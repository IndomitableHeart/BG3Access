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
local Helpers    = BG3Access.Client.Helpers
local SpeechData = BG3Access.Client.SpeechData
local Cutscene   = BG3Access.Client.Cutscene

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
    local speechData = SpeechData.Create()
    speechData:Add("name", displayName, "brief")
    speechData:AddProperty("Action", functionality, "brief")
    local speech = speechData:Format()
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
        -- BG3Access settings menu owns input while open.
        local SettingsMenu = BG3Access.Client.SettingsMenu
        if SettingsMenu and SettingsMenu.IsOpen
            and SettingsMenu.IsOpen() then
            return
        end
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
        local SettingsMenu = BG3Access.Client.SettingsMenu
        if SettingsMenu and SettingsMenu.IsOpen
            and SettingsMenu.IsOpen() then
            return
        end
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
        currentTabContext        = nil,
        lastSpokenTitle      = nil,
        spokenRoles         = {},    -- map of field key -> spoken value (for value-aware tooltip cross-off)
        spokenValues         = {},    -- set of normalized values spoken (for carousel dedup)
        tabHintSpoken        = false,
        screenEntryJustSpoke = false,
        -- Screen-entry override SpeechData.  Handlers populate any
        -- core field on this (title / sectionLabel / description /
        -- status / count / etc.) from onWidgetAdded.  One mechanism
        -- replaces the older per-field bodyOverride pattern.
        screenEntryOverrides = SpeechData.Create(),
        -- Set by HandleWidgetAdded for the current tick.  HandleSnapshot
        -- consumes (and clears) this on the same tick so widget-derived
        -- title/body/namedTexts come from THIS handler's event, not a
        -- shared "best" event picked by the router.
        pendingWidgetEvent   = nil,
    }

    --- RecordSpokenFields: populate spokenRoles (role names) and
    --- spokenValues (normalized text) from a SpeechData object.
    --- Called after every speech event so the handler knows what it said.
    local function RecordSpokenFields(speechData)
        handlerState.spokenRoles = {}
        handlerState.spokenValues = {}
        -- Core fields (dict of fieldName -> fieldValue).
        -- Store actual values into spokenRoles for value-aware
        -- cross-off (per ShouldSkipSpoken in SpeechData.lua).
        if speechData.coreFields then
            for fieldName, fieldValue in pairs(speechData.coreFields) do
                handlerState.spokenRoles[fieldName] = fieldValue
                if fieldValue and fieldValue ~= "" then
                    handlerState.spokenValues[
                        Helpers.NormalizeForCompare(fieldValue)] = true
                end
            end
        end
        -- Properties (array of {label, value, tier}).  Key encodes
        -- value so multi-instance labels each have a unique slot.
        if speechData.properties then
            for _, prop in ipairs(speechData.properties) do
                handlerState.spokenRoles[
                    "property:" .. prop.label .. ":" .. prop.value] = true
                if prop.value and prop.value ~= "" then
                    handlerState.spokenValues[
                        Helpers.NormalizeForCompare(prop.value)] = true
                end
            end
        end
    end

    -- -----------------------------------------------------------------
    -- HandleSnapshot: generic menu processing pipeline.
    -- Handles classification, widget updates, carousel/value, screen
    -- entry, item navigation, and speech output.
    -- -----------------------------------------------------------------
    local function HandleSnapshot(snapshot)
        local focusedElement = snapshot.focusedElement
        if not focusedElement or not focusedElement.elemType then return end

        -- User-initiated: true when the snapshot was triggered by user
        -- input (d-pad, button, carousel switch, value toggle).
        local userInitiated = snapshot.focusChanged
            or snapshot.selectionChanged
            or snapshot.inlineCarouselChanged
            or snapshot.valueChanged

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

        -- pendingWidgetEvent: the widget event that activated this
        -- handler on this tick (set by HandleWidgetAdded).  Consume once
        -- below so widget-derived text doesn't leak into later ticks.
        local widgetEvent = handlerState.pendingWidgetEvent
        handlerState.pendingWidgetEvent = nil

        local isScreenEntry = false
        if snapshot.selectionChanged then
            isScreenEntry = true
        elseif widgetEvent and not handlerState.currentTabContext then
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
        if not isScreenEntry and not isItemNav and widgetEvent then
            local _, widgetBody, widgetActions = Helpers.ExtractFromWidgetData(
                widgetEvent)
            local updateText = widgetBody or widgetActions
            if updateText and updateText ~= ""
                and updateText ~= handlerState.lastSpokenFullText then
                local updateSpeech = SpeechData.Create()
                updateSpeech:Add("status", updateText, "brief")
                updateSpeech:Speak(handlerState, false, nil, userInitiated,
                    "SPEAK [update " .. config.name .. "]")
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
            -- Role-based dedup.  In selector menus (SaveLoad, Options
            -- tab carousels, etc.) the user d-pads to a new item.
            -- Both a focus snapshot AND a separate carousel snapshot
            -- fire from that one press.  The focus path's customItemFn
            -- already speaks the item's name (and any properties);
            -- the carousel value IS that same name, just from the
            -- selector's perspective.  If we spoke a "name" role on
            -- focus, the carousel's name role is redundant -- skip.
            --
            -- This is structural, not a fragile string match: same
            -- "name" role, same item, suppressed.  Handlers that don't
            -- emit "name" on focus (or that have no focus path at all
            -- because focus didn't change -- e.g. a hypothetical pure
            -- selector with sticky focus) still get a carousel speech.
            if handlerState.spokenRoles
                and handlerState.spokenRoles["name"] then
                return
            end
            local carouselValue = snapshot.inlineCarouselValue
            local carouselSpeech = SpeechData.Create()
            carouselSpeech:Add("name", carouselValue, "brief")
            carouselSpeech:Speak(handlerState, false, nil, userInitiated,
                "SPEAK [carousel " .. config.name .. "]")
            return
        end

        if isValueOnly then
            -- customItemFn handles value changes for expander toggles.
            if config.customItemFn then
                local customValue = config.customItemFn(
                    focusedElement, handlerState, snapshot)
                -- SpeechData object: speak directly (checkbox toggle, etc.).
                if type(customValue) == "table" and customValue.coreFields then
                    if next(customValue.coreFields)
                        or #customValue.properties > 0 then
                        RecordSpokenFields(customValue)
                        customValue:Speak(handlerState, false, nil,
                            userInitiated,
                            "SPEAK [custom-value " .. config.name .. "]")
                    end
                    return
                end
                if customValue and customValue ~= "" then
                    -- For value-only changes, speak just the state
                    -- portion (e.g., "expanded") not the full text
                    -- (e.g., "Tav, expanded") to avoid repeating the
                    -- name the user already heard on focus.
                    local stateOnly = customValue:match(", ([%a]+)$")
                    local toSpeak = stateOnly or customValue
                    if toSpeak ~= handlerState.lastSpokenFullText then
                        local valueSpeech = SpeechData.Create()
                        valueSpeech:Add("value", toSpeak, "brief")
                        valueSpeech:Speak(handlerState, false, nil,
                            userInitiated,
                            "SPEAK [value-state " .. config.name .. "]")
                    end
                    return
                end
            end
            local valueText = Helpers.FormatDCValue(focusedElement.dcProps)
            if valueText and valueText ~= ""
                and valueText ~= handlerState.lastSpokenFullText then
                local valueSpeech = SpeechData.Create()
                valueSpeech:Add("value", valueText, "brief")
                valueSpeech:Speak(handlerState, false, nil, userInitiated,
                    "SPEAK [value-dc " .. config.name .. "]")
            end
            return
        end

        -- =============================================================
        -- Screen entry or item navigation: build SpeechData, speak.
        -- =============================================================
        local speechData = SpeechData.Create()
        local tabName = nil
        local normalTab = ""
        local screenTitle = nil

        if isScreenEntry then
            -- Derive tab name.
            if focusedElement.isTab then
                tabName = Helpers.GetTranslatedStringIfHandle(
                    focusedElement.tabName)
            end
            normalTab = tabName and Helpers.NormalizeForCompare(tabName) or ""

            -- Dedup: skip if same tab.
            if tabName and tabName == handlerState.currentTabContext then
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
            handlerState.currentTabContext = tabName or ""
            handlerState.lastSpokenName = nil

            -- Gather data sources.
            local allNamedTexts = {}
            if focusedElement.namedTexts then
                for elementName, elementText in pairs(focusedElement.namedTexts) do
                    allNamedTexts[elementName] = elementText
                end
            end
            if widgetEvent and widgetEvent.namedTexts then
                for elementName, elementText in pairs(widgetEvent.namedTexts) do
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
                Helpers.ExtractFromWidgetData(widgetEvent)

            -- Read all screen-entry overrides up front.  Handlers
            -- populate these via handlerState.screenEntryOverrides
            -- (a SpeechData) from onWidgetAdded.  One mechanism
            -- replaces the older per-field bodyOverride pattern.
            local overrides = handlerState.screenEntryOverrides
            local overrideCoreFields = (overrides and overrides.coreFields)
                or {}

            -- Title.  Override takes priority.
            if overrideCoreFields["title"] then
                screenTitle = overrideCoreFields["title"]
            else
                screenTitle = nsTitle or widgetTitle
            end
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
                speechData:Add("title", screenTitle, "brief")
            end

            -- Hint (once per menu visit).
            if not handlerState.tabHintSpoken then
                handlerState.tabHintSpoken = true
                local menuHint
                if config.hintFn then
                    menuHint = config.hintFn(screenTitle, handlerState)
                else
                    menuHint = config.hint
                    if menuHint == nil then
                        menuHint = DEFAULT_HINT
                    end
                end
                if menuHint then
                    speechData:Add("navigationHint", menuHint, "normal")
                end
            end

            -- Section label.  Override takes priority.
            if overrideCoreFields["sectionLabel"] then
                speechData:Add("sectionLabel",
                    overrideCoreFields["sectionLabel"], "brief")
            elseif tabName then
                local showTabName = true
                -- Filter unresolved LocaString handles.
                if tabName:match("^h%x+g") then
                    showTabName = false
                end
                if showTabName and screenTitle
                    and Helpers.NormalizeForCompare(screenTitle):find(
                        normalTab, 1, true) then
                    showTabName = false
                end
                if showTabName then
                    speechData:Add("sectionLabel", tabName, "brief")
                end
            end

            -- Body.  Override takes priority over NameScope-extracted
            -- body parts (an explicit override is authoritative).
            local bodyAssembled = nil
            if overrideCoreFields["description"] then
                bodyAssembled = overrideCoreFields["description"]
            elseif nsBodyParts and #nsBodyParts > 0 then
                bodyAssembled = table.concat(nsBodyParts, ". ")
            elseif widgetBody then
                bodyAssembled = widgetBody
            end
            local statusText = Helpers.ExtractStatusText(
                focusedElement.dcProps)
            if statusText then
                bodyAssembled = bodyAssembled
                    and (bodyAssembled .. ". " .. statusText) or statusText
            end
            if bodyAssembled then
                speechData:Add("description", bodyAssembled, "normal")
            end
            if widgetActions then
                speechData:Add("instructionHint", widgetActions, "normal")
            end

            -- Apply any OTHER override core fields beyond title /
            -- sectionLabel / description, plus any properties.
            -- Free extensibility -- handlers can add any of the 15
            -- core fields without touching factory plumbing.
            if overrides then
                for fieldName, fieldValue in pairs(overrides.coreFields) do
                    if fieldName ~= "title"
                        and fieldName ~= "sectionLabel"
                        and fieldName ~= "description" then
                        speechData:Add(fieldName, fieldValue,
                            overrides.tiers[fieldName])
                    end
                end
                for _, prop in ipairs(overrides.properties) do
                    speechData:AddProperty(
                        prop.label, prop.value, prop.tier)
                end
                -- One-shot consume.
                handlerState.screenEntryOverrides = SpeechData.Create()
            end
        else
            -- Item navigation: dedup check.
            if elemId == handlerState.lastSpokenName
                and not hasCarousel then
                local text = Helpers.ExtractTextFromData(
                    focusedElement, handlerState.currentTabContext, false)
                if not text
                    or text == handlerState.lastSpokenFullText then
                    Log.Debug("DEDUP SKIP [" .. config.name .. "]: "
                        .. tostring(elemId))
                    return
                end
            end
        end

        -- ----- Item fields -----
        local itemName = nil
        local itemInfo = nil
        local itemValue = nil
        local itemDesc = nil

        -- customItemFn: handler-specific extraction before generic.
        -- Return nil to fall through, string to override item name,
        -- SpeechData for full control (speak + return early).
        local splitName, splitValue, splitDesc, splitValueDesc
        local customHandled = false
        local customSpeechData = nil
        if config.customItemFn then
            splitName = config.customItemFn(
                focusedElement, handlerState, snapshot)
            -- SpeechData object: speak directly and skip generic pipeline.
            if type(splitName) == "table" and splitName.coreFields then
                customSpeechData = splitName
                customHandled = true
            elseif splitName ~= nil then
                customHandled = true
                splitValue = nil
                splitDesc = nil
                splitValueDesc = nil
            end
        end

        -- If customItemFn returned a full SpeechData, use it directly.
        -- On screen entry, merge with screen entry fields (title/hint/body)
        -- so welcome text isn't lost.
        if customSpeechData then
            if not next(customSpeechData.coreFields)
                and #customSpeechData.properties == 0 then return end
            local screenEntryHasFields = next(speechData.coreFields)
                or #speechData.properties > 0
            if isScreenEntry and screenEntryHasFields then
                local merged = SpeechData.Create()
                -- Copy screen entry core fields.
                for fieldName, fieldValue in pairs(speechData.coreFields) do
                    merged:Add(fieldName, fieldValue,
                        speechData.tiers[fieldName])
                end
                for _, prop in ipairs(speechData.properties) do
                    merged:AddProperty(prop.label, prop.value, prop.tier)
                end
                -- Copy custom item core fields.
                for fieldName, fieldValue in pairs(
                    customSpeechData.coreFields) do
                    merged:Add(fieldName, fieldValue,
                        customSpeechData.tiers[fieldName])
                end
                for _, prop in ipairs(customSpeechData.properties) do
                    merged:AddProperty(prop.label, prop.value, prop.tier)
                end
                RecordSpokenFields(merged)
                merged:Speak(handlerState, isScreenEntry, nil,
                    userInitiated, "SPEAK [merged " .. config.name .. "]")
            else
                RecordSpokenFields(customSpeechData)
                customSpeechData:Speak(handlerState, isScreenEntry, nil,
                    userInitiated,
                    "SPEAK [custom " .. config.name .. "]")
            end
            -- Track which element we just spoke for.  The isCarouselOnly
            -- path uses this for identity-based dedup: when C++ raises
            -- BOTH a focus event AND an inline-carousel event for the
            -- same selection (e.g., save list -- ListBox SelectionChanged
            -- captures the highlighted item's name as a "carousel value"
            -- even when the consumer treats the widget as a rich list),
            -- we'd otherwise get a redundant carousel SPEAK after our
            -- custom speech.  Existing value-based dedup in the carousel
            -- path catches the case where the carousel value matches
            -- something in spokenValues, but custom handlers that
            -- transform values (e.g. SaveLoad stripping the auto-
            -- generated "<Level> - <PlayTime>" suffix from the title)
            -- miss that match.  Identity dedup catches it regardless of
            -- value transformation.
            handlerState.lastSpokenName = elemId
            return
        end

        if not customHandled then
            splitName, splitValue, splitDesc, splitValueDesc =
                Helpers.FormatDCTextSplit(focusedElement.dcProps,
                    focusedElement.dcType)
        end
        if not splitName or splitName == "" then
            splitName = Helpers.ExtractTextFromData(
                focusedElement, handlerState.currentTabContext, isScreenEntry)
            splitValue = nil
            splitDesc = nil
            splitValueDesc = nil
        end
        -- Filter unresolved LocaString handles from item names.
        if splitName and splitName:match("^h%x+g") then
            splitName = nil
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

        speechData:Add("name", itemName, "brief")
        if itemInfo then
            speechData:AddProperty("Info", itemInfo, "normal")
        end
        speechData:Add("value", itemValue, "brief")
        speechData:Add("description", itemDesc, "verbose")

        RecordSpokenFields(speechData)
        speechData:Speak(handlerState, isScreenEntry, nil, userInitiated,
            "SPEAK [generic " .. config.name .. "]")
    end

    -- -----------------------------------------------------------------
    -- HandleWidgetAdded: process widget added events.
    -- Called by the router when a widgetAdded event arrives for this
    -- handler's DC type.  Stashes the event on handlerState for
    -- HandleSnapshot to consume on the same tick.
    -- -----------------------------------------------------------------
    local function HandleWidgetAdded(widgetData)
        handlerState.pendingWidgetEvent = widgetData
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
        handlerState.currentTabContext = nil
        handlerState.lastSpokenTitle = nil
        handlerState.tabHintSpoken = false
        handlerState.screenEntryJustSpoke = false
        handlerState.screenEntryOverrides = SpeechData.Create()
        handlerState.pendingWidgetEvent = nil
        if config.onReset then
            config.onReset(handlerState)
        end
    end

    --- ResetNavigation: partial reset for widget root change within
    --- the same handler (e.g., switching tabs in Options).
    --- Preserves tabHintSpoken so the hint doesn't re-speak.
    ---
    --- Does NOT clear screenEntryOverrides OR screenEntryJustSpoke
    --- -- both are forward-looking state set during screen entry
    --- that the very next snapshot (item-nav or new screen entry)
    --- needs to consume.  ResetNavigation runs between screen entry
    --- and first focus when the new widget root is detected --
    --- clearing either would wipe state set milliseconds earlier
    --- and defeat the design.  HandleSnapshot owns the one-shot
    --- consumption of both.
    local function ResetNavigation()
        handlerState.currentTabContext = nil
        handlerState.lastSpokenTitle = nil
        handlerState.lastSpokenName = nil
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
        --- HandleTooltip: receive structured tooltip data ({role, text}
        --- array), build SpeechData from roles, skip fields the handler
        --- already spoke, then speak with inline dedup.
        HandleTooltip = function(structuredData, rawTexts)
            if not structuredData then return end
            -- FromTooltip's value-aware spokenRoles cross-off
            -- handles dedup naturally: matching role+value entries
            -- get skipped, mismatched values get emitted.  If
            -- nothing changed, the result is empty -> Format
            -- returns nil -> Speak early-returns silently.  No
            -- string compare needed.  Menus don't use the
            -- state-change-interrupt pattern (no equivalent of
            -- the panel factory's Reactions toggle); always queue.
            local tooltipData = SpeechData.FromTooltip(
                structuredData, handlerState.spokenRoles)
            tooltipData:Speak(handlerState, false, nil, false,
                "MENU TOOLTIP")
        end,
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
            handlerState.screenEntryOverrides:Add(
                "description",
                "Interactive controller mode: While in this tab, "
                .. "press any button or trigger to hear its function. "
                .. "Press LB twice to return to the previous tab, or "
                .. "press RB twice to move to the next tab in the menu. "
                .. "Press B twice to exit to the main menu.",
                "normal")
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
    -- Navigation hint, contextualized by save vs load (the screen
    -- title is "Save Game" / "Load Game" and decides the verb).
    -- Spoken once per visit (factory dedup via tabHintSpoken).
    hintFn = function(screenTitle)
        local lowerTitle = (screenTitle or ""):lower()
        local isSave = lowerTitle:find("save") ~= nil
        local actionLine
        if isSave then
            actionLine = "A on a save slot to save into it,"
                .. " or A on an empty New Save slot to create"
                .. " a new save."
        else
            actionLine = "A on a save to load it."
        end
        return "Up and down to browse campaigns."
            .. " A on a campaign to expand or collapse its list"
            .. " of saves. When expanded, up and down to browse"
            .. " individual saves. " .. actionLine
            .. " X to delete the selected campaign."
            .. " B to go back."
    end,
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
    customItemFn = function(focusedElement, handlerState, snapshot)
        -- Append expanded/collapsed state for campaign expanders.
        local elemId = focusedElement.elemId or ""
        if elemId:find("ExpanderButton") then
            -- Read rendered text from the focused element's visual
            -- tree (gives "Tav", not "DockPanel" from the elemId).
            local headerName = nil
            local readOk, headerTexts = pcall(
                Ext.UI.ReadFocusedTextBlocks)
            if readOk and headerTexts and #headerTexts > 0 then
                headerName = Helpers.StripMarkupTags(headerTexts[1])
            end
            if not headerName or headerName == "" then
                headerName = Helpers.FormatDCText(
                    focusedElement.dcProps, focusedElement.dcType)
            end
            if not headerName or headerName == "" then
                headerName = "Campaign"
            end
            local isChecked = focusedElement.isChecked
            if isChecked == true then
                headerName = headerName .. ", expanded"
            elseif isChecked == false then
                headerName = headerName .. ", collapsed"
            end
            return headerName
        end

        -- "New save" entry at the top of the Save Game save list.
        -- Per SaveGame_c.xaml line 176, it's a plain ContentControl
        -- with Tag="NewSave" wrapping a TextBlock whose text is a
        -- TranslatedStringConverter binding -- GetProperty("Text")
        -- returns nil for bound values (BG3SE Lua bridge contract),
        -- so the factory's generic extraction produces nothing and
        -- the item stays silent.  Read the rendered TextBlock text
        -- directly (same trick as the ExpanderButton header above).
        --
        -- Detection: elemType is "ContentControl" (the per-save
        -- ListBoxItems use VMSavegame as dcType -- different code
        -- path), AND dcType doesn't contain "VMSavegame" (defensive,
        -- in case a future Larian change reuses ContentControl for
        -- save items).  ContentControl inherits dcType from its
        -- parent (gui::DCSavegames) so we can't gate on
        -- "no dcType" -- inheritance always populates it.
        if focusedElement.elemType == "ContentControl"
            and not (focusedElement.dcType
                and focusedElement.dcType:find("VMSavegame")) then
            local readOk, focusedTexts = pcall(
                Ext.UI.ReadFocusedTextBlocks)
            if readOk and focusedTexts and #focusedTexts > 0 then
                local cleanText = Helpers.StripMarkupTags(
                    focusedTexts[1])
                if cleanText and cleanText ~= ""
                    and not cleanText:match("^h%x+g") then
                    return cleanText
                end
            end
        end

        -- Save list item.  The focused list item's DataContext is a
        -- VMSavegame (per SaveLoad_c.xaml, list-item ItemTemplate
        -- binds to ls:VMSavegame).  Right-panel detail text (play
        -- time, level name, timestamp) lives on these VM properties
        -- but ISN'T part of the list-item's own visible TextBlock --
        -- the generic pipeline only catches the save's Title.  Read
        -- the missing fields off dcProps and assemble a speech that
        -- mirrors what a sighted player sees on the right panel.
        --
        -- Property names verified against
        -- D:\extracted packs\Public\Game\GUI\Library\SaveLoad_c.xaml
        -- (SaveDetailsTemplate, lines 472-476; right-panel PlayTime
        -- binding line 503).
        local dcType = focusedElement.dcType or ""
        local dcProps = focusedElement.dcProps
        if dcProps and dcType:find("VMSavegame") then
            local speechData = SpeechData.Create()
            -- Title (save name): strip the auto-generated playtime
            -- suffix when present so every save announces the same way:
            --   "<Name>. Play time: X. Saved: Y. Difficulty: Z. ..."
            -- Without the strip, auto-named saves sound different from
            -- user-named saves (one says "Ravaged Beach - 4h 45m" with
            -- playtime baked in, the other says "CombatTest" with
            -- playtime announced separately).  Consistency wins.
            local title = dcProps.Title
            local playTime = dcProps.PlayTimeString
            if title and playTime and playTime ~= "" then
                local suffix = " - " .. playTime
                if #title > #suffix
                    and title:sub(-#suffix) == suffix then
                    title = title:sub(1, -#suffix - 1)
                end
            end
            if title and title ~= "" then
                speechData:Add("name", title, "brief")
            end
            if playTime and playTime ~= "" then
                speechData:AddProperty("Play time", playTime, "brief")
            end
            -- TimeString (date/time stamp like "25/4/2026 18:47")
            -- -- useful for "which save is most recent" without
            -- having to compare names.
            local timeString = dcProps.TimeString
            if timeString and timeString ~= "" then
                speechData:AddProperty("Saved", timeString, "normal")
            end
            -- Difficulty + Honour mode.  Difficulty is the displayed
            -- string ("Balanced", "Tactician", etc.); IsHonourMode
            -- overrides the label per the XAML DataTrigger at lines
            -- 521-524.
            local isHonour = dcProps.IsHonourMode
            local difficulty = dcProps.Difficulty
            if isHonour == true or isHonour == "true" then
                speechData:AddProperty("Difficulty",
                    "Honour mode", "brief")
            elseif difficulty and difficulty ~= "" then
                speechData:AddProperty("Difficulty",
                    difficulty, "brief")
            end
            -- LevelName.Str (e.g., "Wilderness").  Sub-object access:
            -- dcProps.LevelName might be a table { Str = "..." } or
            -- a direct string depending on how the bridge marshals it.
            local levelName = nil
            if type(dcProps.LevelName) == "table" then
                levelName = dcProps.LevelName.Str
            elseif type(dcProps.LevelName) == "string" then
                levelName = dcProps.LevelName
            end
            if levelName and levelName ~= "" then
                speechData:AddProperty("Region", levelName, "normal")
            end
            -- Return the SpeechData object so the framework speaks it
            -- (and handles screen-entry merging if applicable).  Per
            -- the customItemFn return convention at line 489-490:
            -- nil = fall through, string = override name only, table
            -- with .coreFields = full SpeechData, framework speaks.
            return speechData
        end

        return nil
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
        handlerState.currentTabContext = nil
    end,
})

