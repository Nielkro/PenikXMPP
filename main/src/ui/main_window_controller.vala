using Gee;
using Gdk;
using Gtk;

using Dino.Entities;

namespace Dino.Ui {

public class MainWindowController : Object {

    private StreamInteractor stream_interactor;
    public Conversation? conversation { get; private set; }
    private Application app;
    private Database db;
    private MainWindow window;

    private ConversationViewController conversation_view_controller;
    
    // Flag to prevent re-entry during conversation selection
    private bool selecting_conversation = false;
    private bool initial_conversation_restore_pending = true;
    private bool initial_restore_selecting = false;
    private int initial_restore_conversation_id = -1;
    private uint initial_stack_state_timeout_id = 0;
    private uint initial_window_reveal_timeout_id = 0;
    private uint removed_conversation_settle_source_id = 0;
    private Conversation? pending_removed_conversation = null;
    private const uint INITIAL_STACK_STATE_DELAY_MS = 700;
    private const uint INITIAL_WINDOW_REVEAL_DELAY_MS = 650;
    private const string LAST_SELECTED_CONVERSATION_ID_SETTING = "last_selected_conversation_id";

    public MainWindowController(Application application, StreamInteractor stream_interactor, Database db) {
        this.app = application;
        this.stream_interactor = stream_interactor;
        this.db = db;
        this.initial_restore_conversation_id = get_stored_selected_conversation_id();

        ConversationManager conversation_manager = stream_interactor.get_module<
            ConversationManager>(ConversationManager.IDENTITY);
        conversation_manager.conversation_deactivated.connect_after(
            schedule_removed_conversation_settle);
        conversation_manager.conversation_hidden.connect_after(
            schedule_removed_conversation_settle);
        stream_interactor.account_removed.connect((_) => check_unset_conversation());

        SimpleAction jump_to_conversatio_message_action = new SimpleAction("jump-to-conversation-message", new VariantType("(ii)"));
        jump_to_conversatio_message_action.activate.connect((variant) => {
            int conversation_id = variant.get_child_value(0).get_int32();
            Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation_by_id(conversation_id);
            if (conversation == null || this.conversation == null || !this.conversation.equals(conversation)) return;

            int item_id = variant.get_child_value(1).get_int32();
            ContentItem? content_item = stream_interactor.get_module<ContentItemStore>(ContentItemStore.IDENTITY).get_item_by_id(conversation, item_id);

            select_conversation(conversation, false, false);
            window.conversation_view.conversation_frame.initialize_around_message(conversation, content_item);
        });
        app.add_action(jump_to_conversatio_message_action);

    }

