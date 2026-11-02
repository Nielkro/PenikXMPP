using Gee;
using Omemo;
using Xmpp;

namespace Dino.Plugins.Omemo {

public class Bundle {
    public StanzaNode? node;

    public Bundle (StanzaNode? node) {
        this.node = node;
        Plugin.ensure_context ();
    }

    private static int32 parse_positive_id (string? id) {
        if (id == null || ((!) id).length == 0) return -1;
        for (int i = 0; i < ((!) id).length; i++) {
            if (!((!) id)[i].isdigit ()) return -1;
        }
        int32 parsed = int.parse ((!) id);
        return parsed > 0 ? parsed : -1;
    }

    public int32 signed_pre_key_id { get {
        if (node == null) return -1;
        string? id = ((!)node).get_deep_attribute ("signedPreKeyPublic", "signedPreKeyId");
        return parse_positive_id (id);
    }}

    public ECPublicKey? signed_pre_key { owned get {
        if (node == null) return null;
        string? key = ((!)node).get_deep_string_content ("signedPreKeyPublic");
        if (key == null) return null;
        try {
            return Plugin.get_context ().decode_public_key (Base64.decode ((!)key));
        } catch (Error e) {
            return null;
        }
    }}

    public uint8[]? signed_pre_key_signature { owned get {
        if (node == null) return null;
        string? sig = ((!)node).get_deep_string_content ("signedPreKeySignature");
        if (sig == null) return null;
        return Base64.decode ((!)sig);
    }}

    public ECPublicKey? identity_key { owned get {
        if (node == null) return null;
        string? key = ((!)node).get_deep_string_content ("identityKey");
        if (key == null) return null;
        try {
            return Plugin.get_context ().decode_public_key (Base64.decode ((!)key));
        } catch (Error e) {
            return null;
        }
    }}

    public ArrayList<PreKey> pre_keys { owned get {
        ArrayList<PreKey> list = new ArrayList<PreKey> ();
        if (node == null || ((!)node).get_subnode ("prekeys") == null) return list;
        ((!)node).get_deep_subnodes ("prekeys", "preKeyPublic")
                .filter ((node) => ((!)node).get_attribute ("preKeyId") != null)
                .map<PreKey> (PreKey.create)
                .foreach ((key) => list.add (key));
        return list;
    }}

    public class PreKey {
        private StanzaNode node;

        public static PreKey create (owned StanzaNode node) {
            return new PreKey (node);
        }

        public PreKey (StanzaNode node) {
            this.node = node;
        }

        public int32 key_id { get {
            return Bundle.parse_positive_id (node.get_attribute ("preKeyId"));
        }}

        public ECPublicKey? key { owned get {
            string? key = node.get_string_content ();
            if (key == null) return null;
            try {
                return Plugin.get_context ().decode_public_key (Base64.decode ((!)key));
            } catch (Error e) {
                return null;
            }
        }}
    }
}

}
