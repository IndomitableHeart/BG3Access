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
    -- Item-level DC types (individual items within pages, not page headers).
    -- These ensure IsCCSnapshot recognizes them so the CC handler processes
    -- skill proficiency cycling, ability bonus cycling, etc.
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
    ["Origin"] = "Choose your character origin. Custom lets you build from scratch. Other origins have preset backstories. D-pad left and right to browse origins. Press right trigger to see a summary of your character.",
    ["Race"] = "Choose your race. Each has unique traits and proficiencies. D-pad left and right to browse races. D-pad down to see racial features. D-pad left or right from within the features list returns to the race selection.",
    ["Subrace"] = "Choose your subrace. D-pad left and right to browse subraces. D-pad down to see subrace features. D-pad left or right from within the features list returns to the subrace selection.",
    ["Class"] = "Choose your class. This determines your abilities, spells, and proficiencies. D-pad left and right to browse classes. D-pad down to see class features. D-pad left or right from within the features list returns to the class selection.",
    ["Background"] = "Choose your background. This affects your skill proficiencies and how characters react to you. D-pad left and right to browse backgrounds.",
    ["Abilities"] = nil,  -- handled separately with points remaining
    ["Skills"] = nil,  -- handled separately with instruction text
    ["Spell"] = "Change your cantrip selection by choosing from the spell list below. D-pad in all directions to navigate the spell grid. Cantrips don't use spell slots and can be cast at will.",
    ["High Elf Cantrip"] = "Choose a cantrip from the list below. D-pad in all directions to navigate the spell grid. Cantrips don't use spell slots and can be cast at will.",
    ["Appearance"] = "Customize your character's appearance. D-pad up and down to navigate options. D-pad left and right to change values.",
    ["Deity"] = "Choose your deity. D-pad left and right to browse deities.",
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
        local resolved = H.GetTranslatedStringIfHandle(handle)
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

-- Cache: display name -> stat description.  Built on first miss from
-- Ext.Stats.GetStats("SpellData").  nil sentinel means "no match found".
local spellDescriptionCache = {}
local spellCacheBuilt = false

-- Cache: display name -> stat description for passives/features.
-- Built on first lookup from Ext.Stats.GetStats("PassiveData").
local passiveDescriptionCache = {}
local passiveCacheBuilt = false

-- Cache: display name -> description for progression boosts.
-- Built from Ext.StaticData ProgressionDescription resources.
-- Covers category proficiencies, saving throws, and other boosts
-- that don't exist in PassiveData.
local progressionDescriptionCache = {}
local progressionCacheBuilt = false

-- Unified StaticData description cache.
-- Maps StaticData type -> { normalizedDisplayName -> description }.
-- Built lazily per type on first lookup.
local staticDataDescriptionCaches = {}
local staticDataCacheBuilt = {}

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
-- CC Helper Functions
-- ============================================================================

-- Get the CC section label from a data table's dcType.
-- Returns section name string or nil.
-- Look up a spell's description from Ext.Stats.
-- Tries the display name with various prefixes (Projectile_, Target_, etc.).
-- Returns description string or nil.
-- Level map values at level 1 (CC is always level 1).
-- Maps the LevelMapValue key to the dice expression at that level.
local LEVEL_MAP_VALUES = {
    ["D4Cantrip"]  = "1d4",
    ["D6Cantrip"]  = "1d6",
    ["D8Cantrip"]  = "1d8",
    ["D10Cantrip"] = "1d10",
    ["D12Cantrip"] = "1d12",
    ["D4"]         = "1d4",
    ["D6"]         = "1d6",
    ["D8"]         = "1d8",
    ["D10"]        = "1d10",
    ["D12"]        = "1d12",
}

