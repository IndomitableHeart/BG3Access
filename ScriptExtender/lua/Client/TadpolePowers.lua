-- File: Client/TadpolePowers.lua
--
-- Brain panel (Illithid Powers / TadpolePowersTree_c) handler for
-- BG3Access.  Stick-driven cursor navigation with rich speech of the
-- focused power plus its 8 nearest spatial neighbors.
--
-- Architecture:
--   * The user moves Larian's in-game SoftwareCursor with the right
--     stick.  No programmatic cursor movement on our side.
--   * OnTadpoleAxisInput schedules a deferred ReadAndSpeakFocusedPower
--     on stick deflection (throttled so a held stick produces ~12 Hz
--     reads, not 60 Hz).
--   * ReadAndSpeakFocusedPower reads
--     cursor.TopFocusedElement.DataContext.Power for the focused
--     power's VM, then pulls Larian's full ExtenderData
--     (Cost/Recharge/Duration/Lore) via TryReadPowerExtenderData
--     (with a few-frame retry loop because Larian's TooltipExtender
--     populates ExtenderData asynchronously after the tooltip opens).
--   * After speaking the power, a follow-up alert names the 8 nearest
--     neighbors by compass direction ("up to Psionic Overload, right
--     to Beginnings, ...") so the user builds a mental map of the
--     radial layout.
--   * A button passes through to Larian's native LSButton unlock
--     handler -- its CommandParameter is bound to
--     Cursor.TopFocusedElement.DataContext (the focused
--     VMTadpolePower) so activation, hold-button build-up sound, and
--     visual feedback all work natively.  We do NOT PreventAction.
--   * On the first A press in a panel session (transitioning from the
--     info screen to manage view), we queue a one-time layout overview
--     hint so the user knows the brain has 26 radially-arranged powers
--     and how to navigate.

local Log = BG3Access.Client.Log
local Helpers = BG3Access.Client.Helpers
local SpeechData = BG3Access.Client.SpeechData

-- ============================================================================
-- Subscriptions and reader state
-- ============================================================================

local tadpoleInputSubscriptionId = nil
local tadpoleAxisSubscriptionId = nil

-- Name of the most recently focused power.  Purely a dedup signal:
-- when the cursor stays inside the same power's hit area between
-- consecutive reads, we don't want to re-speak.  Pairs with the
-- cursorWasOnPower transition flag below to allow re-speech when the
-- cursor leaves and returns to the same power.
local lastFocusedPowerName = nil

-- Tracks whether the cursor's last read was on a power.  Used purely
-- for dedup: when the cursor is sliding within a single power's hit
-- area, we don't want to re-speak.  When the cursor goes off-power
-- then comes back (even to the same power), we DO want to re-speak.
local cursorWasOnPower = false

-- Stick-throttle gate.  While a deferred read is pending, additional
-- axis events are no-ops.  Cleared inside the read function so the
-- next axis event after the read fires can schedule another.  Result:
-- ~1 read per 5 frames (~12 Hz) while the stick is held, fast enough
-- to track the cursor across powers but slow enough not to thrash
-- ReadElementPath.
local stickReadPending = false

-- Cancel handle for the deferred power read.  Used when chaining
-- retries (ExtenderData not yet populated) so an outstanding read
-- doesn't leak into a panel close.
local cancelPendingPowerRead = nil

-- Cancel handle for the deferred auto-orientation that fires once
-- after the manage-mode hint plays (so the player learns where powers
-- are around them at panel-entry time).
local cancelPendingAutoOrient = nil

-- Stick deflection threshold.  Below this we treat the stick as at
-- rest -- matches the conservative end of the RS thresholds in
-- EventRouter, and Larian's cursor has its own deadzone anyway.
local TADPOLE_STICK_DEFLECT_THRESHOLD = 0.3

-- Left-stick axes that move the cursor on this screen.
local TADPOLE_STICK_AXES = {
    LeftX = true,
    LeftY = true,
}

-- One-time per-session diagnostic: dump the focused Power VM's full
-- property bag so we can see what fields are exposed (Description,
-- Type, DisplayName, etc.).
local powerObjectDumped = false

-- Manage-mode hint: spoken once per panel session when the user first
-- presses A to transition from info screen to manage view.
local manageModeHintSpoken = false

-- ============================================================================
-- Constants: state labels, cost/cooldown/duration enums, subtitle handles
-- ============================================================================

-- Map VMTadpolePower.State enum to spoken label.  Per
-- TadpolePowersTree_c.xaml DataTriggers (lines 210-244):
--   Hidden   = padlock visual, IsEnabled=False (cursor can't focus,
--              so we never reach here via the stick path).
--   Disabled = visible but greyed out (prerequisite not met OR no
--              tadpoles available).  Speak as "not yet available".
--   Enabled  = ready to unlock right now.  Speak as "available".
--   Active   = already unlocked.  Speak as "unlocked".
local TADPOLE_STATE_LABELS = {
    Active   = "unlocked",
    Enabled  = "available",
    Disabled = "not yet available",
}

-- Subtitle handles from Tooltips.xaml's PassivesTooltip DataTemplate
-- (line 6337/6408).  IsToggleable=true selects the TOGGLEABLE variant,
-- false the DEFAULT.  Resolved at speech time so we get whatever
-- localization the player has set.
local SUBTITLE_HANDLE_PASSIVE_TOGGLEABLE =
    "he8ad7cd6g0ffag472ega526g52c8ef0560f1"
local SUBTITLE_HANDLE_PASSIVE_DEFAULT =
    "h099ebd82g6ea7g43b7gbf0fg69e32653f322"

-- Cost-type label map.  ExtenderData CostSummary items have a TypeId
-- enum naming the consumed resource; we map to short audio-friendly
-- labels.
local COST_TYPE_LABELS = {
    ActionPoint            = "action",
    BonusActionPoint       = "bonus action",
    ReactionActionPoint    = "reaction",
    Movement               = "movement",
    SpellSlotsGroup        = "spell slot",
    SorceryPoint           = "sorcery point",
    KiPoint                = "ki point",
    SuperiorityDie         = "superiority die",
    InspirationPoint       = "bardic inspiration",
    WildShape              = "wild shape charge",
    Rage                   = "rage charge",
    ChannelDivinity        = "channel divinity",
    ChannelOath            = "channel oath",
    LayOnHands             = "lay on hands charge",
    Tadpole                = "tadpole",
    WarPriestActionPoint   = "war priest action",
    DeflectMissiles_Charge = "deflect missiles charge",
}

-- Property TypeId+SubtypeId combinations.  ExtenderData Properties
-- items typically have TypeId="Cooldown" + a SubtypeId enum that says
-- when the ability recharges.  Phrasing matches the visual tooltip's
-- compact display.  Spoken as "Recharge: Short Rest" etc.
local COOLDOWN_SUBTYPE_LABELS = {
    OncePerTurn             = "once per turn",
    OncePerCombat           = "once per combat",
    UntilRest               = "rest",
    UntilShortRest          = "Short Rest",
    UntilLongRest           = "Long Rest",
    OncePerShortRestPerItem = "Short Rest, per item",
    OncePerLongRestPerItem  = "Long Rest, per item",
    UntilTrigger            = "until trigger",
}

-- Duration-type enum -> noun for InflictedStatusesSection.Details
-- entries.  Larian names the enum for the underlying mechanic
-- ("Timer" = combat-frame countdown) rather than the rendered unit;
-- the visual tooltip renders a "Timer"-typed duration as "turns"
-- because combat ticks one Timer-step per turn.
local DURATION_TYPE_LABELS = {
    Timer            = "turns",
    Turn             = "turns",
    Turns            = "turns",
    Rounds           = "rounds",
    Seconds          = "seconds",
    Hours            = "hours",
    Days             = "days",
    Permanent        = "permanent",
    UntilLongRest    = "until long rest",
    UntilShortRest   = "until short rest",
    UntilTriggered   = "until triggered",
    UntilTurnEnd     = "until end of turn",
    Instant          = "instant",
}

-- ============================================================================
-- Spatial layout: hardcoded Canvas positions of the 26 power nodes
-- ============================================================================

-- Canvas positions for the 26 power nodes.  Verbatim from
-- TadpoleTemplates.xaml line 506-609 (Tadpoles.PowersItemsControlStyle
-- DataTriggers binding ItemsControl AlternationIndex -> Canvas.Left/
-- Top per generated ContentPresenter).  AlternationIndex N maps to
-- POWER_CANVAS_POSITIONS[N+1] (Lua is 1-indexed).  Y increases
-- downward in Canvas coordinates so "up" is negative dy (handled
-- by BearingToClockHour's atan2(dx, -dy) below).
local POWER_CANVAS_POSITIONS = {
    {x = 1234, y = 1556},  --  1: AlternationIndex  0 (center, Persuasion)
    {x = 1206, y = 1146},  --  2: AlternationIndex  1
    {x = 1480, y = 1382},  --  3: AlternationIndex  2
    {x = 1433, y = 1794},  --  4: AlternationIndex  3
    {x = 1018, y = 1836},  --  5: AlternationIndex  4
    {x =  938, y = 1349},  --  6: AlternationIndex  5
    {x =  998, y =  718},  --  7: AlternationIndex  6
    {x = 1413, y =  731},  --  8: AlternationIndex  7
    {x = 1798, y = 1038},  --  9: AlternationIndex  8
    {x = 1871, y = 1586},  -- 10: AlternationIndex  9
    {x = 1703, y = 2098},  -- 11: AlternationIndex 10
    {x = 1454, y = 2468},  -- 12: AlternationIndex 11
    {x =  922, y = 2462},  -- 13: AlternationIndex 12
    {x =  688, y = 2128},  -- 14: AlternationIndex 13
    {x =  558, y = 1482},  -- 15: AlternationIndex 14
    {x =  658, y =  978},  -- 16: AlternationIndex 15
    {x =  813, y =  262},  -- 17: AlternationIndex 16 (outer ring start)
    {x = 1548, y =  258},  -- 18: AlternationIndex 17
    {x = 2044, y =  734},  -- 19: AlternationIndex 18
    {x = 2232, y = 1524},  -- 20: AlternationIndex 19
    {x = 2138, y = 2266},  -- 21: AlternationIndex 20
    {x = 1630, y = 2822},  -- 22: AlternationIndex 21
    {x =  784, y = 2836},  -- 23: AlternationIndex 22
    {x =  266, y = 2318},  -- 24: AlternationIndex 23
    {x =  185, y = 1592},  -- 25: AlternationIndex 24
    {x =  322, y =  728},  -- 26: AlternationIndex 25
}

-- Clock-face ray-cast: for each of 12 clock-hour push directions,
-- predict which power the cursor would FIRST reach if pushed at
-- that bearing.  The cursor moves smoothly in the stick direction,
-- so a power is "reachable by clock hour H" if and only if its
-- center falls within HIT_RADIUS perpendicular distance of the H
-- ray and lies forward of the cursor.  We then pick the closest
-- (smallest forward distance) qualifying power per direction.
--
-- This predicts navigation outcome rather than just labeling
-- bearings.  A power whose bearing rounds to 12 o'clock but is
-- 120 px off the pure-up axis won't be announced under 12, because
-- the cursor's pure-up trajectory wouldn't actually cross it.

-- Perpendicular hit tolerance.  Power icons render at 163 px
-- (PowerIconSize) inside a 236 px container (PowerIconContainer).
-- 100 px is a forgiving radius slightly under the container's
-- half-width -- a power whose center is within 100 px of the ray
-- will be touched by the cursor's path.
local CLOCK_HIT_RADIUS = 100

-- 12 unit-vectors for each clock hour.  Canvas Y increases downward
-- so "up" (12 o'clock) is dy = -1.  Bearing = hour * 30 degrees
-- clockwise from up.
--   12 -> bearing   0deg -> (dx=0, dy=-1)  (up)
--    3 -> bearing  90deg -> (dx=1, dy=0)   (right)
--    6 -> bearing 180deg -> (dx=0, dy=1)   (down)
--    9 -> bearing 270deg -> (dx=-1, dy=0)  (left)
local CLOCK_DIRECTIONS = {}
for hour = 1, 12 do
    local bearingRad = (hour % 12) * math.pi / 6
    CLOCK_DIRECTIONS[hour] = {
        dx = math.sin(bearingRad),
        dy = -math.cos(bearingRad),
    }
end

-- Read order: 12, 1, 2, ... 11.  Matches a clock face read from
-- noon clockwise.
local CLOCK_READ_ORDER = {12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}

-- FormatNearbyPowers: assign each power to its bearing-based clock
-- hour (the hour whose direction the power's actual bearing rounds
-- to), then filter to only powers whose perpendicular distance from
-- that hour's ray is within CLOCK_HIT_RADIUS.
--
-- Why bearing-based instead of ray-cast-per-hour: a ray-cast model
-- picks "the closest power along this hour's ray" which can name
-- the wrong hour for a power whose ACTUAL bearing is closer to a
-- different hour.  For example, a power at bearing 175 degrees
-- (almost pure down) might land in the 7-o'clock ray's hit zone
-- with smaller forward distance than the 6-o'clock ray's hit zone,
-- so ray-cast labels it 7-o'clock -- but its real direction is
-- 6-o'clock (180 degrees), and pushing 6 is what reaches it most
-- directly.  Bearing-based assignment labels by actual direction.
--
-- Hit-radius filtering still applies: a power whose rounded-bearing
-- ray passes more than CLOCK_HIT_RADIUS from its center isn't on
-- any reachable axis from the cursor (e.g., halfway between two
-- clock hours, in a "dead zone").  Those are skipped.
local function FormatNearbyPowers(
    cursorX, cursorY, powerList, excludeIdx)
    if not powerList or #powerList == 0 then return nil end

    -- Pass 1: compute each power's bearing-rounded clock hour and
    -- the perpendicular distance from that hour's ray.  Skip the
    -- power if its center is too far off that ray (dead zone).
    local entriesByHour = {}
    for index = 1, #POWER_CANVAS_POSITIONS do
        if index ~= excludeIdx then
            local pos = POWER_CANVAS_POSITIONS[index]
            local power = powerList[index]
            if pos and power and power.displayName then
                local dx = pos.x - cursorX
                local dy = pos.y - cursorY
                local distance = math.sqrt(dx * dx + dy * dy)
                if distance > 0 then
                    local angle = Ext.Math.Atan2(dx, -dy)
                    if angle < 0 then
                        angle = angle + 2 * math.pi
                    end
                    local hour = math.floor(
                        angle / (math.pi / 6) + 0.5)
                    if hour <= 0 then hour = hour + 12 end
                    if hour > 12 then hour = hour - 12 end

                    local dir = CLOCK_DIRECTIONS[hour]
                    local perp = math.abs(
                        dx * dir.dy - dy * dir.dx)

                    if perp <= CLOCK_HIT_RADIUS then
                        -- Comma included in the prefix so TTS pauses
                        -- between the name and "padlocked".  Without
                        -- it the format string concatenates directly
                        -- ("Awakened padlocked") and the words run
                        -- together as a single phrase.
                        local stateNote = ""
                        if power.state == "Hidden"
                            or (power.state or "") == "" then
                            stateNote = ", padlocked"
                        end
                        local entry = {
                            name      = power.displayName,
                            distance  = distance,
                            stateNote = stateNote,
                        }
                        -- Multiple powers may round to the same
                        -- hour.  Keep the closest by distance
                        -- (most actionable for navigation).
                        local existing = entriesByHour[hour]
                        if not existing
                            or distance < existing.distance then
                            entriesByHour[hour] = entry
                        end
                    end
                end
            end
        end
    end

    -- Pass 2: format in clock read order (12, 1, 2, ..., 11).
    local parts = {}
    for _, hour in ipairs(CLOCK_READ_ORDER) do
        local entry = entriesByHour[hour]
        if entry then
            parts[#parts + 1] = string.format(
                "%d o'clock to %s%s",
                hour, entry.name, entry.stateNote)
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ". ")
end

-- FormatNeighborsAtPosition: clock-face listing from an arbitrary
-- canvas point (cursor between powers).
local function FormatNeighborsAtPosition(cursorX, cursorY, powerList)
    return FormatNearbyPowers(cursorX, cursorY, powerList, nil)
end

-- FormatNeighbors: clock-face listing relative to a focused power.
-- The focused power is excluded from results.
local function FormatNeighbors(focusedIndex, powerList)
    if not powerList or #powerList == 0 then return nil end
    local selfPos = POWER_CANVAS_POSITIONS[focusedIndex]
    if not selfPos then return nil end
    return FormatNearbyPowers(
        selfPos.x, selfPos.y, powerList, focusedIndex)
end


-- ============================================================================
-- Static lookup of TadpolePower prereqs / Half-Illithid requirement
-- ============================================================================

-- Lazy-built lookup keyed by stats name.  Each entry holds:
--   prereqDisplayNames -- array of human-readable prerequisite names
--   needsHalfIllithid  -- true if NeedsHalfIllithidToUnlock is set
-- Built once per session and retained -- static data doesn't change
-- at runtime.
local tadpolePowerLookup = nil

-- ResolveStatDisplayName: stats name -> localized display name.
-- Tadpole powers split across both stats categories: TAD_Illithid
-- Persuasion is a passive, Shout_TAD_PsionicOverload is a spell.
local function ResolveStatDisplayName(statsName)
    if not statsName or statsName == "" then return statsName end

    local passiveOk, cachedPassive =
        pcall(Ext.Stats.GetCachedPassive, statsName)
    if passiveOk and cachedPassive and cachedPassive.Description then
        local displayName = Helpers.ResolveTranslatedString(
            cachedPassive.Description.DisplayName)
        if displayName and displayName ~= "" then return displayName end
    end

    local spellOk, cachedSpell =
        pcall(Ext.Stats.GetCachedSpell, statsName)
    if spellOk and cachedSpell and cachedSpell.Description then
        local displayName = Helpers.ResolveTranslatedString(
            cachedSpell.Description.DisplayName)
        if displayName and displayName ~= "" then return displayName end
    end

    return statsName
end

local function BuildTadpolePowerLookup()
    if tadpolePowerLookup then return tadpolePowerLookup end
    tadpolePowerLookup = {}

    local allOk, allUuids = pcall(Ext.StaticData.GetAll, "TadpolePower")
    if not allOk or not allUuids then return tadpolePowerLookup end

    -- First pass: UUID -> stats name (so we can resolve prereq UUIDs).
    local uuidToStatsName = {}
    for _, uuid in ipairs(allUuids) do
        local resOk, res = pcall(
            Ext.StaticData.Get, uuid, "TadpolePower")
        if resOk and res and res.Name and res.Name ~= "" then
            uuidToStatsName[uuid] = res.Name
        end
    end

    -- Second pass: build the keyed lookup with display-name prereqs.
    for _, uuid in ipairs(allUuids) do
        local resOk, res = pcall(
            Ext.StaticData.Get, uuid, "TadpolePower")
        if resOk and res and res.Name and res.Name ~= "" then
            local prereqDisplayNames = {}
            if res.Prerequisites then
                for _, prereqUuid in ipairs(res.Prerequisites) do
                    local prereqStatsName = uuidToStatsName[prereqUuid]
                    if prereqStatsName then
                        prereqDisplayNames[#prereqDisplayNames + 1] =
                            ResolveStatDisplayName(prereqStatsName)
                    end
                end
            end
            tadpolePowerLookup[res.Name] = {
                prereqDisplayNames = prereqDisplayNames,
                needsHalfIllithid = res.NeedsHalfIllithidToUnlock
                    and true or false,
            }
        end
    end
    return tadpolePowerLookup
end

-- ============================================================================
-- Power inventory (for neighbor name lookup)
-- ============================================================================

-- powerInventory is an array indexed 1..26 matching
-- POWER_CANVAS_POSITIONS.  Each entry holds scalar metadata only --
-- no userdata references (those expire at tick boundary per CLAUDE.md).
--   displayName -- localized power name for speech
--   _type       -- "ls.VMPassive" or "ls.VMCharacterAction"
--   statsKey    -- PassiveName (passives) or PrototypeID (actions)
--   state       -- "Active" / "Enabled" / "Disabled" / "Hidden"
-- Build is deferred ~10 frames after panel open so the brain widget's
-- DataContext has time to bind TadpolePowers.
local powerInventory = nil
local powerInventoryBuilt = false
local cancelPendingInventoryBuild = nil

local function BuildPowerInventory()
    cancelPendingInventoryBuild = nil
    if powerInventoryBuilt then return end

    powerInventory = nil

    local widget = Ext.UI.FindNameInWidget("TadpolePowersTree_c")
    if not widget then return end

    local dc = nil
    pcall(function() dc = widget.DataContext end)
    if not dc then return end

    local dcProps = nil
    pcall(function() dcProps = dc:GetAllProperties() end)
    if not dcProps then return end

    -- Walk CurrentPlayer.SelectedCharacter.PlayerCharacterProperties.
    -- TadpolePowers per the XAML's ItemsSource binding on the Powers
    -- ItemsControl (TadpolePowersTree_c.xaml line 137).
    local powersCollection = nil
    pcall(function()
        local cp = dcProps.CurrentPlayer
        if cp then
            local cpProps = cp:GetAllProperties()
            if cpProps then
                local sc = cpProps.SelectedCharacter
                if sc then
                    local scProps = sc:GetAllProperties()
                    if scProps then
                        local pcp = scProps.PlayerCharacterProperties
                        if pcp then
                            local pcpProps = pcp:GetAllProperties()
                            if pcpProps then
                                powersCollection = pcpProps.TadpolePowers
                            end
                        end
                    end
                end
            end
        end
    end)
    if not powersCollection then return end

    local lenOk, lenVal = pcall(function() return #powersCollection end)
    if not lenOk or not lenVal then return end

    powerInventory = {}
    for collectionIndex = 1, lenVal do
        local itemOk, item = pcall(function()
            return powersCollection[collectionIndex]
        end)
        if itemOk and item then
            local entry = {}
            local itemPropsOk, itemProps = pcall(function()
                return item:GetAllProperties()
            end)
            if itemPropsOk and itemProps then
                entry.state = tostring(itemProps.State or "")
                local power = itemProps.Power
                if power then
                    local powerProps = nil
                    pcall(function()
                        powerProps = power:GetAllProperties()
                    end)
                    if powerProps then
                        entry._type = powerProps._type
                            or tostring(power.Type or "")
                        entry.statsKey = powerProps.PassiveName
                            or powerProps.PrototypeID
                        local rawName = powerProps.Name
                        if type(rawName) == "string" then
                            local resolved =
                                Helpers.ResolveTranslatedString(rawName)
                            entry.displayName =
                                (resolved and resolved ~= "")
                                and resolved or rawName
                        end
                    end
                end
            end
            powerInventory[#powerInventory + 1] = entry
        end
    end

    powerInventoryBuilt = true
    Log.Info("TADPOLE INVENTORY: built " .. tostring(#powerInventory)
        .. " powers")
end

-- ============================================================================
-- TooltipExtender read: structured Cost / Recharge / Duration / Lore
-- ============================================================================

-- ResolvePassiveSubtitle: pick the "Passive Feature" subtitle variant
-- to match the visual tooltip's DataTrigger logic.
local function ResolvePassiveSubtitle(isToggleable)
    local handle = isToggleable
        and SUBTITLE_HANDLE_PASSIVE_TOGGLEABLE
        or SUBTITLE_HANDLE_PASSIVE_DEFAULT
    local resolved = Helpers.ResolveTranslatedString(handle)
    if resolved and resolved ~= "" then return resolved end
    return "Passive Feature"
end

-- TryReadPowerExtenderData: read PowerTooltip.Content.ExtenderData[1]
-- and return a structured table of the fields the visual tooltip
-- displays.
--
-- Data path: TadpolePowersTree_c.xaml line 460's ChangePropertyAction
-- sets PowerTooltip.Content = TopFocusedElement.DataContext.Power
-- whenever the cursor moves to a power.  Larian's TooltipExtender
-- system computes ExtenderData asynchronously after the tooltip
-- opens.  We retry the read a few times in ReadAndSpeakFocusedPower
-- to catch the async population.
--
-- Returns nil when ExtenderData isn't yet populated (caller retries
-- or falls back to API-only speech).  Fields on the returned table
-- (any may be nil):
--   name             -- resolved title
--   isToggleable     -- boolean (passives only)
--   loreDescription  -- resolved italic flavor text
--   description      -- main body with [N] placeholders substituted,
--                       nil when any placeholder couldn't be filled
--   extraDescription -- second body paragraph
--   costParts        -- array of { label, value, tier } from CostSummary
--   propertyParts    -- array of { label, value, tier } from Properties
--                       and InflictedStatusesSection.Details (Duration)
--   unavailableLines -- array of plain strings from UnavailableReasons
local function TryReadPowerExtenderData()
    local ttElem = Ext.UI.FindNameInWidget("PowerTooltip")
    if not ttElem then return nil end

    local content = nil
    pcall(function() content = ttElem.Content end)
    if not content then return nil end

    local cgapOk, cgap = pcall(function()
        return content:GetAllProperties()
    end)
    if not cgapOk or not cgap then return nil end

    local extData = cgap.ExtenderData
    if not extData then return nil end

    local lenOk, lenVal = pcall(function() return #extData end)
    if not lenOk or not lenVal or lenVal < 1 then return nil end

    local itemOk, item = pcall(function() return extData[1] end)
    if not itemOk or not item then return nil end

    local apOk, ap = pcall(function() return item:GetAllProperties() end)
    if not apOk or not ap then return nil end

    local result = {}

    if type(ap.Name) == "string" and ap.Name ~= "" then
        local resolvedName = Helpers.ResolveTranslatedString(ap.Name)
        if resolvedName and resolvedName ~= "" then
            result.name = resolvedName
        end
    end

    if type(ap.IsToggleable) == "boolean" then
        result.isToggleable = ap.IsToggleable
    end

    if type(ap.LoreDescription) == "string"
        and ap.LoreDescription ~= ""
        and not ap.LoreDescription:find("s_HandleUnknown", 1, true) then
        local resolvedLore = Helpers.ResolveTranslatedString(
            ap.LoreDescription)
        if resolvedLore and resolvedLore ~= "" then
            result.loreDescription = resolvedLore
        end
    end

    -- ResolveCtxString: read the Text template from a CtxTransString-
    -- shaped BaseComponent and substitute [N] placeholders from
    -- Params[i].Text.  Returns nil when Text is empty OR when any
    -- placeholder couldn't be filled (caller falls back to API).
    local function ResolveCtxString(component)
        if type(component) ~= "userdata" then return nil end
        local propsOk, props = pcall(function()
            return component:GetAllProperties()
        end)
        if not propsOk or not props then return nil end
        if type(props.Text) ~= "string" or props.Text == "" then
            return nil
        end
        local template = props.Text

        local paramTexts = {}
        if type(props.Params) == "userdata" then
            local lenOk2, lenVal2 = pcall(function()
                return #props.Params
            end)
            if lenOk2 and lenVal2 and lenVal2 > 0 then
                for paramIndex = 1, lenVal2 do
                    local pOk, paramComp = pcall(function()
                        return props.Params[paramIndex]
                    end)
                    if pOk and paramComp then
                        local ppOk, paramProps = pcall(function()
                            return paramComp:GetAllProperties()
                        end)
                        if ppOk and paramProps
                            and type(paramProps.Text) == "string"
                            and paramProps.Text ~= "" then
                            paramTexts[paramIndex] = paramProps.Text
                        end
                    end
                end
            end
        end

        local resolved = template:gsub("%[(%d+)%]", function(numStr)
            local idx = tonumber(numStr)
            return paramTexts[idx] or ("[" .. numStr .. "]")
        end)

        if resolved:find("%[%d+%]") then return nil end
        return Helpers.StripMarkupTags(resolved)
    end

    result.description = ResolveCtxString(ap.Description)
    result.extraDescription = ResolveCtxString(ap.ExtraDescription)

    -- CostSummary -> { label = "Cost", value = "1 action", tier }
    if type(ap.CostSummary) == "userdata" then
        result.costParts = {}
        local csLenOk, csLen = pcall(function()
            return #ap.CostSummary
        end)
        if csLenOk and csLen and csLen > 0 then
            for ci = 1, csLen do
                local csItemOk, csItem = pcall(function()
                    return ap.CostSummary[ci]
                end)
                if csItemOk and csItem then
                    local csPropsOk, csProps = pcall(function()
                        return csItem:GetAllProperties()
                    end)
                    if csPropsOk and csProps
                        and not csProps.IsHidden then
                        local typeId = tostring(csProps.TypeId or "")
                        local label = COST_TYPE_LABELS[typeId] or typeId
                        local valueNum = tonumber(csProps.Value) or 0
                        if valueNum > 0 and label ~= "" then
                            local valueLabel = label
                            if valueNum > 1 then
                                valueLabel = label .. "s"
                            end
                            result.costParts[#result.costParts + 1] = {
                                label = "Cost",
                                value = tostring(math.floor(valueNum))
                                    .. " " .. valueLabel,
                                tier  = "normal",
                            }
                        end
                    end
                end
            end
        end
    end

    -- Properties -> { label = "Recharge", value = "Short Rest", tier }
    if type(ap.Properties) == "userdata" then
        result.propertyParts = {}
        local pLenOk, pLen = pcall(function() return #ap.Properties end)
        if pLenOk and pLen and pLen > 0 then
            for pi = 1, pLen do
                local pItemOk, pItem = pcall(function()
                    return ap.Properties[pi]
                end)
                if pItemOk and pItem then
                    local pPropsOk, pProps = pcall(function()
                        return pItem:GetAllProperties()
                    end)
                    if pPropsOk and pProps then
                        local typeId = tostring(pProps.TypeId or "")
                        local subtypeId = tostring(
                            pProps.SubtypeId or "")
                        if typeId == "Cooldown" then
                            local phrase =
                                COOLDOWN_SUBTYPE_LABELS[subtypeId]
                                or subtypeId
                            if phrase ~= "" then
                                result.propertyParts[
                                    #result.propertyParts + 1] = {
                                    label = "Recharge",
                                    value = phrase,
                                    tier  = "normal",
                                }
                            end
                        elseif typeId ~= "" then
                            -- Surface unknown property types verbose
                            -- so we notice + can map them later.
                            result.propertyParts[
                                #result.propertyParts + 1] = {
                                label = typeId,
                                value = subtypeId ~= ""
                                    and subtypeId or "",
                                tier  = "verbose",
                            }
                        end
                    end
                end
            end
        end
    end

    -- InflictedStatusesSection.Details -> Duration entries.
    -- "10 turns" / "permanent" / "until long rest" etc.
    if type(ap.InflictedStatusesSection) == "userdata" then
        local issOk, issProps = pcall(function()
            return ap.InflictedStatusesSection:GetAllProperties()
        end)
        if issOk and issProps
            and type(issProps.Details) == "userdata" then
            local dLenOk, dLen = pcall(function()
                return #issProps.Details
            end)
            if dLenOk and dLen and dLen > 0 then
                for di = 1, dLen do
                    local dItemOk, dItem = pcall(function()
                        return issProps.Details[di]
                    end)
                    if dItemOk and dItem then
                        local dPropsOk, dProps = pcall(function()
                            return dItem:GetAllProperties()
                        end)
                        if dPropsOk and dProps then
                            local duration = tonumber(dProps.Duration)
                            local durType =
                                tostring(dProps.DurationType or "")
                            local unit = DURATION_TYPE_LABELS[durType]
                                or durType
                            local valueText
                            if duration and duration > 0
                                and unit and unit ~= "" then
                                if unit == "permanent"
                                    or unit == "instant" then
                                    valueText = unit
                                else
                                    valueText = tostring(duration)
                                        .. " " .. unit
                                end
                            elseif unit == "permanent"
                                or unit == "instant"
                                or unit == "until long rest"
                                or unit == "until short rest"
                                or unit == "until triggered"
                                or unit == "until end of turn" then
                                valueText = unit
                            end
                            if valueText then
                                result.propertyParts =
                                    result.propertyParts or {}
                                result.propertyParts[
                                    #result.propertyParts + 1] = {
                                    label = "Duration",
                                    value = valueText,
                                    tier  = "normal",
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    -- UnavailableReasons -> exact "Not trained yet" text.
    if type(ap.UnavailableReasons) == "userdata" then
        result.unavailableLines = {}
        local uLenOk, uLen = pcall(function()
            return #ap.UnavailableReasons
        end)
        if uLenOk and uLen and uLen > 0 then
            for ui = 1, uLen do
                local uItemOk, uItem = pcall(function()
                    return ap.UnavailableReasons[ui]
                end)
                if uItemOk and uItem then
                    local uPropsOk, uProps = pcall(function()
                        return uItem:GetAllProperties()
                    end)
                    if uPropsOk and uProps
                        and type(uProps.Line) == "string"
                        and uProps.Line ~= "" then
                        local line = uProps.Line
                        line = line:gsub("<br%s*/?>", " ")
                        line = Helpers.StripMarkupTags(line)
                        line = line:match("^%s*(.-)%s*$") or line
                        if line ~= "" then
                            result.unavailableLines[
                                #result.unavailableLines + 1] = line
                        end
                    end
                end
            end
        end
    end

    return result
end

-- ============================================================================
-- Cursor canvas position (live read, no calibration needed)
-- ============================================================================
--
-- The brain canvas Grid (Brain.Content) is positioned within the
-- brain via Margin.  Margin.Left / Margin.Top track the live pan
-- offset 1:1 -- as the user pans, Margin updates to reflect the
-- canvas's current screen-space top-left.
--
-- The canvas is rendered scaled by Brain.Content.LayoutTransform
-- (ScaleX / ScaleY, both 0.85 in the dump -- DIFFERENT from
-- Brain.CurrentZoom which is 0.75).  LayoutTransform is the
-- scale that actually applies to the canvas pixels on screen.
--
-- Cursor screen position comes from PlayerPickingHelper.WindowCursorPos.
-- Player-index 1 is the active helper (index 0 is sometimes nil).
--
-- Math:
--   cursor_canvas_x = (cursor_screen_x - Margin.Left) / ScaleX
--   cursor_canvas_y = (cursor_screen_y - Margin.Top)  / ScaleY
--
-- Empirically verified: two samples from different pan states show
-- Margin shifting by exactly the offset delta, and canvas positions
-- for known powers match the formula within rounding.

-- ReadCursorCanvasPosition: returns (canvasX, canvasY) for the
-- current cursor position, or nil if any required property can't
-- be read.  No fit, no samples, no calibration.
local function ReadCursorCanvasPosition()
    local brain = Ext.UI.FindNameInWidget("Brain")
    if not brain then
        Log.Info("CURSOR_CANVAS: Brain element not found")
        return nil, nil
    end

    local brainProps = nil
    pcall(function() brainProps = brain:GetAllProperties() end)
    if not brainProps then
        Log.Info("CURSOR_CANVAS: brain:GetAllProperties() failed")
        return nil, nil
    end
    if not brainProps.Content then
        Log.Info("CURSOR_CANVAS: brain.Content is nil")
        return nil, nil
    end

    local content = brainProps.Content
    local contentProps = nil
    pcall(function() contentProps = content:GetAllProperties() end)
    if not contentProps then
        Log.Info("CURSOR_CANVAS: content:GetAllProperties() failed")
        return nil, nil
    end

    -- Margin is a table {1=left, 2=top, 3=right, 4=bottom}.
    local margin = contentProps.Margin
    if type(margin) ~= "table" then
        Log.Info("CURSOR_CANVAS: content.Margin not a table, got "
            .. type(margin))
        return nil, nil
    end
    local marginLeft = margin[1] or margin.Left
    local marginTop = margin[2] or margin.Top
    if not marginLeft or not marginTop then
        Log.Info("CURSOR_CANVAS: Margin missing left/top, got "
            .. tostring(marginLeft) .. ", " .. tostring(marginTop))
        return nil, nil
    end

    -- LayoutTransform is a ScaleTransform with ScaleX/Y properties.
    local layoutTransform = contentProps.LayoutTransform
    if type(layoutTransform) ~= "userdata" then
        Log.Info("CURSOR_CANVAS: content.LayoutTransform not userdata, "
            .. "got " .. type(layoutTransform))
        return nil, nil
    end
    local layoutProps = nil
    pcall(function() layoutProps = layoutTransform:GetAllProperties() end)
    if not layoutProps then
        Log.Info("CURSOR_CANVAS: layoutTransform:GetAllProperties() failed")
        return nil, nil
    end
    local scaleX = layoutProps.ScaleX
    local scaleY = layoutProps.ScaleY
    if not scaleX or not scaleY
        or scaleX == 0 or scaleY == 0 then
        Log.Info("CURSOR_CANVAS: scale invalid, ScaleX="
            .. tostring(scaleX) .. " ScaleY=" .. tostring(scaleY))
        return nil, nil
    end

    -- Cursor screen position.  Larian's SoftwareCursor locks the
    -- cursor at the brain's center on this panel -- the brain pans
    -- underneath while the cursor stays put.  Its actual rendered
    -- translation is held in RenderTransform.Children (a
    -- TransformCollection), which is OPAQUE to the BG3SE Lua bridge:
    -- pairs() only exposes the collection's methods (GetProperty,
    -- ToString, etc.), and numeric indexing returns nil.  Same for
    -- VisualTransform.  So we can't read the cursor's translation
    -- directly.
    --
    -- Instead, we exploit the fact that the cursor is at the brain's
    -- geometric center: cursor_screen = (brain.ActualWidth/2,
    -- brain.ActualHeight/2).  This matches the brain's
    -- ArrangeTransformRenderOffsetPost values exactly, and matches
    -- empirical observation (the brain panels' pan behavior centers
    -- the focused power under a screen-locked cursor).
    local brainWidth = brainProps.ActualWidth
    local brainHeight = brainProps.ActualHeight
    if type(brainWidth) ~= "number" or type(brainHeight) ~= "number"
        or brainWidth <= 0 or brainHeight <= 0 then
        Log.Info("CURSOR_CANVAS: brain ActualWidth/Height invalid")
        return nil, nil
    end
    local cursorScreenX = brainWidth / 2
    local cursorScreenY = brainHeight / 2

    local canvasX = (cursorScreenX - marginLeft) / scaleX
    local canvasY = (cursorScreenY - marginTop) / scaleY
    Log.Info(string.format(
        "CURSOR_CANVAS: cursorScreen=(%.1f, %.1f) margin=(%.1f, %.1f) "
            .. "scale=(%.3f, %.3f) -> canvas=(%.1f, %.1f)",
        cursorScreenX, cursorScreenY,
        marginLeft, marginTop, scaleX, scaleY,
        canvasX, canvasY))
    return canvasX, canvasY
end


-- ============================================================================
-- Cursor reader (stick-driven speech)
-- ============================================================================

-- Number of additional 5-frame retries when TryReadPowerExtenderData
-- returns nil because Larian's TooltipExtender hasn't yet populated
-- ExtenderData.  Total 4 attempts (frames 5/10/15/20) covers the
-- empirical attachment window; worst case ~333ms.  Falls through to
-- API-only speech when retries exhaust.
local MAX_EXTENDER_RETRIES = 3

local function ReadAndSpeakFocusedPower(retryCount)
    retryCount = retryCount or 0

    -- Clear pending flags BEFORE early-returns so a failed read
    -- doesn't permanently block subsequent reads from being scheduled.
    cancelPendingPowerRead = nil
    stickReadPending = false

    if type(Ext.UI.ReadElementPath) ~= "function" then return end

    local cursor = Ext.UI.FindNameInWidget("Cursor")
    if not cursor then return end

    -- Read the full Power object (all scalar fields + _type field).
    -- TadpolePowersTree_c.xaml line 460 binds the tooltip Content to
    -- the same Power object via Cursor.TopFocusedElement.DataContext.
    -- Power.
    local powerData = Ext.UI.ReadElementPath(
        cursor, "TopFocusedElement.DataContext.Power")

    local powerName = nil
    if type(powerData) == "table" then
        powerName = powerData.Name
        if powerName == "" then powerName = nil end
    end

    -- Dedup only on the first attempt; retries are for the same power
    -- that already passed dedup.  lastFocusedPowerName updates after
    -- speech below.
    --
    -- Transition rules:
    --   - Off-power read: mark cursorWasOnPower=false so the next on-
    --     power read re-speaks even if it's the same power as before.
    --     IMPORTANT: do NOT clear lastFocusedPowerName -- the X-button
    --     orientation needs it as a fallback reference.
    --   - On-power read while already on a power AND same power as
    --     last time: dedup-skip (sliding within hit area).
    --   - All other on-power reads: speak, mark cursorWasOnPower=true.
    if retryCount == 0 then
        if not powerName then
            cursorWasOnPower = false
            return
        end
        if cursorWasOnPower
            and powerName == lastFocusedPowerName then
            return
        end
        cursorWasOnPower = true
    elseif not powerName then
        return
    end

    -- One-time diagnostic dump.
    if not powerObjectDumped then
        powerObjectDumped = true
        local fieldList = {}
        for fieldKey, fieldVal in pairs(powerData) do
            local valStr = tostring(fieldVal)
            if #valStr > 80 then valStr = valStr:sub(1, 80) .. "..." end
            fieldList[#fieldList + 1] =
                tostring(fieldKey) .. "=" .. valStr
        end
        Log.Info("TADPOLE POWER DUMP: " .. table.concat(fieldList, " | "))
    end

    -- State is on VMTadpolePower (the parent), not the Power sub-VM.
    local state = Ext.UI.ReadElementPath(
        cursor, "TopFocusedElement.DataContext.State")
    local stateLabel = TADPOLE_STATE_LABELS[state]

    -- Two power VM types coexist with different stats key fields:
    --   ls.VMPassive          -> PassiveName  (passive feature)
    --   ls.VMCharacterAction  -> PrototypeID  (class action / spell)
    -- Visual UI subtitle: "Passive Feature" vs "Class Actions".
    local statsName = nil
    local typeLabel = "Passive Feature"

    if powerData._type == "ls.VMCharacterAction" then
        typeLabel = "Class Actions"
        statsName = powerData.PrototypeID
    else
        statsName = powerData.PassiveName
    end

    local extenderData = TryReadPowerExtenderData()

    -- If ExtenderData isn't ready and we have retries left, defer
    -- 5 frames and try again.  After retries exhaust, fall through
    -- to API-only speech (description from Ext.Stats).
    if not extenderData and retryCount < MAX_EXTENDER_RETRIES then
        stickReadPending = true
        cancelPendingPowerRead =
            BG3Access.Client.Scheduler.RunAfterFrames(5, function()
                ReadAndSpeakFocusedPower(retryCount + 1)
            end)
        return
    end

    local speechData = SpeechData.Create()
    speechData:Add("name", powerName, "brief")

    -- Toggleable-passive subtitle.
    if extenderData
        and powerData._type == "ls.VMPassive"
        and extenderData.isToggleable ~= nil then
        typeLabel = ResolvePassiveSubtitle(extenderData.isToggleable)
    end
    speechData:Add("controlType", typeLabel, "brief")

    -- Description: prefer ExtenderData's substituted text, fall back
    -- to Ext.Stats API when ExtenderData has unresolved [N] placeholders.
    local description = nil
    if extenderData and extenderData.description then
        description = extenderData.description
    end
    if not description and statsName and statsName ~= "" then
        local cachedOk, cached
        if powerData._type == "ls.VMCharacterAction" then
            cachedOk, cached =
                pcall(Ext.Stats.GetCachedSpell, statsName)
        else
            cachedOk, cached =
                pcall(Ext.Stats.GetCachedPassive, statsName)
        end
        if cachedOk and cached and cached.Description then
            description = Helpers.ResolveTranslatedString(
                cached.Description.Description)
            local descParams = cached.Description.DescriptionParams
            if description and descParams and descParams ~= "" then
                description = Helpers.ResolveDescriptionParams(
                    description, nil, descParams)
            end
            if description and description ~= "" then
                description = Helpers.StripMarkupTags(description)
            end
        end
    end
    if description and description ~= "" then
        speechData:Add("description", description, "normal")
    end

    if extenderData and extenderData.extraDescription then
        speechData:Add("additionalDescription",
            extenderData.extraDescription, "normal")
    end

    -- Cost / Recharge / Duration / Lore from ExtenderData.
    if extenderData and extenderData.costParts then
        for _, costPart in ipairs(extenderData.costParts) do
            speechData:AddProperty(
                costPart.label, costPart.value, costPart.tier)
        end
    end
    if extenderData and extenderData.propertyParts then
        for _, propertyPart in ipairs(extenderData.propertyParts) do
            speechData:AddProperty(
                propertyPart.label,
                propertyPart.value,
                propertyPart.tier)
        end
    end
    if extenderData and extenderData.loreDescription then
        speechData:AddProperty("Lore",
            extenderData.loreDescription, "verbose")
    end

    -- Lock-reason analysis distinguishes the three "why locked" cases.
    --   Active   -> no augmentation needed.
    --   Enabled  -> if tadpole count is 0, append a resource note.
    --   Disabled -> prefer ExtenderData.unavailableLines (exact visual
    --               text like "Not trained yet").  Fall back to static
    --               prereq lookup when ExtenderData is empty.  ALWAYS
    --               append prereqs from static lookup -- the visual
    --               conveys them via tree-line connections which a
    --               blind player can't perceive.
    local lockReasonParts = {}
    local usedUnavailableLines = false
    if state == "Enabled" then
        local tadpoleCountStr = Ext.UI.ReadDCPath(
            cursor, "CurrentPlayer.PartyTadpoleCount")
        local tadpoleCount = tonumber(tadpoleCountStr) or -1
        if tadpoleCount == 0 then
            lockReasonParts[#lockReasonParts + 1] =
                "but no tadpoles available to unlock"
        end
    elseif state == "Disabled" then
        if extenderData and extenderData.unavailableLines
            and #extenderData.unavailableLines > 0 then
            usedUnavailableLines = true
            for _, line in ipairs(extenderData.unavailableLines) do
                lockReasonParts[#lockReasonParts + 1] = line
            end
        end
        local lookup = BuildTadpolePowerLookup()
        local powerInfo = statsName and lookup[statsName]
        if powerInfo then
            if powerInfo.needsHalfIllithid then
                lockReasonParts[#lockReasonParts + 1] =
                    "needs Half Illithid status"
            end
            if #powerInfo.prereqDisplayNames > 0 then
                lockReasonParts[#lockReasonParts + 1] =
                    "requires " .. table.concat(
                        powerInfo.prereqDisplayNames, " or ")
            end
        end
    end

    if stateLabel then
        local stateLine
        if usedUnavailableLines and #lockReasonParts > 0 then
            -- ExtenderData lines already include "Not trained yet" or
            -- equivalent; the state label would be redundant.
            stateLine = table.concat(lockReasonParts, ", ")
        else
            stateLine = stateLabel
            if #lockReasonParts > 0 then
                stateLine = stateLine .. ", "
                    .. table.concat(lockReasonParts, ", ")
            end
        end
        speechData:Add("state", stateLine, "brief")
    end

    local text = speechData:Format("normal")
    if not text or text == "" then return end
    Log.Info("TADPOLE POWER FOCUS: " .. text)
    SpeechData.Alert(text, "interrupt")

    -- Neighbor follow-up: match the focused statsName to its index in
    -- the inventory, then describe its 8 nearest compass neighbors via
    -- the static Canvas position table.  Queued so it follows the
    -- main power speech rather than interrupting it.
    if statsName and statsName ~= "" and powerInventory then
        local focusedIndex = nil
        for inventoryIndex, inventoryEntry
            in ipairs(powerInventory) do
            if inventoryEntry.statsKey == statsName then
                focusedIndex = inventoryIndex
                break
            end
        end
        if focusedIndex then
            local neighborText = FormatNeighbors(
                focusedIndex, powerInventory)
            if neighborText and neighborText ~= "" then
                Log.Info("TADPOLE POWER NEIGHBORS: " .. neighborText)
                SpeechData.Alert(neighborText, "queue")
            end
        end
    end

    -- Commit dedup ONLY after speaking, so retries don't dedup-skip
    -- themselves.
    lastFocusedPowerName = powerName
end

-- ============================================================================
-- Input handlers
-- ============================================================================

-- AnnounceCursorOrientation: on-demand spatial orientation.  Bound to
-- X (with "interrupt" tier) and also auto-fired once after the manage-
-- mode hint plays (with "queue" tier).  Two cases:
--
--   1. Cursor focused on a power
--      -> "On <power>. <8 neighbors of that power>"
--
--   2. Cursor between powers (or outside the canvas entirely)
--      ReadCursorCanvasPosition gives us the exact canvas coordinate
--      under the cursor via Brain.Content.Margin + LayoutTransform
--      (live, no calibration).  Find the nearest power + compass
--      direction FROM the cursor; list neighbors around that power.
--      -> "Cursor between powers. <dir> to <nearest>. From <nearest>:
--          <8 neighbors>"
local function AnnounceCursorOrientation(alertTier)
    alertTier = alertTier or "interrupt"

    if not powerInventory or #powerInventory == 0 then
        SpeechData.Alert(
            "Power list not yet built. Wait a moment, then try "
                .. "again.",
            alertTier)
        return
    end

    -- Case 1: cursor focused on a power.
    local cursor = Ext.UI.FindNameInWidget("Cursor")
    local currentDisplayName = nil
    local currentStatsKey = nil
    if cursor then
        local powerData = Ext.UI.ReadElementPath(
            cursor, "TopFocusedElement.DataContext.Power")
        if type(powerData) == "table" then
            currentDisplayName = powerData.Name
            if currentDisplayName == "" then
                currentDisplayName = nil
            end
            currentStatsKey = powerData.PassiveName
                or powerData.PrototypeID
        end
    end

    if currentStatsKey and currentStatsKey ~= "" then
        for inventoryIndex, inventoryEntry
            in ipairs(powerInventory) do
            if inventoryEntry.statsKey == currentStatsKey then
                local neighborText = FormatNeighbors(
                    inventoryIndex, powerInventory)
                local refName = currentDisplayName
                    or inventoryEntry.displayName
                local fullText
                if neighborText and neighborText ~= "" then
                    fullText = "On " .. refName
                        .. ". " .. neighborText
                else
                    fullText = "On " .. refName
                        .. ". No neighbors found."
                end
                Log.Info("TADPOLE ORIENTATION: " .. fullText)
                SpeechData.Alert(fullText, alertTier)
                return
            end
        end
    end

    -- Case 2: cursor between powers.  Live cursor canvas read via
    -- Brain.Content.Margin (which shifts 1:1 with pan offset) and
    -- LayoutTransform.ScaleX/Y (canvas-to-screen scale).  Then list
    -- the closest power in each of the 8 compass sectors FROM THE
    -- CURSOR (not from any reference power).
    local cursorCanvasX, cursorCanvasY = ReadCursorCanvasPosition()
    if cursorCanvasX and cursorCanvasY then
        local neighborText = FormatNeighborsAtPosition(
            cursorCanvasX, cursorCanvasY, powerInventory)
        local fullText
        if neighborText and neighborText ~= "" then
            fullText = "Cursor between powers. " .. neighborText
        else
            fullText = "Cursor between powers. "
                .. "No powers found near cursor."
        end
        Log.Info(string.format(
            "TADPOLE ORIENTATION (cursor canvas %.0f, %.0f): %s",
            cursorCanvasX, cursorCanvasY, fullText))
        SpeechData.Alert(fullText, alertTier)
        return
    end

    -- Final fallback: couldn't read cursor canvas position.
    SpeechData.Alert(
        "Unable to determine cursor position. Move the left stick "
            .. "to focus a power.",
        alertTier)
end

-- Button handler:
--   A first press in panel -> queue the one-time manage-mode hint.
--                              Do NOT PreventAction; Larian needs the
--                              A press to transition screens and the
--                              LSButton handles unlock natively.
--   X                       -> on-demand orientation announcement.
--                              PreventAction so Larian doesn't try
--                              to interpret it for some default
--                              behavior.
local function OnTadpoleControllerInput(event)
    -- BG3Access settings menu owns input while open.
    local SettingsMenu = BG3Access.Client.SettingsMenu
    if SettingsMenu and SettingsMenu.IsOpen
        and SettingsMenu.IsOpen() then
        return
    end
    if not event or not event.Pressed then return end
    local buttonName = tostring(event.Button)

    if buttonName == "A" then
        if not manageModeHintSpoken then
            manageModeHintSpoken = true
            SpeechData.Alert(
                "Manage powers. This screen depicts a brain with 26 "
                    .. "powers arranged in three concentric rings. "
                    .. "Use the left stick to move the cursor. When "
                    .. "you focus a power, you will hear its info, "
                    .. "followed by directions to the powers nearest "
                    .. "to you. Powers with a padlocked status "
                    .. "cannot be focused. Hold A to unlock the "
                    .. "focused power. Press B to go back one "
                    .. "screen, twice to exit to the game world. "
                    .. "Press X at any time for directions to "
                    .. "nearby powers.",
                "queue")

            -- After the hint, give the player an immediate spatial
            -- orientation so they know what powers surround the
            -- cursor's starting position.  Defer 30 frames so the
            -- manage-mode transition has time to fully settle:
            -- EntryOverlay collapse, Brain.Content layout pass, and
            -- the Margin / LayoutTransform updates that we read in
            -- ReadCursorCanvasPosition.  Queued alert plays after
            -- the manage-mode hint.
            if cancelPendingAutoOrient then
                cancelPendingAutoOrient()
                cancelPendingAutoOrient = nil
            end
            cancelPendingAutoOrient =
                BG3Access.Client.Scheduler.RunAfterFrames(
                    30, function()
                        cancelPendingAutoOrient = nil
                        AnnounceCursorOrientation("queue")
                    end)
        end
        return
    end

    if buttonName == "X" then
        pcall(function() event:PreventAction() end)
        AnnounceCursorOrientation()
        return
    end
end

-- Stick handler.  Schedule a deferred ReadAndSpeakFocusedPower a few
-- frames after the stick deflects so the cursor has time to settle
-- on whatever it's hitting.  Throttled to ~1 read per 5 frames while
-- the stick is held via stickReadPending.
local function OnTadpoleAxisInput(event)
    -- BG3Access settings menu owns input while open.
    local SettingsMenu = BG3Access.Client.SettingsMenu
    if SettingsMenu and SettingsMenu.IsOpen
        and SettingsMenu.IsOpen() then
        return
    end
    if not event then return end
    local axisName = tostring(event.Axis)
    if not TADPOLE_STICK_AXES[axisName] then return end

    local value = event.Value or 0
    if math.abs(value) < TADPOLE_STICK_DEFLECT_THRESHOLD then return end

    if stickReadPending then return end
    stickReadPending = true
    BG3Access.Client.Scheduler.RunAfterFrames(
        5, ReadAndSpeakFocusedPower)
end

-- ============================================================================
-- Handler factory
-- ============================================================================

local function CreateTadpoleHandler(createPanelHandler)
    return createPanelHandler({
    name = "TadpolePowers",
    hint = "A to manage powers. B to close.",
    --- customTooltipFn: suppress all tooltip speech for the brain
    --- panel.  Two reasons:
    ---
    ---   1. When the cursor IS on a power, ReadAndSpeakFocusedPower
    ---      already speaks the focused power's full info (name,
    ---      type, description, cost, recharge, lock-reason, etc.)
    ---      via the stick reader.  A second pass via the factory's
    ---      tooltip dispatch just duplicates that content,
    ---      sometimes interrupting it mid-sentence.
    ---
    ---   2. When the cursor is BETWEEN powers, Larian's PowerTooltip
    ---      can linger with content from the last focused power
    ---      (the binding clears the DataContext but the rendered
    ---      tooltip text doesn't refresh immediately).  A tooltip
    ---      event then fires with stale data belonging to a power
    ---      the user has already left -- e.g. "20ft. Damage: 2d6
    ---      ..." when they're floating in empty canvas space.
    ---
    --- Returning nil here is the factory's documented "no speech"
    --- contract.  Power info still flows via the cursor reader; the
    --- factory still handles screen entry and removal as normal.
    customTooltipFn = function(tooltipTexts, focusedDCType, handlerState)
        return nil
    end,
    onWidgetAdded = function(widgetData, handlerState)
        handlerState.screenEntryOverrides:Add(
            "title", "Illithid Powers", "brief")

        -- Tadpole count read.  The Noesis binding for DisplayedTadPoles
        -- doesn't reliably propagate by the time onWidgetAdded fires
        -- (per CLAUDE.md: "Tadpole count read is the canonical
        -- RunAfterFrames example: Noesis binding propagation needs
        -- ~30 frames after widget creation").  Defer ~20 frames and
        -- speak as a queued Alert.  Cancel any prior pending read in
        -- case the panel re-opens during the defer window.
        if handlerState.cancelPendingTadpoleRecount then
            handlerState.cancelPendingTadpoleRecount()
            handlerState.cancelPendingTadpoleRecount = nil
        end
        handlerState.cancelPendingTadpoleRecount =
            BG3Access.Client.Scheduler.RunAfterFrames(20, function()
                handlerState.cancelPendingTadpoleRecount = nil
                local widget = Ext.UI.FindNameInWidget(
                    "TadpolePowersTree_c")
                if not widget then return end
                local liveDc = nil
                pcall(function() liveDc = widget.DataContext end)
                if not liveDc then return end
                local liveProps = nil
                pcall(function()
                    liveProps = liveDc:GetAllProperties()
                end)
                if not liveProps then return end
                local liveCount = liveProps.DisplayedTadPoles
                if not liveCount then return end
                local liveStr = tostring(liveCount)
                if liveStr == "" then return end

                local label = (liveStr == "0"
                    and "No tadpoles available")
                    or (liveStr .. " tadpoles available")
                Log.Info("TADPOLE COUNT: " .. label)
                SpeechData.Alert(label, "queue")
            end)

        -- Subscribe to controller input.  Axis handler drives the
        -- cursor reader (stick movement = power speech).  Button
        -- handler fires the manage-mode hint on first A press.
        lastFocusedPowerName = nil
        cursorWasOnPower = false
        stickReadPending = false
        if not tadpoleAxisSubscriptionId
            and Ext.Events and Ext.Events.ControllerAxisInput then
            tadpoleAxisSubscriptionId =
                Ext.Events.ControllerAxisInput:Subscribe(
                    OnTadpoleAxisInput)
        end
        if not tadpoleInputSubscriptionId
            and Ext.Events and Ext.Events.ControllerButtonInput then
            tadpoleInputSubscriptionId =
                Ext.Events.ControllerButtonInput:Subscribe(
                    OnTadpoleControllerInput)
        end

        -- Build the power inventory (display names per index, for
        -- FormatNeighbors lookup).  Deferred 10 frames so the brain
        -- widget has time to bind its TadpolePowers collection.
        -- onWidgetAdded can fire multiple times per panel session
        -- (WidgetDCChanged etc.); BuildPowerInventory's
        -- powerInventoryBuilt guard makes re-fires no-ops, and we
        -- also cancel any in-flight pending build before scheduling.
        if cancelPendingInventoryBuild then
            cancelPendingInventoryBuild()
            cancelPendingInventoryBuild = nil
        end
        cancelPendingInventoryBuild =
            BG3Access.Client.Scheduler.RunAfterFrames(
                10, BuildPowerInventory)

    end,

    onReset = function(handlerState)
        lastFocusedPowerName = nil
        cursorWasOnPower = false
        stickReadPending = false
        powerObjectDumped = false
        manageModeHintSpoken = false
        powerInventory = nil
        powerInventoryBuilt = false

        if cancelPendingPowerRead then
            cancelPendingPowerRead()
            cancelPendingPowerRead = nil
        end
        if cancelPendingInventoryBuild then
            cancelPendingInventoryBuild()
            cancelPendingInventoryBuild = nil
        end
        if cancelPendingAutoOrient then
            cancelPendingAutoOrient()
            cancelPendingAutoOrient = nil
        end
        if handlerState.cancelPendingTadpoleRecount then
            handlerState.cancelPendingTadpoleRecount()
            handlerState.cancelPendingTadpoleRecount = nil
        end

        if tadpoleAxisSubscriptionId
            and Ext.Events and Ext.Events.ControllerAxisInput then
            Ext.Events.ControllerAxisInput:Unsubscribe(
                tadpoleAxisSubscriptionId)
            tadpoleAxisSubscriptionId = nil
        end
        if tadpoleInputSubscriptionId
            and Ext.Events and Ext.Events.ControllerButtonInput then
            Ext.Events.ControllerButtonInput:Unsubscribe(
                tadpoleInputSubscriptionId)
            tadpoleInputSubscriptionId = nil
        end
    end,
})
end

-- Exports
BG3Access.Client.TadpolePowers = {
    CreateTadpoleHandler = CreateTadpoleHandler,
}
