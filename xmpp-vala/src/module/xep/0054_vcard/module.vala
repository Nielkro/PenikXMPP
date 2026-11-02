using Gee;

namespace Xmpp.Xep.VCard {
private const string NS_URI = "vcard-temp";
private const string NS_URI_UPDATE = NS_URI + ":x:update";

public class VCardInfo : Object {
    public string? full_name { get; set; }
    public string? nickname { get; set; }
    public Gee.List<string> emails { get; set; default = new Gee.ArrayList<string>(); }
    public Gee.List<string> phones { get; set; default = new Gee.ArrayList<string>(); }
    public Gee.List<string> urls { get; set; default = new Gee.ArrayList<string>(); }
    public Gee.List<string> roles { get; set; default = new Gee.ArrayList<string>(); }
    public Gee.List<string> titles { get; set; default = new Gee.ArrayList<string>(); }
    public Gee.List<string> organizations { get; set; default = new Gee.ArrayList<string>(); }
    public string? description { get; set; }
    public string? birthday { get; set; }
    public string? adr_street { get; set; }
    public string? adr_locality { get; set; }
    public string? adr_pcode { get; set; }
    public string? adr_region { get; set; }
    public string? adr_country { get; set; }
    public Bytes? photo { get; set; }
    public string? photo_type { get; set; }

    public string? email { 
        owned get { return emails.size > 0 ? emails[0] : null; } 
        set { emails.clear(); if (value != null) emails.add(value); }
    }
    public string? phone { 
        owned get { return phones.size > 0 ? phones[0] : null; } 
        set { phones.clear(); if (value != null) phones.add(value); }
    }
    public string? url { 
        owned get { return urls.size > 0 ? urls[0] : null; } 
        set { urls.clear(); if (value != null) urls.add(value); }
    }
    public string? role { 
        owned get { return roles.size > 0 ? roles[0] : null; } 
        set { roles.clear(); if (value != null) roles.add(value); }
    }
    public string? title { 
        owned get { return titles.size > 0 ? titles[0] : null; } 
        set { titles.clear(); if (value != null) titles.add(value); }
    }
    public string? organization { 
        owned get { return organizations.size > 0 ? organizations[0] : null; } 
        set { organizations.clear(); if (value != null) organizations.add(value); }
    }

    public VCardInfo() {}

    public static VCardInfo from_node(StanzaNode node) {
        var vcard = new VCardInfo();

        vcard.full_name = node.get_subnode("FN")?.get_string_content();
        vcard.nickname = node.get_subnode("NICKNAME")?.get_string_content();
        vcard.birthday = node.get_subnode("BDAY")?.get_string_content();

        foreach (var email_node in node.get_subnodes("EMAIL")) {
            var userid = email_node.get_subnode("USERID")?.get_string_content();
            if (userid != null) vcard.emails.add(userid);
        }

        foreach (var tel_node in node.get_subnodes("TEL")) {
            var number = tel_node.get_subnode("NUMBER")?.get_string_content();
            if (number != null) vcard.phones.add(number);
        }
        
        foreach (var url_node in node.get_subnodes("URL")) {
            var url = url_node.get_string_content();
            if (url != null) vcard.urls.add(url);
        }

        foreach (var role_node in node.get_subnodes("ROLE")) {
            var role = role_node.get_string_content();
            if (role != null) vcard.roles.add(role);
        }

        foreach (var title_node in node.get_subnodes("TITLE")) {
            var title = title_node.get_string_content();
            if (title != null) vcard.titles.add(title);
        }

        foreach (var org_node in node.get_subnodes("ORG")) {
            var org_name = org_node.get_subnode("ORGNAME")?.get_string_content();
            if (org_name != null) vcard.organizations.add(org_name);
            
            foreach (var org_unit in org_node.get_subnodes("ORGUNIT")) {
                var unit = org_unit.get_string_content();
                if (unit != null) vcard.organizations.add(unit);
            }
        }

        // Address - iterate all ADR nodes to find one with data
        foreach (var adr_node in node.get_subnodes("ADR")) {
            var street = adr_node.get_subnode("STREET")?.get_string_content();
            var locality = adr_node.get_subnode("LOCALITY")?.get_string_content();
            var region = adr_node.get_subnode("REGION")?.get_string_content();
            var pcode = adr_node.get_subnode("PCODE")?.get_string_content();
            var country = adr_node.get_subnode("CTRY")?.get_string_content();
            
            // If we found a new address part, update our vcard
            // This is a simple merge strategy: last non-null wins, or first non-null wins?
            // Let's prefer the first one that has data, but fill in gaps from others.
            if (vcard.adr_street == null) vcard.adr_street = street;
            if (vcard.adr_locality == null) vcard.adr_locality = locality;
            if (vcard.adr_region == null) vcard.adr_region = region;
            if (vcard.adr_pcode == null) vcard.adr_pcode = pcode;
            if (vcard.adr_country == null) vcard.adr_country = country;
        }

        vcard.description = node.get_subnode("DESC")?.get_string_content();
        if (vcard.description == null) {
            vcard.description = node.get_subnode("NOTE")?.get_string_content();
        }

        var jabberid = node.get_subnode("JABBERID")?.get_string_content();
        if (jabberid != null) {
            // We don't have a field for this in VCardInfo yet, let's add it or put it in emails/impp?
            // For now, let's add it to emails if it looks like an email, or just ignore it if we don't have a place.
            // Actually, let's add a property for it.
        }

        var photo = node.get_subnode("PHOTO");
        if (photo != null) {
            vcard.photo_type = photo.get_subnode("TYPE")?.get_string_content();
            string? binval = photo.get_subnode("BINVAL")?.get_string_content();
            if (binval != null) {
                // Remove whitespace from base64 string
                string clean_binval = "";
                foreach (string line in binval.split("\n")) {
                    clean_binval += line.strip();
                }
                vcard.photo = new Bytes.take(Base64.decode(clean_binval));
            }
        }
        return vcard;
    }

