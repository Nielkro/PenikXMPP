/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gtk;
using Gst;
using Gee;
using Dino.Entities;
using Dino.Security;

namespace Dino.Ui.ConversationSummary {

public class AudioFileMetaItem : FileMetaItem {
    private StreamInteractor stream_interactor;
    
    public AudioFileMetaItem(ContentItem content_item, StreamInteractor stream_interactor) {
        base(content_item, stream_interactor);
        this.stream_interactor = stream_interactor;
        
        // Auto-download audio files if not yet downloaded
        FileManager file_manager = stream_interactor.get_module<FileManager>(FileManager.IDENTITY);
        if (file_transfer.direction == FileTransfer.DIRECTION_RECEIVED && 
            file_transfer.state == FileTransfer.State.NOT_STARTED &&
            file_manager.has_usable_download_source(file_transfer)) {
            file_manager.auto_download_file.begin(file_transfer);
        }
    }

    public override GLib.Object? get_widget(Plugins.ConversationItemWidgetInterface outer, Plugins.WidgetType type) {
        return new AudioPlayerWidget(file_transfer, stream_interactor);
    }
}

public class AudioPlayerWidget : Box {
    private enum PlaybackStartStage { NONE, PREROLLING, SEEKING }
    private FileTransfer? file_transfer;
    private FileContextMenu? context_menu;
    private Button play_button;
    private DrawingArea waveform_area;
    private Scale seek_scale;
    private Box transfer_status_box;
    private Label transfer_status_label;
    private Button transfer_action_button;
    private Label time_label;
    private MenuButton speed_button;
    private CheckButton normal_speed_option;
    private CheckButton faster_speed_option;
    private CheckButton double_speed_option;
    private Element? pipeline;
    private Dino.Ui.MediaAudioPlaybackBridge? playback_bridge = null;
    private ulong playback_error_handler_id = 0;
    private bool is_playing = false;
    private int64 duration = -1;
    private uint update_id = 0;
    private uint bus_watch_id = 0;
    private uint playback_finish_timeout_id = 0;
    private double playback_rate = 1.0;
    private File? temp_play_file = null;
    private Dino.PlaintextFileLease? temp_play_lease = null;
    private int64 saved_position = 0; // saved position for resume after pause
    private int64 displayed_position = 0;
    private bool updating_seek_scale = false;
    private bool setup_pending = false;
    private PlaybackStartStage playback_start_stage = PlaybackStartStage.NONE;
    private int64 pending_seek_position = -1;
    private uint playback_generation = 0;
    private bool _disposed = false;

    // Waveform data
    private double[] waveform_bars = {};
    private const int N_BARS = 50;
    private bool waveform_ready = false;
    private double playback_progress = 0.0; // 0.0 to 1.0
    private ArrayList<double?> scan_peaks = new ArrayList<double?>();
    private Element? scan_element = null;
    private uint scan_bus_watch_id = 0;
    private uint scan_timeout_id = 0;
    private ulong ft_state_handler_id = 0;
    private ulong ft_phase_handler_id = 0;
    private ulong ft_phase_error_handler_id = 0;
    private ulong ft_transferred_handler_id = 0;
    private ulong ft_phase_total_handler_id = 0;
    private ulong ft_sources_handler_id = 0;

    // C binding for GValueArray peak parsing (same as AudioRecorder)
    [CCode (cname = "dino_gva_get_nth")]
    private static extern unowned GLib.Value? gva_get_nth(void* value_array, uint index);

