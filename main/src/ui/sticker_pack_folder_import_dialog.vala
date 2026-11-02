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
using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

public class StickerPackFolderImportDialog : Adw.Window {
    private StreamInteractor stream_interactor;
    private Account account;
    private string folder_path;

    private bool busy = false;
    private bool dialog_closed = false;
    private uint create_source_id = 0;
    private string? created_pack_id;

    private Label title_label = new Label("") { xalign = 0.0f, wrap = true };
    private Label summary_label = new Label("") { xalign = 0.0f, wrap = true, selectable = true };
    private Gtk.Spinner spinner = new Gtk.Spinner() { spinning = false, visible = false, width_request = 24, height_request = 24 };

    private Button cancel_button = new Button.with_label(_("Cancel"));
    private Button local_button = new Button.with_label(_("Local only"));
    private Button publish_button = new Button.with_label(_("Share and Copy Link"));

    private Button copy_button = new Button.with_label(_("Copy Link")) { sensitive = false };
    private Button retry_publish_button = new Button.with_label(_("Try Sharing Again")) { visible = false };
    private Label feedback_label = new Label("") { xalign = 0.0f, wrap = true };
    private Button close_button = new Button.with_label(_("Close"));

    private Gtk.Box actions_box = new Gtk.Box(Orientation.VERTICAL, 6) { halign = Align.FILL, hexpand = true };
    private Gtk.Box result_box = new Gtk.Box(Orientation.VERTICAL, 6) { halign = Align.FILL, hexpand = true, visible = false };

    private string? share_uri;

    public signal void pack_created(string pack_name);

    public StickerPackFolderImportDialog(StreamInteractor stream_interactor, Account account, string folder_path) {
        this.stream_interactor = stream_interactor;
        this.account = account;
        this.folder_path = folder_path;

        this.title = _("Import Sticker Pack");
        this.default_width = 460;
        this.default_height = 240;

        var box = new Gtk.Box(Orientation.VERTICAL, 12);
        box.margin_top = 12;
        box.margin_bottom = 12;
        box.margin_start = 12;
        box.margin_end = 12;

        // Adw.Window does not support gtk_window_set_titlebar(); keep header inside content.
        var header = new Adw.HeaderBar();
        header.decoration_layout = ":";

        // Title line with spinner (spinner shows immediately when starting).
        var title_row = new Gtk.Box(Orientation.HORIZONTAL, 8);
        spinner.valign = Align.CENTER;
        title_row.append(spinner);
        title_row.append(title_label);

        title_label.label = _("Import Sticker Pack");
        summary_label.label = _("Keep the pack on this device, or upload its stickers and publish the pack information so anyone with the link can retrieve it.");

        publish_button.add_css_class("suggested-action");

        // Stack actions under each other (old dialog style).
        cancel_button.halign = Align.FILL;
        cancel_button.hexpand = true;
        local_button.halign = Align.FILL;
        local_button.hexpand = true;
        publish_button.halign = Align.FILL;
        publish_button.hexpand = true;
        copy_button.halign = Align.FILL;
        copy_button.hexpand = true;
        close_button.halign = Align.FILL;
        close_button.hexpand = true;

        actions_box.append(publish_button);
        actions_box.append(local_button);
        actions_box.append(cancel_button);

        result_box.append(copy_button);
        result_box.append(retry_publish_button);
        result_box.append(close_button);

        box.append(header);
        box.append(new Label(_("Account: %s").printf(account.bare_jid.to_string())) { xalign = 0.0f, wrap = true });
        box.append(title_row);
        box.append(summary_label);
        box.append(feedback_label);
        box.append(new Gtk.Separator(Orientation.HORIZONTAL));
        box.append(actions_box);
        box.append(result_box);

        // Keep the dialog width pleasant.
        var clamp = new Adw.Clamp() { maximum_size = 520, tightening_threshold = 520, child = box, halign = Align.FILL };
        this.content = clamp;

        cancel_button.clicked.connect(() => this.close());
        close_button.clicked.connect(() => this.close());
        copy_button.clicked.connect(() => {
            if (share_uri == null || share_uri == "") return;
            var clipboard = this.get_display().get_clipboard();
            clipboard.set_text(share_uri);
            feedback_label.label = _("Link copied to clipboard");
        });

        local_button.clicked.connect(() => start_create(false));
        publish_button.clicked.connect(() => start_create(true));
        retry_publish_button.clicked.connect(() => start_create(true));
        this.close_request.connect(() => {
            mark_closed();
            return false;
        });
        ((Gtk.Widget) this).destroy.connect(mark_closed);
        ((Gtk.Widget) this).unrealize.connect(mark_closed);
    }

