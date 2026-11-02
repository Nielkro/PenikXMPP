using Gee;
using Gtk;

namespace Dino.Ui.Test {

class CallBottomBarRuntimeTest : Gee.TestCase {

    private class RuntimeDevice : Object, Dino.Plugins.MediaDevice {
        private string device_id;
        private string device_display_name;
        private string? device_detail_name;
        private bool device_incoming;

        public string id { owned get { return device_id; } }
        public string display_name { owned get { return device_display_name; } }
        public string? detail_name { owned get { return device_detail_name; } }
        public string? media { owned get { return "audio"; } }
        public bool incoming { get { return device_incoming; } }

        public RuntimeDevice(string id, string display_name, string? detail_name, bool incoming) {
            device_id = id;
            device_display_name = display_name;
            device_detail_name = detail_name;
            device_incoming = incoming;
        }
    }

    public CallBottomBarRuntimeTest() {
        base("CallBottomBarRuntime");

        add_test("GoogleWebrtc_audio_only_controls_hide_video_and_show_dtmf", test_google_webrtc_audio_only_controls_hide_video_and_show_dtmf);
        add_test("GoogleWebrtc_audio_device_popover_uses_injected_devices", test_google_webrtc_audio_device_popover_uses_injected_devices);
        add_test("GoogleWebrtc_video_effects_are_opt_in_and_teardown_safe", test_google_webrtc_video_effects_are_opt_in_and_teardown_safe);
        add_test("extended_video_controls_keep_latest_full_selection", test_extended_video_controls_keep_latest_full_selection);
        add_test("face_scene_controls_keep_full_call_selection", test_face_scene_controls_keep_full_call_selection);
        add_test("background_image_results_are_call_choice_fenced", test_background_image_results_are_call_choice_fenced);
        add_test("background_static_image_decode_is_bounded", test_background_static_image_decode_is_bounded);
        add_test("background_png_rejects_animation_chunks", test_background_png_rejects_animation_chunks);
        add_test("background_png_rejects_malformed_chunk_bounds", test_background_png_rejects_malformed_chunk_bounds);
        add_test("background_static_png_and_jpeg_compatibility", test_background_static_png_and_jpeg_compatibility);
        add_test("additional_presets_keep_adjustments_and_respect_capabilities", test_additional_presets_keep_adjustments_and_respect_capabilities);
        add_test("video_controls_release_after_hangup", test_video_controls_release_after_hangup);
    }

    private void test_google_webrtc_audio_only_controls_hide_video_and_show_dtmf() {
        var window = new Window();
        var bottom_bar = new CallBottomBar();
        window.set_child(bottom_bar);
        window.present();
        drain_main_context();

        bottom_bar.show_video_device_choices(false);
        bottom_bar.show_video_controls(false);
        bottom_bar.show_dialpad(true);
        drain_main_context();

        fail_if(bottom_bar.video_controls_visible,
            "Google/libwebrtc audio-only calls must not expose a video control");
        fail_if_not(bottom_bar.dialpad_visible,
            "Google/libwebrtc audio-only calls must expose the libwebrtc DTMF dialpad");
        fail_if(bottom_bar.is_menu_active(),
            "configuring libwebrtc controls must leave their popovers closed");

        bottom_bar.shutdown();
        window.set_child(null);
        window.destroy();
        drain_main_context();
    }

    private void test_google_webrtc_audio_device_popover_uses_injected_devices() {
        var window = new Window();
        var bottom_bar = new CallBottomBar();
        var microphones = new ArrayList<Dino.Plugins.MediaDevice>();
        var speakers = new ArrayList<Dino.Plugins.MediaDevice>();
        microphones.add(new RuntimeDevice("libwebrtc-mic", "Runtime libwebrtc microphone", "capture-guid", false));
        speakers.add(new RuntimeDevice("libwebrtc-speaker", "Runtime libwebrtc speaker", "playout-guid", true));

        window.set_child(bottom_bar);
        window.present();
        drain_main_context();

        AudioSettingsPopover? popover = bottom_bar.show_audio_device_choices(true, microphones, speakers, false);
        drain_main_context();

        fail_if(popover == null, "injected libwebrtc device popover must be created");
        fail_if(!bottom_bar.audio_device_choices_visible,
            "libwebrtc audio-only calls must keep the audio device chooser visible");
        fail_if_not(widget_tree_contains_label((!) popover, "Runtime libwebrtc microphone"),
            "audio popover must render injected libwebrtc microphone devices without consulting VideoCallPlugin");
        fail_if_not(widget_tree_contains_label((!) popover, "Runtime libwebrtc speaker"),
            "audio popover must render injected libwebrtc speaker devices without consulting VideoCallPlugin");
        fail_if(widget_tree_contains_label((!) popover, "WebRTC Gain:"),
            "libwebrtc device popover must not expose the old RTP/GStreamer digital gain control");

        ((!) popover).popup();
        drain_main_context();
        fail_if_not(bottom_bar.is_menu_active(),
            "an open libwebrtc device popover must be reported as active");

        bottom_bar.shutdown();
        drain_main_context();
        fail_if(bottom_bar.is_menu_active(),
            "shutdown must close and detach active media popovers before widget teardown");
        window.set_child(null);
        window.destroy();
        drain_main_context();
    }

