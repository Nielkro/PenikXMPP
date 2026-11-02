using Xmpp;
using Gee;
using Dino.Entities;
using Gtk;

public class Dino.Ui.CallWindowController : Object {

    private CallWindow call_window;
    private Call call;
    private CallState call_state;

    public bool owns_live_call_state(CallState candidate) {
        return !closing && !cleaned_up && !call_has_terminated && call_state == candidate;
    }
    private StreamInteractor stream_interactor;
    private Calls calls;
    private Plugins.VideoCallPlugin? call_plugin = null;
    private bool uses_google_webrtc_jmi_call_engine = false;
    private Plugins.JmiCallEnginePlugin? selected_jmi_call_engine = null;

    private Plugins.VideoCallWidget? own_video = null;
    private LibwebrtcVideoWidget? google_webrtc_jmi_own_video = null;
    private HashMap<string, Plugins.VideoCallWidget> participant_videos = new HashMap<string, Plugins.VideoCallWidget>();
    private HashMap<string, LibwebrtcVideoWidget> google_webrtc_jmi_participant_videos = new HashMap<string, LibwebrtcVideoWidget>();
    private HashMap<string, ParticipantWidget> participant_widgets = new HashMap<string, ParticipantWidget>();
    private HashMap<string, PeerState> peer_states = new HashMap<string, PeerState>();
    // Per-peer signal handler IDs for cleanup in remove_participant()
    private HashMap<string, ulong> peer_connection_ready_handler_ids = new HashMap<string, ulong>();
    private HashMap<string, ulong> peer_video_updated_handler_ids = new HashMap<string, ulong>();
    private HashMap<string, ulong> peer_google_webrtc_jmi_video_frame_handler_ids = new HashMap<string, ulong>();
    private HashMap<string, ulong> peer_google_webrtc_jmi_local_video_frame_handler_ids = new HashMap<string, ulong>();
    private HashMap<string, ulong> peer_info_received_handler_ids = new HashMap<string, ulong>();
    private HashMap<string, ulong> peer_encryption_handler_ids = new HashMap<string, ulong>();
    private HashMap<string, ulong> participant_video_resolution_handler_ids = new HashMap<string, ulong>();
    private HashMap<string, ulong> google_webrtc_jmi_video_resolution_handler_ids = new HashMap<string, ulong>();
    private HashMap<string, ulong> debug_info_handler_ids = new HashMap<string, ulong>();
    private HashMap<string, ulong> volume_handler_ids = new HashMap<string, ulong>();
    private Plugins.MediaDevice? google_webrtc_jmi_microphone_device = null;
    private Plugins.MediaDevice? google_webrtc_jmi_speaker_device = null;
    private int window_height = -1;
    private int window_width = -1;
    private bool window_size_changed = false;
    private bool closing = false;
    private bool cleaned_up = false;
    private bool background_image_load_busy = false;
    private Cancellable background_image_cancellable = new Cancellable();
    private bool call_has_terminated = false;
    private uint64 async_generation = 1;
    private uint64 invite_control_generation = 0;
    private bool participant_invite_available = false;
    private SelectContactDialog? participant_invite_dialog = null;
    private uint close_timeout_id = 0;
    private uint call_duration_timeout_id = 0;
    private int64 call_duration_started_us = 0;
    private ulong[] call_window_handler_ids = new ulong[0];
    private ulong[] bottom_bar_handler_ids = new ulong[0];
    private ulong call_state_notify_handler_id = 0;
    private ulong devices_changed_handler_id = 0;
    // Singleton/long-lived object handler IDs
    private ulong calls_conference_info_handler_id = 0;
    private ulong call_state_terminated_handler_id = 0;
    private ulong call_state_peer_joined_handler_id = 0;
    private ulong call_state_peer_left_handler_id = 0;
    private ulong call_state_video_effect_handler_id = 0;
    private ulong call_state_group_call_handler_id = 0;
    private ulong call_state_video_mode_handler_id = 0;
    private ulong call_state_invite_capability_handler_id = 0;
    private ulong call_state_invite_availability_handler_id = 0;
    private ulong invite_connection_state_handler_id = 0;
    private ulong own_video_resolution_handler_id = 0;
    private ulong google_webrtc_jmi_own_video_resolution_handler_id = 0;
    private Xep.Muji.GroupCall? observed_group_call = null;
    private ulong group_call_peer_joined_handler_id = 0;
    private ulong group_call_peer_left_handler_id = 0;

    private uint inhibit_cookie;

