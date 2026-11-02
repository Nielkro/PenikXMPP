using Gee;
using Gtk;

using Xmpp;
using Xmpp.Xep.Bookmarks;
using Dino.Entities;

namespace Dino.Ui {

protected class ConferenceList : Object {

    public signal void conversation_selected(Conversation? conversation);
    public signal void rows_changed();

    private StreamInteractor stream_interactor;

    private ListBox list_box = new ListBox();
    private HashMap<Account, Set<Conference>> lists = new HashMap<Account, Set<Conference>>(Account.hash_func, Account.equals_func);
    private HashMap<Account, HashMap<Jid, ListBoxRow>> widgets = new HashMap<Account, HashMap<Jid, ListBoxRow>>(Account.hash_func, Account.equals_func);

    ulong bookmarks_updated_handler_id = 0;
    ulong conference_added_handler_id = 0;
    ulong conference_removed_handler_id = 0;
    ulong conversation_activated_handler_id = 0;
    ulong conversation_deactivated_handler_id = 0;
    ulong conversation_hidden_handler_id = 0;
    private uint refresh_timeout_id = 0;
    private bool started = false;
    private bool initial_bookmark_load_settled = false;
    private int pending_initial_bookmark_loads = 0;
    private ListBoxRow? loading_row = null;
    private bool deactivated = false;

    public ConferenceList(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
        show_loading_row();

        bookmarks_updated_handler_id = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).bookmarks_updated.connect((account, conferences) => {
            if (deactivated) return;
            set_bookmarks(account, conferences);
        });

