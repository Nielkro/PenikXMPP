package eu.siacs.conversations.xmpp.fun;

import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

public final class FunTokens {

    public static final byte LITERAL_STRING_8 = (byte) 0xFA;
    public static final byte LITERAL_STRING_16 = (byte) 0xFB;
    public static final byte LITERAL_STRING_32 = (byte) 0xFC;
    public static final byte JID_BARE = (byte) 0xFD;
    public static final byte JID_FULL = (byte) 0xFE;
    public static final byte CONTENT_EMPTY = 0x00;
    public static final byte CONTENT_TEXT = 0x01;
    public static final byte CONTENT_CHILDREN = 0x02;
    public static final byte CONTENT_MIXED = 0x03;

    public static final String[] TOKENS = {
        // Core Stanzas & Elements (0..19)
        "message", "presence", "iq", "body", "error", "text", "status", "show", "priority", "query",
        "bind", "session", "request", "received", "displayed", "markable", "active", "composing", "paused", "inactive",

        // Chatstates & Common Tags (20..39)
        "gone", "x", "item", "items", "feature", "identity", "forwarded", "delay", "result", "stanza-id",
        "origin-id", "reactions", "reaction", "replace", "enable", "enabled", "resume", "resumed", "failed", "r",

        // Stream & Protocol Tags (40..59)
        "a", "open", "close", "stream:stream", "stream:features", "stream:error", "sm", "csi", "ping", "data",
        "field", "value", "option", "jid", "nick", "subject", "invite", "reason", "actor", "destroy",

        // Attributes (60..79)
        "to", "from", "id", "type", "xmlns", "xml:lang", "version", "stamp", "by", "affiliation",
        "role", "action", "code", "var", "node", "category", "previd", "h", "max", "after",

        // Common Attribute Values (80..109)
        "chat", "groupchat", "normal", "headline", "get", "set", "unavailable", "subscribe", "subscribed", "unsubscribe",
        "unsubscribed", "probe", "available", "away", "dnd", "xa", "both", "none", "owner", "admin",
        "member", "participant", "visitor", "outcast", "moderator", "wait", "cancel", "continue", "modify", "auth",

        // Namespaces (110..149)
        "jabber:client",
        "http://etherx.jabber.org/streams",
        "urn:ietf:params:xml:ns:xmpp-stanzas",
        "urn:ietf:params:xml:ns:xmpp-streams",
        "urn:ietf:params:xml:ns:xmpp-bind",
        "urn:ietf:params:xml:ns:xmpp-session",
        "urn:xmpp:sm:3",
        "urn:xmpp:csi:0",
        "urn:xmpp:receipts",
        "urn:xmpp:chat-markers:0",
        "http://jabber.org/protocol/chatstates",
        "http://jabber.org/protocol/disco#info",
        "http://jabber.org/protocol/disco#items",
        "http://jabber.org/protocol/muc",
        "http://jabber.org/protocol/muc#user",
        "http://jabber.org/protocol/muc#owner",
        "http://jabber.org/protocol/muc#admin",
        "urn:xmpp:mam:2",
        "http://jabber.org/protocol/rsm",
        "urn:xmpp:sid:0",
        "urn:xmpp:reactions:0",
        "urn:xmpp:message-correct:0",
        "urn:xmpp:delay",
        "urn:xmpp:time",
        "urn:xmpp:ping",
        "jabber:x:conference",
        "jabber:x:data",
        "storage:bookmarks",
        "vcard-temp",
        "urn:xmpp:avatar:metadata",
        "urn:xmpp:avatar:data",
        "urn:xmpp:http:upload:0",
        "penik:protocol:funxmpp",

        // Server & Component Domains (143..146)
        "snikket.penik.ru",
        "groups.snikket.penik.ru",
        "share.snikket.penik.ru",
        "push.snikket.penik.ru",

        // Bot Platform (147..152)
        "bot.snikket.penik.ru",
        "markup",
        "row",
        "button",
        "callback",
        "penik:bot:markup"
    };

    private static final Map<String, Integer> TOKEN_LOOKUP;

    static {
        final Map<String, Integer> map = new HashMap<>(TOKENS.length * 2);
        for (int i = 0; i < TOKENS.length; i++) {
            map.put(TOKENS[i], i);
        }
        TOKEN_LOOKUP = Collections.unmodifiableMap(map);
    }

    private FunTokens() {}

    public static Integer getToken(final String string) {
        if (string == null) {
            return null;
        }
        return TOKEN_LOOKUP.get(string);
    }

