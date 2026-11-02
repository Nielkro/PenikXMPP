using Xmpp;
using Gtk;
using Gee;
using Adw;

using Dino.Entities;

namespace Dino.Ui {

    public class CallTitlebarEntry : Plugins.ConversationTitlebarEntry, Object {
        public string id { get { return "call"; } }
        public double order { get { return 4; } }

        private MenuButton button = new MenuButton() { tooltip_text=_("Start call"), visible=false };
        private SimpleAction audio_call_action = new SimpleAction("audio", null);
        private SimpleAction video_call_action = new SimpleAction("video", null);
        private SimpleAction existing_group_call_action = new SimpleAction("group-existing", null);
        private Menu menu_model = new Menu();
        private string menu_signature = "direct";
        private bool disposed = false;
        private bool group_rejoin_in_progress = false;
        private Cancellable? group_rejoin_cancellable = null;

        private StreamInteractor stream_interactor;
        private Conversation conversation;
        private ulong call_incoming_handler_id = 0;
        private ulong call_outgoing_handler_id = 0;
        private ulong call_terminated_handler_id = 0;
        private ulong connection_state_handler_id = 0;
        private ulong capabilities_changed_handler_id = 0;
        private PresenceObserver? presence_observer = null;
        private uint64 capability_generation = 0;

        public CallTitlebarEntry(StreamInteractor stream_interactor) {
            this.stream_interactor = stream_interactor;

            button.set_icon_name("dino-phone-symbolic");

            menu_model.append(_("Audio call"), "call.audio");
            menu_model.append(_("Video call"), "call.video");
            Gtk.PopoverMenu popover_menu = new Gtk.PopoverMenu.from_model(menu_model);
            Util.set_menu_button_popover(button, popover_menu);

            SimpleActionGroup action_group = new SimpleActionGroup();
            audio_call_action.activate.connect((parameter) => {
                initiate_call(false);
            });
            action_group.add_action(audio_call_action);
            video_call_action.activate.connect((parameter) => {
                initiate_call(true);
            });
            action_group.add_action(video_call_action);
            existing_group_call_action.activate.connect((parameter) => {
                open_or_rejoin_group_call();
            });
            action_group.add_action(existing_group_call_action);
            button.insert_action_group("call", action_group);

            var calls = stream_interactor.get_module<Calls>(Calls.IDENTITY);
            call_incoming_handler_id = calls.call_incoming.connect((call, state,conversation) => {
                start_update_visibility();
            });

            call_outgoing_handler_id = calls.call_outgoing.connect((call, state, conversation) => {
                start_update_visibility();
            });

            call_terminated_handler_id = calls.call_terminated.connect((call) => {
                start_update_visibility();
            });
            capabilities_changed_handler_id =
                calls.conversation_call_capabilities_changed.connect(
                    (account, counterpart) => {
                        if (conversation == null ||
                                !conversation.account.equals(account)) return;
                        if (counterpart != null &&
                                !conversation.counterpart.equals_bare(
                                    (!) counterpart)) return;
                        start_update_visibility();
                    });
            connection_state_handler_id = stream_interactor.connection_manager.connection_state_changed.connect((account, state) => {
                if (conversation != null &&
                        conversation.account.equals(account)) {
                    start_update_visibility();
                }
            });
        }

        public override void dispose() {
            if (group_rejoin_cancellable != null) ((!) group_rejoin_cancellable).cancel();
            disposed = true;
            capability_generation++;
            var calls = stream_interactor.get_module<Calls>(Calls.IDENTITY);
            if (call_incoming_handler_id != 0) {
                calls.disconnect(call_incoming_handler_id);
                call_incoming_handler_id = 0;
            }
            if (call_outgoing_handler_id != 0) {
                calls.disconnect(call_outgoing_handler_id);
                call_outgoing_handler_id = 0;
            }
            if (call_terminated_handler_id != 0) {
                calls.disconnect(call_terminated_handler_id);
                call_terminated_handler_id = 0;
            }
            if (capabilities_changed_handler_id != 0) {
                calls.disconnect(capabilities_changed_handler_id);
                capabilities_changed_handler_id = 0;
            }
            if (connection_state_handler_id != 0) {
                stream_interactor.connection_manager.disconnect(connection_state_handler_id);
                connection_state_handler_id = 0;
            }
            if (presence_observer != null) {
                ((!) presence_observer).unsubscribe();
                presence_observer = null;
            }
            base.dispose();
        }

