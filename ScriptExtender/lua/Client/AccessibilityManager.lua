-- File: Client/AccessibilityManager.lua
--
-- Accessibility manager using C++ GlobalFocusMonitor.
--
-- ARCHITECTURE: No Noesis objects cross into Lua for focus events.
-- C++ extracts all element data during Tick() and passes a plain Lua
-- table (strings, bools, numbers) to the callback.  Lua only processes
-- primitives for speech formatting and state management.
--
-- The C++ monitor runs every frame, tracks focus (Strategies 1+2) and
-- selection (Strategy 3) INDEPENDENTLY.  Selection changes take priority
-- (tab switch, option selection); when selection is stable, focus changes
-- drive the callback (d-pad navigation, button focus).
--
-- Focus callback receives a DATA TABLE with:
--   elemType, elemName, elemId, isTab, isFocusable,
--   dcType, dcProps, elemText, tabName, widgetRootId
--
-- INPC (PropertyChanged) is auto-subscribed by C++ when focus changes.
-- Fires the same callback with eventType="PropertyChanged" and updated
-- dcProps.  Lua speaks the value-only part.
--
-- Widget-added events (Strategy 4) pass data tables with widget DC
-- properties and binding metadata.  No Noesis elements cross to Lua.
--
-- Widget DC changes (WidgetDCChanged) fire when the widget's ViewModel
-- updates (e.g., after tab content loads).  Replaces the old WaitFrames
-- timer with event-driven detection from C++ INPC monitoring.
--
-- SPEECH MODEL: Context + Debounce aggregator.
-- Events update named slots (title, hint, tabName, body, itemName).
-- A debounce timer fires after the last update and assembles all
-- non-nil slots into ONE Tolk.Speak call in accessibility order.
-- No priority interruption, no chain/follow-up queue.

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

-- Module references (loaded before this file by _Init.lua).
local Log = BG3Access.Client.Log
local H   = BG3Access.Client.Helpers

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local lastSpokenName      = nil   -- identity of last spoken element
local lastSpokenFullText  = nil   -- full assembled text of last speech
local lastSpokenTab       = nil   -- tab NAME (not elemId) of last spoken tab
local lastSpokenTitle     = nil   -- screen title last spoken (suppress repeats on same screen)
local tabHintSpoken       = false -- true after we've spoken the navigation hint this visit
local suppressSnapshots   = false -- true during game state transitions (loading, etc.)
local lastWidgetRootStr   = nil   -- widgetRootId string of the last widget root (dialog detection)
local seenWidgetRoots     = {}   -- set of widget root strings we've visited
local currentWidgetDCType = nil   -- dcType of the current menu's widget (e.g. "gui::DCOptions")
local debugExploreMode    = false -- toggle with L3+R3; speaks raw element info on every focus change

-- ---------------------------------------------------------------------------
-- Controller bindings interactive mode.
-- When active on the Controller options tab, pressing a button speaks its
-- mapped function instead of performing the in-game action.
-- ---------------------------------------------------------------------------
local controllerBindingsData = nil       -- stored DCControllerOptions dcProps
local controllerInputSubscription = nil  -- subscription ID for ControllerButtonInput
local controllerAxisSubscription = nil   -- subscription ID for ControllerAxisInput

-- Map SDL button enum names (from ControllerButtonInput) to DCControllerOptions keys.
local SDL_BUTTON_TO_DC_KEY = {
    A = "ButtonA",
    B = "ButtonB",
    X = "ButtonX",
    Y = "ButtonY",
    LeftShoulder = "LeftBumper",
    RightShoulder = "RightBumper",
    DPadUp = "DpadUp",
    DPadDown = "DpadDown",
    DPadLeft = "DpadLeft",
    DPadRight = "DpadRight",
    Start = "ButtonStart",
    Back = "ButtonBack",
    LeftStick = "LeftStick",
    RightStick = "RightStick",
}

-- Map SDL axis enum names (from ControllerAxisInput) to DCControllerOptions keys.
local SDL_AXIS_TO_DC_KEY = {
    TriggerLeft = "LeftTrigger",
    TriggerRight = "RightTrigger",
    LeftX = "LeftStick",
    LeftY = "LeftStick",
    RightX = "RightStick",
    RightY = "RightStick",
}

