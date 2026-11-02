using Gee;
using Gdk;
using Gtk;
using Graphene;
using Xmpp;

using Dino.Entities;
using Dino.Security;

namespace Dino.Ui {

namespace StickerAnimationCompat {
    [CCode (cheader_filename = "sticker_animation_compat.h", cname = "dinox_pixbuf_animation_new_from_stream")]
    public static extern Gdk.PixbufAnimation new_from_stream(InputStream stream, int max_width, int max_height,
        out int source_width, out int source_height, Cancellable? cancellable = null) throws Error;
    [CCode (cheader_filename = "sticker_animation_compat.h", cname = "dinox_pixbuf_from_texture")]
    public static extern Gdk.Pixbuf? pixbuf_from_texture(Gdk.Texture texture);
    [CCode (cheader_filename = "sticker_animation_compat.h", cname = "dinox_pixbuf_animation_is_static_image")]
    public static extern bool is_static_image(Gdk.PixbufAnimation animation);
    [CCode (cheader_filename = "sticker_animation_compat.h", cname = "dinox_pixbuf_animation_get_static_image")]
    public static extern unowned Gdk.Pixbuf get_static_image(Gdk.PixbufAnimation animation);
    [CCode (cheader_filename = "sticker_animation_compat.h", cname = "dinox_pixbuf_animation_get_iter")]
    public static extern Gdk.PixbufAnimationIter get_iter(Gdk.PixbufAnimation animation);
    [CCode (cheader_filename = "sticker_animation_compat.h", cname = "dinox_pixbuf_animation_iter_get_delay_time")]
    public static extern int get_delay_time(Gdk.PixbufAnimationIter iter);
    [CCode (cheader_filename = "sticker_animation_compat.h", cname = "dinox_pixbuf_animation_iter_advance")]
    public static extern bool advance(Gdk.PixbufAnimationIter iter);
    [CCode (cheader_filename = "sticker_animation_compat.h", cname = "dinox_pixbuf_animation_iter_get_pixbuf")]
    public static extern unowned Gdk.Pixbuf get_pixbuf(Gdk.PixbufAnimationIter iter);
}

public class FileImageWidget : Widget {
    enum State {
        EMPTY,
        PREVIEW,
        IMAGE
    }
    private State state = State.EMPTY;

    private Stack stack = new Stack() { transition_duration=0, transition_type=StackTransitionType.NONE, hhomogeneous = false, vhomogeneous = false, interpolate_size = true };
    private Overlay overlay = new Overlay();

    private bool show_image_overlay_toolbar = false;
    private Gtk.Box image_overlay_toolbar = new Gtk.Box(Orientation.VERTICAL, 0) { halign=Align.END, valign=Align.START, margin_top=10, margin_start=10, margin_end=10, margin_bottom=10, vexpand=false, visible=false };
    private Label file_size_label = new Label(null) { halign=Align.START, valign=Align.END, margin_bottom=4, margin_start=4, visible=false };
    private Gtk.Box transfer_status_box = new Gtk.Box(Orientation.VERTICAL, 6) { halign=Align.CENTER, valign=Align.CENTER, visible=false };
    private Label transfer_status_label = new Label(null) { halign=Align.CENTER, justify=Justification.CENTER, visible=false, wrap=true, max_width_chars=34 };
    private Button transfer_action_button = new Button() { halign=Align.CENTER, valign=Align.CENTER, visible=false };

    private FileTransfer? file_transfer;
    private Gdk.Pixbuf? thumbnail_preview;
    private Binding? ft_size_binding1 = null;
    private Binding? ft_phase_total_binding = null;
    private Binding? ft_bytes_binding = null;
    private ulong ft_state_handler_id = 0;
    private ulong ft_phase_handler_id = 0;
    private ulong ft_phase_error_handler_id = 0;
    private ulong ft_bytes_handler_id = 0;
    private ulong ft_phase_total_handler_id = 0;
    private ulong ft_sources_handler_id = 0;
    private ulong map_handler_id = 0;
    private ulong unmap_handler_id = 0;
    private ulong settings_anim_handler_id = 0;
    private Dino.Entities.Settings animation_settings;

    private uint animation_timeout_id = 0;
    private uint animation_retry_id = 0;
    private uint cleanup_timeout_id = 0;
    private Gdk.PixbufAnimation? sticker_animation = null;
    private Gdk.PixbufAnimationIter? sticker_anim_iter = null;
    private FixedRatioPicture? sticker_anim_picture = null;
    private Gdk.Texture? sticker_static_frame = null;
    private bool animation_is_sticker = false;

    private File? temp_video_file = null;
    private Dino.PlaintextFileLease? temp_video_lease = null;

    private Gtk.ScrolledWindow? watched_scrolled = null;
    private Gtk.Adjustment? watched_vadjustment = null;
    private ulong watched_vadjustment_handler_id = 0;
    private ulong watched_vadjustment_page_size_handler_id = 0;

    private const int FIRST_FRAME_CACHE_MAX_ENTRIES = 32;
    private static Gee.HashMap<string, Gdk.Texture> first_frame_cache = new Gee.HashMap<string, Gdk.Texture>();
    private static Gee.LinkedList<string> first_frame_lru = new Gee.LinkedList<string>();
    private const int IMAGE_PREVIEW_CACHE_MAX_ENTRIES = 48;
    private const int IMAGE_PREVIEW_MAX_WIDTH = 600;
    private const int IMAGE_PREVIEW_MAX_HEIGHT = 300;
    private const int64 IMAGE_INLINE_PREVIEW_MAX_BYTES = 25 * 1024 * 1024;
    private const int64 VIDEO_INLINE_PREVIEW_MAX_BYTES = 50 * 1024 * 1024;
    private const int UNKNOWN_IMAGE_FALLBACK_WIDTH = 360;
    private const int UNKNOWN_IMAGE_FALLBACK_HEIGHT = 240;
    private static Gee.HashMap<string, Gdk.Texture> image_preview_cache = new Gee.HashMap<string, Gdk.Texture>();
    private static Gee.LinkedList<string> image_preview_lru = new Gee.LinkedList<string>();
    private int max_display_width = IMAGE_PREVIEW_MAX_WIDTH;
    private int max_display_height = IMAGE_PREVIEW_MAX_HEIGHT;

