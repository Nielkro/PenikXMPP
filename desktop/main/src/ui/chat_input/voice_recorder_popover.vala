/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gtk;
using Cairo;
using Gee;

namespace Dino.Ui.ChatInput {

public class VoiceRecorderPopover : Popover {
    private AudioMessageRecorderBackend? recorder;
    private Label timer_label;
    private DrawingArea rec_indicator;
    private DrawingArea waveform;
    private Button send_button;
    private Button discard_button;
    private ArrayList<double?> samples = new ArrayList<double?>();
    private const int MAX_SAMPLES = 60;
    private bool indicator_visible = true;
    private bool action_pending = false;
    private bool action_dispatched = false;
    private bool disposed = false;
    private uint blink_id = 0;
    private uint action_dispatch_id = 0;
    private ulong duration_handler_id = 0;
    private ulong level_handler_id = 0;
    private ulong max_duration_handler_id = 0;

    public signal void send_clicked();
    public signal void cancel_clicked();

    public VoiceRecorderPopover(AudioMessageRecorderBackend recorder) {
        this.recorder = recorder;
        // Keep recording open until an explicit action or Escape closes it.
        // This also avoids accidental cancellation during native device focus
        // changes on Windows; capture itself is owned by Google/libwebrtc.
        autohide = false;
        add_css_class("voice-recorder-popover");

        var main_box = new Box(Orientation.VERTICAL, 10);
        main_box.margin_start = main_box.margin_end = 12;
        main_box.margin_top = main_box.margin_bottom = 12;

        var header = new Box(Orientation.HORIZONTAL, 8);
        rec_indicator = new DrawingArea();
        rec_indicator.set_size_request(10, 10);
        rec_indicator.valign = Align.CENTER;
        rec_indicator.add_css_class("error");
        rec_indicator.add_css_class("voice-recording-indicator");
        rec_indicator.tooltip_text = _("Recording voice message");
        header.append(rec_indicator);

        var title = new Label(_("Recording voice message"));
        title.add_css_class("heading");
        title.xalign = 0;
        title.hexpand = true;
        title.ellipsize = Pango.EllipsizeMode.END;
        title.tooltip_text = title.label;
        header.append(title);

        timer_label = new Label(null);
        timer_label.add_css_class("monospace");
        timer_label.add_css_class("dim-label");
        timer_label.set_direction(TextDirection.LTR);
        timer_label.valign = Align.CENTER;
        header.append(timer_label);
        main_box.append(header);

        waveform = new DrawingArea();
        waveform.set_size_request(240, 44);
        waveform.hexpand = true;
        waveform.add_css_class("voice-recorder-waveform");
        waveform.update_property(AccessibleProperty.LABEL, _("Microphone input level"), -1);
        attach_drawing_callbacks(this);
        main_box.append(waveform);

        var buttons = new Box(Orientation.HORIZONTAL, 8);
        discard_button = create_action_button("user-trash-symbolic", _("Discard"), _("Discard voice message"));
        discard_button.clicked.connect(request_discard);
        buttons.append(discard_button);
        send_button = create_action_button("mail-send-symbolic", _("Send"), _("Send voice message"));
        send_button.add_css_class("suggested-action");
        send_button.hexpand = true;
        send_button.clicked.connect(request_send);
        buttons.append(send_button);
        main_box.append(buttons);
        set_child(main_box);

        duration_handler_id = recorder.duration_changed.connect(on_duration_changed);
        level_handler_id = recorder.level_changed.connect(on_level_changed);
        max_duration_handler_id = recorder.max_duration_reached.connect(request_send);
        map.connect(on_map);
        unmap.connect(on_hidden);
        closed.connect(on_hidden);
        prepare_for_recording();
    }

    private static Button create_action_button(string icon, string label, string description) {
        var button = new Button();
        button.child = new Adw.ButtonContent() { icon_name = icon, label = label };
        button.tooltip_text = description;
        button.update_property(AccessibleProperty.LABEL, description, -1);
        return button;
    }

