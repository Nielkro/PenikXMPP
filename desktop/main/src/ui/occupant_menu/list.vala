using Gee;
using Gtk;

using Dino.Entities;
using Xmpp;

namespace Dino.Ui.OccupantMenu {

public class OccupantListItem : Object {
    public bool is_header { get; set; default = false; }
    public bool header_top { get; set; default = false; }
    public string header_title { get; set; default = ""; }
    public int header_count { get; set; default = 0; }

    public Jid? jid { get; set; }
    public string display_name { get; set; default = ""; }
    public string status_icon { get; set; default = "user-available-symbolic"; }
    public string status_text { get; set; default = ""; }
    public string status_css_class { get; set; default = "success"; }
    public string hats_text { get; set; default = ""; }
    public string hats_markup { get; set; default = ""; }
    // Each presentation owns copies of the room's descriptive Hat values.
    // Never retain mutable protocol objects or use Hats as permissions.
    public Gee.List<Xmpp.Xep.Muc.Hat> hats = new ArrayList<Xmpp.Xep.Muc.Hat>();
    public Xmpp.Xep.Muc.Affiliation affiliation { get; set; default = Xmpp.Xep.Muc.Affiliation.NONE; }
    public Xmpp.Xep.Muc.Role role { get; set; default = Xmpp.Xep.Muc.Role.NONE; }
    public bool affiliation_known { get; set; default = false; }
    public bool role_known { get; set; default = false; }
    public bool is_offline_member { get; set; default = false; }
    public bool details_loaded { get; set; default = false; }
    public Dino.AvatarReadPolicy avatar_read_policy { get; set; default = Dino.AvatarReadPolicy.LOCAL_CACHE_ONLY; }
    public signal void changed();

    public OccupantListItem.header(string title, int count, bool top) {
        is_header = true;
        header_title = title;
        header_count = count;
        header_top = top;
    }

    public OccupantListItem.occupant(Jid jid) {
        this.jid = jid;
    }

    public bool matches_filter(string[]? filter_values) {
        if (is_header) return true;
        if (filter_values == null) return true;

        string searchable = normalize_search_text("%s %s %s %s %s".printf(
            display_name,
            jid != null ? ((!) jid).to_string() : "",
            hats_text,
            get_affiliation_search_text(),
            get_role_search_text()
        ));

        foreach (string filter in filter_values) {
            if (!searchable.contains(normalize_search_text(filter))) return false;
        }
        return true;
    }

    public void notify_changed() {
        changed();
    }

    private static string normalize_search_text(string value) {
        // Match canonically equivalent nicknames and full Unicode casing,
        // including German sharp-s. The contact search uses the same policy.
        return value.make_valid().normalize(-1, NormalizeMode.NFKC).casefold();
    }

    public bool hats_equal(Gee.List<Xmpp.Xep.Muc.Hat> other) {
        if (hats.size != other.size) return false;
        for (int index = 0; index < hats.size; index++) {
            if (!hats[index].equals(other[index])) return false;
        }
        return true;
    }

    private string get_affiliation_search_text() {
        if (!affiliation_known) return _("Participants");

        switch (affiliation) {
            case Xmpp.Xep.Muc.Affiliation.OWNER:
                return _("Owner");
            case Xmpp.Xep.Muc.Affiliation.ADMIN:
                return _("Admin");
            case Xmpp.Xep.Muc.Affiliation.MEMBER:
                return _("Member");
            case Xmpp.Xep.Muc.Affiliation.OUTCAST:
                return _("Banned");
            default:
                return _("Participants");
        }
    }

    private string get_role_search_text() {
        switch (role) {
            case Xmpp.Xep.Muc.Role.MODERATOR:
                return _("Moderator");
            case Xmpp.Xep.Muc.Role.PARTICIPANT:
                return _("Participant");
            case Xmpp.Xep.Muc.Role.VISITOR:
                return _("Visitor");
            default:
                return "";
        }
    }
}

private class OccupantListCache : Object {
    public HashMap<Jid, OccupantListItem> occupants = new HashMap<Jid, OccupantListItem>(Jid.hash_func, Jid.equals_func);
    public ArrayList<OccupantListItem>? presentation_items = null;
    public ArrayList<Jid>? stable_occupants = null;
    public uint64 snapshot_stream_generation = 0;
    public uint64 snapshot_room_generation = 0;
    public uint64 snapshot_revision = 0;
    public uint64 lifecycle_stream_generation = 0;
    public uint64 lifecycle_room_generation = 0;
    public uint64 real_jid_visibility_generation = 0;
    public bool loaded = false;
    public bool details_loaded = false;
    public bool known_large_room = false;
    public int64 last_used_us = 0;
}

[GtkTemplate (ui = "/im/dinox/dinox/occupant_list.ui")]
public class List : Box {

    private static HashMap<string, OccupantListCache> model_cache = new HashMap<string, OccupantListCache>();

    public signal void occupant_activated(Jid jid, string display_name);
    private StreamInteractor stream_interactor;

    [GtkChild] public unowned ListView list_view;
    [GtkChild] private unowned SearchEntry search_entry;
    [GtkChild] private unowned Label summary_label;
    [GtkChild] private unowned Button show_list_button;
    [GtkChild] private unowned Box loading_box;
    [GtkChild] private unowned Spinner loading_spinner;
    [GtkChild] private unowned Label loading_label;
    [GtkChild] private unowned ScrolledWindow scrolled_window;

    private Conversation conversation;
    private string[]? filter_values;
    private ArrayList<Jid> all_occupants = new ArrayList<Jid>(Jid.equals_func);
    private HashSet<Jid> all_occupant_index = new HashSet<Jid>(Jid.hash_func, Jid.equals_func);
    private HashSet<Jid> private_member_snapshot_bare_jids = new HashSet<Jid>(Jid.hash_bare_func, Jid.equals_bare_func);
    private bool private_member_snapshot_complete = false;
    private HashMap<MucMemberListSection, int> summary_counts = new HashMap<MucMemberListSection, int>();
    private HashMap<Widget, ListRow> factory_rows = new HashMap<Widget, ListRow>();
    private GLib.ListStore presentation_store = new GLib.ListStore(typeof(OccupantListItem));

    private const int AUTO_LOAD_LIMIT = 80;
    private const int BATCH_SIZE = 8;
    private const int PRESENTATION_BATCH_SIZE = 20;
    private const int PRESENTATION_COMMIT_BATCH_SIZE = 12;
    private const int SNAPSHOT_APPLY_BATCH_SIZE = 32;
    private const int WORK_BUDGET_US = 2500;
    private const int CLEANUP_ROW_BATCH_SIZE = 16;
    private const int CLEANUP_STORE_BATCH_SIZE = 32;
    private const int CLEANUP_WORK_BUDGET_US = 2500;
    private const int MODEL_CACHE_LIMIT = 16;
    private uint occupant_update_timeout = 0;
    private bool pending_rebuild = false;
    private uint presence_update_timeout = 0;
    private uint affiliation_rebuild_timeout = 0;
    private uint summary_refresh_timeout = 0;
    private uint initial_snapshot_watch_source = 0;
    private uint snapshot_apply_source = 0;
    private uint snapshot_apply_generation = 0;
    private MucRoomDelta? pending_room_snapshot = null;
    private bool room_snapshot_followup_pending = false;
    private ArrayList<Jid>? staged_snapshot_occupants = null;
    private HashSet<Jid>? staged_snapshot_index = null;
    private HashMap<Jid, MucOccupantSnapshot>? staged_snapshot_states = null;
    private HashSet<Jid> snapshot_live_removals = new HashSet<Jid>(Jid.hash_func, Jid.equals_func);
    private uint staged_snapshot_position = 0;
    private int64 snapshot_apply_started_us = 0;
    private HashSet<Jid> pending_presence_jids = new HashSet<Jid>(Jid.hash_func, Jid.equals_func);
    private bool pending_avatar_refresh = false;
    private bool pending_presence_rebuild = false;
    private bool pending_summary_refresh = false;
    private bool waiting_for_initial_snapshot = false;
    private bool waiting_for_uncached_initial_snapshot = false;
    private bool empty_partial_surface_active = false;
    private int64 initial_snapshot_wait_started_us = 0;
    private int64 initial_snapshot_last_membership_change_us = 0;

    private uint batch_init_source = 0;
    private bool initializing = false;
    private ArrayList<Jid>? load_queue = null;
    private HashSet<Jid>? load_queue_index = null;
    private int load_index = 0;
    private uint load_generation = 0;
    private uint presentation_rebuild_generation = 0;
    private uint presentation_commit_generation = 0;
    private uint presentation_cache_generation = 0;
    private uint presentation_commit_cache_generation = 0;
    private uint cache_refresh_source = 0;
    private ArrayList<Jid>? cache_refresh_queue = null;
    private int cache_refresh_index = 0;
    private bool cache_refresh_rebuild_after = false;
    private uint presentation_rebuild_source = 0;
    private uint presentation_commit_source = 0;
    private uint presentation_commit_map_tick = 0;
    private uint presentation_ready_timing_source = 0;
    private ArrayList<OccupantListItem>? presentation_queue = null;
    private ArrayList<OccupantListItem>? staged_presentation_items = null;
    private ArrayList<OccupantListItem>? presentation_commit_queue = null;
    private GLib.ListStore? presentation_commit_store = null;
    private ArrayList<OccupantListItem>? presentation_owner_items = null;
    private ArrayList<OccupantListItem>? presentation_admin_items = null;
    private ArrayList<OccupantListItem>? presentation_moderator_items = null;
    private ArrayList<OccupantListItem>? presentation_member_items = null;
    private ArrayList<OccupantListItem>? presentation_participant_items = null;
    private ArrayList<OccupantListItem>? presentation_visitor_items = null;
    private ArrayList<OccupantListItem>? presentation_outcast_items = null;
    private HashMap<string, int> presentation_counts = new HashMap<string, int>();
    private int presentation_index = 0;
    private int presentation_commit_index = 0;
    private int presentation_commit_member_index = 0;
    private int presentation_commit_member_total = 0;
    private bool presentation_commit_direct_visible = false;
    private int presentation_collect_index = 0;
    private bool presentation_commit_show_progress = false;
    private int presentation_summary_total_count = 0;
    private bool loading_progress_preparing = false;
    private int loading_progress_loaded = -1;
    private int loading_progress_total = -1;
    private bool presentation_has_current_section = false;
    private string presentation_current_group_key = "";
    private bool presentation_top = true;
    private bool presentation_show_progress = false;
    private bool presentation_rebuild_progressive_reveal = false;
    private bool presentation_complete = false;
    private bool presentation_timing_active = false;
    private int64 presentation_timing_started_us = 0;
    private int presentation_factory_setup_count = 0;
    private int presentation_factory_bind_count = 0;
    private int64 presentation_factory_setup_us = 0;
    private int64 presentation_factory_bind_us = 0;
    private bool background_work_suspended = false;
    private bool disposed = false;
    private bool cleanup_started = false;
    private bool cleanup_model_detached = false;
    private bool cleanup_state_cleared = false;
    private ArrayList<ListRow>? cleanup_pending_rows = null;
    private string cache_key = "";
    private OccupantListCache cache;
    private NoSelection selection_model;

    private PresenceObserver? presence_observer = null;
    private ulong occupant_hats_handler = 0;
    private ulong occupant_affiliation_handler = 0;
    private ulong bare_affiliation_changed_handler = 0;
    private ulong occupant_role_handler = 0;
    private ulong private_room_occupant_handler = 0;
    private ulong real_jid_visibility_revoked_handler = 0;
    private ulong initial_sync_started_handler = 0;
    private ulong occupant_projection_changed_handler = 0;
    private ulong occupant_snapshot_handler = 0;
    private ulong occupant_batch_handler = 0;
    private ulong avatar_received_handler = 0;
    private ulong avatar_fetched_handler = 0;

    public List(StreamInteractor stream_interactor, Conversation conversation) {
        this.stream_interactor = stream_interactor;
        this.conversation = conversation;
        setup_list_view();
        search_entry.search_changed.connect(refilter);
        // Opening the popover is the explicit request to load its members.
        // Keep the retired second-stage trigger permanently out of every
        // snapshot/rejoin state transition.
        show_list_button.visible = false;

        WeakRef list_weak = WeakRef(this);
        var presence_manager = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        presence_observer = presence_manager.observe_presence(conversation.account, conversation.counterpart.bare_jid,
            (jid, account, available) => {
                List? list = (List?) list_weak.get();
                if (list == null || ((!) list).disposed) return false;
                if (available) {
                    ((!) list).on_show_received(jid, account);
                } else {
                    ((!) list).on_received_offline_presence(jid, account);
                }
                return true;
            });
        var muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        occupant_hats_handler = muc_manager.received_occupant_hats.connect(on_occupant_hats_changed);
        occupant_affiliation_handler = muc_manager.occupant_affiliation_updated.connect(on_occupant_affiliation_updated);
        var muc_module = stream_interactor.module_manager.get_module<Xmpp.Xep.Muc.Module>(
            conversation.account, Xmpp.Xep.Muc.Module.IDENTITY);
        bare_affiliation_changed_handler = muc_module.bare_affiliation_changed.connect(
            on_bare_affiliation_changed);
        occupant_role_handler = muc_manager.received_occupant_role.connect(on_occupant_role_updated);
        private_room_occupant_handler = muc_manager.private_room_occupant_updated.connect(on_private_room_occupant_updated);
        real_jid_visibility_revoked_handler =
            muc_manager.room_real_jid_visibility_revoked.connect(
                on_room_real_jid_visibility_revoked);
        initial_sync_started_handler = muc_manager.room_initial_sync_started.connect(
            on_room_initial_sync_started);
        occupant_projection_changed_handler =
            muc_manager.room_occupant_projection_changed.connect(
                on_room_occupant_projection_changed);
        occupant_snapshot_handler = muc_manager.room_occupants_snapshot_ready.connect(on_room_occupants_snapshot_ready);
        occupant_batch_handler = muc_manager.room_occupants_changed_batch.connect(on_room_occupants_changed_batch);
        var avatar_manager = stream_interactor.get_module<AvatarManager>(AvatarManager.IDENTITY);
        avatar_received_handler = avatar_manager.received_avatar.connect(on_avatar_changed);
        avatar_fetched_handler = avatar_manager.fetched_avatar.connect(on_avatar_changed);
        this.selection_model = new NoSelection(presentation_store);
        list_view.model = selection_model;
        initialize_for_conversation(conversation);
    }

    private void setup_list_view() {
        var factory = new SignalListItemFactory();
        factory.setup.connect((obj) => {
            int64 timing_started_us = presentation_timing_active ? Dino.Ui.UiTiming.now_us() : 0;
            var list_item = obj as Gtk.ListItem;
            if (list_item == null) return;

            var row = new ListRow();
            Widget widget = row.get_widget();
            factory_rows[widget] = row;
            list_item.child = widget;
            if (presentation_timing_active) {
                presentation_factory_setup_count++;
                presentation_factory_setup_us += Dino.Ui.UiTiming.now_us() - timing_started_us;
            }
        });
        factory.bind.connect((obj) => {
            int64 timing_started_us = presentation_timing_active ? Dino.Ui.UiTiming.now_us() : 0;
            var list_item = obj as Gtk.ListItem;
            if (list_item == null || list_item.child == null) return;

            var row = factory_rows[list_item.child];
            var item = list_item.get_item() as OccupantListItem;
            if (row == null || item == null) return;

            list_item.activatable = !item.is_header;
            list_item.selectable = !item.is_header;
            row.bind(stream_interactor, conversation, item);
            if (presentation_timing_active) {
                presentation_factory_bind_count++;
                presentation_factory_bind_us += Dino.Ui.UiTiming.now_us() - timing_started_us;
            }
        });
        factory.unbind.connect((obj) => {
            var list_item = obj as Gtk.ListItem;
            if (list_item == null || list_item.child == null) return;

            var row = factory_rows[list_item.child];
            if (row != null) row.unbind();
        });
        factory.teardown.connect((obj) => {
            var list_item = obj as Gtk.ListItem;
            if (list_item == null || list_item.child == null) return;

            var row = factory_rows[list_item.child];
            if (row != null) row.cleanup();
            factory_rows.unset(list_item.child);
        });
        list_view.factory = factory;
        list_view.single_click_activate = true;
        list_view.activate.connect((position) => {
            if (position >= presentation_store.get_n_items()) return;

            var item = presentation_store.get_item(position) as OccupantListItem;
            if (item == null || item.is_header || item.jid == null) return;

            if (Dino.Ui.UiTiming.enabled()) {
                GLib.message("UI-TIMING OccupantList.activate: position=%u jid=%s",
                    position, ((!) item.jid).to_string());
            }
            occupant_activated((!) item.jid, item.display_name);
        });
    }

    public void cleanup() {
        while (cleanup_step()) {}
    }

    public bool cleanup_step() {
        bool timing_enabled = Dino.Ui.UiTiming.enabled();
        int64 t_total_us = timing_enabled ? Dino.Ui.UiTiming.now_us() : 0;
        int rows_before = timing_enabled ? factory_rows.size : 0;
        uint store_before = timing_enabled ? presentation_store.get_n_items() : 0;
        begin_cleanup();
        int64 started_us = Dino.Ui.UiTiming.now_us();

        if (cleanup_pending_rows != null) {
            int cleaned_rows = 0;
            while (((!) cleanup_pending_rows).size > 0 && cleaned_rows < CLEANUP_ROW_BATCH_SIZE) {
                ListRow row = ((!) cleanup_pending_rows).remove_at(((!) cleanup_pending_rows).size - 1);
                row.discard_for_list_cleanup();
                cleaned_rows++;
                if (Dino.Ui.UiTiming.now_us() - started_us >= CLEANUP_WORK_BUDGET_US) break;
            }
            if (((!) cleanup_pending_rows).size > 0) return true;
            cleanup_pending_rows = null;
        }

        int removed_items = 0;
        while (presentation_store.get_n_items() > 0 && removed_items < CLEANUP_STORE_BATCH_SIZE) {
            uint last_item = presentation_store.get_n_items() - 1;
            presentation_store.remove(last_item);
            removed_items++;
            if (Dino.Ui.UiTiming.now_us() - started_us >= CLEANUP_WORK_BUDGET_US) break;
        }
        if (presentation_store.get_n_items() > 0) return true;

        if (!cleanup_model_detached) {
            detach_visible_model();
            cleanup_model_detached = true;
        }

        finish_cleanup();
        if (timing_enabled) {
            Dino.Ui.UiTiming.log_ms("OccupantList.cleanup_step: complete rows_before=%d pending_rows=%d store_before=%u store_after=%u".printf(rows_before, cleanup_pending_rows != null ? ((!) cleanup_pending_rows).size : 0, store_before, presentation_store.get_n_items()), t_total_us);
        }
        return false;
    }