-- Friendly display names for speech output.
local BUTTON_DISPLAY_NAMES = {
    ButtonA = "A", ButtonB = "B", ButtonX = "X", ButtonY = "Y",
    DpadUp = "D-pad Up", DpadDown = "D-pad Down",
    DpadLeft = "D-pad Left", DpadRight = "D-pad Right",
    LeftBumper = "Left Bumper", RightBumper = "Right Bumper",
    LeftTrigger = "Left Trigger", RightTrigger = "Right Trigger",
    LeftStick = "Left Stick", RightStick = "Right Stick",
    ButtonStart = "Start", ButtonBack = "Back",
}

local function SpeakControllerBinding(dcKey)
    if not controllerBindingsData then return false end
    local binding = controllerBindingsData[dcKey]
    if type(binding) ~= "table" or not binding.Functionality then return false end
    local displayName = BUTTON_DISPLAY_NAMES[dcKey] or dcKey
    local functionality = H.CleanControllerFunctionality(binding.Functionality)
    if not functionality or functionality == "" then return false end
    local speech = displayName .. ": " .. functionality
    Log.Info("Controller binding -> " .. speech)
    Ext.Tolk.Speak(speech, true)
    return true
end

local function UnsubscribeControllerInput()
    if controllerInputSubscription then
        Ext.Events.ControllerButtonInput:Unsubscribe(controllerInputSubscription)
        controllerInputSubscription = nil
        Log.Info("Unsubscribed controller button input")
    end
    if controllerAxisSubscription then
        Ext.Events.ControllerAxisInput:Unsubscribe(controllerAxisSubscription)
        controllerAxisSubscription = nil
        Log.Info("Unsubscribed controller axis input")
    end
    controllerBindingsData = nil
end

local function SubscribeControllerInput(dcProps)
    -- Clean up any existing subscription first.
    UnsubscribeControllerInput()

    controllerBindingsData = dcProps

    -- Navigation buttons require a double-press to perform their action.
    -- First press speaks the binding, second consecutive press passes through.
    local DOUBLE_PRESS_BUTTONS = {
        B = true,
        LeftShoulder = true,
        RightShoulder = true,
    }

    local lastPressedButton = nil  -- tracks last button for double-press detection

    controllerInputSubscription = Ext.Events.ControllerButtonInput:Subscribe(function(event)
        if not event.Pressed then return end
        local buttonName = tostring(event.Button)
        Log.Debug("Controller button: " .. buttonName)
        local dcKey = SDL_BUTTON_TO_DC_KEY[buttonName]
        if dcKey then
            if DOUBLE_PRESS_BUTTONS[buttonName] then
                if lastPressedButton == buttonName then
                    -- Second consecutive press: let it through, reset.
                    Log.Debug("  -> Double press, passing through: " .. buttonName)
                    lastPressedButton = nil
                    return
                else
                    -- First press: speak binding, block action.
                    lastPressedButton = buttonName
                    SpeakControllerBinding(dcKey)
                    event:PreventAction()
                end
            else
                -- Non-navigation button: always speak and block.
                lastPressedButton = buttonName
                SpeakControllerBinding(dcKey)
                event:PreventAction()
            end
        else
            lastPressedButton = nil
            Log.Debug("  -> No mapping for button: " .. buttonName)
        end
    end)
    Log.Info("Subscribed controller button input")

    -- Axis subscription for triggers and sticks.
    -- Only fire on significant deflection (trigger pulled past threshold).
    local axisSpoken = {}  -- prevent rapid repeats on held axis
    controllerAxisSubscription = Ext.Events.ControllerAxisInput:Subscribe(function(event)
        local axisName = tostring(event.Axis)
        local dcKey = SDL_AXIS_TO_DC_KEY[axisName]
        if not dcKey then return end

        -- Threshold: axis values are normalized -1.0 to 1.0.
        -- Fire when deflected past 50%.
        local AXIS_THRESHOLD = 0.5
        local value = event.Value or 0
        local deflected = (value > AXIS_THRESHOLD or value < -AXIS_THRESHOLD)

        if deflected and not axisSpoken[dcKey] then
            axisSpoken[dcKey] = true
            SpeakControllerBinding(dcKey)
        elseif not deflected then
            axisSpoken[dcKey] = nil
        end
    end)
    Log.Info("Subscribed controller axis input")
