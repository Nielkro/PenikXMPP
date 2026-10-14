-- mod_funxmpp.lua
-- FunXMPP binary tokenized protocol for Snikket / Prosody
-- Provides TLV-safe binary stanza exchange with PenikXMPP clients

module:set_global();

local st = require "util.stanza";

local FUN_NS = "penik:protocol:funxmpp";

local LITERAL_STRING_8 = 0xFA;
local LITERAL_STRING_16 = 0xFB;
local CONTENT_EMPTY = 0x00;
local CONTENT_TEXT = 0x01;
local CONTENT_CHILDREN = 0x02;

local TOKENS = {
    -- Core Stanzas & Elements (0..19)
    [0] = "message", [1] = "presence", [2] = "iq", [3] = "body", [4] = "error",
    [5] = "text", [6] = "status", [7] = "show", [8] = "priority", [9] = "query",
    [10] = "bind", [11] = "session", [12] = "request", [13] = "received", [14] = "displayed",
    [15] = "markable", [16] = "active", [17] = "composing", [18] = "paused", [19] = "inactive",

    -- Chatstates & Common Tags (20..39)
    [20] = "gone", [21] = "x", [22] = "item", [23] = "items", [24] = "feature",
    [25] = "identity", [26] = "forwarded", [27] = "delay", [28] = "result", [29] = "stanza-id",
    [30] = "origin-id", [31] = "reactions", [32] = "reaction", [33] = "replace", [34] = "enable",
    [35] = "enabled", [36] = "resume", [37] = "resumed", [38] = "failed", [39] = "r",

    -- Stream & Protocol Tags (40..59)
    [40] = "a", [41] = "open", [42] = "close", [43] = "stream:stream", [44] = "stream:features",
    [45] = "stream:error", [46] = "sm", [47] = "csi", [48] = "ping", [49] = "data",
    [50] = "field", [51] = "value", [52] = "option", [53] = "jid", [54] = "nick",
    [55] = "subject", [56] = "invite", [57] = "reason", [58] = "actor", [59] = "destroy",

    -- Attributes (60..79)
    [60] = "to", [61] = "from", [62] = "id", [63] = "type", [64] = "xmlns",
    [65] = "xml:lang", [66] = "version", [67] = "stamp", [68] = "by", [69] = "affiliation",
    [70] = "role", [71] = "action", [72] = "code", [73] = "var", [74] = "node",
    [75] = "category", [76] = "previd", [77] = "h", [78] = "max", [79] = "after",

    -- Common Attribute Values (80..109)
    [80] = "chat", [81] = "groupchat", [82] = "normal", [83] = "headline", [84] = "get",
    [85] = "set", [86] = "unavailable", [87] = "subscribe", [88] = "subscribed", [89] = "unsubscribe",
    [90] = "unsubscribed", [91] = "probe", [92] = "available", [93] = "away", [94] = "dnd",
    [95] = "xa", [96] = "both", [97] = "none", [98] = "owner", [99] = "admin",
    [100] = "member", [101] = "participant", [102] = "visitor", [103] = "outcast", [104] = "moderator",
    [105] = "participant", [106] = "cancel", [107] = "continue", [108] = "modify", [109] = "auth",

    -- Namespaces (110..149)
    [110] = "jabber:client",
    [111] = "http://etherx.jabber.org/streams",
    [112] = "urn:ietf:params:xml:ns:xmpp-stanzas",
    [113] = "urn:ietf:params:xml:ns:xmpp-streams",
    [114] = "urn:ietf:params:xml:ns:xmpp-bind",
    [115] = "urn:ietf:params:xml:ns:xmpp-session",
    [116] = "urn:xmpp:sm:3",
    [117] = "urn:xmpp:csi:0",
    [118] = "urn:xmpp:receipts",
    [119] = "urn:xmpp:chat-markers:0",
    [120] = "http://jabber.org/protocol/chatstates",
    [121] = "http://jabber.org/protocol/disco#info",
    [122] = "http://jabber.org/protocol/disco#items",
    [123] = "http://jabber.org/protocol/muc",
    [124] = "http://jabber.org/protocol/muc#user",
    [125] = "http://jabber.org/protocol/muc#owner",
    [126] = "http://jabber.org/protocol/muc#admin",
    [127] = "urn:xmpp:mam:2",
    [128] = "http://jabber.org/protocol/rsm",
    [129] = "urn:xmpp:sid:0",
    [130] = "urn:xmpp:reactions:0",
    [131] = "urn:xmpp:message-correct:0",
    [132] = "urn:xmpp:delay",
    [133] = "urn:xmpp:time",
    [134] = "urn:xmpp:ping",
    [135] = "jabber:x:conference",
    [136] = "jabber:x:data",
    [137] = "storage:bookmarks",
    [138] = "vcard-temp",
    [139] = "urn:xmpp:avatar:metadata",
    [140] = "urn:xmpp:avatar:data",
    [141] = "urn:xmpp:http:upload:0",
    [142] = "penik:protocol:funxmpp",
};

