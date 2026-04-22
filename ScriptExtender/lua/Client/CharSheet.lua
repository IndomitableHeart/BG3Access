-- File: Client/CharSheet.lua
--
-- Character sheet / inventory panel handler for BG3Access.
--
-- Extracted from WorldUI.lua to isolate CharacterPanel-specific logic:
-- equipment slots, ability scores, stats, class display, experience bar,
-- option button polling, proficiency sections, and expander headers.
--
-- Uses the panel handler factory (CreatePanelHandler) from WorldUI.lua
-- and tooltip formatters from Helpers.lua.

local Log = BG3Access.Client.Log
local Helpers = BG3Access.Client.Helpers
local SpeechData = BG3Access.Client.SpeechData

-- ============================================================================
-- Constants
-- ============================================================================

-- Equipment slot type to user-friendly name mapping.
-- Keys are EEquipmentSlot enum labels from Noesis (used in XAML DataTriggers).
local EQUIPMENT_SLOT_NAMES = {
    ["Helmet"]            = "Head",
    ["Breast"]            = "Chest",
    ["Cloak"]             = "Cloak",
    ["MeleeMainHand"]     = "Melee Main Hand",
    ["MeleeOffHand"]      = "Melee Off Hand",
    ["RangedMainHand"]    = "Ranged Main Hand",
    ["RangedOffHand"]     = "Ranged Off Hand",
    ["Ring"]              = "Ring",
    ["Ring2"]             = "Ring 2",
    ["Boots"]             = "Boots",
    ["Gloves"]            = "Gloves",
    ["Amulet"]            = "Amulet",
    ["Underwear"]         = "Underwear",
    ["VanityBody"]        = "Vanity Body",
    ["VanityBoots"]       = "Vanity Boots",
    ["MusicalInstrument"] = "Musical Instrument",
    ["LightSource"]       = "Light Source",
    ["Wings"]             = "Wings",
    ["Horns"]             = "Horns",
    ["Overhead"]          = "Overhead",
    ["Max"]               = "Light Source",
    ["Sentinel"]          = "Light Source",
}

-- Layout container types whose x:Name is decorative.
local CONTAINER_ELEM_TYPES = {
    Grid = true, Border = true, StackPanel = true, Canvas = true,
    Panel = true, DockPanel = true, WrapPanel = true,
}

-- Equipment slot enum: number-string -> friendly name, built at load time.
local EQUIPMENT_SLOT_NUMBERS = {}
if Ext.Enums and Ext.Enums.StatsItemSlot then
    for enumKey, enumValue in pairs(Ext.Enums.StatsItemSlot) do
        if type(enumKey) == "number" then
            local label = tostring(enumValue)
            local displayName = EQUIPMENT_SLOT_NAMES[label] or label
            EQUIPMENT_SLOT_NUMBERS[tostring(enumKey)] = displayName
        end
    end
end

-- DC types that still need tooltip-deferred speech.
local TOOLTIP_DEFERRED_DC_TYPES = {
    ["ObservableCollection<T>"] = true,
}

-- Ability indices (0-based in entity, XAML names AbilityStat0..5).
local ABILITY_INDEX_TO_NAME = {
    [0] = "Strength",
    [1] = "Dexterity",
    [2] = "Constitution",
    [3] = "Intelligence",
    [4] = "Wisdom",
    [5] = "Charisma",
}

-- Component names used to find the active player character entity.
local PLAYER_COMPONENTS = {"ClientControl", "IsPlayer", "PlayerController"}

-- DiceSizeId enum -> face count, built at load time.
local DICE_SIZE_FACES = {}
if Ext.Enums and Ext.Enums.DiceSizeId then
    for enumKey, _ in pairs(Ext.Enums.DiceSizeId) do
        if type(enumKey) == "string" then
            local faces = tonumber(enumKey:match("^D(%d+)$"))
            if faces then
                DICE_SIZE_FACES[enumKey] = faces
            end
        end
    end
end

-- WeaponFlags masks for ability modifier calculation.
-- WeaponFlags is a C++ BITMASK (not enum).  Bitfield values use
-- __Value (double underscore) for the numeric, unlike enums which
-- use .Value.
local _cachedFinesseMask = nil
local function GetFinesseMask()
    if _cachedFinesseMask ~= nil then return _cachedFinesseMask end
    _cachedFinesseMask = 0
    pcall(function()
        if Ext.Enums and Ext.Enums.WeaponFlags then
            local finesse = Ext.Enums.WeaponFlags.Finesse
            if type(finesse) == "number" then
                _cachedFinesseMask = finesse
            elseif finesse then
                -- Bitfield value: __Value (double underscore).
                _cachedFinesseMask = finesse.__Value or 0
            end
        end
    end)
    Log.Info("GetFinesseMask: " .. tostring(_cachedFinesseMask))
    return _cachedFinesseMask
end
local WEAPON_FLAG_MELEE = 0
if Ext.Enums and Ext.Enums.WeaponFlags then
    for flagName, flagValue in pairs(Ext.Enums.WeaponFlags) do
        if type(flagName) == "string" then
            local numericValue = nil
            if type(flagValue) == "number" then
                numericValue = flagValue
            else
                pcall(function() numericValue = flagValue.Value end)
            end
            if numericValue then
                if flagName == "Finesse" then
                    WEAPON_FLAG_FINESSE = numericValue
                elseif flagName == "Range" then
                    WEAPON_FLAG_RANGE = numericValue
                elseif flagName == "Melee" then
                    WEAPON_FLAG_MELEE = numericValue
                end
            end
        end
    end
end

-- ============================================================================
-- Entity API helpers
-- ============================================================================

--- GetSelectedCharacterEntity: returns the entity for the character currently
--- displayed in the character sheet.
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

--- ResolveTranslatedStringValue: converts a BG3SE TranslatedString object
--- or plain string to a human-readable string.
--- @param value any  A string, TranslatedString userdata, or other value.
--- @return string|nil  Resolved text, or nil if unresolvable.
local function ResolveTranslatedStringValue(value)
    if not value then return nil end
    if type(value) == "string" then
        return Helpers.GetTranslatedStringIfHandle(value)
    end
    local handleStr = nil
    pcall(function()
        local handle = value.Handle
        if handle then
            handleStr = handle.Handle or tostring(handle)
        end
    end)
    if handleStr and type(handleStr) == "string" and handleStr ~= "" then
        local resolved = Helpers.GetTranslatedStringIfHandle(handleStr)
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    local rawStr = tostring(value)
    if rawStr and not rawStr:find("^TranslatedString")
        and not rawStr:find("^userdata") then
        return rawStr
    end
    return nil
end

--- ExtractEquipmentSlotName: resolve the slot name from dcProps or numeric fallback.
--- @param dcProps table|nil  DataContext properties of the equipment slot.
--- @param snapshot table  The full TickSnapshot (for tooltip fallback).
--- @return string  Human-readable slot name, or "Equipment Slot".
local function ExtractEquipmentSlotName(dcProps, snapshot)
    if dcProps then
        local slotType = dcProps.SlotType
        if slotType then
            local slotName = EQUIPMENT_SLOT_NAMES[slotType]
            if slotName then return slotName end
            local numericName = EQUIPMENT_SLOT_NUMBERS[tostring(slotType)]
            if numericName then return numericName end
            return tostring(slotType)
        end
    end
    if snapshot and snapshot.tooltipTexts then
        local firstTooltip = snapshot.tooltipTexts[1]
        if firstTooltip and firstTooltip.text
            and firstTooltip.text ~= "" then
            return firstTooltip.text
        end
    end
    return "Equipment Slot"
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

--- GetEquippedItemEntity: direct lookup of the item entity in a specific slot.
--- @param characterEntity userdata  The character entity.
--- @param slotIndex number  The StatsItemSlot enum value.
--- @return userdata|nil  The item entity, or nil if slot is empty.
local function GetEquippedItemEntity(characterEntity, slotIndex)
    local equipInventory = GetEquipmentInventory(characterEntity)
    if not equipInventory then return nil end

    local container = equipInventory.InventoryContainer
    if not container or not container.Items then return nil end

    local slotData = container.Items[slotIndex]
    if slotData and slotData.Item then
        return slotData.Item
    end
    return nil
