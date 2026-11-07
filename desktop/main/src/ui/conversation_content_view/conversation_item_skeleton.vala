using Gee;
using Gdk;
using Gtk;
using Markup;

using Dino.Entities;

namespace Dino.Ui.ConversationSummary {

public class ConversationItemSkeleton : Plugins.ConversationItemWidgetInterface, Object {

    public Grid main_grid { get; set; }
    public Label name_label { get; set; }
    public Label time_label { get; set; }
    public AvatarPicture avatar_picture { get; set; }
    public Image encryption_image { get; set; }
    public Image received_image { get; set; }
    public Label mention_indicator_label { get; set; }
    private Box header_box;

    private HashMap<int, Widget> content_widgets = new HashMap<int, Widget>();

    private bool show_skeleton_ = false;
    private bool requested_skeleton = false;
    public bool show_skeleton {
        get { return show_skeleton_; }
        set {
            requested_skeleton = value;
            // Mentions always keep their metadata visible, even when adjacent
            // messages from the same sender would otherwise share a header.
            show_skeleton_ = (value || has_mention) && content_meta_item != null &&
                content_meta_item.requires_header && content_meta_item.requires_avatar;
        }
    }

    public StreamInteractor stream_interactor;
    public Conversation conversation { get; set; }
    public Plugins.MetaConversationItem item;
    public bool item_in_edit_mode { get; set; }
    public Entities.Message.Marked item_mark { get; set; }
    public ContentMetaItem content_meta_item = null;
    public Widget? widget = null;
    private ReactionsController? reactions_controller = null;
    private MessageMentionPresentation? mention_presentation;
    public bool has_mention {
        get { return mention_presentation != null && ((!) mention_presentation).mentioned; }
    }
    public signal void mention_changed();

    private Binding? edit_mode_binding = null;
    private Binding? mark_binding = null;
    private bool _skeleton_disposed = false;
    private Dino.Ui.OccupantMenu.View? active_occupant_menu = null;
    private bool avatar_menu_pending = false;
    private uint avatar_menu_source = 0;

    private class AvatarMenuBinding : Object {
        private WeakRef skeleton_weak;
        private WeakRef menu_weak;
        private WeakRef anchor_weak;
        private uint position_tick_id = 0;
        private bool has_last_bounds = false;
        private int last_x = 0;
        private int last_y = 0;
        private int last_width = 0;
        private int last_height = 0;

        public AvatarMenuBinding(ConversationItemSkeleton skeleton,
                Dino.Ui.OccupantMenu.View menu, AvatarPicture anchor) {
            skeleton_weak = WeakRef(skeleton);
            menu_weak = WeakRef(menu);
            anchor_weak = WeakRef(anchor);
            position_tick_id = menu.add_tick_callback(on_position_tick);
        }

        public void on_closed() {
            ConversationItemSkeleton? skeleton =
                (ConversationItemSkeleton?) skeleton_weak.get();
            Dino.Ui.OccupantMenu.View? closed_menu =
                (Dino.Ui.OccupantMenu.View?) menu_weak.get();
            if (closed_menu == null) return;

            if (position_tick_id != 0) {
                ((!) closed_menu).remove_tick_callback(position_tick_id);
                position_tick_id = 0;
            }
            // View owns the version-gated GTK tooltip-surface grace period.
            ((!) closed_menu).detach_safely_after_close();
            if (skeleton != null &&
                    ((!) skeleton).active_occupant_menu == closed_menu) {
                ((!) skeleton).active_occupant_menu = null;
            }
        }