    private void test_google_webrtc_video_effects_are_opt_in_and_teardown_safe() {
        var window = new Window();
        var bottom_bar = new CallBottomBar();
        var capabilities = new Dino.Plugins.JmiVideoEffectCapabilities(true, true, true);
        var off_status = new Dino.Plugins.JmiVideoEffectStatus(
            new Dino.Plugins.JmiVideoEffectSelection(Dino.Plugins.JmiVideoEffectKind.OFF),
            Dino.Plugins.JmiVideoEffectApplyState.IDLE,
            0,
            0);
        int selection_count = 0;
        Dino.Plugins.JmiVideoEffectKind selected_kind = Dino.Plugins.JmiVideoEffectKind.OFF;
        bottom_bar.video_effect_selected.connect((selection) => {
            selection_count++;
            selected_kind = selection.kind;
        });

        window.set_child(bottom_bar);
        window.present();
        drain_main_context();

        VideoEffectsPopover? popover = bottom_bar.show_video_effect_choices(
            true, capabilities, off_status);
        drain_main_context();
        fail_if(popover == null, "video effects popover must be created for a capable libwebrtc call");
        fail_if_not(bottom_bar.video_effects_control_visible,
            "video effects control must be visible for a capable libwebrtc video call");
        fail_if_not(bottom_bar.video_effects_control_sensitive,
            "video effects control must be selectable when grayscale is advertised");
        fail_if(bottom_bar.video_effects_icon_name != "applications-graphics-symbolic",
            "video effects control must use the available graphics effects icon");
        fail_if(((!) popover).current_effect != Dino.Plugins.JmiVideoEffectKind.OFF,
            "every new effects popover must start with effects off");
        fail_if_not(widget_tree_contains_label((!) popover, "Video effects"),
            "effects popover must have an accessible visible heading");
        fail_if_not(widget_tree_contains_label((!) popover, "Grayscale"),
            "effects popover must show the worker-advertised grayscale choice");
        fail_if_not(widget_tree_contains_label((!) popover, "Warm tone"),
            "effects popover must show the worker-advertised warm-tone choice");

        ((!) popover).popup();
        drain_main_context();
        fail_if(selection_count != 0,
            "opening the effects popover must never activate an effect");
        fail_if_not(bottom_bar.is_menu_active(),
            "an open effects popover must keep call controls visible");

        CheckButton? grayscale = find_check_button((!) popover, "Grayscale");
        fail_if(grayscale == null, "grayscale choice must be keyboard-selectable");
        ((!) grayscale).active = true;
        drain_main_context();
        fail_if(selection_count != 1 || selected_kind != Dino.Plugins.JmiVideoEffectKind.GRAYSCALE,
            "only an explicit grayscale selection may request the effect");

        CheckButton? warm_tone = find_check_button((!) popover, "Warm tone");
        fail_if(warm_tone == null, "warm-tone choice must be keyboard-selectable");
        ((!) warm_tone).active = true;
        drain_main_context();
        fail_if(selection_count != 2 || selected_kind != Dino.Plugins.JmiVideoEffectKind.WARM_TONE,
            "only an explicit warm-tone selection may request the effect");

        ((!) popover).reset_button.clicked();
        drain_main_context();
        fail_if(selection_count != 3 || selected_kind != Dino.Plugins.JmiVideoEffectKind.OFF,
            "explicit Gray-to-Warm-to-Off switching must preserve the selected effect order");
        // Acknowledge the requested reset before injecting a later backend state.
        bottom_bar.show_video_effect_choices(true, capabilities, off_status);

        var active_status = new Dino.Plugins.JmiVideoEffectStatus(
            new Dino.Plugins.JmiVideoEffectSelection(Dino.Plugins.JmiVideoEffectKind.WARM_TONE),
            Dino.Plugins.JmiVideoEffectApplyState.APPLIED,
            2,
            2);
        bottom_bar.show_video_effect_choices(true, capabilities, active_status);
        drain_main_context();
        fail_if(((!) popover).current_effect != Dino.Plugins.JmiVideoEffectKind.WARM_TONE ||
                !((!) warm_tone).active,
            "an applied warm-tone backend state must select the matching UI choice");
        fail_if_not(widget_tree_contains_label((!) popover, "Active"),
            "applied effect state must be visible in the popover");
        fail_if(selection_count != 3,
            "backend status updates must not implicitly activate an effect");

        var grayscale_only_capabilities =
            new Dino.Plugins.JmiVideoEffectCapabilities(true, true, false);
        bottom_bar.show_video_effect_choices(
            true, grayscale_only_capabilities, off_status);
        drain_main_context();
        fail_if(((!) warm_tone).visible || ((!) warm_tone).sensitive,
            "a worker-unsupported warm-tone choice must stay hidden and inert");
        fail_if(selection_count != 3,
            "capability changes must not implicitly activate an effect");

        var warm_only_capabilities =
            new Dino.Plugins.JmiVideoEffectCapabilities(true, false, true);
        bottom_bar.show_video_effect_choices(
            true, warm_only_capabilities, off_status);
        drain_main_context();
        fail_if(!bottom_bar.video_effects_control_sensitive ||
                ((!) grayscale).visible || ((!) grayscale).sensitive ||
                !((!) warm_tone).visible || !((!) warm_tone).sensitive,
            "a warm-only capability must expose only the selectable warm-tone choice");
        fail_if(selection_count != 3,
            "a warm-only capability update must not implicitly activate its effect");

        var group_capabilities = Dino.Plugins.JmiVideoEffectCapabilities.unavailable(
            Dino.Plugins.JmiVideoEffectUnavailableReason.GROUP_CALL);
        var group_status = new Dino.Plugins.JmiVideoEffectStatus(
            new Dino.Plugins.JmiVideoEffectSelection(Dino.Plugins.JmiVideoEffectKind.OFF),
            Dino.Plugins.JmiVideoEffectApplyState.UNAVAILABLE,
            0,
            0,
            Dino.Plugins.JmiVideoEffectUnavailableReason.GROUP_CALL);
        bottom_bar.show_video_effect_choices(
            true, group_capabilities, group_status,
            _("Video effects are not available in group calls."));
        drain_main_context();
        fail_if_not(bottom_bar.video_effects_control_visible,
            "MUJI must keep the effects control visible as an availability hint");
        fail_if_not(bottom_bar.video_effects_control_sensitive,
            "MUJI effects explanation must remain keyboard-focusable");
        fail_if_not(widget_tree_contains_label(
                (!) popover, "Video effects are not available in group calls."),
            "MUJI popover must expose the concrete unavailable explanation");
        CheckButton? group_off = find_check_button((!) popover, "Original");
        CheckButton? group_grayscale = find_check_button((!) popover, "Grayscale");
        CheckButton? group_warm_tone = find_check_button((!) popover, "Warm tone");
        fail_if(group_off == null || group_grayscale == null || group_warm_tone == null ||
                !((!) group_off).visible || !((!) group_grayscale).visible ||
                !((!) group_warm_tone).visible,
            "MUJI popover must keep all effect choices visible for context");
        fail_if(((!) group_off).sensitive || ((!) group_grayscale).sensitive ||
                ((!) group_warm_tone).sensitive,
            "MUJI popover choices must remain inert even though its explanation opens");
        fail_if(selection_count != 3,
            "capability and group-call status updates must not activate an effect");

        ((!) popover).popup();
        drain_main_context();
        bottom_bar.shutdown();
        drain_main_context();
        fail_if(bottom_bar.is_menu_active(),
            "shutdown must close and detach the effects popover before widget teardown");
        fail_if(bottom_bar.video_effects_popover != null,
            "shutdown must release the effects popover and its signal closure");
        fail_if(bottom_bar.video_effects_control_visible || bottom_bar.video_effects_control_sensitive,
            "shutdown must make the detached effects button inert");
        window.set_child(null);
        window.destroy();
        drain_main_context();
    }

