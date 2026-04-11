-- File: Client/CharCreation.lua
--
-- Character Creation specific snapshot handler.
--
-- CC uses a god-object DataContext (gui::DCCharacterCreation) with 100+
-- properties.  Generic FormatDCText/FormatDCTextSplit cannot extract useful
-- text from it.  This module handles all CC-specific logic in isolation
-- so it cannot affect other menus.
--
-- The Manager detects CC and delegates here via HandleCCSnapshot().
-- This module owns its own state table (ccState) with no shared state coupling.

local Log = BG3Access.Client.Log
local Helpers = BG3Access.Client.Helpers


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

-- DC types that are CC-specific but only when inCharacterCreation is true.
-- These types may also appear in non-CC contexts (e.g. Options sliders,
-- character sheet ability/skill views).  VMAbility and VMSkill moved here
-- from CC_SECTION_LABELS to prevent false CC detection in the character sheet.
local CC_CONTEXT_TYPES = {
    ["gui::VMSliderSetting"]          = "Appearance",
    ["ls.VMSkill"]                    = "Skills",
    ["ls.VMAbility"]                  = "Abilities",
}

-- Body type display names.  Keys are lowercase versions of the
-- BodyTypeAndShape DC property values (Female, Male, FemaleStrong, MaleStrong).
local BODY_TYPE_NAMES = {
    ["female"]       = "Slim feminine",
    ["male"]         = "Slim masculine",
    ["femalestrong"] = "Muscular feminine",
    ["malestrong"]   = "Muscular masculine",
}

-- Section headers that appear as focused elements during rapid page
-- transitions.  These are labels, not actionable items.  Suppress them
-- as item names on screen entry so the user hears just the tab name.
-- Keys must be in NormalizeForCompare format (lowercase, no spaces/hyphens/dots).
local CC_SECTION_HEADERS = {
    ["skillproficiency"]  = true,
    ["cantrip"]           = true,
    ["spell"]             = true,
}

-- Detect if a string is a meaningless placeholder like "(x2)" or "(x3)".
-- These appear briefly before the real data loads in carousel recycling.
local function IsPlaceholder(text)
    if type(text) ~= "string" then return false end
    -- ASCII: "(x2)", "(X3)", etc.
    if text:find("^%([xX]%d+%)$") then return true end
    -- Unicode multiplication sign: the × character is multi-byte.
    -- Check for short strings starting with ( ending with ) containing a digit.
    if #text <= 8 and text:sub(1, 1) == "(" and text:sub(-1) == ")"
        and text:find("%d") then
        return true
    end
    return false
end

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

-- Maps tab key fragments to the correct casing used by god-object property
-- names.  The VM types use "SubRace" (capital R) but the tab label is
-- "Subrace" (lowercase r), causing property lookups like
-- "InfoSubraceDescription" to miss "InfoSubRaceDescription".
local GOD_OBJECT_KEY_OVERRIDES = {
    ["Subrace"]  = "SubRace",
    ["Subclass"] = "SubClass",
}

-- Element name overrides: maps elemName to a friendlier display name.
-- Used for buttons whose raw text is too terse (e.g. "Randomise" ->
-- "Randomize your appearance").
local CC_ELEM_NAME_OVERRIDES = {
    ["newRandomAppearance"] = "Randomize your appearance",
}

-- Instructional speech for special interactive elements (text boxes,
-- custom inputs) keyed by elemName.  When a focused element matches,
-- the instruction is spoken and no further CC processing occurs.
local CC_INTERACTIVE_INSTRUCTIONS = {
    ["characterName"] = "Using your keyboard, type your character name"
        .. " and press B to return to character creation.",
}