    private void begin_cleanup() {
        bool timing_enabled = Dino.Ui.UiTiming.enabled();
        int64 t_total_us = timing_enabled ? Dino.Ui.UiTiming.now_us() : 0;
        if (cleanup_started) return;
        cleanup_started = true;
        disposed = true;
        int rows_before = timing_enabled ? factory_rows.size : 0;
        uint store_before = timing_enabled ? presentation_store.get_n_items() : 0;
        hide_for_deferred_cleanup();
        cancel_loading();
        cancel_cache_refresh();
        cancel_detail_refresh();
        cancel_presentation_rebuild();
        cancel_deferred_updates();
        cancel_initial_snapshot_watch();
        cancel_room_snapshot_apply();
        if (occupant_update_timeout != 0) {
            Source.remove(occupant_update_timeout);
            occupant_update_timeout = 0;
        }
        if (presence_update_timeout != 0) {
            Source.remove(presence_update_timeout);
            presence_update_timeout = 0;
        }
        pending_presence_jids.clear();
        pending_avatar_refresh = false;
        disconnect_external_handlers();
        cleanup_pending_rows = new ArrayList<ListRow>();
        foreach (ListRow row in factory_rows.values) {
            ((!) cleanup_pending_rows).add(row);
        }
        factory_rows.clear();
        // Keep the hidden model attached until its store has been drained in
        // cleanup_step(). Detaching a populated Gtk.ListView tears down every
        // realized row synchronously and used to block the next conversation
        // selection for hundreds of milliseconds.
        if (timing_enabled) {
            Dino.Ui.UiTiming.log_ms("OccupantList.begin_cleanup: rows_before=%d pending_rows=%d store_before=%u".printf(rows_before, ((!) cleanup_pending_rows).size, store_before), t_total_us);
        }
    }

    private void finish_cleanup() {
        if (cleanup_state_cleared) return;
        cleanup_state_cleared = true;
        presentation_complete = false;
        empty_partial_surface_active = false;
        all_occupants.clear();
        summary_counts.clear();
    }

    public void deactivate_for_deferred_cleanup() {
        bool timing_enabled = Dino.Ui.UiTiming.enabled();
        int64 t_total_us = timing_enabled ? Dino.Ui.UiTiming.now_us() : 0;
        if (disposed) return;

        bool has_pending_commit = presentation_commit_source != 0 ||
            presentation_commit_map_tick != 0;
        bool had_pending_updates = pending_rebuild || pending_presence_rebuild ||
                pending_presence_jids.size > 0 || presentation_rebuild_source != 0 ||
                (has_pending_commit && !is_valid_cached_reveal_commit());
        int rows_before = timing_enabled ? factory_rows.size : 0;
        uint store_before = timing_enabled ? presentation_store.get_n_items() : 0;
        bool model_attached_before = timing_enabled && list_view.model != null;
        disposed = true;
        background_work_suspended = true;
        hide_for_deferred_cleanup();
        cancel_loading();
        cancel_cache_refresh();
        cancel_detail_refresh();
        cancel_presentation_rebuild();
        cancel_deferred_updates(false, true);
        cancel_initial_snapshot_watch();
        cancel_room_snapshot_apply();
        if (occupant_update_timeout != 0) {
            Source.remove(occupant_update_timeout);
            occupant_update_timeout = 0;
        }
        if (presence_update_timeout != 0) {
            Source.remove(presence_update_timeout);
            presence_update_timeout = 0;
        }
        if (had_pending_updates) {
            pending_summary_refresh = true;
            pending_rebuild = true;
            presentation_complete = false;
            cache.details_loaded = false;
            invalidate_cached_presentation();
        }
        disconnect_external_handlers();
        if (timing_enabled) {
            Dino.Ui.UiTiming.log_ms("OccupantList.deactivate_for_deferred_cleanup: rows=%d store=%u model_attached=%s pending_updates=%s".printf(rows_before, store_before, model_attached_before.to_string(), had_pending_updates.to_string()), t_total_us);
        }
    }

    private void hide_for_deferred_cleanup() {
        bool timing_enabled = Dino.Ui.UiTiming.enabled();
        int64 t_total_us = timing_enabled ? Dino.Ui.UiTiming.now_us() : 0;
        bool model_attached_before = timing_enabled && list_view.model != null;
        uint store_before = timing_enabled ? presentation_store.get_n_items() : 0;
        hide_list_surface();
        if (timing_enabled) {
            Dino.Ui.UiTiming.log_ms("OccupantList.hide_for_deferred_cleanup: model_attached=%s store=%u".printf(model_attached_before.to_string(), store_before), t_total_us);
        }
    }

    private void hide_list_surface() {
        scrolled_window.visible = false;
        show_list_button.visible = false;
        loading_spinner.stop();
        loading_box.visible = false;
    }

    private void disconnect_external_handlers() {
        if (presence_observer != null) {
            ((!) presence_observer).unsubscribe();
            presence_observer = null;
        }
        var muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        if (occupant_hats_handler != 0) {
            if (SignalHandler.is_connected(muc_manager, occupant_hats_handler)) {
                SignalHandler.disconnect(muc_manager, occupant_hats_handler);
            }
            occupant_hats_handler = 0;
        }
        if (occupant_affiliation_handler != 0) {
            if (SignalHandler.is_connected(muc_manager, occupant_affiliation_handler)) {
                SignalHandler.disconnect(muc_manager, occupant_affiliation_handler);
            }
            occupant_affiliation_handler = 0;
        }
        if (bare_affiliation_changed_handler != 0) {
            var muc_module = stream_interactor.module_manager.get_module<Xmpp.Xep.Muc.Module>(
                conversation.account, Xmpp.Xep.Muc.Module.IDENTITY);
            if (SignalHandler.is_connected(muc_module,
                    bare_affiliation_changed_handler)) {
                SignalHandler.disconnect(muc_module,
                    bare_affiliation_changed_handler);
            }
            bare_affiliation_changed_handler = 0;
        }
        if (occupant_role_handler != 0) {
            if (SignalHandler.is_connected(muc_manager, occupant_role_handler)) {
                SignalHandler.disconnect(muc_manager, occupant_role_handler);
            }
            occupant_role_handler = 0;
        }
        if (private_room_occupant_handler != 0) {
            if (SignalHandler.is_connected(muc_manager, private_room_occupant_handler)) {
                SignalHandler.disconnect(muc_manager, private_room_occupant_handler);
            }
            private_room_occupant_handler = 0;
        }
        if (real_jid_visibility_revoked_handler != 0) {
            if (SignalHandler.is_connected(muc_manager,
                    real_jid_visibility_revoked_handler)) {
                SignalHandler.disconnect(muc_manager,
                    real_jid_visibility_revoked_handler);
            }
            real_jid_visibility_revoked_handler = 0;
        }
        if (initial_sync_started_handler != 0) {
            if (SignalHandler.is_connected(muc_manager,
                    initial_sync_started_handler)) {
                SignalHandler.disconnect(muc_manager,
                    initial_sync_started_handler);
            }
            initial_sync_started_handler = 0;
        }
        if (occupant_projection_changed_handler != 0) {
            if (SignalHandler.is_connected(muc_manager,
                    occupant_projection_changed_handler)) {
                SignalHandler.disconnect(muc_manager,
                    occupant_projection_changed_handler);
            }
            occupant_projection_changed_handler = 0;
        }
        if (occupant_snapshot_handler != 0) {
            if (SignalHandler.is_connected(muc_manager, occupant_snapshot_handler)) {
                SignalHandler.disconnect(muc_manager, occupant_snapshot_handler);
            }
            occupant_snapshot_handler = 0;
        }
        if (occupant_batch_handler != 0) {
            if (SignalHandler.is_connected(muc_manager, occupant_batch_handler)) {
                SignalHandler.disconnect(muc_manager, occupant_batch_handler);
            }
            occupant_batch_handler = 0;
        }
        var avatar_manager = stream_interactor.get_module<AvatarManager>(AvatarManager.IDENTITY);
        if (avatar_received_handler != 0) {
            if (SignalHandler.is_connected(avatar_manager, avatar_received_handler)) {
                SignalHandler.disconnect(avatar_manager, avatar_received_handler);
            }
            avatar_received_handler = 0;
        }
        if (avatar_fetched_handler != 0) {
            if (SignalHandler.is_connected(avatar_manager, avatar_fetched_handler)) {
                SignalHandler.disconnect(avatar_manager, avatar_fetched_handler);
            }
            avatar_fetched_handler = 0;
        }
    }

    public void suspend_for_popover_close() {
        bool timing_enabled = Dino.Ui.UiTiming.enabled();
        int64 t_total_us = timing_enabled ? Dino.Ui.UiTiming.now_us() : 0;
        if (disposed) return;

        bool has_pending_commit = presentation_commit_source != 0 ||
            presentation_commit_map_tick != 0;
        bool had_pending_updates = pending_rebuild || pending_presence_rebuild ||
                pending_presence_jids.size > 0 || presentation_rebuild_source != 0 ||
                (has_pending_commit && !is_valid_cached_reveal_commit());
        bool keep_ready_presentation_attached = cache.loaded && presentation_complete && presentation_store.get_n_items() > 0 && !had_pending_updates;
        int rows_before = timing_enabled ? factory_rows.size : 0;
        uint store_before = timing_enabled ? presentation_store.get_n_items() : 0;
        bool model_attached_before = timing_enabled && list_view.model != null;
        background_work_suspended = true;
        cancel_loading();
        cancel_cache_refresh();
        cancel_detail_refresh();
        cancel_presentation_rebuild();
        cancel_deferred_updates(true);
        if (had_pending_updates) {
            pending_summary_refresh = true;
            pending_rebuild = true;
        }

        if (keep_ready_presentation_attached) {
            show_list_button.visible = false;
            loading_spinner.stop();
            loading_box.visible = false;
            if (timing_enabled) {
                Dino.Ui.UiTiming.log_ms("OccupantList.suspend_for_popover_close: keep_attached rows=%d store=%u model_attached=%s".printf(rows_before, store_before, model_attached_before.to_string()), t_total_us);
            }
            return;
        }

        scrolled_window.visible = false;
        if (!cache.loaded && !empty_partial_surface_active) {
            show_list_button.visible = false;
            if (all_occupants.size == 0) empty_partial_surface_active = true;
        } else if (empty_partial_surface_active) {
            show_list_button.visible = false;
        }
        if (timing_enabled) {
            Dino.Ui.UiTiming.log_ms("OccupantList.suspend_for_popover_close: keep_attached_pending rows=%d store=%u model_attached=%s pending_updates=%s".printf(rows_before, store_before, model_attached_before.to_string(), had_pending_updates.to_string()), t_total_us);
        }
    }

    public override void dispose() {
        cleanup();
        base.dispose();
    }

    public void initialize_for_conversation(Conversation conversation) {
        if (disposed) return;
        cancel_loading();
        cancel_cache_refresh();
        cancel_detail_refresh();
        cancel_presentation_rebuild();
        cancel_initial_snapshot_watch();
        cancel_room_snapshot_apply();
        waiting_for_initial_snapshot = false;
        waiting_for_uncached_initial_snapshot = false;
        empty_partial_surface_active = false;
        initial_snapshot_wait_started_us = 0;
        initial_snapshot_last_membership_change_us = 0;
        this.conversation = conversation;
        background_work_suspended = false;
        pending_avatar_refresh = false;
        this.cache_key = get_cache_key(conversation);
        this.cache = get_or_create_cache(cache_key);
        MucManager muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
        MucRoomKey? active_generation =
            muc_manager.get_room_occupant_generation(conversation.account,
                conversation.counterpart);
        if (!cache_matches_active_room_generation(active_generation)) {
            clear_cache_for_room_lifecycle(active_generation);
        }
        uint64 privacy_generation =
            muc_manager.get_room_real_jid_visibility_generation(
                conversation.account, conversation.counterpart);
        if (cache.real_jid_visibility_generation != privacy_generation) {
            // A static cache can outlive the List instance that observed a
            // whois/privacy revocation. Never reuse rows or a presentation
            // built while real bare JIDs were still visible.
            cache.occupants.clear();
            cache.presentation_items = null;
            cache.stable_occupants = null;
            cache.snapshot_stream_generation = 0;
            cache.snapshot_room_generation = 0;
            cache.snapshot_revision = 0;
            cache.loaded = false;
            cache.details_loaded = false;
            cache.real_jid_visibility_generation = privacy_generation;
            presentation_cache_generation++;
            presentation_store.remove_all();
            presentation_complete = false;
        }
        MucRoomDelta? stable_snapshot = muc_manager.get_room_occupants_snapshot(
            conversation.account, conversation.counterpart);
        bool usable_snapshot = stable_snapshot != null &&
            is_usable_room_snapshot((!) stable_snapshot);
        bool cached_snapshot_matches = usable_snapshot &&
            cache_matches_room_snapshot((!) stable_snapshot);
        bool snapshot_apply_pending = usable_snapshot && !cached_snapshot_matches;
        waiting_for_uncached_initial_snapshot = !cached_snapshot_matches &&
            should_wait_for_uncached_initial_snapshot();
        waiting_for_initial_snapshot = snapshot_apply_pending ||
            waiting_for_uncached_initial_snapshot ||
            (!cached_snapshot_matches && muc_manager.is_initial_presence_sync(
                conversation.account, conversation.counterpart));
        if (waiting_for_initial_snapshot) {
            initial_snapshot_wait_started_us = GLib.get_monotonic_time();
            initial_snapshot_last_membership_change_us = initial_snapshot_wait_started_us;
            schedule_initial_snapshot_watch();
        }

        Gee.List<Jid>? occupants = null;
        all_occupants.clear();
        all_occupant_index.clear();
        summary_counts.clear();

        if (cached_snapshot_matches && cache.stable_occupants != null) {
            foreach (Jid jid in (!) cache.stable_occupants) {
                if (all_occupant_index.add(jid)) all_occupants.add(jid);
            }
        } else if (!usable_snapshot && active_generation != null) {
            occupants = muc_manager.get_occupants(conversation.counterpart,
                conversation.account);
            if (occupants != null) {
                foreach (Jid jid in occupants) {
                    if (all_occupant_index.add(jid)) all_occupants.add(jid);
                }
            }
        }
        refresh_private_member_snapshot_index();
        materialize_complete_member_snapshot();
        bool has_live_occupants = all_occupants.size > 0;
        refresh_room_size_state();
        if (has_live_occupants && !is_initial_presence_sync()) {
            prune_cache_to_current_occupants();
        }
        materialize_cached_occupants();
        refresh_room_size_state();
        bool large_room_context = is_large_room_context();
        if (large_room_context) {
            if (!cached_snapshot_matches) invalidate_cached_presentation();
        } else if (sync_cached_live_items_from_state()) {
            invalidate_cached_presentation();
        }
        if (large_room_context) {
            update_summary_lightweight();
        } else {
            refresh_summary_counts_for_current_context();
        }

        if (snapshot_apply_pending) {
            schedule_room_snapshot_apply((!) stable_snapshot);
        }

        if (waiting_for_initial_snapshot) {
            if (has_authoritative_cached_snapshot() && cache.loaded &&
                    can_reuse_cached_presentation()) {
                begin_presentation_commit((!) cache.presentation_items, true, true);
            } else {
                detach_visible_model();
                presentation_store.remove_all();
                presentation_complete = false;
                show_list_button.visible = false;
                scrolled_window.visible = false;
                loading_box.visible = true;
                loading_spinner.start();
                update_loading_progress(0, 0, true);
            }
            return;
        }

        if (all_occupants.size == 0) {
            enter_stable_empty_snapshot_surface();
            return;
        }

        if (cache.loaded) {
            scrolled_window.visible = false;
            show_list_button.visible = false;
            loading_box.visible = true;
            loading_spinner.start();
            if (can_reuse_cached_presentation()) {
                begin_presentation_commit((!) cache.presentation_items, true, true);
            } else {
                rebuild_presentation(true);
            }
        } else if (should_auto_start_loading_rows()) {
            start_loading_rows();
        } else {
            enter_stable_empty_snapshot_surface();
        }
    }

    private OccupantListCache get_or_create_cache(string key) {
        if (!model_cache.has_key(key)) {
            model_cache[key] = new OccupantListCache();
        }
        OccupantListCache cache = model_cache[key];
        cache.last_used_us = GLib.get_monotonic_time();
        prune_model_cache(key);
        return cache;
    }

    private void prune_model_cache(string keep_key) {
        while (model_cache.size > MODEL_CACHE_LIMIT) {
            string? oldest_key = null;
            int64 oldest_seen_us = 0;
            foreach (string key in model_cache.keys) {
                if (key == keep_key) continue;

                OccupantListCache candidate = model_cache[key];
                if (oldest_key == null || candidate.last_used_us < oldest_seen_us) {
                    oldest_key = key;
                    oldest_seen_us = candidate.last_used_us;
                }
            }
            if (oldest_key == null) break;
            model_cache.unset((!) oldest_key);
        }
    }

    private bool is_usable_room_snapshot(MucRoomDelta delta) {
        // A degraded or structurally partial display snapshot may supplement
        // existing state later, but it must never replace a visible member
        // list. A joined room also has at least the local occupant.
        return delta.full_snapshot && delta.initial_sync_finished &&
            !delta.degraded_partial && delta.occupant_count > 0 &&
            delta.changed_count == delta.occupant_count;
    }

    private bool has_authoritative_cached_snapshot() {
        return cache.stable_occupants != null &&
            cache.snapshot_stream_generation != 0 &&
            cache.snapshot_room_generation != 0;
    }

    private bool has_stable_complete_presentation() {
        if (!has_authoritative_cached_snapshot() || !cache.loaded) return false;

        bool commit_pending = is_valid_cached_reveal_commit();
        bool cached_rows = cache.presentation_items != null &&
            count_occupant_items((!) cache.presentation_items) > 0;
        return (presentation_complete && presentation_store.get_n_items() > 0) ||
            commit_pending || cached_rows;
    }

    private void enter_stable_empty_snapshot_surface() {
        // Zero members is never an authoritative state for a joined MUC: the
        // local occupant alone makes every complete room snapshot non-empty.
        // Discard partial generation state and keep one automatic, empty list
        // surface until a complete worker snapshot replaces it.
        cancel_loading();
        cancel_cache_refresh();
        cancel_detail_refresh();
        cancel_presentation_rebuild();
        cancel_deferred_updates();
        all_occupants.clear();
        all_occupant_index.clear();
        private_member_snapshot_bare_jids.clear();
        private_member_snapshot_complete = false;
        cache.occupants.clear();
        cache.stable_occupants = new ArrayList<Jid>(Jid.equals_func);
        cache.snapshot_stream_generation = 0;
        cache.snapshot_room_generation = 0;
        cache.snapshot_revision = 0;
        cache.loaded = false;
        cache.details_loaded = false;
        presentation_cache_generation++;
        cache.presentation_items = null;
        pending_rebuild = false;
        pending_presence_rebuild = false;
        pending_summary_refresh = false;
        pending_presence_jids.clear();
        summary_counts.clear();
        update_summary();

        detach_visible_model();
        presentation_store.remove_all();
        presentation_complete = false;
        attach_visible_model();
        empty_partial_surface_active = true;
        show_list_button.visible = false;
        loading_spinner.stop();
        loading_box.visible = false;
        scrolled_window.visible = !background_work_suspended;
    }