end

--- ReadItemName: extracts display name from an item entity.
--- @param itemEntity userdata  The item entity.
--- @return string|nil  Human-readable item name, or nil.
local function ReadItemName(itemEntity)
    local displayName = itemEntity.DisplayName
    if displayName and displayName.Name then
        local resolved = ResolveTranslatedStringValue(displayName.Name)
        if resolved and resolved ~= "" then
            return resolved
        end
    end
    local dataComponent = itemEntity.Data
    if dataComponent and dataComponent.StatsId then
        return tostring(dataComponent.StatsId)
    end
    return nil
end

--- HasWeaponFlag: checks if a weapon properties bitfield has a specific flag.
--- @param weaponProps number  The WeaponProperties bitfield.
--- @param flagMask number  The flag mask to check.
--- @return boolean
local function HasWeaponFlag(weaponProps, flagMask)
    if not weaponProps or flagMask == 0 then return false end
    return weaponProps % (flagMask * 2) >= flagMask
end

--- ArmorType enum value -> weight class.
--- Values from Public/Shared/Stats/Generated/Structure/Base/ValueLists.txt:
---   None=0, Cloth=1, Padded=2, Leather=3, StuddedLeather=4,
---   Hide=5, ChainShirt=6, ScaleMail=7, BreastPlate=8, HalfPlate=9,
---   RingMail=10, ChainMail=11, Splint=12, Plate=13.
local ARMOR_TYPE_CATEGORY = {
    -- Light
    Cloth          = "Light Armour",
    Padded         = "Light Armour",
    Leather        = "Light Armour",
    StuddedLeather = "Light Armour",
    -- Medium
    Hide           = "Medium Armour",
    ChainShirt     = "Medium Armour",
    ScaleMail      = "Medium Armour",
    BreastPlate    = "Medium Armour",
    HalfPlate      = "Medium Armour",
    -- Heavy
    RingMail       = "Heavy Armour",
    ChainMail      = "Heavy Armour",
    Splint         = "Heavy Armour",
    Plate          = "Heavy Armour",
}


--- ReadItemCategory: derives a user-friendly category from the stat
--- entry's ArmorType field via Ext.Stats.Get.
---
--- For armor: reads Data.StatsId -> Ext.Stats.Get -> ArmorType enum.
--- For weapons: returns "Weapon".
--- @param itemEntity userdata  The item entity.
--- @return string|nil  Category like "Light Armour", or nil.
local function ReadItemCategory(itemEntity)
    -- Armor: component exists means it's armor or shield.
    local armor = itemEntity.Armor
    if armor then
        if armor.Shield then
            return "Shield"
        end
        -- Read ArmorType from the stat entry.
        local statsId = nil
        pcall(function()
            statsId = tostring(itemEntity.Data.StatsId)
        end)
        if statsId and statsId ~= "" then
            local statOk, statEntry = pcall(Ext.Stats.Get, statsId)
            if statOk and statEntry then
                local typeOk, armorType = pcall(function()
                    return statEntry.ArmorType
                end)
                if typeOk and armorType then
                    local armorTypeStr = tostring(armorType)
                    local category = ARMOR_TYPE_CATEGORY[armorTypeStr]
                    if category then
                        return category
                    end
                end
            end
        end
        return "Armour"
    end

    -- Weapon: component exists means it's a weapon.
    local weapon = itemEntity.Weapon
    if weapon then
        return "Weapon"
    end

    return nil
end

-- ============================================================================
-- Stat/ability/class formatting (API-first, TextBlock fallback)
-- ============================================================================

