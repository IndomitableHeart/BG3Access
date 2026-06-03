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
local lastSpokenRadialTitle  = nil    -- title filter: prevent tooltip re-speaking title (inspect pipeline)
local lastRawTooltipTexts    = nil    -- full raw texts for inspect readback
-- Synthetic handlerState for the radial speech path.  The radial
-- isn't a panel handler, so it doesn't carry its own handlerState,
-- but SpeechData:Speak needs one to record spokenRoles + last text
-- into.  Same shape and semantics as a panel handler's state:
-- spokenRoles is the cross-off set FromTooltip consults to skip
-- already-spoken roles; lastSpokenFullText is what Speak records.
-- Reset spokenRoles on slot change (SpeakRadialSlot), focus /
-- selection change (DispatchTooltip), and ResetTooltipState.
local radialHandlerState     = {
    spokenRoles        = {},
    lastSpokenFullText = nil,
}

-- Forward declaration: the WorldUI dispatcher (Client/Dispatcher.lua
-- instance) is created later in this file once the handler registration
-- list is in place.  Closures earlier in the file (DispatchTooltip etc.)
-- capture this upvalue and query the dispatcher at call time, so the
-- nil-then-assigned pattern works without a separate mirror variable.
local worldUIDispatcher = nil
-- DC type of the most recently focused element.  Set by RoutePanelSnapshot
-- on every focus change; consumed by DispatchTooltip to give handlers
-- context for tooltip role mapping.
local lastFocusedDCType = nil

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
-- Last gathered radial slot data, kept so the radial detail handler
-- (RS Left) can rebuild a property list for the currently-focused
-- slot.  Set by HandleRadialSlot, cleared by ClearRadialFocus and
-- ResetTooltipState.  Independent of lastRawTooltipTexts: slot
-- identity (title, slotType, tagProps, API description) lives here;
-- mid-tooltip-load progressive details live in lastRawTooltipTexts.
local lastRadialSlotData = nil

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
-- Radial noise property categorization
-- ============================================================================
-- PropertyText is a single XAML TextBlock that Larian reuses for many
-- semantic types (range, save, attack, cost, frequency, weapon-class).
-- Coming through FromTooltip it carries the generic label "Property"
-- (or "txt" / "Name" / "VariationWarnings" / "EmpoweredMetamagicText"
-- for spell variants).  Stripping the label was ambiguous ("Melee.
-- DEX Save. Short Rest" had no context); categorizing the VALUE into
-- a canonical label produces coherent speech ("Range: Melee. Saving
-- throw: Dexterity. Recharge: Short Rest").  Unrecognized values from
-- these noisy roles get dropped (the user has Inspect / detail view
-- for full readback).
--
-- Shared between the radial fallback speech path (DispatchTooltip)
-- and the radial detail view (BuildRadialDetailList).  Kept identical
-- so detail-view labels match what the user heard during navigation.

local RADIAL_NOISE_LABELS = {
    Property               = true,
    txt                    = true,
    Name                   = true,
    VariationWarnings      = true,
    EmpoweredMetamagicText = true,
}

--- CategorizeRadialNoiseValue: map a noise property value to a
--- canonical {label, value} pair, or return nils to indicate the
--- value is unrecognized noise that should be dropped.
--- @param value string  Raw property value from FromTooltip.
--- @return string|nil, string|nil  Canonical label, transformed value.
local function CategorizeRadialNoiseValue(value)
    if value == "Melee"
        or value:match("^[%d%.]+%s?m$")
        or value:match("^[%d%.]+%s?ft$")
        or value:match("^[%d%.]+%s?feet$") then
        return "Range", value
    elseif value:match("^(%u+)%s+Save$") then
        -- "DEX Save" -> "Saving throw: Dexterity".  Canonical D&D
        -- label, full ability name (no abbreviation -- screen
        -- readers may pronounce "DEX" as a word or as letters;
        -- "Dexterity" is unambiguous).
        local abbrev = value:match("^(%u+)%s+Save$")
        local fullAbility =
            Helpers.ExpandAbilityAbbreviation(abbrev) or abbrev
        return "Saving throw", fullAbility
    elseif value == "Attack Roll" or value == "Saving Throw" then
        return "Attack type", value
    elseif value == "Short Rest" or value == "Long Rest" then
        return "Recharge", value
    elseif value == "Per turn" then
        return "Frequency", "Once per turn"
    elseif value == "Action"
        or value == "Bonus Action"
        or value == "Reaction" then
        return "Cost", value
    elseif value:lower() == "concentration" then
        return "Concentration", "Yes"
    end
    return nil, nil
end

--- RecategorizeRadialNoiseProperties: mutate speechData.properties to
--- relabel XAML-role-named entries (Property, txt, Name, etc.) into
--- canonical labels (Range, Saving throw, Attack type, Recharge,
--- Frequency, Cost, Concentration) based on value pattern.
--- Unrecognized values from noise roles are dropped entirely.
--- Non-noise properties pass through untouched.
--- @param speechData table  SpeechData with .properties array.
local function RecategorizeRadialNoiseProperties(speechData)
    local recategorizedProps = {}
    for _, prop in ipairs(speechData.properties) do
        if RADIAL_NOISE_LABELS[prop.label] then
            local newLabel, newValue =
                CategorizeRadialNoiseValue(prop.value)
            if newLabel then
                recategorizedProps[#recategorizedProps + 1] = {
                    label = newLabel,
                    value = newValue,
                    tier  = prop.tier,
                }
            end
            -- else: unrecognized noise -> drop entirely.
        else
            recategorizedProps[#recategorizedProps + 1] = prop
        end
    end
    speechData.properties = recategorizedProps
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

--- SpeakRadialSlot: speak the slot title and description.
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

    -- Description is slot-type specific:
    --
    --   * HotBar (action radial -- RB) -- the action's tooltip
    --     popup carries the description.  The tooltip pipeline
    --     (DispatchTooltip -> FromTooltip below) is the
    --     canonical place that detail reaches the user.  Adding
    --     it here would duplicate (and the duplication was
    --     awkward because the slot speech labels it under
    --     "description" while the tooltip labels it under
    --     "technicalDescription", defeating the value-based
    --     dedup).
    --   * Shortcuts menu (RT) and other non-HotBar slot types
    --     render the description inline in the radial widget --
    --     no tooltip popup follows.  Slot speech is the ONLY
    --     place this text can come through.
    if slotData.slotType ~= "HotBar"
        and slotData.description and slotData.description ~= "" then
        local cleanDesc = Helpers.StripMarkupTags(slotData.description)
        if cleanDesc and cleanDesc ~= "" then
            speechData:Add("description", cleanDesc, "normal")
        end
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

    -- New slot: reset the cross-off set so the upcoming tooltip
    -- waves on this slot start fresh.  Speak then accumulates
    -- this slot's fields onto the empty set (same mechanism panel
    -- handlers use via RecordSpokenRoles + Speak).  No-op when
    -- Format produces empty content.  Log tag preserves the
    -- existing "RADIAL [<slotType>]" prefix for debugging.
    radialHandlerState.spokenRoles = {}
    speechData:Speak(radialHandlerState, true, nil, true,
        "RADIAL [" .. slotData.slotType .. "]")
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
--- Also re-arms the hint so the next open re-announces it -- same
--- pattern as panel hints (tabHintSpoken reset on handler
--- deactivation via ResetHint).  Without resetting here, the hint
--- only fires on the FIRST open of a play session and any
--- subsequent reopens (e.g. after closing/reopening from the
--- shortcuts menu) speak just the title with no controls
--- reminder.
local function ClearRadialFocus()
    inRadial = false
    radialHintSpoken = false
    -- Drop the cached slot data so the radial detail handler stops
    -- claiming a focused slot once the radial has closed.
    lastRadialSlotData = nil
end


-- ============================================================================
-- Entry point for radial (called by EventRouter)
-- ============================================================================

--- HandleRadialSlot: gather data then speak.
--- Caches the gathered slotData so the radial detail handler (RS Left)
--- can rebuild a property list for the focused slot without re-reading
--- the snapshot.
--- @param snapshot table  The full TickSnapshot from C++.
local function HandleRadialSlot(snapshot)
    local slotData = GatherRadialSlotData(snapshot)
    if slotData then
        lastRadialSlotData = slotData
        SpeakRadialSlot(slotData)
    end
end

-- ============================================================================
-- Radial detail view (RS Left): D-pad-navigated property list
-- ============================================================================
-- The radial slot tooltip popup is read in full by Inspect (RS press),
-- but Inspect's vertical card-stack navigation is hijacked by the LS
-- direction the user is holding to keep the radial slot focused.  For
-- bottom-half radial positions (4 to 8 o'clock) the LS is held DOWN,
-- which navigates Inspect downward through the explanation cards
-- before they finish reading.  Detail view sidesteps this entirely:
-- d-pad navigation is independent of LS direction, so the user can
-- step through individual properties (Damage, Range, Saving throw,
-- etc.) at their own pace regardless of which radial position they
-- have focused.
--
-- Source of truth:
--   - Identity (Name) and API description come from cached slotData
--     (set by HandleRadialSlot).
--   - Combat facts (Damage, Damage type, Dice, Range, Saving throw,
--     Attack type, Recharge, Frequency, Cost, Concentration,
--     Duration, Properties) come from lastRawTooltipTexts via
--     SpeechData.FromTooltip + RecategorizeRadialNoiseProperties --
--     the SAME pipeline the radial fallback speech uses, so the
--     labels the user heard during navigation match the labels in
--     the detail view.
--   - Economy (Value, Count) for HotBar slots come from tagProps.

--- BuildRadialDetailList: build a {label, value} property list for
--- the currently-focused radial slot.
--- @param focusedData table  Cached slotData (title, description,
---     slotType, tagProps).
--- @param tooltipTexts table|nil  Cached raw tooltip texts.
--- @return table|nil  Array of {label, value}, or nil if empty.
local function BuildRadialDetailList(focusedData, tooltipTexts)
    if not focusedData then return nil end

    local detailList = {}
    local seenLabels = {}
    local function addField(label, val)
        if val and val ~= "" and not seenLabels[label] then
            seenLabels[label] = true
            detailList[#detailList + 1] =
                {label = label, value = val}
        end
    end

    -- Identity from slotData.
    local cleanTitle = Helpers.StripMarkupTags(focusedData.title)
    addField("Name", cleanTitle)

    -- Description: prefer the API-resolved one cached on slotData
    -- (HotBar route uses Stats DB; ShortcutsMenu uses C++ TextBlock).
    -- The tooltip's description core field can fill in if slotData
    -- has no description (rare, but possible for actions whose Stats
    -- entry lacks a Description attribute).
    if IsValidText(focusedData.description) then
        addField("Description", focusedData.description)
    end

    -- HotBar economy / stack info from tagProps.  ShortcutsMenu
    -- entries don't carry tagProps, so this block silently no-ops.
    if focusedData.slotType == "HotBar" and focusedData.tagProps then
        local goldValue = focusedData.tagProps["Gold"]
        if goldValue and goldValue ~= "" and goldValue ~= "0" then
            addField("Value", goldValue .. " gold")
        end
        local stackCount = focusedData.tagProps["Count"]
        if stackCount and stackCount ~= "" and stackCount ~= "0"
            and stackCount ~= "1" then
            addField("Count", stackCount .. " available")
        end
    end

    -- Tooltip-sourced facts.  Apply the same noise categorization
    -- as the speech path so labels stay consistent.
    if tooltipTexts and #tooltipTexts > 0 then
        local speechData = SpeechData.FromTooltip(tooltipTexts)
        RecategorizeRadialNoiseProperties(speechData)

        -- Pull selected core fields.  Skip name/title (already
        -- added).  Skip count/value (handled from tagProps above
        -- to avoid label collisions).
        local CORE_FIELD_LABELS = {
            description           = "Description",
            technicalDescription  = "Technical description",
            additionalDescription = "Additional description",
            status                = "Status",
            state                 = "State",
        }
        for fieldName, label in pairs(CORE_FIELD_LABELS) do
            local entry = speechData.coreFields[fieldName]
            if entry and entry.text then
                addField(label, entry.text)
            end
        end

        -- Properties (Damage, Damage type, Dice, Range, Saving
        -- throw, Attack type, Recharge, Frequency, Cost,
        -- Concentration, Duration, Category, Properties, etc.).
        for _, prop in ipairs(speechData.properties) do
            addField(prop.label, prop.value)
        end
    end

    return #detailList > 0 and detailList or nil
end

--- The radial detail handler.  Same shape as panel/CC handlers:
--- name, BuildDetailList, GetLastFocusedData.  Used by EventRouter's
--- FindActiveDetailHandler when the radial is open.  Detail view
--- title stays "Detail view" (no viewLabel override).
local radialDetailHandler = {
    name = "Radial",
    BuildDetailList = function(focusedData, tooltipTexts)
        return BuildRadialDetailList(focusedData, tooltipTexts)
    end,
    GetLastFocusedData = function()
        if not inRadial or not lastRadialSlotData then return nil end
        return lastRadialSlotData
    end,
}

--- IsRadialOpen: returns true if the radial menu is currently open
--- (between HandleRadialOpen and ClearRadialFocus).  Exposed for
--- EventRouter's FindActiveDetailHandler to gate the radial detail
--- handler check.
local function IsRadialOpen()
    return inRadial
end

--- GetRadialDetailHandler: returns the radial detail handler, but
--- only when the radial is actually open AND a slot has been focused
--- (so GetLastFocusedData would return non-nil).  Returning nil
--- otherwise lets EventRouter fall through to the panel/menu handler
--- check or to the GPS toggle path.
local function GetRadialDetailHandler()
    if not inRadial or not lastRadialSlotData then return nil end
    return radialDetailHandler
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
    -- Reset panel handlers' string dedup on navigation (even when
    -- suppressed, so re-entering a suppressed element doesn't carry
    -- stale state).
    --
    -- DO NOT reset radialHandlerState.spokenRoles here.  The reset
    -- point for the radial cross-off is radialSlotChanged
    -- (SpeakRadialSlot owns that), NOT focusChanged or
    -- selectionChanged -- those flags can fire on tooltip-arrival
    -- ticks for reasons unrelated to the slot changing (each
    -- progressive-load wave can carry focusChanged in BG3's
    -- snapshot model).  Resetting here wipes the slot's
    -- accumulated spokenRoles mid-wave, defeating cross-off.
    local activeHandler = worldUIDispatcher
        and worldUIDispatcher:GetActiveHandler() or nil

    if snapshot.focusChanged or snapshot.selectionChanged then
        if activeHandler and activeHandler.ResetTooltipDedup then
            activeHandler.ResetTooltipDedup()
        end
    end

    -- Tooltip-close signal: tooltipChanged is true but no texts arrived.
    -- Invalidate tooltip-derived state on the active handler (compare
    -- stash) and close any open CompareView whose grid was built from
    -- the tooltip's contents.  Runs even when the module is suppressed
    -- so state can't linger past a suppression boundary.
    if snapshot.tooltipChanged and not structuredTooltipData then
        if activeHandler and activeHandler.ClearCompareData then
            activeHandler.ClearCompareData()
        end
        CloseCompareView(true)
        lastRawTooltipTexts = nil
    end

    if tooltipSuppressed or not tooltipEnabled then return end
    if not structuredTooltipData then return end

    -- Store raw texts for inspect readback (right stick).
    lastRawTooltipTexts = structuredTooltipData

    -- Dispatch to active panel handler.
    if activeHandler and activeHandler.HandleTooltip then
        activeHandler.HandleTooltip(
            structuredTooltipData, structuredTooltipData, lastFocusedDCType)
        return
    end

    -- Radial fallback: no panel handler active.  Same dedup
    -- mechanism panel handlers use -- spokenRoles cross-off:
    -- FromTooltip skips any role whose key (<fieldName> or
    -- "property:<label>") is in radialHandlerState.spokenRoles.
    -- The set is seeded by SpeakRadialSlot via :Speak, then grown
    -- by each tooltip wave's :Speak.  Result: every field speaks
    -- at most once across the slot speech + every progressive-
    -- load tooltip wave on the same slot.
    --
    -- After cross-off, apply a radial-specific tier policy via
    -- RetierProperties:
    --   Brief   -> nothing (slot path already spoke the name).
    --   Normal  -> + damage range only (Damage / Amount labels).
    --   Verbose -> + everything else (dice, type, range, properties,
    --              cost, frequency, etc.).
    -- The universal TOOLTIP_ROLE_MAP tiers are calibrated for full
    -- panel tooltip surfaces where "normal" reasonably includes
    -- Damage type / Range / Property entries.  In the radial, the
    -- user has Inspect (RS) for full-detail readback on demand, so
    -- the hover speech stays terse.  Universal map stays intact
    -- for panel use.
    local fallbackSpeech = SpeechData.FromTooltip(
        structuredTooltipData, radialHandlerState.spokenRoles)
    fallbackSpeech:RetierProperties(function(prop)
        if prop.label == "Damage" or prop.label == "Amount" then
            return "normal"
        end
        return "verbose"
    end)
    -- Pre-record cross-off keys with the ORIGINAL labels BEFORE
    -- categorization mutates them.  Speak's auto-accumulate after
    -- categorization will record under the NEW labels (e.g.
    -- "property:Range:melee"), but the next wave's FromTooltip
    -- looks up with the ORIGINAL XAML role labels ("property:
    -- Property:melee").  Pre-recording with the original labels
    -- ensures wave-to-wave cross-off still works.
    fallbackSpeech:PopulateSpokenRoles(radialHandlerState.spokenRoles)

    -- Categorize / drop XAML-role-named properties for rendering.
    -- Shared with BuildRadialDetailList so detail-view labels match
    -- what the user heard during slot navigation.
    RecategorizeRadialNoiseProperties(fallbackSpeech)
    -- Speak handles format / log / Tolk / spokenRoles populate.
    -- isScreenEntry=false, userInitiated=false -> queue (don't
    -- interrupt the slot speech that just fired).  Log tag
    -- preserves "TOOLTIP (radial fallback)" for debugging.
    fallbackSpeech:Speak(radialHandlerState, false, nil, false,
        "TOOLTIP (radial fallback)")
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
    tooltipSuppressed = false
    lastSpokenRadialTitle = nil
    lastRawTooltipTexts = nil
    radialHandlerState.spokenRoles = {}
    radialHandlerState.lastSpokenFullText = nil
    -- Drop the cached radial slot too so a stale slot can't survive
    -- a state transition (game-state change closes the radial).
    lastRadialSlotData = nil
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
        currentTabContext        = nil,
        lastSpokenTitle      = nil,
        previousSpeechData       = nil,   -- SpeechData from last handler speech
        lastFocusedData      = nil,   -- last focusedElement data table (for detail view)
        hasSpokenTooltip     = false, -- "did a tooltip already speak on this focus" -- drives state-change interrupt
        spokenRoles          = {},    -- map of field key -> spoken value (for value-aware tooltip cross-off)
        spokenValues         = {},    -- set of spoken values (for carousel dedup)
        tabHintSpoken        = false,
        screenEntryJustSpoke = false,
        -- Screen-entry override SpeechData.  Handlers populate any
        -- core field on this (title / sectionLabel / description /
        -- status / count / etc.) from onWidgetAdded; the factory's
        -- screen-entry pipeline reads the overrides and uses them
        -- in place of (or in addition to) extracted values.  One
        -- mechanism replaces the older per-field titleOverride /
        -- sectionLabelOverride / bodyOverride pattern -- adding a
        -- new override slot is now zero factory changes, just
        -- :Add() the new field name from the handler.
        screenEntryOverrides = SpeechData.Create(),
        -- Set by HandleWidgetAdded for the current tick.  HandleSnapshot
        -- consumes (and clears) this on the same tick so widget-derived
        -- title/body/namedTexts come from THIS handler's event, not a
        -- shared "best" event picked by the router.
        pendingWidgetEvent   = nil,
    }

    -- -----------------------------------------------------------------
    -- RecordSpokenRoles: populate spokenRoles and spokenValues from
    -- a SpeechData's fields so tooltip cross-off and carousel dedup
    -- can reference what was already spoken.  Stores the actual
    -- field/property values into spokenRoles (value-aware cross-off
    -- per ShouldSkipSpoken in SpeechData.lua) so subsequent tooltip
    -- waves with matching role+value get skipped while state-change
    -- waves (same role, different value) emit.
    -- Also resets hasSpokenTooltip so the next tooltip on this focus
    -- queues (not interrupts).
    -- -----------------------------------------------------------------
    local function RecordSpokenRoles(speechData)
        handlerState.spokenRoles = {}
        handlerState.spokenValues = {}
        handlerState.hasSpokenTooltip = false
        for fieldName, fieldValue in pairs(speechData.coreFields) do
            handlerState.spokenRoles[fieldName] = fieldValue
            if fieldValue and fieldValue ~= "" then
                handlerState.spokenValues[
                    Helpers.NormalizeForCompare(fieldValue)] = true
            end
        end
        for _, prop in ipairs(speechData.properties) do
            -- Property key encodes value so multi-instance labels
            -- (e.g. PropertyText emitting "Property: Melee" and
            -- "Property: Light") each get their own slot.  Stored
            -- value `true` = presence-only skip in ShouldSkipSpoken.
            handlerState.spokenRoles[
                "property:" .. prop.label .. ":" .. prop.value] = true
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
        elseif widgetEvent and not handlerState.currentTabContext then
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

        -- When the FIRST item-nav after a screen entry fires, pass
        -- userInitiated=false so its speech APPENDS to the screen
        -- entry text instead of cutting it off.  Screen entry is
        -- often triggered by a widget event one tick before the
        -- auto-focus on the first item arrives (Camp grid is the
        -- canonical case: panel loads -> screen entry speaks hint
        -- -> next tick LSGrid auto-focuses Supply Pack -> item nav
        -- would interrupt the hint mid-sentence).  Flag is one-shot:
        -- set after screen-entry-only speech, consumed by the very
        -- next item-nav / value-only / carousel snapshot, then
        -- cleared.  Subsequent navigation interrupts normally so
        -- the user gets responsive feedback as they actively browse.
        local appendForScreenEntryFollow = false
        if (isItemNav or isCarouselOnly or isValueOnly)
            and handlerState.screenEntryJustSpoke then
            appendForScreenEntryFollow = true
            handlerState.screenEntryJustSpoke = false
        end
        local effectiveUserInitiated = userInitiated
        if appendForScreenEntryFollow then
            effectiveUserInitiated = false
        end

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
            -- Role-based dedup.  See Menus.lua isCarouselOnly path
            -- for full rationale.  Selector panels (inventory grids,
            -- equipment slots, etc.) fire both a focus snapshot AND
            -- a carousel snapshot per press; the focus path's "name"
            -- role IS what the carousel value would re-speak.  Same
            -- role, same item, suppressed.
            if handlerState.spokenRoles
                and handlerState.spokenRoles["name"] then
                return
            end
            local carouselValue = snapshot.inlineCarouselValue
            local carouselSpeech = SpeechData.Create()
            carouselSpeech:Add("name", carouselValue, "brief")
            carouselSpeech:Speak(handlerState, false, nil,
                effectiveUserInitiated)
            return
        end

        if isValueOnly then
            -- customItemFn handles value changes for special elements
            -- (expander toggle, equipment equip/unequip, etc.).
            if config.customItemFn then
                local customName = config.customItemFn(
                    focusedElement, handlerState, snapshot)
                -- SpeechData object: speak only what changed vs the
                -- prior speech.  SpeakDelta handles formatting the
                -- delta, recording the FULL state into spokenRoles +
                -- lastSpokenFullText (so the next delta computes
                -- against the right baseline and tooltip cross-off
                -- knows the full set of currently-spoken roles), and
                -- emitting via Tolk with the right interrupt logic.
                if type(customName) == "table" and customName.coreFields then
                    local previousSpeechData =
                        handlerState.previousSpeechData
                    handlerState.previousSpeechData = customName
                    customName:SpeakDelta(handlerState,
                        previousSpeechData,
                        false, nil, effectiveUserInitiated,
                        "VALUE [" .. config.name .. "]")
                    return
                end
                -- Non-empty string: wrap in SpeechData and speak.
                if customName and customName ~= "" then
                    if customName ~= handlerState.lastSpokenFullText then
                        local valueSpeech = SpeechData.Create()
                        valueSpeech:Add("value", customName, "brief")
                        valueSpeech:Speak(handlerState, false, nil,
                            effectiveUserInitiated)
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
                valueSpeech:Speak(handlerState, false, nil,
                    effectiveUserInitiated)
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
            if tabName and tabName == handlerState.currentTabContext then
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
            handlerState.currentTabContext = tabName or ""
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

            -- Read all screen-entry overrides up front.  Handlers
            -- populate these via handlerState.screenEntryOverrides
            -- (a SpeechData) from onWidgetAdded.  One mechanism
            -- replaces the older per-field titleOverride /
            -- sectionLabelOverride / bodyOverride pattern.
            local overrides = handlerState.screenEntryOverrides
            local overrideCoreFields = (overrides and overrides.coreFields)
                or {}

            -- Title.  Handler override takes priority (e.g., Container
            -- handler sets the container name, which is more specific
            -- than a generic tab name like "Inventory" from namedTexts).
            if overrideCoreFields["title"] then
                screenTitle = overrideCoreFields["title"]
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

            -- Section label (slot 2: subtitle / state info under
            -- title).  Handler override takes priority so panels can
            -- inject subtitle-position state (e.g., TadpolePowers
            -- showing tadpole count).  Fall back to extracted tabName
            -- for tab-based menus, suppressing when the title already
            -- contains it or it's an unresolved loca handle.
            if overrideCoreFields["sectionLabel"] then
                speechData:Add("sectionLabel",
                    overrideCoreFields["sectionLabel"], "brief")
            elseif tabName then
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

            -- Body.  Override takes priority over extracted text
            -- (handler explicitly setting description means it's the
            -- authoritative body for this panel).
            local bodyAssembled = nil
            if overrideCoreFields["description"] then
                bodyAssembled = overrideCoreFields["description"]
            elseif nsBodyParts and #nsBodyParts > 0 then
                bodyAssembled = table.concat(nsBodyParts, ". ")
            elseif widgetBody then
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

            -- Apply any OTHER override core fields beyond title /
            -- sectionLabel / description (e.g., status, count,
            -- additionalDescription, instructionHint).  This is the
            -- "free" extensibility -- handlers can add any of the 15
            -- core fields via screenEntryOverrides without touching
            -- the factory.  Properties on the override SpeechData
            -- also get merged.
            if overrides then
                for fieldName, fieldValue in pairs(overrides.coreFields) do
                    if fieldName ~= "title"
                        and fieldName ~= "sectionLabel"
                        and fieldName ~= "description" then
                        speechData:Add(fieldName, fieldValue,
                            overrides.tiers[fieldName])
                    end
                end
                for _, prop in ipairs(overrides.properties) do
                    speechData:AddProperty(
                        prop.label, prop.value, prop.tier)
                end
                -- One-shot consume: replace with fresh empty
                -- SpeechData so the next screen entry starts clean.
                handlerState.screenEntryOverrides = SpeechData.Create()
            end
        else
            -- Item navigation: dedup check.
            if elemId == handlerState.lastSpokenName
                and not hasCarousel then
                local text = Helpers.ExtractTextFromData(
                    focusedElement, handlerState.currentTabContext, false)
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
                handlerState.previousSpeechData = merged
                RecordSpokenRoles(merged)
                merged:Speak(handlerState, isScreenEntry, nil,
                    userInitiated)
            else
                handlerState.previousSpeechData = customSpeechData
                RecordSpokenRoles(customSpeechData)
                customSpeechData:Speak(handlerState, isScreenEntry, nil,
                    effectiveUserInitiated)
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
                focusedElement, handlerState.currentTabContext, isScreenEntry)
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
        handlerState.previousSpeechData = speechData
        -- Record which fields we spoke (for tooltip cross-off).
        RecordSpokenRoles(speechData)
        speechData:Speak(handlerState, isScreenEntry, nil,
            effectiveUserInitiated)

        -- If this was a screen entry that didn't include the focused
        -- item (no name set), set screenEntryJustSpoke so the next
        -- item-nav tick (auto-focus on the first item) appends
        -- instead of cutting the hint off mid-sentence.  See the
        -- block at HandleSnapshot top for the consumption side.
        if isScreenEntry and not itemName then
            handlerState.screenEntryJustSpoke = true
        end
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
        handlerState.currentTabContext = nil
        handlerState.lastSpokenTitle = nil
        handlerState.previousSpeechData = nil
        handlerState.lastFocusedData = nil
        handlerState.tabHintSpoken = false
        handlerState.screenEntryJustSpoke = false
        handlerState.screenEntryOverrides = SpeechData.Create()
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
    ---
    --- Does NOT clear screenEntryOverrides OR screenEntryJustSpoke.
    --- Both are forward-looking state set during screen entry that
    --- the very next snapshot (item-nav or screen entry) needs to
    --- consume.  ResetNavigation runs between screen entry and
    --- first focus when the new widget root is detected --
    --- clearing either would wipe state set milliseconds earlier
    --- and defeat the design.  HandleSnapshot owns the one-shot
    --- consumption of both.  ResetState (full reset on handler
    --- deactivation) clears them properly.
    local function ResetNavigation()
        handlerState.currentTabContext = nil
        handlerState.lastSpokenTitle = nil
        handlerState.lastSpokenName = nil
        handlerState.previousSpeechData = nil
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
            return handlerState.previousSpeechData
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

            -- Interrupt vs queue decision:
            --   First tooltip after focus change -> queue, because
            --   the item handler already spoke the name and the
            --   tooltip is supplemental.
            --   Tooltip refreshed in-place while focus stayed put
            --   (e.g. user pressed A on a Reactions entry and the
            --   ReactionStatusText flipped) -> interrupt, because
            --   the new state is the only thing the user is waiting
            --   to hear and they want immediate confirmation.
            -- The hasSpokenTooltip flag distinguishes the two cases:
            -- false on the first tooltip after focus, true when a
            -- prior tooltip already spoke on this focus.  Reset by
            -- RecordSpokenRoles on item-nav / screen-entry, and by
            -- ResetTooltipDedup at focus boundaries when no item
            -- speech happened.  Pass isStateChange as userInitiated
            -- so Speak's existing interrupt rule emits correctly.
            --
            -- Dedup of identical-content waves comes from value-
            -- aware spokenRoles cross-off: Speak's auto-accumulate
            -- records what was spoken, FromTooltip skips matching
            -- role+value entries on subsequent waves.  No string
            -- compare needed -- if all roles match, FromTooltip
            -- returns empty, Format returns nil, Speak early-returns.
            local isStateChange = handlerState.hasSpokenTooltip
            local emitted = tooltipData:Speak(handlerState, false, nil,
                isStateChange,
                isStateChange and "TOOLTIP (state change, interrupt)"
                              or "TOOLTIP")
            -- Mark that a tooltip has spoken on this focus so the
            -- next wave's interrupt decision sees state-change.
            if emitted then
                handlerState.hasSpokenTooltip = true
            end
        end,
        ResetTooltipDedup = function()
            -- Called from DispatchTooltip on focusChanged /
            -- selectionChanged so the first tooltip on the new
            -- focus queues (not interrupts).  RecordSpokenRoles
            -- also resets this; ResetTooltipDedup is the safety
            -- net for focus changes that arrive without an
            -- accompanying item speech.
            handlerState.hasSpokenTooltip = false
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

-- Trading / bartering dual inventory.  Each party member's inventory
-- is wrapped in an Expander whose header is an LSToggleButton named
-- "ExpanderButton".  The header renders a CharacterName TextBlock + a
-- WeightDisplayControl ("22/240").  The factory's default extraction
-- yields just the bare elemName ("Expander"), which tells the user
-- nothing -- they can't tell whose section they're on.  Same fix
-- pattern as CharSheet's inventory expanders: when focus lands on an
-- ExpanderButton, ReadFocusedTextBlocks to recover the rendered
-- header text (name + weight) that the bound TranslatedString
-- can't be read directly through dcProps.
local TradeHandler = CreatePanelHandler({
    name = "Trade",
    hint = "Use bumpers to switch between inventories."
        .. " Up and down to navigate items.",
    customItemFn = function(focusedElement, handlerState, snapshot)
        local elemId = focusedElement.elemId or ""
        if not elemId:find("ExpanderButton") then return nil end
        local readOk, headerTexts = pcall(
            Ext.UI.ReadFocusedTextBlocks)
        if not readOk or not headerTexts or #headerTexts == 0 then
            return nil
        end
        -- headerTexts[1] = "Tav" / "Shadowheart" (CharacterName)
        -- headerTexts[2..] = weight components ("22", "/", "240")
        local headerName = Helpers.StripMarkupTags(headerTexts[1])
        if not headerName or headerName == "" then return nil end
        local speechData = SpeechData.Create()
        speechData:Add("name", headerName, "brief")
        -- Reassemble the weight pieces into a single "N of M"
        -- phrase so it reads as a unit rather than three
        -- disconnected tokens.  Skip the bare "/" separator
        -- TextBlock and any blanks.
        local weightParts = {}
        for textIndex = 2, #headerTexts do
            local cleaned = Helpers.StripMarkupTags(
                headerTexts[textIndex])
            if cleaned and cleaned ~= "" and cleaned ~= "/" then
                weightParts[#weightParts + 1] = cleaned
            end
        end
        if #weightParts >= 2 then
            speechData:AddProperty("Weight",
                weightParts[1] .. " of " .. weightParts[2],
                "brief")
        elseif #weightParts == 1 then
            speechData:AddProperty("Weight",
                weightParts[1], "brief")
        end
        return speechData
    end,
})

-- Inspect character or item details.
-- Widget DC is generic ls.Widget; discovery activates via focused
-- element DC types (VMRangeStat, VMResistance, VMItem).
local ExamineHandler = CreatePanelHandler({
    name = "Examine",
    hint = false,
    customItemFn = function(focusedElement, handlerState, snapshot)
        local dcType = focusedElement.dcType or ""

        -- ls.VMAbility: ability-score and saving-throw cells on a
        -- creature's Examine panel both use VMAbility as their
        -- DataContext.  The button's bound Content is the bare
        -- numeric value ("6", "-2"), so the default pipeline
        -- speaks just that -- no label -- and the player has no
        -- idea which stat they landed on.  IDString holds the
        -- ability abbreviation ("STR", "DEX", etc.); combine it
        -- with the rendered elemText so focus produces e.g.
        -- "STR: 6" (score) or "STR: -2" (saving throw).
        if dcType:find("VMAbility") then
            local dcProps = focusedElement.dcProps
            local abilityName = dcProps and dcProps.IDString
            local valueText = focusedElement.elemText or ""
            if abilityName and tostring(abilityName) ~= ""
                and valueText ~= "" then
                -- AddProperty formats as "<label>: <value>" so the
                -- formatter prints "Strength: 6" or "Strength: -2".
                local speechData = SpeechData.Create()
                speechData:AddProperty(tostring(abilityName),
                    valueText, "brief")
                return speechData
            end
        end

        -- ls.Character decorations: creature-Examine XAML has
        -- several TextBlocks whose DataContext is the creature
        -- itself (dcType = ls.Character) but whose rendered text is
        -- distinctive -- the race banner ("Aberration"), the
        -- level/type line ("Level 1 Aberration"), section headers
        -- ("Saving Throw Proficiencies"), etc.  The default
        -- pipeline reads DC.Name for those, so every focus spoke
        -- "Intellect Devourer" repeatedly and drowned out the
        -- useful text.
        --
        -- Three sub-cases in priority order:
        --   1. Non-empty elemText that differs from the creature
        --      name -> speak elemText (race banner, level line,
        --      section headers).
        --   2. empty elemText + elemName == "SizeStat" -> emit
        --      "Size: <ObjectSize>" from dcProps.
        --   3. empty elemText + elemName == "PortraitHP" -> read
        --      the subtree's rendered TextBlocks to extract the
        --      HP numerals (HealthText + HealthMaxText), format as
        --      "HP N of M".
        -- Anything else (anonymous empty-text Character elements)
        -- falls through to the default pipeline so behavior for
        -- unexpected cases is unchanged.
        if dcType == "ls.Character" or dcType == "gui::Character" then
            local elemText = focusedElement.elemText or ""
            local elemName = focusedElement.elemName or ""
            local dcProps = focusedElement.dcProps
            local creatureName = ""
            if dcProps then
                creatureName = tostring(dcProps.Name or "")
            end

            -- PortraitHP focus (initial Examine entry lands here):
            -- read HP, cache for later reuse on creature-name focus,
            -- speak "<name>. HP N of M" so the user hears both the
            -- subject and the vital stat on entry.
            if elemName == "PortraitHP" then
                local readOk, textBlocks = pcall(
                    Ext.UI.ReadFocusedTextBlocks)
                if readOk and textBlocks and #textBlocks > 0 then
                    -- HealthText is rendered as a bare number ("10")
                    -- and HealthMaxText is prefixed with a slash
                    -- ("/15").  Match the strict "N/M" pattern; if
                    -- we can't confirm it's HP text, fall through
                    -- rather than risk speaking unrelated text as
                    -- if it were HP.
                    local combined = table.concat(textBlocks)
                    local currentHp, maxHp = combined:match(
                        "^(%d+)%s*/%s*(%d+)$")
                    if currentHp and maxHp then
                        local hpValue = currentHp .. " of " .. maxHp
                        -- Cache on handlerState so the creature-name
                        -- focus (below) can reuse it without having
                        -- to re-read a TextBlock that isn't in its
                        -- own subtree.  Keyed on (creatureName,
                        -- widgetRootId) together: creature name
                        -- alone isn't unique for generic enemies
                        -- (two goblins in a row with different
                        -- HPs would collide), but widgetRootId
                        -- changes on every new Examine widget so
                        -- it's a clean per-session identity.  The
                        -- handlerState.ResetNavigation path that
                        -- runs on widget-root change doesn't hook
                        -- our cache, but the ID check makes that
                        -- reset implicit -- a new widget can't
                        -- match the old widget's cached ID.
                        handlerState.examineCachedHpName = creatureName
                        handlerState.examineCachedHpWidget =
                            focusedElement.widgetRootId
                        handlerState.examineCachedHpValue = hpValue
                        local speechData = SpeechData.Create()
                        if creatureName and creatureName ~= "" then
                            speechData:Add("name", creatureName, "brief")
                        end
                        speechData:AddProperty("HP", hpValue, "brief")
                        return speechData
                    end
                end
            end

            -- Creature-name element (the big ContentControl whose
            -- bound text IS the creature's name): speak name + HP
            -- together so when the player navigates back to this
            -- element they get the same "identity + vital stat"
            -- pair they heard on entry.  Without the HP repetition,
            -- a d-pad-up after d-pad-down only said "Intellect
            -- Devourer" and the user lost the HP context.
            if elemText ~= "" and elemText == creatureName then
                local speechData = SpeechData.Create()
                speechData:Add("name", creatureName, "brief")
                -- Reuse the cached HP if it's for this creature AND
                -- came from THIS widget's PortraitHP focus.  The
                -- widgetRootId check catches the "two generic
                -- enemies with the same display name" case: a
                -- second goblin in a new Examine widget won't
                -- match the previous widget's cached ID, so we
                -- correctly skip the stale HP.
                if handlerState.examineCachedHpName == creatureName
                    and handlerState.examineCachedHpWidget
                        == focusedElement.widgetRootId
                    and handlerState.examineCachedHpValue
                    and handlerState.examineCachedHpValue ~= "" then
                    speechData:AddProperty("HP",
                        handlerState.examineCachedHpValue, "brief")
                end
                return speechData
            end

            if elemText ~= "" and elemText ~= creatureName then
                -- RaceTypeInfo shows the creature's D&D type /
                -- race category alone ("Aberration", "Humanoid
                -- (Human)", "Beast", etc.) with no visible label
                -- in the XAML -- sighted players read the type
                -- from positional context under the portrait.
                -- For TTS it needs a "Type" label so the word
                -- isn't decontextualized.  AddProperty handles the
                -- label-colon formatting so we don't hand-concat.
                if elemName == "RaceTypeInfo" then
                    local speechData = SpeechData.Create()
                    speechData:AddProperty("Type", elemText, "brief")
                    return speechData
                end
                -- NPCRaceInfo already includes the level prefix
                -- ("Level 1 Aberration") and section headers like
                -- ProficienciesTitle are self-describing; speak
                -- their elemText as-is.
                return elemText
            end

            if elemName == "SizeStat" and dcProps then
                local size = dcProps.ObjectSize
                if size ~= nil and tostring(size) ~= "" then
                    local speechData = SpeechData.Create()
                    speechData:AddProperty(
                        "Size", tostring(size), "brief")
                    return speechData
                end
            end
        end

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

            -- Stat tooltips carry a "ShortText" TextBlock that
            -- concatenates the stat name with the help text, like
            -- "Initiative. Initiative determines who acts first in
            -- combat...".  FromTooltip falls back to exposing
            -- unmapped roles as properties, so this lands as
            -- "ShortText: Initiative. Initiative determines..."
            -- with the role name audibly prepended, which the user
            -- doesn't want.  Promote it to description, strip the
            -- redundant leading stat-name sentence.  When the
            -- ShortText is just a label word with no body (e.g.
            -- "Weight" tooltips), drop it -- the stat label was
            -- already spoken by the handler's customItemFn.
            for index, prop in ipairs(speechData.properties) do
                if prop.label == "ShortText" then
                    local text = tostring(prop.value or "")
                    local sentenceEnd = text:find("%.%s")
                    if sentenceEnd then
                        -- Keep text after the first "<name>. " chunk.
                        local body = text:sub(sentenceEnd + 2)
                        if body ~= ""
                            and not speechData:HasField("description") then
                            speechData:Add(
                                "description", body, "verbose")
                        end
                    end
                    -- Either way, drop the ShortText property so
                    -- the "ShortText:" label doesn't get spoken.
                    table.remove(speechData.properties, index)
                    break
                end
            end

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

        -- Other Examine types (VMAbility on creature ability cells,
        -- ls.Character on race / level / HP tooltips, etc.): fall
        -- through to the shared FromTooltip formatter so we surface
        -- whatever role-mapped content the tooltip carries instead
        -- of going silent.  Returning nil here was the bug -- the
        -- factory's tooltip dispatch (see line ~1268) suppresses
        -- speech entirely when customTooltipFn returns nil, so all
        -- non-VMStat / non-VMResistance examine tooltips lost their
        -- description, modifier, saving-throws content even though
        -- the C++ side captured it correctly.  spokenRoles cross-off
        -- prevents double-reading the name/value the item handler
        -- already spoke.
        local speechData = SpeechData.FromTooltip(
            tooltipTexts, handlerState.spokenRoles)
        if not speechData
            or (next(speechData.coreFields) == nil
                and #speechData.properties == 0) then
            return nil
        end
        return speechData
    end,
    onReset = function(handlerState)
        -- Clear cached HP on handler deactivation.  The cache is
        -- additionally gated by widgetRootId match at read time so
        -- re-examines within the same handler auto-invalidate when
        -- the widget rebuilds; this reset handles the game-state
        -- change / handler-swap path.
        handlerState.examineCachedHpName = nil
        handlerState.examineCachedHpWidget = nil
        handlerState.examineCachedHpValue = nil
    end,
})

-- Container inventory (opening a bag/pouch from the inventory).
-- onWidgetAdded captures the container name from namedTexts and sets
-- screenEntryOverrides so screen entry speaks "Alchemy Pouch" instead of
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
                handlerState.screenEntryOverrides:Add(
                    "title", containerName, "brief")
            end
        end
    end,
    -- (No customItemFn needed -- LSGrid focus phantoms are now
    -- handled universally by Helpers.CleanElementName which speaks
    -- "Empty slot" for any "WidgetNavigation*FakeElement" border.
    -- Real items fall through to the factory's generic pipeline.)
})

-- Dice roll UI for skill checks and saving throws.
-- onWidgetAdded fires on initial appearance AND every widget DC INPC
-- change (RollState transitions).  We track lastRollState to detect
-- transitions and speak entry, re-roll, and result announcements.
-- customItemFn handles bonus item navigation (VMBoost, VMAdvantage).
--
-- Pre-commit dice announcement (blind-player informed-reroll feature):
--
-- Previous attempt used a 200ms timer polling FindNameInWidget
-- "ResultHolder" + ReadElementStructuredTextBlocks.  That failed
-- every time because DiceAnimation.xaml ResultCountTemplateStyle
-- sets Visibility=Hidden by default and only becomes Visible during
-- the narrow RevealResultAnimation window -- 30 ticks of 0 entries.
-- Even when visible, the Dice ContentControl Content binds to
-- {Binding ResultNumber} / Tag to {Binding FinalResult} (see
-- DiceAnimation.xaml:1211), which are DC properties, NOT
-- tree-extractable text.
--
-- Real fix: onWidgetAdded is INPC-driven.  When RollState transitions
-- (WaitForStart -> StartRoll -> StopRoll -> WaitForReRoll / ResultReady),
-- the widget DC INPC fires and we get fresh dcProps.  The roll values
-- (NaturalRoll, FinalResult, ResultNumber, etc.) are on dcProps.
--
-- This diagnostic block dumps every candidate DC field at each
-- RollState transition so we can see which field carries the natural
-- d20 face and at which state it's populated.  Remove the dump and
-- wire the right field once the log confirms the answer.
local function DumpActiveRollDcProps(dcProps, rollState)
    if not dcProps then
        Log.Info("ACTIVE ROLL DC dump [" .. tostring(rollState)
            .. "]: dcProps is nil")
        return
    end
    -- Iterate EVERY scalar field on dcProps so we catch fields whose
    -- names we don't know yet (e.g., reroll-state signals, total/bonus
    -- splits).  We log strings, numbers, and booleans; sub-tables get
    -- recursed one level (enough to expose Roll / Boost / similar
    -- nested fields).
    local function isScalar(value)
        local valueType = type(value)
        return valueType == "string"
            or valueType == "number"
            or valueType == "boolean"
    end
    for fieldName, fieldValue in pairs(dcProps) do
        if isScalar(fieldValue) then
            Log.Info("ACTIVE ROLL DC dump [" .. tostring(rollState)
                .. "]: " .. tostring(fieldName)
                .. "=" .. tostring(fieldValue))
        elseif type(fieldValue) == "table" then
            for subFieldName, subFieldValue in pairs(fieldValue) do
                if isScalar(subFieldValue) then
                    Log.Info("ACTIVE ROLL DC dump ["
                        .. tostring(rollState) .. "]: "
                        .. tostring(fieldName) .. "."
                        .. tostring(subFieldName) .. "="
                        .. tostring(subFieldValue))
                end
            end
        end
    end
end

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

        -- Diagnostic: log EVERY RollState transition (even duplicates
        -- that the guard below would skip) so we can see the full
        -- state-machine timeline the widget INPC actually delivers.
        -- This tells us whether StartRoll / StopRoll / WaitForReRoll
        -- fire as distinct INPC events before the player commits.
        Log.Info("ACTIVE ROLL transition: prev="
            .. tostring(previousState) .. " -> new="
            .. tostring(rollState))
        DumpActiveRollDcProps(dcProps, rollState)

        -- Suppress duplicate announcements for the same state.
        -- NOTE: lastRollState is committed AFTER successful speech,
        -- not here.  If data isn't ready yet (e.g., FinalResult nil
        -- on first ResultReady INPC), the state stays unconsumed so
        -- the next INPC can retry with complete data.
        if rollState == previousState then return end

        -- Entry: roll screen just appeared (WaitForStart or Introduction).
        -- We do NOT speak from here.  Instead we stash the widget
        -- dcProps so customItemFn can build a single combined
        -- SpeechData (roll context + focused dice modifier) on the
        -- next HandleSnapshot dispatch.  The factory's standard
        -- screen-entry pipeline then makes ONE Speak call -- no race
        -- with the focused-item path that previously caused the
        -- entry hint to be interrupted.  Two Speaks were the bug.
        if rollState == "WaitForStart"
            or rollState == "IntroductionAnimation" then
            -- Skip if DC isn't fully populated yet (first widget event
            -- often arrives before the game sets SkillOrAbility).  The
            -- INPC-driven second event will have complete data.  When
            -- not ready, leave activeRollWidgetDcProps unset so
            -- customItemFn returns empty SpeechData (suppress factory
            -- speech) until the INPC retry delivers full data.
            local skillName = dcProps.SkillOrAbility
            if not skillName or skillName == ""
                or skillName:match("^h%x+g") then
                return
            end
            -- Mark state consumed and stash widget data for
            -- customItemFn.  entrySpoken is set by customItemFn when
            -- it actually emits the combined entry speech.
            handlerState.lastRollState = rollState
            handlerState.activeRollWidgetDcProps = dcProps

            -- Pre-commit dice announcement (hearing the natural d20
            -- BEFORE reroll choice) is handled by dedicated branches
            -- below when the state machine transitions through
            -- StartRoll / StopRoll / WaitForReRoll.  The removed
            -- 200ms visual-tree poll couldn't work because
            -- ResultCountTemplateStyle is Visibility=Hidden until
            -- the narrow RevealResultAnimation window and the dice
            -- number is bound to DC props not extractable TextBlocks.

        -- Re-roll available (Inspiration point, Lucky feat, Bardic
        -- Inspiration, Portent die, etc.).  The player sees the
        -- dice face on screen and can choose to reroll before
        -- committing.  For that decision to be informed, they
        -- need to hear the current result BEFORE the reroll
        -- prompt -- otherwise they'd either always reroll (wasting
        -- resources on passes) or never reroll (locking in failures).
        --
        -- FinalResult may be populated at this state since the
        -- game has computed the roll and is waiting on the player's
        -- keep-or-reroll input.  Read it and speak the breakdown
        -- alongside the reroll prompt.  If FinalResult is still 0
        -- (game hasn't populated it yet), speak just the reroll
        -- prompt -- the server RollFinished relay will fill in the
        -- result when commit eventually fires.
        elseif rollState == "WaitForReRoll" then
            handlerState.lastRollState = rollState
            local finalResult = dcProps.FinalResult
            local success = dcProps.Success
            local speechData = SpeechData.Create()

            if finalResult and finalResult ~= ""
                and finalResult ~= "0" then
                speechData:AddProperty(
                    "Dice", "Rolled " .. finalResult, "brief")
                local resultNumber = tonumber(finalResult) or 0
                if success == "On" then
                    if resultNumber == 20 then
                        speechData:AddProperty("Outcome",
                            "Critical Success!", "brief")
                    else
                        speechData:AddProperty(
                            "Outcome", "Success.", "brief")
                    end
                else
                    if resultNumber == 1 then
                        speechData:AddProperty("Outcome",
                            "Critical Failure!", "brief")
                    else
                        speechData:AddProperty(
                            "Outcome", "Failure.", "brief")
                    end
                end
            end

            speechData:Add("instructionHint",
                "Re-roll available. Y to re-roll, A to accept.",
                "brief")
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
            -- Commit fired.  The server-side RollFinished relay speaks
            -- the full breakdown (natural roll + modifier + total).
            local finalResult = dcProps.FinalResult
            local success = dcProps.Success
            local skipped = dcProps.SkippedRoll

            -- ResultReady only fires after the player presses A to
            -- commit the roll; BG3 keeps the widget in the earlier
            -- animation/reveal state during the dice resolve so the
            -- player can still Inspiration- or Lucky-reroll.  By the
            -- time we reach this branch, FinalResult is populated --
            -- so the old "defer and retry" path never actually fired
            -- (ResultReady never entered pre-commit).  No retry
            -- needed.  If FinalResult is somehow still 0, log and
            -- bail -- the server-side RollFinished relay will speak
            -- the number regardless.
            if not finalResult or finalResult == ""
                or finalResult == "0" then
                Log.Debug("ACTIVE ROLL ResultReady: FinalResult="
                    .. tostring(finalResult)
                    .. " (server relay will speak)")
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
        handlerState.activeRollWidgetDcProps = nil
        handlerState.subPanelEntered = false
    end,
    customItemFn = function(focusedElement, handlerState, snapshot)
        -- Single-Speak architecture: the entry context (skill,
        -- ability check, DC, advantage, dialogue line, nav hint) and
        -- the focused dice modifier are merged into ONE SpeechData
        -- and returned together on first focus after widget add.
        -- The factory's screen-entry merge produces a single Speak
        -- so the entry hint can never be interrupted by a follow-up
        -- item-nav speak (the bug that previously needed a deferred-
        -- queue band-aid).  Subsequent focuses skip the entry block.
        --
        -- Three states:
        --   1. entrySpoken=true: just speak the focused item.
        --   2. entrySpoken=false AND widget data not ready
        --      (activeRollWidgetDcProps nil): return empty SpeechData
        --      so the factory suppresses speech.  INPC retries.
        --   3. entrySpoken=false AND data ready: build entry block,
        --      append focused item, set entrySpoken=true.
        local widgetDcProps = handlerState.activeRollWidgetDcProps
        if not handlerState.entrySpoken and not widgetDcProps then
            -- Reset currentTabContext so the next snapshot (when INPC
            -- finally delivers SkillOrAbility) is detected as a fresh
            -- screen entry by the factory.  Without this, the factory
            -- would have set currentTabContext="" on this same tick and
            -- the next dispatch would be classified as item-nav --
            -- speech would APPEND instead of INTERRUPT, queuing
            -- behind any in-progress audio.
            handlerState.currentTabContext = nil
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
        -- their text is identical (e.g., two "+2" bonuses).  Skip
        -- dedup on the entry-speech tick -- that emission is the
        -- screen-entry announcement, not a same-item repeat.
        if handlerState.entrySpoken
            and elemId
            and elemId == handlerState.lastBonusElemId then
            return SpeechData.Create()
        end
        handlerState.lastBonusElemId = elemId

        local combinedSpeech = SpeechData.Create()

        -- ----- Entry block (one-shot on first focus after widget add) -----
        if not handlerState.entrySpoken and widgetDcProps then
            -- title: skill + ability check as ONE coherent phrase
            -- (single space, not period -- "Sleight of Hand Dexterity
            -- Check" reads as one thing, the kind of roll being made).
            -- DC and advantage become labeled properties so a screen
            -- reader announces them as discrete pieces of information
            -- ("Difficulty: DC 20") rather than ambiguous title parts.
            local titleParts = {}
            local skillName = widgetDcProps.SkillOrAbility
            if skillName and skillName ~= ""
                and not skillName:match("^h%x+g") then
                titleParts[#titleParts + 1] = skillName
            end
            local abilityText = widgetDcProps.AbilityCheckText
            if abilityText and abilityText ~= ""
                and widgetDcProps.IsPureAbilityRoll ~= "True"
                and not abilityText:match("^h%x+g") then
                titleParts[#titleParts + 1] = abilityText
            end
            if #titleParts > 0 then
                combinedSpeech:Add("title",
                    table.concat(titleParts, " "), "brief")
            end

            -- DC and advantage go in `sectionLabel` (slot 2 in
            -- CORE_FIELD_LIST -- speaks immediately after `title`,
            -- before `navigationHint` and `name`).  Matches the
            -- on-screen layout: the "DIFFICULTY CLASS 20" panel
            -- sits directly under the "Sleight of Hand / Dexterity
            -- Check" header, ABOVE the bonus cards the player
            -- navigates.  AddProperty wouldn't work -- properties
            -- slot after `name`, which would put DC after the
            -- focused bonus and read as if it described the bonus.
            local roll = widgetDcProps.Roll
            if roll and type(roll) == "table" then
                local labelParts = {}
                local difficultyCheck = roll.DifficultyCheck
                if difficultyCheck and difficultyCheck ~= "" then
                    labelParts[#labelParts + 1] =
                        "DC " .. difficultyCheck
                end
                local advantageType = roll.RollAdvantageType
                if advantageType and advantageType ~= "None"
                    and advantageType ~= "" then
                    labelParts[#labelParts + 1] = advantageType
                end
                if #labelParts > 0 then
                    combinedSpeech:Add("sectionLabel",
                        table.concat(labelParts, ". "), "brief")
                end
            end

            -- Navigation hint.  Single canonical place.  X opens the
            -- "Add Bonus" sub-panel where a nearby party member can
            -- spend a resource (Guidance, Bardic Inspiration, Bless,
            -- etc.) to contribute an extra bonus on top of the
            -- always-on modifiers.
            combinedSpeech:Add("navigationHint",
                "Y to roll. X to add bonus. "
                .. "Left and right to browse bonuses.")

            -- Dialogue line (skill checks during dialogue).  Goes in
            -- description -- spoken AFTER the focused item name in
            -- CORE_FIELD_LIST order, which keeps the urgent context
            -- (what's being rolled, what's focused) up front.
            local dialogueLine = widgetDcProps.SelectedDialogueLine
            if dialogueLine and dialogueLine ~= ""
                and not dialogueLine:match("^h%x+g")
                and not dialogueLine:find("%[ForceUpdate%]") then
                combinedSpeech:Add("description", dialogueLine, "normal")
            end

            -- Mark consumed so the next item navigation skips this
            -- block.  Suppress factory's own hint emission too.
            handlerState.entrySpoken = true
            handlerState.tabHintSpoken = true
            handlerState.activeRollWidgetDcProps = nil
            Log.Info("ACTIVE ROLL entry: "
                .. table.concat(titleParts, ". "))
        end

        local dcType = focusedElement.dcType or ""

        -- Sub-panel entry/exit tracking.  We snapshot the previous
        -- value, then reset to false; the VMBoost branch sets it
        -- back to true ONLY if the focus is a spell-derived boost
        -- (i.e. inside the X "Add Bonus" sub-panel).  This handles
        -- back-out via B (focus returns to main row -- could be
        -- VMItem, non-spell VMBoost, or anything) AND repeat-entry
        -- via X (re-announce next time) without needing a separate
        -- exit branch in every catch-all.
        local previousSubPanelEntered = handlerState.subPanelEntered
        handlerState.subPanelEntered = false

        -- VMBoost: a roll modifier card.  Two flavours:
        --   1. Always-on bonuses (proficiency, expertise, ability
        --      mod): dcProps.Name is set directly ("Sleight of Hand
        --      Proficiency").  No offering character -- they're
        --      inherent to the rolling character.
        --   2. Spell-derived boosts from the X "Add Bonus" sub-panel
        --      (Guidance, Bardic Inspiration, Bless, etc.):
        --      dcProps.Name is empty.  The spell name lives in
        --      BoostModifier.Name; the offering party member lives
        --      in Owner.Name.  Speak "Spell +Xd Y from Character".
        if dcType:find("VMBoost") then
            local isSpellDerived = false

            -- name (slot 4): the boost identifier as a single noun
            -- phrase.  Always-on bonuses fuse skill + type qualifier
            -- ("Sleight of Hand" + "Proficiency" -> "Sleight of Hand
            -- Proficiency"), matching how the sighted card renders
            -- them as one inseparable label.  Spell-derived boosts
            -- use BoostModifier.Name alone ("Guidance"); their
            -- BoostType is empty/Custom so no qualifier is added.
            local boostName = dcProps.Name or ""
            if boostName == "" then
                local boostModifier = dcProps.BoostModifier
                if type(boostModifier) == "table"
                    and boostModifier.Name then
                    boostName = boostModifier.Name
                    isSpellDerived = true
                end
            end
            -- BoostType qualifier ("Proficiency" / "Expertise"):
            -- part of the bonus identity, not a separate property.
            -- Only append when the resulting phrase doesn't already
            -- end with the qualifier (defensive against future game
            -- versions that might bake the qualifier into Name).
            local boostType = dcProps.BoostType
            if boostName ~= "" and boostType and boostType ~= "" then
                local qualifier = nil
                if boostType == "ProficiencyBonus" then
                    qualifier = "Proficiency"
                elseif boostType == "ExpertiseBonus" then
                    qualifier = "Expertise"
                end
                if qualifier
                    and not boostName:lower():find(
                        qualifier:lower(), 1, true) then
                    boostName = boostName .. " " .. qualifier
                end
            end
            if boostName ~= ""
                and not boostName:match("^h%x+g") then
                combinedSpeech:Add("name", boostName, "brief")
            end

            -- Sub-panel state tracking (uses isSpellDerived to
            -- distinguish "in X panel" vs "on main row").
            if isSpellDerived then
                handlerState.subPanelEntered = true
                if not previousSubPanelEntered then
                    -- First spell-derived focus = user just opened
                    -- the X "Add Bonus" panel.  Sighted players
                    -- see it slide in with party portraits; speak
                    -- the equivalent.
                    combinedSpeech:Add("title", "Add Bonus", "brief")
                    combinedSpeech:Add("instructionHint",
                        "A to apply. B to go back.")
                end
            end

            -- value (slot 8): the bonus magnitude.  Boosts have
            -- EITHER a numeric Value ("+2" for Proficiency / ability
            -- mod) OR a dice value ("+1d4" for Guidance) -- never
            -- both in practice.  When a future case has both, we'd
            -- need a property fallback; for now, prefer dice.
            local value = dcProps.Value
            local diceTypeSet = dcProps.DiceTypeSet
            local diceStr = nil
            if type(diceTypeSet) == "table" then
                diceStr = diceTypeSet.Str
            end
            if diceStr and diceStr ~= "" then
                combinedSpeech:Add("value", "+" .. diceStr, "brief")
            elseif value and value ~= "" and value ~= "0" then
                local numericValue = tonumber(value)
                if numericValue and numericValue > 0 then
                    combinedSpeech:Add("value",
                        "+" .. value, "brief")
                elseif numericValue then
                    combinedSpeech:Add("value", value, "brief")
                end
            end

            -- AddProperty("From", ...): offering character.  Only for
            -- spell-derived boosts where the source differs from the
            -- rolling character.  Always-on bonuses skip this --
            -- their Owner is the rolling character itself.
            if isSpellDerived then
                local owner = dcProps.Owner
                if type(owner) == "table" and owner.Name then
                    local ownerName = owner.Name
                    if ownerName ~= ""
                        and not ownerName:match("^h%x+g") then
                        combinedSpeech:AddProperty(
                            "From", ownerName, "brief")
                    end
                end
            end

            -- If we built any boost-related fields, return.  Empty
            -- (no name, no value, no properties) means the dcProps
            -- didn't carry usable data -- log and fall through.
            if next(combinedSpeech.coreFields) ~= nil
                or #combinedSpeech.properties > 0 then
                return combinedSpeech
            end

            -- Diagnostic: log dcProps when VMBoost produces nothing
            -- (a future spell type with neither dcProps.Name nor
            -- BoostModifier.Name set).
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
                local advantageText = advantageType
                if description ~= ""
                    and not description:match("^h%x+g") then
                    advantageText = advantageType .. ": " .. description
                end
                combinedSpeech:Add("name", advantageText, "brief")
                return combinedSpeech
            end
        end

        -- VMCharacterAction: spell/action name.
        if dcType:find("VMCharacterAction") then
            local name = dcProps.Name
            if name and name ~= ""
                and not name:match("^h%x+g") then
                combinedSpeech:Add("name", name, "brief")
                return combinedSpeech
            end
        end

        -- VMPassive: passive feature name.
        if dcType:find("VMPassive") then
            local name = dcProps.Name
            if name and name ~= ""
                and not name:match("^h%x+g") then
                combinedSpeech:Add("name", name, "brief")
                return combinedSpeech
            end
        end

        -- Diagnostic: log unrecognized focused-element dcType +
        -- dcProps so we can identify the structure of new VM types.
        -- Skip VMItem (already handled cleanly by generic extraction
        -- for items like Thieves' Tools) and Grid / non-VM types
        -- (containers / wrappers handled by generic extraction).
        if dcType:find("VM")
            and not dcType:find("VMItem") then
            local propDump = {}
            for propName, propValue in pairs(dcProps) do
                propDump[#propDump + 1] = propName .. "="
                    .. tostring(propValue):sub(1, 60)
            end
            Log.Info("ActiveRoll UNHANDLED dcType=" .. dcType
                .. " props={ " .. table.concat(propDump, " | ") .. " }")
        end

        -- Non-VM focused element (e.g., the lockpicking Grid that
        -- shows the tool being used as "Thieves' Tools").  Mirror the
        -- factory's generic extraction so the focused item still
        -- speaks.  We can't return nil here when the entry block was
        -- just built -- the factory takes our return as authoritative
        -- and skips its own generic extraction, which would drop the
        -- entry block.  So extract the name in-place and merge with
        -- the entry block into one SpeechData.
        local genericName, genericValue, genericDesc, genericValueDesc =
            Helpers.FormatDCTextSplit(dcProps, dcType)
        if not genericName or genericName == "" then
            genericName = Helpers.ExtractTextFromData(
                focusedElement, handlerState.currentTabContext,
                not handlerState.entrySpoken)
            genericValue = nil
            genericDesc = nil
            genericValueDesc = nil
        end
        if genericName and genericName:match("^h%x+g") then
            genericName = nil
        end
        if genericName and genericName ~= "" then
            combinedSpeech:Add("name", genericName, "brief")
            if genericValue and genericValue ~= "" then
                combinedSpeech:Add("value", genericValue, "brief")
            end
            -- Item description goes in additionalDescription so it
            -- doesn't clobber the dialogue line in description (set
            -- by the entry block above for dialogue skill checks).
            -- Both speak in CORE_FIELD_LIST order: description first
            -- (dialogue / urgent context), then additionalDescription
            -- (item flavour text).
            local descText = genericValueDesc or genericDesc
            if descText and descText ~= "" then
                combinedSpeech:Add(
                    "additionalDescription", descText, "verbose")
            end
        end

        -- If anything got added (entry block or generic name), return
        -- the combined SpeechData.  Otherwise return nil so the
        -- factory's pipeline can do its own thing (no-op fallback).
        if next(combinedSpeech.coreFields) ~= nil then
            return combinedSpeech
        end
        return nil
    end,
})

-- Reaction ability decision popup during combat.
-- Appears when the player can use a reaction (Opportunity Attack, Counterspell,
-- etc.) on an enemy turn.  Focus lands on VMInterruptDecision items.
--
-- onWidgetAdded reads the trigger description -- WHY this reaction is
-- being prompted ("Goblin Worg moves out of Shadowheart's reach",
-- "Skeleton casts Bless on Goblin", etc.).  The XAML
-- (ReactionDecisionPopup_c.xaml line 334) has a TextBlock named
-- "ReactionTypeText" inside the per-event DataTemplate.  Its content
-- is populated by CtxTransStringRunGeneratorBehavior with Source
-- bound to VMInterruptEvent.Description, so the rendered text is
-- the human-readable trigger description after CtxTransString
-- substitution (character names, spell names, etc. are spliced in).
--
-- Reading the rendered text via FindNameInWidget +
-- ReadElementStructuredTextBlocks is more reliable than walking
-- dcProps to InterruptEvents[0].Description: the dcProps extractor
-- captures shallow widget DC properties, but the InterruptEvents
-- collection lives on the widget DC's Data sub-object and the
-- per-event Description is a TranslatedString reference that
-- Lua-side resolution would need to chase manually.  The TextBlock
-- already holds the resolved+substituted text -- just read it.
local ReactionHandler = CreatePanelHandler({
    name = "Reaction",
    hint = "A to use reaction. B to skip all.",
    onWidgetAdded = function(widgetData, handlerState)
        local findOk, textBlock = pcall(
            Ext.UI.FindNameInWidget, "ReactionTypeText")
        if not findOk or not textBlock then return end
        local readOk, entries = pcall(
            Ext.UI.ReadElementStructuredTextBlocks, textBlock)
        if not readOk or not entries or #entries == 0 then return end
        -- CtxTransStringRunGeneratorBehavior emits a sequence of
        -- Run elements alternating between literal text and
        -- parameter-style runs (character names, etc.).  The
        -- structured reader returns one entry per Run; concatenate
        -- with single spaces to reconstruct the readable sentence.
        -- Filter unresolved binding placeholders / loca handles
        -- that occasionally slip through during the same-tick
        -- read window.
        local pieces = {}
        for _, entry in ipairs(entries) do
            local text = entry.text or ""
            if text ~= ""
                and not text:find("%[ForceUpdate%]")
                and not text:match("^h%x+g")
                and not text:find("s_HandleUnknown") then
                pieces[#pieces + 1] = text
            end
        end
        if #pieces == 0 then return end
        local triggerText = table.concat(pieces, " ")
        -- Use title slot (not description) so the trigger text
        -- precedes the navigation hint -- urgent context (WHY I'm
        -- being asked) leads, choice mechanics follow.  The user
        -- hears: "Reaction: Goblin moves out of Shadowheart's reach.
        -- A to use reaction. B to skip all. Opportunity Attack."
        handlerState.screenEntryOverrides:Add(
            "title", "Reaction: " .. triggerText, "brief")
    end,
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
--
-- The recipe list is grouped by category (Potions, Elixirs, Grenades,
-- Coatings, Extracts).  Each category is an Expander whose header is
-- an LSToggleButton (DC = ls.VMRecipesCollection).  Inside each
-- expanded category is an ItemsControl of recipe entries
-- (DC = ls.VMRecipe).
--
-- Per AlchemyPanel_c.xaml:
--   - Expander header: GroupName TextBlock renders three inline Runs
--     (InheritedTag = localized category name + " (" +
--      TotalCraftableRecipes + "/" + ItemsSource.Count + ")"), e.g.
--     "Potions (3/8)".  Localized.
--   - Recipe entry: Name TextBlock bound to Result.Item.NameAlchemy.
--
-- For screen-reader use, "Potions (3/8)" is awkward (parens read as
-- punctuation).  Rephrase the category header into "<name>. 3 of 8
-- craftable." -- name in the name core field, count as a bare-label
-- property (per SpeechData.lua:494-503 empty-label = bare render).
-- Recipe entries are a single rendered string; speak as the name.
local AlchemyHandler = CreatePanelHandler({
    name = "Alchemy",
    hint = "Up and down to browse recipes, left and right on a recipe to browse ingredients.",
    onReset = function(handlerState)
        -- Clear craft-counter baseline so re-entering the panel
        -- starts fresh.  Without this, a stale lastTotal from a
        -- prior session could mask the first craft on reopen
        -- (e.g. closed panel after one craft -> lastTotal=1; new
        -- panel session DC starts at 0 -> 0 < 1, no increment
        -- detected even after a real craft brings it back to 1).
        handlerState.lastTotalCreatedItems = nil
    end,
    onWidgetAdded = function(widgetData, handlerState)
        -- Two responsibilities, both keyed off the panel-level
        -- ExtractCraftingMessage TextBlock (AlchemyPanel_c.xaml:1252):
        --
        -- (1) Suppress the toast text from screen-entry sweep.  The
        --     TextBlock has Opacity=0 by default and only fades
        --     visible during a transient post-craft animation, but
        --     its bound text resolves regardless of opacity -- so on
        --     screen entry it'd say "0 items added to <name>'s
        --     inventory" (the empty initial state) which is
        --     misleading.  Clearing the namedTexts entry BEFORE
        --     screen entry consumes pendingWidgetEvent prevents
        --     ExtractFromNamedTexts from picking it up via its
        --     "message"-name pattern (Helpers.lua:998).
        --
        -- (2) Announce on craft success.  TotalCreatedItems on the
        --     panel DC (gui::DCAlchemy) increments after a Craft
        --     Item action; the widgetAdded INPC fires with the new
        --     value.  When we detect an increment, speak the
        --     captured rendered toast text via SpeechData.Alert --
        --     audio equivalent of the visual fade-in.  First call
        --     just sets the baseline (lastTotal nil) so we don't
        --     announce "0 items added" on initial entry.
        if not widgetData then return end
        local craftMessage = nil
        if widgetData.namedTexts then
            craftMessage = widgetData.namedTexts.ExtractCraftingMessage
            widgetData.namedTexts.ExtractCraftingMessage = nil
        end
        local dcProps = widgetData.dcProps
        if not dcProps then return end
        local total = tonumber(dcProps.TotalCreatedItems) or 0
        local lastTotal = handlerState.lastTotalCreatedItems
        if lastTotal ~= nil and total > lastTotal and craftMessage then
            local cleaned = Helpers.StripMarkupTags(craftMessage)
            if cleaned and cleaned ~= "" then
                SpeechData.Alert(cleaned, "queue")
            end
        end
        handlerState.lastTotalCreatedItems = total
    end,
    customItemFn = function(focusedElement, handlerState, snapshot)
        local readOk, textBlocks = pcall(Ext.UI.ReadFocusedTextBlocks)
        if not readOk or not textBlocks or #textBlocks == 0 then
            return nil
        end
        -- Join all non-empty rendered TextBlocks with a space.
        -- AlchemyPanel_c.xaml shapes:
        --   - Expander header (RecipesListTemplate): one GroupName
        --     TextBlock with three inline Runs that already render
        --     as a single string ("Potions (3/8)") -- one entry.
        --   - Recipe entry (VMRecipe): one Name TextBlock -- one
        --     entry.
        --   - Ingredient slot (CraftingSlot, lines 381-408): TWO
        --     TextBlocks -- "Salts of" prefix + "Rogue's Morsel"
        --     specific name.  Need both joined.
        -- A single-entry slot joins to itself unchanged; the multi-
        -- entry case is the ingredient slot we need to fix.
        local pieces = {}
        for _, text in ipairs(textBlocks) do
            local cleaned = Helpers.StripMarkupTags(text)
            if cleaned and cleaned ~= "" then
                pieces[#pieces + 1] = cleaned
            end
        end
        if #pieces == 0 then return nil end
        local rawText = table.concat(pieces, " ")

        local speechData = SpeechData.Create()
        -- Match "<category> (<craftable>/<total>)" -- digits required
        -- on both sides of the slash so a recipe name happening to
        -- end in parens won't false-match.
        local categoryName, craftable, total = rawText:match(
            "^(.-)%s*%((%d+)/(%d+)%)$")
        if categoryName and craftable and total then
            -- Append expanded/collapsed state.  Same pattern as
            -- SpellBook.lua:609-613: focusedElement.isChecked is a
            -- tri-state set by C++ on toggleable elements (true =
            -- expanded, false = collapsed, nil = not a toggle /
            -- unknown).  Sighted UX shows an arrow rotating between
            -- "right" and "down"; audio mirror is the state word.
            local isChecked = focusedElement.isChecked
            if isChecked == true then
                categoryName = categoryName .. ", expanded"
            elseif isChecked == false then
                categoryName = categoryName .. ", collapsed"
            end
            speechData:Add("name", categoryName, "brief")
            speechData:AddProperty("",
                craftable .. " of " .. total .. " craftable",
                "brief")
        else
            speechData:Add("name", rawText, "brief")
        end
        return speechData
    end,
})

-- Item combination crafting (DCCombine).  BG3 stages the combine in
-- ONE slot only: dcProps.BaseItem holds the source item (a dye, a
-- quest fragment, etc.).  The card-slot view at the top of the panel
-- previews "if you picked the currently focused inventory item, this
-- would be the pair" -- it's not a separate selection.  Pressing A on
-- an inventory item directly initiates the combine.
--
-- Driving fields on the DCCombine DataContext:
--   BaseItem.Name       -- source item being combined
--   ResultItem.Name     -- preview of the combination result, populated
--                          when ResultItem.Count > 0 (valid recipe)
--   CurrentState        -- "Preparing" / "Working" / "Ready" / "Success" / "Fail"
--   FailReason          -- "None" when valid, otherwise one of:
--                          Invalid, TooFar, NotAllFilled, Duplicate,
--                          BaseNotFound, IngredientNotFound,
--                          Interrupted, NotEmptySlot,
--                          IngredientAlreadyAdded
--   Slots               -- how many slots are filled
--
-- onWidgetAdded fires:
--   1. On initial panel open (first event): screen-entry overrides
--      (title + base item + result preview + action hint).
--   2. On subsequent INPC mutations (state transitions, result
--      changes): incremental announcements via SpeechData.Alert so
--      the player hears state shifts without re-announcing the
--      whole panel.

-- LocaString handles pulled from Combine_c.xaml.  Resolving these at
-- runtime via Helpers.GetTranslatedStringIfHandle gives us Larian's
-- official translated text (matches the on-screen FeedbackLabel) and
-- means the speech tracks the player's chosen language rather than
-- being stuck in our hardcoded English.
local COMBINE_LOCA_HANDLES = {
    -- XAML line 95: containerName TextBlock "Combine Items"
    panelTitle      = "h02ae15ceg643fg41cagadc2g6a4d624daaa2",
    -- XAML line 431: CurrentState=Working feedback ("Combining...")
    stateWorking    = "h3ce43cb2gfecdg4a73g88feg68817006cd8d",
    -- XAML line 421: CurrentState=Success feedback (parameterized with
    -- ResultItem.Name -- template uses [1] placeholder; we substitute
    -- it ourselves at speech time).
    stateSuccess    = "h95958a84g3e7dg4615ga30cg345d06df7cb9",
}

-- FailReason -> LocaString handle.  Each maps to a different on-screen
-- feedback message per XAML lines 445-480.
local COMBINE_FAIL_LOCA_HANDLES = {
    Invalid                = "h47f58fa7g6e37g42fag8408gd89ae7856b9d",
    TooFar                 = "h1371c0f2g99ccg47a3g8012g9c240aec2b50",
    NotAllFilled           = "h2a223e63g1953g4a41gb631gfe287b044889",
    Duplicate              = "h85a8d808g354ag4709g8dbfg39437b3403e7",
    BaseNotFound           = "h84799792gde2eg4c66g8a6bgc6ae05feaa02",
    IngredientNotFound     = "h90ce0538g95a1g4d73gb5c5g54a4dae1c4e9",
    Interrupted            = "he3d62e55g4ed3g49fagb679ge4d9ef4a50b8",
    NotEmptySlot           = "he1c084aag96c0g4716gb47cge9f7e6e5b69d",
    IngredientAlreadyAdded = "h5a6c11e8gf30eg4543g8cb4ge288199d523d",
}

--- Resolve a Combine LocaString handle to Larian's translated text,
--- with optional [1] parameter substitution (used by the Success
--- template which interpolates ResultItem.Name).  Returns nil if the
--- handle doesn't resolve (e.g., Loca API unavailable) OR if the
--- template requires a parameter we don't have, so callers can fall
--- back to their hardcoded English rather than speaking a raw
--- handle or a literal "[1]" to the user.
local function ResolveCombineLoca(handle, paramValue)
    if not handle or handle == "" then return nil end
    if not BG3Access.Client.Helpers
        or not BG3Access.Client.Helpers.GetTranslatedStringIfHandle then
        return nil
    end
    local resolved = BG3Access.Client.Helpers
        .GetTranslatedStringIfHandle(handle)
    if not resolved or resolved == handle then return nil end
    -- Strip Larian's inline markup (e.g., <hl>...</hl> highlight
    -- spans on parameter substitutions).  TTS doesn't render
    -- markup and would speak it literally as "less than h l
    -- greater than" without this.
    resolved = resolved:gsub("</?[%w_]+>", "")
    -- Substitute [1] with paramValue when we have one.  Larian's
    -- parameterized templates use [1], [2], ... for placeholders.
    if paramValue and paramValue ~= "" then
        resolved = resolved:gsub("%[1%]", paramValue)
    end
    -- If the template still contains an unsubstituted placeholder,
    -- the caller's data is missing -- bail so they fall back to a
    -- hardcoded message rather than speaking "[1]" to the user.
    if resolved:find("%[%d+%]") then return nil end
    return resolved
end

local CombineHandler = CreatePanelHandler({
    name = "Combine",
    hint = false,
    onWidgetAdded = function(widgetData, handlerState)
        -- TWO sources to read:
        --
        --   widgetData.dcProps -- C++ side pre-resolves TranslatedString
        --     handles to their localized text, so BaseItem.Name comes
        --     through as "Cobalt Dye" rather than the raw handle
        --     "h3108c778...".  But it's only populated on the INITIAL
        --     widgetAdded fire; subsequent fires arrive with an empty
        --     snapshot.  Cache the resolved item identities here on
        --     fires that have them.
        --
        --   liveDc (via FindNameInWidget) -- always fresh, but
        --     TranslatedString.Name comes back as the raw handle.
        --     Used for scalar state fields (CurrentState, FailReason)
        --     where translation doesn't apply.
        local snapshotProps = widgetData and widgetData.dcProps
        if snapshotProps and type(snapshotProps.BaseItem) == "table" then
            local snapshotBase = snapshotProps.BaseItem
            if snapshotBase.Name and snapshotBase.Name ~= ""
                and not snapshotBase.Name:match("^h%x+g") then
                handlerState.cachedBaseItemName = snapshotBase.Name
            end
            if snapshotBase.EntityUUID then
                handlerState.baseItemEntityUUID = snapshotBase.EntityUUID
            end
        end
        if snapshotProps and type(snapshotProps.ResultItem) == "table" then
            local snapshotResult = snapshotProps.ResultItem
            if snapshotResult.Name and snapshotResult.Name ~= ""
                and not snapshotResult.Name:match("^h%x+g") then
                handlerState.cachedResultItemName = snapshotResult.Name
            end
        end

        local findOk, combineElem = pcall(
            Ext.UI.FindNameInWidget, "Combine_c")
        if not findOk or not combineElem then return end

        local resultCount = 0
        local currentState = ""
        local failReason = "None"
        pcall(function()
            local liveDc = combineElem.DataContext
            if not liveDc then return end
            local resultItem = liveDc.ResultItem
            if resultItem then
                resultCount = tonumber(resultItem.Count) or 0
            end
            local liveState = liveDc.CurrentState
            if liveState ~= nil then
                currentState = tostring(liveState)
            end
            local liveFail = liveDc.FailReason
            if liveFail ~= nil then
                failReason = tostring(liveFail)
            end
        end)

        local baseItemName = handlerState.cachedBaseItemName
        local resultItemName = handlerState.cachedResultItemName
        local hasValidResult = resultCount > 0
            and resultItemName and resultItemName ~= ""

        if not handlerState.entrySpoken then
            -- First fire: stash screen-entry overrides for the
            -- factory's screen-entry pipeline.
            handlerState.entrySpoken = true
            handlerState.lastBaseItemName = baseItemName
            handlerState.lastResultItemName = resultItemName
            handlerState.lastCurrentState = currentState
            handlerState.lastFailReason = failReason
            -- Resolved Larian text for the panel title -- matches
            -- the on-screen containerName TextBlock instead of our
            -- own hardcoded English.
            local panelTitle = ResolveCombineLoca(
                COMBINE_LOCA_HANDLES.panelTitle) or "Combine Items"
            local entryParts = { panelTitle }
            if baseItemName and baseItemName ~= "" then
                entryParts[#entryParts + 1] =
                    "Combining " .. baseItemName
            end
            if hasValidResult then
                entryParts[#entryParts + 1] =
                    "Result: " .. resultItemName
            end
            handlerState.screenEntryOverrides:Add("title",
                table.concat(entryParts, ". "), "brief")
            handlerState.screenEntryOverrides:Add("navigationHint",
                "Y to combine. A to add item. B to close.", "brief")
            return
        end

        -- Subsequent fires: announce diffs via Alert.  Use queue mode
        -- so state announcements don't cut off the focused-item
        -- speech from the factory's item-nav pipeline.
        local diffParts = {}
        if baseItemName ~= handlerState.lastBaseItemName then
            handlerState.lastBaseItemName = baseItemName
            if baseItemName and baseItemName ~= "" then
                diffParts[#diffParts + 1] =
                    "Now combining " .. baseItemName
            end
        end
        if resultItemName ~= handlerState.lastResultItemName then
            handlerState.lastResultItemName = resultItemName
            if hasValidResult then
                diffParts[#diffParts + 1] =
                    "Result: " .. resultItemName
            end
        end
        if currentState ~= handlerState.lastCurrentState then
            local previous = handlerState.lastCurrentState
            handlerState.lastCurrentState = currentState
            -- CurrentState progression per Combine_c.xaml triggers:
            --   "Preparing" -- mid-edit, Y button disabled (silent)
            --   "Ready"     -- valid combination loaded, Y enabled
            --                  (sighted players see Y light up here)
            --   "Working"   -- combination animation playing
            --   "Success"   -- combination committed
            --   "Fail"      -- check FailReason for cause
            -- "Ready" and "No longer ready" stay hardcoded -- they're
            -- our derived "Y just lit up / dimmed" cues, not text
            -- Larian renders anywhere on screen.
            if currentState == "Ready" and previous ~= "Ready" then
                if hasValidResult then
                    diffParts[#diffParts + 1] =
                        "Ready to combine. Result: " .. resultItemName
                else
                    diffParts[#diffParts + 1] = "Ready to combine"
                end
            elseif currentState == "Preparing"
                and previous == "Ready" then
                diffParts[#diffParts + 1] = "No longer ready"
            elseif currentState == "Working"
                and previous ~= "Working" then
                -- Larian's localized FeedbackLabel text for Working.
                local workingText = ResolveCombineLoca(
                    COMBINE_LOCA_HANDLES.stateWorking)
                diffParts[#diffParts + 1] = workingText or "Combining..."
            elseif currentState == "Success" then
                -- Larian's parameterized template; substitute the
                -- result item name into [1] if available.
                local successText = ResolveCombineLoca(
                    COMBINE_LOCA_HANDLES.stateSuccess,
                    resultItemName)
                diffParts[#diffParts + 1] = successText
                    or "Combination complete"
            end
        end
        if failReason ~= handlerState.lastFailReason then
            handlerState.lastFailReason = failReason
            -- Resolve the FailReason to Larian's on-screen
            -- FeedbackLabel text (XAML lines 445-480, one LocaString
            -- per reason).  Matches what sighted players read.
            local failHandle = COMBINE_FAIL_LOCA_HANDLES[failReason]
            local mapped = nil
            if failHandle then
                mapped = ResolveCombineLoca(failHandle)
            end
            if mapped then
                diffParts[#diffParts + 1] = mapped
            elseif failReason ~= "None" and failReason ~= "" then
                -- Unknown FailReason value (BG3 might add new ones in
                -- patches we haven't mapped).  Speak the enum verbatim
                -- so we don't go silent.
                diffParts[#diffParts + 1] =
                    "Cannot combine: " .. failReason
            end
        end
        if #diffParts > 0 then
            SpeechData.Alert(table.concat(diffParts, ". "), "queue")
        end
    end,
    onReset = function(handlerState)
        handlerState.entrySpoken = false
        handlerState.lastBaseItemName = nil
        handlerState.lastResultItemName = nil
        handlerState.lastCurrentState = nil
        handlerState.lastFailReason = nil
        handlerState.baseItemEntityUUID = nil
        handlerState.cachedBaseItemName = nil
        handlerState.cachedResultItemName = nil
    end,
    customItemFn = function(focusedElement, handlerState, snapshot)
        local elemId = focusedElement.elemId or ""

        -- Slot-2 detection: BG3 doesn't expose a top-level slot-2
        -- field on the DCCombine DataContext.  Instead, when the
        -- player presses A on an inventory item, that item's own
        -- IsSelected flag flips to On, and the XAML slot-2 view
        -- renders whichever inventory item has IsSelected=On (other
        -- than BaseItem, which is always IsSelected=On as the source).
        --
        -- We detect this by reading focusedElement.dcProps.IsSelected
        -- and comparing the item identity against BaseItem's EntityUUID.
        -- A focused item that's IsSelected=On AND has a different
        -- EntityUUID from BaseItem is the slot-2 selection -- announce
        -- it as such so the user knows "this item is currently queued
        -- to combine with the source."
        local dcProps = focusedElement.dcProps
        if not dcProps then return nil end
        local isSelected = dcProps.IsSelected
        local entityUUID = dcProps.EntityUUID
        local itemName = dcProps.Name
        local baseUUID = handlerState.baseItemEntityUUID
        if isSelected == "On" or isSelected == true then
            if entityUUID and baseUUID and entityUUID ~= baseUUID
                and itemName and itemName ~= "" then
                -- Slot-2 selected item: build a combined speech that
                -- includes the slot-2 tag AND the current combine-state
                -- status.  Embedding state here (rather than firing a
                -- separate alert) prevents the focus refire from
                -- cutting the state announcement, which was the
                -- "Ready to combine" alert getting swallowed by the
                -- selected-item speech in the prior version.
                local itemDesc = dcProps.Description
                if type(itemDesc) ~= "string"
                    or itemDesc:match("^h%x+g") then
                    itemDesc = nil
                end
                local combinedName = itemName .. ", selected for combine"
                local liveState = handlerState.lastCurrentState
                if liveState == "Ready" then
                    local resultName = handlerState.lastResultItemName
                    if resultName and resultName ~= "" then
                        combinedName = combinedName
                            .. ". Ready to combine. Result: "
                            .. resultName
                    else
                        combinedName = combinedName .. ". Ready to combine"
                    end
                elseif liveState == "Preparing" then
                    -- The pair didn't make a valid combination.
                    -- BG3 doesn't transition to "Fail" until Y is
                    -- pressed, so "Preparing" with an IsSelected
                    -- slot-2 item means "invalid as-loaded."
                    -- Use Larian's localized "Invalid" feedback text
                    -- so we match what the user would see on-screen
                    -- after a Y press in any supported language.
                    local invalidText = ResolveCombineLoca(
                        COMBINE_FAIL_LOCA_HANDLES.Invalid)
                        or "Not a valid combination"
                    combinedName = combinedName .. ". " .. invalidText
                end
                return combinedName, nil, itemDesc
            end
        end
        return nil
    end,
})

-- Give items to NPC.
local DonateHandler = CreatePanelHandler({
    name = "Donate",
    hint = false,
})

-- SchedulePickpocketRollRead: defer a live Roll read by ~20 frames
-- and speak DC + Chance as a queued Alert.  Cancels any pending
-- read on entry so rapid d-pad navigation only speaks the Roll for
-- the item the user actually settles on (settle pattern).
--
-- Why deferred + live: the Pickpocket panel's Roll values come from
-- Noesis bindings that update per focused item.  The dcProps Lua
-- table captured at widget-add / focus-change time is a snapshot
-- with stale Roll values (0 / 0 cold-open, or the previous item's
-- values during navigation).  Reading the LIVE widget via
-- FindNameInWidget("Pickpocket_c").DataContext after the binding
-- chain settles is the only reliable way to get the current item's
-- DC and Chance.  Same canonical pattern as TadpolePowers'
-- tadpole count read.
local function SchedulePickpocketRollRead(handlerState)
    if handlerState.cancelPendingRollRead then
        handlerState.cancelPendingRollRead()
        handlerState.cancelPendingRollRead = nil
    end
    handlerState.cancelPendingRollRead =
        BG3Access.Client.Scheduler.RunAfterFrames(20, function()
            handlerState.cancelPendingRollRead = nil
            local widget = Ext.UI.FindNameInWidget("Pickpocket_c")
            if not widget then return end
            local liveDc = nil
            pcall(function() liveDc = widget.DataContext end)
            if not liveDc then return end
            local liveProps = nil
            pcall(function()
                liveProps = liveDc:GetAllProperties()
            end)
            if not liveProps or not liveProps.Roll then return end
            local rollDc = nil
            local rollChance = nil
            pcall(function()
                local rollProps = liveProps.Roll:GetAllProperties()
                if rollProps then
                    rollDc = tonumber(rollProps.DifficultyCheck)
                    rollChance = tonumber(rollProps.Chance)
                end
            end)
            if not rollDc or rollDc <= 0 then return end

            -- The threshold number is NOT the D&D-style DC that
            -- Combat.lua announces after the roll resolves.
            -- Combat says e.g. "DC 15" -- the full target the
            -- (roll + roller modifier) must meet.  The panel
            -- here shows e.g. "8" -- the threshold on the die
            -- alone (= DC minus the roller's modifier).  Both
            -- numbers are correct in their own framing; the
            -- discrepancy LOOKED like a bug when both got labeled
            -- "DC".  Resolve the actual in-game label for this
            -- number so the speech matches the on-screen UI.
            --
            -- The XAML at line 312 binds the TextBlock next to
            -- the TargetRing image to TranslatedString handle
            -- "hea70fbd3g7598g424egb3bfg7cbe03bbdc09".  Ext.Loca
            -- resolves that to the live English label.  Fallback
            -- "Pickpocket roll" only fires if Ext.Loca isn't
            -- available -- chosen because it can't collide with
            -- our sectionLabel "Target: <name>" the way the
            -- likely in-game label "Target" would, and it's
            -- unambiguous about what number it's describing.
            -- Fallback "Roll target": kept close to the sighted
            -- player's mental model (the threshold ring is
            -- visually labeled "Target") while avoiding collision
            -- with the sectionLabel "Victim: <name>" -- adding
            -- the word "Roll" disambiguates between the d20
            -- threshold number and the person being robbed.
            local rollLabel = "Roll target"
            if Ext.Loca and Ext.Loca.GetTranslatedString then
                local resolvedLabel = Ext.Loca.GetTranslatedString(
                    "hea70fbd3g7598g424egb3bfg7cbe03bbdc09")
                if resolvedLabel and resolvedLabel ~= ""
                    and resolvedLabel
                        ~= "hea70fbd3g7598g424egb3bfg7cbe03bbdc09"
                    -- Sighted players see exactly "Target" on
                    -- screen, but speaking "Target: 10" right
                    -- after "Victim: Shadowheart" would have the
                    -- word "Target" mean two unrelated things in
                    -- back-to-back fields.  Stick with the
                    -- disambiguated "Roll target" when the live
                    -- Loca label is the bare word "Target".  Any
                    -- other resolved label (game patch, mod) wins
                    -- since it implies the in-game UI itself
                    -- changed the label and we should mirror it.
                    and resolvedLabel ~= "Target" then
                    rollLabel = resolvedLabel
                end
            end

            local rollParts = {
                rollLabel .. ": " .. tostring(rollDc),
            }
            if rollChance then
                -- Roll.Chance is a 0..1 float (it's bound to an
                -- LSPie.Value property in the XAML at line 449,
                -- where pie charts use 0..1 for the sweep-angle
                -- ratio).  Multiply by 100 to convert to the
                -- 0..100 percent the user expects.
                rollParts[#rollParts + 1] = "Chance: "
                    .. tostring(math.floor(rollChance * 100))
                    .. " percent"
            end
            local rollText = table.concat(rollParts, ". ")
            Log.Info("PICKPOCKET ROLL: " .. rollText)
            SpeechData.Alert(rollText, "queue")
        end)
end

-- Pickpocket item selection.
--
-- XAML: Pickpocket_c.xaml.  DataContext: gui::DCPickpocket.
-- Each grid cell focuses as elemType=Grid, elemName="Slot Root" with
-- a DataContext that's either ls.VMInventorySlot (an item in the
-- victim's container -- what we'd steal) or ls.VMItem (an item in
-- the player's own inventory -- could plant, but we don't surface
-- that distinction in speech).  See the XAML DataTrigger at line 646
-- for the canonical victim-slot type check.
--
-- Speech model:
--   * Screen entry -> container name + DC + chance + hint.  Target
--     character name comes from widgetData.dcProps.Container.Owner
--     when available.
--   * Item focus -> item name + selected count where relevant.
--   * Grid phantoms -> "Empty slot" (same as Camp).
local PickpocketHandler = CreatePanelHandler({
    name = "Pickpocket",
    hint = false,
    -- ListBoxItems in the grid are flagged isTab by C++; without
    -- this, d-pad cell-to-cell navigation gets routed as screen-
    -- entry events and dedup'd to silence.  Same fix Camp /
    -- ActiveRoll use.
    treatTabsAsItems = true,
    onWidgetAdded = function(widgetData, handlerState)
        local widgetProps = widgetData and widgetData.dcProps
        if not widgetProps then return end

        -- Target / container name resolution.  BG3's data model:
        --
        --   * Top-level character inventory: Container.Name IS the
        --     character's name ("Shadowheart").  Container.Owner is
        --     not populated -- the character IS the container.
        --   * Sub-container (e.g. Camp Supply Sack inside someone's
        --     inventory): Container.Name = "Camp Supply Sack",
        --     Container.Owner.Name = the holder ("Shadowheart").
        --
        -- Try Owner.Name first (specific -- "who owns this sub-bag"),
        -- fall back to Container.Name (top-level character name OR
        -- sub-container name when no Owner is set, e.g. a chest in
        -- the world).  Either way the speech ends up with the most
        -- specific person / object label available.
        local targetName = nil
        if widgetProps.Container
            and type(widgetProps.Container) == "table" then
            if widgetProps.Container.Owner
                and type(widgetProps.Container.Owner) == "table" then
                targetName = Helpers.ResolveTranslatedString(
                    widgetProps.Container.Owner.Name)
            end
            if not targetName or targetName == "" then
                targetName = Helpers.ResolveTranslatedString(
                    widgetProps.Container.Name)
            end
        end

        -- Fields stay distinct -- no comma-concatenation.
        -- Format() handles joining via the field-order walk.
        --   title         -> "Pickpocket" (the action)
        --   sectionLabel  -> "Target: <name>" -- the PERSON being
        --                    pickpocketed.  sectionLabel is the
        --                    slot for subtitle / state info that
        --                    sits under the title; Format() emits
        --                    it second (right after title), so the
        --                    user hears WHO they're pickpocketing
        --                    early instead of buried at the end of
        --                    the speech after the item list.
        --                    Properties (DC / Chance) come much
        --                    later in Format()'s order (between
        --                    technicalDescription and description),
        --                    which is the wrong slot for
        --                    contextual "who am I pickpocketing"
        --                    info.
        --   DC            -> property: difficulty class number.
        --                    The in-game UI labels this "Target N"
        --                    in a small ring; we call it "DC" to
        --                    avoid the word "Target" doubling up
        --                    with the person above.
        --   Chance        -> property: success percent (visualized
        --                    as the pie-fill on the d20 icon).
        --
        -- We deliberately do NOT emit a separate Container property:
        -- when pickpocketing a person, BG3's data model exposes
        -- Container.Name and Container.Owner.Name as the SAME
        -- string (the target's name), so the property would just
        -- duplicate the sectionLabel as "Container: Shadowheart".
        --
        -- DC + Chance values reflect whichever item happens to be
        -- initially focused when the panel opens -- the same info
        -- sighted players see at that same moment.
        handlerState.screenEntryOverrides:Add(
            "title", "Pickpocket", "brief")

        if targetName and targetName ~= "" then
            -- "Victim: <name>" -- not "Target: <name>" -- because
            -- the threshold-ring label resolved via Ext.Loca in
            -- SchedulePickpocketRollRead is "Target", so "Target:
            -- Shadowheart" + "Target: 10" would collide on screen
            -- entry.  "Victim" is unambiguous and matches the
            -- crime-flavored framing of the pickpocket action.
            handlerState.screenEntryOverrides:Add(
                "sectionLabel",
                "Victim: " .. targetName,
                "brief")
        end

        -- Initial Roll read (for the auto-focused first item).
        -- See SchedulePickpocketRollRead helper above for the why.
        -- Subsequent reads fire from customItemFn on each focus
        -- change so the user hears updated DC / Chance per item.
        SchedulePickpocketRollRead(handlerState)

        -- Button mapping per the in-game footer:
        --   D-pad: navigate items in the grid
        --   LB:    open Dice Roll Details popup
        --   RB:    switch between target's inventory and yours
        --   X:     per-item actions menu
        --   Y:     attempt the steal
        --   B:     close panel
        handlerState.screenEntryOverrides:Add(
            "navigationHint",
            "D-pad to browse items. "
                .. "LB for dice roll details. "
                .. "RB to switch between target and your inventory. "
                .. "X for item actions. "
                .. "Y to steal. "
                .. "B to cancel.",
            "normal")
    end,
    customItemFn = function(focusedElement, handlerState, snapshot)
        local dcType = focusedElement.dcType
        local dcProps = focusedElement.dcProps
        local elemId = focusedElement.elemId or ""

        -- Empty grid cell phantom borders.  Raw elemId from C++ is
        -- "Border::WidgetNavigationPrimaryFakeElement" /
        -- "...Secondary..." -- CamelCase, no spaces.  The pretty
        -- "Widget Navigation Primary Fake Element" form only exists
        -- post-CleanElementName at log time.  Same pattern as
        -- ContainerHandler line ~2181.
        --
        -- Speak via Alert with "queue" priority, NOT via the
        -- factory's default interrupt path.  Reason: on a
        -- successful steal, the game removes the stolen item and
        -- auto-shifts focus to the now-empty cell milliseconds
        -- later.  If "Empty slot" went out as interrupt, it would
        -- purge Combat.lua's pending roll-outcome alert ("Tav
        -- passed") that's still in the speech queue waiting its
        -- turn, and the user would never hear the steal result.
        -- Queue puts "Empty slot" behind the roll outcome so the
        -- outcome plays first.  Normal d-pad navigation onto a
        -- real item still uses interrupt (factory default), which
        -- correctly clobbers a queued "Empty slot" when the user
        -- moves on -- so navigation feel doesn't change.
        if elemId:find("WidgetNavigationPrimaryFakeElement")
            or elemId:find("WidgetNavigationSecondaryFakeElement") then
            SpeechData.Alert("Empty slot", "queue")
            return SpeechData.Create()
        end

        if not dcProps then return nil end

        -- Victim's inventory cell: ls.VMInventorySlot wraps an item
        -- in .Object (per the XAML DataTrigger at line 646).
        -- Player's own inventory cell: ls.VMItem directly.
        local objectData = nil
        if dcType == "ls.VMInventorySlot"
            or dcType == "gui::VMInventorySlot" then
            objectData = dcProps.Object
        elseif dcType == "ls.VMItem" or dcType == "gui::VMItem" then
            objectData = dcProps
        else
            return nil
        end

        if not objectData or type(objectData) ~= "table" then
            return nil
        end

        local itemName = Helpers.ResolveTranslatedString(
            objectData.Name or objectData.DisplayName)
        if not itemName or itemName == "" then
            return nil
        end

        local speechData = SpeechData.Create()
        speechData:Add("name", itemName, "brief")

        -- Per-item Roll read.  The panel's Roll binding updates per
        -- focused item: cheap / light items (tankards, keys) have
        -- low DCs and high success chance; valuable items (rare
        -- scrolls, magic gear) have high DCs and low chance.
        -- Schedule a deferred live read so the user hears the DC
        -- and Chance for whichever item they've just focused on.
        -- The settle delay also serves as a debounce: rapid d-pad
        -- navigation only speaks the Roll for the item the user
        -- actually pauses on, not every transient focus.
        SchedulePickpocketRollRead(handlerState)

        return speechData
    end,
    onReset = function(handlerState)
        -- Cancel any in-flight deferred Roll read so a value from
        -- a previous Pickpocket session doesn't surface after the
        -- panel has closed.
        if handlerState.cancelPendingRollRead then
            handlerState.cancelPendingRollRead()
            handlerState.cancelPendingRollRead = nil
        end
    end,
})

-- Spell scroll learning.
local LearnSpellsHandler = CreatePanelHandler({
    name = "LearnSpells",
    hint = false,
})

-- Camp supplies / long rest.
--
-- XAML: MakeCamp_c.xaml.  DataContext: gui::DCMakeCamp.
-- Layout:
--   Title at top:   "Choose Camp Supplies for the Long Rest"
--   Centre ring:    SelectedSuppliesAmount / CurrentPlayer.RequiredPartySupplies
--   5x5 grid:       PartyCampSupplies.Slots (each a VMCampInventorySlot
--                   with .SelectedAmount and .Object.Name / .Object.Count)
--   Footer button:  "Long Rest" (or "Start Resting" / "Long Rest" once
--                   the required supply count is met).
--   Button hints:   A select, ContextMenu auto-select, X split stack,
--                   Y toggle item tooltip, B cancel.
--
-- Speech model:
--   * Screen entry  -> title + current/required supply tally + hint that
--                      describes the controls the player needs.
--   * Item focus    -> "<item name>. <selected> of <available> selected".
local function FormatCampSupplyAmount(selected, available)
    local selectedNumber = tonumber(selected) or 0
    local availableNumber = tonumber(available) or 0
    return tostring(selectedNumber)
        .. " of " .. tostring(availableNumber) .. " selected"
end

local CampHandler = CreatePanelHandler({
    name = "Camp",
    hint = false,
    -- The 5x5 supply grid items are ListBoxItems, which C++
    -- flags as isTab=true.  Without this, d-pad navigation
    -- between cells hits the panel factory's screen-entry path,
    -- which dedups on tabName (every cell resolves to the same
    -- "ListBoxItem:" broken tab name) and silently returns --
    -- the user hears nothing when moving between supplies.
    -- treatTabsAsItems flips tab-typed focus changes into item-
    -- navigation events so customItemFn fires per cell.  Same
    -- setting ActiveRollHandler uses for its bonus row list.
    treatTabsAsItems = true,
    onWidgetAdded = function(widgetData, handlerState)
        -- Stash the camp DC props so the screen-entry pipeline can
        -- read SelectedSuppliesAmount + RequiredPartySupplies even
        -- when the binding hasn't propagated to the focused item yet.
        local widgetProps = widgetData and widgetData.dcProps
        if not widgetProps then return end

        local selectedAmount = widgetProps.SelectedSuppliesAmount
        local requiredAmount = nil
        if widgetProps.CurrentPlayer
            and type(widgetProps.CurrentPlayer) == "table" then
            requiredAmount = widgetProps.CurrentPlayer.RequiredPartySupplies
        end

        handlerState.screenEntryOverrides:Add(
            "title", "Long Rest", "brief")

        if requiredAmount then
            local selectedNumber = tonumber(selectedAmount) or 0
            local requiredNumber = tonumber(requiredAmount) or 0
            local tallyText = tostring(selectedNumber)
                .. " of " .. tostring(requiredNumber)
                .. " camp supplies selected"
            handlerState.screenEntryOverrides:Add(
                "sectionLabel", tallyText, "brief")
        end

        -- Button layout per the in-game footer (controller).  The
        -- StartRestBtn (Y / UITakeAll) flips its label between
        -- "Partial Rest" (when supplies are insufficient) and "Long
        -- Rest" (when supplies meet the required amount) -- describe
        -- it as "start the rest" to cover both cases.
        handlerState.screenEntryOverrides:Add(
            "navigationHint",
            "D-pad to browse supplies. "
                .. "A to select or deselect. "
                .. "X to auto-select. "
                .. "Y to start the rest. "
                .. "B to cancel.",
            "normal")
    end,
    customItemFn = function(focusedElement, handlerState, snapshot)
        local dcType = focusedElement.dcType
        local dcProps = focusedElement.dcProps

        -- (LSGrid empty-cell phantoms now handled universally by
        -- Helpers.CleanElementName -- the factory's generic path
        -- speaks "Empty slot" before reaching this customItemFn.)

        if not dcProps then return nil end

        -- The focused element is a VMCampInventorySlot.  Its .Object
        -- is the actual item (name + count come from there); the
        -- slot itself carries .SelectedAmount.
        if dcType ~= "ls.VMCampInventorySlot"
            and dcType ~= "gui::VMCampInventorySlot" then
            return nil
        end

        local objectData = dcProps.Object
        if not objectData or type(objectData) ~= "table" then
            return nil
        end

        local itemName = Helpers.ResolveTranslatedString(
            objectData.Name or objectData.DisplayName)
        if not itemName or itemName == "" then
            return nil
        end

        local speechData = SpeechData.Create()
        speechData:Add("name", itemName, "brief")
        speechData:Add("value",
            FormatCampSupplyAmount(
                dcProps.SelectedAmount, objectData.Count),
            "brief")
        return speechData
    end,
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
                Log.Info("WALK-FALLBACK: QuestCategoryContainer.Description empty, walking text blocks")
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
                Log.Info("WALK-FALLBACK: QuestView.Quest.Title (and Text/Name/Title) empty, walking text blocks")
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
                    -- NOTE: do NOT append expanded/collapsed for
                    -- leaf QuestView entries.  The XAML wraps each
                    -- quest in an LSToggleButton (so isChecked is
                    -- always reported), but the toggle has no visible
                    -- effect for leaf quests -- the right pane shows
                    -- the same details either way.  Only category
                    -- containers (ls.QuestCategoryContainer) actually
                    -- expand/collapse their child rows in the list.
                    return questTitle, nil, nil
                end
            end
            return "", nil, nil
        end

        -- Quest objective (ls.QuestObjective):
        -- Has Description property directly.  AddProperty puts the
        -- "Objective" label and the description in one labeled fact,
        -- avoiding the prior "Objective: " concat into the value.
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
                local objSpeech = SpeechData.Create()
                objSpeech:AddProperty("Objective",
                    objectiveText, "brief")
                return objSpeech
            end
            Log.Info("WALK-FALLBACK: QuestObjective.Description empty, walking text blocks")
            -- Fallback: text blocks.
            local readOk, texts = pcall(
                Ext.UI.ReadFocusedTextBlocks)
            if readOk and texts and #texts > 0 then
                local text = Helpers.StripMarkupTags(texts[1])
                if text and text ~= "" then
                    local objSpeech = SpeechData.Create()
                    objSpeech:AddProperty("Objective",
                        text, "brief")
                    return objSpeech
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

        -- Generic expander button fallback.  Same rationale as the
        -- QuestView branch above: do NOT append expanded/collapsed.
        -- Genuine category-header expanders are caught by the
        -- QuestCategoryContainer branch (which keeps the suffix
        -- because those toggles ACTUALLY show/hide their child rows
        -- in the list).  Anything reaching here is a leaf with an
        -- invisible IsChecked toggle -- announcing "expanded" /
        -- "collapsed" is misleading.
        if elemId:find("ExpanderButton") then
            Log.Info("WALK-FALLBACK: JournalQuests generic ExpanderButton fallback (dcType=" .. tostring(dcType) .. ")")
            local readOk, headerTexts = pcall(
                Ext.UI.ReadFocusedTextBlocks)
            if readOk and headerTexts and #headerTexts > 0 then
                local headerName = Helpers.StripMarkupTags(
                    headerTexts[1])
                if headerName and headerName ~= "" then
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

-- Dialogue history with portraits (JournalDialogues_c.xaml).
--
-- DC is gui::DCJournalDialogues / ls.DCJournalDialogues.  The left
-- ListBox (DialoguesTree) holds three DC types interleaved:
--
--   ls.JournalDialogueDayGroup -- "By Date" expander row.  Has
--     DayOfMonth + MonthName scalars; XAML formats as "<day>, <month>".
--   ls.JournalDialogueMapGroup -- "By Location" expander row.  Has
--     Map scalar (already a translated location name).
--   ls.JournalDialogue -- a dialogue entry.  Has Participants
--     collection (each {_type=ls.DialogueParticipant, Name="..."}),
--     Map scalar, DayOfMonth + MonthName scalars.  XAML filters out
--     the narrator participant for display; we mirror that by name.
--
-- Sort mode (DataContext.GroupingTab) is "ByDate" or "ByMap".  The
-- entry display swaps Map / Day visibility based on mode -- we don't
-- need to mirror that since we always speak whatever fields are
-- meaningful.
local JOURNAL_DIALOGUE_ENTRY_TYPES = {
    ["ls.JournalDialogueDayGroup"] = true,
    ["ls.JournalDialogueMapGroup"] = true,
    ["ls.JournalDialogue"]         = true,
}

local JournalDialoguesHandler = CreatePanelHandler({
    name = "JournalDialogues",
    hint = "Use bumpers to switch categories."
        .. " Up and down to browse dialogues."
        .. " Press Y to switch sort by date or by location.",
    onWidgetAdded = function(widgetData, handlerState)
        -- Stash the dialogues widget DC so we can find SelectedItem
        -- even after focus drifts away (the always-loaded
        -- gui::DCCrossplayNotifications HUD steals focus on
        -- post-settle ticks, leaving focusedElement pointing nowhere
        -- useful).  dcProps captured at load is a one-shot snapshot;
        -- live SelectedItem comes via dcProps.SelectedItem, which the
        -- C++ collector re-reads any time we get a fresh widget event.
        handlerState.dialoguesWidgetData = widgetData
    end,
    onReset = function(handlerState)
        handlerState.dialoguesWidgetData = nil
    end,
    customItemFn = function(focusedElement, handlerState, snapshot)
        -- DialoguesTree uses ls:MoveFocus.IsFocused="{Binding
        -- IsSelected, ...}" plus VirtualizingStackPanel.  D-pad up/
        -- down fires SelectNextListBoxItem ForceSelect=True which
        -- changes the ListBox.SelectedItem but does NOT raise
        -- Noesis's GotFocus on the new ListBoxItem.  Worse, on the
        -- post-settle tick after the panel opens, focus drifts to
        -- the always-loaded gui::DCCrossplayNotifications HUD widget
        -- (confirmed in DIALOGUES probe logs).
        --
        -- Resolution chain to find the active entry:
        --   1. focusedElement if its dcType is a journal entry type
        --   2. selectedElement if its dcType is a journal entry type
        --   3. focusedElement.dcProps.SelectedItem (DialoguesTree's
        --      SelectedItem flows back into DC.SelectedItem via the
        --      two-way binding in JournalDialogues_c.xaml line 225).
        --      Sub-object _type carries the journal entry class.
        --   4. Fall back to the cached widget DC's SelectedItem when
        --      focus has drifted off the dialogues panel entirely.
        local function FromSelectedItemSubObject(dcProps)
            if type(dcProps) ~= "table" then return nil end
            local selectedItem = dcProps.SelectedItem
            if type(selectedItem) ~= "table" then return nil end
            local subType = selectedItem._type
            if not subType then return nil end
            -- C++ reports type names as "ls.JournalDialogue" etc;
            -- strip the namespace if needed.
            local normalized = subType
            if not JOURNAL_DIALOGUE_ENTRY_TYPES[normalized] then
                local stripped = normalized:gsub("^gui::", "")
                                          :gsub("^ls%.", "ls.")
                if JOURNAL_DIALOGUE_ENTRY_TYPES[stripped] then
                    normalized = stripped
                end
            end
            if not JOURNAL_DIALOGUE_ENTRY_TYPES[normalized] then
                return nil
            end
            return {
                dcType  = normalized,
                dcProps = selectedItem,
                elemId  = "DC.SelectedItem",
            }
        end

        local entry = nil
        if focusedElement.dcType
            and JOURNAL_DIALOGUE_ENTRY_TYPES[focusedElement.dcType] then
            entry = focusedElement
        elseif snapshot.selectedElement
            and snapshot.selectedElement.dcType
            and JOURNAL_DIALOGUE_ENTRY_TYPES[
                snapshot.selectedElement.dcType] then
            entry = snapshot.selectedElement
        else
            entry = FromSelectedItemSubObject(focusedElement.dcProps)
            if not entry and snapshot.selectedElement then
                entry = FromSelectedItemSubObject(
                    snapshot.selectedElement.dcProps)
            end
            if not entry and handlerState.dialoguesWidgetData then
                entry = FromSelectedItemSubObject(
                    handlerState.dialoguesWidgetData.dcProps)
            end
            if not entry then
                entry = focusedElement  -- last-ditch fall-through
            end
        end

        local dcType = entry.dcType
        local dcProps = entry.dcProps
        local elemId = entry.elemId or ""

        -- Tab ListBoxItem (Journal nav carousel itself): suppress.
        if elemId:find("^ListBoxItem::")
            and not JOURNAL_DIALOGUE_ENTRY_TYPES[dcType] then
            return "", nil, nil
        end

        -- Date expander row: speak "Date, <day> <month>, expanded/collapsed".
        if dcType == "ls.JournalDialogueDayGroup" and dcProps then
            local day = dcProps.DayOfMonth
            local month = dcProps.MonthName
            local headerText = nil
            if type(month) == "string" and month ~= "" then
                month = Helpers.GetTranslatedStringIfHandle(month)
                if type(day) == "string" and day ~= "" then
                    headerText = day .. " " .. month
                else
                    headerText = month
                end
            elseif type(day) == "string" and day ~= "" then
                headerText = "Day " .. day
            end
            if not headerText or headerText == "" then
                Log.Info("WALK-FALLBACK: JournalDialogueDayGroup DayOfMonth/MonthName empty, walking text blocks")
                -- Fallback: read text blocks from the expander.
                local readOk, headerTexts = pcall(
                    Ext.UI.ReadFocusedTextBlocks)
                if readOk and headerTexts and #headerTexts > 0 then
                    headerText = Helpers.StripMarkupTags(headerTexts[1])
                end
            end
            if headerText and headerText ~= "" then
                local label = "Date, " .. headerText
                local areShown = dcProps.AreDialoguesShown
                if areShown == "True" or areShown == true then
                    label = label .. ", expanded"
                elseif areShown == "False" or areShown == false then
                    label = label .. ", collapsed"
                end
                return label, nil, nil
            end
            return "", nil, nil
        end

        -- Location expander row: speak "Location, <map>, expanded/collapsed".
        if dcType == "ls.JournalDialogueMapGroup" and dcProps then
            local mapName = dcProps.Map
            if type(mapName) == "string" and mapName ~= "" then
                mapName = Helpers.GetTranslatedStringIfHandle(mapName)
                mapName = Helpers.StripMarkupTags(mapName)
            else
                Log.Info("WALK-FALLBACK: JournalDialogueMapGroup.Map empty, walking text blocks")
                -- Fallback: TextBlock "Map".
                local readOk, headerTexts = pcall(
                    Ext.UI.ReadFocusedTextBlocks)
                if readOk and headerTexts and #headerTexts > 0 then
                    mapName = Helpers.StripMarkupTags(headerTexts[1])
                end
            end
            if mapName and mapName ~= "" then
                local label = "Location, " .. mapName
                local areShown = dcProps.AreDialoguesShown
                if areShown == "True" or areShown == true then
                    label = label .. ", expanded"
                elseif areShown == "False" or areShown == false then
                    label = label .. ", collapsed"
                end
                return label, nil, nil
            end
            return "", nil, nil
        end

        -- Dialogue entry: speaker + location + day, structured.
        if dcType == "ls.JournalDialogue" and dcProps then
            local entrySpeech = SpeechData.Create()

            -- Use the resolved scalar SpeakerName (e.g. "Shadowheart").
            -- Avoid walking dcProps.Participants -- DialogueParticipant.
            -- Name is a parameterized translated string that resolves to
            -- placeholder text like "[1]" at the scalar-read layer, not
            -- to the speaker's name.  SpeakerName is the parent VM's
            -- already-resolved primary speaker scalar.
            local speakerName = dcProps.SpeakerName
            if type(speakerName) == "string" and speakerName ~= "" then
                speakerName = Helpers.GetTranslatedStringIfHandle(
                    speakerName)
                speakerName = Helpers.StripMarkupTags(speakerName)
                if speakerName ~= "" then
                    entrySpeech:Add("name", speakerName, "brief")
                end
            end

            -- Location (Map): only meaningful when sorting by date,
            -- but harmless to speak in either mode.
            local mapName = dcProps.Map
            if type(mapName) == "string" and mapName ~= "" then
                mapName = Helpers.GetTranslatedStringIfHandle(mapName)
                mapName = Helpers.StripMarkupTags(mapName)
                if mapName ~= "" then
                    entrySpeech:AddProperty("Location",
                        mapName, "brief")
                end
            end

            -- Date.
            local day = dcProps.DayOfMonth
            local month = dcProps.MonthName
            if type(month) == "string" and month ~= "" then
                month = Helpers.GetTranslatedStringIfHandle(month)
                local dateText = month
                if type(day) == "string" and day ~= "" then
                    dateText = day .. " " .. month
                end
                entrySpeech:AddProperty("Date", dateText, "normal")
            end

            -- Dialogue content: iterate DialogueLines.  Per the
            -- JournalDialogues_c.xaml DialogueLine template (line 360+)
            -- each line renders as "Speaker.Name: Text" except narrator
            -- lines, where the Name span collapses (the IsNarrator=False
            -- DataTrigger only sets the speaker when speaker is NOT the
            -- narrator).  We mirror: prefix Speaker for character lines,
            -- skip the prefix for narrator lines (they keep their
            -- *italicized* narration framing in the Text itself).
            --
            -- Both bindings are direct property bindings on the
            -- JournalDialogueLine VM with no parameterized loca, so
            -- scalar extraction returns the resolved text -- no walk
            -- needed.  SpeakerName is exposed as a top-level scalar on
            -- each line VM (separate from Speaker sub-object), so use
            -- it directly.
            if type(dcProps.DialogueLines) == "table" then
                local lineParts = {}
                for _, line in ipairs(dcProps.DialogueLines) do
                    if type(line) == "table" then
                        local lineText = line.Text
                        if type(lineText) == "string"
                            and lineText ~= ""
                            and not lineText:match("^h%x+g") then
                            lineText = Helpers.GetTranslatedStringIfHandle(
                                lineText)
                            lineText = Helpers.StripMarkupTags(lineText)
                        else
                            lineText = nil
                        end

                        local speakerName = line.SpeakerName
                        if type(speakerName) == "string"
                            and speakerName ~= ""
                            and speakerName ~= "Narrator" then
                            speakerName = Helpers.GetTranslatedStringIfHandle(
                                speakerName)
                            speakerName = Helpers.StripMarkupTags(speakerName)
                        else
                            speakerName = nil
                        end

                        if lineText and lineText ~= "" then
                            local linePiece
                            if speakerName and speakerName ~= "" then
                                linePiece = speakerName .. ": " .. lineText
                            else
                                linePiece = lineText
                            end
                            lineParts[#lineParts + 1] = linePiece
                        end
                    end
                end
                if #lineParts > 0 then
                    entrySpeech:Add("description",
                        table.concat(lineParts, " "), "normal")
                end
            end

            -- Fallback when scalar extraction produced nothing:
            -- read TextBlocks from the focused entry subtree and stitch
            -- them into a single phrase (mirrors CombatLog handler).
            if next(entrySpeech.coreFields) == nil
                and #entrySpeech.properties == 0 then
                Log.Info("WALK-FALLBACK: JournalDialogue scalar extraction empty, walking text blocks")
                local readOk, entryTexts = pcall(
                    Ext.UI.ReadFocusedTextBlocks)
                if readOk and entryTexts and #entryTexts > 0 then
                    local cleanedParts = {}
                    for _, entryText in ipairs(entryTexts) do
                        local cleaned = Helpers.StripMarkupTags(entryText)
                        if cleaned and cleaned ~= "" then
                            cleanedParts[#cleanedParts + 1] = cleaned
                        end
                    end
                    if #cleanedParts > 0 then
                        return table.concat(cleanedParts, ", "), nil, nil
                    end
                end
                return "", nil, nil
            end

            return entrySpeech
        end

        -- Fall through to generic pipeline.
        return nil
    end,
})

-- Inspiration list (JournalInspiration_c.xaml).
--
-- The controller XAML omits ContextName but the keyboard sibling
-- (JournalInspiration.xaml) declares
-- ls:UIWidget.ContextName="JournalInspiration" and
-- d:DesignInstance {x:Type ls:DCJournalInspiration}, so the runtime
-- DC type is ls.DCJournalInspiration (or gui::DCJournalInspiration
-- in C++ form).  The state machine binding feeds the same DC into
-- both XAML variants.
--
-- Left list (BackgroundsList) holds ls.VMBackground entries with
-- Title scalar and BackgroundOwners collection (each
-- {_type=ls.VMGoalOwner, Name="..."}).  Side panel populates from
-- focused entry's Title + Description + GoalCategories ->
-- BackgroundGoals.
local JournalInspirationHandler = CreatePanelHandler({
    name = "JournalInspiration",
    hint = "Use bumpers to switch categories."
        .. " Up and down to browse inspirations.",
    customItemFn = function(focusedElement, handlerState, snapshot)
        local dcType = focusedElement.dcType
        local dcProps = focusedElement.dcProps

        -- Background category row in the main list.
        if dcType == "ls.VMBackground" and dcProps then
            local entrySpeech = SpeechData.Create()

            local title = dcProps.Title
            if type(title) == "string" and title ~= "" then
                title = Helpers.GetTranslatedStringIfHandle(title)
                title = Helpers.StripMarkupTags(title)
                if title ~= "" then
                    -- Inspiration entries surface their Title as both
                    -- the focused element's tabName (the factory will
                    -- emit it as "tab" during screen entry) and the
                    -- VMBackground.Title scalar.  Skip the "name" field
                    -- when they match to avoid "Charlatan. Charlatan."
                    -- The factory's string-return dedup doesn't run
                    -- when we return SpeechData, so do it here.
                    local tabName = focusedElement.tabName
                    if tabName then
                        tabName = Helpers.GetTranslatedStringIfHandle(
                            tabName)
                    end
                    local isDuplicate = tabName
                        and Helpers.NormalizeForCompare(title)
                            == Helpers.NormalizeForCompare(tabName)
                    if not isDuplicate then
                        entrySpeech:Add("name", title, "brief")
                    end
                end
            end

            -- Owners (party members who satisfied this background):
            -- collected as comma-joined names so the user knows who
            -- earned it.
            if type(dcProps.BackgroundOwners) == "table" then
                local ownerNames = {}
                for _, owner in ipairs(dcProps.BackgroundOwners) do
                    if type(owner) == "table" then
                        local ownerName = owner.Name
                        if type(ownerName) == "string"
                            and ownerName ~= "" then
                            ownerNames[#ownerNames + 1] =
                                Helpers.GetTranslatedStringIfHandle(
                                    ownerName)
                        end
                    end
                end
                if #ownerNames > 0 then
                    entrySpeech:AddProperty("Earned by",
                        table.concat(ownerNames, ", "), "normal")
                end
            end

            -- Description from the side panel binding (focused
            -- VMBackground.Description).
            local desc = dcProps.Description
            if type(desc) == "table" then
                desc = desc.Str or desc.Text or nil
            end
            if type(desc) == "string" and desc ~= "" then
                desc = Helpers.GetTranslatedStringIfHandle(desc)
                desc = Helpers.StripMarkupTags(desc)
                if desc ~= "" then
                    entrySpeech:Add("description", desc, "verbose")
                end
            end

            if next(entrySpeech.coreFields) == nil
                and #entrySpeech.properties == 0 then
                Log.Info("WALK-FALLBACK: JournalInspiration VMBackground scalars empty, walking text blocks")
                -- Fallback: TextBlock subtree.
                local readOk, texts = pcall(
                    Ext.UI.ReadFocusedTextBlocks)
                if readOk and texts and #texts > 0 then
                    local cleaned = Helpers.StripMarkupTags(texts[1])
                    if cleaned and cleaned ~= "" then
                        return cleaned, nil, nil
                    end
                end
                return "", nil, nil
            end

            return entrySpeech
        end

        -- Inspiration goal items in the side panel
        -- (ls.VMBackgroundGoal): Title + Description + GoalOwners.
        if dcType == "ls.VMBackgroundGoal" and dcProps then
            local goalSpeech = SpeechData.Create()
            local title = dcProps.Title
            if type(title) == "string" and title ~= "" then
                title = Helpers.GetTranslatedStringIfHandle(title)
                title = Helpers.StripMarkupTags(title)
                if title ~= "" then
                    goalSpeech:Add("name", title, "brief")
                end
            end
            local desc = dcProps.Description
            if type(desc) == "table" then
                desc = desc.Str or desc.Text or nil
            end
            if type(desc) == "string" and desc ~= "" then
                desc = Helpers.GetTranslatedStringIfHandle(desc)
                desc = Helpers.StripMarkupTags(desc)
                if desc ~= "" then
                    goalSpeech:Add("description", desc, "normal")
                end
            end
            if type(dcProps.GoalOwners) == "table" then
                local ownerNames = {}
                for _, owner in ipairs(dcProps.GoalOwners) do
                    if type(owner) == "table" then
                        local ownerName = owner.Name
                        if type(ownerName) == "string"
                            and ownerName ~= "" then
                            ownerNames[#ownerNames + 1] =
                                Helpers.GetTranslatedStringIfHandle(
                                    ownerName)
                        end
                    end
                end
                if #ownerNames > 0 then
                    goalSpeech:AddProperty("Earned by",
                        table.concat(ownerNames, ", "), "normal")
                end
            end
            if next(goalSpeech.coreFields) == nil
                and #goalSpeech.properties == 0 then
                return "", nil, nil
            end
            return goalSpeech
        end

        return nil
    end,
})

-- Tutorials list (JournalTutorials_c.xaml).
--
-- Widget DC is ls.JournalTutorial (per ContextName="JournalTutorial"
-- in the XAML).  The TreeView has two DC types:
--   ls.TutorialContainer -- category expander.  SectionValue is an
--     enum (e.g. "Combat", "Inventory") that the XAML resolves via
--     EnumTranslatedStringConverter with prefix
--     'h9de08869g5612g419fgbccbg4655074a1030'.  We try the same
--     prefix-based lookup; on miss, fall back to the raw enum or
--     TextBlock contents.
--   ls.TutorialView -- a tutorial entry.  Title, IsNewTutorial,
--     HasBeenShown, DescriptionController.
local TUTORIAL_SECTION_LOCA_PREFIX =
    "h9de08869g5612g419fgbccbg4655074a1030"

local function ResolveTutorialSection(sectionValue)
    if not sectionValue or type(sectionValue) ~= "string"
        or sectionValue == "" then
        return nil
    end
    -- Larian enum->loca pattern: <prefix>_<EnumValue>.
    local handle = TUTORIAL_SECTION_LOCA_PREFIX .. "_" .. sectionValue
    if Ext.Loca and Ext.Loca.GetTranslatedString then
        local translated = Ext.Loca.GetTranslatedString(handle)
        if translated and translated ~= "" and translated ~= handle then
            return translated
        end
    end
    -- Fall back to the raw enum value (CamelCase like
    -- "InventoryAndItems") -- still readable.
    return sectionValue
end

local JournalTutorialsHandler = CreatePanelHandler({
    name = "JournalTutorials",
    hint = "Use bumpers to switch categories."
        .. " Up and down to browse tutorials.",
    customItemFn = function(focusedElement, handlerState, snapshot)
        local dcType = focusedElement.dcType
        local dcProps = focusedElement.dcProps

        -- Category expander.
        if dcType == "ls.TutorialContainer" and dcProps then
            local sectionName =
                ResolveTutorialSection(dcProps.SectionValue)
            if not sectionName or sectionName == "" then
                Log.Info("WALK-FALLBACK: TutorialContainer.SectionValue empty/unresolvable, walking text blocks")
                local readOk, headerTexts = pcall(
                    Ext.UI.ReadFocusedTextBlocks)
                if readOk and headerTexts and #headerTexts > 0 then
                    sectionName = Helpers.StripMarkupTags(headerTexts[1])
                end
            end
            if sectionName and sectionName ~= "" then
                local label = "Category, " .. sectionName
                local isChecked = focusedElement.isChecked
                if isChecked == true then
                    label = label .. ", expanded"
                elseif isChecked == false then
                    label = label .. ", collapsed"
                end
                return label, nil, nil
            end
            return "", nil, nil
        end

        -- Tutorial entry.
        if dcType == "ls.TutorialView" and dcProps then
            local entrySpeech = SpeechData.Create()
            local title = dcProps.Title
            if type(title) == "string" and title ~= "" then
                title = Helpers.GetTranslatedStringIfHandle(title)
                title = Helpers.StripMarkupTags(title)
                if title ~= "" then
                    entrySpeech:Add("name", title, "brief")
                end
            end
            -- "New" indicator (matches the bullet image in XAML).
            if dcProps.IsNewTutorial == "True"
                or dcProps.IsNewTutorial == true then
                entrySpeech:AddProperty("Status", "new", "brief")
            elseif dcProps.HasBeenShown == "False"
                or dcProps.HasBeenShown == false then
                entrySpeech:AddProperty("Status", "unread", "normal")
            end
            -- Description: DescriptionController is a CtxTransString,
            -- not extracted as a scalar.  The side panel renders it
            -- separately.  Skip for entry speech; the user can press
            -- A to view the side panel detail.
            if next(entrySpeech.coreFields) == nil
                and #entrySpeech.properties == 0 then
                Log.Info("WALK-FALLBACK: TutorialView scalars empty, walking text blocks")
                local readOk, texts = pcall(
                    Ext.UI.ReadFocusedTextBlocks)
                if readOk and texts and #texts > 0 then
                    local cleaned = Helpers.StripMarkupTags(texts[1])
                    if cleaned and cleaned ~= "" then
                        return cleaned, nil, nil
                    end
                end
                return "", nil, nil
            end
            return entrySpeech
        end

        return nil
    end,
})

-- Full-screen Combat Log overlay (JournalCombatLog_c.xaml).
-- Reachable from the RT shortcuts radial via the "Combat Log" entry.
--
-- Confirmed runtime DC: ls.Widget (generic, not a specialized DC
-- like the other journal panels).  Widget x:Name is
-- JournalCombatLog_c.  Because the DC isn't specialized, this
-- handler is routed by widget name via WIDGET_NAME_HANDLERS below
-- -- the same mechanism Menus.lua uses for shortcutsMenu sharing
-- gui::DCGameMenu with PauseMenu.
--
-- Structure: ListBox x:Name="Log" with ItemsSource bound to
-- Data.CombatLog.EntryGroupsReversed.  Each entry's content is
-- rendered via CtxTransString with parameter substitution
-- (player names, damage values, status names).
-- GetProperty("Text") returns nil for these bound strings, so we
-- read each focused ListBoxItem's TextBlock subtree via
-- Ext.UI.ReadFocusedTextBlocks -- the same fallback
-- JournalQuestsHandler uses for category / quest titles.
local CombatLogHandler = CreatePanelHandler({
    name = "CombatLog",
    hint = "Up and down to browse entries."
        .. " Right stick click for details. B to close.",
    customItemFn = function(focusedElement, handlerState, snapshot)
        -- JournalCombatLog_c.xaml uses the same virtualizing-list
        -- pattern as DialoguesTree (line 77 carries Larian's own
        -- comment: "Focus is always on ListBox and SelectedItem is
        -- not a FrameworkElement").  D-pad updates SelectedItem via
        -- ls:SelectNextListBoxItem ForceSelect=True; Larian's
        -- MoveFocus.IsFocused on the ListBoxItem container follows
        -- IsSelected, but Noesis keyboard focus stays on the outer
        -- ListBox.  Our class delegate's CSC-VM path captures the
        -- IsSelected ListBoxItem container into snapshot.selectedElement,
        -- so prefer it when focused isn't itself a ListBoxItem.
        local entry = focusedElement
        local entryElemId = focusedElement.elemId or ""
        if not entryElemId:find("^ListBoxItem::") then
            if snapshot.selectedElement
                and (snapshot.selectedElement.elemId or "")
                    :find("^ListBoxItem::") then
                entry = snapshot.selectedElement
            else
                -- Focused on the ListBox itself with no selection
                -- captured -- nothing to speak as an entry.  Generic
                -- pipeline would otherwise read the ListBox's name
                -- ("Combat Log") repeatedly.
                return ""
            end
        end

        -- ReadFocusedTextBlocks reads from the FOCUSED element's
        -- subtree.  When `entry` is the captured ListBoxItem (not
        -- the actual focused element), the read still uses Noesis
        -- focus -- which is the ListBox -- and would return ALL
        -- entries' text.  Only safe to call when `entry` is itself
        -- the focused element.  Fall through to selectedElement
        -- entry text via dcProps if available; otherwise the speech
        -- pipeline gets the elemText from the entry data table.
        if entry == focusedElement then
            local readOk, entryTexts = pcall(
                Ext.UI.ReadFocusedTextBlocks)
            if not readOk or not entryTexts or #entryTexts == 0 then
                return ""
            end
            -- Stitch all TextBlocks in the focused entry into one
            -- phrase.  Most entries are a single line, but multi-Run
            -- formats appear (e.g. "Intellect Devourer received
            -- Condition: Dash" where the condition name is a separate
            -- styled Run).  Strip markup tags from each chunk.
            local cleanedParts = {}
            for _, entryText in ipairs(entryTexts) do
                local cleaned = Helpers.StripMarkupTags(entryText)
                if cleaned and cleaned ~= "" then
                    cleanedParts[#cleanedParts + 1] = cleaned
                end
            end
            if #cleanedParts == 0 then return "" end
            return table.concat(cleanedParts, " ")
        end

        -- Selected ListBoxItem path: text comes from the entry's
        -- elemText (the C++ extractor populates this from the
        -- container's rendered text) or its templateTexts array.
        if entry.elemText and entry.elemText ~= "" then
            local cleaned = Helpers.StripMarkupTags(entry.elemText)
            if cleaned and cleaned ~= "" then return cleaned end
        end
        if type(entry.templateTexts) == "table"
            and #entry.templateTexts > 0 then
            local parts = {}
            for _, t in ipairs(entry.templateTexts) do
                local cleaned = Helpers.StripMarkupTags(t)
                if cleaned and cleaned ~= "" then
                    parts[#parts + 1] = cleaned
                end
            end
            if #parts > 0 then
                return table.concat(parts, " ")
            end
        end
        return ""
    end,
})

-- Brain panel handler is implemented in Client/TadpolePowers.lua to
-- isolate the brain-specific complexity (cursor input, ExtenderData
-- read for cost / recharge / duration / unavailable lines, prereq
-- lookup, future snap-to-power navigation).
local TadpoleHandler = BG3Access.Client.TadpolePowers
    .CreateTadpoleHandler(CreatePanelHandler)

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
            or (hasWidgetThisTick and not handlerState.currentTabContext)
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
                focusedElement, handlerState.currentTabContext, isScreenEntry)
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
    customItemFn = function(focusedElement, handlerState, snapshot)
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
                handlerState.screenEntryOverrides:Add(
                    "title", title, "brief")
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
        .. " A to switch active control."
        .. " X to group, Y to split, hold X to group all."
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
-- Tutorial / Notification de-dup claim set.  Populated by the Tutorial
-- handler when it extracts title/body from a Tutorial modal; consulted
-- by Notifications.lua before speaking a toast text.  Notification_c
-- and ModalTutorial_c both render the same tutorial title/body for
-- some popups (camp transitions etc.); without dedup the Tutorial
-- handler interrupts the queued notification toasts AND the
-- notification text would have already been queued.  With dedup,
-- Notifications skips toasts that the Tutorial handler is already
-- about to speak via screen entry.
--
-- Modal-only tutorials (no matching toast) speak normally via the
-- handler.  Toast-only notifications (no matching modal) speak
-- normally via Notifications.lua.
BG3Access.Client.TutorialClaimedTexts = BG3Access.Client.TutorialClaimedTexts or {}

local function ClaimTutorialText(text)
    if type(text) == "string" and text ~= "" then
        BG3Access.Client.TutorialClaimedTexts[text] = true
    end
end

local function ClearTutorialClaims()
    BG3Access.Client.TutorialClaimedTexts = {}
    BG3Access.Client.TutorialClaimedTexts =
        BG3Access.Client.TutorialClaimedTexts
end

-- ExtractTutorialContent: pull title and description out of widget
-- data or live widget DC.  Returns (title, description) with
-- unresolved-binding sentinels stripped, or nils if not yet ready.
-- Same logic regardless of which source we pulled from -- factored
-- out so both the synchronous onWidgetAdded path and the deferred
-- retry path use the same extraction rules.
local function ExtractTutorialContent(dcProps, namedTexts)
    if not dcProps then return nil, nil end
    local title, description = nil, nil
    local tutorial = dcProps.Tutorial
    if tutorial and type(tutorial) == "table" then
        local rawTitle = tutorial.Title
        if rawTitle and rawTitle ~= ""
            and not rawTitle:match("^h%x+g")
            and not rawTitle:find("%[ForceUpdate%]") then
            title = rawTitle
        end
        local rawDesc = tutorial.DescriptionController
            or tutorial.Description
        if rawDesc and rawDesc ~= ""
            and not rawDesc:match("^h%x+g")
            and not rawDesc:find("%[ForceUpdate%]") then
            description = rawDesc
        end
    end
    if not title then
        local rawTitle = dcProps.Title or dcProps.Text
        if rawTitle and rawTitle ~= ""
            and not rawTitle:match("^h%x+g") then
            title = rawTitle
        end
    end
    -- namedTexts fallback when neither dcProps nor sub-object yielded.
    if not title and not description and namedTexts then
        local parts = {}
        for _, elementText in pairs(namedTexts) do
            if elementText and elementText ~= ""
                and not elementText:match("^h%x+g")
                and not elementText:find("%[ForceUpdate%]") then
                parts[#parts + 1] = elementText
            end
        end
        if #parts > 0 then
            title = "Tutorial"
            description = table.concat(parts, ". ")
        end
    end
    return title, description
end

-- ReadLiveTutorialDcProps: re-read Tutorial widget's DataContext
-- props in the late-arrival case (deferred retry after Larian's
-- binding propagation completes).  Returns dcProps or nil.
local function ReadLiveTutorialDcProps()
    local widget = Ext.UI.FindNameInWidget("ModalTutorial_c")
    if not widget then return nil end
    local liveDc = nil
    pcall(function() liveDc = widget.DataContext end)
    if not liveDc then return nil end
    local liveProps = nil
    pcall(function() liveProps = liveDc:GetAllProperties() end)
    return liveProps
end

local TutorialHandler = CreatePanelHandler({
    name = "Tutorial",
    hint = "A to dismiss.",
    onWidgetAdded = function(widgetData, handlerState)
        local overrides = handlerState.screenEntryOverrides

        -- Sync extraction: if Larian's binding propagated before
        -- this event fired (the common case for tutorials that
        -- aren't immediately following a state transition), we can
        -- populate screenEntryOverrides right now and let the
        -- factory's screen entry pipeline speak it.  Single source.
        local title, description = ExtractTutorialContent(
            widgetData and widgetData.dcProps,
            widgetData and widgetData.namedTexts)

        if title or description then
            if title then
                overrides:Add("title", "Tutorial: " .. title, "brief")
                ClaimTutorialText(title)
            end
            if description then
                overrides:Add("description", description, "normal")
                ClaimTutorialText(description)
            end
            ClaimTutorialText("Dismiss")
            ClaimTutorialText("Finish")
            Log.Info("TUTORIAL (sync): title="
                .. tostring(title or "(none)")
                .. " body=" .. tostring(description or ""):sub(1, 60))
            -- Sync worked, no deferred retry needed.  Cancel any
            -- prior pending retry from a previous widget event.
            if handlerState.cancelPendingTutorialRead then
                handlerState.cancelPendingTutorialRead()
                handlerState.cancelPendingTutorialRead = nil
            end
            return
        end

        -- Sync extraction failed: Larian's dcProps.Tutorial binding
        -- hasn't propagated yet.  Defer via Scheduler -- canonical
        -- pattern for binding-propagation lag (matches the Tadpole
        -- count read).  When the retry fires, the binding will
        -- have settled; we read the live widget DC and speak as a
        -- queued Alert.  The factory's screen entry will already
        -- have spoken just the hint by that point, so the queued
        -- Alert plays AFTER it in order.
        --
        -- Cancel any prior pending read before scheduling a new
        -- one, so re-fires of onWidgetAdded (same widget event
        -- arriving multiple times during binding flux) collapse
        -- into a single deferred read at the final state.
        if handlerState.cancelPendingTutorialRead then
            handlerState.cancelPendingTutorialRead()
        end
        handlerState.cancelPendingTutorialRead =
            BG3Access.Client.Scheduler.RunAfterFrames(30, function()
                handlerState.cancelPendingTutorialRead = nil
                local liveProps = ReadLiveTutorialDcProps()
                if not liveProps then return end
                local lateTitle, lateDescription = ExtractTutorialContent(
                    liveProps, nil)
                if not lateTitle and not lateDescription then return end

                local parts = {}
                if lateTitle then
                    parts[#parts + 1] = "Tutorial: " .. lateTitle
                    ClaimTutorialText(lateTitle)
                end
                if lateDescription then
                    parts[#parts + 1] =
                        Helpers.StripMarkupTags(lateDescription)
                    ClaimTutorialText(lateDescription)
                end
                ClaimTutorialText("Dismiss")
                ClaimTutorialText("Finish")
                if #parts == 0 then return end
                local fullText = table.concat(parts, ". ")
                Log.Info("TUTORIAL (deferred): "
                    .. fullText:sub(1, 100))
                SpeechData.Alert(fullText, "queue")
            end)
    end,
    onReset = function(handlerState)
        if handlerState.cancelPendingTutorialRead then
            handlerState.cancelPendingTutorialRead()
            handlerState.cancelPendingTutorialRead = nil
        end
        ClearTutorialClaims()
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
                handlerState.screenEntryOverrides:Add(
                    "title", regionName, "brief")
            end
        end
    end,
    customItemFn = function(focusedElement, handlerState, snapshot)
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

        -- Announce "Waypoints" once when the waypoint panel opens
        -- (first VMWaypoint focus).  "Waypoints" goes through the
        -- `title` core field (sits before `name` in the formatter's
        -- order) so the formatter renders "Waypoints. <name>." from
        -- two distinct fields rather than the prior packed string.
        if focusedElement.dcType == "ls.VMWaypoint"
            and not handlerState.waypointsAnnounced then
            handlerState.waypointsAnnounced = true
            local waypointSpeech = SpeechData.Create()
            waypointSpeech:Add("title", "Waypoints", "brief")
            waypointSpeech:Add("name", waypointName, "brief")
            return waypointSpeech
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
    -- Title says where we are (unconditional, so the user always
    -- gets feedback that the book viewer opened).  Navigation hint
    -- explains line-by-line motion (hint-gated by hintsEnabled).
    -- Line count is informational tier.  Instruction hint carries
    -- the standard A/B controls (hint-gated).
    local speechData = SpeechData.Create()
    speechData:Add("title", "Book viewer", "brief")
    speechData:Add("navigationHint", "Use d-pad up and down"
        .. " to move line by line through the text.", "normal")
    speechData:AddProperty("Lines", lineCount .. " lines.", "normal")
    speechData:Add("instructionHint",
        "A to pick up. B to close.", "normal")
    speechData:Speak(handlerState, true)

    -- Subscribe to d-pad for line navigation (once).
    if not handlerState.buttonSubscription then
        handlerState.buttonSubscription =
            Ext.Events.ControllerButtonInput:Subscribe(function(event)
                local SettingsMenu = BG3Access.Client.SettingsMenu
                if SettingsMenu and SettingsMenu.IsOpen
                    and SettingsMenu.IsOpen() then
                    return
                end
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
                    -- Book line text is the entire reason the book
                    -- viewer exists.  sectionLabel is unconditional
                    -- in SpeechData.Format(); description would be
                    -- gated by the speakDescription toggle and would
                    -- vanish whenever the user's normal preset turns
                    -- descriptions off -- silencing the book they
                    -- opened specifically to read.
                    local lineSpeech = SpeechData.Create()
                    lineSpeech:Add("sectionLabel",
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
                    -- See DPadDown case for sectionLabel rationale.
                    local lineSpeech = SpeechData.Create()
                    lineSpeech:Add("sectionLabel",
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

-- Per-handler registration list.  The dispatcher in
-- Client/Dispatcher.lua reads these entries to resolve which handler
-- owns a snapshot.  Each entry's openWhen declares the signals that
-- identify the panel; dcTypes are matched against widget DCs AND
-- focused/selected element DCs (for per-item ViewModels like
-- VMSpellBook, VMRangeStat, etc.).
--
-- Defaults: activateMode = "auto", canStack = false.  Override on
-- entries that need different behavior:
--   - PartyLine uses activateMode="explicit" because it's the always-
--     loaded HUD portrait row; pickup must NOT auto-activate it.
--     Explicit activation comes from a widgetAdded event on
--     PartyLineActive_c (the LT-opened party panel).
--   - Panels that commonly have overlays opening on top (Container,
--     Examine, Compare, etc. opening over CharacterPanel) set
--     canStack=true so the underlying panel resumes when the overlay
--     closes.  Panels that don't typically host overlays leave
--     canStack=false (default) -- harmless if overridden either way,
--     but precise registration documents intent.
local registeredPanelHandlers = {
    -- Character sheet / inventory.  Bottom of most overlay stacks
    -- (containers and examines pop on top of it), so canStack=true.
    {
        name    = "CharacterPanel",
        handler = CharacterPanelHandler,
        canStack = true,
        openWhen = {
            dcTypes = {
                ["gui::DCCharacterPanels"] = true,
                ["ls.DCCharacterPanels"]   = true,
            },
        },
    },
    -- Spell book.  Outer widget DC is generic (ls.Widget); the
    -- identifying signal is ls.VMSpellBook on focused/selected
    -- elements, plus the SpellBook_c widget x:Name.
    {
        name    = "SpellBook",
        handler = SpellBookHandler,
        canStack = true,
        openWhen = {
            widgetNames = { ["SpellBook_c"] = true },
            dcTypes = {
                ["gui::VMSpellBook"] = true,
                ["ls.VMSpellBook"]   = true,
            },
        },
    },
    {
        name    = "Trade",
        handler = TradeHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCTrade"] = true,
                ["ls.DCTrade"]   = true,
            },
        },
    },
    -- Container inventory (bags, pouches).  Common overlay over
    -- CharacterPanel.
    {
        name    = "Container",
        handler = ContainerHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCContainerInventory"] = true,
                ["ls.DCContainerInventory"]   = true,
            },
        },
    },
    -- Examine / inspect.  Widget DC is generic ls.Widget, so the
    -- identifying signal is per-item VMs (VMRangeStat, VMResistance)
    -- on the focused element.
    {
        name    = "Examine",
        handler = ExamineHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCExamine"]    = true,
                ["ls.DCExamine"]      = true,
                ["gui::VMRangeStat"]  = true,
                ["ls.VMRangeStat"]    = true,
                ["gui::VMResistance"] = true,
                ["ls.VMResistance"]   = true,
            },
        },
    },
    {
        name    = "ActiveRoll",
        handler = ActiveRollHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCActiveRoll"] = true,
                ["ls.DCActiveRoll"]   = true,
            },
        },
    },
    {
        name    = "Reaction",
        handler = ReactionHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCReactionDecision"] = true,
                ["ls.DCReactionDecision"]   = true,
            },
        },
    },
    {
        name    = "Alchemy",
        handler = AlchemyHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCAlchemy"] = true,
                ["ls.DCAlchemy"]   = true,
            },
        },
    },
    {
        name    = "Combine",
        handler = CombineHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCCombine"] = true,
                ["ls.DCCombine"]   = true,
            },
        },
    },
    {
        name    = "Donate",
        handler = DonateHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCDonate"] = true,
                ["ls.DCDonate"]   = true,
            },
        },
    },
    {
        name    = "Pickpocket",
        handler = PickpocketHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCPickpocket"] = true,
                ["ls.DCPickpocket"]   = true,
            },
        },
    },
    {
        name    = "LearnSpells",
        handler = LearnSpellsHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCLearnSpells"] = true,
                ["ls.DCLearnSpells"]   = true,
            },
        },
    },
    {
        name    = "Camp",
        handler = CampHandler,
        canStack = true,
        openWhen = {
            dcTypes = {
                ["gui::DCMakeCamp"] = true,
                ["ls.DCMakeCamp"]   = true,
            },
        },
    },
    {
        name    = "JournalQuests",
        handler = JournalQuestsHandler,
        canStack = true,
        openWhen = {
            dcTypes = {
                ["gui::DCJournalQuests"] = true,
                ["ls.DCJournalQuests"]   = true,
            },
        },
    },
    {
        name    = "JournalDialogues",
        handler = JournalDialoguesHandler,
        canStack = true,
        openWhen = {
            dcTypes = {
                ["gui::DCJournalDialogues"] = true,
                ["ls.DCJournalDialogues"]   = true,
            },
        },
    },
    -- Inspiration: DC type confirmed via the keyboard sibling
    -- JournalInspiration.xaml which declares
    -- ls:UIWidget.ContextName="JournalInspiration" and
    -- d:DesignInstance {x:Type ls:DCJournalInspiration}.  The
    -- controller variant JournalInspiration_c.xaml omits the redeclare
    -- but inherits the same DC via the state machine binding (same
    -- pattern as all other journal _c variants).
    {
        name    = "JournalInspiration",
        handler = JournalInspirationHandler,
        canStack = true,
        openWhen = {
            widgetNames = { ["JournalInspiration_c"] = true },
            dcTypes = {
                ["gui::DCJournalInspiration"] = true,
                ["ls.DCJournalInspiration"]   = true,
            },
        },
    },
    -- Tutorials: ls:UIWidget.ContextName="JournalTutorial" with
    -- d:DesignInstance {x:Type ls:JournalTutorial} -- DC type is
    -- ls.JournalTutorial (note: NOT a DC* prefix; this one is named
    -- after the VM directly).
    {
        name    = "JournalTutorials",
        handler = JournalTutorialsHandler,
        canStack = true,
        openWhen = {
            widgetNames = { ["JournalTutorials_c"] = true },
            dcTypes = {
                ["gui::JournalTutorial"] = true,
                ["ls.JournalTutorial"]   = true,
            },
        },
    },
    -- Combat log.  Outer widget has generic ls.Widget DC; identify
    -- by widget x:Name only.
    {
        name    = "CombatLog",
        handler = CombatLogHandler,
        openWhen = {
            widgetNames = { ["JournalCombatLog_c"] = true },
        },
    },
    {
        name    = "Tadpole",
        handler = TadpoleHandler,
        openWhen = {
            -- widgetNames is the stable liveness signal: the
            -- TadpolePowersTree_c widget has an x:Name in the XAML
            -- and stays in snapshot.allWidgetNames as long as the
            -- panel is loaded.  dcTypes is also listed but it can
            -- transiently report empty in allWidgetDCTypes when the
            -- DC swap fires (cutscene-overlay events trigger this
            -- every couple seconds), which would falsely deactivate
            -- this handler if widgetNames weren't there as backstop.
            widgetNames = { ["TadpolePowersTree_c"] = true },
            dcTypes = {
                ["gui::DCTadpolePowersTree"] = true,
                ["ls.DCTadpolePowersTree"]   = true,
            },
        },
    },
    {
        name    = "SelectionFlyOut",
        handler = SelectionFlyOutHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCSelectionFlyOut"] = true,
                ["ls.DCSelectionFlyOut"]   = true,
                ["gui::DCActiveSearch"]    = true,
                ["ls.DCActiveSearch"]      = true,
            },
        },
    },
    {
        name    = "Reward",
        handler = RewardHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCRewardPanel"] = true,
                ["ls.DCRewardPanel"]   = true,
            },
        },
    },
    {
        name    = "SavePopup",
        handler = SavePopupHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCNewSavegamePopup"] = true,
                ["ls.DCNewSavegamePopup"]   = true,
            },
        },
    },
    {
        name    = "Honour",
        handler = HonourHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCProofOfHonour"] = true,
                ["ls.DCProofOfHonour"]   = true,
            },
        },
    },
    {
        name    = "Connectivity",
        handler = ConnectivityHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCConnectivityMenu"] = true,
                ["ls.DCConnectivityMenu"]   = true,
            },
        },
    },
    {
        name    = "SignUp",
        handler = SignUpHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCSignUp"] = true,
                ["ls.DCSignUp"]   = true,
            },
        },
    },
    {
        name    = "FirstTimeSetup",
        handler = FirstTimeSetupHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCFirstTimeSetup"] = true,
                ["ls.DCFirstTimeSetup"]   = true,
            },
        },
    },
    {
        name    = "HDR",
        handler = HDRHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCHDRCalibration"] = true,
                ["ls.DCHDRCalibration"]   = true,
            },
        },
    },
    {
        name    = "Gamma",
        handler = GammaHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCGammaCalibration"] = true,
                ["ls.DCGammaCalibration"]   = true,
            },
        },
    },
    {
        name    = "Report",
        handler = ReportHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCReport"] = true,
                ["ls.DCReport"]   = true,
            },
        },
    },
    -- Party line: HUD portrait row that's always loaded.  Auto-pickup
    -- must NOT activate it -- only an explicit widgetAdded event for
    -- the PartyLineActive_c widget (the LT-opened party panel) does.
    {
        name         = "PartyLine",
        handler      = PartyLineHandler,
        activateMode = "explicit",
        openWhen = {
            -- PartyLineActive_c is the navigable LT panel.  PartyLine_c
            -- (the HUD row) shares the DC but uses a different x:Name;
            -- name-based registration distinguishes them.  An explicit
            -- widgetAdded event on PartyLineActive_c activates this
            -- handler; nothing else does.
            widgetNames = { ["PartyLineActive_c"] = true },
            dcTypes = {
                ["gui::DCPartyLine"] = true,
                ["ls.DCPartyLine"]   = true,
            },
        },
    },
    {
        name    = "Lobby",
        handler = LobbyHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCLobby"] = true,
                ["ls.DCLobby"]   = true,
            },
        },
    },
    {
        name    = "Tutorial",
        handler = TutorialHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCTutorial"] = true,
                ["ls.DCTutorial"]   = true,
            },
        },
    },
    {
        name    = "Book",
        handler = BookHandler,
        canStack = true,
        openWhen = {
            dcTypes = {
                ["gui::DCBook"] = true,
                ["ls.DCBook"]   = true,
            },
        },
    },
    {
        name    = "Map",
        handler = MapHandler,
        openWhen = {
            dcTypes = {
                ["gui::DCJournalMap"] = true,
                ["ls.JournalMap"]     = true,
            },
        },
    },
}

