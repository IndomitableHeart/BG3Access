-- ============================================================================
-- BG3Access HUDReader Module
--
-- On-demand readers for HUD info that the user invokes via the right
-- stick (RS Up / RS Down / RS Right when not in combat).  Extracted
-- from WorldNav.lua because they're not GPS / navigation -- they read
-- character status, current target, and action resources from
-- existing UI widgets / entity components, with no path-finding,
-- entity scanning, or routing logic involved.
--
-- WorldNav.lua hit Lua 5.1's hard limit of 200 module-level locals
-- per file when these readers were added in-place; splitting them
-- into this module restores headroom in WorldNav for future GPS
-- features and gives HUDReader a clean place to grow.
--
-- Public API (called from EventRouter's RS dispatch):
--   SpeakCharacterInfo()    -- RS Up: name, HP, movement, turn / round
--   SpeakTargetInfo()       -- RS Down: cursor target name + action
--   SpeakActionResources()  -- RS Right (out of combat): actions, spell
--                              slots, camp supplies
-- ============================================================================

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

local Log        = BG3Access.Client.Log
local SpeechData = BG3Access.Client.SpeechData

-- ---------------------------------------------------------------------------
-- Entity utilities (intentionally duplicated from WorldNav.lua to keep
-- HUDReader free of cross-module coupling -- ten lines of code is a
-- cheaper trade than a load-order dependency).
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Number / resource helpers
-- ---------------------------------------------------------------------------

--- Format a number as integer if whole, one decimal otherwise.
local function FormatAmount(value)
    if value == math.floor(value) then
        return tostring(math.floor(value))
    end
    return string.format("%.1f", value)
end

--- Read the Movement action resource for an entity.  Returns
--- amount, maxAmount as numbers, or nil, nil when the resource
--- isn't present.  Movement is stored in metres directly (a fresh
--- character has Amount = 9 = 9 metres of remaining movement).
---
--- Discovers Movement by iterating ActionResources.Resources and
--- looking up each resource's name via Ext.StaticData.Get(uuid,
--- "ActionResource").  Avoids hardcoding the Movement UUID --
--- mods can introduce additional movement-like resources, and the
--- StaticData lookup is the same approach SpeakActionResources
--- uses for the full resource list.
local function ReadMovementResource(playerEntity)
    if not playerEntity then return nil, nil end
    local readOk, amount, maxAmount = pcall(function()
        local actionResources = playerEntity.ActionResources
        if not actionResources or not actionResources.Resources then
            return nil, nil
        end
        for resourceUuid, resourceEntries
            in pairs(actionResources.Resources) do
            local nameOk, resourceName = pcall(function()
                local resourceDef = Ext.StaticData.Get(
                    resourceUuid, "ActionResource")
                if resourceDef and resourceDef.Name then
                    return resourceDef.Name
                end
                return nil
            end)
            if nameOk and resourceName == "Movement" then
                for _, entry in pairs(resourceEntries) do
                    local entryAmount = entry.Amount or 0
                    local entryMax = entry.MaxAmount or 0
                    if entryMax > 0 then
                        return entryAmount, entryMax
                    end
                end
            end
        end
        return nil, nil
    end)
    if not readOk then return nil, nil end
    return amount, maxAmount
end

-- ---------------------------------------------------------------------------
-- HUD readers (RS handlers)
-- ---------------------------------------------------------------------------