        conference_added_handler_id = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).conference_added.connect(on_conference_added);
        conference_removed_handler_id = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).conference_removed.connect(remove_conference);

        ConversationManager conversation_manager = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
        conversation_activated_handler_id = conversation_manager.conversation_activated.connect(on_conversation_state_changed);
        conversation_deactivated_handler_id = conversation_manager.conversation_deactivated.connect(on_conversation_state_changed);
        conversation_hidden_handler_id = conversation_manager.conversation_hidden.connect(on_conversation_state_changed);
    }

    public void start_loading() {
        if (started || deactivated) return;
        bool timing = UiTiming.enabled();
        int64 t0_us = timing ? UiTiming.now_us() : 0;
        started = true;

        pending_initial_bookmark_loads = stream_interactor.get_accounts().size;
        initial_bookmark_load_settled = pending_initial_bookmark_loads == 0;
        foreach (Account account in stream_interactor.get_accounts()) {
            stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_bookmarks.begin(account, (_, res) => {
                Set<Conference>? conferences = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_bookmarks.end(res);
                if (deactivated) return;
                set_bookmarks(account, conferences);
                pending_initial_bookmark_loads--;
                if (pending_initial_bookmark_loads <= 0) {
                    pending_initial_bookmark_loads = 0;
                    initial_bookmark_load_settled = true;
                    schedule_refresh_conferences();
                }
            });
        }

        if (initial_bookmark_load_settled) schedule_refresh_conferences();
        if (timing) {
            UiTiming.log_ms("ConferenceList.start_loading: accounts=%d".printf(stream_interactor.get_accounts().size), t0_us);
        }
    }

    ~ConferenceList() {
        deactivate();
    }

    public void deactivate() {
        if (deactivated) return;
        deactivated = true;
        if (refresh_timeout_id != 0) Source.remove(refresh_timeout_id);
        refresh_timeout_id = 0;
        MucManager muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        if (bookmarks_updated_handler_id != 0) {
            muc_manager.disconnect(bookmarks_updated_handler_id);
            bookmarks_updated_handler_id = 0;
        }
        if (conference_added_handler_id != 0) muc_manager.disconnect(conference_added_handler_id);
        if (conference_removed_handler_id != 0) muc_manager.disconnect(conference_removed_handler_id);
        conference_added_handler_id = 0;
        conference_removed_handler_id = 0;
        ConversationManager conversation_manager = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
        if (conversation_activated_handler_id != 0) conversation_manager.disconnect(conversation_activated_handler_id);
        if (conversation_deactivated_handler_id != 0) conversation_manager.disconnect(conversation_deactivated_handler_id);
        if (conversation_hidden_handler_id != 0) conversation_manager.disconnect(conversation_hidden_handler_id);
        conversation_activated_handler_id = 0;
        conversation_deactivated_handler_id = 0;
        conversation_hidden_handler_id = 0;
        deactivate_rows();
    }

    private void schedule_refresh_conferences() {
        if (!started || deactivated) return;
        if (refresh_timeout_id != 0) return;
        refresh_timeout_id = Timeout.add(25, () => {
            refresh_timeout_id = 0;
            if (deactivated) return false;
            refresh_conferences();
            return false;
        });
    }

    private void on_conference_added(Account account, Conference conference) {
        add_bookmark_to_cache(account, conference);
        add_conference(account, conference);
    }

    private bool add_conference(Account account, Conference conference, bool emit_rows_changed = true) {
        if (deactivated) return false;
        bool changed = false;
        if (conference.jid == null) return false;
        if (!widgets.has_key(account)) {
            widgets[account] = new HashMap<Jid, ListBoxRow>(Jid.hash_bare_func, Jid.equals_bare_func);
        }
        Jid row_jid = conference.jid.bare_jid;
        if (widgets[account].has_key(row_jid)) {
            ConferenceListRow? existing_row = widgets[account][row_jid].child as ConferenceListRow;
            if (existing_row != null) {
                changed = existing_row.update_from_bookmark(stream_interactor, conference, account);
                if (changed && emit_rows_changed) rows_changed();
                return changed;
            }
        }
        var widget = new ConferenceListRow(stream_interactor, conference, account);
        var list_box_row = new ListBoxRow();
        list_box_row.set_child(widget);
        widgets[account][row_jid] = list_box_row;
        list_box.append(list_box_row);
        if (emit_rows_changed) rows_changed();
        return true;
    }

    private void remove_conference(Account account, Jid jid) {
        if (deactivated) return;
        Jid row_jid = jid.bare_jid;
        if (lists.has_key(account)) {
            var remove_conferences = new ArrayList<Conference>();
            foreach (Conference conference in lists[account]) {
                if (conference.jid != null && ((!) conference.jid).bare_jid.equals(row_jid)) {
                    remove_conferences.add(conference);
                }
            }
            foreach (Conference conference in remove_conferences) {
                lists[account].remove(conference);
            }
            if (lists[account].is_empty) {
                lists.unset(account);
            }
        }
        if (widgets.has_key(account) && widgets[account].has_key(row_jid)) {
            remove_list_box_row(widgets[account][row_jid]);
            widgets[account].unset(row_jid);
            rows_changed();
        }
        if (started) schedule_refresh_conferences();
    }

    private bool add_conversation(Conversation conversation, bool emit_rows_changed = true) {
        if (deactivated) return false;
        if (conversation.type_ != Conversation.Type.GROUPCHAT) return false;
        if (!conversation.active && !stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_joined(conversation.counterpart, conversation.account)) return false;

        if (!widgets.has_key(conversation.account)) {
            widgets[conversation.account] = new HashMap<Jid, ListBoxRow>(Jid.hash_bare_func, Jid.equals_bare_func);
        }
        Jid row_jid = conversation.counterpart.bare_jid;
        if (widgets[conversation.account].has_key(row_jid)) {
            ConferenceListRow? existing_row = widgets[conversation.account][row_jid].child as ConferenceListRow;
            if (existing_row != null) {
                bool changed = existing_row.mark_existing_conversation(stream_interactor, conversation);
                if (changed && emit_rows_changed) rows_changed();
                return changed;
            }
            return false;
        }

        var widget = new ConferenceListRow.from_conversation(stream_interactor, conversation);
        var list_box_row = new ListBoxRow();
        list_box_row.set_child(widget);
        widgets[conversation.account][row_jid] = list_box_row;
        list_box.append(list_box_row);
        if (emit_rows_changed) rows_changed();
        return true;
    }

    private void on_conversation_state_changed(Conversation conversation) {
        if (deactivated) return;
        if (conversation.type_ == Conversation.Type.GROUPCHAT) schedule_refresh_conferences();
    }

    public void refresh_conferences() {
        if (!started || deactivated) return;
        bool timing = UiTiming.enabled();
        int64 t0_us = timing ? UiTiming.now_us() : 0;
        int bookmark_count = 0;
        int conversation_count = 0;
        int removed_count = 0;
        bool rows_changed_pending = false;
        bool removed_loading_row = initial_bookmark_load_settled && loading_row != null;
        if (initial_bookmark_load_settled) {
            hide_loading_row();
        }

        var desired = new HashMap<Account, HashSet<Jid>>(Account.hash_func, Account.equals_func);

        foreach (Account account in lists.keys) {
            foreach (Conference conference in lists[account]) {
                if (conference.jid == null) continue;
                if (timing) bookmark_count++;
                mark_desired(desired, account, conference.jid.bare_jid);
                if (add_conference(account, conference, false)) rows_changed_pending = true;
            }
        }

        foreach (Conversation conversation in stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY).get_groupchat_conversations()) {
            if (conversation.type_ != Conversation.Type.GROUPCHAT) continue;
            if (!conversation.active && !stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_joined(conversation.counterpart, conversation.account)) continue;
            if (timing) conversation_count++;
            mark_desired(desired, conversation.account, conversation.counterpart.bare_jid);
            if (add_conversation(conversation, false)) rows_changed_pending = true;
        }

        bool removed_rows = false;

        foreach (Account account in widgets.keys) {
            var account_widgets_cpy = new HashMap<Jid, ListBoxRow>(Jid.hash_bare_func, Jid.equals_bare_func);
            account_widgets_cpy.set_all(widgets[account]);

            foreach (Jid jid in account_widgets_cpy.keys) {
                if (!desired.has_key(account) || !desired[account].contains(jid.bare_jid)) {
                    remove_list_box_row(widgets[account][jid]);
                    widgets[account].unset(jid);
                    if (timing) removed_count++;
                    removed_rows = true;
                }
            }
        }

        if (rows_changed_pending || removed_rows || removed_loading_row) {
            rows_changed();
        }

        if (timing) {
            int row_count = 0;
            foreach (Account account in widgets.keys) {
                row_count += widgets[account].size;
            }
            UiTiming.log_ms("ConferenceList.refresh_conferences: bookmarks=%d conversations=%d rows=%d removed=%d".printf(bookmark_count, conversation_count, row_count, removed_count), t0_us);
        }
    }

    private void mark_desired(HashMap<Account, HashSet<Jid>> desired, Account account, Jid jid) {
        if (!desired.has_key(account)) {
            desired[account] = new HashSet<Jid>(Jid.hash_bare_func, Jid.equals_bare_func);
        }
        desired[account].add(jid.bare_jid);
    }

    private void add_bookmark_to_cache(Account account, Conference conference) {
        if (conference.jid == null) return;
        if (!lists.has_key(account)) {
            lists[account] = new HashSet<Conference>(Conference.hash_func, Conference.equals_func);
        }
        Jid bare = ((!) conference.jid).bare_jid;
        Conference? existing_conference = null;
        foreach (Conference cached_conference in lists[account]) {
            if (cached_conference.jid != null && ((!) cached_conference.jid).bare_jid.equals(bare)) {
                existing_conference = cached_conference;
                break;
            }
        }
        if (existing_conference != null) {
            lists[account].remove((!) existing_conference);
        }
        lists[account].add(conference);
    }

    private void set_bookmarks(Account account, Set<Conference>? conferences) {
        if (conferences == null) {
            warning("Failed to load MUC bookmarks for %s; keeping cached group list", account.bare_jid.to_string());
            return;
        } else {
            lists[account] = conferences;
        }
        schedule_refresh_conferences();
    }

    public ListBox get_list_box() {
        return list_box;
    }

    private void remove_list_box_row(ListBoxRow list_box_row) {
        ConferenceListRow? conference_row = list_box_row.child as ConferenceListRow;
        if (conference_row != null) {
            conference_row.deactivate_conference_row();
        }
        ListRow? list_row = list_box_row.child as ListRow;
        if (list_row != null) {
            list_row.deactivate();
        }
        list_box.remove(list_box_row);
    }

    private void deactivate_rows() {
        foreach (Account account in widgets.keys) {
            foreach (ListBoxRow row in widgets[account].values) {
                ConferenceListRow? conference_row = row.child as ConferenceListRow;
                if (conference_row != null) conference_row.deactivate_conference_row();
                ListRow? list_row = row.child as ListRow;
                if (list_row != null) list_row.deactivate();
            }
        }
    }

    private void show_loading_row() {
        if (loading_row != null) return;

        var box = new Box(Orientation.HORIZONTAL, 8) {
            margin_top = 10,
            margin_bottom = 10,
            margin_start = 10,
            margin_end = 10
        };
        var spinner = new Spinner();
        spinner.start();
        var label = new Label(_("Loading groups...")) { xalign = 0 };
        box.append(spinner);
        box.append(label);

        loading_row = new ListBoxRow();
        ((!) loading_row).set_selectable(false);
        ((!) loading_row).set_activatable(false);
        ((!) loading_row).set_child(box);
        list_box.append((!) loading_row);
    }

    private void hide_loading_row() {
        if (loading_row == null) return;
        remove_list_box_row((!) loading_row);
        loading_row = null;
    }
}

