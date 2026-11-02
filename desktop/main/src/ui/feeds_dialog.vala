using Gtk;
using Gee;
using Dino.Entities;

namespace Dino.Ui {

public class FeedsDialog : Adw.Dialog {
    private StreamInteractor interactor;
    private Feeds.Service service;
    private ArrayList<Account> accounts = new ArrayList<Account>();
    private Adw.ComboRow account_choice;
    private Adw.EntryRow web_url = new Adw.EntryRow();
    private Adw.SpinRow web_interval = new Adw.SpinRow.with_range(5, 1440, 5) { value = 30 };
    private Adw.EntryRow xmpp_address = new Adw.EntryRow();
    private Adw.EntryRow xmpp_node = new Adw.EntryRow() { text = Feeds.Social.MICROBLOG };
    private Box web_entries = new Box(Orientation.VERTICAL, 10);
    private Box social_entries = new Box(Orientation.VERTICAL, 10);
    private Box subscriptions = new Box(Orientation.VERTICAL, 10);
    private Label feedback = new Label("") { wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR, max_width_chars = 55, xalign = 0 };
    private Stack pages = new Stack() { hhomogeneous = false, vhomogeneous = false };
    private Box controls;
    private Cancellable cancel = new Cancellable();
    private bool dialog_closed;
    private ArrayList<Adw.Dialog> child_dialogs = new ArrayList<Adw.Dialog>();
    private bool busy;
    private ulong changed_handler;
    private ulong social_handler;
    private uint refresh_source;
    private Account? loaded_account;
    private string loaded_url = "";
    private ArrayList<Feeds.Entry>? loaded_entries;
    private Conversation? preferred_target;
    private string displayed_social_source = "";
    private string displayed_social_node = "";

