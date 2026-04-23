-- ============================================================================
-- BG3Access Server Bootstrap
--
-- Handles server-side operations that the client cannot perform
-- directly due to BG3's client/server architecture split.
--
-- Currently: template data lookup for entity classification.
-- Templates (GameObjectTemplate / ItemTemplate / CharacterTemplate)
-- are loaded into the server's template banks (root, local, cache)
-- when a level loads.  The client only has access to root templates
-- via Ext.Template.GetRootTemplate, but level-local templates
-- (which most in-world entities use) are server-only.  This script
-- bridges that gap by looking up templates on the server and
-- sending the classification-relevant fields to the client.
-- ============================================================================

local CHANNEL_REQUEST  = "BG3Access_ClassifyRequest"
local CHANNEL_RESPONSE = "BG3Access_ClassifyResponse"

_P("BG3Access: BootstrapServer.lua loaded")

--- Handle a classification request from the client.
--- Payload is a JSON array of entity UUID strings.
--- For each UUID, the server:
---   1. Gets the entity via Ext.Entity.Get(uuid)
---   2. Checks key components (InventoryOwner, CanBeLooted, etc.)
---   3. Gets the template via OriginalTemplate -> GetTemplate
---   4. Reads template + stats fields
--- Response is keyed by UUID with all classification signals.
Ext.RegisterNetListener(CHANNEL_REQUEST, function(channel, payload, userId)
    local ok, uuids = pcall(Ext.Json.Parse, payload)
    if not ok or type(uuids) ~= "table" then
        _P("BG3Access Server: bad classify request payload")
        return
    end

    local results = {}
    for _, uuid in ipairs(uuids) do
        local uuidStr = tostring(uuid)
        local entry = {}

        -- Step 1: Get the entity and check components.
        local okEntity, entity = pcall(Ext.Entity.Get, uuidStr)
        if okEntity and entity then
            -- Component presence checks.  These are the
            -- AUTHORITATIVE signals for classification.
            -- Get ALL components via GetAllComponents (proven to
            -- work in the entity dump diagnostic).  Then check
            -- for the presence of classification-relevant ones.
            -- The keys in the returned table are ExtComponentType
            -- values; tostring() gives us the component name.
            local okComps, allComponents = pcall(
                entity.GetAllComponents, entity, false)
            if okComps and allComponents then
                local componentSet = {}
                for componentType, _ in pairs(allComponents) do
                    componentSet[tostring(componentType)] = true
                end
                -- Check classification-relevant components.
                local wantedComponents = {
                    "InventoryOwner",
                    "CanBeLooted",
                    "CanBeInInventory",
                    "IsCharacter",
                    "IsDoor",
                    "Health",
                    "Use",
                    "Death",
                    "DeathState",
                    "CanBeWielded",
                    "Equipable",
                    "Weapon",
                    "ObjectInteraction",
                    "HasGeneratedTreasure",
                }
                for _, compName in ipairs(wantedComponents) do
                    if componentSet[compName] then
                        entry["has_" .. compName] = true
                    end
                end
            end

            -- Get template GUID from entity.
            local templateGuid = nil
            pcall(function()
                local tmplComp = entity.OriginalTemplate
                if tmplComp then
                    templateGuid = tostring(
                        tmplComp.OriginalTemplate)
                end
            end)

            -- Step 2: Get the template.
            local template = nil
            if templateGuid and templateGuid ~= ""
                and templateGuid ~= "nil" then
                local okTmpl, tmpl = pcall(
                    Ext.Template.GetTemplate, templateGuid)
                if okTmpl and tmpl then
                    template = tmpl
                end
            end

            if not template then
                results[uuidStr] = entry
            else
            -- Read classification fields into the EXISTING entry
            -- (which already has has_* component signals from
            -- the GetAllComponents check above).  Do NOT re-declare
            -- entry here — that was a variable shadowing bug that
            -- wiped out all component signals.

            -- Boolean fields: read and force to true/false.
            local boolFields = {
                "CanBePickedUp", "StoryItem", "IsKey", "IsPortal",
                "IsTrap", "Hostile", "TreasureOnDestroy",
                "IsSourceContainer",
            }
            for _, fieldName in ipairs(boolFields) do
                local okF, fv = pcall(function()
                    return template[fieldName]
                end)
                if okF and fv == true then
                    entry[fieldName] = true
                end
            end

            -- String/enum fields: force tostring, skip empty.
            local stringFields = { "InventoryType", "BookType" }
            for _, fieldName in ipairs(stringFields) do
                local okF, fv = pcall(function()
                    return template[fieldName]
                end)
                if okF and fv ~= nil then
                    local s = tostring(fv)
                    if s ~= "" and s ~= "nil" then
                        entry[fieldName] = s
                    end
                end
            end

            -- InventoryList: send the count, not the full list.
            local okIL, il = pcall(function()
                return template.InventoryList
            end)
            if okIL and il then
                local okLen, len = pcall(function() return #il end)
                if okLen and type(len) == "number" then
                    entry.InventoryListCount = len
                end
            end

            -- Stats entry name from the template.
            local okStats, statsVal = pcall(function()
                return template.Stats
            end)
            if okStats and statsVal ~= nil then
                local s = tostring(statsVal)
                if s ~= "" and s ~= "nil" then
                    entry.Stats = s
                end
            end

            -- OnUsePeaceActions: send the count as a signal that
            -- the entity has interaction actions (Open, Use, etc.).
            local okActions, actions = pcall(function()
                return template.OnUsePeaceActions
            end)
            if okActions and actions then
                local okALen, aLen = pcall(function()
                    return #actions
                end)
                if okALen and type(aLen) == "number" then
                    entry.UseActionCount = aLen
                end
            end

            -- Entity component signals: probe the ENTITY (not the
            -- template) for components that definitively classify
            -- it.  These are server-only components the client
            -- cannot see.
            --
            -- InventoryOwner: THE container signal.  Every
            -- lootable container (chests, corpses, pods, barrels)
            -- has it.  Nothing else does.
            --
            -- CanBeInInventory: pickable items the player can
            -- carry.  CanBeLooted: the entity presents a loot UI.
            local entityForGuid = nil
            pcall(function()
                -- Look up the actual entity on the server by UUID
                -- so we can check its components directly.
                -- The template GUID and the entity UUID are
                -- different — we need the entity's Uuid component.
                -- For now, we check the template-level signals
                -- (already captured above) and add entity-level
                -- signals via a secondary lookup if available.
            end)

            -- Since we receive TEMPLATE GUIDs (not entity UUIDs),
            -- we can't directly look up the entity here.  Instead,
            -- we'll add the entity component signals in a separate
            -- channel.  For now, mark which template fields serve
            -- as container proxies.

            -- Template type name: force tostring, skip nil.
            local okType, typeName = pcall(function()
                return template.TemplateName
            end)
            if okType and typeName ~= nil then
                local s = tostring(typeName)
                if s ~= "" and s ~= "nil" then
                    entry.TemplateName = s
                end
            end

            -- Stats classification: if the template has a Stats
            -- field, look up the stats entry and read the game's
            -- own InventoryTab / ObjectCategory / ItemUseType.
            -- These are the AUTHORITATIVE classification signals
            -- that BG3 uses to decide which UI tab an item
            -- belongs to.  Reading stats on the server avoids the
            -- debug-build se_assert crash that happens on the
            -- client when accessing attributes on stats entries
            -- whose ModifierList doesn't include the field.
            if entry.Stats and entry.Stats ~= "" then
                local okStat, statEntry = pcall(
                    Ext.Stats.Get, entry.Stats)
                if okStat and statEntry then
                    -- ModifierList: safe first-class property
                    -- (P_FREE_GETTER, not a stats attribute).
                    -- Reading it never triggers se_assert.
                    local modifierList = ""
                    local okML, ml = pcall(function()
                        return statEntry.ModifierList
                    end)
                    if okML and ml then
                        modifierList = tostring(ml)
                        if modifierList ~= "" and modifierList ~= "nil" then
                            entry.StatsModifierList = modifierList
                        end
                    end

                    -- CRITICAL: InventoryTab, ObjectCategory, and
                    -- ItemUseType are ONLY valid on Object-type
                    -- stats entries.  Reading them on Character,
                    -- Weapon, or Armor entries triggers se_assert
                    -- -> abort() in debug builds.  pcall does NOT
                    -- catch abort().  Gate ALL schema-specific
                    -- reads behind the ModifierList check.
                    if modifierList == "Object" then
                        local okIT, it = pcall(function()
                            return statEntry.InventoryTab
                        end)
                        if okIT and it ~= nil then
                            local s = tostring(it)
                            if s ~= "" and s ~= "nil" then
                                entry.StatsInventoryTab = s
                            end
                        end

                        local okOC, oc = pcall(function()
                            return statEntry.ObjectCategory
                        end)
                        if okOC and oc ~= nil then
                            local s = tostring(oc)
                            if s ~= "" and s ~= "nil" then
                                entry.StatsObjectCategory = s
                            end
                        end

                        local okIUT, iut = pcall(function()
                            return statEntry.ItemUseType
                        end)
                        if okIUT and iut ~= nil then
                            local s = tostring(iut)
                            if s ~= "" and s ~= "nil" then
                                entry.StatsItemUseType = s
                            end
                        end
                    end
                end
            end

            results[uuidStr] = entry
            end -- if template
        end -- if entity
    end -- for each uuid

    -- Send the response back to the requesting client.
    -- BroadcastMessage sends to all clients; in single-player
    -- there is only one client so this is equivalent to a
    -- targeted send without needing the userId/peerId lookup.
    local responsePayload = Ext.Json.Stringify(results)
    Ext.ServerNet.BroadcastMessage(CHANNEL_RESPONSE, responsePayload)
end)

_P("BG3Access: Server classify listener registered on '"
    .. CHANNEL_REQUEST .. "'")

-- ============================================================================
-- Combat Event Relay
--
-- Registers Osiris listeners for combat events and relays them to the
-- client via net messages.  The client's Combat.lua module receives
-- these and generates speech for the screen reader.
--
-- Events relayed:
--   TurnStarted     -- whose turn it is (all combatants)
--   CombatStarted   -- combat begins
--   CombatEnded     -- combat ends
--   RoundStarted    -- new combat round
--   Died            -- character death (all combatants)
--   StatusApplied   -- status effect gained (party members only)
--   StatusRemoved   -- status effect lost (party members only)
--   AttackedBy      -- damage dealt (party member involved)
-- ============================================================================

local COMBAT_CHANNEL = "BG3Access_Combat"

--- Resolve a character GUID to a translated display name.
--- Returns the name string, or "Unknown" if resolution fails.
local function GetCharacterName(characterGuid)
    local resolveOk, resolvedName = pcall(function()
        local entity = Ext.Entity.Get(characterGuid)
        if not entity or not entity.DisplayName then return nil end
        local nameKey = entity.DisplayName.NameKey
        if not nameKey or not nameKey.Handle
            or not nameKey.Handle.Handle then
            return nil
        end
        local translated = Ext.Loca.GetTranslatedString(
            nameKey.Handle.Handle)
        if translated and translated ~= "" then return translated end
        return nil
    end)
    if resolveOk and resolvedName then return resolvedName end
    return "Unknown"
end

--- Check whether a character GUID belongs to a player party member.
local function IsPartyMember(characterGuid)
    local checkOk, checkResult = pcall(function()
        local entity = Ext.Entity.Get(characterGuid)
        if not entity then return false end
        local partyMember = entity.PartyMember
        return partyMember ~= nil
    end)
    return checkOk and checkResult == true
end

--- Resolve a status ID to a human-readable display name.  Returns
--- nil when the status has no localizable DisplayName, which is the
--- standard mark of an internal/meta status (INSURFACE, INENCOUNTER,
--- and similar engine-facing flags) that should not be relayed to
--- the screen reader.  Callers treat nil as "skip this event."
---
--- Also filters placeholder display names that DID resolve but
--- render as unresolved markers: "%%% EMPTY" (placeholder used by
--- some engine-internal statuses with a populated-but-stub
--- DisplayName handle), "h########" (raw LocaString handle that
--- failed to resolve), "[ForceUpdate]" (unresolved Noesis binding
--- marker).  These were slipping through the "empty string" gate.
local function GetStatusDisplayName(statusId)
    local statusOk, statusName = pcall(function()
        local statEntry = Ext.Stats.Get(statusId)
        if statEntry and statEntry.DisplayName
            and statEntry.DisplayName ~= "" then
            local translated = Ext.Loca.GetTranslatedString(
                statEntry.DisplayName)
            if translated and translated ~= "" then
                return translated
            end
        end
        return nil
    end)
    if not statusOk or not statusName then return nil end

    -- Placeholder-name filter.
    if string.sub(statusName, 1, 3) == "%%%" then return nil end
    if string.find(statusName, "ForceUpdate", 1, true) then
        return nil
    end
    -- Raw LocaString handle: starts with 'h' followed by hex.
    if string.match(statusName, "^h[%x]+$") then return nil end

    return statusName
end

--- Send a combat event payload to all clients.
local function RelayCombatEvent(eventData)
    local stringifyOk, payload = pcall(Ext.Json.Stringify, eventData)
    if stringifyOk and payload then
        Ext.ServerNet.BroadcastMessage(COMBAT_CHANNEL, payload)
    end
end

-- Turn started: announce whose turn it is (all combatants).
Ext.Osiris.RegisterListener("TurnStarted", 1, "after",
    function(characterGuid)
        local characterName = GetCharacterName(characterGuid)
        RelayCombatEvent({
            event = "TurnStarted",
            characterGuid = tostring(characterGuid),
            characterName = characterName,
            isPartyMember = IsPartyMember(characterGuid),
        })
    end)

-- Combat started.
Ext.Osiris.RegisterListener("CombatStarted", 1, "after",
    function(combatGuid)
        RelayCombatEvent({
            event = "CombatStarted",
            combatGuid = tostring(combatGuid),
        })
    end)

-- Combat ended.
Ext.Osiris.RegisterListener("CombatEnded", 1, "after",
    function(combatGuid)
        RelayCombatEvent({
            event = "CombatEnded",
            combatGuid = tostring(combatGuid),
        })
    end)

-- New combat round.
Ext.Osiris.RegisterListener("CombatRoundStarted", 2, "after",
    function(combatGuid, round)
        RelayCombatEvent({
            event = "RoundStarted",
            combatGuid = tostring(combatGuid),
            round = round,
        })
    end)

-- Character died (all combatants).
Ext.Osiris.RegisterListener("Died", 1, "after",
    function(characterGuid)
        local characterName = GetCharacterName(characterGuid)
        RelayCombatEvent({
            event = "Died",
            characterGuid = tostring(characterGuid),
            characterName = characterName,
            isPartyMember = IsPartyMember(characterGuid),
        })
    end)

-- Status applied (party members only -- server filters).  Drops
-- statuses whose DisplayName resolution returns nil; those are
-- internal engine flags (INSURFACE, INENCOUNTER, etc.) that spam
-- the screen reader without giving the player useful information.
Ext.Osiris.RegisterListener("StatusApplied", 4, "after",
    function(characterGuid, statusId, causee, storyActionId)
        if not IsPartyMember(characterGuid) then return end
        local statusDisplayName = GetStatusDisplayName(statusId)
        if not statusDisplayName then return end
        local characterName = GetCharacterName(characterGuid)
        RelayCombatEvent({
            event = "StatusApplied",
            characterGuid = tostring(characterGuid),
            characterName = characterName,
            statusId = statusId,
            statusDisplayName = statusDisplayName,
            isPartyMember = true,
        })
    end)

-- Status removed (party members only -- server filters).  Same
-- DisplayName gate as StatusApplied: skip internal engine flags.
Ext.Osiris.RegisterListener("StatusRemoved", 4, "after",
    function(characterGuid, statusId, causee, storyActionId)
        if not IsPartyMember(characterGuid) then return end
        local statusDisplayName = GetStatusDisplayName(statusId)
        if not statusDisplayName then return end
        local characterName = GetCharacterName(characterGuid)
        RelayCombatEvent({
            event = "StatusRemoved",
            characterGuid = tostring(characterGuid),
            characterName = characterName,
            statusId = statusId,
            statusDisplayName = statusDisplayName,
            isPartyMember = true,
        })
    end)

-- Damage dealt (only when a party member is attacker or defender).
Ext.Osiris.RegisterListener("AttackedBy", 7, "after",
    function(defender, attackerOwner, attacker2,
             damageType, damageAmount, damageCause, storyActionId)
        local defenderIsParty = IsPartyMember(defender)
        local attackerIsParty = IsPartyMember(attackerOwner)
        if not defenderIsParty and not attackerIsParty then return end

        local defenderName = GetCharacterName(defender)
        local attackerName = GetCharacterName(attackerOwner)
        RelayCombatEvent({
            event = "AttackedBy",
            defenderGuid = tostring(defender),
            defenderName = defenderName,
            attackerGuid = tostring(attackerOwner),
            attackerName = attackerName,
            damageType = tostring(damageType),
            damageAmount = damageAmount,
            defenderIsParty = defenderIsParty,
            attackerIsParty = attackerIsParty,
        })
    end)

_P("BG3Access: Combat event relay registered on '"
    .. COMBAT_CHANNEL .. "'")

-- ============================================================================
-- Subregion transition relay
--
-- Larian's own Osiris story code fires EnteredTrigger / LeftTrigger
-- events whenever any character crosses a trigger boundary.  We
-- register listeners, filter for the host character crossing a
-- subregion trigger (identified by DB_Subregion membership), and
-- relay a lightweight notification to the client so the accessibility
-- layer can announce "Entering X" / "Leaving X".  No per-tick polling
-- -- the work only happens at actual trigger boundaries.
-- ============================================================================

local SUBREGION_CHANNEL       = "BG3Access_SubregionEvent"
local SUBREGION_QUERY_CHANNEL = "BG3Access_SubregionQuery"

--- Broadcast a subregion transition to all clients.  Client-side
--- listener reads the UI-bound SubRegionName TextBlock to get the
--- localized display name (Larian's Osiris also populates that
--- widget text on the same tick via SetSubRegionName).
---
--- eventName is one of "enter" (crossed boundary into subregion),
--- "leave" (crossed boundary out), "initial" (player started in
--- this subregion -- save load or level warp; phrased differently
--- on the client so it doesn't sound like a fresh crossing).
local function RelaySubregionEvent(eventName, slug)
    local payload = nil
    local okEncode, encoded = pcall(Ext.Json.Stringify, {
        event = eventName,
        slug  = slug,
    })
    if okEncode then payload = encoded end
    if not payload then return end
    pcall(Ext.ServerNet.BroadcastMessage, SUBREGION_CHANNEL, payload)
end

--- Handler shared between EnteredTrigger and LeftTrigger.  Filters
--- to the host character + subregion triggers; silently ignores
--- everything else.
local function HandleSubregionCrossing(eventName, characterGuid, triggerGuid)
    local hostOk, host = pcall(Osi.GetHostCharacter)
    if not hostOk or not host then return end
    if tostring(characterGuid) ~= tostring(host) then return end

    local rowsOk, rows = pcall(function()
        return Osi.DB_Subregion:Get(tostring(triggerGuid), nil, nil, nil)
    end)
    if not rowsOk or not rows or #rows == 0 then return end

    local slug = tostring(rows[1][2])
    RelaySubregionEvent(eventName, slug)
end

pcall(Ext.Osiris.RegisterListener, "EnteredTrigger", 2, "after",
    function(character, trigger)
        HandleSubregionCrossing("enter", character, trigger)
    end)

pcall(Ext.Osiris.RegisterListener, "LeftTrigger", 2, "after",
    function(character, trigger)
        HandleSubregionCrossing("leave", character, trigger)
    end)

--- Broadcast the host character's CURRENT subregion memberships.
--- Called when a client asks for a subregion prime -- after save
--- load, level warp, or client reconnect, since EnteredTrigger
--- doesn't fire for triggers the player is already standing inside.
--- Multiple subregions can overlap (city + district + building);
--- we emit the one with the highest tier (most specific) only.
local function BroadcastCurrentSubregion()
    local hostOk, host = pcall(Osi.GetHostCharacter)
    if not hostOk or not host then return end

    local entityOk, entity = pcall(Ext.Entity.Get, host)
    if not entityOk or not entity then return end
    local triggersInside = entity.TriggerIsInsideOf
    if not triggersInside then return end
    local insideOf = triggersInside.InsideOf
    if not insideOf or #insideOf == 0 then return end

    -- Walk every trigger the host is inside, pick the subregion with
    -- the highest tier (fourth column of DB_Subregion).
    local bestSlug = nil
    local bestTier = -1
    for _, triggerGuid in ipairs(insideOf) do
        local rowsOk, rows = pcall(function()
            return Osi.DB_Subregion:Get(tostring(triggerGuid),
                nil, nil, nil)
        end)
        if rowsOk and rows and #rows > 0 then
            local slug = tostring(rows[1][2])
            local tier = tonumber(rows[1][4]) or 0
            if tier > bestTier then
                bestTier = tier
                bestSlug = slug
            end
        end
    end

    if bestSlug then
        RelaySubregionEvent("initial", bestSlug)
    end
end

Ext.RegisterNetListener(SUBREGION_QUERY_CHANNEL,
    function(channel, payload, userId)
        BroadcastCurrentSubregion()
    end)

_P("BG3Access: Subregion transition relay registered on '"
    .. SUBREGION_CHANNEL .. "'")
_P("BG3Access: Subregion prime query registered on '"
    .. SUBREGION_QUERY_CHANNEL .. "'")
