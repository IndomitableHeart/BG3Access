-- File: Client/Menus.lua
--
-- Per-menu handler system using factory pattern.
--
-- Each menu family (Options, Multiplayer, etc.) gets its own handler
-- with isolated state.  The Manager routes snapshots here via
-- RouteSnapshot().  A CreateMenuHandler() factory builds handlers with
-- shared generic pipeline logic but separate state tables.
--
-- Controller bindings interactive mode lives here alongside the Options
-- handler (it is Options-specific).

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

local Log = BG3Access.Client.Log
local Helpers  = BG3Access.Client.Helpers
local Cutscene = BG3Access.Client.Cutscene

-- ============================================================================
-- Controller bindings interactive mode (Options-specific)
-- ============================================================================

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
    local functionality = Helpers.CleanControllerFunctionality(binding.Functionality)
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

-- ============================================================================
-- Generic menu handler factory
-- ============================================================================

-- Default hint for menus that don't specify one and have no explicit false.
local DEFAULT_HINT = "Use bumpers to switch tabs, press down for content."

--- CreateMenuHandler: builds a handler with isolated state and generic pipeline.
---
--- @param config table  Handler configuration:
---   name (string)               -- handler name for logging
---   hint (string|false|nil)     -- navigation hint text, false to suppress, nil for default
---   onWidgetAdded (function)    -- optional: called on widgetAdded with (widgetData, handlerState)
---   onReset (function)          -- optional: called on full state reset
---
--- @return table  Handler with HandleSnapshot, ResetState, ResetNavigation, ResetHint
local function CreateMenuHandler(config)
    local handlerState = {
        lastSpokenName       = nil,
        lastSpokenFullText   = nil,
        lastSpokenTab        = nil,
        lastSpokenTitle      = nil,
        tabHintSpoken        = false,
        screenEntryJustSpoke = false,
        -- Optional: set by onWidgetAdded hooks for body text override.
        bodyOverride         = nil,
    }

    -- -----------------------------------------------------------------
    -- HandleSnapshot: generic menu processing pipeline.
    -- Handles classification, widget updates, carousel/value, screen
    -- entry, item navigation, and speech output.
    -- -----------------------------------------------------------------
    local function HandleSnapshot(snapshot)
        local focusedElement = snapshot.focusedElement
        if not focusedElement or not focusedElement.elemType then return end

        -- Dialog answer navigation: when focus changes within an active
        -- dialog, the cutscene module handles answer speech.
        if snapshot.focusChanged and focusedElement
            and Cutscene.HandleDialogAnswerFocus(focusedElement) then
            return
        end

        -- =============================================================
        -- Classify: what kind of change is this?
        -- =============================================================
        local elemId = focusedElement.elemId or ""
        local hasCarousel = snapshot.inlineCarouselChanged
            and snapshot.inlineCarouselValue
            and snapshot.inlineCarouselValue ~= ""

        local isScreenEntry = false
        if snapshot.selectionChanged then
            isScreenEntry = true
        elseif snapshot.widgetAdded and snapshot.widgetData
            and not handlerState.lastSpokenTab then
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
        if not isScreenEntry and not isItemNav
            and snapshot.widgetAdded and snapshot.widgetData then
            local _, widgetBody, widgetActions = Helpers.ExtractFromWidgetData(
                snapshot.widgetData)
            local updateText = widgetBody or widgetActions
            if updateText and updateText ~= ""
                and updateText ~= handlerState.lastSpokenFullText then
                handlerState.lastSpokenFullText = updateText
                Log.Info("WIDGET UPDATE [" .. config.name .. "]: "
                    .. updateText)
                Ext.Tolk.Speak(updateText, true)
                return
            end
        end

        if not isScreenEntry and not isItemNav
            and not isCarouselOnly and not isValueOnly then
            return
        end

        -- =============================================================
        -- Standalone carousel or value.
        -- =============================================================
        if isCarouselOnly then
            local carouselValue = snapshot.inlineCarouselValue
            if carouselValue ~= handlerState.lastSpokenFullText then
                handlerState.lastSpokenFullText = carouselValue
                Log.Info("CAROUSEL [" .. config.name .. "]: "
                    .. carouselValue)
                Ext.Tolk.Speak(carouselValue, true)
            end
            return
        end

        if isValueOnly then
            local valueText = Helpers.FormatDCValue(focusedElement.dcProps)
            if valueText and valueText ~= ""
                and valueText ~= handlerState.lastSpokenFullText then
                handlerState.lastSpokenFullText = valueText
                Log.Info("VALUE [" .. config.name .. "]: " .. valueText)
                Ext.Tolk.Speak(valueText, true)
            end
            return
        end

        -- =============================================================
        -- Screen entry or item navigation: fill slots, speak.
        -- =============================================================
        local slots = {}
        local tabName = nil
        local normalTab = ""
        local screenTitle = nil

        if isScreenEntry then
            -- Derive tab name.
            if focusedElement.isTab then
                tabName = focusedElement.tabName
            end
            normalTab = tabName and Helpers.NormalizeForCompare(tabName) or ""

            -- Dedup: skip if same tab.
            if tabName and tabName == handlerState.lastSpokenTab then
                Log.Debug("SKIP screen entry (same tab) ["
                    .. config.name .. "]: " .. tabName)
                return
            end

            Log.Info("SCREEN ENTRY [" .. config.name .. "]: tab="
                .. tostring(tabName)
                .. " sel=" .. tostring(snapshot.selectionChanged)
                .. " widget=" .. tostring(snapshot.widgetAdded))

            -- Always update, even when nil, so widgetAdded doesn't
            -- re-trigger.  Empty string = "screen entry processed".
            handlerState.lastSpokenTab = tabName or ""
            handlerState.lastSpokenName = nil

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
            local nsTitle, nsBodyParts
            if config.extractNamedTexts then
                nsTitle, nsBodyParts = config.extractNamedTexts(allNamedTexts)
            else
                nsTitle, nsBodyParts = Helpers.ExtractFromNamedTexts(
                    allNamedTexts)
            end
            local widgetTitle, widgetBody, widgetActions =
                Helpers.ExtractFromWidgetData(snapshot.widgetData)

            -- Title.
            screenTitle = nsTitle or widgetTitle
            if screenTitle and normalTab ~= ""
                and Helpers.NormalizeForCompare(screenTitle) == normalTab then
                screenTitle = nil
            end
            if screenTitle
                and screenTitle == handlerState.lastSpokenTitle then
                screenTitle = nil
            end
            if screenTitle then
                handlerState.lastSpokenTitle = screenTitle
                slots["title"] = screenTitle
            end

            -- Hint (once per menu visit).
            if not handlerState.tabHintSpoken then
                handlerState.tabHintSpoken = true
                local menuHint
                -- hintFn(screenTitle, handlerState) allows dynamic hints
                -- based on screen context (e.g., save vs. load mode).
                if config.hintFn then
                    menuHint = config.hintFn(screenTitle, handlerState)
                else
                    -- nil means use default hint, false means no hint.
                    menuHint = config.hint
                    if menuHint == nil then
                        menuHint = DEFAULT_HINT
                    end
                end
                if menuHint then
                    slots["hint"] = menuHint
                end
            end

            -- Tab name (suppress if title contains it).
            if tabName then
                local showTabName = true
                if screenTitle
                    and Helpers.NormalizeForCompare(screenTitle):find(
                        normalTab, 1, true) then
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
            if not bodyAssembled and handlerState.bodyOverride then
                bodyAssembled = handlerState.bodyOverride
                handlerState.bodyOverride = nil
            end
            if not bodyAssembled and widgetBody then
                bodyAssembled = widgetBody
            end
            local statusText = Helpers.ExtractStatusText(
                focusedElement.dcProps)
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
            if elemId == handlerState.lastSpokenName
                and not hasCarousel then
                local text = Helpers.ExtractTextFromData(
                    focusedElement, handlerState.lastSpokenTab, false)
                if not text
                    or text == handlerState.lastSpokenFullText then
                    Log.Debug("DEDUP SKIP [" .. config.name .. "]: "
                        .. tostring(elemId))
                    return
                end
            end
        end

        -- ----- Item slots -----
        local itemName = nil
        local itemInfo = nil
        local itemValue = nil
        local itemDesc = nil

        local splitName, splitValue, splitDesc, splitValueDesc =
            Helpers.FormatDCTextSplit(focusedElement.dcProps,
                focusedElement.dcType)
        if not splitName or splitName == "" then
            splitName = Helpers.ExtractTextFromData(
                focusedElement, handlerState.lastSpokenTab, isScreenEntry)
            splitValue = nil
            splitDesc = nil
            splitValueDesc = nil
        end
        if splitName and splitName ~= "" then
            local normalItem = Helpers.NormalizeForCompare(splitName)
            local normalTitle = screenTitle
                and Helpers.NormalizeForCompare(screenTitle) or ""
            local isDuplicate = (normalTab ~= ""
                and normalItem == normalTab)
                or (normalTitle ~= ""
                    and (normalItem == normalTitle
                        or normalTitle:find(normalItem, 1, true)))
            if not isDuplicate then
                itemName = splitName
                itemValue = splitValue
                -- When a value has its own description (combobox options),
                -- put the setting description before the value (itemInfo)
                -- and the value description after it (itemDesc).
                -- Order: name -> setting desc -> value -> value desc
                if splitValueDesc then
                    itemInfo = splitDesc
                    itemDesc = splitValueDesc
                else
                    itemDesc = splitDesc
                end
            end
        end

        if hasCarousel then
            itemValue = snapshot.inlineCarouselValue
        end

        if itemName then
            slots["itemName"] = itemName
            handlerState.lastSpokenName = elemId
            handlerState.lastSpokenFullText = itemName
            Log.Info("ITEM [" .. config.name .. "]: "
                .. tostring(focusedElement.elemType)
                .. "  name=" .. itemName
                .. (itemValue and ("  val=" .. itemValue) or "")
                .. (itemDesc
                    and ("  desc=" .. tostring(itemDesc):sub(1, 40))
                    or ""))
        end
        if itemInfo then slots["itemInfo"] = itemInfo end
        if itemValue then slots["itemValue"] = itemValue end
        if itemDesc then slots["itemDesc"] = itemDesc end

        Helpers.SpeakSlots(slots, handlerState, isScreenEntry)
    end

    -- -----------------------------------------------------------------
    -- HandleWidgetAdded: process widget added events.
    -- Called by the router when a widgetAdded event arrives for this
    -- handler's DC type.
    -- -----------------------------------------------------------------
    local function HandleWidgetAdded(widgetData)
        if config.onWidgetAdded then
            config.onWidgetAdded(widgetData, handlerState)
        end
    end

    -- -----------------------------------------------------------------
    -- State management.
    -- -----------------------------------------------------------------

    --- ResetState: full reset (GameStateChanged or handler deactivation).
    local function ResetState()
        handlerState.lastSpokenName = nil
        handlerState.lastSpokenFullText = nil
        handlerState.lastSpokenTab = nil
        handlerState.lastSpokenTitle = nil
        handlerState.tabHintSpoken = false
        handlerState.screenEntryJustSpoke = false
        handlerState.bodyOverride = nil
        if config.onReset then
            config.onReset(handlerState)
        end
    end

    --- ResetNavigation: partial reset for widget root change within
    --- the same handler (e.g., switching tabs in Options).
    --- Preserves tabHintSpoken so the hint doesn't re-speak.
    local function ResetNavigation()
        handlerState.lastSpokenTab = nil
        handlerState.lastSpokenTitle = nil
        handlerState.lastSpokenName = nil
        handlerState.screenEntryJustSpoke = false
        handlerState.bodyOverride = nil
    end

    --- ResetHint: reset tabHintSpoken so the hint speaks on next visit.
    --- Called when this handler is deactivated (different handler takes over).
    local function ResetHint()
        handlerState.tabHintSpoken = false
    end

    return {
        name              = config.name,
        HandleSnapshot    = HandleSnapshot,
        HandleWidgetAdded = HandleWidgetAdded,
        ResetState        = ResetState,
        ResetNavigation   = ResetNavigation,
        ResetHint         = ResetHint,
    }