    private bool cache_matches_room_snapshot(MucRoomDelta delta) {
        return cache.stable_occupants != null &&
            cache.snapshot_stream_generation == delta.room.stream_generation &&
            cache.snapshot_room_generation == delta.room.room_generation &&
            cache.snapshot_revision == delta.revision;
    }

    private bool cache_matches_active_room_generation(
            MucRoomKey? active_generation) {
        if (active_generation == null) {
            return cache.lifecycle_stream_generation == 0 &&
                cache.lifecycle_room_generation == 0;
        }
        return cache.lifecycle_stream_generation ==
                ((!) active_generation).stream_generation &&
            cache.lifecycle_room_generation ==
                ((!) active_generation).room_generation;
    }

    private void clear_cache_for_room_lifecycle(
            MucRoomKey? active_generation) {
        cache.occupants.clear();
        cache.presentation_items = null;
        cache.stable_occupants = null;
        cache.snapshot_stream_generation = 0;
        cache.snapshot_room_generation = 0;
        cache.snapshot_revision = 0;
        cache.lifecycle_stream_generation = active_generation != null
            ? ((!) active_generation).stream_generation : 0;
        cache.lifecycle_room_generation = active_generation != null
            ? ((!) active_generation).room_generation : 0;
        cache.loaded = false;
        cache.details_loaded = false;
        cache.known_large_room = false;
        presentation_cache_generation++;
        presentation_store.remove_all();
        presentation_complete = false;
    }

    private void on_room_initial_sync_started(Account account, Jid room_jid) {
        if (disposed || !conversation.account.equals(account) ||
                !conversation.counterpart.equals_bare(room_jid)) return;

        MucRoomKey? active_generation = stream_interactor.get_module<
            MucManager>(MucManager.IDENTITY).get_room_occupant_generation(
                account, room_jid);

        // This signal marks the generation boundary and is emitted before
        // worker startup can fail. Stop exposing names, avatars and any
        // real-JID-derived rows from the previous join immediately.
        cancel_loading();
        cancel_cache_refresh();
        cancel_detail_refresh();
        cancel_presentation_rebuild();
        cancel_deferred_updates();
        cancel_initial_snapshot_watch();
        cancel_room_snapshot_apply();
        clear_cache_for_room_lifecycle(active_generation);
        all_occupants.clear();
        all_occupant_index.clear();
        private_member_snapshot_bare_jids.clear();
        private_member_snapshot_complete = false;
        summary_counts.clear();
        pending_presence_jids.clear();
        pending_avatar_refresh = false;
        pending_presence_rebuild = false;
        pending_summary_refresh = false;
        pending_rebuild = false;
        empty_partial_surface_active = false;
        waiting_for_initial_snapshot = true;
        waiting_for_uncached_initial_snapshot = true;
        initial_snapshot_wait_started_us = GLib.get_monotonic_time();
        initial_snapshot_last_membership_change_us =
            initial_snapshot_wait_started_us;
        detach_visible_model();
        show_list_button.visible = false;
        scrolled_window.visible = false;
        loading_box.visible = true;
        loading_spinner.start();
        update_loading_progress(0, 0, true);
        schedule_initial_snapshot_watch();
    }

    private void on_room_occupants_snapshot_ready(Account account, Jid room,
            MucRoomDelta delta) {
        if (disposed || !conversation.account.equals(account) ||
                !conversation.counterpart.equals_bare(room) ||
                !is_usable_room_snapshot(delta)) return;

        if (cache_matches_room_snapshot(delta)) {
            if (waiting_for_initial_snapshot) {
                finish_initial_snapshot_wait_from_authoritative_snapshot();
            }
            return;
        }
        schedule_room_snapshot_apply(delta);
    }

    private void on_room_occupants_changed_batch(Account account, Jid room,
            MucRoomDelta delta) {
        if (disposed || !conversation.account.equals(account) ||
                !conversation.counterpart.equals_bare(room) ||
                delta.room.account_id != account.id ||
                delta.room.room_bare_jid !=
                    conversation.counterpart.bare_jid.to_string() ||
                delta.full_snapshot || !delta.initial_sync_finished) return;

        if (delta.degraded_partial) {
            rebuild_from_authoritative_presence_after_live_batch_failure();
            return;
        }

        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        if (snapshot_apply_source != 0 && pending_room_snapshot != null) {
            // A full snapshot can take several bounded main-loop slices in a
            // large room. Live batches advance the worker snapshot while that
            // apply is running; keep the current cursor intact and coalesce
            // those advances into one latest full-snapshot follow-up.
            room_snapshot_followup_pending = true;
            return;
        }
        if (cache.stable_occupants == null ||
                cache.snapshot_stream_generation != delta.room.stream_generation ||
                cache.snapshot_room_generation != delta.room.room_generation ||
                waiting_for_initial_snapshot) {
            MucRoomDelta? current = muc_manager.get_room_occupants_snapshot(
                conversation.account, conversation.counterpart);
            if (current != null && is_usable_room_snapshot((!) current)) {
                schedule_room_snapshot_apply((!) current);
            } else {
                rebuild_from_authoritative_presence_after_live_batch_failure();
            }
            return;
        }
        if (delta.revision <= cache.snapshot_revision) return;

        var removed = new ArrayList<Jid>(Jid.equals_func);
        var changed_jids = new ArrayList<Jid>(Jid.equals_func);
        var changed_states = new HashMap<Jid, MucOccupantSnapshot>(
            Jid.hash_func, Jid.equals_func);
        for (uint i = 0; i < delta.removed_count; i++) {
            try {
                Jid occupant = new Jid(delta.removed_at(i));
                if (!is_room_occupant_jid(occupant)) {
                    rebuild_from_authoritative_presence_after_live_batch_failure();
                    return;
                }
                removed.add(occupant);
            } catch (InvalidJidError e) {
                rebuild_from_authoritative_presence_after_live_batch_failure();
                return;
            }
        }
        for (uint i = 0; i < delta.changed_count; i++) {
            MucOccupantSnapshot snapshot = delta.changed_at(i);
            try {
                Jid occupant = new Jid(snapshot.occupant_full_jid);
                if (!snapshot.available || !is_room_occupant_jid(occupant)) {
                    rebuild_from_authoritative_presence_after_live_batch_failure();
                    return;
                }
                changed_jids.add(occupant);
                changed_states[occupant] = snapshot;
            } catch (InvalidJidError e) {
                rebuild_from_authoritative_presence_after_live_batch_failure();
                return;
            }
        }

        bool state_changed = false;
        bool presentation_changed = removed.size > 0;
        bool summary_changed = removed.size > 0;
        foreach (Jid occupant in removed) {
            state_changed = remove_occupant_from_state(occupant) || state_changed;
        }
        bool private_identity_changed = false;
        for (uint i = 0; i < delta.changed_count; i++) {
            Jid occupant = changed_jids[(int) i];
            MucOccupantSnapshot snapshot = changed_states[occupant];
            MucOccupantChange change = delta.changed_flags_at(i);
            state_changed = add_occupant_to_state(occupant, false) ||
                state_changed;
            if ((change & (MucOccupantChange.MEMBERSHIP |
                    MucOccupantChange.NICK |
                    MucOccupantChange.AFFILIATION |
                    MucOccupantChange.ROLE |
                    MucOccupantChange.REAL_JID)) != 0 ||
                    ((change & MucOccupantChange.HATS) != 0 &&
                        filter_values != null)) {
                presentation_changed = true;
            }
            if ((change & (MucOccupantChange.MEMBERSHIP |
                    MucOccupantChange.AFFILIATION |
                    MucOccupantChange.ROLE)) != 0) {
                summary_changed = true;
            }
            OccupantListItem item = ensure_item(occupant, false,
                !should_defer_expensive_details());
            apply_snapshot_item_state(item, snapshot);
            if (!background_work_suspended) item.notify_changed();
            if ((change & MucOccupantChange.REAL_JID) != 0) {
                private_identity_changed = true;
                refresh_realized_avatar(occupant);
            }
        }
        if (removed.size > 0 || private_identity_changed) {
            state_changed = refresh_private_member_snapshot_index() ||
                state_changed;
            state_changed = reconcile_private_member_snapshot() ||
                state_changed;
        }
        presentation_changed = presentation_changed || state_changed;
        summary_changed = summary_changed || state_changed;

        cache.snapshot_stream_generation = delta.room.stream_generation;
        cache.snapshot_room_generation = delta.room.room_generation;
        cache.snapshot_revision = delta.revision;
        cache.details_loaded = false;
        if (all_occupants.size == 0) {
            cancel_loading();
            cancel_cache_refresh();
            cancel_detail_refresh();
            cancel_presentation_rebuild();
            enter_stable_empty_snapshot_surface();
            return;
        }
        if (background_work_suspended) {
            // Cached state is current, but detached rows were deliberately not
            // notified. Rebind once when the popover is opened again.
            invalidate_cached_presentation();
            pending_summary_refresh = pending_summary_refresh ||
                summary_changed;
            pending_rebuild = true;
            return;
        }

        if (presentation_changed) {
            invalidate_cached_presentation();
            if (summary_changed) refresh_summary_counts_for_current_context();
            schedule_rebuild();
        }
        if (state_changed) resume_loading_after_empty_state();
    }

    private void rebuild_from_authoritative_presence_after_live_batch_failure() {
        if (disposed) return;

        cancel_room_snapshot_apply();
        if (waiting_for_initial_snapshot) {
            release_initial_snapshot_wait_for_partial_display(
                "live-batch-fallback");
            return;
        }
        cancel_loading();
        cancel_cache_refresh();
        cancel_detail_refresh();
        cancel_presentation_rebuild();

        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        Gee.List<Jid>? occupants = muc_manager.get_occupants(
            conversation.counterpart, conversation.account);
        all_occupants.clear();
        all_occupant_index.clear();
        if (occupants != null) {
            foreach (Jid occupant in (!) occupants) {
                if (all_occupant_index.add(occupant)) {
                    all_occupants.add(occupant);
                }
            }
        }
        cache.snapshot_stream_generation = 0;
        cache.snapshot_room_generation = 0;
        cache.snapshot_revision = 0;
        cache.stable_occupants = new ArrayList<Jid>(Jid.equals_func);
        ((!) cache.stable_occupants).add_all(all_occupants);
        refresh_private_member_snapshot_index();
        materialize_complete_member_snapshot();
        refresh_room_size_state();
        if (all_occupants.size > 0) prune_cache_to_current_occupants();
        materialize_cached_occupants();
        invalidate_cached_presentation();
        refresh_summary_counts_for_current_context();

        if (all_occupants.size == 0) {
            enter_stable_empty_snapshot_surface();
            return;
        }
        if (background_work_suspended) {
            pending_summary_refresh = true;
            pending_rebuild = true;
            return;
        }
        if (cache.loaded) {
            rebuild_presentation();
        } else {
            start_loading_rows();
        }
    }

    private void schedule_room_snapshot_apply(MucRoomDelta delta) {
        if (disposed || !is_usable_room_snapshot(delta)) return;

        if (snapshot_apply_source != 0 && pending_room_snapshot != null) {
            room_snapshot_followup_pending = true;
            return;
        }

        bool generation_changed =
            cache.snapshot_stream_generation != delta.room.stream_generation ||
            cache.snapshot_room_generation != delta.room.room_generation;
        cancel_room_snapshot_apply();
        if (generation_changed && !has_stable_complete_presentation()) {
            cancel_loading();
            cancel_cache_refresh();
            cancel_detail_refresh();
            cancel_presentation_rebuild();
            enter_stable_empty_snapshot_surface();
        }
        show_list_button.visible = false;
        pending_room_snapshot = delta;
        staged_snapshot_occupants = new ArrayList<Jid>(Jid.equals_func);
        staged_snapshot_index = new HashSet<Jid>(Jid.hash_func, Jid.equals_func);
        staged_snapshot_states = new HashMap<Jid, MucOccupantSnapshot>(
            Jid.hash_func, Jid.equals_func);
        snapshot_live_removals.clear();
        staged_snapshot_position = 0;
        snapshot_apply_started_us = Dino.Ui.UiTiming.now_us();

        if (!waiting_for_initial_snapshot) {
            waiting_for_initial_snapshot = true;
            waiting_for_uncached_initial_snapshot = !cache.loaded;
            initial_snapshot_wait_started_us = GLib.get_monotonic_time();
            initial_snapshot_last_membership_change_us =
                initial_snapshot_wait_started_us;
            schedule_initial_snapshot_watch();
        } else if (!cache.loaded) {
            waiting_for_uncached_initial_snapshot = true;
        }

        uint generation = ++snapshot_apply_generation;
        // This source exists only for a visible member-list consumer and each
        // callback is strictly bounded. Run it before the lower-value
        // compatibility fanout so the committed snapshot becomes visible
        // without waiting for every legacy per-occupant signal.
        snapshot_apply_source = Idle.add_full(GLib.Priority.DEFAULT,
            () => process_room_snapshot_apply(generation));
    }

    private bool process_room_snapshot_apply(uint generation) {
        if (disposed || generation != snapshot_apply_generation ||
                pending_room_snapshot == null ||
                staged_snapshot_occupants == null ||
                staged_snapshot_index == null ||
                staged_snapshot_states == null) {
            snapshot_apply_source = 0;
            return Source.REMOVE;
        }

        MucRoomDelta delta = (!) pending_room_snapshot;
        int64 deadline_us = GLib.get_monotonic_time() + WORK_BUDGET_US;
        uint processed = 0;
        while (staged_snapshot_position < delta.changed_count &&
                processed < SNAPSHOT_APPLY_BATCH_SIZE &&
                GLib.get_monotonic_time() < deadline_us) {
            MucOccupantSnapshot snapshot = delta.changed_at(
                staged_snapshot_position++);
            Jid occupant;
            try {
                occupant = new Jid(snapshot.occupant_full_jid);
            } catch (InvalidJidError e) {
                return abort_room_snapshot_apply_to_fallback();
            }
            if (!snapshot.available || !occupant.is_full() ||
                    !conversation.counterpart.equals_bare(occupant)) {
                return abort_room_snapshot_apply_to_fallback();
            }
            if (((!) staged_snapshot_index).add(occupant)) {
                ((!) staged_snapshot_occupants).add(occupant);
                ((!) staged_snapshot_states)[occupant] = snapshot;
            }
            processed++;
        }
        if (staged_snapshot_position < delta.changed_count) return Source.CONTINUE;

        snapshot_apply_source = 0;
        if (((!) staged_snapshot_occupants).size != (int) delta.occupant_count) {
            request_current_room_snapshot_followup();
            if (continue_with_room_snapshot_followup()) return Source.REMOVE;
            return abort_room_snapshot_apply_to_fallback();
        }
        bool committed = commit_room_snapshot(delta);
        clear_room_snapshot_apply_state();
        if (continue_with_room_snapshot_followup()) return Source.REMOVE;
        if (!committed && waiting_for_initial_snapshot) {
            release_initial_snapshot_wait_for_partial_display(
                "stale-snapshot");
        }
        return Source.REMOVE;
    }

    private bool abort_room_snapshot_apply_to_fallback() {
        snapshot_apply_source = 0;
        request_current_room_snapshot_followup();
        clear_room_snapshot_apply_state();
        if (continue_with_room_snapshot_followup()) return Source.REMOVE;
        if (waiting_for_initial_snapshot) {
            release_initial_snapshot_wait_for_partial_display(
                "snapshot-apply-abort");
        }
        return Source.REMOVE;
    }

    private bool commit_room_snapshot(MucRoomDelta delta) {
        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        MucRoomDelta? current = muc_manager.get_room_occupants_snapshot(
                conversation.account, conversation.counterpart);
        if (current == null || ((!) current) != delta ||
                staged_snapshot_occupants == null ||
                staged_snapshot_index == null ||
                staged_snapshot_states == null) {
            if (current != null && is_usable_room_snapshot((!) current)) {
                room_snapshot_followup_pending = true;
            }
            return false;
        }

        cancel_loading();
        cancel_cache_refresh();
        cancel_detail_refresh();
        cancel_presentation_rebuild();

        // The worker snapshot is the stable initial batch, but the live
        // PresenceManager can already be ahead when its main-context result
        // reaches this visible consumer (especially on Windows). Reconcile
        // membership once at the commit boundary so a valid live addition is
        // not erased by an older initial snapshot. This remains display-only;
        // OMEMO membership never consumes this cache.
        PresenceManager presence_manager = stream_interactor.get_module<PresenceManager>(
            PresenceManager.IDENTITY);
        var merged_occupants = new ArrayList<Jid>(Jid.equals_func);
        var merged_index = new HashSet<Jid>(Jid.hash_func, Jid.equals_func);
        foreach (Jid jid in (!) staged_snapshot_occupants) {
            if (snapshot_live_removals.contains(jid) ||
                    (jid.is_full() && !presence_manager.has_presence(
                        jid, conversation.account))) continue;
            if (merged_index.add(jid)) merged_occupants.add(jid);
        }
        uint live_merged = 0;
        Gee.List<Jid>? live_occupants = muc_manager.get_occupants(
            conversation.counterpart, conversation.account);
        if (live_occupants != null) {
            foreach (Jid jid in (!) live_occupants) {
                if (snapshot_live_removals.contains(jid)) continue;
                if (merged_index.add(jid)) {
                    merged_occupants.add(jid);
                    live_merged++;
                }
            }
        }
        // Preserve offline bare-JID rows from a complete private-room member
        // affiliation snapshot. They are not live PresenceManager resources.
        foreach (Jid jid in all_occupants) {
            if (!jid.is_bare() || !is_private_member_snapshot_jid(jid)) continue;
            if (merged_index.add(jid)) {
                merged_occupants.add(jid);
            }
        }
        all_occupants = merged_occupants;
        all_occupant_index = merged_index;

        cache.stable_occupants = new ArrayList<Jid>(Jid.equals_func);
        ((!) cache.stable_occupants).add_all(all_occupants);
        cache.snapshot_stream_generation = delta.room.stream_generation;
        cache.snapshot_room_generation = delta.room.room_generation;
        cache.snapshot_revision = delta.revision;
        cache.details_loaded = false;

        foreach (var entry in ((!) staged_snapshot_states).entries) {
            if (!all_occupant_index.contains(entry.key) ||
                    !cache.occupants.has_key(entry.key)) continue;
            apply_snapshot_item_state(cache.occupants[entry.key], entry.value);
        }
        if (waiting_for_initial_snapshot) {
            finish_initial_snapshot_wait_from_authoritative_snapshot();
        } else {
            // A UI deadline may already have exposed a partial, display-only
            // presence view.  The late complete worker snapshot is
            // authoritative and must visibly replace that partial view.
            present_current_occupants(true);
        }
        if (Dino.Ui.UiTiming.enabled()) {
            Dino.Ui.UiTiming.log_ms(
                ("OccupantList.commit_room_snapshot: occupants=%u live_merged=%u final=%d generation=%" +
                    uint64.FORMAT + " revision=%" + uint64.FORMAT).printf(
                        delta.occupant_count, live_merged, all_occupants.size,
                        delta.room.room_generation, delta.revision),
                snapshot_apply_started_us);
        }
        return true;
    }