-- Extract a human-readable value from a DescriptionParams expression.
-- E.g., "DealDamage(1d8,Necrotic)" -> "1d8 Necrotic damage"
--        "ApplyStatus(BURNING,100,1)" -> "Burning"
--        "RegainHitPoints(1d8)" -> "1d8"
--        "LevelMapValue(D8Cantrip)" -> "1d8"
--        "Distance(12)" -> "12m"
local function ParseDescriptionParam(expression)
    if not expression or expression == "" then return nil end

    -- DealDamage(dice,type) -> "dice type damage"
    local dice, damageType = expression:match("DealDamage%(([^,]+),([^,)]+)")
    if dice and damageType then
        -- Resolve nested LevelMapValue in dice expression.
        local levelMapKey = dice:match("LevelMapValue%(([^)]+)%)")
        if levelMapKey and LEVEL_MAP_VALUES[levelMapKey] then
            dice = LEVEL_MAP_VALUES[levelMapKey]
        end
        return dice .. " " .. damageType .. " damage"
    end

    -- LevelMapValue(key) -> dice from lookup table
    local levelMapKey = expression:match("LevelMapValue%(([^)]+)%)")
    if levelMapKey then
        local resolved = LEVEL_MAP_VALUES[levelMapKey]
        if resolved then return resolved end
        -- Unknown key: return the key name as-is (better than nothing).
        return levelMapKey
    end

    -- RegainHitPoints(dice) -> "dice"
    local healDice = expression:match("RegainHitPoints%(([^)]+)%)")
    if healDice then return healDice end

    -- ApplyStatus(STATUS,...) -> humanize status name
    local statusName = expression:match("ApplyStatus%(([^,]+)")
    if statusName then
        return statusName:gsub("_", " "):lower():gsub("^%l", string.upper)
    end

    -- Distance(N) -> "Nm"
    local distance = expression:match("Distance%(([^)]+)%)")
    if distance then return distance .. "m" end

    -- Plain number or dice expression (e.g., "1d6", "3")
    if expression:match("^%d+d?%d*$") then
        return expression
    end

    -- Fallback: return nil, leave [N] in place.
    return nil
end

