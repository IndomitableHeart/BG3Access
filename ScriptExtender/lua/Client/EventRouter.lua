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

    local focusedElement = snapshot.focusedElement

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
            Log.Info("CONTEXT MENU: " .. itemText)
            Ext.Tolk.Speak(itemText, true)
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
            else
                Menus.HandleWidgetAdded(snapshot.widgetData)
                -- Switch routing to Menus if coming from WorldUI.
                if routeToWorld then
                    if World then World.ResetAllPanelHandlers() end
                    routeToWorld = false
                    Log.Info("Routing to Menus")
                end
            end
        end
    end

    -- =================================================================
    -- focusedElement guard: everything below needs a valid focus target.
    -- Widget-added events (above) are processed regardless.
    -- =================================================================
    if not focusedElement or not focusedElement.elemType then return end

    -- =================================================================
    -- World entry visual text suppression: skip the initial burst of
    -- HUD widget visual texts (Overlay "Examine", "Context Menu", etc.)
    -- that fire when entering Running state.  Clear once a genuine focus
    -- event (focusChanged/selectionChanged) arrives -- that means the
    -- player has started interacting.
    -- =================================================================
    if suppressWorldEntryVisualText then
        if snapshot.focusChanged or snapshot.selectionChanged then
            -- Player interacted -- clear suppression.
            suppressWorldEntryVisualText = false
        elseif focusedElement.namedTexts then
            -- Check if this snapshot only has visual text entries.
            local hasVisualText = false
            for textKey, _ in pairs(focusedElement.namedTexts) do
                if textKey:find("^_visualText_") then
                    hasVisualText = true
                    break
                end
            end
            if hasVisualText then
                Log.Debug("Suppressed world entry visual text")
                return
            end
        end
    end

    -- =================================================================
    -- Loading suppression: only allow visual text (tips, splash screen).
    -- C++ sends indexed keys (_visualText_1, _visualText_2, ...) to
    -- avoid Lua table key collisions.  Speak each non-percentage text.
    -- =================================================================
    if suppressSnapshots then
        if snapshot.widgetAdded and focusedElement.namedTexts then
            -- Collect and sort keys so tips speak in document order
            -- (pairs() iteration order is not guaranteed).
            local visualKeys = {}
            for textKey, _ in pairs(focusedElement.namedTexts) do
                if textKey:find("^_visualText_") then
                    table.insert(visualKeys, textKey)
                end
            end
            table.sort(visualKeys)
            for _, textKey in ipairs(visualKeys) do
                local visualText = focusedElement.namedTexts[textKey]
                if visualText and visualText ~= ""
                    and not visualText:match("^%d+%%?$")
                    and not spokenLoadingTips[visualText] then
                    spokenLoadingTips[visualText] = true
                    Log.Info("LOADING TIP: " .. visualText)
                    Ext.Tolk.Speak(visualText, false)
                end
            end
        end
        return
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
            Log.Info("EXPLORE: " .. speech)
            Ext.Tolk.Speak(speech, true)
        end
        return
    end

    -- =================================================================
    -- Widget root tracking: detect UI teardown/rebuild.
    -- =================================================================
    local widgetRootId = focusedElement.widgetRootId or ""
    if widgetRootId ~= "" and widgetRootId ~= lastWidgetRootStr then
        lastWidgetRootStr = widgetRootId
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
    -- Dispatch to the active handler module.
    -- =================================================================
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

    -- =================================================================
    -- Tooltip events: speak AFTER the focus/handler speech so tooltip
    -- text supplements the item name rather than competing with it.
    -- Routed through the Tooltip handler for title/description ordering
    -- and junk filtering.
    -- =================================================================
    if snapshot.tooltipChanged and snapshot.tooltipTexts then
        local tooltipSpeech = Helpers.FormatTooltipTexts(snapshot.tooltipTexts)
        if tooltipSpeech then
            Log.Info("TOOLTIP: " .. tooltipSpeech)
            Ext.Tolk.Speak(tooltipSpeech, false)
        end
    end
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
    routeToWorld = false
    worldDialogOverlayJustSpoke = false
    suppressWorldEntryVisualText = false

    local toState = tostring(e.ToState)
    suppressSnapshots = LOADING_STATES[toState] or false
    -- Suppress visual text speech on world entry (Running state).
    -- HUD widgets fire immediately and their visual texts (static button
    -- prompts like "Examine", "Context Menu") are useless noise.
    -- The RS HUD reader replaces this -- user reads info when ready.
    suppressWorldEntryVisualText = (toState == "Running")
    SetupGlobalFocusMonitor()
end)

-- ---------------------------------------------------------------------------
-- Debug explore mode toggle (L3 + R3).
-- ---------------------------------------------------------------------------
function BG3Access.Client.ToggleExploreMode()
    debugExploreMode = not debugExploreMode
    local modeState = debugExploreMode and "ON" or "OFF"
    Log.Info("Explore mode: " .. modeState)
    Ext.Tolk.Speak("Explore mode " .. modeState, true)
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
    Log.Info("Mid-session reload detected, suppression cleared")
end

Log.Info("Accessibility ready (GlobalFocusMonitor).")