--- Read character info: name, race/class, HP, movement.
--- In combat, also includes turn status and round number.
--- RS Up handler.
local function SpeakCharacterInfo()
    -- UI text from PartyLine_c widget.
    local hudOk, hudInfo = pcall(Ext.UI.ReadHUDInfo)
    local characterName = ""
    local characterInfo = ""
    if hudOk and hudInfo then
        characterName = hudInfo.characterName or ""
        characterInfo = hudInfo.characterInfo or ""
    end

    -- HP from entity API.  Build the value as just "N of M" (no
    -- trailing "HP") so AddProperty("HP", ...) renders cleanly as
    -- "HP: 10 of 10" rather than "HP: 10 of 10 HP".
    local hpText = ""
    local playerEntity = GetPlayerEntity()
    if playerEntity then
        local hpOk, hpResult = pcall(function()
            local health = playerEntity.Health
            if health then
                return tostring(health.Hp) .. " of "
                    .. tostring(health.MaxHp)
            end
            return nil
        end)
        if hpOk and hpResult then
            hpText = hpResult
        end
    end

    -- Movement: current and max in metres.  Critical in combat
    -- (decides whether you can reach a target without an AoO
    -- provoke), useful out of combat too.  Format uses FormatAmount
    -- (one decimal trim) since BG3 movement values can be
    -- fractional after partial moves.
    local movementText = ""
    local moveAmount, moveMax = ReadMovementResource(playerEntity)
    if moveAmount and moveMax then
        movementText = FormatAmount(moveAmount) .. " of "
            .. FormatAmount(moveMax) .. " meters"
    end

    -- Build speech via SpeechData.
    local charSpeech = SpeechData.Create()
    if characterName ~= "" then
        charSpeech:Add("name", characterName, "brief")
    end
    if characterInfo ~= "" then
        charSpeech:AddProperty("Info", characterInfo, "normal")
    end
    if hpText ~= "" then
        charSpeech:AddProperty("HP", hpText, "brief")
    end
    if movementText ~= "" then
        charSpeech:AddProperty("Movement", movementText, "brief")
    end

    -- Combat info: whose turn and round number.  Build value
    -- without redundant prefix -- AddProperty("Round", "1") renders
    -- as "Round: 1", not "Round: Round 1".
    local Combat = BG3Access.Client.Combat
    if Combat and Combat.IsInCombat and Combat.IsInCombat() then
        local currentTurn = Combat.GetCurrentTurnName
            and Combat.GetCurrentTurnName()
        local currentRound = Combat.GetCurrentRound
            and Combat.GetCurrentRound()
        if currentTurn and currentTurn ~= "" then
            -- Check if it matches the player's character name.
            if characterName ~= ""
                and currentTurn == characterName then
                charSpeech:Add("status", "Your turn", "brief")
            else
                charSpeech:Add("status",
                    currentTurn .. "'s turn", "brief")
            end
        end
        if currentRound and currentRound > 0 then
            charSpeech:AddProperty("Round",
                tostring(currentRound), "normal")
        end
    end

    local charFormatted = charSpeech:Format()
    if charFormatted then
        Ext.Tolk.Speak(charFormatted, true)
    else
        local noCharSpeech = SpeechData.Create()
        noCharSpeech:Add("status",
            "No character info available", "brief")
        Ext.Tolk.Speak(noCharSpeech:Format(), true)
    end
end

--- Read target info: what cursor is on + available action.
--- RS Down handler.
local function SpeakTargetInfo()
    local hudOk, hudInfo = pcall(Ext.UI.ReadHUDInfo)
    local targetName = ""
    local actionText = ""
    if hudOk and hudInfo then
        targetName = hudInfo.targetName or ""
        actionText = hudInfo.actionText or ""
    end

    local targetSpeech = SpeechData.Create()
    if targetName ~= "" then
        targetSpeech:Add("name", targetName, "brief")
    end
    if actionText ~= "" then
        targetSpeech:Add("value", actionText, "normal")
    end

    local targetFormatted = targetSpeech:Format()
    if targetFormatted then
        Ext.Tolk.Speak(targetFormatted, true)
    else
        local noTargetSpeech = SpeechData.Create()
        noTargetSpeech:Add("status", "No target", "brief")
        Ext.Tolk.Speak(noTargetSpeech:Format(), true)
    end
end