local ModManagerHandler = CreateMenuHandler({
    name = "ModManager",
    hint = "Use bumpers to switch tabs. Use up and down to cycle through items",
    customItemFn = function(focusedElement, handlerState, snapshot)
        -- Announce checkbox role and checked/unchecked state.
        if focusedElement.elemType
            and focusedElement.elemType:find("CheckBox") then
            local checkedText = nil
            if focusedElement.isChecked == true then
                checkedText = "checked"
            elseif focusedElement.isChecked == false then
                checkedText = "unchecked"
            end

            -- Value-only (A press toggle): speak just the state.
            if snapshot.valueChanged and not snapshot.focusChanged then
                local speechData = SpeechData.Create()
                if checkedText then
                    speechData:Add("value", checkedText, "brief")
                end
                return speechData
            end

            -- Focus arrival: speak name + role + state.
            local speechData = SpeechData.Create()
            local checkboxName = Helpers.ExtractTextFromData(
                focusedElement, nil, false)
            if checkboxName and checkboxName ~= "" then
                speechData:Add("name", checkboxName, "brief")
            end
            speechData:Add("controlType", "checkbox", "brief")
            if checkedText then
                speechData:Add("value", checkedText, "brief")
            end
            return speechData
        end
        return nil
    end,
})

local MainMenuHandler = CreateMenuHandler({
    name = "MainMenu",
    hint = false,
})