-- ============================================================================
-- Dispatcher
-- ============================================================================
--
-- The dispatcher in Client/Dispatcher.lua handles handler lifecycle:
-- liveness checks, widget-event activation, pickup, overlay stacking
-- (canStack), explicit-only activation (activateMode), reset.  All the
-- old per-module ad-hoc state (activePanelHandler, previousPanelHandler,
-- activePanelHandlerWidgetAddr, activePanelHandlerDCType, DC_TYPE_HANDLERS,
-- WIDGET_NAME_HANDLERS, DISCOVERY_ONLY_DC_TYPES, ALL_PANEL_HANDLERS) is
-- replaced by registeredPanelHandlers + Dispatcher.Create.

local Dispatcher = BG3Access.Client.Dispatcher

local worldUIDispatcher_Create = Dispatcher.Create({
    name = "WorldUI",
    handlers = registeredPanelHandlers,
    -- Skip dispatch entirely while a radial menu is open.  Radial
    -- slot changes are handled by HandleRadialSlot, not panel
    -- discovery; otherwise PartyLine or other background DC types
    -- would activate a panel handler during radial use.
    skipWhen = function(snapshot)
        return inRadial == true
    end,
    onActivate = function(entry)
        -- Close detail/compare views when active handler changes
        -- (overlay took over, tab switch, etc.) so their d-pad
        -- subscriptions don't persist into the new context.
        CloseDetailView(true)
        CloseCompareView(true)
    end,
    onDeactivate = function(entry)
        -- Same teardown as onActivate.  Detail / compare views
        -- assume an active handler context.
        CloseDetailView(true)
    end,
})
-- Assign to the forward-declared upvalue so closures earlier in
-- this file (DispatchTooltip etc.) can query the dispatcher.
worldUIDispatcher = worldUIDispatcher_Create

