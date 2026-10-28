-- mod_penik_silent_muc.lua
-- Converts MUC conferences into silent, high-performance Telegram-like supergroups.
-- Suppresses join/leave/status presence broadcasts to room occupants,
-- preventing presence storms and eliminating mobile battery drain.
-- Also provides an IQ query handler for fetching persistent room member lists.

local st = require "util.stanza";
local jid_bare = require "util.jid".bare;

local xmlns_penik_members = "ru:penik:muc:members:1";

-- Check if room has silent mode enabled (default: true)
local function is_silent_room(room)
    if not room then
        return false;
    end
    if room._data and room._data.penik_silent ~= nil then
        return room._data.penik_silent;
    end
    return module:get_option_boolean("penik_silent_muc_default", true);
end

-- Hook: muc-broadcast-presence
-- Fired right before presence is broadcasted to other room occupants.
-- Returning true halts the broadcast to room participants.
module:hook("muc-broadcast-presence", function(event)
    local room, occupant, stanza, x = event.room, event.occupant, event.stanza, event.x;
    if not room or not occupant or not stanza then
        return;
    end

    if not is_silent_room(room) then
        return;
    end

    -- Allow presence through if it's a kick, ban, or destruction status
    if x then
        for _, child in ipairs(x) do
            if type(child) == "table" and child.name == "status" then
                local code = child.attr and child.attr.code;
                -- 301 = banned, 307 = kicked, 321 = removed, 332 = room destroyed
                if code == "301" or code == "307" or code == "321" or code == "332" then
                    return; -- Do not suppress administrative removals
                end
            end
        end
    end

    -- Suppress regular join, leave, and status updates to other occupants
    return true;
end, 100);

-- Hook: Query persistent members via IQ
-- <iq type='get' to='room@conference.domain' id='...'>
--   <query xmlns='ru:penik:muc:members:1'/>
-- </iq>
local function handle_members_iq(event)
    local origin, stanza = event.origin, event.stanza;
    if stanza.attr.type ~= "get" then
        return;
    end

    local query = stanza:get_child("query", xmlns_penik_members);
    if not query then
        return;
    end

    local room_jid = stanza.attr.to;
    local room = event.room;
    if not room and module.get_room_from_jid then
        room = module:get_room_from_jid(room_jid);
    end

    if not room then
        origin.send(st.error_reply(stanza, "cancel", "item-not-found", "Room not found"));
        return true;
    end

    local sender_jid = stanza.attr.from;
    local sender_bare = sender_jid and jid_bare(sender_jid);

    -- Security check: user must have an affiliation or room must be public
    local affiliations = room._affiliations or (room._data and room._data.affiliations) or {};
    local is_members_only = room.is_members_only and room:is_members_only();
    if is_members_only and sender_bare then
        local sender_affiliation = affiliations[sender_bare];
        if not sender_affiliation or sender_affiliation == "none" or sender_affiliation == "outcast" then
            origin.send(st.error_reply(stanza, "auth", "forbidden", "Only members can query participant list"));
            return true;
        end
    end

    local reply = st.reply(stanza):tag("query", { xmlns = xmlns_penik_members });
    for user_jid, affiliation in pairs(affiliations) do
        if affiliation and affiliation ~= "none" and affiliation ~= "outcast" then
            reply:tag("member", { jid = user_jid, affiliation = affiliation }):up();
        end
    end

    origin.send(reply);
    return true;
end

module:hook("iq/bare/" .. xmlns_penik_members, handle_members_iq);
module:hook("iq/full/" .. xmlns_penik_members, handle_members_iq);
