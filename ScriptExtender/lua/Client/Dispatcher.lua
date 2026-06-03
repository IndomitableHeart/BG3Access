-- File: Client/Dispatcher.lua
--
-- Generic UI handler dispatcher.  ONE implementation, used by both
-- Menus and WorldUI.  EventRouter routes snapshots to the appropriate
-- dispatcher instance based on game state; each dispatcher resolves
-- the active handler within its category from a registration list.
--
-- =====================================================================
-- DESIGN STATEMENT (read before changing anything in this file)
-- =====================================================================
--
-- This module is the result of multiple painful debugging sessions
-- where the dispatcher accumulated fallback ladders.  Specifically:
--   - 6-way OR liveness checks that conflated "is this widget loaded"
--     with "is this widget visible right now"
--   - Time-based activation grace periods that papered over identity
--     inconsistencies
--   - Permissive "any registered DC keeps me alive" clauses that
--     masked shared-DC handler collisions (PauseMenu vs ShortcutsMenu)
--   - Per-module ad-hoc dispatchers that drifted apart over time
--
-- Each addition was locally reasonable.  The accumulation produced
-- recurring "handler dropped mid-navigation" and "handler stuck after
-- close" bugs whose root causes were impossible to keep straight.
--
-- The principle that resolves all of them: a handler is open if its
-- declared signals fire.  ONE check per snapshot.  No fallback
-- ladders.  When a new edge case appears, EXTEND THE REGISTRATION
-- SHAPE so the case is expressible as data, not as a new code path.
--
-- HARD RULES:
--
-- 1. Liveness uses snapshot.allWidget* (loaded-state, not visibility-
--    filtered).  Discovery / activation uses widget events directly.
--    NEVER mix them, NEVER fall back from one to the other.
--
-- 2. If you need a new "kind of liveness signal," ADD A FIELD to the
--    registration's openWhen table.  Update IsHandlerOpen to consider
--    it.  Do NOT add a special-case branch that only fires for one
--    handler.  If the case is unique to one handler, it goes in that
--    handler's isOpen function.
--
-- 3. There is no "grace period."  If a handler's openWhen says it's
--    closed, it's closed.  If that's wrong, the openWhen is wrong --
--    fix the openWhen, not the dispatcher.
--
-- 4. There is no "default handler" fallback.  If no registered handler
--    is open, the dispatcher returns and the upstream router decides
--    what to do (usually: route to world).
--
-- 5. Ad-hoc state variables (lastSpokenName, activationTimestamp, etc.)
--    do not live in the dispatcher.  They live in handler state
--    where they belong.  The dispatcher tracks ONLY: current entry,
--    overlay stack.
--
-- =====================================================================
-- REGISTRATION SHAPE
-- =====================================================================
--
-- {
--     name = "<HandlerName>",          -- string, for logging
--     handler = <handler module>,      -- table with HandleSnapshot,
--                                      --   HandleWidgetAdded, ResetState,
--                                      --   ResetNavigation methods
--     openWhen = {
--         widgetNames = { [name] = true, ... },     -- optional
--         dcTypes     = { [type] = true, ... },     -- optional
--         isOpen      = function(snapshot) ... end, -- optional escape hatch
--     },
--     activateMode = "auto" | "explicit",  -- default "auto"
--     canStack     = true | false,         -- default false
-- }
--
-- openWhen sources (handler is open if ANY non-empty source fires):
--
--   widgetNames   -- A widget with this x:Name is in
--                    snapshot.allWidgetNames.  Most stable signal --
--                    x:Names don't change during a session and only
--                    leave allWidgetNames when the widget actually
--                    unloads.  Use this when the widget has a known
--                    x:Name in its XAML.  Distinguishes handlers that
--                    share a DC (PauseMenu vs ShortcutsMenu).
--
--   dcTypes       -- A DC type appears in either snapshot.allWidgetDCTypes,
--                    snapshot.focusedElement.dcType, or
--                    snapshot.selectedElement.dcType.  Use for
--                    handlers identified by content type rather than
--                    by widget identity, OR for per-item ViewModels
--                    that only ever appear as focused/selected element
--                    DCs (ls.VMSavegame, gui::VMPreset, ls.VMSpellBook).
--                    Also covers widgets with no x:Name in XAML
--                    (KeybindingOptions has no x:Name).
--
--   isOpen        -- Escape hatch for handlers whose open-state can't
--                    be expressed via the above (typically permanent
--                    overlays like Notification_c where loaded != open
--                    and the open question depends on a DC sub-property
--                    being non-default).  Receives the full snapshot;
--                    returns boolean.  USE SPARINGLY -- if you find
--                    yourself writing the same isOpen function for
--                    multiple handlers, that's a sign the registration
--                    shape needs another field, not more closures.
--
-- activateMode:
--   "auto"     -- Default.  Handler activates whenever its openWhen
--                 fires from any source (widgetNames, dcTypes, isOpen).
--   "explicit" -- Handler activates AND stays alive ONLY through
--                 widget x:Name match.  dcTypes are still listed in
--                 the registration so IsRegisteredDCType (used by
--                 EventRouter / cross-module routing checks) can
--                 recognize the DC family, but a bare DC-type match
--                 will NOT activate or sustain the handler.
--
--                 Use for HUD widgets that are always loaded but
--                 should only take focus when the user explicitly
--                 enters a navigable instance (PartyLine: the
--                 PartyLine_c HUD row is always present and shares
--                 ls.DCPartyLine with PartyLineActive_c, the LT-
--                 opened navigable panel; only the named active
--                 panel should activate the handler).
--
--                 Concretely:
--                  - MatchHandlerForWidgetEvent skips dcType-only
--                    matches for explicit handlers (Source 2 of
--                    activation).
--                  - IsHandlerOpen skips dcType source for explicit
--                    handlers (Source 2 of liveness).
--                  - widgetNames source still applies to both.
--
-- canStack:
--   false  -- New activation supersedes current; old handler discarded.
--   true   -- New activation pushes current onto an overlay stack.
--            When current handler closes, stack pops and the popped
--            handler resumes.  Use for overlay panels (Examine over
--            CharacterSheet, Container over CharacterSheet, etc.).
--
-- =====================================================================
-- ADDING A NEW MENU/PANEL
-- =====================================================================
--
-- 1. Write the handler module exposing: HandleSnapshot, HandleWidgetAdded,
--    ResetState, ResetNavigation.  Use the existing factory in
--    Menus.lua (CreateMenuHandler) or WorldUI.lua (CreatePanelHandler)
--    if your handler fits the standard pipeline.
--
-- 2. Determine which signal sources reliably identify your widget:
--    - Widget has a known x:Name in XAML -> widgetNames
--    - Widget DC type is unique to your handler -> dcTypes
--    - Per-item VMs distinguish (carousel, list) -> dcTypes
--    - Widget never closes, only changes content -> isOpen
--
-- 3. Add an entry to the appropriate dispatcher's registration list
--    (Menus.lua's `registeredHandlers` or WorldUI.lua's equivalent).
--
-- 4. DO NOT modify Dispatcher.lua.  If your handler doesn't fit the
--    registration shape, propose extending the shape -- don't add a
--    one-off branch.

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

