using Gtk;

using Dino.Entities;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Ui {

[GtkTemplate (ui = "/im/dinox/dinox/add_conversation/conference_details_fragment.ui")]
protected class ConferenceDetailsFragment : Box {

    public signal void joined();

    public bool done { get; private set; }

    public Account? account {
        owned get { return selected_join_account ?? account_combobox.active_account; }
        set {
            if (value == null) return;
            selected_join_account = value;
            accounts_label.label = Util.sanitize_utf8(value.bare_jid.to_string());
            account_combobox.active_account = value;
            if (nick == null && value.alias != null) {
                nick = value.alias;
            }
            accounts_stack.set_visible_child_name("label");
        }
    }
    public string jid {
        get { return jid_entry.text; }
        set {
            string safe_value = Util.sanitize_utf8(value);
            jid_label.label = safe_value;
            jid_entry.text = safe_value;
            jid_stack.set_visible_child_name("label");
            check_if_done();
        }
    }
    public string? nick {
        get { return nick_entry.text != "" ? nick_entry.text : null; }
        set {
            string safe_value = Util.sanitize_utf8(value);
            nick_label.label = safe_value;
            nick_entry.text = safe_value;
            nick_stack.set_visible_child_name("label");
            check_if_done();
        }
    }
    public string? password {
        get { return password_entry.text == "" ? null : password_entry.text; }
        set {
            string safe_value = Util.sanitize_utf8(value);
            password_label.label = safe_value;
            password_entry.text = safe_value;
            password_stack.set_visible_child_name("label");
        }
    }

    public bool fragment_active { get; set; default=true; }

    [GtkChild] private unowned Stack accounts_stack;
    [GtkChild] private unowned Button accounts_button;
    [GtkChild] private unowned Label accounts_label;
    [GtkChild] private unowned AccountComboBox account_combobox;

    [GtkChild] private unowned Stack jid_stack;
    [GtkChild] private unowned Button jid_button;
    [GtkChild] private unowned Label jid_label;
    [GtkChild] private unowned Entry jid_entry;

    [GtkChild] private unowned Stack nick_stack;
    [GtkChild] private unowned Button nick_button;
    [GtkChild] private unowned Label nick_label;
    [GtkChild] private unowned Entry nick_entry;

    [GtkChild] private unowned Stack password_stack;
    [GtkChild] private unowned Button password_button;
    [GtkChild] private unowned Label password_label;
    [GtkChild] private unowned Label password_text_label;
    [GtkChild] private unowned Entry password_entry;

    [GtkChild] private unowned Revealer notification_revealer;
    [GtkChild] private unowned Button notification_button;
    [GtkChild] private unowned Label notification_label;

    private StreamInteractor stream_interactor;
    private Button ok_button_ = new Button();
    private uint join_request_id = 0;
    private Cancellable? join_cancellable = null;
    private Account? pending_join_account = null;
    private Jid? pending_join_jid = null;
    private Account? selected_join_account = null;
    public bool joining { get; private set; default=false; }
    private bool join_completed = false;
    private bool suppress_join_input_changed = false;
    public Button ok_button {
        get { return ok_button_; }
        set {
            ok_button_ = value;
            if (join_completed || joining) {
                ok_button_.label = _("Joining…");
                ok_button_.sensitive = false;
            } else {
                ok_button_.label = _("Join");
                ok_button_.sensitive = done;
            }
        }
    }

    public ConferenceDetailsFragment(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;

        account_combobox.initialize(stream_interactor);

        accounts_button.clicked.connect(() => { set_active_stack(accounts_stack); });
        jid_button.clicked.connect(() => { set_active_stack(jid_stack); });
        nick_button.clicked.connect(() => { set_active_stack(nick_stack); });
        password_button.clicked.connect(() => { set_active_stack(password_stack); });

        account_combobox.notify["active-account"].connect(() => {
            Account? active_account = account_combobox.active_account;
            if (selected_join_account != null && !account_is_active_managed(selected_join_account)) {
                accounts_label.label = _("Selected account is no longer active");
            } else {
                selected_join_account = account_is_active_managed(active_account) ? active_account : null;
                accounts_label.label = active_account != null ? Util.sanitize_utf8(((!) active_account).bare_jid.to_string()) : _("No enabled account");
            }
            on_join_target_changed();
        });
        Account? active_account = account_combobox.active_account;
        selected_join_account = account_is_active_managed(active_account) ? active_account : null;
        accounts_label.label = active_account != null ? Util.sanitize_utf8(((!) active_account).bare_jid.to_string()) : _("No enabled account");
        jid_entry.changed.connect(() => { on_join_target_changed(); });
        nick_entry.changed.connect(() => { on_join_input_changed(); });
        password_entry.changed.connect(() => { on_join_input_changed(); });

        check_if_done();

        notification_button.clicked.connect(() => { notification_revealer.set_reveal_child(false); });

        clear();
    }

    public void cancel_pending_join() {
        join_request_id++;
        if (pending_join_account != null && pending_join_jid != null) {
            MucManager? muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            if (muc_manager != null) {
                ((!) muc_manager).cancel_join((!) pending_join_account, (!) pending_join_jid);
            }
        }
        if (join_cancellable != null && !((!) join_cancellable).is_cancelled()) {
            ((!) join_cancellable).cancel();
        }
        join_cancellable = null;
        pending_join_account = null;
        pending_join_jid = null;
        notification_revealer.set_reveal_child(false);
        if (!join_completed) {
            reset_join_button_state();
        }
    }

    private void clear_current_join_state(Cancellable current_cancellable) {
        if (join_cancellable != current_cancellable) return;
        join_cancellable = null;
        pending_join_account = null;
        pending_join_jid = null;
    }

    private void set_join_button_busy() {
        join_completed = false;
        joining = true;
        notification_revealer.set_reveal_child(false);
        ok_button_.label = _("Joining…");
        ok_button_.sensitive = false;
    }

    private void set_join_button_completed() {
        join_completed = true;
        joining = false;
        ok_button_.label = _("Joining…");
        ok_button_.sensitive = false;
    }

    private void reset_join_button_state() {
        join_completed = false;
        joining = false;
        ok_button_.label = _("Join");
        ok_button_.sensitive = done;
    }

    public void submit_join() {
        if (!fragment_active || join_completed || joining || !done) return;
        set_join_button_busy();

        on_ok_button_clicked.begin((obj, res) => {
            on_ok_button_clicked.end(res);
        });
    }

    public void clear() {
        cancel_pending_join();
        suppress_join_input_changed = true;
        jid = "";
        nick = "";
        password = "";
        suppress_join_input_changed = false;
        password_text_label.visible = false;
        password_stack.visible = false;
        check_if_done();
        reset_join_button_state();
        reset_editable();
    }

    public void reset_editable() {
        jid_stack.set_visible_child_name("entry");
        accounts_stack.set_visible_child_name("entry");
        nick_stack.set_visible_child_name("entry");
        password_stack.set_visible_child_name("entry");
    }

    private async void on_ok_button_clicked() {
        if (!fragment_active || !done) {
            reset_join_button_state();
            return;
        }
        uint request_id = ++join_request_id;
        Account? active_account = selected_join_account;
        if (!account_is_active_managed(active_account)) {
            reset_join_button_state();
            return;
        }
        if (join_cancellable != null && !((!) join_cancellable).is_cancelled()) {
            ((!) join_cancellable).cancel();
        }
        join_cancellable = new Cancellable();
        Cancellable current_cancellable = (!) join_cancellable;

        string label_text = "";
        try {
            Jid parsed_jid = new Jid(jid);
            string connect_error_text = _("Could not connect to %s").printf(parsed_jid.domainpart);
            Account join_account = (!) active_account;
            pending_join_account = join_account;
            pending_join_jid = parsed_jid;
            Muc.JoinResult? join_result = yield stream_interactor.get_module<MucManager>(MucManager.IDENTITY).join(join_account, parsed_jid, nick, password, false, current_cancellable);
            if (!account_is_active_managed(join_account)) {
                clear_current_join_state(current_cancellable);
                reset_join_button_state();
                return;
            }
            if (request_id != join_request_id || !fragment_active) {
                clear_current_join_state(current_cancellable);
                if (request_id == join_request_id && !fragment_active) {
                    reset_join_button_state();
                }
                return;
            }
            clear_current_join_state(current_cancellable);

            if (join_result != null && join_result.nick != null) {
                if (!account_is_active_managed(join_account)) {
                    reset_join_button_state();
                    return;
                }
                Conversation conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).create_conversation(parsed_jid, join_account, Conversation.Type.GROUPCHAT);
                Application app = GLib.Application.get_default() as Application;
                if (app != null) {
                    app.controller.select_conversation(conversation);
                }
                set_join_button_completed();
                joined();
                return;
            }

            if (join_result == null) {
                label_text = connect_error_text;
            } else if (join_result.muc_error != null) {
                label_text = connect_error_text;
                switch (join_result.muc_error) {
                    case Muc.MucEnterError.PASSWORD_REQUIRED:
                        label_text = _("Password required to enter room");
                        password_text_label.visible = true;
                        password_stack.visible = true;
                        break;
                    case Muc.MucEnterError.BANNED:
                        label_text = _("Banned from joining or creating conference"); break;
                    case Muc.MucEnterError.ROOM_DOESNT_EXIST:
                        label_text = _("Room does not exist"); break;
                    case Muc.MucEnterError.CREATION_RESTRICTED:
                        label_text = _("Not allowed to create room"); break;
                    case Muc.MucEnterError.NOT_IN_MEMBER_LIST:
                        label_text = _("Members-only room"); break;
                    case Muc.MucEnterError.USE_RESERVED_ROOMNICK:
                    case Muc.MucEnterError.NICK_CONFLICT:
                        label_text = _("Choose a different nick"); break;
                    case Muc.MucEnterError.OCCUPANT_LIMIT_REACHED:
                        label_text = _("Too many occupants in room"); break;
                }
            } else if (join_result.stanza_error == ErrorStanza.CONDITION_REMOTE_SERVER_TIMEOUT) {
                label_text = _("The room did not answer. This can happen sporadically; try joining again.");
            } else if (join_result.stanza_error != null) {
                label_text = connect_error_text;
            } else {
                label_text = connect_error_text;
            }
        } catch (InvalidJidError e) {
            label_text = _("Invalid address");
        }
        clear_current_join_state(current_cancellable);
        if (request_id != join_request_id) return;
        if (!fragment_active) {
            reset_join_button_state();
            return;
        }
        reset_join_button_state();
        notification_label.label = Util.sanitize_utf8(label_text);
        notification_revealer.set_reveal_child(true);
    }

    private void check_if_done() {
        try {
            Jid parsed_jid = new Jid(jid);
            Account? active_account = selected_join_account;
            done = account_is_active_managed(active_account) && parsed_jid.localpart != null && parsed_jid.resourcepart == null && nick != null;
        } catch (InvalidJidError e) {
            done = false;
        }
        if (!joining && !join_completed) {
            ok_button_.sensitive = done;
        }
    }

    private void on_join_input_changed() {
        if (suppress_join_input_changed) return;
        if (joining) {
            cancel_pending_join();
        } else {
            notification_revealer.set_reveal_child(false);
            reset_join_button_state();
        }
        check_if_done();
    }

    private void on_join_target_changed() {
        if (suppress_join_input_changed) return;
        if (password != null) {
            suppress_join_input_changed = true;
            password = null;
            suppress_join_input_changed = false;
        }
        password_text_label.visible = false;
        password_stack.visible = false;
        on_join_input_changed();
    }

    private bool account_is_active_managed(Account? account) {
        if (account == null || !((!) account).enabled) return false;
        foreach (Account managed_account in stream_interactor.get_accounts()) {
            if (managed_account == (!) account && managed_account.enabled) return true;
        }
        return false;
    }

    private void set_active_stack(Stack stack) {
        stack.set_visible_child_name("entry");
        if (stack != accounts_stack) accounts_stack.set_visible_child_name("label");
        if (stack != jid_stack) jid_stack.set_visible_child_name("label");
        if (stack != nick_stack) nick_stack.set_visible_child_name("label");
        if (stack != password_stack) password_stack.set_visible_child_name("label");
    }

}

}