end

-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Per-menu navigation hints.  Keyed by widget DC type.
-- false = no hint for that menu.  Missing key = default hint.
-- ---------------------------------------------------------------------------
local MENU_HINTS = {
    -- Options: standard bumper tab switching + vertical content
    ["gui::DCOptions"] = "Use bumpers to switch tabs, press down for content.",
    -- Multiplayer: bumper tab switching (Online, Cross-Play, LAN)
    ["gui::DCLobbyBrowser"] = "Use bumpers to switch tabs, press down for content.",
    -- Mod manager: bumper tab switching (Browse, Installed)
    ["gui::DCModBrowser"] = "Use bumpers to switch tabs, press down for content.",
    -- Character creation: bumper tab switching (Origin, Race, Class, etc.)
    ["gui::DCCharacterCreation"] = "Use bumpers to switch tabs.",
    -- Difficulty selector: d-pad left/right navigation, no bumpers
    ["gui::DCNewGameSettings"] = false,
    ["gui::DCDMSettings"] = false,
    -- VMPreset is the tab item DC type inside the difficulty carousel
    ["gui::VMPreset"] = false,
}
local DEFAULT_HINT = "Use bumpers to switch tabs, press down for content."

-- ---------------------------------------------------------------------------
-- Speech output: fill slots, speak immediately.
--
-- Slot order is fixed.  Non-nil slots are joined with ". " and spoken.
-- No timers, no debounce, no deferred assembly.
-- Every snapshot that reaches Lua is the result of user action (the C++
-- settle window filters out Noesis rebuild noise), so always interrupt.
-- ---------------------------------------------------------------------------
local SLOT_ORDER = { "title", "hint", "tabName", "body", "itemName", "itemValue", "itemDesc" }

local screenEntryJustSpoke = false  -- true for ONE snapshot after screen entry

local function SpeakSlots(slots, isScreenEntry)
    local parts = {}
    for _, slotName in ipairs(SLOT_ORDER) do
        local value = slots[slotName]
        if value and value ~= "" then
            table.insert(parts, (value:gsub("[%.%s]+$", "")))
        end
    end
    if #parts == 0 then return end
    local assembled = H.StripMarkupTags(table.concat(parts, ". "))
    if not assembled or assembled == "" then return end
    -- Screen entry always interrupts (user navigated to new screen).
    -- The NEXT speak after screen entry does NOT interrupt (auto-focus).
    -- Everything else interrupts (user d-pad, value change, etc.).
    local interrupt = true
    if screenEntryJustSpoke and not isScreenEntry then
        interrupt = false
        screenEntryJustSpoke = false
    end
    if isScreenEntry then
        screenEntryJustSpoke = true
    end
    Log.Info("SPEAK" .. (interrupt and "" or " (append)") .. ": " .. assembled)
    Ext.Tolk.Speak(assembled, interrupt)
    lastSpokenFullText = assembled
end

-- ---------------------------------------------------------------------------
-- HandleTickSnapshot: single-pass snapshot processor.
--
-- ONE snapshot per tick from C++, ONE pass through this function.
-- Fills slots from snapshot data and speaks immediately.
-- No deferred assembly, no multi-handler dispatch.
--
-- Processing order:
--   1. Inline carousel value (immediate)
--   2. INPC value change on stable focus (immediate)
--   3. Widget root tracking (new screen detection)
--   4. Tab switch / screen entry (full slot assembly)
--   5. Widget added overlay/dialog (immediate)
--   6. Item focus change (item slot only)
-- ---------------------------------------------------------------------------

