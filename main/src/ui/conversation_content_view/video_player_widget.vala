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
using Graphene;
using Gst;
using Xmpp;

using Dino.Entities;
using Dino.Security;

#if HAVE_MALLOC_TRIM
[CCode (cname = "malloc_trim", cheader_filename = "malloc.h")]
extern int malloc_trim (size_t pad);
#endif

namespace Dino.Ui.ConversationSummary {

public class VideoFileMetaItem : FileMetaItem {
    private const int64 AUTO_DOWNLOAD_VIDEO_MAX_BYTES = 5000000;
    private StreamInteractor stream_interactor_ref;
    
    public VideoFileMetaItem(ContentItem content_item, StreamInteractor stream_interactor) {
        base(content_item, stream_interactor);
        this.stream_interactor_ref = stream_interactor;
        
        // Auto-download small videos only from durable download providers.
        FileManager file_manager = stream_interactor.get_module<FileManager>(FileManager.IDENTITY);
        if (file_transfer.direction == FileTransfer.DIRECTION_RECEIVED &&
            file_transfer.state == FileTransfer.State.NOT_STARTED &&
            file_transfer.provider != FileManager.JINGLE_PROVIDER_ID &&
            file_transfer.size > 0 &&
            file_transfer.size < AUTO_DOWNLOAD_VIDEO_MAX_BYTES &&
            file_manager.has_usable_download_source(file_transfer)) {
            file_manager.auto_download_file.begin(file_transfer);
        }
    }

    public override GLib.Object? get_widget(Plugins.ConversationItemWidgetInterface outer, Plugins.WidgetType type) {
        return new VideoPlayerWidget(file_transfer, stream_interactor_ref);
    }

}

public class VideoPlayerWidget : Widget {
    enum State {
        EMPTY,
        PREVIEW,
        VIDEO
    }
    private State state = State.EMPTY;

    private Stack stack = new Stack() { transition_duration=0, transition_type=StackTransitionType.NONE, hhomogeneous=true, vhomogeneous=true, interpolate_size=false };
    private Overlay overlay = new Overlay();

    private bool show_overlay_toolbar = false;
    private Gtk.Box overlay_toolbar = new Gtk.Box(Orientation.VERTICAL, 0) { halign=Align.START, valign=Align.START, margin_top=10, margin_start=10, margin_end=10, margin_bottom=10, vexpand=false, visible=false };
    private Label file_size_label = new Label(null) { halign=Align.START, valign=Align.END, margin_bottom=4, margin_start=4, visible=false };
    private Gtk.Box transfer_status_box = new Gtk.Box(Orientation.VERTICAL, 6) { halign=Align.CENTER, valign=Align.CENTER, visible=false };
    private Label transfer_status_label = new Label(null) { halign=Align.CENTER, justify=Justification.CENTER, visible=false, wrap=true, max_width_chars=34 };
    private Button transfer_action_button = new Button() { halign=Align.CENTER, valign=Align.CENTER, visible=false };

    private FileTransfer? file_transfer;
    private FileContextMenu? context_menu;
    private StreamInteractor? stream_interactor;
    private Binding? ft_state_binding = null;
    private Binding? ft_phase_binding = null;
    private Binding? ft_size_binding1 = null;
    private Binding? ft_phase_total_binding = null;
    private Binding? ft_bytes_binding = null;
    private ulong notify_ft_bytes_handler_id = 0;
    private ulong notify_ft_phase_total_handler_id = 0;
    private Gtk.Picture? video_picture = null;
    private Gtk.Widget? video_container = null;
    private FixedRatioPicture? preview_image = null;

    // GStreamer playback with deterministic cleanup
    private Gst.Element? playback_pipeline = null;
    private Gst.Element? playback_vsink = null;
    private Dino.Ui.MediaAudioPlaybackBridge? playback_bridge = null;
    private ulong playback_error_handler_id = 0;
    private uint playback_bus_watch = 0;
    private uint playback_start_timeout_id = 0;
    private uint playback_finish_timeout_id = 0;
    private uint frame_update_timer = 0;
    private bool is_video_playing = false;
    private bool playback_starting = false;
    private VideoPlaybackLifecycle playback_lifecycle =
        new VideoPlaybackLifecycle();
    private int64 last_frame_pts = -1;

    // Video player controls
    private Gtk.Box? controls_bar = null;
    private Gtk.Scale? seek_scale = null;
    private Gtk.Label? time_label = null;
    private Gtk.Button? play_pause_btn = null;
    private Gtk.Button? stop_btn = null;
    private int64 playback_duration = -1;
    private bool seeking = false;
    private uint seek_timeout_id = 0;

    private Gtk.ScrolledWindow? watched_scrolled = null;
    private Gtk.Adjustment? watched_vadjustment = null;
    private ulong watched_vadjustment_handler_id = 0;
    private ulong watched_vadjustment_page_size_handler_id = 0;
    private bool preview_initialized = false;
    private VideoPlaybackLifecycle preview_lifecycle =
        new VideoPlaybackLifecycle();
    private bool preview_generating {
        get { return preview_lifecycle.has_active_setup; }
    }
    private uint preview_retry_source_id = 0;
    private uint preview_retry_attempts = 0;
    private uint temp_preview_generation = 0;
    private bool pipeline_active = false;
    private bool _disposed = false;
    private ulong map_handler_id = 0;
    private ulong unmap_handler_id = 0;
    private int preview_height = 180;
    private ulong notify_ft_state_handler_id = 0;
    private ulong notify_ft_phase_handler_id = 0;
    private ulong notify_ft_phase_error_handler_id = 0;
    private ulong ft_sources_handler_id = 0;

    private Button? start_play_button = null;

    private const int VIDEO_PREVIEW_CACHE_MAX_ENTRIES = 24;
    private const uint PLAYBACK_START_TIMEOUT_MS = 10000;
    private static HashMap<string, Gdk.Texture> video_preview_cache = new HashMap<string, Gdk.Texture>();
    private static Gee.LinkedList<string> video_preview_lru = new Gee.LinkedList<string>();

    private FileTransmissionProgress transmission_progress = new FileTransmissionProgress() { halign=Align.CENTER, valign=Align.CENTER, visible=false };

    construct {
        layout_manager = new BinLayout();
    }

