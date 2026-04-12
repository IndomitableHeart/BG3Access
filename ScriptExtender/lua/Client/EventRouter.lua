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
-- True when routeToWorld was flipped from true->false for a menu that
-- opened during gameplay (e.g. shortcuts radial).  When the menu's
-- widget disappears from the scan, routeToWorld is restored to true
-- so HUD noise doesn't bleed through Menus routing.
local worldRouteBeforeMenu = false
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

-- ---------------------------------------------------------------------------
-- HandleTickSnapshot: thin router.
-- Dispatches to the correct handler module based on snapshot content.
-- ---------------------------------------------------------------------------
local function HandleTickSnapshot(snapshot)
    -- =================================================================
    -- Dialog/cutscene widget events: handle BEFORE focus check since
    -- cutscenes have no focused element.
    -- =================================================================
    if snapshot.widgetAdded and snapshot.widgetData
        and snapshot.widgetData.dcType
        and Cutscene.IsDialogOrCutscene(snapshot.widgetData.dcType) then
        Cutscene.HandleDialogWidgetEvent(snapshot.widgetData)
        -- If no focused element data, nothing else to do (pure cutscene).
        if not snapshot.focusedElement
            or not snapshot.focusedElement.elemType then
            return
        end
    end

    -- =================================================================
    -- Loading tips: read _loadingHint_ keys from widgetData.namedTexts.
    -- C++ CollectLoadingHints finds the LoadingHints ItemsControl by name,
    -- walks its TextBlock children, reads Inlines text, and stores as
    -- _loadingHint_1, _loadingHint_2, etc.  Runs FIRST before any routing
    -- logic that might return early (loading screen has no focused element).
    -- =================================================================
    if snapshot.widgetAdded and snapshot.widgetData
        and snapshot.widgetData.dcType == "ls.LoadingScreen"
        and snapshot.widgetData.namedTexts then
        for textKey, textValue in pairs(snapshot.widgetData.namedTexts) do
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

    -- =================================================================
    -- CC dispatch (early): CC snapshots may lack elemType during rapid
    -- focus bounces (e.g. guardian page entry).  Route to CC handler
    -- before the elemType filter so they aren't dropped.
    -- =================================================================
    if focusedElement and not suppressSnapshots
        and CC.IsCCSnapshot(snapshot) then
        CC.HandleCCSnapshot(snapshot)
        return
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
    -- Widget added events: process BEFORE focusedElement guard.
    -- Widget events describe the NEW widget (dcType, dcProps), not the
    -- focused element.  They must register the panel handler and set
    -- routeToWorld even when focusedElement is nil (UI rebuilding).
    -- Skip during loading suppression -- no handler routing needed.
    -- =================================================================
    if not suppressSnapshots
        and snapshot.widgetAdded and snapshot.widgetData
        and snapshot.widgetData.dcType then
        local newDCType = snapshot.widgetData.dcType
        Log.Debug("WIDGET EVENT: dcType=" .. newDCType)
        -- Reset dialog state when a non-dialog widget appears.
        if not Cutscene.IsDialogOrCutscene(newDCType) then
            Cutscene.ResetDialogState()
        end
        -- Difficulty selection signals a genuine new game flow (not
        -- Continue or Load).  The AD system uses this to decide whether
        -- to play the opening audio description.
        if newDCType == "gui::DCNewGameSettings" then
            Cutscene.NotifyNewGameInitiated()
        end
        -- Dialog overlays (MessageBox) are handled separately with full
        -- snapshot context to distinguish real modals from pre-loaded widgets.
        if Menus.IsDialogOverlay(newDCType) then
            local dialogSpoke = Menus.HandleDialogOverlay(
                snapshot, snapshot.widgetData)
            -- When WorldUI is active, suppress panel routing on this tick
            -- so the dialog speech isn't immediately interrupted.
            if dialogSpoke and routeToWorld then
                worldDialogOverlayJustSpoke = true
            end
        else
            -- CC always gets widget events (detects its own re-appearance).
            CC.HandleWidgetAdded(snapshot.widgetData)

            -- Route to WorldUI or Menus based on DC type.
            local World = BG3Access.Client.WorldUI
            if World and World.IsWorldDCType(newDCType) then
                World.HandlePanelWidgetAdded(snapshot.widgetData)
                -- Switch routing to WorldUI if not already there.
                if not routeToWorld then
                    Menus.ResetAllHandlers()
                    routeToWorld = true
                    Log.Info("Routing to WorldUI panels")
                end
            elseif Menus.IsMenuDCType(newDCType) then
                -- Only switch back to Menus for explicitly handled menu
                -- DC types.  Generic types (ls.Widget, ls.DCPartyLine,
                -- etc.) fire alongside panel widgets during initial scans
                -- and must NOT reset WorldUI routing.
                Menus.HandleWidgetAdded(snapshot.widgetData)
                if routeToWorld then
                    if World then World.ResetAllPanelHandlers() end
                    worldRouteBeforeMenu = true
                    routeToWorld = false
                    Log.Info("Routing to Menus (from world)")
                end
            else
                -- Generic/unknown DC type: let both sides see the event
                -- but don't change routing.
                if routeToWorld then
                    if World then
                        World.HandlePanelWidgetAdded(snapshot.widgetData)
                    end
                else
                    Menus.HandleWidgetAdded(snapshot.widgetData)
                end
            end
        end
    end

    -- =================================================================
    -- Tooltip events: process BEFORE focusedElement guard.
    -- Tooltip-only snapshots (no focus/selection change) have no
    -- focusedElement and would be dropped by the guard below.
    -- =================================================================
    if not suppressSnapshots then
        -- Process tooltip on tooltip changes, AND on focus/selection
        -- changes (to reset dedup state so re-visiting an element
        -- speaks its tooltip again).
        if snapshot.tooltipChanged
            or snapshot.focusChanged
            or snapshot.selectionChanged then
            local World = BG3Access.Client.WorldUI
            if World then
                World.ProcessTooltip(snapshot)
            end
        end
    end

    -- Update UI focus flag: true whenever the snapshot carries a
    -- focused element.  This is how IsUIActive knows whether the
    -- player is in the world (no focus) or in some UI (focused).
    snapshotHasUIFocus = (focusedElement ~= nil
        and focusedElement.elemType ~= nil
        and focusedElement.elemType ~= "")

    -- =================================================================
    -- Restore world routing when a gameplay-interrupting menu closes.
    -- When routeToWorld was flipped false for a menu (shortcuts, pause)
    -- and no menu widgets remain in the scan, switch back to world.
    -- =================================================================
    if not routeToWorld and worldRouteBeforeMenu
        and not suppressSnapshots then
        local hasMenuWidget = false
        if snapshot.widgetDCTypes then
            for _, widgetDCType in ipairs(snapshot.widgetDCTypes) do
                if Menus.IsMenuDCType(widgetDCType) then
                    hasMenuWidget = true
                    break
                end
            end
        end
        if not hasMenuWidget then
            worldRouteBeforeMenu = false
            routeToWorld = true
            Menus.ResetAllHandlers()
            Log.Info("Routing back to WorldUI (menu closed)")
        end
    end

    -- =================================================================
    -- Early menu delivery: some menus (shortcuts radial) use local
    -- focus instead of standard IsFocused/FocusManager, so the C++
    -- focus strategies never report a focusedElement for them.
    -- Deliver the snapshot to Menus before the focusedElement guard
    -- drops it, so the screen entry announcement fires.
    -- =================================================================
    if not suppressSnapshots
        and snapshot.widgetAdded and snapshot.widgetData
        and snapshot.widgetData.dcType
        and Menus.IsMenuDCType(snapshot.widgetData.dcType)
        and (not focusedElement or not focusedElement.elemType) then
        if not routeToWorld then
            Menus.RouteSnapshot(snapshot)
        end
        return
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
    if snapshot.widgetData
        and snapshot.widgetData.elemName == "PinnedTooltips_c" then
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

    -- Late world panel detection: when the widget callback's widgetData
    -- carried a generic DC type (ls.Widget) but a panel widget was also
    -- present, the widget processing block above missed it.  WorldUI
    -- owns the detection logic (checking focused/selected/widget DC
    -- types against its handler table).
    if not routeToWorld
        and (snapshot.focusChanged or snapshot.selectionChanged) then
        local World = BG3Access.Client.WorldUI
        if World and World.TryActivateFromSnapshot(snapshot) then
            Menus.ResetAllHandlers()
            routeToWorld = true
            Log.Info("Routing to WorldUI (late detection)")
        end
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
        Menus.RouteSnapshot(snapshot)
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

    -- Reset router state.
    lastWidgetRootStr = nil
    exploreLastSpoken = nil
    spokenLoadingTips = {}
    worldDialogOverlayJustSpoke = false
    worldRouteBeforeMenu = false
    suppressWorldEntryVisualText = false

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

-- Detect mid-session reload (SE console `reset`).
-- During normal startup the mod loads in LoadMenu state and
-- GameStateChanged fires to clear suppressSnapshots.  After reset,
-- Lua reloads in Running state with no state transition.
-- If entities with ClientControl exist, we are in gameplay.
local resetOk, resetEntities = pcall(
    Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
if resetOk and resetEntities and next(resetEntities) then
    suppressSnapshots = false
    -- Also set routeToWorld since we're clearly in gameplay.  Without
    -- this, IsUIActive returns true in free world because the default
    -- routeToWorld=false is interpreted as "pre-game menus".
    routeToWorld = true
    Log.Info("Mid-session reload detected, suppression cleared")
end

-- ---------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------
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
        -- Inspect panel (PinnedTooltips_c) consumes RS input.
        if inspectWidgetActive then return true end
        -- Gameplay: check the cached focus state from the tick monitor.
        return snapshotHasUIFocus
    end,
}

Log.Info("Accessibility ready (GlobalFocusMonitor).")