    public CallWindowController(CallWindow call_window, CallState call_state, StreamInteractor stream_interactor) {
        this.call_window = call_window;
        this.call = call_state.call;
        this.call_state = call_state;
        this.stream_interactor = stream_interactor;

        this.calls = stream_interactor.get_module<Calls>(Calls.IDENTITY);
        this.uses_google_webrtc_jmi_call_engine = call_state.uses_google_webrtc_jmi_call_engine();
        this.selected_jmi_call_engine = call_state.get_selected_jmi_call_engine();
        if (!uses_google_webrtc_jmi_call_engine) {
            this.call_plugin = Dino.Application.get_default().plugin_registry.video_call_plugin;
            this.own_video = require_legacy_call_plugin().create_widget(
                Plugins.WidgetType.GTK4);
        }

        call_window.set_default_size(704, 528); // 640x480 * 1.1

        call_state_notify_handler_id = call.notify["state"].connect(on_call_state_changed);
        invite_connection_state_handler_id = stream_interactor.connection_manager
            .connection_state_changed.connect(on_invite_connection_state_changed);
        on_call_state_changed();

        this.call_window.bottom_bar.video_enabled = call_state.should_we_send_video();
        refresh_video_control_visibility();

        call_state_terminated_handler_id = call_state.terminated.connect((who_terminated, reason_name, reason_text) => {
            call_has_terminated = true;
            close_participant_invite_dialog();
            refresh_participant_invite_control();
            // Let child controls release transient resources before the
            // delayed ended-call window teardown.
            call_window.shutdown_transient_ui();

            Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation(who_terminated.bare_jid, call.account, Conversation.Type.CHAT);
            string display_name = conversation != null ? Util.get_conversation_display_name(stream_interactor, conversation) : who_terminated.bare_jid.to_string();

            call_window.show_counterpart_ended(display_name, reason_name, reason_text);

            // Release GStreamer resources immediately — don't wait 3 seconds.
            // The window stays open to show "call ended" but video/audio
            // pipeline elements are freed right away (~80+ MB).
            detach_all_video();

            close_timeout_id = Timeout.add_seconds(3, () => {
                close_timeout_id = 0;
                if (!closing) {
                    closing = true;
                    call_window.close();
                    cleanup();
                }
                return false;
            });
        });
        call_state_peer_joined_handler_id = call_state.peer_joined.connect((jid, peer_state) => {
            if (closing || call_has_terminated) return;
            connect_peer_signals(peer_state);
            add_new_participant(peer_state.internal_id, peer_state.jid);
            refresh_participant_invite_control();
            update_video_effect_controls();
        });
        call_state_peer_left_handler_id = call_state.peer_left.connect((jid, peer_state, reason_name, reason_text) => {
            if (closing || call_has_terminated) return;
            remove_participant(peer_state.internal_id);
            refresh_participant_invite_control();
            update_video_effect_controls();
        });
        call_state_video_effect_handler_id = call_state.video_effect_status_changed.connect((status) => {
            if (closing || call_has_terminated) return;
            update_video_effect_controls();
        });
        call_state_group_call_handler_id = call_state.notify["group-call"].connect(() => {
            if (closing || call_has_terminated) return;
            setup_group_call_participant_list();
            refresh_video_control_visibility();
            refresh_participant_invite_control();
            update_video_effect_controls();
        });
        call_state_invite_capability_handler_id = call_state.notify[
            "can-invite-group-participants"].connect(() => {
                if (closing || call_has_terminated) return;
                refresh_participant_invite_control();
            });
        call_state_invite_availability_handler_id = call_state
            .participant_invite_availability_changed.connect(() => {
                if (owns_live_call_state(call_state)) refresh_participant_invite_control();
            });
        call_state_video_mode_handler_id = call_state.notify[
            "we-should-send-video"].connect(() => {
                if (closing || call_has_terminated) return;
                bool video_enabled = call_state.should_we_send_video();
                call_window.bottom_bar.video_enabled = video_enabled;
                if (uses_google_webrtc_jmi_call_engine &&
                        call_state.is_group_video_permanently_disabled()) {
                    call_window.bottom_bar.show_video_controls(false);
                    detach_all_video();
                    foreach (var participant_entry in peer_states.entries) {
                        Conversation? participant_conversation =
                            stream_interactor.get_module<ConversationManager>(
                                ConversationManager.IDENTITY).get_conversation(
                                    participant_entry.value.jid.bare_jid,
                                    call.account, Conversation.Type.CHAT);
                        call_window.set_placeholder(participant_entry.key,
                            participant_conversation, stream_interactor);
                    }
                } else if (uses_google_webrtc_jmi_call_engine) {
                    refresh_video_control_visibility();
                }
                refresh_participant_invite_control();
                update_video_effect_controls();
            });

        foreach (PeerState peer_state in call_state.peers.values) {
            connect_peer_signals(peer_state);
            add_new_participant(peer_state.internal_id, peer_state.jid);
        }

        // Setup MUJI group call participant list
        setup_group_call_participant_list();

        // Call window signals

        bottom_bar_handler_ids += call_window.bottom_bar.add_participant.connect(
            invite_button_clicked);
        bottom_bar_handler_ids += call_window.bottom_bar.hang_up.connect(() => {
            if (closing) return;
            closing = true;
            if (close_timeout_id != 0) {
                Source.remove(close_timeout_id);
                close_timeout_id = 0;
            }
            call_state.end();
            call_window.close();
            cleanup();
        });
        call_window_handler_ids += call_window.close_request.connect(() => {
            if (closing) return false;
            closing = true;
            if (close_timeout_id != 0) {
                Source.remove(close_timeout_id);
                close_timeout_id = 0;
            }
            call_state.end();
            // cleanup() after close — schedule on idle so GTK finishes the close first
            Idle.add(() => { cleanup(); return false; });
            return false;
        });
        bottom_bar_handler_ids += call_window.bottom_bar.notify["audio-enabled"].connect(() => {
            call_state.mute_own_audio(!call_window.bottom_bar.audio_enabled);
        });
        bottom_bar_handler_ids += call_window.bottom_bar.notify["video-enabled"].connect(() => {
            if (uses_google_webrtc_jmi_call_engine) {
                call_state.mute_own_video(!call_window.bottom_bar.video_enabled);
                if (!call_window.bottom_bar.video_enabled) {
                    detach_google_webrtc_jmi_own_video();
                }
                update_video_effect_controls();
                return;
            }
            call_state.mute_own_video(!call_window.bottom_bar.video_enabled);
            update_own_video();
            update_video_effect_controls();
        });
        bottom_bar_handler_ids += call_window.bottom_bar.video_effect_selected.connect((selection) => {
            if (closing || call_has_terminated ||
                    (!uses_google_webrtc_jmi_call_engine && call_state.group_call == null)) return;
            VideoEffectsPopover? controls = call_window.bottom_bar.video_effects_popover;
            if (controls == null || !((!) controls).has_pending_background_image)
                background_image_cancellable.cancel();
            call_state.request_video_effect(selection);
        });
        bottom_bar_handler_ids += call_window.bottom_bar.video_background_requested.connect((choice, generation) => {
            background_image_cancellable.cancel();
            background_image_cancellable = new Cancellable();
            stage_background_image.begin(choice, generation);
        });
        bottom_bar_handler_ids += call_window.bottom_bar.dtmf_digit.connect((digit) => {
            if (uses_google_webrtc_jmi_call_engine) {
                bool sent = false;
                foreach (PeerState peer_state in call_state.peers.values) {
                    sent = peer_state.send_google_webrtc_jmi_dtmf(digit) || sent;
                }
                if (!sent) {
                    warning("No Google/libwebrtc call session accepted DTMF digit");
                }
                return;
            }

            // Send DTMF via RFC 4733 to all peers' audio streams
            foreach (PeerState peer_state in call_state.peers.values) {
                var audio_stream = peer_state.get_audio_stream();
                if (audio_stream != null) {
                    require_legacy_call_plugin().send_dtmf(audio_stream, digit);
                }
            }
        });
        call_window_handler_ids += call_window.notify["default-width"].connect((event) => {
            if (call_window.default_width == -1) return;
            int current_width = this.call_window.get_width();
            if (window_width != current_width) {
                debug("Call window size changed by user. Disabling auto window-to-video size adaptation. Width %i->%i", window_width, current_width);
                window_size_changed = true;
            }
        });
        call_window_handler_ids += call_window.notify["default-height"].connect((event) => {
            if (call_window.default_height == -1) return;
            int current_height = this.call_window.get_height();
            if (window_height != current_height) {
                debug("Call window size changed by user. Disabling auto window-to-video size adaptation. Height %i->%i", window_height, current_height);
                window_size_changed = true;
            }
        });
        call_window_handler_ids += ((Widget)call_window).realize.connect(() => {
            capture_window_size();
        });

        calls_conference_info_handler_id = calls.conference_info_received.connect((call, conference_info) => {
            if (!this.call.equals(call)) return;

            var participants = new ArrayList<string>();
            participants.add_all(participant_videos.keys);
            foreach (string participant in participants) {
                remove_participant(participant);
            }
            foreach (Jid participant in conference_info.users.keys) {
                add_new_participant(participant.to_string(), participant);
            }
        });

        if (own_video != null) {
            own_video_resolution_handler_id = ((!) own_video).resolution_changed.connect((width, height) => {
                if (width == 0 || height == 0) return;
                call_window.set_own_video_ratio((int)width, (int)height);
            });
        }

        call_window_handler_ids += call_window.menu_dump_dot.connect(() => {
            if (uses_google_webrtc_jmi_call_engine) return;
            require_legacy_call_plugin().dump_dot();
        });

        update_own_video();

        if (uses_google_webrtc_jmi_call_engine) {
            update_google_webrtc_jmi_audio_device_choices();
            update_google_webrtc_jmi_video_device_choices();
        } else {
            update_audio_device_choices();
            update_video_device_choices();
        }
        update_video_effect_controls();
        // Seed availability even when connection_ready preceded this window.
        refresh_participant_invite_control();

        var app = GLib.Application.get_default() as Application;
        inhibit_cookie = app.inhibit(call_window, IDLE | SUSPEND, "Ongoing call");

        if (inhibit_cookie == 0) {
            warning("suspend inhibit request failed or unsupported");
        }

        call_window_handler_ids += call_window.close_request.connect(() => {
            if (inhibit_cookie != 0) {
                app.uninhibit(inhibit_cookie);
            }
            return false;
        });
    }

    private void on_call_state_changed() {
        refresh_video_control_visibility();
        update_video_effect_controls();
        refresh_participant_invite_control();
        if (call.state == Call.State.IN_PROGRESS) {
            if (call_duration_started_us != 0) return;

            call_duration_started_us = GLib.get_monotonic_time();
            update_call_duration();
            call_duration_timeout_id = Timeout.add_seconds(1, () => {
                if (closing || call.state != Call.State.IN_PROGRESS) {
                    call_duration_timeout_id = 0;
                    return Source.REMOVE;
                }
                update_call_duration();
                return Source.CONTINUE;
            });
            return;
        }

        if (call_duration_started_us == 0) {
            call_window.hide_call_duration();
            return;
        }

        update_call_duration();
        stop_call_duration_timer();
    }

    private void update_call_duration() {
        int64 elapsed_us = GLib.get_monotonic_time() - call_duration_started_us;
        int elapsed_seconds = (int) (elapsed_us / GLib.TimeSpan.SECOND);
        int hours = elapsed_seconds / 3600;
        int minutes = (elapsed_seconds % 3600) / 60;
        int seconds = elapsed_seconds % 60;

        if (hours > 0) {
            call_window.show_call_duration("%d:%02d:%02d".printf(hours, minutes, seconds));
        } else {
            call_window.show_call_duration("%02d:%02d".printf(minutes, seconds));
        }
    }

