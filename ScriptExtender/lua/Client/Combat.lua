-- ============================================================================
-- BG3Access Combat Module
--
-- Receives combat events from the server (Osiris listeners relayed via
-- net messages) and generates screen reader speech for:
--   - Turn changes (whose turn, round number)
--   - Combat start / end
--   - Death / downed announcements
--   - Status effects applied / removed (party members)
--   - Damage dealt (party member involved)
--
-- Also provides on-demand combat info:
--   - Turn order list (for RS HUD reader)
--   - Combat state queries (for other modules)
-- ============================================================================

local Log = BG3Access.Client.Log
local Helpers = BG3Access.Client.Helpers

local COMBAT_CHANNEL = "BG3Access_Combat"

-- ---------------------------------------------------------------------------
-- Combat state
-- ---------------------------------------------------------------------------

local inCombat = false
local currentTurnCharacterName = nil
local currentTurnCharacterGuid = nil
local currentRound = 0
local pendingRoundAnnouncement = nil

-- ---------------------------------------------------------------------------
-- Speech helpers
-- ---------------------------------------------------------------------------

--- Speak combat text with interrupt (cuts off previous speech).
local function SpeakCombatInterrupt(text)
    if not text or text == "" then return end
    Log.Debug("Combat speech (interrupt): " .. text)
    Ext.Tolk.Speak(text, true)
end

--- Speak combat text queued (appends after current speech).
local function SpeakCombatQueued(text)
    if not text or text == "" then return end
    Log.Debug("Combat speech (queued): " .. text)
    Ext.Tolk.Speak(text, false)
end

-- ---------------------------------------------------------------------------
-- Event handlers
-- ---------------------------------------------------------------------------

local function HandleCombatStarted(eventData)
    inCombat = true
    currentRound = 0
    currentTurnCharacterName = nil
    currentTurnCharacterGuid = nil
    pendingRoundAnnouncement = nil
    SpeakCombatInterrupt("Combat started")
end

local function HandleCombatEnded(eventData)
    inCombat = false
    currentTurnCharacterName = nil
    currentTurnCharacterGuid = nil
    currentRound = 0
    pendingRoundAnnouncement = nil
    SpeakCombatInterrupt("Combat ended")
end

local function HandleRoundStarted(eventData)
    local round = eventData.round or 0
    currentRound = round
    -- Don't speak immediately -- prepend to the next TurnStarted
    -- so "Round 2. Tav's turn" is a single uninterrupted speech.
    pendingRoundAnnouncement = round
end

local function HandleTurnStarted(eventData)
    local characterName = eventData.characterName or "Unknown"
    currentTurnCharacterName = characterName
    currentTurnCharacterGuid = eventData.characterGuid

    local text = characterName .. "'s turn"

    -- Prepend pending round announcement.
    if pendingRoundAnnouncement then
        text = "Round " .. tostring(pendingRoundAnnouncement)
            .. ". " .. text
        pendingRoundAnnouncement = nil
    end

    SpeakCombatInterrupt(text)
end

local function HandleDied(eventData)
    local characterName = eventData.characterName or "Unknown"
    if eventData.isPartyMember then
        SpeakCombatInterrupt(characterName .. " is down")
    else
        SpeakCombatInterrupt(characterName .. " died")
    end
end

local function HandleStatusApplied(eventData)
    local characterName = eventData.characterName or "Unknown"
    local statusName = eventData.statusDisplayName
        or eventData.statusId or "unknown status"
    SpeakCombatQueued(characterName .. ": " .. statusName)
end

local function HandleStatusRemoved(eventData)
    local characterName = eventData.characterName or "Unknown"
    local statusName = eventData.statusDisplayName
        or eventData.statusId or "unknown status"
    SpeakCombatQueued(statusName .. " expired on " .. characterName)
end

local function HandleAttackedBy(eventData)
    local attackerName = eventData.attackerName or "Unknown"
    local defenderName = eventData.defenderName or "Unknown"
    local damageAmount = eventData.damageAmount or 0
    local damageType = eventData.damageType or ""

    if damageAmount > 0 then
        local damageText = attackerName .. " dealt "
            .. tostring(damageAmount)
        if damageType ~= "" then
            damageText = damageText .. " " .. damageType
        end
        damageText = damageText .. " damage to " .. defenderName
        SpeakCombatQueued(damageText)
    else
        SpeakCombatQueued(attackerName .. " missed " .. defenderName)
    end
end

-- ---------------------------------------------------------------------------
-- Event dispatch
-- ---------------------------------------------------------------------------

local EVENT_HANDLERS = {
    CombatStarted = HandleCombatStarted,
    CombatEnded   = HandleCombatEnded,
    RoundStarted  = HandleRoundStarted,
    TurnStarted   = HandleTurnStarted,
    Died          = HandleDied,
    StatusApplied = HandleStatusApplied,
    StatusRemoved = HandleStatusRemoved,
    AttackedBy    = HandleAttackedBy,
}

local function HandleCombatEvent(eventData)
    local eventType = eventData.event
    if not eventType then return end

    local handler = EVENT_HANDLERS[eventType]
    if handler then
        handler(eventData)
    else
        Log.Debug("Combat: unknown event type '" .. eventType .. "'")
    end
end

