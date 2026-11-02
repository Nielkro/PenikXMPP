using Gtk;
using Gee;

private class AudioVideoDeviceChoice : Object {
    public string label { get; private set; }
    public string value { get; private set; }
    public Dino.Plugins.MediaDevice? device { get; private set; }

    public AudioVideoDeviceChoice(string label, string value, Dino.Plugins.MediaDevice? device = null) {
        this.label = label;
        this.value = value;
        this.device = device;
    }
}

private class AudioVideoDeviceCatalog : Object {
    public bool call_engine_available { get; set; }
    public bool recorder_available { get; set; }
    public bool playback_available { get; set; }
    public Gee.List<Dino.Plugins.MediaDevice> call_microphones { get; set; }
    public Gee.List<Dino.Plugins.MediaDevice> call_speakers { get; set; }
    public Gee.List<Dino.Plugins.MediaDevice> call_cameras { get; set; }
    public Gee.List<Dino.Plugins.MediaDevice> message_microphones { get; set; }
    public Gee.List<Dino.Plugins.MediaDevice> message_speakers { get; set; }
    public Gee.List<Dino.Plugins.MediaDevice> message_cameras { get; set; }

    public AudioVideoDeviceCatalog() {
        call_microphones = new ArrayList<Dino.Plugins.MediaDevice>();
        call_speakers = new ArrayList<Dino.Plugins.MediaDevice>();
        call_cameras = new ArrayList<Dino.Plugins.MediaDevice>();
        message_microphones = new ArrayList<Dino.Plugins.MediaDevice>();
        message_speakers = new ArrayList<Dino.Plugins.MediaDevice>();
        message_cameras = new ArrayList<Dino.Plugins.MediaDevice>();
    }
}

public class Dino.Ui.AudioVideoPreferencesPage : Adw.PreferencesPage {

    unowned Adw.ComboRow call_mic_row;
    unowned Adw.ComboRow call_speaker_row;
    unowned Adw.ComboRow call_camera_row;
    unowned Adw.ComboRow call_network_mode_row;
    unowned Adw.PreferencesGroup message_devices_group;
    unowned Adw.ComboRow msg_mic_row;
    unowned Adw.ComboRow msg_speaker_row;
    unowned Adw.ComboRow msg_camera_row;
    unowned Adw.ActionRow test_call_mic_row;
    unowned Adw.ActionRow test_call_speaker_row;
    unowned Adw.ActionRow test_call_camera_row;
    unowned Adw.ActionRow test_msg_mic_row;
    unowned Adw.ActionRow test_msg_camera_row;
    unowned Adw.ActionRow refresh_row;

    private Dino.Entities.Settings settings;
    private bool populating = false;
    private bool wired = false;
    private bool populated = false;
    private bool populate_scheduled = false;
    private bool populate_running = false;
    private uint populate_timeout_id = 0;
    private uint populate_generation = 0;
    private bool content_initialized = false;

    private ArrayList<AudioVideoDeviceChoice> call_mic_choices = new ArrayList<AudioVideoDeviceChoice>();
    private ArrayList<AudioVideoDeviceChoice> call_speaker_choices = new ArrayList<AudioVideoDeviceChoice>();
    private ArrayList<AudioVideoDeviceChoice> call_camera_choices = new ArrayList<AudioVideoDeviceChoice>();
    private ArrayList<AudioVideoDeviceChoice> msg_mic_choices = new ArrayList<AudioVideoDeviceChoice>();
    private ArrayList<AudioVideoDeviceChoice> msg_speaker_choices = new ArrayList<AudioVideoDeviceChoice>();
    private ArrayList<AudioVideoDeviceChoice> msg_camera_choices = new ArrayList<AudioVideoDeviceChoice>();
    private bool device_test_running = false;
    private unowned Adw.ActionRow? active_device_test_row = null;
    private uint audio_test_timeout_id = 0;
    private uint video_test_refresh_timeout_id = 0;
    private Dino.Ui.ChatInput.ProviderAudioMessageRecorderBackend? active_audio_test_backend = null;
    private Dino.Ui.ChatInput.ProviderVideoMessageRecorderBackend? active_video_test_backend = null;
    private Adw.AlertDialog? active_video_test_dialog = null;
    private Gtk.Picture? active_video_test_picture = null;
    private Gtk.Spinner? active_video_test_spinner = null;
    private string? active_test_output_path = null;
    private bool audio_test_playback_active = false;
    private ulong audio_level_handler = 0;
    private ulong audio_pcm_handler = 0;
    private ulong audio_error_handler = 0;
    private ulong audio_stopped_handler = 0;
    private ulong video_error_handler = 0;
    private ulong video_dialog_response_handler = 0;

    construct {
        this.map.connect(() => {
            int64 map_start_us = UiTiming.enabled() ? UiTiming.now_us() : 0;
            if (!content_initialized) {
                ensure_content();
            }
            if (!populated) {
                queue_populate();
            }
            if (UiTiming.enabled()) {
                UiTiming.log_ms("Preferences.audio-video: map", map_start_us);
            }
        });
        this.unmap.connect(() => {
            // A cancelled refresh invalidates the displayed catalog as well as
            // its response. Remapping must reload the disabled device rows.
            if (populate_running || populate_scheduled) populated = false;
            populate_generation++;
            populate_running = false;
            if (populate_timeout_id != 0) {
                Source.remove(populate_timeout_id);
                populate_timeout_id = 0;
                populate_scheduled = false;
            }
            cancel_active_device_test(true);
        });
    }

