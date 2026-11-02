/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gee;
using Gdk;
using Gtk;
using Adw;

using Dino.Entities;

namespace Dino.Ui.ChatInput {

public class StickerChooser : Popover {
    private StreamInteractor stream_interactor;
    private Conversation? conversation;

    private bool needs_reload = true;

    private Gtk.Box root_box = new Gtk.Box(Orientation.VERTICAL, 6);
    private Gtk.Box header_box = new Gtk.Box(Orientation.HORIZONTAL, 6);
    private Gtk.MenuButton pack_button;
    private Gtk.Label pack_label = new Gtk.Label("");
    private Gtk.Popover pack_popover = new Gtk.Popover();
    private Gtk.ListBox pack_list = new Gtk.ListBox();
    // 0 = selection prompt, 1..N map to packs[0..N-1]
    private uint selected_pack = 0;
    private Gtk.Button manage_button;
    private GLib.ListStore sticker_store = new GLib.ListStore(typeof(Dino.Stickers.StickerItem));
    private Gtk.GridView grid;
    private Gtk.ScrolledWindow scroller = new Gtk.ScrolledWindow();
    private Gtk.Stack content_stack = new Gtk.Stack();
    private Gtk.Label empty_label = new Gtk.Label("");

    private Gee.List<Dino.Stickers.StickerPack> packs = new ArrayList<Dino.Stickers.StickerPack>();

    private uint populate_generation = 0;
    private uint populate_source = 0;
    private bool disposed = false;

    private const int THUMB_SIZE = 48;
    private const int THUMB_CACHE_LIMIT = 256;
    private const int STORE_BATCH_SIZE = 48;

    internal static bool is_supported_raster_sticker_source(string source_path, string? media_type) {
        string lower_path = source_path.ascii_down();
        if (lower_path.has_suffix(".svg") || lower_path.has_suffix(".svgz")) {
            return false;
        }

        if (media_type != null && media_type != "") {
            string mt = media_type.ascii_down();
            // Be conservative: avoid SVG and only allow common raster formats.
            if (mt == "image/png" || mt == "image/apng" || mt == "image/jpeg" || mt == "image/jpg" || mt == "image/webp" || mt == "image/gif") {
                return true;
            }
            if (mt.has_prefix("image/svg")) {
                return false;
            }
        }

        // Best-effort fallback when mime-type is missing/incorrect.
        return lower_path.has_suffix(".png") || lower_path.has_suffix(".apng") || lower_path.has_suffix(".jpg") || lower_path.has_suffix(".jpeg") || lower_path.has_suffix(".webp") || lower_path.has_suffix(".gif");
    }

    private class ThumbJob {
        public Gee.List<ThumbTarget> targets = new ArrayList<ThumbTarget>();
        public Dino.Stickers.StickerItem? item;
        public string source_path;
        public uint generation;
        public bool should_stop;

        public ThumbJob(Dino.Stickers.StickerItem item, string source_path, uint generation) {
            this.item = item;
            this.source_path = source_path;
            this.generation = generation;
            this.should_stop = false;
        }

        public ThumbJob.stop_job() {
            this.item = null;
            this.source_path = "";
            this.generation = 0;
            this.should_stop = true;
        }
    }

    private class ThumbTarget {
        public WeakRef button_weak;

        public ThumbTarget(StickerButton button) {
            button_weak = WeakRef(button);
        }
    }

    private GLib.AsyncQueue<ThumbJob> thumb_queue = new GLib.AsyncQueue<ThumbJob>();
    private Gee.HashMap<string, Gdk.Texture> thumb_cache = new Gee.HashMap<string, Gdk.Texture>();
    // The map and target lists are accessed only on the main thread. The worker
    // reads the job's immutable source/item and hands its result back via Idle.
    private Gee.HashMap<string, ThumbJob> pending_thumb_jobs = new Gee.HashMap<string, ThumbJob>();
    private bool thumb_worker_started = false;

    private bool popover_open = false;
    private bool send_allowed = true;

    private string? current_pack_id;
    private Gee.HashMap<int, string> selected_pack_by_account = new Gee.HashMap<int, string>();

