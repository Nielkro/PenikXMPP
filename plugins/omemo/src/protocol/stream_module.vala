using Gee;
using Xmpp;
using Xmpp.Xep;
using Omemo;

namespace Dino.Plugins.Omemo {

internal const string NS_URI = "eu.siacs.conversations.axolotl";
private const string NODE_DEVICELIST = NS_URI + ".devicelist";
private const string NODE_BUNDLES = NS_URI + ".bundles";
private const string NODE_VERIFICATION = NS_URI + ".verification";

private const int NUM_KEYS_TO_PUBLISH = 100;

private class LegacyBundlePayloadResult {
    public string? item_id;
    public StanzaNode? node;
    public bool request_failed;
    public string? error_condition;
    public string? error_text;
    public bool presence_subscription_required;

    public LegacyBundlePayloadResult (string? item_id, StanzaNode? node, bool request_failed, string? error_condition = null, string? error_text = null, bool presence_subscription_required = false) {
        this.item_id = item_id;
        this.node = node;
        this.request_failed = request_failed;
        this.error_condition = error_condition;
        this.error_text = error_text;
        this.presence_subscription_required = presence_subscription_required;
    }

    public bool is_access_denied () {
        return error_condition == ErrorStanza.CONDITION_NOT_AUTHORIZED ||
            error_condition == ErrorStanza.CONDITION_FORBIDDEN;
    }
}

private class OwnBundleOperation : Object {
    internal XmppStream stream;
    internal uint generation;
    internal PreKeyStore key_store;
    internal IdentityKeyStore identity_store;
    internal uint32 device_id;
    internal Jid own_jid;
    internal Cancellable cancellable = new Cancellable();
    internal bool superseded = false;
    internal bool invalidated = false;
    internal bool awaiting_publish_ack = true;

    internal OwnBundleOperation(XmppStream stream, uint generation, Store store,
            Jid own_jid) {
        this.stream = stream;
        this.generation = generation;
        key_store = store.pre_key_store;
        identity_store = store.identity_key_store;
        device_id = store.local_registration_id;
        this.own_jid = own_jid.bare_jid;
    }
}

// Local supersession is neither a server acknowledgement nor a server error.
private class SupersededOwnBundleResult : Pubsub.PublishResult {
    internal SupersededOwnBundleResult() { base(false); }
}

public class StreamModule : XmppStreamModule {
    public static Xmpp.ModuleIdentity<StreamModule> IDENTITY = new Xmpp.ModuleIdentity<StreamModule> (NS_URI, "omemo_module"); // vala-lint=naming-convention
    private static TimeSpan IGNORE_TIME = TimeSpan.MINUTE; // vala-lint=naming-convention

    public Store store { public get; private set; }
    public string? own_device_label { get; set; default = null; }
    public bool auto_publish_own_device_list { get; set; default = true; }
    internal LegacyRegistrationGuard? registration_guard { get; set; }
    internal uint attachment_generation { get { return stream_generation; } }
    private bool registration_probe_active = false;
    private bool registration_candidate_verified = false;
    private uint registration_retry_timeout = 0;
    private StanzaNode? registration_latest_node = null;
    private string? registration_latest_item_id = null;
    private ArrayList<int32>? registration_latest_devices = null;
    internal ConcurrentSet<string> active_bundle_requests = new ConcurrentSet<string> ();
    private HashSet<string> requested_session_builds = new HashSet<string> ();
    private HashMap<string, int> awaited_session_builds = new HashMap<string, int> ();
    private ConcurrentSet<string> pending_missing_bundle_retries = new ConcurrentSet<string> ();
    private ConcurrentSet<string> pending_transient_bundle_retries = new ConcurrentSet<string> ();
    private HashMap<string, uint> transient_bundle_retry_sources = new HashMap<string, uint> ();
    private HashMap<string, int> transient_bundle_retry_attempts = new HashMap<string, int> ();
    private HashMap<Jid, Future<ArrayList<int32>>> active_devicelist_requests = new HashMap<Jid, Future<ArrayList<int32>>> (Jid.hash_func, Jid.equals_func);
    private Map<string, DateTime> device_ignore_time = new HashMap<string, DateTime> ();
    private XmppStream? active_stream = null;
    private uint stream_generation = 0;
    private bool own_devicelist_publish_active = false;
    private DateTime? own_devicelist_publish_blocked_until = null;
    private StanzaNode? pending_own_devicelist_node = null;
    private Jid? pending_own_devicelist_jid = null;
    private ArrayList<int32>? pending_own_devicelist_loaded_after_success = null;
    private Promise<ArrayList<int32>?>? pending_own_devicelist_readiness_promise = null;
    private Future<ArrayList<int32>>? pending_own_devicelist_readiness_future = null;
    private bool pending_own_devicelist_publish_bundle_after_success = false;
    private bool own_devicelist_publish_waits_for_readiness = false;
    private ArrayList<int32>? last_successful_own_devicelist_publish_devices = null;
    private DateTime? last_successful_own_devicelist_publish_time = null;
    private bool own_devicelist_publish_options_max_items_supported = true;
    private uint own_devicelist_retry_timeout = 0;
    private int own_devicelist_retry_attempts = 0;
    private bool own_bundle_publish_active = false;
    private DateTime? own_bundle_publish_blocked_until = null;
    private StanzaNode? pending_own_bundle_node = null;
    private string? pending_own_bundle_node_id = null;
    private string? pending_own_bundle_item_id = null;
    private string? pending_own_bundle_retract_item_id = null;
    private Jid? pending_own_bundle_device_list_loaded_jid = null;
    private ArrayList<int32>? pending_own_bundle_device_list_loaded_after_success = null;
    private uint own_bundle_retry_timeout = 0;
    private int own_bundle_retry_attempts = 0;
    private uint own_bundle_refresh_timeout = 0;
    private uint64 own_pre_key_consumption_epoch = 0;
    private uint64 own_bundle_reconciled_epoch = 0;
    private uint64 pending_own_bundle_epoch = 0;
    private PreKeyStore? own_bundle_refresh_key_store;
    private uint32 own_bundle_refresh_device_id = 0;
    private OwnBundleOperation? active_own_bundle_operation;

    public signal void device_list_loaded (Jid jid, ArrayList<int32> devices);
    public signal void device_list_fetch_failed (Jid jid, Pubsub.RequestAllResult result);
    public signal void device_label_received (Jid jid, int32 device_id, string label);
    public signal void bundle_fetched (Jid jid, int device_id, Bundle bundle);
    internal signal void bundle_ready (Jid jid, int device_id, Bundle bundle, bool build_session);
    public signal void bundle_fetch_failed (Jid jid, int device_id);
    public signal void bundle_access_denied (Jid jid, int device_id, bool presence_subscription_required);
    internal signal void registration_candidate_ready ();

    public StreamModule (Store store) {
        this.store = store;
    }

    public override string get_id () { return IDENTITY.id; }
    public override string get_ns () { return IDENTITY.ns; }

    public override void attach (XmppStream stream) {
        if (active_stream == stream) return;
        if (active_stream != null) detach ((!) active_stream);
        active_stream = stream;
        stream_generation++;
        stream.get_module<Pubsub.Module> (Pubsub.Module.IDENTITY).add_filtered_notification (stream, NODE_DEVICELIST,
                (stream, jid, id, node) => parse_device_list (stream, jid, id, node), null, null);
        if (own_bundle_refresh_key_store != null &&
                (store.pre_key_store != own_bundle_refresh_key_store ||
                 store.local_registration_id != own_bundle_refresh_device_id)) {
            own_pre_key_consumption_epoch = own_bundle_reconciled_epoch = 0;
            own_bundle_refresh_key_store = null;
        }
        queue_own_bundle_refresh(stream, stream_generation);
    }

    public override void detach (XmppStream stream) {
        // Account modules survive reconnects. Old stream teardown must not
        // discard a replacement stream's pending keys or PubSub handlers.
        if (active_stream != stream) return;
        if (active_own_bundle_operation != null) {
            ((!) active_own_bundle_operation).cancellable.cancel();
            active_own_bundle_operation = null;
        }
        stream.get_module<Pubsub.Module> (Pubsub.Module.IDENTITY).remove_filtered_notification (stream, NODE_DEVICELIST);
        if (active_stream == stream) {
            active_stream = null;
            stream_generation++;
        }
        active_devicelist_requests.clear();
        active_bundle_requests = new ConcurrentSet<string> ();
        requested_session_builds.clear ();
        awaited_session_builds.clear ();
        pending_missing_bundle_retries = new ConcurrentSet<string> ();
        pending_transient_bundle_retries = new ConcurrentSet<string> ();
        foreach (uint source_id in transient_bundle_retry_sources.values) Source.remove (source_id);
        transient_bundle_retry_sources.clear ();
        transient_bundle_retry_attempts.clear ();
        registration_probe_active = false;
        registration_candidate_verified = false;
        clear_registration_list_snapshot ();
        if (registration_retry_timeout != 0) {
            Source.remove (registration_retry_timeout);
            registration_retry_timeout = 0;
        }
        if (own_devicelist_retry_timeout != 0) {
            Source.remove(own_devicelist_retry_timeout);
            own_devicelist_retry_timeout = 0;
        }
        if (own_bundle_retry_timeout != 0) {
            Source.remove(own_bundle_retry_timeout);
            own_bundle_retry_timeout = 0;
        }
        if (own_bundle_refresh_timeout != 0) {
            Source.remove(own_bundle_refresh_timeout);
            own_bundle_refresh_timeout = 0;
        }
        pending_own_bundle_epoch = 0;
        own_devicelist_publish_active = false;
        own_devicelist_publish_blocked_until = null;
        pending_own_devicelist_node = null;
        pending_own_devicelist_jid = null;
        pending_own_devicelist_loaded_after_success = null;
        complete_pending_own_devicelist_readiness (null);
        pending_own_devicelist_publish_bundle_after_success = false;
        own_devicelist_publish_waits_for_readiness = false;
        last_successful_own_devicelist_publish_devices = null;
        last_successful_own_devicelist_publish_time = null;
        own_bundle_publish_active = false;
        own_bundle_publish_blocked_until = null;
        pending_own_bundle_node = null;
        pending_own_bundle_node_id = null;
        pending_own_bundle_item_id = null;
        pending_own_bundle_retract_item_id = null;
        pending_own_bundle_device_list_loaded_jid = null;
        pending_own_bundle_device_list_loaded_after_success = null;
        own_devicelist_retry_attempts = 0;
        own_bundle_retry_attempts = 0;
    }

