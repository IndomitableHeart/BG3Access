-- File: Client/Logger.lua
--
-- Centralized logging for BG3Access.  All diagnostic output goes through
-- this module so verbosity can be toggled at runtime without touching
-- individual handlers.
--
-- Levels:
--   0 = off    -- no logging at all (production)
--   1 = info   -- speech events, key decisions (default)
--   2 = debug  -- full dcProps dumps, bindings, tree walks
--
-- Toggle: call BG3Access.Client.CycleLogLevel() or bind to a key combo.
-- The level persists for the session but resets to INFO on game state change.

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

local LOG_LEVEL_OFF   = 0
local LOG_LEVEL_INFO  = 1
local LOG_LEVEL_DEBUG = 2

local LOG_LEVEL_NAMES = { [0] = "OFF", [1] = "INFO", [2] = "DEBUG" }

local currentLevel = LOG_LEVEL_INFO

local AccessibilityLogger = {}

-- ---------------------------------------------------------------------------
-- Core logging functions.
-- ---------------------------------------------------------------------------

function AccessibilityLogger.Info(message)
    if currentLevel >= LOG_LEVEL_INFO then
        Ext.Utils.Print("[BG3Access] " .. message)
    end
end

function AccessibilityLogger.Debug(message)
    if currentLevel >= LOG_LEVEL_DEBUG then
        Ext.Utils.Print("[BG3Access] " .. message)
    end
end

-- Always prints regardless of level (errors, warnings).
function AccessibilityLogger.Warn(message)
    Ext.Utils.Print("[BG3Access] WARNING: " .. message)
end

function AccessibilityLogger.Error(message)
    Ext.Utils.Print("[BG3Access] ERROR: " .. message)
end

-- ---------------------------------------------------------------------------
-- Structured dump helpers.
-- These format complex data for diagnostic output at DEBUG level.
-- ---------------------------------------------------------------------------

-- Dump a dcProps table.  Used by HandleFocusChange, HandleWidgetChanged,
-- and HandleWidgetDCChanged -- previously copy-pasted in each.
function AccessibilityLogger.DumpDCProps(dcProps, indent)
    if currentLevel < LOG_LEVEL_DEBUG then return end
    if not dcProps then
        Ext.Utils.Print("[BG3Access] " .. (indent or "  ") .. "dcProps: nil")
        return
    end

    local prefix = indent or "  "
    local dcParts = {}
    for key, val in pairs(dcProps) do
        if type(val) == "table" then
            local subParts = {}
            for subKey, subVal in pairs(val) do
                local subStr = tostring(subVal)
                if #subStr > 40 then subStr = subStr:sub(1, 40) .. "..." end
                table.insert(subParts, subKey .. "=" .. subStr)
            end
            table.sort(subParts)
            table.insert(dcParts, key .. "={" .. table.concat(subParts, ", ") .. "}")
        else
            local valStr = tostring(val)
            if #valStr > 80 then valStr = valStr:sub(1, 80) .. "..." end
            table.insert(dcParts, key .. "=" .. valStr)
        end
    end
    table.sort(dcParts)
    Ext.Utils.Print("[BG3Access] " .. prefix .. "dcProps: "
        .. (#dcParts > 0 and table.concat(dcParts, " | ") or "(empty)"))
end

-- Dump binding metadata entries.
function AccessibilityLogger.DumpBindings(bindings, indent)
    if currentLevel < LOG_LEVEL_DEBUG then return end
    if not bindings or #bindings == 0 then return end

    local prefix = indent or "  "
    for _, bindingEntry in ipairs(bindings) do
        Ext.Utils.Print("[BG3Access] " .. prefix .. "binding: "
            .. tostring(bindingEntry.propertyName)
            .. " path=" .. tostring(bindingEntry.bindingPath)
            .. " value=" .. tostring(bindingEntry.resolvedValue))
    end
end

-- Dump namedTexts table.
function AccessibilityLogger.DumpNamedTexts(namedTexts, indent)
    if currentLevel < LOG_LEVEL_DEBUG then return end
    if not namedTexts then return end

    local prefix = indent or "  "
    local namedParts = {}
    for elementName, elementText in pairs(namedTexts) do
        local displayText = tostring(elementText)
        if #displayText > 80 then displayText = displayText:sub(1, 80) .. "..." end
        table.insert(namedParts, elementName .. "=" .. displayText)
    end
    table.sort(namedParts)
    Ext.Utils.Print("[BG3Access] " .. prefix .. "namedTexts: "
        .. (#namedParts > 0 and table.concat(namedParts, " | ") or "(empty)"))
end

-- Dump controller sub-table properties (buttons, triggers, sticks).
function AccessibilityLogger.DumpControllerSubTables(dcProps, indent)
    if currentLevel < LOG_LEVEL_DEBUG then return end
    if not dcProps then return end

    local prefix = indent or "  "
    for key, val in pairs(dcProps) do
        if type(val) == "table" then
            if key:match("^Button") or key:match("^Dpad") or key:match("Bumper$")
                or key:match("Trigger$") or key:match("Stick$") then
                local subParts = {}
                for subKey, subVal in pairs(val) do
                    local subStr = tostring(subVal)
                    if #subStr > 60 then subStr = subStr:sub(1, 60) .. "..." end
                    table.insert(subParts, subKey .. "=" .. subStr)
                end
                table.sort(subParts)
                if #subParts > 0 then
                    Ext.Utils.Print("[BG3Access] " .. prefix .. "sub[" .. key .. "]: "
                        .. table.concat(subParts, " | "))
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Level control.
-- ---------------------------------------------------------------------------

function AccessibilityLogger.GetLevel()
    return currentLevel
end

function AccessibilityLogger.SetLevel(level)
    currentLevel = level
end

function AccessibilityLogger.GetLevelName()
    return LOG_LEVEL_NAMES[currentLevel] or "UNKNOWN"
end

function AccessibilityLogger.IsDebug()
    return currentLevel >= LOG_LEVEL_DEBUG
end

-- Cycle through levels: OFF -> INFO -> DEBUG -> OFF
function BG3Access.Client.CycleLogLevel()
    currentLevel = (currentLevel + 1) % 3
    local levelName = LOG_LEVEL_NAMES[currentLevel]
    Ext.Utils.Print("[BG3Access] Log level: " .. levelName)
    -- Mirror Lua DEBUG on the C++ trace-logging flag so one toggle
    -- flips the whole firehose.  Guarded: the Ext.UI.SetTraceLogging
    -- binding only exists in VERBOSE-compiled dev builds of the
    -- extender dll.
    if Ext.UI and Ext.UI.SetTraceLogging then
        Ext.UI.SetTraceLogging(currentLevel == LOG_LEVEL_DEBUG)
    end
    local SpeechDataMod = BG3Access.Client.SpeechData
    if SpeechDataMod then
        SpeechDataMod.Alert("Log level " .. levelName, "interrupt")
    else
        Ext.Tolk.Speak("Log level " .. levelName, true)
    end
end

-- Export constants for external use.
AccessibilityLogger.OFF   = LOG_LEVEL_OFF
AccessibilityLogger.INFO  = LOG_LEVEL_INFO
AccessibilityLogger.DEBUG = LOG_LEVEL_DEBUG

-- Attach to global namespace so other modules can access via BG3Access.Client.Log.
BG3Access.Client.Log = AccessibilityLogger