    private uint load_generation = 0;
    private Cancellable? load_cancellable = null;

    private FileTransmissionProgress transmission_progress = new FileTransmissionProgress() { halign=Align.CENTER, valign=Align.CENTER, visible=false };

    private Widget? active_content_widget = null;

    construct {
        layout_manager = new BinLayout();
    }

    private static void cache_first_frame(string key, Gdk.Texture texture) {
        if (key == "") return;

        if (first_frame_cache.has_key(key)) {
            first_frame_lru.remove(key);
        }

        first_frame_cache[key] = texture;
        first_frame_lru.add(key);

        while (first_frame_lru.size > FIRST_FRAME_CACHE_MAX_ENTRIES) {
            string oldest = first_frame_lru.get(0);
            first_frame_lru.remove_at(0);
            first_frame_cache.unset(oldest);
        }
    }

    private static Gdk.Texture? get_cached_first_frame(string key) {
        if (key == "") return null;
        if (!first_frame_cache.has_key(key)) return null;

        // Touch LRU
        first_frame_lru.remove(key);
        first_frame_lru.add(key);

        return first_frame_cache[key];
    }

    private static void cache_image_preview(string key, Gdk.Texture texture) {
        if (key == "") return;

        if (image_preview_cache.has_key(key)) {
            image_preview_lru.remove(key);
        }

        image_preview_cache[key] = texture;
        image_preview_lru.add(key);

        while (image_preview_lru.size > IMAGE_PREVIEW_CACHE_MAX_ENTRIES) {
            string oldest = image_preview_lru.get(0);
            image_preview_lru.remove_at(0);
            image_preview_cache.unset(oldest);
        }
    }

    private static Gdk.Texture? get_cached_image_preview(string key) {
        if (key == "") return null;
        if (!image_preview_cache.has_key(key)) return null;

        image_preview_lru.remove(key);
        image_preview_lru.add(key);

        return image_preview_cache[key];
    }

    private static Pixbuf scale_preview_pixbuf(Pixbuf pixbuf) {
        int width = pixbuf.width;
        int height = pixbuf.height;
        if (width <= 0 || height <= 0) return pixbuf;
        if (width <= IMAGE_PREVIEW_MAX_WIDTH && height <= IMAGE_PREVIEW_MAX_HEIGHT) return pixbuf;

        double scale = double.min((double) IMAGE_PREVIEW_MAX_WIDTH / width, (double) IMAGE_PREVIEW_MAX_HEIGHT / height);
        int target_width = int.max(1, (int) Math.round(width * scale));
        int target_height = int.max(1, (int) Math.round(height * scale));
        Pixbuf? scaled = pixbuf.scale_simple(target_width, target_height, InterpType.BILINEAR);
        return scaled ?? pixbuf;
    }

    private static void scale_display_size(int source_width, int source_height, int fallback_width, int fallback_height, int max_width, int max_height, out int target_width, out int target_height) {
        if (source_width <= 0 || source_height <= 0) {
            target_width = fallback_width;
            target_height = fallback_height;
            return;
        }

        double scale = double.min((double) max_width / source_width, (double) max_height / source_height);
        scale = double.min(scale, 1.0);
        target_width = int.max(1, (int) Math.round(source_width * scale));
        target_height = int.max(1, (int) Math.round(source_height * scale));
    }

    private FixedRatioPicture create_image_picture(FileTransfer? file_transfer, int fallback_width = UNKNOWN_IMAGE_FALLBACK_WIDTH, int fallback_height = UNKNOWN_IMAGE_FALLBACK_HEIGHT) {
        int source_width = file_transfer != null ? file_transfer.width : -1;
        int source_height = file_transfer != null ? file_transfer.height : -1;

        if ((source_width <= 0 || source_height <= 0) && file_transfer != null) {
            foreach (Xep.JingleContentThumbnails.Thumbnail thumbnail in file_transfer.thumbnails) {
                if (thumbnail.width > 0 && thumbnail.height > 0) {
                    source_width = thumbnail.width;
                    source_height = thumbnail.height;
                    break;
                }
            }
        }

        int target_width;
        int target_height;
        scale_display_size(source_width, source_height, fallback_width, fallback_height, max_display_width, max_display_height, out target_width, out target_height);

        return new FixedRatioPicture() {
            min_width = int.min(64, target_width),
            min_height = 1,
            max_width = max_display_width,
            max_height = max_display_height,
            target_width = target_width,
            target_height = target_height
        };
    }

    private void update_image_picture_size(FixedRatioPicture image, int source_width, int source_height) {
        int target_width;
        int target_height;
        scale_display_size(source_width, source_height, image.target_width, image.target_height, max_display_width, max_display_height, out target_width, out target_height);

        image.min_width = int.min(64, target_width);
        image.min_height = 1;
        image.max_width = max_display_width;
        image.max_height = max_display_height;
        image.target_width = target_width;
        image.target_height = target_height;
        image.queue_resize();
    }

    public static void clear_frame_cache() {
        if (first_frame_cache != null) first_frame_cache.clear();
        if (first_frame_lru != null) first_frame_lru.clear();
        if (image_preview_cache != null) image_preview_cache.clear();
        if (image_preview_lru != null) image_preview_lru.clear();
    }

    private void disconnect_scroll_watch() {
        if (watched_vadjustment != null && watched_vadjustment_handler_id != 0) {
            watched_vadjustment.disconnect(watched_vadjustment_handler_id);
            watched_vadjustment_handler_id = 0;
        }
        if (watched_vadjustment != null && watched_vadjustment_page_size_handler_id != 0) {
            watched_vadjustment.disconnect(watched_vadjustment_page_size_handler_id);
            watched_vadjustment_page_size_handler_id = 0;
        }
        watched_vadjustment = null;
        watched_scrolled = null;
    }