-- Resolve [1], [2], etc. in a description using DescriptionParams from a stat.
-- Returns the description with params substituted where possible.
-- Resolve [1], [2], etc. in a description using DescriptionParams.
-- Accepts either a stat object (legacy) or a direct params string
-- (from cached prototype's DescriptionInfo.DescriptionParams).
local function ResolveDescriptionParams(text, stat, paramsString)
    if not text then return nil end
    if not text:find("%[%d+%]") then return text end

    -- Get the raw params string: prefer direct string, fall back to stat.
    local rawParams = paramsString
    if not rawParams and stat then
        local paramSuccess, paramValue = pcall(function()
            return stat.DescriptionParams
        end)
        if paramSuccess and type(paramValue) == "string" then
            rawParams = paramValue
        end
    end

    -- Parse semicolon-separated params into indexed table.
    local params = {}
    if rawParams and rawParams ~= "" then
        local index = 1
        for param in rawParams:gmatch("[^;]+") do
            local resolved = ParseDescriptionParam(
                param:match("^%s*(.-)%s*$"))
            if resolved then
                params[index] = resolved
            end
            index = index + 1
        end
    end

    -- Substitute [N] with resolved params.
    local result = text:gsub("%[(%d+)%]", function(numStr)
        local paramIndex = tonumber(numStr)
        if paramIndex and params[paramIndex] then
            return params[paramIndex]
        end
        -- No resolution available; strip the placeholder.
        return ""
    end)

    -- Collapse multiple spaces and trim.
    result = result:gsub("  +", " "):match("^%s*(.-)%s*$")
    if result == "" then return nil end
    return result
end

-- Try to read a description string from a stat object.
-- Only accesses "Description" — other attributes (DescriptionRef,
-- ExtraDescription, TooltipStatusApply) don't exist on all stat types
-- and trigger __debugbreak in BG3SE Debug builds.
-- Returns resolved text or nil.
local function ReadStatDescription(stat)
    if not stat then return nil end
    local propSuccess, propValue = pcall(function()
        return stat.Description
    end)
    if not propSuccess or not propValue then return nil end
    -- Handle TranslatedString table, userdata, or raw string.
    local handle = nil
    if type(propValue) == "string" and propValue ~= "" then
        handle = propValue
    elseif type(propValue) == "userdata" then
        local asString = tostring(propValue)
        if asString and asString ~= "" then
            handle = asString
        end
    elseif type(propValue) == "table" and propValue.Handle
        and propValue.Handle.Handle then
        handle = propValue.Handle.Handle
    end
    if handle then
        local resolved = H.GetTranslatedStringIfHandle(handle)
        if resolved and resolved ~= "" then
            return ResolveDescriptionParams(resolved, stat)
        end
    end
    return nil
end

-- Resolve a TranslatedString from a cached prototype's DescriptionInfo.
-- Handles string, userdata (tostring resolves it), and table formats.
local function ResolveTranslatedString(translatedString)
    if not translatedString then return nil end
    local stringType = type(translatedString)
    if stringType == "string" and translatedString ~= "" then
        local resolved = H.GetTranslatedStringIfHandle(translatedString)
        if resolved and not resolved:match("^h%x") then return resolved end
        return nil
    elseif stringType == "userdata" then
        -- TranslatedString userdata from cached prototypes.
        -- tostring() returns "TranslatedString (0x...)", not the text.
        -- Access Handle.Handle and resolve via localization.
        local handleSuccess, handle = pcall(function()
            return translatedString.Handle.Handle
        end)
        if handleSuccess and handle then
            local handleStr = tostring(handle)
            if handleStr and handleStr ~= "" then
                local resolved = H.GetTranslatedStringIfHandle(handleStr)
                if resolved and not resolved:match("^h%x") then
                    return resolved
                end
            end
        end
        -- Fallback: try .Value property.
        local valueSuccess, value = pcall(function()
            return translatedString.Value
        end)
        if valueSuccess and type(value) == "string"
            and value ~= "" and not value:match("^h%x") then
            return value
        end
        return nil
    elseif stringType == "table" then
        -- Try Handle.Handle first.
        if translatedString.Handle
            and translatedString.Handle.Handle then
            local resolved = H.GetTranslatedStringIfHandle(
                translatedString.Handle.Handle)
            if resolved and not resolved:match("^h%x") then
                return resolved
            end
        end
        -- Try common string fields.
        for _, key in ipairs({"Value", "Name", "Str"}) do
            if type(translatedString[key]) == "string"
                and translatedString[key] ~= "" then
                return translatedString[key]
            end
        end
    end
    return nil
end

-- Build a display-name -> description cache from all SpellData stats.
-- Uses GetCachedSpell for safe access to SpellPrototype.Description.
-- Called once on first cache miss.
local function BuildSpellDisplayNameCache()
    if spellCacheBuilt then return end
    spellCacheBuilt = true
    local success, allSpellIds = pcall(Ext.Stats.GetStats, "SpellData")
    if not success or not allSpellIds then
        Log.Info("SPELL CACHE: failed to enumerate SpellData stats")
        return
    end
    Log.Info("SPELL CACHE: building from " .. #allSpellIds .. " spell stats")
    for _, statId in ipairs(allSpellIds) do
        local entrySuccess, entryError = pcall(function()
            local cached = Ext.Stats.GetCachedSpell(statId)
            if not cached or not cached.Description then return end
            local displayName = ResolveTranslatedString(
                cached.Description.DisplayName)
            if not displayName then return end
            local normalizedName = displayName:lower()
            if spellDescriptionCache[normalizedName] then return end
            local description = ResolveTranslatedString(
                cached.Description.Description)
            if not description then return end
            local descParams = cached.Description.DescriptionParams
            if descParams and descParams ~= "" then
                description = ResolveDescriptionParams(
                    description, nil, descParams)
            end
            spellDescriptionCache[normalizedName] = description
        end)
        -- Same as passives: junk entries throw, pcall catches.
    end
    local count = 0
    for _ in pairs(spellDescriptionCache) do count = count + 1 end
    Log.Info("SPELL CACHE: " .. count .. " display names cached")
end

local function GetSpellDescription(spellName)
    if not spellName or spellName == "" then return nil end

    -- Use the display name cache exclusively.  It's built from
    -- Ext.Stats.GetStats("SpellData") which enumerates every spell
    -- with its correct stat ID.  No prefix guessing needed.
    BuildSpellDisplayNameCache()
    local normalizedLookup = spellName:lower()
    local cached = spellDescriptionCache[normalizedLookup]
    if cached then
        Log.Debug("SPELL CACHE HIT: " .. spellName)
        return cached
    end

    Log.Debug("SPELL MISS: '" .. spellName .. "'")
    return nil
end

-- Read Description from a passive stat.  Passive stats only have
-- Build a display-name -> description cache from all PassiveData stats.
-- Uses GetCachedPassive for safe access to PassivePrototype.Description.
-- Called once on first lookup.
local function BuildPassiveDisplayNameCache()
    if passiveCacheBuilt then return end
    passiveCacheBuilt = true
    local success, allPassiveIds = pcall(Ext.Stats.GetStats, "PassiveData")
    if not success or not allPassiveIds then
        Log.Info("PASSIVE CACHE: failed to enumerate PassiveData stats")
        return
    end
    Log.Info("PASSIVE CACHE: building from " .. #allPassiveIds .. " passive stats")
    for _, statId in ipairs(allPassiveIds) do
        local entrySuccess, entryError = pcall(function()
            local cached = Ext.Stats.GetCachedPassive(statId)
            if not cached or not cached.Description then return end
            local displayName = ResolveTranslatedString(
                cached.Description.DisplayName)
            if not displayName then return end
            local normalizedName = displayName:lower()
            if passiveDescriptionCache[normalizedName] then return end
            local description = ResolveTranslatedString(
                cached.Description.Description)
            if not description then return end
            local descParams = cached.Description.DescriptionParams
            if descParams and descParams ~= "" then
                description = ResolveDescriptionParams(
                    description, nil, descParams)
            end
            passiveDescriptionCache[normalizedName] = description
        end)
        -- Junk entries (%%% technical, broken TranslatedStrings) throw
        -- C++ exceptions caught by pcall.  Harmless; debugger may break
        -- on first-chance exception but game continues normally.
    end
    local count = 0
    for _ in pairs(passiveDescriptionCache) do count = count + 1 end
    Log.Info("PASSIVE CACHE: " .. count .. " display names cached")
end

-- Build a display-name -> description cache from ProgressionDescription
-- resources.  These cover category proficiencies (Simple Weapons, Light
-- Armour, etc.), saving throw proficiencies, and other boost descriptions
-- that don't exist in PassiveData or SpellData.
local function BuildProgressionDescriptionCache()
    if progressionCacheBuilt then return end
    progressionCacheBuilt = true
    local guidsSuccess, guids = pcall(
        Ext.StaticData.GetAll, "ProgressionDescription")
    if not guidsSuccess or not guids then
        Log.Info("PROGRESSION CACHE: failed to enumerate resources")
        return
    end
    Log.Info("PROGRESSION CACHE: building from "
        .. #guids .. " progression descriptions")
    for _, guid in ipairs(guids) do
        local entrySuccess, entryError = pcall(function()
            local entry = Ext.StaticData.Get(guid, "ProgressionDescription")
            if not entry then return end
            if entry.Hidden then return end
            local displayName = ResolveTranslatedString(entry.DisplayName)
            if not displayName then return end
            local description = ResolveTranslatedString(entry.Description)
            if not description then return end
            description = H.StripMarkupTags(description)
            local normalizedName = displayName:lower()
            if not progressionDescriptionCache[normalizedName] then
                progressionDescriptionCache[normalizedName] = description
            end
        end)
        -- Skip broken entries silently.
    end
    local count = 0
    for _ in pairs(progressionDescriptionCache) do count = count + 1 end
    Log.Info("PROGRESSION CACHE: " .. count .. " descriptions cached")
end

-- Build a display-name -> description cache for a StaticData type.
-- Generic: works for Race, ClassDescription, Background, God, Origin, etc.
-- Called once per type on first lookup.
local function BuildStaticDataDescriptionCache(staticDataType)
    if staticDataCacheBuilt[staticDataType] then return end
    staticDataCacheBuilt[staticDataType] = true
    staticDataDescriptionCaches[staticDataType] = {}
    local cache = staticDataDescriptionCaches[staticDataType]

    local guidsSuccess, guids = pcall(
        Ext.StaticData.GetAll, staticDataType)
    if not guidsSuccess or not guids then
        Log.Info("STATIC CACHE [" .. staticDataType
            .. "]: failed to enumerate")
        return
    end
    Log.Info("STATIC CACHE [" .. staticDataType
        .. "]: building from " .. #guids .. " entries")
    for _, guid in ipairs(guids) do
        pcall(function()
            local entry = Ext.StaticData.Get(guid, staticDataType)
            if not entry then return end
            local displayName = ResolveTranslatedString(entry.DisplayName)
            if not displayName then return end
            local description = ResolveTranslatedString(entry.Description)
            if not description then return end
            description = H.StripMarkupTags(description)
            local normalizedName = displayName:lower()
            if not cache[normalizedName] then
                cache[normalizedName] = description
            end
        end)
    end
    local count = 0
    for _ in pairs(cache) do count = count + 1 end
    Log.Info("STATIC CACHE [" .. staticDataType
        .. "]: " .. count .. " descriptions cached")
end

-- Look up a description by display name from a StaticData type cache.
-- Returns description string or nil.
local function GetStaticDataDescription(staticDataType, displayName)
    if not staticDataType or not displayName or displayName == "" then
        return nil
    end
    BuildStaticDataDescriptionCache(staticDataType)
    local cache = staticDataDescriptionCaches[staticDataType]
    if not cache then return nil end
    return cache[displayName:lower()]
end

-- Look up a feature/passive description by display name.
-- Returns description string or nil.
local function GetFeatureDescription(featureName, dcType)
    if not featureName or featureName == "" then return nil end
    BuildPassiveDisplayNameCache()
    local normalizedLookup = featureName:lower()
    local cached = passiveDescriptionCache[normalizedLookup]
    if cached then
        Log.Debug("PASSIVE HIT: " .. featureName)
        return cached
    end

    -- Fuzzy match: summary panel uses short names ("Rapiers") while
    -- the passive cache has "Rapier Proficiency".  Try variations
    -- to find the real game text before falling back to anything else.
    local singular = featureName:gsub("s$", "")
    -- Also try removing " Proficiency" suffix (e.g., "Light Armour Proficiency"
    -- stored as "Light Armour" in the UI).
    local withoutProf = featureName:gsub(" Proficiency$", "")
    local variations = {
        featureName .. " Proficiency",
        singular .. " Proficiency",
        singular,
        withoutProf,
    }
    for _, variant in ipairs(variations) do
        local variantDesc = passiveDescriptionCache[variant:lower()]
        if variantDesc then
            Log.Debug("PASSIVE FUZZY HIT: " .. featureName
                .. " via " .. variant)
            return variantDesc
        end
    end

    -- Spell lookup for spell-type features (Rage, Produce Flame).
    local spellDesc = GetSpellDescription(featureName)
    if spellDesc then
        Log.Debug("FEATURE SPELL HIT: " .. featureName)
        return spellDesc
    end

    -- Progression descriptions: category proficiencies, saving throws,
    -- and other boost descriptions that don't exist in PassiveData.
    -- Built dynamically from Ext.StaticData ProgressionDescription resources.
    BuildProgressionDescriptionCache()
    local progressionDesc = progressionDescriptionCache[normalizedLookup]
    if progressionDesc then
        Log.Debug("PROGRESSION HIT: " .. featureName)
        return progressionDesc
    end

    Log.Debug("FEATURE MISS: '" .. featureName .. "'")
    return nil
end

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
        local apiDesc = GetStaticDataDescription(staticDataType, itemName)
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
                    local apiDesc = GetStaticDataDescription(
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
                    return H.StripMarkupTags(description)
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
                local fallbackDesc = GetStaticDataDescription(
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
    if H.NormalizeForCompare(elemText) == "origin" then
        return nil, nil,
            "Play as an existing character from Baldur's Gate 3"
    end

    -- Origin character name (Custom, Astarion, etc.): match against SelectedOrigin.
    local selectedOrigin = data.dcProps.SelectedOrigin
    if type(selectedOrigin) == "table" then
        local originName = selectedOrigin.Name or selectedOrigin.DisplayName
            or selectedOrigin.Title
        if originName and H.NormalizeForCompare(elemText) == H.NormalizeForCompare(originName) then
            local originDesc = selectedOrigin.Description
            if type(originDesc) == "string" and originDesc ~= "" then
                -- Custom: speak the API description, then action hint.
                if H.NormalizeForCompare(originName) == "custom" then
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
--   4. H.FormatDCText (generic dcProps)
--   5. H.ExtractTextFromData (visual text / elemText fallback)
-- Then applies overrides (carousel, toggles, bonus ability, stat labels)
-- and enriches with API-first descriptions.
--
-- Parameters:
--   focusedElement  - the focused element data table
--   snapshot        - full snapshot from C++
--   state           - shared Manager state (lastMainTab, etc.)
--   tabName         - current tab name (may be nil for item nav)
--   isScreenEntry   - boolean, passed to H.ExtractTextFromData
--
-- Returns: name, value, description (all strings or nil)
local function GetCCItemData(focusedElement, snapshot, state, tabName,
                             isScreenEntry)
    if not focusedElement then return nil, nil, nil end

    local dcProps = focusedElement.dcProps
    local itemName = nil
    local itemValue = nil
    local itemDescription = nil

    -- 1. Placeholder guard: strip placeholder elemText so downstream
    --    extractors (H.ExtractTextFromData) don't pick it up.
    local elemText = focusedElement.elemText
    if elemText and IsPlaceholder(elemText) then
        Log.Debug("GetCCItemData: strip placeholder elemText: " .. elemText)
        elemText = nil
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

    -- 4. H.FormatDCText: generic dcProps formatting.
    if not elementClaimed then
        itemName = H.FormatDCText(dcProps)
        itemValue = nil
        itemDescription = nil
        elementClaimed = itemName and itemName ~= ""
    end

    -- 5. H.ExtractTextFromData: visual text / elemText fallback.
    --    Pass the effective tab name for context.
    if not elementClaimed then
        local effectiveTab = tabName or state.lastSpokenTab
        itemName = H.ExtractTextFromData(
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
        local effectiveMainTab = state.lastMainTab
        if effectiveMainTab
            and not CC_TAB_STATIC_DATA_TYPE[effectiveMainTab]
            and GetStaticDataDescription("God", effectiveMainTab) then
            effectiveMainTab = "Deity"
        end

        -- A. StaticData API via GetGodObjectDescription (primary).
        --    Covers Race, Class, Subclass, Background, Deity, Origin, Feat.
        if not itemDescription
            and focusedElement.dcType == "gui::DCCharacterCreation"
            and dcProps and effectiveMainTab then
            itemDescription = GetGodObjectDescription(
                dcProps, effectiveMainTab, itemName)
        end

        -- B. Feature/passive API via GetFeatureDescription.
        --    Covers race/class features, proficiencies, Darkvision, etc.
        if not itemDescription and focusedElement.dcType
            and CC_FEATURE_DC_TYPES[focusedElement.dcType] then
            local featureSuccess, featureDescription = pcall(
                GetFeatureDescription, itemName, focusedElement.dcType)
            if featureSuccess and featureDescription then
                itemDescription = featureDescription
                Log.Debug("GetCCItemData: feature desc: " .. itemName
                    .. " -> " .. tostring(featureDescription):sub(1, 60))
            end
        end

        -- C. Spell API via GetSpellDescription.
        --    Covers spell buttons (Fire Bolt, etc.).
        if not itemDescription and itemName
            and focusedElement.elemType
            and (focusedElement.elemType:find("LSButton", 1, true)
                or focusedElement.elemType:find("spellButton", 1, true))
            and itemName ~= "spell" then
            local spellSuccess, spellDescription = pcall(
                GetSpellDescription, itemName)
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

    -- God-object DC.
    if focusedElement.dcType == "gui::DCCharacterCreation" then
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
    if focusedElement.dcType and CC_SUMMARY_STAT_LABELS[focusedElement.dcType] then
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

-- Main CC handler.  Called by Manager when IsCCSnapshot returns true.
-- state is a table reference to shared Manager state variables.
local function HandleCCSnapshot(snapshot, state)
    local focusedElement = snapshot.focusedElement

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
        .. " lastTab=" .. tostring(state.lastSpokenTab)
        .. " mainTab=" .. tostring(state.lastMainTab)
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
            if selectedSectionLabel ~= state.lastSpokenTab then
                isScreenEntry = true
            end
        elseif selectedTabName
            and not selectedTabName:find("^ListBoxItem:")
            and selectedTabName ~= state.lastSpokenTab then
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
        and focusedSectionLabel and focusedSectionLabel ~= state.lastSpokenTab then
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
        and state.lastSpokenTab ~= "Appearance" then
        isScreenEntry = true
        Log.Info("CC Appearance page detected via elemName")
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
    -- Naming screen: buttons are hardcoded to controller inputs (A, Y),
    -- not d-pad navigable.  Detect via CC step and speak the screen
    -- content using API data for the character name.
    -- =================================================================
    -- Naming screen: CharacterCreationStep becomes "Naming" once all
    -- required pages are complete, and STAYS "Naming" even when bumping
    -- back to earlier tabs.  So we can't use the step alone.  Instead,
    -- detect the naming screen by: the focused element has NO focusable
    -- items (elemId is empty or just "ContentControl::base"), isScreenEntry
    -- fired, and we came from a regular CC tab (not already on Naming).
    -- The naming page has only button-mapped actions (A=Rename, Y=Guardian),
    -- nothing d-pad navigable.
    if isScreenEntry and state.lastSpokenTab ~= "Naming"
        and not selectedSectionLabel and not selectedTabName
        and focusedElement.dcType == "gui::DCCharacterCreation"
        and (not focusedElement.elemId or focusedElement.elemId == ""
            or focusedElement.elemId == "ContentControl::base") then
        -- Check that it's actually the naming screen by looking for
        -- CharacterName in dcProps (only present on the naming page's
        -- god-object, and the focused element has no meaningful content).
        if focusedElement.dcProps
            and focusedElement.dcProps.CharacterName then
            state.lastSpokenTab = "Naming"
            state.lastMainTab = "Naming"

            -- Get character name from entity API (primary).
            local characterName = nil
            local entitySuccess, entities = pcall(
                Ext.Entity.GetAllEntitiesWithComponent,
                "CCCharacterDefinition")
            if entitySuccess and entities and #entities > 0 then
                pcall(function()
                    characterName = entities[1].CCCharacterDefinition
                        .Definition.Name
                end)
            end
            -- God-object fallback, filtering placeholder strings.
            if not characterName or characterName == ""
                or characterName:find("^%[%d+%]$") then
                local godName = focusedElement.dcProps.CharacterName
                if godName and godName ~= ""
                    and not godName:find("^%[%d+%]$") then
                    characterName = godName
                end
            end
            if not characterName or characterName == ""
                or characterName:find("^%[%d+%]$") then
                characterName = "Tav"
            end

            local speech = "Enter Character Name. " .. characterName
                .. ". Press A to rename. Press Y to choose guardian"
            Log.Info("NAMING SCREEN: " .. speech)
            Ext.Tolk.Speak(speech, true)
            state.lastSpokenFullText = speech
            state.lastSpokenName = elemId
            state.lastSpokenItemName = "Naming"
            return
        end
    end

    -- =================================================================
    -- Standalone carousel or value change.
    -- =================================================================
    if isCarouselOnly then
        local carouselValue = snapshot.inlineCarouselValue

        -- Append description via StaticData API for tabs that have one.
        local effectiveTab = state.lastMainTab or state.lastSpokenTab
        -- Deity detection: tab name is a deity name, not "Deity".
        if effectiveTab
            and not CC_TAB_STATIC_DATA_TYPE[effectiveTab]
            and GetStaticDataDescription("God", effectiveTab) then
            effectiveTab = "Deity"
            state.lastMainTab = "Deity"
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

        if carouselValue ~= state.lastSpokenFullText then
            state.lastSpokenFullText = carouselValue
            state.lastSpokenName = elemId
            state.lastCarouselTick = Ext.Utils.MonotonicTime()
            Log.Info("CAROUSEL: " .. carouselValue)
            Ext.Tolk.Speak(carouselValue, true)
        end
        return
    end

    -- Suppress value-only events that immediately follow a carousel event
    -- on the same element (e.g., Face carousel fires "Head 3", then a
    -- stale value event fires just "Face" and interrupts).
    if isValueOnly and state.lastCarouselTick then
        local elapsed = Ext.Utils.MonotonicTime() - state.lastCarouselTick
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
            focusedElement, snapshot, state, nil, false)

        -- Assemble and speak.
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
        local fullText = table.concat(parts, ". ")
        if fullText ~= "" and fullText ~= state.lastSpokenFullText then
            state.lastSpokenFullText = fullText
            state.lastSpokenName = elemId
            if valueName and valueName ~= "" then
                state.lastSpokenItemName = valueName
            end
            Log.Info("VALUE: " .. fullText)
            Ext.Tolk.Speak(fullText, true)
        end
        return
    end

    -- =================================================================
    -- Screen entry or item navigation.
    -- =================================================================
    local slots = {}
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
        if tabName and tabName == state.lastSpokenTab then
            Log.Debug("SKIP CC screen entry (same tab): " .. tabName)
            isScreenEntry = false
        end

        Log.Info("SCREEN ENTRY: tab=" .. tostring(tabName)
            .. " sel=" .. tostring(snapshot.selectionChanged)
            .. " widget=" .. tostring(snapshot.widgetAdded))

        -- Update lastSpokenTab.  Never overwrite with nil — preserve
        -- the previous value so pages without recognized tab names
        -- (like Appearance) don't trigger first-entry logic repeatedly.
        local previousTab = state.lastSpokenTab
        if tabName then
            state.lastSpokenTab = tabName
        end
        state.lastSpokenItemName = nil  -- reset so label speaks on new page
        state.lastSpokenName = nil

        -- Track main RB tab separately from lastSpokenTab.
        -- Update on RB tab switches (selectionChanged=true) and on
        -- section-change detection (focusChanged into sub-sections
        -- like Subclass, Skills, Spell).  This ensures description
        -- lookups read the correct source: e.g. SelectedSubClass for
        -- domains instead of InfoClassDescription for the parent class.
        if snapshot.selectionChanged then
            state.lastMainTab = detectedSectionLabel or tabName
        elseif snapshot.focusChanged then
            -- If we focused a sub-section (Skills, Spell), use it.
            -- If we focused the god-object wrapper (nil), fall back
            -- to the currently selected carousel tab (Race, Class).
            -- If both are nil, keep the current state.
            state.lastMainTab = focusedSectionLabel
                or selectedSectionLabel or state.lastMainTab
        end

        -- Deity page detection: deity carousel items inherit the
        -- god-object DC (no unique VM type like ls.VMSelectableSubClass),
        -- so detectedSectionLabel is always nil.  Instead, check if the
        -- tab name is actually a deity display name from the StaticData
        -- cache.  If so, this is the deity page.
        if state.lastMainTab
            and not CC_TAB_STATIC_DATA_TYPE[state.lastMainTab]
            and GetStaticDataDescription("God", state.lastMainTab) then
            state.lastMainTab = "Deity"
            if tabName and not CC_TAB_STATIC_DATA_TYPE[tabName] then
                tabName = "Deity"
            end
        end

        -- ----- Title -----
        local screenTitle = nil
        local effectiveDCType = state.currentWidgetDCType
            or focusedElement.dcType
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

        -- Abilities page: speak points remaining and first-time rules hint.
        if tabName == "Abilities" and focusedElement.dcProps then
            local bodyParts = {}
            if not state.abilityHintSpoken then
                state.abilityHintSpoken = true
                table.insert(bodyParts,
                    "Every 2 points above 10 gives plus 1 to related rolls")
            end
            local unusedPoints = focusedElement.dcProps.UnusedAbilityPoints
            if unusedPoints then
                table.insert(bodyParts, unusedPoints .. " points remaining")
            end
            if #bodyParts > 0 then
                slots["body"] = table.concat(bodyParts, ". ")
            end
        end

        -- Tab hint: spoken once per tab on first visit.
        -- Only fire on selection-based entry (bumper press), not on
        -- focus-only section crossings (summary panel scrolling).
        local hintKey = tabName
        if not hintKey and detectedSectionLabel then
            hintKey = detectedSectionLabel
        end
        if hintKey and not state.tabHintsSpoken then
            state.tabHintsSpoken = {}
        end
        if hintKey and state.tabHintsSpoken
            and not state.tabHintsSpoken[hintKey]
            and snapshot.selectionChanged then
            local hint = CC_TAB_HINTS[hintKey]
            if hint then
                state.tabHintsSpoken[hintKey] = true
                slots["body"] = hint
                Log.Info("TAB HINT: " .. hintKey .. " -> " .. hint:sub(1, 60))
            end
        end

        -- First CC entry: natural introduction speech.
        if not previousTab then
            slots["title"] = "Character Creation"
            slots["hint"] = "You are on the " .. (tabName or "origin")
                .. " page. Use bumpers to switch tabs."
            slots["tabName"] = nil  -- suppress raw tab name
            state.lastSpokenTitle = "Character Creation"
            state.tabHintSpoken = true
            state.lastMainTab = detectedSectionLabel or tabName
            state.lastSpokenName = elemId
            Log.Info("CC SLOTS: first entry, tab=" .. tostring(tabName))
            SpeakSlots(slots, state, true)
            return
        end
    end

    -- =================================================================
    -- Unified item extraction: parse ONCE via GetCCItemData.
    -- Both screen entry and item nav use the same result.
    -- =================================================================
    local effectiveTabForExtraction = tabName or state.lastSpokenTab
    local itemName, itemValue, itemDesc = GetCCItemData(
        focusedElement, snapshot, state, effectiveTabForExtraction,
        isScreenEntry)

    -- Item navigation dedup: same elemId and same extracted name.
    -- Skip dedup when valueChanged (DC swapped on recycled element)
    -- or when the value differs from what was last spoken (body type
    -- cycling: same "Body Type" name but different value each time).
    if isItemNav and elemId == state.lastSpokenName and not hasCarousel
        and not snapshot.valueChanged then
        local valueDiffers = itemValue
            and itemValue ~= state.lastSpokenFullText
        if not valueDiffers then
            if not itemName or itemName == state.lastSpokenItemName
                or itemName == state.lastSpokenFullText then
                Log.Debug("DEDUP SKIP: " .. tostring(elemId))
                return
            end
        end
    end

    -- ----- Section header suppression -----
    -- Applied to the parsed name, not re-extracted.  GetCCItemData
    -- returns raw data; the handler decides what to suppress.
    if itemName then
        local effectiveTab = tabName or state.lastSpokenTab
        local normalTab = effectiveTab
            and H.NormalizeForCompare(effectiveTab) or ""
        local normalItem = H.NormalizeForCompare(itemName)

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
        -- update state.lastSpokenName so the dedup check on the NEXT
        -- element doesn't compare against the stale elemId from two
        -- visits ago.  Without this, Custom->Origin(suppressed)->Custom
        -- causes the second Custom to dedup-skip because
        -- lastSpokenName still points at the first Custom's elemId.
        if not itemName and (itemDesc or itemValue) then
            state.lastSpokenName = elemId
            state.lastSpokenItemName = nil
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
                    if state.lastMainTab ~= recoveryTab then
                        Log.Debug("AUTO-RECOVER lastMainTab: "
                            .. tostring(state.lastMainTab) .. " -> "
                            .. recoveryTab)
                        state.lastMainTab = recoveryTab
                    end
                    break
                end
            end
        end
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

    -- Value-only speech: when cycling values on the same item (e.g.,
    -- left/right on Body Type), suppress the label and speak only the
    -- new value.  Mimics Options menu behavior (label on first visit,
    -- value-only on subsequent changes).
    if itemName and itemValue and state.lastSpokenItemName
        and itemName == state.lastSpokenItemName then
        -- Same label, different value -> speak value only.
        state.lastSpokenFullText = itemValue
        state.lastSpokenName = elemId
        state.lastSpokenItemName = itemName
        Log.Info("VALUE CYCLE: " .. itemValue)
        Ext.Tolk.Speak(itemValue, true)
        return
    end

    if itemName then
        state.lastSpokenItemName = itemName
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
