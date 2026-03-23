-- File: Client/AccessibilityHelpers.lua
--
-- Pure utility functions for BG3Access speech formatting and text extraction.
-- None of these functions reference module-level state variables.  They take
-- data in and return data out, making them safe to call from any context.

local Log = BG3Access.Client.Log

-- ---------------------------------------------------------------------------
-- Constants: data tables used by helper functions.
-- ---------------------------------------------------------------------------

-- Character creation section labels.
-- Maps DC types of carousel items to their section/page name.
local CC_SECTION_LABELS = {
    ["ls.VMSelectableOrigin"]      = "Origin",
    ["ls.VMSelectableRace"]        = "Race",
    ["ls.VMSelectableSubRace"]     = "Subrace",
    ["ls.VMSelectableClass"]       = "Class",
    ["ls.VMSelectableSubClass"]    = "Subclass",
    ["ls.VMSelectable"]            = "Background",
    ["ls.VMAbilityBonusSelection"] = "Ability Bonus",
    ["ls.VMSelectableCantrip"]     = "Cantrip",
    ["ls.VMSelectableSpell"]       = "Spell",
    ["ls.VMSelectableFeat"]        = "Feat",
}

-- Body type name mapping.
-- The XAML x:Names for body type ListBoxItems are internal identifiers.
local BODY_TYPE_NAMES = {
    female       = "Slim feminine",
    male         = "Slim masculine",
    femaleStrong = "Muscular feminine",
    maleStrong   = "Muscular masculine",
}

-- Status property names to check in dcProps for live status messages.
local STATUS_PROPS = {
    "StatusText", "Status", "ErrorMessage", "Message",
    "InfoText", "WarningText", "EmptyMessage",
}

-- Micro-dictionary for god-object tabs whose name doesn't match the
-- "Selected" .. tabName property suffix.  Add entries ONLY when the
-- standard pattern doesn't work.
local GOD_OBJECT_EXCEPTIONS = {
    -- ["WeirdTabName"] = "SelectedActualPropertyName",
}

-- ---------------------------------------------------------------------------
-- Strip XML-style markup tags from text.
-- Larian uses <LSTag Tooltip="...">visible text</LSTag> in descriptions.
-- This keeps the visible text and removes the tags.
-- Also strips any other XML-like tags (e.g. <br/>, <i>, </i>).
-- ---------------------------------------------------------------------------
local function StripMarkupTags(text)
    if not text then return text end
    -- Single pass: strip ANY tag (including LSTag, br, etc.) and replace
    -- with a space to prevent word collision (e.g. "word<br>word" -> "word word").
    local result = text:gsub("<[^>]+>", " ")
    -- Collapse all whitespace (spaces, tabs, newlines) into single spaces.
    result = result:gsub("%s+", " ")
    -- Trim leading and trailing whitespace.
    return result:match("^%s*(.-)%s*$") or result
end

-- ---------------------------------------------------------------------------
-- Normalize text for comparison: lowercase, strip spaces, hyphens, periods.
-- ---------------------------------------------------------------------------
local function NormalizeForCompare(str)
    if not str then return "" end
    return str:lower():gsub("[%s%-%.]+", "")
end

-- ---------------------------------------------------------------------------
-- Check if data represents an "option item" (has DataContext with "Text").
-- ---------------------------------------------------------------------------
local function IsOptionData(data)
    return data.dcProps and data.dcProps.Text and data.dcProps.Text ~= ""
end

-- ---------------------------------------------------------------------------
-- Clean up an x:Name into readable text.
-- "NewGameButton" -> "New Game", "OptionsButton" -> "Options"
-- Strips common suffixes, inserts spaces at camelCase boundaries.
-- ---------------------------------------------------------------------------
local function CleanElementName(name)
    if not name or name == "" then return nil end
    local cleaned = name
        :gsub("Button$", "")
        :gsub("Btn$", "")
        :gsub("Container$", "")
    if cleaned == "" or #cleaned < 3 then return nil end
    -- Insert spaces at camelCase boundaries: "NewGame" -> "New Game"
    cleaned = cleaned:gsub("(%l)(%u)", "%1 %2")
    -- Insert spaces before sequences of caps followed by lowercase
    cleaned = cleaned:gsub("(%u+)(%u%l)", "%1 %2")
    return cleaned