end

-- ============================================================================
-- Handler instances
-- ============================================================================

local OptionsHandler = CreateMenuHandler({
    name = "Options",
    hint = "Use LB and RB to switch tabs. Up and down cycles through options. Left and right changes values",
    onWidgetAdded = function(widgetData, handlerState)
        if widgetData.dcType == "gui::DCControllerOptions"
            and widgetData.dcProps then
            SubscribeControllerInput(widgetData.dcProps)
            handlerState.bodyOverride = "Interactive controller mode: While in this tab, press any button or trigger to hear its function. Press LB twice to return to the previous tab, or press RB twice to move to the next tab in the menu. Press B twice to exit to the main menu."
            Log.Info("Controller bindings interactive mode activated")
        elseif controllerBindingsData then
            -- Leaving controller tab for a different Options tab.
            UnsubscribeControllerInput()
        end
    end,
    onReset = function(handlerState)
        UnsubscribeControllerInput()
    end,
})

local MultiplayerHandler = CreateMenuHandler({
    name = "Multiplayer",
    hint = "Use LB and RB to switch tabs, Up and down to explore lobbies",
})

local SaveLoadHandler = CreateMenuHandler({
    name = "SaveLoad",
    -- Detect save vs. load context when the widget first appears.
    -- The widget title ("Save Game" vs. "Load Game") is in dcProps or
    -- namedTexts of the widget data.  Store the result on handlerState
    -- so hintFn can use it even if screenTitle is nil at hint time.
    onWidgetAdded = function(widgetData, handlerState)
        local titleCandidate = nil
        if widgetData.dcProps then
            titleCandidate = widgetData.dcProps.Title
                or widgetData.dcProps.TitleText
                or widgetData.dcProps.Mode
        end
        if not titleCandidate and widgetData.namedTexts then
            for elementName, elementText in pairs(widgetData.namedTexts) do
                if elementName:lower():find("title")
                    and elementText and elementText ~= "" then
                    titleCandidate = elementText
                    break
                end
            end
        end
        if titleCandidate then
            local lowerTitle = titleCandidate:lower()
            if lowerTitle:find("save") then
                handlerState.saveLoadMode = "save"
            elseif lowerTitle:find("load") then
                handlerState.saveLoadMode = "load"
            end
            Log.Info("SaveLoad mode: " .. tostring(handlerState.saveLoadMode)
                .. " (from: " .. titleCandidate .. ")")
        end
    end,
    onReset = function(handlerState)
        handlerState.saveLoadMode = nil
    end,
    hintFn = function(screenTitle, handlerState)
        -- Determine mode from stored detection or from screenTitle fallback.
        local isSave = handlerState.saveLoadMode == "save"
            or (handlerState.saveLoadMode == nil
                and screenTitle and screenTitle:lower():find("save"))
        if isSave then
            return "Press A to expand a campaign and see its saves."
                .. " On a save, press A to overwrite."
                .. " X deletes all but the latest save,"
                .. " Y deletes the campaign. B goes back"
        else
            return "Press A to expand a campaign and see its saves."
                .. " On a save, press A to load."
                .. " X deletes all but the latest save,"
                .. " Y deletes the campaign. B goes back"
        end
    end,
})

