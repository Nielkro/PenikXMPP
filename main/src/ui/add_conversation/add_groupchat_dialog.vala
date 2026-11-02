using Gee;
using Gtk;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

[GtkTemplate (ui = "/im/dinox/dinox/add_conversation/add_groupchat_dialog.ui")]
protected class AddGroupchatDialog : Adw.Dialog {

    private static HashSet<string> pending_bookmark_keys = new HashSet<string>();

    [GtkChild] private unowned Stack accounts_stack;
    [GtkChild] private unowned AccountComboBox account_combobox;
    [GtkChild] private unowned Button ok_button;
    [GtkChild] private unowned Button cancel_button;
    [GtkChild] private unowned Entry jid_entry;
    [GtkChild] private unowned Entry alias_entry;
    [GtkChild] private unowned Entry nick_entry;
    [GtkChild] private unowned CheckButton private_room_checkbutton;
    [GtkChild] private unowned Button avatar_button;
    [GtkChild] private unowned Label avatar_label;

    private StreamInteractor stream_interactor;
    private bool alias_entry_changed = false;
    private bool suppress_alias_entry_changed = false;
    private bool creating = false;
    private bool dialog_closed = false;
    private File? selected_avatar_file = null;
    private uint join_request_id = 0;
    private Cancellable? join_cancellable = null;
    private Account? pending_join_account = null;
    private Jid? pending_join_jid = null;
    private string? pending_bookmark_key = null;
    private string? join_failure_detail = null;

    public AddGroupchatDialog(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
        ok_button.label = _("Add");
        ok_button.add_css_class("suggested-action"); // TODO why doesn't it work in XML
        accounts_stack.set_visible_child_name("combobox");
        account_combobox.initialize(stream_interactor);

        cancel_button.clicked.connect(() => { close(); });
        ok_button.clicked.connect(on_ok_button_clicked);
        avatar_button.clicked.connect(on_avatar_button_clicked);
        this.closed.connect(() => {
            dialog_closed = true;
            cancel_pending_join();
        });

        account_combobox.notify["active-account"].connect(() => {
            if (creating && !account_is_active_managed(pending_join_account)) {
                cancel_pending_join();
                set_creating(false);
                if (!dialog_closed) {
                    show_dialog_error(_("Could not add group chat"), _("The selected account is no longer active."));
                }
            }
            check_ok();
        });
        jid_entry.changed.connect(on_jid_key_release);
        alias_entry.changed.connect(() => {
            if (!suppress_alias_entry_changed) {
                alias_entry_changed = true;
            }
        });
        nick_entry.changed.connect(check_ok);
    }

    private void on_jid_key_release() {
        check_ok();
        if (!alias_entry_changed) {
            try {
                Jid parsed_jid = new Jid(get_effective_jid());
                set_alias_text_without_marking_changed(parsed_jid != null && parsed_jid.localpart != null ? parsed_jid.localpart : jid_entry.text);
            } catch (InvalidJidError e) {
                set_alias_text_without_marking_changed(jid_entry.text);
            }
        }
    }

    private void set_alias_text_without_marking_changed(string text) {
        suppress_alias_entry_changed = true;
        alias_entry.text = text;
        suppress_alias_entry_changed = false;
    }

    private string get_effective_jid() {
        string text = jid_entry.text;
        if (text.contains("@")) {
            return text;
        }
        var account = account_combobox.active_account;
        if (account != null) {
            return "%s@conference.%s".printf(text, account.domainpart);
        }
        return text;
    }

    private void check_ok() {
        Account? account = account_combobox.active_account;
        if (creating || !account_is_active_managed(account)) {
            ok_button.sensitive = false;
            return;
        }
        try {
            Jid parsed_jid = new Jid(get_effective_jid());
            ok_button.sensitive = parsed_jid != null && parsed_jid.localpart != null && parsed_jid.resourcepart == null;
        } catch (InvalidJidError e) {
            ok_button.sensitive = false;
        }
    }

