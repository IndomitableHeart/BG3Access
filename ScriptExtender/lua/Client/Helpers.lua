-- File: Client/Helpers.lua
--
-- Pure utility functions for BG3Access speech formatting and text extraction.
-- None of these functions reference module-level state variables.  They take
-- data in and return data out, making them safe to call from any context.
--
-- CC-specific logic lives in CharCreation.lua.  This file is generic only.

local Log = BG3Access.Client.Log

-- Forward declarations for functions referenced before definition.
local ResolveDescriptionParams

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

-- Level code to display name for multiplayer lobbies.  The game's
-- TranslatedStringConverter with LocaKey resolves these visually,
-- but Ext.Loca.GetTranslatedString does not find them.  Verified
-- against the in-game lobby browser Location column.
local LEVEL_DISPLAY_NAMES = {
    ["WLD_Main_A"]            = "Wilderness",
    ["SCL_Main_A"]            = "Shadow-Cursed Lands",
    ["CTY_Main_A"]            = "Baldur's Gate",
    ["BGO_Main_A"]            = "Wyrm's Crossing",
    ["CRE_Main_A"]            = "Githyanki Creche",
    ["TUT_Avernus_C"]         = "A Nautiloid in Hell",
    ["SYS_Menuscreen_Camp_A"] = "Character Creation",
}

-- Status property names to check in dcProps for live status messages.
local STATUS_PROPS = {
    "StatusText", "Status", "ErrorMessage", "Message",
    "InfoText", "WarningText", "EmptyMessage",
}

-- ---------------------------------------------------------------------------
-- Strip XML-style markup tags from text.
-- Larian uses <LSTag Tooltip="...">visible text</LSTag> in descriptions.
-- This keeps the visible text and removes the tags.
-- Also strips any other XML-like tags (e.g. <br/>, <i>, </i>).
-- ---------------------------------------------------------------------------
local function StripMarkupTags(text)
    if not text then return text end
    -- Replace each tag with a space so adjacent words don't smash
    -- together (e.g., "an<LSTag>Attack Roll</LSTag>" -> "an Attack Roll").
    local result = text:gsub("<[^>]+>", " ")
    -- Collapse multiple spaces into one.
    result = result:gsub("%s+", " ")
    -- Strip whitespace that ended up immediately BEFORE common
    -- punctuation: when the original was "...<LSTag>X</LSTag>, ..." the
    -- tag-strip produced "...X , ...", which screen readers verbalize
    -- with an awkward pause-before-comma.  Removes spaces preceding
    -- comma, period, semicolon, colon, exclamation, question mark.
    result = result:gsub("%s+([%.,;:!%?])", "%1")
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
local FILTERED_ELEMENT_NAMES = {
    base = true,
    root = true,
    content = true,
    panel = true,
    wrapper = true,
    container = true,
}

local function CleanElementName(name)
    if not name or name == "" then return nil end
    if FILTERED_ELEMENT_NAMES[name:lower()] then return nil end
    local cleaned = name
        :gsub("Button$", "")
        :gsub("Btn$", "")
        :gsub("Container$", "")
    if cleaned == "" or #cleaned < 3 then return nil end
    cleaned = cleaned:gsub("(%l)(%u)", "%1 %2")
    cleaned = cleaned:gsub("(%u+)(%u%l)", "%1 %2")
    return cleaned
end

-- ---------------------------------------------------------------------------
-- Clean controller functionality text for speech.
-- ---------------------------------------------------------------------------
local function CleanControllerFunctionality(rawText)
    if not rawText then return nil end
    local cleaned = rawText:gsub("<br>", ", ")
    cleaned = cleaned:gsub("<[^>]+>", " ")
    cleaned = cleaned:gsub("%s+", " ")
    cleaned = cleaned:match("^%s*(.-)%s*$") or cleaned
    return cleaned
end

-- Resolve a LocaString handle to translated text, or return the input as-is.
local function GetTranslatedStringIfHandle(textOrHandle, logContextStringOptional)
    if not textOrHandle or type(textOrHandle) ~= "string" or textOrHandle == "" then
        return textOrHandle
    end
    if Ext.Loca and Ext.Loca.GetTranslatedString then
        local translated = Ext.Loca.GetTranslatedString(textOrHandle)
        if translated and translated ~= "" and translated ~= textOrHandle then
            return translated
        end
    end
    return textOrHandle
end