    // The controller calls this before popup because a cached popover can be
    // reopened before its previous closing animation has completely unmapped.
    public void prepare_for_recording() {
        cancel_pending_action();
        stop_blink();
        action_dispatched = false;
        indicator_visible = true;
        samples.clear();
        for (int i = 0; i < MAX_SAMPLES; i++) samples.add(0.0);
        timer_label.label = format_duration("0:00");
        waveform.queue_draw();
        rec_indicator.queue_draw();
        update_action_sensitivity();
    }

    private void on_map() {
        prepare_for_recording();
        ensure_blink();
    }

    private void on_hidden() {
        cancel_pending_action();
        stop_blink();
    }

    private static string format_duration(string text) {
        // The existing backend appends a last-30-seconds countdown. The
        // elapsed/limit display makes that limit explicit throughout capture.
        string elapsed = text.split(" ", 2)[0];
        string limit = "%d:%02d".printf(
            ProviderAudioMessageRecorderBackend.MAX_DURATION_SECONDS / 60,
            ProviderAudioMessageRecorderBackend.MAX_DURATION_SECONDS % 60);
        return _("%s / %s").printf(elapsed, limit);
    }

    private bool can_record() {
        return !disposed && get_mapped() && recorder != null && ((!) recorder).state.is_busy();
    }

    private void on_duration_changed(string text) {
        if (!can_record()) return;
        timer_label.label = format_duration(text);
        update_action_sensitivity();
        ensure_blink();
    }

    private void on_level_changed(double level) {
        if (!can_record()) return;
        samples.add(double.max(0, double.min(1, level)));
        if (samples.size > MAX_SAMPLES) samples.remove_at(0);
        waveform.queue_draw();
        update_action_sensitivity();
        ensure_blink();
    }

    private void update_action_sensitivity() {
        bool available = !disposed && !action_pending && !action_dispatched;
        discard_button.sensitive = available;
        send_button.sensitive = available && recorder != null &&
            ((!) recorder).state == MediaMessageRecorderState.RECORDING;
    }

    internal void request_send() {
        if (!can_record() || ((!) recorder).state != MediaMessageRecorderState.RECORDING) return;
        request_action(true);
    }

    private void request_discard() {
        if (disposed || !get_mapped()) return;
        request_action(false);
    }

    private void request_action(bool send) {
        if (action_pending || action_dispatched) return;
        action_pending = true;
        update_action_sensitivity();
        // Dispatch after GTK has finished the current native pointer sequence.
        // Both actions remain single-shot on newer Windows GTK as well.
        action_dispatch_id = queue_action(this, send);
    }

    private static uint queue_action(VoiceRecorderPopover owner, bool send) {
        WeakRef weak_owner = WeakRef(owner);
        return Idle.add(() => {
            var popover = weak_owner.get() as VoiceRecorderPopover;
            if (popover == null) return Source.REMOVE;
            popover.action_dispatch_id = 0;
            popover.action_pending = false;
            if (popover.disposed || !popover.get_mapped()) return Source.REMOVE;
            if (send && (popover.recorder == null ||
                    ((!) popover.recorder).state != MediaMessageRecorderState.RECORDING)) {
                popover.update_action_sensitivity();
                return Source.REMOVE;
            }
            popover.action_dispatched = true;
            if (send) popover.send_clicked();
            else popover.cancel_clicked();
            return Source.REMOVE;
        });
    }

    private void cancel_pending_action() {
        if (action_dispatch_id != 0) {
            Source.remove(action_dispatch_id);
            action_dispatch_id = 0;
        }
        action_pending = false;
    }

    private void ensure_blink() {
        if (!can_record() || blink_id != 0 || !animations_enabled()) return;
        blink_id = add_blink(this);
    }

    private static bool animations_enabled() {
        Gtk.Settings? settings = Gtk.Settings.get_default();
        return settings == null || ((!) settings).gtk_enable_animations;
    }