--- IsWorldDCType: thin wrapper exposing the dispatcher's DC-type
--- registration check.  Returns false for the PartyLine HUD DC types
--- since PartyLine uses activateMode="explicit" -- those DC types
--- don't trigger world routing on their own (the explicit signal
--- would be a widgetAdded event for PartyLineActive_c).
local function IsWorldDCType(dcType)
    if not dcType then return false end
    -- PartyLine HUD DC: skip the DC check.  PartyLineActive_c (the
    -- LT panel) gets routed via widget-name match through
    -- IsWorldWidgetName / HandlePanelWidgetAdded; the bare DC alone
    -- shouldn't flip routing to world.
    if dcType == "gui::DCPartyLine" or dcType == "ls.DCPartyLine" then
        return false
    end
    return worldUIDispatcher:IsRegisteredDCType(dcType)
end

--- IsWorldWidgetName: returns true if any registered handler claims
--- this widget x:Name in its openWhen.widgetNames set.
local function IsWorldWidgetName(widgetName)
    if not widgetName or widgetName == "" then return false end
    for _, entry in ipairs(registeredPanelHandlers) do
        local criterion = entry.openWhen
        if criterion and criterion.widgetNames
            and criterion.widgetNames[widgetName] then
            return true
        end
    end
    return false
end


