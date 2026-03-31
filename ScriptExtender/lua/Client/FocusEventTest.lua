-- FocusEventTest.lua
-- Temporary test: subscribe to focus routed events on the application root
-- and log what fires when navigating with a controller.
-- Delete this file after testing.

local TAG = "[FocusEventTest]"

local function SafeType(elem)
    local ok, t = pcall(function() return elem.Type end)
    return ok and t or "???"
end

local function SafeName(elem)
    local ok, n = pcall(function() return elem:GetProperty("Name") end)
    return ok and n or nil
end

local function SafeText(elem)
    local ok, t = pcall(function() return elem:GetProperty("Text") end)
    if ok and t then return t end
    -- Try ToString as fallback
    local ok2, s = pcall(function() return elem:ToString() end)
    if ok2 and s and not s:find("%[ForceUpdate%]") then
        -- Filter out type-name-only results
        local typ = SafeType(elem)
        if s ~= typ and s ~= "Noesis." .. typ then
            return s
        end
    end
    return nil
end

local function DescribeElement(elem)
    if not elem then return "nil" end
    local typ = SafeType(elem)
    local name = SafeName(elem)
    local text = SafeText(elem)
    local parts = { typ }
    if name then parts[#parts + 1] = "name=" .. name end
    if text then parts[#parts + 1] = "text=" .. tostring(text) end
    return table.concat(parts, " | ")
end

local subscriptions = {}

local function SetupSubscriptions()
    local root = Ext.UI.GetRoot()
    if not root then
        Ext.Utils.PrintWarning(TAG .. " GetRoot() returned nil, retrying in 1s")
        Ext.Timer.WaitFor(1000, SetupSubscriptions)
        return
    end

    Ext.Utils.Print(TAG .. " Root type: " .. SafeType(root))

    -- GotKeyboardFocus: the main one we care about
    local sub1 = root:Subscribe("GotKeyboardFocus", function(sender, args)
        local newDesc = DescribeElement(args.NewFocus)
        local oldDesc = DescribeElement(args.OldFocus)
        Ext.Utils.Print(TAG .. " GotKeyboardFocus: NEW=" .. newDesc
            .. " | OLD=" .. oldDesc)
    end)
    subscriptions[#subscriptions + 1] = { root, sub1 }
    Ext.Utils.Print(TAG .. " Subscribed GotKeyboardFocus (id=" .. tostring(sub1) .. ")")

    -- GotFocus: simpler event, compare coverage
    local sub2 = root:Subscribe("GotFocus", function(sender, args)
        local srcDesc = DescribeElement(args.Source)
        Ext.Utils.Print(TAG .. " GotFocus: SOURCE=" .. srcDesc)
    end)
    subscriptions[#subscriptions + 1] = { root, sub2 }
    Ext.Utils.Print(TAG .. " Subscribed GotFocus (id=" .. tostring(sub2) .. ")")

    -- LostKeyboardFocus: see if we get clean leave events
    local sub3 = root:Subscribe("LostKeyboardFocus", function(sender, args)
        local oldDesc = DescribeElement(args.OldFocus)
        local newDesc = DescribeElement(args.NewFocus)
        Ext.Utils.Print(TAG .. " LostKeyboardFocus: LOST=" .. oldDesc
            .. " | TO=" .. newDesc)
    end)
    subscriptions[#subscriptions + 1] = { root, sub3 }
    Ext.Utils.Print(TAG .. " Subscribed LostKeyboardFocus (id=" .. tostring(sub3) .. ")")

    Ext.Utils.Print(TAG .. " All subscriptions active. Navigate with controller and check log.")
end

-- Also try subscribing to IsSelected changes via a tick-based check
-- to see if carousel tab selection fires any focus events
local lastSelectedType = nil
local function CheckSelectedOnTick()
    local ok, elem = pcall(Ext.UI.GetFocusedElement)
    if ok and elem then
        local desc = SafeType(elem)
        if desc ~= lastSelectedType then
            Ext.Utils.Print(TAG .. " GetFocusedElement changed: " .. DescribeElement(elem))
            lastSelectedType = desc
        end
    end
end

Ext.Events.GameStateChanged:Subscribe(function(e)
    Ext.Utils.Print(TAG .. " GameState: " .. tostring(e.FromState) .. " -> " .. tostring(e.ToState))

    -- Clean up old subscriptions
    for _, sub in ipairs(subscriptions) do
        pcall(function() sub[1]:Unsubscribe(sub[2]) end)
    end
    subscriptions = {}
    lastSelectedType = nil

    -- Re-subscribe after a short delay to let UI initialize
    if tostring(e.ToState) == "Menu"
        or tostring(e.ToState) == "Running"
        or tostring(e.ToState) == "Paused" then
        Ext.Timer.WaitFor(500, SetupSubscriptions)
    end
end)

-- Periodic focused element check (every 500ms, not every frame)
local tickCount = 0
Ext.Events.Tick:Subscribe(function()
    tickCount = tickCount + 1
    if tickCount % 30 == 0 then  -- roughly every 500ms at 60fps
        CheckSelectedOnTick()
    end
end)

Ext.Utils.Print(TAG .. " Test script loaded. Waiting for game state change...")