    private void test_extended_video_controls_keep_latest_full_selection() {
        var window = new Window();
        var bottom_bar = new CallBottomBar();
        var capabilities = new Plugins.JmiVideoEffectCapabilities(true, true, true,
            Plugins.JmiVideoEffectUnavailableReason.NONE, true, true, 15);
        var neutral = new Plugins.JmiVideoEffectSelection(Plugins.JmiVideoEffectKind.OFF);
        var idle = new Plugins.JmiVideoEffectStatus(neutral, Plugins.JmiVideoEffectApplyState.IDLE, 0, 0);
        var requests = new Gee.ArrayList<Plugins.JmiVideoEffectSelection>();
        bottom_bar.video_effect_selected.connect((selection) => { requests.add(selection); });
        window.set_child(bottom_bar);
        window.present();
        VideoEffectsPopover? maybe_popover = bottom_bar.show_video_effect_choices(true, capabilities, idle);
        fail_if(maybe_popover == null, "extended controls need a capable popover");
        VideoEffectsPopover popover = (!) maybe_popover;
        var scales = new Gee.ArrayList<Scale>();
        collect_scales(popover, scales);
        fail_if(scales.size != 5, "brightness, contrast, saturation and sharpness must be separate controls");
        popover.popup();
        drain_main_context();
        fail_if(requests.size != 0, "opening extended controls must preserve neutral capture");
        scales[0].set_value(20);
        drain_main_context();
        fail_if(requests.size != 1 || requests[0].brightness != 20 || requests[0].is_neutral(),
            "Original with brightness must request an active full configuration");
        fail_if_not(bottom_bar.is_menu_active(), "moving a slider must leave the controls open");
        popover.update_state(capabilities, idle);
        fail_if(scales[0].get_value() != 20, "an old neutral acknowledgement must not move a live slider back");
        CheckButton? cold = find_check_button(popover, "Cold tone");
        CheckButton? sepia = find_check_button(popover, "Sepia");
        fail_if(cold == null || sepia == null, "supported cold tone and sepia must be selectable");
        ((!) cold).active = true;
        fail_if(requests[requests.size - 1].brightness != 20 ||
            requests[requests.size - 1].kind != Plugins.JmiVideoEffectKind.COLD_TONE,
            "changing the colour preset must preserve the full slider configuration");
        ((!) sepia).active = true;
        scales[1].set_value(-15);
        scales[2].set_value(-30);
        scales[3].set_value(40);
        Plugins.JmiVideoEffectSelection latest = requests[requests.size - 1];
        fail_if(latest.kind != Plugins.JmiVideoEffectKind.SEPIA || latest.brightness != 20 ||
            latest.contrast != -15 || latest.saturation != -30 || latest.sharpness != 40,
            "each revision must include the entire live configuration");
        popover.update_state(capabilities, new Plugins.JmiVideoEffectStatus(requests[0],
            Plugins.JmiVideoEffectApplyState.APPLIED, 1, 1));
        fail_if(scales[3].get_value() != 40 || !((!) sepia).active,
            "an older applied revision must not replace the user's latest choices");
        popover.update_state(capabilities, new Plugins.JmiVideoEffectStatus(requests[0],
            Plugins.JmiVideoEffectApplyState.FAILED, 1, 0,
            Plugins.JmiVideoEffectUnavailableReason.BACKEND_FAILURE));
        fail_if(scales[3].get_value() != 40 || scales[1].get_value() != -15 || !((!) sepia).active,
            "a failure of the older in-flight configuration must not undo a newer pending choice");
        fail_if_not(widget_tree_contains_label(popover, "Applying…"),
            "the newer pending choice must keep its applying status after an older failure");
        popover.update_state(capabilities, new Plugins.JmiVideoEffectStatus(requests[0],
            Plugins.JmiVideoEffectApplyState.DEGRADED, 1, 1,
            Plugins.JmiVideoEffectUnavailableReason.BACKEND_FAILURE));
        fail_if(scales[3].get_value() != 40 || !((!) sepia).active,
            "degradation of an older configuration must not move the newest controls");
        int request_count = requests.size;
        popover.update_state(capabilities, new Plugins.JmiVideoEffectStatus(latest,
            Plugins.JmiVideoEffectApplyState.APPLIED, 6, 6));
        fail_if(requests.size != request_count, "matching state synchronization must never emit a control request");
        CheckButton? original = find_check_button(popover, "Original");
        fail_if(original == null, "Original must remove only the colour preset");
        ((!) original).active = true;
        fail_if(requests[requests.size - 1].is_neutral() || requests[requests.size - 1].sharpness != 40,
            "Original must preserve other explicitly chosen adjustments");
        popover.reset_button.clicked();
        fail_if_not(requests[requests.size - 1].matches(neutral), "Off must reset every configuration field");
        foreach (Scale scale in scales) fail_if(scale.get_value() != 0, "Off must visibly reset every slider");
        bottom_bar.shutdown();
        window.set_child(null);
        window.destroy();
        drain_main_context();
    }

    private void collect_scales(Widget widget, Gee.ArrayList<Scale> scales) {
        Scale? scale = widget as Scale?;
        if (scale != null) scales.add((!) scale);
        Widget? child = widget.get_first_child();
        while (child != null) {
            collect_scales((!) child, scales);
            child = ((!) child).get_next_sibling();
        }
    }

    private void collect_choices(Widget widget, Gee.ArrayList<DropDown> choices) {
        DropDown? choice = widget as DropDown?;
        if (choice != null) choices.add((!) choice);
        Widget? child = widget.get_first_child();
        while (child != null) {
            collect_choices((!) child, choices);
            child = ((!) child).get_next_sibling();
        }
    }