-- Extract title and body from namedTexts table.
-- Returns (titleText, bodyParts) where bodyParts is an array of strings.
local function ExtractFromNamedTexts(namedTexts)
    if not namedTexts then return nil, {} end
    local titleText = nil
    local bodyParts = {}
    for elementName, elementText in pairs(namedTexts) do
        local nameLower = elementName:lower()
        if nameLower:find("title") or nameLower:find("header") then
            if not titleText then
                titleText = elementText
            end
        elseif nameLower:find("body") or nameLower:find("description")
            or nameLower:find("message") or nameLower:find("warning")
            or nameLower:find("busy") or nameLower:find("status")
            or nameLower:find("info") then
            table.insert(bodyParts, elementText)
        end
    end
    return titleText, bodyParts
end

-- Extract title and body from widget DC properties and bindings.
-- Returns (titleText, bodyText).
local function ExtractFromWidgetData(widgetData)
    if not widgetData then return nil, nil end
    local titleText = nil
    local bodyText = nil
    if widgetData.dcProps then
        titleText = widgetData.dcProps.Title or widgetData.dcProps.TitleText
            or widgetData.dcProps.Header or widgetData.dcProps.TitleProperty
        bodyText = widgetData.dcProps.Description or widgetData.dcProps.Text
            or widgetData.dcProps.Message or widgetData.dcProps.BodyText
            or widgetData.dcProps.TextProperty
    end
    if widgetData.bindings then
        for _, bindingEntry in ipairs(widgetData.bindings) do
            if not titleText and bindingEntry.path and bindingEntry.path:find("Title") and bindingEntry.value then
                titleText = bindingEntry.value
            end
            if not bodyText and bindingEntry.path and (bindingEntry.path:find("Description") or bindingEntry.path:find("Text") or bindingEntry.path:find("Message")) and bindingEntry.value then
                bodyText = bindingEntry.value
            end
        end
    end
    return titleText, bodyText
end

