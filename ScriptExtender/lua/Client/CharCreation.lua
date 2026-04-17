-- File: Client/CharCreation.lua
--
-- Character Creation per-page factory router.
--
-- CC uses a god-object DataContext (gui::DCCharacterCreation) with 100+
-- properties.  Generic FormatDCText / FormatDCTextSplit cannot extract
-- useful text from it, so CC logic lives here in isolation.
--
-- Architecture:
--   * Shared module state (ccState) tracks cross-page concerns:
--     transitions, naming screen, guardian detection, intro split,
--     selected origin, widget DC type.
--   * Each CC page (Origin / Race / Class / Abilities / Skills /
--     Appearance / ...) has its own handler created by
--     CreateCCPageHandler.  Per-handler state (dedup, tab-hint spoken,
--     last-carousel tick) is owned by the handler, not by ccState.
--   * HandleCCSnapshot is the thin router.  It classifies the current
--     page, handles transitions / instructions / first-entry speech,
--     then dispatches to the active handler.
--
-- The Manager detects CC and delegates here via HandleCCSnapshot().

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

-- Sub-item VM types that appear on MULTIPLE pages as feature/spell/skill
-- rows (class features list, race features list, background skill
-- proficiency section, etc.).  When these types appear as the FOCUSED
-- element, they must NOT trigger a page re-classification on d-pad
-- alone (focusChanged) -- doing so would switch from e.g. the Class
-- page to the Spell page when the user merely d-padded down into the
-- class features list.  They only re-classify when selectionChanged
-- is true (the user pressed RB/LB to switch tabs).
local CC_SUBITEM_DC_TYPES = {
    ["ls.VMSpellReference"]      = true,
    ["ls.VMSkill"]               = true,
    ["ls.VMAbility"]             = true,
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
    -- Unicode multiplication sign: the multi-byte x character.
    -- Short strings starting with ( ending with ) containing a digit.
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
    ["Cantrip"] = "Change your cantrip selection by choosing from the spell list below. D-pad in all directions to navigate the spell grid. Cantrips don't use spell slots and can be cast at will.",
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

-- Section-transition labels: spoken once when focus moves from the
-- carousel into the sub-item feature list on a carousel page.  Gives
-- the player context that these items are granted automatically, not
-- selections they need to make.
local CC_SECTION_TRANSITION_LABELS = {
    ["Race"]     = "You acquire the following:",
    ["Subrace"]  = "You acquire the following:",
    ["Class"]    = "You acquire the following:",
    ["Subclass"] = "You acquire the following:",
}

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

-- Valid page names (whitelist for the classifier).  Must cover every
-- key in PAGE_HANDLERS below; it is declared here because
-- ClassifyPage is defined before PAGE_HANDLERS.  Without this
-- whitelist, arbitrary tabName strings like "Custom" or "Astarion"
-- (the origin carousel's selected ListBoxItem names) would be
-- accepted as page identifiers, flipping ccState.currentPage and
-- re-triggering screen-entry speech on every carousel step.
local CC_PAGE_NAMES = {
    ["Origin"]           = true,
    ["Race"]             = true,
    ["Subrace"]          = true,
    ["Class"]            = true,
    ["Subclass"]         = true,
    ["Background"]       = true,
    ["Deity"]            = true,
    ["Feat"]             = true,
    ["Abilities"]        = true,
    ["Ability Bonus"]    = true,
    ["Skills"]           = true,
    ["Cantrip"]          = true,
    ["Spell"]            = true,
    ["High Elf Cantrip"] = true,
    ["Appearance"]       = true,
}

-- ============================================================================
-- CC module state (shared across all per-page handlers)
-- ============================================================================
--
-- Per-page state (dedup, last-spoken, tab-hint spoken) lives on each
-- handler's handlerState table.  ccState holds only cross-page
-- concerns: transitions, naming screen, guardian detection, intro
-- split, selected origin, currentWidgetDCType, and the active handler
-- pointer used by the router.

local ccState = {
    -- Speech dedup / last-spoken tracking (router-level; also referenced
    -- by :Speak(ccState, ...) for cross-call dedup after first entry).
    lastSpokenName           = nil,
    lastSpokenFullText       = nil,
    lastSpokenTab            = nil,
    lastSpokenTitle          = nil,
    lastSpokenItemName       = nil,
    lastMainTab              = nil,
    lastCarouselTick         = nil,
    -- Router-level flags retained for first-entry and transition logic.
    screenEntryJustSpoke     = false,
    inCharacterCreation      = false,
    inPostNamingCC           = false,
    pendingTransition        = nil,
    suppressGuardianTeardown = false,
    activeInstruction        = nil,
    selectedOriginName       = nil,
    isCustomOrigin           = nil,
    currentWidgetDCType      = nil,
    -- Router dispatch state (per-page factory refactor).
    currentPage              = nil,
    activePageHandler        = nil,
    firstEntrySpoken         = false,
    -- Intro split state (main CC entry only).
    introAwaitingContinue       = false,
    introContinueSubscription   = nil,
    introAxisSubscription       = nil,
    introButtonSuppression      = nil,
    introAxisSuppression        = nil,
    customBackstoryText         = nil,
    -- Suppresses INPC follow-up after standalone carousel already spoke
    -- name + description for the same item.
    lastStandaloneCarouselValue = nil,
    lastHandlerSpeechData       = nil,
    -- CC tooltip dedup field.  Helpers.ProcessTooltip mutates this to
    -- collapse subset / superset waves.  Isolated from WorldUI's
    -- tooltipState holder because the two contexts don't share namespace
    -- and must reset independently on CC enter / exit.
    lastTooltipSpeech           = nil,
    -- Post-cutscene return suppression.  When the origin-preview cutscene
    -- ends, Noesis rebuilds the CC UI and fires a burst of stale focus /
    -- selection events (every carousel item cycles through).  Without a
    -- gate the user hears the full origin backstory again -- sometimes
    -- doubled.  awaitingPostCutsceneNav suppresses all handler dispatch
    -- until genuine user d-pad input arrives.  The hint speaks once on
    -- the first noise tick, then silence until the user re-engages.
    -- postCutsceneArmedAt stores MonotonicTime() when the gate was armed;
    -- the noise burst finishes within ~500ms, so any focus/selection
    -- change arriving 1000ms+ after arming is genuine user input.
    awaitingPostCutsceneNav     = false,
    postCutsceneHintSpoken      = false,
    postCutsceneArmedAt         = 0,
}

-- Forward declaration: handler-block code assigns this so
-- ResetCCState / HandleWidgetAdded can reset per-handler state too.
local resetHandlersHook = nil

-- ============================================================================
-- CC helper functions
-- ============================================================================

local ResolveTranslatedString = Helpers.ResolveTranslatedString
-- Stat description helpers: shared versions from Helpers.lua.
local ParseDescriptionParam = Helpers.ParseDescriptionParam
local ResolveDescriptionParams = Helpers.ResolveDescriptionParams
local ReadStatDescription = Helpers.ReadStatDescription

-- Get the CC section label from a data table's dcType.
-- Returns section name string or nil.
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

-- Returns true if the dcType is a sub-item or feature type that
-- appears on multiple pages (class features, race features, etc.).
-- Used to detect the carousel-to-feature-list section transition.
local function IsFeatureOrSubItemDCType(dcType)
    if not dcType then return false end
    return CC_SUBITEM_DC_TYPES[dcType] == true
        or CC_FEATURE_DC_TYPES[dcType] == true
end

-- Body-type tab names (Male, Female, MaleStrong, FemaleStrong) appear
-- as selectedElement.tabName when the Origin page's gender selector or
-- the Appearance page's body-type row cycles.  These are NOT page
-- tabs; they are sub-item values.  Treating them as page tabs caused
-- "You are on the Female page" and re-announcing the hint on every
-- gender change.  The classifier uses this to filter them out.
local function IsBodyTypeTabName(tabName)
    if type(tabName) ~= "string" or tabName == "" then return false end
    return BODY_TYPE_NAMES[tabName:lower()] ~= nil
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
-- itemName is the display name of the currently selected item
-- (race name, class name, deity name, etc.) used for API lookups.
local function GetGodObjectDescription(dcProps, tabName, itemName)
    if not dcProps or not tabName then return nil end

    local staticDataType = CC_TAB_STATIC_DATA_TYPE[tabName]

    -- 1. StaticData API by display name (primary).
    if staticDataType and itemName and itemName ~= "" then
        local apiDesc = Helpers.LookupStaticDataDescription(
            staticDataType, itemName)
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
local function FormatCCDCTextSplit(dcProps, dcType)
    if not dcProps then return nil, nil, nil end

    local text = nil
    local value = nil
    -- API-first: descriptions are NOT extracted from dcProps here.
    -- GetCCItemData runs API lookups (StaticData, Feature/Passive,
    -- Spell) which resolve parameter placeholders like [2] into real
    -- values.  Raw dcProps.Description is the LAST RESORT fallback
    -- in GetCCItemData, used only when all API lookups fail (modded
    -- content with no stat entry).
    local desc = nil

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
                value = (numericValue >= 0 and "+" or "")
                    .. tostring(numericValue)
            end
        end
    end

    -- VMSpellReference: Spell sub-table has the spell details.
    -- Name only; description deferred to API (LookupSpellDescription
    -- resolves DescriptionParams).
    if not text and type(dcProps.Spell) == "table" then
        local spellTable = dcProps.Spell
        text = spellTable.Name or spellTable.DisplayName
            or spellTable.Title or spellTable.Text
    end

    -- VMFeatureBoost / VMPassiveFeatureBoost: NameCTS.Text or
    -- ShortName has the display name.
    if not text and type(dcProps.NameCTS) == "table" then
        text = dcProps.NameCTS.Text
    end
    if not text and dcProps.ShortName then
        text = dcProps.ShortName
    end

    -- VM carousel items (VMSelectableRace, VMSelectableOrigin,
    -- VMSelectableClass, VMSelectable): Name is the display name.
    -- Two guards prevent false matches on the god-object
    -- (gui::DCCharacterCreation): IDString (present on VM types but
    -- not on the god-object), and dcType membership in
    -- CC_SECTION_LABELS (covers the post-cutscene case where
    -- selected-as-focused elements may lack IDString in dcProps).
    -- Description is returned separately so the caller can place it
    -- in its own SpeechData field rather than concatenating it into
    -- the name.
    local isVMCarouselType = dcProps.IDString
        or (dcType and CC_SECTION_LABELS[dcType])
    if not text and type(dcProps.Name) == "string"
        and dcProps.Name ~= "" and isVMCarouselType then
        text = dcProps.Name
        -- Return description separately (API-first enrichment in
        -- GetCCItemData may override with a StaticData lookup, but
        -- when it can't the raw VM description is the best we have).
        -- Strip markup since some VM descriptions carry formatting.
        if type(desc) == "string" and desc ~= "" then
            desc = Helpers.StripMarkupTags(desc)
        else
            desc = nil
        end
    end

    if not text or text == "" then return nil, nil, nil end
    return text, value, desc
end

-- Origin / Appearance page context labels.  Body Type and Identity
-- rows appear on both pages and use the same extraction logic.
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
    if Helpers.NormalizeForCompare(elemText) == "origin" then
        return nil, nil,
            "Play as an existing character from Baldur's Gate 3"
    end

    -- Origin character name (Custom, Astarion, etc.): match against SelectedOrigin.
    local selectedOrigin = data.dcProps.SelectedOrigin
    if type(selectedOrigin) == "table" then
        local originName = selectedOrigin.Name or selectedOrigin.DisplayName
            or selectedOrigin.Title
        if originName and Helpers.NormalizeForCompare(elemText)
            == Helpers.NormalizeForCompare(originName) then
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
-- Unified item data extraction
-- ============================================================================
--
-- GetCCItemData is the single source of truth for per-element name/
-- value/description extraction.  All handler pipelines (screen entry,
-- item nav, value-only) call it.
--
-- Pipeline (stops at first name hit):
--   1. Placeholder guard
--   2. Level-up summary items (DCCharacterLevelUp)
--   3. FormatCCDCTextSplit (Skill, Ability, Spell dcProps)
--   4. ExtractOriginContext (Body Type, Identity, Origin)
--   5. Helpers.FormatDCText (generic dcProps)
--   6. Helpers.ExtractTextFromData (visual text / elemText fallback)
-- Then applies overrides (carousel, toggles, bonus ability, stat labels)
-- and enriches with API-first descriptions.

local function GetCCItemData(focusedElement, snapshot, tabName,
                             isScreenEntry)
    if not focusedElement then return nil, nil, nil end

    local dcProps = focusedElement.dcProps
    local itemName = nil
    local itemValue = nil
    local itemDescription = nil

    -- 1. Placeholder guard.
    local elemText = focusedElement.elemText
    if elemText and IsPlaceholder(elemText) then
        Log.Debug("GetCCItemData: strip placeholder elemText: " .. elemText)
        elemText = nil
    end

    -- 2. Level-up summary items (DCCharacterLevelUp).
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

    -- 3. FormatCCDCTextSplit: Skill, Ability, Spell sub-table dcProps.
    itemName, itemValue, itemDescription = FormatCCDCTextSplit(
        dcProps, focusedElement.dcType)

    -- 4. ExtractOriginContext: Body Type, Identity, Origin character.
    if not itemName or itemName == "" then
        itemName, itemValue, itemDescription = ExtractOriginContext(
            focusedElement)
    end

    local elementClaimed = (itemName and itemName ~= "")
        or (itemDescription and itemDescription ~= "")

    -- 5. Helpers.FormatDCText: generic dcProps formatting.
    if not elementClaimed then
        itemName = Helpers.FormatDCText(dcProps)
        itemValue = nil
        itemDescription = nil
        elementClaimed = itemName and itemName ~= ""
    end

    -- 6. Helpers.ExtractTextFromData: visual text / elemText fallback.
    if not elementClaimed then
        local effectiveTab = tabName or ccState.lastSpokenTab
        itemName = Helpers.ExtractTextFromData(
            focusedElement, effectiveTab, isScreenEntry)
        itemValue = nil
        itemDescription = nil
    end

    -- DC property authority for carousel pages: TryShallowChildTextScan
    -- finds whichever TextBlock is first in BFS order, which may be
    -- any of the 3 visible carousel items.  The god-object SelectedX.
    -- Name is authoritative for the actual current selection.
    --
    -- SKIP when a specific extractor already claimed the element with
    -- a description but no name.  ExtractOriginContext returns
    -- (nil, nil, "Play as an existing character...") for the Origin
    -- category button; overriding itemName with SelectedOrigin.Name
    -- ("Astarion") would replace the category announcement with a
    -- specific character the user hasn't navigated to yet.
    local hasDescriptionOnly = (itemDescription and itemDescription ~= "")
        and (not itemName or itemName == "")
    if not hasDescriptionOnly
        and focusedElement.dcType == "gui::DCCharacterCreation"
        and dcProps then
        local effectiveTab = tabName or ccState.lastMainTab
            or ccState.lastSpokenTab
        if effectiveTab then
            local subTableKey = CC_SELECTED_DESCRIPTION_KEYS[effectiveTab]
            if subTableKey then
                local subTable = dcProps[subTableKey]
                if type(subTable) == "table" then
                    local dcName = subTable.Name
                        or subTable.DisplayName or subTable.Title
                    if dcName and dcName ~= "" then
                        -- Only override carousel container BFS results,
                        -- not sub-item labels.  If itemName resolves via
                        -- StaticData for this tab, it IS a carousel item
                        -- (possibly wrong from BFS ordering) and dcName
                        -- corrects it.  If itemName does NOT resolve, it
                        -- is a sub-item (Identity, Body Type, etc.) and
                        -- is already correct.
                        local shouldOverride = (not itemName
                            or itemName == "")
                        if not shouldOverride and itemName then
                            local staticDataType =
                                CC_TAB_STATIC_DATA_TYPE[effectiveTab]
                            if staticDataType then
                                shouldOverride =
                                    Helpers.LookupStaticDataDescription(
                                        staticDataType, itemName) ~= nil
                            end
                        end
                        if shouldOverride then
                            itemName = dcName
                            if not itemDescription
                                or itemDescription == "" then
                                itemDescription = nil
                            end
                        end
                    end
                end
            end
        end
    end

    -- If all extractors produced nothing, bail.
    if (not itemName or itemName == "")
        and (not itemDescription or itemDescription == "") then
        return nil, nil, nil
    end

    -- Final placeholder check on extracted name.
    if itemName and IsPlaceholder(itemName) then
        Log.Info("GetCCItemData: suppress placeholder name: " .. itemName)
        return nil, nil, nil
    end

    -- Element name overrides: terse button text -> friendlier label.
    if itemName and focusedElement.elemName
        and CC_ELEM_NAME_OVERRIDES[focusedElement.elemName] then
        itemName = CC_ELEM_NAME_OVERRIDES[focusedElement.elemName]
    end

    -- --------------------------------------------------------------
    -- Post-extraction overrides (only when itemName is set).
    -- Description-only elements skip these.
    -- --------------------------------------------------------------
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

        -- Toggle properties: read value from god-object property.
        if not itemValue and dcProps then
            local toggleProperty = CC_TOGGLE_PROPERTIES[itemName]
            if toggleProperty then
                local toggleValue = dcProps[toggleProperty]
                if type(toggleValue) == "string" and toggleValue ~= "" then
                    itemValue = toggleValue
                end
            end
        end

        -- Appearance label properties: elemText IS the label.
        if not itemValue and dcProps then
            local appearanceMapping =
                CC_APPEARANCE_LABEL_PROPERTIES[itemName]
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

        -- Slider setting value: FormatDCValue restores value on
        -- left/right presses (binding makes raw Value nil at focus).
        if not itemValue
            and focusedElement.dcType == "gui::VMSliderSetting" then
            local sliderValue = Helpers.FormatDCValue(dcProps)
            if sliderValue and sliderValue ~= "" then
                itemValue = sliderValue
            end
        end

        -- Bonus ability: append selected ability name for "+2 Bonus".
        if itemName:find("Bonus", 1, true) and dcProps
            and dcProps.SelectedBonusAbility then
            itemName = itemName .. " to " .. dcProps.SelectedBonusAbility
            Log.Debug("GetCCItemData: bonus ability: " .. itemName)
        end

        -- Summary stat labels: prepend static label for DC types with
        -- no name of their own (Initiative, Hit Points).
        if focusedElement.dcType
            and CC_SUMMARY_STAT_LABELS[focusedElement.dcType] then
            local staticLabel = CC_SUMMARY_STAT_LABELS[focusedElement.dcType]
            if staticLabel and staticLabel ~= "" and not itemValue then
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

    -- --------------------------------------------------------------
    -- Description enrichment (API-first).
    -- --------------------------------------------------------------
    if not itemDescription or itemDescription == "" then
        itemDescription = nil  -- normalize empty string to nil

        -- Deity detection: if lastMainTab isn't a known StaticData
        -- type but the tab name IS a deity display name, fix it.
        local effectiveMainTab = ccState.lastMainTab
        if effectiveMainTab
            and not CC_TAB_STATIC_DATA_TYPE[effectiveMainTab]
            and Helpers.LookupStaticDataDescription("God",
                effectiveMainTab) then
            effectiveMainTab = "Deity"
        end

        -- A0. VM carousel items: API description by display name.
        if not itemDescription and focusedElement.dcType
            and CC_SECTION_LABELS[focusedElement.dcType] then
            local sectionLabel = GetSectionLabel(focusedElement)
            if sectionLabel then
                local staticDataType = CC_TAB_STATIC_DATA_TYPE[sectionLabel]
                if staticDataType and itemName and itemName ~= "" then
                    itemDescription = Helpers.LookupStaticDataDescription(
                        staticDataType, itemName)
                    if itemDescription then
                        Log.Debug("GetCCItemData: VM API desc: "
                            .. itemName .. " -> "
                            .. tostring(itemDescription):sub(1, 60))
                    end
                end
            end
            -- dcProps.Description fallback (modded content).
            if not itemDescription and dcProps then
                local vmDescription = dcProps.Description
                if type(vmDescription) == "table" then
                    vmDescription = vmDescription.Text
                        or vmDescription.Str
                        or vmDescription.Description
                end
                if type(vmDescription) == "string"
                    and vmDescription ~= "" then
                    itemDescription = Helpers.StripMarkupTags(vmDescription)
                end
            end
        end

        -- A. StaticData API via GetGodObjectDescription.
        if not itemDescription
            and focusedElement.dcType == "gui::DCCharacterCreation"
            and dcProps and effectiveMainTab then
            itemDescription = GetGodObjectDescription(
                dcProps, effectiveMainTab, itemName)
            if not itemDescription
                and snapshot.inlineCarouselValue
                and snapshot.inlineCarouselValue ~= "" then
                itemDescription = GetGodObjectDescription(
                    dcProps, effectiveMainTab,
                    snapshot.inlineCarouselValue)
            end
        end

        -- B. Feature/passive API.  Some features have sparse tooltips
        -- (Darkvision: just name + range) so the description must
        -- come from the API.  For features with rich tooltips
        -- (Perception: description + ability + modifier), the exact-
        -- match Diff in ProcessTooltip strips duplicates.
        if not itemDescription and focusedElement.dcType
            and CC_FEATURE_DC_TYPES[focusedElement.dcType] then
            local featureSuccess, featureDescription = pcall(
                Helpers.LookupFeatureDescription, itemName)
            if featureSuccess and featureDescription then
                itemDescription =
                    Helpers.StripMarkupTags(featureDescription)
            end
        end

        -- C. Spell API.
        if not itemDescription and itemName
            and focusedElement.elemType
            and (focusedElement.elemType:find("LSButton", 1, true)
                or focusedElement.elemType:find("spellButton", 1, true))
            and itemName ~= "spell" then
            local spellSuccess, spellDescription = pcall(
                Helpers.LookupSpellDescription, itemName)
            if spellSuccess and spellDescription then
                itemDescription =
                    Helpers.StripMarkupTags(spellDescription)
            end
        end

        -- D. Last resort: dcProps.Description (focused or selected).
        -- For features/spells not found in the API (modded content).
        if not itemDescription then
            local rawDescription = nil
            if dcProps then
                rawDescription = dcProps.Description
            end
            if not rawDescription and snapshot.selectedElement
                and snapshot.selectedElement.dcProps then
                rawDescription =
                    snapshot.selectedElement.dcProps.Description
            end
            if type(rawDescription) == "table" then
                rawDescription = rawDescription.Text
                    or rawDescription.Str
                    or rawDescription.Description
            end
            if type(rawDescription) == "string"
                and rawDescription ~= "" then
                rawDescription = Helpers.StripMarkupTags(rawDescription)
                if rawDescription:find("%[%d+%]") then
                    rawDescription =
                        Helpers.ResolveDescriptionParams(
                            rawDescription, nil)
                end
                itemDescription = rawDescription
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
-- CC detection (called by the Manager)
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
-- CC Y-button subscription for naming-screen detection
-- ============================================================================
-- The naming screen has no d-pad focusable elements (buttons map to
-- controller inputs directly).  Instead of trying to detect it from
-- snapshots (which look identical to transient empty-focus bounces),
-- we detect the Y-button press directly and speak the naming screen
-- from the controller input callback.  Deterministic, no timing.

local ccYButtonSubscription = nil
local namingScreenWasSpoken = false

local function SpeakNamingScreen()
    local characterName = nil
    if ccState.isCustomOrigin then
        -- Custom: entity API has the renamed name (Big Pillow, etc.).
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
        characterName = ccState.selectedOriginName
    end
    if not characterName or characterName == ""
        or characterName:find("^%[%d+%]$") then
        characterName = "Tav"
    end

    ccState.lastSpokenTab = "Naming"
    ccState.lastMainTab = "Naming"
    namingScreenWasSpoken = true

    local speechData = Helpers.CreateSpeechData()
    speechData:Add("title", "Enter Character Name")
    speechData:Add("characterName", characterName, "brief")
    speechData:Add("hint",
        "Press A to rename. Press Y to choose guardian")
    local speech = speechData:Format()
    Log.Info("NAMING SCREEN: " .. speech)
    Ext.Tolk.Speak(speech, true)
    ccState.lastSpokenFullText = speech
    ccState.lastSpokenName = ""
    ccState.lastSpokenItemName = "Naming"
end

local function SubscribeCCYButton()
    if ccYButtonSubscription then return end
    ccYButtonSubscription =
        Ext.Events.ControllerButtonInput:Subscribe(function(event)
            if not event.Pressed then return end
            if not ccState.inCharacterCreation then return end
            local buttonName = tostring(event.Button)
            if buttonName == "Y" and ccState.lastMainTab ~= "Naming"
                and not ccState.inPostNamingCC then
                ccState.suppressGuardianTeardown = false
                ccState.pendingTransition = "Naming"
                Log.Debug("CC Y-button: transition to Naming")
                SpeakNamingScreen()
            elseif buttonName == "B"
                and ccState.lastMainTab == "Naming" then
                ccState.suppressGuardianTeardown = false
                ccState.pendingTransition = "MainCC"
                namingScreenWasSpoken = false
                Log.Debug("CC B-button: transition from Naming to MainCC")
            elseif buttonName == "B" and ccState.inPostNamingCC then
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

-- ============================================================================
-- Intro split (main CC first-entry LT listener)
-- ============================================================================
-- Scoped to the initial entry into main CC (currentWidgetDCType ==
-- "gui::DCCharacterCreation") AND not a naming return / guardian entry
-- AND not level up.  On that entry the router speaks a welcome message,
-- arms the LT listener, and drops subsequent CC snapshots until LT
-- fires.  The LT press then speaks the currently-selected origin's
-- backstory (Custom by default) and normal navigation resumes.
--
-- LT is the one controller input the Origin page does not bind to any
-- game action, so using it for "continue" does not collide with
-- existing controls.  PreventAction is called defensively.

local CC_INTRO_WELCOME =
    "Welcome to character creation."
    .. " You can choose to create a custom character and build from scratch,"
    .. " or you can choose a character with a preset backstory."
    .. " D-pad left and right to cycle between making a custom character"
    .. " or playing with an existing one, and down to navigate content."
    .. " Press right trigger to see a summary of your character."
    .. " Use RB and LB to switch pages."
    .. " Press left trigger to continue."

local function UnsubscribeIntroContinue()
    if ccState.introContinueSubscription then
        pcall(Ext.Events.ControllerButtonInput.Unsubscribe,
            Ext.Events.ControllerButtonInput,
            ccState.introContinueSubscription)
        ccState.introContinueSubscription = nil
    end
    if ccState.introAxisSubscription then
        pcall(Ext.Events.ControllerAxisInput.Unsubscribe,
            Ext.Events.ControllerAxisInput,
            ccState.introAxisSubscription)
        ccState.introAxisSubscription = nil
    end
    if ccState.introButtonSuppression then
        pcall(Ext.Events.ControllerButtonInput.Unsubscribe,
            Ext.Events.ControllerButtonInput,
            ccState.introButtonSuppression)
        ccState.introButtonSuppression = nil
    end
    if ccState.introAxisSuppression then
        pcall(Ext.Events.ControllerAxisInput.Unsubscribe,
            Ext.Events.ControllerAxisInput,
            ccState.introAxisSuppression)
        ccState.introAxisSuppression = nil
    end
end

local function SpeakIntroBackstory()
    -- "Create a custom character. Backstory: ...".  Prefer the text
    -- cached at welcome time.  snapshot suppression while armed keeps
    -- dcProps frozen, so the cached value is already the freshest.
    local backstory = ccState.customBackstoryText
    if not backstory or backstory == "" then
        backstory = "You've always felt you had a greater calling,"
            .. " but it has never borne fruit."
            .. " Everything changes when you awaken imprisoned on an alien ship."
            .. " Perhaps your time has finally come."
    end
    local speechData = Helpers.CreateSpeechData()
    speechData:Add("originLabel", "Create a custom character.", "brief")
    speechData:Add("originBackstory", "Backstory: " .. backstory, "verbose")
    local speech = speechData:Format()
    Log.Info("CC INTRO BACKSTORY: " .. speech)
    Ext.Tolk.Speak(speech, true)
    ccState.lastSpokenFullText = speech
end

local function HandleIntroContinuePress()
    if not ccState.introAwaitingContinue then return end
    ccState.introAwaitingContinue = false
    UnsubscribeIntroContinue()
    -- D-pad was suppressed while the gate was armed, so focus is
    -- still on the Custom origin where it landed on entry.  The
    -- cached backstory is guaranteed to match.
    SpeakIntroBackstory()
end

local function SubscribeIntroContinue()
    UnsubscribeIntroContinue()
    -- Button channel: some backends report LT as a button (either
    -- "LeftTrigger" or "TriggerLeft").
    ccState.introContinueSubscription =
        Ext.Events.ControllerButtonInput:Subscribe(function(event)
            if not event.Pressed then return end
            if not ccState.introAwaitingContinue then return end
            local buttonName = tostring(event.Button)
            if buttonName == "LeftTrigger"
                or buttonName == "TriggerLeft" then
                pcall(function() event:PreventAction() end)
                HandleIntroContinuePress()
            end
        end)
    -- Axis channel: LT also reports as an analog axis.  Edge-triggered
    -- so a held trigger doesn't re-fire.  Threshold 0.5 prevents
    -- partial pulls from triggering accidentally.
    local axisEdgeCrossed = false
    ccState.introAxisSubscription =
        Ext.Events.ControllerAxisInput:Subscribe(function(event)
            if not ccState.introAwaitingContinue then return end
            local axisName = tostring(event.Axis)
            if axisName ~= "TriggerLeft" then return end
            local value = event.Value or 0
            if value >= 0.5 then
                if not axisEdgeCrossed then
                    axisEdgeCrossed = true
                    HandleIntroContinuePress()
                end
            else
                axisEdgeCrossed = false
            end
        end)
    -- Suppress all navigation input while the gate is armed so focus
    -- can't drift from the Custom origin.  PreventAction eats the
    -- event before Noesis processes it.  LT is excluded (handled
    -- above).  Unsubscribed by UnsubscribeIntroContinue on LT press.
    ccState.introButtonSuppression =
        Ext.Events.ControllerButtonInput:Subscribe(function(event)
            if not ccState.introAwaitingContinue then return end
            if not event.Pressed then return end
            local buttonName = tostring(event.Button)
            -- Allow system buttons (Guide, Start) through.
            if buttonName ~= "LeftTrigger"
                and buttonName ~= "TriggerLeft"
                and buttonName ~= "Guide"
                and buttonName ~= "Start"
                and buttonName ~= "Back" then
                pcall(function() event:PreventAction() end)
            end
        end)
    ccState.introAxisSuppression =
        Ext.Events.ControllerAxisInput:Subscribe(function(event)
            if not ccState.introAwaitingContinue then return end
            local axisName = tostring(event.Axis)
            -- Allow LT through; suppress sticks and other axes.
            if axisName ~= "TriggerLeft" then
                pcall(function() event:PreventAction() end)
            end
        end)
    Log.Debug("Subscribed CC intro LT listener + input suppression")
end

-- ============================================================================
-- First-entry speech helpers (invoked once per flow from the router)
-- ============================================================================

-- SpeakGuardianEntry: first CC snapshot after naming -> guardian page.
local function SpeakGuardianEntry()
    local speechData = Helpers.CreateSpeechData()
    speechData:Add("title", "Guardian Appearance", "brief")
    speechData:Add("hint",
        "Choose your guardian's appearance."
        .. " D-pad up and down to browse options."
        .. " D-pad left and right to change values."
        .. " Press Y to venture forth and start the game."
        .. " Press B to return to character naming.", "normal")
    ccState.lastSpokenTitle = "Guardian Appearance"
    Log.Info("CC FIRST ENTRY: guardian")
    return speechData
end

-- SpeakLevelUpEntry: CC widget is gui::DCCharacterLevelUp.
local function SpeakLevelUpEntry(focusedElement)
    local levelUpClass = nil
    if focusedElement and focusedElement.namedTexts then
        levelUpClass = focusedElement.namedTexts.classLevelText
    end
    local levelUpTitle = "Level Up"
    if levelUpClass and levelUpClass ~= "" then
        levelUpTitle = "Level Up: " .. levelUpClass
    end
    local speechData = Helpers.CreateSpeechData()
    speechData:Add("title", levelUpTitle, "brief")
    speechData:Add("hint",
        "Up and down to review gains."
        .. " Press Y to accept."
        .. " Press X to add a class."
        .. " Press B to exit.", "normal")
    ccState.lastSpokenTitle = levelUpTitle
    Log.Info("CC FIRST ENTRY: level up, " .. tostring(levelUpClass))
    return speechData
end

-- SpeakMainCCEntry: main CC entry.  Arms the LT listener and returns
-- the welcome SpeechData.  Caches Custom's backstory for the LT press.
local function SpeakMainCCEntry(focusedElement)
    if focusedElement and focusedElement.dcProps then
        local selectedOrigin = focusedElement.dcProps.SelectedOrigin
        if type(selectedOrigin) == "table" then
            local backstory = selectedOrigin.Description
            if type(backstory) == "string" and backstory ~= "" then
                ccState.customBackstoryText = Helpers.StripMarkupTags(
                    backstory):gsub("[%.%s]+$", "")
            end
        end
    end

    ccState.introAwaitingContinue = true
    SubscribeIntroContinue()

    local speechData = Helpers.CreateSpeechData()
    speechData:Add("title", "Character Creation", "brief")
    speechData:Add("welcome", CC_INTRO_WELCOME, "verbose")
    ccState.lastSpokenTitle = "Character Creation"
    Log.Info("CC FIRST ENTRY: main, intro-await LT")
    return speechData
end

-- ============================================================================
-- Page classifier
-- ============================================================================
--
-- ClassifyPage: determine which CC page the snapshot is on.
-- Returns a page name from the set of keys in PAGE_HANDLERS, or nil.
--
-- Resolution order (returns on first hit):
--   1. focusedSectionLabel / selectedSectionLabel from CC_SECTION_LABELS
--      (VM types directly identify Race / Class / Skill / etc.)
--   2. selectedTabName, filtered to exclude body-type strings and
--      ListBoxItem:N indices (neither are real tabs)
--   3. focusedElement.tabName (when element itself is a tab), same filters
--   4. Deity detection via StaticData API when tab name looks like a deity
--   5. elemName hints for Appearance (no VM type, no header tab)
--   6. Fall back to ccState.currentPage (stay on current page)

local function ClassifyPage(snapshot)
    local focusedElement = snapshot.focusedElement
    if not focusedElement then return ccState.currentPage end

    local focusedSectionLabel = GetSectionLabel(focusedElement)
    local selectedSectionLabel = nil
    if snapshot.selectedElement then
        selectedSectionLabel = GetSectionLabel(snapshot.selectedElement)
    end

    -- VM types are the most reliable signal.
    if selectedSectionLabel then return selectedSectionLabel end
    if focusedSectionLabel then
        -- Sub-item types (VMSpellReference, VMSkill, VMAbility) appear
        -- on multiple pages: class/race feature lists, background skill
        -- proficiency, etc.  Only let them re-classify the page when
        -- selectionChanged confirms a genuine tab switch (RB/LB), not
        -- on d-pad down within the same page.  Without this gate,
        -- d-padding from the Druid carousel into its spell features
        -- would switch to SpellSelectionHandler and speak the cantrip
        -- hint instead of staying on the Class page.
        if CC_SUBITEM_DC_TYPES[focusedElement.dcType] then
            if snapshot.selectionChanged then
                return focusedSectionLabel
            end
            -- Fall through to keep current page.
        else
            return focusedSectionLabel
        end
    end

    -- Selected tab name (header carousel), filtered.  Only accept
    -- tabNames that match a known page or a deity display name.
    -- Carousel-internal ListBoxItems (Custom, Astarion, etc.) also
    -- come through as .tabName but are item selections, not pages.
    if snapshot.selectedElement and snapshot.selectedElement.isTab then
        local selectedTabName = snapshot.selectedElement.tabName
        if selectedTabName and selectedTabName ~= ""
            and not selectedTabName:find("^ListBoxItem:")
            and not IsBodyTypeTabName(selectedTabName) then
            if CC_PAGE_NAMES[selectedTabName] then
                return selectedTabName
            end
            if Helpers.LookupStaticDataDescription("God",
                    selectedTabName) then
                return "Deity"
            end
            -- Unknown name (character / item display name) -- fall
            -- through so we don't flip currentPage on carousel steps.
        end
    end

    -- Focused element's tab name (when the element IS a tab).  Same
    -- whitelist filter as above.
    if focusedElement.isTab then
        local focusedTabName = focusedElement.tabName
        if focusedTabName and focusedTabName ~= ""
            and not focusedTabName:find("^ListBoxItem:")
            and not IsBodyTypeTabName(focusedTabName) then
            if CC_PAGE_NAMES[focusedTabName] then
                return focusedTabName
            end
            if Helpers.LookupStaticDataDescription("God",
                    focusedTabName) then
                return "Deity"
            end
        end
    end

    -- Appearance page hints: no CC VM type, no recognized tab name.
    if focusedElement.elemName
        and (focusedElement.elemName:find("Appearance", 1, true)
            or focusedElement.elemName:find("newRandom", 1, true)) then
        return "Appearance"
    end
    if focusedElement.elemText == "Randomise" then
        return "Appearance"
    end

    -- Stay on the current page if nothing re-classifies.
    return ccState.currentPage
end

-- ============================================================================
-- ResetCCNavigation / ResetCCState
-- ============================================================================

--- ResetCCNavigation: clear CC navigation dedup state only.
local function ResetCCNavigation()
    ccState.lastSpokenTab = nil
    ccState.lastSpokenTitle = nil
    ccState.lastSpokenName = nil
    ccState.lastSpokenItemName = nil
end

--- ResetCCState: clear all CC state.  Called by the Manager on
--- GameStateChanged.  Also invoked by HandleWidgetAdded on blurb
--- return (preserving firstEntrySpoken so the intro does not replay).
local function ResetCCState()
    ccState.lastSpokenName = nil
    ccState.lastSpokenFullText = nil
    ccState.lastSpokenTab = nil
    ccState.lastSpokenTitle = nil
    ccState.lastSpokenItemName = nil
    ccState.lastMainTab = nil
    ccState.lastCarouselTick = nil
    ccState.screenEntryJustSpoke = false
    ccState.inCharacterCreation = false
    ccState.inPostNamingCC = false
    ccState.pendingTransition = nil
    ccState.suppressGuardianTeardown = false
    ccState.activeInstruction = nil
    ccState.selectedOriginName = nil
    ccState.isCustomOrigin = nil
    ccState.currentWidgetDCType = nil
    ccState.currentPage = nil
    ccState.activePageHandler = nil
    ccState.firstEntrySpoken = false
    ccState.introAwaitingContinue = false
    ccState.customBackstoryText = nil
    ccState.lastStandaloneCarouselValue = nil
    ccState.lastHandlerSpeechData = nil
    ccState.lastTooltipSpeech = nil
    ccState.awaitingPostCutsceneNav = false
    ccState.postCutsceneHintSpoken = false
    ccState.postCutsceneArmedAt = 0
    UnsubscribeIntroContinue()
    if resetHandlersHook then resetHandlersHook() end
end

-- ============================================================================
-- CreateCCPageHandler factory
-- ============================================================================
--
-- Mirrors Menus.CreateMenuHandler and WorldUI.CreatePanelHandler.  Each
-- page handler owns its own handlerState table and shares the generic
-- HandleSnapshot dispatch pipeline from this factory.
--
-- Config fields (all optional except name):
--   name (string)              -- display name for logs
--   pages (table of strings)   -- tab names this handler services
--   hint (string|false|nil)    -- static hint (nil -> CC_TAB_HINTS[tab])
--                                 false explicitly suppresses
--   hintFn (function)          -- (tabName, snapshot, handlerState)
--                                 -> string | false | nil
--                                 nil return falls through to hint
--   screenBodyFn (function)    -- extra body text on screen entry;
--                                 (focusedElement, tabName,
--                                  handlerState, snapshot) -> string
--   customItemFn (function)    -- per-handler item extraction override;
--                                 (focusedElement, snapshot, tabName,
--                                  handlerState) -> (name, value, desc)
--                                 return all nil to fall through to
--                                 the default GetCCItemData extractor
--   onReset (function)         -- (handlerState)
--
-- Returns: { name, pages, HandlesPage, HandleSnapshot, ResetNavigation,
--            ResetState }

local function CreateCCPageHandler(config)
    local handlerState = {
        lastSpokenName       = nil,
        lastSpokenFullText   = nil,
        lastSpokenItemName   = nil,
        lastSpokenTitle      = nil,
        lastCarouselTick     = nil,
        tabHintsSpoken       = {},   -- keyed by tab name
        screenEntryJustSpoke = false,
        -- True after the "You acquire the following..." section label
        -- has been spoken for this page visit.  Reset on page switch
        -- (ResetNavigation) so it re-speaks on return.
        sectionLabelSpoken   = false,
        -- Free-form slot for screenBodyFn / customItemFn / onReset to
        -- stash per-handler data (abilityRulesSpoken, etc.).
        handlerExtras        = {},
    }

    local pageSet = {}
    if config.pages then
        for _, pageName in ipairs(config.pages) do
            pageSet[pageName] = true
        end
    end

    local function HandlesPage(pageName)
        return pageSet[pageName] == true
    end

    -- Resolve hint for a tab: hintFn > config.hint > CC_TAB_HINTS[tab].
    local function ResolveHint(tabName, snapshot)
        if config.hintFn then
            local dynamicHint = config.hintFn(
                tabName, snapshot, handlerState)
            if dynamicHint ~= nil then return dynamicHint end
        end
        if config.hint ~= nil then return config.hint end
        return CC_TAB_HINTS[tabName]
    end

    -- ---------------------------------------------------------------
    -- HandleSnapshot: per-page dispatch pipeline.
    --   snapshot:     the full TickSnapshot
    --   tabName:      page name from the router's classifier (or nil)
    --   isFirstEntry: true when this is the first snapshot of a fresh
    --                 activation of this handler on this page
    -- ---------------------------------------------------------------
    local function HandleSnapshot(snapshot, tabName, isFirstEntry)
        local focusedElement = snapshot.focusedElement
        if not focusedElement or not focusedElement.elemType then
            return
        end

        local userInitiated = snapshot.focusChanged
            or snapshot.selectionChanged
            or snapshot.inlineCarouselChanged
            or snapshot.valueChanged

        -- Capture the standalone carousel value BEFORE clearing so we
        -- can suppress the post-settle item-nav speech that repeats
        -- what the standalone carousel already spoke.  Clear after
        -- capture so stale values don't persist across unrelated ticks.
        local standaloneCarouselJustSpoke =
            ccState.lastStandaloneCarouselValue
        if snapshot.focusChanged or snapshot.selectionChanged then
            ccState.lastStandaloneCarouselValue = nil
        end

        local elemId = focusedElement.elemId or ""
        local hasCarousel = snapshot.inlineCarouselChanged
            and snapshot.inlineCarouselValue
            and snapshot.inlineCarouselValue ~= ""

        -- Classification.  Handler-change is the screen-entry trigger;
        -- everything else is item nav or in-place change.
        local focusedSectionLabel = GetSectionLabel(focusedElement)
        local effectiveIsTab = focusedElement.isTab
            and not focusedSectionLabel
        local isScreenEntry = isFirstEntry == true

        local isItemNav = (snapshot.focusChanged
                or snapshot.selectionChanged)
            and not isScreenEntry
        local isCarouselOnly = hasCarousel and not snapshot.focusChanged
        local isValueOnly = not isScreenEntry and not isItemNav
            and not isCarouselOnly and snapshot.valueChanged

        if not isScreenEntry and not isItemNav
            and not isCarouselOnly and not isValueOnly then
            return
        end

        -- =============================================================
        -- Standalone inline carousel change (no focus shift).
        -- =============================================================
        if isCarouselOnly then
            local carouselValue = snapshot.inlineCarouselValue
            local carouselDescription = nil
            local effectiveTab = tabName or ccState.lastMainTab
                or ccState.lastSpokenTab
            if effectiveTab
                and not CC_TAB_STATIC_DATA_TYPE[effectiveTab]
                and Helpers.LookupStaticDataDescription("God",
                    effectiveTab) then
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
                    carouselDescription = carouselDesc
                end
            end
            if carouselValue ~= handlerState.lastSpokenFullText then
                handlerState.lastSpokenName = elemId
                handlerState.lastCarouselTick = Ext.Utils.MonotonicTime()
                local carouselSpeech = Helpers.CreateSpeechData()
                carouselSpeech:Add("carouselValue", carouselValue, "brief")
                if carouselDescription then
                    carouselSpeech:Add("carouselDesc",
                        carouselDescription, "normal")
                end
                local carouselFormatted = carouselSpeech:Format()
                handlerState.lastSpokenFullText = carouselFormatted
                Log.Info("CAROUSEL [" .. config.name .. "]: "
                    .. carouselFormatted)
                Ext.Tolk.Speak(carouselFormatted, true)
            end
            return
        end

        -- Suppress INPC follow-up from standalone carousel that already
        -- spoke name + description for the same item.
        if ccState.lastStandaloneCarouselValue
            and snapshot.inlineCarouselValue
            and snapshot.inlineCarouselValue
                == ccState.lastStandaloneCarouselValue then
            ccState.lastStandaloneCarouselValue = nil
            Log.Debug("SUPPRESS INPC follow-up (standalone carousel): "
                .. tostring(snapshot.inlineCarouselValue))
            return
        end

        -- Suppress value events that follow a carousel on the same
        -- element (e.g. Face carousel "Head 3" then stale "Face" value).
        if isValueOnly and handlerState.lastCarouselTick then
            local elapsed = Ext.Utils.MonotonicTime()
                - handlerState.lastCarouselTick
            if elapsed < 200 then
                Log.Debug("SUPPRESS POST-CAROUSEL VALUE ["
                    .. config.name .. "]")
                return
            end
        end

        -- =============================================================
        -- Value-only INPC change.
        -- =============================================================
        if isValueOnly then
            local itemName, itemValue, itemDescription = GetCCItemData(
                focusedElement, snapshot, tabName, false)

            if config.customItemFn then
                local customName, customValue, customDescription =
                    config.customItemFn(focusedElement, snapshot,
                        tabName, handlerState)
                if customName ~= nil then itemName = customName end
                if customValue ~= nil then itemValue = customValue end
                if customDescription ~= nil then
                    itemDescription = customDescription
                end
            end

            local hasValueOrDesc = (itemValue and itemValue ~= "")
                or (itemDescription and itemDescription ~= "")
            local nameChanged = itemName and itemName ~= ""
                and itemName ~= handlerState.lastSpokenItemName
            if not hasValueOrDesc and not nameChanged then
                return
            end

            local valueSpeech = Helpers.CreateSpeechData()
            if focusedElement.dcType == "gui::VMSliderSetting"
                and itemValue and itemValue ~= "" then
                -- Sliders: speak only the number; the name was just
                -- spoken on the initial focus arrival.
                valueSpeech:Add("itemValue", itemValue, "brief")
            else
                if itemName and itemName ~= "" then
                    valueSpeech:Add("itemName",
                        Helpers.StripMarkupTags(
                            itemName:gsub("%s+$", "")), "brief")
                end
                if itemValue and itemValue ~= "" then
                    valueSpeech:Add("itemValue",
                        Helpers.StripMarkupTags(
                            itemValue:gsub("%s+$", "")), "brief")
                end
                if itemDescription and itemDescription ~= "" then
                    valueSpeech:Add("itemDesc",
                        Helpers.StripMarkupTags(
                            itemDescription:gsub("%s+$", "")), "verbose")
                end
            end
            local fullText = valueSpeech:Format()
            if fullText and fullText ~= ""
                and fullText ~= handlerState.lastSpokenFullText then
                handlerState.lastSpokenFullText = fullText
                handlerState.lastSpokenName = elemId
                if itemName and itemName ~= "" then
                    handlerState.lastSpokenItemName = itemName
                end
                Log.Info("VALUE [" .. config.name .. "]: " .. fullText)
                Ext.Tolk.Speak(fullText, true)
            end
            return
        end

        -- =============================================================
        -- Screen entry or item navigation.
        -- =============================================================
        local speechData = Helpers.CreateSpeechData()
        local screenTitle = nil

        if isScreenEntry then
            local effectiveDCType = ccState.currentWidgetDCType
                or focusedElement.dcType
            if effectiveDCType == "gui::DCCharacterCreation" then
                screenTitle = "Character Creation"
            end
            local normalTab = tabName
                and Helpers.NormalizeForCompare(tabName) or ""
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

            if tabName
                and not handlerState.tabHintsSpoken[tabName] then
                local tabHint = ResolveHint(tabName, snapshot)
                if tabHint then
                    handlerState.tabHintsSpoken[tabName] = true
                    speechData:Add("hint", tabHint, "normal")
                elseif tabHint == false then
                    -- Explicitly suppressed; still mark spoken so we
                    -- don't try again on this visit.
                    handlerState.tabHintsSpoken[tabName] = true
                end
            end

            if tabName then
                local showTabName = true
                if screenTitle and normalTab ~= ""
                    and Helpers.NormalizeForCompare(screenTitle):find(
                        normalTab, 1, true) then
                    showTabName = false
                end
                if showTabName then
                    speechData:Add("tabName", tabName, "brief")
                end
            end

            if config.screenBodyFn then
                local extraBody = config.screenBodyFn(
                    focusedElement, tabName, handlerState, snapshot)
                if extraBody and extraBody ~= "" then
                    speechData:Add("body", extraBody, "normal")
                end
            end
        end

        -- =============================================================
        -- Item extraction (shared by screen entry and item nav).
        -- =============================================================
        local effectiveTabForExtraction = tabName or ccState.lastSpokenTab
        local itemName, itemValue, itemDescription

        if config.customItemFn then
            itemName, itemValue, itemDescription = config.customItemFn(
                focusedElement, snapshot,
                effectiveTabForExtraction, handlerState)
        end
        if itemName == nil and itemValue == nil
            and itemDescription == nil then
            itemName, itemValue, itemDescription = GetCCItemData(
                focusedElement, snapshot,
                effectiveTabForExtraction, isScreenEntry)
        end

        -- Selection-based carousel cycling fallback: d-pad cycling an
        -- outer carousel keeps focus on the god-object container and
        -- the default extractor returns "Grid".  Recover from the
        -- selectedElement (VM ListBoxItem) or from the god-object
        -- sub-table directly.
        --
        -- Guard: if an extractor returned a description but no name
        -- (e.g. ExtractOriginContext -> "Play as an existing
        -- character..."), that is a legitimate description-only claim
        -- and the fallback must not override it with a carousel item.
        local descriptionOnlyClaim = (itemDescription
            and itemDescription ~= "")
            and (not itemName or itemName == "")
        if snapshot.selectionChanged
            and (not itemName or itemName == "Grid")
            and not descriptionOnlyClaim
            and focusedElement.dcProps and effectiveTabForExtraction then
            local selectedName = nil
            local selectedDescription = nil

            if snapshot.selectedElement and snapshot.selectedElement.dcType
                and CC_SECTION_LABELS[snapshot.selectedElement.dcType] then
                local selectedDCProps = snapshot.selectedElement.dcProps
                if selectedDCProps then
                    selectedName = selectedDCProps.Name
                end
                if (not selectedName or selectedName == "")
                    and snapshot.selectedElement.tabName then
                    selectedName = snapshot.selectedElement.tabName
                end
                if selectedName and selectedName ~= "" then
                    local sectionLabel = GetSectionLabel(
                        snapshot.selectedElement)
                    if sectionLabel then
                        local staticDataType =
                            CC_TAB_STATIC_DATA_TYPE[sectionLabel]
                        if staticDataType then
                            selectedDescription =
                                Helpers.LookupStaticDataDescription(
                                    staticDataType, selectedName)
                        end
                    end
                    if not selectedDescription and selectedDCProps then
                        local vmDescription = selectedDCProps.Description
                        if type(vmDescription) == "table" then
                            vmDescription = vmDescription.Text
                                or vmDescription.Str
                                or vmDescription.Description
                        end
                        if type(vmDescription) == "string"
                            and vmDescription ~= "" then
                            selectedDescription =
                                Helpers.StripMarkupTags(vmDescription)
                        end
                    end
                end
            end

            if not selectedName then
                local subTableKey = CC_SELECTED_DESCRIPTION_KEYS[
                    effectiveTabForExtraction]
                if subTableKey then
                    local subTable = focusedElement.dcProps[subTableKey]
                    if type(subTable) == "table" then
                        selectedName = subTable.Name
                            or subTable.DisplayName or subTable.Title
                    end
                end
            end

            if selectedName and selectedName ~= "" then
                if not selectedDescription then
                    selectedDescription = GetGodObjectDescription(
                        focusedElement.dcProps,
                        effectiveTabForExtraction, selectedName)
                end
                itemName = selectedName
                itemDescription = selectedDescription
                itemValue = nil
                Log.Info("CAROUSEL FALLBACK [" .. config.name .. "]: "
                    .. selectedName .. " tab="
                    .. tostring(effectiveTabForExtraction))
            end
        end

        -- "Grid" suppression: never a valid item name.
        if itemName == "Grid" then
            Log.Debug("SUPPRESS GRID [" .. config.name .. "]: "
                .. tostring(elemId) .. " isItem="
                .. tostring(isItemNav) .. " isScreen="
                .. tostring(isScreenEntry))
            if not isScreenEntry then return end
            itemName = nil
        end

        -- Item nav dedup.
        if isItemNav and elemId == handlerState.lastSpokenName
            and not hasCarousel
            and not snapshot.valueChanged
            and not snapshot.selectionChanged then
            local valueDiffers = itemValue
                and itemValue ~= handlerState.lastSpokenFullText
            if not valueDiffers then
                if not itemName
                    or itemName == handlerState.lastSpokenItemName
                    or itemName == handlerState.lastSpokenFullText then
                    Log.Debug("DEDUP SKIP [" .. config.name .. "]: "
                        .. tostring(elemId))
                    return
                end
            end
        end

        -- Section header / tab-restate suppression.
        if itemName then
            local effectiveTab = tabName or ccState.lastSpokenTab
            local normalTab = effectiveTab
                and Helpers.NormalizeForCompare(effectiveTab) or ""
            local normalItem = Helpers.NormalizeForCompare(itemName)
            if normalTab ~= "" and normalItem == normalTab then
                Log.Debug("SUPPRESS TAB DUP [" .. config.name .. "]: "
                    .. itemName)
                itemName = nil
            elseif CC_SECTION_HEADERS[normalItem] then
                Log.Debug("SUPPRESS HEADER [" .. config.name .. "]: "
                    .. itemName)
                itemName = nil
            elseif isScreenEntry and focusedSectionLabel
                and normalTab ~= "" and not itemValue
                and normalItem:find(normalTab, 1, true) then
                Log.Debug("SUPPRESS SECTION RESTATE ["
                    .. config.name .. "]: " .. itemName)
                itemName = nil
            end

            if not itemName and (itemDescription or itemValue) then
                handlerState.lastSpokenName = elemId
                handlerState.lastSpokenItemName = nil
            end
        end

        -- Cross-element dedup: name alone already spoken.
        if isItemNav and itemName and not itemDescription
            and not itemValue
            and handlerState.lastSpokenFullText then
            local normalItem = Helpers.NormalizeForCompare(itemName)
            local normalLast = Helpers.NormalizeForCompare(
                handlerState.lastSpokenFullText)
            if normalItem == normalLast
                or (normalLast:sub(-#normalItem) == normalItem) then
                Log.Debug("DEDUP SKIP cross-element ["
                    .. config.name .. "]: " .. itemName)
                return
            end
        end

        -- Value-only cycling on the same label (e.g. body type cycling).
        if itemName and itemValue
            and handlerState.lastSpokenItemName
            and itemName == handlerState.lastSpokenItemName then
            handlerState.lastSpokenFullText = itemValue
            handlerState.lastSpokenName = elemId
            handlerState.lastSpokenItemName = itemName
            local cycleSpeech = Helpers.CreateSpeechData()
            cycleSpeech:Add("cycleValue", itemValue, "brief")
            Log.Info("VALUE CYCLE [" .. config.name .. "]: " .. itemValue)
            Ext.Tolk.Speak(cycleSpeech:Format(), true)
            return
        end

        -- Section-transition label: when focus moves from the carousel
        -- into the feature/sub-item list for the first time on this
        -- page visit, prepend "You acquire the following class
        -- features:" (or racial/subrace/subclass variant) so the
        -- player knows these are granted items, not selections.
        if not handlerState.sectionLabelSpoken
            and not isScreenEntry
            and focusedElement.dcType
            and IsFeatureOrSubItemDCType(focusedElement.dcType) then
            local currentPage = tabName or ccState.currentPage
            local sectionLabel =
                CC_SECTION_TRANSITION_LABELS[currentPage]
            if sectionLabel then
                handlerState.sectionLabelSpoken = true
                speechData:Add("sectionLabel", sectionLabel, "brief")
                Log.Info("SECTION LABEL [" .. config.name .. "]: "
                    .. sectionLabel)
            end
        end

        if itemName then
            handlerState.lastSpokenItemName = itemName
            handlerState.lastSpokenName = elemId
            handlerState.lastSpokenFullText = itemName
            Log.Info("ITEM [" .. config.name .. "]: "
                .. tostring(focusedElement.elemType)
                .. "  name=" .. itemName
                .. (itemValue and ("  val=" .. itemValue) or "")
                .. (itemDescription
                    and ("  desc="
                        .. tostring(itemDescription):sub(1, 40))
                    or ""))
        end
        speechData:Add("itemName", itemName, "brief")
        speechData:Add("itemValue", itemValue, "brief")
        speechData:Add("itemDesc", itemDescription, "verbose")

        if not itemName and not itemValue and not itemDescription then
            Log.Info("SILENT ELEMENT [" .. config.name .. "]: elemId="
                .. tostring(elemId) .. " elemType="
                .. tostring(focusedElement.elemType) .. " elemText="
                .. tostring(focusedElement.elemText) .. " dcType="
                .. tostring(focusedElement.dcType))
        end

        -- Suppress post-settle speech when the standalone carousel
        -- handler already spoke the same item with name + description.
        -- The standalone fires on the carousel-changed tick (no
        -- focus/selection), then the post-settle tick arrives with
        -- focusChanged + selectionChanged and re-extracts the same
        -- item.  Without this gate the user hears every carousel step
        -- twice.
        Log.Info("POST-SETTLE CHECK [" .. config.name .. "]: carousel='"
            .. tostring(standaloneCarouselJustSpoke)
            .. "' itemName='" .. tostring(itemName) .. "'")
        if standaloneCarouselJustSpoke and itemName
            and standaloneCarouselJustSpoke == itemName then
            Log.Info("SUPPRESS post-settle duplicate ["
                .. config.name .. "]: " .. itemName)
            return
        end

        -- Store for tooltip exact-match Diff.
        ccState.lastHandlerSpeechData = speechData
        speechData:Speak(ccState, isScreenEntry, nil, userInitiated)
    end

    local function ResetNavigation()
        handlerState.lastSpokenName = nil
        handlerState.lastSpokenFullText = nil
        handlerState.lastSpokenItemName = nil
        handlerState.screenEntryJustSpoke = false
        handlerState.sectionLabelSpoken = false
    end

    local function ResetState()
        ResetNavigation()
        handlerState.lastSpokenTitle = nil
        handlerState.lastCarouselTick = nil
        handlerState.tabHintsSpoken = {}
        handlerState.handlerExtras = {}
        if config.onReset then
            config.onReset(handlerState)
        end
    end

    return {
        name               = config.name,
        pages              = config.pages or {},
        HandlesPage        = HandlesPage,
        HandleSnapshot     = HandleSnapshot,
        ResetNavigation    = ResetNavigation,
        ResetState         = ResetState,
    }
end

-- ============================================================================
-- Per-page handler instances
-- ============================================================================

-- CarouselDescHandler: Race / Subrace / Class / Subclass / Background /
-- Deity / Feat / Origin.  All share the same pattern (carousel of items,
-- StaticData-backed descriptions).  GetCCItemData + GetGodObjectDescription
-- already do all the extraction work; no per-handler overrides needed.
-- Origin is included here because its body-type and identity sub-items
-- already route through ExtractOriginContext inside GetCCItemData.
local CarouselDescHandler = CreateCCPageHandler({
    name  = "CCCarouselDesc",
    pages = { "Race", "Subrace", "Class", "Subclass", "Background",
              "Deity", "Feat", "Origin" },
})

-- AbilitiesHandler: abilities grid with points-remaining + rules hint.
-- CC_TAB_HINTS["Abilities"] is nil on purpose -- screenBodyFn owns the
-- extra body text so rules hint and points count are one announcement.
local AbilitiesHandler = CreateCCPageHandler({
    name  = "CCAbilities",
    pages = { "Abilities" },
    screenBodyFn = function(focusedElement, tabName, handlerState,
                            snapshot)
        if not focusedElement.dcProps then return nil end
        local bodyParts = {}
        if not handlerState.handlerExtras.abilityRulesSpoken then
            handlerState.handlerExtras.abilityRulesSpoken = true
            table.insert(bodyParts,
                "Every 2 points above 10 gives plus 1 to related rolls")
        end
        local unusedPoints = focusedElement.dcProps.UnusedAbilityPoints
        if unusedPoints then
            table.insert(bodyParts,
                tostring(unusedPoints) .. " points remaining")
        end
        if #bodyParts == 0 then return nil end
        return table.concat(bodyParts, ". ")
    end,
})

-- SkillsHandler: LocaString-resolved hint ("Choose N skills").
local SkillsHandler = CreateCCPageHandler({
    name  = "CCSkills",
    pages = { "Skills" },
    hintFn = function(tabName)
        return GetPageInstructionText(tabName)
    end,
})

-- SpellSelectionHandler: Cantrip + Spell + High Elf Cantrip all share
-- the spell grid.  hintFn prioritizes CC_TAB_HINTS (hand-written
-- navigation guidance like "cantrips don't use spell slots") over the
-- LocaString instruction text ("Selected. Available") which is just
-- XAML header labels and not useful for orientation.
local SpellSelectionHandler = CreateCCPageHandler({
    name  = "CCSpellSelection",
    pages = { "Cantrip", "Spell", "High Elf Cantrip" },
    hintFn = function(tabName)
        return CC_TAB_HINTS[tabName] or GetPageInstructionText(tabName)
    end,
})

-- AppearanceHandler: sliders, inline carousels, toggles.  Body Type /
-- Identity / Voice rows also appear on Appearance; the shared
-- extractors (ExtractOriginContext inside GetCCItemData) already handle
-- them, so no customItemFn is needed.
local AppearanceHandler = CreateCCPageHandler({
    name  = "CCAppearance",
    pages = { "Appearance" },
})

-- AbilityBonusHandler: the "Ability Bonus" sub-page under Race / Class.
-- Kept as its own handler so "Bonus to Strength" naming and cycling
-- announcements have a dedicated tab-hint slot (nil in CC_TAB_HINTS
-- falls through to "no hint").  Inherits the default generic pipeline.
local AbilityBonusHandler = CreateCCPageHandler({
    name  = "CCAbilityBonus",
    pages = { "Ability Bonus" },
})

-- ============================================================================
-- Page handler routing
-- ============================================================================

local PAGE_HANDLERS = {
    ["Origin"]           = CarouselDescHandler,
    ["Race"]             = CarouselDescHandler,
    ["Subrace"]          = CarouselDescHandler,
    ["Class"]            = CarouselDescHandler,
    ["Subclass"]         = CarouselDescHandler,
    ["Background"]       = CarouselDescHandler,
    ["Deity"]            = CarouselDescHandler,
    ["Feat"]             = CarouselDescHandler,
    ["Abilities"]        = AbilitiesHandler,
    ["Ability Bonus"]    = AbilityBonusHandler,
    ["Skills"]           = SkillsHandler,
    ["Cantrip"]          = SpellSelectionHandler,
    ["Spell"]            = SpellSelectionHandler,
    ["High Elf Cantrip"] = SpellSelectionHandler,
    ["Appearance"]       = AppearanceHandler,
}

-- Fallback handler for unclassified pages (e.g. rapid transitions).
-- CarouselDescHandler's pipeline is page-agnostic.
local defaultPageHandler = CarouselDescHandler

local function ResolveHandlerForPage(pageName)
    if not pageName then return defaultPageHandler end
    return PAGE_HANDLERS[pageName] or defaultPageHandler
end

local function ResetAllPageHandlers()
    CarouselDescHandler.ResetState()
    AbilitiesHandler.ResetState()
    SkillsHandler.ResetState()
    SpellSelectionHandler.ResetState()
    AppearanceHandler.ResetState()
    AbilityBonusHandler.ResetState()
end

-- Wire the forward-declared hook so ResetCCState resets per-handler
-- state too.
resetHandlersHook = ResetAllPageHandlers

-- ============================================================================
-- HandleCCSnapshot (router)
-- ============================================================================
--
-- Responsibilities:
--   1. Transition lockouts (Naming / MainCC) and guardian teardown
--      suppression.
--   2. Interactive instruction gate (text input screens).
--   3. Track SelectedOrigin, isCustomOrigin, currentWidgetDCType.
--   4. Intro-awaiting gate: drop snapshots while LT is pending.
--   5. Classify the current page; switch active handler on page change.
--   6. First-entry speech (main CC intro / level up / guardian).
--   7. Dispatch to the active handler's HandleSnapshot.

local function HandleCCSnapshot(snapshot)
    local focusedElement = snapshot.focusedElement

    if ccState.suppressGuardianTeardown then
        Log.Debug("SUPPRESS: dropping guardian teardown snapshot")
        return
    end

    if ccState.pendingTransition then
        local hasRealDCType = focusedElement
            and focusedElement.dcType
            and focusedElement.dcType ~= "(none)"
            and focusedElement.dcType ~= ""
        -- Genuine navigation: focus or selection changed, not just a
        -- residual INPC value tick from the old page's god-object.
        local hasGenuineNav = snapshot.focusChanged
            or snapshot.selectionChanged
        if ccState.pendingTransition == "Naming" then
            -- The naming screen was spoken by the Y-button callback.
            -- Only clear the lockout when focus genuinely moves to a
            -- new element (the guardian page loading after user pressed
            -- A).  Residual value-only ticks from the old CC page
            -- fire with dcType=gui::DCCharacterCreation but no
            -- focus/selection change -- those must be dropped so the
            -- guardian speech doesn't fire prematurely.
            if hasRealDCType and hasGenuineNav then
                ccState.pendingTransition = nil
                ccState.lastSpokenTab = nil
                Log.Debug("LOCKOUT: cleared (real focused element arrived)")
            else
                return
            end
        elseif ccState.pendingTransition == "MainCC" then
            if hasRealDCType then
                ccState.pendingTransition = nil
                ccState.lastMainTab = nil
                ccState.lastSpokenTab = nil
                ccState.inPostNamingCC = false
                ccState.currentPage = nil
                ccState.activePageHandler = nil
                Log.Debug("LOCKOUT: arrived at MainCC (state reset)")
            else
                Log.Debug("LOCKOUT: dropping (waiting for MainCC)")
                return
            end
        end
    end

    -- Widget DC type caching + post-cutscene detection.
    -- Runs BEFORE the focusedElement guard so that:
    --   (a) Post-cutscene gate is armed on the same tick as the widget
    --       re-add (HandleCCSnapshot runs before EventRouter's widget
    --       event loop, which calls HandleWidgetAdded).
    --   (b) DEV-ONLY: on mid-session reload, currentWidgetDCType and
    --       inCharacterCreation are set even when focusedElement is nil
    --       (the C++ focus cache was wiped by the reset).  On a real
    --       first entry the widget and focus arrive on the same tick
    --       after the settle cycle, so this early path only matters for
    --       the dev reload scenario.
    if snapshot.widgetEvents then
        for _, widgetEvent in ipairs(snapshot.widgetEvents) do
            if widgetEvent.dcType == "gui::DCCharacterCreation"
                or widgetEvent.dcType == "gui::DCCharacterLevelUp" then
                ccState.currentWidgetDCType = widgetEvent.dcType
                -- NOTE: do NOT set inCharacterCreation here.  Setting
                -- it early causes HandleWidgetAdded (which runs AFTER
                -- HandleCCSnapshot on the same tick) to see
                -- inCharacterCreation=true and fire a blurb-return
                -- partial reset, wiping the introAwaitingContinue flag
                -- and LT listeners that the first-entry speech just
                -- armed.  currentWidgetDCType persists to the next
                -- tick; inCharacterCreation is set naturally at the
                -- guard below when focusedElement arrives.
                -- Arm post-cutscene gate: the CC widget re-appeared
                -- while we're already in CC (origin cutscene return).
                -- firstEntrySpoken distinguishes a genuine first entry
                -- (where we WANT the welcome) from a blurb return.
                if widgetEvent.dcType == "gui::DCCharacterCreation"
                    and ccState.firstEntrySpoken
                    and not ccState.awaitingPostCutsceneNav then
                    Log.Info("CC POST-CUTSCENE: arming gate"
                        .. " (CC widget re-added while in CC)")
                    ccState.awaitingPostCutsceneNav = true
                    ccState.postCutsceneHintSpoken = false
                    ccState.postCutsceneArmedAt =
                        Ext.Utils.MonotonicTime()
                end
                break
            end
        end
    end

    -- Post-cutscene return gate.  Suppresses all speech (carousels,
    -- focus events, handler dispatch) during the noise burst after
    -- an origin-preview cutscene ends.  Speaks a hint once, then
    -- silence until the user re-engages (focus/selection change
    -- arriving 1000ms+ after the gate was armed).
    if ccState.awaitingPostCutsceneNav then
        local elapsed = Ext.Utils.MonotonicTime()
            - ccState.postCutsceneArmedAt
        if elapsed >= 1000
            and (snapshot.focusChanged
                or snapshot.selectionChanged) then
            Log.Info("CC POST-CUTSCENE: user navigated after "
                .. tostring(elapsed) .. "ms, resuming")
            ccState.awaitingPostCutsceneNav = false
            ccState.postCutsceneHintSpoken = false
            ccState.postCutsceneArmedAt = 0
            -- Clear handler dedup so the element under focus speaks
            -- fresh (the user may land on the same origin character
            -- they were on before the cutscene).
            if ccState.activePageHandler then
                ccState.activePageHandler.ResetNavigation()
            end
            -- Fall through to normal processing below.
        else
            if not ccState.postCutsceneHintSpoken then
                ccState.postCutsceneHintSpoken = true
                local hintSpeech = Helpers.CreateSpeechData()
                hintSpeech:Add("hint",
                    "Press down twice to return to the character list",
                    "brief")
                local hintText = hintSpeech:Format()
                Log.Info("CC POST-CUTSCENE HINT: " .. hintText)
                Ext.Tolk.Speak(hintText, true)
            end
            return
        end
    end

    -- Standalone carousel events (inline appearance carousels) arrive
    -- from C++ ClassSelectionDelegate with no focus change.  The
    -- snapshot has carousel=1 + carVal but no focusedElement (or an
    -- empty elemType).  Handle BEFORE the focusedElement guard so
    -- they don't fall through EventRouter to Menus (which would
    -- speak the bare name, then the INPC follow-up speaks name+desc,
    -- causing double-reads).
    local hasStandaloneCarousel = snapshot.inlineCarouselChanged
        and snapshot.inlineCarouselValue
        and snapshot.inlineCarouselValue ~= ""
        and not snapshot.focusChanged
    if hasStandaloneCarousel
        and (not focusedElement
            or not focusedElement.elemType
            or focusedElement.elemType == "") then
        local carouselValue = snapshot.inlineCarouselValue
        if carouselValue ~= ccState.lastSpokenFullText then
            -- Look up description via StaticData API for the current
            -- page so the standalone carousel speaks name + description.
            local carouselDescription = nil
            local currentTab = ccState.lastMainTab
            if currentTab then
                local staticDataType = CC_TAB_STATIC_DATA_TYPE[currentTab]
                if staticDataType then
                    carouselDescription =
                        Helpers.LookupStaticDataDescription(
                            staticDataType, carouselValue)
                end
            end
            local carouselSpeech = Helpers.CreateSpeechData()
            carouselSpeech:Add("carouselValue", carouselValue, "brief")
            if carouselDescription and carouselDescription ~= "" then
                carouselSpeech:Add("carouselDesc",
                    carouselDescription, "normal")
            end
            local carouselFormatted = carouselSpeech:Format()
            ccState.lastSpokenFullText = carouselFormatted
            ccState.lastStandaloneCarouselValue = carouselValue
            Log.Info("CAROUSEL (standalone): " .. carouselFormatted)
            Ext.Tolk.Speak(carouselFormatted, true)
        end
        return
    end

    if not focusedElement then return end

    -- Interactive instruction screens (text input).  Speak the
    -- instruction once per focus arrival, suppress subsequent ticks.
    if focusedElement.elemName then
        local instruction = CC_INTERACTIVE_INSTRUCTIONS[
            focusedElement.elemName]
        if instruction then
            if ccState.activeInstruction ~= focusedElement.elemName then
                ccState.activeInstruction = focusedElement.elemName
                local instructionSpeech = Helpers.CreateSpeechData()
                instructionSpeech:Add("instruction", instruction, "brief")
                Log.Info("CC INSTRUCTION: " .. focusedElement.elemName)
                Ext.Tolk.Speak(instructionSpeech:Format(), true)
            end
            return
        else
            ccState.activeInstruction = nil
        end
    end

    if not ccState.inCharacterCreation then
        ccState.inCharacterCreation = true
        SubscribeCCYButton()
    end

    -- Track selected origin (used by naming screen character name).
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

    -- Guardian detection: first real CC element after naming screen.
    if not ccState.inPostNamingCC
        and ccState.lastMainTab == "Naming"
        and focusedElement.dcType
        and focusedElement.dcType ~= "(none)"
        and focusedElement.dcType ~= "" then
        ccState.inPostNamingCC = true
        Log.Debug("Guardian CC detected (post-naming)")
    end

    -- Intro-awaiting gate: welcome spoken, waiting on LT.  Drop all
    -- snapshots until the LT handler clears the flag.
    if ccState.introAwaitingContinue then
        return
    end

    -- =============================================================
    -- Classify current page.
    -- =============================================================
    local pageName = ClassifyPage(snapshot)

    -- Sync lastMainTab with the classifier's result so description
    -- lookups (GetGodObjectDescription) have the correct key across
    -- all paths that still consult it.
    if pageName and PAGE_HANDLERS[pageName] then
        ccState.lastMainTab = pageName
    end

    Log.Info("CC CLASSIFY: page=" .. tostring(pageName)
        .. " mainTab=" .. tostring(ccState.lastMainTab)
        .. " sel=" .. tostring(snapshot.selectionChanged)
        .. " foc=" .. tostring(snapshot.focusChanged))

    -- Handler switch: when the classified page changes to a KNOWN
    -- page, deactivate the old handler's navigation state and
    -- activate the new one.  A nil pageName (classifier had no
    -- strong signal) stays on the current page -- flipping to nil
    -- and back to the same page would re-fire screen entry and
    -- re-speak title/hint/tab/item, which the user observed as
    -- "the Custom desc repeated".
    local isFirstEntry = false
    if pageName and pageName ~= ccState.currentPage then
        if ccState.activePageHandler then
            ccState.activePageHandler.ResetNavigation()
        end
        ccState.currentPage = pageName
        ccState.activePageHandler = ResolveHandlerForPage(pageName)
        isFirstEntry = true
        ccState.lastSpokenTab = pageName
    end

    -- =============================================================
    -- First-entry speech (main CC intro / level up / guardian).
    -- Guardian entry is a distinct speech that fires AFTER the main CC
    -- intro has already played; namingScreenWasSpoken is the explicit
    -- signal for that transition and overrides firstEntrySpoken.
    -- Main CC / Level Up entries only fire if firstEntrySpoken is
    -- still false (they happen exactly once per CC session).
    -- =============================================================
    if namingScreenWasSpoken or not ccState.firstEntrySpoken then
        local firstEntrySpeech = nil
        if namingScreenWasSpoken then
            firstEntrySpeech = SpeakGuardianEntry()
            namingScreenWasSpoken = false
        elseif ccState.currentWidgetDCType == "gui::DCCharacterLevelUp" then
            firstEntrySpeech = SpeakLevelUpEntry(focusedElement)
        elseif ccState.currentWidgetDCType == "gui::DCCharacterCreation" then
            firstEntrySpeech = SpeakMainCCEntry(focusedElement)
        end
        if firstEntrySpeech then
            ccState.firstEntrySpoken = true
            ccState.lastMainTab = pageName or ccState.lastMainTab
            -- Anchor currentPage so the NEXT tick's classifier result
            -- (which may finally resolve to "Origin" once the VM
            -- type on selected is visible) doesn't read as a fresh
            -- page change and re-fire the handler's screen-entry
            -- speech right after the welcome.  Default to "Origin"
            -- for main CC entry if the classifier couldn't identify
            -- the page yet -- the first visible page of every main
            -- CC session is Origin.
            if not ccState.currentPage then
                ccState.currentPage = pageName or "Origin"
                ccState.activePageHandler = ResolveHandlerForPage(
                    ccState.currentPage)
                ccState.lastSpokenTab = ccState.currentPage
            end
            local speech = firstEntrySpeech:Format()
            Log.Info("CC FIRST ENTRY SPEECH: " .. speech)
            Ext.Tolk.Speak(speech, true)
            ccState.lastSpokenFullText = speech
            -- Suppress handler dispatch on first-entry tick so the
            -- welcome / level-up / guardian speech is not interrupted.
            -- When the intro-split listener is armed, subsequent ticks
            -- remain suppressed until LT clears introAwaitingContinue.
            return
        end
    end

    -- =============================================================
    -- Dispatch to the active handler.
    -- =============================================================
    if ccState.activePageHandler then
        ccState.activePageHandler.HandleSnapshot(
            snapshot, pageName, isFirstEntry)
    end
end

-- ============================================================================
-- State query and widget-added (exported for the Manager)
-- ============================================================================

--- IsInCC: returns true if currently in character creation.
--- Called by the Manager for cutscene-to-CC return detection.
local function IsInCC()
    return ccState.inCharacterCreation
end

--- ProcessTooltip: thin wrapper around Helpers.ProcessTooltip.  CC
--- routes here (via EventRouter) instead of WorldUI.ProcessTooltip
--- because CC tooltips need full-detail text (skill / feature / passive
--- descriptions).  The only CC-specific concern is the "not in CC"
--- early exit; all dedup, diff, subset/superset, and speech is handled
--- Two-event pattern: handler speaks immediately (name + value +
--- API description), tooltip follows when ready with supplementary
--- detail.  Exact-match Diff strips fields the handler already
--- spoke (typically just the item name).  No buffering, no latency.
--- @param snapshot table  The full TickSnapshot from C++.
local function ProcessTooltip(snapshot)
    if not ccState.inCharacterCreation then return end
    Helpers.ProcessTooltip(snapshot, {
        stateHolder = ccState,
        defaultMinimal = false,
        getHandlerSpeechData = function()
            return ccState.lastHandlerSpeechData
        end,
        logPrefix = "CC TOOLTIP",
    })
end

--- MarkMidSessionReload: called by EventRouter at startup when it
--- detects a Lua reload that happened while character creation was
--- already open (CCState component present in entities).  Pre-arms
--- ccState to skip the intro welcome and LT-await gate so the
--- returning user can navigate normally instead of getting stuck
--- waiting for an LT press they already made.
local function MarkMidSessionReload()
    ccState.firstEntrySpoken = true
    ccState.introAwaitingContinue = false
    -- Assume we're on the Origin page by default so the classifier
    -- and standalone carousel have a valid tab context until the
    -- user navigates and the classifier re-syncs.  Also assign the
    -- active handler: without this, the first several post-reload
    -- snapshots (where the classifier returns nil from god-object-
    -- only elements) would fail the "if ccState.activePageHandler"
    -- dispatch check and silently no-op -- which the user observes
    -- as "can't d-pad on origin, nothing speaks."
    if not ccState.lastMainTab then
        ccState.lastMainTab = "Origin"
    end
    if not ccState.currentPage then
        ccState.currentPage = "Origin"
        ccState.activePageHandler = ResolveHandlerForPage("Origin")
    end
    -- Force the C++ monitor to re-evaluate focus on the next tick so
    -- its cached sLastFocusedElement pointer (which survives Lua
    -- reset but may now point at a stale Noesis element after the
    -- CC widget rebuilt during reset) is refreshed.  Without this,
    -- the ClassSelectionDelegate's "focused element is descendant of
    -- source ListBox" gate fails on the next carousel event and
    -- suppresses the carousel capture -- user observes this as
    -- "d-pad on race carousel does nothing after reset."
    pcall(Ext.UI.ForceGlobalFocusUpdate)
end

--- HandleWidgetAdded: called by the Manager for every widgetAdded
--- event.  CC owns the policy for what to do when its widget reappears
--- after a dialog, cutscene, or origin-preview blurb.
---
--- Blurb-return reset preserves firstEntrySpoken so the LT intro is
--- not replayed.  Guardian / level-up entries use their own detection
--- paths (namingScreenWasSpoken / currentWidgetDCType) and are not
--- affected by this reset.
local function HandleWidgetAdded(widgetData)
    if not widgetData or not widgetData.dcType then return end
    if not ccState.inCharacterCreation then return end
    if widgetData.dcType ~= "gui::DCCharacterCreation" then return end
    -- Don't reset when the intro LT gate is armed.  HandleCCSnapshot
    -- runs before HandleWidgetAdded on the same tick; if the first-
    -- entry speech just armed introAwaitingContinue, a blurb-return
    -- reset here would wipe the flag and unsubscribe the LT listeners.
    if ccState.introAwaitingContinue then return end
    Log.Info("CC: DCCharacterCreation re-added while in CC"
        .. " -- resetting for fresh entry (blurb return)")
    -- Preserve session-continuity flags across the blurb-return reset.
    -- firstEntrySpoken keeps the intro welcome from re-firing.
    -- customBackstoryText keeps the Custom backstory cached for LT.
    -- currentPage + activePageHandler + lastMainTab keep the page
    -- handler wired up so the next snapshot dispatches correctly
    -- (without these, activePageHandler becomes nil and every
    -- subsequent snapshot silently no-ops at the dispatch line).
    local keepFirstEntry = ccState.firstEntrySpoken
    local keepBackstory = ccState.customBackstoryText
    local keepCurrentPage = ccState.currentPage
    local keepActiveHandler = ccState.activePageHandler
    local keepLastMainTab = ccState.lastMainTab
    ResetCCState()
    ccState.firstEntrySpoken = keepFirstEntry
    ccState.customBackstoryText = keepBackstory
    ccState.currentPage = keepCurrentPage
    ccState.activePageHandler = keepActiveHandler
    ccState.lastMainTab = keepLastMainTab
    -- Post-cutscene gate arming is handled in HandleCCSnapshot
    -- (widget event detection), not here.  HandleCCSnapshot runs
    -- BEFORE HandleWidgetAdded in EventRouter's dispatch order,
    -- so the gate must be armed there to suppress the first tick.
end

-- ============================================================================
-- Exports
-- ============================================================================

BG3Access.Client.CC = {
    IsCCSnapshot         = IsCCSnapshot,
    HandleCCSnapshot     = HandleCCSnapshot,
    HandleWidgetAdded    = HandleWidgetAdded,
    ProcessTooltip       = ProcessTooltip,
    MarkMidSessionReload = MarkMidSessionReload,
    GetSectionLabel      = GetSectionLabel,
    GetBodyTypeName      = GetBodyTypeName,
    CC_SECTION_LABELS    = CC_SECTION_LABELS,
    SubscribeCCYButton   = SubscribeCCYButton,
    UnsubscribeCCYButton = UnsubscribeCCYButton,
    IsInCC               = IsInCC,
    ResetCCNavigation    = ResetCCNavigation,
    ResetCCState         = ResetCCState,
}