--- Read action resources: actions, spell slots, movement, camp supplies.
--- RS Right handler (out-of-combat path; in combat RS Right calls
--- Combat.SpeakTurnOrder per EventRouter dispatch).
---
--- Output shape (single SpeechData with one property per concept):
---   - Available resources: <comma-list of single-charge actions still available>
---   - Used resources: <comma-list of single-charge actions already spent>
---   - <ResourceName>: N of M  (one line per multi-charge resource)
---   - Movement: N of M meters
---   - Spell slots: N of M (total across all levels)
---   - Highest: Level N (omitted when zero remain)
---   - Camp Supplies: N
local function SpeakActionResources()
    local playerEntity = GetPlayerEntity()
    if not playerEntity then
        local noCharSpeech = SpeechData.Create()
        noCharSpeech:Add("status", "No character found", "brief")
        Ext.Tolk.Speak(noCharSpeech:Format(), true)
        return
    end

    -- RESOURCE_NAME_OVERRIDES: BG3's well-known action resources
    -- whose raw StaticData Name needs a custom rewrite rather than
    -- the generic strip ("Reaction Action Point" -> "Reaction"
    -- since Larian's internal naming nests Action twice but the
    -- user-facing term is just "Reaction").  Keys are case-folded
    -- AND space-stripped: looked up via NormalizeKey so a single
    -- entry per concept covers all observed forms ("Action Point",
    -- "Action point", "ActionPoint") across BG3SE builds.
    local RESOURCE_NAME_OVERRIDES = {
        actionpoint         = "Action",
        bonusactionpoint    = "Bonus Action",
        reactionactionpoint = "Reaction",
    }
    local function NormalizeKey(name)
        return name:lower():gsub("%s+", "")
    end
    --- Clean an action-resource name for speech.
    --- 1. Normalized override lookup (handles known awkward names
    ---    regardless of case / spacing variants).
    --- 2. Generic suffix strip: drop trailing "Point"/"Points" with
    ---    optional preceding whitespace.  Covers both "Foo Point"
    ---    (spaced) and "FooPoint" (camelCase) forms.
    --- 3. If the strip leaves an empty string (degenerate case like
    ---    a name that's literally "Point"), fall back to the
    ---    original so we still say something.
    local function CleanResourceName(resourceName)
        if not resourceName or resourceName == "" then
            return resourceName
        end
        local override = RESOURCE_NAME_OVERRIDES[
            NormalizeKey(resourceName)]
        if override then return override end
        local stripped = resourceName:gsub("%s*[Pp]oints?$", "")
        if stripped == "" then return resourceName end
        return stripped
    end
    -- Categorize an ActionResourceEntry into one of:
    --   "movement"     -- player movement budget
    --   "spellSlot"    -- per-level spell-slot-like resource (Level > 0)
    --   "availability" -- single-charge action (MaxAmount == 1)
    --   "counted"      -- multi-charge resource (Ki, Sorcery, surges)
    --   "skip"         -- empty / unusable / unknown
    local function CategorizeResource(resourceName, resourceEntry)
        if not resourceName or resourceName == "" then return "skip" end
        local maxAmount = tonumber(resourceEntry.MaxAmount) or 0
        if maxAmount <= 0 then return "skip" end
        if resourceName == "Movement" then return "movement" end
        local level = tonumber(resourceEntry.Level) or 0
        if level > 0 then return "spellSlot" end
        if maxAmount == 1 then return "availability" end
        return "counted"
    end

    local availableActions = {}
    local usedActions = {}
    local countedResources = {}
    -- Spell slot entries collected as a list rather than a level-keyed
    -- map so multiple slot types at the same level (e.g. Warlock pact
    -- slots and regular spell slots both at Level 3 for a multiclass
    -- caster) accumulate separately instead of overwriting.
    local spellSlotEntries = {}
    local movementText = nil

    -- Action resources from entity component.  Each ActionResourceEntry
    -- has Amount, MaxAmount, Level, ResourceUUID per
    -- BG3Extender/GameDefinitions/Components/ActionResources.h:52-61.
    pcall(function()
        local actionResources = playerEntity.ActionResources
        if not actionResources
            or not actionResources.Resources then return end

        for resourceUuid, resourceEntries in pairs(
                actionResources.Resources) do
            for _, resourceEntry in pairs(resourceEntries) do
                local resourceName = nil
                local nameOk, nameResult = pcall(function()
                    local resourceDef = Ext.StaticData.Get(
                        resourceUuid, "ActionResource")
                    if resourceDef and resourceDef.Name then
                        return resourceDef.Name
                    end
                    return nil
                end)
                if nameOk and nameResult then
                    resourceName = nameResult
                end

                local category = CategorizeResource(
                    resourceName, resourceEntry)
                local amount = tonumber(resourceEntry.Amount) or 0
                local maxAmount = tonumber(resourceEntry.MaxAmount) or 0

                if category == "movement" then
                    movementText = FormatAmount(amount) .. " of "
                        .. FormatAmount(maxAmount) .. " meters"
                elseif category == "spellSlot" then
                    local level = tonumber(resourceEntry.Level) or 0
                    spellSlotEntries[#spellSlotEntries + 1] = {
                        level = level,
                        amount = amount,
                        max = maxAmount,
                    }
                elseif category == "availability" then
                    local cleanName = CleanResourceName(resourceName)
                    if amount > 0 then
                        availableActions[#availableActions + 1] =
                            cleanName
                    else
                        usedActions[#usedActions + 1] = cleanName
                    end
                elseif category == "counted" then
                    countedResources[#countedResources + 1] = {
                        name = CleanResourceName(resourceName),
                        amount = amount,
                        max = maxAmount,
                    }
                end
            end
        end
    end)

    -- Camp Supplies: party-pooled total, independent of the focused
    -- character.  Lives on a party-level entity carrying
    -- CampTotalSupplies (eoc::camp::TotalSuppliesComponent in
    -- BG3Extender/GameDefinitions/Components/Camp.h:48).  Required-
    -- supplies number deliberately omitted: depends on camp quality +
    -- difficulty via LongRestCost (GuidResources.h:1259) and resolving
    -- the right entry needs current camp-quality state.
    local supplyAmount = nil
    pcall(function()
        local supplyEntities = Ext.Entity.GetAllEntitiesWithComponent(
            "CampTotalSupplies")
        if not supplyEntities or #supplyEntities == 0 then return end
        local supplyComp = supplyEntities[1].CampTotalSupplies
        if not supplyComp then return end
        supplyAmount = tonumber(supplyComp.Amount)
    end)

    -- Compose speech.  AddProperty(label, value, tier) renders as
    -- "label: value" so each property contributes one labeled clause.
    local resourceSpeech = SpeechData.Create()
    local emittedAny = false

    if #availableActions > 0 then
        resourceSpeech:AddProperty("Available resources",
            table.concat(availableActions, ", "), "brief")
        emittedAny = true
    end
    if #usedActions > 0 then
        resourceSpeech:AddProperty("Used resources",
            table.concat(usedActions, ", "), "brief")
        emittedAny = true
    end
    for _, countedEntry in ipairs(countedResources) do
        resourceSpeech:AddProperty(
            countedEntry.name,
            FormatAmount(countedEntry.amount) .. " of "
                .. FormatAmount(countedEntry.max),
            "brief")
        emittedAny = true
    end
    if movementText then
        resourceSpeech:AddProperty("Movement", movementText, "brief")
        emittedAny = true
    end
    -- Spell slots: collapse the per-level breakdown into a single
    -- "X of Y total" with a separate "Highest spell slot: Level N"
    -- property when at least one slot remains.  Per-level detail at
    -- high caster levels (Wizard 11+ has slots at every level 1-6)
    -- balloons the readout with information the player already gets
    -- contextually from the spellbook when picking a spell.  The two
    -- actionable facts at a glance are total remaining (am I close
    -- to needing a long rest?) and highest level still available
    -- (what's my biggest spell?).
    local totalAmount = 0
    local totalMax = 0
    local highestAvailable = 0
    for _, slotEntry in ipairs(spellSlotEntries) do
        totalAmount = totalAmount + slotEntry.amount
        totalMax = totalMax + slotEntry.max
        if slotEntry.amount > 0
            and slotEntry.level > highestAvailable then
            highestAvailable = slotEntry.level
        end
    end
    if totalMax > 0 then
        resourceSpeech:AddProperty("Spell slots",
            FormatAmount(totalAmount) .. " of "
                .. FormatAmount(totalMax), "brief")
        emittedAny = true
        if highestAvailable > 0 then
            resourceSpeech:AddProperty("Highest",
                "Level " .. tostring(highestAvailable), "brief")
        end
    end
    if supplyAmount then
        resourceSpeech:AddProperty("Camp Supplies",
            tostring(supplyAmount), "brief")
        emittedAny = true
    end

    if emittedAny then
        Ext.Tolk.Speak(resourceSpeech:Format(), true)
    else
        local noResourceSpeech = SpeechData.Create()
        noResourceSpeech:Add("status",
            "No action resources available", "brief")
        Ext.Tolk.Speak(noResourceSpeech:Format(), true)
    end
end

-- ============================================================================
-- Module export
-- ============================================================================

BG3Access.Client.HUDReader = {
    SpeakCharacterInfo   = SpeakCharacterInfo,
    SpeakTargetInfo      = SpeakTargetInfo,
    SpeakActionResources = SpeakActionResources,
}

if Log and Log.Debug then
    Log.Debug("HUDReader module loaded")
end