    private void add_text_node(StanzaNode parent, string name, string content) {
        var child = new StanzaNode.build(name, NS_URI);
        child.put_node(new StanzaNode.text(content));
        parent.put_node(child);
    }

    public StanzaNode to_node() {
        var node = new StanzaNode.build("vCard", NS_URI);
        if (full_name != null) add_text_node(node, "FN", full_name);
        if (nickname != null) add_text_node(node, "NICKNAME", nickname);
        if (birthday != null) add_text_node(node, "BDAY", birthday);
        
        foreach (var email in emails) {
            var email_node = new StanzaNode.build("EMAIL", NS_URI);
            email_node.put_node(new StanzaNode.build("INTERNET", NS_URI));
            email_node.put_node(new StanzaNode.build("PREF", NS_URI));
            add_text_node(email_node, "USERID", email);
            node.put_node(email_node);
        }

        foreach (var phone in phones) {
            var tel_node = new StanzaNode.build("TEL", NS_URI);
            tel_node.put_node(new StanzaNode.build("VOICE", NS_URI));
            add_text_node(tel_node, "NUMBER", phone);
            node.put_node(tel_node);
        }

        if (adr_street != null || adr_locality != null || adr_region != null || adr_pcode != null || adr_country != null) {
            var adr_node = new StanzaNode.build("ADR", NS_URI);
            adr_node.put_node(new StanzaNode.build("HOME", NS_URI));
            if (adr_street != null) add_text_node(adr_node, "STREET", adr_street);
            if (adr_locality != null) add_text_node(adr_node, "LOCALITY", adr_locality);
            if (adr_region != null) add_text_node(adr_node, "REGION", adr_region);
            if (adr_pcode != null) add_text_node(adr_node, "PCODE", adr_pcode);
            if (adr_country != null) add_text_node(adr_node, "CTRY", adr_country);

            node.put_node(adr_node);

            // Add LABEL for compatibility
            var sb = new StringBuilder();
            if (adr_street != null) sb.append(adr_street).append("\n");
            if (adr_pcode != null) sb.append(adr_pcode).append(" ");
            if (adr_locality != null) sb.append(adr_locality).append("\n");
            if (adr_region != null) sb.append(adr_region).append("\n");
            if (adr_country != null) sb.append(adr_country);
            string label_str = sb.str.strip();
            if (label_str != "") {
                var label_node = new StanzaNode.build("LABEL", NS_URI);
                label_node.put_node(new StanzaNode.build("HOME", NS_URI));
                foreach (string line in label_str.split("\n")) {
                    if (line.strip() != "") {
                        label_node.put_node(new StanzaNode.build("LINE", NS_URI).put_node(new StanzaNode.text(line)));
                    }
                }
                node.put_node(label_node);
            }
        }

        foreach (var url in urls) add_text_node(node, "URL", url);
        foreach (var role in roles) add_text_node(node, "ROLE", role);
        foreach (var title in titles) add_text_node(node, "TITLE", title);
        
        if (description != null) add_text_node(node, "DESC", description);
        
        foreach (var org in organizations) {
            var org_node = new StanzaNode.build("ORG", NS_URI);
            add_text_node(org_node, "ORGNAME", org);
            node.put_node(org_node);
        }

        if (photo != null) {
            var photo_node = new StanzaNode.build("PHOTO", NS_URI);
            if (photo_type != null) add_text_node(photo_node, "TYPE", photo_type);
            add_text_node(photo_node, "BINVAL", Base64.encode(photo.get_data()));
            node.put_node(photo_node);
        }
        return node;
    }
}

private string describe_vcard_iq_error(Iq.Stanza iq) {
    ErrorStanza? stanza_error = iq.get_error();
    if (stanza_error == null) return "unknown stanza error";

    string detail = ((!) stanza_error).condition;
    if (((!) stanza_error).text != null && ((!) stanza_error).text != "") {
        detail += ": " + ((!) stanza_error).text;
    }
    return detail;
}

public async VCardInfo? fetch_vcard_checked(XmppStream stream,
        Jid? jid = null) throws Error {
    return yield fetch_vcard_checked_with_cancellable(stream, jid, null);
}

public async VCardInfo? fetch_vcard_checked_with_cancellable(
        XmppStream stream, Jid? jid = null,
        Cancellable? cancellable = null) throws Error {
    Iq.Stanza iq = new Iq.Stanza.get(new StanzaNode.build("vCard", NS_URI).add_self_xmlns());
    if (jid != null) iq.to = jid;

    Iq.Stanza iq_res = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY)
        .send_iq_async(stream, iq, Priority.DEFAULT, cancellable);
    if (iq_res.is_error()) {
        ErrorStanza? stanza_error = iq_res.get_error();
        if (stanza_error != null && ((!) stanza_error).condition ==
                ErrorStanza.CONDITION_ITEM_NOT_FOUND) {
            return null;
        }
        throw new IOError.FAILED("Server rejected vCard query: %s".printf(
            describe_vcard_iq_error(iq_res)));
    }

