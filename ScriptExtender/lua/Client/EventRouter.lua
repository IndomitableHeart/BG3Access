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
local Log   = BG3Access.Client.Log
local Helpers = BG3Access.Client.Helpers
local CC    = BG3Access.Client.CC
local Cutscene = BG3Access.Client.Cutscene
local Menus = BG3Access.Client.Menus

-- ---------------------------------------------------------------------------
-- Cross-cutting state (not owned by any single handler).
-- ---------------------------------------------------------------------------
-- Start suppressed: the mod loads during a loading state (LoadMenu)
-- and no GameStateChanged fires for the initial state.
local suppressSnapshots   = true
local lastWidgetRootStr   = nil
local inspectWidgetActive = false  -- true while PinnedTooltips_c has focus
local debugExploreMode    = false
-- Explore mode uses its own lastSpokenFullText to avoid needing a handler state.
local exploreLastSpoken   = nil
-- Loading tips use their own dedup to avoid needing a handler state.
-- Table used as a set because multiple tips can arrive in the same snapshot.
local spokenLoadingTips = {}
-- True when snapshots should route to WorldUI panel handlers instead of Menus.
local routeToWorld        = false
-- True when a dialog overlay spoke on this tick while WorldUI is active.
-- Suppresses the panel handler so dialog speech isn't interrupted.
local worldDialogOverlayJustSpoke = false
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

