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

--- Read a character entity's current and maximum hit points.
--- Returns {hp=number, maxHp=number} or nil when unavailable (entity
--- missing, Health component absent on level-transient objects, or
--- server-side read faults).  Used to attach defender HP context to
--- damage / miss announcements so the screen reader can say
--- "Gale took 7 fire damage.  13 of 60 remaining."
local function GetCharacterHitpoints(characterGuid)
    local readOk, hitpoints = pcall(function()
        local entity = Ext.Entity.Get(characterGuid)
        if not entity or not entity.Health then return nil end
        local health = entity.Health
        local currentHp = tonumber(health.Hp)
        local maxHp = tonumber(health.MaxHp)
        if not currentHp or not maxHp then return nil end
        return { hp = currentHp, maxHp = maxHp }
    end)
    if readOk and hitpoints then return hitpoints end
    return nil
end

-- HP cache fed by Osiris HitpointsChanged.  Robust workaround for the
-- engine timing race that affects HitResultEvent: the engine commits
-- direct-hit damage to the HealthComponent BEFORE firing the
-- HitResultEvent, but commits status-tick / surface-tick damage AFTER
-- (sometimes 2+ ticks after).  Reading HealthComponent directly in
-- our event handler -- even with Ext.OnNextTick deferral -- can
-- therefore return stale HP for tick-style damage, producing the bug
-- where two back-to-back hits both report the same "X of N remaining"
-- when the second should be N - first - second.
--
-- Strategy: subscribe to HitpointsChanged (Osiris arity 2: character,
-- newHp) and stamp the latest authoritative HP per entity UUID.  The
-- HitResultEvent relay then prefers this cached value over the live
-- component read, falling back to the component only when the entity
-- hasn't been seen yet (first hit of combat, just-spawned, etc.).
-- HitpointsChanged fires synchronously with the engine's HP commit,
-- so by the time our deferred relay runs (~2 ticks after the event),
-- the cache holds the post-damage value regardless of which damage
-- pipeline produced it.
--
-- maxHp doesn't change on damage (only level up / temp-HP boons), so
-- we capture it from the entity component when we first cache an
-- entry and refresh it on subsequent updates.
local latestHpByUuid = {}

-- HitpointsChanged Osiris arg2 is a PERCENTAGE (0-100), not the
-- absolute HP value -- verified empirically: cache reads showed
-- "13.333333969116 of 15 remaining" for an enemy at 2/15 (which is
-- 100 * 2 / 15 = 13.33%).  We ignore the arg entirely and instead
-- read the live HealthComponent at the moment the event fires --
-- the engine has just committed the new value, so the component
-- holds the authoritative absolute HP.  This sidesteps the
-- percentage-vs-absolute confusion AND uses the same field the
-- target select pipeline reads later for consistency.
Ext.Osiris.RegisterListener("HitpointsChanged", 2, "after",
    function(characterGuid, _newHpPercent)
        local uuidStr = tostring(characterGuid)
        local hitpoints = GetCharacterHitpoints(characterGuid)
        if hitpoints then
            latestHpByUuid[uuidStr] = {
                hp    = hitpoints.hp,
                maxHp = hitpoints.maxHp,
            }
        end
    end)

--- Resolve an entity reference (UUID string, EntityHandle userdata,
--- or already-resolved entity table) to a canonical UUID string.
--- Used to key the HP cache uniformly regardless of which Osiris /
--- ECS path delivered the reference -- HitpointsChanged supplies a
--- CHARACTERGUID UUID, HitResultEvent supplies an EntityHandle, and
--- we need both lookups to hit the same cache slot.
local function EntityRefToUuid(entityRef)
    if entityRef == nil then return nil end
    -- Osiris CHARACTERGUIDs / ITEMGUIDs / etc. come through as
    -- strings prefixed with the template name, e.g.
    --   "Elves_Male_High_Player_35219604-4ea5-3c89-fa42-dc5ecf306f8c"
    --   "S_CRA_Escape_IntDevourer2_a2838af7-698b-8761-2004-d118d80cf848"
    -- ...while the EntityHandle-resolved path returns the BARE
    -- UUID ("35219604-...").  We must strip the prefix so both
    -- paths produce the same canonical UUID and burst-key lookups
    -- match.  Match the trailing 8-4-4-4-12 hex group as the UUID;
    -- if no match, fall back to "string contains a dash" as a final
    -- safety net.
    if type(entityRef) == "string" then
        local uuidPart = entityRef:match(
            "(%x+%-%x+%-%x+%-%x+%-%x+)$")
        if uuidPart then return uuidPart end
        if entityRef:find("-") then return entityRef end
    end
    local resolveOk, uuid = pcall(function()
        local entity = Ext.Entity.Get(entityRef)
        if not entity or not entity.Uuid then return nil end
        return tostring(entity.Uuid.EntityUuid)
    end)
    if resolveOk and uuid then return uuid end
    return nil
end

--- Read the cached HP for an entity, falling back to a live component
--- read when the entity hasn't been seen by HitpointsChanged yet.
--- Returns the same {hp, maxHp} shape as GetCharacterHitpoints.
--- Accepts a UUID string OR an EntityHandle -- normalizes through
--- EntityRefToUuid so both Osiris (UUID) and HitResultEvent
--- (EntityHandle) callers hit the same cache.
local function GetCachedOrLiveHitpoints(entityRef)
    local uuidStr = EntityRefToUuid(entityRef)
    if uuidStr then
        local cached = latestHpByUuid[uuidStr]
        if cached and cached.hp ~= nil and cached.maxHp ~= nil then
            return { hp = cached.hp, maxHp = cached.maxHp }
        end
    end
    return GetCharacterHitpoints(entityRef)
end

-- Pending damage bursts (HitResultEvent aggregation).  Defined here,
-- before the AttackedBy / MissedBy listeners, so those listeners can
-- check whether a burst is in flight for the same (attacker,
-- defender) pair and suppress their relay -- otherwise the engine's
-- followup AttackedBy / MissedBy events would speak alongside the
-- burst's CombatHit announcement, doubling up.  Filled by
-- EnqueueDamageBurst (defined later); consumed by FlushDamageBurst
-- (also later) which clears the entry.
local pendingDamageBursts = {}

--- Build the burst key for a given (attacker, defender) pair.  The
--- AttackedBy / MissedBy Osiris listeners receive CHARACTERGUID
--- strings (UUIDs); EnqueueDamageBurst receives EntityHandles and
--- resolves them through EntityRefToUuid -- both paths produce the
--- same canonical UUID string, so the same key composition lookups
--- the same slot.
local function ComposeBurstKey(attackerRef, defenderRef)
    local attackerUuid = EntityRefToUuid(attackerRef)
    local defenderUuid = EntityRefToUuid(defenderRef)
    if not attackerUuid or not defenderUuid then return nil end
    return attackerUuid .. "::" .. defenderUuid
end

--- Returns true if a HitResultEvent burst is currently pending
--- (enqueued but not yet flushed) for the given attacker/defender
--- pair.  AttackedBy and MissedBy use this to suppress their relay
--- when the burst will emit a coherent CombatHit announcement.
local function IsBurstPendingForPair(attackerRef, defenderRef)
    local burstKey = ComposeBurstKey(attackerRef, defenderRef)
    if not burstKey then return false end
    return pendingDamageBursts[burstKey] ~= nil
end

--- Schedule a callback to run after `tickCount` game ticks, chaining
--- Ext.OnNextTick.  Used by the HitResultEvent relay to wait long
--- enough for both the synchronous-commit and deferred-commit damage
--- paths to land in the HitpointsChanged cache before reading.
local function DeferredAfterTicks(tickCount, callback)
    local remaining = tickCount
    local function step()
        remaining = remaining - 1
        if remaining <= 0 then
            callback()
        else
            Ext.OnNextTick(step)
        end
    end
    Ext.OnNextTick(step)
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

-- Server-side combat-active tracking.  Used to gate the enemy-action
-- declaration relays (UsingSpell* / StartAttack) so we don't announce
-- every ambient NPC casting Light in a tavern.  Counter rather than
-- boolean to handle simultaneous combats (rare but possible in BG3
-- when two encounters trigger overlapping).  Math.max guards against
-- underflow if a CombatEnded fires without a prior CombatStarted
-- (e.g., savegame loaded mid-combat).
local activeCombatCount = 0
local function IsAnyCombatActive()
    return activeCombatCount > 0
end

-- Combat started.
Ext.Osiris.RegisterListener("CombatStarted", 1, "after",
    function(combatGuid)
        activeCombatCount = activeCombatCount + 1
        RelayCombatEvent({
            event = "CombatStarted",
            combatGuid = tostring(combatGuid),
        })
    end)

-- Combat ended.
Ext.Osiris.RegisterListener("CombatEnded", 1, "after",
    function(combatGuid)
        activeCombatCount = math.max(0, activeCombatCount - 1)
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
        -- Suppress when a HitResultEvent burst is pending for the
        -- same (attacker, defender) pair.  The engine fires an
        -- AttackedBy event alongside every HitResultEvent (and
        -- sometimes again per damage sub-instance).  When a burst
        -- is in flight, the burst will emit a coherent CombatHit
        -- announcement at flush time covering all the damage --
        -- letting AttackedBy speak in the meantime would double up.
        if IsBurstPendingForPair(attackerOwner, defender) then
            return
        end

        local defenderIsParty = IsPartyMember(defender)
        local attackerIsParty = IsPartyMember(attackerOwner)
        if not defenderIsParty and not attackerIsParty then return end

        local defenderName = GetCharacterName(defender)
        local attackerName = GetCharacterName(attackerOwner)
        -- Prefer the HitpointsChanged-fed cache so the HP read is at
        -- least as fresh as the latest engine commit.  AttackedBy is
        -- usually deduped against the CombatHit fired for the same
        -- damage, but the fallback path (when dedup misses) could
        -- otherwise read pre-commit HP for status / surface ticks.
        local defenderHp = GetCachedOrLiveHitpoints(defender)
        RelayCombatEvent({
            event = "AttackedBy",
            defenderGuid = tostring(defender),
            defenderName = defenderName,
            attackerGuid = tostring(attackerOwner),
            attackerName = attackerName,
            damageType = tostring(damageType),
            damageAmount = damageAmount,
            damageCause = tostring(damageCause or ""),
            defenderIsParty = defenderIsParty,
            attackerIsParty = attackerIsParty,
            defenderHp     = defenderHp and defenderHp.hp or nil,
            defenderMaxHp  = defenderHp and defenderHp.maxHp or nil,
        })
    end)