-- ============================================================================
-- Handler registration
-- ============================================================================
--
-- Each menu / screen registers ONCE here with one openWhen criterion
-- table.  The criterion has up to three OPTIONAL signal sources that
-- the dispatcher checks:
--
--   widgetNames - set of UIWidget x:Names that identify "my widget."
--                 The most stable signal: x:Names don't change during a
--                 session and only leave the visible widgetNames array
--                 when the widget actually unloads (Loaded/Unloaded
--                 events).  Use this when the widget has a known x:Name.
--
--   dcTypes     - set of DC type strings that count as "my content."
--                 Matched against widgetDCTypes (outer widget DCs) AND
--                 against focusedElement.dcType (per-item ViewModels).
--                 Use this when (a) the widget has no x:Name in its
--                 XAML (KeybindingOptions is the example) and (b) for
--                 per-item VMs that only ever appear on focused elements
--                 (ls.VMSavegame on a save row, gui::VMPreset on a
--                 difficulty preset card).
--
--   isOpen      - function(snapshot) returning bool.  For permanent
--                 overlays where "loaded != open" needs custom logic
--                 (Notification_c with Type != "None", etc.).
--
-- The handler is open if ANY non-empty source returns true.  Sources
-- are independent -- not a fallback ladder.  Each handler picks
-- whichever sources are stable for its case; PauseMenu uses
-- widgetNames only (because its DC collides with shortcutsMenu),
-- KeybindingOptions needs dcTypes (because no x:Name), Notifications
-- will use isOpen (because the widget is permanent).
--
-- Adding a new menu: one entry here, fill in the signal sources that
-- are stable for its case.  No edits to dispatcher logic.
local registeredHandlers = {
    {
        name    = "Options",
        handler = OptionsHandler,
        openWhen = {
            -- Six of seven Options sub-screens (GameOptions, Audio,
            -- Video, Controller, Interface, Accessibility) all have
            -- x:Name="Options_c" in their XAML.  Different widgets,
            -- shared name, all map to OptionsHandler -- fine.
            widgetNames = { ["Options_c"] = true },
            -- KeybindingOptions_c.xaml has NO x:Name on its UIWidget
            -- root, so widgetNames matching can't catch it.  dcTypes
            -- is the only signal for that one screen, plus catches
            -- DC swaps on the named widgets.
            dcTypes = {
                ["gui::DCOptions"]           = true,
                ["gui::DCOptionsBase"]       = true,
                ["gui::DCControllerOptions"] = true,
                ["gui::DCInterfaceOptions"]  = true,
            },
        },
    },
    {
        name    = "Multiplayer",
        handler = MultiplayerHandler,
        openWhen = {
            widgetNames = {
                ["LobbyBrowser_c"]    = true,
                ["CharacterAssign_c"] = true,
            },
            dcTypes = {
                ["gui::DCLobbyBrowser"]    = true,
                ["gui::DCCharacterAssign"] = true,
            },
        },
    },
    {
        name    = "SaveLoad",
        handler = SaveLoadHandler,
        openWhen = {
            -- Outer UIWidget x:Names: stable across DC rebinds.  The
            -- widget DC can swap to the active campaign / save's VM
            -- mid-navigation, dropping gui::DCSavegames from the cache;
            -- the x:Name stays put.  Both names so one handler covers
            -- Save Game and Load Game.
            widgetNames = {
                ["LoadGame_c"] = true,
                ["SaveGame_c"] = true,
            },
            dcTypes = {
                ["gui::DCSavegames"]       = true,
                -- Per-save and campaign-expander VMs.  Only appear as
                -- focused element DCs while navigating inside the
                -- list -- never as widget DCs.
                ["ls.VMSavegame"]          = true,
                ["ls.VMPlaythroughHolder"] = true,
            },
        },
    },
    {
        name    = "ShortcutsMenu",
        handler = ShortcutsMenuHandler,
        openWhen = {
            -- INTENTIONALLY widgetNames-only.  shortcutsMenu shares
            -- gui::DCGameMenu with PauseMenu; if we matched on dcTypes
            -- the two handlers would mask each other's close detection.
            widgetNames = { ["shortcutsMenu"] = true },
        },
    },
    {
        -- PauseMenu comes AFTER ShortcutsMenu in this list because
        -- both have gui::DCGameMenu and the dispatcher's pickup pass
        -- iterates in registration order.  When both widgets are
        -- visible (RT held during pause menu), ShortcutsMenu wins as
        -- the topmost interaction surface.
        name    = "PauseMenu",
        handler = PauseMenuHandler,
        openWhen = {
            -- Same rationale as ShortcutsMenu: shared DC type, name-
            -- only.  Closing one does not keep the other alive.
            widgetNames = { ["GameMenu_c"] = true },
        },
    },
    {
        name    = "Difficulty",
        handler = DifficultyHandler,
        openWhen = {
            -- Outer UIWidget x:Name from NewGameSettings_c.xaml.
            -- DataContext rebinds to gui::VMPreset on selection
            -- change, so the widget DC string isn't stable.
            widgetNames = { ["DMSettings"] = true },
            dcTypes = {
                ["gui::DCDMSettings"]      = true,
                ["gui::DCNewGameSettings"] = true,
                -- Per-preset VM, only appears as focused element DC.
                ["gui::VMPreset"]          = true,
            },
        },
    },
    {
        name    = "ModManager",
        handler = ModManagerHandler,
        openWhen = {
            -- TODO: confirm widget x:Name when the file is located.
            dcTypes = { ["gui::DCModBrowser"] = true },
        },
    },
    {
        name    = "MainMenu",
        handler = MainMenuHandler,
        openWhen = {
            widgetNames = { ["MainMenu_c"] = true },
            dcTypes     = { ["gui::DCMainMenu"] = true },
        },
    },
}

