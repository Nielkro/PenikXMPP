-- test_mod_penik_silent_muc.lua
-- Unit tests for server/Modules/mod_penik_silent_muc.lua

local hooks = {};

module = {
    hook = function(self, name, handler, priority)
        hooks[name] = handler;
    end,
    log = function(self, level, fmt, ...)
        -- Mock log
    end,
    get_option_boolean = function(self, name, default)
        return default;
    end,
};

-- Mock util.stanza
local stanza_mt = {
    __index = {
        tag = function(self, name, attr)
            local child = setmetatable({ name = name, attr = attr or {} }, getmetatable(self));
            table.insert(self, child);
            return self;
        end,
        text = function(self, str)
            table.insert(self, str);
            return self;
        end,
        up = function(self) return self end,
        get_child = function(self, name, ns)
            for _, child in ipairs(self) do
                if child.name == name and (not ns or child.attr.xmlns == ns) then
                    return child;
                end
            end
            return nil;
        end
    },
    __tostring = function(self)
        return "<" .. self.name .. "/>";
    end
};

local mock_stanza = {
    stanza = function(name, attr)
        return setmetatable({ name = name, attr = attr or {} }, stanza_mt);
    end,
    reply = function(s)
        return setmetatable({ name = "iq", attr = { type = "result", id = s.attr.id, to = s.attr.from } }, stanza_mt);
    end,
    error_reply = function(s, typ, cond, msg)
        return setmetatable({ name = "iq", attr = { type = "error", id = s.attr.id, to = s.attr.from }, cond = cond }, stanza_mt);
    end
};

package.loaded["util.stanza"] = mock_stanza;
package.loaded["util.jid"] = {
    bare = function(jid)
        return jid and jid:match("^([^/]+)") or jid;
    end
};

-- Load module
dofile("server/Modules/mod_penik_silent_muc.lua");

print("[*] Running Silent MUC unit tests...");

-- Test 1: Hook registration
assert(hooks["muc-broadcast-presence"] ~= nil, "muc-broadcast-presence hook must be registered");
assert(hooks["iq/bare/ru:penik:muc:members:1"] ~= nil, "iq/bare members hook must be registered");

-- Test 2: Standard presence is suppressed (returns true)
local mock_room = { jid = "test@conference.penik.chat", _data = {} };
local mock_occupant = { nick = "alice", role = "participant", jid = "alice@penik.chat/mobile" };
local mock_presence = mock_stanza.stanza("presence", { from = "test@conference.penik.chat/alice" });

local res = hooks["muc-broadcast-presence"]({
    room = mock_room,
    occupant = mock_occupant,
    stanza = mock_presence
});
assert(res == true, "Standard presence broadcast must be suppressed (return true)");

-- Test 3: Kick / ban presence is allowed through (returns nil)
local kick_x = {
    name = "x",
    attr = { xmlns = "http://jabber.org/protocol/muc#user" },
    { name = "status", attr = { code = "307" } }
};
local kick_res = hooks["muc-broadcast-presence"]({
    room = mock_room,
    occupant = mock_occupant,
    stanza = mock_presence,
    x = kick_x
});
assert(kick_res == nil, "Kick/ban presence must NOT be suppressed");

-- Test 4: Query persistent members via IQ
local query_iq = mock_stanza.stanza("iq", {
    type = "get",
    id = "mem1",
    from = "alice@penik.chat/mobile",
    to = "test@conference.penik.chat"
});
query_iq:tag("query", { xmlns = "ru:penik:muc:members:1" });

mock_room._affiliations = {
    ["alice@penik.chat"] = "owner",
    ["bob@penik.chat"] = "member"
};

local sent_stanza = nil;
local mock_origin = {
    send = function(s)
        sent_stanza = s;
    end
};

local iq_res = hooks["iq/bare/ru:penik:muc:members:1"]({
    origin = mock_origin,
    stanza = query_iq,
    room = mock_room
});

assert(iq_res == true, "IQ handler must return true");
assert(sent_stanza ~= nil, "Reply must be sent");
assert(sent_stanza.attr.type == "result", "Reply must be of type result");
assert(sent_stanza:get_child("query", "ru:penik:muc:members:1") ~= nil, "Reply must contain members query");

print("[+] All Silent MUC tests passed successfully!");