local PauseMenuHandler = CreateMenuHandler({
    name = "PauseMenu",
    hint = false,
})

-- RT shortcuts radial: shares gui::DCGameMenu with PauseMenu but has
-- widget name "shortcutsMenu".  Routed by widget name, not DC type.
local ShortcutsMenuHandler = CreateMenuHandler({
    name = "ShortcutsMenu",
    hint = "Y for quicksave. X for quickload. A to confirm. B to close",
    onWidgetAdded = function(widgetData, handlerState)
        -- Flag that we'll handle visual texts ourselves in formatBodyFn.
        handlerState.shortcutsMenuActive = true
    end,
    -- Custom named text extractor: the visual texts in this snapshot
    -- are HUD elements (Camp Supplies, Party Gold, etc.) that bleed
    -- through from nearby widgets -- not shortcuts menu content.
    -- Discard them all; the hint covers navigation instructions.
    extractNamedTexts = function(namedTexts)
        return "Shortcuts Menu", {}
    end,
})

local DifficultyHandler = CreateMenuHandler({
    name = "Difficulty",
    hintFn = function(screenTitle)
        if screenTitle and screenTitle:lower():find("custom") then
            return "Pick and choose from a selection of rules to create"
                .. " your own, custom way of playing Baldur's Gate 3."
                .. " Using Custom Mode will not affect the game's story,"
                .. " and achievements are still enabled."
                .. " We recommend new players try a premade difficulty"
                .. " for their first campaign, as this cannot be changed"
                .. " at a later date"
        end
        return false
    end,
    -- Reset hint state when a new widget appears (e.g., transitioning
    -- from preset selector to custom settings).  The hintFn decides
    -- what to say based on screen title — false for presets, paragraph
    -- for custom mode.
    onWidgetAdded = function(widgetData, handlerState)
        handlerState.tabHintSpoken = false
        handlerState.lastSpokenTab = nil
    end,
})

