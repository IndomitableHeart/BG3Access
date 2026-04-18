-- File: Client/SpellBook.lua
--
-- Spell book / actions panel handler for BG3Access.
--
-- Handles the in-game spellbook panel (DC type ls.VMSpellBook).
-- Speaks action group headers (VMActionGroup), individual actions
-- (VMCharacterAction), passives (VMPassive), and tab names.
-- Suppresses fake navigation elements.
--
-- Uses the panel handler factory (CreatePanelHandler) from WorldUI.lua
-- and tooltip/lookup functions from Helpers.lua.

local Log = BG3Access.Client.Log
local Helpers = BG3Access.Client.Helpers

-- ============================================================================
-- Constants
-- ============================================================================

-- Component names used to find the active player character entity.
local PLAYER_COMPONENTS = {"ClientControl", "IsPlayer", "PlayerController"}

-- Short ability abbreviations from tooltip -> full names.
local ABILITY_ABBREVIATIONS = {
    STR = "Strength",
    DEX = "Dexterity",
    CON = "Constitution",
    INT = "Intelligence",
    WIS = "Wisdom",
    CHA = "Charisma",
}

-- Layout container types whose x:Name is decorative (not speakable).
local CONTAINER_ELEM_TYPES = {
    Grid = true, Border = true, StackPanel = true, Canvas = true,
    Panel = true, DockPanel = true, WrapPanel = true,
}

-- DC types that should defer to tooltip for speech.
local TOOLTIP_DEFERRED_DC_TYPES = {
    ["ObservableCollection<T>"] = true,
}

-- ============================================================================
-- Tooltip detail parser for actions/spells
-- ============================================================================

