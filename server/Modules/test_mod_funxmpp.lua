-- test_mod_funxmpp.lua
-- Unit tests for server/mod_funxmpp.lua covering smacks piggyback, prefix matching, and safe stanza drop

-- Mock Prosody environment
local hooks = {};
local filters_map = {};

module = {
    hook = function(self, name, handler)
        hooks[name] = handler;
    end,
    hook_global = function(self, name, handler)
        hooks[name] = handler;
    end,
    hook_tag = function(self, ns, tag, handler)
        hooks[ns .. ":" .. tag] = handler;
    end,
    log = function(self, level, fmt, ...)
        -- Mock logger
        -- print(string.format("[%s] " .. fmt, level, ...));
    end,
    get_option_number = function(self, name, default)
        return default;
    end
};

prosody = {
    core_process_stanza = function(session, stanza) end
};

local mock_filters = {
    add_filter = function(session, name, fn, priority)
        if not filters_map[name] then filters_map[name] = {} end
        table.insert(filters_map[name], { fn = fn, priority = priority });
        table.sort(filters_map[name], function(a, b) return a.priority > b.priority end);
    end,
    remove_filter = function(session, name, fn)
        if not filters_map[name] then return end
        for i, entry in ipairs(filters_map[name]) do
            if entry.fn == fn then
                table.remove(filters_map[name], i);
                break;
            end
        end
    end
};

package.loaded["util.filters"] = mock_filters;

-- Mock util.stanza
local stanza_mt = {
    __index = {
        tag = function(self, name, attr)
            local child = setmetatable({ name = name, attr = attr or {}, tags = {}, parent = self }, getmetatable(self));
            if not self.tags then self.tags = {} end
            table.insert(self.tags, child);
            table.insert(self, child);
            return child;
        end,
        add_child = function(self, child)
            if not self.tags then self.tags = {} end
            if type(child) == "table" and child.name then
                table.insert(self.tags, child);
            end
            table.insert(self, child);
            return self;
        end,
        add_direct_child = function(self, child)
            if not self.tags then self.tags = {} end
            if type(child) == "table" and child.name then
                table.insert(self.tags, child);
            end
            table.insert(self, child);
            return self;
        end,
        text = function(self, str)
            table.insert(self, str);
            return self;
        end,
        up = function(self) return self.parent or self end,
        get_child = function(self, name, ns)
            if self.tags then
                for _, tag in ipairs(self.tags) do
                    if (not name or tag.name == name) and (not ns or tag.attr.xmlns == ns) then
                        return tag;
                    end
                end
            end
            return nil;
        end
    },
    __tostring = function(self)
        local parts = { "<" .. self.name };
        for k, v in pairs(self.attr) do
            table.insert(parts, string.format(' %s="%s"', k, v));
        end
        if #self == 0 then
            table.insert(parts, "/>");
        else
            table.insert(parts, ">");
            for _, child in ipairs(self) do
                table.insert(parts, tostring(child));
            end
            table.insert(parts, "</" .. self.name .. ">");
        end
        return table.concat(parts);
    end
};

local mock_stanza = {
    stanza = function(name, attr)
        return setmetatable({ name = name, attr = attr or {} }, stanza_mt);
    end
};

package.loaded["util.stanza"] = mock_stanza;

-- Load the module under test
local script_dir = debug.getinfo(1, "S").source:match("@?(.*[/\\])") or "";
dofile(script_dir .. "mod_funxmpp.lua");

-- Helpers
local function assert_eq(a, b, msg)
    if a ~= b then
        error(string.format("Assertion failed: expected %s, got %s (%s)", tostring(b), tostring(a), msg or ""));
    end
end

local function assert_true(val, msg)
    if not val then
        error(string.format("Assertion failed: %s", msg or "expected true"));
    end
end

-- Setup session
local session = {
    type = "c2s",
    full_jid = "test@snikket.penik.ru/mobile",
    send = function(s) end
};