-- ---------------------------------------------------------------------------
-- Format speech text from a data table's dcProps.
-- Returns full text string or nil.
-- ---------------------------------------------------------------------------
local function FormatDCText(dcProps)
    if not dcProps then return nil end

    local text = dcProps.Text
    local value = dcProps.Value
    local desc = dcProps.Description

    if not text then text = dcProps.Title end

    -- Character assignment player slots (VMCharacterAssignPlayerSlot):
    -- prefer Player.Name over the Roman numeral slot Name.
    if not text and dcProps.Player and type(dcProps.Player) == "table" then
        local playerName = dcProps.Player.Name
        if type(playerName) == "string" and playerName ~= "" then
            text = playerName
            if dcProps.IsHost then
                text = text .. " (Host)"
            end
        end
    end
    -- Slot state when no player assigned ("Open" / "Closed").
    if not text and type(dcProps.State) == "string"
        and dcProps.State ~= "" then
        local slotLabel = dcProps.Name
        if type(slotLabel) == "string" and slotLabel ~= "" then
            text = "Slot " .. slotLabel .. ": " .. dcProps.State
        else
            text = dcProps.State
        end
    end
    -- Character assignment character slots (VMCharacterAssignCharacterSlot).
    if not text and dcProps.Character
        and type(dcProps.Character) == "table" then
        local charName = dcProps.Character.CharacterName
            or dcProps.Character.Name
            or dcProps.Character.DisplayName
            or dcProps.Character.Title
        if type(charName) == "string" and charName ~= "" then
            text = charName
        end
    end
    -- VMLobby and similar: Name is the primary text property.
    if not text and dcProps.Name then
        text = dcProps.Name
        local currentPlayers = dcProps.CurrentPlayers
        local maxPlayers = dcProps.MaxPlayers
        if currentPlayers and maxPlayers then
            text = text .. ", " .. tostring(currentPlayers) .. " of "
                .. tostring(maxPlayers) .. " players"
        end
        -- Map is a LocaKey — resolve via Loca, fall back to known
        -- level codes, then raw code.
        local map = dcProps.Map
        if type(map) == "string" and map ~= "" then
            local mapDisplay = GetTranslatedStringIfHandle(map)
            if mapDisplay == map then
                mapDisplay = LEVEL_DISPLAY_NAMES[map] or map
            end
            text = text .. ", " .. mapDisplay
        end
        local partyLevel = dcProps.PartyLevel
        if partyLevel and partyLevel ~= "" then
            text = text .. ", Level " .. tostring(partyLevel)
        end
    end

    -- DCMessageBox: TitleProperty + TextProperty (Larian naming convention)
    if not text then text = dcProps.TitleProperty end

    -- LobbyMessage fallback.
    if not text and dcProps.LobbyMessage then
        local lobbyMessage = dcProps.LobbyMessage
        if type(lobbyMessage) == "string" and lobbyMessage ~= ""
            and lobbyMessage:sub(-3) ~= "..." then
            text = lobbyMessage
        end
    end

    if not text or text == "" then return nil end

    -- SelectedItem: combo boxes store value in a nested sub-object.
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

    local textProperty = dcProps.TextProperty
    if textProperty and textProperty ~= "" and textProperty ~= text then
        parts[#parts + 1] = ". "
        parts[#parts + 1] = textProperty
    end

    return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- FormatDCTextSplit: returns (name, value, description) as separate strings.
-- ---------------------------------------------------------------------------
local function FormatDCTextSplit(dcProps, dcType)
    if not dcProps then return nil, nil, nil end

    local text = dcProps.Text
    local value = dcProps.Value
    local desc = dcProps.Description

    -- DC sub-objects: Text, Value, Description may be tables (LocaString,
    -- ViewModel sub-objects) instead of strings.  Extract the string content.
    if type(text) == "table" then
        text = text.Str or text.Text or text.Title or text.Name or nil
    end
    if type(value) == "table" then
        value = value.Str or value.Text or value.Name or nil
    end
    if type(desc) == "table" then
        desc = desc.Str or desc.Text or desc.Description or nil
    end

    if not text and dcProps.Title then
        text = dcProps.Title
        -- Savegame items: return location and difficulty as separate
        -- fields (value, desc) instead of concatenating into the name.
        -- This enables proper semantic field tracking (spokenValues).
        local levelName = dcProps.LevelName
        if type(levelName) == "string" and levelName ~= "" then
            if not value then
                value = levelName
            else
                text = text .. ", " .. levelName
            end
        end
        local difficulty = dcProps.Difficulty
        if type(difficulty) == "string" and difficulty ~= "" then
            if not desc then
                desc = difficulty
            else
                value = (value or "") .. ", " .. difficulty
            end
        end
    end
    -- Character assignment player slots (VMCharacterAssignPlayerSlot):
    -- Player.Name is the display name of the connected player.  This
    -- must be checked BEFORE dcProps.Name, which is the Roman numeral
    -- slot identifier ("I", "II", etc.) and is not useful on its own.
    if not text and dcProps.Player and type(dcProps.Player) == "table" then
        local playerName = dcProps.Player.Name
        if type(playerName) == "string" and playerName ~= "" then
            text = playerName
        end
    end
    -- Slot state when no player is assigned ("Open" / "Closed").
    -- Pair with the Roman numeral slot label so the user knows the slot.
    if not text and type(dcProps.State) == "string"
        and dcProps.State ~= "" then
        local slotLabel = dcProps.Name
        if type(slotLabel) == "string" and slotLabel ~= "" then
            text = "Slot " .. slotLabel .. ": " .. dcProps.State
        else
            text = dcProps.State
        end
    end
    -- Character assignment character slots (VMCharacterAssignCharacterSlot):
    -- Character is a sub-object containing the assigned character's info.
    if not text and dcProps.Character
        and type(dcProps.Character) == "table" then
        local charName = dcProps.Character.CharacterName
            or dcProps.Character.Name
            or dcProps.Character.DisplayName
            or dcProps.Character.Title
        if type(charName) == "string" and charName ~= "" then
            text = charName
        end
    end
    if not text and dcProps.Name then
        text = dcProps.Name
        local currentPlayers = dcProps.CurrentPlayers
        local maxPlayers = dcProps.MaxPlayers
        if currentPlayers and maxPlayers then
            text = text .. ", " .. tostring(currentPlayers) .. " of "
                .. tostring(maxPlayers) .. " players"
        end
        -- Map is a LocaKey — resolve via Loca, fall back to known
        -- level codes, then raw code.
        local map = dcProps.Map
        if type(map) == "string" and map ~= "" then
            local mapDisplay = GetTranslatedStringIfHandle(map)
            if mapDisplay == map then
                mapDisplay = LEVEL_DISPLAY_NAMES[map] or map
            end
            text = text .. ", " .. mapDisplay
        end
        local partyLevel = dcProps.PartyLevel
        if partyLevel and partyLevel ~= "" then
            text = text .. ", Level " .. tostring(partyLevel)
        end
    end
    if not text then text = dcProps.TitleProperty end
    -- Playthrough holders (save game groups): use ProtagonistName and
    -- LatestSave sub-object for distinguishing info.
    if not text and dcProps.ProtagonistName then
        text = dcProps.ProtagonistName
        local latestSave = dcProps.LatestSave
        if type(latestSave) == "table" then
            local saveTitle = latestSave.Title
            if type(saveTitle) == "string" and saveTitle ~= "" then
                text = text .. ", " .. saveTitle
            end
            local levelName = latestSave.LevelName
            if type(levelName) == "string" and levelName ~= "" then
                text = text .. ", " .. levelName
            end
            local timeString = latestSave.TimeString
            if type(timeString) == "string" and timeString ~= "" then
                text = text .. ", " .. timeString
            end
        end
    end
    if not text and dcProps.LobbyMessage then
        local lobbyMessage = dcProps.LobbyMessage
        if type(lobbyMessage) == "string" and lobbyMessage ~= ""
            and lobbyMessage:sub(-3) ~= "..." then
            text = lobbyMessage
        end
    end
    -- VMResistance (Examine panel resistance rows): DamageType is an
    -- enum whose symbolic name is the damage type (Piercing, etc.).
    -- Full/NonMagical/Magical give the resistance level (Resistant,
    -- Immune, Vulnerable).  The C++ enum lookup can't resolve all
    -- values -- 255 is Vulnerable (not in the Noesis enum mapping).
    if not text and dcProps.DamageType then
        text = tostring(dcProps.DamageType)
        local resistanceLevel = dcProps.Full
        -- Map unresolved enum values to display names.
        if resistanceLevel == "255" then
            resistanceLevel = "Vulnerable"
        end
        if type(resistanceLevel) == "string"
            and resistanceLevel ~= "None" then
            value = resistanceLevel
        end
    end

    if not text or text == "" then return nil, nil, nil end

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
    -- VMCustomSettingCombobox: SelectedValue sub-object with Name.
    if not valueResult then
        local selectedValue = dcProps.SelectedValue
        if type(selectedValue) == "table" then
            local selectedName = selectedValue.Name or selectedValue.Text
                or selectedValue.Title
            if type(selectedName) == "string" and selectedName ~= "" then
                valueResult = selectedName
            end
        elseif type(selectedValue) == "string" and selectedValue ~= "" then
            valueResult = selectedValue
        end
    end

    local descParts = {}
    if type(desc) == "string" and desc ~= "" then
        descParts[#descParts + 1] = desc
    end
    local textProperty = dcProps.TextProperty
    if type(textProperty) == "string" and textProperty ~= "" and textProperty ~= text then
        descParts[#descParts + 1] = textProperty
    end
    -- Host indicator for character assignment player slots.
    -- Only add when Player sub-object exists (multiplayer character assign),
    -- not on every screen that happens to have IsHost (e.g., difficulty).
    if dcProps.IsHost and dcProps.Player then
        descParts[#descParts + 1] = "Host"
    end
    -- Warning for custom difficulty settings that are locked after game start.
    if dcProps.EditableInGame == "Off" then
        local warningText = GetTranslatedStringIfHandle(
            "h3c46af69gfe72g49f1gb524g8bf318295dc3")
        if warningText and warningText ~= ""
            and warningText ~= "h3c46af69gfe72g49f1gb524g8bf318295dc3" then
            descParts[#descParts + 1] = warningText
        end
    end
    -- SelectedValue description for combobox items (e.g., difficulty
    -- presets: "Balanced" has "Enemies will provide a balanced challenge").
    -- Returned as a 4th value so callers can place it after the value name.
    local valueDescResult = nil
    if dcProps.SelectedValue and type(dcProps.SelectedValue) == "table" then
        local selectedDesc = dcProps.SelectedValue.Description
        if type(selectedDesc) == "string" and selectedDesc ~= "" then
            valueDescResult = selectedDesc
        end
    end
    -- Strip trailing periods/spaces from each part to avoid ".." when joined.
    for descIndex = 1, #descParts do
        descParts[descIndex] = descParts[descIndex]:gsub("[%.%s]+$", "")
    end
    local descResult = #descParts > 0 and table.concat(descParts, ". ") or nil

    return text, valueResult, descResult, valueDescResult
end

-- ---------------------------------------------------------------------------
-- Format value-only text from dcProps (for INPC "value changed" speech).
-- ---------------------------------------------------------------------------
local function FormatDCValue(dcProps)
    if not dcProps then return nil end

    local value = dcProps.Value
    if value and value ~= "" then return tostring(value) end

    local selItem = dcProps.SelectedItem
    if type(selItem) == "table" then
        local selText = selItem.Text or selItem.Title or selItem.Name
            or selItem.Label or selItem.DisplayName
        if selText and selText ~= "" then return selText end
    end

    -- VMCustomSettingCombobox: SelectedValue sub-object with Name + Description.
    local selectedValue = dcProps.SelectedValue
    if type(selectedValue) == "table" then
        local selectedName = selectedValue.Name or selectedValue.Text
            or selectedValue.Title
        if type(selectedName) == "string" and selectedName ~= "" then
            local selectedDesc = selectedValue.Description
            if type(selectedDesc) == "string" and selectedDesc ~= "" then
                return selectedName .. ". " .. selectedDesc
            end
            return selectedName
        end
    elseif type(selectedValue) == "string" and selectedValue ~= "" then
        return selectedValue
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
-- Extract speech text from a data table.
-- Priority: dcProps (ViewModel text) > elemText (rendered text).
-- ---------------------------------------------------------------------------
local function ExtractTextFromData(data, currentTabContext, tabFlushPending)
    if not data then return nil end

    local dcText = FormatDCText(data.dcProps)
    if dcText and dcText ~= "" then return dcText end

    if data.elemText and data.elemText ~= "" then return data.elemText end

    -- Check namedTexts for a title or header element.  Container elements
    -- (e.g., ContentControl wrapping a savegames list) may have no dcProps or
    -- elemText but expose a TitleText named element that identifies the screen.
    if data.namedTexts then
        for elementName, elementText in pairs(data.namedTexts) do
            local nameLower = elementName:lower()
            if (nameLower:find("title") or nameLower:find("header")
                or nameLower == "tabname")
                and elementText and elementText ~= "" then
                return elementText
            end
        end
    end

    return CleanElementName(data.elemName)
end

-- ---------------------------------------------------------------------------
-- Diagnostic: dump UI widget info using safe Ext.UI bridge functions.
-- Logs the topmost widget and focused element with DC type info.
-- For full widget enumeration, use the C++ widget scan logs (Initial
-- widget scan) which already iterate all widgets with SEH guards.
-- Call from anywhere: H.DumpWidgets() or H.DumpWidgets("optional label")
-- ---------------------------------------------------------------------------
local function DumpWidgets(label)
    local tag = label or "WIDGET DUMP"

    -- Topmost widget via safe C++ function.
    local topWidget = nil
    pcall(function() topWidget = Ext.UI.GetTopmostWidget() end)
    if topWidget then
        local dcType = "(none)"
        pcall(function()
            local dataContext = topWidget.DataContext
            if dataContext then
                dcType = dataContext:GetClassType().TypeName or "(unknown)"
            end
        end)
        local widgetName = "(unnamed)"
        pcall(function() widgetName = topWidget.Name or "(unnamed)" end)
        Log.Info(tag .. " topmost: name=" .. widgetName .. " DC=" .. dcType)
    else
        Log.Info(tag .. " topmost: nil")
    end

    -- Focused element via safe C++ function.
    local focusedElement = nil
    pcall(function() focusedElement = Ext.UI.GetFocusedElement() end)
    if focusedElement then
        local dcType = "(none)"
        pcall(function()
            local dataContext = focusedElement.DataContext
            if dataContext then
                dcType = dataContext:GetClassType().TypeName or "(unknown)"
            end
        end)
        local elemName = "(unnamed)"
        pcall(function() elemName = focusedElement.Name or "(unnamed)" end)
        Log.Info(tag .. " focused: name=" .. elemName .. " DC=" .. dcType)
    else
        Log.Info(tag .. " focused: nil")
    end

    -- Force the C++ to re-scan widgets which logs all widget details.
    pcall(function() Ext.UI.ForceGlobalFocusUpdate() end)
    Log.Info(tag .. " forced widget re-scan (check C++ logs for full list)")
end

-- ---------------------------------------------------------------------------
-- Stat description resolution (shared by CC and World modules).
-- ---------------------------------------------------------------------------

-- Level map values for description parameter resolution.
-- Maps LevelMapValue keys to dice expressions.
-- TODO: level-aware lookup based on character level (currently assumes level 1).
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

--- ParseDescriptionParam: extract a human-readable value from a
--- DescriptionParams expression.
--- E.g., "DealDamage(1d8,Necrotic)" -> "1d8 Necrotic damage"
---       "ApplyStatus(BURNING,100,1)" -> "Burning"
---       "RegainHitPoints(1d8)" -> "1d8"
---       "LevelMapValue(D8Cantrip)" -> "1d8"
---       "Distance(12)" -> "12m"
local function ParseDescriptionParam(expression)
    if not expression or expression == "" then return nil end

    local dice, damageType = expression:match("DealDamage%(([^,]+),([^,)]+)")
    if dice and damageType then
        local levelMapKey = dice:match("LevelMapValue%(([^)]+)%)")
        if levelMapKey and LEVEL_MAP_VALUES[levelMapKey] then
            dice = LEVEL_MAP_VALUES[levelMapKey]
        end
        return dice .. " " .. damageType .. " damage"
    end

    local levelMapKey = expression:match("LevelMapValue%(([^)]+)%)")
    if levelMapKey then
        local resolved = LEVEL_MAP_VALUES[levelMapKey]
        if resolved then return resolved end
        return levelMapKey
    end

    local healDice = expression:match("RegainHitPoints%(([^)]+)%)")
    if healDice then return healDice end

    local statusName = expression:match("ApplyStatus%(([^,]+)")
    if statusName then
        return statusName:gsub("_", " "):lower():gsub("^%l", string.upper)
    end

    local distance = expression:match("Distance%(([^)]+)%)")
    if distance then return distance .. "m" end

    if expression:match("^%d+d?%d*$") then
        return expression
    end

    return nil
end

--- ResolveDescriptionParams: replace [1], [2], etc. in a description
--- using DescriptionParams from a stat entry.
--- @param text string  The description text with [N] placeholders.
--- @param stat table|nil  The stat object (for stat.DescriptionParams).
--- @param paramsString string|nil  Direct params string override.
--- @return string|nil  Text with params substituted.
ResolveDescriptionParams = function(text, stat, paramsString)
    if not text then return nil end
    if not text:find("%[%d+%]") then return text end

    local rawParams = paramsString
    if not rawParams and stat then
        local paramSuccess, paramValue = pcall(function()
            return stat.DescriptionParams
        end)
        if paramSuccess and type(paramValue) == "string" then
            rawParams = paramValue
        end
    end

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

    local result = text:gsub("%[(%d+)%]", function(numStr)
        local paramIndex = tonumber(numStr)
        if paramIndex and params[paramIndex] then
            return params[paramIndex]
        end
        return ""
    end)

    result = result:gsub("  +", " "):match("^%s*(.-)%s*$")
    if result == "" then return nil end
    return result
end

--- ReadStatDescription: safely read and resolve a stat entry's Description.
--- Handles pcall, TranslatedString types (string/userdata/table),
--- Loca resolution, and parameter substitution.
--- @param stat table  A stat object from Ext.Stats.Get().
--- @return string|nil  Resolved description text, or nil.
local function ReadStatDescription(stat)
    if not stat then return nil end
    local propSuccess, propValue = pcall(function()
        return stat.Description
    end)
    if not propSuccess or not propValue then return nil end

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
        local resolved = GetTranslatedStringIfHandle(handle)
        if resolved and resolved ~= "" then
            return ResolveDescriptionParams(resolved, stat)
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Description lookup caches (shared by CC, WorldUI, and any future modules).
-- All caches build lazily on first access from game APIs.
-- ---------------------------------------------------------------------------

--- Check whether a "resolved" string is actually a failed-resolve
--- sentinel that should be rejected.  Two patterns:
---   * `^h%x` -- raw handle ("h1234abcd5678") leaked through unchanged
---   * `s_HandleUnknown` substring -- BG3SE's sentinel for "the loca
---     repository had no entry for this handle"; comes back as
---     `ls::TranslatedStringRepository::s_HandleUnknown`
--- Either pattern means we got no real text; callers should skip.
local function IsFailedResolve(text)
    if type(text) ~= "string" or text == "" then return true end
    if text:match("^h%x") then return true end
    if text:find("s_HandleUnknown", 1, true) then return true end
    return false
end

--- ResolveTranslatedString: resolve a TranslatedString from a cached
--- prototype's DescriptionInfo.  Handles string, userdata, and table formats.
--- @param translatedString any  String, userdata, or table with Handle.
--- @return string|nil  Resolved text, or nil.
local function ResolveTranslatedString(translatedString)
    if not translatedString then return nil end
    local stringType = type(translatedString)
    if stringType == "string" and translatedString ~= "" then
        local resolved = GetTranslatedStringIfHandle(translatedString)
        if not IsFailedResolve(resolved) then return resolved end
        return nil
    elseif stringType == "userdata" then
        local handleSuccess, handle = pcall(function()
            return translatedString.Handle.Handle
        end)
        if handleSuccess and handle then
            local handleStr = tostring(handle)
            if handleStr and handleStr ~= "" then
                local resolved = GetTranslatedStringIfHandle(handleStr)
                if not IsFailedResolve(resolved) then
                    return resolved
                end
            end
        end
        local valueSuccess, value = pcall(function()
            return translatedString.Value
        end)
        if valueSuccess and type(value) == "string"
            and not IsFailedResolve(value) then
            return value
        end
        return nil
    elseif stringType == "table" then
        if translatedString.Handle
            and translatedString.Handle.Handle then
            local resolved = GetTranslatedStringIfHandle(
                translatedString.Handle.Handle)
            if not IsFailedResolve(resolved) then
                return resolved
            end
        end
        for _, key in ipairs({"Value", "Name", "Str"}) do
            if type(translatedString[key]) == "string"
                and not IsFailedResolve(translatedString[key]) then
                return translatedString[key]
            end
        end
    end
    return nil
end

-- Spell description cache: display name -> resolved description.
local spellDescriptionCache = {}
local spellCacheBuilt = false

local function BuildSpellDisplayNameCache()
    if spellCacheBuilt then return end
    spellCacheBuilt = true
    local success, allSpellIds = pcall(Ext.Stats.GetStats, "SpellData")
    if not success or not allSpellIds then return end
    for _, statId in ipairs(allSpellIds) do
        pcall(function()
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
    end
end

--- LookupSpellDescription: resolve a spell's description by display name.
--- @param spellName string  The spell's display name.
--- @return string|nil  Resolved description, or nil.
local function LookupSpellDescription(spellName)
    if not spellName or spellName == "" then return nil end
    BuildSpellDisplayNameCache()
    return spellDescriptionCache[spellName:lower()]
end

-- Passive description cache: display name -> resolved description.
local passiveDescriptionCache = {}
local passiveCacheBuilt = false

local function BuildPassiveDisplayNameCache()
    if passiveCacheBuilt then return end
    passiveCacheBuilt = true
    local success, allPassiveIds = pcall(Ext.Stats.GetStats, "PassiveData")
    if not success or not allPassiveIds then return end
    for _, statId in ipairs(allPassiveIds) do
        pcall(function()
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
    end
end

-- Progression description cache: display name -> description.
local progressionDescriptionCache = {}
local progressionCacheBuilt = false

local function BuildProgressionDescriptionCache()
    if progressionCacheBuilt then return end
    progressionCacheBuilt = true
    local guidsSuccess, guids = pcall(
        Ext.StaticData.GetAll, "ProgressionDescription")
    if not guidsSuccess or not guids then return end
    for _, guid in ipairs(guids) do
        pcall(function()
            local entry = Ext.StaticData.Get(guid, "ProgressionDescription")
            if not entry then return end
            if entry.Hidden then return end
            local displayName = ResolveTranslatedString(entry.DisplayName)
            if not displayName then return end
            local description = ResolveTranslatedString(entry.Description)
            if not description then return end
            description = StripMarkupTags(description)
            local normalizedName = displayName:lower()
            if not progressionDescriptionCache[normalizedName] then
                progressionDescriptionCache[normalizedName] = description
            end
        end)
    end
end

-- StaticData description cache: keyed by type, then display name.
local staticDataDescriptionCaches = {}
local staticDataCacheBuilt = {}

local function BuildStaticDataDescriptionCache(staticDataType)
    if staticDataCacheBuilt[staticDataType] then return end
    staticDataCacheBuilt[staticDataType] = true
    staticDataDescriptionCaches[staticDataType] = {}
    local cache = staticDataDescriptionCaches[staticDataType]
    local guidsSuccess, guids = pcall(
        Ext.StaticData.GetAll, staticDataType)
    if not guidsSuccess or not guids then return end
    for _, guid in ipairs(guids) do
        pcall(function()
            local entry = Ext.StaticData.Get(guid, staticDataType)
            if not entry then return end
            local displayName = ResolveTranslatedString(entry.DisplayName)
            if not displayName then return end
            local description = ResolveTranslatedString(entry.Description)
            if not description then return end
            description = StripMarkupTags(description)
            local normalizedName = displayName:lower()
            if not cache[normalizedName] then
                cache[normalizedName] = description
            end
        end)
    end
end

--- LookupStaticDataDescription: look up description by display name
--- from a StaticData type cache (Race, ClassDescription, Background, etc.).
--- @param staticDataType string  The StaticData type name.
--- @param displayName string  The entry's display name.
--- @return string|nil  Description text, or nil.
local function LookupStaticDataDescription(staticDataType, displayName)
    if not staticDataType or not displayName or displayName == "" then
        return nil
    end
    BuildStaticDataDescriptionCache(staticDataType)
    local cache = staticDataDescriptionCaches[staticDataType]
    if not cache then return nil end
    return cache[displayName:lower()]
end

--- LookupFeatureDescription: cascading lookup for passive features.
--- Searches passive cache (with fuzzy matching for proficiency variants),
--- then spell cache, then progression descriptions.
--- @param featureName string  The feature's display name.
--- @return string|nil  Resolved description, or nil.
local function LookupFeatureDescription(featureName)
    if not featureName or featureName == "" then return nil end
    BuildPassiveDisplayNameCache()
    local normalizedLookup = featureName:lower()
    local cached = passiveDescriptionCache[normalizedLookup]
    if cached then return cached end

    -- Fuzzy match: summary panel uses short names ("Rapiers") while
    -- the passive cache has "Rapier Proficiency".  Try variations.
    local singular = featureName:gsub("s$", "")
    local withoutProf = featureName:gsub(" Proficiency$", "")
    local variations = {
        featureName .. " Proficiency",
        singular .. " Proficiency",
        singular,
        withoutProf,
    }
    for _, variant in ipairs(variations) do
        local variantDesc = passiveDescriptionCache[variant:lower()]
        if variantDesc then return variantDesc end
    end

    -- Spell lookup for spell-type features (Rage, Produce Flame).
    local spellDesc = LookupSpellDescription(featureName)
    if spellDesc then return spellDesc end

    -- Progression descriptions: category proficiencies, saving throws.
    BuildProgressionDescriptionCache()
    local progressionDesc = progressionDescriptionCache[normalizedLookup]
    if progressionDesc then return progressionDesc end

    return nil
end

-- ---------------------------------------------------------------------------
-- Speech slot assembly (shared by all menu handlers and CC).
-- ---------------------------------------------------------------------------

-- Slot names in the order they should be spoken.
-- Standard DCMessageBox button hint.  Noesis Indie SDK crashes when
-- enumerating the Actions IList collection from C++, so we handle
-- button hints in Lua based on the dialog DC type.
local DIALOG_BUTTON_HINT = "Press A to confirm, or B to cancel"

-- SpeechData moved to Client/SpeechData.lua (loaded before Helpers).

--- ExtractFromNamedTexts: extract title and body parts from named text entries.
--- @param namedTexts table|nil  Map of elementName -> elementText.
--- @return string|nil titleText, table bodyParts
local function ExtractFromNamedTexts(namedTexts)
    if not namedTexts then return nil, {} end
    local titleText = nil
    local bodyParts = {}
    for elementName, elementText in pairs(namedTexts) do
        -- Skip unresolved LocaString handles and ForceUpdate placeholders.
        if elementText:match("^h%x+g")
            or elementText:find("%[ForceUpdate%]")
            or elementText:find("s_HandleUnknown") then
            goto nextNamedText
        end
        local nameLower = elementName:lower()
        if nameLower:find("title") or nameLower:find("header")
            or nameLower == "tabname" then
            if not titleText then titleText = elementText end
        elseif nameLower:find("body") or nameLower:find("description")
            or nameLower:find("message") or nameLower:find("warning")
            or nameLower:find("busy") or nameLower:find("status")
            or nameLower:find("info")
            or nameLower:find("^_visualtext") then
            -- Filter out pure numeric text (e.g., "93%" from loading progress).
            if nameLower:find("^_visualtext") and elementText:match("^%d+%%?$") then
                -- skip progress percentages
            else
                table.insert(bodyParts, elementText)
            end
        end
        ::nextNamedText::
    end
    return titleText, bodyParts
end

--- ExtractFromWidgetData: extract title, body, and actions from widget data.
--- @param widgetData table|nil  Widget data table with dcProps and bindings.
--- @return string|nil titleText, string|nil bodyText, string|nil actionsText
local function ExtractFromWidgetData(widgetData)
    if not widgetData then return nil, nil, nil end
    local titleText = nil
    local bodyText = nil
    if widgetData.dcProps then
        titleText = widgetData.dcProps.Title or widgetData.dcProps.TitleText
            or widgetData.dcProps.Header or widgetData.dcProps.TitleProperty
        bodyText = widgetData.dcProps.Description or widgetData.dcProps.Text
            or widgetData.dcProps.Message or widgetData.dcProps.BodyText
            or widgetData.dcProps.TextProperty or widgetData.dcProps.LobbyMessage
    end
    if widgetData.bindings then
        for _, bindingEntry in ipairs(widgetData.bindings) do
            if not titleText and bindingEntry.path and bindingEntry.path:find("Title") and bindingEntry.value then
                titleText = bindingEntry.value
            end
            if not bodyText and bindingEntry.path and (bindingEntry.path:find("Description") or bindingEntry.path:find("Text") or bindingEntry.path:find("Message")) and bindingEntry.value then
                bodyText = bindingEntry.value
            end
        end
    end
    -- Append button hint for standard message box dialogs.
    local actionsText = nil
    if widgetData.dcType and widgetData.dcType:find("MessageBox") then
        actionsText = DIALOG_BUTTON_HINT
    end
    return titleText, bodyText, actionsText
end

-- ---------------------------------------------------------------------------
-- Tooltip text processing
-- ---------------------------------------------------------------------------

-- Short button labels and decorative text that leak into tooltip TextBlocks.
local TOOLTIP_JUNK_LABELS = {
    ["Inspect"] = true,
    ["Close"] = true,
    ["OK"] = true,
    ["."] = true,
    [":"] = true,
    ["You already know this spell."] = true,
    -- Button hints from inspect panel (PinnedTooltips_c).
    ["Select"] = true,
    ["Close Tooltips"] = true,
    ["Back"] = true,
    -- Tutorial labels from inspect side panels.
    ["Replenishable Resource"] = true,
}

-- Ability score names for inspect panel modifier grouping.
-- Built from game enums so modded abilities are included.
local ABILITY_NAMES = {}
if Ext.Enums and Ext.Enums.Ability then
    for abilityLabel, _ in pairs(Ext.Enums.Ability) do
        if type(abilityLabel) == "string" then
            ABILITY_NAMES[abilityLabel] = true
        end
    end
end

-- Ability abbreviations used in tooltips (CHA, STR, etc.).
-- Maps the 3-letter abbreviation to the full ability name so
-- tooltips can speak "Spellcasting ability, Charisma" instead of "CHA".
local ABILITY_ABBREVIATIONS = {
    ["STR"] = "Strength",  ["DEX"] = "Dexterity",
    ["CON"] = "Constitution", ["INT"] = "Intelligence",
    ["WIS"] = "Wisdom",    ["CHA"] = "Charisma",
}

-- Damage type keywords for filtering tooltip detail and grouping in inspect.
-- Built from game enums so modded damage types are included.
local DAMAGE_TYPES = {}
if Ext.Enums and Ext.Enums.DamageType then
    for damageLabel, _ in pairs(Ext.Enums.DamageType) do
        if type(damageLabel) == "string" then
            DAMAGE_TYPES[damageLabel] = true
        end
    end
end

-- ---------------------------------------------------------------------------
-- Inspect formatter (full tooltip detail for right-stick inspect)
-- ---------------------------------------------------------------------------

--- FormatInspectTexts: formats widget BFS data for inspect readback.
--- Filters button hints, tutorial explanations, and junk.  Keeps combat
--- data: damage (dice + type), range (feet), attack modifier (ability +N),
--- cost, category.  Groups related entries (dice+type, ability+modifier,
--- range label+feet).
--- @param widgetTexts table  Raw text array from C++ ReadWidgetTextBlocks.
--- @param filterTitle string|nil  Title to filter (handler already spoke it).
--- @return table|nil  SpeechData object with tier annotations, or nil.
local function FormatInspectTexts(widgetTexts, filterTitle)
    if not widgetTexts or #widgetTexts == 0 then return nil end

    local normalizedTitle = filterTitle
        and NormalizeForCompare(filterTitle) or nil

    -- Collect into semantic buckets.
    local damageRange = nil
    local diceParts = {}
    local damageTypes = {}
    local rangeLabel = nil
    local rangeFeet = nil
    local attackType = nil
    local attackAbility = nil
    local attackModifier = nil
    local costParts = {}
    local cooldownParts = {}
    local categoryParts = {}
    local seen = {}  -- dedup

    for _, text in ipairs(widgetTexts) do
        if text and text ~= ""
            and not TOOLTIP_JUNK_LABELS[text] then
            local cleaned = StripMarkupTags(text)
            if cleaned and cleaned ~= "" and cleaned ~= "."
                and cleaned ~= ":" then
                -- Skip title (handler already spoke it).
                if normalizedTitle
                    and NormalizeForCompare(cleaned) == normalizedTitle then
                    -- skip

                -- Skip tutorial/explanation sentences (> 30 chars).
                elseif #cleaned > 30 then
                    -- skip long explanatory text

                -- Dedup: skip if already seen this exact text.
                elseif seen[cleaned] then
                    -- skip duplicate

                -- Damage range: "4~9 Damage"
                elseif cleaned:match("^%d+~%d+ Damage$") then
                    local damageMin, damageMax =
                        cleaned:match("^(%d+)~(%d+) Damage$")
                    damageRange = damageMin .. " to " .. damageMax
                    seen[cleaned] = true

                -- Dice notation: "1d6+3", "+1d6"
                elseif cleaned:match("^[%+%-]?%d*d%d+[%+%-]?%d*$") then
                    table.insert(diceParts, cleaned)
                    seen[cleaned] = true

                -- Damage type keyword
                elseif DAMAGE_TYPES[cleaned] then
                    table.insert(damageTypes, cleaned)
                    seen[cleaned] = true

                -- Range: "Melee" or "Nft"
                elseif cleaned == "Melee" then
                    rangeLabel = "Melee range"
                    seen[cleaned] = true
                elseif cleaned:match("^%d+ft$") then
                    local distance = cleaned:match("^(%d+)ft$")
                    rangeLabel = "Range"
                    rangeFeet = distance .. " feet"
                    seen[cleaned] = true

                -- Range detail from side panel.
                -- Imperial: "5 feet", "18 feet"
                -- Metric: "2 metres", "1.5 metres", "5.4m", "1.5 m"
                elseif cleaned:match("^[%d%.%,]+ feet$")
                    or cleaned:match("^[%d%.%,]+ metres?$")
                    or cleaned:match("^[%d%.%,]+ meters?$")
                    or cleaned:match("^[%d%.%,]+%s?m$") then
                    rangeFeet = cleaned
                    seen[cleaned] = true

                -- Attack type
                elseif cleaned == "Attack Roll"
                    or cleaned == "Saving Throw" then
                    attackType = cleaned
                    seen[cleaned] = true

                -- Ability name (from side panel)
                elseif ABILITY_NAMES[cleaned] then
                    attackAbility = cleaned
                    seen[cleaned] = true

                -- Modifier: "+5 (Tav)" or "+3"
                elseif cleaned:match("^[%+%-]%d+") then
                    attackModifier = cleaned
                    seen[cleaned] = true

                -- Cost
                elseif cleaned == "Action" then
                    table.insert(costParts, "Costs Action")
                    seen[cleaned] = true
                elseif cleaned == "Bonus Action" then
                    table.insert(costParts, "Costs Bonus Action")
                    seen[cleaned] = true

                -- Cooldown
                elseif cleaned == "Per turn" then
                    table.insert(cooldownParts, "Once per turn")
                    seen[cleaned] = true
                elseif cleaned == "Short Rest"
                    or cleaned == "Long Rest" then
                    table.insert(cooldownParts, "Recharges on " .. cleaned)
                    seen[cleaned] = true
                elseif cleaned:match("^%d+ turns?$") then
                    table.insert(cooldownParts, "Duration " .. cleaned)
                    seen[cleaned] = true

                -- Category badge
                elseif cleaned == "Weapon Actions"
                    or cleaned == "Class Action"
                    or cleaned == "Cantrip"
                    or cleaned:match("^Level %d+") then
                    table.insert(categoryParts, cleaned)
                    seen[cleaned] = true

                -- Weapon Damage (label-only, skip)
                elseif cleaned == "Weapon Damage" then
                    seen[cleaned] = true

                -- Everything else short enough: keep as info.
                -- (already filtered > 30 chars above)
                end
            end
        end
    end

    -- Assemble damage phrase: "4 to 9 Damage, 1d6+3 Piercing"
    local combinedDice = {}
    for diceIndex = 1, #diceParts do
        local diceText = diceParts[diceIndex]
        if damageTypes[diceIndex] then
            diceText = diceText .. " " .. damageTypes[diceIndex]
        end
        table.insert(combinedDice, diceText)
    end
    for typeIndex = #diceParts + 1, #damageTypes do
        table.insert(combinedDice, damageTypes[typeIndex])
    end

    local damagePhrases = {}
    if damageRange then table.insert(damagePhrases, damageRange) end
    if #combinedDice > 0 then
        table.insert(damagePhrases, table.concat(combinedDice, " plus "))
    end
    -- Label "Damage" is applied by AddProperty below; don't suffix
    -- the value with " Damage" or the formatter produces
    -- "Damage: ... Damage".
    local damagePhrase = #damagePhrases > 0
        and table.concat(damagePhrases, ", ") or nil

    -- Assemble range phrase: "Melee, 5 feet"
    local rangePhrase = nil
    if rangeLabel and rangeFeet then
        rangePhrase = rangeLabel .. ", " .. rangeFeet
    elseif rangeLabel then
        rangePhrase = rangeLabel
    elseif rangeFeet then
        rangePhrase = rangeFeet
    end

    -- Assemble attack phrase: "Attack Roll, Dexterity +5 (Tav)"
    local attackPhrase = nil
    if attackType then
        local attackDetails = {}
        table.insert(attackDetails, attackType)
        if attackAbility and attackModifier then
            table.insert(attackDetails,
                attackAbility .. " " .. attackModifier)
        elseif attackAbility then
            table.insert(attackDetails, attackAbility)
        elseif attackModifier then
            table.insert(attackDetails, attackModifier)
        end
        attackPhrase = table.concat(attackDetails, ", ")
    end

    -- Final assembly via SpeechData.
    local SpeechDataMod = BG3Access.Client.SpeechData
    local speechData = SpeechDataMod.Create()
    speechData:Add("name", "Inspect", "brief")
    if damagePhrase then
        speechData:AddProperty("Damage", damagePhrase, "brief")
    end
    if rangePhrase then
        speechData:AddProperty("Range", rangePhrase, "brief")
    end
    if attackPhrase then
        speechData:AddProperty("Attack", attackPhrase, "brief")
    end
    for _, entry in ipairs(costParts) do
        speechData:AddProperty("Cost", entry, "normal")
    end
    for _, entry in ipairs(cooldownParts) do
        speechData:AddProperty("Cooldown", entry, "normal")
    end
    for _, entry in ipairs(categoryParts) do
        speechData:AddProperty("Category", entry, "verbose")
    end

    -- Only the "Inspect" name with no properties: nothing useful.
    if #speechData.properties == 0 then return nil end
    return speechData
end

-- (Tooltip formatters removed -- handlers iterate structured {role, text}
-- entries from C++ directly and build their own SpeechData.  Roles come
-- from TextBlock x:Name attributes in Tooltips.xaml: Title, ContentText,
-- DamageLabel, DiceValue, DamageType, PropertyText, SpellDamageText,
-- EquippedByText, weightText, TechnicalDescription, ExtraDescription, etc.
-- C++ PollTooltip handles stabilization and dedup via fingerprinting.)

-- ---------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------
--- ExpandAbilityAbbreviation: returns the full ability name for a 3-letter
--- abbreviation (STR -> Strength, INT -> Intelligence, etc.), or nil if
--- the text is not a recognized abbreviation.
local function ExpandAbilityAbbreviation(text)
    if not text then return nil end
    return ABILITY_ABBREVIATIONS[text]
end

BG3Access.Client.Helpers = {
    StripMarkupTags              = StripMarkupTags,
    NormalizeForCompare          = NormalizeForCompare,
    IsOptionData                 = IsOptionData,
    CleanElementName             = CleanElementName,
    CleanControllerFunctionality = CleanControllerFunctionality,
    FormatDCText                 = FormatDCText,
    FormatDCTextSplit            = FormatDCTextSplit,
    FormatDCValue                = FormatDCValue,
    ExtractStatusText            = ExtractStatusText,
    ExtractTextFromData          = ExtractTextFromData,
    GetTranslatedStringIfHandle  = GetTranslatedStringIfHandle,
    DumpWidgets                  = DumpWidgets,
    ParseDescriptionParam        = ParseDescriptionParam,
    ResolveDescriptionParams     = ResolveDescriptionParams,
    ReadStatDescription          = ReadStatDescription,
    ResolveTranslatedString      = ResolveTranslatedString,
    LookupSpellDescription       = LookupSpellDescription,
    LookupFeatureDescription     = LookupFeatureDescription,
    LookupStaticDataDescription  = LookupStaticDataDescription,
    DIALOG_BUTTON_HINT           = DIALOG_BUTTON_HINT,
    ExtractFromNamedTexts        = ExtractFromNamedTexts,
    ExtractFromWidgetData        = ExtractFromWidgetData,
    FormatInspectTexts           = FormatInspectTexts,
    ExpandAbilityAbbreviation    = ExpandAbilityAbbreviation,
}