    public static Integer getToken(final String string, final String negotiatedDict) {
        final Integer token = getToken(string);
        if (token == null) {
            return null;
        }
        if (LTS_V1_HASH.equals(negotiatedDict) && token >= V1_TOKEN_COUNT) {
            return null; // Force literal string fallback for tokens added in v2+
        }
        return token;
    }

    public static final String LTS_V1_HASH = "68a7596d";
    public static final int V1_TOKEN_COUNT = 147;

    public static final String V2_HASH = computeDictHash();
    public static final String DICTIONARY_HASH = V2_HASH;

    public static boolean isSupportedDict(final String dict) {
        return LTS_V1_HASH.equals(dict) || V2_HASH.equals(dict);
    }

    private static String computeDictHash() {
        int hash = 0x811c9dc5;
        for (final String token : TOKENS) {
            final byte[] bytes = token.getBytes(java.nio.charset.StandardCharsets.UTF_8);
            for (final byte b : bytes) {
                hash ^= (b & 0xff);
                hash *= 0x01000193;
            }
            hash ^= 10;
            hash *= 0x01000193;
        }
        return String.format(java.util.Locale.US, "%08x", hash);
    }

    public static String getString(final int tokenId) {
        if (tokenId >= 0 && tokenId < TOKENS.length) {
            return TOKENS[tokenId];
        }
        return null;
    }

    public static String getString(final int tokenId, final String negotiatedDict) {
        if (LTS_V1_HASH.equals(negotiatedDict) && tokenId >= V1_TOKEN_COUNT) {
            return null;
        }
        return getString(tokenId);
    }

    public static final byte[] MAGIC_DIRECT_PXMPP = new byte[] {0x50, 0x58, 0x4D, 0x50}; // "PXMP"
    public static final byte DIRECT_PXMPP_VERSION = 0x01;
    public static final byte FLAG_DIRECT_RESUME = 0x01;

    public static byte[] hexToBytes(final String hex) {
        if (hex == null || hex.length() != 8) {
            return new byte[4];
        }
        final byte[] bytes = new byte[4];
        for (int i = 0; i < 4; i++) {
            bytes[i] = (byte) Integer.parseInt(hex.substring(i * 2, i * 2 + 2), 16);
        }
        return bytes;
    }

    public static String bytesToHex(final byte[] bytes) {
        if (bytes == null) {
            return "";
        }
        final StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (final byte b : bytes) {
            sb.append(String.format(java.util.Locale.US, "%02x", b & 0xff));
        }
        return sb.toString();
    }

    public static byte[] createDirectStreamHeader(final String dictHash, final String domain, final boolean resume) throws java.io.IOException {
        final java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
        out.write(MAGIC_DIRECT_PXMPP);
        out.write(DIRECT_PXMPP_VERSION);
        out.write(resume ? FLAG_DIRECT_RESUME : 0x00);
        out.write(hexToBytes(dictHash != null ? dictHash : DICTIONARY_HASH));
        final java.io.DataOutputStream data = new java.io.DataOutputStream(out);
        FunWriter.writeTokenOrString(data, domain, dictHash);
        data.flush();
        return out.toByteArray();
    }

    public static String readServerStreamHeader(final java.io.InputStream in) throws java.io.IOException {
        final byte[] magic = new byte[4];
        int read = 0;
        while (read < 4) {
            final int r = in.read(magic, read, 4 - read);
            if (r == -1) throw new java.io.EOFException("Premature EOF reading Direct PXMPP magic");
            read += r;
        }
        if (!java.util.Arrays.equals(magic, MAGIC_DIRECT_PXMPP)) {
            throw new java.io.IOException("Invalid Direct PXMPP magic from server: " + java.util.Arrays.toString(magic) + " (ASCII: '" + new String(magic, java.nio.charset.StandardCharsets.ISO_8859_1) + "')");
        }
        final int version = in.read();
        if (version != (DIRECT_PXMPP_VERSION & 0xFF)) {
            throw new java.io.IOException("Unsupported Direct PXMPP version: " + version);
        }
        final int flags = in.read();
        final byte[] hashBytes = new byte[4];
        read = 0;
        while (read < 4) {
            final int r = in.read(hashBytes, read, 4 - read);
            if (r == -1) throw new java.io.EOFException("Premature EOF reading Direct PXMPP dict hash");
            read += r;
        }
        return bytesToHex(hashBytes);
    }
}
