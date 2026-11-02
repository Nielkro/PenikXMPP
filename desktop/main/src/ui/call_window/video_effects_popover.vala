using Gtk;

private class Dino.Ui.VideoEffectAdjustmentRow : Gtk.Box {
    public Scale scale { get; private set; }
    private Label value_label = new Label("0%") { xalign=1 };

    public VideoEffectAdjustmentRow(string title, int minimum, int maximum) {
        Object(orientation: Orientation.VERTICAL, spacing: 2);
        var labels = new Box(Orientation.HORIZONTAL, 6);
        labels.append(new Label(title) { xalign=0, hexpand=true });
        labels.append(value_label);
        scale = new Scale.with_range(Orientation.HORIZONTAL, minimum, maximum, 1) {
            draw_value=false, digits=0, hexpand=true
        };
        scale.set_value(0);
        scale.update_property(AccessibleProperty.LABEL, title, -1);
        // A bound object method gives GTK a weak receiver; capturing this
        // scale inside its own callback would keep the row alive after hangup.
        scale.value_changed.connect(update_value_label);
        append(labels);
        append(scale);
    }

    private void update_value_label() {
        value_label.label = _("%d%%").printf((int) Math.round(scale.get_value()));
    }
}

/** Call-scoped controls; opening and backend synchronization never apply effects. */
public class Dino.Ui.VideoEffectsPopover : Gtk.Popover {
    public signal void background_image_requested(uint builtin_choice, uint64 request_generation);
    private uint64 image_request_generation = 1;
    private uint image_menu_choice = 3;
    private bool image_staging = false;
    public bool has_pending_background_image { get { return image_staging; } }
    private DropDown background_choice;
    private Box background_row;
    private Scale background_strength_scale;
    private Box background_strength_row;
    private DropDown background_color_choice;
    private Box background_color_row;
    private CheckButton framing_button = new CheckButton.with_label(_("Automatic framing"));
    public signal void effect_selected(Plugins.JmiVideoEffectSelection selection);
    public Plugins.JmiVideoEffectKind current_effect { get; private set; default=Plugins.JmiVideoEffectKind.OFF; }
    private Plugins.JmiVideoEffectSelection selection = new Plugins.JmiVideoEffectSelection(Plugins.JmiVideoEffectKind.OFF);
    private bool updating = false;
    private bool pending_selection = false;
    private CheckButton original_button = new CheckButton.with_label(_("Original"));
    private CheckButton grayscale_button = new CheckButton.with_label(_("Grayscale"));
    private CheckButton warm_tone_button = new CheckButton.with_label(_("Warm tone"));
    private CheckButton cold_tone_button = new CheckButton.with_label(_("Cold tone"));
    private CheckButton sepia_button = new CheckButton.with_label(_("Sepia"));
    private CheckButton[] preset_buttons;
    private Plugins.JmiVideoEffectKind[] preset_kinds;
    private Label status_label = new Label("") { xalign=0, wrap=true, max_width_chars=34 };
    private Scale brightness_scale;
    private Scale contrast_scale;
    private Scale saturation_scale;
    private Scale sharpness_scale;
    private DropDown glasses_choice;
    private DropDown hat_choice;
    private DropDown beard_choice;
    private DropDown accessory_choice;
    private DropDown scene_choice;
    private CheckButton touch_up_button = new CheckButton.with_label(_("Gentle touch-up"));
    private CheckButton low_light_button = new CheckButton.with_label(_("Low-light enhancement"));
    private Box glasses_row;
    private Box hat_row;
    private Box beard_row;
    private Box accessory_row;
    private Box scene_row;
    public Button reset_button { get; private set; }

