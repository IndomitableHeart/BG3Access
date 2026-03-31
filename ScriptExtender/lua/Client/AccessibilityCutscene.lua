-- File: Client/AccessibilityCutscene.lua
--
-- Dialog and cutscene accessibility handler.
--
-- Handles two main scenarios:
-- 1. Cutscene subtitles: overhead widget (DCOverheads) shows speaker name
--    and subtitle text during cinematics.
-- 2. Interactive dialog: dialog widget (DCDialogue) shows NPC dialog lines
--    and player answer choices.
--
-- The Manager detects dialog/cutscene widget DC types and delegates here.
-- This module reads widget DC properties for speech output.

local Log = BG3Access.Client.Log
local H   = BG3Access.Client.Helpers

-- ============================================================================
-- Constants
-- ============================================================================

-- DC types that indicate a dialog or cutscene context.
-- Larian prefixes vary (gui::, ls., ls::), so we match flexibly.
local DIALOG_DC_PATTERNS = {
    "DCDialogue",
    "DCDialog",
}

local OVERHEAD_DC_PATTERNS = {
    "DCOverhead",
}

-- ============================================================================
-- State
-- ============================================================================

local dialogState = {
    lastSubtitleText    = nil,
    lastSpeakerName     = nil,
    lastBodyText        = nil,
    lastAnswerText      = nil,
    inDialog            = false,
    inCutscene          = false,
}

-- ============================================================================
-- Detection helpers
-- ============================================================================

-- Check if a dcType string matches any pattern in a list.
local function MatchesDCPattern(dcType, patterns)
    if not dcType then return false end
    for _, pattern in ipairs(patterns) do
        if dcType:find(pattern, 1, true) then
            return true
        end
    end
    return false
end

-- Returns true if this widget DC type is a dialog widget.
local function IsDialogWidget(dcType)
    return MatchesDCPattern(dcType, DIALOG_DC_PATTERNS)
end

-- Returns true if this widget DC type is an overhead/subtitle widget.
local function IsOverheadWidget(dcType)
    return MatchesDCPattern(dcType, OVERHEAD_DC_PATTERNS)
end

-- Returns true if this DC type belongs to the dialog/cutscene system.
local function IsDialogOrCutscene(dcType)
    return IsDialogWidget(dcType) or IsOverheadWidget(dcType)
end

-- ============================================================================
-- Subtitle handling (cutscene narration)
-- ============================================================================

-- Process subtitle properties from an overhead widget.
-- dcProps should contain CurrentSubtitle and/or CurrentSpeaker.
local function HandleSubtitle(dcProps)
    if not dcProps then return end

    local subtitleText = dcProps.CurrentSubtitle
    local speakerName = dcProps.CurrentSpeaker

    -- Filter empty/unchanged subtitles.
    if not subtitleText or subtitleText == "" then return end
    if subtitleText == dialogState.lastSubtitleText
        and speakerName == dialogState.lastSpeakerName then
        return
    end

    dialogState.lastSubtitleText = subtitleText
    dialogState.lastSpeakerName = speakerName
    dialogState.inCutscene = true

    -- Strip markup tags from both fields.
    local cleanSubtitle = H.StripMarkupTags(subtitleText)
    if not cleanSubtitle or cleanSubtitle == "" then return end

    local parts = {}
    if speakerName and speakerName ~= "" then
        local cleanSpeaker = H.StripMarkupTags(speakerName)
        if cleanSpeaker and cleanSpeaker ~= "" then
            table.insert(parts, cleanSpeaker)
        end
    end
    table.insert(parts, cleanSubtitle)

    local fullText = table.concat(parts, ": ")
    Log.Info("SUBTITLE: " .. fullText)
    Ext.Tolk.Speak(fullText, true)
end

-- ============================================================================
-- Dialog handling (interactive NPC conversations)
-- ============================================================================

-- Process dialog properties from a dialog widget.
-- dcProps should contain BodyText, ShowAnswers, etc.
local function HandleDialogWidget(dcProps)
    if not dcProps then return end

    local bodyText = dcProps.BodyText
    if not bodyText or bodyText == "" then return end
    if bodyText == dialogState.lastBodyText then return end

    dialogState.lastBodyText = bodyText
    dialogState.inDialog = true

    local cleanBody = H.StripMarkupTags(bodyText)
    if not cleanBody or cleanBody == "" then return end

    Log.Info("DIALOG: " .. cleanBody:sub(1, 80))
    Ext.Tolk.Speak(cleanBody, true)
end