    private void stop_call_duration_timer() {
        if (call_duration_timeout_id == 0) return;
        Source.remove(call_duration_timeout_id);
        call_duration_timeout_id = 0;
    }

    private void invite_button_clicked() {
        if (!owns_live_call_state(call_state) || !participant_invite_available ||
                participant_invite_dialog != null) return;
        CallState expected_state = call_state;
        Account expected_account = call.account;
        XmppStream? expected_stream = stream_interactor.get_stream(expected_account);
        if (expected_stream == null) {
            refresh_participant_invite_control();
            return;
        }
        uint64 operation_generation = async_generation;
        Gee.List<Account> accounts = new ArrayList<Account>(Account.equals_func);
        accounts.add(expected_account);
        var dialog = new SelectContactDialog(stream_interactor, accounts);
        participant_invite_dialog = dialog;
        dialog.title = _("Invite to Call");
        dialog.ok_button.label = _("Invite");
        dialog.selected.connect((selected_account, jid) => {
            if (participant_invite_dialog != dialog ||
                    !owns_live_call_state(expected_state) ||
                    async_generation != operation_generation ||
                    call.account != expected_account ||
                    selected_account != expected_account ||
                    stream_interactor.get_stream(expected_account) != expected_stream) return;
            // The backend rechecks capabilities and ownership before changing
            // the call; a dialog result never authorizes a successor call.
            expected_state.invite_to_call.begin(jid, (source, result) => {
                ParticipantInviteAvailability invitation = expected_state.invite_to_call.end(result);
                if (owns_live_call_state(expected_state) &&
                        async_generation == operation_generation &&
                        call.account == expected_account &&
                        stream_interactor.get_stream(expected_account) == expected_stream) {
                    if (invitation == ParticipantInviteAvailability.CONTACT_UNSUPPORTED) {
                        call_window.show_invite_notice(_("This contact does not support group calls."));
                    } else if (invitation != ParticipantInviteAvailability.AVAILABLE &&
                            invitation != ParticipantInviteAvailability.CONVERTING &&
                            invitation != ParticipantInviteAvailability.ENDED) {
                        call_window.show_invite_notice(participant_invite_explanation(invitation));
                    }
                    refresh_participant_invite_control();
                }
            });
            refresh_participant_invite_control();
        });
        dialog.closed.connect(() => {
            if (participant_invite_dialog == dialog) {
                participant_invite_dialog = null;
                refresh_participant_invite_control();
            }
        });
        dialog.unmap.connect(() => {
            // Older libadwaita Gtk.Window hosts do not emit Dialog.closed.
            // A dismissed host is no longer visible; minimization or hiding
            // an embedded parent must not cancel a still-present chooser.
            Gtk.Root? root = dialog.get_root();
            if (root is Adw.Window || root is Adw.ApplicationWindow) return;
            if (root is Gtk.Window && ((Gtk.Window) root).get_visible()) return;
            if (participant_invite_dialog == dialog) {
                participant_invite_dialog = null;
                refresh_participant_invite_control();
            }
        });
        refresh_participant_invite_control();
        dialog.present(call_window);
    }

    private void close_participant_invite_dialog() {
        SelectContactDialog? dialog = participant_invite_dialog;
        participant_invite_dialog = null;
        if (dialog != null && ((!) dialog).get_mapped()) ((!) dialog).close();
    }

    private void refresh_video_control_visibility() {
        if (!owns_live_call_state(call_state) || !uses_google_webrtc_jmi_call_engine) return;
        // Turning off our camera does not remove negotiated video media.
        // Keep the control available for an explicit, later camera choice.
        call_window.bottom_bar.show_video_controls(call_state.has_video_media());
    }

    private void on_invite_connection_state_changed(Account account,
            ConnectionManager.ConnectionState state) {
        if (!account.equals(call.account) || !owns_live_call_state(call_state)) return;
        if (state != ConnectionManager.ConnectionState.CONNECTED) {
            close_participant_invite_dialog();
        }
        refresh_participant_invite_control();
    }

    private void refresh_participant_invite_control() {
        participant_invite_available = false;
        uint64 request_generation = ++invite_control_generation;
        call_window.bottom_bar.update_participant_invite(false,
            owns_live_call_state(call_state)
                ? _("Checking call availability...") : _("The call has ended."));
        if (!owns_live_call_state(call_state)) return;
        CallState expected_state = call_state;
        Account expected_account = call.account;
        XmppStream? expected_stream = stream_interactor.get_stream(expected_account);
        uint64 operation_generation = async_generation;
        expected_state.get_participant_invite_availability.begin((source, result) => {
            ParticipantInviteAvailability availability =
                expected_state.get_participant_invite_availability.end(result);
            if (!owns_live_call_state(expected_state) ||
                    async_generation != operation_generation ||
                    invite_control_generation != request_generation) return;
            if (call.account != expected_account ||
                    stream_interactor.get_stream(expected_account) != expected_stream) {
                call_window.bottom_bar.update_participant_invite(false,
                    _("Wait until the call is connected."));
                return;
            }
            participant_invite_available = availability ==
                ParticipantInviteAvailability.AVAILABLE;
            call_window.bottom_bar.update_participant_invite(
                participant_invite_available && participant_invite_dialog == null,
                participant_invite_explanation(availability));
        });
    }

    private static string participant_invite_explanation(
            ParticipantInviteAvailability availability) {
        switch (availability) {
        case ParticipantInviteAvailability.AVAILABLE:
            return _("Add participant");
        case ParticipantInviteAvailability.NOT_CONNECTED:
            return _("Wait until the call is connected.");
        case ParticipantInviteAvailability.CONVERTING:
            return _("The call is being changed to a group call.");
        case ParticipantInviteAvailability.PEER_UNSUPPORTED:
            return _("The other client cannot join a group call.");
        case ParticipantInviteAvailability.NO_MUC_SERVICE:
            return _("This account has no service for private group calls.");
        case ParticipantInviteAvailability.NO_INVITE_PERMISSION:
            return _("You cannot invite participants to this group call.");
        case ParticipantInviteAvailability.CALL_FULL:
            return _("The group call is full.");
        case ParticipantInviteAvailability.ENDED:
            return _("The call has ended.");
        default:
            return _("Group calls are not available for this call.");
        }
    }

