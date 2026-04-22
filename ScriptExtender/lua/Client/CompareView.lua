-- File: Client/CompareView.lua
--
-- Compare view (RS Right virtual grid).  When the game renders a
-- two-card compare tooltip (focused item + currently-equipped
-- counterpart), the user can press RS Right to open a navigable
-- grid: columns = items, rows = shared stat labels.
--
-- D-pad:
--   up/down   = previous/next row (wraps)
--   left/right = previous/next column (clamps between 2 cards)
-- B closes the view.
--
-- Module-level state: one compare view open at a time across all
-- contexts.  Compare data comes from handler-side tooltip processing
-- (HandleTooltip in WorldUI.lua reads HoveredItemPanel and
-- EquippedItemPanel via primitives and stashes SpeechData on the
-- handler state).

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

local Log        = BG3Access.Client.Log
local SpeechData = BG3Access.Client.SpeechData

-- ============================================================================
-- State
-- ============================================================================

local compareOpen               = false
local compareGrid               = nil  -- { rows = {{label, values={...}}, ...}, columnNames = {...} }
local compareRow                = 1    -- 1-based
local compareColumn             = 1    -- 1-based (1 = focused, 2 = compare)
local compareButtonSubscription = nil

-- Navigation hint: speak on first open per session, then suppress.
-- Reset on ResetHint() (module export) when ResetState fires.
local compareHintSpoken = false

-- ============================================================================
-- Grid building
-- ============================================================================

-- Canonical label priority for grid rows.  Matches the spirit of
-- SpeechData.PROPERTY_ORDER but compressed for compare-relevant facts.
-- Labels not in this table fall to the end in insertion order.
local ROW_PRIORITY = {
    ["Name"]              = 1,
    ["Equipped by"]       = 5,
    ["Category"]          = 10,
    ["Armour Class"]      = 20,
    ["Amount"]             = 25,
    ["Damage"]            = 30,
    ["Damage type"]       = 35,
    ["Range"]             = 40,
    ["Weapon properties"] = 50,
    ["Property"]          = 55,
    ["Weight"]            = 100,
    ["Gold"]              = 105,
}

