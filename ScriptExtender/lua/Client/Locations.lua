-- File: Client/Locations.lua
--
-- Named-location service.  Two responsibilities:
--   1. Slug -> display-name resolution for Larian internal slugs
--      (subregions, waypoints, levels).  In practice this only
--      provides a humanized fallback -- the real name resolution
--      lives elsewhere (UI widget reads for subregions, server-side
--      DisplayName lookups for waypoints).
--   2. Client-side caches:
--      - Unlocked waypoints, relayed by the server from Osiris's
--        DB_WaypointInfo / DB_WaypointUnlocked tables.
--      - Discovered subregions, populated by Subregion.lua on every
--        entry event (so the player can route back to a region they
--        previously crossed into).
--
-- Both caches are exposed via the public API at the bottom and
-- consumed by WorldNav as "Waypoints" / "Discovered places" routing
-- categories.
--
-- Loca resolution history note: an earlier iteration shipped a
-- preprocessed slug -> TranslatedString-handle map (321 entries)
-- generated from the converted Localization LSX files, with the
-- intent of feeding Ext.Loca.GetTranslatedString.  Empirically the
-- runtime translation pool doesn't index these slugs OR their
-- handles -- both lookups return empty.  The preprocessed map was
-- dead code and was removed.  The widget-read path and server-side
-- entity DisplayName resolution remain the only working paths for
-- subregion / waypoint display names.

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

local Log = BG3Access.Client.Log

-- ============================================================================
-- Net channels.  Match BootstrapServer.lua's local constants.
-- ============================================================================

local CHANNEL_WAYPOINTS_QUERY    = "BG3Access_WaypointsQuery"
local CHANNEL_WAYPOINTS_RESPONSE = "BG3Access_WaypointsResponse"

-- ============================================================================
-- Slug -> display name resolution
-- ============================================================================