    public StickerChooser(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;

        this.has_arrow = true;
        // Chat input sits at the bottom; prefer opening upwards.
        this.position = Gtk.PositionType.TOP;

        // Allow dismissing by clicking outside of the popover.
        this.autohide = true;
        this.focusable = true;

        this.closed.connect(() => {
            popover_open = false;
            cancel_population();
        });

        // Track real visibility (MenuButton drives popup/popdown).
        this.notify["visible"].connect(() => {
            popover_open = this.visible;
            if (!popover_open) {
                cancel_population();
                return;
            }

            // If we became visible and are already rooted, ensure content is ready.
            if (this.get_root() != null) {
                if (needs_reload) {
                    reload();
                } else {
                    refresh_grid();
                }
            }
            
            // Ensure the popover has focus so it can capture outside clicks for autohide.
            Idle.add(() => {
                if (this.visible) this.child_focus(Gtk.DirectionType.TAB_FORWARD);
                return false;
            });
        });

        // `set_open(true)` can be triggered before the popover is actually attached to a root
        // (depending on MenuButton timing). Only start heavy work once we have a root.
        this.notify["root"].connect(() => {
            if (this.visible && this.get_root() != null) {
                if (needs_reload) {
                    reload();
                } else {
                    refresh_grid();
                }
            }
        });

        // Pack selector: use a MenuButton+Popover+ListBox instead of Gtk.DropDown.
        pack_label.xalign = 0.0f;
        pack_label.ellipsize = Pango.EllipsizeMode.END;

        pack_button = new Gtk.MenuButton();
        pack_button.add_css_class("flat");
        pack_button.hexpand = true;
        pack_button.set_child(pack_label);

        // Configure pack popover.
        pack_popover.has_arrow = true;
        pack_popover.autohide = true;

        pack_list.selection_mode = Gtk.SelectionMode.SINGLE;
        pack_list.activate_on_single_click = true;
        pack_list.row_activated.connect((row) => {
            on_pack_row_activated(row);
        });

        var pack_scroller = new Gtk.ScrolledWindow();
        pack_scroller.propagate_natural_width = true;
        pack_scroller.propagate_natural_height = false;
        pack_scroller.min_content_height = 220;
        pack_scroller.set_child(pack_list);
        pack_popover.set_child(pack_scroller);

        Util.set_menu_button_popover(pack_button, pack_popover);

        manage_button = new Gtk.Button.with_label(_("Manage Sticker Packs"));
        manage_button.add_css_class("flat");
        manage_button.tooltip_text = _("Manage Sticker Packs");
        manage_button.clicked.connect(open_manager);

        var close_button = new Gtk.Button.from_icon_name("window-close-symbolic");
        close_button.add_css_class("flat");
        close_button.tooltip_text = _("Close");
        close_button.clicked.connect(() => this.popdown());

        header_box.hexpand = true;
        header_box.append(pack_button);
        header_box.append(manage_button);
        header_box.append(close_button);

        var factory = new Gtk.SignalListItemFactory();
        factory.setup.connect((obj) => {
            var list_item = obj as Gtk.ListItem;
            if (list_item == null) return;
            var btn = new StickerButton(this);
            list_item.child = btn;
        });
        factory.bind.connect((obj) => {
            var list_item = obj as Gtk.ListItem;
            if (list_item == null) return;
            var btn = list_item.child as StickerButton;
            if (btn == null) return;
            var it = list_item.get_item() as Dino.Stickers.StickerItem;
            btn.bind_item(it, populate_generation);
        });
        factory.unbind.connect((obj) => {
            var list_item = obj as Gtk.ListItem;
            if (list_item == null) return;
            var btn = list_item.child as StickerButton;
            if (btn == null) return;
            btn.unbind_item();
        });

        var selection = new Gtk.NoSelection(sticker_store);
        grid = new Gtk.GridView(selection, factory);
        grid.max_columns = 8;
        grid.min_columns = 4;

        scroller.hexpand = true;
        scroller.vexpand = true;
        // Ensure the popover doesn't shrink to one-column layout.
        scroller.propagate_natural_width = false;
        scroller.propagate_natural_height = false;
        scroller.min_content_width = 420;
        scroller.min_content_height = 260;
        scroller.set_child(grid);

        empty_label.wrap = true;
        empty_label.justify = Gtk.Justification.CENTER;

        content_stack.hexpand = true;
        content_stack.vexpand = true;
        content_stack.hhomogeneous = false;
        content_stack.vhomogeneous = false;
        content_stack.add_named(scroller, "grid");
        content_stack.add_named(empty_label, "empty");

        root_box.margin_top = 8;
        root_box.margin_bottom = 8;
        root_box.margin_start = 8;
        root_box.margin_end = 8;

        root_box.append(header_box);
        root_box.append(content_stack);

        this.set_child(root_box);
    }

