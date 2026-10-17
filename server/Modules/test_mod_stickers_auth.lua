-- test_mod_stickers_auth.lua
-- Unit tests for server/Modules/mod_stickers_auth.lua

local hooks = {};

module = {
    hook = function(self, name, handler)
        hooks[name] = handler;
    end,
    log = function(self, level, fmt, ...)
        -- Mock log
    end,
    get_option_string = function(self, name, default)
        if name == "stickers_shared_secret" then
            return "test_secret_123";
        end
        return default;
    end,
    get_option_number = function(self, name, default)
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
        return setmetatable({ name = "iq", attr = { type = "error", id = s.attr.id, to = s.attr.from } }, stanza_mt);
    end
};

package.loaded["util.stanza"] = mock_stanza;

-- Mock util.hashes & util.encodings
-- Lua 5.3+ bitwise or string operations for basic mock
local function simple_mock_hmac(secret, data)
    return "mock_hmac_" .. secret .. "_" .. data;
end

local function hex(str)
    return "0123456789abcdef" .. #str;
end

package.loaded["util.hashes"] = {
    hmac_sha256 = function(secret, data, raw)
        return simple_mock_hmac(secret, data);
    end,
    hex = function(bytes)
        return hex(bytes);
    end,
};

-- Base64 mock
local b64_chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
local function mock_b64_encode(data)
    -- Simple reversible mock or standard b64
    return "b64_" .. data;
end

local function mock_b64_decode(data)
    if data:sub(1, 4) == "b64_" then
        return data:sub(5);
    end
    return data;
end

package.loaded["util.encodings"] = {
    base64 = {
        encode = mock_b64_encode,
        decode = mock_b64_decode,
    }
};

-- Load module
local script_dir = debug.getinfo(1, "S").source:match("@?(.*[/\\])") or "";
dofile(script_dir .. "mod_stickers_auth.lua");

-- Verify hooks registered
local xmlns = "penik:stickers:auth:0";
local hook_self = "iq/self/" .. xmlns .. ":stickers-auth";
assert(hooks[hook_self], "Hook for iq/self must be registered");

-- Test 1: Successful token issuance
local sent_stanza = nil;
local origin = {
    username = "alice",
    host = "snikket.penik.ru",
    send = function(s)
        sent_stanza = s;
    end
};

local request_iq = mock_stanza.stanza("iq", { type = "get", id = "test_req_1" });
request_iq:tag("stickers-auth", { xmlns = xmlns });

local event = {
    origin = origin,
    stanza = request_iq,
};

local handled = hooks[hook_self](event);
assert(handled == true, "Handler must return true");
assert(sent_stanza ~= nil, "Response stanza must be sent");
assert(sent_stanza.attr.type == "result", "Response must be of type result");

local reply_auth = sent_stanza:get_child("stickers-auth", xmlns);
assert(reply_auth ~= nil, "stickers-auth tag must be present in reply");
assert(reply_auth.attr.token ~= nil, "token attribute must be present");
assert(reply_auth.attr.expires ~= nil, "expires attribute must be present");

-- Verify token format
local raw_token = mock_b64_decode(reply_auth.attr.token);
local expected_prefix = "alice@snikket.penik.ru:" .. reply_auth.attr.expires .. ":";
assert(raw_token:sub(1, #expected_prefix) == expected_prefix, "Token must start with jid:expires:");

print("ALL MOD_STICKERS_AUTH TESTS PASSED SUCCESSFULLY!");