    public void set_window(MainWindow window) {
        this.window = window;
        if (has_enabled_accounts_in_db()) {
            window.stack.opacity = 0;
        }

        this.conversation_view_controller = new ConversationViewController(window, window.conversation_view, stream_interactor);

        conversation_view_controller.search_menu_entry.button.bind_property("active", window.search_flap, "show-sidebar", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);

        window.search_flap.notify["show-sidebar"].connect(() => {
            if (window.search_flap.show_sidebar) {
                if (window.conversation_view.conversation_frame.conversation != null) {
                    reset_search_scope();
                }
                window.global_search.search_entry.grab_focus();
                window.global_search.search_entry.set_position((int)window.global_search.search_entry.text.length);
            }
        });
        window.global_search.selected_item.connect((item) => {
            select_conversation(item.conversation, false, false);
            window.conversation_view.conversation_frame.initialize_around_message(item.conversation, item);
            if (window.search_flap.collapsed) {
                close_search();
            }
        });

        window.welcome_placeholder.primary_button.clicked.connect(() => {
            bool created;
            ManageAccounts.AddAccountDialog.present_regular(stream_interactor, db, app.get_active_window(), false, out created);
        });
        window.welcome_placeholder.register_button.clicked.connect(() => {
            bool created;
            ManageAccounts.AddAccountDialog.present_regular(stream_interactor, db, app.get_active_window(), true, out created);
        });
        window.welcome_placeholder.secondary_button.clicked.connect(() => {
            ((Dino.Ui.Application) app).restore_from_backup();
        });
        window.accounts_placeholder.primary_button.clicked.connect(() => { app.activate_action("preferences", null); });
        window.conversation_selector.conversation_selected.connect((conversation) => {
            debug("MainWindowController: conversation_selector.conversation_selected received for %s", conversation != null ? conversation.counterpart.to_string() : "NULL");
            if (initial_conversation_restore_pending && !initial_restore_selecting) {
                debug("MainWindowController: Ignoring sidebar selection during initial restore");
                return;
            }
            select_conversation(conversation);
        });
        window.conversation_selector.conversation_activated.connect((activated) => {
            // Activating the current row after Back only restores navigation;
            // row_selected already initializes a newly selected conversation.
            if (conversation != null && ((!) conversation).equals(activated)) {
                window.navigation_split_view.show_content = true;
            }
        });

//        ConversationListModel list_model = new ConversationListModel(stream_interactor);
//        list_model.closed_conversation.connect((conversation) => {
//            print(@"closed $(conversation.counterpart.bare_jid)\n");
//            stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).close_conversation(conversation);
//        });
//        SingleSelection selection_model = new SingleSelection(list_model) { autoselect=false };
//        selection_model.notify["selected-item"].connect(() => {
//            ConversationViewModel view_model = (ConversationViewModel) selection_model.selected_item;
//            if (view_model.conversation.equals(conversation)) return;
//            print(@"selected conversation $(view_model.conversation.counterpart)\n");
//            select_conversation(view_model.conversation);
//        });
//        window.conversation_list_view.set_model(selection_model);
//        print(list_model.get_n_items().to_string() + " " + selection_model.get_n_items().to_string() + "<<");
//        print(selection_model.get_selected().to_string() + "<<");
//        window.conversation_list_view.realize.connect(() => {
//            selection_model.set_selected(0);
//        });

        Widget window_widget = ((Widget) window);

        EventControllerKey key_event_controller = new EventControllerKey();
        window_widget.add_controller(key_event_controller);
        // TODO GTK4: Why doesn't this work with key_pressed signal
        key_event_controller.key_released.connect((keyval) => {
            if (keyval == Gdk.Key.Escape) {
                close_search();
            }
        });

        EventControllerFocus focus_event_controller = new EventControllerFocus();
        window_widget.add_controller(focus_event_controller);
        focus_event_controller.enter.connect(() => {
            stream_interactor.get_module<ChatInteraction>(ChatInteraction.IDENTITY).on_window_focus_in(conversation);
        });
        focus_event_controller.leave.connect(() => {
            stream_interactor.get_module<ChatInteraction>(ChatInteraction.IDENTITY).on_window_focus_out(conversation);
        });

        window.conversation_selected.connect(conversation => {
            debug("MainWindowController: window.conversation_selected received for %s", conversation != null ? conversation.counterpart.to_string() : "NULL");
            select_conversation(conversation);
        });

        stream_interactor.account_added.connect((account) => { update_stack_state(true); });
        stream_interactor.account_removed.connect((account) => { update_stack_state(); });
        stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).conversation_activated.connect((activated_conversation) => {
            update_stack_state();
        });
        stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).conversation_deactivated.connect(() => update_stack_state());
        update_stack_state();
    }

    public void select_conversation(Conversation? conversation, bool do_reset_search = true, bool default_initialize_conversation = true, bool remember_selection = true) {
        debug("MainWindowController.select_conversation: Called with %s", conversation != null ? conversation.counterpart.to_string() : "NULL");

        // Guard against recursion
        if (selecting_conversation && this.conversation != null) {
            debug("MainWindowController.select_conversation: Skipping - already selecting");
            return;
        }

        cancel_removed_conversation_settle();
        
        int64 t0_us = Dino.Ui.UiTiming.now_us();
        this.conversation = conversation;
        stream_interactor.get_module<MucManager>(MucManager.IDENTITY).prioritize_conversation_autojoin(conversation);
        if (conversation == null) {
            unset_conversation();
            return;
        }

        conversation_view_controller.select_conversation(conversation, default_initialize_conversation);

        Dino.Ui.UiTiming.log_ms("MainWindowController.select_conversation: view_controller", t0_us);

        stream_interactor.get_module<ChatInteraction>(ChatInteraction.IDENTITY).on_conversation_selected(conversation);
        conversation.active = true; // only for conversation_selected
        if (remember_selection) {
            conversation.mark_active_now();
            store_last_selected_conversation(conversation);
        }
        window.conversation_selector.on_conversation_selected(conversation); // In case selection was not via ConversationSelector
        // Programmatic selection (including startup restore) suppresses the
        // sidebar signal, but must also keep the chat visible when collapsed.
        window.navigation_split_view.show_content = true;

        Dino.Ui.UiTiming.log_ms("MainWindowController.select_conversation: post_select_hooks", t0_us);

        if (do_reset_search) {
            reset_search_scope();
        }

        Dino.Ui.UiTiming.log_ms("MainWindowController.select_conversation: total", t0_us);
    }

    private void schedule_removed_conversation_settle(Conversation removed_conversation) {
        bool is_current = this.conversation != null &&
            ((!) this.conversation).equals(removed_conversation);
        if (!is_current && stream_interactor.get_module<ConversationManager>(
                ConversationManager.IDENTITY).get_active_conversations().size != 0) {
            return;
        }

        if (pending_removed_conversation == null || is_current) {
            pending_removed_conversation = removed_conversation;
        }
        if (removed_conversation_settle_source_id != 0) return;

        WeakRef controller_weak = WeakRef(this);
        uint source_id = 0;
        source_id = Idle.add_full(GLib.Priority.LOW, () => {
            MainWindowController? controller = (MainWindowController?)
                controller_weak.get();
            if (controller == null) return Source.REMOVE;
            return ((!) controller).run_removed_conversation_settle(source_id);
        });
        removed_conversation_settle_source_id = source_id;
    }

    private bool run_removed_conversation_settle(uint source_id) {
        if (removed_conversation_settle_source_id != source_id) {
            return Source.REMOVE;
        }
        removed_conversation_settle_source_id = 0;

        Conversation? removed_conversation = pending_removed_conversation;
        pending_removed_conversation = null;
        Gee.List<Conversation> active_conversations = stream_interactor
            .get_module<ConversationManager>(ConversationManager.IDENTITY)
            .get_active_conversations();

        if (active_conversations.is_empty) {
            if (this.conversation != null) unset_conversation();
            update_stack_state();
            return Source.REMOVE;
        }

        if (removed_conversation != null && this.conversation != null &&
                ((!) this.conversation).equals((!) removed_conversation) &&
                !active_conversations.contains((!) removed_conversation)) {
            unset_conversation();
            update_stack_state();
        }
        return Source.REMOVE;
    }

    private void cancel_removed_conversation_settle() {
        if (removed_conversation_settle_source_id != 0) {
            Source.remove(removed_conversation_settle_source_id);
            removed_conversation_settle_source_id = 0;
        }
        pending_removed_conversation = null;
    }

    private void check_unset_conversation() {
        if (stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_active_conversations().size == 0) {
            unset_conversation();
        }
    }

    private void unset_conversation() {
        cancel_removed_conversation_settle();
        this.conversation = null;

        conversation_view_controller.unset_conversation();
        window.navigation_split_view.show_content = false;
    }

    private void update_stack_state(bool know_exists = false) {
        ArrayList<Account> accounts = stream_interactor.get_accounts();
        if (initial_conversation_restore_pending && has_enabled_accounts_in_db()) {
            if (!know_exists && accounts.size == 0) {
                schedule_initial_stack_state_settle();
                return;
            }
            if (stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_active_conversations().size == 0) {
                schedule_initial_stack_state_settle();
                return;
            }
        }

        if (!know_exists && accounts.size == 0) {
            if (db.get_accounts().size == 0) {
                window.set_stack_state(MainWindow.StackState.CLEAN_START);
            } else {
                window.set_stack_state(MainWindow.StackState.NO_ACTIVE_ACCOUNTS);
            }
        } else if (stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_active_conversations().size == 0) {
            window.set_stack_state(MainWindow.StackState.NO_ACTIVE_CONVERSATIONS);
        } else {
            if (this.conversation == null && !selecting_conversation) {
                Conversation? restored_conversation = get_initial_restore_active_conversation();
                if (initial_conversation_restore_pending && initial_restore_conversation_id >= 0 && restored_conversation == null) {
                    schedule_initial_stack_state_settle();
                    return;
                }
                restored_conversation = restored_conversation ?? get_most_recently_selected_active_conversation();
                if (restored_conversation != null) {
                    debug("MainWindowController: Restoring active conversation %s", restored_conversation.counterpart.to_string());
                    selecting_conversation = true;
                    initial_restore_selecting = true;
                    select_conversation(restored_conversation, true, true, false);
                    initial_restore_selecting = false;
                    selecting_conversation = false;
                }
            }
            finish_initial_conversation_restore();
            window.set_stack_state(MainWindow.StackState.CONVERSATION);
        }
    }

    private void store_last_selected_conversation(Conversation conversation) {
        db.settings.upsert()
                .value(db.settings.key, LAST_SELECTED_CONVERSATION_ID_SETTING, true)
                .value(db.settings.value, conversation.id.to_string())
                .perform();
    }

    private int get_stored_selected_conversation_id() {
        string? value = db.settings.select({db.settings.value})
                .with(db.settings.key, "=", LAST_SELECTED_CONVERSATION_ID_SETTING)[db.settings.value];
        if (value == null) return -1;

        return int.parse(value);
    }

    private Conversation? get_initial_restore_active_conversation() {
        if (initial_restore_conversation_id < 0) return null;

        Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation_by_id(initial_restore_conversation_id);
        if (conversation == null || !conversation.active) return null;
        return conversation;
    }

    private Conversation? get_most_recently_selected_active_conversation() {
        Conversation? selected = null;
        foreach (Conversation conversation in stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_active_conversations()) {
            if (selected == null || conversation.active_last_changed.compare(selected.active_last_changed) > 0) {
                selected = conversation;
            }
        }
        return selected;
    }

    private bool has_enabled_accounts_in_db() {
        foreach (Account account in db.get_accounts()) {
            if (account.enabled) return true;
        }
        return false;
    }

    private void schedule_initial_stack_state_settle() {
        if (initial_stack_state_timeout_id != 0) return;

        initial_stack_state_timeout_id = Timeout.add(INITIAL_STACK_STATE_DELAY_MS, () => {
            initial_stack_state_timeout_id = 0;
            initial_conversation_restore_pending = false;
            update_stack_state();
            reveal_initial_window_now();
            return false;
        });
    }

    private void finish_initial_conversation_restore() {
        initial_conversation_restore_pending = false;
        if (initial_stack_state_timeout_id != 0) {
            Source.remove(initial_stack_state_timeout_id);
            initial_stack_state_timeout_id = 0;
        }
        schedule_initial_window_reveal();
    }

    private void schedule_initial_window_reveal() {
        if (window == null || window.stack.opacity >= 1) return;
        if (initial_window_reveal_timeout_id != 0) return;

        initial_window_reveal_timeout_id = Timeout.add(INITIAL_WINDOW_REVEAL_DELAY_MS, () => {
            initial_window_reveal_timeout_id = 0;
            reveal_initial_window_now();
            return false;
        });
    }

    private void reveal_initial_window_now() {
        if (initial_window_reveal_timeout_id != 0) {
            Source.remove(initial_window_reveal_timeout_id);
            initial_window_reveal_timeout_id = 0;
        }
        if (window != null) {
            window.stack.opacity = 1;
        }
    }

    private void reset_search_scope() {
        Conversation? current_conversation = window.conversation_view.conversation_frame.conversation;
        if (current_conversation != null) {
            window.global_search.set_conversation_scope(current_conversation, true);
        }
    }

    private void close_search() {
        conversation_view_controller.search_menu_entry.button.active = false;
    }
}

}