    private void request_current_room_snapshot_followup() {
        MucManager manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        MucRoomDelta? current = manager.get_room_occupants_snapshot(
            conversation.account, conversation.counterpart);
        if (current != null && is_usable_room_snapshot((!) current) &&
                (pending_room_snapshot == null ||
                    ((!) current) != (!) pending_room_snapshot)) {
            room_snapshot_followup_pending = true;
        }
    }

    private bool continue_with_room_snapshot_followup() {
        bool has_followup = room_snapshot_followup_pending;
        room_snapshot_followup_pending = false;
        if (!has_followup) return false;

        // Re-read the local worker cache at the hand-off boundary. The flag
        // is only a coalescing marker; a privacy scrub can replace a
        // materialized snapshot at the same revision, and a later live batch
        // can advance it again before the current slice finishes.
        MucRoomDelta? current = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY).get_room_occupants_snapshot(
                conversation.account, conversation.counterpart);
        if (current == null || !is_usable_room_snapshot((!) current) ||
                cache_matches_room_snapshot((!) current)) {
            return false;
        }
        schedule_room_snapshot_apply((!) current);
        return true;
    }

    private void apply_snapshot_item_state(OccupantListItem item,
            MucOccupantSnapshot snapshot) {
        if (item.jid == null) return;

        // The occupant full JID/resource is the stable XEP-0045 display
        // identity.  snapshot.nick is redundant for AVAILABLE state and must
        // never overwrite it; 303 transitions already arrive with a new full
        // JID.  This also keeps the small- and large-room paths identical.
        item.display_name = get_lightweight_display_name((!) item.jid);
        item.affiliation_known = snapshot.affiliation_known;
        item.affiliation = map_snapshot_affiliation(snapshot.affiliation);
        item.role_known = snapshot.role_known;
        item.role = map_snapshot_role(snapshot.role);
        apply_snapshot_hats(item, snapshot);
        apply_presence_state(item, (!) item.jid);
        item.details_loaded = false;
    }

    private Xmpp.Xep.Muc.Affiliation map_snapshot_affiliation(
            MucWorkerAffiliationState affiliation) {
        switch (affiliation) {
            case MucWorkerAffiliationState.MEMBER:
                return Xmpp.Xep.Muc.Affiliation.MEMBER;
            case MucWorkerAffiliationState.ADMIN:
                return Xmpp.Xep.Muc.Affiliation.ADMIN;
            case MucWorkerAffiliationState.OWNER:
                return Xmpp.Xep.Muc.Affiliation.OWNER;
            case MucWorkerAffiliationState.OUTCAST:
                return Xmpp.Xep.Muc.Affiliation.OUTCAST;
            case MucWorkerAffiliationState.NONE:
            case MucWorkerAffiliationState.UNKNOWN:
            default:
                return Xmpp.Xep.Muc.Affiliation.NONE;
        }
    }

    private Xmpp.Xep.Muc.Role map_snapshot_role(MucWorkerRoleState role) {
        switch (role) {
            case MucWorkerRoleState.VISITOR:
                return Xmpp.Xep.Muc.Role.VISITOR;
            case MucWorkerRoleState.PARTICIPANT:
                return Xmpp.Xep.Muc.Role.PARTICIPANT;
            case MucWorkerRoleState.MODERATOR:
                return Xmpp.Xep.Muc.Role.MODERATOR;
            case MucWorkerRoleState.NONE:
            case MucWorkerRoleState.UNKNOWN:
            default:
                return Xmpp.Xep.Muc.Role.NONE;
        }
    }

    private void cancel_room_snapshot_apply() {
        if (snapshot_apply_source != 0) {
            Source.remove(snapshot_apply_source);
            snapshot_apply_source = 0;
        }
        snapshot_apply_generation++;
        clear_room_snapshot_apply_state();
        room_snapshot_followup_pending = false;
    }

    private void clear_room_snapshot_apply_state() {
        pending_room_snapshot = null;
        staged_snapshot_occupants = null;
        staged_snapshot_index = null;
        staged_snapshot_states = null;
        snapshot_live_removals.clear();
        staged_snapshot_position = 0;
        snapshot_apply_started_us = 0;
    }

    private void materialize_cached_occupants() {
        if (!cache.loaded) return;

        bool has_missing = false;
        foreach (Jid jid in all_occupants) {
            if (!cache.occupants.has_key(jid)) {
                has_missing = true;
                break;
            }
        }
        if (!has_missing && !(!is_large_room_context() && !cache.details_loaded)) return;

        cache.details_loaded = false;
        invalidate_cached_presentation();

        bool load_details_now = !is_large_room_context();
        foreach (Jid jid in all_occupants) {
            if (load_details_now || !cache.occupants.has_key(jid)) {
                ensure_item(jid, true, load_details_now);
            }
        }
        if (load_details_now) cache.details_loaded = true;
    }

    private void refresh_room_size_state() {
        if (cache.known_large_room) return;
        if (all_occupants.size > AUTO_LOAD_LIMIT || cache.occupants.size > AUTO_LOAD_LIMIT) {
            cache.known_large_room = true;
            cache.details_loaded = false;
            foreach (OccupantListItem item in cache.occupants.values) {
                if (item.avatar_read_policy == Dino.AvatarReadPolicy.LOCAL_CACHE_ONLY) continue;
                item.avatar_read_policy = Dino.AvatarReadPolicy.LOCAL_CACHE_ONLY;
                item.notify_changed();
            }
        }
    }

    private bool is_initial_presence_sync() {
        return stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_initial_presence_sync(conversation.account, conversation.counterpart);
    }

    private bool is_large_room_context() {
        return cache.known_large_room || all_occupants.size > AUTO_LOAD_LIMIT || cache.occupants.size > AUTO_LOAD_LIMIT || is_initial_presence_sync();
    }

    private bool should_auto_start_loading_rows() {
        // Opening the titlebar member list is already an explicit request.
        // The batched path keeps large-room work bounded on every platform;
        // a second in-popover confirmation only creates an inconsistent state.
        return true;
    }

    private bool should_wait_for_uncached_initial_snapshot() {
#if WINDOWS
        return !cache.loaded;
#else
        return false;
#endif
    }

    private int initial_snapshot_quiet_period_ms() {
#if WINDOWS
        return InitialSnapshotWaitPolicy.SYNC_QUIET_MS;
#else
        return 0;
#endif
    }

    private int interactive_source_priority() {
#if WINDOWS
        // GLib idle sources can be starved for several seconds by the initial
        // MUC presence burst on Windows. Every callback below is bounded by a
        // small batch/time budget, so it can safely share normal event-loop
        // priority while the member list is visibly waiting for it.
        return GLib.Priority.DEFAULT;
#else
        return GLib.Priority.DEFAULT_IDLE;
#endif
    }

