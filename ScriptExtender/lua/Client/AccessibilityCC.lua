-- File: Client/AccessibilityCC.lua
--
-- Character Creation specific snapshot handler.
--
-- CC uses a god-object DataContext (gui::DCCharacterCreation) with 100+
-- properties.  Generic FormatDCText/FormatDCTextSplit cannot extract useful
-- text from it.  This module handles all CC-specific logic in isolation
-- so it cannot affect other menus.
--
-- The Manager detects CC and delegates here via HandleCCSnapshot().
-- This module reads/writes shared state through a state table reference.

local Log = BG3Access.Client.Log
local H   = BG3Access.Client.Helpers

-- ============================================================================
-- Constants
-- ============================================================================

-- Maps DC types of carousel items to their section/page name.
local CC_SECTION_LABELS = {
    ["ls.VMSelectableOrigin"]         = "Origin",
    ["ls.VMSelectableRace"]           = "Race",
    ["ls.VMSelectableSubRace"]        = "Subrace",
    ["ls.VMSelectableClass"]          = "Class",
    ["ls.VMSelectableSubClass"]       = "Subclass",
    ["ls.VMSelectable"]               = "Background",
    ["ls.VMAbilityBonusSelection"]    = "Ability Bonus",
    ["ls.VMSelectableCantrip"]        = "Cantrip",
    ["ls.VMSelectableSpell"]          = "Spell",
    ["ls.VMSelectableFeat"]           = "Feat",
    ["ls.VMCharacterCreationSkill"]   = "Skills",
    ["ls.VMSpellReference"]           = "Spell",
}

-- Body type name mapping (XAML x:Name -> display name).
local BODY_TYPE_NAMES = {
    female       = "Slim feminine",
    male         = "Slim masculine",
    femaleStrong = "Muscular feminine",
    maleStrong   = "Muscular masculine",
}

-- CC toggle items whose INPC Value=0/1 should be spoken as "On"/"Off".
local CC_BOOLEAN_TOGGLES = {
    ["Heterochromia"]  = true,
    ["Hide Clothes"]   = true,
    ["CoverNudity"]    = true,
}

-- Maps god-object property name -> display label for origin page items.
local CC_ORIGIN_PROPERTY_LABELS = {
    { property = "SelectedIdentity",  label = "Identity" },
    { property = "BodyTypeAndShape",  label = "Body Type" },
}

-- Tab name overrides for god-object property pattern exceptions.
local GOD_OBJECT_EXCEPTIONS = {
    -- ["WeirdTabName"] = "SelectedActualPropertyName",
}

-- ============================================================================
-- CC Helper Functions
-- ============================================================================

-- Get the CC section label from a data table's dcType.
-- Returns section name string or nil.
local function GetSectionLabel(data)
    if not data or not data.dcType then return nil end
    local label = CC_SECTION_LABELS[data.dcType]
    if not label then return nil end

    -- Subrace detection: ls.VMSelectableRace is used for both races and
    -- subraces.  Subraces have an underscore in their IDString.
    if label == "Race" and data.dcProps and data.dcProps.IDString then
        if data.dcProps.IDString:find("_") then
            label = "Subrace"
        end
    end

    return label
end

-- Get a body type display name from an element name, or nil.
local function GetBodyTypeName(elemName)
    if not elemName then return nil end
    return BODY_TYPE_NAMES[elemName]
end

-- Extract title and description from the CC god-object using tab context.
-- Larian convention: tab "Race" -> SelectedRace sub-table, InfoRaceDescription.
-- Returns (titleText, bodyText).
local function ExtractContextualGodObjectText(dcProps, currentTab)
    if not dcProps or not currentTab then return nil, nil end

    local tabKey = currentTab:gsub("[%s%-%.]+", "")
    local titleText = nil
    local bodyText = nil

    -- Look for the active Selected[Tab] sub-object.
    local selectedKey = "Selected" .. tabKey
    local activeObject = dcProps[selectedKey]
    if not activeObject and GOD_OBJECT_EXCEPTIONS[tabKey] then
        selectedKey = GOD_OBJECT_EXCEPTIONS[tabKey]
        activeObject = dcProps[selectedKey]
    end

    if type(activeObject) == "table" then
        titleText = activeObject.Name or activeObject.DisplayName
                 or activeObject.Title or activeObject.Text
        if not titleText or titleText == "" then
            titleText = nil
        end
    end

    -- Look for contextual description string.
    local descKey = "Info" .. tabKey .. "Description"
    local descProp = dcProps[descKey]
    if type(descProp) == "string" and descProp ~= "" then
        bodyText = descProp
    else
        local fallbackDescKey = tabKey .. "Description"
        local fallbackDesc = dcProps[fallbackDescKey]
        if type(fallbackDesc) == "string" and fallbackDesc ~= "" then
            bodyText = fallbackDesc
        end
    end

    return titleText, bodyText
