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
local H     = BG3Access.Client.Helpers
local CC    = BG3Access.Client.CC
local CS    = BG3Access.Client.Cutscene
local Menus = BG3Access.Client.Menus

-- ---------------------------------------------------------------------------
-- Cross-cutting state (not owned by any single handler).
-- ---------------------------------------------------------------------------
local suppressSnapshots   = false
local lastWidgetRootStr   = nil
local debugExploreMode    = false
-- Explore mode uses its own lastSpokenFullText to avoid needing a handler state.
local exploreLastSpoken   = nil
-- Loading tips use their own dedup to avoid needing a handler state.
local lastSpokenLoadingTip = nil

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
        and CS.IsDialogOrCutscene(snapshot.widgetData.dcType) then
        CS.HandleDialogWidgetEvent(snapshot.widgetData)
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

    if not focusedElement or not focusedElement.elemType then return end

    -- =================================================================
    -- Loading suppression: only allow visual text (tips, splash screen).
    -- =================================================================
    if suppressSnapshots then
        if snapshot.widgetAdded and focusedElement.namedTexts then
            local visualText = focusedElement.namedTexts["_visualText"]
            if visualText and visualText ~= ""
                and not visualText:match("^%d+%%?$")
                and visualText ~= lastSpokenLoadingTip then
                lastSpokenLoadingTip = visualText
                Log.Info("LOADING TIP: " .. visualText)
                Ext.Tolk.Speak(visualText, false)
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
        local text = H.ExtractTextFromData(data, nil, false)
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
        local speech = H.StripMarkupTags(table.concat(parts, " | "))
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
        Menus.HandleWidgetRootChanged()
    end

    -- =================================================================
    -- Widget added events: route to Menus for handler activation,
    -- and handle cross-cutting dialog/CC cleanup.
    -- =================================================================
    if snapshot.widgetAdded and snapshot.widgetData
        and snapshot.widgetData.dcType then
        local newDCType = snapshot.widgetData.dcType
        -- Reset dialog state when a non-dialog widget appears.
        if not CS.IsDialogOrCutscene(newDCType) then
            CS.ResetDialogState()
        end
        -- Dialog overlays (MessageBox) are handled separately with full
        -- snapshot context to distinguish real modals from pre-loaded widgets.
        if Menus.IsDialogOverlay(newDCType) then
            Menus.HandleDialogOverlay(snapshot, snapshot.widgetData)
        else
            -- Route to CC and Menus for handler activation and widget hooks.
            -- CC.HandleWidgetAdded detects its own widget re-appearing after
            -- a blurb/cutscene and resets state internally.
            CC.HandleWidgetAdded(snapshot.widgetData)
            Menus.HandleWidgetAdded(snapshot.widgetData)
        end
    end

    -- =================================================================
    -- HotBar (action radial) focus tracking.
    -- When focus first moves to a VMHotBar element, the action radial
    -- has just opened — route to World for intro speech.  LB/RB page
    -- switches also cause VMHotBar focus changes but are suppressed
    -- by World (inRadial flag).  When focus moves to any non-radial
    -- element, clear the flag so the next open is detected.
    -- =================================================================
    if snapshot.focusChanged then
        local World = BG3Access.Client.WorldUI
        if World then
            if focusedElement.dcType
                and focusedElement.dcType:find("VMHotBar") then
                World.HandleRadialOpen()
                return
            else
                World.ClearRadialFocus()
            end
        end
    end

    -- =================================================================
    -- Dispatch to per-menu handler via Menus router.
    -- =================================================================
    Menus.RouteSnapshot(snapshot)
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
    StartLoading = true, StartServer = true, LoadSession = true,
    LoadLevel = true, SwapLevel = true, UnloadLevel = true,
    UnloadSession = true, InitNetwork = true, InitConnection = true,
    StopLoading = true, Idle = true,
}

Ext.Events.GameStateChanged:Subscribe(function(e)
    Log.Info("GameStateChanged: " .. tostring(e.FromState)
        .. " -> " .. tostring(e.ToState))

    -- Reset all handler modules.
    Menus.ResetAllHandlers()
    CC.ResetCCState()
    if CC.UnsubscribeCCYButton then CC.UnsubscribeCCYButton() end
    CS.ResetDialogState()
    CS.HandleGameStateForAD(tostring(e.FromState), tostring(e.ToState))
    local World = BG3Access.Client.WorldUI
    if World then World.ResetState() end

    -- Reset router state.
    lastWidgetRootStr = nil
    exploreLastSpoken = nil
    lastSpokenLoadingTip = nil

    local toState = tostring(e.ToState)
    suppressSnapshots = LOADING_STATES[toState] or false
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
Log.Info("Accessibility ready (GlobalFocusMonitor).")