    private void schedule_initial_snapshot_watch() {
        if (initial_snapshot_watch_source != 0) return;

        // The watch only evaluates a few integers.  DEFAULT priority prevents
        // the visible deadline from being starved behind large idle batches.
        initial_snapshot_watch_source = Timeout.add_full(GLib.Priority.DEFAULT,
                250, () => {
            if (disposed || !waiting_for_initial_snapshot) {
                initial_snapshot_watch_source = 0;
                return Source.REMOVE;
            }
            int64 now_us = GLib.get_monotonic_time();
            int64 quiet_us = now_us - initial_snapshot_last_membership_change_us;
            int64 waited_us = now_us - initial_snapshot_wait_started_us;
            bool snapshot_apply_pending = snapshot_apply_source != 0 ||
                pending_room_snapshot != null;
            InitialSnapshotWaitDecision decision =
                InitialSnapshotWaitPolicy.decide(waited_us, quiet_us,
                    is_initial_presence_sync(),
                    waiting_for_uncached_initial_snapshot,
                    all_occupants.size, initial_snapshot_quiet_period_ms(),
                    snapshot_apply_pending);
            if (decision != InitialSnapshotWaitDecision.KEEP_WAITING) {
                initial_snapshot_watch_source = 0;
                release_initial_snapshot_wait_for_partial_display(
                    decision == InitialSnapshotWaitDecision.RELEASE_DEADLINE ?
                        "deadline" : "quiet-presence");
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
    }

    private void release_initial_snapshot_wait_for_partial_display(
            string reason) {
        if (!waiting_for_initial_snapshot || disposed) return;

        int64 wait_started_us = stop_initial_snapshot_wait();
        empty_partial_surface_active = false;

        bool invalidated_snapshot = reason == "stale-snapshot" ||
            reason == "snapshot-apply-abort" ||
            reason == "live-batch-fallback";
        if (invalidated_snapshot) {
            if (has_stable_complete_presentation()) {
                all_occupants.clear();
                all_occupant_index.clear();
                foreach (Jid jid in (!) cache.stable_occupants) {
                    if (all_occupant_index.add(jid)) all_occupants.add(jid);
                }
                present_current_occupants(false, true);
                show_list_button.visible = false;
            } else {
                cancel_loading();
                cancel_cache_refresh();
                cancel_detail_refresh();
                cancel_presentation_rebuild();
                enter_stable_empty_snapshot_surface();
            }
            if (Dino.Ui.UiTiming.enabled()) {
                Dino.Ui.UiTiming.log_ms(
                    "OccupantList.release_initial_snapshot_wait_for_partial_display: reason=%s stable_fallback=true".printf(
                        reason), wait_started_us);
            }
            return;
        }

        // Keep the last complete cache and merge currently known PresenceManager
        // rows additively for this display fallback.  Do not cancel a pending
        // worker apply, prune the cache from this partial presence set, or
        // replace the worker snapshot generation/revision.
        if (has_authoritative_cached_snapshot() &&
                cache.stable_occupants != null) {
            foreach (Jid jid in (!) cache.stable_occupants) {
                if (all_occupant_index.add(jid)) all_occupants.add(jid);
            }
        }
        Gee.List<Jid>? occupants = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY).get_occupants(conversation.counterpart,
                conversation.account);
        if (occupants != null) {
            foreach (Jid jid in occupants) {
                if (all_occupant_index.add(jid)) all_occupants.add(jid);
            }
        }
        if (Dino.Ui.UiTiming.enabled()) {
            Dino.Ui.UiTiming.log_ms(
                "OccupantList.release_initial_snapshot_wait_for_partial_display: reason=%s occupants=%d pending_snapshot=%s".printf(
                    reason, all_occupants.size,
                    (snapshot_apply_source != 0 || pending_room_snapshot != null).to_string()),
                wait_started_us);
        }
        present_current_occupants(false, true);

        bool presentation_commit_pending = presentation_commit_source != 0 ||
            presentation_commit_map_tick != 0;
        if (InitialSnapshotWaitPolicy.needs_empty_partial_surface(
                all_occupants.size, presentation_store.get_n_items() > 0,
                presentation_commit_pending)) {
            // Every non-authoritative release reason uses the same automatic
            // empty surface. A stale/cancelled generation is not a reason to
            // resurrect the retired manual trigger.
            enter_stable_empty_snapshot_surface();
            if (Dino.Ui.UiTiming.enabled()) {
                GLib.message(
                    "UI-TIMING OccupantList.release_initial_snapshot_wait_for_partial_display: empty_surface");
            }
        }
    }

    private int64 stop_initial_snapshot_wait() {
        int64 wait_started_us = initial_snapshot_wait_started_us;
        waiting_for_initial_snapshot = false;
        waiting_for_uncached_initial_snapshot = false;
        initial_snapshot_wait_started_us = 0;
        initial_snapshot_last_membership_change_us = 0;
        cancel_initial_snapshot_watch();
        return wait_started_us;
    }

    private void cancel_initial_snapshot_watch() {
        if (initial_snapshot_watch_source == 0) return;
        Source.remove(initial_snapshot_watch_source);
        initial_snapshot_watch_source = 0;
    }

    private void finish_initial_snapshot_wait_from_authoritative_snapshot() {
        if (!waiting_for_initial_snapshot || disposed) return;

        int64 wait_started_us = stop_initial_snapshot_wait();
        cancel_loading();
        cancel_presentation_rebuild();
        if (presence_update_timeout != 0) {
            Source.remove(presence_update_timeout);
            presence_update_timeout = 0;
        }
        pending_presence_jids.clear();
        pending_presence_rebuild = false;
        pending_rebuild = false;
        if (Dino.Ui.UiTiming.enabled()) {
            Dino.Ui.UiTiming.log_ms(
                "OccupantList.finish_initial_snapshot_wait_from_authoritative_snapshot: occupants=%d".printf(
                    all_occupants.size), wait_started_us);
        }
        present_current_occupants(true);
    }

    private void present_current_occupants(bool authoritative,
            bool keep_cached_presentation = false) {
        refresh_private_member_snapshot_index();
        materialize_complete_member_snapshot();
        refresh_room_size_state();
        if (authoritative && all_occupants.size > 0) {
            prune_cache_to_current_occupants();
        }
        materialize_cached_occupants();
        refresh_room_size_state();
        if (authoritative || all_occupants.size > 0) {
            empty_partial_surface_active = false;
        }

        // During a rejoin, keep the last complete presentation visible rather
        // than replacing it with a smaller partial PresenceManager view.  A
        // first-open list without a cached presentation is built from the
        // additive partial rows below, then replaced by the late full snapshot.
        bool cached_presentation_commit_pending =
            presentation_commit_source != 0 ||
            presentation_commit_map_tick != 0;
        if (!authoritative && keep_cached_presentation &&
                has_authoritative_cached_snapshot() &&
                InitialSnapshotWaitPolicy.can_keep_cached_presentation(
                    cache.loaded, presentation_store.get_n_items() > 0,
                    cached_presentation_commit_pending)) {
            if (!background_work_suspended &&
                    presentation_store.get_n_items() > 0) {
                attach_visible_model();
                scrolled_window.visible = true;
                show_list_button.visible = false;
                loading_spinner.stop();
                loading_box.visible = false;
            }
            if (background_work_suspended) {
                pending_summary_refresh = true;
                pending_rebuild = true;
            } else {
                resume_background_work();
            }
            return;
        }

        invalidate_cached_presentation();
        refresh_summary_counts_for_current_context();

        if (all_occupants.size == 0) {
            enter_stable_empty_snapshot_surface();
            return;
        }

        if (background_work_suspended) {
            pending_summary_refresh = true;
            pending_rebuild = true;
            return;
        }

        if (cache.loaded) {
            bool show_progress = presentation_store.get_n_items() == 0;
            rebuild_presentation(show_progress);
        } else if (should_auto_start_loading_rows()) {
            start_loading_rows();
        }
    }

    private void start_loading_rows() {
        if (disposed || waiting_for_initial_snapshot || cache.loaded || initializing) return;
        if (all_occupants.size == 0) {
            enter_stable_empty_snapshot_surface();
            return;
        }

        resume_background_work();
        show_list_button.visible = false;
        cancel_detail_refresh();
        detach_visible_model();
        presentation_store.remove_all();
        scrolled_window.visible = false;
        loading_box.visible = true;
        loading_spinner.start();
        update_loading_progress(0, all_occupants.size, true);

        initializing = true;
        uint generation = ++load_generation;
        batch_init_source = Idle.add_full(interactive_source_priority(), () => {
            if (disposed || generation != load_generation) {
                batch_init_source = 0;
                return Source.REMOVE;
            }
            batch_init_source = 0;
            load_queue = build_sorted_occupants();
            load_queue_index = new HashSet<Jid>(Jid.hash_func, Jid.equals_func);
            foreach (Jid jid in (!) load_queue) {
                ((!) load_queue_index).add(jid);
            }
            load_index = 0;
            update_loading_progress(0, ((!) load_queue).size, false);
            batch_init_source = Idle.add_full(interactive_source_priority(), () => process_load_batch(generation));
            return Source.REMOVE;
        });
    }

    private void cancel_loading() {
        load_generation++;
        if (batch_init_source != 0) {
            Source.remove(batch_init_source);
            batch_init_source = 0;
        }
        initializing = false;
        load_queue = null;
        load_queue_index = null;
        load_index = 0;
        loading_spinner.stop();
        loading_box.visible = false;
    }

    public void cancel_partial_loading() {
        background_work_suspended = true;
        cancel_deferred_updates();

        bool has_blocking_work = initializing || batch_init_source != 0 || cache_refresh_source != 0 || presentation_rebuild_source != 0 || presentation_commit_source != 0 || presentation_commit_map_tick != 0;
        bool has_active_work = has_blocking_work;
        if (!has_active_work) return;

        if (!has_blocking_work) return;

        cancel_loading();
        cancel_cache_refresh();
        cancel_presentation_rebuild();
        if (!cache.loaded) {
            if (all_occupants.size == 0) {
                enter_stable_empty_snapshot_surface();
            } else {
                detach_visible_model();
                presentation_store.remove_all();
                presentation_complete = false;
                scrolled_window.visible = false;
                show_list_button.visible = false;
            }
        } else {
            scrolled_window.visible = false;
        }
    }

    private void cancel_deferred_updates(bool keep_pending_presence = false, bool cancel_row_sources = true) {
        if (occupant_update_timeout != 0) {
            Source.remove(occupant_update_timeout);
            occupant_update_timeout = 0;
        }
        pending_rebuild = false;
        if (presence_update_timeout != 0) {
            Source.remove(presence_update_timeout);
            presence_update_timeout = 0;
        }
        if (summary_refresh_timeout != 0) {
            Source.remove(summary_refresh_timeout);
            summary_refresh_timeout = 0;
        }
        if (affiliation_rebuild_timeout != 0) {
            Source.remove(affiliation_rebuild_timeout);
            affiliation_rebuild_timeout = 0;
        }
        if (!keep_pending_presence) {
            pending_presence_jids.clear();
            pending_presence_rebuild = false;
        }
        if (cancel_row_sources) {
            foreach (ListRow row in factory_rows.values) {
                row.cancel_deferred_sources();
            }
        }
    }

    private void resume_background_work() {
        background_work_suspended = false;
        if (waiting_for_initial_snapshot) return;
        schedule_pending_summary_refresh();
        if (pending_presence_jids.size > 0 && presence_update_timeout == 0) {
            uint delay = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_initial_presence_sync(conversation.account, conversation.counterpart) ? 500 : 150;
            presence_update_timeout = Timeout.add_full(interactive_source_priority(), delay, () => flush_presence_updates());
        }
    }

    private bool flush_deferred_updates_for_reopen() {
        bool had_deferred_updates = pending_rebuild || pending_summary_refresh || pending_presence_rebuild || pending_presence_jids.size > 0;
        if (!had_deferred_updates) return false;

        if (presence_update_timeout != 0) {
            Source.remove(presence_update_timeout);
            presence_update_timeout = 0;
        }
        if (summary_refresh_timeout != 0) {
            Source.remove(summary_refresh_timeout);
            summary_refresh_timeout = 0;
        }
        if (occupant_update_timeout != 0) {
            Source.remove(occupant_update_timeout);
            occupant_update_timeout = 0;
        }
        if (affiliation_rebuild_timeout != 0) {
            Source.remove(affiliation_rebuild_timeout);
            affiliation_rebuild_timeout = 0;
        }

        bool rebuild_required = pending_rebuild || pending_presence_rebuild;
        if (pending_presence_jids.size > 0 || pending_presence_rebuild) {
            flush_presence_updates();
        }
        apply_pending_summary_refresh();

        if (occupant_update_timeout != 0) {
            Source.remove(occupant_update_timeout);
            occupant_update_timeout = 0;
        }
        if (affiliation_rebuild_timeout != 0) {
            Source.remove(affiliation_rebuild_timeout);
            affiliation_rebuild_timeout = 0;
        }

        rebuild_required = rebuild_required || pending_rebuild;
        pending_rebuild = false;
        return rebuild_required;
    }

    private bool prepare_reopen_rebuild() {
        bool show_progress = presentation_store.get_n_items() == 0;
        if (!show_progress) {
            // Keep the last complete snapshot visible while the replacement
            // model is prepared. Hiding it makes the popover look as if the
            // click was ignored and encourages repeated open/close clicks.
            if (list_view.model == null) attach_visible_model();
            scrolled_window.visible = true;
            show_list_button.visible = false;
            loading_spinner.stop();
            loading_box.visible = false;
        }
        return show_progress;
    }

    public void resume_auto_loading_if_needed() {
        bool timing_enabled = Dino.Ui.UiTiming.enabled();
        int64 t_total_us = timing_enabled ? Dino.Ui.UiTiming.now_us() : 0;
        if (disposed) return;

        uint store_before = timing_enabled ? presentation_store.get_n_items() : 0;
        bool model_attached_before = timing_enabled && list_view.model != null;
        background_work_suspended = false;
        if (presentation_commit_map_tick != 0 || presentation_commit_source != 0) {
            if (timing_enabled) {
                Dino.Ui.UiTiming.log_ms("OccupantList.resume_auto_loading_if_needed: presentation_commit_active store=%u".printf(store_before), t_total_us);
            }
            return;
        }
        flush_pending_avatar_updates();
        if (waiting_for_initial_snapshot) {
            if (empty_partial_surface_active && all_occupants.size == 0) {
                if (list_view.model == null) attach_visible_model();
                scrolled_window.visible = true;
                show_list_button.visible = false;
                loading_spinner.stop();
                loading_box.visible = false;
                if (timing_enabled) {
                    Dino.Ui.UiTiming.log_ms(
                        "OccupantList.resume_auto_loading_if_needed: waiting_empty_snapshot_surface",
                        t_total_us);
                }
                return;
            }
            if (!cache.loaded || presentation_store.get_n_items() == 0) {
                show_list_button.visible = false;
                scrolled_window.visible = false;
                loading_box.visible = true;
                loading_spinner.start();
            }
            if (timing_enabled) {
                Dino.Ui.UiTiming.log_ms("OccupantList.resume_auto_loading_if_needed: waiting_initial_snapshot occupants=%d store=%u".printf(all_occupants.size, store_before), t_total_us);
            }
            return;
        }
        if (empty_partial_surface_active && all_occupants.size == 0) {
            if (list_view.model == null) attach_visible_model();
            scrolled_window.visible = true;
            show_list_button.visible = false;
            loading_spinner.stop();
            loading_box.visible = false;
            if (timing_enabled) {
                Dino.Ui.UiTiming.log_ms(
                    "OccupantList.resume_auto_loading_if_needed: empty_partial_surface",
                    t_total_us);
            }
            return;
        }
        empty_partial_surface_active = false;
        bool force_rebuild = flush_deferred_updates_for_reopen();
        if (cache.loaded) {
            if (force_rebuild) {
                bool show_progress = prepare_reopen_rebuild();
                rebuild_presentation(show_progress);
                if (timing_enabled) {
                    Dino.Ui.UiTiming.log_ms("OccupantList.resume_auto_loading_if_needed: flushed_pending_rebuild store=%u model_attached=%s".printf(store_before, model_attached_before.to_string()), t_total_us);
                }
                return;
            }
            if (list_view.model == null && presentation_store.get_n_items() > 0) {
                attach_visible_model();
                scrolled_window.visible = true;
                show_list_button.visible = false;
                loading_spinner.stop();
                loading_box.visible = false;
            }
            if (pending_rebuild) {
                bool show_progress = prepare_reopen_rebuild();
                pending_rebuild = false;
                rebuild_presentation(show_progress);
            } else if (!presentation_complete || presentation_store.get_n_items() == 0) {
                if (can_reuse_cached_presentation()) {
                    begin_presentation_commit((!) cache.presentation_items, true, true);
                } else {
                    rebuild_presentation(true);
                }
            } else {
                if (list_view.model == null) attach_visible_model();
                scrolled_window.visible = true;
                show_list_button.visible = false;
                loading_spinner.stop();
                loading_box.visible = false;
                schedule_detail_refresh();
            }
            if (timing_enabled) {
                Dino.Ui.UiTiming.log_ms("OccupantList.resume_auto_loading_if_needed: cache_loaded store=%u model_attached=%s pending_rebuild=%s".printf(store_before, model_attached_before.to_string(), pending_rebuild.to_string()), t_total_us);
            }
            return;
        }
        if (!cache.loaded && all_occupants.size > 0 && should_auto_start_loading_rows()) {
            start_loading_rows();
        } else if (!cache.loaded && all_occupants.size == 0) {
            enter_stable_empty_snapshot_surface();
        }
        if (timing_enabled) {
            Dino.Ui.UiTiming.log_ms("OccupantList.resume_auto_loading_if_needed: cache_not_loaded store=%u model_attached=%s".printf(store_before, model_attached_before.to_string()), t_total_us);
        }
    }

    public void load_all_members() {
        if (disposed) return;

        if (waiting_for_initial_snapshot) {
            show_list_button.visible = false;
            scrolled_window.visible = false;
            loading_box.visible = true;
            loading_spinner.start();
            return;
        }

        resume_background_work();
        show_list_button.visible = false;
        if (cache.loaded) {
            if (!presentation_complete || presentation_store.get_n_items() == 0) {
                scrolled_window.visible = false;
                loading_box.visible = true;
                loading_spinner.start();
                if (can_reuse_cached_presentation()) {
                    begin_presentation_commit((!) cache.presentation_items, true, true);
                } else {
                    rebuild_presentation(true);
                }
            } else {
                loading_box.visible = false;
                scrolled_window.visible = true;
                schedule_detail_refresh();
            }
            return;
        }
        start_loading_rows();
    }

    public void reset_popover_state() {
        if (disposed) return;
        if (cache.loaded) {
            show_list_button.visible = false;
            scrolled_window.visible = presentation_complete && presentation_store.get_n_items() > 0;
        } else if (!initializing && batch_init_source == 0) {
            show_list_button.visible = false;
            if (all_occupants.size == 0) {
                enter_stable_empty_snapshot_surface();
            } else {
                start_loading_rows();
            }
        }
    }

    public void clear_selection() {
        // Gtk.NoSelection keeps no selected row. Method kept for popover lifecycle symmetry.
    }

    private bool process_load_batch(uint generation) {
        if (disposed || generation != load_generation) {
            batch_init_source = 0;
            return Source.REMOVE;
        }
        if (load_queue == null) {
            abort_loading_rows();
            return Source.REMOVE;
        }

        int64 deadline_us = GLib.get_monotonic_time() + WORK_BUDGET_US;
        bool load_details = !should_defer_expensive_details();
        while (load_index < ((!) load_queue).size) {
            int end = int.min(load_index + BATCH_SIZE, ((!) load_queue).size);
            while (load_index < end) {
                ensure_item(((!) load_queue)[load_index], true, load_details);
                load_index++;
                if (GLib.get_monotonic_time() >= deadline_us) break;
            }
            if (load_index < end || GLib.get_monotonic_time() >= deadline_us) break;
        }
        update_loading_progress(load_index, ((!) load_queue).size, false);

        if (load_index >= ((!) load_queue).size) {
            finish_loading_rows();
            return Source.REMOVE;
        }
        return Source.CONTINUE;
    }

    private void finish_loading_rows() {
        if (disposed) {
            abort_loading_rows();
            return;
        }
        int completed_queue_size = load_queue != null ? ((!) load_queue).size : 0;
        batch_init_source = 0;
        initializing = false;
        load_queue = null;
        load_queue_index = null;
        load_index = 0;
        if (completed_queue_size == 0) {
            cache.loaded = false;
            cache.details_loaded = false;
            if (all_occupants.size == 0) {
                enter_stable_empty_snapshot_surface();
            } else {
                start_loading_rows();
            }
            return;
        }
        cache.loaded = true;
        if (!should_defer_expensive_details()) cache.details_loaded = true;
        rebuild_presentation(true);
    }

    private void abort_loading_rows() {
        batch_init_source = 0;
        initializing = false;
        load_queue = null;
        load_queue_index = null;
        load_index = 0;
    }

    private void update_loading_progress(int loaded, int total, bool preparing) {
        if (loading_progress_preparing == preparing && loading_progress_loaded == loaded && loading_progress_total == total) return;
        loading_progress_preparing = preparing;
        loading_progress_loaded = loaded;
        loading_progress_total = total;

        if (preparing) {
            loading_label.label = _("Preparing member list...");
            return;
        }
        loading_label.label = _("Loading members %d / %d").printf(loaded, total);
    }

    private ArrayList<Jid> build_sorted_occupants() {
        var sorted = new ArrayList<Jid>(Jid.equals_func);
        sorted.add_all(all_occupants);
        if (should_defer_expensive_details()) return sorted;

        sorted.sort((a, b) => compare_occupants(a, b));
        return sorted;
    }

    private int compare_items(OccupantListItem a, OccupantListItem b) {
        int section_sort = MucMemberListSectionModel.rank(
            get_member_list_section(a)) - MucMemberListSectionModel.rank(
                get_member_list_section(b));
        if (section_sort != 0) return section_sort;
        int display_name_sort = a.display_name.collate(b.display_name);
        if (display_name_sort != 0) return display_name_sort;
        if (a.jid != null && b.jid != null) return ((!) a.jid).to_string().collate(((!) b.jid).to_string());
        if (a.jid == null && b.jid != null) return -1;
        if (a.jid != null && b.jid == null) return 1;
        return 0;
    }

    private int compare_occupants(Jid a, Jid b) {
        if (should_defer_expensive_details()) {
            return get_sort_name(a).collate(get_sort_name(b));
        }
        MucMemberListSection section_a = MucMemberListSectionModel.classify(
            has_affiliation(a), get_affiliation(a), has_role(a), get_role(a));
        MucMemberListSection section_b = MucMemberListSectionModel.classify(
            has_affiliation(b), get_affiliation(b), has_role(b), get_role(b));
        int section_sort = MucMemberListSectionModel.rank(section_a) -
            MucMemberListSectionModel.rank(section_b);
        if (section_sort != 0) return section_sort;
        return get_sort_name(a).collate(get_sort_name(b));
    }

    private string get_sort_name(Jid jid) {
        OccupantListItem? item = cache.occupants.has_key(jid) ? cache.occupants[jid] : null;
        if (item != null && item.display_name != "") return item.display_name;
        if (jid.resourcepart != null && jid.resourcepart != "") return jid.resourcepart;
        return jid.to_string();
    }

    private void refilter() {
        string[]? values = null;
        string str = search_entry.get_text().strip();
        if (str != "") values = str.split_set(" \t\r\n");
        filter_values = values;
        if (filter_values != null && !cache.loaded) {
            start_loading_rows();
            return;
        }
        if (cache.loaded) rebuild_presentation();
    }

    private OccupantListItem ensure_item(Jid jid, bool refresh, bool detailed = true) {
        OccupantListItem item;
        if (cache.occupants.has_key(jid)) {
            item = cache.occupants[jid];
        } else {
            item = new OccupantListItem.occupant(jid);
            cache.occupants[jid] = item;
        }
        // Opening or binding the member list is presentation-only. Avatar IQs
        // are produced from stabilized MUC worker deltas in AvatarManager,
        // never from a row or popover lifecycle.
        Dino.AvatarReadPolicy avatar_read_policy =
            Dino.AvatarReadPolicy.LOCAL_CACHE_ONLY;
        bool policy_changed = item.avatar_read_policy != avatar_read_policy;
        item.avatar_read_policy = avatar_read_policy;
        bool is_offline_member = is_private_member_snapshot_jid(jid);
        bool offline_state_changed = item.is_offline_member != is_offline_member;
        if (offline_state_changed) {
            item.is_offline_member = is_offline_member;
        }
        if (refresh) {
            if (detailed || item.details_loaded) {
                refresh_item(item);
            } else {
                refresh_item_lightweight(item);
            }
        } else if (policy_changed || offline_state_changed) {
            item.notify_changed();
        }
        return item;
    }

    private void refresh_item(OccupantListItem item) {
        if (item.jid == null) return;

        Jid jid = (!) item.jid;
        item.display_name = (item.is_offline_member
            ? get_lightweight_display_name(jid)
            : Util.get_participant_display_name(stream_interactor,
                conversation, jid)).make_valid();
        item.affiliation = get_affiliation(jid);
        item.affiliation_known = has_affiliation(jid);
        item.role = get_role(jid);
        item.role_known = has_role(jid);
        apply_presence_state(item, jid);
        if (item.is_offline_member) {
            item.hats_text = "";
            item.hats_markup = "";
            item.hats = new ArrayList<Xmpp.Xep.Muc.Hat>();
        } else {
            update_item_hats(item);
        }
        item.details_loaded = true;
        item.notify_changed();
    }

    private void refresh_item_lightweight(OccupantListItem item) {
        if (item.jid == null) return;

        Jid jid = (!) item.jid;
        item.display_name = get_lightweight_display_name(jid);
        item.affiliation = get_affiliation(jid);
        item.affiliation_known = has_affiliation(jid);
        item.role = get_role(jid);
        item.role_known = has_role(jid);
        if (item.is_offline_member) {
            item.hats_text = "";
            item.hats_markup = "";
            item.hats = new ArrayList<Xmpp.Xep.Muc.Hat>();
        } else {
            update_item_hats(item);
        }
        item.details_loaded = false;
        apply_presence_state(item, jid);
        item.notify_changed();
    }

    private string get_lightweight_display_name(Jid jid) {
        string display_name = jid.resourcepart != null && jid.resourcepart != ""
            ? (!) jid.resourcepart
            : jid.to_string();
        return display_name.make_valid();
    }

    private void apply_presence_state(OccupantListItem item, Jid jid) {
        if (item.is_offline_member) {
            item.status_icon = "user-offline-symbolic";
            item.status_text = _("Offline");
            item.status_css_class = "dim-label";
            return;
        }

        PresenceManager presence_manager = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
        bool has_presence = presence_manager.has_presence(jid, conversation.account);
        string? show = has_presence ? presence_manager.get_last_show(jid, conversation.account) : null;
        if (!has_presence) {
            item.status_icon = "user-offline-symbolic";
            item.status_text = _("Offline");
            item.status_css_class = "dim-label";
        } else if (show == "away") {
            item.status_icon = "user-away-symbolic";
            item.status_text = _("Away");
            item.status_css_class = "warning";
        } else if (show == "dnd") {
            item.status_icon = "user-busy-symbolic";
            item.status_text = _("Busy");
            item.status_css_class = "error";
        } else if (show == "xa") {
            item.status_icon = "user-idle-symbolic";
            item.status_text = _("Not Available");
            item.status_css_class = "error";
        } else {
            item.status_icon = "user-available-symbolic";
            item.status_text = _("Online");
            item.status_css_class = (show == null || show == "online" || show == "chat") ? "success" : "dim-label";
        }
    }

    private bool should_defer_expensive_details() {
        return is_large_room_context();
    }

    private void update_item_hats(OccupantListItem item) {
        if (item.jid == null) return;

        Gee.List<Xmpp.Xep.Muc.Hat> hats = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_hats((!) item.jid, conversation.account);
        var copied_hats = new ArrayList<Xmpp.Xep.Muc.Hat>();
        foreach (Xmpp.Xep.Muc.Hat hat in hats) {
            copied_hats.add(new Xmpp.Xep.Muc.Hat() {
                uri = hat.uri.make_valid(), title = hat.title.make_valid(),
                hue = hat.hue
            });
        }
        item.hats = copied_hats;
        if (hats.size == 0) {
            item.hats_text = "";
            item.hats_markup = "";
            return;
        }

        string[] titles = new string[hats.size];
        string[] markup_titles = new string[hats.size];
        int index = 0;
        foreach (Xmpp.Xep.Muc.Hat hat in hats) {
            titles[index] = hat.title.make_valid();
            markup_titles[index] = get_hat_markup(hat);
            index++;
        }
        item.hats_text = string.joinv(", ", titles);
        item.hats_markup = string.joinv(", ", markup_titles);
    }

    private void apply_snapshot_hats(OccupantListItem item,
            MucOccupantSnapshot snapshot) {
        var copied_hats = new ArrayList<Xmpp.Xep.Muc.Hat>();
        for (uint index = 0; index < snapshot.hat_count; index++) {
            copied_hats.add(new Xmpp.Xep.Muc.Hat() {
                uri = snapshot.hat_uri_at(index).make_valid(),
                title = snapshot.hat_title_at(index).make_valid(),
                hue = snapshot.hat_hue_at(index)
            });
        }
        item.hats = copied_hats;
        if (snapshot.hat_count == 0) {
            item.hats_text = "";
            item.hats_markup = "";
            return;
        }

        string[] titles = new string[snapshot.hat_count];
        string[] markup_titles = new string[snapshot.hat_count];
        for (uint i = 0; i < snapshot.hat_count; i++) {
            string title = snapshot.hat_title_at(i).make_valid();
            titles[i] = title;
            markup_titles[i] = get_hat_markup_values(title,
                snapshot.hat_hue_at(i));
        }
        item.hats_text = string.joinv(", ", titles);
        item.hats_markup = string.joinv(", ", markup_titles);
    }

    private Xmpp.Xep.Muc.Affiliation get_affiliation(Jid jid) {
        return stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_affiliation(conversation.counterpart, jid, conversation.account) ?? Xmpp.Xep.Muc.Affiliation.NONE;
    }

    private bool has_affiliation(Jid jid) {
        return stream_interactor.get_module<MucManager>(MucManager.IDENTITY).has_affiliation(conversation.counterpart, jid, conversation.account);
    }

    private bool refresh_private_member_snapshot_index() {
        Gee.List<Jid>? snapshot = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_private_muc_member_affiliation_snapshot(conversation.account, conversation.counterpart);
        var next_snapshot_bare_jids = new HashSet<Jid>(Jid.hash_bare_func, Jid.equals_bare_func);
        bool next_complete = snapshot != null;

        if (snapshot != null) {
            foreach (Jid jid in (!) snapshot) {
                Jid bare_jid = jid.bare_jid;
                if (!bare_jid.equals_bare(conversation.counterpart)) next_snapshot_bare_jids.add(bare_jid);
            }
        }

        bool changed = private_member_snapshot_complete != next_complete || !jid_sets_equal(private_member_snapshot_bare_jids, next_snapshot_bare_jids);
        private_member_snapshot_complete = next_complete;
        private_member_snapshot_bare_jids = next_snapshot_bare_jids;
        return changed;
    }

    private bool jid_sets_equal(HashSet<Jid> a, HashSet<Jid> b) {
        if (a.size != b.size) return false;

        foreach (Jid jid in a) {
            if (!b.contains(jid)) return false;
        }
        return true;
    }

    private HashSet<Jid> build_live_real_jid_index() {
        var live_real_jids = new HashSet<Jid>(Jid.hash_bare_func, Jid.equals_bare_func);
        foreach (Jid jid in all_occupants) {
            if (!is_room_occupant_jid(jid)) continue;

            Jid? real_jid = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_real_jid(jid, conversation.account);
            if (real_jid != null) live_real_jids.add(((!) real_jid).bare_jid);
        }
        return live_real_jids;
    }

    private bool materialize_complete_member_snapshot() {
        return reconcile_private_member_snapshot();
    }

    private bool reconcile_private_member_snapshot() {
        bool changed = false;
        var live_real_jids = build_live_real_jid_index();
        var remove_jids = new ArrayList<Jid>(Jid.equals_func);

        foreach (Jid jid in all_occupants) {
            if (!jid.is_bare() || jid.equals_bare(conversation.counterpart)) continue;
            if (!private_member_snapshot_complete || !private_member_snapshot_bare_jids.contains(jid) || live_real_jids.contains(jid)) {
                remove_jids.add(jid);
            }
        }

        changed = remove_occupants_from_state(remove_jids) || changed;

        if (!private_member_snapshot_complete) return changed;

        foreach (Jid bare_jid in private_member_snapshot_bare_jids) {
            if (live_real_jids.contains(bare_jid) || all_occupant_index.contains(bare_jid)) continue;

            changed = add_occupant_to_state(bare_jid, true) || changed;
        }
        return changed;
    }

    private Xmpp.Xep.Muc.Role get_role(Jid jid) {
        return stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_role(jid, conversation.account) ?? Xmpp.Xep.Muc.Role.NONE;
    }

    private bool has_role(Jid jid) {
        return stream_interactor.get_module<MucManager>(MucManager.IDENTITY)
            .has_role(jid, conversation.account);
    }

    private bool sync_item_affiliation_from_state(OccupantListItem item, bool notify = true) {
            if (item.jid == null) return false;

        Xmpp.Xep.Muc.Affiliation affiliation = get_affiliation((!) item.jid);
        bool affiliation_known = has_affiliation((!) item.jid);
        if (item.affiliation == affiliation && item.affiliation_known == affiliation_known) return false;

        item.affiliation = affiliation;
        item.affiliation_known = affiliation_known;
        if (notify) item.notify_changed();
        return true;
    }

    private bool sync_item_role_from_state(OccupantListItem item, bool notify = true) {
        if (item.jid == null) return false;

        Xmpp.Xep.Muc.Role role = get_role((!) item.jid);
        bool role_known = has_role((!) item.jid);
        if (item.role == role && item.role_known == role_known) return false;

        item.role = role;
        item.role_known = role_known;
        if (notify) item.notify_changed();
        return true;
    }

    private bool sync_item_presence_from_state(OccupantListItem item, bool notify = true) {
        if (item.jid == null) return false;

        string old_status_icon = item.status_icon;
        string old_status_text = item.status_text;
        string old_status_css_class = item.status_css_class;

        apply_presence_state(item, (!) item.jid);
        bool changed = old_status_icon != item.status_icon ||
            old_status_text != item.status_text ||
            old_status_css_class != item.status_css_class;
        if (changed && notify) item.notify_changed();
        return changed;
    }

    private bool sync_item_state_from_live_sources(OccupantListItem item, bool notify = true) {
        bool changed = sync_item_affiliation_from_state(item, false);
        changed = sync_item_role_from_state(item, false) || changed;
        changed = sync_item_presence_from_state(item, false) || changed;
        if (changed && notify) item.notify_changed();
        return changed;
    }

    private bool sync_cached_live_items_from_state() {
        bool presentation_changed = false;

        foreach (Jid jid in all_occupants) {
            if (!is_presentable_memberlist_jid(jid) || !cache.occupants.has_key(jid)) continue;

            OccupantListItem item = cache.occupants[jid];
            string old_group_key = get_member_list_section_key(item);
            bool item_changed = sync_item_state_from_live_sources(item, false);
            string new_group_key = get_member_list_section_key(item);
            if (old_group_key != new_group_key) presentation_changed = true;
            if (item_changed) item.notify_changed();
        }

        return presentation_changed;
    }

    private void prune_cache_to_current_occupants() {
        var current_occupants = new HashSet<Jid>(Jid.hash_func, Jid.equals_func);
        foreach (Jid jid in all_occupants) {
            current_occupants.add(jid);
        }

        var remove = new ArrayList<Jid>(Jid.equals_func);
        foreach (Jid jid in cache.occupants.keys) {
            if (!current_occupants.contains(jid)) remove.add(jid);
        }
        foreach (Jid jid in remove) {
            cache.occupants.unset(jid);
        }
        if (remove.size > 0) {
            cache.details_loaded = false;
            invalidate_cached_presentation();
        }
    }

    private void rebuild_presentation(bool show_progress = false,
            bool progressive_reveal = false) {
        cancel_presentation_rebuild();
        if (!cache.loaded) {
            presentation_store.remove_all();
            presentation_complete = false;
            return;
        }
        if (is_large_room_context()) {
            begin_incremental_presentation_rebuild(show_progress,
                progressive_reveal);
            return;
        }

        var visible = build_visible_items();

        foreach (OccupantListItem item in visible) {
            string group_key = get_member_list_section_key(item);
            presentation_counts[group_key] = (presentation_counts.has_key(group_key) ? presentation_counts[group_key] : 0) + 1;
        }
        presentation_queue = visible;
        staged_presentation_items = new ArrayList<OccupantListItem>();
        presentation_index = 0;
        presentation_has_current_section = false;
        presentation_current_group_key = "";
        presentation_top = true;
        presentation_show_progress = show_progress;
        presentation_rebuild_progressive_reveal = progressive_reveal;
        if (show_progress) {
            scrolled_window.visible = false;
            loading_box.visible = true;
            loading_spinner.start();
            update_loading_progress(0, visible.size, false);
        }
        uint generation = ++presentation_rebuild_generation;
        presentation_rebuild_source = Idle.add_full(interactive_source_priority(), () => process_presentation_batch(generation));
    }

    private void begin_incremental_presentation_rebuild(bool show_progress,
            bool progressive_reveal) {
        presentation_owner_items = new_incremental_presentation_group();
        presentation_admin_items = new_incremental_presentation_group();
        presentation_moderator_items = new_incremental_presentation_group();
        presentation_member_items = new_incremental_presentation_group();
        presentation_participant_items = new_incremental_presentation_group();
        presentation_visitor_items = new_incremental_presentation_group();
        presentation_outcast_items = new_incremental_presentation_group();
        presentation_summary_total_count = 0;
        presentation_collect_index = 0;
        presentation_show_progress = show_progress;
        presentation_rebuild_progressive_reveal = progressive_reveal;
        if (show_progress) {
            scrolled_window.visible = false;
            loading_box.visible = true;
            loading_spinner.start();
            update_loading_progress(0, all_occupants.size, true);
        }
        uint generation = ++presentation_rebuild_generation;
        presentation_rebuild_source = Idle.add_full(interactive_source_priority(), () => process_incremental_presentation_collect_batch(generation));
    }

    private bool process_incremental_presentation_collect_batch(uint generation) {
        if (disposed || generation != presentation_rebuild_generation) {
            presentation_rebuild_source = 0;
            clear_presentation_rebuild_state();
            return Source.REMOVE;
        }

        int64 deadline_us = GLib.get_monotonic_time() + WORK_BUDGET_US;
        while (presentation_collect_index < all_occupants.size) {
            int end = int.min(presentation_collect_index + PRESENTATION_BATCH_SIZE, all_occupants.size);
            while (presentation_collect_index < end) {
                Jid jid = all_occupants[presentation_collect_index];
                presentation_collect_index++;
                if (!is_presentable_memberlist_jid(jid)) continue;
                if (!cache.occupants.has_key(jid)) continue;

                OccupantListItem item = cache.occupants[jid];
                sync_item_state_from_live_sources(item, false);
                if (item.matches_filter(filter_values)) {
                    add_item_to_incremental_presentation(item);
                }
                if (GLib.get_monotonic_time() >= deadline_us) break;
            }
            if (presentation_collect_index < end || GLib.get_monotonic_time() >= deadline_us) break;
        }
        if (presentation_show_progress) {
            update_loading_progress(presentation_collect_index, all_occupants.size, false);
        }

        if (presentation_collect_index >= all_occupants.size) {
            finish_incremental_presentation_rebuild();
            return Source.REMOVE;
        }
        return Source.CONTINUE;
    }

    private void add_item_to_incremental_presentation(OccupantListItem item) {
        presentation_summary_total_count++;
        switch (get_member_list_section(item)) {
            case MucMemberListSection.OWNER:
                ((!) presentation_owner_items).add(item);
                break;
            case MucMemberListSection.ADMIN:
                ((!) presentation_admin_items).add(item);
                break;
            case MucMemberListSection.MODERATOR:
                ((!) presentation_moderator_items).add(item);
                break;
            case MucMemberListSection.MEMBER:
                ((!) presentation_member_items).add(item);
                break;
            case MucMemberListSection.VISITOR:
                ((!) presentation_visitor_items).add(item);
                break;
            case MucMemberListSection.BANNED:
                ((!) presentation_outcast_items).add(item);
                break;
            case MucMemberListSection.PARTICIPANT:
            default:
                ((!) presentation_participant_items).add(item);
                break;
        }
    }

    private ArrayList<OccupantListItem> new_incremental_presentation_group() {
        return new ArrayList<OccupantListItem>();
    }

    private void finish_incremental_presentation_rebuild() {
        var staged_items = new ArrayList<OccupantListItem>();
        bool top = true;
        append_incremental_presentation_group(staged_items, presentation_owner_items, ref top);
        append_incremental_presentation_group(staged_items, presentation_admin_items, ref top);
        append_incremental_presentation_group(staged_items, presentation_moderator_items, ref top);
        append_incremental_presentation_group(staged_items, presentation_member_items, ref top);
        append_incremental_presentation_group(staged_items, presentation_participant_items, ref top);
        append_incremental_presentation_group(staged_items, presentation_visitor_items, ref top);
        append_incremental_presentation_group(staged_items, presentation_outcast_items, ref top);

        bool show_progress = presentation_show_progress;
        bool progressive_reveal = presentation_rebuild_progressive_reveal;
        presentation_rebuild_source = 0;
        apply_incremental_summary_counts();
        clear_presentation_rebuild_state();
        if (!disposed) {
            begin_presentation_commit(staged_items, show_progress,
                progressive_reveal);
        } else {
            if (cache.loaded) scrolled_window.visible = true;
            loading_spinner.stop();
            loading_box.visible = false;
        }
    }

    private void append_incremental_presentation_group(ArrayList<OccupantListItem> staged_items, ArrayList<OccupantListItem>? group_items, ref bool top) {
        if (group_items == null || ((!) group_items).size == 0) return;

        OccupantListItem first_item = ((!) group_items)[0];
        staged_items.add(new OccupantListItem.header(
            get_member_list_section_label(first_item),
            ((!) group_items).size, top));
        top = false;
        foreach (OccupantListItem item in (!) group_items) {
            staged_items.add(item);
        }
    }

    private void apply_incremental_summary_counts() {
        summary_counts.clear();
        copy_incremental_summary_count(MucMemberListSection.OWNER,
            presentation_owner_items);
        copy_incremental_summary_count(MucMemberListSection.ADMIN,
            presentation_admin_items);
        copy_incremental_summary_count(MucMemberListSection.MODERATOR,
            presentation_moderator_items);
        copy_incremental_summary_count(MucMemberListSection.MEMBER,
            presentation_member_items);
        copy_incremental_summary_count(MucMemberListSection.PARTICIPANT,
            presentation_participant_items);
        copy_incremental_summary_count(MucMemberListSection.VISITOR,
            presentation_visitor_items);
        copy_incremental_summary_count(MucMemberListSection.BANNED,
            presentation_outcast_items);
        update_summary_with_total(presentation_summary_total_count);
    }

    private void copy_incremental_summary_count(MucMemberListSection section,
            ArrayList<OccupantListItem>? group_items) {
        if (group_items != null && ((!) group_items).size > 0) {
            summary_counts[section] = ((!) group_items).size;
        }
    }

    private bool process_presentation_batch(uint generation) {
        if (disposed || generation != presentation_rebuild_generation || presentation_queue == null) {
            presentation_rebuild_source = 0;
            clear_presentation_rebuild_state();
            return Source.REMOVE;
        }

        int64 deadline_us = GLib.get_monotonic_time() + WORK_BUDGET_US;
        while (presentation_index < ((!) presentation_queue).size) {
            int end = int.min(presentation_index + PRESENTATION_BATCH_SIZE, ((!) presentation_queue).size);
            while (presentation_index < end) {
                OccupantListItem item = ((!) presentation_queue)[presentation_index];
                string group_key = get_member_list_section_key(item);
                if (!presentation_has_current_section || presentation_current_group_key != group_key) {
                    presentation_current_group_key = group_key;
                    presentation_has_current_section = true;
                    int count = presentation_counts.has_key(group_key) ? presentation_counts[group_key] : 0;
                    ((!) staged_presentation_items).add(new OccupantListItem.header(get_member_list_section_label(item), count, presentation_top));
                    presentation_top = false;
                }
                ((!) staged_presentation_items).add(item);
                presentation_index++;
                if (GLib.get_monotonic_time() >= deadline_us) break;
            }
            if (presentation_index < end || GLib.get_monotonic_time() >= deadline_us) break;
        }
        if (presentation_show_progress) {
            update_loading_progress(presentation_index, ((!) presentation_queue).size, false);
        }

        if (presentation_index >= ((!) presentation_queue).size) {
            finish_presentation_rebuild();
            return Source.REMOVE;
        }
        return Source.CONTINUE;
    }

    private void finish_presentation_rebuild() {
        ArrayList<OccupantListItem>? staged_items = staged_presentation_items;
        bool show_progress = presentation_show_progress;
        bool progressive_reveal = presentation_rebuild_progressive_reveal;
        presentation_rebuild_source = 0;
        clear_presentation_rebuild_state();
        if (!disposed && staged_items != null) {
            begin_presentation_commit((!) staged_items, show_progress,
                progressive_reveal);
        } else {
            if (cache.loaded) scrolled_window.visible = true;
            loading_spinner.stop();
            loading_box.visible = false;
        }
    }

    private void clear_presentation_rebuild_state() {
        presentation_queue = null;
        staged_presentation_items = null;
        presentation_counts.clear();
        presentation_index = 0;
        presentation_collect_index = 0;
        presentation_owner_items = null;
        presentation_admin_items = null;
        presentation_moderator_items = null;
        presentation_member_items = null;
        presentation_participant_items = null;
        presentation_visitor_items = null;
        presentation_outcast_items = null;
        presentation_summary_total_count = 0;
        presentation_has_current_section = false;
        presentation_show_progress = false;
        presentation_rebuild_progressive_reveal = false;
    }

    private void cancel_presentation_rebuild() {
        presentation_rebuild_generation++;
        if (presentation_rebuild_source != 0) {
            Source.remove(presentation_rebuild_source);
            presentation_rebuild_source = 0;
        }
        cancel_presentation_commit();
        clear_presentation_rebuild_state();
        loading_spinner.stop();
        loading_box.visible = false;
    }

    private bool is_valid_cached_reveal_commit() {
        return presentation_commit_direct_visible &&
            (presentation_commit_map_tick != 0 ||
                presentation_commit_source != 0) &&
            presentation_commit_cache_generation ==
                presentation_cache_generation &&
            filter_values == null && cache.presentation_items != null;
    }

    private void begin_presentation_commit(Gee.List<OccupantListItem> items, bool show_progress = false,
            bool progressive_cached_reveal = false) {
        if (presentation_matches_current(items)) {
            if (filter_values == null) {
                cache.presentation_items = new ArrayList<OccupantListItem>();
                ((!) cache.presentation_items).add_all(items);
            }
            presentation_complete = true;
            if (list_view.model == null) attach_visible_model();
            if (cache.loaded) scrolled_window.visible = true;
            show_list_button.visible = false;
            loading_spinner.stop();
            loading_box.visible = false;
            return;
        }

        cancel_presentation_commit();
        if (Dino.Ui.UiTiming.enabled()) {
            presentation_timing_active = true;
            presentation_timing_started_us = Dino.Ui.UiTiming.now_us();
            presentation_factory_setup_count = 0;
            presentation_factory_bind_count = 0;
            presentation_factory_setup_us = 0;
            presentation_factory_bind_us = 0;
        }
        presentation_commit_queue = new ArrayList<OccupantListItem>();
        ((!) presentation_commit_queue).add_all(items);
        presentation_commit_store = new GLib.ListStore(typeof(OccupantListItem));
        // A rebuilt large-room presentation must use the same mapped,
        // incremental path as a reusable cached presentation.  Attaching a
        // complete hidden model at once makes GTK realize every row before the
        // viewport settles and can starve the Windows main loop for seconds.
        presentation_commit_direct_visible = show_progress &&
            presentation_store.get_n_items() == 0 &&
            (progressive_cached_reveal || is_large_room_context());
        presentation_commit_show_progress = show_progress;
        presentation_commit_cache_generation = presentation_cache_generation;
        presentation_commit_index = 0;
        presentation_commit_member_index = 0;
        presentation_commit_member_total = show_progress ? count_occupant_items(items) : 0;
        presentation_complete = false;

        if (show_progress) {
            if (presentation_commit_direct_visible) {
                // Map the stable, empty viewport first.  The cached rows are
                // appended only after GTK has had a frame to present the
                // popover, so Windows never realizes the full hidden model in
                // one blocking attach.
                attach_visible_model();
                scrolled_window.visible = true;
                show_list_button.visible = false;
                loading_spinner.stop();
                loading_box.visible = false;
            } else {
                detach_visible_model();
                scrolled_window.visible = false;
                loading_box.visible = true;
                loading_spinner.start();
                update_loading_progress(0, presentation_commit_member_total, false);
            }
        }

        if (items.size == 0) {
            finish_presentation_commit();
            return;
        }
        uint generation = ++presentation_commit_generation;
        if (presentation_commit_direct_visible) {
            presentation_commit_map_tick = scrolled_window.add_tick_callback((widget, frame_clock) => {
                presentation_commit_map_tick = 0;
                if (disposed || generation != presentation_commit_generation) {
                    clear_presentation_commit_state();
                    return Source.REMOVE;
                }
                presentation_commit_source = Idle.add_full(interactive_source_priority(),
                    () => process_presentation_commit_batch(generation));
                return Source.REMOVE;
            });
        } else {
            presentation_commit_source = Idle.add_full(interactive_source_priority(),
                () => process_presentation_commit_batch(generation));
        }
    }

    private bool presentation_matches_current(Gee.List<OccupantListItem> items) {
        if (!presentation_complete || presentation_store.get_n_items() != items.size) return false;

        for (uint i = 0; i < presentation_store.get_n_items(); i++) {
            OccupantListItem? current = presentation_store.get_item(i) as OccupantListItem;
            OccupantListItem next = items[(int) i];
            if (current == null || ((!) current).is_header != next.is_header) return false;

            if (next.is_header) {
                if (((!) current).header_title != next.header_title ||
                        ((!) current).header_count != next.header_count ||
                        ((!) current).header_top != next.header_top) {
                    return false;
                }
            } else if (current != next) {
                return false;
            }
        }
        return true;
    }

    private bool process_presentation_commit_batch(uint generation) {
        if (disposed || generation != presentation_commit_generation || presentation_commit_queue == null) {
            presentation_commit_source = 0;
            presentation_commit_map_tick = 0;
            clear_presentation_commit_state();
            return Source.REMOVE;
        }

        bool timing_direct_commit = Dino.Ui.UiTiming.enabled() &&
            presentation_commit_direct_visible;
        int64 slice_started_us = timing_direct_commit ? Dino.Ui.UiTiming.now_us() : 0;
        int slice_start_index = presentation_commit_index;
        GLib.ListStore target_store = presentation_commit_direct_visible
            ? presentation_store
            : (!) presentation_commit_store;
        int64 deadline_us = GLib.get_monotonic_time() + WORK_BUDGET_US;
        while (presentation_commit_index < ((!) presentation_commit_queue).size) {
            int end = int.min(presentation_commit_index + PRESENTATION_COMMIT_BATCH_SIZE, ((!) presentation_commit_queue).size);
            int additions_count = end - presentation_commit_index;
            void*[] additions = new void*[additions_count];
            for (int i = 0; i < additions_count; i++) {
                OccupantListItem item = ((!) presentation_commit_queue)[presentation_commit_index + i];
                additions[i] = (void*) item;
                if (!item.is_header) presentation_commit_member_index++;
            }
            list_store_splice_raw(target_store, target_store.get_n_items(), 0, additions);
            presentation_commit_index = end;
            if (GLib.get_monotonic_time() >= deadline_us) break;
        }
        if (presentation_commit_show_progress) {
            update_loading_progress(presentation_commit_member_index, presentation_commit_member_total, false);
        }
        if (timing_direct_commit) {
            Dino.Ui.UiTiming.log_ms(
                "OccupantList.presentation_commit_slice: items=%d index=%d/%d store=%u".printf(
                    presentation_commit_index - slice_start_index,
                    presentation_commit_index,
                    ((!) presentation_commit_queue).size,
                    presentation_store.get_n_items()),
                slice_started_us);
        }

        if (presentation_commit_index >= ((!) presentation_commit_queue).size) {
            finish_presentation_commit();
            return Source.REMOVE;
        }
        return Source.CONTINUE;
    }

    [CCode (cname = "g_list_store_splice", cheader_filename = "gio/gio.h")]
    private extern static void list_store_splice_raw(GLib.ListStore store, uint position, uint n_removals, [CCode (array_length_pos = 4.1, array_length_type = "guint")] void*[]? additions);

    private void finish_presentation_commit() {
        presentation_commit_source = 0;
        presentation_commit_map_tick = 0;
        int64 finish_started_us = presentation_timing_active ? Dino.Ui.UiTiming.now_us() : 0;
        Gee.List<OccupantListItem>? committed_items = presentation_commit_queue;
        bool show_progress = presentation_commit_show_progress;
        bool direct_visible = presentation_commit_direct_visible;
        bool commit_stale = presentation_commit_cache_generation != presentation_cache_generation;
        if (!disposed && !commit_stale && filter_values == null && committed_items != null) {
            cache.presentation_items = new ArrayList<OccupantListItem>();
            ((!) cache.presentation_items).add_all((!) committed_items);
        }
        if (!disposed && !commit_stale && committed_items != null &&
                !direct_visible) {
            replace_presentation_store((!) committed_items);
        }
        if (!disposed && commit_stale && direct_visible) {
            detach_visible_model();
            presentation_store.remove_all();
        }
        clear_presentation_commit_state();
        if (!disposed && commit_stale && cache.loaded) {
            presentation_complete = false;
            rebuild_presentation(show_progress, direct_visible);
            return;
        }
        presentation_complete = true;
        int64 attach_started_us = presentation_timing_active ? Dino.Ui.UiTiming.now_us() : 0;
        attach_visible_model();
        if (presentation_timing_active) {
            Dino.Ui.UiTiming.log_ms("OccupantList.finish_presentation_commit: attach_model store=%u rows=%d direct_visible=%s".printf(
                presentation_store.get_n_items(), factory_rows.size,
                direct_visible.to_string()), attach_started_us);
        }
        if (cache.loaded) {
            scrolled_window.visible = true;
            schedule_detail_refresh();
        }
        if (show_progress) {
            loading_spinner.stop();
            loading_box.visible = false;
        }
        if (presentation_timing_active) {
            Dino.Ui.UiTiming.log_ms("OccupantList.finish_presentation_commit: synchronous store=%u rows=%d".printf(
                presentation_store.get_n_items(), factory_rows.size), finish_started_us);
            schedule_presentation_ready_timing();
        }
    }

    private void cancel_presentation_commit() {
        presentation_commit_generation++;
        bool discard_direct_partial = presentation_commit_direct_visible &&
            !presentation_complete;
        if (presentation_commit_map_tick != 0) {
            scrolled_window.remove_tick_callback(presentation_commit_map_tick);
            presentation_commit_map_tick = 0;
        }
        if (presentation_commit_source != 0) {
            Source.remove(presentation_commit_source);
            presentation_commit_source = 0;
        }
        cancel_presentation_ready_timing();
        clear_presentation_commit_state();
        if (discard_direct_partial && !disposed) {
            detach_visible_model();
            presentation_store.remove_all();
            presentation_complete = false;
        }
    }

    private void schedule_presentation_ready_timing() {
        if (!presentation_timing_active || presentation_ready_timing_source != 0) return;

        presentation_ready_timing_source = Idle.add_full(GLib.Priority.LOW, () => {
            presentation_ready_timing_source = 0;
            if (presentation_timing_active) {
                double setup_ms = (double) presentation_factory_setup_us / 1000.0;
                double bind_ms = (double) presentation_factory_bind_us / 1000.0;
                Dino.Ui.UiTiming.log_ms(
                    "OccupantList.presentation_ready: store=%u rows=%d setup=%d/%.2fms bind=%d/%.2fms".printf(
                        presentation_store.get_n_items(), factory_rows.size,
                        presentation_factory_setup_count, setup_ms,
                        presentation_factory_bind_count, bind_ms),
                    presentation_timing_started_us);
            }
            presentation_timing_active = false;
            return Source.REMOVE;
        });
    }

    private void cancel_presentation_ready_timing() {
        if (presentation_ready_timing_source != 0) {
            Source.remove(presentation_ready_timing_source);
            presentation_ready_timing_source = 0;
        }
        presentation_timing_active = false;
    }

    private void clear_presentation_commit_state() {
        presentation_commit_queue = null;
        presentation_commit_store = null;
        presentation_commit_show_progress = false;
        presentation_commit_cache_generation = 0;
        presentation_commit_index = 0;
        presentation_commit_member_index = 0;
        presentation_commit_member_total = 0;
        presentation_commit_direct_visible = false;
    }

    private void replace_presentation_store(Gee.List<OccupantListItem> items) {
        void*[]? additions = null;
        if (items.size > 0) {
            additions = new void*[items.size];
            for (int i = 0; i < items.size; i++) {
                additions[i] = (void*) items[i];
            }
        }
        list_store_splice_raw(presentation_store, 0, presentation_store.get_n_items(), additions);
    }

    private int count_occupant_items(Gee.List<OccupantListItem> items) {
        int count = 0;
        foreach (OccupantListItem item in items) {
            if (!item.is_header) count++;
        }
        return count;
    }

    private bool can_reuse_cached_presentation() {
        if (filter_values != null || cache.presentation_items == null) return false;
        if (is_large_room_context()) return true;
        if (sync_cached_live_items_from_state()) return false;
        return cached_presentation_matches_current_state();
    }

    private bool cached_presentation_matches_current_state() {
        if (cache.presentation_items == null) return false;

        ArrayList<OccupantListItem> visible = build_visible_items();
        int visible_index = 0;
        int cached_index = 0;

        while (visible_index < visible.size) {
            OccupantListItem first_item = visible[visible_index];
            string group_key = get_member_list_section_key(first_item);
            string group_label = get_member_list_section_label(first_item);
            int group_count = 0;
            int group_start = visible_index;

            while (visible_index < visible.size && get_member_list_section_key(visible[visible_index]) == group_key) {
                group_count++;
                visible_index++;
            }

            if (cached_index >= ((!) cache.presentation_items).size) return false;
            OccupantListItem header = ((!) cache.presentation_items)[cached_index++];
            if (!header.is_header || header.header_title != group_label || header.header_count != group_count) return false;

            for (int i = group_start; i < visible_index; i++) {
                if (cached_index >= ((!) cache.presentation_items).size) return false;
                OccupantListItem cached_item = ((!) cache.presentation_items)[cached_index++];
                if (cached_item.is_header || cached_item.jid == null || visible[i].jid == null) return false;
                if (!((!) cached_item.jid).equals((!) visible[i].jid)) return false;
                if (get_member_list_section_key(cached_item) != get_member_list_section_key(visible[i])) return false;
            }
        }

        return cached_index == ((!) cache.presentation_items).size;
    }

    private ArrayList<OccupantListItem> build_visible_items() {
        var visible = new ArrayList<OccupantListItem>();
        foreach (Jid jid in all_occupants) {
            if (!is_presentable_memberlist_jid(jid)) continue;
            if (!cache.occupants.has_key(jid)) continue;
            OccupantListItem item = cache.occupants[jid];
            sync_item_state_from_live_sources(item, false);
            if (item.matches_filter(filter_values)) visible.add(item);
        }
        visible.sort((a, b) => compare_items(a, b));
        return visible;
    }

    private bool is_room_occupant_jid(Jid jid) {
        return jid.is_full() && conversation.counterpart.equals_bare(jid);
    }

    private bool is_presentable_memberlist_jid(Jid jid) {
        return is_room_occupant_jid(jid) || is_private_member_snapshot_jid(jid);
    }

    private bool is_private_member_snapshot_jid(Jid jid) {
        return jid.is_bare() && private_member_snapshot_complete && private_member_snapshot_bare_jids.contains(jid);
    }

    private void detach_visible_model() {
        list_view.model = null;
    }

    private void attach_visible_model() {
        if (list_view.model == null) list_view.model = selection_model;
    }

    private void invalidate_cached_presentation() {
        if (waiting_for_initial_snapshot) {
            pending_rebuild = true;
            return;
        }
        presentation_cache_generation++;
        cache.presentation_items = null;
    }

    private bool add_occupant_to_state(Jid jid, bool refresh = true) {
        bool changed = remove_matching_offline_member_snapshot(jid);
        bool added = all_occupant_index.add(jid);
        if (added) {
            cancel_detail_refresh();
            all_occupants.add(jid);
            if (cache.stable_occupants != null &&
                    !((!) cache.stable_occupants).contains(jid)) {
                ((!) cache.stable_occupants).add(jid);
            }
            refresh_room_size_state();
            cache.details_loaded = false;
            invalidate_cached_presentation();
            changed = true;
        }
        if (initializing && load_queue != null && load_queue_index != null && ((!) load_queue_index).add(jid)) {
            ((!) load_queue).add(jid);
            update_loading_progress(load_index, ((!) load_queue).size, false);
        }
        if (cache.loaded || initializing) ensure_item(jid, refresh, !should_defer_expensive_details());
        if (added && cache.loaded && !initializing) schedule_detail_refresh();
        return changed;
    }

    private bool remove_matching_offline_member_snapshot(Jid occupant_jid) {
        if (!is_room_occupant_jid(occupant_jid)) return false;

        Jid? real_jid = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_real_jid(occupant_jid, conversation.account);
        if (real_jid == null) return false;

        Jid bare_real_jid = ((!) real_jid).bare_jid;
        if (!all_occupant_index.contains(bare_real_jid)) return false;

        return remove_occupant_from_state(bare_real_jid);
    }

    private bool remove_occupant_from_state(Jid jid) {
        cancel_detail_refresh();
        bool removed_from_index = all_occupant_index.remove(jid);
        bool removed_from_list = all_occupants.remove(jid);
        if (cache.stable_occupants != null) {
            ((!) cache.stable_occupants).remove(jid);
        }
        bool had_cache_item = cache.occupants.has_key(jid);
        cache.occupants.unset(jid);
        if (!removed_from_index && !removed_from_list && !had_cache_item) return false;

        cache.details_loaded = false;
        invalidate_cached_presentation();
        if (load_queue != null) {
            int queue_index = ((!) load_queue).index_of(jid);
            if (queue_index >= 0) {
                ((!) load_queue).remove_at(queue_index);
                if (queue_index < load_index && load_index > 0) load_index--;
                if (load_index > ((!) load_queue).size) load_index = ((!) load_queue).size;
                if (load_queue_index != null) ((!) load_queue_index).remove(jid);
                update_loading_progress(load_index, ((!) load_queue).size, false);
            }
        }
        return true;
    }

    private bool remove_occupants_from_state(ArrayList<Jid> jids) {
        if (jids.size == 0) return false;

        var remove_index = new HashSet<Jid>(Jid.hash_func, Jid.equals_func);
        foreach (Jid jid in jids) {
            if (all_occupant_index.contains(jid) || cache.occupants.has_key(jid) || (load_queue_index != null && ((!) load_queue_index).contains(jid))) {
                remove_index.add(jid);
            }
        }
        if (remove_index.size == 0) return false;

        cancel_detail_refresh();
        var remaining_occupants = new ArrayList<Jid>(Jid.equals_func);
        foreach (Jid jid in all_occupants) {
            if (remove_index.contains(jid)) {
                all_occupant_index.remove(jid);
            } else {
                remaining_occupants.add(jid);
            }
        }
        all_occupants = remaining_occupants;

        foreach (Jid jid in remove_index) {
            all_occupant_index.remove(jid);
            if (cache.stable_occupants != null) {
                ((!) cache.stable_occupants).remove(jid);
            }
            cache.occupants.unset(jid);
        }

        if (load_queue != null) {
            int removed_before_index = 0;
            var remaining_queue = new ArrayList<Jid>(Jid.equals_func);
            for (int i = 0; i < ((!) load_queue).size; i++) {
                Jid jid = ((!) load_queue)[i];
                if (remove_index.contains(jid)) {
                    if (i < load_index) removed_before_index++;
                    if (load_queue_index != null) ((!) load_queue_index).remove(jid);
                } else {
                    remaining_queue.add(jid);
                }
            }
            load_queue = remaining_queue;
            load_index = int.max(0, load_index - removed_before_index);
            if (load_index > ((!) load_queue).size) load_index = ((!) load_queue).size;
            update_loading_progress(load_index, ((!) load_queue).size, false);
        }

        cache.details_loaded = false;
        invalidate_cached_presentation();
        return true;
    }

    private void on_received_offline_presence(Jid jid, Account account) {
        if (conversation.account.equals(account) && conversation.counterpart.equals_bare(jid) && jid.is_full()) {
            if (pending_room_snapshot != null || snapshot_apply_source != 0) {
                snapshot_live_removals.add(jid);
            }
            // A healthy live worker owns membership and emits one ordered
            // room batch. Applying this leave here as well would schedule a
            // second summary/rebuild for the same presence. The worker flushes
            // unavailable/control events immediately; on degradation its
            // room-level fallback rebuilds from PresenceManager.
            if (uses_live_occupant_batches(account, jid.bare_jid)) return;
            bool membership_changed = remove_occupant_from_state(jid);
            membership_changed = refresh_private_member_snapshot_index() || membership_changed;
            membership_changed = reconcile_private_member_snapshot() || membership_changed;
            if (membership_changed) note_initial_snapshot_membership_change();
            pending_presence_jids.remove(jid);
            if (membership_changed && all_occupants.size == 0) {
                cancel_loading();
                cancel_cache_refresh();
                cancel_detail_refresh();
                cancel_presentation_rebuild();
                enter_stable_empty_snapshot_surface();
                return;
            }
            if (background_work_suspended) {
                pending_summary_refresh = true;
                pending_rebuild = true;
                return;
            }
            refresh_summary_counts_for_current_context();
            schedule_rebuild();
        }
    }

    private void on_show_received(Jid jid, Account account) {
        if (conversation.account.equals(account) && conversation.counterpart.equals_bare(jid) && jid.is_full()) {
            if (pending_room_snapshot != null || snapshot_apply_source != 0) {
                snapshot_live_removals.remove(jid);
            }
            if (uses_live_occupant_batches(account, jid.bare_jid)) {
                // Presence still owns show/status details that are not part of
                // the occupant reducer. Membership and its rebuild arrive in
                // the short worker batch.
                queue_presence_update(jid, false);
                return;
            }
            bool membership_changed = add_occupant_to_state(jid, false);
            if (membership_changed) note_initial_snapshot_membership_change();
            queue_presence_update(jid, membership_changed);
        }
    }

    private void note_initial_snapshot_membership_change() {
        if (!waiting_for_initial_snapshot) return;
        initial_snapshot_last_membership_change_us = GLib.get_monotonic_time();
    }

    private void on_avatar_changed(Jid jid, Account account) {
        if (disposed || !conversation.account.equals(account)) return;
        if (jid.is_full()) {
            if (!conversation.counterpart.equals_bare(jid) || !cache.occupants.has_key(jid)) return;
        } else {
            // A private-room row can prefer the occupant's real bare JID. Keep
            // one list-level observer and let only realized rows match it.
            MucManager muc_manager = stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            if (!muc_manager.is_private_room(conversation.account, conversation.counterpart.bare_jid)) return;
        }

        if (background_work_suspended) {
            // Do not retain one pending entry per occupant. Current hashes stay
            // in AvatarManager; one realized-row refresh on reopen is enough.
            pending_avatar_refresh = true;
            return;
        }
        refresh_realized_avatar(jid);
    }

    private void flush_pending_avatar_updates() {
        if (!pending_avatar_refresh) return;

        pending_avatar_refresh = false;
        foreach (ListRow row in factory_rows.values) row.refresh_avatar();
    }

    private void refresh_realized_avatar(Jid jid) {
        foreach (ListRow row in factory_rows.values) {
            row.refresh_cached_avatar(jid);
        }
    }

    private void queue_presence_update(Jid jid, bool membership_changed) {
        pending_presence_jids.add(jid);
        if (membership_changed) pending_presence_rebuild = true;
        if (background_work_suspended || waiting_for_initial_snapshot) return;

        if (presence_update_timeout == 0) {
            uint delay = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).is_initial_presence_sync(conversation.account, conversation.counterpart) ? 500 : 150;
            presence_update_timeout = Timeout.add_full(interactive_source_priority(), delay, () => flush_presence_updates());
        }
    }

    private bool flush_presence_updates() {
        presence_update_timeout = 0;
        if (disposed) {
            pending_presence_jids.clear();
            pending_presence_rebuild = false;
            return Source.REMOVE;
        }
        if (background_work_suspended) {
            pending_summary_refresh = true;
            if (pending_presence_rebuild) pending_rebuild = true;
            return Source.REMOVE;
        }

        var pending = new ArrayList<Jid>(Jid.equals_func);
        pending.add_all(pending_presence_jids);
        pending_presence_jids.clear();

        foreach (Jid jid in pending) {
            if (!all_occupant_index.contains(jid)) continue;
            OccupantListItem item = ensure_item(jid, false);
            if (item.display_name == "") {
                if (should_defer_expensive_details()) {
                    refresh_item_lightweight(item);
                } else {
                    refresh_item(item);
                }
            } else {
                apply_presence_state(item, jid);
                item.notify_changed();
            }
        }

        if (pending_presence_rebuild || filter_values != null) {
            refresh_summary_counts_for_current_context();
            if (background_work_suspended) {
                pending_rebuild = true;
            } else {
                schedule_rebuild();
            }
        }
        pending_presence_rebuild = false;
        resume_loading_after_empty_state();
        return Source.REMOVE;
    }

    private void resume_loading_after_empty_state() {
        if (disposed || background_work_suspended || waiting_for_initial_snapshot ||
                cache.loaded || initializing) return;

        if (all_occupants.size == 0) {
            enter_stable_empty_snapshot_surface();
            return;
        }

        if (should_auto_start_loading_rows()) {
            start_loading_rows();
        }
    }

    private void on_occupant_hats_changed(Account account, Jid jid, Gee.List<Xmpp.Xep.Muc.Hat> hats) {
        if (!conversation.account.equals(account) || !conversation.counterpart.equals_bare(jid)) return;
        if (is_initial_presence_sync() || snapshot_apply_source != 0) return;
        if (uses_live_occupant_batches(account, jid.bare_jid)) return;

        OccupantListItem? item = cache.occupants.has_key(jid) ? cache.occupants[jid] : null;
        if (item != null) {
            update_item_hats(item);
            item.notify_changed();
        }
        if (filter_values != null) {
            if (background_work_suspended) {
                pending_summary_refresh = true;
                pending_rebuild = true;
            } else {
                schedule_rebuild();
            }
        }
    }

    private void on_occupant_affiliation_updated(Account account, Jid room_jid, Jid occupant_jid, Xmpp.Xep.Muc.Affiliation affiliation) {
        if (!conversation.account.equals(account) || !conversation.counterpart.equals_bare(room_jid)) return;
        if (!occupant_jid.is_full() || !conversation.counterpart.equals_bare(occupant_jid)) return;
        if (is_initial_presence_sync() || snapshot_apply_source != 0) return;
        if (uses_live_occupant_batches(account, room_jid)) return;

        bool known_occupant = all_occupant_index.contains(occupant_jid);
        if (!known_occupant) {
            add_occupant_to_state(occupant_jid, false);
        }
        OccupantListItem? item = cache.occupants.has_key(occupant_jid) ? cache.occupants[occupant_jid] : null;
        if (item != null) {
            if (should_defer_expensive_details()) {
                refresh_item_lightweight(item);
            } else {
                refresh_item(item);
            }
        }
        invalidate_cached_presentation();
        if (background_work_suspended) {
            pending_summary_refresh = true;
            pending_rebuild = true;
            return;
        }
        refresh_summary_counts_for_current_context();
        schedule_affiliation_rebuild();
    }

    private void on_bare_affiliation_changed(XmppStream stream, Jid room_jid,
            Jid target_jid, Xmpp.Xep.Muc.Affiliation _affiliation) {
        if (disposed || !conversation.counterpart.equals_bare(room_jid) ||
                !target_jid.is_bare() ||
                stream_interactor.get_stream(conversation.account) != stream) {
            return;
        }

        // change_affiliation() has already updated the account-scoped MUC
        // flag. Reconcile only this room's bare snapshot and matching live row;
        // never trigger a whole-room detail fetch here.
        refresh_private_member_snapshot_index();
        reconcile_private_member_snapshot();

        if (cache.occupants.has_key(target_jid)) {
            OccupantListItem item = cache.occupants[target_jid];
            sync_item_affiliation_from_state(item);
        }

        Jid? live_occupant = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY).get_occupant_jid(conversation.account,
                room_jid, target_jid);
        if (live_occupant != null && cache.occupants.has_key((!) live_occupant)) {
            OccupantListItem item = cache.occupants[(!) live_occupant];
            sync_item_affiliation_from_state(item);
        }

        cache.details_loaded = false;
        invalidate_cached_presentation();
        pending_summary_refresh = true;
        pending_rebuild = true;
        if (is_initial_presence_sync() || snapshot_apply_source != 0 ||
                background_work_suspended) {
            return;
        }

        pending_summary_refresh = false;
        refresh_summary_counts_for_current_context();
        schedule_affiliation_rebuild();
    }