-- ============================================================================
-- Dispatcher
-- ============================================================================
--
-- Routing logic lives in Client/Dispatcher.lua.  Menus.lua provides the
-- registration list (above) and a small amount of Menus-specific glue:
--   - Skip the next snapshot when a dialog overlay just spoke (so the
--     underlying menu doesn't immediately interrupt the dialog speech).
--   - Suspend GPS when a menu activates (Nav.SuspendForMenu).
--   - Filter MessageBox dialog overlays out of HandleWidgetAdded so they
--     don't switch the active handler -- they're handled separately by
--     HandleDialogOverlay below.

local Dispatcher = BG3Access.Client.Dispatcher
local dialogOverlayJustSpoke = false

local menusDispatcher = Dispatcher.Create({
    name = "Menus",
    handlers = registeredHandlers,
    onActivate = function(entry)
        -- Suspend GPS for the duration of the menu.  Fires only on
        -- real handler transitions, so widget rebuilds (which keep
        -- the same registration entry active) don't re-suspend.
        local Nav = BG3Access.Client.WorldNav
        if Nav and Nav.SuspendForMenu then
            Nav.SuspendForMenu()
        end
    end,
    skipWhen = function(snapshot)
        -- One-tick suppression after a dialog overlay spoke.  Consume
        -- the flag here -- the next call resumes normal dispatch.
        if snapshot ~= nil and dialogOverlayJustSpoke then
            dialogOverlayJustSpoke = false
            return true
        end
        return false
    end,
})

--- IsDialogOverlay: returns true for DC types that are dialog/popup
--- overlays (e.g. confirmation MessageBox).  These speak their content
--- on arrival but do NOT switch the active handler -- the underlying
--- menu is still up and owns input.
local function IsDialogOverlay(dcType)
    if not dcType then return false end
    return dcType:find("MessageBox") ~= nil
end

--- IsMenuDCType: thin wrapper exposing the dispatcher's check for use
--- by EventRouter when deciding whether to flip routing from WorldUI
--- back to Menus.  Generic / unhandled DC types return false.
local function IsMenuDCType(dcType)
    return menusDispatcher:IsRegisteredDCType(dcType)
end

--- IsMenuWidgetName: returns true if any registered handler claims
--- this widget x:Name in its openWhen.widgetNames set.  Companion to
--- IsMenuDCType for handlers that identify by name-only (PauseMenu,
--- ShortcutsMenu -- both share gui::DCGameMenu so DC alone can't
--- distinguish them; widget name is the canonical signal).
--- EventRouter consults this to route widget events whose DC isn't
--- in any handler's dcTypes set but whose x:Name IS registered.
local function IsMenuWidgetName(widgetName)
    if not widgetName or widgetName == "" then return false end
    for _, entry in ipairs(registeredHandlers) do
        local criterion = entry.openWhen
        if criterion and criterion.widgetNames
            and criterion.widgetNames[widgetName] then
            return true
        end
    end
    return false
end

--- HandleWidgetAdded: forwards widget events to the dispatcher AFTER
--- filtering out MessageBox dialog overlays.  Dialog overlays speak
--- via HandleDialogOverlay (below) and must not switch the active
--- handler since the underlying menu is still up.
local function HandleWidgetAdded(widgetData)
    if not widgetData or not widgetData.dcType then return end
    if IsDialogOverlay(widgetData.dcType) then
        Log.Info("Skipping dialog overlay in handler routing: "
            .. widgetData.dcType)
        return
    end
    menusDispatcher:HandleWidgetAdded(widgetData)
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
    -- Save/Load pre-load suppression: navigating between save ROWS
    -- (VMSavegame entries inside an expanded campaign) causes the
    -- game to pre-load the delete-confirmation MessageBox even
    -- though the user didn't press anything.  Suppress dialogs
    -- that co-occur with save-row focus changes specifically.
    --
    -- VMPlaythroughHolder (campaign header) was previously in this
    -- list, but pressing X on a campaign header is an INTENTIONAL
    -- action that opens the "Delete all but latest" confirmation,
    -- and X-press triggers a focusChanged on the same tick (widget
    -- rebuild repositions focus).  Including VMPlaythroughHolder
    -- caused the legitimate confirm dialog to be silently dropped.
    -- Save-row pre-load is the only documented misfire; restrict
    -- the suppression to that single case.
    if snapshot.focusChanged or snapshot.selectionChanged then
        local focusedDCType = snapshot.focusedElement
            and snapshot.focusedElement.dcType or ""
        if focusedDCType:find("VMSavegame") then
            Log.Debug("Skipping pre-loaded dialog overlay"
                .. " (save-row navigation: " .. focusedDCType .. ")")
            return false
        end
    end

    local _, bodyText, actionsText = Helpers.ExtractFromWidgetData(widgetData)
    -- Early placeholder filter: Helpers.ExtractFromWidgetData can
    -- return unresolved LocaString parameter tokens like "[1]" or
    -- "[ForceUpdate]" when the game hasn't substituted the binding.
    -- Nil those out BEFORE the namedTexts fallback runs, otherwise
    -- the fallback (which is gated on `not bodyText`) is skipped
    -- and we end up with no body AND no diagnostic.
    if bodyText then
        local trimmed = bodyText:match("^%s*(.-)%s*$") or bodyText
        if trimmed == "" or trimmed:match("^%[%d+%]$")
            or trimmed:find("%[ForceUpdate%]") then
            bodyText = nil
        end
    end
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
    -- Body namedTexts fallback (mirrors the title fallback above).
    -- Helpers.ExtractFromWidgetData probes dcProps for common body
    -- field names (Text, Description, Message, etc.) and bindings
    -- by path -- but Larian's MessageBox template puts the body in
    -- an x:Named TextBlock under the widget's NameScope, where it
    -- shows up in namedTexts.  Match common message-body x:Name
    -- patterns; skip anything that looks title-ish or actions-ish.
    if not bodyText and widgetData.namedTexts then
        for elementName, elementText in pairs(widgetData.namedTexts) do
            local lower = elementName:lower()
            local looksLikeBody = lower:find("message")
                or lower:find("body")
                or lower:find("description")
                or lower:find("content")
                or lower == "text"
            local looksLikeOther = lower:find("title")
                or lower:find("button")
                or lower:find("action")
                or lower:find("hint")
            if looksLikeBody and not looksLikeOther
                and elementText and elementText ~= "" then
                local candidate = elementText:match("^%s*(.-)%s*$")
                    or elementText
                if candidate ~= "" and not candidate:match("^%[%d+%]$")
                    and not candidate:find("%[ForceUpdate%]")
                    and candidate ~= titleText then
                    bodyText = elementText
                    break
                end
            end
        end
    end
    -- Live-element fallback: some dialog templates name the body
    -- TextBlock "Message" and bind it through a Larian formatter,
    -- so the C++ namedTexts collector misses it but a fresh read
    -- at call time picks it up.  Empirically this does NOT work
    -- for the standard LSMessageBox / MessageBoxTemplate path --
    -- FindNameInWidget("Message") returns nil there because the
    -- TextBlock lives inside the ControlTemplate's NameScope,
    -- which isn't exposed to the widget's outer NameScope.  Kept
    -- as a cheap try anyway in case a non-templated dialog uses
    -- the same x:Name.  No logging -- silent failure is expected.
    if not bodyText and widgetData.dcType
        and widgetData.dcType:find("MessageBox") then
        local findOk, messageElement = pcall(
            Ext.UI.FindNameInWidget, "Message")
        if findOk and messageElement then
            local readOk, entries = pcall(
                Ext.UI.ReadElementStructuredTextBlocks, messageElement)
            if readOk and entries then
                for _, entry in ipairs(entries) do
                    local text = entry.text
                    if text and text ~= "" then
                        local trimmed = text:match("^%s*(.-)%s*$") or text
                        if trimmed ~= "" and not trimmed:match("^%[%d+%]$")
                            and not trimmed:find("%[ForceUpdate%]")
                            and trimmed ~= titleText then
                            bodyText = text
                            break
                        end
                    end
                end
            end
        end
    end
    -- Log when body extraction fell short.  Single line at Debug
    -- because the limitation is understood (see NOTE below) -- this
    -- is just a marker for future investigation if a new template
    -- shows up that's NOT the LSMessageBox formatter case.
    if not bodyText then
        Log.Debug("DIALOG OVERLAY no body extracted"
            .. " (dcType=" .. tostring(widgetData.dcType) .. ")")
    end
    -- Helper: assemble title/body/actions into a SpeechData and emit
    -- via SpeechData.Alert (interrupt priority).  Shared between the
    -- immediate path and the deferred-body path so speech ordering
    -- and field-routing rules stay in one place.
    --
    -- bodyArg uses "sectionLabel" (not "description") deliberately:
    -- "description" routes through the speakDescription toggle (the
    -- one core field in CORE_FIELD_TOGGLE_SETTINGS), which would
    -- silence the body when the user picks the Normal verbosity
    -- preset.  sectionLabel is unconditionally emitted by Format()
    -- regardless of tier or toggle, and is the right semantic slot
    -- for "subtitle / state info under title" -- which is exactly
    -- what a confirmation-dialog body is to its title.  For
    -- title-less dialogs (just a prompt), it speaks as the sole
    -- content slot before the instructionHint with the buttons.
    local function emitDialogSpeech(
        titleArg, bodyArg, actionsArg, logTag)
        local dialogSpeech = SpeechData.Create()
        if titleArg then
            dialogSpeech:Add("title", titleArg, "brief")
        end
        if bodyArg then
            dialogSpeech:Add("sectionLabel", bodyArg, "brief")
        end
        if actionsArg then
            dialogSpeech:Add("instructionHint", actionsArg, "normal")
        end
        local speech = dialogSpeech:Format()
        if not speech or speech == "" then return false end
        Log.Info("DIALOG OVERLAY" .. logTag .. ": " .. speech)
        SpeechData.Alert(speech, "interrupt")
        return true
    end

    -- NOTE: when widgetData.dcProps.TextProperty comes back as a
    -- raw formatter placeholder ("[1]" etc.) and FindNameInWidget
    -- ("Message") returns nil, we currently fall through and speak
    -- title + actions without the body.  Confirmed cases: the
    -- save-load "Delete all but the latest save" prompt, where the
    -- body interpolates campaign name and autosave name.  A 30-frame
    -- deferred RunAfterFrames retry was tried -- the body still
    -- doesn't appear via FindNameInWidget at any tested delay, and
    -- the deferred read introduces a noticeable delay before any
    -- speech.  Likely root cause: the body TextBlock lives inside
    -- the LSMessageBox ControlTemplate's NameScope, which is NOT
    -- exposed in the widget's outer NameScope that FindNameInWidget
    -- walks.  A proper fix needs either (a) C++ exposure of a
    -- "walk the widget Visual subtree and gather all rendered
    -- TextBlocks" primitive that descends through template
    -- boundaries, or (b) a way to read the formatter's resolved
    -- arg list off the LSMessageBoxData DC.  Title + actions are
    -- enough to indicate WHAT action the user is confirming,
    -- which is the critical accessibility need; the specific
    -- campaign/save names are nice-to-have.
    local parts = {}
    if titleText then table.insert(parts, titleText) end
    if bodyText then table.insert(parts, bodyText) end
    if actionsText then table.insert(parts, actionsText) end
    if #parts > 0 then
        emitDialogSpeech(titleText, bodyText, actionsText, "")
        -- Suppress the active Menus handler on this tick so the
        -- dialog isn't immediately interrupted by the underlying menu.
        dialogOverlayJustSpoke = true
        return true
    end
    return false
end

--- HandleWidgetRootChanged: forwards to dispatcher.
local function HandleWidgetRootChanged()
    menusDispatcher:HandleWidgetRootChanged()
end

--- RouteSnapshot: forwards to dispatcher.
--- @param snapshot table  The full TickSnapshot from C++.
local function RouteSnapshot(snapshot)
    menusDispatcher:RouteSnapshot(snapshot)
end

--- CheckLiveness: run dispatcher's liveness check ONLY (no pickup,
--- no dispatch).  EventRouter calls this above the focusedElement
--- guard so handlers whose widget went away during a "no focus"
--- window (radial dismiss with no HUD target) still get deactivated.
local function CheckLiveness(snapshot)
    menusDispatcher:CheckLiveness(snapshot)