    private static uint add_blink(VoiceRecorderPopover owner) {
        WeakRef weak_owner = WeakRef(owner);
        return Timeout.add(600, () => {
            var popover = weak_owner.get() as VoiceRecorderPopover;
            if (popover == null) return Source.REMOVE;
            if (!popover.can_record() || !animations_enabled()) {
                popover.blink_id = 0;
                popover.indicator_visible = true;
                popover.rec_indicator.queue_draw();
                return Source.REMOVE;
            }
            popover.indicator_visible = !popover.indicator_visible;
            popover.rec_indicator.queue_draw();
            return Source.CONTINUE;
        });
    }

    private void stop_blink() {
        if (blink_id != 0) {
            Source.remove(blink_id);
            blink_id = 0;
        }
        indicator_visible = true;
    }

    // Static helpers are required here: Vala instance-method lambda blocks
    // capture their owner strongly even when the body uses only a WeakRef.
    private static void attach_drawing_callbacks(VoiceRecorderPopover owner) {
        WeakRef weak_owner = WeakRef(owner);
        owner.rec_indicator.set_draw_func((area, cr, width, height) => {
            var popover = weak_owner.get() as VoiceRecorderPopover;
            if (popover == null || popover.disposed || !popover.indicator_visible) return;
            set_theme_color(area, cr);
            cr.arc(width / 2.0, height / 2.0, double.min(width, height) / 2.0 - 1, 0, 2 * Math.PI);
            cr.fill();
        });
        owner.waveform.set_draw_func((area, cr, width, height) => {
            var popover = weak_owner.get() as VoiceRecorderPopover;
            if (popover == null || popover.disposed) return;
            popover.draw_waveform(area, cr, width, height);
        });
    }

    private static void set_theme_color(DrawingArea area, Cairo.Context cr, double alpha = 1) {
#if GTK_4_12
        Gdk.RGBA color = area.get_color();
#else
        Gdk.RGBA color = area.get_style_context().get_color();
#endif
        cr.set_source_rgba(color.red, color.green, color.blue, color.alpha * alpha);
    }

    private void draw_waveform(DrawingArea area, Context cr, int width, int height) {
        double bar_width = (double) width / MAX_SAMPLES;
        double draw_width = double.max(1.5, double.min(3, bar_width - 1.5));
        bool rtl = area.get_direction() == TextDirection.RTL;
        for (int i = 0; i < samples.size; i++) {
            double bar_height = double.max(2, height * samples[i]);
            int visual_index = rtl ? MAX_SAMPLES - 1 - i : i;
            double x = visual_index * bar_width + (bar_width - draw_width) / 2;
            double y = (height - bar_height) / 2;
            double alpha = 0.55 + 0.45 * (double) i / MAX_SAMPLES;
            set_theme_color(area, cr, alpha);
            double radius = double.min(draw_width, bar_height) / 2;
            cr.new_sub_path();
            cr.arc(x + radius, y + radius, radius, Math.PI, 3 * Math.PI / 2);
            cr.arc(x + draw_width - radius, y + radius, radius, 3 * Math.PI / 2, 0);
            cr.arc(x + draw_width - radius, y + bar_height - radius, radius, 0, Math.PI / 2);
            cr.arc(x + radius, y + bar_height - radius, radius, Math.PI / 2, Math.PI);
            cr.close_path();
            cr.fill();
        }
    }

    public override void dispose() {
        disposed = true;
        on_hidden();
        if (recorder != null) {
            if (duration_handler_id != 0 && SignalHandler.is_connected(recorder, duration_handler_id)) recorder.disconnect(duration_handler_id);
            if (level_handler_id != 0 && SignalHandler.is_connected(recorder, level_handler_id)) recorder.disconnect(level_handler_id);
            if (max_duration_handler_id != 0 && SignalHandler.is_connected(recorder, max_duration_handler_id)) recorder.disconnect(max_duration_handler_id);
        }
        duration_handler_id = level_handler_id = max_duration_handler_id = 0;
        recorder = null;
        base.dispose();
    }
}

}