    private void test_face_scene_controls_keep_full_call_selection() {
        var window = new Window();
        var bottom_bar = new CallBottomBar();
        var capabilities = new Plugins.JmiVideoEffectCapabilities(true, true, true,
            Plugins.JmiVideoEffectUnavailableReason.NONE, true, true, 15, 1, false,
            8160, 15, 15, 15, 7, 31, true, true);
        var neutral = new Plugins.JmiVideoEffectSelection(Plugins.JmiVideoEffectKind.OFF);
        var idle = new Plugins.JmiVideoEffectStatus(neutral, Plugins.JmiVideoEffectApplyState.IDLE, 0, 0);
        var requests = new Gee.ArrayList<Plugins.JmiVideoEffectSelection>();
        bottom_bar.video_effect_selected.connect((value) => { requests.add(value); });
        window.set_child(bottom_bar);
        window.present();
        VideoEffectsPopover? maybe_popover = bottom_bar.show_video_effect_choices(true, capabilities, idle);
        fail_if(maybe_popover == null, "face controls require a capable video popover");
        VideoEffectsPopover popover = (!) maybe_popover;
        var choices = new Gee.ArrayList<DropDown>();
        collect_choices(popover, choices);
        fail_if(choices.size != 7, "independent glasses, hat, beard, accessory and scene menus");
        fail_if(requests.size != 0, "opening accessory controls may not enable any effect");
        foreach (DropDown choice in choices.slice(2, 7)) fail_if(!choice.sensitive,
            "complete capability masks must enable the corresponding menu");
        choices[2].selected = 1;
        choices[3].selected = 2;
        choices[4].selected = 3;
        choices[5].selected = 2;
        choices[6].selected = 4;
        CheckButton? touch_up = find_check_button(popover, "Gentle touch-up");
        CheckButton? low_light = find_check_button(popover, "Low-light enhancement");
        fail_if(touch_up == null || low_light == null, "both optional image controls must exist");
        ((!) touch_up).active = true;
        ((!) low_light).active = true;
        Plugins.JmiVideoEffectSelection latest = requests[requests.size - 1];
        fail_if(latest.glasses_style != Plugins.JmiVideoGlassesStyle.SUNGLASSES ||
            latest.hat_style != Plugins.JmiVideoHatStyle.COWBOY ||
            latest.beard_style != Plugins.JmiVideoBeardStyle.FULL ||
            latest.face_accessory != Plugins.JmiVideoFaceAccessory.KARAOKE_MICROPHONE ||
            latest.scene_effect != Plugins.JmiVideoSceneEffect.FOOTBALL ||
            !latest.touch_up || !latest.low_light || latest.is_neutral(),
            "a selection must include every independent optional field");
        fail_if_not(capabilities.supports_selection(latest), "capabilities must cover the complete selection");
        popover.update_state(capabilities, idle);
        fail_if(choices[2].selected != 1 || choices[6].selected != 4 || !((!) touch_up).active,
            "an old acknowledgement must preserve the latest accessory selection");
        CheckButton? cold = find_check_button(popover, "Cold tone");
        fail_if(cold == null, "color preset control required");
        ((!) cold).active = true;
        latest = requests[requests.size - 1];
        fail_if(latest.glasses_style != Plugins.JmiVideoGlassesStyle.SUNGLASSES ||
            latest.scene_effect != Plugins.JmiVideoSceneEffect.FOOTBALL || !latest.touch_up,
            "color changes must retain accessories and animations");
        bottom_bar.show_video_effect_choices(true,
            new Plugins.JmiVideoEffectCapabilities(true, true, true),
            new Plugins.JmiVideoEffectStatus(latest, Plugins.JmiVideoEffectApplyState.DEGRADED, 1, 1));
        fail_if(choices[2].sensitive || choices[6].sensitive || ((!) touch_up).sensitive,
            "unavailable accessories must remain visible but cannot be selected");
        bottom_bar.show_video_effect_choices(true, capabilities,
            new Plugins.JmiVideoEffectStatus(latest, Plugins.JmiVideoEffectApplyState.APPLIED, 2, 2));
        choices[2].grab_focus();
        bottom_bar.shutdown();
        window.set_child(null);
        window.destroy();
        drain_main_context();
    }

    private void test_background_image_results_are_call_choice_fenced() {
        var window = new Window();
        var bar = new CallBottomBar();
        var capabilities = new Plugins.JmiVideoEffectCapabilities(true, true, true,
            Plugins.JmiVideoEffectUnavailableReason.NONE, true, true, 15, 15, true,
            8160, 15, 15, 15, 7, 31, true, true);
        var neutral = new Plugins.JmiVideoEffectSelection(Plugins.JmiVideoEffectKind.OFF);
        var requests = new Gee.ArrayList<Plugins.JmiVideoEffectSelection>();
        bar.video_effect_selected.connect((value) => { requests.add(value); });
        uint builtin = 0; uint64 token = 0; uint image_requests = 0;
        bar.video_background_requested.connect((choice, generation) => {
            builtin = choice; token = generation; image_requests++;
        });
        window.set_child(bar); window.present();
        VideoEffectsPopover popover = (!) bar.show_video_effect_choices(true, capabilities,
            new Plugins.JmiVideoEffectStatus(neutral, Plugins.JmiVideoEffectApplyState.IDLE, 0, 0));
        var choices = new Gee.ArrayList<DropDown>(); collect_choices(popover, choices);
        fail_if(choices.size != 7, "The real video popover must contain its background selector");
        StringList? backgrounds = choices[0].model as StringList;
        fail_if(backgrounds == null || ((!) backgrounds).get_n_items() == 0,
            "The background selector must use its populated image-choice model");
        uint manual_index = ((!) backgrounds).get_n_items() - 1;
        fail_if(((!) backgrounds).get_string(manual_index) != _("Choose image…"),
            "The final background choice must expose manual image selection");
        Widget? background_row = choices[0].get_parent();
        popover.popup(); drain_main_context();
        fail_if(!popover.get_mapped() || !popover.is_sensitive() || background_row == null ||
            !((!) background_row).visible || !((!) background_row).is_sensitive() || !choices[0].is_sensitive(),
            "Image-capable backend controls must show an active background row in the mapped popover");
        fail_if(requests.size != 0 || image_requests != 0 || popover.has_pending_background_image,
            "Opening the background controls must not request or stage any image");
        choices[0].selected = manual_index;
        fail_if(image_requests != 1 || builtin != 0 || token == 0 || !popover.accepts_background_result(token),
            "Selecting Choose image must issue a manual image request with its own valid generation");
        fail_if(requests.size != 1 || requests[0].background_mode != Plugins.JmiVideoBackgroundMode.SOLID ||
            requests[0].asset_id != 0,
            "The manual chooser must conceal the background while awaiting explicitly chosen pixels");
        choices[0].selected = 3;
        fail_if(builtin != 1 || token == 0 || !popover.accepts_background_result(token),
            "An illustration load belongs to its exact user choice");
        Plugins.JmiVideoEffectSelection fallback = requests[requests.size - 1];
        fail_if(fallback.background_mode != Plugins.JmiVideoBackgroundMode.SOLID || fallback.background_color_rgb != 0x303030,
            "An image that is still loading must select opaque concealment");
        uint64 old_token = token;
        choices[3].selected = 2;
        CheckButton? framing = find_check_button(popover, "Automatic framing");
        fail_if(framing == null, "Framing must be independently selectable");
        ((!) framing).active = true;
        popover.finish_background_image(token, 17);
        Plugins.JmiVideoEffectSelection applied = requests[requests.size - 1];
        fail_if(applied.background_mode != Plugins.JmiVideoBackgroundMode.IMAGE || applied.asset_id != 17 ||
            applied.hat_style != Plugins.JmiVideoHatStyle.COWBOY || applied.framing_mode != Plugins.JmiVideoFramingMode.AUTO,
            "An image completion must preserve more recent independent controls");
        choices[0].selected = 4;
        int count = requests.size;
        popover.finish_background_image(old_token, 999);
        fail_if(requests.size != count, "A superseded image may not overwrite a newer choice");
        popover.fail_background_image(token);
        fail_if(requests[requests.size - 1].background_mode != Plugins.JmiVideoBackgroundMode.SOLID,
            "A failed image must retain the chosen concealment");
        choices[0].selected = 5;
        uint64 last_token = token;
        popover.reset_button.clicked(); count = requests.size;
        popover.finish_background_image(last_token, 1000);
        fail_if(requests.size != count || !requests[requests.size - 1].is_neutral(),
            "Off invalidates pending images and every other effect");
        bar.shutdown(); window.set_child(null); window.destroy(); drain_main_context();
    }