end

--- ResetAllHandlers: forwards to dispatcher.
local function ResetAllHandlers()
    menusDispatcher:Reset()
end

--- GetActiveHandler: returns the currently active handler instance.
local function GetActiveHandler()
    return menusDispatcher:GetActiveHandler()
end

--- GetActiveHandlerWidgetNames: returns the set of the active
--- handler's registered widget x:Names (table keyed by name with
--- value true), or nil.  Used by EventRouter for widget-removal
--- matching.  Set form supports any-match queries across multi-
--- widget-name handlers (e.g. SaveLoad covers LoadGame_c AND
--- SaveGame_c -- the previous single-name return picked one
--- arbitrarily and mis-fired liveness checks).
local function GetActiveHandlerWidgetNames()
    return menusDispatcher:GetActiveHandlerWidgetNames()
end

--- DispatchTooltip: routes structured tooltip data to the active
--- menu handler if it exposes a HandleTooltip method.
local function DispatchTooltip(structuredTooltipData, snapshot)
    if not structuredTooltipData then return end
    local handler = menusDispatcher:GetActiveHandler()
    if handler and handler.HandleTooltip then
        handler.HandleTooltip(structuredTooltipData, structuredTooltipData)
    end
end

-- ============================================================================
-- Exports
-- ============================================================================

BG3Access.Client.Menus = {
    RouteSnapshot           = RouteSnapshot,
    CheckLiveness           = CheckLiveness,
    HandleWidgetAdded       = HandleWidgetAdded,
    HandleDialogOverlay     = HandleDialogOverlay,
    HandleWidgetRootChanged = HandleWidgetRootChanged,
    IsDialogOverlay         = IsDialogOverlay,
    IsMenuDCType            = IsMenuDCType,
    IsMenuWidgetName        = IsMenuWidgetName,
    ResetAllHandlers        = ResetAllHandlers,
    GetActiveHandler        = GetActiveHandler,
    GetActiveHandlerWidgetNames = GetActiveHandlerWidgetNames,
    UnsubscribeControllerInput = UnsubscribeControllerInput,
    DispatchTooltip         = DispatchTooltip,
}