    public void ensure_content() {
        if (content_initialized) return;
        int64 build_start_us = UiTiming.enabled() ? UiTiming.now_us() : 0;
        content_initialized = true;

        Builder builder = new Builder.from_resource(
            "/im/dinox/dinox/preferences_window/audio_video_preferences_page.ui");
        var content_page = (Adw.PreferencesPage) builder.get_object("content_page");

        call_mic_row = (Adw.ComboRow) builder.get_object("call_mic_row");
        call_speaker_row = (Adw.ComboRow) builder.get_object("call_speaker_row");
        call_camera_row = (Adw.ComboRow) builder.get_object("call_camera_row");
        call_network_mode_row = (Adw.ComboRow) builder.get_object("call_network_mode_row");
        message_devices_group = (Adw.PreferencesGroup) builder.get_object("message_devices_group");
        msg_mic_row = (Adw.ComboRow) builder.get_object("msg_mic_row");
        msg_speaker_row = (Adw.ComboRow) builder.get_object("msg_speaker_row");
        msg_camera_row = (Adw.ComboRow) builder.get_object("msg_camera_row");
        test_call_mic_row = (Adw.ActionRow) builder.get_object("test_call_mic_row");
        test_call_speaker_row = (Adw.ActionRow) builder.get_object("test_call_speaker_row");
        test_call_camera_row = (Adw.ActionRow) builder.get_object("test_call_camera_row");
        test_msg_mic_row = (Adw.ActionRow) builder.get_object("test_msg_mic_row");
        test_msg_camera_row = (Adw.ActionRow) builder.get_object("test_msg_camera_row");
        refresh_row = (Adw.ActionRow) builder.get_object("refresh_row");

        string[] group_ids = {
            "call_devices_group", "message_devices_group", "call_device_tests_group",
            "message_device_tests_group", "device_management_group"
        };
        foreach (string group_id in group_ids) {
            var group = (Adw.PreferencesGroup) builder.get_object(group_id);
            content_page.remove(group);
            this.add(group);
        }

        if (this.get_mapped() && !populated) {
            queue_populate();
        }
        if (UiTiming.enabled()) {
            UiTiming.log_ms("Preferences.audio-video: build content", build_start_us);
        }
    }

    public void populate() {
        bool timing = UiTiming.enabled();
        int64 prepare_start_us = timing ? UiTiming.now_us() : 0;
        var app = (Dino.Application) GLib.Application.get_default();
        settings = app.settings;
        Dino.Plugins.JmiCallEnginePlugin? call_engine = app.plugin_registry.jmi_call_engine_plugin;
        bool call_engine_available = call_engine != null && ((!) call_engine).engine_id == "google-libwebrtc";
        Dino.Plugins.MediaMessageRecorderProvider? recorder_provider = app.plugin_registry.media_message_recorder_provider;
        bool recorder_available = recorder_provider != null && ((!) recorder_provider).id == "google-libwebrtc";
        Dino.Plugins.MediaMessagePlaybackProvider? playback_provider = app.plugin_registry.media_message_playback_provider;
        bool playback_available = playback_provider != null &&
            ((!) playback_provider).id == "google-libwebrtc" &&
            ((!) playback_provider).available;

        populated = false;
        populating = true;
        populate_network_mode_combo();
        set_call_rows_sensitive(false);
        set_message_rows_sensitive(false);
        set_device_test_rows_sensitive(false, false);
        call_mic_row.subtitle = call_engine_available
            ? _("Loading Google WebRTC audio input devices…")
            : _("Google WebRTC call engine is not active");
        call_speaker_row.subtitle = call_engine_available
            ? _("Loading Google WebRTC audio output devices…")
            : _("Google WebRTC call engine is not active");
        call_camera_row.subtitle = call_engine_available
            ? _("Loading Google WebRTC video input devices…")
            : _("Google WebRTC call engine is not active");
        msg_mic_row.subtitle = recorder_available
            ? _("Loading Google WebRTC recording devices…")
            : _("Google WebRTC recorder is not available");
        msg_speaker_row.subtitle = playback_available
            ? _("Loading Google WebRTC audio output devices…")
            : _("Google WebRTC message playback is not available");
        msg_camera_row.subtitle = msg_mic_row.subtitle;
        populating = false;

        wire_rows_once();

        populate_generation++;
        uint generation = populate_generation;
        populate_running = true;
        if (timing) {
            UiTiming.log_ms("Preferences.audio-video: prepare device catalog", prepare_start_us);
        }
        int64 catalog_start_us = timing ? UiTiming.now_us() : 0;
        new Thread<void*>("dinox-webrtc-device-catalog", () => {
            var catalog = new AudioVideoDeviceCatalog();
            catalog.call_engine_available = call_engine_available;
            catalog.recorder_available = recorder_available;
            catalog.playback_available = playback_available;
            if (call_engine_available) {
                catalog.call_microphones = ((!) call_engine).get_audio_devices(false);
                catalog.call_speakers = ((!) call_engine).get_audio_devices(true);
                catalog.call_cameras = ((!) call_engine).get_video_devices();
            }
            if (recorder_available) {
                catalog.message_microphones = ((!) recorder_provider).get_audio_input_devices();
                catalog.message_cameras = ((!) recorder_provider).get_video_input_devices();
            }
            if (playback_available) {
                catalog.message_speakers = ((!) playback_provider).get_audio_output_devices();
            }
            if (timing) {
                UiTiming.log_ms("Preferences.audio-video: enumerate device catalog", catalog_start_us);
            }
            int64 handoff_start_us = timing ? UiTiming.now_us() : 0;
            Idle.add(() => {
                if (generation != populate_generation || !this.get_mapped()) return false;
                populate_running = false;
                if (timing) {
                    UiTiming.log_ms("Preferences.audio-video: device catalog main-loop handoff", handoff_start_us);
                }
                int64 apply_start_us = timing ? UiTiming.now_us() : 0;
                apply_device_catalog(catalog);
                if (timing) {
                    UiTiming.log_ms("Preferences.audio-video: apply device catalog", apply_start_us);
                }
                return false;
            });
            return null;
        });
    }

