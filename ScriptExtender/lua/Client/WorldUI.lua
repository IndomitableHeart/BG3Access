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
local Helpers  = BG3Access.Client.Helpers
local Cutscene = BG3Access.Client.Cutscene

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
local lastTooltipSpeech      = nil    -- dedup: last spoken tooltip text
local lastSpokenRadialTitle  = nil    -- title filter: prevent tooltip re-speaking title
local lastRawTooltipTexts    = nil    -- full raw texts for inspect readback

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
--- @param slotData table  From GatherRadialSlotData.
local function SpeakRadialSlot(slotData)
    local cleanTitle = Helpers.StripMarkupTags(slotData.title)
    local speechParts = { cleanTitle }

    -- Track title so the tooltip can filter it (avoid double-speaking).
    -- Reset tooltip dedup so the new slot's tooltip always speaks.
    lastSpokenRadialTitle = cleanTitle
    lastTooltipSpeech = nil

    -- API-sourced description (spell/passive flavor text not shown in tooltip).
    if slotData.description and slotData.description ~= "" then
        local cleanedDescription = Helpers.StripMarkupTags(slotData.description)
        -- Strip trailing period to avoid double periods when joining.
        if cleanedDescription:sub(-1) == "." then
            cleanedDescription = cleanedDescription:sub(1, -2)
        end
        speechParts[#speechParts + 1] = cleanedDescription
    end

    local fullText = table.concat(speechParts, ". ")

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

    local parts = { "Action Radial" }
    if not radialHintSpoken then
        radialHintSpoken = true
        table.insert(parts, RADIAL_HINT)
    end
    local speech = table.concat(parts, ". ")
    Log.Info("RADIAL OPEN: " .. speech)
    Ext.Tolk.Speak(speech, true)
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

--- ProcessTooltip: called by EventRouter with tooltip snapshot data.
--- Speaks immediately on each tooltip change.  Title filtering prevents
--- re-speaking what the handler already said.  The subset check prevents
--- re-speaking when a later wave has fewer texts than a previous one
--- (tooltip collapsing as TextBlocks disappear).
--- @param snapshot table  The full TickSnapshot from C++.
local function ProcessTooltip(snapshot)
    -- Reset dedup when user navigates to a new element.
    -- Note: radial slot changes reset lastTooltipSpeech in SpeakRadialSlot
    -- instead, since snapshot.radialSlotChanged isn't on the Lua table.
    if snapshot.focusChanged or snapshot.selectionChanged then
        lastTooltipSpeech = nil
    end

    -- Only process if tooltip data is present and speech is allowed.
    if not snapshot.tooltipChanged or not snapshot.tooltipTexts then
        return
    end
    if tooltipSuppressed or not tooltipEnabled then return end

    -- Store the full raw texts for inspect readback (right stick).
    lastRawTooltipTexts = snapshot.tooltipTexts

    local tooltipSpeech = Helpers.FormatTooltipTexts(
        snapshot.tooltipTexts, lastSpokenRadialTitle)
    if not tooltipSpeech or tooltipSpeech == lastTooltipSpeech then return end

    -- Skip if the new text is a subset of what was already spoken
    -- (tooltip collapsing between waves as TextBlocks disappear).
    if lastTooltipSpeech
        and lastTooltipSpeech:find(tooltipSpeech, 1, true) then
        return
    end

    lastTooltipSpeech = tooltipSpeech
    Log.Info("TOOLTIP: " .. tooltipSpeech)
    Ext.Tolk.Speak(tooltipSpeech, false)
end

--- HandleInspectNav: called by EventRouter when d-pad moves focus between
--- side panels in the PinnedTooltips_c inspect widget.  Reads the focused
--- panel's TextBlocks via C++ BFS and speaks title + description.
local function HandleInspectNav()
    local readOk, panelTexts = pcall(Ext.UI.ReadFocusedTextBlocks)
    if not readOk or not panelTexts or #panelTexts == 0 then return end

    -- Partition into titles (short, no periods) and details (longer/sentences).
    -- Titles come first so the panel name is spoken before its description.
    local titles = {}
    local details = {}
    for _, text in ipairs(panelTexts) do
        if text and text ~= "" and text ~= ":" and text ~= "." then
            local cleaned = Helpers.StripMarkupTags(text)
            if cleaned and cleaned ~= ""
                and cleaned ~= ":" and cleaned ~= "." then
                -- Strip trailing colon or period.
                if cleaned:sub(-1) == "."
                    or cleaned:sub(-1) == ":" then
                    cleaned = cleaned:sub(1, -2)
                end
                -- Bare numbers are stat values (DC 13, etc.).
                -- Parenthesized text is modifiers like "(Tav)".
                -- Modifier notation like "+5 (Tav)" is a stat value.
                -- These are all details, not titles.
                if cleaned:match("^[%d%.]+$")
                    or cleaned:match("^%(.*%)$")
                    or cleaned:match("^[%+%-]%d+") then
                    table.insert(details, cleaned)
                elseif #cleaned <= 25 and not cleaned:find("%.") then
                    table.insert(titles, cleaned)
                else
                    table.insert(details, cleaned)
                end
            end
        end
    end

    local parts = {}
    for _, title in ipairs(titles) do table.insert(parts, title) end
    for _, detail in ipairs(details) do table.insert(parts, detail) end

    if #parts > 0 then
        local speech = table.concat(parts, ". ")
        Log.Info("INSPECT NAV: " .. speech)
        Ext.Tolk.Speak(speech, true)
    end
end

--- SpeakInspectData: called when PinnedTooltips_c widget appears (right
--- stick inspect).  Reads TextBlocks directly from the inspect widget
--- via C++ BFS (same approach as tooltip scanner but targeting a widget).
--- This captures the side panel detail (dice, damage type, range in feet,
--- attack modifier, cost explanation) that the tooltip popup didn't have.
--- Falls back to stored tooltip texts if the widget read fails.
--- @return boolean  True if inspect data was spoken, false if nothing found.
local function SpeakInspectData()
    -- Try reading the inspect widget directly via C++ BFS.
    local readOk, widgetTexts = pcall(
        Ext.UI.ReadWidgetTextBlocks, "PinnedTooltips_c")
    if readOk and widgetTexts and #widgetTexts > 0 then
        local inspectSpeech = Helpers.FormatInspectTexts(
            widgetTexts, lastSpokenRadialTitle)
        if inspectSpeech then
            Log.Info("INSPECT (widget): " .. inspectSpeech)
            Ext.Tolk.Speak(inspectSpeech, true)
            return true
        end
    end

    -- Fallback: use stored tooltip texts if widget read failed.
    if lastRawTooltipTexts and #lastRawTooltipTexts > 0 then
        local inspectSpeech = Helpers.FormatInspectTexts(
            lastRawTooltipTexts, lastSpokenRadialTitle)
        if inspectSpeech then
            Log.Info("INSPECT (fallback): " .. inspectSpeech)
            Ext.Tolk.Speak(inspectSpeech, true)
            return true
        end
    end

    return false
end

--- ResetTooltipState: clear all tooltip state (called on GameStateChanged).
local function ResetTooltipState()
    lastTooltipSpeech = nil
    tooltipSuppressed = false
    lastSpokenRadialTitle = nil
    lastRawTooltipTexts = nil
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
---
--- @return table  Handler with HandleSnapshot, HandleWidgetAdded,
---                ResetState, ResetNavigation, ResetHint
local function CreatePanelHandler(config)
    local handlerState = {
        lastSpokenName       = nil,
        lastSpokenFullText   = nil,
        lastSpokenTab        = nil,
        lastSpokenTitle      = nil,
        tabHintSpoken        = false,
        screenEntryJustSpoke = false,
        -- Optional: set by onWidgetAdded hooks for overrides.
        titleOverride        = nil,
        bodyOverride         = nil,
    }

    -- -----------------------------------------------------------------
    -- HandleSnapshot: generic panel processing pipeline.
    -- Handles classification, widget updates, carousel/value, screen
    -- entry, item navigation, and speech output.
    -- -----------------------------------------------------------------
    local function HandleSnapshot(snapshot)
        local focusedElement = snapshot.focusedElement
        if not focusedElement or not focusedElement.elemType then return end

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

        local isScreenEntry = false
        if snapshot.selectionChanged then
            isScreenEntry = true
        elseif snapshot.widgetAdded and snapshot.widgetData
            and not handlerState.lastSpokenTab then
            isScreenEntry = true
        elseif snapshot.focusChanged and focusedElement.isTab then
            isScreenEntry = true
        end

        local isItemNav = snapshot.focusChanged
            and not focusedElement.isTab and not isScreenEntry
        local isCarouselOnly = hasCarousel and not snapshot.focusChanged
        local isValueOnly = not isScreenEntry and not isItemNav
            and not isCarouselOnly and snapshot.valueChanged

        -- Widget text update: DC property changed (e.g., status text
        -- update) or dialog appeared without focus change.
        if not isScreenEntry and not isItemNav
            and snapshot.widgetAdded and snapshot.widgetData then
            local _, widgetBody, widgetActions = Helpers.ExtractFromWidgetData(
                snapshot.widgetData)
            local updateText = widgetBody or widgetActions
            if updateText and updateText ~= ""
                and updateText ~= handlerState.lastSpokenFullText then
                handlerState.lastSpokenFullText = updateText
                Log.Info("WIDGET UPDATE [" .. config.name .. "]: "
                    .. updateText)
                Ext.Tolk.Speak(updateText, true)
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
            if carouselValue ~= handlerState.lastSpokenFullText then
                handlerState.lastSpokenFullText = carouselValue
                Log.Info("CAROUSEL [" .. config.name .. "]: "
                    .. carouselValue)
                Ext.Tolk.Speak(carouselValue, true)
            end
            return
        end

        if isValueOnly then
            local valueText = Helpers.FormatDCValue(focusedElement.dcProps)
            if valueText and valueText ~= ""
                and valueText ~= handlerState.lastSpokenFullText then
                handlerState.lastSpokenFullText = valueText
                Log.Info("VALUE [" .. config.name .. "]: " .. valueText)
                Ext.Tolk.Speak(valueText, true)
            end
            return
        end

        -- =============================================================
        -- Screen entry or item navigation: fill slots, speak.
        -- =============================================================
        local slots = {}
        local tabName = nil
        local normalTab = ""
        local screenTitle = nil

        if isScreenEntry then
            -- Derive tab name.
            if focusedElement.isTab then
                tabName = focusedElement.tabName
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
            if snapshot.widgetData and snapshot.widgetData.namedTexts then
                for elementName, elementText in pairs(snapshot.widgetData.namedTexts) do
                    if not allNamedTexts[elementName] then
                        allNamedTexts[elementName] = elementText
                    end
                end
            end
            local nsTitle, nsBodyParts = Helpers.ExtractFromNamedTexts(
                allNamedTexts)
            local widgetTitle, widgetBody, widgetActions =
                Helpers.ExtractFromWidgetData(snapshot.widgetData)

            -- Title.
            screenTitle = nsTitle or widgetTitle
            -- Synthetic title from onWidgetAdded (e.g., "Item" / "Spell"
            -- for SelectionFlyOut where the real title is inaccessible).
            if not screenTitle and handlerState.titleOverride then
                screenTitle = handlerState.titleOverride
                handlerState.titleOverride = nil
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
                slots["title"] = screenTitle
            end

            -- Hint (once per panel visit).
            -- Skip when customSpeakFn is configured -- the custom
            -- function manages its own hint timing and placement.
            if not config.customSpeakFn
                and not handlerState.tabHintSpoken then
                handlerState.tabHintSpoken = true
                local panelHint
                -- hintFn(screenTitle, handlerState) allows dynamic hints.
                if config.hintFn then
                    panelHint = config.hintFn(screenTitle, handlerState)
                else
                    -- nil means use default hint, false means no hint.
                    panelHint = config.hint
                    if panelHint == nil then
                        panelHint = DEFAULT_PANEL_HINT
                    end
                end
                if panelHint then
                    slots["hint"] = panelHint
                end
            end

            -- Tab name (suppress if title contains it).
            if tabName then
                local showTabName = true
                if screenTitle
                    and Helpers.NormalizeForCompare(screenTitle):find(
                        normalTab, 1, true) then
                    showTabName = false
                end
                if showTabName then
                    slots["tabName"] = tabName
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
                slots["body"] = bodyAssembled
            end
            -- Dialog button actions (e.g., "A: Yes, B: No").
            if widgetActions then
                slots["actions"] = widgetActions
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

        -- ----- Item slots -----
        local itemName = nil
        local itemInfo = nil
        local itemValue = nil
        local itemDesc = nil

        local splitName, splitValue, splitDesc, splitValueDesc =
            Helpers.FormatDCTextSplit(focusedElement.dcProps,
                focusedElement.dcType)
        if not splitName or splitName == "" then
            splitName = Helpers.ExtractTextFromData(
                focusedElement, handlerState.lastSpokenTab, isScreenEntry)
            splitValue = nil
            splitDesc = nil
            splitValueDesc = nil
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
                -- When a value has its own description (combobox options),
                -- put the setting description before the value (itemInfo)
                -- and the value description after it (itemDesc).
                -- Order: name -> setting desc -> value -> value desc
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
            slots["itemName"] = itemName
            handlerState.lastSpokenName = elemId
            -- Only pre-set lastSpokenFullText for the default speech
            -- path.  customSpeakFn manages its own dedup and updates
            -- lastSpokenFullText after building the full speech string.
            -- Pre-setting it here would defeat customSpeakFn's dedup
            -- check (speech == lastSpokenFullText is always true).
            if not config.customSpeakFn then
                handlerState.lastSpokenFullText = itemName
            end
            Log.Info("ITEM [" .. config.name .. "]: "
                .. tostring(focusedElement.elemType)
                .. "  name=" .. itemName
                .. (itemValue and ("  val=" .. itemValue) or "")
                .. (itemDesc
                    and ("  desc=" .. tostring(itemDesc):sub(1, 40))
                    or ""))
        end
        if itemInfo then slots["itemInfo"] = itemInfo end
        if itemValue then slots["itemValue"] = itemValue end
        if itemDesc then slots["itemDesc"] = itemDesc end

        -- customSpeakFn lets a handler control speech ordering entirely.
        -- It receives (slots, handlerState, isScreenEntry) and is
        -- responsible for calling Ext.Tolk.Speak and updating
        -- handlerState.lastSpokenFullText / screenEntryJustSpoke.
        if config.customSpeakFn then
            config.customSpeakFn(slots, handlerState, isScreenEntry)
        else
            Helpers.SpeakSlots(slots, handlerState, isScreenEntry)
        end
    end

    -- -----------------------------------------------------------------
    -- HandleWidgetAdded: process widget added events.
    -- -----------------------------------------------------------------
    local function HandleWidgetAdded(widgetData)
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
        handlerState.tabHintSpoken = false
        handlerState.screenEntryJustSpoke = false
        handlerState.titleOverride = nil
        handlerState.bodyOverride = nil
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
    }