    var vcard_node = iq_res.stanza.get_subnode("vCard", NS_URI);
    if (vcard_node == null) {
        throw new IOError.INVALID_DATA(
            "The vCard query result is missing its vCard element");
    }

    return VCardInfo.from_node(vcard_node);
}

public async VCardInfo? fetch_vcard(XmppStream stream, Jid? jid = null) {
    return yield fetch_vcard_with_cancellable(stream, jid, null);
}

public async VCardInfo? fetch_vcard_with_cancellable(XmppStream stream,
        Jid? jid = null, Cancellable? cancellable = null) {
    try {
        return yield fetch_vcard_checked_with_cancellable(stream, jid,
            cancellable);
    } catch (GLib.Error e) {
        warning("Failed to fetch vCard: %s", e.message);
        return null;
    }
}

public async void publish_vcard(XmppStream stream, VCardInfo vcard,
        Jid? to = null) throws Error {
    yield publish_vcard_with_cancellable(stream, vcard, to, null);
}

public async void publish_vcard_with_cancellable(XmppStream stream,
        VCardInfo vcard, Jid? to = null,
        Cancellable? cancellable = null) throws Error {
    Iq.Stanza iq = new Iq.Stanza.set(vcard.to_node().add_self_xmlns());
    if (to != null) iq.to = to;
    Iq.Stanza iq_res = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY)
        .send_iq_async(stream, iq, Priority.DEFAULT, cancellable);
    if (iq_res.is_error()) {
        throw new IOError.FAILED("Server rejected vCard update: %s".printf(
            describe_vcard_iq_error(iq_res)));
    }
}

