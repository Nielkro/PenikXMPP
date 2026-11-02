/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gtk;
using Adw;
using Gee;
using Dino.Entities;

namespace Dino.Ui {

    public class StickerManagerDialog : Adw.PreferencesDialog {
        private StreamInteractor stream_interactor;
        private Account? account;
        private bool dialog_closed = false;
        private HashSet<string> publishing_packs = new HashSet<string>();
        private Dino.Stickers? stickers_service;
        private ulong publishing_handler_id = 0;
        private ulong importing_handler_id = 0;
        
        private Adw.PreferencesPage page;
        private Adw.PreferencesGroup packs_group;
        
        public signal void packs_changed();

        public StickerManagerDialog(StreamInteractor stream_interactor, Conversation? conversation) {
            this.stream_interactor = stream_interactor;
            this.account = conversation != null ? conversation.account : null;
            this.closed.connect(() => {
                dialog_closed = true;
                disconnect_publication_signal();
            });
            stickers_service = stream_interactor.get_module<Dino.Stickers>(Dino.Stickers.IDENTITY);
            if (stickers_service != null) {
                var manager_weak = WeakRef(this);
                publishing_handler_id = stickers_service.publishing_changed.connect((changed_account, pack_id, publishing) => {
                    var manager = manager_weak.get() as StickerManagerDialog;
                    if (manager != null && !manager.dialog_closed && manager.account != null
                            && manager.account.id == changed_account.id) manager.refresh_packs();
                });
                importing_handler_id = stickers_service.importing_changed.connect((changed_account, pack_id, importing) => {
                    var manager = manager_weak.get() as StickerManagerDialog;
                    if (manager != null && !manager.dialog_closed && manager.account != null
                            && manager.account.id == changed_account.id) manager.refresh_packs();
                });
            }

            this.title = _("Sticker Packs");
            this.content_width = 500;
            this.content_height = 600;

            page = new Adw.PreferencesPage();
            this.add(page);

            // Import Group
            var import_group = new Adw.PreferencesGroup();
            import_group.title = _("Add Stickers");
            if (account != null) import_group.description = _("Account: %s").printf(account.bare_jid.to_string());
            page.add(import_group);

            var import_row = new Adw.ActionRow();
            import_row.title = _("Import from Link");
            import_row.subtitle = _("Paste an xmpp: sticker pack link");
            import_row.activatable = true;
            import_row.add_suffix(new Image.from_icon_name("list-add-symbolic"));
            import_row.activated.connect(show_import_dialog);
            import_group.add(import_row);

            var folder_row = new Adw.ActionRow();
            folder_row.title = _("Import from Folder");
            folder_row.subtitle = _("Add images from a folder as a sticker pack");
            folder_row.activatable = true;
            folder_row.add_suffix(new Image.from_icon_name("folder-open-symbolic"));
            folder_row.activated.connect(open_folder_import);
            import_group.add(folder_row);

            // Installed Packs Group
            packs_group = new Adw.PreferencesGroup();
            packs_group.title = _("Installed Packs");
            page.add(packs_group);

            refresh_packs();
        }

        private Gtk.Window? get_parent_window() {
            return this.get_root() as Gtk.Window;
        }

        private void disconnect_publication_signal() {
            if (stickers_service != null && publishing_handler_id != 0) {
                SignalHandler.disconnect(stickers_service, publishing_handler_id);
                publishing_handler_id = 0;
            }
            if (stickers_service != null && importing_handler_id != 0) {
                SignalHandler.disconnect(stickers_service, importing_handler_id);
                importing_handler_id = 0;
            }
        }

        public override void dispose() {
            dialog_closed = true;
            disconnect_publication_signal();
            base.dispose();
        }

        private void refresh_packs() {
            if (dialog_closed) return;
            page.remove(packs_group);
            packs_group = new Adw.PreferencesGroup();
            packs_group.title = _("Installed Packs");
            page.add(packs_group);

            if (account == null) return;

            var stickers = stream_interactor.get_module<Dino.Stickers>(Dino.Stickers.IDENTITY);
            if (stickers == null) return;

            var packs = stickers.get_packs(account);
            if (packs.size == 0) {
                var empty_row = new Adw.ActionRow();
                empty_row.title = _("No sticker packs installed");
                packs_group.add(empty_row);
                return;
            }

            foreach (var pack in packs) {
                var row = new Adw.ActionRow();
                row.use_markup = false;
                row.title = (pack.name != null && pack.name != "") ? pack.name : pack.pack_id;
                row.subtitle = pack.summary ?? "";
                
                bool publishing = publishing_packs.contains(pack.pack_id) || stickers.is_pack_publishing(account, pack.pack_id);
                bool importing = stickers.is_pack_importing(account, pack.pack_id);
                var delete_btn = new Button.with_label(_("Remove"));
                delete_btn.add_css_class("flat");
                delete_btn.add_css_class("destructive-action");
                delete_btn.tooltip_text = _("Remove Pack");
                delete_btn.valign = Align.CENTER;
                delete_btn.sensitive = !publishing;
                
                delete_btn.clicked.connect(() => {
                    confirm_delete(pack);
                });

                if (pack.source_jid != null && pack.source_jid != "" && pack.source_node != null && pack.source_node != "") {
                    var share_btn = new Button.with_label(_("Copy Link"));
                    share_btn.add_css_class("flat");
                    share_btn.tooltip_text = _("Copy Share Link");
                    share_btn.valign = Align.CENTER;
                    share_btn.clicked.connect(() => {
                        copy_share_link(pack);
                    });
                    row.add_suffix(share_btn);
                } else {
                    var publish_btn = new Button.with_label(importing ? _("Importing…") : publishing ? _("Sharing…") : _("Share Pack"));
                    publish_btn.add_css_class("flat");
                    publish_btn.tooltip_text = _("Publish Pack");
                    publish_btn.valign = Align.CENTER;
                    publish_btn.sensitive = !publishing && !importing;
                    publish_btn.clicked.connect(() => {
                        confirm_publish(pack);
                    });
                    row.add_suffix(publish_btn);
                }
                
                row.add_suffix(delete_btn);
                packs_group.add(row);
            }
        }