    public FeedsDialog(StreamInteractor interactor, Conversation? preferred_target = null) {
        this.interactor = interactor;
        this.preferred_target = preferred_target;
        this.service = interactor.get_module<Feeds.Service>(Feeds.Service.IDENTITY);
        Util.TextContextMenu.attach(web_url);
        Util.TextContextMenu.attach(web_interval);
        Util.TextContextMenu.attach(xmpp_address);
        Util.TextContextMenu.attach(xmpp_node);
        title = _("Feeds");
        content_width = 600;
        content_height = 640;
        follows_content_size = false;
        var toolbar = new Adw.ToolbarView();
        toolbar.add_top_bar(new Adw.HeaderBar());
        var scroll = new ScrolledWindow() { hscrollbar_policy = PolicyType.NEVER, vexpand = true };
        controls = new Box(Orientation.VERTICAL, 14) { margin_start = 18, margin_end = 18, margin_top = 12, margin_bottom = 18 };
        scroll.child = controls;
        toolbar.content = scroll;
        child = toolbar;
        controls.append(label(_("A feed is a list of new posts, such as news or software releases. Here you can read feeds, share posts in chats or publish your own posts.")));
        accounts.add_all(interactor.get_accounts());
        var account_names = new StringList(null);
        foreach (Account account in accounts) account_names.append(account.bare_jid.to_string());
        account_choice = new Adw.ComboRow() { title = _("Account"), model = account_names, use_subtitle = true };
        var account_group = new Adw.PreferencesGroup();
        account_group.add(account_choice);
        controls.append(account_group);
        if (preferred_target != null) for (int i = 0; i < accounts.size; i++) {
            if (accounts[i].id == ((!) preferred_target).account.id) account_choice.selected = i;
        }
        // Keep all four purposes visible in narrow windows, without hiding
        // the last sections behind a horizontal scrollbar.
        var navigation = new Grid() { column_homogeneous = true, row_homogeneous = true, column_spacing = 6, row_spacing = 6 };
        controls.append(navigation);
        feedback.visible = false;
        feedback.notify["label"].connect(() => { feedback.visible = feedback.label != ""; });
        controls.append(feedback);
        controls.append(pages);
        var web = new Box(Orientation.VERTICAL, 10);
        web.append(label(_("Read RSS or Atom feeds and share individual articles in a chat.")));
        web_url.title = _("Feed URL");
        var web_group = new Adw.PreferencesGroup();
        web_group.add(web_url);
        web.append(web_group);
        var fetch = button(_("Load articles"));
        fetch.clicked.connect(() => load_web.begin());
        web.append(fetch);
        var automatic = button(_("Automatically post new articles…"));
        automatic.clicked.connect(configure_automatic);
        var automatic_group = new Adw.PreferencesGroup() { title = _("Automatic posting to chats"), description = _("Optional: check for new articles while DinoX is open and the account is connected.") };
        web_interval.title = _("Check interval (minutes)");
        web_interval.subtitle = _("5 minutes to 24 hours; default: 30 minutes.");
        automatic_group.add(web_interval);
        web.append(automatic_group);
        web.append(automatic);
        web.append(web_entries);
        pages.add_titled(web, "web", _("Web feeds"));
        var social = new Box(Orientation.VERTICAL, 10);
        social.append(label(_("Enter the address of someone who publishes an XMPP feed. Reading loads their recent posts; subscribing asks their server to notify your account about new posts.")));
        social.append(label(_("An open subscribed feed updates when the server announces changes. Otherwise, load it again to see new posts. Posts are not end-to-end encrypted and do not appear in chats automatically.")));
        xmpp_address.title = _("XMPP address or PubSub service");
        xmpp_node.title = _("Node (leave the default for personal feeds)");
        var social_group = new Adw.PreferencesGroup();
        social_group.add(xmpp_address);
        var advanced = new Adw.ExpanderRow() { title = _("Advanced feed settings"), subtitle = _("For personal feeds, keep the default node.") };
        advanced.add_row(xmpp_node);
        social_group.add(advanced);
        social.append(social_group);
        var read = button(_("Read XMPP feed"));
        read.clicked.connect(() => load_social.begin());
        social.append(read);
        var subscribe = button(_("Subscribe to this XMPP feed"));
        subscribe.clicked.connect(() => subscribe_social.begin());
        social.append(subscribe);
        social.append(label(_("Shows up to 100 recent posts. Images and external content are not loaded automatically.")));
        social.append(social_entries);
        pages.add_titled(social, "xmpp", _("Read XMPP feeds"));
        var own = new Box(Orientation.VERTICAL, 10);
        own.append(label(_("Your first published post creates a personal feed on your XMPP server, if the server supports it. Your server stores the posts so others can read them while DinoX is closed.")));
        own.append(label(_("Share the selected account's XMPP address with your readers. They need a client with feed support and permission to read your feed. DinoX does not currently show a list of your subscribers.")));
        own.append(label(_("Your feed changes when you publish or remove a post. Web feeds are not copied into it automatically. When publishing, choose who may read it; posts are not end-to-end encrypted.")));
        var publish = button(_("Write a post in my feed…"));
        publish.clicked.connect(() => compose(null));
        own.append(publish);
        var read_own = button(_("Read my feed"));
        read_own.clicked.connect(() => {
            Account? account = selected_account();
            if (account == null) return;
            xmpp_address.text = ((!) account).bare_jid.to_string();
            xmpp_node.text = Feeds.Social.MICROBLOG;
            pages.visible_child_name = "xmpp";
            load_social.begin();
        });
        own.append(read_own);
        pages.add_titled(own, "own", _("My XMPP feed"));
        pages.add_titled(subscriptions, "subscriptions", _("Subscriptions"));
        ToggleButton? first_page_button = null;
        string[] page_names = {"web", "xmpp", "own", "subscriptions"};
        string[] page_titles = {_("Web feeds"), _("Read XMPP feeds"), _("My XMPP feed"), _("Subscriptions")};
        for (int i = 0; i < page_names.length; i++) {
            var page_button = page_navigation_button(page_names[i], page_titles[i]);
            if (first_page_button == null) first_page_button = page_button;
            else page_button.set_group(first_page_button);
            navigation.attach(page_button, i % 2, i / 2);
        }
        account_choice.notify["selected"].connect(() => {
            cancel.cancel(); cancel = new Cancellable();
            loaded_entries = null; loaded_account = null;
            displayed_social_source = ""; displayed_social_node = "";
            clear(web_entries); clear(social_entries);
            refresh_subscriptions();
        });
        changed_handler = service.changed.connect(refresh_subscriptions);
        social_handler = service.social.updated.connect((account, source, node) => {
            if (dialog_closed || busy || pages.visible_child_name != "xmpp" || selected_account() != account ||
                    source != displayed_social_source || node != displayed_social_node ||
                    xmpp_address.text.strip() != source || xmpp_node.text.strip() != node || refresh_source != 0) return;
            refresh_source = Timeout.add(300, () => { refresh_source = 0; if (!dialog_closed && !busy) load_social.begin(); return Source.REMOVE; });
        });
        closed.connect(cleanup);
        // Parent destruction can unroot a dialog without a user close action.
        unrealize.connect(cleanup);
        refresh_subscriptions();
        if (accounts.is_empty) feedback.label = _("Connect an account to use feeds.");
    }