    private void apply_device_catalog(AudioVideoDeviceCatalog catalog) {
        populating = true;

        if (catalog.call_engine_available) {
            call_mic_choices = build_media_device_choices(catalog.call_microphones);
            call_speaker_choices = build_media_device_choices(catalog.call_speakers);
            call_camera_choices = build_media_device_choices(catalog.call_cameras);
            call_mic_row.subtitle = _("Google WebRTC audio input for calls");
            call_speaker_row.subtitle = _("Google WebRTC audio output for calls");
            call_camera_row.subtitle = _("Google WebRTC video input for calls");
            set_call_rows_sensitive(true);
        } else {
            call_mic_choices = build_default_only_choices();
            call_speaker_choices = build_default_only_choices();
            call_camera_choices = build_default_only_choices();
            call_mic_row.subtitle = _("Google WebRTC call engine is not active");
            call_speaker_row.subtitle = _("Google WebRTC call engine is not active");
            call_camera_row.subtitle = _("Google WebRTC call engine is not active");
            set_call_rows_sensitive(false);
        }

        message_devices_group.description = _("Devices used for recording and playing messages");
        if (catalog.recorder_available) {
            msg_mic_choices = build_media_device_choices(catalog.message_microphones);
            msg_camera_choices = build_media_device_choices(catalog.message_cameras);
            msg_mic_row.subtitle = _("Google WebRTC audio input for voice and video messages");
            msg_camera_row.subtitle = _("Google WebRTC video input for video messages");
            set_message_rows_sensitive(true);
        } else {
            msg_mic_choices = build_default_only_choices();
            msg_camera_choices = build_default_only_choices();
            msg_mic_row.subtitle = _("Google WebRTC recorder is not available");
            msg_camera_row.subtitle = _("Google WebRTC recorder is not available");
            set_message_rows_sensitive(false);
        }
        if (catalog.playback_available) {
            msg_speaker_choices = build_media_device_choices(catalog.message_speakers);
            msg_speaker_row.subtitle = _("Google WebRTC audio output for voice and video messages");
            msg_speaker_row.sensitive = true;
        } else {
            msg_speaker_choices = build_default_only_choices();
            msg_speaker_row.subtitle = _("Google WebRTC message playback is not available");
            msg_speaker_row.sensitive = false;
        }
        set_device_test_rows_sensitive(catalog.call_engine_available, catalog.recorder_available);
        reset_device_test_subtitles();

        populate_combo(call_mic_row, call_mic_choices, settings.call_audio_input_device);
        populate_combo(call_speaker_row, call_speaker_choices, settings.call_audio_output_device);
        populate_combo(call_camera_row, call_camera_choices, settings.call_video_device);
        populate_combo(msg_mic_row, msg_mic_choices, settings.msg_audio_input_device);
        populate_combo(msg_speaker_row, msg_speaker_choices, settings.msg_audio_output_device);
        populate_combo(msg_camera_row, msg_camera_choices, settings.msg_video_device);

        populating = false;

        populated = true;
    }

    private void wire_rows_once() {
        if (!wired) {
            Adw.ComboRow[] device_rows = {
                call_mic_row, call_speaker_row, call_camera_row,
                msg_mic_row, msg_speaker_row, msg_camera_row
            };
            foreach (var row in device_rows) {
                // A method-bound signal uses a weak page target. An owned save
                // lambda would make page -> row -> callback -> page a cycle.
                row.notify["selected"].connect(on_device_selection_changed);
            }
            call_network_mode_row.notify["selected"].connect(() => {
                if (populating) return;
                settings.call_network_mode = call_network_mode_row.selected == 1
                    ? "low-bandwidth-2g"
                    : "automatic";
            });
            refresh_row.activated.connect(() => {
                populate();
            });
            test_call_mic_row.activated.connect(() => {
                run_microphone_test(test_call_mic_row, call_mic_row, true);
            });
            test_call_speaker_row.activated.connect(() => {
                run_speaker_test();
            });
            test_call_camera_row.activated.connect(() => {
                run_camera_test(test_call_camera_row, call_camera_row, true);
            });
            test_msg_mic_row.activated.connect(() => {
                run_microphone_test(test_msg_mic_row, msg_mic_row, false);
            });
            test_msg_camera_row.activated.connect(() => {
                run_camera_test(test_msg_camera_row, msg_camera_row, false);
            });

            wired = true;
        }
    }

