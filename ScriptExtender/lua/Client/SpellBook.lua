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
local SpeechData = BG3Access.Client.SpeechData

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

    -- Pre-process: extract text from {role, text} entries and split
    -- concatenated entries like "1.5mDisadvantage." into separate texts.
    local processedTexts = {}
    for _, tooltipEntry in ipairs(tooltipTexts) do
        local entryText = tooltipEntry.text
        if entryText then
            local range, rest = entryText:match("^([%d%.]+m)(.+)$")
            if range and rest then
                processedTexts[#processedTexts + 1] = range
                processedTexts[#processedTexts + 1] = rest
            else
                processedTexts[#processedTexts + 1] = entryText
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
            -- No " damage" suffix; detail view uses label = "Damage".
            result.damageRange = damageMin .. " to " .. damageMax
            goto nextTooltip
        end

        -- Healing range: "4~10 Healing".
        local healMin, healMax = cleaned:match(
            "^(%d+)~(%d+)%s*[Hh]ealing")
        if healMin then
            result.healingRange = healMin .. " to " .. healMax
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
    local speechData = SpeechData.Create()
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

            -- (LSGrid empty-cell phantoms now handled universally by
            -- Helpers.CleanElementName -- the factory's generic path
            -- speaks "Empty slot" before reaching here.)

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

            -- SpellBook header stat containers (caster classes only).
            -- Three focusable ContentControls in the right-side header
            -- per SpellBook_c.xaml:
            --   line 690 - CastAbilityContainer (spellcasting ability,
            --              renders short ability name like "WIS")
            --   line 713 - SpellDCContainer (Spell Save DC numeric value)
            --   line 723 - SpellAttackContainer (Spell Attack signed bonus)
            -- The framework's elemName resolver auto-derives a
            -- human-readable label from the OUTER container's x:Name
            -- ("CastAbilityContainer" -> "Cast Ability") OR falls back
            -- to the inner rendered text when no derivable name exists
            -- (yielding bare "13" / "+5" for the numeric containers).
            -- Detect each by its observed elemName pattern and return
            -- a SpeechData with the proper labeled AddProperty so the
            -- formatter renders "Spell Save DC: 13" architecturally
            -- (no string concat).  The factory accepts a SpeechData
            -- return (per WorldUI.lua:1015-1024) and uses it directly.
            -- SpellBook header stat containers (caster classes only).
            -- Three focusable ContentControls in the right-side header
            -- per SpellBook_c.xaml -- match by their literal x:Name:
            --   line 690 - CastAbilityContainer (spellcasting ability;
            --              inner Control renders short name like "WIS")
            --   line 713 - SpellDCContainer (Spell Save DC value)
            --   line 723 - SpellAttackContainer (Spell Attack bonus)
            -- focusedElement.elemName carries the raw x:Name as
            -- authored in the XAML (NOT a derived display label), so
            -- an exact match against each Container's x:Name is the
            -- correct identifier.  ReadFocusedTextBlocks pulls the
            -- inner rendered value (the ability name / DC number /
            -- bonus) which we attach via AddProperty so the formatter
            -- emits "Spell Save DC: 13" architecturally.
            local STAT_LABELS = {
                CastAbilityContainer = "Spellcasting ability",
                SpellDCContainer     = "Spell Save DC",
                SpellAttackContainer = "Spell Attack bonus",
            }
            local elemName = focusedElement.elemName or ""
            local statLabel = STAT_LABELS[elemName]
            if statLabel then
                local statValue = nil
                local readOk, focusedTexts = pcall(
                    Ext.UI.ReadFocusedTextBlocks)
                if readOk and focusedTexts and #focusedTexts > 0 then
                    statValue = Helpers.StripMarkupTags(focusedTexts[1])
                end
                local statSpeech = SpeechData.Create()
                if statValue and statValue ~= "" then
                    statSpeech:AddProperty(statLabel,
                        statValue, "brief")
                else
                    -- No inner value read: speak just the label so
                    -- the user at least knows which stat is focused.
                    statSpeech:Add("name", statLabel, "brief")
                end
                return statSpeech
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
                local speechData = SpeechData.Create()
                local seen = {}

                -- Pre-process: extract text from {role, text, typeId}
                -- entries and split concatenated entries like
                -- "1.5mDisadvantage." into separate texts.  Each
                -- processedTexts element is now a {text, typeId}
                -- table so the matcher loop can use typeId to
                -- disambiguate properties whose values look alike
                -- (e.g. Jump's two distance values: TypeId="Range"
                -- for max jump distance vs TypeId="ZoneRadius" for
                -- the secondary distance, both rendered as "6m" /
                -- "3m").  When a single entry is split, the typeId
                -- is dropped from the synthetic halves -- they
                -- weren't a single semantic property to begin with.
                -- Pre-process the raw tooltipTexts list:
                -- 1. Pair consecutive CostTemplateRoot Value+Name
                --    entries into one synthetic entry whose text
                --    is "<Value> <Name>" (e.g. "3m Movement
                --    Speed").  These represent secondary costs
                --    the action consumes (movement, charges) --
                --    structurally distinct from the action-type
                --    cost ("Bonus Action") that uses a single
                --    Name-only entry.  Tagged with synthetic
                --    typeId="CostPair" so the matcher can route.
                -- 2. Split concatenated "1.5mDisadvantage." entries
                --    where the structured reader collapsed two
                --    XAML elements into one rendered string.
                -- 3. Pass everything else through with its
                --    original typeId preserved.
                local processedTexts = {}
                local entryCount = #tooltipTexts
                local entryIndex = 1
                while entryIndex <= entryCount do
                    local tooltipEntry = tooltipTexts[entryIndex]
                    local entryText = tooltipEntry.text
                    if not entryText then
                        entryIndex = entryIndex + 1
                        goto nextRawEntry
                    end
                    -- CostTemplateRoot Value+Name pair: combine.
                    if tooltipEntry.parentRole == "CostTemplateRoot"
                        and tooltipEntry.role == "Value" then
                        local nextEntry = tooltipTexts[entryIndex + 1]
                        if nextEntry
                            and nextEntry.parentRole
                                == "CostTemplateRoot"
                            and nextEntry.role == "Name"
                            and nextEntry.text then
                            processedTexts[#processedTexts + 1] = {
                                text = entryText .. " "
                                    .. nextEntry.text,
                                typeId = "CostPair",
                            }
                            entryIndex = entryIndex + 2
                            goto nextRawEntry
                        end
                    end
                    -- Concatenated split: "1.5mDisadvantage." etc.
                    local range, rest = entryText:match(
                        "^([%d%.]+m)(.+)$")
                    if range and rest then
                        processedTexts[#processedTexts + 1] =
                            {text = range, typeId = nil}
                        processedTexts[#processedTexts + 1] =
                            {text = rest, typeId = nil}
                    else
                        processedTexts[#processedTexts + 1] =
                            {text = entryText,
                             typeId = tooltipEntry.typeId}
                    end
                    entryIndex = entryIndex + 1
                    ::nextRawEntry::
                end

                for _, processedEntry in ipairs(processedTexts) do
                    local rawText = processedEntry.text
                    local entryTypeId = processedEntry.typeId
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
                        speechData:AddProperty("Damage",
                            damageMin .. " to " .. damageMax,
                            "brief")
                        goto nextTT
                    end

                    -- Healing range: "4~10 Healing".
                    local healMin, healMax = cleaned:match(
                        "^(%d+)~(%d+)%s*[Hh]ealing")
                    if healMin then
                        speechData:AddProperty("Healing",
                            healMin .. " to " .. healMax, "brief")
                        goto nextTT
                    end

                    -- Dice notation: "1d6+3" (main roll) or
                    -- "+1d6" / "-1d4" (bonus dice, leading sign).
                    if cleaned:match(
                        "^[%+%-]?%d*d%d+[%+%-]?%d*$") then
                        if cleaned:match("^[%+%-]") then
                            speechData:AddProperty("Bonus dice",
                                cleaned, "verbose")
                        else
                            speechData:AddProperty("Dice",
                                cleaned, "verbose")
                        end
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
                            speechData:AddProperty("Damage type",
                                cleaned, "normal")
                            goto nextTT
                        end
                    end

                    -- Cost: just the action type as the value.  The
                    -- "Cost" label already carries the "this is what
                    -- it costs" meaning, so packing "Costs " into the
                    -- value duplicates the word.
                    if cleaned == "Action"
                        or cleaned == "Bonus Action"
                        or cleaned == "Reaction" then
                        speechData:AddProperty("Cost",
                            cleaned, "verbose")
                        goto nextTT
                    end

                    -- Use limits split into two semantic categories
                    -- with their own toggles:
                    --
                    --   * Frequency (gated by speakFrequency):
                    --     per-turn caps.  Speech: "Frequency: Once
                    --     per turn".
                    --   * Recharges (gated by speakRecharge):
                    --     rest-cycle reset triggers.  Speech:
                    --     "Recharges: on Short Rest" -- the screen
                    --     reader treats the colon as a brief pause,
                    --     so this reads close to "Recharges on
                    --     Short Rest" without needing empty-label
                    --     gymnastics.
                    if cleaned == "Per turn" then
                        speechData:AddProperty("Frequency",
                            "Once per turn", "verbose")
                        goto nextTT
                    end
                    if cleaned == "Short Rest"
                        or cleaned == "Long Rest" then
                        speechData:AddProperty("Recharges",
                            "on " .. cleaned, "verbose")
                        goto nextTT
                    end

                    -- Duration: just the turn count as the value.
                    -- Label = "Duration" carries the "for how long"
                    -- meaning; packing "Duration " into the value
                    -- duplicates.
                    if cleaned:match("^%d+ turns?$") then
                        speechData:AddProperty("Duration",
                            cleaned, "normal")
                        goto nextTT
                    end

                    -- Attack type: the value names the mechanism
                    -- (Attack Roll vs Saving Throw).  These are
                    -- canonical D&D phrases that don't read as
                    -- redundant against the "Attack type" label.
                    if cleaned == "Attack Roll"
                        or cleaned == "Saving Throw" then
                        speechData:AddProperty("Attack type",
                            cleaned, "verbose")
                        goto nextTT
                    end

                    -- Save type: just the ability abbreviation as
                    -- the value (CON, DEX, etc.).  Label = "Save
                    -- type" already conveys "this is the save
                    -- triggered"; appending " Save" to the value
                    -- duplicates the word.
                    local saveAbility = cleaned:match(
                        "^(%u+) Save$")
                    if saveAbility then
                        speechData:AddProperty("Save type",
                            saveAbility, "verbose")
                        goto nextTT
                    end

                    -- CostPair: synthetic entry from
                    -- CostTemplateRoot Value+Name pair (e.g.
                    -- "3m Movement Speed").  The first token is
                    -- the cost amount, the rest is the resource
                    -- name.  Speak as a labeled property whose
                    -- label IS the resource name and value IS
                    -- the amount, e.g. "Movement Speed: 3m".
                    if entryTypeId == "CostPair" then
                        local costAmount, costName = cleaned:match(
                            "^(%S+)%s+(.+)$")
                        if costAmount and costName then
                            speechData:AddProperty(costName,
                                costAmount, "verbose")
                        end
                        goto nextTT
                    end
                    -- Range / radius / zone: the value is a distance
                    -- ("Melee" or "6m" or "30ft").  Require an
                    -- explicit typeId to label as a distance --
                    -- this prevents distance-shaped values that are
                    -- actually OTHER costs (Jump's "3m" movement
                    -- cost from CostTemplateRoot) from being
                    -- mislabeled as "Range".  The CostPair branch
                    -- above catches those before we reach here.
                    -- Unknown typeId values fall through to the
                    -- generic non-empty-role property emitter at
                    -- the bottom of this matcher.
                    local distanceLabel = nil
                    if entryTypeId == "Range" then
                        distanceLabel = "Range"
                    elseif entryTypeId == "ZoneRadius" then
                        distanceLabel = "Zone radius"
                    elseif entryTypeId == "Radius" then
                        distanceLabel = "Radius"
                    end
                    if distanceLabel then
                        local isMeleeMode = (cleaned == "Melee")
                        local isDistance = isMeleeMode
                            or cleaned:match("^[%d%.]+%s?m$")
                            or cleaned:match("^[%d%.]+%s?ft$")
                            or cleaned:match("^[%d%.]+%s?feet$")
                            or cleaned:match("^%d+ft$")
                        if isDistance then
                            speechData:AddProperty(distanceLabel,
                                cleaned, "normal")
                            goto nextTT
                        end
                    end

                    -- Concentration: a binary flag.  "Yes" reads
                    -- naturally with the "Concentration" label
                    -- ("Concentration: Yes") and avoids the
                    -- self-referential "Concentration: Concentration"
                    -- the value used to produce.
                    if cleaned:lower() == "concentration" then
                        speechData:AddProperty("Concentration",
                            "Yes", "verbose")
                        goto nextTT
                    end

                    -- Warning.
                    if cleaned:match("^No .+ equipped%.$") then
                        local warning = cleaned:sub(1, -2)
                        speechData:Add("status",
                            warning, "brief")
                        goto nextTT
                    end

                    ::nextTT::
                end

                if next(speechData.coreFields) == nil
                    and #speechData.properties == 0 then
                    return nil
                end
                return speechData
            end

            -- VMPassive: standard tooltip mapping.
            if focusedDCType == "ls.VMPassive" then
                local speechData = SpeechData.FromTooltip(tooltipTexts)
                if next(speechData.coreFields) == nil
                    and #speechData.properties == 0 then
                    return nil
                end
                return speechData
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

                -- Healing range.
                if tooltipData.healingRange then
                    detailList[#detailList + 1] = {
                        label = "Healing",
                        value = tooltipData.healingRange}
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