    public override void unmap() {
        Util.clear_focus_before_detach(this);
        base.unmap();
    }

    private void cleanup() {
        if (dialog_closed) return;
        dialog_closed = true; cancel.cancel();
        var closing_dialogs = new Gee.ArrayList<Adw.Dialog>();
        closing_dialogs.add_all(child_dialogs);
        foreach (Adw.Dialog dialog in closing_dialogs) dialog.force_close();
        child_dialogs.clear();
        if (refresh_source != 0) { Source.remove(refresh_source); refresh_source = 0; }
        service.disconnect(changed_handler); service.social.disconnect(social_handler);
    }

    private Account? selected_account() {
        return account_choice.selected < accounts.size ? accounts[(int) account_choice.selected] : null;
    }
    private ToggleButton page_navigation_button(string name, string title) {
        var toggle = new ToggleButton.with_label(title) { hexpand = true };
        var text = toggle.child as Label;
        if (text != null) { text.wrap = true; text.wrap_mode = Pango.WrapMode.WORD_CHAR; }
        toggle.toggled.connect((button) => { if (button.active) pages.visible_child_name = name; });
        pages.bind_property("visible-child-name", toggle, "active", BindingFlags.SYNC_CREATE,
            (binding, source, ref target) => { target.set_boolean(source.get_string() == name); return true; });
        return toggle;
    }
    private static Label label(string text) { return new Label(text) { wrap = true, wrap_mode = Pango.WrapMode.WORD_CHAR, max_width_chars = 55, xalign = 0, selectable = false }; }
    private static Button button(string text) {
        var button = new Button.with_label(text) { halign = Align.FILL };
        var label = button.get_child() as Label;
        if (label != null) label.wrap = true;
        return button;
    }
    private static void clear(Box box) {
        Util.clear_focus_before_detach(box);
        while (box.get_first_child() != null) box.remove(box.get_first_child());
    }
    private void working(bool value) {
        // GtkText must receive focus-out while it is still sensitive. Otherwise
        // its cursor-blink callback can survive GTK's deferred focus change.
        if (value) Util.clear_focus_before_detach(controls);
        busy = value;
        controls.sensitive = !value;
    }
    private void failed(Error error) { if (!dialog_closed) feedback.label = _("Feed operation failed: %s").printf(error.message); }

    private async void load_web() {
        Account? account = selected_account();
        if (account == null || busy) return;
        working(true); feedback.label = _("Loading…");
        loaded_entries = null; loaded_account = null; clear(web_entries);
        string source = web_url.text.strip();
        try {
            var result = yield service.fetch((!) account, source, "", "", cancel);
            if (dialog_closed || selected_account() != account) return;
            loaded_account = account; loaded_url = source; loaded_entries = result.entries;
            show_entries(web_entries, result.entries, false);
            feedback.label = _("%u articles loaded. Select one to preview it before sharing.").printf(result.entries.size);
        } catch (Error e) { failed(e); }
        finally { working(false); }
    }

