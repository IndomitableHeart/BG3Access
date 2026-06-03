-- ============================================================================
-- BG3Access TargetSelect Module
--
-- Speaks combat target information when the player cycles targets with
-- the D-pad during their turn.  BG3 renders target data to two HUD
-- widgets that are otherwise silent for the screen reader:
--   - TargetInfo_c   -- target name, level, HP bar, status effects
--   - CursorText_c   -- hit chance, distance, advantages/disadvantages,
--                      capability errors, concentration warnings,
--                      attack-of-opportunity warnings
--
-- Flow:
--   1. Combat is active AND it is the player-controlled character's turn.
--   2. User presses D-pad Left or D-pad Right.  The game cycles through
--      valid targets and updates TargetInfo_c / CursorText_c bindings.
--   3. A short timer defers the read a few ticks so Noesis can flush
--      the new target into the rendered TextBlocks.
--   4. We locate a unique element inside each widget via FindNameInWidget,
--      walk up the Parent chain to the widget root, then
--      ReadElementStructuredTextBlocks on the widget root to harvest all
--      rendered TextBlock texts in a single primitive call.
--   5. Entries are classified by their x:Name role, fed into a
--      SpeechData object using the standardized core fields (status,
--      name, additionalDescription) and AddProperty (Level, Hit
--      chance, Distance, Roll, Concentration, Warning, Cannot,
--      Container, More statuses), and spoken via speechData:Speak
--      with isScreenEntry=true / userInitiated=true so verbosity
--      filtering and role cross-off work the same way every other
--      panel handler does them.
--
-- PURE LUA: no C++ changes.  Relies on the same FindNameInWidget /
-- ReadElementStructuredTextBlocks primitives every other panel handler
-- uses.  Adds no per-tick work -- reads only on user input.
-- ============================================================================

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

local Log        = BG3Access.Client.Log
local SpeechData = BG3Access.Client.SpeechData
local Helpers    = BG3Access.Client.Helpers

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

-- Hard ceiling on how long a single press can wait for the engine
-- to process before we give up and speak whatever we have.  No fixed
-- timer drives the read -- the per-frame Ext.Events.Tick handler
-- triggers on the actual frame the camera target changes.  This
-- timeout is just defensive: if the engine never advances the camera
-- (target despawned, focus lost, weird state), we still speak after
-- this budget rather than block forever.  Sized for the cursor-info
-- worst case: stage 1 (~120ms) -> stage 2 (~320ms) -> stage 3 (~360ms)
-- + 250ms stability window = ~610ms expected fire.  Add headroom.
local READ_MAX_TOTAL_MS = 900

-- x:Name uniquely present in TargetInfo_c's template.  Used as the
-- anchor for locating the widget root, then ReadDCPath reads through
-- the widget root's DataContext (the root Widget VM, which exposes
-- CurrentPlayer / Data / Layout).
--
-- HPBarContainer turned out to be PRESENT IN BOTH the mouse
-- TargetInfo.xaml AND the controller TargetInfo_c.xaml -- and the
-- mouse widget can be loaded simultaneously with controller widgets
-- in Steam Input setups.  FindNameInWidget("HPBarContainer") then
-- returns whichever widget gets found first across visible NameScopes,
-- which can be the mouse TargetInfo holding stale or mouse-cursor
-- data while the actual on-screen nameplate is rendered by
-- TargetInfo_c.  Symptom: speech reports a different enemy / HP than
-- what the player sees on screen.
--
-- "CycleSelection" is the d-pad cycling button hint inside
-- TargetInfo_c.xaml's Header grid -- a ContentControl with
-- Template=ButtonHint.  Verified unique across all 201 _c.xaml /
-- non-_c.xaml files in MainUI/GUI/Pages -- only TargetInfo_c uses
-- this name, so the anchor cannot be confused with the mouse widget.
local TARGET_INFO_ANCHOR = "CycleSelection"

-- x:Name uniquely present in CursorText_c's template.
--
-- Same bug pattern as the TargetInfo anchor above: hitChanceText
-- appears in BOTH CursorText.xaml (mouse) and CursorText_c.xaml
-- (controller).  When both NameScopes are searched, the first match
-- can return mouse-cursor data that doesn't reflect the controller's
-- actual cursor target.
--
-- "CursorTextRight" is the Grid containing the entire controller
-- cursor text panel inside CursorText_c.xaml.  Confirmed unique across
-- all extracted XAML pages -- exists only in CursorText_c.
local CURSOR_TEXT_ANCHOR = "CursorTextRight"

-- Maximum Parent hops when walking up from an anchor element to the
-- widget root.  Anchors live 4-6 levels deep in the visual tree; 12
-- hops provides comfortable margin without risking an infinite loop
-- if Parent ever returns a cycle.
local MAX_PARENT_HOPS = 12

-- Larian TranslatedString handles referenced by the cursor / target
-- XAML templates for trigger-driven Run text.  Resolved lazily once
-- per session via Ext.Loca.GetTranslatedString.  Hardcoded here
-- because the corresponding Run is set via DataTrigger on the VM's
-- enum value -- the VM does not expose the resolved string.
--
-- Source-of-truth in CursorText_c.xaml / TargetInfo_c.xaml.
local LOCA_HANDLES = {
    -- Cause prefix: ParameterizedTranslatedString that wraps a Cause
    -- string for capability-error messages and cannot-heal messages.
    -- Format: "{0}: <Cause>" (locale-dependent).
    capabilityCausePrefix       = "hb19f530dgfeb2g4d13g8d64ga8216f364f67",
    -- Capability error messages keyed by VMCapabilityModifier.Type.
    -- See CursorText_c.xaml DataTriggers under the CapabilityError
    -- DataTemplate (lines 150-178).
    capabilityMovementBlocked   = "h7760a99cg8a58g4555gb0f1g0e3e2b872f66",
    capabilityMovementImpeded   = "h987efa83g0f3bg416dga3dfg7a588084af78",
    capabilityMovementHalved    = "h709568ceg6653g4caag90afg57b5be47ca55",
    capabilityCostMultiplier    = "hd5796d9fg7f28g4f61g9287g688eccd1b538",
    capabilityCostDouble        = "hb8b5ca34g224eg4ed0g8029g170746bef0f4",
    -- Cannot-heal error message (CursorText_c.xaml line 241).
    targetCantBeHealed          = "h392eef12g97b6g47c8g858egd305c12f7dfd",
    -- Attack-of-opportunity warning (CursorText_c.xaml line 225).
    attackOfOpportunity         = "ha622b8f7gecf0g44c8gb8abgca896b1c48ef",
    -- High-defense warning (CursorText_c.xaml line 99).
    highDefense                 = "hd135c195g1887g4ee4g85b8g586666685815",
    -- Throw / improvised-weapon overrides for TaskDescription (used
    -- when SelectedCharacter.PlayerCharacterProperties.CurrentSpellTask
    -- ActionId is "Throw" or "ImprovisedWeapon").
    throwAction                 = "he2954eb6g6074g4b0ag90e9g8f14cc2ee21c",
    throwActionNoTarget         = "h521c4991ge535g48dcg842dg26eb11b13c46",
    -- Ping target (when CurrentPlayer.IsRequestingPing == true).
    pingAction                  = "hfe7d4028g2faag4431g974ag7cbf0c3ef163",
}

local resolvedLocaCache = {}
local function ResolveHandle(handleKey)
    if resolvedLocaCache[handleKey] ~= nil then
        return resolvedLocaCache[handleKey]
    end
    local handle = LOCA_HANDLES[handleKey]
    if not handle then
        resolvedLocaCache[handleKey] = ""
        return ""
    end
    local lookupOk, resolved = pcall(
        Ext.Loca.GetTranslatedString, handle)
    if lookupOk and type(resolved) == "string" then
        resolvedLocaCache[handleKey] = resolved
    else
        resolvedLocaCache[handleKey] = ""
    end
    return resolvedLocaCache[handleKey]
end

-- Bool string returned by ReadDCPath / ReadTypePropertyAsString in
-- C++ (ConvertRawValueToString_Inner) for Boolean TypeProperties.
-- Used for ShowDescription / AoOWarning / TargetCanBeHealed gates.
local BOOL_TRUE  = "On"

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local buttonSubscription   = nil
local lastSpokenAtMs       = 0

-- Most-recent target (name + entity handle + timestamp).  Populated
-- by PerformTargetRead on each d-pad cycle.  Used by the RS-Left
-- effects view so it can enumerate statuses on whichever character
-- the user is currently aimed at.
--
-- Staleness guarding:
-- The effects view must NOT serve data from a previous combat /
-- previous target-select session.  Two gates prevent that:
--   1. TTL: lastTargetReadAtMs is compared to monotonic time at
--      handler-lookup.  Beyond TARGET_STALENESS_MS, the cache is
--      considered stale and GetActiveDetailHandler returns nil so
--      other handlers (character sheet, inventory, etc.) serve
--      RS-Left instead.
--   2. In-combat check: effects view fires only during combat.
--      Out-of-combat contexts (character sheet detail, inventory
--      detail) are owned by WorldUI / Menus handlers.
-- Cleared on GameStateChanged via ResetState (explicit clear) and
-- on combat end via HandleCombatEnded hook in Combat.lua.
local lastTargetName       = nil
-- UUID string only; we DO NOT cache the entity userdata across
-- ticks.  Caching entity pointers across teardown windows was a
-- known source of "dead object in ToString" SEH faults.  Use
-- ResolveTargetEntity() below to get a live reference each time.
local lastTargetEntityUuid = nil
local lastTargetReadAtMs   = 0
-- Most recent cast-blocking rejection text from the cursor read, or
-- nil if the cast would proceed.  Set in BuildTargetSpeechData when
-- a rejection is present, cleared (set to nil) when none -- so the
-- A-press handler can interrupt-speak the reason if the player tries
-- to confirm a cast the game will refuse.  Defense in depth on top
-- of front-loading the rejection in title -- catches cases where the
-- navigation speech still got missed (interrupted, audio glitch).
local lastRejectionText    = nil

-- Maximum age for the cached target to still count as "fresh."  If
-- the user hasn't cycled a target in this window, they've moved on
-- to something else and the effects view should step aside.
-- 30s gives the player ample time to cycle a target, listen to the
-- full target announcement, then press RS-Left for effects.  5s
-- was too aggressive: users regularly took 6-8s to press RS-Left
-- after a d-pad, and the stale gate tripped before the RS-Left
-- lookup hit our handler.
local TARGET_STALENESS_MS  = 30000

-- SpeechData handler state used by :Speak() for spokenRoles /
-- lastSpokenFullText tracking.  Dedup across rapid presses uses
-- handlerState.lastSpokenFullText populated automatically by
-- SpeechData:Speak() -- no separate last-phrase cache needed.
local handlerState = {
    lastSpokenFullText = nil,
    spokenRoles = {},
    spokenValues = {},
}

-- Min gap between two identical target speeches.  Prevents the
-- second press in a rapid L/R oscillation from re-announcing the
-- same target when the game hasn't moved on yet.
local DEDUP_WINDOW_MS = 250

-- Forward declaration: EnumerateStatuses is defined later in the
-- file (near BuildEffectsDetailList), but PerformTargetRead (which
-- appears before that definition) needs to call it to pass the
-- entity status list into BuildTargetSpeechData.  Declaring the
-- local up here lets the later definition bind to the same slot
-- so the forward reference resolves at call time.
local EnumerateStatuses

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Returns the first local-player-controlled entity.  ClientControl
--- alone isn't specific enough (ghost-controlled items also have it);
--- IsPlayer narrows to a party member.  Returns nil when neither
--- component lookup yields a match (loading, pre-game, disconnected).
local PLAYER_COMPONENTS = {"ClientControl", "IsPlayer", "PlayerController"}
local function FindLocalPlayerEntity()
    for _, componentName in ipairs(PLAYER_COMPONENTS) do
        local queryOk, entities = pcall(
            Ext.Entity.GetAllEntitiesWithComponent, componentName)
        if queryOk and entities and #entities > 0 then
            return entities[1]
        end
    end
    return nil
end

--- Resolve the cached target UUID to a live entity reference.
--- Returns nil when no target is cached or when the entity has
--- since died/despawned.  We always re-resolve from the UUID
--- rather than caching the entity userdata across ticks --
--- caching the pointer was a documented source of "dead object
--- in ToString" SEH faults when the creature was freed between
--- cache time and use time.  Ext.Entity.Get handles missing
--- entities cleanly (returns nil; no fault), so this is the
--- safe identity-based pattern.
local function ResolveTargetEntity()
    if not lastTargetEntityUuid then return nil end
    local resolveOk, entity = pcall(
        Ext.Entity.Get, lastTargetEntityUuid)
    if not resolveOk or not entity then return nil end
    return entity
end

