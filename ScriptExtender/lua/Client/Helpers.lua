-- File: Client/Helpers.lua
--
-- Pure utility functions for BG3Access speech formatting and text extraction.
-- None of these functions reference module-level state variables.  They take
-- data in and return data out, making them safe to call from any context.
--
-- CC-specific logic lives in CharCreation.lua.  This file is generic only.

local Log = BG3Access.Client.Log

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
    local result = text:gsub("<[^>]+>", " ")
    result = result:gsub("%s+", " ")
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
-- Stat labels for DC types whose label comes from the XAML template
-- parent (Tag property), not from the DataContext itself.
local STAT_DC_TYPE_LABELS = {
    ["ls.VMRangeStat"] = "Hit Points",
    ["ls.VMStat"]      = "Initiative",
}

local function FormatDCTextSplit(dcProps, dcType)
    if not dcProps then return nil, nil, nil end

    local text = dcProps.Text
    local value = dcProps.Value
    local desc = dcProps.Description

    -- Stat types whose label is in the parent template, not the DC.
    -- Use the hardcoded label and treat Value as the value slot.
    if not text and dcType and STAT_DC_TYPE_LABELS[dcType] then
        text = STAT_DC_TYPE_LABELS[dcType]
    end

    if not text and dcProps.Title then
        text = dcProps.Title
        -- Savegame items: append location and difficulty.
        local levelName = dcProps.LevelName
        if type(levelName) == "string" and levelName ~= "" then
            text = text .. ", " .. levelName
        end
        local difficulty = dcProps.Difficulty
        if type(difficulty) == "string" and difficulty ~= "" then
            text = text .. ", " .. difficulty
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
    if desc and desc ~= "" then
        descParts[#descParts + 1] = desc
    end
    local textProperty = dcProps.TextProperty
    if textProperty and textProperty ~= "" and textProperty ~= text then
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
local function ExtractTextFromData(data, lastSpokenTab, tabFlushPending)
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
            if (nameLower:find("title") or nameLower:find("header"))
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
local function ResolveDescriptionParams(text, stat, paramsString)
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
-- Speech slot assembly (shared by all menu handlers and CC).
-- ---------------------------------------------------------------------------

-- Slot names in the order they should be spoken.
local SLOT_ORDER = { "title", "hint", "tabName", "body", "actions", "itemName", "itemInfo", "itemValue", "itemDesc" }

-- Standard DCMessageBox button hint.  Noesis Indie SDK crashes when
-- enumerating the Actions IList collection from C++, so we handle
-- button hints in Lua based on the dialog DC type.
local DIALOG_BUTTON_HINT = "Press A to confirm, or B to cancel"

--- SpeakSlots: assemble slots in order, apply interrupt logic, speak.
--- @param slots table  Keyed by slot name (title, hint, tabName, etc.).
--- @param handlerState table  Handler's isolated state table.  Must have
---     screenEntryJustSpoke (bool) and lastSpokenFullText (string|nil).
--- @param isScreenEntry boolean  Whether this is a screen entry event.
local function SpeakSlots(slots, handlerState, isScreenEntry)
    local parts = {}
    for _, slotName in ipairs(SLOT_ORDER) do
        local slotValue = slots[slotName]
        if slotValue and slotValue ~= "" then
            table.insert(parts, (slotValue:gsub("[%.%s]+$", "")))
        end
    end
    if #parts == 0 then return end
    local assembled = StripMarkupTags(table.concat(parts, ". "))
    if not assembled or assembled == "" then return end

    local interrupt = true
    if handlerState.screenEntryJustSpoke and not isScreenEntry then
        interrupt = false
        handlerState.screenEntryJustSpoke = false
    end
    -- Visual text (loading tips, splash screen) should always append.
    -- These arrive from the initial widget scan with no title, tab, hint,
    -- or item -- just body text.  Appending lets tips queue naturally
    -- instead of cutting each other off.
    local isVisualTextOnly = slots["body"] and not slots["title"]
        and not slots["tabName"] and not slots["hint"]
        and not slots["itemName"]
    if isVisualTextOnly then
        interrupt = false
    end
    if isScreenEntry then
        handlerState.screenEntryJustSpoke = true
    end

    local Log = BG3Access.Client.Log
    Log.Info("SPEAK" .. (interrupt and "" or " (append)") .. ": " .. assembled)
    Ext.Tolk.Speak(assembled, interrupt)
    handlerState.lastSpokenFullText = assembled
end

--- ExtractFromNamedTexts: extract title and body parts from named text entries.
--- @param namedTexts table|nil  Map of elementName -> elementText.
--- @return string|nil titleText, table bodyParts
local function ExtractFromNamedTexts(namedTexts)
    if not namedTexts then return nil, {} end
    local titleText = nil
    local bodyParts = {}
    for elementName, elementText in pairs(namedTexts) do
        local nameLower = elementName:lower()
        if nameLower:find("title") or nameLower:find("header") then
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

-- Short button labels that leak into tooltip TextBlocks.
local TOOLTIP_JUNK_LABELS = {
    ["Inspect"] = true,
    ["Close"] = true,
    ["OK"] = true,
}

-- Heuristic: titles are short and don't end with sentence punctuation.
local function IsTooltipTitle(text)
    if #text > 60 then return false end
    if text:sub(-1) == "." or text:sub(-1) == ":" then return false end
    return true
end

-- FormatTooltipTexts: takes the raw tooltipTexts array from C++,
-- filters junk, identifies title vs descriptions, reorders title first.
-- Returns a formatted speech string or nil.
local function FormatTooltipTexts(tooltipTexts)
    if not tooltipTexts or #tooltipTexts == 0 then return nil end

    -- Filter junk
    local filtered = {}
    for _, text in ipairs(tooltipTexts) do
        if text and text ~= "" and not TOOLTIP_JUNK_LABELS[text] then
            local cleaned = StripMarkupTags(text)
            if cleaned and cleaned ~= "" then
                table.insert(filtered, cleaned)
            end
        end
    end
    if #filtered == 0 then return nil end

    -- Drop the title -- the focus handler already speaks the name and
    -- level (e.g. "Necrotic, Resistant").  The tooltip should only add
    -- the description lines that give extra detail.
    local parts = {}
    for _, text in ipairs(filtered) do
        if not IsTooltipTitle(text) then
            table.insert(parts, text)
        end
    end
    -- Strip trailing periods from each part before joining to avoid
    -- double periods ("halved.. Next sentence").
    for i, part in ipairs(parts) do
        if part:sub(-1) == "." then
            parts[i] = part:sub(1, -2)
        end
    end
    local speech = table.concat(parts, ". ")
    if speech == "" then return nil end
    return speech
end

-- ---------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------
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
    SpeakSlots                   = SpeakSlots,
    SLOT_ORDER                   = SLOT_ORDER,
    DIALOG_BUTTON_HINT           = DIALOG_BUTTON_HINT,
    ExtractFromNamedTexts        = ExtractFromNamedTexts,
    ExtractFromWidgetData        = ExtractFromWidgetData,
    FormatTooltipTexts           = FormatTooltipTexts,
}