    private void queue_populate() {
        if (populate_scheduled || populate_running || populated) return;
        populate_scheduled = true;
        int64 queue_start_us = UiTiming.enabled() ? UiTiming.now_us() : 0;
        populate_timeout_id = Timeout.add(16, () => {
            populate_timeout_id = 0;
            populate_scheduled = false;
            if (!this.get_mapped()) {
                return false;
            }
            if (UiTiming.enabled()) {
                UiTiming.log_ms("Preferences.audio-video: queued populate wait", queue_start_us);
            }
            populate();
            return false;
        });
    }

    private void populate_network_mode_combo() {
        var labels = new Gtk.StringList(null);
        labels.append(_("Automatic"));
        labels.append(_("Low bandwidth (2G, audio calls only)"));
        call_network_mode_row.model = labels;
        call_network_mode_row.selected = settings.call_network_mode == "low-bandwidth-2g" ? 1 : 0;
    }

    private void on_device_selection_changed(GLib.Object object, GLib.ParamSpec spec) {
        var row = object as Adw.ComboRow;
        if (row == null || populating || !row.sensitive) return;
        string value = get_combo_value(row);
        if (row == call_mic_row) settings.call_audio_input_device = value;
        else if (row == call_speaker_row) settings.call_audio_output_device = value;
        else if (row == call_camera_row) settings.call_video_device = value;
        else if (row == msg_mic_row) settings.msg_audio_input_device = value;
        else if (row == msg_speaker_row) settings.msg_audio_output_device = value;
        else if (row == msg_camera_row) settings.msg_video_device = value;
    }

    private ArrayList<AudioVideoDeviceChoice> build_default_only_choices() {
        var choices = new ArrayList<AudioVideoDeviceChoice>();
        choices.add(new AudioVideoDeviceChoice(_("System Default"), ""));
        return choices;
    }

    private ArrayList<AudioVideoDeviceChoice> build_media_device_choices(Gee.List<Dino.Plugins.MediaDevice> devices) {
        var choices = build_default_only_choices();
        foreach (Dino.Plugins.MediaDevice device in devices) {
            string value = device.persistent_id;
            if (value == "") value = device.display_name;
            choices.add(new AudioVideoDeviceChoice(device.display_name, value, device));
        }
        return choices;
    }

    private void populate_combo(Adw.ComboRow row, Gee.List<AudioVideoDeviceChoice> choices,
                                string saved_value) {
        var model = new Gtk.StringList(null);
        var devices = new ArrayList<Dino.Plugins.MediaDevice>();
        foreach (var choice in choices) {
            model.append(choice.label);
            if (choice.device != null) devices.add((!) choice.device);
        }
        // Resolve identities across the whole list before considering names.
        // Duplicate labels must not win over a later device's exact ID.
        Dino.Plugins.MediaDevice? saved_device = Dino.Plugins.MediaDeviceSelection.find(devices, saved_value);
        uint selected = 0;
        for (int i = 1; i < choices.size; i++) {
            if (choices[i].device == saved_device && saved_device != null) {
                selected = i;
                break;
            }
        }
        row.model = model;
        row.selected = selected;
    }

    private string get_combo_value(Adw.ComboRow row) {
        AudioVideoDeviceChoice? choice = get_selected_choice(row);
        if (choice == null) return "";
        return ((!) choice).value;
    }

    private AudioVideoDeviceChoice? get_selected_choice(Adw.ComboRow row) {
        uint sel = row.selected;
        Gee.List<AudioVideoDeviceChoice>? choices = get_choices_for_row(row);
        if (choices == null || sel >= ((!) choices).size) return null;
        return ((!) choices)[(int) sel];
    }

    private Gee.List<AudioVideoDeviceChoice>? get_choices_for_row(Adw.ComboRow row) {
        if (row == call_mic_row) return call_mic_choices;
        if (row == call_speaker_row) return call_speaker_choices;
        if (row == call_camera_row) return call_camera_choices;
        if (row == msg_mic_row) return msg_mic_choices;
        if (row == msg_speaker_row) return msg_speaker_choices;
        if (row == msg_camera_row) return msg_camera_choices;
        return null;
    }

    private void run_speaker_test() {
        Dino.Plugins.JmiCallEnginePlugin? call_engine = get_google_call_engine();
        if (call_engine == null) {
            show_device_test_error(test_call_speaker_row, _("Speaker test failed"), _("Google WebRTC call engine is not available."));
            return;
        }
        if (!begin_device_test(test_call_speaker_row, _("Playing speaker test tone…"))) return;

        try {
            Dino.Plugins.MediaDevice? device = get_selected_media_device(
                call_speaker_row,
                ((!) call_engine).get_audio_devices(true));
            uint duration_ms = 520;
            ((!) call_engine).play_test_tone(device, '5', duration_ms);
            audio_test_playback_active = true;
            test_call_speaker_row.subtitle = _("Speaker test tone is playing.");
            audio_test_timeout_id = Timeout.add(duration_ms + 220, () => {
                audio_test_timeout_id = 0;
                finish_device_test(test_call_speaker_row, _("Speaker test tone finished."), false);
                return false;
            });
        } catch (Error e) {
            finish_device_test(test_call_speaker_row, _("Speaker test failed."), false);
            show_device_test_error(test_call_speaker_row, _("Speaker test failed"), e.message);
        }
    }

