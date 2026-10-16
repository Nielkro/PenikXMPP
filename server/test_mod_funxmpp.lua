-- test_mod_funxmpp.lua
-- Unit tests for server/mod_funxmpp.lua covering smacks piggyback, prefix matching, and safe stanza drop

-- Mock Prosody environment
local hooks = {};
local filters_map = {};

module = {
    hook = function(self, name, handler)
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
    end
};

package.loaded["util.filters"] = mock_filters;

-- Mock util.stanza
local stanza_mt = {
    __index = {
        tag = function(self, name, attr)
            local child = setmetatable({ name = name, attr = attr or {} }, getmetatable(self));
            table.insert(self, child);
            return child;
        end,
        text = function(self, str)
            table.insert(self, str);
            return self;
        end,
        up = function(self) return self end,
        get_child = function(self, name, ns) return nil end
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
dofile("server/mod_funxmpp.lua");

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

print("ALL MOD_FUNXMPP TESTS PASSED SUCCESSFULLY!");