    public override void dispose() {
        if (disposed) {
            base.dispose();
            return;
        }
        disposed = true;
        cancel_population();
        thumb_cache.clear();
        pending_thumb_jobs.clear();
        if (thumb_worker_started) {
            thumb_queue.push(new ThumbJob.stop_job());
            thumb_worker_started = false;
        }
        base.dispose();
    }

    public void set_conversation(Conversation? conversation) {
        this.conversation = conversation;
        needs_reload = true;
        manage_button.sensitive = conversation != null;

        // Avoid doing heavy pack reload on every chat switch.
        // Only reload when the user actually opens the popover (or if it is already open).
        if (this.visible && this.get_root() != null) {
            reload();
        } else {
            cancel_population();
            clear_sticker_store();
            content_stack.visible_child_name = "empty";

            // Avoid showing a stale pack selection from a previous conversation.
            selected_pack = 0;
            update_pack_label();
            select_pack_row(selected_pack);
            current_pack_id = null;
        }
    }

    public void set_send_allowed(bool allowed) {
        send_allowed = allowed;
        if (!allowed && popover_open) this.popdown();
    }

    public void set_open(bool open) {
        if (popover_open == open) return;
        popover_open = open;
        if (!popover_open) {
            cancel_population();
            return;
        }
        if (this.get_root() != null) {
            if (needs_reload) {
                reload();
            } else {
                refresh_grid();
            }
        }
    }

    private void cancel_population() {
        populate_generation++;
        if (populate_source != 0) {
            Source.remove(populate_source);
            populate_source = 0;
        }
        // Drop queued thumbnail work; generation check also prevents stale UI updates.
        drain_thumb_queue();
        pending_thumb_jobs.clear();
    }

    private void clear_sticker_store() {
        sticker_store.remove_all();
    }

    private void ensure_thumb_worker() {
        if (thumb_worker_started) return;
        thumb_worker_started = true;
        var queue = thumb_queue;
        var stickers = stream_interactor.get_module<Dino.Stickers>(Dino.Stickers.IDENTITY);
        var chooser_weak = WeakRef(this);

        new Thread<void*>("sticker-thumb-worker", () => {
            while (true) {
                ThumbJob job = queue.pop();
                if (job.should_stop) break;
                if (job.item == null) continue;

                Dino.Stickers.StickerItem item = (!) job.item;

                // Decode/scaling can be expensive (especially animated WebP). Do it off the UI thread.
                Pixbuf? pixbuf = null;
                try {
                    Bytes? bytes = stickers.get_thumbnail_bytes_for_item(item);
                    if (bytes != null) {
                        var stream = new MemoryInputStream.from_data(bytes.get_data(), null);
                        pixbuf = new Pixbuf.from_stream(stream);
                    } else {
                        // Fallback to source if thumb not available (yet)
                        bytes = stickers.get_sticker_bytes(item);
                        if (bytes != null) {
                            var stream = new MemoryInputStream.from_data(bytes.get_data(), null);
                            pixbuf = new Pixbuf.from_stream_at_scale(stream, THUMB_SIZE, THUMB_SIZE, true);
                            pixbuf = pixbuf.apply_embedded_orientation();
                        }
                    }
                } catch (Error e) {
                    pixbuf = null;
                }

                Idle.add(() => {
                    StickerChooser? chooser = chooser_weak.get() as StickerChooser;
                    if (chooser != null) chooser.finish_thumbnail(job, pixbuf);
                    return false;
                });

                // Minimal yield to avoid starving the CPU on very large packs.
                Thread.usleep(2 * 1000);
            }
            return null;
        });
    }