--- BuildGrid: assemble a 2-column grid from two SpeechData objects.
--- Column 1 = focused item, column 2 = compare item.
--- Rows include Name (from coreFields.name) plus all property labels
--- present in either side.  Missing cells are nil (spoken as "not
--- applicable").
--- @param focusedSpeech table  SpeechData for the focused item card.
--- @param compareSpeech table  SpeechData for the compare item card.
--- @return table  { rows = {{label, values={focused, compare}}, ...},
---                 columnNames = {"Acolyte's Sandals", "Tasteful Boots"} }
local function BuildGrid(focusedSpeech, compareSpeech)
    local grid = {
        rows = {},
        columnNames = {
            focusedSpeech.coreFields.name or "Focused item",
            compareSpeech.coreFields.name or "Compared item",
        },
    }

    -- Row 0: Name row, always present.
    grid.rows[#grid.rows + 1] = {
        label = "Name",
        values = {
            focusedSpeech.coreFields.name,
            compareSpeech.coreFields.name,
        },
    }

    -- Collect property labels from both sides, preserving insertion
    -- order for labels not in ROW_PRIORITY.
    local focusedByLabel = {}
    local compareByLabel = {}
    local insertionOrder = {}
    local seenLabels = {}

    for _, prop in ipairs(focusedSpeech.properties) do
        focusedByLabel[prop.label] = prop.value
        if not seenLabels[prop.label] then
            seenLabels[prop.label] = true
            insertionOrder[#insertionOrder + 1] = prop.label
        end
    end
    for _, prop in ipairs(compareSpeech.properties) do
        compareByLabel[prop.label] = prop.value
        if not seenLabels[prop.label] then
            seenLabels[prop.label] = true
            insertionOrder[#insertionOrder + 1] = prop.label
        end
    end

    -- Sort labels by ROW_PRIORITY, falling back to insertion order.
    table.sort(insertionOrder, function(labelA, labelB)
        local priorityA = ROW_PRIORITY[labelA] or math.huge
        local priorityB = ROW_PRIORITY[labelB] or math.huge
        if priorityA ~= priorityB then
            return priorityA < priorityB
        end
        -- Stable tiebreak: original insertion order.  Since insertionOrder
        -- was built in encounter order, falling back to the string's
        -- position in the original array preserves that order.
        return false
    end)

    for _, label in ipairs(insertionOrder) do
        grid.rows[#grid.rows + 1] = {
            label = label,
            values = {
                focusedByLabel[label],
                compareByLabel[label],
            },
        }
    end

    return grid
end

-- ============================================================================
-- Navigation
-- ============================================================================

--- Speak the current cell: "label: value" for the active row/column.
--- When column changes and the current row isn't the Name row, prefix
--- with the item name so the user keeps their bearings.  Skipped on
--- the Name row because the cell value IS the item name -- prepending
--- would produce "Tasteful Boots. Name: Tasteful Boots".
--- @param announceColumn boolean  If true, prefix with column item name.
local function SpeakCurrentCell(announceColumn)
    if not compareGrid or not compareGrid.rows[compareRow] then return end
    local row = compareGrid.rows[compareRow]
    local value = row.values[compareColumn]
    local speechData = SpeechData.Create()
    if announceColumn and row.label ~= "Name" then
        local columnName = compareGrid.columnNames[compareColumn]
        if columnName and columnName ~= "" then
            speechData:Add("title", columnName, "brief")
        end
    end
    speechData:Add("name", row.label, "brief")
    if value and value ~= "" then
        speechData:Add("value", value, "brief")
    else
        speechData:Add("value", "not applicable", "brief")
    end
    local speech = speechData:Format()
    if not speech then return end
    Log.Info("COMPARE [" .. compareRow .. "/" .. #compareGrid.rows
        .. ", col " .. compareColumn .. "]: " .. speech)
    Ext.Tolk.Speak(speech, true)
end

local function NextRow()
    if not compareGrid or #compareGrid.rows == 0 then return end
    compareRow = (compareRow % #compareGrid.rows) + 1
    SpeakCurrentCell(false)
end

local function PreviousRow()
    if not compareGrid or #compareGrid.rows == 0 then return end
    compareRow = ((compareRow - 2) % #compareGrid.rows) + 1
    SpeakCurrentCell(false)
end

local function NextColumn()
    if not compareGrid then return end
    if compareColumn >= 2 then return end  -- clamp at right edge
    compareColumn = compareColumn + 1
    SpeakCurrentCell(true)
end

local function PreviousColumn()
    if not compareGrid then return end
    if compareColumn <= 1 then return end  -- clamp at left edge
    compareColumn = compareColumn - 1
    SpeakCurrentCell(true)
end

-- ============================================================================
-- Open / Close
-- ============================================================================

--- Close the compare view and unsubscribe input.
--- @param silent boolean|nil  If true, skip the "closed" announcement.
local function CloseCompareView(silent)
    if not compareOpen then return end
    if compareButtonSubscription then
        Ext.Events.ControllerButtonInput:Unsubscribe(
            compareButtonSubscription)
        compareButtonSubscription = nil
    end
    compareOpen = false
    compareGrid = nil
    compareRow = 1
    compareColumn = 1
    if not silent then
        Log.Info("COMPARE VIEW: closed")
        SpeechData.Alert("Comparison closed", "interrupt")
    else
        Log.Info("COMPARE VIEW: closed (silent)")
    end
end

--- Open the compare view for two SpeechData objects.
--- @param focusedSpeech table  Focused item's SpeechData.
--- @param compareSpeech table  Compare item's SpeechData.
--- @return boolean  true if opened
local function Open(focusedSpeech, compareSpeech)
    if compareOpen then
        CloseCompareView()
        return true
    end
    if not focusedSpeech or not compareSpeech then
        return false
    end

    compareGrid = BuildGrid(focusedSpeech, compareSpeech)
    if not compareGrid or #compareGrid.rows == 0 then
        return false
    end

    compareOpen = true
    compareRow = 1
    compareColumn = 1

    -- Subscribe d-pad input for navigation.  D-pad up/down/left/right
    -- all intercepted while open; B closes; LB/RB blocked to prevent
    -- tab-switching underneath the open view.
    compareButtonSubscription =
        Ext.Events.ControllerButtonInput:Subscribe(function(event)
            if not event.Pressed then return end
            local buttonName = tostring(event.Button)
            if buttonName == "DPadDown" then
                event:PreventAction()
                NextRow()
            elseif buttonName == "DPadUp" then
                event:PreventAction()
                PreviousRow()
            elseif buttonName == "DPadRight" then
                event:PreventAction()
                NextColumn()
            elseif buttonName == "DPadLeft" then
                event:PreventAction()
                PreviousColumn()
            elseif buttonName == "LeftShoulder"
                or buttonName == "RightShoulder" then
                event:PreventAction()
            elseif buttonName == "B" then
                CloseCompareView(true)
            end
        end)

    Log.Info("COMPARE VIEW: opened " .. #compareGrid.rows
        .. " rows, columns: " .. compareGrid.columnNames[1]
        .. " vs " .. compareGrid.columnNames[2])
    -- First open per session includes the navigation hint.  Subsequent
    -- opens skip it -- just the title and the two item names, so user
    -- can dive straight into cells.
    local introText
    if not compareHintSpoken then
        introText = "Comparison view. "
            .. "D-pad left and right between items, up and down for details. "
            .. "B to close. "
            .. compareGrid.columnNames[1] .. " versus "
            .. compareGrid.columnNames[2]
        compareHintSpoken = true
    else
        introText = "Comparison view. "
            .. compareGrid.columnNames[1] .. " versus "
            .. compareGrid.columnNames[2]
    end
    SpeechData.Alert(introText, "interrupt")
    SpeakCurrentCell(false)
    return true
end

--- ResetHint: re-arm the one-time navigation hint.  Called from
--- WorldUI.ResetState on game-state transitions so a new session
--- hears the hint again.
local function ResetHint()
    compareHintSpoken = false
end

--- @return boolean  true if the compare view is currently open
local function IsOpen()
    return compareOpen
end

-- ============================================================================
-- Exports
-- ============================================================================

BG3Access.Client.CompareView = {
    Open       = Open,
    Close      = CloseCompareView,
    IsOpen     = IsOpen,
    ResetHint  = ResetHint,
    BuildGrid  = BuildGrid,  -- exposed for tests / custom callers
}