--- FormatAbilityFromAPI: reads ability score and modifier from entity Stats.
--- @param elemId string  The focused element's ID chain.
--- @param dcProps table|nil  DataContext properties.
--- @return string|nil  Formatted speech like "Strength: 16, modifier +3".
local function FormatAbilityFromAPI(elemId, dcProps)
    local abilityIndexStr = elemId:match("AbilityStat(%d)")
    if not abilityIndexStr then
        local readOk, textBlocks = pcall(Ext.UI.ReadFocusedTextBlocks)
        if readOk and textBlocks and #textBlocks > 0 then
            local labels = {}
            local values = {}
            for _, text in ipairs(textBlocks) do
                local cleaned = Helpers.StripMarkupTags(text)
                if cleaned and cleaned ~= "" then
                    if cleaned:match("^[%d%+%-]") then
                        values[#values + 1] = cleaned
                    else
                        labels[#labels + 1] = cleaned
                    end
                end
            end
            local resultParts = {}
            for _, label in ipairs(labels) do
                resultParts[#resultParts + 1] = label
            end
            for _, value in ipairs(values) do
                resultParts[#resultParts + 1] = value
            end
            if #resultParts > 0 then
                return table.concat(resultParts, ": ")
            end
        end
        return nil
    end

    local abilityIndex = tonumber(abilityIndexStr)
    local abilityName = ABILITY_INDEX_TO_NAME[abilityIndex]
    if not abilityName then return nil end

    local entity = GetSelectedCharacterEntity()
    if entity then
        local statsOk, statsComponent = pcall(function()
            return entity.Stats
        end)
        if statsOk and statsComponent then
            local luaIndex = abilityIndex + 1
            local abilitiesOk, abilities = pcall(function()
                return statsComponent.Abilities
            end)
            local modifiersOk, modifiers = pcall(function()
                return statsComponent.AbilityModifiers
            end)
            if abilitiesOk and abilities then
                local score = nil
                local modifier = nil
                local scoreOk, scoreVal = pcall(function()
                    return abilities[luaIndex]
                end)
                if scoreOk and scoreVal and type(scoreVal) == "number" then
                    score = scoreVal
                end
                if modifiersOk and modifiers then
                    local modOk, modVal = pcall(function()
                        return modifiers[luaIndex]
                    end)
                    if modOk and modVal and type(modVal) == "number" then
                        modifier = modVal
                    end
                end
                if score and not modifier then
                    modifier = math.floor((score - 10) / 2)
                end
                if score then
                    local modSign = modifier >= 0 and "+" or ""
                    return abilityName .. ": " .. tostring(score)
                        .. ", modifier " .. modSign .. tostring(modifier)
                end
            end
        end
    end

    if dcProps and dcProps.Value then
        local score = tonumber(dcProps.Value)
        if score then
            local modifier = math.floor((score - 10) / 2)
            local modSign = modifier >= 0 and "+" or ""
            return abilityName .. ": " .. tostring(score)
                .. ", modifier " .. modSign .. tostring(modifier)
        end
    end

    return abilityName
end

--- FormatStatFromTextBlocks: reads a stat's label and value from rendered
--- TextBlocks via C++ BFS.  Reorders so label comes before value.
--- @return string|nil  Formatted speech like "Hit Points: 10/10" or nil.
local function FormatStatFromTextBlocks()
    local readOk, textBlocks = pcall(Ext.UI.ReadFocusedTextBlocks)
    if not readOk or not textBlocks or #textBlocks == 0 then return nil end

    local labels = {}
    local values = {}
    for _, text in ipairs(textBlocks) do
        if text and text ~= "" then
            local cleaned = Helpers.StripMarkupTags(text)
            if cleaned and cleaned ~= "" then
                cleaned = cleaned:gsub("(%d+)~(%d+)", "%1 to %2")
                if cleaned:match("^[%d%+%-/]") then
                    values[#values + 1] = cleaned
                else
                    labels[#labels + 1] = cleaned
                end
            end
        end
    end

    local parts = {}
    for _, label in ipairs(labels) do
        parts[#parts + 1] = label
    end
    if #values > 0 then
        for valueIndex = 1, #values - 1 do
            if values[valueIndex]:sub(1, 1) == "/"
                and values[valueIndex + 1]:match("^%d") then
                values[valueIndex], values[valueIndex + 1] =
                    values[valueIndex + 1], values[valueIndex]
            end
        end
        local valueStr = ""
        for _, value in ipairs(values) do
            if value:sub(1, 1) == "/" then
                valueStr = valueStr .. value
            elseif valueStr == "" then
                valueStr = value
            else
                valueStr = valueStr .. " " .. value
            end
        end
        parts[#parts + 1] = valueStr
    end

    if #parts == 0 then return nil end
    return table.concat(parts, ": ")
end

--- FormatClassFromAPI: reads class name, subclass, and level from entity.
--- @return string|nil  Formatted speech like "Fighter 5, Battle Master".
local function FormatClassFromAPI()
    local entity = GetSelectedCharacterEntity()
    if entity then
        local classesOk, classesComponent = pcall(function()
            return entity.Classes
        end)
        if classesOk and classesComponent then
            local entriesOk, classEntries = pcall(function()
                return classesComponent.Classes
            end)
            if entriesOk and classEntries then
                local classParts = {}
                local iterateOk = pcall(function()
                    for entryIndex = 1, #classEntries do
                        local entry = classEntries[entryIndex]
                        if entry then
                            local className = nil
                            local subclassName = nil
                            local level = nil

                            if entry.ClassUUID then
                                local classData = Ext.StaticData.Get(
                                    tostring(entry.ClassUUID),
                                    "ClassDescription")
                                if classData and classData.Name then
                                    className = Helpers
                                        .GetTranslatedStringIfHandle(
                                            classData.Name)
                                end
                            end

                            if entry.SubClassUUID then
                                local subUuid = tostring(entry.SubClassUUID)
                                if subUuid ~= ""
                                    and subUuid ~= "00000000-0000-0000-0000-000000000000" then
                                    local subData = Ext.StaticData.Get(
                                        subUuid, "ClassDescription")
                                    if subData and subData.Name then
                                        subclassName = Helpers
                                            .GetTranslatedStringIfHandle(
                                                subData.Name)
                                    end
                                end
                            end

                            level = entry.Level

                            if className then
                                local part = className
                                if level then
                                    part = part .. " " .. tostring(level)
                                end
                                if subclassName then
                                    part = part .. ", " .. subclassName
                                end
                                classParts[#classParts + 1] = part
                            end
                        end
                    end
                end)
                if iterateOk and #classParts > 0 then
                    return table.concat(classParts, ". ")
                end
            end
        end
    end

    return FormatStatFromTextBlocks()
end

--- FormatExperienceBar: speaks level + XP from entity.
--- @return string|nil  Immediate speech like "Level 1. 0 of 300 XP".
local function FormatExperienceBar()
    local entity = GetSelectedCharacterEntity()
    if not entity then return nil end

    local parts = {}
    pcall(function()
        local level = entity.EocLevel.Level
        if level then
            parts[#parts + 1] = "Level " .. tostring(level)
        end
    end)

    pcall(function()
        local xpComponent = entity.Experience
        if not xpComponent then return end
        -- TotalExperience is the cumulative threshold for the next
        -- level; NextLevelExperience is the player's current total.
        -- Field names are counterintuitive but confirmed by testing.
        local currentXP = xpComponent.NextLevelExperience or 0
        local thresholdXP = xpComponent.TotalExperience or 0
        if thresholdXP > 0 then
            parts[#parts + 1] = tostring(currentXP)
                .. " of " .. tostring(thresholdXP) .. " XP"
        else
            parts[#parts + 1] = tostring(currentXP) .. " XP"
        end
    end)

    if #parts > 0 then return table.concat(parts, ". ") end
    return FormatStatFromTextBlocks()
end

-- ============================================================================
-- Equipment option buttons (INPC-driven value updates on A press)
-- ============================================================================

-- Equipment slot state for tooltip speech.
local equipmentSlotEmpty = false
local equipmentSlotName = nil
local equipmentItemName = nil
local equipmentTooltipShouldAppend = false

--- ReadOptionButtonText: read and format option button text via BFS.
--- Called on initial focus and on INPC-driven valueChanged events.
--- @return string|nil  Formatted text or nil.
local function ReadOptionButtonText()
    local readOk, buttonTexts = pcall(Ext.UI.ReadFocusedTextBlocks)
    if not readOk or not buttonTexts or #buttonTexts == 0 then return nil end
    local textParts = {}
    for _, text in ipairs(buttonTexts) do
        if text and text ~= "" then
            local cleaned = Helpers.StripMarkupTags(text)
            if cleaned and cleaned ~= "" then
                textParts[#textParts + 1] = cleaned
            end
        end
    end
    if #textParts == 0 then return nil end
    return table.concat(textParts, ": ")
end

-- ============================================================================
-- Detail view builders (RS Left virtual property list)
-- ============================================================================

--- HasDetailLabel: check if a label already exists in a detail list.
--- @param detailList table  Array of {label, value} entries.
--- @param targetLabel string  The label to look for.
--- @return boolean
local function HasDetailLabel(detailList, targetLabel)
    for entryIndex = 1, #detailList do
        if detailList[entryIndex].label == targetLabel then
            return true
        end
    end
    return false
end

--- ResolveDCPropString: extract a string from a dcProps value
--- that may be a plain string or a LocaString table with a .Str field.
--- @param propValue string|table|nil  The property value.
--- @return string|nil
local function ResolveDCPropString(propValue)
    if not propValue then return nil end
    if type(propValue) == "string" then
        if propValue == "" then return nil end
        return propValue
    end
    if type(propValue) == "table" then
        return propValue.Str or propValue.Text or propValue.Name or nil
    end
    return nil
end

--- ExtractItemFacts: extract all item-body facts from tooltip data
--- into a flat structured table that detail-view builders can convert
--- into {label, value} list entries.
---
--- The tooltip is the authoritative source for item-body facts --
--- all values here (damage, dice, AC, weight, gold, properties,
--- description, etc.) come from the game's own rendered tooltip, so
--- they already respect the user's unit/language/theme settings and
--- never disagree with what a sighted player sees.  Callers that
--- need non-item facts (character's ability modifier for dice,
--- identity fields like slot name) add those on top of the facts
--- returned here.
---
--- Returns a table of optional facts (all fields may be nil):
---   damageRange      -- "4 to 9"       (Range prop / damageDisplayText)
---   dice             -- "1d6+3"        (Damage prop, dice notation)
---   damageType       -- "Piercing"     (Damage type prop)
---   healing          -- "4 to 10"      (Amount prop / unroled "N~M Healing")
---   weaponProperties -- "Light, Finesse" (Property entries, itemName-deduped)
---   armorClass       -- "11"           (Armour Class prop / ArmorText)
---   category         -- "Light Armour" (Category prop / SubTitleContainer)
---   gold             -- "16"           (Gold prop / GoldContainer)
---   weight           -- "1.8"          (Weight prop / weightText, unit-aware)
---   description      -- "A common..."  (description core field, markup stripped)
---   effectDesc       -- short (10-80 char) unroled functional text
---   actionCost       -- "Bonus Action" (Cost prop or unroled marker)
---   singleUse        -- true if marker present
---
--- @param tooltipTexts table|nil  Structured {role,text} entries.
--- @param itemName string|nil  Item name, used to dedup Property
---   entries whose value just repeats the title.
--- @return table  Facts table (may be empty if tooltip missing).
local function ExtractItemFacts(tooltipTexts, itemName)
    local facts = {}
    if not tooltipTexts or #tooltipTexts == 0 then return facts end

    local speechData = SpeechData.FromTooltip(tooltipTexts)

    -- Description from the core field (ContentText / BaseDescription),
    -- markup stripped.
    if speechData.coreFields["description"] then
        facts.description = Helpers.StripMarkupTags(
            speechData.coreFields["description"])
    end

    -- Walk properties and map each known label to a fact field.
    -- Property entries collect separately and get itemName-deduped
    -- + joined at the end.
    local propertyValues = {}
    local itemNameLower = itemName and itemName:lower() or nil

    for _, prop in ipairs(speechData.properties) do
        local label = prop.label
        local value = prop.value
        if label == "Range" then
            facts.damageRange = value
        elseif label == "Damage" then
            -- Dice notation for weapons/potions -> dice; rare "N to M"
            -- form -> damageRange fallback.
            if value:match("^%d+d%d+[%+%-]?%d*$") then
                facts.dice = value
            elseif value:match("^%d+ to %d+") then
                facts.damageRange = facts.damageRange
                    or value:match("^(%d+ to %d+)")
            end
        elseif label == "Damage type" then
            facts.damageType = value
        elseif label == "Amount" then
            -- DamageRange role: value carries context word baked in
            -- ("4 to 10 Healing" or "4 to 9 Damage"); route to the
            -- appropriate fact based on the suffix.
            local healMatch = value:match("^(%d+ to %d+)%s*[Hh]ealing")
            if healMatch then
                facts.healing = facts.healing or healMatch
            else
                local rangeMatch = value:match("^(%d+ to %d+)")
                if rangeMatch then
                    facts.damageRange = facts.damageRange or rangeMatch
                end
            end
        elseif label == "Armour Class" then
            facts.armorClass = value
        elseif label == "Category" then
            facts.category = value
        elseif label == "Gold" then
            facts.gold = value
        elseif label == "Weight" then
            facts.weight = value
        elseif label == "Cost" then
            facts.actionCost = value
        elseif label == "Property" then
            if not (itemNameLower
                and value:lower() == itemNameLower) then
                propertyValues[#propertyValues + 1] = value
            end
        end
    end

    if #propertyValues > 0 then
        facts.weaponProperties = table.concat(propertyValues, ", ")
    end

    -- Unroled (empty-role) text extraction: singleUse marker, healing
    -- variant ("4~10 Healing" as raw text), action cost fallback,
    -- short effect description.
    for _, tooltipEntry in ipairs(tooltipTexts) do
        local role = tooltipEntry.role or ""
        if role ~= "" then goto nextUnroled end
        local cleaned = SpeechData.CleanTooltipText(tooltipEntry.text)
        if not cleaned then goto nextUnroled end
        local lowerCleaned = cleaned:lower()

        if itemNameLower and lowerCleaned == itemNameLower then
            goto nextUnroled
        end

        if lowerCleaned == "single use" then
            facts.singleUse = true
            goto nextUnroled
        end

        local healRange = cleaned:match("^(%d+~%d+)%s*[Hh]ealing")
        if healRange and not facts.healing then
            facts.healing = healRange:gsub("(%d+)~(%d+)", "%1 to %2")
            goto nextUnroled
        end

        if not facts.actionCost then
            if lowerCleaned == "bonus action"
                or lowerCleaned == "action"
                or lowerCleaned == "reaction" then
                facts.actionCost = cleaned
                goto nextUnroled
            end
        end

        if not facts.effectDesc
            and #cleaned > 10 and #cleaned < 80
            and not cleaned:find("^Proficiency with") then
            facts.effectDesc = cleaned
        end

        ::nextUnroled::
    end

    return facts
end

--- BuildVMItemDetailList: build detail list for inventory items.
--- Identity fields come from dcProps; all item-body facts (damage,
--- dice, AC, properties, weight, gold, description, etc.) come from
--- ExtractItemFacts which reads the tooltip (the same source the
--- sighted player sees, already unit-aware).  A small entity-side
--- fallback provides Category (proficiency group like "Shortswords")
--- for items whose tooltip has no Category role -- weapons don't
--- render SubTitleContainer.
---
--- @param dcProps table  DataContext properties from the focused VMItem.
--- @param tooltipTexts table|nil  Cached tooltip texts for the item.
--- @return table|nil  Array of {label, value}, or nil if empty.
local function BuildVMItemDetailList(dcProps, tooltipTexts)
    local detailList = {}
    local function addField(label, val)
        if val and val ~= "" then
            detailList[#detailList + 1] = {label = label, value = val}
        end
    end

    local itemName = ResolveDCPropString(
        dcProps.Name or dcProps.Text or dcProps.Title)
    local facts = ExtractItemFacts(tooltipTexts, itemName)

    -- Category: tooltip has it only for items with SubTitleContainer
    -- (armor).  Weapons carry the proficiency group on the entity
    -- stat entry, so fall back there, and fall back again to the
    -- generic dcProps.ItemType ("Equipment"/"Container").
    local category = facts.category
    if not category then
        local entityUUID = dcProps.EntityUUID
        if entityUUID and entityUUID ~= "" then
            pcall(function()
                local itemEntity = Ext.Entity.Get(entityUUID)
                if itemEntity then
                    category = ReadItemCategory(itemEntity)
                end
            end)
        end
    end
    if not category then
        local dcPropsCategory = dcProps.ItemType
        if dcPropsCategory and dcPropsCategory ~= "" then
            category = dcPropsCategory
        end
    end

    -- Identity block.
    addField("Name", itemName)
    local rarity = dcProps.Rarity
    if rarity and rarity ~= "" and rarity ~= "Common" then
        addField("Rarity", rarity)
    end
    addField("Category", category)

    local equippedProp = dcProps.Equipped
    if equippedProp and equippedProp ~= "" then
        addField("Status", (equippedProp == "NotEquipped")
            and "Not Equipped" or "Equipped")
    end

    -- "N available" format matches the radial slot speech for
    -- consistent count-announcement across contexts.
    local stackCount = dcProps.Count
    if stackCount and stackCount ~= "" and stackCount ~= "1" then
        addField("Count", tostring(stackCount) .. " available")
    end

    -- Combat/usage block (all tooltip-sourced).
    addField("Damage", facts.damageRange)
    addField("Dice", facts.dice)
    addField("Damage type", facts.damageType)
    addField("Healing", facts.healing)
    addField("Armor Class", facts.armorClass)
    addField("Properties", facts.weaponProperties)
    addField("Cost", facts.actionCost)
    if facts.singleUse then addField("Usage", "Single Use") end
    addField("Effect", facts.effectDesc)

    -- Economy block.
    if facts.gold then
        addField("Value", facts.gold .. " gold")
    else
        local dcGold = dcProps.Gold
        if dcGold and dcGold ~= "" and dcGold ~= "0" then
            addField("Value", dcGold .. " gold")
        end
    end
    addField("Weight", facts.weight)

    -- Description: tooltip flavor first, then dcProps fallback.
    local description = facts.description
    if not description then
        local dcPropsDescription = ResolveDCPropString(dcProps.Description)
        if dcPropsDescription and dcPropsDescription ~= "" then
            description = Helpers.StripMarkupTags(dcPropsDescription)
        end
    end
    addField("Description", description)

    return #detailList > 0 and detailList or nil
end

--- ResolveSlotIndex: convert a slot name (friendly) back to a numeric
--- slot index for entity inventory lookup.
--- @param slotName string  Friendly name from EQUIPMENT_SLOT_NAMES.
--- @return number|nil  Slot index, or nil if not found.
local function ResolveSlotIndex(slotName)
    if not slotName then return nil end
    -- Reverse lookup: friendly name -> enum label.
    local slotType = nil
    for enumLabel, friendlyName in pairs(EQUIPMENT_SLOT_NAMES) do
        if friendlyName == slotName then
            slotType = enumLabel
            break
        end
    end
    if not slotType then return nil end
    -- Enum label -> numeric index.
    if not Ext.Enums or not Ext.Enums.StatsItemSlot then return nil end
    local enumValue = Ext.Enums.StatsItemSlot[slotType]
    if type(enumValue) == "number" then return enumValue end
    if enumValue ~= nil then
        local indexOk, indexValue = pcall(function()
            return enumValue.Value
        end)
        if indexOk then return indexValue end
    end
    return nil
end

--- BuildEquipmentSlotDetailList: build detail list for an equipped
--- item.  Identity fields (slot, status, item name) come from dcProps;
--- all item-body facts (damage, dice, AC, properties, weight, gold,
--- description) come from ExtractItemFacts via the tooltip.  The only
--- genuinely entity-sourced fact is the ability-inference on the dice
--- roll ("from Dexterity") -- that's character data, not item data,
--- and lives here because it embellishes an item fact.  Category
--- falls back to entity (proficiency group) when tooltip has no role.
---
--- @param dcProps table  DataContext properties from the focused slot.
--- @param focusedData table  Full focused element data (not a snapshot).
--- @param tooltipTexts table|nil  Cached tooltip texts for the slot.
--- @return table|nil  Array of {label, value}, or nil if empty.
local function BuildEquipmentSlotDetailList(dcProps, focusedData, tooltipTexts)
    local slotName = ExtractEquipmentSlotName(dcProps, nil)

    -- Empty slot: just Slot + Status.
    local isEquipped = dcProps and dcProps.EquippedType
        and dcProps.EquippedType ~= "None"
        and dcProps.EquippedType ~= ""
    if not isEquipped then
        local emptyList = {}
        if slotName then
            emptyList[#emptyList + 1] = {label = "Slot", value = slotName}
        end
        emptyList[#emptyList + 1] = {label = "Status", value = "Empty"}
        return emptyList
    end

    local itemName = nil
    if type(dcProps.Item) == "table" then
        itemName = ResolveDCPropString(
            dcProps.Item.Name or dcProps.Item.DisplayName
            or dcProps.Item.Text)
    end

    local facts = ExtractItemFacts(tooltipTexts, itemName)

    -- Category fallback: tooltip has it only for SubTitleContainer
    -- items (armor).  Weapons carry proficiency group on the entity
    -- stat entry; look up if tooltip didn't cover it.
    local slotIndex = ResolveSlotIndex(slotName)
    local characterEntity = GetSelectedCharacterEntity()
    local category = facts.category
    if not category and slotIndex and characterEntity then
        pcall(function()
            local itemEntity = GetEquippedItemEntity(
                characterEntity, slotIndex)
            if itemEntity then
                category = ReadItemCategory(itemEntity)
            end
        end)
    end

    -- Dice roll: tooltip gives the raw notation ("1d6+3"); format as
    -- "1d6, +3 from Dexterity" with ability-inference from the
    -- character.  Ability-inference is character data, not item, so
    -- it stays in this builder instead of ExtractItemFacts.
    local rollField = nil
    if facts.dice then
        local rollValue = facts.dice:gsub(
            "(%d+d%d+)([%+%-])", "%1, %2")
        if characterEntity then
            pcall(function()
                local statsComponent = characterEntity.Stats
                if not statsComponent then return end

                -- Determine which ability drives this weapon's damage.
                -- All paths set abilityName directly (string) using
                -- enum labels -- no hardcoded indices.
                local abilityName = nil

                -- Check for ability override boost (Hexblade etc.).
                pcall(function()
                    local overrideBoost = characterEntity
                        .WeaponAttackRollAbilityOverride
                    if overrideBoost and overrideBoost.Ability then
                        local overrideLabel = tostring(
                            overrideBoost.Ability)
                        if overrideLabel == "SpellCastingAbility" then
                            abilityName = tostring(
                                statsComponent.SpellCastingAbility)
                        elseif overrideLabel ~= "None"
                            and overrideLabel ~= "WeaponAttackAbility" then
                            abilityName = overrideLabel
                        end
                    end
                end)

                -- No override: determine from slot type + weapon.
                if not abilityName or abilityName == "None" then
                    abilityName = nil
                    local isRanged = slotName
                        and slotName:find("Ranged")
                    if isRanged then
                        -- Use entity's RangedAttackAbility (enum).
                        local rangedAbility = statsComponent
                            .RangedAttackAbility
                        if rangedAbility then
                            abilityName = tostring(rangedAbility)
                        end
                    else
                        -- Melee: check Finesse on the item entity.
                        local isFinesse = false
                        local finesseMask = GetFinesseMask()
                        if finesseMask > 0 then
                            pcall(function()
                                local slotIdx = ResolveSlotIndex(
                                    slotName)
                                local itemEntity =
                                    GetEquippedItemEntity(
                                        characterEntity, slotIdx)
                                if itemEntity
                                    and itemEntity.Weapon then
                                    local weaponFlags = itemEntity
                                        .Weapon.WeaponProperties
                                    if weaponFlags
                                        and weaponFlags ~= 0 then
                                        isFinesse = HasWeaponFlag(
                                            weaponFlags, finesseMask)
                                    end
                                end
                            end)
                        end
                        if isFinesse then
                            -- Finesse: use higher modifier of Str/Dex.
                            -- AbilityId enum is 0-based (matching C++
                            -- array index); Lua array is 1-indexed,
                            -- so add 1 to convert.
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
                            abilityName = Ext.Enums.AbilityId
                                .Strength.Label
                        end
                    end
                end

                if abilityName and abilityName ~= "None" then
                    rollValue = rollValue .. " from " .. abilityName
                end
            end)
        end
        rollField = rollValue
    end

    -- Assemble in final display order.  Each Damage / Dice / Damage
    -- type / Property etc. is its own d-pad entry.
    local detailList = {}
    local function addField(label, val)
        if val and val ~= "" then
            detailList[#detailList + 1] = {label = label, value = val}
        end
    end
    addField("Slot", slotName)
    addField("Name", itemName)
    addField("Category", category)
    addField("Damage", facts.damageRange)
    addField("Dice", rollField)
    addField("Damage type", facts.damageType)
    addField("Healing", facts.healing)
    addField("Properties", facts.weaponProperties)
    addField("Armor Class", facts.armorClass)
    addField("Cost", facts.actionCost)
    if facts.singleUse then addField("Usage", "Single Use") end
    addField("Effect", facts.effectDesc)
    addField("Value", facts.gold and (facts.gold .. " gold") or nil)
    addField("Weight", facts.weight)
    addField("Description", facts.description)

    return #detailList > 0 and detailList or nil
end

--- BuildAbilityDetailList: build detail list for ability scores.
--- @param elemId string  The focused element's ID chain.
--- @param dcProps table|nil  DataContext properties.
--- @return table|nil  Array of {label, value}, or nil if empty.
local function BuildAbilityDetailList(elemId, dcProps)
    local abilityIndexStr = elemId and elemId:match("AbilityStat(%d)")
    if not abilityIndexStr then return nil end

    local abilityIndex = tonumber(abilityIndexStr)
    local abilityName = ABILITY_INDEX_TO_NAME[abilityIndex]
    if not abilityName then return nil end

    local detailList = {}
    detailList[#detailList + 1] = {label = "Ability", value = abilityName}

    -- Get score and modifier from entity.
    local entity = GetSelectedCharacterEntity()
    if entity then
        pcall(function()
            local statsComponent = entity.Stats
            if not statsComponent then return end
            local abilities = statsComponent.Abilities
            if not abilities then return end
            -- Abilities are 0-indexed in the entity but 1-indexed in
            -- the Lua array (BG3SE converts).  Ability enum starts at 1
            -- (Strength=1, ..., Charisma=6).
            local score = abilities[abilityIndex + 1]
            if score then
                detailList[#detailList + 1] = {
                    label = "Score", value = tostring(score)}
                local modifier = math.floor((score - 10) / 2)
                local modifierSign = modifier >= 0 and "+" or ""
                detailList[#detailList + 1] = {
                    label = "Modifier",
                    value = modifierSign .. tostring(modifier),
                }
            end
        end)
    end

    return #detailList > 0 and detailList or nil
end

-- ============================================================================
-- Per-DC-type tooltip formatters
-- ============================================================================
-- Each formatter takes the raw tooltip data and spokenRoles cross-off
-- set, returns a SpeechData or nil.  The TOOLTIP_FORMATTERS dispatch
-- table below maps focused DC type -> formatter.  Adding new item
-- types means adding a named formatter and one line to the table,
-- not growing a monolithic customTooltipFn.

--- Item-shaped tooltips: inventory VMItem entries AND equipment-
--- slot VMEquipmentSlot entries (when the slot is populated, its
--- tooltip content is identical in shape to an inventory item's).
--- Drops armorDisplay (redundant static label), dedupes armor
--- Category against PropertyText, relabels dice-notation Damage ->
--- Dice (potions), promotes "Single Use" marker from empty role to
--- a Usage property, collapses the weapon-property trio into a
--- single "Weapon properties" line, and combines Range + dice +
--- type into a prose Damage phrase.
local function FormatItemTooltip(tooltipTexts, spokenRoles)
    local speechData = SpeechData.FromTooltip(tooltipTexts, spokenRoles)
    speechData:RemoveProperty("armorDisplay")

    -- Extract the raw title text directly from tooltipTexts (NOT
    -- from speechData.coreFields.name, which is nil when the caller
    -- passed spokenRoles = {name=true} to suppress title speech --
    -- e.g. equipment-slot tooltips where the handler already spoke
    -- the item name).  Used to dedup Property entries whose value
    -- just repeats the item name.
    local itemTitle = nil
    for _, entry in ipairs(tooltipTexts) do
        if entry.role == "Title" and entry.text then
            itemTitle = SpeechData.CleanTooltipText(entry.text)
            break
        end
    end

    -- Dedup: armor tooltips duplicate "Light Armour" across
    -- SubTitleContainer (-> Category) and PropertyText.
    local categoryValue = nil
    for _, prop in ipairs(speechData.properties) do
        if prop.label == "Category" then
            categoryValue = prop.value
            break
        end
    end
    if categoryValue then
        speechData:RemoveProperties(function(prop)
            return prop.label == "Property"
                and prop.value == categoryValue
        end)
    end

    -- "Single Use" is an empty-role text marker; promote to Usage.
    for _, entry in ipairs(tooltipTexts) do
        local role = entry.role or ""
        if role == "" and entry.text
            and SpeechData.CleanTooltipText(entry.text)
                == "Single Use" then
            speechData:AddProperty("Usage", "Single Use", "brief")
            break
        end
    end

    -- Collapse weapon-property entries into a single "Weapon
    -- properties: Light, Finesse" line, dropping any Property
    -- whose value duplicates the item name (e.g. a Shortsword has
    -- "Property: Shortsword" that just repeats the title).
    SpeechData.CollapseProperties(
        speechData, "Property", "Weapon properties",
        itemTitle, "normal")

    -- Combine Range + dice-notation Damage + Damage type into a
    -- single prose Damage phrase that mirrors the sighted tooltip
    -- hierarchy ("4~9 Damage" as headline, 1d6+3 Piercing as detail):
    --   "Damage: 4 to 9, 1d6+3, type piercing"
    -- Must run BEFORE the potion dice-relabel below, otherwise the
    -- relabel consumes the Damage property this combining needs.
    local rangeValue = nil
    local damageValue = nil
    local damageTypeValue = nil
    for _, prop in ipairs(speechData.properties) do
        if prop.label == "Range" then
            rangeValue = prop.value
        elseif prop.label == "Damage" then
            damageValue = prop.value
        elseif prop.label == "Damage type" then
            damageTypeValue = prop.value
        end
    end
    -- Only combine when we have at least two parts -- a bare Damage
    -- entry with no Range and no type is a potion (handled below).
    local weaponPartCount = (rangeValue and 1 or 0)
        + (damageValue and 1 or 0)
        + (damageTypeValue and 1 or 0)
    if weaponPartCount >= 2 then
        local parts = {}
        if rangeValue     then parts[#parts + 1] = rangeValue end
        if damageValue    then parts[#parts + 1] = damageValue end
        if damageTypeValue then
            parts[#parts + 1] = "type " .. damageTypeValue:lower()
        end
        speechData:RemoveProperty("Range")
        speechData:RemoveProperty("Damage type")
        speechData:RemoveProperties(function(prop)
            return prop.label == "Damage"
        end)
        speechData:AddProperty(
            "Damage", table.concat(parts, ", "), "normal")
    end

    -- Potions/scrolls/consumables: relabel orphan Damage dice to
    -- Dice via the shared helper (same logic used by
    -- SpeakInspectData for the inspect-widget overview).
    SpeechData.RelabelOrphanDamageDice(speechData)

    return speechData
end

--- VMStat / VMRangeStat: derived stats with breakdowns (HP, AC,
--- Initiative, Movement, Melee Attack Bonus, etc.).  Stat tooltips
--- use paired Value+Description entries for the breakdown; the
--- shared ParseValueDescriptionBreakdown helper turns them into a
--- single "Breakdown" property and captures any real description.
--- Stat tooltips that don't name their body TextBlock also have
--- their description promoted from empty-role text as a fallback.
local function FormatVMStatTooltip(tooltipTexts, spokenRoles)
    local speechData = SpeechData.FromTooltip(tooltipTexts, spokenRoles)
    speechData:RelabelProperty("Property", "Breakdown")
    speechData:RemoveProperty("TitleValue")
    speechData:RemoveProperty("ShortText")
    speechData:RemoveProperty("AC")
    SpeechData.ParseValueDescriptionBreakdown(
        speechData, tooltipTexts)
    SpeechData.PromoteEmptyRoleDescription(
        speechData, tooltipTexts, 30)
    return speechData
end

--- VMCharacterStats: combat stats (Melee Damage row).  Shape
--- differs from VMStat: a sequence of Description entries forms
--- the breakdown ("Melee Attack. Total Damage 1d6+3. Shortsword
--- 1d6 Piercing. Dexterity"), followed by an additionSign /
--- statValue pair that appends to the last Description (e.g.
--- "Dexterity +3").  Assemble the full sequence as description.
local function FormatVMCharacterStatsTooltip(tooltipTexts, spokenRoles)
    local speechData = SpeechData.FromTooltip(tooltipTexts, spokenRoles)
    local descriptions = {}
    local additionSign = nil
    local statValue = nil
    for _, entry in ipairs(tooltipTexts) do
        local role = entry.role or ""
        local text = SpeechData.CleanTooltipText(entry.text)
        if text then
            if role == "Description" then
                descriptions[#descriptions + 1] = text
            elseif role == "additionSign" then
                additionSign = text
            elseif role == "statValue" then
                statValue = text
            end
        end
    end
    if additionSign and statValue and #descriptions > 0 then
        descriptions[#descriptions] =
            descriptions[#descriptions]
            .. " " .. additionSign .. statValue
    end
    if #descriptions > 0 then
        speechData:Add("description",
            table.concat(descriptions, ". "), "verbose")
    end
    speechData:RemoveProperty("additionSign")
    speechData:RemoveProperty("statValue")
    return speechData
end

--- VMAbility / VMSkill / VMEquipmentProficiency: ability and skill
--- rows.  Relabels "Property" to "Effect" (these are effect text,
--- not generic properties), drops the redundant TitleValue.
--- Ability tooltips use the same paired Value+Description breakdown
--- as stat tooltips (e.g. Base 15, +2 from Class), with a real
--- description as the FIRST Description entry before any Value.
local function FormatVMAbilityTooltip(tooltipTexts, spokenRoles)
    local speechData = SpeechData.FromTooltip(tooltipTexts, spokenRoles)
    speechData:RelabelProperty("Property", "Effect")
    speechData:RemoveProperty("TitleValue")
    SpeechData.ParseValueDescriptionBreakdown(
        speechData, tooltipTexts)
    return speechData
end

--- VMClass / ls.Character / deferred DC types: generic tooltips
--- with no special handling beyond the universal role mapping.
local function FormatGenericTooltip(tooltipTexts, spokenRoles)
    return SpeechData.FromTooltip(tooltipTexts, spokenRoles)
end

--- Dispatch table: focused DC type -> formatter function.  Adding
--- a new tooltip-bearing DC type means adding an entry here; the
--- customTooltipFn below stays unchanged.
local TOOLTIP_FORMATTERS = {
    ["ls.VMItem"]                  = FormatItemTooltip,
    -- Equipment slot tooltip when slot is populated IS an item
    -- tooltip (same roles, same layout); reuse the item formatter.
    ["ls.VMEquipmentSlot"]         = FormatItemTooltip,
    ["ls.VMStat"]                  = FormatVMStatTooltip,
    ["ls.VMRangeStat"]             = FormatVMStatTooltip,
    ["gui::VMCharacterStats"]      = FormatVMCharacterStatsTooltip,
    ["ls.VMAbility"]               = FormatVMAbilityTooltip,
    ["ls.VMSkill"]                 = FormatVMAbilityTooltip,
    ["gui::VMEquipmentProficiency"] = FormatVMAbilityTooltip,
    ["ls.VMClass"]                 = FormatGenericTooltip,
    ["ls.Character"]               = FormatGenericTooltip,
}

-- ============================================================================
-- CharacterPanelHandler: created via WorldUI.CreatePanelHandler
-- ============================================================================

--- CreateCharacterPanelHandler: builds the handler using the factory from
--- WorldUI.  Called once during module init after WorldUI is loaded.
--- @param createPanelHandler function  WorldUI.CreatePanelHandler factory.
--- @return table  The handler instance + equipment state accessors.
local function CreateCharacterPanelHandler(createPanelHandler)

    local handler = createPanelHandler({
        name = "CharacterPanel",
        hint = "Use bumpers to switch tabs. Up and down to navigate items.",
        onReset = function(handlerState)
            -- No polling state to clean up; INPC drives option button updates.
        end,
        customItemFn = function(focusedElement, handlerState, snapshot)
            local dcType = focusedElement.dcType
            local dcProps = focusedElement.dcProps
            local elemId = focusedElement.elemId or ""

            -- Reset equipment slot state on every focus change.
            equipmentSlotEmpty = false
            equipmentSlotName = nil
            equipmentItemName = nil
            equipmentTooltipShouldAppend = false

            local isOptionButton = elemId:match("Button::(%w+Option)")

            -- Widget navigation fake elements are actually empty
            -- equipment/inventory slots.  A sighted check confirmed
            -- these are gaps in the slot grid, not pure navigation
            -- scaffolding.  Announce them so blind users know they've
            -- landed on a real (but empty) slot rather than thinking
            -- the mod has gone silent.
            if elemId:find("WidgetNavigationPrimaryFakeElement")
                or elemId:find("WidgetNavigationSecondaryFakeElement") then
                return "Empty slot", nil, nil
            end

            -- Tab ListBoxItem: suppress as item.
            if elemId:find("^ListBoxItem::Tab") then
                return "", nil, nil
            end

            -- Equipment option buttons (Y menu).
            -- INPC fires on the button's DataContext when the user presses A,
            -- so the isValueOnly path in HandleSnapshot re-invokes customItemFn
            -- with the updated text.  No polling timer needed.
            if isOptionButton then
                local buttonText = ReadOptionButtonText()
                if buttonText then
                    return buttonText, nil, nil
                end
                local label = isOptionButton:gsub("Option$", "")
                    :gsub("(%l)(%u)", "%1 %2")
                return label, nil, nil
            end

            -- Inventory items: identity-only focus speech (name, equipped
            -- state, stack count).  Everything else -- description,
            -- weapon properties, weight, gold, armor class, damage --
            -- comes from the tooltip pipeline via FormatItemTooltip.
            -- Tooltip is the single source of truth; when the user
            -- toggles tooltips off (R3 short-press), focus speech stays
            -- but extra data goes silent, matching the visual behavior.
            if dcType == "ls.VMItem" and dcProps then
                local itemName = dcProps.Name or dcProps.Text
                    or dcProps.Title
                if type(itemName) == "table" then
                    itemName = itemName.Str or itemName.Text
                        or itemName.Name or nil
                end
                if itemName and itemName ~= "" then
                    local speechData = SpeechData.Create()
                    speechData:Add("name", itemName, "brief")
                    local equippedProp = dcProps.Equipped
                    if equippedProp and equippedProp ~= ""
                        and equippedProp ~= "NotEquipped" then
                        speechData:Add("state", "Equipped", "brief")
                    end
                    -- Stack count via the dedicated `count` core
                    -- field.  Same slot, same phrasing everywhere
                    -- quantity appears (radial, inventory, loot,
                    -- trade, containers).
                    local stackCount = dcProps.Count
                    if stackCount and stackCount ~= ""
                        and stackCount ~= "0" and stackCount ~= "1" then
                        speechData:Add("count",
                            tostring(stackCount) .. " available",
                            "normal")
                    end
                    return speechData
                end
            end

            -- Passive features (Darkvision, Fey Ancestry, etc.).
            if dcType == "ls.VMPassive" and dcProps then
                local passiveName = dcProps.Text or dcProps.Name
                if passiveName and passiveName ~= "" then
                    local apiDesc = Helpers.LookupFeatureDescription(passiveName)
                    if apiDesc then
                        return passiveName, nil, apiDesc
                    end
                end
            end

            -- Equipment slot: entity API reads slot name + item name + stats.
            if dcType == "ls.VMEquipmentSlot" then
                local slotName = ExtractEquipmentSlotName(dcProps, snapshot)
                local isEquipped = dcProps and dcProps.EquippedType
                    and dcProps.EquippedType ~= "None"
                    and dcProps.EquippedType ~= ""

                if not isEquipped then
                    equipmentSlotEmpty = true
                    return slotName .. ": Empty", nil, nil
                end

                equipmentSlotEmpty = false
                equipmentSlotName = slotName
                if type(dcProps.Item) == "table" then
                    equipmentItemName = ResolveTranslatedStringValue(
                        dcProps.Item.Name or dcProps.Item.DisplayName
                        or dcProps.Item.Text)
                end
                equipmentTooltipShouldAppend = true
                local immediateText = slotName
                if equipmentItemName and equipmentItemName ~= ""
                    and equipmentItemName ~= slotName then
                    immediateText = slotName .. ": " .. equipmentItemName
                end
                return immediateText, nil, nil
            end

            -- Ability scores: API-first via entity Stats component.
            if dcType == "ls.VMAbility" then
                local abilitySpeech = FormatAbilityFromAPI(elemId, dcProps)
                if abilitySpeech then
                    return abilitySpeech, nil, nil
                end
                return "", nil, nil
            end

            -- Stats (Health, AC, Movement, Initiative, Attack Bonus).
            if dcType == "ls.VMStat" or dcType == "ls.VMRangeStat" then
                local statSpeech = FormatStatFromTextBlocks()
                if statSpeech then
                    local ancestorContext = focusedElement.ancestorContext
                    if ancestorContext then
                        statSpeech = ancestorContext .. " " .. statSpeech
                    end
                    return statSpeech, nil, nil
                end
                return "", nil, nil
            end

            -- Combat stats panel.
            if dcType == "gui::VMCharacterStats" then
                local statSpeech = FormatStatFromTextBlocks()
                if statSpeech then
                    return statSpeech, nil, nil
                end
                return "", nil, nil
            end

            -- Class display.
            if dcType == "ls.VMClass" then
                local classSpeech = FormatClassFromAPI()
                if classSpeech then
                    return classSpeech, nil, nil
                end
                return "", nil, nil
            end

            -- Proficiency items (skills, weapons, armours).
            if dcType == "ls.VMSkill"
                or dcType == "gui::VMEquipmentProficiency" then
                local proficiencySpeech = FormatStatFromTextBlocks()
                if proficiencySpeech then
                    return proficiencySpeech, nil, nil
                end
                return "", nil, nil
            end

            -- Expander buttons: section headers.
            if elemId:find("ExpanderButton") then
                local readOk, headerTexts = pcall(
                    Ext.UI.ReadFocusedTextBlocks)
                if readOk and headerTexts and #headerTexts > 0 then
                    local headerName = Helpers.StripMarkupTags(headerTexts[1])
                    if not headerName or headerName == "" then
                        return "", nil, nil
                    end
                    -- Inventory header: name + gold + weight.
                    if dcType == "ls.Character"
                        and #headerTexts >= 2 then
                        local speechData = SpeechData.Create()
                        speechData:Add("name", headerName, "brief")
                        local extras = {}
                        for textIndex = 2, #headerTexts do
                            local cleaned = Helpers.StripMarkupTags(
                                headerTexts[textIndex])
                            if cleaned and cleaned ~= ""
                                and cleaned ~= "/" then
                                extras[#extras + 1] = cleaned
                            end
                        end
                        if #extras >= 1 then
                            speechData:AddProperty("Gold",
                                extras[1], "normal")
                        end
                        if #extras >= 2 then
                            local weightText = extras[2]
                            if #extras >= 3 then
                                weightText = extras[2] .. " of "
                                    .. extras[3]
                            else
                                weightText = weightText:gsub(
                                    "%s*/%s*", " of ")
                            end
                            speechData:AddProperty("Weight",
                                weightText, "normal")
                        end
                        return speechData:Format(), nil, nil
                    end
                    -- Section header with optional count and item list.
                    -- BFS may return separator chars (",", ":") as separate
                    -- entries.  Filter those and join items with commas.
                    if #headerTexts >= 2 then
                        local extraItems = {}
                        for textIndex = 2, #headerTexts do
                            local extra = Helpers.StripMarkupTags(
                                headerTexts[textIndex])
                            if extra and extra ~= ""
                                and extra ~= "," and extra ~= ":"
                                and extra ~= "/" then
                                extraItems[#extraItems + 1] = extra
                            end
                        end
                        if #extraItems > 0 then
                            headerName = headerName .. ": "
                                .. table.concat(extraItems, ", ")
                        end
                    end
                    -- Expanded/collapsed state.
                    local isChecked = focusedElement.isChecked
                    if isChecked == true then
                        headerName = headerName .. ", expanded"
                    elseif isChecked == false then
                        headerName = headerName .. ", collapsed"
                    end
                    return headerName, nil, nil
                end
                return "", nil, nil
            end

            -- ls.Character DC elements.
            if dcType == "ls.Character" then
                -- Empty slot navigation anchors.
                if elemId:find("FakeElement") then
                    return "Empty slot", nil, nil
                end
                -- Experience bar.
                if elemId:find("ExperienceBarRoot") then
                    local xpSpeech = FormatExperienceBar()
                    if xpSpeech then
                        return xpSpeech, nil, nil
                    end
                end
                -- Character info entries (race, background, deity).
                if elemId:find("EntryRoot") then
                    local infoSpeech = FormatStatFromTextBlocks()
                    if infoSpeech then
                        return infoSpeech, nil, nil
                    end
                    return "", nil, nil
                end
                -- Party member toggle.
                local elemType = focusedElement.elemType or ""
                local isToggleOrButton = elemType:find("LSToggleButton")
                    or elemType:find("LSButton")
                if isToggleOrButton and dcProps then
                    local charName = dcProps.Name or dcProps.CharacterName
                        or dcProps.DisplayName
                    if charName and charName ~= "" then
                        return "Character: " .. charName, nil, nil
                    end
                end
                -- Other ls.Character elements.
                local charStatSpeech = FormatStatFromTextBlocks()
                if charStatSpeech then
                    return charStatSpeech, nil, nil
                end
                return "", nil, nil
            end

            -- Tooltip-deferred DC types (catch-all).
            if dcType and TOOLTIP_DEFERRED_DC_TYPES[dcType] then
                return "", nil, nil
            end

            -- Suppress layout containers.
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
        customTooltipFn = function(tooltipTexts, focusedDCType,
                                   handlerState)
            if not tooltipTexts or #tooltipTexts == 0 then return nil end
            if not focusedDCType then return nil end

            -- Empty equipment slot: handler already spoke "slot:
            -- Empty", no tooltip content to append.
            if focusedDCType == "ls.VMEquipmentSlot"
                and equipmentSlotEmpty then
                return ""
            end

            -- Action resources: handler already spoke everything.
            if focusedDCType == "ls.VMActionResource" then
                return ""
            end

            -- Dispatch by DC type; TOOLTIP_DEFERRED_DC_TYPES share
            -- the generic formatter.  For equipment slots, the
            -- handler spoke "slot: item" as plain text (not via
            -- SpeechData) so spokenRoles wasn't populated -- pre-
            -- mark "name" so the tooltip doesn't repeat the item
            -- name we just said.
            local spokenRoles
            if focusedDCType == "ls.VMEquipmentSlot" then
                spokenRoles = {name = true}
            else
                spokenRoles = handlerState
                    and handlerState.spokenRoles or nil
            end
            local formatter = TOOLTIP_FORMATTERS[focusedDCType]
            if not formatter and TOOLTIP_DEFERRED_DC_TYPES[focusedDCType]
                then formatter = FormatGenericTooltip end
            if not formatter then return nil end

            local speechData = formatter(tooltipTexts, spokenRoles)
            if not speechData
                or (next(speechData.coreFields) == nil
                    and #speechData.properties == 0) then
                return nil
            end
            return speechData
        end,
        shouldDisableInterrupt = ShouldAppendEquipmentTooltip,
        buildDetailList = function(focusedData, tooltipTexts)
            if not focusedData then return nil end
            local dcType = focusedData.dcType
            local dcProps = focusedData.dcProps
            if not dcProps then return nil end

            -- VMItem: inventory item detail view.
            if dcType == "ls.VMItem" then
                return BuildVMItemDetailList(dcProps, tooltipTexts)
            end

            -- VMEquipmentSlot: equipment slot detail view.
            if dcType == "ls.VMEquipmentSlot" then
                return BuildEquipmentSlotDetailList(
                    dcProps, focusedData, tooltipTexts)
            end

            -- VMAbility: ability score detail view.
            if dcType == "ls.VMAbility" then
                return BuildAbilityDetailList(
                    focusedData.elemId, dcProps)
            end

            return nil
        end,
    })

    return handler
end

-- ============================================================================
-- Equipment state accessors (for tooltip dispatch in WorldUI)
-- ============================================================================

local function IsEquipmentSlotEmpty()
    return equipmentSlotEmpty
end

local function ShouldAppendEquipmentTooltip()
    if equipmentTooltipShouldAppend then
        equipmentTooltipShouldAppend = false
        return true
    end
    return false
end

-- ============================================================================
-- Diagnostics
-- ============================================================================

local equipmentDumpDone = false
local function DumpEquipmentStructure()
    if equipmentDumpDone then return end
    equipmentDumpDone = true

    local entity = GetSelectedCharacterEntity()
    if not entity then
        Log.Warn("EQUIP DUMP: no player entity")
        return
    end

    Log.Info("========== EQUIPMENT STRUCTURE DUMP ==========")

    local componentNames = {}
    pcall(function()
        local allNames = entity:GetAllComponentNames()
        if allNames then
            for nameIndex = 1, #allNames do
                componentNames[#componentNames + 1] = allNames[nameIndex]
            end
        end
    end)
    local inventoryComponents = {}
    for _, componentName in ipairs(componentNames) do
        local lowerName = componentName:lower()
        if lowerName:find("inventor") or lowerName:find("equip")
            or lowerName:find("item") or lowerName:find("container")
            or lowerName:find("slot") or lowerName:find("weapon")
            or lowerName:find("armor") then
            inventoryComponents[#inventoryComponents + 1] = componentName
        end
    end
    Log.Info("EQUIP DUMP: inventory-related components: "
        .. table.concat(inventoryComponents, ", "))

    pcall(function()
        local owner = entity.InventoryOwner
        if not owner then
            Log.Info("EQUIP DUMP: no InventoryOwner component")
            return
        end
        Log.Info("EQUIP DUMP: InventoryOwner type=" .. type(owner))
        if owner.PrimaryInventory then
            Log.Info("EQUIP DUMP: PrimaryInventory exists")
        end
        if owner.Inventories then
            local inventoryCount = 0
            pcall(function() inventoryCount = #owner.Inventories end)
            Log.Info("EQUIP DUMP: Inventories count=" .. tostring(inventoryCount))
        end
    end)

    Log.Info("========== END EQUIPMENT STRUCTURE DUMP ==========")
end

-- ============================================================================
-- Exports
-- ============================================================================

BG3Access.Client.CharSheet = {
    CreateCharacterPanelHandler  = CreateCharacterPanelHandler,
    IsEquipmentSlotEmpty         = IsEquipmentSlotEmpty,
    ShouldAppendEquipmentTooltip = ShouldAppendEquipmentTooltip,
    DumpEquipmentStructure       = DumpEquipmentStructure,
}