    private void pause_animation() {
        if (animation_timeout_id != 0) {
            Source.remove(animation_timeout_id);
            animation_timeout_id = 0;
        }
        if (animation_retry_id != 0) {
            Source.remove(animation_retry_id);
            animation_retry_id = 0;
        }
    }

    private void reset_loading_and_animation() {
        load_generation++;
        pause_animation();
        if (cleanup_timeout_id != 0) {
            Source.remove(cleanup_timeout_id);
            cleanup_timeout_id = 0;
        }
        sticker_animation = null;
        sticker_anim_iter = null;
        sticker_anim_picture = null;
        sticker_static_frame = null;
        animation_is_sticker = false;

        if (load_cancellable != null) {
            load_cancellable.cancel();
            load_cancellable = null;
        }
    }

    private void clear_loaded_plaintext_content() {
        reset_loading_and_animation();
        if (temp_video_lease != null) {
            ((!) temp_video_lease).release();
            temp_video_lease = null;
            temp_video_file = null;
        }
        active_content_widget = null;
        Widget? child = stack.get_first_child();
        while (child != null) {
            Widget next = child.get_next_sibling();
            stack.remove(child);
            child.dispose();
            child = next;
        }
        this.set_cursor_from_name("default");
        state = EMPTY;
    }

    private Gtk.ScrolledWindow? find_scrolled_window() {
        Widget? w = this;
        while (w != null) {
            if (w is Gtk.ScrolledWindow) {
                return (Gtk.ScrolledWindow) w;
            }
            w = w.get_parent();
        }
        return null;
    }

    private void ensure_scroll_watch() {
        if (watched_scrolled != null) return;

        watched_scrolled = find_scrolled_window();
        if (watched_scrolled == null) return;

        watched_vadjustment = watched_scrolled.vadjustment;
        if (watched_vadjustment == null) return;

        watched_vadjustment_handler_id = watched_vadjustment.value_changed.connect(() => {
            update_animation_state();
            // GtkViewport can apply its new scroll allocation after adjustment
            // notifications. Recheck once after layout so returning a paused
            // sticker to the viewport can restart its frame timer.
            schedule_animation_state_retry();
        });
        watched_vadjustment_page_size_handler_id = watched_vadjustment.notify["page-size"].connect(() => {
            update_animation_state();
            schedule_animation_state_retry();
        });
    }

    private bool is_in_viewport() {
        if (watched_scrolled == null || watched_vadjustment == null) return true;

        Graphene.Rect bounds;
        // ScrolledWindow coordinates already include the scroll offset. Its
        // GtkViewport child does too; adding adjustment.value again would mark
        // visible stickers further down a conversation as offscreen.
        if (!this.compute_bounds(watched_scrolled, out bounds)) return true;

        double y1 = bounds.origin.y;
        double y2 = y1 + bounds.size.height;

        // Small margin to avoid rapid toggling near edges.
        const double margin = 64.0;
        return (y2 >= -margin) && (y1 <= (watched_vadjustment.page_size + margin));
    }

    private void update_animation_state() {
        if (sticker_animation == null || sticker_anim_picture == null) return;

        ensure_scroll_watch();

        // This preference belongs to stickers; ordinary animated images retain
        // their existing playback regardless of the sticker setting.
        bool animations_enabled = !animation_is_sticker || animation_settings.sticker_animations_enabled;
        if (!animations_enabled) {
            pause_animation();
            sticker_anim_iter = null;
            // Return to the first frame, rather than freezing whichever frame
            // happened to be displayed when the preference changed.
            sticker_anim_picture.paintable = sticker_static_frame;
            return;
        }
        bool should_animate = animations_enabled && this.visible && this.get_mapped() && is_in_viewport();
        if (should_animate) {
            if (sticker_anim_iter == null) {
                sticker_anim_iter = StickerAnimationCompat.get_iter(sticker_animation);
            }
            if (animation_timeout_id == 0) {
                schedule_next_sticker_frame();
            }
        } else {
            pause_animation();
        }
    }

    private void schedule_animation_state_retry() {
        if (animation_retry_id != 0) return;
        if (sticker_animation == null || sticker_anim_picture == null) return;
        if (animation_is_sticker && !animation_settings.sticker_animations_enabled) return;
        if (!this.visible || !this.get_mapped()) return;

        animation_retry_id = Timeout.add(100, () => {
            animation_retry_id = 0;
            update_animation_state();
            return Source.REMOVE;
        });
    }

    private class LoadResult : Object {
        public Gdk.Pixbuf? pixbuf;
        public Gdk.PixbufAnimation? animation;
        public int source_width = -1;
        public int source_height = -1;
    }

    private class ImagePreviewLeaseOwner : Object {
        private Dino.PlaintextFileLease? lease;

        public ImagePreviewLeaseOwner(Dino.PlaintextFileLease lease) {
            this.lease = lease;
        }

        public void release() {
            if (lease == null) return;
            Dino.PlaintextFileLease owned_lease = (!) lease;
            lease = null;
            owned_lease.release();
        }
    }

    private static void release_image_preview_lease_owner(ImagePreviewLeaseOwner? owner) {
        if (owner != null) ((!) owner).release();
    }