    private void on_private_room_occupant_updated(Account account, Jid room_jid, Jid occupant_jid) {
        if (!conversation.account.equals(account) || !conversation.counterpart.equals_bare(room_jid)) return;
        if (is_initial_presence_sync() || snapshot_apply_source != 0) return;
        if (uses_live_occupant_batches(account, room_jid)) return;

        // A private-room avatar can switch between the occupant JID and the
        // resolved real bare JID. Rebind only the matching realized row so its
        // exact keyed avatar observers follow that identity change.
        refresh_realized_avatar(occupant_jid);

        bool snapshot_changed = refresh_private_member_snapshot_index();
        bool reconciled_snapshot = reconcile_private_member_snapshot();
        bool state_changed = snapshot_changed || reconciled_snapshot;

        if (is_large_room_context()) {
            Jid? row_jid = null;
            if (is_room_occupant_jid(occupant_jid)) {
                row_jid = occupant_jid;
            } else {
                row_jid = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_occupant_jid(account, conversation.counterpart, occupant_jid);
            }

            if (row_jid != null) {
                state_changed = add_occupant_to_state((!) row_jid, false) || state_changed;
            }

            OccupantListItem? direct_item = null;
            if (row_jid != null && cache.occupants.has_key((!) row_jid)) {
                direct_item = cache.occupants[(!) row_jid];
            } else if (cache.occupants.has_key(occupant_jid.bare_jid)) {
                direct_item = cache.occupants[occupant_jid.bare_jid];
            }
            if (direct_item != null) {
                refresh_item_lightweight((!) direct_item);
                state_changed = true;
            }
            if (state_changed) {
                cache.details_loaded = false;
                invalidate_cached_presentation();
                pending_summary_refresh = true;
                pending_rebuild = true;
                if (!background_work_suspended) {
                    schedule_pending_summary_refresh();
                    schedule_affiliation_rebuild();
                }
            }
            return;
        }

        foreach (OccupantListItem item in cache.occupants.values) {
            if (item.jid == null) continue;
            Jid row_jid = (!) item.jid;
            if (row_jid.equals(occupant_jid)) {
                refresh_item(item);
                state_changed = true;
                continue;
            }

            Jid? real_jid = stream_interactor.get_module<MucManager>(MucManager.IDENTITY).get_real_jid(row_jid, conversation.account);
            if (real_jid != null && ((!) real_jid).equals_bare(occupant_jid)) {
                state_changed = remove_occupant_from_state(occupant_jid.bare_jid) || state_changed;
                refresh_item(item);
                state_changed = true;
            }
        }
        if (state_changed) {
            cache.details_loaded = false;
            invalidate_cached_presentation();
        }
        if (background_work_suspended) {
            pending_summary_refresh = true;
            pending_rebuild = true;
            return;
        }
        refresh_summary_counts_for_current_context();
        schedule_rebuild();
    }

