-- File: Client/Subregion.lua
--
-- Announces subregion transitions ("Entering Ravaged Beach", "Leaving
-- Ravaged Beach") as the player crosses world trigger boundaries.
--
-- Data flow:
--   1. Server side (BootstrapServer.lua) registers Osiris listeners on
--      EnteredTrigger / LeftTrigger events, filters for the host
--      character + DB_Subregion membership, and relays {event, slug}
--      over the BG3Access_SubregionEvent net channel.
--   2. This module receives the relay on the client.  For "enter"
--      events we read the SubRegionName TextBlock from the UI --
--      Larian populates that on the same tick via SetSubRegionName,
--      so the localized display name ("Ravaged Beach") is available
--      through our existing NameScope read path.  We cache slug ->
--      display name so subsequent entries and the "leave"
--      announcement avoid a second UI read.
--
-- Event-driven throughout.  Zero per-tick polling.

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

local Log        = BG3Access.Client.Log
local SpeechData = BG3Access.Client.SpeechData

local SUBREGION_CHANNEL       = "BG3Access_SubregionEvent"
local SUBREGION_QUERY_CHANNEL = "BG3Access_SubregionQuery"

-- slug -> localized display name, populated as the player enters new
-- subregions.  Leaving announcements reuse this cache since the UI
-- text has already updated by the time a "leave" event fires.
local subregionNames = {}

-- Slug of the subregion the player is currently inside.  Used to
-- phrase leaving announcements when we only have the slug coming
-- through the net channel.
local currentSubregionSlug = nil

--- ToTitleCase: turn "RAVAGED BEACH" into "Ravaged Beach".  The
--- Minimap's MapLocation TextBlock formats the subregion name in
--- all caps; TTS handles it but visually the log is cleaner in
--- title case.  Preserves existing mixed-case text untouched when
--- it isn't fully uppercase.
local function ToTitleCase(text)
    if not text or text == "" then return text end
    if text:upper() ~= text then return text end
    local result = text:lower():gsub("(%a)(%w*)", function(first, rest)
        return first:upper() .. rest
    end)
    return result
end

--- ReadCurrentSubRegionText: pulls the rendered subregion name from
--- whichever widget currently exposes it.  Larian binds the name to
--- two different TextBlocks on different widgets:
---   - "SubRegionName" on the always-on-top overlay (title case,
---     matches what the subregion entry toast shows)
---   - "MapLocation" on the Minimap widget (all caps)
--- The toast widget isn't always visible (it fades in only on fresh
--- transitions), but the Minimap's MapLocation is always present
--- once the HUD has loaded.  Try SubRegionName first for the nicer
--- casing, fall back to MapLocation and re-case.
local function TryReadElementText(element)
    if not element then return nil end
    local readOk, entries = pcall(
        Ext.UI.ReadElementStructuredTextBlocks, element)
    if not readOk or not entries then return nil end
    for _, entry in ipairs(entries) do
        if entry.text and entry.text ~= "" then
            return entry.text
        end
    end
    return nil
end

local function ReadCurrentSubRegionText()
    local findOk, element = pcall(
        Ext.UI.FindNameInWidget, "SubRegionName")
    if findOk and element then
        local text = TryReadElementText(element)
        if text and text ~= "" then
            return text
        end
    end

    findOk, element = pcall(
        Ext.UI.FindNameInWidget, "MapLocation")
    if findOk and element then
        local text = TryReadElementText(element)
        if text and text ~= "" then
            return ToTitleCase(text)
        end
    end

    return nil
end

--- Announce a transition through SpeechData.Alert.  Queued rather
--- than interrupting -- a region change is ambient info, not
--- urgent, and interrupting ongoing speech (dialogue, combat alerts)
--- would feel hostile.
local function AnnounceTransition(prefix, name)
    if not name or name == "" then return end
    SpeechData.Alert(prefix .. " " .. name, "queue")
end