    private void run_microphone_test(Adw.ActionRow status_row, Adw.ComboRow device_row, bool call_device) {
        Dino.Plugins.MediaMessageRecorderProvider? provider = get_google_recorder_provider();
        Dino.Plugins.JmiCallEnginePlugin? call_engine = get_google_call_engine();
        Dino.Plugins.MediaMessagePlaybackProvider? playback_provider = get_google_playback_provider();
        if (provider == null || call_engine == null || (!call_device && playback_provider == null)) {
            show_device_test_error(
                status_row,
                _("Microphone test failed"),
                _("Google WebRTC recorder or speaker output is not available."));
            return;
        }

        try {
            Dino.Plugins.MediaDevice? device = call_device ?
                get_selected_call_media_device(device_row, false) :
                get_selected_media_device(device_row, ((!) provider).get_audio_input_devices());
            if (!begin_device_test(status_row, _("Recording microphone test… speak now."))) return;

            string output_path = create_device_test_temp_path();
            active_test_output_path = output_path;
            var backend = new Dino.Ui.ChatInput.ProviderAudioMessageRecorderBackend((!) provider, device, true);
            active_audio_test_backend = backend;
            var pcm_frames = new ArrayList<Bytes>();
            size_t pcm_byte_count = 0;
            int pcm_sample_rate = 0;
            int pcm_channels = 0;
            int pcm_bytes_per_sample = 0;
            double peak = 0.0;
            bool input_detected = false;

            audio_level_handler = backend.level_changed.connect((level) => {
                if (level > peak) peak = level;
                if (!input_detected && level >= 0.015) {
                    input_detected = true;
                    status_row.subtitle = _("Microphone input detected. Finishing test…");
                }
            });
            audio_pcm_handler = backend.pcm_frame.connect((pcm_data, sample_rate, channels, bytes_per_sample) => {
                if (sample_rate <= 0 || channels <= 0 || bytes_per_sample != 2) return;
                if (pcm_sample_rate == 0) {
                    pcm_sample_rate = sample_rate;
                    pcm_channels = channels;
                    pcm_bytes_per_sample = bytes_per_sample;
                }
                if (sample_rate != pcm_sample_rate ||
                        channels != pcm_channels ||
                        bytes_per_sample != pcm_bytes_per_sample) {
                    return;
                }
                pcm_frames.add(pcm_data);
                pcm_byte_count += pcm_data.get_size();
            });
            audio_error_handler = backend.recording_error.connect((message) => {
                if (active_audio_test_backend != backend) return;
                finish_device_test(status_row, _("Microphone test failed."), false);
                show_device_test_error(status_row, _("Microphone test failed"), message);
            });
            audio_stopped_handler = backend.recording_stopped.connect((output) => {
                if (active_audio_test_backend != backend) return;
                if (audio_test_timeout_id != 0) {
                    Source.remove(audio_test_timeout_id);
                    audio_test_timeout_id = 0;
                }
                if (output != null) {
                    FileUtils.unlink(((Dino.Ui.ChatInput.MediaMessageRecorderOutput) (!) output).path);
                }
                active_test_output_path = null;
                disconnect_audio_test_handlers();
                active_audio_test_backend = null;

                try {
                    Bytes? clip = build_audio_test_clip(
                        pcm_frames,
                        pcm_byte_count,
                        pcm_sample_rate,
                        pcm_channels,
                        pcm_bytes_per_sample);
                    if (clip == null) {
                        finish_device_test(status_row, _("No WebRTC microphone input detected."), false);
                        return;
                    }

                    Adw.ComboRow speaker_row = call_device ? call_speaker_row : msg_speaker_row;
                    Gee.List<Dino.Plugins.MediaDevice> speakers = call_device
                        ? ((!) call_engine).get_audio_devices(true)
                        : ((!) playback_provider).get_audio_output_devices();
                    Dino.Plugins.MediaDevice? speaker = get_selected_media_device(speaker_row, speakers);
                    uint playback_ms = ((!) call_engine).play_audio_test_clip(
                        speaker,
                        (!) clip,
                        pcm_sample_rate,
                        pcm_channels,
                        pcm_bytes_per_sample);
                    audio_test_playback_active = true;
                    status_row.subtitle = _("Playing the microphone recording…");
                    audio_test_timeout_id = Timeout.add(playback_ms + 220, () => {
                        audio_test_timeout_id = 0;
                        string result = peak >= 0.015 ?
                            _("Microphone recording played successfully.") :
                            _("Microphone recording was silent.");
                        finish_device_test(status_row, result, false);
                        return false;
                    });
                } catch (Error e) {
                    finish_device_test(status_row, _("Microphone test failed."), false);
                    show_device_test_error(status_row, _("Microphone test failed"), e.message);
                }
            });

            backend.start_recording(output_path);
            if (active_audio_test_backend != backend) return;
            audio_test_timeout_id = Timeout.add(3000, () => {
                audio_test_timeout_id = 0;
                if (active_audio_test_backend == backend) {
                    backend.stop_recording();
                }
                return false;
            });
        } catch (Error e) {
            cancel_active_device_test(false);
            show_device_test_error(status_row, _("Microphone test failed"), e.message);
        }
    }

