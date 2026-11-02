using Gee;
using Xmpp;
using Xmpp.Xep;
using Omemo;

namespace Dino.Plugins.Omemo {

private const string NS_URI_V2 = Xmpp.Xep.Omemo.NS_URI_V2;
private const string NODE_DEVICELIST_V2 = Xmpp.Xep.Omemo.NODE_DEVICELIST_V2;
private const string NODE_BUNDLES_V2 = Xmpp.Xep.Omemo.NODE_BUNDLES_V2;

private const int NUM_KEYS_TO_PUBLISH_V2 = 100;

/**
 * OMEMO 2 stream module -- manages PEP interaction for device lists and bundles.
 *
 * Key differences from legacy StreamModule:
 * - Device list: urn:xmpp:omemo:2:devices (<devices><device id='...' label='...'/></devices>)
 * - Bundles: urn:xmpp:omemo:2:bundles (multi-item node, item_id = device_id)
 * - Bare 32-byte X25519 keys (no 0x05 prefix)
 * - Bundle XML: <spk>, <spks>, <ik>, <pk> elements
 */
private class OwnBundle2Context : Object {
    internal XmppStream stream;
    internal uint generation;
    internal PreKeyStore keys;
    internal SignedPreKeyStore signed_keys;
    internal IdentityKeyStore identity;
    internal string identity_public;
    internal uint32 device_id;
    internal Jid jid;
    internal bool automatic;

    internal OwnBundle2Context(XmppStream stream, uint generation, Store store, Jid jid,
            bool automatic = true) {
        this.stream = stream;
        this.generation = generation;
        keys = store.pre_key_store;
        signed_keys = store.signed_pre_key_store;
        identity = store.identity_key_store;
        identity_public = Base64.encode(identity.identity_key_public.get_data());
        device_id = store.local_registration_id;
        this.jid = jid.bare_jid;
        this.automatic = automatic;
    }
}

public class StreamModule2 : XmppStreamModule {
    public static Xmpp.ModuleIdentity<StreamModule2> IDENTITY = new Xmpp.ModuleIdentity<StreamModule2>(NS_URI_V2, "omemo2_module");
    private static TimeSpan IGNORE_TIME = TimeSpan.MINUTE;

    public Store store { public get; private set; }
    public string? own_device_label { get; set; default = null; }
    public bool auto_publish_own_device_list { get; set; default = true; }
    internal uint attachment_generation { get { return stream_generation; } }
    private ConcurrentSet<string> active_bundle_requests = new ConcurrentSet<string>();
    private HashMap<Jid, Future<ArrayList<int32>>> active_devicelist_requests = new HashMap<Jid, Future<ArrayList<int32>>>(Jid.hash_func, Jid.equals_func);
    private Map<string, DateTime> device_ignore_time = new HashMap<string, DateTime>();
    private XmppStream? active_stream = null;
    private uint stream_generation = 0;
    private bool own_devicelist_publish_active = false;
    private DateTime? own_devicelist_publish_blocked_until = null;
    private StanzaNode? pending_own_devicelist_node = null;
    private Jid? pending_own_devicelist_jid = null;
    private bool pending_own_devicelist_publish_bundle_after_success = false;
    private bool own_devicelist_publish_options_max_items_supported = true;
    private uint own_devicelist_retry_timeout = 0;
    private int own_devicelist_retry_attempts = 0;
    private bool own_bundle_publish_active = false;
    private DateTime? own_bundle_publish_blocked_until = null;
    private StanzaNode? pending_own_bundle_node = null;
    private string? pending_own_bundle_node_id = null;
    private string? pending_own_bundle_item_id = null;
    private uint own_bundle_retry_timeout = 0;
    private int own_bundle_retry_attempts = 0;
    private uint own_bundle_refresh_timeout = 0;
    private uint64 own_pre_key_consumption_epoch = 0;
    private uint64 own_bundle_reconciled_epoch = 0;
    private uint64 pending_own_bundle_epoch = 0;
    private OwnBundle2Context? refresh_context;
    private OwnBundle2Context? pending_own_bundle_context;
    private OwnBundle2Context? own_bundle_operation;


    public signal void device_list_loaded(Jid jid, ArrayList<int32> devices);
    public signal void device_label_received(Jid jid, int32 device_id, string label);
    public signal void bundle_fetched(Jid jid, int device_id, Bundle2 bundle);
    public signal void bundle_fetch_failed(Jid jid, int device_id);

    public StreamModule2(Store store) {
        this.store = store;
    }

    public override string get_id() { return IDENTITY.id; }
    public override string get_ns() { return IDENTITY.ns; }

    public override void attach(XmppStream stream) {
        if (active_stream != null && active_stream != stream) detach((!) active_stream);
        active_stream = stream;
        stream_generation++;
        stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).add_filtered_notification(stream, NODE_DEVICELIST_V2,
                (stream, jid, id, node) => parse_device_list(stream, jid, id, node), null, null);
        if (own_pre_key_consumption_epoch != own_bundle_reconciled_epoch) {
            Bind.Flag? bind = stream.get_flag(Bind.Flag.IDENTITY);
            Jid? own_jid = bind != null ? ((!) bind).my_jid : null;
            if (own_jid != null) {
                var context = new OwnBundle2Context(stream, stream_generation, store, (!) own_jid);
                prepare_own_bundle_context(context);
                queue_own_bundle_refresh();
            }
        }
    }