--- Event handler for net messages from the server.
--- @param payload string  JSON with { event = "enter"|"leave", slug }.
local function OnSubregionEvent(payload)
    local parseOk, data = pcall(Ext.Json.Parse, payload)
    if not parseOk or type(data) ~= "table" then return end
    if not data.event or not data.slug then return end
    local slug = tostring(data.slug)

    if data.event == "enter" or data.event == "initial" then
        -- "enter": crossed a boundary.  Phrase as "Entering X".
        -- "initial": player loaded into the subregion (save load,
        -- level warp).  Phrase as "You are in X" so it doesn't
        -- sound like a fresh crossing the player just made.
        local prefix = data.event == "initial"
            and "You are in"
            or "Entering"

        -- Cache hit: announce immediately.
        local cachedName = subregionNames[slug]
        if cachedName then
            currentSubregionSlug = slug
            AnnounceTransition(prefix, cachedName)
            Log.Info("Subregion: " .. data.event .. " " .. slug
                .. " (cached: " .. cachedName .. ")")
            return
        end
        -- Cache miss: read the UI widget.  Larian's own SetSubRegionName
        -- call fires on the same tick as EnteredTrigger so the text
        -- should already be current by the time the net relay
        -- round-trip delivers.  If the read returns nil (widget not
        -- visible yet, early frame, etc.), fall back to speaking
        -- the cleaned-up slug rather than going silent.
        local displayName = ReadCurrentSubRegionText()
        if not displayName or displayName == "" then
            -- Fallback: strip the _SUB / _ area suffixes, replace
            -- underscores with spaces.  Not pretty but not silent.
            displayName = slug
                :gsub("_SUB$", "")
                :gsub("_sub$", "")
                :gsub("_", " ")
            Log.Info("Subregion: UI read failed for " .. slug
                .. ", using slug fallback: " .. displayName)
        else
            subregionNames[slug] = displayName
            Log.Info("Subregion: " .. data.event .. " " .. slug
                .. " -> " .. displayName)
        end
        currentSubregionSlug = slug
        AnnounceTransition(prefix, displayName)

    elseif data.event == "leave" then
        local cachedName = subregionNames[slug]
        if not cachedName then
            -- We never cached a name for this slug (entered before
            -- our listener was active, e.g. mid-session reload).
            -- Try a UI read one more time; on failure, stay silent
            -- rather than leak a slug.
            cachedName = ReadCurrentSubRegionText()
            if cachedName and cachedName ~= "" then
                subregionNames[slug] = cachedName
            end
        end
        if cachedName and cachedName ~= "" then
            AnnounceTransition("Leaving", cachedName)
            Log.Info("Subregion: left " .. slug
                .. " (" .. cachedName .. ")")
        else
            Log.Info("Subregion: left " .. slug
                .. " (no cached name, silent)")
        end
        if currentSubregionSlug == slug then
            currentSubregionSlug = nil
        end
    end
end

Ext.RegisterNetListener(SUBREGION_CHANNEL, function(_, payload)
    local ok, err = pcall(OnSubregionEvent, payload)
    if not ok then
        Log.Warn("Subregion handler error: " .. tostring(err))
    end
end)

--- Request the current subregion from the server.  EnteredTrigger
--- doesn't fire for triggers the player is already standing inside,
--- so after save loads / level warps we need to explicitly ask.
--- The server queries TriggerIsInsideOf on the host character and
--- broadcasts an "initial" event for the most specific subregion.
local function RequestSubregionPrime()
    pcall(Ext.ClientNet.PostMessageToServer,
        SUBREGION_QUERY_CHANNEL, "")
end

-- Fire the prime on every transition to Running: save load, level
-- warp, fresh game start.  A small tick delay after the event would
-- be safer (host character may not be fully resolved at the exact
-- transition instant), but in practice the server-side resolution
-- is forgiving -- if host is nil we just no-op and the next widget-
-- driven event will catch it.
Ext.Events.GameStateChanged:Subscribe(function(event)
    if tostring(event.ToState) == "Running" then
        RequestSubregionPrime()
    end
end)

-- Also fire once right now in case the module loaded after the
-- state already transitioned (mid-session reload, dev reload, etc.).
RequestSubregionPrime()

BG3Access.Client.Subregion = {
    --- GetCurrentSubRegionName: returns the cached display name of
    --- the subregion the host character is currently inside, or nil
    --- if we haven't entered one yet this session (or we entered
    --- before our listener came online).  Other modules can use this
    --- to include the current location in speech output.
    GetCurrentSubRegionName = function()
        if not currentSubregionSlug then return nil end
        return subregionNames[currentSubregionSlug]
    end,
}

Log.Info("Subregion: listener registered on '"
    .. SUBREGION_CHANNEL .. "'")