    public VideoPlayerWidget(FileTransfer file_transfer, StreamInteractor? stream_interactor = null) {
        debug("VideoPlayerWidget: init");
        this.halign = Align.START;
        this.valign = Align.START;
        this.hexpand = false;
        this.vexpand = false;
        if (file_transfer.width > 0 && file_transfer.height > 0) {
            double scale = double.min(1.0, double.min(320.0 / file_transfer.width,
                240.0 / file_transfer.height));
            preview_height = int.max(180, (int) Math.round(file_transfer.height * scale));
        }
        this.set_size_request(320, preview_height);
        this.add_css_class("video-player-widget");

        this.file_transfer = file_transfer;
        this.stream_interactor = stream_interactor;
        context_menu = new FileContextMenu(this, file_transfer, stream_interactor);

        start_play_button = new Button.from_icon_name("media-playback-start-symbolic");
        start_play_button.add_css_class("osd");
        start_play_button.add_css_class("circular");
        start_play_button.valign = Align.CENTER;
        start_play_button.halign = Align.CENTER;
        start_play_button.width_request = 64;
        start_play_button.height_request = 64;
        start_play_button.visible = false;
        start_play_button.clicked.connect(() => {
            // Resume if paused
            if (playback_pipeline != null && !is_video_playing) {
                resume_playback();
                return;
            }
            if (pipeline_active) return; // guard against double-click
            if (!can_play_media_payload()) return;
            File? file = file_transfer.get_file();
            if (file != null) {
                start_play_button.visible = false;
                start_setup_pipeline(file);
            }
        });
        overlay.add_overlay(start_play_button);

        map_handler_id = this.map.connect(() => {
            if (_disposed) return;
            ensure_scroll_watch();
            schedule_preview_retry();
        });
        unmap_handler_id = this.unmap.connect(() => {
            if (_disposed) return;
            playback_lifecycle.invalidate_setup();
            cleanup_playback();
            disconnect_scroll_watch();
            if (preview_retry_source_id != 0) {
                Source.remove(preview_retry_source_id);
                preview_retry_source_id = 0;
            }
        });

        install_action("file.open", null, (widget, action_name) => { ((VideoPlayerWidget) widget).start_open_file(); });
        install_action("file.save_as", null, (widget, action_name) => { ((VideoPlayerWidget) widget).save_file(); });
        install_action("file.download", null, (widget, action_name) => { ((VideoPlayerWidget) widget).start_download(); });
        install_action("file.cancel", null, (widget, action_name) => { ((VideoPlayerWidget) widget).cancel_download(); });

        // Setup menu button overlay
        MenuButton button = new MenuButton();
        button.icon_name = "view-more-symbolic";
        Menu menu_model = new Menu();
        menu_model.append(_("Open"), "file.open");
        menu_model.append(_("Save as…"), "file.save_as");
        Gtk.PopoverMenu popover_menu = new Gtk.PopoverMenu.from_model(menu_model);
        Util.set_menu_button_popover(button, popover_menu);
        overlay_toolbar.append(button);
        overlay_toolbar.add_css_class("card");
        overlay_toolbar.add_css_class("toolbar");
        overlay_toolbar.add_css_class("compact-card-toolbar");
        overlay_toolbar.set_cursor_from_name("default");

        file_size_label.add_css_class("file-details");
        transfer_status_label.add_css_class("file-transfer-status");
        transfer_action_button.add_css_class("small-button");
        transfer_action_button.clicked.connect(on_transfer_action_clicked);
        transfer_status_box.append(transmission_progress);
        transfer_status_box.append(transfer_status_label);
        transfer_status_box.append(transfer_action_button);

        // Build video player controls bar (hidden until playback starts)
        controls_bar = new Gtk.Box(Orientation.HORIZONTAL, 4);
        controls_bar.halign = Align.FILL;
        controls_bar.valign = Align.END;
        controls_bar.margin_start = 4;
        controls_bar.margin_end = 4;
        controls_bar.margin_bottom = 4;
        controls_bar.add_css_class("osd");
        controls_bar.add_css_class("toolbar");
        controls_bar.visible = false;

        play_pause_btn = new Gtk.Button.from_icon_name("media-playback-pause-symbolic");
        play_pause_btn.add_css_class("flat");
        play_pause_btn.valign = Align.CENTER;
        play_pause_btn.clicked.connect(() => {
            if (playback_pipeline == null) return;
            if (is_video_playing) {
                pause_playback();
            } else {
                resume_playback();
            }
        });
        controls_bar.append(play_pause_btn);

        seek_scale = new Gtk.Scale.with_range(Orientation.HORIZONTAL, 0.0, 1.0, 0.01);
        seek_scale.hexpand = true;
        seek_scale.draw_value = false;
        seek_scale.valign = Align.CENTER;
        seek_scale.change_value.connect((scroll_type, new_value) => {
            if (playback_pipeline == null || playback_duration <= 0) return false;
            seeking = true;
            double val = new_value.clamp(0.0, 1.0);
            int64 target = (int64)(val * (double)playback_duration);
            if (playback_bridge != null) {
                try {
                    ((!) playback_bridge).flush();
                } catch (Error e) {
                    warning("VideoPlayerWidget: could not flush WebRTC playback: %s", e.message);
                    cleanup_playback();
                    return false;
                }
            }
            playback_pipeline.seek_simple(
                Gst.Format.TIME,
                Gst.SeekFlags.FLUSH | Gst.SeekFlags.KEY_UNIT,
                target
            );
            // Cancel previous seek timeout to prevent stacking
            if (seek_timeout_id != 0) Source.remove(seek_timeout_id);
            seek_timeout_id = Timeout.add(200, () => {
                seek_timeout_id = 0;
                if (_disposed) return false;
                seeking = false;
                return false;
            });
            return false;
        });
        controls_bar.append(seek_scale);

        time_label = new Gtk.Label("0:00 / 0:00");
        time_label.add_css_class("monospace");
        time_label.valign = Align.CENTER;
        time_label.width_chars = 13;
        time_label.xalign = 1.0f;
        controls_bar.append(time_label);

        stop_btn = new Gtk.Button.from_icon_name("media-playback-stop-symbolic");
        stop_btn.add_css_class("flat");
        stop_btn.valign = Align.CENTER;
        stop_btn.clicked.connect(() => {
            playback_lifecycle.invalidate_setup();
            cleanup_playback();
            if (controls_bar != null) controls_bar.visible = false;
            if (start_play_button != null) start_play_button.visible = true;
            if (preview_image != null) stack.set_visible_child(preview_image);
        });
        controls_bar.append(stop_btn);

        overlay.set_child(stack);
        overlay.set_measure_overlay(stack, true);
        overlay.add_overlay(file_size_label);
        overlay.add_overlay(transfer_status_box);
        overlay.add_overlay(controls_bar);
        overlay.add_overlay(overlay_toolbar);
        overlay.set_clip_overlay(overlay_toolbar, true);

        overlay.insert_after(this, null);

        EventControllerMotion this_motion_events = new EventControllerMotion();
        this.add_controller(this_motion_events);
        this_motion_events.enter.connect((controller, x, y) => {
            var widget = controller.widget as VideoPlayerWidget;
            if (widget != null) {
                widget.on_motion_event_enter();
            }
        });
        attach_on_motion_event_leave(this_motion_events, button);
        
        // Note: Click to play/pause is handled by Gtk.MediaControls
        // which is added when the video loads

        start_update_widget();

        ft_state_binding = file_transfer.bind_property("state", this, "file-transfer-state");
        ft_phase_binding = file_transfer.bind_property("phase", this, "file-transfer-phase");
        notify_ft_state_handler_id = this.notify["file-transfer-state"].connect(start_update_widget);
        notify_ft_phase_handler_id = this.notify["file-transfer-phase"].connect(start_update_widget);
        notify_ft_phase_error_handler_id = file_transfer.notify["phase-error"].connect(update_transfer_status);
        notify_ft_bytes_handler_id = file_transfer.notify["transferred-bytes"].connect(update_transfer_status);
        notify_ft_phase_total_handler_id = file_transfer.notify["phase-total-bytes"].connect(update_transfer_status);
        ft_sources_handler_id = file_transfer.sources_changed.connect(start_update_widget);
        
        ft_size_binding1 = this.file_transfer.bind_property("size", file_size_label, "label", BindingFlags.SYNC_CREATE, file_size_label_transform);
        ft_phase_total_binding = this.file_transfer.bind_property("phase-total-bytes", transmission_progress, "file-size", BindingFlags.SYNC_CREATE);
        ft_bytes_binding = this.file_transfer.bind_property("transferred-bytes", transmission_progress, "transferred-size", BindingFlags.SYNC_CREATE);
    }

    private void start_update_widget() {
        update_widget.begin((obj, res) => {
            update_widget.end(res);
        });
    }

    public FileTransfer.State file_transfer_state { get; set; }
    public FileTransfer.Phase file_transfer_phase { get; set; }

    ~VideoPlayerWidget() {
    }

    private static void cache_video_preview(string key, Gdk.Texture texture) {
        if (key == "") return;

        if (video_preview_cache.has_key(key)) {
            video_preview_lru.remove(key);
        }

        video_preview_cache[key] = texture;
        video_preview_lru.add(key);

        while (video_preview_lru.size > VIDEO_PREVIEW_CACHE_MAX_ENTRIES) {
            string oldest = video_preview_lru.get(0);
            video_preview_lru.remove_at(0);
            video_preview_cache.unset(oldest);
        }
    }

