using Gee;

namespace Xmpp.Xep.Pubsub {
    public const string NS_URI = "http://jabber.org/protocol/pubsub";
    public const string NS_URI_EVENT = NS_URI + "#event";
    private const string NS_URI_OWNER = NS_URI + "#owner";
    public const string NS_URI_ERROR = NS_URI + "#errors";

    public const string ACCESS_MODEL_AUTHORIZE = "authorize";
    public const string ACCESS_MODEL_OPEN = "open";
    public const string ACCESS_MODEL_PRESENCE = "presence";
    public const string ACCESS_MODEL_ROSTER = "roster";
    public const string ACCESS_MODEL_WHITELIST = "whitelist";

    public enum RequestPurpose {
        USER_ACTION,
        STATE_SYNC,
        PASSIVE_UI_PREFETCH,
        OPPORTUNISTIC_METADATA,
        OPTIONAL_NODE_QUERY
    }

    public class Module : XmppStreamModule {
        public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0060_pubsub_module");

        private HashMap<string, ItemListenerDelegate> item_listeners = new HashMap<string, ItemListenerDelegate>();
        private HashMap<string, RawItemListenerDelegate> raw_item_listeners =
            new HashMap<string, RawItemListenerDelegate>();
        private HashMap<string, RetractListenerDelegate> retract_listeners = new HashMap<string, RetractListenerDelegate>();
        private HashMap<string, DeleteListenerDelegate> delete_listeners = new HashMap<string, DeleteListenerDelegate>();

        private void log_iq_failure(string message, GLib.Error error, RequestPurpose purpose = RequestPurpose.USER_ACTION) {
            if (error is IOError.CANCELLED ||
                    purpose == RequestPurpose.PASSIVE_UI_PREFETCH ||
                    purpose == RequestPurpose.OPPORTUNISTIC_METADATA) {
                debug("%s: %s", message, error.message);
            } else {
                warning("%s: %s", message, error.message);
            }
        }

        private void log_iq_error(string message, Iq.Stanza iq, RequestPurpose purpose) {
            ErrorStanza? error = iq.get_error();
            string condition = error != null ? ((!) error).condition : "unknown";
            bool expected_missing_state = (purpose == RequestPurpose.STATE_SYNC ||
                    purpose == RequestPurpose.OPTIONAL_NODE_QUERY) &&
                    condition == ErrorStanza.CONDITION_ITEM_NOT_FOUND;
            if (expected_missing_state ||
                    purpose == RequestPurpose.PASSIVE_UI_PREFETCH ||
                    purpose == RequestPurpose.OPPORTUNISTIC_METADATA) {
                debug("%s: IQ error %s", message, condition);
            } else {
                warning("%s: IQ error %s", message, condition);
            }
        }

        public void add_filtered_notification(XmppStream stream, string node,
                owned ItemListenerDelegate.ResultFunc? item_listener,
                owned RetractListenerDelegate.ResultFunc? retract_listener,
                owned DeleteListenerDelegate.ResultFunc? delete_listener) {
            stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).add_feature_notify(stream, node);
            if (item_listener != null) {
                item_listeners[node] = new ItemListenerDelegate((owned)item_listener);
            }
            if (retract_listener != null) {
                retract_listeners[node] = new RetractListenerDelegate((owned)retract_listener);
            }
            if (delete_listener != null) {
                delete_listeners[node] = new DeleteListenerDelegate((owned)delete_listener);
            }
        }

        /** Register a strict consumer that needs the complete event item. */
        public void add_filtered_raw_notification(XmppStream stream,
                string node,
                owned RawItemListenerDelegate.ResultFunc item_listener) {
            stream.get_module<ServiceDiscovery.Module>(
                ServiceDiscovery.Module.IDENTITY).add_feature_notify(stream,
                    node);
            raw_item_listeners[node] = new RawItemListenerDelegate(
                (owned) item_listener);
        }

