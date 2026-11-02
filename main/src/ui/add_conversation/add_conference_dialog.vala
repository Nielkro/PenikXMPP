using Gee;
using Gtk;

using Dino.Entities;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Ui {

public class AddConferenceDialog : Adw.Dialog {

    private Stack stack = new Stack();
    private Button cancel_button = new Button();
    private Button ok_button;

    private SelectJidFragment select_fragment;
    private ConferenceDetailsFragment details_fragment;
    private ConferenceList conference_list;
    private ListBox conference_list_box;
    private uint conference_list_load_source = 0;
    private uint resize_timeout_id = 0;
    private ulong conference_list_rows_changed_handler_id = 0;
    private bool conference_sorting_enabled = false;
    private bool conference_list_loading_started = false;
    private bool removing_bookmark = false;
    private bool dialog_closed = false;

    private StreamInteractor stream_interactor;
    private Adw.HeaderBar header_bar;

    public AddConferenceDialog(StreamInteractor stream_interactor) {
        bool timing = UiTiming.enabled();
        int64 t0_us = timing ? UiTiming.now_us() : 0;
        this.title = _("Join Group");
        this.content_width = 460;
        this.content_height = 550;
        this.follows_content_size = false;
        this.stream_interactor = stream_interactor;

        var toolbar_view = new Adw.ToolbarView();
        this.child = toolbar_view;

        stack.visible = true;
        // Hidden room details must not impose their minimum width on the selector.
        stack.hhomogeneous = false;
        stack.vhomogeneous = false;
        toolbar_view.content = stack;

        setup_headerbar(toolbar_view);
        setup_jid_add_view();
        setup_conference_details_view();
        show_jid_add_view();
        this.map.connect(() => {
            ensure_list_started();
        });
        if (timing) {
            UiTiming.log_ms("AddConferenceDialog.constructor", t0_us);
        }

        this.closed.connect(() => {
            dialog_closed = true;
            if (conference_list_load_source != 0) {
                Source.remove(conference_list_load_source);
                conference_list_load_source = 0;
            }
            cancel_resize_animation();
            if (conference_list_rows_changed_handler_id != 0) {
                conference_list.disconnect(conference_list_rows_changed_handler_id);
                conference_list_rows_changed_handler_id = 0;
            }
            select_fragment.deactivate();
            conference_list.deactivate();
            details_fragment.cancel_pending_join();
        });
    }

    private void show_jid_add_view() {
        cancel_resize_animation();
        details_fragment.cancel_pending_join();
        cancel_button.set_label(_("Cancel"));
        cancel_button.clicked.disconnect(show_jid_add_view);
        cancel_button.clicked.connect(on_cancel);
        ok_button.label = _("Next");
        ok_button.sensitive = select_fragment.done;
        update_ok_button_label();
        ok_button.clicked.disconnect(on_join_button_clicked);
        ok_button.clicked.connect(on_next_button_clicked);
        details_fragment.fragment_active = false;
        details_fragment.notify["done"].disconnect(set_ok_sensitive_from_details);
        select_fragment.notify["done"].connect(set_ok_sensitive_from_select);

        stack.transition_type = StackTransitionType.SLIDE_RIGHT;
        stack.set_visible_child_name("select");
        update_ok_button_label();
        animate_window_resize(550);
    }

    private void show_conference_details_view() {
        cancel_button.set_icon_name("go-previous-symbolic");
        cancel_button.clicked.disconnect(on_cancel);
        cancel_button.clicked.connect(show_jid_add_view);
        ok_button.label = _("Join");
        ok_button.sensitive = details_fragment.done;
        ok_button.clicked.disconnect(on_next_button_clicked);
        ok_button.clicked.connect(on_join_button_clicked);
        details_fragment.fragment_active = true;
        select_fragment.notify["done"].disconnect(set_ok_sensitive_from_select);
        details_fragment.notify["done"].connect(set_ok_sensitive_from_details);

        stack.transition_type = StackTransitionType.SLIDE_LEFT;
        stack.set_visible_child_name("details");
        animate_window_resize();
    }

    private void setup_headerbar(Adw.ToolbarView toolbar_view) {
        ok_button = new Button() { can_focus=true };
        ok_button.add_css_class("suggested-action");

        header_bar = new Adw.HeaderBar();
        header_bar.decoration_layout = ":";

        header_bar.pack_start(cancel_button);
        header_bar.pack_end(ok_button);

        var window_title = new Adw.WindowTitle("", "");
        this.bind_property("title", window_title, "title", BindingFlags.SYNC_CREATE);
        header_bar.title_widget = window_title;
        
        toolbar_view.add_top_bar(header_bar);
    }

    private void setup_jid_add_view() {
        conference_list = new ConferenceList(stream_interactor);
        conference_list_box = conference_list.get_list_box();
        conference_list_box.row_selected.connect(update_ok_button_label);

        select_fragment = new SelectJidFragment(stream_interactor, conference_list_box, stream_interactor.get_accounts());
        conference_list_rows_changed_handler_id = conference_list.rows_changed.connect(() => {
            if (!conference_sorting_enabled) {
                select_fragment.enable_sorting();
                conference_sorting_enabled = true;
            }
            select_fragment.schedule_filter_refresh();
            select_fragment.refresh_button_state();
            update_ok_button_label();
        });
        select_fragment.enable_muc_search = true;
        select_fragment.button_mode = SelectJidFragment.ButtonMode.GROUP;
        select_fragment.show_button_labels = true;
        select_fragment.browser_jid_chosen.connect((account, jid) => {
            Idle.add(() => {
                details_fragment.clear();
                details_fragment.account = account;
                details_fragment.jid = jid.to_string();
                ok_button.grab_focus();
                show_conference_details_view();
                return Source.REMOVE;
            });
        });
        select_fragment.add_jid.connect(() => {
            AddGroupchatDialog dialog = new AddGroupchatDialog(stream_interactor);
            dialog.present(this);
        });
        select_fragment.remove_jid.connect((row) => {
            ConferenceListRow conference_row = row as ConferenceListRow;
            if (conference_row == null) return;
            if (!account_is_active_managed(conference_row.account)) return;
            MucManager muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            ConversationManager conversation_manager = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
            Conversation? conversation = conversation_manager.get_conversation(conference_row.jid, conference_row.account, Conversation.Type.GROUPCHAT);
            bool has_active_conversation = conversation != null && conversation.active;
            if (conference_row.bookmark != null && !conference_row.open_existing && !has_active_conversation) {
                remove_bookmark.begin(muc_manager, conference_row.account, conference_row.bookmark);
            } else if (muc_manager.is_joined_or_joining(conference_row.jid, conference_row.account) ||
                    conference_row.open_existing ||
                    has_active_conversation) {
                muc_manager.part(conference_row.account, conference_row.jid);
            }
        });

        Box wrap_box = new Box(Orientation.VERTICAL, 0);
        wrap_box.append(select_fragment);
        stack.add_named(wrap_box, "select");
    }

    private async void remove_bookmark(MucManager muc_manager, Account account, Conference bookmark) {
        if (removing_bookmark) return;
        removing_bookmark = true;
        select_fragment.sensitive = false;
        ok_button.sensitive = false;
        cancel_button.sensitive = false;

        bool ok = yield muc_manager.remove_bookmark(account, bookmark);
        if (dialog_closed) return;

        removing_bookmark = false;
        select_fragment.sensitive = true;
        cancel_button.sensitive = true;
        ok_button.sensitive = select_fragment.done;
        update_ok_button_label();

        if (!ok) {
            show_error_dialog(
                _("Could not remove bookmark"),
                _("The group bookmark was not changed on the server. Please try again later.")
            );
        }
    }

    private void setup_conference_details_view() {
        details_fragment = new ConferenceDetailsFragment(stream_interactor) { ok_button=ok_button };
        details_fragment.joined.connect(() => this.close());

        Box wrap_box = new Box(Orientation.VERTICAL, 0);
        wrap_box.append(details_fragment);

        stack.add_named(wrap_box, "details");
    }

    private void set_ok_sensitive_from_select() {
        ok_button.sensitive = select_fragment.done;
        update_ok_button_label();
    }

    private void set_ok_sensitive_from_details() {
        ok_button.sensitive = !details_fragment.joining && details_fragment.done;
    }

    private void on_next_button_clicked() {
        if (removing_bookmark) return;
        details_fragment.clear();

        ListRow? row = conference_list_box.get_selected_row() != null ? conference_list_box.get_selected_row().get_child() as ListRow : null;
        ConferenceListRow? conference_row = conference_list_box.get_selected_row() != null ? conference_list_box.get_selected_row().get_child() as ConferenceListRow : null;
        if (conference_row != null) {
            if (!account_is_active_managed(conference_row.account)) return;
            if (conference_row.open_existing && open_existing_groupchat(conference_row.account, conference_row.jid)) {
                return;
            }
            details_fragment.account = conference_row.account;
            details_fragment.jid = conference_row.jid.to_string();
            if (conference_row.bookmark != null) {
                details_fragment.nick = conference_row.bookmark.nick;
                if (conference_row.bookmark.password != null) details_fragment.password = conference_row.bookmark.password;
            }
            ok_button.grab_focus();
        } else if (row != null) {
            if (!account_is_active_managed(row.account)) return;
            details_fragment.account = row.account;
            details_fragment.jid = row.jid.to_string();
        } else {
            return;
        }
        show_conference_details_view();
    }

    private void on_join_button_clicked() {
        details_fragment.submit_join();
    }

    private void update_ok_button_label() {
        if (stack.visible_child_name != "select") return;
        ConferenceListRow? conference_row = conference_list_box.get_selected_row() != null ? conference_list_box.get_selected_row().get_child() as ConferenceListRow : null;
        ok_button.label = conference_row != null && conference_row.open_existing ? _("Open") : _("Next");
    }

    private bool open_existing_groupchat(Account account, Jid jid) {
        if (!account_is_active_managed(account)) return false;
        ConversationManager conversation_manager = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
        Conversation? conversation = conversation_manager.get_conversation(jid.bare_jid, account, Conversation.Type.GROUPCHAT);
        if (conversation == null) return false;

        conversation_manager.start_conversation(conversation);
        Application app = GLib.Application.get_default() as Application;
        if (app != null) {
            app.controller.select_conversation(conversation);
        }
        close();
        return true;
    }

    private bool account_is_active_managed(Account? account) {
        if (account == null || !((!) account).enabled) return false;
        foreach (Account managed_account in stream_interactor.get_accounts()) {
            if (managed_account == (!) account && managed_account.enabled) return true;
        }
        return false;
    }

    private void ensure_list_started() {
        if (conference_list_load_source != 0) return;
        if (conference_list_loading_started) return;
        conference_list_loading_started = true;
        conference_list_load_source = Timeout.add(30, () => {
            conference_list_load_source = 0;
            conference_list.start_loading();
            return false;
        });
    }

    private void on_cancel() {
        details_fragment.cancel_pending_join();
        close();
    }

    private void show_error_dialog(string title, string body) {
        var dialog = new Adw.AlertDialog(title, body);
        dialog.add_response("ok", _("OK"));
        dialog.present(this);
    }

    private void animate_window_resize(int preferred_height = -1) {
        cancel_resize_animation();
        if (dialog_closed || child == null) return;

        // Dialog content includes the ToolbarView's header bar as well as the
        // current page. Measuring only the fragment omits the header's height.
        Widget content = (!) child;
        int width = content.get_width() > 0 ? content.get_width() : content_width;
        int floor_height, natural_height, minimum_baseline, natural_baseline;
        content.measure(Orientation.VERTICAL, int.max(1, width),
            out floor_height, out natural_height, out minimum_baseline, out natural_baseline);
        int target_height = int.max(floor_height,
            preferred_height >= 0 ? preferred_height : natural_height);
        int curr_height = int.max(content_height, floor_height);
        // Apply the new page's minimum before the first animation tick.
        content_height = curr_height;
        int difference = target_height - curr_height;
        uint duration_ms = stack.transition_duration;
        if (difference == 0 || duration_ms == 0) {
            content_height = target_height;
            return;
        }

        int64 started_us = get_monotonic_time();
        uint interval_ms = (uint) int.max(1, (int) (duration_ms / 30));
        resize_timeout_id = Timeout.add(interval_ms, () => {
            double partial = double.min(1,
                (get_monotonic_time() - started_us) / (duration_ms * 1000.0));
            content_height = int.max(floor_height, (int) (curr_height + difference * partial));
            bool keep_running = partial < 1;
            if (!keep_running) {
                resize_timeout_id = 0;
            }
            return keep_running;
        });
    }

    private void cancel_resize_animation() {
        if (resize_timeout_id == 0) return;
        Source.remove(resize_timeout_id);
        resize_timeout_id = 0;
    }
}

}
