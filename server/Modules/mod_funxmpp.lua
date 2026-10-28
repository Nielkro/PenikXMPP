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

local TOKENS_V1 = {
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

local TOKENS_V2 = {};
for i = 0, 146 do
    TOKENS_V2[i] = TOKENS_V1[i];
end
-- Bot Platform tokens (147..152) added in v2
TOKENS_V2[147] = "bot.snikket.penik.ru";
TOKENS_V2[148] = "markup";
TOKENS_V2[149] = "row";
TOKENS_V2[150] = "button";
TOKENS_V2[151] = "callback";
TOKENS_V2[152] = "penik:bot:markup";

local function build_lookup(tokens)
    local lookup = {};
    for id, str in pairs(tokens) do
        lookup[str] = id;
    end
    return lookup;
end

local LOOKUP_V1 = build_lookup(TOKENS_V1);
local LOOKUP_V2 = build_lookup(TOKENS_V2);

-- Default global fallback for backwards compatibility
local TOKENS = TOKENS_V2;
local TOKEN_LOOKUP = LOOKUP_V2;

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

    -- 32-bit FNV prime multiplication safe from 53-bit IEEE-754 double precision loss in Lua 5.1/5.2
    local function mul_fnv(h)
        if h < 0 then h = (h % 4294967296); end
        local h_lo = h % 65536;
        local h_hi = math.floor(h / 65536);
        local p_lo = 0x0193;
        local p_hi = 0x0100;

        local low = h_lo * p_lo;
        local mid = h_lo * p_hi + h_hi * p_lo;
        local high = (math.floor(low / 65536) + mid) % 65536;
        return (high * 65536 + (low % 65536)) % 4294967296;
    end

    local hash = 0x811c9dc5;

    local i = 0;
    while tokens[i] ~= nil do
        local token = tokens[i];
        for j = 1, #token do
            local b = token:byte(j);
            hash = bxor(hash, b);
            hash = mul_fnv(hash);
        end
        hash = bxor(hash, 10);
        hash = mul_fnv(hash);
        i = i + 1;
    end
    return string.format("%08x", hash);
end

local DICT_V1_HASH = compute_dict_hash(TOKENS_V1);
local DICT_V2_HASH = compute_dict_hash(TOKENS_V2);

local DICTIONARIES = {
    [DICT_V1_HASH] = {
        version = 1,
        hash = DICT_V1_HASH,
        tokens = TOKENS_V1,
        lookup = LOOKUP_V1,
    },
    [DICT_V2_HASH] = {
        version = 2,
        hash = DICT_V2_HASH,
        tokens = TOKENS_V2,
        lookup = LOOKUP_V2,
    },
};

local LATEST_DICT_HASH = DICT_V2_HASH;
local LTS_V1_HASH = DICT_V1_HASH;
local DICTIONARY_HASH = LATEST_DICT_HASH;

-- Helper: encode string or token with 8/16/32-bit length
local function write_token_or_string(buf, str, lookup)
    lookup = lookup or TOKEN_LOOKUP;
    str = str or "";
    local token = lookup[str];
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
            local domain_token = lookup[domain];
            if domain_token and domain_token >= 0 and domain_token < 240 then
                table.insert(buf, string.char(JID_BARE));
                write_token_or_string(buf, user, lookup);
                table.insert(buf, string.char(domain_token));
                return;
            end
        else
            local user = str:sub(1, at_pos - 1);
            local domain = str:sub(at_pos + 1, slash_pos - 1);
            local domain_token = lookup[domain];
            if domain_token and domain_token >= 0 and domain_token < 240 then
                local resource = str:sub(slash_pos + 1);
                table.insert(buf, string.char(JID_FULL));
                write_token_or_string(buf, user, lookup);
                table.insert(buf, string.char(domain_token));
                write_token_or_string(buf, resource, lookup);
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
local function read_token_or_string(data, pos, tokens_tab)
    tokens_tab = tokens_tab or TOKENS;
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
        if pos + 1 > #data then return nil, pos end
        local hi = data:byte(pos);
        local lo = data:byte(pos + 1);
        local len = hi * 256 + lo;
        pos = pos + 2;
        if pos + len - 1 > #data then return nil, pos end
        local s = data:sub(pos, pos + len - 1);
        return s, pos + len;
    elseif b == LITERAL_STRING_32 then
        if pos + 3 > #data then return nil, pos end
        local b1, b2, b3, b4 = data:byte(pos, pos + 3);
        local len = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4;
        pos = pos + 4;
        if pos + len - 1 > #data then return nil, pos end
        local s = data:sub(pos, pos + len - 1);
        return s, pos + len;
    elseif b == JID_BARE then
        local user;
        user, pos = read_token_or_string(data, pos, tokens_tab);
        if not user or pos > #data then return nil, pos end
        local domain_token = data:byte(pos);
        pos = pos + 1;
        local domain = tokens_tab[domain_token];
        if not domain then return nil, pos end
        return user .. "@" .. domain, pos;
    elseif b == JID_FULL then
        local user;
        user, pos = read_token_or_string(data, pos, tokens_tab);
        if not user or pos > #data then return nil, pos end
        local domain_token = data:byte(pos);
        pos = pos + 1;
        local domain = tokens_tab[domain_token];
        if not domain then return nil, pos end
        local resource;
        resource, pos = read_token_or_string(data, pos, tokens_tab);
        if not resource then return nil, pos end
        return user .. "@" .. domain .. "/" .. resource, pos;
    else
        local token = tokens_tab[b];
        if token then
            return token, pos;
        else
            return nil, pos;
        end
    end
end

-- Encode Stanza to FunXMPP binary node
local function encode_stanza(stanza, parent_ns, session)
    local lookup = (session and session.funxmpp_dict and session.funxmpp_dict.lookup) or TOKEN_LOOKUP;
    local body_buf = {};

    -- 1. Tag name
    write_token_or_string(body_buf, stanza.name, lookup);

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

    if #attr_list > 255 then
        module:log("error", "FunXMPP: stanza %s has %d attributes (> 255), dropping stanza", tostring(stanza.name), #attr_list);
        return nil;
    end
    table.insert(body_buf, string.char(#attr_list));
    for _, attr in ipairs(attr_list) do
        write_token_or_string(body_buf, attr[1], lookup);
        write_token_or_string(body_buf, attr[2], lookup);
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
    if #child_tags > 65535 then
        module:log("error", "FunXMPP: stanza %s has %d children (> 65535), dropping", tostring(stanza.name), #child_tags);
        return nil;
    end

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
            local child_bin = encode_stanza(child, current_ns, session);
            if not child_bin then return nil; end
            table.insert(body_buf, child_bin);
        end
    elseif has_children then
        table.insert(body_buf, string.char(CONTENT_CHILDREN));
        local hi = math.floor(#child_tags / 256);
        local lo = #child_tags % 256;
        table.insert(body_buf, string.char(hi, lo));
        for _, child in ipairs(child_tags) do
            local child_bin = encode_stanza(child, current_ns, session);
            if not child_bin then return nil; end
            table.insert(body_buf, child_bin);
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
local function decode_node(data, pos, parent_ns, session, depth)
    depth = depth or 0;
    if depth > 64 then
        module:log("warn", "FunXMPP: max node depth exceeded (64), aborting decode");
        return nil, pos;
    end
    local tokens_tab = (session and session.funxmpp_dict and session.funxmpp_dict.tokens) or TOKENS;
    if pos > #data then return nil, pos end

    local tag_name;
    tag_name, pos = read_token_or_string(data, pos, tokens_tab);
    if not tag_name then return nil, pos end

    local attr_count = data:byte(pos) or 0;
    pos = pos + 1;
    local attr = {};
    for _ = 1, attr_count do
        local k, v;
        k, pos = read_token_or_string(data, pos, tokens_tab);
        v, pos = read_token_or_string(data, pos, tokens_tab);
        if not k or not v then
            return nil, pos;
        end
        attr[k] = v;
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
            if child_len <= 0 or (pos + child_len - 1) > #data then
                module:log("warn", "FunXMPP: invalid child length %d at pos %d, aborting child read", child_len, pos);
                break;
            end
            local expected_end_pos = pos + child_len;
            local child_stanza = decode_node(data, pos, ns, session, depth + 1);
            if child_stanza then
                if stanza.add_direct_child then
                    stanza:add_direct_child(child_stanza);
                elseif stanza.add_child then
                    stanza:add_child(child_stanza);
                else
                    if not stanza.tags then stanza.tags = {}; end
                    table.insert(stanza.tags, child_stanza);
                    table.insert(stanza, child_stanza);
                end
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
        if text_len < 0 or (pos + text_len - 1) > #data then
            module:log("warn", "FunXMPP: invalid text length %d, aborting text read", text_len);
            return;
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
    local buf = session.funxmpp_in_buf;
    if buf and buf ~= "" then
        buf = buf .. data;
    else
        buf = data;
    end

    local pos = 1;
    local total_len = #buf;
    while total_len - pos + 1 >= 2 do
        local b1, b2 = buf:byte(pos, pos + 1);
        local len = b1 * 256 + b2;
        local header_size = 2;
        if len == 0xFFFF then
            if total_len - pos + 1 < 6 then break end
            local b3, b4, b5, b6 = buf:byte(pos + 2, pos + 5);
            len = b3 * 16777216 + b4 * 65536 + b5 * 256 + b6;
            header_size = 6;
        end

        if len > MAX_FRAME_SIZE then
            module:log("warn", "FunXMPP frame size limit exceeded (%d > %d) from %s, terminating session",
                len, MAX_FRAME_SIZE, session.full_jid or session.ip or "unknown");
            session.funxmpp_in_buf = nil;
            session.funxmpp_enabled = false;
            session:close({
                condition = "policy-violation",
                text = "FunXMPP frame size exceeded maximum allowed limit"
            });
            return "";
        end

        if total_len - pos + 1 < header_size + len then
            break;
        end
        local frame = buf:sub(pos + header_size, pos + header_size + len - 1);
        pos = pos + header_size + len;

        if session.funxmpp_stats then
            session.funxmpp_stats.in_bytes = session.funxmpp_stats.in_bytes + header_size + len;
            session.funxmpp_stats.in_frames = session.funxmpp_stats.in_frames + 1;
        end

        local stanza = decode_node(frame, 1, "jabber:client", session, 0);
        if stanza then
            -- Run through incoming stanza filters (mod_smacks counts stanzas here!)
            local filtered = stanza;
            if session.filter then
                filtered = session.filter("stanzas/in", stanza);
            end
            if filtered then
                (prosody.core_process_stanza or core_process_stanza)(session, filtered);
            end
        end
    end

    if pos > total_len then
        session.funxmpp_in_buf = nil;
    elseif pos > 1 then
        session.funxmpp_in_buf = buf:sub(pos);
    else
        session.funxmpp_in_buf = buf;
    end
    return ""; -- Swallow binary bytes so Expat parser receives nothing
end

-- Stash original outgoing stanza table at priority -999 before mod_smacks (-1000)
-- might convert it to a string when appending piggybacked <r/>.
-- NOTE: Intermediate filters between -999 and -10000 (such as carbons or CSI) are expected
-- to mutate stanzas in-place or leave them as tables. If an intermediate filter were to replace
-- the table with a new object before mod_smacks stringifies it, the prefix check below
-- (tostring(stashed)) ensures we do not output stale or corrupt content if the string diverged.
local function funxmpp_stanzas_stash_out(stanza, session)
    if session.funxmpp_enabled and type(stanza) == "table" and stanza.name then
        session.funxmpp_last_out = stanza;
    else
        session.funxmpp_last_out = nil;
    end
    return stanza;
end

-- Outgoing stanza filter: runs at priority -10000 after mod_smacks, CSI, carbons, etc.
-- NOTE: The returned wrapper table delegates __tostring to encode_stanza(stanza), memoizing
-- the binary frame so stats are not double-counted if tostring() is invoked multiple times.
-- If mod_smacks appended a piggybacked <r/>, the incoming stanza is a string and the original
-- stanza was saved in session.funxmpp_last_out; we verify that the string prefix matches
-- tostring(stashed) before serializing both as binary frames.
-- NOTE: mod_smacks returns "" (empty string) during session hibernation.
-- Such non-piggyback strings pass through directly to socket write without binary encoding.
local function funxmpp_stanzas_out(stanza, session)
    if not session.funxmpp_enabled then
        return stanza;
    end
    if session.funxmpp_direct and type(stanza) == "string" and not session.funxmpp_last_out then
        if stanza:sub(1, 5) == "<?xml" or stanza:sub(1, 14) == "<stream:stream" then
            return nil;
        end
    end
    if type(stanza) == "table" and stanza.name then
        session.funxmpp_last_out = nil;
        local memoized_bin = nil;
        return setmetatable({ name = stanza.name, attr = stanza.attr }, {
            __index = stanza,
            __tostring = function()
                if not memoized_bin then
                    memoized_bin = encode_stanza(stanza, nil, session) or "";
                    if memoized_bin ~= "" and session.funxmpp_stats then
                        session.funxmpp_stats.out_bytes = session.funxmpp_stats.out_bytes + #memoized_bin;
                        session.funxmpp_stats.out_frames = session.funxmpp_stats.out_frames + 1;
                    end
                end
                return memoized_bin;
            end
        });
    elseif type(stanza) == "string" and session.funxmpp_last_out then
        local stashed = session.funxmpp_last_out;
        session.funxmpp_last_out = nil;

        local expected_prefix = tostring(stashed);
        if stanza:sub(1, #expected_prefix) ~= expected_prefix then
            module:log("warn", "FunXMPP: outgoing string does not match stashed stanza prefix (%s), skipping binary piggyback",
                stashed.name or "unknown");
            return stanza;
        end

        local suffix = stanza:sub(#expected_prefix + 1);
        local sm_ns = suffix:match("^%s*<r%s+xmlns=['\"](urn:xmpp:sm:[23])['\"]%s*/>%s*$");
        if sm_ns then
            local r_stanza = st.stanza("r", { xmlns = sm_ns });
            local bin1 = encode_stanza(stashed, nil, session);
            local bin2 = encode_stanza(r_stanza, nil, session);
            if bin1 and bin2 then
                if session.funxmpp_stats then
                    session.funxmpp_stats.out_bytes = session.funxmpp_stats.out_bytes + #bin1 + #bin2;
                    session.funxmpp_stats.out_frames = session.funxmpp_stats.out_frames + 2;
                end
                return bin1 .. bin2;
            else
                module:log("error", "FunXMPP: failed to encode piggybacked stanza (%s), dropping", stashed.name or "unknown");
                return "";
            end
        else
            module:log("warn", "FunXMPP: outgoing string matched stashed prefix but has unexpected suffix, passing raw string");
        end
    end
    return stanza;
end

local function funxmpp_bytes_out(data, session)
    if not session.funxmpp_direct then
        return data;
    end
    if type(data) == "string" then
        if data:sub(1, 5) == "<?xml" or data:sub(1, 14) == "<stream:stream" then
            return "";
        end
    end
    return data;
end

-- Hook: Stream features
-- NOTE: Advertises latest version and hash, plus min_compat for older clients.
module:hook("stream-features", function(event)
    local origin, features = event.origin, event.features;
    if origin and not origin.funxmpp_enabled and (origin.type == "c2s" or origin.type == "c2s_unauthed") then
        if not features:get_child("funxmpp", FUN_NS) then
            features:tag("funxmpp", {
                xmlns = FUN_NS,
                version = "2",
                dict = LATEST_DICT_HASH,
                min_compat = LTS_V1_HASH,
            }):up();
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
    local selected_dict = nil;
    local selected_hash = nil;

    if client_dict and DICTIONARIES[client_dict] then
        selected_dict = DICTIONARIES[client_dict];
        selected_hash = client_dict;
    elseif not client_dict then
        selected_dict = DICTIONARIES[LATEST_DICT_HASH];
        selected_hash = LATEST_DICT_HASH;
    else
        -- Unknown client dictionary: gracefully fall back to LTS v1 instead of failing
        module:log("warn", "FunXMPP dictionary unknown for %s: client=%s, falling back to LTS v1 (%s)",
            session.full_jid or session.ip or "unknown", client_dict, LTS_V1_HASH);
        selected_dict = DICTIONARIES[LTS_V1_HASH];
        selected_hash = LTS_V1_HASH;
    end

    session.funxmpp_dict = selected_dict;
    module:log("info", "Client requested FunXMPP binary protocol: %s (dict=%s, version=%d)",
        session.full_jid or session.ip or "unknown", selected_hash, selected_dict.version);
    session.funxmpp_stats = { in_bytes = 0, out_bytes = 0, in_frames = 0, out_frames = 0 };

    -- Send XML acknowledgment first with negotiated dict hash
    session.send(st.stanza("enabled", { xmlns = FUN_NS, dict = selected_hash }));
    session.funxmpp_enabled = true;

    -- Register symmetric stream filters without breaking mod_smacks queue
    filters.add_filter(session, "bytes/in", funxmpp_bytes_in, 100);
    filters.add_filter(session, "stanzas/out", funxmpp_stanzas_stash_out, -999);
    filters.add_filter(session, "stanzas/out", funxmpp_stanzas_out, -10000);
    return true;
end

module:hook_tag(FUN_NS, "enable", handle_enable);

-- Direct PXMPP Helpers
local function hex_to_bytes(hex)
    return (hex:gsub("..", function(cc)
        return string.char(tonumber(cc, 16))
    end))
end

local function bytes_to_hex(b)
    return (b:gsub(".", function(c)
        return string.format("%02x", string.byte(c))
    end))
end

local function handle_direct_pxmpp(session, data)
    if not data or #data < 10 then
        return;
    end
    local magic = data:sub(1, 4);
    if magic ~= "PXMP" then
        return;
    end
    local version = data:byte(5);
    local flags = data:byte(6);
    local client_dict_bytes = data:sub(7, 10);
    local client_dict_hash = bytes_to_hex(client_dict_bytes);

    local domain, next_pos = read_token_or_string(data, 11, TOKENS);
    domain = domain or session.host or "snikket.penik.ru";

    local selected_dict = DICTIONARIES[client_dict_hash] or DICTIONARIES[LTS_V1_HASH];
    session.funxmpp_dict = selected_dict;
    session.funxmpp_enabled = true;
    session.funxmpp_direct = true;
    session.funxmpp_stats = { in_bytes = 0, out_bytes = 0, in_frames = 0, out_frames = 0 };

    module:log("info", "Direct PXMPP stream negotiated for %s (dict=%s, domain=%s)",
        session.full_jid or session.ip or "unknown", selected_dict.hash, domain);

    -- Send 10-byte Server Stream Header: "PXMP" .. \001\000 .. ActiveDictHash (4 bytes)
    local server_header = "PXMP\001\000" .. hex_to_bytes(selected_dict.hash);
    if session.conn and session.conn.write then
        session.conn:write(server_header);
    elseif session.send then
        session.send(server_header);
    end

    -- In Direct PXMPP, intercept session.send to drop textual XML stream headers
    local original_send = session.send;
    if original_send then
        session.funxmpp_original_send = original_send;
        session.send = function(stanza)
            if session.funxmpp_direct and type(stanza) == "string" then
                if stanza:sub(1, 5) == "<?xml" or stanza:sub(1, 14) == "<stream:stream" then
                    return true;
                end
            end
            return original_send(stanza);
        end
    end

    -- Register symmetric stream filters
    filters.add_filter(session, "bytes/in", funxmpp_bytes_in, 100);
    filters.add_filter(session, "bytes/out", funxmpp_bytes_out, -10000);
    filters.add_filter(session, "stanzas/out", funxmpp_stanzas_stash_out, -999);
    filters.add_filter(session, "stanzas/out", funxmpp_stanzas_out, -10000);

    -- Trigger streamopened in Prosody session runner
    if session.thread then
        session.thread:run({
            event = "streamopened",
            attr = {
                to = domain,
                version = "1.0",
                ["xmlns:stream"] = "http://etherx.jabber.org/streams",
                xmlns = "jabber:client"
            }
        });
    end

    -- Process any remaining pipelined bytes (e.g. <resume/> or <auth/>)
    if next_pos and next_pos <= #data then
        local leftover = data:sub(next_pos);
        if #leftover > 0 then
            funxmpp_bytes_in(leftover, session);
        end
    end
end

local function setup_c2s_sniffing(session)
    if session.funxmpp_sniff_installed then return end
    session.funxmpp_sniff_installed = true;
    module:log("debug", "Direct PXMPP: setup_c2s_sniffing installed for session %s", tostring(session.id or session));
    local original_data = session.data;

    session.data = function(data)
        if not data then return end
        module:log("debug", "Direct PXMPP: incoming chunk len=%d, 1st byte=0x%02x", #data, data:byte(1) or 0);

        if session.funxmpp_direct or session.funxmpp_enabled then
            if original_data then
                return original_data(data);
            end
            return;
        end

        local conn = session.conn;
        local alpn = conn and conn.selected_alpn and conn:selected_alpn();
        local sniff = (session.funxmpp_sniff_buf or "") .. data;
        session.funxmpp_sniff_buf = sniff;

        if alpn == "pxmpp-1" or sniff:byte(1) == 0x50 then -- 'P' (potential PXMP)
            if #sniff >= 4 and sniff:sub(1, 4) ~= "PXMP" and alpn ~= "pxmpp-1" then
                session.funxmpp_sniff_buf = nil;
                session.data = original_data;
                if original_data then
                    return original_data(sniff);
                end
                return;
            end

            if #sniff >= 10 then
                if sniff:sub(1, 4) == "PXMP" then
                    -- Verify if the domain token / literal string has also arrived completely
                    local _, next_pos = read_token_or_string(sniff, 11, TOKENS);
                    if next_pos then
                        session.funxmpp_sniff_buf = nil;
                        session.data = original_data;
                        return handle_direct_pxmpp(session, sniff);
                    else
                        -- Need more bytes to finish reading domain
                        return;
                    end
                else
                    session.funxmpp_sniff_buf = nil;
                    session.data = original_data;
                    if original_data then
                        return original_data(sniff);
                    end
                end
            else
                -- Waiting for at least 10 bytes of PXMP header
                return;
            end
        elseif sniff:byte(1) == 0x3C then -- '<' (classical XML)
            session.funxmpp_sniff_buf = nil;
            session.data = original_data;
            if original_data then
                return original_data(sniff);
            end
        else
            session.funxmpp_sniff_buf = nil;
            session.data = original_data;
            if original_data then
                return original_data(sniff);
            end
        end
    end
end

local hook_c2s = module.hook_global or function(self, name, fn, prio) return self:hook(name, fn, prio) end;

hook_c2s(module, "c2s-connected", function(event)
    if event.session then
        setup_c2s_sniffing(event.session);
    end
end, 100);

-- Hook: Stream Management hibernation / disconnect cleanup
-- When a connection drops or hibernates, reset funxmpp stream state so that
-- reconnected/resumed sessions do not attempt binary I/O on fresh un-negotiated sockets.
local function handle_session_cleanup(event)
    local session = event.origin or event.session;
    if session and session.funxmpp_enabled then
        if session.funxmpp_original_send then
            session.send = session.funxmpp_original_send;
            session.funxmpp_original_send = nil;
        end
        session.funxmpp_enabled = false;
        session.funxmpp_direct = false;
        session.funxmpp_sniff_buf = nil;
        session.funxmpp_sniff_installed = nil;
        session.funxmpp_dict = nil;
        session.funxmpp_in_buf = nil;
        session.funxmpp_last_out = nil;
        pcall(filters.remove_filter, session, "bytes/in", funxmpp_bytes_in);
        pcall(filters.remove_filter, session, "bytes/out", funxmpp_bytes_out);
        pcall(filters.remove_filter, session, "stanzas/out", funxmpp_stanzas_stash_out);
        pcall(filters.remove_filter, session, "stanzas/out", funxmpp_stanzas_out);
        module:log("info", "FunXMPP stream state reset on disconnect/hibernation for %s",
            session.full_jid or session.ip or "unknown");
    end
end

hook_c2s(module, "c2s-closed", handle_session_cleanup, 100);
hook_c2s(module, "c2s-destroyed", handle_session_cleanup, 100);
module:hook("smacks-hibernation-start", handle_session_cleanup, 100);

-- Automatically re-open stream in Prosody runner for post-auth stream features upon SASL success
hook_c2s(module, "authentication-success", function(event)
    local session = event.session;
    if session and session.funxmpp_direct then
        module:log("info", "Direct PXMPP: auth successful, auto-restarting authenticated stream for %s", tostring(session.username or session.host));
        if session.thread then
            session.thread:run({
                event = "streamopened",
                attr = {
                    to = session.host or "snikket.penik.ru",
                    version = "1.0",
                    ["xmlns:stream"] = "http://etherx.jabber.org/streams",
                    xmlns = "jabber:client"
                }
            });
        end
    end
end, -10);

module:log("info", "mod_funxmpp initialized for high-performance mobile binary framing");