        private void initiate_call(bool video) {
            if (conversation == null) return;
            if (conversation.type_ == Conversation.Type.GROUPCHAT) {
                begin_group_call_request(true, video);
                return;
            }
            ConversationCallCapabilities capabilities = stream_interactor
                .get_module<Calls>(Calls.IDENTITY)
                .get_conversation_call_capabilities(conversation);
            CallCapabilityStatus requested = video ? capabilities.video :
                capabilities.audio;
            if (requested != CallCapabilityStatus.AVAILABLE) {
                start_update_visibility();
                return;
            }
            // Guard: disable button immediately to prevent double-clicks
            button.sensitive = false;

            stream_interactor.get_module<Calls>(Calls.IDENTITY).initiate_call.begin(conversation, video, null, (_, res) => {
                CallState? call_state = stream_interactor.get_module<Calls>(Calls.IDENTITY).initiate_call.end(res);
                if (call_state == null) {
                    // Call was blocked (already in progress) — re-enable button
                    update_button_state();
                    return;
                }
                open_call_window(call_state);
            });
        }

        private bool open_call_window(CallState call_state) {
            if (call_state.group_call != null) {
                var windows = Gtk.Window.get_toplevels();
                for (uint i = 0; i < windows.get_n_items(); i++) {
                    CallWindow? existing = windows.get_item(i) as CallWindow;
                    if (existing != null && ((!) existing).controller != null &&
                            ((!) existing).controller.owns_live_call_state(call_state)) {
                        ((!) existing).present();
                        update_button_state();
                        return !disposed && existing.get_realized() &&
                            existing.controller.owns_live_call_state(call_state);
                    }
                }
            }
            var call_window = new CallWindow();
            var call_controller = new CallWindowController(call_window, call_state, stream_interactor);
            call_window.controller = call_controller;
            call_window.present();

            update_button_state();
            return !disposed && call_window.get_realized() &&
                call_controller.owns_live_call_state(call_state);
        }

        private void open_or_rejoin_group_call() {
            if (disposed || group_rejoin_in_progress || conversation == null ||
                    conversation.type_ != Conversation.Type.GROUPCHAT) return;
            var calls = stream_interactor.get_module<Calls>(Calls.IDENTITY);
            CallState? current = calls.get_current_group_call(conversation);
            if (current != null) {
                open_call_window((!) current);
                return;
            }
            bool video = calls.current_group_call_has_video(conversation) &&
                calls.can_we_do_call(conversation.account, true, true);
            begin_group_call_request(false, video);
        }

        private async CallState? perform_group_call_request(Calls calls, Conversation source,
                bool start_new, bool current_room, bool video,
                GroupCallRejoinTicket? ticket, Cancellable cancellable) {
            if (start_new) return yield calls.initiate_call(source, video, cancellable);
            if (current_room) return yield calls.join_current_group_call(source, video, cancellable);
            if (ticket == null) return null;
            return yield calls.rejoin_group_call(source, (!) ticket, cancellable);
        }

        private void finish_group_call_request(Cancellable request,
                Gtk.Window? parent, ulong parent_close_handler_id) {
            if (parent != null && parent_close_handler_id != 0 &&
                    SignalHandler.is_connected(parent, parent_close_handler_id)) {
                parent.disconnect(parent_close_handler_id);
            }
            if (group_rejoin_cancellable == request) {
                group_rejoin_cancellable = null;
                group_rejoin_in_progress = false;
            }
            if (!disposed) update_button_state();
        }

