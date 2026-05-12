-- File: Client/Scheduler.lua
--
-- Frame-based deferred-action utility.  Run a function after N
-- Ext.Events.Tick events have elapsed.  Used to work around binding
-- propagation timing in Noesis (data-bound TextBlocks need several
-- frames after widget creation before their Text reflects the
-- ViewModel value -- reading too early returns stale defaults).
--
-- Usage:
--   local cancel = BG3Access.Client.Scheduler.RunAfterFrames(
--       30, function() ... end)
--   -- later, if needed:
--   cancel()
--
-- Implementation: a single permanent Tick subscription manages a
-- pending list.  Each tick decrements every entry's framesLeft;
-- entries that hit zero fire once and are removed.  Cancellation is
-- handled by setting a flag on the entry (so iteration during
-- cancellation is safe).  Subscription is a no-op when the pending
-- list is empty.

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

local Log = BG3Access.Client.Log

local pendingActions = {}
local tickSubscribed = false

local function TickHandler()
    if #pendingActions == 0 then return end

    -- Iterate over a snapshot so that entries scheduled or canceled
    -- during action callbacks don't break the loop.
    local toProcess = pendingActions
    pendingActions = {}

    for _, entry in ipairs(toProcess) do
        if not entry.canceled then
            entry.framesLeft = entry.framesLeft - 1
            if entry.framesLeft <= 0 then
                local ok, err = pcall(entry.action)
                if not ok and Log then
                    Log.Warn("Scheduler action error: " .. tostring(err))
                end
            else
                pendingActions[#pendingActions + 1] = entry
            end
        end
    end
end

local function EnsureSubscribed()
    if tickSubscribed then return end
    if not Ext.Events or not Ext.Events.Tick then return end
    Ext.Events.Tick:Subscribe(TickHandler)
    tickSubscribed = true
    if Log then
        Log.Info("Scheduler: subscribed to Ext.Events.Tick")
    end
end

local Scheduler = {}

--- RunAfterFrames: invoke `action` after `framesToWait` Ext.Events.Tick
--- events have elapsed.  Returns a cancel function that, when
--- called, prevents the action from firing if it hasn't already.
---
--- Frame counting starts from the next tick after the call -- i.e.,
--- RunAfterFrames(1, fn) fires fn on the next tick, not immediately.
---
--- Use this when you need to wait for engine-internal state to
--- propagate -- e.g., Noesis binding pipeline, render-frame sync.
--- For real-time delays (audio cue scheduling, polling intervals),
--- use RunAfterMs instead.
---
--- @param framesToWait number  Number of frames to wait (>= 1).
--- @param action function      Callback to invoke (no arguments).
--- @return function  Cancel function -- call to abort.
function Scheduler.RunAfterFrames(framesToWait, action)
    EnsureSubscribed()
    local entry = {
        framesLeft = framesToWait,
        action     = action,
        canceled   = false,
    }
    pendingActions[#pendingActions + 1] = entry
    return function()
        entry.canceled = true
    end
end

--- RunAfterMs: invoke `action` after `msToWait` real-time
--- milliseconds have elapsed.  Returns a cancel function.
---
--- Wrapper around Ext.Timer.WaitFor that adds cancellation support
--- (Ext.Timer.WaitFor itself has no cancel mechanism on the BG3SE
--- bindings; callers were rolling their own canceled-flag pattern
--- inside the callback).  Cancelling here turns the action into a
--- no-op when the timer eventually fires.
---
--- Use this for real-time delays (audio scheduling, polling
--- intervals).  For engine-state-settle waits, use RunAfterFrames.
---
--- @param msToWait number    Real-time delay in milliseconds (>= 1).
--- @param action function    Callback to invoke (no arguments).
--- @return function  Cancel function -- call to abort.
function Scheduler.RunAfterMs(msToWait, action)
    local entry = { canceled = false, action = action }
    Ext.Timer.WaitFor(msToWait, function()
        if entry.canceled then return end
        local ok, err = pcall(entry.action)
        if not ok and Log then
            Log.Warn("Scheduler RunAfterMs error: " .. tostring(err))
        end
    end)
    return function()
        entry.canceled = true
    end
end

BG3Access.Client.Scheduler = Scheduler

return Scheduler