local function HandleTickSnapshot(snapshot)
    if suppressSnapshots then return end
    local focusedElement = snapshot.focusedElement
    if not focusedElement then return end

    -- =================================================================
    -- Debug explore mode: speak raw element info, skip all processing.
    -- =================================================================
    if debugExploreMode and (snapshot.focusChanged or snapshot.selectionChanged) then
        local data = focusedElement
        local parts = {}
        if data.isTab then
            local sectionLabel = H.GetSectionLabel(data)
            table.insert(parts, sectionLabel or "Tab")
            if data.tabName then table.insert(parts, data.tabName) end
        else
            if data.elemType then table.insert(parts, data.elemType) end
            if data.elemName then table.insert(parts, data.elemName) end
        end
        if data.dcType then table.insert(parts, "DC:" .. data.dcType) end
        if data.isFocusable then table.insert(parts, "focusable") end
        local text = H.ExtractTextFromData(data, lastSpokenTab, false)
        if text then table.insert(parts, "text:" .. text) end
        local speech = H.StripMarkupTags(table.concat(parts, " | "))
        if speech ~= "" and speech ~= lastSpokenFullText then
            lastSpokenFullText = speech
            Log.Info("EXPLORE: " .. speech)
            Ext.Tolk.Speak(speech, true)
        end
        return
    end

    -- =================================================================
    -- Housekeeping: widget root tracking, DC type, controller mode.
    -- =================================================================
    local widgetRootId = focusedElement.widgetRootId or ""
    if widgetRootId ~= "" and widgetRootId ~= lastWidgetRootStr then
        lastWidgetRootStr = widgetRootId
        Log.Info("Widget root changed to " .. widgetRootId)
        seenWidgetRoots[widgetRootId] = true
        if controllerBindingsData then
            UnsubscribeControllerInput()
        end
        if not focusedElement.isTab and not H.IsOptionData(focusedElement) then
            lastSpokenTab = nil
            lastSpokenTitle = nil
            tabHintSpoken = false
        end
        currentWidgetDCType = nil
        screenEntryJustSpoke = false
    end

    if snapshot.widgetAdded and snapshot.widgetData and snapshot.widgetData.dcType then
        currentWidgetDCType = snapshot.widgetData.dcType
    end

    local controllerHintText = nil
    if snapshot.widgetAdded and snapshot.widgetData
        and snapshot.widgetData.dcType == "gui::DCControllerOptions"
        and snapshot.widgetData.dcProps then
        SubscribeControllerInput(snapshot.widgetData.dcProps)
        controllerHintText = "Interactive controller mode: While in this tab, press any button or trigger to hear its function. Press LB twice to return to the previous tab, or press RB twice to move to the next tab in the menu. Press B twice to exit to the main menu."
        Log.Info("Controller bindings interactive mode activated")
    end

    -- =================================================================
    -- Classify: what kind of change is this?
    -- =================================================================
    local elemId = focusedElement.elemId or ""
    local hasCarousel = snapshot.inlineCarouselChanged
        and snapshot.inlineCarouselValue
        and snapshot.inlineCarouselValue ~= ""

    local isScreenEntry = false
    if snapshot.selectionChanged then
        isScreenEntry = true
    elseif snapshot.widgetAdded and snapshot.widgetData and not lastSpokenTab then
        isScreenEntry = true
    end

    local isItemNav = snapshot.focusChanged
        and not focusedElement.isTab and not isScreenEntry
    local isCarouselOnly = hasCarousel and not snapshot.focusChanged
    local isValueOnly = not isScreenEntry and not isItemNav
        and not isCarouselOnly and snapshot.valueChanged

    -- Nothing to do?
    if not isScreenEntry and not isItemNav
        and not isCarouselOnly and not isValueOnly then
        return
    end

    -- =================================================================
    -- Standalone carousel or value: speak immediately, no slots needed.
    -- =================================================================
    if isCarouselOnly then
        local carouselValue = snapshot.inlineCarouselValue
        if carouselValue ~= lastSpokenFullText then
            lastSpokenFullText = carouselValue
            Log.Info("CAROUSEL: " .. carouselValue)
            Ext.Tolk.Speak(carouselValue, true)
        end
        return
    end

    if isValueOnly then
        local valueText = H.FormatDCValue(focusedElement.dcProps)
        if valueText and valueText ~= "" and valueText ~= lastSpokenFullText then
            lastSpokenFullText = valueText
            Log.Info("VALUE: " .. valueText)
            Ext.Tolk.Speak(valueText, true)
        end
        return
    end

    -- =================================================================
    -- Screen entry or item navigation: fill slots, speak.
    -- =================================================================
    local slots = {}
    local tabName = nil
    local ccItemName = nil
    local normalTab = ""
    local screenTitle = nil

    -- ----- Screen entry: fill title, hint, tabName, body -----
    if isScreenEntry then
        -- Derive tab name.
        if focusedElement.isTab then
            tabName = focusedElement.tabName
        end
        if not tabName and snapshot.selectionChanged then
            local sectionLabel = H.GetSectionLabel(focusedElement)
            if sectionLabel then
                tabName = sectionLabel
                ccItemName = H.ExtractTextFromData(focusedElement, nil, false)
            end
        end
        normalTab = tabName and H.NormalizeForCompare(tabName) or ""

        -- Appearance carousel (unnamed ListBoxItem).
        if tabName and tabName:find("^ListBoxItem:") then
            local itemLabel = focusedElement.elemName
                and H.GetBodyTypeName(focusedElement.elemName)
            if not itemLabel then
                itemLabel = tabName:match("^ListBoxItem:%s*(.+)$") or tabName
            end
            -- Treat as simple item, not screen entry.
            slots["itemName"] = itemLabel
            lastSpokenName = elemId
            lastSpokenFullText = itemLabel
            Log.Info("ITEM: appearance  name=" .. itemLabel)
            SpeakSlots(slots)
            return
        end

        -- Dedup: skip if same tab.
        if tabName and tabName == lastSpokenTab then
            Log.Debug("SKIP screen entry (same tab): " .. tabName)
            return
        end

        Log.Info("SCREEN ENTRY: tab=" .. tostring(tabName)
            .. " sel=" .. tostring(snapshot.selectionChanged)
            .. " widget=" .. tostring(snapshot.widgetAdded))

        if tabName then lastSpokenTab = tabName end
        lastSpokenName = nil

        -- Gather all data sources.
        local allNamedTexts = {}
        if focusedElement.namedTexts then
            for elementName, elementText in pairs(focusedElement.namedTexts) do
                allNamedTexts[elementName] = elementText
            end
        end
        if snapshot.widgetData and snapshot.widgetData.namedTexts then
            for elementName, elementText in pairs(snapshot.widgetData.namedTexts) do
                if not allNamedTexts[elementName] then
                    allNamedTexts[elementName] = elementText
                end
            end
        end
        local nsTitle, nsBodyParts = ExtractFromNamedTexts(allNamedTexts)
        local widgetTitle, widgetBody = ExtractFromWidgetData(snapshot.widgetData)

        -- Title.
        screenTitle = nsTitle or widgetTitle
        if screenTitle and normalTab ~= ""
            and H.NormalizeForCompare(screenTitle) == normalTab then
            screenTitle = nil
        end
        if screenTitle and screenTitle == lastSpokenTitle then
            screenTitle = nil
        end
        if screenTitle then
            lastSpokenTitle = screenTitle
            slots["title"] = screenTitle
        end

        -- Hint (once per menu visit).
        if not tabHintSpoken then
            tabHintSpoken = true
            local menuType = currentWidgetDCType
            if not menuType or MENU_HINTS[menuType] == nil then
                if focusedElement.dcType and MENU_HINTS[focusedElement.dcType] ~= nil then
                    menuType = focusedElement.dcType
                end
            end
            local menuHint = menuType and MENU_HINTS[menuType]
            if menuHint then
                slots["hint"] = menuHint
            elseif menuHint ~= false and menuType == nil then
                slots["hint"] = DEFAULT_HINT
            end
        end

        -- Tab name (suppress if title contains it).
        if tabName then
            local showTabName = true
            if screenTitle and H.NormalizeForCompare(screenTitle):find(normalTab, 1, true) then
                showTabName = false
            end
            if showTabName then
                slots["tabName"] = tabName
            end
        end

        -- Body.
        local bodyAssembled = nil
        if nsBodyParts and #nsBodyParts > 0 then
            bodyAssembled = table.concat(nsBodyParts, ". ")
        end
        if not bodyAssembled and controllerHintText then
            bodyAssembled = controllerHintText
        end
        if not bodyAssembled and widgetBody then
            bodyAssembled = widgetBody
        end
        local statusText = H.ExtractStatusText(focusedElement.dcProps)
        if statusText then
            bodyAssembled = bodyAssembled
                and (bodyAssembled .. ". " .. statusText) or statusText
        end
        if bodyAssembled then
            slots["body"] = bodyAssembled
        end
    else
        -- Item navigation: dedup check.
        if elemId == lastSpokenName and not hasCarousel then
            local text = H.ExtractTextFromData(focusedElement, lastSpokenTab, false)
            if not text or text == lastSpokenFullText then
                Log.Debug("DEDUP SKIP: " .. tostring(elemId))
                return
            end
        end
    end

    -- ----- Item slots (both screen entry and item navigation) -----
    local itemName = nil
    local itemValue = nil
    local itemDesc = nil

    -- CC: section label is tab, selected item is itemName.
    if ccItemName then
        itemName = ccItemName
        if focusedElement.dcProps and tabName then
            local godTitle, godBody = H.ExtractContextualGodObjectText(
                focusedElement.dcProps, tabName)
            if godBody and godBody ~= "" then
                itemDesc = godBody
            end
        end
    end

    -- Regular element.
    if not itemName then
        local splitName, splitValue, splitDesc = H.FormatDCTextSplit(focusedElement.dcProps)
        if not splitName or splitName == "" then
            splitName = H.ExtractTextFromData(focusedElement, lastSpokenTab, isScreenEntry)
            splitValue = nil
            splitDesc = nil
        end
        if splitName and splitName ~= "" then
            local normalItem = H.NormalizeForCompare(splitName)
            local isDuplicate = (normalTab ~= "" and normalItem == normalTab)
                or (screenTitle and normalItem == H.NormalizeForCompare(screenTitle))
            if not isDuplicate then
                itemName = splitName
                itemValue = splitValue
                if splitDesc then itemDesc = splitDesc end
            end
        end
    end

    -- Inline carousel value.
    if hasCarousel then
        itemValue = snapshot.inlineCarouselValue
    end

    if itemName then
        slots["itemName"] = itemName
        lastSpokenName = elemId
        lastSpokenFullText = itemName
        Log.Info("ITEM: " .. tostring(focusedElement.elemType)
            .. "  name=" .. itemName
            .. (itemValue and ("  val=" .. itemValue) or "")
            .. (itemDesc and ("  desc=" .. tostring(itemDesc):sub(1, 40)) or ""))
    end
    if itemValue then slots["itemValue"] = itemValue end
    if itemDesc then slots["itemDesc"] = itemDesc end

    -- ----- Speak -----
    -- Screen entry speech (title, hint, body) should not interrupt
    -- because the auto-focused item may arrive in a follow-up snapshot
    -- and we don't want the lobby name cutting off "Use bumpers...".
    -- User-initiated navigation (isItemNav) always interrupts.
    SpeakSlots(slots, isScreenEntry)