-- ---------------------------------------------------------------------------
-- HandleTickSnapshot: thin router.
--
-- Iterates snapshot.widgetEvents (one entry per new/changed widget this
-- tick) and dispatches each event to the handler that cares about it.
-- Each handler receives its own event data -- no shared "best" event is
-- computed here.  Routing state (routeToWorld) is updated based on which
-- handler kinds activated; menu wins over world if both appeared.
-- ---------------------------------------------------------------------------
local function HandleTickSnapshot(snapshot)
    local widgetEvents = snapshot.widgetEvents or {}
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
        for _, widgetEvent in ipairs(widgetEvents) do
            if widgetEvent.dcType == "ls.LoadingScreen"
                and widgetEvent.namedTexts then
                for textKey, textValue in pairs(widgetEvent.namedTexts) do
                    if textKey:find("^_loadingHint_") then
                        if textValue and textValue ~= ""
                            and not textValue:match("^%d+%%?$")
                            and not spokenLoadingTips[textValue] then
                            spokenLoadingTips[textValue] = true
                            local tipSpeech = Helpers.CreateSpeechData()
                            tipSpeech:Add("loadingTip", textValue, "normal")
                            Log.Info("LOADING TIP: " .. textValue)
                            Ext.Tolk.Speak(tipSpeech:Format(), false)
                        end
                    end
                end
            end
        end
    end

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
            local contextSpeech = Helpers.CreateSpeechData()
            contextSpeech:Add("contextItem", itemText, "brief")
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
        -- Clear widgetAdded so downstream discovery (RoutePanelSnapshot)
        -- also ignores this scan.
        if suppressNextWidgetScan then
            suppressNextWidgetScan = false
            snapshot.widgetAdded = false
            Log.Debug("WIDGET EVENT suppressed (menu close re-scan)")
        else
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

            -- When WorldUI is active and a dialog overlay spoke,
            -- suppress the panel handler on this tick so the dialog
            -- speech isn't immediately interrupted.
            if dialogOverlaySpoke and routeToWorld then
                worldDialogOverlayJustSpoke = true
            end
        end  -- suppressNextWidgetScan else
    end

    -- =================================================================
    -- Tooltip events: process BEFORE focusedElement guard.
    -- Tooltip-only snapshots (no focus/selection change) have no
    -- focusedElement and would be dropped by the guard below.
    --
    -- Hub-and-spoke: the hub passes raw structured tooltip data
    -- (array of {role, text} tables) to the active handler.
    -- Each handler builds its own SpeechData from the roles it
    -- cares about via customTooltipFn.  Three-way dispatch:
    -- CC, WorldUI, or Menus.
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

            -- Dispatch to active context (handler decides speech).
            local isCC = CC.IsInCC and CC.IsInCC()
            if isCC then
                if CC.DispatchTooltip then
                    CC.DispatchTooltip(structuredTooltipData, snapshot)
                end
            elseif routeToWorld then
                local World = BG3Access.Client.WorldUI
                if World and World.DispatchTooltip then
                    World.DispatchTooltip(structuredTooltipData, snapshot)
                end
            else
                if Menus.DispatchTooltip then
                    Menus.DispatchTooltip(structuredTooltipData, snapshot)
                end
            end
        end
    end

    -- Update UI focus flag: true whenever the snapshot carries a
    -- focused element.  This is how IsUIActive knows whether the
    -- player is in the world (no focus) or in some UI (focused).
    -- When focus is lost (transition from true to false), silence
    -- any in-progress speech -- the user just closed a menu/panel.
    local hadUIFocus = snapshotHasUIFocus
    snapshotHasUIFocus = (focusedElement ~= nil
        and focusedElement.elemType ~= nil
        and focusedElement.elemType ~= "")
    if hadUIFocus and not snapshotHasUIFocus then
        -- Only silence when no handler is active.  Focus can
        -- temporarily drop between ticks during menu transitions
        -- (widget scan ticks have no focusedElement).  If a handler
        -- is still active, the menu/panel is still open.
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
        local activeWidgetName = Menus.GetActiveHandlerWidgetName
            and Menus.GetActiveHandlerWidgetName() or nil

        -- Check if the removed widget matches the active handler.
        -- Match by widget name first (distinguishes shortcuts menu
        -- from pause menu when both share gui::DCGameMenu), then
        -- by DC type as fallback.
        local handlerMatched = false
        if activeWidgetName and removedName ~= ""
            and removedName == activeWidgetName then
            handlerMatched = true
        elseif activeHandler and removedDCType ~= ""
            and Menus.IsMenuDCType(removedDCType) then
            -- DC type match: only if the handler was NOT activated by
            -- widget name (otherwise we'd false-match on shared types).
            if not activeWidgetName then
                handlerMatched = true
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
    -- Widget-added events (above) are processed regardless.
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
                local greetingSpeech = Helpers.CreateSpeechData()
                if hudInfo.characterName and hudInfo.characterName ~= "" then
                    greetingSpeech:Add("characterName",
                        hudInfo.characterName, "brief")
                end
                if hudInfo.characterInfo and hudInfo.characterInfo ~= "" then
                    greetingSpeech:Add("characterInfo",
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
    -- Debug explore mode: speak raw element info, skip all processing.
    -- =================================================================
    if debugExploreMode
        and (snapshot.focusChanged or snapshot.selectionChanged) then
        local data = focusedElement
        local parts = {}
        if data.isTab then
            table.insert(parts, "Tab")
            if data.tabName then table.insert(parts, data.tabName) end
        else
            if data.elemType then table.insert(parts, data.elemType) end
            if data.elemName then table.insert(parts, data.elemName) end
        end
        if data.dcType then table.insert(parts, "DC:" .. data.dcType) end
        if data.isFocusable then table.insert(parts, "focusable") end
        local text = Helpers.ExtractTextFromData(data, nil, false)
        if text then table.insert(parts, "text:" .. text) end
        Log.Info("EXPLORE sel=" .. tostring(snapshot.selectionChanged)
            .. " foc=" .. tostring(snapshot.focusChanged)
            .. " isTab=" .. tostring(data.isTab)
            .. " postSettle=" .. tostring(snapshot.postSettle)
            .. " elemId=" .. tostring(data.elemId))
        if data.dcProps then
            local propParts = {}
            for propName, propValue in pairs(data.dcProps) do
                table.insert(propParts, propName .. "="
                    .. tostring(propValue))
            end
            if #propParts > 0 then
                table.sort(propParts)
                Log.Info("EXPLORE dcProps: "
                    .. table.concat(propParts, " | "))
            end
        end
        local speech = Helpers.StripMarkupTags(table.concat(parts, " | "))
        if speech ~= "" and speech ~= exploreLastSpoken then
            exploreLastSpoken = speech
            local exploreSpeech = Helpers.CreateSpeechData()
            exploreSpeech:Add("exploreInfo", speech, "brief")
            Log.Info("EXPLORE: " .. speech)
            Ext.Tolk.Speak(exploreSpeech:Format(), true)
        end
        return
    end

    -- =================================================================
    -- Widget root tracking: detect UI teardown/rebuild.
    -- =================================================================
    local widgetRootId = focusedElement.widgetRootId or ""
    if widgetRootId ~= "" and widgetRootId ~= lastWidgetRootStr then
        lastWidgetRootStr = widgetRootId
        inspectWidgetActive = false  -- widget root changed, inspect closed
        Log.Info("Widget root changed to " .. widgetRootId)
        if routeToWorld then
            local World = BG3Access.Client.WorldUI
            if World then World.HandlePanelWidgetRootChanged() end
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
            Menus.RouteSnapshot(snapshot)
        end
    end

    -- Tooltip events are processed BEFORE the focusedElement guard
    -- (above) so tooltip-only snapshots aren't dropped.
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

Ext.Events.GameStateChanged:Subscribe(function(e)
    Log.Info("GameStateChanged: " .. tostring(e.FromState)
        .. " -> " .. tostring(e.ToState))

    -- Reset all handler modules.
    Menus.ResetAllHandlers()
    CC.ResetCCState()
    if CC.UnsubscribeCCYButton then CC.UnsubscribeCCYButton() end
    Cutscene.ResetDialogState()
    Cutscene.HandleGameStateForAD(tostring(e.FromState), tostring(e.ToState))
    local World = BG3Access.Client.WorldUI
    if World then World.ResetState() end
    local Nav = BG3Access.Client.WorldNav
    if Nav then Nav.ResetState() end
    local Combat = BG3Access.Client.Combat
    if Combat then Combat.ResetState() end

    -- Reset RS input state.
    lastRSDirection = RS_DIRECTION_NONE
    rsAxisX = 0
    rsAxisY = 0

    -- Reset router state.
    lastWidgetRootStr = nil
    exploreLastSpoken = nil
    spokenLoadingTips = {}
    worldDialogOverlayJustSpoke = false
    suppressWorldEntryVisualText = false
    suppressNextWidgetScan = false

    local toState = tostring(e.ToState)
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

-- ---------------------------------------------------------------------------
-- Debug explore mode toggle (L3 + R3).
-- ---------------------------------------------------------------------------
function BG3Access.Client.ToggleExploreMode()
    debugExploreMode = not debugExploreMode
    local modeState = debugExploreMode and "ON" or "OFF"
    Log.Info("Explore mode: " .. modeState)
    local modeSpeech = Helpers.CreateSpeechData()
    modeSpeech:Add("exploreToggle", "Explore mode " .. modeState, "brief")
    Ext.Tolk.Speak(modeSpeech:Format(), true)
end

local exploreComboState = { leftStickHeld = false, rightStickHeld = false }

Ext.Events.ControllerButtonInput:Subscribe(function(event)
    local buttonName = tostring(event.Button)
    if debugExploreMode and event.Pressed then
        Log.Debug("INPUT: " .. buttonName)
    end
    if buttonName == "LeftStick" then
        exploreComboState.leftStickHeld = event.Pressed
        if event.Pressed and exploreComboState.rightStickHeld then
            BG3Access.Client.ToggleExploreMode()
        end
    elseif buttonName == "RightStick" then
        exploreComboState.rightStickHeld = event.Pressed
        if event.Pressed and exploreComboState.leftStickHeld then
            BG3Access.Client.ToggleExploreMode()
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
-- in free world), WorldNav HUD reader (RS Up/Down/Right in free world),
-- Combat turn order (RS Right in combat).

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

--- Find the active handler with BuildDetailList support.
--- Priority: CC > WorldUI > Menus.
local function FindActiveDetailHandler()
    if CC.IsInCC and CC.IsInCC() then
        local ccHandler = CC.GetActiveHandler
            and CC.GetActiveHandler()
        if ccHandler and ccHandler.BuildDetailList then
            return ccHandler
        end
    end
    local World = BG3Access.Client.WorldUI
    if World and World.GetActivePanelHandler then
        local panelHandler = World.GetActivePanelHandler()
        if panelHandler and panelHandler.BuildDetailList then
            return panelHandler
        end
    end
    if Menus and Menus.GetActiveHandler then
        local menuHandler = Menus.GetActiveHandler()
        if menuHandler and menuHandler.BuildDetailList then
            return menuHandler
        end
    end
    return nil
end

--- IsUIActiveForRS: checks whether UI is consuming RS input.
local function IsUIActiveForRS()
    if not routeToWorld then return true end
    if CC.IsInCC and CC.IsInCC() then return true end
    if inspectWidgetActive then return true end
    return snapshotHasUIFocus
end

local function HandleRSDirection(direction)
    local Nav = BG3Access.Client.WorldNav
    if not Nav or not Nav.HasPlayerEntity() then return end

    -- RS Left: detail view toggle or GPS cycle.
    if direction == RS_DIRECTION_LEFT then
        local DetailView = BG3Access.Client.DetailView
        if DetailView then
            local handler = FindActiveDetailHandler()
            if handler then
                local handled = DetailView.Toggle(handler)
                if handled then return end
            end
        end
        if IsUIActiveForRS() then return end
        if Nav.IsEntityListOpen() then return end
        Nav.CycleGPSMode()
        return
    end

    -- RS Up/Down/Right: HUD reader (free world only).
    if IsUIActiveForRS() then return end

    if direction == RS_DIRECTION_UP then
        Nav.SpeakCharacterInfo()
    elseif direction == RS_DIRECTION_DOWN then
        Nav.SpeakTargetInfo()
    elseif direction == RS_DIRECTION_RIGHT then
        local Combat = BG3Access.Client.Combat
        if Combat and Combat.IsInCombat and Combat.IsInCombat() then
            Combat.SpeakTurnOrder()
        else
            Nav.SpeakActionResources()
        end
    end
end

local function OnRSAxisInput(event)
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
}

Log.Info("Accessibility ready (GlobalFocusMonitor).")