    public VideoEffectsPopover() {
        var content = new Box(Orientation.VERTICAL, 10) {
            margin_top=12, margin_bottom=12, margin_start=12, margin_end=12,
            width_request=260
        };
        var heading = new Label(_("Video effects")) { xalign=0 };
        heading.add_css_class("heading");
        content.append(heading);
        content.append(new Label(_("Video filter")) { xalign=0 });
        preset_kinds = {
            Plugins.JmiVideoEffectKind.OFF, Plugins.JmiVideoEffectKind.GRAYSCALE,
            Plugins.JmiVideoEffectKind.WARM_TONE, Plugins.JmiVideoEffectKind.COLD_TONE,
            Plugins.JmiVideoEffectKind.SEPIA, Plugins.JmiVideoEffectKind.LIGHT_LEAK,
            Plugins.JmiVideoEffectKind.DREAMY, Plugins.JmiVideoEffectKind.PRISM_LIGHT,
            Plugins.JmiVideoEffectKind.FISHEYE, Plugins.JmiVideoEffectKind.VINTAGE_TV,
            Plugins.JmiVideoEffectKind.FROSTED_GLASS, Plugins.JmiVideoEffectKind.DUO_TONE,
            Plugins.JmiVideoEffectKind.UNDERWATER
        };
        preset_buttons = {
            original_button, grayscale_button, warm_tone_button, cold_tone_button, sepia_button,
            new CheckButton.with_label(_("Light leak")), new CheckButton.with_label(_("Dreamy")),
            new CheckButton.with_label(_("Prism light")), new CheckButton.with_label(_("Fisheye")),
            new CheckButton.with_label(_("Vintage TV")), new CheckButton.with_label(_("Frosted glass")),
            new CheckButton.with_label(_("Duo tone")), new CheckButton.with_label(_("Underwater"))
        };
        foreach (CheckButton button in preset_buttons) {
            if (button != original_button) button.set_group(original_button);
            content.append(button);
        }
        original_button.active = true;
        foreach (CheckButton button in preset_buttons) {
            button.toggled.connect(on_preset_changed);
        }
        brightness_scale = add_adjustment(content, _("Brightness"), -100, 100);
        contrast_scale = add_adjustment(content, _("Contrast"), -100, 100);
        saturation_scale = add_adjustment(content, _("Saturation"), -100, 100);
        sharpness_scale = add_adjustment(content, _("Sharpness"), 0, 100);
        foreach (Scale scale in new Scale[] { brightness_scale, contrast_scale, saturation_scale, sharpness_scale }) {
            scale.value_changed.connect(on_adjustments_changed);
        }
        background_row = add_choice(content, _("Background"), {
            _("Off"), _("Blur"), _("Solid colour"), _("Living room"), _("Office"),
            _("Cafe"), _("Stones"), _("Food"), _("Abstract"), _("Beach"),
            _("Sunset"), _("Celebration"), _("Forest"), _("Choose image…")
        }, out background_choice);
        background_strength_row = new Box(Orientation.VERTICAL, 2);
        background_strength_scale = add_adjustment(background_strength_row, _("Background blur"), 0, 100);
        content.append(background_strength_row);
        background_color_row = add_choice(content, _("Background colour"),
            { _("Dark grey"), _("Light grey"), _("Blue"), _("Green"), _("Purple") }, out background_color_choice);
        background_choice.notify["selected"].connect(on_background_changed);
        background_color_choice.notify["selected"].connect(on_background_color_changed);
        background_strength_scale.value_changed.connect(on_background_strength_changed);
        framing_button.toggled.connect(on_framing_changed);
        content.append(framing_button);
        glasses_row = add_choice(content, _("Glasses"),
            { _("Off"), _("Sunglasses"), _("Round glasses"), _("Rectangular glasses") }, out glasses_choice);
        hat_row = add_choice(content, _("Hat"),
            { _("Off"), _("Cap"), _("Cowboy hat"), _("Top hat") }, out hat_choice);
        beard_row = add_choice(content, _("Beard"),
            { _("Off"), _("Moustache"), _("Goatee"), _("Full beard") }, out beard_choice);
        accessory_row = add_choice(content, _("Face accessory"),
            { _("Off"), _("Puppy"), _("Karaoke microphone") }, out accessory_choice);
        scene_row = add_choice(content, _("Animation"),
            { _("Off"), _("Fireworks"), _("Confetti"), _("Stars"), _("Football") }, out scene_choice);
        foreach (DropDown choice in new DropDown[] {
                glasses_choice, hat_choice, beard_choice, accessory_choice, scene_choice }) {
            choice.notify["selected"].connect(on_decoration_changed);
        }
        touch_up_button.toggled.connect(on_decoration_changed);
        low_light_button.toggled.connect(on_decoration_changed);
        content.append(touch_up_button);
        content.append(low_light_button);
        status_label.add_css_class("dim-label");
        content.append(status_label);
        var actions = new Box(Orientation.HORIZONTAL, 8);
        reset_button = new Button.with_label(_("Off")) { hexpand=true };
        reset_button.tooltip_text = _("Turn off all video effects");
        reset_button.clicked.connect(on_reset_clicked);
        var done = new Button.with_label(_("Done")) { hexpand=true };
        done.clicked.connect(popdown);
        actions.append(reset_button);
        actions.append(done);
        content.append(actions);
        var scroll = new ScrolledWindow() {
            hscrollbar_policy=PolicyType.NEVER, vscrollbar_policy=PolicyType.AUTOMATIC,
            propagate_natural_height=true, max_content_height=440, child=content
        };
        set_child(scroll);
    }

