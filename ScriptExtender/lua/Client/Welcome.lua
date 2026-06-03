-- File: Client/Welcome.lua
--
-- First-launch welcome message.  Speaks a one-time orientation script
-- that points new users at the three settings most likely to affect
-- their experience (tooltips, settings menu, north-facing minimap)
-- and then closes with a greeting.
--
-- Persistence: a boolean flag (`welcomeShown`) inside the unified
-- BG3Access settings file (BG3Access_settings.json), managed via
-- Client/Settings.lua.  Registered as an internal-only key (no
-- valueOptions / no label) so the SettingsMenu does not show it.
-- Users who want to re-hear the welcome can delete the settings
-- file from their BG3 user profile directory; doing so will also
-- reset their other preferences to defaults, which is fine because
-- "I want to re-tour this mod" implies a clean slate anyway.
--
-- Timing: Welcome is required late in Client/_Init.lua, after the
-- Settings module is loaded.  Tolk reports ready well before
-- BootstrapClient.lua finishes; a small post-load delay lets the
-- audio output device finish its own init so the first phrase plays
-- cleanly.  Priority is "interrupt" so any in-flight loading-tip
-- speech is replaced and the welcome takes the floor as the first
-- coherent thing the user hears from the mod.

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

local Log        = BG3Access.Client.Log
local SpeechData = BG3Access.Client.SpeechData
local Scheduler  = BG3Access.Client.Scheduler
local Settings   = BG3Access.Client.Settings

local WELCOME_FLAG_KEY = "welcomeShown"

-- Register as internal-only (no valueOptions, no label) so it
-- persists but doesn't appear in the SettingsMenu.
if Settings and Settings.RegisterDefault then
    Settings.RegisterDefault(WELCOME_FLAG_KEY, false, nil, nil)
end

-- Welcome script split into pages.  Each page is spoken as a separate
-- announcement; the user presses A to advance to the next page.  The
-- pacing here matters more than the total content -- a single
-- ~30-second block of speech overwhelms new users; broken into
-- discrete pages with manual advance, they can take each piece in.
--
-- Last page has NO "Press A to continue" prompt -- the welcome
-- completes after it speaks.
local WELCOME_PAGES = {
    "Thank you for using this accessibility mod for BG3. "
        .. "Since this is your first time, there are a few things "
        .. "you should keep in mind. "
        .. "Press A to continue.",
    "For the best experience, it is recommended that you do not "
        .. "turn off tooltips directly in game. "
        .. "Instead, speech verbosity and other settings for the "
        .. "mod may be adjusted at any time by flicking the right "
        .. "stick down. ",
    "For consistent navigation, it is recommended that you keep "
        .. "the auto-rotate camera option off. "
        .. "You can still manually adjust the camera position if "
        .. "you wish. "
        .. "First, press R3 to disable the accessibility "
        .. "functionality. "
        .. "Then, use the right stick to adjust the camera "
        .. "normally. "
        .. "Press R3 again to re-enable accessibility "
        .. "functionality. ",
    "Have fun! Welcome to Baldur's Gate 3!",
}

local SPEAK_DELAY_MS = 500

-- Tracks position in WELCOME_PAGES across A presses.  0 before any
-- page has spoken, 1..#WELCOME_PAGES while speaking, set back to nil
-- when the welcome completes (also indicates "subscription cleaned").
local currentPageIdx = nil
-- Subscription handle for ControllerButtonInput -- captured so we can
-- unsubscribe after the last page so the A-key capture doesn't bleed
-- into normal gameplay input.
local buttonSubscription = nil

--- HasWelcomeShown: read the persistent flag.  Returns false (so the
--- welcome plays) on any failure -- treating "I don't know" as "show
--- it" is the right user-friendly default; worst case is the welcome
--- plays an extra time on a transient I/O failure.
local function HasWelcomeShown()
    if not Settings or not Settings.Get then return false end
    return Settings.Get(WELCOME_FLAG_KEY) == true
end

--- MarkWelcomeShown: flip the persistent flag and request a flush.
--- Settings.Save writes the JSON file; pcall'd so a write failure
--- doesn't break the calling flow.
local function MarkWelcomeShown()
    if not Settings or not Settings.Set then return end
    Settings.Set(WELCOME_FLAG_KEY, true)
    if Settings.Save then
        pcall(Settings.Save)
    end
