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

-- Milliseconds to wait between the D-pad press and the widget read.
-- BG3 processes controller input on the game thread, updates the
-- target pointer, fires INPC, and Noesis re-renders the TextBlocks
-- that display the target name/HP/hit-chance.  A 60ms window is
-- enough for a single frame at 30fps and several frames at 60fps
-- while still feeling immediate to the user.  Subsequent rapid
-- presses cancel the pending timer and restart the window, so the
-- screen reader only speaks the latest target after the user stops
-- cycling.
local READ_DEFER_MS = 60

-- x:Name uniquely present in TargetInfo_c's template.  Used as the
-- anchor for locating the widget root -- HPBarContainer is the
-- Control hosting the target health bar and exists nowhere else.
local TARGET_INFO_ANCHOR = "HPBarContainer"

-- x:Name uniquely present in CursorText_c's template.  hitChanceText
-- is the TextBlock showing the percentage to hit; no other widget
-- uses that identifier.
local CURSOR_TEXT_ANCHOR = "hitChanceText"

-- Maximum Parent hops when walking up from an anchor element to the
-- widget root.  Anchors live 4-6 levels deep in the visual tree; 12
-- hops provides comfortable margin without risking an infinite loop
-- if Parent ever returns a cycle.
local MAX_PARENT_HOPS = 12

-- Role -> label mapping for TargetInfo_c TextBlocks.  Keys are the
-- x:Name of the TextBlock (role) from the XAML template.  Values are
-- the user-facing label used in the structured speech output.
--
-- Name            -- target name (bound to CurrentRegularOrCombatTurnTarget.Name)
-- LevelText       -- "Lv. N" (only shown when target is a Character)
-- HealthText      -- current HP number (from TargetHealthBarTemplate)
-- HealthMaxText   -- "/N" max HP (leading slash included by XAML)
-- OverflowText    -- "+N" when more status effects exist than fit inline
local TARGET_INFO_ROLES = {
    Name          = "name",
    LevelText     = "level",
    HealthText    = "hpCurrent",
    HealthMaxText = "hpMax",
    OverflowText  = "extraStatuses",
}

-- Role -> label mapping for CursorText_c TextBlocks.  Same
-- convention as TARGET_INFO_ROLES.  Many of these TextBlocks carry
-- no text unless the underlying ActiveTask condition fires (e.g.
-- ConcentrationWarningText is blank unless the player is holding
-- concentration), so we look up role-by-role and skip empties.
local CURSOR_TEXT_ROLES = {
    hitChanceText                  = "hitChance",
    distance                       = "distance",
    TaskDescription                = "action",
    ConcentrationWarningText       = "concentration",
    highDefText                    = "highDefense",
    ContainerInfo                  = "container",
    UpcastInfo                     = "upcast",
    CapabilityError                = "capabilityError",
    Message                        = "capabilityError",
    Cause                          = "capabilityCause",
    TargetCantBeHealedErrorMessage = "cannotHealMessage",
    TargetCantBeHealedErrorCause   = "cannotHealCause",
    -- CursorTextList VMText items (AoO warning, surface message,
    -- "Not enough movement", etc.).  XAML template's TextBlock has
    -- x:Name="txt" so role comes through as "txt".
    txt                            = "cursorInfo",
    -- Damage-preview block under DamagesProperty StackPanel.  XAML
    -- has a "Damage:" label TextBlock and a values TextBlock.  We
    -- skip the label (redundant with the AddProperty label) and
    -- keep only the values ("4~9" which FromTooltip would have
    -- normalized to "4 to 9" -- we do that ourselves below).
    DamagesPropertyTextValues      = "damage",
    -- Attack-of-opportunity / provoke warning fires under an
    -- "Errors" container per the observed log.
    Errors                         = "actionWarning",
    -- Cooldown / recharge info ("Short Rest", "Long Rest", "Turn")
    -- for limited-use actions.
    CooldownText                   = "cooldown",
    -- Applied condition block.  "Applies: Gaping Wounds for 2
    -- Turn(s)" is split across four TextBlocks (Index / Name /
    -- Value / Type).  We pick up the name; the value/type pair is
    -- assembled into a phrase in the speech builder.
    TurnsConditionName             = "appliesName",
    TurnsValue                     = "appliesTurns",
    TurnsType                      = "appliesTurnsUnit",
    -- SurfaceInfo: name of the surface the cursor target is standing
    -- in or moving onto ("Blood", "Fire", "Ice", "Web", "Grease",
    -- "Water", etc.).  This is the user-facing equivalent of the
    -- engine-only INSURFACE status (which has no DisplayName and is
    -- filtered out of the entity status enumeration).  Sighted
    -- players see the surface name on the cursor panel; we surface
    -- it as a property in the speech so the blind player gets the
    -- same hazard awareness.
    SurfaceInfo                    = "surface",
}