-- Initialize funxmpp for session
local enable_handler = hooks["penik:protocol:funxmpp:enable"];
assert_true(enable_handler, "Enable hook registered");
enable_handler(session, mock_stanza.stanza("enable", { xmlns = "penik:protocol:funxmpp" }));
assert_true(session.funxmpp_enabled, "FunXMPP enabled on session");

local stash_filter = nil;
local out_filter = nil;
for _, f in ipairs(filters_map["stanzas/out"]) do
    if f.priority == -999 then stash_filter = f.fn end
    if f.priority == -10000 then out_filter = f.fn end
end
assert_true(stash_filter, "Stash filter registered at -999");
assert_true(out_filter, "Out filter registered at -10000");

-- Test 1: Standard stanza out produces binary wrapper and memoizes stats
do
    local msg = mock_stanza.stanza("message", { id = "m1", to = "bob@snikket.penik.ru", type = "chat" });
    stash_filter(msg, session);
    assert_eq(session.funxmpp_last_out, msg, "Stash filter saved msg");

    local wrapped = out_filter(msg, session);
    assert_eq(session.funxmpp_last_out, nil, "Out filter cleared stash");
    assert_true(type(wrapped) == "table", "Out filter returned wrapper table");

    local initial_frames = session.funxmpp_stats.out_frames;
    local initial_bytes = session.funxmpp_stats.out_bytes;

    local bin1 = tostring(wrapped);
    assert_true(#bin1 > 0, "Binary frame generated");
    assert_true(bin1:byte(1) ~= 0x3C, "Binary frame must not start with '<'");
    assert_eq(session.funxmpp_stats.out_frames, initial_frames + 1, "Frame counted once");

    -- Second tostring() call MUST NOT re-increment stats (memoization check)
    local bin2 = tostring(wrapped);
    assert_eq(bin1, bin2, "Memoized binary matches");
    assert_eq(session.funxmpp_stats.out_frames, initial_frames + 1, "Stats not double-counted");
    assert_eq(session.funxmpp_stats.out_bytes, initial_bytes + #bin1, "Bytes not double-counted");
end

-- Test 2: Smacks piggyback <r xmlns='urn:xmpp:sm:3'/> concatenation produces two binary frames
do
    local msg = mock_stanza.stanza("message", { id = "m2", to = "alice@snikket.penik.ru" });
    stash_filter(msg, session);
    assert_eq(session.funxmpp_last_out, msg, "Stashed for smacks");

    -- Simulate mod_smacks: returns tostring(stanza) .. tostring(<r/>)
    local smacks_out = tostring(msg) .. '<r xmlns="urn:xmpp:sm:3"/>';

    local frames = out_filter(smacks_out, session);
    assert_eq(session.funxmpp_last_out, nil, "Stash cleared after processing");
    assert_true(type(frames) == "string", "Output is concatenated binary string");
    assert_true(frames:byte(1) ~= 0x3C, "Output must NOT start with '<' (0x3C)");

    -- Verify first 2 bytes are length header, and whole output has length > 0
    local len1 = frames:byte(1) * 256 + frames:byte(2);
    assert_true(len1 > 0 and len1 < #frames, "First frame length valid");
    local frame2 = frames:sub(2 + len1 + 1);
    assert_true(#frame2 > 2, "Second frame (<r/>) present");
    local len2 = frame2:byte(1) * 256 + frame2:byte(2);
    assert_eq(#frame2, 2 + len2, "Second frame has correct length header");
end

-- Test 3: Prefix mismatch prevents silent corruption and returns string unchanged
do
    local msg = mock_stanza.stanza("message", { id = "m3" });
    stash_filter(msg, session);

    -- Simulate a different string returned by some filter
    local divergent = '<custom-something-else/><r xmlns="urn:xmpp:sm:3"/>';
    local res = out_filter(divergent, session);
    assert_eq(session.funxmpp_last_out, nil, "Stash cleared");
    assert_eq(res, divergent, "Divergent string returned as-is to prevent corrupting stashed node");
end

-- Test 4: Hibernation empty string passes through
do
    local msg = mock_stanza.stanza("message", { id = "m4" });
    stash_filter(msg, session);

    local res = out_filter("", session);
    assert_eq(session.funxmpp_last_out, nil, "Stash cleared");
    assert_eq(res, "", "Empty string passes through");
end

-- Test 5: Excessive attributes (> 255) drops stanza safely without throwing Lua error
do
    local huge_stanza = mock_stanza.stanza("iq", { id = "huge" });
    for i = 1, 256 do
        huge_stanza.attr["attr_" .. i] = "v" .. i;
    end

    stash_filter(huge_stanza, session);
    local wrapped = out_filter(huge_stanza, session);
    -- Calling tostring on wrapper must not throw, but return empty string ""
    local bin = tostring(wrapped);
    assert_eq(bin, "", "Stanza with >255 attributes dropped safely as empty string");
end
 
-- Test 6: Session cleanup on disconnect or hibernation resets state and removes filters
do
    local cleanup_handler = hooks["c2s-closed"];
    assert(type(cleanup_handler) == "function", "c2s-closed hook is registered");
    assert(hooks["c2s-destroyed"] == cleanup_handler, "c2s-destroyed hook is registered to same handler");
    assert(hooks["smacks-hibernation-start"] == cleanup_handler, "smacks-hibernation-start hook is registered to same handler");

    session.funxmpp_enabled = true;
    session.funxmpp_in_buf = "leftover";
    session.funxmpp_last_out = mock_stanza.stanza("message", { id = "m6" });

    cleanup_handler({ session = session });
    assert_eq(session.funxmpp_enabled, false, "funxmpp_enabled reset to false");
    assert_eq(session.funxmpp_in_buf, nil, "funxmpp_in_buf reset to nil");
    assert_eq(session.funxmpp_last_out, nil, "funxmpp_last_out reset to nil");
end

-- Test 7: Stream features advertises latest dict hash and min_compat for v1
do
    local features_hook = hooks["stream-features"];
    assert(type(features_hook) == "function", "stream-features hook registered");

    local test_features = mock_stanza.stanza("stream:features");
    local test_session = { type = "c2s", funxmpp_enabled = false };
    features_hook({ origin = test_session, features = test_features });

    local fun_tag = nil;
    for _, child in ipairs(test_features) do
        if child.name == "funxmpp" then fun_tag = child break end
    end
    assert_true(fun_tag ~= nil, "funxmpp tag advertised in features");
    assert_eq(fun_tag.attr.version, "2", "features advertises version 2");
    assert_eq(fun_tag.attr.dict, "3a145c7a", "features advertises latest v2 dict hash");
    assert_eq(fun_tag.attr.min_compat, "68a7596d", "features advertises LTS v1 min_compat hash");
end

-- Test 8: Client requests LTS v1 dictionary -> Server activates v1, falls back to literal string for v2 tokens
do
    local v1_session;
    v1_session = {
        type = "c2s",
        full_jid = "legacy_user@snikket.penik.ru/phone",
        send_queue = {},
        send = function(s) table.insert(v1_session.send_queue, s) end
    };
    enable_handler(v1_session, mock_stanza.stanza("enable", { xmlns = "penik:protocol:funxmpp", dict = "68a7596d" }));
    assert_true(v1_session.funxmpp_enabled, "FunXMPP enabled for v1 client");
    assert_eq(#v1_session.send_queue, 1, "Enabled ack sent");
    assert_eq(v1_session.send_queue[1].attr.dict, "68a7596d", "Ack echoes back negotiated v1 dict");
    assert_eq(v1_session.funxmpp_dict.version, 1, "v1 dictionary active on session");

    -- Send message with child <markup xmlns="penik:bot:markup"/>
    -- "markup" is token 148 in v2, but does NOT exist in v1!
    local bot_msg = mock_stanza.stanza("message", { id = "b1", to = "user@snikket.penik.ru" });
    local bot_markup = mock_stanza.stanza("markup", { xmlns = "penik:bot:markup" });
    table.insert(bot_msg, bot_markup);

    stash_filter(bot_msg, v1_session);
    local wrapped = out_filter(bot_msg, v1_session);
    local bin = tostring(wrapped);
    assert_true(#bin > 0, "Binary frame generated for v1 client");

    -- For v1, "markup" and "penik:bot:markup" MUST be encoded as string literals (0xFA prefix), NOT single-byte tokens 148/152
    local found_literal_tag = false;
    for i = 1, #bin - 6 do
        if bin:byte(i) == 0xFA and bin:sub(i + 2, i + 7) == "markup" then
            found_literal_tag = true;
            break;
        end
    end
    assert_true(found_literal_tag, "v2 token 'markup' correctly fell back to string literal (0xFA) for v1 client");

    -- Verify that incoming filter decodes it back identically
    local last_processed = nil;
    prosody.core_process_stanza = function(s, st_obj)
        last_processed = st_obj;
    end
    local in_filter = filters_map["bytes/in"][1].fn;
    in_filter(bin, v1_session);

    assert_true(last_processed ~= nil, "Stanza decoded and processed via bytes/in filter");
    assert_eq(last_processed.name, "message", "Decoded stanza name is message");
    assert_eq(#last_processed, 1, "Child markup preserved");
    assert_eq(last_processed[1].name, "markup", "Child name is markup");
    assert_eq(last_processed[1].attr.xmlns, "penik:bot:markup", "Child xmlns is penik:bot:markup");
end

-- Test 9: Client requests v2 dictionary -> Server activates v2, encodes bot tokens as single-byte tokens
do
    local v2_session;
    v2_session = {
        type = "c2s",
        full_jid = "v2_user@snikket.penik.ru/desktop",
        send_queue = {},
        send = function(s) table.insert(v2_session.send_queue, s) end
    };
    enable_handler(v2_session, mock_stanza.stanza("enable", { xmlns = "penik:protocol:funxmpp", dict = "3a145c7a" }));
    assert_true(v2_session.funxmpp_enabled, "FunXMPP enabled for v2 client");
    assert_eq(#v2_session.send_queue, 1, "Enabled ack sent");
    assert_eq(v2_session.send_queue[1].attr.dict, "3a145c7a", "Ack echoes back negotiated v2 dict");
    assert_eq(v2_session.funxmpp_dict.version, 2, "v2 dictionary active on session");

    local bot_msg = mock_stanza.stanza("message", { id = "b2", to = "user@snikket.penik.ru" });
    local bot_markup = mock_stanza.stanza("markup", { xmlns = "penik:bot:markup" });
    table.insert(bot_msg, bot_markup);

    stash_filter(bot_msg, v2_session);
    local wrapped = out_filter(bot_msg, v2_session);
    local bin = tostring(wrapped);

    -- In v2, token 148 is "markup" and token 152 is "penik:bot:markup"
    local found_token_148 = false;
    for i = 1, #bin do
        if bin:byte(i) == 148 then found_token_148 = true break end
    end
    assert_true(found_token_148, "v2 token 148 ('markup') is encoded as 1-byte token for v2 client");

    -- Verify that incoming filter decodes it back identically
    local last_processed = nil;
    prosody.core_process_stanza = function(s, st_obj)
        last_processed = st_obj;
    end
    local in_filter = filters_map["bytes/in"][1].fn;
    in_filter(bin, v2_session);

    assert_true(last_processed ~= nil, "Stanza decoded and processed via bytes/in filter for v2");
    assert_eq(last_processed.name, "message", "Decoded stanza name is message");
    assert_eq(last_processed[1].name, "markup", "Child name is markup");
    assert_eq(last_processed[1].attr.xmlns, "penik:bot:markup", "Child xmlns is penik:bot:markup");
end

-- Test 10: Unknown client dictionary gracefully falls back to LTS v1 instead of failing
do
    local unknown_session;
    unknown_session = {
        type = "c2s",
        full_jid = "foreign_user@snikket.penik.ru/custom",
        send_queue = {},
        send = function(s) table.insert(unknown_session.send_queue, s) end
    };
    enable_handler(unknown_session, mock_stanza.stanza("enable", { xmlns = "penik:protocol:funxmpp", dict = "unknown999" }));
    assert_true(unknown_session.funxmpp_enabled, "FunXMPP gracefully enabled with fallback");
    assert_eq(#unknown_session.send_queue, 1, "Ack sent");
    assert_eq(unknown_session.send_queue[1].name, "enabled", "Response is <enabled/>, not <failed/>");
    assert_eq(unknown_session.send_queue[1].attr.dict, "68a7596d", "Fallback to LTS v1 dict hash");
    assert_eq(unknown_session.funxmpp_dict.version, 1, "LTS v1 dictionary bound to session");
end

-- Test 11: Direct PXMPP handshake over ALPN "pxmpp-1"
do
    local c2s_connected_hook = hooks["c2s-connected"];
    assert(type(c2s_connected_hook) == "function", "c2s-connected hook registered");

    local thread_events = {};
    local direct_session;
    direct_session = {
        type = "c2s_unauthed",
        host = "snikket.penik.ru",
        send_queue = {},
        send = function(s) table.insert(direct_session.send_queue, s) end,
        thread = {
            run = function(self, ev) table.insert(thread_events, ev) end
        },
        conn = {
            selected_alpn = function(self) return "pxmpp-1" end
        },
        data = function(data)
            error("Default XML data handler should not be called when ALPN is pxmpp-1");
        end
    };

    c2s_connected_hook({ session = direct_session, conn = direct_session.conn });

    -- Client sends Magic Header: "PXMP" (4B) + \001 (version) + \000 (flags) + dict_bytes (4B) + domain token 143 (snikket.penik.ru)
    local hex_to_bytes = function(h) return (h:gsub("..", function(cc) return string.char(tonumber(cc, 16)) end)) end
    local client_header = "PXMP\001\000" .. hex_to_bytes("3a145c7a") .. string.char(143);

    direct_session.data(client_header);

    assert_true(direct_session.funxmpp_direct, "Session marked funxmpp_direct");
    assert_true(direct_session.funxmpp_enabled, "Session marked funxmpp_enabled");
    assert_eq(#direct_session.send_queue, 1, "Server sent Server Stream Header");

    local resp = direct_session.send_queue[1];
    assert_eq(resp:sub(1, 4), "PXMP", "Server response starts with PXMP");
    assert_eq(resp:byte(5), 1, "Server response version 1");
    assert_eq(resp:byte(6), 0, "Server response flags 0");
    assert_eq(resp:sub(7, 10), hex_to_bytes("3a145c7a"), "Server echoed active dict hash in binary header");

    assert_eq(#thread_events, 1, "Streamopened event triggered");
    assert_eq(thread_events[1].event, "streamopened", "Event is streamopened");
    assert_eq(thread_events[1].attr.to, "snikket.penik.ru", "Target domain is snikket.penik.ru");
end

-- Test 12: Direct PXMPP sniffing branch without ALPN (Magic Header detection)
do
    local c2s_connected_hook = hooks["c2s-connected"];
    local thread_events = {};
    local sniff_session;
    sniff_session = {
        type = "c2s_unauthed",
        host = "snikket.penik.ru",
        send_queue = {},
        send = function(s) table.insert(sniff_session.send_queue, s) end,
        thread = {
            run = function(self, ev) table.insert(thread_events, ev) end
        },
        conn = {}, -- No ALPN
        data = function(data)
            error("Default data handler should not be called when sniffing detects PXMP");
        end
    };

    c2s_connected_hook({ session = sniff_session, conn = sniff_session.conn });

    local hex_to_bytes = function(h) return (h:gsub("..", function(cc) return string.char(tonumber(cc, 16)) end)) end
    local client_header = "PXMP\001\000" .. hex_to_bytes("68a7596d") .. string.char(143);

    -- Simulate fragmented TCP arrival: send 2 bytes first, then rest
    sniff_session.data("PX");
    assert_eq(sniff_session.funxmpp_direct, nil, "Wait for full magic header");
    sniff_session.data(client_header:sub(3));

    assert_true(sniff_session.funxmpp_direct, "Direct mode activated after buffer complete");
    assert_eq(#sniff_session.send_queue, 1, "Server response sent");
    assert_eq(sniff_session.send_queue[1]:sub(7, 10), hex_to_bytes("68a7596d"), "Active dict LTS v1 selected");
end

-- Test 13: Sniffing branch preserves standard XML stream transparently
do
    local c2s_connected_hook = hooks["c2s-connected"];
    local xml_data_received = nil;
    local xml_session;
    xml_session = {
        type = "c2s_unauthed",
        host = "snikket.penik.ru",
        conn = {},
        data = function(data)
            xml_data_received = data;
        end
    };

    c2s_connected_hook({ session = xml_session, conn = xml_session.conn });

    local raw_xml = "<stream:stream xmlns='jabber:client' to='snikket.penik.ru'>";
    xml_session.data(raw_xml);

    assert_eq(xml_session.funxmpp_direct, nil, "Direct mode not enabled for XML");
    assert_eq(xml_data_received, raw_xml, "Raw XML passed through to standard handler untouched");
end

-- Test 14: Decoded IQ stanzas must properly populate stanza.tags for Prosody IQ routing
do
    local iq_session;
    iq_session = {
        type = "c2s",
        full_jid = "iq_user@snikket.penik.ru/mobile",
        send_queue = {},
        send = function(s) table.insert(iq_session.send_queue, s) end
    };
    enable_handler(iq_session, mock_stanza.stanza("enable", { xmlns = "penik:protocol:funxmpp", dict = "3a145c7a" }));

    local iq = mock_stanza.stanza("iq", { type = "get", id = "disco-1", to = "snikket.penik.ru" })
        :tag("query", { xmlns = "http://jabber.org/protocol/disco#info" }):up();
    stash_filter(iq, iq_session);
    local wrapped = out_filter(iq, iq_session);
    local bin = tostring(wrapped);

    local processed_stanza = nil;
    prosody.core_process_stanza = function(s, st_obj)
        processed_stanza = st_obj;
    end
    local in_filter = filters_map["bytes/in"][1].fn;
    in_filter(bin, iq_session);

    assert_true(processed_stanza ~= nil, "IQ stanza decoded via bytes/in filter");
    assert_eq(processed_stanza.name, "iq", "Root is IQ");
    assert_eq(processed_stanza.attr.type, "get", "Type is get");
    assert_true(processed_stanza.tags ~= nil, "stanza.tags table exists");
    assert_eq(#processed_stanza.tags, 1, "stanza.tags has exactly 1 child tag");
    assert_eq(processed_stanza.tags[1].name, "query", "Child tag name is query");
    assert_eq(processed_stanza.tags[1].attr.xmlns, "http://jabber.org/protocol/disco#info", "Child tag namespace is disco#info");
end

-- Test 15: Malformed frame with invalid child length does not cause infinite loop
do
    local session = {
        type = "c2s",
        full_jid = "test@snikket.penik.ru",
        send_queue = {},
        send = function(s) end
    };
    enable_handler(session, mock_stanza.stanza("enable", { xmlns = "penik:protocol:funxmpp", dict = "3a145c7a" }));

    -- Craft node: tag 'message' (token 0), 0 attrs, CONTENT_CHILDREN, count 5, child_len 0
    local malformed_node = string.char(
        0, -- token 0 = "message"
        0, -- 0 attrs
        1, -- CONTENT_CHILDREN
        0, 5, -- count = 5
        0, 0  -- child_len = 0 (malformed)
    );
    local frame = string.char(0, #malformed_node) .. malformed_node;
    local in_filter = filters_map["bytes/in"][1].fn;
    -- Must finish cleanly without hang
    in_filter(frame, session);
end

print("ALL MOD_FUNXMPP TESTS PASSED SUCCESSFULLY!");