--- ParseActionTooltipForDetails: extract combat properties from tooltip
--- texts for actions, spells, and cantrips.  Returns a table of fields:
---   name: action display name
---   damageRange: "4 to 9 damage"
---   roll: dice roll (e.g., "1d6+3")
---   bonusDice: bonus dice (e.g., "+1d6")
---   damageType: damage type (e.g., "Piercing")
---   attackType: "Attack Roll" or "Saving Throw"
---   saveAbility: save ability (e.g., "DEX", "STR")
---   actionCost: action cost (e.g., "Action", "Bonus Action")
---   frequency: usage frequency (e.g., "Per turn", "Short Rest")
---   range: range text (e.g., "Melee", "1.5m", "18m")
---   effectDesc: short functional description
---   warningText: warning message (e.g., "No ranged weapon equipped")
---   category: group category (e.g., "Weapon Actions", "Cantrip")
--- @param tooltipTexts table|nil  Array of raw tooltip strings.
--- @param actionName string|nil  Action name to filter out of results.
--- @return table  Extracted fields (may be empty).
local function ParseActionTooltipForDetails(tooltipTexts, actionName)
    local result = {}
    if not tooltipTexts or #tooltipTexts == 0 then return result end

    local actionNameLower = actionName and actionName:lower() or nil
    local longestDesc = nil
    local longestDescLength = 0

    -- Pre-process: split concatenated entries like
    -- "1.5mDisadvantage." into separate texts.
    local processedTexts = {}
    for _, rawText in ipairs(tooltipTexts) do
        if rawText then
            local range, rest = rawText:match("^([%d%.]+m)(.+)$")
            if range and rest then
                processedTexts[#processedTexts + 1] = range
                processedTexts[#processedTexts + 1] = rest
            else
                processedTexts[#processedTexts + 1] = rawText
            end
        end
    end

    for _, rawText in ipairs(processedTexts) do
        if not rawText or rawText == "" then goto nextTooltip end
        local cleaned = Helpers.StripMarkupTags(rawText)
        if not cleaned or cleaned == "" then goto nextTooltip end
        local lowerCleaned = cleaned:lower()

        -- Skip noise.
        if cleaned == "Inspect" or cleaned == "Close"
            or cleaned == "OK" or cleaned == "."
            or cleaned == ":" then
            goto nextTooltip
        end
        -- Bare numbers.
        if cleaned:match("^[%d%.]+$") then goto nextTooltip end
        -- Unresolved handles/placeholders.
        if cleaned:match("^h%x+g") then goto nextTooltip end
        if cleaned:find("%[ForceUpdate%]") then goto nextTooltip end
        if cleaned:find("s_HandleUnknown") then goto nextTooltip end
        -- Action name itself.
        if actionNameLower and lowerCleaned == actionNameLower then
            goto nextTooltip
        end

        -- Damage range: "4~9 Damage" or "4~15 Damage".
        local damageMin, damageMax = cleaned:match(
            "^(%d+)~(%d+)%s*[Dd]amage$")
        if damageMin then
            result.damageRange = damageMin .. " to " .. damageMax
                .. " damage"
            goto nextTooltip
        end

        -- Healing range: "4~10 Healing".
        local healMin, healMax = cleaned:match(
            "^(%d+)~(%d+)%s*[Hh]ealing")
        if healMin then
            result.damageRange = healMin .. " to " .. healMax
                .. " Healing"
            goto nextTooltip
        end

        -- Dice roll: "1d6+3", "2d4", "+1d6".
        if cleaned:match("^[%+%-]?%d*d%d+[%+%-]?%d*$") then
            -- First dice notation is the primary roll; subsequent
            -- are bonus dice.
            if not result.roll then
                result.roll = cleaned
            else
                -- Strip leading "+" since the detail list adds its
                -- own " + " separator.
                local stripped = cleaned:gsub("^%+", "")
                result.bonusDice = (result.bonusDice
                    and result.bonusDice .. " + " or "") .. stripped
            end
            goto nextTooltip
        end

        -- Action cost.
        if lowerCleaned == "action" then
            result.actionCost = "Action"
            goto nextTooltip
        end
        if lowerCleaned == "bonus action" then
            result.actionCost = "Bonus Action"
            goto nextTooltip
        end
        if lowerCleaned == "reaction" then
            result.actionCost = "Reaction"
            goto nextTooltip
        end

        -- Frequency / cooldown.
        if lowerCleaned == "per turn" then
            result.frequency = "Per turn"
            goto nextTooltip
        end
        if lowerCleaned == "short rest" then
            result.frequency = "Short Rest"
            goto nextTooltip
        end
        if lowerCleaned == "long rest" then
            result.frequency = "Long Rest"
            goto nextTooltip
        end

        -- Attack type.
        if lowerCleaned == "attack roll" then
            result.attackType = "Attack Roll"
            goto nextTooltip
        end
        if lowerCleaned == "saving throw" then
            result.attackType = "Saving Throw"
            goto nextTooltip
        end

        -- Save type: "DEX Save", "STR Save", etc.
        -- These indicate the target's saving throw ability.
        local saveAbbrev = cleaned:match("^(%u+) Save$")
        if saveAbbrev and ABILITY_ABBREVIATIONS[saveAbbrev] then
            result.saveAbility = ABILITY_ABBREVIATIONS[saveAbbrev]
            goto nextTooltip
        end

        -- Bare ability abbreviation (e.g., "INT" for spellcasting,
        -- "DEX" for attack).  These indicate the caster's ability
        -- modifier used for the roll.
        if ABILITY_ABBREVIATIONS[cleaned] then
            result.attackAbilityHint =
                ABILITY_ABBREVIATIONS[cleaned]
            goto nextTooltip
        end
        -- Full ability names.
        local fullAbilityLower = lowerCleaned
        if fullAbilityLower == "strength"
            or fullAbilityLower == "dexterity"
            or fullAbilityLower == "constitution"
            or fullAbilityLower == "intelligence"
            or fullAbilityLower == "wisdom"
            or fullAbilityLower == "charisma" then
            result.attackAbilityHint = cleaned:sub(1, 1):upper()
                .. cleaned:sub(2):lower()
            goto nextTooltip
        end

        -- Range: "Melee", "1.5m", "18m", "5ft", etc.
        if lowerCleaned == "melee" then
            result.range = "Melee"
            goto nextTooltip
        end
        if cleaned:match("^[%d%.]+%s?m$")
            or cleaned:match("^[%d%.]+%s?ft$")
            or cleaned:match("^[%d%.]+%s?feet$")
            or cleaned:match("^[%d%.]+%s?metres?$")
            or cleaned:match("^[%d%.]+%s?meters?$") then
            result.range = cleaned
            goto nextTooltip
        end

        -- Damage type (single word matching DamageType enum).
        if Ext.Enums and Ext.Enums.DamageType then
            local isDamageType = false
            pcall(function()
                isDamageType = Ext.Enums.DamageType[cleaned] ~= nil
            end)
            if isDamageType then
                result.damageType = cleaned
                goto nextTooltip
            end
        end

        -- Disadvantage text.
        if lowerCleaned == "disadvantage"
            or lowerCleaned == "disadvantage." then
            result.disadvantage = true
            goto nextTooltip
        end

        -- Warning messages (e.g., "No ranged weapon equipped.").
        if cleaned:match("^No .+ equipped%.$") then
            local warning = cleaned
            if warning:sub(-1) == "." then
                warning = warning:sub(1, -2)
            end
            result.warningText = warning
            goto nextTooltip
        end

        -- Category badge: "Weapon Actions", "Class Action", "Cantrip",
        -- "Level N Spell".
        if lowerCleaned == "weapon actions"
            or lowerCleaned == "class action"
            or lowerCleaned == "cantrip"
            or cleaned:match("^Level %d+") then
            result.category = cleaned
            goto nextTooltip
        end

        -- Duration.
        if cleaned:match("^%d+ turns?$") then
            result.duration = cleaned
            goto nextTooltip
        end

        -- Single Use.
        if lowerCleaned == "single use" then
            result.singleUse = true
            goto nextTooltip
        end

        -- Concentration.
        if lowerCleaned == "concentration" then
            result.concentration = true
            goto nextTooltip
        end

        -- Effect description: short functional text (10-80 chars).
        if #cleaned > 10 and #cleaned < 80 then
            if not result.effectDesc then
                result.effectDesc = cleaned
            end
        end

        -- Longest remaining text as flavor description fallback.
        if #cleaned > longestDescLength and #cleaned > 20 then
            longestDesc = cleaned
            longestDescLength = #cleaned
        end

        ::nextTooltip::
    end

    result.flavorDesc = longestDesc
    return result
end

-- ============================================================================
-- Entity API helpers
-- ============================================================================

--- GetSelectedCharacterEntity: returns the entity for the character
--- currently displayed in the spellbook.
--- @return userdata|nil  The character entity, or nil if not found.
local function GetSelectedCharacterEntity()
    for _, componentName in ipairs(PLAYER_COMPONENTS) do
        local ok, players = pcall(
            Ext.Entity.GetAllEntitiesWithComponent, componentName)
        if ok and players and #players > 0 then
            return players[1]
        end
    end
    return nil
end

--- GetEquipmentInventory: finds the Equipment-type inventory entity.
--- @param characterEntity userdata  The character entity.
--- @return userdata|nil  The equipment inventory entity, or nil.
local function GetEquipmentInventory(characterEntity)
    local owner = characterEntity.InventoryOwner
    if not owner or not owner.Inventories then return nil end
    local inventoryCount = #owner.Inventories
    for inventoryIndex = 1, inventoryCount do
        local inventoryEntity = owner.Inventories[inventoryIndex]
        if inventoryEntity then
            local inventoryData = inventoryEntity.InventoryData
            if inventoryData then
                local inventoryType = inventoryData.Type
                if inventoryType == 1
                    or tostring(inventoryType) == "Equipment" then
                    return inventoryEntity
                end
            end
        end
    end
    return nil
end

--- GetEquippedWeaponEntity: find the melee main hand weapon entity.
--- @param characterEntity userdata  The character entity.
--- @return userdata|nil  The weapon item entity, or nil.
local function GetEquippedWeaponEntity(characterEntity)
    local equipInventory = GetEquipmentInventory(characterEntity)
    if not equipInventory then return nil end
    local container = equipInventory.InventoryContainer
    if not container or not container.Items then return nil end
    -- MeleeMainHand slot index from StatsItemSlot enum.
    local slotIndex = nil
    pcall(function()
        slotIndex = Ext.Enums.StatsItemSlot.MeleeMainHand.Value
    end)
    if not slotIndex then return nil end
    local slotData = container.Items[slotIndex]
    if slotData and slotData.Item then
        return slotData.Item
    end
    return nil
end

--- AttributeRollModifier: given a roll string like "1d6+3" and tooltip
--- data, determine which ability the +N modifier comes from using the
--- entity API at runtime.
--- Returns formatted roll text like "1d6, +3 from Dexterity".
--- @param rollText string  Raw dice roll (e.g., "1d6+3").
--- @param tooltipData table  Parsed tooltip fields.
--- @return string  Formatted roll with ability attribution.
local function AttributeRollModifier(rollText, tooltipData)
    -- Split roll into dice and modifier: "1d6+3" -> "1d6", "+3"
    local formattedRoll = rollText:gsub(
        "(%d+d%d+)([%+%-])", "%1, %2")

    local characterEntity = GetSelectedCharacterEntity()
    if not characterEntity then return formattedRoll end

    local abilityName = nil
    pcall(function()
        local statsComponent = characterEntity.Stats
        if not statsComponent then return end

        -- Check for ability override boost (Hexblade, etc.).
        pcall(function()
            local overrideBoost = characterEntity
                .WeaponAttackRollAbilityOverride
            if overrideBoost and overrideBoost.Ability then
                local overrideLabel = tostring(overrideBoost.Ability)
                if overrideLabel == "SpellCastingAbility" then
                    abilityName = tostring(
                        statsComponent.SpellCastingAbility)
                elseif overrideLabel ~= "None"
                    and overrideLabel ~= "WeaponAttackAbility" then
                    abilityName = overrideLabel
                end
            end
        end)

        -- Weapon actions: determine from melee/ranged + Finesse.
        local isWeaponAction = tooltipData.category
            and tooltipData.category == "Weapon Actions"

        if isWeaponAction
            and (not abilityName or abilityName == "None") then
            abilityName = nil
            local isMelee = tooltipData.range == "Melee"
            if not isMelee then
                -- Ranged: use entity's RangedAttackAbility.
                local rangedAbility = statsComponent
                    .RangedAttackAbility
                if rangedAbility then
                    abilityName = tostring(rangedAbility)
                end
            else
                -- Melee: check Finesse on the equipped weapon.
                local isFinesse = false
                pcall(function()
                    local finesseMask = 0
                    local finesseFlag = Ext.Enums.WeaponFlags.Finesse
                    if type(finesseFlag) == "number" then
                        finesseMask = finesseFlag
                    elseif finesseFlag then
                        finesseMask = finesseFlag.__Value or 0
                    end
                    if finesseMask > 0 then
                        local weaponEntity = GetEquippedWeaponEntity(
                            characterEntity)
                        if weaponEntity and weaponEntity.Weapon then
                            local weaponFlags = weaponEntity
                                .Weapon.WeaponProperties
                            if weaponFlags and weaponFlags ~= 0 then
                                isFinesse = weaponFlags
                                    % (finesseMask * 2) >= finesseMask
                            end
                        end
                    end
                end)
                if isFinesse then
                    -- Finesse: higher of Str/Dex modifier.
                    local strIndex = Ext.Enums.AbilityId
                        .Strength.Value + 1
                    local dexIndex = Ext.Enums.AbilityId
                        .Dexterity.Value + 1
                    local strMod = statsComponent
                        .AbilityModifiers[strIndex] or 0
                    local dexMod = statsComponent
                        .AbilityModifiers[dexIndex] or 0
                    if dexMod >= strMod then
                        abilityName = Ext.Enums.AbilityId
                            .Dexterity.Label
                    else
                        abilityName = Ext.Enums.AbilityId
                            .Strength.Label
                    end
                else
                    abilityName = Ext.Enums.AbilityId.Strength.Label
                end
            end
        end

        -- Spells/cantrips: tooltip ability hint or SpellCastingAbility.
        if not isWeaponAction
            and (not abilityName or abilityName == "None") then
            abilityName = nil
            if tooltipData.attackAbilityHint then
                abilityName = tooltipData.attackAbilityHint
            else
                local spellAbility = statsComponent
                    .SpellCastingAbility
                if spellAbility then
                    abilityName = tostring(spellAbility)
                end
            end
        end
    end)

    if abilityName and abilityName ~= "None" then
        formattedRoll = formattedRoll .. " from " .. abilityName
    end

    return formattedRoll
end

-- ============================================================================
-- Speech formatting for actions/spells
-- ============================================================================

--- FormatActionSpeech: build SpeechData for a VMCharacterAction.
--- Uses dcProps for the action name, then Ext.Stats API for description,
--- then tooltip data for combat properties.
--- @param dcProps table  DataContext properties from the focused action.
--- @param tooltipTexts table|nil  Cached tooltip texts.
--- @return table  SpeechData object.
local function FormatActionSpeech(dcProps)
    local speechData = Helpers.CreateSpeechData()
    if not dcProps then return speechData end

    -- Action name from dcProps.
    local actionName = dcProps.Text or dcProps.Name or dcProps.Title
    if type(actionName) == "table" then
        actionName = actionName.Str or actionName.Text
            or actionName.Name or nil
    end
    if actionName and actionName ~= "" then
        actionName = Helpers.StripMarkupTags(actionName)
        speechData:Add("name", actionName, "brief")
    end

    -- API description: use LookupFeatureDescription which cascades
    -- through passives, spells, and progression descriptions.
    if actionName and actionName ~= "" then
        local apiDesc = Helpers.LookupFeatureDescription(actionName)
        if apiDesc and apiDesc ~= "" then
            apiDesc = Helpers.StripMarkupTags(apiDesc)
            speechData:Add("description", apiDesc, "verbose")
        end
    end

    return speechData
end

-- ============================================================================
-- Handler factory
-- ============================================================================

--- CreateSpellBookHandler: builds the spellbook handler using the factory
--- from WorldUI.  Called once during module init after WorldUI is loaded.
--- @param createPanelHandler function  WorldUI.CreatePanelHandler factory.
--- @return table  The handler instance.
local function CreateSpellBookHandler(createPanelHandler)

    local handler = createPanelHandler({
        name = "SpellBook",
        hint = "Use bumpers to switch tabs. Up and down to navigate actions.",
        customItemFn = function(focusedElement, handlerState, snapshot)
            local dcType = focusedElement.dcType
            local dcProps = focusedElement.dcProps
            local elemId = focusedElement.elemId or ""

            -- Widget navigation fake elements: suppress or say "Empty slot".
            if elemId:find("WidgetNavigationPrimaryFakeElement")
                or elemId:find("WidgetNavigationSecondaryFakeElement") then
                return "Empty slot", nil, nil
            end

            -- Tab ListBoxItem: suppress as item (screen entry speaks it).
            -- Spellbook tabs use "ListBoxItem::ListBoxItem:" not
            -- "ListBoxItem::Tab", so match both patterns.
            if elemId:find("^ListBoxItem::Tab")
                or (elemId:find("^ListBoxItem::")
                    and dcType == "ls.VMSpellBook") then
                return "", nil, nil
            end

            -- Action group expanders (VMActionGroup): speak group name.
            -- These are containers like "Weapon Actions", "Class Actions",
            -- "Cantrips", "Level 1 Spells", etc.
            if dcType == "ls.VMActionGroup" and dcProps then
                local groupName = dcProps.Text or dcProps.Name
                    or dcProps.Title
                if type(groupName) == "table" then
                    groupName = groupName.Str or groupName.Text
                        or groupName.Name or nil
                end
                if groupName and groupName ~= "" then
                    groupName = Helpers.StripMarkupTags(groupName)
                    -- Expanded/collapsed state from isChecked.
                    local isChecked = focusedElement.isChecked
                    if isChecked == true then
                        groupName = groupName .. ", expanded"
                    elseif isChecked == false then
                        groupName = groupName .. ", collapsed"
                    end
                    return groupName, nil, nil
                end
                -- Fallback: read text blocks from C++ (expander button).
                if elemId:find("ExpanderButton") then
                    local readOk, headerTexts = pcall(
                        Ext.UI.ReadFocusedTextBlocks)
                    if readOk and headerTexts and #headerTexts > 0 then
                        local headerName = Helpers.StripMarkupTags(
                            headerTexts[1])
                        if headerName and headerName ~= "" then
                            local isCheckedAlt = focusedElement.isChecked
                            if isCheckedAlt == true then
                                headerName = headerName .. ", expanded"
                            elseif isCheckedAlt == false then
                                headerName = headerName .. ", collapsed"
                            end
                            return headerName, nil, nil
                        end
                    end
                end
                return "", nil, nil
            end

            -- Expander buttons without VMActionGroup DC (generic fallback).
            if elemId:find("ExpanderButton") then
                local readOk, headerTexts = pcall(
                    Ext.UI.ReadFocusedTextBlocks)
                if readOk and headerTexts and #headerTexts > 0 then
                    local headerName = Helpers.StripMarkupTags(
                        headerTexts[1])
                    if headerName and headerName ~= "" then
                        local isChecked = focusedElement.isChecked
                        if isChecked == true then
                            headerName = headerName .. ", expanded"
                        elseif isChecked == false then
                            headerName = headerName .. ", collapsed"
                        end
                        return headerName, nil, nil
                    end
                end
                return "", nil, nil
            end

            -- Character actions (VMCharacterAction): spells, attacks,
            -- cantrips, weapon actions, class actions.
            if dcType == "ls.VMCharacterAction" and dcProps then
                return FormatActionSpeech(dcProps)
            end

            -- Passives (VMPassive): toggle abilities, auras, etc.
            if dcType == "ls.VMPassive" and dcProps then
                local passiveName = dcProps.Text or dcProps.Name
                if type(passiveName) == "table" then
                    passiveName = passiveName.Str or passiveName.Text
                        or passiveName.Name or nil
                end
                if passiveName and passiveName ~= "" then
                    passiveName = Helpers.StripMarkupTags(passiveName)
                    local apiDesc = Helpers.LookupFeatureDescription(
                        passiveName)
                    if apiDesc then
                        return passiveName, nil, apiDesc
                    end
                    return passiveName, nil, nil
                end
            end

            -- Tooltip-deferred DC types.
            if dcType and TOOLTIP_DEFERRED_DC_TYPES[dcType] then
                return "", nil, nil
            end

            -- Suppress bare layout containers (DockPanel, Grid, etc.).
            local elemType = focusedElement.elemType
            if elemType and not dcProps then
                local baseType = elemType:match("%.(%w+)$") or elemType
                if CONTAINER_ELEM_TYPES[baseType] then
                    return "", nil, nil
                end
            end

            -- Fall through to generic pipeline.
            return nil
        end,

        customTooltipFn = function(tooltipTexts, focusedDCType)
            if not focusedDCType then return nil end

            -- VMCharacterAction: rich action tooltip with combat data.
            -- Parses damage, dice, type, range, attack, cost, frequency
            -- from tooltip texts and assembles into SpeechData.
            if focusedDCType == "ls.VMCharacterAction" then
                if not tooltipTexts or #tooltipTexts == 0 then
                    return nil
                end
                local speechData = Helpers.CreateSpeechData()
                local seen = {}

                -- Pre-process: split concatenated entries like
                -- "1.5mDisadvantage." into separate texts.
                local processedTexts = {}
                for _, rawText in ipairs(tooltipTexts) do
                    if rawText then
                        local range, rest = rawText:match(
                            "^([%d%.]+m)(.+)$")
                        if range and rest then
                            processedTexts[#processedTexts + 1] = range
                            processedTexts[#processedTexts + 1] = rest
                        else
                            processedTexts[#processedTexts + 1] = rawText
                        end
                    end
                end

                for _, rawText in ipairs(processedTexts) do
                    if not rawText or rawText == "" then
                        goto nextTT
                    end
                    local cleaned = Helpers.StripMarkupTags(rawText)
                    if not cleaned or cleaned == "" or cleaned == "."
                        or cleaned == ":" then
                        goto nextTT
                    end
                    -- Skip noise.
                    if cleaned == "Inspect" or cleaned == "Close"
                        or cleaned == "Weapon Damage"
                        or cleaned == "Movement Speed" then
                        goto nextTT
                    end
                    if cleaned:match("^[%d%.]+$") then goto nextTT end
                    if cleaned:match("^h%x+g") then goto nextTT end
                    if cleaned:find("%[ForceUpdate%]") then goto nextTT end
                    if cleaned:find("s_HandleUnknown") then goto nextTT end
                    if seen[cleaned] then goto nextTT end
                    seen[cleaned] = true

                    -- Damage range: "5~15 Damage".
                    local damageMin, damageMax = cleaned:match(
                        "^(%d+)~(%d+)%s*[Dd]amage$")
                    if damageMin then
                        speechData:Add("damage",
                            damageMin .. " to " .. damageMax
                            .. " Damage", "brief")
                        goto nextTT
                    end

                    -- Healing range: "4~10 Healing".
                    local healMin, healMax = cleaned:match(
                        "^(%d+)~(%d+)%s*[Hh]ealing")
                    if healMin then
                        speechData:Add("damage",
                            healMin .. " to " .. healMax
                            .. " Healing", "brief")
                        goto nextTT
                    end

                    -- Dice notation: "1d6+3", "+1d6".
                    if cleaned:match(
                        "^[%+%-]?%d*d%d+[%+%-]?%d*$") then
                        speechData:Add("dice", cleaned, "normal")
                        goto nextTT
                    end

                    -- Damage type (enum match).
                    if Ext.Enums and Ext.Enums.DamageType then
                        local isDamageType = false
                        pcall(function()
                            isDamageType =
                                Ext.Enums.DamageType[cleaned] ~= nil
                        end)
                        if isDamageType then
                            speechData:Add("damageType",
                                cleaned, "normal")
                            goto nextTT
                        end
                    end

                    -- Cost.
                    if cleaned == "Action" then
                        speechData:Add("cost",
                            "Costs Action", "normal")
                        goto nextTT
                    end
                    if cleaned == "Bonus Action" then
                        speechData:Add("cost",
                            "Costs Bonus Action", "normal")
                        goto nextTT
                    end
                    if cleaned == "Reaction" then
                        speechData:Add("cost",
                            "Costs Reaction", "normal")
                        goto nextTT
                    end

                    -- Frequency.
                    if cleaned == "Per turn" then
                        speechData:Add("frequency",
                            "Once per turn", "normal")
                        goto nextTT
                    end
                    if cleaned == "Short Rest"
                        or cleaned == "Long Rest" then
                        speechData:Add("frequency",
                            "Recharges on " .. cleaned, "normal")
                        goto nextTT
                    end

                    -- Duration.
                    if cleaned:match("^%d+ turns?$") then
                        speechData:Add("duration",
                            "Duration " .. cleaned, "normal")
                        goto nextTT
                    end

                    -- Attack type.
                    if cleaned == "Attack Roll" then
                        speechData:Add("attackType",
                            "Attack Roll", "normal")
                        goto nextTT
                    end
                    if cleaned == "Saving Throw" then
                        speechData:Add("attackType",
                            "Saving Throw", "normal")
                        goto nextTT
                    end

                    -- Save type: "DEX Save", "STR Save", etc.
                    local saveAbility = cleaned:match(
                        "^(%u+) Save$")
                    if saveAbility then
                        speechData:Add("saveType",
                            saveAbility .. " Save", "normal")
                        goto nextTT
                    end

                    -- Range.
                    if cleaned == "Melee" then
                        speechData:Add("range",
                            "Melee range", "normal")
                        goto nextTT
                    end
                    if cleaned:match("^[%d%.]+%s?m$")
                        or cleaned:match("^[%d%.]+%s?ft$")
                        or cleaned:match("^[%d%.]+%s?feet$")
                        or cleaned:match("^%d+ft$") then
                        speechData:Add("range",
                            "Range " .. cleaned, "normal")
                        goto nextTT
                    end

                    -- Concentration.
                    if cleaned:lower() == "concentration" then
                        speechData:Add("concentration",
                            "Concentration", "normal")
                        goto nextTT
                    end

                    -- Warning.
                    if cleaned:match("^No .+ equipped%.$") then
                        local warning = cleaned:sub(1, -2)
                        speechData:Add("warning",
                            warning, "brief")
                        goto nextTT
                    end

                    ::nextTT::
                end

                if #speechData.fields == 0 then return nil end
                return speechData
            end

            -- VMPassive: full tooltip.
            if focusedDCType == "ls.VMPassive" then
                return Helpers.FormatFullTooltip(tooltipTexts)
            end

            -- VMActionGroup: suppress tooltip (group name already spoken).
            if focusedDCType == "ls.VMActionGroup" then
                return ""
            end

            -- Other types: default handling.
            return nil
        end,

        buildDetailList = function(focusedData, tooltipTexts)
            if not focusedData then return nil end
            local dcType = focusedData.dcType
            local dcProps = focusedData.dcProps
            if not dcProps then return nil end

            -- VMCharacterAction: action/spell detail view.
            if dcType == "ls.VMCharacterAction" then
                local actionName = dcProps.Text or dcProps.Name
                    or dcProps.Title
                if type(actionName) == "table" then
                    actionName = actionName.Str or actionName.Text
                        or actionName.Name or nil
                end
                if actionName then
                    actionName = Helpers.StripMarkupTags(actionName)
                end

                local tooltipData = ParseActionTooltipForDetails(
                    tooltipTexts, actionName)
                local detailList = {}

                -- Name.
                if actionName and actionName ~= "" then
                    detailList[#detailList + 1] = {
                        label = "Name", value = actionName}
                end

                -- Category.
                if tooltipData.category then
                    detailList[#detailList + 1] = {
                        label = "Category",
                        value = tooltipData.category}
                end

                -- Damage range.
                if tooltipData.damageRange then
                    detailList[#detailList + 1] = {
                        label = "Damage",
                        value = tooltipData.damageRange}
                end

                -- Dice roll with ability attribution.
                if tooltipData.roll then
                    local rollText = AttributeRollModifier(
                        tooltipData.roll, tooltipData)
                    if tooltipData.bonusDice then
                        rollText = rollText .. ", + bonus dice "
                            .. tooltipData.bonusDice
                    end
                    detailList[#detailList + 1] = {
                        label = "Roll", value = rollText}
                end

                -- Damage type.
                if tooltipData.damageType then
                    detailList[#detailList + 1] = {
                        label = "Damage Type",
                        value = tooltipData.damageType}
                end

                -- Attack type.
                if tooltipData.attackType then
                    local attackText = tooltipData.attackType
                    if tooltipData.saveAbility then
                        attackText = attackText .. " ("
                            .. tooltipData.saveAbility .. ")"
                    end
                    detailList[#detailList + 1] = {
                        label = "Attack", value = attackText}
                end

                -- Range.
                if tooltipData.range then
                    detailList[#detailList + 1] = {
                        label = "Range", value = tooltipData.range}
                end

                -- Action cost.
                if tooltipData.actionCost then
                    detailList[#detailList + 1] = {
                        label = "Cost", value = tooltipData.actionCost}
                end

                -- Frequency.
                if tooltipData.frequency then
                    detailList[#detailList + 1] = {
                        label = "Frequency",
                        value = tooltipData.frequency}
                end

                -- Duration.
                if tooltipData.duration then
                    detailList[#detailList + 1] = {
                        label = "Duration",
                        value = tooltipData.duration}
                end

                -- Concentration.
                if tooltipData.concentration then
                    detailList[#detailList + 1] = {
                        label = "Concentration", value = "Yes"}
                end

                -- Disadvantage.
                if tooltipData.disadvantage then
                    detailList[#detailList + 1] = {
                        label = "Disadvantage", value = "Yes"}
                end

                -- Single use.
                if tooltipData.singleUse then
                    detailList[#detailList + 1] = {
                        label = "Single Use", value = "Yes"}
                end

                -- Warning.
                if tooltipData.warningText then
                    detailList[#detailList + 1] = {
                        label = "Warning",
                        value = tooltipData.warningText}
                end

                -- Effect description.
                if tooltipData.effectDesc then
                    detailList[#detailList + 1] = {
                        label = "Effect",
                        value = tooltipData.effectDesc}
                end

                -- API description.
                if actionName and actionName ~= "" then
                    local apiDesc = Helpers.LookupFeatureDescription(
                        actionName)
                    if apiDesc and apiDesc ~= "" then
                        apiDesc = Helpers.StripMarkupTags(apiDesc)
                        detailList[#detailList + 1] = {
                            label = "Description", value = apiDesc}
                    end
                end

                if #detailList == 0 then return nil end
                return detailList
            end

            -- VMPassive: passive detail view.
            if dcType == "ls.VMPassive" then
                local passiveName = dcProps.Text or dcProps.Name
                if type(passiveName) == "table" then
                    passiveName = passiveName.Str or passiveName.Text
                        or passiveName.Name or nil
                end
                if not passiveName or passiveName == "" then return nil end
                passiveName = Helpers.StripMarkupTags(passiveName)

                local detailList = {}
                detailList[#detailList + 1] = {
                    label = "Name", value = passiveName}

                local apiDesc = Helpers.LookupFeatureDescription(
                    passiveName)
                if apiDesc and apiDesc ~= "" then
                    apiDesc = Helpers.StripMarkupTags(apiDesc)
                    detailList[#detailList + 1] = {
                        label = "Description", value = apiDesc}
                end

                return #detailList > 0 and detailList or nil
            end

            return nil
        end,
    })

    return handler
end

-- ============================================================================
-- Exports
-- ============================================================================

BG3Access.Client.SpellBook = {
    CreateSpellBookHandler = CreateSpellBookHandler,
}