--- Is ANY locally-controlled party member currently on their combat
--- turn?  Speaking target info on an enemy's turn is wrong -- the
--- player can't cycle targets until one of their characters comes
--- up.
---
--- Source of truth is TurnBased.IsActiveCombatTurn on the entities
--- themselves.  We iterate ALL entities matching the player-component
--- criteria rather than just the first, because in a multi-character
--- party the "first" entity (typically Tav) won't be on its turn
--- when another party member is acting -- and the previous
--- single-entity check gated d-pad targeting silently for those
--- members.  Iterating catches the active member regardless of
--- party position.
---
--- Three legitimate "allow d-pad targeting" states:
---   1. In combat, local player's turn  -> a party member has
---      IsActiveCombatTurn=true.
---   2. Out of combat entirely         -> NO entity has
---      IsActiveCombatTurn=true (no one's in a turn-based action,
---      so the engine isn't waiting on anyone's input gate).
---   3. (Implicit) In combat, party turn just ended but enemy turn
---      hasn't fully begun yet -- handled by case 2 because there
---      is briefly no IsActiveCombatTurn-true entity.
---
--- The one state we GATE is "in combat, an enemy has the active
--- turn" -- a non-party entity has IsActiveCombatTurn=true.  The
--- player can't act, and reading their cursor target would just
--- echo whatever the AI's about to attack.
---
--- We do NOT pre-gate on Combat.IsInCombat().  That tracked flag
--- starts false after a Lua reload / console reset and only flips
--- true on the next CombatStarted Osiris event -- so during an
--- in-progress combat that survived the reload, the flag lies and
--- silently gates targeting for the entire session.  Walking the
--- ECS for IsActiveCombatTurn is authoritative.
local function IsLocalPlayerTurn()
    -- First sweep: is ANY party member's turn active?  If yes, that
    -- IS the local player's turn, allow.
    for _, componentName in ipairs(PLAYER_COMPONENTS) do
        local queryOk, entities = pcall(
            Ext.Entity.GetAllEntitiesWithComponent, componentName)
        if queryOk and entities then
            for _, entity in ipairs(entities) do
                local activeOk, isActive = pcall(function()
                    local turnBased = entity.TurnBased
                    if not turnBased then return false end
                    return turnBased.IsActiveCombatTurn == true
                end)
                if activeOk and isActive == true then return true end
            end
        end
    end
    -- Second sweep: scan ALL TurnBased entities for any with
    -- IsActiveCombatTurn=true.  If we find one (and the first sweep
    -- already proved it isn't a party member), an enemy currently
    -- holds the turn -- gate.  If we find none, we're out of combat
    -- entirely -- allow.
    local turnBasedOk, turnBasedEntities = pcall(
        Ext.Entity.GetAllEntitiesWithComponent, "TurnBased")
    if turnBasedOk and turnBasedEntities then
        for _, entity in ipairs(turnBasedEntities) do
            local activeOk, isActive = pcall(function()
                local turnBased = entity.TurnBased
                if not turnBased then return false end
                return turnBased.IsActiveCombatTurn == true
            end)
            if activeOk and isActive == true then
                return false  -- enemy has the turn, gate
            end
        end
    end
    -- No active combat turn anywhere -> out of combat -> allow.
    return true
end

--- Walk up the parent chain from an anchor element and return the
--- highest in-widget ancestor (the ls:UIWidget, or the Root Grid just
--- below it if we cannot reach the widget itself).
---
--- We MUST stop before leaving the widget: the application Canvas
--- holds every HUD widget in the game, and reading its DataContext
--- would mix together state that does not belong to either the
--- TargetInfo_c or CursorText_c widget.  Two stop conditions:
---   1. Element type name is "UIWidget" (reached the widget element).
---   2. Parent's type name is "Canvas" (parent is the app root, so
---      the current element IS the widget).
---
--- Tries logical Parent first (cleanest in-widget traversal), then
--- VisualParent as fallback when a template-internal element has no
--- logical parent.
local function SafeTypeName(element)
    local typeOk, typeName = pcall(function() return element.Type end)
    if typeOk and typeName then return tostring(typeName) end
    return ""
end

local function GetParentElement(element)
    local logicalOk, logicalParent = pcall(function()
        return element.Parent
    end)
    if logicalOk and logicalParent then return logicalParent end
    local visualOk, visualParent = pcall(function()
        return element.VisualParent
    end)
    if visualOk and visualParent then return visualParent end
    return nil
end

local function GetWidgetRoot(anchorElement)
    if not anchorElement then return nil end
    local current = anchorElement
    for hopIndex = 1, MAX_PARENT_HOPS do
        -- Stop if the current element is the UIWidget itself.
        if SafeTypeName(current):find("UIWidget") then
            return current
        end
        local parent = GetParentElement(current)
        if not parent then
            -- Reached the top of the tree.  Current is the highest
            -- reachable element (the Root Grid, typically).
            return current
        end
        -- Stop BEFORE crossing into the Canvas (app root): current
        -- is the widget at this point.
        if SafeTypeName(parent):find("Canvas") then
            return current
        end
        current = parent
    end
    return current
end

--- Normalize percentage strings: "65%" -> "65 percent" so the screen
--- reader doesn't pronounce the raw symbol.
local function NormalizeText(text)
    if not text then return text end
    text = text:gsub("(%d+)%%", "%1 percent")
    return text
end

--- Filter out placeholder / unresolved text values.
local function IsValidText(text)
    if not text or text == "" then return false end
    if text:find("%[ForceUpdate%]") then return false end
    if text:find("s_HandleUnknown") then return false end
    if text:match("^h[%x]+$") then return false end
    return true
end

--- Locate the widget root for a given widget anchor.  Returns nil
--- when the widget is not currently loaded / visible (the anchor
--- x:Name does not resolve through any active NameScope).
---
--- The same x:Name anchors as the previous TextBlock-read pipeline
--- are still used here -- they remain unique across CursorText.xaml
--- vs CursorText_c.xaml etc., so the widget-resolution logic is
--- identical; only the text-extraction step that follows it changed.
local function ResolveWidgetRoot(widgetLabel, anchorName)
    local findOk, anchor = pcall(Ext.UI.FindNameInWidget, anchorName)
    if not findOk or not anchor then
        Log.Debug("TARGET READ " .. widgetLabel
            .. ": anchor '" .. anchorName .. "' NOT FOUND"
            .. " (findOk=" .. tostring(findOk) .. ")")
        return nil
    end

    local widgetRoot = GetWidgetRoot(anchor)
    if not widgetRoot then
        Log.Debug("TARGET READ " .. widgetLabel
            .. ": GetWidgetRoot returned nil for anchor '"
            .. anchorName .. "'")
        return nil
    end

    Log.Debug("TARGET READ " .. widgetLabel
        .. ": widget root type=" .. SafeTypeName(widgetRoot)
        .. ", anchor=" .. tostring(anchor)
        .. ", widgetRoot=" .. tostring(widgetRoot))
    return widgetRoot
end

--- ReadDCPath wrapper that pcall-guards the C++ call and logs on
--- error.  Returns the C++ result (string / table / nil) on success;
--- nil on failure.  All read paths in this module funnel through
--- here so any C++ fault gets logged uniformly.
local function ReadPath(widgetRoot, path)
    if not widgetRoot or not path then return nil end
    local readOk, result = pcall(Ext.UI.ReadDCPath, widgetRoot, path)
    if not readOk then
        Log.Debug("TARGET READ ReadDCPath('" .. path
            .. "') FAILED: " .. tostring(result))
        return nil
    end
    return result
end

--- Convenience: read a path and return a non-empty trimmed string,
--- or nil if the path is missing / empty / a placeholder value.
local function ReadPathString(widgetRoot, path)
    local raw = ReadPath(widgetRoot, path)
    if type(raw) ~= "string" then return nil end
    if not IsValidText(raw) then return nil end
    return raw
end

--- Convenience: read a path and treat the result as a Bool string
--- (ConvertRawValueToString returns "On" / "Off" for bool DPs).
local function ReadPathBool(widgetRoot, path)
    local raw = ReadPath(widgetRoot, path)
    return raw == BOOL_TRUE
end

--- Format a numeric distance string ("3.7" -> "3.7 feet").  XAML
--- uses a UnitConverter to render this as locale-aware "3.7m" /
--- "12.1ft" but the underlying VM scalar is a unit-agnostic float
--- (BG3's internal units are roughly meters; "feet" is what TTS
--- naturally reads as a distance unit in English speech).  Drops
--- zero values which the XAML CountToVisibilityConverter would
--- collapse out of the panel.
local function FormatDistance(rawDistance)
    if not rawDistance or rawDistance == "" then return nil end
    local n = tonumber(rawDistance)
    if not n or n <= 0 then return nil end
    return string.format("%.1f feet", n)
end

--- Format a Cause clause as a standalone string, mimicking the
--- XAML's ParameterizedTranslatedString output for the Cause Run
--- (CursorText_c.xaml line 142 / line 313).  Returns the clause
--- ready to concatenate after a base error message via
--- CombineMessageAndCause -- e.g. " for ROUGH_TERRAIN" given a
--- prefix template like " for {0}".  Returns nil for missing /
--- empty causes so callers can leave the cause field unset.
local function FormatCauseClause(causeText)
    if not causeText or causeText == "" then return nil end
    local prefix = ResolveHandle("capabilityCausePrefix")
    if prefix and prefix:find("{0}") then
        return prefix:gsub("{0}", causeText)
    end
    return " " .. causeText
end

--- Map a VMCapabilityModifier {Type, Value} pair to the loca handle
--- key the XAML uses to render its Message Run.  Implements the
--- DataTrigger ladder from CursorText_c.xaml (lines 150-178).
--- Returns nil when no rule matches (XAML would render an empty
--- Message Run, which the CapabilityError DataTemplate.Triggers
--- sets to Visibility=Collapsed via the empty-text trigger).
local function ResolveCapabilityHandleKey(typeValue, rawValue)
    if not typeValue or typeValue == "" then return nil end
    if typeValue == "MovementBlocked" then
        return "capabilityMovementBlocked"
    end
    if typeValue == "MovementModification" then
        return "capabilityMovementImpeded"
    end
    if typeValue == "MovementMultiplier" then
        local n = tonumber(rawValue or "")
        if n and math.abs(n - 0.5) < 0.001 then
            return "capabilityMovementHalved"
        end
        return "capabilityMovementImpeded"
    end
    if typeValue == "MovementCostMultiplier" then
        local n = tonumber(rawValue or "")
        if n and math.abs(n - 2) < 0.001 then
            return "capabilityCostDouble"
        end
        return "capabilityCostMultiplier"
    end
    return nil
end