    public override void detach(XmppStream stream) {
        stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).remove_filtered_notification(stream, NODE_DEVICELIST_V2);
        if (active_stream != stream) return;
        active_stream = null;
        stream_generation++;
        if (own_bundle_refresh_timeout != 0) {
            Source.remove(own_bundle_refresh_timeout);
            own_bundle_refresh_timeout = 0;
        }
        // Keep the immutable key owner for dirty-state transfer on reconnect.
        active_devicelist_requests.clear();
        active_bundle_requests = new ConcurrentSet<string>();
        if (own_devicelist_retry_timeout != 0) {
            Source.remove(own_devicelist_retry_timeout);
            own_devicelist_retry_timeout = 0;
        }
        if (own_bundle_retry_timeout != 0) {
            Source.remove(own_bundle_retry_timeout);
            own_bundle_retry_timeout = 0;
        }
        own_devicelist_publish_active = false;
        own_devicelist_publish_blocked_until = null;
        pending_own_devicelist_node = null;
        pending_own_devicelist_jid = null;
        pending_own_devicelist_publish_bundle_after_success = false;
        own_bundle_publish_active = false;
        own_bundle_publish_blocked_until = null;
        pending_own_bundle_node = null;
        pending_own_bundle_node_id = null;
        pending_own_bundle_item_id = null;
        pending_own_bundle_context = null;
        own_bundle_operation = null;
        own_devicelist_retry_attempts = 0;
        own_bundle_retry_attempts = 0;
    }

    public async ArrayList<int32> request_user_devicelist(XmppStream stream, Jid jid) {
        if (jid.localpart == null) {
            debug("OMEMO 2: Not requesting device list for domain JID %s", jid.to_string());
            return new ArrayList<int32>();
        }
        var future = active_devicelist_requests[jid];
        if (future == null) {
            var promise = new Promise<ArrayList<int32>?>();
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
            return yield future.wait_async();
        } catch (FutureError error) {
            if (active_devicelist_requests[jid] == future) active_devicelist_requests.unset(jid);
            warning("OMEMO 2: Future error when waiting for device list: %s", error.message);
            return new ArrayList<int32>();
        }
    }

    private async ArrayList<int32> request_user_devicelist_uncached(XmppStream stream, Jid jid, uint generation) {
        if (!is_current_stream(stream, generation)) return new ArrayList<int32>();
        string? item_id = null;
        Pubsub.RequestAllResult result = yield stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).request_all_with_result(
            stream, jid, NODE_DEVICELIST_V2, -1, Pubsub.RequestPurpose.STATE_SYNC);
        Gee.List<StanzaNode>? items = result.items;
        if (!is_current_stream(stream, generation)) return new ArrayList<int32>();
        if (result.is_item_not_found()) {
            Jid? my_jid = stream.get_flag(Bind.Flag.IDENTITY).my_jid;
            if (auto_publish_own_device_list && my_jid != null && jid.equals_bare((!) my_jid)) {
                debug("OMEMO 2: device list for own JID %s is missing; bootstrapping publish using empty list", jid.bare_jid.to_string());
                return parse_device_list(stream, jid, null, null);
            }
            return new ArrayList<int32>();
        }
        if (items == null) {
            return new ArrayList<int32>();
        }
        StanzaNode? node = select_first_payload(items, out item_id);
        return parse_device_list(stream, jid, item_id, node);
    }

    /**
     * Parse OMEMO 2 device list:
     * <devices xmlns='urn:xmpp:omemo:2'>
     *   <device id='12345' label='Phone'/>
     * </devices>
     */
    public ArrayList<int32> parse_device_list(XmppStream stream, Jid jid, string? id, StanzaNode? node_) {
        ArrayList<int32> device_list = new ArrayList<int32>();
        if (active_stream != stream) return device_list;
        HashMap<int32, string> device_labels = new HashMap<int32, string>();

        StanzaNode node = node_ ?? new StanzaNode.build("devices", NS_URI_V2).add_self_xmlns();
        Jid? my_jid = stream.get_flag(Bind.Flag.IDENTITY).my_jid;
        if (my_jid == null) return device_list;
        foreach (StanzaNode device_node in node.get_subnodes("device")) {
            int32 did = device_node.get_attribute_int("id");
            if (did <= 0) continue;
            if (!device_list.contains(did)) {
                device_list.add(did);
            }
            string? label = device_node.get_attribute("label");
            if (label != null && label.length > 0) {
                device_labels[did] = (!)label;
                device_label_received(jid, did, (!)label);
            }
        }

        if (auto_publish_own_device_list && jid.equals_bare(my_jid) && store.local_registration_id != 0) {
            bool am_on_devicelist = device_list.contains((int32)store.local_registration_id);
            if (am_on_devicelist) {
                if (pending_own_devicelist_node == null) {
                    own_devicelist_publish_blocked_until = null;
                    own_devicelist_retry_attempts = 0;
                    if (own_devicelist_retry_timeout != 0) {
                        Source.remove(own_devicelist_retry_timeout);
                        own_devicelist_retry_timeout = 0;
                    }
                }
                publish_bundles_if_needed(stream, jid);
            } else {
                debug("OMEMO 2: Not on device list, adding id %u", store.local_registration_id);
                device_list.add((int32)store.local_registration_id);
                if (own_device_label != null && own_device_label.length > 0) {
                    device_labels[(int32)store.local_registration_id] = (!)own_device_label;
                }
                publish_own_devicelist(stream, jid, device_list, device_labels, true);
            }
        }

        device_list_loaded(jid, device_list);

        return device_list;
    }

    internal void publish_own_devicelist(XmppStream stream, Jid jid, Gee.List<int32> devices, Map<int32, string>? labels = null, bool publish_bundle_after_success = false) {
        publish_own_devicelist_if_allowed(stream, jid, NODE_DEVICELIST_V2, build_devicelist_node(devices, labels), create_devicelist_publish_options(), publish_bundle_after_success);
    }

    private Pubsub.PublishOptions create_devicelist_publish_options() {
        Pubsub.PublishOptions options = new Pubsub.PublishOptions()
            .set_access_model(Pubsub.ACCESS_MODEL_OPEN)
            .set_persist_items(true);
        if (own_devicelist_publish_options_max_items_supported) {
            options.set_max_items("1");
        }
        return options;
    }

    private StanzaNode build_devicelist_node(Gee.List<int32> devices, Map<int32, string>? labels = null) {
        StanzaNode devices_node = new StanzaNode.build("devices", NS_URI_V2).add_self_xmlns();
        foreach (int32 device_id in devices) {
            var device_node = new StanzaNode.build("device", NS_URI_V2)
                .put_attribute("id", device_id.to_string());
            if (labels != null && ((!)labels).has_key(device_id)) {
                device_node.put_attribute("label", ((!)labels)[device_id]);
            } else if (device_id == (int32)store.local_registration_id && own_device_label != null && own_device_label.length > 0) {
                device_node.put_attribute("label", (!)own_device_label);
            }
            devices_node.put_node(device_node);
        }
        return devices_node;
    }

    private StanzaNode? select_first_payload(Gee.List<StanzaNode>? items, out string? item_id) {
        item_id = null;
        if (items == null) return null;
        StanzaNode? fallback = null;
        string? fallback_id = null;
        foreach (StanzaNode item in items) {
            if (item.sub_nodes.size == 0) continue;
            string? id = item.get_attribute("id") ?? item.get_attribute("id", Pubsub.NS_URI);
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

    private bool is_current_stream(XmppStream stream, uint generation) {
        return active_stream == stream && stream_generation == generation;
    }

    private void publish_own_devicelist_if_allowed(XmppStream stream, Jid jid, string node_id, StanzaNode node, Pubsub.PublishOptions publish_options, bool publish_bundle_after_success = false) {
        uint generation = stream_generation;
        if (!is_current_stream(stream, generation)) return;
        DateTime now = new DateTime.now_utc();
        if (own_devicelist_publish_active) {
            debug("OMEMO 2: own device-list publish already active for %s", jid.bare_jid.to_string());
            pending_own_devicelist_node = node;
            pending_own_devicelist_jid = jid;
            pending_own_devicelist_publish_bundle_after_success = pending_own_devicelist_publish_bundle_after_success || publish_bundle_after_success;
            return;
        }
        if (own_devicelist_publish_blocked_until != null && now.compare((!) own_devicelist_publish_blocked_until) < 0) {
            debug("OMEMO 2: own device-list publish deferred after previous failure for %s", jid.bare_jid.to_string());
            pending_own_devicelist_node = node;
            pending_own_devicelist_jid = jid;
            pending_own_devicelist_publish_bundle_after_success = pending_own_devicelist_publish_bundle_after_success || publish_bundle_after_success;
            schedule_own_devicelist_retry(stream, jid, get_retry_seconds_until((!) own_devicelist_publish_blocked_until, now));
            return;
        }

        own_devicelist_publish_active = true;
        Jid? publish_jid = get_own_pep_publish_jid(stream, jid);
        stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).publish_with_result.begin(stream, publish_jid, node_id, "current", node, publish_options, true, false, (obj, res) => {
            if (!is_current_stream(stream, generation)) return;
            Pubsub.PublishResult result = stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).publish_with_result.end(res);
            own_devicelist_publish_active = false;
            if (result.ok) {
                own_devicelist_publish_blocked_until = null;
                own_devicelist_retry_attempts = 0;
                if (own_devicelist_retry_timeout != 0) {
                    Source.remove(own_devicelist_retry_timeout);
                    own_devicelist_retry_timeout = 0;
                }
                // Device list node: max_items=1 (only latest list matters)
                try_make_node_public.begin(stream, node_id, "1");
                StanzaNode? next_node = pending_own_devicelist_node;
                Jid? next_jid = pending_own_devicelist_jid;
                bool next_publish_bundle_after_success = pending_own_devicelist_publish_bundle_after_success || publish_bundle_after_success;
                pending_own_devicelist_node = null;
                pending_own_devicelist_jid = null;
                pending_own_devicelist_publish_bundle_after_success = false;
                if (next_node != null && next_jid != null) {
                    publish_own_devicelist_if_allowed(stream, (!)next_jid, node_id, (!)next_node, create_devicelist_publish_options(), next_publish_bundle_after_success);
                } else if (next_publish_bundle_after_success) {
                    publish_bundles_if_needed(stream, jid);
                }
            } else {
                if (own_devicelist_publish_options_max_items_supported && result_is_unknown_publish_option(result, "pubsub#max_items")) {
                    own_devicelist_publish_options_max_items_supported = false;
                    debug("OMEMO 2: server rejected pubsub#max_items in device-list publish-options; retrying without that field");
                    publish_own_devicelist_if_allowed(stream, jid, node_id, node, create_devicelist_publish_options(), publish_bundle_after_success);
                    return;
                }
                pending_own_devicelist_node = node;
                pending_own_devicelist_jid = jid;
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
        if (my_jid != null && jid.equals_bare((!)my_jid)) return null;
        return jid;
    }

    private bool result_is_unknown_publish_option(Pubsub.PublishResult result, string field_name) {
        if (result.ok || result.error_text == null) return false;
        string text = (!)result.error_text;
        return text.contains(@"Unknown field '$field_name'") && text.contains("publish-options");
    }

    internal static uint get_own_publish_retry_delay_for_error(string? error_type, string? error_condition, int attempts) {
        return StreamModule.get_own_publish_retry_delay_for_error(error_type, error_condition, attempts);
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
            warning("OMEMO 2: server deferred own %s PubSub publish for node %s with wait/resource-constraint; retrying in %u seconds",
                target, node_id, retry_delay);
            return;
        }
        string detail = result != null ? ((!) result).describe_error() : "unknown";
        warning("OMEMO 2: own %s PubSub publish failed for node %s: %s; retrying in %u seconds",
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
            bool publish_bundle_after_success = pending_own_devicelist_publish_bundle_after_success;
            pending_own_devicelist_node = null;
            pending_own_devicelist_jid = null;
            pending_own_devicelist_publish_bundle_after_success = false;
            if (next_node != null && next_jid != null) {
                publish_own_devicelist_if_allowed(stream, (!)next_jid, NODE_DEVICELIST_V2, (!)next_node, create_devicelist_publish_options(), publish_bundle_after_success);
            } else {
                request_user_devicelist.begin(stream, jid);
            }
            return Source.REMOVE;
        });
    }

    public void fetch_bundles(XmppStream stream, Jid jid, Gee.List<int32> devices) {
        Address address = new Address(jid.bare_jid.to_string(), 0);
        foreach (int32 device_id in devices) {
            if (!is_ignored_device(jid, device_id)) {
                address.device_id = device_id;
                try {
                    if (!store.contains_session(address)) {
                        fetch_bundle(stream, jid, device_id);
                    }
                } catch (Error e) {
                    // Ignore
                }
            }
        }
        address.device_id = 0;
    }

    /**
     * Fetch bundle from multi-item PEP node.
     * OMEMO 2: single node urn:xmpp:omemo:2:bundles, item_id = device_id.
     */
    public void fetch_bundle(XmppStream stream, Jid jid, int device_id, bool ignore_if_non_present = true) {
        uint generation = stream_generation;
        if (!is_current_stream(stream, generation)) return;
        if (active_bundle_requests.add(jid.bare_jid.to_string() + @":v2:$device_id")) {
            debug("OMEMO 2: Asking for bundle for %s/%d", jid.bare_jid.to_string(), device_id);
            /* Use request_item for multi-item PEP node */
            fetch_bundle_async.begin(stream, jid, device_id, ignore_if_non_present, generation);
        }
    }

    public void reset_bundle_request(Jid jid, int device_id) {
        active_bundle_requests.remove(jid.bare_jid.to_string() + @":v2:$device_id");
    }

    private async void fetch_bundle_async(XmppStream stream, Jid jid, int device_id, bool ignore_if_non_present, uint generation) {
        ConcurrentSet<string> requests = active_bundle_requests;
        string key = jid.bare_jid.to_string() + @":v2:$device_id";
        try {
            if (!is_current_stream(stream, generation)) return;
            StanzaNode? bundle_node = yield stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY)
                .request_item(stream, jid.bare_jid, NODE_BUNDLES_V2, device_id.to_string(), Pubsub.RequestPurpose.STATE_SYNC);
            if (!is_current_stream(stream, generation)) return;
            on_other_bundle_result(stream, jid, device_id, bundle_node, ignore_if_non_present);
        } finally {
            requests.remove(key);
        }
    }

    public void ignore_device(Jid jid, int32 device_id) {
        if (device_id <= 0) return;
        lock (device_ignore_time) {
            device_ignore_time[jid.bare_jid.to_string() + @":v2:$device_id"] = new DateTime.now_utc();
        }
    }

    public void unignore_device(Jid jid, int32 device_id) {
        if (device_id <= 0) return;
        lock (device_ignore_time) {
            device_ignore_time.unset(jid.bare_jid.to_string() + @":v2:$device_id");
        }
    }

    public bool is_ignored_device(Jid jid, int32 device_id) {
        if (device_id <= 0) return true;
        lock (device_ignore_time) {
            string id = jid.bare_jid.to_string() + @":v2:$device_id";
            if (device_ignore_time.has_key(id)) {
                return new DateTime.now_utc().difference(device_ignore_time[id]) < IGNORE_TIME;
            }
        }
        return false;
    }

    public void clear_device_list(XmppStream stream) {
        stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).delete_node(stream, null, NODE_DEVICELIST_V2);
    }

    private void on_other_bundle_result(XmppStream stream, Jid jid, int device_id, StanzaNode? node, bool ignore_if_non_present) {
        if (node == null) {
            if (ignore_if_non_present) {
                debug("OMEMO 2: Ignoring device %s/%d: No bundle", jid.bare_jid.to_string(), device_id);
                ignore_device(jid, device_id);
            }
            bundle_fetch_failed(jid, device_id);
        } else {
            Bundle2 bundle = new Bundle2(node);
            if (!is_valid_omemo2_bundle(bundle)) {
                debug("OMEMO 2: Ignoring device %s/%d: Bad bundle signature",
                    jid.bare_jid.to_string(), device_id);
                ignore_device(jid, device_id);
                bundle_fetch_failed(jid, device_id);
                return;
            }
            unignore_device(jid, device_id);
            debug("OMEMO 2: Received bundle for %s/%d (identity_key_present=%s)",
                jid.bare_jid.to_string(),
                device_id,
                (bundle.identity_key != null).to_string());
            bundle_fetched(jid, device_id, bundle);
        }
    }

    public static bool is_valid_omemo2_bundle(Bundle2 bundle) {
        bool has_pre_key = false;
        foreach (Bundle2.PreKey2 pre_key in bundle.pre_keys) {
            if (pre_key.key_id <= 0 || pre_key.key == null) return false;
            has_pre_key = true;
        }
        ECPublicKey? identity_key = bundle.identity_key;
        ECPublicKey? signed_pre_key = bundle.signed_pre_key;
        uint8[]? signed_pre_key_signature = bundle.signed_pre_key_signature;
        if (identity_key == null || bundle.signed_pre_key_id <= 0 ||
                signed_pre_key == null || signed_pre_key_signature == null ||
                !has_pre_key) {
            return false;
        }

        try {
            return verify_signature((!) identity_key,
                    ((!) signed_pre_key).serialize_omemo(),
                    (!) signed_pre_key_signature);
        } catch (Error e) {
            debug("OMEMO 2: Rejecting bundle with invalid signed pre-key: %s",
                    e.message);
            return false;
        }
    }

    public bool start_session(XmppStream stream, Jid jid, int32 device_id, Bundle2 bundle) {
        bool fail = false;
        int32 signed_pre_key_id = bundle.signed_pre_key_id;
        ECPublicKey? signed_pre_key = bundle.signed_pre_key;
        uint8[]? signed_pre_key_signature = bundle.signed_pre_key_signature;
        ECPublicKey? identity_key = bundle.identity_key;

        ArrayList<Bundle2.PreKey2> pre_keys = bundle.pre_keys;
        if (signed_pre_key_id < 0 || signed_pre_key == null || signed_pre_key_signature == null || identity_key == null || pre_keys.size == 0) {
            fail = true;
        } else {
            int pre_key_idx = Random.int_range(0, pre_keys.size);
            int32 pre_key_id = pre_keys[pre_key_idx].key_id;
            ECPublicKey? pre_key = pre_keys[pre_key_idx].key;
            if (pre_key_id < 0 || pre_key == null) {
                fail = true;
            } else {
                Address address = new Address(jid.bare_jid.to_string(), device_id);
                try {
                    if (store.contains_session(address)) {
                        return true;
                    }
                    debug("OMEMO 2: Starting new session with %s/%d", jid.bare_jid.to_string(), device_id);
                    SessionBuilder builder = store.create_session_builder(address);
                    builder.version = 4; // OMEMO 2: verify signature on bare 32-byte key
                    builder.process_pre_key_bundle(create_pre_key_bundle(device_id, device_id, pre_key_id, pre_key, signed_pre_key_id, signed_pre_key, signed_pre_key_signature, identity_key));
                } catch (Error e) {
                    debug("OMEMO 2: Can't create session with %s/%d: %s", jid.bare_jid.to_string(), device_id, e.message);
                    fail = true;
                }
                address.device_id = 0;
            }
        }
        if (fail) {
            debug("OMEMO 2: Ignoring device %s/%d: Bad bundle", jid.bare_jid.to_string(), device_id);
            ignore_device(jid, device_id);
        }
        return !fail;
    }

    public void publish_bundles_if_needed(XmppStream stream, Jid jid) {
        var context = new OwnBundle2Context(stream, stream_generation, store, jid);
        if (!is_current_own_bundle_context(context)) return;
        prepare_own_bundle_context(context);
        if (!store.is_persistence_ready) {
            debug("OMEMO 2: Own bundle publish deferred until the persistent store is ready");
            return;
        }
        string key = jid.bare_jid.to_string() + @":v2:$(store.local_registration_id)";
        DateTime now = new DateTime.now_utc();
        if (own_devicelist_publish_active || pending_own_devicelist_node != null) {
            debug("OMEMO 2: own bundle publish waits for pending own device-list publish for %s", jid.bare_jid.to_string());
            pending_own_devicelist_publish_bundle_after_success = true;
            return;
        }
        if (own_devicelist_publish_blocked_until != null && now.compare((!)own_devicelist_publish_blocked_until) < 0) {
            debug("OMEMO 2: own bundle publish deferred after own device-list publish failure for %s", jid.bare_jid.to_string());
            pending_own_devicelist_publish_bundle_after_success = true;
            schedule_own_devicelist_retry(stream, jid, get_retry_seconds_until((!)own_devicelist_publish_blocked_until, now));
            return;
        }
        if (own_bundle_publish_active) {
            debug("OMEMO 2: own bundle publish already active for %s", jid.bare_jid.to_string());
            return;
        }
        if (own_bundle_publish_blocked_until != null && now.compare((!) own_bundle_publish_blocked_until) < 0) {
            debug("OMEMO 2: own bundle publish deferred after previous failure for %s", jid.bare_jid.to_string());
            schedule_own_bundle_retry(stream, jid, get_retry_seconds_until((!) own_bundle_publish_blocked_until, now));
            return;
        }
        debug("OMEMO 2: publish_bundles_if_needed called for %s, key=%s", jid.bare_jid.to_string(), key);
        if (active_bundle_requests.add(key)) {
            debug("OMEMO 2: Starting fetch_self_bundle for %s", jid.bare_jid.to_string());
            /* For OMEMO 2, fetch our own bundle from multi-item node */
            fetch_self_bundle.begin(stream, jid, stream_generation);
        } else {
            debug("OMEMO 2: Bundle request already active for %s", jid.bare_jid.to_string());
        }
    }

    private bool is_current_own_bundle_context(OwnBundle2Context context) {
        Bind.Flag? bind = context.stream.get_flag(Bind.Flag.IDENTITY);
        Jid? own_jid = bind != null ? ((!) bind).my_jid : null;
        return (!context.automatic || auto_publish_own_device_list) &&
            is_current_stream(context.stream, context.generation) &&
            store.is_persistence_ready && !store.registration_pending &&
            store.pre_key_store == context.keys && store.signed_pre_key_store == context.signed_keys &&
            store.identity_key_store == context.identity &&
            Base64.encode(store.identity_key_store.identity_key_public.get_data()) == context.identity_public &&
            store.local_registration_id == context.device_id && context.device_id != 0 &&
            own_jid != null && context.jid.equals_bare((!) own_jid);
    }

    private bool same_own_material(OwnBundle2Context first, OwnBundle2Context second) {
        return first.keys == second.keys && first.signed_keys == second.signed_keys &&
            first.identity == second.identity &&
            first.device_id == second.device_id && first.identity_public == second.identity_public &&
            first.jid.equals_bare(second.jid);
    }

    private void prepare_own_bundle_context(OwnBundle2Context context) {
        if (refresh_context != null && !same_own_material((!) refresh_context, context)) {
            if (own_bundle_refresh_timeout != 0) {
                Source.remove(own_bundle_refresh_timeout);
                own_bundle_refresh_timeout = 0;
            }
            clear_pending_own_bundle_publish();
            own_bundle_operation = null;
            own_bundle_publish_active = false;
            active_bundle_requests = new ConcurrentSet<string>();
            own_pre_key_consumption_epoch = own_bundle_reconciled_epoch = 0;
        }
        refresh_context = context;
    }

    internal void on_omemo2_pre_key_consumed(XmppStream stream) {
        Bind.Flag? bind = stream.get_flag(Bind.Flag.IDENTITY);
        Jid? own_jid = bind != null ? ((!) bind).my_jid : null;
        if (own_jid == null) return;
        var context = new OwnBundle2Context(stream, stream_generation, store, (!) own_jid);
        if (!is_current_own_bundle_context(context)) return;
        prepare_own_bundle_context(context);
        own_pre_key_consumption_epoch++;
        queue_own_bundle_refresh();
    }

    private void queue_own_bundle_refresh() {
        if (!auto_publish_own_device_list || own_bundle_refresh_timeout != 0 || refresh_context == null ||
                own_pre_key_consumption_epoch == own_bundle_reconciled_epoch ||
                !is_current_own_bundle_context((!) refresh_context)) return;
        DateTime now = new DateTime.now_utc();
        if ((own_bundle_publish_blocked_until != null &&
                    now.compare((!) own_bundle_publish_blocked_until) < 0) ||
                (own_devicelist_publish_blocked_until != null &&
                    now.compare((!) own_devicelist_publish_blocked_until) < 0)) return;
        OwnBundle2Context context = (!) refresh_context;
        uint source_id = 0;
        source_id = Timeout.add(200, () => {
            if (own_bundle_refresh_timeout != source_id) return Source.REMOVE;
            own_bundle_refresh_timeout = 0;
            if (is_current_own_bundle_context(context)) {
                publish_bundles_if_needed(context.stream, context.jid);
            }
            return Source.REMOVE;
        });
        own_bundle_refresh_timeout = source_id;
    }

    // Distinguish confirmed missing own items from transport/server failures.
    // A request error must not be interpreted as an empty bundle and publish.
    private async StanzaNode? request_self_bundle_checked(OwnBundle2Context context) throws Error {
        var items = new StanzaNode.build("items", Pubsub.NS_URI)
            .put_attribute("node", NODE_BUNDLES_V2)
            .put_node(new StanzaNode.build("item", Pubsub.NS_URI)
                .put_attribute("id", context.device_id.to_string()));
        var request = new Iq.Stanza.get(new StanzaNode.build("pubsub", Pubsub.NS_URI)
            .add_self_xmlns().put_node(items)) { to = context.jid };
        Iq.Stanza response = yield context.stream.get_module<Iq.Module>(Iq.Module.IDENTITY)
            .send_iq_async(context.stream, request);
        if (response.is_error()) {
            ErrorStanza? error = response.get_error();
            if (error != null && ((!) error).condition == ErrorStanza.CONDITION_ITEM_NOT_FOUND) return null;
            throw new IOError.FAILED("OMEMO 2 own bundle lookup failed");
        }
        StanzaNode? result = response.stanza.get_deep_subnode(
            Pubsub.NS_URI + ":pubsub", Pubsub.NS_URI + ":items");
        if (result == null || ((!) result).get_attribute("node") != NODE_BUNDLES_V2) {
            throw new IOError.INVALID_DATA("OMEMO 2 own bundle lookup has an unexpected node");
        }
        Gee.List<StanzaNode> entries = ((!) result).get_subnodes("item", Pubsub.NS_URI);
        if (entries.size == 0) return null;
        if (entries.size != 1 || entries[0].get_attribute("id") != context.device_id.to_string() ||
                entries[0].get_subnodes("bundle", NS_URI_V2).size != 1) {
            throw new IOError.INVALID_DATA("OMEMO 2 own bundle lookup has an unexpected item");
        }
        return entries[0].get_subnode("bundle", NS_URI_V2);
    }

    private async void fetch_self_bundle(XmppStream stream, Jid jid, uint generation) {
        var context = new OwnBundle2Context(stream, generation, store, jid);
        ConcurrentSet<string> requests = active_bundle_requests;
        string key = jid.bare_jid.to_string() + @":v2:$(context.device_id)";
        try {
            if (!is_current_own_bundle_context(context)) return;
            StanzaNode? node = yield request_self_bundle_checked(context);
            if (!is_current_own_bundle_context(context)) return;
            yield on_self_bundle_result(context, node);
        } catch (Error error) {
            if (is_current_own_bundle_context(context)) {
                own_bundle_retry_attempts++;
                uint delay = get_own_publish_retry_delay(own_bundle_retry_attempts);
                own_bundle_publish_blocked_until = new DateTime.now_utc().add_seconds(delay);
                schedule_own_bundle_retry(stream, jid, delay);
                debug("OMEMO 2 own bundle reconciliation deferred after lookup failure");
            }
        } finally {
            // A stale old attachment must not remove a newly attached slot.
            if (active_bundle_requests == requests && stream_generation == generation) {
                requests.remove(key);
                queue_own_bundle_refresh();
            }
        }
    }

    private async void on_self_bundle_result(OwnBundle2Context context, StanzaNode? node) {
        XmppStream stream = context.stream;
        Jid jid = context.jid;
        uint generation = context.generation;
        if (!is_current_own_bundle_context(context)) return;
        uint64 snapshot_epoch = own_pre_key_consumption_epoch;
        uint32 published_max_pre_key_id = 0;
        debug("OMEMO 2: on_self_bundle_result called, node=%s", node != null ? "present" : "NULL");
        if (!is_current_stream(stream, generation)) {
            return;
        }
        if (!Plugin.ensure_context()) {
            debug("OMEMO 2: on_self_bundle_result: ensure_context FAILED, aborting");
            return;
        }
        if (!store.is_persistence_ready) {
            return;
        }
        Map<int, ECPublicKey> keys = new HashMap<int, ECPublicKey>();
        ECPublicKey? identity_key = null;
        int32 signed_pre_key_id = -1;
        ECPublicKey? signed_pre_key = null;
        SignedPreKeyRecord? signed_pre_key_record = null;
        bool changed = false;

        if (node == null) {
            debug("OMEMO 2: No existing bundle found, will publish new one");
            identity_key = store.identity_key_pair.public;
            changed = true;
        } else {
            Bundle2 bundle = new Bundle2(node);
            if (!is_valid_omemo2_bundle(bundle)) changed = true;
            foreach (Bundle2.PreKey2 prekey in bundle.pre_keys) {
                ECPublicKey? key = prekey.key;
                if (key != null && prekey.key_id > 0) {
                    keys[prekey.key_id] = (!)key;
                    published_max_pre_key_id = uint32.max(published_max_pre_key_id, (uint32) prekey.key_id);
                } else {
                    changed = true;
                }
            }
            identity_key = bundle.identity_key;
            signed_pre_key_id = bundle.signed_pre_key_id;
            signed_pre_key = bundle.signed_pre_key;
        }

        try {
            /* Validate IdentityKey */
            if (identity_key == null || store.identity_key_pair.public.compare((!)identity_key) != 0) {
                changed = true;
            }
            IdentityKeyPair identity_key_pair = store.identity_key_pair;
            uint32 observed_id = identity_key != null &&
                identity_key_pair.public.compare((!) identity_key) == 0 ? published_max_pre_key_id : 0;
            BackedPreKeyStore? backed_keys = context.keys as BackedPreKeyStore;
            if (backed_keys != null) ((!) backed_keys).observe_high_watermark(observed_id);

            /* Validate signedPreKeyRecord + ID */
            if (signed_pre_key == null || signed_pre_key_id == -1 || !store.contains_signed_pre_key(signed_pre_key_id) || store.load_signed_pre_key(signed_pre_key_id).key_pair.public.compare((!)signed_pre_key) != 0) {
                int64 next_signed_id = (int64) store.signed_pre_key_store.get_max_key_id() + 1;
                if (next_signed_id > int.MAX) throw new IOError.INVALID_DATA("OMEMO 2 signed pre-key IDs are exhausted");
                signed_pre_key_id = (int32) next_signed_id;

                signed_pre_key_record = Plugin.get_context().generate_signed_pre_key(identity_key_pair, signed_pre_key_id);
                store.store_signed_pre_key((!)signed_pre_key_record);
                changed = true;
            } else {
                signed_pre_key_record = store.load_signed_pre_key(signed_pre_key_id);
            }

            /* Upgrade SPK if signature_omemo is missing (pre-OMEMO2 keys) */
            if (signed_pre_key_record != null && signed_pre_key_record.signature_omemo.length == 0) {
                debug("OMEMO 2: SPK %u missing signature_omemo, upgrading...", signed_pre_key_record.id);
                SignedPreKeyRecord upgraded = signed_pre_key_record;
                Protocol.KeyHelper.upgrade_signed_pre_key(ref upgraded, identity_key_pair, Plugin.get_context().native_context);
                signed_pre_key_record = upgraded;
                store.store_signed_pre_key((!)signed_pre_key_record);
                changed = true;
            }

            /* Validate PreKeys */
            Set<PreKeyRecord> pre_key_records = new HashSet<PreKeyRecord>();
            foreach (var entry in keys.entries) {
                if (!store.contains_pre_key(entry.key)) {
                    changed = true;
                    continue;
                }
                PreKeyRecord record = store.load_pre_key(entry.key);
                if (record.key_pair.public.compare(entry.value) == 0) {
                    pre_key_records.add(record);
                } else {
                    changed = true;
                }
            }
            int new_keys = NUM_KEYS_TO_PUBLISH_V2 - pre_key_records.size;
            if (new_keys > 0) {
                uint32 next_id;
                if (backed_keys != null) {
                    next_id = ((!) backed_keys).reserve_key_ids((uint) new_keys, observed_id);
                } else {
                    int64 first = (int64) uint32.max(context.keys.get_max_key_id(), observed_id) + 1;
                    if (first <= 0xFFFFFF && first + new_keys - 1 >= 0xFFFFFF) first = 0x1000000;
                    if (first + new_keys - 1 > int.MAX) throw new IOError.INVALID_DATA("OMEMO 2 pre-key IDs are exhausted");
                    next_id = (uint32) first;
                }
                Set<PreKeyRecord> new_records = Plugin.get_context().generate_pre_keys(next_id, (uint)new_keys);
                pre_key_records.add_all(new_records);
                foreach (PreKeyRecord record in new_records) {
                    store.store_pre_key(record);
                }
                changed = true;
            }

            debug("OMEMO 2: Bundle check complete: changed=%s, pre_keys=%d", changed.to_string(), pre_key_records.size);
            if (changed) {
                debug("OMEMO 2: Publishing v2 bundle for device %d", (int32)store.local_registration_id);
                Pubsub.PublishResult result = yield publish_bundle_v2_with_result(stream, (!)signed_pre_key_record, identity_key_pair, pre_key_records, (int32)store.local_registration_id, generation);
                if (!is_current_own_bundle_context(context)) return;
                if (result.ok) {
                    own_bundle_publish_blocked_until = null;
                    own_bundle_retry_attempts = 0;
                    if (own_bundle_retry_timeout != 0) {
                        Source.remove(own_bundle_retry_timeout);
                        own_bundle_retry_timeout = 0;
                    }
                    if (snapshot_epoch == own_pre_key_consumption_epoch) own_bundle_reconciled_epoch = snapshot_epoch;
                    debug("OMEMO 2: Bundle published successfully");
                } else {
                    own_bundle_retry_attempts++;
                    uint retry_delay = get_own_publish_retry_delay_for_result(result, own_bundle_retry_attempts);
                    own_bundle_publish_blocked_until = new DateTime.now_utc().add_seconds(retry_delay);
                    log_own_publish_retry("bundle", pending_own_bundle_node_id ?? NODE_BUNDLES_V2, result, retry_delay);
                    schedule_own_bundle_retry(stream, jid, retry_delay);
                }
            } else {
                own_bundle_publish_blocked_until = null;
                own_bundle_retry_attempts = 0;
                if (own_bundle_retry_timeout != 0) {
                    Source.remove(own_bundle_retry_timeout);
                    own_bundle_retry_timeout = 0;
                }
                if (snapshot_epoch == own_pre_key_consumption_epoch) own_bundle_reconciled_epoch = snapshot_epoch;
                debug("OMEMO 2: Bundle unchanged, not publishing");
            }
        } catch (Error e) {
            warning("OMEMO 2: Unexpected error while publishing bundle: %s", e.message);
            if (is_current_own_bundle_context(context)) {
                own_bundle_retry_attempts++;
                uint retry_delay = get_own_publish_retry_delay(own_bundle_retry_attempts);
                own_bundle_publish_blocked_until = new DateTime.now_utc().add_seconds(retry_delay);
                schedule_own_bundle_retry(stream, jid, retry_delay);
            }
        }
    }

    private void schedule_own_bundle_retry(XmppStream stream, Jid jid, uint retry_delay) {
        if (own_bundle_retry_timeout != 0) return;
        uint generation = stream_generation;
        var context = new OwnBundle2Context(stream, generation, store, jid);
        if (!is_current_own_bundle_context(context)) return;
        uint source_id = 0;
        source_id = Timeout.add_seconds(retry_delay, () => {
            if (own_bundle_retry_timeout != source_id) return Source.REMOVE;
            own_bundle_retry_timeout = 0;
            if (!is_current_own_bundle_context(context)) return Source.REMOVE;
            own_bundle_publish_blocked_until = null;
            retry_pending_own_bundle_publish.begin(stream, jid, generation);
            return Source.REMOVE;
        });
        own_bundle_retry_timeout = source_id;
    }

    internal async void retry_pending_own_bundle_publish(XmppStream stream, Jid jid, uint generation) {
        if (!is_current_stream(stream, generation)) return;
        var context = new OwnBundle2Context(stream, generation, store, jid);
        if (!is_current_own_bundle_context(context)) return;
        prepare_own_bundle_context(context);
        if (own_bundle_retry_timeout != 0) {
            Source.remove(own_bundle_retry_timeout);
            own_bundle_retry_timeout = 0;
        }
        own_bundle_publish_blocked_until = null;
        if (pending_own_bundle_node != null && (pending_own_bundle_epoch != own_pre_key_consumption_epoch ||
                pending_own_bundle_context == null || !same_own_material((!) pending_own_bundle_context, context) ||
                !has_current_bundle_material(context, (!) pending_own_bundle_node))) {
            // A consumed key invalidates a cached failed publish. Rebuild
            // after the retained backoff instead of replaying stale XML.
            clear_pending_own_bundle_publish();
        }
        if (pending_own_bundle_node == null || pending_own_bundle_node_id == null || pending_own_bundle_item_id == null) {
            publish_bundles_if_needed(stream, jid);
            return;
        }

        uint64 snapshot_epoch = pending_own_bundle_epoch;
        own_bundle_operation = context;
        own_bundle_publish_active = true;
        Pubsub.PublishResult result = new Pubsub.PublishResult(false);
        try {
            result = yield publish_own_bundle_node(context, (!)pending_own_bundle_node_id, (!)pending_own_bundle_item_id, (!)pending_own_bundle_node);
        } catch (Error e) {
            warning("OMEMO 2: Unexpected error while retrying bundle publish: %s", e.message);
        }
        if (own_bundle_operation != context) return;
        own_bundle_operation = null;
        own_bundle_publish_active = false;
        if (!is_current_own_bundle_context(context)) {
            if (pending_own_bundle_context == context) clear_pending_own_bundle_publish();
            return;
        }

        if (result.ok) {
            clear_pending_own_bundle_publish();
            if (snapshot_epoch == own_pre_key_consumption_epoch) own_bundle_reconciled_epoch = snapshot_epoch;
            queue_own_bundle_refresh();
        } else {
            own_bundle_retry_attempts++;
            uint retry_delay = get_own_publish_retry_delay_for_result(result, own_bundle_retry_attempts);
            own_bundle_publish_blocked_until = new DateTime.now_utc().add_seconds(retry_delay);
            log_own_publish_retry("bundle", (!) pending_own_bundle_node_id, result, retry_delay);
            schedule_own_bundle_retry(stream, jid, retry_delay);
        }
    }

    private void clear_pending_own_bundle_publish() {
        own_bundle_publish_blocked_until = null;
        own_bundle_retry_attempts = 0;
        pending_own_bundle_node = null;
        pending_own_bundle_node_id = null;
        pending_own_bundle_item_id = null;
        pending_own_bundle_context = null;
        if (own_bundle_retry_timeout != 0) {
            Source.remove(own_bundle_retry_timeout);
            own_bundle_retry_timeout = 0;
        }
    }

    /**
     * Publish OMEMO 2 bundle to multi-item PEP node.
     * Key formats per OMEMO 2 (XEP-0384) and QXmpp interop:
     *   IK  = Ed25519 (ec_public_key_get_ed)
     *   SPK = X25519/Montgomery (ec_public_key_get_mont)
     *   PKs = X25519/Montgomery (ec_public_key_get_mont)
     */
    public async bool publish_bundle_v2(XmppStream stream, SignedPreKeyRecord signed_pre_key_record, IdentityKeyPair identity_key_pair, Set<PreKeyRecord> pre_key_records, int32 device_id, uint expected_generation = 0) throws Error {
        // Disabling automatic device-list maintenance does not revoke an
        // explicitly requested publication. Its cryptographic owner and
        // stream checks are identical; only the automatic switch is bypassed.
        Pubsub.PublishResult result = yield publish_bundle_v2_with_result(stream, signed_pre_key_record, identity_key_pair, pre_key_records, device_id, expected_generation, false);
        return result.ok;
    }

    private async Pubsub.PublishResult publish_bundle_v2_with_result(XmppStream stream, SignedPreKeyRecord signed_pre_key_record, IdentityKeyPair identity_key_pair, Set<PreKeyRecord> pre_key_records, int32 device_id, uint expected_generation = 0,
            bool automatic = true) throws Error {
        uint generation = expected_generation == 0 ? stream_generation : expected_generation;
        Bind.Flag? bind = stream.get_flag(Bind.Flag.IDENTITY);
        Jid? own_jid = bind != null ? ((!) bind).my_jid : null;
        if (own_jid == null) return new Pubsub.PublishResult(false);
        var context = new OwnBundle2Context(stream, generation, store, (!) own_jid, automatic);
        if (!is_current_own_bundle_context(context) || (uint32) device_id != context.device_id ||
                identity_key_pair.public.compare(store.identity_key_pair.public) != 0) return new Pubsub.PublishResult(false);
        prepare_own_bundle_context(context);
        ECKeyPair tmp;
        /* IK must be Ed25519, SPK must be Montgomery/X25519 */
        uint8[] ik_bytes = identity_key_pair.public.ed.data;
        uint8[] spk_bytes = (tmp = signed_pre_key_record.key_pair).public.mont.data;
        uint8[] sig_omemo = signed_pre_key_record.signature_omemo;
        uint8[] sig_legacy = signed_pre_key_record.signature;
        debug("OMEMO 2: Bundle IK %d bytes (Ed25519), SPK %d bytes (Mont)", ik_bytes.length, spk_bytes.length);
        debug("OMEMO 2: SPK signature_omemo %d bytes, signature_legacy %d bytes", sig_omemo.length, sig_legacy.length);
        debug("OMEMO 2: SPK id=%u", signed_pre_key_record.id);

        /* Verify the OMEMO signature locally, simulating what QXmpp/Kaidan does */
        ECPublicKey verify_ik;
        curve_decode_point_ed(out verify_ik, ik_bytes, Plugin.get_context().native_context);
        ECPublicKey verify_spk;
        curve_decode_point_mont(out verify_spk, spk_bytes, Plugin.get_context().native_context);
        uint8[] verify_spk_serialized = verify_spk.serialize_omemo();
        debug("OMEMO 2: Verify: IK decoded (has_ed=%s), SPK decoded, SPK serialized %d bytes",
              verify_ik.ed != null ? "true" : "false", verify_spk_serialized.length);
        int verify_result = Curve.verify_signature(verify_ik, verify_spk_serialized, sig_omemo);
        debug("OMEMO 2: Local SPK signature verification result: %d (1=valid, 0=invalid, <0=error)", verify_result);
        if (verify_result != 1) {
            throw new IOError.FAILED("OMEMO 2 signed pre-key verification failed; refusing to publish bundle");
        }

        StanzaNode bundle = new StanzaNode.build("bundle", NS_URI_V2)
                .add_self_xmlns()
                .put_node(new StanzaNode.build("spk", NS_URI_V2)
                    .put_attribute("id", signed_pre_key_record.id.to_string())
                    .put_node(new StanzaNode.text(Base64.encode(spk_bytes))))
                .put_node(new StanzaNode.build("spks", NS_URI_V2)
                    .put_node(new StanzaNode.text(Base64.encode(signed_pre_key_record.signature_omemo))))
                .put_node(new StanzaNode.build("ik", NS_URI_V2)
                    .put_node(new StanzaNode.text(Base64.encode(ik_bytes))));

        StanzaNode prekeys = new StanzaNode.build("prekeys", NS_URI_V2);
        foreach (PreKeyRecord pre_key_record in pre_key_records) {
            uint8[] pk_bytes = pre_key_record.key_pair.public.mont.data;
            prekeys.put_node(new StanzaNode.build("pk", NS_URI_V2)
                    .put_attribute("id", pre_key_record.id.to_string())
                    .put_node(new StanzaNode.text(Base64.encode(pk_bytes))));
        }
        bundle.put_node(prekeys);

        /* Publish to multi-item node with item_id = device_id */
        debug("OMEMO 2: About to publish bundle to node %s with item_id %s", NODE_BUNDLES_V2, device_id.to_string());
        pending_own_bundle_node = bundle;
        pending_own_bundle_node_id = NODE_BUNDLES_V2;
        pending_own_bundle_item_id = device_id.to_string();
        pending_own_bundle_epoch = own_pre_key_consumption_epoch;
        pending_own_bundle_context = context;
        own_bundle_operation = context;
        own_bundle_publish_active = true;
        Pubsub.PublishResult result;
        try {
            result = yield publish_own_bundle_node(context, NODE_BUNDLES_V2, device_id.to_string(), bundle);
        } catch (Error e) {
            if (own_bundle_operation == context) {
                own_bundle_operation = null;
                own_bundle_publish_active = false;
                if (!is_current_own_bundle_context(context) && pending_own_bundle_context == context) {
                    clear_pending_own_bundle_publish();
                }
            }
            throw e;
        }
        if (own_bundle_operation != context) return new Pubsub.PublishResult(false);
        own_bundle_operation = null;
        own_bundle_publish_active = false;
        if (!is_current_own_bundle_context(context)) {
            if (pending_own_bundle_context == context) clear_pending_own_bundle_publish();
            return new Pubsub.PublishResult(false);
        }
        if (result.ok) {
            clear_pending_own_bundle_publish();
        }
        return result;
    }

    private async Pubsub.PublishResult publish_own_bundle_node(OwnBundle2Context context, string node_id, string item_id, StanzaNode bundle) throws Error {
        XmppStream stream = context.stream;
        if (!is_current_own_bundle_context(context) || item_id != context.device_id.to_string() ||
                !has_current_bundle_material(context, bundle)) return new Pubsub.PublishResult(false);
        var publish_options = new Pubsub.PublishOptions()
            .set_access_model(Pubsub.ACCESS_MODEL_OPEN)
            .set_max_items("max")
            .set_persist_items(true);
        Pubsub.PublishResult result = yield stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).publish_with_result(stream, null, node_id, item_id, bundle, publish_options, true, false);
        if (!is_current_own_bundle_context(context)) return new Pubsub.PublishResult(false);
        debug("OMEMO 2: Bundle publish result: %s", result.ok ? "SUCCESS" : "FAILURE");
        if (result.ok) {
            yield try_make_node_public_in_context(context, node_id);
        }
        if (!is_current_own_bundle_context(context)) return new Pubsub.PublishResult(false);
        return result;
    }

    // Epochs describe committed native consumption. Also verify retained XML
    // directly: local cleanup/restoration can remove private key material
    // without emitting that commit hook, and must never replay its old bundle.
    private bool has_current_bundle_material(OwnBundle2Context context, StanzaNode node) {
        if (!is_current_own_bundle_context(context)) return false;
        try {
            Bundle2 bundle = new Bundle2(node);
            ECPublicKey? identity_key = bundle.identity_key;
            ECPublicKey? signed_key = bundle.signed_pre_key;
            uint8[]? signature = bundle.signed_pre_key_signature;
            if (identity_key == null || store.identity_key_pair.public.compare((!) identity_key) != 0 ||
                    signed_key == null || signature == null || bundle.signed_pre_key_id <= 0 ||
                    !store.contains_signed_pre_key(bundle.signed_pre_key_id)) return false;
            SignedPreKeyRecord signed_record = store.load_signed_pre_key(bundle.signed_pre_key_id);
            if (signed_record.key_pair.public.compare((!) signed_key) != 0 ||
                    Base64.encode(signed_record.signature_omemo) != Base64.encode((!) signature)) return false;
            if (bundle.pre_keys.size == 0) return false;
            foreach (Bundle2.PreKey2 key in bundle.pre_keys) {
                ECPublicKey? public_key = key.key;
                if (key.key_id <= 0 || public_key == null || !store.contains_pre_key(key.key_id) ||
                        store.load_pre_key(key.key_id).key_pair.public.compare((!) public_key) != 0) return false;
            }
            return true;
        } catch (Error error) {
            debug("OMEMO 2: Cached own bundle no longer matches the private key store");
            return false;
        }
    }

    private async void try_make_node_public(XmppStream stream, string node_id, string max_items = "max") {
        uint generation = stream_generation;
        if (!is_current_stream(stream, generation)) return;
        Bind.Flag? bind = stream.get_flag(Bind.Flag.IDENTITY);
        if (bind == null || ((!) bind).my_jid == null) return;
        var context = new OwnBundle2Context(stream, generation, store, ((!) bind).my_jid);
        yield try_make_node_public_in_context(context, node_id, max_items);
    }

    private async void try_make_node_public_in_context(OwnBundle2Context context, string node_id, string max_items = "max") {
        XmppStream stream = context.stream;
        if (!is_current_own_bundle_context(context)) return;
        debug("OMEMO 2: try_make_node_public for %s (max_items=%s)", node_id, max_items);
        DataForms.DataForm? data_form = yield stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).request_node_config(stream, null, node_id);
        if (!is_current_own_bundle_context(context)) return;
        if (data_form == null) {
            debug("OMEMO 2: try_make_node_public: data_form is NULL for %s", node_id);
            return;
        }

        bool needs_submit = false;
        foreach (DataForms.DataForm.Field field in data_form.fields) {
            if (field.var == "pubsub#access_model" && field.get_value_string() != Pubsub.ACCESS_MODEL_OPEN) {
                debug("OMEMO 2: Changing access_model from %s to %s", field.get_value_string(), Pubsub.ACCESS_MODEL_OPEN);
                field.set_value_string(Pubsub.ACCESS_MODEL_OPEN);
                needs_submit = true;
            }
            if (field.var == "pubsub#max_items" && field.get_value_string() != max_items) {
                debug("OMEMO 2: Changing max_items from %s to %s", field.get_value_string(), max_items);
                field.set_value_string(max_items);
                needs_submit = true;
            }
        }
        if (needs_submit) {
            if (!is_current_own_bundle_context(context)) return;
            yield stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).submit_node_config(stream, null, data_form, node_id);
            if (!is_current_own_bundle_context(context)) return;
            debug("OMEMO 2: Node config updated for %s", node_id);
        }
        debug("OMEMO 2: try_make_node_public done for %s", node_id);
    }
}

}
