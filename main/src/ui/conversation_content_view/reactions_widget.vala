using Gee;
using Gtk;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui.ConversationSummary {

public class ReactionsController : Object {
    public signal void box_activated(Widget widget);

    private Conversation conversation;
    private Account account;
    private ContentItem content_item;
    private StreamInteractor stream_interactor;

    private HashMap<string, Gee.List<Jid>> reactions = new HashMap<string, Gee.List<Jid>>();

    private ReactionsWidget? widget = null;
    private ulong reaction_added_handler_id = 0;
    private ulong reaction_removed_handler_id = 0;

    public ReactionsController(Conversation conversation, ContentItem content_item, StreamInteractor stream_interactor) {
        this.conversation = conversation;
        this.account = conversation.account;
        this.content_item = content_item;
        this.stream_interactor = stream_interactor;
    }

    public void init() {
        Gee.List<ReactionUsers> reactions = stream_interactor.get_module<Reactions>(Reactions.IDENTITY).get_item_reactions(conversation, content_item);
        foreach (ReactionUsers reaction_users in reactions) {
            foreach (Jid jid in reaction_users.jids) {
                reaction_added(reaction_users.reaction, jid);
            }
        }

        reaction_added_handler_id = stream_interactor.get_module<Reactions>(Reactions.IDENTITY).reaction_added.connect((account, content_item_id, jid, reaction) => {
            if (this.content_item.id == content_item_id) {
                reaction_added(reaction, jid);
            }
        });
        reaction_removed_handler_id = stream_interactor.get_module<Reactions>(Reactions.IDENTITY).reaction_removed.connect((account, content_item_id, jid, reaction) => {
            if (this.content_item.id == content_item_id) {
                reaction_removed(reaction, jid);
            }
        });
    }

    public void cleanup() {
        if (reaction_added_handler_id != 0) {
            stream_interactor.get_module<Reactions>(Reactions.IDENTITY).disconnect(reaction_added_handler_id);
            reaction_added_handler_id = 0;
        }
        if (reaction_removed_handler_id != 0) {
            stream_interactor.get_module<Reactions>(Reactions.IDENTITY).disconnect(reaction_removed_handler_id);
            reaction_removed_handler_id = 0;
        }
        if (widget != null) {
            widget.cleanup();
            widget = null;
        }
        reactions.clear();
    }

    private void initialize_widget() {
        widget = new ReactionsWidget();
        widget.emoji_picked.connect((emoji) => {
            stream_interactor.get_module<Reactions>(Reactions.IDENTITY).add_reaction(conversation, content_item, emoji);
        });
        widget.emoji_clicked.connect((emoji) => {
            if (account.bare_jid in reactions[emoji]) {
                stream_interactor.get_module<Reactions>(Reactions.IDENTITY).remove_reaction(conversation, content_item, emoji);
            } else {
                stream_interactor.get_module<Reactions>(Reactions.IDENTITY).add_reaction(conversation, content_item, emoji);
            }
        });
        box_activated(widget);
    }

    public void reaction_added(string reaction, Jid jid) {
        if (widget == null) {
            initialize_widget();
        }

        if (!reactions.has_key(reaction)) {
            reactions[reaction] = new ArrayList<Jid>(Jid.equals_func);
        }
        if (jid.equals_bare(account.bare_jid) && reactions[reaction].contains(jid)) {
            return;
        }
        reactions[reaction].add(jid);

        if (reactions[reaction].size == 0) return;

        widget.update_reaction(reaction, reactions[reaction].size, reactions[reaction].contains(account.bare_jid), update_tooltip(reaction));
    }

    public void reaction_removed(string reaction, Jid jid) {
        if (!reactions.has_key(reaction)) return;
        reactions[reaction].remove(jid);

        if (reactions[reaction].size > 0) {
            widget.update_reaction(reaction, reactions[reaction].size, reactions[reaction].contains(account.bare_jid), update_tooltip(reaction));
        } else {
            widget.remove_reaction(reaction);
            reactions.unset(reaction);
        }

        if (reactions.size == 0) {
            widget.cleanup();
            if (widget.get_parent() != null) widget.unparent();
            widget = null;
        }
    }

    private Gee.List<string> update_tooltip(string reaction) {
        var name_list = new ArrayList<string>();
        if (reactions[reaction].size > 0) {
            if (account.bare_jid in reactions[reaction]) {
                name_list.add(_("You"));
            }
            foreach (Jid jid in reactions[reaction]) {
                if (jid.equals(account.bare_jid)) continue;

                name_list.add(Util.get_participant_display_name(stream_interactor, conversation, jid));
            }
        }
        return name_list;
    }
}

public class ReactionsWidget : Widget {

    public signal void emoji_picked(string emoji);
    public signal void emoji_clicked(string emoji);

    private HashMap<string, Label> reaction_counts = new HashMap<string, Label>();
    private HashMap<string, Button> reaction_buttons = new HashMap<string, Button>();
    private HashMap<string, ulong?> reaction_clicked_handler_ids = new HashMap<string, ulong?>();
    private FlowBox flow = new FlowBox();
    private MenuButton? add_button;
    private EmojiChooser? chooser;
    private ulong emoji_picked_handler_id = 0;
    private bool cleaned_up = false;

    public ReactionsWidget() {
        this.margin_top = 2;
        this.halign = Align.FILL;
        this.valign = Align.START;
        this.hexpand = true;
        flow.orientation = Orientation.HORIZONTAL;
        flow.valign = Align.START;
        flow.row_spacing = flow.column_spacing = 5;
        flow.selection_mode = SelectionMode.NONE;
        flow.activate_on_single_click = false;
        flow.min_children_per_line = 1;
        flow.max_children_per_line = 10;
        flow.homogeneous = false;
        this.add_css_class("reaction-grid");
        flow.set_parent(this);

        add_button = new MenuButton() { tooltip_text= _("Add reaction") };
        add_button.add_css_class("pill");
        Util.menu_button_set_icon_with_size(add_button, "dino-emoticon-add-symbolic", 14);

        install_popup_factory(this, (!) add_button);
        insert_control((!) add_button, -1);
    }

    private static void install_popup_factory(ReactionsWidget owner, MenuButton button) {
        // GTK populates an EmojiChooser even while it is hidden. Avoid that
        // work for every historical reaction row until its menu is opened.
        // Static scope prevents the factory from retaining its owning row.
        WeakRef owner_weak = WeakRef(owner);
        button.set_create_popup_func((target) => {
            var current = owner_weak.get() as ReactionsWidget;
            if (current == null || ((!) current).cleaned_up ||
                    ((!) current).add_button != target || ((!) current).chooser != null) return;

            var popup = new EmojiChooser();
            ((!) current).chooser = popup;
            ((!) current).emoji_picked_handler_id = popup.emoji_picked.connect((emoji) => {
                var receiver = owner_weak.get() as ReactionsWidget;
                if (receiver != null && !((!) receiver).cleaned_up) {
                    ((!) receiver).emoji_picked(emoji);
                }
            });
            Util.set_menu_button_popover(target, popup);
        });
    }

    private int natural_line_width() {
        int columns = int.max(1, (int) flow.max_children_per_line);
        int[] widths = new int[columns];
        int count = 0;
        for (Widget? child = flow.get_first_child(); child != null;
                child = child.get_next_sibling()) {
            if (!child.should_layout()) continue;
            int natural;
            child.measure(Orientation.HORIZONTAL, -1, null, out natural,
                null, null);
            int column = count % columns;
            widths[column] = int.max(widths[column], natural);
            count++;
        }
        int width = 0;
        foreach (int column_width in widths) width += column_width;
        return width + int.max(0, int.min(count, columns) - 1) *
            (int) flow.column_spacing;
    }

    public override SizeRequestMode get_request_mode() {
        return SizeRequestMode.HEIGHT_FOR_WIDTH;
    }

    public override void measure(Orientation orientation, int for_size,
            out int minimum, out int natural, out int minimum_baseline,
            out int natural_baseline) {
        if (orientation == Orientation.HORIZONTAL) {
            flow.measure(orientation, for_size, out minimum, out natural,
                out minimum_baseline, out natural_baseline);
            // FlowBox requests only its minimum number of columns. A START
            // aligned container therefore received a single pill's width in
            // the real message grid, even when the body column was wide.
            natural = int.max(minimum, natural_line_width());
        } else {
            int layout_width = natural_line_width();
            if (for_size >= 0) layout_width = int.min(for_size, layout_width);
            flow.measure(orientation, layout_width, out minimum, out natural,
                out minimum_baseline, out natural_baseline);
        }
    }

    public override void size_allocate(int width, int height, int baseline) {
        // Accept the body's available width, but keep a short reaction row at
        // its natural width. Giving all of a wide chat to FlowBox would spread
        // its compact controls across the whole text column.
        int flow_width = int.min(width, natural_line_width());
        Gsk.Transform? transform = null;
        if (get_direction() == TextDirection.RTL) {
            Graphene.Point offset = Graphene.Point() {
                x = width - flow_width, y = 0
            };
            transform = new Gsk.Transform().translate(offset);
        }
        flow.allocate(flow_width, height, baseline, transform);
    }

    private void insert_control(Widget control, int position) {
        // Keep the actual buttons as the keyboard focus and activation
        // targets. The flow cells only arrange existing controls when the
        // conversation becomes narrower; they do not select or rebuild them.
        var cell = new FlowBoxChild() { focusable = false, halign = Align.START };
        cell.add_css_class("reaction-flow-child");
        cell.set_child(control);
        flow.insert(cell, position);
    }

    private void remove_control(Widget control) {
        var cell = control.get_parent() as FlowBoxChild;
        if (cell != null && ((!) cell).get_parent() == flow) {
            Util.clear_focus_before_detach(control);
            ((!) cell).set_child(null);
            flow.remove((!) cell);
        }
    }

    public void update_reaction(string reaction, int count, bool own, Gee.List<string> names) {
        if (cleaned_up) return;
        if (!reaction_buttons.has_key(reaction)) {
            Label reaction_label = new Label("<span size='small'>" + GLib.Markup.escape_text(reaction) + "</span>") { use_markup=true };
            Label count_label = new Label("") { use_markup=true };
            Button button = new Button();
            button.add_css_class("pill");
            Box reaction_box = new Box(Orientation.HORIZONTAL, 4) { halign=Align.CENTER };
            reaction_box.append(reaction_label);
            reaction_box.append(count_label);
            button.set_child(reaction_box);

            reaction_counts[reaction] = count_label;
            reaction_buttons[reaction] = button;

            // Insert immediately before the add control, preserving that
            // control's focus and popover across incoming reaction updates.
            insert_control(button, reaction_buttons.size - 1);

            reaction_clicked_handler_ids[reaction] = button.clicked.connect(() => {
                emoji_clicked(reaction);
            });
        }

        reaction_counts[reaction].label = "<span font_family='monospace' size='small'>" + count.to_string() + "</span>";
        if (own) {
            reaction_buttons[reaction].add_css_class("own-reaction");
        } else {
            reaction_buttons[reaction].remove_css_class("own-reaction");
        }

        // Build tooltip
        StringBuilder tooltip_builder = new StringBuilder ();
        for (int i = 0; i < names.size - 1; i++) {
            tooltip_builder.append(names[i]);
            if (i < names.size - 2) tooltip_builder.append(_(" , ").strip() + " ");
        }
        if (names.size > 1) {
            tooltip_builder.append(" " + _("and") + " ");
        }
        if (!names.is_empty) tooltip_builder.append(names[names.size - 1]);
        tooltip_builder.append(" " + _("reacted with %s").printf(reaction));
        reaction_buttons[reaction].set_tooltip_text(tooltip_builder.str);
    }

    public void remove_reaction(string reaction) {
        if (!reaction_buttons.has_key(reaction)) return;

        Button button = reaction_buttons[reaction];
        ulong? handler_id = reaction_clicked_handler_ids[reaction];
        if (handler_id != null && SignalHandler.is_connected(button, (!) handler_id)) {
            button.disconnect((!) handler_id);
        }
        reaction_clicked_handler_ids.unset(reaction);
        reaction_counts.unset(reaction);
        reaction_buttons.unset(reaction);
        remove_control(button);
        button.dispose();
    }

    public void cleanup() {
        if (cleaned_up) return;
        cleaned_up = true;
        if (add_button != null) ((!) add_button).set_create_popup_func(null);

        string[] reactions = new string[reaction_buttons.size];
        int i = 0;
        foreach (string reaction in reaction_buttons.keys) {
            reactions[i++] = reaction;
        }
        foreach (string reaction in reactions) {
            remove_reaction(reaction);
        }

        if (chooser != null && emoji_picked_handler_id != 0 &&
                SignalHandler.is_connected((!) chooser, emoji_picked_handler_id)) {
            ((!) chooser).disconnect(emoji_picked_handler_id);
        }
        emoji_picked_handler_id = 0;
        if (add_button != null) {
            Util.clear_focus_before_detach((!) add_button);
            Util.set_menu_button_popover((!) add_button, null);
            remove_control((!) add_button);
            ((!) add_button).dispose();
            add_button = null;
        }
        chooser = null;
    }

    public override void dispose() {
        cleanup();
        if (flow.get_parent() == this) flow.unparent();
        base.dispose();
    }
}

}