local Log = BG3Access.Client.Log

-- =====================================================================
-- IsHandlerOpen: evaluates a registered handler's openWhen criterion
-- against the snapshot.  Returns true if the handler should be
-- considered alive on this tick.
-- =====================================================================
local function IsHandlerOpen(entry, snapshot)
    local criterion = entry.openWhen
    if not criterion then return false end
    local isExplicit = (entry.activateMode or "auto") == "explicit"

    -- Source 1: widget x:Name in the all-tracked list (loaded-state).
    if criterion.widgetNames and snapshot.allWidgetNames then
        for _, widgetName in ipairs(snapshot.allWidgetNames) do
            if criterion.widgetNames[widgetName] then return true end
        end
    end

    -- Source 2: DC type match against widget DCs OR focused DC OR
    -- selected DC.  Catches per-item VMs and widgets without x:Names.
    --
    -- Explicit-mode handlers SKIP this source.  Their dcTypes are
    -- declared only for IsRegisteredDCType (so EventRouter and
    -- IsWorldDCType / IsMenuDCType can recognize the DC family);
    -- a DC type match alone must not keep them alive.  Example:
    -- PartyLine.dcTypes contains ls.DCPartyLine so the HUD's DC is
    -- "known" to WorldUI for routing decisions.  But PartyLine
    -- should ONLY be open while PartyLineActive_c (the LT-opened
    -- panel) is in the tracked widget set -- never just because
    -- the HUD's DC is loaded.  The Source-2 short-circuit would
    -- otherwise pin PartyLine open forever.
    if criterion.dcTypes and not isExplicit then
        if snapshot.allWidgetDCTypes then
            for _, widgetDCType in ipairs(snapshot.allWidgetDCTypes) do
                if criterion.dcTypes[widgetDCType] then return true end
            end
        end
        if snapshot.focusedElement
            and snapshot.focusedElement.dcType
            and criterion.dcTypes[snapshot.focusedElement.dcType] then
            return true
        end
        if snapshot.selectedElement
            and snapshot.selectedElement.dcType
            and criterion.dcTypes[snapshot.selectedElement.dcType] then
            return true
        end
    end

    -- Source 3: handler-supplied content check.
    if criterion.isOpen then
        return criterion.isOpen(snapshot) == true
    end

    return false
