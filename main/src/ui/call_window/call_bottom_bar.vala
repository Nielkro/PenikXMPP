using Dino.Entities;
using Gtk;
using Pango;

public class Dino.Ui.CallBottomBar : Gtk.Box {

    public signal void hang_up();
    public signal void dtmf_digit(char digit);
    public signal void add_participant();

    public bool audio_enabled { get; set; }
    public bool video_enabled { get; set; }

    public string counterpart_display_name { get; set; }

    private Button audio_button = new Button() { height_request=45, width_request=45, halign=Align.START, valign=Align.START };
    private Overlay audio_button_overlay = new Overlay();
    private Image audio_image = new Image() { pixel_size=22 };
    private MenuButton audio_settings_button = new MenuButton() { halign=Align.END, valign=Align.END };
    public AudioSettingsPopover? audio_settings_popover;

    private Button video_button = new Button() { height_request=45, width_request=45, halign=Align.START, valign=Align.START };
    private Overlay video_button_overlay = new Overlay();
    private Image video_image = new Image() { pixel_size=22 };
    private MenuButton video_settings_button = new MenuButton() { halign=Align.END, valign=Align.END };
    public VideoSettingsPopover? video_settings_popover;

    private MenuButton video_effects_button = new MenuButton() {
        height_request=45,
        width_request=45,
        halign=Align.START,
        valign=Align.START,
        visible=false,
        sensitive=false
    };
    public VideoEffectsPopover? video_effects_popover;
    private ulong video_effect_selected_handler_id = 0;
    private ulong background_image_handler_id = 0;
    private Adw.Bin video_effects_button_bin = new Adw.Bin() { valign=Align.START };

    private MenuButton dialpad_button = new MenuButton() { height_request=45, width_request=45, halign=Align.START, valign=Align.START };
    private Button participant_button = new Button() {
        height_request=45, width_request=45, halign=Align.START,
        valign=Align.START, sensitive=false
    };

    private Label label = new Label("") { halign=Align.CENTER, valign=Align.CENTER, wrap=true, wrap_mode=Pango.WrapMode.WORD_CHAR, hexpand=true };
    private Stack stack = new Stack();

    public CallBottomBar() {
        Object(orientation:Orientation.HORIZONTAL, spacing:0);

        Box main_buttons = new Box(Orientation.HORIZONTAL, 20) { margin_start=40, margin_end=40, margin_bottom=20, margin_top=20, halign=Align.CENTER, hexpand=true };

        audio_button.set_child(audio_image);
        audio_button.add_css_class("circular");
        audio_button.clicked.connect(() => { audio_enabled = !audio_enabled; });
        Adw.Bin audio_button_bin = new Adw.Bin();
        audio_button_bin.add_css_class("call-button");
        audio_button_bin.margin_end = audio_button_bin.margin_bottom = 5; // space for the small settings button
        audio_button_bin.set_child(audio_button);
        audio_button_overlay.set_child(audio_button_bin);
        audio_button_overlay.add_overlay(audio_settings_button);
        Util.menu_button_set_icon_with_size(audio_settings_button, "go-up-symbolic", 10);
        audio_settings_button.add_css_class("circular");
        audio_settings_button.add_css_class("call-button");
        audio_settings_button.add_css_class("call-mediadevice-settings-button");
        main_buttons.append(audio_button_overlay);

        video_button.set_child(video_image);
        video_button.add_css_class("circular");
        video_button.clicked.connect(() => { video_enabled = !video_enabled; });
        Adw.Bin video_button_bin = new Adw.Bin();
        video_button_bin.add_css_class("call-button");
        video_button_bin.margin_end = video_button_bin.margin_bottom = 5;
        video_button_bin.set_child(video_button);
        video_button_overlay.set_child(video_button_bin);
        video_button_overlay.add_overlay(video_settings_button);
        Util.menu_button_set_icon_with_size(video_settings_button, "go-up-symbolic", 10);
        video_settings_button.add_css_class("circular");
        video_settings_button.add_css_class("call-button");
        video_settings_button.add_css_class("call-mediadevice-settings-button");
        main_buttons.append(video_button_overlay);

        video_effects_button.set_child(new Image() { icon_name="applications-graphics-symbolic", pixel_size=22 });
        video_effects_button.add_css_class("circular");
        video_effects_button.add_css_class("white-button");
        video_effects_button.tooltip_text = _("Video effects");
        video_effects_button_bin.tooltip_text = _("Video effects");
        video_effects_button.update_property(AccessibleProperty.LABEL, _("Video effects"), -1);
        video_effects_button_bin.add_css_class("call-button");
        video_effects_button_bin.set_child(video_effects_button);
        main_buttons.append(video_effects_button_bin);

        // Dialpad (DTMF) button
        dialpad_button.set_child(new Image() { icon_name="input-dialpad-symbolic", pixel_size=22 });
        dialpad_button.add_css_class("circular");
        dialpad_button.add_css_class("white-button");
        var dialpad = new CallDialpad();
        dialpad.digit_pressed.connect((digit) => {
            dtmf_digit(digit);
        });
        Util.set_menu_button_popover(dialpad_button, dialpad);
        Adw.Bin dialpad_button_bin = new Adw.Bin() { valign=Align.START };
        dialpad_button_bin.add_css_class("call-button");
        dialpad_button_bin.set_child(dialpad_button);
        main_buttons.append(dialpad_button_bin);

        participant_button.set_child(new Image() {
            icon_name="contact-new-symbolic", pixel_size=22
        });
        participant_button.add_css_class("circular");
        participant_button.add_css_class("white-button");
        participant_button.tooltip_text = _("Add participant");
        participant_button.update_property(AccessibleProperty.LABEL,
            _("Add participant"), -1);
        participant_button.clicked.connect(() => add_participant());
        var participant_button_bin = new Adw.Bin() { valign=Align.START };
        participant_button_bin.add_css_class("call-button");
        participant_button_bin.set_child(participant_button);
        main_buttons.append(participant_button_bin);

        Button button_hang = new Button() { height_request=45, width_request=45, halign=Align.START, valign=Align.START };
        button_hang.set_child(new Image() { icon_name="dino-phone-hangup-symbolic", pixel_size=22 });
        button_hang.add_css_class("circular");
        button_hang.add_css_class("destructive-action");
        button_hang.clicked.connect(() => hang_up());
        Adw.Bin button_hang_bin = new Adw.Bin() { valign=Align.START };
        button_hang_bin.add_css_class("call-button");
        button_hang_bin.set_child(button_hang);
        main_buttons.append(button_hang_bin);

        label.add_css_class("text-no-controls");

        stack.add_named(main_buttons, "control-buttons");
        stack.add_named(label, "label");
        this.append(stack);

        this.notify["audio-enabled"].connect(on_audio_enabled_changed);
        this.notify["video-enabled"].connect(on_video_enabled_changed);

        audio_enabled = true;
        video_enabled = false;

        on_audio_enabled_changed();
        on_video_enabled_changed();

        this.add_css_class("call-bottom-bar");
    }