    public async ArrayList<int32> request_user_devicelist (XmppStream stream, Jid jid) {
        if (jid.localpart == null) {
            debug ("OMEMO: Not requesting device list for domain JID %s", jid.to_string ());
            return new ArrayList<int32> ();
        }
        var future = active_devicelist_requests[jid];
        if (future == null && is_own_devicelist_jid (stream, jid) && pending_own_devicelist_readiness_future != null) {
            debug ("OMEMO: own device-list request coalesced for %s; repair/readiness operation is already pending", jid.bare_jid.to_string ());
            return yield wait_pending_own_devicelist_readiness ();
        }
        if (future == null) {
            var promise = new Promise<ArrayList<int32>?> ();
            future = promise.future;
            active_devicelist_requests[jid] = future;

            uint generation = stream_generation;
            var request_future = future;
            request_user_devicelist_uncached.begin(stream, jid, generation, (obj, res) => {
                ArrayList<int32> device_list = request_user_devicelist_uncached.end(res);
                promise.set_value(device_list);
                if (active_devicelist_requests[jid] == request_future) {
                    active_devicelist_requests.unset(jid);
                }
            });
        }

        try {
            return yield future.wait_async ();
        } catch (FutureError error) {
            active_devicelist_requests.unset(jid);
            warning ("Future error when waiting for device list: %s", error.message);
            return new ArrayList<int32> ();
        }
    }

    private bool is_own_devicelist_jid (XmppStream stream, Jid jid) {
        Bind.Flag? bind_flag = stream.get_flag<Bind.Flag> (Bind.Flag.IDENTITY);
        Jid? my_jid = bind_flag != null ? ((!) bind_flag).my_jid : null;
        return my_jid != null && jid.equals_bare ((!) my_jid);
    }

    private Future<ArrayList<int32>> ensure_pending_own_devicelist_readiness_future () {
        if (pending_own_devicelist_readiness_future == null) {
            var promise = new Promise<ArrayList<int32>?> ();
            pending_own_devicelist_readiness_promise = promise;
            pending_own_devicelist_readiness_future = promise.future;
        }
        return (!) pending_own_devicelist_readiness_future;
    }

    private async ArrayList<int32> wait_pending_own_devicelist_readiness () {
        if (pending_own_devicelist_readiness_future == null) return new ArrayList<int32> ();
        try {
            return yield ((!) pending_own_devicelist_readiness_future).wait_async ();
        } catch (FutureError error) {
            warning ("Future error when waiting for own device-list readiness: %s", error.message);
            return new ArrayList<int32> ();
        }
    }

    private async ArrayList<int32> wait_for_own_devicelist_readiness_if_pending (XmppStream stream, Jid jid, ArrayList<int32> fallback) {
        if (!is_own_devicelist_jid (stream, jid) || pending_own_devicelist_readiness_future == null) return fallback;
        return yield wait_pending_own_devicelist_readiness ();
    }

    private void complete_pending_own_devicelist_readiness (Gee.List<int32>? devices) {
        if (pending_own_devicelist_readiness_promise == null) return;

        Promise<ArrayList<int32>?> promise = (!) pending_own_devicelist_readiness_promise;
        pending_own_devicelist_readiness_promise = null;
        pending_own_devicelist_readiness_future = null;

        ArrayList<int32>? ready_devices = clone_device_list_for_signal (devices);
        promise.set_value (ready_devices ?? new ArrayList<int32> ());
    }

    private void remember_successful_own_devicelist_publish (Gee.List<int32>? devices) {
        last_successful_own_devicelist_publish_devices = clone_device_list_for_signal (devices);
        last_successful_own_devicelist_publish_time = last_successful_own_devicelist_publish_devices != null ? new DateTime.now_utc () : null;
    }

    private ArrayList<int32>? get_recent_successful_own_devicelist_publish (XmppStream stream, Jid jid) {
        if (!is_own_devicelist_jid (stream, jid)) return null;
        if (last_successful_own_devicelist_publish_devices == null || last_successful_own_devicelist_publish_time == null) return null;
        if (new DateTime.now_utc ().difference ((!) last_successful_own_devicelist_publish_time) > IGNORE_TIME) return null;
        if (!((!) last_successful_own_devicelist_publish_devices).contains ((int32) store.local_registration_id)) return null;
        return clone_device_list_for_signal ((!) last_successful_own_devicelist_publish_devices);
    }

    private async ArrayList<int32> request_user_devicelist_uncached (XmppStream stream, Jid jid, uint generation) {
        if (!is_current_stream(stream, generation)) return new ArrayList<int32> ();
        string? item_id = null;
        Pubsub.RequestAllResult result = yield stream.get_module<Pubsub.Module> (Pubsub.Module.IDENTITY).request_all_with_result (
            stream, jid, NODE_DEVICELIST, -1, Pubsub.RequestPurpose.STATE_SYNC);
        Gee.List<StanzaNode>? items = result.items;
        if (!is_current_stream(stream, generation)) return new ArrayList<int32> ();
        // IQ detach can resume this request before this module is detached.
        // This is neither an authoritative empty list nor a server failure.
        if (result.locally_cancelled) {
            debug("OMEMO: device-list request cancelled for %s", jid.bare_jid.to_string());
            return new ArrayList<int32> ();
        }
        if (result.is_item_not_found()) {
            Jid? my_jid = stream.get_flag (Bind.Flag.IDENTITY).my_jid;
            if (auto_publish_own_device_list && my_jid != null && jid.equals_bare ((!) my_jid)) {
                debug("OMEMO: device list for own JID %s is missing; bootstrapping publish using empty list", jid.bare_jid.to_string());
                ArrayList<int32> device_list = parse_device_list (stream, jid, null, null);
                return yield wait_for_own_devicelist_readiness_if_pending (stream, jid, device_list);
            }
            // A missing contact node is a successfully loaded empty list, not
            // a transient request failure. Emit device_list_loaded so pending
            // sends reach a deterministic terminal state.
            return parse_device_list (stream, jid, null, null);
        }
        if (items == null) {
            // A failed query is not an authoritative empty device list.
            // Wake direct sends with a local error rather than leaving them
            // waiting for a device_list_loaded signal that cannot arrive.
            warning ("OMEMO: device-list request failed for %s (condition=%s)",
                jid.bare_jid.to_string (), result.error_condition ?? "unknown");
            device_list_fetch_failed (jid, result);
            return new ArrayList<int32> ();
        }
        StanzaNode? node = select_first_payload (items, out item_id);
        ArrayList<int32> device_list = parse_device_list (stream, jid, item_id, node);
        return yield wait_for_own_devicelist_readiness_if_pending (stream, jid, device_list);
    }

    private void clear_registration_list_snapshot () {
        registration_latest_node = null;
        registration_latest_item_id = null;
        registration_latest_devices = null;
    }

    private async void verify_first_registration (XmppStream stream, Jid jid,
            uint generation) {
        try {
            if (registration_guard == null) throw new GLib.Error(-1, 0, "Missing registration guard");
            LegacyRegistrationGuard guard = (!) registration_guard;
            HashSet<int32> foreign_bundle_ids = new HashSet<int32> ();
            bool verified = false;
            for (int attempt = 0; attempt < 16; attempt++) {
                int32 previous_id = guard.read_device_id_checked ();
                // Check every candidate, including replacements, even if it
                // is unlisted: do not overwrite an orphaned foreign bundle.
                LegacyBundlePayloadResult result = yield request_legacy_bundle_payload (
                        stream, jid, @"$NODE_BUNDLES:$previous_id");
                if (!is_current_stream (stream, generation)) return;
                if (result.request_failed) {
                    debug ("OMEMO: Initial device-ID check deferred after bundle lookup failure");
                    defer_first_registration (stream, jid, generation);
                    return;
                }
                if (guard.read_device_id_checked () != previous_id || !guard.read_pending_checked ()) {
                    defer_first_registration (stream, jid, generation);
                    return;
                }
                if (registration_latest_devices == null || registration_latest_node == null) {
                    defer_first_registration (stream, jid, generation);
                    return;
                }
                // Own-list notifications may arrive while this IQ is pending.
                // Use their latest device IDs for collision detection, while
                // retaining every foreign bundle found by earlier probes.
                ArrayList<int32> occupied = (!) clone_device_list_for_signal (registration_latest_devices);
                foreach (int32 foreign_id in foreign_bundle_ids) {
                    if (!occupied.contains (foreign_id)) occupied.add (foreign_id);
                }
                bool matching = false;
                if (result.node != null) {
                    var bundle = new Bundle ((!) result.node);
                    matching = guard.matches_identity_key_checked (bundle.identity_key);
                    if (!matching) {
                        foreign_bundle_ids.add (previous_id);
                        if (!occupied.contains (previous_id)) occupied.add (previous_id);
                    }
                }
                int32 selected_id = guard.resolve_candidate_checked (occupied, matching);
                store.identity_key_store.local_registration_id = (uint32) selected_id;
                if (selected_id == previous_id) {
                    verified = true;
                    break;
                }
            }
            if (!verified) {
                defer_first_registration (stream, jid, generation);
                return;
            }
            registration_candidate_verified = true;
            registration_probe_active = false;
            registration_candidate_ready ();
            if (!is_current_stream (stream, generation)) return;
            // Only now may the ordinary list/bundle publisher run. Preserve
            // the latest server list and labels, including notifications that
            // arrived while the candidate's bundle was being checked.
            StanzaNode? node = registration_latest_node;
            string? item_id = registration_latest_item_id;
            clear_registration_list_snapshot ();
            parse_device_list (stream, jid, item_id, node);
        } catch (Error e) {
            if (!is_current_stream (stream, generation)) return;
            warning ("OMEMO: Initial device-ID check failed: %s", e.message);
            defer_first_registration (stream, jid, generation);
        }
    }

    private void defer_first_registration (XmppStream stream, Jid jid, uint generation) {
        registration_probe_active = false;
        registration_candidate_verified = false;
        clear_registration_list_snapshot ();
        complete_pending_own_devicelist_readiness (null);
        if (registration_retry_timeout != 0) return;
        registration_retry_timeout = Timeout.add_seconds (30, () => {
            registration_retry_timeout = 0;
            if (is_current_stream (stream, generation)) request_user_devicelist.begin (stream, jid);
            return Source.REMOVE;
        });
    }