    private Box add_choice(Box content, string title, string[] choices, out DropDown dropdown) {
        var row = new Box(Orientation.VERTICAL, 4);
        row.append(new Label(title) { xalign=0 });
        var model = new StringList(null);
        foreach (string choice in choices) model.append(choice);
        dropdown = new DropDown(model, null) { hexpand=true };
        dropdown.update_property(AccessibleProperty.LABEL, title, -1);
        row.append(dropdown);
        row.visible = false;
        content.append(row);
        return row;
    }

    private static uint32 selected_color(uint choice) {
        uint32[] colors = { 0x303030, 0xdadada, 0x355c91, 0x416c4a, 0x68466f };
        return choice < colors.length ? colors[choice] : colors[0];
    }

    private void invalidate_image_request() {
        if (image_request_generation != uint64.MAX) image_request_generation++;
        image_staging = false;
    }

    private void on_background_changed() {
        if (updating) return;
        uint choice = background_choice.selected;
        if (choice > 13) return;
        invalidate_image_request();
        if (choice >= 3) {
            if (image_request_generation == uint64.MAX) return;
            image_menu_choice = choice;
            image_staging = true;
            // Conceal while decoding/staging a replacement; late or failed
            // image loads never silently expose the real background.
            selection = selection.with_background_settings(Plugins.JmiVideoBackgroundMode.SOLID,
                0, 0x303030, 0, selection.framing_mode);
            publish_selection();
            background_image_requested(choice == 13 ? 0 : choice - 2, image_request_generation);
            return;
        }
        Plugins.JmiVideoBackgroundMode mode = (Plugins.JmiVideoBackgroundMode) choice;
        selection = selection.with_background_settings(mode,
            mode == Plugins.JmiVideoBackgroundMode.BLUR ? 70 : 0,
            mode == Plugins.JmiVideoBackgroundMode.SOLID ? selected_color(background_color_choice.selected) : 0,
            0, selection.framing_mode);
        publish_selection();
    }

    private void on_background_strength_changed() {
        if (updating || selection.background_mode != Plugins.JmiVideoBackgroundMode.BLUR) return;
        selection = selection.with_background_settings(selection.background_mode,
            (int) Math.round(background_strength_scale.get_value()), 0, 0, selection.framing_mode);
        publish_selection();
    }

    private void on_background_color_changed() {
        if (updating || image_staging || selection.background_mode != Plugins.JmiVideoBackgroundMode.SOLID) return;
        selection = selection.with_background_settings(selection.background_mode, 0,
            selected_color(background_color_choice.selected), 0, selection.framing_mode);
        publish_selection();
    }

