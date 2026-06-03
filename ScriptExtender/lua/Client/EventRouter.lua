-- File: Client/EventRouter.lua
--
-- Thin router for the BG3Access accessibility system.
--
-- ARCHITECTURE: No Noesis objects cross into Lua for focus events.
-- C++ extracts all element data during Tick() and passes a plain Lua
-- table (strings, bools, numbers) to the callback.  Lua only processes
-- primitives for speech formatting and state management.
--
-- This file is a ROUTER ONLY.  It handles cross-cutting concerns
-- (loading suppression, debug explore mode, game state transitions)
-- and dispatches snapshots to the appropriate handler module:
--   CC (Character Creation)  -> CharCreation.lua
--   Cutscene/Dialog          -> Cutscene.lua
--   WorldUI/Radials/Panels   -> WorldUI.lua
--   Pre-game menus           -> Menus.lua (per-menu handlers)

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

-- Module references (loaded before this file by _Init.lua).
local Log        = BG3Access.Client.Log
local Helpers    = BG3Access.Client.Helpers
local SpeechData = BG3Access.Client.SpeechData
local CC         = BG3Access.Client.CC
local Cutscene   = BG3Access.Client.Cutscene
local Menus      = BG3Access.Client.Menus

-- ---------------------------------------------------------------------------
-- Cross-cutting state (not owned by any single handler).
-- ---------------------------------------------------------------------------
-- Start suppressed: the mod loads during a loading state (LoadMenu)
-- and no GameStateChanged fires for the initial state.
local suppressSnapshots   = true
local lastWidgetRootStr   = nil
local inspectWidgetActive = false  -- true while PinnedTooltips_c has focus
-- Explore mode uses its own lastSpokenFullText to avoid needing a handler state.
-- Loading tips use their own dedup to avoid needing a handler state.
-- Table used as a set because multiple tips can arrive in the same snapshot.
local spokenLoadingTips = {}
-- Tips collected while the first-launch welcome was active.  The C++
-- side flushes its tip buffer one-shot, so tips we'd otherwise drop
-- get held here and replayed when Welcome calls FlushPendingLoadingTips
-- on completion.  Kept until flushed -- never auto-cleared.
local pendingTipsDuringWelcome = {}
-- True when snapshots should route to WorldUI panel handlers instead of Menus.
local routeToWorld        = false
-- Last value of routeToWorld we logged at dispatch time.  Triggers a
-- log line whenever the flag changes so silent flips become visible.
local lastRouteToWorldLogged = nil
-- True when a dialog overlay spoke on this tick while WorldUI is active.
-- Suppresses the panel handler so dialog speech isn't interrupted.
local worldDialogOverlayJustSpoke = false
local menuDialogOverlayJustSpoke  = false
-- True on world entry (Running state) to suppress the initial burst of
-- visual text from HUD widgets (Overlay "Examine/Context Menu/Actions",
-- etc.).  The RS HUD reader replaces this -- user reads when ready.
local suppressWorldEntryVisualText = false
-- True when the most recent snapshot had a focused UI element.
-- This is the authoritative "UI is active" signal from the C++
-- tick monitor.  In free world, the monitor reports focused=nil.
-- In any menu/panel, a focused element exists.  GetFocusedElement
-- on its own is unreliable because BG3's HUD has "selected" elements
-- (party member, hotbar slot) that the focus strategies pick up.
local snapshotHasUIFocus = false
-- True for one tick after worldRouteBeforeMenu restores world routing.
-- Suppresses the post-settle widget scan so background widgets like
-- PartyLine_c don't trigger handler activation on menu close.
local suppressNextWidgetScan = false
-- Authoritative game state for RS gating.  Updated on GameStateChanged
-- and seeded at startup from Ext.Utils.GetGameState.  Used by
-- IsUIActiveForRS so pre-game states always gate the stick, and in-game
-- free world always lets it through -- independent of routeToWorld,
-- which is purely about handler dispatch.
local currentGameState = "Unknown"