-- Register net listener for combat events from server.
Ext.RegisterNetListener(COMBAT_CHANNEL,
    function(channel, payload, userId)
        local parseOk, eventData = pcall(Ext.Json.Parse, payload)
        if not parseOk or type(eventData) ~= "table" then
            Log.Error("Combat: bad event payload")
            return
        end
        local handleOk, handleErr = pcall(HandleCombatEvent, eventData)
        if not handleOk then
            Log.Error("Combat event handler: " .. tostring(handleErr))
        end
    end)

-- ---------------------------------------------------------------------------
-- On-demand combat info (for RS HUD reader)
-- ---------------------------------------------------------------------------

--- Read the turn order from entity components.
--- Returns a list of {name=string, isCurrent=bool} entries, or nil.
local function ReadTurnOrder()
    local entitiesOk, entities = pcall(
        Ext.Entity.GetAllEntitiesWithComponent, "TurnOrder")
    if not entitiesOk or not entities or #entities == 0 then
        return nil
    end

    local turnEntries = {}

    for _, combatEntity in ipairs(entities) do
        local groupsOk, groups = pcall(function()
            return combatEntity.TurnOrder.Participants
        end)
        -- Try .Participants first, fall back to .Groups
        if not groupsOk or not groups then
            groupsOk, groups = pcall(function()
                return combatEntity.TurnOrder.Groups
            end)
        end
        if not groupsOk or not groups then break end

        for _, group in ipairs(groups) do
            -- Each group may have Members, or may be a direct entry.
            local members = nil
            local membersOk = false
            membersOk, members = pcall(function()
                return group.Members
            end)
            if membersOk and members then
                -- Group with Members array.
                for _, member in ipairs(members) do
                    local nameOk, memberName = pcall(function()
                        local memberEntity = member.Entity
                        if not memberEntity
                            or not memberEntity.DisplayName then
                            return nil
                        end
                        local nameKey =
                            memberEntity.DisplayName.NameKey
                        if nameKey and nameKey.Handle
                            and nameKey.Handle.Handle then
                            return Ext.Loca.GetTranslatedString(
                                nameKey.Handle.Handle)
                        end
                        return nil
                    end)

                    local isCurrent = false
                    pcall(function()
                        local memberEntity = member.Entity
                        if memberEntity
                            and memberEntity.TurnBased then
                            isCurrent =
                                memberEntity.TurnBased
                                    .IsActiveCombatTurn == true
                        end
                    end)

                    if nameOk and memberName
                        and memberName ~= "" then
                        turnEntries[#turnEntries + 1] = {
                            name = memberName,
                            isCurrent = isCurrent,
                        }
                    end
                end
            else
                -- Direct entry (group IS the participant).
                local nameOk, memberName = pcall(function()
                    local memberEntity = group.Entity
                        or group.Character
                    if not memberEntity
                        or not memberEntity.DisplayName then
                        return nil
                    end
                    local nameKey =
                        memberEntity.DisplayName.NameKey
                    if nameKey and nameKey.Handle
                        and nameKey.Handle.Handle then
                        return Ext.Loca.GetTranslatedString(
                            nameKey.Handle.Handle)
                    end
                    return nil
                end)

                local isCurrent = false
                pcall(function()
                    local memberEntity = group.Entity
                        or group.Character
                    if memberEntity
                        and memberEntity.TurnBased then
                        isCurrent =
                            memberEntity.TurnBased
                                .IsActiveCombatTurn == true
                    end
                end)

                if nameOk and memberName
                    and memberName ~= "" then
                    turnEntries[#turnEntries + 1] = {
                        name = memberName,
                        isCurrent = isCurrent,
                    }
                end
            end
        end

        -- Only need one TurnOrder entity.
        if #turnEntries > 0 then break end
    end

    return #turnEntries > 0 and turnEntries or nil
end

--- Speak the full turn order list.
--- Used by RS HUD reader (RS Right in combat).
local function SpeakTurnOrder()
    local turnEntries = ReadTurnOrder()
    if not turnEntries then
        SpeakCombatInterrupt("Turn order not available")
        return
    end

    local parts = {}
    for _, entry in ipairs(turnEntries) do
        local prefix = entry.isCurrent and "Current: " or ""
        parts[#parts + 1] = prefix .. entry.name
    end
    SpeakCombatInterrupt(
        "Turn order: " .. table.concat(parts, ", "))
end

-- ---------------------------------------------------------------------------
-- State management
-- ---------------------------------------------------------------------------

--- Reset combat state.  Called on GameStateChanged.
local function ResetState()
    inCombat = false
    currentTurnCharacterName = nil
    currentTurnCharacterGuid = nil
    currentRound = 0
    pendingRoundAnnouncement = nil
end

--- Query: are we currently in combat?
local function IsInCombat()
    return inCombat
end

--- Query: current turn character name (or nil).
local function GetCurrentTurnName()
    return currentTurnCharacterName
end

--- Query: current round number (0 if not in combat).
local function GetCurrentRound()
    return currentRound
end

Log.Debug("Combat module loaded")

-- ============================================================================
-- Module Table
-- ============================================================================

BG3Access.Client.Combat = {
    IsInCombat        = IsInCombat,
    GetCurrentTurnName = GetCurrentTurnName,
    GetCurrentRound   = GetCurrentRound,
    ReadTurnOrder     = ReadTurnOrder,
    SpeakTurnOrder    = SpeakTurnOrder,
    ResetState        = ResetState,
}