end

-- =====================================================================
-- MatchHandlerForWidgetEvent: find the registration whose openWhen
-- claims this widget event.  widgetNames takes priority over dcTypes
-- (more specific -- distinguishes shared-DC handlers).
--
-- activateMode="explicit" entries activate ONLY via a widget x:Name
-- match.  Their dcTypes are still considered for liveness (in
-- IsHandlerOpen), but a fresh widgetAdded event carrying just a
-- shared DC type must NOT activate them.  Example: PartyLine
-- registers widgetNames={PartyLineActive_c} and dcTypes={DCPartyLine}.
-- The HUD's PartyLine_c widget fires a widgetAdded with dc=DCPartyLine
-- but elemName=PartyLine_c (NOT PartyLineActive_c).  Without the
-- explicit-mode gate, the DC-type fallback would activate PartyLine
-- from the HUD event -- exactly the auto-pickup we wanted to avoid.
-- =====================================================================
local function MatchHandlerForWidgetEvent(handlers, widgetEvent)
    if not widgetEvent then return nil end
    local elemName = widgetEvent.elemName
    local dcType = widgetEvent.dcType

    if elemName and elemName ~= "" then
        for _, entry in ipairs(handlers) do
            local criterion = entry.openWhen
            if criterion and criterion.widgetNames
                and criterion.widgetNames[elemName] then
                return entry
            end
        end
    end

    if dcType and dcType ~= "" then
        for _, entry in ipairs(handlers) do
            local criterion = entry.openWhen
            if criterion and criterion.dcTypes
                and criterion.dcTypes[dcType]
                and (entry.activateMode or "auto") ~= "explicit" then
                return entry
            end
        end
    end

    return nil
end

-- =====================================================================
-- Dispatcher.Create: build a dispatcher instance with the given config.
-- =====================================================================
--
-- config = {
--     name = "Menus",                  -- for logging
--     handlers = registeredHandlers,    -- the registration list
--     onActivate = function(entry) end, -- optional, fires when handler
--                                       --   becomes active (after the
--                                       --   handler.ResetState on prior).
--                                       --   Use for cross-cutting effects
--                                       --   like GPS suspend.
--     skipWhen = function(snapshot) end, -- optional, predicate.  When
--                                        --   it returns true, the
--                                        --   dispatcher is a no-op for
--                                        --   that snapshot (suppression
--                                        --   for special states).
-- }
--
-- The returned dispatcher exposes:
--
--   dispatcher:HandleWidgetAdded(widgetData)
--     - Matches the event against handlers.  On a hit, activates that
--       handler (pushes current onto the overlay stack if canStack).
--       Forwards the event to the (possibly new) current handler.
--
--   dispatcher:RouteSnapshot(snapshot)
--     - Step 1: liveness check on current handler.  Close if openWhen
--       fails.
--     - Step 2: pickup case.  If no current handler but a registered
--       handler with activateMode="auto" is open, activate it.
--     - Step 3: dispatch.  Forward snapshot to current handler if any.
--     - Special: if current handler closed and overlay stack is non-
--       empty, pop and resume.
--
--   dispatcher:GetActiveHandler()
--     - Returns the current handler instance (or nil).
--
--   dispatcher:GetActiveHandlerWidgetNames()
--     - Returns the SET (table keyed by name, value true) of the
--       current entry's registered widget x:Names, or nil if no
--       active handler / no widgetNames criterion.  Set form
--       supports any-match queries across multi-widget-name
--       handlers (e.g. SaveLoad covers both LoadGame_c and
--       SaveGame_c).
--
--   dispatcher:IsRegisteredDCType(dcType)
--     - True if any handler has the DC type in its dcTypes set.  Used
--       by upstream routing decisions.
--
--   dispatcher:Reset()
--     - Resets all handler state and clears current/stack.