        public void remove_filtered_notification(XmppStream stream, string node) {
            stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).remove_feature_notify(stream, node);
            item_listeners.unset(node);
            raw_item_listeners.unset(node);
            retract_listeners.unset(node);
            delete_listeners.unset(node);
        }

        public async Gee.List<StanzaNode>? request_all(XmppStream stream,
                Jid jid, string node, int max_items = -1,
                RequestPurpose purpose = RequestPurpose.USER_ACTION) { // TODO multiple nodes gehen auch
            return (yield request_all_with_result(stream, jid, node, max_items,
                purpose)).items;
        }

        public async RequestAllResult request_all_with_result(
                XmppStream stream, Jid jid, string node, int max_items = -1,
                RequestPurpose purpose = RequestPurpose.USER_ACTION) { // TODO multiple nodes gehen auch
            return (yield request_all_with_result_cancellable(stream, jid,
                node, max_items, purpose, null)) ??
                new RequestAllResult.local_cancellation("pubsub request cancelled");
        }

        // Vala's GTask returns null when its Cancellable is cancelled, even
        // if the body returned a structured failure. Callers must distinguish
        // cancellation from a successful empty node (Linux and Windows).
        public async RequestAllResult? request_all_with_result_cancellable(
                XmppStream stream, Jid jid, string node, int max_items = -1,
                RequestPurpose purpose = RequestPurpose.USER_ACTION,
                Cancellable? cancellable = null) { // TODO multiple nodes gehen auch
            StanzaNode items_request = new StanzaNode.build("items", NS_URI).put_attribute("node", node);
            if (max_items > 0) {
                items_request.put_attribute("max_items", max_items.to_string());
            }
            Iq.Stanza request_iq = new Iq.Stanza.get(new StanzaNode.build("pubsub", NS_URI).add_self_xmlns().put_node(items_request));
            request_iq.to = jid;

            Iq.Stanza? iq_res;
            try {
                iq_res = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY)
                    .send_iq_async(stream, request_iq, Priority.DEFAULT,
                        cancellable);
            } catch (GLib.Error e) {
                log_iq_failure("Failed to request pubsub items from %s node=%s max_items=%d".printf(jid.to_string(), node, max_items), e, purpose);
                if (e is IOError.CANCELLED) {
                    return new RequestAllResult.local_cancellation(e.message);
                }
                return new RequestAllResult(null, null, null, e.message);
            }
            if (iq_res == null) return new RequestAllResult(null, null, null, "pubsub request returned no IQ stanza");
            if (((!) iq_res).is_error()) {
                log_iq_error("Failed to request pubsub items from %s node=%s max_items=%d".printf(jid.to_string(), node, max_items), (!) iq_res, purpose);
                ErrorStanza? error = iq_res.get_error();
                if (error == null) {
                    return new RequestAllResult(null);
                }
                return RequestAllResult.from_error_stanza((!) error);
            }

            StanzaNode event_node = iq_res.stanza.get_subnode("pubsub", NS_URI);
            if (event_node == null) return new RequestAllResult(null, null, null, "pubsub response missing pubsub");
            StanzaNode items_node = event_node.get_subnode("items", NS_URI);
            if (items_node == null) return new RequestAllResult(null, null, null, "pubsub response missing items");

            Gee.List<StanzaNode> items = items_node.get_subnodes("item", NS_URI);
            debug("PubSub IQ response for node '%s': %d item(s)", node, items.size);
            return new RequestAllResult(items);
        }

        public async StanzaNode? request_item(XmppStream stream, Jid jid, string node, string item_id, RequestPurpose purpose = RequestPurpose.USER_ACTION) {
            StanzaNode pubsub = new StanzaNode.build("pubsub", NS_URI).add_self_xmlns();
            StanzaNode items = new StanzaNode.build("items", NS_URI).put_attribute("node", node);
            items.put_node(new StanzaNode.build("item", NS_URI).put_attribute("id", item_id));
            pubsub.put_node(items);

            Iq.Stanza request_iq = new Iq.Stanza.get(pubsub);
            request_iq.to = jid;

            Iq.Stanza? iq_res;
            try {
                iq_res = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, request_iq);
            } catch (GLib.Error e) {
                log_iq_failure("Failed to request pubsub item from %s node=%s item=%s".printf(jid.to_string(), node, item_id), e, purpose);
                return null;
            }
            if (iq_res == null) return null;
            if (((!) iq_res).is_error()) {
                log_iq_error("Failed to request pubsub item from %s node=%s item=%s".printf(jid.to_string(), node, item_id), (!) iq_res, purpose);
                return null;
            }

            StanzaNode event_node = iq_res.stanza.get_subnode("pubsub", NS_URI);
            if (event_node == null) return null;
            StanzaNode items_node = event_node.get_subnode("items", NS_URI);
            if (items_node == null) return null;
            StanzaNode item_node = items_node.get_subnode("item", NS_URI);
            if (item_node == null) return null;
            if (item_node.sub_nodes.size == 0) return null;
            return item_node.sub_nodes[0];
        }

        public delegate void OnResult(XmppStream stream, Jid jid, string? id, StanzaNode? node);
        public void request(XmppStream stream, Jid jid, string node, owned OnResult listener) { // TODO multiple nodes gehen auch
            Iq.Stanza request_iq = new Iq.Stanza.get(new StanzaNode.build("pubsub", NS_URI).add_self_xmlns().put_node(new StanzaNode.build("items", NS_URI).put_attribute("node", node)));
            request_iq.to = jid;
            stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq(stream, request_iq, (stream, iq) => {
                StanzaNode event_node = iq.stanza.get_subnode("pubsub", NS_URI);
                StanzaNode items_node = event_node != null ? event_node.get_subnode("items", NS_URI) : null;
                StanzaNode item_node = items_node != null ? items_node.get_subnode("item", NS_URI) : null;
                string? id = item_node != null ? item_node.get_attribute("id", NS_URI) : null;
                listener(stream, iq.from, id, (item_node != null && item_node.sub_nodes.size > 0) ? item_node.sub_nodes[0] : null);
            });
        }

        public async bool publish(
                XmppStream stream, Jid? jid, string node_id, string? item_id, StanzaNode content,
                PublishOptions? publish_options = null,
                bool try_reconfiguring = true
        ) {
            PublishResult result = yield publish_with_result(stream, jid,
                node_id, item_id, content, publish_options,
                try_reconfiguring, true);
            return result.ok;
        }

        public async PublishResult publish_with_result(
                XmppStream stream, Jid? jid, string node_id, string? item_id, StanzaNode content,
                PublishOptions? publish_options = null,
                bool try_reconfiguring = true,
                bool log_errors = true
        ) {
            return (yield publish_with_result_cancellable(stream, jid, node_id,
                item_id, content, publish_options, try_reconfiguring,
                log_errors, null)) ?? new PublishResult.ambiguous_failure("pubsub publish cancelled");
        }

        // Cancellation can discard the result after a write. Null is not a
        // confirmed failure to apply the change on the server.
        public async PublishResult? publish_with_result_cancellable(
                XmppStream stream, Jid? jid, string node_id, string? item_id,
                StanzaNode content, PublishOptions? publish_options = null,
                bool try_reconfiguring = true, bool log_errors = true,
                Cancellable? cancellable = null
        ) {
            StanzaNode pubsub_node = new StanzaNode.build("pubsub", NS_URI).add_self_xmlns();
            StanzaNode publish_node = new StanzaNode.build("publish", NS_URI).put_attribute("node", node_id);
            pubsub_node.put_node(publish_node);
            StanzaNode items_node = new StanzaNode.build("item", NS_URI);
            if (item_id != null) items_node.put_attribute("id", item_id);
            items_node.put_node(content);
            publish_node.put_node(items_node);

            // Send along our requirements for the node
            if (publish_options != null) {
                StanzaNode publish_options_node = new StanzaNode.build("publish-options", NS_URI);
                pubsub_node.put_node(publish_options_node);

                DataForms.DataForm data_form = new DataForms.DataForm();
                DataForms.DataForm.HiddenField form_type_field = new DataForms.DataForm.HiddenField() { var="FORM_TYPE" };
                form_type_field.set_value_string(NS_URI + "#publish-options");
                data_form.add_field(form_type_field);

                foreach (string field_name in publish_options.settings.keys) {
                    DataForms.DataForm.Field field = new DataForms.DataForm.Field() { var=field_name };
                    field.set_value_string(publish_options.settings[field_name]);
                    data_form.add_field(field);
                }
                publish_options_node.put_node(data_form.get_submit_node());
            }

            Iq.Stanza iq = new Iq.Stanza.set(pubsub_node);
            if (jid != null) {
                iq.to = jid;
            }

            // If the node was configured differently before, reconfigure it to meet our requirements and try again
            Iq.Stanza? iq_result;
            try {
                iq_result = yield stream.get_module<Iq.Module>(
                    Iq.Module.IDENTITY).send_iq_async(stream, iq,
                        Priority.DEFAULT, cancellable);
            } catch (GLib.Error e) {
                if (log_errors && !(e is IOError.CANCELLED)) {
                    log_iq_failure("Failed to publish item", e);
                }
                // Once an IQ write has started, a transport error or timeout
                // cannot prove that the service did not apply the publish.
                // Preserve that distinction for state-changing callers.
                return new PublishResult.ambiguous_failure(e.message);
            }
            if (iq_result == null) {
                return new PublishResult.ambiguous_failure(
                    "pubsub publish returned no IQ stanza");
            }
            if (iq_result.is_error()) {
                var error = iq_result.get_error();
                if (error == null) {
                    if (log_errors) {
                        warning("Failed to publish item to node %s: unknown/unknown", node_id);
                    }
                    return new PublishResult(false);
                }

                if (publish_options == null || !try_reconfiguring) return PublishResult.from_error_stanza(error);

                // Check for conflict (409) or precondition-not-met
                bool conflict = error.type_ == ErrorStanza.TYPE_CANCEL && error.condition == ErrorStanza.CONDITION_CONFLICT;
                bool precondition_not_met = error.error_node.get_subnode("precondition-not-met", NS_URI_ERROR) != null;
                
                if (precondition_not_met || conflict) {
                    if (log_errors) {
                        warning("PubSub publish failed with conflict/precondition-not-met. Attempting to reconfigure node %s", node_id);
                    }
                    bool success = yield change_node_config(stream, jid,
                        node_id, publish_options, cancellable);
                    if (!success) {
                        if (log_errors && (cancellable == null ||
                                !((!) cancellable).is_cancelled())) {
                            warning("Failed to reconfigure node %s", node_id);
                        }
                        return PublishResult.from_error_stanza(error);
                    }
                    if (log_errors) {
                        warning("Successfully reconfigured node %s. Retrying publish...", node_id);
                    }
                    return yield publish_with_result_cancellable(stream, jid,
                        node_id, item_id, content, publish_options, false,
                        log_errors, cancellable);
                }
                if (log_errors) {
                    warning("Failed to publish item to node %s: %s/%s",
                            node_id, error.type_ ?? "unknown", error.condition ?? "unknown");
                }
                return PublishResult.from_error_stanza(error);
            }

            return new PublishResult(true);
        }

        public async bool retract_item(XmppStream stream, Jid? jid, string node_id, string item_id) {
            return yield retract_item_with_error_logging(stream, jid, node_id, item_id, true);
        }

        public async bool retract_item_with_error_logging(XmppStream stream, Jid? jid, string node_id, string item_id, bool log_errors) {
            return (yield retract_item_with_result(stream, jid, node_id, item_id, log_errors)).ok;
        }

        public async RetractResult retract_item_with_result(XmppStream stream, Jid? jid, string node_id, string item_id, bool log_errors = true) {
            return (yield retract_item_with_result_cancellable(stream, jid,
                    node_id, item_id, log_errors, null)) ?? new RetractResult(false);
        }

        public async RetractResult? retract_item_with_result_cancellable(XmppStream stream, Jid? jid,
                string node_id, string item_id, bool log_errors = true,
                Cancellable? cancellable = null) {
            StanzaNode pubsub_node = new StanzaNode.build("pubsub", NS_URI).add_self_xmlns()
                .put_node(new StanzaNode.build("retract", NS_URI).put_attribute("node", node_id).put_attribute("notify", "true")
                    .put_node(new StanzaNode.build("item", NS_URI).put_attribute("id", item_id)));

            Iq.Stanza iq = new Iq.Stanza.set(pubsub_node);
            if (jid != null) {
                iq.to = jid;
            }
            Iq.Stanza? result_iq;
            try {
                result_iq = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(
                        stream, iq, Priority.DEFAULT, cancellable);
            } catch (GLib.Error e) {
                if (log_errors) {
                    log_iq_failure("Failed to retract pubsub item %s from node %s".printf(item_id, node_id), e);
                }
                return new RetractResult(false, null, null, e.message);
            }

            if (result_iq == null) return new RetractResult(false);
            if (((!) result_iq).is_error()) {
                if (log_errors) {
                    log_iq_error("Failed to retract pubsub item %s from node %s".printf(item_id, node_id), (!) result_iq, RequestPurpose.USER_ACTION);
                }
                ErrorStanza? error = result_iq.get_error();
                if (error == null) return new RetractResult(false);
                return RetractResult.from_error_stanza((!) error);
            }
            return new RetractResult(true);
        }

        public async bool delete_node_async(XmppStream stream, Jid? jid, string node_id) {
            StanzaNode pubsub_node = new StanzaNode.build("pubsub", NS_URI_OWNER).add_self_xmlns();
            StanzaNode publish_node = new StanzaNode.build("delete", NS_URI_OWNER).put_attribute("node", node_id);
            pubsub_node.put_node(publish_node);

            Iq.Stanza iq = new Iq.Stanza.set(pubsub_node);
            if (jid != null) {
                iq.to = jid;
            }
            Iq.Stanza? iq_result;
            try {
                iq_result = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, iq);
            } catch (GLib.Error e) {
                log_iq_failure("Failed to delete pubsub node %s".printf(node_id), e);
                return false;
            }
            if (iq_result == null) return false;
            return !iq_result.is_error();
        }

        public void delete_node(XmppStream stream, Jid? jid, string node_id) {
            delete_node_async.begin(stream, jid, node_id);
        }

        /**
         * Remove other privileged readers before publishing personal PEP
         * data. The caller must also set the intended access model (e.g.
         * whitelist or presence). This checks affiliations only; it neither
         * retrieves payloads nor changes the node's access model.
         */
        public async void ensure_node_owner_only(XmppStream stream,
                Jid owner_bare_jid, string node_id,
                Cancellable? cancellable = null) throws Error {
            check_owner_only_account(stream, owner_bare_jid, cancellable);
            if (node_id == "") {
                throw new IOError.INVALID_ARGUMENT("A PEP node is required");
            }
            HashMap<string, string>? affiliations =
                yield request_owner_affiliations(stream, owner_bare_jid,
                    node_id, cancellable);
            // The caller must create a missing node with its intended access
            // model. A missing node has no existing readers to remove.
            if (affiliations == null) return;

            var changes = new StanzaNode.build("affiliations", NS_URI_OWNER)
                .put_attribute("node", node_id);
            foreach (var entry in ((!) affiliations).entries) {
                if (entry.key != owner_bare_jid.to_string() &&
                        affiliation_can_read(entry.value)) {
                    changes.put_node(new StanzaNode.build("affiliation",
                        NS_URI_OWNER).put_attribute("jid", entry.key)
                        .put_attribute("affiliation", "none"));
                }
            }
            if (changes.sub_nodes.is_empty) return;

            check_owner_only_account(stream, owner_bare_jid, cancellable);
            var request = new Iq.Stanza.set(new StanzaNode.build("pubsub",
                NS_URI_OWNER).add_self_xmlns().put_node(changes));
            request.to = owner_bare_jid;
            Iq.Stanza result = yield stream.get_module<Iq.Module>(
                Iq.Module.IDENTITY).send_iq_async(stream, request,
                    Priority.DEFAULT, cancellable);
            check_owner_only_response(stream, owner_bare_jid, result,
                cancellable);
            if (result.is_error()) {
                throw new IOError.PERMISSION_DENIED(
                    "Server rejected removal of other PEP readers: %s".printf(
                        owner_affiliations_error_condition(result)));
            }
            if (!owner_only_element_children(result.stanza).is_empty) {
                throw new IOError.INVALID_DATA(
                    "PEP affiliation change acknowledgement is not empty");
            }

            affiliations = yield request_owner_affiliations(stream,
                owner_bare_jid, node_id, cancellable);
            if (affiliations == null) {
                throw new IOError.INVALID_DATA(
                    "PEP node disappeared while verifying its readers");
            }
            foreach (var entry in ((!) affiliations).entries) {
                if (entry.key != owner_bare_jid.to_string() &&
                        affiliation_can_read(entry.value)) {
                    throw new IOError.PERMISSION_DENIED(
                        "Other accounts still have privileged access to the PEP node");
                }
            }
        }

        private async HashMap<string, string>? request_owner_affiliations(
                XmppStream stream, Jid owner_bare_jid, string node_id,
                Cancellable? cancellable) throws Error {
            check_owner_only_account(stream, owner_bare_jid, cancellable);
            var request = new Iq.Stanza.get(new StanzaNode.build("pubsub",
                NS_URI_OWNER).add_self_xmlns().put_node(new StanzaNode.build(
                    "affiliations", NS_URI_OWNER).put_attribute("node",
                        node_id)));
            request.to = owner_bare_jid;
            Iq.Stanza result = yield stream.get_module<Iq.Module>(
                Iq.Module.IDENTITY).send_iq_async(stream, request,
                    Priority.DEFAULT, cancellable);
            check_owner_only_response(stream, owner_bare_jid, result,
                cancellable);
            if (result.is_error()) {
                string condition = owner_affiliations_error_condition(result);
                if (condition == ErrorStanza.CONDITION_ITEM_NOT_FOUND) {
                    return null;
                }
                throw new IOError.PERMISSION_DENIED(
                    "Server rejected PEP affiliation query: %s".printf(
                        condition));
            }

            Gee.List<StanzaNode> iq_children =
                owner_only_element_children(result.stanza);
            if (iq_children.size != 1 || iq_children[0].name != "pubsub" ||
                    iq_children[0].ns_uri != NS_URI_OWNER) {
                throw new IOError.INVALID_DATA(
                    "PEP affiliation response has no unique owner payload");
            }
            Gee.List<StanzaNode> pubsub_children =
                owner_only_element_children(iq_children[0]);
            if (pubsub_children.size != 1 ||
                    pubsub_children[0].name != "affiliations" ||
                    pubsub_children[0].ns_uri != NS_URI_OWNER ||
                    pubsub_children[0].get_attribute("node") != node_id) {
                throw new IOError.INVALID_DATA(
                    "PEP affiliation response does not match the node");
            }

            var affiliations = new HashMap<string, string>();
            foreach (StanzaNode item in owner_only_element_children(
                    pubsub_children[0])) {
                string? raw_jid = item.get_attribute("jid");
                string? affiliation = item.get_attribute("affiliation");
                if (item.name != "affiliation" || item.ns_uri != NS_URI_OWNER ||
                        raw_jid == null || affiliation == null ||
                        !owner_only_element_children(item).is_empty) {
                    throw new IOError.INVALID_DATA(
                        "Malformed PEP affiliation entry");
                }
                Jid jid;
                try {
                    jid = new Jid((!) raw_jid);
                } catch (InvalidJidError e) {
                    throw new IOError.INVALID_DATA(
                        "PEP affiliation entry contains an invalid JID");
                }
                if (!jid.is_bare() || affiliations.has_key(jid.to_string()) ||
                        (affiliation != "owner" && affiliation != "member" &&
                         affiliation != "publisher" &&
                         affiliation != "publish-only" &&
                         affiliation != "outcast" && affiliation != "none")) {
                    throw new IOError.INVALID_DATA(
                        "PEP affiliation entry is ambiguous or unsupported");
                }
                // Owner lists should omit 'none' (XEP-0060 8.9.1.2), but
                // explicit nonreader entries do not weaken the privacy check.
                affiliations[jid.to_string()] = (!) affiliation;
            }
            if (affiliations[owner_bare_jid.to_string()] != "owner") {
                throw new IOError.PERMISSION_DENIED(
                    "The bound account is not the verified PEP node owner");
            }
            return affiliations;
        }

        private static bool affiliation_can_read(string affiliation) {
            return affiliation == "owner" || affiliation == "publisher" ||
                affiliation == "member";
        }

        private static void check_owner_only_account(XmppStream stream,
                Jid owner_bare_jid, Cancellable? cancellable) throws Error {
            if (cancellable != null) cancellable.set_error_if_cancelled();
            Bind.Flag? bind = stream.get_flag(Bind.Flag.IDENTITY);
            if (!owner_bare_jid.is_bare() || owner_bare_jid.localpart == null ||
                    bind == null || !((!) bind).finished ||
                    ((!) bind).my_jid == null ||
                    !owner_bare_jid.equals(((!) ((!) bind).my_jid).bare_jid)) {
                throw new IOError.PERMISSION_DENIED(
                    "PEP privacy checks require the bound account's bare JID");
            }
        }

        private static void check_owner_only_response(XmppStream stream,
                Jid owner_bare_jid, Iq.Stanza result,
                Cancellable? cancellable) throws Error {
            check_owner_only_account(stream, owner_bare_jid, cancellable);
            // RFC 6120 treats a missing sender as the user's own bare JID.
            // Never use Stanza.from's fallback to accept an invalid address.
            string? raw_from = result.stanza.get_attribute("from");
            if (raw_from != null) {
                try {
                    if (!new Jid((!) raw_from).equals(owner_bare_jid)) {
                        throw new IOError.PERMISSION_DENIED(
                            "PEP privacy response has an unexpected sender");
                    }
                } catch (InvalidJidError e) {
                    throw new IOError.INVALID_DATA(
                        "PEP privacy response has an invalid sender");
                }
            }
            if (result.type_ != Iq.Stanza.TYPE_RESULT && !result.is_error()) {
                throw new IOError.INVALID_DATA(
                    "PEP privacy response is not an IQ result or error");
            }
        }

        private static string owner_affiliations_error_condition(
                Iq.Stanza result) throws Error {
            Gee.List<StanzaNode> errors = result.stanza.get_subnodes("error",
                "jabber:client");
            ErrorStanza? error = result.get_error();
            if (errors.size != 1 || error == null) {
                throw new IOError.INVALID_DATA("Malformed PEP IQ error");
            }
            string? type = errors[0].get_attribute("type");
            if (type != ErrorStanza.TYPE_AUTH && type != ErrorStanza.TYPE_CANCEL &&
                    type != ErrorStanza.TYPE_CONTINUE &&
                    type != ErrorStanza.TYPE_MODIFY && type != ErrorStanza.TYPE_WAIT) {
                throw new IOError.INVALID_DATA("PEP IQ error has no valid type");
            }
            int conditions = 0;
            foreach (var child in owner_only_element_children(errors[0])) {
                if (child.ns_uri == "urn:ietf:params:xml:ns:xmpp-stanzas" &&
                        child.name != "text") conditions++;
            }
            if (conditions != 1) {
                throw new IOError.INVALID_DATA("Ambiguous PEP IQ error");
            }
            return ((!) error).condition;
        }

        private static Gee.List<StanzaNode> owner_only_element_children(
                StanzaNode node) throws Error {
            var elements = new ArrayList<StanzaNode>();
            foreach (var child in node.sub_nodes) {
                if (child.name == "#text") {
                    if ((child.get_string_content() ?? "").strip() != "") {
                        throw new IOError.INVALID_DATA(
                            "Unexpected text in PEP owner response");
                    }
                } else {
                    elements.add(child);
                }
            }
            return elements;
        }

        public async DataForms.DataForm? request_node_config(
                XmppStream stream, Jid? jid, string node_id) {
            return yield request_node_config_with_cancellable(stream, jid,
                node_id, null);
        }

        public async DataForms.DataForm? request_node_config_with_cancellable(
                XmppStream stream, Jid? jid, string node_id,
                Cancellable? cancellable = null) {
            StanzaNode pubsub_node = new StanzaNode.build("pubsub", NS_URI_OWNER).add_self_xmlns();
            StanzaNode publish_node = new StanzaNode.build("configure", NS_URI_OWNER).put_attribute("node", node_id);
            pubsub_node.put_node(publish_node);

            Iq.Stanza iq = new Iq.Stanza.get(pubsub_node);
            if (jid != null) {
                iq.to = jid;
            }
            Iq.Stanza? result_iq;
            try {
                result_iq = yield stream.get_module<Iq.Module>(
                    Iq.Module.IDENTITY).send_iq_async(stream, iq,
                        Priority.DEFAULT, cancellable);
            } catch (GLib.Error e) {
                if (!(e is IOError.CANCELLED)) {
                    log_iq_failure("Failed to request node config", e);
                }
                return null;
            }
            if (result_iq == null) return null;
            StanzaNode? data_form_node = result_iq.stanza.get_deep_subnode(Pubsub.NS_URI_OWNER + ":pubsub", Pubsub.NS_URI_OWNER + ":configure", "jabber:x:data:x");
            if (data_form_node == null) return null;
            return DataForms.DataForm.create_from_node(data_form_node);
        }

        public async bool submit_node_config(XmppStream stream, Jid? jid,
                DataForms.DataForm data_form, string node_id) {
            return yield submit_node_config_with_cancellable(stream, jid,
                data_form, node_id, null);
        }

        public async bool submit_node_config_with_cancellable(
                XmppStream stream, Jid? jid, DataForms.DataForm data_form,
                string node_id,
                Cancellable? cancellable = null) {
            StanzaNode submit_node = data_form.get_submit_node();

            StanzaNode pubsub_node = new StanzaNode.build("pubsub", Pubsub.NS_URI_OWNER).add_self_xmlns();
            StanzaNode publish_node = new StanzaNode.build("configure", Pubsub.NS_URI_OWNER).put_attribute("node", node_id);
            pubsub_node.put_node(publish_node);
            publish_node.put_node(submit_node);


            Iq.Stanza iq = new Iq.Stanza.set(pubsub_node);
            if (jid != null) {
                iq.to = jid;
            }
            // node config is addressed to the pubsub service; keep default addressing
            Iq.Stanza? iq_result;
            try {
                iq_result = yield stream.get_module<Iq.Module>(
                    Iq.Module.IDENTITY).send_iq_async(stream, iq,
                        Priority.DEFAULT, cancellable);
            } catch (GLib.Error e) {
                if (!(e is IOError.CANCELLED)) {
                    log_iq_failure("Failed to submit node config", e);
                }
                return false;
            }
            if (iq_result == null) return false;

            return !iq_result.is_error();
        }

        public override void attach(XmppStream stream) {
            stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message.connect(on_received_message);
        }

        public override void detach(XmppStream stream) {
            stream.get_module<MessageModule>(MessageModule.IDENTITY).received_message.disconnect(on_received_message);
        }

        public override string get_ns() { return NS_URI; }
        public override string get_id() { return IDENTITY.id; }

        private void on_received_message(XmppStream stream, MessageStanza message) {
            StanzaNode event_node = message.stanza.get_subnode("event", NS_URI_EVENT);
            if (event_node == null) return;

            if (!message.from.is_bare()) {
                warning("Got a PEP message from a full JID (%s), ignoring.", message.from.to_string());
                return;
            }

            StanzaNode items_node = event_node.get_subnode("items", NS_URI_EVENT);
            if (items_node != null) {
                string node = items_node.get_attribute("node", NS_URI_EVENT);

                Gee.List<StanzaNode> item_nodes = items_node.get_subnodes("item", NS_URI_EVENT);
                foreach (StanzaNode item_node in item_nodes) {
                    string id = item_node.get_attribute("id", NS_URI_EVENT);

                    if (item_listeners.has_key(node) && item_node.sub_nodes.size > 0) {
                        item_listeners[node].on_result(stream, message.from, id, item_node.sub_nodes[0]);
                    }
                    if (raw_item_listeners.has_key(node)) {
                        raw_item_listeners[node].on_result(stream,
                            message.from, item_node);
                    }
                }

                StanzaNode? retract_node = items_node.get_subnode("retract", NS_URI_EVENT);
                if (retract_node != null) {
                    string id = retract_node.get_attribute("id", NS_URI_EVENT);

                    if (retract_listeners.has_key(node)) {
                        retract_listeners[node].on_result(stream, message.from, id);
                    }
                }
            }

            StanzaNode? delete_node = event_node.get_subnode("delete", NS_URI_EVENT);
            if (delete_node != null) {
                string node = delete_node.get_attribute("node", NS_URI_EVENT);

                if (delete_listeners.has_key(node)) {
                    delete_listeners[node].on_result(stream, message.from);
                }
            }
        }

        private async bool change_node_config(XmppStream stream, Jid? jid,
                string node, PublishOptions publish_options,
                Cancellable? cancellable = null) {
            DataForms.DataForm? data_form = yield stream.get_module<
                Pubsub.Module>(Pubsub.Module.IDENTITY)
                    .request_node_config_with_cancellable(stream, jid, node,
                        cancellable);
            if (data_form == null) return false;

            foreach (DataForms.DataForm.Field field in data_form.fields) {
                if (publish_options.settings.has_key(field.var) && publish_options.settings[field.var] != field.get_value_string()) {
                    field.set_value_string(publish_options.settings[field.var]);
                }
            }
            return yield stream.get_module<Pubsub.Module>(
                Pubsub.Module.IDENTITY).submit_node_config_with_cancellable(
                    stream, jid, data_form, node, cancellable);
        }
    }

    public class PublishOptions {
        public HashMap<string, string> settings = new HashMap<string, string>();

        public PublishOptions set_persist_items(bool persist) {
            settings["pubsub#persist_items"] = persist.to_string();
            return this;
        }

        public PublishOptions set_max_items(string max) {
            settings["pubsub#max_items"] = max;
            return this;
        }

        public PublishOptions set_send_last_published_item(string send) {
            settings["pubsub#send_last_published_item"] = send.to_string();
            return this;
        }

        public PublishOptions set_access_model(string model) {
            settings["pubsub#access_model"] = model;
            return this;
        }
    }

    public class RequestAllResult {
        public Gee.List<StanzaNode>? items;
        public string? error_type;
        public string? error_condition;
        public string? error_text;
        public bool presence_subscription_required;
        // Process-local cancellation, never inferred from a server error's
        // type="cancel", condition or text.
        public bool locally_cancelled { get; private set; default = false; }

        public RequestAllResult(Gee.List<StanzaNode>? items, string? error_type = null, string? error_condition = null, string? error_text = null, bool presence_subscription_required = false) {
            this.items = items;
            this.error_type = error_type;
            this.error_condition = error_condition;
            this.error_text = error_text;
            this.presence_subscription_required = presence_subscription_required;
        }

        internal RequestAllResult.local_cancellation(string? message) {
            this(null, null, null, message);
            this.locally_cancelled = true;
        }

        public static RequestAllResult from_error_stanza(ErrorStanza error) {
            bool presence_required = error.error_node.get_subnode(
                "presence-subscription-required", "http://jabber.org/protocol/pubsub#errors") != null;
            return new RequestAllResult(null, error.type_, error.condition, error.text, presence_required);
        }

        public bool is_access_denied() {
            return error_condition == ErrorStanza.CONDITION_NOT_AUTHORIZED ||
                error_condition == ErrorStanza.CONDITION_FORBIDDEN;
        }

        public bool is_item_not_found() {
            return error_condition == ErrorStanza.CONDITION_ITEM_NOT_FOUND;
        }
    }

    public class PublishResult {
        public bool ok;
        public string? error_type;
        public string? error_condition;
        public string? error_text;
        public bool ambiguous { get; private set; default = false; }
        public bool precondition_not_met { get; private set; default = false; }

        public PublishResult(bool ok, string? error_type = null,
                string? error_condition = null, string? error_text = null) {
            this.ok = ok;
            this.error_type = error_type;
            this.error_condition = error_condition;
            this.error_text = error_text;
        }

        internal PublishResult.ambiguous_failure(string? error_text) {
            this(false, null, null, error_text);
            this.ambiguous = true;
        }

        public static PublishResult from_error_stanza(ErrorStanza error) {
            var result = new PublishResult(false, error.type_, error.condition, error.text);
            result.precondition_not_met = error.error_node.get_subnode(
                    "precondition-not-met", NS_URI_ERROR) != null;
            return result;
        }

        public bool is_error(string type_, string condition) {
            return !ok && error_type == type_ && error_condition == condition;
        }

        public string describe_error() {
            if (ok) return "ok";
            if (error_type != null || error_condition != null) {
                return "%s/%s".printf(error_type ?? "unknown", error_condition ?? "unknown");
            }
            return error_text ?? "unknown";
        }
    }

    public class RetractResult {
        public bool ok;
        public string? error_type;
        public string? error_condition;
        public string? error_text;

        public RetractResult(bool ok, string? error_type = null, string? error_condition = null, string? error_text = null) {
            this.ok = ok;
            this.error_type = error_type;
            this.error_condition = error_condition;
            this.error_text = error_text;
        }

        public static RetractResult from_error_stanza(ErrorStanza error) {
            return new RetractResult(false, error.type_, error.condition, error.text);
        }

        public bool is_item_not_found() {
            return !ok && error_condition == ErrorStanza.CONDITION_ITEM_NOT_FOUND;
        }

        public string describe_error() {
            if (ok) return "ok";
            if (error_type != null || error_condition != null) {
                return "%s/%s".printf(error_type ?? "unknown", error_condition ?? "unknown");
            }
            return error_text ?? "unknown";
        }
    }

    public class ItemListenerDelegate {
        public delegate void ResultFunc(XmppStream stream, Jid jid, string id, StanzaNode? node);
        public ResultFunc on_result { get; private owned set; }

        public ItemListenerDelegate(owned ResultFunc on_result) {
            this.on_result = (owned) on_result;
        }
    }

    public class RawItemListenerDelegate {
        public delegate void ResultFunc(XmppStream stream, Jid jid,
            StanzaNode item);
        public ResultFunc on_result { get; private owned set; }

        public RawItemListenerDelegate(owned ResultFunc on_result) {
            this.on_result = (owned) on_result;
        }
    }

    public class RetractListenerDelegate {
        public delegate void ResultFunc(XmppStream stream, Jid jid, string id);
        public ResultFunc on_result { get; private owned set; }

        public RetractListenerDelegate(owned ResultFunc on_result) {
            this.on_result = (owned) on_result;
        }
    }

    public class DeleteListenerDelegate {
        public delegate void ResultFunc(XmppStream stream, Jid jid);
        public ResultFunc on_result { get; private owned set; }

        public DeleteListenerDelegate(owned ResultFunc on_result) {
            this.on_result = (owned) on_result;
        }
    }

}