local ModManagerHandler = CreateMenuHandler({
    name = "ModManager",
    hint = "Use bumpers to switch tabs. Use up and down to cycle through items",
})

local MainMenuHandler = CreateMenuHandler({
    name = "MainMenu",
    hint = false,
})

-- ============================================================================
-- DC type routing table
-- ============================================================================

local DC_TYPE_HANDLERS = {
    ["gui::DCOptions"]           = OptionsHandler,
    ["gui::DCOptionsBase"]       = OptionsHandler,
    ["gui::DCControllerOptions"] = OptionsHandler,
    ["gui::DCInterfaceOptions"]  = OptionsHandler,
    ["gui::DCLobbyBrowser"]      = MultiplayerHandler,
    ["gui::DCCharacterAssign"]   = MultiplayerHandler,
    ["gui::DCSavegames"]         = SaveLoadHandler,
    ["gui::DCGameMenu"]          = PauseMenuHandler,
    ["gui::DCNewGameSettings"]   = DifficultyHandler,
    ["gui::VMPreset"]            = DifficultyHandler,
    ["gui::DCModBrowser"]        = ModManagerHandler,
    ["gui::DCMainMenu"]          = MainMenuHandler,
    ["gui::DCDMSettings"]        = DifficultyHandler,
}

-- Widget name overrides: when a widget name matches, use this handler
-- instead of the DC type lookup.  Needed when multiple menus share a
-- DC type (e.g. shortcutsMenu and pause menu both use gui::DCGameMenu).
local WIDGET_NAME_HANDLERS = {
    ["shortcutsMenu"] = ShortcutsMenuHandler,
}