        private void begin_group_call_request(bool start_new, bool video) {
            if (disposed || group_rejoin_in_progress || conversation == null ||
                    conversation.type_ != Conversation.Type.GROUPCHAT) return;
            Conversation source = conversation;
            var calls = stream_interactor.get_module<Calls>(Calls.IDENTITY);
            bool current_room = calls.has_current_group_call_participants(source);
            GroupCallRejoinTicket? ticket = calls.get_group_call_rejoin_ticket(source);
            if (calls.is_call_in_progress() ||
                    (start_new ? current_room : !current_room && ticket == null)) {
                update_button_state();
                return;
            }
            if (start_new) {
                ConversationCallCapabilities capabilities = calls.get_conversation_call_capabilities(source);
                if ((video ? capabilities.video : capabilities.audio) != CallCapabilityStatus.AVAILABLE) return;
            }
            Gtk.Window? parent = button.get_root() as Gtk.Window;
            if (parent == null || !parent.get_realized()) return;
            WeakRef parent_ref = WeakRef(parent);
            var request_cancellable = new Cancellable();
            group_rejoin_cancellable = request_cancellable;
            ulong parent_close_handler_id = parent.close_request.connect(() => {
                request_cancellable.cancel();
                return false;
            });
            group_rejoin_in_progress = true;
            update_button_state();
            perform_group_call_request.begin(calls, source, start_new, current_room, video,
                    ticket, request_cancellable, (source_object, result) => {
                CallState? joined = perform_group_call_request.end(result);
                Gtk.Window? current_parent = parent_ref.get() as Gtk.Window;
                if (disposed || request_cancellable.is_cancelled() || conversation != source ||
                        current_parent == null || !current_parent.get_realized() ||
                        button.get_root() != current_parent) {
                    if (joined != null) calls.abort_group_call_handoff(joined, request_cancellable);
                    finish_group_call_request(request_cancellable, current_parent, parent_close_handler_id);
                    return;
                }
                if (joined != null) {
                    if (open_call_window(joined)) {
                        calls.acknowledge_group_call_handoff(joined, request_cancellable);
                    } else {
                        calls.abort_group_call_handoff(joined, request_cancellable);
                    }
                } else if (conversation == source && source.active && !calls.is_call_in_progress()) {
                    var dialog = new Adw.AlertDialog(
                        _("Group call unavailable"),
                        _("This group call is no longer available. You can start a new call from the call menu."));
                    dialog.add_response("close", _("Close"));
                    dialog.present(current_parent);
                }
                finish_group_call_request(request_cancellable, current_parent, parent_close_handler_id);
            });
        }

        private void update_group_menu(bool current, bool remote, bool previous) {
            bool group = conversation != null && conversation.type_ == Conversation.Type.GROUPCHAT;
            string signature = group ? "group:%s:%s:%s".printf(current.to_string(), remote.to_string(), previous.to_string()) : "direct";
            if (signature == menu_signature) return;
            menu_signature = signature;
            menu_model.remove_all();
            if (group && (current || remote || previous)) {
                string label = current ? _("Open ongoing group call") :
                    remote ? _("Join ongoing group call") : _("Rejoin previous group call");
                menu_model.append(label, "call.group-existing");
            }
            menu_model.append(group ? _("New audio group call") : _("Audio call"), "call.audio");
            menu_model.append(group ? _("New video group call") : _("Video call"), "call.video");
        }