public async Bytes? fetch_image(XmppStream stream, Jid jid, string hash, bool warn_on_error = true, bool validate_hash = true) {
    Iq.Stanza iq = new Iq.Stanza.get(new StanzaNode.build("vCard", NS_URI).add_self_xmlns()) { to=jid };
    Iq.Stanza iq_res;
    try {
        iq_res = yield stream.get_module<Iq.Module>(Iq.Module.IDENTITY).send_iq_async(stream, iq);
    } catch (GLib.Error e) {
        if (warn_on_error) {
            warning("Failed to fetch vCard image: %s", e.message);
        } else {
            debug("Failed to fetch optional vCard image: %s", e.message);
        }
        return null;
    }

    if (iq_res.is_error()) return null;
    string? res = iq_res.stanza.get_deep_string_content(@"$NS_URI:vCard", "PHOTO", "BINVAL");
    if (res == null) return null;
    // Strip whitespace from base64 (servers often return multi-line BINVAL)
    string clean_res = "";
    foreach (string line in res.split("\n")) {
        clean_res += line.strip();
    }
    if (clean_res == "") return null;
    Bytes content = new Bytes.take(Base64.decode(clean_res));
    if (validate_hash) {
        string sha1 = Checksum.compute_for_bytes(ChecksumType.SHA1, content);
        if (sha1 != hash.down()) return null;
    }

    return content;
}

public class Module : XmppStreamModule {
    public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0153_vcard_based_avatars");

    public signal void received_avatar_hash(XmppStream stream, Jid jid, string hash);
    public signal void avatar_removed(XmppStream stream, Jid jid);
    public signal void own_avatar_state_reset_requested(XmppStream stream,
        bool refetch);

    private bool own_avatar_state_known = false;
    private string? own_avatar_hash = null;
    private HashSet<Jid> nonconforming_own_resources = new HashSet<Jid>(
        Jid.hash_func, Jid.equals_func);

    public override void attach(XmppStream stream) {
        Xep.StreamManagement.Flag? stream_management = stream.get_flag<
            Xep.StreamManagement.Flag>(Xep.StreamManagement.Flag.IDENTITY);
        if (stream_management == null || !((!) stream_management).resumed) {
            // The cached module instance is account-scoped, but XEP-0153
            // advertisement state is stream-scoped. A genuinely fresh stream
            // must verify the server vCard again before announcing a hash.
            own_avatar_state_known = false;
            own_avatar_hash = null;
            nonconforming_own_resources.clear();
        }

        Presence.Module presence = stream.get_module<Presence.Module>(
            Presence.Module.IDENTITY);
        presence.received_presence.connect(on_received_presence);
        presence.received_unavailable.connect(on_received_unavailable);
        presence.pre_send_presence_stanza.connect(on_pre_send_presence);
    }

    public override void detach(XmppStream stream) {
        Presence.Module presence = stream.get_module<Presence.Module>(
            Presence.Module.IDENTITY);
        presence.received_presence.disconnect(on_received_presence);
        presence.received_unavailable.disconnect(on_received_unavailable);
        presence.pre_send_presence_stanza.disconnect(on_pre_send_presence);
    }

    public override string get_ns() { return NS_URI; }
    public override string get_id() { return IDENTITY.id; }

    /**
     * Set the verified vCard PHOTO hash for outgoing XEP-0153 presence.
     * A null hash is a known "no avatar" state. Before this method is called,
     * outgoing available presence carries an empty update element without a
     * photo child, which is XEP-0153's unknown/not-ready state.
     * Returns true when the advertised state changed.
     */
    public bool set_own_avatar_hash(string? hash) {
        if (!nonconforming_own_resources.is_empty) {
            // XEP-0153 section 4.3: another own resource that does not support
            // avatar updates may still change the shared vCard. Do not resume
            // advertising until every such resource is gone or conforming.
            own_avatar_state_known = false;
            own_avatar_hash = null;
            return false;
        }
        string? normalized = null;
        if (hash != null) {
            normalized = ((!) hash).strip().down();
            if (!is_sha1_hash((!) normalized)) {
                warning("Refusing invalid own vCard avatar hash");
                return false;
            }
        }

        bool changed = !own_avatar_state_known || own_avatar_hash != normalized;
        own_avatar_state_known = true;
        own_avatar_hash = normalized;
        return changed;
    }

