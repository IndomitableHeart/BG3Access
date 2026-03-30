-- File: Client/AccessibilityManager.lua
--
-- Accessibility manager using C++ GlobalFocusMonitor.
--
-- ARCHITECTURE: No Noesis objects cross into Lua for focus events.
-- C++ extracts all element data during Tick() and passes a plain Lua
-- table (strings, bools, numbers) to the callback.  Lua only processes
-- primitives for speech formatting and state management.
--
-- CC (Character Creation) snapshots are detected early and delegated to
-- AccessibilityCC.lua.  This file handles ONLY generic menus: Options,
-- Difficulty, Multiplayer, Mod Manager, Dialogs, Main Menu, etc.

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

-- Module references (loaded before this file by _Init.lua).
local Log = BG3Access.Client.Log
local H   = BG3Access.Client.Helpers
local CC  = BG3Access.Client.CC
local CS  = BG3Access.Client.Cutscene

-- ---------------------------------------------------------------------------
-- Shared state (also passed to CC handler via state table).
-- ---------------------------------------------------------------------------
local state = {
    lastSpokenName      = nil,
    lastSpokenFullText  = nil,
    lastSpokenTab       = nil,
    lastSpokenTitle     = nil,
    tabHintSpoken       = false,
    screenEntryJustSpoke = false,
    currentWidgetDCType = nil,
}

local suppressSnapshots   = false
local lastWidgetRootStr   = nil
local seenWidgetRoots     = {}
local debugExploreMode    = false

-- ---------------------------------------------------------------------------
-- Controller bindings interactive mode.
-- ---------------------------------------------------------------------------
local controllerBindingsData = nil
local controllerInputSubscription = nil
local controllerAxisSubscription = nil

local SDL_BUTTON_TO_DC_KEY = {
    A = "ButtonA", B = "ButtonB", X = "ButtonX", Y = "ButtonY",
    LeftShoulder = "LeftBumper", RightShoulder = "RightBumper",
    DPadUp = "DpadUp", DPadDown = "DpadDown",
    DPadLeft = "DpadLeft", DPadRight = "DpadRight",
    Start = "ButtonStart", Back = "ButtonBack",
    LeftStick = "LeftStick", RightStick = "RightStick",
}