    private void on_framing_changed() {
        if (updating) return;
        selection = selection.with_background_settings(selection.background_mode,
            selection.background_strength, selection.background_color_rgb, selection.asset_id,
            framing_button.active ? Plugins.JmiVideoFramingMode.AUTO : Plugins.JmiVideoFramingMode.NONE);
        publish_selection();
    }

    public bool accepts_background_result(uint64 generation) {
        return image_staging && generation == image_request_generation;
    }

    public void finish_background_image(uint64 generation, uint asset_id) {
        if (!accepts_background_result(generation) || asset_id == 0) return;
        image_staging = false;
        selection = selection.with_background_settings(Plugins.JmiVideoBackgroundMode.IMAGE,
            0, 0, asset_id, selection.framing_mode);
        publish_selection();
    }

    public void fail_background_image(uint64 generation) {
        if (!accepts_background_result(generation)) return;
        image_staging = false;
        render_selection();
        status_label.label = _("The background image could not be loaded. Choose another image or turn the background off.");
    }

    private void on_decoration_changed() {
        if (updating) return;
        if (glasses_choice.selected > 3 || hat_choice.selected > 3 || beard_choice.selected > 3 ||
                accessory_choice.selected > 2 || scene_choice.selected > 4) return;
        selection = new Plugins.JmiVideoEffectSelection(selection.kind, selection.quality,
            selection.preset_id, selection.asset_id, selection.brightness, selection.contrast,
            selection.saturation, selection.sharpness, selection.background_mode,
            selection.background_strength, selection.background_color_rgb, selection.framing_mode,
            (Plugins.JmiVideoGlassesStyle) glasses_choice.selected,
            (Plugins.JmiVideoHatStyle) hat_choice.selected,
            (Plugins.JmiVideoBeardStyle) beard_choice.selected,
            (Plugins.JmiVideoFaceAccessory) accessory_choice.selected,
            touch_up_button.active, low_light_button.active,
            (Plugins.JmiVideoSceneEffect) scene_choice.selected);
        publish_selection();
    }

    private Scale add_adjustment(Box content, string title, int minimum, int maximum) {
        var row = new VideoEffectAdjustmentRow(title, minimum, maximum);
        content.append(row);
        return row.scale;
    }

    private void on_reset_clicked() {
        if (updating) return;
        invalidate_image_request();
        selection = new Plugins.JmiVideoEffectSelection(Plugins.JmiVideoEffectKind.OFF);
        publish_selection();
    }

    private void on_preset_changed() {
        if (updating) return;
        Plugins.JmiVideoEffectKind kind = selection.kind;
        for (int index = 0; index < preset_buttons.length; index++) {
            if (preset_buttons[index].active) {
                kind = preset_kinds[index];
                break;
            }
        }
        // Radio-group transitions may notify both the old and the new button.
        if (kind == selection.kind) return;
        selection = selection.with_color_settings(kind, selection.brightness,
            selection.contrast, selection.saturation, selection.sharpness);
        publish_selection();
    }

    private void on_adjustments_changed() {
        if (updating) return;
        selection = selection.with_color_settings(selection.kind,
            (int) Math.round(brightness_scale.get_value()),
            (int) Math.round(contrast_scale.get_value()),
            (int) Math.round(saturation_scale.get_value()),
            (int) Math.round(sharpness_scale.get_value()));
        publish_selection();
    }

    private void publish_selection() {
        pending_selection = true;
        render_selection();
        effect_selected(selection);
    }

