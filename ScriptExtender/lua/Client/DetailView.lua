-- File: Client/DetailView.lua
--
-- Shared detail view (RS Left virtual property list).
-- Any handler with BuildDetailList + GetLastFocusedData can use this.
-- State is module-level: one detail view open at a time across all
-- contexts (WorldUI panels, CC pages, etc.).

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

local Log     = BG3Access.Client.Log
local Helpers = BG3Access.Client.Helpers

-- ============================================================================
-- State
-- ============================================================================

local detailViewOpen               = false
local detailViewList               = nil   -- array of {label, value}
local detailViewIndex              = 1
local detailViewButtonSubscription = nil

-- ============================================================================
-- Navigation
-- ============================================================================

local function SpeakDetailItem()
    if not detailViewList or not detailViewList[detailViewIndex] then
        return
    end
    local entry = detailViewList[detailViewIndex]
    local speechData = Helpers.CreateSpeechData()
    speechData:Add("name", entry.label, "brief")
    if entry.value and entry.value ~= "" then
        speechData:Add("value", entry.value, "brief")
    end
    local speech = speechData:Format()
    if not speech then return end
    Log.Info("DETAIL [" .. detailViewIndex .. "/"
        .. #detailViewList .. "]: " .. speech)
    Ext.Tolk.Speak(speech, true)
end

local function DetailViewNext()
    if not detailViewList or #detailViewList == 0 then return end
    detailViewIndex = (detailViewIndex % #detailViewList) + 1
    SpeakDetailItem()
end

local function DetailViewPrevious()
    if not detailViewList or #detailViewList == 0 then return end
    detailViewIndex = ((detailViewIndex - 2) % #detailViewList) + 1
    SpeakDetailItem()
end

-- ============================================================================
-- Open / Close
-- ============================================================================

--- Close the detail view and unsubscribe input.
--- @param silent boolean|nil  If true, skip the "closed" announcement.
local function CloseDetailView(silent)
    if not detailViewOpen then return end
    if detailViewButtonSubscription then
        Ext.Events.ControllerButtonInput:Unsubscribe(
            detailViewButtonSubscription)
        detailViewButtonSubscription = nil
    end
    detailViewOpen = false
    detailViewList = nil
    detailViewIndex = 1
    if not silent then
        Log.Info("DETAIL VIEW: closed")
        local speechData = Helpers.CreateSpeechData()
        speechData:Add("name", "Detail view closed", "brief")
        Ext.Tolk.Speak(speechData:Format(), true)
    else
        Log.Info("DETAIL VIEW: closed (silent)")
    end
end

--- Toggle the detail view for the given handler.
--- @param handler table  Handler with BuildDetailList + GetLastFocusedData.
--- @param tooltipTexts table|nil  Cached tooltip data to pass to builder.
--- @return boolean  true if handled
local function Toggle(handler, tooltipTexts)
    -- Toggle: if already open, close it.
    if detailViewOpen then
        CloseDetailView()
        return true
    end

    -- Focus-alive check.
    local focusCheckOk, focusedElement = pcall(Ext.UI.GetFocusedElement)
    if not focusCheckOk or not focusedElement then
        return false
    end

    -- Need a handler with BuildDetailList.
    if not handler or not handler.BuildDetailList then
        return false
    end

    -- Get cached focused element data.
    local focusedData = nil
    if handler.GetLastFocusedData then
        focusedData = handler.GetLastFocusedData()
    end
    if not focusedData then
        return false
    end

    -- Build the detail list.
    local buildOk, builtList = pcall(
        handler.BuildDetailList, focusedData, tooltipTexts)
    if not buildOk then
        Log.Error("BuildDetailList: " .. tostring(builtList))
        return false
    end
    if not builtList or #builtList == 0 then
        local noDetailsSpeech = Helpers.CreateSpeechData()
        noDetailsSpeech:Add("name", "No details available", "brief")
        Ext.Tolk.Speak(noDetailsSpeech:Format(), true)
        return true
    end

    -- Open.
    detailViewOpen = true
    detailViewList = builtList
    detailViewIndex = 1

    -- Subscribe d-pad input for navigation.
    detailViewButtonSubscription =
        Ext.Events.ControllerButtonInput:Subscribe(function(event)
            if not event.Pressed then return end
            local buttonName = tostring(event.Button)
            if buttonName == "DPadDown" then
                event:PreventAction()
                DetailViewNext()
            elseif buttonName == "DPadUp" then
                event:PreventAction()
                DetailViewPrevious()
            elseif buttonName == "DPadLeft"
                or buttonName == "DPadRight" then
                event:PreventAction()
            elseif buttonName == "LeftShoulder"
                or buttonName == "RightShoulder" then
                event:PreventAction()
            elseif buttonName == "B" then
                CloseDetailView(true)
            end
        end)

    -- Announce entry and speak first item.
    local firstEntry = detailViewList[1]
    local openSpeechData = Helpers.CreateSpeechData()
    openSpeechData:Add("title", "Detail view", "brief")
    openSpeechData:Add("name", firstEntry.label, "brief")
    openSpeechData:Add("value", firstEntry.value, "brief")
    local openSpeech = openSpeechData:Format()
    Log.Info("DETAIL VIEW: opened with "
        .. #detailViewList .. " items")
    Ext.Tolk.Speak(openSpeech, true)
    return true
end

--- @return boolean  true if the detail view is currently open
local function IsOpen()
    return detailViewOpen
end

-- ============================================================================
-- Shared formatting (used by any handler's buildDetailList)
-- ============================================================================

-- Tooltip role -> user-friendly label.
-- PropertyText is NOT here because it uses TypeId-based labels.
local ROLE_LABELS = {
    ["txt"]                  = "School",
    ["SpellDamageText"]      = "Damage",
    ["TechnicalDescription"] = "Description",
    ["Name"]                 = "Cost",
    ["DiceValue"]            = "Dice",
    ["DamageType"]           = "Damage type",
    ["SectionDuration"]      = "Duration",
    ["SkillValue"]           = "Value",
    ["TitleName"]            = "Name",
    ["TitleValue"]           = "Value",
    ["Description"]          = "Description",
    ["AbilityModifierDesc"]  = "Modifier",
    ["SavingThrows"]         = "Saving throws",
}

-- TypeId -> user-friendly label for PropertyText entries.
local PROPERTY_TYPE_LABELS = {
    ["Range"]         = "Range",
    ["ZoneRadius"]    = "AoE radius",
    ["Radius"]        = "Radius",
    ["CastAbility"]   = "Casting stat",
    ["SaveAbility"]   = "Save",
    ["Concentration"] = "Concentration",
}

-- Positional fallback when TypeId is absent.
local PROPERTY_POSITIONAL_LABELS = { "Range", "Modifier" }

--- Map a tooltip role to a user-friendly label.
--- @param role string  Tooltip x:Name role.
--- @param text string|nil  Entry text (for context-aware labels).
local function RoleLabel(role, text)
    if not role or role == "?" then return nil end
    if role == "Name" and text then
        if text:find("Spell Slot")
            or text:find("Sorcery Point")
            or text:find("Channel") then
            return "Spell slot"
        end
    end
    return ROLE_LABELS[role]
end

--- Normalize text for screen reader clarity.
--- @param text string  Raw text from tooltip.
--- @param role string|nil  Tooltip role (for context-aware stripping).
local function NormalizeText(text, role)
    if not text then return text end
    text = text:gsub("(%d+)~(%d+)", "%1 to %2")
    text = text:gsub("(%d+)ft", "%1 feet")
    text = text:gsub("(%d+)m$", "%1 metres")
    text = text:gsub("(%d+)m ", "%1 metres ")
    text = text:gsub("(%d+)d(%d+)", "%1 D %2")
    if role == "Name" and text:find("Spell Slot") then
        text = text:gsub("%s*Spell Slot%s*", "")
    end
    if role == "SpellDamageText" then
        text = text:gsub("%s+[Dd]amage%s*$", "")
    end
    return text
end

-- ============================================================================
-- Exports
-- ============================================================================

BG3Access.Client.DetailView = {
    Toggle                = Toggle,
    Close                 = CloseDetailView,
    IsOpen                = IsOpen,
    -- Shared formatting for buildDetailList implementations.
    RoleLabel             = RoleLabel,
    NormalizeText         = NormalizeText,
    PropertyTypeLabels    = PROPERTY_TYPE_LABELS,
    PropertyPositionalLabels = PROPERTY_POSITIONAL_LABELS,
}