    private async void load_social() {
        Account? account = selected_account();
        if (account == null || busy) return;
        working(true); feedback.label = _("Loading…"); clear(social_entries);
        string source = xmpp_address.text.strip(), node = xmpp_node.text.strip();
        try {
            source = Feeds.Social.service_jid(source).to_string();
            xmpp_address.text = source;
            var entries = yield service.social.read((!) account, source, node, cancel);
            if (dialog_closed || selected_account() != account) return;
            displayed_social_source = source; displayed_social_node = node;
            show_entries(social_entries, entries, true);
            feedback.label = _("%u posts loaded.").printf(entries.size);
        } catch (Error e) { failed(e); }
        finally { working(false); }
    }

    private void show_entries(Box box, Gee.List<Feeds.Entry> entries, bool social, int offset = 0) {
        int end = int.min(offset + 20, entries.size);
        for (int i = offset; i < end; i++) {
            Feeds.Entry entry = entries[i];
            var card = new Box(Orientation.VERTICAL, 6) { margin_bottom = 12 };
            var title = label(entry.title); title.add_css_class("heading"); card.append(title);
            card.append(label(Feeds.shorten(entry.text, 220)));
            if (entry.published != "") card.append(label(entry.published));
            var share = button(_("Preview and share…"));
            Account? origin = selected_account();
            share.clicked.connect(() => { if (origin != null) share_article((!) origin, entry); });
            card.append(share);
            if (social) {
                string source = displayed_social_source, node = displayed_social_node;
                var reply = button(_("Reply in my feed…"));
                reply.clicked.connect(() => compose(entry, source, node));
                card.append(reply);
                if (origin != null && source == ((!) origin).bare_jid.to_string() && node == Feeds.Social.MICROBLOG) {
                    var remove = button(_("Remove my post…"));
                    remove.add_css_class("destructive-action");
                    remove.clicked.connect(() => confirm_remove_post((!) origin, entry));
                    card.append(remove);
                }
            }
            card.append(new Separator(Orientation.HORIZONTAL));
            box.append(card);
        }
        if (end < entries.size) {
            var more = button(_("Show more articles"));
            more.clicked.connect(() => { box.remove(more); show_entries(box, entries, social, end); });
            box.append(more);
        }
    }

    private ArrayList<Conversation> targets(Account account, DropDown choice) {
        var result = new ArrayList<Conversation>();
        var names = new StringList(null);
        foreach (Conversation conversation in interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_active_conversations(account)) {
            if (conversation.type_ != Conversation.Type.CHAT && conversation.type_ != Conversation.Type.GROUPCHAT) continue;
            if (conversation.counterpart.domainpart == "mqtt.local") continue;
            result.add(conversation);
            names.append(Util.get_conversation_display_name(interactor, conversation) + " — " + conversation.counterpart.to_string());
        }
        choice.model = names;
        if (preferred_target != null) for (int i = 0; i < result.size; i++) if (result[i].id == ((!) preferred_target).id) choice.selected = i;
        return result;
    }

    private Adw.Dialog child_dialog(string title, string action_label, out Box body, out Button action) {
        var dialog = new FeedActionDialog() { title = title, content_width = 500, content_height = 500, follows_content_size = false };
        var toolbar = new Adw.ToolbarView();
        var header = new Adw.HeaderBar() { show_start_title_buttons = false, show_end_title_buttons = false };
        var cancel_button = new Button.with_label(_("Cancel"));
        cancel_button.clicked.connect(() => { dialog.close(); });
        action = new Button.with_label(action_label);
        action.add_css_class("suggested-action");
        header.pack_start(cancel_button);
        header.pack_end(action);
        toolbar.add_top_bar(header);
        body = new Box(Orientation.VERTICAL, 12) { margin_start = 18, margin_end = 18, margin_top = 12, margin_bottom = 18 };
        toolbar.content = new ScrolledWindow() { hscrollbar_policy = PolicyType.NEVER, vexpand = true, child = body };
        dialog.child = toolbar;
        child_dialogs.add(dialog);
        dialog.closed.connect(() => { child_dialogs.remove(dialog); });
        return dialog;
    }