-- Parent role -> label for TextBlocks that carry no x:Name.  Some
-- CursorText_c TextBlocks are bound inside template containers (e.g.
-- AdvantagesList StackPanel) and ReadElementStructuredTextBlocks
-- promotes the parent's x:Name into the role field.
local PARENT_ROLE_TO_LABEL = {
    AdvantagesList    = "advantages",
    DisadvantagesList = "disadvantages",
}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local deferredReadPending = false
local deferredReadCancelKey = 0   -- monotonic; invalidates stale timers
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

--- Is this the local player's combat turn?  Speaking target info
--- on an enemy's turn is wrong -- the player can't cycle targets
--- until their own turn comes up.  We read IsActiveCombatTurn off
--- the local player entity's TurnBased component; no dependency on
--- the Combat module's tracked turn GUID (which can be stale across
--- mid-session reloads or lag between TurnStarted events).
local function IsLocalPlayerTurn()
    local Combat = BG3Access.Client.Combat
    if not Combat or not Combat.IsInCombat or not Combat.IsInCombat() then
        return false
    end
    local playerEntity = FindLocalPlayerEntity()
    if not playerEntity then return false end
    local activeOk, isActive = pcall(function()
        local turnBased = playerEntity.TurnBased
        if not turnBased then return false end
        return turnBased.IsActiveCombatTurn == true
    end)
    return activeOk and isActive == true
end

--- Walk up the parent chain from an anchor element and return the
--- highest in-widget ancestor (the ls:UIWidget, or the Root Grid just
--- below it if we cannot reach the widget itself).
---
--- We MUST stop before leaving the widget: the application Canvas
--- holds every HUD widget in the game, and passing it to
--- ReadElementStructuredTextBlocks would return every TextBlock on
--- screen.  Two stop conditions:
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

