/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gtk;
using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

public class StickerPackImportDialog : Adw.Window {
    private StreamInteractor stream_interactor;

    private bool preview_started = false;
    private bool accounts_initialized = false;
    private bool importing = false;
    private bool dialog_closed = false;
    private uint preview_generation = 0;
    private uint frame_callback_id = 0;
    private Account? preferred_account;
    private Account? preview_account;

    private void run_on_next_frame(owned GLib.SourceFunc fn) {
        if (frame_callback_id != 0) remove_tick_callback(frame_callback_id);
        frame_callback_id = this.add_tick_callback((widget, frame_clock) => {
            frame_callback_id = 0;
            if (!dialog_closed) fn();
            return Source.REMOVE;
        });
    }

    private AccountComboBox account_combo = new AccountComboBox();
    private Label title_label = new Label("") { xalign = 0.0f, wrap = true };
    private Label summary_label = new Label("") { xalign = 0.0f, wrap = true };
    private Gtk.Spinner spinner = new Gtk.Spinner() { spinning = false, visible = false, width_request = 24, height_request = 24 };
    private Button import_button = new Button.with_label(_("Import")) { sensitive = false };
    private Button copy_uri_button = new Button.with_label(_("Copy Link")) { sensitive = false };
    private Button retry_button = new Button.with_label(_("Try Again")) { visible = false };
    private Label feedback_label = new Label("") { xalign = 0.0f, wrap = true };

    private Jid source_jid;
    private string node;
    private string item;

    private Dino.Stickers.StickerPack? pack;

    public StickerPackImportDialog(StreamInteractor stream_interactor, Jid source_jid, string node, string item, Account? preferred_account = null) {
        this.stream_interactor = stream_interactor;
        this.source_jid = source_jid;
        this.node = node;
        this.item = item;
        this.preferred_account = preferred_account;

        this.title = _("Import Sticker Pack");
        this.default_width = 420;
        this.default_height = 200;

        var box = new Gtk.Box(Orientation.VERTICAL, 12);
        box.margin_top = 12;
        box.margin_bottom = 12;
        box.margin_start = 12;
        box.margin_end = 12;

        // Important for UX: do NOT initialize accounts here.
        // `stream_interactor.get_accounts()` can be slow and would delay showing
        // the window (including the spinner) by several seconds.
        box.append(new Label(_("Account")) { xalign = 0.0f });
        account_combo.sensitive = false;
        box.append(account_combo);

        var status_row = new Gtk.Box(Orientation.HORIZONTAL, 8);
        spinner.valign = Align.CENTER;
        title_label.hexpand = true;
        status_row.append(spinner);
        status_row.append(title_label);
        box.append(status_row);
        box.append(summary_label);
        var publication_label = new Label(_("Importing also makes this pack's information publicly available through the selected XMPP account.")) { xalign = 0.0f, wrap = true };
        publication_label.add_css_class("dim-label");
        box.append(publication_label);
        box.append(feedback_label);

        var buttons = new Gtk.Box(Orientation.HORIZONTAL, 6) { halign = Align.END };
        buttons.append(retry_button);
        buttons.append(copy_uri_button);
        buttons.append(import_button);
        box.append(buttons);

        this.content = box;

        import_button.clicked.connect(start_import);
        copy_uri_button.clicked.connect(copy_share_uri);
        retry_button.clicked.connect(start_preview);
        account_combo.notify["active-account"].connect(() => {
            if (!accounts_initialized || importing || dialog_closed) return;
            var selected = account_combo.active_account;
            if (same_account(selected, preview_account)) return;
            start_preview();
        });
        this.close_request.connect(() => {
            mark_closed();
            return false;
        });
        ((Gtk.Widget) this).destroy.connect(mark_closed);
        ((Gtk.Widget) this).unrealize.connect(mark_closed);

        // Start initialization on the frame clock after the window is mapped.
        // File preparation is kept off the UI thread by the sticker service.
        this.map.connect(() => {
            if (preview_started) return;
            preview_started = true;

            // Update the busy controls before scheduling initialization.
            set_working(true);
            title_label.label = _("Loading…");
            summary_label.label = "";

            run_on_next_frame(() => {
                initialize_accounts();
                return Source.REMOVE;
            });
        });
    }

    private void mark_closed() {
        if (dialog_closed) return;
        dialog_closed = true;
        spinner.spinning = false;
        preview_generation++;
        if (frame_callback_id != 0) {
            remove_tick_callback(frame_callback_id);
            frame_callback_id = 0;
        }
    }

    private void set_working(bool working) {
        spinner.visible = working;
        spinner.spinning = working;
    }

    public override void dispose() {
        mark_closed();
        base.dispose();
    }

