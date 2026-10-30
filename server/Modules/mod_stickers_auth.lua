-- mod_stickers_auth.lua
-- Issues HMAC-SHA256 Bearer authentication tokens for the Penik Stickers Microservice
-- over XMPP IQ stanzas.
--
-- Request:
--   <iq type='get' id='stk_1'>
--     <stickers-auth xmlns='penik:stickers:auth:0'/>
--   </iq>
--
-- Response:
--   <iq type='result' id='stk_1'>
--     <stickers-auth xmlns='penik:stickers:auth:0' token='...' expires='1776345600'/>
--   </iq>

local st = require "util.stanza";
local hashes = require "util.hashes";
local base64 = require "util.encodings".base64;

local xmlns_stickers_auth = "penik:stickers:auth:0";

local shared_secret = module:get_option_string("stickers_shared_secret");
local shared_secret_configured = shared_secret ~= nil
    and shared_secret ~= ""
    and shared_secret ~= "penik_secret_shared_key";
local token_ttl = module:get_option_number("stickers_token_ttl", 86400); -- 24 hours default

if not shared_secret_configured then
    module:log("error", "stickers_shared_secret is missing or uses the former public default; token issuance disabled");
end

local function handle_auth_iq(event)
    local origin, stanza = event.origin, event.stanza;

    if stanza.attr.type ~= "get" then
        return;
    end

    local payload_tag = stanza:get_child("stickers-auth", xmlns_stickers_auth);
    if not payload_tag then
        return;
    end

    if not shared_secret_configured then
        origin.send(st.error_reply(stanza, "cancel", "service-unavailable", "Stickers authentication is not configured"));
        return true;
    end

    -- Determine authenticated user JID
    local user_jid;
    if origin.username and origin.host then
        user_jid = origin.username .. "@" .. origin.host;
    elseif origin.bare_jid then
        user_jid = origin.bare_jid;
    else
        origin.send(st.error_reply(stanza, "cancel", "not-authorized", "User is not authenticated"));
        return true;
    end

    local now = os.time();
    local expires_at = now + token_ttl;
    local raw_data = user_jid .. ":" .. tostring(expires_at);

    -- Compute HMAC-SHA256 (hex-encoded)
    local sig_hex;
    if hashes.hex then
        sig_hex = hashes.hex(hashes.hmac_sha256(shared_secret, raw_data, false));
    else
        sig_hex = hashes.hmac_sha256(shared_secret, raw_data, true);
    end

    -- Format: base64(user_jid:expires_at:sig_hex)
    local raw_token = raw_data .. ":" .. sig_hex;
    local token = base64.encode(raw_token);

    module:log("info", "Issued sticker auth token for %s (expires %d)", user_jid, expires_at);

    local reply = st.reply(stanza):tag("stickers-auth", {
        xmlns = xmlns_stickers_auth,
        token = token,
        expires = tostring(expires_at),
    });

    origin.send(reply);
    return true;
end

module:hook("iq/self/" .. xmlns_stickers_auth .. ":stickers-auth", handle_auth_iq);
module:hook("iq/host/" .. xmlns_stickers_auth .. ":stickers-auth", handle_auth_iq);

module:log("info", "mod_stickers_auth loaded successfully");