    /**
     * Forget the locally verified vCard PHOTO state after an ambiguous
     * publication lifecycle. Until the server vCard is fetched again,
     * outgoing XEP-0153 presence advertises support without a photo claim.
     */
    public bool invalidate_own_avatar_state() {
        bool changed = own_avatar_state_known || own_avatar_hash != null;
        own_avatar_state_known = false;
        own_avatar_hash = null;
        return changed;
    }

    private static bool is_sha1_hash(string hash) {
        if (hash.length != 40) return false;
        for (int i = 0; i < hash.length; i++) {
            char c = hash[i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
                return false;
            }
        }
        return true;
    }

    private void on_pre_send_presence(XmppStream stream,
            Presence.Stanza presence) {
        if (presence.type_ != Presence.Stanza.TYPE_AVAILABLE) return;

        StanzaNode? previous = presence.stanza.get_subnode("x",
            NS_URI_UPDATE);
        if (previous != null) presence.stanza.sub_nodes.remove((!) previous);

        StanzaNode update = new StanzaNode.build("x", NS_URI_UPDATE)
            .add_self_xmlns();
        if (own_avatar_state_known) {
            StanzaNode photo = new StanzaNode.build("photo", NS_URI_UPDATE);
            if (own_avatar_hash != null) {
                photo.put_node(new StanzaNode.text((!) own_avatar_hash));
            }
            update.put_node(photo);
        }
        presence.stanza.put_node(update);
    }

    private void on_received_presence(XmppStream stream, Presence.Stanza presence) {
        if (presence.type_ != Presence.Stanza.TYPE_AVAILABLE) {
            return;
        }
        StanzaNode? update_node = presence.stanza.get_subnode("x", NS_URI_UPDATE);
        if (is_other_own_resource(stream, presence.from)) {
            handle_other_own_resource_presence(stream, presence.from,
                update_node);
            return;
        }
        if (update_node == null) return;
        StanzaNode? photo_node = update_node.get_subnode("photo", NS_URI_UPDATE);
        if (photo_node == null) return;
        string? sha1 = photo_node.get_string_content();
        if (sha1 == null || sha1.strip() == "") {
            // XEP-0153 section 3.1: an empty photo element explicitly means
            // that the entity is not advertising a vCard-based avatar.
            avatar_removed(stream, presence.from);
            return;
        }
        received_avatar_hash(stream, presence.from, sha1);
    }

    private bool is_other_own_resource(XmppStream stream, Jid from) {
        Bind.Flag? bind = stream.get_flag<Bind.Flag>(Bind.Flag.IDENTITY);
        Jid? own = bind != null ? ((!) bind).my_jid : null;
        return own != null && from.is_full() && from.equals_bare((!) own) &&
            !from.equals((!) own);
    }

    private void handle_other_own_resource_presence(XmppStream stream,
            Jid from, StanzaNode? update_node) {
        if (update_node == null) {
            if (nonconforming_own_resources.add(from)) {
                own_avatar_state_reset_requested(stream, false);
            }
            return;
        }

        bool was_nonconforming = nonconforming_own_resources.remove(from);
        StanzaNode? photo_node = ((!) update_node).get_subnode("photo",
            NS_URI_UPDATE);
        if (photo_node == null) {
            // A conforming resource that is not yet ready does not claim a
            // change. If it was the last nonconforming resource, recover the
            // state that we deliberately stopped advertising.
            if (was_nonconforming && nonconforming_own_resources.is_empty) {
                own_avatar_state_reset_requested(stream, true);
            }
            return;
        }

        string? announced = ((!) photo_node).get_string_content();
        if (announced == null || ((!) announced).strip() == "") {
            own_avatar_state_reset_requested(stream, true);
            return;
        }

        string normalized = ((!) announced).strip().down();
        if (!is_sha1_hash(normalized) || !own_avatar_state_known ||
                own_avatar_hash != normalized) {
            own_avatar_state_reset_requested(stream, true);
        }
    }

    private void on_received_unavailable(XmppStream stream,
            Presence.Stanza presence) {
        if (!is_other_own_resource(stream, presence.from) ||
                !nonconforming_own_resources.remove(presence.from) ||
                !nonconforming_own_resources.is_empty) return;
        own_avatar_state_reset_requested(stream, true);
    }
}
}
