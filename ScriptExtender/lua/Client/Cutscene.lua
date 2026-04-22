-- File: Client/Cutscene.lua
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

local Log        = BG3Access.Client.Log
local Helpers    = BG3Access.Client.Helpers
local SpeechData = BG3Access.Client.SpeechData

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
    local cleanSubtitle = Helpers.StripMarkupTags(subtitleText)
    if not cleanSubtitle or cleanSubtitle == "" then return end

    local cleanSpeaker = nil
    if speakerName and speakerName ~= "" then
        cleanSpeaker = Helpers.StripMarkupTags(speakerName)
        if cleanSpeaker == "" then cleanSpeaker = nil end
    end

    local speechData = SpeechData.Create()
    if cleanSpeaker then
        speechData:Add("description",
            cleanSpeaker .. ": " .. cleanSubtitle, "brief")
    else
        speechData:Add("description", cleanSubtitle, "brief")
    end
    local fullText = speechData:Format()
    Log.Info("SUBTITLE: " .. fullText)
    Ext.Tolk.Speak(fullText, true)
end

-- ============================================================================
-- Dialog handling (interactive NPC conversations)
-- ============================================================================

-- Process dialog properties from a dialog widget.
-- Always marks us as in-dialog whenever the widget event fires --
-- the narrator text may be voice-acted (empty BodyText) but the
-- answer-choice poller still needs to run.
local function HandleDialogWidget(dcProps)
    -- Any DCDialogue event means we are in a dialog.  Set the flag
    -- unconditionally so answer detection activates even for
    -- voice-acted narrator lines that carry no BodyText.
    dialogState.inDialog = true
    -- Clear the last spoken answer so re-entering the same dialog
    -- with the same first choice still speaks it.
    dialogState.lastAnswerText = nil

    -- Enable the C++ dialogue poll so it detects d-pad navigation
    -- through answer choices (IsSelected changes on ListBoxItems).
    -- The poll only runs when this flag is true AND no menu has focus.
    pcall(Ext.UI.SetDialoguePollActive, true)

    -- Re-arm the C++ focus monitor so it runs a forced walk on the
    -- next tick.  On dialog re-entry the widget set count may not
    -- change (BG3 reuses the widget), so the normal "widgetCount
    -- increased" reset doesn't fire.
    pcall(Ext.UI.ForceGlobalFocusUpdate)

    if not dcProps then return end

    local bodyText = dcProps.BodyText
    if not bodyText or bodyText == "" then return end
    if bodyText == dialogState.lastBodyText then return end

    dialogState.lastBodyText = bodyText

    local cleanBody = Helpers.StripMarkupTags(bodyText)
    if not cleanBody or cleanBody == "" then return end

    local dialogSpeech = SpeechData.Create()
    dialogSpeech:Add("description", cleanBody, "brief")
    Log.Info("DIALOG: " .. cleanBody:sub(1, 80))
    Ext.Tolk.Speak(dialogSpeech:Format(), true)
end