    private void on_room_real_jid_visibility_revoked(Account account,
            Jid room_jid) {
        if (disposed || !conversation.account.equals(account) ||
                !conversation.counterpart.equals_bare(room_jid)) return;

        // The protocol layer has already purged live real-JID mappings and
        // privileged affiliation snapshots. Drop matching bare rows and
        // refresh room/nick rows immediately so an open popover cannot retain
        // identities that the current role is no longer allowed to see.
        refresh_private_member_snapshot_index();
        reconcile_private_member_snapshot();
        cache.real_jid_visibility_generation = stream_interactor.get_module<
            MucManager>(MucManager.IDENTITY)
                .get_room_real_jid_visibility_generation(account, room_jid);
        foreach (OccupantListItem item in cache.occupants.values) {
            if (item.jid != null && ((!) item.jid).is_full()) {
                refresh_item_lightweight(item);
            }
        }
        cache.details_loaded = false;
        // Privacy revocation must override the cached-rejoin reveal path. Its
        // normal invalidator intentionally keeps the old visible model while
        // an initial snapshot is pending, which would leave disclosed bare
        // JIDs on screen. Clear that surface synchronously, then rebuild only
        // from the sanitized room/nick state.
        cancel_presentation_rebuild();
        presentation_cache_generation++;
        cache.presentation_items = null;
        presentation_store.remove_all();
        presentation_complete = false;
        pending_summary_refresh = true;
        pending_rebuild = true;
        if (is_initial_presence_sync() || snapshot_apply_source != 0 ||
                background_work_suspended) return;

        pending_summary_refresh = false;
        refresh_summary_counts_for_current_context();
        schedule_affiliation_rebuild();
    }