-- Handle focus on a dialog answer choice (player navigating answers).
-- Called from the Manager when focus changes within a dialog widget.
local function HandleDialogAnswerFocus(focusedElement)
    if not focusedElement then return false end
    if not dialogState.inDialog then return false end

    -- Answer elements have dcProps with answer text.
    local dcProps = focusedElement.dcProps
    if not dcProps then return false end

    -- Try to extract answer text from dcProps.
    local answerText = dcProps.CtxAnswer or dcProps.BodyText
        or dcProps.Text or dcProps.Title
    if not answerText or answerText == "" then
        -- Fallback: try elemText.
        answerText = focusedElement.elemText
    end
    if not answerText or answerText == "" then return false end
    if answerText == dialogState.lastAnswerText then return false end

    dialogState.lastAnswerText = answerText

    local cleanAnswer = H.StripMarkupTags(answerText)
    if not cleanAnswer or cleanAnswer == "" then return false end

    -- Prefix with answer number if available.
    local answerIndex = dcProps.AnswerIdx
    local parts = {}
    if answerIndex then
        local numIndex = tonumber(answerIndex)
        if numIndex then
            table.insert(parts, tostring(numIndex + 1))
        end
    end
    table.insert(parts, cleanAnswer)

    local fullText = table.concat(parts, ". ")
    Log.Info("DIALOG ANSWER: " .. fullText:sub(1, 80))
    Ext.Tolk.Speak(fullText, true)
    return true
end

-- ============================================================================
-- Main widget event handler
-- ============================================================================

-- Called by the Manager when a WidgetAdded or WidgetDCChanged event
-- has a dialog/cutscene DC type.
local function HandleDialogWidgetEvent(widgetData)
    if not widgetData or not widgetData.dcType then return end

    Log.Info("CUTSCENE WIDGET: dcType=" .. widgetData.dcType
        .. " event=" .. tostring(widgetData.eventType))

    -- Log all properties for initial debugging.
    if widgetData.dcProps then
        local propList = {}
        for propName, propValue in pairs(widgetData.dcProps) do
            local displayValue = tostring(propValue)
            if #displayValue > 60 then
                displayValue = displayValue:sub(1, 60) .. "..."
            end
            table.insert(propList, propName .. "=" .. displayValue)
        end
        if #propList > 0 then
            Log.Info("CUTSCENE PROPS: " .. table.concat(propList, " | "))
        end
    end

    if IsOverheadWidget(widgetData.dcType) then
        HandleSubtitle(widgetData.dcProps)
    elseif IsDialogWidget(widgetData.dcType) then
        HandleDialogWidget(widgetData.dcProps)
    end
end

-- ============================================================================
-- Audio Description playback
-- ============================================================================

-- Path relative to the game Data directory.
local AD_BASE_PATH = "Mods/BG3Access_a8cddf0c-2e61-1b7c-5c0c-275d46073949"
    .. "/ScriptExtender/lua/Audio/"

-- Audio description files keyed by cutscene identifier.
-- Add new entries here as AD tracks are produced.
local AD_TRACKS = {
    opening = "AD001.wav",
}

-- Tracks whether AD has already played this session to avoid replaying
-- on subsequent Running transitions (e.g. after a save/load cycle).
local adPlayedThisSession = true

-- Delay (ms) between the Running state and AD playback start.
-- Tune this to align with the actual cutscene start.
local AD_START_DELAY_MS = 1500

-- Called from the Manager on every GameStateChanged event.
local function HandleGameStateForAD(fromState, toState)
    Log.Info("AD CHECK: " .. fromState .. " -> " .. toState
        .. " played=" .. tostring(adPlayedThisSession))

    -- The opening cutscene begins exactly on PrepareRunning -> Running.
    -- This transition only fires when entering gameplay, never at
    -- startup or the main menu.  Play once per VM session.
    if fromState == "StopLoading" and toState == "PrepareRunning"
        and not adPlayedThisSession then
        adPlayedThisSession = true
        local adFile = AD_TRACKS.opening
        if adFile then
            local fullPath = AD_BASE_PATH .. adFile
            Log.Info("AD: Scheduling " .. adFile
                .. " in " .. AD_START_DELAY_MS .. "ms"
                .. " (path=" .. fullPath .. ")")
            Ext.Timer.WaitFor(AD_START_DELAY_MS, function()
                Log.Info("AD: Timer fired, playing " .. adFile)
                local playSuccess, playResult = pcall(
                    Ext.Audio.PlayFile, fullPath)
                if playSuccess then
                    Log.Info("AD: PlayFile returned "
                        .. tostring(playResult))
                else
                    Log.Warning("AD: PlayFile error: "
                        .. tostring(playResult))
                end
            end)
        end
    end

    -- Returning to the main menu cancels any playing AD.
    if toState == "Menu" then
        pcall(Ext.Audio.StopFile)
        Log.Debug("AD: Stopped (returned to menu)")
    end
end

-- ============================================================================
-- State management
-- ============================================================================

local function ResetDialogState()
    dialogState.lastSubtitleText = nil
    dialogState.lastSpeakerName = nil
    dialogState.lastBodyText = nil
    dialogState.lastAnswerText = nil
    dialogState.inDialog = false
    dialogState.inCutscene = false
    Log.Debug("Dialog/cutscene state reset")
end

-- ============================================================================
-- Exports
-- ============================================================================

BG3Access.Client.Cutscene = {
    IsDialogOrCutscene        = IsDialogOrCutscene,
    IsDialogWidget            = IsDialogWidget,
    IsOverheadWidget          = IsOverheadWidget,
    HandleDialogWidgetEvent   = HandleDialogWidgetEvent,
    HandleDialogAnswerFocus   = HandleDialogAnswerFocus,
    HandleGameStateForAD      = HandleGameStateForAD,
    ResetDialogState          = ResetDialogState,
}