    private void initialize_accounts() {
        if (!accounts_initialized) {
            account_combo.allow_fallback_selection = preferred_account == null;
            account_combo.initialize(stream_interactor);
            if (preferred_account != null) {
                // An unavailable context account must not silently select a different one.
                account_combo.select_account(preferred_account);
            }
            accounts_initialized = true;
            account_combo.sensitive = true;
        }

        // Defer the preview after initializing the account selector.
        run_on_next_frame(() => {
            start_preview();
            return Source.REMOVE;
        });
    }

    private void start_preview() {
        if (dialog_closed || importing) return;
        uint generation = ++preview_generation;
        preview_account = account_combo.active_account;
        Account? account = preview_account;
        pack = null;
        feedback_label.label = "";
        title_label.label = _("Loading…");
        summary_label.label = "";
        set_working(true);
        import_button.sensitive = false;
        copy_uri_button.sensitive = false;
        retry_button.visible = false;
        if (account == null) {
            title_label.label = _("No account available");
            set_working(false);
            return;
        }
        preview.begin(account, generation, (obj, res) => {
            preview.end(res);
        });
    }

    private async void yield_to_mainloop() {
        Idle.add(() => {
            yield_to_mainloop.callback();
            return Source.REMOVE;
        });
        yield;
    }

    private void start_import() {
        if (dialog_closed || importing || pack == null) return;
        Account? account = account_combo.active_account;
        if (account == null || !same_account(account, preview_account)) {
            start_preview();
            return;
        }
        importing = true;
        preview_generation++;
        // Update busy controls before scheduling the asynchronous import.
        set_working(true);
        import_button.sensitive = false;
        copy_uri_button.sensitive = false;
        account_combo.sensitive = false;
        retry_button.visible = false;
        feedback_label.label = "";
        title_label.label = _("Importing…");
        summary_label.label = "";

        run_on_next_frame(() => {
            start_do_import((!) account);
            return Source.REMOVE;
        });
    }

    private void start_do_import(Account account) {
        do_import.begin(account, (obj, res) => {
            do_import.end(res);
        });
    }

    private async void preview(Account account, uint generation) {
        // Yield before sending the preview request.
        yield yield_to_mainloop();

        if (!is_current_preview(account, generation)) return;

        try {
            var stickers = stream_interactor.get_module<Dino.Stickers>(Dino.Stickers.IDENTITY);
            if (stickers == null) throw new Dino.StickerError.NOT_CONNECTED("Stickers module unavailable");
            var loaded_pack = yield stickers.preview_pack(account, source_jid, node, item);
            if (!is_current_preview(account, generation)) return;
            pack = loaded_pack;
            title_label.label = loaded_pack.name ?? loaded_pack.pack_id;
            summary_label.label = loaded_pack.summary ?? "";
            import_button.sensitive = true;
            copy_uri_button.sensitive = true;
        } catch (Error e) {
            if (!is_current_preview(account, generation)) return;
            title_label.label = _("Could not load sticker pack");
            summary_label.label = e.message;
            retry_button.visible = true;
        } finally {
            if (is_current_preview(account, generation)) set_working(false);
        }
    }

    private async void do_import(Account account) {
        // Yield before starting the import request.
        yield yield_to_mainloop();
        if (dialog_closed) return;

        try {
            var stickers = stream_interactor.get_module<Dino.Stickers>(Dino.Stickers.IDENTITY);
            if (stickers == null) throw new Dino.StickerError.NOT_CONNECTED("Stickers module unavailable");
            var imported_pack = yield stickers.import_pack_with_progress(account, source_jid, node, item, (completed, total) => {
                if (!dialog_closed) title_label.label = _("Importing… %d/%d").printf(completed, total);
            });
            if (dialog_closed) return;
            pack = imported_pack;
            set_working(false);
            this.close();
        } catch (Error e) {
            if (dialog_closed) return;
            title_label.label = _("Failed to import sticker pack");
            summary_label.label = e.message;
            import_button.sensitive = same_account(account_combo.active_account, account) && pack != null;
            copy_uri_button.sensitive = pack != null;
            set_working(false);
        } finally {
            importing = false;
            if (!dialog_closed) {
                account_combo.sensitive = true;
                if (!same_account(account_combo.active_account, account)) start_preview();
            }
        }
    }

    private void copy_share_uri() {
        if (pack == null) return;

        string share_jid = source_jid.to_string();
        string node_enc = Uri.escape_string(node, null, false);
        string item_enc = Uri.escape_string(item, null, false);
        string uri = @"xmpp:$(share_jid)?pubsub;action=retrieve;node=$(node_enc);item=$(item_enc)";

        var clipboard = this.get_display().get_clipboard();
        clipboard.set_text(uri);
        feedback_label.label = _("Link copied to clipboard");
    }

    private static bool same_account(Account? left, Account? right) {
        return left == null ? right == null : right != null && left.id == right.id;
    }

    private bool is_current_preview(Account account, uint generation) {
        return !dialog_closed && !importing && preview_generation == generation
            && same_account(account_combo.active_account, account);
    }
}

}