    private void mark_closed() {
        if (dialog_closed) return;
        dialog_closed = true;
        spinner.spinning = false;
        if (create_source_id != 0) {
            Source.remove(create_source_id);
            create_source_id = 0;
        }
    }

    public override void dispose() {
        mark_closed();
        base.dispose();
    }

    private void set_busy(bool busy) {
        this.busy = busy;

        spinner.visible = busy;
        spinner.spinning = busy;

        cancel_button.sensitive = !busy;
        local_button.sensitive = !busy;
        publish_button.sensitive = !busy;

        copy_button.sensitive = !busy && share_uri != null && share_uri != "";
        close_button.sensitive = !busy;
        retry_publish_button.sensitive = !busy;
    }

    private void show_done_state(string title, string body, bool show_copy) {
        title_label.label = title;
        summary_label.label = body;

        actions_box.visible = false;
        result_box.visible = true;

        copy_button.visible = show_copy;
        copy_button.sensitive = show_copy && share_uri != null && share_uri != "";
    }

    private void start_create(bool publish) {
        if (busy || dialog_closed) return;

        // Queue the import after updating busy controls. File preparation runs
        // in the service's existing background worker.
        set_busy(true);
        title_label.label = created_pack_id == null ? _("Importing…") : _("Sharing…");
        summary_label.label = created_pack_id == null
            ? _("Importing images from the selected folder…")
            : _("Sharing the imported sticker pack…");
        feedback_label.label = "";
        share_uri = null;
        copy_button.sensitive = false;
        actions_box.visible = true;
        result_box.visible = false;
        retry_publish_button.visible = false;

        create_source_id = Idle.add(() => {
            create_source_id = 0;
            if (!dialog_closed && get_realized()) start_create_async(publish);
            return Source.REMOVE;
        });
    }

    private void start_create_async(bool publish) {
        create.begin(publish, (obj, res) => {
            create.end(res);
        });
    }

    private async void create(bool publish) {
        try {
            var stickers = stream_interactor.get_module<Dino.Stickers>(Dino.Stickers.IDENTITY);
            if (stickers == null) throw new Dino.StickerError.NOT_CONNECTED("Stickers module unavailable");

            if (created_pack_id == null) {
                created_pack_id = yield stickers.create_local_pack_from_folder_with_progress(account, folder_path, (completed, total) => {
                    if (!dialog_closed) title_label.label = _("Importing… %d stickers").printf(completed);
                });
                pack_created(Path.get_basename(folder_path));
            }
            if (dialog_closed) return;
            if (publish) {
                title_label.label = _("Sharing…");
                summary_label.label = _("Uploading stickers and publishing the pack…");
            }
            string uri = publish ? yield stickers.publish_pack(account, (!) created_pack_id) : "";
            if (dialog_closed) return;
            share_uri = (uri != null && uri != "") ? uri : null;

            if (publish && share_uri != null) {
                var clipboard = this.get_display().get_clipboard();
                clipboard.set_text(share_uri);
                show_done_state(_("Sticker pack published"), _("Share link (copied to clipboard):\n%s").printf(share_uri), true);
            } else {
                show_done_state(_("Sticker pack imported"), _("The sticker pack is now available locally."), false);
            }
        } catch (Error e) {
            if (dialog_closed) return;
            if (created_pack_id != null) {
                show_done_state(_("Sticker pack imported"), _("The pack is available locally, but sharing failed:\n%s").printf(e.message), false);
                retry_publish_button.visible = true;
            } else {
                show_done_state(_("Failed to import sticker pack"), e.message, false);
            }
        } finally {
            if (!dialog_closed) set_busy(false);
        }
    }
}

}
