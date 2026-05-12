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
local SpeechData = BG3Access.Client.SpeechData


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
    ["ls.VMSpellReference"]          = true,
    ["ls.VMSkill"]                   = true,
    ["ls.VMAbility"]                 = true,
    ["ls.VMCharacterCreationSkill"]  = true,
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

-- Detail view formatting: shared module (Client/DetailView.lua).
local DetailRoleLabel = BG3Access.Client.DetailView.RoleLabel
local NormalizeDetailText = BG3Access.Client.DetailView.NormalizeText

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
    ["Spell"] = nil,  -- handled by SpellSelectionHandler.hintFn
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
-- Page name whitelist.  Values are the canonical page name used by
-- PAGE_HANDLERS.  Tab header text may differ from canonical names
-- (e.g. "Cantrips" plural, "Spellbook", "Skill Expertise").
local CC_PAGE_NAMES = {
    ["Origin"]           = "Origin",
    ["Race"]             = "Race",
    ["Subrace"]          = "Subrace",
    ["Class"]            = "Class",
    ["Subclass"]         = "Subclass",
    ["Background"]       = "Background",
    ["Deity"]            = "Deity",
    ["Feat"]             = "Feat",
    ["Abilities"]        = "Abilities",
    ["Ability Bonus"]    = "Ability Bonus",
    ["Skills"]           = "Skills",
    ["Skill Expertise"]  = "Skill Expertise",
    ["Cantrip"]          = "Cantrip",
    ["Cantrips"]         = "Cantrip",
    ["Spell"]            = "Spell",
    ["Spellbook"]        = "Spell",
    ["High Elf Cantrip"] = "High Elf Cantrip",
    ["Skill Proficiency"] = "Skills",
    ["Skill Expertise"]  = "Skill Expertise",
    ["Appearance"]       = "Appearance",
}

-- Maps XAML Tag values from the gameplayTabs ListBox items to canonical
-- page names.  Used as last-resort classification when the focused
-- element is a sub-item and no tab name is available in the snapshot.
-- Tag values come from CharacterCreation_c.xaml ListBoxItem Tags.
-- Forward declaration: populated after handler instances are created.
-- Used by ClassifyPage to compare handlers for sibling page detection.
local PAGE_HANDLERS = nil