local DispatcherModule = {}

function DispatcherModule.Create(config)
    assert(config and config.handlers,
        "Dispatcher.Create requires config.handlers")

    local handlers = config.handlers
    local logName = config.name or "Dispatcher"
    local onActivate = config.onActivate
    local skipWhen = config.skipWhen

    local currentEntry = nil
    -- Overlay stack for canStack handlers.  Pushed on activation when
    -- current handler had canStack=true.  Popped when current closes.
    local overlayStack = {}

    -- Per-widget-name last-seen widgetRootId (C++ widget pointer as
    -- string).  A widgetAdded event with the same elemName but a
    -- different widgetRootId is a FRESH C++ widget instance -- the
    -- previous one was destroyed and a new one created.
    --
    -- Necessary because the dispatcher's normal liveness check
    -- (RouteSnapshot Step 1) is gated by EventRouter's
    -- focusedElement guard.  When a menu closes and `focusedElement`
    -- stays nil during the close window (no specific HUD focus in
    -- world), Menus.RouteSnapshot never gets called, IsHandlerOpen
    -- never runs, and currentEntry stays pinned to the closed
    -- handler across many snapshots.  On reopen, matchedEntry ==
    -- currentEntry so ActivateEntry is skipped (no ResetState, no
    -- clean entry) -- silence.
    --
    -- widgetRootId is the C++ Widget pointer formatted as "%p" --
    -- ExtractWidgetData populates it for every widget event (per
    -- Module.inl line 3907-3908; PushFocusEventTable pushes it to
    -- Lua as the "widgetRootId" key per UIEvents.inl line 316-322).
    -- Two instances of the same XAML widget x:Name at different
    -- pointers = a legitimate destroy + recreate.
    local lastWidgetRootIdByName = {}

    local onDeactivate = config.onDeactivate

    --- DeactivateCurrent: reset and clear the current handler.  Pure
    --- internal helper -- no stack interaction here.
    local function DeactivateCurrent(reason)
        if not currentEntry then return end
        local exiting = currentEntry
        Log.Info(logName .. ": Deactivating " .. exiting.name
            .. " (" .. (reason or "unspecified") .. ")")
        exiting.handler.ResetState()
        currentEntry = nil
        if onDeactivate then onDeactivate(exiting) end
    end

    --- ActivateEntry: promote the given registration entry to current.
    --- Handles overlay stacking: if current handler had canStack=true,
    --- it goes on the stack instead of being deactivated.
    local function ActivateEntry(newEntry, reason)
        if currentEntry == newEntry then return end

        if currentEntry then
            if currentEntry.canStack then
                -- Save for restoration when newEntry closes.  Do NOT
                -- ResetState -- the handler's navigation state must
                -- persist intact for the resume.
                table.insert(overlayStack, currentEntry)
                Log.Info(logName .. ": Stacking " .. currentEntry.name
                    .. " under " .. newEntry.name)
                currentEntry = nil
            else
                DeactivateCurrent("superseded by " .. newEntry.name)
            end
        end

        currentEntry = newEntry
        Log.Info(logName .. ": Activating " .. newEntry.name
            .. " (" .. (reason or "unspecified") .. ")")
        if onActivate then onActivate(newEntry) end
    end

    --- TryRestoreFromStack: when current handler closes, see if there's
    --- a stacked handler underneath whose openWhen still fires.  If
    --- yes, resume it.  If no, drop it and keep popping.
    local function TryRestoreFromStack(snapshot)
        while #overlayStack > 0 do
            local candidate = overlayStack[#overlayStack]
            table.remove(overlayStack, #overlayStack)
            if IsHandlerOpen(candidate, snapshot) then
                currentEntry = candidate
                Log.Info(logName .. ": Resumed from stack: "
                    .. candidate.name)
                return
            end
            -- Underlying handler is also gone -- discard and keep
            -- popping.  Reset its state since we're not resuming it.
            candidate.handler.ResetState()
            Log.Info(logName .. ": Dropped stacked (also closed): "
                .. candidate.name)
        end
    end

    local dispatcher = {}

    function dispatcher:HandleWidgetAdded(widgetData)
        if not widgetData then return end
        if skipWhen and skipWhen(nil) then return end

        local matchedEntry = MatchHandlerForWidgetEvent(
            handlers, widgetData)

        -- Re-instantiation check: same elemName + different
        -- widgetRootId = a fresh C++ widget instance (previous one
        -- destroyed, new one created).  The game does this on
        -- tab switches in tabbed menus (e.g. Options swaps the
        -- inner widget per tab while keeping the outer x:Name
        -- "Options_c" stable).  The user is STILL in the same
        -- logical panel -- only the underlying widget pointer
        -- changed.
        --
        -- Use a SOFT reset (ResetNavigation) instead of a full
        -- DeactivateCurrent -> ResetState here.  ResetNavigation
        -- clears per-tab navigation state (currentTabContext,
        -- lastSpokenTitle, lastSpokenName, previousSpeechData)
        -- which is what we want for a tab switch, BUT preserves
        -- tabHintSpoken and screenEntryOverrides which should
        -- carry across the re-instantiation:
        --
        --   - tabHintSpoken: the user already heard the nav hint
        --     when they entered the panel; re-speaking it on
        --     every tab switch is noise.
        --   - screenEntryOverrides: forward-looking state set by
        --     onWidgetAdded for the new tab, to be consumed by
        --     the next screen entry.  Wiping it would defeat the
        --     design (same rationale as ResetNavigation itself
        --     not wiping it).
        --
        -- onWidgetAdded still fires below via HandleWidgetAdded,
        -- so per-tab subscriptions (controller input bindings,
        -- description overrides for special tabs) are re-applied
        -- as needed; handlers that swap state on tab change
        -- (e.g. Options unsubscribing controller input when
        -- leaving the Controller tab) use the onWidgetAdded
        -- elseif branch which still runs.
        if matchedEntry then
            local widgetRootId = widgetData.widgetRootId
            local elemName = widgetData.elemName
            if elemName and widgetRootId and widgetRootId ~= "" then
                local lastRootId = lastWidgetRootIdByName[elemName]
                lastWidgetRootIdByName[elemName] = widgetRootId
                if lastRootId and lastRootId ~= widgetRootId
                    and matchedEntry == currentEntry then
                    Log.Info(logName .. ": widget '" .. elemName
                        .. "' re-instantiated (widgetRootId "
                        .. lastRootId .. " -> " .. widgetRootId
                        .. ") -- soft reset (preserve tab hint)")
                    if currentEntry.handler.ResetNavigation then
                        currentEntry.handler.ResetNavigation()
                    end
                end
            end
        end

        if matchedEntry and matchedEntry ~= currentEntry then
            ActivateEntry(matchedEntry, "widget event "
                .. tostring(widgetData.elemName)
                .. " dc=" .. tostring(widgetData.dcType))
        end

        if currentEntry then
            currentEntry.handler.HandleWidgetAdded(widgetData)
        end
    end

    function dispatcher:RouteSnapshot(snapshot)
        if skipWhen and skipWhen(snapshot) then return end

        -- Step 1: liveness.
        if currentEntry
            and not IsHandlerOpen(currentEntry, snapshot) then
            DeactivateCurrent("openWhen failed")
            -- Try to resume from overlay stack.
            TryRestoreFromStack(snapshot)
        end

        -- Step 2: pickup case.  No current handler but some auto-
        -- mode registered handler is open.
        if not currentEntry then
            for _, entry in ipairs(handlers) do
                if (entry.activateMode or "auto") == "auto"
                    and IsHandlerOpen(entry, snapshot) then
                    ActivateEntry(entry, "pickup")
                    break
                end
            end
        end

        -- Step 3: dispatch.
        if currentEntry then
            currentEntry.handler.HandleSnapshot(snapshot)
        end
    end

    --- CheckLiveness: run ONLY Step 1 (liveness) of RouteSnapshot,
    --- with no pickup or dispatch.  Used by EventRouter to detect
    --- "the active handler's widget went away" on snapshots that
    --- don't have a focusedElement -- the normal full RouteSnapshot
    --- is gated above by the focusedElement guard in EventRouter,
    --- which means a handler whose widget closed during a "no focus"
    --- window (e.g. shortcuts radial dismiss, no HUD focus target
    --- afterwards) would stay pinned indefinitely.  Per the design
    --- statement, liveness uses snapshot.allWidget* -- this is
    --- safe to call on every snapshot regardless of focus state.
    function dispatcher:CheckLiveness(snapshot)
        if skipWhen and skipWhen(snapshot) then return end
        if currentEntry
            and not IsHandlerOpen(currentEntry, snapshot) then
            DeactivateCurrent("openWhen failed (liveness check)")
            TryRestoreFromStack(snapshot)
        end
    end

    function dispatcher:HandleWidgetRootChanged()
        if currentEntry then
            currentEntry.handler.ResetNavigation()
        end
    end

    --- TryPickup: run only the pickup pass (no liveness, no dispatch).
    --- Returns true if a handler is active after the call.  Used by
    --- upstream routing logic that wants to detect "this snapshot
    --- belongs to my dispatcher's domain" without actually delivering
    --- the snapshot to the handler -- the dispatch happens later via
    --- RouteSnapshot when the upstream router has confirmed routing.
    function dispatcher:TryPickup(snapshot)
        if currentEntry then return true end
        if skipWhen and skipWhen(snapshot) then return false end
        for _, entry in ipairs(handlers) do
            if (entry.activateMode or "auto") == "auto"
                and IsHandlerOpen(entry, snapshot) then
                ActivateEntry(entry, "pickup")
                return true
            end
        end
        return false
    end

    function dispatcher:GetActiveHandler()
        return currentEntry and currentEntry.handler or nil
    end

    function dispatcher:GetActiveEntry()
        return currentEntry
    end

    --- Returns the set of widget x:Names the active handler is
    --- registered for, or nil if no handler is active / it has no
    --- widgetNames criterion.  Set form (key = name, value = true)
    --- so callers can membership-test in O(1).
    ---
    --- A handler may register multiple widget names (e.g. SaveLoad
    --- covers both LoadGame_c and SaveGame_c).  The previous version
    --- of this function returned a SINGLE name picked by Lua's
    --- unordered table iteration, which made the liveness fallback
    --- in EventRouter check the wrong widget half the time -- e.g.
    --- on a Load Game session it would query "SaveGame_c" against
    --- allWidgetNames, fail to find it, and falsely deactivate the
    --- live handler.  Returning the whole set lets callers do an
    --- any-match check.
    function dispatcher:GetActiveHandlerWidgetNames()
        if not currentEntry then return nil end
        local criterion = currentEntry.openWhen
        if not criterion or not criterion.widgetNames then
            return nil
        end
        local names = {}
        for widgetName in pairs(criterion.widgetNames) do
            names[widgetName] = true
        end
        return names
    end

    function dispatcher:IsRegisteredDCType(dcType)
        if not dcType or dcType == "" then return false end
        for _, entry in ipairs(handlers) do
            local criterion = entry.openWhen
            if criterion and criterion.dcTypes
                and criterion.dcTypes[dcType] then
                return true
            end
        end
        return false
    end

    function dispatcher:Reset()
        for _, entry in ipairs(handlers) do
            entry.handler.ResetState()
        end
        currentEntry = nil
        overlayStack = {}
        lastWidgetRootIdByName = {}
    end

    return dispatcher
end

BG3Access.Client.Dispatcher = DispatcherModule

return DispatcherModule