    private void on_room_occupant_projection_changed(Account account,
            Jid room_jid) {
        if (disposed || !conversation.account.equals(account) ||
                !conversation.counterpart.equals_bare(room_jid)) return;
        // A healthy worker receives targeted UNAVAILABLE envelopes and owns
        // the ordered UI delta. If no binding exists, rebuild immediately from
        // the already filtered local Presence flag so a degraded/fallback list
        // cannot retain occupants hidden by confirmed presencebroadcast.
        if (uses_live_occupant_batches(account, room_jid)) return;
        rebuild_from_authoritative_presence_after_live_batch_failure();
    }

    private void on_occupant_role_updated(Account account, Jid jid, Xmpp.Xep.Muc.Role? role) {
        if (!conversation.account.equals(account) || !conversation.counterpart.equals_bare(jid)) return;
        if (!jid.is_full() || !conversation.counterpart.equals_bare(jid)) return;
        if (is_initial_presence_sync() || snapshot_apply_source != 0) return;
        if (uses_live_occupant_batches(account, jid.bare_jid)) return;

        OccupantListItem? item = cache.occupants.has_key(jid) ? cache.occupants[jid] : null;
        if (item != null) {
            ((!) item).role = role ?? Xmpp.Xep.Muc.Role.NONE;
            ((!) item).role_known = role != null;
            ((!) item).notify_changed();
        }
        invalidate_cached_presentation();
        if (background_work_suspended) {
            pending_summary_refresh = true;
            pending_rebuild = true;
            return;
        }
        refresh_summary_counts_for_current_context();
        schedule_rebuild();
    }

    private bool uses_live_occupant_batches(Account account, Jid room) {
        return stream_interactor.get_module<MucManager>(MucManager.IDENTITY)
            .has_live_occupant_batching(account, room);
    }

    private void apply_pending_summary_refresh() {
        if (!pending_summary_refresh) return;

        pending_summary_refresh = false;
        refresh_summary_counts_for_current_context();
    }

    private void schedule_pending_summary_refresh(uint delay = 50) {
        if (!pending_summary_refresh || background_work_suspended || summary_refresh_timeout != 0) return;

        summary_refresh_timeout = Timeout.add_full(GLib.Priority.LOW, delay, () => {
            summary_refresh_timeout = 0;
            if (disposed || background_work_suspended) return Source.REMOVE;

            apply_pending_summary_refresh();
            return Source.REMOVE;
        });
    }

    private void recompute_summary_counts() {
        summary_counts.clear();
        if (all_occupants.size == 0) return;

        foreach (Jid jid in all_occupants) {
            count_summary_occupant(jid);
        }
    }

    private void count_summary_occupant(Jid jid) {
        Xmpp.Xep.Muc.Affiliation affiliation = Xmpp.Xep.Muc.Affiliation.NONE;
        bool affiliation_known = false;
        Xmpp.Xep.Muc.Role role = Xmpp.Xep.Muc.Role.NONE;
        bool role_known = false;

        if (cache.occupants.has_key(jid)) {
            OccupantListItem item = cache.occupants[jid];
            sync_item_affiliation_from_state(item, false);
            sync_item_role_from_state(item, false);
            affiliation = item.affiliation;
            affiliation_known = item.affiliation_known;
            role = item.role;
            role_known = item.role_known;
        } else {
            affiliation = get_affiliation(jid);
            affiliation_known = has_affiliation(jid);
            role = get_role(jid);
            role_known = has_role(jid);
        }

        MucMemberListSection section = MucMemberListSectionModel.classify(
            affiliation_known, affiliation, role_known, role);
        summary_counts[section] = get_summary_count(section) + 1;
    }

    private void update_summary() {
        update_summary_with_total(all_occupants.size);
    }

    private void update_summary_with_total(int total_count) {
        summary_label.label = ("%s: %d | %s: %d | %s: %d | " +
            "%s: %d | %s: %d | %s: %d | %s: %d").printf(
            _("Total"),
            total_count,
            _("Owner"),
            get_summary_count(MucMemberListSection.OWNER),
            _("Admin"),
            get_summary_count(MucMemberListSection.ADMIN),
            _("Moderator"),
            get_summary_count(MucMemberListSection.MODERATOR),
            _("Member"),
            get_summary_count(MucMemberListSection.MEMBER),
            _("Participants"),
            get_summary_count(MucMemberListSection.PARTICIPANT),
            _("Visitors"),
            get_summary_count(MucMemberListSection.VISITOR)
        );
    }

    private void update_summary_lightweight() {
        summary_label.label = "%s: %d".printf(_("Total"), all_occupants.size);
    }

    private void refresh_summary_counts_for_current_context() {
        if (is_large_room_context()) {
            update_summary_lightweight();
            return;
        }

        recompute_summary_counts();
        update_summary();
    }

    private int get_summary_count(MucMemberListSection section) {
        return summary_counts.has_key(section) ? summary_counts[section] : 0;
    }

    private void schedule_rebuild() {
        pending_rebuild = true;
        if (!cache.loaded || background_work_suspended) return;

        if (occupant_update_timeout == 0) {
            occupant_update_timeout = Timeout.add_full(GLib.Priority.LOW, 150, () => {
                occupant_update_timeout = 0;
                if (pending_rebuild) {
                    pending_rebuild = false;
                    rebuild_presentation();
                }
                return Source.REMOVE;
            });
        }
    }

    private void schedule_affiliation_rebuild() {
        pending_rebuild = true;
        if (!cache.loaded || background_work_suspended) return;

        schedule_rebuild();
    }

    private void schedule_detail_refresh() {
        // Large-room detail refreshes reintroduce the UI stalls this view is
        // designed to avoid. Keep large MUC member lists lightweight; richer
        // data such as affiliations, hats and avatars must be restored later
        // through a visible-row, rate-limited path instead of refreshing the
        // whole room in the popover lifecycle.
        if (is_large_room_context() || background_work_suspended || !cache.loaded) return;

        bool changed = false;
        foreach (OccupantListItem item in cache.occupants.values) {
            if (item.jid == null) continue;
            string old_hats_text = item.hats_text;
            string old_hats_markup = item.hats_markup;
            Gee.List<Xmpp.Xep.Muc.Hat> old_hats = item.hats;
            changed = sync_item_affiliation_from_state(item, false) || changed;
            update_item_hats(item);
            if (old_hats_text != item.hats_text || old_hats_markup != item.hats_markup ||
                    !item.hats_equal(old_hats)) changed = true;
        }
        if (changed) {
            rebuild_presentation();
        }
    }

    private void cancel_detail_refresh() {
        // Kept as a lifecycle hook for callers that cancel all deferred work.
    }

    private void cancel_cache_refresh() {
        if (cache_refresh_source != 0) {
            Source.remove(cache_refresh_source);
            cache_refresh_source = 0;
        }
        cache_refresh_queue = null;
        cache_refresh_index = 0;
        cache_refresh_rebuild_after = false;
    }

    private MucMemberListSection get_member_list_section(
            OccupantListItem item) {
        return MucMemberListSectionModel.classify(item.affiliation_known,
            item.affiliation, item.role_known, item.role);
    }

    private string get_member_list_section_key(OccupantListItem item) {
        return MucMemberListSectionModel.key(get_member_list_section(item));
    }

    private string get_member_list_section_label(OccupantListItem item) {
        switch (get_member_list_section(item)) {
            case MucMemberListSection.OWNER:
                return _("Owners");
            case MucMemberListSection.ADMIN:
                return _("Admins");
            case MucMemberListSection.MODERATOR:
                return _("Moderators");
            case MucMemberListSection.MEMBER:
                return _("Members");
            case MucMemberListSection.VISITOR:
                return _("Visitors");
            case MucMemberListSection.BANNED:
                return _("Banned users");
            case MucMemberListSection.PARTICIPANT:
            default:
                return _("Participants");
        }
    }

    private string get_hat_markup(Xmpp.Xep.Muc.Hat hat) {
        return get_hat_markup_values(hat.title.make_valid(), hat.hue);
    }

    private string get_hat_markup_values(string title, string? hue) {
        string escaped_title = Markup.escape_text(title.make_valid());
        string? color = get_hat_color(hue);
        if (color == null) return escaped_title;
        return "<span foreground=\"%s\">%s</span>".printf(color,
            escaped_title);
    }

    private string? get_hat_color(string? hue_string) {
        if (hue_string == null || hue_string == "") return null;

        double hue;
        if (!double.try_parse(hue_string, out hue) || !hue.is_finite() ||
                hue < 0 || hue > 360) return null;

        bool dark = false;
        var style_manager = Adw.StyleManager.get_default();
        if (style_manager != null) dark = style_manager.dark;

        double saturation = 0.70;
        double lightness = dark ? 0.68 : 0.36;
        double red;
        double green;
        double blue;
        hsl_to_rgb(hue / 360.0, saturation, lightness, out red, out green, out blue);

        return "#%02x%02x%02x".printf(
            (uint) Math.round(red * 255.0),
            (uint) Math.round(green * 255.0),
            (uint) Math.round(blue * 255.0)
        );
    }

    private void hsl_to_rgb(double hue, double saturation, double lightness, out double red, out double green, out double blue) {
        if (saturation == 0) {
            red = lightness;
            green = lightness;
            blue = lightness;
            return;
        }

        double q = lightness < 0.5 ? lightness * (1.0 + saturation) : lightness + saturation - lightness * saturation;
        double p = 2.0 * lightness - q;
        red = hue_to_rgb(p, q, hue + 1.0 / 3.0);
        green = hue_to_rgb(p, q, hue);
        blue = hue_to_rgb(p, q, hue - 1.0 / 3.0);
    }

    private double hue_to_rgb(double p, double q, double t) {
        if (t < 0) t += 1.0;
        if (t > 1) t -= 1.0;
        if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
        if (t < 1.0 / 2.0) return q;
        if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
        return p;
    }

    private string get_cache_key(Conversation conversation) {
        return "%d\n%s".printf(conversation.account.id, conversation.counterpart.to_string());
    }
}

}