    private void render_selection() {
        updating = true;
        current_effect = selection.kind;
        for (int index = 0; index < preset_buttons.length; index++) {
            preset_buttons[index].active = current_effect == preset_kinds[index];
        }
        brightness_scale.set_value(selection.brightness);
        contrast_scale.set_value(selection.contrast);
        saturation_scale.set_value(selection.saturation);
        sharpness_scale.set_value(selection.sharpness);
        if (selection.is_neutral()) background_color_choice.selected = 0;
        background_choice.selected = image_staging || selection.background_mode == Plugins.JmiVideoBackgroundMode.IMAGE
            ? image_menu_choice : (uint) selection.background_mode;
        background_strength_scale.set_value(selection.background_strength);
        for (uint color = 0; color < 5; color++)
            if (selected_color(color) == selection.background_color_rgb) background_color_choice.selected = color;
        framing_button.active = selection.framing_mode == Plugins.JmiVideoFramingMode.AUTO;
        background_strength_row.visible = selection.background_mode == Plugins.JmiVideoBackgroundMode.BLUR;
        background_color_row.visible = !image_staging && selection.background_mode == Plugins.JmiVideoBackgroundMode.SOLID;
        glasses_choice.selected = (uint) selection.glasses_style;
        hat_choice.selected = (uint) selection.hat_style;
        beard_choice.selected = (uint) selection.beard_style;
        accessory_choice.selected = (uint) selection.face_accessory;
        scene_choice.selected = (uint) selection.scene_effect;
        touch_up_button.active = selection.touch_up;
        low_light_button.active = selection.low_light;
        updating = false;
    }

    public void update_state(Plugins.JmiVideoEffectCapabilities capabilities,
            Plugins.JmiVideoEffectStatus status, string? unavailable_hint = null) {
        bool terminal = !capabilities.available ||
            status.state == Plugins.JmiVideoEffectApplyState.UNAVAILABLE;
        // An older acknowledgement must not move a slider back during a drag.
        if (!pending_selection || selection.matches(status.selection) || terminal) {
            selection = status.selection;
            pending_selection = false;
            render_selection();
        }
        original_button.sensitive = reset_button.sensitive = capabilities.available;
        for (int index = 0; index < preset_buttons.length; index++) {
            Plugins.JmiVideoEffectKind kind = preset_kinds[index];
            bool supported = capabilities.supports_kind(kind);
            bool show_unavailable_context = !capabilities.available &&
                (kind == Plugins.JmiVideoEffectKind.GRAYSCALE || kind == Plugins.JmiVideoEffectKind.WARM_TONE);
            preset_buttons[index].visible = kind == Plugins.JmiVideoEffectKind.OFF ||
                supported || show_unavailable_context || current_effect == kind;
            preset_buttons[index].sensitive = supported;
        }
        brightness_scale.sensitive = capabilities.available && capabilities.brightness_supported;
        contrast_scale.sensitive = capabilities.available && capabilities.contrast_supported;
        saturation_scale.sensitive = capabilities.available && capabilities.saturation_supported;
        sharpness_scale.sensitive = capabilities.available && capabilities.sharpness_supported;
        background_row.visible = (capabilities.supported_background_mask & ~1U) != 0 ||
            selection.background_mode != Plugins.JmiVideoBackgroundMode.NONE;
        background_choice.sensitive = capabilities.available &&
            (capabilities.supported_background_mask & 15U) == 15U;
        background_strength_scale.sensitive = capabilities.available && (capabilities.supported_background_mask & 2U) != 0;
        background_color_choice.sensitive = capabilities.available && (capabilities.supported_background_mask & 4U) != 0;
        framing_button.visible = capabilities.auto_framing_supported || framing_button.active;
        framing_button.sensitive = capabilities.available && capabilities.auto_framing_supported;
        update_choice(glasses_row, glasses_choice, capabilities.available,
            capabilities.supported_glasses_mask, (uint) selection.glasses_style);
        update_choice(hat_row, hat_choice, capabilities.available,
            capabilities.supported_hat_mask, (uint) selection.hat_style);
        update_choice(beard_row, beard_choice, capabilities.available,
            capabilities.supported_beard_mask, (uint) selection.beard_style);
        update_choice(accessory_row, accessory_choice, capabilities.available,
            capabilities.supported_face_accessory_mask, (uint) selection.face_accessory);
        update_choice(scene_row, scene_choice, capabilities.available,
            capabilities.supported_scene_effect_mask, (uint) selection.scene_effect);
        touch_up_button.visible = capabilities.touch_up_supported || selection.touch_up;
        touch_up_button.sensitive = capabilities.available && capabilities.touch_up_supported;
        low_light_button.visible = capabilities.low_light_supported || selection.low_light;
        low_light_button.sensitive = capabilities.available && capabilities.low_light_supported;
        // Keep one owned string alive through the GTK setter. A conditional
        // mixing the borrowed hint and an owned result can release Vala's
        // temporary before gtk_label_set_label consumes it.
        string display_text;
        if (!capabilities.available && unavailable_hint != null) {
            display_text = (!) unavailable_hint;
        } else if (pending_selection && !selection.matches(status.selection)) {
            display_text = _("Applying…");
        } else {
            display_text = status_text(status);
        }
        status_label.label = image_staging ? _("Loading background…") : display_text;
    }