internal class ConferenceListRow : ListRow {

    public Conference? bookmark;
    public bool open_existing { get; private set; }
    private uint avatar_hydrate_source_id = 0;
    private uint avatar_generation = 0;
    private AvatarObserver? avatar_observer;
    private bool conference_row_deactivated = false;

    public ConferenceListRow(StreamInteractor stream_interactor, Conference bookmark, Account account) {
        update_from_bookmark(stream_interactor, bookmark, account);
    }

    public ConferenceListRow.from_conversation(StreamInteractor stream_interactor, Conversation conversation) {
        update_from_conversation(stream_interactor, conversation);
    }

    public bool mark_existing_conversation(StreamInteractor stream_interactor, Conversation conversation) {
        if (bookmark != null && open_existing) return false;
        this.open_existing = true;

        if (bookmark == null) {
            return update_from_conversation(stream_interactor, conversation);
        }
        return true;
    }

    public bool update_from_bookmark(StreamInteractor stream_interactor, Conference bookmark, Account account) {
        string safe_jid = Util.sanitize_utf8(bookmark.jid.to_string());
        string safe_bookmark_name = Util.sanitize_utf8(bookmark.name);
        bool has_bookmark_name = safe_bookmark_name != "";
        bool has_display_alias = has_bookmark_name && safe_bookmark_name != safe_jid;
        string new_name = has_bookmark_name ? safe_bookmark_name : safe_jid;
        bool new_open_existing = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_joined_or_joining(bookmark.jid, account) ||
                is_active_groupchat_conversation(stream_interactor, account, bookmark.jid);
        bool new_private_visible = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_private_room(account, bookmark.jid);
        bool new_via_visible = stream_interactor.get_accounts().size > 1 ||
                has_display_alias;
        string new_via_label = stream_interactor.get_accounts().size > 1 ?
                Util.sanitize_utf8(_("via %s").printf(account.bare_jid.to_string())) :
                (has_display_alias ? safe_jid : "");
        bool changed = this.jid == null || !this.jid.equals(bookmark.jid.bare_jid) ||
                this.account == null || !Account.equals_func(this.account, account) ||
                this.open_existing != new_open_existing ||
                name_label.label != new_name ||
                private_room_image.visible != new_private_visible ||
                via_label.visible != new_via_visible ||
                (new_via_visible && via_label.label != new_via_label);

        if (!changed) {
            this.bookmark = bookmark;
            return false;
        }

        this.jid = bookmark.jid.bare_jid;
        this.account = account;
        this.bookmark = bookmark;
        this.open_existing = new_open_existing;

        status_dot.visible = false;
        name_label.label = new_name;

        private_room_image.visible = new_private_visible;

        if (stream_interactor.get_accounts().size > 1) {
            via_label.visible = true;
            via_label.label = new_via_label;
        } else if (has_display_alias) {
            via_label.visible = true;
            via_label.label = new_via_label;
        } else {
            via_label.visible = false;
        }

        set_deferred_avatar(stream_interactor, account, jid, "#");
        return changed;
    }