    private void finish_thumbnail(ThumbJob job, Pixbuf? pixbuf) {
        if (disposed || job.generation != populate_generation) return;
        string path = job.source_path;
        // A previous generation may finish after a replacement job for the
        // same path was queued. It must not remove that job.
        if (!pending_thumb_jobs.has_key(path) || pending_thumb_jobs[path] != job) return;
        pending_thumb_jobs.unset(path);
        if (!popover_open || this.get_root() == null) return;

        Gdk.Texture? texture = null;
        if (thumb_cache.has_key(path)) {
            texture = thumb_cache[path];
        } else if (pixbuf != null) {
            texture = Dino.Ui.Util.texture_from_pixbuf(pixbuf);
            thumb_cache[path] = texture;
            if (thumb_cache.size > THUMB_CACHE_LIMIT) {
                // Evict ~half instead of clearing everything to avoid a visible
                // flash when all thumbnails need re-decode.
                var iter = thumb_cache.map_iterator();
                int removed = 0;
                int target = THUMB_CACHE_LIMIT / 2;
                while (iter.next() && removed < target) {
                    iter.unset();
                    removed++;
                }
            }
        }

        // Every visible cell waiting for this path receives the decoded
        // texture, including duplicate entries in a pack.
        foreach (var target in job.targets) {
            StickerButton? button = target.button_weak.get() as StickerButton;
            if (button != null) button.apply_thumbnail(texture, path, job.generation);
        }
    }

    private void drain_thumb_queue() {
        ThumbJob? job;
        while ((job = thumb_queue.try_pop()) != null) {
            // GTK disposal can emit visibility/closed notifications after the
            // stop job was queued. Cancelling population must preserve it.
            if (job.should_stop) {
                thumb_queue.push(job);
                break;
            }
        }
    }

    private void request_thumbnail(StickerButton button, Dino.Stickers.StickerItem item, string path, uint generation) {
        if (disposed || generation != populate_generation) return;

        ThumbJob? job = pending_thumb_jobs[path];
        if (job == null) {
            job = new ThumbJob(item, path, generation);
            pending_thumb_jobs[path] = job;
            job.targets.add(new ThumbTarget(button));
            ensure_thumb_worker();
            thumb_queue.push(job);
        } else {
            // Keep one decode per path, but register every waiting widget.
            job.targets.add(new ThumbTarget(button));
        }
    }

    private void reload() {
        needs_reload = false;

        cancel_population();
        clear_sticker_store();
        content_stack.visible_child_name = "empty";
        clear_pack_list();
        packs = new ArrayList<Dino.Stickers.StickerPack>();
        selected_pack = 0;
        current_pack_id = null;
        update_pack_label();
        manage_button.label = _("Add Sticker Pack");

        if (conversation == null) {
            empty_label.label = _("Stickers are unavailable");
            return;
        }

        var app = Dino.Application.get_default();
        if (!app.settings.stickers_enabled) {
            empty_label.label = _("Stickers are unavailable");
            return;
        }

        var stickers = stream_interactor.get_module<Dino.Stickers>(Dino.Stickers.IDENTITY);
        if (stickers == null) {
            empty_label.label = _("Stickers are unavailable");
            return;
        }

        packs = stickers.get_packs(conversation.account);
        manage_button.label = packs.size == 0 ? _("Add Sticker Pack") : _("Manage Sticker Packs");

        // Keep an explicit selection prompt, followed by installed packs.
        append_pack_row(_("Select Sticker Pack"), null);
        foreach (var p in packs) {
            string label = p.name != null && p.name != "" ? p.name : p.pack_id;
            append_pack_row(label, p.pack_id);
        }
        // Restore a pack only when it still belongs to the current account.
        string? remembered_pack = selected_pack_by_account[conversation.account.id];
        if (remembered_pack != null && remembered_pack != "") {
            for (int i = 0; i < packs.size; i++) {
                if (packs[i].pack_id == remembered_pack) {
                    selected_pack = (uint) i + 1;
                    break;
                }
            }
            if (selected_pack == 0) selected_pack_by_account.unset(conversation.account.id);
        }
        // First use (or a removed selection) opens an installed pack directly.
        // An explicitly chosen prompt is remembered as an empty ID.
        if (selected_pack == 0 && remembered_pack != "" && packs.size > 0) selected_pack = 1;
        if (selected_pack != 0) {
            selected_pack_by_account[conversation.account.id] = packs[(int) selected_pack - 1].pack_id;
        }
        update_pack_label();
        select_pack_row(selected_pack);

        if (packs.size == 0) {
            empty_label.label = _("No sticker packs yet.");
        } else {
            empty_label.label = _("No stickers selected");
        }

        // Ensure the visible content matches the selected pack.
        refresh_grid();
    }