    private void connect_peer_signals(PeerState peer_state) {
        string peer_id = peer_state.internal_id;
        Jid peer_jid = peer_state.jid;
        peer_states[peer_id] = peer_state;

        peer_connection_ready_handler_ids[peer_id] = peer_state.connection_ready.connect(() => {
            if (closing || !participant_widgets.has_key(peer_id)) return;
            call_window.set_status(peer_id, "");
            
            // Show volume controls only in group calls (more than 1 participant)
            if (!uses_google_webrtc_jmi_call_engine && participant_widgets.size > 1) {
                // Enable volume controls for all participants in group call
                participant_widgets.values.@foreach((widget) => widget.show_volume_control = true);
                
                // Initialize participant volume from stream
                if (participant_widgets.has_key(peer_id)) {
                    var audio_stream = peer_state.get_audio_stream();
                    if (audio_stream != null) {
                        double current_volume = require_legacy_call_plugin()
                            .get_stream_volume(audio_stream);
                        participant_widgets[peer_id].set_volume(current_volume);
                    }
                }
            }
            
            if (participant_widgets.size == 1) {
                if (!uses_google_webrtc_jmi_call_engine) {
                    devices_changed_handler_id = require_legacy_call_plugin()
                        .devices_changed.connect((media, incoming) => {
                        if (media == "audio") update_audio_device_choices();
                        if (media == "video") update_video_device_choices();
                    });

                    update_audio_device_choices();
                    update_video_device_choices();
                }
            }
            refresh_participant_invite_control();
        });
        peer_video_updated_handler_ids[peer_id] = peer_state.counterpart_sends_video_updated.connect((mute) => {
            if (closing || !participant_widgets.has_key(peer_id) || !participant_videos.has_key(peer_id)) return;
            debug("RECV-VIDEO-UI: counterpart_sends_video_updated mute=%s widgets=%s videos=%s",
                    mute.to_string(), participant_widgets.has_key(peer_id).to_string(), participant_videos.has_key(peer_id).to_string());
            if (mute) {
                Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation(peer_jid.bare_jid, call.account, Conversation.Type.CHAT);
                call_window.set_placeholder(peer_id, conversation, stream_interactor);
                participant_videos[peer_id].detach();
            } else {
                if (!(participant_videos[peer_id] is Widget)) return;
                Widget widget = (Widget) participant_videos[peer_id];
                call_window.set_video(peer_id, widget);
                participant_videos[peer_id].display_stream(peer_state.get_video_stream(), peer_jid);
            }
        });
        if (uses_google_webrtc_jmi_call_engine) {
            peer_google_webrtc_jmi_video_frame_handler_ids[peer_id] = peer_state.google_webrtc_jmi_remote_video_frame.connect((frame) => {
                display_google_webrtc_jmi_video_frame(peer_id, frame);
            });
            peer_google_webrtc_jmi_local_video_frame_handler_ids[peer_id] = peer_state.google_webrtc_jmi_local_video_frame.connect((frame) => {
                display_google_webrtc_jmi_local_video_frame(frame);
            });
        }
        peer_info_received_handler_ids[peer_id] = peer_state.info_received.connect((session_info) => {
            if (closing) return;
            if (session_info == Xmpp.Xep.JingleRtp.CallSessionInfo.RINGING) {
                call_window.set_status(peer_id, "ringing");
            }
        });
        peer_encryption_handler_ids[peer_id] = peer_state.encryption_updated.connect((state, audio_encryption,  video_encryption) => {
            if (closing || !participant_widgets.has_key(peer_id) || !peer_states.has_key(peer_id)) return;
            PeerState current_peer_state = peer_states[peer_id];
            update_encryption_indicator(
                participant_widgets[peer_id].encryption_button_controller,
                current_peer_state.audio_content != null || current_peer_state.uses_google_webrtc_jmi_call_engine_session(),
                audio_encryption,
                current_peer_state.video_content != null ||
                    (current_peer_state.uses_google_webrtc_jmi_call_engine_session() && current_peer_state.we_should_send_video),
                video_encryption);
        });
    }

    private void display_google_webrtc_jmi_video_frame(string participant_id, Plugins.JmiCallVideoFrame frame) {
        if (closing || !uses_google_webrtc_jmi_call_engine || !participant_widgets.has_key(participant_id)) {
            return;
        }
        LibwebrtcVideoWidget? video_widget = google_webrtc_jmi_participant_videos[participant_id];
        if (video_widget == null) {
            video_widget = create_google_webrtc_jmi_video_widget(participant_id);
        }
        if (video_widget == null) return;

        if (!participant_widgets[participant_id].shows_video) {
            call_window.set_video(participant_id, (!) video_widget);
        }
        ((!) video_widget).display_frame(frame);
    }

    private void display_google_webrtc_jmi_local_video_frame(Plugins.JmiCallVideoFrame frame) {
        if (closing || !uses_google_webrtc_jmi_call_engine || !call_window.bottom_bar.video_enabled) {
            return;
        }

        LibwebrtcVideoWidget? video_widget = google_webrtc_jmi_own_video;
        if (video_widget == null) {
            video_widget = create_google_webrtc_jmi_own_video_widget();
        }
        if (video_widget == null) return;

        ((!) video_widget).display_frame(frame);
    }

    private LibwebrtcVideoWidget create_google_webrtc_jmi_own_video_widget() {
        LibwebrtcVideoWidget video_widget = new LibwebrtcVideoWidget();
        google_webrtc_jmi_own_video = video_widget;
        google_webrtc_jmi_own_video_resolution_handler_id = video_widget.resolution_changed.connect((width, height) => {
            if (width <= 0 || height <= 0) return;
            call_window.set_own_video_ratio(width, height);
        });
        call_window.set_own_video(video_widget);
        return video_widget;
    }

    private LibwebrtcVideoWidget create_google_webrtc_jmi_video_widget(string participant_id) {
        LibwebrtcVideoWidget video_widget = new LibwebrtcVideoWidget();
        google_webrtc_jmi_participant_videos[participant_id] = video_widget;
        google_webrtc_jmi_video_resolution_handler_ids[participant_id] = video_widget.resolution_changed.connect((width, height) => {
            if (window_size_changed || participant_widgets.size > 1) return;
            if (width == 0 || height == 0) return;
            if (width > height) {
                call_window.default_width = 704;
                call_window.default_height = (int) (height * 704 / width);
            } else {
                call_window.default_width = (int) (width * 704 / height);
                call_window.default_height = 704;
            }
            capture_window_size();
        });
        return video_widget;
    }

    private void update_encryption_indicator(CallEncryptionButtonController encryption_button, bool has_audio, Xep.Jingle.ContentEncryption? audio_encryption, bool has_video, Xep.Jingle.ContentEncryption? video_encryption) {
        string? title = null;
        string? icon_name = null;
        bool show_keys = true;
        Plugins.Registry registry = Dino.Application.get_default().plugin_registry;
        if (((has_audio && audio_encryption != null) || (has_video && video_encryption != null)) && (!has_audio || !has_video || (audio_encryption != null && video_encryption != null && audio_encryption.encryption_ns == video_encryption.encryption_ns))) {
            Plugins.CallEncryptionEntry? audio_encryption_entry = audio_encryption != null ? registry.call_encryption_entries[audio_encryption.encryption_ns] : null;
            Plugins.CallEncryptionEntry? video_encryption_entry = video_encryption != null ? registry.call_encryption_entries[video_encryption.encryption_ns] : null;
            Plugins.CallEncryptionWidget? audio_encryption_widgets = audio_encryption_entry != null ? audio_encryption_entry.get_widget(call.account, audio_encryption) : null;
            Plugins.CallEncryptionWidget? video_encryption_widgets = video_encryption_entry != null ? video_encryption_entry.get_widget(call.account, video_encryption) : null;
            if (audio_encryption_widgets != null && !has_video) {
                title = audio_encryption_widgets.get_title();
                icon_name = audio_encryption_widgets.get_icon_name();
                show_keys = audio_encryption_widgets.show_keys();
            } else if (video_encryption_widgets != null && !has_audio) {
                title = video_encryption_widgets.get_title();
                icon_name = video_encryption_widgets.get_icon_name();
                show_keys = video_encryption_widgets.show_keys();
            } else if (audio_encryption_widgets != null && video_encryption_widgets != null) {
                if (audio_encryption_widgets.get_title() == video_encryption_widgets.get_title())
                    title = audio_encryption_widgets.get_title();
                if (audio_encryption_widgets.get_icon_name() == video_encryption_widgets.get_icon_name())
                    icon_name = audio_encryption_widgets.get_icon_name();
                if (audio_encryption_widgets.show_keys() == video_encryption_widgets.show_keys())
                    show_keys = audio_encryption_widgets.show_keys();
            }
        }
        if (title == null && media_encryptions_are_plain_dtls_srtp(has_audio, audio_encryption, has_video, video_encryption)) {
            title = "This call is encrypted with DTLS-SRTP.";
            icon_name = "changes-prevent-symbolic";
            show_keys = encryption_has_keys(audio_encryption) || encryption_has_keys(video_encryption);
        }

        encryption_button.set_info(title, show_keys, has_audio, audio_encryption, has_video, video_encryption);
        encryption_button.set_icon((!has_audio || audio_encryption != null) && (!has_video || video_encryption != null), icon_name);
    }

    private static bool media_encryptions_are_plain_dtls_srtp(bool has_audio, Xep.Jingle.ContentEncryption? audio_encryption, bool has_video, Xep.Jingle.ContentEncryption? video_encryption) {
        if (!has_audio && !has_video) return false;
        if (has_audio && !is_plain_dtls_srtp_encryption(audio_encryption)) return false;
        if (has_video && !is_plain_dtls_srtp_encryption(video_encryption)) return false;
        return true;
    }

    private static bool is_plain_dtls_srtp_encryption(Xep.Jingle.ContentEncryption? encryption) {
        return encryption != null &&
            ((!) encryption).encryption_ns == Xep.JingleIceUdp.DTLS_NS_URI &&
            ((!) encryption).encryption_name == "DTLS-SRTP";
    }