    private void on_ok_button_clicked() {
        if (creating) return;
        Account? active_account = account_combobox.active_account;
        if (!account_is_active_managed(active_account)) return;
        try {
            Conference conference = new Conference();
            conference.jid = new Jid(get_effective_jid());
            conference.nick = nick_entry.text != "" ? nick_entry.text : null;
            conference.name = alias_entry.text;
            conference.autojoin = true;
            string bookmark_key = get_bookmark_key((!) active_account, conference.jid);
            if (pending_bookmark_keys.contains(bookmark_key)) {
                show_dialog_error(_("Could not add group chat"), _("This group chat is already being added"));
                return;
            }
            pending_bookmark_keys.add(bookmark_key);
            pending_bookmark_key = bookmark_key;
            join_failure_detail = null;
            uint request_id = ++join_request_id;
            account_combobox.allow_fallback_selection = false;
            set_creating(true);
            
            // Capture widget state before close() destroys the dialog
            bool want_private = private_room_checkbutton.active;
            File? avatar_file = selected_avatar_file;
            
            join_and_configure_room.begin((!) active_account, conference, want_private, avatar_file, request_id, (obj, res) => {
                string? joined_nick = join_and_configure_room.end(res);
                if (request_id != join_request_id) return;
                clear_pending_bookmark_key(bookmark_key);
                if (dialog_closed) return;
                if (!account_is_active_managed(active_account)) {
                    set_creating(false);
                    show_dialog_error(_("Could not add group chat"), _("The selected account is no longer active."));
                    return;
                }
                if (joined_nick != null) {
                    if (conference.nick == null) conference.nick = joined_nick;
                    MucManager muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
                    muc_manager.add_bookmark.begin((!) active_account, conference, (obj, add_res) => {
                        bool bookmark_added = muc_manager.add_bookmark.end(add_res);
                        if (request_id != join_request_id) return;
                        if (dialog_closed) return;
                        if (!bookmark_added) {
                            set_creating(false);
                            show_dialog_error(_("Could not add group chat"), _("The group was joined, but the bookmark could not be saved on the server."));
                            return;
                        }
                        can_close = true;
                        close();
                    });
                } else {
                    set_creating(false);
                    if (join_failure_detail != null) {
                        show_dialog_error(_("Could not add group chat"), join_failure_detail);
                    } else {
                        show_dialog_error(_("Could not join group chat"));
                    }
                }
            });
        } catch (InvalidJidError e) {
            warning("Ignoring invalid conference Jid: %s", e.message);
        }
    }

    private void cancel_pending_join() {
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
        clear_pending_bookmark_key();
    }

    private void clear_pending_bookmark_key(string? expected_key = null) {
        if (pending_bookmark_key == null) return;
        if (expected_key != null && (!) pending_bookmark_key != (!) expected_key) return;
        pending_bookmark_keys.remove((!) pending_bookmark_key);
        pending_bookmark_key = null;
    }

    private string get_bookmark_key(Account account, Jid jid) {
        return account.id.to_string() + "\n" + jid.bare_jid.to_string();
    }

    private void set_creating(bool creating) {
        this.creating = creating;
        if (!creating) {
            account_combobox.allow_fallback_selection = true;
        }

        account_combobox.sensitive = !creating;
        jid_entry.sensitive = !creating;
        alias_entry.sensitive = !creating;
        nick_entry.sensitive = !creating;
        private_room_checkbutton.sensitive = !creating;
        avatar_button.sensitive = !creating;
        cancel_button.sensitive = !creating;
        can_close = !creating;

        if (creating) {
            ok_button.sensitive = false;
        } else {
            check_ok();
        }
    }

    private async string? join_and_configure_room(Account account, Conference conference, bool want_private, File? avatar_file, uint request_id) {
        if (!account_is_active_managed(account)) return null;
        join_cancellable = new Cancellable();
        Cancellable current_cancellable = (!) join_cancellable;
        pending_join_account = account;
        pending_join_jid = conference.jid;
        // The bookmark is written only after a successful join so failed joins don't persist state.
        // already_autojoin=true keeps MucManager from writing a bookmark without the dialog alias;
        // override_leave_block=true still lets this manual join try a previously left room.
        Xep.Muc.JoinResult? join_result = yield stream_interactor.get_module<MucManager>(MucManager.IDENTITY).join(
            account,
            conference.jid,
            conference.nick,
            conference.password,
            true,
            current_cancellable,
            true
        );
        if (request_id != join_request_id || current_cancellable.is_cancelled()) return null;
        join_cancellable = null;
        pending_join_account = null;
        pending_join_jid = null;
        if (join_result == null || join_result.nick == null) {
            warning("Failed to join groupchat %s before configuration", conference.jid.to_string());
            return null;
        }
        if (!account_is_active_managed(account)) return null;

        // A status-201 join created a locked room which must be configured before it
        // is usable. Existing rooms belong to their owners and must not be rewritten
        // merely because this account added a bookmark for them.
        bool configured = yield configure_room_async(account, conference.jid,
            want_private, avatar_file, join_result.newly_created);
        if (!configured) return null;
        return join_result.nick;
    }