end

-- ---------------------------------------------------------------------------
-- Subscribe to the C++ per-frame GlobalFocusMonitor.
-- This single callback fires for EVERY focus/selection change in ANY menu.
-- ---------------------------------------------------------------------------
local function SetupGlobalFocusMonitor()
    local ok, result = pcall(Ext.UI.SubscribeGlobalFocusChanged, function(first, prop)
        if type(first) ~= "table" then
            Log.Warn("unexpected callback arg type: " .. type(first))
            return
        end

        -- New snapshot system: one table per tick with everything.
        if prop == "TickSnapshot" then
            local handlerOk, handlerErr = pcall(HandleTickSnapshot, first)
            if not handlerOk then
                Log.Error("in HandleTickSnapshot: " .. tostring(handlerErr))
            end
            return
        end

        -- All legacy event types are now handled by the snapshot system.
        -- Skip any non-snapshot events that arrive through the old path.
        return
    end)
    if ok and result then
        Log.Info("Global focus monitor active")
    else
        Log.Error("could not subscribe global focus: " .. tostring(result))
    end
end

-- Try immediately (root may exist already at script load time).
SetupGlobalFocusMonitor()

-- Re-subscribe on game state changes.
-- Game states where snapshots should be suppressed (loading, transitions).
local LOADING_STATES = {
    StartLoading = true,
    StartServer = true,
    LoadSession = true,
    LoadLevel = true,
    SwapLevel = true,
    UnloadLevel = true,
    UnloadSession = true,
    InitNetwork = true,
    InitConnection = true,
    StopLoading = true,
    Idle = true,
}

