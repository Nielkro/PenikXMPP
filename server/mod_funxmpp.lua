-- mod_funxmpp.lua
-- FunXMPP binary tokenized protocol for Snikket / Prosody
-- Provides TLV-safe binary stanza exchange with PenikXMPP clients

local st = require "util.stanza";
local filters = require "util.filters";
local core_process_stanza = prosody.core_process_stanza;

local FUN_NS = "penik:protocol:funxmpp";

local LITERAL_STRING_8 = 0xFA;
local LITERAL_STRING_16 = 0xFB;
local LITERAL_STRING_32 = 0xFC;
local JID_BARE = 0xFD;
local JID_FULL = 0xFE;
local CONTENT_EMPTY = 0x00;
local CONTENT_TEXT = 0x01;
local CONTENT_CHILDREN = 0x02;
local CONTENT_MIXED = 0x03;

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
    [105] = "wait", [106] = "cancel", [107] = "continue", [108] = "modify", [109] = "auth",

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

    -- Server & Component Domains (143..146)
    [143] = "snikket.penik.ru",
    [144] = "groups.snikket.penik.ru",
    [145] = "share.snikket.penik.ru",
    [146] = "push.snikket.penik.ru",
};

local TOKEN_LOOKUP = {};
for id, str in pairs(TOKENS) do
    TOKEN_LOOKUP[str] = id;
end

-- Deterministic 32-bit FNV-1a dictionary checksum matching client algorithm
local function compute_dict_hash(tokens)
    local bxor;
    if rawget(_G, "bit") and bit.bxor then
        bxor = bit.bxor;
    elseif rawget(_G, "bit32") and bit32.bxor then
        bxor = bit32.bxor;
    else
        local ok, b = pcall(require, "bit");
        if ok and b.bxor then
            bxor = b.bxor;
        else
            local ok2, b2 = pcall(require, "bit32");
            if ok2 and b2.bxor then
                bxor = b2.bxor;
            end
        end
    end
    if not bxor then
        local ok, f = pcall(load, "return function(a, b) return (a ~ b) & 0xffffffff end");
        if ok and f then bxor = f(); end
    end
    if not bxor then
        bxor = function(a, b)
            local r = 0;
            local p = 1;
            for _ = 1, 32 do
                local bit_a = a % 2;
                local bit_b = b % 2;
                if bit_a ~= bit_b then
                    r = r + p;
                end
                a = math.floor(a / 2);
                b = math.floor(b / 2);
                p = p * 2;
            end
            return r;
        end
    end

    local hash = 0x811c9dc5;
    local FNV_PRIME = 0x01000193;
    local MOD32 = 0x100000000;

    local i = 0;
    while tokens[i] ~= nil do
        local token = tokens[i];
        for j = 1, #token do
            local b = token:byte(j);
            hash = bxor(hash, b);
            hash = (hash * FNV_PRIME) % MOD32;
        end
        hash = bxor(hash, 10);
        hash = (hash * FNV_PRIME) % MOD32;
        i = i + 1;
    end
    return string.format("%08x", hash);
end

local DICTIONARY_HASH = compute_dict_hash(TOKENS);

-- Helper: encode string or token with 8/16/32-bit length
local function write_token_or_string(buf, str)
    str = str or "";
    local token = TOKEN_LOOKUP[str];
    if token and token >= 0 and token < 240 then
        table.insert(buf, string.char(token));
        return;
    end

    local at_pos = str:find("@", 1, true);
    if at_pos and at_pos > 1 then
        local slash_pos = str:find("/", at_pos + 1, true);
        if not slash_pos then
            local user = str:sub(1, at_pos - 1);
            local domain = str:sub(at_pos + 1);
            local domain_token = TOKEN_LOOKUP[domain];
            if domain_token and domain_token >= 0 and domain_token < 240 then
                table.insert(buf, string.char(JID_BARE));
                write_token_or_string(buf, user);
                table.insert(buf, string.char(domain_token));
                return;
            end
        else
            local user = str:sub(1, at_pos - 1);
            local domain = str:sub(at_pos + 1, slash_pos - 1);
            local domain_token = TOKEN_LOOKUP[domain];
            if domain_token and domain_token >= 0 and domain_token < 240 then
                local resource = str:sub(slash_pos + 1);
                table.insert(buf, string.char(JID_FULL));
                write_token_or_string(buf, user);
                table.insert(buf, string.char(domain_token));
                write_token_or_string(buf, resource);
                return;
            end
        end
    end

    local len = #str;
    if len <= 255 then
        table.insert(buf, string.char(LITERAL_STRING_8, len));
        table.insert(buf, str);
    elseif len <= 65535 then
        local hi = math.floor(len / 256);
        local lo = len % 256;
        table.insert(buf, string.char(LITERAL_STRING_16, hi, lo));
        table.insert(buf, str);
    else
        local b1 = math.floor(len / 16777216) % 256;
        local b2 = math.floor(len / 65536) % 256;
        local b3 = math.floor(len / 256) % 256;
        local b4 = len % 256;
        table.insert(buf, string.char(LITERAL_STRING_32, b1, b2, b3, b4));
        table.insert(buf, str);
    end
