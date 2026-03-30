-- File: Client/AccessibilityHelpers.lua
--
-- Pure utility functions for BG3Access speech formatting and text extraction.
-- None of these functions reference module-level state variables.  They take
-- data in and return data out, making them safe to call from any context.
--
-- CC-specific logic lives in AccessibilityCC.lua.  This file is generic only.

local Log = BG3Access.Client.Log

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

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

    -- VMLobby and similar: Name is the primary text property.
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
    if not text then text = dcProps.TitleProperty end
    if not text and dcProps.LobbyMessage then
        local lobbyMessage = dcProps.LobbyMessage
        if type(lobbyMessage) == "string" and lobbyMessage ~= ""
            and lobbyMessage:sub(-3) ~= "..." then
            text = lobbyMessage
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

    return CleanElementName(data.elemName)
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
}