        public new void set_conversation(Conversation conversation) {
            if (this.conversation != conversation) {
                button.popdown();
                if (group_rejoin_cancellable != null) ((!) group_rejoin_cancellable).cancel();
            }
            if (presence_observer != null) {
                ((!) presence_observer).unsubscribe();
                presence_observer = null;
            }
            this.conversation = conversation;

            // Direct-call availability follows the contact's presence. Group
            // call visibility does not change for every occupant presence and
            // must not launch one async capability check per MUC member.
            if (conversation.type_ == Conversation.Type.CHAT) {
                var presence_manager = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
                WeakRef entry_weak = WeakRef(this);
                presence_observer = presence_manager.observe_presence(conversation.account, conversation.counterpart.bare_jid,
                    (jid, account, available) => {
                        CallTitlebarEntry? entry = (CallTitlebarEntry?) entry_weak.get();
                        if (entry == null || ((!) entry).conversation == null || ((!) entry).conversation != conversation) return false;
                        ((!) entry).start_update_visibility();
                        return true;
                    });
            }

            // Do not paint the previous chat's call control while waiting for
            // an idle callback. Capability lookup uses the current local state;
            // later presence/discovery changes still refresh it via signals.
            capability_generation++;
            update_button_state();
        }

        private void start_update_visibility() {
            uint64 generation = ++capability_generation;
            Idle.add(() => {
                if (generation != capability_generation) return Source.REMOVE;
                update_button_state();
                return Source.REMOVE;
            });
        }

        private void update_button_state() {
            if (disposed) return;
            var calls = stream_interactor.get_module<Calls>(Calls.IDENTITY);
            if (conversation == null) {
                button.visible = false;
                button.sensitive = false;
                audio_call_action.set_enabled(false);
                video_call_action.set_enabled(false);
                existing_group_call_action.set_enabled(false);
                return;
            }
            ConversationCallCapabilities capabilities =
                calls.get_conversation_call_capabilities(conversation);
            bool call_in_progress = calls.is_call_in_progress();
            bool group = conversation.type_ == Conversation.Type.GROUPCHAT;
            bool group_pending = group && group_rejoin_in_progress;
            CallState? current_group = group ? calls.get_current_group_call(conversation) : null;
            GroupCallRejoinTicket? ticket = group ? calls.get_group_call_rejoin_ticket(conversation) : null;
            bool previous_available = ticket != null &&
                calls.can_we_do_call(conversation.account, ((!) ticket).video, true);
            bool remote_group = group && calls.has_current_group_call_participants(conversation);
            bool new_group_available = !group || calls.can_start_new_group_call(conversation);
            bool current_join_available = remote_group &&
                calls.can_we_do_call(conversation.account, false, true);
            bool existing_available = !group_pending &&
                (current_group != null || (!call_in_progress && (current_join_available || previous_available)));
            bool audio_available = capabilities.audio ==
                CallCapabilityStatus.AVAILABLE;
            bool video_available = capabilities.video ==
                CallCapabilityStatus.AVAILABLE;

            update_group_menu(current_group != null, remote_group, ticket != null);
            existing_group_call_action.set_enabled(existing_available);
            button.visible = capabilities.visible || existing_available;
            button.sensitive = existing_available || (!call_in_progress && !group_pending &&
                (audio_available || video_available));
            audio_call_action.set_enabled(!call_in_progress && !group_pending && new_group_available && audio_available);
            video_call_action.set_enabled(!call_in_progress && !group_pending && new_group_available && video_available);
            switch (capabilities.reason) {
                case CallCapabilityReason.ROOM_INFO_PENDING:
                    button.tooltip_text = _("Checking call availability...");
                    break;
                case CallCapabilityReason.MUC_SERVICE_PENDING:
                    button.tooltip_text = _("Conference server is not available yet");
                    break;
                default:
                    button.tooltip_text = current_group != null ? _("Open ongoing group call") : _("Start call");
                    break;
            }
        }

        public new void unset_conversation() {
            button.popdown();
            if (group_rejoin_cancellable != null) ((!) group_rejoin_cancellable).cancel();
            if (presence_observer != null) {
                ((!) presence_observer).unsubscribe();
                presence_observer = null;
            }
            capability_generation++;
            this.conversation = null;
            update_button_state();
        }

        public Object? get_widget(Plugins.WidgetType type) {
            if (type != Plugins.WidgetType.GTK4) return null;
            return button;
        }
    }

}