    public AudioSettingsPopover? show_audio_device_choices(bool show, Gee.List<Plugins.MediaDevice>? microphone_devices = null, Gee.List<Plugins.MediaDevice>? speaker_devices = null, bool show_digital_gain_controls = true) {
        audio_settings_button.visible = show;
        if (audio_settings_popover != null) audio_settings_popover.visible = false;
        if (!show) return null;

        audio_settings_popover = new AudioSettingsPopover(microphone_devices, speaker_devices, show_digital_gain_controls);
        Util.set_menu_button_popover(audio_settings_button, audio_settings_popover);
        audio_settings_popover.microphone_selected.connect(() => { audio_settings_button.popdown(); });
        audio_settings_popover.speaker_selected.connect(() => { audio_settings_button.popdown(); });

        return audio_settings_popover;
    }

    public bool audio_device_choices_visible {
        get { return audio_settings_button.visible; }
    }

    public void show_audio_device_error() {
        audio_settings_button.set_icon_name("dialog-warning-symbolic");
        Util.force_error_color(audio_settings_button);
    }

    public VideoSettingsPopover? show_video_device_choices(bool show, Gee.List<Plugins.MediaDevice>? camera_devices = null) {
        video_settings_button.visible = show;
        if (video_settings_popover != null) video_settings_popover.visible = false;
        if (!show) return null;

        video_settings_popover = new VideoSettingsPopover(camera_devices);
        Util.set_menu_button_popover(video_settings_button, video_settings_popover);
        video_settings_popover.camera_selected.connect(() => { video_settings_button.popdown(); });

        return video_settings_popover;
    }

    public void show_video_controls(bool show) {
        video_button_overlay.visible = show;
        if (!show) {
            video_settings_button.popdown();
            if (video_settings_popover != null) video_settings_popover.visible = false;
            show_video_effect_choices(false);
        }
    }

    public bool video_controls_visible {
        get { return video_button_overlay.visible; }
    }

    public void show_video_device_error() {
        video_settings_button.set_icon_name("dialog-warning-symbolic");
        Util.force_error_color(video_settings_button);
    }