end

-- Extract text from CC-specific dcProps (Skill, Ability, Spell sub-table).
-- Returns (name, value, description) or all nils.
local function FormatCCDCTextSplit(dcProps)
    if not dcProps then return nil, nil, nil end

    local text = nil
    local value = nil
    local desc = dcProps.Description

    -- Skill enum: VMCharacterCreationSkill has Skill + Ability.
    -- Check Skill FIRST so "Arcana" wins over "Intelligence".
    if dcProps.Skill then
        text = dcProps.Skill
        if dcProps.Value then
            local modifier = tonumber(dcProps.Value) or 0
            local sign = modifier >= 0 and "+" or ""
            value = sign .. tostring(modifier)
        end
    end

    -- Ability enum: VMAbility.Ability = "Strength", etc.
    if not text and dcProps.Ability then
        text = dcProps.Ability
        if dcProps.Value then
            value = tostring(dcProps.Value)
            if dcProps.Modifier then
                local modifier = tonumber(dcProps.Modifier) or 0
                local sign = modifier >= 0 and "+" or ""
                value = value .. " (" .. sign .. tostring(modifier) .. ")"
            end
        end
    end

    -- VMSpellReference: Spell sub-table has the spell details.
    if not text and type(dcProps.Spell) == "table" then
        local spellTable = dcProps.Spell
        text = spellTable.Name or spellTable.DisplayName
            or spellTable.Title or spellTable.Text
        if not desc then
            desc = spellTable.Description
        end
    end

    if not text or text == "" then return nil, nil, nil end
    return text, value, desc
end

-- Origin page context labels.  Maps elemText to god-object properties.
-- Returns (name, value, description) or all nils.
local function ExtractOriginContext(data)
    if not data or not data.dcProps then return nil, nil, nil end
    if data.dcType ~= "gui::DCCharacterCreation" then return nil, nil, nil end
    local elemText = data.elemText
    if not elemText or elemText == "" then return nil, nil, nil end

    -- Check if elemText matches a known god-object property value.
    for _, mapping in ipairs(CC_ORIGIN_PROPERTY_LABELS) do
        local propertyValue = data.dcProps[mapping.property]
        if type(propertyValue) == "string" and propertyValue ~= "" then
            if elemText == propertyValue then
                return mapping.label .. ": " .. elemText, nil, nil
            end
        end
    end

    -- Body type numeric ID: substitute the readable BodyTypeAndShape value.
    if elemText:match("^%d+$") and data.dcProps.BodyTypeAndShape then
        return "Body Type: " .. data.dcProps.BodyTypeAndShape, nil, nil
    end

    -- Origin name (Custom, Astarion, etc.): match against SelectedOrigin.
    local selectedOrigin = data.dcProps.SelectedOrigin
    if type(selectedOrigin) == "table" then
        local originName = selectedOrigin.Name or selectedOrigin.DisplayName
            or selectedOrigin.Title
        if originName and H.NormalizeForCompare(elemText) == H.NormalizeForCompare(originName) then
            local originDesc = selectedOrigin.Description
            if type(originDesc) == "string" and originDesc ~= "" then
                return elemText, nil, originDesc
            end
        end
    end

    return nil, nil, nil
end

-- Format CC INPC value change.  Converts 0/1 to On/Off for known toggles.
local function FormatCCValue(dcProps)
    if not dcProps then return nil end
    local value = dcProps.Value
    if value and value ~= "" then
        local itemText = dcProps.Text
        if itemText and CC_BOOLEAN_TOGGLES[itemText] then
            if value == 1 or value == "1" or value == true then
                return "On"
            elseif value == 0 or value == "0" or value == false then
                return "Off"
            end
        end
        return tostring(value)
    end
    return nil