    public bool update_from_conversation(StreamInteractor stream_interactor, Conversation conversation) {
        string new_name = Util.sanitize_utf8(Util.get_conversation_display_name(stream_interactor, conversation));
        string safe_jid = Util.sanitize_utf8(conversation.counterpart.bare_jid.to_string());
        bool new_private_visible = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_private_room(conversation.account, conversation.counterpart.bare_jid);
        bool new_via_visible = stream_interactor.get_accounts().size > 1 || new_name != safe_jid;
        string new_via_label = stream_interactor.get_accounts().size > 1 ?
                Util.sanitize_utf8(_("via %s").printf(conversation.account.bare_jid.to_string())) :
                (new_name != safe_jid ? safe_jid : "");
        bool changed = this.jid == null || !this.jid.equals(conversation.counterpart.bare_jid) ||
                this.account == null || !Account.equals_func(this.account, conversation.account) ||
                this.bookmark != null ||
                !this.open_existing ||
                name_label.label != new_name ||
                private_room_image.visible != new_private_visible ||
                via_label.visible != new_via_visible ||
                (new_via_visible && via_label.label != new_via_label);

        if (!changed) {
            return false;
        }

        this.jid = conversation.counterpart.bare_jid;
        this.account = conversation.account;
        this.bookmark = null;
        this.open_existing = true;

        status_dot.visible = false;
        name_label.label = new_name;

        private_room_image.visible = new_private_visible;

        if (stream_interactor.get_accounts().size > 1) {
            via_label.visible = true;
            via_label.label = new_via_label;
        } else if (new_name != safe_jid) {
            via_label.visible = true;
            via_label.label = new_via_label;
        } else {
            via_label.visible = false;
        }

        set_deferred_avatar(stream_interactor, conversation.account, jid, "#");
        return changed;
    }