    private static Gdk.Texture? get_cached_video_preview(string key) {
        if (key == "") return null;
        if (!video_preview_cache.has_key(key)) return null;

        video_preview_lru.remove(key);
        video_preview_lru.add(key);

        return video_preview_cache[key];
    }

    private static Gdk.Texture? texture_from_sample(Gst.Sample? sample, out double average_luma) {
        average_luma = -1.0;
        if (sample == null) return null;

        var buf = sample.get_buffer();
        var caps = sample.get_caps();
        if (buf == null || caps == null || caps.get_size() == 0) return null;

        unowned Gst.Structure st = caps.get_structure(0);
        int width = 0, height = 0;
        st.get_int("width", out width);
        st.get_int("height", out height);
        if (width <= 0 || height <= 0) return null;

        Gst.MapInfo map;
        if (!buf.map(out map, Gst.MapFlags.READ)) return null;

        Gdk.Texture? texture = null;
        size_t min_size = (size_t)(width * height * 4);
        if (map.data != null && map.size >= min_size) {
            int step_x = int.max(1, width / 24);
            int step_y = int.max(1, height / 24);
            double luma_sum = 0.0;
            int samples = 0;

            for (int y = 0; y < height; y += step_y) {
                for (int x = 0; x < width; x += step_x) {
                    size_t offset = (size_t)((y * width + x) * 4);
                    double r = map.data[offset];
                    double g = map.data[offset + 1];
                    double b = map.data[offset + 2];
                    luma_sum += (0.2126 * r) + (0.7152 * g) + (0.0722 * b);
                    samples++;
                }
            }
            average_luma = samples > 0 ? luma_sum / samples : -1.0;

            var bytes = new GLib.Bytes(map.data);
            size_t row_stride = (size_t)(width * 4);
            texture = new Gdk.MemoryTexture(width, height,
                Gdk.MemoryFormat.R8G8B8A8, bytes, row_stride);
        }

        buf.unmap(map);
        return texture;
    }

    private static void attach_on_motion_event_leave(EventControllerMotion this_motion_events, MenuButton button) {
        this_motion_events.leave.connect((controller) => {
            if (!controller.widget.get_realized()) return;
            if (button.popover != null && button.popover.visible) return;

            var widget = controller.widget as VideoPlayerWidget;
            if (widget != null) {
                widget.overlay_toolbar.visible = false;
                widget.file_size_label.visible = false;
            }
        });
    }

