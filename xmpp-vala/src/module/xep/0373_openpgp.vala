/**
 * XEP-0373: OpenPGP for XMPP
 * 
 * This module handles the PubSub-based key distribution for OpenPGP.
 * It publishes and retrieves public keys via PEP (Personal Eventing Protocol).
 * 
 * Nodes:
 * - urn:xmpp:openpgp:0:public-keys - List of public key metadata
 * - urn:xmpp:openpgp:0:public-keys:[fingerprint] - Individual public key data
 * 
 * This complements XEP-0027 (legacy presence signing) with modern PubSub-based
 * key discovery, enabling interoperability with clients like Conversations.
 */

using Gee;

namespace Xmpp.Xep.OpenPgp {

    public const string NS_URI = "urn:xmpp:openpgp:0";
    public const string NS_URI_PUBKEYS = NS_URI + ":public-keys";
    public const string NS_URI_SECRET_KEY = NS_URI + ":secret-key";

    public delegate bool OperationGuard();

    /**
     * Metadata about a published public key
     */
    public class PublicKeyMeta {
        public string fingerprint { get; set; }
        public DateTime? date { get; set; }
        
        public PublicKeyMeta(string fingerprint, DateTime? date = null) {
            this.fingerprint = fingerprint;
            this.date = date;
        }
    }

    /**
     * A full public key with its armored data
     */
    public class PublicKeyData {
        public string fingerprint { get; set; }
        public string key_data_base64 { get; set; }
        public string armored_key {
            get { return key_data_base64; }
            set { key_data_base64 = value; }
        }
        public DateTime? date { get; set; }
        
        public PublicKeyData(string fingerprint, string key_data_base64, DateTime? date = null) {
            this.fingerprint = fingerprint;
            this.key_data_base64 = key_data_base64;
            this.date = date;
        }
    }

    public class Module : XmppStreamModule {
        public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0373_openpgp");

        /**
         * Signal emitted when we receive updated key metadata from a contact
         */
        public signal void public_keys_received(XmppStream stream, Jid jid, Gee.List<PublicKeyMeta> keys);

        /**
         * Signal emitted when a contact advertises one or more keys.  The
         * receiver can use this as an invalidation hint without fetching key
         * material immediately.
         */
        public signal void public_keys_advertised(XmppStream stream, Jid jid, Gee.List<PublicKeyMeta> keys);

        public override void attach(XmppStream stream) {
            // Subscribe to notifications about public key updates
            stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).add_filtered_notification(
                stream, 
                NS_URI_PUBKEYS,
                on_pubkeys_item_received,
                on_pubkeys_item_retracted,
                on_pubkeys_node_deleted
            );
        }