local TOKEN_LOOKUP = {};
for id, str in pairs(TOKENS) do
    TOKEN_LOOKUP[str] = id;
end

-- Helper: encode string or token
local function write_token_or_string(buf, str)
    str = str or "";
    local token = TOKEN_LOOKUP[str];
    if token and token >= 0 and token < 240 then
        table.insert(buf, string.char(token));
    else
        local len = #str;
        if len <= 255 then
            table.insert(buf, string.char(LITERAL_STRING_8, len));
            table.insert(buf, str);
        else
            local hi = math.floor(len / 256);
            local lo = len % 256;
            table.insert(buf, string.char(LITERAL_STRING_16, hi, lo));
            table.insert(buf, str);
        end
    end
end

-- Encode Stanza to FunXMPP binary node
local function encode_stanza(stanza)
    local body_buf = {};

    -- 1. Tag name
    write_token_or_string(body_buf, stanza.name);

    -- 2. Attributes
    local attr_list = {};
    for k, v in pairs(stanza.attr) do
        table.insert(attr_list, { k, tostring(v) });
    end
    table.insert(body_buf, string.char(#attr_list));
    for _, attr in ipairs(attr_list) do
        write_token_or_string(body_buf, attr[1]);
        write_token_or_string(body_buf, attr[2]);
    end

    -- 3. Content: children vs text vs empty
    local child_tags = {};
    local text_parts = {};
    for _, child in ipairs(stanza) do
        if type(child) == "table" and child.name then
            table.insert(child_tags, child);
        elseif type(child) == "string" then
            table.insert(text_parts, child);
        end
    end

    if #child_tags > 0 then
        table.insert(body_buf, string.char(CONTENT_CHILDREN));
        local hi = math.floor(#child_tags / 256);
        local lo = #child_tags % 256;
        table.insert(body_buf, string.char(hi, lo));
        for _, child in ipairs(child_tags) do
            table.insert(body_buf, encode_stanza(child));
        end
    elseif #text_parts > 0 then
        local full_text = table.concat(text_parts);
        local len = #full_text;
        local hi = math.floor(len / 256);
        local lo = len % 256;
        table.insert(body_buf, string.char(CONTENT_TEXT, hi, lo));
        table.insert(body_buf, full_text);
    else
        table.insert(body_buf, string.char(CONTENT_EMPTY));
    end

    local body_str = table.concat(body_buf);
    local body_len = #body_str;
    local len_hi = math.floor(body_len / 256);
    local len_lo = body_len % 256;

    return string.char(len_hi, len_lo) .. body_str;
end

-- Hook: Stream features
module:hook("stream-features", function(event)
    local origin, features = event.origin, event.features;
    if not origin.funxmpp_enabled and origin.type == "c2s" then
        features:tag("funxmpp", { xmlns = FUN_NS, version = "1" }):up();
    end
end);

-- Hook: Stanza negotiation
module:hook("stanza/" .. FUN_NS .. ":enable", function(event)
    local session = event.origin;
    module:log("info", "Client requested FunXMPP binary protocol: %s", session.full_jid or session.ip);
    session.funxmpp_enabled = true;
    session.send(st.stanza("enabled", { xmlns = FUN_NS }));
    return true;
end);

module:log("info", "mod_funxmpp initialized for high-performance mobile binary framing");
