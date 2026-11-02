using Gtk;

namespace Dino.Ui {

// Manual compaction changes only the wide layout. The navigation split view
// continues to own narrow-window navigation, including its native Back action.
public class ConversationSidebarLayout : Object {
    private Adw.NavigationSplitView navigation;
    private Widget full_header;
    private Widget toggle_strip;
    private Button toggle_button;
    private Widget compact_window_controls;
    private Widget compact_menu;
    private double full_min_width;
    private double full_max_width;
    private double full_width_fraction;
    private bool requested_ = false;
    private bool available_ = true;
    private ulong collapsed_handler;
    private ulong clicked_handler;
    private ulong controls_handler;

    public signal void compact_changed(bool compact);
    public bool compact { get; private set; default = false; }

    public bool compact_requested {
        get { return requested_; }
        set {
            if (requested_ == value) return;
            requested_ = value;
            update_layout();
        }
    }

    public bool available {
        get { return available_; }
        set {
            if (available_ == value) return;
            available_ = value;
            update_layout();
        }
    }

    public ConversationSidebarLayout(Adw.NavigationSplitView navigation,
            Widget full_header, Widget toggle_strip, Button toggle_button,
            Widget compact_window_controls, Widget compact_menu) {
        this.navigation = navigation;
        this.full_header = full_header;
        this.toggle_strip = toggle_strip;
        this.toggle_button = toggle_button;
        this.compact_window_controls = compact_window_controls;
        this.compact_menu = compact_menu;
        full_min_width = navigation.min_sidebar_width;
        full_max_width = navigation.max_sidebar_width;
        full_width_fraction = navigation.sidebar_width_fraction;

        // Clicking the handle should not pull focus away from a draft. Native
        // keyboard focus and activation remain available on this button.
        toggle_button.focus_on_click = false;
        connect_signals_weak(this);
        update_layout();
    }

    // Vala constructor closures also retain their enclosing `this`, even when
    // their body uses a WeakRef. Create them in a static scope instead.
    private static void connect_signals_weak(ConversationSidebarLayout owner) {
        WeakRef layout_weak = WeakRef(owner);
        owner.collapsed_handler = owner.navigation.notify["collapsed"].connect(() => {
            var layout = (ConversationSidebarLayout?) layout_weak.get();
            if (layout != null) ((!) layout).update_layout();
        });
        owner.clicked_handler = owner.toggle_button.clicked.connect(() => {
            var layout = (ConversationSidebarLayout?) layout_weak.get();
            if (layout != null && !((!) layout).navigation.collapsed && ((!) layout).available)
                ((!) layout).compact_requested = !((!) layout).compact_requested;
        });
        if (owner.compact_window_controls is WindowControls) {
            owner.controls_handler = owner.compact_window_controls.notify["empty"].connect(() => {
                var layout = (ConversationSidebarLayout?) layout_weak.get();
                if (layout != null) ((!) layout).update_controls();
            });
        }
    }

    private void update_layout() {
        bool next_compact = requested_ && available_ && !navigation.collapsed;
        // Restore the full row/header size before entering the single-pane
        // layout. Never alter show_content or collapsed from this controller.
        navigation.min_sidebar_width = next_compact ? 72 : full_min_width;
        navigation.max_sidebar_width = next_compact ? 72 : full_max_width;
        navigation.sidebar_width_fraction = next_compact ? 0.0 : full_width_fraction;
        var window = full_header.get_root() as Gtk.Window;
        Widget? focused = window == null ? null : window.get_focus();
        bool hides_focus = next_compact && focused != null &&
            (focused == full_header || focused.is_ancestor(full_header));
        full_header.visible = !next_compact;
        toggle_strip.visible = available_ && !navigation.collapsed;
        compact_menu.visible = next_compact;
        bool changed = compact != next_compact;
        compact = next_compact;
        update_controls();
        update_button();
        if (hides_focus) toggle_button.grab_focus();
        if (changed) compact_changed(compact);
    }

    private void update_controls() {
        var controls = compact_window_controls as WindowControls;
        compact_window_controls.visible = compact && (controls == null || !controls.empty);
    }

    private void update_button() {
        string label = compact ? _("Expand chat list") : _("Collapse chat list");
        // These symbolic icons have native RTL variants; GTK selects them.
        var icon = toggle_button.get_child() as Image;
        if (icon == null) {
            toggle_button.icon_name = "pan-start-symbolic";
            icon = toggle_button.get_child() as Image;
        }
        if (icon != null) {
            icon.icon_name = compact ? "pan-end-symbolic" : "pan-start-symbolic";
            icon.pixel_size = 10;
        }
        toggle_button.tooltip_text = Util.string_if_tooltips_active(label);
        toggle_button.update_property(AccessibleProperty.LABEL, label, -1);
    }

    protected override void dispose() {
        if (collapsed_handler != 0) {
            navigation.disconnect(collapsed_handler);
            collapsed_handler = 0;
        }
        if (clicked_handler != 0) {
            toggle_button.disconnect(clicked_handler);
            clicked_handler = 0;
        }
        if (controls_handler != 0) {
            compact_window_controls.disconnect(controls_handler);
            controls_handler = 0;
        }
        base.dispose();
    }
}

}