        private bool on_position_tick(Widget widget, Gdk.FrameClock frame_clock) {
            Dino.Ui.OccupantMenu.View? menu =
                (Dino.Ui.OccupantMenu.View?) menu_weak.get();
            AvatarPicture? anchor = (AvatarPicture?) anchor_weak.get();
            Widget? parent = menu != null ? ((!) menu).get_parent() : null;
            if (menu == null || parent == null || !((!) menu).visible) {
                position_tick_id = 0;
                return Source.REMOVE;
            }
            if (anchor == null) {
                position_tick_id = 0;
                ((!) menu).popdown_for_lifecycle();
                return Source.REMOVE;
            }

            Graphene.Rect bounds;
            if (!((!) anchor).compute_bounds((!) parent, out bounds)) {
                position_tick_id = 0;
                ((!) menu).popdown_for_lifecycle();
                return Source.REMOVE;
            }
            int x = (int) bounds.origin.x;
            int y = (int) bounds.origin.y;
            int width = (int) bounds.size.width;
            int height = (int) bounds.size.height;
            if (has_last_bounds && x == last_x && y == last_y &&
                    width == last_width && height == last_height) {
                return Source.CONTINUE;
            }
            has_last_bounds = true;
            last_x = x;
            last_y = y;
            last_width = width;
            last_height = height;
            ((!) menu).set_pointing_to({
                x, y, width, height
            });
            return Source.CONTINUE;
        }
    }

    private static void connect_avatar_menu_binding(
            Dino.Ui.OccupantMenu.View menu, AvatarMenuBinding binding) {
        // A static bridge makes the signal closure own only the binding. The
        // binding itself keeps weak references, so neither the menu nor its
        // originating message row participates in a reference cycle.
        menu.closed.connect(() => binding.on_closed());
    }

    private bool defer_heavy_work = false;
    private bool header_initialized = false;
    private bool content_initialized = false;
    private bool avatar_initialized = false;

    private uint time_update_timeout = 0;
    private ulong updated_roster_handler_id = 0;
    private ulong notify_edit_mode_handler_id = 0;
    private ulong notify_show_skeleton1_handler_id = 0;
    private ulong notify_show_skeleton2_handler_id = 0;
    private ulong notify_item_mark_handler_id = 0;
    private ulong groupchat_displayed_state_handler_id = 0;

    public ConversationItemSkeleton(StreamInteractor stream_interactor, Conversation conversation, Plugins.MetaConversationItem item, bool defer_heavy_work = false) {
        this.stream_interactor = stream_interactor;
        this.conversation = conversation;
        this.item = item;
        this.content_meta_item = item as ContentMetaItem;
        this.defer_heavy_work = defer_heavy_work;

        edit_mode_binding = item.bind_property("in-edit-mode", this, "item-in-edit-mode");
        notify_edit_mode_handler_id = this.notify["item-in-edit-mode"].connect(update_edit_mode);

        int64 t_builder_us = Dino.Ui.UiTiming.now_us();
        Builder builder = new Builder.from_resource("/im/dinox/dinox/conversation_item_widget.ui");
        Dino.Ui.UiTiming.log_ms("ConversationItemSkeleton.constructor: builder", t_builder_us);
        main_grid = (Grid) builder.get_object("main_grid");
        main_grid.add_css_class("message-box");
        header_box = (Box) builder.get_object("header_box");
        
        name_label = (Label) builder.get_object("name_label");
        mention_indicator_label = (Label) builder.get_object("mention_indicator_label");
        time_label = (Label) builder.get_object("time_label");
        avatar_picture = (AvatarPicture) builder.get_object("avatar_picture");
        encryption_image = (Image) builder.get_object("encrypted_image");
        received_image = (Image) builder.get_object("marked_image");

        if (content_meta_item != null) {
            mention_presentation = new MessageMentionPresentation(stream_interactor,
                conversation, content_meta_item.content_item, main_grid,
                mention_indicator_label);
            WeakRef skeleton_weak = WeakRef(this);
            ((!) mention_presentation).changed.connect(() => {
                var skeleton = (ConversationItemSkeleton?) skeleton_weak.get();
                if (skeleton != null) ((!) skeleton).on_mention_changed();
            });
        }

        if (!defer_heavy_work) {
            ensure_avatar_initialized();
            ensure_content_initialized();
        }

        // Signal connections and margin must run immediately (not deferred),
        // otherwise set_header() is never called and encryption/mark icons
        // are never initialized.
        notify_show_skeleton1_handler_id = this.notify["show-skeleton"].connect(update_margin);
        notify_show_skeleton2_handler_id = this.notify["show-skeleton"].connect(set_header);

        update_margin();
    }

