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

    -- Subtitles are the primary content of a cutscene -- always
    -- speak regardless of verbosity / toggles.  sectionLabel is
    -- unconditionally emitted by SpeechData.Format(); the
    -- "description" core field routes through speakDescription
    -- and would vanish whenever the user's normal verbosity
    -- preset turns descriptions off.
    local speechData = SpeechData.Create()
    if cleanSpeaker then
        speechData:Add("sectionLabel",
            cleanSpeaker .. ": " .. cleanSubtitle, "brief")
    else
        speechData:Add("sectionLabel", cleanSubtitle, "brief")
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

    -- NPC dialogue body is the primary content of a dialog --
    -- always speak regardless of verbosity / toggles.  See the
    -- subtitle helper above for the same rationale (sectionLabel
    -- is unconditional in SpeechData.Format(); description routes
    -- through the speakDescription toggle).
    local dialogSpeech = SpeechData.Create()
    dialogSpeech:Add("sectionLabel", cleanBody, "brief")
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
    -- Run whose StringFormat binding is evaluated.
    --
    -- Subtle: Larian's AnswerText TextBlock renders the tag Run and
    -- the body Run as ONE concatenated string ("[NATURE] Don't druids
    -- cherish harmony?..."), not as separate TextBlocks.  So a naive
    -- "starts with [" check would grab the ENTIRE answer (tag + body)
    -- and we'd then append the body again from dcProps.BodyText,
    -- producing a doubled-body announcement.  Extract just the
    -- bracketed prefix substring instead.
    local tagPrefix = ""
    if Ext.UI.ReadFocusedTextBlocks then
        local okFocusedTexts, focusedTexts = pcall(
            Ext.UI.ReadFocusedTextBlocks)
        if okFocusedTexts and type(focusedTexts) == "table" then
            for _, text in ipairs(focusedTexts) do
                if type(text) == "string" then
                    local bracketed = text:match("^(%[%u[^%]]+%])")
                    if bracketed then
                        tagPrefix = bracketed .. " "
                        break
                    end
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

-- Audio description tracks keyed by cinematic identifier.  Lookup
-- key:
--   * Engine timeline cinematics (TimelineScreenFadeStarted):
--     DIALOGRESOURCE GUID string.  When such a timeline fires the
--     server relays a MovieStarted with movie=<uuid>, and
--     HandleMovieStarted picks the matching track.
--   * Video CGI .bk2 files: short movie name (e.g. "GUS_CGI01_Part1"
--     for the Nautiloid intro -- confirmed at
--     D:\extracted packs\Osi\Z_Shared_TutorialCharacterCreation.txt:13).
--     CAVEAT: BG3's CGI player does NOT fire any Osiris start
--     event -- only MovieFinished at end.  Diagnostic confirmed
--     this in production (none of MoviePlay / PROC_StartMovie /
--     DB_MoviePlayed / TimelineScreenFadeStarted fire for
--     GUS_CGI01_Part1; only MovieFinished does).  For CGIs we
--     therefore can't subscribe to a per-movie start signal, so
--     the opening case uses a state-transition heuristic
--     (StopLoading -> PrepareRunning + new-game gate) to time
--     the AD start.  MovieFinished still cleanly stops the AD
--     when the cinematic ends.
--
-- Add new entries as AD tracks are produced.
-- Each entry: { file = "<filename>", delayMs = <number, optional> }
-- delayMs is for per-cinematic alignment when the trigger signal
-- fires before the video visually starts on screen (e.g. Part 2's
-- CharacterCreationFinished fires ~500ms before the video begins).
-- Default delay is 0 (play immediately).  Negative delays not
-- supported -- if a trigger fires AFTER the video starts, trim
-- the audio file's lead-in instead.
local AD_TRACKS = {
    ["GUS_CGI01_Part1"] = { file = "AD001.wav" },
    ["GUS_CGI01_Part2"] = { file = "AD002.wav", delayMs = 1100 },
}

-- Opening CGI AD: there's no per-movie Osiris start event for the
-- engine-played .bk2 video (confirmed in production -- only
-- MovieFinished fires, at the end).  But the server detects the
-- fresh-new-game path via the CharacterCreationStarted Osiris
-- event (character creation happens ONLY on a new game, never on
-- a save load) and relays it as a MovieStarted for GUS_CGI01
-- _Part1.  So the opening cinematic flows through the exact same
-- client-side path as every other cinematic: HandleMovieStarted
-- looks up AD_TRACKS and plays; HandleMovieFinished stops.  No
-- menu-VM flag, no settings persistence, no game-state heuristic.

-- Tracks the movie name currently associated with an active AD
-- playback.  Used to deduplicate concurrent MovieStarted relays
-- for the same cinematic (the server subscribes to multiple Osi
-- signals -- MoviePlay / PROC_StartMovie / DB_MoviePlayed / etc.
-- -- and more than one may fire for the same movie; we don't
-- want to start the audio playback multiple times in parallel).
-- Cleared on MovieFinished.
local currentlyPlayingMovie = nil

--- HandleMovieStarted: client-side handler for the server-relayed
--- "MovieStarted" event.  Looks up the AD track for the named
--- movie and plays it.  Movies the AD_TRACKS table doesn't cover
--- are silently ignored.  Duplicate relays for the same movie
--- (multiple Osi signals firing in tandem) are deduplicated.
---
--- @param eventData table  { event = "MovieStarted", movie = "...",
---                           source = "..." (optional, diagnostic) }
local function HandleMovieStarted(eventData)
    local movieName = tostring(eventData and eventData.movie or "")
    local source = tostring(eventData and eventData.source
        or "<unknown>")
    if movieName == "" then return end
    if currentlyPlayingMovie == movieName then
        Log.Debug("AD: MovieStarted '" .. movieName
            .. "' via " .. source .. " -- already playing,"
            .. " ignored as duplicate")
        return
    end
    local entry = AD_TRACKS[movieName]
    Log.Info("AD: MovieStarted '" .. movieName
        .. "' via " .. source
        .. (entry and (" -> " .. tostring(entry.file)
            .. (entry.delayMs and (" (+" .. entry.delayMs
                .. "ms)") or ""))
            or " (no AD track)"))
    if not entry or not entry.file then return end
    currentlyPlayingMovie = movieName
    local fullPath = AD_BASE_PATH .. entry.file
    local delayMs = tonumber(entry.delayMs) or 0
    local function doPlay()
        local playOk, playResult = pcall(Ext.Audio.PlayFile, fullPath)
        if playOk then
            Log.Info("AD: PlayFile returned " .. tostring(playResult))
        else
            Log.Warning("AD: PlayFile error: " .. tostring(playResult))
        end
    end
    if delayMs > 0 then
        Log.Info("AD: scheduling " .. entry.file .. " in "
            .. delayMs .. "ms (path=" .. fullPath .. ")")
        BG3Access.Client.Scheduler.RunAfterMs(delayMs, doPlay)
    else
        Log.Info("AD: playing " .. entry.file
            .. " (path=" .. fullPath .. ")")
        doPlay()
    end
end

--- HandleMovieFinished: client-side handler for the server-relayed
--- "MovieFinished" event.  Stops any currently-playing AD track.
--- The natural-end case is fine to stop because the AD file's
--- duration is matched to the cinematic; the user-skip case is
--- what really matters (no more talking after the visuals are
--- gone).
---
--- Server side subscribes to Osi.MovieFinished (Event, 1 arg).
---
--- @param eventData table  { event = "MovieFinished", movie = "..." }
local function HandleMovieFinished(eventData)
    local movieName = tostring(eventData and eventData.movie or "")
    Log.Info("AD: MovieFinished '" .. movieName .. "' -- stopping AD")
    currentlyPlayingMovie = nil
    pcall(Ext.Audio.StopFile)
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
    HandleMovieStarted         = HandleMovieStarted,
    HandleMovieFinished        = HandleMovieFinished,
    ResetDialogState           = ResetDialogState,
}