        private void copy_share_link(Dino.Stickers.StickerPack pack) {
            if (pack.source_jid == null || pack.source_node == null) return;
            
            // import_pack stores the source PubSub item ID as pack_id.
            
            string item_id = pack.pack_id;
            string uri = "xmpp:%s?pubsub;action=retrieve;node=%s;item=%s".printf(
                pack.source_jid,
                Uri.escape_string(pack.source_node, "", false),
                Uri.escape_string(item_id, "", false)
            );
            
            var clipboard = this.get_display().get_clipboard();
            clipboard.set_text(uri);
            
            var toast = new Adw.Toast(_("Link copied to clipboard"));
            this.add_toast(toast);
        }

        private void confirm_publish(Dino.Stickers.StickerPack pack) {
            if (dialog_closed || publishing_packs.contains(pack.pack_id)) return;
            if (account != null && stickers_service != null && stickers_service.is_pack_importing(account, pack.pack_id)) return;
            var dialog = new Adw.AlertDialog(_("Share Sticker Pack?"),
                _("This uploads the stickers and publishes their pack information through your XMPP account. Anyone with the link can retrieve the pack."));
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("share", _("Share Pack"));
            dialog.set_response_appearance("share", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";
            dialog.response.connect((response) => {
                if (response == "share" && !dialog_closed) publish_pack(pack);
            });
            dialog.present(this);
        }

        private void publish_pack(Dino.Stickers.StickerPack pack) {
            if (account == null || dialog_closed || publishing_packs.contains(pack.pack_id)) return;
            
            var stickers = stream_interactor.get_module<Dino.Stickers>(Dino.Stickers.IDENTITY);
            if (stickers == null) return;

            publishing_packs.add(pack.pack_id);
            refresh_packs();
            var toast = new Adw.Toast(_("Publishing sticker pack…"));
            this.add_toast(toast);
            
            stickers.publish_pack.begin(account, pack.pack_id, (obj, res) => {
                try {
                    string uri = stickers.publish_pack.end(res);
                    if (dialog_closed) return;
                    var clipboard = this.get_display().get_clipboard();
                    clipboard.set_text(uri);
                    
                    var success_toast = new Adw.Toast(_("Pack published! Link copied."));
                    this.add_toast(success_toast);
                    
                    packs_changed();
                } catch (Error e) {
                    if (dialog_closed) return;
                    var err_dialog = new Adw.AlertDialog(_("Publish Failed"), e.message);
                    err_dialog.add_response("ok", _("OK"));
                    err_dialog.present(this);
                } finally {
                    publishing_packs.remove(pack.pack_id);
                    if (!dialog_closed) refresh_packs();
                }
            });
        }

        private void confirm_delete(Dino.Stickers.StickerPack pack) {
            if (dialog_closed || publishing_packs.contains(pack.pack_id)) return;
            var dialog = new Adw.AlertDialog(
                _("Remove Sticker Pack?"),
                _("Are you sure you want to remove '%s'?").printf(pack.name ?? pack.pack_id)
            );
            dialog.add_response("cancel", _("Cancel"));
            dialog.add_response("remove", _("Remove"));
            dialog.set_response_appearance("remove", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";
            
            dialog.response.connect((response) => {
                if (response == "remove" && !dialog_closed) {
                    delete_pack(pack);
                }
            });
            
            dialog.present(this);
        }

        private void delete_pack(Dino.Stickers.StickerPack pack) {
            var stickers = stream_interactor.get_module<Dino.Stickers>(Dino.Stickers.IDENTITY);
            if (stickers == null || account == null || dialog_closed || publishing_packs.contains(pack.pack_id)) return;

            try {
                stickers.remove_pack(account, pack.pack_id);
                refresh_packs();
                packs_changed();
            } catch (Error e) {
                var err_dialog = new Adw.AlertDialog(_("Error"), e.message);
                err_dialog.add_response("ok", _("OK"));
                err_dialog.present(this);
            }
        }

        private void show_import_dialog() {
            var input_dialog = new InputDialog(_("Import Sticker Pack"), _("Paste an xmpp: sticker pack link"));
            input_dialog.response.connect((text) => {
                if (text != null && text.strip() != "" && !dialog_closed) {
                    start_import(text.strip());
                }
            });
            input_dialog.present(this);
        }

        private void start_import(string uri) {
            Xmpp.Jid src;
            string node;
            string item;
            
            if (!try_parse_sticker_pack_uri(uri, out src, out node, out item)) {
                var err = new Adw.AlertDialog(_("Invalid sticker pack link"), _("The provided text is not a valid sticker pack link."));
                err.add_response("ok", _("OK"));
                err.present(this);
                return;
            }

            var dialog = new Dino.Ui.StickerPackImportDialog(stream_interactor, src, node, item, account);
            Gtk.Window? parent_window = get_parent_window();
            if (parent_window != null) dialog.set_transient_for(parent_window);
            dialog.close_request.connect(() => {
                dialog.destroy();
                if (!dialog_closed) {
                    refresh_packs();
                    packs_changed();
                }
                return true;
            });
            dialog.present();
        }

        private void open_folder_import() {
            if (account == null || dialog_closed) return;
            Account folder_account = account;
            
            var chooser = new Gtk.FileDialog();
            chooser.title = _("Select Folder");
            chooser.accept_label = _("Select");
            
            chooser.select_folder.begin(get_parent_window(), null, (obj, res) => {
                try {
                    File? folder = chooser.select_folder.end(res);
                    if (folder != null && !dialog_closed) {
                        string? path = folder.get_path();
                        if (path != null) {
                            var dialog = new StickerPackFolderImportDialog(stream_interactor, folder_account, path);
                            Gtk.Window? parent_window = get_parent_window();
                            if (parent_window != null) dialog.set_transient_for(parent_window);
                            dialog.pack_created.connect(() => {
                                if (!dialog_closed) {
                                    refresh_packs();
                                    packs_changed();
                                }
                            });
                            dialog.present();
                        }
                    }
                } catch (Error e) {
                    if (e is IOError.CANCELLED || e is Gtk.DialogError.DISMISSED || e is Gtk.DialogError.CANCELLED || dialog_closed) return;
                    var err = new Adw.AlertDialog(_("Could not open folder"), e.message);
                    err.add_response("ok", _("OK"));
                    err.present(this);
                }
            });
        }

        // Helper from original sticker_chooser.vala
        private bool try_parse_sticker_pack_uri(string uri, out Xmpp.Jid? source_jid, out string? node, out string? item) {
            source_jid = null;
            node = null;
            item = null;

            if (!uri.has_prefix("xmpp:")) return false;
            string content = uri.substring(5);
            
            int q_pos = content.index_of("?");
            if (q_pos <= 0) return false;

            string jid_str = content.substring(0, q_pos);
            string query_str = content.substring(q_pos + 1);

            try {
                source_jid = new Xmpp.Jid(jid_str);
            } catch (Xmpp.InvalidJidError e) {
                return false;
            }

            string[] parts = query_str.split(";");
            if (parts.length < 2) return false;
            if (parts[0] != "pubsub") return false;

            var options = new HashMap<string, string>();
            for (int i = 1; i < parts.length; i++) {
                string p = parts[i];
                int eq = p.index_of("=");
                if (eq <= 0) continue;
                string k = p.substring(0, eq);
                string v = p.substring(eq + 1);
                string? decoded = Uri.unescape_string(v);
                if (decoded != null) options[k] = Util.sanitize_utf8(decoded);
            }

            if (!options.has_key("action") || options["action"] != "retrieve") return false;
            if (!options.has_key("node") || options["node"] != Xmpp.Xep.Stickers.NS_URI) return false;
            if (!options.has_key("item") || options["item"] == "") return false;

            node = options["node"];
            item = options["item"];
            return true;
        }
    }

    // Simple helper dialog for text input since Adw.AlertDialog doesn't support entries yet
    public class InputDialog : Adw.Dialog {
        public signal void response(string? text);
        private Entry entry;

        public InputDialog(string title, string placeholder) {
            this.title = title;
            this.content_width = 400;
            
            var box = new Box(Orientation.VERTICAL, 12);
            box.margin_top = 24;
            box.margin_bottom = 24;
            box.margin_start = 24;
            box.margin_end = 24;
            
            var label = new Label(title);
            label.add_css_class("title-2");
            box.append(label);
            
            entry = new Entry();
            entry.placeholder_text = placeholder;
            entry.activates_default = true;
            box.append(entry);
            
            var btn_box = new Box(Orientation.HORIZONTAL, 12);
            btn_box.halign = Align.CENTER;
            
            var cancel = new Button.with_label(_("Cancel"));
            cancel.clicked.connect(() => { response(null); this.close(); });
            
            var ok = new Button.with_label(_("OK"));
            ok.add_css_class("suggested-action");
            ok.clicked.connect(() => { response(entry.text); this.close(); });
            
            btn_box.append(cancel);
            btn_box.append(ok);
            box.append(btn_box);
            
            this.child = box;
            this.set_default_widget(ok);
        }
    }
}
