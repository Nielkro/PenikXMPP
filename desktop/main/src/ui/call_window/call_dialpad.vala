using Gtk;

public class Dino.Ui.CallDialpad : Gtk.Popover {

    public signal void digit_pressed(char digit);

    private const string[] BUTTON_LABELS = {
        "1", "2", "3",
        "4", "5", "6",
        "7", "8", "9",
        "*", "0", "#"
    };

    private const string[] BUTTON_SUBLABELS = {
        "", "ABC", "DEF",
        "GHI", "JKL", "MNO",
        "PQRS", "TUV", "WXYZ",
        "", "+", ""
    };

    // Debounce: prevent double-sending within 80ms
    private int64 last_digit_time = 0;
    private char last_digit_char = '\0';
    private const int64 DEBOUNCE_US = 80000; // 80ms in microseconds

    public CallDialpad() {
        var grid = new Grid() {
            row_spacing = 6,
            column_spacing = 6,
            margin_start = 12,
            margin_end = 12,
            margin_top = 12,
            margin_bottom = 12
        };

        for (int i = 0; i < BUTTON_LABELS.length; i++) {
            int row = i / 3;
            int col = i % 3;

            var box = new Box(Orientation.VERTICAL, 0) {
                halign = Align.CENTER,
                valign = Align.CENTER
            };

            var main_label = new Label(BUTTON_LABELS[i]) {
                halign = Align.CENTER
            };
            main_label.add_css_class("dtmf-digit");

            box.append(main_label);

            if (BUTTON_SUBLABELS[i] != "") {
                var sub_label = new Label(BUTTON_SUBLABELS[i]) {
                    halign = Align.CENTER
                };
                sub_label.add_css_class("dtmf-sublabel");
                sub_label.add_css_class("dim-label");
                box.append(sub_label);
            }

            var button = new Button() {
                child = box,
                width_request = 64,
                height_request = 52
            };
            button.add_css_class("flat");
            button.add_css_class("dtmf-button");

            string digit_str = BUTTON_LABELS[i];
            button.clicked.connect(() => {
                // Debounce: ignore same digit within 80ms
                int64 now = GLib.get_monotonic_time();
                if (digit_str[0] == last_digit_char && (now - last_digit_time) < DEBOUNCE_US) {
                    debug("DTMF debounce: ignoring duplicate '%c' within 80ms", digit_str[0]);
                    return;
                }
                last_digit_char = digit_str[0];
                last_digit_time = now;

                digit_pressed(digit_str[0]);
            });

            grid.attach(button, col, row, 1, 1);
        }

        this.set_child(grid);
        this.has_arrow = true;
        this.position = PositionType.TOP;
    }

    /**
     * Compatibility hook for CallBottomBar cleanup.
     *
     * The dialpad is intentionally media-backend free; DTMF is sent through the
     * active call engine instead of a local UI tone pipeline.
     */
    public void shutdown() {
    }
}
