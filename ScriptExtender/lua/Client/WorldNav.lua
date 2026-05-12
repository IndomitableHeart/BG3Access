-- File: Client/WorldNav.lua
--
-- Spatial navigation and GPS system for BG3Access.
--
-- Single RS-Left cycle in the world: Off -> Exploration -> Routing -> Off.
--
--   Off         = silent, all GPS state cleared.
--   Exploration = proximity mode, announces nearby entities (categorised,
--                 deduped) as the player walks around.
--   Routing     = opens the entity list immediately.  After A-selecting
--                 a target, pathfinds to it and announces clock direction
--                 + distance every 2m.  Unrelated proximity alerts are
--                 muted while a target is active.
--
-- Entity list (opened automatically on Routing entry):
--    D-pad left/right  = cycle categories (wrapping).
--    D-pad up/down     = cycle entities in current category.
--    A button          = select entity as tracking target, close list.
--    B button          = close list without selecting.
--
-- RS-Left in a menu still opens the detail view (WorldUI).  RS-Left while
-- the entity list is open is ignored (use B to close first).
--
-- Camera-position-based reference angle for clock directions (immune to
-- Steering feedback loop).  Pathfinding via BeginPathfindingImmediate +
-- FindPath, retry at shorter distances for unwalkable targets.
-- Direction = bearing from player to lookahead node on the computed path.
-- No walkability scanning -- the path IS the validation.

local Log = BG3Access.Client.Log
local Helpers = BG3Access.Client.Helpers
local SpeechData = BG3Access.Client.SpeechData

-- Bundled state for guidance speech dedup.  After the detour state
-- machine was removed (auto-walk handles routing), only the spoken
-- bearing remains.  Kept as a one-field table both for forward-
-- compatibility (easy to add more dedup state later) and because
-- the "always one local for state" pattern keeps the main function
-- under Lua's 200-local ceiling regardless of state growth.
local NavState = {
    spokenBearing = nil,
}

-- ============================================================================
-- Constants
-- ============================================================================

-- Path-following.
local GPS_GUIDANCE_MOVEMENT   = 2.0   -- meters between guidance updates

-- Fallback values for the BG3 engine config constants below, used
-- only if Ext.ExtraData is unavailable at the time of first read.
-- The real values are read lazily from Ext.ExtraData and cached so
-- the mod always tracks whatever BG3 itself uses.
local GPS_FALLBACK_MOVETO_MIN = 0.5
local GPS_FALLBACK_MOVETO_MAX = 3.5

-- Path-endpoint arrival.  When the target position is inside an
-- unwalkable mesh (corpse, container, decoration), the pathfinder
-- may settle on a walkable tile beyond MoveToTargetCloseEnoughMax
-- from the raw target.  If the player is within
-- GPS_ENDPOINT_ARRIVAL_M of the path's last node AND the raw
-- target distance is within GPS_ENDPOINT_MAX_DISTANCE, we treat it
-- as arrival: the pathfinder has done its best and this is the
-- closest physical approach.  Kept as a safety net even though the
-- move-to tolerances now match BG3's own.
local GPS_ENDPOINT_ARRIVAL_M  = 0.8
local GPS_ENDPOINT_MAX_DISTANCE = 4.5

-- Resolved at first use from Ext.ExtraData.
local cachedMoveToCloseEnoughMin = nil
local cachedMoveToCloseEnoughMax = nil

--- Return BG3's authoritative "move to target" minimum close-enough
--- distance.  Reads Ext.ExtraData.MoveToTargetCloseEnoughMin the
--- first time it is called and caches the value; falls back to
--- GPS_FALLBACK_MOVETO_MIN if ExtraData is not accessible.
local function GetMoveToCloseEnoughMin()
    if cachedMoveToCloseEnoughMin then
        return cachedMoveToCloseEnoughMin
    end
    local ok, value = pcall(function()
        return Ext.ExtraData.MoveToTargetCloseEnoughMin
    end)
    if ok and type(value) == "number" then
        cachedMoveToCloseEnoughMin = value
        return value
    end
    return GPS_FALLBACK_MOVETO_MIN
end

--- Return BG3's authoritative "move to target" maximum close-enough
--- distance.  Reads Ext.ExtraData.MoveToTargetCloseEnoughMax the
--- first time it is called and caches the value; falls back to
--- GPS_FALLBACK_MOVETO_MAX if ExtraData is not accessible.  This
--- is the same threshold BG3's own character controller uses to
--- decide a Move To task has arrived, so we use it for both the
--- AiPath.CloseEnoughMax field and the GPS arrival check.
local function GetMoveToCloseEnoughMax()
    if cachedMoveToCloseEnoughMax then
        return cachedMoveToCloseEnoughMax
    end
    local ok, value = pcall(function()
        return Ext.ExtraData.MoveToTargetCloseEnoughMax
    end)
    if ok and type(value) == "number" then
        cachedMoveToCloseEnoughMax = value
        return value
    end
    return GPS_FALLBACK_MOVETO_MAX
end

-- Pathfinder "close enough" Y tolerances.  The horizontal thresholds
-- (Min/Max) are read at runtime from Ext.ExtraData via the
-- GetMoveToCloseEnough* helpers above.  Y tolerances are not in
-- ExtraData, so they stay hand-picked.
local GPS_CLOSE_ENOUGH_FLOOR  = 2.0   -- Y tolerance below target
local GPS_CLOSE_ENOUGH_CEIL   = 2.0   -- Y tolerance above target