-- Attack missed (party member attacker or defender).  BG3's AttackedBy
-- fires only on damaging hits; misses need a dedicated event or the
-- player never hears "Tav missed the goblin."  MissedBy signature is
-- (defender, attackerOwner, attacker, storyActionId) -- 4 args.
Ext.Osiris.RegisterListener("MissedBy", 4, "after",
    function(defender, attackerOwner, attacker, storyActionId)
        -- Same suppression rationale as AttackedBy: when a
        -- HitResultEvent burst is pending for this pair, the burst
        -- will emit the miss announcement at flush time.  Letting
        -- MissedBy speak in the meantime would double up.
        if IsBurstPendingForPair(attackerOwner, defender) then
            return
        end

        local defenderIsParty = IsPartyMember(defender)
        local attackerIsParty = IsPartyMember(attackerOwner)
        if not defenderIsParty and not attackerIsParty then return end

        local defenderName = GetCharacterName(defender)
        local attackerName = GetCharacterName(attackerOwner)
        RelayCombatEvent({
            event = "MissedBy",
            defenderGuid = tostring(defender),
            defenderName = defenderName,
            attackerGuid = tostring(attackerOwner),
            attackerName = attackerName,
            defenderIsParty = defenderIsParty,
            attackerIsParty = attackerIsParty,
        })
    end)

_P("BG3Access: Combat event relay registered on '"
    .. COMBAT_CHANNEL .. "'")

-- ---------------------------------------------------------------------------
-- Roll detail relay.
--
-- BG3's Osiris-level combat events (AttackedBy, MissedBy) tell us
-- outcomes but don't carry the d20 breakdown.  The server-side
-- RollSystem tracks every finished roll (attack, save, ability /
-- skill check, initiative, etc.) on a one-frame component called
-- `ServerRollFinishedEvent`, populated with a `FinishedEvent` struct
-- that exposes `NaturalRoll`, `DiceAdditionalValue`, `DC`,
-- `Advantage`, `Disadvantage`, `Roller`, `Subject`, `RollType`,
-- `Ability`, `Skill`, and `Canceled`.
--
-- We subscribe with `Ext.Entity.OnCreateDeferred` for that component
-- type -- the callback fires any time an entity receives the
-- component (BG3SE handles the one-frame lifetime transparently).
-- For each finished event we resolve roller / subject names, filter
-- to rolls involving a party member (same party-only gate as
-- AttackedBy), categorize the roll type, and relay to the client.
-- The client merges attack rolls into subsequent AttackedBy /
-- MissedBy announcements and speaks save / skill / ability-check
-- rolls standalone.
-- ---------------------------------------------------------------------------

