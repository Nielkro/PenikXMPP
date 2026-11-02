using Gtk;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui.OccupantMenu {

/** Passive, compact room labels. Hats describe occupants, never permissions. */
public class OccupantHatBadges : Widget {
    // This display-wide function remains supported; only the owning
    // GtkStyleContext type is deprecated in older Vala bindings.
    [CCode (cname = "gtk_style_context_add_provider_for_display", cheader_filename = "gtk/gtk.h")]
    private static extern void add_display_provider(Gdk.Display display, StyleProvider provider, uint priority);
    private const int SPACING = 4;
    private const int PREFERRED_LINE_WIDTH = 240;
    private Gee.ArrayList<Xep.Muc.Hat> displayed_hats = new Gee.ArrayList<Xep.Muc.Hat>();

    public int count { get { return displayed_hats.size; } }

    public OccupantHatBadges() {
        hexpand = true;
        valign = Align.START;
        add_css_class("occupant-hat-badges");
        ensure_hue_palette();
    }

    public void set_hats(Gee.List<Xep.Muc.Hat> hats) {
        // Preserve native widgets across ordinary status/role updates. Copy
        // metadata so later cache mutations cannot alias a recycled row.
        var next = new Gee.ArrayList<Xep.Muc.Hat>();
        foreach (var hat in hats) {
            string title = hat.title.make_valid().strip();
            if (title == "") continue;
            next.add(new Xep.Muc.Hat() {
                uri = hat.uri.make_valid(), title = title, hue = hat.hue
            });
        }
        bool same = next.size == displayed_hats.size;
        for (int i = 0; same && i < next.size; i++) {
            same = next[i].equals(displayed_hats[i]);
        }
        if (same) return;
        clear();
        foreach (var hat in next) {
            var badge = new Box(Orientation.HORIZONTAL, 4) {
                valign = Align.START,
                tooltip_text = hat.title
            };
            badge.add_css_class("occupant-hat-badge");
            string? hue_class = get_hue_css_class(hat.hue);
            if (hue_class != null) badge.add_css_class((!) hue_class);
            badge.append(new Image.from_icon_name("dino-hat-symbolic") { pixel_size = 12 });
            badge.append(new Label(hat.title) {
                ellipsize = Pango.EllipsizeMode.END, max_width_chars = 18,
                xalign = 0, use_markup = false
            });
            badge.update_property(AccessibleProperty.LABEL, hat.title, -1);
            badge.set_parent(this);
            displayed_hats.add(hat);
        }
        queue_resize();
    }

    // One bounded palette per display supports the color picker without
    // per-row providers, theme subscriptions, or server text in CSS.
    private static void ensure_hue_palette() {
        var display = Gdk.Display.get_default();
        if (display == null || display.get_data<CssProvider>("dinox-hat-palette") != null) return;
        var css = new StringBuilder();
        for (int hue = 0; hue < 360; hue++) {
            var color = ConversationDetails.HatFormChoices.hue_color(hue);
            css.append_printf(".occupant-hat-badge.hat-tone-%d { background-color: rgb(%d,%d,%d); }\n",
                hue, (int) Math.round(color.red * 255), (int) Math.round(color.green * 255),
                (int) Math.round(color.blue * 255));
        }
        var provider = new CssProvider();
        provider.load_from_string(css.str);
        add_display_provider(display, provider, STYLE_PROVIDER_PRIORITY_APPLICATION);
        display.set_data<CssProvider>("dinox-hat-palette", provider);
    }

    public static string? get_hue_css_class(string? hue_string) {
        if (hue_string == null || ((!) hue_string).strip() == "") return null;
        double hue;
        if (!double.try_parse((!) hue_string, out hue) || !hue.is_finite() ||
                hue < 0 || hue > 360) return null;
        int slot = ((int) Math.floor(hue + 0.5)) % 360;
        return "hat-tone-%d".printf(slot);
    }

    public void clear() {
        Widget? child;
        while ((child = get_first_child()) != null) ((!) child).unparent();
        displayed_hats.clear();
        queue_resize();
    }

    public override SizeRequestMode get_request_mode() {
        return SizeRequestMode.HEIGHT_FOR_WIDTH;
    }

    public override void measure(Orientation orientation, int for_size,
            out int minimum, out int natural, out int minimum_baseline,
            out int natural_baseline) {
        minimum_baseline = natural_baseline = -1;
        minimum = natural = 0;
        if (orientation == Orientation.HORIZONTAL) {
            int count = 0;
            for (Widget? child = get_first_child(); child != null;
                    child = child.get_next_sibling()) {
                int child_min, child_nat;
                child.measure(orientation, -1, out child_min, out child_nat, null, null);
                minimum = int.max(minimum, child_min);
                natural += child_nat;
                count++;
            }
            natural += int.max(0, count - 1) * SPACING;
            natural = int.max(minimum, int.min(natural, PREFERRED_LINE_WIDTH));
        } else {
            natural = layout_badges(for_size < 0 ? PREFERRED_LINE_WIDTH : for_size, false);
            minimum = natural;
        }
    }

    public override void size_allocate(int width, int height, int baseline) {
        layout_badges(width, true);
    }

    private int layout_badges(int available_width, bool allocate) {
        int width = int.max(1, available_width);
        int x = 0, y = 0, row_height = 0;
        for (Widget? child = get_first_child(); child != null;
                child = child.get_next_sibling()) {
            int child_width, child_height;
            child.measure(Orientation.HORIZONTAL, -1, null, out child_width, null, null);
            child_width = int.min(child_width, width);
            child.measure(Orientation.VERTICAL, child_width, null, out child_height, null, null);
            if (x > 0 && x + child_width > width) {
                y += row_height + SPACING;
                x = row_height = 0;
            }
            if (allocate) {
                var position = Graphene.Point() {
                    x = get_direction() == TextDirection.RTL ? width - x - child_width : x,
                    y = y
                };
                child.allocate(child_width, child_height, -1,
                    new Gsk.Transform().translate(position));
            }
            x += child_width + SPACING;
            row_height = int.max(row_height, child_height);
        }
        return y + row_height;
    }

    public override void dispose() {
        clear();
        base.dispose();
    }
}

public class ListRow : Object {

    private Grid main_grid;
    private AvatarPicture picture;
    public Label name_label;
    private Image status_image;
    private Box metadata_box;
    private Label role_label;
    private OccupantHatBadges hats_badges = new OccupantHatBadges();

    public Conversation? conversation;
    public Jid? jid;
    public Xmpp.Xep.Muc.Affiliation affiliation = Xmpp.Xep.Muc.Affiliation.NONE;

    private StreamInteractor? stream_interactor = null;
    private OccupantListItem? item = null;
    private ulong item_changed_handler_id = 0;
    private ViewModel.CompatAvatarPictureModel? avatar_model = null;
    private string avatar_display_name = "";
    private Dino.AvatarReadPolicy avatar_read_policy = Dino.AvatarReadPolicy.LOCAL_CACHE_ONLY;
    private bool avatar_read_policy_set = false;
    private string? status_css_class = null;
    private bool discarded = false;

    construct {
        Builder builder = new Builder.from_resource("/im/dinox/dinox/occupant_list_item.ui");
        main_grid = (Grid) builder.get_object("main_grid");
        picture = (AvatarPicture) builder.get_object("picture");
        name_label = (Label) builder.get_object("name_label");
        status_image = (Image) builder.get_object("status_image");
        metadata_box = (Box) builder.get_object("metadata_box");
        role_label = (Label) builder.get_object("role_label");
        metadata_box.append(hats_badges);
    }

    public ListRow() {
    }

    public void bind(StreamInteractor stream_interactor, Conversation conversation, OccupantListItem item) {
        unbind();
        this.stream_interactor = stream_interactor;
        this.conversation = conversation;
        this.item = item;
        item_changed_handler_id = connect_item_changed(this, item);
        refresh_from_item();
    }

    private static ulong connect_item_changed(ListRow source, OccupantListItem item) {
        // An instance-method closure captures self even when it uses WeakRef.
        WeakRef row_weak = WeakRef(source);
        return item.changed.connect(() => {
            ListRow? row = (ListRow?) row_weak.get();
            if (row != null) ((!) row).refresh_from_item();
        });
    }

    public void unbind() {
        cancel_deferred_sources();
        if (avatar_model != null) {
            ((!) avatar_model).cleanup();
            avatar_model = null;
        }
        avatar_display_name = "";
        avatar_read_policy_set = false;
        if (item_changed_handler_id != 0 && item != null) {
            if (SignalHandler.is_connected((!) item, item_changed_handler_id)) {
                SignalHandler.disconnect((!) item, item_changed_handler_id);
            }
            item_changed_handler_id = 0;
        }
        item = null;
        stream_interactor = null;
        conversation = null;
        jid = null;
        picture.model = null;
        main_grid.tooltip_text = null;
        name_label.tooltip_text = null;
        status_image.tooltip_text = null;
        clear_metadata();
        clear_status_css_class();
    }

    public void cancel_deferred_sources() {
        // Kept for popover/list lifecycle symmetry. Cache work is owned and
        // deduplicated by AvatarManager; rows hold no timeout or worker source.
    }

    public void refresh_cached_avatar(Jid updated_jid) {
        if (item == null || ((!) item).is_header || ((!) item).jid == null) return;
        if (!matches_avatar_identity((!) item, updated_jid)) return;

        set_avatar_model((!) item);
    }

    public void refresh_avatar() {
        if (item == null || ((!) item).is_header || ((!) item).jid == null) return;
        set_avatar_model((!) item);
    }

    public void cleanup() {
        if (discarded) return;
        unbind();
    }

    public void discard_for_list_cleanup() {
        if (discarded) return;
        discarded = true;
        cancel_deferred_sources();
        if (item_changed_handler_id != 0 && item != null) {
            if (SignalHandler.is_connected((!) item, item_changed_handler_id)) {
                SignalHandler.disconnect((!) item, item_changed_handler_id);
            }
            item_changed_handler_id = 0;
        }
        // The detached ListView owns the widget/model until GTK tears its
        // factory children down. Avoid hundreds of invisible property changes
        // here; they otherwise trigger costly relayout work on the main loop.
        avatar_model = null;
        item = null;
        stream_interactor = null;
        conversation = null;
        jid = null;
    }

    ~ListRow() {
        cleanup();
    }

    private void refresh_from_item() {
        if (item == null) return;

        OccupantListItem bound_item = (!) item;
        if (bound_item.is_header) {
            bind_header(bound_item);
        } else {
            bind_occupant(bound_item);
        }
    }

    private void bind_header(OccupantListItem item) {
        string header_title = item.header_title.make_valid();
        jid = null;
        affiliation = Xmpp.Xep.Muc.Affiliation.NONE;
        main_grid.margin_top = item.header_top ? 5 : 15;
        main_grid.margin_bottom = 3;
        picture.visible = false;
        status_image.visible = false;
        status_image.tooltip_text = null;
        clear_status_css_class();
        clear_metadata();
        name_label.use_markup = true;
        name_label.set_markup("<b>%s</b> <span alpha=\"55%%\">%d</span>".printf(Markup.escape_text(header_title), item.header_count));
        name_label.tooltip_text = header_title;
        name_label.add_css_class("dim-label");
        main_grid.tooltip_text = header_title;
        picture.model = null;
    }

    private void bind_occupant(OccupantListItem item) {
        if (item.jid == null) return;

        // XMPP text should already be UTF-8, but this GTK boundary must remain
        // safe even when cached or extension-provided display metadata is not.
        string display_name = item.display_name.make_valid();
        string status_text = item.status_text.make_valid();
        string hats_text = item.hats_text.make_valid();
        string role_text = get_visible_role_text(item);
        if (display_name != item.display_name) item.display_name = display_name;

        bool same_jid = jid != null && ((!) jid).equals((!) item.jid);
        jid = (!) item.jid;
        affiliation = item.affiliation;
        main_grid.margin_top = 3;
        main_grid.margin_bottom = 3;
        picture.visible = true;
        name_label.use_markup = false;
        name_label.remove_css_class("dim-label");
        name_label.label = display_name;
        name_label.tooltip_text = display_name;
        status_image.visible = true;
        status_image.icon_name = item.status_icon;
        status_image.tooltip_text = status_text;
        set_status_css_class(item.status_css_class);
        string metadata_text = role_text;
        if (hats_text != "") {
            if (metadata_text != "" && hats_text != "") metadata_text += " · ";
            metadata_text += hats_text;
        }
        main_grid.tooltip_text = metadata_text == ""
            ? "%s - %s".printf(display_name, status_text)
            : "%s - %s - %s".printf(display_name, status_text, metadata_text);

        role_label.label = role_text;
        role_label.tooltip_text = role_text == "" ? null : role_text;
        role_label.visible = role_text != "";
        hats_badges.set_hats(item.hats);
        hats_badges.visible = hats_badges.count > 0;
        metadata_box.visible = role_label.visible || hats_badges.visible;

        if (!same_jid || avatar_model == null || avatar_display_name != item.display_name ||
                !avatar_read_policy_set || avatar_read_policy != item.avatar_read_policy) {
            set_avatar_model(item);
        }
    }

    private void clear_metadata() {
        role_label.label = "";
        role_label.tooltip_text = null;
        role_label.visible = false;
        hats_badges.clear();
        hats_badges.visible = false;
        metadata_box.visible = false;
    }

    private string get_visible_role_text(OccupantListItem item) {
        if (!item.role_known) return "";

        MucMemberListSection section = MucMemberListSectionModel.classify(
            item.affiliation_known, item.affiliation, item.role_known,
            item.role);
        if (MucMemberListSectionModel.role_is_redundant(section, item.role)) {
            return "";
        }

        switch (item.role) {
            case Xmpp.Xep.Muc.Role.MODERATOR:
                return _("Moderator");
            case Xmpp.Xep.Muc.Role.VISITOR:
                return _("Visitor");
            default:
                // Participant is the normal room role. Keeping it implicit
                // avoids doubling the height of every ordinary member row.
                return "";
        }
    }

    private void set_avatar_model(OccupantListItem item) {
        if (avatar_model != null) {
            ((!) avatar_model).cleanup();
            avatar_model = null;
        }
        avatar_display_name = item.display_name;
        avatar_read_policy = item.avatar_read_policy;
        avatar_read_policy_set = true;
        if (stream_interactor == null || conversation == null || item.jid == null) {
            picture.model = new ViewModel.CompatAvatarPictureModel(null).add(item.display_name, item.display_name);
            return;
        }

        // Rows stay observer-free. One list-level handler refreshes only the
        // matching realized rows after the bounded cache/network worker emits.
        AvatarManager avatar_manager = ((!) stream_interactor).get_module<AvatarManager>(AvatarManager.IDENTITY);
        Jid primary_jid;
        Jid? secondary_jid;
        string color_id;
        avatar_manager.resolve_participant_avatar_identity((!) conversation, (!) item.jid,
            out primary_jid, out secondary_jid, out color_id);
        Bytes? image_bytes = avatar_manager.get_avatar_bytes_with_policy(
            ((!) conversation).account, primary_jid, item.avatar_read_policy);
        if (image_bytes == null && secondary_jid != null) {
            image_bytes = avatar_manager.get_avatar_bytes_with_policy(
                ((!) conversation).account, (!) secondary_jid, item.avatar_read_policy);
        }
        avatar_model = new ViewModel.CompatAvatarPictureModel(null).add(item.display_name, color_id, image_bytes);
        picture.model = avatar_model;
    }

    private bool matches_avatar_identity(OccupantListItem item, Jid updated_jid) {
        if (stream_interactor == null || conversation == null || item.jid == null) return false;

        AvatarManager avatar_manager = ((!) stream_interactor).get_module<AvatarManager>(AvatarManager.IDENTITY);
        Jid primary_jid;
        Jid? secondary_jid;
        avatar_manager.resolve_participant_avatar_jids((!) conversation, (!) item.jid,
            out primary_jid, out secondary_jid);
        return primary_jid.equals(updated_jid) || (secondary_jid != null && ((!) secondary_jid).equals(updated_jid));
    }

    private void set_status_css_class(string css_class) {
        if (status_css_class == css_class) return;
        clear_status_css_class();
        status_css_class = css_class;
        status_image.add_css_class(css_class);
    }

    private void clear_status_css_class() {
        if (status_css_class != null) {
            status_image.remove_css_class((!) status_css_class);
            status_css_class = null;
        }
    }

    public ListRow.label(string c, string text) {
        name_label.label = text;
        Widget? picture_parent = picture.get_parent();
        if (picture_parent != null) {
            ((!) picture_parent).visible = false;
        } else {
            picture.visible = false;
        }
        main_grid.attach(new Image.from_icon_name("list-add-symbolic") {
            pixel_size = 18,
            halign = Align.CENTER,
            valign = Align.CENTER
        }, 0, 0, 1, 1);
    }

    public Widget get_widget() {
        return main_grid;
    }
}

}