    private void schedule_next_sticker_frame() {
        if (sticker_anim_iter == null || sticker_anim_picture == null) return;
        if (animation_timeout_id != 0) return;

        int delay_ms = StickerAnimationCompat.get_delay_time(sticker_anim_iter);
        // A negative delay means the animation has no next frame. Do not keep
        // waking the main loop for a completed/non-looping animation.
        if (delay_ms < 0) return;
        delay_ms = int.max(delay_ms, 20);

        animation_timeout_id = Timeout.add((uint) delay_ms, () => {
            animation_timeout_id = 0;
            if (sticker_anim_iter == null || sticker_anim_picture == null) return false;

            // Only animate while visible, in viewport, and animations enabled.
            if (!this.visible || !this.get_mapped() || !is_in_viewport() ||
                    (animation_is_sticker && !animation_settings.sticker_animations_enabled)) {
                return false;
            }

            bool changed = StickerAnimationCompat.advance(sticker_anim_iter);
            var frame_pb = StickerAnimationCompat.get_pixbuf(sticker_anim_iter);
            if (changed && frame_pb != null && frame_pb.get_pixels() != null) {
                sticker_anim_picture.paintable = Dino.Ui.Util.texture_from_pixbuf(frame_pb);
            }

            schedule_next_sticker_frame();
            return false;
        });
    }

    public FileImageWidget(int MAX_WIDTH=600, int MAX_HEIGHT=300) {
        animation_settings = Dino.Application.get_default().settings;
        max_display_width = MAX_WIDTH;
        max_display_height = MAX_HEIGHT;
        this.halign = Align.START;

        this.add_css_class("file-image-widget");

        // Setup menu button overlay
        MenuButton button = new MenuButton();
        button.icon_name = "view-more-symbolic";
        Menu menu_model = new Menu();
        menu_model.append(_("Open"), "file.open");
        menu_model.append(_("Save as…"), "file.save_as");
        Gtk.PopoverMenu popover_menu = new Gtk.PopoverMenu.from_model(menu_model);
        Util.set_menu_button_popover(button, popover_menu);
        image_overlay_toolbar.append(button);
        image_overlay_toolbar.add_css_class("card");
        image_overlay_toolbar.add_css_class("toolbar");
        image_overlay_toolbar.add_css_class("compact-card-toolbar");
        image_overlay_toolbar.set_cursor_from_name("default");

        file_size_label.add_css_class("file-details");
        transfer_status_label.add_css_class("file-transfer-status");
        transfer_action_button.add_css_class("small-button");
        transfer_action_button.clicked.connect(on_transfer_action_clicked);
        transfer_status_box.append(transmission_progress);
        transfer_status_box.append(transfer_status_label);
        transfer_status_box.append(transfer_action_button);

        overlay.set_child(stack);
        overlay.set_measure_overlay(stack, true);
        overlay.add_overlay(file_size_label);
        overlay.add_overlay(transfer_status_box);
        overlay.add_overlay(image_overlay_toolbar);
        overlay.set_clip_overlay(image_overlay_toolbar, true);

        overlay.insert_after(this, null);

        GestureClick gesture_click_controller = new GestureClick();
        gesture_click_controller.button = 1; // listen for left clicks
        gesture_click_controller.released.connect(on_image_clicked);
        stack.add_controller(gesture_click_controller);

        EventControllerMotion this_motion_events = new EventControllerMotion();
        this.add_controller(this_motion_events);
        this_motion_events.enter.connect((controller, x, y) => {
            var widget = controller.widget as FileImageWidget;
            if (widget != null) {
                widget.on_motion_event_enter();
            }
        });
        attach_on_motion_event_leave(this_motion_events, button);

        // Gtk.Widget exposes map/unmap signals, not a mapped GObject property.
        // Run after its default map handler so get_mapped() is already true.
        map_handler_id = this.map.connect_after(() => {
            update_animation_state();
            schedule_animation_state_retry();
        });
        unmap_handler_id = this.unmap.connect(() => {
            pause_animation();
            disconnect_scroll_watch();
        });

        // React to sticker animation setting changes
        settings_anim_handler_id = animation_settings.notify["sticker-animations-enabled"].connect(() => {
            update_animation_state();
        });
    }

    private static void attach_on_motion_event_leave(EventControllerMotion this_motion_events, MenuButton button) {
        this_motion_events.leave.connect((controller) => {
            if (!controller.widget.get_realized()) return;
            if (button.popover != null && button.popover.visible) return;

            var widget = controller.widget as FileImageWidget;
            if (widget != null) {
                widget.image_overlay_toolbar.visible = false;
                widget.file_size_label.visible = false;
            }
        });
    }

    private void on_motion_event_enter() {
        image_overlay_toolbar.visible = show_image_overlay_toolbar;
        file_size_label.visible = file_transfer != null && file_transfer.direction == FileTransfer.DIRECTION_RECEIVED && file_transfer.state == FileTransfer.State.NOT_STARTED && has_download_source();
        if (file_transfer == null) return;
    }

    private bool has_download_source() {
        if (file_transfer == null) return false;
        FileManager? file_manager = get_file_manager();
        if (file_manager != null) return ((!) file_manager).has_usable_download_source(file_transfer);
        if (file_transfer.provider == FileManager.JINGLE_PROVIDER_ID) return false;
        return file_transfer.has_usable_download_source(FileManager.SFS_PROVIDER_ID);
    }

    private bool is_direct_transfer_unavailable(bool has_download_source) {
        return file_transfer != null &&
            file_transfer.direction == FileTransfer.DIRECTION_RECEIVED &&
            file_transfer.provider == FileManager.JINGLE_PROVIDER_ID &&
            !has_download_source;
    }

    public async void set_file_transfer(FileTransfer file_transfer, Gdk.Pixbuf? thumbnail_preview = null) {
        this.file_transfer = file_transfer;
        this.thumbnail_preview = thumbnail_preview;

        ft_size_binding1 = this.file_transfer.bind_property("size", file_size_label, "label", BindingFlags.SYNC_CREATE, file_size_label_transform);
        ft_phase_total_binding = this.file_transfer.bind_property("phase-total-bytes", transmission_progress, "file-size", BindingFlags.SYNC_CREATE);
        ft_bytes_binding = this.file_transfer.bind_property("transferred-bytes", transmission_progress, "transferred-size", BindingFlags.SYNC_CREATE);

        ft_state_handler_id = file_transfer.notify["state"].connect(refresh_state);
        ft_phase_handler_id = file_transfer.notify["phase"].connect(refresh_state);
        ft_phase_error_handler_id = file_transfer.notify["phase-error"].connect(update_transfer_status);
        ft_bytes_handler_id = file_transfer.notify["transferred-bytes"].connect(refresh_state);
        ft_phase_total_handler_id = file_transfer.notify["phase-total-bytes"].connect(refresh_state);
        ft_sources_handler_id = file_transfer.sources_changed.connect(refresh_state);
        refresh_state();
    }