    private void clear_pack_list() {
        Gtk.ListBoxRow? row;
        while ((row = pack_list.get_row_at_index(0)) != null) {
            pack_list.remove(row);
        }
    }

    private void append_pack_row(string label, string? pack_id) {
        var row = new Gtk.ListBoxRow();
        var lbl = new Gtk.Label(label);
        lbl.xalign = 0.0f;
        lbl.margin_top = 6;
        lbl.margin_bottom = 6;
        lbl.margin_start = 10;
        lbl.margin_end = 10;
        row.set_child(lbl);
        row.set_data<string>("pack_id", pack_id != null ? pack_id : "");
        pack_list.append(row);
    }

    private void select_pack_row(uint index) {
        // index maps to row position (0..N). Best-effort.
        int i = 0;
        for (Gtk.Widget? child = pack_list.get_first_child(); child != null; child = child.get_next_sibling()) {
            var row = child as Gtk.ListBoxRow;
            if (row == null) continue;
            if (i == (int) index) {
                pack_list.select_row(row);
                break;
            }
            i++;
        }
    }

    private void update_pack_label() {
        if (selected_pack == 0) {
            pack_label.label = _("Select Sticker Pack");
            return;
        }
        uint pack_index = selected_pack - 1;
        if (pack_index >= packs.size) {
            pack_label.label = _("Select Sticker Pack");
            return;
        }
        var p = packs[(int) pack_index];
        pack_label.label = (p.name != null && p.name != "") ? p.name : p.pack_id;
    }

    private void on_pack_row_activated(Gtk.ListBoxRow row) {
        // Determine row index.
        int idx = row.get_index();
        if (idx < 0) return;

        selected_pack = (uint) idx;
        update_pack_label();
        if (conversation != null) {
            if (selected_pack != 0 && selected_pack - 1 < packs.size) {
                selected_pack_by_account[conversation.account.id] = packs[(int) selected_pack - 1].pack_id;
            } else {
                selected_pack_by_account[conversation.account.id] = "";
            }
        }

        // Close pack chooser first.
        pack_popover.popdown();

        refresh_grid();

        // Restore focus to our popover so outside click can dismiss it.
        Idle.add(() => {
            if (this.visible) this.child_focus(Gtk.DirectionType.TAB_FORWARD);
            return false;
        });
    }

    private void open_manager() {
        if (conversation == null) return;

        Gtk.Window? parent = this.get_root() as Gtk.Window;
        var manager_conversation = (!) conversation;
        this.popdown();

        var dialog = new Dino.Ui.StickerManagerDialog(stream_interactor, manager_conversation);
        dialog.present(parent);

        // Reload when the manager is closed, in case packs were added/removed.
        var chooser_weak = WeakRef(this);
        dialog.closed.connect(() => {
            StickerChooser? chooser = chooser_weak.get() as StickerChooser;
            if (chooser == null || chooser.disposed) return;
            chooser.needs_reload = true;
            if (chooser.visible && chooser.get_root() != null) chooser.reload();
        });
    }