    internal static void queue_initialization(ConversationItemSkeleton owner,
            FrameRenderQueue queue) {
        if (!owner.defer_heavy_work) return;
        var owner_ref = WeakRef(owner);
        queue.add(() => {
            var skeleton = owner_ref.get() as ConversationItemSkeleton;
            if (skeleton == null || skeleton._skeleton_disposed ||
                    skeleton.main_grid.parent == null) return;
            skeleton.defer_heavy_work = false;
            skeleton.ensure_avatar_initialized();
            skeleton.ensure_content_initialized();
            skeleton.set_header();
        });
    }

    private void ensure_avatar_initialized() {
        if (avatar_initialized) return;
        avatar_initialized = true;

        if (item.requires_header) {
            // TODO: For MUC messags, use real jid from message if known
            avatar_picture.model = new ViewModel.CompatAvatarPictureModel(stream_interactor).add_participant(conversation, item.jid);

            var click_controller = new Gtk.GestureClick();
            click_controller.button = 0;
            click_controller.pressed.connect(on_avatar_menu_pressed);
            click_controller.released.connect(on_avatar_menu_released);
            click_controller.cancel.connect(cancel_pending_avatar_menu);
            avatar_picture.add_controller(click_controller);
            avatar_picture.unmap.connect(cancel_pending_avatar_menu);
        }
    }

    private void ensure_content_initialized() {
        if (content_initialized) return;
        content_initialized = true;

        int64 t_widget_us = Dino.Ui.UiTiming.now_us();
        widget = item.get_widget(this, Plugins.WidgetType.GTK4) as Widget;
        Dino.Ui.UiTiming.log_ms("ConversationItemSkeleton.ensure_content_initialized: item.get_widget", t_widget_us);
        if (widget != null) {
            widget.valign = Align.END;
            set_widget(widget, Plugins.WidgetType.GTK4, 2);
        }

        ContentMetaItem? content_meta_item = item as ContentMetaItem;
        if (content_meta_item != null) {
            int64 t_react_us = Dino.Ui.UiTiming.now_us();
            reactions_controller = new ReactionsController(conversation, content_meta_item.content_item, stream_interactor);
            reactions_controller.box_activated.connect(on_reaction_box_activated);
            reactions_controller.init();
            Dino.Ui.UiTiming.log_ms("ConversationItemSkeleton.ensure_content_initialized: reactions_controller.init", t_react_us);
        }
    }

    private bool can_open_avatar_menu() {
        if (_skeleton_disposed || !avatar_picture.get_mapped() ||
                avatar_picture.get_root() == null) return false;
        // Don't open an occupant menu for the account's own avatar.
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            Xmpp.Jid? own_jid = stream_interactor.get_module<MucManager>(MucManager.IDENTITY)
                .get_own_jid(conversation.counterpart, conversation.account);
            if (own_jid != null && item.jid.equals(own_jid)) return false;
        } else if (item.jid.equals_bare(conversation.account.bare_jid)) {
            return false;
        }
        return true;
    }

    private void on_avatar_menu_pressed(GestureClick controller, int n_press,
            double x, double y) {
        cancel_pending_avatar_menu();
        uint button = controller.get_current_button();
        if ((button != 1 && button != 3) || !can_open_avatar_menu()) return;
        controller.set_state(EventSequenceState.CLAIMED);
        avatar_menu_pending = true;
    }

    private void on_avatar_menu_released() {
        if (!avatar_menu_pending) return;
        avatar_menu_pending = false;
        // Changing the modal grab during the initiating press/release can
        // break GTK's active-state accounting, especially on repeated clicks.
        // Wait for release dispatch to finish on Linux and Windows alike.
        avatar_menu_source = queue_avatar_menu(this, conversation, item);
    }

    private static uint queue_avatar_menu(ConversationItemSkeleton owner,
            Conversation conversation, Plugins.MetaConversationItem item) {
        WeakRef owner_weak = WeakRef(owner);
        return Idle.add(() => {
            var skeleton = owner_weak.get() as ConversationItemSkeleton;
            if (skeleton == null) return Source.REMOVE;
            skeleton.avatar_menu_source = 0;
            if (skeleton.conversation != conversation || skeleton.item != item ||
                    !skeleton.can_open_avatar_menu()) return Source.REMOVE;
            skeleton.open_avatar_menu();
            return Source.REMOVE;
        });
    }

