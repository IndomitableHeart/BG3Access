-- File: Client/WorldUI.lua
--
-- In-game UI panel handler (gameplay screens, not pre-game menus).
--
-- Handles UI elements that appear during gameplay:
-- - RT shortcuts radial (character sheet, spell book, journal, etc.)
-- - RB action radial (hotbar actions, spells, passives)
-- - In-game panels: inventory, trade, journal, alchemy, examine, etc.
--
-- Panel handlers use the same factory pattern as Menus.lua
-- (CreatePanelHandler), with isolated state and a generic pipeline
-- that speaks DC properties via FormatDCTextSplit.
--
-- The EventRouter detects panel widget events and delegates here.
-- Spatial navigation/exploration lives in WorldNav.lua.
-- C++ provides the radial slot data (title, description, tag) via
-- TickSnapshot.radialSlotChanged.
--
-- HotBar slots (RB action radial): C++ passes VMHotBarSlot Content
-- sub-object properties as radialSlotTag ("key1=val1;key2=val2;...").
-- XAML binds descriptions to Content.ShortDescription (spells/actions)
-- and Content.Description (passives fallback).  If those resolve to
-- LocaString handles, Lua falls back to Ext.Stats API lookups.

local Log = BG3Access.Client.Log
local Helpers    = BG3Access.Client.Helpers
local SpeechData = BG3Access.Client.SpeechData
local Cutscene   = BG3Access.Client.Cutscene
local CharSheet  = BG3Access.Client.CharSheet
local SpellBook  = BG3Access.Client.SpellBook

-- ============================================================================
-- Constants
-- ============================================================================

-- Spoken once when the action radial first opens (first slot event after reset).
local RADIAL_HINT = "A to select. X to customize."
    .. " Right stick to inspect. B to close."
    .. " LB and RB switch between rings"

-- Default hint for panel handlers (false = no hint by default).
-- Individual handlers override with specific hints.
local DEFAULT_PANEL_HINT = false

-- ============================================================================
-- Tooltip state (above radial because radial open/close sets suppression)
-- ============================================================================

local tooltipSuppressed      = false  -- handlers set true to suppress speech
local tooltipEnabled         = true   -- future settings toggle
-- Dedup state for radial fallback tooltip path.  Its .lastTooltipSpeech
-- field holds the last spoken tooltip string for subset / superset
-- collapsing across tooltip waves.  Mutated by DispatchTooltip fallback.
local tooltipState           = {lastTooltipSpeech = nil}
local lastSpokenRadialTitle  = nil    -- title filter: prevent tooltip re-speaking title (inspect pipeline)
local lastRawTooltipTexts    = nil    -- full raw texts for inspect readback
local lastRadialSpeechData   = nil    -- SpeechData from radial slot speech (for tooltip diff)

-- Forward declarations: panel handler state needed by DispatchTooltip.
-- These are set by HandlePanelWidgetAdded / RoutePanelSnapshot (defined later).
local activePanelHandler     = nil
local lastFocusedDCType      = nil

--- SetTooltipSuppressed: called by handlers that speak their own
--- descriptions (radial, future settings menu, etc.).
local function SetTooltipSuppressed(suppressed)
    tooltipSuppressed = suppressed
end

--- SetTooltipEnabled: future settings toggle.
local function SetTooltipEnabled(enabled)
    tooltipEnabled = enabled
end

-- ============================================================================
-- Detail view: shared module (Client/DetailView.lua).
-- Trigger + handler lookup live in EventRouter so any menu/panel can
-- use it.  WorldUI exposes the tooltip cache (source of truth for
-- item facts) via GetLastTooltipTexts, and the close hook for state
-- reset.  Nothing here calls DetailView.Toggle directly.
local DetailView = BG3Access.Client.DetailView

--- GetLastTooltipTexts: exposes the tooltip cache populated by
--- DispatchTooltip.  EventRouter owns the detail-view trigger and
--- fetches this to pass along when opening DetailView.Toggle, since
--- the builders use the tooltip as source of truth for item facts.
local function GetLastTooltipTexts()
    return lastRawTooltipTexts
end

local function CloseDetailView(silent)
    DetailView.Close(silent)
end

--- CloseCompareView: close the compare grid (if open) so its d-pad
--- input subscription doesn't persist after the panel deactivates.
--- Called on active-handler change, overlay takeover, and module reset.
local function CloseCompareView(silent)
    local CompareView = BG3Access.Client.CompareView
    if CompareView and CompareView.IsOpen() then
        CompareView.Close(silent)
    end
end

-- ============================================================================
-- Radial state
-- ============================================================================

-- Hint spoken once per radial session (reset on GameStateChanged).
local radialHintSpoken = false
-- Tracks whether the radial is currently open (to distinguish fresh
-- opens from LB/RB page switches within the radial).
local inRadial = false

-- ============================================================================
-- Tag parsing
-- ============================================================================

--- ParseTagProps: parse "key1=val1;key2=val2;..." into a table.
--- @param tagString string  Serialized properties from C++.
--- @return table  {key = value, ...}
local function ParseTagProps(tagString)
    local props = {}
    if not tagString or tagString == "" then return props end
    for pair in tagString:gmatch("[^;]+") do
        local key, value = pair:match("^([^=]+)=(.*)$")
        if key then
            props[key] = value
        end
    end
    return props
end

--- IsValidText: check if a string is usable text (not empty, not a
--- LocaString handle, not a ForceUpdate placeholder).
local function IsValidText(text)
    if not text or text == "" then return false end
    if text:find("%[ForceUpdate%]") then return false end
    if text:match("^h%x+g") then return false end
    if text:find("s_HandleUnknown") then return false end
    return true
end

-- ============================================================================
-- API-based description lookup for HotBar slots
-- ============================================================================

--- LookupHotBarDescription: resolve description for an action/spell/item.
---
--- Strategy (API-first per CLAUDE.md):
--- ALL paths use SE APIs via Helpers.ReadStatDescription (shared helper).
--- ViewModel props are LAST RESORT fallback.
---
--- Lookup order (all API-based):
--- 1. Ext.Stats.Get(PrototypeID) for spells/actions.
--- 2. Ext.Stats.Get(PassiveName) for passives.
--- 3. Ext.Entity.Get(EntityUUID) -> SpellBook.Spells for linked spells.
--- 4. Ext.Entity.Get(EntityUUID) -> Data.StatsId -> Ext.Stats for items.
--- 5. ViewModel Description prop (last resort fallback).
---
--- @param contentProps table  Parsed Content sub-object properties.
--- @return string|nil  The description text, or nil if not found.
local function LookupHotBarDescription(contentProps)
    -- Stat types that have a Description attribute, per the game's schema:
    -- Public\Shared\Stats\Generated\Structure\Modifiers.txt
    -- Types WITHOUT Description: Armor, Character, CriticalHitTypeData,
    -- Object, Weapon.  Accessing Description on these triggers SE's
    -- __debugbreak in Debug builds, which kills the game without a debugger.
    local STAT_TYPES_WITH_DESCRIPTION = {
        SpellData = true,
        StatusData = true,
        PassiveData = true,
        InterruptData = true,
    }

    -- Helper: try Ext.Stats.Get(id) -> Helpers.ReadStatDescription.
    -- Skips stat types that don't have Description per the game's schema.
    local function TryStatsDescription(statsId, label)
        if not statsId or statsId == "" then return nil end
        Log.Debug("  HotBar API: " .. label .. "=" .. statsId)
        local statsOk, statsData = pcall(Ext.Stats.Get, statsId)
        if statsOk and statsData then
            -- Check the stat's ModifierList (type) before reading Description.
            -- Reading Description on Armor/Character/Object/Weapon/CriticalHitTypeData
            -- triggers __debugbreak in SE Debug builds.
            local typeOk, statType = pcall(function()
                return statsData.ModifierList
            end)
            if typeOk and statType and not STAT_TYPES_WITH_DESCRIPTION[statType] then
                Log.Debug("  HotBar API: " .. label .. " stat type="
                    .. tostring(statType) .. " (no Description attribute, skipping)")
                return nil
            end
            local resolved = Helpers.ReadStatDescription(statsData)
            if resolved and resolved ~= "" then
                Log.Debug("  HotBar desc (" .. label .. "): " .. resolved)
                return resolved
            end
        end
        return nil
    end

    -- 1. Spell/action lookup via PrototypeID (most common path).
    local result = TryStatsDescription(contentProps["PrototypeID"], "PrototypeID")
    if result then return result end

    -- 2. Passive lookup via PassiveName.
    result = TryStatsDescription(contentProps["PassiveName"], "PassiveName")
    if result then return result end

    -- 3-4. Entity-based lookup for items.
    --      APIs from D:\API.md:
    --      - Ext.Entity.Get(uuid) (line 182)
    --      - entity.SpellBook.Spells (line 200)
    --      - entity:GetAllComponentNames() (line 799)
    local entityUuid = contentProps["EntityUUID"]
    if entityUuid and entityUuid ~= "" then
        Log.Debug("  HotBar API: EntityUUID=" .. entityUuid)
        local entityOk, entity = pcall(Ext.Entity.Get, entityUuid)
        if entityOk and entity then
            -- 3. SpellBook.Spells: linked spells (scrolls, wands).
            local spellBookOk, spellBook = pcall(function()
                return entity.SpellBook
            end)
            if spellBookOk and spellBook then
                local spellsOk, spells = pcall(function()
                    return spellBook.Spells
                end)
                if spellsOk and spells then
                    for spellIndex = 1, #spells do
                        local entryOk, spellId = pcall(function()
                            local entry = spells[spellIndex]
                            local entryId = entry.Id
                            if entryId then
                                return entryId.OriginatorPrototype
                                    or entryId.Prototype
                            end
                            return nil
                        end)
                        if entryOk and spellId and spellId ~= "" then
                            result = TryStatsDescription(spellId, "SpellBook")
                            if result then return result end
                        end
                    end
                end
            end

            -- 4. Item stats via entity Data component.
            local dataOk, statsId = pcall(function()
                return entity.Data and entity.Data.StatsId
            end)
            if dataOk and statsId and statsId ~= "" then
                result = TryStatsDescription(statsId, "Entity/StatsId")
                if result then return result end
            end

            -- Diagnostic: dump component names if all API paths missed.
            local namesOk, componentNames = pcall(function()
                return entity:GetAllComponentNames()
            end)
            if namesOk and componentNames then
                local nameList = table.concat(componentNames, ", ")
                Log.Debug("  HotBar entity components: " .. nameList)
            end
        end
    end

    -- 5. Last resort: ViewModel Description prop from content data.
    local directDescription = contentProps["Description"]
    if IsValidText(directDescription) then
        Log.Debug("  HotBar desc (ViewModel fallback): " .. directDescription)
        return directDescription
    end

    Log.Debug("  HotBar desc: no match found")
    return nil
end

-- ============================================================================
-- Data gathering (one function collects all data into a result table)
-- ============================================================================

--- GatherRadialSlotData: collect all data for a radial slot event.
--- Returns a structured table with title, description, slotType, etc.
--- Does NOT speak -- that's the caller's job.
---
--- For ShortcutsMenu (RT): title and description come from C++ directly
--- (ActionTitle and Description TextBlocks, localized by XAML DataTriggers).
---
--- For HotBar (RB): title comes from C++. Description is resolved here
--- via SE APIs (API-first: Stats, Entity, then ViewModel fallback).
---
--- @param snapshot table  The full TickSnapshot from C++.
--- @return table|nil  {title, description, slotType, tagProps} or nil if nothing to say.
local function GatherRadialSlotData(snapshot)
    local title = snapshot.radialTitleText
    local slotType = snapshot.radialSlotType or "?"

    if not title or title == "" then
        Log.Debug("RADIAL [" .. slotType .. "]: no title, skipping")
        return nil
    end

    local description = snapshot.radialDescriptionText
    local tagProps = ParseTagProps(snapshot.radialSlotTag)

    -- HotBar slots: resolve description via API.
    if slotType == "HotBar" and not IsValidText(description) then
        description = LookupHotBarDescription(tagProps)
    end

    return {
        title       = title,
        description = description,
        slotType    = slotType,
        tagProps    = tagProps,
    }
end

-- ============================================================================
-- Speech output (decides what and how to speak from gathered data)
-- ============================================================================

--- SpeakRadialSlot: speak the slot title and API description.
--- Combat stats (dice, range, cost) come from the C++ tooltip scanner
--- which reads them from the popup TextBlocks -- no Lua API duplication.
--- Builds SpeechData so the tooltip handler can diff against it.
--- @param slotData table  From GatherRadialSlotData.
local function SpeakRadialSlot(slotData)
    local cleanTitle = Helpers.StripMarkupTags(slotData.title)

    -- Build SpeechData for tooltip diff.
    local speechData = SpeechData.Create()
    speechData:Add("title", cleanTitle, "brief")

    -- Track title for inspect panel filtering (separate pipeline).
    lastSpokenRadialTitle = cleanTitle
    tooltipState.lastTooltipSpeech = nil

    -- API-sourced description (spell/passive flavor text not shown in tooltip).
    if slotData.description and slotData.description ~= "" then
        local cleanedDescription = Helpers.StripMarkupTags(slotData.description)
        if cleanedDescription:sub(-1) == "." then
            cleanedDescription = cleanedDescription:sub(1, -2)
        end
        speechData:Add("description", cleanedDescription, "normal")
    end

    -- HotBar item extras from tag props (gold value, stack count).
    if slotData.tagProps and slotData.slotType == "HotBar" then
        local goldValue = slotData.tagProps["Gold"]
        if goldValue and goldValue ~= "" and goldValue ~= "0" then
            speechData:AddProperty("Gold", goldValue, "normal")
        end
        -- Stack count for any stackable item.  Goes through the
        -- dedicated `count` core field so every context that shows
        -- quantity (radial, inventory, loot, trade, containers,
        -- camp, alchemy, etc.) speaks the same form.  Only fires
        -- when > 1 since single items are implicit.
        local stackCount = slotData.tagProps["Count"]
        if stackCount and stackCount ~= "" and stackCount ~= "0"
            and stackCount ~= "1" then
            speechData:Add("count",
                stackCount .. " available", "normal")
        end
    end

    -- Store for tooltip diff (radial isn't a panel handler, so
    -- DispatchTooltip checks this as radial fallback).
    lastRadialSpeechData = speechData

    local fullText = speechData:Format()
    if not fullText then return end

    -- No Lua-side dedup for radial events.  C++ handles dedup via
    -- pointer address comparison and resets on center rest.
    Log.Info("RADIAL [" .. slotData.slotType .. "]: " .. fullText)
    Ext.Tolk.Speak(fullText, true)
end

-- ============================================================================
-- Radial open detection (called by Manager on VMHotBar focus change)
-- ============================================================================

--- HandleRadialOpen: speak the radial intro when focus first moves to the
--- HotBar PageView.  Called by the Manager when it detects a focusChanged
--- event on an element with dcType containing "VMHotBar".
--- Suppressed when already inside the radial (LB/RB page switches cause
--- focus changes to new PageView elements but are NOT fresh opens).
--- Hint speaks on first open per gameplay session; subsequent opens speak
--- just the title ("Action Radial").
local function HandleRadialOpen()
    if inRadial then return end
    inRadial = true

    local speechData = SpeechData.Create()
    speechData:Add("title", "Action Radial")
    if not radialHintSpoken then
        radialHintSpoken = true
        speechData:Add("navigationHint", RADIAL_HINT)
    end
    local speech = speechData:Format()
    if not speech then return end
    Log.Info("RADIAL OPEN: " .. speech)
    SpeechData.Alert(speech, "interrupt")
end

--- ClearRadialFocus: called by the Manager when focus moves to a
--- non-radial element, indicating the radial has been closed.
local function ClearRadialFocus()
    inRadial = false
end


-- ============================================================================
-- Entry point for radial (called by EventRouter)
-- ============================================================================