end

-- ============================================================================
-- CC Detection (called by Manager)
-- ============================================================================

-- Returns true if this snapshot should be handled by the CC module.
local function IsCCSnapshot(snapshot)
    local focusedElement = snapshot.focusedElement
    if not focusedElement then return false end

    -- God-object DC.
    if focusedElement.dcType == "gui::DCCharacterCreation" then
        return true
    end

    -- CC VM type on focused element.
    if focusedElement.dcType and CC_SECTION_LABELS[focusedElement.dcType] then
        return true
    end

    -- CC VM type on selected element.
    if snapshot.selectedElement and snapshot.selectedElement.dcType
        and CC_SECTION_LABELS[snapshot.selectedElement.dcType] then
        return true
    end

    return false
end

-- ============================================================================
-- CC Snapshot Handler
-- ============================================================================

-- Shared speech slot assembly (same order as Manager).
local SLOT_ORDER = { "title", "hint", "tabName", "body", "itemName", "itemValue", "itemDesc" }

local function SpeakSlots(slots, state, isScreenEntry)
    local parts = {}
    for _, slotName in ipairs(SLOT_ORDER) do
        local slotValue = slots[slotName]
        if slotValue and slotValue ~= "" then
            table.insert(parts, (slotValue:gsub("[%.%s]+$", "")))
        end
    end
    if #parts == 0 then return end
    local assembled = H.StripMarkupTags(table.concat(parts, ". "))
    if not assembled or assembled == "" then return end

    local interrupt = true
    if state.screenEntryJustSpoke and not isScreenEntry then
        interrupt = false
        state.screenEntryJustSpoke = false
    end
    if isScreenEntry then
        state.screenEntryJustSpoke = true
    end

    Log.Info("SPEAK" .. (interrupt and "" or " (append)") .. ": " .. assembled)
    Ext.Tolk.Speak(assembled, interrupt)
    state.lastSpokenFullText = assembled
end

