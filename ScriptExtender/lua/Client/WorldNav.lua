-- File: Client/WorldNav.lua
--
-- Spatial navigation and GPS system for BG3Access.
--
-- Two independent features:
--
-- 1. GPS (RS hold 500ms, release to toggle):
--    ON with no target  = proximity mode, announces up to 3 nearby entities
--                          as the player walks around.
--    ON with target      = tracking mode, pathfinds to selected target,
--                          announces clock direction + distance every 2m.
--    OFF                 = silent.
--
-- 2. Entity List (LS hold 500ms, release to open):
--    Categorised list of nearby entities (Items, NPCs, Doors).
--    D-pad left/right  = cycle categories (wrapping).
--    D-pad up/down     = cycle entities in current category.
--    A button           = select entity as tracking target, close list.
--    B button           = close list without selecting.
--
-- Camera-position-based reference angle for clock directions (immune to
-- Steering feedback loop).  Pathfinding via BeginPathfindingImmediate +
-- FindPath, retry at shorter distances for unwalkable targets.
-- Direction = bearing from player to lookahead node on the computed path.
-- No walkability scanning -- the path IS the validation.

local Log = BG3Access.Client.Log
local H   = BG3Access.Client.Helpers

-- ============================================================================
-- Constants
-- ============================================================================

-- Path-following.
local GPS_LOOKAHEAD_NODES     = 8     -- nodes ahead on path (~4m)
local GPS_DEVIATION_THRESHOLD = 3.0   -- meters off-path triggers recalculation
local GPS_ARRIVAL_DISTANCE    = 5.0   -- meters to declare arrival
local GPS_GUIDANCE_MOVEMENT   = 2.0   -- meters between guidance updates

-- Proximity mode.
local GPS_PROXIMITY_MAX       = 3     -- max entities announced per check
local GPS_PROXIMITY_MOVEMENT  = 3.0   -- meters between proximity checks

-- Entity scanning.
local ENTITY_SCAN_RADIUS      = 30    -- meters for entity scanning
local ENTITY_SCAN_MOVEMENT    = 3.0   -- meters before rescanning

-- Timing (milliseconds).
local POSITION_CHECK_MS       = 300   -- between position checks
local STICK_HOLD_MS           = 500   -- hold duration for RS/LS toggle

-- Minimum distance to include an entity in scan results.
-- Filters out inventory items (worn/carried) which share the player's
-- position, and the player entity itself.
local ENTITY_MIN_DISTANCE     = 1.0

-- Pathfinding retry fractions for unwalkable target tiles.
local PATH_RETRY_FRACTIONS    = {0.90, 0.75, 0.50, 0.30}

-- Clock direction: 30 degrees per hour.
local DEGREES_PER_CLOCK_HOUR  = 30

-- Entity category names (order matches D-pad left/right cycling).
local CATEGORY_NAMES          = {"Items", "NPCs", "Doors"}

-- ============================================================================
-- State
-- ============================================================================

-- GPS state.
local gpsEnabled             = false  -- RS toggle: proximity mode active
local trackingTarget         = nil    -- {handle, name, position, entity}
local currentPath            = nil    -- array of {[1]=x, [2]=y, [3]=z}
local currentPathIndex       = 1
local lastPlayerPosition     = nil
local lastGuidancePosition   = nil
local lastDistanceToTarget   = nil

-- Proximity alert state.
local lastProximityPosition  = nil
local announcedHandles       = {}     -- handles announced this GPS session

-- Entity scanning state.
local scannedCategories      = {}     -- {Items={...}, NPCs={...}, Doors={...}}
local lastScanPosition       = nil

-- Entity list state.
local entityListOpen         = false
local currentCategoryIndex   = 1      -- index into CATEGORY_NAMES
local currentItemIndex       = 1      -- index into current category

-- Button hold tracking (fire on release after >= 500ms hold).
local rightStickPressTime    = nil
local leftStickPressTime     = nil
-- Track both sticks for explore mode combo guard (L3+R3).
local leftStickDown          = false
local rightStickDown         = false

-- Tick timing.
local lastPositionCheckTime  = 0

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

local function BearingXZ(fromPosition, toPosition)
    local deltaX = toPosition[1] - fromPosition[1]
    local deltaZ = toPosition[3] - fromPosition[3]
    return math.atan(deltaX, deltaZ)
end

local function LerpPositionXZ(fromPosition, toPosition, fraction)
    return {
        fromPosition[1] + (toPosition[1] - fromPosition[1]) * fraction,
        toPosition[2],
        fromPosition[3] + (toPosition[3] - fromPosition[3]) * fraction,
    }
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

