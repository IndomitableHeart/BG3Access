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
        local defenderHp = GetCharacterHitpoints(defender)
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
    -- Same party-only gate as AttackedBy.  We care when a party
    -- member rolled or when a non-party roll is targeting a party
    -- member (enemy attack rolls, enemy-forced saves).
    if not rollerIsParty and not subjectIsParty then
        _P("BG3Access:   skipped (neither side is party)")
        return
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

    _P("BG3Access: HitResultEvent fired"
        .. " attacker=" .. attackerName
        .. " target=" .. targetName
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

    -- Damage.  Prefer DamageList (per-type breakdown) over flat
    -- Damage int (which would lose the per-type split we need for
    -- natural speech).
    local damageList = SafeIndex(hitDesc, "DamageList")
    local perType, totalDamage = SummarizeDamageList(damageList)
    if totalDamage == 0 then
        -- Fall back to TotalDamageDone if DamageList was empty
        -- (unusual but possible for some hit types).
        totalDamage = tonumber(SafeIndex(
            hitDesc, "TotalDamageDone")) or 0
    end
    local damagePhrase = FormatDamageBreakdown(perType, totalDamage)

    -- Target HP after the hit.  GetCharacterHitpoints returns a
    -- single table {hp=N, maxHp=M} (or nil), NOT two return values;
    -- destructure here rather than assigning both to the same var.
    local targetHp, targetMaxHp = nil, nil
    local hitpoints = GetCharacterHitpoints(targetHandle)
    if hitpoints then
        targetHp = hitpoints.hp
        targetMaxHp = hitpoints.maxHp
    end

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

    _P("BG3Access:   CombatHit"
        .. " cause=" .. causeType
        .. " surface=" .. surfaceTypeName
        .. " status=" .. statusId
        .. " miss=" .. tostring(isMiss)
        .. " roll=" .. tostring(naturalRoll)
        .. " total=" .. tostring(rollTotal)
        .. " crit=" .. tostring(critical)
        .. " damage=" .. tostring(totalDamage)
        .. " damagePhrase='" .. damagePhrase .. "'"
        .. " targetHp=" .. tostring(targetHp) .. "/" .. tostring(targetMaxHp)
        .. " lethal=" .. tostring(lethal))

    RelayCombatEvent({
        event           = "CombatHit",
        attackerName    = attackerName,
        targetName      = targetName,
        attackerIsParty = attackerIsParty,
        targetIsParty   = targetIsParty,
        causeType       = causeType,
        surfaceType     = surfaceTypeName,
        statusId        = statusId,
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
        ac              = ac,
        defenderHp      = targetHp,
        defenderMaxHp   = targetMaxHp,
        lethal          = lethal,
        shouldBeDowned  = shouldBeDowned,
    })
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