-- Default handler for unknown DC types (simple button menus).
local defaultHandler = MainMenuHandler

-- Currently active handler (set by widget events, used by snapshot routing).
local activeHandler = nil
-- Widget name that activated the current handler (for stale handler detection).
local activeHandlerWidgetName = nil

-- Set true when a dialog overlay just spoke on this tick.
-- Suppresses the active handler's snapshot processing so the dialog
-- speech isn't immediately interrupted by the underlying menu.
local dialogOverlayJustSpoke = false

-- ============================================================================
-- Routing
-- ============================================================================

--- ResolveHandler: look up the handler for a DC type string.
--- @param dcType string  The DataContext type from a widget or focused element.
--- @return table  The handler instance, or defaultHandler if not found.
local function ResolveHandler(dcType)
    if not dcType then return defaultHandler end
    return DC_TYPE_HANDLERS[dcType] or defaultHandler
end

--- IsDialogOverlay: returns true for DC types that are dialog/popup overlays
--- (e.g. confirmation dialogs).  These should speak their content but NOT
--- switch the active handler, since the underlying menu is still present.
local function IsDialogOverlay(dcType)
    if not dcType then return false end
    return dcType:find("MessageBox") ~= nil
end

--- HandleWidgetAdded: called by the Manager when a non-CC, non-cutscene
--- widget is added.  Updates the active handler and calls its hook.
--- @param widgetData table  The widget data from the snapshot.
local function HandleWidgetAdded(widgetData)
    if not widgetData or not widgetData.dcType then return end

    -- Dialog overlays (confirmation popups like MessageBox) should NOT
    -- switch the active handler.  Skip them entirely here; they are
    -- spoken by HandleDialogOverlay when the snapshot context confirms
    -- they are genuine modal dialogs (not pre-loaded widgets).
    if IsDialogOverlay(widgetData.dcType) then
        Log.Info("Skipping dialog overlay in handler routing: "
            .. widgetData.dcType)
        return
    end

    -- Check widget name overrides first (e.g. shortcutsMenu vs pause
    -- menu both share gui::DCGameMenu but need different handlers).
    local newHandler = nil
    local isExplicitMatch = false
    if widgetData.elemName and WIDGET_NAME_HANDLERS[widgetData.elemName] then
        newHandler = WIDGET_NAME_HANDLERS[widgetData.elemName]
        isExplicitMatch = true
    else
        newHandler = ResolveHandler(widgetData.dcType)
        isExplicitMatch = DC_TYPE_HANDLERS[widgetData.dcType] ~= nil
    end

    -- Don't let the default handler (MainMenu) overwrite a handler
    -- that was explicitly matched by widget name or DC type.
    -- The initial widget scan fires HandleWidgetAdded for every visible
    -- widget, and generic ls.Widget entries would clobber the real handler.
    -- Stale handler cleanup is handled in RouteSnapshot instead.
    if not isExplicitMatch and activeHandler
        and activeHandler ~= defaultHandler then
        return
    end

    if newHandler ~= activeHandler then
        -- Deactivating old handler: full reset so it's clean on return
        -- (hint re-speaks, controller input unsubscribes, etc.).
        if activeHandler then
            activeHandler.ResetState()
        end
        activeHandler = newHandler
        activeHandlerWidgetName = widgetData.elemName
        Log.Info("Active handler: " .. activeHandler.name
            .. " (dc=" .. widgetData.dcType .. ")")
    end

    activeHandler.HandleWidgetAdded(widgetData)