-- Two-phase pathfinding close-enough radii.  BG3's authoritative
-- MoveToTargetCloseEnoughMax (3.5m) is "generic walk-to distance" --
-- the range at which the engine's Move To task stops walking, but
-- NOT necessarily a range at which the player can interact with the
-- target.  Interaction (Examine, Use, Attack, X context menu) needs
-- the character to be roughly 1.5m from the object so the cursor
-- target highlights it.
--
-- ComputePath therefore runs a two-phase attempt each tick:
--   Phase 1 (tight):  CloseEnoughMax = GPS_INTERACT_CLOSE_ENOUGH_MAX.
--                     Gets the player within interaction range when
--                     a walkable tile exists that close.  Arrival
--                     fires at the tight radius so the player can
--                     immediately interact without nudging around.
--   Phase 2 (loose):  CloseEnoughMax = GetMoveToCloseEnoughMax()
--                     (BG3's default 3.5m).  Used when no walkable
--                     tile exists within the tight radius (target
--                     inside a mesh, narrow approach corridor).
--                     Arrival fires at the loose radius -- the
--                     player stops walking but may need to nudge
--                     manually to interact.  Path-endpoint arrival
--                     remains the last-resort fallback.
local GPS_INTERACT_CLOSE_ENOUGH_MAX = 1.5

-- Stuck detection.  Every position check (POSITION_CHECK_MS = 300ms),
-- we compare distance-to-target against the previous check.  If it
-- has not improved by at least GPS_PROGRESS_DELTA for GPS_STUCK_TICKS
-- consecutive checks, the path is assumed blocked by something the
-- static navmesh did not account for (dynamic obstacles, closed
-- doors, body props, party members) and a recompute is forced.
--
-- Tuning rationale:
--   GPS_PROGRESS_DELTA = 0.10  -- 0.10m / 300ms = 0.33 m/s minimum.
--     Slower than walking speed but enough to filter true stalls.
--     Previously 0.25 (0.83 m/s), which falsely flagged the user
--     when they were intentionally walking slowly to avoid
--     overshooting interaction targets near hazards.
--   GPS_STUCK_TICKS = 10 -- 10 * 300ms = 3.0 seconds of cumulative
--     stall before "Path blocked" fires.  Previously 6 (1.8 s).
--     The longer window pairs with the looser progress threshold
--     so genuine blockages still trip but cautious-walking pauses
--     do not.
local GPS_PROGRESS_DELTA      = 0.10  -- meters per position-check tick
local GPS_STUCK_TICKS         = 10    -- ~3.0s of no progress
-- Close-range exclusion radius for stuck detection.  When the player
-- is within arrivalThreshold + GPS_STUCK_CLOSE_RANGE_PAD of the raw
-- target position, stuck detection is disabled entirely -- that's
-- the endgame circling-the-target phase where straight-line
-- distance naturally oscillates and a "Path blocked" announcement
-- would be noise rather than signal.
--
-- 3.0 covers the ~5-6m wobble zone observed when the player is
-- navigating around a target that sits in or near fire: the
-- pathfinder's detour paths can leave the player at ~5m from the
-- target for several seconds while they work around the final
-- approach.  Previously 1.5, which only covered a ~3m exclusion
-- zone and fired a false "Path blocked" at 4.91m on the Mind
-- Flayer Pod approach.
local GPS_STUCK_CLOSE_RANGE_PAD = 3.0

-- Consecutive clean-path ticks required before the reroute
-- announcement fires.  Guards against single-tick probe jitter
-- where the hazard scan transiently misses a fire tile even
-- though the path is unchanged and still crosses it.  3 ticks at
-- 300ms = ~0.9s of stable clean state -- short enough that a real
-- reroute still announces promptly, long enough that scan noise
-- doesn't trigger false positives.
local GPS_REROUTE_STABILITY_TICKS = 3

-- Consecutive no-path ticks required before auto-cancelling
-- tracking.  10 ticks * 300ms = 3.0 seconds of consistent "no
-- route" from the pathfinder before we give up.  Short enough
-- that the player is not left wondering why GPS is dead, long
-- enough that transient navmesh hiccups (a party member briefly
-- blocking every route) do not falsely cancel a valid target.
local GPS_NO_PATH_CANCEL_TICKS = 10

-- Proximity mode (Exploration tier announcements).
--
-- Two tiers drive the streaming speech in Exploration mode:
--
-- Tier 1 -- "Within reach" (<= GPS_PROXIMITY_TIER1_ENTER_M).
--   When any important entity enters this ring, speak its name
--   only (no distance, no clock -- you are already right next to
--   it).  The entity is latched so it does not repeat until it
--   exits GPS_PROXIMITY_TIER1_EXIT_M (hysteresis buffer prevents
--   jitter re-announcements from small position drift).
--
-- Tier 2 -- "On approach" (between tier 1 enter and
--   GPS_PROXIMITY_TIER2_ENTER_M).  When an important entity first
--   enters the 8m ring, speak "Name. N meters. H o'clock." once.
--   Latched until it exits GPS_PROXIMITY_TIER2_EXIT_M so walking
--   away and coming back re-announces.
--
-- Any entity beyond tier 2 is silent in the speech stream.  The
-- full 30m scan still feeds the Routing mode entity list, but
-- proximity mode does not stream beyond 8m.  Pre-tier values
-- (GPS_PROXIMITY_MAX, GPS_PROXIMITY_MOVEMENT) are gone -- the
-- new model has no "max per cycle" because each tier latch
-- limits firing to actual transitions, not a fixed budget.
local GPS_PROXIMITY_TIER1_ENTER_M = 3.0
local GPS_PROXIMITY_TIER1_EXIT_M  = 5.0
local GPS_PROXIMITY_TIER2_ENTER_M = 8.0
local GPS_PROXIMITY_TIER2_EXIT_M  = 12.0

-- Entity scanning.
local ENTITY_SCAN_RADIUS      = 50    -- meters for entity scanning
local ENTITY_SCAN_MOVEMENT    = 3.0   -- meters before rescanning

-- Movement threshold for the proximity poller to run at all.
-- Previously GPS_PROXIMITY_MOVEMENT; kept as its own constant so
-- the proximity poll rate is decoupled from the scan rate.  At
-- 2m we get frequent enough latch updates to catch transitions
-- without running the whole scanner on every 300ms tick.
local GPS_PROXIMITY_POLL_M    = 2.0

-- Timing (milliseconds).
local POSITION_CHECK_MS       = 300   -- between position checks

-- GPS mode constants.  RS Left cycles Off -> Exploration -> Routing -> Off.
local GPS_MODE_OFF            = "off"
local GPS_MODE_EXPLORATION    = "exploration"
local GPS_MODE_ROUTING        = "routing"

-- Minimum distance to include an entity in scan results.
-- Filters out inventory items (worn/carried) which share the player's
-- position, and the player entity itself.
local ENTITY_MIN_DISTANCE     = 1.0

-- Clock direction: 30 degrees per hour.
local DEGREES_PER_CLOCK_HOUR  = 30

-- Entity category names (order matches D-pad left/right cycling).
-- Entity category names (order matches D-pad left/right cycling).
-- The list is also the canonical lookup for which categories exist;
-- CategoriseEntity MUST return one of these names or nil.  Landing
-- position on first entry to the entity list is index 1 (NPCs).
-- Empty categories stay in the cycle order and say "None" when
-- visited rather than auto-skipping.
local CATEGORY_NAMES          = {
    "Companions",     -- party members (alive/downed/dead) - DISTANCE-UNBOUNDED
    "NPCs",           -- alive non-party characters
    "Doors",          -- doors, hatches, traversal
    "Containers",     -- chests, crates, pods, corpses, lootables
    "Quest items",    -- items flagged as story/quest-relevant
    "Consumables",    -- potions, scrolls, grenades, utility
    "Food",           -- trivial-heal consumables (<=3 HP)
    "Herbs",          -- alchemy ingredients (harvestable plants)
    "Equipment",      -- weapons, armor, wearables with a slot
    "Loot",           -- valuables (gold value >= threshold)
    "Books and keys", -- readable / letter / prayer / key items
    "Miscellaneous",  -- fallback for anything else (scenery, props)
}

-- ============================================================================
-- State
-- ============================================================================

-- GPS state.
local gpsMode                = GPS_MODE_OFF  -- RS-Left cycles Off/Exploration/Routing
local trackingTarget         = nil    -- {handle, name, position, entity}
local autoWalkActive         = nil    -- {targetName, targetPosition} while engine-driven walk in flight
local currentPath            = nil    -- array of {[1]=x, [2]=y, [3]=z}
local lastPlayerPosition     = nil
local lastGuidancePosition   = nil
local lastDistanceToTarget   = nil

-- Proximity alert state.
-- Two per-tier latch sets drive hysteresis-based announcement
-- behavior.  An entity handle in tier1Latched means "we already
-- announced this entity at tier 1 (< 3m) and it has not yet
-- moved outside 5m"; it stays latched until its distance exceeds
-- GPS_PROXIMITY_TIER1_EXIT_M, at which point it is removed and
-- becomes eligible for re-announcement on the next entry.
-- Tier 2 works identically with the tier 2 enter/exit distances.
-- Reset at all tracking / mode / state teardown sites alongside
-- the other latch state.
local lastProximityPosition  = nil
local lastProximityUpdateMs  = 0      -- throttle: ms timestamp of last
                                       -- ProcessProximityUpdate call.
                                       -- Hard ceiling so post-combat
                                       -- chaos (cluster of dead bodies
                                       -- + active char moving + classify
                                       -- responses arriving in bursts)
                                       -- can't pile per-tick proximity
                                       -- iteration onto the render thread
                                       -- and stall the game.
local tier1Latched           = {}     -- {entityKey = true}
local tier2Latched           = {}     -- {entityKey = true}

-- Stuck detection state.  Reset on target change / progress.
local stuckTickCount         = 0
local stuckLastDistance      = nil
-- Latch flag: once we speak "Path blocked" we do not repeat the
-- announcement until the player starts making progress again.
local blockedAnnounced       = false
-- Hazard announcement latch: once we warn about a hazard on the
-- upcoming path we do not re-warn on every tick.  Stores the label
-- of the hazard we most recently warned about (nil when no warning
-- is active) so we can use that label in the follow-up "Rerouting
-- around X" announcement when the hazard disappears from the path.
-- Acts as a boolean (nil vs non-nil) for latch purposes.
local lastHazardAnnouncedLabel = nil
-- Sum of XZ distances between consecutive nodes of the path from
-- the previous UpdateTrackingState tick.  Used to distinguish a
-- reroute (path length roughly unchanged or longer, because the
-- new path detours around a hazard) from the player walking past
-- an unavoidable hazard (path length drops because they covered
-- ground).  Reset on target change / tracking teardown.
local lastPathLength         = 0
-- Consecutive-tick stability counter for reroute detection.  Only
-- when the full-path hazard scan has returned clean for
-- GPS_REROUTE_STABILITY_TICKS ticks in a row do we announce
-- "Rerouting around X" -- single-tick jitter in the probe sampling
-- (which does happen; probe ring offsets shift as the player moves,
-- and occasional ticks miss the fire edge even when the path is
-- unchanged) no longer fire false reroute announcements.
local hazardClearTickCount   = 0
-- Dedup latch for the dev-visibility detour log.  Stores the
-- hazard label we most recently logged a silent-detour message
-- about so repeated per-tick detections of the same hazard do not
-- spam the log.  Cleared when the straight-line scan comes up
-- clean (no hazard) OR when the label changes to something else
-- (e.g. Fire -> Acid on a different nearby puddle).  Reset on
-- target change / tracking teardown along with the other hazard
-- tracking state.
local lastLoggedDetourLabel  = nil
-- Tracks previous-tick path availability so we can detect the
-- had-path -> no-path transition (to log and speak a single "no
-- path" message) and the no-path -> had-path transition (to drop
-- the noPathAnnounced latch).
local pathWasAvailable       = false
local noPathAnnounced        = false
-- Consecutive-tick counter for the no-path auto-cancel feature.
-- Increments on every tick where RecalculatePath returns nil,
-- resets to 0 whenever a path is found.  When this exceeds
-- GPS_NO_PATH_CANCEL_TICKS, tracking auto-tears-down and returns
-- to Exploration mode so the player does not have to cycle the
-- GPS manually when their target becomes unreachable.
local noPathTickCount        = 0
-- Number of position-check ticks since the current tracking
-- session started.  Used to gate stuck detection for the first few
-- ticks so the player gets time to react and push the stick before
-- we declare them stuck.
local trackingTicks          = 0
-- Position-check ticks before stuck detection becomes active.
-- 4 ticks * 300ms = 1.2 seconds of grace before stuck can fire.
local GPS_STUCK_GRACE_TICKS  = 4

-- Entity scanning state.
local scannedCategories      = {}     -- {NPCs={...}, Doors={...}, ...}
local lastScanPosition       = nil
-- Set of entityKey strings (tostring(entity)) for entities discovered
-- by ScanEntities's PartyView pass as party members.  Reset each scan,
-- consumed by CategoriseEntity to route those entries to the
-- Companions category.  Necessary because per-entity
-- GetEntityComponent("PartyMember") probes have been observed to
-- return nil in some game states (e.g. immediately after level load,
-- or for downed members in certain phases) even when the engine
-- canonical roster (PartyView.Characters) still lists them.
local partyMemberHandleSet   = {}

-- Entity list state.
local entityListOpen         = false
local currentCategoryIndex   = 1      -- index into CATEGORY_NAMES
local currentItemIndex       = 1      -- index into current category

-- Routing-mode instructional hint gate.  Set to true on the first
-- entry into Routing mode (via OpenEntityList).  Subsequent entries
-- during the same gameplay session speak only the brief mode +
-- landing announcement, not the full instructional tutorial.
-- Reset to false in ResetState, which is hooked to GameStateChanged
-- -- so a fresh save load or campaign restart replays the hint.
-- Matches the radialHintSpoken pattern in WorldUI.lua.
-- TODO settings hook: gate this on BG3Access.Settings.hintsEnabled
-- when the settings module exists.
local routingHintSpoken      = false

-- Tick timing.
local lastPositionCheckTime  = 0

-- ============================================================================
-- Server-side Template Data Cache
-- ============================================================================
--
-- Classification-relevant fields from entity templates, fetched
-- from the server via net message.  The server has access to all
-- template banks (root, local, cache, local cache) while the
-- client can only see root templates.  Level-local templates (the
-- ones most in-world entities use) are server-only.
--
-- Populated by RequestTemplateData (sends GUIDs to the server)
-- and the CHANNEL_RESPONSE net listener (receives and caches the
-- server's response).  Cleared on GameStateChanged via ResetState.
--
-- Cache format: templateDataCache[guidString] = {
--   CanBePickedUp      = bool,
--   StoryItem          = bool,
--   IsKey              = bool,
--   IsPortal           = bool,
--   IsTrap             = bool,
--   Hostile            = bool,
--   TreasureOnDestroy  = bool,
--   IsSourceContainer  = bool,
--   InventoryType      = string,
--   BookType           = string,
--   InventoryListCount = number,
--   Stats              = string,
--   UseActionCount     = number,
--   TemplateName       = string,
-- }

local CLASSIFY_CHANNEL_REQUEST  = "BG3Access_ClassifyRequest"
local CLASSIFY_CHANNEL_RESPONSE = "BG3Access_ClassifyResponse"

local entityClassifyCache    = {}  -- entityUuid -> {fields}
local classifyRequestPending = false

--- Request entity classification data from the server for a
--- batch of entity UUIDs.  The server looks up each entity,
--- checks its components (InventoryOwner, CanBeLooted, etc.),
--- reads its template and stats fields, and sends everything
--- back in one response.
local function RequestEntityClassification(uuids)
    if not uuids or #uuids == 0 then return end
    classifyRequestPending = true
    local payload = Ext.Json.Stringify(uuids)
    Log.Info(string.format(
        "Classify request: sending %d UUIDs to server", #uuids))
    pcall(Ext.ClientNet.PostMessageToServer,
        CLASSIFY_CHANNEL_REQUEST, payload)
end

--- Look up cached classification data for an entity by UUID.
--- Returns the cached field table, or nil on cache miss.
local function GetCachedEntityData(entity)
    local ok, result = pcall(function()
        local uuidComp = entity.Uuid
        if not uuidComp then return nil end
        local uuid = tostring(uuidComp.EntityUuid)
        if uuid == "" or uuid == "nil" then return nil end
        return entityClassifyCache[uuid]
    end)
    if ok then return result end
    return nil
end

-- Raw scanned entities before classification.  Populated by
-- ScanEntities (Phase 1), consumed by ClassifyScannedEntities
-- (Phase 2).  Declared here (before the net listener) so the
-- listener closure captures the local.  Must be in scope before
-- Ext.RegisterNetListener runs.
local scannedEntitiesRaw = {}

-- Forward declaration for ClassifyScannedEntities so the net
-- listener closure below can call it.  The implementation lives
-- further down in the Entity Scanning section.
local ClassifyScannedEntities

--- Net message listener: receives template data from the server,
--- populates the cache, and re-runs classification on the raw
--- scanned entities so categories are now based on authoritative
--- template data instead of heuristic fallbacks.
Ext.RegisterNetListener(CLASSIFY_CHANNEL_RESPONSE,
    function(channel, payload, userId)
        local ok, results = pcall(Ext.Json.Parse, payload)
        if not ok or type(results) ~= "table" then
            Log.Info("Classify response: bad payload")
            classifyRequestPending = false
            return
        end
        local count = 0
        for uuid, fields in pairs(results) do
            entityClassifyCache[uuid] = fields
            count = count + 1
        end
        classifyRequestPending = false
        Log.Info(string.format(
            "Classify response: cached %d entities, "
                .. "re-classifying", count))

        -- Re-classify with the server-provided data.
        if #scannedEntitiesRaw > 0 then
            ClassifyScannedEntities()
        end
    end)

-- ============================================================================
-- Math Utilities
-- ============================================================================

local function DistanceSquaredXZ(positionA, positionB)
    local deltaX = positionA[1] - positionB[1]
    local deltaZ = positionA[3] - positionB[3]
    return deltaX * deltaX + deltaZ * deltaZ
end

local function DistanceXZ(positionA, positionB)
    return math.sqrt(DistanceSquaredXZ(positionA, positionB))
end

--- Perpendicular distance from a point to a line segment in the XZ
--- plane.  Standard point-to-segment formula: project the point
--- onto the segment, clamp the parameter to [0,1] so the closest
--- point is an endpoint when the projection falls outside the
--- segment, then measure the distance to that clamped point.
local function PointToSegmentDistanceXZ(point, segmentStart, segmentEnd)
    local segDeltaX = segmentEnd[1] - segmentStart[1]
    local segDeltaZ = segmentEnd[3] - segmentStart[3]
    local segLengthSquared = segDeltaX * segDeltaX
        + segDeltaZ * segDeltaZ
    if segLengthSquared == 0 then
        -- Degenerate: segment is a point.
        return DistanceXZ(point, segmentStart)
    end
    local projectionParameter =
        ((point[1] - segmentStart[1]) * segDeltaX
            + (point[3] - segmentStart[3]) * segDeltaZ)
        / segLengthSquared
    if projectionParameter < 0 then projectionParameter = 0 end
    if projectionParameter > 1 then projectionParameter = 1 end
    local closestX = segmentStart[1]
        + projectionParameter * segDeltaX
    local closestZ = segmentStart[3]
        + projectionParameter * segDeltaZ
    local diffX = point[1] - closestX
    local diffZ = point[3] - closestZ
    return math.sqrt(diffX * diffX + diffZ * diffZ)
end

--- Minimum distance from a point to any segment of a path (the
--- "how far off the path is this point" metric).  Returns
--- math.huge when the path is empty.  Used by the path-commitment
--- gate in RecalculatePath to decide whether the current path is
--- still serving the player or whether A* needs a fresh answer.
local function MinDistanceToPath(point, path)
    if not path or #path == 0 then return math.huge end
    if #path == 1 then return DistanceXZ(point, path[1]) end
    local minDistance = math.huge
    for nodeIndex = 1, #path - 1 do
        local dist = PointToSegmentDistanceXZ(
            point, path[nodeIndex], path[nodeIndex + 1])
        if dist < minDistance then minDistance = dist end
    end
    return minDistance
end

--- Project a point onto the nearest segment of a path, and return
--- the information forward-traversal accumulators need:
---   nextNodeIndex   = index of the node immediately forward of
---                     the projection (the first node "ahead" of
---                     the player along the path).
---   distanceForward = path-distance from the projection to
---                     path[nextNodeIndex].  Used as the initial
---                     pathDistanceAccum for forward scans.
---
--- This replaces the older "start accumulating from
--- DistanceXZ(player, path[1])" approach, which inflated the
--- accumulator by the distance the player had walked PAST node 1
--- -- for a fixed downstream bend, the reported "turn in N meters"
--- grew as the player walked toward the bend instead of shrinking,
--- because the backward distance to node 1 kept adding up.
---
--- Returns nil, 0 when the path is empty or a single node (caller
--- should handle those edge cases separately).
local function GetForwardPathStart(playerPosition, path)
    if not path or #path == 0 then return nil, 0 end
    if #path == 1 then
        return 1, DistanceXZ(playerPosition, path[1])
    end

    local nearestSegmentIndex = 1
    local nearestDistance = math.huge
    for segmentIndex = 1, #path - 1 do
        local segmentDistance = PointToSegmentDistanceXZ(
            playerPosition,
            path[segmentIndex], path[segmentIndex + 1])
        if segmentDistance < nearestDistance then
            nearestDistance = segmentDistance
            nearestSegmentIndex = segmentIndex
        end
    end

    local segmentStart = path[nearestSegmentIndex]
    local segmentEnd   = path[nearestSegmentIndex + 1]
    local segmentDeltaX = segmentEnd[1] - segmentStart[1]
    local segmentDeltaZ = segmentEnd[3] - segmentStart[3]
    local segmentLengthSquared = segmentDeltaX * segmentDeltaX
        + segmentDeltaZ * segmentDeltaZ
    local parameter = 0
    if segmentLengthSquared > 0 then
        parameter =
            ((playerPosition[1] - segmentStart[1]) * segmentDeltaX
            + (playerPosition[3] - segmentStart[3]) * segmentDeltaZ)
            / segmentLengthSquared
        if parameter < 0 then parameter = 0 end
        if parameter > 1 then parameter = 1 end
    end
    local projectionX = segmentStart[1] + parameter * segmentDeltaX
    local projectionZ = segmentStart[3] + parameter * segmentDeltaZ
    local distanceForward = math.sqrt(
        (segmentEnd[1] - projectionX)
            * (segmentEnd[1] - projectionX)
        + (segmentEnd[3] - projectionZ)
            * (segmentEnd[3] - projectionZ))

    return nearestSegmentIndex + 1, distanceForward,
        projectionX, projectionZ
end

local function BearingXZ(fromPosition, toPosition)
    local deltaX = toPosition[1] - fromPosition[1]
    local deltaZ = toPosition[3] - fromPosition[3]
    return math.atan(deltaX, deltaZ)
end

local function RadiansToClockHour(angleRadians)
    local degrees = (angleRadians * 180 / math.pi) % 360
    if degrees < 0 then degrees = degrees + 360 end
    local hour = math.floor(degrees / DEGREES_PER_CLOCK_HOUR + 0.5) % 12
    if hour == 0 then hour = 12 end
    return hour
end

-- ============================================================================
-- Entity Utilities
-- ============================================================================

-- Component shorthands verified from bg3se-SR source.  Names that
-- aren't registered ExtComponentType enum labels (e.g. "IsPlayer",
-- "PlayerController") fail GetAllEntitiesWithComponent with a pcall
-- error and do nothing useful, so they're absent here.
--
--   ClientControl - eoc::ClientControlComponent (tag) - the active
--                   controlled character.  Tag is exclusive in normal
--                   play but BG3 leaves it on the corpse after a KO,
--                   which is why the alive-filter exists.
--   PartyMember   - eoc::party::MemberComponent - on every party
--                   member (UserId/UserUuid/Party/ViewUuid/IsPermanent).
--                   Persistent across alive/dead.  Reliable "any party
--                   member" anchor when ClientControl points at a corpse.
--   Player        - eoc::PlayerComponent (tag) - generic "is a player
--                   character" tag.  Last-resort fallback.
local PLAYER_COMPONENTS = {"ClientControl", "PartyMember", "Player"}

--- Returns true when the entity is alive (Hp > 0) or has no Health
--- component.  Used to filter out dead candidates in GetPlayerEntity.
---
--- After a party-member KO (Shadowheart dies in combat), BG3 leaves
--- ClientControl lingering on the dead entity rather than atomically
--- moving it to a surviving party member.  IsPlayer and
--- PlayerController also stay on the corpse.  GetAllEntitiesWithComponent
--- then returns [DeadShadowheart] for ClientControl and
--- [Tav, DeadShadowheart] (or the reverse) for IsPlayer/
--- PlayerController -- order is insertion-time, undefined for our
--- purposes.  Without this filter, callers receive a corpse as
--- "the player", which:
---   - HUD reader reports HP 0/10 with the active character's name
---     (HP from the corpse, name from the PartyLine widget which
---     reflects who actually has input control).
---   - AutoWalk dispatches CharacterMoveTo using the corpse's UUID;
---     the engine refuses (dead can't walk) so nothing moves.
---   - Entity scan uses the corpse's position as the player anchor;
---     the corpse self-filters from its own result via
---     ENTITY_MIN_DISTANCE (it sits at distance 0 from itself), so
---     looting the dead party member becomes impossible.
local function IsEntityAlive(entity)
    if not entity then return false end
    local ok, alive = pcall(function()
        local health = entity.Health
        if not health then return true end
        local hp = tonumber(health.Hp) or 0
        return hp > 0
    end)
    if not ok then return false end
    return alive
end

local function GetPlayerEntity()
    -- Try each component in order, preferring an alive candidate
    -- over a dead one.  ClientControl is checked first because in
    -- normal play it's the authoritative "active character" marker;
    -- IsPlayer / PlayerController are fallbacks for the rare cases
    -- (loading transitions, post-KO frames) where ClientControl
    -- returns nothing or a dead entity.
    for _, componentName in ipairs(PLAYER_COMPONENTS) do
        local ok, candidates = pcall(
            Ext.Entity.GetAllEntitiesWithComponent, componentName)
        if ok and candidates then
            for _, candidate in ipairs(candidates) do
                if IsEntityAlive(candidate) then
                    return candidate
                end
            end
        end
    end
    -- All candidates dead (party wipe) or none returned.  Fail
    -- closed -- callers handle nil with "No character" speech rather
    -- than acting on a corpse.
    return nil
end

--- Materialize a vec3 userdata into a plain Lua table {x, y, z}.
--- BG3SE vec3 from entity components are userdata; Ext.Math.Sub
--- with a zero vector converts them into indexable tables.
local ZERO_VEC = {0, 0, 0}

local function MaterializeVec3(vec3Userdata)
    return Ext.Math.Sub(vec3Userdata, ZERO_VEC)
end

--- Get an entity's world position as a plain {x, y, z} table.
--- Path: entity.Transform.Transform.Translate (TransformComponent
--- contains a Transform struct whose Translate field is the vec3).
local function GetEntityPosition(entity)
    local ok, result = pcall(function()
        if not entity or not entity.Transform then return nil end
        local translate = entity.Transform.Transform.Translate
        local x, y, z = translate[1], translate[2], translate[3]
        if not x or not z then return nil end
        return {x, y or 0, z}
    end)
    if ok then return result end
    return nil
end

local function GetCameraEntity()
    local ok, cameras = pcall(
        Ext.Entity.GetAllEntitiesWithComponent, "GameCameraBehavior")
    if ok and cameras and #cameras > 0 then
        return cameras[1]
    end
    return nil
end

--- Check if the player entity is in turn-based combat.
--- In combat the left stick moves a targeting cursor, not the character,
--- so GPS pathfinding and navigation are meaningless.
---
--- CombatParticipant always exists on player characters.  Outside combat
--- CombatHandle is nil and InitiativeRoll is -100.  In active combat
--- CombatHandle is a non-nil Entity userdata.
local function IsInCombat(playerEntity)
    if not playerEntity then return false end
    local ok, inCombat = pcall(function()
        local participant = playerEntity.CombatParticipant
        if not participant then return false end
        return participant.CombatHandle ~= nil
    end)
    return ok and inCombat
end

--- Resolve a TranslatedString to a plain Lua string.
--- TranslatedString userdata has .Handle.Handle containing the loca key.
local function ResolveTranslatedString(translatedString)
    if not translatedString then return nil end
    if type(translatedString) == "string" then
        return Helpers.GetTranslatedStringIfHandle(translatedString)
    end
    -- TranslatedString userdata: dig into .Handle.Handle for the key.
    local handle = nil
    pcall(function()
        handle = translatedString.Handle.Handle
    end)
    if handle then
        return Helpers.GetTranslatedStringIfHandle(handle)
    end
    return nil
end

-- Names starting with "%%%" are Larian's internal debug/placeholder
-- markers for scripted entities (spawn points, effect owners, dev leaks)
-- that were never meant to be player-facing.  Returning nil here makes
-- ScanAndCategorise skip the entity entirely.
--
-- "Object" is the generic fallback display name BG3 assigns when an
-- entity has no authored DisplayName.  It's always noise in a scan
-- result -- if the entity isn't important enough to have a name, it's
-- not important enough to announce.
local function IsPlaceholderName(resolvedName)
    if type(resolvedName) ~= "string" then return true end
    if resolvedName:sub(1, 3) == "%%%" then return true end
    if resolvedName == "Object" then return true end
    return false
end

local function GetEntityDisplayName(entity)
    local ok, name = pcall(function()
        if not entity.DisplayName then return nil end
        local resolved = ResolveTranslatedString(entity.DisplayName.Name)
        if resolved and resolved ~= ""
            and not IsPlaceholderName(resolved) then
            return resolved
        end
        resolved = ResolveTranslatedString(entity.DisplayName.NameKey)
        if resolved and resolved ~= ""
            and not IsPlaceholderName(resolved) then
            return resolved
        end
        return nil
    end)
    if ok then return name end
    return nil
end

-- ============================================================================
-- Camera Reference Angle and Clock Direction
-- ============================================================================

local function GetCameraReferenceAngle(playerPosition)
    local cameraEntity = GetCameraEntity()
    if not cameraEntity then return nil end
    local cameraPosition = GetEntityPosition(cameraEntity)
    if not cameraPosition then return nil end
    return BearingXZ(cameraPosition, playerPosition)
end

local function ComputeClockDirection(playerPosition, targetPosition)
    local referenceAngle = GetCameraReferenceAngle(playerPosition)
    if not referenceAngle then return nil, nil end
    local targetBearing = BearingXZ(playerPosition, targetPosition)
    local relativeAngle = targetBearing - referenceAngle
    local clockHour = RadiansToClockHour(relativeAngle)
    local distance = DistanceXZ(playerPosition, targetPosition)
    return clockHour, distance
end

-- 8-point cardinal compass for proximity announcements.  Unlike
-- ComputeClockDirection (camera-relative -- "12 o'clock = where the
-- camera faces right now"), this is WORLD-relative -- "north" stays
-- north regardless of which way the camera is rotated.  Used by the
-- exploration-mode proximity tier announcements to give the user a
-- stable sense of where things are on the map, separate from the
-- steering directions clock-face provides for routing/target speech.
--
-- World axis convention: BearingXZ uses atan2(dx, dz) so 0 radians
-- points along +Z.  We treat +Z as "north" and clockwise from there
-- (E at 90 degrees, S at 180, W at 270) -- matches BG3's minimap
-- orientation in most areas observed.  If a future area's map turns
-- out to be flipped, swap the labels here, not the math.
local CARDINAL_LABELS = {
    "north", "northeast", "east", "southeast",
    "south", "southwest", "west", "northwest",
}

local function ComputeCardinalDirection(playerPosition, targetPosition)
    local targetBearing = BearingXZ(playerPosition, targetPosition)
    -- Convert radians to degrees normalized to [0, 360).
    local degrees = (targetBearing * 180 / math.pi) % 360
    if degrees < 0 then degrees = degrees + 360 end
    -- Quantize into 8 buckets of 45 degrees each.  Add half a
    -- bucket (22.5 deg) before flooring so a target at exactly 22.5
    -- degrees reads as NE instead of N -- matches how compass
    -- needles snap to the nearest mark, not the previous one.
    local bucket = math.floor((degrees + 22.5) / 45) % 8
    return CARDINAL_LABELS[bucket + 1]
end

-- ============================================================================
-- Surface Hazard Detection
-- ============================================================================
--
-- The hazardous surface set is built at runtime from the game's own
-- data rather than hand-written.  Pipeline:
--
--   1. Ext.Template.GetAllRootTemplates() returns every GameObjectTemplate
--      in the global bank (characters, items, scenery, surfaces, ...).
--   2. SurfaceTemplate instances are identified by duck-typing: only
--      SurfaceTemplate has a .SurfaceType property (typed as the
--      SurfaceType enum value that Ext.Level.GetTileDebugInfo returns).
--      Source: BG3Extender/GameDefinitions/RootTemplates.h line 587,
--      "struct SurfaceTemplate : public GameObjectTemplate".
--   3. Each SurfaceTemplate has a .Statuses array of SurfaceStatusData
--      (StatusId, Remove, ApplyToCharacters, ...).  Source: same file,
--      line 569.
--   4. Each applied status is looked up via Ext.Stats.Get.  A status is
--      "harmful" if any of TickFunctors/OnApplyFunctors/OnRemoveFunctors
--      contains "DealDamage", or if StatusGroups contains "SG_Condition"
--      (the D&D 5e conditions bucket: Poisoned, Restrained, Frightened,
--      Incapacitated, Stunned, etc.), or if the stats name itself
--      contains damage/condition keywords (fallback for statuses that
--      use custom functors we can't parse).
--
-- Manual overrides below cover hazards that are not expressible as
-- SurfaceTemplate statuses -- notably Chasm (a navmesh gap, no template)
-- and Deepwater (drowning is a scripted mechanic).
--
-- The set builds lazily on first use because the template bank is not
-- populated until a level is loaded.  If the build fails (templates
-- unavailable, no surfaces found), we fall back to MANUAL_HAZARDS so
-- routing still protects against the obvious ones.

-- Surfaces that must always be treated as hazardous, even if no
-- matching SurfaceTemplate analysis flags them.  Kept small and
-- justified per-entry.  These labels correspond to Ext.Enums.SurfaceType.
local MANUAL_HAZARDS = {
    Chasm     = true,  -- no SurfaceTemplate; pure navmesh gap = fall
    Deepwater = true,  -- drowning is scripted, not a surface status
}

-- StatsFunctorId values that cause harm when they fire on a character.
-- DealDamage is the canonical damage call.  Kill outright kills the
-- target.  CreateSurface can spawn secondary damaging surfaces (used
-- by BlackPowder, Hellfire).  Sabotage breaks equipment.  Force
-- triggers knockback / fall damage.  Full StatsFunctorId enum lives
-- in BG3Extender/IdeHelpers/ExtIdeHelpers.lua line 1311.
local HARMFUL_FUNCTOR_IDS = {
    DealDamage    = true,
    Kill          = true,
    CreateSurface = true,
    Sabotage      = true,
}

-- D&D 5e condition status groups.  Status entries whose StatusGroups
-- bitmask includes any of these apply a hard debuff (Poisoned,
-- Restrained, Frightened, Incapacitated, Stunned, etc.).  Full enum
-- alias lives in ExtIdeHelpers.lua line 1319 (StatsStatusGroup).
local HARMFUL_STATUS_GROUPS = {
    "SG_Condition",
    "SG_Incapacitated",
    "SG_Stunned",
    "SG_Paralyzed",
    "SG_Petrified",
    "SG_Restrained",
    "SG_Unconscious",
    "SG_Prone",
    "SG_Frightened",
    "SG_Charmed",
    "SG_Dominated",
    "SG_Poisoned",
    "SG_Blinded",
    "SG_Sleeping",
    "SG_Exhausted",
    "SG_Cursed",
}

-- Lazy cache.  Starts nil; populated on first CheckPositionHazard call.
local hazardousSurfaceCache = nil

-- Per-tile A* cost penalty for hazardous surfaces, applied via
-- AiPath.SurfacePathInfluences in ApplyHazardAvoidance.  BG3's
-- CheckPlayerWeightCell (Ai.inl) has TWO cost branches:
--
--   Primary (tile center is on fire):
--     surfaceCost = 2 * Influence
--     For Influence=50000: 100000 per fire tile.
--
--   Fallback (tile center clean, nearby area has fire):
--     surfaceCost = Influence / 5
--     For Influence=50000: 10000 per adjacent-fire tile.
--
-- The fallback branch is the one that matters for "the character's
-- body grazes a fire edge while the centerline is technically
-- clean".  At Influence=9999 the fallback was only 1999, which
-- lost to any detour longer than ~2000 tiles -- the radial probe
-- was correctly catching the resulting grazing cases.  At 50000
-- the fallback is 10000, which beats any detour shorter than ~5km
-- (roughly 10000 tiles of real movement).  No realistic BG3 level
-- has a clean alternative that long, so adjacent-fire tiles will
-- be avoided whenever a clean corridor exists.
--
-- Overflow safety: AiPath.SurfacePathInfluences entries use int32
-- for Influence.  pathScore is int32 and accumulates across all
-- fire tiles on the candidate A* path.  At 50000 the per-tile
-- primary cost is 100000, so a path would need to cross ~21000
-- fire tiles (~10km of continuous fire at 0.5m tile spacing)
-- before pathScore overflows int32.  That is far beyond any BG3
-- level's worst case, so the 50000 value is safe for cumulative
-- scoring.  Higher values (500000+) approach the overflow ceiling
-- and can cause pathScore to flip negative in pathological cases,
-- which would turn avoidance into ATTRACTION -- deliberately
-- avoided.
--
-- DamagingSurfacesThreshold from stats ExtraData (35 in vanilla):
-- influences at or above the threshold incur the full per-tile
-- cost, influences below it are capped at 12.  50000 is well
-- above 35 so the cap never applies.
--
-- Tuning history:
--   500    -- original; too weak for fallback branch
--   9999   -- diagnostic bump; still too weak for fallback
--   500000 -- too strong; accumulation overflow risk
--   50000  -- current; strong enough to beat all realistic detours,
--             safe from int32 accumulation overflow
local GPS_HAZARD_INFLUENCE = 50000

-- Cached SurfacePathInfluences array derived from hazardousSurfaceCache.
-- Assigned to AiPath.SurfacePathInfluences on every TryPathfind call
-- so the native pathfinder routes around our hazards.  Built lazily
-- by GetHazardAvoidanceInfluences and cached once the underlying
-- hazard set has been built from a real template scan.
local hazardAvoidanceInfluences = nil

--- Ext.Enums.SurfaceType values may stringify to a label or to a
--- number depending on how the binding is generated.  Normalize to a
--- label string (e.g. "Fire") that we can compare across
--- GetTileDebugInfo results and SurfaceTemplate.SurfaceType.
local function SurfaceLabel(surfaceValue)
    if surfaceValue == nil then return nil end
    local asString = tostring(surfaceValue)
    if asString == "" or asString == "None" or asString == "0" then
        return nil
    end
    -- Numeric surface id: resolve against the enum table.
    if asString:match("^%d+$") then
        local numericId = tonumber(asString)
        local enumDef = Ext.Enums and Ext.Enums.SurfaceType
        if enumDef then
            for label, value in pairs(enumDef) do
                if type(label) == "string"
                    and tonumber(tostring(value)) == numericId then
                    return label
                end
            end
        end
        return nil
    end
    return asString
end

--- Walk a StatsFunctors object's FunctorList and return true if any
--- functor's TypeId is in HARMFUL_FUNCTOR_IDS.  Silently returns
--- false if the field is missing or can't be iterated.
local function FunctorListContainsHarm(statsFunctors)
    if not statsFunctors then return false end
    local okList, functorList = pcall(function()
        return statsFunctors.FunctorList
    end)
    if not okList or not functorList then return false end
    local okLen, listLength = pcall(function() return #functorList end)
    if not okLen or not listLength then return false end
    for functorIndex = 1, listLength do
        local okFunctor, functor = pcall(function()
            return functorList[functorIndex]
        end)
        if okFunctor and functor then
            local okTypeId, typeId = pcall(function()
                return tostring(functor.TypeId)
            end)
            if okTypeId and typeId and HARMFUL_FUNCTOR_IDS[typeId] then
                return true
            end
        end
    end
    return false
end

--- Probe a StatusGroupFlags bitmask for known-harmful group labels.
--- BG3SE's bitmask userdata may expose set labels via pairs iteration
--- (key=label, value=true) and/or stringify to a semicolon-joined
--- list.  Try both patterns; fall through to false if neither works.
local function StatusGroupsContainHarm(statusGroups)
    if not statusGroups then return false end

    -- Pattern 1: iterate as a table.  BG3SE bitmasks often expose
    -- active flags via __pairs.
    local found = false
    pcall(function()
        for key, value in pairs(statusGroups) do
            local label = nil
            if type(key) == "string" then
                label = key
            elseif type(value) == "string" then
                label = value
            end
            if label then
                for _, harmfulLabel in ipairs(HARMFUL_STATUS_GROUPS) do
                    if label == harmfulLabel then
                        found = true
                        return
                    end
                end
            end
        end
    end)
    if found then return true end

    -- Pattern 2: bitmask stringifies to a list of labels.
    local okString, asString = pcall(tostring, statusGroups)
    if okString and type(asString) == "string" and asString ~= "" then
        for _, harmfulLabel in ipairs(HARMFUL_STATUS_GROUPS) do
            if asString:find(harmfulLabel, 1, true) then
                return true
            end
        end
    end
    return false
end

--- Check whether a StatsObject for a status applies any damaging or
--- debilitating effect to the character it lands on.  Traces the
--- same data the game evaluates when the status fires: the stats
--- functor lists (TickFunctors/OnApplyFunctors/OnRemoveFunctors),
--- the TooltipDamage string, and the StatusGroups bitmask.
local function IsHarmfulStatus(statusId)
    if not statusId or statusId == "" then return false end
    local ok, statEntry = pcall(Ext.Stats.Get, statusId)
    if not ok or not statEntry then return false end

    -- 1. Functor lists: any DealDamage / Kill / CreateSurface /
    -- Sabotage means the status actively harms the character.
    local functorFieldNames = {
        "TickFunctors",
        "OnApplyFunctors",
        "OnRemoveFunctors",
        "OnApplySuccess",
        "OnApplyFail",
    }
    for _, fieldName in ipairs(functorFieldNames) do
        local okRead, functorsObject = pcall(function()
            return statEntry[fieldName]
        end)
        if okRead and FunctorListContainsHarm(functorsObject) then
            return true
        end
    end

    -- 2. TooltipDamage: plain string set on damaging statuses.
    -- BURNING has TooltipDamage="DealDamage(1d4,Fire)" for example.
    local okTooltip, tooltipDamage = pcall(function()
        return statEntry.TooltipDamage
    end)
    if okTooltip and type(tooltipDamage) == "string"
        and tooltipDamage ~= "" then
        return true
    end

    -- 3. StatusGroups bitmask: D&D condition memberships.
    local okGroups, statusGroups = pcall(function()
        return statEntry.StatusGroups
    end)
    if okGroups and StatusGroupsContainHarm(statusGroups) then
        return true
    end

    return false
end

--- Determine the SurfaceType label for a given SurfaceTemplate,
--- handling both enum userdata and raw number encodings.
local function SurfaceTemplateLabel(surfaceTemplate)
    local okRead, surfaceTypeValue = pcall(function()
        return surfaceTemplate.SurfaceType
    end)
    if not okRead or surfaceTypeValue == nil then return nil end
    return SurfaceLabel(surfaceTypeValue)
end

--- Walk all root templates and build the hazardous surface set.
--- Called lazily the first time a hazard check runs.  Returns a
--- table of {SurfaceLabel = true, ...}.  On failure, returns a copy
--- of MANUAL_HAZARDS so the rest of the system still functions.
--- Build the hazardous surface set.  Returns (resultTable, didScan)
--- where didScan is true only if at least one SurfaceTemplate was
--- inspected.  The caller uses didScan to decide whether to cache the
--- result: before a level loads the template bank is empty, so we
--- should keep retrying on each call until the real scan succeeds.
local function BuildHazardousSurfaceSet()
    local result = {}
    for label in pairs(MANUAL_HAZARDS) do result[label] = true end

    local okTemplates, allTemplates = pcall(
        Ext.Template.GetAllRootTemplates)
    if not okTemplates or not allTemplates then
        Log.Info("Hazard set: template bank unavailable, "
            .. "using manual overrides only (will retry)")
        return result, false
    end

    local surfaceTemplateCount = 0
    local hazardousCount = 0
    local inspectedStatuses = 0

    for _, template in pairs(allTemplates) do
        -- Duck-type SurfaceTemplate: only it exposes .SurfaceType.
        local label = SurfaceTemplateLabel(template)
        if label then
            surfaceTemplateCount = surfaceTemplateCount + 1
            local okStatuses, statusArray = pcall(function()
                return template.Statuses
            end)
            if okStatuses and statusArray then
                for statusIndex = 1, #statusArray do
                    local surfaceStatus = statusArray[statusIndex]
                    local applyToChars = false
                    local isRemoval = false
                    local statusId = nil
                    pcall(function()
                        applyToChars = surfaceStatus.ApplyToCharacters
                        isRemoval = surfaceStatus.Remove
                        statusId = tostring(surfaceStatus.StatusId)
                    end)
                    if applyToChars and not isRemoval and statusId then
                        inspectedStatuses = inspectedStatuses + 1
                        if IsHarmfulStatus(statusId) then
                            if not result[label] then
                                hazardousCount = hazardousCount + 1
                            end
                            result[label] = true
                            -- One harmful status is enough; stop
                            -- scanning this surface.
                            break
                        end
                    end
                end
            end
        end
    end

    if surfaceTemplateCount == 0 then
        Log.Info("Hazard set: 0 surface templates found "
            .. "(level not loaded yet?), will retry")
        return result, false
    end

    Log.Info(string.format(
        "Hazard set built: %d surface templates scanned, "
            .. "%d statuses inspected, %d surfaces flagged hazardous",
        surfaceTemplateCount, inspectedStatuses, hazardousCount))
    return result, true
end

--- Return the hazardous surface set, building it lazily on first use.
--- Only caches after a successful scan (template bank populated).
--- Before that, each call runs the build and returns the manual
--- overrides only, so as soon as the level finishes loading the next
--- hazard check picks up the full runtime set.
local function GetHazardousSurfaces()
    if hazardousSurfaceCache then return hazardousSurfaceCache end
    local result, didScan = BuildHazardousSurfaceSet()
    if didScan then
        hazardousSurfaceCache = result
    end
    return result
end

--- Build the AiPath.SurfacePathInfluences array that drives native
--- hazard avoidance during pathfinding.  Each SurfacePathInfluence
--- has three fields: SurfaceType (enum label string; the C++ binding
--- accepts labels directly and converts to the SurfaceType enum
--- underneath -- see CharacterComponentTests.lua), IsCloud (true for
--- the airborne half of the SurfaceType enum, 39..74 -- detected by
--- the "Cloud" suffix on the enum label, which every cloud type
--- uses and no ground type uses), and Influence (per-tile A* cost
--- penalty, see GPS_HAZARD_INFLUENCE).
---
--- Cached once the underlying hazardousSurfaceCache is populated so
--- we do not rebuild on every TryPathfind call.  Before the hazard
--- set settles (level not loaded yet), each call rebuilds from the
--- manual-hazard overrides and the result is not cached -- the next
--- call after the level loads will pick up the full set.
-- Hazards that show up in detection (so "Warning: X on route"
-- still fires) but are EXCLUDED from A* avoidance weighting.
-- These apply status effects or movement penalties but do not
-- damage the player, so routing the path around them generates
-- useless detours -- Deepwater especially, which sits along
-- most shorelines near quest targets and produced the "Detour,
-- bearing flip-flop" problem when the A* cost weighting fought
-- the player's desire to walk through it anyway.  Lethal
-- hazards (Fire, Lava, Poison, electrified water, clouds of
-- any kind) stay in the avoidance set.
local NON_AVOIDED_HAZARDS = {
    Deepwater = true,
}

local function GetHazardAvoidanceInfluences()
    if hazardAvoidanceInfluences then
        return hazardAvoidanceInfluences
    end

    local hazardSet = GetHazardousSurfaces()
    local influences = {}
    for hazardLabel in pairs(hazardSet) do
        if not NON_AVOIDED_HAZARDS[hazardLabel] then
            -- Cloud surfaces live in the 39..74 range of the
            -- SurfaceType enum and every label in that range ends
            -- in "Cloud" (WaterCloud, PoisonCloud, CloudkillCloud,
            -- FogCloud, ...).  No ground surface (1..38) uses the
            -- "Cloud" suffix, so checking the last five characters
            -- is sufficient to classify.  See
            -- BG3Extender/GameDefinitions/Enumerations/Stats.inl
            -- line 1393 (BEGIN_ENUM(SurfaceType)).
            local isCloud = hazardLabel:sub(-5) == "Cloud"
            table.insert(influences, {
                SurfaceType = hazardLabel,
                IsCloud = isCloud,
                Influence = GPS_HAZARD_INFLUENCE,
            })
        end
    end

    -- Mirror GetHazardousSurfaces' caching gate: only hold onto the
    -- derived influences once the hazard set itself has settled
    -- (real template scan succeeded, hazardousSurfaceCache non-nil).
    if hazardousSurfaceCache then
        hazardAvoidanceInfluences = influences
        -- Build a comma-separated list of the hazard labels so the
        -- log shows exactly which surfaces the pathfinder is told
        -- to avoid.  If "Fire" doesn't appear here, no amount of
        -- avoidance logic is going to route around fire -- that's
        -- the first thing to check when debugging a fire-step bug.
        local labels = {}
        for _, influence in ipairs(influences) do
            table.insert(labels, influence.SurfaceType)
        end
        table.sort(labels)
        Log.Info(string.format(
            "Hazard avoidance influences built: %d entries "
                .. "(influence=%d per tile): %s",
            #influences, GPS_HAZARD_INFLUENCE,
            table.concat(labels, ", ")))
    end
    return influences
end

--- Configure an AiPath to route AROUND hazardous surfaces during the
--- A* search.  Works by populating the path's SurfacePathInfluences
--- array and invoking AiPath:UsePlayerWeighting, which installs the
--- game's own CheckPlayerWeightCell function pointer into the path's
--- WeightFunc slot.  The weight function adds GPS_HAZARD_INFLUENCE to
--- the cost of every tile whose surface matches one of our entries,
--- so the pathfinder naturally detours up to ~500 tiles around a
--- hazard before it would willingly cross one.
---
--- Must be called BEFORE Ext.Level.FindPath -- the weight function is
--- consulted during the search, not after it.  Setting it afterward
--- has no effect.
---
--- UsePlayerWeighting internally skips surface influence weighting
--- when the source entity is in combat (UseSurfaceInfluences
--- = !inCombat in Ai.inl:255).  GPS runs in exploration, not combat,
--- so this is not a concern for us -- the influences are always
--- honoured.
---
--- Silent on failure.  Avoidance is a best-effort optimisation; the
--- path is still usable without it and FindPathHazard still catches
--- any hazard on the computed path so the warning speech still fires.
---
local function ApplyHazardAvoidance(aiPath)
    local intended = GetHazardAvoidanceInfluences()
    pcall(function()
        aiPath.SurfacePathInfluences = intended
        -- Args: avoidObstacles=true, avoidDynamics=true.  Mirrors
        -- what the game's own Move-To task uses for players out of
        -- combat, and keeps "avoid party members / barrels / dropped
        -- items" behaviour alongside the hazard weighting.
        aiPath:UsePlayerWeighting(true, true)
    end)
end

--- Return (true, hazardLabel) if the given world position sits on a
--- damaging ground or cloud surface, otherwise (false, nil).  Uses
--- Ext.Level.GetTileDebugInfo which reads the AiGrid's current tile
--- flags -- dynamic surfaces (Cloudkill, Grease on fire, Hellfire
--- puddles) show up here as soon as the game applies them.  Matches
--- against the runtime-built hazardous surface set (GetHazardousSurfaces),
--- not a hand-written list.
local function CheckPositionHazard(position)
    if not position then return false, nil end
    local ok, tile = pcall(Ext.Level.GetTileDebugInfo, position)
    if not ok or not tile then return false, nil end

    local hazardSet = GetHazardousSurfaces()
    local groundLabel = SurfaceLabel(tile.GroundSurface)
    if groundLabel and hazardSet[groundLabel] then
        return true, groundLabel
    end
    local cloudLabel = SurfaceLabel(tile.CloudSurface)
    if cloudLabel and hazardSet[cloudLabel] then
        return true, cloudLabel
    end
    return false, nil
end

-- Hazard-area probe radius for path scans.  BG3's character
-- MovingBound is ~0.5m for a Small/Medium character, meaning the
-- body clips tiles up to 0.5m away from the path centerline.  A
-- path that runs right next to a fire edge has all its nodes on
-- clean tiles but still burns the character as they walk past.
-- Probing a radius slightly larger than the bound catches those
-- grazing cases so FindPathHazard reports fire BEFORE the player
-- physically steps on it -- not when node 1 (their feet) finally
-- sits on a burning tile and the warning comes 0.0m too late.
-- Also helps with small fire patches that fall between path nodes
-- when path smoothing produces sparse node spacing.
local GPS_HAZARD_PROBE_RADIUS = 0.75

-- Inter-node sample spacing for path hazard scans.  Path smoothing
-- can leave segments with nodes >1m apart.  Rather than trust that
-- the 0.75m radius rings at each endpoint cover the gap, sample
-- along the segment at this interval between rings.  Each sample
-- still gets a full 0.75m radius probe, so the effective corridor
-- around the path is a sausage of radius 0.75m with no gaps.
local GPS_HAZARD_INTERNODE_SAMPLE_M = 0.75

-- Precomputed 8-point ring offsets (unit circle, 45 degree steps).
-- Scaled by GPS_HAZARD_PROBE_RADIUS when sampling.  Built once at
-- load time rather than recomputed per-call.  XZ only; Y is
-- inherited from the probe center (the character's walking plane).
local HAZARD_RING_OFFSETS = (function()
    local ringOffsets = {}
    for hour = 0, 7 do
        local angle = hour * math.pi / 4
        table.insert(ringOffsets, {
            math.cos(angle) * GPS_HAZARD_PROBE_RADIUS,
            math.sin(angle) * GPS_HAZARD_PROBE_RADIUS,
        })
    end
    return ringOffsets
end)()

--- Area-aware hazard probe: check the given position AND a ring of
--- 8 surrounding sample points at GPS_HAZARD_PROBE_RADIUS.  Returns
--- (true, label) for the first sample that hits a hazardous surface,
--- (false, nil) when the whole probe area is clean.  Catches fire
--- that clips the character's MovingBound even when the centerline
--- coordinate is on a safe tile -- without this, FindPathHazard can
--- only see hazards the path steps ON, not hazards the path walks
--- next to, and the warning always arrives too late.
local function CheckPositionHazardArea(position)
    if not position then return false, nil end

    -- Center sample first -- most paths are clean, so the center
    -- check short-circuits the ring scan on the common case.
    local centerHit, centerLabel = CheckPositionHazard(position)
    if centerHit then return true, centerLabel end

    -- Ring samples at the 8 cardinal + diagonal offsets.
    for offsetIndex = 1, #HAZARD_RING_OFFSETS do
        local offset = HAZARD_RING_OFFSETS[offsetIndex]
        local samplePosition = {
            position[1] + offset[1],
            position[2],
            position[3] + offset[2],
        }
        local hit, label = CheckPositionHazard(samplePosition)
        if hit then return true, label end
    end

    return false, nil
end

--- Human-readable hazard label for speech.  The enum labels are
--- PascalCase ("CloudkillCloud"); convert to "cloudkill cloud".
local function FormatHazardLabel(hazardLabel)
    if not hazardLabel then return "hazard" end
    local spaced = hazardLabel:gsub("(%l)(%u)", "%1 %2")
    return spaced:lower()
end

-- ============================================================================
-- Entity Scanning and Categorisation
-- ============================================================================

-- ============================================================================
-- Entity classification constants and helpers.
--
-- Classification uses a hybrid approach:
--   1. ECS components for quick, always-safe structural checks
--      (character? door? lootable? weapon? equipable? use-type?).
--   2. Stats attribute reads ONLY for Object-type items, and ONLY
--      for attributes known to exist on the Object modifier list
--      (InventoryTab, ObjectCategory, ItemUseType).  The safety
--      constraint: statEntry.ModifierList (a first-class property
--      that bypasses LuaStatGetAttribute) must return "Object"
--      before any attribute read is attempted.  Attributes that
--      are NOT on the Object schema (like UniqueID) are NEVER
--      read -- in debug builds, LuaStatGetAttribute triggers
--      se_assert -> abort() on unknown attributes, and pcall
--      cannot catch abort().
--
-- The game's own stats data (Public/Shared/Stats/Generated/Data/)
-- provides authoritative classification fields:
--   InventoryTab: "Consumable", "Magical", "BooksAndKeys",
--                 "Equipment", "Misc", "Auto"
--   ObjectCategory: "FoodCooked", "RottenFood", "Drink",
--                   "PreciousGem_*", "JunkArtificial", "JunkBio",
--                   "MagicScroll*", "Luxury", etc.
--   ItemUseType: "None", "Grenade", "Arrow", "Scroll", "Potion",
--                "Throwable", "Consumable"
-- ============================================================================

-- Gold value threshold above which an uncategorized item falls
-- into the Loot category rather than Miscellaneous.  Read from the
-- entity's ValueComponent.Value, which is a universal component
-- field available without stats probing.
local GPS_LOOT_GOLD_THRESHOLD = 10

--- Probe an entity for a specific component.  Returns the component
--- object when present, nil otherwise.  Wraps the GetComponent call
--- in pcall because some entity handles throw on certain component
--- name lookups.
local function GetEntityComponent(entity, componentName)
    local ok, component = pcall(
        entity.GetComponent, entity, componentName)
    if ok then return component end
    return nil
end

--- Check whether a character entity is dead / in a death state.
--- Corpses have CharacterComponent and are reachable, but they are
--- classified as Containers (you loot them), not NPCs (you talk to
--- them).  Returns true when the entity has a DeathState component,
--- which the game attaches to any character currently dead.
local function IsDeadCharacter(entity)
    local deathState = GetEntityComponent(entity, "DeathState")
    if deathState then return true end
    -- Fallback: some builds expose ServerDeathState.  Check both.
    local serverDeathState = GetEntityComponent(
        entity, "ServerDeathState")
    if serverDeathState then return true end
    return false
end

--- Safely read a field from an ECS component.  Returns (ok, value).
--- Component fields are plain C++ struct members exposed through
--- the property map; reading them does not go through the stats
--- attribute fallback and cannot trigger a se_assert abort.  Still
--- wrap in pcall so individual field reads that hit unexpected
--- types (e.g. a component that was torn down mid-frame) do not
--- propagate errors out of the classification loop.
local function SafeReadField(component, fieldName)
    if not component then return false, nil end
    local ok, value = pcall(function()
        return component[fieldName]
    end)
    if ok then return true, value end
    return false, nil
end

--- Determine the category for an entity.  Three-phase approach:
---
---   Phase 1 -- ECS structural checks (client-visible components).
---     Character detection (alive -> NPCs, dead -> Containers).
---     Door detection (IsDoor component).
---
---   Phase 2 -- Server-provided authoritative data.
---     The server cache contains entity component signals (has_*),
---     template fields, and stats classification fields.  This is
---     the definitive source for containers, items, equipment, etc.
---
---   Phase 3 -- Miscellaneous fallback.
---
--- Returns the category name or nil (scenery, filtered out).
--- Never returns nil for entities the server has classified;
--- nil only happens for scenery with no interaction or Health.
local function CategoriseEntity(entity, displayName)
    -- ================================================================
    -- Phase 1: ECS structural checks (client-visible).
    -- ================================================================

    -- Characters.  Try all character component names because
    -- visibility varies between entity types and client/server
    -- context.  Party members ALWAYS route to the Companions
    -- category (alive, downed, dead -- the user wants to find them
    -- regardless of state and regardless of distance, e.g. to walk
    -- back and revive a fallen companion).  Non-party dead chars
    -- become Containers (lootable corpses); non-party alive chars
    -- become NPCs.
    local isCharacter = GetEntityComponent(entity, "IsCharacter")
        or GetEntityComponent(entity, "ClientCharacter")
        or GetEntityComponent(entity, "ServerCharacter")
    if isCharacter then
        -- Party-member check first.  Two sources:
        --   1. partyMemberHandleSet -- populated each scan from
        --      PartyView.Characters (canonical engine roster).
        --      Reliable across all states.
        --   2. Per-entity GetEntityComponent("PartyMember") -- works
        --      in many cases but has been observed to return nil for
        --      entities the engine still considers party members
        --      (e.g. downed companions in certain game phases).
        -- Either source flagging the entity routes it to Companions.
        if partyMemberHandleSet[tostring(entity)] then
            return "Companions"
        end
        local partyMember = GetEntityComponent(entity, "PartyMember")
        if partyMember then return "Companions" end

        local isDead = false
        local health = GetEntityComponent(entity, "Health")
        if health then
            local okHp, hp = SafeReadField(health, "Hp")
            if okHp and type(hp) == "number" and hp <= 0 then
                isDead = true
            end
        end
        if not isDead then
            isDead = IsDeadCharacter(entity)
        end
        if isDead then return "Containers" end
        return "NPCs"
    end

    -- Doors (client-visible component).
    if GetEntityComponent(entity, "IsDoor") then
        return "Doors"
    end

    -- Portal / fast-travel marker fallback.  Some door-like
    -- entities (Ancient Door on the Nautiloid, fast-travel
    -- waypoints) don't have the IsDoor tag -- they're marked via
    -- client-only ecl::markers::AvailablePortalComponent and
    -- PortalCandidateComponent, which aren't exposed through
    -- Ext.Entity.GetComponent's named registry.  Scan the full
    -- component-name list for those markers; per-entity cost is
    -- a single call during classification (not per tick).
    local okComponentNames, componentNames = pcall(
        entity.GetAllComponentNames, entity, false)
    if okComponentNames and componentNames then
        for _, componentName in ipairs(componentNames) do
            local componentString = tostring(componentName)
            if componentString:find("AvailablePortal")
                or componentString:find("PortalCandidate") then
                return "Doors"
            end
        end
    end

    -- ================================================================
    -- Phase 2: Server-provided authoritative data.
    -- ================================================================

    local srvData = GetCachedEntityData(entity)
    if srvData then
        -- Also check server-side character signal (the server
        -- checks IsCharacter on the entity via GetAllComponents).
        if srvData.has_IsCharacter then
            local isDead = srvData.has_Death
                or srvData.has_DeathState
            if isDead then return "Containers" end
            return "NPCs"
        end

        -- Server-side door detection.
        if srvData.has_IsDoor then
            return "Doors"
        end

        -- Containers: has_InventoryOwner is the definitive signal.
        -- Every lootable container (chests, corpses, pods, barrels)
        -- has it; nothing else does.
        if srvData.has_InventoryOwner then
            return "Containers"
        end

        -- Quest items: StoryItem template flag.
        if srvData.StoryItem == true then
            return "Quest items"
        end

        -- Quest items: Value.Unique ECS fallback.
        local valueComponent = GetEntityComponent(entity, "Value")
        if valueComponent then
            local okUnique, isUnique = SafeReadField(
                valueComponent, "Unique")
            if okUnique and isUnique == true then
                return "Quest items"
            end
        end

        -- Herbs: stats name starts with CONS_Herbs_ (Mergrass,
        -- Belladonna, Daggerroot, Knotted Roots, etc.).  BG3's own
        -- UI places these in the "Misc" inventory tab, but for our
        -- routing category list they deserve their own bucket --
        -- the player cares whether a 20m-away Misc entry is a
        -- prayer book, a dirt mound, or a harvestable alchemy
        -- ingredient, and the stats-name prefix distinguishes
        -- them cleanly.
        if srvData.Stats
            and string.match(srvData.Stats, "^CONS_Herbs_") then
            return "Herbs"
        end

        -- Equipment: server-side Weapon or Equipable component,
        -- or stats InventoryTab = Equipment.
        if srvData.has_Weapon then
            return "Equipment"
        end
        if srvData.has_Equipable then
            return "Equipment"
        end

        -- Stats-based classification: the server reads
        -- InventoryTab / ObjectCategory / ItemUseType from the
        -- stats entry.  These are BG3's own authoritative fields
        -- that determine which UI tab an item lands in.
        local inventoryTab = srvData.StatsInventoryTab or ""
        local objectCategory = srvData.StatsObjectCategory or ""
        local itemUseType = srvData.StatsItemUseType or ""

        if inventoryTab == "Equipment" then
            return "Equipment"
        end

        if inventoryTab == "BooksAndKeys" then
            return "Books and keys"
        end

        if inventoryTab == "Consumable"
            or inventoryTab == "Magical" then
            if objectCategory:find("Food", 1, true)
                or objectCategory:find("Drink", 1, true)
                or objectCategory:find("Alcohol", 1, true)
                or objectCategory:find("Rotten", 1, true) then
                return "Food"
            end
            return "Consumables"
        end

        if itemUseType == "Grenade" or itemUseType == "Arrow"
            or itemUseType == "Scroll" or itemUseType == "Potion"
            or itemUseType == "Throwable" then
            return "Consumables"
        end

        if itemUseType == "Consumable" then
            if objectCategory:find("Food", 1, true)
                or objectCategory:find("Drink", 1, true)
                or objectCategory:find("Alcohol", 1, true)
                or objectCategory:find("Rotten", 1, true) then
                return "Food"
            end
            return "Consumables"
        end

        if inventoryTab == "Misc" then
            if objectCategory:find("PreciousGem", 1, true)
                or objectCategory:find("Luxury", 1, true) then
                return "Loot"
            end
            return "Miscellaneous"
        end

        -- Template flags: portals, keys, books.
        if srvData.IsPortal == true then
            return "Doors"
        end
        if srvData.IsKey == true then
            return "Miscellaneous"
        end
        if srvData.BookType and srvData.BookType ~= ""
            and srvData.BookType ~= "0" then
            return "Miscellaneous"
        end

        -- Loot via gold value (client-side Value component).
        if valueComponent then
            local okValue, itemValue = SafeReadField(
                valueComponent, "Value")
            if okValue and type(itemValue) == "number"
                and itemValue >= GPS_LOOT_GOLD_THRESHOLD then
                return "Loot"
            end
        else
            -- Value component not read yet, try now.
            local valComp = GetEntityComponent(entity, "Value")
            if valComp then
                local okValue, itemValue = SafeReadField(
                    valComp, "Value")
                if okValue and type(itemValue) == "number"
                    and itemValue >= GPS_LOOT_GOLD_THRESHOLD then
                    return "Loot"
                end
            end
        end

        -- Scenery filter: non-portable entities with no
        -- interaction actions and no Health component are pure
        -- scenery (chairs, pillars, decorations).  Filter out.
        -- Entities with Health are destructible (plants, breakable
        -- objects) and stay as Miscellaneous.
        local isPortable = srvData.CanBePickedUp == true
        if not isPortable
            and (not srvData.UseActionCount
                or srvData.UseActionCount == 0) then
            local health = GetEntityComponent(entity, "Health")
            if not health then
                return nil
            end
        end
    end

    -- ================================================================
    -- Phase 3: Fallback.
    -- ================================================================

    -- If the server cache hasn't arrived yet (first scan, request
    -- in flight), entities land here temporarily.  Once the server
    -- responds, ClassifyScannedEntities re-runs and moves them to
    -- the correct category using authoritative server data.
    return "Miscellaneous"
end

--- Returns true when the entity lives inside an inventory (container,
--- NPC pockets, player backpack, etc.).  The InventoryMember component
--- is attached by the game to every item that belongs to an inventory;
--- such items share the container's world position and are not
--- directly reachable by the player, so they must not appear in GPS
--- proximity or routing results.
local function IsInsideInventory(entity)
    local ok, memberComponent = pcall(
        entity.GetComponent, entity, "InventoryMember")
    return ok and memberComponent ~= nil
end

--- Phase 1: Scan nearby entities and store the raw list.  Does
--- NOT classify — that's Phase 2 (ClassifyScannedEntities).  The
--- separation lets us defer classification until the server-side
--- template cache is populated.
local function ScanEntities(playerPosition)
    scannedEntitiesRaw = {}
    -- Reset the party-member tag set each scan.  Populated by the
    -- second pass below from PartyView.Characters; consumed by
    -- CategoriseEntity to route entries to the Companions category
    -- even when per-entity PartyMember probes return nil.
    partyMemberHandleSet = {}
    local radiusSquared = ENTITY_SCAN_RADIUS * ENTITY_SCAN_RADIUS
    local minDistSquared = ENTITY_MIN_DISTANCE * ENTITY_MIN_DISTANCE
    local seenHandles = {}

    -- Component queries that work on the client.  ServerItem,
    -- ServerCharacter, and ItemTemplate all return 0 or error on
    -- the client -- removed.  GameObjectVisual covers items and
    -- scenery; IsCharacter and ClientCharacter cover NPCs and
    -- party members; IsDoor covers doors.
    local componentNames = {
        "ClientCharacter", "IsCharacter", "IsDoor",
        "GameObjectVisual",
    }
    for _, componentName in ipairs(componentNames) do
        local ok, entities = pcall(
            Ext.Entity.GetAllEntitiesWithComponent, componentName)
        if ok and entities then
            for _, entity in ipairs(entities) do
                local entityKey = tostring(entity)
                if not seenHandles[entityKey] then
                    seenHandles[entityKey] = true
                    if not IsInsideInventory(entity) then
                        local entityPosition = GetEntityPosition(entity)
                        if entityPosition then
                            local distSquared = DistanceSquaredXZ(
                                playerPosition, entityPosition)
                            if distSquared >= minDistSquared
                                and distSquared <= radiusSquared then
                                local displayName =
                                    GetEntityDisplayName(entity)
                                if displayName then
                                    table.insert(scannedEntitiesRaw, {
                                        entityKey = entityKey,
                                        name = displayName,
                                        position = entityPosition,
                                        distance = math.sqrt(distSquared),
                                        entity = entity,
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Second pass: party members specifically, NO distance gate.
    -- Companions need to be findable from any distance (e.g. walking
    -- back across the map to revive a fallen ally).
    --
    -- Don't iterate ClientCharacter (~781 entities in this game) and
    -- per-entity probe each for PartyMember -- that's hundreds of
    -- wasted calls per scan when the party is at most ~4 entities.
    -- Don't use the global PartyMember / PartyView queries either --
    -- those have empirically returned 0 entities even when party
    -- members exist with those components attached (same pattern as
    -- ClientControl returning only 1 entity instead of all-with-the-tag).
    --
    -- Efficient discovery via component chain (per Components/Party.h):
    --   1. ClientControl global query -> 1 entity (the active character).
    --      In normal play that entity has a PartyMember component.
    --   2. PartyMember.Party (EntityHandle) points at the Party entity.
    --   3. The Party entity carries PartyView whose Characters array
    --      lists every party member.  This is the canonical roster.
    -- Total cost: 3 component reads per scan, regardless of party size.
    -- If any link in the chain fails (atypical states), we fall back
    -- to "no party-distance-bypass" -- the first pass still picks up
    -- party members within the 50m scan radius.
    local partyMembersDiscovered = {}
    pcall(function()
        local seedOk, seedEntities = pcall(
            Ext.Entity.GetAllEntitiesWithComponent, "ClientControl")
        if not seedOk or not seedEntities or #seedEntities == 0 then
            return
        end
        local seed = seedEntities[1]
        local memberComp = seed.PartyMember
        if not memberComp then return end
        local partyEntity = memberComp.Party
        if not partyEntity then return end
        local viewComp = partyEntity.PartyView
        if not viewComp then return end
        local characters = viewComp.Characters
        if not characters then return end
        for _, characterEntity in ipairs(characters) do
            partyMembersDiscovered[#partyMembersDiscovered + 1] =
                characterEntity
        end
    end)
    for _, characterEntity in ipairs(partyMembersDiscovered) do
        local entityKey = tostring(characterEntity)
        if not seenHandles[entityKey] then
            seenHandles[entityKey] = true
            if not IsInsideInventory(characterEntity) then
                local entityPosition = GetEntityPosition(
                    characterEntity)
                if entityPosition then
                    local distSquared = DistanceSquaredXZ(
                        playerPosition, entityPosition)
                    local displayName =
                        GetEntityDisplayName(characterEntity)
                    if displayName then
                        -- Tag the entry so CategoriseEntity routes
                        -- it to Companions even if the per-entity
                        -- PartyMember component isn't readable in
                        -- this state (which can happen for downed
                        -- party members in some game phases).
                        partyMemberHandleSet[entityKey] = true
                        table.insert(scannedEntitiesRaw, {
                            entityKey = entityKey,
                            name = displayName,
                            position = entityPosition,
                            distance = math.sqrt(distSquared),
                            entity = characterEntity,
                        })
                    end
                end
            end
        else
            -- Entity already added by the normal pass (within radius).
            -- Tag it so classification routes to Companions.
            partyMemberHandleSet[entityKey] = true
        end
    end

    lastScanPosition = playerPosition
    Log.Debug(string.format(
        "Entity scan: %d raw entities collected",
        #scannedEntitiesRaw))
end

--- Phase 2: Classify the raw scanned entities into categories
--- using the (now-populated) template cache.  Called either
--- immediately after ScanEntities when the cache is warm, or
--- from the net response listener when the cache just arrived.
---
--- NOTE: assigns to the forward-declared upvalue (no `local`
--- here) so that the Ext.RegisterNetListener closure defined
--- earlier in the file can call this function.  See the matching
--- `local ClassifyScannedEntities` declaration above the listener.
function ClassifyScannedEntities()
    local categories = {}
    for _, categoryName in ipairs(CATEGORY_NAMES) do
        categories[categoryName] = {}
    end

    -- TEMP DIAGNOSTIC: dump component lists AND cached server data
    -- for entities whose name suggests they should be in a
    -- specific category but landed in Miscellaneous.  Helps us see
    -- which server-side fields populated (StatsInventoryTab,
    -- StoryItem, etc.) so we know why the classifier fell through.
    -- Reads from entityClassifyCache because by the time this
    -- function runs the client has already received and cached the
    -- server's response -- no need to wait for a fresh request.
    local diagnosticLogged = 0
    local DIAGNOSTIC_LIMIT = 12
    local SUSPECT_NAME_PATTERNS = {
        -- Doors / traversal
        "door", "hatch", "ladder",
        -- Live / dead characters
        "shadowheart", "lae'zel", "astarion", "gale",
        "aradin", "zevlor", "tiefling", "goblin",
        "fisher", "commoner",
        -- Items that landed in Misc but feel like Quest / Consumable
        "shanties", "sigil", "mergrass", "belladonna",
        "daggerroot", "knotted", "clamshell", "mound",
        "spiderweb", "pouch",
    }

    for _, entry in ipairs(scannedEntitiesRaw) do
        local category = CategoriseEntity(entry.entity, entry.name)
        if category and categories[category] then
            table.insert(categories[category], entry)
        end

        -- Diagnostic: if this entity's name matches a suspect
        -- pattern AND it didn't classify into NPCs/Doors, log its
        -- components so we can see why.
        if diagnosticLogged < DIAGNOSTIC_LIMIT
            and category ~= "NPCs"
            and category ~= "Doors" then
            local lowerName = entry.name:lower()
            local suspect = false
            for _, pattern in ipairs(SUSPECT_NAME_PATTERNS) do
                if lowerName:find(pattern, 1, true) then
                    suspect = true
                    break
                end
            end
            if suspect then
                local okNames, names = pcall(
                    entry.entity.GetAllComponentNames,
                    entry.entity, false)
                local namesList = "<failed>"
                if okNames and names then
                    local nameArray = {}
                    for _, nameEntry in ipairs(names) do
                        table.insert(nameArray, tostring(nameEntry))
                    end
                    namesList = table.concat(nameArray, ", ")
                end

                -- Also dump the cached server classification data
                -- for this entity.  If any server-side fields
                -- populated (Stats*, StoryItem, has_*), we'll see
                -- them here.  Emptiness means the template has no
                -- classification data on the server.
                local serverData = GetCachedEntityData(entry.entity)
                local serverParts = {}
                if serverData then
                    for key, value in pairs(serverData) do
                        table.insert(serverParts,
                            key .. "=" .. tostring(value))
                    end
                    table.sort(serverParts)
                end
                local serverDump = "<no cache>"
                if #serverParts > 0 then
                    serverDump = table.concat(serverParts, " | ")
                elseif serverData then
                    serverDump = "<cache empty>"
                end

                -- DEBUG-gated: quiet in normal play; flip log
                -- level to DEBUG (L3 click from DevConfig) to
                -- surface component lists + cached server
                -- classification for item-categorisation work.
                Log.Debug("CATEGORIZE DIAG: '" .. entry.name
                    .. "' category=" .. tostring(category)
                    .. " | server: " .. serverDump
                    .. " | components: " .. namesList)
                diagnosticLogged = diagnosticLogged + 1
            end
        end
    end

    -- Sort each category by distance.
    for _, categoryName in ipairs(CATEGORY_NAMES) do
        table.sort(categories[categoryName],
            function(entryA, entryB)
                return entryA.distance < entryB.distance
            end)
    end

    scannedCategories = categories

    local totalCount = 0
    local countParts = {}
    for _, categoryName in ipairs(CATEGORY_NAMES) do
        local count = #categories[categoryName]
        totalCount = totalCount + count
        table.insert(countParts,
            count .. " " .. categoryName:lower())
    end
    Log.Debug("Entity scan: classified " .. totalCount .. " ("
        .. table.concat(countParts, ", ") .. ")")
end

--- Collect entity UUIDs from raw scanned entities that are not
--- yet in the classification cache.  Returns the list of
--- uncached UUID strings.
local function CollectUncachedEntityUuids()
    local uncachedUuids = {}
    local seen = {}
    for _, entry in ipairs(scannedEntitiesRaw) do
        pcall(function()
            local uuidComp = entry.entity.Uuid
            if uuidComp then
                local uuid = tostring(uuidComp.EntityUuid)
                if uuid ~= "" and uuid ~= "nil"
                    and not entityClassifyCache[uuid]
                    and not seen[uuid] then
                    seen[uuid] = true
                    table.insert(uncachedUuids, uuid)
                end
            end
        end)
    end
    return uncachedUuids
end

--- Full scan + classify pipeline.  If the template cache is warm,
--- classifies immediately.  If not, sends a template request to
--- the server and defers classification to the net response
--- listener.  Returns true when categories are ready, false when
--- classification is deferred (caller should wait for the async
--- response before announcing categories).
local function ScanAndCategorise(playerPosition)
    ScanEntities(playerPosition)

    local uncachedUuids = CollectUncachedEntityUuids()
    if #uncachedUuids > 0 then
        -- Cache is cold.  Request classification data from the
        -- server.  The server checks entity components AND
        -- template/stats fields, sending everything in one pass.
        RequestEntityClassification(uncachedUuids)
        -- Classify with whatever we have now (ECS + stats checks
        -- will work; template-dependent checks will miss but the
        -- response handler will re-classify when data arrives).
        ClassifyScannedEntities()
        return true
    end

    -- Cache is warm.  Classify immediately.
    ClassifyScannedEntities()
    return true
end

--- Get all entities across all categories as a flat distance-sorted list.
local function GetAllEntitiesFlat()
    local all = {}
    for _, categoryName in ipairs(CATEGORY_NAMES) do
        for _, entry in ipairs(scannedCategories[categoryName] or {}) do
            table.insert(all, entry)
        end
    end
    table.sort(all, function(entryA, entryB)
        return entryA.distance < entryB.distance
    end)
    return all
end

-- ============================================================================
-- Pathfinding
-- ============================================================================

--- Extract node positions from an AiPath into a plain Lua array.
local function ExtractPathNodes(aiPath)
    local nodes = {}
    for nodeIndex = 1, #aiPath.Nodes do
        local nodePosition = aiPath.Nodes[nodeIndex].Position
        nodes[nodeIndex] = {
            nodePosition[1], nodePosition[2], nodePosition[3]
        }
    end
    return nodes
end

--- Run BG3's native pathfinder from the player entity to a target
--- position with a caller-supplied CloseEnoughMax.  The caller uses
--- this to drive the two-phase pathfinding strategy in ComputePath:
--- a tight first pass at interaction range (~1.5m) and a loose
--- fallback at BG3's default move-to range (~3.5m).  Other pathfinder
--- fields (CloseEnoughMin, Y tolerances, InteractionRange) are set
--- consistently so the result is valid regardless of which phase
--- the caller is running.  Returns the node array, or nil on failure.
---
--- Before FindPath runs we install hazard-avoidance weighting via
--- ApplyHazardAvoidance, which configures the AiPath's
--- SurfacePathInfluences + WeightFunc so the A* search actively
--- routes around fire, acid, cloudkill, and every other surface in
--- our runtime hazard set.  Because RecalculatePath re-runs this
--- function every tick, dynamic hazards that appear mid-walk
--- (Cloudkill cast, Grease ignited to Fire, Hellfire pool spawned)
--- are automatically avoided on the very next path compute.
local function TryPathfind(playerEntity, targetPosition, closeEnoughMax)
    local ok, result = pcall(function()
        local aiPath = Ext.Level.BeginPathfindingImmediate(
            playerEntity, targetPosition)
        if not aiPath then return nil end

        -- Configure AiPath.  CloseEnoughMin comes from
        -- MoveToTargetCloseEnoughMin (the engine's floor on the
        -- close-enough annulus).  CloseEnoughMax and InteractionRange
        -- come from the parameter so the caller controls the
        -- phase (tight interaction vs. loose movement).  Y
        -- tolerances are hand-picked since ExtraData does not
        -- expose them.
        local closeEnoughMin = GetMoveToCloseEnoughMin()
        if closeEnoughMin > closeEnoughMax then
            closeEnoughMin = 0
        end
        pcall(function()
            aiPath.CloseEnoughMin     = closeEnoughMin
            aiPath.CloseEnoughMax     = closeEnoughMax
            aiPath.CloseEnoughFloor   = GPS_CLOSE_ENOUGH_FLOOR
            aiPath.CloseEnoughCeiling = GPS_CLOSE_ENOUGH_CEIL
            aiPath.InteractionRange   = closeEnoughMax
        end)

        -- Native hazard-avoidance weighting.  Must be set BEFORE
        -- FindPath so the weight function is consulted during the
        -- A* search, not after.  Setting it afterward is a no-op.
        ApplyHazardAvoidance(aiPath)

        local goalFound = Ext.Level.FindPath(aiPath)
        -- DestinationReached is a separate flag that becomes true
        -- when the pathfinder settled on a close-enough approach
        -- tile.  GoalFound alone can be false while
        -- DestinationReached is true for the exact scenario we care
        -- about: target is unwalkable but a nearby tile is.
        local destinationReached = false
        pcall(function()
            destinationReached = aiPath.DestinationReached
        end)
        if not (goalFound or destinationReached) then
            pcall(Ext.Level.ReleasePath, aiPath)
            return nil
        end
        local nodes = ExtractPathNodes(aiPath)
        pcall(Ext.Level.ReleasePath, aiPath)
        if #nodes == 0 then return nil end
        return nodes
    end)
    if ok then return result end
    return nil
end

--- Scan every node in a path for damaging surfaces.  Returns
--- (firstHazardNodeIndex, hazardLabel) for the first hazard found,
--- or (nil, nil) when the path is clear.
---
--- Uses CheckPositionHazardArea (9-sample ring) at each node so a
--- hazard clipping the character's MovingBound is detected even
--- when the node centerline sits on a safe tile.  For segments
--- longer than GPS_HAZARD_INTERNODE_SAMPLE_M, also samples
--- intermediate positions along the segment so fires that sit
--- between two safe nodes (path smoothing leaves gaps) don't
--- slip through.
---
--- Returns the node index of the SEGMENT whose scan first hit a
--- hazard -- for an inter-node sample the reported index is the
--- segment's endpoint node, which is close enough for the
--- callers that use it (FindPathHazard's only consumers need a
--- node index for path-slicing; off-by-one on a 0.75m segment is
--- noise).
local function FindPathHazard(path)
    if not path then return nil, nil end

    -- First node: check its ring immediately so an in-place hazard
    -- (the player is already standing in/next to fire) is caught
    -- on the very first probe.
    local firstHit, firstLabel = CheckPositionHazardArea(path[1])
    if firstHit then return 1, firstLabel end

    for nodeIndex = 2, #path do
        local prevNode = path[nodeIndex - 1]
        local thisNode = path[nodeIndex]

        -- Inter-node sampling along the segment from prevNode to
        -- thisNode.  Skip if the segment is shorter than one sample
        -- step -- the ring at each endpoint already covers it.
        local segmentLength = DistanceXZ(prevNode, thisNode)
        if segmentLength > GPS_HAZARD_INTERNODE_SAMPLE_M then
            local sampleCount = math.floor(
                segmentLength / GPS_HAZARD_INTERNODE_SAMPLE_M)
            for sampleIndex = 1, sampleCount do
                local fraction = sampleIndex / (sampleCount + 1)
                local samplePosition = {
                    prevNode[1]
                        + (thisNode[1] - prevNode[1]) * fraction,
                    prevNode[2]
                        + (thisNode[2] - prevNode[2]) * fraction,
                    prevNode[3]
                        + (thisNode[3] - prevNode[3]) * fraction,
                }
                local interHit, interLabel =
                    CheckPositionHazardArea(samplePosition)
                if interHit then
                    return nodeIndex, interLabel
                end
            end
        end

        -- Then the node itself.
        local nodeHit, nodeLabel =
            CheckPositionHazardArea(thisNode)
        if nodeHit then
            return nodeIndex, nodeLabel
        end
    end
    return nil, nil
end

-- Straight-line sample spacing for the hazard-detour detector.  One
-- sample every 1 meter along the player -> target straight line
-- gives ~30 samples on a 30m path, each a single
-- Ext.Level.GetTileDebugInfo call (cheap).  1m resolution is fine
-- for detecting any hazard zone worth warning about; smaller fire
-- patches that a 1m step would skip are also rarely worth
-- re-routing around since the player could walk straight through
-- before taking a single tick of damage.
local GPS_STRAIGHT_LINE_SAMPLE_M = 1.0

--- Sample the straight line from the player to the target at 1m
--- intervals and return the first hazardous surface we hit, if any.
--- Used by the hazard-detour detector to distinguish "path is long
--- because of geometry (walls, furniture)" from "path is long
--- because the pathfinder is actively avoiding a hazard our naive
--- straight-line walk would have crossed".  Returns (label, tValue)
--- where tValue is the 0..1 parametric position along the line, or
--- (nil, nil) when the line is clear.
---
--- Cost: one GetTileDebugInfo call per sample, ceil(distance / 1m)
--- samples.  On a 30m route that is ~30 calls, plus one set lookup
--- each.  Runs once per successful path compute (300ms tick), so
--- the total is negligible.
local function FindStraightLineHazard(fromPosition, toPosition)
    if not fromPosition or not toPosition then return nil, nil end
    local distance = DistanceXZ(fromPosition, toPosition)
    if distance < GPS_STRAIGHT_LINE_SAMPLE_M then return nil, nil end
    local sampleCount = math.ceil(
        distance / GPS_STRAIGHT_LINE_SAMPLE_M)
    for sampleIndex = 1, sampleCount do
        local tValue = sampleIndex / sampleCount
        local samplePosition = {
            fromPosition[1] + (toPosition[1] - fromPosition[1]) * tValue,
            fromPosition[2] + (toPosition[2] - fromPosition[2]) * tValue,
            fromPosition[3] + (toPosition[3] - fromPosition[3]) * tValue,
        }
        local isHazard, hazardLabel =
            CheckPositionHazard(samplePosition)
        if isHazard then
            return hazardLabel, tValue
        end
    end
    return nil, nil
end

--- Dev-visibility log for the silent-avoidance case.  After a
--- successful pathfind, compare the actual path against the
--- straight-line hazard sample.  Three outcomes:
---
---   A. Straight line clean, actual path clean  -> no log (normal).
---   B. Straight line has a hazard, actual path is clean -> the
---      pathfinder IS routing around that hazard.  Log at Info so
---      we can verify hazard avoidance is working even when we
---      never speak anything to the player (the common case).
---   C. Straight line has a hazard, actual path crosses it too ->
---      FindPathHazard already logs that case via ComputePath's
---      callers, so we do not duplicate the log here.
---
--- Uses the lastLoggedDetourLabel latch so repeated per-tick
--- detections of the same hazard label only log once.  The latch
--- clears when the straight line returns clean (hazard out of
--- range, walked past, dissipated) so the next fresh detour can
--- log again.  Label transitions (Fire -> Acid) also log -- the
--- dedup is strictly on label equality, not "any log was made
--- this session".
---
--- Silent on nil inputs; the caller feeds validated arguments.
local function LogHazardDetourIfDetected(
    phaseLabel, playerPosition, targetPosition, path, pathHasHazard)
    if pathHasHazard then return end
    local straightHazardLabel, tValue =
        FindStraightLineHazard(playerPosition, targetPosition)
    if not straightHazardLabel then
        -- Straight line is clean now.  Clear the dedup latch so
        -- the next detected detour logs a fresh entry even if it
        -- has the same label as the one we cleared.
        lastLoggedDetourLabel = nil
        return
    end

    -- Dedup: only log when the detected hazard label differs from
    -- the one we last logged.  Covers both "same hazard, same
    -- detour" and "same hazard, moved further down the straight
    -- line as the player walks" spam cases.
    if lastLoggedDetourLabel == straightHazardLabel then
        return
    end
    lastLoggedDetourLabel = straightHazardLabel

    -- Compute path length for log context.
    local pathLength = 0
    for nodeIndex = 2, #path do
        pathLength = pathLength + DistanceXZ(
            path[nodeIndex - 1], path[nodeIndex])
    end
    local straightLineDistance = DistanceXZ(
        playerPosition, targetPosition)
    local detourRatio = 0
    if straightLineDistance > 0 then
        detourRatio = pathLength / straightLineDistance
    end

    Log.Info(string.format(
        "Path (%s) routes around %s at t=%.2f "
            .. "(straight %.1fm, path %.1fm, ratio %.2fx)",
        phaseLabel, straightHazardLabel, tValue,
        straightLineDistance, pathLength, detourRatio))
end

-- Dedup state for path-crosses-hazard logging.  Without dedup,
-- the per-tick path recompute produces dozens of identical
-- "Path crosses Fire at node N" lines while the path shape is
-- unchanged, making it impossible to see any other diagnostic
-- in the log.  The dedup signature combines the phase, node
-- count, hazard label, and node index (rounded to the nearest
-- group of 3 nodes) so small shifts in node position from
-- recompute jitter do NOT count as a new crossing -- a real
-- change (new hazard label, significant node index shift, or
-- node-count change) does.
local lastLoggedPathHazardKey = nil

--- Log "Path crosses <hazard> at node N" at Info level only
--- when the crossing signature meaningfully differs from the
--- last logged one.  Subsequent identical crossings drop to
--- Debug level and are suppressed from normal log output.
---
--- Callers should invoke this helper ONLY when
--- FindPathHazard returned a non-nil hazardIndex.  When the
--- path is clean, the dedup signature should be reset via
--- ResetPathCrossHazardDedup() so the next crossing logs fresh.
local function LogPathCrossesHazard(
    phase, closeEnoughMax, nodeCount, hazardLabel, hazardIndex)
    -- Bucket node index into groups of 3 so tiny path shape
    -- changes (node index drifting by 1-2 across recomputes)
    -- do not count as distinct crossings.
    local nodeBucket = math.floor(hazardIndex / 3)
    local key = string.format("%s|%d|%s|%d",
        phase, nodeCount, hazardLabel, nodeBucket)
    if key == lastLoggedPathHazardKey then
        Log.Debug(string.format(
            "Path (%s %.1fm, %d nodes) crosses %s at node %d "
                .. "(suppressed duplicate)",
            phase, closeEnoughMax, nodeCount,
            hazardLabel, hazardIndex))
        return
    end
    lastLoggedPathHazardKey = key
    Log.Info(string.format(
        "Path (%s %.1fm, %d nodes) crosses %s at node %d",
        phase, closeEnoughMax, nodeCount,
        hazardLabel, hazardIndex))
end

--- Reset the path-crosses-hazard dedup signature.  Called when
--- the path becomes clean (no crossing) so the next genuine
--- crossing logs fresh at Info level.  Also called on tracking
--- teardown via the state-reset sites.
local function ResetPathCrossHazardDedup()
    lastLoggedPathHazardKey = nil
end

--- Two-phase path computation.  Returns (nodes, arrivalThreshold)
--- where arrivalThreshold is the CloseEnoughMax that produced the
--- path -- the caller uses it as the arrival distance so the
--- player is told "arriving" exactly when they reach the radius
--- the pathfinder aimed for.
---
--- Phase 1: tight (interaction range, ~1.5m).  Succeeds when a
--- walkable tile exists within GPS_INTERACT_CLOSE_ENOUGH_MAX of
--- the raw target -- which is the case for most loose-world items,
--- NPCs, and destructibles.  The player ends the walk already in
--- interaction range so the cursor can target the object on the
--- first RS Down / X press without manual nudging.
---
--- Phase 2: loose (BG3's default, ~3.5m).  Fallback for targets
--- buried inside meshes (corpses, pods, decoration) or behind
--- narrow approach corridors where no tile is reachable within
--- the tight radius.  The player stops walking but may need to
--- rotate / take a step to get the cursor on the target; path-
--- endpoint arrival still fires via UpdateTrackingState when the
--- player is near the last path node.
---
--- Silent on total failure (returns nil, nil); caller handles the
--- "no path" transition announcement.
local function ComputePath(playerEntity, playerPosition, targetPosition)
    local tightMax = GPS_INTERACT_CLOSE_ENOUGH_MAX
    local looseMax = GetMoveToCloseEnoughMax()
    -- Belt-and-suspenders: if engine config ever reports a tight
    -- MoveToTargetCloseEnoughMax smaller than our interaction
    -- radius, don't run a nonsensical "tight" phase larger than the
    -- loose one.
    if tightMax >= looseMax then
        local path = TryPathfind(playerEntity, targetPosition, looseMax)
        if not path then return nil, nil end
        local hazardIndex, _ = FindPathHazard(path)
        LogHazardDetourIfDetected(
            string.format("loose %.1fm", looseMax),
            playerPosition, targetPosition, path, hazardIndex ~= nil)
        return path, looseMax
    end

    -- Phase 1: tight.
    local tightPath = TryPathfind(
        playerEntity, targetPosition, tightMax)
    if tightPath then
        local hazardIndex, hazardLabel = FindPathHazard(tightPath)
        if hazardIndex then
            LogPathCrossesHazard("tight", tightMax, #tightPath,
                hazardLabel, hazardIndex)
        else
            ResetPathCrossHazardDedup()
            Log.Debug(string.format(
                "Path (tight %.1fm): %d nodes",
                tightMax, #tightPath))
        end
        LogHazardDetourIfDetected(
            string.format("tight %.1fm", tightMax),
            playerPosition, targetPosition, tightPath,
            hazardIndex ~= nil)
        return tightPath, tightMax
    end

    -- Phase 2: loose.
    local loosePath = TryPathfind(
        playerEntity, targetPosition, looseMax)
    if not loosePath then return nil, nil end
    local hazardIndex, hazardLabel = FindPathHazard(loosePath)
    if hazardIndex then
        LogPathCrossesHazard("loose", looseMax, #loosePath,
            hazardLabel, hazardIndex)
    else
        ResetPathCrossHazardDedup()
        Log.Debug(string.format(
            "Path (loose %.1fm): %d nodes",
            looseMax, #loosePath))
    end
    LogHazardDetourIfDetected(
        string.format("loose %.1fm", looseMax),
        playerPosition, targetPosition, loosePath,
        hazardIndex ~= nil)
    return loosePath, looseMax
end

-- ============================================================================
-- GPS Tracking Mode (path following to selected target)
-- ============================================================================

-- Steering target: the first path node that is at least this far from
-- the player.  Close enough that the straight-line from the player
-- should not cut through obstacles; far enough to give a stable
-- clock reading that doesn't flicker with every step.
local GPS_STEERING_DISTANCE   = 2.0

-- How far ahead on the path (in meters of cumulative path distance)
-- to scan for dynamic hazards.  The scan runs every silent tick
-- (~300ms), so the total advance warning is this distance minus
-- however far the player walks during the speech delivery latency
-- (~0.5s = ~1.5m at normal walking speed).  12m leaves ~10m of real
-- warning, which is enough to stop before a fire/cloudkill edge.
local GPS_HAZARD_WARNING_M    = 12.0

--- Recompute the path from the player's current position to the
--- tracking target, refreshing the target's world position from the
--- live entity handle first (NPC targets may have moved).  Silent:
--- updates currentPath without speaking.  Stores the threshold that
--- produced the path on trackingTarget.arrivalThreshold so the
--- arrival check in UpdateTrackingState uses the radius the
--- pathfinder actually aimed for -- tight (~1.5m, interaction
--- range) when a walkable tile exists that close, loose (~3.5m,
--- BG3's default move-to range) when it does not.
-- Path commitment policy: once A* returns a path, keep using it
-- until the path is demonstrably stale.  A* is deterministic on
-- stable inputs but has tie-breaking behavior at equal-cost paths
-- and (apparently) a nearest-walkable-tile fallback when the start
-- tile is flagged non-walkable.  Tiny player-position jitter near
-- hazards or unwalkable terrain can flip either of those and
-- produce radically different path shapes on otherwise identical
-- inputs.  The previous "recompute every N meters of movement"
-- policy meant we kept asking A* for fresh opinions every 3 meters,
-- surfacing that tie-breaking variance as announced bearing
-- flip-flop even when the player was barely moving.
--
-- New policy: we only recompute when one of three conditions
-- fires, in priority order:
--   1. Target moved >= GPS_TARGET_MOVED_M since last recompute
--      (NPC targets reposition and the path must follow).
--   2. Player drifted > GPS_OFF_PATH_M perpendicular from the
--      current path (player chose a different direction than the
--      path's centerline suggested -- honor that by asking A* for
--      a new path from where they actually are).
--   3. No path exists yet (first tracking tick).
--
-- Absent those triggers, we commit to the current path and the
-- analysis/speech layers work off stable inputs.  Bearings only
-- change when the player has genuinely moved along the path, not
-- because A* changed its mind about a tie.
-- 4m (was 2.5m): hazard-adjacent walking (deepwater, in particular)
-- jitters the player's physics capsule sideways by up to a couple
-- of meters even when they're walking "straight."  A tight 2.5m
-- off-path gate fired recomputes regularly during water crossings
-- -- each recompute could produce a slightly different A* path
-- due to tiebreaking near the water/shore boundary, which in turn
-- fed state-classification flicker.  4m absorbs typical physics
-- jitter without losing the "player chose a genuinely different
-- direction" signal (they'd have to deviate by half a body-length
-- from the path centerline to trigger recompute).
local GPS_OFF_PATH_M     = 4.0  -- perpendicular drift that invalidates path
local GPS_TARGET_MOVED_M = 3.0  -- target delta that invalidates path

local function RecalculatePath(playerPosition)
    if not trackingTarget then return end

    local playerEntity = GetPlayerEntity()
    if not playerEntity then return end

    -- Refresh the target's world position.  Targets are stored
    -- by entity handle; the cached position goes stale if the
    -- target moves (NPC wanders, quest marker updates).
    local targetMoved = false
    local refreshedPosition = GetEntityPosition(trackingTarget.entity)
    if refreshedPosition then
        if trackingTarget.position then
            local targetDelta = DistanceXZ(
                refreshedPosition, trackingTarget.position)
            if targetDelta >= GPS_TARGET_MOVED_M then
                targetMoved = true
            end
        end
        trackingTarget.position = refreshedPosition
    end

    -- Path commitment check.  If we already have a path, the
    -- target hasn't moved, and the player is still on/near the
    -- path's centerline, reuse the existing path.  No fresh A*
    -- call -- no tie-break variance, no node-count bounce, no
    -- bearing flip-flop.
    if currentPath and #currentPath > 0 and not targetMoved then
        local offPathDistance = MinDistanceToPath(
            playerPosition, currentPath)
        if offPathDistance <= GPS_OFF_PATH_M then
            return
        end
    end

    local path, threshold = ComputePath(
        playerEntity, playerPosition, trackingTarget.position)
    currentPath = path
    if threshold then
        trackingTarget.arrivalThreshold = threshold
    end

    -- (Path-shape ratio computation removed.  It was used solely by
    -- the detour state machine which has been deleted -- the engine
    -- pathfinder still routes around hazards but we no longer
    -- announce the path's bend shape.)
end

-- When the player is within GPS_CLOSE_RANGE_STEERING_M of the path's
-- last node (which is the closest reachable approach to the target),
-- use the last node itself as the steering target instead of the
-- "first node >= 2m away" heuristic.  Rationale: at long range the
-- "2m ahead on path" rule gives a stable clock bearing because the
-- chosen node is always comfortably far from the player.  At close
-- range the path only has a handful of nodes, the "first node >= 2m
-- away" is frequently the last node anyway, and tiny player movements
-- (or tiny path shape changes during recompute) flip which node gets
-- picked -- producing the 3h -> 9h -> 12h -> 3h clock bearing jitter
-- observed on the Mind Flayer Pod approach.  Locking to the last node
-- in the close-range endgame eliminates the flip-flop because the
-- last node moves smoothly as the player approaches it.
local GPS_CLOSE_RANGE_STEERING_M = 5.0

-- Node-consumed threshold.  Nodes within this distance of the player
-- are treated as "reached" -- the bearing picker advances to the next
-- node for its direction read, mirroring the NPC behavior of
-- consuming a waypoint when standing on it.
--
-- Previously 0.75m, which was too aggressive: obstacle-avoidance
-- corner waypoints returned by BG3's pathfinder often sit 0.3-0.6m
-- from the player (tight bends around pods, pillars, walls), and the
-- old value discarded them as "too close for a stable bearing."  The
-- practical effect was that GPS skipped the corner and announced the
-- bearing to the post-corner node -- pointing straight through the
-- obstacle the pathfinder had routed around.  0.1m only skips nodes
-- the player is literally standing on top of.
local GPS_BEARING_MIN_SEGMENT_M = 0.1

-- Maximum distance (along path) the detour-aware picker will look
-- for the end of the first leg.  If the bearing has not changed by
-- the end of this window, the leg is treated as the entire readable
-- path and the picker returns the node at that distance -- matching
-- the long-range "2m ahead" behavior it replaces.
local GPS_DETOUR_LEG_MAX_M = 6.0

--- Find the path node the player should steer toward, respecting
--- local path detours instead of blindly picking a node 2m out.
---
--- The previous implementation walked the path outward and returned
--- the first node at least GPS_STEERING_DISTANCE meters from the
--- player.  That broke when the path had a short detour around an
--- obstacle: the first few nodes zigzagged past a wall/prop, all
--- within 2m of the player, so the picker skipped them and returned
--- a node PAST the detour.  The bearing to that post-detour node
--- was "3 o'clock" while the player's first step actually needed
--- to be "5 o'clock to get around the wall" -- guidance told the
--- player to push the stick in a direction where they were
--- physically blocked.
---
--- Detour-aware algorithm:
---   1. Compute the clock bearing from the player to the FIRST
---      node with a meaningful segment length (>= 0.75m).  That
---      bearing defines the "first leg direction."
---   2. Walk the path outward from that node.  For each subsequent
---      node, check whether its clock bearing from the player is
---      within 1 clock hour (30 degrees) of the first-leg bearing.
---   3. The last node that's still within 30 degrees AND within
---      GPS_DETOUR_LEG_MAX_M of the player is the steering target.
---      That's the far end of the first leg.
---   4. Any node beyond that (different bearing OR beyond the leg
---      window) is the beginning of the second leg, which the
---      picker ignores -- it gets described by the per-tick
---      guidance once the player reaches the pivot.
---
--- Special cases:
---   * Fewer than 2 usable nodes: fall back to the old behavior
---     (first node >= GPS_STEERING_DISTANCE from the player).
---   * Close range (last path node within GPS_CLOSE_RANGE_STEERING_M):
---     return the last node directly, as before.  The detour logic
---     does not help when the whole path is a few meters long.
---   * All nodes within 30 degrees of node 1: return the node at
---     ~GPS_DETOUR_LEG_MAX_M or the final node, whichever comes
---     first.  This matches the "no detour, just walk straight"
---     case.
local function GetSteeringTargetPosition(playerPosition)
    if not currentPath or #currentPath == 0 then return nil end

    local lastNode = currentPath[#currentPath]
    local lastNodeDistance = DistanceXZ(playerPosition, lastNode)
    if lastNodeDistance <= GPS_CLOSE_RANGE_STEERING_M then
        return lastNode
    end

    -- Find the first node with a meaningful segment length.  Nodes
    -- closer than GPS_BEARING_MIN_SEGMENT_M give unstable clock
    -- bearings (noise) so we skip them and start bearing computation
    -- from the first trustworthy node.
    local firstLegStartIndex = nil
    for nodeIndex = 1, #currentPath do
        local dist = DistanceXZ(
            playerPosition, currentPath[nodeIndex])
        if dist >= GPS_BEARING_MIN_SEGMENT_M then
            firstLegStartIndex = nodeIndex
            break
        end
    end
    if not firstLegStartIndex then
        -- Every path node is within 0.75m of the player.  Path is
        -- absurdly short; just return the last node.
        return lastNode
    end

    local firstLegBearing = ComputeClockDirection(
        playerPosition, currentPath[firstLegStartIndex])
    if not firstLegBearing then
        -- Camera unavailable, can't compute bearing -- fall back.
        return currentPath[firstLegStartIndex]
    end

    -- Walk outward from the first-leg start node.  Keep the last
    -- node whose bearing matches the first-leg bearing (within 1
    -- clock hour) AND is within the leg window.  When either
    -- condition fails, stop -- the previous node is our steering
    -- target (the pivot at the end of leg 1).
    local steeringNodeIndex = firstLegStartIndex
    for nodeIndex = firstLegStartIndex + 1, #currentPath do
        local candidate = currentPath[nodeIndex]
        local candidateDistance = DistanceXZ(
            playerPosition, candidate)
        if candidateDistance > GPS_DETOUR_LEG_MAX_M then
            -- Past the leg window.  Previous node was the pivot.
            break
        end

        local candidateBearing = ComputeClockDirection(
            playerPosition, candidate)
        if not candidateBearing then
            break
        end

        -- Clock hour distance, accounting for wrap-around (12 -> 1
        -- is one hour, not eleven).  Range is 0..6.
        local hourDelta = math.abs(candidateBearing - firstLegBearing)
        if hourDelta > 6 then hourDelta = 12 - hourDelta end

        if hourDelta > 1 then
            -- Bearing has diverged from the first leg.  We've
            -- reached the pivot -- previous node was its far end.
            break
        end

        -- Still in the same leg; advance.
        steeringNodeIndex = nodeIndex
    end

    return currentPath[steeringNodeIndex]
end

--- Scan the upcoming path segment for dynamic hazards (Cloudkill
--- cast while the user is walking, Hellfire ignited by a trap,
--- etc.).  Walks path nodes starting from node 1 and stops when the
--- cumulative path distance exceeds GPS_HAZARD_WARNING_M.  Returns
--- (true, hazardLabel, distanceMeters) for the nearest hazard in
--- range, or (false, nil, nil) when the upcoming segment is clear.
---
--- The returned distance is the path distance from the player to
--- the hazardous node, rounded at the caller.  Using cumulative
--- path distance (not straight-line distance to the player) is
--- correct here because the player will actually walk along the
--- path, so the walking-time-to-impact is what matters.
local function CheckUpcomingPathHazard()
    if not currentPath or #currentPath == 0 then
        return false, nil, nil
    end

    -- Node 1 (player's current position): wide probe.  If the
    -- player is standing in or grazing a hazard right now, report
    -- it at distance 0.
    local firstHit, firstLabel =
        CheckPositionHazardArea(currentPath[1])
    if firstHit then
        return true, firstLabel, 0
    end

    local cumulativeDistance = 0
    for nodeIndex = 2, #currentPath do
        local prevNode = currentPath[nodeIndex - 1]
        local thisNode = currentPath[nodeIndex]
        local segmentLength = DistanceXZ(prevNode, thisNode)

        -- Inter-node sampling along the segment.  Each sample gets
        -- the full 0.75m radius probe.  The reported distance for
        -- a sample hit is the cumulative path distance up to that
        -- sample, which is what the "N meters ahead" warning uses.
        if segmentLength > GPS_HAZARD_INTERNODE_SAMPLE_M then
            local sampleCount = math.floor(
                segmentLength / GPS_HAZARD_INTERNODE_SAMPLE_M)
            for sampleIndex = 1, sampleCount do
                local fraction = sampleIndex / (sampleCount + 1)
                local sampleDistance =
                    cumulativeDistance + segmentLength * fraction
                if sampleDistance > GPS_HAZARD_WARNING_M then
                    return false, nil, nil
                end
                local samplePosition = {
                    prevNode[1]
                        + (thisNode[1] - prevNode[1]) * fraction,
                    prevNode[2]
                        + (thisNode[2] - prevNode[2]) * fraction,
                    prevNode[3]
                        + (thisNode[3] - prevNode[3]) * fraction,
                }
                local interHit, interLabel =
                    CheckPositionHazardArea(samplePosition)
                if interHit then
                    return true, interLabel, sampleDistance
                end
            end
        end

        -- Then the node itself.
        cumulativeDistance = cumulativeDistance + segmentLength
        if cumulativeDistance > GPS_HAZARD_WARNING_M then
            break
        end
        local nodeHit, nodeLabel =
            CheckPositionHazardArea(thisNode)
        if nodeHit then
            return true, nodeLabel, cumulativeDistance
        end
    end
    return false, nil, nil
end

-- Forward declaration for EnterExplorationMode, called by
-- UpdateTrackingState's arrival branch for the auto-return-to-
-- exploration feature.  The implementation lives in the GPS
-- Control section further down the file, so we declare the local
-- here and assign to it (without `local`) at the definition site.
-- Matches the existing OpenEntityList forward-declaration pattern.
local EnterExplorationMode

--- Silent tracking state update.  Called every tick.
---
--- Order of operations matters: we recompute the path FIRST, then
--- check arrival using the fresh path.  The arrival check has two
--- conditions that both look at the current path:
---
---   1. Raw proximity: straight-line distance to the raw target
---      position is within MoveToTargetCloseEnoughMax.  That is
---      the exact threshold BG3's own character controller uses
---      to consider a Move To task arrived, so if we match it we
---      agree with the engine.
---   2. Path-endpoint arrival: player is at the last node of the
---      current path (within GPS_ENDPOINT_ARRIVAL_M) AND the raw
---      target is still in sensible arrival range
---      (GPS_ENDPOINT_MAX_DISTANCE).  This catches the case where
---      the target is so deeply inside an unwalkable mesh that
---      the pathfinder settles on a tile beyond CloseEnoughMax --
---      the path endpoint IS the closest physical approach, so
---      the player has arrived as closely as they physically can.
---
--- On arrival, tracking state is torn down and the mode
--- automatically switches back to Exploration via the forward-
--- declared EnterExplorationMode so the player does not have to
--- manually cycle RS-Left through Off then Exploration after
--- every GPS destination.
---
--- Then the hazard scan runs.  Hazard warnings can speak here
--- immediately (not throttled to the 2m movement tick) so the
--- player gets advance warning as soon as a hazard appears within
--- GPS_HAZARD_WARNING_M of their position along the path.
---
--- All non-arrival / non-hazard speech (distance, clock direction)
--- lives in SpeakTrackingGuidance, which only fires on
--- GPS_GUIDANCE_MOVEMENT meters of actual player movement.
local function UpdateTrackingState(playerPosition)
    if not trackingTarget then return end

    -- Silent path recompute first, so arrival + hazard checks see
    -- the current world state rather than last tick's stale path.
    RecalculatePath(playerPosition)

    -- Path-availability transition tracking.  Log and speak "no
    -- path" only when the state actually changes, not every tick
    -- the path remains unavailable.  Clear the latch when a path
    -- becomes available again (target moved, pathfinder finds a
    -- route after dynamic obstacles clear, etc.).
    --
    -- Auto-cancel: if the path stays unavailable for
    -- GPS_NO_PATH_CANCEL_TICKS in a row, give up, announce the
    -- cancellation, and return to Exploration mode.  Previous
    -- behavior left tracking alive indefinitely, forcing the
    -- player to cycle RS-Left manually to recover.
    if currentPath then
        if not pathWasAvailable then
            Log.Info("GPS: path found")
        end
        pathWasAvailable = true
        noPathAnnounced = false
        noPathTickCount = 0
    else
        if pathWasAvailable or not noPathAnnounced then
            Log.Info(string.format(
                "GPS: no path to %s", trackingTarget.name))
            if not noPathAnnounced then
                local noPathSpeech = SpeechData.Create()
                noPathSpeech:Add("status",
                    "No path to " .. trackingTarget.name, "brief")
                Ext.Tolk.Speak(noPathSpeech:Format(), true)
                noPathAnnounced = true
            end
        end
        pathWasAvailable = false
        noPathTickCount = noPathTickCount + 1
        if noPathTickCount >= GPS_NO_PATH_CANCEL_TICKS then
            local cancelledName = trackingTarget.name
            Log.Info(string.format(
                "GPS: auto-cancelling tracking of %s "
                    .. "(%d consecutive no-path ticks)",
                cancelledName, noPathTickCount))
            -- Clear tracking state BEFORE switching modes so the
            -- next tick sees a clean slate and OnTick's
            -- "not trackingTarget" branch does not spuriously
            -- re-clear state EnterExplorationMode populates.
            trackingTarget = nil
            currentPath = nil
            lastHazardAnnouncedLabel = nil
            lastPathLength = 0
            lastLoggedDetourLabel = nil
            lastLoggedPathHazardKey = nil
            hazardClearTickCount = 0
            noPathTickCount = 0
            noPathAnnounced = false
            pathWasAvailable = false
            EnterExplorationMode(
                "Route unavailable. Cancelling tracking of "
                    .. cancelledName .. ". Exploration mode.")
            return
        end
    end

    -- Arrival: speak once and tear down tracking.  The threshold is
    -- whichever CloseEnoughMax the most recent ComputePath succeeded
    -- with (tight ~1.5m for interaction-reachable targets, loose
    -- ~3.5m for mesh-buried targets).  Fall back to the loose max
    -- if no path has been computed yet.
    local arrivalThreshold = trackingTarget.arrivalThreshold
        or GetMoveToCloseEnoughMax()
    local distanceToTarget = DistanceXZ(
        playerPosition, trackingTarget.position)
    local atRawTarget = distanceToTarget <= arrivalThreshold
    local atPathEndpoint = false
    if not atRawTarget
        and currentPath and #currentPath > 0
        and distanceToTarget <= GPS_ENDPOINT_MAX_DISTANCE then
        local endpointNode = currentPath[#currentPath]
        local endpointDistance = DistanceXZ(
            playerPosition, endpointNode)
        if endpointDistance <= GPS_ENDPOINT_ARRIVAL_M then
            atPathEndpoint = true
        end
    end
    if atRawTarget or atPathEndpoint then
        local reason = atRawTarget
            and "raw proximity"
            or "pathfinder endpoint"
        local arrivedName = trackingTarget.name
        Log.Info(string.format(
            "GPS: Arriving at %s (%.2fm, threshold=%.1fm, %s)",
            arrivedName, distanceToTarget,
            arrivalThreshold, reason))
        -- Clear the tracking session state BEFORE switching modes
        -- so the next tick sees a clean slate and OnTick's
        -- "not trackingTarget" branch does not spuriously re-clear
        -- state EnterExplorationMode is about to populate.
        trackingTarget = nil
        currentPath = nil
        lastHazardAnnouncedLabel = nil
        lastPathLength = 0
        lastLoggedDetourLabel = nil
        lastLoggedPathHazardKey = nil
        hazardClearTickCount = 0
        noPathTickCount = 0
        -- Auto-return to Exploration mode so the player does not
        -- have to cycle RS-Left (Off -> Exploration) after every
        -- arrival.  Combine the arrival and mode-switch messages
        -- into a single interrupt speech so the second does not
        -- chop off the first, then let ProcessProximityUpdate fire
        -- non-interrupt nearby-entity announcements normally.
        EnterExplorationMode(
            "Arriving at " .. arrivedName .. ". Exploration mode.")
        return
    end

    if not currentPath then return end

    -- Measure the current path's total length so we can distinguish
    -- a reroute (length stays roughly the same or grows because the
    -- new path detours around a hazard) from ordinary forward
    -- progress (length shrinks as the player covers ground toward
    -- the target).  Sum the XZ distance between consecutive nodes;
    -- Y is intentionally ignored here to match every other distance
    -- metric in this module.
    local newPathLength = 0
    for nodeIndex = 2, #currentPath do
        newPathLength = newPathLength + DistanceXZ(
            currentPath[nodeIndex - 1], currentPath[nodeIndex])
    end

    -- Hazard scan every tick.  Firing here (not in the
    -- speech-throttled branch) means the player gets warned as soon
    -- as a hazard appears within range, not when they next cross
    -- the 2m movement threshold.
    --
    -- Two DIFFERENT scans are used for two different purposes:
    --
    --   * CheckUpcomingPathHazard: 12m cutoff.  Drives the "Stop.
    --     fire N meters ahead" warning -- we only want to warn about
    --     hazards close enough to matter for immediate walking.
    --   * FindPathHazard: full-path scan, no cutoff.  Drives the
    --     reroute-clean detection -- declaring "rerouting around X"
    --     requires the ENTIRE path to be clean, not just the first
    --     12m.  Using the 12m scan for the clean check produced
    --     spurious reroute announcements when fire at node 20+
    --     fell past the cutoff -- "no hazard ahead within 12m" is
    --     NOT the same thing as "path rerouted around hazard".
    --
    -- Outcomes:
    --
    --   1. Hazard within 12m, previously unannounced: speak "Stop.
    --      <label> N meters ahead" and latch.
    --   2. Full-path clean for GPS_REROUTE_STABILITY_TICKS in a row
    --      while a warning was latched: speak "Rerouting around
    --      <label>. N meters. H o'clock." -- single speech combining
    --      the reroute notification WITH the new steering direction
    --      so the player immediately knows which way to walk.  Also
    --      reset lastGuidancePosition so subsequent movement fires
    --      the normal throttled guidance from the announcement
    --      point, not from wherever the player was when the warning
    --      first fired.
    --   3. Full-path still has hazard (but > 12m out), a warning was
    --      latched, and the path length has dropped significantly:
    --      the player walked past the first hazard but there's
    --      another one beyond.  Silently update the latch label and
    --      reset the stability counter -- no "rerouting" announcement
    --      because we haven't actually rerouted around anything.
    --
    -- Path length delta is kept as a secondary signal only: if the
    -- full-path scan is clean AND length shrank a lot, the player
    -- walked past the hazard rather than rerouting, so we suppress
    -- the announcement in that case too (same spirit as before).
    local REROUTE_SHRINK_TOLERANCE = 1.5
    local hazardAhead, hazardLabel, hazardDistance =
        CheckUpcomingPathHazard()
    local fullPathHazardIndex, fullPathHazardLabel =
        FindPathHazard(currentPath)
    local fullPathHasHazard = fullPathHazardIndex ~= nil

    if hazardAhead then
        -- Case 1: hazard within 12m warning window.  Only speak
        -- once per continuous hazard episode (the latch), but
        -- always refresh the stored label so the "Rerouting around
        -- X" follow-up uses the most recent hazard even if the
        -- label shifts from Fire to Hellfire as the surface evolves.
        if not lastHazardAnnouncedLabel then
            local hazardText = FormatHazardLabel(hazardLabel)
            local distanceRounded =
                math.floor(hazardDistance + 0.5)
            Log.Info(string.format(
                "GPS: hazard ahead -- %s at %.1fm",
                hazardText, hazardDistance))
            local hazardSpeech = SpeechData.Create()
            hazardSpeech:AddProperty("Hazard", "Stop", "brief")
            hazardSpeech:AddProperty("Detail", hazardText .. " "
                .. distanceRounded .. " meters ahead", "brief")
            Ext.Tolk.Speak(hazardSpeech:Format(), true)
        end
        lastHazardAnnouncedLabel = hazardLabel
        -- Reset stability counter: the 12m-window warning says
        -- we are NOT clean regardless of whether the full-path
        -- scan agrees.
        hazardClearTickCount = 0
    else
        -- No immediate 12m hazard.  The question now is whether
        -- the full path is also clean (true reroute) or whether
        -- fire is just further out than the warning window.
        if lastHazardAnnouncedLabel then
            if fullPathHasHazard then
                -- Case 3: fire still ahead, just past the warning
                -- cutoff.  Update the label so the next within-12m
                -- tick uses the current hazard, reset the
                -- stability counter, stay silent.
                lastHazardAnnouncedLabel = fullPathHazardLabel
                hazardClearTickCount = 0
                Log.Debug(string.format(
                    "GPS: hazard still on path beyond 12m "
                        .. "(label=%s, node=%d) -- no reroute",
                    fullPathHazardLabel, fullPathHazardIndex))
            else
                -- Full path is clean.  Require the clean state to
                -- persist for GPS_REROUTE_STABILITY_TICKS before
                -- declaring the reroute; single-tick probe jitter
                -- does NOT get to fire the announcement.
                hazardClearTickCount = hazardClearTickCount + 1
                if hazardClearTickCount >= GPS_REROUTE_STABILITY_TICKS then
                    local lengthDelta =
                        newPathLength - lastPathLength
                    local walkedPast =
                        lengthDelta < -REROUTE_SHRINK_TOLERANCE
                    -- Minimum path-shape change required to consider
                    -- this an actual reroute.  A real reroute around
                    -- a fire tile adds at LEAST one tile's worth of
                    -- detour distance (typically several meters for
                    -- a meaningful obstacle).  A delta smaller than
                    -- this is probe jitter: the same path is being
                    -- scanned and the radial probe is flipping
                    -- between "hit fire" and "miss fire" due to
                    -- sub-tile position drift or path smoothing
                    -- rounding.  Announcing a reroute in that case
                    -- is a lie -- the player hears "rerouting" and
                    -- walks straight into the unchanged path of
                    -- fire.  Observed symptom: reroute detected
                    -- with length delta=+0.00m on consecutive ticks
                    -- while the path was still grazing fire edges.
                    local MIN_REROUTE_DELTA_M = 0.5
                    local noRealChange =
                        math.abs(lengthDelta) < MIN_REROUTE_DELTA_M
                    local hazardText = FormatHazardLabel(
                        lastHazardAnnouncedLabel)
                    -- Early exit for the jitter case: suppress the
                    -- announcement, reset the stability counter,
                    -- keep the hazard latch intact so subsequent
                    -- scans can re-evaluate, and skip the
                    -- latch-clearing tail code at the bottom of
                    -- this branch.
                    if noRealChange then
                        Log.Debug(string.format(
                            "GPS: reroute SUPPRESSED -- path "
                                .. "length unchanged (%+.2fm), "
                                .. "probe jitter not a real reroute",
                            lengthDelta))
                        hazardClearTickCount = 0
                    else
                        if walkedPast then
                            Log.Debug(string.format(
                                "GPS: hazard passed -- full path "
                                    .. "clean, length delta=%+.2fm "
                                    .. "(was %.1fm, now %.1fm)",
                                lengthDelta, lastPathLength,
                                newPathLength))
                        else
                            -- Real reroute.  Build a combined
                            -- announcement that includes the new
                            -- steering direction so the player does
                            -- not sit in silence waiting for guidance
                            -- after hearing "rerouting around X".
                            local distanceToTarget = DistanceXZ(
                                playerPosition,
                                trackingTarget.position)
                            local distanceRounded = math.floor(
                                distanceToTarget + 0.5)
                            local steeringTargetPosition =
                                GetSteeringTargetPosition(
                                    playerPosition)
                            local clockHour = nil
                            if steeringTargetPosition then
                                clockHour = ComputeClockDirection(
                                    playerPosition,
                                    steeringTargetPosition)
                            end
                            local directionText = ""
                            if clockHour then
                                directionText = ". "
                                    .. distanceRounded
                                    .. " meters. "
                                    .. clockHour .. " o'clock"
                            end
                            Log.Info(string.format(
                                "GPS: reroute detected -- full path "
                                    .. "clean (%d stable ticks), "
                                    .. "length delta=%+.2fm "
                                    .. "(was %.1fm, now %.1fm)",
                                hazardClearTickCount, lengthDelta,
                                lastPathLength, newPathLength))
                            local rerouteSpeech = SpeechData.Create()
                            rerouteSpeech:AddProperty("Reroute",
                                "Rerouting around " .. hazardText
                                    .. directionText, "brief")
                            Ext.Tolk.Speak(rerouteSpeech:Format(), true)
                            -- Reset the guidance movement baseline
                            -- so subsequent throttled guidance
                            -- measures from the announcement point,
                            -- not from wherever the player last
                            -- heard a direction.
                            lastGuidancePosition = {
                                playerPosition[1],
                                playerPosition[2],
                                playerPosition[3],
                            }
                        end
                        -- Both real-reroute and walked-past clear
                        -- the latch: in both cases the hazard is
                        -- no longer relevant (either we genuinely
                        -- rerouted away from it or the player
                        -- walked past it).
                        lastHazardAnnouncedLabel = nil
                        hazardClearTickCount = 0
                    end
                end
            end
        else
            -- No warning was latched.  Keep the counter at 0 so
            -- the next fresh warning + clean cycle starts from
            -- scratch.
            hazardClearTickCount = 0
        end
    end

    lastPathLength = newPathLength
end

-- Detour analysis constants.
--
-- (Detour classification removed.  Auto-walk handles routing/
-- steering, so the elaborate "Detour" / "approaching_detour" /
-- "on_detour" speech state machine is no longer needed.  The
-- pathfinder still routes around hazards via SurfacePathInfluences;
-- we just don't talk about the path's shape anymore.  Hazard
-- radar (separate cardinal scanner near end of file) still fires
-- for situational awareness.)

-- How far along the path to sample when computing the bearing
-- to the next reachable point.  Using the first path node directly
-- makes the reported clock hour flip wildly when the pathfinder
-- recomputes (node count can bounce 6-40 nodes between consecutive
-- ticks when hazard influence kicks in); the raw first node
-- position shifts by a meter or more across recomputes.  Sampling
-- a FIXED DISTANCE along the path gives us a point that stays in
-- approximately the same world-space location across recomputes
-- because the overall path shape is stable even when node density
-- changes.  3m is enough distance to average out immediate jitter
-- while still being short enough to represent the "next step"
-- direction the player should walk.
local GPS_BEARING_SAMPLE_M = 3.0

--- Bearing from the player to a point GPS_BEARING_SAMPLE_M
--- meters along the given path.  Interpolates between path nodes
--- when the sample distance falls mid-segment.  Falls back to the
--- final node when the entire path is shorter than the sample
--- distance (residual arrival, short routes).  Returns nil when
--- the path is empty or the bearing lookup fails.
local function GetSmoothedPathBearing(playerPosition, path)
    if not path or #path == 0 then return nil end
    if #path == 1 then
        return ComputeClockDirection(playerPosition, path[1])
    end

    -- Walk the path forward from the player's projection onto the
    -- nearest segment.  Accumulating from DistanceXZ(player,
    -- path[1]) would count the distance back to node 1 when the
    -- player has walked past it -- inflating "3 meters ahead" to
    -- "3 + (meters walked past node 1) ahead."  The projection
    -- gives a true "forward distance along path" measurement.
    local nextNodeIndex, distanceForward,
        projectionX, projectionZ =
        GetForwardPathStart(playerPosition, path)
    if not nextNodeIndex then
        return ComputeClockDirection(playerPosition, path[#path])
    end

    -- Case 1: the sample distance lands on the stub segment (from
    -- the projection to path[nextNodeIndex]).  Interpolate within
    -- that segment.
    if distanceForward >= GPS_BEARING_SAMPLE_M then
        local stubEnd = path[nextNodeIndex]
        local stubT = 0
        if distanceForward > 0 then
            stubT = GPS_BEARING_SAMPLE_M / distanceForward
        end
        local samplePoint = {
            projectionX + (stubEnd[1] - projectionX) * stubT,
            stubEnd[2],
            projectionZ + (stubEnd[3] - projectionZ) * stubT,
        }
        return ComputeClockDirection(playerPosition, samplePoint)
    end

    -- Case 2: the sample distance lands past the stub.  Accumulate
    -- along successive segments until we cross the sample distance
    -- or run out of path.
    local accumulated = distanceForward
    local previousNode = path[nextNodeIndex]
    for nodeIndex = nextNodeIndex + 1, #path do
        local node = path[nodeIndex]
        local segmentLength = DistanceXZ(previousNode, node)
        if accumulated + segmentLength
            >= GPS_BEARING_SAMPLE_M then
            local remaining =
                GPS_BEARING_SAMPLE_M - accumulated
            local segmentT = 0
            if segmentLength > 0 then
                segmentT = remaining / segmentLength
            end
            local samplePoint = {
                previousNode[1]
                    + (node[1] - previousNode[1]) * segmentT,
                previousNode[2]
                    + (node[2] - previousNode[2]) * segmentT,
                previousNode[3]
                    + (node[3] - previousNode[3]) * segmentT,
            }
            return ComputeClockDirection(
                playerPosition, samplePoint)
        end
        accumulated = accumulated + segmentLength
        previousNode = node
    end

    -- Whole remaining path shorter than the sample distance:
    -- fall back to bearing to the final node.
    return ComputeClockDirection(playerPosition, path[#path])
end

--- Speech-only tracking guidance.  Called by OnTick once the player
--- has moved at least GPS_GUIDANCE_MOVEMENT meters since the last
--- guidance update.  Assumes UpdateTrackingState has already
--- refreshed currentPath for this tick and has already issued any
--- hazard warnings (hazard detection lives in the silent tick so
--- the player does not have to walk another 2m to hear a warning).
-- Dedup state for guidance speech.  Keeps announcements quiet when
-- nothing material has changed since the last one -- the player
-- hears the bearing once and stays silent until it changes by 2+
-- clock hours, instead of re-announcing every 2m of walking.  Reset
-- on new tracking session (ClearGPSState, StartTracking) so the
-- first announcement of a new route always speaks.
local function ResetGuidanceSpeechDedup()
    NavState.spokenBearing = nil
end

--- Simple guidance speech -- distance and bearing to target.
---
--- Auto-walk handles routing/steering, so the player doesn't need
--- the previous Waze-style turn-by-turn phrasing ("In 4 meters,
--- turn to 12 o'clock", "Detour", etc.).  This stripped-down
--- version just announces "N meters. H o'clock" on bearing change.
--- Hazard radar (separate system) still fires for situational
--- awareness of nearby dangers.
local function SpeakTrackingGuidance(playerPosition)
    if not trackingTarget or not currentPath then return end

    local distanceToTarget = DistanceXZ(
        playerPosition, trackingTarget.position)
    local distanceRounded = math.floor(distanceToTarget + 0.5)

    local bearing = GetSmoothedPathBearing(playerPosition, currentPath)
    if not bearing then return end

    -- Dedup: only re-speak when bearing changes by 2+ clock hours.
    -- One-hour shifts (30 degrees) are noise from pathfinder
    -- recomputes near hazard boundaries.  Distance progress alone
    -- never re-announces; the player knows they're walking.
    local function ClockHourDelta(hourA, hourB)
        local delta = math.abs(hourA - hourB)
        if delta > 6 then delta = 12 - delta end
        return delta
    end

    local shouldSpeak = false
    if not NavState.spokenBearing then
        shouldSpeak = true  -- first announcement of the session
    elseif ClockHourDelta(bearing, NavState.spokenBearing) >= 2 then
        shouldSpeak = true
    end

    local phrase = distanceRounded .. " meters. " .. bearing .. " o'clock"

    -- Distance trend for diagnostic log.
    local trend = ""
    if lastDistanceToTarget then
        local delta = lastDistanceToTarget - distanceToTarget
        if delta > 0.5 then
            trend = " (approaching)"
        elseif delta < -0.5 then
            trend = " (receding)"
        end
    end
    lastDistanceToTarget = distanceToTarget

    -- Log player's actual movement direction vs recommended.  This
    -- stays at Info level even when speech is suppressed -- it's
    -- the primary diagnostic for "why did the GPS tell me Xh" debug.
    local movementClock = nil
    if lastGuidancePosition then
        local moveDist = DistanceXZ(
            playerPosition, lastGuidancePosition)
        if moveDist > 0.5 then
            movementClock = ComputeClockDirection(
                lastGuidancePosition, playerPosition)
        end
    end
    local moveInfo = movementClock
        and (" moved=" .. movementClock .. "h") or ""
    local suppressedTag = shouldSpeak and "" or " [suppressed]"
    Log.Info("GPS: " .. phrase .. trend
        .. " guide=" .. bearing .. "h" .. moveInfo
        .. " nodes=" .. #currentPath
        .. suppressedTag)

    if not shouldSpeak then return end

    local guidanceSpeech = SpeechData.Create()
    guidanceSpeech:AddProperty("Guidance", phrase, "brief")
    Ext.Tolk.Speak(guidanceSpeech:Format(), true)

    NavState.spokenBearing = bearing
end

-- ============================================================================
-- GPS Proximity Mode (announce nearby entities while walking)
-- ============================================================================

--- Tiered proximity announcement.  Called while GPS is in
--- Exploration mode whenever the player has moved
--- GPS_PROXIMITY_POLL_M meters since the last poll.
---
--- Scans all categorized entities from the last ScanAndCategorise
--- pass (rescanning if the player has moved far enough) and
--- processes each according to its distance:
---
---   d <= GPS_PROXIMITY_TIER1_ENTER_M:
---     Tier 1 announcement.  If the entity is not yet in the
---     tier1Latched set, speak its name (no distance, no clock).
---     Add the entity to tier1Latched.
---
---   GPS_PROXIMITY_TIER1_EXIT_M < d <= GPS_PROXIMITY_TIER2_ENTER_M:
---     Tier 2 announcement.  If the entity is not yet in the
---     tier2Latched set, speak "Name. N meters. H o'clock."
---     once.  Add the entity to tier2Latched.  Skipping the
---     3-5m band prevents tier 2 from firing for entities that
---     just left tier 1 but are still within the tier 1 exit
---     buffer -- without this gap the player would hear a tier
---     1 readout at 2m ("Chest"), then a tier 2 readout at 4m
---     ("Chest. 4 meters. 9 o'clock") as they walked past.
---
---   d > GPS_PROXIMITY_TIER1_EXIT_M:
---     Un-latch tier 1 so the next entry from > 5m re-announces.
---
---   d > GPS_PROXIMITY_TIER2_EXIT_M:
---     Un-latch tier 2 as well.
---
--- Entities beyond GPS_PROXIMITY_TIER2_ENTER_M are silent in
--- the speech stream but remain in the scan results for the
--- Routing-mode entity list.  Categories are respected via
--- CategoriseEntity -- scenery and unnamed entities are already
--- filtered out at scan time, so everything in
--- scannedCategories is eligible for tier announcements.
local function ProcessProximityUpdate(playerPosition)
    -- Combat gate: skip proximity tier announcements while in combat.
    -- GPS modes (Exploration / Routing) and auto-walk are still
    -- available in combat (intentional accessibility win), but the
    -- auto-discovery tier announcements ("Proximity Tier 1: Intellect
    -- Devourer", "Proximity Tier 2: Nautiloid Tank") are for free-
    -- world spatial awareness, not combat target select.  When they
    -- fire during combat they queue up and interleave with D-pad
    -- target reads, so the user hears stale "Intellect Devourer" /
    -- "Nautiloid Tank" / "Shadowheart" announcements pushed in front
    -- of the target info they actually pressed for.  Gating here
    -- (not at the caller) catches both the per-tick OnTick path AND
    -- the immediate scan EnterExplorationMode fires on entry/auto-
    -- walk arrival.
    local playerEntity = GetPlayerEntity()
    if playerEntity and IsInCombat(playerEntity) then
        return
    end

    -- Rescan if moved enough.
    if not lastScanPosition
        or DistanceXZ(playerPosition, lastScanPosition)
            >= ENTITY_SCAN_MOVEMENT then
        ScanAndCategorise(playerPosition)
    end

    -- Walk every category, process every entity.  The flat-list
    -- helper sorts by distance, but per-tier hysteresis does not
    -- need sorted order -- the first time an entity crosses
    -- either threshold wins regardless of iteration order.
    local allEntities = GetAllEntitiesFlat()

    -- Track which handles are still live this pass so we can
    -- prune latched entries for entities that have left the scan
    -- radius entirely (and therefore can never exit via the
    -- normal hysteresis check).
    local liveHandles = {}

    for _, entry in ipairs(allEntities) do
        liveHandles[entry.entityKey] = true

        -- Use the live distance from player to entity instead of
        -- the scan-time distance, which may be stale (the scan
        -- only runs every ENTITY_SCAN_MOVEMENT meters but this
        -- poller runs every GPS_PROXIMITY_POLL_M meters).
        local distance = DistanceXZ(
            playerPosition, entry.position)

        if distance <= GPS_PROXIMITY_TIER1_ENTER_M then
            -- Tier 1 candidate.
            if not tier1Latched[entry.entityKey] then
                tier1Latched[entry.entityKey] = true
                -- Entering tier 1 from tier 2 should also ensure
                -- tier 2 is latched so we do not re-announce at
                -- tier 2 on the way out.
                tier2Latched[entry.entityKey] = true
                Log.Info("Proximity Tier 1: " .. entry.name)
                local proxSpeech = SpeechData.Create()
                proxSpeech:Add("name", entry.name, "brief")
                Ext.Tolk.Speak(proxSpeech:Format(), false)
            end
        elseif distance > GPS_PROXIMITY_TIER1_EXIT_M
            and distance <= GPS_PROXIMITY_TIER2_ENTER_M then
            -- Tier 2 candidate.
            if not tier2Latched[entry.entityKey] then
                tier2Latched[entry.entityKey] = true
                -- Cardinal direction (world-relative) instead of
                -- clock-face (camera-relative).  Auto-walk handles
                -- routing-mode steering, so proximity announcements
                -- only need to convey "where on the map" -- which
                -- cardinal does without changing as the user rotates
                -- the camera.  Clock-face stays the choice for
                -- target reads / arrival speech (steering speech).
                local cardinal = ComputeCardinalDirection(
                    playerPosition, entry.position)
                local distanceRounded = math.floor(distance + 0.5)
                local parts = {
                    entry.name,
                    distanceRounded .. " meters",
                }
                if cardinal then
                    table.insert(parts, cardinal)
                end
                local proxSpeech2 = SpeechData.Create()
                proxSpeech2:Add("name", entry.name, "brief")
                proxSpeech2:AddProperty("Distance",
                    distanceRounded .. " meters", "brief")
                if cardinal then
                    proxSpeech2:AddProperty("Direction",
                        cardinal, "normal")
                end
                local speech = proxSpeech2:Format()
                Log.Info("Proximity Tier 2: " .. speech)
                Ext.Tolk.Speak(speech, false)
            end
        end

        -- Hysteresis un-latching.  An entity that has moved past
        -- its exit radius becomes eligible for re-announcement
        -- on the next entry into the tier.
        if distance > GPS_PROXIMITY_TIER1_EXIT_M then
            tier1Latched[entry.entityKey] = nil
        end
        if distance > GPS_PROXIMITY_TIER2_EXIT_M then
            tier2Latched[entry.entityKey] = nil
        end
    end

    -- Prune latched entries for entities no longer in the scan
    -- results.  An entity that left the 30m scan radius is out
    -- of speech range anyway, and leaving its latch set would
    -- leak memory across a long session.
    for handle in pairs(tier1Latched) do
        if not liveHandles[handle] then
            tier1Latched[handle] = nil
        end
    end
    for handle in pairs(tier2Latched) do
        if not liveHandles[handle] then
            tier2Latched[handle] = nil
        end
    end

    lastProximityPosition = {
        playerPosition[1], playerPosition[2], playerPosition[3]
    }
end

-- ============================================================================
-- GPS Control
-- ============================================================================

-- Forward declaration for OpenEntityList, called by EnterRoutingMode.
-- The implementation lives in the Entity List section further down.
local OpenEntityList

--- Clear all GPS runtime state.  Used when leaving any mode.
local function ClearGPSState()
    trackingTarget = nil
    autoWalkActive = nil
    currentPath = nil
    lastGuidancePosition = nil
    lastDistanceToTarget = nil
    lastProximityPosition = nil
    tier1Latched = {}
    tier2Latched = {}
    scannedCategories = {}
    lastScanPosition = nil
    entityListOpen = false
    stuckTickCount = 0
    stuckLastDistance = nil
    blockedAnnounced = false
    lastHazardAnnouncedLabel = nil
    lastPathLength = 0
    lastLoggedDetourLabel = nil
    lastLoggedPathHazardKey = nil
    hazardClearTickCount = 0
    ResetGuidanceSpeechDedup()
    ResetGuidanceSpeechDedup()
    pathWasAvailable = false
    noPathAnnounced = false
    noPathTickCount = 0
    trackingTicks = 0
end

--- Enter Off mode: clear everything and go silent.
local function EnterOffMode()
    gpsMode = GPS_MODE_OFF
    ClearGPSState()
    Log.Info("GPS: Off")
    local offSpeech = SpeechData.Create()
    offSpeech:Add("status", "GPS off", "brief")
    Ext.Tolk.Speak(offSpeech:Format(), true)
end

--- Enter Exploration mode: proximity announcements for nearby entities.
--- Optional introText overrides the default "Exploration mode" speech
--- string so callers that are transitioning from another state (most
--- notably the auto-return after GPS arrival in Routing mode) can
--- deliver a single interrupt speech that combines both messages --
--- "Arriving at <name>. Exploration mode." -- without the mode speech
--- chopping off the arrival speech.  The proximity scan still runs
--- afterwards and announces nearby entities as non-interrupt speech.
---
--- NOTE: assigns to the forward-declared upvalue (no `local` here)
--- so that UpdateTrackingState further up the file can call this
--- function.  See the matching `local EnterExplorationMode`
--- declaration above UpdateTrackingState for the rationale.
function EnterExplorationMode(introText)
    gpsMode = GPS_MODE_EXPLORATION
    tier1Latched = {}
    tier2Latched = {}
    lastProximityPosition = nil
    Log.Info("GPS: Exploration mode")
    local exploSpeech = SpeechData.Create()
    exploSpeech:Add("status", introText or "Exploration mode", "brief")
    Ext.Tolk.Speak(exploSpeech:Format(), true)

    -- Immediate proximity scan.
    local playerEntity = GetPlayerEntity()
    if playerEntity then
        local playerPosition = GetEntityPosition(playerEntity)
        if playerPosition then
            ProcessProximityUpdate(playerPosition)
        end
    end
end

--- Enter Routing mode: open the entity list immediately.  A-selecting
--- a target inside the list starts clock-face tracking.  The intro
--- phrase is passed to OpenEntityList so the initial announcement is
--- built as a single speech string (no interrupt between intro and
--- category readout).
---
--- Pre-builds the hazard set here so the first StartTracking call
--- does not pay the ~900ms lazy-build cost as part of its initial
--- ComputePath -> FindPathHazard pipeline.  The scan runs during
--- the window when the user is listening to the mode announcement
--- and navigating the list, which is idle time in the main thread
--- anyway.
local function EnterRoutingMode()
    gpsMode = GPS_MODE_ROUTING
    tier1Latched = {}
    tier2Latched = {}
    lastProximityPosition = nil
    Log.Info("GPS: Routing mode")
    -- Force the hazard set to build now if it has not been built
    -- yet.  GetHazardousSurfaces is idempotent and cached after
    -- first success.
    pcall(GetHazardousSurfaces)

    -- Choose the entry announcement based on whether the
    -- instructional hint has already fired this gameplay
    -- session.  First entry: full tutorial.  Subsequent entries:
    -- brief mode-name prefix only.  The hint gate resets on
    -- GameStateChanged via ResetState, so reloading a save or
    -- starting a new campaign replays the tutorial once.
    --
    -- TODO settings hook: when BG3Access.Settings.hintsEnabled
    -- exists, AND it into the `not routingHintSpoken` check so
    -- the tutorial can be suppressed entirely by user preference.
    local prefix
    if not routingHintSpoken then
        routingHintSpoken = true
        prefix = "Routing mode. Use left and right to cycle "
            .. "through categories, up and down to view items. "
            .. "Press A on an item to be routed there"
    else
        prefix = "Routing mode"
    end
    OpenEntityList(prefix)
end

--- Cycle GPS mode: Off -> Exploration -> Routing -> Off.
--- GPS works in combat: on your turn, LS still walks the character
--- (subject to remaining movement budget), so pathing announcements
--- and clock-face guidance are meaningful for "walk to the cartilaginous
--- chest and break it" type tactics.  On other characters' turns LS
--- is inert anyway, so guidance just sits silent until your turn.
local function CycleGPSMode()
    if gpsMode == GPS_MODE_OFF then
        EnterExplorationMode()
    elseif gpsMode == GPS_MODE_EXPLORATION then
        EnterRoutingMode()
    else
        EnterOffMode()
    end
end

--- Start tracking to a specific entity (selected from entity list).
--- Always called from EntityListSelect in Routing mode, so the mode is
--- already set; this just binds the target and kicks off the first path.
local function StartTracking(targetEntry)
    if not targetEntry then return end

    local playerEntity = GetPlayerEntity()
    if not playerEntity then
        local noPlayerSpeech = SpeechData.Create()
        noPlayerSpeech:Add("status", "Cannot find player", "brief")
        Ext.Tolk.Speak(noPlayerSpeech:Format(), true)
        return
    end
    local playerPosition = GetEntityPosition(playerEntity)
    if not playerPosition then
        local noPosSpeech = SpeechData.Create()
        noPosSpeech:Add("status", "Cannot get position", "brief")
        Ext.Tolk.Speak(noPosSpeech:Format(), true)
        return
    end

    trackingTarget = {
        entityKey = targetEntry.entityKey,
        name = targetEntry.name,
        position = targetEntry.position,
        entity = targetEntry.entity,
    }
    lastDistanceToTarget = nil
    -- Reset tracking-session state before the first compute so
    -- UpdateTrackingState's transition detection starts clean.
    pathWasAvailable = false
    noPathAnnounced = false
    noPathTickCount = 0
    trackingTicks = 0
    stuckTickCount = 0
    stuckLastDistance = nil
    blockedAnnounced = false
    lastHazardAnnouncedLabel = nil
    lastPathLength = 0
    lastLoggedDetourLabel = nil
    lastLoggedPathHazardKey = nil
    hazardClearTickCount = 0
    ResetGuidanceSpeechDedup()
    ResetGuidanceSpeechDedup()

    local initialPath, initialThreshold = ComputePath(
        playerEntity, playerPosition, trackingTarget.position)
    currentPath = initialPath
    if initialThreshold then
        trackingTarget.arrivalThreshold = initialThreshold
    end

    local distanceToTarget = DistanceXZ(
        playerPosition, trackingTarget.position)
    local distanceRounded = math.floor(distanceToTarget + 0.5)

    if not currentPath then
        SpeechData.Alert(
            "Tracking " .. trackingTarget.name
                .. ". " .. distanceRounded .. " meters. No path",
            "interrupt")
        Log.Info("GPS: Tracking " .. trackingTarget.name
            .. " (" .. distanceRounded .. "m, no path)")
        -- StartTracking owns the initial no-path announcement;
        -- set the latch so UpdateTrackingState does not re-speak
        -- it on the first tick.
        noPathAnnounced = true
        pathWasAvailable = false
    else
        pathWasAvailable = true

        -- Initial track-start announcement: "Tracking X. N meters.
        -- H o'clock".  Auto-walk handles the actual steering, so
        -- the elaborate Waze-style turn-by-turn phrasing is no
        -- longer needed.
        local initialBearing = GetSmoothedPathBearing(
            playerPosition, currentPath)
        local guidancePhrase = nil
        if initialBearing then
            guidancePhrase = distanceRounded .. " meters. "
                .. initialBearing .. " o'clock"
            -- Record initial bearing so SpeakTrackingGuidance does
            -- not re-announce on the first post-tracking movement
            -- tick.  Without this the player would hear the same
            -- phrase twice -- once here, once on the first 2m
            -- guidance cycle.
            NavState.spokenBearing = initialBearing
        end

        -- Warn if the computed path still crosses a hazard
        -- (ComputePath already tried retries; this is the last-
        -- resort fallback path).  Distinguish "hazard at the
        -- destination" from "hazard along the route" based on how
        -- close the first hazard node is to the path's endpoint --
        -- a hazard within 3m of the last node means the target
        -- itself is sitting in or next to fire.
        local hazardIndex, hazardLabel = FindPathHazard(currentPath)
        local hazardText = ""
        if hazardIndex then
            local hazardNode = currentPath[hazardIndex]
            local endNode = currentPath[#currentPath]
            local distanceToEnd = DistanceXZ(hazardNode, endNode)
            local formatted = FormatHazardLabel(hazardLabel)
            if distanceToEnd <= 3.0 then
                hazardText = ". Warning: "
                    .. formatted .. " at destination"
            else
                hazardText = ". Warning: "
                    .. formatted .. " on route"
            end
        end

        -- Tracking-start is an event-driven announcement (user
        -- pressed A on a target), not a focus change, so the
        -- plain-text Alert pathway is the right tool.  Going
        -- through core fields or AddProperty would either
        -- misuse the semantic field labels (name, title, etc.)
        -- or prepend "Tracking:" / "Direction:" filler words
        -- that bury the actionable guidance behind category
        -- labels.  The same pattern is used by combat events,
        -- subregion transitions, and log-level changes.
        local announcement = "Tracking " .. trackingTarget.name
        if guidancePhrase then
            announcement = announcement .. ". " .. guidancePhrase
        else
            announcement = announcement
                .. ". " .. distanceRounded .. " meters"
        end
        if hazardText ~= "" then
            announcement = announcement .. hazardText
        end
        SpeechData.Alert(announcement, "interrupt")

        -- Prime the hazard-warning latch so UpdateTrackingState's
        -- per-tick "Stop. X meters ahead" announcement does NOT
        -- fire on the very next tick after StartTracking.  Without
        -- this the hazard warning interrupts the tracking speech
        -- mid-sentence and the player never hears the direction.
        -- The latch clears naturally when the player exits the
        -- hazard (CheckUpcomingPathHazard returns false for
        -- GPS_REROUTE_STABILITY_TICKS consecutive ticks).
        if hazardIndex then
            lastHazardAnnouncedLabel = hazardLabel
        end

        Log.Info("GPS: Tracking " .. trackingTarget.name
            .. " (" .. distanceRounded .. "m, "
            .. #currentPath .. " nodes"
            .. (hazardIndex and (", hazard=" .. hazardLabel) or "")
            .. ")")
    end

    lastGuidancePosition = {
        playerPosition[1], playerPosition[2], playerPosition[3]
    }
end

-- ============================================================================
-- Auto-walk (engine-driven path following)
--
-- Replaces clock-face tracking for routing-list selections.  The server
-- side fires Osi.CharacterMoveToPosition / CharacterMoveTo, which drives
-- the player character along the engine's pathfinder route -- the same
-- way NPCs walk paths.  No corner-cutting, no per-tick clock-face
-- bearing speech.  We still compute the path locally first for the
-- arrival-summary speech (distance + hazard warnings if any), then
-- hand off to the engine.
--
-- State: autoWalkActive -- non-nil while a request is in flight,
-- cleared when the server reports arrival/cancel/failure.  Used by
-- OnTick to skip clock-face guidance entirely while auto-walk is
-- driving the character.
-- ============================================================================

-- (autoWalkActive declared in the GPS state block above.)

local AUTOWALK_REQUEST_CHANNEL = "BG3Access_AutoWalk"
local AUTOWALK_TRACK_CHANNEL   = "BG3Access_AutoWalk_TrackTarget"
local AUTOWALK_RESULT_CHANNEL  = "BG3Access_AutoWalkResult"

--- Send an auto-walk request to the server and announce the route.
--- Replaces StartTracking for routing-list A-selections.  Returns
--- true if the request was dispatched, false if a precondition
--- (player entity / position / character UUID) failed -- callers
--- can fall back to StartTracking if needed.
local function RequestAutoWalk(targetEntry)
    if not targetEntry then return false end

    local playerEntity = GetPlayerEntity()
    if not playerEntity then
        local noPlayerSpeech = SpeechData.Create()
        noPlayerSpeech:Add("status", "Cannot find player", "brief")
        Ext.Tolk.Speak(noPlayerSpeech:Format(), true)
        return false
    end

    local playerPosition = GetEntityPosition(playerEntity)
    if not playerPosition then
        local noPosSpeech = SpeechData.Create()
        noPosSpeech:Add("status", "Cannot get position", "brief")
        Ext.Tolk.Speak(noPosSpeech:Format(), true)
        return false
    end

    -- Resolve the active player's character UUID.  Osi.CharacterMoveTo
    -- needs a CHARACTER UUID, not the entity userdata.
    local characterUuid = nil
    pcall(function()
        if playerEntity.Uuid and playerEntity.Uuid.EntityUuid then
            characterUuid = tostring(playerEntity.Uuid.EntityUuid)
        end
    end)
    if not characterUuid or characterUuid == "" then
        local noCharSpeech = SpeechData.Create()
        noCharSpeech:Add("status", "Cannot resolve character", "brief")
        Ext.Tolk.Speak(noCharSpeech:Format(), true)
        return false
    end

    -- Compute the path locally so we can announce distance + hazard
    -- warnings.  The engine's auto-walk uses its own pathfinder
    -- (which respects the same hazard-influence weights -- see
    -- ApplyHazardAvoidance -- so the actual path it takes should
    -- match ours), but it doesn't TELL the user "fire on route".
    -- We do that ourselves before handing off.
    local previewPath, _ = ComputePath(
        playerEntity, playerPosition, targetEntry.position)

    local distanceToTarget = DistanceXZ(
        playerPosition, targetEntry.position)
    local distanceRounded = math.floor(distanceToTarget + 0.5)

    -- Hazard summary on the planned route.
    local hazardText = ""
    if previewPath then
        local hazardIndex, hazardLabel = FindPathHazard(previewPath)
        if hazardIndex then
            local hazardNode = previewPath[hazardIndex]
            local endNode = previewPath[#previewPath]
            local distanceToEnd = DistanceXZ(hazardNode, endNode)
            local formatted = FormatHazardLabel(hazardLabel)
            if distanceToEnd <= 3.0 then
                hazardText = ". Warning: " .. formatted
                    .. " at destination"
            else
                hazardText = ". Warning: " .. formatted
                    .. " on route"
            end
        end
    end

    -- Compose announcement.  "Walking to" rather than "Tracking" --
    -- the engine is doing the walking, the user is along for the ride.
    local announcement = "Walking to " .. (targetEntry.name or "target")
        .. ". " .. distanceRounded .. " meters"
        .. hazardText
    SpeechData.Alert(announcement, "interrupt")

    -- Build target identification.  Prefer entity UUID if we have
    -- one (engine can use Osi.CharacterMoveTo with object-based
    -- pathfinding); otherwise fall back to position.
    local targetUuid = nil
    if targetEntry.entity then
        pcall(function()
            if targetEntry.entity.Uuid
                and targetEntry.entity.Uuid.EntityUuid then
                targetUuid = tostring(
                    targetEntry.entity.Uuid.EntityUuid)
            end
        end)
    end

    local request = {
        characterUuid = characterUuid,
        targetUuid    = targetUuid or "",
        position      = {
            x = targetEntry.position[1],
            y = targetEntry.position[2],
            z = targetEntry.position[3],
        },
        targetName    = targetEntry.name or "",
        walkOrRun     = "Walk",
    }
    local jsonOk, jsonStr = pcall(Ext.Json.Stringify, request)
    if not jsonOk then
        Log.Error("AutoWalk: failed to serialize request: "
            .. tostring(jsonStr))
        return false
    end

    -- Tell server which name to associate with this character so the
    -- arrival relay can include it in the result message.  Sent on a
    -- separate channel so the main request payload stays focused on
    -- the Osiris-level arguments.
    local trackJsonOk, trackJsonStr = pcall(Ext.Json.Stringify, {
        characterUuid = characterUuid,
        targetName    = targetEntry.name or "",
    })
    if trackJsonOk then
        pcall(Ext.ClientNet.PostMessageToServer,
            AUTOWALK_TRACK_CHANNEL, trackJsonStr)
    end

    pcall(Ext.ClientNet.PostMessageToServer,
        AUTOWALK_REQUEST_CHANNEL, jsonStr)

    -- Snapshot Tav's position at AutoWalk request time.  The arrival
    -- handler compares request-position to arrival-position to
    -- determine whether the engine actually walked the character or
    -- if a teleport / target-substitution happened (e.g. user changed
    -- target mid-walk and engine kept walking to the original).  Real
    -- walk: actual_position is between start and target.  Teleport:
    -- actual_position is at the target (or some other unrelated point).
    -- No movement: actual_position == start_position.
    local startPosition = nil
    pcall(function()
        local playerEntity = GetPlayerEntity()
        if playerEntity then
            startPosition = GetEntityPosition(playerEntity)
        end
    end)

    autoWalkActive = {
        targetName     = targetEntry.name or "target",
        targetPosition = targetEntry.position,
        startPosition  = startPosition,
    }
    Log.Info("AutoWalk: request sent target=" .. (targetEntry.name or "?")
        .. " distance=" .. distanceRounded .. "m"
        .. (targetUuid and (" uuid=" .. targetUuid) or " by-position")
        .. (startPosition
            and (" start=("
                .. string.format("%.2f", startPosition[1]) .. ","
                .. string.format("%.2f", startPosition[3]) .. ")")
            or ""))
    return true
end

--- Server result listener: arrival / cancellation / failure.
Ext.RegisterNetListener(AUTOWALK_RESULT_CHANNEL,
    function(channel, payload, userId)
        if not autoWalkActive then return end
        local parseOk, result = pcall(Ext.Json.Parse, payload)
        if not parseOk or type(result) ~= "table" then return end
        local eventKind = tostring(result.event or "")
        local cachedTargetName = autoWalkActive.targetName

        if eventKind == "arrived" then
            -- Verify the arrival is real.  The server fires "arrived"
            -- when its CharacterMoveTo bookkeeping considers the move
            -- complete -- but empirically (verified via diagnostic
            -- logging) the "arrived" event ALSO fires when combat
            -- lock-in cancels an in-flight move, even though Tav is
            -- nowhere near the destination.  Compute the actual delta
            -- and decide:
            --   delta < ARRIVAL_TOLERANCE_M  -> real arrival, normal speech
            --   delta >= ARRIVAL_TOLERANCE_M -> false arrival (engine
            --     stopped Tav short).  Speak an honest "walk
            --     interrupted" message instead of lying about arrival.
            local ARRIVAL_TOLERANCE_M = 5.0
            local cachedTargetPosition = autoWalkActive.targetPosition
            local cachedStartPosition = autoWalkActive.startPosition
            local cachedCombatStartPosition =
                autoWalkActive.combatStartPosition
            local actualPosition = nil
            local playerEntity = GetPlayerEntity()
            if playerEntity then
                actualPosition = GetEntityPosition(playerEntity)
            end
            local arrivalDelta = nil
            local distanceWalked = nil
            local duringLockMovement = nil
            if actualPosition and cachedTargetPosition then
                local dx = actualPosition[1] - cachedTargetPosition[1]
                local dz = actualPosition[3] - cachedTargetPosition[3]
                arrivalDelta = math.sqrt(dx*dx + dz*dz)
            end
            if actualPosition and cachedStartPosition then
                local sdx = actualPosition[1] - cachedStartPosition[1]
                local sdz = actualPosition[3] - cachedStartPosition[3]
                distanceWalked = math.sqrt(sdx*sdx + sdz*sdz)
            end
            if actualPosition and cachedCombatStartPosition then
                -- Movement DURING combat lock-in: this is the key
                -- signal for "did the engine teleport Tav after combat
                -- froze him?".  If non-zero, something moved him --
                -- engine fast-resolved a queued CharacterMoveTo, or
                -- a teleport happened.  If zero, Tav was frozen the
                -- whole time and the "arrived" event was a false
                -- positive (we never reached the target).
                local cdx = actualPosition[1]
                    - cachedCombatStartPosition[1]
                local cdz = actualPosition[3]
                    - cachedCombatStartPosition[3]
                duringLockMovement = math.sqrt(cdx*cdx + cdz*cdz)
            end
            local startStr = cachedStartPosition
                and string.format("%.2f,%.2f", cachedStartPosition[1],
                    cachedStartPosition[3]) or "?"
            local targetStr = cachedTargetPosition
                and string.format("%.2f,%.2f", cachedTargetPosition[1],
                    cachedTargetPosition[3]) or "?"
            local actualStr = actualPosition
                and string.format("%.2f,%.2f", actualPosition[1],
                    actualPosition[3]) or "?"
            local combatStartStr = cachedCombatStartPosition
                and string.format("%.2f,%.2f",
                    cachedCombatStartPosition[1],
                    cachedCombatStartPosition[3]) or "?"
            Log.Info("AutoWalk arrival diagnostic: start=(" .. startStr
                .. ") target=(" .. targetStr
                .. ") combat_start=(" .. combatStartStr
                .. ") actual=(" .. actualStr .. ")"
                .. " delta_target="
                .. (arrivalDelta and string.format("%.2fm", arrivalDelta)
                    or "?")
                .. " distance_walked="
                .. (distanceWalked and string.format("%.2fm",
                    distanceWalked) or "?")
                .. " during_lock_movement="
                .. (duringLockMovement
                    and string.format("%.2fm", duringLockMovement)
                    or "?"))
            autoWalkActive = nil
            local trueArrival = arrivalDelta == nil
                or arrivalDelta < ARRIVAL_TOLERANCE_M
            if trueArrival then
                Log.Info("AutoWalk: arrived at " .. cachedTargetName)
            else
                Log.Info("AutoWalk: stopped short of " .. cachedTargetName
                    .. " (delta="
                    .. string.format("%.1fm", arrivalDelta) .. ")")
            end
            local Combat = BG3Access.Client.Combat
            local inCombat = Combat and Combat.IsInCombat
                and Combat.IsInCombat()
            if trueArrival then
                if inCombat then
                    local arrivalSpeech = SpeechData.Create()
                    arrivalSpeech:Add("status",
                        "Arrived at " .. cachedTargetName, "brief")
                    Ext.Tolk.Speak(arrivalSpeech:Format(), true)
                else
                    EnterExplorationMode(
                        "Arrived at " .. cachedTargetName
                            .. ". Exploration mode.")
                end
            else
                -- False arrival: BG3 cancelled the move (typically combat
                -- lock-in) but still fired the "arrived" event.  Tell
                -- the user where they actually ended up, in distance
                -- terms.  Don't enter Exploration mode -- stay in
                -- whatever state we were in.
                local distanceText = string.format("%.0f",
                    arrivalDelta)
                local interruptSpeech = SpeechData.Create()
                interruptSpeech:Add("status",
                    "Walk interrupted, " .. distanceText
                    .. " meters from " .. cachedTargetName, "brief")
                Ext.Tolk.Speak(interruptSpeech:Format(), true)
            end
        elseif eventKind == "failed" or eventKind == "cancelled" then
            autoWalkActive = nil
            Log.Info("AutoWalk: " .. eventKind
                .. " for " .. cachedTargetName)
            local statusSpeech = SpeechData.Create()
            statusSpeech:Add("status",
                "Walk to " .. cachedTargetName .. " " .. eventKind,
                "brief")
            Ext.Tolk.Speak(statusSpeech:Format(), true)
        end
    end)

-- ============================================================================
-- Entity List
-- ============================================================================

--- Get the list of entities for the current category.
local function GetCurrentCategoryEntities()
    local categoryName = CATEGORY_NAMES[currentCategoryIndex]
    return scannedCategories[categoryName] or {}
end

--- Build speech string for an entity list entry.
--- Reports name and straight-line distance only.  Clock direction is
--- deliberately omitted: the list has no path, so any direction it
--- reports would be the direct bearing, which disagrees with the path
--- tangent announced during routing.  A user hearing two different
--- clock readings for the same item would walk in the wrong direction.
--- The real walk direction arrives once tracking starts.
local function FormatEntitySpeech(playerPosition, entry)
    local _, distance = ComputeClockDirection(
        playerPosition, entry.position)
    local distanceRounded = math.floor(
        (distance or entry.distance) + 0.5)
    return entry.name .. ". " .. distanceRounded .. " meters"
end

--- Announce the current item (no category prefix).
local function AnnounceCurrentListItem(playerPosition)
    local categoryName = CATEGORY_NAMES[currentCategoryIndex]
    local entities = GetCurrentCategoryEntities()
    if #entities == 0 then return end

    local entry = entities[currentItemIndex]
    if not entry then
        currentItemIndex = 1
        entry = entities[1]
    end

    local speech = FormatEntitySpeech(playerPosition, entry)
    Log.Info("List [" .. categoryName .. " "
        .. currentItemIndex .. "/" .. #entities .. "]: " .. speech)
    local listSpeech = SpeechData.Create()
    listSpeech:Add("name", speech, "brief")
    Ext.Tolk.Speak(listSpeech:Format(), true)
end

--- Announce category name then first item in a single speech.
--- Optional prefix is prepended to the category line so an intro
--- phrase ("Routing mode" or the first-time tutorial) plays in
--- the same interrupt without the category speech chopping it off.
---
--- Empty categories say "None" and stay on the current category.
--- The d-pad up/down navigation in EntityListItemNext /
--- EntityListItemPrevious bails out on empty lists, so pressing
--- up/down after landing on an empty category is silent.  Use
--- d-pad left/right to move to another category.
local function AnnounceCategorySwitch(playerPosition, prefix)
    local categoryName = CATEGORY_NAMES[currentCategoryIndex]
    local entities = GetCurrentCategoryEntities()
    currentItemIndex = 1

    local prefixText = ""
    if prefix and prefix ~= "" then
        prefixText = prefix .. ". "
    end

    if #entities == 0 then
        Log.Info("List [" .. categoryName .. "]: empty")
        local emptySpeech = SpeechData.Create()
        if prefixText ~= "" then
            emptySpeech:Add("status", prefix, "brief")
        end
        emptySpeech:Add("sectionLabel", categoryName, "brief")
        emptySpeech:Add("status", "None", "brief")
        Ext.Tolk.Speak(emptySpeech:Format(), true)
    else
        local firstEntry = entities[1]
        local itemSpeech = FormatEntitySpeech(
            playerPosition, firstEntry)
        Log.Info("List [" .. categoryName .. " 1/"
            .. #entities .. "]: " .. itemSpeech)
        local catSpeech = SpeechData.Create()
        if prefixText ~= "" then
            catSpeech:Add("status", prefix, "brief")
        end
        catSpeech:Add("sectionLabel", categoryName, "brief")
        catSpeech:AddProperty("First item", itemSpeech, "brief")
        Ext.Tolk.Speak(catSpeech:Format(), true)
    end
end

-- Bind to the forward-declared OpenEntityList so EnterRoutingMode
-- (defined earlier) can call it.
function OpenEntityList(prefix)
    local playerEntity = GetPlayerEntity()
    if not playerEntity then
        local noPlayerSpeech = SpeechData.Create()
        noPlayerSpeech:Add("status", "Cannot find player", "brief")
        Ext.Tolk.Speak(noPlayerSpeech:Format(), true)
        return
    end
    local playerPosition = GetEntityPosition(playerEntity)
    if not playerPosition then
        local noPosSpeech = SpeechData.Create()
        noPosSpeech:Add("status", "Cannot get position", "brief")
        Ext.Tolk.Speak(noPosSpeech:Format(), true)
        return
    end

    ScanAndCategorise(playerPosition)
    entityListOpen = true
    currentCategoryIndex = 1
    currentItemIndex = 1

    Log.Info("Entity list opened")
    AnnounceCategorySwitch(playerPosition, prefix)
end

local function CloseEntityList()
    if entityListOpen then
        entityListOpen = false
        Log.Debug("Entity list closed")
    end
end

local function EntityListCategoryNext()
    if not entityListOpen then return end
    currentCategoryIndex = currentCategoryIndex + 1
    if currentCategoryIndex > #CATEGORY_NAMES then
        currentCategoryIndex = 1
    end
    local playerEntity = GetPlayerEntity()
    if not playerEntity then return end
    local playerPosition = GetEntityPosition(playerEntity)
    if not playerPosition then return end
    AnnounceCategorySwitch(playerPosition)
end

local function EntityListCategoryPrevious()
    if not entityListOpen then return end
    currentCategoryIndex = currentCategoryIndex - 1
    if currentCategoryIndex < 1 then
        currentCategoryIndex = #CATEGORY_NAMES
    end
    local playerEntity = GetPlayerEntity()
    if not playerEntity then return end
    local playerPosition = GetEntityPosition(playerEntity)
    if not playerPosition then return end
    AnnounceCategorySwitch(playerPosition)
end

local function EntityListItemNext()
    if not entityListOpen then return end
    local entities = GetCurrentCategoryEntities()
    if #entities == 0 then return end
    currentItemIndex = currentItemIndex + 1
    if currentItemIndex > #entities then
        currentItemIndex = 1
    end
    local playerEntity = GetPlayerEntity()
    if not playerEntity then return end
    local playerPosition = GetEntityPosition(playerEntity)
    if not playerPosition then return end
    AnnounceCurrentListItem(playerPosition)
end

local function EntityListItemPrevious()
    if not entityListOpen then return end
    local entities = GetCurrentCategoryEntities()
    if #entities == 0 then return end
    currentItemIndex = currentItemIndex - 1
    if currentItemIndex < 1 then
        currentItemIndex = #entities
    end
    local playerEntity = GetPlayerEntity()
    if not playerEntity then return end
    local playerPosition = GetEntityPosition(playerEntity)
    if not playerPosition then return end
    AnnounceCurrentListItem(playerPosition)
end

local function EntityListSelect()
    if not entityListOpen then return end
    local entities = GetCurrentCategoryEntities()
    if #entities == 0 then
        local emptySelectSpeech = SpeechData.Create()
        emptySelectSpeech:Add("status",
            "Nothing to select", "brief")
        Ext.Tolk.Speak(emptySelectSpeech:Format(), true)
        return
    end
    local entry = entities[currentItemIndex]
    if not entry then return end

    CloseEntityList()
    -- Auto-walk via Osi.CharacterMoveTo: the engine drives the
    -- character along its own pathfinder route (same one our
    -- clock-face was approximating).  Replaces StartTracking, which
    -- compressed the multi-segment path into per-tick clock-face
    -- bearings and cut corners through walls / fire.  StartTracking
    -- is still defined (above) as a fallback in case auto-walk
    -- can't dispatch (no character UUID, etc.).
    if not RequestAutoWalk(entry) then
        StartTracking(entry)
    end
end

-- ============================================================================
-- Hazard radar (always-on, all directions)
--
-- Single unified scan that runs at 1Hz regardless of GPS mode or combat
-- state.  Subsumes the previous motion-only look-ahead.  Probes 8
-- cardinal directions at 3 distance shells (24 samples total, center-
-- only -- no ring); reports both the "I'm walking into fire" case
-- (interrupt urgency, "ahead" wording) and the "fire is to my east, I
-- shouldn't go that way" case (queued, cardinal wording).
--
-- Distances are tuned for plenty of reaction time:
--   6m   -- close (~1s walk / 1s run after speech latency)
--   12m  -- moderate (~2.5s walk, ~2s run)
--   18m  -- far heads-up (~3.5s walk, ~3s run)
--
-- Per-direction we report the CLOSEST hit only -- multiple distances
-- per direction would just spam.
-- ============================================================================

-- Hazard radar wrapped in an IIFE so its 8 internal constants/state
-- vars don't count against the main function's 200-local limit.  The
-- IIFE returns ScanRadialHazards, which is the only main-scope local
-- this whole subsystem now consumes.  Same behaviour as before --
-- just scoped tighter to free up local slots elsewhere in the file.
local ScanRadialHazards = (function()
    local DISTANCES = { 6, 12, 18 }

    -- Cardinal labels and unit vectors (world-relative).  +Z = north;
    -- order matches CARDINAL_LABELS used by ComputeCardinalDirection
    -- so direction strings are consistent across speech sources.
    local DIRECTIONS = {
        { label = "north",     dirX =  0,        dirZ =  1        },
        { label = "northeast", dirX =  0.707107, dirZ =  0.707107 },
        { label = "east",      dirX =  1,        dirZ =  0        },
        { label = "southeast", dirX =  0.707107, dirZ = -0.707107 },
        { label = "south",     dirX =  0,        dirZ = -1        },
        { label = "southwest", dirX = -0.707107, dirZ = -0.707107 },
        { label = "west",      dirX = -1,        dirZ =  0        },
        { label = "northwest", dirX = -0.707107, dirZ =  0.707107 },
    }

    -- Half-cone (radians) for classifying a hazard direction as "ahead"
    -- relative to player motion.  pi/8 = 22.5 degrees, half a cardinal
    -- bucket -- so a hazard within +/- 22.5deg of the motion vector
    -- counts as "ahead" (urgent interrupt warning).  Outside that cone
    -- it's "side/back" (queued cardinal warning).
    local AHEAD_CONE_RAD = math.pi / 8

    -- Minimum motion (meters) per tick to count as "moving".  Below
    -- this the player is stationary -- ALL hits classify as side/
    -- cardinal, nothing as "ahead".  No motion vector to compare.
    local MIN_MOTION_M = 0.3

    -- Per-(label + direction) dedup window.  Same hazard, same
    -- compass direction, fired less than this ago: suppress.  Re-arms
    -- on different hazard, different direction, or after the window.
    local REPEAT_MS = 30000

    -- Throttle: scan runs at most this often regardless of position-
    -- check cadence.  Same 1Hz cap the proximity tier scan uses.
    local MIN_INTERVAL_MS = 1000

    local lastMs = 0
    local dedup = {}  -- {[label .. ":" .. direction] = timestampMs}

    return function(playerPosition, previousPosition)
        if not playerPosition then return end

        -- Skip during auto-walk: engine pathfinder routes around
        -- hazards via SurfacePathInfluences and the user has no
        -- manual steering input to react to a warning anyway.
        if autoWalkActive then return end

        -- Skip during menus: game is paused, no movement is happening,
        -- hazard announcements just clutter the menu's speech queue
        -- ("PauseMenu reads Resume" + "fire south 6m" interleaved is
        -- chaotic).  The HazardRadar runs in OnTick BEFORE the
        -- gpsMode==OFF early-return, so SuspendForMenu's gpsMode
        -- flip doesn't gate it -- this explicit check does.
        local Menus = BG3Access.Client.Menus
        if Menus and Menus.GetActiveHandler
            and Menus.GetActiveHandler() then
            return
        end

        -- 1Hz throttle.
        local nowMs = Ext.Utils.MonotonicTime()
        if nowMs - lastMs < MIN_INTERVAL_MS then
            return
        end
        lastMs = nowMs

        -- Compute motion vector if there is meaningful motion.  When
        -- stationary, motionDir stays nil and no hits get classified
        -- as "ahead" -- everything reports as cardinal.
        local motionDirX, motionDirZ = nil, nil
        if previousPosition then
            local dx = playerPosition[1] - previousPosition[1]
            local dz = playerPosition[3] - previousPosition[3]
            local dlen = math.sqrt(dx * dx + dz * dz)
            if dlen >= MIN_MOTION_M then
                motionDirX = dx / dlen
                motionDirZ = dz / dlen
            end
        end

        -- Per-direction scan.  For each cardinal, walk distance
        -- shells ascending -- first hit (closest) wins for that
        -- direction.
        for _, dir in ipairs(DIRECTIONS) do
            local hitDistance, hitLabel = nil, nil
            for _, distance in ipairs(DISTANCES) do
                local sample = {
                    playerPosition[1] + dir.dirX * distance,
                    playerPosition[2],
                    playerPosition[3] + dir.dirZ * distance,
                }
                local hit, label = CheckPositionHazard(sample)
                if hit then
                    hitDistance = distance
                    hitLabel = label
                    break
                end
            end
            if hitLabel then
                -- Dedup: label + direction + window.
                local dedupKey = hitLabel .. ":" .. dir.label
                local prevMs = dedup[dedupKey] or 0
                if nowMs - prevMs >= REPEAT_MS then
                    dedup[dedupKey] = nowMs

                    -- Classify ahead vs cardinal based on whether
                    -- this direction lies within the motion cone.
                    -- Dot product with the cardinal unit vector:
                    -- cos(angle) >= cos(cone).
                    local isAhead = false
                    if motionDirX then
                        local dot = motionDirX * dir.dirX
                            + motionDirZ * dir.dirZ
                        if dot >= math.cos(AHEAD_CONE_RAD) then
                            isAhead = true
                        end
                    end

                    local labelText = FormatHazardLabel(hitLabel)
                    local distRounded = math.floor(hitDistance + 0.5)
                    local warning, interrupt
                    if isAhead then
                        warning = "Caution, " .. labelText
                            .. " ahead, " .. distRounded .. " meters"
                        interrupt = true
                    else
                        warning = labelText .. ", " .. dir.label
                            .. ", " .. distRounded .. " meters"
                        interrupt = false
                    end
                    Log.Info("HazardRadar: " .. warning
                        .. (isAhead and " [AHEAD]" or " [SIDE]"))
                    Ext.Tolk.Speak(warning, interrupt)
                end
            end
        end
    end
end)()

-- ============================================================================
-- Tick Handler
-- ============================================================================

local function OnTick()
    local now = Ext.Utils.MonotonicTime()
    if now - lastPositionCheckTime < POSITION_CHECK_MS then return end
    lastPositionCheckTime = now

    local playerEntity = GetPlayerEntity()
    if not playerEntity then return end
    local playerPosition = GetEntityPosition(playerEntity)
    if not playerPosition then return end

    local previousPosition = lastPlayerPosition
    lastPlayerPosition = playerPosition

    if not previousPosition then return end

    -- Always-on hazard radar.  Probes 8 cardinal directions at 3
    -- distance shells (6/12/18m); reports motion-direction hits as
    -- urgent "ahead" interrupts and side hits as queued cardinal
    -- announcements.  Subsumes the previous motion-only look-ahead.
    -- Independent of GPS mode and combat state.  Throttled to 1Hz
    -- inside the function; per-direction dedup prevents repeats.
    ScanRadialHazards(playerPosition, previousPosition)

    if gpsMode == GPS_MODE_OFF then return end

    -- Routing mode with active target.  Work split:
    --   UpdateTrackingState: runs every tick.  Silent.  Recomputes
    --     the path against the current world state, checks arrival,
    --     updates internal bookkeeping.  Never speaks a direction.
    --   SpeakTrackingGuidance: runs only when the player has actually
    --     walked GPS_GUIDANCE_MOVEMENT meters since the last time
    --     guidance was spoken.  Speaks the clock/distance/hazard.
    --   Stuck detection: track distance-to-target deltas across ticks;
    --     speak "Path blocked" ONCE when the player has stalled for
    --     GPS_STUCK_TICKS checks.  Do not re-speak until the player
    --     starts making progress again (blockedAnnounced latch).
    if trackingTarget then
        if not lastGuidancePosition then
            lastGuidancePosition = playerPosition
        end

        trackingTicks = trackingTicks + 1

        -- Silent work: path recompute + arrival check + hazard scan.
        UpdateTrackingState(playerPosition)
        -- UpdateTrackingState may have cleared trackingTarget on
        -- arrival; in that case, fall through to the cleanup path.
        if not trackingTarget then
            stuckTickCount = 0
            stuckLastDistance = nil
            blockedAnnounced = false
            lastHazardAnnouncedLabel = nil
            lastPathLength = 0
            lastLoggedDetourLabel = nil
            lastLoggedPathHazardKey = nil
            hazardClearTickCount = 0
            noPathTickCount = 0
            trackingTicks = 0
            return
        end

        -- Stuck detection runs only when we actually have a path to
        -- follow and the tracking session has had a grace period to
        -- give the player time to react.  Without the grace period
        -- the first guidance update is spoken at the same time as
        -- the stuck counter starts, which falsely fires "Path
        -- blocked" before the player has had a chance to move.
        --
        -- Additional close-range exclusion: within the arrival
        -- vicinity (arrivalThreshold + GPS_STUCK_CLOSE_RANGE_PAD)
        -- the player is circling the target, path shape oscillates
        -- as they move, and straight-line distance bounces around
        -- without net decrease for long stretches.  That's the
        -- endgame, not a blockage -- suppress stuck detection
        -- entirely until either arrival fires or they back out of
        -- the vicinity.  Fixes the spammy "stuck (6 ticks, dist=1.62)"
        -- false positives observed on the Mind Flayer Pod approach.
        local currentDistanceToTarget = DistanceXZ(
            playerPosition, trackingTarget.position)
        local arrivalThreshold =
            (trackingTarget.arrivalThreshold
                or GetMoveToCloseEnoughMax())
        local inArrivalVicinity =
            currentDistanceToTarget
                <= (arrivalThreshold + GPS_STUCK_CLOSE_RANGE_PAD)
        local stuckEligible =
            currentPath
            and trackingTicks > GPS_STUCK_GRACE_TICKS
            and not inArrivalVicinity
        if stuckEligible then
            if stuckLastDistance == nil then
                stuckLastDistance = currentDistanceToTarget
                stuckTickCount = 0
            else
                local progress =
                    stuckLastDistance - currentDistanceToTarget
                if progress >= GPS_PROGRESS_DELTA then
                    -- Player is making real progress: reset the
                    -- counter and drop the blocked-announce latch
                    -- so the next stall can report blocked again.
                    stuckLastDistance = currentDistanceToTarget
                    stuckTickCount = 0
                    blockedAnnounced = false
                else
                    stuckTickCount = stuckTickCount + 1
                    if stuckTickCount >= GPS_STUCK_TICKS
                        and not blockedAnnounced then
                        Log.Info(string.format(
                            "GPS: stuck (%d ticks, dist=%.2f)",
                            stuckTickCount,
                            currentDistanceToTarget))
                        local blockedSpeech = SpeechData.Create()
                        blockedSpeech:Add("status",
                            "Path blocked", "brief")
                        Ext.Tolk.Speak(blockedSpeech:Format(), true)
                        blockedAnnounced = true
                    end
                end
            end
        else
            -- Either no path yet or still in grace period: keep
            -- the counters clean so stuck detection starts from
            -- zero when it becomes eligible.
            stuckTickCount = 0
            stuckLastDistance = nil
        end

        -- Speech: only fires on actual player movement AND when
        -- there is a path to speak about.  When the path is nil we
        -- already announced "No path to <target>" once via
        -- UpdateTrackingState and there is nothing to say until
        -- the path becomes available again.
        if currentPath then
            local movementSinceGuidance = DistanceXZ(
                playerPosition, lastGuidancePosition)
            if movementSinceGuidance >= GPS_GUIDANCE_MOVEMENT then
                SpeakTrackingGuidance(playerPosition)
                lastGuidancePosition = {
                    playerPosition[1],
                    playerPosition[2],
                    playerPosition[3]
                }
            end
        end
        return
    end

    -- Not tracking anymore; clear stuck-detection, hazard, and
    -- tracking-tick state so the next target starts with a clean
    -- slate.
    stuckTickCount = 0
    stuckLastDistance = nil
    blockedAnnounced = false
    lastHazardAnnouncedLabel = nil
    lastPathLength = 0
    lastLoggedDetourLabel = nil
    lastLoggedPathHazardKey = nil
    hazardClearTickCount = 0
    noPathTickCount = 0
    trackingTicks = 0

    -- Proximity announcements only run in Exploration mode.  Routing
    -- without a picked target yet (entity list still open, or closed
    -- without selection) stays silent.
    if gpsMode ~= GPS_MODE_EXPLORATION then return end

    if not lastProximityPosition then
        lastProximityPosition = playerPosition
    end
    local movementSinceProximity = DistanceXZ(
        playerPosition, lastProximityPosition)
    if movementSinceProximity < GPS_PROXIMITY_POLL_M then
        return
    end

    -- Hard time throttle: ProcessProximityUpdate iterates the full
    -- categorised entity list and (when ENTITY_SCAN_MOVEMENT is met)
    -- triggers a fresh ScanEntities + ClassifyScannedEntities cycle.
    -- Each invocation runs on the render thread.  In normal play the
    -- 2m movement gate keeps frequency well under 1Hz, but during
    -- post-combat chaos -- active character moving toward a downed
    -- party member through a cluster of corpses, classify responses
    -- arriving in bursts, the GPS auto-flipping back to Exploration
    -- on arrival -- the gate can fire several times per second and
    -- stack 25-30ms ticks until Windows flags bg3.exe "not responding".
    -- 1Hz is plenty for accessibility; the user can't act on faster
    -- proximity announcements anyway.
    local nowMs = Ext.Utils.MonotonicTime()
    local PROXIMITY_MIN_INTERVAL_MS = 1000
    if nowMs - lastProximityUpdateMs < PROXIMITY_MIN_INTERVAL_MS then
        return
    end
    lastProximityUpdateMs = nowMs

    ProcessProximityUpdate(playerPosition)
end

-- ============================================================================
-- HUD readers (SpeakCharacterInfo / SpeakTargetInfo / SpeakActionResources)
-- and their helpers (FormatAmount, ReadMovementResource) live in
-- HUDReader.lua -- they're not GPS/navigation, and keeping them here
-- pushed the file past Lua 5.1's 200-locals-per-chunk cap.
-- ============================================================================

-- ============================================================================
-- Controller Input (entity list navigation + tracking-cancel)
-- ============================================================================

--- Clear an active tracking target and all associated path / hazard /
--- stuck-detection state.  Shared by the routing-list B handler (clear
--- target without exiting the list) and the global tracking-active B
--- handler (cancel from the no-list-open mid-route state).
--- Returns the cancelled target's name for the caller to use in
--- announcements, or nil if no target was active.
local function CancelTrackingTarget()
    if not trackingTarget then return nil end
    local cancelledName = trackingTarget.name or "target"
    trackingTarget = nil
    currentPath = nil
    lastGuidancePosition = nil
    lastDistanceToTarget = nil
    stuckTickCount = 0
    stuckLastDistance = nil
    blockedAnnounced = false
    lastHazardAnnouncedLabel = nil
    lastPathLength = 0
    lastLoggedDetourLabel = nil
    lastLoggedPathHazardKey = nil
    hazardClearTickCount = 0
    pathWasAvailable = false
    noPathAnnounced = false
    noPathTickCount = 0
    trackingTicks = 0
    ResetGuidanceSpeechDedup()
    ResetGuidanceSpeechDedup()
    return cancelledName
end

local function OnControllerButton(event)
    if not event.Pressed then return end

    -- Defer ALL world-context button handling when a menu handler is
    -- active.  This handler manages the GPS routing list and tracking-
    -- cancel, both of which only make sense while the player is in
    -- the world.  Without this gate:
    --   * Pause menu opens with GPS list still open (entityListOpen=true)
    --     -> any B press the user makes to dismiss the pause menu gets
    --     eaten by our list-close handler instead of routing to the
    --     menu.  The pause menu then can't speak / dismiss cleanly
    --     until the user accidentally closes the GPS list first.
    --   * D-pad in the menu would be ambiguously routed (menu nav vs.
    --     our list category cycling).
    -- The menu's own handler (Menus.lua) owns input while it's active;
    -- we just step out of the way.
    local Menus = BG3Access.Client.Menus
    if Menus and Menus.GetActiveHandler and Menus.GetActiveHandler() then
        return
    end

    local buttonName = tostring(event.Button)

    -- Global tracking-cancel: B while actively tracking with the list
    -- closed.  Conditions are deliberately strict so we don't steal
    -- B from BG3's other contexts (dialog cancel, spell-cast abort,
    -- menu close, etc.) -- only fires when GPS owns the press:
    --   * Routing mode AND
    --   * trackingTarget set (actively guiding) AND
    --   * entityListOpen false (list-open case is handled below).
    if buttonName == "B"
        and gpsMode == GPS_MODE_ROUTING
        and trackingTarget
        and not entityListOpen then
        event:PreventAction()
        local cancelledName = CancelTrackingTarget()
        EnterExplorationMode(
            "Tracking cancelled, " .. (cancelledName or "target")
            .. ", exploration mode")
        return
    end

    if not entityListOpen then return end

    if buttonName == "DPadLeft" then
        event:PreventAction()
        EntityListCategoryPrevious()
    elseif buttonName == "DPadRight" then
        event:PreventAction()
        EntityListCategoryNext()
    elseif buttonName == "DPadUp" then
        event:PreventAction()
        EntityListItemPrevious()
    elseif buttonName == "DPadDown" then
        event:PreventAction()
        EntityListItemNext()
    elseif buttonName == "A" then
        event:PreventAction()
        EntityListSelect()
    elseif buttonName == "B" then
        event:PreventAction()
        -- Two-stage cancel from the routing list:
        --   1. List open + tracking a target -> first B clears the
        --      target only.  List stays open so the user can browse
        --      and pick a different one without exiting to
        --      Exploration first.
        --   2. List open + no active target -> B closes the list
        --      and reverts GPS to Exploration.  One press instead
        --      of cycling RS-Left through GPS modes.
        local cancelledName = CancelTrackingTarget()
        if cancelledName then
            local clearSpeech = SpeechData.Create()
            clearSpeech:Add("status",
                "Tracking cancelled, " .. cancelledName, "brief")
            Ext.Tolk.Speak(clearSpeech:Format(), true)
            return
        end
        CloseEntityList()
        EnterExplorationMode("Routing cancelled, exploration mode")
    end
end

-- ============================================================================
-- Console Commands
-- ============================================================================

local function PathDiagnostic()
    if not currentPath then
        Log.Info("PATHDIAG: No active path")
        return
    end
    local playerEntity = GetPlayerEntity()
    if not playerEntity then
        Log.Info("PATHDIAG: Cannot find player")
        return
    end
    local playerPosition = GetEntityPosition(playerEntity)
    if not playerPosition then
        Log.Info("PATHDIAG: Cannot get position")
        return
    end

    Log.Info("PATHDIAG: " .. #currentPath .. " nodes")
    if trackingTarget then
        local distanceToTarget = DistanceXZ(
            playerPosition, trackingTarget.position)
        Log.Info("PATHDIAG: Target=" .. trackingTarget.name
            .. " dist=" .. string.format("%.1f", distanceToTarget)
            .. "m")
    end

    -- Print the first 10 nodes of the current (freshly-recomputed)
    -- path with their distance from the player and clock direction.
    local endNode = math.min(#currentPath, 10)
    for nodeIndex = 1, endNode do
        local node = currentPath[nodeIndex]
        local distanceFromPlayer = DistanceXZ(playerPosition, node)
        local clockHour = ComputeClockDirection(playerPosition, node)
        Log.Info(string.format("  [%d] dist=%.1f clock=%s",
            nodeIndex, distanceFromPlayer,
            clockHour and (clockHour .. "h") or "?"))
    end
end

-- ============================================================================
-- Public API
-- ============================================================================

local function ResetState()
    gpsMode = GPS_MODE_OFF
    trackingTarget = nil
    currentPath = nil
    lastPlayerPosition = nil
    lastGuidancePosition = nil
    lastDistanceToTarget = nil
    lastProximityPosition = nil
    tier1Latched = {}
    tier2Latched = {}
    scannedCategories = {}
    lastScanPosition = nil
    entityListOpen = false
    currentCategoryIndex = 1
    currentItemIndex = 1
    stuckTickCount = 0
    stuckLastDistance = nil
    blockedAnnounced = false
    lastHazardAnnouncedLabel = nil
    lastPathLength = 0
    lastLoggedDetourLabel = nil
    lastLoggedPathHazardKey = nil
    hazardClearTickCount = 0
    ResetGuidanceSpeechDedup()
    ResetGuidanceSpeechDedup()
    pathWasAvailable = false
    noPathAnnounced = false
    noPathTickCount = 0
    trackingTicks = 0
    lastPositionCheckTime = 0
    -- Hint gates reset on state transitions (new save load, new
    -- campaign, etc.) so the first Routing mode entry after a
    -- GameStateChanged plays the instructional tutorial again.
    -- Matches the radialHintSpoken reset in WorldUI.lua.
    routingHintSpoken = false
    -- Clear the server-side template data cache and raw scan
    -- buffer so a new level load fetches fresh template data.
    entityClassifyCache = {}
    classifyRequestPending = false
    scannedEntitiesRaw = {}
    Log.Debug("WorldNav: State reset")
end

local function PauseGPS()
    -- Temporarily suppress GPS updates (e.g. during menus).
    -- Mode stays set but tracking/proximity are paused via the gpsMode
    -- check in OnTick.  State preserved for resume.
    Log.Debug("WorldNav: GPS paused")
end

local function ResumeGPS()
    Log.Debug("WorldNav: GPS resumed")
end

local function IsGPSActive()
    return gpsMode ~= GPS_MODE_OFF
end

--- Force GPS off in response to combat start.  Combat's HandleCombatStarted
--- calls this so that:
---   - gpsMode flips to OFF -- OnTick stops running proximity scans,
---     hazard radar, guidance announcements during enemy turns.
---   - The entity list closes if it was open (handled by ClearGPSState).
---   - Any active tracking target / path / proximity latch state is
---     dropped so resume after combat starts from a clean slate.
---
--- IMPORTANT: autoWalkActive is PRESERVED across the clear.  We don't
--- cancel the in-flight AutoWalk (BG3 will decide whether to finish or
--- abort the CharacterMoveTo on its own based on combat lock-in
--- semantics, and the user explicitly does not want us forcing a
--- cancel).  If the engine completes the walk -- which it sometimes
--- does even mid-combat for a movement that was nearly done -- the
--- arrival callback still needs to know about the active walk so it
--- can speak "Arrived at <target>".  The arrival callback checks
--- IsInCombat itself and speaks WITHOUT flipping GPS to Exploration.
---
--- Quiet: does NOT speak "GPS off" (combat speech is already busy with
--- Initiative + first turn announcement; an extra alert would drown
--- those out and confuse the user).
--- Force GPS off in response to a menu activation (pause menu, options,
--- save/load, etc.).  Called by Menus.lua when an explicit menu handler
--- takes over from the world handler so:
---   - The entity routing list closes immediately (otherwise our
---     OnControllerButton's entityListOpen branch would intercept B
---     presses meant for the menu).
---   - Tracking guidance / proximity scans / hazard radar stop firing
---     during the menu (game is paused, no movement, those announcements
---     just clutter the menu's speech).
---   - User returns from the menu to a clean GPS-off state and re-engages
---     manually with RS-Left when ready.
---
--- Quiet (the menu is announcing itself; an extra "GPS off" alert would
--- step on the menu's first item readout).  Differs from
--- SuspendForCombat by NOT preserving autoWalkActive -- BG3 halts an
--- in-flight CharacterMoveTo when a menu opens, so the eventual arrival
--- callback would never fire anyway.
local function SuspendForMenu()
    if gpsMode == GPS_MODE_OFF and not autoWalkActive then
        return
    end
    gpsMode = GPS_MODE_OFF
    ClearGPSState()
    Log.Info("GPS: Menu opened -- forced off")
end

local function SuspendForCombat()
    if gpsMode == GPS_MODE_OFF and not autoWalkActive then
        return
    end
    -- Save autoWalkActive across the ClearGPSState call so the
    -- eventual arrival callback still has the cached target name to
    -- announce.  ClearGPSState wipes everything; we restore the one
    -- piece we need.
    local preservedAutoWalk = autoWalkActive
    -- Snapshot Tav's position at combat-lock-in time.  Stored on
    -- autoWalkActive so the arrival handler can compare it to the
    -- post-arrival actual position -- if they differ by more than a
    -- meter or two, something moved Tav DURING combat lock (teleport
    -- to a different point, BG3 finishing a queued move, etc.).  If
    -- they match, Tav was frozen at this point throughout combat
    -- lock-in -- the arrival event was a false positive.
    local combatStartPosition = nil
    pcall(function()
        local playerEntity = GetPlayerEntity()
        if playerEntity then
            combatStartPosition = GetEntityPosition(playerEntity)
        end
    end)
    gpsMode = GPS_MODE_OFF
    ClearGPSState()
    autoWalkActive = preservedAutoWalk
    if autoWalkActive and combatStartPosition then
        autoWalkActive.combatStartPosition = combatStartPosition
    end
    Log.Info("GPS: Combat -- forced off"
        .. (autoWalkActive
            and (" (autoWalk to "
                .. tostring(autoWalkActive.targetName)
                .. " preserved)")
            or "")
        .. (combatStartPosition
            and (" combat_start_pos=("
                .. string.format("%.2f", combatStartPosition[1]) .. ","
                .. string.format("%.2f", combatStartPosition[3]) .. ")")
            or ""))
end

-- ============================================================================
-- Subscriptions
-- ============================================================================

Ext.Events.Tick:Subscribe(function()
    local tickOk, tickErr = pcall(OnTick)
    if not tickOk then
        Log.Error("WorldNav tick: " .. tostring(tickErr))
    end
end)

Ext.Events.ControllerButtonInput:Subscribe(function(event)
    local buttonOk, buttonErr = pcall(OnControllerButton, event)
    if not buttonOk then
        Log.Error("WorldNav button: " .. tostring(buttonErr))
    end
end)

Ext.RegisterConsoleCommand("bg3a_pathdiag", function()
    PathDiagnostic()
end)

--- Diagnostic: dump every character entity's name, position, distance
--- from the active player, HP, and the filter conditions that the
--- routing-list scan applies (component presence, inventory membership,
--- distance gate, position read).  Use when a character that should
--- appear in the routing list (downed party member, etc.) is missing,
--- to pinpoint which filter rejects it.
---
--- Logs raw positions instead of just distances so a nil-player or
--- nil-entity-position case is visible (the previous version showed
--- "dist=?" for every entry without revealing whether the player
--- reference or the entity reference was the failing side).
---
--- Usage from console: bg3a_charscan
Ext.RegisterConsoleCommand("bg3a_charscan", function()
    local playerEntity = GetPlayerEntity()
    local playerPosition = playerEntity and GetEntityPosition(playerEntity)
    local playerLabel = "<no player entity>"
    if playerEntity then
        playerLabel = GetEntityDisplayName(playerEntity) or "<unnamed>"
    end
    if playerPosition then
        Log.Info("CHARSCAN: player=" .. playerLabel
            .. " pos=(" .. string.format("%.2f", playerPosition[1])
            .. "," .. string.format("%.2f", playerPosition[3]) .. ")")
    else
        Log.Info("CHARSCAN: player=" .. playerLabel
            .. " <no position read; GetEntityPosition returned nil>")
    end

    local function DescribePosition(entity)
        -- Probe the path GetEntityPosition takes, layer by layer,
        -- so a nil at any step is identifiable.  Returns
        -- (x, z, errorReason) where errorReason explains which probe
        -- failed when x is nil.
        local hasTransform = false
        local hasInnerTransform = false
        local translate = nil
        pcall(function()
            if entity and entity.Transform then
                hasTransform = true
                if entity.Transform.Transform then
                    hasInnerTransform = true
                    translate = entity.Transform.Transform.Translate
                end
            end
        end)
        if not hasTransform then
            return nil, nil, "no Transform component"
        end
        if not hasInnerTransform then
            return nil, nil, "Transform.Transform nil"
        end
        if not translate then
            return nil, nil, "Translate nil"
        end
        local x, z = nil, nil
        pcall(function()
            x = translate[1]
            z = translate[3]
        end)
        if not x then return nil, nil, "Translate[1] nil" end
        return x, z, nil
    end

    local visited = {}
    for _, componentName in ipairs({
        "ClientCharacter", "IsCharacter", "ServerCharacter",
    }) do
        local ok, entities = pcall(
            Ext.Entity.GetAllEntitiesWithComponent, componentName)
        if ok and entities then
            for _, entity in ipairs(entities) do
                local entityKey = tostring(entity)
                if not visited[entityKey] then
                    visited[entityKey] = true
                    local name = GetEntityDisplayName(entity)
                        or "<unnamed>"
                    local x, z, posErr = DescribePosition(entity)
                    local positionStr
                    if x and z then
                        positionStr = "pos=("
                            .. string.format("%.2f", x) .. ","
                            .. string.format("%.2f", z) .. ")"
                    else
                        positionStr = "pos=<nil:" .. tostring(posErr) .. ">"
                    end
                    local distance = nil
                    if x and z and playerPosition then
                        local dx = x - playerPosition[1]
                        local dz = z - playerPosition[3]
                        distance = math.sqrt(dx*dx + dz*dz)
                    end
                    local hp = "?"
                    local maxHp = "?"
                    pcall(function()
                        local health = entity.Health
                        if health then
                            hp = tostring(health.Hp)
                            maxHp = tostring(health.MaxHp)
                        end
                    end)
                    local inInventory = IsInsideInventory(entity)
                    local hasIsChar = GetEntityComponent(
                        entity, "IsCharacter") ~= nil
                    local hasClientChar = GetEntityComponent(
                        entity, "ClientCharacter") ~= nil
                    local hasDeathState = GetEntityComponent(
                        entity, "DeathState") ~= nil
                    local hasServerDeathState = GetEntityComponent(
                        entity, "ServerDeathState") ~= nil
                    -- Probe player-marker components per entity so we
                    -- can see which character(s) hold ClientControl /
                    -- IsPlayer / PlayerController in the current game
                    -- state.  GetPlayerEntity uses these as the
                    -- "who am I controlling" signal; if none are
                    -- present on any alive character, GetPlayerEntity
                    -- returns nil and the entity scan can't anchor.
                    local hasClientControl = GetEntityComponent(
                        entity, "ClientControl") ~= nil
                    local hasIsPlayer = GetEntityComponent(
                        entity, "IsPlayer") ~= nil
                    local hasPlayerController = GetEntityComponent(
                        entity, "PlayerController") ~= nil
                    Log.Info("  " .. name
                        .. " comp=" .. componentName
                        .. " hp=" .. hp .. "/" .. maxHp
                        .. " " .. positionStr
                        .. " dist=" .. (distance
                            and string.format("%.1fm", distance)
                            or "?")
                        .. " inv=" .. tostring(inInventory)
                        .. " IsChar=" .. tostring(hasIsChar)
                        .. " ClientChar=" .. tostring(hasClientChar)
                        .. " DeathState=" .. tostring(hasDeathState)
                        .. " ServerDeathState="
                        .. tostring(hasServerDeathState)
                        .. " ClientControl="
                        .. tostring(hasClientControl)
                        .. " IsPlayer=" .. tostring(hasIsPlayer)
                        .. " PlayerController="
                        .. tostring(hasPlayerController))
                end
            end
        end
    end
    Log.Info("CHARSCAN: done. ENTITY_MIN_DISTANCE="
        .. tostring(ENTITY_MIN_DISTANCE)
        .. "m  ENTITY_SCAN_RADIUS="
        .. tostring(ENTITY_SCAN_RADIUS) .. "m")
end)

--- Probe whether GetAllEntitiesWithComponent works with various
--- component name forms (shorthand vs. fully-qualified namespaced
--- names).  Reports the count returned by each query.  Reveals
--- which name BG3SE's global component-index registers, so we can
--- pick the right one to query for "active character" / "any party
--- member" anchors in GetPlayerEntity.
---
--- Usage: bg3a_probequeries
Ext.RegisterConsoleCommand("bg3a_probequeries", function()
    local QUERIES = {
        -- Existing (probably broken) shorthands.
        "ClientControl",
        "IsPlayer",
        "PlayerController",
        -- Fully-qualified candidates from the dumpcomponents output.
        "ecl::character::AssignedComponent",
        "ecl::tadpole_tree::StatePowerContainerComponent",
        "ecl::ftb::ToggleRequestComponent",
        "ecl::AiPathVisualComponent",
        -- Sanity: known-working shorthands.
        "ClientCharacter",
        "Health",
    }
    Log.Info("PROBEQUERIES: testing GetAllEntitiesWithComponent")
    for _, queryName in ipairs(QUERIES) do
        local ok, entities = pcall(
            Ext.Entity.GetAllEntitiesWithComponent, queryName)
        local count = "<error>"
        if ok and entities then
            count = tostring(#entities)
        elseif not ok then
            count = "<pcall failed: " .. tostring(entities) .. ">"
        end
        Log.Info("    " .. queryName .. " -> " .. count)
    end
    Log.Info("PROBEQUERIES: done")
end)

--- Dump every component name on Tav and Shadowheart specifically.
--- Hardcodes those names because the party-member detection bug we're
--- trying to fix means we can't *use* the broken player-marker
--- components to identify them programmatically -- chicken-and-egg.
--- The component lists let us discover the correct party-marker
--- component name(s) by comparing what's on Tav (alive party) vs
--- Shadowheart (dead party) vs the existing charscan data on
--- non-party characters (Intellect Devourer, Mushroom Circle).
---
--- Usage: bg3a_dumpcomponents
Ext.RegisterConsoleCommand("bg3a_dumpcomponents", function()
    local TARGETS = {Tav = true, Shadowheart = true,
                     ["Intellect Devourer"] = true}
    Log.Info("DUMPCOMPONENTS: enumerating ClientCharacter entities,"
        .. " targets=" .. table.concat({"Tav", "Shadowheart",
            "Intellect Devourer"}, ", "))
    local ok, entities = pcall(
        Ext.Entity.GetAllEntitiesWithComponent, "ClientCharacter")
    if not ok or not entities then
        Log.Info("DUMPCOMPONENTS: GetAllEntitiesWithComponent failed")
        return
    end
    local dumpedNames = {}
    for _, entity in ipairs(entities) do
        local name = GetEntityDisplayName(entity) or "<unnamed>"
        if TARGETS[name] and not dumpedNames[name] then
            dumpedNames[name] = true
            local hp = nil
            local maxHp = nil
            pcall(function()
                local health = entity.Health
                if health then
                    hp = tonumber(health.Hp)
                    maxHp = tonumber(health.MaxHp)
                end
            end)
            Log.Info("DUMPCOMPONENTS: " .. name
                .. " hp=" .. tostring(hp) .. "/" .. tostring(maxHp))
            local componentsOk, components = pcall(
                entity.GetAllComponentNames, entity, false)
            if componentsOk and components then
                local sorted = {}
                for _, componentName in ipairs(components) do
                    sorted[#sorted + 1] = tostring(componentName)
                end
                table.sort(sorted)
                for _, componentName in ipairs(sorted) do
                    Log.Info("    " .. componentName)
                end
            else
                Log.Info("    <GetAllComponentNames failed: "
                    .. tostring(components) .. ">")
            end
        end
    end
    local missing = {}
    for targetName, _ in pairs(TARGETS) do
        if not dumpedNames[targetName] then
            missing[#missing + 1] = targetName
        end
    end
    Log.Info("DUMPCOMPONENTS: done. dumped="
        .. table.concat({(dumpedNames["Tav"] and "Tav" or nil),
            (dumpedNames["Shadowheart"] and "Shadowheart" or nil),
            (dumpedNames["Intellect Devourer"]
                and "Intellect Devourer" or nil)}, ",")
        .. " missing=" .. (#missing > 0
            and table.concat(missing, ",") or "<none>"))
end)

Log.Debug("WorldNav module loaded")

-- ============================================================================
-- Module Table
-- ============================================================================

BG3Access.Client.WorldNav = {
    ResetState           = ResetState,
    PauseGPS             = PauseGPS,
    ResumeGPS            = ResumeGPS,
    IsGPSActive          = IsGPSActive,
    TestPathDiagnostic   = PathDiagnostic,
    -- Exported for EventRouter RS input dispatch.
    CycleGPSMode         = CycleGPSMode,
    IsEntityListOpen     = function() return entityListOpen end,
    HasPlayerEntity      = function() return GetPlayerEntity() ~= nil end,
    -- Exported so Combat.lua can dismiss the routing list the
    -- instant CombatStarted fires.  Without this the list stays
    -- open across the combat transition and eats A-presses meant
    -- for combat actions (Fire Bolt, attack, etc.) until OnTick's
    -- 300ms throttle next observes the state change.
    CloseEntityList      = CloseEntityList,
    -- Exported for Combat.lua to fully suspend GPS at combat start
    -- (cancels in-flight AutoWalk's auto-Exploration transition,
    -- drops tracking state, ensures no proximity / hazard work
    -- runs during enemy turns).
    SuspendForCombat     = SuspendForCombat,
    -- Exported for Menus.lua to fully suspend GPS when a menu opens
    -- (closes the entity list so the menu's B-press isn't intercepted,
    -- drops tracking / proximity / hazard work for the duration of
    -- the menu).
    SuspendForMenu       = SuspendForMenu,
}