    private void run_camera_test(Adw.ActionRow status_row, Adw.ComboRow device_row, bool call_device) {
        Dino.Plugins.MediaMessageRecorderProvider? provider = get_google_recorder_provider();
        if (provider == null) {
            show_device_test_error(
                status_row,
                _("Camera test failed"),
                _("Google WebRTC recorder is not available."));
            return;
        }

        Window? root = this.get_root() as Window;
        if (root == null) return;

        try {
            Dino.Plugins.MediaDevice? device = call_device ?
                get_selected_call_media_device(device_row, true) :
                get_selected_media_device(device_row, ((!) provider).get_video_input_devices());
            if (!begin_device_test(status_row, _("Starting camera preview…"))) return;

            string output_path = create_device_test_temp_path();
            active_test_output_path = output_path;
            var backend = new Dino.Ui.ChatInput.ProviderVideoMessageRecorderBackend((!) provider, device, true);
            active_video_test_backend = backend;

            var preview_box = new Box(Orientation.VERTICAL, 12);
            preview_box.margin_top = 6;
            preview_box.margin_bottom = 6;
            var aspect_frame = new AspectFrame(0.5f, 0.5f, 16.0f / 9.0f, false);
            aspect_frame.set_size_request(420, 236);
            var preview_overlay = new Overlay();
            var preview_picture = new Picture();
            preview_picture.content_fit = ContentFit.CONTAIN;
            preview_picture.add_css_class("card");
            preview_picture.visible = false;
            preview_picture.set_size_request(420, 236);
            var preview_spinner = new Spinner();
            preview_spinner.halign = Align.CENTER;
            preview_spinner.valign = Align.CENTER;
            preview_spinner.start();
            preview_overlay.set_child(preview_picture);
            preview_overlay.add_overlay(preview_spinner);
            aspect_frame.set_child(preview_overlay);
            preview_box.append(aspect_frame);

            active_video_test_picture = preview_picture;
            active_video_test_spinner = preview_spinner;

            AudioVideoDeviceChoice? choice = get_selected_choice(device_row);
            string camera_name = choice != null ? ((!) choice).label : _("System Default");
            var dialog = new Adw.AlertDialog(
                call_device ? _("Call Camera Preview") : _("Message Camera Preview"),
                (call_device
                    ? _("Camera: %s\nUses the camera selected under Audio/Video Calls.")
                    : _("Camera: %s\nUses the camera selected under Voice/Video Messages.")).printf(camera_name));
            dialog.add_response("close", _("Close"));
            dialog.default_response = "close";
            dialog.close_response = "close";
            dialog.set_extra_child(preview_box);
            active_video_test_dialog = dialog;
            video_dialog_response_handler = dialog.response.connect((response) => {
                if (active_video_test_dialog != dialog) return;
                cancel_active_device_test(false);
                status_row.subtitle = _("Camera preview closed.");
            });

            video_error_handler = backend.recording_error.connect((message) => {
                if (active_video_test_backend != backend) return;
                finish_device_test(status_row, _("Camera test failed."), true);
                show_device_test_error(status_row, _("Camera test failed"), message);
            });

            backend.start_recording(output_path);
            dialog.present(root);
            status_row.subtitle = _("Camera preview is running.");
            video_test_refresh_timeout_id = Timeout.add(80, () => {
                if (active_video_test_backend != backend ||
                        active_video_test_picture == null ||
                        active_video_test_spinner == null) {
                    video_test_refresh_timeout_id = 0;
                    return false;
                }
                Gdk.Texture? texture = backend.get_preview_texture();
                if (texture != null) {
                    ((!) active_video_test_picture).paintable = (!) texture;
                    ((!) active_video_test_picture).visible = true;
                    ((!) active_video_test_spinner).stop();
                    ((!) active_video_test_spinner).visible = false;
                }
                return true;
            });
        } catch (Error e) {
            cancel_active_device_test(false);
            show_device_test_error(status_row, _("Camera test failed"), e.message);
        }
    }

    private bool begin_device_test(Adw.ActionRow status_row, string status) {
        if (device_test_running) {
            if (status_row != active_device_test_row) {
                status_row.subtitle = _("Another device test is already running.");
            }
            return false;
        }
        device_test_running = true;
        active_device_test_row = status_row;
        set_all_device_test_rows_sensitive(false);
        status_row.subtitle = status;
        return true;
    }

    private void finish_device_test(Adw.ActionRow? status_row, string? status, bool close_video_dialog) {
        clear_active_device_test(close_video_dialog);
        if (status_row != null && status != null) {
            ((!) status_row).subtitle = (!) status;
        }
    }