    private static bool file_size_label_transform(Binding binding, Value from_value, ref Value to_value) {
        to_value = FileDefaultWidget.get_size_string((int64) from_value);
        return true;
    }

    private void refresh_state() {
        if (file_transfer == null) return;
        FileTransfer current_transfer = (!)file_transfer;
        bool release_allowed = current_transfer.is_plaintext_release_allowed();
        if (!release_allowed && state == IMAGE) {
            clear_loaded_plaintext_content();
        }

        File? verified_file = release_allowed ? current_transfer.get_file() : null;
        if ((state == EMPTY || state == PREVIEW) && verified_file != null) {
            load_from_file.begin((!) verified_file, current_transfer.file_name, (_, res) => {
                try {
                    load_from_file.end(res);
                } catch (Error e) {
                    warning("FileImageWidget: Failed to load image file %s: %s", current_transfer.file_name, e.message);
                }
            });
            show_image_overlay_toolbar = true;
            this.set_cursor_from_name("zoom-in");

            state = IMAGE;
        } else if (state == EMPTY && current_transfer.thumbnails.size > 0) {
            load_from_thumbnail.begin(current_transfer, (_, res) => {
                load_from_thumbnail.end(res);
            });

            transmission_progress.visible = true;
            show_image_overlay_toolbar = false;
        }

        if (file_transfer.state == IN_PROGRESS || file_transfer.state == NOT_STARTED || file_transfer.state == FAILED) {
            transmission_progress.visible = true;
            show_image_overlay_toolbar = false;
            image_overlay_toolbar.visible = false;
        } else if (transmission_progress.visible) {
            Timeout.add(250, () => {
                transmission_progress.transferred_size = transmission_progress.file_size;
                transmission_progress.visible = false;
                show_image_overlay_toolbar = true;
                update_transfer_status();
                return false;
            });
        }

        if (file_transfer.direction == FileTransfer.DIRECTION_RECEIVED) {
            if (file_transfer.state == IN_PROGRESS) {
                transmission_progress.state = get_in_progress_transmission_state(file_transfer.phase);
            } else if (!has_download_source()) {
                transmission_progress.state = UNKNOWN_SOURCE;
            } else if (file_transfer.state == NOT_STARTED) {
                transmission_progress.state = DOWNLOAD_NOT_STARTED;
            } else if (file_transfer.state == FAILED) {
                transmission_progress.state = DOWNLOAD_NOT_STARTED_FAILED_BEFORE;
            }
        } else if (file_transfer.direction == FileTransfer.DIRECTION_SENT) {
            if (file_transfer.state == IN_PROGRESS) {
                transmission_progress.state = get_in_progress_transmission_state(file_transfer.phase);
            } else if (file_transfer.state == FAILED) {
                transmission_progress.state = UPLOAD_FAILED;
            }
        }
        update_transfer_status();
    }

    private void update_transfer_status() {
        string? status_text = null;
        string? action_label = null;
        bool action_destructive = false;
        bool error_status = false;
        bool source_available = has_download_source();
        if (file_transfer != null && file_transfer.state == IN_PROGRESS) {
            status_text = FileDefaultWidget.get_transfer_phase_label(file_transfer.phase, file_transfer.direction, file_transfer.size, file_transfer.transferred_bytes, file_transfer.phase_total_bytes);
            action_label = _("Cancel");
            action_destructive = true;
        } else if (file_transfer != null && file_transfer.state == FAILED) {
            status_text = FileDefaultWidget.get_transfer_failure_text(file_transfer.phase_error);
            error_status = true;
            if (file_transfer.direction == FileTransfer.DIRECTION_RECEIVED && source_available) {
                action_label = _("Download");
            } else if (file_transfer.can_retry_send_attempt()) {
                action_label = _("Retry upload");
            }
        } else if (file_transfer != null && file_transfer.state == NOT_STARTED && file_transfer.direction == FileTransfer.DIRECTION_RECEIVED && !source_available) {
            status_text = FileDefaultWidget.get_missing_download_source_text(is_direct_transfer_unavailable(source_available));
            error_status = true;
        } else if (file_transfer != null && file_transfer.state == NOT_STARTED && file_transfer.direction == FileTransfer.DIRECTION_RECEIVED && source_available) {
            action_label = _("Download");
        }

        if (status_text != null && status_text != "") {
            transfer_status_label.label = (!) status_text;
            transfer_status_label.tooltip_text = (!) status_text;
            transfer_status_label.visible = true;
            transfer_status_box.tooltip_text = (!) status_text;
        } else {
            transfer_status_label.visible = false;
            transfer_status_box.tooltip_text = null;
        }
        if (error_status) {
            transfer_status_label.add_css_class("error");
        } else {
            transfer_status_label.remove_css_class("error");
        }
        set_transfer_action(action_label, action_destructive);
        transfer_status_box.visible = transmission_progress.visible || transfer_status_label.visible || transfer_action_button.visible;
    }

    private void set_transfer_action(string? label, bool destructive = false) {
        transfer_action_button.remove_css_class("destructive-action");
        if (label == null) {
            transfer_action_button.visible = false;
            transfer_action_button.label = "";
            transfer_action_button.tooltip_text = null;
            return;
        }

        transfer_action_button.label = (!) label;
        transfer_action_button.tooltip_text = (!) label;
        transfer_action_button.visible = true;
        if (destructive) transfer_action_button.add_css_class("destructive-action");
    }