    public ArrayList<int32> parse_device_list (XmppStream stream, Jid jid, string? id, StanzaNode? node_) {
        ArrayList<int32> device_list = new ArrayList<int32> ();
        HashMap<int32, string> device_labels = new HashMap<int32, string> ();

        StanzaNode node = node_ ?? new StanzaNode.build ("list", NS_URI).add_self_xmlns ();
        Jid? my_jid = stream.get_flag (Bind.Flag.IDENTITY).my_jid;
        if (my_jid == null) return device_list;
        foreach (StanzaNode device_node in node.get_subnodes ("device")) {
            int32 did = device_node.get_attribute_int ("id");
            if (did <= 0) continue;
            if (!device_list.contains (did)) {
                device_list.add (did);
            }
            string? label = device_node.get_attribute ("label");
            if (label != null && label.length > 0) {
                device_labels[did] = (!) label;
                device_label_received (jid, did, (!) label);
            }
        }
        bool device_list_loaded_deferred = false;
        ArrayList<int32>? device_list_return_override = null;
        if (auto_publish_own_device_list && jid.equals_bare (my_jid) &&
                store.registration_pending && !registration_candidate_verified) {
            if (!is_attached_stream (stream)) return device_list;
            registration_latest_node = build_devicelist_node (device_list, device_labels);
            registration_latest_item_id = id;
            registration_latest_devices = clone_device_list_for_signal (device_list);
            ensure_pending_own_devicelist_readiness_future ();
            if (!registration_probe_active) {
                registration_probe_active = true;
                verify_first_registration.begin (stream, jid, stream_generation);
            }
            return device_list;
        }
        if (auto_publish_own_device_list && jid.equals_bare (my_jid) && store.local_registration_id != 0) {
            bool am_on_devicelist = device_list.contains ((int32) store.local_registration_id);
            if (am_on_devicelist) {
                if (own_devicelist_publish_active || pending_own_devicelist_node != null) {
                    ensure_pending_own_devicelist_readiness_future ();
                    pending_own_devicelist_loaded_after_success = clone_device_list_for_signal (device_list);
                    device_list_loaded_deferred = true;
                } else {
                    own_devicelist_publish_blocked_until = null;
                    own_devicelist_retry_attempts = 0;
                    if (own_devicelist_retry_timeout != 0) {
                        Source.remove(own_devicelist_retry_timeout);
                        own_devicelist_retry_timeout = 0;
                    }
                }
                ensure_pending_own_devicelist_readiness_future ();
                publish_bundles_if_needed (stream, jid, device_list);
                device_list_loaded_deferred = true;
            } else {
                ArrayList<int32>? recent_published_devices = get_recent_successful_own_devicelist_publish (stream, jid);
                if (recent_published_devices != null) {
                    debug ("OMEMO: own device-list response for %s is stale after successful publish; using the acknowledged list", jid.bare_jid.to_string ());
                    device_list_return_override = (!) recent_published_devices;
                } else {
                    debug ("Not on device list, adding id");
                    device_list_return_override = new ArrayList<int32> ();
                    device_list.add ((int32) store.local_registration_id);
                    if (own_device_label != null && own_device_label.length > 0) {
                        device_labels[(int32) store.local_registration_id] = (!) own_device_label;
                    }
                    // During first registration the readiness future already
                    // waits for the ID probe. It does not mean a publish has
                    // started; the verified candidate must now be published.
                    if (own_devicelist_publish_active || pending_own_devicelist_node != null ||
                            (pending_own_devicelist_readiness_future != null && !store.registration_pending)) {
                        debug ("OMEMO: own device-list repair already pending for %s; stale missing-device response is coalesced", jid.bare_jid.to_string ());
                        ensure_pending_own_devicelist_readiness_future ();
                    } else {
                        publish_own_devicelist (stream, jid, device_list, device_labels, true, device_list);
                    }
                }
                device_list_loaded_deferred = true;
            }
        }
        if (!device_list_loaded_deferred) {
            device_list_loaded (jid, device_list);
        }

        if (device_list_return_override != null) {
            return (!) device_list_return_override;
        }
        return device_list;
    }

    internal void publish_own_devicelist (XmppStream stream, Jid jid, Gee.List<int32> devices, Map<int32, string>? labels = null, bool publish_bundle_after_success = false, Gee.List<int32>? device_list_loaded_after_success = null) {
        if (store.registration_pending && !registration_candidate_verified) return;
        ArrayList<int32>? readiness_devices = clone_device_list_for_signal (device_list_loaded_after_success);
        if (is_own_devicelist_jid (stream, jid) && (readiness_devices != null || !publish_bundle_after_success)) {
            ensure_pending_own_devicelist_readiness_future ();
            if (readiness_devices == null) {
                readiness_devices = clone_device_list_for_signal (devices);
            }
        }
        publish_own_devicelist_if_allowed (stream, jid, NODE_DEVICELIST, build_devicelist_node (devices, labels), create_devicelist_publish_options (), publish_bundle_after_success, readiness_devices);
    }

    private ArrayList<int32>? clone_device_list_for_signal (Gee.List<int32>? devices) {
        if (devices == null) return null;

        ArrayList<int32> copy = new ArrayList<int32> ();
        foreach (int32 device_id in (!) devices) {
            copy.add (device_id);
        }
        return copy;
    }

    private Pubsub.PublishOptions create_devicelist_publish_options () {
        Pubsub.PublishOptions options = new Pubsub.PublishOptions()
            .set_access_model(Pubsub.ACCESS_MODEL_OPEN)
            .set_persist_items(true);
        if (own_devicelist_publish_options_max_items_supported) {
            options.set_max_items("1");
        }
        return options;
    }

    private StanzaNode build_devicelist_node (Gee.List<int32> devices, Map<int32, string>? labels = null) {
        StanzaNode list_node = new StanzaNode.build ("list", NS_URI).add_self_xmlns ();
        foreach (int32 device_id in devices) {
            var device_node = new StanzaNode.build ("device", NS_URI)
                .put_attribute ("id", device_id.to_string ());
            if (labels != null && ((!) labels).has_key (device_id)) {
                device_node.put_attribute ("label", ((!) labels)[device_id]);
            } else if (device_id == (int32) store.local_registration_id && own_device_label != null && own_device_label.length > 0) {
                device_node.put_attribute ("label", (!) own_device_label);
            }
            list_node.put_node (device_node);
        }
        return list_node;
    }

    private StanzaNode? select_first_payload (Gee.List<StanzaNode>? items, out string? item_id) {
        item_id = null;
        if (items == null) return null;
        StanzaNode? fallback = null;
        string? fallback_id = null;
        foreach (StanzaNode item in items) {
            if (item.sub_nodes.size == 0) continue;
            string? id = item.get_attribute ("id") ?? item.get_attribute ("id", Pubsub.NS_URI);
            if (id == "current") {
                item_id = id;
                return item.sub_nodes[0];
            }
            if (fallback == null) {
                fallback = item.sub_nodes[0];
                fallback_id = id;
            }
        }
        item_id = fallback_id;
        return fallback;
    }

    private bool is_current_stream (XmppStream stream, uint generation) {
        return active_stream == stream && stream_generation == generation;
    }

    private bool is_current_own_bundle_store(XmppStream stream, uint generation,
            PreKeyStore key_store, uint32 device_id) {
        return is_current_stream(stream, generation) && store.is_persistence_ready &&
            store.pre_key_store == key_store && store.local_registration_id == device_id &&
            (!store.registration_pending || registration_candidate_verified);
    }

    private bool is_current_own_bundle_operation(OwnBundleOperation operation,
            bool allow_cancelled = false) {
        return !operation.invalidated &&
            (allow_cancelled || !operation.cancellable.is_cancelled()) &&
            is_current_own_bundle_store(operation.stream, operation.generation,
                operation.key_store, operation.device_id) &&
            store.identity_key_store == operation.identity_store &&
            is_own_devicelist_jid(operation.stream, operation.own_jid);
    }

    internal void on_legacy_pre_key_consumed(XmppStream stream) {
        if (!is_attached_stream(stream) || !store.is_persistence_ready ||
                store.registration_pending) return;
        own_bundle_refresh_key_store = store.pre_key_store;
        own_bundle_refresh_device_id = store.local_registration_id;
        own_pre_key_consumption_epoch++;
        if (active_own_bundle_operation != null) {
            // Serialize already-sent publish writes through their ACK. Only
            // subsequent config/retract phases may be cancelled by consumption.
            ((!) active_own_bundle_operation).superseded = true;
            if (!((!) active_own_bundle_operation).awaiting_publish_ack) {
                ((!) active_own_bundle_operation).cancellable.cancel();
            }
        }
        queue_own_bundle_refresh(stream, stream_generation);
    }

    private void queue_own_bundle_refresh(XmppStream stream, uint generation) {
        if (own_bundle_refresh_timeout != 0 ||
                own_pre_key_consumption_epoch == own_bundle_reconciled_epoch ||
                own_bundle_refresh_key_store == null ||
                !is_current_own_bundle_store(stream, generation,
                    (!) own_bundle_refresh_key_store, own_bundle_refresh_device_id)) return;
        DateTime now = new DateTime.now_utc();
        // Existing own-list/bundle retry timers retain their backoff. A burst
        // of received PREKEYs must not restart those timers or busy-loop.
        if ((own_bundle_publish_blocked_until != null &&
                now.compare((!) own_bundle_publish_blocked_until) < 0) ||
            (own_devicelist_publish_blocked_until != null &&
                now.compare((!) own_devicelist_publish_blocked_until) < 0)) return;
        own_bundle_refresh_timeout = Timeout.add(200, () => {
            own_bundle_refresh_timeout = 0;
            if (own_bundle_refresh_key_store == null ||
                    !is_current_own_bundle_store(stream, generation,
                        (!) own_bundle_refresh_key_store, own_bundle_refresh_device_id)) return Source.REMOVE;
            Jid? own_jid = stream.get_flag(Bind.Flag.IDENTITY).my_jid;
            if (own_jid != null) publish_bundles_if_needed(stream, ((!) own_jid).bare_jid);
            return Source.REMOVE;
        });
    }