end

--- HandleDialogOverlay: called by EventRouter when a dialog overlay
--- widget appears.  Only speaks if the snapshot context indicates a
--- genuine modal dialog (not a pre-loaded widget).
---
--- Pre-loaded dialogs fire on the same tick as selectionChanged or
--- focusChanged (the user navigated to an item, and the game pre-loaded
--- the delete confirmation).  Real modal dialogs fire without focus/
--- selection changes (the user pressed X to delete, no navigation).
---
--- @param snapshot table  The full TickSnapshot from C++.
--- @param widgetData table  The widget data for the dialog overlay.
--- @return boolean  True if the dialog was spoken, false otherwise.
local function HandleDialogOverlay(snapshot, widgetData)
    -- Skip if focus or selection changed on this tick -- the dialog
    -- is pre-loaded alongside a navigation event, not user-triggered.
    if snapshot.focusChanged or snapshot.selectionChanged then
        Log.Debug("Skipping pre-loaded dialog overlay (focus/sel changed)")
        return false
    end

    local _, bodyText, actionsText = Helpers.ExtractFromWidgetData(widgetData)
    local titleText = nil
    if widgetData.dcProps then
        titleText = widgetData.dcProps.Title or widgetData.dcProps.TitleText
    end
    -- Also check namedTexts for the title (MessageBox uses NameScope).
    if not titleText and widgetData.namedTexts then
        for elementName, elementText in pairs(widgetData.namedTexts) do
            if elementName:lower():find("title")
                and not elementName:lower():find("titletext") then
                titleText = elementText
                break
            end
        end
    end
    -- Filter out unresolved LocaString parameter placeholders
    -- (e.g. "[1]") that the game didn't substitute.
    if bodyText and bodyText:match("^%[%d+%]$") then
        bodyText = nil
    end
    local parts = {}
    if titleText then table.insert(parts, titleText) end
    if bodyText then table.insert(parts, bodyText) end
    if actionsText then table.insert(parts, actionsText) end
    if #parts > 0 then
        local speech = Helpers.StripMarkupTags(table.concat(parts, ". "))
        Log.Info("DIALOG OVERLAY: " .. speech)
        Ext.Tolk.Speak(speech, true)
        -- Suppress the active Menus handler on this tick so the dialog
        -- isn't immediately interrupted by the underlying menu.
        dialogOverlayJustSpoke = true
        return true
    end
    return false
end

--- HandleWidgetRootChanged: called by the Manager when the widget root
--- changes.  Resets navigation state on the active handler.
local function HandleWidgetRootChanged()
    if activeHandler then
        activeHandler.ResetNavigation()
    end
end