--- Collect all TextBlock entries from a widget.  Returns an array of
--- {role, text, parentRole} tables, or nil on failure.
---
--- Logs each step at Info level so the log shows exactly where the
--- read pipeline breaks when target speech goes silent:
---   1. Did FindNameInWidget locate the anchor?
---   2. Did GetWidgetRoot produce a widget ancestor?
---   3. How many TextBlock entries did the structured reader produce?
---   4. What roles and texts did those entries carry?
local function ReadWidgetEntries(widgetLabel, anchorName)
    local findOk, anchor = pcall(Ext.UI.FindNameInWidget, anchorName)
    if not findOk or not anchor then
        Log.Info("TARGET READ " .. widgetLabel
            .. ": anchor '" .. anchorName .. "' NOT FOUND"
            .. " (findOk=" .. tostring(findOk) .. ")")
        return nil
    end

    local widgetRoot = GetWidgetRoot(anchor)
    if not widgetRoot then
        Log.Info("TARGET READ " .. widgetLabel
            .. ": GetWidgetRoot returned nil for anchor '"
            .. anchorName .. "'")
        return nil
    end

    Log.Info("TARGET READ " .. widgetLabel
        .. ": anchor '" .. anchorName .. "' found"
        .. ", widget root type=" .. SafeTypeName(widgetRoot))

    local readOk, entries = pcall(
        Ext.UI.ReadElementStructuredTextBlocks, widgetRoot)
    if not readOk then
        Log.Info("TARGET READ " .. widgetLabel
            .. ": ReadElementStructuredTextBlocks FAILED: "
            .. tostring(entries))
        return nil
    end
    if not entries then
        Log.Info("TARGET READ " .. widgetLabel
            .. ": ReadElementStructuredTextBlocks returned nil")
        return nil
    end

    -- Log entry count and a summary of every entry so the log shows
    -- exactly what the structured reader extracted.  Cap detailed
    -- entry dump at 25 to keep the log manageable in degenerate
    -- cases (long status lists, many capability errors, etc.).
    Log.Info("TARGET READ " .. widgetLabel
        .. ": " .. tostring(#entries) .. " entries")
    local dumpLimit = 25
    local dumpCount = math.min(#entries, dumpLimit)
    for i = 1, dumpCount do
        local entry = entries[i]
        local role = entry.role or "(no role)"
        local parentRole = entry.parentRole or ""
        local text = entry.text or ""
        -- Truncate very long texts for log readability.
        if #text > 80 then
            text = text:sub(1, 77) .. "..."
        end
        Log.Info("  [" .. i .. "] role='" .. role
            .. "' parentRole='" .. parentRole
            .. "' text='" .. text .. "'")
    end
    if #entries > dumpLimit then
        Log.Info("  ... " .. tostring(#entries - dumpLimit)
            .. " more entries not logged")
    end

    return entries
end

--- Classify entries into a map of {label = text}.  Iterates the
--- raw entry list and assigns the first valid text seen for each
--- mapped role.  Subsequent duplicates are skipped.  The XAML may
--- render the same TextBlock twice (e.g. StatusHolderHolderHidden
--- mirrors StatusHolderHolder for width calculations); we want
--- only the first.
---
--- captureUnlabeledAsReason:  when true, any TextBlock with empty
--- role AND empty parentRole is captured into classified.reasonText
--- (joined with ". " if multiple).  This is how short context
--- strings surface for action reasons ("Target is too close", "Not
--- enough movement in the target area").
---
--- Reason filtering:
--- - bare digit text ("1") is the unlabeled Duration badge from
---   NamedStatusTemplate (DataTemplates_c.xaml line 341); we already
---   speak that authoritatively from the entity, so drop here.
--- - 1-2 char tokens ("/", "-") are XAML separators between reason
---   phrases; not speakable on their own.
--- - text that exactly duplicates a statusLabel role's text in the
---   same entry list is the HitChanceDesc explainer echoing the
---   status name (e.g. "Threatened" appears as both statusLabel and
---   as an unlabeled Run); skip the echo since we'll speak statuses
---   via the entity-side enumeration.
local function ClassifyEntries(
    entries, roleMap, parentRoleMap, captureUnlabeledAsReason)
    local classified = {}
    if not entries then return classified end
    -- First pass: collect statusLabel texts so we can dedupe their
    -- echoes from the unlabeled-reason bucket.
    local statusLabelTexts = {}
    if captureUnlabeledAsReason then
        for _, entry in ipairs(entries) do
            if (entry.role or "") == "statusLabel" then
                local cleaned = NormalizeText(entry.text or "")
                if cleaned ~= "" then
                    statusLabelTexts[cleaned] = true
                end
            end
        end
    end
    local unclassifiedReasons = {}
    for _, entry in ipairs(entries) do
        local role = entry.role or ""
        local text = entry.text or ""
        if IsValidText(text) then
            local label = roleMap[role]
            if not label and parentRoleMap then
                label = parentRoleMap[entry.parentRole or ""]
            end
            if label and not classified[label] then
                classified[label] = NormalizeText(text)
            elseif captureUnlabeledAsReason
                and not label and role == ""
                and (entry.parentRole or "") == "" then
                local cleaned = NormalizeText(text)
                local isBareNumber = cleaned:match("^%d+$") ~= nil
                local isSeparator = #cleaned <= 2
                local isStatusEcho = statusLabelTexts[cleaned] == true
                if not isBareNumber
                    and not isSeparator
                    and not isStatusEcho then
                    unclassifiedReasons[#unclassifiedReasons + 1] =
                        cleaned
                end
            end
        end
    end
    if #unclassifiedReasons > 0 then
        classified.reasonText = table.concat(
            unclassifiedReasons, ". ")
    end
    return classified
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
--- " of level 2").  Our ClassifyEntries captures each Run separately
--- under distinct roles.  Stitch them back together for the property
--- value so the screen reader speaks one coherent sentence.
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
local function FormatStatusesPhrase(statuses)
    if not statuses or #statuses == 0 then return nil end
    local parts = {}
    for _, entry in ipairs(statuses) do
        local name = entry.name or ""
        local statusId = entry.statusId or ""
        -- Resolved DisplayName means the entry.name differs from
        -- the raw status id.  When they match, the prototype had no
        -- resolvable DisplayName -- treat as internal/hidden.
        local hasResolvedDisplayName = name ~= ""
            and name ~= statusId
        if hasResolvedDisplayName then
            local turns = LifetimeToTurns(entry.rawLifetime)
            if turns then
                local unit = (turns == 1) and "turn" or "turns"
                parts[#parts + 1] = name .. " "
                    .. tostring(turns) .. " " .. unit
            else
                parts[#parts + 1] = name
            end
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

local function BuildTargetSpeechData(
    targetInfo, cursorInfo, statuses)
    local speechData = SpeechData.Create()

    -- Preview action: "status" fits because the architecture spec
    -- describes it as transient state info (like "Your turn",
    -- "Round 3").  "Attack", "Throw", "Move to" are the same kind
    -- of transient cursor state.
    if cursorInfo.action then
        speechData:Add("status", cursorInfo.action, "brief")
    end

    -- Target identity.  The target name is the focused entity, which
    -- maps to the core "name" field.
    if targetInfo.name then
        speechData:Add("name", targetInfo.name, "brief")
    end

    -- Level: flexible property so the formatter emits "Level: 3".
    local levelValue = StripLevelPrefix(targetInfo.level)
    if levelValue and levelValue ~= "" then
        speechData:AddProperty("Level", levelValue, "brief")
    end

    -- HP: "10 of 15" from HealthText + HealthMaxText.  HealthMaxText
    -- carries a leading slash from the XAML ("/15"); strip it and
    -- combine as "N of M" for natural TTS.  Brief tier -- the player
    -- needs this to decide whether one more attack will finish the
    -- target.
    if targetInfo.hpCurrent and targetInfo.hpCurrent ~= "" then
        local maxClean = targetInfo.hpMax
            and targetInfo.hpMax:gsub("^/%s*", "") or ""
        local hpPhrase = targetInfo.hpCurrent
        if maxClean ~= "" then
            hpPhrase = hpPhrase .. " of " .. maxClean
        end
        speechData:AddProperty("HP", hpPhrase, "brief")
    end

    -- Combat-critical pair: hit chance + distance.  Already
    -- normalized to spoken form ("65 percent", "8 meters").
    if cursorInfo.hitChance then
        speechData:AddProperty(
            "Hit chance", cursorInfo.hitChance, "brief")
    end
    if cursorInfo.distance then
        speechData:AddProperty(
            "Distance", cursorInfo.distance, "brief")
    end

    -- Damage preview.  XAML value often comes through as "4~9"
    -- (dice range); rewrite to "4 to 9" for TTS pronounceability.
    if cursorInfo.damage and cursorInfo.damage ~= "" then
        local damagePhrase = cursorInfo.damage
            :gsub("(%d+)%s*~%s*(%d+)", "%1 to %2")
        speechData:AddProperty("Damage", damagePhrase, "brief")
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

    -- Roll modifiers.  XAML collapses both Advantage and Disadvantage
    -- rows when both are populated (they cancel on the d20), so at
    -- most one fires.  The TextBlock text is the literal word
    -- ("Advantage" / "Disadvantage").  AddProperty produces
    -- "Roll: Disadvantage".
    local rollValue = nil
    if cursorInfo.advantages then
        rollValue = cursorInfo.advantages
    elseif cursorInfo.disadvantages then
        rollValue = cursorInfo.disadvantages
    end
    if rollValue then
        speechData:AddProperty("Roll", rollValue, "brief")
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

    -- Capability errors (cannot cast here, missing resources) and
    -- cannot-heal errors.  Message + cause are separate XAML Runs;
    -- stitch them into one value so the property speaks as a
    -- single sentence.
    local capabilityError = CombineMessageAndCause(
        cursorInfo.capabilityError, cursorInfo.capabilityCause)
    if capabilityError then
        speechData:AddProperty("Cannot", capabilityError, "normal")
    end
    local cannotHealError = CombineMessageAndCause(
        cursorInfo.cannotHealMessage, cursorInfo.cannotHealCause)
    if cannotHealError then
        speechData:AddProperty("Cannot", cannotHealError, "normal")
    end

    -- Container state for Move To over a chest/barrel.  Verbose
    -- tier: the information is ambient, not central to target
    -- choice.
    if cursorInfo.container then
        speechData:AddProperty(
            "Container", cursorInfo.container, "verbose")
    end

    -- Extra TextBlocks from CursorTextList ItemsControl (role="txt"):
    -- attack-of-opportunity warnings, surface messages, etc.
    -- These are secondary text that elaborates the current task;
    -- "additionalDescription" is the core field for "also applies"
    -- kinds of elaboration.
    if cursorInfo.cursorInfo then
        speechData:Add(
            "additionalDescription", cursorInfo.cursorInfo, "normal")
    end

    -- Active status effects with turn counts, read from the target
    -- entity (authoritative) rather than from TargetInfo_c's XAML.
    -- The widget renders each status badge with a statusLabel
    -- TextBlock (status name) and a separate unlabeled TextBlock
    -- (turns-remaining "Duration"), but BFS interleaves across
    -- multiple badges so positional pairing is unreliable.  Reading
    -- entity.StatusContainer + entity.StatusLifetime gives us the
    -- same information the sighted player sees, paired correctly.
    local statusesPhrase = FormatStatusesPhrase(statuses)
    if statusesPhrase then
        speechData:AddProperty("Statuses", statusesPhrase, "normal")
    end

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

--- Dump a classified {label -> text} table to the log so we can see
--- which roles survived the validity filter and which were dropped
--- or not found.
local function LogClassified(label, classified)
    if not classified or next(classified) == nil then
        Log.Info("CLASSIFIED " .. label .. ": (empty)")
        return
    end
    local parts = {}
    for key, value in pairs(classified) do
        parts[#parts + 1] = key .. "='" .. tostring(value) .. "'"
    end
    table.sort(parts)
    Log.Info("CLASSIFIED " .. label .. ": " .. table.concat(parts, ", "))
end

--- Perform the actual widget read and speech.  Called after the
--- defer timer fires -- never directly from the input handler.
---
--- Instrumented end-to-end: logs widget read results, classified
--- role maps, composed speech, and every reason we'd skip speaking.
--- When the user reports "d-pad did nothing," the log shows which
--- stage dropped the data.
local function PerformTargetRead()
    Log.Info("TARGET READ: begin")

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
            Log.Info("TARGET READ: turn-order pool ("
                .. tostring(#turnEntries) .. "): "
                .. table.concat(names, ", "))
        else
            Log.Info("TARGET READ: turn-order pool = (empty)")
        end
    end

    local targetEntries = ReadWidgetEntries(
        "TargetInfo_c", TARGET_INFO_ANCHOR)
    local cursorEntries = ReadWidgetEntries(
        "CursorText_c", CURSOR_TEXT_ANCHOR)

    -- BOTH widgets capture unlabeled Runs as reasonText.  Reason
    -- text (e.g. "Target is too close", "Not enough movement in the
    -- target area", "Can't reach destination") can surface in
    -- either TargetInfo_c (HitChanceDesc explainer) or CursorText_c
    -- (txt items / TaskDescription siblings) depending on what the
    -- game decided to render.  ClassifyEntries already filters the
    -- noise (bare-digit Duration badges from NamedStatusTemplate,
    -- 1-2 char XAML separators, statusLabel echoes).
    local targetInfo = ClassifyEntries(
        targetEntries, TARGET_INFO_ROLES, nil, true)
    local cursorInfo = ClassifyEntries(
        cursorEntries, CURSOR_TEXT_ROLES,
        PARENT_ROLE_TO_LABEL, true)

    -- Resolve target name to an entity handle by scanning the
    -- turn-order pool.  The widget gives us a display name but not
    -- a stable identifier, and the name can be ambiguous for generic
    -- enemy types ("Intellect Devourer" appearing twice).  For the
    -- common case where names are unique we pick the first match;
    -- for duplicates we fall through to the first match which is
    -- acceptable for the effects view (both instances typically
    -- share statuses in the same encounter).
    --
    -- We cache only the UUID string (a stable identifier).  The
    -- entity userdata pointer in entry.entity is fresh THIS tick
    -- but we must not store it -- holding it across ticks risks
    -- dereferencing a freed ECS record.  ResolveTargetEntity()
    -- below re-resolves from the UUID on each use via
    -- Ext.Entity.Get (returns nil cleanly for dead/missing
    -- entities).
    lastTargetName = targetInfo.name
    lastTargetEntityUuid = nil
    if targetInfo.name and targetInfo.name ~= ""
        and Combat and Combat.ReadTurnOrder then
        local turnEntries = Combat.ReadTurnOrder()
        if turnEntries then
            for _, entry in ipairs(turnEntries) do
                if entry.name == targetInfo.name and entry.entity then
                    pcall(function()
                        if entry.entity.Uuid
                            and entry.entity.Uuid.EntityUuid then
                            lastTargetEntityUuid = tostring(
                                entry.entity.Uuid.EntityUuid)
                        end
                    end)
                    break
                end
            end
        end
    end
    -- Record freshness timestamp so the effects view can decide
    -- whether the cached target is still current.  Set even when
    -- entity resolution fails so the "target selected but not
    -- resolved" case also ages out.
    lastTargetReadAtMs = Ext.Utils.MonotonicTime()

    LogClassified("TargetInfo_c", targetInfo)
    LogClassified("CursorText_c", cursorInfo)

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
        Log.Info("TARGET READ: entity statuses ("
            .. tostring(#entityStatuses) .. ")")
        for _, statusEntry in ipairs(entityStatuses) do
            Log.Info("  status: id='"
                .. tostring(statusEntry.statusId) .. "' name='"
                .. tostring(statusEntry.name) .. "' lifetime="
                .. tostring(statusEntry.rawLifetime))
        end
    end

    local speechData = BuildTargetSpeechData(
        targetInfo, cursorInfo, entityStatuses)
    if not speechData then
        Log.Info("TARGET READ: no speakable data (widgets produced"
            .. " no classifiable entries)")
        return
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
        return
    end
    lastSpokenAtMs = nowMs

    -- :Speak with isScreenEntry=true + userInitiated=true -> the
    -- SpeechData formatter interrupts current speech (the user just
    -- pressed d-pad; they want to hear the new target immediately).
    -- It also records handlerState.spokenRoles / lastSpokenFullText
    -- so subsequent tooltip / INPC events can cross-off what we said.
    speechData:Speak(handlerState, true, nil, true)
end

--- Schedule a deferred target read.  Cancels any previously-pending
--- read by invalidating its cancel key, so rapid presses coalesce
--- into a single read of the final state.
local function ScheduleTargetRead()
    deferredReadPending = true
    deferredReadCancelKey = deferredReadCancelKey + 1
    local myCancelKey = deferredReadCancelKey
    Ext.Timer.WaitFor(READ_DEFER_MS, function()
        if myCancelKey ~= deferredReadCancelKey then
            -- A newer press came in and scheduled its own read.
            -- Drop this one.
            return
        end
        deferredReadPending = false
        local readOk, readErr = pcall(PerformTargetRead)
        if not readOk then
            Log.Error("TargetSelect read error: " .. tostring(readErr))
        end
    end)
end

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

    return true
end

local function OnButtonInput(event)
    if not event.Pressed then return end
    local buttonName = tostring(event.Button)
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
            .. " localPlayerTurn=" .. tostring(IsLocalPlayerTurn())
            .. " menu=" .. menuName
            .. " inCC=" .. tostring(inCC)
            .. ")")
        return
    end
    Log.Info("TARGET BUTTON " .. buttonName
        .. ": accepted, scheduling read in "
        .. tostring(READ_DEFER_MS) .. "ms")
    ScheduleTargetRead()
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
        detailList[#detailList + 1] = {
            label = statusInfo.name,
            value = statusInfo.description or "",
        }
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
        deferredReadCancelKey = deferredReadCancelKey + 1
        deferredReadPending = false
        lastTargetName = nil
        lastTargetEntityUuid = nil
        lastTargetReadAtMs = 0
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