    private void test_background_static_image_decode_is_bounded() {
        string directory;
        try { directory = DirUtils.make_tmp("dinox-background-image-XXXXXX"); }
        catch (Error e) { fail_if(true, "Could not create a private image fixture: " + e.message); return; }
        File image_file = File.new_for_path(Path.build_filename(directory, "test.png"));
        try {
            var source = new Gdk.Pixbuf(Gdk.Colorspace.RGB, true, 8, 3000, 500);
            source.fill(0x5599cc80);
            source.save((!) image_file.get_path(), "png");
            Plugins.JmiVideoBackgroundImage decoded = VideoBackgroundImageLoader.decode(image_file);
            Plugins.JmiVideoBackgroundImage? asynchronous = null;
            Error? asynchronous_error = null;
            var decode_loop = new MainLoop();
            VideoBackgroundImageLoader.load.begin(image_file, null, (source_object, result) => {
                try { asynchronous = VideoBackgroundImageLoader.load.end(result); }
                catch (Error e) { asynchronous_error = e; }
                decode_loop.quit();
            });
            decode_loop.run();
            fail_if(asynchronous_error != null || asynchronous == null || ((!) asynchronous).width != 1920,
                "The image decoder must also complete off the UI thread");
            fail_if(decoded.width != 1920 || decoded.height != 320 || !decoded.rgba ||
                decoded.pixels.get_size() > 8388608,
                "Static image decode must preserve aspect ratio and enforce decoded bounds");
            FileUtils.set_contents((!) image_file.get_path(), "not a PNG or JPEG");
            bool rejected = false;
            try { VideoBackgroundImageLoader.decode(image_file); } catch (Error e) { rejected = true; }
            fail_if(!rejected, "An unsupported file must not reach an unrestricted image decoder");
            rejected = false;
            try { new Plugins.JmiVideoBackgroundImage(1921, 1, 7684, true, new Bytes(new uint8[7684])); }
            catch (IOError e) { rejected = true; }
            fail_if(!rejected, "Decoded image dimensions are checked at the backend-neutral boundary");
        } catch (Error e) { fail_if(true, "Bounded static PNG fixture failed: " + e.message); }
        try { image_file.delete(); } catch (Error ignored) { }
        DirUtils.remove(directory);
    }