    private static TextView editor(string text) {
        var view = new TextView() { wrap_mode = WrapMode.WORD_CHAR, height_request = 160, vexpand = true };
        view.buffer.text = text;
        Util.TextContextMenu.attach(view);
        return view;
    }

    private void share_article(Account account, Feeds.Entry entry) {
        Box body; Button send;
        var window = child_dialog(_("Share feed article"), _("Send"), out body, out send);
        send.tooltip_text = _("Send to selected chat");
        body.append(label(_("Account: %s").printf(account.bare_jid.to_string())));
        body.append(label(_("Destination chat")));
        var choice = new DropDown(null, null); var conversations = targets(account, choice); body.append(choice);
        var mode = label(""); body.append(mode);
        var preview = editor(entry.message()); body.append(preview);
        var status = label(""); body.append(status);
        Encryption expected_encryption = update_target_label(choice, conversations, mode);
        choice.notify["selected"].connect(() => { expected_encryption = update_target_label(choice, conversations, mode); });
        send.sensitive = !conversations.is_empty;
        send.clicked.connect(() => {
            if (choice.selected >= conversations.size) return;
            if (conversations[(int) choice.selected].encryption != expected_encryption) {
                expected_encryption = update_target_label(choice, conversations, mode);
                status.label = _("The chat encryption changed. Review the updated setting before confirming again.");
                return;
            }
            try { service.send(conversations[(int) choice.selected], preview.buffer.text); window.close(); }
            catch (Error e) { status.label = _("Sending failed: %s").printf(e.message); }
        });
        window.present(this);
    }

    private Encryption update_target_label(DropDown choice, ArrayList<Conversation> conversations, Label label) {
        if (choice.selected >= conversations.size) { label.label = _("No chat is available for this account."); return Encryption.NONE; }
        var conversation = conversations[(int) choice.selected];
        string encryption = conversation.encryption == Encryption.OMEMO ? "OMEMO" :
            conversation.encryption == Encryption.PGP ? "OpenPGP" : _("Unencrypted");
        label.label = _("Uses this chat's encryption: %s").printf(encryption);
        return conversation.encryption;
    }

    private void configure_automatic() {
        if (loaded_account == null || loaded_entries == null || selected_account() != loaded_account || loaded_url != web_url.text.strip()) {
            feedback.label = _("Load the feed first, then choose its destination."); return;
        }
        Account account = (!) loaded_account;
        string source = loaded_url;
        var initial = (!) loaded_entries;
        Box body; Button enable;
        var window = child_dialog(_("Automatically post new articles"), _("Enable"), out body, out enable);
        enable.tooltip_text = _("Enable automatic posting");
        body.append(label(source)); body.append(label(_("Account: %s").printf(account.bare_jid.to_string())));
        body.append(label(_("Existing articles will not be sent. New articles are checked only while DinoX runs. Up to five are queued per check. Normal chat encryption applies; changing it pauses this subscription.")));
        body.append(label(_("Destination chat")));
        var choice = new DropDown(null, null); var conversations = targets(account, choice); body.append(choice);
        var mode = label(""); body.append(mode);
        Encryption expected_encryption = update_target_label(choice, conversations, mode);
        choice.notify["selected"].connect(() => { expected_encryption = update_target_label(choice, conversations, mode); });
        body.append(label(_("Check interval (minutes)")));
        var interval = new SpinButton.with_range(5, 1440, 5) { value = web_interval.value }; body.append(interval);
        Util.TextContextMenu.attach(interval);
        var status = label(""); body.append(status);
        enable.sensitive = !conversations.is_empty;
        enable.clicked.connect(() => {
            if (choice.selected >= conversations.size) return;
            Conversation target = conversations[(int) choice.selected];
            if (target.encryption != expected_encryption) {
                expected_encryption = update_target_label(choice, conversations, mode);
                status.label = _("The chat encryption changed. Review the updated setting before confirming again.");
                return;
            }
            try {
                if (!service.can_send(target)) throw new IOError.PERMISSION_DENIED(_("The selected chat cannot send messages now."));
                service.store.add(account.id, Feeds.Parser.http_url(source), "", target.id, (int) target.encryption, interval.get_value_as_int(), initial);
                refresh_subscriptions(); window.close();
                feedback.label = _("Subscription enabled. Existing articles were skipped.");
            } catch (Error e) { status.label = _("Could not enable subscription: %s").printf(e.message); }
        });
        window.present(this);
    }