-- Main CC handler.  Called by Manager when IsCCSnapshot returns true.
-- state is a table reference to shared Manager state variables.
local function HandleCCSnapshot(snapshot, state)
    local focusedElement = snapshot.focusedElement

    -- =================================================================
    -- Classify the change.
    -- =================================================================
    local elemId = focusedElement.elemId or ""
    local hasCarousel = snapshot.inlineCarouselChanged
        and snapshot.inlineCarouselValue
        and snapshot.inlineCarouselValue ~= ""

    -- Determine section labels.
    local focusedSectionLabel = GetSectionLabel(focusedElement)
    local selectedSectionLabel = nil
    if snapshot.selectedElement then
        selectedSectionLabel = GetSectionLabel(snapshot.selectedElement)
    end
    local detectedSectionLabel = selectedSectionLabel or focusedSectionLabel

    -- Determine tab name from selectedElement.tabName (header carousel tab
    -- like "Appearance" whose VM type isn't in CC_SECTION_LABELS).
    local selectedTabName = nil
    if snapshot.selectedElement and snapshot.selectedElement.isTab
        and snapshot.selectedElement.tabName then
        selectedTabName = snapshot.selectedElement.tabName
    end

    -- Best available section/tab identifier.
    local bestTabLabel = detectedSectionLabel or selectedTabName

    local isScreenEntry = false
    if snapshot.selectionChanged then
        -- Same section = in-page cycling (body type, Custom/Origin, etc.).
        -- Different section or unknown = tab switch.
        if selectedSectionLabel and selectedSectionLabel == state.lastSpokenTab then
            Log.Debug("CC same-section selection: " .. selectedSectionLabel)
        else
            isScreenEntry = true
        end
    elseif snapshot.focusChanged and focusedElement.isTab then
        isScreenEntry = true
    end

    -- Section-change detection: focus moves to an element whose section
    -- label differs from lastSpokenTab (e.g. Spell page buttons).
    if not isScreenEntry and snapshot.focusChanged
        and focusedSectionLabel and focusedSectionLabel ~= state.lastSpokenTab then
        isScreenEntry = true
        Log.Info("CC section change detected: " .. tostring(focusedSectionLabel))
    end

    local isItemNav = snapshot.focusChanged
        and not focusedElement.isTab and not isScreenEntry
    local isCarouselOnly = hasCarousel and not snapshot.focusChanged
    local isValueOnly = not isScreenEntry and not isItemNav
        and not isCarouselOnly and snapshot.valueChanged

    -- Nothing to do?
    if not isScreenEntry and not isItemNav
        and not isCarouselOnly and not isValueOnly then
        return
    end

    -- =================================================================
    -- Standalone carousel or value change.
    -- =================================================================
    if isCarouselOnly then
        local carouselValue = snapshot.inlineCarouselValue
        if carouselValue ~= state.lastSpokenFullText then
            state.lastSpokenFullText = carouselValue
            Log.Info("CAROUSEL: " .. carouselValue)
            Ext.Tolk.Speak(carouselValue, true)
        end
        return
    end

    if isValueOnly then
        local valueText = FormatCCValue(focusedElement.dcProps)
        if not valueText then
            valueText = H.FormatDCValue(focusedElement.dcProps)
        end
        if valueText and valueText ~= "" and valueText ~= state.lastSpokenFullText then
            state.lastSpokenFullText = valueText
            Log.Info("VALUE: " .. valueText)
            Ext.Tolk.Speak(valueText, true)
        end
        return
    end

    -- =================================================================
    -- Screen entry or item navigation.
    -- =================================================================
    local slots = {}
    local tabName = nil
    local ccItemName = nil

    if isScreenEntry then
        -- ----- Derive tab name -----
        if focusedElement.isTab then
            tabName = focusedElement.tabName
        end
        if not tabName and detectedSectionLabel then
            tabName = detectedSectionLabel
            -- When tab comes from section label, the focused element's text
            -- is the first item (e.g. "Elf" on the Race page).
            ccItemName = H.ExtractTextFromData(focusedElement, nil, false)
        end
        if not tabName and selectedTabName then
            tabName = selectedTabName
        end

        -- Appearance carousel (unnamed ListBoxItem).
        if tabName and tabName:find("^ListBoxItem:") then
            local itemLabel = focusedElement.elemName
                and GetBodyTypeName(focusedElement.elemName)
            if not itemLabel then
                itemLabel = tabName:match("^ListBoxItem:%s*(.+)$") or tabName
            end
            slots["itemName"] = itemLabel
            state.lastSpokenName = elemId
            state.lastSpokenFullText = itemLabel
            Log.Info("ITEM: appearance  name=" .. itemLabel)
            SpeakSlots(slots, state)
            return
        end

        -- Dedup: skip if same tab.
        if tabName and tabName == state.lastSpokenTab then
            Log.Debug("SKIP CC screen entry (same tab): " .. tabName)
            return
        end

        Log.Info("SCREEN ENTRY: tab=" .. tostring(tabName)
            .. " sel=" .. tostring(snapshot.selectionChanged)
            .. " widget=" .. tostring(snapshot.widgetAdded))

        -- Update lastSpokenTab.  Clear when entering a screen with no tab
        -- (e.g. unrecognized page) so the next tab is detected as a change.
        state.lastSpokenTab = tabName
        state.lastSpokenName = nil

        -- ----- Title -----
        local screenTitle = nil
        local effectiveDCType = state.currentWidgetDCType
            or (snapshot.widgetData and snapshot.widgetData.dcType)
        if effectiveDCType == "gui::DCCharacterCreation" then
            screenTitle = "Character Creation"
        end
        local normalTab = tabName and H.NormalizeForCompare(tabName) or ""
        if screenTitle and normalTab ~= ""
            and H.NormalizeForCompare(screenTitle) == normalTab then
            screenTitle = nil
        end
        if screenTitle and screenTitle == state.lastSpokenTitle then
            screenTitle = nil
        end
        if screenTitle then
            state.lastSpokenTitle = screenTitle
            slots["title"] = screenTitle
        end

        -- ----- Hint -----
        if not state.tabHintSpoken then
            state.tabHintSpoken = true
            slots["hint"] = "Use bumpers to switch tabs."
        end

        -- ----- Tab name -----
        if tabName then
            local showTabName = true
            if screenTitle and H.NormalizeForCompare(screenTitle):find(normalTab, 1, true) then
                showTabName = false
            end
            if showTabName then
                slots["tabName"] = tabName
            end
        end
    else
        -- Item navigation: dedup check.
        if elemId == state.lastSpokenName and not hasCarousel then
            local text = H.ExtractTextFromData(focusedElement, state.lastSpokenTab, false)
            if not text or text == state.lastSpokenFullText then
                Log.Debug("DEDUP SKIP: " .. tostring(elemId))
                return
            end
        end
    end

    -- ----- Item extraction -----
    local itemName = nil
    local itemValue = nil
    local itemDesc = nil

    -- Path 1: section label found -> ccItemName is the auto-focused item.
    if ccItemName then
        itemName = ccItemName
        -- Try god-object description (InfoRaceDescription etc.)
        if focusedElement.dcProps and tabName then
            local godTitle, godBody = ExtractContextualGodObjectText(
                focusedElement.dcProps, tabName)
            if godBody and godBody ~= "" then
                itemDesc = godBody
            end
        end
        -- Fall back to selectedElement VM description.
        if not itemDesc and snapshot.selectedElement
            and snapshot.selectedElement.dcProps then
            local vmDesc = snapshot.selectedElement.dcProps.Description
            if type(vmDesc) == "string" and vmDesc ~= "" then
                itemDesc = vmDesc
            end
        end
    end

    -- Path 2: CC-specific DC extraction (Skill, Ability, Spell).
    if not itemName then
        local splitName, splitValue, splitDesc = FormatCCDCTextSplit(focusedElement.dcProps)
        -- Path 3: origin context (body type label, identity, origin desc).
        if not splitName or splitName == "" then
            splitName, splitValue, splitDesc = ExtractOriginContext(focusedElement)
        end
        -- Path 4: generic fallback.
        if not splitName or splitName == "" then
            splitName = H.FormatDCText(focusedElement.dcProps)
        end
        if not splitName or splitName == "" then
            splitName = H.ExtractTextFromData(focusedElement, state.lastSpokenTab, isScreenEntry)
        end
        if splitName and splitName ~= "" then
            local normalTab = tabName and H.NormalizeForCompare(tabName) or ""
            local normalItem = H.NormalizeForCompare(splitName)
            if normalTab ~= "" and normalItem == normalTab then
                -- Name duplicates tab; keep desc/value but suppress name.
            else
                itemName = splitName
            end
            itemValue = splitValue
            itemDesc = splitDesc
        end
    end

    -- Inline carousel value.
    if hasCarousel then
        itemValue = snapshot.inlineCarouselValue
    end

    -- Cross-element dedup.
    if isItemNav and itemName and not itemDesc and not itemValue
        and state.lastSpokenFullText then
        local normalItem = H.NormalizeForCompare(itemName)
        local normalLast = H.NormalizeForCompare(state.lastSpokenFullText)
        if normalItem == normalLast
            or (normalLast:sub(-#normalItem) == normalItem) then
            Log.Debug("DEDUP SKIP (cross-element): " .. tostring(itemName))
            return
        end
    end

    if itemName then
        slots["itemName"] = itemName
        state.lastSpokenName = elemId
        state.lastSpokenFullText = itemName
        Log.Info("ITEM: " .. tostring(focusedElement.elemType)
            .. "  name=" .. itemName
            .. (itemValue and ("  val=" .. itemValue) or "")
            .. (itemDesc and ("  desc=" .. tostring(itemDesc):sub(1, 40)) or ""))
    end
    if itemValue then slots["itemValue"] = itemValue end
    if itemDesc then slots["itemDesc"] = itemDesc end

    SpeakSlots(slots, state, isScreenEntry)
end

-- ============================================================================
-- Exports
-- ============================================================================

BG3Access.Client.CC = {
    IsCCSnapshot        = IsCCSnapshot,
    HandleCCSnapshot    = HandleCCSnapshot,
    GetSectionLabel     = GetSectionLabel,
    GetBodyTypeName     = GetBodyTypeName,
    CC_SECTION_LABELS   = CC_SECTION_LABELS,
}