    private void on_avatar_button_clicked() {
        var dialog = new Gtk.FileDialog();
        dialog.title = _("Select Avatar");
        var filter = new FileFilter();
        filter.add_mime_type("image/png");
        filter.add_mime_type("image/jpeg");
        filter.add_mime_type("image/gif");
        filter.add_mime_type("image/webp");
        filter.name = _("Images");
        
        var filters = new GLib.ListStore(typeof(FileFilter));
        filters.append(filter);
        dialog.filters = filters;
        dialog.default_filter = filter;

        dialog.open.begin((Window) this.root, null, (obj, res) => {
            try {
                File avatar_file = dialog.open.end(res);
                if (dialog_closed) return;
                selected_avatar_file = avatar_file;
                avatar_label.label = Util.sanitize_utf8(avatar_file.get_basename());
            } catch (Error e) {
                // Cancelled or error
            }
        });
    }
    
    private async bool configure_room_async(Account account, Jid room_jid,
            bool want_private, File? avatar_file, bool newly_created) {
        if (!account_is_active_managed(account)) return false;
        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        MucManager.MucOwnerMutationContext? room_context = null;
        if (newly_created) {
            room_context = muc_manager.capture_current_owner_context(account,
                room_jid);
            if (room_context == null) {
                join_failure_detail = _("Room configuration could not be loaded");
                return false;
            }
            Xep.DataForms.DataForm? data_form = yield
                muc_manager.get_config_form_in_context(account,
                    (!) room_context);
            if (!account_is_active_managed(account)) return false;
            if (data_form == null) {
                join_failure_detail = _("Room configuration could not be loaded");
                return false;
            }

            bool? original_members_only = MucManager.get_members_only_config_value((!) data_form);
            muc_manager.set_mam_archiving_enabled((!) data_form, true);

            // Set explicit creation defaults so server-specific defaults don't
            // silently invert the user's public/private choice.
            foreach (Xep.DataForms.DataForm.Field field in ((!) data_form).fields) {
                switch (field.var) {
                    case "muc#roomconfig_membersonly":
                        if (field.type_ == Xep.DataForms.DataForm.Type.BOOLEAN) {
                            ((Xep.DataForms.DataForm.BooleanField) field).value = want_private;
                        }
                        break;
                    case "muc#roomconfig_whois":
                        if (field.type_ == Xep.DataForms.DataForm.Type.LIST_SINGLE) {
                            // Private rooms: "anyone" (non-anonymous) — needed for OMEMO
                            // Public rooms: "moderators" (semi-anonymous) — standard default
                            ((Xep.DataForms.DataForm.ListSingleField) field).value = want_private ? "anyone" : "moderators";
                        }
                        break;
                    case "muc#roomconfig_publicroom":
                        if (field.type_ == Xep.DataForms.DataForm.Type.BOOLEAN) {
                            ((Xep.DataForms.DataForm.BooleanField) field).value = !want_private;
                        }
                        break;
                    case "muc#roomconfig_persistentroom":
                        if (field.type_ == Xep.DataForms.DataForm.Type.BOOLEAN) {
                            ((Xep.DataForms.DataForm.BooleanField) field).value = true;
                        }
                        break;
                }
            }
            if (!account_is_active_managed(account)) return false;
            MucConfigSaveResult config_result = yield
                muc_manager.set_config_form_detailed_in_context(account,
                    (!) room_context, (!) data_form, original_members_only);
            if (config_result != MucConfigSaveResult.APPLIED &&
                    config_result !=
                        MucConfigSaveResult.APPLIED_LOCAL_SYNC_WARNING) {
                join_failure_detail = config_result ==
                        MucConfigSaveResult.APPLIED_SERVER_STATE_UNVERIFIED
                    ? _("The server acknowledged the room configuration, but its effective security settings could not be confirmed.")
                    : _("The server rejected the room configuration. Check your room permissions and try again.");
                return false;
            }
            if (want_private &&
                    !muc_manager.has_live_private_room_features(account,
                        room_jid)) {
                join_failure_detail = _("The server acknowledged the room configuration, but its effective security settings could not be confirmed.");
                return false;
            }
            if (want_private) {
                // The room-info update normally starts this already. The
                // explicit call covers servers whose creation/configuration
                // timing delivered that update before the joined lifecycle.
                muc_manager.query_private_muc_affiliation_snapshot.begin(
                    account, room_jid);
            }
        }

        if (avatar_file != null) {
            if (!account_is_active_managed(account)) return true;
            if (room_context == null) {
                room_context = muc_manager.capture_current_owner_context(
                    account, room_jid);
            }
            if (room_context == null ||
                    !muc_manager.is_current_owner_context(account,
                        (!) room_context)) {
                warning("Skipping MUC avatar upload without a current Owner context");
                return true;
            }
            MucManager.MucOwnerMutationContext avatar_context =
                (!) room_context;
            if (!muc_manager.try_begin_muc_avatar_mutation(account,
                    avatar_context.room)) {
                warning("Skipping concurrent MUC avatar upload for %s",
                    avatar_context.room.to_string());
                return true;
            }
            try {
                // Resize image if necessary (limit to 192px)
                const int MAX_PIXEL = 192;
                var file_stream = yield avatar_file.read_async();
                if (!account_is_active_managed(account) ||
                        !muc_manager.is_current_owner_context(account,
                            avatar_context)) {
                    yield file_stream.close_async();
                    return true;
                }
                Gdk.Pixbuf pixbuf;
                try {
                    pixbuf = yield new Gdk.Pixbuf.from_stream_async(file_stream);
                    if (!account_is_active_managed(account) ||
                            !muc_manager.is_current_owner_context(account,
                                avatar_context)) {
                        yield file_stream.close_async();
                        return true;
                    }
                } catch (Error decode_error) {
                    try {
                        file_stream.close();
                    } catch (Error close_error) {
                        debug("Failed to close avatar stream after decode failure: %s", close_error.message);
                    }
                    warning("Failed to decode avatar: %s", decode_error.message);
                    return true;
                }
                yield file_stream.close_async();
                if (!account_is_active_managed(account) ||
                        !muc_manager.is_current_owner_context(account,
                            avatar_context)) return true;

                if (pixbuf.width >= pixbuf.height && pixbuf.width > MAX_PIXEL) {
                    int dest_height = int.max(1, (int) ((float) MAX_PIXEL / pixbuf.width * pixbuf.height));
                    pixbuf = pixbuf.scale_simple(MAX_PIXEL, dest_height, Gdk.InterpType.BILINEAR);
                } else if (pixbuf.height > pixbuf.width && pixbuf.height > MAX_PIXEL) {
                    int dest_width = int.max(1, (int) ((float) MAX_PIXEL / pixbuf.height * pixbuf.width));
                    pixbuf = pixbuf.scale_simple(dest_width, MAX_PIXEL, Gdk.InterpType.BILINEAR);
                }

                uint8[] buffer;
                buffer = Dino.Ui.Util.pixbuf_to_png_bytes(pixbuf);
                Bytes bytes = new Bytes(buffer);
                
                // Preserve non-photo fields and require a confirmed IQ result
                // from the exact room generation before touching local cache.
                var vcard = yield
                    muc_manager.fetch_muc_vcard_in_owner_context(account,
                        avatar_context);
                if (vcard == null) vcard = new Xmpp.Xep.VCard.VCardInfo();
                vcard.photo = bytes;
                vcard.photo_type = "image/png";
                yield muc_manager.publish_muc_vcard_in_owner_context(account,
                    avatar_context, (!) vcard);
                if (!account_is_active_managed(account) ||
                        !muc_manager.is_current_owner_context(account,
                            avatar_context)) return true;

                string hash = Checksum.compute_for_bytes(ChecksumType.SHA1,
                    bytes);
                var avatar_manager = stream_interactor.get_module<AvatarManager>(AvatarManager.IDENTITY);
                yield avatar_manager.store_image(hash, bytes);
                if (!account_is_active_managed(account) ||
                        !muc_manager.is_current_owner_context(account,
                            avatar_context)) return true;
                avatar_manager.on_vcard_avatar_received(account,
                    avatar_context.room, hash);
            } catch (Error e) {
                warning("Failed to upload avatar: %s", e.message);
            } finally {
                muc_manager.finish_muc_avatar_mutation(account,
                    avatar_context.room);
            }
        }
        return true;
    }

    private void show_dialog_error(string title, string? body = null) {
        var dialog = new Adw.AlertDialog(title, body);
        dialog.add_response("ok", _("OK"));
        dialog.present((Window) this.root);
    }

    private bool account_is_active_managed(Account? account) {
        if (account == null || !((!) account).enabled) return false;
        foreach (Account managed_account in stream_interactor.get_accounts()) {
            if (managed_account == (!) account && managed_account.enabled) return true;
        }
        return false;
    }
}

}