end

-- ============================================================================
-- Panel handler instances
-- ============================================================================

-- Character sheet / inventory / equipment (tabbed: Inventory, Character
-- Sheet, Spells, Features).
local CharacterPanelHandler = CreatePanelHandler({
    name = "CharacterPanel",
    hint = "Use bumpers to switch tabs. Up and down to navigate items.",
})

-- Trading / bartering dual inventory.
local TradeHandler = CreatePanelHandler({
    name = "Trade",
    hint = "Use bumpers to switch between inventories."
        .. " Up and down to navigate items.",
})

-- Inspect character or item details.
local ExamineHandler = CreatePanelHandler({
    name = "Examine",
    hint = false,
})

-- Dice roll UI for skill checks and saving throws.
local ActiveRollHandler = CreatePanelHandler({
    name = "ActiveRoll",
    hint = false,
})

-- Reaction ability decision during combat.
local ReactionHandler = CreatePanelHandler({
    name = "Reaction",
    hint = false,
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
-- Uses customSpeakFn for speech order: title, item name, then hints.
-- Speech on entry: "Search Results. Brine Bulb. A to attack. X for actions. B to close."
-- Speech on nav:   "Brine Bulb."
local SelectionFlyOutHandler = CreatePanelHandler({
    name = "SelectionFlyOut",
    hint = false,
    onWidgetAdded = function(widgetData, handlerState)
        if widgetData.dcProps then
            -- CollectionTitle from C++ post-processor (DCSelectionFlyOut).
            -- Title from direct DC property (DCActiveSearch).
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
    customSpeakFn = function(slots, handlerState, isScreenEntry)
        local parts = {}
        if isScreenEntry then
            -- Title from C++ collection extraction (e.g. "Search Results").
            local title = handlerState.collectionTitle
            if title then
                table.insert(parts, title)
            end
        end
        -- Item name.
        if slots.itemName then
            table.insert(parts, slots.itemName)
        end
        -- Value and description after name.
        if slots.itemValue then
            table.insert(parts, slots.itemValue)
        end
        if slots.itemDesc then
            table.insert(parts, slots.itemDesc)
        end
        -- Hint on first visit only, AFTER the item name.
        if isScreenEntry and not handlerState.tabHintSpoken then
            handlerState.tabHintSpoken = true
            if handlerState.panelContentType == "Spell" then
                table.insert(parts, "A to cast. X for actions. B to close")
            else
                table.insert(parts,
                    "A to attack. X for actions. B to close")
            end
        end
        if #parts == 0 then return end
        local speech = Helpers.StripMarkupTags(table.concat(parts, ". "))
        if not speech or speech == "" then return end
        if speech == handlerState.lastSpokenFullText
            and not isScreenEntry then
            return
        end
        Log.Info("FLYOUT [" .. (isScreenEntry and "entry" or "nav")
            .. "]: " .. speech)
        Ext.Tolk.Speak(speech, true)
        handlerState.lastSpokenFullText = speech
        if isScreenEntry then
            handlerState.screenEntryJustSpoke = true
        end
    end,
})

-- Quest or encounter reward selection.
local RewardHandler = CreatePanelHandler({
    name = "Reward",
    hint = false,
})

-- Save name input dialog.
local SavePopupHandler = CreatePanelHandler({
    name = "SavePopup",
    hint = false,
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

-- Multiplayer lobby room (different from lobby browser in Menus).
local LobbyHandler = CreatePanelHandler({
    name = "Lobby",
    hint = false,
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
    -- Examine / inspect
    ["gui::DCExamine"]            = ExamineHandler,
    ["ls.DCExamine"]              = ExamineHandler,
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
    -- Multiplayer lobby
    ["gui::DCLobby"]              = LobbyHandler,
    ["ls.DCLobby"]                = LobbyHandler,
}

-- All handler instances for batch reset.
local ALL_PANEL_HANDLERS = {
    CharacterPanelHandler,
    TradeHandler,
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
    LobbyHandler,
}

-- ============================================================================
-- Panel routing (active handler tracking)
-- ============================================================================

-- Currently active panel handler (set by widget events).
local activePanelHandler = nil

--- IsWorldDCType: returns true if the given DC type belongs to an
--- in-game panel handled by WorldUI.
--- @param dcType string  The DataContext type from a widget.
--- @return boolean
local function IsWorldDCType(dcType)
    if not dcType then return false end
    return DC_TYPE_HANDLERS[dcType] ~= nil
end

--- HandlePanelWidgetAdded: called by EventRouter when a WorldUI panel
--- widget appears.  Updates the active handler and calls its hook.
--- @param widgetData table  The widget data from the snapshot.
local function HandlePanelWidgetAdded(widgetData)
    if not widgetData or not widgetData.dcType then return end

    local newHandler = DC_TYPE_HANDLERS[widgetData.dcType]
    if not newHandler then return end

    if newHandler ~= activePanelHandler then
        -- Deactivating old handler: full reset so it's clean on return.
        if activePanelHandler then
            activePanelHandler.ResetState()
        end
        activePanelHandler = newHandler
        Log.Info("Active panel: " .. activePanelHandler.name
            .. " (dc=" .. widgetData.dcType .. ")")
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
    if not activePanelHandler then
        -- Defensive: routeToWorld is true but no panel handler was set
        -- (widget-added tick had no focusedElement, or handler lookup
        -- failed).  Fall back to Menus so the snapshot isn't dropped.
        Log.Warn("RoutePanelSnapshot: no active panel handler, "
            .. "falling back to Menus")
        local Menus = BG3Access.Client.Menus
        if Menus then
            Menus.RouteSnapshot(snapshot)
        end
        return
    end
    activePanelHandler.HandleSnapshot(snapshot)
end

--- ResetAllPanelHandlers: called on GameStateChanged or when switching
--- away from WorldUI panels.  Resets all handler state.
local function ResetAllPanelHandlers()
    for handlerIndex = 1, #ALL_PANEL_HANDLERS do
        ALL_PANEL_HANDLERS[handlerIndex].ResetState()
    end
    activePanelHandler = nil
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
    -- Radial state.
    radialHintSpoken = false
    inRadial = false
    -- Panel state.
    ResetAllPanelHandlers()
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
    ResetAllPanelHandlers      = ResetAllPanelHandlers,
    GetActivePanelHandler      = GetActivePanelHandler,
    -- Tooltip
    ProcessTooltip             = ProcessTooltip,
    SpeakInspectData           = SpeakInspectData,
    HandleInspectNav           = HandleInspectNav,
    SetTooltipSuppressed       = SetTooltipSuppressed,
    SetTooltipEnabled          = SetTooltipEnabled,
    -- State management
    ResetState                 = ResetState,
}
