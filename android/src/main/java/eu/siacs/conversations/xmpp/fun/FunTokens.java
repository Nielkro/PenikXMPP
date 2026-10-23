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

    public static final String DICTIONARY_HASH = computeDictHash();

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
}
