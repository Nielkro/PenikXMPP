-- Prosody IM
-- XEP-0012: Last Activity backed by mod_account_activity storage
local st = require "prosody.util.stanza";
local is_contact_subscribed = require "prosody.core.rostermanager".is_contact_subscribed;
local jid_bare = require "prosody.util.jid".bare;
local jid_split = require "prosody.util.jid".split;

module:add_feature("jabber:iq:last");

local store = module:open_store("account_activity", "keyval+");

local function get_last_active(username)
	local user_sessions = prosody.hosts[module.host] and prosody.hosts[module.host].sessions;
	if user_sessions and user_sessions[username] then
		return os.time(), true;
	else
		local last_activity = store:get(username);
		if not last_activity or not last_activity.timestamp then
			return nil, false;
		end
		return last_activity.timestamp, false;
	end
end

module:hook("iq-get/bare/jabber:iq:last:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	local username = jid_split(stanza.attr.to) or origin.username;
	local requester = stanza.attr.from and jid_bare(stanza.attr.from);
	local target_jid = username .. "@" .. module.host;

	if not stanza.attr.to or requester == target_jid or (requester and is_contact_subscribed(username, module.host, requester)) then
		local last_timestamp, is_online = get_last_active(username);
		if not last_timestamp then
			origin.send(st.error_reply(stanza, 'cancel', 'item-not-found'));
			return true;
		end
		local seconds = is_online and "0" or string.format("%d", math.max(0, os.difftime(os.time(), last_timestamp)));
		origin.send(st.reply(stanza):tag('query', {xmlns='jabber:iq:last', seconds=seconds}));
	else
		origin.send(st.error_reply(stanza, 'auth', 'forbidden'));
	end
	return true;
end);