    private void update_choice(Box row, DropDown dropdown, bool available,
            uint32 supported_mask, uint selected) {
        row.visible = (supported_mask & ~1U) != 0 || selected != 0;
        // Each currently shipped category publishes a complete set of styles.
        // A partial capability set must not expose unsupported menu entries.
        uint count = dropdown.model != null ? dropdown.model.get_n_items() : 0;
        uint32 complete = count > 0 && count < 32 ? (1U << count) - 1U : 0;
        dropdown.sensitive = available && complete != 0 && (supported_mask & complete) == complete;
    }

    private static string status_text(Plugins.JmiVideoEffectStatus status) {
        switch (status.state) {
            case Plugins.JmiVideoEffectApplyState.IDLE: return _("Off");
            case Plugins.JmiVideoEffectApplyState.ACCEPTED: return _("Applying…");
            case Plugins.JmiVideoEffectApplyState.APPLIED:
                return status.selection.is_neutral() ? _("Off") : _("Active");
            case Plugins.JmiVideoEffectApplyState.DEGRADED: return _("Degraded");
            case Plugins.JmiVideoEffectApplyState.UNAVAILABLE: return _("Unavailable");
            case Plugins.JmiVideoEffectApplyState.FAILED: return _("Failed");
            default: return _("Unavailable");
        }
    }
}

/** A single bounded static-image decode, outside GTK and the capture lane. */
internal class Dino.Ui.VideoBackgroundImageLoader : Object {
    private class DecodeResult : Object {
        public Plugins.JmiVideoBackgroundImage? image;
        public Error? error;
    }

    private static uint32 png_word(uint8[] data, size_t offset) {
        return ((uint32) data[offset] << 24) | ((uint32) data[offset + 1] << 16) |
            ((uint32) data[offset + 2] << 8) | (uint32) data[offset + 3];
    }

    private static void require_static_png(uint8[] data, size_t count, Cancellable? cancellable) throws IOError {
        // GdkPixbuf's native PNG loader exposes APNG as a static fallback image.
        // Inspect only bounded chunk headers; the decoder still checks pixels.
        size_t offset = 8;
        while (offset < count) {
            if (cancellable != null && ((!) cancellable).is_cancelled())
                throw new IOError.CANCELLED("Background image loading was cancelled");
            size_t remaining = count - offset;
            if (remaining < 12)
                throw new IOError.INVALID_DATA("The background PNG has a truncated chunk");
            uint32 length = png_word(data, offset);
            if ((size_t) length > remaining - 12)
                throw new IOError.INVALID_DATA("The background PNG has an invalid chunk length");
            uint32 type = png_word(data, offset + 4);
            if (offset == 8 && (type != 0x49484452 || length != 13)) // IHDR
                throw new IOError.INVALID_DATA("The background PNG has an invalid header");
            if (type == 0x6163544c || type == 0x6663544c || type == 0x66644154) // acTL, fcTL, fdAT
                throw new IOError.INVALID_DATA("Choose a static PNG background image, not an animated PNG");
            if (type == 0x49454e44) { // IEND
                if (length != 0)
                    throw new IOError.INVALID_DATA("The background PNG has an invalid end chunk");
                // Preserve the existing decoder's handling of trailing bytes.
                return;
            }
            offset += (size_t) length + 12;
        }
        throw new IOError.INVALID_DATA("The background PNG has no end chunk");
    }