local SDL_AXIS_TO_DC_KEY = {
    TriggerLeft = "LeftTrigger", TriggerRight = "RightTrigger",
    LeftX = "LeftStick", LeftY = "LeftStick",
    RightX = "RightStick", RightY = "RightStick",
}

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
    UnsubscribeControllerInput()
    controllerBindingsData = dcProps

    local DOUBLE_PRESS_BUTTONS = {
        B = true, LeftShoulder = true, RightShoulder = true,
    }
    local lastPressedButton = nil

    controllerInputSubscription = Ext.Events.ControllerButtonInput:Subscribe(function(event)
        if not event.Pressed then return end
        local buttonName = tostring(event.Button)
        Log.Debug("Controller button: " .. buttonName)
        local dcKey = SDL_BUTTON_TO_DC_KEY[buttonName]
        if dcKey then
            if DOUBLE_PRESS_BUTTONS[buttonName] then
                if lastPressedButton == buttonName then
                    Log.Debug("  -> Double press, passing through: " .. buttonName)
                    lastPressedButton = nil
                    return
                else
                    lastPressedButton = buttonName
                    SpeakControllerBinding(dcKey)
                    event:PreventAction()
                end
            else
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

    local axisSpoken = {}
    controllerAxisSubscription = Ext.Events.ControllerAxisInput:Subscribe(function(event)
        local axisName = tostring(event.Axis)
        local dcKey = SDL_AXIS_TO_DC_KEY[axisName]
        if not dcKey then return end
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
-- Per-menu navigation hints.  Keyed by widget DC type.
-- false = no hint.  Missing key = default hint.
-- ---------------------------------------------------------------------------
local MENU_HINTS = {
    ["gui::DCOptions"]         = "Use bumpers to switch tabs, press down for content.",
    ["gui::DCLobbyBrowser"]    = "Use bumpers to switch tabs, press down for content.",
    ["gui::DCModBrowser"]      = "Use bumpers to switch tabs, press down for content.",
    ["gui::DCNewGameSettings"] = false,
    ["gui::DCDMSettings"]      = false,
    ["gui::VMPreset"]          = false,
}
local DEFAULT_HINT = "Use bumpers to switch tabs, press down for content."

-- ---------------------------------------------------------------------------
-- Speech output: fill slots, speak immediately.
-- ---------------------------------------------------------------------------
local SLOT_ORDER = { "title", "hint", "tabName", "body", "actions", "itemName", "itemValue", "itemDesc" }

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

    local interrupt = true
    if state.screenEntryJustSpoke and not isScreenEntry then
        interrupt = false
        state.screenEntryJustSpoke = false
    end
    -- Visual text (loading tips, splash screen) should always append.
    -- These arrive from the initial widget scan with no title, tab, hint,
    -- or item -- just body text.  Appending lets tips queue naturally
    -- instead of cutting each other off.
    local isVisualTextOnly = slots["body"] and not slots["title"]
        and not slots["tabName"] and not slots["hint"]
        and not slots["itemName"]
    if isVisualTextOnly then
        interrupt = false
    end
    if isScreenEntry then
        state.screenEntryJustSpoke = true
    end
    Log.Info("SPEAK" .. (interrupt and "" or " (append)") .. ": " .. assembled)
    Ext.Tolk.Speak(assembled, interrupt)
    state.lastSpokenFullText = assembled
end

-- ---------------------------------------------------------------------------
-- Named text extraction helpers.
-- ---------------------------------------------------------------------------
local function ExtractFromNamedTexts(namedTexts)
    if not namedTexts then return nil, {} end
    local titleText = nil
    local bodyParts = {}
    for elementName, elementText in pairs(namedTexts) do
        local nameLower = elementName:lower()
        if nameLower:find("title") or nameLower:find("header") then
            if not titleText then titleText = elementText end
        elseif nameLower:find("body") or nameLower:find("description")
            or nameLower:find("message") or nameLower:find("warning")
            or nameLower:find("busy") or nameLower:find("status")
            or nameLower:find("info")
            or nameLower == "_visualtext" then
            -- Filter out pure numeric text (e.g., "93%" from loading progress).
            if nameLower == "_visualtext" and elementText:match("^%d+%%?$") then
                -- skip progress percentages
            else
                table.insert(bodyParts, elementText)
            end
        end
    end
    return titleText, bodyParts
end

-- Standard DCMessageBox button hint.  Noesis Indie SDK crashes when
-- enumerating the Actions IList collection from C++, so we handle
-- button hints in Lua based on the dialog DC type.
-- Standard dialogs use UIAccept (A) for confirm and UICancel (B) for cancel.
local DIALOG_BUTTON_HINT = "Press A to confirm, or B to cancel"

local function ExtractFromWidgetData(widgetData)
    if not widgetData then return nil, nil, nil end
    local titleText = nil
    local bodyText = nil
    if widgetData.dcProps then
        titleText = widgetData.dcProps.Title or widgetData.dcProps.TitleText
            or widgetData.dcProps.Header or widgetData.dcProps.TitleProperty
        bodyText = widgetData.dcProps.Description or widgetData.dcProps.Text
            or widgetData.dcProps.Message or widgetData.dcProps.BodyText
            or widgetData.dcProps.TextProperty or widgetData.dcProps.LobbyMessage
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
    -- Append button hint for standard message box dialogs.
    local actionsText = nil
    if widgetData.dcType and widgetData.dcType:find("MessageBox") then
        actionsText = DIALOG_BUTTON_HINT
    end
    return titleText, bodyText, actionsText
end

-- ---------------------------------------------------------------------------
-- HandleTickSnapshot: generic menu processor.
-- CC snapshots are dispatched to AccessibilityCC before reaching this code.
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
        -- focusedElement is always a table but may have no elemType.
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
        CC.HandleCCSnapshot(snapshot, state)
        return
    end

    if not focusedElement or not focusedElement.elemType then return end

    -- During loading states, only allow visual text (tips, splash screen).
    -- Normal menu processing is suppressed to avoid stale/transient data.
    if suppressSnapshots then
        if snapshot.widgetAdded and focusedElement.namedTexts then
            local visualText = focusedElement.namedTexts["_visualText"]
            if visualText and visualText ~= ""
                and not visualText:match("^%d+%%?$")
                and visualText ~= state.lastSpokenFullText then
                state.lastSpokenFullText = visualText
                Log.Info("LOADING TIP: " .. visualText)
                Ext.Tolk.Speak(visualText, false)
            end
        end
        return
    end

    -- =================================================================
    -- Debug explore mode: speak raw element info, skip all processing.
    -- =================================================================
    if debugExploreMode and (snapshot.focusChanged or snapshot.selectionChanged) then
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
        local text = H.ExtractTextFromData(data, state.lastSpokenTab, false)
        if text then table.insert(parts, "text:" .. text) end
        Log.Info("EXPLORE sel=" .. tostring(snapshot.selectionChanged)
            .. " foc=" .. tostring(snapshot.focusChanged)
            .. " isTab=" .. tostring(data.isTab)
            .. " postSettle=" .. tostring(snapshot.postSettle)
            .. " elemId=" .. tostring(data.elemId))
        if data.dcProps then
            local propParts = {}
            for propName, propValue in pairs(data.dcProps) do
                table.insert(propParts, propName .. "=" .. tostring(propValue))
            end
            if #propParts > 0 then
                table.sort(propParts)
                Log.Info("EXPLORE dcProps: " .. table.concat(propParts, " | "))
            end
        end
        local speech = H.StripMarkupTags(table.concat(parts, " | "))
        if speech ~= "" and speech ~= state.lastSpokenFullText then
            state.lastSpokenFullText = speech
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
        if controllerBindingsData then
            UnsubscribeControllerInput()
        end
        state.lastSpokenTab = nil
        state.lastSpokenTitle = nil
        state.screenEntryJustSpoke = false
        -- Save previous DC type to detect menu changes vs tab switches.
        state.previousWidgetDCType = state.currentWidgetDCType
        state.currentWidgetDCType = nil
        seenWidgetRoots[widgetRootId] = true
    end

    if snapshot.widgetAdded and snapshot.widgetData and snapshot.widgetData.dcType then
        local newDCType = snapshot.widgetData.dcType
        -- Reset dialog state when a non-dialog widget appears.
        if not CS.IsDialogOrCutscene(newDCType) then
            CS.ResetDialogState()
            -- If returning to CC after a cutscene (e.g. origin preview),
            -- reset speech state so the next snapshot triggers a clean entry.
            if state.inCharacterCreation then
                state.lastSpokenTab = nil
                state.lastSpokenTitle = nil
                state.lastSpokenName = nil
                state.lastSpokenItemName = nil
            end
        end
        -- Reset hint only when entering a genuinely different menu.
        -- Compare against BOTH currentWidgetDCType (for menus that
        -- share widget root, like multiplayer tabs) AND previousWidgetDCType
        -- (for menus that change widget root per tab, like Options).
        -- "Same family" means exact match OR both contain "Option"
        -- (gui::DCOptions and gui::DCControllerOptions are one menu).
        local sameMenuFamily = false
        local currentDC = state.currentWidgetDCType
        local previousDC = state.previousWidgetDCType
        if currentDC and newDCType == currentDC then
            sameMenuFamily = true
        elseif previousDC and newDCType == previousDC then
            sameMenuFamily = true
        elseif currentDC
            and currentDC:find("Option") and newDCType:find("Option") then
            sameMenuFamily = true
        elseif previousDC
            and previousDC:find("Option") and newDCType:find("Option") then
            sameMenuFamily = true
        end
        if not sameMenuFamily then
            state.tabHintSpoken = false
        end
        state.currentWidgetDCType = newDCType
        state.previousWidgetDCType = nil
    end

    local controllerHintText = nil
    if snapshot.widgetAdded and snapshot.widgetData
        and snapshot.widgetData.dcType == "gui::DCControllerOptions"
        and snapshot.widgetData.dcProps then
        SubscribeControllerInput(snapshot.widgetData.dcProps)
        controllerHintText = "Interactive controller mode: While in this tab, press any button or trigger to hear its function. Press LB twice to return to the previous tab, or press RB twice to move to the next tab in the menu. Press B twice to exit to the main menu."
        Log.Info("Controller bindings interactive mode activated")
    end

    -- CC dispatch already handled above (before elemType filter).

    -- =================================================================
    -- Dialog answer navigation: when focus changes within an active
    -- dialog, the cutscene module handles answer speech.
    -- =================================================================
    if snapshot.focusChanged and focusedElement
        and CS.HandleDialogAnswerFocus(focusedElement) then
        return
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
    elseif snapshot.widgetAdded and snapshot.widgetData and not state.lastSpokenTab then
        isScreenEntry = true
    elseif snapshot.focusChanged and focusedElement.isTab then
        isScreenEntry = true
    end

    local isItemNav = snapshot.focusChanged
        and not focusedElement.isTab and not isScreenEntry
    local isCarouselOnly = hasCarousel and not snapshot.focusChanged
    local isValueOnly = not isScreenEntry and not isItemNav
        and not isCarouselOnly and snapshot.valueChanged

    -- Widget text update: DC property changed (e.g., "Finding lobbies..."
    -- -> "No lobbies found") or dialog appeared without focus change.
    -- Checked BEFORE carousel/value handlers because widgetAdded with
    -- text takes priority (valueChanged fires on the same tick but reads
    -- from focusedElement.dcProps which doesn't have the widget text).
    if not isScreenEntry and not isItemNav and snapshot.widgetAdded and snapshot.widgetData then
        local _, widgetBody, widgetActions = ExtractFromWidgetData(snapshot.widgetData)
        local updateText = widgetBody or widgetActions
        if updateText and updateText ~= ""
            and updateText ~= state.lastSpokenFullText then
            state.lastSpokenFullText = updateText
            Log.Info("WIDGET UPDATE: " .. updateText)
            Ext.Tolk.Speak(updateText, true)
            return
        end
    end

    if not isScreenEntry and not isItemNav
        and not isCarouselOnly and not isValueOnly then
        return
    end

    -- =================================================================
    -- Standalone carousel or value.
    -- =================================================================
    if isCarouselOnly then
        local carouselValue = snapshot.inlineCarouselValue
        if carouselValue ~= state.lastSpokenFullText then
            state.lastSpokenFullText = carouselValue
            Log.Info("CAROUSEL: " .. carouselValue)
            Ext.Tolk.Speak(carouselValue, true)
        end
        return
    end

    if isValueOnly then
        local valueText = H.FormatDCValue(focusedElement.dcProps)
        if valueText and valueText ~= "" and valueText ~= state.lastSpokenFullText then
            state.lastSpokenFullText = valueText
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
    local normalTab = ""
    local screenTitle = nil

    if isScreenEntry then
        -- If widget root changed but no widgetAdded event arrived (e.g.
        -- returning to main menu), previousWidgetDCType is still set.
        -- The widgetAdded DC check above handles most cases, but when
        -- no widgetAdded fires, we need to clear the stale previous DC.
        -- Do NOT reset hint here -- the widgetAdded path handles that.
        if state.previousWidgetDCType then
            state.previousWidgetDCType = nil
        end

        -- Derive tab name.
        if focusedElement.isTab then
            tabName = focusedElement.tabName
        end
        normalTab = tabName and H.NormalizeForCompare(tabName) or ""

        -- Dedup: skip if same tab.
        if tabName and tabName == state.lastSpokenTab then
            Log.Debug("SKIP screen entry (same tab): " .. tabName)
            return
        end

        Log.Info("SCREEN ENTRY: tab=" .. tostring(tabName)
            .. " sel=" .. tostring(snapshot.selectionChanged)
            .. " widget=" .. tostring(snapshot.widgetAdded))

        -- Always update, even when nil, so widgetAdded doesn't re-trigger.
        -- Use empty string as sentinel for "screen entry processed, no tab name".
        state.lastSpokenTab = tabName or ""
        state.lastSpokenName = nil

        -- Gather data sources.
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
        local widgetTitle, widgetBody, widgetActions = ExtractFromWidgetData(snapshot.widgetData)

        -- Title.
        screenTitle = nsTitle or widgetTitle
        if screenTitle and normalTab ~= ""
            and H.NormalizeForCompare(screenTitle) == normalTab then
            screenTitle = nil
        end
        if screenTitle and screenTitle == state.lastSpokenTitle then
            screenTitle = nil
        end
        if screenTitle then
            state.lastSpokenTitle = screenTitle
            slots["title"] = screenTitle
        end

        -- Hint (once per menu visit).
        if not state.tabHintSpoken then
            state.tabHintSpoken = true
            local menuType = state.currentWidgetDCType
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
        -- Dialog button actions (e.g., "A: Yes, B: No").
        if widgetActions then
            slots["actions"] = widgetActions
        end
    else
        -- Item navigation: dedup check.
        if elemId == state.lastSpokenName and not hasCarousel then
            local text = H.ExtractTextFromData(focusedElement, state.lastSpokenTab, false)
            if not text or text == state.lastSpokenFullText then
                Log.Debug("DEDUP SKIP: " .. tostring(elemId))
                return
            end
        end
    end

    -- ----- Item slots -----
    local itemName = nil
    local itemValue = nil
    local itemDesc = nil

    local splitName, splitValue, splitDesc = H.FormatDCTextSplit(focusedElement.dcProps)
    if not splitName or splitName == "" then
        splitName = H.ExtractTextFromData(focusedElement, state.lastSpokenTab, isScreenEntry)
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
        end
        -- Keep description even when name is suppressed as tab duplicate.
        if splitDesc then itemDesc = splitDesc end
        if splitValue and not itemValue then itemValue = splitValue end
    end

    if hasCarousel then
        itemValue = snapshot.inlineCarouselValue
    end

    if itemName then
        slots["itemName"] = itemName
        state.lastSpokenName = elemId
        state.lastSpokenFullText = itemName
        Log.Info("ITEM: " .. tostring(focusedElement.elemType)
            .. "  name=" .. itemName
            .. (itemValue and ("  val=" .. itemValue) or "")
            .. (itemDesc and ("  desc=" .. tostring(itemDesc):sub(1, 40)) or ""))
    end
    if itemValue then slots["itemValue"] = itemValue end
    if itemDesc then slots["itemDesc"] = itemDesc end

    SpeakSlots(slots, isScreenEntry)
end

-- ---------------------------------------------------------------------------
-- Subscribe to the C++ per-frame GlobalFocusMonitor.
-- ---------------------------------------------------------------------------
local function SetupGlobalFocusMonitor()
    local ok, result = pcall(Ext.UI.SubscribeGlobalFocusChanged, function(first, prop)
        if type(first) ~= "table" then
            Log.Warn("unexpected callback arg type: " .. type(first))
            return
        end
        if prop == "TickSnapshot" then
            local handlerOk, handlerErr = pcall(HandleTickSnapshot, first)
            if not handlerOk then
                Log.Error("in HandleTickSnapshot: " .. tostring(handlerErr))
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

-- Game state transitions.
local LOADING_STATES = {
    StartLoading = true, StartServer = true, LoadSession = true,
    LoadLevel = true, SwapLevel = true, UnloadLevel = true,
    UnloadSession = true, InitNetwork = true, InitConnection = true,
    StopLoading = true, Idle = true,
}

Ext.Events.GameStateChanged:Subscribe(function(e)
    Log.Info("GameStateChanged: " .. tostring(e.FromState) .. " -> " .. tostring(e.ToState))
    UnsubscribeControllerInput()
    state.lastSpokenName = nil
    state.lastSpokenFullText = nil
    state.lastSpokenTab = nil
    state.lastSpokenTitle = nil
    state.tabHintSpoken = false
    state.screenEntryJustSpoke = false
    state.currentWidgetDCType = nil
    state.previousWidgetDCType = nil
    state.inCharacterCreation = false
    state.inPostNamingCC = false
    state.pendingTransition = nil
    state.suppressGuardianTeardown = false
    if CC and CC.UnsubscribeCCYButton then CC.UnsubscribeCCYButton() end
    lastWidgetRootStr = nil
    seenWidgetRoots = {}
    CS.ResetDialogState()
    CS.HandleGameStateForAD(tostring(e.FromState), tostring(e.ToState))
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