end

-- ---------------------------------------------------------------------------
-- Clean controller functionality text for speech.
-- Replaces <br> with comma-space, strips remaining HTML tags.
-- ---------------------------------------------------------------------------
local function CleanControllerFunctionality(rawText)
    if not rawText then return nil end
    local cleaned = rawText:gsub("<br>", ", ")
    cleaned = cleaned:gsub("<[^>]+>", " ")
    cleaned = cleaned:gsub("%s+", " ")
    cleaned = cleaned:match("^%s*(.-)%s*$") or cleaned
    return cleaned
end

-- ---------------------------------------------------------------------------
-- Format speech text from a data table's dcProps.
-- Mirrors the old ReadDataContextText: Text + Value, or Title + Description.
-- Returns full text string or nil.
-- ---------------------------------------------------------------------------
local function FormatDCText(dcProps)
    if not dcProps then return nil end

    local text = dcProps.Text
    local value = dcProps.Value
    local desc = dcProps.Description

    -- VMPreset: Title (may be string from LocaString resolution)
    if not text then
        text = dcProps.Title
    end

    -- VMLobby and similar: Name is the primary text property.
    -- Format lobby-style data with player count if available.
    if not text and dcProps.Name then
        text = dcProps.Name
        local currentPlayers = dcProps.CurrentPlayers
        local maxPlayers = dcProps.MaxPlayers
        if currentPlayers and maxPlayers then
            text = text .. ", " .. tostring(currentPlayers) .. " of "
                .. tostring(maxPlayers) .. " players"
        end
        local difficulty = dcProps.Difficulty
        if difficulty and difficulty ~= "" then
            text = text .. ", " .. difficulty
        end
    end

    -- CC skill enum properties: VMCharacterCreationSkill has both Skill
    -- and Ability.  Check Skill FIRST so "Arcana" wins over "Intelligence".
    -- Append the modifier value for context.
    if not text and dcProps.Skill then
        text = dcProps.Skill
        if dcProps.Value then
            local mod = tonumber(dcProps.Value) or 0
            local sign = mod >= 0 and "+" or ""
            value = sign .. tostring(mod)
        end
    end
    -- CC ability enum properties: VMAbility.Ability = "Strength", etc.
    -- Append the ability value and modifier for context.
    if not text and dcProps.Ability then
        text = dcProps.Ability
        if dcProps.Value then
            value = tostring(dcProps.Value)
            if dcProps.Modifier then
                local mod = tonumber(dcProps.Modifier) or 0
                local sign = mod >= 0 and "+" or ""
                value = value .. " (" .. sign .. tostring(mod) .. ")"
            end
        end
    end

    -- DCMessageBox: TitleProperty + TextProperty (Larian naming convention)
    if not text then
        text = dcProps.TitleProperty
    end

    -- LobbyMessage fallback: used as a button label in some contexts
    -- (e.g. "Allow Cross-Play").  Skip status-style messages ("...").
    if not text and dcProps.LobbyMessage then
        local lobbyMessage = dcProps.LobbyMessage
        if type(lobbyMessage) == "string" and lobbyMessage ~= ""
            and lobbyMessage:sub(-3) ~= "..." then
            text = lobbyMessage
        end
    end

    if not text or text == "" then return nil end

    -- SelectedItem: combo boxes (ls.VMComboBoxSetting) store their
    -- current value in a nested sub-object instead of a flat Value prop.
    if not value or value == "" then
        local selItem = dcProps.SelectedItem
        if type(selItem) == "table" then
            value = selItem.Text or selItem.Title or selItem.Name
                or selItem.Label or selItem.DisplayName
        end
    end

    local parts = { text }
    if value and value ~= "" then
        parts[#parts + 1] = ": "
        parts[#parts + 1] = value
    end
    if desc and desc ~= "" then
        parts[#parts + 1] = ". "
        parts[#parts + 1] = desc
    end

    -- TextProperty: dialog body text (DCMessageBox)
    local textProperty = dcProps.TextProperty
    if textProperty and textProperty ~= "" and textProperty ~= text then
        parts[#parts + 1] = ". "
        parts[#parts + 1] = textProperty
    end

    return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- FormatDCTextSplit: returns (name, value, description) as separate strings.
-- Used by the aggregator to put item data into separate speech slots.
-- ---------------------------------------------------------------------------
local function FormatDCTextSplit(dcProps)
    if not dcProps then return nil, nil, nil end

    local text = dcProps.Text
    local value = dcProps.Value
    local desc = dcProps.Description

    if not text then text = dcProps.Title end
    if not text and dcProps.Name then
        text = dcProps.Name
        local currentPlayers = dcProps.CurrentPlayers
        local maxPlayers = dcProps.MaxPlayers
        if currentPlayers and maxPlayers then
            text = text .. ", " .. tostring(currentPlayers) .. " of "
                .. tostring(maxPlayers) .. " players"
        end
        local difficulty = dcProps.Difficulty
        if difficulty and difficulty ~= "" then
            text = text .. ", " .. difficulty
        end
    end
    if not text and dcProps.Skill then
        text = dcProps.Skill
        if dcProps.Value then
            local mod = tonumber(dcProps.Value) or 0
            local sign = mod >= 0 and "+" or ""
            value = sign .. tostring(mod)
        end
    end
    if not text and dcProps.Ability then
        text = dcProps.Ability
        if dcProps.Value then
            value = tostring(dcProps.Value)
            if dcProps.Modifier then
                local mod = tonumber(dcProps.Modifier) or 0
                local sign = mod >= 0 and "+" or ""
                value = value .. " (" .. sign .. tostring(mod) .. ")"
            end
        end
    end
    if not text then text = dcProps.TitleProperty end
    if not text and dcProps.LobbyMessage then
        local lobbyMessage = dcProps.LobbyMessage
        if type(lobbyMessage) == "string" and lobbyMessage ~= ""
            and lobbyMessage:sub(-3) ~= "..." then
            text = lobbyMessage
        end
    end

    if not text or text == "" then return nil, nil, nil end

    -- Value: direct Value prop, or SelectedItem for combo boxes.
    local valueResult = nil
    if value and value ~= "" then
        valueResult = tostring(value)
    else
        local selItem = dcProps.SelectedItem
        if type(selItem) == "table" then
            valueResult = selItem.Text or selItem.Title or selItem.Name
                or selItem.Label or selItem.DisplayName
        end
    end

    -- Description
    local descParts = {}
    if desc and desc ~= "" then
        descParts[#descParts + 1] = desc
    end
    local textProperty = dcProps.TextProperty
    if textProperty and textProperty ~= "" and textProperty ~= text then
        descParts[#descParts + 1] = textProperty
    end
    local descResult = #descParts > 0 and table.concat(descParts, ". ") or nil

    return text, valueResult, descResult
end

-- ---------------------------------------------------------------------------
-- Format value-only text from dcProps (for INPC "value changed" speech).
-- Returns just the value part, not the full "Name: Value" string.
-- ---------------------------------------------------------------------------
local function FormatDCValue(dcProps)
    if not dcProps then return nil end

    local value = dcProps.Value
    if value and value ~= "" then return value end

    -- ComboBox: SelectedItem text
    local selItem = dcProps.SelectedItem
    if type(selItem) == "table" then
        local selText = selItem.Text or selItem.Title or selItem.Name
            or selItem.Label or selItem.DisplayName
        if selText and selText ~= "" then return selText end
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Check status properties in dcProps for non-focusable status messages.
-- ---------------------------------------------------------------------------
local function ExtractStatusText(dcProps)
    if not dcProps then return nil end
    for _, propName in ipairs(STATUS_PROPS) do
        local val = dcProps[propName]
        if val and val ~= "" then return val end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- God-Object Extraction via Tab Context.
--
-- For complex menus (e.g. Character Creation) where the DataContext is a
-- god object with 100+ properties, generic FormatDCText finds nothing
-- useful.  This function uses the current tab name to dynamically
-- construct the correct property key.
--
-- Larian convention: tab "Origin" -> dcProps.SelectedOrigin (sub-table),
-- tab "Race" -> dcProps.SelectedRace, etc.
--
-- Returns titleText, bodyText (either or both may be nil).
-- ---------------------------------------------------------------------------
local function ExtractContextualGodObjectText(dcProps, currentTab)
    if not dcProps or not currentTab then return nil, nil end

    local tabKey = currentTab:gsub("[%s%-%.]+", "")

    local titleText = nil
    local bodyText = nil

    -- 1. Look for the active Selected[Tab] sub-object
    local selectedKey = "Selected" .. tabKey
    local activeObject = dcProps[selectedKey]

    -- Try the exceptions table if exact match fails.
    if not activeObject and GOD_OBJECT_EXCEPTIONS[tabKey] then
        selectedKey = GOD_OBJECT_EXCEPTIONS[tabKey]
        activeObject = dcProps[selectedKey]
    end

    -- Extract title from the matched sub-object's scalar properties.
    if type(activeObject) == "table" then
        titleText = activeObject.Name or activeObject.DisplayName
                 or activeObject.Title or activeObject.Text
        if titleText and titleText ~= "" then
            Log.Debug("GodObject: tab '" .. currentTab
                .. "' matched '" .. selectedKey .. "' -> " .. titleText)
        else
            titleText = nil
            if Log.IsDebug() then
                local subKeys = {}
                for subKey, subVal in pairs(activeObject) do
                    local valStr = tostring(subVal)
                    if #valStr > 60 then valStr = valStr:sub(1, 60) .. "..." end
                    table.insert(subKeys, subKey .. "=" .. valStr)
                end
                table.sort(subKeys)
                Log.Debug("GodObject: matched '" .. selectedKey
                    .. "' but no Name/DisplayName/Title/Text. Keys: "
                    .. table.concat(subKeys, " | "))
            end
        end
    end

    -- 2. Look for contextual description string
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

-- ---------------------------------------------------------------------------
-- Extract speech text from a data table.
-- Priority: dcProps (ViewModel text) > elemText (rendered text).
--
-- lastSpokenTab and tabFlushPending are passed in as parameters so this
-- function stays pure (no module state references).
-- Returns text string or nil.
-- ---------------------------------------------------------------------------
local function ExtractTextFromData(data, lastSpokenTab, tabFlushPending)
    if not data then return nil end

    -- Smart god-object heuristic: use tab context to pluck the right
    -- sub-object from complex DataContexts (e.g. DCCharacterCreation).
    -- ONLY fires during auto-focus (tabFlushPending=true).
    if lastSpokenTab and data.dcProps and tabFlushPending then
        local godTitle, godBody = ExtractContextualGodObjectText(data.dcProps, lastSpokenTab)
        if godTitle and godTitle ~= "" then
            if godBody and godBody ~= "" then
                return godTitle .. ". " .. godBody
            end
            return godTitle
        end
    end

    -- Try ViewModel properties first (most elements have DataContext)
    local dcText = FormatDCText(data.dcProps)
    if dcText and dcText ~= "" then return dcText end

    -- Fall back to element's own text (TextBlock, Content, ToString)
    if data.elemText and data.elemText ~= "" then return data.elemText end

    -- Last resort: clean up the element's x:Name into readable text.
    return CleanElementName(data.elemName)
end

-- ---------------------------------------------------------------------------
-- Get the CC section label for a data table, with subrace detection.
-- Returns the section name string or nil.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- Get a body type display name from an element name, or nil.
-- ---------------------------------------------------------------------------
local function GetBodyTypeName(elemName)
    if not elemName then return nil end
    return BODY_TYPE_NAMES[elemName]
end

-- ---------------------------------------------------------------------------
-- Attach to global namespace so other modules can access via BG3Access.Client.Helpers.
-- ---------------------------------------------------------------------------
BG3Access.Client.Helpers = {
    StripMarkupTags                  = StripMarkupTags,
    NormalizeForCompare              = NormalizeForCompare,
    IsOptionData                     = IsOptionData,
    CleanElementName                 = CleanElementName,
    CleanControllerFunctionality     = CleanControllerFunctionality,
    FormatDCText                     = FormatDCText,
    FormatDCTextSplit                = FormatDCTextSplit,
    FormatDCValue                    = FormatDCValue,
    ExtractStatusText                = ExtractStatusText,
    ExtractContextualGodObjectText   = ExtractContextualGodObjectText,
    ExtractTextFromData              = ExtractTextFromData,
    GetSectionLabel                  = GetSectionLabel,
    GetBodyTypeName                  = GetBodyTypeName,
    CC_SECTION_LABELS                = CC_SECTION_LABELS,
    BODY_TYPE_NAMES                  = BODY_TYPE_NAMES,
}