    private static bool encryption_has_keys(Xep.Jingle.ContentEncryption? encryption) {
        return encryption != null &&
            (((!) encryption).our_key.length > 0 || ((!) encryption).peer_key.length > 0);
    }

    private void add_new_participant(string participant_id, Jid jid) {
        if (participant_widgets.has_key(participant_id)) {
            warning("[%s] Attempted to add same participant twice: %s", call.account.bare_jid.to_string(), jid.to_string());
            return;
        }
        debug("[%s] Call window controller | Add participant: %s", call.account.bare_jid.to_string(), jid.to_string());

        Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation(jid.bare_jid, call.account, Conversation.Type.CHAT);
        string participant_name = conversation != null ? Util.get_conversation_display_name(stream_interactor, conversation) : jid.bare_jid.to_string();

        ParticipantWidget participant_widget = new ParticipantWidget(participant_name);
        debug_info_handler_ids[participant_id] = participant_widget.debug_information_clicked.connect(() => {
            var conn_details_window = new CallConnectionDetailsWindow() { title=participant_name };
            if (peer_states.has_key(participant_id)) {
                conn_details_window.update_content(peer_states[participant_id].get_info());
            }
            uint timeout_handle_id = 0;
            timeout_handle_id = Timeout.add_seconds(1, () => {
                if (peer_states.has_key(participant_id)) {
                    conn_details_window.update_content(peer_states[participant_id].get_info());
                    return true;
                }
                timeout_handle_id = 0;
                return false;
            });
            conn_details_window.closed.connect(() => {
                if (timeout_handle_id > 0) {
                    Source.remove(timeout_handle_id);
                    timeout_handle_id = 0;
                }
            });
            conn_details_window.present(call_window);
            call_window_handler_ids += this.call_window.close_request.connect(() => {
                // Don't call conn_details_window.close() here — it triggers
                // recursive gtk_window_close on the already-closing parent,
                // causing a segfault.  The dialog is a child of call_window
                // and will be torn down automatically.  Just stop the timer.
                if (timeout_handle_id > 0) {
                    Source.remove(timeout_handle_id);
                    timeout_handle_id = 0;
                }
                return false;
            });
        });
        
        // Connect volume slider to stream volume control
        volume_handler_ids[participant_id] = participant_widget.volume_changed.connect((volume) => {
            if (uses_google_webrtc_jmi_call_engine) return;
            if (peer_states.has_key(participant_id)) {
                var audio_stream = peer_states[participant_id].get_audio_stream();
                if (audio_stream != null) {
                    require_legacy_call_plugin().set_stream_volume(
                        audio_stream, volume);
                }
            }
        });
        
        participant_widgets[participant_id] = participant_widget;

        call_window.add_participant(participant_id, participant_widget);

        if (!uses_google_webrtc_jmi_call_engine) {
            participant_videos[participant_id] = require_legacy_call_plugin()
                .create_widget(Plugins.WidgetType.GTK4);

            participant_video_resolution_handler_ids[participant_id] = participant_videos[participant_id].resolution_changed.connect((width, height) => {
                if (window_size_changed || participant_widgets.size > 1) return;
                if (width == 0 || height == 0) return;
                if (width > height) {
                    call_window.default_width = 704;
                    call_window.default_height = (int) (height * 704 / width);
                } else {
                    call_window.default_width = (int) (width * 704 / height);
                    call_window.default_height = 704;
                }
                capture_window_size();
            });
        } else {
            create_google_webrtc_jmi_video_widget(participant_id);
        }

        participant_widget.set_placeholder(conversation, stream_interactor);
        if (call.direction == Call.DIRECTION_INCOMING) {
            call_window.set_status(participant_id, "establishing");
        } else {
            call_window.set_status(participant_id, "requested");
        }
    }

    private void remove_participant(string participant_id) {
        if (peer_states.has_key(participant_id)) debug(@"[%s] Call window controller | Remove participant: %s", call.account.bare_jid.to_string(), peer_states[participant_id].jid.to_string());

        // Disconnect per-peer PeerState signal handlers
        if (peer_states.has_key(participant_id)) {
            PeerState ps = peer_states[participant_id];
            ulong hid;
            if (peer_connection_ready_handler_ids.has_key(participant_id)) {
                hid = peer_connection_ready_handler_ids[participant_id];
                if (hid != 0 && SignalHandler.is_connected(ps, hid)) ps.disconnect(hid);
            }
            if (peer_video_updated_handler_ids.has_key(participant_id)) {
                hid = peer_video_updated_handler_ids[participant_id];
                if (hid != 0 && SignalHandler.is_connected(ps, hid)) ps.disconnect(hid);
            }
            if (peer_google_webrtc_jmi_video_frame_handler_ids.has_key(participant_id)) {
                hid = peer_google_webrtc_jmi_video_frame_handler_ids[participant_id];
                if (hid != 0 && SignalHandler.is_connected(ps, hid)) ps.disconnect(hid);
            }
            if (peer_google_webrtc_jmi_local_video_frame_handler_ids.has_key(participant_id)) {
                hid = peer_google_webrtc_jmi_local_video_frame_handler_ids[participant_id];
                if (hid != 0 && SignalHandler.is_connected(ps, hid)) ps.disconnect(hid);
            }
            if (peer_info_received_handler_ids.has_key(participant_id)) {
                hid = peer_info_received_handler_ids[participant_id];
                if (hid != 0 && SignalHandler.is_connected(ps, hid)) ps.disconnect(hid);
            }
            if (peer_encryption_handler_ids.has_key(participant_id)) {
                hid = peer_encryption_handler_ids[participant_id];
                if (hid != 0 && SignalHandler.is_connected(ps, hid)) ps.disconnect(hid);
            }
        }
        peer_connection_ready_handler_ids.unset(participant_id);
        peer_video_updated_handler_ids.unset(participant_id);
        peer_google_webrtc_jmi_video_frame_handler_ids.unset(participant_id);
        peer_google_webrtc_jmi_local_video_frame_handler_ids.unset(participant_id);
        peer_info_received_handler_ids.unset(participant_id);
        peer_encryption_handler_ids.unset(participant_id);

        // Disconnect participant video resolution handler
        if (participant_video_resolution_handler_ids.has_key(participant_id) && participant_videos.has_key(participant_id)) {
            ulong hid = participant_video_resolution_handler_ids[participant_id];
            if (hid != 0 && SignalHandler.is_connected(participant_videos[participant_id], hid)) {
                participant_videos[participant_id].disconnect(hid);
            }
        }
        participant_video_resolution_handler_ids.unset(participant_id);

        if (google_webrtc_jmi_video_resolution_handler_ids.has_key(participant_id) && google_webrtc_jmi_participant_videos.has_key(participant_id)) {
            ulong hid = google_webrtc_jmi_video_resolution_handler_ids[participant_id];
            if (hid != 0 && SignalHandler.is_connected(google_webrtc_jmi_participant_videos[participant_id], hid)) {
                google_webrtc_jmi_participant_videos[participant_id].disconnect(hid);
            }
        }
        google_webrtc_jmi_video_resolution_handler_ids.unset(participant_id);
        if (google_webrtc_jmi_participant_videos.has_key(participant_id)) {
            google_webrtc_jmi_participant_videos[participant_id].detach();
        }
        google_webrtc_jmi_participant_videos.unset(participant_id);

        // Detach video widget GStreamer elements before removing reference
        if (participant_videos.has_key(participant_id)) {
            participant_videos[participant_id].detach();
        }
        participant_videos.unset(participant_id);

        // Disconnect participant widget signal handlers
        if (participant_widgets.has_key(participant_id)) {
            if (debug_info_handler_ids.has_key(participant_id)) {
                ulong hid = debug_info_handler_ids[participant_id];
                if (hid != 0 && SignalHandler.is_connected(participant_widgets[participant_id], hid)) {
                    participant_widgets[participant_id].disconnect(hid);
                }
            }
            if (volume_handler_ids.has_key(participant_id)) {
                ulong hid = volume_handler_ids[participant_id];
                if (hid != 0 && SignalHandler.is_connected(participant_widgets[participant_id], hid)) {
                    participant_widgets[participant_id].disconnect(hid);
                }
            }
        }
        participant_widgets.unset(participant_id);
        debug_info_handler_ids.unset(participant_id);
        volume_handler_ids.unset(participant_id);
        peer_states.unset(participant_id);
        call_window.remove_participant(participant_id);
    }