    // Small CRC-valid image fixtures; no external fixture files or image encoders are needed.
    private const string BACKGROUND_STATIC_PNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=";
    private const string BACKGROUND_METADATA_PNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAMXRFWHREZXNjcmlwdGlvbgBhY1RMIGZjVEwgZmRBVCBhcmUgb3Jk" +
        "aW5hcnkgdGV4dCBoZXJlPsl+tQAAABFJREFUeJxj+M/A8B+EGWAMAEfKB/lnWW63AAAAAElFTkSuQmCC";
    private const string BACKGROUND_APNG_ONE_FRAME =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAACGFjVEwAAAABAAAAALQt6aAAAAAaZmNUTAAAAAAAAAACAAAAAgAA" +
        "AAAAAAAAAAEACgAA6FTcAAAAABFJREFUeJxj+M/A8B+EGWAMAEfKB/lnWW63AAAAAElFTkSuQmCC";
    private const string BACKGROUND_APNG_TWO_FRAMES =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAACAAAAAgAA" +
        "AAAAAAAAAAEACgAA6FTcAAAAABFJREFUeJxj+M/A8B+EGWAMAEfKB/lnWW63AAAAGmZjVEwAAAABAAAAAgAAAAIAAAAAAAAAAAAB" +
        "AAoAAHMnNtQAAAASZmRBVAAAAAJ4nGNg+A+FMAYAQ84H+d5oJ9kAAAAASUVORK5CYII=";
    private const string BACKGROUND_APNG_DEFAULT_OUTSIDE =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAACGFjVEwAAAACAAAAAPONk3AAAAARSURBVHicY/jPwPAfhBlgDABH" +
        "ygf5Z1lutwAAABpmY1RMAAAAAAAAAAIAAAACAAAAAAAAAAAAAQAKAADoVNwAAAAAEmZkQVQAAAABeJxjYPgPhTAGAEPOB/nPFU2g" +
        "AAAAGmZjVEwAAAACAAAAAgAAAAIAAAAAAAAAAAABAAoAAAXCD+kAAAAUZmRBVAAAAAN4nGNgYPj/H4KhDAA/0gf5UaYKDgAAAABJ" +
        "RU5ErkJggg==";
    private const string BACKGROUND_ORPHAN_FRAME_CONTROL =
        "AAAAGmZjVEwAAAABAAAAAgAAAAIAAAAAAAAAAAABAAoAAHMnNtQ=";
    private const string BACKGROUND_ORPHAN_FRAME_DATA =
        "AAAAEmZkQVQAAAACeJxjYPgPhTAGAEPOB/neaCfZ";
    private const string BACKGROUND_INDEXED_PNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACAgMAAAAP2OW3AAAADFBMVEX/AAAA/wAAAP8AAAD7vkbkAAAADElEQVR4nGMQYGgAAAC0" +
        "AJEACtizAAAAAElFTkSuQmCC";
    private const string BACKGROUND_INTERLACED_PNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACAQMAAAE/f6/xAAAAA1BMVEX/AAAZ4gk3AAAAC0lEQVQI12NgAAEAAAYAAWb0yWwAAAAA" +
        "SUVORK5CYII=";
    private const string BACKGROUND_BASELINE_JPEG =
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAIBAQEBAQIBAQECAgICAgQDAgICAgUEBAMEBgUGBgYFBgYGBwkIBgcJBwYGCAsICQoK" +
        "CgoKBggLDAsKDAkKCgr/2wBDAQICAgICAgUDAwUKBwYHCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoK" +
        "CgoKCgoKCgr/wAARCAACAAMDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABsQAAIDAQEBAAAAAAAAAAAAAAIDAQQG" +
        "BQgx/8QAFQEBAQAAAAAAAAAAAAAAAAAACAn/xAAdEQADAAMAAwEAAAAAAAAAAAABAgMEBQYHCBIy/9oADAMBAAIRAxEAPwBAP8o+" +
        "W9Ro9H0tN5rwHRsq2HaqLsXsdRcYV6/SsoQmCNUzALStagH4ALERiIGIhC+Dul6LS+EuWx9fmVjNtbgUKzo6KaWxZWtQhSAXrV3r" +
        "Rv09HZ2JZiTOD3a67rOe9ltxi6rYXx5NLAsUlWk1NcjXYl71KowBpe9KWs5H1StHo5Z2Yn//2Q==";
    private const string BACKGROUND_PROGRESSIVE_JPEG =
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAIBAQEBAQIBAQECAgICAgQDAgICAgUEBAMEBgUGBgYFBgYGBwkIBgcJBwYGCAsICQoK" +
        "CgoKBggLDAsKDAkKCgr/2wBDAQICAgICAgUDAwUKBwYHCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoK" +
        "CgoKCgoKCgr/wgARCAACAAMDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAAB//EABUBAQEAAAAAAAAAAAAAAAAAAAcI/9oA" +
        "DAMBAAIQAxAAAAFAQpv/AP/EABYQAQEBAAAAAAAAAAAAAAAAAAQGAf/aAAgBAQABBQLZSWUj/8QAHhEBAAEEAgMAAAAAAAAAAAAA" +
        "AgEDBAURAAcSMTL/2gAIAQMBAT8B7ty+Wx/Zd5Stbh0zJoPRSMeVS3pNrUT9NpNz7SUqdzM8/8QAHxEAAgEEAgMAAAAAAAAAAAAA" +
        "AQIDBAUGIQAREjFB/9oACAECAQE/AcHuVxosJtcdPMyKaaBulYgeTxK7tr6zEsx9liSdnn//xAAdEAACAgEFAAAAAAAAAAAAAAAB" +
        "AgMEAAYiMUGB/9oACAEBAAY/ArElnTVCRhcmUM9NDtWRgBx0AB5n/8QAGBABAAMBAAAAAAAAAAAAAAAAAQARMUH/2gAIAQEAAT8h" +
        "c9DLLLuBBwAZP//aAAwDAQACAAMAAAAQf//EABURAQEAAAAAAAAAAAAAAAAAAAER/9oACAEDAQE/EERVnhviFYSlVH//xAAVEQEB" +
        "AAAAAAAAAAAAAAAAAAABMf/aAAgBAgEBPxBzEJGRAgb+KlF//8QAFRABAQAAAAAAAAAAAAAAAAAAATH/2gAIAQEAAT8QIx5Exy0k" +
        "MYAA/9k=";
    private const string BACKGROUND_ORIENTED_JPEG =
        "/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAABAAYAAAAAAAD/2wBDAAIBAQEBAQIBAQECAgIC" +
        "AgQDAgICAgUEBAMEBgUGBgYFBgYGBwkIBgcJBwYGCAsICQoKCgoKBggLDAsKDAkKCgr/2wBDAQICAgICAgUDAwUKBwYHCgoKCgoK" +
        "CgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgr/wAARCAACAAMDAREAAhEBAxEB/8QAFAABAAAAAAAA" +
        "AAAAAAAAAAAACP/EABsQAAIDAQEBAAAAAAAAAAAAAAIDAQQGBQgx/8QAFQEBAQAAAAAAAAAAAAAAAAAACAn/xAAdEQADAAMAAwEA" +
        "AAAAAAAAAAABAgMEBQYHCBIy/9oADAMBAAIRAxEAPwBAP8o+W9Ro9H0tN5rwHRsq2HaqLsXsdRcYV6/SsoQmCNUzALStagH4ALER" +
        "iIGIhC+Dul6LS+EuWx9fmVjNtbgUKzo6KaWxZWtQhSAXrV3rRv09HZ2JZiTOD3a67rOe9ltxi6rYXx5NLAsUlWk1NcjXYl71KowB" +
        "pe9KWs5H1StHo5Z2Yn//2Q==";

    private uint8[] join_background_fixture(uint8[] prefix, uint8[] insertion, uint8[] suffix) {
        uint8[] result = new uint8[prefix.length + insertion.length + suffix.length];
        int offset = 0;
        foreach (uint8 value in prefix) result[offset++] = value;
        foreach (uint8 value in insertion) result[offset++] = value;
        foreach (uint8 value in suffix) result[offset++] = value;
        return result;
    }

    private Plugins.JmiVideoBackgroundImage decode_background_fixture(File file, uint8[] data,
            Cancellable? cancellable = null) throws Error {
        FileUtils.set_data((!) file.get_path(), data);
        return VideoBackgroundImageLoader.decode(file, cancellable);
    }

    private void assert_background_fixture_invalid(File file, uint8[] data, string description) throws Error {
        bool rejected = false;
        try { decode_background_fixture(file, data); }
        catch (IOError.INVALID_DATA e) { rejected = true; }
        catch (Error e) { fail_if(true, description + ": unexpected error: " + e.message); return; }
        fail_if(!rejected, description);
    }

    private void test_background_png_rejects_animation_chunks() {
        string directory;
        try { directory = DirUtils.make_tmp("dinox-background-apng-XXXXXX"); }
        catch (Error e) { fail_if(true, e.message); return; }
        File? image_file = null;
        try {
            string[] animations = { BACKGROUND_APNG_ONE_FRAME, BACKGROUND_APNG_TWO_FRAMES,
                BACKGROUND_APNG_DEFAULT_OUTSIDE };
            string[] names = { "background.png", "background.jpg", "background" };
            foreach (string name in names) {
                image_file = File.new_for_path(Path.build_filename(directory, name));
                for (int index = 0; index < animations.length; index++)
                    assert_background_fixture_invalid((!) image_file, Base64.decode(animations[index]),
                        "APNG variant %d must be rejected regardless of filename %s".printf(index, name));
                ((!) image_file).delete();
                image_file = null;
            }
            image_file = File.new_for_path(Path.build_filename(directory, "orphan.png"));
            uint8[] png = Base64.decode(BACKGROUND_STATIC_PNG);
            string[] orphan_chunks = { BACKGROUND_ORPHAN_FRAME_CONTROL, BACKGROUND_ORPHAN_FRAME_DATA };
            foreach (string chunk in orphan_chunks)
                assert_background_fixture_invalid((!) image_file,
                    join_background_fixture(png[0:png.length - 12], Base64.decode(chunk), png[png.length - 12:png.length]),
                    "A frame-control or frame-data chunk after IDAT must be rejected even without acTL");
        } catch (Error e) { fail_if(true, "APNG fixture failed: " + e.message); }
        finally {
            if (image_file != null) { try { ((!) image_file).delete(); } catch (Error ignored) { } }
            DirUtils.remove(directory);
        }
    }