    private void publish_own_devicelist_if_allowed(XmppStream stream, Jid jid, string node_id, StanzaNode node, Pubsub.PublishOptions publish_options, bool publish_bundle_after_success = false, ArrayList<int32>? device_list_loaded_after_success = null) {
        uint generation = stream_generation;
        if (!is_current_stream(stream, generation)) return;
        DateTime now = new DateTime.now_utc();
        if (own_devicelist_publish_active) {
            debug("OMEMO: own device-list publish already active for %s", jid.bare_jid.to_string());
            pending_own_devicelist_node = node;
            pending_own_devicelist_jid = jid;
            if (device_list_loaded_after_success != null) {
                pending_own_devicelist_loaded_after_success = device_list_loaded_after_success;
            }
            pending_own_devicelist_publish_bundle_after_success = pending_own_devicelist_publish_bundle_after_success || publish_bundle_after_success;
            return;
        }
        if (own_devicelist_publish_blocked_until != null && now.compare((!) own_devicelist_publish_blocked_until) < 0) {
            debug("OMEMO: own device-list publish deferred after previous failure for %s", jid.bare_jid.to_string());
            pending_own_devicelist_node = node;
            pending_own_devicelist_jid = jid;
            if (device_list_loaded_after_success != null) {
                pending_own_devicelist_loaded_after_success = device_list_loaded_after_success;
            }
            pending_own_devicelist_publish_bundle_after_success = pending_own_devicelist_publish_bundle_after_success || publish_bundle_after_success;
            schedule_own_devicelist_retry(stream, jid, get_retry_seconds_until((!) own_devicelist_publish_blocked_until, now));
            return;
        }

        own_devicelist_publish_active = true;
        own_devicelist_publish_waits_for_readiness = publish_bundle_after_success || device_list_loaded_after_success != null;
        Jid? publish_jid = get_own_pep_publish_jid(stream, jid);
        stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).publish_with_result.begin(stream, publish_jid, node_id, "current", node, publish_options, true, false, (obj, res) => {
            if (!is_current_stream(stream, generation)) return;
            Pubsub.PublishResult result = stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).publish_with_result.end(res);
            own_devicelist_publish_active = false;
            own_devicelist_publish_waits_for_readiness = false;
            if (result.ok) {
                own_devicelist_publish_blocked_until = null;
                own_devicelist_retry_attempts = 0;
                if (own_devicelist_retry_timeout != 0) {
                    Source.remove(own_devicelist_retry_timeout);
                    own_devicelist_retry_timeout = 0;
                }
                try_make_node_public.begin(stream, node_id);
                StanzaNode? next_node = pending_own_devicelist_node;
                Jid? next_jid = pending_own_devicelist_jid;
                ArrayList<int32>? next_device_list_loaded_after_success = pending_own_devicelist_loaded_after_success;
                ArrayList<int32>? current_device_list_loaded_after_success = device_list_loaded_after_success ?? next_device_list_loaded_after_success;
                bool next_publish_bundle_after_success = pending_own_devicelist_publish_bundle_after_success || publish_bundle_after_success;
                pending_own_devicelist_node = null;
                pending_own_devicelist_jid = null;
                pending_own_devicelist_loaded_after_success = null;
                pending_own_devicelist_publish_bundle_after_success = false;
                if (next_node != null && next_jid != null) {
                    if (next_device_list_loaded_after_success == null) {
                        next_device_list_loaded_after_success = device_list_loaded_after_success;
                    }
                    publish_own_devicelist_if_allowed(stream, (!) next_jid, node_id, (!) next_node, create_devicelist_publish_options(), next_publish_bundle_after_success, next_device_list_loaded_after_success);
                    return;
                } else if (next_publish_bundle_after_success) {
                    remember_successful_own_devicelist_publish (current_device_list_loaded_after_success);
                    publish_bundles_if_needed(stream, jid, current_device_list_loaded_after_success);
                    current_device_list_loaded_after_success = null;
                }
                if (current_device_list_loaded_after_success != null) {
                    remember_successful_own_devicelist_publish (current_device_list_loaded_after_success);
                    complete_pending_own_devicelist_readiness (current_device_list_loaded_after_success);
                    device_list_loaded(jid, (!) current_device_list_loaded_after_success);
                }
            } else {
                if (own_devicelist_publish_options_max_items_supported && result_is_unknown_publish_option(result, "pubsub#max_items")) {
                    own_devicelist_publish_options_max_items_supported = false;
                    debug("OMEMO: server rejected pubsub#max_items in device-list publish-options; retrying without that field");
                    publish_own_devicelist_if_allowed(stream, jid, node_id, node, create_devicelist_publish_options(), publish_bundle_after_success, device_list_loaded_after_success);
                    return;
                }
                if (pending_own_devicelist_node == null) {
                    pending_own_devicelist_node = node;
                    pending_own_devicelist_jid = jid;
                }
                if (pending_own_devicelist_jid == null) {
                    pending_own_devicelist_jid = jid;
                }
                if (device_list_loaded_after_success != null && pending_own_devicelist_loaded_after_success == null) {
                    pending_own_devicelist_loaded_after_success = device_list_loaded_after_success;
                }
                pending_own_devicelist_publish_bundle_after_success = pending_own_devicelist_publish_bundle_after_success || publish_bundle_after_success;
                own_devicelist_retry_attempts++;
                uint retry_delay = get_own_publish_retry_delay_for_result(result, own_devicelist_retry_attempts);
                own_devicelist_publish_blocked_until = new DateTime.now_utc().add_seconds(retry_delay);
                log_own_publish_retry("device-list", node_id, result, retry_delay);
                schedule_own_devicelist_retry(stream, jid, retry_delay);
            }
        });
    }

    private Jid? get_own_pep_publish_jid(XmppStream stream, Jid jid) {
        Jid? my_jid = stream.get_flag(Bind.Flag.IDENTITY).my_jid;
        if (my_jid != null && jid.equals_bare((!) my_jid)) return null;
        return jid;
    }

    private bool result_is_unknown_publish_option(Pubsub.PublishResult result, string field_name) {
        if (result.ok || result.error_text == null) return false;
        string text = (!) result.error_text;
        return text.contains(@"Unknown field '$field_name'") && text.contains("publish-options");
    }

    internal static uint get_own_publish_retry_delay_for_error(string? error_type, string? error_condition, int attempts) {
        if (error_type == ErrorStanza.TYPE_WAIT && error_condition == ErrorStanza.CONDITION_RESOURCE_CONSTRAINT) {
            if (attempts <= 1) return 600;
            if (attempts == 2) return 1800;
            return 3600;
        }
        if (attempts <= 1) return 30;
        if (attempts == 2) return 60;
        if (attempts == 3) return 120;
        return 300;
    }

    private uint get_own_publish_retry_delay_for_result(Pubsub.PublishResult? result, int attempts) {
        return get_own_publish_retry_delay_for_error(
            result != null ? ((!) result).error_type : null,
            result != null ? ((!) result).error_condition : null,
            attempts);
    }

    private uint get_own_publish_retry_delay(int attempts) {
        return get_own_publish_retry_delay_for_error(null, null, attempts);
    }

    private uint get_retry_seconds_until(DateTime until, DateTime now) {
        TimeSpan remaining = until.difference(now);
        if (remaining <= 0) return 1;
        int64 seconds = (remaining + TimeSpan.SECOND - 1) / TimeSpan.SECOND;
        if (seconds > uint.MAX) return uint.MAX;
        return (uint) seconds;
    }

    private void log_own_publish_retry(string target, string node_id, Pubsub.PublishResult? result, uint retry_delay) {
        if (result != null && ((!) result).is_error(ErrorStanza.TYPE_WAIT, ErrorStanza.CONDITION_RESOURCE_CONSTRAINT)) {
            warning("OMEMO: server deferred own %s PubSub publish for node %s with wait/resource-constraint; retrying in %u seconds",
                target, node_id, retry_delay);
            return;
        }
        string detail = result != null ? ((!) result).describe_error() : "unknown";
        warning("OMEMO: own %s PubSub publish failed for node %s: %s; retrying in %u seconds",
            target, node_id, detail, retry_delay);
    }

    private void schedule_own_devicelist_retry(XmppStream stream, Jid jid, uint retry_delay) {
        if (own_devicelist_retry_timeout != 0) return;
        uint generation = stream_generation;
        own_devicelist_retry_timeout = Timeout.add_seconds(retry_delay, () => {
            own_devicelist_retry_timeout = 0;
            if (!is_current_stream(stream, generation)) return Source.REMOVE;
            own_devicelist_publish_blocked_until = null;
            StanzaNode? next_node = pending_own_devicelist_node;
            Jid? next_jid = pending_own_devicelist_jid ?? jid;
            ArrayList<int32>? next_device_list_loaded_after_success = pending_own_devicelist_loaded_after_success;
            bool publish_bundle_after_success = pending_own_devicelist_publish_bundle_after_success;
            pending_own_devicelist_node = null;
            pending_own_devicelist_jid = null;
            pending_own_devicelist_loaded_after_success = null;
            pending_own_devicelist_publish_bundle_after_success = false;
            if (next_node != null && next_jid != null) {
                publish_own_devicelist_if_allowed(stream, (!) next_jid, NODE_DEVICELIST, (!) next_node, create_devicelist_publish_options(), publish_bundle_after_success, next_device_list_loaded_after_success);
            } else {
                request_user_devicelist.begin(stream, jid);
            }
            return Source.REMOVE;
        });
    }

    public void fetch_bundles (XmppStream stream, Jid jid, Gee.List<int32> devices) {
        Address address = new Address (jid.bare_jid.to_string (), 0);
        foreach (int32 device_id in devices) {
            if (!is_ignored_device (jid, device_id)) {
                address.device_id = device_id;
                try {
                    if (!store.contains_session (address)) {
                        fetch_bundle (stream, jid, device_id, false);
                    }
                } catch (Error e) {
                    // Ignore
                }
            }
        }
        address.device_id = 0; // Hack: Keeps 'address' alive until function exit, preventing premature free during loop.
    }

    // Discovery/UI callers need authenticated device metadata, not an unused
    // ratchet. XEP-0384 v0.3 section 5 recommends building only before sending.
    public void fetch_bundle_info (XmppStream stream, Jid jid, int device_id, bool ignore_if_non_present = true) {
        fetch_bundle (stream, jid, device_id, ignore_if_non_present, false);
    }

    public void fetch_bundle (XmppStream stream, Jid jid, int device_id, bool ignore_if_non_present = true, bool build_session = true) {
        uint generation = stream_generation;
        if (!is_current_stream(stream, generation)) return;
        string request_key = jid.bare_jid.to_string () + @":$device_id";
        // A send may arrive while metadata discovery or a retry is in flight.
        // Upgrade that request rather than losing the send's session demand.
        if (build_session) requested_session_builds.add (request_key);
        if (pending_missing_bundle_retries.contains (request_key) ||
                pending_transient_bundle_retries.contains (request_key)) return;
        if (active_bundle_requests.add (request_key)) {
            debug ("Asking for bundle for %s/%d", jid.bare_jid.to_string (), device_id);
            fetch_bundle_async.begin (stream, jid, device_id, ignore_if_non_present, generation);
        }
    }

    public void reset_bundle_request(Jid jid, int device_id) {
        active_bundle_requests.remove(jid.bare_jid.to_string () + @":$device_id");
    }

    internal bool has_legacy_session_for_send (Jid jid, int device_id) {
        if (!store.is_persistence_ready || store.registration_pending) return false;
        Address address = new Address (jid.bare_jid.to_string (), device_id);
        try {
            if (!store.contains_session (address)) return false;
            SessionCipher cipher = store.create_session_cipher (address);
            return cipher.get_session_version () == 3;
        } catch (Error e) {
            return false;
        } finally {
            address.device_id = 0;
        }
    }

    private void release_awaited_session_build (string request_key, uint generation) {
        if (stream_generation != generation || !awaited_session_builds.has_key (request_key)) return;
        int remaining = awaited_session_builds[request_key] - 1;
        if (remaining > 0) awaited_session_builds[request_key] = remaining;
        else awaited_session_builds.unset (request_key);
    }

    // JET constructs its envelope synchronously. Only its actual send hook
    // waits here; cancelled/timed-out waiters must not leave a ratchet demand
    // on a late metadata response. Other concurrent sends retain their demand.
    internal async bool ensure_legacy_session_for_send (XmppStream stream,
            Jid jid, int device_id, Cancellable cancellable) {
        return yield await_legacy_bundle_for_send (stream, jid, device_id, cancellable, true);
    }

    internal async bool await_legacy_bundle_for_send (XmppStream stream,
            Jid jid, int device_id, Cancellable cancellable, bool build_session) {
        uint generation = stream_generation;
        if (!is_current_stream (stream, generation) || cancellable.is_cancelled () ||
                store.registration_pending || !store.is_persistence_ready) return false;
        if (build_session && has_legacy_session_for_send (jid, device_id)) return true;
        string request_key = jid.bare_jid.to_string () + @":$device_id";
        var promise = new Promise<bool> ();
        bool completed = false;
        bool demand_active = build_session;
        if (build_session) awaited_session_builds[request_key] = awaited_session_builds[request_key] + 1;
        ulong ready_handler = bundle_fetched.connect ((from, id, bundle) => {
            if (completed || id != device_id || !from.equals_bare (jid)) return;
            completed = true;
            promise.set_value (is_current_stream (stream, generation) &&
                    !cancellable.is_cancelled () &&
                    (!build_session || has_legacy_session_for_send (jid, device_id)));
        });
        ulong failed_handler = bundle_fetch_failed.connect ((from, id) => {
            if (completed || id != device_id || !from.equals_bare (jid)) return;
            completed = true;
            promise.set_value (false);
        });
        ulong denied_handler = bundle_access_denied.connect ((from, id, presence_required) => {
            if (completed || id != device_id || !from.equals_bare (jid)) return;
            completed = true;
            promise.set_value (false);
        });
        ulong cancelled_handler = cancellable.cancelled.connect (() => {
            if (completed) return;
            completed = true;
            if (demand_active) {
                demand_active = false;
                release_awaited_session_build (request_key, generation);
            }
            promise.set_value (false);
        });
        uint timeout = 0;
        timeout = Timeout.add_seconds (15, () => {
            timeout = 0;
            if (!completed) {
                completed = true;
                if (demand_active) {
                    demand_active = false;
                    release_awaited_session_build (request_key, generation);
                }
                promise.set_value (false);
            }
            return Source.REMOVE;
        });
        fetch_bundle_info (stream, jid, device_id, false);
        try {
            return yield promise.future.wait_async ();
        } catch (FutureError e) {
            return false;
        } finally {
            SignalHandler.disconnect (this, ready_handler);
            SignalHandler.disconnect (this, failed_handler);
            SignalHandler.disconnect (this, denied_handler);
            SignalHandler.disconnect (cancellable, cancelled_handler);
            if (timeout != 0) Source.remove (timeout);
            if (demand_active) release_awaited_session_build (request_key, generation);
        }
    }

    internal bool is_attached_stream (XmppStream stream) {
        return active_stream == stream;
    }

    // Recovery must validate the expected sender identity itself. In
    // particular it must not enter Manager's ordinary identity-change path.
    internal async Bundle? request_recovery_bundle (XmppStream stream, Jid jid, int device_id) {
        uint generation = stream_generation;
        if (!is_current_stream (stream, generation) || device_id <= 0) return null;
        LegacyBundlePayloadResult result = yield request_legacy_bundle_payload (
                stream, jid.bare_jid, @"$NODE_BUNDLES:$device_id");
        if (!is_current_stream (stream, generation) || result.request_failed || result.node == null) return null;
        var bundle = new Bundle ((!) result.node);
        return is_valid_legacy_bundle (bundle) ? bundle : null;
    }

    private async void fetch_bundle_async (XmppStream stream, Jid jid, int device_id, bool ignore_if_non_present, uint generation) {
        if (!is_current_stream(stream, generation)) return;
        LegacyBundlePayloadResult result = yield request_legacy_bundle_payload (stream, jid.bare_jid, @"$NODE_BUNDLES:$device_id");
        if (!is_current_stream(stream, generation)) return;
        if (result.request_failed) {
            debug ("OMEMO: bundle request failed for %s/%d: %s",
                jid.bare_jid.to_string (),
                device_id,
                describe_legacy_bundle_request_failure (result));
            string request_key = jid.bare_jid.to_string () + @":$device_id";
            active_bundle_requests.remove (request_key);
            if (result.is_access_denied ()) {
                // An authorization error cannot be repaired by dropping this
                // device or repeatedly querying it. Explicit retry may query
                // again after the contact/server permission has changed.
                requested_session_builds.remove (request_key);
                pending_transient_bundle_retries.remove (request_key);
                if (transient_bundle_retry_sources.has_key (request_key)) {
                    Source.remove (transient_bundle_retry_sources[request_key]);
                    transient_bundle_retry_sources.unset (request_key);
                }
                transient_bundle_retry_attempts.unset (request_key);
                bundle_access_denied (jid, device_id, result.presence_subscription_required);
                return;
            }
            schedule_transient_bundle_retry (stream, jid, device_id, ignore_if_non_present, generation);
            return;
        }
        on_other_bundle_result (stream, jid, device_id, result.item_id, result.node, ignore_if_non_present);
    }

    private void schedule_transient_bundle_retry (XmppStream stream, Jid jid, int device_id, bool ignore_if_non_present, uint generation) {
        string request_key = jid.bare_jid.to_string () + @":$device_id";
        int attempts = transient_bundle_retry_attempts.has_key (request_key)
            ? transient_bundle_retry_attempts[request_key] + 1 : 1;
        transient_bundle_retry_attempts[request_key] = attempts;
        uint delay = attempts == 1 ? 2 : attempts == 2 ? 5 : attempts == 3 ? 15 :
            attempts == 4 ? 30 : attempts == 5 ? 60 : 300;
        if (!pending_transient_bundle_retries.add (request_key)) return;
        debug ("OMEMO: transient bundle request retry for %s/%d in %u seconds (attempt %d)",
               jid.bare_jid.to_string (), device_id, delay, attempts);
        uint source_id = 0;
        source_id = Timeout.add_seconds (delay, () => {
            if (!is_current_stream (stream, generation) ||
                    !transient_bundle_retry_sources.has_key (request_key) ||
                    transient_bundle_retry_sources[request_key] != source_id) return Source.REMOVE;
            transient_bundle_retry_sources.unset (request_key);
            pending_transient_bundle_retries.remove (request_key);
            fetch_bundle (stream, jid, device_id, ignore_if_non_present, false);
            return Source.REMOVE;
        });
        transient_bundle_retry_sources[request_key] = source_id;
    }

    public void ignore_device (Jid jid, int32 device_id) {
        if (device_id <= 0) return;
        lock (device_ignore_time) {
            device_ignore_time[jid.bare_jid.to_string () + @":$device_id"] = new DateTime.now_utc ();
        }
    }

    public void unignore_device (Jid jid, int32 device_id) {
        if (device_id <= 0) return;
        lock (device_ignore_time) {
            device_ignore_time.unset (jid.bare_jid.to_string () + @":$device_id");
        }
    }

    public bool is_ignored_device (Jid jid, int32 device_id) {
        if (device_id <= 0) return true;
        lock (device_ignore_time) {
            string id = jid.bare_jid.to_string () + @":$device_id";
            if (device_ignore_time.has_key (id)) {
                return new DateTime.now_utc ().difference (device_ignore_time[id]) < IGNORE_TIME;
            }
        }
        return false;
    }

    public void clear_device_list (XmppStream stream) {
        stream.get_module<Pubsub.Module> (Pubsub.Module.IDENTITY).delete_node (stream, null, NODE_DEVICELIST);
    }

    private void on_other_bundle_result (XmppStream stream, Jid jid, int device_id, string? id, StanzaNode? node, bool ignore_if_non_present) {
        string request_key = jid.bare_jid.to_string () + @":$device_id";
        transient_bundle_retry_attempts.unset (request_key);
        if (node == null) {
            active_bundle_requests.remove (request_key);
            if (!ignore_if_non_present && pending_missing_bundle_retries.add (request_key)) {
                // Publishing a device list and its bundle is not atomic. Give
                // a newly advertised device one short grace period before it
                // is classified as unavailable.
                uint generation = stream_generation;
                debug ("OMEMO: bundle for %s/%d not present yet; retrying once",
                       jid.bare_jid.to_string (), device_id);
                Timeout.add_seconds (2, () => {
                    pending_missing_bundle_retries.remove (request_key);
                    if (is_current_stream (stream, generation)) {
                        fetch_bundle (stream, jid, device_id, true, false);
                    }
                    return Source.REMOVE;
                });
                return;
            }

            debug ("Ignoring device %s/%d: No bundle after retry", jid.bare_jid.to_string (), device_id);
            requested_session_builds.remove (request_key);
            stream.get_module<StreamModule> (IDENTITY).ignore_device (jid, device_id);
            bundle_fetch_failed (jid, device_id);
        } else {
            Bundle bundle = new Bundle (node);
            if (!is_valid_legacy_bundle (bundle)) {
                debug ("Ignoring device %s/%d: Bad OMEMO bundle", jid.bare_jid.to_string (), device_id);
                stream.get_module<StreamModule> (IDENTITY).ignore_device (jid, device_id);
                requested_session_builds.remove (request_key);
                bundle_fetch_failed (jid, device_id);
                stream.get_module<StreamModule> (IDENTITY).active_bundle_requests.remove (request_key);
                return;
            }
            stream.get_module<StreamModule> (IDENTITY).unignore_device (jid, device_id);
            // Never log key material (even public keys) in full; keep logs metadata-only.
            debug ("Received bundle for %s/%d (identity_key_present=%s)",
                jid.bare_jid.to_string (),
                device_id,
                (bundle.identity_key != null).to_string ());
            bool build_session = requested_session_builds.remove (request_key) ||
                    awaited_session_builds.has_key (request_key);
            // Release before callbacks: persisting metadata may resume a send
            // which needs to request a fresh bundle for its first ratchet.
            active_bundle_requests.remove (request_key);
            bundle_ready (jid, device_id, bundle, build_session);
            bundle_fetched (jid, device_id, bundle);
            return;
        }
        stream.get_module<StreamModule> (IDENTITY).active_bundle_requests.remove (request_key);
    }

    public static bool is_valid_legacy_bundle (Bundle bundle) {
        bool has_pre_key = false;
        foreach (Bundle.PreKey pre_key in bundle.pre_keys) {
            if (pre_key.key_id <= 0 || pre_key.key == null) return false;
            has_pre_key = true;
        }
        ECPublicKey? identity_key = bundle.identity_key;
        ECPublicKey? signed_pre_key = bundle.signed_pre_key;
        uint8[]? signed_pre_key_signature = bundle.signed_pre_key_signature;
        if (identity_key == null || bundle.signed_pre_key_id < 0 ||
                signed_pre_key == null || signed_pre_key_signature == null ||
                !has_pre_key) {
            return false;
        }

        // Manager may reset an existing ratchet after this gate. Authenticate
        // the bundle first so malformed PubSub data can never destroy the
        // previously valid identity/session state.
        try {
            return verify_signature ((!) identity_key,
                    ((!) signed_pre_key).serialize (),
                    (!) signed_pre_key_signature);
        } catch (Error e) {
            debug ("Rejecting OMEMO bundle with invalid signed pre-key: %s",
                    e.message);
            return false;
        }
    }

    public bool start_session (XmppStream stream, Jid jid, int32 device_id, Bundle bundle) {
        if (store.registration_pending) return false;
        bool fail = false;
        int32 signed_pre_key_id = bundle.signed_pre_key_id;
        ECPublicKey? signed_pre_key = bundle.signed_pre_key;
        uint8[]? signed_pre_key_signature = bundle.signed_pre_key_signature;
        ECPublicKey? identity_key = bundle.identity_key;

        ArrayList<Bundle.PreKey> pre_keys = bundle.pre_keys;
        if (signed_pre_key_id < 0 || signed_pre_key == null || signed_pre_key_signature == null || identity_key == null || pre_keys.size == 0) {
            fail = true;
        } else {
            int pre_key_idx = Random.int_range (0, pre_keys.size);
            int32 pre_key_id = pre_keys[pre_key_idx].key_id;
            ECPublicKey? pre_key = pre_keys[pre_key_idx].key;
            if (pre_key_id < 0 || pre_key == null) {
                fail = true;
            } else {
                Address address = new Address (jid.bare_jid.to_string (), device_id);
                try {
                    if (store.contains_session (address)) {
                        /* Check if this is a v4 session created by the OMEMO 2 module.
                         * The v1 encryptor uses cipher.version=0 (default) which
                         * breaks with v4 sessions → SG_ERR_LEGACY_MESSAGE.
                         * Replace v4 with a proper v3 session. */
                        SessionCipher probe = store.create_session_cipher (address);
                        uint32 sv = probe.get_session_version ();
                        if (sv >= 4) {
                            debug ("Replacing v%u session with v3 for %s/%d", sv, jid.bare_jid.to_string (), device_id);
                            store.delete_session (address);
                        } else {
                            // A compatible v3 session is already ready. This
                            // is success for callers waiting on bundle repair.
                            return true;
                        }
                    }
                    debug ("Starting new session for encryption with %s/%d", jid.bare_jid.to_string (), device_id);
                    SessionBuilder builder = store.create_session_builder (address);
                    builder.process_pre_key_bundle (create_pre_key_bundle (device_id, device_id, pre_key_id, pre_key, signed_pre_key_id, signed_pre_key, (!) signed_pre_key_signature, identity_key));
                } catch (Error e) {
                    debug ("Can't create session with %s/%d: %s", jid.bare_jid.to_string (), device_id, e.message);
                    fail = true;
                }
                address.device_id = 0; // Hack: Keeps 'address' alive while 'builder' is using it (SessionBuilder likely holds a reference to Address).
            }
        }
        if (fail) {
            debug ("Ignoring device %s/%d: Bad OMEMO bundle", jid.bare_jid.to_string (), device_id);
            stream.get_module<StreamModule> (IDENTITY).ignore_device (jid, device_id);
        }
        return !fail;
    }

    private void defer_own_bundle_device_list_loaded_after_success (Jid jid, ArrayList<int32>? device_list_loaded_after_success) {
        if (device_list_loaded_after_success == null) return;
        pending_own_bundle_device_list_loaded_jid = jid;
        pending_own_bundle_device_list_loaded_after_success = clone_device_list_for_signal ((!) device_list_loaded_after_success);
    }

    private void emit_own_bundle_device_list_loaded_after_success (Jid jid) {
        if (store.registration_pending) {
            try {
                if (registration_guard == null || !registration_candidate_verified) return;
                ((!) registration_guard).mark_published_checked ((int32) store.local_registration_id);
                store.registration_pending = false;
            } catch (Error e) {
                warning ("OMEMO: Failed to persist device registration completion: %s", e.message);
                release_own_bundle_device_list_loaded_after_failure (jid);
                return;
            }
        }
        release_pending_own_bundle_device_list_loaded (jid, true);
    }

    private void release_own_bundle_device_list_loaded_after_failure (Jid jid) {
        release_pending_own_bundle_device_list_loaded (jid, false);
    }

    private void release_pending_own_bundle_device_list_loaded (Jid jid, bool emit_loaded) {
        if (pending_own_bundle_device_list_loaded_jid == null || pending_own_bundle_device_list_loaded_after_success == null) return;
        if (!((!) pending_own_bundle_device_list_loaded_jid).equals_bare (jid)) return;

        Jid emit_jid = (!) pending_own_bundle_device_list_loaded_jid;
        ArrayList<int32> devices = (!) pending_own_bundle_device_list_loaded_after_success;
        pending_own_bundle_device_list_loaded_jid = null;
        pending_own_bundle_device_list_loaded_after_success = null;
        complete_pending_own_devicelist_readiness (devices);
        if (emit_loaded) {
            device_list_loaded (emit_jid, devices);
        }
    }

    public void publish_bundles_if_needed (XmppStream stream, Jid jid, ArrayList<int32>? device_list_loaded_after_success = null) {
        if (!is_attached_stream(stream) || !is_own_devicelist_jid(stream, jid)) return;
        if (store.registration_pending && !registration_candidate_verified) return;
        if (!store.is_persistence_ready) {
            debug("OMEMO: Own bundle publish deferred until the persistent store is ready");
            return;
        }
        defer_own_bundle_device_list_loaded_after_success (jid, device_list_loaded_after_success);
        DateTime now = new DateTime.now_utc();
        if (own_devicelist_publish_active || pending_own_devicelist_node != null) {
            debug ("OMEMO: own bundle publish waits for pending own device-list publish for %s", jid.bare_jid.to_string ());
            pending_own_devicelist_publish_bundle_after_success = true;
            return;
        }
        if (own_devicelist_publish_blocked_until != null && now.compare((!) own_devicelist_publish_blocked_until) < 0) {
            debug ("OMEMO: own bundle publish deferred after own device-list publish failure for %s", jid.bare_jid.to_string ());
            pending_own_devicelist_publish_bundle_after_success = true;
            schedule_own_devicelist_retry(stream, jid, get_retry_seconds_until((!) own_devicelist_publish_blocked_until, now));
            return;
        }
        if (own_bundle_publish_active) {
            debug ("OMEMO: own bundle publish already active for %s", jid.bare_jid.to_string ());
            return;
        }
        if (own_bundle_publish_blocked_until != null && now.compare((!) own_bundle_publish_blocked_until) < 0) {
            debug ("OMEMO: own bundle publish deferred after previous failure for %s", jid.bare_jid.to_string ());
            schedule_own_bundle_retry(stream, jid, get_retry_seconds_until((!) own_bundle_publish_blocked_until, now));
            release_own_bundle_device_list_loaded_after_failure (jid);
            return;
        }
        string request_key = jid.bare_jid.to_string () + @":$(store.local_registration_id)";
        var request_set = active_bundle_requests;
        if (request_set.add (request_key)) {
            fetch_self_bundle.begin (stream, jid, stream_generation,
                    request_set, request_key, store.pre_key_store,
                    store.local_registration_id);
        }
    }

    private async void fetch_self_bundle (XmppStream stream, Jid jid, uint generation,
            ConcurrentSet<string> request_set, string request_key,
            PreKeyStore key_store, uint32 device_id) {
        try {
            LegacyBundlePayloadResult result = yield request_legacy_bundle_payload (
                    stream, jid, @"$NODE_BUNDLES:$device_id");
            if (!is_current_own_bundle_store(stream, generation, key_store, device_id) ||
                    !is_own_devicelist_jid(stream, jid)) return;
            if (result.request_failed) {
                on_self_bundle_request_failed (stream, jid, result, generation);
                return;
            }
            yield on_self_bundle_result (stream, jid, result.item_id, result.node, generation);
        } finally {
            // A late response must not remove an identically named operation
            // from the replacement stream's newly allocated request set.
            request_set.remove(request_key);
            if (is_current_own_bundle_store(stream, generation, key_store, device_id)) {
                queue_own_bundle_refresh(stream, generation);
            }
        }
    }

    private async LegacyBundlePayloadResult request_legacy_bundle_payload (XmppStream stream, Jid jid, string node_id) {
        Pubsub.RequestAllResult result = yield stream.get_module<Pubsub.Module> (Pubsub.Module.IDENTITY).request_all_with_result (
            stream, jid, node_id, -1, Pubsub.RequestPurpose.STATE_SYNC);
        if (result.items == null) {
            if (result.is_item_not_found ()) {
                return new LegacyBundlePayloadResult (null, null, false, result.error_condition, result.error_text);
            }
            return new LegacyBundlePayloadResult (null, null, true, result.error_condition, result.error_text, result.presence_subscription_required);
        }

        if (result.items.size == 0) {
            return new LegacyBundlePayloadResult (null, null, false, result.error_condition, result.error_text);
        }

        string? item_id = null;
        StanzaNode? node = select_legacy_bundle_payload (result.items, out item_id);
        if (node == null) {
            return new LegacyBundlePayloadResult (item_id, null, false, null, "pubsub response missing legacy bundle payload");
        }
        return new LegacyBundlePayloadResult (item_id, node, false, result.error_condition, result.error_text);
    }

    private string describe_legacy_bundle_request_failure (LegacyBundlePayloadResult result) {
        if (result.error_condition != null && result.error_condition.length > 0) return (!) result.error_condition;
        if (result.error_text != null && result.error_text.length > 0) return (!) result.error_text;
        return "unknown";
    }

    private void on_self_bundle_request_failed (XmppStream stream, Jid jid, LegacyBundlePayloadResult result, uint generation) {
        if (!is_current_stream(stream, generation)) {
            return;
        }

        own_bundle_retry_attempts++;
        uint retry_delay = get_own_publish_retry_delay (own_bundle_retry_attempts);
        own_bundle_publish_blocked_until = new DateTime.now_utc ().add_seconds (retry_delay);
        debug ("OMEMO: own bundle request failed for %s: %s; retrying in %u seconds",
            jid.bare_jid.to_string (),
            describe_legacy_bundle_request_failure (result),
            retry_delay);
        schedule_own_bundle_retry (stream, jid, retry_delay);
        release_own_bundle_device_list_loaded_after_failure (jid);
    }

    private static bool uint8_arrays_equal (uint8[] first, uint8[] second) {
        if (first.length != second.length) return false;
        for (int i = 0; i < first.length; i++) {
            if (first[i] != second[i]) return false;
        }
        return true;
    }

    internal static StanzaNode? select_legacy_bundle_payload (Gee.List<StanzaNode>? items, out string? item_id) {
        item_id = null;
        if (items == null) return null;

        StanzaNode? fallback = null;
        string? fallback_id = null;
        StanzaNode? legacy_one = null;
        string? legacy_one_id = null;

        foreach (StanzaNode item in items) {
            if (item.sub_nodes.size == 0) continue;

            string? id = item.get_attribute ("id");
            if (id == null) id = item.get_attribute ("id", Pubsub.NS_URI);

            StanzaNode payload = item.sub_nodes[0];
            if (id == "current") {
                item_id = id;
                return payload;
            }
            if (id == "1" && legacy_one == null) {
                legacy_one = payload;
                legacy_one_id = id;
            }
            if (fallback == null) {
                fallback = payload;
                fallback_id = id;
            }
        }

        if (legacy_one != null) {
            item_id = legacy_one_id;
            return legacy_one;
        }
        item_id = fallback_id;
        return fallback;
    }

    private async void on_self_bundle_result (XmppStream stream, Jid jid, string? id, StanzaNode? node, uint generation) {
        if (!is_current_stream(stream, generation)) {
            return;
        }
        if (!Plugin.ensure_context ()) {
            defer_own_bundle_reconciliation(stream, jid);
            release_own_bundle_device_list_loaded_after_failure (jid);
            return;
        }
        if (!store.is_persistence_ready) {
            release_own_bundle_device_list_loaded_after_failure (jid);
            return;
        }
        Map<int, ECPublicKey> keys = new HashMap<int, ECPublicKey> ();
        ECPublicKey? identity_key = null;
        int32 signed_pre_key_id = -1;
        ECPublicKey? signed_pre_key = null;
        uint8[]? signed_pre_key_signature = null;
        SignedPreKeyRecord? signed_pre_key_record = null;
        bool changed = false;
        bool bundle_ready = false;
        uint32 published_max_pre_key_id = 0;
        uint64 snapshot_epoch = own_pre_key_consumption_epoch;
        PreKeyStore key_store = store.pre_key_store;
        uint32 device_id = store.local_registration_id;
        if (node == null) {
            identity_key = store.identity_key_pair.public;
            changed = true;
        } else {
            Bundle bundle = new Bundle (node);
            foreach (Bundle.PreKey prekey in bundle.pre_keys) {
                if (prekey.key_id > 0) {
                    published_max_pre_key_id = uint32.max(published_max_pre_key_id, (uint32) prekey.key_id);
                }
                ECPublicKey? key = prekey.key;
                if (key != null && prekey.key_id > 0) {
                    keys[prekey.key_id] = (!)key;
                } else {
                    changed = true;
                }
            }
            identity_key = bundle.identity_key;
            signed_pre_key_id = bundle.signed_pre_key_id;
            signed_pre_key = bundle.signed_pre_key;
            signed_pre_key_signature = bundle.signed_pre_key_signature;
        }

        try {
            // Validate IdentityKey
            if (identity_key == null || store.identity_key_pair.public.compare ((!)identity_key) != 0) {
                changed = true;
            }
            IdentityKeyPair identity_key_pair = store.identity_key_pair;
            uint32 observed_pre_key_id = 0;
            if (identity_key != null && identity_key_pair.public.compare((!) identity_key) == 0) {
                observed_pre_key_id = published_max_pre_key_id;
            }
            if (pending_own_bundle_node != null) {
                foreach (Bundle.PreKey pending_key in new Bundle(pending_own_bundle_node).pre_keys) {
                    if (pending_key.key_id > 0) observed_pre_key_id = uint32.max(observed_pre_key_id, (uint32) pending_key.key_id);
                }
            }
            BackedPreKeyStore? backed_keys = key_store as BackedPreKeyStore;
            if (backed_keys != null) ((!) backed_keys).observe_high_watermark(observed_pre_key_id);

            // Validate signedPreKeyRecord + ID + published signature.
            if (signed_pre_key_id != -1 && store.contains_signed_pre_key (signed_pre_key_id)) {
                signed_pre_key_record = store.load_signed_pre_key (signed_pre_key_id);
            }
            if (signed_pre_key == null ||
                    signed_pre_key_id == -1 ||
                    signed_pre_key_record == null ||
                    ((!)signed_pre_key_record).key_pair.public.compare ((!)signed_pre_key) != 0 ||
                    signed_pre_key_signature == null ||
                    !uint8_arrays_equal ((!)signed_pre_key_signature, ((!)signed_pre_key_record).signature)) {
                // Use sequential ID based on last stored key
                signed_pre_key_id = (int32)store.signed_pre_key_store.get_max_key_id () + 1;
                if (signed_pre_key_id <= 0) signed_pre_key_id = 1;

                signed_pre_key_record = Plugin.get_context ().generate_signed_pre_key (identity_key_pair, signed_pre_key_id);
                store.store_signed_pre_key ((!)signed_pre_key_record);
                changed = true;
            }

            // Validate PreKeys
            Set<PreKeyRecord> pre_key_records = new HashSet<PreKeyRecord> ();
            foreach (var entry in keys.entries) {
                if (entry.key <= 0 || !store.contains_pre_key (entry.key)) {
                    changed = true;
                    continue;
                }
                PreKeyRecord record = store.load_pre_key (entry.key);
                if (record.key_pair.public.compare (entry.value) == 0) {
                    pre_key_records.add (record);
                } else {
                    changed = true;
                }
            }
            int new_keys = NUM_KEYS_TO_PUBLISH - pre_key_records.size;
            if (new_keys > 0) {
                uint32 next_id;
                if (backed_keys != null) {
                    next_id = ((!) backed_keys).reserve_key_ids((uint) new_keys, observed_pre_key_id);
                } else {
                    // In-memory stores are used by native test/smoke fixtures.
                    int64 first = (int64) uint32.max(key_store.get_max_key_id(), observed_pre_key_id) + 1;
                    if (first <= 0xFFFFFF && first + new_keys - 1 >= 0xFFFFFF) first = 0x1000000;
                    if (first + new_keys - 1 > int.MAX) throw new IOError.INVALID_DATA("Own OMEMO pre-key IDs are exhausted");
                    next_id = (uint32) first;
                }

                Set<PreKeyRecord> new_records = Plugin.get_context ().generate_pre_keys (next_id, (uint)new_keys);
                pre_key_records.add_all (new_records);
                foreach (PreKeyRecord record in new_records) {
                    store.store_pre_key (record);
                }
                changed = true;
            }

            if (changed) {
                snapshot_epoch = own_pre_key_consumption_epoch;
                Pubsub.PublishResult result = yield publish_bundles_with_result (stream, (!)signed_pre_key_record, identity_key_pair, pre_key_records, (int32) store.local_registration_id, generation);
                if (!is_current_own_bundle_store(stream, generation, key_store, device_id)) {
                    return;
                }
                if (result.ok) {
                    own_bundle_publish_blocked_until = null;
                    own_bundle_retry_attempts = 0;
                    if (own_bundle_retry_timeout != 0) {
                        Source.remove(own_bundle_retry_timeout);
                        own_bundle_retry_timeout = 0;
                    }
                    bundle_ready = true;
                } else if (result is SupersededOwnBundleResult) {
                    discard_pending_own_bundle_snapshot();
                } else {
                    own_bundle_retry_attempts++;
                    uint retry_delay = get_own_publish_retry_delay_for_result(result, own_bundle_retry_attempts);
                    own_bundle_publish_blocked_until = new DateTime.now_utc().add_seconds(retry_delay);
                    log_own_publish_retry("bundle", pending_own_bundle_node_id ?? NODE_BUNDLES, result, retry_delay);
                    schedule_own_bundle_retry(stream, jid, retry_delay);
                    release_own_bundle_device_list_loaded_after_failure (jid);
                }
            } else {
                snapshot_epoch = own_pre_key_consumption_epoch;
                own_bundle_publish_blocked_until = null;
                own_bundle_retry_attempts = 0;
                if (own_bundle_retry_timeout != 0) {
                    Source.remove(own_bundle_retry_timeout);
                    own_bundle_retry_timeout = 0;
                }
                bundle_ready = true;
            }
        } catch (Error e) {
            warning (@"Unexpected error while publishing bundle: $(e.message)\n");
            defer_own_bundle_reconciliation(stream, jid);
            release_own_bundle_device_list_loaded_after_failure (jid);
        }
        if (bundle_ready) {
            own_bundle_reconciled_epoch = snapshot_epoch;
            emit_own_bundle_device_list_loaded_after_success (jid);
        }
    }

    private void defer_own_bundle_reconciliation(XmppStream stream, Jid jid) {
        own_bundle_retry_attempts++;
        uint retry_delay = get_own_publish_retry_delay(own_bundle_retry_attempts);
        own_bundle_publish_blocked_until = new DateTime.now_utc().add_seconds(retry_delay);
        schedule_own_bundle_retry(stream, jid, retry_delay);
    }

    private void schedule_own_bundle_retry(XmppStream stream, Jid jid, uint retry_delay) {
        if (own_bundle_retry_timeout != 0) return;
        uint generation = stream_generation;
        if (!is_current_stream(stream, generation)) return;
        own_bundle_retry_timeout = Timeout.add_seconds(retry_delay, () => {
            own_bundle_retry_timeout = 0;
            if (!is_current_stream(stream, generation)) return Source.REMOVE;
            own_bundle_publish_blocked_until = null;
            retry_pending_own_bundle_publish.begin(stream, jid, generation);
            return Source.REMOVE;
        });
    }

    internal async void retry_pending_own_bundle_publish(XmppStream stream, Jid jid, uint generation) {
        if (!is_current_stream(stream, generation) || !is_own_devicelist_jid(stream, jid)) return;
        // Normally invoked by the expired backoff timer. Keeping this callback
        // internal also permits deterministic native tests without real sleeps.
        if (own_bundle_retry_timeout != 0) {
            Source.remove(own_bundle_retry_timeout);
            own_bundle_retry_timeout = 0;
        }
        own_bundle_publish_blocked_until = null;
        if (pending_own_bundle_node == null || pending_own_bundle_node_id == null || pending_own_bundle_item_id == null) {
            publish_bundles_if_needed(stream, jid);
            return;
        }
        PreKeyStore key_store = store.pre_key_store;
        uint32 device_id = store.local_registration_id;
        uint64 snapshot_epoch = pending_own_bundle_epoch;
        Pubsub.PublishResult result = new Pubsub.PublishResult(false);
        try {
            if (own_pre_key_consumption_epoch != pending_own_bundle_epoch ||
                    !pending_own_bundle_matches_store((!) pending_own_bundle_node, device_id)) {
                discard_pending_own_bundle_snapshot();
                publish_bundles_if_needed(stream, jid);
                return;
            }
            own_bundle_publish_active = true;
            var operation = new OwnBundleOperation(stream, generation, store, jid);
            result = yield publish_own_bundle_node(stream, (!) pending_own_bundle_node_id, (!) pending_own_bundle_item_id,
                (!) pending_own_bundle_node, pending_own_bundle_retract_item_id, operation);
        } catch (Error e) {
            warning(@"Unexpected error while retrying bundle publish: $(e.message)\n");
        }
        if (!is_current_own_bundle_store(stream, generation, key_store, device_id)) return;
        own_bundle_publish_active = false;

        if (result.ok) {
            clear_pending_own_bundle_publish();
            own_bundle_reconciled_epoch = snapshot_epoch;
            emit_own_bundle_device_list_loaded_after_success (jid);
        } else if (result is SupersededOwnBundleResult) {
            discard_pending_own_bundle_snapshot();
        } else {
            own_bundle_retry_attempts++;
            uint retry_delay = get_own_publish_retry_delay_for_result(result, own_bundle_retry_attempts);
            own_bundle_publish_blocked_until = new DateTime.now_utc().add_seconds(retry_delay);
            log_own_publish_retry("bundle", pending_own_bundle_node_id ?? NODE_BUNDLES, result, retry_delay);
            schedule_own_bundle_retry(stream, jid, retry_delay);
            release_own_bundle_device_list_loaded_after_failure (jid);
        }
        queue_own_bundle_refresh(stream, generation);
    }

    private bool pending_own_bundle_matches_store(StanzaNode node, uint32 device_id) throws Error {
        store.require_persistence_ready();
        if (pending_own_bundle_node_id != @"$NODE_BUNDLES:$device_id") return false;
        var bundle = new Bundle(node);
        if (bundle.identity_key == null || store.identity_key_pair.public.compare(bundle.identity_key) != 0 ||
                bundle.signed_pre_key_id <= 0 || !store.contains_signed_pre_key(bundle.signed_pre_key_id)) return false;
        SignedPreKeyRecord signed_key = store.load_signed_pre_key(bundle.signed_pre_key_id);
        if (bundle.signed_pre_key == null || signed_key.key_pair.public.compare(bundle.signed_pre_key) != 0 ||
                bundle.signed_pre_key_signature == null ||
                !uint8_arrays_equal(signed_key.signature, bundle.signed_pre_key_signature)) return false;
        foreach (Bundle.PreKey pre_key in bundle.pre_keys) {
            if (pre_key.key_id <= 0 || pre_key.key == null || !store.contains_pre_key(pre_key.key_id) ||
                    store.load_pre_key(pre_key.key_id).key_pair.public.compare(pre_key.key) != 0) return false;
        }
        return true;
    }

    private void discard_pending_own_bundle_snapshot() {
        pending_own_bundle_node = null;
        pending_own_bundle_node_id = null;
        pending_own_bundle_item_id = null;
        pending_own_bundle_retract_item_id = null;
    }

    private void clear_pending_own_bundle_publish() {
        own_bundle_publish_blocked_until = null;
        own_bundle_retry_attempts = 0;
        discard_pending_own_bundle_snapshot();
        if (own_bundle_retry_timeout != 0) {
            Source.remove(own_bundle_retry_timeout);
            own_bundle_retry_timeout = 0;
        }
    }

    public async bool publish_bundles (XmppStream stream, SignedPreKeyRecord signed_pre_key_record, IdentityKeyPair identity_key_pair, Set<PreKeyRecord> pre_key_records, int32 device_id, uint expected_generation = 0) throws Error {
        Pubsub.PublishResult result = yield publish_bundles_with_result(stream, signed_pre_key_record, identity_key_pair, pre_key_records, device_id, expected_generation);
        return result.ok;
    }

    private async Pubsub.PublishResult publish_bundles_with_result (XmppStream stream, SignedPreKeyRecord signed_pre_key_record, IdentityKeyPair identity_key_pair, Set<PreKeyRecord> pre_key_records, int32 device_id, uint expected_generation = 0) throws Error {
        if (store.registration_pending && !registration_candidate_verified) return new Pubsub.PublishResult(false);
        uint generation = expected_generation == 0 ? stream_generation : expected_generation;
        Bind.Flag? bind = stream.get_flag<Bind.Flag>(Bind.Flag.IDENTITY);
        Jid? own_jid = bind != null ? ((!) bind).my_jid : null;
        if (own_jid == null || device_id != store.local_registration_id) return new Pubsub.PublishResult(false);
        var operation = new OwnBundleOperation(stream, generation, store, (!) own_jid);
        if (!is_current_own_bundle_operation(operation)) return new Pubsub.PublishResult(false);
        ECKeyPair tmp;
        StanzaNode bundle = new StanzaNode.build ("bundle", NS_URI)
                .add_self_xmlns ()
                .put_node (new StanzaNode.build ("signedPreKeyPublic", NS_URI)
                    .put_attribute ("signedPreKeyId", signed_pre_key_record.id.to_string ())
                    .put_node (new StanzaNode.text (Base64.encode ((tmp = signed_pre_key_record.key_pair).public.serialize ()))))
                .put_node (new StanzaNode.build ("signedPreKeySignature", NS_URI)
                    .put_node (new StanzaNode.text (Base64.encode (signed_pre_key_record.signature))))
                .put_node (new StanzaNode.build ("identityKey", NS_URI)
                    .put_node (new StanzaNode.text (Base64.encode (identity_key_pair.public.serialize ()))));
        StanzaNode prekeys = new StanzaNode.build ("prekeys", NS_URI);
        foreach (PreKeyRecord pre_key_record in pre_key_records) {
            prekeys.put_node (new StanzaNode.build ("preKeyPublic", NS_URI)
                    .put_attribute ("preKeyId", pre_key_record.id.to_string ())
                    .put_node (new StanzaNode.text (Base64.encode (pre_key_record.key_pair.public.serialize ()))));
        }
        bundle.put_node (prekeys);

        string node_id = @"$NODE_BUNDLES:$device_id";
        pending_own_bundle_node = bundle;
        pending_own_bundle_node_id = node_id;
        pending_own_bundle_item_id = "current";
        pending_own_bundle_retract_item_id = "1";
        pending_own_bundle_epoch = own_pre_key_consumption_epoch;
        own_bundle_publish_active = true;
        Pubsub.PublishResult result;
        try {
            result = yield publish_own_bundle_node(stream, node_id, "current", bundle, "1", operation);
        } catch (Error e) {
            if (is_current_own_bundle_operation(operation, true)) {
                own_bundle_publish_active = false;
            }
            throw e;
        }
        if (!is_current_own_bundle_operation(operation, true)) return new Pubsub.PublishResult(false);
        own_bundle_publish_active = false;
        if (result.ok) {
            clear_pending_own_bundle_publish();
        }
        return result;

    }

    private async Pubsub.PublishResult publish_own_bundle_node (XmppStream stream, string node_id, string item_id, StanzaNode bundle, string? retract_item_id, OwnBundleOperation operation) throws Error {
        var publish_options = new Pubsub.PublishOptions()
            .set_access_model (Pubsub.ACCESS_MODEL_OPEN)
            .set_max_items ("1")
            .set_persist_items (true);
        if (!is_current_own_bundle_operation(operation)) return new Pubsub.PublishResult(false);
        active_own_bundle_operation = operation;
        ulong ready_handler = store.persistence_readiness_changed.connect((ready) => {
            if (!ready) {
                operation.invalidated = true;
                operation.cancellable.cancel();
            }
        });
        ulong keys_handler = store.notify["pre-key-store"].connect(() => {
            operation.invalidated = true;
            operation.cancellable.cancel();
        });
        ulong identity_handler = store.notify["identity-key-store"].connect(() => {
            operation.invalidated = true;
            operation.cancellable.cancel();
        });
        ulong own_identity_handler = operation.identity_store.notify.connect(() => {
            operation.invalidated = true;
            operation.cancellable.cancel();
        });
        try {
            Pubsub.PublishResult? result = yield stream.get_module<Pubsub.Module> (Pubsub.Module.IDENTITY)
                    .publish_with_result_cancellable(stream, null, node_id, item_id, bundle,
                        publish_options, false, false, operation.cancellable);
            operation.awaiting_publish_ack = false;
            if (!is_current_own_bundle_operation(operation, true)) return new Pubsub.PublishResult(false);
            if (result == null) return new Pubsub.PublishResult(false, null, null, "Bundle publication cancelled");
            bool reconfigure = result.precondition_not_met ||
                    result.is_error(ErrorStanza.TYPE_CANCEL, ErrorStanza.CONDITION_CONFLICT);
            if (!result.ok && reconfigure) {
                // The initial write was explicitly rejected. A newer consumed
                // key snapshot now owns any retry; never replay the stale XML.
                if (operation.superseded) return new SupersededOwnBundleResult();
                bool configured = yield configure_own_bundle_for_retry(node_id,
                        publish_options, operation);
                if (!is_current_own_bundle_operation(operation, true)) return new Pubsub.PublishResult(false);
                if (operation.superseded) return new SupersededOwnBundleResult();
                if (configured) {
                    operation.awaiting_publish_ack = true;
                    result = yield stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY)
                            .publish_with_result_cancellable(stream, null, node_id,
                                item_id, bundle, publish_options, false, false,
                                operation.cancellable);
                    operation.awaiting_publish_ack = false;
                    if (!is_current_own_bundle_operation(operation, true)) return new Pubsub.PublishResult(false);
                    if (result == null) return new Pubsub.PublishResult(false, null, null, "Bundle publication cancelled");
                }
            }
            // An acknowledgement already obtained remains an acknowledgement
            // of this older snapshot; the dirty epoch still requires repair.
            if (operation.superseded || !is_current_own_bundle_operation(operation)) return result;
            if (result.ok) {
                if (retract_item_id != null) {
                    Pubsub.RetractResult retract_result = yield stream.get_module<Pubsub.Module> (Pubsub.Module.IDENTITY).retract_item_with_result_cancellable (
                            stream, null, node_id, (!) retract_item_id, false,
                            operation.cancellable);
                    if (!is_current_own_bundle_operation(operation)) return result;
                    if (!retract_result.ok && !retract_result.is_item_not_found ()) {
                        warning ("OMEMO: failed to retract legacy bundle item %s from node %s: %s",
                            (!) retract_item_id, node_id, retract_result.describe_error ());
                    }
                }
                yield try_make_own_bundle_public(node_id, operation);
            }
            return result;
        } finally {
            SignalHandler.disconnect(store, ready_handler);
            SignalHandler.disconnect(store, keys_handler);
            SignalHandler.disconnect(store, identity_handler);
            SignalHandler.disconnect(operation.identity_store, own_identity_handler);
            if (active_own_bundle_operation == operation) {
                active_own_bundle_operation = null;
                own_bundle_publish_active = false;
            }
        }
    }

    private async bool configure_own_bundle_for_retry(string node_id,
            Pubsub.PublishOptions publish_options, OwnBundleOperation operation) {
        if (!is_current_own_bundle_operation(operation) || operation.superseded) return false;
        var pubsub = operation.stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY);
        DataForms.DataForm? form = yield pubsub.request_node_config_with_cancellable(
                operation.stream, null, node_id, operation.cancellable);
        if (form == null || !is_current_own_bundle_operation(operation) || operation.superseded) return false;
        foreach (DataForms.DataForm.Field field in form.fields) {
            if (publish_options.settings.has_key(field.var) &&
                    publish_options.settings[field.var] != field.get_value_string()) {
                field.set_value_string(publish_options.settings[field.var]);
            }
        }
        bool result = yield pubsub.submit_node_config_with_cancellable(operation.stream,
                null, form, node_id, operation.cancellable);
        return result && is_current_own_bundle_operation(operation) && !operation.superseded;
    }

    private async void try_make_own_bundle_public(string node_id, OwnBundleOperation operation) {
        if (!is_current_own_bundle_operation(operation)) return;
        var pubsub = operation.stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY);
        DataForms.DataForm? data_form = yield pubsub.request_node_config_with_cancellable(
                operation.stream, null, node_id, operation.cancellable);
        if (data_form == null || !is_current_own_bundle_operation(operation)) return;
        foreach (DataForms.DataForm.Field field in data_form.fields) {
            if (field.var == "pubsub#access_model" && field.get_value_string() != Pubsub.ACCESS_MODEL_OPEN) {
                field.set_value_string(Pubsub.ACCESS_MODEL_OPEN);
                yield pubsub.submit_node_config_with_cancellable(operation.stream,
                        null, data_form, node_id, operation.cancellable);
                return;
            }
        }
    }

    private async void try_make_node_public (XmppStream stream, string node_id) {
        DataForms.DataForm? data_form = yield stream.get_module<Pubsub.Module> (Pubsub.Module.IDENTITY).request_node_config (stream, null, node_id);
        if (data_form == null) return;

        foreach (DataForms.DataForm.Field field in data_form.fields) {
            if (field.var == "pubsub#access_model" && field.get_value_string () != Pubsub.ACCESS_MODEL_OPEN) {
                field.set_value_string (Pubsub.ACCESS_MODEL_OPEN);
                yield stream.get_module<Pubsub.Module> (Pubsub.Module.IDENTITY).submit_node_config (stream, null, data_form, node_id);
            }
        }
    }
}

}