    private void capture_window_size() {
        this.window_height = this.call_window.get_height();
        this.window_width = this.call_window.get_width();
    }

    private Plugins.VideoCallPlugin require_legacy_call_plugin() {
        assert(!uses_google_webrtc_jmi_call_engine);
        assert(call_plugin != null);
        return (!) call_plugin;
    }

    private void update_audio_device_choices() {
        Plugins.VideoCallPlugin plugin = require_legacy_call_plugin();
        if (plugin.get_devices("audio", true).size == 0 || plugin.get_devices("audio", false).size == 0) {
            call_window.bottom_bar.show_audio_device_error();
        }

        AudioSettingsPopover? audio_settings_popover = call_window.bottom_bar.show_audio_device_choices(true);
        update_current_audio_device(audio_settings_popover);

        audio_settings_popover.microphone_selected.connect((device) => {
            if (call_state == null) return;
            call_state.set_audio_device(device);
            ((Dino.Application) GLib.Application.get_default()).settings.call_audio_input_device = device.display_name;
            update_current_audio_device(audio_settings_popover);
        });
        audio_settings_popover.speaker_selected.connect((device) => {
            if (call_state == null) return;
            call_state.set_audio_device(device);
            ((Dino.Application) GLib.Application.get_default()).settings.call_audio_output_device = device.display_name;
            update_current_audio_device(audio_settings_popover);
        });
        audio_settings_popover.microphone_volume_changed.connect((volume) => {
            if (call_state == null) return;
            var device = call_state.get_microphone_device();
            if (device != null) {
                plugin.set_device_volume(device, volume);
            }
        });
        audio_settings_popover.speaker_volume_changed.connect((volume) => {
            if (call_state == null) return;
            var device = call_state.get_speaker_device();
            if (device != null) {
                plugin.set_device_volume(device, volume);
            }
        });

        audio_settings_popover.digital_gain_changed.connect((gain_db, manual_mode) => {
            debug("CallWindowController: gain_db=%d manual=%s", gain_db, manual_mode.to_string());
            plugin.set_digital_gain_db(gain_db, manual_mode);
        });
    }

    private void update_google_webrtc_jmi_audio_device_choices() {
        Plugins.JmiCallEnginePlugin? jmi_call_engine = selected_jmi_call_engine;
        if (jmi_call_engine == null) {
            call_window.bottom_bar.show_audio_device_error();
            return;
        }

        Gee.List<Plugins.MediaDevice> microphones = jmi_call_engine.get_audio_devices(false);
        Gee.List<Plugins.MediaDevice> speakers = jmi_call_engine.get_audio_devices(true);
        if (microphones.size == 0 || speakers.size == 0) {
            call_window.bottom_bar.show_audio_device_error();
        }

        Dino.Entities.Settings settings = ((Dino.Application) GLib.Application.get_default()).settings;
        if (google_webrtc_jmi_microphone_device == null) {
            google_webrtc_jmi_microphone_device = pick_google_webrtc_jmi_audio_device(microphones, settings.call_audio_input_device);
        }
        if (google_webrtc_jmi_speaker_device == null) {
            google_webrtc_jmi_speaker_device = pick_google_webrtc_jmi_audio_device(speakers, settings.call_audio_output_device);
        }
        apply_google_webrtc_jmi_audio_device(google_webrtc_jmi_microphone_device, false, jmi_call_engine);
        apply_google_webrtc_jmi_audio_device(google_webrtc_jmi_speaker_device, true, jmi_call_engine);

        AudioSettingsPopover? audio_settings_popover = call_window.bottom_bar.show_audio_device_choices(true, microphones, speakers, false);
        update_current_google_webrtc_jmi_audio_device(audio_settings_popover, jmi_call_engine);

        audio_settings_popover.microphone_selected.connect((device) => {
            google_webrtc_jmi_microphone_device = device;
            try {
                jmi_call_engine.set_audio_device(device);
                settings.call_audio_input_device = media_device_settings_value(device);
            } catch (Error e) {
                warning("Failed to select Google/libwebrtc microphone device '%s': %s", device.display_name, e.message);
                call_window.bottom_bar.show_audio_device_error();
            }
            update_current_google_webrtc_jmi_audio_device(audio_settings_popover, jmi_call_engine);
        });
        audio_settings_popover.speaker_selected.connect((device) => {
            google_webrtc_jmi_speaker_device = device;
            try {
                jmi_call_engine.set_audio_device(device);
                settings.call_audio_output_device = media_device_settings_value(device);
            } catch (Error e) {
                warning("Failed to select Google/libwebrtc speaker device '%s': %s", device.display_name, e.message);
                call_window.bottom_bar.show_audio_device_error();
            }
            update_current_google_webrtc_jmi_audio_device(audio_settings_popover, jmi_call_engine);
        });
        audio_settings_popover.microphone_volume_changed.connect((volume) => {
            if (closing || call_has_terminated || google_webrtc_jmi_microphone_device == null) return;
            try {
                jmi_call_engine.set_audio_device_volume(google_webrtc_jmi_microphone_device, volume);
            } catch (Error e) {
                warning("Failed to set Google/libwebrtc microphone volume: %s", e.message);
            }
        });
        audio_settings_popover.speaker_volume_changed.connect((volume) => {
            if (closing || call_has_terminated || google_webrtc_jmi_speaker_device == null) return;
            try {
                jmi_call_engine.set_audio_device_volume(google_webrtc_jmi_speaker_device, volume);
            } catch (Error e) {
                warning("Failed to set Google/libwebrtc speaker volume: %s", e.message);
            }
        });
    }

    private Plugins.MediaDevice? pick_google_webrtc_jmi_audio_device(Gee.List<Plugins.MediaDevice> devices, string saved_value) {
        if (saved_value != "") {
            Plugins.MediaDevice? selected = Plugins.MediaDeviceSelection.find(devices, saved_value);
            if (selected != null) return selected;
        }
        if (!devices.is_empty) return devices.first();
        return null;
    }

    private void apply_google_webrtc_jmi_audio_device(Plugins.MediaDevice? device, bool incoming, Plugins.JmiCallEnginePlugin jmi_call_engine) {
        if (device == null) return;
        try {
            jmi_call_engine.set_audio_device((!) device);
        } catch (Error e) {
            warning(
                "Failed to select initial Google/libwebrtc %s device '%s': %s",
                incoming ? "speaker" : "microphone",
                ((!) device).display_name,
                e.message);
            call_window.bottom_bar.show_audio_device_error();
        }
    }

    private void update_current_google_webrtc_jmi_audio_device(AudioSettingsPopover audio_settings_popover, Plugins.JmiCallEnginePlugin jmi_call_engine) {
        audio_settings_popover.current_microphone_device = google_webrtc_jmi_microphone_device;
        audio_settings_popover.current_speaker_device = google_webrtc_jmi_speaker_device;
        audio_settings_popover.set_microphone_volume(jmi_call_engine.get_audio_device_volume(google_webrtc_jmi_microphone_device));
        audio_settings_popover.set_speaker_volume(jmi_call_engine.get_audio_device_volume(google_webrtc_jmi_speaker_device));
    }

    private void update_google_webrtc_jmi_video_device_choices() {
        if (!call_state.should_we_send_video()) {
            call_window.bottom_bar.show_video_device_choices(false);
            return;
        }

        Plugins.JmiCallEnginePlugin? jmi_call_engine = selected_jmi_call_engine;
        if (jmi_call_engine == null) {
            call_window.bottom_bar.show_video_device_error();
            return;
        }

        Gee.List<Plugins.MediaDevice> cameras = jmi_call_engine.get_video_devices();
        if (cameras.size == 0) {
            call_window.bottom_bar.show_video_device_error();
            return;
        }

        Plugins.MediaDevice? selected_camera = call_state.get_video_device();
        if (selected_camera == null) {
            selected_camera = jmi_call_engine.get_preferred_video_device();
        }
        if (selected_camera != null) {
            call_state.set_video_device((!) selected_camera);
        }

        if (cameras.size == 1 || call_state.get_video_device() == null) {
            call_window.bottom_bar.show_video_device_choices(false);
            return;
        }

        VideoSettingsPopover? video_settings_popover = call_window.bottom_bar.show_video_device_choices(true, cameras);
        update_current_video_device(video_settings_popover);

        video_settings_popover.camera_selected.connect((device) => {
            call_state.set_video_device(device);
            ((Dino.Application) GLib.Application.get_default()).settings.call_video_device = media_device_settings_value(device);
            update_current_video_device(video_settings_popover);
        });
    }