    private void cancel_active_device_test(bool close_video_dialog) {
        // Disconnect first: cancellation may synchronously emit a backend error.
        disconnect_audio_test_handlers();
        disconnect_video_test_handlers();
        if (active_audio_test_backend != null) {
            ((!) active_audio_test_backend).cancel_recording();
        }
        if (active_video_test_backend != null) {
            ((!) active_video_test_backend).cancel_recording();
        }
        clear_active_device_test(close_video_dialog);
    }

    private void clear_active_device_test(bool close_video_dialog) {
        disconnect_audio_test_handlers();
        disconnect_video_test_handlers();
        Adw.AlertDialog? dialog_to_close = null;
        if (audio_test_timeout_id != 0) {
            Source.remove(audio_test_timeout_id);
            audio_test_timeout_id = 0;
        }
        if (video_test_refresh_timeout_id != 0) {
            Source.remove(video_test_refresh_timeout_id);
            video_test_refresh_timeout_id = 0;
        }
        if (close_video_dialog && active_video_test_dialog != null) {
            dialog_to_close = active_video_test_dialog;
            active_video_test_dialog = null;
        }
        if (active_test_output_path != null) {
            FileUtils.unlink((!) active_test_output_path);
        }
        if (audio_test_playback_active) {
            Dino.Plugins.JmiCallEnginePlugin? call_engine = get_google_call_engine();
            if (call_engine != null) {
                try {
                    ((!) call_engine).stop_audio_test_playout();
                } catch (Error e) {
                    debug("Could not stop Google WebRTC audio device test: %s", e.message);
                }
            }
        }
        active_audio_test_backend = null;
        active_video_test_backend = null;
        active_video_test_dialog = null;
        active_video_test_picture = null;
        active_video_test_spinner = null;
        active_test_output_path = null;
        audio_test_playback_active = false;
        device_test_running = false;
        active_device_test_row = null;
        restore_device_test_sensitivity();
        if (dialog_to_close != null) {
            ((!) dialog_to_close).close();
        }
    }

    private void disconnect_audio_test_handlers() {
        if (active_audio_test_backend != null) {
            var backend = (!) active_audio_test_backend;
            if (audio_level_handler != 0) backend.disconnect(audio_level_handler);
            if (audio_pcm_handler != 0) backend.disconnect(audio_pcm_handler);
            if (audio_error_handler != 0) backend.disconnect(audio_error_handler);
            if (audio_stopped_handler != 0) backend.disconnect(audio_stopped_handler);
        }
        audio_level_handler = audio_pcm_handler = audio_error_handler = audio_stopped_handler = 0;
    }

    private void disconnect_video_test_handlers() {
        if (active_video_test_backend != null && video_error_handler != 0) {
            ((!) active_video_test_backend).disconnect(video_error_handler);
        }
        video_error_handler = 0;
        if (active_video_test_dialog != null && video_dialog_response_handler != 0) {
            ((!) active_video_test_dialog).disconnect(video_dialog_response_handler);
        }
        video_dialog_response_handler = 0;
    }

    private string create_device_test_temp_path() throws Error {
        FileIOStream stream;
        File file = File.new_tmp("dinox-device-test-XXXXXX", out stream);
        stream.close();
        string? path = file.get_path();
        if (path == null) {
            throw new IOError.FAILED("Could not create temporary device test file");
        }
        return (!) path;
    }

    private static Bytes? build_audio_test_clip(
            Gee.List<Bytes> frames,
            size_t total_byte_count,
            int sample_rate,
            int channels,
            int bytes_per_sample) {
        if (frames.is_empty ||
                total_byte_count == 0 ||
                sample_rate <= 0 ||
                channels <= 0 ||
                bytes_per_sample != 2) {
            return null;
        }

        size_t skip_bytes =
            ((size_t) sample_rate * (size_t) channels *
             (size_t) bytes_per_sample * 500) / 1000;
        if (skip_bytes >= total_byte_count || total_byte_count - skip_bytes > int.MAX) {
            return null;
        }

        uint8[] combined = new uint8[(int) (total_byte_count - skip_bytes)];
        size_t write_offset = 0;
        size_t remaining_skip = skip_bytes;
        foreach (Bytes frame in frames) {
            unowned uint8[]? raw_maybe = frame.get_data();
            if (raw_maybe == null) continue;
            unowned uint8[] raw = (!) raw_maybe;
            size_t frame_size = frame.get_size();
            size_t frame_offset = remaining_skip < frame_size ? remaining_skip : frame_size;
            remaining_skip -= frame_offset;
            size_t copy_size = frame_size - frame_offset;
            if (copy_size == 0) continue;
            Memory.copy(
                ((uint8*) combined) + write_offset,
                ((uint8*) raw) + frame_offset,
                copy_size);
            write_offset += copy_size;
        }
        if (write_offset == 0) return null;
        if (write_offset != combined.length) return null;
        return new Bytes(combined);
    }