-- ---------------------------------------------------------------------------
-- ResolveActiveTooltipDispatcher: picks the right per-context tooltip
-- dispatch function based on priority.  Conceptually there's ONE active
-- handler at any moment for a tooltip event; this helper centralizes the
-- decision so the snapshot handler can collapse to a single dispatch
-- call instead of duplicating an if/elif/else.  Each per-context
-- DispatchTooltip function (CC, WorldUI, Menus) retains its own
-- legitimately context-specific work (CC caches lastTooltipData, WorldUI
-- handles dedup-reset / tooltip-close / compare-view / radial fallback /
-- inspect cache, Menus is trivial) -- the choice of WHICH function to
-- call lives here.
--
-- Priority order:
--   1. CC (CharCreation owns its tooltip dispatch when ccState says CC
--      is open -- highest priority because CC's own widget handlers
--      shouldn't see tooltip data).
--   2. WorldUI when EITHER routeToWorld is true OR a radial menu (RT
--      shortcuts / RB action) is open.  The radial carve-out matters
--      because radial slot tooltips need WorldUI's radial-fallback
--      path even when a Menus handler (e.g. ShortcutsMenu under
--      gui::DCGameMenu) is active for the parent widget.
--   3. Menus (default fallback for pre-game / pause-menu contexts).
--
-- Returns the dispatch function or nil if no module exposes one (which
-- would be a load-order bug -- modules are loaded before EventRouter).
-- ---------------------------------------------------------------------------
local function ResolveActiveTooltipDispatcher(routeToWorld)
    if CC.IsInCC and CC.IsInCC() then
        return CC.DispatchTooltip
    end
    local World = BG3Access.Client.WorldUI
    local inRadial = World and World.IsRadialOpen
        and World.IsRadialOpen() or false
    if (routeToWorld or inRadial)
        and World and World.DispatchTooltip then
        return World.DispatchTooltip
    end
    return Menus.DispatchTooltip
end

-- ---------------------------------------------------------------------------
-- HandleTickSnapshot: thin router.
--
-- Iterates snapshot.widgetEvents (one entry per new/changed widget this
-- tick) and dispatches each event to the handler that cares about it.
-- Each handler receives its own event data -- no shared "best" event is
-- computed here.  Routing state (routeToWorld) is updated based on which
-- handler kinds activated; menu wins over world if both appeared.
-- ---------------------------------------------------------------------------
-- Diagnostic toggle: when true, every widgetAdded event logs the
-- widget's name + DC type so cinematic / overlay widgets can be
-- identified by triggering the UI condition in-game and reading
-- the log.  Toggled by /bg3a_log_widgets console command.
local widgetIdentityLogging = false

-- Most recent snapshot, cached for the bg3a_dump_widgets command.
-- snapshot.allWidgetNames / allWidgetDCTypes are populated every
-- tick (used by Dispatcher for handler-liveness checks) -- the
-- data IS already enumerated, we just need to surface it on
-- demand for forensics.
local latestSnapshot = nil

local function HandleTickSnapshot(snapshot)
    latestSnapshot = snapshot  -- For bg3a_dump_widgets forensic command.
    Log.Debug("[BG3A_BC] phase=lua_snapshot_begin events="
        .. tostring(snapshot.widgetEvents and #snapshot.widgetEvents or 0)
        .. " removed=" .. tostring(snapshot.widgetRemoved or false))
    local widgetEvents = snapshot.widgetEvents or {}

    -- Identity diagnostic.  Logs every widgetEvent's name + dcType
    -- when the toggle is on -- used for one-off forensics when
    -- trying to map "this cinematic plays through which widget?".
    -- Toggle on, trigger the cinematic / dialog / overlay, read
    -- the log, toggle off.  See Ext.RegisterConsoleCommand below.
    if widgetIdentityLogging and #widgetEvents > 0 then
        for i, widgetEvent in ipairs(widgetEvents) do
            Log.Info("WIDGET DIAG: event[" .. i
                .. "] name='" .. tostring(widgetEvent.elemName or "")
                .. "' dcType='" .. tostring(widgetEvent.dcType or "")
                .. "' elemType='"
                .. tostring(widgetEvent.elemType or "")
                .. "'")
        end
    end
    local hasWidgetEvents = #widgetEvents > 0
    -- Track whether a menu handler activated this tick.  Used to gate
    -- the late world-panel detection at the bottom of this function so
    -- a freshly-opened menu (pause, shortcuts, etc.) isn't immediately
    -- hijacked by a leftover world panel discovered in widgetDCTypes.
    local menuActivatedThisTick = false
    local ccHandledThisTick = false

    -- =================================================================
    -- Dialog/cutscene widget events: handle BEFORE focus check since
    -- cutscenes have no focused element.  Process every cutscene event
    -- this tick (typically at most one).
    -- =================================================================
    local anyCutsceneEvent = false
    if hasWidgetEvents then
        for _, widgetEvent in ipairs(widgetEvents) do
            if widgetEvent.dcType
                and Cutscene.IsDialogOrCutscene(widgetEvent.dcType) then
                anyCutsceneEvent = true
                Cutscene.HandleDialogWidgetEvent(widgetEvent)
            end
        end
        -- If no focused element data, nothing else to do (pure cutscene).
        if anyCutsceneEvent
            and (not snapshot.focusedElement
                or not snapshot.focusedElement.elemType) then
            return
        end
    end

    -- =================================================================
    -- Loading tips: read _loadingHint_ keys from any ls.LoadingScreen
    -- widget event's namedTexts.  Runs FIRST before any routing logic
    -- that might return early (loading screen has no focused element).
    -- =================================================================
    if snapshot.widgetAdded and hasWidgetEvents then
        -- Welcome-mode handling: while the first-launch welcome is
        -- mid-flow it owns the audio channel.  We can't speak tips
        -- alongside it (they'd interrupt), and we can't just drop them
        -- because the C++ side flushes its buffer one-shot.  Solution:
        -- enqueue suppressed tips in pendingTipsDuringWelcome; Welcome
        -- calls FlushPendingLoadingTips on completion to speak them.
        local Welcome = BG3Access.Client.Welcome
        local welcomeActive = Welcome and Welcome.IsActive
            and Welcome.IsActive()
        for _, widgetEvent in ipairs(widgetEvents) do
            if widgetEvent.dcType == "ls.LoadingScreen"
                and widgetEvent.namedTexts then
                for textKey, textValue in pairs(widgetEvent.namedTexts) do
                    if textKey:find("^_loadingHint_") then
                        if textValue and textValue ~= ""
                            and not textValue:match("^%d+%%?$")
                            and not spokenLoadingTips[textValue] then
                            -- Mark spoken either way so we don't
                            -- enqueue duplicates if the same text
                            -- arrives in two widget events.
                            spokenLoadingTips[textValue] = true
                            if welcomeActive then
                                Log.Info("LOADING TIP (queued during"
                                    .. " welcome): " .. textValue)
                                pendingTipsDuringWelcome[
                                    #pendingTipsDuringWelcome + 1] =
                                    textValue
                            else
                                Log.Info("LOADING TIP: " .. textValue)
                                -- One-off announcement, no field
                                -- structure -- Alert is the correct
                                -- primitive per the speech architecture
                                -- (CLAUDE.md).  "queue" so multiple
                                -- buffered tips speak in order and a
                                -- tip in flight isn't killed by the
                                -- next one arriving.
                                SpeechData.Alert(textValue, "queue")
                            end
                        end
                    end
                end
            end
        end
    end

    -- =================================================================
    -- HUD notification popups (Notification_c): recipe unlocks, spell
    -- learns, item pickups, region announcements, journal/quest
    -- updates.  Permanent widget with a Style.TemplateSwitcher driven
    -- by Notification.Type; no focus, no Loaded event for activation.
    -- The Notifications module BFS-reads its visible TextBlocks per
    -- tick (cheap when idle -- inner ContentControl is collapsed,
    -- BFS bails on IsVisibleDP filter).  See Notifications.lua for
    -- the full architecture note.
    -- =================================================================
    -- Notifications now drives itself off Ext.Events.Tick (see
    -- Notifications.lua) rather than snapshot dispatch -- snapshot
    -- dispatch is gated on change flags and won't fire during stable
    -- gameplay, but notification popups can appear without any of
    -- those flags being set.  No call here.

    local focusedElement = snapshot.focusedElement

    -- =================================================================
    -- Dialog answer selection: D-pad through answer choices in a
    -- DCDialogue fires snapshots where the selected LSListBoxItem has
    -- dcType = "gui::VMDialogueAnswer".  Noesis keyboard focus never
    -- moves during dialog navigation (the XAML binds UIUp/UIDown to
    -- custom SelectorUpCommand / SelectorDownCommand handlers that
    -- mutate ActiveDialogue.LocalHighlightedAnswer directly), so the
    -- global focus monitor reports it as a selection change via
    -- Strategy 3 (IsSelected tree walk).
    --
    -- Without this interception the snapshot falls through to the
    -- default MainMenu handler, which extracts only the
    -- AnswerTextPrefix TextBlock ("1.", "2.", "3.") because the
    -- generic text extraction does not walk deep enough for the full
    -- AnswerText inside the ListBoxItem template.  Route to Cutscene
    -- instead so the full answer text is spoken.
    if focusedElement
        and focusedElement.dcType == "gui::VMDialogueAnswer" then
        Cutscene.HandleDialogAnswerSnapshot(snapshot)
        return
    end
    -- Fallback: dialogue answer data may arrive via selectedElement
    -- (event-driven mode puts the selected ListBoxItem's data into
    -- selectedElement when focused is nil during dialogue).
    if snapshot.selectedElement
        and snapshot.selectedElement.dcType == "gui::VMDialogueAnswer" then
        snapshot.focusedElement = snapshot.selectedElement
        Cutscene.HandleDialogAnswerSnapshot(snapshot)
        return
    end

    -- =================================================================
    -- CC dispatch (early): CC snapshots may lack elemType during rapid
    -- focus bounces (e.g. guardian page entry).  Route to CC handler
    -- before the elemType filter so they aren't dropped.
    -- =================================================================
    if not suppressSnapshots then
        local isCC = focusedElement and CC.IsCCSnapshot(snapshot)
        -- Standalone carousel events during CC (inline appearance
        -- carousels) arrive with dcType=(none) since focus didn't
        -- change.  IsCCSnapshot misses them, but they belong to the
        -- CC carousel and must not fall through to Menus (which would
        -- speak the bare name, then the INPC follow-up speaks
        -- name+desc, causing audible double-reads).
        if not isCC and CC.IsInCC()
            and snapshot.inlineCarouselChanged then
            isCC = true
        end
        -- DEV-ONLY: CC widget re-appearance on reload ticks.
        -- After a mid-session Lua reset, the CC widget event fires
        -- on a tick where focusedElement is nil (C++ focus cache was
        -- wiped).  Route to HandleCCSnapshot so it picks up
        -- currentWidgetDCType before the next focused tick.
        -- Users never hit this (DevConfig.lua is excluded from
        -- releases; on normal first entry the widget and focus
        -- arrive on the same tick after the settle cycle).
        if not isCC and BG3Access.DevMode and hasWidgetEvents then
            for _, widgetEvent in ipairs(widgetEvents) do
                if widgetEvent.dcType == "gui::DCCharacterCreation"
                    or widgetEvent.dcType
                        == "gui::DCCharacterLevelUp" then
                    isCC = true
                    break
                end
            end
        end
        if isCC then
            CC.HandleCCSnapshot(snapshot)
            ccHandledThisTick = true
            -- Don't return: the tooltip section below must run for
            -- CC snapshots too (clears dedup on focus changes,
            -- processes tooltip data when it arrives).
        end
    end

    -- =================================================================
    -- Radial slot events (RT shortcuts menu, RB action radial).
    -- =================================================================
    if snapshot.radialSlotChanged then
        local World = BG3Access.Client.WorldUI
        if World then
            World.HandleRadialSlot(snapshot)
        end
        return
    end

    -- =================================================================
    -- Context menu events (WorldContextMenu popup -- X button actions).
    -- =================================================================
    if snapshot.contextMenuChanged then
        local itemText = snapshot.contextMenuItemText
        if itemText and itemText ~= "" then
            local contextSpeech = SpeechData.Create()
            contextSpeech:Add("name", itemText, "brief")
            Log.Info("CONTEXT MENU: " .. itemText)
            Ext.Tolk.Speak(contextSpeech:Format(), true)
        end
        return
    end

    -- =================================================================
    -- Widget added events: iterate snapshot.widgetEvents and dispatch
    -- each event to the handler that owns it.  Process BEFORE the
    -- focusedElement guard: widget events describe the NEW widget, not
    -- the focused element, and must register panel handlers even when
    -- focusedElement is nil (UI rebuilding).  Skip during loading
    -- suppression -- no handler routing needed.
    -- =================================================================
    if not suppressSnapshots and snapshot.widgetAdded and hasWidgetEvents then
        -- Skip widget scan noise after menu close (e.g., PartyLine_c
        -- re-discovered when returning to world from shortcuts/radials).
        -- Filter the events: drop generic HUD re-discovery events but
        -- KEEP events that match a REGISTERED handler (menu OR world).
        -- Reasons:
        --   - Menu events: the user closing a menu and immediately
        --     reopening one would lose the reopen's activation if we
        --     dropped all events in the suppression window.
        --   - World panel events: a panel like Tutorial popping up
        --     after a camp transition arrives in the suppression
        --     window; if we drop it, onWidgetAdded never runs and
        --     the panel's screen entry has no title/body to speak.
        -- Only events that match NO registered handler are genuine
        -- noise to suppress.
        if suppressNextWidgetScan then
            suppressNextWidgetScan = false
            local World = BG3Access.Client.WorldUI
            local filteredEvents = {}
            for _, widgetEvent in ipairs(widgetEvents) do
                local dcType = widgetEvent.dcType or ""
                local elemName = widgetEvent.elemName or ""
                local matchesMenu = Menus.IsMenuDCType(dcType)
                    or (Menus.IsMenuWidgetName
                        and Menus.IsMenuWidgetName(elemName))
                local matchesWorld = World
                    and ((World.IsWorldDCType
                            and World.IsWorldDCType(dcType))
                        or (World.IsWorldWidgetName
                            and World.IsWorldWidgetName(elemName)))
                -- Dialog overlays (LSMessageBoxData widgets like the
                -- Long Rest "Do you want to end the day?" confirmation)
                -- are NOT in any registered handler's openWhen -- they
                -- speak via Menus.HandleDialogOverlay directly without
                -- switching the active handler.  Without keeping them
                -- here, the post-menu-close suppression silently drops
                -- the dialog right when it arrives, and the user gets
                -- no prompt at all.  Bug seen specifically after closing
                -- the character sheet: the widget address churn makes
                -- the next cache rebuild report changed=0 (so the
                -- non-suppress fast path in C++ doesn't run), so this
                -- filter is the only path the dialog has into dispatch.
                local matchesDialogOverlay =
                    Menus.IsDialogOverlay and Menus.IsDialogOverlay(dcType)
                if matchesMenu or matchesWorld or matchesDialogOverlay then
                    filteredEvents[#filteredEvents + 1] = widgetEvent
                end
            end
            if #filteredEvents == 0 then
                snapshot.widgetAdded = false
                Log.Debug("WIDGET EVENT suppressed (menu close re-scan)")
            else
                widgetEvents = filteredEvents
                Log.Debug("WIDGET EVENT partial suppression "
                    .. "(menu close re-scan): kept "
                    .. #filteredEvents .. " registered-handler events, "
                    .. "dropped unregistered HUD noise")
            end
        end

        if snapshot.widgetAdded then
            local World = BG3Access.Client.WorldUI

            -- Reset dialog state once per tick when no cutscene event
            -- fired.  A new widget that isn't a cutscene means the
            -- dialogue has ended or been replaced.
            if not anyCutsceneEvent then
                Cutscene.ResetDialogState()
            end

            -- Dispatch each widget event independently.  Track which
            -- handler kinds activated so we can update routeToWorld
            -- once after the loop (menu > world priority).
            local worldActivated = false
            local menuActivated = false
            local dialogOverlaySpoke = false

            for _, widgetEvent in ipairs(widgetEvents) do
                local dcType = widgetEvent.dcType
                if dcType and not Cutscene.IsDialogOrCutscene(dcType) then
                    Log.Debug("WIDGET EVENT: dcType=" .. dcType
                        .. " name=" .. tostring(widgetEvent.elemName))


                    if Menus.IsDialogOverlay(dcType) then
                        -- Dialog overlays (MessageBox): speak, don't
                        -- switch the active handler.
                        local spoke = Menus.HandleDialogOverlay(
                            snapshot, widgetEvent)
                        if spoke then dialogOverlaySpoke = true end
                    else
                        -- CC always gets widget events (detects its
                        -- own re-appearance).
                        CC.HandleWidgetAdded(widgetEvent)

                        if World and World.IsWorldDCType(dcType) then
                            World.HandlePanelWidgetAdded(widgetEvent)
                            worldActivated = true
                        elseif Menus.IsMenuDCType(dcType) then
                            -- Only switch back to Menus for explicitly
                            -- handled menu DC types.  Generic types
                            -- (ls.Widget, ls.DCPartyLine) must NOT
                            -- reset WorldUI routing.
                            Menus.HandleWidgetAdded(widgetEvent)
                            menuActivated = true
                        elseif Menus.IsMenuWidgetName
                            and Menus.IsMenuWidgetName(
                                widgetEvent.elemName) then
                            -- Menu-side widget-name routing: handlers
                            -- that identify by widget x:Name only
                            -- (PauseMenu = "GameMenu_c", ShortcutsMenu
                            -- = "shortcutsMenu" -- both share DC
                            -- gui::DCGameMenu so the DC alone can't
                            -- distinguish them).  Without this branch,
                            -- their widgetAdded events fall through to
                            -- the "generic noise" else and never
                            -- activate.
                            Menus.HandleWidgetAdded(widgetEvent)
                            menuActivated = true
                        elseif World and World.IsWorldWidgetName
                            and World.IsWorldWidgetName(
                                widgetEvent.elemName) then
                            -- Known in-game widget with a generic DC
                            -- (e.g. JournalCombatLog_c whose runtime
                            -- DC is ls.Widget).  Route to WorldUI by
                            -- widget x:Name, same way Menus uses
                            -- widget-name routing for shortcutsMenu.
                            -- This also flips routeToWorld back to
                            -- true via the worldActivated branch
                            -- below, so subsequent generic-DC HUD
                            -- noise resumes routing through WorldUI.
                            World.HandlePanelWidgetAdded(widgetEvent)
                            worldActivated = true
                        else
                            -- Generic/unknown DC type (HUD noise).
                            -- Forward to WorldUI only in world mode
                            -- (WorldUI safely ignores unhandled types).
                            -- Do NOT forward to Menus -- the default
                            -- handler would activate for HUD noise.
                            if routeToWorld and World then
                                World.HandlePanelWidgetAdded(widgetEvent)
                            end
                        end
                    end
                end
            end

            -- Flip routeToWorld based on what activated this tick.
            -- Menu wins over world: if both a menu and a world widget
            -- appeared on the same tick, a menu was just opened on top
            -- of the world (pause, shortcuts, etc.).
            if menuActivated then
                menuActivatedThisTick = true
                if routeToWorld then
                    if World then World.ResetAllPanelHandlers() end
                    routeToWorld = false
                    Log.Info("Routing to Menus (from world)")
                end
            elseif worldActivated then
                if not routeToWorld then
                    Menus.ResetAllHandlers()
                    routeToWorld = true
                    Log.Info("Routing to WorldUI panels")
                end
            end

            -- When a dialog overlay spoke this tick, suppress the
            -- subsequent active-handler dispatch so the handler's
            -- own item speech (interrupt-mode Tolk.Speak) doesn't
            -- cut off the dialog mid-word.  Two flags because the
            -- world and menu dispatch paths are separate -- one
            -- gets consumed depending on routeToWorld.
            if dialogOverlaySpoke then
                if routeToWorld then
                    worldDialogOverlayJustSpoke = true
                else
                    menuDialogOverlayJustSpoke = true
                end
            end
        end  -- end of "if snapshot.widgetAdded then" block
    end

    -- =================================================================
    -- Tooltip events: process BEFORE focusedElement guard.
    -- Tooltip-only snapshots (no focus/selection change) have no
    -- focusedElement and would be dropped by the guard below.
    --
    -- Hub-and-spoke: the hub passes raw structured tooltip data
    -- (array of {role, text} tables) to the active handler.
    -- Each handler builds its own SpeechData from the roles it
    -- cares about via customTooltipFn.  Single dispatch point;
    -- ResolveActiveTooltipDispatcher picks the right per-context
    -- function based on priority (see helper above).
    -- =================================================================
    if not suppressSnapshots then
        if snapshot.tooltipChanged
            or snapshot.focusChanged
            or snapshot.selectionChanged then
            -- Raw structured tooltip data: array of {role, text}.
            -- nil when no tooltip data arrived this tick.
            local structuredTooltipData = nil
            if snapshot.tooltipChanged
                and snapshot.tooltipTexts
                and #snapshot.tooltipTexts > 0 then
                structuredTooltipData = snapshot.tooltipTexts
            end

            local dispatch = ResolveActiveTooltipDispatcher(routeToWorld)
            if dispatch then
                dispatch(structuredTooltipData, snapshot)
            end
        end
    end

    -- Update UI focus flag.  Event-driven: only update when the
    -- snapshot actually carries focus information.  Snapshots fire
    -- per-event (widget add/remove, INPC notification, tooltip
    -- change, etc.); only focus-bearing snapshots have an
    -- authoritative focusedElement field.  Widget-add snapshots
    -- (e.g. cutscene widget refresh) come through with focusedElement
    -- = nil even when the user is genuinely focused on something --
    -- if we recompute snapshotHasUIFocus from those, it flickers
    -- false and gates RS off mid-navigation.
    --
    -- Authoritative signals (in order of priority):
    --   1. snapshot.focusChanged = true: focus state genuinely
    --      changed this snapshot.  Update from focusedElement
    --      (if non-nil = gained, if nil = lost).
    --   2. focusedElement present (non-nil) on any snapshot: even
    --      without focusChanged, that's evidence focus is still
    --      where we thought.  Update if changed.
    --   3. Otherwise: keep prior value.  The snapshot doesn't
    --      provide focus info.
    local hadUIFocus = snapshotHasUIFocus
    if snapshot.focusChanged then
        snapshotHasUIFocus = (focusedElement ~= nil
            and focusedElement.elemType ~= nil
            and focusedElement.elemType ~= "")
    elseif focusedElement ~= nil
        and focusedElement.elemType ~= nil
        and focusedElement.elemType ~= "" then
        snapshotHasUIFocus = true
    end
    -- Note: when focusedElement is nil and focusChanged is false,
    -- snapshotHasUIFocus is unchanged (preserved across the snapshot).

    if hadUIFocus and not snapshotHasUIFocus then
        -- Focus genuinely transitioned true -> false (focusChanged
        -- fired with no focusedElement).  Silence in-progress speech
        -- only when no handler is active -- a panel/menu/CC handler
        -- being active means the UI is still open even if focus
        -- briefly dropped during a transition.
        local World = BG3Access.Client.WorldUI
        local hasActiveHandler = Menus.GetActiveHandler()
            or (World and World.GetActivePanelHandler
                and World.GetActivePanelHandler())
            or (CC.IsInCC and CC.IsInCC())
        if not hasActiveHandler then
            Ext.Tolk.Silence()
        end
    end

    -- =================================================================
    -- Widget removal: C++ detected a widget going invisible.
    -- If the removed widget matches the active menu handler, switch
    -- routing back to WorldUI.  Event-driven, no per-tick polling.
    -- =================================================================
    if snapshot.widgetRemoved and snapshot.removedWidgetData
        and not routeToWorld then
        local removedName = snapshot.removedWidgetData.elemName or ""
        local removedDCType = snapshot.removedWidgetData.dcType or ""
        local activeHandler = Menus.GetActiveHandler()
        local activeWidgetNames = Menus.GetActiveHandlerWidgetNames
            and Menus.GetActiveHandlerWidgetNames() or nil
        local hasAnyActiveName = activeWidgetNames
            and next(activeWidgetNames) ~= nil

        -- Check if the removed widget matches the active handler.
        -- Match by widget name first (distinguishes shortcuts menu
        -- from pause menu when both share gui::DCGameMenu), then
        -- by DC type as fallback.
        local handlerMatched = false
        if hasAnyActiveName and removedName ~= ""
            and activeWidgetNames[removedName] then
            handlerMatched = true
        elseif activeHandler and removedDCType ~= ""
            and Menus.IsMenuDCType(removedDCType) then
            -- DC type match: only if the handler was NOT activated by
            -- widget name (otherwise we'd false-match on shared types).
            if not hasAnyActiveName then
                handlerMatched = true
            end
        end

        -- Fallback: snapshot.removedWidgetData is a single field (per
        -- the C++ TickSnapshot design -- not a vector like
        -- widgetEvents).  Multi-widget menus close several widgets
        -- simultaneously and C++ can only report ONE of them.  If the
        -- reported one wasn't the active handler's specifically-
        -- registered widget x:Name, the explicit match above fails --
        -- yet the active handler's widget IS gone from the live set.
        -- Use the SAME widgetRemoved event as our trigger but check
        -- allWidgetNames to authoritatively detect a missing widget.
        -- Still event-driven (only fires when SOMETHING was removed),
        -- not a per-tick poll.
        --
        -- ANY-MATCH: a handler may register MULTIPLE widget names
        -- (e.g. SaveLoad covers both LoadGame_c and SaveGame_c --
        -- only one of those is present in any given visit).  The
        -- handler is still alive as long as AT LEAST ONE of its
        -- registered names is in the live widget set.  Previously
        -- this used a single arbitrarily-picked name and false-
        -- matched on Load Game visits (checked SaveGame_c, found
        -- it missing, deactivated the live handler).
        if not handlerMatched and activeHandler and hasAnyActiveName
            and snapshot.allWidgetNames then
            local anyPresent = false
            for _, liveWidgetName in ipairs(snapshot.allWidgetNames) do
                if activeWidgetNames[liveWidgetName] then
                    anyPresent = true
                    break
                end
            end
            if not anyPresent then
                handlerMatched = true
                local nameList = {}
                for name in pairs(activeWidgetNames) do
                    nameList[#nameList + 1] = name
                end
                Log.Info("Widget removal liveness fallback: "
                    .. "removedWidgetData reported '" .. removedName
                    .. "' AND none of the active handler's widgets {"
                    .. table.concat(nameList, ", ")
                    .. "} are in allWidgetNames")
            end
        end

        if handlerMatched then
            Menus.ResetAllHandlers()
            routeToWorld = true
            suppressNextWidgetScan = true
            Log.Info("Routing back to WorldUI (widget removed: "
                .. removedName .. " dc=" .. removedDCType .. ")")
        end
    end

    -- =================================================================
    -- Generic menu liveness check.  Runs every snapshot regardless of
    -- focusedElement state.  Catches the case where a menu's widget
    -- closed but didn't fire snapshot.widgetRemoved (e.g. the radial
    -- closes visually without unloading its widget, or C++ misses the
    -- visibility transition).  The dispatcher's normal Step-1 liveness
    -- inside Menus.RouteSnapshot is gated below by the focusedElement
    -- guard, so post-close "no focus" snapshots never reach it -- this
    -- closes that gap.  Uses snapshot.allWidget* (loaded-state) per the
    -- dispatcher design statement.  No-op when the active handler's
    -- widget is still loaded.
    -- =================================================================
    if not routeToWorld and not suppressSnapshots
        and Menus.CheckLiveness and Menus.GetActiveHandler then
        local wasActive = Menus.GetActiveHandler() ~= nil
        Menus.CheckLiveness(snapshot)
        local stillActive = Menus.GetActiveHandler() ~= nil
        if wasActive and not stillActive then
            routeToWorld = true
            suppressNextWidgetScan = true
            Log.Info("Routing back to WorldUI "
                .. "(menu liveness check deactivated handler)")
        end
    end

    -- =================================================================
    -- Radial liveness check.  The radial closes whenever the player
    -- picks a slot (potion, action, spell) -- the ActionRadials
    -- widget unloads, but in many cases the closing tick has no
    -- focusChanged we can hook (focus moves to nothing / combat
    -- target / HUD, none of which produce a Noesis focused-element
    -- transition we'd see in HandleSnapshot).  Without a hook, the
    -- inRadial flag stays pinned true and GetRadialDetailHandler
    -- keeps hijacking RS-Left from GPS / panel detail view.
    --
    -- Authoritative signal: the "ActionRadials" widget x:Name is
    -- present in snapshot.allWidgetNames iff the radial is loaded.
    -- This check runs every snapshot regardless of focus state,
    -- closing the gap the focus-driven path leaves open.  No-op
    -- when the radial is genuinely open OR was never opened.
    -- =================================================================
    do
        local World = BG3Access.Client.WorldUI
        if World and World.IsRadialOpen and World.IsRadialOpen()
            and World.ClearRadialFocus
            and snapshot.allWidgetNames then
            local radialWidgetPresent = false
            for _, liveWidgetName in ipairs(snapshot.allWidgetNames) do
                if liveWidgetName == "ActionRadials" then
                    radialWidgetPresent = true
                    break
                end
            end
            if not radialWidgetPresent then
                Log.Info("Radial liveness check: ActionRadials gone --"
                    .. " clearing radial focus")
                World.ClearRadialFocus()
            end
        end
    end

    -- =================================================================
    -- Early menu delivery: some menus (shortcuts radial) use local
    -- focus instead of standard IsFocused/FocusManager, so the C++
    -- focus strategies never report a focusedElement for them.
    -- Deliver the snapshot to Menus before the focusedElement guard
    -- drops it, so the screen entry announcement fires.  Trigger when
    -- any widget event this tick carries a menu DC type.
    -- =================================================================
    if not suppressSnapshots
        and snapshot.widgetAdded and hasWidgetEvents
        and (not focusedElement or not focusedElement.elemType) then
        local hasMenuEvent = false
        for _, widgetEvent in ipairs(widgetEvents) do
            if widgetEvent.dcType
                and Menus.IsMenuDCType(widgetEvent.dcType) then
                hasMenuEvent = true
                break
            end
        end
        if hasMenuEvent then
            if not routeToWorld then
                Menus.RouteSnapshot(snapshot)
            end
            return
        end
    end

    -- Clear widget scan suppression once the user navigates to something.
    if suppressNextWidgetScan and snapshot.focusChanged then
        suppressNextWidgetScan = false
    end

    -- =================================================================
    -- focusedElement guard: everything below needs a valid focus target.
    -- Widget-added events (above) are processed regardless.  Radial
    -- liveness handled in its own block above -- runs regardless of
    -- focus state via snapshot.allWidgetNames.
    -- =================================================================
    if not focusedElement or not focusedElement.elemType then return end

    -- =================================================================
    -- Loading suppression: skip handler dispatch during loading.
    -- =================================================================
    if suppressSnapshots then
        return
    end

    -- =================================================================
    -- World entry announcement: one-shot replacement for the junk
    -- visual text burst (Overlay "Examine", "Context Menu", etc.).
    -- Speaks character name + info via ReadHUDInfo instead.
    -- =================================================================
    if suppressWorldEntryVisualText then
        suppressWorldEntryVisualText = false
        if focusedElement.namedTexts then
            for textKey, _ in pairs(focusedElement.namedTexts) do
                focusedElement.namedTexts[textKey] = nil
            end
        end
        local hudOk, hudInfo = pcall(Ext.UI.ReadHUDInfo)
        if hudOk and hudInfo then
            local parts = {}
            if hudInfo.characterName and hudInfo.characterName ~= "" then
                parts[#parts + 1] = hudInfo.characterName
            end
            if hudInfo.characterInfo and hudInfo.characterInfo ~= "" then
                parts[#parts + 1] = hudInfo.characterInfo
            end
            if #parts > 0 then
                local greetingSpeech = SpeechData.Create()
                if hudInfo.characterName and hudInfo.characterName ~= "" then
                    greetingSpeech:Add("name",
                        hudInfo.characterName, "brief")
                end
                if hudInfo.characterInfo and hudInfo.characterInfo ~= "" then
                    greetingSpeech:Add("value",
                        hudInfo.characterInfo, "normal")
                end
                local greeting = greetingSpeech:Format()
                Log.Info("WORLD ENTRY: " .. greeting)
                Ext.Tolk.Speak(greeting, true)
            end
        end
        return  -- skip handler dispatch for this snapshot
    end

    -- =================================================================
    -- Widget root tracking: detect UI teardown/rebuild.
    -- =================================================================
    local widgetRootId = focusedElement.widgetRootId or ""
    if widgetRootId ~= "" and widgetRootId ~= lastWidgetRootStr then
        lastWidgetRootStr = widgetRootId
        inspectWidgetActive = false  -- widget root changed, inspect closed
        Log.Info("Widget root changed to " .. widgetRootId)
        -- Reset the radial-open flag on any widget root change.
        -- Closing the radial hides it but doesn't fully unload the
        -- widget, so widgetRemoved doesn't fire -- but the widget
        -- root DOES change (back to PartyLine/Minimap/etc.).  LB/RB
        -- page switches within an open radial do NOT change the
        -- widget root, so this doesn't step on page-switch dedup.
        -- If the new root IS the radial (fresh open), the subsequent
        -- focus event on VMHotBar will re-arm inRadial via
        -- HandleRadialOpen and speak "Action Radial" again.
        local World = BG3Access.Client.WorldUI
        if World and World.ClearRadialFocus then
            World.ClearRadialFocus()
        end
        if routeToWorld then
            if World then
                World.HandlePanelWidgetRootChanged(widgetRootId)
            end
        else
            Menus.HandleWidgetRootChanged()
        end
    end

    -- =================================================================
    -- HotBar (action radial) focus tracking.
    -- When focus first moves to a VMHotBar element, the action radial
    -- has just opened -- route to World for intro speech.  LB/RB page
    -- switches also cause VMHotBar focus changes but are suppressed
    -- by World (inRadial flag).  When focus moves to any non-radial
    -- element, clear the flag so the next open is detected.
    --
    -- Only return early when NOT in WorldUI panel mode.  When a panel
    -- is active, the radial open is still announced but the snapshot
    -- must also reach the panel handler for state tracking.
    -- =================================================================
    if snapshot.focusChanged then
        local World = BG3Access.Client.WorldUI
        if World then
            if focusedElement.dcType
                and focusedElement.dcType:find("VMHotBar") then
                World.HandleRadialOpen()
                if not routeToWorld then
                    return
                end
            else
                World.ClearRadialFocus()
            end
        end
    end

    -- =================================================================
    -- PinnedTooltips_c: inspect panel (right stick).
    -- On widgetAdded: speak the full tooltip data (dice, damage, etc.).
    -- On subsequent focus changes: read the focused side panel's text
    -- via C++ BFS and speak it (Advantage, Disadvantage, range, etc.).
    -- =================================================================
    local pinnedTooltipsEvent = nil
    if hasWidgetEvents then
        for _, widgetEvent in ipairs(widgetEvents) do
            if widgetEvent.elemName == "PinnedTooltips_c" then
                pinnedTooltipsEvent = widgetEvent
                break
            end
        end
    end
    if pinnedTooltipsEvent then
        inspectWidgetActive = true
        local World = BG3Access.Client.WorldUI
        if World then
            World.SpeakInspectData()
        end
        return
    end

    -- D-pad navigation within the inspect panel: route to WorldUI.
    if inspectWidgetActive and snapshot.focusChanged then
        local World = BG3Access.Client.WorldUI
        if World then
            World.HandleInspectNav()
        end
        return
    end

    -- =================================================================
    -- Dispatch to the active handler module.
    -- =================================================================

    -- Late world panel detection: when every widget event this tick
    -- carried a generic DC type (ls.Widget) but a panel widget is
    -- actually present, the widget dispatch block above missed it.
    -- WorldUI owns the detection logic (checking focused/selected/widget
    -- DC types against its handler table).
    --
    -- Skip when a menu activated this tick: the user just opened a
    -- menu (pause, shortcuts, options), and a leftover world panel
    -- (e.g. Examine widget still in widgetDCTypes from earlier) must
    -- not hijack routing back to WorldUI.
    if not routeToWorld and not menuActivatedThisTick
        and (snapshot.focusChanged or snapshot.selectionChanged) then
        local World = BG3Access.Client.WorldUI
        if World and World.TryActivateFromSnapshot(snapshot) then
            Menus.ResetAllHandlers()
            routeToWorld = true
            Log.Info("Routing to WorldUI (late detection)")
        end
    end

    -- Skip menu/world dispatch when CC already handled this snapshot.
    -- Without this gate, both CC and Menus (PartyLine) would process
    -- the same snapshot, causing duplicate speech.
    if not ccHandledThisTick then
        -- Diagnostic: log every dispatch-time transition in routeToWorld
        -- so silent flips become visible.  Once the stuck-routing issue
        -- is diagnosed this can come out.
        if lastRouteToWorldLogged ~= routeToWorld then
            Log.Info("DISPATCH: routeToWorld=" .. tostring(routeToWorld))
            lastRouteToWorldLogged = routeToWorld
        end
        if routeToWorld then
            -- Dialog overlay just spoke on this tick -- suppress the panel
            -- handler so it doesn't immediately interrupt the dialog speech.
            if worldDialogOverlayJustSpoke then
                worldDialogOverlayJustSpoke = false
                return
            end
            local World = BG3Access.Client.WorldUI
            if World then
                World.RoutePanelSnapshot(snapshot)
            end
        else
            -- Same guard for the menu path: a dialog overlay that
            -- spoke this tick (e.g. SaveLoad "delete?" confirmation)
            -- must not be clobbered by the active menu handler's
            -- item speech immediately after.
            if menuDialogOverlayJustSpoke then
                menuDialogOverlayJustSpoke = false
                return
            end
            Menus.RouteSnapshot(snapshot)
            -- Recovery: if Menus.RouteSnapshot finishes with no
            -- active handler, the menu we were routed for has
            -- closed (staleness check cleared it OR the in-game
            -- gate skipped the MainMenu default).  Flip routing
            -- back to world so the next snapshot reaches WorldUI
            -- and ShouldHandleDPad in TargetSelect stops gating
            -- on a phantom menu.  Without this, a closed RT
            -- shortcuts radial / pause menu / etc. could leave
            -- routing stuck on Menus for the rest of the session.
            if Menus.GetActiveHandler and not Menus.GetActiveHandler() then
                routeToWorld = true
                Log.Info("Routing back to WorldUI (Menus has no active handler)")
            end
        end
    end

    -- Tooltip events are processed BEFORE the focusedElement guard
    -- (above) so tooltip-only snapshots aren't dropped.
    Log.Debug("[BG3A_BC] phase=lua_snapshot_end")
end

-- ---------------------------------------------------------------------------
-- Subscribe to the C++ per-frame GlobalFocusMonitor.
-- ---------------------------------------------------------------------------
local function SetupGlobalFocusMonitor()
    local ok, result = pcall(Ext.UI.SubscribeGlobalFocusChanged,
        function(first, prop)
            if type(first) ~= "table" then
                Log.Warn("unexpected callback arg type: " .. type(first))
                return
            end
            if prop == "TickSnapshot" then
                local handlerOk, handlerErr = pcall(
                    HandleTickSnapshot, first)
                if not handlerOk then
                    Log.Error("in HandleTickSnapshot: "
                        .. tostring(handlerErr))
                end
                return
            end
            return
        end)
    if ok and result then
        Log.Info("Global focus monitor active")
    else
        Log.Error("could not subscribe global focus: " .. tostring(result))
    end
end

SetupGlobalFocusMonitor()

-- ---------------------------------------------------------------------------
-- Game state transitions.
-- ---------------------------------------------------------------------------
local LOADING_STATES = {
    LoadMenu = true,
    StartLoading = true, StartServer = true, LoadSession = true,
    LoadLevel = true, SwapLevel = true, UnloadLevel = true,
    UnloadSession = true, InitNetwork = true, InitConnection = true,
    StopLoading = true,
}

-- On console reset (SE hot-reload), GameStateChanged doesn't fire.
-- Check the current game state so suppressSnapshots is correct.
-- Without this, suppressSnapshots stays true forever after a reset.
-- Ext.Client may not exist during initial load, so pcall everything.
local initOk, currentState = pcall(function()
    return Ext.Utils.GetGameState()
end)
if initOk and currentState then
    local stateStr = tostring(currentState)
    currentGameState = stateStr
    suppressSnapshots = LOADING_STATES[stateStr] or false
    if not suppressSnapshots then
        -- Running or Menu state: allow snapshots immediately.
        pcall(Ext.UI.SuppressGlobalFocusTick, false)
        if stateStr == "Running" then
            routeToWorld = true
        end
    end
    Log.Info("Init state: " .. stateStr
        .. " suppress=" .. tostring(suppressSnapshots))
end

-- Forensic toggle: when on, every widgetEvent gets its identity
-- logged in HandleTickSnapshot.  Use to identify which widget(s)
-- accompany a cinematic / dialog / overlay: toggle on, trigger
-- the UI condition in-game, read the log, toggle off.  Off by
-- default to keep normal-play logs clean.
-- One-shot dump of the latest snapshot's widget set.  Uses
-- allWidgetNames + allWidgetDCTypes (loaded-state, the same data
-- Dispatcher checks for handler liveness).  Run during whatever
-- UI condition you're trying to identify -- the lists print
-- in correlated order so name[i] matches dcType[i].
Ext.RegisterConsoleCommand("bg3a_dump_widgets", function()
    if not latestSnapshot then
        Log.Info("WIDGET DUMP: no snapshot received yet")
        return
    end
    local names = latestSnapshot.allWidgetNames or {}
    local dcTypes = latestSnapshot.allWidgetDCTypes or {}
    local addrs = latestSnapshot.allWidgetAddrs or {}
    local count = math.max(#names, #dcTypes, #addrs)
    Log.Info("WIDGET DUMP: " .. count
        .. " widgets (loaded-state, not visibility-filtered):")
    for i = 1, count do
        Log.Info(string.format(
            "  [%d] name='%s' dcType='%s' addr='%s'",
            i,
            tostring(names[i] or ""),
            tostring(dcTypes[i] or ""),
            tostring(addrs[i] or "")))
    end
end)

Ext.RegisterConsoleCommand("bg3a_log_widgets", function(_, arg)
    local newValue
    if arg == "on" or arg == "true" or arg == "1" then
        newValue = true
    elseif arg == "off" or arg == "false" or arg == "0" then
        newValue = false
    else
        newValue = not widgetIdentityLogging
    end
    widgetIdentityLogging = newValue
    Log.Info("Widget identity logging: "
        .. (widgetIdentityLogging and "ON" or "OFF"))
end)

Ext.Events.GameStateChanged:Subscribe(function(e)
    Log.Info("GameStateChanged: " .. tostring(e.FromState)
        .. " -> " .. tostring(e.ToState))

    -- Opening-cinematic handshake.  CharacterCreationStarted fires
    -- server-side during the SwapLevel load phase -- too early for
    -- a server->client relay to land (client net pipe isn't up).
    -- So once the client reaches PrepareRunning (net pipe confirmed
    -- up -- the MovieFinished relay arrives fine at this state) we
    -- ASK the server.  The server replies with the MovieStarted
    -- relay iff CharacterCreationStarted fired this session (new
    -- game).  Save loads never fire it, so they get no reply, no
    -- AD.  See BootstrapServer.lua's BG3Access_QueryOpeningCinematic
    -- listener for the both-orderings handshake logic.
    if tostring(e.ToState) == "PrepareRunning" then
        pcall(Ext.ClientNet.PostMessageToServer,
            "BG3Access_QueryOpeningCinematic", "")
    end

    -- Reset all handler modules.
    Menus.ResetAllHandlers()
    CC.ResetCCState()
    if CC.UnsubscribeCCYButton then CC.UnsubscribeCCYButton() end
    Cutscene.ResetDialogState()
    -- Audio description is fully event-driven now: the server
    -- relays MovieStarted (from the opening-cinematic handshake
    -- above, or other cinematic signals) and MovieFinished,
    -- dispatched via Combat.lua's EVENT_HANDLERS to
    -- Cutscene.HandleMovieStarted / HandleMovieFinished.
    local World = BG3Access.Client.WorldUI
    if World then World.ResetState() end
    local Nav = BG3Access.Client.WorldNav
    if Nav then Nav.ResetState() end
    local Combat = BG3Access.Client.Combat
    if Combat then Combat.ResetState() end
    local TargetSelect = BG3Access.Client.TargetSelect
    if TargetSelect then TargetSelect.ResetState() end

    -- Reset RS input state.
    lastRSDirection = RS_DIRECTION_NONE
    rsAxisX = 0
    rsAxisY = 0

    -- Reset router state.
    lastWidgetRootStr = nil
    spokenLoadingTips = {}
    worldDialogOverlayJustSpoke = false
    menuDialogOverlayJustSpoke  = false
    suppressWorldEntryVisualText = false
    suppressNextWidgetScan = false

    local toState = tostring(e.ToState)
    currentGameState = toState
    suppressSnapshots = LOADING_STATES[toState] or false
    -- Suppress C++ Tick() entirely during loading to prevent deadlocks.
    -- Noesis tree walks can hang when the loading thread is
    -- constructing/destroying UI objects under internal mutexes.
    pcall(Ext.UI.SuppressGlobalFocusTick, suppressSnapshots)
    -- Suppress visual text speech on world entry (Running state).
    -- HUD widgets fire immediately and their visual texts (static button
    -- prompts like "Examine", "Context Menu") are useless noise.
    -- The RS HUD reader replaces this -- user reads info when ready.
    suppressWorldEntryVisualText = (toState == "Running")
    -- Seed routeToWorld from the target state.  Entering Running means
    -- the player is in gameplay and the HUD is the default: the RS
    -- HUD reader, GPS cycle, and other world-mode features must be
    -- active immediately, without waiting for a world-type panel
    -- (Examine, Container, etc.) to appear and flip the flag.  Any
    -- other target state (Menu, LoadSession, etc.) resets to false
    -- so the panel routing logic below can observe fresh transitions.
    routeToWorld = (toState == "Running")
    SetupGlobalFocusMonitor()
end)

-- Dev-only log-level cycler (L3 click) lives in Client/DevConfig.lua,
-- which is excluded from release packaging.  End users never see the
-- binding or the speech feedback it produces.

-- ============================================================================
-- Right-stick accessibility-layer toggle (R3 click)
-- ============================================================================
--
-- A sighted person playing alongside the blind user (or testing /
-- co-op) may want the right stick to behave normally -- rotate the
-- camera as BG3 intends -- rather than being intercepted by the
-- accessibility layer (HUD reader on RS-Up / RS-Right, detail view
-- on RS-Left, settings menu on RS-Down, etc.).  Clicking R3 (right
-- stick) toggles between the two modes.
--
-- When OFF (pass-through):
--   * OnRSAxisInput returns immediately -- no PreventAction, no
--     direction dispatch.  The game receives raw axis events and
--     rotates the camera normally.
--   * Right-stick click (R3 itself) STILL toggles the mode back on
--     -- it's the only way back.
--
-- When ON (default):
--   * Accessibility layer active -- existing behavior.
--
-- Default: ON, because the mod's primary user is blind.  Sighted
-- users explicitly opt-out via R3.
local rsAccessibilityEnabled = true

Ext.Events.ControllerButtonInput:Subscribe(function(event)
    if not event.Pressed then return end
    local buttonName = tostring(event.Button)
    if buttonName ~= "RightStick" then return end

    local SettingsMenu = BG3Access.Client.SettingsMenu
    if SettingsMenu and SettingsMenu.IsOpen
        and SettingsMenu.IsOpen() then
        return
    end

    rsAccessibilityEnabled = not rsAccessibilityEnabled
    local SpeechData = BG3Access.Client.SpeechData
    if SpeechData and SpeechData.Alert then
        if rsAccessibilityEnabled then
            SpeechData.Alert("Accessibility", "interrupt")
        else
            SpeechData.Alert("Camera movement", "interrupt")
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------------

-- DEV-ONLY: mid-session reload recovery.
--
-- The SE console `reset` command wipes the Lua VM mid-game and reloads
-- all scripts.  Users never see the console (dev-only tool), so this
-- block is dead code for them -- gated behind BG3Access.DevMode (set
-- by Client/DevConfig.lua, which is excluded from releases) to make
-- that explicit.
--
-- During normal startup the mod loads in LoadMenu state and
-- GameStateChanged fires to clear suppressSnapshots.  After `reset`,
-- Lua reloads in Running state with no state transition.  If entities
-- with ClientControl exist, we're in gameplay; if CCState entities
-- exist, we're in character creation.  Pre-populate state so the
-- developer can continue testing without re-navigating from the
-- start of whatever they were testing.
if BG3Access.DevMode then
    local resetOk, resetEntities = pcall(
        Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
    if resetOk and resetEntities and next(resetEntities) then
        suppressSnapshots = false
        -- Also set routeToWorld since we're clearly in gameplay.
        -- Without this, IsUIActive returns true in free world because
        -- the default routeToWorld=false is interpreted as "pre-game
        -- menus".
        routeToWorld = true
        Log.Info("Mid-session reload detected, suppression cleared")
        -- If the reload happened while character creation was already
        -- open, tell CC to skip the intro welcome on the next CC
        -- snapshot.  Without this, mid-session reload would re-arm
        -- the LT intro-await listener and drop every subsequent CC
        -- snapshot until the user presses LT again.
        local ccReloadEntities = nil
        local ccReloadOk = pcall(function()
            ccReloadEntities =
                Ext.Entity.GetAllEntitiesWithComponent("CCState")
        end)
        if ccReloadOk and ccReloadEntities and next(ccReloadEntities)
            and CC and CC.MarkMidSessionReload then
            CC.MarkMidSessionReload()
            Log.Info("Mid-session reload detected in CC")
        end
    end
end

-- ---------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------
-- ============================================================================
-- Right-stick input dispatch
-- ============================================================================
--
-- Owns the ControllerAxisInput subscription for the right stick.
-- Dispatches to: DetailView (RS Left in UI), WorldNav GPS (RS Left
-- in free world), WorldNav HUD reader (RS Up / RS Right in free
-- world), Combat turn order (RS Right in combat), SpeechData
-- verbosity cycler (RS Down, global -- fires in any context).

local RS_DIRECTION_NONE  = 0
local RS_DIRECTION_UP    = 1
local RS_DIRECTION_DOWN  = 2
local RS_DIRECTION_RIGHT = 3
local RS_DIRECTION_LEFT  = 4

local RS_DEFLECT_THRESHOLD = 0.4
local RS_RELEASE_THRESHOLD = 0.15
local RS_PREVENT_THRESHOLD = 0.1
local RS_DEAD_ZONE         = 0.5

local lastRSDirection = RS_DIRECTION_NONE
local rsAxisX         = 0
local rsAxisY         = 0

local function GetRSDirection()
    local absX = math.abs(rsAxisX)
    local absY = math.abs(rsAxisY)
    if absX < RS_DEAD_ZONE and absY < RS_DEAD_ZONE then
        return RS_DIRECTION_NONE
    end
    if absY >= absX then
        if rsAxisY < 0 then return RS_DIRECTION_UP end
        return RS_DIRECTION_DOWN
    end
    if rsAxisX > 0 then return RS_DIRECTION_RIGHT end
    return RS_DIRECTION_LEFT
end

--- IsUIActiveForRS: checks whether UI is consuming RS input.
---
--- Previously gated on `routeToWorld`, but that flag is about which
--- handler module (WorldUI vs. Menus) processes snapshots -- NOT
--- about UI ownership of controller input.  In practice the game
--- sometimes closes menus by collapsing the widget (no
--- widgetRemoved event), leaving routeToWorld stuck at false even
--- after the player is back in free world.  That bricked RS Up /
--- Left / Right while RS Down kept working because the verbosity
--- cycle bypasses this gate.
---
--- The authoritative signal is `snapshotHasUIFocus`: the tick
--- monitor reports focused=nil in free world and a real focused
--- element in every menu/panel/dialog.  Pre-game states (Menu,
--- LoadMenu) always have a focused main-menu button, so they
--- naturally gate true without needing a separate check.  CC and
--- the inspect panel have their own flags that outlive
--- snapshotHasUIFocus transitions, so those stay explicit.
---
--- Pre-game state gate: GameState != Running means we're in the
--- main menu / load sequence / transitions where stick input
--- should NEVER trigger GPS / HUD reader / combat turn-order.
--- We track `currentGameState` via GameStateChanged.
--- Sanity check: snapshotHasUIFocus alone is unreliable because
--- Noesis doesn't cleanly reset focus when overlays close.  After
--- Container / Examine / context-menu closes, the engine's
--- focusedElement can still point at a stale HUD element, so the
--- flag stays true forever and RS gets gated indefinitely.
---
--- Cross-verify: only trust snapshotHasUIFocus when a REAL
--- handler is also active.  PartyLine doesn't count (sticky HUD
--- handler activated by snapshot lone-discovery).  CC / inspect
--- have their own explicit flags handled above.
local function HasRealUIHandlerActive()
    if Menus and Menus.GetActiveHandler
        and Menus.GetActiveHandler() then
        return true
    end
    local World = BG3Access.Client.WorldUI
    if World and World.GetActivePanelHandler then
        local panel = World.GetActivePanelHandler()
        if panel and panel.name and panel.name ~= "PartyLine" then
            return true
        end
    end
    return false
end

local function IsUIActiveForRS()
    if currentGameState ~= "Running" then return true end
    if CC.IsInCC and CC.IsInCC() then return true end
    if inspectWidgetActive then return true end
    -- Handlers are the sole truth source for "is UI active".  If a
    -- panel/menu handler is set, we're in UI; if not, the user is in
    -- the world.
    --
    -- Previous design ORed in snapshotHasUIFocus as a "sanity check"
    -- backup, but Noesis leaves stale focus state behind constantly
    -- (after fast travel, after context menu close, after character
    -- sheet close, after Tutorial dismiss, etc.) -- the engine's
    -- focused-element pointer continues pointing at a hidden HUD
    -- element with non-empty elemType, so snapshotHasUIFocus stays
    -- stuck `true` and gated RS off in the free world indefinitely.
    -- The "sanity check" caused more bugs than it prevented.
    --
    -- The remaining concern (an untracked UI not gating because no
    -- handler was registered for it) is bounded: every UI we
    -- currently see has a handler, and a missing handler shows up as
    -- "weird RS behavior in this menu" not "RS dead in world", which
    -- is recoverable and obvious in testing.  Per-handler stuck-
    -- active issues (Map after fast travel) are tracked separately
    -- and need fixes at their source, not by gating RS at a global
    -- level.
    return HasRealUIHandlerActive()
end

--- Diagnostic: explains WHY IsUIActiveForRS returned true on a given
--- call.  Called from RS-direction dispatch when a user's stick input
--- was gated away.  Emitted at Debug level so it doesn't spam normal
--- logs but is available when the user is trying to diagnose "my
--- stick doesn't do anything" reports.
local function DescribeRSGateReason()
    if currentGameState ~= "Running" then
        return "gameState=" .. tostring(currentGameState)
    end
    if CC.IsInCC and CC.IsInCC() then return "CC active" end
    if inspectWidgetActive then return "inspect panel active" end
    if HasRealUIHandlerActive() then
        local Menus = BG3Access.Client.Menus
        local World = BG3Access.Client.WorldUI
        local menuHandler = Menus and Menus.GetActiveHandler
            and Menus.GetActiveHandler()
        local panelHandler = World and World.GetActivePanelHandler
            and World.GetActivePanelHandler()
        local active = (menuHandler and menuHandler.name)
            or (panelHandler and panelHandler.name)
            or "unknown handler"
        return "handler active: " .. active
    end
    return "unknown"
end

--- Find the active handler with BuildDetailList support.
--- Priority: CC > TargetSelect (combat effects view) > WorldUI > Menus.
---
--- TargetSelect takes priority over WorldUI/Menus when the user has
--- a currently-cycled combat target, so RS-Left during target
--- select opens the effects view (statuses on the targeted
--- character) rather than, e.g., the hotbar's detail view.
---
--- WorldUI/Menus paths are gated on IsUIActiveForRS: panel handlers
--- like PartyLineHandler stay set as activePanelHandler permanently
--- (PartyLine_c is the always-visible HUD portrait row, never
--- removed), so without the gate, free-world RS-Left would route
--- to PartyLine's detail view and silently swallow the GPS toggle.
--- CC and TargetSelect already imply UI/target focus, so they
--- don't need the gate.
local function FindActiveDetailHandler()
    if CC.IsInCC and CC.IsInCC() then
        local ccHandler = CC.GetActiveHandler
            and CC.GetActiveHandler()
        if ccHandler and ccHandler.BuildDetailList then
            return ccHandler
        end
    end
    local TargetSelect = BG3Access.Client.TargetSelect
    if TargetSelect and TargetSelect.GetActiveDetailHandler then
        local effectsHandler = TargetSelect.GetActiveDetailHandler()
        if effectsHandler and effectsHandler.BuildDetailList then
            return effectsHandler
        end
    end
    -- Radial: when open, the radial owns RS Left detail view because
    -- Inspect (RS press) is unreliable for bottom-half radial slots
    -- (4-8 o'clock).  The user holds LS down to keep those slots
    -- focused, but Inspect's vertical card-stack navigation reads
    -- the held LS direction and steps through the cards before they
    -- finish reading.  Detail view's d-pad navigation is independent
    -- of LS direction, so it works for every slot regardless of
    -- which direction the user is holding.  Checked BEFORE the panel
    -- handler branch so a stale activePanelHandler from a recently
    -- closed panel doesn't shadow the radial when the user opens it
    -- via the shortcuts menu.
    local World = BG3Access.Client.WorldUI
    if World and World.GetRadialDetailHandler then
        local radialHandler = World.GetRadialDetailHandler()
        if radialHandler and radialHandler.BuildDetailList then
            return radialHandler
        end
    end
    if IsUIActiveForRS() then
        if World and World.GetActivePanelHandler then
            local panelHandler = World.GetActivePanelHandler()
            -- PartyLine excluded: PartyLine_c (always-visible HUD
            -- portrait row) gets activated as activePanelHandler via
            -- the snapshot lone-discovery branch when no other panel
            -- is open, which would route RS-Left into a detail-view
            -- toggle that has no useful content (HUD doesn't have a
            -- "currently focused" character) and silently swallows
            -- the GPS toggle the user actually pressed RS-Left for.
            -- The LT-opened expanded party panel (PartyLineActive_c)
            -- shares the same handler instance, but the user is
            -- already navigating that panel directly and doesn't
            -- need a separate detail view layered on top.
            if panelHandler and panelHandler.name ~= "PartyLine"
                and panelHandler.BuildDetailList then
                return panelHandler
            end
        end
        if Menus and Menus.GetActiveHandler then
            local menuHandler = Menus.GetActiveHandler()
            if menuHandler and menuHandler.BuildDetailList then
                return menuHandler
            end
        end
    end
    return nil
end

local function HandleRSDirection(direction)
    -- Top-level gate: while the BG3Access settings menu is open, the
    -- ONLY RS direction we honor is Down (close + save, handled
    -- below).  Everything else (Left/Right/Up -- detail view,
    -- compare view, GPS cycle, HUD reader) stays off so the menu's
    -- speech doesn't compete with other mod chatter while the user
    -- is configuring.
    local SettingsMenu = BG3Access.Client.SettingsMenu
    if SettingsMenu and SettingsMenu.IsOpen and SettingsMenu.IsOpen()
        and direction ~= RS_DIRECTION_DOWN then
        return
    end

    -- No top-level WorldNav dependency.  RS handling fans out to
    -- branches that have nothing to do with navigation: detail view,
    -- compare view, verbosity cycle, HUD reader.  Only the
    -- GPS-toggle FALLBACK in the RS-Left branch actually needs
    -- WorldNav -- it's looked up inline there, not gated globally.
    -- The previous top-level Nav gate broke RS in any context where
    -- WorldNav happened to be unloaded or where its HasPlayerEntity
    -- probe missed the controllable character (character sheet was
    -- one such case).  Branches that need a module check it
    -- themselves.

    -- RS Left: detail view toggle or GPS cycle.
    if direction == RS_DIRECTION_LEFT then
        Log.Info("RS LEFT: fired, looking for detail handler")
        local DetailView = BG3Access.Client.DetailView
        if DetailView then
            local handler = FindActiveDetailHandler()
            Log.Info("RS LEFT: FindActiveDetailHandler -> "
                .. (handler and ("handler='"
                    .. tostring(handler.name or "?") .. "'") or "nil"))
            if handler then
                -- The detail-view builders rely on the tooltip as
                -- source of truth for item facts; fetch the cached
                -- tooltip texts from whichever module owns the
                -- active handler.  Without this, builders see nil
                -- tooltipTexts and produce nearly-empty lists.
                local tooltipTexts = nil
                local World = BG3Access.Client.WorldUI
                if World and World.GetLastTooltipTexts then
                    tooltipTexts = World.GetLastTooltipTexts()
                end
                if not tooltipTexts and Menus
                    and Menus.GetLastTooltipTexts then
                    tooltipTexts = Menus.GetLastTooltipTexts()
                end
                local handled = DetailView.Toggle(handler, tooltipTexts)
                if handled then return end
            end
        end
        if IsUIActiveForRS() then
            Log.Info("RS Left gated: " .. DescribeRSGateReason())
            return
        end
        -- In combat, RS-Left is exclusively for the effects view.
        -- If we got here, no effects handler was available (no
        -- target cycled, target stale, etc.) -- stay silent rather
        -- than falling through to GPS, which would announce "GPS
        -- not available in combat" and be misleading: the user
        -- pressed RS-Left for effects, not GPS, so "hit d-pad to
        -- select a target first" is closer to the truth.
        local Combat = BG3Access.Client.Combat
        if Combat and Combat.IsInCombat and Combat.IsInCombat() then
            local hintSpeech = SpeechData.Create()
            hintSpeech:Add("instructionHint",
                "Select a target first with d-pad", "brief")
            local formatted = hintSpeech:Format()
            if formatted and formatted ~= "" then
                Ext.Tolk.Speak(formatted, true)
            end
            return
        end
        -- GPS toggle: needs WorldNav.  Look it up here, not at the
        -- top of HandleRSDirection -- this branch is the only one
        -- that actually requires the navigation module.
        --
        -- NOTE: do NOT guard on Nav.IsEntityListOpen here.  The cycle
        -- is Off -> Exploration -> Routing -> Off, and Routing has the
        -- list open by definition.  A list-open guard turns RS-Left
        -- into a one-way door once the user reaches Routing -- the
        -- only escape becomes pressing B (closes list, reverts to
        -- Exploration), defeating the "RS-Left to turn GPS off" muscle
        -- memory that holds in every other state.  ClearGPSState (run
        -- by EnterOffMode) sets entityListOpen=false, so the
        -- Routing -> Off transition closes the list as part of the
        -- mode change -- no separate close needed.
        local Nav = BG3Access.Client.WorldNav
        if not Nav then
            -- WorldNav module is missing.  Most common cause is a
            -- parse error at module load (e.g. the Lua 200-locals
            -- limit being exceeded).  Surface the diagnostic so
            -- "RS-Left does nothing" doesn't go unnoticed.
            Log.Warn("RS LEFT: WorldNav module is nil"
                .. " -- check earlier log for parse errors")
            return
        end
        if Nav.CycleGPSMode then Nav.CycleGPSMode() end
        return
    end

    -- RS Down: open/close the BG3Access settings menu.  Fires in ANY
    -- context, not gated on IsUIActiveForRS -- the menu lives above
    -- the game's own UI, intercepts D-pad/B while open, and returns
    -- the user to wherever they were on close.  Inside the menu,
    -- D-pad cycles settings (Up/Down for selection, Left/Right for
    -- values) and B (or RS Down again) closes + saves.
    if direction == RS_DIRECTION_DOWN then
        local SettingsMenu = BG3Access.Client.SettingsMenu
        if SettingsMenu and SettingsMenu.Toggle then
            SettingsMenu.Toggle()
        elseif BG3Access.Client.CycleVerbosity then
            -- Fallback: if SettingsMenu hasn't loaded for some
            -- reason, preserve the historical verbosity-cycle
            -- behavior so RS Down doesn't go silent.
            BG3Access.Client.CycleVerbosity()
        end
        return
    end

    -- RS Right: compare view (UI only).  When inside a menu with an
    -- active panel handler whose last tooltip included a compare card,
    -- RS Right toggles the CompareView grid.  Always-on close (user
    -- can close it even if we somehow think UI isn't active).  Open
    -- is gated on IsUIActiveForRS so world RS-Right stays HUD-only
    -- and doesn't fire on stale handler state left over from a recent
    -- menu visit.
    if direction == RS_DIRECTION_RIGHT then
        local CompareView = BG3Access.Client.CompareView
        if CompareView and CompareView.IsOpen() then
            CompareView.Close()
            return
        end
        if IsUIActiveForRS() then
            local World = BG3Access.Client.WorldUI
            if World and World.GetActivePanelHandler then
                local panelHandler = World.GetActivePanelHandler()
                if panelHandler and panelHandler.GetCompareData then
                    local focusedSpeech, compareSpeech =
                        panelHandler.GetCompareData()
                    if focusedSpeech and compareSpeech and CompareView then
                        if CompareView.Open(
                                focusedSpeech, compareSpeech) then
                            return
                        end
                    end
                end
            end
            -- UI active but no compare: do not fall through to HUD.
            -- The game owns RS-Right in menus.
            return
        end
    end

    -- RS Up/Right (non-compare): HUD reader (free world only).
    if IsUIActiveForRS() then
        Log.Info("RS " .. tostring(direction)
            .. " gated: " .. DescribeRSGateReason())
        return
    end

    local HUDReader = BG3Access.Client.HUDReader
    if direction == RS_DIRECTION_UP then
        if HUDReader then HUDReader.SpeakCharacterInfo() end
    elseif direction == RS_DIRECTION_RIGHT then
        local Combat = BG3Access.Client.Combat
        if Combat and Combat.IsInCombat and Combat.IsInCombat() then
            Combat.SpeakTurnOrder()
        elseif HUDReader then
            HUDReader.SpeakActionResources()
        end
    end
end

local function OnRSAxisInput(event)
    -- Pass-through mode: a sighted user toggled the accessibility
    -- layer off via R3.  Return without PreventAction so the game
    -- gets raw axis values for camera rotation, AND without dispatching
    -- to GPS / HUD reader / detail view / settings menu so those
    -- accessibility features stay dormant until R3 toggles back.
    if not rsAccessibilityEnabled then return end

    local axisName = tostring(event.Axis)
    local value = event.Value or 0

    if axisName == "RightX" then
        rsAxisX = value
    elseif axisName == "RightY" then
        rsAxisY = value
    else
        return
    end

    local absX = math.abs(rsAxisX)
    local absY = math.abs(rsAxisY)
    local maxDeflection = absX > absY and absX or absY

    if maxDeflection >= RS_PREVENT_THRESHOLD then
        pcall(event.PreventAction, event)
    end

    if lastRSDirection ~= RS_DIRECTION_NONE then
        if maxDeflection < RS_RELEASE_THRESHOLD then
            lastRSDirection = RS_DIRECTION_NONE
        end
        return
    end

    if maxDeflection < RS_DEFLECT_THRESHOLD then
        return
    end

    local direction = GetRSDirection()
    if direction == RS_DIRECTION_NONE then return end
    lastRSDirection = direction
    HandleRSDirection(direction)
end

Ext.Events.ControllerAxisInput:Subscribe(function(event)
    local axisOk, axisErr = pcall(OnRSAxisInput, event)
    if not axisOk then
        Log.Error("EventRouter RS axis: " .. tostring(axisErr))
    end
end)

-- ============================================================================
-- Exports
-- ============================================================================

BG3Access.Client.EventRouter = {
    --- IsUIActive: returns true when any UI is active (pre-game menu,
    --- WorldUI panel, dialog, inspect, etc.) and false only during
    --- free-world navigation.
    ---
    --- Uses the tick monitor's authoritative focus state (cached in
    --- snapshotHasUIFocus on every snapshot).  In free world the
    --- monitor reports focused=nil; in any menu/panel a focused
    --- element exists.  This avoids Ext.UI.GetFocusedElement() which
    --- returns non-nil even in free world because BG3's HUD has
    --- "selected" elements (party member, hotbar slot) that the
    --- focus strategies pick up.
    IsUIActive = function()
        -- Pre-game menus: no gameplay running, always UI active.
        if not routeToWorld then return true end
        -- Character creation: always UI active regardless of
        -- snapshotHasUIFocus.  CC snapshots flip between "focused"
        -- (d-pad nav) and "no focus" (inline carousel events) within
        -- the same CC session.  Without this check WorldNav GPS
        -- would fire on every carousel tick and consume input.
        if CC.IsInCC and CC.IsInCC() then return true end
        -- Inspect panel (PinnedTooltips_c) consumes RS input.
        if inspectWidgetActive then return true end
        -- Gameplay: check the cached focus state from the tick monitor.
        return snapshotHasUIFocus
    end,

    GetActiveDetailHandler = FindActiveDetailHandler,

    --- FlushPendingLoadingTips: speak any loading tips that were
    --- queued during the welcome flow.  Called by Welcome.FinishWelcome
    --- after the user A-presses past the final page.  Empties the
    --- pending queue.  Safe to call when the queue is empty.
    FlushPendingLoadingTips = function()
        if #pendingTipsDuringWelcome == 0 then return end
        Log.Info("Flushing " .. #pendingTipsDuringWelcome
            .. " loading tips queued during welcome")
        for _, textValue in ipairs(pendingTipsDuringWelcome) do
            SpeechData.Alert(textValue, "queue")
        end
        pendingTipsDuringWelcome = {}
    end,
}

Log.Info("Accessibility ready (GlobalFocusMonitor).")