    private async void stage_background_image(uint builtin_choice, uint64 generation) {
        CallState owner = call_state;
        VideoEffectsPopover? controls = call_window.bottom_bar.video_effects_popover;
        if (!owns_live_call_state(owner) || controls == null || !((!) controls).accepts_background_result(generation)) return;
        try {
            yield owner.wait_for_video_background_concealment(background_image_cancellable);
            if (!owns_live_call_state(owner) || !((!) controls).accepts_background_result(generation)) return;
            Plugins.JmiVideoBackgroundImage? pixels = null;
            if (builtin_choice == 0) {
                if (background_image_load_busy) throw new IOError.PENDING("A background image is already loading");
                background_image_load_busy = true;
                try {
                    var chooser = new FileDialog() { title=_("Choose background image") };
                    var filter = new FileFilter() { name=_("PNG and JPEG images") };
                    filter.add_mime_type("image/png"); filter.add_mime_type("image/jpeg");
                    var filters = new GLib.ListStore(typeof(FileFilter)); filters.append(filter);
                    chooser.filters = filters; chooser.default_filter = filter;
                    File? file = yield chooser.open(call_window, background_image_cancellable);
                    if (file == null) throw new IOError.CANCELLED("No background image was selected");
                    if (!owns_live_call_state(owner) || !((!) controls).accepts_background_result(generation)) return;
                    pixels = yield VideoBackgroundImageLoader.load((!) file, background_image_cancellable);
                } finally { background_image_load_busy = false; }
            }
            if (!owns_live_call_state(owner) || !((!) controls).accepts_background_result(generation)) return;
            uint asset = yield owner.stage_video_background(builtin_choice, pixels);
            if (!owns_live_call_state(owner) || call_window.bottom_bar.video_effects_popover != controls ||
                    !((!) controls).accepts_background_result(generation)) {
                try { yield owner.release_video_background(asset); } catch (Error ignored) { }
                return;
            }
            ((!) controls).finish_background_image(generation, asset);
        } catch (Error e) {
            if (!owns_live_call_state(owner) || call_window.bottom_bar.video_effects_popover != controls) return;
            ((!) controls).fail_background_image(generation);
            debug("Background image staging did not complete: %s", e.message);
        }
    }

    private void update_video_effect_controls() {
        if (closing || call_has_terminated || call_state == null) return;

        bool group_call = call_state.group_call != null;
        bool show = call_state.has_video_media() &&
            (uses_google_webrtc_jmi_call_engine || group_call);
        if (!show) {
            call_window.bottom_bar.show_video_effect_choices(false);
            return;
        }

        Plugins.JmiVideoEffectCapabilities capabilities =
            call_state.get_video_effect_capabilities();
        Plugins.JmiVideoEffectStatus status = call_state.get_video_effect_status();
        string? unavailable_hint = null;
        if (!capabilities.available) {
            switch (capabilities.unavailable_reason) {
                case Plugins.JmiVideoEffectUnavailableReason.GROUP_CALL:
                    unavailable_hint = _("Video effects are not available in group calls.");
                    break;
                case Plugins.JmiVideoEffectUnavailableReason.AUDIO_ONLY:
                    unavailable_hint = _("Video effects are not available in audio-only calls.");
                    break;
                default:
                    unavailable_hint = _("Video effects are not available.");
                    break;
            }
        }

        call_window.bottom_bar.show_video_effect_choices(
            true, capabilities, status, unavailable_hint);
    }

    private static string media_device_settings_value(Plugins.MediaDevice device) {
        string id = device.persistent_id;
        if (id != "") return id;
        return device.display_name;
    }

    private void update_current_audio_device(AudioSettingsPopover audio_settings_popover) {
        Plugins.VideoCallPlugin plugin = require_legacy_call_plugin();
        if (call_state == null) return;
        audio_settings_popover.current_microphone_device = call_state.get_microphone_device();
        audio_settings_popover.current_speaker_device = call_state.get_speaker_device();
        // Update volume sliders
        var mic = call_state.get_microphone_device();
        var speaker = call_state.get_speaker_device();
        if (mic != null) {
            audio_settings_popover.set_microphone_volume(plugin.get_device_volume(mic));
        }
        if (speaker != null) {
            audio_settings_popover.set_speaker_volume(plugin.get_device_volume(speaker));
        }
    }

    private void update_video_device_choices() {
        Plugins.VideoCallPlugin plugin = require_legacy_call_plugin();
        int device_count = plugin.get_devices("video", false).size;

        if (device_count == 0) {
            call_window.bottom_bar.show_video_device_error();
        } else if (device_count == 1 || call_state.get_video_device() == null) {
            call_window.bottom_bar.show_video_device_choices(false);
            return;
        }

        VideoSettingsPopover? video_settings_popover = call_window.bottom_bar.show_video_device_choices(true);
        update_current_video_device(video_settings_popover);

        video_settings_popover.camera_selected.connect((device) => {
            call_state.set_video_device(device);
            ((Dino.Application) GLib.Application.get_default()).settings.call_video_device = device.display_name;
            update_current_video_device(video_settings_popover);
            own_video.display_device(device);
        });
    }

    private void update_current_video_device(VideoSettingsPopover video_settings_popover) {
        video_settings_popover.current_device = call_state.get_video_device();
    }

    private void update_own_video() {
        if (uses_google_webrtc_jmi_call_engine || own_video == null) {
            if (!uses_google_webrtc_jmi_call_engine) {
                call_window.unset_own_video();
            }
            return;
        }
        if (this.call_window.bottom_bar.video_enabled) {
            Gee.List<Plugins.MediaDevice> devices = require_legacy_call_plugin()
                .get_devices("video", false);
            if (!(own_video is Widget) || devices.is_empty) {
                call_window.set_own_video(null);
            } else {
                Widget widget = (Widget) own_video;
                call_window.set_own_video(widget);
                own_video.display_device(call_state.get_video_device());
            }
        } else {
            ((!) own_video).detach();
            call_window.unset_own_video();
        }
    }

    private void detach_google_webrtc_jmi_own_video() {
        if (google_webrtc_jmi_own_video == null) return;

        if (google_webrtc_jmi_own_video_resolution_handler_id != 0 &&
                SignalHandler.is_connected((!) google_webrtc_jmi_own_video, google_webrtc_jmi_own_video_resolution_handler_id)) {
            ((!) google_webrtc_jmi_own_video).disconnect(google_webrtc_jmi_own_video_resolution_handler_id);
        }
        google_webrtc_jmi_own_video_resolution_handler_id = 0;
        ((!) google_webrtc_jmi_own_video).detach();
        call_window.unset_own_video();
        google_webrtc_jmi_own_video = null;
    }

    /** Detach all video widgets to release GStreamer sinks/textures immediately. */
    private void detach_all_video() {
        debug("detach_all_video(): %d participant videos, own_video=%s", participant_videos.size, (own_video != null).to_string());
        foreach (string participant_id in participant_videos.keys) {
            participant_videos[participant_id].detach();
        }
        foreach (string participant_id in google_webrtc_jmi_participant_videos.keys) {
            google_webrtc_jmi_participant_videos[participant_id].detach();
        }
        detach_google_webrtc_jmi_own_video();
        if (own_video != null) {
            if (own_video_resolution_handler_id != 0 && SignalHandler.is_connected(own_video, own_video_resolution_handler_id)) {
                own_video.disconnect(own_video_resolution_handler_id);
            }
            own_video_resolution_handler_id = 0;
            own_video.detach();
            call_window.unset_own_video();
            own_video = null;
        }
    }