    public static async Plugins.JmiVideoBackgroundImage load(File file, Cancellable? cancellable = null) throws Error {
        SourceFunc resume = load.callback;
        MainContext context = MainContext.ref_thread_default();
        var result = new DecodeResult();
        new Thread<void*>("dinox-background-image", () => {
            try { result.image = decode(file, cancellable); }
            catch (Error e) { result.error = e; }
            var idle = new IdleSource();
            idle.set_callback((owned) resume);
            idle.attach(context);
            return null;
        });
        yield;
        if (result.error != null) throw (!) result.error;
        if (result.image == null) throw new IOError.INVALID_DATA("No background pixels were decoded");
        return (!) result.image;
    }

    internal static Plugins.JmiVideoBackgroundImage decode(File file, Cancellable? cancellable = null) throws Error {
        FileInfo info = file.query_info(FileAttribute.STANDARD_SIZE + "," + FileAttribute.STANDARD_TYPE,
            FileQueryInfoFlags.NONE, cancellable);
        if (info.get_file_type() != FileType.REGULAR || info.get_size() <= 0 || info.get_size() > 8388608)
            throw new IOError.INVALID_DATA("The background image must be a regular file up to 8 MiB");
        // Limit the actual read too; a file may grow after query_info().
        InputStream stream = file.read(cancellable);
        uint8[] data = new uint8[8388609];
        size_t count = 0;
        try { stream.read_all(data, out count, cancellable); }
        finally { try { stream.close(); } catch (Error ignored) { } }
        if (count == 0 || count > 8388608)
            throw new IOError.INVALID_DATA("The background image exceeds the encoded image bound");
        if (cancellable != null && ((!) cancellable).is_cancelled())
            throw new IOError.CANCELLED("Background image loading was cancelled");
        string format;
        if (count >= 8 && data[0] == 137 && data[1] == 80 && data[2] == 78 && data[3] == 71 &&
                data[4] == 13 && data[5] == 10 && data[6] == 26 && data[7] == 10) {
            require_static_png(data, count, cancellable);
            format = "png";
        }
        else if (count >= 3 && data[0] == 255 && data[1] == 216 && data[2] == 255) format = "jpeg";
        else throw new IOError.NOT_SUPPORTED("Choose a static PNG or JPEG background image");
        var loader = new Gdk.PixbufLoader.with_type(format);
        bool valid_size = false;
        ulong size_handler = loader.size_prepared.connect((width, height) => {
            valid_size = width > 0 && height > 0 && width <= 8192 && height <= 8192 &&
                (uint64) width * height <= 16777216;
            if (!valid_size) { loader.set_size(1, 1); return; }
            double factor = double.min(1.0, double.min(1920.0 / width, 1920.0 / height));
            factor = double.min(factor, Math.sqrt(2073600.0 / ((double) width * height)));
            loader.set_size(int.max(1, (int) Math.floor(width * factor)),
                int.max(1, (int) Math.floor(height * factor)));
        });
        try {
            loader.write(data[0:count]);
            loader.close();
        } catch (Error e) {
            loader.disconnect(size_handler);
            try { loader.close(); } catch (Error ignored) { }
            throw e;
        }
        loader.disconnect(size_handler);
        Gdk.Pixbuf? decoded = loader.get_pixbuf();
        if (!valid_size || decoded == null)
            throw new IOError.INVALID_DATA("The background image is oversized or invalid");
        Gdk.Pixbuf? oriented = ((!) decoded).apply_embedded_orientation();
        if (oriented == null) throw new IOError.INVALID_DATA("The background image could not be oriented");
        if (cancellable != null && ((!) cancellable).is_cancelled())
            throw new IOError.CANCELLED("Background image loading was cancelled");
        return new Plugins.JmiVideoBackgroundImage((uint) ((!) oriented).width, (uint) ((!) oriented).height,
            (uint) ((!) oriented).rowstride, ((!) oriented).has_alpha, ((!) oriented).read_pixel_bytes());
    }
}