    private void on_motion_event_enter() {
        if (file_transfer == null) return;
        overlay_toolbar.visible = show_overlay_toolbar && can_play_media_payload();
        file_size_label.visible = file_transfer.direction == FileTransfer.DIRECTION_RECEIVED && file_transfer.state == FileTransfer.State.NOT_STARTED && has_download_source();
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

    private bool has_empty_media_payload() {
        return file_transfer != null &&
            ((!) file_transfer).state == FileTransfer.State.COMPLETE &&
            ((!) file_transfer).size == 0;
    }

    private bool can_play_media_payload() {
        return file_transfer != null &&
            ((!) file_transfer).is_plaintext_release_allowed() &&
            !has_empty_media_payload();
    }

    private bool file_size_label_transform(Binding binding, GLib.Value source_value, ref GLib.Value target_value) {
        int64 size = (int64) source_value;
        target_value.set_string(GLib.format_size((uint64) size));
        return true;
    }

    private async void update_widget() {
        if (file_transfer == null) return;
        debug("VideoPlayerWidget: update_widget state=%s", file_transfer.state.to_string());
        bool release_allowed = can_play_media_payload();
        if (!release_allowed) {
            revoke_plaintext_access();
        }

        if (start_play_button != null) {
            start_play_button.visible = release_allowed && playback_pipeline == null;
        }

        if (release_allowed) {
            if (state != State.VIDEO) {
                state = State.VIDEO;
                show_overlay_toolbar = true;
                transmission_progress.visible = false;
                
                // Cached posters are installed before the first layout/paint.
                // Only a cache miss needs a decoder after mapping.
                restore_cached_preview();
                if (preview_image == null || preview_image.paintable == null) {
                    var placeholder = stack.get_child_by_name("placeholder");
                    if (placeholder == null) {
                        var box = new Gtk.Box(Orientation.VERTICAL, 0);
                        box.set_size_request(320, preview_height);
                        box.add_css_class("video-transfer-placeholder");
                        stack.add_named(box, "placeholder");
                        placeholder = box;
                    }
                    stack.set_visible_child(placeholder);
                }
                // Generate preview thumbnail (uses fakesink only, no PipeWire, destroyed immediately)
                schedule_preview_retry();
            }
        } else {
            // Not complete (Downloading, Not Started, etc.)
            if (state != State.PREVIEW) {
                state = State.PREVIEW;
                show_overlay_toolbar = false;
                overlay_toolbar.visible = false;

                var placeholder = stack.get_child_by_name("transfer-placeholder");
                if (placeholder == null) {
                    var box = new Gtk.Box(Orientation.VERTICAL, 0);
                    box.set_size_request(320, preview_height);
                    box.add_css_class("video-transfer-placeholder");
                    stack.add_named(box, "transfer-placeholder");
                    placeholder = box;
                }
                stack.set_visible_child(placeholder);
            }

            if (file_transfer.direction == FileTransfer.DIRECTION_RECEIVED && file_transfer.state == FileTransfer.State.IN_PROGRESS) {
                transmission_progress.visible = true;
                transmission_progress.state = get_in_progress_transmission_state(file_transfer.phase);
            } else if (file_transfer.direction == FileTransfer.DIRECTION_RECEIVED && file_transfer.state == FileTransfer.State.NOT_STARTED) {
                transmission_progress.visible = true;
                transmission_progress.state = !has_download_source() ?
                    FileTransmissionProgress.State.UNKNOWN_SOURCE :
                    FileTransmissionProgress.State.DOWNLOAD_NOT_STARTED;
            } else if (file_transfer.direction == FileTransfer.DIRECTION_RECEIVED && file_transfer.state == FileTransfer.State.FAILED) {
                transmission_progress.visible = true;
                transmission_progress.state = !has_download_source() ?
                    FileTransmissionProgress.State.UNKNOWN_SOURCE :
                    FileTransmissionProgress.State.DOWNLOAD_NOT_STARTED_FAILED_BEFORE;
            } else if (file_transfer.direction == FileTransfer.DIRECTION_SENT && file_transfer.state == FileTransfer.State.IN_PROGRESS) {
                transmission_progress.visible = true;
                transmission_progress.state = get_in_progress_transmission_state(file_transfer.phase);
            } else if (file_transfer.direction == FileTransfer.DIRECTION_SENT && file_transfer.state == FileTransfer.State.FAILED) {
                transmission_progress.visible = true;
                transmission_progress.state = FileTransmissionProgress.State.UPLOAD_FAILED;
            } else {
                transmission_progress.visible = false;
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
        if (file_transfer != null && file_transfer.state == FileTransfer.State.IN_PROGRESS) {
            status_text = FileDefaultWidget.get_transfer_phase_label(file_transfer.phase, file_transfer.direction, file_transfer.size, file_transfer.transferred_bytes, file_transfer.phase_total_bytes);
            action_label = _("Cancel");
            action_destructive = true;
        } else if (file_transfer != null && file_transfer.state == FileTransfer.State.FAILED) {
            status_text = FileDefaultWidget.get_transfer_failure_text(file_transfer.phase_error);
            error_status = true;
            if (file_transfer.direction == FileTransfer.DIRECTION_RECEIVED && source_available) {
                action_label = _("Download");
            } else if (file_transfer.can_retry_send_attempt()) {
                action_label = _("Retry upload");
            }
        } else if (file_transfer != null && has_empty_media_payload()) {
            status_text = FileDefaultWidget.get_transfer_failure_text("Received media file is empty");
            error_status = true;
        } else if (file_transfer != null && file_transfer.state == FileTransfer.State.NOT_STARTED && file_transfer.direction == FileTransfer.DIRECTION_RECEIVED && !source_available) {
            status_text = FileDefaultWidget.get_missing_download_source_text(is_direct_transfer_unavailable(source_available));
            error_status = true;
        } else if (file_transfer != null && file_transfer.state == FileTransfer.State.NOT_STARTED && file_transfer.direction == FileTransfer.DIRECTION_RECEIVED && source_available) {
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

    private File? temp_preview_file = null;
    private Dino.PlaintextFileLease? temp_preview_lease = null;

    private void schedule_preview_retry() {
        if (_disposed || preview_initialized || preview_generating) return;
        if (preview_retry_source_id != 0) return;

        preview_retry_attempts = 0;
        preview_retry_source_id = Timeout.add(50, () => {
            if (_disposed || preview_initialized || preview_generating) {
                preview_retry_source_id = 0;
                return false;
            }
            if (file_transfer == null || !can_play_media_payload() || !this.get_mapped()) {
                preview_retry_source_id = 0;
                return false;
            }

            try_lazy_preview_init();
            if (preview_initialized || preview_generating) {
                preview_retry_source_id = 0;
                return false;
            }

            preview_retry_attempts++;
            if (preview_retry_attempts >= 8) {
                preview_retry_source_id = 0;
                return false;
            }

            return true;
        });
    }

    private void try_lazy_preview_init() {
        if (preview_initialized || preview_generating) return;
        if (pipeline_active) return;
        if (file_transfer == null) return;
        if (!can_play_media_payload()) return;
        if (!this.get_mapped()) return;

        // Connect scroll watcher so we get called when scrolling
        ensure_scroll_watch();

        if (!is_in_viewport()) return;

        File? file = file_transfer.get_file();
        if (file == null) return;
        if (restore_cached_preview()) return;

        uint generation = preview_lifecycle.begin_setup();
        start_generate_preview(file, generation);
    }

    private FixedRatioPicture create_video_picture() {
        // The poster and playback share one reserved canvas. Decoder dimensions
        // must not change a row's height or the chat's scroll position.
        return new FixedRatioPicture() {
            min_width = 320, max_width = 320, target_width = 320,
            min_height = preview_height, max_height = preview_height,
            target_height = preview_height, content_fit = ContentFit.CONTAIN
        };
    }

    private bool restore_cached_preview() {
        if (!can_play_media_payload()) return false;
        File? file = file_transfer.get_file();
        string? key = file != null ? file.get_path() : null;
        if (key == null) return false;
        var cached = get_cached_video_preview(key);
        if (cached == null) return false;
        if (preview_image == null) {
            preview_image = create_video_picture();
            stack.add_child(preview_image);
        }
        preview_image.paintable = cached;
        stack.set_visible_child(preview_image);
        preview_initialized = true;
        return true;
    }

    private void restore_poster() {
        if (controls_bar != null) controls_bar.visible = false;
        if (start_play_button != null) start_play_button.visible = can_play_media_payload();
        if (preview_image != null && preview_image.paintable != null) {
            stack.set_visible_child(preview_image);
        } else {
            var placeholder = stack.get_child_by_name("fallback") ??
                stack.get_child_by_name("placeholder");
            if (placeholder != null) stack.set_visible_child(placeholder);
        }
    }

    private void start_generate_preview(File file, uint generation) {
        generate_preview.begin(file, generation, (obj, res) => {
            generate_preview.end(res);
        });
    }

    private bool is_preview_generation_current(uint generation) {
        return !_disposed &&
            preview_lifecycle.is_current(generation) &&
            file_transfer != null &&
            can_play_media_payload();
    }

    private async void generate_preview(File encrypted_file, uint generation) {
        if (!is_preview_generation_current(generation)) {
            preview_lifecycle.finish_setup(generation);
            return;
        }

        if (file_transfer.size > 104857600) { // > 100 MB
            debug("VideoPlayerWidget: File too large for preview generation (%lld bytes)", (int64)file_transfer.size);
            show_fallback_preview();
            preview_initialized = true;
            preview_lifecycle.finish_setup(generation);
            return;
        }

        debug("VideoPlayerWidget: generating preview thumbnail");
        File? preview_file = yield decrypt_to_temp(
            encrypted_file, file_transfer.file_name, "preview_", generation);
        if (!is_preview_generation_current(generation)) {
            release_preview_lease(generation);
            preview_lifecycle.finish_setup(generation);
            return;
        }
        if (preview_file == null) {
            show_fallback_preview();
            preview_initialized = true;
            preview_lifecycle.finish_setup(generation);
            return;
        }

        // Extract first frame using filesrc + decodebin — lighter than uridecodebin,
        // avoids URI resolution overhead since we already have a local file path.
        // NO playbin, NO autoaudiosink → ZERO PipeWire connections.
        var pipe = new Gst.Pipeline("thumb-pipe");
        var thumb_filesrc = ElementFactory.make("filesrc", "thumb-filesrc");
        var thumb_decode = ElementFactory.make("decodebin", "thumb-decode");
        var vconv = ElementFactory.make("videoconvert", "thumb-vc");
        var vscale = ElementFactory.make("videoscale", "thumb-vscale");
        var vcaps_elem = ElementFactory.make("capsfilter", "thumb-vcaps");
        var vsink = ElementFactory.make("fakesink", "thumb-vs");

        if (thumb_filesrc == null || thumb_decode == null || vconv == null ||
                vscale == null || vcaps_elem == null || vsink == null) {
            debug("VideoPlayerWidget: missing GStreamer elements for thumbnail");
            show_fallback_preview();
            release_preview_lease(generation);
            preview_lifecycle.finish_setup(generation);
            return;
        }

        // Keep cached thumbnails small. The previous pipeline cached the full
        // source frame, so 24 UHD previews alone could retain about 800 MiB.
        vcaps_elem.set("caps", Gst.Caps.from_string(
            "video/x-raw,format=RGBA,width=(int)[1,320],height=(int)[1,240]," +
            "pixel-aspect-ratio=(fraction)1/1"));
        vsink.set("enable-last-sample", true);

        thumb_filesrc.set("location", preview_file.get_path());

        pipe.add_many(thumb_filesrc, thumb_decode, vconv, vscale, vcaps_elem, vsink);
        thumb_filesrc.link(thumb_decode);
        vconv.link(vscale);
        vscale.link(vcaps_elem);
        vcaps_elem.link(vsink);

        // Dynamic pad linking from decodebin — only link video pads
        thumb_decode.pad_added.connect((pad) => {
            var pad_caps = pad.get_current_caps();
            if (pad_caps == null) pad_caps = pad.query_caps(null);
            if (pad_caps != null && pad_caps.get_size() > 0) {
                unowned Gst.Structure st = pad_caps.get_structure(0);
                if (!st.get_name().has_prefix("video/")) return;
            }
            var sink_pad = vconv.get_static_pad("sink");
            if (sink_pad != null && !sink_pad.is_linked()) {
                pad.link(sink_pad);
            }
        });

        // Use async state change + bus watch instead of blocking get_state()
        Gst.Bus thumb_bus = pipe.get_bus();
        bool preroll_done = false;
        SourceFunc callback = generate_preview.callback;

        uint thumb_bus_watch = thumb_bus.add_watch(0, (bus, msg) => {
            if (msg.type == Gst.MessageType.ASYNC_DONE || msg.type == Gst.MessageType.ERROR) {
                if (!preroll_done) {
                    preroll_done = true;
                    Idle.add((owned) callback);
                }
            }
            return true;
        });

        // Safety timeout 3s
        bool timeout_fired = false;
        uint timeout_id = Timeout.add(3000, () => {
            timeout_fired = true;
            if (!preroll_done) {
                preroll_done = true;
                callback();
            }
            return false;
        });

        pipe.set_state(Gst.State.PAUSED);
        yield;

        Source.remove(thumb_bus_watch);
        if (!timeout_fired) Source.remove(timeout_id);

        if (!is_preview_generation_current(generation)) {
            pipe.set_state(Gst.State.NULL);
            release_preview_lease(generation);
            preview_lifecycle.finish_setup(generation);
            return;
        }

        // Check if pipeline reached PAUSED (prerolled first frame)
        Gst.State cur_state, pend_state;
        pipe.get_state(out cur_state, out pend_state, 0); // non-blocking check

        if (cur_state == Gst.State.PAUSED) {
            // Get last-sample from the fakesink directly. Camera recordings often
            // start with a black exposure-settling frame, so retry around 800 ms
            // before accepting a very dark thumbnail.
            Gst.Sample? sample = null;
            vsink.get("last-sample", out sample);

            double average_luma;
            Gdk.Texture? texture = texture_from_sample(sample, out average_luma);

            if (texture != null && average_luma >= 0.0 && average_luma < 18.0) {
                debug("VideoPlayerWidget: first thumbnail frame is dark (luma %.1f), seeking later", average_luma);
                bool seek_started = pipe.seek_simple(
                    Gst.Format.TIME,
                    Gst.SeekFlags.FLUSH | Gst.SeekFlags.ACCURATE,
                    800 * Gst.MSECOND
                );

                if (seek_started) {
                    bool seek_done = false;
                    SourceFunc seek_callback = generate_preview.callback;
                    uint seek_watch = thumb_bus.add_watch(0, (bus, msg) => {
                        if (msg.type == Gst.MessageType.ASYNC_DONE || msg.type == Gst.MessageType.ERROR) {
                            if (!seek_done) {
                                seek_done = true;
                                Idle.add((owned) seek_callback);
                            }
                        }
                        return true;
                    });

                    bool seek_timeout_fired = false;
                    uint seek_timeout_id = Timeout.add(1500, () => {
                        seek_timeout_fired = true;
                        if (!seek_done) {
                            seek_done = true;
                            seek_callback();
                        }
                        return false;
                    });

                    yield;

                    Source.remove(seek_watch);
                    if (!seek_timeout_fired) Source.remove(seek_timeout_id);

                    if (!is_preview_generation_current(generation)) {
                        pipe.set_state(Gst.State.NULL);
                        release_preview_lease(generation);
                        preview_lifecycle.finish_setup(generation);
                        return;
                    }

                    Gst.Sample? later_sample = null;
                    vsink.get("last-sample", out later_sample);
                    double later_luma;
                    var later_texture = texture_from_sample(later_sample, out later_luma);
                    if (later_texture != null) {
                        texture = later_texture;
                        average_luma = later_luma;
                    }
                }
            }

            if (texture != null) {
                if (!is_preview_generation_current(generation)) {
                    pipe.set_state(Gst.State.NULL);
                    release_preview_lease(generation);
                    preview_lifecycle.finish_setup(generation);
                    return;
                }
                if (preview_image == null) {
                    preview_image = create_video_picture();
                    stack.add_child(preview_image);
                }
                preview_image.paintable = texture;
                string? cache_key = encrypted_file.get_path();
                if (cache_key != null && cache_key != "") {
                    cache_video_preview(cache_key, texture);
                }
                stack.set_visible_child(preview_image);
                debug("VideoPlayerWidget: preview thumbnail captured as static texture (luma %.1f)", average_luma);
            } else {
                debug("VideoPlayerWidget: no thumbnail sample captured");
                show_fallback_preview();
            }
        } else {
            debug("VideoPlayerWidget: pipeline did not reach PAUSED, no thumbnail");
            show_fallback_preview();
        }

        // Immediately destroy pipeline → zero PipeWire footprint
        pipe.set_state(Gst.State.NULL);

        preview_initialized = true;
        preview_lifecycle.finish_setup(generation);
        debug("VideoPlayerWidget: preview generation complete, pipeline destroyed");
    }

    private void show_fallback_preview() {
        if (preview_image == null) {
            var existing = stack.get_child_by_name("fallback");
            if (existing != null) {
                stack.set_visible_child(existing);
                return;
            }
            var icon = new Gtk.Image.from_icon_name("video-x-generic");
            icon.pixel_size = 96;
            stack.add_named(icon, "fallback");
            stack.set_visible_child(icon);
        }
    }

    private void pause_playback() {
        if (playback_pipeline == null) return;
        playback_pipeline.set_state(Gst.State.PAUSED);
        cancel_playback_start_timeout();
        playback_starting = false;
        if (playback_bridge != null) {
            try {
                ((!) playback_bridge).set_paused(true);
            } catch (Error e) {
                warning("VideoPlayerWidget: could not pause WebRTC playback: %s", e.message);
                cleanup_playback();
                return;
            }
        }
        is_video_playing = false;
        if (frame_update_timer != 0) {
            Source.remove(frame_update_timer);
            frame_update_timer = 0;
        }
        if (play_pause_btn != null) play_pause_btn.icon_name = "media-playback-start-symbolic";
        if (start_play_button != null) start_play_button.visible = true;
    }

    private void resume_playback() {
        if (playback_pipeline == null) return;
        if (!can_play_media_payload()) {
            revoke_plaintext_access();
            return;
        }
        if (playback_bridge != null) {
            try {
                ((!) playback_bridge).set_paused(false);
            } catch (Error e) {
                warning("VideoPlayerWidget: could not resume WebRTC playback: %s", e.message);
                cleanup_playback();
                return;
            }
        }
        request_playing_state();
    }

    private void cleanup_playback() {
        is_video_playing = false;
        playback_starting = false;
        cancel_playback_start_timeout();
        if (frame_update_timer != 0) {
            Source.remove(frame_update_timer);
            frame_update_timer = 0;
        }
        if (playback_bus_watch != 0) {
            Source.remove(playback_bus_watch);
            playback_bus_watch = 0;
        }
        if (playback_finish_timeout_id != 0) {
            Source.remove(playback_finish_timeout_id);
            playback_finish_timeout_id = 0;
        }
        if (playback_pipeline != null) {
            playback_pipeline.set_state(Gst.State.NULL);
            playback_pipeline = null;
        }
        if (playback_bridge != null) {
            if (playback_error_handler_id != 0 &&
                    SignalHandler.is_connected((!) playback_bridge, playback_error_handler_id)) {
                ((!) playback_bridge).disconnect(playback_error_handler_id);
            }
            playback_error_handler_id = 0;
            ((!) playback_bridge).stop();
            playback_bridge = null;
        }
        playback_vsink = null;
        last_frame_pts = -1;
        if (video_picture != null) {
            video_picture.paintable = null;
        }
        playback_duration = -1;
        if (seek_timeout_id != 0) {
            Source.remove(seek_timeout_id);
            seek_timeout_id = 0;
        }
        seeking = false;
        pipeline_active = false;
        restore_poster();
#if HAVE_MALLOC_TRIM
        // Force glibc to return freed memory to OS
        malloc_trim(0);
#endif
    }

    private void revoke_plaintext_access() {
        preview_lifecycle.invalidate_setup();
        playback_lifecycle.invalidate_setup();
        cleanup_playback();
        release_plaintext_leases();
        if (preview_retry_source_id != 0) {
            Source.remove(preview_retry_source_id);
            preview_retry_source_id = 0;
        }
        preview_initialized = false;
        if (video_picture != null) {
            video_picture.paintable = null;
        }
        if (preview_image != null) {
            preview_image.paintable = null;
        }
        if (controls_bar != null) {
            controls_bar.visible = false;
        }
    }

    private void release_preview_lease(uint generation = 0) {
        if (temp_preview_lease == null) return;
        if (generation != 0 && temp_preview_generation != generation) return;
        ((!) temp_preview_lease).release();
        temp_preview_lease = null;
        temp_preview_file = null;
        temp_preview_generation = 0;
    }

    private void release_playback_lease(uint generation = 0) {
        if (temp_play_lease == null) return;
        if (generation != 0 && temp_play_generation != generation) return;
        ((!) temp_play_lease).release();
        temp_play_lease = null;
        temp_play_file = null;
        temp_play_generation = 0;
    }

    private void release_plaintext_leases() {
        release_playback_lease();
        release_preview_lease();
        if (temp_open_lease != null) {
            ((!) temp_open_lease).release();
            temp_open_lease = null;
            temp_open_file = null;
        }
    }

    private File? temp_play_file = null;
    private File? temp_open_file = null;
    private Dino.PlaintextFileLease? temp_play_lease = null;
    private Dino.PlaintextFileLease? temp_open_lease = null;
    private uint temp_play_generation = 0;

    /**
     * Decrypt an encrypted file to a random temp file in the video cache dir.
     * Returns null on failure so playback never falls back to the encrypted
     * at-rest storage file.
     */
    private async File? decrypt_to_temp(File source_file, string filename,
            string prefix = "", uint generation = 0) {
        try {
            FileManager? file_manager = get_file_manager();
            if (file_manager == null || file_transfer == null) return null;
            if (!file_transfer.is_plaintext_release_allowed()) return null;

            bool preview = prefix.has_prefix("preview");
            Dino.PlaintextFileLease lease = yield ((!) file_manager).create_plaintext_file_lease((!) file_transfer, preview ? "video-preview" : "video-playback");
            if (file_transfer == null ||
                    !file_transfer.is_plaintext_release_allowed() ||
                    (preview && !preview_lifecycle.is_current(generation)) ||
                    (!preview && !is_playback_setup_current(generation))) {
                lease.release();
                return null;
            }
            if (preview) {
                if (temp_preview_lease != null) ((!) temp_preview_lease).release();
                temp_preview_lease = lease;
                temp_preview_file = lease.file;
                temp_preview_generation = generation;
            } else {
                release_playback_lease();
                temp_play_lease = lease;
                temp_play_file = lease.file;
                temp_play_generation = generation;
            }
            return lease.file;
        } catch (Error e) {
            warning("VideoPlayerWidget: decrypt failed: %s", e.message);
            return null;
        }
    }

    private FileManager? get_file_manager() {
        if (stream_interactor != null) {
            return ((!) stream_interactor).get_module<FileManager>(FileManager.IDENTITY);
        }

        Dino.Application? app = GLib.Application.get_default() as Dino.Application;
        if (app == null) return null;
        return app.stream_interactor.get_module<FileManager>(FileManager.IDENTITY);
    }

    private bool is_playback_setup_current(uint generation) {
        return playback_lifecycle.is_current(generation) && !_disposed &&
            this.get_mapped() && file_transfer != null &&
            can_play_media_payload();
    }

    private async void setup_pipeline(File file, uint generation) {
        if (!is_playback_setup_current(generation)) return;
        if (pipeline_active) return;
        pipeline_active = true;
        debug("VideoPlayerWidget: setup_pipeline");

        // A click can race the lazy thumbnail preroll. Invalidate that
        // generation and use a separate playback lease until its pipeline has
        // released the preview file; otherwise the late thumbnail completion
        // can replace the visible video child again.
        bool preview_was_generating = preview_generating;
        if (preview_was_generating) {
            preview_lifecycle.invalidate_setup();
        }
        
        // Reuse already-decrypted temp file from preview if available
        File file_to_play;
        if (!preview_was_generating && temp_preview_file != null) {
            file_to_play = temp_preview_file;
            debug("VideoPlayerWidget: reusing preview temp file");
        } else if (temp_play_file != null) {
            // A newer setup adopts the cached lease. A late completion from
            // the previous setup may then release only its own generation.
            temp_play_generation = generation;
            file_to_play = temp_play_file;
            debug("VideoPlayerWidget: reusing existing temp file");
        } else {
            // Decrypt file
            File? decrypted_file = yield decrypt_to_temp(file,
                file_transfer.file_name, "", generation);
            if (!is_playback_setup_current(generation)) {
                release_playback_lease(generation);
                return;
            }
            if (decrypted_file == null) {
                pipeline_active = false;
                if (start_play_button != null) start_play_button.visible = true;
                return;
            }
            temp_play_file = (!) decrypted_file;
            file_to_play = temp_play_file;
        }

        // Destroy any existing pipeline
        cleanup_playback();
        pipeline_active = true;

        if (video_picture == null) {
            video_picture = new Gtk.Picture();
            video_picture.content_fit = ContentFit.CONTAIN;
            video_picture.can_shrink = true;
            video_picture.halign = Align.FILL;
            video_picture.valign = Align.FILL;
            video_picture.hexpand = false;
            video_picture.vexpand = false;

            // Click on video to toggle pause/play
            var click = new GestureClick();
            click.pressed.connect((n, x, y) => {
                if (playback_pipeline != null && is_video_playing) {
                    pause_playback();
                } else if (playback_pipeline != null && !is_video_playing) {
                    resume_playback();
                }
            });
            video_picture.add_controller(click);
            
            // Bound the existing live picture without adding per-frame
            // property notifications to the poster's layout widget.
            var canvas = new SizingBin() {
                min_width = 320, target_width = 320, max_width = 320,
                min_height = preview_height, target_height = preview_height,
                max_height = preview_height
            };
            video_picture.set_parent(canvas);
            video_container = canvas;
            stack.add_child(video_container);
        }

        // GStreamer decodes video to a fakesink and audio to an appsink. The
        // external Google/libwebrtc worker owns the actual speaker output.
        var playbin = ElementFactory.make("playbin", "video-playback");
        var vconv = ElementFactory.make("videoconvert", "play-vc");
        var vcaps = ElementFactory.make("capsfilter", "play-vcaps");
        playback_vsink = ElementFactory.make("fakesink", "play-vs");

        if (playbin == null || vconv == null || vcaps == null || playback_vsink == null) {
            warning("VideoPlayerWidget: missing playback elements");
            pipeline_active = false;
            release_playback_lease(generation);
            if (start_play_button != null) start_play_button.visible = true;
            return;
        }

        vcaps.set("caps", Gst.Caps.from_string("video/x-raw,format=RGBA"));
        playback_vsink.set("enable-last-sample", true);
        playback_vsink.set("sync", true);
        playback_vsink.set("qos", false);

        var vbin = new Gst.Bin("video-sink-bin");
        vbin.add_many(vconv, vcaps, playback_vsink);
        vconv.link(vcaps);
        vcaps.link(playback_vsink);
        var ghost = new Gst.GhostPad("sink", vconv.get_static_pad("sink"));
        vbin.add_pad(ghost);

        playbin.set("uri", file_to_play.get_uri());
        playbin.set("video-sink", vbin);
        var app = (Dino.Ui.Application) GLib.Application.get_default();
        Dino.Plugins.MediaMessagePlaybackProvider? playback_provider =
            app.plugin_registry.media_message_playback_provider;
        if (playback_provider == null) {
            warning("VideoPlayerWidget: Google/libwebrtc media playback provider is unavailable");
            pipeline_active = false;
            release_playback_lease(generation);
            if (start_play_button != null) start_play_button.visible = true;
            return;
        }
        try {
            var bridge = new Dino.Ui.MediaAudioPlaybackBridge((!) playback_provider);
            Gst.Element audio_sink_bin = bridge.create_sink_bin();
            playback_bridge = bridge;
            playback_error_handler_id = bridge.playback_error.connect((message) => {
                if (_disposed || playback_bridge == null) return;
                warning("VideoPlayerWidget: WebRTC playback failed: %s", message);
                cleanup_playback();
                if (start_play_button != null) start_play_button.visible = true;
            });
            playbin.set("audio-sink", audio_sink_bin);
        } catch (Error e) {
            warning("VideoPlayerWidget: could not create media playback bridge: %s", e.message);
            pipeline_active = false;
            release_playback_lease(generation);
            if (start_play_button != null) start_play_button.visible = true;
            return;
        }

        playback_pipeline = playbin;

        // Track the asynchronous state transition as well as terminal events.
        Gst.Bus bus = playback_pipeline.get_bus();
        playback_bus_watch = bus.add_watch(0, (b, msg) => {
            if (_disposed) return false;
            if (msg.type == Gst.MessageType.EOS) {
                debug("VideoPlayerWidget: EOS");
                finish_playback_after_eos();
            } else if (msg.type == Gst.MessageType.ERROR) {
                GLib.Error err;
                string dbg;
                msg.parse_error(out err, out dbg);
                warning("VideoPlayerWidget: playback error: %s\n  debug: %s", err.message, dbg ?? "(none)");

                // Check for missing-plugin and log details
                unowned Gst.Structure? st = msg.get_structure();
                if (st != null) {
                    warning("VideoPlayerWidget: error structure: %s", st.to_string());
                }

                cleanup_playback();
                if (controls_bar != null) controls_bar.visible = false;
                if (start_play_button != null) start_play_button.visible = true;
            } else if (msg.type == Gst.MessageType.ASYNC_DONE &&
                    playback_pipeline != null &&
                    msg.src == playback_pipeline) {
                complete_playback_start();
            } else if (msg.type == Gst.MessageType.STATE_CHANGED &&
                    playback_pipeline != null &&
                    msg.src == playback_pipeline) {
                Gst.State old_state;
                Gst.State new_state;
                Gst.State pending_state;
                msg.parse_state_changed(out old_state, out new_state,
                    out pending_state);
                if (new_state == Gst.State.PLAYING) {
                    complete_playback_start();
                }
            }
            return true;
        });

        // Show video container
        if (video_container != null) {
            stack.set_visible_child(video_container);
        }

        playback_duration = -1;
        if (time_label != null) time_label.label = "0:00 / 0:00";
        if (seek_scale != null) seek_scale.set_value(0.0);
        request_playing_state();
    }

    private void request_playing_state() {
        if (playback_pipeline == null || _disposed) return;

        playback_starting = true;
        is_video_playing = false;
        if (start_play_button != null) start_play_button.visible = false;
        cancel_playback_start_timeout();
        playback_start_timeout_id = Timeout.add(
            PLAYBACK_START_TIMEOUT_MS, () => {
                playback_start_timeout_id = 0;
                if (_disposed || !playback_starting) return Source.REMOVE;
                warning("VideoPlayerWidget: playback did not reach PLAYING within %u ms",
                    PLAYBACK_START_TIMEOUT_MS);
                fail_playback_start();
                return Source.REMOVE;
            });

        Gst.StateChangeReturn state_result = playback_pipeline.set_state(
            Gst.State.PLAYING);
        if (state_result == Gst.StateChangeReturn.FAILURE) {
            warning("VideoPlayerWidget: playback pipeline refused PLAYING state");
            fail_playback_start();
        } else if (state_result != Gst.StateChangeReturn.ASYNC) {
            complete_playback_start();
        }
    }

    private void complete_playback_start() {
        if (!playback_starting || playback_pipeline == null || _disposed) {
            return;
        }

        playback_starting = false;
        cancel_playback_start_timeout();
        is_video_playing = true;
        if (controls_bar != null) controls_bar.visible = true;
        if (play_pause_btn != null) {
            play_pause_btn.icon_name = "media-playback-pause-symbolic";
        }
        if (start_play_button != null) start_play_button.visible = false;
        if (frame_update_timer == 0) {
            // 15 fps is sufficient for the GTK texture bridge and avoids
            // rebuilding identical frames at display refresh rate.
            frame_update_timer = Timeout.add(66, () => {
                if (_disposed) {
                    frame_update_timer = 0;
                    return Source.REMOVE;
                }
                update_video_frame();
                return Source.CONTINUE;
            });
        }
        debug("VideoPlayerWidget: decoder playback reached PLAYING with WebRTC audio output");
    }

    private void fail_playback_start() {
        cleanup_playback();
        if (controls_bar != null) controls_bar.visible = false;
        if (start_play_button != null) start_play_button.visible = true;
    }

    private void cancel_playback_start_timeout() {
        if (playback_start_timeout_id != 0) {
            Source.remove(playback_start_timeout_id);
            playback_start_timeout_id = 0;
        }
    }

    private void finish_playback_after_eos() {
        if (playback_finish_timeout_id != 0) return;
        playback_starting = false;
        cancel_playback_start_timeout();
        is_video_playing = false;
        if (frame_update_timer != 0) {
            Source.remove(frame_update_timer);
            frame_update_timer = 0;
        }
        uint drain_ms = 0;
        if (playback_bridge != null) {
            try {
                drain_ms = ((!) playback_bridge).finish();
            } catch (Error e) {
                warning("VideoPlayerWidget: could not finish WebRTC playback: %s", e.message);
                cleanup_playback();
                if (start_play_button != null) start_play_button.visible = true;
                return;
            }
        }
        playback_finish_timeout_id = Timeout.add(drain_ms + 80, () => {
            playback_finish_timeout_id = 0;
            cleanup_playback();
            if (controls_bar != null) controls_bar.visible = false;
            if (start_play_button != null) start_play_button.visible = true;
            if (preview_image != null) stack.set_visible_child(preview_image);
            return Source.REMOVE;
        });
    }

    private void start_setup_pipeline(File file) {
        uint generation = playback_lifecycle.begin_setup();
        setup_pipeline.begin(file, generation, (obj, res) => {
            setup_pipeline.end(res);
        });
    }

    // Pull latest frame from fakesink — only create new texture when PTS changes
    private void update_video_frame() {
        if (_disposed) return;
        if (playback_vsink == null || video_picture == null) return;
        if (!this.get_mapped()) return;

        // Use g_object_get() directly — avoids GLib.Value leak
        // (stack-allocated GLib.Value never gets g_value_unset, leaking GstSample refs)
        Gst.Sample? sample = null;
        playback_vsink.get("last-sample", out sample);
        if (sample == null) return;

        var buf = sample.get_buffer();
        if (buf == null) return;

        // Skip if same frame as last rendered (compare PTS, not pointer)
        int64 pts = (int64) buf.pts;
        if (pts == last_frame_pts && last_frame_pts >= 0) return;

        var caps = sample.get_caps();
        if (caps == null || caps.get_size() == 0) return;

        unowned Gst.Structure st = caps.get_structure(0);
        int width = 0, height = 0;
        st.get_int("width", out width);
        st.get_int("height", out height);
        if (width <= 0 || height <= 0) return;

        Gst.MapInfo map;
        if (buf.map(out map, Gst.MapFlags.READ)) {
            if (map.data == null || map.size < (size_t)(width * height * 4)) {
                buf.unmap(map);
                return;
            }
            var bytes = new GLib.Bytes(map.data);
            buf.unmap(map);

            size_t row_stride = (size_t)(width * 4);
            var texture = new Gdk.MemoryTexture(width, height,
                Gdk.MemoryFormat.R8G8B8A8, bytes, row_stride);
            video_picture.paintable = texture;
            last_frame_pts = pts;
        }

        // Update seek bar and time label
        if (!seeking && playback_pipeline != null) {
            if (playback_duration <= 0) {
                playback_pipeline.query_duration(Gst.Format.TIME, out playback_duration);
            }
            int64 position = 0;
            if (playback_pipeline.query_position(Gst.Format.TIME, out position) && playback_duration > 0) {
                double frac = (double)position / (double)playback_duration;
                if (seek_scale != null) seek_scale.set_value(frac.clamp(0.0, 1.0));
                if (time_label != null) {
                    time_label.label = "%s / %s".printf(format_time(position), format_time(playback_duration));
                }
            }
        }
    }

    private string format_time(int64 ns) {
        int64 s = ns / Gst.SECOND;
        int m = (int)(s / 60);
        int sec = (int)(s % 60);
        return "%d:%02d".printf(m, sec);
    }

    private async void open_file() {
        try {
            if (!can_play_media_payload()) return;

            File? file = file_transfer.get_file();
            if (file != null) {
                FileManager? file_manager = get_file_manager();
                if (file_manager == null) return;

                if (temp_open_lease != null) ((!) temp_open_lease).release();
                Dino.PlaintextFileLease lease = yield ((!) file_manager).create_plaintext_file_lease(file_transfer, "open");
                if (!can_play_media_payload()) {
                    lease.release();
                    return;
                }
                temp_open_lease = lease;
                temp_open_file = lease.file;

                launch_file_with_default_app((!) temp_open_file);
            }
        } catch (GLib.Error err) {
            warning("Failed to open file: %s", err.message);
        }
    }

    private static void launch_file_with_default_app(File file) throws Error {
#if WINDOWS
        string? path = file.get_path();
        if (path == null || path == "") {
            throw new IOError.FAILED("Cannot open file without local path");
        }
        if (!SystrayWin32.open_file(path)) {
            throw new IOError.FAILED("Windows could not open the file with the default application");
        }
#else
        try {
            AppInfo.launch_default_for_uri(file.get_uri(), null);
        } catch (Error appinfo_error) {
            throw appinfo_error;
        }
#endif
    }

    private void start_open_file() {
        open_file.begin((obj, res) => {
            open_file.end(res);
        });
    }

    private void save_file() {
        if (!can_play_media_payload()) return;

        var save_dialog = new Gtk.FileDialog();
        save_dialog.title = _("Save as…");
        save_dialog.initial_name = file_transfer.file_name;

        save_dialog.save.begin(this.get_root() as Gtk.Window, null, (obj, res) => {
            start_save_file_finish(obj, res);
        });
    }

    private void start_save_file_finish(GLib.Object? obj, AsyncResult res) {
        save_file_finish.begin(obj, res, (source, save_res) => {
            save_file_finish.end(save_res);
        });
    }

    private async void save_file_finish(GLib.Object? obj, AsyncResult res) {
        var save_dialog = (Gtk.FileDialog) obj;
        try {
            File? target_file = save_dialog.save.end(res);
            if (target_file != null) {
                if (!can_play_media_payload()) return;
                File? source_file = file_transfer.get_file();
                if (source_file != null) {
                    FileManager? file_manager = get_file_manager();
                    if (file_manager != null) {
                        yield ((!) file_manager).export_plaintext_file(file_transfer, target_file);
                    }
                }
            }
        } catch (GLib.Error e) {
            warning("Failed to save file: %s", e.message);
        }
    }

    private void start_download() {
        if (stream_interactor == null || file_transfer == null) return;
        if (file_transfer.state != FileTransfer.State.NOT_STARTED && file_transfer.state != FileTransfer.State.FAILED) return;
        FileManager? file_manager = get_file_manager();
        if (file_manager == null) return;

        if (file_transfer.direction == FileTransfer.DIRECTION_SENT) {
            if (file_transfer.can_retry_send_attempt()) {
                ((!) file_manager).retry_send_file.begin(file_transfer);
            }
            return;
        }

        if (has_download_source()) {
            ((!) file_manager).download_file.begin(file_transfer);
        }
    }

    private void cancel_download() {
        if (file_transfer == null) return;
        FileManager? file_manager = get_file_manager();
        if (file_manager != null) {
            ((!) file_manager).cancel_download((!) file_transfer);
        } else {
            ((!) file_transfer).cancellable.cancel();
        }
    }

    public override void dispose() {
        _disposed = true;
        if (context_menu != null) { context_menu.dispose(); context_menu = null; }
        preview_lifecycle.invalidate_setup();
        playback_lifecycle.invalidate_setup();
        // Break reference cycles: disconnect this.notify signals
        if (map_handler_id != 0) { this.disconnect(map_handler_id); map_handler_id = 0; }
        if (unmap_handler_id != 0) { this.disconnect(unmap_handler_id); unmap_handler_id = 0; }
        if (notify_ft_state_handler_id != 0) { this.disconnect(notify_ft_state_handler_id); notify_ft_state_handler_id = 0; }
        if (notify_ft_phase_handler_id != 0) { this.disconnect(notify_ft_phase_handler_id); notify_ft_phase_handler_id = 0; }
        if (file_transfer != null && notify_ft_phase_error_handler_id != 0) { file_transfer.disconnect(notify_ft_phase_error_handler_id); notify_ft_phase_error_handler_id = 0; }
        if (file_transfer != null && notify_ft_bytes_handler_id != 0) { file_transfer.disconnect(notify_ft_bytes_handler_id); notify_ft_bytes_handler_id = 0; }
        if (file_transfer != null && notify_ft_phase_total_handler_id != 0) { file_transfer.disconnect(notify_ft_phase_total_handler_id); notify_ft_phase_total_handler_id = 0; }
        if (file_transfer != null && ft_sources_handler_id != 0) { file_transfer.disconnect(ft_sources_handler_id); ft_sources_handler_id = 0; }
        // Unbind all file_transfer property bindings
        if (ft_state_binding != null) { ft_state_binding.unbind(); ft_state_binding = null; }
        if (ft_phase_binding != null) { ft_phase_binding.unbind(); ft_phase_binding = null; }
        if (ft_size_binding1 != null) { ft_size_binding1.unbind(); ft_size_binding1 = null; }
        if (ft_phase_total_binding != null) { ft_phase_total_binding.unbind(); ft_phase_total_binding = null; }
        if (ft_bytes_binding != null) { ft_bytes_binding.unbind(); ft_bytes_binding = null; }
        stream_interactor = null;
        file_transfer = null;

        disconnect_scroll_watch();
        if (preview_retry_source_id != 0) {
            Source.remove(preview_retry_source_id);
            preview_retry_source_id = 0;
        }
        cleanup_playback();
        release_plaintext_leases();
        if (video_picture != null) {
            video_picture.paintable = null;
        }
        if (preview_image != null) {
            preview_image.paintable = null;
        }
        base.dispose();
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

    private Gtk.ScrolledWindow? find_scrolled_window() {
        Gtk.Widget? w = this;
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
            update_playback_visibility();
        });
        watched_vadjustment_page_size_handler_id = watched_vadjustment.notify["page-size"].connect(() => {
            update_playback_visibility();
        });
    }

    private bool is_in_viewport() {
        if (watched_scrolled == null || watched_vadjustment == null) {
            return true;
        }

        // Compute widget bounds relative to the ScrolledWindow (not its child).
        // The ScrolledWindow's coordinate space already accounts for scrolling,
        // so a visible widget will have y1 >= 0 and y2 <= page_size.
        Graphene.Rect bounds;
        if (!this.compute_bounds(watched_scrolled, out bounds)) {
            return true;
        }

        double page_size = watched_vadjustment.page_size;
        double y1 = bounds.origin.y;
        double y2 = y1 + bounds.size.height;

        const double margin = 64.0;
        bool result = (y2 >= -margin) && (y1 <= (page_size + margin));
        return result;
    }

    private void update_playback_visibility() {
        if (playback_pipeline == null) {
            try_lazy_preview_init();
        }
    }
}

}