--- Read CursorText_c-equivalent fields directly from the widget
--- root's DataContext (the root Widget VM).  Replaces the previous
--- TextBlock-text reader, which was vulnerable to .Text DP
--- propagation lag (the ground-truth fields update synchronously
--- when BG3 updates the cursor target, but the bound TextBlock.Text
--- DP catches up across multiple frames).
---
--- Returns a flat table compatible with BuildTargetSpeechData's
--- cursorInfo parameter.  All values are pre-normalized strings
--- (percent / feet / "on" / etc.) ready for AddProperty.
local function ReadCursorDCData(widgetRoot)
    local cursor = {}
    if not widgetRoot then return cursor end

    -- Action label: the XAML TaskDescription TextBlock starts bound
    -- to ActiveTask.PreviewDescription (a generic verb like "Cast
    -- spell", "Move To", "Loot") and gets RE-BOUND to a more
    -- specific value via DataTriggers (CursorText_c.xaml lines
    -- 333-374):
    --   1. CurrentSpellTask non-null  -> CurrentSpellTask.Name
    --      ("Fire Bolt", "Healing Word", etc.)
    --   2. CurrentSpellTask.SpellType == Shout  -> still the spell
    --      Name, but the XAML wraps it with a parameterized
    --      "Shout: {0}" handle.  We just speak the name.
    --   3. CurrentSpellTask.ActionId == Throw / ImprovisedWeapon
    --      with TaskObject present  -> "Throw" handle
    --   4. Same ActionIds with TaskObject null -> "Throw" handle
    --      with no-target wording
    --   5. CurrentPlayer.IsRequestingPing == true  -> "Ping target"
    --      handle (overrides everything above)
    -- We mirror that ladder in priority order; later branches win.
    local actionLabel = ReadPathString(widgetRoot,
        "CurrentPlayer.UIData.ActiveTask.PreviewDescription")

    -- 1: CurrentSpellTask.Name takes over when a spell is queued.
    -- This is what produces "Fire Bolt" instead of "Cast spell".
    local spellName = ReadPathString(widgetRoot,
        "CurrentPlayer.SelectedCharacter.PlayerCharacterProperties.CurrentSpellTask.Name")
    if spellName then
        actionLabel = spellName
    end

    -- 3 / 4: Throw and ImprovisedWeapon override the spell name
    -- (they're not really spells; the engine routes them through
    -- the spell-task system but the XAML re-labels them).
    local actionId = ReadPathString(widgetRoot,
        "CurrentPlayer.SelectedCharacter.PlayerCharacterProperties.CurrentSpellTask.ActionId")
    if actionId == "Throw" or actionId == "ImprovisedWeapon" then
        local hasTaskObject = ReadPath(widgetRoot,
            "CurrentPlayer.UIData.ActiveTask.TaskObject")
        if hasTaskObject == nil then
            local noTargetMessage = ResolveHandle("throwActionNoTarget")
            if noTargetMessage and noTargetMessage ~= "" then
                actionLabel = noTargetMessage
            end
        else
            local throwMessage = ResolveHandle("throwAction")
            if throwMessage and throwMessage ~= "" then
                actionLabel = throwMessage
            end
        end
    end

    -- 5: Ping mode overrides everything above.
    if ReadPathBool(widgetRoot, "CurrentPlayer.IsRequestingPing") then
        local pingMessage = ResolveHandle("pingAction")
        if pingMessage and pingMessage ~= "" then
            actionLabel = pingMessage
        end
    end

    cursor.action = actionLabel

    -- Hit chance: only render when ShowDescription is true (XAML
    -- collapses the hitChance Border otherwise).  TotalHitChance is
    -- a UInt8 percent integer (0..100); speak as "N percent".
    -- (The C++ scalar-type recognition was extended to include
    -- Int8/Int16/UInt8/UInt16/UInt64 -- without UInt8, this read
    -- silently returned nil even when ShowDescription was true.)
    if ReadPathBool(widgetRoot,
        "CurrentPlayer.UIData.HitChanceDesc.ShowDescription") then
        local hcRaw = ReadPathString(widgetRoot,
            "CurrentPlayer.UIData.HitChanceDesc.TotalHitChance")
        if hcRaw then
            cursor.hitChance = hcRaw .. " percent"
        end
    end

    -- Distance to cursor target.  Skip when zero (XAML collapses
    -- the row).
    cursor.distance = FormatDistance(ReadPathString(widgetRoot,
        "CurrentPlayer.UIData.Cursor.Distance"))

    -- Per-source advantage / disadvantage descriptions.  Each
    -- VMAdvantage's Description scalar is the user-facing text
    -- (e.g. "Pack Tactics", "Threatened").
    local advantages = ReadPath(widgetRoot,
        "CurrentPlayer.UIData.HitChanceDesc.Advantages")
    if type(advantages) == "table" and #advantages > 0 then
        cursor.advantages = "Advantage"
        local descriptions = {}
        for _, item in ipairs(advantages) do
            local desc = item and item.Description
            if desc and IsValidText(desc) then
                descriptions[#descriptions + 1] = NormalizeText(desc)
            end
        end
        if #descriptions > 0 then
            cursor.advantageList = descriptions
        end
    end
    local disadvantages = ReadPath(widgetRoot,
        "CurrentPlayer.UIData.HitChanceDesc.Disadvantages")
    if type(disadvantages) == "table" and #disadvantages > 0 then
        cursor.disadvantages = "Disadvantage"
        local descriptions = {}
        for _, item in ipairs(disadvantages) do
            local desc = item and item.Description
            if desc and IsValidText(desc) then
                descriptions[#descriptions + 1] = NormalizeText(desc)
            end
        end
        if #descriptions > 0 then
            cursor.disadvantageList = descriptions
        end
    end

    -- ActiveTask.Info collection: VMText items the engine emits to
    -- explain why an action would or would not work ("Not enough
    -- movement", "Out of range", damage previews keyed off
    -- TextContext="HitChance" -- the latter duplicate the hit-chance
    -- bar above and are filtered out, mirroring the XAML's
    -- DataTrigger that sets Visibility=Collapsed for them).
    local infoItems = ReadPath(widgetRoot,
        "CurrentPlayer.UIData.ActiveTask.Info")
    if type(infoItems) == "table" and #infoItems > 0 then
        local cursorReasons = {}
        for _, item in ipairs(infoItems) do
            local text = item and item.Text
            local context = (item and item.TextContext) or ""
            if text and IsValidText(text) and context ~= "HitChance" then
                cursorReasons[#cursorReasons + 1] = NormalizeText(text)
            end
        end
        if #cursorReasons > 0 then
            cursor.cursorInfo = table.concat(cursorReasons, ". ")
        end
    end

    -- Attack-of-opportunity warning -- single trigger, fires when
    -- the move preview crosses an enemy's reach.
    if ReadPathBool(widgetRoot,
        "CurrentPlayer.UIData.ActiveTask.AoOWarning") then
        local aooText = ResolveHandle("attackOfOpportunity")
        if aooText and aooText ~= "" then
            cursor.actionWarning = aooText
        end
    end

    -- Surface preview message ("walking onto Fire creates a hazard",
    -- etc.).  This is a localized scalar TranslatedString whose
    -- resolved text comes through ReadDCPath.
    local surfaceMessage = ReadPathString(widgetRoot,
        "CurrentPlayer.UIData.ActiveTask.SurfaceMessage")
    if surfaceMessage then
        cursor.cursorInfo = (cursor.cursorInfo
            and (cursor.cursorInfo .. ". ") or "") .. surfaceMessage
    end

    -- Surface name on the cursor target (e.g. "Blood", "Fire") --
    -- comes through CurrentPlayer.UIData.SurfaceInformation.Header
    -- when HasSurface is true.
    local hasSurface = ReadPathBool(widgetRoot,
        "CurrentPlayer.UIData.SurfaceInformation.HasSurface")
    if hasSurface then
        cursor.surface = ReadPathString(widgetRoot,
            "CurrentPlayer.UIData.SurfaceInformation.Header")
    end

    -- Concentration warning: when the cursor task is itself a
    -- concentration spell AND the character already concentrates,
    -- speak the existing concentration name so the player hears
    -- they'd lose it.  XAML uses a parameterized translated string
    -- ("Concentration on {Name}"); we use plain English here since
    -- handlerState localization isn't wired up.
    local castingConcentration = ReadPathBool(widgetRoot,
        "CurrentPlayer.SelectedCharacter.PlayerCharacterProperties.CurrentSpellTask.IsConcentrationSpell")
    if castingConcentration then
        local existingSpellName = ReadPathString(widgetRoot,
            "CurrentPlayer.SelectedCharacter.ConcentrationSpell.Name")
        if existingSpellName then
            cursor.concentration =
                "Concentrating on " .. existingSpellName
        end
    end

    -- Capability errors (XAML's CapabilityListSelectorBehavior shows
    -- the FIRST visible item only; we mimic that by stopping at the
    -- first match).  The handle-key map lives in
    -- ResolveCapabilityHandleKey; the Cause Run is appended via the
    -- ParameterizedTranslatedString prefix.
    local capabilityList = ReadPath(widgetRoot,
        "CurrentPlayer.SelectedCharacter.PlayerCharacterProperties.ModifiedCapabilities")
    if type(capabilityList) == "table" and #capabilityList > 0 then
        for _, capItem in ipairs(capabilityList) do
            if type(capItem) == "table" then
                local handleKey = ResolveCapabilityHandleKey(
                    capItem.Type, capItem.Value)
                if handleKey then
                    local message = ResolveHandle(handleKey)
                    if message and message ~= "" then
                        cursor.capabilityError = message
                        if capItem.Cause and capItem.Cause ~= "" then
                            cursor.capabilityCause =
                                FormatCauseClause(capItem.Cause)
                        end
                        break
                    end
                end
            end
        end
    end

    -- Cannot-heal error: TargetCanBeHealed=false AND a non-null
    -- TargetHealBlockCause produce the message + cause pair shown
    -- by the XAML's TargetCantBeHealedError TextBlock.
    local canBeHealed = ReadPathBool(widgetRoot,
        "CurrentPlayer.UIData.ActiveTask.TargetCanBeHealed")
    if not canBeHealed then
        local cantHealMessage = ResolveHandle("targetCantBeHealed")
        if cantHealMessage and cantHealMessage ~= "" then
            local healCause = ReadPathString(widgetRoot,
                "CurrentPlayer.UIData.ActiveTask.TargetHealBlockCause")
            if healCause then
                cursor.cannotHealMessage = cantHealMessage
                cursor.cannotHealCause = FormatCauseClause(healCause)
            else
                -- TargetCanBeHealed=false sometimes fires without a
                -- cause when the engine knows the target is dead /
                -- already at full HP.  Skip in that case to avoid
                -- a misleading bare "Target cannot be healed".
                cursor.cannotHealMessage = nil
            end
        end
    end

    -- High-defense warning fires when the target's AC is far above
    -- the attacker's level (XAML's MultiBinding compares
    -- CurrentTarget.Stats.ArmorClass.Value against
    -- SelectedCharacter.Stats.Level.Value/2).  We can't easily
    -- reproduce the multibinding from a single path read, so derive
    -- it via the same arithmetic comparison in Lua.  Falls back to
    -- silence on missing inputs (rather than risk a false positive).
    local targetAC = tonumber(ReadPathString(widgetRoot,
        "CurrentPlayer.CurrentRegularOrCombatTurnTarget.Stats.ArmorClass.Value")
        or "")
    local selectedLevel = tonumber(ReadPathString(widgetRoot,
        "CurrentPlayer.SelectedCharacter.Stats.Level.Value") or "")
    local relation = ReadPathString(widgetRoot,
        "CurrentPlayer.CurrentRegularOrCombatTurnTarget.PlayerRelation")
    if targetAC and selectedLevel and relation == "Enemy"
        and ReadPathBool(widgetRoot,
            "CurrentPlayer.UIData.HitChanceDesc.ShowDescription")
        and (targetAC - 14) > (selectedLevel / 2) then
        local highDefMessage = ResolveHandle("highDefense")
        if highDefMessage and highDefMessage ~= "" then
            cursor.highDefense = highDefMessage
        end
    end

    -- Container state for Move To onto a chest / barrel.  Empty /
    -- NotExplored map to user-facing strings so the player hears
    -- whether they'd find anything.
    local containerState = ReadPathString(widgetRoot,
        "CurrentPlayer.UIData.ActiveTask.ContainerState")
    if containerState == "Empty" then
        cursor.container = "Empty"
    elseif containerState == "NotExplored" then
        cursor.container = "Unexplored"
    end

    -- Damage preview (e.g., "1~10" for Fire Bolt, "4~9" for Main Hand
    -- Attack).  This lives on the DamagesPropertyTextValues TextBlock
    -- inside the ActionDetailsTemplate, bound through Larian's
    -- TooltipExtender attached property -- which means we can't reach
    -- it via plain ReadDCPath.  The reachable approach is to find the
    -- TextBlock by its x:Name and read its rendered text.  Why this
    -- doesn't suffer from the binding-propagation lag the original
    -- text-based read did: the cursor-info stability gate in OnTick
    -- waits until ALL the cursor-info VM fields have settled before
    -- this read fires, by which point the bound TextBlock text has
    -- also propagated.  BuildTargetSpeechData already converts
    -- "X~Y" to "X to Y" for natural speech.
    local damageOk, damageElem = pcall(
        Ext.UI.FindNameInWidget, "DamagesPropertyTextValues")
    if damageOk and damageElem then
        local readOk, entries = pcall(
            Ext.UI.ReadElementStructuredTextBlocks, damageElem)
        if readOk and type(entries) == "table" and #entries > 0 then
            local rawText = entries[1].text
            if rawText and IsValidText(rawText) then
                cursor.damage = rawText
            end
        end
    end

    return cursor
end

--- Resolve the current cursor / D-pad target by reading the camera
--- entity's GameCameraBehavior.Targets[1].  Verified against Examine
--- ground truth: this field reflects the engine's actual cursor
--- target at game-thread speed -- always fresh, no Noesis-marshaling
--- lag.
---
--- Falls back to GameCameraBehavior.Target (singular) when Targets
--- is empty (defensive; in practice Targets[1] was populated in every
--- observed cycle, including when Target itself was nil because the
--- cursor had landed on the player character).
---
--- Returns the entity userdata or nil when no target is selected
--- (cursor on open ground / off any entity).
local function ResolveCameraTargetEntity()
    local queryOk, cameras = pcall(
        Ext.Entity.GetAllEntitiesWithComponent, "GameCameraBehavior")
    if not queryOk or not cameras or #cameras == 0 then return nil end

    -- Single-player has one camera entity.  Split-screen would have
    -- multiple but we don't differentiate; first entry is the local
    -- player's camera in single-player and a reasonable starting
    -- point in split-screen (the existing read pipeline didn't
    -- handle split-screen either).
    local cameraEntity = cameras[1]
    local readOk, gcb = pcall(function()
        return cameraEntity.GameCameraBehavior
    end)
    if not readOk or not gcb then return nil end

    local primaryTarget
    pcall(function()
        local targets = gcb.Targets
        if targets and #targets > 0 then
            primaryTarget = targets[1]
        end
    end)
    if not primaryTarget then
        pcall(function() primaryTarget = gcb.Target end)
    end
    if not primaryTarget then return nil end

    local resolveOk, entity = pcall(Ext.Entity.Get, primaryTarget)
    if not resolveOk or not entity then return nil end
    return entity
end

--- Read entity-side identity (name, HP, statuses count) from a
--- target entity returned by ResolveCameraTargetEntity.  These fields
--- come straight from the entity's own components -- no Noesis VM
--- involved -- so they're always synchronized with the engine's
--- actual state.
---
--- Returns a flat table compatible with BuildTargetSpeechData's
--- targetInfo parameter.
local function ReadEntityIdentity(targetEntity)
    local identity = {}
    if not targetEntity then return identity end

    -- Display name via DisplayName.Name (TranslatedString handle).
    pcall(function()
        if targetEntity.DisplayName then
            local nameHandle = targetEntity.DisplayName.Name
                or targetEntity.DisplayName.NameKey
            if nameHandle then
                local resolved = Helpers.ResolveTranslatedString(nameHandle)
                if resolved and resolved ~= "" then
                    identity.name = resolved
                end
            end
        end
    end)

    -- Health.Hp / MaxHp -- int counters maintained on the entity by
    -- the combat system, updated immediately when damage / healing
    -- resolves.
    pcall(function()
        if targetEntity.Health then
            local hp = targetEntity.Health.Hp
            local maxHp = targetEntity.Health.MaxHp
            if hp ~= nil then identity.hpCurrent = tostring(hp) end
            if maxHp ~= nil then identity.hpMax = tostring(maxHp) end
        end
    end)

    -- Status overflow count: count statuses on the entity to see
    -- whether we'd overflow the icon row sighted players see.  The
    -- existing Noesis StatusEffects.Count was a parallel value; we
    -- get the same number (or close to it) directly here.
    pcall(function()
        if targetEntity.StatusContainer
            and targetEntity.StatusContainer.Statuses then
            local statusCount = 0
            for _ in pairs(targetEntity.StatusContainer.Statuses) do
                statusCount = statusCount + 1
            end
            local maxDisplayed = 5
            if statusCount > maxDisplayed then
                identity.extraStatuses = "+"
                    .. tostring(statusCount - maxDisplayed)
            end
        end
    end)

    return identity
end

--- Read TargetInfo_c-equivalent fields.  Identity (name, HP,
--- overflow count) comes from the camera's actual cursor target
--- entity -- see ResolveCameraTargetEntity for why this is needed.
---
--- Level is read from the Noesis VM since the engine-side level on
--- combatant entities isn't exposed in a single obvious place; the
--- VM's level value is consistent for entities of the same template
--- so even in the rare cases when the VM lags, the level is rarely
--- wrong (a Devourer is always level 1).  If the VM identity differs
--- from the camera identity, we still skip the level so we don't
--- speak the wrong level for an under-leveled rare creature.
---
--- widgetRoot may be nil when the TargetInfo widget is missing /
--- invisible; identity reads work regardless because they don't go
--- through Noesis at all.
local function ReadTargetDCData(widgetRoot)
    local target = {}

    -- Camera-driven identity is always fresh.
    local targetEntity = ResolveCameraTargetEntity()
    local entityIdentity = ReadEntityIdentity(targetEntity)
    target.name = entityIdentity.name
    target.hpCurrent = entityIdentity.hpCurrent
    target.hpMax = entityIdentity.hpMax
    target.extraStatuses = entityIdentity.extraStatuses
    target._entity = targetEntity

    -- Level still comes from the VM (no clean entity-side source).
    -- Only trust it when the VM's identity matches the camera's --
    -- otherwise the VM is stale and the level may belong to a
    -- different target.
    if widgetRoot and target.name then
        local noesisName = ReadPathString(widgetRoot,
            "CurrentPlayer.CurrentRegularOrCombatTurnTarget.Name")
        local noesisHp = ReadPathString(widgetRoot,
            "CurrentPlayer.CurrentRegularOrCombatTurnTarget.Stats.Health.Value")
        local identityMatches = noesisName == target.name
            and noesisHp == target.hpCurrent
        target._noesisIdentityMatches = identityMatches

        if identityMatches then
            local targetType = ReadPathString(widgetRoot,
                "CurrentPlayer.CurrentRegularOrCombatTurnTarget.Type")
            if targetType == "Character" then
                target.level = ReadPathString(widgetRoot,
                    "CurrentPlayer.CurrentRegularOrCombatTurnTarget.Stats.Level.Value")
            end
            target.title = ReadPathString(widgetRoot,
                "CurrentPlayer.CurrentRegularOrCombatTurnTarget.Title")
        end
    end

    return target
end

--- Stable representation of a small subset of cursorInfo / target
--- info, used to log a one-line summary per read so we can see what
--- the DC pipeline produced this tick when the user reports a
--- missing or wrong field.
local function LogReadSummary(label, info, fields)
    if not info or next(info) == nil then
        Log.Debug("CLASSIFIED " .. label .. ": (empty)")
        return
    end
    local parts = {}
    for _, field in ipairs(fields) do
        if info[field] ~= nil then
            local v = info[field]
            if type(v) == "table" then v = "[table]" end
            parts[#parts + 1] = field .. "='" .. tostring(v) .. "'"
        end
    end
    table.sort(parts)
    Log.Debug("CLASSIFIED " .. label .. ": " .. table.concat(parts, ", "))
end

-- ---------------------------------------------------------------------------
-- Speech assembly (semantic roles, not string concatenation)
-- ---------------------------------------------------------------------------

--- Strip a leading "Level " / "Lv." / "Lvl." prefix from a level
--- text.  The XAML renders level via a ParameterizedTranslatedString
--- whose localized form is "Lv. N" in English (ConsoleFormat) and
--- "Level N" in the longer form.  If we pass "Lv. 1" to
--- AddProperty("Level", ...) the formatter produces "Level: Lv. 1"
--- which is audibly redundant.  Drop any known prefix so the
--- AddProperty label is the only source of the word.
---
--- Patterns handled:
---   "Level 3"  -> "3"
---   "Lv. 3"    -> "3"
---   "Lv 3"     -> "3"
---   "Lvl. 3"   -> "3"
local function StripLevelPrefix(levelText)
    if not levelText then return nil end
    local lowered = levelText:lower()
    local stripped = levelText
    if lowered:match("^level%s+") then
        stripped = levelText:gsub("^[Ll][Ee][Vv][Ee][Ll]%s+", "")
    elseif lowered:match("^lvl%.?%s*") then
        stripped = levelText:gsub("^[Ll][Vv][Ll]%.?%s*", "")
    elseif lowered:match("^lv%.?%s*") then
        stripped = levelText:gsub("^[Ll][Vv]%.?%s*", "")
    end
    return stripped
end

--- Compose capability / heal-error text.  XAML templates render these
--- as a two-Run TextBlock (Message + Cause, e.g. "Out of spell slots" +
--- " of level 2").  ReadCursorDCData captures each Run's data
--- separately under distinct fields (capabilityError /
--- capabilityCause, cannotHealMessage / cannotHealCause).  Stitch them
--- back together for the property value so the screen reader speaks
--- one coherent sentence.
local function CombineMessageAndCause(message, cause)
    if not message or message == "" then return nil end
    if cause and cause ~= "" then
        return message .. cause
    end
    return message
end

--- Build a SpeechData describing the current target-select state.
--- Returns nil when nothing speakable was captured (no target or
--- action in progress).  Uses ONLY the 14 core field names and
--- AddProperty for everything else, per the SpeechData architecture
--- rule "no ad-hoc field names; labels are expressed via AddProperty."
---
--- Field mapping:
---   status  -- preview action ("Attack", "Throw", "Move to")
---   name    -- target name ("Intellect Devourer")
---   additionalDescription -- extra cursor info (AoO warning,
---                            surface message) - verbose tier
---
--- Properties (in addition order, flexible labels):
---   Level           -- "3" (stripped of "Level " prefix)
---   Hit chance      -- "65 percent"
---   Distance        -- "8 meters"
---   Roll            -- "Advantage" or "Disadvantage"
---   Concentration   -- "Concentration on Bless"
---   Warning         -- high-defense indicator (enemy AC too high)
---   Cannot          -- capability error / cannot-heal message
---   Container       -- "Empty" / "Unexplored" (verbose)
---   More statuses   -- "+3" (overflow counter, verbose)
--- Convert a raw StatusLifetime.Lifetime (float seconds on the
--- status entity) to an integer turn count.  A D&D round is 6
--- seconds; this matches BG3's TimeToTurnConverter used by the
--- status-badge XAML (DataTemplates_c.xaml line 337).  Returns nil
--- for permanent / untimed statuses (Lifetime nil or <= 0).
---
--- Empirical: BURNING with one turn remaining reports Lifetime=6.0,
--- consistent with seconds-per-turn = 6.
local TURN_SECONDS = 6
local function LifetimeToTurns(rawLifetime)
    if not rawLifetime or rawLifetime <= 0 then return nil end
    local turns = math.ceil(rawLifetime / TURN_SECONDS)
    if turns < 1 then turns = 1 end
    return turns
end

--- Assemble a statuses phrase like "Threatened, Gaping Wounds 1
--- turn, Bless 3 turns" from a list of {statusId, name,
--- rawLifetime} entries.  Returns nil when nothing speakable
--- remains.
---
--- Filtering rule: drop entity statuses whose DisplayName failed
--- to resolve (entry.name still equals the raw status id like
--- "INSURFACE", "TUT_DUMMY").  Larian uses an empty / missing
--- DisplayName as the marker for "internal status, not meant for
--- player display."  Statuses whose DisplayName resolves
--- ("Threatened", "Groggy", "Burning") are user-facing -- the
--- icon row in TargetInfo_c may collapse the text label when too
--- many badges crowd the row (DataTemplates_c.xaml DataTrigger
--- on StatusHolderHolderHidden.ActualWidth), but the icon stays
--- visible to sighted players, so we should still speak it.
---
--- Permanent statuses (no Lifetime) render as name only; timed
--- statuses append " N turn" / " N turns" based on remaining
--- turns.
---
--- Visual-only statuses (those Larian intentionally left without a
--- DisplayName because they're VFX-only) are normally filtered out
--- because they speak as "%%% EMPTY".  But some of them ARE visible
--- to sighted players via VFX on the character model and should be
--- announced for accessibility parity.  VISUAL_ONLY_STATUS_NAMES
--- below maps the statusId to a readable name we'll use when the
--- DisplayName comes back as the placeholder.
local VISUAL_ONLY_STATUS_NAMES = {
    -- Blood splatter VFX on the character model after melee combat
    -- or bleeding sources.  Sighted players see a bloody character;
    -- blind players hear "Blood covered".
    BLOOD_COVERED = "Blood covered",
}

local function FormatStatusesPhrase(statuses)
    if not statuses or #statuses == 0 then return nil end
    local parts = {}
    for _, entry in ipairs(statuses) do
        local name = entry.name or ""
        local statusId = entry.statusId or ""
        -- A status is user-facing only if its DisplayName resolved
        -- to a real localized string.  Several internal forms
        -- indicate "no display name":
        --   1. name == statusId: the resolver fell back to the raw
        --      status id (INSURFACE, TUT_DUMMY).
        --   2. name == "" / nil: nothing came back at all.
        --   3. name starts with "%%%": Larian's placeholder marker
        --      for missing TranslatedString resolution
        --      ("%%% EMPTY", "%%% MissingString").  BLOOD_COVERED
        --      is a common case -- it's a real visual-only status
        --      (drives blood-splatter VFX on character models)
        --      with no player-facing name by design.
        local hasResolvedDisplayName = name ~= ""
            and name ~= statusId
            and name:sub(1, 3) ~= "%%%"
        local effectiveName = nil
        if hasResolvedDisplayName then
            effectiveName = name
        else
            -- Fall back to the visual-only-status lookup so
            -- accessibility-relevant VFX statuses (Blood covered etc.)
            -- still get announced.
            effectiveName = VISUAL_ONLY_STATUS_NAMES[statusId]
        end
        if effectiveName then
            local turns = LifetimeToTurns(entry.rawLifetime)
            if turns then
                local unit = (turns == 1) and "turn" or "turns"
                parts[#parts + 1] = effectiveName .. " "
                    .. tostring(turns) .. " " .. unit
            else
                parts[#parts + 1] = effectiveName
            end
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

local function BuildTargetSpeechData(
    targetInfo, cursorInfo, statuses,
    advantageList, disadvantageList)
    local speechData = SpeechData.Create()

    -- Per-instance priority override.  In SpeechData's canonical
    -- PROPERTY_ORDER, "Damage" is priority 40 because spell/weapon
    -- tooltips speak damage early (right after the spell name).  In
    -- the target-cycling context the desired order is name -> Level
    -- -> Status -> HP -> action hit chance -> Damage, which mirrors
    -- the screen's nameplate then action card grouping.  Override
    -- "Damage" to 155 so it sits after HP (145) and after the
    -- pattern-priced "<action> hit chance" labels (150).
    speechData.priorityOverrides = {
        ["Damage"] = 155,
    }

    -- Cast-blocking rejection text (out-of-range, can't target self,
    -- not enough movement, capability errors, cannot-heal errors).
    -- These ALL prevent the cast going through, so we put them in the
    -- "title" core field which:
    --   1. Speaks FIRST in the phrase, before name/HP/etc, so the
    --      player gets the cast-validity verdict before any other
    --      detail (a fast d-pad cycle still leaks the rejection).
    --   2. Bypasses the verbosity gate (title + sectionLabel are
    --      always spoken regardless of brief/normal/verbose).  This
    --      was the actual reason the rejection went silent in
    --      observed combat: at "brief" verbosity, normal-tier
    --      additionalDescription got filtered out.
    -- Save the combined text on the module-local rejection cache so
    -- the A-press handler can re-announce on confirm (catches the
    -- case where the navigation speech still got missed).
    local rejectionParts = {}
    if cursorInfo.cursorInfo and cursorInfo.cursorInfo ~= "" then
        rejectionParts[#rejectionParts + 1] = cursorInfo.cursorInfo
    end
    local capabilityRejection = CombineMessageAndCause(
        cursorInfo.capabilityError, cursorInfo.capabilityCause)
    if capabilityRejection then
        rejectionParts[#rejectionParts + 1] = capabilityRejection
    end
    local cannotHealRejection = CombineMessageAndCause(
        cursorInfo.cannotHealMessage, cursorInfo.cannotHealCause)
    if cannotHealRejection then
        rejectionParts[#rejectionParts + 1] = cannotHealRejection
    end
    local rejectionText = nil
    if #rejectionParts > 0 then
        rejectionText = table.concat(rejectionParts, ". ")
        speechData:Add("title", rejectionText, "brief")
    end
    lastRejectionText = rejectionText

    -- Target identity -- speak the target name PLAIN, no action
    -- prefix.  The action gets folded into the hit-chance label
    -- below ("Fire Bolt hit chance: X percent") which keeps the
    -- speech tight and reads more naturally than the previous
    -- verb-object form.
    if targetInfo.name then
        speechData:Add("name", targetInfo.name, "brief")
    end

    -- Level FIRST among the properties -- sits adjacent to the
    -- target name, mirroring the screen's "Intellect Devourer
    -- Lv. 1" nameplate placement.  StripLevelPrefix removes any
    -- "Lv. "/"Level " prefix from the raw value so AddProperty's
    -- own "Level: " label isn't redundant.
    local levelValue = StripLevelPrefix(targetInfo.level)
    if levelValue and levelValue ~= "" then
        speechData:AddProperty("Level", levelValue, "brief")
    end

    -- Statuses come AFTER Level so the speech reads
    -- "Intellect Devourer. Level: 1. Status: Threatened. <rest>"
    -- with the level grouped tightly with the name (matching the
    -- screen) and statuses one step later.  Routed through
    -- AddProperty rather than the "state" core field because core
    -- fields all fire before any property in CORE_FIELD_LIST order;
    -- using "state" would push statuses BEFORE Level.  "Status"
    -- (singular label, but the value can be a comma-joined list)
    -- reads naturally for both single and multiple statuses.
    local statusesPhrase = FormatStatusesPhrase(statuses)
    if statusesPhrase then
        speechData:AddProperty("Status", statusesPhrase, "normal")
    end

    -- HP next -- the most decision-relevant single number ("can I
    -- finish this target with one more attack?").  HealthMaxText
    -- carries a leading slash from the XAML ("/15") historically;
    -- strip if present.
    if targetInfo.hpCurrent and targetInfo.hpCurrent ~= "" then
        local maxClean = targetInfo.hpMax
            and targetInfo.hpMax:gsub("^/%s*", "") or ""
        local hpPhrase = targetInfo.hpCurrent
        if maxClean ~= "" then
            hpPhrase = hpPhrase .. " of " .. maxClean
        end
        speechData:AddProperty("HP", hpPhrase, "brief")
    end

    -- Hit chance, prefixed by the action name so the player hears
    -- which action the chance is for ("Fire Bolt hit chance: 80
    -- percent", "Main Hand Attack hit chance: 65 percent").  Bare
    -- "Hit chance" label when the action name is missing.
    if cursorInfo.hitChance then
        local hitChanceLabel = "Hit chance"
        if cursorInfo.action and cursorInfo.action ~= "" then
            hitChanceLabel = cursorInfo.action .. " hit chance"
        end
        speechData:AddProperty(
            hitChanceLabel, cursorInfo.hitChance, "brief")
    end

    -- Damage preview ("4~9" from XAML; rewrite to "4 to 9" for TTS).
    -- Bare "Damage" label -- the action name is already on the hit
    -- chance label above, so prefixing damage too would be redundant.
    if cursorInfo.damage and cursorInfo.damage ~= "" then
        local damagePhrase = cursorInfo.damage
            :gsub("(%d+)%s*~%s*(%d+)", "%1 to %2")
        speechData:AddProperty("Damage", damagePhrase, "brief")
    end

    -- Distance for movement-relevant cases (cursor on terrain or
    -- friendly).  Lower priority than hit chance / damage.
    if cursorInfo.distance then
        speechData:AddProperty(
            "Distance", cursorInfo.distance, "brief")
    end

    -- Attack-of-opportunity / provoke warning.  "Errors" role holds
    -- a line like "Provokes Attack of Opportunity" when the action
    -- would trigger a reaction from a nearby enemy.  Normal tier
    -- because it's a meaningful combat warning.
    if cursorInfo.actionWarning then
        speechData:AddProperty(
            "Warning", cursorInfo.actionWarning, "normal")
    end

    -- Cooldown / recharge info for limited-use actions ("Short
    -- Rest", "Long Rest", "Per Turn").  Normal tier; helps players
    -- plan burst usage.
    if cursorInfo.cooldown then
        speechData:AddProperty(
            "Recharge", cursorInfo.cooldown, "normal")
    end

    -- Applied condition preview ("Applies: Gaping Wounds for 2
    -- Turn(s)").  XAML splits this across three TextBlocks; we
    -- reassemble.  Verbose tier -- useful but not combat-critical.
    if cursorInfo.appliesName then
        local turnsPhrase = cursorInfo.appliesName
        if cursorInfo.appliesTurns
            and cursorInfo.appliesTurns ~= "" then
            turnsPhrase = turnsPhrase .. " for "
                .. cursorInfo.appliesTurns
            if cursorInfo.appliesTurnsUnit
                and cursorInfo.appliesTurnsUnit ~= "" then
                turnsPhrase = turnsPhrase .. " "
                    .. cursorInfo.appliesTurnsUnit
            end
        end
        speechData:AddProperty("Applies", turnsPhrase, "verbose")
    end

    -- Surface the target / cursor is on ("Blood", "Fire", "Ice",
    -- etc.).  Brief tier because it changes hazard calculus
    -- (positioning, reactions, AoO) and the blind player needs the
    -- same awareness sighted players get from the SurfaceInfo
    -- TextBlock on the cursor panel.
    if cursorInfo.surface then
        speechData:AddProperty(
            "Surface", cursorInfo.surface, "brief")
    end

    -- Roll modifier as label-value: the mode (Advantage / Disadvantage)
    -- becomes part of the label so the source(s) read as the value.
    -- XAML collapses both Advantage and Disadvantage rows when both
    -- populate (they cancel on the d20), so at most one mode is in
    -- play per readout.  Source descriptions are read out of
    -- TargetInfo_c.xaml AdvantagesListHolder / DisadvantagesListHolder
    -- at lines 224 and 259.
    -- Output examples:
    --   "Roll Disadvantage: Target is too close"
    --   "Roll Advantage: High Ground, Pack Tactics"
    --   "Roll: Advantage" (no sources rendered, e.g. ShowDescription
    --                      false during cursor exploration)
    local rollMode = nil
    local rollSources = nil
    if cursorInfo.advantages then
        rollMode = cursorInfo.advantages
        rollSources = advantageList
    elseif cursorInfo.disadvantages then
        rollMode = cursorInfo.disadvantages
        rollSources = disadvantageList
    end
    if rollMode then
        if rollSources and #rollSources > 0 then
            speechData:AddProperty("Roll " .. rollMode,
                table.concat(rollSources, ", "), "brief")
        else
            speechData:AddProperty("Roll", rollMode, "brief")
        end
    end

    -- Reason context.  BG3 renders these as unlabeled Runs in
    -- either widget depending on which sub-explainer fires:
    -- TargetInfo_c shows HitChanceDesc reasons ("Target is too
    -- close", "Threatened" -> ranged disadvantage explainer),
    -- CursorText_c shows action-availability reasons ("Not enough
    -- movement", "Can't reach destination").  Empty label: each
    -- phrase is a complete self-explanatory clause; a "Reason:"
    -- prefix would be redundant.  Stitch both with ". " so the
    -- formatter still inserts its own clause separator after.
    local reasonParts = {}
    if targetInfo.reasonText and targetInfo.reasonText ~= "" then
        reasonParts[#reasonParts + 1] = targetInfo.reasonText
    end
    if cursorInfo.reasonText and cursorInfo.reasonText ~= ""
        and cursorInfo.reasonText ~= targetInfo.reasonText then
        reasonParts[#reasonParts + 1] = cursorInfo.reasonText
    end
    if #reasonParts > 0 then
        speechData:AddProperty(
            "", table.concat(reasonParts, ". "), "brief")
    end

    -- Concentration warning: "Concentrating on Bless" (from
    -- ParameterizedTranslatedString).  Important enough to be
    -- "normal" tier, not verbose.
    if cursorInfo.concentration then
        speechData:AddProperty(
            "Concentration", cursorInfo.concentration, "normal")
    end

    -- High-defense warning: the XAML flags when target AC is far
    -- above the attacker's level.  Keep as a warning property.
    if cursorInfo.highDefense then
        speechData:AddProperty(
            "Warning", cursorInfo.highDefense, "normal")
    end

    -- (Capability errors and cannot-heal errors moved up into the
    -- "title" core field above so they front-load and bypass the
    -- verbosity gate.  See the rejectionParts block at the start
    -- of this function.)

    -- Container state for Move To over a chest/barrel.  Verbose
    -- tier: the information is ambient, not central to target
    -- choice.
    if cursorInfo.container then
        speechData:AddProperty(
            "Container", cursorInfo.container, "verbose")
    end

    -- (cursorInfo.cursorInfo / capability errors / cannot-heal errors
    -- moved up into the "title" core field above so they front-load
    -- and bypass the verbosity gate.  See the rejectionParts block
    -- at the start of this function.)

    -- Active status effects with turn counts are appended inline to
    -- the target name (see the "name" core field setup above), so
    -- no standalone Statuses property fires here.  This makes the
    -- status ownership unambiguous in speech ("Intellect Devourer,
    -- Threatened" rather than the trailing "Statuses: Threatened"
    -- that read confusingly when the attacker also had the same
    -- status, e.g. mutual Threatened in melee reach).

    -- Status effects overflow ("+3 more") -- verbose; not critical
    -- to target choice but useful when tuning full combat state.
    if targetInfo.extraStatuses then
        speechData:AddProperty(
            "More statuses", targetInfo.extraStatuses, "verbose")
    end

    -- If nothing was added, return nil so callers skip speaking.
    if next(speechData.coreFields) == nil
        and #speechData.properties == 0 then
        return nil
    end
    return speechData
end

-- ---------------------------------------------------------------------------
-- Read & speak
-- ---------------------------------------------------------------------------

-- Field whitelists for LogReadSummary -- log only the fields that
-- actually feed BuildTargetSpeechData so the log line stays readable.
-- (Definitions also document the full set of expected fields per
-- widget for future maintenance.)
local TARGET_LOG_FIELDS = {
    "name", "title", "level", "hpCurrent", "hpMax", "extraStatuses",
}
local CURSOR_LOG_FIELDS = {
    "action", "hitChance", "distance", "advantages", "disadvantages",
    "cursorInfo", "actionWarning", "concentration",
    "capabilityError", "capabilityCause",
    "cannotHealMessage", "cannotHealCause",
    "highDefense", "container", "surface",
}

--- Perform the actual widget read and speech.  Called after the
--- defer timer fires -- never directly from the input handler.
---
--- Instrumented end-to-end: logs DC read results and composed speech.
--- When the user reports "d-pad did nothing," the log shows which
--- stage dropped the data.
--- forceSpeak (default false): when true, accept identity-only
--- speech if Noesis cursor info still hasn't caught up (the retry
--- budget exhausted).  When false, return false on identity
--- mismatch so the caller can re-schedule.
---
--- Returns true when speech was emitted (or skipped intentionally
--- via dedup/empty cases).  Returns false when the read should be
--- retried because Noesis hasn't caught up yet.
local function PerformTargetRead(forceSpeak)
    Log.Debug("TARGET READ: begin")

    -- Log the current turn-order pool for comparison with the
    -- d-pad cycle results.  If the pool has four combatants but
    -- the d-pad cycle consistently surfaces only one or two, the
    -- difference is game-side filtering (range, line-of-sight,
    -- valid-for-action) rather than a bug in our read pipeline.
    local Combat = BG3Access.Client.Combat
    if Combat and Combat.ReadTurnOrder then
        local turnEntries = Combat.ReadTurnOrder()
        if turnEntries and #turnEntries > 0 then
            local names = {}
            for _, entry in ipairs(turnEntries) do
                names[#names + 1] =
                    (entry.isCurrent and "*" or "") .. entry.name
            end
            Log.Debug("TARGET READ: turn-order pool ("
                .. tostring(#turnEntries) .. "): "
                .. table.concat(names, ", "))
        else
            Log.Debug("TARGET READ: turn-order pool = (empty)")
        end
    end

    -- Resolve a widget root for each XAML widget (TargetInfo_c,
    -- CursorText_c).  Both widgets ultimately route through the
    -- same root Widget VM (CurrentPlayer / Data / Layout), so
    -- either widget root works for any DC path -- but resolving
    -- both serves as a presence check so missing widgets log a
    -- specific "anchor not found" line for diagnosis.
    local targetWidgetRoot = ResolveWidgetRoot(
        "TargetInfo_c", TARGET_INFO_ANCHOR)
    local cursorWidgetRoot = ResolveWidgetRoot(
        "CursorText_c", CURSOR_TEXT_ANCHOR)

    local targetInfo = ReadTargetDCData(
        targetWidgetRoot or cursorWidgetRoot)
    local cursorInfo = ReadCursorDCData(
        cursorWidgetRoot or targetWidgetRoot)

    -- The Noesis VM (which provides cursor info -- action, distance,
    -- hit chance, advantages, AoO warning, etc.) lags the engine's
    -- actual cursor target intermittently.  When that happens, the
    -- VM's identity won't match the camera's identity (which is the
    -- ground truth -- see ResolveCameraTargetEntity), and the cursor
    -- info belongs to the WRONG target.
    --
    -- Cursor info is critical accessibility data -- sighted players
    -- read action / distance / hit chance / advantages from visual
    -- cues we have no equivalent for.  Discarding it isn't an
    -- option.  Instead, the per-tick OnTick handler keeps calling
    -- this function each frame until the identity matches (so the
    -- cursor info we read with it is for the right target).  This
    -- function returns false when the identity hasn't caught up yet,
    -- and OnTick checks again on the next frame -- no timer
    -- arithmetic, just frame-by-frame polling driven by the engine
    -- itself.  When forceSpeak is true (READ_MAX_TOTAL_MS budget
    -- exhausted), we accept identity-only speech as a last resort
    -- rather than blocking forever.
    if targetInfo._noesisIdentityMatches == false then
        if not forceSpeak then
            Log.Info("TARGET READ: Noesis identity stale (camera='"
                .. tostring(targetInfo.name) .. "' "
                .. tostring(targetInfo.hpCurrent) .. "/"
                .. tostring(targetInfo.hpMax)
                .. "'); next tick will retry")
            return false
        end
        Log.Info("TARGET READ: Noesis identity stale (camera='"
            .. tostring(targetInfo.name) .. "' "
            .. tostring(targetInfo.hpCurrent) .. "/"
            .. tostring(targetInfo.hpMax)
            .. "); retry budget exhausted, identity-only speech")
        cursorInfo = {}
    end

    -- Surface the per-source advantage / disadvantage descriptions
    -- the speech builder expects.  ReadCursorDCData populated
    -- cursor.advantageList / disadvantageList from the VM
    -- collections.
    local advantageList = cursorInfo.advantageList
    local disadvantageList = cursorInfo.disadvantageList

    -- Cache the cursor target UUID for the effects view.  We get
    -- the live entity straight from ResolveCameraTargetEntity (no
    -- name-pool lookup needed -- the camera gives us the precise
    -- entity, even when multiple combatants share a name).  Only
    -- cache the UUID string, never the entity userdata pointer
    -- across ticks (caching pointers across teardown windows
    -- caused "dead object in ToString" SEH faults).
    lastTargetName = targetInfo.name
    lastTargetEntityUuid = nil
    if targetInfo._entity then
        pcall(function()
            if targetInfo._entity.Uuid
                and targetInfo._entity.Uuid.EntityUuid then
                lastTargetEntityUuid = tostring(
                    targetInfo._entity.Uuid.EntityUuid)
            end
        end)
    end

    -- Record freshness timestamp so the effects view can decide
    -- whether the cached target is still current.  Set even when
    -- entity resolution fails so the "target selected but not
    -- resolved" case also ages out.
    lastTargetReadAtMs = Ext.Utils.MonotonicTime()

    LogReadSummary("TargetInfo_c", targetInfo, TARGET_LOG_FIELDS)
    LogReadSummary("CursorText_c", cursorInfo, CURSOR_LOG_FIELDS)

    -- Read the authoritative status list from the target entity.
    -- EnumerateStatuses returns {statusId, name, description,
    -- rawLifetime}.  FormatStatusesPhrase filters by "DisplayName
    -- resolved" -- statuses whose entry.name still equals the raw
    -- statusId are treated as internal (no user-facing label) and
    -- dropped, so INSURFACE / tutorial blockers don't speak while
    -- Groggy / Threatened / Burning still do.
    local entityStatuses = {}
    local targetEntity = ResolveTargetEntity()
    if targetEntity then
        entityStatuses = EnumerateStatuses(targetEntity)
        Log.Debug("TARGET READ: entity statuses ("
            .. tostring(#entityStatuses) .. ")")
        for _, statusEntry in ipairs(entityStatuses) do
            Log.Debug("  status: id='"
                .. tostring(statusEntry.statusId) .. "' name='"
                .. tostring(statusEntry.name) .. "' lifetime="
                .. tostring(statusEntry.rawLifetime))
        end
    end

    local speechData = BuildTargetSpeechData(
        targetInfo, cursorInfo, entityStatuses,
        advantageList, disadvantageList)
    if not speechData then
        Log.Info("TARGET READ: no speakable data (widgets produced"
            .. " no classifiable entries)")
        return true
    end

    local candidatePhrase = speechData:Format()
    Log.Info("TARGET READ: composed phrase = '"
        .. tostring(candidatePhrase) .. "'")

    -- Rapid-bounce dedup: if the exact same formatted phrase comes
    -- up again within DEDUP_WINDOW_MS, skip -- the game didn't
    -- actually move to a new target (e.g. end-of-list bounce).
    -- Compare against handlerState.lastSpokenFullText which :Speak()
    -- populates on every successful utterance.
    local nowMs = Ext.Utils.MonotonicTime()
    if candidatePhrase == handlerState.lastSpokenFullText
        and (nowMs - lastSpokenAtMs) < DEDUP_WINDOW_MS then
        Log.Info("TARGET READ: dedup suppressed (same phrase within "
            .. tostring(DEDUP_WINDOW_MS) .. "ms)")
        return true
    end
    lastSpokenAtMs = nowMs

    -- :Speak with isScreenEntry=true + userInitiated=true -> the
    -- SpeechData formatter interrupts current speech (the user just
    -- pressed d-pad; they want to hear the new target immediately).
    -- It also records handlerState.spokenRoles / lastSpokenFullText
    -- so subsequent tooltip / INPC events can cross-off what we said.
    speechData:Speak(handlerState, true, nil, true)
    return true
end

--- Snapshot the current camera target UUID.  Returns nil when no
--- camera entity exists or no target is currently selected.  Used
--- as a "pre-press" snapshot so the per-tick handler can detect
--- when the engine has actually processed a D-pad input (camera
--- UUID diverges from the snapshot).
local function SnapshotCameraTargetUuid()
    local entity = ResolveCameraTargetEntity()
    if not entity then return nil end
    local uuid
    pcall(function()
        if entity.Uuid and entity.Uuid.EntityUuid then
            uuid = tostring(entity.Uuid.EntityUuid)
        end
    end)
    return uuid
end

--- Snapshot the CurrentPlayer.CurrentTarget identity from the
--- TargetInfo_c VM.  Used as a SECOND advance signal alongside the
--- camera UUID so D-pad targeting works outside combat.
---
--- Why a second signal: the combat camera target field
--- (GameCameraBehavior.Targets[1]) is only populated during combat.
--- In exploration the engine's D-pad target cycle updates a
--- different VM field -- CurrentPlayer.CurrentTarget -- which the
--- TargetInfo_c.xaml widget binds for its name / AC / rarity / etc.
--- displays.  By snapshotting the CurrentTarget's EntityHandle (or
--- Name as fallback) and watching it for divergence, we detect a
--- successful exploration cycle the same way we detect a combat
--- cycle via camera UUID.
---
--- Returns nil when the widget isn't mounted (e.g. no target on
--- screen at all) -- the OnTick advance check handles nil-vs-value
--- as a divergence, which is exactly what we want when the press
--- transitions from "no target" to "Shadowheart targeted."
local function SnapshotCurrentTargetIdentity()
    local widgetRoot = ResolveWidgetRoot(
        "TargetInfo_c", TARGET_INFO_ANCHOR)
    if not widgetRoot then return nil end
    -- EntityHandle is the most stable per-entity identifier exposed
    -- on CurrentTarget; falls through to .Name only when the handle
    -- read returns nil (which can happen for non-character targets
    -- the engine hasn't fully classified yet).
    local handleValue = ReadPath(
        widgetRoot, "CurrentPlayer.CurrentTarget.EntityHandle")
    if handleValue ~= nil then
        return tostring(handleValue)
    end
    local nameValue = ReadPath(
        widgetRoot, "CurrentPlayer.CurrentTarget.Name")
    if nameValue and nameValue ~= "" then
        return tostring(nameValue)
    end
    return nil
end

-- Per-press state.  Set by OnButtonInput, consumed by the per-tick
-- handler.  Nil when no press is awaiting the engine to process.
--
-- Fields:
--   prePressCameraUuid -- camera target UUID at the moment of the
--     D-pad press, BEFORE the engine processed it.  The tick handler
--     waits for the live camera UUID to diverge from this.
--   startTimeMs        -- monotonic time of the press; used to bound
--     how long we wait before giving up.
--   pressId            -- monotonic counter; the tick handler
--     ignores stale pending records (a newer press supersedes them).
local pendingPress = nil
local nextPressId = 0

-- Diagnostic: per-tick cursor-info evolution logger.  Active for the
-- first DIAG_EVOLVE_MAX_TICKS frames after a D-pad press.  Logs the
-- raw cursor-info VM values each tick so we can see whether the
-- cursor-info VM fields evolve over time (settling toward the truth)
-- or stay uniformly stale.  Read-only -- does not affect speech.
-- Declared BEFORE MarkPendingPress so the local reference resolves
-- correctly (Lua locals are lexical).
local DIAG_EVOLVE_MAX_TICKS = 40
local diagEvolveState = nil

-- Hash a small set of cursor-info VM fields into a comparable string.
-- Used by the stability gate in OnTick to detect when the cursor info
-- has (a) diverged from the pre-press snapshot (engine has updated
-- the values) and (b) stabilized across two consecutive ticks (engine
-- is done updating).  Field choice mirrors the diagnostic logger:
-- ShowDescription / TotalHitChance / AoOWarning / ActiveTask.Info are
-- the fields the diagnostic showed evolving across ticks.
local function ComputeCursorInfoHash(widgetRoot)
    if not widgetRoot then return "" end
    local parts = {}
    -- ActiveTask.PreviewDescription is the action label ("Move To",
    -- "Cast spell", "Main Hand Attack", ...).  MUST be in the hash
    -- so the engine's stage-1 transition (Move To -> Cast spell at
    -- ~120ms post-press) resets stability.  Without this, evolves
    -- where action changes but hc/info stay zero/empty look
    -- identical and the stability timer expires during the quiet
    -- zone between stage 1 (action transition) and stage 2 (hit
    -- chance / warnings populate at ~320ms).
    parts[#parts + 1] = "act:"
        .. tostring(ReadPath(widgetRoot,
            "CurrentPlayer.UIData.ActiveTask.PreviewDescription"))
    parts[#parts + 1] = "show:"
        .. tostring(ReadPath(widgetRoot,
            "CurrentPlayer.UIData.HitChanceDesc.ShowDescription"))
    parts[#parts + 1] = "hc:"
        .. tostring(ReadPath(widgetRoot,
            "CurrentPlayer.UIData.HitChanceDesc.TotalHitChance"))
    parts[#parts + 1] = "aoo:"
        .. tostring(ReadPath(widgetRoot,
            "CurrentPlayer.UIData.ActiveTask.AoOWarning"))
    local info = ReadPath(widgetRoot,
        "CurrentPlayer.UIData.ActiveTask.Info")
    if type(info) == "table" then
        for index, item in ipairs(info) do
            parts[#parts + 1] = "info" .. index .. ":"
                .. tostring(item and item.Text)
                .. "/" .. tostring(item and item.TextContext)
        end
    end
    return table.concat(parts, "|")
end

--- Called by OnButtonInput on every accepted D-pad press.  Records
--- the pre-press camera UUID AND the pre-press cursor-info hash so
--- the per-tick handler can detect when both have updated.  No timer
--- involved -- the next render frame will trigger the read attempt.
local function MarkPendingPress(preCameraUuid)
    nextPressId = nextPressId + 1
    -- Pre-press cursor info hash: captures whatever cursor-info state
    -- was visible at the moment of the press.  After the press the
    -- engine eventually updates these fields; the stability gate in
    -- OnTick waits for the hash to (1) differ from this snapshot, then
    -- (2) stabilize for one more tick.
    local cursorWidgetRoot = ResolveWidgetRoot(
        "CursorText_c", CURSOR_TEXT_ANCHOR)
    local prePressCursorHash =
        ComputeCursorInfoHash(cursorWidgetRoot)

    -- Snapshot CurrentPlayer.CurrentTarget identity in addition to
    -- the camera UUID.  See SnapshotCurrentTargetIdentity for why:
    -- the combat camera-target field is empty in exploration, so
    -- without this second signal the engine could process a
    -- successful exploration D-pad cycle and we'd never notice
    -- (camera UUID stays unchanged the whole time, the gate times
    -- out, we fall back to identity-only Tav speech).
    local prePressCurrentTargetId = SnapshotCurrentTargetIdentity()

    pendingPress = {
        prePressCameraUuid = preCameraUuid,
        prePressCurrentTargetId = prePressCurrentTargetId,
        prePressCursorHash = prePressCursorHash,
        startTimeMs = Ext.Utils.MonotonicTime(),
        pressId = nextPressId,
        -- Stability tracking: cursor-info hash + timestamp of when
        -- it was last DIFFERENT.  Diagnostic showed the engine runs
        -- a multi-stage compute pipeline (range check → hit chance
        -- attempt → pathfind → AoO check → settle), each stage
        -- producing a briefly stable intermediate state.  Wait for
        -- the hash to be UNCHANGED for STABILITY_MS milliseconds to
        -- get past the intermediate states and capture the final
        -- settled value.
        lastSeenCursorHash = nil,
        lastHashChangeMs = nil,
    }
    diagEvolveState = {
        startTimeMs = pendingPress.startTimeMs,
        ticksLogged = 0,
    }
end

local function DiagEvolveTick()
    if not diagEvolveState then return end
    if diagEvolveState.ticksLogged >= DIAG_EVOLVE_MAX_TICKS then
        diagEvolveState = nil
        return
    end

    diagEvolveState.ticksLogged = diagEvolveState.ticksLogged + 1
    local elapsedMs = Ext.Utils.MonotonicTime()
        - diagEvolveState.startTimeMs

    -- Resolve a cursor widget root for the path reads.
    local cursorWidgetRoot = ResolveWidgetRoot(
        "CursorText_c", CURSOR_TEXT_ANCHOR)
    if not cursorWidgetRoot then
        Log.Debug("CURSOR EVOLVE [" .. tostring(diagEvolveState.ticksLogged)
            .. "@" .. tostring(elapsedMs) .. "ms] no cursor widget")
        return
    end

    -- Camera target identity.
    local camEntity = ResolveCameraTargetEntity()
    local camId = "nil"
    if camEntity then
        pcall(function()
            local name
            if camEntity.DisplayName and camEntity.DisplayName.Name then
                local resolved = Helpers.ResolveTranslatedString(
                    camEntity.DisplayName.Name)
                if resolved and resolved ~= "" then name = resolved end
            end
            local hp = "?"
            if camEntity.Health then
                hp = tostring(camEntity.Health.Hp) .. "/"
                    .. tostring(camEntity.Health.MaxHp)
            end
            camId = (name or "?") .. " " .. hp
        end)
    end

    -- Raw cursor-info VM fields.
    local action = ReadPath(cursorWidgetRoot,
        "CurrentPlayer.UIData.ActiveTask.PreviewDescription")
    local showDesc = ReadPath(cursorWidgetRoot,
        "CurrentPlayer.UIData.HitChanceDesc.ShowDescription")
    local totalHC = ReadPath(cursorWidgetRoot,
        "CurrentPlayer.UIData.HitChanceDesc.TotalHitChance")
    local aoo = ReadPath(cursorWidgetRoot,
        "CurrentPlayer.UIData.ActiveTask.AoOWarning")

    -- ActiveTask.Info collection: summarize first few entries.
    local info = ReadPath(cursorWidgetRoot,
        "CurrentPlayer.UIData.ActiveTask.Info")
    local infoStr = "nil"
    if type(info) == "table" then
        if #info == 0 then
            infoStr = "[]"
        else
            local items = {}
            for index, item in ipairs(info) do
                local txt = (item and item.Text) or "?"
                local ctx = (item and item.TextContext) or ""
                items[#items + 1] = '"' .. txt .. '"'
                    .. (ctx ~= "" and ("/" .. ctx) or "")
                if index >= 3 then
                    items[#items + 1] = "..."
                    break
                end
            end
            infoStr = "[" .. table.concat(items, ", ") .. "]"
        end
    end

    Log.Debug("CURSOR EVOLVE [" .. tostring(diagEvolveState.ticksLogged)
        .. "@" .. tostring(elapsedMs) .. "ms]"
        .. " cam=" .. camId
        .. " action=" .. tostring(action)
        .. " showDesc=" .. tostring(showDesc)
        .. " hc=" .. tostring(totalHC)
        .. " aoo=" .. tostring(aoo)
        .. " info=" .. infoStr)
end

--- Per-tick handler.  Runs on every game tick (Ext.Events.Tick).
--- When pendingPress is set, attempts the read; when not, no-op.
---
--- Two conditions must hold before we speak:
---   1. The camera UUID has changed from the pre-press snapshot
---      (engine has processed the press).
---   2. PerformTargetRead succeeds (Noesis identity matches camera
---      identity, so the cursor info is for the right target).
--- If either fails, we DO NOTHING this tick -- the next tick will
--- check again.  No retry timers, no fixed intervals.
---
--- After READ_MAX_TOTAL_MS, we force-speak whatever we have to
--- avoid blocking on engine state that may never arrive (e.g.,
--- target despawned mid-press, focus lost, weird transient state).
local function OnTick()
    -- Diagnostic logging fires independently of pendingPress so we
    -- still see field evolution for ticks that occur after we've
    -- already spoken (whether speech was correct or stale).
    DiagEvolveTick()

    if not pendingPress then return end

    local elapsedMs = Ext.Utils.MonotonicTime()
        - pendingPress.startTimeMs
    local timeoutReached = elapsedMs >= READ_MAX_TOTAL_MS

    -- Phase 1: wait for ANY of three signals to diverge from
    -- pre-press, indicating BG3 has acknowledged the press:
    --   * Camera UUID (combat target cycle).
    --   * CurrentTarget VM identity (exploration target cycle).
    --   * Cursor-info hash (target-prompt error messages).
    --
    -- The third signal is essential when the engine REJECTS the
    -- press: e.g. queuing Revivify on a downed-not-dead party
    -- member produces a sequence of cursor-prompt error messages
    -- ("Can't target self" -> "No target" -> "Target must be a
    -- playable character") with the cursor staying glued to the
    -- caster.  Without the cursor-hash signal, neither camera nor
    -- target ID advances and the gate waits the full 900ms
    -- timeout before falling back to stale identity-only speech.
    -- With it, the message change registers as "press handled" and
    -- the user hears the actual rejection in ~300-400ms.
    local currentUuid = SnapshotCameraTargetUuid()
    local cameraAdvanced = currentUuid ~= pendingPress.prePressCameraUuid
    local currentTargetId = SnapshotCurrentTargetIdentity()
    local currentTargetAdvanced =
        currentTargetId ~= pendingPress.prePressCurrentTargetId
    local cursorHashNow = ComputeCursorInfoHash(
        ResolveWidgetRoot("CursorText_c", CURSOR_TEXT_ANCHOR))
    local cursorHashAdvanced =
        cursorHashNow ~= pendingPress.prePressCursorHash
    local pressAcknowledged = cameraAdvanced
        or currentTargetAdvanced or cursorHashAdvanced
    if not pressAcknowledged and not timeoutReached then
        return  -- engine hasn't processed yet; next tick
    end

    -- Phase 2: stability gate on cursor info.  After the engine
    -- processes the press (camera UUID advances), the cursor-info VM
    -- fields can do one of two things: (a) keep updating across
    -- multiple ticks as the engine runs through its compute pipeline
    -- before settling, or (b) stay identical to the pre-press values
    -- because the new target happens to share the same hit chance /
    -- info / etc. as the previous one.  We can't tell (a) from (b)
    -- by comparing to the pre-press snapshot -- in (b), the hash
    -- equals pre-press and would block forever.  Instead, the moment
    -- camera UUID advances, RESET the stability tracking and wait
    -- STABILITY_MS of unchanged hash from THAT point.  Both cases
    -- collapse to the same logic: the engine has settled when the
    -- cursor-info hash hasn't changed for STABILITY_MS post-advance.
    local cursorWidgetRoot = ResolveWidgetRoot(
        "CursorText_c", CURSOR_TEXT_ANCHOR)
    local currentCursorHash = ComputeCursorInfoHash(cursorWidgetRoot)
    local nowMs = Ext.Utils.MonotonicTime()

    -- Initialize stability tracking the FIRST tick we observe camera
    -- advance.  Crediting any time before camera advance would let
    -- pre-press stale-but-stable hashes pass the gate.
    if pendingPress.cameraAdvanceObservedMs == nil then
        pendingPress.cameraAdvanceObservedMs = nowMs
        pendingPress.lastSeenCursorHash = currentCursorHash
        pendingPress.lastHashChangeMs = nowMs
        return  -- start fresh on the next tick
    end

    if currentCursorHash ~= pendingPress.lastSeenCursorHash then
        pendingPress.lastSeenCursorHash = currentCursorHash
        pendingPress.lastHashChangeMs = nowMs
        return  -- still settling
    end

    -- The cursor-info VM evolves in two stages on attackable
    -- targets: stage 1 (~120ms after press) is the action-label
    -- transition (Move To -> Cast spell / Main Hand Attack), and
    -- stage 2 (~320ms after press) is when ShowDescription flips
    -- to On with TotalHitChance populated, then stage 3 (~360ms)
    -- adjusts to final state (e.g. swaps to a "Not enough movement"
    -- warning).  The quiet zone between stages 1 and 2 is ~200ms,
    -- so STABILITY_MS must be larger than that to avoid firing
    -- mid-pipeline.  250ms catches the full evolution while keeping
    -- the total speech delay around 600-650ms post-press.  For
    -- friendly / movement-only targets where stage 2 never fires,
    -- the 250ms wait runs from the camera-advance reset and we
    -- speak around 350-400ms post-press.
    local STABILITY_MS = 250
    local stableForMs = nowMs - pendingPress.lastHashChangeMs
    if stableForMs < STABILITY_MS and not timeoutReached then
        return  -- not stable long enough yet
    end

    -- All gates passed (or timeout fired).  Do the read + speak.
    local readOk, completed = pcall(
        PerformTargetRead, timeoutReached)
    if not readOk then
        Log.Error("TargetSelect tick error: " .. tostring(completed))
        pendingPress = nil
        return
    end

    if completed then
        Log.Info("TARGET READ: completed via tick ("
            .. tostring(elapsedMs) .. "ms after press, camAdv="
            .. tostring(cameraAdvanced)
            .. ", tgtAdv=" .. tostring(currentTargetAdvanced)
            .. ", cursorAdv=" .. tostring(cursorHashAdvanced)
            .. ", timeout=" .. tostring(timeoutReached) .. ")")
        pendingPress = nil
        return
    end

    -- PerformTargetRead returned false (its internal Noesis-vs-camera
    -- identity check failed even after our gates).  This is rare now
    -- that the cursor-info stability gate ran first -- but if it
    -- happens, the natural per-frame cadence retries on the next tick
    -- (or the timeout will eventually force speech).
end

local tickSubscriptionId = nil
local function SubscribeTick()
    if tickSubscriptionId then return end
    tickSubscriptionId = Ext.Events.Tick:Subscribe(function()
        local handleOk, handleErr = pcall(OnTick)
        if not handleOk then
            Log.Error("TargetSelect tick handler error: "
                .. tostring(handleErr))
        end
    end)
    Log.Debug("TargetSelect: tick subscription active")
end

SubscribeTick()

-- ---------------------------------------------------------------------------
-- Input wiring
-- ---------------------------------------------------------------------------

--- Returns true when the D-pad press should trigger a target read.
---
--- Previously gated on Router.IsUIActive(), which internally depends
--- on snapshotHasUIFocus.  The failure mode: HUD elements (cursor
--- hints, target indicators, menu buttons that were just active) take
--- Noesis focus transiently and don't cleanly release it even after
--- the modal they belonged to closes.  The result: the player closes
--- a context menu / Examine panel / etc., returns to combat
--- target-select, and finds d-pad alternately accepts and rejects
--- presses depending on which tick's snapshotHasUIFocus value the
--- input handler observed.  The log shows this cleanly: the CONTEXT
--- MENU: closed line precedes the first gated d-pad, not follows it.
---
--- The correct test for combat target-select is: "is a truly modal
--- UI in front, right now, that owns d-pad for navigation?"  That
--- means:
---   * A pre-game menu / pause menu / save-load / options (Menus
---     handler active -- GetActiveHandler returns non-nil)
---   * Character creation (CC active)
--- Everything else -- context menus (whether open or just closed),
--- Examine overlay (same), radial wheel, HUD cursor hints,
--- transient-focus HUD elements -- does NOT gate.  BG3 still routes
--- d-pad L/R to its target cycle in those states; we must read
--- TargetInfo_c / CursorText_c on every press.
local function ShouldHandleDPad()
    -- BG3Access settings menu owns D-pad while open: cycling combat
    -- targets while the user is configuring would be confusing and
    -- competes with the menu's own announcements.  Checked first so
    -- the gate fires regardless of turn state.
    local SettingsMenu = BG3Access.Client.SettingsMenu
    if SettingsMenu and SettingsMenu.IsOpen and SettingsMenu.IsOpen() then
        return false
    end

    if not IsLocalPlayerTurn() then return false end

    local Menus = BG3Access.Client.Menus
    if Menus and Menus.GetActiveHandler
        and Menus.GetActiveHandler() then
        return false
    end

    local CC = BG3Access.Client.CC
    if CC and CC.IsInCC and CC.IsInCC() then
        return false
    end

    -- GPS routing entity list owns D-pad for category/item navigation
    -- (handled by WorldNav).  TargetSelect must not accept the press
    -- in parallel: the engine doesn't actually advance the camera
    -- target while the list is open, so the pending press times out
    -- 925ms later and falls back to identity-only speech, leaking
    -- "Tav. HP: 6 of 10" into the middle of list navigation.
    local Nav = BG3Access.Client.WorldNav
    if Nav and Nav.IsEntityListOpen and Nav.IsEntityListOpen() then
        return false
    end

    -- WorldUI panels (Container, Examine, SpellBook, ActiveRoll, etc.)
    -- own D-pad while open: BG3 routes up/down for item browsing,
    -- left/right for tab cycling, A for select.  TargetSelect must
    -- step aside or it races with the panel and reads stale camera
    -- info ("Container: Empty" while the user expected the loot list
    -- to focus an item).
    --
    -- PartyLine is one exception: PartyLine_c is the always-visible
    -- HUD portrait row that activates the handler from snapshot-
    -- discovery without representing an actual interactive panel.
    -- PartyLineActive_c (the LT-opened expanded party panel) ALSO
    -- maps to PartyLineHandler, so the LT-held edge case isn't
    -- distinguishable here -- accept the false negative; LT is rarely
    -- held during target select.
    --
    -- SelectionFlyOut is the second exception: gui::DCActiveSearch /
    -- gui::DCSelectionFlyOut backs both the combat-start target-picker
    -- flyout AND the X-button context menu.  The widget often persists
    -- (same Noesis address reused) after the context menu closes, but
    -- BG3 never fires a widgetRemoved event -- only a C++-side
    -- "context menu closed" log.  Result: panelHandler stays pinned
    -- to SelectionFlyOut indefinitely after a context-menu interaction,
    -- and TargetSelect is gated for the rest of combat (or until
    -- another panel takes the slot).  Letting D-pad pass through
    -- restores combat-target cycling; in the rare case the flyout is
    -- genuinely visible, BG3 uses LB/RB and stick for navigation
    -- inside it, not D-pad, so the pass-through doesn't conflict.
    local World = BG3Access.Client.WorldUI
    if World and World.GetActivePanelHandler then
        local panelHandler = World.GetActivePanelHandler()
        if panelHandler and panelHandler.name
            and panelHandler.name ~= "PartyLine"
            and panelHandler.name ~= "SelectionFlyOut" then
            return false
        end
    end

    return true
end

local function OnButtonInput(event)
    if not event.Pressed then return end
    local buttonName = tostring(event.Button)
    -- A-press: confirm the cast.  If the most recent target read
    -- recorded a rejection (out-of-range, can't target self, etc.),
    -- the game will silently refuse the press -- so we interrupt
    -- and speak the reason.  Only fires when we KNOW about a
    -- rejection; valid casts stay silent on A and let the existing
    -- HitResultEvent path announce the outcome.  Same gate as DPad
    -- (combat + local turn + no menu/CC) so we don't speak in
    -- contexts where A means something other than "cast".
    if buttonName == "ButtonA" then
        if lastRejectionText and ShouldHandleDPad() then
            SpeechData.Alert(lastRejectionText, "interrupt")
        end
        return
    end
    if buttonName ~= "DPadLeft" and buttonName ~= "DPadRight" then
        return
    end
    if not ShouldHandleDPad() then
        local Combat = BG3Access.Client.Combat
        local inCombat = Combat and Combat.IsInCombat
            and Combat.IsInCombat() or false
        local Menus = BG3Access.Client.Menus
        local menuHandler = Menus and Menus.GetActiveHandler
            and Menus.GetActiveHandler()
        local menuName = menuHandler and menuHandler.name or "nil"
        local CC = BG3Access.Client.CC
        local inCC = CC and CC.IsInCC and CC.IsInCC() or false
        Log.Info("TARGET BUTTON " .. buttonName
            .. ": gated (inCombat=" .. tostring(inCombat)
            .. " turnAllowsTargeting=" .. tostring(IsLocalPlayerTurn())
            .. " menu=" .. menuName
            .. " inCC=" .. tostring(inCC)
            .. ")")
        return
    end
    -- Snapshot the camera target UUID NOW, before BG3's game thread
    -- has had a chance to process this D-pad event.  The per-tick
    -- handler (OnTick) waits for the live camera UUID to diverge
    -- from this snapshot -- the only reliable signal that the engine
    -- has actually advanced the cursor.  No timer involved; the next
    -- render frame triggers the check.
    local prePressCameraUuid = SnapshotCameraTargetUuid()
    Log.Info("TARGET BUTTON " .. buttonName
        .. ": accepted, marking pending (pre-press camera="
        .. tostring(prePressCameraUuid) .. ")")
    MarkPendingPress(prePressCameraUuid)
end

--- Subscribe to controller input.  Idempotent -- safe to call from
--- GameStateChanged on every transition.
local function Subscribe()
    if buttonSubscription then return end
    buttonSubscription = Ext.Events.ControllerButtonInput:Subscribe(
        function(event)
            local handleOk, handleErr = pcall(OnButtonInput, event)
            if not handleOk then
                Log.Error("TargetSelect input error: "
                    .. tostring(handleErr))
            end
        end)
    Log.Debug("TargetSelect: controller button subscription active")
end

Subscribe()

-- ---------------------------------------------------------------------------
-- Effects view (RS Left in combat target select)
-- ---------------------------------------------------------------------------
--
-- Enumerates active statuses on the currently targeted character
-- and exposes them through the Detail View's handler contract
-- (BuildDetailList + GetLastFocusedData).  When RS Left fires in a
-- combat target-select context, EventRouter resolves to this
-- handler and opens the detail view showing each status's name,
-- effect description, and remaining duration.
--
-- Component paths verified against
-- `BG3Extender\GameDefinitions\Components\Status.h:5-10`:
--   entity.StatusContainer.Statuses     -- HashMap<EntityHandle, FixedString>
-- and `Prototype.h:144-170` / DescriptionInfo for display name +
-- description.
--
-- TranslatedStrings must be resolved explicitly via
-- Ext.Loca.GetTranslatedString(handle).  tostring() on a
-- TranslatedString returns the userdata repr
-- ("TranslatedString (0x...)"), NOT the localized text.
--
-- Duration: `StatusLifetime.Lifetime` exists as a float, but its
-- unit is not documented in the header (could be seconds, turns,
-- or engine ticks -- the field name doesn't say and the codebase
-- has no conversion constant).  We include the raw value in the
-- diagnostic log so the user can confirm units empirically; we
-- DO NOT speak a converted duration until we've verified against
-- in-game values.  Better silence than a misleading number.

-- Uses Helpers.ResolveTranslatedString for TranslatedString -> text
-- resolution (handles string, userdata, and table variants; already
-- used throughout the codebase for the same pattern).

--- Enumerate active statuses on an entity.  Returns a list of
--- {statusId, name, description, rawLifetime} entries, or an empty
--- list on any access failure.  rawLifetime is the unconverted
--- Lifetime float (or nil when absent / permanent).
--- Bound as an ASSIGNMENT (no `local` keyword) so it binds to the
--- forward-declared local near the top of the file -- otherwise
--- `local function` here would shadow with a new local, and
--- `function EnumerateStatuses(...)` without `local` would create
--- a global.  PerformTargetRead (defined earlier) calls through
--- the forward-declared local to reach this body.
EnumerateStatuses = function(characterEntity)
    if not characterEntity then return {} end
    local readOk, result = pcall(function()
        local container = characterEntity.StatusContainer
        if not container or not container.Statuses then
            return {}
        end
        local collected = {}
        for statusEntityHandle, statusId in pairs(container.Statuses) do
            local proto = Ext.Stats.GetCachedStatus(
                tostring(statusId))
            -- Default to the status id (e.g., "BURNING") if no
            -- display name resolves.  Better than saying the raw
            -- TranslatedString userdata repr.
            local displayName = tostring(statusId)
            local description = ""
            if proto and proto.Description then
                local descInfo = proto.Description
                local resolvedName = Helpers.ResolveTranslatedString(
                    descInfo.DisplayName)
                if resolvedName and resolvedName ~= "" then
                    displayName = resolvedName
                end
                -- DescriptionInfo has five TranslatedString fields
                -- (Prototype.h:10-21).  Different statuses populate
                -- different ones -- some only have ShortDescription
                -- for the hover tooltip, others put the tooltip in
                -- Description and leave ShortDescription empty, and
                -- tutorial / story statuses may have no real text
                -- in any of them.  Try each in the typical priority
                -- order used by sighted tooltips, stop at first
                -- non-empty resolution.
                --
                -- Parameterized descriptions: most BG3 status
                -- descriptions contain [1] / [2] placeholders
                -- (e.g. "Takes [1] per turn") that resolve via
                -- Helpers.ResolveDescriptionParams using the
                -- corresponding Params field.  Skip that step and
                -- the user hears "Takes [1] per turn" literally.
                local descFieldsInOrder = {
                    {field = "Description",
                     params = "DescriptionParams"},
                    {field = "ShortDescription",
                     params = "ShortDescriptionParams"},
                    {field = "ExtraDescription",
                     params = "ExtraDescriptionParams"},
                    -- LoreDescription has no corresponding Params
                    -- field in the header; pass nil so it's skipped.
                    {field = "LoreDescription", params = nil},
                }
                for _, entry in ipairs(descFieldsInOrder) do
                    local candidate = Helpers.ResolveTranslatedString(
                        descInfo[entry.field])
                    if candidate and candidate ~= "" then
                        local paramsString = nil
                        if entry.params then
                            local paramsOk, paramsValue = pcall(
                                function()
                                    return descInfo[entry.params]
                                end)
                            if paramsOk
                                and type(paramsValue) == "string"
                                and paramsValue ~= "" then
                                paramsString = paramsValue
                            end
                        end
                        description =
                            Helpers.ResolveDescriptionParams(
                                candidate, proto, paramsString)
                            or candidate
                        break
                    end
                end
            end

            -- Raw lifetime for diagnostic logging; NOT converted
            -- to turns / seconds / anything until we verify units.
            local rawLifetime = nil
            local statusEntity = Ext.Entity.Get(statusEntityHandle)
            if statusEntity and statusEntity.StatusLifetime then
                rawLifetime = tonumber(
                    statusEntity.StatusLifetime.Lifetime)
            end

            collected[#collected + 1] = {
                statusId = tostring(statusId),
                name = displayName,
                description = description,
                rawLifetime = rawLifetime,
            }
        end
        -- Stable alphabetical order so the detail view doesn't
        -- reorder between reads.
        table.sort(collected, function(a, b)
            return (a.name or "") < (b.name or "")
        end)
        return collected
    end)
    if readOk and result then return result end
    return {}
end

--- BuildDetailList for the effects view.  `focusedData` is the
--- target entity (from GetLastFocusedData).  Returns a list of
--- {label, value} entries matching the Detail View contract:
---   label = status name
---   value = description
---
--- Duration deliberately omitted pending unit verification --
--- StatusLifetime.Lifetime's unit isn't documented in the header
--- and I won't speak a guess.  The raw lifetime is logged below
--- so the user can observe it in-game and tell us what the real
--- unit is (if "2.0" corresponds to "2 turns", it's turns; if
--- "12.0" corresponds to "2 turns", it's seconds at 6/turn; etc.).
local function BuildEffectsDetailList(focusedData, _tooltipTexts)
    local targetEntity = focusedData and focusedData.entity
    if not targetEntity then return {} end
    local statuses = EnumerateStatuses(targetEntity)
    if #statuses == 0 then return {} end

    -- Diagnostic: log raw lifetime values so we can figure out
    -- what unit Lifetime is actually in.  Remove once verified.
    for _, statusInfo in ipairs(statuses) do
        Log.Info("EFFECTS: " .. statusInfo.statusId
            .. " name='" .. tostring(statusInfo.name) .. "'"
            .. " rawLifetime=" .. tostring(statusInfo.rawLifetime))
    end

    local detailList = {}
    for _, statusInfo in ipairs(statuses) do
        -- Same display-name filter as FormatStatusesPhrase: skip
        -- statuses with no resolved DisplayName, UNLESS they're in
        -- VISUAL_ONLY_STATUS_NAMES (statuses Larian left unnamed
        -- but ARE visible to sighted players via VFX -- blood
        -- splatter etc.).  For those we substitute our own name
        -- so blind players get the same info.
        local name = statusInfo.name or ""
        local statusId = statusInfo.statusId or ""
        local hasResolvedDisplayName = name ~= ""
            and name ~= statusId
            and name:sub(1, 3) ~= "%%%"
        local effectiveName = nil
        if hasResolvedDisplayName then
            effectiveName = name
        else
            effectiveName = VISUAL_ONLY_STATUS_NAMES[statusId]
        end
        if effectiveName then
            detailList[#detailList + 1] = {
                label = effectiveName,
                value = statusInfo.description or "",
            }
        end
    end
    return detailList
end

--- GetLastFocusedData for the effects view.  Returns {entity,
--- name} for the most recently read target.  Detail View calls
--- this to pass focusedData into BuildDetailList.  Returns nil
--- when there's no current target OR when the cached entity has
--- since been freed -- causes Detail View to fall back to other
--- handlers rather than open an empty/dangerous view.  The
--- entity reference returned here is freshly resolved from the
--- UUID and intended for immediate single-tick use.
local function GetEffectsFocusedData()
    local entity = ResolveTargetEntity()
    if not entity then return nil end
    return {
        entity = entity,
        name = lastTargetName,
    }
end

--- Return a synthetic detail-view handler if there's a current,
--- fresh combat target; nil otherwise.  Gated on:
---   1. A target UUID has been cached (user cycled at least one
---      combat target in this session).
---   2. In-combat (Combat.IsInCombat true).  Effects view is a
---      combat-only feature -- out-of-combat RS-Left should go
---      to whatever panel handler owns the current context
---      (character sheet, inventory, etc.), not this.
---   3. Freshness: last target read within TARGET_STALENESS_MS.
---      If the user hasn't cycled a target recently, they've
---      moved on and stale cached data shouldn't hijack RS-Left.
local function GetActiveDetailHandler()
    if not lastTargetEntityUuid then
        Log.Info("EFFECTS VIEW: handler nil -- no target cached"
            .. " (d-pad to a target first)")
        return nil
    end

    local Combat = BG3Access.Client.Combat
    if not (Combat and Combat.IsInCombat
        and Combat.IsInCombat()) then
        Log.Info("EFFECTS VIEW: handler nil -- not in combat"
            .. " (Combat=" .. tostring(Combat and "ok" or "nil")
            .. " IsInCombat="
            .. tostring(Combat and Combat.IsInCombat
                and Combat.IsInCombat()) .. ")")
        return nil
    end

    local nowMs = Ext.Utils.MonotonicTime()
    local ageMs = nowMs - lastTargetReadAtMs
    if ageMs > TARGET_STALENESS_MS then
        Log.Info("EFFECTS VIEW: handler nil -- target stale ("
            .. tostring(ageMs) .. "ms > "
            .. tostring(TARGET_STALENESS_MS) .. "ms)")
        -- Cached target is stale.  Clear so subsequent calls skip
        -- the in-combat check early and so the state doesn't
        -- re-acquire freshness on its own.
        lastTargetName = nil
        lastTargetEntityUuid = nil
        return nil
    end

    Log.Info("EFFECTS VIEW: handler returned for '"
        .. tostring(lastTargetName) .. "' (age "
        .. tostring(ageMs) .. "ms)")
    return {
        name = "Effects",
        -- DetailView uses this as the opening-announcement title,
        -- so the user hears "Effects view" instead of the generic
        -- "Detail view" that panel handlers get.
        viewLabel = "Effects view",
        BuildDetailList = BuildEffectsDetailList,
        GetLastFocusedData = GetEffectsFocusedData,
    }
end

-- ---------------------------------------------------------------------------
-- Module table
-- ---------------------------------------------------------------------------

BG3Access.Client.TargetSelect = {
    --- Exposed for manual trigger / debugging: reads the current
    --- target info regardless of state gate.
    ReadAndSpeak = PerformTargetRead,
    --- Detail-view handler adapter for the effects view.  Returns
    --- nil when no target is active; EventRouter falls back to
    --- other handlers in that case.
    GetActiveDetailHandler = GetActiveDetailHandler,
    --- Called on GameStateChanged to clear dedup and target cache.
    --- Also called from Combat.lua HandleCombatEnded so the effects
    --- view doesn't serve stale target data the moment combat
    --- concludes.
    ResetState = function()
        lastSpokenAtMs = 0
        handlerState.lastSpokenFullText = nil
        handlerState.spokenRoles = {}
        handlerState.spokenValues = {}
        pendingPress = nil
        lastTargetName = nil
        lastTargetEntityUuid = nil
        lastTargetReadAtMs = 0
        lastRejectionText = nil
    end,

    --- Clear the cached target only if the UUID matches.  Called
    --- from Combat.HandleDied so the cached UUID is dropped at the
    --- moment its entity is being torn down.  Belt-and-braces
    --- defence even with the UUID-only caching pattern: an extra
    --- Ext.Entity.Get call on a freshly-dead UUID is cheap, but
    --- skipping it entirely is cheaper.
    ClearCachedTargetByUuid = function(deadUuid)
        if not deadUuid or not lastTargetEntityUuid then return end
        if tostring(deadUuid) == tostring(lastTargetEntityUuid) then
            Log.Info("TargetSelect: clearing cached target "
                .. "(died: " .. tostring(deadUuid) .. ")")
            lastTargetName = nil
            lastTargetEntityUuid = nil
            lastTargetReadAtMs = 0
        end
    end,
}

Log.Debug("TargetSelect module loaded")