    private void test_background_png_rejects_malformed_chunk_bounds() {
        string directory;
        try { directory = DirUtils.make_tmp("dinox-background-chunks-XXXXXX"); }
        catch (Error e) { fail_if(true, e.message); return; }
        File image_file = File.new_for_path(Path.build_filename(directory, "test.png"));
        try {
            uint8[] png = Base64.decode(BACKGROUND_STATIC_PNG);
            assert_background_fixture_invalid(image_file, png[0:8], "A PNG signature alone is not a complete image");
            assert_background_fixture_invalid(image_file, png[0:61],
                "A PNG chunk must include every payload byte and its four CRC bytes");
            // The complete IDAT ends at byte 62. Keep every possible incomplete IEND length.
            for (int remaining = 0; remaining < 12; remaining++)
                assert_background_fixture_invalid(image_file, png[0:62 + remaining],
                    "Missing IEND or a %d-byte chunk remainder must be rejected".printf(remaining));
            uint32[] lengths = { 0x7fffffffU, 0x80000000U, 0xffffffffU };
            foreach (uint32 length in lengths) {
                uint8[] damaged = join_background_fixture(png, new uint8[0], new uint8[0]);
                // IDAT's real payload is 17 bytes: a declared unsigned length must fit the file.
                for (int byte = 0; byte < 4; byte++) damaged[33 + byte] = (uint8) (length >> (24 - byte * 8));
                assert_background_fixture_invalid(image_file, damaged,
                    "An oversized unsigned PNG chunk length must be rejected before image decode");
            }
            foreach (uint8 length in new uint8[] { 12, 14 }) {
                uint8[] damaged = join_background_fixture(png, new uint8[0], new uint8[0]);
                damaged[11] = length;
                assert_background_fixture_invalid(image_file, damaged, "IHDR must have exactly 13 payload bytes");
            }
            uint8[] wrong_header = join_background_fixture(png, new uint8[0], new uint8[0]);
            wrong_header[12] = 'I'; wrong_header[13] = 'D'; wrong_header[14] = 'A'; wrong_header[15] = 'T';
            assert_background_fixture_invalid(image_file, wrong_header, "The first PNG chunk must be IHDR");
            assert_background_fixture_invalid(image_file,
                join_background_fixture(png[0:62], Base64.decode("AAAAAUlFTkQA0RpP4Q=="), new uint8[0]),
                "Even a CRC-valid IEND must have zero payload bytes");
            var cancelled = new Cancellable();
            cancelled.cancel();
            bool cancellation_observed = false;
            try { decode_background_fixture(image_file, png, cancelled); }
            catch (IOError.CANCELLED e) { cancellation_observed = true; }
            fail_if(!cancellation_observed, "A cancelled background choice must not produce pixels");
            assert_background_fixture_invalid(image_file, new uint8[8388609],
                "A regular file over 8 MiB must be rejected before image decoding");
        } catch (Error e) { fail_if(true, "PNG chunk fixture failed: " + e.message); }
        finally {
            try { image_file.delete(); } catch (Error ignored) { }
            DirUtils.remove(directory);
        }
    }

    private void test_background_static_png_and_jpeg_compatibility() {
        string directory;
        try { directory = DirUtils.make_tmp("dinox-background-static-XXXXXX"); }
        catch (Error e) { fail_if(true, e.message); return; }
        File image_file = File.new_for_path(Path.build_filename(directory, "image.bin"));
        try {
            string[] static_pngs = { BACKGROUND_STATIC_PNG, BACKGROUND_METADATA_PNG,
                BACKGROUND_INDEXED_PNG, BACKGROUND_INTERLACED_PNG };
            foreach (string fixture in static_pngs) {
                Plugins.JmiVideoBackgroundImage decoded = decode_background_fixture(image_file, Base64.decode(fixture));
                fail_if(decoded.width != 2 || decoded.height != 2,
                    "Static PNG pixels, textual APNG names, indexed color and Adam7 interlace must remain supported");
            }
            uint8[] png = Base64.decode(BACKGROUND_STATIC_PNG);
            Plugins.JmiVideoBackgroundImage trailer = decode_background_fixture(image_file,
                join_background_fixture(png, Base64.decode("AAAACGFjVEwAAAABAAAAALQt6aA="), new uint8[0]));
            fail_if(trailer.width != 2 || trailer.height != 2,
                "Bytes after IEND, including an acTL marker, retain the existing static PNG acceptance");
            Plugins.JmiVideoBackgroundImage baseline = decode_background_fixture(image_file, Base64.decode(BACKGROUND_BASELINE_JPEG));
            Plugins.JmiVideoBackgroundImage progressive = decode_background_fixture(image_file, Base64.decode(BACKGROUND_PROGRESSIVE_JPEG));
            fail_if(baseline.width != 3 || baseline.height != 2 || baseline.rgba ||
                progressive.width != 3 || progressive.height != 2 || progressive.rgba,
                "Baseline and progressive JPEG must remain supported without alpha");
            Plugins.JmiVideoBackgroundImage oriented = decode_background_fixture(image_file, Base64.decode(BACKGROUND_ORIENTED_JPEG));
            fail_if(oriented.width != 2 || oriented.height != 3 || oriented.rgba,
                "JPEG EXIF orientation 6 must rotate the decoded dimensions");
            for (uint y = 0; y < baseline.height; y++) {
                for (uint x = 0; x < baseline.width; x++) {
                    var original_pixel = new Bytes.from_bytes(baseline.pixels, y * baseline.stride + x * 3, 3);
                    var rotated_pixel = new Bytes.from_bytes(oriented.pixels,
                        x * oriented.stride + (baseline.height - 1 - y) * 3, 3);
                    fail_if(original_pixel.compare(rotated_pixel) != 0,
                        "EXIF rotation must preserve the JPEG pixels at their oriented positions");
                }
            }
        } catch (Error e) { fail_if(true, "Static PNG/JPEG fixture failed: " + e.message); }
        finally {
            try { image_file.delete(); } catch (Error ignored) { }
            DirUtils.remove(directory);
        }
    }