    public VideoEffectsPopover? show_video_effect_choices(
            bool show,
            Plugins.JmiVideoEffectCapabilities? capabilities = null,
            Plugins.JmiVideoEffectStatus? status = null,
            string? unavailable_hint = null) {
        video_effects_button.visible = show;
        if (!show) {
            video_effects_button.popdown();
            return video_effects_popover;
        }

        if (video_effects_popover == null) {
            video_effects_popover = new VideoEffectsPopover();
            Util.set_menu_button_popover(video_effects_button, video_effects_popover);
            background_image_handler_id = ((!) video_effects_popover).background_image_requested.connect((choice, generation) => {
                video_background_requested(choice, generation);
            });
            video_effect_selected_handler_id = ((!) video_effects_popover).effect_selected.connect((selection) => {
                video_effect_selected(selection);
            });
        }

        if (capabilities != null && status != null) {
            ((!) video_effects_popover).update_state(
                (!) capabilities, (!) status, unavailable_hint);
            bool selectable = ((!) capabilities).available &&
                (((!) capabilities).grayscale_supported ||
                    ((!) capabilities).warm_tone_supported ||
                    ((!) capabilities).cold_tone_supported ||
                    ((!) capabilities).sepia_supported ||
                    ((!) capabilities).additional_effect_mask != 0 ||
                    ((!) capabilities).supported_adjustment_mask != 0 ||
                    (((!) capabilities).supported_background_mask & ~1U) != 0 ||
                    ((!) capabilities).auto_framing_supported);
            // Keep the control keyboard-focusable even when unavailable so
            // its concrete explanation can be opened. Individual choices in
            // the popover remain insensitive and cannot emit a request.
            video_effects_button.sensitive = true;
            string description = selectable
                ? _("Video effects")
                : (unavailable_hint ?? _("Video effects are not available."));
            video_effects_button.tooltip_text = description;
            video_effects_button_bin.tooltip_text = description;
            video_effects_button.update_property(AccessibleProperty.DESCRIPTION, description, -1);
        } else {
            video_effects_button.sensitive = false;
        }

        return video_effects_popover;
    }

    public signal void video_background_requested(uint builtin_choice, uint64 generation);
    public signal void video_effect_selected(Plugins.JmiVideoEffectSelection selection);

    public bool video_effects_control_visible {
        get { return video_effects_button.visible; }
    }

    public bool video_effects_control_sensitive {
        get { return video_effects_button.sensitive; }
    }

    public string? video_effects_icon_name {
        owned get {
            Image? image = video_effects_button.child as Image?;
            return image != null ? ((!) image).icon_name : null;
        }
    }

    public void show_dialpad(bool show) {
        dialpad_button.visible = show;
        if (!show) dialpad_button.popdown();
    }

    public bool dialpad_visible {
        get { return dialpad_button.visible; }
    }

    public void update_participant_invite(bool available, string explanation) {
        participant_button.sensitive = available;
        participant_button.tooltip_text = explanation;
        participant_button.update_property(AccessibleProperty.DESCRIPTION,
            explanation, -1);
    }

    public void on_audio_enabled_changed() {
        if (audio_enabled) {
            audio_image.icon_name = "audio-input-microphone-symbolic";
            audio_button.add_css_class("white-button");
            audio_button.remove_css_class("transparent-white-button");
        } else {
            audio_image.icon_name = "microphone-disabled-symbolic";
            audio_button.remove_css_class("white-button");
            audio_button.add_css_class("transparent-white-button");
        }
    }

    public void on_video_enabled_changed() {
        if (video_enabled) {
            video_image.icon_name = "dino-video-symbolic";
            video_button.add_css_class("white-button");
            video_button.remove_css_class("transparent-white-button");

        } else {
            video_image.icon_name = "dino-video-off-symbolic";
            video_button.remove_css_class("white-button");
            video_button.add_css_class("transparent-white-button");
        }
    }

    public void show_counterpart_ended(string text) {
        stack.set_visible_child_name("label");
        label.label = Util.unbreak_space_around_non_spacing_mark(text);
    }

    /**
     * Let child widgets release transient resources before the call window is
     * torn down. The dialpad itself is media-backend free.
     */
    public void shutdown() {
        participant_button.sensitive = false;
        var dp = dialpad_button.popover as CallDialpad;
        if (dp != null) dp.shutdown();
        // Clear focus before hiding and unparenting the outgoing popover.
        // GTK 4.14 otherwise queues its focused descendant twice and can
        // retain it after the call window's native surface is destroyed.
        if (video_effects_popover != null) Util.clear_focus_before_detach((!) video_effects_popover);
        audio_settings_button.popdown();
        video_settings_button.popdown();
        video_effects_button.popdown();
        dialpad_button.popdown();
        if (video_effects_popover != null && video_effect_selected_handler_id != 0 &&
                SignalHandler.is_connected((!) video_effects_popover, video_effect_selected_handler_id)) {
            ((!) video_effects_popover).disconnect(video_effect_selected_handler_id);
        }
        if (video_effects_popover != null && background_image_handler_id != 0 &&
                SignalHandler.is_connected((!) video_effects_popover, background_image_handler_id))
            ((!) video_effects_popover).disconnect(background_image_handler_id);
        background_image_handler_id = 0;
        video_effect_selected_handler_id = 0;
        audio_settings_button.set_popover(null);
        video_settings_button.set_popover(null);
        video_effects_button.set_popover(null);
        dialpad_button.set_popover(null);
        video_effects_popover = null;
        video_effects_button.sensitive = false;
        video_effects_button.visible = false;
    }

    public bool is_menu_active() {
        return (video_settings_button.popover != null && video_settings_button.popover.visible) ||
                (audio_settings_button.popover != null && audio_settings_button.popover.visible) ||
                (video_effects_button.popover != null && video_effects_button.popover.visible) ||
                (dialpad_button.popover != null && dialpad_button.popover.visible);
    }
}