--- Resolve an EntityHandle from a roll event to its translated
--- display name.  Rolls come with EntityHandle fields (not GUID
--- strings), so we can't use the GetCharacterName path directly.
--- Returns "Unknown" on any failure -- the relay is best-effort.
local function GetEntityDisplayName(entityHandle)
    if entityHandle == nil then return "Unknown" end
    local resolveOk, resolved = pcall(function()
        local entity = Ext.Entity.Get(entityHandle)
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
    if resolveOk and resolved then return resolved end
    return "Unknown"
end

--- Check whether an EntityHandle belongs to a party member.  Same
--- idea as the GUID-based IsPartyMember, but operates on handles.
local function IsPartyEntity(entityHandle)
    if entityHandle == nil then return false end
    local checkOk, result = pcall(function()
        local entity = Ext.Entity.Get(entityHandle)
        if not entity then return false end
        return entity.PartyMember ~= nil
    end)
    return checkOk and result == true
end

--- Resolve a BG3SE enum-typed value to its string name.  Enum
--- fields on components sometimes come through as the raw numeric
--- value rather than the named string ("RollType=8" instead of
--- "RollType=SkillCheck").  This first log from the roll relay
--- confirmed that: the SkillCheck roll fired with RollType=8.
--- Tostring on a number gives the digits, so the string-match
--- classification below never caught it.  Use Ext.Enums to do
--- the integer -> name translation when needed, and pass strings
--- through unchanged so future BG3SE builds that expose the names
--- directly still work.
local function EnumName(enumName, value)
    if value == nil then return "" end
    -- Coerce whatever BG3SE gave us (number, enum userdata, string)
    -- to a string representation first.
    local text = tostring(value) or ""
    if text == "" then return "" end
    -- Already a non-numeric string (the enum name)?  Pass through.
    if not text:match("^%d+$") then return text end
    -- Looks numeric.  Look up via Ext.Enums.  The result could be
    -- a string OR an enum value (userdata with a __tostring meta)
    -- depending on BG3SE internals -- force another tostring to
    -- normalize to a Lua string so callers can :find / == etc.
    -- without the "Enum values have no property named 'find'"
    -- crash we hit on the first attempt.
    local enumTable = Ext.Enums and Ext.Enums[enumName]
    if enumTable then
        local resolved = enumTable[tonumber(text)]
        if resolved ~= nil then
            local name = tostring(resolved) or ""
            -- Guard against tostring falling back to digits (which
            -- would imply no name metatable); keep the original
            -- numeric text in that case so at least downstream
            -- string ops don't crash.
            if name ~= "" and not name:match("^%d+$") then
                return name
            end
        end
    end
    return text
end

--- Classify a RollType enum into the three buckets the client
--- actually wants to speak about: "attack" (merges with damage /
--- miss announcements), "save" (standalone), "check" (standalone,
--- covers ability checks + skill checks), or "skip" (damage rolls,
--- which AttackedBy already announces, and any other noise).
local function ClassifyRollType(rollType)
    local name = EnumName("StatsRollType", rollType)
    -- Damage-type rolls are redundant with AttackedBy's damage
    -- amount.  Skip entirely.
    if name:find("Damage") then return "skip" end
    -- Attack-type rolls (Attack, MeleeWeaponAttack, etc.).
    if name:find("Attack") then return "attack" end
    -- Saving throws.
    if name == "SavingThrow" or name == "DeathSavingThrow" then
        return "save"
    end
    -- Ability and skill checks (the interactive-ActiveRoll flavour
    -- plus Osiris-driven checks like Perception).
    if name == "SkillCheck" or name == "RawAbility" then
        return "check"
    end
    return "skip"
end

-- Live-path self-dedup.  OnChange("RequestedRoll") empirically fires
-- TWICE per roll (confirmed via the "spokenRollUuids size=1 sample=
-- <this roll's own uuid>" diagnostic): once very early with
-- NaturalRoll populated but Result.Total still zero, and a second
-- time shortly after with the same state.  Without dedup we'd speak
-- the preview twice for every roll.  Scoped to the live path only --
-- the commit path (ServerRollFinishedEvent) gets its own complete
-- breakdown and MUST NOT be deduped against the live preview, or
-- the user loses the "plus 7, total 20, skill name, DC" detail that
-- lives on the commit-time FinishedEvent and that we can't recover
-- from the pre-commit RequestedRollComponent.
--
-- Kept as a simple Lua table keyed by stringified UUID.  Rolls are
-- consumed at most once per playthrough; unbounded growth is a
-- non-issue in practice.
local livePreviewSpokenUuids = {}

--- Normalize a RollUuid-ish field to a string key.  BG3SE sometimes
--- gives us a string, sometimes a struct with a .Value, sometimes a
--- userdata that tostring handles.  Any empty / nil result means
--- "treat as non-dedup-able" -- we speak but don't register.
local function NormalizeRollUuidKey(rollUuid)
    if rollUuid == nil then return nil end
    local text = tostring(rollUuid) or ""
    if text == "" then return nil end
    return text
end

-- Cache: enemy-target entity handle -> {spellName, expiresAtMs}.
-- Populated by the ServerRollStartSpellRequest subscription (below)
-- whenever a party member casts a spell with one or more targets.
-- Consumed by RelayRollEvent: when an enemy-vs-enemy save fires
-- (neither Roller nor Subject is party), we look up the Roller's
-- entity handle here to detect "this enemy is rolling a save
-- because of a party-cast spell that targeted them."  Without
-- this association, the existing party-only roll gate silently
-- drops every enemy save against player spells (Sleep, Hold
-- Person, Command, etc.) -- the player casts the spell and never
-- hears whether any target succeeded or failed the save.
--
-- TTL of 5 seconds: spell cast -> save resolution can take
-- multiple ticks (especially for projectile spells with travel
-- time, or AoEs where each target rolls independently).  5s is
-- generous enough to cover the slowest cases without leaking
-- stale associations into a later, unrelated save the same
-- target rolls.  Entries are also one-shot: consumed on first
-- match so a second save by the same target isn't misattributed.
local pendingPartyCastTargets = {}
local PARTY_CAST_TARGET_TTL_MS = 5000

--- Relay a single FinishedEvent struct to the client.  This is the
--- commit-time path -- fires on A-press and carries the complete
--- breakdown (NaturalRoll + DiceAdditionalValue + DC + advantage
--- flags + outcome).  Always speaks; NEVER deduped against the live
--- path (the live preview only has the natural d20, the commit
--- carries the rest).
local function RelayRollEvent(finishedEvent)
    if finishedEvent.Canceled then
        _P("BG3Access:   skipped (canceled)")
        return
    end

    local rollBucket = ClassifyRollType(finishedEvent.RollType)
    _P("BG3Access:   classified as bucket=" .. rollBucket)
    if rollBucket == "skip" then return end

    local rollerIsParty = IsPartyEntity(finishedEvent.Roller)
    local subjectIsParty = IsPartyEntity(finishedEvent.Subject)
    _P("BG3Access:   rollerParty=" .. tostring(rollerIsParty)
        .. " subjectParty=" .. tostring(subjectIsParty))

    -- Forced-by-party spell context lookup.  When the standard
    -- party-only gate would skip (neither side is party), check
    -- whether the rolling entity is the target of a recent
    -- party-cast spell.  If so, this is an enemy rolling a save
    -- against the player's spell -- relay it with the spell name
    -- attached so the client can announce
    -- "<enemy>, rolled X, <save> DC Y, passed/failed against <spell>".
    -- Only saves are eligible: ability/skill checks aren't typically
    -- forced by an enemy spell cast (and would be noisy if relayed).
    local forcingSpellName = nil
    if not rollerIsParty and not subjectIsParty then
        if rollBucket ~= "save" then
            _P("BG3Access:   skipped (neither side is party)")
            return
        end
        local cacheKey = tostring(finishedEvent.Roller or "")
        local cachedCast = pendingPartyCastTargets[cacheKey]
        if not cachedCast
            or Ext.Utils.MonotonicTime()
                > cachedCast.expiresAtMs then
            pendingPartyCastTargets[cacheKey] = nil
            _P("BG3Access:   skipped (enemy save, no party-cast match)")
            return
        end
        forcingSpellName = cachedCast.spellName
        pendingPartyCastTargets[cacheKey] = nil
        _P("BG3Access:   matched enemy save vs party cast: "
            .. tostring(forcingSpellName))
    end

    local naturalRoll = tonumber(finishedEvent.NaturalRoll) or 0
    -- Skip rolls that never actually produced a d20 result (0).
    -- Happens on canceled / replaced rolls that slipped past the
    -- Canceled check above.
    if naturalRoll == 0 then
        _P("BG3Access:   skipped (NaturalRoll=0)")
        return
    end

    local modifier = tonumber(finishedEvent.DiceAdditionalValue) or 0
    local dc = tonumber(finishedEvent.DC) or 0
    -- DC of 0 means "no target DC" (e.g. some ability checks with
    -- no contested number).  Leave nil so the client can skip the
    -- "DC N" phrase when it doesn't apply.
    if dc == 0 then dc = nil end

    _P("BG3Access:   relaying Natural=" .. naturalRoll
        .. " mod=" .. modifier
        .. " DC=" .. tostring(dc))
    RelayCombatEvent({
        event          = "RollFinished",
        rollUuid       = NormalizeRollUuidKey(finishedEvent.RollUuid) or "",
        rollBucket     = rollBucket,
        -- Resolve enum numbers to names so the client can string-
        -- match against "DeathSavingThrow" etc. without repeating
        -- the integer-vs-name dance.
        rollTypeName   = EnumName("StatsRollType", finishedEvent.RollType),
        naturalRoll    = naturalRoll,
        modifier       = modifier,
        total          = naturalRoll + modifier,
        dc             = dc,
        advantage      = finishedEvent.Advantage == true,
        disadvantage   = finishedEvent.Disadvantage == true,
        rollerName     = GetEntityDisplayName(finishedEvent.Roller),
        subjectName    = GetEntityDisplayName(finishedEvent.Subject),
        rollerIsParty  = rollerIsParty,
        subjectIsParty = subjectIsParty,
        abilityName    = EnumName("AbilityId", finishedEvent.Ability),
        skillName      = EnumName("SkillId", finishedEvent.Skill),
        -- Populated only for enemy-vs-enemy saves where a party
        -- spell is forcing the save (per the
        -- pendingPartyCastTargets lookup above).  Nil for normal
        -- party-side rolls -- the client uses presence/absence to
        -- decide whether to append "against <spell>" to the
        -- announcement.
        forcingSpellName = forcingSpellName,
    })
end

--- Live pre-commit roll preview relay.
---
--- Reads RequestedRollComponent when OnChange fires during roll
--- resolution.  Empirical behaviour:
---   * OnChange fires TWICE per roll with essentially the same state
---     (NaturalRoll populated, Result.Total still 0, Finished=false).
---   * Self-dedup via livePreviewSpokenUuids prevents double-speech.
---   * Canceled stays false throughout a normal roll lifecycle.
---
--- We send a minimal "RollPreview" event carrying only the natural
--- d20 + roll type so the client can speak a terse "<roller> rolled
--- N" announcement.  The subsequent commit-side RollFinished event
--- carries the complete breakdown (modifier, total, DC, advantage,
--- skill/ability name, outcome) and fires independently -- no dedup
--- against the preview.
---
--- That split is deliberate.  The live component lacks the modifier
--- (DiceAdditionalValue only exists on the one-frame FinishedEvent)
--- and Result.Total isn't populated when OnChange fires, so any
--- attempt to relay a complete announcement from here reads total=
--- natural and mod=0 -- misleading for the reroll decision the
--- feature is meant to support.  Preview-only keeps the announcement
--- truthful and the commit announcement untouched.
local function RelayLiveRollComponent(rollComp)
    if not rollComp then return end
    if rollComp.Canceled == true then return end

    local naturalRoll = tonumber(rollComp.NaturalRoll) or 0
    if naturalRoll == 0 then return end

    local uuidKey = NormalizeRollUuidKey(rollComp.RollUuid)
    if uuidKey and livePreviewSpokenUuids[uuidKey] then return end

    local rollBucket = ClassifyRollType(rollComp.RollType)
    if rollBucket == "skip" then
        -- Mark so we also suppress the second OnChange fire for this
        -- roll (damage rolls, etc. that we intentionally ignore).
        if uuidKey then livePreviewSpokenUuids[uuidKey] = true end
        return
    end

    local rollerIsParty = IsPartyEntity(rollComp.Roller)
    local subjectIsParty = IsPartyEntity(rollComp.Subject)
    if not rollerIsParty and not subjectIsParty then
        if uuidKey then livePreviewSpokenUuids[uuidKey] = true end
        return
    end

    _P("BG3Access: LIVE preview relaying"
        .. " uuid=" .. tostring(uuidKey)
        .. " bucket=" .. rollBucket
        .. " Natural=" .. naturalRoll)
    if uuidKey then livePreviewSpokenUuids[uuidKey] = true end
    RelayCombatEvent({
        event          = "RollPreview",
        rollUuid       = uuidKey or "",
        rollBucket     = rollBucket,
        rollTypeName   = EnumName("StatsRollType", rollComp.RollType),
        naturalRoll    = naturalRoll,
        rollerName     = GetEntityDisplayName(rollComp.Roller),
        subjectName    = GetEntityDisplayName(rollComp.Subject),
        rollerIsParty  = rollerIsParty,
        subjectIsParty = subjectIsParty,
    })
end

--- Subscribe to ServerRollFinishedEvent creation.  Instrumented
--- heavily: if the subscription fails outright the error surfaces;
--- if the callback fires we log it unconditionally BEFORE any
--- filtering, so a silent pipeline (no logs) tells us the issue is
--- the subscription itself, and a noisy pipeline with no relays
--- tells us the filters are dropping events.  Remove the per-event
--- logs once we confirm end-to-end flow.
local rollSubId = nil
local rollSubErr = nil
local subscribeOk, subscribeResult = pcall(
    Ext.Entity.OnCreateDeferred, "ServerRollFinishedEvent",
    function(entity, componentType)
        _P("BG3Access: RollFinished callback fired")
        local processOk, processErr = pcall(function()
            local comp = entity.ServerRollFinishedEvent
            if not comp then
                _P("BG3Access:   entity.ServerRollFinishedEvent is nil")
                return
            end
            if not comp.Events then
                _P("BG3Access:   comp.Events is nil")
                return
            end
            _P("BG3Access:   iterating " .. tostring(#comp.Events)
                .. " events")
            for i, rollEvent in ipairs(comp.Events) do
                _P("BG3Access:   event[" .. i .. "] RollType="
                    .. tostring(rollEvent.RollType)
                    .. " Natural=" .. tostring(rollEvent.NaturalRoll)
                    .. " Canceled=" .. tostring(rollEvent.Canceled))
                RelayRollEvent(rollEvent)
            end
        end)
        if not processOk then
            _P("BG3Access: RollFinished handler error: "
                .. tostring(processErr))
        end
    end)
if subscribeOk then
    rollSubId = subscribeResult
    _P("BG3Access: Roll detail relay subscription registered, id="
        .. tostring(rollSubId))
else
    rollSubErr = subscribeResult
    _P("BG3Access: Roll detail relay SUBSCRIPTION FAILED: "
        .. tostring(rollSubErr))
end

-- Live pre-commit roll subscription.  OnChange fires when any field
-- on a RequestedRollComponent mutates -- typically many times per
-- roll as Roller, Subject, DC, then NaturalRoll / Result / Finished
-- get populated.  Our dedup + (Finished==true && NaturalRoll!=0)
-- gate guarantees we only actually relay once per roll.
local liveRollSubId = nil
local liveRollSubErr = nil
local liveSubscribeOk, liveSubscribeResult = pcall(
    Ext.Entity.OnChange, "RequestedRoll",
    function(entity, componentType)
        local processOk, processErr = pcall(function()
            local rollComp = entity.RequestedRoll
            if not rollComp then
                return
            end
            RelayLiveRollComponent(rollComp)
        end)
        if not processOk then
            _P("BG3Access: LIVE roll handler error: "
                .. tostring(processErr))
        end
    end)
if liveSubscribeOk then
    liveRollSubId = liveSubscribeResult
    _P("BG3Access: Live roll relay subscription registered, id="
        .. tostring(liveRollSubId))
else
    liveRollSubErr = liveSubscribeResult
    _P("BG3Access: Live roll relay SUBSCRIPTION FAILED: "
        .. tostring(liveRollSubErr))
end

-- ---------------------------------------------------------------------------
-- Spell display-name resolver (shared by party-cast tracker AND
-- concentration relay below).  Defined before either subscription so
-- both closures capture the local properly -- Lua's local-scope
-- rules require the declaration to precede the closure that
-- references it, otherwise the closure binds to a global lookup
-- (nil at runtime).
--
-- Returns nil when the spell prototype is empty or the name handle
-- fails to resolve; falls back to the prototype string when the
-- cached spell exists but has no resolvable DisplayName so the
-- player at least hears "Spell_Bless" rather than silence.
-- ---------------------------------------------------------------------------
local function GetSpellDisplayName(spellId)
    if spellId == nil then return nil end
    -- Two callers shape this differently:
    --   * ServerRollStartSpellRequest / SpellCastEvent components pass
    --     a SpellId object with a .Prototype field.
    --   * Osiris event listeners (UsingSpell*, CastSpell*, etc.) pass
    --     spellId as a plain FixedString like "Target_FireBolt".
    -- Accept both: if it's already a string, use it as the prototype;
    -- otherwise look up .Prototype on the object.
    local prototype
    if type(spellId) == "string" then
        prototype = spellId
    else
        local prototypeOk, prototypeValue = pcall(function()
            return tostring(spellId.Prototype or "")
        end)
        if not prototypeOk then return nil end
        prototype = prototypeValue
    end
    if not prototype or prototype == "" then
        return nil
    end
    local cachedOk, cached = pcall(Ext.Stats.GetCachedSpell, prototype)
    if not cachedOk or not cached or not cached.Description then
        return prototype
    end
    local nameKey = cached.Description.DisplayName
    if not nameKey then return prototype end
    local handleOk, handleStr = pcall(function()
        return tostring(nameKey.Handle.Handle)
    end)
    if not handleOk or not handleStr or handleStr == "" then
        return prototype
    end
    local translateOk, translated = pcall(
        Ext.Loca.GetTranslatedString, handleStr)
    if translateOk and translated and translated ~= "" then
        return translated
    end
    return prototype
end

-- ---------------------------------------------------------------------------
-- Party-cast spell tracker (feeds enemy-save relay).
--
-- Subscribes to ServerRollStartSpellRequest
-- (esv::active_roll::StartSpellRequestOneFrameComponent in
-- BG3Extender/GameDefinitions/Components/Roll.h:182): fires on every
-- spell-cast roll start with Caster, Spell, and Targets array.  When
-- the caster is a party member, we record each target entity handle
-- in pendingPartyCastTargets so RelayRollEvent's enemy-vs-enemy save
-- branch can detect "this enemy is rolling a save BECAUSE of a
-- party-cast spell" and relay accordingly.
--
-- We intentionally cache ALL party-cast spells, not just save-forcing
-- ones, because there's no reliable way to know in advance whether a
-- specific spell will trigger a save without inspecting its
-- SpellRoll metadata (deep, version-fragile).  Cache entries that
-- never match a save are pruned by the TTL check at lookup time
-- (PARTY_CAST_TARGET_TTL_MS = 5000).  Wasted entries cost a few
-- bytes; missed associations would cost the player a needed
-- combat announcement.
-- ---------------------------------------------------------------------------

local startSpellSubId = nil
local startSpellSubErr = nil
local startSpellSubscribeOk, startSpellSubscribeResult = pcall(
    Ext.Entity.OnCreateDeferred, "ServerRollStartSpellRequest",
    function(entity, componentType)
        local processOk, processErr = pcall(function()
            local comp = entity.ServerRollStartSpellRequest
            if not comp then return end
            local casterEntity = comp.Caster
            if not casterEntity then return end
            if not IsPartyEntity(casterEntity) then return end
            local spellName = GetSpellDisplayName(comp.Spell)
            if not spellName or spellName == "" then return end
            local expiresAtMs = Ext.Utils.MonotonicTime()
                + PARTY_CAST_TARGET_TTL_MS
            local targets = comp.Targets or {}
            for _, initialTarget in ipairs(targets) do
                -- BaseTarget.Target is the EntityHandle; tostring
                -- gives us the stable hash key the relay path
                -- looks up by.  TargetProxy (the optional
                -- override) is a UI-only concept and isn't what
                -- the save actually rolls under.
                local targetHandle = initialTarget.Target
                if targetHandle then
                    local key = tostring(targetHandle)
                    pendingPartyCastTargets[key] = {
                        spellName   = spellName,
                        expiresAtMs = expiresAtMs,
                    }
                end
            end
        end)
        if not processOk then
            _P("BG3Access: StartSpellRequest handler error: "
                .. tostring(processErr))
        end
    end)
if startSpellSubscribeOk then
    startSpellSubId = startSpellSubscribeResult
    _P("BG3Access: Party-cast tracker registered, id="
        .. tostring(startSpellSubId))
else
    startSpellSubErr = startSpellSubscribeResult
    _P("BG3Access: Party-cast tracker SUBSCRIPTION FAILED: "
        .. tostring(startSpellSubErr))
end

-- ---------------------------------------------------------------------------
-- Concentration loss relay.
--
-- BG3 fires the one-frame component `ConcentrationChanged`
-- (esv::concentration::ConcentrationChangedOneFrameComponent in
-- BG3Extender/GameDefinitions/Components/SpellCast.h:884) whenever a
-- caster's concentration state transitions: starts, stops, or is
-- interrupted.  Fields:
--   Started     SpellId  -- the spell newly being concentrated on
--   Ended       SpellId  -- the spell concentration that just ended
--   Interrupted bool     -- true when ended due to damage save fail,
--                           death, dispel, etc.; false when the
--                           caster voluntarily ended (recast, cancel)
--
-- The Constitution save itself is already announced by the existing
-- roll relay path (RollFinishedEvent -> client HandleRollFinishedSave).
-- What that path can't say is which save was a CONCENTRATION save and
-- whether it took the spell down.  This relay closes the gap by
-- announcing the consequence ("X lost concentration on Bless") on the
-- frame the spell drops -- the user has already heard the Con save's
-- pass/fail, so the loss announcement adds the affected spell.
--
-- Filter: party only (same gate as StatusApplied / StatusRemoved -- a
-- world full of enemy spellcasters losing concentration would be
-- noise; the party's own concentration choices are tactical).
-- Interrupted only (voluntary cancel / spell-replace cases produce no
-- new info for the screen reader -- the cast UI already speaks).
-- ---------------------------------------------------------------------------

local concentrationSubId = nil
local concentrationSubErr = nil
local concentrationSubscribeOk, concentrationSubscribeResult = pcall(
    Ext.Entity.OnCreateDeferred, "ConcentrationChanged",
    function(entity, componentType)
        local processOk, processErr = pcall(function()
            local comp = entity.ConcentrationChanged
            if not comp then return end
            -- Voluntary cancel / spell replace: no announcement.
            if comp.Interrupted ~= true then return end
            -- Only the "ended" branch is interesting for loss
            -- announcements.  A pure "Started" event with no Ended
            -- means concentration was just initiated -- the caster
            -- already heard the spell-cast UI.
            local endedSpellName = GetSpellDisplayName(comp.Ended)
            if not endedSpellName or endedSpellName == "" then
                return
            end
            -- Owner of the one-frame component is the caster whose
            -- concentration changed.  Party-only filter keeps enemy
            -- concentration breaks out of the announcement stream.
            if not IsPartyEntity(entity) then return end
            local casterName = GetEntityDisplayName(entity)
            RelayCombatEvent({
                event       = "ConcentrationLost",
                casterName  = casterName,
                spellName   = endedSpellName,
            })
        end)
        if not processOk then
            _P("BG3Access: ConcentrationChanged handler error: "
                .. tostring(processErr))
        end
    end)
if concentrationSubscribeOk then
    concentrationSubId = concentrationSubscribeResult
    _P("BG3Access: Concentration relay subscription registered, id="
        .. tostring(concentrationSubId))
else
    concentrationSubErr = concentrationSubscribeResult
    _P("BG3Access: Concentration relay SUBSCRIPTION FAILED: "
        .. tostring(concentrationSubErr))
end

-- ---------------------------------------------------------------------------
-- Enemy action declaration relay (UsingSpell* / StartAttack).
--
-- HitResultEvent / AttackedBy / MissedBy tell us OUTCOMES (X hit Y for
-- 5, X missed Y).  Sighted players ALSO see the action being declared
-- BEFORE resolution: a spell name pops over the caster, the attack
-- animation starts.  For a blind player tracking what enemies are
-- doing on their turn, that pre-resolution announcement is the gap.
--
-- Filters:
--   1. IsAnyCombatActive() -- skip ambient NPC casts in towns,
--      cinematic spells, etc.  Counter is maintained by the
--      CombatStarted / CombatEnded listeners above.
--   2. Skip party-controlled casters.  When the player casts Fire
--      Bolt the radial menu already announced it; an additional
--      "Tav cast Fire Bolt" here would just repeat it.  Enemy /
--      NPC casts ARE the gap we're closing.
--
-- Spell signature notes (Osiris arities verified against decompiled
-- D:\extracted packs\Osi):
--   * UsingSpellOnTarget(caster, target, spellId, _, _, _)        -> arity 6
--   * UsingSpell(caster, spellId, _, _, _)                          -> arity 5
--   * StartAttack(_, _, attacker, target)                            -> arity 4
--     (positions 1+2 are story / template IDs, position 3 is the
--      actual character per the IsCharacter / PROC_TryStartNPCAttackAD
--      consumption pattern in story.div.osi)
--   * UsingSpellOnZoneWithTarget exists with arity 6 but the
--     argument layout was not unambiguous from the decompile;
--     intentionally not subscribed yet to avoid mis-naming the spell.
-- ---------------------------------------------------------------------------

--- Resolve an Osiris-delivered spell prototype string to a
--- player-facing display name, falling back to the prototype itself
--- when the lookup fails.  Plain wrapper around GetSpellDisplayName;
--- the wrapper exists so the listener bodies stay readable.
local function ResolveSpellNameOrPrototype(spellId)
    local resolved = GetSpellDisplayName(spellId)
    if resolved and resolved ~= "" then return resolved end
    return tostring(spellId or "")
end

-- Dedup state: BG3's engine fires BOTH UsingSpell AND
-- UsingSpellOnTarget for a targeted cast (verified empirically:
-- "Intellect Devourer cast Claws" + "cast Claws on Tav" both fired
-- on every melee attack).  For untargeted casts (Dash, self-buffs)
-- only UsingSpell fires.  We want one announcement per cast, with
-- the target included whenever available.
--
-- Strategy: relay UsingSpellOnTarget synchronously (it carries the
-- richer info), and stamp recentTargetedCastKey with the
-- caster::spell pair.  Defer UsingSpell relay one tick via
-- Ext.OnNextTick; in that handler, check whether a targeted version
-- for the same caster+spell stamped the key during the same frame.
-- If so, skip -- the targeted relay already announced this cast.
-- If not, relay as an untargeted cast.
local recentTargetedCastKey = nil
local recentTargetedCastTimeMs = 0
local TARGETED_CAST_DEDUP_WINDOW_MS = 100

-- Spell cast on a specific target (single-target spells: Mind Blast,
-- Fire Bolt, Vicious Mockery, Knock, etc., AND every melee attack
-- in BG3 because attacks are spells in the engine).
Ext.Osiris.RegisterListener("UsingSpellOnTarget", 6, "after",
    function(caster, target, spellId, _magicType, _spellType, _storyActionId)
        if not IsAnyCombatActive() then return end
        if IsPartyMember(caster) then return end
        recentTargetedCastKey =
            tostring(caster) .. "::" .. tostring(spellId)
        recentTargetedCastTimeMs = Ext.Utils.MonotonicTime()
        local casterName = GetCharacterName(caster)
        local targetName = GetCharacterName(target)
        local spellName = ResolveSpellNameOrPrototype(spellId)
        RelayCombatEvent({
            event         = "SpellCastDeclared",
            casterGuid    = tostring(caster),
            casterName    = casterName,
            casterIsParty = false,
            targetGuid    = tostring(target),
            targetName    = targetName,
            targetIsParty = IsPartyMember(target),
            spellName     = spellName,
        })
    end)

-- Spell cast with no explicit target (self-buffs, dashes, untargeted
-- shouts).  Deferred one tick to dedup against UsingSpellOnTarget --
-- see comment block above.
Ext.Osiris.RegisterListener("UsingSpell", 5, "after",
    function(caster, spellId, _magicType, _spellType, _storyActionId)
        if not IsAnyCombatActive() then return end
        if IsPartyMember(caster) then return end
        local capturedCaster = caster
        local capturedSpellId = spellId
        Ext.OnNextTick(function()
            local thisKey = tostring(capturedCaster)
                .. "::" .. tostring(capturedSpellId)
            if recentTargetedCastKey == thisKey then
                local age = Ext.Utils.MonotonicTime()
                    - recentTargetedCastTimeMs
                if age <= TARGETED_CAST_DEDUP_WINDOW_MS then
                    return  -- targeted version already announced
                end
            end
            local casterName = GetCharacterName(capturedCaster)
            local spellName = ResolveSpellNameOrPrototype(capturedSpellId)
            RelayCombatEvent({
                event         = "SpellCastDeclared",
                casterGuid    = tostring(capturedCaster),
                casterName    = casterName,
                casterIsParty = false,
                spellName     = spellName,
            })
        end)
    end)

-- StartAttack listener intentionally NOT registered.  In BG3 every
-- action is modelled as a spell in the engine's data layer (Main
-- Hand Attack, Claws, Shove, Help, etc. all fire UsingSpell* events
-- with their own spell prototypes).  StartAttack therefore fires
-- redundantly alongside UsingSpellOnTarget for melee attacks --
-- producing duplicate announcements -- and its arg layout
-- (positions 3+4 from the decompile pattern) does not actually
-- carry the target entity in arg 4 the way an initial reading of
-- PROC_TryStartNPCAttackAD(_Var3, _Var4) suggested.  Empirically the
-- defender came back as "Unknown" via GetCharacterName, confirming
-- arg 4 is some other ID (story action / weapon / template).
-- Subscribing UsingSpellOnTarget alone gives us the action name
-- AND a reliable target.

_P("BG3Access: Action declaration relay registered "
    .. "(UsingSpellOnTarget, UsingSpell)")

-- ---------------------------------------------------------------------------
-- Combat attack-hit relay (HitResultEvent).
--
-- Combat attack rolls (Fire Bolt, melee swings, weapon attacks, spell
-- attacks) DO NOT go through ServerRollFinishedEvent -- that path is
-- reserved for the "active roll" UI pipeline used by skill checks,
-- saving throws, and reaction prompts.  Combat hits resolve through
-- esv::hit::HitSystem and fire esv::hit::HitResultEventOneFrameComponent
-- exposed as "HitResultEvent".
--
-- Single HitResultEvent per attack resolution carries EVERYTHING:
-- the attack roll breakdown (NaturalRoll / Total / Critical), itemized
-- modifier sources, damage per type, total damage done, target, AC,
-- and lethal / should-be-downed flags.  Replaces the old multi-fire
-- AttackedBy announcements (which spoke once per damage sub-instance
-- and never carried roll info) with a single coherent announcement.
--
-- Party gate: relay only when the attacker or target is a party
-- member.  Same rationale as the existing AttackedBy gate.
-- ---------------------------------------------------------------------------

--- Safely read a field from a nested component path.  Returns nil on
--- any access failure -- the HitResultEvent structure has deep
--- optional nesting (Hit.ConditionRolls[1].StatsRoll.Result.*) that
--- can miss a link if the game didn't populate an attack roll
--- (e.g. save-or-suck spells where damage happens without a to-hit
--- roll).
local function SafeIndex(root, ...)
    local current = root
    for _, key in ipairs({...}) do
        if type(current) ~= "table" and type(current) ~= "userdata" then
            return nil
        end
        local ok, nextValue = pcall(function() return current[key] end)
        if not ok then return nil end
        current = nextValue
        if current == nil then return nil end
    end
    return current
end

--- Pull the attack-roll StatsRoll out of HitDesc.ConditionRolls.
---
--- Verified against Hit.h:100-111:
---   struct ConditionRoll {
---       uint8_t DataType;
---       ConditionRollType RollType;   -- AttackRoll / AbilityCheckRoll / etc.
---       std::variant<StatsRoll, StatsExpressionResolved> Roll;
---       int Difficulty;
---       Guid RollUuid;
---       bool SwappedSourceAndTarget;
---       AbilityId Ability;
---       SkillId Skill;
---   }
---
---   struct StatsRoll {
---       Roll Roll;                 -- dice definition
---       StatsRollResult Result;    -- Total, NaturalRoll, Critical
---       StatsRollMetadata Metadata;-- ProficiencyBonus, RollBonus, ResolvedRollBonuses
---   }
---
---   struct StatsRollResult {
---       int Total; int NaturalRoll; int DiscardedDiceTotal;
---       RollCritical Critical; ...
---   }
---
--- So the path is:
---   conditionRoll.Roll.Result.NaturalRoll
---   conditionRoll.Roll.Result.Total
---   conditionRoll.Roll.Result.Critical  (enum, not bool)
---
--- The field on ConditionRoll is named "Roll", NOT "StatsRoll".
--- Earlier version had "StatsRoll" based on a research summary and
--- never extracted anything.
---
--- We accept the first entry whose ConditionRollType names it as
--- an attack roll.  If we can't determine the type, fall back to
--- "first entry with non-zero NaturalRoll."
local function ExtractAttackRoll(hitDesc)
    local conditionRolls = SafeIndex(hitDesc, "ConditionRolls")
    if not conditionRolls then return nil end
    local rollCount = 0
    pcall(function() rollCount = #conditionRolls end)
    if rollCount == 0 then return nil end
    for rollIndex = 1, rollCount do
        local conditionRoll = conditionRolls[rollIndex]
        if conditionRoll then
            local statsRoll = SafeIndex(conditionRoll, "Roll")
            if statsRoll then
                local naturalRoll = tonumber(SafeIndex(
                    statsRoll, "Result", "NaturalRoll")) or 0
                if naturalRoll > 0 then
                    return statsRoll
                end
            end
        end
    end
    return nil
end

--- Sum DamageList into a { typeName -> amount } table and a total.
--- BG3's DamageList is typically a vector of { Amount, DamageType }.
--- DamageType is an enum (Fire, Slashing, Force, etc.) that may come
--- through as either a string name or an integer we need to resolve
--- via Ext.Enums.DamageType.
local function SummarizeDamageList(damageList)
    local perType = {}
    local total = 0
    if not damageList then return perType, total end
    local entryCount = 0
    pcall(function() entryCount = #damageList end)
    if entryCount == 0 then return perType, total end
    for damageIndex = 1, entryCount do
        local entry = damageList[damageIndex]
        if entry then
            local amount = tonumber(SafeIndex(entry, "Amount")) or 0
            local damageType = SafeIndex(entry, "DamageType")
            local typeName = EnumName("DamageType", damageType)
            if typeName == "" then typeName = "Damage" end
            if amount > 0 then
                perType[typeName] = (perType[typeName] or 0) + amount
                total = total + amount
            end
        end
    end
    return perType, total
end

--- DiceSizeId enum (Stats.inl:472) -> integer die size.  D100 maps
--- to 100; Default falls back to nil so the formatter can suppress
--- the dice phrase for static / non-rolled damage.
local DICE_SIZE_BY_ENUM_NAME = {
    D4   = 4,
    D6   = 6,
    D8   = 8,
    D10  = 10,
    D12  = 12,
    D20  = 20,
    D100 = 100,
}

--- Walk hitDesc.Damage.DamageRolls -- a LegacyRefMap<DamageType,
--- Array<StatsRoll>> exposed in Hit.h:138 -- and return a flat
--- array of {damageType, diceCount, diceSize, modifier, naturalRoll,
--- total, isNegative} entries.  Used by the verbose-tier client
--- formatter to read out the dice breakdown ("rolled 2 on 1d4 plus 2
--- for 4 slashing").  Returns an empty array when the map is missing
--- or empty (e.g. surface ticks, status ticks without a roll).
---
--- Field paths verified against Hit.h:
---   StatsRoll.Roll              -> Roll struct (Hit.h:30)
---   Roll.Roll                   -> RollDefinition (ExposedTypes.h:66)
---   RollDefinition.DiceValue    -> DiceSizeId enum
---   RollDefinition.AmountOfDices -> uint8_t
---   RollDefinition.DiceAdditionalValue -> int (the static "+N" / "-N")
---   RollDefinition.DiceNegative -> bool (healing rolls, etc.)
---   StatsRoll.Result.NaturalRoll -> int (sum of all dice this roll)
---   StatsRoll.Result.Total       -> int (NaturalRoll + modifier, post-crit)
--- Decode a single StatsRoll into our flat record format, or nil
--- if the roll is a placeholder (no dice, no modifier, no natural).
--- Shared between the DamageRolls path (weapon damage) and the
--- StatsExpressionResolved.RollParams path (spell damage / modifiers).
local function DecodeStatsRoll(statsRoll, damageTypeName)
    if not statsRoll then return nil end
    local rollDef = SafeIndex(statsRoll, "Roll", "Roll")
    local rollResult = SafeIndex(statsRoll, "Result")
    if not rollDef or not rollResult then return nil end
    local diceCount = tonumber(SafeIndex(
        rollDef, "AmountOfDices")) or 0
    local diceSizeName = EnumName("DiceSizeId",
        SafeIndex(rollDef, "DiceValue"))
    local diceSize = DICE_SIZE_BY_ENUM_NAME[diceSizeName]
    local modifier = tonumber(SafeIndex(
        rollDef, "DiceAdditionalValue")) or 0
    local naturalRoll = tonumber(SafeIndex(
        rollResult, "NaturalRoll")) or 0
    local total = tonumber(SafeIndex(
        rollResult, "Total")) or 0
    local isNegative = SafeIndex(rollDef, "DiceNegative") == true
    -- Skip roll definitions that have neither dice
    -- nor a modifier -- those are placeholder entries
    -- the engine sometimes emits for non-rolled damage.
    if diceCount == 0 and modifier == 0 and naturalRoll == 0 then
        return nil
    end
    return {
        damageType  = damageTypeName or "Damage",
        diceCount   = diceCount,
        diceSize    = diceSize,
        modifier    = modifier,
        naturalRoll = naturalRoll,
        total       = total,
        isNegative  = isNegative,
    }
end

--- Walk a StatsExpressionResolved.RollParams array and append any
--- non-placeholder StatsRolls into result.  Used by the spell-
--- damage path: when a spell's damage formula resolves, the dice
--- it rolled live in StatsExpressionResolved.RollParams (Hit.h:93).
local function HarvestExpressionRolls(expressionResolved, damageTypeName, result)
    if not expressionResolved then return end
    local rollParams = SafeIndex(expressionResolved, "RollParams")
    if not rollParams then return end
    local rollCount = 0
    pcall(function() rollCount = #rollParams end)
    for rollIndex = 1, rollCount do
        local decoded = DecodeStatsRoll(rollParams[rollIndex], damageTypeName)
        if decoded then result[#result + 1] = decoded end
    end
end

local function ExtractDamageRolls(hitDesc)
    local result = {}
    local statsDamage = SafeIndex(hitDesc, "Damage")
    if not statsDamage then return result end

    -- Path A: DamageRolls map (weapon damage).
    -- LegacyRefMap<DamageType, Array<StatsRoll>>: each damage type
    -- has its own array of rolled instances.
    local damageRolls = SafeIndex(statsDamage, "DamageRolls")
    if damageRolls then
        -- LegacyRefMap iterates with pairs(); guard with pcall in case
        -- the binding emits a userdata that doesn't support __pairs.
        local pairsOk, pairsIter = pcall(function()
            local outerEntries = {}
            for damageTypeKey, statsRollArray in pairs(damageRolls) do
                outerEntries[#outerEntries + 1] = {
                    damageTypeKey = damageTypeKey,
                    statsRollArray = statsRollArray,
                }
            end
            return outerEntries
        end)
        if pairsOk and pairsIter then
            for _, mapEntry in ipairs(pairsIter) do
                local typeName = EnumName("DamageType", mapEntry.damageTypeKey)
                if typeName == "" then typeName = "Damage" end
                local statsRollArray = mapEntry.statsRollArray
                local rollCount = 0
                pcall(function() rollCount = #statsRollArray end)
                for rollIndex = 1, rollCount do
                    local decoded = DecodeStatsRoll(
                        statsRollArray[rollIndex], typeName)
                    if decoded then
                        result[#result + 1] = decoded
                    end
                end
            end
        end
    end

    -- Path B: ConditionRoll.RollParams (spell-formula damage).
    -- For spells, DealDamageFunctor.Damage is a StatsExpressionRef
    -- (Functors.h:379); when the engine resolves the expression
    -- (e.g. "DealDamage(1d10, Fire)" for Fire Bolt), the rolled
    -- dice land in StatsDamage.ConditionRoll.RollParams as
    -- StatsRoll entries (Hit.h:93, ExtIdeHelpers.lua:6499).
    if #result == 0 then
        local conditionRoll = SafeIndex(statsDamage, "ConditionRoll")
        local primaryDamageType = EnumName("DamageType",
            SafeIndex(hitDesc, "DamageType"))
        if primaryDamageType == "" then primaryDamageType = "Damage" end
        HarvestExpressionRolls(conditionRoll, primaryDamageType, result)
    end

    -- Path C: Modifiers[].Source / Modifiers2[].Source (boost-driven
    -- contributions: Bless +1d4, Sneak Attack +Nd6, etc., as well
    -- as some spell paths).  DamageModifierMetadata.Source is a
    -- variant<int32, RollDefinition, StatsExpressionResolved>;
    -- only the StatsExpressionResolved arm has rolls.
    local function harvestModifierArray(modifierArray)
        if not modifierArray then return end
        local modCount = 0
        pcall(function() modCount = #modifierArray end)
        for modIndex = 1, modCount do
            local modifier = modifierArray[modIndex]
            if modifier then
                local source = SafeIndex(modifier, "Source")
                if source then
                    local typeName = EnumName("DamageType",
                        SafeIndex(modifier, "DamageType"))
                    if typeName == "" then typeName = "Damage" end
                    HarvestExpressionRolls(source, typeName, result)
                end
            end
        end
    end
    if #result == 0 then
        harvestModifierArray(SafeIndex(statsDamage, "Modifiers"))
        harvestModifierArray(SafeIndex(statsDamage, "Modifiers2"))
    end

    return result
end

--- Build a compact string describing an attack's damage for the
--- client formatter, e.g. "9 fire" or "4 fire, 3 piercing".  The
--- client composes this into the full announcement; we keep it as
--- pre-formatted text here so the client doesn't need the damage-
--- type enum resolution logic.
local function FormatDamageBreakdown(perType, total)
    if total == 0 then return "" end
    -- Single-type: "N <type> damage"
    local typeCount = 0
    local soleTypeName, soleAmount = nil, nil
    for typeName, amount in pairs(perType) do
        typeCount = typeCount + 1
        soleTypeName = typeName
        soleAmount = amount
    end
    if typeCount == 1 then
        return tostring(soleAmount) .. " " .. soleTypeName:lower()
    end
    -- Multi-type: "N1 <type1>, N2 <type2>, ..."
    local parts = {}
    for typeName, amount in pairs(perType) do
        parts[#parts + 1] = tostring(amount) .. " "
            .. typeName:lower()
    end
    return table.concat(parts, ", ")
end

--- Relay a single HitResultEvent to the client.
-- ============================================================================
-- Combat damage burst aggregation
--
-- The engine fires a separate HitResultEvent for each damage instance:
-- the direct hit of an attack, then any followup status / surface ticks
-- that hit the same target in the same frame.  Example for Fire Bolt:
--   HitResultEvent #1: cause=Attack, damage=5 fire (Fire Bolt direct)
--   HitResultEvent #2: cause=StatusTick statusId=BURNING, damage=2 fire
-- Both fire on tick N, both with attacker=Tav, target=Devourer.
--
-- Speaking these as two separate sentences with per-event "X of N
-- remaining" requires correlating each HitResultEvent to its
-- corresponding HealthComponent commit, which the engine doesn't
-- expose.  Reading HealthComponent at deferred time gives the FINAL
-- HP (post all events) for both, producing identical "3 of 15
-- remaining" twice.
--
-- Better unit of meaning: the *burst*.  Buffer all HitResultEvents
-- for the same (attacker, defender) pair on the same tick; flush
-- via Ext.OnNextTick (1 tick later, after every commit has landed).
-- Flush reads the engine's final HP once -- authoritative -- and
-- emits a single CombatBurst event:
--   "Tav, rolled 19 plus 3 total 22, hit Intellect Devourer,
--    for 5 fire damage plus 2 fire damage from Burning,
--    3 of 15 remaining"
--
-- The pendingDamageBursts table and EntityRefToUuid helper are
-- declared earlier in the file so AttackedBy / MissedBy can check
-- IsBurstPendingForPair before relaying.  See those declarations
-- above.
-- ============================================================================

local function FlushDamageBurst(burstKey)
    local burst = pendingDamageBursts[burstKey]
    pendingDamageBursts[burstKey] = nil
    if not burst or #burst.events == 0 then return end

    -- Final HP read at flush time.  The engine has committed every
    -- HP change for every HitResultEvent in this burst by now, so
    -- the HealthComponent value is authoritative for the burst's
    -- final state.  No math, no estimation.
    local hitpoints = GetCharacterHitpoints(burst.defenderHandle)
    local defenderHp = hitpoints and hitpoints.hp or nil
    local defenderMaxHp = hitpoints and hitpoints.maxHp or nil

    -- Diagnostic: summarize the burst (cause types + damages + source).
    -- spellId is non-empty for bonus-damage events (Sneak Attack,
    -- Smite, Hex, etc.) and for primary spell hits; empty for plain
    -- weapon attacks.  Logging it helps identify which feature
    -- triggered an unexpected extra die.
    local causeSummary = {}
    for _, ev in ipairs(burst.events) do
        local entry = ev.causeType
            .. "(" .. tostring(ev.damageAmount) .. ")"
        if ev.spellId and ev.spellId ~= "" then
            entry = entry .. "[" .. ev.spellId .. "]"
        end
        causeSummary[#causeSummary + 1] = entry
    end
    _P("BG3Access:   DamageBurst attacker=" .. burst.events[1].attackerName
        .. " defender=" .. burst.events[1].targetName
        .. " events=[" .. table.concat(causeSummary, ",") .. "]"
        .. " finalHp=" .. tostring(defenderHp) .. "/"
        .. tostring(defenderMaxHp))

    -- Emit each event as its own CombatHit -- two short natural
    -- sentences read better than one cluttered combined sentence,
    -- and avoid the "X of N remaining" repetition we'd get if every
    -- event reported HP.  Only the LAST event in the burst includes
    -- the HP suffix -- that's where the engine's final committed HP
    -- is meaningful.  Earlier events skip HP entirely (defenderHp=nil
    -- → client suppresses the suffix).  Net effect for Fire Bolt +
    -- Burning:
    --   "Tav, rolled 18 plus 3 total 21, hit Intellect Devourer,
    --    for 1 fire damage"
    --   "Burning, dealt 2 fire damage to Intellect Devourer,
    --    7 of 15 remaining"
    -- The user hears each engine event reported, no HP repeated,
    -- final HP shown after the chain settles.
    -- Bonus-damage detection: when the burst contains multiple
    -- attack-like events, the second and later ones are damage
    -- instances piggybacking on the same swing (Sneak Attack,
    -- Smite, magic-weapon procs, Hex/Hunter's Mark).  Mark them so
    -- the client can format as "plus N piercing from Sneak Attack"
    -- rather than re-announcing "Tav, hit Intellect Devourer" for
    -- every die.  Status/surface ticks (Burning, fire surface) are
    -- NOT attack-like; those keep their independent announcement
    -- because they're attributed to the status/surface, not the
    -- attacker (e.g. "Burning, dealt 2 fire damage").
    local ATTACK_LIKE_CAUSES = {
        Attack = true, Offhand = true, AURA = true,
        InventoryItem = true, WorldItemThrow = true, None = true,
    }
    local seenAttackLike = false
    for _, ev in ipairs(burst.events) do
        if ATTACK_LIKE_CAUSES[ev.causeType] then
            if seenAttackLike then
                ev.isBonusDamage = true
            else
                seenAttackLike = true
            end
        end
    end

    local lastIndex = #burst.events
    for i, ev in ipairs(burst.events) do
        ev.event = "CombatHit"
        if i == lastIndex then
            ev.defenderHp = defenderHp
            ev.defenderMaxHp = defenderMaxHp
        else
            ev.defenderHp = nil
            ev.defenderMaxHp = nil
        end
        RelayCombatEvent(ev)
    end
end

-- Burst aggregation timing.  The engine doesn't fire all of a damage
-- chain's HitResultEvents on the exact same tick: empirically, Fire
-- Bolt's direct-hit event arrives on tick N, the followup Burning
-- tick can arrive on tick N+1 or even N+2.  A single-tick flush
-- window therefore split the chain into two bursts.
--
-- We use a "quiet period" rule instead: flush when no new event has
-- arrived for FLUSH_QUIET_MS milliseconds.  Each new event resets
-- the quiet timer.  FLUSH_MAX_AGE_MS caps the maximum aggregation
-- time so persistent damage sources (long-lived fire surface, etc.)
-- can't extend a burst indefinitely and starve the announcement.
-- Empirically, BG3 spaces a damage chain's HitResultEvents further
-- apart than expected: Fire Bolt's direct hit and the followup
-- Burning tick can be >50ms apart in real frames.  We need a
-- generous quiet window so they end up in the same burst.  150ms
-- is well within the perception threshold for combat speech (the
-- announcement that follows is itself ~1500ms+ of speech) and
-- catches even slow followup ticks.
-- Single-shot delay before flushing.  Ext.Timer.WaitFor schedules
-- one callback after N ms; the engine is free to fire other events
-- during that interval (in contrast to Ext.OnNextTick polling, which
-- ran on the main game thread every ~1ms and blocked the engine
-- from firing queued HitResultEvents until our polling finished --
-- so Burning's event always landed AFTER the flush no matter the
-- quiet period).  300ms gives the engine room to fire the followup
-- ticks (Fire Bolt commits then Burning ticks ~immediately after
-- when our handler isn't hogging the thread).
local BURST_WAIT_MS = 300

--- Add an event payload to the per-(attacker, defender) burst buffer.
--- First call for a new key schedules a single Ext.Timer.WaitFor
--- flush; later events on the same key just append to the buffer --
--- the already-scheduled timer fires once and picks up everything
--- that accumulated.
local function EnqueueDamageBurst(eventPayload, attackerHandle, defenderHandle)
    local burstKey = ComposeBurstKey(attackerHandle, defenderHandle)
    if not burstKey then return end

    local now = Ext.Utils.MonotonicTime()
    local burst = pendingDamageBursts[burstKey]
    local burstWasNew = false
    if not burst then
        burst = {
            defenderHandle    = defenderHandle,
            events            = {},
            firstEventTimeMs  = now,
        }
        pendingDamageBursts[burstKey] = burst
        burstWasNew = true
    end

    table.insert(burst.events, eventPayload)

    -- Diagnostic: log when each event arrives relative to the burst's
    -- first event.  When new=false we successfully aggregated; when
    -- new=true the burst was already flushed and this event starts a
    -- fresh one (which means BURST_WAIT_MS was too short).
    _P("BG3Access:   BurstEnqueue cause=" .. tostring(eventPayload.causeType)
        .. " damage=" .. tostring(eventPayload.damageAmount)
        .. " burstKey=" .. burstKey
        .. " new=" .. tostring(burstWasNew)
        .. " gapFromFirstMs="
        .. tostring(now - burst.firstEventTimeMs)
        .. " events=" .. tostring(#burst.events))

    if burstWasNew then
        -- One-shot timer.  Crucially does NOT poll on the main thread,
        -- so the engine can fire its queued HitResultEvents during the
        -- wait and they land in this burst before the flush.
        Ext.Timer.WaitFor(BURST_WAIT_MS, function()
            FlushDamageBurst(burstKey)
        end)
    end
end

local function RelayHitResultEvent(entity)
    local hitResult = entity.HitResultEvent
    if not hitResult then return end
    local hitDesc = SafeIndex(hitResult, "Hit")
    if not hitDesc then return end


    -- Resolve attacker / target.
    -- Inflicter is the entity that caused the hit.  For spells cast
    -- by a character, Inflicter is the spell/projectile and
    -- InflicterOwner is the caster -- the caster is what we want to
    -- name.  Fall back to Inflicter if InflicterOwner is empty.
    local inflicter = SafeIndex(hitDesc, "Inflicter")
    local inflicterOwner = SafeIndex(hitDesc, "InflicterOwner")
    local attackerHandle = inflicterOwner or inflicter
    local targetHandle = SafeIndex(hitResult, "Target")

    local attackerName = GetEntityDisplayName(attackerHandle)
    local targetName = GetEntityDisplayName(targetHandle)
    local attackerIsParty = IsPartyEntity(attackerHandle)
    local targetIsParty = IsPartyEntity(targetHandle)

    -- Log the target entity's UUID along with the display name.
    -- Display names are ambiguous for duplicate-named enemies
    -- ("Intellect Devourer" x3 in a single combat) -- the UUID
    -- disambiguates which specific instance was hit, which is
    -- essential for any post-hoc analysis (HP tracking, kill
    -- attribution, replay correlation against client-side reads).
    local targetUuidStr = "?"
    pcall(function()
        if targetHandle and targetHandle.Uuid
            and targetHandle.Uuid.EntityUuid then
            targetUuidStr = tostring(targetHandle.Uuid.EntityUuid)
        end
    end)

    _P("BG3Access: HitResultEvent fired"
        .. " attacker=" .. attackerName
        .. " target=" .. targetName
        .. " targetUuid=" .. targetUuidStr
        .. " attackerParty=" .. tostring(attackerIsParty)
        .. " targetParty=" .. tostring(targetIsParty))

    -- Party gate.
    if not attackerIsParty and not targetIsParty then
        _P("BG3Access:   CombatHit skipped (neither side party)")
        return
    end

    -- Attack roll extraction.  May be nil for save-or-suck spells
    -- (no to-hit roll, target rolls a save).
    --
    -- Verified paths (Hit.h:39-47, 81-86, 100-111):
    --   conditionRoll.Roll                 -- StatsRoll (variant field)
    --   conditionRoll.Roll.Roll.Advantage  -- inner Roll struct (disambiguate!)
    --   conditionRoll.Roll.Roll.Disadvantage
    --   conditionRoll.Roll.Result.NaturalRoll
    --   conditionRoll.Roll.Result.Total
    --   conditionRoll.Roll.Result.Critical -- RollCritical enum: None/Success/Fail
    local attackRoll = ExtractAttackRoll(hitDesc)
    local naturalRoll = nil
    local rollTotal = nil
    local critical = false
    local criticalMiss = false
    local advantage = false
    local disadvantage = false
    local modifier = nil
    if attackRoll then
        naturalRoll = tonumber(SafeIndex(
            attackRoll, "Result", "NaturalRoll"))
        rollTotal = tonumber(SafeIndex(
            attackRoll, "Result", "Total"))
        -- RollCritical is an enum: None=0, Success=1 (natural 20),
        -- Fail=2 (natural 1).  BG3SE delivers enums as their string
        -- names via tostring (userdata with __tostring), so compare
        -- to "Success" / "Fail" rather than ==true.
        local critEnumValue = SafeIndex(attackRoll, "Result", "Critical")
        local critName = ""
        if critEnumValue ~= nil then
            critName = tostring(critEnumValue) or ""
        end
        critical = (critName == "Success")
        criticalMiss = (critName == "Fail")
        -- Advantage / disadvantage live on the INNER Roll struct
        -- (Hit.h:30 - struct Roll { ... bool Advantage; bool Disadvantage; }).
        -- Path is statsRoll.Roll.Advantage (yes, Roll.Roll -- the
        -- outer is StatsRoll, inner is its Roll field).
        advantage = SafeIndex(
            attackRoll, "Roll", "Advantage") == true
        disadvantage = SafeIndex(
            attackRoll, "Roll", "Disadvantage") == true
        if naturalRoll and rollTotal then
            modifier = rollTotal - naturalRoll
        end
    end

    -- Damage extraction: separate the rolled damage (per-type
    -- breakdown via DamageList) from the actual damage delivered
    -- (TotalDamageDone, post-resistance / immunity / temp HP).
    -- Without this split the player hears "Goblin hit Tav for 8
    -- fire damage" while Tav's HP only drops by 4 because Tav has
    -- fire resistance -- the announcement misleads the player about
    -- their actual remaining survivability.
    --
    -- HitDesc fields verified against Hit.h:161-203:
    --   TotalDamageDone        int  -- post-resistance, what HP loses
    --   OriginalDamageValue    int  -- pre-resistance rolled total
    --   DamageList             Array<DamagePair>  -- pre-resistance per-type
    --   Damage.FinalDamage     int  -- another post-resistance signal
    --                                -- (typically equals TotalDamageDone)
    --   Damage.Resistances     Array<DamageResistance>  -- per-type
    --                                                      resistance entries
    local damageList = SafeIndex(hitDesc, "DamageList")
    local perType, rolledDamage = SummarizeDamageList(damageList)
    -- Authoritative actual damage: TotalDamageDone is what the
    -- engine applied to the target this hit.  Fall back to the
    -- DamageList sum only when TotalDamageDone is missing (unusual).
    local actualDamage = tonumber(SafeIndex(
        hitDesc, "TotalDamageDone"))
    if actualDamage == nil then actualDamage = rolledDamage end
    local originalDamage = tonumber(SafeIndex(
        hitDesc, "OriginalDamageValue")) or rolledDamage
    -- Resistance / immunity detection.  If the engine applied less
    -- than was rolled, the difference came from resistance, immunity,
    -- temp HP, or armor absorption -- all observationally equivalent
    -- to the player ("you did less than you rolled").  Immunity is
    -- the special case where ALL damage was absorbed.
    local wasReduced = false
    local wasImmune = false
    if rolledDamage > 0 and actualDamage < rolledDamage then
        wasReduced = true
        if actualDamage == 0 then wasImmune = true end
    end
    -- Per-type phrase generation: only emit when the breakdown is
    -- TRUSTWORTHY (rolled total matches actual).  When resistance
    -- skewed the numbers, the per-type DamageList values overstate
    -- per-type damage, so prefer a flat "N damage" phrase instead
    -- of misleading "8 fire" when only 4 fire actually landed.
    local damagePhrase = ""
    if not wasReduced then
        damagePhrase = FormatDamageBreakdown(perType, actualDamage)
    end

    -- Per-instance dice breakdown for the verbose-tier client
    -- formatter ("rolled 2 on 1d4 plus 2 for 4 slashing").  Empty
    -- array for hits without a roll (status ticks, surface ticks,
    -- pre-rolled snare damage); the client only speaks the dice
    -- phrase when this array has entries AND the user is at
    -- verbose verbosity.
    local damageRolls = ExtractDamageRolls(hitDesc)

    -- Use actualDamage as the canonical number all downstream code
    -- references.  rolledDamage / originalDamage are only carried
    -- for the resistance announcement.
    local totalDamage = actualDamage

    -- Classify the damage source.  HitResultEvent fires once per
    -- damage DELIVERY (not per attack): primary spell hit, surface
    -- tick, status tick (Burning), etc. each fire their own event.
    -- The user needs to hear what's actually damaging them -- a
    -- fire-surface tick attributed to "Tav" is wrong.  CauseType
    -- (Stats.inl:760-773) tells us the source category; StatusId
    -- and SurfaceType name the specific source.
    local causeType = EnumName("CauseType", SafeIndex(hitDesc, "CauseType"))
    local surfaceTypeName = EnumName(
        "SurfaceType", SafeIndex(hitDesc, "SurfaceType"))
    -- StatusId is a FixedString like "BURNING"; pass as-is and let
    -- the client humanize.  Empty string when not status-caused.
    local statusId = tostring(SafeIndex(hitDesc, "StatusId") or "")
    if statusId == "nil" then statusId = "" end

    -- SpellId identifies the source for bonus-damage instances:
    -- weapon attacks fire HitResultEvent with SpellId="" (cause=Attack),
    -- but features that piggyback on an attack (Sneak Attack, Smite,
    -- Hex, Hunter's Mark, magic-weapon procs) fire as a separate
    -- HitResultEvent in the same burst with SpellId set to the
    -- triggering spell/passive (e.g., "Target_SneakAttack",
    -- "Target_DivineSmite", "Shout_HuntersMark_Damage").  Resolve to
    -- a display name via Ext.Stats.GetCachedSpell when available so
    -- the client can attribute the bonus die: "plus 5 piercing from
    -- Sneak Attack".  Resolution path mirrors GetSpellDisplayName
    -- earlier in this file: cached.Description.DisplayName is a
    -- TranslatedString userdata, .Handle.Handle is the loca key,
    -- Ext.Loca.GetTranslatedString resolves the key to a string.
    local spellId = tostring(SafeIndex(hitDesc, "SpellId") or "")
    if spellId == "nil" then spellId = "" end
    local spellName = ""
    if spellId ~= "" then
        local cachedOk, cached = pcall(Ext.Stats.GetCachedSpell, spellId)
        if cachedOk and cached and cached.Description then
            local nameKey = cached.Description.DisplayName
            if nameKey then
                local handleOk, handleStr = pcall(function()
                    return tostring(nameKey.Handle.Handle)
                end)
                if handleOk and handleStr and handleStr ~= "" then
                    local translateOk, translated = pcall(
                        Ext.Loca.GetTranslatedString, handleStr)
                    if translateOk and translated and translated ~= "" then
                        spellName = translated
                    end
                end
            end
        end
        if spellName == "" then
            -- Fallback: humanize the SpellId itself when no loca
            -- is available (modded spells, missing display names).
            spellName = spellId:gsub("^Target_", "")
                              :gsub("^Shout_", "")
                              :gsub("^Projectile_", "")
                              :gsub("_", " ")
        end
    end

    -- Miss detection: HitResultEvent fires for misses too, with
    -- the Miss bit set in EffectFlags (DamageFlags bitmask,
    -- Stats.inl:776-782).  BG3SE bitmasks typically tostring() as
    -- a comma list like "Hit,Critical" -- match literally on the
    -- "Miss" token.  Falls back to damage==0 as a fuzzy miss
    -- indicator for cases where EffectFlags isn't populated.
    local effectFlagsText = tostring(
        SafeIndex(hitDesc, "EffectFlags") or "")
    local isMiss = effectFlagsText:find("Miss") ~= nil

    -- Lethal flag: did this hit drop the target to 0?
    local lethal = SafeIndex(hitResult, "Lethal") == true
    local shouldBeDowned = SafeIndex(hitResult, "ShouldBeDowned") == true
    local ac = tonumber(SafeIndex(hitResult, "AC"))

    -- Build the event payload and aggregate into a per-(attacker,
    -- defender) burst.  See EnqueueDamageBurst for the rationale,
    -- but the short version: cross-event chains (Fire Bolt + Burning)
    -- need to be combined into a single announcement because the
    -- engine commits all damage in the chain in a batch before
    -- firing any HitResultEvent, leaving no per-event HP available.
    local eventPayload = {
        attackerName    = attackerName,
        targetName      = targetName,
        attackerIsParty = attackerIsParty,
        targetIsParty   = targetIsParty,
        causeType       = causeType,
        surfaceType     = surfaceTypeName,
        statusId        = statusId,
        spellId         = spellId,
        spellName       = spellName,
        isMiss          = isMiss,
        naturalRoll     = naturalRoll,
        rollTotal       = rollTotal,
        modifier        = modifier,
        critical        = critical,
        criticalMiss    = criticalMiss,
        advantage       = advantage,
        disadvantage    = disadvantage,
        damageAmount    = totalDamage,
        damagePhrase    = damagePhrase,
        damageRolls     = damageRolls,
        -- perType: kept for cross-event merging in FlushDamageBurst
        -- when one swing produces multiple damage instances (weapon
        -- + Sneak Attack, Smite, etc.).  Not used by the client.
        perType         = perType,
        rolledDamage    = rolledDamage,
        originalDamage  = originalDamage,
        wasReduced      = wasReduced,
        wasImmune       = wasImmune,
        ac              = ac,
        lethal          = lethal,
        shouldBeDowned  = shouldBeDowned,
    }
    EnqueueDamageBurst(eventPayload, attackerHandle, targetHandle)
end

local hitSubId = nil
local hitSubErr = nil
local hitSubscribeOk, hitSubscribeResult = pcall(
    Ext.Entity.OnCreateDeferred, "HitResultEvent",
    function(entity, componentType)
        local processOk, processErr = pcall(RelayHitResultEvent, entity)
        if not processOk then
            _P("BG3Access: HitResultEvent handler error: "
                .. tostring(processErr))
        end
    end)
if hitSubscribeOk then
    hitSubId = hitSubscribeResult
    _P("BG3Access: HitResultEvent subscription registered, id="
        .. tostring(hitSubId))
else
    hitSubErr = hitSubscribeResult
    _P("BG3Access: HitResultEvent SUBSCRIPTION FAILED: "
        .. tostring(hitSubErr))
end

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

-- ============================================================================
-- Auto-walk relay (Osiris CharacterMoveToPosition / CharacterMoveTo)
--
-- Replaces clock-face guidance for routing-list selections.  When the
-- user A-selects a target in the entity list, the client sends a
-- payload here.  We invoke the engine's own auto-walk so the character
-- follows the exact pathfinder route (same one our clock-face was
-- approximating).  No corner-cutting, no "step in fire because the
-- bearing pointed through it" -- the engine drives the character
-- node-by-node along walkable corridors, just like NPCs.
--
-- Osiris signatures (verified via D:\extracted packs\Osi\debug.log):
--   Call CharacterMoveToPosition(CHARACTER, REAL, REAL, REAL,
--                                STRING, STRING, INTEGER)
--      character UUID, x, y, z, "Walk"|"Run", arriveEventName, -1
--   Call CharacterMoveTo(CHARACTER, GUIDSTRING, STRING, STRING,
--                        INTEGER)
--      character UUID, target GUID, "Walk"|"Run", arriveEventName, -1
--
-- Arrival fires Osiris EntityEvent(character, arriveEventName).
-- We use a fixed name and listen for it to relay arrival back to
-- the client for "arrived at X" speech.
-- ============================================================================

local AUTOWALK_CHANNEL          = "BG3Access_AutoWalk"
local AUTOWALK_RESULT_CHANNEL   = "BG3Access_AutoWalkResult"
local AUTOWALK_EVENT_NAME       = "BG3Access_AutoWalkArrived"

--- Relay a single auto-walk lifecycle event to the client.
local function RelayAutoWalkResult(eventKind, characterUuid, targetName)
    local payload = {
        event         = eventKind,           -- "started" / "arrived" / "cancelled" / "failed"
        characterUuid = characterUuid or "",
        targetName    = targetName or "",
    }
    local jsonOk, jsonStr = pcall(Ext.Json.Stringify, payload)
    if not jsonOk then return end
    pcall(Ext.ServerNet.BroadcastMessage,
        AUTOWALK_RESULT_CHANNEL, jsonStr)
end

Ext.RegisterNetListener(AUTOWALK_CHANNEL,
    function(channel, payload, userId)
        local parseOk, request = pcall(Ext.Json.Parse, payload)
        if not parseOk or type(request) ~= "table" then
            _P("BG3Access: AutoWalk bad payload")
            return
        end

        local characterUuid = tostring(request.characterUuid or "")
        if characterUuid == "" then
            _P("BG3Access: AutoWalk missing characterUuid")
            return
        end

        local walkOrRun = request.walkOrRun
        if walkOrRun ~= "Walk" and walkOrRun ~= "Run" then
            walkOrRun = "Walk"
        end

        local targetName = tostring(request.targetName or "")
        local targetUuid = tostring(request.targetUuid or "")
        local position   = request.position

        local invokeOk, invokeErr
        if targetUuid ~= "" then
            invokeOk, invokeErr = pcall(Osi.CharacterMoveTo,
                characterUuid, targetUuid,
                walkOrRun, AUTOWALK_EVENT_NAME, -1)
            _P("BG3Access: AutoWalk CharacterMoveTo char="
                .. characterUuid .. " target=" .. targetUuid
                .. " mode=" .. walkOrRun
                .. " ok=" .. tostring(invokeOk))
        elseif type(position) == "table"
            and tonumber(position.x) and tonumber(position.y)
            and tonumber(position.z) then
            invokeOk, invokeErr = pcall(Osi.CharacterMoveToPosition,
                characterUuid,
                tonumber(position.x), tonumber(position.y), tonumber(position.z),
                walkOrRun, AUTOWALK_EVENT_NAME, -1)
            _P("BG3Access: AutoWalk CharacterMoveToPosition char="
                .. characterUuid
                .. string.format(" pos=(%.2f,%.2f,%.2f)",
                    position.x, position.y, position.z)
                .. " mode=" .. walkOrRun
                .. " ok=" .. tostring(invokeOk))
        else
            _P("BG3Access: AutoWalk no target or position supplied")
            return
        end

        if invokeOk then
            RelayAutoWalkResult("started", characterUuid, targetName)
        else
            _P("BG3Access: AutoWalk Osi call error: " .. tostring(invokeErr))
            RelayAutoWalkResult("failed", characterUuid, targetName)
        end
    end)

-- Track in-flight walks by character UUID -> target name so the
-- arrival event handler can name the destination on the client.
local pendingAutoWalkTargets = {}

Ext.RegisterNetListener(AUTOWALK_CHANNEL .. "_TrackTarget",
    function(channel, payload, userId)
        local parseOk, request = pcall(Ext.Json.Parse, payload)
        if not parseOk or type(request) ~= "table" then return end
        local characterUuid = tostring(request.characterUuid or "")
        if characterUuid == "" then return end
        pendingAutoWalkTargets[characterUuid] =
            tostring(request.targetName or "")
    end)

-- Listen for the arrival event we instructed the engine to fire.
-- Osi.RegisterListener pattern (used elsewhere in this file for
-- combat events).  Engine fires this as EntityEvent(character,
-- AUTOWALK_EVENT_NAME) when the auto-walk completes.
local autoWalkArrivalSubOk, autoWalkArrivalErr = pcall(
    Ext.Osiris.RegisterListener,
    "EntityEvent", 2, "before", function(characterRef, eventName)
        if tostring(eventName) ~= AUTOWALK_EVENT_NAME then return end
        local characterUuid = EntityRefToUuid(characterRef)
        if not characterUuid then return end
        local targetName = pendingAutoWalkTargets[characterUuid] or ""
        pendingAutoWalkTargets[characterUuid] = nil
        _P("BG3Access: AutoWalk arrived char=" .. characterUuid
            .. " target=" .. targetName)
        RelayAutoWalkResult("arrived", characterUuid, targetName)
    end)
if not autoWalkArrivalSubOk then
    _P("BG3Access: AutoWalk arrival listener FAILED: "
        .. tostring(autoWalkArrivalErr))
end

_P("BG3Access: AutoWalk relay registered on '"
    .. AUTOWALK_CHANNEL .. "'")