-- Resolution cache.  Keyed by raw slug; value is the resolved display
-- string (humanized fallback, or whatever GetTranslatedStringIfSlug
-- returned on the rare slug that's runtime-registered).
local resolvedNameCache = {}

--- HumanizeSlug: convert "DEN_DruidGrove_SUB" -> "Druid Grove" as the
--- standard fallback when Larian's runtime loca tables don't have an
--- entry for this slug.  Strips trailing "_SUB" / "_sub" and leading
--- "WAYP_" prefix patterns, replaces underscores with spaces, splits
--- camelCase boundaries.  Not pretty for every slug but never silent.
local function HumanizeSlug(slug)
    if not slug or slug == "" then return slug end
    local stripped = slug
        :gsub("^WAYP_", "")
        :gsub("_SUB$", "")
        :gsub("_sub$", "")
    -- Split CamelCase into separate words (DruidGrove -> Druid Grove)
    -- before underscore replacement so we don't double-space anything.
    stripped = stripped:gsub("(%l)(%u)", "%1 %2")
    stripped = stripped:gsub("_", " ")
    -- Collapse any double spaces left by the substitutions.
    stripped = stripped:gsub("  +", " ")
    return stripped
end

-- Lazy Helpers reference.  Loaded once; the module is part of the
-- standard client init order and is always available by the time any
-- ResolveDisplayName call fires (entity scans, subregion events).
local Helpers = nil
local function GetHelpers()
    Helpers = Helpers or BG3Access.Client.Helpers
    return Helpers
end

--- ResolveDisplayName: slug -> player-facing display string.
---   1. Cache hit -> return immediately.
---   2. Helpers.GetTranslatedStringIfSlug(slug) -- in theory uses BG3's
---      runtime TextToStringKey map.  Empirically returns nothing for
---      subregion / waypoint / level slugs (the table isn't populated
---      with these), but cheap and defensive -- a future BG3SE version
---      or patch could start populating it.
---   3. Humanized slug fallback ("CRA_Beach_SUB" -> "CRA Beach").
--- kind is an optional hint string -- currently ignored; the slug
--- helper does its own namespace matching internally.  Kept in the
--- signature so callers that pass it don't break.
---
--- For real localized names, prefer:
---   * Subregions: read the SubRegionName / MapLocation TextBlock.
---     Subregion.lua does this and caches the result.
---   * Waypoints: server-side TryGetItemDisplayName on the shrine
---     entity, relayed in the waypoint payload.
local function ResolveDisplayName(slug, kind)
    if not slug or slug == "" then return slug end

    local cached = resolvedNameCache[slug]
    if cached then return cached end

    local helpers = GetHelpers()
    if helpers and helpers.GetTranslatedStringIfSlug then
        local fromSlug = helpers.GetTranslatedStringIfSlug(slug)
        if fromSlug then
            resolvedNameCache[slug] = fromSlug
            return fromSlug
        end
    end

    local humanized = HumanizeSlug(slug)
    resolvedNameCache[slug] = humanized
    return humanized
end

-- ============================================================================
-- Waypoint cache (server-relayed)
-- ============================================================================

-- Most recent unlocked-waypoint list.  Each entry is shaped:
--   { slug, displayName, triggerGuid, position = { x, y, z },
--     levelSlug, levelName, inCurrentLevel }
-- Populated by the CHANNEL_WAYPOINTS_RESPONSE handler; consumed by
-- WorldNav's scanner.
local unlockedWaypoints = {}
local waypointsLastUpdatedTime = 0

--- ParsePosition: tolerant decoder for the server's position payload.
--- Server emits {x, y, z} as a 3-element array of numbers.  Guard
--- against missing fields or string-typed values.
local function ParsePosition(rawPosition)
    if type(rawPosition) ~= "table" then return nil end
    local x = tonumber(rawPosition[1] or rawPosition.x)
    local y = tonumber(rawPosition[2] or rawPosition.y)
    local z = tonumber(rawPosition[3] or rawPosition.z)
    if not (x and y and z) then return nil end
    return { x, y, z }
end

--- HandleWaypointsResponse: server's response to our query.  Replaces
--- the local cache wholesale -- the server query is the authoritative
--- snapshot of "what's unlocked right now."
local function HandleWaypointsResponse(payload)
    local parseOk, data = pcall(Ext.Json.Parse, payload)
    if not parseOk or type(data) ~= "table" then
        Log.Warn("Locations: malformed waypoints response payload")
        return
    end

    local refreshed = {}
    if type(data.waypoints) == "table" then
        for _, raw in ipairs(data.waypoints) do
            if type(raw) == "table" and raw.slug then
                local slug = tostring(raw.slug)
                local position = ParsePosition(raw.position)

                -- Prefer the server-relayed displayName (resolved
                -- from the item entity's DisplayName.NameKey on the
                -- server, where the ECS guarantees the localized
                -- string is available for in-level items).  Fall
                -- back to slug resolution only when the server
                -- couldn't read it -- typically waypoints in
                -- streamed-out levels.
                local relayedName = raw.displayName
                    and tostring(raw.displayName)
                    or nil
                local displayName
                if relayedName and relayedName ~= "" then
                    displayName = relayedName
                else
                    displayName = ResolveDisplayName(slug, "waypoint")
                end

                local entry = {
                    slug           = slug,
                    displayName    = displayName,
                    triggerGuid    = raw.triggerGuid
                        and tostring(raw.triggerGuid)
                        or nil,
                    itemGuid       = raw.itemGuid
                        and tostring(raw.itemGuid)
                        or nil,
                    position       = position,
                    levelSlug      = raw.levelSlug
                        and tostring(raw.levelSlug)
                        or nil,
                    levelName      = nil,
                    inCurrentLevel = raw.inCurrentLevel == true,
                }
                if entry.levelSlug then
                    entry.levelName = ResolveDisplayName(
                        entry.levelSlug, "level")
                end
                refreshed[#refreshed + 1] = entry
            end
        end
    end

    unlockedWaypoints = refreshed
    waypointsLastUpdatedTime = Ext.Utils.MonotonicTime()
    if Log and Log.Info then
        Log.Info(string.format(
            "Locations: %d unlocked waypoints (current-level: %d)",
            #unlockedWaypoints,
            (function()
                local n = 0
                for _, entry in ipairs(unlockedWaypoints) do
                    if entry.inCurrentLevel then n = n + 1 end
                end
                return n
            end)()))
    end
end

Ext.RegisterNetListener(CHANNEL_WAYPOINTS_RESPONSE,
    function(_, payload)
        local ok, err = pcall(HandleWaypointsResponse, payload)
        if not ok and Log and Log.Warn then
            Log.Warn("Locations: waypoints handler error: "
                .. tostring(err))
        end
    end)

--- RequestWaypointsPrime: ask the server for the current list of
--- unlocked waypoints.  Fired automatically on every GameStateChanged
--- to "Running" (save load, level warp, fresh game).  Modules that
--- need a fresh snapshot mid-session (e.g. WorldNav opening the
--- routing list) can call this manually too.
local function RequestWaypointsPrime()
    pcall(Ext.ClientNet.PostMessageToServer,
        CHANNEL_WAYPOINTS_QUERY, "")
end

Ext.Events.GameStateChanged:Subscribe(function(event)
    if tostring(event.ToState) == "Running" then
        RequestWaypointsPrime()
    end
end)

-- Fire once at module load in case we came up after the state
-- transition already happened.
RequestWaypointsPrime()

-- ============================================================================
-- Discovered subregion list (client-side, in-memory)
-- ============================================================================

-- Subregions the player has entered this session.  Keyed by slug so
-- we update the lastPosition on re-entry rather than appending duplicates.
-- Populated externally -- Subregion.lua calls RegisterVisitedSubregion()
-- on every entry event.
local discoveredSubregions = {}

--- RegisterVisitedSubregion: called by Subregion.lua when an entry
--- event fires.  Stores slug + display name + the player's position at
--- the moment of entry, so WorldNav can route back to "the spot where
--- I crossed into Druid Grove" even if the region's trigger volume is
--- offscreen.
---
--- displayName is optional but should be passed when the caller has
--- already resolved the slug to a localized name (e.g. via the
--- SubRegionName widget read).  Without it we fall back to
--- ResolveDisplayName, which for subregion slugs almost always lands
--- on the humanized fallback ("CRA_Beach_SUB" -> "CRA Beach") because
--- the runtime loca tables don't index those slugs.  Passing the
--- widget-resolved name avoids that ugly fallback.
local function RegisterVisitedSubregion(slug, position, displayName)
    if not slug or slug == "" then return end
    if not displayName or displayName == "" then
        displayName = ResolveDisplayName(slug, "subregion")
    end
    discoveredSubregions[slug] = {
        slug        = slug,
        displayName = displayName,
        position    = position,  -- may be nil if caller didn't have it
    }
end

--- ResetDiscoveredSubregions: clear the in-memory list.  Hooked to
--- save load / level warp where the player's known-region context
--- changes wholesale.  In-memory only -- no persistence across saves
--- in this iteration (planned: per-save persistence via mod data).
local function ResetDiscoveredSubregions()
    discoveredSubregions = {}
end

Ext.Events.GameStateChanged:Subscribe(function(event)
    if tostring(event.ToState) == "Running" then
        -- The previous session's list is irrelevant in the new save;
        -- re-entry events will repopulate as the player moves.
        ResetDiscoveredSubregions()
    end
end)

-- ============================================================================
-- Public API
-- ============================================================================

local Locations = {}

--- ResolveDisplayName: slug -> "Druid Grove" (or humanized fallback).
Locations.ResolveDisplayName = ResolveDisplayName

--- GetUnlockedWaypoints: returns the live list of unlocked waypoints
--- (most recent server response).  Each entry has slug, displayName,
--- triggerGuid, itemGuid, position, levelSlug, levelName,
--- inCurrentLevel.  position is nil for waypoints in unloaded levels.
function Locations.GetUnlockedWaypoints()
    return unlockedWaypoints
end

--- GetWaypointsInCurrentLevel: convenience filter for routing.  Only
--- waypoints in the player's current level have positions and are
--- navigable via WorldNav's pathfinding.  Cross-level waypoints are
--- usable for fast-travel via TeleportToWaypoint but not for GPS.
function Locations.GetWaypointsInCurrentLevel()
    local filtered = {}
    for _, entry in ipairs(unlockedWaypoints) do
        if entry.inCurrentLevel and entry.position then
            filtered[#filtered + 1] = entry
        end
    end
    return filtered
end

--- GetDiscoveredSubregions: returns list of {slug, displayName, position}
--- for every subregion the player has entered this session.  Order is
--- insertion order from the underlying hash; callers that need stable
--- ordering should sort by displayName.
function Locations.GetDiscoveredSubregions()
    local list = {}
    for _, entry in pairs(discoveredSubregions) do
        list[#list + 1] = entry
    end
    return list
end

--- RegisterVisitedSubregion: external hook for Subregion.lua.  See
--- internal docstring above.
Locations.RegisterVisitedSubregion = RegisterVisitedSubregion

--- RequestWaypointsPrime: public form of the server query.  Modules
--- that want a fresh snapshot before showing a routing list call this.
Locations.RequestWaypointsPrime = RequestWaypointsPrime

--- WaypointsLastUpdatedTime: monotonic timestamp of the last server
--- response.  WorldNav can use this to detect "I haven't heard back
--- from the server yet" and either retry or show a stale-data hint.
function Locations.WaypointsLastUpdatedTime()
    return waypointsLastUpdatedTime
end

BG3Access.Client.Locations = Locations

if Log and Log.Info then
    Log.Info("Locations: module loaded; waypoints query channel '"
        .. CHANNEL_WAYPOINTS_QUERY .. "'")
end

return Locations