    private void refresh_grid() {
        // Avoid heavy sticker decoding/scaling work unless the user actually opened the popover.
        if (!popover_open || this.get_root() == null) {
            cancel_population();
            clear_sticker_store();
            content_stack.visible_child_name = "empty";
            return;
        }

        cancel_population();
        clear_sticker_store();
        content_stack.visible_child_name = "empty";
        if (conversation == null) return;

        if (pack_list.get_first_child() == null) return;

        if (packs.size == 0) {
            empty_label.label = _("No sticker packs yet.");
            current_pack_id = null;
            return;
        }

        if (selected_pack == 0) {
            empty_label.label = _("No stickers selected");
            current_pack_id = null;
            return;
        }

        uint pack_index = selected_pack - 1;
        if (pack_index >= packs.size) return;

        string pack_id = packs[(int) pack_index].pack_id;
        current_pack_id = pack_id;

        var stickers = stream_interactor.get_module<Dino.Stickers>(Dino.Stickers.IDENTITY);
        if (stickers == null) return;

        var items = stickers.get_items(conversation.account, pack_id);
        if (items.size == 0) {
            empty_label.label = _("No stickers in this pack");
            return;
        }

        content_stack.visible_child_name = "grid";

        append_items_batched(items, populate_generation);
    }

    private void append_items_batched(Gee.List<Dino.Stickers.StickerItem> items, uint generation) {
        int index = 0;
        populate_source = Timeout.add(1, () => {
            if (disposed || generation != populate_generation || !popover_open || this.get_root() == null) {
                populate_source = 0;
                return Source.REMOVE;
            }

            int end = int.min(index + STORE_BATCH_SIZE, items.size);
            for (int i = index; i < end; i++) {
                sticker_store.append(items[i]);
            }
            index = end;

            if (index >= items.size) {
                populate_source = 0;
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
    }



    private void on_sticker_clicked(Dino.Stickers.StickerItem? item) {
        if (!send_allowed) return;
        if (item == null) return;
        if (conversation == null) return;
        if (current_pack_id == null) return;

        // Capture the destination before closing; chat/account switches during
        // the async operation must not change where the sticker is sent.
        Conversation send_conversation = (!) conversation;
        string send_pack_id = (!) current_pack_id;
        Gtk.Window? parent = this.get_root() as Gtk.Window;
        if (item.pack_id != send_pack_id || item.local_path == null || item.local_path == "" ||
                !FileUtils.test(item.local_path, FileTest.IS_REGULAR)) {
            this.popdown();
            show_send_error(parent, send_conversation, _("Sticker unavailable"));
            return;
        }

        var stickers_click = stream_interactor.get_module<Dino.Stickers>(Dino.Stickers.IDENTITY);
        if (stickers_click == null) {
            this.popdown();
            show_send_error(parent, send_conversation, _("Stickers are unavailable"));
            return;
        }

        var parent_weak = WeakRef(parent);
        this.popdown();
        stickers_click.send_sticker.begin(send_conversation, send_pack_id, item, (obj, res) => {
            try {
                stickers_click.send_sticker.end(res);
            } catch (Error e) {
                Gtk.Window? send_parent = parent_weak.get() as Gtk.Window;
                if (send_parent == null || !send_parent.get_realized()) return;
                show_send_error(send_parent, send_conversation, e.message);
            }
        });
    }

    private static void show_send_error(Gtk.Window? parent, Conversation send_conversation, string detail) {
        if (parent == null) return;
        var dialog = new Adw.AlertDialog(_("Could not send sticker"),
            _("Account: %s\nChat: %s\n\n%s").printf(
                send_conversation.account.bare_jid.to_string(),
                send_conversation.counterpart.to_string(), detail));
        dialog.add_response("close", _("Close"));
        dialog.present(parent);
    }

    private class StickerButton : Gtk.Button {
        private weak StickerChooser? chooser;
        private Gtk.Picture picture = new Gtk.Picture();
        private Gtk.Stack thumbnail_stack = new Gtk.Stack();
        private Gtk.Image placeholder_image = new Gtk.Image();
        private Gtk.Label placeholder_label = new Gtk.Label("");
        private Dino.Stickers.StickerItem? item;
        private uint bound_generation = 0;
        private string? bound_source;
        private string description = "";

        public StickerButton(StickerChooser chooser) {
            this.chooser = chooser;
            this.add_css_class("flat");

            // Add spacing between grid cells (GridView spacing isn't available in our gtk4.vapi).
            this.margin_top = 3;
            this.margin_bottom = 3;
            this.margin_start = 3;
            this.margin_end = 3;

            picture.can_shrink = true;
            picture.content_fit = ContentFit.CONTAIN;
            picture.width_request = THUMB_SIZE;
            picture.height_request = THUMB_SIZE;

            var placeholder = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
            placeholder.valign = Gtk.Align.CENTER;
            placeholder_image.pixel_size = 24;
            placeholder_label.wrap = true;
            placeholder_label.max_width_chars = 10;
            placeholder_label.justify = Gtk.Justification.CENTER;
            placeholder_label.add_css_class("caption");
            placeholder.append(placeholder_image);
            placeholder.append(placeholder_label);

            thumbnail_stack.add_named(picture, "picture");
            thumbnail_stack.add_named(placeholder, "placeholder");
            thumbnail_stack.width_request = THUMB_SIZE;
            thumbnail_stack.height_request = THUMB_SIZE;
            this.child = thumbnail_stack;

            this.clicked.connect(() => {
                var c = this.chooser;
                if (c == null) return;
                if (!this.sensitive || bound_generation != c.populate_generation) return;
                c.on_sticker_clicked(item);
            });
        }

        public void bind_item(Dino.Stickers.StickerItem? it, uint generation) {
            item = it;
            bound_generation = generation;
            bound_source = it != null ? it.local_path : null;
            picture.paintable = null;
            picture.file = null;
            this.sensitive = false;
            description = it != null && it.desc != null && it.desc.strip() != ""
                ? Dino.Ui.Util.sanitize_utf8(it.desc.strip()) : _("Sticker %d").printf(it != null ? it.position + 1 : 1);
            this.tooltip_text = description;
            this.update_property(Gtk.AccessibleProperty.LABEL, description,
                Gtk.AccessibleProperty.DESCRIPTION, "", -1);

            if (chooser == null || it == null || it.local_path == null || it.local_path == "" ||
                    !FileUtils.test(it.local_path, FileTest.IS_REGULAR)) {
                show_placeholder("image-missing-symbolic", _("Sticker unavailable"));
                return;
            }
            this.sensitive = true;

            if (chooser.thumb_cache.has_key(it.local_path)) {
                picture.paintable = chooser.thumb_cache[it.local_path];
                thumbnail_stack.visible_child_name = "picture";
                return;
            }

            // Avoid decoding SVG/non-raster stickers (gdk-pixbuf SVG loader is unstable in some runtimes).
            if (!StickerChooser.is_supported_raster_sticker_source(it.local_path, it.media_type)) {
                show_placeholder("image-x-generic-symbolic", _("Preview unavailable"));
                return;
            }

            show_placeholder("image-loading-symbolic", _("Loading…"));
            chooser.request_thumbnail(this, it, it.local_path, generation);
        }

        private void show_placeholder(string icon_name, string label) {
            placeholder_image.icon_name = icon_name;
            placeholder_label.label = label;
            thumbnail_stack.visible_child_name = "placeholder";
            this.tooltip_text = "%s\n%s".printf(description, label);
            this.update_property(Gtk.AccessibleProperty.DESCRIPTION, label, -1);
        }

        public void apply_thumbnail(Gdk.Texture? texture, string source_path, uint generation) {
            // GTK recycles buttons: matching a path alone is not sufficient
            // when the same file appears again in a later grid generation.
            if (item == null || bound_generation != generation || bound_source != source_path ||
                    item.local_path != source_path) return;
            if (!FileUtils.test(source_path, FileTest.IS_REGULAR)) {
                this.sensitive = false;
                show_placeholder("image-missing-symbolic", _("Sticker unavailable"));
            } else if (texture != null) {
                picture.paintable = texture;
                thumbnail_stack.visible_child_name = "picture";
                this.tooltip_text = description;
                this.update_property(Gtk.AccessibleProperty.DESCRIPTION, "", -1);
            } else {
                show_placeholder("image-missing-symbolic", _("Preview unavailable"));
            }
        }

        public void unbind_item() {
            item = null;
            bound_generation = 0;
            bound_source = null;
            picture.paintable = null;
            picture.file = null;
            this.sensitive = false;
            this.tooltip_text = null;
            this.update_property(Gtk.AccessibleProperty.LABEL, "", Gtk.AccessibleProperty.DESCRIPTION, "", -1);
        }
    }
}

}