--- HandlePanelWidgetAdded: forwards widget events to the dispatcher.
--- The dispatcher's match logic prefers widget x:Name (so PartyLineActive_c
--- routes to PartyLine even though the DC matches multiple registrations)
--- and falls back to DC type.  activateMode="explicit" handlers (PartyLine)
--- only activate via this path, never via pickup.
local function HandlePanelWidgetAdded(widgetData)
    if not widgetData or not widgetData.dcType then return end
    Log.Debug("[BG3A_BC] phase=worldui_widget_added dc="
        .. tostring(widgetData.dcType)
        .. " name=" .. tostring(widgetData.elemName or "?")
        .. " widget=" .. tostring(widgetData.widgetRootId or "?"))
    worldUIDispatcher:HandleWidgetAdded(widgetData)
end

--- HandlePanelWidgetRootChanged: forwards to dispatcher.  The
--- dispatcher's RouteSnapshot Step 1 (liveness) handles the case
--- where the new root indicates the handler's widget is gone --
--- the openWhen check naturally fails when the widget no longer
--- claims the focus.  No special re-anchoring logic needed.
local function HandlePanelWidgetRootChanged(newWidgetRootId)
    worldUIDispatcher:HandleWidgetRootChanged()
end

--- RoutePanelSnapshot: called by EventRouter for all snapshots when
--- routing is in WorldUI.  Delegates to the dispatcher; if no handler
--- ends up dispatched (no panel is open in the snapshot), checks
--- whether a menu DC is present and falls back to Menus.RouteSnapshot.
--- That fallback is WorldUI-Menus boundary logic -- not part of
--- handler dispatch -- so it stays here, not in Dispatcher.lua.
--- @param snapshot table  The full TickSnapshot from C++.
local function RoutePanelSnapshot(snapshot)
    Log.Debug("[BG3A_BC] phase=worldui_route_begin handler="
        .. (worldUIDispatcher:GetActiveHandler()
            and worldUIDispatcher:GetActiveEntry().name or "nil"))

    -- Track focused DC for tooltip context (used by DispatchTooltip).
    if snapshot.focusedElement and snapshot.focusedElement.dcType then
        lastFocusedDCType = snapshot.focusedElement.dcType
    end

    -- Dispatcher does liveness, pickup, and dispatch in one call.  If
    -- a handler is current after this returns, the snapshot was
    -- delivered.  If not, we fall through to the Menus boundary check.
    worldUIDispatcher:RouteSnapshot(snapshot)

    if worldUIDispatcher:GetActiveHandler() then return end

    -- No panel handler active.  Check whether the snapshot carries
    -- a menu DC type (e.g. gui::DCGameMenu from the shortcuts menu).
    -- Menus on separate visual layers don't fire panel widgetAdded
    -- events, so they reach here with routeToWorld still true.  Only
    -- fall back to Menus when a genuine menu signal is present;
    -- without this guard, HUD widget text (Overlay, Actions, etc.)
    -- would be spoken as menu content when returning to the world
    -- after closing any panel.
    local Menus = BG3Access.Client.Menus
    if not Menus then return end

    local hasMenuSignal = false
    if snapshot.focusedElement and snapshot.focusedElement.dcType
        and Menus.IsMenuDCType(snapshot.focusedElement.dcType) then
        hasMenuSignal = true
    end
    if not hasMenuSignal and snapshot.selectedElement
        and snapshot.selectedElement.dcType
        and Menus.IsMenuDCType(snapshot.selectedElement.dcType) then
        hasMenuSignal = true
    end
    if not hasMenuSignal and snapshot.widgetDCTypes then
        for _, widgetDCType in ipairs(snapshot.widgetDCTypes) do
            if Menus.IsMenuDCType(widgetDCType) then
                hasMenuSignal = true
                break
            end
        end
    end
    if hasMenuSignal then
        Log.Info("RoutePanelSnapshot: menu DC type detected, "
            .. "falling back to Menus")
        Menus.RouteSnapshot(snapshot)
    end