--- HandleRadialSlot: gather data then speak.
--- @param snapshot table  The full TickSnapshot from C++.
local function HandleRadialSlot(snapshot)
    local slotData = GatherRadialSlotData(snapshot)
    if slotData then
        SpeakRadialSlot(slotData)
    end
end

-- ============================================================================
-- Tooltip handler
-- ============================================================================

--- DispatchTooltip: routes structured tooltip data to the active panel
--- handler.  Handles WorldUI-specific suppression, raw-text retention
--- for inspect readback, and dedup reset on navigation.
--- The handler owns all speech decisions via HandleTooltip.
--- @param structuredTooltipData table|nil  Array of {role, text} from C++
---     (nil on focus-only ticks with no tooltip data).
--- @param snapshot table  The full TickSnapshot (for change flags).
local function DispatchTooltip(structuredTooltipData, snapshot)
    -- Reset dedup on navigation (even when suppressed, so re-entering
    -- a suppressed element doesn't carry stale state).
    if snapshot.focusChanged or snapshot.selectionChanged then
        if activePanelHandler and activePanelHandler.ResetTooltipDedup then
            activePanelHandler.ResetTooltipDedup()
        end
        -- Also clear radial fallback dedup.
        tooltipState.lastTooltipSpeech = nil
    end

    -- Tooltip-close signal: tooltipChanged is true but no texts arrived.
    -- Invalidate tooltip-derived state on the active handler (compare
    -- stash) and close any open CompareView whose grid was built from
    -- the tooltip's contents.  Runs even when the module is suppressed
    -- so state can't linger past a suppression boundary.
    if snapshot.tooltipChanged and not structuredTooltipData then
        if activePanelHandler and activePanelHandler.ClearCompareData then
            activePanelHandler.ClearCompareData()
        end
        CloseCompareView(true)
        lastRawTooltipTexts = nil
    end

    if tooltipSuppressed or not tooltipEnabled then return end
    if not structuredTooltipData then return end

    -- Store raw texts for inspect readback (right stick).
    lastRawTooltipTexts = structuredTooltipData

    -- Dispatch to active panel handler.
    if activePanelHandler and activePanelHandler.HandleTooltip then
        activePanelHandler.HandleTooltip(
            structuredTooltipData, structuredTooltipData, lastFocusedDCType)
        return
    end

    -- Radial fallback: no panel handler active, build simple SpeechData
    -- from roles and speak directly.  Use "brief" verbosity for radial
    -- context (damage/cost only, matching old minimal behavior).
    local fallbackSpeech = SpeechData.FromTooltip(structuredTooltipData)
    if lastRadialSpeechData then
        fallbackSpeech = fallbackSpeech:Diff(lastRadialSpeechData)
    end
    local tooltipSpeech = fallbackSpeech:Format("brief")
    if tooltipSpeech and tooltipSpeech ~= ""
        and tooltipSpeech ~= tooltipState.lastTooltipSpeech then
        tooltipState.lastTooltipSpeech = tooltipSpeech
        Log.Info("TOOLTIP (radial fallback): " .. tooltipSpeech)
        Ext.Tolk.Speak(tooltipSpeech, false)
    end
end

--- HandleInspectNav: called by EventRouter when d-pad moves focus between
--- side panels in the PinnedTooltips_c inspect widget.  Reads the focused
--- panel's TextBlocks via C++ structured BFS and speaks using SpeechData.
---
--- Delegates to SpeechData.FromTooltip -- the same role-based classifier
--- used by the live tooltip poll -- via the shared TOOLTIP_ROLE_MAP.
--- Inspect side cards use the game's tooltip templates (Tooltips.xaml)
--- which have x:Name on most TextBlocks (Title, ContentText,
--- PropertyText, etc.), so role-based classification is reliable.
---
--- Pre-pass: KeyValue WrapPanel templates emit consecutive pairs of
--- role="KeyValue" entries (label + value).  PairKeyValueEntries
--- collapses them into {role=<key>, text=<value>} entries so
--- FromTooltip renders them as "key: value" properties.
local function HandleInspectNav()
    local focused = Ext.UI.GetFocusedElement()
    if not focused then return end
    local readOk, structuredTexts = pcall(
        Ext.UI.ReadElementStructuredTextBlocks, focused)
    if not readOk or not structuredTexts or #structuredTexts == 0 then
        return
    end

    local pairedTexts = SpeechData.PairKeyValueEntries(structuredTexts)
    local speechData = SpeechData.FromTooltip(pairedTexts)

    -- Some inspect tooltip templates (StatusTooltip et al.) put the
    -- title/subtitle TextBlocks under unnamed container chains that
    -- C++ parent-role promotion can't reach, so FromTooltip drops
    -- them.  Fill any missing title/sectionLabel/description core
    -- fields from unnamed short/long entries as a fallback.  Named
    -- roles win because we check HasField before filling.
    SpeechData.PromoteEmptyRoleTitle(speechData, pairedTexts)
    SpeechData.PromoteEmptyRoleDescription(speechData, pairedTexts)

    local speech = speechData:Format()
    if speech and speech ~= "" then
        Log.Info("INSPECT NAV: " .. speech)
        Ext.Tolk.Speak(speech, true)
    end
end

--- SpeakInspectData: called when PinnedTooltips_c widget appears (right
--- stick inspect).  Reads the MAIN tooltip subtree (not the linked
--- side panels) via structured role-based extraction and speaks the
--- overview through SpeechData.FromTooltip.
---
--- XAML structure: PinnedTooltips_c contains a `PinnedContainer`
--- (Grid) for the primary item tooltip AND a `ChildTooltipsContainer`
--- (ScrollViewer) for linked side panels (Burning, Bonus Action,
--- Single Use, Item Weight, Item Price, etc.).  Early versions read
--- the WHOLE widget with a flat-text BFS, which conflated main-item
--- data with side-panel data -- e.g. a Potion of Healing's 2d4+2
--- healing got mixed with the linked Burning condition's 1d4 Fire
--- damage ("Damage: 1 to 4, 1d4 Fire plus 2d4+2" -- misleading).
---
--- Now we target only PinnedContainer via FindNameInWidget, run the
--- structured reader primitive on it, and let FromTooltip classify
--- each TextBlock by role.  Side panels remain navigable via d-pad
--- through HandleInspectNav (each reads with correct per-panel
--- structure).
---
--- @return boolean  True if inspect data was spoken, false if nothing found.
local function SpeakInspectData()
    -- Resolve PinnedContainer (the main-tooltip Grid inside the
    -- PinnedTooltips_c widget).  FindNameInWidget walks across
    -- visible widgets to find the named element, bypassing the
    -- widget NameScope boundary.
    local findOk, mainContainer = pcall(
        Ext.UI.FindNameInWidget, "PinnedContainer")
    if findOk and mainContainer then
        local readOk, structuredTexts = pcall(
            Ext.UI.ReadElementStructuredTextBlocks, mainContainer)
        if readOk and structuredTexts and #structuredTexts > 0 then
            local pairedTexts = SpeechData.PairKeyValueEntries(
                structuredTexts)
            local speechData = SpeechData.FromTooltip(pairedTexts)
            SpeechData.PromoteEmptyRoleTitle(speechData, pairedTexts)
            SpeechData.PromoteEmptyRoleDescription(
                speechData, pairedTexts)
            -- Potions/scrolls/consumables: relabel orphan Damage
            -- dice to Dice so "2d4+2" doesn't read as "Damage: 2d4+2"
            -- when it's actually healing/effect dice.  Shared with
            -- FormatItemTooltip for consistent labeling.
            SpeechData.RelabelOrphanDamageDice(speechData)
            local inspectSpeech = speechData:Format()
            if inspectSpeech and inspectSpeech ~= "" then
                Log.Info("INSPECT (widget): " .. inspectSpeech)
                Ext.Tolk.Speak(inspectSpeech, true)
                return true
            end
        end
    end

    -- Fallback: use stored tooltip texts if PinnedContainer lookup
    -- failed.  Same structured path via FromTooltip.
    if lastRawTooltipTexts and #lastRawTooltipTexts > 0 then
        local pairedTexts = SpeechData.PairKeyValueEntries(
            lastRawTooltipTexts)
        local speechData = SpeechData.FromTooltip(pairedTexts)
        SpeechData.PromoteEmptyRoleTitle(speechData, pairedTexts)
        SpeechData.PromoteEmptyRoleDescription(
            speechData, pairedTexts)
        SpeechData.RelabelOrphanDamageDice(speechData)
        local inspectSpeech = speechData:Format()
        if inspectSpeech and inspectSpeech ~= "" then
            Log.Info("INSPECT (fallback): " .. inspectSpeech)
            Ext.Tolk.Speak(inspectSpeech, true)
            return true
        end
    end

    return false
end

--- ResetTooltipState: clear all tooltip state (called on GameStateChanged).
local function ResetTooltipState()
    tooltipState.lastTooltipSpeech = nil
    tooltipSuppressed = false
    lastSpokenRadialTitle = nil
    lastRawTooltipTexts = nil
    lastRadialSpeechData = nil
end

-- ============================================================================
-- Panel handler factory (adapted from Menus.CreateMenuHandler)
-- ============================================================================

--- CreatePanelHandler: builds a handler with isolated state and a generic
--- pipeline for in-game panel navigation.  Same factory pattern as
--- Menus.CreateMenuHandler.
---
--- @param config table  Handler configuration:
---   name (string)               -- handler name for logging
---   hint (string|false|nil)     -- navigation hint text, false to suppress, nil for default
---   onWidgetAdded (function)    -- optional: called on widgetAdded with (widgetData, handlerState)
---   onReset (function)          -- optional: called on full state reset
---   hintFn (function)           -- optional: dynamic hint based on (screenTitle, handlerState)
---   customItemFn (function)     -- optional: custom item extraction per handler.
---                                  Called with (focusedElement, handlerState, snapshot)
---                                  BEFORE the generic FormatDCTextSplit pipeline.
---                                  Returns (name, value, desc) to override, or nil
---                                  to fall through.  Can also return a SpeechData
---                                  object for full control over speech ordering.
---   treatTabsAsItems (boolean)  -- optional: when true, tab-typed focus changes
---                                  (ListBoxItems) are classified as item navigation
---                                  instead of screen entries.  Use for panels where
---                                  ListBoxItems are navigable items, not real tabs
---                                  (e.g., ActiveRoll bonus list).
---   customTooltipFn (function)  -- optional: per-handler tooltip formatting.
---                                  Called with (tooltipTexts, focusedDCType).
---                                  Returns a SpeechData object (to speak), "" to
---                                  suppress, or nil to fall through to
---                                  the default role-based SpeechData
---                                  builder (the radial/panel default).
---
--- @return table  Handler with HandleSnapshot, HandleWidgetAdded,
---                ResetState, ResetNavigation, ResetHint, customTooltipFn,
---                GetLastFocusedData, BuildDetailList (if config provides it)
local function CreatePanelHandler(config)
    local handlerState = {
        lastSpokenName       = nil,
        lastSpokenFullText   = nil,
        lastSpokenTab        = nil,
        lastSpokenTitle      = nil,
        lastSpeechData       = nil,   -- SpeechData from last handler speech
        lastFocusedData      = nil,   -- last focusedElement data table (for detail view)
        lastTooltipSpeech    = nil,   -- tooltip dedup (inline comparison)
        spokenRoles          = {},    -- set of field names spoken (for tooltip cross-off)
        spokenValues         = {},    -- set of spoken values (for carousel dedup)
        tabHintSpoken        = false,
        screenEntryJustSpoke = false,
        -- Optional: set by onWidgetAdded hooks for overrides.
        titleOverride        = nil,
        bodyOverride         = nil,
        -- Set by HandleWidgetAdded for the current tick.  HandleSnapshot
        -- consumes (and clears) this on the same tick so widget-derived
        -- title/body/namedTexts come from THIS handler's event, not a
        -- shared "best" event picked by the router.
        pendingWidgetEvent   = nil,
    }

    -- -----------------------------------------------------------------
    -- RecordSpokenRoles: populate spokenRoles and spokenValues from
    -- a SpeechData's fields so tooltip cross-off and carousel dedup
    -- can reference what was already spoken.
    -- -----------------------------------------------------------------
    local function RecordSpokenRoles(speechData)
        handlerState.spokenRoles = {}
        handlerState.spokenValues = {}
        for fieldName, fieldValue in pairs(speechData.coreFields) do
            handlerState.spokenRoles[fieldName] = true
            if fieldValue and fieldValue ~= "" then
                handlerState.spokenValues[
                    Helpers.NormalizeForCompare(fieldValue)] = true
            end
        end
        for _, prop in ipairs(speechData.properties) do
            handlerState.spokenRoles["property:" .. prop.label] = true
            if prop.value and prop.value ~= "" then
                handlerState.spokenValues[
                    Helpers.NormalizeForCompare(prop.value)] = true
            end
        end
    end

    -- -----------------------------------------------------------------
    -- HandleSnapshot: generic panel processing pipeline.
    -- Handles classification, widget updates, carousel/value, screen
    -- entry, item navigation, and speech output.
    -- -----------------------------------------------------------------
    local function HandleSnapshot(snapshot)
        local focusedElement = snapshot.focusedElement
        if not focusedElement or not focusedElement.elemType then return end

        -- User-initiated: true when the snapshot was triggered by user
        -- input (d-pad, button, carousel switch, value toggle).
        -- System events (widget scans, post-settle) are not user-initiated.
        local userInitiated = snapshot.focusChanged
            or snapshot.selectionChanged
            or snapshot.inlineCarouselChanged
            or snapshot.valueChanged

        -- Clear stale compare data on focus change.  HandleTooltip
        -- re-populates when the new item's tooltip (with compare card)
        -- arrives; until then, RS-Right falls through to default
        -- behavior instead of opening a grid for the previous item.
        -- Also close an open compare view: its local grid was built
        -- from the previous item's cards and is now stale.
        if snapshot.focusChanged then
            handlerState.focusedCompareData = nil
            handlerState.compareData = nil
            CloseCompareView(true)
        end

        -- Dialog answer navigation: when focus changes within an active
        -- dialog, the cutscene module handles answer speech.
        if snapshot.focusChanged and focusedElement
            and Cutscene.HandleDialogAnswerFocus(focusedElement) then
            return
        end

        -- =============================================================
        -- Classify: what kind of change is this?
        -- =============================================================
        local elemId = focusedElement.elemId or ""
        local hasCarousel = snapshot.inlineCarouselChanged
            and snapshot.inlineCarouselValue
            and snapshot.inlineCarouselValue ~= ""

        -- pendingWidgetEvent: the widget event that activated this
        -- handler on this tick (set by HandleWidgetAdded).  Consume
        -- once so widget-derived text doesn't leak into later ticks.
        local widgetEvent = handlerState.pendingWidgetEvent
        handlerState.pendingWidgetEvent = nil

        local isScreenEntry = false
        -- treatTabsAsItems: when true, tab-typed focus changes are
        -- item navigation, not screen entries.  Used by ActiveRoll
        -- where ListBoxItems are bonus items, not real carousel tabs.
        local tabIsItem = config.treatTabsAsItems
            and focusedElement.isTab
        if snapshot.selectionChanged then
            isScreenEntry = true
        elseif widgetEvent and not handlerState.lastSpokenTab then
            isScreenEntry = true
        elseif snapshot.focusChanged and focusedElement.isTab
            and not tabIsItem then
            isScreenEntry = true
        end

        local isItemNav = snapshot.focusChanged
            and (not focusedElement.isTab or tabIsItem)
            and not isScreenEntry
        local isCarouselOnly = hasCarousel and not snapshot.focusChanged
        local isValueOnly = not isScreenEntry and not isItemNav
            and not isCarouselOnly and snapshot.valueChanged

        -- Widget text update: DC property changed (e.g., status text
        -- update) or dialog appeared without focus change.
        if not isScreenEntry and not isItemNav and widgetEvent then
            local _, widgetBody, widgetActions = Helpers.ExtractFromWidgetData(
                widgetEvent)
            local updateText = widgetBody or widgetActions
            if updateText and updateText ~= ""
                and updateText ~= handlerState.lastSpokenFullText then
                local updateSpeech = SpeechData.Create()
                updateSpeech:Add("status", updateText, "brief")
                updateSpeech:Speak(handlerState, false, nil, userInitiated)
                return
            end
        end

        if not isScreenEntry and not isItemNav
            and not isCarouselOnly and not isValueOnly then
            return
        end

        -- =============================================================
        -- Standalone carousel or value.
        -- =============================================================
        if isCarouselOnly then
            local carouselValue = snapshot.inlineCarouselValue
            if carouselValue ~= handlerState.lastSpokenFullText
                and not handlerState.spokenValues[
                    Helpers.NormalizeForCompare(carouselValue)] then
                local carouselSpeech = SpeechData.Create()
                carouselSpeech:Add("value", carouselValue, "brief")
                carouselSpeech:Speak(handlerState, false, nil, userInitiated)
            end
            return
        end

        if isValueOnly then
            -- customItemFn handles value changes for special elements
            -- (expander toggle, equipment equip/unequip, etc.).
            if config.customItemFn then
                local customName = config.customItemFn(
                    focusedElement, handlerState, snapshot)
                -- SpeechData object: compute delta against previous
                -- SpeechData and speak only what changed.
                if type(customName) == "table" and customName.coreFields then
                    local delta = customName:Delta(
                        handlerState.lastSpeechData)
                    local deltaFormatted = delta:Format()
                    -- Always update lastSpeechData so subsequent
                    -- deltas compare against the most recent state,
                    -- even when the current tick was silent.
                    handlerState.lastSpeechData = customName
                    handlerState.lastSpokenFullText = customName:Format()
                    if deltaFormatted and deltaFormatted ~= "" then
                        Log.Info("VALUE [" .. config.name .. "]: "
                            .. deltaFormatted)
                        Ext.Tolk.Speak(deltaFormatted, true)
                    end
                    return
                end
                -- Non-empty string: wrap in SpeechData and speak.
                if customName and customName ~= "" then
                    if customName ~= handlerState.lastSpokenFullText then
                        local valueSpeech = SpeechData.Create()
                        valueSpeech:Add("value", customName, "brief")
                        valueSpeech:Speak(handlerState, false, nil,
                            userInitiated)
                    end
                    return
                end
                -- nil: fall through to generic value path.
                -- "": suppressed, but still try generic value.
            end
            local valueText = Helpers.FormatDCValue(focusedElement.dcProps)
            if valueText and valueText ~= ""
                and valueText ~= handlerState.lastSpokenFullText then
                local valueSpeech = SpeechData.Create()
                valueSpeech:Add("value", valueText, "brief")
                valueSpeech:Speak(handlerState, false, nil, userInitiated)
            end
            return
        end

        -- =============================================================
        -- Screen entry or item navigation: build SpeechData, speak.
        -- =============================================================
        local speechData = SpeechData.Create()
        local tabName = nil
        local normalTab = ""
        local screenTitle = nil

        if isScreenEntry then
            -- Derive tab name.
            if focusedElement.isTab then
                tabName = Helpers.GetTranslatedStringIfHandle(
                    focusedElement.tabName)
            end
            normalTab = tabName and Helpers.NormalizeForCompare(tabName) or ""

            -- Dedup: skip if same tab.
            if tabName and tabName == handlerState.lastSpokenTab then
                Log.Debug("SKIP screen entry (same tab) ["
                    .. config.name .. "]: " .. tabName)
                return
            end

            Log.Info("SCREEN ENTRY [" .. config.name .. "]: tab="
                .. tostring(tabName)
                .. " sel=" .. tostring(snapshot.selectionChanged)
                .. " widget=" .. tostring(snapshot.widgetAdded))

            -- Always update, even when nil, so widgetAdded doesn't
            -- re-trigger.  Empty string = "screen entry processed".
            handlerState.lastSpokenTab = tabName or ""
            handlerState.lastSpokenName = nil

            -- Gather data sources.
            local allNamedTexts = {}
            if focusedElement.namedTexts then
                for elementName, elementText in pairs(focusedElement.namedTexts) do
                    allNamedTexts[elementName] = elementText
                end
            end
            if widgetEvent and widgetEvent.namedTexts then
                for elementName, elementText in pairs(widgetEvent.namedTexts) do
                    if not allNamedTexts[elementName] then
                        allNamedTexts[elementName] = elementText
                    end
                end
            end
            local nsTitle, nsBodyParts = Helpers.ExtractFromNamedTexts(
                allNamedTexts)
            local widgetTitle, widgetBody, widgetActions =
                Helpers.ExtractFromWidgetData(widgetEvent)

            -- Title.  Handler titleOverride takes priority (e.g., Container
            -- handler sets the container name, which is more specific than
            -- a generic tab name like "Inventory" from namedTexts).
            if handlerState.titleOverride then
                screenTitle = handlerState.titleOverride
                handlerState.titleOverride = nil
            else
                screenTitle = nsTitle or widgetTitle
            end
            if screenTitle and normalTab ~= ""
                and Helpers.NormalizeForCompare(screenTitle) == normalTab then
                screenTitle = nil
            end
            if screenTitle
                and screenTitle == handlerState.lastSpokenTitle then
                screenTitle = nil
            end
            if screenTitle then
                handlerState.lastSpokenTitle = screenTitle
                speechData:Add("title", screenTitle, "brief")
            end

            -- Hint (once per panel visit).
            if not handlerState.tabHintSpoken then
                handlerState.tabHintSpoken = true
                local panelHint
                if config.hintFn then
                    panelHint = config.hintFn(screenTitle, handlerState)
                else
                    panelHint = config.hint
                    if panelHint == nil then
                        panelHint = DEFAULT_PANEL_HINT
                    end
                end
                if panelHint then
                    speechData:Add("navigationHint", panelHint, "normal")
                end
            end

            -- Tab name (suppress if title contains it or unresolved handle).
            if tabName then
                local showTabName = true
                if tabName:match("^h%x+g") then
                    showTabName = false
                end
                if showTabName and screenTitle
                    and Helpers.NormalizeForCompare(screenTitle):find(
                        normalTab, 1, true) then
                    showTabName = false
                end
                if showTabName then
                    speechData:Add("sectionLabel", tabName, "brief")
                end
            end

            -- Body.
            local bodyAssembled = nil
            if nsBodyParts and #nsBodyParts > 0 then
                bodyAssembled = table.concat(nsBodyParts, ". ")
            end
            if not bodyAssembled and handlerState.bodyOverride then
                bodyAssembled = handlerState.bodyOverride
                handlerState.bodyOverride = nil
            end
            if not bodyAssembled and widgetBody then
                bodyAssembled = widgetBody
            end
            local statusText = Helpers.ExtractStatusText(
                focusedElement.dcProps)
            if statusText then
                bodyAssembled = bodyAssembled
                    and (bodyAssembled .. ". " .. statusText) or statusText
            end
            if bodyAssembled then
                speechData:Add("description", bodyAssembled, "normal")
            end
            if widgetActions then
                speechData:Add("instructionHint", widgetActions, "normal")
            end
        else
            -- Item navigation: dedup check.
            if elemId == handlerState.lastSpokenName
                and not hasCarousel then
                local text = Helpers.ExtractTextFromData(
                    focusedElement, handlerState.lastSpokenTab, false)
                if not text
                    or text == handlerState.lastSpokenFullText then
                    Log.Debug("DEDUP SKIP [" .. config.name .. "]: "
                        .. tostring(elemId))
                    return
                end
            end
        end

        -- ----- Item fields -----
        local itemName = nil
        local itemInfo = nil
        local itemValue = nil
        local itemDesc = nil

        -- customItemFn: handler-specific extraction before generic pipeline.
        -- Return nil to fall through to generic extraction.
        -- Return "" to suppress (no speech, no fallback).
        -- Return a non-empty string to override the item name.
        -- Return a SpeechData object for full control over speech.
        local splitName, splitValue, splitDesc, splitValueDesc
        local customHandled = false
        local customSpeechData = nil
        if config.customItemFn then
            splitName, splitValue, splitDesc = config.customItemFn(
                focusedElement, handlerState, snapshot)
            -- Check if customItemFn returned a SpeechData object.
            if type(splitName) == "table" and splitName.coreFields then
                customSpeechData = splitName
                customHandled = true
            elseif splitName ~= nil then
                customHandled = true
            end
        end

        -- If customItemFn returned a full SpeechData, use it directly.
        -- Empty SpeechData (zero fields) = handler handled everything
        -- itself (e.g., Book reader), suppress all generic speech.
        if customSpeechData then
            if next(customSpeechData.coreFields) == nil
                and #customSpeechData.properties == 0 then
                handlerState.lastFocusedData = focusedElement
                return
            end
            -- Cache focused element data for detail view (RS Left).
            handlerState.lastFocusedData = focusedElement
            -- Merge screen entry fields (title/hint/tab) into the custom
            -- SpeechData if this is a screen entry.
            if isScreenEntry then
                local merged = SpeechData.Create()
                -- Copy screen entry core fields first.
                for fieldName, fieldValue in pairs(speechData.coreFields) do
                    merged:Add(fieldName, fieldValue,
                        speechData.tiers[fieldName])
                end
                for _, prop in ipairs(speechData.properties) do
                    merged:AddProperty(prop.label, prop.value, prop.tier)
                end
                -- Then custom handler fields.
                for fieldName, fieldValue in pairs(
                        customSpeechData.coreFields) do
                    merged:Add(fieldName, fieldValue,
                        customSpeechData.tiers[fieldName])
                end
                for _, prop in ipairs(customSpeechData.properties) do
                    merged:AddProperty(prop.label, prop.value, prop.tier)
                end
                handlerState.lastSpeechData = merged
                RecordSpokenRoles(merged)
                merged:Speak(handlerState, isScreenEntry, nil,
                    userInitiated)
            else
                handlerState.lastSpeechData = customSpeechData
                RecordSpokenRoles(customSpeechData)
                customSpeechData:Speak(handlerState, isScreenEntry, nil,
                    userInitiated)
            end
            return
        end

        if not customHandled then
            splitName, splitValue, splitDesc, splitValueDesc =
                Helpers.FormatDCTextSplit(focusedElement.dcProps,
                    focusedElement.dcType)
        end
        if not customHandled and (not splitName or splitName == "") then
            splitName = Helpers.ExtractTextFromData(
                focusedElement, handlerState.lastSpokenTab, isScreenEntry)
            splitValue = nil
            splitDesc = nil
            splitValueDesc = nil
        end
        -- Filter unresolved LocaString handles from item names.
        if splitName and splitName:match("^h%x+g") then
            splitName = nil
        end
        if splitName and splitName ~= "" then
            local normalItem = Helpers.NormalizeForCompare(splitName)
            local normalTitle = screenTitle
                and Helpers.NormalizeForCompare(screenTitle) or ""
            local isDuplicate = (normalTab ~= ""
                and normalItem == normalTab)
                or (normalTitle ~= ""
                    and (normalItem == normalTitle
                        or normalTitle:find(normalItem, 1, true)))
            if not isDuplicate then
                itemName = splitName
                itemValue = splitValue
                if splitValueDesc then
                    itemInfo = splitDesc
                    itemDesc = splitValueDesc
                else
                    itemDesc = splitDesc
                end
            end
        end

        if hasCarousel then
            itemValue = snapshot.inlineCarouselValue
        end

        if itemName then
            handlerState.lastSpokenName = elemId
            handlerState.lastSpokenFullText = itemName
            Log.Info("ITEM [" .. config.name .. "]: "
                .. tostring(focusedElement.elemType)
                .. "  name=" .. itemName
                .. (itemValue and ("  val=" .. itemValue) or "")
                .. (itemDesc
                    and ("  desc=" .. tostring(itemDesc):sub(1, 40))
                    or ""))
        end

        speechData:Add("name", itemName, "brief")
        speechData:AddProperty("Info", itemInfo, "normal")
        speechData:Add("value", itemValue, "brief")
        speechData:Add("description", itemDesc, "verbose")

        -- Cache focused element data for detail view (RS Left).
        handlerState.lastFocusedData = focusedElement
        handlerState.lastSpeechData = speechData
        -- Record which fields we spoke (for tooltip cross-off).
        RecordSpokenRoles(speechData)
        speechData:Speak(handlerState, isScreenEntry, nil, userInitiated)
    end

    -- -----------------------------------------------------------------
    -- HandleWidgetAdded: process widget added events.  Stashes the
    -- event on handlerState for HandleSnapshot to consume on the same
    -- tick.
    -- -----------------------------------------------------------------
    local function HandleWidgetAdded(widgetData)
        handlerState.pendingWidgetEvent = widgetData
        if config.onWidgetAdded then
            config.onWidgetAdded(widgetData, handlerState)
        end
    end

    -- -----------------------------------------------------------------
    -- State management.
    -- -----------------------------------------------------------------

    --- ResetState: full reset (GameStateChanged or handler deactivation).
    local function ResetState()
        handlerState.lastSpokenName = nil
        handlerState.lastSpokenFullText = nil
        handlerState.lastSpokenTab = nil
        handlerState.lastSpokenTitle = nil
        handlerState.lastSpeechData = nil
        handlerState.lastFocusedData = nil
        handlerState.tabHintSpoken = false
        handlerState.screenEntryJustSpoke = false
        handlerState.titleOverride = nil
        handlerState.bodyOverride = nil
        handlerState.pendingWidgetEvent = nil
        -- Compare stash lives across tooltip events; clear on handler
        -- teardown so re-entering the panel doesn't pick up state from
        -- a previous session's tooltip.
        handlerState.focusedCompareData = nil
        handlerState.compareData = nil
        if config.onReset then
            config.onReset(handlerState)
        end
    end

    --- ResetNavigation: partial reset for widget root change within
    --- the same handler (e.g., switching tabs in inventory).
    --- Preserves tabHintSpoken so the hint doesn't re-speak.
    local function ResetNavigation()
        handlerState.lastSpokenTab = nil
        handlerState.lastSpokenTitle = nil
        handlerState.lastSpokenName = nil
        handlerState.lastSpeechData = nil
        handlerState.screenEntryJustSpoke = false
        handlerState.titleOverride = nil
        handlerState.bodyOverride = nil
    end

    --- ResetHint: reset tabHintSpoken so the hint speaks on next visit.
    --- Called when this handler is deactivated (different handler takes over).
    local function ResetHint()
        handlerState.tabHintSpoken = false
    end

    return {
        name              = config.name,
        HandleSnapshot    = HandleSnapshot,
        HandleWidgetAdded = HandleWidgetAdded,
        ResetState        = ResetState,
        ResetNavigation   = ResetNavigation,
        ResetHint         = ResetHint,
        customTooltipFn   = config.customTooltipFn,
        GetLastSpeechData = function()
            return handlerState.lastSpeechData
        end,
        GetLastFocusedData = function()
            return handlerState.lastFocusedData
        end,
        BuildDetailList   = config.buildDetailList,
        --- HandleTooltip: process an open tooltip.
        ---
        --- Single-card tooltips (most cases) flow through the normal
        --- role-mapping pipeline on the whole popup's TextBlocks.
        ---
        --- Compare-mode tooltips (inventory items focused on a
        --- non-selected character) render CompareTooltipTemplate with
        --- two named ContentControls:
        ---   HoveredItemPanel  = focused item's card
        ---   EquippedItemPanel = currently-equipped counterpart
        --- Lua detects this via primitives (GetTooltipPopupRoot +
        --- FindNameInWidgetScoped) and:
        ---   1. Speaks the MAIN tooltip from HoveredItemPanel only
        ---      (no doubled Equipped-by/Weight/Gold across cards)
        ---   2. Stashes both cards as separate SpeechData objects on
        ---      handlerState for the CompareView RS-Right grid
        ---   3. Adds a "Comparison available, right stick right" hint
        ---      to the main tooltip speech
        ---
        --- @param structuredData table  Array of {role, text} from C++ (whole popup).
        --- @param rawTexts table  Same structured array (for customTooltipFn).
        --- @param focusedDCType string|nil  DC type of focused element.
        HandleTooltip = function(structuredData, rawTexts, focusedDCType)
            -- Compare-mode detection: if both named panels exist, read
            -- each card's entries separately via primitives.  The
            -- focused-card entries go to the main speech path; both
            -- go (without cross-off) to CompareView state.
            handlerState.focusedCompareData = nil
            handlerState.compareData = nil
            local focusedEntries = structuredData
            local compareEntries = nil
            local popupRoot = Ext.UI.GetTooltipPopupRoot()
            if popupRoot then
                local hoveredPanel = Ext.UI.FindNameInWidgetScoped(
                    "HoveredItemPanel", popupRoot)
                local equippedPanel = Ext.UI.FindNameInWidgetScoped(
                    "EquippedItemPanel", popupRoot)
                if hoveredPanel and equippedPanel then
                    local hEntries = Ext.UI
                        .ReadElementStructuredTextBlocks(hoveredPanel)
                    local eEntries = Ext.UI
                        .ReadElementStructuredTextBlocks(equippedPanel)
                    if hEntries and eEntries
                        and #hEntries > 0 and #eEntries > 0 then
                        focusedEntries = hEntries
                        compareEntries = eEntries
                    end
                end
            end

            -- Main speech pipeline (focused card only in compare mode,
            -- whole popup in single-card mode).
            local tooltipData
            if config.customTooltipFn then
                tooltipData = config.customTooltipFn(
                    focusedEntries, focusedDCType, handlerState)
            else
                tooltipData = SpeechData.FromTooltip(
                    focusedEntries, handlerState.spokenRoles)
            end
            if not tooltipData or tooltipData == ""
                or (next(tooltipData.coreFields) == nil
                    and #tooltipData.properties == 0) then return end

            -- Compare data: build separate SpeechData objects WITHOUT
            -- cross-off so CompareView has both items' full facts
            -- (including names) regardless of what focus already spoke.
            if compareEntries then
                local focusedNoCrossOff = SpeechData.FromTooltip(
                    focusedEntries)
                local compareSpeech = SpeechData.FromTooltip(
                    compareEntries)
                if focusedNoCrossOff and compareSpeech
                    and compareSpeech.coreFields.name then
                    handlerState.focusedCompareData = focusedNoCrossOff
                    handlerState.compareData = compareSpeech
                    if not tooltipData:HasField("instructionHint") then
                        tooltipData:Add("instructionHint",
                            "Comparison available, right stick right",
                            "brief")
                    end
                end
            end

            -- Format and speak with inline dedup.  No explicit
            -- verbosity: Format() falls back to the module-global
            -- currentVerbosity so RS-Down cycling affects tooltips
            -- the same as every other speech path.
            local tooltipSpeech = tooltipData:Format()
            if not tooltipSpeech or tooltipSpeech == "" then return end
            if tooltipSpeech == handlerState.lastTooltipSpeech then return end
            handlerState.lastTooltipSpeech = tooltipSpeech
            Log.Info("TOOLTIP: " .. tooltipSpeech)
            -- Queue after item speech (interrupt=false).  The handler
            -- already spoke the item name; tooltip is supplemental.
            Ext.Tolk.Speak(tooltipSpeech, false)
        end,
        ResetTooltipDedup = function()
            handlerState.lastTooltipSpeech = nil
        end,
        --- ClearCompareData: invalidate tooltip-derived compare stash.
        --- Called by DispatchTooltip on the tooltip-close signal so a
        --- subsequent RS-Right can't open a grid for a tooltip that is
        --- no longer on screen.
        ClearCompareData = function()
            handlerState.focusedCompareData = nil
            handlerState.compareData = nil
        end,
        --- GetCompareData: returns (focusedSpeech, compareSpeech) when
        --- the last tooltip contained a compare card, or nil otherwise.
        --- Used by the EventRouter RS-Right dispatcher to open CompareView.
        GetCompareData = function()
            if handlerState.focusedCompareData
                and handlerState.compareData then
                return handlerState.focusedCompareData,
                    handlerState.compareData
            end
            return nil, nil
        end,
    }
end

-- ============================================================================
-- Panel handler instances
-- ============================================================================

-- Character sheet / inventory / equipment (from CharSheet.lua).
local CharacterPanelHandler = CharSheet.CreateCharacterPanelHandler(
    CreatePanelHandler)

-- Spell book / actions panel (from SpellBook.lua).
local SpellBookHandler = SpellBook.CreateSpellBookHandler(
    CreatePanelHandler)

-- Trading / bartering dual inventory.
local TradeHandler = CreatePanelHandler({
    name = "Trade",
    hint = "Use bumpers to switch between inventories."
        .. " Up and down to navigate items.",
})

-- Inspect character or item details.
-- Widget DC is generic ls.Widget; discovery activates via focused
-- element DC types (VMRangeStat, VMResistance, VMItem).
local ExamineHandler = CreatePanelHandler({
    name = "Examine",
    hint = false,
    customItemFn = function(focusedElement, handlerState, snapshot)
        local dcType = focusedElement.dcType or ""

        -- VMRangeStat / VMStat: read label + value from rendered
        -- TextBlocks, same approach as CharSheet.FormatStatFromTextBlocks.
        if dcType:find("VMRangeStat") or dcType:find("VMStat") then
            local readOk, textBlocks = pcall(Ext.UI.ReadFocusedTextBlocks)
            if readOk and textBlocks and #textBlocks > 0 then
                local labels = {}
                local values = {}
                for _, text in ipairs(textBlocks) do
                    if text and text ~= "" then
                        local cleaned = Helpers.StripMarkupTags(text)
                        if cleaned and cleaned ~= "" then
                            cleaned = cleaned:gsub("(%d+)~(%d+)",
                                "%1 to %2")
                            if cleaned:match("^[%d%+%-/]") then
                                values[#values + 1] = cleaned
                            else
                                labels[#labels + 1] = cleaned
                            end
                        end
                    end
                end
                local parts = {}
                for _, label in ipairs(labels) do
                    parts[#parts + 1] = label
                end
                for _, value in ipairs(values) do
                    parts[#parts + 1] = value
                end
                if #parts > 0 then
                    return table.concat(parts, ": ")
                end
            end
        end

        -- VMResistance: name + level from dcProps.  Description
        -- comes from the tooltip on the next tick (customTooltipFn
        -- adds it as a description field, no Diff needed).
        if dcType:find("VMResistance") then
            local dcProps = focusedElement.dcProps
            if dcProps and dcProps.DamageType then
                local damageType = tostring(dcProps.DamageType)

                -- Resolve resistance level: Full covers both
                -- magical and non-magical.  When Full is absent,
                -- fall back to NonMagical or Magical.
                local function ResolveLevel(rawLevel)
                    if rawLevel == "255" then return "Vulnerable" end
                    if type(rawLevel) == "string"
                        and rawLevel ~= "None"
                        and rawLevel ~= "" then
                        return rawLevel
                    end
                    return nil
                end

                local resistanceLevel = ResolveLevel(dcProps.Full)
                    or ResolveLevel(dcProps.NonMagical)
                    or ResolveLevel(dcProps.Magical)

                local speechData = SpeechData.Create()
                speechData:Add("name", damageType, "brief")
                if resistanceLevel then
                    speechData:AddProperty("Level",
                        resistanceLevel, "brief")
                end
                return speechData
            end
        end

        return nil
    end,
    customTooltipFn = function(tooltipTexts, focusedDCType,
                               handlerState)
        if not tooltipTexts or #tooltipTexts == 0 then return nil end

        -- VMRangeStat / VMStat: extract breakdown and description
        -- from roles.  No skipDiff needed -- only adds breakdown +
        -- description fields (no name/title), so the Diff won't
        -- kill them.
        if focusedDCType
            and (focusedDCType:find("VMRangeStat")
                or focusedDCType:find("VMStat")) then
            local speechData = SpeechData.FromTooltip(tooltipTexts)
            -- Stat tooltips use PropertyText for component breakdowns
            -- rather than generic properties.
            speechData:RelabelProperty("Property", "Breakdown")
            -- Stat tooltips often put their explanatory body text
            -- in an unnamed TextBlock (no x:Name).
            SpeechData.PromoteEmptyRoleDescription(
                speechData, tooltipTexts, 30)
            if next(speechData.coreFields) == nil
                and #speechData.properties == 0 then return nil end
            return speechData
        end

        -- VMResistance: tooltip has description sentences in
        -- BaseDescription and (optionally) AdditionalDescription
        -- TextBlocks.  Use the shared FromTooltip mapping so both
        -- land in their own core fields instead of collapsing.
        -- Title is cross-off filtered (handler spoke name).
        -- skipDiff because the description is new information,
        -- not a duplicate of what the handler said.
        if focusedDCType
            and focusedDCType:find("VMResistance") then
            local speechData = SpeechData.FromTooltip(tooltipTexts,
                handlerState.spokenRoles)
            speechData.skipDiff = true
            if next(speechData.coreFields) == nil
                and #speechData.properties == 0 then return nil end
            return speechData
        end

        -- Other Examine types: use default formatter.
        return nil
    end,
})

-- Container inventory (opening a bag/pouch from the inventory).
-- onWidgetAdded captures the container name from namedTexts and sets
-- titleOverride so screen entry speaks "Alchemy Pouch" instead of
-- a generic tab name like "Inventory".
-- customItemFn suppresses item speech on screen entry: the container
-- name IS the announcement; the focused item's description is redundant.
local ContainerHandler = CreatePanelHandler({
    name = "Container",
    hint = "Up and down to browse items. Y to take all. B to close.",
    onWidgetAdded = function(widgetData, handlerState)
        if widgetData and widgetData.namedTexts then
            local containerName = widgetData.namedTexts.containerName
            if containerName and containerName ~= ""
                and not containerName:match("^h%x+g")
                and not containerName:find("%[ForceUpdate%]") then
                handlerState.titleOverride = containerName
            end
        end
    end,
    customItemFn = function(focusedElement, handlerState, snapshot)
        -- Widget navigation fake elements are empty slots in the grid
        -- (same pattern as CharSheet inventory).  Announce them so the
        -- user knows they landed on a real slot that happens to be
        -- empty, rather than thinking the mod has gone silent.
        local elemId = focusedElement.elemId or ""
        if elemId:find("WidgetNavigationPrimaryFakeElement")
            or elemId:find("WidgetNavigationSecondaryFakeElement") then
            return "Empty slot", nil, nil
        end
        -- Real item: fall through to the generic pipeline.  On screen
        -- entry (selectionChanged), this means the initial focused
        -- item is spoken right after the container title and hint.
        return nil
    end,
})

-- Dice roll UI for skill checks and saving throws.
-- onWidgetAdded fires on initial appearance AND every widget DC INPC
-- change (RollState transitions).  We track lastRollState to detect
-- transitions and speak entry, re-roll, and result announcements.
-- customItemFn handles bonus item navigation (VMBoost, VMAdvantage).
local ActiveRollHandler = CreatePanelHandler({
    name = "ActiveRoll",
    hint = false,
    treatTabsAsItems = true,
    onWidgetAdded = function(widgetData, handlerState)
        local dcProps = widgetData and widgetData.dcProps
        if not dcProps then return end

        local rollState = dcProps.RollState
        if not rollState or rollState == "" then return end

        local previousState = handlerState.lastRollState

        -- Suppress duplicate announcements for the same state.
        -- NOTE: lastRollState is committed AFTER successful speech,
        -- not here.  If data isn't ready yet (e.g., FinalResult nil
        -- on first ResultReady INPC), the state stays unconsumed so
        -- the next INPC can retry with complete data.
        if rollState == previousState then return end

        -- Entry: roll screen just appeared (WaitForStart or Introduction).
        if rollState == "WaitForStart"
            or rollState == "IntroductionAnimation" then
            -- Always mark hint as spoken so the generic screen entry
            -- pipeline doesn't speak it separately.  We include it
            -- in the entry speech below.
            handlerState.tabHintSpoken = true

            -- Skip if DC isn't fully populated yet (first widget event
            -- often arrives before the game sets SkillOrAbility).  The
            -- INPC-driven second event will have complete data.
            local skillName = dcProps.SkillOrAbility
            if not skillName or skillName == ""
                or skillName:match("^h%x+g") then
                return
            end
            local speechData = SpeechData.Create()

            -- Dialogue line (for dialogue skill checks).
            local dialogueLine = dcProps.SelectedDialogueLine
            if dialogueLine and dialogueLine ~= ""
                and not dialogueLine:match("^h%x+g")
                and not dialogueLine:find("%[ForceUpdate%]") then
                speechData:Add("description", dialogueLine, "normal")
            end

            -- Build title from roll info: skill, ability check, DC,
            -- advantage.  Combined into a single "title" field so it
            -- always speaks regardless of verbosity tier.
            local titleParts = {}
            if skillName and skillName ~= ""
                and not skillName:match("^h%x+g") then
                titleParts[#titleParts + 1] = skillName
            end
            local abilityText = dcProps.AbilityCheckText
            if abilityText and abilityText ~= ""
                and dcProps.IsPureAbilityRoll ~= "True"
                and not abilityText:match("^h%x+g") then
                titleParts[#titleParts + 1] = abilityText
            end
            local roll = dcProps.Roll
            if roll and type(roll) == "table" then
                local difficultyCheck = roll.DifficultyCheck
                if difficultyCheck and difficultyCheck ~= "" then
                    titleParts[#titleParts + 1] = "DC " .. difficultyCheck
                end
                local advantageType = roll.RollAdvantageType
                if advantageType
                    and advantageType ~= "None"
                    and advantageType ~= "" then
                    titleParts[#titleParts + 1] = advantageType
                end
            end
            if #titleParts > 0 then
                speechData:Add("title",
                    table.concat(titleParts, ". "))
            end

            -- Navigation hint (globally toggleable via hintsEnabled).
            speechData:Add("navigationHint",
                "Y to roll. Left and right to browse bonuses.")

            local formatted = speechData:Format()
            if formatted and formatted ~= "" then
                handlerState.lastRollState = rollState
                Log.Info("ACTIVE ROLL entry: " .. formatted)
                handlerState.lastSpokenFullText = formatted
                handlerState.entrySpoken = true
                speechData:Speak(handlerState, true)
            end

        -- Re-roll available (Inspiration point or Lucky feat).
        elseif rollState == "WaitForReRoll" then
            handlerState.lastRollState = rollState
            local speechData = SpeechData.Create()
            speechData:Add("instructionHint",
                "Re-roll available. Y to re-roll.", "brief")
            local formatted = speechData:Format()
            if formatted then
                Log.Info("ACTIVE ROLL re-roll: " .. formatted)
                handlerState.lastSpokenFullText = formatted
                speechData:Speak(handlerState, true)
            end

        -- Result ready: announce outcome.
        -- Properties use On/Off (not True/False).
        -- Roll.RolledNumber has the die value but is often 0 when
        -- ResultReady first fires (dice animation still settling).
        -- Result ready: FinalResult DP has the rolled number (read
        -- from the DCActiveRoll DependencyProperty, not the Roll
        -- sub-object which is often 0 during dice animation).
        -- If FinalResult isn't available yet, don't commit state
        -- so the next INPC retry can pick it up with complete data.
        elseif rollState == "ResultReady" then
            local finalResult = dcProps.FinalResult
            local success = dcProps.Success
            local skipped = dcProps.SkippedRoll

            -- Defer if FinalResult isn't populated yet.
            if not finalResult or finalResult == ""
                or finalResult == "0" then
                Log.Debug("ACTIVE ROLL ResultReady: FinalResult="
                    .. tostring(finalResult) .. ", deferring")
                return
            end

            handlerState.lastRollState = rollState
            local speechData = SpeechData.Create()

            if skipped == "On" then
                speechData:Add("status", "Skipped", "brief")
            end

            speechData:AddProperty("Dice",
                "Rolled " .. finalResult, "brief")

            local resultNumber = tonumber(finalResult) or 0
            if success == "On" then
                if resultNumber == 20 then
                    speechData:AddProperty("Outcome",
                        "Critical Success!", "brief")
                else
                    speechData:AddProperty("Outcome", "Success!", "brief")
                end
            else
                if resultNumber == 1 then
                    speechData:AddProperty("Outcome",
                        "Critical Failure!", "brief")
                else
                    speechData:AddProperty("Outcome", "Failure.", "brief")
                end
            end

            local formatted = speechData:Format()
            if formatted and formatted ~= "" then
                Log.Info("ACTIVE ROLL result: " .. formatted)
                handlerState.lastSpokenFullText = formatted
                speechData:Speak(handlerState, true)
            end

        else
            -- Unrecognized intermediate state (e.g., rolling animation).
            -- Consume it so it doesn't block the next real transition.
            handlerState.lastRollState = rollState
            Log.Debug("ACTIVE ROLL state: " .. rollState)
        end
    end,
    onReset = function(handlerState)
        handlerState.lastRollState = nil
        handlerState.entrySpoken = false
        handlerState.lastBonusElemId = nil
    end,
    customItemFn = function(focusedElement, handlerState, snapshot)
        -- Suppress item speech until the entry announcement has spoken.
        -- The game focuses Thieves' Tools before the INPC delivers
        -- complete roll data, causing item speech to get interrupted.
        -- Return empty SpeechData to suppress all generic speech too.
        if not handlerState.entrySpoken then
            return SpeechData.Create()
        end

        local elemId = focusedElement.elemId
        local dcProps = focusedElement.dcProps
        if not dcProps then
            Log.Warn("ActiveRoll customItemFn: dcProps nil for "
                .. tostring(focusedElement.dcType)
                .. " elemId=" .. tostring(elemId))
            return nil
        end

        -- Dedup on elemId: skip only when the same element is focused
        -- consecutively.  Different elements always speak even when
        -- their text is identical (e.g., two "+2" bonuses).
        if elemId and elemId == handlerState.lastBonusElemId then
            return SpeechData.Create()
        end
        handlerState.lastBonusElemId = elemId

        local dcType = focusedElement.dcType or ""

        -- VMBoost: modifier name + boost type + numeric value or dice.
        -- BoostType distinguishes "ProficiencyBonus" vs "ExpertiseBonus"
        -- (XAML uses DataTrigger on BoostType to render the label).
        if dcType:find("VMBoost") then
            local name = dcProps.Name or ""
            local parts = {}
            if name ~= "" then parts[#parts + 1] = name end

            -- Boost type label (Proficiency / Expertise).
            local boostType = dcProps.BoostType
            if boostType and boostType ~= "" then
                if boostType == "ProficiencyBonus" then
                    parts[#parts + 1] = "Proficiency"
                elseif boostType == "ExpertiseBonus" then
                    parts[#parts + 1] = "Expertise"
                end
            end

            -- Numeric value ("+3", "-1").
            local value = dcProps.Value
            if value and value ~= "" and value ~= "0" then
                local numericValue = tonumber(value)
                if numericValue and numericValue > 0 then
                    parts[#parts + 1] = "+" .. value
                elseif numericValue then
                    parts[#parts + 1] = value
                end
            end

            -- Dice bonus ("+1d4" from Guidance, etc.).
            local diceTypeSet = dcProps.DiceTypeSet
            if diceTypeSet and type(diceTypeSet) == "table" then
                local diceStr = diceTypeSet.Str
                if diceStr and diceStr ~= "" then
                    parts[#parts + 1] = "+" .. diceStr
                end
            end

            if #parts > 0 then
                local itemSpeech = SpeechData.Create()
                itemSpeech:Add("name",
                    table.concat(parts, " "), "brief")
                return itemSpeech
            end

            -- Debug: log dcProps when VMBoost produces no text.
            local propDump = {}
            for propName, propValue in pairs(dcProps) do
                propDump[#propDump + 1] = propName .. "="
                    .. tostring(propValue)
            end
            Log.Warn("VMBoost empty: " .. table.concat(propDump, " | "))
        end

        -- VMAdvantage: advantage/disadvantage + reason.
        if dcType:find("VMAdvantage") then
            local advantageType = dcProps.AdvantageType or ""
            local description = dcProps.Description or ""
            if advantageType ~= "" then
                local itemSpeech = SpeechData.Create()
                local advantageText = advantageType
                if description ~= ""
                    and not description:match("^h%x+g") then
                    advantageText = advantageType .. ": " .. description
                end
                itemSpeech:Add("name", advantageText, "brief")
                return itemSpeech
            end
        end

        -- VMCharacterAction: spell/action name.
        if dcType:find("VMCharacterAction") then
            local name = dcProps.Name
            if name and name ~= ""
                and not name:match("^h%x+g") then
                local itemSpeech = SpeechData.Create()
                itemSpeech:Add("name", name, "brief")
                return itemSpeech
            end
        end

        -- VMPassive: passive feature name.
        if dcType:find("VMPassive") then
            local name = dcProps.Name
            if name and name ~= ""
                and not name:match("^h%x+g") then
                local itemSpeech = SpeechData.Create()
                itemSpeech:Add("name", name, "brief")
                return itemSpeech
            end
        end

        -- Other types: fall through to generic pipeline.
        return nil
    end,
})

-- Reaction ability decision popup during combat.
-- Appears when the player can use a reaction (Opportunity Attack, Counterspell,
-- etc.) on an enemy turn.  Focus lands on VMInterruptDecision items.
local ReactionHandler = CreatePanelHandler({
    name = "Reaction",
    hint = "A to use reaction. B to skip all.",
    customItemFn = function(focusedElement, handlerState, snapshot)
        local dcProps = focusedElement.dcProps
        if not dcProps then return nil end

        local dcType = focusedElement.dcType or ""

        -- VMInterruptDecision: the actual reaction choice.
        -- Interrupt is a sub-object with Name property.
        if dcType:find("VMInterruptDecision")
            or dcType:find("InterruptDecision") then
            local interrupt = dcProps.Interrupt
            if interrupt and type(interrupt) == "table" then
                local interruptName = interrupt.Name
                if interruptName and interruptName ~= ""
                    and not interruptName:match("^h%x+g") then
                    return interruptName
                end
            end
            -- Fallback: top-level Name.
            local name = dcProps.Name
            if name and name ~= ""
                and not name:match("^h%x+g") then
                return name
            end
        end

        -- VMInterruptor: character header in multi-char scenarios.
        -- Contains Character sub-object.
        if dcType:find("VMInterruptor") then
            local character = dcProps.Character
            if character and type(character) == "table" then
                local charName = character.Name
                    or character.CharacterName
                    or character.DisplayName
                if charName and charName ~= ""
                    and not charName:match("^h%x+g") then
                    return charName
                end
            end
        end

        -- Fall through to generic pipeline.
        return nil
    end,
})

-- Alchemy crafting (recipes and ingredients).
local AlchemyHandler = CreatePanelHandler({
    name = "Alchemy",
    hint = "Up and down to browse recipes.",
})

-- Item combination crafting.
local CombineHandler = CreatePanelHandler({
    name = "Combine",
    hint = false,
})

-- Give items to NPC.
local DonateHandler = CreatePanelHandler({
    name = "Donate",
    hint = false,
})

-- Pickpocket item selection.
local PickpocketHandler = CreatePanelHandler({
    name = "Pickpocket",
    hint = false,
})

-- Spell scroll learning.
local LearnSpellsHandler = CreatePanelHandler({
    name = "LearnSpells",
    hint = false,
})

-- Camp supplies / long rest.
local CampHandler = CreatePanelHandler({
    name = "Camp",
    hint = false,
})

-- Quest log with categories (tabbed).
local JournalQuestsHandler = CreatePanelHandler({
    name = "JournalQuests",
    hint = "Use bumpers to switch categories."
        .. " Up and down to browse entries.",
    customItemFn = function(focusedElement, handlerState, snapshot)
        local dcType = focusedElement.dcType
        local dcProps = focusedElement.dcProps
        local elemId = focusedElement.elemId or ""

        -- Tab ListBoxItem: suppress as item.
        if elemId:find("^ListBoxItem::") then
            return "", nil, nil
        end

        -- Quest category expander (ls.QuestCategoryContainer):
        -- QuestCategory sub-object has Description property.
        if dcType == "ls.QuestCategoryContainer" and dcProps then
            local categoryName = nil
            if type(dcProps.QuestCategory) == "table" then
                categoryName = dcProps.QuestCategory.Description
            end
            if not categoryName or categoryName == "" then
                -- Fallback: read text blocks from the expander.
                local readOk, headerTexts = pcall(
                    Ext.UI.ReadFocusedTextBlocks)
                if readOk and headerTexts and #headerTexts > 0 then
                    categoryName = Helpers.StripMarkupTags(
                        headerTexts[1])
                end
            end
            if categoryName and categoryName ~= "" then
                categoryName = Helpers.GetTranslatedStringIfHandle(
                    categoryName)
                if categoryName and categoryName ~= "" then
                    local isChecked = focusedElement.isChecked
                    if isChecked == true then
                        categoryName = categoryName .. ", expanded"
                    elseif isChecked == false then
                        categoryName = categoryName .. ", collapsed"
                    end
                    return categoryName, nil, nil
                end
            end
            return "", nil, nil
        end

        -- Quest entry expander (ls.QuestView):
        -- Quest sub-object has Title, IsDisabled properties.
        if dcType == "ls.QuestView" and dcProps then
            local questTitle = nil
            local questCompleted = false
            if type(dcProps.Quest) == "table" then
                questTitle = dcProps.Quest.Title
                questCompleted = dcProps.Quest.IsDisabled == "True"
                    or dcProps.Quest.IsDisabled == true
            end
            if not questTitle or questTitle == "" then
                questTitle = dcProps.Text or dcProps.Name
                    or dcProps.Title
                if type(questTitle) == "table" then
                    questTitle = questTitle.Str or questTitle.Text
                        or questTitle.Name or nil
                end
            end
            if not questTitle or questTitle == "" then
                -- Fallback: read text blocks.
                local readOk, headerTexts = pcall(
                    Ext.UI.ReadFocusedTextBlocks)
                if readOk and headerTexts and #headerTexts > 0 then
                    questTitle = Helpers.StripMarkupTags(
                        headerTexts[1])
                end
            end
            if questTitle and questTitle ~= "" then
                questTitle = Helpers.GetTranslatedStringIfHandle(
                    questTitle)
                if questTitle and questTitle ~= "" then
                    if questCompleted then
                        questTitle = questTitle .. ", completed"
                    end
                    -- Update indicator.
                    local hasUpdate = dcProps.HasPlayerSeenLastUpdate
                    if hasUpdate == "False" or hasUpdate == false then
                        questTitle = questTitle .. ", new update"
                    end
                    local isChecked = focusedElement.isChecked
                    if isChecked == true then
                        questTitle = questTitle .. ", expanded"
                    elseif isChecked == false then
                        questTitle = questTitle .. ", collapsed"
                    end
                    return questTitle, nil, nil
                end
            end
            return "", nil, nil
        end

        -- Quest objective (ls.QuestObjective):
        -- Has Description property directly.
        if dcType == "ls.QuestObjective" and dcProps then
            local objectiveText = dcProps.Description
            if type(objectiveText) == "table" then
                objectiveText = objectiveText.Str or objectiveText.Text
                    or nil
            end
            if objectiveText and objectiveText ~= "" then
                objectiveText = Helpers.GetTranslatedStringIfHandle(
                    objectiveText)
                objectiveText = Helpers.StripMarkupTags(objectiveText)
                return "Objective: " .. objectiveText, nil, nil
            end
            -- Fallback: text blocks.
            local readOk, texts = pcall(
                Ext.UI.ReadFocusedTextBlocks)
            if readOk and texts and #texts > 0 then
                local text = Helpers.StripMarkupTags(texts[1])
                if text and text ~= "" then
                    return "Objective: " .. text, nil, nil
                end
            end
            return "", nil, nil
        end

        -- Quest step (ls.QuestStep):
        -- Has Description and IsCompleted properties.
        if dcType == "ls.QuestStep" and dcProps then
            local stepText = dcProps.Description
            if type(stepText) == "table" then
                stepText = stepText.Str or stepText.Text or nil
            end
            if stepText and stepText ~= "" then
                stepText = Helpers.GetTranslatedStringIfHandle(
                    stepText)
                stepText = Helpers.StripMarkupTags(stepText)
                local isCompleted = dcProps.IsCompleted == "True"
                    or dcProps.IsCompleted == true
                if isCompleted then
                    stepText = stepText .. ", completed"
                end
                return stepText, nil, nil
            end
            return "", nil, nil
        end

        -- Generic expander button fallback.
        if elemId:find("ExpanderButton") then
            local readOk, headerTexts = pcall(
                Ext.UI.ReadFocusedTextBlocks)
            if readOk and headerTexts and #headerTexts > 0 then
                local headerName = Helpers.StripMarkupTags(
                    headerTexts[1])
                if headerName and headerName ~= "" then
                    local isChecked = focusedElement.isChecked
                    if isChecked == true then
                        headerName = headerName .. ", expanded"
                    elseif isChecked == false then
                        headerName = headerName .. ", collapsed"
                    end
                    return headerName, nil, nil
                end
            end
            return "", nil, nil
        end

        -- Fall through to generic pipeline.
        return nil
    end,
    customTooltipFn = function(tooltipTexts, focusedDCType,
                               handlerState)
        if not tooltipTexts or #tooltipTexts == 0 then return nil end
        -- Quest entries: build SpeechData from roles for full detail.
        if focusedDCType == "ls.QuestView" then
            local speechData = SpeechData.FromTooltip(tooltipTexts)
            speechData:RelabelProperty("Property", "Info")
            if next(speechData.coreFields) == nil
                and #speechData.properties == 0 then return nil end
            return speechData
        end
        -- Categories and objectives: suppress (already spoken).
        if focusedDCType == "ls.QuestCategoryContainer"
            or focusedDCType == "ls.QuestObjective"
            or focusedDCType == "ls.QuestStep" then
            return ""
        end
        return nil
    end,
})

-- Dialogue history with portraits.
local JournalDialoguesHandler = CreatePanelHandler({
    name = "JournalDialogues",
    hint = false,
})

-- Illithid power tree progression.
local TadpoleHandler = CreatePanelHandler({
    name = "TadpolePowers",
    hint = false,
})

-- Ground item or equipment slot picker.
-- C++ post-processor extracts ObjectCollectionList[0].Title as
-- "CollectionTitle" (e.g. "Search Results").  PanelContentType
-- distinguishes "Item" from "Spell" for context-appropriate hints.
-- Uses customItemFn returning SpeechData for custom speech order:
-- title, item name, value, desc, then context-appropriate hints.
-- Speech on entry: "Search Results. Brine Bulb. A to attack. X for actions. B to close."
-- Speech on nav:   "Brine Bulb."
local SelectionFlyOutHandler = CreatePanelHandler({
    name = "SelectionFlyOut",
    hint = false,
    onWidgetAdded = function(widgetData, handlerState)
        if widgetData.dcProps then
            handlerState.collectionTitle =
                widgetData.dcProps.CollectionTitle
                or widgetData.dcProps.Title
            handlerState.panelContentType =
                widgetData.dcProps.PanelContentType
        end
    end,
    onReset = function(handlerState)
        handlerState.collectionTitle = nil
        handlerState.panelContentType = nil
    end,
    customItemFn = function(focusedElement, handlerState, snapshot)
        -- Build SpeechData with custom ordering: title, item, value,
        -- desc, then hint (hint AFTER item name, not before).
        local speechData = SpeechData.Create()

        -- Title (screen entry only -- collection title from C++).
        -- Note: HandleSnapshot already consumed pendingWidgetEvent, so
        -- check widgetEvents directly for the "widget added this tick"
        -- signal used to gate the screen-entry title.
        local hasWidgetThisTick = snapshot.widgetEvents
            and #snapshot.widgetEvents > 0
        local isScreenEntry = snapshot.selectionChanged
            or (hasWidgetThisTick and not handlerState.lastSpokenTab)
            or (snapshot.focusChanged and focusedElement.isTab)
        if isScreenEntry and handlerState.collectionTitle then
            speechData:Add("title", handlerState.collectionTitle, "brief")
        end

        -- Item name from generic extraction.
        local itemName, itemValue, itemDesc =
            Helpers.FormatDCTextSplit(focusedElement.dcProps,
                focusedElement.dcType)
        if not itemName or itemName == "" then
            itemName = Helpers.ExtractTextFromData(
                focusedElement, handlerState.lastSpokenTab, isScreenEntry)
        end
        if itemName and itemName ~= "" then
            speechData:Add("name", itemName, "brief")
        end
        if itemValue and itemValue ~= "" then
            speechData:Add("value", itemValue, "brief")
        end
        if itemDesc and itemDesc ~= "" then
            speechData:Add("description", itemDesc, "verbose")
        end

        -- Hint AFTER item name (first visit only).
        if isScreenEntry and not handlerState.tabHintSpoken then
            handlerState.tabHintSpoken = true
            local hintText
            if handlerState.panelContentType == "Spell" then
                hintText = "A to cast. X for actions. B to close"
            else
                hintText = "A to attack. X for actions. B to close"
            end
            speechData:Add("instructionHint", hintText, "normal")
        end

        return speechData
    end,
})

-- Quest or encounter reward selection.
local RewardHandler = CreatePanelHandler({
    name = "Reward",
    hint = false,
})

-- Save name input dialog ("Create New Save" popup).
-- namedTexts carry TitleContainer and SubtitleContainer from XAML.
-- Buttons: A to save, Y to rename, B to cancel.
local SavePopupHandler = CreatePanelHandler({
    name = "SavePopup",
    hint = "A to save. Y to rename. B to cancel.",
    customItemFn = function(focusedElement, snapshot, effectiveTab,
                            handlerState)
        if focusedElement.elemType
            and focusedElement.elemType:find("TextBox") then
            return "Using your keyboard, type a name for this save."
                .. " Press A to save, or B to cancel.", nil, nil
        end
        return nil, nil, nil
    end,
    onWidgetAdded = function(widgetData, handlerState)
        -- Extract title from namedTexts (TitleContainer = "Create New Save").
        if widgetData and widgetData.namedTexts then
            local title = widgetData.namedTexts.TitleContainer
            if title and title ~= ""
                and not title:match("^h%x+g")
                and not title:find("%[ForceUpdate%]") then
                handlerState.titleOverride = title
            end
        end
    end,
})

-- Honour mode death memorial.
local HonourHandler = CreatePanelHandler({
    name = "Honour",
    hint = false,
})

-- Online / crossplay settings (in-game).
local ConnectivityHandler = CreatePanelHandler({
    name = "Connectivity",
    hint = false,
})

-- Larian account sign-up.
local SignUpHandler = CreatePanelHandler({
    name = "SignUp",
    hint = false,
})

-- Sensitive content settings (nudity, gore).
local FirstTimeSetupHandler = CreatePanelHandler({
    name = "FirstTimeSetup",
    hint = false,
})

-- HDR calibration.
local HDRHandler = CreatePanelHandler({
    name = "HDR",
    hint = false,
})

-- Gamma / brightness calibration.
local GammaHandler = CreatePanelHandler({
    name = "Gamma",
    hint = false,
})

-- Crossplay player report form.
local ReportHandler = CreatePanelHandler({
    name = "Report",
    hint = false,
})

-- Party portraits (LT from world HUD).
-- Shows party members with name, level, class, HP, reactions, level-up.
-- Uses text blocks from the portrait for structured speech since the
-- CharacterPortrait template is precompiled and dcProps are minimal.
local PartyLineHandler = CreatePanelHandler({
    name = "PartyLine",
    hint = "Up and down to browse party members."
        .. " RB to level up if available.",
    customItemFn = function(focusedElement, handlerState, snapshot)
        local dcType = focusedElement.dcType
        local dcProps = focusedElement.dcProps
        local elemId = focusedElement.elemId or ""

        -- Party member character entry.
        if dcType == "ls.Character" and dcProps then
            local speechData = SpeechData.Create()

            -- Character name from dcProps.
            local charName = dcProps.Name or dcProps.CharacterName
                or dcProps.DisplayName
            if charName and charName ~= "" then
                speechData:Add("name", charName, "brief")
            end

            -- Read text blocks for level/class and other info.
            -- CleanTooltipText handles markup strip, trailing punct,
            -- Inspect/Close/OK junk filter, and numeric-only reject.
            -- HP "10/10" would be rejected as numeric-only, so we
            -- check that pattern BEFORE CleanTooltipText.
            local readOk, textBlocks = pcall(
                Ext.UI.ReadFocusedTextBlocks)
            if readOk and textBlocks then
                for _, text in ipairs(textBlocks) do
                    local raw = text and
                        Helpers.StripMarkupTags(text) or nil
                    if raw and raw:match("^%d+/%d+$") then
                        speechData:AddProperty("HP", raw, "normal")
                    else
                        local cleaned = SpeechData.CleanTooltipText(text)
                        if cleaned and cleaned ~= charName then
                            if cleaned:match("^Lv %d+") then
                                -- Strip "Lv " prefix; label supplies
                                -- the context ("Level: 1 Rogue").
                                local levelValue = cleaned:gsub(
                                    "^Lv%s+", "")
                                speechData:AddProperty("Level",
                                    levelValue, "brief")
                            elseif cleaned == "Level Up" then
                                speechData:Add("status",
                                    "Level Up available", "brief")
                            elseif cleaned ~= "Reactions" then
                                speechData:AddProperty("Reaction",
                                    cleaned, "verbose")
                            end
                        end
                    end
                end
            end

            if next(speechData.coreFields) ~= nil
                or #speechData.properties > 0 then
                return speechData
            end
        end

        -- Fall through to generic pipeline.
        return nil
    end,
    customTooltipFn = function(tooltipTexts, focusedDCType,
                               handlerState)
        -- Party member tooltip.  XAML roles available:
        --   TitleArea -> name (handler already spoke; cross-off)
        --   ClassAndLevel -> AddProperty("Level", "Lv 1 Rogue")
        --     (customItemFn already added this; cross-off skips)
        --   Root -> individual reactions (Opportunity Attack, etc.)
        --   "" (empty) -> header labels and "Level Up" marker
        -- FromTooltip handles named roles + cross-off.  Post-
        -- processing collapses the "Root" reactions into a count
        -- and scans empty-role text for the Level Up marker.
        if focusedDCType == "ls.Character" and tooltipTexts then
            local spokenRoles = handlerState
                and handlerState.spokenRoles or nil
            local speechData = SpeechData.FromTooltip(
                tooltipTexts, spokenRoles)

            -- Count Root reactions and detect Level Up BEFORE
            -- removing those properties (the removal happens via
            -- RemoveProperties below).  Level Up text arrives under
            -- the generic "txt" x:Name which FromTooltip passes
            -- through as AddProperty("txt", ...).
            local reactionCount = 0
            local levelUpFound = false
            for _, prop in ipairs(speechData.properties) do
                if prop.label == "Root" then
                    reactionCount = reactionCount + 1
                elseif prop.label == "txt"
                    and prop.value:find("Level Up", 1, true) then
                    levelUpFound = true
                end
            end
            -- Drop the raw Root and Level-Up-txt entries; replace
            -- with semantic equivalents (status, Reactions count).
            speechData:RemoveProperties(function(prop)
                if prop.label == "Root" then return true end
                if prop.label == "txt"
                    and prop.value:find("Level Up", 1, true) then
                    return true
                end
                return false
            end)
            if levelUpFound then
                speechData:Add("status",
                    "Level Up available", "brief")
            end
            if reactionCount > 0 then
                speechData:AddProperty("Reactions",
                    tostring(reactionCount) .. " reactions active",
                    "normal")
            end

            if next(speechData.coreFields) ~= nil
                or #speechData.properties > 0 then
                return speechData
            end
        end
        return nil
    end,
    buildDetailList = function(focusedData, tooltipTexts)
        if not focusedData then return nil end
        if focusedData.dcType ~= "ls.Character" then return nil end

        local detailList = {}
        local dcProps = focusedData.dcProps

        -- Name.
        if dcProps then
            local charName = dcProps.Name or dcProps.CharacterName
                or dcProps.DisplayName
            if charName and charName ~= "" then
                detailList[#detailList + 1] = {
                    label = "Name", value = charName}
            end
        end

        -- Build remaining fields via shared FromTooltip mapping.
        -- Level from ClassAndLevel role; reactions from Root roles.
        if tooltipTexts then
            local speechData = SpeechData.FromTooltip(tooltipTexts)
            -- Extract Reaction, Level, and Level Up from properties.
            -- "Level Up" text arrives under the "txt" x:Name which
            -- FromTooltip passes through as AddProperty("txt", ...).
            for _, prop in ipairs(speechData.properties) do
                if prop.label == "Root" then
                    detailList[#detailList + 1] = {
                        label = "Reaction", value = prop.value}
                elseif prop.label == "Level" then
                    detailList[#detailList + 1] = {
                        label = "Level", value = prop.value}
                elseif prop.label == "txt"
                    and prop.value:find("Level Up", 1, true) then
                    detailList[#detailList + 1] = {
                        label = "Level Up", value = "Available"}
                end
            end
        end

        -- HP from elemId (e.g., "10/10").
        local elemId = focusedData.elemId or ""
        local currentHP, maxHP = elemId:match("(%d+)/(%d+)")
        if currentHP and maxHP then
            detailList[#detailList + 1] = {
                label = "HP",
                value = currentHP .. " of " .. maxHP}
        end

        if #detailList == 0 then return nil end
        return detailList
    end,
})

-- Multiplayer lobby room (different from lobby browser in Menus).
local LobbyHandler = CreatePanelHandler({
    name = "Lobby",
    hint = false,
})

-- Tutorial popup (modal tips explaining game mechanics).
-- DCTutorial has Tutorial sub-object with Title and DescriptionController.
-- The description uses CtxTransStringRunGeneratorBehavior which means the
-- rendered text includes controller button placeholders -- we extract what
-- we can from dcProps and namedTexts.
local TutorialHandler = CreatePanelHandler({
    name = "Tutorial",
    hint = "A to dismiss.",
    onWidgetAdded = function(widgetData, handlerState)
        -- Title from Tutorial sub-object in dcProps.
        local dcProps = widgetData and widgetData.dcProps
        if dcProps then
            local tutorial = dcProps.Tutorial
            if tutorial and type(tutorial) == "table" then
                local title = tutorial.Title
                if title and title ~= ""
                    and not title:match("^h%x+g")
                    and not title:find("%[ForceUpdate%]") then
                    handlerState.titleOverride = "Tutorial: " .. title
                end
                local description = tutorial.DescriptionController
                    or tutorial.Description
                if description and description ~= ""
                    and not description:match("^h%x+g")
                    and not description:find("%[ForceUpdate%]") then
                    handlerState.bodyOverride = description
                end
            end
            -- Fallback: top-level Title/Text from dcProps.
            if not handlerState.titleOverride then
                local title = dcProps.Title or dcProps.Text
                if title and title ~= ""
                    and not title:match("^h%x+g") then
                    handlerState.titleOverride = "Tutorial: " .. title
                end
            end
        end

        -- Also try namedTexts for rendered TextBlock content.
        if widgetData and widgetData.namedTexts
            and not handlerState.titleOverride
            and not handlerState.bodyOverride then
            local parts = {}
            for elementName, elementText in pairs(widgetData.namedTexts) do
                if elementText and elementText ~= ""
                    and not elementText:match("^h%x+g")
                    and not elementText:find("%[ForceUpdate%]") then
                    parts[#parts + 1] = elementText
                end
            end
            if #parts > 0 then
                handlerState.titleOverride = "Tutorial"
                handlerState.bodyOverride = table.concat(parts, ". ")
            end
        end

        if handlerState.titleOverride or handlerState.bodyOverride then
            Log.Info("TUTORIAL: title="
                .. tostring(handlerState.titleOverride)
                .. " body="
                .. tostring(handlerState.bodyOverride
                    and handlerState.bodyOverride:sub(1, 60)))
        end
    end,
    customItemFn = function(focusedElement, snapshot, tabName,
                            handlerState)
        -- Tutorial body arrives on the tick AFTER screen entry
        -- (dcProps not populated on the widget event tick).
        -- Check dcProps each tick for the Tutorial sub-object.
        local dcProps = focusedElement and focusedElement.dcProps
        if not dcProps then return nil, nil, nil end
        local tutorial = dcProps.Tutorial
        if not tutorial or type(tutorial) ~= "table" then
            return nil, nil, nil
        end
        local title = tutorial.Title
        if title and (title:match("^h%x+g")
            or title:find("%[ForceUpdate%]")) then
            title = nil
        end
        local body = tutorial.DescriptionController
            or tutorial.Description
        if body and (body:match("^h%x+g")
            or body:find("%[ForceUpdate%]")) then
            body = nil
        end
        if title then title = "Tutorial: " .. title end
        if body then body = Helpers.StripMarkupTags(body) end
        return title, nil, body
    end,
})

-- Map / waypoint fast travel.
-- ls.JournalMap is the map widget.  When the user presses Y (Fast
-- Travel), a waypoint panel opens with focusable ls.VMWaypoint items.
-- D-pad navigates, A teleports.  The map image itself is not accessible
-- but the waypoint list provides the core fast travel functionality.
local MapHandler = CreatePanelHandler({
    name = "Map",
    hint = "Press Y for fast travel waypoints. Press A to travel. "
        .. "B to close.",
    onWidgetAdded = function(widgetData, handlerState)
        -- Read current region from namedTexts.
        if widgetData and widgetData.namedTexts then
            local regionName =
                widgetData.namedTexts.SubRegionName
            if regionName and regionName ~= "" then
                handlerState.titleOverride = regionName
            end
        end
    end,
    customItemFn = function(focusedElement, snapshot, tabName,
                            handlerState)
        -- Waypoint items: read the Name property.
        if not focusedElement then return nil, nil, nil end
        local dcProps = focusedElement.dcProps
        if not dcProps then return nil, nil, nil end

        local waypointName = dcProps.Name
            or dcProps.DisplayName or dcProps.Title
        if not waypointName or waypointName == "" then
            waypointName = focusedElement.elemText
        end
        if not waypointName or waypointName == "" then
            return nil, nil, nil
        end
        waypointName = Helpers.StripMarkupTags(waypointName)

        -- Announce "Waypoints" once when the waypoint panel
        -- opens (first VMWaypoint focus).
        if focusedElement.dcType == "ls.VMWaypoint"
            and not handlerState.waypointsAnnounced then
            handlerState.waypointsAnnounced = true
            return "Waypoints. " .. waypointName, nil, nil
        end

        return waypointName, nil, nil
    end,
})

-- Book / document viewer.
-- DCBook has BookFullText bound to an LSBook control.  BookFullText is
-- the entire book content.  BookType determines the visual style.
-- The LSBook control handles pagination internally (HasPrevPage/HasNextPage).
-- Body text is in BookFullText -- a single large string.
--- SplitBookLines: split raw BookFullText into navigable lines.
--- Splits on <br> tags and --- section separators.  Trims whitespace.
--- Returns an array of non-empty line strings.
local function SplitBookLines(rawText)
    if not rawText or rawText == "" then return {} end
    -- Replace <br> and <br/> with newline, then split.
    local normalized = rawText:gsub("<br%s*/?>", "\n")
    -- Strip any remaining markup tags.
    normalized = normalized:gsub("<[^>]+>", " ")
    local lines = {}
    for line in normalized:gmatch("[^\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then
            lines[#lines + 1] = trimmed
        end
    end
    return lines
end

--- OpenBookReader: set up line-by-line reading with d-pad navigation.
--- Speaks the first line and subscribes to d-pad input.
local function OpenBookReader(handlerState)
    if not handlerState.bookLines
        or #handlerState.bookLines == 0 then
        return
    end

    handlerState.bookLineIndex = 0
    local lineCount = #handlerState.bookLines
    Log.Info("BOOK: " .. lineCount .. " lines")
    local speechData = SpeechData.Create()
    speechData:Add("description", "Book viewer. Use d-pad up and down"
        .. " to move line by line through the text.", "brief")
    speechData:AddProperty("Lines", lineCount .. " lines.", "normal")
    speechData:Add("instructionHint",
        "A to pick up. B to close.", "normal")
    speechData:Speak(handlerState, true)

    -- Subscribe to d-pad for line navigation (once).
    if not handlerState.buttonSubscription then
        handlerState.buttonSubscription =
            Ext.Events.ControllerButtonInput:Subscribe(function(event)
                if not event.Pressed then return end
                local buttonName = tostring(event.Button)

                if buttonName == "DPadDown" then
                    event:PreventAction()
                    local bookLines = handlerState.bookLines
                    if not bookLines then return end
                    local currentIndex = handlerState.bookLineIndex
                    if currentIndex >= #bookLines then
                        local endSpeech = SpeechData.Create()
                        endSpeech:Add("status",
                            "End of text", "brief")
                        endSpeech:Speak(handlerState, false, nil, true)
                        return
                    end
                    currentIndex = currentIndex + 1
                    handlerState.bookLineIndex = currentIndex
                    Log.Info("BOOK [" .. currentIndex .. "/"
                        .. #bookLines .. "]: "
                        .. bookLines[currentIndex]:sub(1, 60))
                    local lineSpeech = SpeechData.Create()
                    lineSpeech:Add("description",
                        bookLines[currentIndex], "brief")
                    lineSpeech:Speak(handlerState, false, nil, true)

                elseif buttonName == "DPadUp" then
                    event:PreventAction()
                    local bookLines = handlerState.bookLines
                    if not bookLines then return end
                    local currentIndex = handlerState.bookLineIndex
                    if currentIndex <= 1 then
                        local beginSpeech = SpeechData.Create()
                        beginSpeech:Add("status",
                            "Beginning of text", "brief")
                        beginSpeech:Speak(handlerState, false, nil, true)
                        return
                    end
                    currentIndex = currentIndex - 1
                    handlerState.bookLineIndex = currentIndex
                    Log.Info("BOOK [" .. currentIndex .. "/"
                        .. #bookLines .. "]: "
                        .. bookLines[currentIndex]:sub(1, 60))
                    local lineSpeech = SpeechData.Create()
                    lineSpeech:Add("description",
                        bookLines[currentIndex], "brief")
                    lineSpeech:Speak(handlerState, false, nil, true)

                elseif buttonName == "DPadLeft"
                    or buttonName == "DPadRight" then
                    -- Block horizontal d-pad to prevent accidental
                    -- navigation while reading.
                    event:PreventAction()

                elseif buttonName == "B" then
                    -- Clean up the subscription and let B pass through
                    -- to the game to close the book widget.
                    if handlerState.buttonSubscription then
                        Ext.Events.ControllerButtonInput:Unsubscribe(
                            handlerState.buttonSubscription)
                        handlerState.buttonSubscription = nil
                    end
                    handlerState.bookLines = nil
                    handlerState.bookLineIndex = nil
                    Log.Info("BOOK: closed (B pressed)")
                end
            end)
    end
end

local BookHandler = CreatePanelHandler({
    name = "Book",
    hint = false,
    onWidgetAdded = function(widgetData, handlerState)
        -- Cache BookFullText and split into lines (normal widget path).
        local dcProps = widgetData and widgetData.dcProps
        if dcProps and not handlerState.bookLines then
            local bookText = dcProps.BookFullText
            if bookText and bookText ~= ""
                and not bookText:match("^h%x+g")
                and not bookText:find("%[ForceUpdate%]") then
                handlerState.bookLines = SplitBookLines(bookText)
                OpenBookReader(handlerState)
            end
        end
    end,
    onReset = function(handlerState)
        if handlerState.buttonSubscription then
            Ext.Events.ControllerButtonInput:Unsubscribe(
                handlerState.buttonSubscription)
            handlerState.buttonSubscription = nil
        end
        handlerState.bookLines = nil
        handlerState.bookLineIndex = nil
    end,
    customItemFn = function(focusedElement, handlerState, snapshot)
        -- Discovery path fallback: onWidgetAdded gets synthetic
        -- widgetData without dcProps.  The snapshot widget events
        -- carry the real data.  Iterate to find any event with
        -- BookFullText in its dcProps.
        if not handlerState.bookLines and snapshot.widgetEvents then
            for _, widgetEvent in ipairs(snapshot.widgetEvents) do
                if widgetEvent.dcProps
                    and widgetEvent.dcProps.BookFullText then
                    local bookText = widgetEvent.dcProps.BookFullText
                    if bookText and bookText ~= ""
                        and not bookText:match("^h%x+g")
                        and not bookText:find("%[ForceUpdate%]") then
                        handlerState.bookLines = SplitBookLines(bookText)
                        OpenBookReader(handlerState)
                        break
                    end
                end
            end
        end
        -- Always return an empty SpeechData to suppress the generic
        -- pipeline entirely (including namedTexts visual text noise
        -- like "Close", "Pick up", "Turn Page").  The book reader
        -- handles all speech directly.
        return SpeechData.Create()
    end,
})

-- ============================================================================
-- Panel DC type routing table
-- ============================================================================

-- Normalize a DC type string by stripping the namespace prefix.
-- Runtime types use either "gui::" or "ls." depending on the class.
local function NormalizeDCType(dcType)
    if not dcType then return nil end
    return dcType:gsub("^gui::", ""):gsub("^ls%.", "")
end

local DC_TYPE_HANDLERS = {
    -- Character sheet / inventory
    ["gui::DCCharacterPanels"]    = CharacterPanelHandler,
    ["ls.DCCharacterPanels"]      = CharacterPanelHandler,
    -- Trading
    ["gui::DCTrade"]              = TradeHandler,
    ["ls.DCTrade"]                = TradeHandler,
    -- Container inventory (bags, pouches)
    ["gui::DCContainerInventory"] = ContainerHandler,
    ["ls.DCContainerInventory"]   = ContainerHandler,
    -- Examine / inspect (widget DC is generic ls.Widget, so discovery
    -- uses focused element DC types: VMRangeStat, VMResistance, etc.)
    ["gui::DCExamine"]            = ExamineHandler,
    ["ls.DCExamine"]              = ExamineHandler,
    ["gui::VMRangeStat"]          = ExamineHandler,
    ["ls.VMRangeStat"]            = ExamineHandler,
    ["gui::VMResistance"]         = ExamineHandler,
    ["ls.VMResistance"]           = ExamineHandler,
    -- Dice rolls and reactions
    ["gui::DCActiveRoll"]         = ActiveRollHandler,
    ["ls.DCActiveRoll"]           = ActiveRollHandler,
    ["gui::DCReactionDecision"]   = ReactionHandler,
    ["ls.DCReactionDecision"]     = ReactionHandler,
    -- Crafting
    ["gui::DCAlchemy"]            = AlchemyHandler,
    ["ls.DCAlchemy"]              = AlchemyHandler,
    ["gui::DCCombine"]            = CombineHandler,
    ["ls.DCCombine"]              = CombineHandler,
    -- Item transfer
    ["gui::DCDonate"]             = DonateHandler,
    ["ls.DCDonate"]               = DonateHandler,
    ["gui::DCPickpocket"]         = PickpocketHandler,
    ["ls.DCPickpocket"]           = PickpocketHandler,
    ["gui::DCLearnSpells"]        = LearnSpellsHandler,
    ["ls.DCLearnSpells"]          = LearnSpellsHandler,
    -- Spell book / actions
    ["gui::VMSpellBook"]          = SpellBookHandler,
    ["ls.VMSpellBook"]            = SpellBookHandler,
    -- Camp / rest
    ["gui::DCMakeCamp"]           = CampHandler,
    ["ls.DCMakeCamp"]             = CampHandler,
    -- Journal
    ["gui::DCJournalQuests"]      = JournalQuestsHandler,
    ["ls.DCJournalQuests"]        = JournalQuestsHandler,
    ["gui::DCJournalDialogues"]   = JournalDialoguesHandler,
    ["ls.DCJournalDialogues"]     = JournalDialoguesHandler,
    -- Illithid powers
    ["gui::DCTadpolePowersTree"]  = TadpoleHandler,
    ["ls.DCTadpolePowersTree"]    = TadpoleHandler,
    -- Selection / rewards
    ["gui::DCSelectionFlyOut"]    = SelectionFlyOutHandler,
    ["ls.DCSelectionFlyOut"]      = SelectionFlyOutHandler,
    ["gui::DCActiveSearch"]       = SelectionFlyOutHandler,
    ["ls.DCActiveSearch"]         = SelectionFlyOutHandler,
    ["gui::DCRewardPanel"]        = RewardHandler,
    ["ls.DCRewardPanel"]          = RewardHandler,
    -- Popups
    ["gui::DCNewSavegamePopup"]   = SavePopupHandler,
    ["ls.DCNewSavegamePopup"]     = SavePopupHandler,
    ["gui::DCProofOfHonour"]      = HonourHandler,
    ["ls.DCProofOfHonour"]        = HonourHandler,
    -- Settings (in-game)
    ["gui::DCConnectivityMenu"]   = ConnectivityHandler,
    ["ls.DCConnectivityMenu"]     = ConnectivityHandler,
    ["gui::DCSignUp"]             = SignUpHandler,
    ["ls.DCSignUp"]               = SignUpHandler,
    ["gui::DCFirstTimeSetup"]     = FirstTimeSetupHandler,
    ["ls.DCFirstTimeSetup"]       = FirstTimeSetupHandler,
    ["gui::DCHDRCalibration"]     = HDRHandler,
    ["ls.DCHDRCalibration"]       = HDRHandler,
    ["gui::DCGammaCalibration"]   = GammaHandler,
    ["ls.DCGammaCalibration"]     = GammaHandler,
    ["gui::DCReport"]             = ReportHandler,
    ["ls.DCReport"]               = ReportHandler,
    -- Party portraits (LT from world)
    ["gui::DCPartyLine"]          = PartyLineHandler,
    ["ls.DCPartyLine"]            = PartyLineHandler,
    -- Multiplayer lobby
    ["gui::DCLobby"]              = LobbyHandler,
    ["ls.DCLobby"]                = LobbyHandler,
    -- Tutorial popups
    ["gui::DCTutorial"]           = TutorialHandler,
    ["ls.DCTutorial"]             = TutorialHandler,
    -- Book / document viewer
    ["gui::DCBook"]               = BookHandler,
    ["ls.DCBook"]                 = BookHandler,
    -- Map / waypoint fast travel
    ["gui::DCJournalMap"]         = MapHandler,
    ["ls.JournalMap"]             = MapHandler,
}

-- All handler instances for batch reset.
local ALL_PANEL_HANDLERS = {
    CharacterPanelHandler,
    SpellBookHandler,
    TradeHandler,
    ContainerHandler,
    ExamineHandler,
    ActiveRollHandler,
    ReactionHandler,
    AlchemyHandler,
    CombineHandler,
    DonateHandler,
    PickpocketHandler,
    LearnSpellsHandler,
    CampHandler,
    JournalQuestsHandler,
    JournalDialoguesHandler,
    TadpoleHandler,
    SelectionFlyOutHandler,
    RewardHandler,
    SavePopupHandler,
    HonourHandler,
    ConnectivityHandler,
    SignUpHandler,
    FirstTimeSetupHandler,
    HDRHandler,
    GammaHandler,
    ReportHandler,
    PartyLineHandler,
    LobbyHandler,
    TutorialHandler,
    BookHandler,
    MapHandler,
}

-- ============================================================================
-- Panel routing (active handler tracking)
-- ============================================================================

-- activePanelHandler and lastFocusedDCType are forward-declared near
-- the top of this file (before DispatchTooltip) so that DispatchTooltip's
-- closure captures the same locals that the routing functions set.

-- Previous handler: saved when an overlay panel (Container, etc.)
-- takes over from the base panel (CharacterPanel, Trade, etc.).
-- Restored when the overlay disappears (widget set shrinks).
local previousPanelHandler = nil

-- Widget address (hex pointer string) of the widget the active handler
-- was activated against.  C++ emits snapshot.widgetAddrs (parallel to
-- snapshot.widgetDCTypes) so we can verify by identity, not DC type.
-- DC types lie for handlers whose top-level widget is generic
-- (ls.Widget) but whose nested content carries the distinctive DC
-- (ActiveRoll, SpellBook, etc.).  Widget addresses don't lie.
local activePanelHandlerWidgetAddr   = nil
local previousPanelHandlerWidgetAddr = nil


-- DC types that should only activate when the user explicitly focuses
-- or selects an element inside them (focusedElement/selectedElement),
-- never from widget scans or widgetDCTypes arrays.  These are HUD
-- elements that are always visible but only interactive when the user
-- navigates into them (e.g., LT for party).
local DISCOVERY_ONLY_DC_TYPES = {
    ["gui::DCPartyLine"] = true,
    ["ls.DCPartyLine"]   = true,
}

--- IsWorldDCType: returns true if the given DC type belongs to an
--- in-game panel handled by WorldUI.
--- @param dcType string  The DataContext type from a widget.
--- @return boolean
local function IsWorldDCType(dcType)
    if not dcType then return false end
    if DISCOVERY_ONLY_DC_TYPES[dcType] then return false end
    return DC_TYPE_HANDLERS[dcType] ~= nil
end


--- HandlePanelWidgetAdded: called by EventRouter when a WorldUI panel
--- widget appears.  Updates the active handler and calls its hook.
--- Saves the previous handler so overlays can restore it on close.
--- @param widgetData table  The widget data from the snapshot.
local function HandlePanelWidgetAdded(widgetData)
    if not widgetData or not widgetData.dcType then return end

    -- Skip discovery-only DC types: these are HUD widgets that fire
    -- on every scan but should only activate when focus enters them.
    if DISCOVERY_ONLY_DC_TYPES[widgetData.dcType] then return end

    local newHandler = DC_TYPE_HANDLERS[widgetData.dcType]
    if not newHandler then return end

    if newHandler ~= activePanelHandler then
        -- Close detail/compare views when active handler changes
        -- (overlay took over, tab switch, etc.) so their d-pad
        -- subscriptions don't persist into the new context.
        CloseDetailView(true)
        CloseCompareView(true)
        if activePanelHandler then
            -- Save for restoration when overlay closes.
            -- Do NOT reset the previous handler -- its state (tabHintSpoken,
            -- lastSpokenTab, etc.) must be preserved intact so the hint
            -- doesn't re-speak when the overlay closes and the handler is
            -- restored.
            previousPanelHandler = activePanelHandler
            previousPanelHandlerWidgetAddr = activePanelHandlerWidgetAddr
        end
        activePanelHandler = newHandler
        -- Anchor the handler to this specific widget's address.  Used
        -- by close detection to verify presence by identity, not by
        -- DC type.
        activePanelHandlerWidgetAddr = widgetData.widgetRootId
        Log.Info("Active panel: " .. activePanelHandler.name
            .. " (dc=" .. widgetData.dcType
            .. " widget=" .. tostring(activePanelHandlerWidgetAddr) .. ")")
    end

    activePanelHandler.HandleWidgetAdded(widgetData)
end

--- HandlePanelWidgetRootChanged: called by EventRouter when the widget
--- root changes while a WorldUI panel is active.
local function HandlePanelWidgetRootChanged()
    if activePanelHandler then
        activePanelHandler.ResetNavigation()
    end
end

--- RoutePanelSnapshot: called by EventRouter for all snapshots when
--- a WorldUI panel is active.
--- @param snapshot table  The full TickSnapshot from C++.
local function RoutePanelSnapshot(snapshot)
    -- Radial is active (RT shortcuts or RB action radial).  Radial slot
    -- changes are handled by HandleRadialSlot via EventRouter, not by
    -- panel discovery.  Skip discovery to avoid PartyLine or other
    -- background DC types activating a panel handler during radial use.
    if inRadial then return end

    if not activePanelHandler then
        -- Attempt handler discovery from snapshot data before falling
        -- back to Menus.  This handles panels whose widget DC type is
        -- generic (ls.Widget) but whose selected/focused element DC type
        -- identifies the panel (e.g., ls.VMSpellBook on the tab).
        local discoveredHandler = nil
        if snapshot.focusedElement and snapshot.focusedElement.dcType then
            discoveredHandler = DC_TYPE_HANDLERS[
                snapshot.focusedElement.dcType]
        end
        -- Selected element: tab ListBoxItems carry the panel DC type
        -- (e.g., ls.VMSpellBook) even when the focused element is a
        -- child action (ls.VMActionGroup, ls.VMCharacterAction).
        if not discoveredHandler
            and snapshot.selectedElement
            and snapshot.selectedElement.dcType then
            discoveredHandler = DC_TYPE_HANDLERS[
                snapshot.selectedElement.dcType]
        end
        -- Widget added on this tick: check widgetDCTypes for a
        -- non-discovery type first.  widgetData.dcType may have been
        -- overwritten by a background widget (PartyLine_c processed
        -- last by C++) so it cannot be trusted directly.
        if not discoveredHandler
            and snapshot.widgetAdded and snapshot.widgetDCTypes then
            for _, widgetDCType in ipairs(snapshot.widgetDCTypes) do
                if not DISCOVERY_ONLY_DC_TYPES[widgetDCType] then
                    discoveredHandler = DC_TYPE_HANDLERS[widgetDCType]
                    if discoveredHandler then break end
                end
            end
        end
        -- If no non-discovery handler found but a widget event this
        -- tick has a discovery type, allow it only when no HANDLED
        -- non-discovery type exists in widgetDCTypes.  Unhandled HUD
        -- types like gui::DCOverlay, gui::DCCombatants are always
        -- present and must not block genuine LT opens (PartyLineActive_c
        -- is the only HANDLED new widget, alongside unhandled HUD noise).
        if not discoveredHandler
            and snapshot.widgetAdded and snapshot.widgetEvents then
            local discoveryEvent = nil
            for _, widgetEvent in ipairs(snapshot.widgetEvents) do
                if widgetEvent.dcType
                    and DISCOVERY_ONLY_DC_TYPES[widgetEvent.dcType] then
                    discoveryEvent = widgetEvent
                    break
                end
            end
            if discoveryEvent then
                local hasHandledNonDiscovery = false
                if snapshot.widgetDCTypes then
                    for _, widgetDCType in ipairs(
                            snapshot.widgetDCTypes) do
                        if not DISCOVERY_ONLY_DC_TYPES[widgetDCType]
                            and DC_TYPE_HANDLERS[widgetDCType] then
                            hasHandledNonDiscovery = true
                            break
                        end
                    end
                end
                if not hasHandledNonDiscovery then
                    discoveredHandler = DC_TYPE_HANDLERS[
                        discoveryEvent.dcType]
                end
            end
        end
        -- Fallback: check all widget DC types from this tick, but
        -- skip discovery-only types (always-present HUD widgets).
        if not discoveredHandler and snapshot.widgetDCTypes then
            for _, widgetDCType in ipairs(snapshot.widgetDCTypes) do
                if not DISCOVERY_ONLY_DC_TYPES[widgetDCType] then
                    discoveredHandler = DC_TYPE_HANDLERS[widgetDCType]
                    if discoveredHandler then break end
                end
            end
        end
        if discoveredHandler then
            activePanelHandler = discoveredHandler
            -- Anchor to the widget that carried the identifying DC.
            -- Prefer focused, then selected, then the first matching
            -- widget in widgetDCTypes (fallback for widget-level
            -- discovery).  widgetRootId is set on every FocusEventData.
            activePanelHandlerWidgetAddr = nil
            if snapshot.focusedElement
                and snapshot.focusedElement.widgetRootId
                and snapshot.focusedElement.widgetRootId ~= "" then
                activePanelHandlerWidgetAddr =
                    snapshot.focusedElement.widgetRootId
            elseif snapshot.selectedElement
                and snapshot.selectedElement.widgetRootId
                and snapshot.selectedElement.widgetRootId ~= "" then
                activePanelHandlerWidgetAddr =
                    snapshot.selectedElement.widgetRootId
            elseif snapshot.widgetDCTypes and snapshot.widgetAddrs then
                for widgetIndex, widgetDCType in ipairs(
                        snapshot.widgetDCTypes) do
                    if DC_TYPE_HANDLERS[widgetDCType]
                            == discoveredHandler then
                        activePanelHandlerWidgetAddr =
                            snapshot.widgetAddrs[widgetIndex]
                        break
                    end
                end
            end
            Log.Info("Active panel (discovered): "
                .. activePanelHandler.name
                .. " widget=" .. tostring(activePanelHandlerWidgetAddr))
            -- Handler just activated -- deliver snapshot and return.
            -- Skip close detection on this snapshot: widgetDCTypes
            -- cache is stale (built early in tick before the widget
            -- became visible) and would falsely deactivate the handler.
            activePanelHandler.HandleSnapshot(snapshot)
            return
        else
            -- No WorldUI panel handler found.  Check if the snapshot
            -- contains a menu-worthy DC type (e.g., gui::DCGameMenu
            -- from the shortcuts menu).  Menus on separate visual
            -- layers don't generate widget events so they reach here
            -- with routeToWorld still true.  Only fall back to Menus
            -- when a genuine menu signal is present.  Without this
            -- guard, HUD widget text (Overlay, Actions, etc.) would
            -- be spoken as menu content when returning to the world
            -- after closing any panel.
            local Menus = BG3Access.Client.Menus
            if Menus then
                local hasMenuSignal = false
                -- Check focused element dcType.
                if snapshot.focusedElement
                    and snapshot.focusedElement.dcType
                    and Menus.IsMenuDCType(
                        snapshot.focusedElement.dcType) then
                    hasMenuSignal = true
                end
                -- Check selected element dcType.
                if not hasMenuSignal
                    and snapshot.selectedElement
                    and snapshot.selectedElement.dcType
                    and Menus.IsMenuDCType(
                        snapshot.selectedElement.dcType) then
                    hasMenuSignal = true
                end
                -- Check widget DC types from the scan.
                if not hasMenuSignal and snapshot.widgetDCTypes then
                    for _, widgetDCType in ipairs(
                            snapshot.widgetDCTypes) do
                        if Menus.IsMenuDCType(widgetDCType) then
                            hasMenuSignal = true
                            break
                        end
                    end
                end
                if hasMenuSignal then
                    Log.Info("RoutePanelSnapshot: menu DC type "
                        .. "detected, falling back to Menus")
                    Menus.RouteSnapshot(snapshot)
                else
                    Log.Debug("RoutePanelSnapshot: no panel or "
                        .. "menu handler, suppressing HUD noise")
                end
            end
            return
        end
    end

    -- Event-driven handler lifetime: the only close trigger is C++
    -- firing widgetRemoved with a widget address matching our anchor.
    -- No polling of widgetAddrs, no inference from "anchor not present"
    -- -- the tracked-widget array is noisy for specific widgets (BG3
    -- rebuilds pointers / transient visibility flips), so using it as
    -- a presence oracle produces false-positive closes.  widgetRemoved
    -- is an explicit event and fires exactly when a widget genuinely
    -- goes invisible.
    if snapshot.widgetRemoved and snapshot.removedWidgetData then
        local removedAddr = snapshot.removedWidgetData.widgetRootId
        if removedAddr and removedAddr ~= "" then
            if removedAddr == activePanelHandlerWidgetAddr then
                if previousPanelHandler then
                    Log.Info("Overlay closed, restoring: "
                        .. previousPanelHandler.name)
                    activePanelHandler.ResetState()
                    activePanelHandler = previousPanelHandler
                    activePanelHandlerWidgetAddr =
                        previousPanelHandlerWidgetAddr
                    previousPanelHandler = nil
                    previousPanelHandlerWidgetAddr = nil
                else
                    Log.Info("Panel closed, deactivating: "
                        .. activePanelHandler.name
                        .. " widget=" .. tostring(activePanelHandlerWidgetAddr))
                    CloseDetailView(true)
                    activePanelHandler.ResetState()
                    activePanelHandler = nil
                    activePanelHandlerWidgetAddr = nil
                    return
                end
            elseif removedAddr == previousPanelHandlerWidgetAddr then
                -- The underlying panel's widget is gone (e.g. user
                -- navigated away while an overlay was active).  Drop
                -- the saved previous handler so we don't try to
                -- restore to a panel that no longer exists.
                Log.Info("Previous panel widget removed, clearing: "
                    .. previousPanelHandler.name)
                previousPanelHandler.ResetState()
                previousPanelHandler = nil
                previousPanelHandlerWidgetAddr = nil
            end
        end
    end

    -- Track focused element dcType for customTooltipFn context.
    if snapshot.focusedElement and snapshot.focusedElement.dcType then
        lastFocusedDCType = snapshot.focusedElement.dcType
    end
    activePanelHandler.HandleSnapshot(snapshot)
end

--- ResetAllPanelHandlers: called on GameStateChanged or when switching
--- away from WorldUI panels.  Resets all handler state.
local function ResetAllPanelHandlers()
    -- Close detail view silently (no "closed" announcement during teardown).
    CloseDetailView(true)
    for handlerIndex = 1, #ALL_PANEL_HANDLERS do
        ALL_PANEL_HANDLERS[handlerIndex].ResetState()
    end
    activePanelHandler = nil
    activePanelHandlerWidgetAddr = nil
    previousPanelHandler = nil
    previousPanelHandlerWidgetAddr = nil
end

--- TryActivateFromSnapshot: attempt to discover and activate a panel
--- handler from snapshot data.  Called by EventRouter's late detection
--- when the widget DC type was generic (ls.Widget) and no handler was
--- activated through the normal widget event path.  All detection logic
--- lives here so EventRouter stays a dumb router.
--- @param snapshot table  The full TickSnapshot from C++.
--- @return boolean  True if a handler was activated.
local function TryActivateFromSnapshot(snapshot)
    local panelDCType = nil
    -- Check focused element dcType.
    if snapshot.focusedElement and snapshot.focusedElement.dcType then
        if DC_TYPE_HANDLERS[snapshot.focusedElement.dcType] then
            panelDCType = snapshot.focusedElement.dcType
        end
    end
    -- Check selected element dcType: tab ListBoxItems carry the panel
    -- DC type (e.g., ls.VMSpellBook) even when the focused element is
    -- a child (ls.VMActionGroup, ls.VMCharacterAction).
    if not panelDCType
        and snapshot.selectedElement
        and snapshot.selectedElement.dcType then
        if DC_TYPE_HANDLERS[snapshot.selectedElement.dcType] then
            panelDCType = snapshot.selectedElement.dcType
        end
    end
    -- Widget added on this tick: freshly opened panel, allow all
    -- types.  Iterate all widget events so we don't miss a handled
    -- panel DC type that fired alongside a generic widget event.
    if not panelDCType
        and snapshot.widgetAdded and snapshot.widgetEvents then
        for _, widgetEvent in ipairs(snapshot.widgetEvents) do
            if widgetEvent.dcType
                and DC_TYPE_HANDLERS[widgetEvent.dcType] then
                panelDCType = widgetEvent.dcType
                break
            end
        end
    end
    -- Fallback: all widget DC types, skip discovery-only (HUD noise).
    if not panelDCType and snapshot.widgetDCTypes then
        for _, widgetDCType in ipairs(snapshot.widgetDCTypes) do
            if not DISCOVERY_ONLY_DC_TYPES[widgetDCType]
                and DC_TYPE_HANDLERS[widgetDCType] then
                panelDCType = widgetDCType
                break
            end
        end
    end
    if panelDCType then
        local syntheticWidgetData = {
            dcType = panelDCType,
            elemName = snapshot.focusedElement
                and snapshot.focusedElement.widgetRootId or nil,
        }
        HandlePanelWidgetAdded(syntheticWidgetData)
        return activePanelHandler ~= nil
    end
    return false
end

--- GetActivePanelHandler: returns the currently active panel handler.
--- @return table|nil  The active handler instance, or nil.
local function GetActivePanelHandler()
    return activePanelHandler
end

-- ============================================================================
-- State management
-- ============================================================================

--- ResetState: clear all WorldUI state (radial + panels).
--- Called on GameStateChanged to prevent stale dedup across sessions.
local function ResetState()
    -- Detail + compare views: close silently so their d-pad input
    -- subscriptions don't outlive the session.
    CloseDetailView(true)
    CloseCompareView(true)
    -- Re-arm compare navigation hint for the new session.
    local CompareView = BG3Access.Client.CompareView
    if CompareView and CompareView.ResetHint then
        CompareView.ResetHint()
    end
    -- Radial state.
    radialHintSpoken = false
    inRadial = false
    -- Tooltip state.
    ResetTooltipState()
    -- Panel state.
    ResetAllPanelHandlers()
    lastFocusedDCType = nil
end

-- ============================================================================
-- Exports
-- ============================================================================

BG3Access.Client.WorldUI = {
    -- Radial
    HandleRadialOpen           = HandleRadialOpen,
    ClearRadialFocus           = ClearRadialFocus,
    HandleRadialSlot           = HandleRadialSlot,
    -- Panel routing
    IsWorldDCType              = IsWorldDCType,
    HandlePanelWidgetAdded     = HandlePanelWidgetAdded,
    HandlePanelWidgetRootChanged = HandlePanelWidgetRootChanged,
    RoutePanelSnapshot         = RoutePanelSnapshot,
    TryActivateFromSnapshot    = TryActivateFromSnapshot,
    ResetAllPanelHandlers      = ResetAllPanelHandlers,
    GetActivePanelHandler      = GetActivePanelHandler,
    -- Tooltip
    DispatchTooltip            = DispatchTooltip,
    SpeakInspectData           = SpeakInspectData,
    HandleInspectNav           = HandleInspectNav,
    SetTooltipSuppressed       = SetTooltipSuppressed,
    SetTooltipEnabled          = SetTooltipEnabled,
    -- Detail view: EventRouter owns the RS Left trigger and handler
    -- lookup; WorldUI only exposes the tooltip cache that builders
    -- need as item-facts source, and a close hook for state reset.
    GetLastTooltipTexts        = GetLastTooltipTexts,
    CloseDetailView            = CloseDetailView,
    -- State management
    ResetState                 = ResetState,
    -- Diagnostics (SE console: BG3Access.Client.WorldUI.DumpEquipmentStructure())
    DumpEquipmentStructure     = CharSheet.DumpEquipmentStructure,
}