    private void test_additional_presets_keep_adjustments_and_respect_capabilities() {
        var window = new Window();
        var bottom_bar = new CallBottomBar();
        var capabilities = new Plugins.JmiVideoEffectCapabilities(true, true, true,
            Plugins.JmiVideoEffectUnavailableReason.NONE, true, true, 15, 1, false, 4064);
        var selection = new Plugins.JmiVideoEffectSelection(Plugins.JmiVideoEffectKind.OFF,
            Plugins.JmiVideoEffectQuality.AUTO, 0, 0, 12, -8, -20, 30);
        var status = new Plugins.JmiVideoEffectStatus(selection, Plugins.JmiVideoEffectApplyState.APPLIED, 1, 1);
        var requests = new Gee.ArrayList<Plugins.JmiVideoEffectSelection>();
        bottom_bar.video_effect_selected.connect((value) => { requests.add(value); });
        window.set_child(bottom_bar);
        window.present();
        VideoEffectsPopover? maybe_popover = bottom_bar.show_video_effect_choices(true, capabilities, status);
        fail_if(maybe_popover == null, "additional presets need a capable popover");
        VideoEffectsPopover popover = (!) maybe_popover;
        popover.popup();
        drain_main_context();
        fail_if(requests.size != 0, "showing more presets must not apply any filter");
        string[] labels = { "Light leak", "Dreamy", "Prism light", "Fisheye", "Vintage TV", "Frosted glass", "Duo tone" };
        for (int index = 0; index < labels.length; index++) {
            CheckButton? button = find_check_button(popover, labels[index]);
            fail_if(button == null || !((!) button).visible || !((!) button).sensitive,
                "each advertised additional preset must be visible and selectable");
            int previous_count = requests.size;
            ((!) button).active = true;
            fail_if(requests.size != previous_count + 1, "a radio transition must issue only one full selection");
            Plugins.JmiVideoEffectSelection selected = requests[requests.size - 1];
            fail_if(selected.kind != (Plugins.JmiVideoEffectKind) ((int) Plugins.JmiVideoEffectKind.LIGHT_LEAK + index) ||
                selected.brightness != 12 || selected.contrast != -8 || selected.saturation != -20 || selected.sharpness != 30,
                "additional presets must retain all four explicit adjustments");
            fail_if_not(capabilities.supports_selection(selected), "advertised presets must pass the capability gate");
        }
        Plugins.JmiVideoEffectSelection latest = requests[requests.size - 1];
        popover.update_state(capabilities, new Plugins.JmiVideoEffectStatus(latest,
            Plugins.JmiVideoEffectApplyState.APPLIED, 8, 8));
        popover.reset_button.clicked();
        fail_if_not(requests[requests.size - 1].is_neutral(), "Off must also clear the new presets and adjustments");
        var limited = new Plugins.JmiVideoEffectCapabilities(true, true, true,
            Plugins.JmiVideoEffectUnavailableReason.NONE, true, true, 15, 1, false,
            1UL << (int) Plugins.JmiVideoEffectKind.LIGHT_LEAK);
        popover.update_state(limited, new Plugins.JmiVideoEffectStatus(
            new Plugins.JmiVideoEffectSelection(Plugins.JmiVideoEffectKind.OFF), Plugins.JmiVideoEffectApplyState.IDLE, 9, 9));
        CheckButton? dreamy = find_check_button(popover, "Dreamy");
        fail_if(dreamy == null || ((!) dreamy).visible || ((!) dreamy).sensitive,
            "a source without a preset must not expose an actionable choice");
        fail_if(limited.supports_kind(Plugins.JmiVideoEffectKind.DREAMY), "capability subsets must reject absent presets");
        fail_if(capabilities.supports_kind((Plugins.JmiVideoEffectKind) 64), "unknown effect IDs must be rejected before bit shifts");
        bottom_bar.shutdown();
        window.set_child(null);
        window.destroy();
        drain_main_context();
    }

    private void test_video_controls_release_after_hangup() {
        // GLib registers the address of a GWeakRef. Keep that address stable
        // while the helper drops its strong reference instead of copying a
        // registered stack weak-ref back by value.
        WeakRef closed = WeakRef(null);
        create_closed_video_controls(ref closed);
        // GTK may still own the widget through a queued layout/frame update.
        // Allow that bounded cleanup without forcing dispose or disconnecting
        // production callbacks here: a real reference cycle still fails.
        int64 deadline = get_monotonic_time() + 500 * 1000;
        while (closed.get() != null && get_monotonic_time() < deadline) {
            drain_main_context();
            Thread.usleep(1000);
        }
        fail_if(closed.get() != null, "closed video controls must not be retained by their own signal callbacks");
    }

    private void create_closed_video_controls(ref WeakRef weak_reference) {
        var window = new Window();
        var bottom_bar = new CallBottomBar();
        var capabilities = new Plugins.JmiVideoEffectCapabilities(true, true, true,
            Plugins.JmiVideoEffectUnavailableReason.NONE, true, true, 15);
        var idle = new Plugins.JmiVideoEffectStatus(
            new Plugins.JmiVideoEffectSelection(Plugins.JmiVideoEffectKind.OFF),
            Plugins.JmiVideoEffectApplyState.IDLE, 0, 0);
        window.set_child(bottom_bar);
        window.present();
        VideoEffectsPopover? popover = bottom_bar.show_video_effect_choices(true, capabilities, idle);
        fail_if(popover == null, "the call must create its own effect controls");
        weak_reference.set(popover);
        ((!) popover).popup();
        drain_main_context();
        CheckButton? original = find_check_button((!) popover, "Original");
        fail_if(original == null || !((!) original).grab_focus(),
            "the focused popover teardown regression needs a live control");
        fail_if(window.get_focus() == null || !((!) window.get_focus()).is_ancestor((!) popover),
            "focus must be inside the effect popover before hangup");
        bottom_bar.shutdown();
        window.set_child(null);
        window.destroy();
    }

    private bool widget_tree_contains_label(Widget widget, string text) {
        Label? label = widget as Label?;
        // Match the displayed catalog text when running under a translated locale.
        if (label != null && ((!) label).label == _(text)) return true;

        Widget? child = widget.get_first_child();
        while (child != null) {
            if (widget_tree_contains_label((!) child, text)) return true;
            child = ((!) child).get_next_sibling();
        }
        return false;
    }

    private CheckButton? find_check_button(Widget widget, string label) {
        CheckButton? check_button = widget as CheckButton?;
        if (check_button != null && ((!) check_button).label == _(label)) {
            return check_button;
        }

        Widget? child = widget.get_first_child();
        while (child != null) {
            CheckButton? found = find_check_button((!) child, label);
            if (found != null) return found;
            child = ((!) child).get_next_sibling();
        }
        return null;
    }

    private void drain_main_context() {
        MainContext context = MainContext.default();
        while (context.pending()) {
            context.iteration(false);
        }
    }
}

}