--- RouteSnapshot: called by the Manager for all non-CC, non-cutscene,
--- non-radial snapshots.  Dispatches to the active handler.
--- @param snapshot table  The full TickSnapshot from C++.
local function RouteSnapshot(snapshot)
    -- Dialog overlay just spoke on this tick -- suppress the handler
    -- so it doesn't immediately interrupt the dialog speech.
    if dialogOverlayJustSpoke then
        dialogOverlayJustSpoke = false
        return
    end

    -- Clear stale widget-name-based handler: if the handler was activated
    -- by a specific widget (e.g. "shortcutsMenu") and that widget is no
    -- longer present in the snapshot, the menu closed -- reset.
    --
    -- ONLY check on widget rescan snapshots (no user interaction).
    -- During active navigation, focusChanged/selectionChanged are true
    -- and the handler must stay alive even without its widget in the
    -- snapshot metadata.
    if activeHandlerWidgetName and activeHandler
        and activeHandler ~= defaultHandler
        and not snapshot.focusChanged and not snapshot.selectionChanged
        and not snapshot.valueChanged then
        local widgetStillPresent = false
        if snapshot.visualTextWidgetName
            and snapshot.visualTextWidgetName == activeHandlerWidgetName then
            widgetStillPresent = true
        end
        if snapshot.widgetData
            and snapshot.widgetData.elemName == activeHandlerWidgetName then
            widgetStillPresent = true
        end
        if not widgetStillPresent then
            Log.Info("Clearing stale handler: " .. activeHandler.name
                .. " (widget " .. activeHandlerWidgetName .. " gone)")
            activeHandler.ResetState()
            activeHandler = nil
            activeHandlerWidgetName = nil
            -- No user interaction on this snapshot (focus/sel/val all
            -- false), and the menu just closed.  Return to avoid the
            -- fallback handler speaking HUD junk.
            return
        end
    end

    -- Route by visual text source widget name when the widget scan
    -- didn't trigger a separate widgetAdded event.  C++ tags visual
    -- texts with the source widget name so we can route correctly
    -- (e.g. "shortcutsMenu" shares gui::DCGameMenu with pause menu).
    if snapshot.visualTextWidgetName
        and WIDGET_NAME_HANDLERS[snapshot.visualTextWidgetName] then
        local newHandler = WIDGET_NAME_HANDLERS[snapshot.visualTextWidgetName]
        if newHandler ~= activeHandler then
            if activeHandler then activeHandler.ResetState() end
            activeHandler = newHandler
            activeHandlerWidgetName = snapshot.visualTextWidgetName
            Log.Info("Active handler: " .. activeHandler.name
                .. " (widget=" .. snapshot.visualTextWidgetName .. ")")
        end
    end

    -- If no handler is active yet (no widgetAdded event has fired),
    -- use the default handler (MainMenu -- simple button navigation).
    if not activeHandler then
        activeHandler = defaultHandler
        Log.Info("Active handler (default): " .. activeHandler.name)
    end

    activeHandler.HandleSnapshot(snapshot)
end

--- ResetAllHandlers: called by the Manager on GameStateChanged.
--- Resets all handler state and clears the active handler.
local function ResetAllHandlers()
    OptionsHandler.ResetState()
    MultiplayerHandler.ResetState()
    SaveLoadHandler.ResetState()
    PauseMenuHandler.ResetState()
    ShortcutsMenuHandler.ResetState()
    DifficultyHandler.ResetState()
    ModManagerHandler.ResetState()
    MainMenuHandler.ResetState()
    activeHandler = nil
    activeHandlerWidgetName = nil
end

--- GetActiveHandler: returns the currently active handler (for diagnostics).
--- @return table|nil  The active handler instance, or nil.
local function GetActiveHandler()
    return activeHandler
end

-- ============================================================================
-- Exports
-- ============================================================================

BG3Access.Client.Menus = {
    RouteSnapshot           = RouteSnapshot,
    HandleWidgetAdded       = HandleWidgetAdded,
    HandleDialogOverlay     = HandleDialogOverlay,
    HandleWidgetRootChanged = HandleWidgetRootChanged,
    IsDialogOverlay         = IsDialogOverlay,
    ResetAllHandlers        = ResetAllHandlers,
    GetActiveHandler        = GetActiveHandler,
    UnsubscribeControllerInput = UnsubscribeControllerInput,
}