    private async void subscribe_social() {
        Account? account = selected_account(); if (account == null || busy) return;
        working(true);
        try {
            yield service.social.subscribe((!) account, xmpp_address.text.strip(), xmpp_node.text.strip());
            if (!dialog_closed) { feedback.label = _("Subscription saved. The server may require the owner's approval."); refresh_subscriptions(); }
        } catch (Error e) { failed(e); }
        finally { working(false); }
    }

    private void refresh_subscriptions() {
        if (dialog_closed) return;
        clear(subscriptions);
        subscriptions.append(label(_("These subscriptions belong to the selected account. Stopping automatic posting keeps messages already sent. Unsubscribing from an XMPP feed stops notifications; it does not delete the author's posts.")));
        Account? account = selected_account(); if (account == null) return;
        var saved = service.store.list();
        for (int kind = 0; kind < 2; kind++) {
          bool xmpp = kind == 1;
          var heading = label(xmpp ? _("XMPP feed subscriptions") : _("Automatic posting to chats"));
          heading.add_css_class("heading"); subscriptions.append(heading);
          bool found = false;
          foreach (Feeds.Subscription subscription in saved) {
            if (subscription.account_id != ((!) account).id || subscription.is_xmpp != xmpp) continue;
            found = true;
            var card = new Box(Orientation.VERTICAL, 6);
            card.append(label(subscription.source + (subscription.is_xmpp ? "\n" + subscription.node : "")));
            if (!subscription.is_xmpp) {
                Conversation? target = interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation_by_id(subscription.target_id);
                card.append(label(target != null ? _("Chat: %s").printf(Util.get_conversation_display_name(interactor, (!) target)) : _("Destination chat unavailable")));
                card.append(label(subscription.enabled ? _("Automatic posting enabled") : _("Automatic posting paused")));
                var interval_group = new Adw.PreferencesGroup();
                var interval = new Adw.SpinRow.with_range(5, 1440, 5) { title = _("Check interval (minutes)"), subtitle = _("5 minutes to 24 hours; default: 30 minutes."), value = subscription.interval };
                Util.TextContextMenu.attach(interval);
                var save_interval = new Button.with_label(_("Save interval")) { valign = Align.CENTER };
                save_interval.clicked.connect(() => {
                    try {
                        service.store.set_interval(subscription.id, ((!) account).id, (int) interval.value);
                        feedback.label = _("Check interval saved.");
                    } catch (Error e) { failed(e); }
                });
                interval_group.add(interval); card.append(interval_group);
                card.append(save_interval);
                card.append(label(subscription.checked > 0 ? _("Last check: %s").printf(new DateTime.from_unix_local(subscription.checked).format("%x %X")) : _("Not checked yet")));
                var toggle = button(subscription.enabled ? _("Pause") : _("Resume with current chat encryption"));
                toggle.clicked.connect(() => {
                    try {
                        if (target == null) return;
                        service.store.set_enabled(subscription.id, !subscription.enabled, (int) ((!) target).encryption); refresh_subscriptions();
                    } catch (Error e) { failed(e); }
                });
                card.append(toggle);
            }
            if (subscription.status == "encryption-changed") card.append(label(_("Paused because the chat encryption changed.")));
            else if (subscription.status == "subscribed") card.append(label(_("Subscribed")));
            else if (subscription.status == "pending") card.append(label(_("Waiting for the feed owner's approval.")));
            else if (subscription.status != "" && subscription.status != "ok") card.append(label(_("Server status: %s").printf(subscription.status)));
            var open = button(_("Read feed"));
            open.clicked.connect(() => {
                if (subscription.is_xmpp) { xmpp_address.text = subscription.source; xmpp_node.text = subscription.node; pages.visible_child_name = "xmpp"; load_social.begin(); }
                else { web_url.text = subscription.source; pages.visible_child_name = "web"; load_web.begin(); }
            }); card.append(open);
            var remove = button(subscription.is_xmpp ? _("Unsubscribe") : _("Stop automatic posting"));
            remove.clicked.connect(() => remove_subscription.begin((!) account, subscription)); card.append(remove);
            card.append(new Separator(Orientation.HORIZONTAL)); subscriptions.append(card);
          }
          if (!found) subscriptions.append(label(xmpp ? _("No XMPP feeds subscribed for this account.") : _("No automatic posting configured for this account.")));
        }
    }