end

--- SpeakPage: speak the given page index at interrupt priority.
--- Pages 1..(N-1) end with "Press A to continue"; page N is the
--- closing salutation.  Each call updates currentPageIdx so the
--- A-button handler knows where we are.
local function SpeakPage(pageIdx)
    if pageIdx < 1 or pageIdx > #WELCOME_PAGES then return end
    currentPageIdx = pageIdx
    Log.Info("WELCOME: speaking page " .. pageIdx
        .. " of " .. #WELCOME_PAGES)
    local text = WELCOME_PAGES[pageIdx]
    if SpeechData and SpeechData.Alert then
        SpeechData.Alert(text, "interrupt")
    else
        pcall(Ext.Tolk.Speak, text, true)
    end
end

--- FinishWelcome: clean up the button subscription, set the
--- persistence flag, clear state.  Called after the last page
--- speaks OR if the user is somehow stuck mid-flow (handled by
--- the "already on last page" branch in the A handler).
---
--- Also flushes any loading tips that were queued during the
--- welcome via EventRouter.QueueLoadingTipDuringWelcome -- the
--- C++-side buffer flushes one-shot, so tips we suppressed here
--- would be lost without the EventRouter-side queue.
local function FinishWelcome()
    Log.Info("WELCOME: complete, unsubscribing button handler")
    if buttonSubscription and Ext.Events
        and Ext.Events.ControllerButtonInput then
        pcall(Ext.Events.ControllerButtonInput.Unsubscribe,
            Ext.Events.ControllerButtonInput, buttonSubscription)
    end
    buttonSubscription = nil
    currentPageIdx = nil
    MarkWelcomeShown()
    -- Clear currentPageIdx BEFORE flushing tips so the flush sees
    -- IsActive()==false and doesn't re-queue them.
    local EventRouter = BG3Access.Client.EventRouter
    if EventRouter and EventRouter.FlushPendingLoadingTips then
        EventRouter.FlushPendingLoadingTips()
    end
end

--- OnButtonInput: A-button advances to next page; if we're on the
--- last page already, A finishes the welcome.  Only intercepts A
--- presses -- any other button passes through normally.
--- PreventAction suppresses the in-game effect so A doesn't double
--- as a menu confirm during the welcome.
local function OnButtonInput(event)
    if not event.Pressed then return end
    if tostring(event.Button) ~= "A" then return end
    if not currentPageIdx then return end  -- welcome already done
    event:PreventAction()
    if currentPageIdx >= #WELCOME_PAGES then
        FinishWelcome()
        return
    end
    SpeakPage(currentPageIdx + 1)
end

--- StartWelcome: schedule the first page after the audio device init
--- delay, subscribe to controller input for A-press paging.
local function StartWelcome()
    if Ext.Events and Ext.Events.ControllerButtonInput then
        buttonSubscription =
            Ext.Events.ControllerButtonInput:Subscribe(OnButtonInput)
    end
    SpeakPage(1)
end

--- MaybeSpeakWelcome: entry point.  Skips silently when the flag is
--- already set.  Otherwise schedules StartWelcome via Scheduler.RunAfterMs
--- so the audio device has time to initialize; falls back to immediate
--- start if Scheduler isn't available for any reason.
local function MaybeSpeakWelcome()
    if HasWelcomeShown() then
        Log.Info("WELCOME: flag already set, skipping")
        return
    end
    if Scheduler and Scheduler.RunAfterMs then
        Scheduler.RunAfterMs(SPEAK_DELAY_MS, StartWelcome)
    else
        StartWelcome()
    end
end

MaybeSpeakWelcome()

--- IsActive: returns true while the welcome is mid-flow (between
--- the first page speaking and FinishWelcome clearing currentPageIdx).
--- Other modules (EventRouter loading-tip handler) check this to
--- suppress their own speech while the welcome owns the audio
--- channel -- otherwise loading tips would interrupt the welcome
--- pages on first launch.
local function IsActive()
    return currentPageIdx ~= nil
end

local WelcomeModule = {
    MaybeSpeakWelcome = MaybeSpeakWelcome,
    IsActive = IsActive,
}

BG3Access.Client.Welcome = WelcomeModule

return WelcomeModule