-- ============================================================================
-- Dialog answer handler (snapshot-driven)
-- ============================================================================
--
-- D-pad navigation inside a DCDialogue does NOT fire Noesis keyboard
-- focus events.  Dialogue_c.xaml binds UIUp / UIDown to custom
-- SelectorUpCommand / SelectorDownCommand handlers that mutate
-- ActiveDialogue.LocalHighlightedAnswer on the view model.  The
-- answerList ls:LSListBox then updates its SelectedItem via a data
-- binding, which flips IsSelected=true on the corresponding
-- LSListBoxItem.
--
-- The C++ global focus monitor's Strategy 3 (IsSelected tree walk,
-- FindSelectedTabInTree) DOES detect this selection change and
-- delivers it via the snapshot pipeline with:
--
--     snapshot.focusedElement.elemId = "ls.LSListBoxItem@0x..."
--     snapshot.focusedElement.dcType = "gui::VMDialogueAnswer"
--
-- EventRouter intercepts snapshots with that dcType and routes them
-- here instead of letting them fall through to the default MainMenu
-- handler (which would extract only the "1." AnswerTextPrefix).
--
-- To read the full answer text we call Ext.UI.ReadFocusedTextBlocks()
-- -- a C++, SEH-guarded helper that walks the focused element's
-- visual subtree for all TextBlocks and returns their rendered text
-- (via ReadTextBlockText, which already handles the Inlines / Run
-- decomposition that CtxTransStringRunGeneratorBehavior produces).
-- For a dialog answer LSListBoxItem the returned array contains the
-- AnswerTextPrefix ("1.") and the AnswerText ("Reach toward the
-- pool.") in some order.
--
-- This module never touches Noesis directly -- the rule is "all
-- visual-tree walking lives in C++ under SEH".  ReadFocusedTextBlocks
-- satisfies that.

--- Read the dialog answer directly from the focused element's
--- ViewModel dcProps.  The data layer IS the single source of truth
--- for answer text — the rendered TextBlocks are populated by a
--- CtxTransStringRunGeneratorBehavior that creates Runs with bound
--- Text values the C++ Inlines walker cannot fully extract.
---
--- dcProps keys for gui::VMDialogueAnswer:
---   BodyText:   "<i>Investigate the pool.</i>" (HTML, full answer)
---   AnswerIdx:  "1" (0-based)
---   AnswerTags: table (tag collection, contains "[INVESTIGATION]" etc.)
---   CtxAnswer:  table (TranslatedString context, complex)
---   Enabled, HighlightedByHost, BoundEvent, PollResult* ... (metadata)
---
--- Also checks ReadFocusedTextBlocks for bracket-tagged prefixes
--- like "[INVESTIGATION]" that are rendered as styled Runs in the
--- AnswerText TextBlock (those DO come through the Inlines walker
--- because the ParamRunStyle's StringFormat binding is resolved).
local function HandleDialogAnswerSnapshot(snapshot)
    dialogState.inDialog = true

    local focusedElement = snapshot.focusedElement
    if not focusedElement then return end
    local dcProps = focusedElement.dcProps
    if type(dcProps) ~= "table" then return end

    -- Body text from the ViewModel (the actual answer string).
    local bodyText = dcProps.BodyText
    if not bodyText or bodyText == "" then return end
    local cleanBody = Helpers.StripMarkupTags(bodyText)
    if not cleanBody or cleanBody == "" then return end

    -- Number prefix from 0-based AnswerIdx.
    local numberPrefix = ""
    local answerIndex = tonumber(dcProps.AnswerIdx)
    if answerIndex then
        numberPrefix = tostring(answerIndex + 1) .. ". "
    end

    -- Tag prefix: "[INVESTIGATION]", "[PERSUASION]", etc.  The tag
    -- text comes through ReadFocusedTextBlocks because it's a styled
    -- Run whose StringFormat binding is evaluated.  Look for any
    -- entry that starts with "[" and contains uppercase letters --
    -- that's the D&D skill/ability tag the player needs to know.
    local tagPrefix = ""
    if Ext.UI.ReadFocusedTextBlocks then
        local okFocusedTexts, focusedTexts = pcall(
            Ext.UI.ReadFocusedTextBlocks)
        if okFocusedTexts and type(focusedTexts) == "table" then
            for _, text in ipairs(focusedTexts) do
                if type(text) == "string"
                    and text:match("^%[%u") then
                    tagPrefix = text .. " "
                    break
                end
            end
        end
    end

    local combined = numberPrefix .. tagPrefix .. cleanBody
    if combined == dialogState.lastAnswerText then return end
    dialogState.lastAnswerText = combined

    local answerSpeech = SpeechData.Create()
    answerSpeech:Add("name", combined, "brief")
    Log.Info("DIALOG ANSWER: " .. combined:sub(1, 160))
    Ext.Tolk.Speak(answerSpeech:Format(), true)
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

    local cleanAnswer = Helpers.StripMarkupTags(answerText)
    if not cleanAnswer or cleanAnswer == "" then return false end

    -- Prefix with answer number if available.
    local answerIndex = dcProps.AnswerIdx
    local numberPrefix = ""
    if answerIndex then
        local numIndex = tonumber(answerIndex)
        if numIndex then
            numberPrefix = tostring(numIndex + 1) .. ". "
        end
    end
    local answerFocusSpeech = SpeechData.Create()
    answerFocusSpeech:Add("name", numberPrefix .. cleanAnswer, "brief")
    local fullText = answerFocusSpeech:Format()
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
local adPlayedThisSession = false

-- Delay (ms) between the Running state and AD playback start.
-- Tune this to align with the actual cutscene start.
local AD_START_DELAY_MS = 200

--- IsFreshCharacter: decide if the party's main character is a
--- just-created new-game character vs an existing save being loaded.
---
--- Approach: check Experience.NextLevelExperience (the player's current
--- cumulative XP, despite the counterintuitive field name -- see
--- CharSheet.lua:712 for the same read).  A newly-created character
--- has 0 XP.  A Continue or Load Game has some progress and therefore
--- XP > 0 (or is at least level 2+).
---
--- This runs on PrepareRunning, by which point the player's party
--- member entities are loaded and their components are populated.
---
--- @return boolean true if the main character appears to be a fresh
---                 new-game character, false otherwise or on error.
local function IsFreshCharacter()
    local queryOk, partyMembers = pcall(
        Ext.Entity.GetAllEntitiesWithComponent, "PartyMember")
    if not queryOk or not partyMembers or #partyMembers == 0 then
        Log.Info("AD: IsFreshCharacter could not find party members")
        return false
    end

    -- Any party member with XP > 0 means we're loading an existing save.
    -- Only a fresh new game has every party member at exactly 0 XP.
    -- (The opening cinematic plays before any XP could be gained.)
    for _, partyEntity in ipairs(partyMembers) do
        local xpOk, currentXP = pcall(function()
            local xpComponent = partyEntity.Experience
            if not xpComponent then return nil end
            return xpComponent.NextLevelExperience or 0
        end)
        if xpOk and currentXP and currentXP > 0 then
            Log.Info("AD: Party member XP=" .. tostring(currentXP)
                .. " -- treating as loaded save, not a new game")
            return false
        end
    end

    Log.Info("AD: All party members have 0 XP -- treating as new game")
    return true
end

-- Called from the Manager on every GameStateChanged event.
local function HandleGameStateForAD(fromState, toState)
    Log.Info("AD CHECK: " .. fromState .. " -> " .. toState
        .. " played=" .. tostring(adPlayedThisSession))

    -- The opening cutscene begins on StopLoading -> PrepareRunning.
    -- This transition fires for BOTH new games AND continued saves.
    -- Distinguish by inspecting character state: a fresh new game has
    -- party members at 0 XP; a Continue/Load has accumulated XP.
    -- No persistent state required (the previous newGameInitiated flag
    -- approach was broken by the Menu->Game VM reset that happens
    -- between difficulty selection and PrepareRunning).
    if fromState == "StopLoading" and toState == "PrepareRunning"
        and not adPlayedThisSession then
        if not IsFreshCharacter() then
            return
        end
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
    -- Disable the C++ dialogue poll so no tree walks run during
    -- exploration (DCDialogue is always loaded in-game but inactive).
    pcall(Ext.UI.SetDialoguePollActive, false)
    Log.Debug("Dialog/cutscene state reset")
end

-- ============================================================================
-- Exports
-- ============================================================================

BG3Access.Client.Cutscene = {
    IsDialogOrCutscene         = IsDialogOrCutscene,
    IsDialogWidget             = IsDialogWidget,
    IsOverheadWidget           = IsOverheadWidget,
    HandleDialogWidgetEvent    = HandleDialogWidgetEvent,
    HandleDialogAnswerFocus    = HandleDialogAnswerFocus,
    HandleDialogAnswerSnapshot = HandleDialogAnswerSnapshot,
    HandleGameStateForAD       = HandleGameStateForAD,
    ResetDialogState           = ResetDialogState,
}