        public override void detach(XmppStream stream) {
            stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY).remove_filtered_notification(stream, NS_URI_PUBKEYS);
        }

        public override string get_ns() { return NS_URI; }
        public override string get_id() { return IDENTITY.id; }

        /**
         * Publish our public key to PEP
         * 
         * This publishes to two nodes:
         * 1. urn:xmpp:openpgp:0:public-keys - metadata list with fingerprint and date
         * 2. urn:xmpp:openpgp:0:public-keys:[fingerprint] - the actual key data
         */
        public async bool publish_key_data(XmppStream stream, string fingerprint, string public_key_data_base64,
                OperationGuard? guard = null) {
            var pubsub = stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY);
            if (guard != null && !guard()) return false;
            
            // Normalize fingerprint (uppercase, no spaces)
            string fp = fingerprint.up().replace(" ", "");
            Gee.List<StanzaNode>? metadata_items = yield fetch_own_metadata_items_checked(stream);
            if (metadata_items == null || (guard != null && !guard())) return false;
            var meta_entries = merge_metadata_entries((!) metadata_items, fp);
            
            debug("XEP-0373: publish_key called with fingerprint: %s", fp);
            
            // First, publish the actual key data to its own node
            string key_node = NS_URI_PUBKEYS + ":" + fp;
            DateTime now = new DateTime.now_utc();
            string date_str = now.format_iso8601();
            
            debug("XEP-0373: Publishing to node: %s", key_node);
            
            // XEP-0373 specifies raw OpenPGP public-key material encoded as Base64:
            // <pubkey><data>[BASE64 KEY BYTES]</data></pubkey>
            StanzaNode pubkey_node = new StanzaNode.build("pubkey", NS_URI)
                .add_self_xmlns()
                .put_node(new StanzaNode.build("data", NS_URI)
                    .put_node(new StanzaNode.text(public_key_data_base64)));
            
            // Publish options for the key node - open access so contacts can retrieve it
            var key_publish_options = new Pubsub.PublishOptions();
            key_publish_options.settings["pubsub#access_model"] = Pubsub.ACCESS_MODEL_OPEN;
            key_publish_options.settings["pubsub#persist_items"] = "true";
            key_publish_options.settings["pubsub#max_items"] = "1";
            
            bool key_published = yield pubsub.publish(stream, null, key_node, date_str, pubkey_node, key_publish_options);
            if (guard != null && !guard()) return false;
            debug("XEP-0373: Key data publish result: %s", key_published ? "SUCCESS" : "FAILED");
            if (!key_published) {
                debug("XEP-0373: Failed to publish public key data to %s", key_node);
                return false;
            }
            
            // The node belongs to the XMPP account, not this device. Preserve
            // keys published by other devices while replacing this fingerprint.
            debug("XEP-0373: Publishing metadata with date: %s", date_str);

            meta_entries.add(new PublicKeyMeta(fp, now));

            StanzaNode pubkeys_list = build_public_keys_list(meta_entries);
            
            // Publish options for the metadata node
            var meta_publish_options = new Pubsub.PublishOptions();
            meta_publish_options.settings["pubsub#access_model"] = Pubsub.ACCESS_MODEL_OPEN;
            meta_publish_options.settings["pubsub#persist_items"] = "true";
            meta_publish_options.settings["pubsub#max_items"] = "1";
            
            // Use a fixed item-id for the metadata (some servers require this)
            bool meta_published = yield pubsub.publish(stream, null, NS_URI_PUBKEYS, "current", pubkeys_list, meta_publish_options);
            if (guard != null && !guard()) return false;
            debug("XEP-0373: Metadata publish result: %s", meta_published ? "SUCCESS" : "FAILED");
            if (!meta_published) {
                debug("XEP-0373: Failed to publish public key metadata to %s", NS_URI_PUBKEYS);
                return false;
            }
            
            debug("XEP-0373: Successfully published public key %s", fp);
            return true;
        }

        /**
         * Unpublish (retract) a public key from PEP.
         * This removes the key data node and updates the metadata list
         * to no longer include this fingerprint.
         *
         * @param stream The XMPP stream
         * @param fingerprint The fingerprint to retract (uppercase, no spaces)
         * @return true if successful
         */
        public async bool unpublish_key(XmppStream stream, string fingerprint, OperationGuard? guard = null) {
            var pubsub = stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY);
            if (guard != null && !guard()) return false;
            
            string fp = fingerprint.up().replace(" ", "");
            string key_node = NS_URI_PUBKEYS + ":" + fp;
            Gee.List<StanzaNode>? metadata_items = yield fetch_own_metadata_items_checked(stream);
            if (metadata_items == null || (guard != null && !guard())) return false;
            var remaining = merge_metadata_entries((!) metadata_items, fp);
            
            debug("XEP-0373: Unpublishing key %s – deleting node %s", fp, key_node);
            
            // 1. Delete the key data node entirely and verify the server result.
            bool key_node_deleted = yield delete_public_key_node_if_present(stream, key_node);
            if (guard != null && !guard()) return false;

            // 2. Remove only this key from the account's metadata. Other devices
            // may have independent keys under the same account.
            var options = new Pubsub.PublishOptions();
            options.settings["pubsub#access_model"] = Pubsub.ACCESS_MODEL_OPEN;
            options.settings["pubsub#persist_items"] = "true";
            options.settings["pubsub#max_items"] = "1";
            bool meta_ok = yield pubsub.publish(stream, null, NS_URI_PUBKEYS, "current",
                build_public_keys_list(remaining), options);
            if (guard != null && !guard()) return false;
            if (meta_ok) meta_ok = yield retract_stale_metadata_items(stream, guard);
            debug("XEP-0373: Metadata updated: %s, key node deleted: %s",
                    meta_ok ? "SUCCESS" : "FAILED", key_node_deleted ? "SUCCESS" : "FAILED");

            return meta_ok && key_node_deleted;
        }

        private async bool delete_public_key_node_if_present(XmppStream stream, string key_node) {
            var request = new Iq.Stanza.set(new StanzaNode.build("pubsub", "http://jabber.org/protocol/pubsub#owner")
                .add_self_xmlns().put_node(new StanzaNode.build("delete", "http://jabber.org/protocol/pubsub#owner")
                    .put_attribute("node", key_node)));
            try {
                Iq.Stanza response = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, request);
                return !response.is_error() || response.get_error()?.condition == ErrorStanza.CONDITION_ITEM_NOT_FOUND;
            } catch (Error error) {
                debug("XEP-0373: Public-key node deletion did not complete: %s", error.message);
                return false;
            }
        }

        public async bool clear_public_keys_metadata(XmppStream stream) {
            var pubsub = stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY);

            var meta_entries = new ArrayList<PublicKeyMeta>();
            StanzaNode updated_list = build_public_keys_list(meta_entries);

            var meta_publish_options = new Pubsub.PublishOptions();
            meta_publish_options.settings["pubsub#access_model"] = Pubsub.ACCESS_MODEL_OPEN;
            meta_publish_options.settings["pubsub#persist_items"] = "true";
            meta_publish_options.settings["pubsub#max_items"] = "1";

            bool current_published = yield pubsub.publish(stream, null, NS_URI_PUBKEYS, "current", updated_list, meta_publish_options);
            if (!current_published) return false;

            // Older DinoX builds and some PubSub servers may still have stale
            // auto-generated metadata items beside "current".  Contacts that
            // interoperate with non-DinoX XEP-0373 publishers may fall back to
            // the latest metadata item when "current" is absent, so remove our
            // stale metadata items best-effort whenever we explicitly disable
            // OpenPGP for XMPP.
            return yield retract_stale_metadata_items(stream);
        }

        private async bool retract_stale_metadata_items(XmppStream stream, OperationGuard? guard = null) {
            if (guard != null && !guard()) return false;
            var pubsub = stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY);
            Jid? own_jid = stream.get_flag(Bind.Flag.IDENTITY)?.my_jid;
            if (own_jid == null) return true;

            var items = yield pubsub.request_all(stream, (!) own_jid.bare_jid, NS_URI_PUBKEYS);
            if (guard != null && !guard()) return false;
            if (items == null) return true;

            bool ok = true;
            foreach (StanzaNode item in items) {
                if (guard != null && !guard()) return false;
                string? id = item.get_attribute("id", Pubsub.NS_URI);
                if (id == null || id == "") {
                    id = item.get_attribute("id");
                }
                if (id == null || id == "" || id == "current") continue;

                bool retracted = yield pubsub.retract_item(stream, null, NS_URI_PUBKEYS, (!) id);
                if (guard != null && !guard()) return false;
                if (!retracted) {
                    warning("XEP-0373: Failed to retract stale metadata item %s", (!) id);
                    ok = false;
                } else {
                    debug("XEP-0373: Retracted stale metadata item %s", (!) id);
                }
            }
            return ok;
        }

        private async Gee.List<StanzaNode>? fetch_own_metadata_items_checked(XmppStream stream) {
            Jid? own_jid = stream.get_flag(Bind.Flag.IDENTITY)?.my_jid;
            if (own_jid == null) return null;
            var result = yield stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY)
                .request_all_with_result(stream, (!) own_jid.bare_jid, NS_URI_PUBKEYS, -1,
                    Pubsub.RequestPurpose.OPPORTUNISTIC_METADATA);
            if (result.is_item_not_found()) return new ArrayList<StanzaNode>();
            if (result.items == null) return null;
            foreach (StanzaNode item in (!) result.items) {
                if (item.get_subnode("public-keys-list", NS_URI) == null) return null;
            }
            return result.items;
        }

        private Gee.List<PublicKeyMeta> merge_metadata_entries(Gee.List<StanzaNode> items, string excluded_fingerprint) {
            var entries = new ArrayList<PublicKeyMeta>();
            var seen = new HashSet<string>();
            foreach (StanzaNode item in items) {
                foreach (PublicKeyMeta entry in parse_public_keys_list_node(item)) {
                    string fingerprint = entry.fingerprint.up().replace(" ", "");
                    if (fingerprint == excluded_fingerprint || seen.contains(fingerprint)) continue;
                    seen.add(fingerprint);
                    entries.add(entry);
                }
            }
            return entries;
        }

        private StanzaNode build_public_keys_list(Gee.List<PublicKeyMeta> entries) {
            StanzaNode pubkeys_list = new StanzaNode.build("public-keys-list", NS_URI).add_self_xmlns();
            foreach (var entry in entries) {
                StanzaNode meta = new StanzaNode.build("pubkey-metadata", NS_URI)
                    .put_attribute("v4-fingerprint", entry.fingerprint.up().replace(" ", ""));
                if (entry.date != null) {
                    meta.put_attribute("date", ((!) entry.date).format_iso8601());
                }
                pubkeys_list.put_node(meta);
            }
            return pubkeys_list;
        }

        /**
         * Retrieve the list of public key metadata from a contact
         */
        public async Gee.List<PublicKeyMeta>? fetch_public_keys_list(XmppStream stream, Jid jid) {
            var pubsub = stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY);
            
            debug("XEP-0373: Fetching public keys list from %s, node: %s", jid.to_string(), NS_URI_PUBKEYS);
            StanzaNode? item = yield pubsub.request_item(stream, jid, NS_URI_PUBKEYS,
                "current", Pubsub.RequestPurpose.STATE_SYNC);
            if (item == null) {
                debug("XEP-0373: No active 'current' metadata item for %s; trying latest metadata item", jid.to_string());
                var items = yield pubsub.request_all(stream, jid, NS_URI_PUBKEYS, 1,
                    Pubsub.RequestPurpose.STATE_SYNC);
                if (items == null) {
                    debug("XEP-0373: PubSub metadata request for %s did not complete", jid.to_string());
                    return null;
                }
                if (items.size == 0) {
                    debug("XEP-0373: PubSub returned no metadata items for %s", jid.to_string());
                    return new ArrayList<PublicKeyMeta>();
                }
                item = items[items.size - 1];
            }

            debug("XEP-0373: Processing active metadata item from %s: %s", jid.to_string(), item.to_string());

            var result = parse_public_keys_list_node(item);
            
            debug("XEP-0373: Found %d public key(s) for %s", result.size, jid.to_string());
            return result;
        }

        /**
         * Retrieve a specific public key from a contact
         */
        public async PublicKeyData? fetch_public_key(XmppStream stream, Jid jid, string fingerprint) {
            var pubsub = stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY);
            
            string fp = fingerprint.up().replace(" ", "");
            string key_node = NS_URI_PUBKEYS + ":" + fp;
            string lowercase_key_node = NS_URI_PUBKEYS + ":" + fp.down();
            
            StanzaNode? key_stanza = null;
            var key_items = yield pubsub.request_all(stream, jid, key_node, 1);
            if (key_items != null && key_items.size > 0) {
                key_stanza = key_items[key_items.size - 1];
            } else if (key_items == null) {
                debug("XEP-0373: Key data node %s from %s did not return a usable item list; trying fingerprint item fallback",
                        key_node, jid.to_string());
            } else {
                debug("XEP-0373: Key data node %s from %s returned no items; trying fingerprint item fallback",
                        key_node, jid.to_string());
            }
            if (key_stanza == null && lowercase_key_node != key_node) {
                // XEP-0373 specifies uppercase OpenPGP fingerprints for the
                // key-data node.  Some clients publish the metadata fingerprint
                // and node id in lowercase.  Keep DinoX canonical internally,
                // but tolerate the lowercase node so those contacts remain
                // interoperable.
                var lowercase_key_items = yield pubsub.request_all(stream, jid, lowercase_key_node, 1);
                if (lowercase_key_items != null && lowercase_key_items.size > 0) {
                    key_stanza = lowercase_key_items[lowercase_key_items.size - 1];
                    debug("XEP-0373: Fetched public key %s from %s via lowercase node compatibility fallback",
                            fp, jid.to_string());
                }
            }
            if (key_stanza == null) {
                // Compatibility fallback for older DinoX builds that used the
                // fingerprint as the PubSub item id for the key payload.
                key_stanza = yield pubsub.request_item(stream, jid, key_node, fp, Pubsub.RequestPurpose.OPPORTUNISTIC_METADATA);
                if (key_stanza != null) {
                    debug("XEP-0373: Fetched public key %s from %s via fingerprint item fallback",
                            fp, jid.to_string());
                }
            }
            if (key_stanza == null) {
                debug("XEP-0373: Could not fetch public key %s from %s; metadata may advertise a key without retrievable key data",
                        fp, jid.to_string());
                return null;
            }

            if (key_stanza.name == "item" && key_stanza.sub_nodes.size > 0) {
                key_stanza = key_stanza.sub_nodes[0];
            }
            
            StanzaNode? data_node = key_stanza.get_subnode("data", NS_URI);
            if (data_node == null) {
                data_node = key_stanza.get_subnode("data"); // Try without namespace
            }
            
            if (data_node == null) {
                debug("XEP-0373: Key node has no data element");
                return null;
            }
            
            string? base64_key = data_node.get_string_content();
            if (base64_key == null) {
                debug("XEP-0373: Key data is empty");
                return null;
            }
            
            debug("XEP-0373: fetch_public_key - base64 key length: %d", base64_key.length);
            debug("XEP-0373: Successfully fetched public key %s from %s", fp, jid.to_string());
            return new PublicKeyData(fp, base64_key);
        }

        /**
         * Retrieve the synchronized encrypted secret key from PEP
         */
        public async string? fetch_secret_key(XmppStream stream) {
            var pubsub = stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY);
            Jid? own_jid = stream.get_flag(Bind.Flag.IDENTITY)?.my_jid;
            if (own_jid == null) return null;
            
            debug("XEP-0373: Fetching secret key from %s", NS_URI_SECRET_KEY);
            var items = yield pubsub.request_all(stream, own_jid.bare_jid, NS_URI_SECRET_KEY, 1);
            if (items == null || items.size == 0) {
                debug("XEP-0373: No secret key found on server");
                return null;
            }
            
            StanzaNode item = items[items.size - 1];
            if (item.name == "item" && item.sub_nodes.size > 0) {
                item = item.sub_nodes[0];
            }
            
            StanzaNode? secret_node = item;
            if (item.name != "secretkey") {
                secret_node = item.get_subnode("secretkey", NS_URI);
                if (secret_node == null) secret_node = item.get_subnode("secretkey");
            }
            
            if (secret_node == null) {
                debug("XEP-0373: Secret key node has no secretkey element");
                return null;
            }
            
            string? base64_key = secret_node.get_string_content();
            if (base64_key == null) {
                debug("XEP-0373: Secret key data is empty");
                return null;
            }
            
            debug("XEP-0373: Successfully fetched secret key, length: %d", base64_key.length);
            return base64_key;
        }

        // Cleanup must distinguish a genuinely absent backup from a failed or
        // malformed response. A failed lookup is never permission to delete a
        // local key or report successful server cleanup.
        public async string? fetch_secret_key_checked(XmppStream stream) throws Error {
            Bind.Flag? bind = stream.get_flag(Bind.Flag.IDENTITY);
            Jid? own_jid = bind?.my_jid;
            if (bind == null || !((!) bind).finished || own_jid == null) {
                throw new IOError.NOT_CONNECTED("No bound account for secret-key backup lookup");
            }
            Jid owner_bare_jid = ((!) own_jid).bare_jid;
            if (owner_bare_jid.localpart == null) {
                throw new IOError.PERMISSION_DENIED("Secret-key backup lookup requires a bound user account");
            }
            var request = new Iq.Stanza.get(new StanzaNode.build("pubsub", Pubsub.NS_URI).add_self_xmlns()
                .put_node(new StanzaNode.build("items", Pubsub.NS_URI)
                    .put_attribute("node", NS_URI_SECRET_KEY).put_attribute("max_items", "1")));
            request.to = owner_bare_jid;
            Iq.Stanza response = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, request);
            bind = stream.get_flag(Bind.Flag.IDENTITY);
            if (bind == null || !((!) bind).finished || ((!) bind).my_jid == null ||
                    !(((!) ((!) bind).my_jid).bare_jid.equals(owner_bare_jid))) {
                throw new IOError.NOT_CONNECTED("Bound account changed during secret-key backup lookup");
            }
            // Missing 'from' means the own bare JID according to RFC 6120.
            // Inspect the raw attribute; Stanza.from's fallback must not turn a
            // malformed or foreign sender into an apparently valid owner.
            string? raw_from = response.stanza.get_attribute("from");
            if (raw_from != null) {
                try {
                    if (!new Jid((!) raw_from).equals(owner_bare_jid)) {
                        throw new IOError.PERMISSION_DENIED("Secret-key backup response has an unexpected sender");
                    }
                } catch (InvalidJidError error) {
                    throw new IOError.INVALID_DATA("Secret-key backup response has an invalid sender");
                }
            }
            if (response.type_ != Iq.Stanza.TYPE_RESULT && !response.is_error()) {
                throw new IOError.INVALID_DATA("Secret-key backup response is not an IQ result or error");
            }
            if (response.is_error()) {
                ErrorStanza? error = response.get_error();
                if (error == null) throw new IOError.INVALID_DATA("Malformed secret-key backup lookup error");
                int conditions = 0;
                foreach (StanzaNode child in checked_element_children(((!) error).error_node)) {
                    if (child.ns_uri == "urn:ietf:params:xml:ns:xmpp-stanzas" && child.name != "text") conditions++;
                }
                if (conditions != 1) throw new IOError.INVALID_DATA("Ambiguous secret-key backup lookup error");
                if (((!) error).condition == ErrorStanza.CONDITION_ITEM_NOT_FOUND) return null;
                throw new IOError.FAILED("Secret-key backup lookup failed: %s".printf(((!) error).condition));
            }
            Gee.List<StanzaNode> children = checked_element_children(response.stanza);
            if (children.size != 1 || children[0].name != "pubsub" || children[0].ns_uri != Pubsub.NS_URI) {
                throw new IOError.INVALID_DATA("Secret-key backup response has no unique PubSub payload");
            }
            Gee.List<StanzaNode> pubsub_children = checked_element_children(children[0]);
            if (pubsub_children.size != 1 || pubsub_children[0].name != "items" || pubsub_children[0].ns_uri != Pubsub.NS_URI ||
                    pubsub_children[0].get_attribute("node") != NS_URI_SECRET_KEY) {
                throw new IOError.INVALID_DATA("Secret-key backup response belongs to another node or has ambiguous items");
            }
            Gee.List<StanzaNode> items = checked_element_children(pubsub_children[0]);
            if (items.size == 0) return null;
            if (items.size != 1 || items[0].name != "item" || items[0].ns_uri != Pubsub.NS_URI) {
                throw new IOError.INVALID_DATA("Server returned invalid secret-key backup items");
            }
            Gee.List<StanzaNode> item_children = checked_element_children(items[0]);
            if (item_children.size != 1 || item_children[0].name != "secretkey" || item_children[0].ns_uri != NS_URI) {
                throw new IOError.INVALID_DATA("Secret-key backup item has no unique encrypted payload");
            }
            foreach (StanzaNode child in item_children[0].sub_nodes) {
                if (child.name != "#text") throw new IOError.INVALID_DATA("Secret-key backup payload contains unexpected elements");
            }
            string? payload = item_children[0].get_string_content();
            if (payload == null || ((!) payload).strip().length == 0) {
                throw new IOError.INVALID_DATA("Secret-key backup response has no encrypted payload");
            }
            return payload;
        }

        private static Gee.List<StanzaNode> checked_element_children(StanzaNode node) throws Error {
            var elements = new ArrayList<StanzaNode>();
            foreach (StanzaNode child in node.sub_nodes) {
                if (child.name == "#text") {
                    if ((child.get_string_content() ?? "").strip() != "") {
                        throw new IOError.INVALID_DATA("Unexpected text in secret-key backup response");
                    }
                } else {
                    elements.add(child);
                }
            }
            return elements;
        }

        /**
         * Publish the synchronized encrypted secret key to PEP
         */
        public async bool publish_secret_key(XmppStream stream, string encrypted_secret_key_base64) {
            var pubsub = stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY);
            
            debug("XEP-0373: Publishing secret key backup to %s", NS_URI_SECRET_KEY);
            
            StanzaNode secret_node = new StanzaNode.build("secretkey", NS_URI)
                .add_self_xmlns()
                .put_node(new StanzaNode.text(encrypted_secret_key_base64));
            
            var publish_options = new Pubsub.PublishOptions();
            publish_options.settings["pubsub#access_model"] = "whitelist"; // Only the owner can access
            publish_options.settings["pubsub#persist_items"] = "true";
            publish_options.settings["pubsub#max_items"] = "1";
            
            bool published = yield pubsub.publish(stream, null, NS_URI_SECRET_KEY, "current", secret_node, publish_options);
            debug("XEP-0373: Secret key publish result: %s", published ? "SUCCESS" : "FAILED");
            return published;
        }

        /**
         * Delete the synchronized encrypted secret key from PEP
         */
        public async bool delete_secret_key(XmppStream stream) {
            var pubsub = stream.get_module<Pubsub.Module>(Pubsub.Module.IDENTITY);
            debug("XEP-0373: Deleting secret key backup node %s", NS_URI_SECRET_KEY);
            return yield pubsub.delete_node_async(stream, null, NS_URI_SECRET_KEY);
        }

        /**
         * Handle incoming PubSub notifications about public key updates
         */
        private void on_pubkeys_item_received(XmppStream stream, Jid jid, string id, StanzaNode? node) {
            if (node == null) {
                debug("XEP-0373: Received public key update without payload from %s; deferring fetch to explicit refresh/send path",
                        jid.to_string());
                return;
            }
            debug("XEP-0373: Received public key update from %s", jid.to_string());
            var result = parse_public_keys_list_node(node);
            if (result.size == 0) {
                public_keys_received(stream, jid, result);
                return;
            }

            public_keys_advertised(stream, jid, result);
            debug("XEP-0373: Deferring import of %d advertised key(s) from %s to explicit refresh/send path",
                    result.size, jid.to_string());
        }

        private void on_pubkeys_item_retracted(XmppStream stream, Jid jid, string id) {
            if (id == "current") {
                debug("XEP-0373: Current public key metadata retracted by %s", jid.to_string());
                public_keys_received(stream, jid, new ArrayList<PublicKeyMeta>());
            }
        }

        private void on_pubkeys_node_deleted(XmppStream stream, Jid jid) {
            debug("XEP-0373: Public key metadata node deleted by %s", jid.to_string());
            public_keys_received(stream, jid, new ArrayList<PublicKeyMeta>());
        }

        private Gee.List<PublicKeyMeta> parse_public_keys_list_node(StanzaNode item) {
            var result = new ArrayList<PublicKeyMeta>();

            StanzaNode? pubkeys_list = item.get_subnode("public-keys-list", NS_URI);
            if (pubkeys_list == null) {
                pubkeys_list = item.get_subnode("public-keys-list");
            }
            if (pubkeys_list == null && item.name == "public-keys-list") {
                pubkeys_list = item;
            }
            if (pubkeys_list == null) {
                debug("XEP-0373: Item has no public-keys-list element");
                return result;
            }

            var meta_nodes = pubkeys_list.get_subnodes("pubkey-metadata", NS_URI);
            if (meta_nodes.size == 0) {
                meta_nodes = pubkeys_list.get_subnodes("pubkey-metadata");
            }

            debug("XEP-0373: Found %d pubkey-metadata node(s)", meta_nodes.size);

            foreach (var meta_node in meta_nodes) {
                string? fp = meta_node.get_attribute("v4-fingerprint");
                string? date_str = meta_node.get_attribute("date");

                if (fp != null) {
                    DateTime? date = null;
                    if (date_str != null) {
                        date = new DateTime.from_iso8601(date_str, new TimeZone.utc());
                    }
                    result.add(new PublicKeyMeta(fp.up(), date));
                }
            }
            return result;
        }
    }
}