    private void cancel_pending_avatar_menu() {
        avatar_menu_pending = false;
        if (avatar_menu_source != 0) {
            Source.remove(avatar_menu_source);
            avatar_menu_source = 0;
        }
    }

    private void open_avatar_menu() {
        Widget? popover_parent = avatar_picture.get_root() as Widget;
        if (popover_parent == null) return;
        Graphene.Rect avatar_bounds;
        if (!avatar_picture.compute_bounds((!) popover_parent,
                out avatar_bounds)) return;

        if (active_occupant_menu != null) {
            active_occupant_menu.close_and_detach();
            active_occupant_menu = null;
        }

        var menu = new Dino.Ui.OccupantMenu.View.for_avatar(
            stream_interactor, conversation, avatar_picture);
        active_occupant_menu = menu;
        // Keep the native popup parented to the stable window root. A
        // message row can disappear while GTK's tooltip query is still
        // pending; parenting to the row avatar would destroy the popup
        // surface before View's version-gated grace period has elapsed.
        menu.set_parent((!) popover_parent);
        menu.set_pointing_to({
            (int) avatar_bounds.origin.x,
            (int) avatar_bounds.origin.y,
            (int) avatar_bounds.size.width,
            (int) avatar_bounds.size.height
        });
        menu.show_menu(item.jid, name_label.label);
        var menu_binding = new AvatarMenuBinding(this, menu, avatar_picture);
        connect_avatar_menu_binding(menu, menu_binding);
        menu.popup();
    }

    private void set_header() {
        if (!show_skeleton) return;
        if (header_initialized) return;

        if (defer_heavy_work) return;

        init_header();
    }

    private void init_header() {
        if (_skeleton_disposed || header_initialized) return;
        // A deferred attempt may be skipped after a merge/mention update.
        // Only an actually initialized header must prevent a later retry.
        header_initialized = true;
        int64 t0_us = Dino.Ui.UiTiming.now_us();

        update_name_label();
        updated_roster_handler_id = stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY).updated_roster_item.connect((account, jid, roster_item) => {
            if (this.conversation.account.equals(account) && this.conversation.counterpart.equals(jid)) {
                update_name_label();
            }
        });

        item.notify["encryption"].connect(update_encryption_icon);
        update_encryption_icon();

        if (item.time != null) {
            update_time();
        }

        mark_binding = item.bind_property("mark", this, "item-mark", BindingFlags.SYNC_CREATE);
        notify_item_mark_handler_id = this.notify["item-mark"].connect_after(update_received_mark);
        Entities.Message? displayed_message = get_displayed_state_message();
        if (conversation.type_ == Conversation.Type.GROUPCHAT &&
                displayed_message != null &&
                ((!) displayed_message).direction ==
                    Entities.Message.DIRECTION_SENT) {
            DisplayedStateManager displayed_state = stream_interactor
                .get_module<DisplayedStateManager>(
                    DisplayedStateManager.IDENTITY);
            groupchat_displayed_state_handler_id = displayed_state
                .groupchat_displayed_state_changed.connect(
                    (changed_conversation, target) => {
                if (conversation.equals(changed_conversation)) {
                    update_received_mark();
                }
            });
        }
        update_received_mark();

