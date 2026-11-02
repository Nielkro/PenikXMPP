using Gdk;
using Gee;
using Gtk;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui {

/**
 * - With given prefix: Complete from occupant list (sorted lexicographically)
 * - W/o prefix: Complete from received messages (most recent first)
 * - At the start (with ",") and in the middle of a text
 * - Backwards tabbing
 */
public class OccupantsTabCompletor : Object {

    private StreamInteractor stream_interactor;
    private Conversation? conversation;
    private TextView text_input;

    private Gee.List<string> completions = new ArrayList<string>();
    private bool active = false;
    private int index = -1;
    private TextMark? completion_start;
    private TextMark? completion_end;
    private string completion_suffix = "";
    private bool replacing_completion = false;

    public OccupantsTabCompletor(StreamInteractor stream_interactor, TextView text_input) {
        this.stream_interactor = stream_interactor;
        this.text_input = text_input;

        var text_input_key_events = new EventControllerKey();
        text_input_key_events.key_pressed.connect(on_text_input_key_press);
        text_input.add_controller(text_input_key_events);
        text_input.buffer.changed.connect(on_buffer_changed);
        text_input.buffer.mark_set.connect(on_buffer_mark_set);
    }

    public void initialize_for_conversation(Conversation conversation) {
        reset_completion();
        this.conversation = conversation;
    }

    public void unset_conversation() {
        this.conversation = null;
        reset_completion();
    }

    private void reset_completion() {
        if (completion_start != null && !((!) completion_start).get_deleted()) {
            text_input.buffer.delete_mark((!) completion_start);
        }
        if (completion_end != null && !((!) completion_end).get_deleted()) {
            text_input.buffer.delete_mark((!) completion_end);
        }
        completion_start = null;
        completion_end = null;
        completions.clear();
        active = false;
        index = -1;
    }

    private void on_buffer_changed() {
        if (!replacing_completion) reset_completion();
    }

    private void on_buffer_mark_set(TextIter location, TextMark mark) {
        if (!active || replacing_completion || completion_end == null) return;
        if (mark != text_input.buffer.get_insert() &&
                mark != text_input.buffer.get_selection_bound()) return;
        TextIter end;
        text_input.buffer.get_iter_at_mark(out end, (!) completion_end);
        if (location.get_offset() != end.get_offset()) reset_completion();
    }

    public bool on_text_input_key_press(uint keyval, uint keycode, Gdk.ModifierType state) {
        if (conversation == null) return false;
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            if (keyval == Key.Tab || keyval == Key.ISO_Left_Tab) {
                if ((state & (ModifierType.CONTROL_MASK | ModifierType.ALT_MASK |
                        ModifierType.SUPER_MASK)) != 0 ||
                        text_input.buffer.has_selection) {
                    reset_completion();
                    return false;
                }
                if (!active) {
                    TextIter cursor;
                    text_input.buffer.get_iter_at_mark(out cursor,
                        text_input.buffer.get_insert());
                    TextIter start = cursor;
                    TextIter previous = start;
                    while (previous.backward_char() &&
                            !previous.get_char().isspace()) {
                        start = previous;
                    }
                    TextIter end = cursor;
                    while (!end.is_end() && !end.get_char().isspace()) {
                        end.forward_char();
                    }
                    string word = text_input.buffer.get_text(start, cursor, true);
                    if (word == "") {
                        completions = generate_completions_from_messages();
                    } else {
                        completions = generate_completions_from_occupants(word);
                    }
                    if (completions.size > 0) {
                        // Replace only the word at the caret. A following
                        // space belongs to its separator; newlines and the
                        // rest of a multiline draft remain untouched.
                        bool followed_by_newline = !end.is_end() &&
                            end.get_char() == '\n';
                        if (!end.is_end() && end.get_char() == ' ') {
                            end.forward_char();
                        }
                        completion_suffix = start.get_offset() == 0 ? "," : "";
                        if (!followed_by_newline) completion_suffix += " ";
                        completion_start = text_input.buffer.create_mark(null,
                            start, true);
                        completion_end = text_input.buffer.create_mark(null,
                            end, false);
                        active = true;
                        index = -1;
                    }
                }
                if (active) {
                    next_completion(keyval == Key.ISO_Left_Tab ||
                        (state & ModifierType.SHIFT_MASK) != 0);
                    return true;
                }
            } else if (keyval != Key.Shift_L && keyval != Key.Shift_R && active) {
                reset_completion();
            }
        }
        return false;
    }

    private void next_completion(bool backwards) {
        if (backwards) {
            index = int.max(index, 0) - 1;
            if (index < 0) index = completions.size - 1;
        } else {
            index = (index + 1) % (completions.size);
        }
        TextIter start, end;
        text_input.buffer.get_iter_at_mark(out start, (!) completion_start);
        text_input.buffer.get_iter_at_mark(out end, (!) completion_end);
        string replacement = completions[index] + completion_suffix;
        replacing_completion = true;
        text_input.buffer.begin_user_action();
        text_input.buffer.delete(ref start, ref end);
        text_input.buffer.insert(ref start, replacement, replacement.length);
        text_input.buffer.place_cursor(start);
        text_input.buffer.end_user_action();
        replacing_completion = false;
    }

    private Gee.List<string> generate_completions_from_messages(string? prefix = null) {
        Gee.List<string> ret = new ArrayList<string>();
        Gee.List<ContentItem> content_items = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).get_n_latest(conversation, 10);
        for (int i = content_items.size - 1; i >= 0; i--) {
            string resourcepart = content_items[i].jid.resourcepart;
            Jid? own_nick = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_own_jid(conversation.counterpart, conversation.account);
            if (resourcepart != null && resourcepart != "" && (own_nick == null || resourcepart != own_nick.resourcepart) && !ret.contains(resourcepart)) {
                if (prefix != null && !resourcepart.to_string().down().has_prefix(prefix.down())) continue;
                ret.add(resourcepart);
            }
        }
        return ret;
    }

    private Gee.List<string> generate_completions_from_occupants(string prefix) {
        // First suggest nicks that have recently writen something
        Gee.List<string> ret = generate_completions_from_messages(prefix);

        // Then, suggest other nicks in alphabetical order
        Gee.List<Jid>? occupants = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_other_occupants(conversation.counterpart, conversation.account);
        Gee.List<string> filtered_occupants = new ArrayList<string>();
        if (occupants != null) {
            foreach (Jid jid in occupants) {
                string resourcepart = jid.resourcepart.to_string();
                if (resourcepart.down().has_prefix(prefix.down()) && !ret.contains(resourcepart)) {
                    filtered_occupants.add(resourcepart);
                }
            }
        }
        filtered_occupants.sort();

        ret.add_all(filtered_occupants);
        return ret;
    }
}

}