Ext.Events.GameStateChanged:Subscribe(function(e)
    Log.Info("GameStateChanged: " .. tostring(e.FromState) .. " -> " .. tostring(e.ToState))
    UnsubscribeControllerInput()
    lastSpokenName = nil
    lastSpokenFullText = nil
    lastSpokenTab = nil
    lastSpokenTitle = nil
    tabHintSpoken = false
    screenEntryJustSpoke = false
    lastWidgetRootStr = nil
    seenWidgetRoots = {}
    currentWidgetDCType = nil
    -- Suppress snapshots during loading/transitions.
    local toState = tostring(e.ToState)
    suppressSnapshots = LOADING_STATES[toState] or false
    SetupGlobalFocusMonitor()
end)

-- ---------------------------------------------------------------------------
-- Debug explore mode toggle.
-- Usage: press L3 + R3 (both sticks) simultaneously.
-- ---------------------------------------------------------------------------
function BG3Access.Client.ToggleExploreMode()
    debugExploreMode = not debugExploreMode
    local state = debugExploreMode and "ON" or "OFF"
    Log.Info("Explore mode: " .. state)
    Ext.Tolk.Speak("Explore mode " .. state, true)
end

-- L3 + R3 combo detection for explore mode toggle.
local exploreComboState = {
    leftStickHeld = false,
    rightStickHeld = false,
}

Ext.Events.ControllerButtonInput:Subscribe(function(event)
    local buttonName = tostring(event.Button)
    -- Log all button presses when explore mode is active.
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

-- State machine probe removed -- C++ GetStateMachine() crashes.
-- Searching via Lua/Noesis tree instead (see BootstrapClient.lua).