end

-- Helper: read token or string with 8/16/32-bit length
local function read_token_or_string(data, pos)
    if pos > #data then return nil, pos end
    local b = data:byte(pos);
    pos = pos + 1;
    if b == LITERAL_STRING_8 then
        if pos > #data then return "", pos end
        local len = data:byte(pos);
        pos = pos + 1;
        local s = data:sub(pos, pos + len - 1);
        return s, pos + len;
    elseif b == LITERAL_STRING_16 then
        if pos + 1 > #data then return "", pos end
        local hi = data:byte(pos);
        local lo = data:byte(pos + 1);
        local len = hi * 256 + lo;
        pos = pos + 2;
        local s = data:sub(pos, pos + len - 1);
        return s, pos + len;
    elseif b == LITERAL_STRING_32 then
        if pos + 3 > #data then return "", pos end
        local b1, b2, b3, b4 = data:byte(pos, pos + 3);
        local len = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4;
        pos = pos + 4;
        local s = data:sub(pos, pos + len - 1);
        return s, pos + len;
    elseif b == JID_BARE then
        local user;
        user, pos = read_token_or_string(data, pos);
        if pos > #data then return (user or "") .. "@unknown", pos end
        local domain_token = data:byte(pos);
        pos = pos + 1;
        local domain = TOKENS[domain_token] or ("unknown_0x" .. string.format("%x", domain_token));
        return (user or "") .. "@" .. domain, pos;
    elseif b == JID_FULL then
        local user;
        user, pos = read_token_or_string(data, pos);
        if pos > #data then return (user or "") .. "@unknown", pos end
        local domain_token = data:byte(pos);
        pos = pos + 1;
        local domain = TOKENS[domain_token] or ("unknown_0x" .. string.format("%x", domain_token));
        local resource;
        resource, pos = read_token_or_string(data, pos);
        return (user or "") .. "@" .. domain .. "/" .. (resource or ""), pos;
    else
        local token = TOKENS[b];
        if token then
            return token, pos;
        else
            return "unknown_0x" .. string.format("%x", b), pos;
        end
    end
end