    public AudioPlayerWidget(FileTransfer file_transfer, StreamInteractor? stream_interactor = null) {
        GLib.Object(orientation: Orientation.VERTICAL, spacing: 4);
        this.file_transfer = file_transfer;
        context_menu = new FileContextMenu(this, file_transfer, stream_interactor);
        
        this.add_css_class("audio-player");
        this.margin_top = 18;
        this.margin_bottom = 4;
        this.margin_start = 8;
        this.margin_end = 8;
        this.halign = Align.START;
        this.hexpand = false;

        var controls = new Box(Orientation.HORIZONTAL, 6);
        append(controls);

        play_button = new Button.from_icon_name("media-playback-start-symbolic");
        play_button.add_css_class("circular");
        play_button.add_css_class("flat");
        play_button.add_css_class("audio-play-button");
        play_button.valign = Align.CENTER;
        update_play_button_label();
        play_button.clicked.connect(toggle_playback);
        controls.append(play_button);

        // Stop pipeline when widget is unmapped (scrolled out of view, conversation switched)
        this.unmap.connect(() => {
            pause();
            cleanup_scan(); // Also stop any ongoing waveform scan
        });
        
        // Keep the actual GTK slider for pointer, keyboard and accessible
        // seeking. Its themed thumb sits above the decorative waveform.
        var waveform_overlay = new Overlay();
        waveform_overlay.hexpand = true;
        waveform_overlay.valign = Align.CENTER;
        waveform_overlay.set_size_request(96, 36);
        waveform_area = new DrawingArea();
        waveform_area.add_css_class("audio-waveform");
        waveform_area.hexpand = true;
        waveform_area.valign = Align.CENTER;
        waveform_area.set_size_request(-1, 36);
        waveform_area.can_target = false;
        attach_waveform_draw(waveform_area, this);
        waveform_overlay.set_child(waveform_area);

        seek_scale = new Scale.with_range(Orientation.HORIZONTAL, 0, 1, 1);
        seek_scale.add_css_class("audio-waveform-seek");
        seek_scale.draw_value = false;
        seek_scale.has_origin = false;
        seek_scale.hexpand = true;
        seek_scale.valign = Align.FILL;
        seek_scale.set_flippable(true);
        seek_scale.update_property(AccessibleProperty.LABEL, _("Audio position"), -1);
        seek_scale.tooltip_text = _("Audio position");
        seek_scale.value_changed.connect(() => {
            if (updating_seek_scale || duration <= 0 || _disposed) return;
            int64 position = (int64) (seek_scale.get_value() * Gst.SECOND);
            saved_position = position;
            update_position_display(position);
            if (pipeline != null) {
                seek_to(position);
            } else {
                request_pipeline();
            }
        });
        waveform_overlay.add_overlay(seek_scale);
        // Prefer a readable waveform without stretching the message across
        // the chat. The existing sizing helper allows a narrower allocation.
        var waveform_sizing = new Dino.Ui.SizingBin() {
            target_width = 144,
            hexpand = true,
            valign = Align.CENTER
        };
        waveform_overlay.set_parent(waveform_sizing);
        controls.append(waveform_sizing);

        time_label = new Label("0:00/–:––");
        time_label.add_css_class("monospace");
        time_label.add_css_class("dim-label");
        time_label.valign = Align.CENTER;
        time_label.width_chars = 9;
        time_label.set_direction(TextDirection.LTR);
        controls.append(time_label);

        speed_button = new MenuButton();
        speed_button.icon_name = "view-more-symbolic";
        speed_button.add_css_class("flat");
        speed_button.valign = Align.CENTER;
        speed_button.tooltip_text = _("Playback speed");
        speed_button.update_property(AccessibleProperty.LABEL, _("Playback speed"), -1);

        var speed_popover = new Popover();
        var speed_options = new Box(Orientation.VERTICAL, 6);
        speed_options.margin_top = speed_options.margin_bottom = 8;
        speed_options.margin_start = speed_options.margin_end = 8;
        var speed_title = new Label(_("Playback speed")) { xalign=0 };
        speed_title.add_css_class("heading");
        speed_options.append(speed_title);
        normal_speed_option = new CheckButton.with_label(_("Normal speed"));
        faster_speed_option = new CheckButton.with_label(_("1.5× speed"));
        double_speed_option = new CheckButton.with_label(_("2× speed"));
        faster_speed_option.set_group(normal_speed_option);
        double_speed_option.set_group(normal_speed_option);
        normal_speed_option.active = true;
        normal_speed_option.toggled.connect(() => {
            if (normal_speed_option.active) set_playback_rate(1.0);
        });
        faster_speed_option.toggled.connect(() => {
            if (faster_speed_option.active) set_playback_rate(1.5);
        });
        double_speed_option.toggled.connect(() => {
            if (double_speed_option.active) set_playback_rate(2.0);
        });
        speed_options.append(normal_speed_option);
        speed_options.append(faster_speed_option);
        speed_options.append(double_speed_option);
        speed_popover.set_child(speed_options);
        Dino.Ui.Util.set_menu_button_popover(speed_button, speed_popover);
        controls.append(speed_button);

        transfer_status_box = new Box(Orientation.HORIZONTAL, 8);
        transfer_status_box.visible = false;
        append(transfer_status_box);

        transfer_status_label = new Label(null) { valign=Align.CENTER, xalign=0, visible=false, wrap=true, max_width_chars=28, hexpand=true };
        transfer_status_label.add_css_class("transfer-status");
        transfer_status_label.add_css_class("dim-label");
        transfer_status_box.append(transfer_status_label);

        transfer_action_button = new Button();
        transfer_action_button.visible = false;
        transfer_action_button.valign = Align.CENTER;
        transfer_action_button.add_css_class("small-button");
        transfer_action_button.clicked.connect(on_transfer_action_clicked);
        transfer_status_box.append(transfer_action_button);

        // Do NOT scan waveform automatically — no GStreamer pipeline until user clicks play
        // Placeholder bars are shown in draw_waveform when waveform_ready == false
        ft_state_handler_id = file_transfer.notify["state"].connect(update_transfer_status);
        ft_phase_handler_id = file_transfer.notify["phase"].connect(update_transfer_status);
        ft_phase_error_handler_id = file_transfer.notify["phase-error"].connect(update_transfer_status);
        ft_transferred_handler_id = file_transfer.notify["transferred-bytes"].connect(update_transfer_status);
        ft_phase_total_handler_id = file_transfer.notify["phase-total-bytes"].connect(update_transfer_status);
        ft_sources_handler_id = file_transfer.sources_changed.connect(update_transfer_status);
        update_transfer_status();

        FileManager? file_manager = get_file_manager();
        if (file_manager != null) {
            ((!) file_manager).arm_scheduled_transfer_retry(file_transfer);
        }
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

    private void update_transfer_status() {
        if (file_transfer == null || _disposed) return;

        string? status_text = null;
        string? action_label = null;
        bool action_destructive = false;
        bool error_status = false;
        bool playable = file_transfer.is_plaintext_release_allowed();
        bool source_available = has_download_source();
        if (!playable) {
            stop();
            cleanup_scan();
            release_playback_lease();
        }

        if (file_transfer.state == FileTransfer.State.IN_PROGRESS) {
            status_text = FileDefaultWidget.get_transfer_phase_label(
                file_transfer.phase,
                file_transfer.direction,
                file_transfer.size,
                file_transfer.transferred_bytes,
                file_transfer.phase_total_bytes);
            action_label = _("Cancel");
            action_destructive = true;
        } else if (file_transfer.state == FileTransfer.State.FAILED) {
            status_text = FileDefaultWidget.get_transfer_failure_text(file_transfer.phase_error);
            error_status = true;
            if (file_transfer.direction == FileTransfer.DIRECTION_RECEIVED && source_available) {
                action_label = _("Download");
            } else if (file_transfer.can_retry_send_attempt()) {
                action_label = _("Retry upload");
            }
        } else if (file_transfer.state == FileTransfer.State.NOT_STARTED &&
                   file_transfer.direction == FileTransfer.DIRECTION_RECEIVED &&
                   !source_available) {
            status_text = FileDefaultWidget.get_missing_download_source_text(is_direct_transfer_unavailable(source_available));
            error_status = true;
        } else if (file_transfer.state == FileTransfer.State.NOT_STARTED &&
                   file_transfer.direction == FileTransfer.DIRECTION_RECEIVED) {
            status_text = FileDefaultWidget.get_transfer_phase_label(
                FileTransfer.Phase.DOWNLOADING,
                file_transfer.direction,
                file_transfer.size,
                file_transfer.transferred_bytes,
                file_transfer.phase_total_bytes);
            if (source_available) action_label = _("Download");
        }

        if (status_text != null && status_text != "") {
            transfer_status_label.label = (!) status_text;
            transfer_status_label.tooltip_text = (!) status_text;
            transfer_status_label.visible = true;
            play_button.tooltip_text = (!) status_text;
        } else {
            transfer_status_label.visible = false;
            transfer_status_label.tooltip_text = null;
            update_play_button_label();
        }

        if (error_status) {
            transfer_status_label.add_css_class("error");
        } else {
            transfer_status_label.remove_css_class("error");
        }

        play_button.sensitive = playable;
        waveform_area.sensitive = playable;
        seek_scale.sensitive = playable && duration > 0;
        speed_button.sensitive = playable;
        set_transfer_action(action_label, action_destructive);
        transfer_status_box.visible = transfer_status_label.visible || transfer_action_button.visible;
        if (!playable) {
            play_button.icon_name = error_status ? "dialog-warning-symbolic" : "content-loading-symbolic";
        } else if (!is_playing) {
            play_button.icon_name = "media-playback-start-symbolic";
        }
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
        if (file_transfer == null || _disposed) return;
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

    private FileManager? get_file_manager() {
        Dino.Application? app = GLib.Application.get_default() as Dino.Application;
        if (app == null || app.stream_interactor == null) return null;
        return app.stream_interactor.get_module<FileManager>(FileManager.IDENTITY);
    }

    // Convert dB to perceptual 0.0-1.0 range (same curve as AudioRecorder)
    private double db_to_visual(double db) {
        if (db <= -60.0) return 0.0;
        double normalized = (db + 40.0) / 40.0;
        normalized = double.max(0.0, double.min(normalized, 1.0));
        return Math.sqrt(normalized);
    }

    private static void attach_waveform_draw(DrawingArea area, AudioPlayerWidget widget) {
        var widget_ref = GLib.WeakRef(widget);
        area.set_draw_func((area, cr, width, height) => {
            var player = widget_ref.get() as AudioPlayerWidget;
            if (player != null) player.draw_waveform(area, cr, width, height);
        });
    }

    private void draw_waveform(DrawingArea area, Cairo.Context cr, int width, int height) {
        int n = waveform_ready ? waveform_bars.length : N_BARS;
        if (n == 0) n = N_BARS;

        // The inset matches the native scale's thumb travel and CSS padding.
        double inset = 9.0;
        double available_width = double.max(1.0, width - 2 * inset);
        double bar_width = available_width / n;
        double draw_width = double.max(1.0, double.min(2.5, bar_width * 0.55));
        bool rtl = seek_scale.get_direction() == TextDirection.RTL;
#if GTK_4_12
        Gdk.RGBA accent = area.get_color();
        Gdk.RGBA foreground = this.get_color();
#else
        Gdk.RGBA accent = area.get_style_context().get_color();
        Gdk.RGBA foreground = this.get_style_context().get_color();
#endif

        for (int i = 0; i < n; i++) {
            double level;
            if (waveform_ready && i < waveform_bars.length) {
                level = waveform_bars[i];
            } else {
                level = 0.12; // placeholder: small uniform bars before scan
            }
            level = double.min(level, 1.0);

            double bar_height = (height - 6) * level;
            if (bar_height < 2.0) bar_height = 2.0;

            int visual_index = rtl ? n - 1 - i : i;
            double x = inset + visual_index * bar_width + (bar_width - draw_width) / 2.0;
            double y = (height - bar_height) / 2.0;

            // Use the current theme's accent and foreground in either scheme.
            double bar_fraction = (double)(i + 0.5) / n;
            if (bar_fraction <= playback_progress) {
                cr.set_source_rgba(accent.red, accent.green, accent.blue, accent.alpha);
            } else {
                cr.set_source_rgba(foreground.red, foreground.green, foreground.blue, foreground.alpha * 0.30);
            }

            // Rounded rectangle (pill-shaped bars)
            double radius = draw_width / 2.0;
            if (radius > bar_height / 2.0) radius = bar_height / 2.0;

            cr.new_sub_path();
            cr.arc(x + radius, y + radius, radius, Math.PI, 3 * Math.PI / 2);
            cr.arc(x + draw_width - radius, y + radius, radius, 3 * Math.PI / 2, 0);
            cr.arc(x + draw_width - radius, y + bar_height - radius, radius, 0, Math.PI / 2);
            cr.arc(x + radius, y + bar_height - radius, radius, Math.PI / 2, Math.PI);
            cr.close_path();

            cr.fill();
        }
    }

    // Scan audio file to extract waveform peak data (runs faster than real-time)
    private async void scan_waveform(uint generation) {
        File? audio_file = null;

        // Reuse already-decrypted temp file from setup_pipeline if available
        if (temp_play_file != null) {
            audio_file = temp_play_file;
        } else {
            if (file_transfer == null) return;
            if (file_transfer.state != FileTransfer.State.COMPLETE) return;
            var file = file_transfer.get_file();
            if (file == null) return;

            // Decrypt if needed (reuse temp file for later playback)
            audio_file = yield decrypt_to_temp(file, file_transfer.file_name, generation);
        }

        if (audio_file == null || !is_setup_current(generation)) return;

        scan_peaks.clear();

        // Pipeline + uridecodebin — NO playbin, NO autoaudiosink, ZERO PipeWire
        // uridecodebin only decodes, it creates NO sinks
        var scan_pipe = new Gst.Pipeline("waveform-scanner");
        var sc_src = ElementFactory.make("uridecodebin", "sc-src");
        var sc_conv = ElementFactory.make("audioconvert", "sc-conv");
        var sc_resample = ElementFactory.make("audioresample", "sc-resample");
        var sc_caps = ElementFactory.make("capsfilter", "sc-caps");
        var sc_level = ElementFactory.make("level", "sc-level");
        var sc_sink = ElementFactory.make("fakesink", "sc-sink");

        if (sc_src == null || sc_conv == null || sc_resample == null || sc_caps == null || sc_level == null || sc_sink == null) {
            return;
        }

        sc_caps.set("caps", Caps.from_string("audio/x-raw, rate=8000, channels=1"));
        sc_level.set("interval", (uint64)50000000); // 50ms intervals → ~20 peaks/sec
        sc_level.set("post-messages", true);
        sc_sink.set("sync", false); // Process faster than real-time

        // Only decode audio streams (caps filter on uridecodebin)
        sc_src.set("caps", Caps.from_string("audio/x-raw"));

        scan_pipe.add_many(sc_src, sc_conv, sc_resample, sc_caps, sc_level, sc_sink);
        sc_conv.link(sc_resample);
        sc_resample.link(sc_caps);
        sc_caps.link(sc_level);
        sc_level.link(sc_sink);

        // Dynamic pad linking from uridecodebin
        sc_src.pad_added.connect((pad) => {
            var sink_pad = sc_conv.get_static_pad("sink");
            if (sink_pad != null && !sink_pad.is_linked()) {
                pad.link(sink_pad);
            }
        });

        sc_src.set("uri", audio_file.get_uri());
        scan_element = scan_pipe;

        Gst.Bus sbus = scan_pipe.get_bus();

        scan_bus_watch_id = sbus.add_watch(0, (bus, msg) => {
            if (msg.type == Gst.MessageType.ELEMENT && msg.src != null && msg.src.name == "sc-level") {
                unowned Gst.Structure st = msg.get_structure();
                if (st != null && st.has_field("peak")) {
                    unowned GLib.Value? pk = st.get_value("peak");
                    if (pk != null) {
                        void* boxed = pk.get_boxed();
                        if (boxed != null) {
                            unowned GLib.Value? v = gva_get_nth(boxed, 0);
                            if (v != null) {
                                scan_peaks.add(db_to_visual(v.get_double()));
                            }
                        }
                    }
                }
            } else if (msg.type == Gst.MessageType.EOS) {
                finalize_waveform();
                // Don't call Source.remove from inside callback — return false instead
                scan_bus_watch_id = 0;
                if (scan_timeout_id != 0) {
                    Source.remove(scan_timeout_id);
                    scan_timeout_id = 0;
                }
                if (scan_element != null) {
                    scan_element.set_state(State.NULL);
                    scan_element = null;
                }
                return false; // Removes this bus watch source
            } else if (msg.type == Gst.MessageType.ERROR) {
                scan_bus_watch_id = 0;
                if (scan_timeout_id != 0) {
                    Source.remove(scan_timeout_id);
                    scan_timeout_id = 0;
                }
                if (scan_element != null) {
                    scan_element.set_state(State.NULL);
                    scan_element = null;
                }
                return false; // Removes this bus watch source
            }
            return true;
        });

        scan_element.set_state(State.PLAYING);

        // Safety timeout: force cleanup if scan hangs (10 seconds)
        scan_timeout_id = Timeout.add(10000, () => {
            scan_timeout_id = 0; // Clear before cleanup to prevent double-remove
            if (scan_element != null) {
                debug("AudioPlayerWidget: scan timeout, forcing cleanup");
                finalize_waveform();
                cleanup_scan();
            }
            return false;
        });
    }

    private void finalize_waveform() {
        if (scan_peaks.size == 0) return;

        waveform_bars = new double[N_BARS];

        if (scan_peaks.size <= N_BARS) {
            // Fewer peaks than bars: spread evenly
            for (int i = 0; i < N_BARS; i++) {
                int src = (int)((double)i / N_BARS * scan_peaks.size);
                src = int.min(src, scan_peaks.size - 1);
                waveform_bars[i] = scan_peaks[src];
            }
        } else {
            // More peaks than bars: take max of each group for dynamic waveform
            double group_size = (double)scan_peaks.size / N_BARS;
            for (int i = 0; i < N_BARS; i++) {
                int start = (int)(i * group_size);
                int end = (int)((i + 1) * group_size);
                end = int.min(end, scan_peaks.size);
                double max_val = 0;
                for (int j = start; j < end; j++) {
                    double v = scan_peaks[j];
                    if (v > max_val) max_val = v;
                }
                waveform_bars[i] = max_val;
            }
        }

        waveform_ready = true;
        waveform_area.queue_draw();
    }

    private void cleanup_scan() {
        if (scan_timeout_id != 0) {
            Source.remove(scan_timeout_id);
            scan_timeout_id = 0;
        }
        // Remove bus watch FIRST to prevent callbacks during teardown
        if (scan_bus_watch_id != 0) {
            Source.remove(scan_bus_watch_id);
            scan_bus_watch_id = 0;
        }
        if (scan_element != null) {
            scan_element.set_state(State.NULL);
            scan_element = null;
        }
    }
    
    private void set_playback_rate(double rate) {
        if (playback_rate == rate) return;
        playback_rate = rate;
        speed_button.popdown();
        
        if (is_playing || (setup_pending && playback_bridge != null)) {
            // Recreate both the decoder segment and the WebRTC source clock at
            // the saved position so accelerated PCM cannot fill the worker
            // queue while it is still consuming at the previous rate.
            pause();
            play();
        }
    }

    private void update_play_button_label() {
        string label = setup_pending ? _("Cancel") : (is_playing ? _("Pause audio") : _("Play audio"));
        play_button.tooltip_text = label;
        play_button.update_property(AccessibleProperty.LABEL, label, -1);
    }
    
    private void toggle_playback() {
        if (is_playing || setup_pending) {
            pause();
        } else {
            play();
        }
    }
    
    private void play() {
        if (_disposed || !get_mapped() || file_transfer == null || !file_transfer.is_plaintext_release_allowed()) return;
        // A finished bridge may still be draining. Replay uses a fresh session.
        if (playback_finish_timeout_id != 0) stop();

        if (pipeline == null) {
            request_pipeline();
            return;
        }

        // The decoder cannot accept a seek until its first segment exists.
        // Preroll without producing PCM, then apply rate/resume before PLAYING.
        playback_start_stage = PlaybackStartStage.PREROLLING;
        StateChangeReturn state_result = pipeline.set_state(State.PAUSED);
        if (state_result == StateChangeReturn.FAILURE) {
            warning("AudioPlayerWidget: playback pipeline refused PAUSED state");
            stop();
            play_button.icon_name = "dialog-error-symbolic";
            return;
        }
        if (state_result != StateChangeReturn.ASYNC) seek_start_position();
    }

    private void seek_start_position() {
        if (pipeline == null || _disposed || !get_mapped() || !setup_pending) return;
        query_duration();
        if (playback_rate == 1.0 && saved_position == 0) {
            // Normal playback at the beginning does not require seeking.
            pending_seek_position = 0;
            finish_starting_playback();
            return;
        }
        playback_start_stage = PlaybackStartStage.SEEKING;
        apply_seek(saved_position);
    }

    private void finish_starting_playback() {
        if (pipeline == null || _disposed || !get_mapped() || !setup_pending) return;
        if (pending_seek_position != saved_position) {
            // Seeking during preroll only replaces the desired position.
            seek_start_position();
            return;
        }
        playback_start_stage = PlaybackStartStage.NONE;
        pending_seek_position = -1;
        setup_pending = false;
        saved_position = 0;
        if (pipeline.set_state(State.PLAYING) == StateChangeReturn.FAILURE) {
            warning("AudioPlayerWidget: playback pipeline refused PLAYING state");
            stop();
            play_button.icon_name = "dialog-error-symbolic";
            return;
        }
        is_playing = true;
        play_button.icon_name = "media-playback-pause-symbolic";
        update_play_button_label();
        update_progress();
        if (update_id == 0) {
            update_id = Timeout.add(50, update_progress);
        }
    }
    
    private void pause() {
        // A decrypt/download continuation may still be pending after unmap.
        // Invalidate it before releasing any active native output.
        playback_generation++;
        setup_pending = false;
        cleanup_scan();
        // Save current position before stopping pipeline
        if (pipeline != null) {
            int64 position;
            saved_position = query_playback_position(out position) && position >= 0 ?
                position : displayed_position;
            update_position_display(saved_position);
        }
        playback_start_stage = PlaybackStartStage.NONE;
        pending_seek_position = -1;
        is_playing = false;
        play_button.icon_name = "media-playback-start-symbolic";
        update_play_button_label();
        
        if (update_id != 0) {
            Source.remove(update_id);
            update_id = 0;
        }
        
        // Fully stop pipeline to release PipeWire/PulseAudio connection
        // Remove bus watch FIRST to prevent callbacks during teardown
        if (bus_watch_id != 0) {
            Source.remove(bus_watch_id);
            bus_watch_id = 0;
        }
        if (pipeline != null) {
            pipeline.set_state(State.NULL);
            pipeline = null;
        }
        stop_playback_bridge();
    }

    private void stop() {
        playback_generation++;
        setup_pending = false;
        playback_start_stage = PlaybackStartStage.NONE;
        pending_seek_position = -1;
        // Remove bus watch FIRST to prevent callbacks during teardown
        if (bus_watch_id != 0) {
            Source.remove(bus_watch_id);
            bus_watch_id = 0;
        }
        if (pipeline != null) {
            pipeline.set_state(State.NULL);
            pipeline = null;
        }
        stop_playback_bridge();
        is_playing = false;
        saved_position = 0;
        play_button.icon_name = "media-playback-start-symbolic";
        update_play_button_label();
        update_position_display(0);
        
        if (update_id != 0) {
            Source.remove(update_id);
            update_id = 0;
        }
    }

    // Decrypt an encrypted file to a random temp file in the audio cache dir.
    // Returns null on failure so playback never falls back to the encrypted
    // at-rest storage file.
    private async File? decrypt_to_temp(File source_file, string filename, uint generation) {
        try {
            if (file_transfer == null) return null;
            if (!file_transfer.is_plaintext_release_allowed()) return null;

            Dino.Application? app = GLib.Application.get_default() as Dino.Application;
            if (app == null) return null;

            FileManager file_manager = app.stream_interactor.get_module<FileManager>(FileManager.IDENTITY);
            Dino.PlaintextFileLease lease = yield file_manager.create_plaintext_file_lease((!) file_transfer, "audio-playback");
            if (!is_setup_current(generation)) {
                lease.release();
                return null;
            }
            if (temp_play_lease != null) {
                ((!) temp_play_lease).release();
            }
            temp_play_lease = lease;
            temp_play_file = lease.file;

            return temp_play_file;
        } catch (Error e) {
            warning("AudioPlayerWidget: decrypt failed: %s", e.message);
            return null;
        }
    }

    private bool is_setup_current(uint generation) {
        return !_disposed && get_mapped() && generation == playback_generation &&
            file_transfer != null && file_transfer.is_plaintext_release_allowed();
    }

    private void request_pipeline() {
        if (setup_pending || _disposed || !get_mapped()) return;
        if (file_transfer == null || !file_transfer.is_plaintext_release_allowed()) return;
        setup_pending = true;
        uint generation = ++playback_generation;
        play_button.icon_name = "content-loading-symbolic";
        update_play_button_label();
        setup_pipeline.begin(generation, (obj, res) => {
            setup_pipeline.end(res);
            if (!is_setup_current(generation)) return;
            if (pipeline == null) {
                setup_pending = false;
                update_play_button_label();
            }
        });
    }

    private async void setup_pipeline(uint generation) {
        if (!is_setup_current(generation)) return;
        FileTransfer transfer = (!) file_transfer;

        File file_to_play;

        // Reuse already-decrypted temp file from waveform scan if available
        if (temp_play_file != null) {
            file_to_play = temp_play_file;
        } else {
            var file = transfer.get_file();
            if (file == null) {
                // Already failed or download error? Don't wait
                if (transfer.state == FileTransfer.State.FAILED ||
                    (transfer.state == FileTransfer.State.NOT_STARTED && transfer.info != null)) {
                    play_button.icon_name = "dialog-error-symbolic";
                    play_button.sensitive = false;
                    play_button.tooltip_text = _("File corrupted or unavailable");
                    return;
                }

                // File not yet downloaded -- wait for download to complete or fail
                play_button.icon_name = "content-loading-symbolic";
                play_button.sensitive = false;

                bool resolved = false;
                ulong notify_path_id = 0;
                ulong notify_state_id = 0;
                SourceFunc cb = setup_pipeline.callback;

                notify_path_id = transfer.notify["path"].connect(() => {
                    if (transfer.state == FileTransfer.State.COMPLETE && transfer.path != null && !resolved) {
                        resolved = true;
                        Idle.add((owned) cb);
                    }
                });

                // Watch for FAILED or back to NOT_STARTED (download error)
                notify_state_id = transfer.notify["state"].connect(() => {
                    if ((transfer.state == FileTransfer.State.COMPLETE ||
                         transfer.state == FileTransfer.State.FAILED ||
                         transfer.state == FileTransfer.State.NOT_STARTED) && !resolved) {
                        resolved = true;
                        Idle.add((owned) cb);
                    }
                });

                // Safety timeout 30s
                bool timeout_fired = false;
                uint timeout_id = Timeout.add(30000, () => {
                    timeout_fired = true;
                    if (!resolved) {
                        resolved = true;
                        cb();
                    }
                    return false;
                });

                yield;

                if (!timeout_fired) Source.remove(timeout_id);
                transfer.disconnect(notify_path_id);
                transfer.disconnect(notify_state_id);
                if (!is_setup_current(generation)) return;

                if (transfer.state != FileTransfer.State.COMPLETE) {
                    play_button.icon_name = "dialog-error-symbolic";
                    play_button.sensitive = false;
                    play_button.tooltip_text = _("File corrupted or unavailable");
                    return;
                }

                play_button.icon_name = "media-playback-start-symbolic";
                play_button.sensitive = true;

                file = transfer.get_file();
                if (file == null) {
                    warning("Audio file download timed out");
                    play_button.icon_name = "dialog-error-symbolic";
                    play_button.sensitive = false;
                    return;
                }
            }

            File? decrypted_file = yield decrypt_to_temp(file, transfer.file_name, generation);
            if (!is_setup_current(generation)) return;
            if (decrypted_file == null) {
                play_button.icon_name = "dialog-error-symbolic";
                play_button.sensitive = false;
                play_button.tooltip_text = _("File corrupted or unavailable");
                return;
            }
            file_to_play = (!) decrypted_file;
        }
        if (!is_setup_current(generation)) return;

        // GStreamer only demuxes/decodes. The appsink bridge sends PCM to the
        // selected Google/libwebrtc speaker owned by the external worker.
        var play_pipe = new Gst.Pipeline("audio-playback");
        var play_src = ElementFactory.make("uridecodebin", "play-src");
        var play_queue = ElementFactory.make("queue", "play-queue");
        var app = GLib.Application.get_default() as Dino.Application;
        if (app == null) return;
        Dino.Plugins.MediaMessagePlaybackProvider? playback_provider =
            app.plugin_registry.media_message_playback_provider;
        if (playback_provider == null) {
            warning("AudioPlayerWidget: Google/libwebrtc media playback provider is unavailable");
            play_button.icon_name = "dialog-error-symbolic";
            return;
        }

        Dino.Ui.MediaAudioPlaybackBridge bridge;
        Gst.Element play_sink;
        try {
            bridge = new Dino.Ui.MediaAudioPlaybackBridge(
                (!) playback_provider,
                playback_rate);
            play_sink = bridge.create_sink_bin();
        } catch (Error e) {
            warning("AudioPlayerWidget: could not create media playback bridge: %s", e.message);
            play_button.icon_name = "dialog-error-symbolic";
            return;
        }
        playback_bridge = bridge;
        playback_error_handler_id = bridge.playback_error.connect((message) => {
            if (_disposed || playback_bridge == null) return;
            warning("AudioPlayerWidget: WebRTC playback failed: %s", message);
            stop();
            play_button.icon_name = "dialog-error-symbolic";
        });

        if (play_src == null || play_queue == null) {
            warning("Could not create audio playback pipeline");
            stop_playback_bridge();
            return;
        }

        // Only decode audio (no video pads → no PipeWire video entry from album art)
        play_src.set("caps", Caps.from_string("audio/x-raw"));
        play_src.set("uri", file_to_play.get_uri());

        play_pipe.add_many(play_src, play_queue, play_sink);
        if (!play_queue.link(play_sink)) {
            warning("AudioPlayerWidget: could not link audio playback elements");
            play_pipe.set_state(State.NULL);
            stop_playback_bridge();
            return;
        }

        // Dynamic pad linking from uridecodebin
        play_src.pad_added.connect((pad) => {
            var sink_pad = play_queue.get_static_pad("sink");
            if (sink_pad != null && !sink_pad.is_linked()) {
                PadLinkReturn link_result = pad.link(sink_pad);
                if (link_result != PadLinkReturn.OK) {
                    warning(
                        "AudioPlayerWidget: decoder pad link failed: %s",
                        link_result.to_string());
                }
            }
        });

        pipeline = play_pipe;
        
        Gst.Bus bus = play_pipe.get_bus();
        bus_watch_id = bus.add_watch(0, bus_callback);
        
        // Lazy waveform scan: only now (first play click) do we create a scan pipeline.
        // The scan pipeline uses fakesink only — no PipeWire entry.
        if (!waveform_ready) {
            start_scan_waveform();
        }
        
        // Start playing after setup
        play();
    }

    private void start_scan_waveform() {
        if (scan_element != null) return;
        scan_waveform.begin(playback_generation, (obj, res) => {
            scan_waveform.end(res);
        });
    }
    
    private bool bus_callback(Gst.Bus bus, Gst.Message msg) {
        if (_disposed) return false;
        switch (msg.type) {
            case Gst.MessageType.EOS:
                finish_playback_after_eos();
                break;
            case Gst.MessageType.ERROR:
                GLib.Error err;
                string debug;
                msg.parse_error(out err, out debug);
                warning(
                    "AudioPlayerWidget: playback error: %s\n  debug: %s",
                    err.message,
                    debug ?? "(none)");
                stop();
                break;
            case Gst.MessageType.DURATION_CHANGED:
                query_duration();
                break;
            case Gst.MessageType.ASYNC_DONE:
                if (msg.src != pipeline) break;
                if (playback_start_stage == PlaybackStartStage.PREROLLING) {
                    seek_start_position();
                } else if (playback_start_stage == PlaybackStartStage.SEEKING) {
                    finish_starting_playback();
                } else {
                    pending_seek_position = -1;
                }
                break;
            default:
                break;
        }
        return true;
    }
    
    private void query_duration() {
        if (pipeline == null) return;
        int64 queried_duration;
        if (pipeline.query_duration(Format.TIME, out queried_duration) && queried_duration > 0) {
            update_timeline(queried_duration, displayed_position);
        }
    }

    // Shared with focused widget tests: this is the same timeline update used
    // by native duration/position queries and does not open an output device.
    internal void update_timeline(int64 total_duration, int64 position) {
        duration = total_duration;
        update_position_display(position);
    }

    private void update_position_display(int64 position) {
        displayed_position = int64.max(0, position);
        if (duration > 0) displayed_position = int64.min(displayed_position, duration);
        playback_progress = duration > 0 ? (double) displayed_position / duration : 0;

        string text = "%s/%s".printf(format_time(displayed_position), duration > 0 ? format_time(duration) : "–:––");
        if (time_label.label != text) {
            time_label.label = text;
            seek_scale.update_property(AccessibleProperty.VALUE_TEXT, text, -1);
        }
        updating_seek_scale = true;
        double upper = duration > 0 ? (double) duration / Gst.SECOND : 1;
        if (seek_scale.adjustment.upper != upper) seek_scale.set_range(0, upper);
        seek_scale.set_increments(1, 10);
        seek_scale.set_value((double) displayed_position / Gst.SECOND);
        updating_seek_scale = false;
        seek_scale.sensitive = duration > 0 && file_transfer != null && file_transfer.is_plaintext_release_allowed();
        waveform_area.queue_draw();
    }
    
    private bool update_progress() {
        if (_disposed) { update_id = 0; return false; }
        if (pipeline != null) {
            if (duration <= 0) query_duration();
            int64 position;
            if (query_playback_position(out position)) {
                update_position_display(position);
            }
        }
        return true;
    }
    
    private void seek_to(int64 position) {
        if (playback_finish_timeout_id != 0) {
            stop();
            saved_position = position;
            update_position_display(position);
            request_pipeline();
            return;
        }
        if (playback_start_stage != PlaybackStartStage.NONE) return;
        apply_seek(position);
    }

    private bool apply_seek(int64 position) {
        if (pipeline != null) {
            if (playback_bridge != null) {
                try {
                    ((!) playback_bridge).flush();
                } catch (Error e) {
                    warning("AudioPlayerWidget: could not flush WebRTC playback: %s", e.message);
                    stop();
                    play_button.icon_name = "dialog-error-symbolic";
                    return false;
                }
            }
            if (!pipeline.seek(playback_rate, Format.TIME, SeekFlags.FLUSH | SeekFlags.ACCURATE,
                               Gst.SeekType.SET, position, Gst.SeekType.NONE, -1)) {
                warning("AudioPlayerWidget: playback pipeline refused seek after preroll");
                stop();
                play_button.icon_name = "dialog-error-symbolic";
                return false;
            }
            pending_seek_position = position;
            update_position_display(position);
            return true;
        }
        return false;
    }

    // Query actual decoder time only after its pending start/seek has settled.
    // Focused integration tests also use this path rather than the UI value.
    internal bool query_playback_position(out int64 position) {
        position = -1;
        return pipeline != null && playback_start_stage == PlaybackStartStage.NONE &&
            pending_seek_position < 0 && pipeline.query_position(Format.TIME, out position);
    }
    
    private string format_time(int64 ns) {
        int64 s = ns / Gst.SECOND;
        return "%d:%02d".printf((int)(s / 60), (int)(s % 60));
    }

    private void release_playback_lease() {
        if (temp_play_lease == null) return;
        ((!) temp_play_lease).release();
        temp_play_lease = null;
        temp_play_file = null;
    }

    private void finish_playback_after_eos() {
        if (playback_finish_timeout_id != 0) return;
        is_playing = false;
        play_button.icon_name = "media-playback-start-symbolic";
        update_play_button_label();
        if (update_id != 0) {
            Source.remove(update_id);
            update_id = 0;
        }

        uint drain_ms = 0;
        if (playback_bridge != null) {
            try {
                drain_ms = ((!) playback_bridge).finish();
            } catch (Error e) {
                warning("AudioPlayerWidget: could not finish WebRTC playback: %s", e.message);
                stop();
                play_button.icon_name = "dialog-error-symbolic";
                return;
            }
        }
        playback_finish_timeout_id = Timeout.add(drain_ms + 80, () => {
            playback_finish_timeout_id = 0;
            stop();
            return Source.REMOVE;
        });
    }

    private void stop_playback_bridge() {
        if (playback_finish_timeout_id != 0) {
            Source.remove(playback_finish_timeout_id);
            playback_finish_timeout_id = 0;
        }
        if (playback_bridge == null) return;
        if (playback_error_handler_id != 0 &&
                SignalHandler.is_connected((!) playback_bridge, playback_error_handler_id)) {
            ((!) playback_bridge).disconnect(playback_error_handler_id);
        }
        playback_error_handler_id = 0;
        ((!) playback_bridge).stop();
        playback_bridge = null;
    }
    
    public override void dispose() {
        _disposed = true;
        if (context_menu != null) { context_menu.dispose(); context_menu = null; }
        stop();
        cleanup_scan();
        if (file_transfer != null && ft_state_handler_id != 0) { file_transfer.disconnect(ft_state_handler_id); ft_state_handler_id = 0; }
        if (file_transfer != null && ft_phase_handler_id != 0) { file_transfer.disconnect(ft_phase_handler_id); ft_phase_handler_id = 0; }
        if (file_transfer != null && ft_phase_error_handler_id != 0) { file_transfer.disconnect(ft_phase_error_handler_id); ft_phase_error_handler_id = 0; }
        if (file_transfer != null && ft_transferred_handler_id != 0) { file_transfer.disconnect(ft_transferred_handler_id); ft_transferred_handler_id = 0; }
        if (file_transfer != null && ft_phase_total_handler_id != 0) { file_transfer.disconnect(ft_phase_total_handler_id); ft_phase_total_handler_id = 0; }
        if (file_transfer != null && ft_sources_handler_id != 0) { file_transfer.disconnect(ft_sources_handler_id); ft_sources_handler_id = 0; }
        file_transfer = null;
        release_playback_lease();
        base.dispose();
    }
}

}