    private void cleanup() {
        background_image_cancellable.cancel();
        if (cleaned_up) return;
        cleaned_up = true;
        async_generation++;
        closing = true; // Signal all handlers to ignore events
        close_participant_invite_dialog();
        refresh_participant_invite_control();
        debug("CallWindowController.cleanup() called");

        // Let child controls release transient resources before teardown.
        call_window.shutdown_transient_ui();
        stop_call_duration_timer();
        detach_all_video();

        if (call_state_notify_handler_id != 0 && SignalHandler.is_connected(call, call_state_notify_handler_id)) {
            call.disconnect(call_state_notify_handler_id);
        }
        call_state_notify_handler_id = 0;
        if (invite_connection_state_handler_id != 0 &&
                SignalHandler.is_connected(stream_interactor.connection_manager,
                    invite_connection_state_handler_id)) {
            stream_interactor.connection_manager.disconnect(
                invite_connection_state_handler_id);
        }
        invite_connection_state_handler_id = 0;

        // Disconnect from the singleton Calls module
        if (calls_conference_info_handler_id != 0 && SignalHandler.is_connected(calls, calls_conference_info_handler_id)) {
            calls.disconnect(calls_conference_info_handler_id);
        }
        calls_conference_info_handler_id = 0;

        // Disconnect from call_state
        if (call_state != null) {
        if (call_state_terminated_handler_id != 0 && SignalHandler.is_connected(call_state, call_state_terminated_handler_id)) {
            call_state.disconnect(call_state_terminated_handler_id);
        }
        if (call_state_peer_joined_handler_id != 0 && SignalHandler.is_connected(call_state, call_state_peer_joined_handler_id)) {
            call_state.disconnect(call_state_peer_joined_handler_id);
        }
        if (call_state_peer_left_handler_id != 0 && SignalHandler.is_connected(call_state, call_state_peer_left_handler_id)) {
            call_state.disconnect(call_state_peer_left_handler_id);
        }
        if (call_state_video_effect_handler_id != 0 && SignalHandler.is_connected(call_state, call_state_video_effect_handler_id)) {
            call_state.disconnect(call_state_video_effect_handler_id);
        }
        if (call_state_group_call_handler_id != 0 && SignalHandler.is_connected(call_state, call_state_group_call_handler_id)) {
            call_state.disconnect(call_state_group_call_handler_id);
        }
        if (call_state_video_mode_handler_id != 0 && SignalHandler.is_connected(call_state, call_state_video_mode_handler_id)) {
            call_state.disconnect(call_state_video_mode_handler_id);
        }
        if (call_state_invite_capability_handler_id != 0 &&
                SignalHandler.is_connected(call_state,
                    call_state_invite_capability_handler_id)) {
            call_state.disconnect(call_state_invite_capability_handler_id);
        }
        }
        call_state_terminated_handler_id = call_state_peer_joined_handler_id = call_state_peer_left_handler_id = 0;
        call_state_video_effect_handler_id = call_state_group_call_handler_id = 0;
        call_state_video_mode_handler_id = 0;
        call_state_invite_capability_handler_id = 0;
        if (call_state_invite_availability_handler_id != 0 &&
                SignalHandler.is_connected(call_state,
                    call_state_invite_availability_handler_id)) {
            call_state.disconnect(call_state_invite_availability_handler_id);
        }
        call_state_invite_availability_handler_id = 0;

        disconnect_group_call_participant_list();

        // Disconnect from the singleton call_plugin
        if (devices_changed_handler_id != 0) {
            require_legacy_call_plugin().disconnect(devices_changed_handler_id);
            devices_changed_handler_id = 0;
        }

        foreach (ulong handler_id in call_window_handler_ids) {
            if (handler_id != 0 && SignalHandler.is_connected(call_window, handler_id)) {
                call_window.disconnect(handler_id);
            }
        }
        foreach (ulong handler_id in bottom_bar_handler_ids) {
            if (handler_id != 0 && SignalHandler.is_connected(call_window.bottom_bar, handler_id)) {
                call_window.bottom_bar.disconnect(handler_id);
            }
        }

        var participant_ids = new ArrayList<string>();
        participant_ids.add_all(participant_widgets.keys);
        foreach (string participant_id in participant_ids) {
            remove_participant(participant_id);
        }

        call_window_handler_ids = bottom_bar_handler_ids = new ulong[0];

        if (own_video != null) {
            if (own_video_resolution_handler_id != 0 && SignalHandler.is_connected(own_video, own_video_resolution_handler_id)) {
                own_video.disconnect(own_video_resolution_handler_id);
            }
            own_video_resolution_handler_id = 0;
            own_video.detach();
            call_window.unset_own_video();
            own_video = null;
        }

        if (close_timeout_id != 0) {
            Source.remove(close_timeout_id);
            close_timeout_id = 0;
        }

        // Break references
        call_window.controller = null;
        call_state = null;

#if HAVE_MALLOC_TRIM
        malloc_trim(0);
        Timeout.add(500, () => {
            malloc_trim(0);
            return Source.REMOVE;
        });
#endif
    }

    public override void dispose() {
        cleanup();
        base.dispose();
    }

    private void setup_group_call_participant_list() {
        if (closing || cleaned_up) return;
        Xep.Muji.GroupCall? current_group_call = call_state.group_call;
        if (current_group_call == observed_group_call) return;
        disconnect_group_call_participant_list();
        if (current_group_call == null) {
            call_window.show_participant_list(false);
            return;
        }
        observed_group_call = current_group_call;
        Xep.Muji.GroupCall active_group_call = (!) current_group_call;
        
        // Show the participant list sidebar
        call_window.show_participant_list(true);
        
        // Add ourselves
        call_window.add_group_call_participant(call.account.bare_jid, _("Me"));
        call_window.set_group_call_participant_status(call.account.bare_jid, true);
        
        // Initial ready peers are real full JIDs; later peers are MUC occupants.
        var real_peers = new HashSet<Jid>(Jid.hash_func, Jid.equals_func);
        real_peers.add_all(active_group_call.peers_to_connect_to);
        real_peers.add_all(active_group_call.peers_to_wait_for);
        foreach (Jid peer_jid in active_group_call.peers) {
            Jid? real_jid = active_group_call.real_jids[peer_jid];
            if (real_jid != null) real_peers.add(real_jid);
        }
        foreach (Jid real_jid in real_peers) {
            string display_name = get_participant_display_name(real_jid);
            call_window.add_group_call_participant(real_jid, display_name);
            call_window.set_group_call_participant_status(real_jid, true);
        }
        
        // Listen for new participants joining
        group_call_peer_joined_handler_id = active_group_call.peer_joined.connect((real_jid) => {
            if (observed_group_call != active_group_call) return;
            string display_name = get_participant_display_name(real_jid);
            call_window.add_group_call_participant(real_jid, display_name);
            call_window.set_group_call_participant_status(real_jid, true);
        });
        
        // Listen for participants leaving
        group_call_peer_left_handler_id = active_group_call.peer_left.connect((real_jid) => {
            if (observed_group_call != active_group_call) return;
            call_window.remove_group_call_participant(real_jid);
        });
    }

    private void disconnect_group_call_participant_list() {
        if (observed_group_call != null) {
            Xep.Muji.GroupCall old_group_call = (!) observed_group_call;
            if (group_call_peer_joined_handler_id != 0 &&
                    SignalHandler.is_connected(old_group_call,
                        group_call_peer_joined_handler_id)) {
                SignalHandler.disconnect(old_group_call,
                    group_call_peer_joined_handler_id);
            }
            if (group_call_peer_left_handler_id != 0 &&
                    SignalHandler.is_connected(old_group_call,
                        group_call_peer_left_handler_id)) {
                SignalHandler.disconnect(old_group_call,
                    group_call_peer_left_handler_id);
            }
        }
        group_call_peer_joined_handler_id = 0;
        group_call_peer_left_handler_id = 0;
        observed_group_call = null;
    }
    
    private string get_participant_display_name(Jid jid) {
        Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation(jid.bare_jid, call.account, Conversation.Type.CHAT);
        if (conversation != null) {
            return Util.get_conversation_display_name(stream_interactor, conversation);
        }
        return jid.bare_jid.to_string();
    }
}