    public void deactivate_conference_row() {
        if (conference_row_deactivated) return;
        conference_row_deactivated = true;
        avatar_generation++;
        if (avatar_hydrate_source_id != 0) {
            Source.remove(avatar_hydrate_source_id);
            avatar_hydrate_source_id = 0;
        }
        if (avatar_observer != null) {
            ((!) avatar_observer).unsubscribe();
            avatar_observer = null;
        }
    }

    public override void dispose() {
        deactivate_conference_row();
        base.dispose();
    }

    private void set_deferred_avatar(StreamInteractor stream_interactor, Account account, Jid jid, string display) {
        if (avatar_observer != null) {
            ((!) avatar_observer).unsubscribe();
            avatar_observer = null;
        }
        Jid bare_jid = jid.bare_jid;
        AvatarManager avatar_manager = stream_interactor.get_module<AvatarManager>(AvatarManager.IDENTITY);
        WeakRef observer_row_weak = WeakRef(this);
        avatar_observer = avatar_manager.observe_avatar(account, bare_jid,
            (changed_jid, changed_account) => {
                ConferenceListRow? row = (ConferenceListRow?) observer_row_weak.get();
                if (row == null || ((!) row).conference_row_deactivated ||
                        ((!) row).jid == null || ((!) row).account == null ||
                        !Account.equals_func(changed_account, account) ||
                        !changed_jid.equals_bare(bare_jid) ||
                        !Account.equals_func(((!) row).account, account) ||
                        !((!) row).jid.equals_bare(bare_jid)) return false;
                ((!) row).schedule_local_avatar_hydration(stream_interactor,
                    account, bare_jid, display,
                    !avatar_manager.has_avatar(account, bare_jid));
                return true;
            });
        schedule_local_avatar_hydration(stream_interactor, account, bare_jid,
            display, true);
    }

    private void schedule_local_avatar_hydration(
            StreamInteractor stream_interactor, Account account, Jid jid,
            string display, bool reset_placeholder) {
        avatar_generation++;
        uint generation = avatar_generation;
        if (avatar_hydrate_source_id != 0) {
            Source.remove(avatar_hydrate_source_id);
            avatar_hydrate_source_id = 0;
        }
        if (reset_placeholder) {
            picture.model = new ViewModel.CompatAvatarPictureModel(null).add(
                display, jid.bare_jid.to_string(), null);
        }
        avatar_hydrate_source_id = Idle.add(() => {
            avatar_hydrate_source_id = 0;
            if (conference_row_deactivated || generation != avatar_generation || this.jid == null || this.account == null ||
                    !Account.equals_func(this.account, account) || !this.jid.equals_bare(jid)) {
                return false;
            }

            AvatarManager avatar_manager = stream_interactor.get_module<
                AvatarManager>(AvatarManager.IDENTITY);
            WeakRef row_weak = WeakRef(this);
            avatar_manager.get_avatar_bytes_from_local_cache_async.begin(account, jid.bare_jid, (obj, result) => {
                Bytes? image_bytes = avatar_manager.get_avatar_bytes_from_local_cache_async.end(result);
                ConferenceListRow? row = (ConferenceListRow?) row_weak.get();
                if (row == null || ((!) row).conference_row_deactivated || generation != ((!) row).avatar_generation ||
                        ((!) row).jid == null || ((!) row).account == null ||
                        !Account.equals_func(((!) row).account, account) || !((!) row).jid.equals_bare(jid) || image_bytes == null) {
                    return;
                }

                ((!) row).picture.model = new ViewModel.CompatAvatarPictureModel(null).add(display, jid.bare_jid.to_string(), image_bytes);
            });
            return false;
        });
    }

    private static bool is_active_groupchat_conversation(StreamInteractor stream_interactor, Account account, Jid jid) {
        Conversation? conversation = stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY)
                .get_conversation(jid.bare_jid, account, Conversation.Type.GROUPCHAT);
        return conversation != null && conversation.active;
    }
}

}