-- Toggle items on the Appearance page whose values come from
-- god-object properties (not from the element's own DC).
local CC_TOGGLE_PROPERTIES = {
    ["Heterochromia"]  = "HeterochromiaEnabled",
    ["Hide Clothes"]   = "CoverNudity",
}

-- Appearance page items whose label is the elemText and whose value
-- comes from a god-object property.  Maps label -> property + optional
-- value transformer.  Unlike CC_ORIGIN_PROPERTY_LABELS (which matches
-- elemText against property VALUES), this maps elemText AS the label
-- and reads the god-object property for the display value.
local CC_APPEARANCE_LABEL_PROPERTIES = {
    ["Body Type"] = {
        property = "BodyTypeAndShape",
        transform = function(rawValue)
            return BODY_TYPE_NAMES[rawValue:lower()] or rawValue
        end,
    },
}

-- Maps tab/section name to its StaticData type for API-based description
-- lookups.  Primary source for all descriptions -- avoids Noesis pointer
-- drama.  Falls back to god-object properties only if the API misses.
local CC_TAB_STATIC_DATA_TYPE = {
    ["Race"]       = "Race",
    ["Subrace"]    = "Race",        -- subraces are Race entries too
    ["Class"]      = "ClassDescription",
    ["Subclass"]   = "ClassDescription",
    ["Background"] = "Background",
    ["Deity"]      = "God",
    ["Origin"]     = "Origin",
    ["Feat"]       = "FeatDescription",
}

-- Fallback: god-object sub-table whose .Description field holds the
-- currently-selected item's description.  Used only when the API cache
-- misses (e.g. modded content not in StaticData).
local CC_SELECTED_DESCRIPTION_KEYS = {
    ["Race"]       = "SelectedRace",
    ["Subrace"]    = "SelectedSubRace",
    ["Class"]      = "SelectedClass",
    ["Subclass"]   = "SelectedSubClass",
    ["Background"] = "SelectedBackground",
    ["Deity"]      = "SelectedDeity",
    ["Origin"]     = "SelectedOrigin",
    ["Feat"]       = "SelectedFeatDetails",
}

-- Tab hints: spoken once on first visit to each tab.  Combines what the
-- page is for with navigation guidance where non-obvious.
local CC_TAB_HINTS = {
    ["Origin"] = "You can choose to create a custom character and build from scratch, or you can choose a character with a preset backstory. D-pad left and right to cycle between custom and preset characters, and down to navigate content. Press right trigger to see a summary of your character.",
    ["Race"] = "Choose your race. Each has unique traits and proficiencies. D-pad left and right to browse races. D-pad down to see racial features and skills. D-pad left or right from within the features list returns to the race selection.",
    ["Subrace"] = "Choose your subrace. D-pad left and right to browse subraces. D-pad down to see subrace features. D-pad left or right from within the features list returns to the subrace selection.",
    ["Class"] = "Choose your class. This determines your abilities, spells, and proficiencies. D-pad left and right to browse classes. D-pad down to see class features. D-pad left or right from within the features list returns to the class selection.",
    ["Background"] = "Choose your background. This affects your skill proficiencies and how characters react to you. D-pad left and right to browse backgrounds.",
    ["Abilities"] = nil,  -- handled separately with points remaining
    ["Skills"] = nil,  -- handled separately with instruction text
    ["Spell"] = "Change your cantrip selection by choosing from the spell list below. D-pad in all directions to navigate the spell grid. Cantrips don't use spell slots and can be cast at will.",
    ["High Elf Cantrip"] = "This is the cantrip linked to your selected race. Cantrips don't use spell slots and can be cast at will.",
    ["Appearance"] = "Customize your character's appearance. D-pad up and down to navigate options. D-pad left and right to change values.",
    ["Deity"] = "Choose your deity. Use standard D-pad navigation to browse deities.",
    ["Subclass"] = "Choose your subclass. D-pad left and right to browse options.",
    ["Feat"] = "Choose a feat. Feats grant powerful new abilities and bonuses. D-pad left and right to browse feats.",
}

-- Instructional LocaString handles for CC page entry.
-- Resolved once and cached.  Maps tab name to list of handles to try.
-- These are the XAML TextBlock labels like "Selected", "Available", etc.
local CC_PAGE_INSTRUCTION_HANDLES = {
    ["Skills"] = {
        "h0bddbaf0g8c93g4ddfgbb52ge3c54b72c3c6",  -- SkillSelectionTitle
    },
    ["Cantrip"] = {
        "h46206b54gae33g4546ga5dfg13de4a4c66aa",   -- SelectedTitle (cantrips)
        "h76bfc212gcdd9g4c2ag899eg6bbeaf84f1e5",   -- Available cantrips header
    },
    ["Spell"] = {
        "h46206b54gae33g4546ga5dfg13de4a4c66aa",   -- SelectedTitle (spells)
        "h76bfc212gcdd9g4c2ag899eg6bbeaf84f1e5",   -- Available spells header
    },
}
local instructionTextCache = {}

-- Common spell stat ID prefixes in BG3.

-- Resolve instructional text for a CC page.  Cached per tab name.
-- Returns a string like "Choose 2 Skills" or nil.
local function GetPageInstructionText(tabName)
    if not tabName then return nil end
    if instructionTextCache[tabName] ~= nil then
        -- false sentinel means we tried and got nothing.
        return instructionTextCache[tabName] or nil
    end
    local handles = CC_PAGE_INSTRUCTION_HANDLES[tabName]
    if not handles then
        instructionTextCache[tabName] = false
        return nil
    end
    local parts = {}
    for _, handle in ipairs(handles) do
        local resolved = Helpers.GetTranslatedStringIfHandle(handle)
        if resolved and resolved ~= "" then
            table.insert(parts, resolved)
        end
    end
    if #parts > 0 then
        local text = table.concat(parts, ". ")
        instructionTextCache[tabName] = text
        Log.Info("PAGE INSTRUCTION: " .. tabName .. " -> " .. text)
        return text
    end
    instructionTextCache[tabName] = false
    return nil
end

-- DC types that represent race/class features and passives.
-- These need stat-based description lookup.
local CC_FEATURE_DC_TYPES = {
    ["ls.VMFeatureBoost"]        = true,  -- Base Racial Speed, proficiencies
    ["ls.VMPassiveFeatureBoost"] = true,  -- Darkvision, Fey Ancestry, etc.
    ["ls.VMFeatureSpell"]        = true,  -- Rage, class action features
    ["ls.VMSpellReference"]      = true,  -- Fire Bolt, cantrips as ContentControl
}

-- Static labels for summary panel items whose DC has a value but no name.
local CC_SUMMARY_STAT_LABELS = {
    ["ls.VMStat"]      = "Initiative",
    ["ls.VMRangeStat"] = "Hit Points",
    ["ls.VMClass"]     = "",  -- already has name ("Level 1 Barbarian")
}

-- ============================================================================
-- CC-internal state (isolated from Manager and other handlers)
-- ============================================================================
local ccState = {
    lastSpokenName           = nil,
    lastSpokenFullText       = nil,
    lastSpokenTab            = nil,
    lastSpokenTitle          = nil,
    lastSpokenItemName       = nil,
    lastMainTab              = nil,
    lastCarouselTick         = nil,
    tabHintSpoken            = false,
    tabHintsSpoken           = nil,
    abilityHintSpoken        = false,
    screenEntryJustSpoke     = false,
    inCharacterCreation      = false,
    inPostNamingCC           = false,
    pendingTransition        = nil,
    suppressGuardianTeardown = false,
    activeInstruction        = nil,
    selectedOriginName       = nil,
    isCustomOrigin           = nil,
    currentWidgetDCType      = nil,
}

-- ============================================================================
-- CC Helper Functions
-- ============================================================================

-- Get the CC section label from a data table's dcType.
-- Returns section name string or nil.
-- Stat description helpers: use shared versions from Helpers.lua.
-- ParseDescriptionParam, ResolveDescriptionParams, ReadStatDescription
-- are all defined in Helpers and exported as Helpers.* functions.
local ParseDescriptionParam = Helpers.ParseDescriptionParam
local ResolveDescriptionParams = Helpers.ResolveDescriptionParams
local ReadStatDescription = Helpers.ReadStatDescription

local ResolveTranslatedString = Helpers.ResolveTranslatedString

local function GetSectionLabel(data)
    if not data or not data.dcType then return nil end
    local label = CC_SECTION_LABELS[data.dcType]
        or CC_CONTEXT_TYPES[data.dcType]
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
    -- Resolve casing: "Subrace" -> "SubRace" to match god-object property names.
    local resolvedKey = GOD_OBJECT_KEY_OVERRIDES[tabKey] or tabKey
    local titleText = nil
    local bodyText = nil

    -- Look for the active Selected[Tab] sub-object.
    local selectedKey = "Selected" .. resolvedKey
    local activeObject = dcProps[selectedKey]

    if type(activeObject) == "table" then
        titleText = activeObject.Name or activeObject.DisplayName
                 or activeObject.Title or activeObject.Text
        if not titleText or titleText == "" then
            titleText = nil
        end
    end

    -- Look for contextual description string.
    -- Priority: Info[Tab]Description > [Tab]Description > Selected[Tab].Description
    -- Uses resolvedKey so "Subrace" -> "InfoSubRaceDescription" (correct casing).
    local descKey = "Info" .. resolvedKey .. "Description"
    local descProp = dcProps[descKey]
    if type(descProp) == "string" and descProp ~= "" then
        bodyText = descProp
    else
        local fallbackDescKey = resolvedKey .. "Description"
        local fallbackDesc = dcProps[fallbackDescKey]
        if type(fallbackDesc) == "string" and fallbackDesc ~= "" then
            bodyText = fallbackDesc
        elseif type(activeObject) == "table" and activeObject.Description then
            local subObjectDesc = activeObject.Description
            if type(subObjectDesc) == "string" and subObjectDesc ~= "" then
                bodyText = subObjectDesc
            end
        end
    end

    return titleText, bodyText
end

-- Read description from the best available source for a tab.
-- Priority:
-- 1. StaticData API by display name (God, ClassDescription) -- reliable
-- 2. God-object sub-table (SelectedDeity.Description, etc.) -- fallback
-- 3. Scalar Info property (InfoRaceDescription, etc.)
-- APIs are preferred over Noesis sub-table pointers because they are
-- always available once the cache is built and don't depend on C++
-- extracting the right pointer type from the god-object.
-- Returns description string or nil.
-- itemName is the display name of the currently selected item
-- (race name, class name, deity name, etc.) used for API lookups.
local function GetGodObjectDescription(dcProps, tabName, itemName)
    if not dcProps or not tabName then return nil end

    local staticDataType = CC_TAB_STATIC_DATA_TYPE[tabName]

    -- 1. StaticData API by display name (primary).
    if staticDataType and itemName and itemName ~= "" then
        local apiDesc = Helpers.LookupStaticDataDescription(staticDataType, itemName)
        if apiDesc then return apiDesc end
    end

    -- 2. If no itemName was provided, try to get one from the
    --    god-object sub-table and retry the API lookup.
    if staticDataType and (not itemName or itemName == "") then
        local subTableKey = CC_SELECTED_DESCRIPTION_KEYS[tabName]
        if subTableKey then
            local subTable = dcProps[subTableKey]
            if type(subTable) == "table" then
                local subName = subTable.Name or subTable.DisplayName
                    or subTable.Title
                if subName and subName ~= "" then
                    local apiDesc = Helpers.LookupStaticDataDescription(
                        staticDataType, subName)
                    if apiDesc then return apiDesc end
                end
            end
        end
    end

    -- 3. Fallback: god-object sub-table .Description property.
    --    ONLY use this if the sub-table's name matches the item we're
    --    looking for.  The sub-table always reflects the CURRENTLY
    --    SELECTED item, not the FOCUSED item.  Without this check,
    --    every item on the page gets the selected item's description
    --    (e.g. Body Type on Origin page gets Custom's description).
    local subTableKey = CC_SELECTED_DESCRIPTION_KEYS[tabName]
    if subTableKey and itemName and itemName ~= "" then
        local subTable = dcProps[subTableKey]
        if type(subTable) == "table" then
            local subName = subTable.Name or subTable.DisplayName
                or subTable.Title
            if subName and subName ~= ""
                and subName:lower() == itemName:lower() then
                local description = subTable.Description
                if type(description) == "string"
                    and description ~= "" then
                    return Helpers.StripMarkupTags(description)
                end
            end
        end
    end

    -- 4. Last resort: scalar Info property (InfoRaceDescription, etc.)
    --    from ExtractContextualGodObjectText.  Same guard: only use
    --    if this tab has an Info property AND the item name matches
    --    what ExtractContextualGodObjectText would return as the title.
    local godTitle, godDesc = ExtractContextualGodObjectText(
        dcProps, tabName)
    if godDesc and godDesc ~= "" then
        -- Only return if the title matches or we have no item name
        -- to cross-check (screen entry with no specific item).
        if not itemName or itemName == ""
            or (godTitle and godTitle:lower() == itemName:lower()) then
            return godDesc
        end
    end

    -- 5. Fallback: search ALL StaticData caches for the item name.
    --    Handles the case where lastMainTab is wrong (e.g. stuck on
    --    "Skills" after returning to the Race carousel from the
    --    skills section).  The item name IS in a cache, just not
    --    the one tabName points to.
    if itemName and itemName ~= "" then
        for fallbackTab, fallbackType in pairs(CC_TAB_STATIC_DATA_TYPE) do
            if fallbackType ~= staticDataType then
                local fallbackDesc = Helpers.LookupStaticDataDescription(
                    fallbackType, itemName)
                if fallbackDesc then return fallbackDesc end
            end
        end
    end

    return nil
end

-- Extract text from CC-specific dcProps (Skill, Ability, Spell sub-table).
-- Returns (name, value, description) or all nils.
local function FormatCCDCTextSplit(dcProps)
    if not dcProps then return nil, nil, nil end

    local text = nil
    local value = nil
    local desc = dcProps.Description
    -- Description may be a sub-table (VMContextTransString) with a
    -- .Text field, not a plain string.  Extract the string now.
    if type(desc) == "table" then
        desc = desc.Text or desc.Str or desc.Description
    end

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

    -- Skill proficiency items (ls.VMSkill): Skill=Insight, Value=3, etc.
    if not text and dcProps.Skill then
        text = tostring(dcProps.Skill)
        if dcProps.Value then
            local numericValue = tonumber(tostring(dcProps.Value))
            if numericValue then
                value = (numericValue >= 0 and "+" or "") .. tostring(numericValue)
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

    -- VMFeatureBoost: NameCTS.Text has display name,
    -- Description.Text has the description.
    if not text and type(dcProps.NameCTS) == "table" then
        text = dcProps.NameCTS.Text
    end
    if not text and dcProps.ShortName then
        text = dcProps.ShortName
    end
    if not desc and type(dcProps.Description) == "table" then
        desc = dcProps.Description.Text
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
    -- Returns "label: value" so the user hears context on every change.
    for _, mapping in ipairs(CC_ORIGIN_PROPERTY_LABELS) do
        local propertyValue = data.dcProps[mapping.property]
        if type(propertyValue) == "string" and propertyValue ~= "" then
            if elemText == propertyValue then
                local displayValue = elemText
                if mapping.property == "BodyTypeAndShape" then
                    displayValue = BODY_TYPE_NAMES[propertyValue:lower()]
                        or propertyValue
                end
                return mapping.label, displayValue, nil
            end
        end
    end

    -- Body type numeric ID: substitute the readable BodyTypeAndShape value.
    if elemText:match("^%d+$") and data.dcProps.BodyTypeAndShape then
        local rawBodyType = data.dcProps.BodyTypeAndShape
        local displayName = BODY_TYPE_NAMES[rawBodyType:lower()] or rawBodyType
        return "Body Type", displayName, nil
    end

    -- Appearance page label-based items: elemText IS the label (e.g.,
    -- "Body Type") and the display value comes from a god-object property.
    local appearanceMapping = CC_APPEARANCE_LABEL_PROPERTIES[elemText]
    if appearanceMapping then
        local rawValue = data.dcProps[appearanceMapping.property]
        if type(rawValue) == "string" and rawValue ~= "" then
            local displayValue = rawValue
            if appearanceMapping.transform then
                displayValue = appearanceMapping.transform(rawValue)
            end
            return elemText, displayValue, nil
        end
    end

    -- "Origin" meta-option: play as a pre-made origin character.
    -- The actual description lives at DummyCharacter.Stats.OriginDescription
    -- (two levels deep, not accessible yet).
    if Helpers.NormalizeForCompare(elemText) == "origin" then
        return nil, nil,
            "Play as an existing character from Baldur's Gate 3"
    end

    -- Origin character name (Custom, Astarion, etc.): match against SelectedOrigin.
    local selectedOrigin = data.dcProps.SelectedOrigin
    if type(selectedOrigin) == "table" then
        local originName = selectedOrigin.Name or selectedOrigin.DisplayName
            or selectedOrigin.Title
        if originName and Helpers.NormalizeForCompare(elemText) == Helpers.NormalizeForCompare(originName) then
            local originDesc = selectedOrigin.Description
            if type(originDesc) == "string" and originDesc ~= "" then
                -- Custom: speak the API description, then action hint.
                if Helpers.NormalizeForCompare(originName) == "custom" then
                    local trimmedDesc = originDesc:gsub("[%.%s]+$", "")
                    return nil, nil,
                        trimmedDesc .. ". Create a custom character"
                end
                return elemText, nil, originDesc
            end
        end
    end

    return nil, nil, nil
end

-- ============================================================================
-- Unified Item Data Extraction
-- ============================================================================

-- Extract name, value, and description for the current CC focused element.
-- This is the SINGLE source of truth for item data.  All code paths
-- (dedup, isValueOnly, screen entry, item nav) use the same result.
--
-- Pipeline (stops at first name hit):
--   1. Placeholder guard
--   2. FormatCCDCTextSplit (Skill, Ability, Spell dcProps)
--   3. ExtractOriginContext (Body Type, Identity, Origin)
--   4. Helpers.FormatDCText (generic dcProps)
--   5. Helpers.ExtractTextFromData (visual text / elemText fallback)
-- Then applies overrides (carousel, toggles, bonus ability, stat labels)
-- and enriches with API-first descriptions.
--
-- Parameters:
--   focusedElement  - the focused element data table
--   snapshot        - full snapshot from C++
--   tabName         - current tab name (may be nil for item nav)
--   isScreenEntry   - boolean, passed to Helpers.ExtractTextFromData
--
-- Returns: name, value, description (all strings or nil)
local function GetCCItemData(focusedElement, snapshot, tabName,
                             isScreenEntry)
    if not focusedElement then return nil, nil, nil end

    local dcProps = focusedElement.dcProps
    local itemName = nil
    local itemValue = nil
    local itemDescription = nil

    -- 1. Placeholder guard: strip placeholder elemText so downstream
    --    extractors (Helpers.ExtractTextFromData) don't pick it up.
    local elemText = focusedElement.elemText
    if elemText and IsPlaceholder(elemText) then
        Log.Debug("GetCCItemData: strip placeholder elemText: " .. elemText)
        elemText = nil
    end

    -- 1b. Level-up summary items (DCCharacterLevelUp): HP gains, etc.
    --      These have no useful dcProps -- read text blocks for content.
    if focusedElement.dcType == "gui::DCCharacterLevelUp" then
        local readOk, textBlocks = pcall(Ext.UI.ReadFocusedTextBlocks)
        if readOk and textBlocks and #textBlocks > 0 then
            local parts = {}
            for _, text in ipairs(textBlocks) do
                if text and text ~= "" then
                    local cleaned = Helpers.StripMarkupTags(text)
                    if cleaned and cleaned ~= "" then
                        parts[#parts + 1] = cleaned
                    end
                end
            end
            if #parts > 0 then
                return table.concat(parts, ", "), nil, nil
            end
        end
        return nil, nil, nil
    end

    -- 2. FormatCCDCTextSplit: Skill, Ability, Spell sub-table dcProps.
    itemName, itemValue, itemDescription = FormatCCDCTextSplit(dcProps)

    -- 3. ExtractOriginContext: Body Type, Identity, Origin character.
    if not itemName or itemName == "" then
        itemName, itemValue, itemDescription = ExtractOriginContext(
            focusedElement)
    end

    -- If a prior extractor returned description but no name (e.g.
    -- ExtractOriginContext for "Custom" or "Origin"), the element is
    -- claimed.  Do NOT fall through to generic extractors which would
    -- overwrite the description with unrelated text.
    local elementClaimed = (itemName and itemName ~= "")
        or (itemDescription and itemDescription ~= "")

    -- 4. Helpers.FormatDCText: generic dcProps formatting.
    if not elementClaimed then
        itemName = Helpers.FormatDCText(dcProps)
        itemValue = nil
        itemDescription = nil
        elementClaimed = itemName and itemName ~= ""
    end

    -- 5. Helpers.ExtractTextFromData: visual text / elemText fallback.
    --    Pass the effective tab name for context.
    if not elementClaimed then
        local effectiveTab = tabName or ccState.lastSpokenTab
        itemName = Helpers.ExtractTextFromData(
            focusedElement, effectiveTab, isScreenEntry)
        itemValue = nil
        itemDescription = nil
    end

    -- If all extractors produced nothing, bail early.
    -- An element with description but no name (Custom, Origin) is valid.
    if (not itemName or itemName == "")
        and (not itemDescription or itemDescription == "") then
        return nil, nil, nil
    end

    -- Final placeholder check on the extracted name.
    if itemName and IsPlaceholder(itemName) then
        Log.Info("GetCCItemData: suppress placeholder name: " .. itemName)
        return nil, nil, nil
    end

    -- Element name overrides: replace terse button text with friendlier labels.
    if itemName and focusedElement.elemName
        and CC_ELEM_NAME_OVERRIDES[focusedElement.elemName] then
        itemName = CC_ELEM_NAME_OVERRIDES[focusedElement.elemName]
    end

    -- ----------------------------------------------------------------
    -- 6. Post-extraction overrides (only when itemName is set)
    -- ----------------------------------------------------------------
    -- Elements with description-only (Custom, Origin on the origin page)
    -- skip overrides entirely — they have no name/value to transform.

    if itemName and itemName ~= "" then
        -- Carousel value: non-numeric carousel values override itemValue.
        local hasCarousel = snapshot.inlineCarouselChanged
            and snapshot.inlineCarouselValue
            and snapshot.inlineCarouselValue ~= ""
        if hasCarousel then
            local carouselValue = snapshot.inlineCarouselValue
            if carouselValue and not carouselValue:match("^%d+$") then
                itemValue = carouselValue
            else
                Log.Debug("GetCCItemData: suppress numeric carousel: "
                    .. tostring(carouselValue))
            end
        end

        -- Toggle properties: read value from god-object property by item name.
        if not itemValue and dcProps then
            local toggleProperty = CC_TOGGLE_PROPERTIES[itemName]
            if toggleProperty then
                local toggleValue = dcProps[toggleProperty]
                if type(toggleValue) == "string" and toggleValue ~= "" then
                    itemValue = toggleValue
                end
            end
        end

        -- Appearance label properties: elemText IS the label, value from god-object.
        if not itemValue and dcProps then
            local appearanceMapping = CC_APPEARANCE_LABEL_PROPERTIES[itemName]
            if appearanceMapping then
                local rawValue = dcProps[appearanceMapping.property]
                if type(rawValue) == "string" and rawValue ~= "" then
                    local displayValue = rawValue
                    if appearanceMapping.transform then
                        displayValue = appearanceMapping.transform(rawValue)
                    end
                    itemValue = displayValue
                    Log.Debug("GetCCItemData: appearance label value: "
                        .. itemName .. " -> " .. displayValue)
                end
            end
        end

        -- Slider setting value: dcProps.Value is only a concrete number
        -- during INPC (val=1) snapshots -- the binding expression makes it
        -- nil at initial focus.  Helpers.FormatDCValue reads it the same way
        -- the Menus pipeline does, restoring the value on left/right presses.
        if not itemValue and focusedElement.dcType == "gui::VMSliderSetting" then
            local sliderValue = Helpers.FormatDCValue(dcProps)
            if sliderValue and sliderValue ~= "" then
                itemValue = sliderValue
            end
        end

        -- Bonus ability: append selected ability name for "+2 Bonus" items.
        if itemName:find("Bonus", 1, true) and dcProps
            and dcProps.SelectedBonusAbility then
            itemName = itemName .. " to " .. dcProps.SelectedBonusAbility
            Log.Debug("GetCCItemData: bonus ability: " .. itemName)
        end

        -- Summary stat labels: prepend static label for DC types with no name.
        if focusedElement.dcType
            and CC_SUMMARY_STAT_LABELS[focusedElement.dcType] then
            local staticLabel = CC_SUMMARY_STAT_LABELS[focusedElement.dcType]
            if staticLabel and staticLabel ~= "" and not itemValue then
                -- The "name" is actually the value; rewrite as label + value.
                itemValue = itemName
                itemName = staticLabel
            end
        end

        -- Suppress bare "0" values (selection indices, not game values).
        if itemValue and itemValue == "0" then
            Log.Debug("GetCCItemData: suppress bare zero value")
            itemValue = nil
        end
    end

    -- ----------------------------------------------------------------
    -- 7. Description enrichment (API-first)
    -- ----------------------------------------------------------------
    if not itemDescription or itemDescription == "" then
        itemDescription = nil  -- normalize empty string to nil

        -- Deity detection: if lastMainTab isn't a known StaticData type
        -- but the tab name IS a deity display name, fix it.
        local effectiveMainTab = ccState.lastMainTab
        if effectiveMainTab
            and not CC_TAB_STATIC_DATA_TYPE[effectiveMainTab]
            and Helpers.LookupStaticDataDescription("God", effectiveMainTab) then
            effectiveMainTab = "Deity"
        end

        -- A. StaticData API via GetGodObjectDescription (primary).
        --    Covers Race, Class, Subclass, Background, Deity, Origin, Feat.
        if not itemDescription
            and focusedElement.dcType == "gui::DCCharacterCreation"
            and dcProps and effectiveMainTab then
            itemDescription = GetGodObjectDescription(
                dcProps, effectiveMainTab, itemName)
            -- Inline carousel items (Race, Subrace on appearance page):
            -- itemName is the label ("Race"), but the actual value to look
            -- up is in the carousel value ("Drow").  Try that too.
            if not itemDescription
                and snapshot.inlineCarouselValue
                and snapshot.inlineCarouselValue ~= "" then
                itemDescription = GetGodObjectDescription(
                    dcProps, effectiveMainTab,
                    snapshot.inlineCarouselValue)
            end
        end

        -- B. Feature/passive API via Helpers.LookupFeatureDescription.
        --    Covers race/class features, proficiencies, Darkvision, etc.
        if not itemDescription and focusedElement.dcType
            and CC_FEATURE_DC_TYPES[focusedElement.dcType] then
            local featureSuccess, featureDescription = pcall(
                Helpers.LookupFeatureDescription, itemName)
            if featureSuccess and featureDescription then
                itemDescription = featureDescription
                Log.Debug("GetCCItemData: feature desc: " .. itemName
                    .. " -> " .. tostring(featureDescription):sub(1, 60))
            end
        end

        -- C. Spell API via Helpers.LookupSpellDescription.
        --    Covers spell buttons (Fire Bolt, etc.).
        if not itemDescription and itemName
            and focusedElement.elemType
            and (focusedElement.elemType:find("LSButton", 1, true)
                or focusedElement.elemType:find("spellButton", 1, true))
            and itemName ~= "spell" then
            local spellSuccess, spellDescription = pcall(
                Helpers.LookupSpellDescription, itemName)
            if spellSuccess and spellDescription then
                itemDescription = spellDescription
                Log.Debug("GetCCItemData: spell desc: " .. itemName
                    .. " -> " .. tostring(spellDescription):sub(1, 60))
            end
        end

        -- D. Last resort: selected element VM .Description property.
        --    Only if all API lookups missed (Noesis pointer, least reliable).
        if not itemDescription and snapshot.selectedElement
            and snapshot.selectedElement.dcProps then
            local vmDescription = snapshot.selectedElement.dcProps.Description
            if type(vmDescription) == "string" and vmDescription ~= "" then
                itemDescription = vmDescription
            end
        end
    end

    return itemName, itemValue, itemDescription
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

    -- God-object DC (character creation or level up).
    if focusedElement.dcType == "gui::DCCharacterCreation"
        or focusedElement.dcType == "gui::DCCharacterLevelUp" then
        return true
    end

    -- CC VM type on focused element.
    if focusedElement.dcType and CC_SECTION_LABELS[focusedElement.dcType] then
        return true
    end

    -- CC feature/passive type on focused element.
    if focusedElement.dcType and CC_FEATURE_DC_TYPES[focusedElement.dcType] then
        return true
    end

    -- Summary panel stat types (Initiative, Hit Points, Class).
    -- Guard with inCharacterCreation: VMRangeStat also appears in the
    -- Examine panel (Hit Points row) and must not be claimed there.
    if ccState.inCharacterCreation and focusedElement.dcType
        and CC_SUMMARY_STAT_LABELS[focusedElement.dcType] then
        return true
    end

    -- CC VM type on selected element.
    if snapshot.selectedElement and snapshot.selectedElement.dcType
        and CC_SECTION_LABELS[snapshot.selectedElement.dcType] then
        return true
    end

    -- Types that appear in CC but also in other contexts (e.g. sliders).
    -- Only claim when already in character creation.
    if ccState.inCharacterCreation and focusedElement.dcType
        and CC_CONTEXT_TYPES[focusedElement.dcType] then
        return true
    end

    return false
end

-- ============================================================================
-- CC Snapshot Handler
-- ============================================================================


-- One-shot diagnostic: dump CC entity components on first CC entry.
-- Recurses into userdata/table fields up to maxDepth levels.
local ccEntityDiagDone = false

local function DumpValue(value, indent, maxDepth, visited)
    if maxDepth <= 0 then return end
    indent = indent or "  "
    visited = visited or {}

    local valueType = type(value)
    if valueType == "userdata" then
        -- Avoid infinite loops on circular references.
        local address = tostring(value)
        if visited[address] then
            Log.Info(indent .. "(circular ref: " .. address .. ")")
            return
        end
        visited[address] = true

        -- Try pairs() to enumerate fields.
        local fieldsSuccess, fieldsError = pcall(function()
            local fieldCount = 0
            for key, subValue in pairs(value) do
                fieldCount = fieldCount + 1
                if fieldCount > 30 then
                    Log.Info(indent .. "... (truncated at 30 fields)")
                    break
                end
                local subType = type(subValue)
                if subType == "userdata" or subType == "table" then
                    Log.Info(indent .. tostring(key) .. " = "
                        .. subType .. ": " .. tostring(subValue))
                    DumpValue(subValue, indent .. "  ",
                        maxDepth - 1, visited)
                else
                    Log.Info(indent .. tostring(key) .. " = "
                        .. tostring(subValue))
                end
            end
            if fieldCount == 0 then
                -- Try array-style access.
                local lenSuccess, length = pcall(function()
                    return #value
                end)
                if lenSuccess and length and length > 0 then
                    Log.Info(indent .. "(array, length=" .. length .. ")")
                    local showCount = math.min(length, 6)
                    for arrayIndex = 1, showCount do
                        local itemSuccess, item = pcall(function()
                            return value[arrayIndex]
                        end)
                        if itemSuccess then
                            Log.Info(indent .. "  [" .. arrayIndex
                                .. "] = " .. tostring(item))
                            if type(item) == "userdata" then
                                DumpValue(item, indent .. "    ",
                                    maxDepth - 1, visited)
                            end
                        end
                    end
                    if length > showCount then
                        Log.Info(indent .. "  ... ("
                            .. length .. " total)")
                    end
                else
                    Log.Info(indent .. "(no enumerable fields)")
                end
            end
        end)
        if not fieldsSuccess then
            Log.Info(indent .. "(pairs failed: "
                .. tostring(fieldsError) .. ")")
        end
    elseif valueType == "table" then
        local count = 0
        for key, subValue in pairs(value) do
            count = count + 1
            if count > 20 then
                Log.Info(indent .. "... (truncated)")
                break
            end
            local subType = type(subValue)
            if subType == "userdata" or subType == "table" then
                Log.Info(indent .. tostring(key) .. " = "
                    .. subType .. ": " .. tostring(subValue))
                DumpValue(subValue, indent .. "  ",
                    maxDepth - 1, visited)
            else
                Log.Info(indent .. tostring(key) .. " = "
                    .. tostring(subValue))
            end
        end
    end
end

local function DumpCCEntityComponents()
    if ccEntityDiagDone then return end
    ccEntityDiagDone = true

    Log.Info("=== CC ENTITY DIAGNOSTIC ===")

    local componentTypes = {
        "CCCharacterDefinition",
        "CCCreation",
        "CCState",
        "CCSessionCommon",
        "CCDefinitionCommon",
        "CCLevelUp",
        "CCLevelUpDefinition",
        "CharacterCreationStats",
        "ClientCCBaseDefinitionState",
    }
    for _, componentName in ipairs(componentTypes) do
        local success, entities = pcall(
            Ext.Entity.GetAllEntitiesWithComponent, componentName)
        if success and entities and #entities > 0 then
            Log.Info("CC ENTITY [" .. componentName .. "]: "
                .. #entities .. " entities")
            for entityIndex, entity in ipairs(entities) do
                if entityIndex > 2 then
                    Log.Info("  ... (" .. #entities .. " total)")
                    break
                end
                local componentSuccess, component = pcall(function()
                    return entity[componentName]
                end)
                if componentSuccess and component then
                    Log.Info("  --- Entity " .. entityIndex .. " ---")
                    DumpValue(component, "    ", 3)
                end
            end
        elseif success then
            Log.Info("CC ENTITY [" .. componentName .. "]: 0 entities")
        else
            Log.Info("CC ENTITY [" .. componentName .. "]: error - "
                .. tostring(entities))
        end
    end
    Log.Info("=== END CC ENTITY DIAGNOSTIC ===")
end

-- ============================================================================
-- CC Y-button subscription for naming screen detection
-- ============================================================================
-- The naming screen has no d-pad focusable elements (buttons map to
-- controller inputs directly).  Instead of trying to detect it from
-- snapshots (which look identical to transient empty-focus bounces),
-- we detect the Y-button press directly and speak the naming screen
-- from the controller input callback.  Deterministic, no timing.

local ccYButtonSubscription = nil
local namingScreenWasSpoken = false

local function SpeakNamingScreen()
    -- Get character name from the correct source.
    -- For origin characters: use SelectedOrigin.Name from the god-object
    -- DC (tracked in ccState by HandleCCSnapshot).  The entity API's
    -- CharacterName lags behind the UI carousel selection.
    -- For custom characters: use the entity API (reflects renames).
    local characterName = nil
    if ccState.isCustomOrigin then
        -- Custom: entity API has the renamed name (Big Pillow, etc.)
        local namingSuccess, namingEntities = pcall(
            Ext.Entity.GetAllEntitiesWithComponent,
            "CCCharacterDefinition")
        if namingSuccess and namingEntities and #namingEntities > 0 then
            pcall(function()
                characterName = namingEntities[1].CCCharacterDefinition
                    .Definition.Name
            end)
        end
    else
        -- Origin character: use tracked SelectedOrigin.Name
        characterName = ccState.selectedOriginName
    end
    if not characterName or characterName == ""
        or characterName:find("^%[%d+%]$") then
        characterName = "Tav"
    end

    ccState.lastSpokenTab = "Naming"
    ccState.lastMainTab = "Naming"
    namingScreenWasSpoken = true

    local speech = "Enter Character Name. " .. characterName
        .. ". Press A to rename. Press Y to choose guardian"
    Log.Info("NAMING SCREEN: " .. speech)
    Ext.Tolk.Speak(speech, true)
    ccState.lastSpokenFullText = speech
    ccState.lastSpokenName = ""
    ccState.lastSpokenItemName = "Naming"
end

local function SubscribeCCYButton()
    if ccYButtonSubscription then return end
    ccYButtonSubscription = Ext.Events.ControllerButtonInput:Subscribe(function(event)
        if not event.Pressed then return end
        if not ccState.inCharacterCreation then return end
        local buttonName = tostring(event.Button)
        if buttonName == "Y" and ccState.lastMainTab ~= "Naming"
            and not ccState.inPostNamingCC then
            -- Y from any CC tab → forward to naming screen.
            -- Use lastMainTab (survives widget root resets) instead of
            -- lastSpokenTab (gets cleared on widget root change).
            -- Set lockout so snapshot handler drops lingering CC snapshots.
            ccState.suppressGuardianTeardown = false
            ccState.pendingTransition = "Naming"
            Log.Debug("CC Y-button: transition to Naming")
            SpeakNamingScreen()
        elseif buttonName == "B" and ccState.lastMainTab == "Naming" then
            -- B from naming screen or text input → back to main CC.
            -- Set lockout so snapshot handler drops stale snapshots
            -- until a real CC element arrives.
            ccState.suppressGuardianTeardown = false
            ccState.pendingTransition = "MainCC"
            namingScreenWasSpoken = false
            Log.Debug("CC B-button: transition from Naming to MainCC")
        elseif buttonName == "B" and ccState.inPostNamingCC then
            -- B from guardian CC → back to naming screen.
            -- Suppress all CC snapshots until the next button press.
            -- The naming screen has no detectable elements; stale guardian
            -- snapshots keep firing during teardown.
            ccState.suppressGuardianTeardown = true
            ccState.inPostNamingCC = false
            Log.Debug("CC B-button: transition from Guardian to Naming")
            SpeakNamingScreen()
        end
    end)
    Log.Debug("Subscribed CC Y-button listener")
end

local function UnsubscribeCCYButton()
    if ccYButtonSubscription then
        Ext.Events.ControllerButtonInput:Unsubscribe(ccYButtonSubscription)
        ccYButtonSubscription = nil
        Log.Debug("Unsubscribed CC Y-button listener")
    end
end

--- ResetCCNavigation: clear CC navigation dedup state only.
--- Defined before HandleCCSnapshot so it can be called on cutscene return.
local function ResetCCNavigation()
    ccState.lastSpokenTab = nil
    ccState.lastSpokenTitle = nil
    ccState.lastSpokenName = nil
    ccState.lastSpokenItemName = nil
end

--- ResetCCState: clear all CC state.
--- Defined before HandleCCSnapshot so it can be called on cutscene return.
--- Also exported for Manager to call on GameStateChanged.
local function ResetCCState()
    ccState.lastSpokenName = nil
    ccState.lastSpokenFullText = nil
    ccState.lastSpokenTab = nil
    ccState.lastSpokenTitle = nil
    ccState.lastSpokenItemName = nil
    ccState.lastMainTab = nil
    ccState.lastCarouselTick = nil
    ccState.tabHintSpoken = false
    ccState.tabHintsSpoken = nil
    ccState.abilityHintSpoken = false
    ccState.screenEntryJustSpoke = false
    ccState.inCharacterCreation = false
    ccState.inPostNamingCC = false
    ccState.pendingTransition = nil
    ccState.suppressGuardianTeardown = false
    ccState.activeInstruction = nil
    ccState.selectedOriginName = nil
    ccState.isCustomOrigin = nil
    ccState.currentWidgetDCType = nil
end

-- Main CC handler.  Called by Manager when IsCCSnapshot returns true.
-- Uses module-level ccState for all CC-specific state.
local function HandleCCSnapshot(snapshot)
    local focusedElement = snapshot.focusedElement

    -- =================================================================
    -- Guardian teardown suppression: after B from guardian, suppress ALL
    -- CC snapshots until the next button press (Y or B).  The naming
    -- screen was already spoken by the B callback; these are stale
    -- guardian elements being torn down by Noesis.
    -- =================================================================
    if ccState.suppressGuardianTeardown then
        Log.Debug("SUPPRESS: dropping guardian teardown snapshot")
        return
    end


    -- =================================================================
    -- Transition lockout: when Y or B triggers a known screen change,
    -- pendingTransition is set to the destination.  Drop all snapshots
    -- until the UI catches up to that destination.  This prevents
    -- lingering stale snapshots from interrupting the correct speech.
    -- =================================================================
    if ccState.pendingTransition then
        local hasRealDCType = focusedElement.dcType
            and focusedElement.dcType ~= "(none)"
            and focusedElement.dcType ~= ""
        if ccState.pendingTransition == "Naming" then
            -- The naming screen was already spoken by the Y-button callback.
            -- Drop empty snapshots (naming screen has no focusable elements).
            -- Clear the lockout when a real element arrives (guardian page
            -- or returning CC page) and fall through to process it.
            if hasRealDCType then
                ccState.pendingTransition = nil
                ccState.lastSpokenTab = nil
                -- Keep lastMainTab = "Naming" so guardian detection
                -- (inPostNamingCC) can fire and B-handler works.
                Log.Debug("LOCKOUT: cleared (real element arrived)")
                -- Fall through to process this snapshot normally.
            else
                -- Empty snapshot during naming screen — nothing to process.
                return
            end
        elseif ccState.pendingTransition == "MainCC" then
            -- Waiting for main CC (real focused element).  Drop stale
            -- naming/transition snapshots until a real CC element arrives.
            if hasRealDCType then
                ccState.pendingTransition = nil
                ccState.lastMainTab = nil
                ccState.lastSpokenTab = nil
                ccState.inPostNamingCC = false
                Log.Debug("LOCKOUT: arrived at MainCC (state reset)")
                -- Fall through to process this snapshot normally.
            else
                Log.Debug("LOCKOUT: dropping snapshot (waiting for MainCC)")
                return
            end
        end
    end

    -- Interactive element instructions: text boxes, custom inputs, etc.
    -- Speak the instruction once and suppress all subsequent snapshots
    -- for the same element (e.g. each keystroke fires a value change).
    if focusedElement.elemName then
        local instruction = CC_INTERACTIVE_INSTRUCTIONS[focusedElement.elemName]
        if instruction then
            if ccState.activeInstruction ~= focusedElement.elemName then
                ccState.activeInstruction = focusedElement.elemName
                Log.Info("CC INSTRUCTION: " .. focusedElement.elemName)
                Ext.Tolk.Speak(instruction, true)
            end
            return
        else
            ccState.activeInstruction = nil
        end
    end

    -- Mark that we're in CC and subscribe the Y/B button listener.
    if not ccState.inCharacterCreation then
        ccState.inCharacterCreation = true
        SubscribeCCYButton()
    end

    -- Track the selected origin from the god-object DC.  The entity
    -- API's CharacterName lags behind the UI carousel — SelectedOrigin
    -- reflects what the game actually displays on the naming screen.
    if focusedElement.dcProps
        and focusedElement.dcType == "gui::DCCharacterCreation" then
        local trackedOrigin = focusedElement.dcProps.SelectedOrigin
        if type(trackedOrigin) == "table" then
            ccState.selectedOriginName = trackedOrigin.Name
                or trackedOrigin.DisplayName or trackedOrigin.Title
            ccState.isCustomOrigin =
                trackedOrigin.IsCustom == "On"
                or trackedOrigin.IsCustom == true
        end
    end

    -- Detect guardian CC: first real CC element after naming screen.
    if not ccState.inPostNamingCC
        and ccState.lastMainTab == "Naming"
        and focusedElement.dcType
        and focusedElement.dcType ~= "(none)"
        and focusedElement.dcType ~= "" then
        ccState.inPostNamingCC = true
        Log.Debug("Guardian CC detected (post-naming)")
    end

    -- Entity diagnostic disabled -- data collected 2026-03-27.
    -- See memory/project_cc_entity_components.md for results.
    -- DumpCCEntityComponents()

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

    Log.Info("CC CLASSIFY: selSec=" .. tostring(selectedSectionLabel)
        .. " selTab=" .. tostring(selectedTabName)
        .. " lastTab=" .. tostring(ccState.lastSpokenTab)
        .. " mainTab=" .. tostring(ccState.lastMainTab)
        .. " sel=" .. tostring(snapshot.selectionChanged)
        .. " foc=" .. tostring(snapshot.focusChanged))
    -- Diagnostic: log selectedElement dcType to discover unknown VM types.
    if snapshot.selectedElement and snapshot.selectedElement.dcType then
        Log.Info("CC CLASSIFY selDcType=" .. snapshot.selectedElement.dcType)
    end

    local isScreenEntry = false
    if snapshot.selectionChanged then
        -- Check known signals for tab switch vs in-page cycling.
        if selectedSectionLabel then
            -- Known CC VM type: same section = in-page, different = tab switch.
            if selectedSectionLabel ~= ccState.lastSpokenTab then
                isScreenEntry = true
            end
        elseif selectedTabName
            and not selectedTabName:find("^ListBoxItem:")
            and selectedTabName ~= ccState.lastSpokenTab then
            -- Header carousel tab changed (skip raw ListBoxItem indices
            -- which are body type cycling on the Appearance page).
            isScreenEntry = true
        elseif not selectedSectionLabel and not selectedTabName then
            -- No recognized signals at all.  Catches pages like Appearance.
            -- Body type/identity cycling has selectedSectionLabel="Origin"
            -- (non-nil) so it never reaches this branch.
            isScreenEntry = true
        end
    elseif snapshot.focusChanged and focusedElement.isTab then
        isScreenEntry = true
    end

    -- Section-change detection: focus moves to an element whose section
    -- label differs from lastSpokenTab (e.g. Spell page buttons).
    if not isScreenEntry and snapshot.focusChanged
        and focusedSectionLabel and focusedSectionLabel ~= ccState.lastSpokenTab then
        isScreenEntry = true
        Log.Info("CC section change detected: " .. tostring(focusedSectionLabel))
    end

    -- Appearance page detection: selectedTabName is "ListBoxItem: N"
    -- which gets filtered above, so isScreenEntry is never set.  Detect
    -- via the focused element's elemName containing "Appearance" or
    -- "newRandom" (the Randomise button unique to the Appearance page).
    if not isScreenEntry and snapshot.selectionChanged
        and focusedElement.elemName
        and (focusedElement.elemName:find("Appearance", 1, true)
            or focusedElement.elemName:find("newRandom", 1, true))
        and ccState.lastSpokenTab ~= "Appearance" then
        isScreenEntry = true
        Log.Info("CC Appearance page detected via elemName")
    end

    local isItemNav = snapshot.focusChanged
        and not focusedElement.isTab and not isScreenEntry
    local isCarouselOnly = hasCarousel and not snapshot.focusChanged
    local isValueOnly = not isScreenEntry and not isItemNav
        and not isCarouselOnly and snapshot.valueChanged

    -- Naming screen is handled directly by the Y-button callback
    -- (SubscribeCCYButton / SpeakNamingScreen).  No snapshot detection
    -- needed — the controller input event IS the signal.

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

        -- Append description via StaticData API for tabs that have one.
        local effectiveTab = ccState.lastMainTab or ccState.lastSpokenTab
        -- Deity detection: tab name is a deity name, not "Deity".
        if effectiveTab
            and not CC_TAB_STATIC_DATA_TYPE[effectiveTab]
            and Helpers.LookupStaticDataDescription("God", effectiveTab) then
            effectiveTab = "Deity"
            ccState.lastMainTab = "Deity"
        end
        if effectiveTab
            and CC_TAB_STATIC_DATA_TYPE[effectiveTab]
            and focusedElement.dcProps
            and focusedElement.dcType == "gui::DCCharacterCreation" then
            local carouselDesc = GetGodObjectDescription(
                focusedElement.dcProps, effectiveTab, carouselValue)
            if carouselDesc and carouselDesc ~= "" then
                carouselValue = carouselValue .. ". " .. carouselDesc
            end
        end

        if carouselValue ~= ccState.lastSpokenFullText then
            ccState.lastSpokenFullText = carouselValue
            ccState.lastSpokenName = elemId
            ccState.lastCarouselTick = Ext.Utils.MonotonicTime()
                    Log.Info("CAROUSEL: " .. carouselValue)
            Ext.Tolk.Speak(carouselValue, true)
        end
        return
    end

    -- Suppress value-only events that immediately follow a carousel event
    -- on the same element (e.g., Face carousel fires "Head 3", then a
    -- stale value event fires just "Face" and interrupts).
    if isValueOnly and ccState.lastCarouselTick then
        local elapsed = Ext.Utils.MonotonicTime() - ccState.lastCarouselTick
        if elapsed < 200 then
            Log.Debug("SUPPRESS POST-CAROUSEL VALUE: " .. tostring(focusedElement.elemText))
            return
        end
    end

    if isValueOnly then
        -- Unified extraction: GetCCItemData handles all value-only
        -- extraction (structured, toggles, appearance, bonus ability,
        -- deity detection, god-object description).
        local valueName, valueValue, valueDescription = GetCCItemData(
            focusedElement, snapshot, nil, false)

        -- Slider settings: speak only the changing number, not the name.
        -- The name was already spoken when focus arrived (isItemNav path).
        -- Repeating it on every left/right press is too verbose.
        local fullText
        if focusedElement.dcType == "gui::VMSliderSetting"
            and valueValue and valueValue ~= "" then
            fullText = valueValue
        else
            local parts = {}
            if valueName and valueName ~= "" then
                table.insert(parts, (valueName:gsub("%s+$", "")))
            end
            if valueValue and valueValue ~= "" then
                table.insert(parts, (valueValue:gsub("%s+$", "")))
            end
            if valueDescription and valueDescription ~= "" then
                table.insert(parts, (valueDescription:gsub("%s+$", "")))
            end
            fullText = table.concat(parts, ". ")
        end

        -- Strip markup for comparison and speech so raw LSTag text
        -- doesn't bypass dedup against the already-spoken stripped version.
        fullText = Helpers.StripMarkupTags(fullText)
        if fullText ~= "" and fullText ~= ccState.lastSpokenFullText then
            ccState.lastSpokenFullText = fullText
            ccState.lastSpokenName = elemId
            if valueName and valueName ~= "" then
                ccState.lastSpokenItemName = valueName
            end
            Log.Info("VALUE: " .. fullText)
            Ext.Tolk.Speak(fullText, true)
        end
        return
    end

    -- =================================================================
    -- Screen entry or item navigation.
    -- =================================================================
    local speechData = Helpers.CreateSpeechData()
    local tabName = nil

    if isScreenEntry then
        -- ----- Derive tab name -----
        if focusedElement.isTab then
            tabName = focusedElement.tabName
        end
        -- Priority: selectedSectionLabel (Race, Subrace, etc.) is most
        -- reliable.  When nil, prefer selectedTabName ("High Elf Cantrip")
        -- over focusedSectionLabel ("Spell") for better labels.
        if not tabName and selectedSectionLabel then
            tabName = selectedSectionLabel
        end
        if not tabName and selectedTabName
            and not selectedTabName:find("^ListBoxItem:") then
            tabName = selectedTabName
        end
        if not tabName and focusedSectionLabel then
            tabName = focusedSectionLabel
        end

        -- Appearance page: no CC VM type, no recognized tab name.
        -- Detect by the Randomise button (unique to Appearance) or
        -- by element names containing "Appearance".
        if not tabName then
            if focusedElement.elemName
                and (focusedElement.elemName:find("Appearance", 1, true)
                    or focusedElement.elemName:find("newRandom", 1, true)) then
                tabName = "Appearance"
            elseif focusedElement.elemText
                and focusedElement.elemText == "Randomise" then
                tabName = "Appearance"
            end
        end

        -- Dedup: skip screen entry announcement if same tab, but DON'T
        -- return — let the rest of the function handle value cycling.
        if tabName and tabName == ccState.lastSpokenTab then
            Log.Debug("SKIP CC screen entry (same tab): " .. tabName)
            isScreenEntry = false
        end

        Log.Info("SCREEN ENTRY: tab=" .. tostring(tabName)
            .. " sel=" .. tostring(snapshot.selectionChanged)
            .. " widget=" .. tostring(snapshot.widgetAdded))

        -- Update lastSpokenTab.  Never overwrite with nil — preserve
        -- the previous value so pages without recognized tab names
        -- (like Appearance) don't trigger first-entry logic repeatedly.
        local previousTab = ccState.lastSpokenTab
        if tabName then
            ccState.lastSpokenTab = tabName
        end
        ccState.lastSpokenItemName = nil  -- reset so label speaks on new page
        ccState.lastSpokenName = nil

        -- Track main RB tab separately from lastSpokenTab.
        -- Update on RB tab switches (selectionChanged=true) and on
        -- section-change detection (focusChanged into sub-sections
        -- like Subclass, Skills, Spell).  This ensures description
        -- lookups read the correct source: e.g. SelectedSubClass for
        -- domains instead of InfoClassDescription for the parent class.
        if snapshot.selectionChanged then
            ccState.lastMainTab = detectedSectionLabel or tabName
        elseif snapshot.focusChanged then
            -- If we focused a sub-section (Skills, Spell), use it.
            -- If we focused the god-object wrapper (nil), fall back
            -- to the currently selected carousel tab (Race, Class).
            -- If both are nil, keep the current ccState.
            ccState.lastMainTab = focusedSectionLabel
                or selectedSectionLabel or ccState.lastMainTab
        end

        -- Deity page detection: deity carousel items inherit the
        -- god-object DC (no unique VM type like ls.VMSelectableSubClass),
        -- so detectedSectionLabel is always nil.  Instead, check if the
        -- tab name is actually a deity display name from the StaticData
        -- cache.  If so, this is the deity page.
        if ccState.lastMainTab
            and not CC_TAB_STATIC_DATA_TYPE[ccState.lastMainTab]
            and Helpers.LookupStaticDataDescription("God", ccState.lastMainTab) then
            ccState.lastMainTab = "Deity"
            if tabName and not CC_TAB_STATIC_DATA_TYPE[tabName] then
                tabName = "Deity"
            end
        end

        -- ----- Title -----
        local screenTitle = nil
        local effectiveDCType = ccState.currentWidgetDCType
            or focusedElement.dcType
            or (snapshot.widgetData and snapshot.widgetData.dcType)
        if effectiveDCType == "gui::DCCharacterCreation" then
            screenTitle = "Character Creation"
        end
        local normalTab = tabName and Helpers.NormalizeForCompare(tabName) or ""
        if screenTitle and normalTab ~= ""
            and Helpers.NormalizeForCompare(screenTitle) == normalTab then
            screenTitle = nil
        end
        if screenTitle and screenTitle == ccState.lastSpokenTitle then
            screenTitle = nil
        end
        if screenTitle then
            ccState.lastSpokenTitle = screenTitle
            speechData:Add("title", screenTitle, "brief")
        end

        -- ----- Hint -----
        if not ccState.tabHintSpoken then
            ccState.tabHintSpoken = true
            speechData:Add("hint", "Use bumpers to switch tabs.", "normal")
        end

        -- ----- Tab name -----
        if tabName then
            local showTabName = true
            if screenTitle and Helpers.NormalizeForCompare(screenTitle):find(normalTab, 1, true) then
                showTabName = false
            end
            if showTabName then
                speechData:Add("tabName", tabName, "brief")
            end
        end

        -- Abilities page: speak points remaining and first-time rules hint.
        -- Body text: ability info or tab hint (tab hint overwrites ability
        -- info when both are present).
        local screenBody = nil
        if tabName == "Abilities" and focusedElement.dcProps then
            local bodyParts = {}
            if not ccState.abilityHintSpoken then
                ccState.abilityHintSpoken = true
                table.insert(bodyParts,
                    "Every 2 points above 10 gives plus 1 to related rolls")
            end
            local unusedPoints = focusedElement.dcProps.UnusedAbilityPoints
            if unusedPoints then
                table.insert(bodyParts, unusedPoints .. " points remaining")
            end
            if #bodyParts > 0 then
                screenBody = table.concat(bodyParts, ". ")
            end
        end

        -- Tab hint: spoken once per tab on first visit.
        -- Only fire on selection-based entry (bumper press), not on
        -- focus-only section crossings (summary panel scrolling).
        local hintKey = tabName
        if not hintKey and detectedSectionLabel then
            hintKey = detectedSectionLabel
        end
        if hintKey and not ccState.tabHintsSpoken then
            ccState.tabHintsSpoken = {}
        end
        if hintKey and ccState.tabHintsSpoken
            and not ccState.tabHintsSpoken[hintKey]
            and snapshot.selectionChanged then
            local hint = CC_TAB_HINTS[hintKey]
            if hint then
                ccState.tabHintsSpoken[hintKey] = true
                screenBody = hint  -- overwrites ability info
                Log.Info("TAB HINT: " .. hintKey .. " -> " .. hint:sub(1, 60))
            end
        end

        -- First CC entry: natural introduction speech.
        -- Overrides title/hint/body with a custom introduction.
        if not previousTab then
            -- Reset speechData for the introduction (discard any
            -- title/hint/tabName added above).
            speechData = Helpers.CreateSpeechData()
            if namingScreenWasSpoken then
                -- Guardian character creation entry (from naming screen).
                speechData:Add("title", "Guardian Appearance", "brief")
                speechData:Add("hint",
                    "Choose your guardian's appearance."
                    .. " D-pad up and down to browse options."
                    .. " D-pad left and right to change values."
                    .. " Press Y to venture forth and start the game."
                    .. " Press B to return to character naming.", "normal")
                ccState.lastSpokenTitle = "Guardian Appearance"
                namingScreenWasSpoken = false
                Log.Info("CC SLOTS: guardian entry")
            elseif ccState.currentWidgetDCType
                == "gui::DCCharacterLevelUp" then
                -- Level up entry.
                local levelUpClass = nil
                if snapshot.focusedElement
                    and snapshot.focusedElement.namedTexts then
                    levelUpClass =
                        snapshot.focusedElement.namedTexts.classLevelText
                end
                local levelUpTitle = "Level Up"
                if levelUpClass and levelUpClass ~= "" then
                    levelUpTitle = "Level Up: " .. levelUpClass
                end
                speechData:Add("title", levelUpTitle, "brief")
                speechData:Add("hint",
                    "Up and down to review gains."
                    .. " Press Y to accept."
                    .. " Press X to add a class."
                    .. " Press B to exit.", "normal")
                ccState.lastSpokenTitle = levelUpTitle
                Log.Info("CC SLOTS: level up entry, "
                    .. tostring(levelUpClass))
            else
                -- Main character creation entry.
                speechData:Add("title", "Character Creation", "brief")
                speechData:Add("hint", "You are on the "
                    .. (tabName or "origin")
                    .. " page. Use bumpers to switch tabs.", "normal")
                ccState.lastSpokenTitle = "Character Creation"
                Log.Info("CC SLOTS: first entry, tab=" .. tostring(tabName))
            end
            ccState.tabHintSpoken = true
            ccState.lastMainTab = detectedSectionLabel or tabName
            ccState.lastSpokenName = elemId
            speechData:Speak(ccState, true)
            return
        end

        -- Add body text (ability info or tab hint) for non-first-entry
        -- screen entries.
        if screenBody then
            speechData:Add("body", screenBody, "normal")
        end
    end

    -- =================================================================
    -- Unified item extraction: parse ONCE via GetCCItemData.
    -- Both screen entry and item nav use the same result.
    -- =================================================================
    local effectiveTabForExtraction = tabName or ccState.lastSpokenTab
    local itemName, itemValue, itemDesc = GetCCItemData(
        focusedElement, snapshot, effectiveTabForExtraction,
        isScreenEntry)

    -- Item navigation dedup: same elemId and same extracted name.
    -- Skip dedup when valueChanged (DC swapped on recycled element)
    -- or when the value differs from what was last spoken (body type
    -- cycling: same "Body Type" name but different value each time).
    if isItemNav and elemId == ccState.lastSpokenName and not hasCarousel
        and not snapshot.valueChanged then
        local valueDiffers = itemValue
            and itemValue ~= ccState.lastSpokenFullText
        if not valueDiffers then
            if not itemName or itemName == ccState.lastSpokenItemName
                or itemName == ccState.lastSpokenFullText then
                Log.Debug("DEDUP SKIP: " .. tostring(elemId))
                return
            end
        end
    end

    -- ----- Section header suppression -----
    -- Applied to the parsed name, not re-extracted.  GetCCItemData
    -- returns raw data; the handler decides what to suppress.
    if itemName then
        local effectiveTab = tabName or ccState.lastSpokenTab
        local normalTab = effectiveTab
            and Helpers.NormalizeForCompare(effectiveTab) or ""
        local normalItem = Helpers.NormalizeForCompare(itemName)

        if normalTab ~= "" and normalItem == normalTab then
            -- Name duplicates tab; suppress name but keep desc/value.
            Log.Debug("SUPPRESS TAB DUP: " .. itemName)
            itemName = nil
        elseif CC_SECTION_HEADERS[normalItem] then
            -- Known section header (Skill Proficiency, Cantrip, Spell).
            Log.Debug("SUPPRESS HEADER: " .. itemName)
            itemName = nil
        elseif isScreenEntry and focusedSectionLabel
            and normalTab ~= "" and not itemValue
            and normalItem:find(normalTab, 1, true) then
            -- Name restates section header; suppress name but keep desc.
            Log.Debug("SUPPRESS SECTION RESTATE: " .. itemName)
            itemName = nil
        end

        -- When name is suppressed but desc/value will still speak,
        -- update ccState.lastSpokenName so the dedup check on the NEXT
        -- element doesn't compare against the stale elemId from two
        -- visits ago.  Without this, Custom->Origin(suppressed)->Custom
        -- causes the second Custom to dedup-skip because
        -- lastSpokenName still points at the first Custom's elemId.
        if not itemName and (itemDesc or itemValue) then
            ccState.lastSpokenName = elemId
            ccState.lastSpokenItemName = nil
        end
    end

    -- AUTO-RECOVERY: If lastMainTab points to a sub-section (Skills)
    -- but we're focused on an item that matches a god-object selected
    -- category (SelectedRace.Name == "Elf"), auto-correct lastMainTab.
    -- This handles d-pad up from Skills back to the Race carousel
    -- where focusedSectionLabel is nil (god-object DC) and
    -- selectedSectionLabel is unavailable (no selection change).
    if itemName and not isScreenEntry and isItemNav
        and focusedElement.dcType == "gui::DCCharacterCreation"
        and focusedElement.dcProps then
        for recoveryTab, selectedPropKey
            in pairs(CC_SELECTED_DESCRIPTION_KEYS) do
            local selectedPropData =
                focusedElement.dcProps[selectedPropKey]
            if type(selectedPropData) == "table" then
                local currentActiveName = selectedPropData.Name
                    or selectedPropData.DisplayName
                    or selectedPropData.Title
                if currentActiveName and currentActiveName ~= ""
                    and currentActiveName:lower()
                    == itemName:lower() then
                    if ccState.lastMainTab ~= recoveryTab then
                        Log.Debug("AUTO-RECOVER lastMainTab: "
                            .. tostring(ccState.lastMainTab) .. " -> "
                            .. recoveryTab)
                        ccState.lastMainTab = recoveryTab
                    end
                    break
                end
            end
        end
    end

    -- Cross-element dedup.
    if isItemNav and itemName and not itemDesc and not itemValue
        and ccState.lastSpokenFullText then
        local normalItem = Helpers.NormalizeForCompare(itemName)
        local normalLast = Helpers.NormalizeForCompare(ccState.lastSpokenFullText)
        if normalItem == normalLast
            or (normalLast:sub(-#normalItem) == normalItem) then
            Log.Debug("DEDUP SKIP (cross-element): " .. tostring(itemName))
            return
        end
    end

    -- Value-only speech: when cycling values on the same item (e.g.,
    -- left/right on Body Type), suppress the label and speak only the
    -- new value.  Mimics Options menu behavior (label on first visit,
    -- value-only on subsequent changes).
    if itemName and itemValue and ccState.lastSpokenItemName
        and itemName == ccState.lastSpokenItemName then
        -- Same label, different value -> speak value only.
        ccState.lastSpokenFullText = itemValue
        ccState.lastSpokenName = elemId
        ccState.lastSpokenItemName = itemName
            Log.Info("VALUE CYCLE: " .. itemValue)
        Ext.Tolk.Speak(itemValue, true)
        return
    end

    if itemName then
        ccState.lastSpokenItemName = itemName
        ccState.lastSpokenName = elemId
        ccState.lastSpokenFullText = itemName
        Log.Info("ITEM: " .. tostring(focusedElement.elemType)
            .. "  name=" .. itemName
            .. (itemValue and ("  val=" .. itemValue) or "")
            .. (itemDesc and ("  desc=" .. tostring(itemDesc):sub(1, 40)) or ""))
    end
    speechData:Add("itemName", itemName, "brief")
    speechData:Add("itemValue", itemValue, "brief")
    speechData:Add("itemDesc", itemDesc, "verbose")

    -- DIAG: log when all extraction paths produced nothing (silent element).
    if not itemName and not itemValue and not itemDesc then
        Log.Info("SILENT ELEMENT: elemId=" .. tostring(elemId)
            .. " elemType=" .. tostring(focusedElement.elemType)
            .. " elemText=" .. tostring(focusedElement.elemText)
            .. " dcType=" .. tostring(focusedElement.dcType)
            .. " isScreen=" .. tostring(isScreenEntry)
            .. " isItem=" .. tostring(isItemNav))
        if focusedElement.dcProps then
            local propList = {}
            for propName, propValue in pairs(focusedElement.dcProps) do
                table.insert(propList, propName .. "=" .. tostring(propValue))
            end
            Log.Info("SILENT dcProps: " .. table.concat(propList, " | "))
        end
    end

    speechData:Speak(ccState, isScreenEntry)
end

-- ============================================================================
-- State query and reset (exported for Manager)
-- ============================================================================

--- IsInCC: returns true if currently in character creation.
--- Called by the Manager for cutscene-to-CC return detection.
local function IsInCC()
    return ccState.inCharacterCreation
end

--- HandleWidgetAdded: called by the Manager for every widgetAdded event,
--- the same way Menus.HandleWidgetAdded is called.  CC owns all logic about
--- what to do when its widget re-appears after a dialog or cutscene.
---
--- When the CC widget (gui::DCCharacterCreation) is re-added while already
--- in CC (e.g. returning from an origin preview blurb), treat it as a fresh
--- first entry.  This clears stale navigation dedup so d-pad works correctly
--- rather than inheriting focus state from before the blurb.
local function HandleWidgetAdded(widgetData)
    if not widgetData or not widgetData.dcType then return end
    -- Track the widget DC type so we know if we're in CC vs Level Up.
    if widgetData.dcType == "gui::DCCharacterCreation"
        or widgetData.dcType == "gui::DCCharacterLevelUp" then
        ccState.currentWidgetDCType = widgetData.dcType
    end
    if not ccState.inCharacterCreation then return end
    if widgetData.dcType ~= "gui::DCCharacterCreation" then return end
    Log.Info("CC: DCCharacterCreation re-added while in CC"
        .. " -- resetting for fresh entry (blurb return)")
    ResetCCState()
end

-- ============================================================================
-- Exports
-- ============================================================================

BG3Access.Client.CC = {
    IsCCSnapshot         = IsCCSnapshot,
    HandleCCSnapshot     = HandleCCSnapshot,
    HandleWidgetAdded    = HandleWidgetAdded,
    GetSectionLabel      = GetSectionLabel,
    GetBodyTypeName      = GetBodyTypeName,
    CC_SECTION_LABELS    = CC_SECTION_LABELS,
    SubscribeCCYButton   = SubscribeCCYButton,
    UnsubscribeCCYButton = UnsubscribeCCYButton,
    IsInCC               = IsInCC,
    ResetCCNavigation    = ResetCCNavigation,
    ResetCCState         = ResetCCState,
}