    private void on_transfer_action_clicked() {
        if (file_transfer == null) return;
        FileTransfer transfer = (!) file_transfer;
        FileManager? file_manager = get_file_manager();

        if (transfer.state == FileTransfer.State.IN_PROGRESS) {
            if (file_manager != null) {
                ((!) file_manager).cancel_download(transfer);
            } else {
                transfer.cancellable.cancel();
            }
        } else if (transfer.direction == FileTransfer.DIRECTION_RECEIVED &&
                   (transfer.state == FileTransfer.State.NOT_STARTED || transfer.state == FileTransfer.State.FAILED) &&
                   has_download_source()) {
            if (file_manager != null) ((!) file_manager).download_file.begin(transfer);
        } else if (transfer.can_retry_send_attempt()) {
            if (file_manager != null) ((!) file_manager).retry_send_file.begin(transfer);
        }
    }

    private static FileTransmissionProgress.State get_in_progress_transmission_state(FileTransfer.Phase phase) {
        switch (phase) {
            case FileTransfer.Phase.DOWNLOADING:
                return FileTransmissionProgress.State.DOWNLOADING;
            case FileTransfer.Phase.UPLOADING:
                return FileTransmissionProgress.State.UPLOADING;
            default:
                return FileTransmissionProgress.State.PROCESSING;
        }
    }

    private bool can_create_inline_image_preview_lease(FileTransfer transfer, File source_file, Cancellable cancellable) {
        if (!transfer.is_plaintext_release_allowed()) return false;
        if (transfer.size > IMAGE_INLINE_PREVIEW_MAX_BYTES) return false;

        try {
            FileInfo info = source_file.query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE, cancellable);
            if (info.get_size() > IMAGE_INLINE_PREVIEW_MAX_BYTES + 4096) return false;
        } catch (IOError.CANCELLED e) {
            return false;
        } catch (IOError.NOT_FOUND e) {
            return false;
        } catch (Error e) {
            // Keep the size check best-effort if metadata is temporarily unavailable.
        }

        return !cancellable.is_cancelled();
    }