        Dino.Ui.UiTiming.log_ms("ConversationItemSkeleton.init_header: total", t0_us);
    }

    public void clear_focus_before_detach() {
        Util.clear_focus_before_detach(main_grid);
    }

    public void set_widget(Object object, Plugins.WidgetType type, int priority) {
        foreach (var content_widget in content_widgets.values) {
            Util.clear_focus_before_detach(content_widget);
            if (content_widget.get_parent() != null) content_widget.unparent();
        }

        content_widgets[priority] = (Widget) object;
        int row_no = 1;
        for (int i = 0; i < 5; i++) {
            if (!content_widgets.has_key(i)) continue;
            main_grid.attach(content_widgets[i], 2, row_no, 1, 1);
            row_no++;
        }
    }

    private void update_margin() {
        avatar_picture.visible = show_skeleton;
        // Hide the group instead of overriding the visibility of status
        // children. Plain messages must not regain an empty lock/receipt slot
        // when their headers are regrouped or a mention becomes visible.
        header_box.visible = show_skeleton;
        mention_indicator_label.visible = has_mention;

        if (show_skeleton || content_meta_item == null) {
            main_grid.add_css_class("has-skeleton");
        } else {
            main_grid.remove_css_class("has-skeleton");
        }
    }

    private void on_mention_changed() {
        if (_skeleton_disposed) return;
        show_skeleton = requested_skeleton;
        mention_changed();
    }

    private void update_edit_mode() {
        if (item.in_edit_mode) {
            main_grid.add_css_class("edit-mode");
        } else {
            main_grid.remove_css_class("edit-mode");
        }
    }



    private void update_encryption_icon() {
        Application app = GLib.Application.get_default() as Application;
        encryption_image.visible = false;
        encryption_image.icon_name = null;
        encryption_image.tooltip_text = null;

        ContentMetaItem ci = item as ContentMetaItem;
        if (item.encryption != Encryption.NONE && item.encryption != Encryption.UNKNOWN && ci != null) {
            string? icon_name = null;
            var encryption_entry = app.plugin_registry.encryption_list_entries[item.encryption];
            if (encryption_entry != null) icon_name = encryption_entry.get_encryption_icon_name(conversation, ci.content_item);
            encryption_image.icon_name = icon_name ?? "changes-prevent-symbolic";
            encryption_image.tooltip_text = Util.string_if_tooltips_active(get_encryption_tooltip(item.encryption));
            encryption_image.visible = true;
        }

        if (item.encryption == Encryption.NONE) {
            if (conversation.encryption != Encryption.NONE) {
                debug("update_encryption_icon: OPEN LOCK — item.encryption=NONE but conversation.encryption=%d jid=%s time=%s",
                      (int) conversation.encryption,
                      conversation.counterpart.to_string(),
                      item.time != null ? item.time.to_string() : "(null)");
                encryption_image.icon_name = "changes-allow-symbolic";
                encryption_image.tooltip_text = Util.string_if_tooltips_active(_("Unencrypted"));
                Util.force_error_color(encryption_image);
                encryption_image.visible = true;
            } else if (conversation.encryption == Encryption.NONE) {
                encryption_image.icon_name = null;
                encryption_image.tooltip_text = null;
                encryption_image.visible = false;
            }
        }
    }

    private string get_encryption_tooltip(Encryption encryption) {
        switch (encryption) {
            case Encryption.PGP:
                return _("OpenPGP encrypted");
            case Encryption.OMEMO:
                return _("Encrypted");
            case Encryption.DTLS_SRTP:
                return _("DTLS-SRTP encrypted");
            case Encryption.SRTP:
                return _("SRTP encrypted");
            default:
                return _("Encrypted");
        }
    }

    private void on_reaction_box_activated(Widget widget) {
        set_widget(widget, Plugins.WidgetType.GTK4, 4);
    }

    private void on_time_update_timeout() {
        if (main_grid.parent != null) update_time();
    }

    private void update_time() {
        time_label.label = get_relative_time(item.time.to_local()).to_string();

        time_update_timeout = Dino.WeakTimeout.add_seconds_once((int) get_next_time_change(item.time), this, on_time_update_timeout);
    }

    private void update_name_label() {
        name_label.label = Util.get_participant_display_name(stream_interactor, conversation, item.jid, true);
        name_label.tooltip_text = Util.string_if_tooltips_active(name_label.label);
    }

    private void update_received_mark() {
        // Reset any previously applied CSS color
        received_image.remove_css_class("sent-mark");
        received_image.remove_css_class("received-mark");
        received_image.tooltip_text = null;
        received_image.visible = true;

        Entities.Message? displayed_message = get_displayed_state_message();
        if (conversation.type_ == Conversation.Type.GROUPCHAT &&
                displayed_message != null) {
            int reader_count = stream_interactor.get_module<
                DisplayedStateManager>(DisplayedStateManager.IDENTITY)
                .get_groupchat_reader_count(conversation,
                    (!) displayed_message);
            if (reader_count > 0) {
                received_image.icon_name = "dino-double-tick-symbolic";
                received_image.add_css_class("received-mark");
                received_image.tooltip_text = Util.string_if_tooltips_active(
                    n("Read by %i participant",
                        "Read by %i participants", reader_count)
                        .printf(reader_count));
                return;
            }
        }

        switch (content_meta_item.mark) {
            case Message.Marked.RECEIVED: 
                received_image.icon_name = "dino-tick-symbolic";
                received_image.add_css_class("sent-mark");
                received_image.tooltip_text = Util.string_if_tooltips_active(_("Delivered"));
                break;
            case Message.Marked.READ:
                received_image.icon_name = "dino-double-tick-symbolic";
                received_image.add_css_class("received-mark");
                received_image.tooltip_text = Util.string_if_tooltips_active(_("Read"));
                break;
            case Message.Marked.WONTSEND:
            case Message.Marked.ERROR:
                received_image.icon_name = "dialog-warning-symbolic";
                Util.force_error_color(received_image);
                Util.force_error_color(time_label);
                string error_text = Util.string_if_tooltips_active(
                    MessageDiagnostics.delivery_error_for_display(
                        displayed_message != null ? ((!) displayed_message).delivery_error_text : null));
                received_image.tooltip_text = error_text;
                time_label.tooltip_text = error_text;
                break;
            default:
                received_image.icon_name = null;
                received_image.visible = false;
                break;
        }
    }

    private Entities.Message? get_displayed_state_message() {
        if (content_meta_item == null ||
                content_meta_item.content_item == null) return null;
        return stream_interactor.get_module<ContentItemStore>(
            ContentItemStore.IDENTITY).get_message_for_content_item(
                conversation, content_meta_item.content_item);
    }

    public static int get_next_time_change(DateTime datetime) {
        DateTime now = new DateTime.now_local();
        TimeSpan timespan = now.difference(datetime);

        if (timespan < 10 * TimeSpan.MINUTE) {
            if (now.get_second() < datetime.get_second()) {
                return datetime.get_second() - now.get_second();
            } else {
                return 60 - (now.get_second() - datetime.get_second());
            }
        } else {
            return (23 - now.get_hour()) * 3600 + (59 - now.get_minute()) * 60 + (59 - now.get_second());
        }
    }

    public static string format_time(DateTime datetime, string format_24h, string format_12h) {
        string format = Util.is_24h_format() ? format_24h : format_12h;
        if (!get_charset(null)) {
            // No UTF-8 support, use simple colon for time instead
            format = format.replace("∶", ":");
        }
        return datetime.format(format);
    }

    public static string get_relative_time(DateTime datetime) {
        DateTime now = new DateTime.now_local();
        TimeSpan timespan = now.difference(datetime);
        if (timespan > 365 * TimeSpan.DAY) {
            return format_time(datetime,
                /* xgettext:no-c-format */ /* Date + time in 24h format (w/o seconds) */ _("%x, %H∶%M"),
                /* xgettext:no-c-format */ /* Date + time in 12h format (w/o seconds)*/ _("%x, %l∶%M %p"));
        } else if (timespan > 7 * TimeSpan.DAY) {
            return format_time(datetime,
                /* xgettext:no-c-format */ /* Month, day and time in 24h format (w/o seconds) */ _("%b %d, %H∶%M"),
                /* xgettext:no-c-format */ /* Month, day and time in 12h format (w/o seconds) */ _("%b %d, %l∶%M %p"));
        } else if (datetime.get_day_of_month() != now.get_day_of_month()) {
            return format_time(datetime,
                /* xgettext:no-c-format */ /* Day of week and time in 24h format (w/o seconds) */ _("%a, %H∶%M"),
                /* xgettext:no-c-format */ /* Day of week and time in 12h format (w/o seconds) */_("%a, %l∶%M %p"));
        } else if (timespan > 9 * TimeSpan.MINUTE) {
            return format_time(datetime,
                /* xgettext:no-c-format */  /* Time in 24h format (w/o seconds) */ _("%H∶%M"),
                /* xgettext:no-c-format */  /* Time in 12h format (w/o seconds) */ _("%l∶%M %p"));
        } else if (timespan > TimeSpan.MINUTE) {
            ulong mins = (ulong) (timespan.abs() / TimeSpan.MINUTE);
            /* xgettext:this is the beginning of a sentence. */
            return n("%i min ago", "%i mins ago", mins).printf(mins);
        } else {
            return _("Just now");
        }
    }

    public Widget get_widget() {
        return main_grid;
    }

    public override void dispose() {
        if (_skeleton_disposed) { base.dispose(); return; }
        _skeleton_disposed = true;
        cancel_pending_avatar_menu();

        if (mention_presentation != null) {
            ((!) mention_presentation).clear();
            mention_presentation = null;
        }

        // The row must still be rooted while focus is cleared. ConversationView
        // calls this before removing a single row; clear() reaches dispose()
        // while the row is still attached.
        clear_focus_before_detach();

        // Break reference cycles: disconnect this.notify signals
        if (notify_edit_mode_handler_id != 0) { this.disconnect(notify_edit_mode_handler_id); notify_edit_mode_handler_id = 0; }
        if (notify_show_skeleton1_handler_id != 0) { this.disconnect(notify_show_skeleton1_handler_id); notify_show_skeleton1_handler_id = 0; }
        if (notify_show_skeleton2_handler_id != 0) { this.disconnect(notify_show_skeleton2_handler_id); notify_show_skeleton2_handler_id = 0; }
        if (notify_item_mark_handler_id != 0) { this.disconnect(notify_item_mark_handler_id); notify_item_mark_handler_id = 0; }

        // Unbind property bindings that keep item<->skeleton alive
        if (edit_mode_binding != null) { edit_mode_binding.unbind(); edit_mode_binding = null; }
        if (mark_binding != null) { mark_binding.unbind(); mark_binding = null; }

        // Disconnect signals on item that prevent skeleton GC
        if (item != null && header_initialized) {
            item.notify["encryption"].disconnect(update_encryption_icon);
        }

        if (time_update_timeout != 0) {
            Source.remove(time_update_timeout);
            time_update_timeout = 0;
        }
        if (updated_roster_handler_id != 0){
            stream_interactor.get_module<RosterManager>(RosterManager.IDENTITY).disconnect(updated_roster_handler_id);
            updated_roster_handler_id = 0;
        }
        if (groupchat_displayed_state_handler_id != 0) {
            stream_interactor.get_module<DisplayedStateManager>(
                DisplayedStateManager.IDENTITY).disconnect(
                    groupchat_displayed_state_handler_id);
            groupchat_displayed_state_handler_id = 0;
        }
        if (reactions_controller != null) {
            reactions_controller.cleanup();
            reactions_controller = null;
        }

        if (active_occupant_menu != null) {
            active_occupant_menu.close_and_detach();
            active_occupant_menu = null;
        }

        // Dispose content widgets (VideoPlayerWidget, FileWidget, etc.)
        if (content_widgets != null) {
            foreach (var content_widget in content_widgets.values) {
                if (content_widget.get_parent() != null) content_widget.unparent();
                content_widget.dispose();
            }
            content_widgets.clear();
        }
        widget = null;

        // Children won't be disposed automatically
        if (name_label != null) {
            name_label.unparent();
            name_label.dispose();
            name_label = null;
        }
        if (time_label != null) {
            time_label.unparent();
            time_label.dispose();
            time_label = null;
        }
        if (avatar_picture != null) {
            // Clean up avatar tile models to break signal reference cycles
            var compat_model = avatar_picture.model as ViewModel.CompatAvatarPictureModel;
            if (compat_model != null) compat_model.reset();
            avatar_picture.unparent();
            avatar_picture.dispose();
            avatar_picture = null;
        }
        if (encryption_image != null) {
            encryption_image.unparent();
            encryption_image.dispose();
            encryption_image = null;
        }
        if (received_image != null) {
            received_image.unparent();
            received_image.dispose();
            received_image = null;
        }
        if (mention_indicator_label != null) {
            mention_indicator_label.unparent();
            mention_indicator_label.dispose();
            mention_indicator_label = null;
        }
        if (header_box != null) {
            header_box.unparent();
            header_box.dispose();
            header_box = null;
        }
        item = null;
        content_meta_item = null;
        base.dispose();
    }
}

}
