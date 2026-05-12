-- File: Client/Notifications.lua
--
-- Reads HUD notification popups -- recipe unlocked / spell learned /
-- item received / new region / journal updated / quest done /
-- lockpick progress -- from the always-loaded Notification_c widget.
--
-- Architecture (verified against
-- D:\extracted packs\Mods\MainUI\GUI\Pages\Notification_c.xaml and
-- D:\extracted packs\Public\Game\GUI\Library\NotificationLib.xaml):
--
-- The widget is permanent: a single Notification_c UIWidget lives at
-- the top of the application Canvas regardless of game state.  Its
-- inner ContentControl x:Name="Notifications" binds DataContext to
-- CurrentPlayer.UIData.Notification and uses a Style.TemplateSwitcher
-- to render different ControlTemplates per Notification.Type:
--   - RecipesUnlocked  / NewSpell / NewItem  -> IconNotificationTemplate
--   - QuestDone                              -> QuestDoneNotificationTemplate
--   - JournalUpdate                          -> JournalUpdateNotificationTemplate
--   - Region                                 -> RegionNotificationTemplate
--   - LockPick / progress                    -> ProgressBarNotificationTemplate
-- When Notification.Type == "None" the inner ContentControl is
-- collapsed (DataTrigger at Notification_c.xaml line 93) and no
-- TextBlocks are rendered.
--
-- No event signal exists for Notification.Type transitions: there is
-- no Osi event, no focused element (notifications don't take focus),
-- and no widget Loaded event (the outer UIWidget is permanent).
-- Polling is the only available mechanism.
--
-- Driver: Ext.Events.Tick.  Snapshot dispatch from the C++ focus
-- monitor is gated on change flags (focusChanged/selectionChanged/
-- widgetAdded/etc.) and does NOT fire during stable gameplay -- so
-- driving Notifications off snapshot dispatch caused popups to be
-- silently missed during walking/exploration.  Ext.Events.Tick fires
-- every game frame regardless of UI activity, which is what polling
-- needs.
--
-- Per-tick cost analysis: Ext.UI.ReadWidgetTextBlocks does a BFS over
-- the named widget's visual tree, gated by IsVisibleDP on every node.
-- When idle, BFS visits the outer widget + sees the collapsed
-- ContentControl + skips its subtree -- O(1).  When active, the
-- visible subtree contains ~5 TextBlocks (Title, Message, plus the
-- per-Type controller / keyboard hint) -- O(small constant).  Cheap
-- enough to run unconditionally.
--
-- Speech routing: SpeechData.Alert with priority "queue" so popups
-- are announced one-off without interrupting other speech (combat
-- alerts, dialogue, item nav).  Multiple stacked notifications speak
-- in arrival order.

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

local Log        = BG3Access.Client.Log
local SpeechData = BG3Access.Client.SpeechData

local NOTIFICATION_WIDGET_NAME = "Notification_c"

--- ReadActiveTexts: BFS the Notification_c widget for currently
--- visible TextBlock texts.  Returns nil when the read fails (widget
--- not present yet, e.g. early boot) and an empty array when the
--- widget is idle.  Each TextBlock is returned as its own string;
--- callers speak them as separate Alerts so screen-reader pacing
--- and punctuation match the source material.
--- @return string[]|nil  Text array (one entry per visible TextBlock),
---     or nil on read failure.
local function ReadActiveTexts()
    local readOk, texts = pcall(
        Ext.UI.ReadWidgetTextBlocks, NOTIFICATION_WIDGET_NAME)
    if not readOk or not texts then return nil end
    local clean = {}
    for _, text in ipairs(texts) do
        if text and text ~= "" then
            clean[#clean + 1] = text
        end
    end
    return clean
end

-- Texts that appear in the Notification_c widget tree but aren't part
-- of the active-notification ContentControl.  The widget hosts a
-- separate TurnIndicationCombat Control whose "Your Turn" TextBlock
-- is rendered with Opacity=0 most of the time -- our BFS picks it up
-- because IsVisibleDP only filters by Visibility, not Opacity.  Until
-- the Notifications module is rewritten to scope its read to the
-- inner Notifications ContentControl (CurrentPlayer.UIData.Notification),
-- filter these known dormant texts OUT of the read result so they
-- don't ride along when a real notification appears alongside them.
local DORMANT_TEXTS = {
    ["Your Turn"] = true,
}

local function FilterDormant(texts)
    local kept = {}
    for _, text in ipairs(texts) do
        if not DORMANT_TEXTS[text] then
            kept[#kept + 1] = text
        end
    end
    return kept
end

-- Per-text dedup set.  When notifications overlap (recipe popup +
-- tutorial overlay both visible together), each tick produces a
-- different combined signature -- a coarse signature dedup would
-- speak each combined state once, repeating texts the user already
-- heard.  We track individual texts that have been spoken and only
-- announce ones we haven't seen yet.  When the widget goes idle (no
-- non-dormant texts), the set clears so a repeat of the same
-- notification later announces again.
local spokenTexts = {}

--- HandleSnapshot: tick-driven poll.  Detects the rendered
--- notification text and speaks newly-arrived items once.  When
--- everything goes idle, the spoken set resets so future repeats
--- of the same notification announce again.
--- @param snapshot table|nil  Unused -- driver is Ext.Events.Tick.
local function HandleSnapshot(snapshot)
    local rawTexts = ReadActiveTexts()
    if not rawTexts or #rawTexts == 0 then
        spokenTexts = {}
        return
    end
    -- Filter known dormant texts (TurnIndicationCombat "Your Turn")
    -- so they don't ride along when a real notification appears.
    local texts = FilterDormant(rawTexts)
    if #texts == 0 then
        spokenTexts = {}
        return
    end
    -- Speak each new text as its own queued Alert.  Each TextBlock is
    -- already a complete phrase from Larian's localization (with its
    -- own punctuation) -- joining them would create double-punctuation
    -- and treat semantically separate items (title + message + hints)
    -- as one phrase.  Queue mode preserves order without interrupting.
    -- Texts seen last tick AND still on screen this tick stay in the
    -- spoken set and don't re-announce.
    for _, text in ipairs(texts) do
        if not spokenTexts[text] then
            spokenTexts[text] = true
            Log.Info("NOTIFICATION: " .. text)
            SpeechData.Alert(text, "queue")
        end
    end
end

-- Tick driver: subscribe to Ext.Events.Tick instead of relying on
-- snapshot dispatch.  C++ only dispatches snapshots when something
-- changed (focusChanged/selectionChanged/widgetAdded/etc.) -- during
-- stable gameplay (just walking around), no flags fire and no
-- snapshot reaches Lua.  Notifications doesn't need snapshot data --
-- it just needs a periodic "go check the widget" -- so Ext.Events.Tick
-- is the correct driver.  Fires every game frame regardless of UI
-- activity.
local function TickHandler()
    HandleSnapshot(nil)
end

local subscribed = false
local function EnsureSubscribed()
    if subscribed then return end
    if not Ext.Events or not Ext.Events.Tick then return end
    Ext.Events.Tick:Subscribe(TickHandler)
    subscribed = true
    Log.Info("Notifications: subscribed to Ext.Events.Tick")
end

EnsureSubscribed()

local NotificationsModule = {
    HandleSnapshot = HandleSnapshot,
}

BG3Access.Client.Notifications = NotificationsModule

return NotificationsModule