    private Dino.Plugins.MediaDevice? get_selected_call_media_device(Adw.ComboRow row, bool video) throws Error {
        Dino.Plugins.JmiCallEnginePlugin? call_engine = get_google_call_engine();
        if (call_engine == null) {
            throw new IOError.NOT_SUPPORTED("Google WebRTC call engine is not available");
        }
        Dino.Plugins.MediaDevice? selected = get_selected_media_device(
            row,
            video ? ((!) call_engine).get_video_devices() : ((!) call_engine).get_audio_devices(false));
        // Null means "use message preferences" to the recorder provider. Call
        // tests need an explicit system-default override instead.
        return selected ?? new Dino.Plugins.SystemDefaultMediaDevice(video ? "video" : "audio");
    }

    private Dino.Plugins.MediaDevice? get_selected_media_device(
            Adw.ComboRow row,
            Gee.List<Dino.Plugins.MediaDevice> devices) throws Error {
        AudioVideoDeviceChoice? choice = get_selected_choice(row);
        if (choice == null || ((!) choice).value == "") return null;
        Dino.Plugins.MediaDevice? original_device = ((!) choice).device;
        Dino.Plugins.MediaDevice? selected = original_device != null
            ? Dino.Plugins.MediaDeviceSelection.find_selected(devices, (!) original_device)
            : Dino.Plugins.MediaDeviceSelection.find(devices, ((!) choice).value);
        if (selected != null) return selected;
        throw new IOError.NOT_FOUND("Selected Google WebRTC device is not available");
    }

    private Dino.Plugins.JmiCallEnginePlugin? get_google_call_engine() {
        var app = (Dino.Application) GLib.Application.get_default();
        Dino.Plugins.JmiCallEnginePlugin? call_engine = app.plugin_registry.jmi_call_engine_plugin;
        if (call_engine == null || ((!) call_engine).engine_id != "google-libwebrtc") return null;
        return call_engine;
    }

    private Dino.Plugins.MediaMessageRecorderProvider? get_google_recorder_provider() {
        var app = (Dino.Application) GLib.Application.get_default();
        Dino.Plugins.MediaMessageRecorderProvider? provider = app.plugin_registry.media_message_recorder_provider;
        if (provider == null || ((!) provider).id != "google-libwebrtc") return null;
        return provider;
    }

    private Dino.Plugins.MediaMessagePlaybackProvider? get_google_playback_provider() {
        var app = (Dino.Application) GLib.Application.get_default();
        Dino.Plugins.MediaMessagePlaybackProvider? provider = app.plugin_registry.media_message_playback_provider;
        if (provider == null ||
                ((!) provider).id != "google-libwebrtc" ||
                !((!) provider).available) {
            return null;
        }
        return provider;
    }

    private void show_device_test_error(Adw.ActionRow row, string title, string message) {
        row.subtitle = title;
        Window? root = this.get_root() as Window;
        if (root == null) return;
        var dialog = new Adw.AlertDialog(title, message);
        dialog.add_response("ok", _("OK"));
        dialog.default_response = "ok";
        dialog.close_response = "ok";
        dialog.present(root);
    }

    private void reset_device_test_subtitles() {
        test_call_mic_row.subtitle = _("Record and play back a short clip with the selected call microphone");
        test_call_speaker_row.subtitle = _("Play a short tone on the selected call speaker");
        test_call_camera_row.subtitle = _("Show a short live preview from the selected call camera");
        test_msg_mic_row.subtitle = _("Record and play back a short clip with the selected message microphone");
        test_msg_camera_row.subtitle = _("Show a short live preview from the selected message camera");
    }

    private void set_device_test_rows_sensitive(bool call_engine_available, bool recorder_available) {
        if (device_test_running) {
            set_all_device_test_rows_sensitive(false);
            return;
        }
        test_call_speaker_row.sensitive = call_engine_available;
        test_call_mic_row.sensitive = call_engine_available && recorder_available;
        test_call_camera_row.sensitive = call_engine_available && recorder_available;
        test_msg_mic_row.sensitive = call_engine_available &&
            recorder_available && get_google_playback_provider() != null;
        test_msg_camera_row.sensitive = recorder_available;
    }

    private void restore_device_test_sensitivity() {
        set_device_test_rows_sensitive(get_google_call_engine() != null, get_google_recorder_provider() != null);
    }

    private void set_all_device_test_rows_sensitive(bool sensitive) {
        // Making the focused row insensitive moves GTK focus elsewhere and
        // scrolls the page. Keep the running status row focusable; the busy
        // guard rejects another activation while all other tests are disabled.
        test_call_mic_row.sensitive = sensitive || active_device_test_row == test_call_mic_row;
        test_call_speaker_row.sensitive = sensitive || active_device_test_row == test_call_speaker_row;
        test_call_camera_row.sensitive = sensitive || active_device_test_row == test_call_camera_row;
        test_msg_mic_row.sensitive = sensitive || active_device_test_row == test_msg_mic_row;
        test_msg_camera_row.sensitive = sensitive || active_device_test_row == test_msg_camera_row;
    }

    private void set_call_rows_sensitive(bool sensitive) {
        call_mic_row.sensitive = sensitive;
        call_speaker_row.sensitive = sensitive;
        call_camera_row.sensitive = sensitive;
    }

    private void set_message_rows_sensitive(bool sensitive) {
        msg_mic_row.sensitive = sensitive;
        msg_camera_row.sensitive = sensitive;
    }

}