local PLAYER_COMPONENTS = {"ClientControl", "IsPlayer", "PlayerController"}

local function GetPlayerEntity()
    for _, componentName in ipairs(PLAYER_COMPONENTS) do
        local ok, players = pcall(
            Ext.Entity.GetAllEntitiesWithComponent, componentName)
        if ok and players and #players > 0 then
            return players[1]
        end
    end
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

--- Resolve a TranslatedString to a plain Lua string.
--- TranslatedString userdata has .Handle.Handle containing the loca key.
local function ResolveTranslatedString(translatedString)
    if not translatedString then return nil end
    if type(translatedString) == "string" then
        return H.GetTranslatedStringIfHandle(translatedString)
    end
    -- TranslatedString userdata: dig into .Handle.Handle for the key.
    local handle = nil
    pcall(function()
        handle = translatedString.Handle.Handle
    end)
    if handle then
        return H.GetTranslatedStringIfHandle(handle)
    end
    return nil
end

local function GetEntityDisplayName(entity)
    local ok, name = pcall(function()
        if not entity.DisplayName then return nil end
        local resolved = ResolveTranslatedString(entity.DisplayName.Name)
        if resolved and resolved ~= "" then return resolved end
        resolved = ResolveTranslatedString(entity.DisplayName.NameKey)
        if resolved and resolved ~= "" then return resolved end
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

-- ============================================================================
-- Entity Scanning and Categorisation
-- ============================================================================

--- Determine the category for an entity.
--- Returns "NPCs", "Doors", or "Items" (default).
local function CategoriseEntity(entity)
    -- Check for character components (NPCs).
    local isChar = pcall(function()
        return entity.ServerCharacter ~= nil
    end)
    if isChar then
        local hasChar = false
        pcall(function() hasChar = entity.ServerCharacter ~= nil end)
        if hasChar then return "NPCs" end
    end

    -- Check for door component.
    local hasDoor = false
    pcall(function() hasDoor = entity.Door ~= nil end)
    if hasDoor then return "Doors" end

    return "Items"
end

--- Scan nearby entities, categorise them, and store in scannedCategories.
--- Each entry: {handle, name, position, distance, entity}.
local function ScanAndCategorise(playerPosition)
    local categories = {}
    for _, categoryName in ipairs(CATEGORY_NAMES) do
        categories[categoryName] = {}
    end

    local radiusSquared = ENTITY_SCAN_RADIUS * ENTITY_SCAN_RADIUS
    local minDistSquared = ENTITY_MIN_DISTANCE * ENTITY_MIN_DISTANCE
    local seenHandles = {}

    -- Try multiple component queries to find entities.
    local componentNames = {
        "ServerItem", "ServerCharacter",
        "GameObjectVisual", "ItemTemplate",
    }
    for _, componentName in ipairs(componentNames) do
        local ok, entities = pcall(
            Ext.Entity.GetAllEntitiesWithComponent, componentName)
        if ok and entities then
            for _, entity in ipairs(entities) do
                local entityKey = tostring(entity)
                if not seenHandles[entityKey] then
                    seenHandles[entityKey] = true
                    local entityPosition = GetEntityPosition(entity)
                    if entityPosition then
                        local distSquared = DistanceSquaredXZ(
                            playerPosition, entityPosition)
                        if distSquared >= minDistSquared
                            and distSquared <= radiusSquared then
                            local displayName =
                                GetEntityDisplayName(entity)
                            if displayName then
                                local category =
                                    CategoriseEntity(entity)
                                table.insert(categories[category], {
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

    -- Sort each category by distance.
    for _, categoryName in ipairs(CATEGORY_NAMES) do
        table.sort(categories[categoryName],
            function(entryA, entryB)
                return entryA.distance < entryB.distance
            end)
    end

    scannedCategories = categories
    lastScanPosition = playerPosition

    local totalCount = 0
    for _, categoryName in ipairs(CATEGORY_NAMES) do
        totalCount = totalCount + #categories[categoryName]
    end
    Log.Debug("Entity scan: " .. totalCount .. " total ("
        .. #categories["Items"] .. " items, "
        .. #categories["NPCs"] .. " NPCs, "
        .. #categories["Doors"] .. " doors)")

    return categories
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

local function TryPathfind(playerEntity, targetPosition)
    local ok, result = pcall(function()
        local aiPath = Ext.Level.BeginPathfindingImmediate(
            playerEntity, targetPosition)
        if not aiPath then return nil end
        local goalFound = Ext.Level.FindPath(aiPath)
        if not goalFound then
            pcall(Ext.Level.ReleasePath, aiPath)
            return nil
        end
        local nodes = {}
        for nodeIndex = 1, #aiPath.Nodes do
            local nodePosition = aiPath.Nodes[nodeIndex].Position
            nodes[nodeIndex] = {
                nodePosition[1], nodePosition[2], nodePosition[3]
            }
        end
        pcall(Ext.Level.ReleasePath, aiPath)
        if #nodes == 0 then return nil end
        return nodes
    end)
    if ok then return result end
    return nil
end

local function ComputePath(playerEntity, playerPosition, targetPosition)
    local path = TryPathfind(playerEntity, targetPosition)
    if path then
        Log.Debug("Path found: " .. #path .. " nodes (full distance)")
        return path
    end
    for _, fraction in ipairs(PATH_RETRY_FRACTIONS) do
        local intermediatePosition = LerpPositionXZ(
            playerPosition, targetPosition, fraction)
        path = TryPathfind(playerEntity, intermediatePosition)
        if path then
            Log.Debug("Path found: " .. #path .. " nodes (at "
                .. math.floor(fraction * 100) .. "% distance)")
            return path
        end
    end
    Log.Info("No path found to target")
    return nil
end

local function FindNearestPathNode(path, position)
    local nearestIndex = 1
    local nearestDistSquared = DistanceSquaredXZ(position, path[1])
    for nodeIndex = 2, #path do
        local distSquared = DistanceSquaredXZ(position, path[nodeIndex])
        if distSquared < nearestDistSquared then
            nearestDistSquared = distSquared
            nearestIndex = nodeIndex
        end
    end
    return nearestIndex, math.sqrt(nearestDistSquared)
end

-- ============================================================================
-- GPS Tracking Mode (path following to selected target)
-- ============================================================================

local function AdvancePathIndex(playerPosition)
    if not currentPath then return end
    while currentPathIndex < #currentPath do
        local nextIndex = currentPathIndex + 1
        local currentDistSquared = DistanceSquaredXZ(
            playerPosition, currentPath[currentPathIndex])
        local nextDistSquared = DistanceSquaredXZ(
            playerPosition, currentPath[nextIndex])
        if nextDistSquared < currentDistSquared then
            currentPathIndex = nextIndex
        else
            break
        end
    end
end

local function GetLookaheadPosition()
    if not currentPath then return nil end
    local lookaheadIndex = math.min(
        currentPathIndex + GPS_LOOKAHEAD_NODES, #currentPath)
    return currentPath[lookaheadIndex]
end

local function IsDeviatedFromPath(playerPosition)
    if not currentPath then return true end
    local _, nearestDistance = FindNearestPathNode(
        currentPath, playerPosition)
    return nearestDistance > GPS_DEVIATION_THRESHOLD
end

local function IsPathExhausted(playerPosition)
    if not currentPath or not trackingTarget then return false end
    if currentPathIndex >= #currentPath - GPS_LOOKAHEAD_NODES then
        local distanceToTarget = DistanceXZ(
            playerPosition, trackingTarget.position)
        return distanceToTarget > GPS_ARRIVAL_DISTANCE
    end
    return false
end

local function RecalculatePath(playerPosition)
    if not trackingTarget then return end
    local playerEntity = GetPlayerEntity()
    if not playerEntity then return end
    local refreshedPosition = GetEntityPosition(trackingTarget.entity)
    if refreshedPosition then
        trackingTarget.position = refreshedPosition
    end
    currentPath = ComputePath(
        playerEntity, playerPosition, trackingTarget.position)
    currentPathIndex = 1
    if not currentPath then
        Ext.Tolk.Speak("No path", true)
    end
end

--- Process one tracking guidance update (called every GPS_GUIDANCE_MOVEMENT).
local function ProcessTrackingUpdate(playerPosition)
    if not trackingTarget then return end

    -- Check arrival.
    local distanceToTarget = DistanceXZ(
        playerPosition, trackingTarget.position)
    if distanceToTarget <= GPS_ARRIVAL_DISTANCE then
        Log.Info("GPS: Arriving at " .. trackingTarget.name)
        Ext.Tolk.Speak("Arriving at " .. trackingTarget.name, true)
        trackingTarget = nil
        currentPath = nil
        return
    end

    -- Recalculate if needed.
    if not currentPath or IsDeviatedFromPath(playerPosition)
        or IsPathExhausted(playerPosition) then
        RecalculatePath(playerPosition)
    end
    if not currentPath then return end

    AdvancePathIndex(playerPosition)
    local lookaheadPosition = GetLookaheadPosition()
    if not lookaheadPosition then return end

    local clockHour = ComputeClockDirection(
        playerPosition, lookaheadPosition)
    if not clockHour then return end

    -- Tracking speech: distance + clock (no target name).
    local distanceRounded = math.floor(distanceToTarget + 0.5)
    local guidance = distanceRounded .. " meters. "
        .. clockHour .. " o'clock"

    -- Distance trend for diagnostics.
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

    Log.Info("GPS: " .. guidance .. trend)
    Ext.Tolk.Speak(guidance, true)
    lastGuidancePosition = {
        playerPosition[1], playerPosition[2], playerPosition[3]
    }
end

-- ============================================================================
-- GPS Proximity Mode (announce nearby entities while walking)
-- ============================================================================

--- Announce up to GPS_PROXIMITY_MAX nearby entities that have not
--- been announced yet this GPS session.
local function ProcessProximityUpdate(playerPosition)
    -- Rescan if moved enough.
    if not lastScanPosition
        or DistanceXZ(playerPosition, lastScanPosition)
            >= ENTITY_SCAN_MOVEMENT then
        ScanAndCategorise(playerPosition)
    end

    local allEntities = GetAllEntitiesFlat()
    local announced = 0

    for _, entry in ipairs(allEntities) do
        if announced >= GPS_PROXIMITY_MAX then break end
        if not announcedHandles[entry.entityKey] then
            local clockHour, distance = ComputeClockDirection(
                playerPosition, entry.position)
            local distanceRounded = math.floor(
                (distance or entry.distance) + 0.5)
            local parts = {entry.name, distanceRounded .. " meters"}
            if clockHour then
                table.insert(parts, clockHour .. " o'clock")
            end
            local speech = table.concat(parts, ". ")
            Log.Info("Proximity: " .. speech)
            Ext.Tolk.Speak(speech, false)
            announcedHandles[entry.entityKey] = true
            announced = announced + 1
        end
    end

    lastProximityPosition = {
        playerPosition[1], playerPosition[2], playerPosition[3]
    }
end

-- ============================================================================
-- GPS Control
-- ============================================================================

local function EnableGPS()
    gpsEnabled = true
    announcedHandles = {}
    lastProximityPosition = nil
    Log.Info("GPS: ON")
    Ext.Tolk.Speak("GPS on", true)

    -- Immediate proximity scan.
    local playerEntity = GetPlayerEntity()
    if playerEntity then
        local playerPosition = GetEntityPosition(playerEntity)
        if playerPosition then
            ProcessProximityUpdate(playerPosition)
        end
    end
end

local function DisableGPS()
    gpsEnabled = false
    trackingTarget = nil
    currentPath = nil
    currentPathIndex = 1
    lastGuidancePosition = nil
    lastDistanceToTarget = nil
    announcedHandles = {}
    lastProximityPosition = nil
    Log.Info("GPS: OFF")
    Ext.Tolk.Speak("GPS off", true)
end

local function ToggleGPS()
    if gpsEnabled then
        DisableGPS()
    else
        EnableGPS()
    end
end

--- Start tracking to a specific entity (selected from entity list).
--- Enables GPS if not already on.
local function StartTracking(targetEntry)
    if not targetEntry then return end

    if not gpsEnabled then
        gpsEnabled = true
        announcedHandles = {}
        lastProximityPosition = nil
        Log.Info("GPS: ON (via tracking)")
    end

    local playerEntity = GetPlayerEntity()
    if not playerEntity then
        Ext.Tolk.Speak("Cannot find player", true)
        return
    end
    local playerPosition = GetEntityPosition(playerEntity)
    if not playerPosition then
        Ext.Tolk.Speak("Cannot get position", true)
        return
    end

    trackingTarget = {
        entityKey = targetEntry.entityKey,
        name = targetEntry.name,
        position = targetEntry.position,
        entity = targetEntry.entity,
    }
    currentPathIndex = 1
    lastDistanceToTarget = nil

    currentPath = ComputePath(
        playerEntity, playerPosition, trackingTarget.position)

    local distanceToTarget = DistanceXZ(
        playerPosition, trackingTarget.position)
    local distanceRounded = math.floor(distanceToTarget + 0.5)

    if not currentPath then
        Ext.Tolk.Speak("Tracking " .. trackingTarget.name .. ". "
            .. distanceRounded .. " meters. No path", true)
        Log.Info("GPS: Tracking " .. trackingTarget.name
            .. " (" .. distanceRounded .. "m, no path)")
    else
        local lookaheadPosition = GetLookaheadPosition()
            or trackingTarget.position
        local clockHour = ComputeClockDirection(
            playerPosition, lookaheadPosition)
        local clockText = clockHour
            and (". " .. clockHour .. " o'clock") or ""
        Ext.Tolk.Speak("Tracking " .. trackingTarget.name .. ". "
            .. distanceRounded .. " meters" .. clockText, true)
        Log.Info("GPS: Tracking " .. trackingTarget.name
            .. " (" .. distanceRounded .. "m, "
            .. #currentPath .. " nodes)")
    end

    lastGuidancePosition = {
        playerPosition[1], playerPosition[2], playerPosition[3]
    }
end

-- ============================================================================
-- Entity List
-- ============================================================================

--- Get the list of entities for the current category.
local function GetCurrentCategoryEntities()
    local categoryName = CATEGORY_NAMES[currentCategoryIndex]
    return scannedCategories[categoryName] or {}
end

--- Build speech string for an entity list entry.
local function FormatEntitySpeech(playerPosition, entry)
    local clockHour, distance = ComputeClockDirection(
        playerPosition, entry.position)
    local distanceRounded = math.floor(
        (distance or entry.distance) + 0.5)
    local parts = {entry.name, distanceRounded .. " meters"}
    if clockHour then
        table.insert(parts, clockHour .. " o'clock")
    end
    return table.concat(parts, ". ")
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
    Ext.Tolk.Speak(speech, true)
end

--- Announce category name + count (interrupt), then first item (append).
local function AnnounceCategorySwitch(playerPosition)
    local categoryName = CATEGORY_NAMES[currentCategoryIndex]
    local entities = GetCurrentCategoryEntities()
    currentItemIndex = 1

    if #entities == 0 then
        Ext.Tolk.Speak(categoryName .. ". Empty", true)
    else
        Ext.Tolk.Speak(categoryName .. ". " .. #entities .. ".", true)
        local firstEntry = entities[1]
        local itemSpeech = FormatEntitySpeech(playerPosition, firstEntry)
        Log.Info("List [" .. categoryName .. " 1/"
            .. #entities .. "]: " .. itemSpeech)
        Ext.Tolk.Speak(itemSpeech, false)
    end
end

local function OpenEntityList()
    local playerEntity = GetPlayerEntity()
    if not playerEntity then
        Ext.Tolk.Speak("Cannot find player", true)
        return
    end
    local playerPosition = GetEntityPosition(playerEntity)
    if not playerPosition then
        Ext.Tolk.Speak("Cannot get position", true)
        return
    end

    ScanAndCategorise(playerPosition)
    entityListOpen = true
    currentCategoryIndex = 1
    currentItemIndex = 1

    Log.Info("Entity list opened")
    AnnounceCategorySwitch(playerPosition)
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
        Ext.Tolk.Speak("Nothing to select", true)
        return
    end
    local entry = entities[currentItemIndex]
    if not entry then return end

    CloseEntityList()
    StartTracking(entry)
end

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
    if not gpsEnabled then return end

    -- Tracking mode: clock direction guidance to target.
    if trackingTarget then
        if not lastGuidancePosition then
            lastGuidancePosition = playerPosition
        end
        local movementSinceGuidance = DistanceXZ(
            playerPosition, lastGuidancePosition)
        if movementSinceGuidance >= GPS_GUIDANCE_MOVEMENT then
            ProcessTrackingUpdate(playerPosition)
        end
        return  -- tracking takes priority, skip proximity
    end

    -- Proximity mode: announce nearby entities.
    if not lastProximityPosition then
        lastProximityPosition = playerPosition
    end
    local movementSinceProximity = DistanceXZ(
        playerPosition, lastProximityPosition)
    if movementSinceProximity >= GPS_PROXIMITY_MOVEMENT then
        ProcessProximityUpdate(playerPosition)
    end
end

-- ============================================================================
-- Controller Input
-- ============================================================================

local function OnControllerButton(event)
    local buttonName = tostring(event.Button)
    local now = Ext.Utils.MonotonicTime()

    -- Track stick state for explore mode combo guard.
    if buttonName == "LeftStick" then
        leftStickDown = event.Pressed
    elseif buttonName == "RightStick" then
        rightStickDown = event.Pressed
    end

    -- ----- Entity list navigation (highest priority when open) -----
    if entityListOpen and event.Pressed then
        if buttonName == "DPadLeft" then
            event:PreventAction()
            EntityListCategoryPrevious()
            return
        elseif buttonName == "DPadRight" then
            event:PreventAction()
            EntityListCategoryNext()
            return
        elseif buttonName == "DPadUp" then
            event:PreventAction()
            EntityListItemPrevious()
            return
        elseif buttonName == "DPadDown" then
            event:PreventAction()
            EntityListItemNext()
            return
        elseif buttonName == "A" then
            event:PreventAction()
            EntityListSelect()
            return
        elseif buttonName == "B" then
            event:PreventAction()
            CloseEntityList()
            Ext.Tolk.Speak("List closed", true)
            return
        end
    end

    -- ----- Right Stick: press records time, release fires if >= 500ms -----
    if buttonName == "RightStick" then
        if event.Pressed then
            rightStickPressTime = now
        else
            if rightStickPressTime and not leftStickDown then
                local holdDuration = now - rightStickPressTime
                if holdDuration >= STICK_HOLD_MS then
                    event:PreventAction()
                    ToggleGPS()
                end
            end
            rightStickPressTime = nil
        end
        return
    end

    -- ----- Left Stick: press records time, release fires if >= 500ms -----
    if buttonName == "LeftStick" then
        if event.Pressed then
            leftStickPressTime = now
        else
            if leftStickPressTime and not rightStickDown then
                local holdDuration = now - leftStickPressTime
                if holdDuration >= STICK_HOLD_MS then
                    event:PreventAction()
                    OpenEntityList()
                end
            end
            leftStickPressTime = nil
        end
        return
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

    Log.Info("PATHDIAG: " .. #currentPath .. " nodes, index="
        .. currentPathIndex)
    if trackingTarget then
        local distanceToTarget = DistanceXZ(
            playerPosition, trackingTarget.position)
        Log.Info("PATHDIAG: Target=" .. trackingTarget.name
            .. " dist=" .. string.format("%.1f", distanceToTarget)
            .. "m")
    end

    local startNode = math.max(1, currentPathIndex - 2)
    local endNode = math.min(
        #currentPath, currentPathIndex + GPS_LOOKAHEAD_NODES + 2)
    for nodeIndex = startNode, endNode do
        local node = currentPath[nodeIndex]
        local distanceFromPlayer = DistanceXZ(playerPosition, node)
        local clockHour = ComputeClockDirection(playerPosition, node)
        local marker = ""
        if nodeIndex == currentPathIndex then
            marker = " <-- current"
        elseif nodeIndex == currentPathIndex + GPS_LOOKAHEAD_NODES then
            marker = " <-- lookahead"
        end
        Log.Info(string.format("  [%d] dist=%.1f clock=%s%s",
            nodeIndex, distanceFromPlayer,
            clockHour and (clockHour .. "h") or "?",
            marker))
    end
end

-- ============================================================================
-- Public API
-- ============================================================================

local function ResetState()
    gpsEnabled = false
    trackingTarget = nil
    currentPath = nil
    currentPathIndex = 1
    lastPlayerPosition = nil
    lastGuidancePosition = nil
    lastDistanceToTarget = nil
    lastProximityPosition = nil
    announcedHandles = {}
    scannedCategories = {}
    lastScanPosition = nil
    entityListOpen = false
    currentCategoryIndex = 1
    currentItemIndex = 1
    rightStickPressTime = nil
    leftStickPressTime = nil
    leftStickDown = false
    rightStickDown = false
    lastPositionCheckTime = 0
    Log.Debug("WorldNav: State reset")
end

local function PauseGPS()
    -- Temporarily suppress GPS updates (e.g. during menus).
    -- GPS stays enabled but tracking/proximity are paused via gpsEnabled check.
    -- For now, just stop announcing. State preserved for resume.
    Log.Debug("WorldNav: GPS paused")
end

local function ResumeGPS()
    Log.Debug("WorldNav: GPS resumed")
end

local function IsGPSActive()
    return gpsEnabled
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

Log.Info("WorldNav module loaded")

-- ============================================================================
-- Module Table
-- ============================================================================

BG3Access.Client.WorldNav = {
    ResetState         = ResetState,
    PauseGPS           = PauseGPS,
    ResumeGPS          = ResumeGPS,
    IsGPSActive        = IsGPSActive,
    TestPathDiagnostic = PathDiagnostic,
}