local CC_TAB_TAG_PAGES = {
    ["origin"]     = "Origin",
    ["race"]       = "Race",
    ["subrace"]    = "Subrace",
    ["class"]      = "Class",
    ["subclass"]   = "Subclass",
    ["deity"]      = "Deity",
    ["spellprep"]  = "Spell",
    ["background"] = "Background",
    ["ability"]    = "Abilities",
    ["raceskills"] = "Cantrip",
    ["skills"]     = "Skills",
    ["expertise"]  = "Skill Expertise",
    ["appearance"] = "Appearance",
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
    currentTabContext            = nil,
    lastSpokenTitle          = nil,
    lastSpokenItemName       = nil,
    lastMainTab              = nil,
    -- Router-level flags retained for first-entry and transition logic.
    screenEntryJustSpoke     = false,
    inCharacterCreation      = false,
    inPostNamingCC           = false,
    pendingTransition        = nil,
    lastFocusedDCType        = nil,
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
    -- CC tooltip dedup is now value-aware via spokenRoles cross-off
    -- in FromTooltip (see SpeechData.lua ShouldSkipSpoken).  No
    -- separate string-compare field needed.
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
    -- Per-handler customItemFn runs API lookups (StaticData,
    -- Feature/Passive, Spell) which resolve parameter placeholders
    -- like [2] into real values.  Raw dcProps.Description is the
    -- LAST RESORT fallback, used only when all API lookups fail
    -- (modded content with no stat entry).
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
        -- Return description separately (per-handler API-first
        -- enrichment may override with a StaticData lookup, but
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
-- Level-up summary extraction (factory infrastructure)
-- ============================================================================

-- Extract concatenated TextBlock texts from a DCCharacterLevelUp focused
-- element.  Used by the factory before per-handler customItemFn dispatch.
local function ExtractLevelUpSummary(focusedElement)
    if not focusedElement
        or focusedElement.dcType ~= "gui::DCCharacterLevelUp" then
        return nil
    end
    local readOk, textBlocks = pcall(Ext.UI.ReadFocusedTextBlocks)
    if not readOk or not textBlocks or #textBlocks == 0 then
        return nil
    end
    local parts = {}
    for _, text in ipairs(textBlocks) do
        if text and text ~= "" then
            local cleaned = Helpers.StripMarkupTags(text)
            if cleaned and cleaned ~= "" then
                parts[#parts + 1] = cleaned
            end
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

-- GetCCItemData and FormatCCValue deleted -- extraction logic is now
-- in per-handler customItemFn functions.

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

    ccState.currentTabContext = "Naming"
    ccState.lastMainTab = "Naming"
    namingScreenWasSpoken = true

    local speechData = SpeechData.Create()
    speechData:Add("title", "Enter Character Name")
    speechData:Add("name", characterName, "brief")
    speechData:Add("instructionHint",
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
    local speechData = SpeechData.Create()
    speechData:Add("sectionLabel", "Create a custom character.", "brief")
    speechData:Add("description", "Backstory: " .. backstory, "verbose")
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
    local speechData = SpeechData.Create()
    speechData:Add("title", "Guardian Appearance", "brief")
    speechData:Add("navigationHint",
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
    local speechData = SpeechData.Create()
    speechData:Add("title", levelUpTitle, "brief")
    speechData:Add("navigationHint",
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

    local speechData = SpeechData.Create()
    -- Title omitted: the welcome text opens with "Welcome to
    -- character creation" which establishes context without
    -- a redundant "Character Creation" prefix.
    speechData:Add("navigationHint", CC_INTRO_WELCOME, "verbose")
    Log.Info("CC FIRST ENTRY: main, intro-await LT")
    return speechData
end

-- ============================================================================
-- Active tab tag (migrated from C++ ReadActiveTabTag_SEH)
-- ============================================================================
--
-- Reads gameplayTabs.SelectedIndex via QueryNamedElement and maps to a
-- tag name using the static tab order from CharacterCreation_c.xaml.
-- Replaces the C++ ReadActiveTabTag_SEH / snapshot.activeTabTag field.

-- Static tab order from CharacterCreation_c.xaml ListBoxItem order.
-- Index 0 = "origin", index 12 = "appearance".  Must match the XAML.
local CC_TAB_TAG_ORDER = {
    [0]  = "origin",
    [1]  = "race",
    [2]  = "subrace",
    [3]  = "class",
    [4]  = "subclass",
    [5]  = "deity",
    [6]  = "spellprep",
    [7]  = "background",
    [8]  = "ability",
    [9]  = "raceskills",
    [10] = "skills",
    [11] = "expertise",
    [12] = "appearance",
}

--- ReadActiveTabTag: query gameplayTabs.SelectedIndex and return the
--- corresponding tag string (e.g. "race", "skills"), or nil on failure.
local function ReadActiveTabTag()
    local queryOk, tabsInfo = pcall(
        Ext.UI.QueryNamedElement, "gameplayTabs",
        { "SelectedIndex" })
    if not queryOk or not tabsInfo then return nil end
    local indexStr = tabsInfo.SelectedIndex
    if not indexStr or indexStr == "" then return nil end
    local index = tonumber(indexStr)
    if not index or index < 0 then return nil end
    return CC_TAB_TAG_ORDER[index]
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

    if not focusedElement then
        return ccState.currentPage
    end

    local focusedSectionLabel = GetSectionLabel(focusedElement)
    local selectedSectionLabel = nil
    if snapshot.selectedElement then
        selectedSectionLabel = GetSectionLabel(snapshot.selectedElement)
    end

    -- Read active tab tag from gameplayTabs (Lua-side, replaces C++
    -- ReadActiveTabTag_SEH).  Computed once, used by sub-item
    -- disambiguation and fallback classification below.
    local activeTabTag = ReadActiveTabTag()

    -- VM types are the most reliable signal -- BUT the tab name may
    -- provide a more specific page when multiple pages share the same
    -- VM type (e.g. Skills and Skill Expertise both use
    -- VMCharacterCreationSkill).  Check tab name first for overrides.
    -- Sub-item VM types (VMSpellReference, VMSkill, etc.) appear on
    -- multiple pages.  When the SELECTED element is a sub-item, don't
    -- trust its section label as a page classifier -- fall through to
    -- tab name checks which are page-specific.
    if selectedSectionLabel
        and not ccState.pendingPageRecheck then
        if snapshot.selectedElement
            and not CC_SUBITEM_DC_TYPES[
                snapshot.selectedElement.dcType] then
            return selectedSectionLabel
        end
        -- Selected element is a sub-item: fall through to tab name
        -- and gameplayTabs last-resort checks.
    end
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
            -- Sub-item focused.  Two cases:
            --   A) selectionChanged: RB/LB tab switch, use
            --      selectedElement.tabName for specific page.
            --   B) focusChanged only: d-pad within page OR RB
            --      without selectionChanged.  Query gameplaySubPanel
            --      DC type to distinguish (VMSpellSelector = page
            --      switch, anything else = same page).
            -- No multi-tick state machine.  Direct query, same tick.

            -- Try selectedElement.tabName first (RB/LB case).
            if snapshot.selectedElement
                and snapshot.selectedElement.tabName
                and snapshot.selectedElement.tabName ~= ""
                and not snapshot.selectedElement.tabName
                    :find("^ListBoxItem:")
                and not IsBodyTypeTabName(
                    snapshot.selectedElement.tabName) then
                local selectedTabPage = CC_PAGE_NAMES[
                    snapshot.selectedElement.tabName]
                if selectedTabPage then
                    return selectedTabPage
                end
            end

            -- Query gameplaySubPanel DC to detect spell sub-panels.
            -- On RB to cantrips, the sub-panel DC is VMSpellSelector.
            -- On d-pad down within Subrace, the sub-panel DC is the
            -- race progression data (NOT VMSpellSelector).
            if snapshot.focusChanged then
                local subPanelOk, subPanelInfo = pcall(
                    Ext.UI.QueryNamedElement, "gameplaySubPanel")
                if subPanelOk and subPanelInfo
                    and subPanelInfo.dcType
                    and subPanelInfo.dcType:find("VMSpellSelector")
                then
                    -- Try PanelHeader for specific title.
                    local panelOk, panelInfo = pcall(
                        Ext.UI.QueryNamedElement, "PanelHeader")
                    if panelOk and panelInfo
                        and panelInfo.elemText
                        and panelInfo.elemText ~= "" then
                        local panelPage =
                            CC_PAGE_NAMES[panelInfo.elemText]
                        if panelPage then
                            return panelPage
                        end
                    end
                    -- Distinguish cantrip vs spell by level.
                    if focusedElement.dcProps
                        and type(focusedElement.dcProps.Spell) == "table"
                        then
                        local spellLevel =
                            focusedElement.dcProps.Spell.Level
                        if spellLevel == 0 or spellLevel == "0" then
                            return "Cantrip"
                        end
                    end
                    return "Spell"
                end
            end

            -- activeTabTag for sibling disambiguation (Skills vs
            -- Skill Expertise share VMCharacterCreationSkill).
            if snapshot.selectionChanged and activeTabTag then
                local tagPage = CC_TAB_TAG_PAGES[activeTabTag]
                if tagPage and PAGE_HANDLERS then
                    local tagHandler = PAGE_HANDLERS[tagPage]
                    local currentHandler =
                        PAGE_HANDLERS[focusedSectionLabel]
                    if tagHandler and currentHandler
                        and tagHandler == currentHandler then
                        return tagPage
                    end
                end
            end

            if snapshot.selectionChanged then
                return focusedSectionLabel
            end
            -- Fall through to keep current page (d-pad within page).
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
            local canonicalPage = CC_PAGE_NAMES[selectedTabName]
            if canonicalPage then
                return canonicalPage
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
            local canonicalFocused = CC_PAGE_NAMES[focusedTabName]
            if canonicalFocused then
                return canonicalFocused
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

    -- C++ reads the visible page title from gameplaySubPanel
    -- (first large-font TextBlock).  The page title is the
    -- definitive signal -- it matches what the sighted user sees
    -- ("High Elf Cantrip", "Skill Proficiency", etc.) and works
    -- for both static tabs and dynamic sub-panels.
    if snapshot.activePageTitle
        and snapshot.activePageTitle ~= "" then
        local titlePage =
            CC_PAGE_NAMES[snapshot.activePageTitle]
        if titlePage and titlePage ~= ccState.currentPage then
            Log.Info("CC CLASSIFY: pageTitle="
                .. snapshot.activePageTitle .. " -> " .. titlePage)
            return titlePage
        end
    end

    -- Fallback: tab index from gameplayTabs.SelectedIndex.
    -- ONLY used for the very first CC entry (empty focus, no
    -- currentPage yet).  The tab index is unreliable as a general
    -- fallback because the XAML sets SelectedIndex to -1 when
    -- sub-tabs (cantrips, spellbook) are active, and the index
    -- can be stale during page transitions.
    if activeTabTag and not ccState.currentPage then
        local tabTagPage = CC_TAB_TAG_PAGES[activeTabTag]
        if tabTagPage then
            Log.Info("CC CLASSIFY: initial activeTabTag="
                .. activeTabTag .. " -> " .. tabTagPage)
            return tabTagPage
        end
    end

    -- Stay on the current page if nothing re-classifies.
    return ccState.currentPage
end

-- ============================================================================
-- ResetCCNavigation / ResetCCState
-- ============================================================================

--- ResetCCNavigation: clear CC navigation dedup state only.
local function ResetCCNavigation()
    ccState.currentTabContext = nil
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
    ccState.currentTabContext = nil
    ccState.lastSpokenTitle = nil
    ccState.lastSpokenItemName = nil
    ccState.lastMainTab = nil
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
--                                 Each handler MUST provide customItemFn
--                                 (no shared fallback extractor)
--   buildDetailList (function)  -- (focusedData, tooltipTexts) ->
--                                 array of {label, value} for RS Left
--   onReset (function)         -- (handlerState)
--
-- Returns: { name, pages, HandlesPage, HandleSnapshot, ResetNavigation,
--            ResetState, GetLastFocusedData, BuildDetailList }

local function CreateCCPageHandler(config)
    local handlerState = {
        lastSpokenName       = nil,    -- last elemId spoken (legacy)
        lastSpokenItemName   = nil,    -- last item name spoken
        lastSpokenElemAddr   = nil,    -- stable element pointer (cycling detection)
        lastSpokenTitle      = nil,
        lastCarouselTick     = nil,
        spokenRoles          = {},     -- map of field key -> spoken value (for value-aware tooltip cross-off)
        tabHintsSpoken       = {},     -- keyed by tab name
        screenEntryJustSpoke = false,
        -- True after the "You acquire the following..." section label
        -- has been spoken for this page visit.  Reset on page switch
        -- (ResetNavigation) so it re-speaks on return.
        sectionLabelSpoken   = false,
        -- Free-form slot for screenBodyFn / customItemFn / onReset to
        -- stash per-handler data (abilityRulesSpoken, etc.).
        handlerExtras        = {},
        -- Cached focused element data for detail view (RS Left).
        lastFocusedData      = nil,
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

    -- Record which roles were spoken (for tooltip cross-off).
    -- The tooltip handler skips any role that's already set here.
    -- Records role keys into spokenRoles for value-aware tooltip
    -- cross-off (per ShouldSkipSpoken in SpeechData.lua).
    --   Core fields: stored value enables value-comparison cross-
    --     off (state changes emit, identical values skip).
    --   Properties: key encodes value so multi-instance labels each
    --     have their own slot; stored value `true` = presence skip.
    local function RecordSpokenRoles(speechData)
        handlerState.spokenRoles = {}
        for fieldName, fieldValue in pairs(speechData.coreFields) do
            handlerState.spokenRoles[fieldName] = fieldValue
        end
        for _, prop in ipairs(speechData.properties) do
            handlerState.spokenRoles[
                "property:" .. prop.label .. ":" .. prop.value] = true
        end
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
            Log.Debug("HANDLER SKIP [" .. config.name
                .. "]: no focusedElement or elemType, elemId="
                .. tostring(focusedElement and focusedElement.elemId))
            return
        end

        local userInitiated = snapshot.focusChanged
            or snapshot.selectionChanged
            or snapshot.inlineCarouselChanged
            or snapshot.valueChanged

        -- Cache for detail view (RS Left).
        handlerState.lastFocusedData = focusedElement

        -- Capture the standalone carousel value BEFORE clearing so we
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
        local isValueOnly = not isScreenEntry and not isItemNav
            and snapshot.valueChanged

        if not isScreenEntry and not isItemNav
            and not isValueOnly then
            return
        end

        -- =============================================================
        -- Value-only INPC change.  User changed a value (slider,
        -- toggle) without moving focus.  Speak the new value.
        -- Name already spoken on focus arrival -- only include it
        -- if it actually changed (e.g. ability bonus reassignment).
        -- =============================================================
        if isValueOnly then
            -- Level-up summary items don't have INPC value changes.
            if focusedElement.dcType == "gui::DCCharacterLevelUp" then
                return
            end
            local itemName, itemValue, itemDescription
            if config.customItemFn then
                itemName, itemValue, itemDescription =
                    config.customItemFn(focusedElement, snapshot,
                        tabName, handlerState)
            end

            local valueSpeech = SpeechData.Create()
            if focusedElement.dcType == "gui::VMSliderSetting"
                and itemValue and itemValue ~= "" then
                -- Sliders: speak only the number.
                valueSpeech:Add("value", itemValue, "brief")
            else
                -- Include name only if it changed (e.g. ability bonus
                -- reassignment changes the ability name).
                if itemName and itemName ~= ""
                    and itemName ~= handlerState.lastSpokenItemName then
                    valueSpeech:Add("name",
                        Helpers.StripMarkupTags(
                            itemName:gsub("%s+$", "")), "brief")
                    handlerState.lastSpokenItemName = itemName
                end
                if itemValue and itemValue ~= "" then
                    valueSpeech:Add("value",
                        Helpers.StripMarkupTags(
                            itemValue:gsub("%s+$", "")), "brief")
                end
                if itemDescription and itemDescription ~= "" then
                    valueSpeech:Add("description",
                        Helpers.StripMarkupTags(
                            itemDescription:gsub("%s+$", "")),
                        "verbose")
                end
            end
            local fullText = valueSpeech:Format()
            if fullText and fullText ~= "" then
                Log.Info("VALUE [" .. config.name .. "]: " .. fullText)
                Ext.Tolk.Speak(fullText, true)
            end
            return
        end

        -- =============================================================
        -- Screen entry or item navigation.
        -- =============================================================
        local speechData = SpeechData.Create()
        local screenTitle = nil

        if isScreenEntry then
            -- "Character Creation" title is redundant after the
            -- welcome speech ("Welcome to character creation").
            -- Only show it on the very first page if the welcome
            -- hasn't played yet (e.g. mid-session reload).
            if not ccState.firstEntrySpoken then
                local effectiveDCType = ccState.currentWidgetDCType
                    or focusedElement.dcType
                if effectiveDCType == "gui::DCCharacterCreation" then
                    screenTitle = "Character Creation"
                end
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
                    speechData:Add("navigationHint", tabHint, "normal")
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
                    speechData:Add("sectionLabel", tabName, "brief")
                end
            end

            if config.screenBodyFn then
                local extraBody = config.screenBodyFn(
                    focusedElement, tabName, handlerState, snapshot)
                if extraBody and extraBody ~= "" then
                    speechData:Add("description", extraBody, "normal")
                end
            end
        end

        -- =============================================================
        -- Item extraction (shared by screen entry and item nav).
        -- =============================================================
        local effectiveTabForExtraction = tabName or ccState.currentTabContext
        local itemName, itemValue, itemDescription

        -- Level-up summary items: factory infrastructure.
        if focusedElement.dcType == "gui::DCCharacterLevelUp" then
            itemName = ExtractLevelUpSummary(focusedElement)
        elseif config.customItemFn then
            itemName, itemValue, itemDescription = config.customItemFn(
                focusedElement, snapshot,
                effectiveTabForExtraction, handlerState)
        end

        -- Final placeholder check on extracted name.
        if itemName and IsPlaceholder(itemName) then
            Log.Info("Factory: suppress placeholder name: " .. itemName)
            itemName = nil
            itemValue = nil
            itemDescription = nil
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

        -- Same-element re-arrival dedup: if focus re-fires on the
        -- exact same element with no value/selection/carousel change,
        -- skip.  Uses elemAddr (stable pointer) not elemId (includes
        -- text which changes during cycling).
        local elemAddr = focusedElement.elemAddr or ""
        if isItemNav and elemAddr ~= ""
            and elemAddr == handlerState.lastSpokenElemAddr
            and not hasCarousel
            and not snapshot.valueChanged
            and not snapshot.selectionChanged then
            Log.Debug("DEDUP SKIP [" .. config.name .. "]: "
                .. tostring(elemId))
            return
        end

        -- Section header / tab-restate suppression.
        if itemName then
            local effectiveTab = tabName or ccState.currentTabContext
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
                handlerState.lastSpokenItemName = nil
            end
        end


        -- Value cycling: same element pointer, text changed.
        -- Name was already spoken on focus arrival -- just speak the
        -- new value.  Uses elemAddr for stable identity instead of
        -- comparing itemName strings.
        if elemAddr ~= ""
            and elemAddr == handlerState.lastSpokenElemAddr
            and not isScreenEntry then
            -- Same element, new data.  Speak only what changed.
            local cycleSpeech = SpeechData.Create()
            if itemValue and itemValue ~= "" then
                cycleSpeech:Add("value", itemValue, "brief")
            elseif itemName and itemName ~= ""
                and itemName ~= handlerState.lastSpokenItemName then
                -- No structured value but name changed (e.g. Identity
                -- cycling where ExtractOriginContext returned raw text).
                cycleSpeech:Add("value", itemName, "brief")
            end
            local cycleText = cycleSpeech:Format()
            if cycleText and cycleText ~= "" then
                handlerState.lastSpokenName = elemId
                handlerState.lastSpokenElemAddr = elemAddr
                Log.Info("VALUE CYCLE [" .. config.name .. "]: "
                    .. cycleText)
                Ext.Tolk.Speak(cycleText, true)
                return
            end
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
            ccState.lastSpokenItemName = itemName
            Log.Info("ITEM [" .. config.name .. "]: "
                .. tostring(focusedElement.elemType)
                .. "  name=" .. itemName
                .. (itemValue and ("  val=" .. itemValue) or "")
                .. (itemDescription
                    and ("  desc="
                        .. tostring(itemDescription):sub(1, 40))
                    or ""))
        end
        speechData:Add("name", itemName, "brief")
        speechData:Add("value", itemValue, "brief")
        speechData:Add("description", itemDescription, "verbose")

        -- Always update element tracking after any speech attempt
        -- (including description-only).  Without this, returning
        -- to a previously-visited element after a description-only
        -- element (like Custom backstory) falsely dedup-skips.
        handlerState.lastSpokenName = elemId
        handlerState.lastSpokenElemAddr = elemAddr

        if not itemName and not itemValue and not itemDescription then
            Log.Info("SILENT ELEMENT [" .. config.name .. "]: elemId="
                .. tostring(elemId) .. " elemType="
                .. tostring(focusedElement.elemType) .. " elemText="
                .. tostring(focusedElement.elemText) .. " dcType="
                .. tostring(focusedElement.dcType))
        end

        -- Suppress post-settle speech when the standalone carousel
        -- handler already spoke the same item with name + description.

        -- Record which fields/values we spoke (for tooltip cross-off
        -- and carousel dedup).
        RecordSpokenRoles(speechData)
        speechData:Speak(ccState, isScreenEntry, nil, userInitiated)
    end

    local function ResetNavigation()
        handlerState.lastSpokenName = nil
        handlerState.lastSpokenItemName = nil
        handlerState.lastSpokenElemAddr = nil
        handlerState.screenEntryJustSpoke = false
        handlerState.sectionLabelSpoken = false
    end

    local function ResetState()
        ResetNavigation()
        handlerState.lastSpokenTitle = nil
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
        GetLastFocusedData = function()
            return handlerState.lastFocusedData
        end,
        BuildDetailList    = config.buildDetailList,
        --- HandleTooltip: receive structured tooltip data ({role, text}
        --- array).  Build SpeechData from roles the item handler
        --- DIDN'T already speak.  Role-based cross-off: if the item
        --- handler spoke the "name" role, tooltip skips Title entries.
        HandleTooltip = function(structuredData, rawTexts)
            if not structuredData then return end
            local spoken = handlerState.spokenRoles or {}

            -- Base mapping via shared FromTooltip (handles common
            -- named roles, junk filtering, cross-off).
            local tooltipData = SpeechData.FromTooltip(
                structuredData, spoken)

            -- Post-process: PropertyText typeId overrides.
            -- FromTooltip maps PropertyText to generic "Property".
            -- CC tooltip templates use typeId for specific labels.
            -- Clean entryText via the same pipeline FromTooltip used
            -- on prop.value so the match comparison works.
            for _, tooltipEntry in ipairs(structuredData) do
                local role = tooltipEntry.role or ""
                if role == "PropertyText" and tooltipEntry.typeId then
                    local typeId = tooltipEntry.typeId
                    local entryText = SpeechData.CleanTooltipText(
                        tooltipEntry.text)
                    if entryText then
                        for _, prop in ipairs(tooltipData.properties) do
                            if prop.label == "Property"
                                and prop.value == entryText then
                                if typeId == "Concentration" then
                                    prop.label = "Concentration"
                                    prop.value =
                                        "Requires concentration"
                                elseif typeId == "Range" then
                                    prop.label = "Range"
                                    prop.value = NormalizeDetailText(
                                        entryText, "PropertyText")
                                elseif typeId == "ZoneRadius"
                                    or typeId == "Radius" then
                                    prop.label = "AoE radius"
                                    prop.value = NormalizeDetailText(
                                        entryText, "PropertyText")
                                elseif typeId == "CastAbility" then
                                    prop.label = "Casting"
                                    local abilityFull =
                                        Helpers.ExpandAbilityAbbreviation(
                                            entryText)
                                    if abilityFull then
                                        prop.value = abilityFull
                                    end
                                elseif typeId == "SaveAbility" then
                                    prop.label = "Save"
                                    prop.value = NormalizeDetailText(
                                        entryText, "PropertyText")
                                else
                                    prop.label = typeId
                                end
                                break
                            end
                        end
                    end
                end
            end

            -- Post-process: "Name" role conditional relabeling.
            -- FromTooltip falls through to AddProperty("Name", text)
            -- for unrecognized roles.  CC uses content to pick labels.
            for _, prop in ipairs(tooltipData.properties) do
                if prop.label == "Name" then
                    if prop.value:find("Spell Slot") then
                        prop.label = "Spell slot"
                        prop.value = prop.value:gsub(
                            "%s*Spell Slot%s*", "")
                    elseif prop.value:find("Sorcery Point")
                        or prop.value:find("Channel") then
                        prop.label = "Resource"
                    else
                        prop.label = "Cost"
                    end
                elseif prop.label == "VariationWarnings" then
                    prop.label = "Warning"
                elseif prop.label == "EmpoweredMetamagicText" then
                    prop.label = "Metamagic"
                    prop.tier = "verbose"
                elseif prop.label == "TitleValue" then
                    prop.label = "Total"
                elseif prop.label == "AbilityModifiersLabel" then
                    prop.label = "Breakdown"
                    prop.tier = "verbose"
                elseif prop.label == "Value" then
                    prop.label = "Breakdown"
                    prop.tier = "verbose"
                elseif prop.label == "txt" then
                    -- CC spell tooltips use "txt" for school+level,
                    -- e.g. "Evocation Cantrip" or "Level 1 Spell".
                    prop.label = "School"
                end
            end

            -- Post-process: SkillValue override.
            -- FromTooltip maps SkillValue to core "value" field.
            -- CC wants it as a property for richer context.
            if tooltipData.coreFields["value"] then
                tooltipData:AddProperty("Skill check",
                    tooltipData.coreFields["value"], "normal")
                tooltipData.coreFields["value"] = nil
            end

            -- Post-process: unnamed entries (empty role with fontSize).
            -- FromTooltip skips these.  CC uses fontSize to distinguish
            -- title (>52) from body text.
            for _, tooltipEntry in ipairs(structuredData) do
                local role = tooltipEntry.role or ""
                if role == "" then
                    local entryText = SpeechData.CleanTooltipText(
                        tooltipEntry.text)
                    if entryText then
                        local entryFontSize =
                            tooltipEntry.fontSize or 0
                        if entryFontSize > 52 then
                            if not spoken.name then
                                tooltipData:Add("name",
                                    entryText, "brief")
                            end
                        elseif #entryText > 40 then
                            tooltipData:Add("description",
                                entryText, "verbose")
                        else
                            tooltipData:AddProperty("Effect",
                                entryText, "normal")
                        end
                    end
                end
            end

            if not next(tooltipData.coreFields)
                and #tooltipData.properties == 0 then return end
            -- Speak handles format / log / Tolk / spokenRoles
            -- accumulation.  CC tooltips queue (don't interrupt the
            -- item handler that just spoke); no state-change-
            -- interrupt pattern in CC.  Dedup of duplicate waves
            -- comes from value-aware spokenRoles cross-off in
            -- FromTooltip -- if the wave is identical to what was
            -- spoken before, FromTooltip returns empty and Speak
            -- early-returns.  No string compare needed.
            tooltipData:Speak(handlerState, false, nil, false,
                "CC TOOLTIP")
        end,
        GetSectionLabelSpoken = function()
            return handlerState.sectionLabelSpoken
        end,
    }
end

-- ============================================================================
-- Per-page handler instances
-- ============================================================================

-- CarouselDescHandler: Race / Subrace / Class / Subclass / Background /
-- Deity / Feat / Origin.  Carousel items get StaticData-backed descriptions.
-- Origin's body-type and identity sub-items route through ExtractOriginContext.
-- Sub-items (features, passives, spells) use FormatCCDCTextSplit.
local CarouselDescHandler = CreateCCPageHandler({
    name  = "CCCarouselDesc",
    pages = { "Race", "Subrace", "Class", "Subclass", "Background",
              "Deity", "Feat", "Origin" },
    customItemFn = function(focusedElement, snapshot, effectiveTab,
                            handlerState)
        local dcProps = focusedElement.dcProps
        local itemName, itemValue, itemDescription

        -- 1. FormatCCDCTextSplit: VM sub-table items (skills, abilities,
        --    spells, features, carousel items).
        itemName, itemValue, itemDescription = FormatCCDCTextSplit(
            dcProps, focusedElement.dcType)

        -- 2. ExtractOriginContext: Body Type, Identity, Origin character
        --    names (Origin page only, harmless elsewhere).
        if not itemName or itemName == "" then
            itemName, itemValue, itemDescription = ExtractOriginContext(
                focusedElement)
        end

        local elementClaimed = (itemName and itemName ~= "")
            or (itemDescription and itemDescription ~= "")

        -- 3. Helpers.FormatDCText: generic dcProps formatting.
        if not elementClaimed then
            itemName = Helpers.FormatDCText(dcProps)
            itemValue = nil
            itemDescription = nil
            elementClaimed = itemName and itemName ~= ""
        end

        -- 4. Helpers.ExtractTextFromData: visual text / elemText fallback.
        if not elementClaimed then
            itemName = Helpers.ExtractTextFromData(
                focusedElement, effectiveTab, false)
            itemValue = nil
            itemDescription = nil
        end

        -- God-object SelectedX.Name override: BFS may return the wrong
        -- carousel item or "Grid".  The god-object's SelectedX.Name is
        -- authoritative.  Skip when an extractor claimed description-only
        -- (e.g. ExtractOriginContext -> "Play as an existing character").
        local hasDescriptionOnly = (itemDescription
            and itemDescription ~= "")
            and (not itemName or itemName == "")
        if not hasDescriptionOnly
            and focusedElement.dcType == "gui::DCCharacterCreation"
            and dcProps then
            local resolvedTab = effectiveTab or ccState.lastMainTab
                or ccState.currentTabContext
            if resolvedTab then
                local subTableKey =
                    CC_SELECTED_DESCRIPTION_KEYS[resolvedTab]
                if subTableKey then
                    local subTable = dcProps[subTableKey]
                    if type(subTable) == "table" then
                        local dcName = subTable.Name
                            or subTable.DisplayName or subTable.Title
                        if dcName and dcName ~= "" then
                            local shouldOverride = (not itemName
                                or itemName == "")
                            if not shouldOverride and itemName then
                                local staticDataType =
                                    CC_TAB_STATIC_DATA_TYPE[resolvedTab]
                                if staticDataType then
                                    shouldOverride =
                                        Helpers.LookupStaticDataDescription(
                                            staticDataType,
                                            itemName) ~= nil
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

        -- Bail if all extractors produced nothing.
        if (not itemName or itemName == "")
            and (not itemDescription or itemDescription == "") then
            return nil, nil, nil
        end

        -- CC_SUMMARY_STAT_LABELS: prepend static label for DC types
        -- with no name of their own (Initiative, Hit Points).
        if itemName and itemName ~= "" and focusedElement.dcType
            and CC_SUMMARY_STAT_LABELS[focusedElement.dcType] then
            local staticLabel =
                CC_SUMMARY_STAT_LABELS[focusedElement.dcType]
            if staticLabel and staticLabel ~= "" and not itemValue then
                itemValue = itemName
                itemName = staticLabel
            end
        end

        -- Suppress bare zero values (selection indices, not game values).
        if itemValue and itemValue == "0" then itemValue = nil end

        -- Description enrichment (API-first).
        if not itemDescription or itemDescription == "" then
            itemDescription = nil

            -- VM carousel items: StaticData API by display name.
            if focusedElement.dcType
                and CC_SECTION_LABELS[focusedElement.dcType] then
                local sectionLabel = GetSectionLabel(focusedElement)
                if sectionLabel then
                    local staticDataType =
                        CC_TAB_STATIC_DATA_TYPE[sectionLabel]
                    if staticDataType and itemName
                        and itemName ~= "" then
                        itemDescription =
                            Helpers.LookupStaticDataDescription(
                                staticDataType, itemName)
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
                        itemDescription =
                            Helpers.StripMarkupTags(vmDescription)
                    end
                end
            end

            -- God-object: GetGodObjectDescription with deity detection.
            if not itemDescription
                and focusedElement.dcType
                    == "gui::DCCharacterCreation"
                and dcProps then
                local effectiveMainTab = ccState.lastMainTab
                if effectiveMainTab
                    and not CC_TAB_STATIC_DATA_TYPE[effectiveMainTab]
                    and Helpers.LookupStaticDataDescription(
                        "God", effectiveMainTab) then
                    effectiveMainTab = "Deity"
                end
                if effectiveMainTab then
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
            end
        end

        return itemName, itemValue, itemDescription
    end,
    buildDetailList = function(focusedData, tooltipTexts)
        if not focusedData then return nil end
        local detailList = {}
        local dcProps = focusedData.dcProps

        -- Name.
        local itemName = nil
        if dcProps then
            itemName, _, _ = FormatCCDCTextSplit(
                dcProps, focusedData.dcType)
            if not itemName or itemName == "" then
                itemName = Helpers.FormatDCText(dcProps)
            end
        end
        if itemName and itemName ~= "" then
            detailList[#detailList + 1] = {
                label = "Name",
                value = Helpers.StripMarkupTags(itemName)}
        end

        -- Description from dcProps or StaticData API.
        local itemDescription = nil
        if dcProps then
            local sectionLabel = GetSectionLabel(focusedData)
            if sectionLabel then
                local staticDataType =
                    CC_TAB_STATIC_DATA_TYPE[sectionLabel]
                if staticDataType and itemName then
                    itemDescription =
                        Helpers.LookupStaticDataDescription(
                            staticDataType, itemName)
                end
            end
            if not itemDescription then
                local vmDescription = dcProps.Description
                if type(vmDescription) == "table" then
                    vmDescription = vmDescription.Text
                        or vmDescription.Str
                end
                if type(vmDescription) == "string"
                    and vmDescription ~= "" then
                    itemDescription = vmDescription
                end
            end
        end
        if itemDescription and itemDescription ~= "" then
            detailList[#detailList + 1] = {
                label = "Description",
                value = Helpers.StripMarkupTags(itemDescription)}
        end

        -- Tooltip entries (features, proficiencies, etc.).
        local tooltips = ccState.lastTooltipData or tooltipTexts
        if tooltips then
            local propertyIndex = 0
            local DV = BG3Access.Client.DetailView
            for _, entry in ipairs(tooltips) do
                local text = entry.text
                if text and text ~= "" then
                    local cleaned = NormalizeDetailText(
                        Helpers.StripMarkupTags(text),
                        entry.role)
                    if cleaned and cleaned ~= ""
                        and cleaned ~= "Inspect" then
                        local role = entry.role or "?"
                        local friendlyLabel
                        if role == "PropertyText" then
                            propertyIndex = propertyIndex + 1
                            if entry.typeId then
                                friendlyLabel =
                                    DV.PropertyTypeLabels[entry.typeId]
                                    or entry.typeId
                            else
                                friendlyLabel =
                                    DV.PropertyPositionalLabels[
                                        propertyIndex]
                                    or "Property"
                            end
                        elseif role == "?" then
                            friendlyLabel = "Info"
                        else
                            friendlyLabel =
                                DetailRoleLabel(role, cleaned)
                                    or "Info"
                        end
                        if entry.typeId == "Concentration" then
                            detailList[#detailList + 1] = {
                                label = "Requires concentration",
                                value = ""}
                        else
                            detailList[#detailList + 1] = {
                                label = friendlyLabel,
                                value = cleaned}
                        end
                    end
                end
            end
        end

        if #detailList == 0 then return nil end
        return detailList
    end,
})

-- AbilitiesHandler: abilities grid with points-remaining + rules hint.
-- CC_TAB_HINTS["Abilities"] is nil on purpose -- screenBodyFn owns the
-- extra body text so rules hint and points count are one announcement.
local AbilitiesHandler = CreateCCPageHandler({
    name  = "CCAbilities",
    pages = { "Abilities" },
    customItemFn = function(focusedElement, snapshot, effectiveTab,
                            handlerState)
        local dcProps = focusedElement.dcProps
        local itemName, itemValue, itemDescription

        -- FormatCCDCTextSplit handles VMAbility items.
        itemName, itemValue, itemDescription = FormatCCDCTextSplit(
            dcProps, focusedElement.dcType)

        if not itemName or itemName == "" then
            itemName = Helpers.FormatDCText(dcProps)
        end
        if not itemName or itemName == "" then
            itemName = Helpers.ExtractTextFromData(
                focusedElement, effectiveTab, false)
        end

        if (not itemName or itemName == "")
            and (not itemDescription or itemDescription == "") then
            return nil, nil, nil
        end

        -- CC_SUMMARY_STAT_LABELS (Initiative, Hit Points).
        if itemName and itemName ~= "" and focusedElement.dcType
            and CC_SUMMARY_STAT_LABELS[focusedElement.dcType] then
            local staticLabel =
                CC_SUMMARY_STAT_LABELS[focusedElement.dcType]
            if staticLabel and staticLabel ~= "" and not itemValue then
                itemValue = itemName
                itemName = staticLabel
            end
        end

        if itemValue and itemValue == "0" then itemValue = nil end

        return itemName, itemValue, itemDescription
    end,
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

-- SkillsHandler: skill name + modifier value via FormatCCDCTextSplit.
-- LocaString-resolved hint ("Choose N skills").
local SkillsHandler = CreateCCPageHandler({
    name  = "CCSkills",
    pages = { "Skills", "Skill Expertise" },
    customItemFn = function(focusedElement, snapshot, effectiveTab,
                            handlerState)
        local dcProps = focusedElement.dcProps
        local itemName, itemValue, itemDescription

        -- FormatCCDCTextSplit handles VMCharacterCreationSkill / VMSkill.
        itemName, itemValue, itemDescription = FormatCCDCTextSplit(
            dcProps, focusedElement.dcType)

        if not itemName or itemName == "" then
            itemName = Helpers.FormatDCText(dcProps)
        end
        if not itemName or itemName == "" then
            itemName = Helpers.ExtractTextFromData(
                focusedElement, effectiveTab, false)
        end

        if (not itemName or itemName == "")
            and (not itemDescription or itemDescription == "") then
            return nil, nil, nil
        end

        return itemName, itemValue, itemDescription
    end,
    hintFn = function(tabName)
        if tabName == "Skill Expertise" then
            return "Double your Proficiency Bonus for any checks"
                .. " you make with skills that you have Expertise"
                .. " in. Press A to assign or remove expertise."
        end
        local instruction = GetPageInstructionText(tabName)
        if instruction then
            return instruction .. ". Press A to select or deselect."
        end
        return nil
    end,
})

-- SpellSelectionHandler: Cantrip + Spell + High Elf Cantrip all share
-- the spell grid.  Spell names via FormatCCDCTextSplit; descriptions
-- are deferred to tooltips (C++ tooltip extraction resolves parameters
-- and unit conversions that API descriptions miss).
-- hintFn prioritizes CC_TAB_HINTS (hand-written navigation guidance
-- like "cantrips don't use spell slots") over the LocaString instruction
-- text ("Selected. Available") which is just XAML header labels.
local CANTRIP_HINT = "Choose from the cantrip list below. D-pad in all directions to navigate the spell grid. Cantrips don't use spell slots and can be cast at will."
local SPELL_HINT = "Choose from the spell list below. D-pad in all directions to navigate the spell grid."

local SpellSelectionHandler = CreateCCPageHandler({
    name  = "CCSpellSelection",
    pages = { "Cantrip", "Spell", "High Elf Cantrip" },
    customItemFn = function(focusedElement, snapshot, effectiveTab,
                            handlerState)
        local dcProps = focusedElement.dcProps
        local itemName, itemValue, itemDescription

        -- FormatCCDCTextSplit handles VMSpellReference, VMFeatureBoost,
        -- VMPassiveFeatureBoost.
        itemName, itemValue, itemDescription = FormatCCDCTextSplit(
            dcProps, focusedElement.dcType)

        if not itemName or itemName == "" then
            itemName = Helpers.FormatDCText(dcProps)
        end
        if not itemName or itemName == "" then
            itemName = Helpers.ExtractTextFromData(
                focusedElement, effectiveTab, false)
        end

        if (not itemName or itemName == "")
            and (not itemDescription or itemDescription == "") then
            return nil, nil, nil
        end

        -- Descriptions deferred to tooltip.  The C++ tooltip reads
        -- CtxTransStringRunGeneratorBehavior-populated TextBlocks
        -- which produce unit-converted, fully-resolved text matching
        -- what the sighted user sees.

        return itemName, itemValue, itemDescription
    end,
    screenBodyFn = function(focusedElement, tabName, handlerState,
                            snapshot)
        -- Read the spell selector description from the sub-panel
        -- (e.g. "You may change your cantrip... It uses your
        -- Intelligence as its modifier.").
        local descriptionOk, descriptionInfo = pcall(
            Ext.UI.QueryNamedElement, "SpellSelectorDescription")
        if descriptionOk and descriptionInfo
            and descriptionInfo.elemText
            and descriptionInfo.elemText ~= "" then
            return Helpers.StripMarkupTags(descriptionInfo.elemText)
        end
        return nil
    end,
    hintFn = function(tabName, snapshot, handlerState)
        -- Distinguish cantrip vs spell pages by checking the
        -- focused element's Spell.Level (0 = cantrip).
        if tabName == "Cantrip" or tabName == "High Elf Cantrip" then
            return CANTRIP_HINT
        end
        if snapshot and snapshot.focusedElement then
            local dcProps = snapshot.focusedElement.dcProps
            if dcProps and type(dcProps.Spell) == "table" then
                local level = dcProps.Spell.Level
                if level == 0 or level == "0" then
                    return CANTRIP_HINT
                end
            end
        end
        return SPELL_HINT
    end,
    buildDetailList = function(focusedData, tooltipTexts)
        -- Use CC's cached tooltip data (closure over ccState).
        local tooltips = ccState.lastTooltipData or tooltipTexts
        if not tooltips or #tooltips == 0 then return nil end

        local detailList = {}
        -- Spell name from focused data.
        if focusedData and focusedData.dcProps then
            local spellName = Helpers.FormatDCText(focusedData.dcProps)
            if spellName and spellName ~= "" then
                detailList[#detailList + 1] = {
                    label = "Spell",
                    value = Helpers.StripMarkupTags(spellName)}
            end
        end

        -- PropertyText entries get positional labels (Range, Modifier).
        local propertyIndex = 0
        -- TypeId -> user-friendly label for PropertyText entries.
        local DV = BG3Access.Client.DetailView

        for _, entry in ipairs(tooltips) do
            local text = entry.text
            if not text or text == "" then goto continueEntry end
            local cleaned = NormalizeDetailText(
                Helpers.StripMarkupTags(text), entry.role)
            if not cleaned or cleaned == "" then goto continueEntry end
            if cleaned == "Inspect" then goto continueEntry end

            local role = entry.role or "?"
            if role == "PropertyText" then
                propertyIndex = propertyIndex + 1
                local propertyLabel
                if entry.typeId then
                    propertyLabel =
                        DV.PropertyTypeLabels[entry.typeId]
                        or entry.typeId
                else
                    propertyLabel =
                        DV.PropertyPositionalLabels[propertyIndex]
                        or "Property"
                end
                if entry.typeId == "Concentration" then
                    detailList[#detailList + 1] = {
                        label = "Requires concentration",
                        value = ""}
                else
                    detailList[#detailList + 1] = {
                        label = propertyLabel, value = cleaned}
                end
            elseif role == "?" then
                -- Unnamed entries: use fontSize to distinguish
                -- title (>52, already handled above) from other.
                if not (entry.fontSize and entry.fontSize > 52) then
                    detailList[#detailList + 1] = {
                        label = "Info", value = cleaned}
                end
            else
                local friendlyLabel = DetailRoleLabel(role, cleaned)
                    or "Info"
                detailList[#detailList + 1] = {
                    label = friendlyLabel, value = cleaned}
            end
            ::continueEntry::
        end

        if #detailList == 0 then return nil end
        return detailList
    end,
})

-- AppearanceHandler: sliders, inline carousels, toggles, color
-- descriptions.  Body Type / Identity rows use ExtractOriginContext.
-- Carousel values include color priority: manual override -> computed
-- hex -> raw display name.
local AppearanceHandler = CreateCCPageHandler({
    name  = "CCAppearance",
    pages = { "Appearance" },
    customItemFn = function(focusedElement, snapshot, effectiveTab,
                            handlerState)
        local dcProps = focusedElement.dcProps
        local itemName, itemValue, itemDescription

        -- 1. ExtractOriginContext: Body Type, Identity rows.
        itemName, itemValue, itemDescription = ExtractOriginContext(
            focusedElement)

        -- 2. FormatCCDCTextSplit: VM sub-items (if any).
        if not itemName or itemName == "" then
            itemName, itemValue, itemDescription = FormatCCDCTextSplit(
                dcProps, focusedElement.dcType)
        end

        local elementClaimed = (itemName and itemName ~= "")
            or (itemDescription and itemDescription ~= "")

        -- 3. Helpers.FormatDCText: generic dcProps formatting.
        if not elementClaimed then
            itemName = Helpers.FormatDCText(dcProps)
            itemValue = nil
            itemDescription = nil
            elementClaimed = itemName and itemName ~= ""
        end

        -- 4. Helpers.ExtractTextFromData: visual text / elemText.
        if not elementClaimed then
            itemName = Helpers.ExtractTextFromData(
                focusedElement, effectiveTab, false)
            itemValue = nil
            itemDescription = nil
        end

        if (not itemName or itemName == "")
            and (not itemDescription or itemDescription == "") then
            return nil, nil, nil
        end

        -- CC_ELEM_NAME_OVERRIDES: "newRandomAppearance" -> friendlier.
        if itemName and focusedElement.elemName
            and CC_ELEM_NAME_OVERRIDES[focusedElement.elemName] then
            itemName = CC_ELEM_NAME_OVERRIDES[focusedElement.elemName]
        end

        -- Post-extraction overrides (only when itemName is set).
        if itemName and itemName ~= "" then
            -- Carousel value as itemValue: only when the carousel
            -- provides a value distinct from the name (appearance
            -- sub-selections like "Face" -> "Head 6").  NOT applied
            -- for race/class carousels where carousel value IS the name.
            local hasCarousel = snapshot.inlineCarouselValue
                and snapshot.inlineCarouselValue ~= ""
            if hasCarousel then
                local carouselValue = snapshot.inlineCarouselValue
                if carouselValue ~= itemName
                    and not carouselValue:match("^%d+$") then
                    -- Color description priority:
                    -- 1. Manual override (sighted-validated)
                    -- 2. Computed color from hex (skin/hair/eye)
                    -- 3. Raw carousel display name (fallback)
                    local ColorDescriptions =
                        BG3Access.Client.ColorDescriptions
                    local override =
                        ColorDescriptions.DescribeAppearanceItem(
                            carouselValue)
                    if override then
                        -- Manual override replaces entirely.
                        itemValue = override
                    else
                        local colorHex =
                            snapshot.inlineCarouselColorHex
                        if colorHex and colorHex ~= "" then
                            local colorDescription =
                                ColorDescriptions.DescribeColorHex(
                                    itemName, colorHex)
                            if colorDescription then
                                itemValue = colorDescription
                            else
                                itemValue = carouselValue
                            end
                        else
                            itemValue = carouselValue
                        end
                    end
                end
            end

            -- Toggle properties: read on/off from god-object property.
            if not itemValue and dcProps then
                local toggleProperty = CC_TOGGLE_PROPERTIES[itemName]
                if toggleProperty then
                    local toggleValue = dcProps[toggleProperty]
                    if type(toggleValue) == "string"
                        and toggleValue ~= "" then
                        itemValue = toggleValue
                    end
                end
            end

            -- Appearance label properties: elemText IS the label,
            -- display value from god-object property with transform.
            if not itemValue and dcProps then
                local appearanceMapping =
                    CC_APPEARANCE_LABEL_PROPERTIES[itemName]
                if appearanceMapping then
                    local rawValue = dcProps[appearanceMapping.property]
                    if type(rawValue) == "string"
                        and rawValue ~= "" then
                        local displayValue = rawValue
                        if appearanceMapping.transform then
                            displayValue =
                                appearanceMapping.transform(rawValue)
                        end
                        itemValue = displayValue
                    end
                end
            end

            -- Slider setting value: FormatDCValue restores the value
            -- on left/right presses.
            if not itemValue
                and focusedElement.dcType
                    == "gui::VMSliderSetting" then
                local sliderValue = Helpers.FormatDCValue(dcProps)
                if sliderValue and sliderValue ~= "" then
                    itemValue = sliderValue
                end
            end
        end

        -- No description enrichment for appearance items.

        return itemName, itemValue, itemDescription
    end,
})

-- AbilityBonusHandler: the "Ability Bonus" sub-page under Race / Class.
-- Appends selected ability name to "+2 Bonus" -> "+2 Bonus to Strength".
local AbilityBonusHandler = CreateCCPageHandler({
    name  = "CCAbilityBonus",
    pages = { "Ability Bonus" },
    hint = "Select two abilities to get an additional bonus. D-pad left and right to change the ability. D-pad down to see your ability scores.",
    customItemFn = function(focusedElement, snapshot, effectiveTab,
                            handlerState)
        local dcProps = focusedElement.dcProps
        local itemName, itemValue, itemDescription

        -- FormatCCDCTextSplit handles VMAbility items.
        itemName, itemValue, itemDescription = FormatCCDCTextSplit(
            dcProps, focusedElement.dcType)

        if not itemName or itemName == "" then
            itemName = Helpers.FormatDCText(dcProps)
        end
        if not itemName or itemName == "" then
            itemName = Helpers.ExtractTextFromData(
                focusedElement, effectiveTab, false)
        end

        if (not itemName or itemName == "")
            and (not itemDescription or itemDescription == "") then
            return nil, nil, nil
        end

        -- Bonus ability suffix: "+2 Bonus" -> "+2 Bonus to Strength".
        if itemName and itemName:find("Bonus", 1, true)
            and dcProps and dcProps.SelectedBonusAbility then
            itemName = itemName .. " to "
                .. dcProps.SelectedBonusAbility
        end

        return itemName, itemValue, itemDescription
    end,
})

-- ============================================================================
-- Page handler routing
-- ============================================================================

PAGE_HANDLERS = {
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
    ["Skill Expertise"]  = SkillsHandler,
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
                ccState.currentTabContext = nil
                Log.Debug("LOCKOUT: cleared (real focused element arrived)")
            else
                return
            end
        elseif ccState.pendingTransition == "MainCC" then
            if hasRealDCType then
                ccState.pendingTransition = nil
                ccState.lastMainTab = nil
                ccState.currentTabContext = nil
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
                -- Only arm post-cutscene gate on genuinely new widgets
                -- (WidgetAdded), NOT on INPC-triggered DC refreshes
                -- (WidgetDCChanged).  INPC fires when the user cycles
                -- races/classes, re-detecting the CC widget as "changed".
                -- Treating that as a cutscene return kills carousel speech
                -- and resets handler state mid-navigation.
                if widgetEvent.dcType == "gui::DCCharacterCreation"
                    and widgetEvent.eventType == "WidgetAdded"
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
                local hintSpeech = SpeechData.Create()
                hintSpeech:Add("navigationHint",
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
    -- Carousel changes set valueChanged in C++, handled by the
    -- per-page handler's value path.  No special carousel code here.

    -- Guard: bail on nil focus.  Also bail on empty focus
    -- (dcType="(none)") but ONLY when already in CC -- INPC value
    -- ticks have empty-focus tables that cause activeTabTag to
    -- misclassify (e.g. Race -> Origin).  First CC entry legitimately
    -- has empty focus and must pass through for intro detection.
    if not focusedElement then return end
    if ccState.inCharacterCreation
        and (not focusedElement.dcType
            or focusedElement.dcType == "(none)"
            or focusedElement.dcType == "") then
        return
    end

    -- Interactive instruction screens (text input).  Speak the
    -- instruction once per focus arrival, suppress subsequent ticks.
    if focusedElement and focusedElement.elemName then
        local instruction = CC_INTERACTIVE_INSTRUCTIONS[
            focusedElement.elemName]
        if instruction then
            if ccState.activeInstruction ~= focusedElement.elemName then
                ccState.activeInstruction = focusedElement.elemName
                local instructionSpeech = SpeechData.Create()
                instructionSpeech:Add("instructionHint", instruction, "brief")
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
    if focusedElement and focusedElement.dcProps
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
    if focusedElement
        and not ccState.inPostNamingCC
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
        -- Close detail view on page switch.
        pcall(function()
            local DetailView = BG3Access.Client.DetailView
            if DetailView then DetailView.Close(true) end
        end)
        if ccState.activePageHandler then
            ccState.activePageHandler.ResetNavigation()
        end
        ccState.currentPage = pageName
        ccState.activePageHandler = ResolveHandlerForPage(pageName)
        isFirstEntry = true
        ccState.currentTabContext = pageName
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
                ccState.currentTabContext = ccState.currentPage
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

    -- Track focused DC type for next tick's classifier (sub-item
    -- transition detection).
    if focusedElement and focusedElement.dcType then
        ccState.lastFocusedDCType = focusedElement.dcType
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

--- DispatchTooltip: routes structured tooltip data to the active
--- CC page handler.  The handler owns all speech decisions via
--- HandleTooltip (role-based cross-off by spokenRoles).
--- @param structuredTooltipData table|nil  Array of {role, text}
---     from C++ (nil on focus-only ticks with no tooltip data).
--- @param snapshot table  The full TickSnapshot (for change flags).
local function DispatchTooltip(structuredTooltipData, snapshot)
    if not ccState.inCharacterCreation then return end

    -- spokenRoles is reset by RecordSpokenRoles on each
    -- screen-entry / item-nav speech, so cross-off naturally
    -- starts fresh per focus.  No explicit reset needed here.

    if not structuredTooltipData then return end

    -- Cache for detail view (RS Left).
    ccState.lastTooltipData = structuredTooltipData

    -- Dispatch to active page handler.
    if ccState.activePageHandler
        and ccState.activePageHandler.HandleTooltip then
        ccState.activePageHandler.HandleTooltip(
            structuredTooltipData, structuredTooltipData)
    end
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
    -- INPC-triggered DC refreshes (WidgetDCChanged) are NOT real
    -- widget re-additions.  Only genuine WidgetAdded events (cutscene
    -- return, dialog close) should trigger a blurb-return reset.
    if widgetData.eventType and widgetData.eventType ~= "WidgetAdded" then
        return
    end
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
    DispatchTooltip      = DispatchTooltip,
    MarkMidSessionReload = MarkMidSessionReload,
    GetSectionLabel      = GetSectionLabel,
    GetBodyTypeName      = GetBodyTypeName,
    CC_SECTION_LABELS    = CC_SECTION_LABELS,
    SubscribeCCYButton   = SubscribeCCYButton,
    UnsubscribeCCYButton = UnsubscribeCCYButton,
    IsInCC               = IsInCC,
    GetActiveHandler     = function()
        return ccState.activePageHandler
    end,
    ResetCCNavigation    = ResetCCNavigation,
    ResetCCState         = ResetCCState,
}