    private async void remove_subscription(Account account, Feeds.Subscription subscription) {
        if (busy) return; working(true);
        try {
            if (subscription.is_xmpp) yield service.social.unsubscribe(account, subscription);
            else service.store.remove(subscription.id);
            refresh_subscriptions();
        } catch (Error e) { failed(e); }
        finally { working(false); }
    }

    private void compose(Feeds.Entry? reply, string source = "", string node = "") {
        Account? account = selected_account(); if (account == null) return;
        Box body; Button publish;
        var window = child_dialog(reply == null ? _("Write a post") : _("Reply in my feed"), _("Publish"), out body, out publish);
        body.append(label(_("Account: %s").printf(((!) account).bare_jid.to_string())));
        body.append(label(_("You are publishing a post in your personal XMPP feed. Posts are not end-to-end encrypted.")));
        if (reply != null) body.append(label(_("Reply to: %s").printf(((!) reply).title)));
        var public_feed = new CheckButton.with_label(_("Public feed (anyone can read it)")); body.append(public_feed);
        body.append(label(_("Without the checkmark, only contacts you have allowed to see your online status can read your feed. They can also read it while you are offline.")));
        var access_help = new Expander(null) {
            label_widget = label(_("Check or grant contact access"))
        };
        var access_steps = new Box(Orientation.VERTICAL, 8) { margin_top = 8 };
        access_steps.append(label(_("Check: Open the contact's chat, then Conversation details → About → Contact permissions.")));
        access_steps.append(label(_("Grant access: Accept the contact's request to see your online status. When adding a contact, you can also select “Also share my online status”.")));
        access_help.child = access_steps;
        body.append(access_help);
        body.append(label(_("This choice applies to the whole feed. You cannot change an existing feed's visibility here.")));
        var title = new Entry() { placeholder_text = _("Title") }; body.append(title);
        Util.TextContextMenu.attach(title);
        var text = editor(""); body.append(text);
        var status = label(""); body.append(status);
        string item_id = Uuid.string_random(); // retained on retry, including uncertain responses
        publish.clicked.connect(() => {
            publish.sensitive = false;
            service.social.publish.begin((!) account, item_id, title.text, text.buffer.text, public_feed.active,
                reply != null ? Feeds.Social.item_uri(source, node, ((!) reply).item_id) : null, reply != null ? ((!) reply).id : null,
                (obj, result) => {
                    try { service.social.publish.end(result); window.close(); if (!dialog_closed) feedback.label = _("Post published."); }
                    catch (Error e) { status.label = _("Publishing failed: %s").printf(e.message); publish.sensitive = true; }
                });
        }); window.present(this);
    }

    private void confirm_remove_post(Account account, Feeds.Entry entry) {
        var dialog = new Adw.AlertDialog(_("Remove this post?"), entry.title);
        dialog.add_response("cancel", _("Cancel")); dialog.add_response("remove", _("Remove"));
        dialog.set_response_appearance("remove", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.response.connect((response) => {
            if (response != "remove") return;
            service.social.retract.begin(account, entry.item_id, (_, result) => {
                try { service.social.retract.end(result); if (!dialog_closed) load_social.begin(); }
                catch (Error e) { failed(e); }
            });
        }); dialog.present(this);
    }
}

private class FeedActionDialog : Adw.Dialog {
    public override void unmap() {
        Util.clear_focus_before_detach(this);
        base.unmap();
    }
}
}