    public async void load_from_file(File file, string file_name) throws GLib.Error {
        reset_loading_and_animation();

        Widget? content_widget = null;
        if (this.file_transfer != null && this.file_transfer.mime_type != null && this.file_transfer.mime_type.ascii_down().has_prefix("video/")) {
            File video_file = file;
            try {
                Dino.PlaintextFileLease lease = yield create_plaintext_lease("video-preview");

                if (temp_video_lease != null) {
                    ((!) temp_video_lease).release();
                }
                temp_video_lease = lease;
                temp_video_file = lease.file;
                video_file = lease.file;
            } catch (Error e) {
                warning("Video decryption failed: %s", e.message);
                throw e;
            }

            var video = new Gtk.Video.for_file(video_file) {
                 autoplay = false,
                 loop = false,
                 vexpand = true,
                 hexpand = true
            };
            video.set_size_request(200, 200);
            content_widget = video;
        } else {
            content_widget = create_image_picture(this.file_transfer);
        }

        // Add new child and set visible
        active_content_widget = content_widget;
        stack.add_child(content_widget);
        stack.set_visible_child(content_widget);

        // Schedule removal of old children after transition
        if (cleanup_timeout_id != 0) Source.remove(cleanup_timeout_id);
        cleanup_timeout_id = Timeout.add(stack.transition_duration + 50, () => {
             cleanup_timeout_id = 0;
             Widget? child = stack.get_first_child();
             while (child != null) {
                 Widget next = child.get_next_sibling();
                 if (child != content_widget && child != active_content_widget) {
                     if (child.get_parent() == stack) {
                         stack.remove(child);
                         child.dispose();
                     }
                 }
                 child = next;
             }
             return false;
        });

        if (content_widget is Gtk.Video) return;

        FixedRatioPicture image = (FixedRatioPicture) content_widget;

        uint gen = ++load_generation;
        var cancellable = new Cancellable();
        load_cancellable = cancellable;

        bool is_sticker = this.file_transfer != null && this.file_transfer.is_sticker;
        bool is_transfer_preview = this.file_transfer != null;

        string? local_path = file.get_path();
        File decode_file = file;
        ImagePreviewLeaseOwner? image_preview_lease_owner = null;

        // Avoid SVG stickers: gdk-pixbuf SVG loader can crash in some Flatpak runtimes.
        if (is_sticker) {
            string? mt = this.file_transfer != null ? this.file_transfer.mime_type : null;
            if (mt != null && mt != "" && mt.ascii_down().has_prefix("image/svg")) {
                return;
            }
            if (local_path != null && local_path != "") {
                string lower_path = local_path.ascii_down();
                if (lower_path.has_suffix(".svg") || lower_path.has_suffix(".svgz")) {
                    return;
                }
            }
        }

        // If we have a cached first frame for an animated sticker, show it immediately.
        if (is_sticker && local_path != null && local_path != "") {
            var cached = get_cached_first_frame(local_path);
            if (cached != null) {
                image.paintable = cached;
            }
        }

        if (!is_sticker && local_path != null && local_path != "") {
            var cached = get_cached_image_preview(local_path);
            if (cached != null) {
                if (!is_transfer_preview) {
                    update_image_picture_size(image, cached.get_width(), cached.get_height());
                }
                image.paintable = cached;
                return;
            }
        }

        FileTransfer? decode_transfer = this.file_transfer;
        if (decode_transfer != null) {
            if (!can_create_inline_image_preview_lease((!) decode_transfer, decode_file, cancellable)) {
                return;
            }

            try {
                Dino.PlaintextFileLease lease = yield create_plaintext_lease("image-preview", decode_transfer);
                ImagePreviewLeaseOwner lease_owner = new ImagePreviewLeaseOwner(lease);
                if (this.load_generation != gen || cancellable.is_cancelled()) {
                    lease_owner.release();
                    return;
                }

                image_preview_lease_owner = lease_owner;
                decode_file = lease.file;
            } catch (Error e) {
                return;
            }
        }

        // Animation support depends on the installed GdkPixbuf loaders. A
        // texture-only decoder can still provide a static sticker preview.
        new Thread<void*>("dinox-image-decode", () => {
                var result = new LoadResult();
                if (cancellable.is_cancelled()) {
                    Idle.add(() => {
                        release_image_preview_lease_owner(image_preview_lease_owner);
                        return false;
                    });
                    return null;
                }

                try {
                    FileInfo info = decode_file.query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE, cancellable);
                    int64 preview_size = info.get_size();
                    if (preview_size <= IMAGE_INLINE_PREVIEW_MAX_BYTES && preview_size >= 100) {
                        FileInputStream stream = decode_file.read(cancellable);
                        try {
                            Gdk.PixbufAnimation anim = StickerAnimationCompat.new_from_stream(stream,
                                IMAGE_PREVIEW_MAX_WIDTH, IMAGE_PREVIEW_MAX_HEIGHT,
                                out result.source_width, out result.source_height, cancellable);
                            if (!StickerAnimationCompat.is_static_image(anim)) {
                                result.animation = anim;
                            } else {
                                var pb = StickerAnimationCompat.get_static_image(anim);
                                // Apply orientation in the thread to avoid UI blocking and ensure it's done before display
                                var oriented = pb.apply_embedded_orientation();
                                string? orientation = pb.get_option("orientation");
                                if (orientation in new string[] { "5", "6", "7", "8" }) {
                                    int original_width = result.source_width;
                                    result.source_width = result.source_height;
                                    result.source_height = original_width;
                                }
                                result.pixbuf = scale_preview_pixbuf(oriented);
                            }
                        } catch (Error e) {
                            // Some valid PNG/APNG files are rejected by GdkPixbuf but
                            // can still be decoded by GTK4's texture loader.
                            // Both decoding routes stay off the GTK thread. Do not
                            // bypass the pixel limit or a cancelled chat load.
                            if (!(e is IOError.NO_SPACE) && !cancellable.is_cancelled()) {
                                var texture = Texture.from_file(decode_file);
                                result.source_width = texture.get_width();
                                result.source_height = texture.get_height();
                                if ((int64) result.source_width * result.source_height <= 64000000) {
                                    var pixbuf = StickerAnimationCompat.pixbuf_from_texture(texture);
                                    if (pixbuf != null) result.pixbuf = scale_preview_pixbuf(pixbuf);
                                }
                            }
                        }
                        try {
                            stream.close(null);
                        } catch (Error close_error) {}
                    }
                } catch (Error e) {
                    // Keep result empty.
                }

                Idle.add(() => {
                    // Check if widget is still alive and generation matches
                    if (this.load_generation != gen || cancellable.is_cancelled()) {
                        release_image_preview_lease_owner(image_preview_lease_owner);
                        return false;
                    }

                    // Check if we got valid data
                    if (result.animation == null && result.pixbuf == null) {
                        warning("Image decoding failed to produce valid data");
                        release_image_preview_lease_owner(image_preview_lease_owner);
                        return false;
                    }

                    if (result.animation != null && !StickerAnimationCompat.is_static_image(result.animation)) {
                        var iter = StickerAnimationCompat.get_iter(result.animation);
                        var first_pb = StickerAnimationCompat.get_pixbuf(iter);
                        var first_tex = Dino.Ui.Util.texture_from_pixbuf(first_pb);
                        if (this.file_transfer != null && first_pb != null) {
                            if (this.file_transfer.width <= 0) this.file_transfer.width = result.source_width;
                            if (this.file_transfer.height <= 0) this.file_transfer.height = result.source_height;
                        }
                        image.paintable = first_tex;
                        if (is_sticker && local_path != null && local_path != "") {
                            cache_first_frame(local_path, first_tex);
                        }
                        sticker_animation = result.animation;
                        sticker_anim_iter = iter;
                        sticker_anim_picture = image;
                        sticker_static_frame = first_tex;
                        animation_is_sticker = is_sticker;
                        update_animation_state();
                        schedule_animation_state_retry();
                        release_image_preview_lease_owner(image_preview_lease_owner);
                        return false;
                    }

                    if (result.pixbuf != null && result.pixbuf.get_pixels() != null) {
                        var texture = Dino.Ui.Util.texture_from_pixbuf(result.pixbuf);
                        if (this.file_transfer != null && result.source_width > 0 && result.source_height > 0) {
                            if (this.file_transfer.width <= 0) this.file_transfer.width = result.source_width;
                            if (this.file_transfer.height <= 0) this.file_transfer.height = result.source_height;
                        }
                        if (!is_transfer_preview) {
                            update_image_picture_size(image, result.pixbuf.width, result.pixbuf.height);
                        }
                        image.paintable = texture;
                        if (!is_sticker && local_path != null && local_path != "") {
                            cache_image_preview(local_path, texture);
                        }
                    }
                    release_image_preview_lease_owner(image_preview_lease_owner);
                    return false;
                });

                return null;
            });
    }

    private async Dino.PlaintextFileLease create_plaintext_lease(string purpose, FileTransfer? transfer = null) throws Error {
        FileTransfer? target_transfer = transfer != null ? transfer : file_transfer;
        if (target_transfer == null) {
            throw new IOError.FAILED("No file transfer available");
        }
        if (!target_transfer.is_plaintext_release_allowed()) {
            throw new IOError.PERMISSION_DENIED("File transfer is not complete yet");
        }

        FileManager? file_manager = get_file_manager();
        if (file_manager == null) throw new IOError.FAILED("File manager is not available");
        Dino.PlaintextFileLease lease = yield file_manager.create_plaintext_file_lease((!) target_transfer, purpose);
        if (!target_transfer.is_plaintext_release_allowed()) {
            lease.release();
            throw new IOError.PERMISSION_DENIED("File transfer is not complete yet");
        }
        return lease;
    }

    private FileManager? get_file_manager() {
        Dino.Application? app = GLib.Application.get_default() as Dino.Application;
        if (app == null) return null;
        return app.stream_interactor.get_module<FileManager>(FileManager.IDENTITY);
    }

    public async void load_from_thumbnail(FileTransfer file_transfer) {
        this.file_transfer = file_transfer;

        Gdk.Pixbuf? pixbuf = thumbnail_preview;
        if (pixbuf == null) return;

        // XEP-0264/SFS thumbnails are intentionally tiny placeholders (often
        // only 1..8 pixels). file_transfer.width/height describe the original
        // image and are used by create_image_picture() only to reserve the
        // correct display aspect ratio. Expanding the placeholder to those
        // dimensions here allocated about 49 MiB for every 4032x3024 image.
        FixedRatioPicture image = create_image_picture(file_transfer, pixbuf.width, pixbuf.height);
        image.paintable = Dino.Ui.Util.texture_from_pixbuf(pixbuf);
        active_content_widget = image;
        stack.add_child(image);
        stack.set_visible_child(image);
        state = PREVIEW;
    }

    public void on_image_clicked(GestureClick gesture_click_controller, int n_press, double x, double y) {
        if (this.file_transfer == null) return;
        if (this.file_transfer.state != COMPLETE) return;

        bool is_video = (this.file_transfer.mime_type != null && this.file_transfer.mime_type.ascii_down().has_prefix("video/"));

        switch (gesture_click_controller.get_device().source) {
            case Gdk.InputSource.TOUCHSCREEN:
            case Gdk.InputSource.PEN:
                if (n_press == 1) {
                    image_overlay_toolbar.visible = !image_overlay_toolbar.visible;
                } else if (n_press == 2) {
                    this.activate_action("file.open", null);
                    image_overlay_toolbar.visible = false;
                }
                break;
            default:
                if (is_video) {
                    image_overlay_toolbar.visible = !image_overlay_toolbar.visible;
                } else {
                    this.activate_action("file.open", null);
                    image_overlay_toolbar.visible = false;
                }
                break;
        }
    }

    public static bool can_display(FileTransfer? file_transfer, Gdk.Pixbuf? thumbnail_preview = null) {
        if (file_transfer == null) return false;
        var app = Dino.Application.get_default();
        if (file_transfer.is_sticker && !app.settings.stickers_enabled) {
            return false;
        }

        string? mime_type = file_transfer.mime_type;
        if (mime_type == null) return false;
        
        if (file_transfer.is_sticker && mime_type != "" && mime_type.ascii_down().has_prefix("image/svg")) {
            return false;
        }

        if (mime_type.ascii_down().has_prefix("video/")) {
            // Don't display videos larger than 50 MB inline to avoid UI freeze
            if (file_transfer.size > VIDEO_INLINE_PREVIEW_MAX_BYTES) return false;
            return file_transfer.state == FileTransfer.State.COMPLETE;
        }

        if (file_transfer.size > IMAGE_INLINE_PREVIEW_MAX_BYTES) return false;

        // A thumbnail entry alone does not imply a renderable image (e.g.
        // ThumbHash). Keep FileWidget's ordinary download/file fallback until
        // a supported thumbnail or the completed image is available.
        return Dino.Util.can_preview_image(file_transfer.mime_type, file_transfer.file_name) &&
                (file_transfer.state == FileTransfer.State.COMPLETE ||
                 thumbnail_preview != null);
    }

    public override void dispose() {
        // Break reference cycles: disconnect widget lifecycle signals.
        if (map_handler_id != 0) { this.disconnect(map_handler_id); map_handler_id = 0; }
        if (unmap_handler_id != 0) { this.disconnect(unmap_handler_id); unmap_handler_id = 0; }
        if (settings_anim_handler_id != 0) {
            animation_settings.disconnect(settings_anim_handler_id);
            settings_anim_handler_id = 0;
        }
        // Unbind all file_transfer property bindings
        if (ft_size_binding1 != null) { ft_size_binding1.unbind(); ft_size_binding1 = null; }
        if (ft_phase_total_binding != null) { ft_phase_total_binding.unbind(); ft_phase_total_binding = null; }
        if (ft_bytes_binding != null) { ft_bytes_binding.unbind(); ft_bytes_binding = null; }
        // Disconnect signal handlers from file_transfer
        if (file_transfer != null && ft_state_handler_id != 0) {
            file_transfer.disconnect(ft_state_handler_id);
            ft_state_handler_id = 0;
        }
        if (file_transfer != null && ft_phase_handler_id != 0) {
            file_transfer.disconnect(ft_phase_handler_id);
            ft_phase_handler_id = 0;
        }
        if (file_transfer != null && ft_phase_error_handler_id != 0) {
            file_transfer.disconnect(ft_phase_error_handler_id);
            ft_phase_error_handler_id = 0;
        }
        if (file_transfer != null && ft_bytes_handler_id != 0) {
            file_transfer.disconnect(ft_bytes_handler_id);
            ft_bytes_handler_id = 0;
        }
        if (file_transfer != null && ft_phase_total_handler_id != 0) {
            file_transfer.disconnect(ft_phase_total_handler_id);
            ft_phase_total_handler_id = 0;
        }
        if (file_transfer != null && ft_sources_handler_id != 0) {
            file_transfer.disconnect(ft_sources_handler_id);
            ft_sources_handler_id = 0;
        }
        file_transfer = null;
        thumbnail_preview = null;

        clear_loaded_plaintext_content();
        disconnect_scroll_watch();

        // Dispose all stack children (FixedRatioPicture with textures)
        active_content_widget = null;
        Widget? child = stack.get_first_child();
        while (child != null) {
            Widget next = child.get_next_sibling();
            stack.remove(child);
            child.dispose();
            child = next;
        }

        if (overlay != null) {
            if (overlay.parent != null) overlay.unparent();
            overlay.dispose();
            overlay = null;
        }
        base.dispose();
    }
}

}