-- Encode Stanza to FunXMPP binary node
local function encode_stanza(stanza, parent_ns)
    local body_buf = {};

    -- 1. Tag name
    write_token_or_string(body_buf, stanza.name);

    -- Current namespace resolution
    local current_ns = stanza.attr.xmlns or parent_ns or "jabber:client";

    -- 2. Attributes (sorted deterministically)
    local attr_list = {};
    for k, v in pairs(stanza.attr) do
        if k == "xmlns" then
            if v ~= parent_ns then
                table.insert(attr_list, { k, tostring(v) });
            end
        else
            table.insert(attr_list, { k, tostring(v) });
        end
    end
    table.sort(attr_list, function(a, b) return a[1] < b[1] end);

    table.insert(body_buf, string.char(#attr_list));
    for _, attr in ipairs(attr_list) do
        write_token_or_string(body_buf, attr[1]);
        write_token_or_string(body_buf, attr[2]);
    end

    -- 3. Content: Children vs Text vs Mixed vs Empty
    local child_tags = {};
    local text_parts = {};
    for _, child in ipairs(stanza) do
        if type(child) == "table" and child.name then
            table.insert(child_tags, child);
        elseif type(child) == "string" and child ~= "" then
            table.insert(text_parts, child);
        end
    end

    local has_children = #child_tags > 0;
    local has_text = #text_parts > 0;

    if has_children and has_text then
        table.insert(body_buf, string.char(CONTENT_MIXED));
        local full_text = table.concat(text_parts);
        local tlen = #full_text;
        if tlen < 0xFFFF then
            local hi = math.floor(tlen / 256);
            local lo = tlen % 256;
            table.insert(body_buf, string.char(hi, lo));
        else
            local b1 = math.floor(tlen / 16777216) % 256;
            local b2 = math.floor(tlen / 65536) % 256;
            local b3 = math.floor(tlen / 256) % 256;
            local b4 = tlen % 256;
            table.insert(body_buf, string.char(0xFF, 0xFF, b1, b2, b3, b4));
        end
        table.insert(body_buf, full_text);

        local hi = math.floor(#child_tags / 256);
        local lo = #child_tags % 256;
        table.insert(body_buf, string.char(hi, lo));
        for _, child in ipairs(child_tags) do
            table.insert(body_buf, encode_stanza(child, current_ns));
        end
    elseif has_children then
        table.insert(body_buf, string.char(CONTENT_CHILDREN));
        local hi = math.floor(#child_tags / 256);
        local lo = #child_tags % 256;
        table.insert(body_buf, string.char(hi, lo));
        for _, child in ipairs(child_tags) do
            table.insert(body_buf, encode_stanza(child, current_ns));
        end
    elseif has_text then
        local full_text = table.concat(text_parts);
        local tlen = #full_text;
        if tlen < 0xFFFF then
            local hi = math.floor(tlen / 256);
            local lo = tlen % 256;
            table.insert(body_buf, string.char(CONTENT_TEXT, hi, lo));
        else
            local b1 = math.floor(tlen / 16777216) % 256;
            local b2 = math.floor(tlen / 65536) % 256;
            local b3 = math.floor(tlen / 256) % 256;
            local b4 = tlen % 256;
            table.insert(body_buf, string.char(CONTENT_TEXT, 0xFF, 0xFF, b1, b2, b3, b4));
        end
        table.insert(body_buf, full_text);
    else
        table.insert(body_buf, string.char(CONTENT_EMPTY));
    end

    local body_str = table.concat(body_buf);
    local body_len = #body_str;

    if body_len < 0xFFFF then
        local len_hi = math.floor(body_len / 256);
        local len_lo = body_len % 256;
        return string.char(len_hi, len_lo) .. body_str;
    else
        local b1 = math.floor(body_len / 16777216) % 256;
        local b2 = math.floor(body_len / 65536) % 256;
        local b3 = math.floor(body_len / 256) % 256;
        local b4 = body_len % 256;
        return string.char(0xFF, 0xFF, b1, b2, b3, b4) .. body_str;
    end
end

local MAX_FRAME_SIZE = module:get_option_number("funxmpp_max_frame_size", 1024 * 1024); -- 1 MB limit (guards against expansion attacks)

-- Decode FunXMPP binary node to Prosody Stanza
local function decode_node(data, pos, parent_ns)
    if pos > #data then return nil, pos end

    local tag_name;
    tag_name, pos = read_token_or_string(data, pos);
    if not tag_name then return nil, pos end

    local attr_count = data:byte(pos) or 0;
    pos = pos + 1;
    local attr = {};
    for _ = 1, attr_count do
        local k, v;
        k, pos = read_token_or_string(data, pos);
        v, pos = read_token_or_string(data, pos);
        if k and v then
            attr[k] = v;
        end
    end

    local ns = attr.xmlns or parent_ns or "jabber:client";
    if ns == (parent_ns or "jabber:client") then
        attr.xmlns = nil;
    else
        attr.xmlns = ns;
    end
    local stanza = st.stanza(tag_name, attr);

    local content_type = data:byte(pos) or 0;
    pos = pos + 1;

    local function read_child_nodes()
        if pos + 1 > #data then return end
        local count = data:byte(pos) * 256 + data:byte(pos + 1);
        pos = pos + 2;
        for _ = 1, count do
            if pos + 1 > #data then break end
            local child_len = data:byte(pos) * 256 + data:byte(pos + 1);
            pos = pos + 2;
            if child_len == 0xFFFF then
                if pos + 3 > #data then break end
                local b1, b2, b3, b4 = data:byte(pos, pos + 3);
                child_len = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4;
                pos = pos + 4;
            end
            local expected_end_pos = pos + child_len;
            local child_stanza = decode_node(data, pos, ns);
            if child_stanza then
                stanza:add_child(child_stanza);
            end
            pos = expected_end_pos;
        end
    end

    local function read_text_content()
        if pos + 1 > #data then return end
        local text_len = data:byte(pos) * 256 + data:byte(pos + 1);
        pos = pos + 2;
        if text_len == 0xFFFF then
            if pos + 3 > #data then return end
            local b1, b2, b3, b4 = data:byte(pos, pos + 3);
            text_len = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4;
            pos = pos + 4;
        end
        local text = data:sub(pos, pos + text_len - 1);
        pos = pos + text_len;
        stanza:text(text);
    end

    if content_type == CONTENT_CHILDREN then
        read_child_nodes();
    elseif content_type == CONTENT_TEXT then
        read_text_content();
    elseif content_type == CONTENT_MIXED then
        read_text_content();
        read_child_nodes();
    end

    return stanza, pos;
end

-- Incoming byte filter for FunXMPP frames
local function funxmpp_bytes_in(data, session)
    if not session.funxmpp_enabled then
        return data;
    end
    session.funxmpp_in_buf = (session.funxmpp_in_buf or "") .. data;
    while #session.funxmpp_in_buf >= 2 do
        local len = session.funxmpp_in_buf:byte(1) * 256 + session.funxmpp_in_buf:byte(2);
        local header_size = 2;
        if len == 0xFFFF then
            if #session.funxmpp_in_buf < 6 then break end
            local b1, b2, b3, b4 = session.funxmpp_in_buf:byte(3, 6);
            len = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4;
            header_size = 6;
        end

        if len > MAX_FRAME_SIZE then
            module:log("warn", "FunXMPP frame size limit exceeded (%d > %d) from %s, terminating session",
                len, MAX_FRAME_SIZE, session.full_jid or session.ip or "unknown");
            session.funxmpp_in_buf = "";
            session.funxmpp_enabled = false;
            session:close({
                condition = "policy-violation",
                text = "FunXMPP frame size exceeded maximum allowed limit"
            });
            return "";
        end

        if #session.funxmpp_in_buf < header_size + len then
            break;
        end
        local frame = session.funxmpp_in_buf:sub(header_size + 1, header_size + len);
        session.funxmpp_in_buf = session.funxmpp_in_buf:sub(header_size + len + 1);

        if session.funxmpp_stats then
            session.funxmpp_stats.in_bytes = session.funxmpp_stats.in_bytes + header_size + len;
            session.funxmpp_stats.in_frames = session.funxmpp_stats.in_frames + 1;
        end

        local stanza = decode_node(frame, 1, "jabber:client");
        if stanza then
            -- Run through incoming stanza filters (mod_smacks counts stanzas here!)
            local filtered = stanza;
            if session.filter then
                filtered = session.filter("stanzas/in", stanza);
            end
            if filtered then
                core_process_stanza(session, filtered);
            end
        end
    end
    return ""; -- Swallow binary bytes so Expat parser receives nothing
end

-- Outgoing stanza filter: runs at priority -10000 after mod_smacks, CSI, carbons, etc.
-- NOTE: The returned wrapper table delegates __tostring to encode_stanza(stanza), locking in
-- the binary serialization of the original stanza table at filter execution time.
-- Any downstream filter with priority < -10000 that attempts in-place mutation of the stanza
-- table will NOT alter the already-serialized binary output returned by __tostring.
local function funxmpp_stanzas_out(stanza, session)
    if not session.funxmpp_enabled or type(stanza) ~= "table" or not stanza.name then
        return stanza;
    end
    return setmetatable({ name = stanza.name, attr = stanza.attr }, {
        __index = stanza,
        __tostring = function()
            local bin = encode_stanza(stanza);
            if session.funxmpp_stats then
                session.funxmpp_stats.out_bytes = session.funxmpp_stats.out_bytes + #bin;
                session.funxmpp_stats.out_frames = session.funxmpp_stats.out_frames + 1;
            end
            return bin;
        end
    });
end

-- Hook: Stream features
-- NOTE: Advertises version="1" with negotiated dictionary checksum (dict attribute).
module:hook("stream-features", function(event)
    local origin, features = event.origin, event.features;
    if origin and not origin.funxmpp_enabled and (origin.type == "c2s" or origin.type == "c2s_unauthed") then
        if not features:get_child("funxmpp", FUN_NS) then
            features:tag("funxmpp", { xmlns = FUN_NS, version = "1", dict = DICTIONARY_HASH }):up();
        end
    end
end);

-- Hook: Stanza negotiation
local function handle_enable(origin, stanza)
    local session = origin;
    if not session or not session.send then
        return;
    end
    -- Idempotency check: prevent duplicate filter registration on repeated <enable/>
    if session.funxmpp_enabled then
        return true;
    end

    local client_dict = stanza and stanza.attr and stanza.attr.dict;
    if client_dict and client_dict ~= DICTIONARY_HASH then
        module:log("warn", "FunXMPP dictionary mismatch for %s: client=%s, server=%s",
            session.full_jid or session.ip or "unknown", client_dict, DICTIONARY_HASH);
        session.send(st.stanza("failed", { xmlns = FUN_NS })
            :tag("dictionary-mismatch"):up());
        return true;
    end

    module:log("info", "Client requested FunXMPP binary protocol: %s (dict=%s)",
        session.full_jid or session.ip or "unknown", client_dict or "unspecified");
    session.funxmpp_stats = { in_bytes = 0, out_bytes = 0, in_frames = 0, out_frames = 0 };

    -- Send XML acknowledgment first
    session.send(st.stanza("enabled", { xmlns = FUN_NS, dict = DICTIONARY_HASH }));
    session.funxmpp_enabled = true;

    -- Register symmetric stream filters without breaking mod_smacks queue
    filters.add_filter(session, "bytes/in", funxmpp_bytes_in, 100);
    filters.add_filter(session, "stanzas/out", funxmpp_stanzas_out, -10000);
    return true;
end

module:hook_tag(FUN_NS, "enable", handle_enable);

module:log("info", "mod_funxmpp initialized for high-performance mobile binary framing");