end

--- ResetAllPanelHandlers: forwards to dispatcher, plus close detail
--- and compare views (their d-pad subscriptions assume a panel
--- context).  Called on GameStateChanged.
local function ResetAllPanelHandlers()
    CloseDetailView(true)
    CloseCompareView(true)
    worldUIDispatcher:Reset()
end

--- TryActivateFromSnapshot: forwards to the dispatcher's pickup pass.
--- Returns true if a handler is active after the call (either was
--- already current or got activated by pickup).  Called by EventRouter
--- to detect "this snapshot belongs in WorldUI" without yet
--- dispatching -- the dispatch happens in RoutePanelSnapshot once
--- EventRouter has flipped routing.
local function TryActivateFromSnapshot(snapshot)
    return worldUIDispatcher:TryPickup(snapshot)
end

--- GetActivePanelHandler: returns the currently active panel handler.
--- @return table|nil
local function GetActivePanelHandler()
    return worldUIDispatcher:GetActiveHandler()
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
    -- Tooltip state (also clears radialHandlerState's spokenRoles
    -- cross-off + lastSpokenFullText).
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
    IsRadialOpen               = IsRadialOpen,
    GetRadialDetailHandler     = GetRadialDetailHandler,
    -- Panel routing
    IsWorldDCType              = IsWorldDCType,
    IsWorldWidgetName          = IsWorldWidgetName,
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

