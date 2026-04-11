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

-- WeaponFlags bitmask -> speech-worthy flag names, built at load time.
local WEAPON_FLAG_SPEECH = {}
local WEAPON_FLAGS_SKIP = {
    Melee = true, Dippable = true, Torch = true, NoDualWield = true,
    NotSheathable = true, Unstowable = true, NeedDualWieldingBoost = true,
    Magical = true, Ammunition = true, Loading = true, Lance = true,
    Net = true,
}
if Ext.Enums and Ext.Enums.WeaponFlags then
    for flagName, flagValue in pairs(Ext.Enums.WeaponFlags) do
        if type(flagName) == "string" and not WEAPON_FLAGS_SKIP[flagName] then
            local numericValue = nil
            if type(flagValue) == "number" then
                numericValue = flagValue
            else
                pcall(function() numericValue = flagValue.Value end)
            end
            if numericValue and numericValue > 0 then
                local displayName = flagName:gsub("(%l)(%u)", "%1-%2")
                WEAPON_FLAG_SPEECH[#WEAPON_FLAG_SPEECH + 1] = {
                    mask = numericValue, name = displayName
                }
            end
        end
    end
    table.sort(WEAPON_FLAG_SPEECH, function(flagA, flagB)
        return flagA.mask < flagB.mask
    end)
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
        if firstTooltip and firstTooltip ~= "" then
            return firstTooltip
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

--- ReadItemDescription: gets the item's flavor description from its root template.
--- @param itemEntity userdata  The item entity.
--- @return string|nil  Description text, or nil.
local function ReadItemDescription(itemEntity)
    local templateComponent = itemEntity.OriginalTemplate
    if not templateComponent then return nil end
    local templateId = templateComponent.OriginalTemplate
    if not templateId or templateId == "" then return nil end

    local template = Ext.Template.GetRootTemplate(tostring(templateId))
    if not template then return nil end

    local description = template.Description
    if not description then return nil end

    local resolved = ResolveTranslatedStringValue(description)
    if resolved and (resolved:find("s_HandleUnknown")
        or resolved:find("%[ForceUpdate%]")
        or resolved:match("^h%x+g")) then
        return nil
    end
    return resolved
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

--- ReadItemStats: reads weapon properties, armor AC, and item description
--- from an item entity.  Returns a structured table so callers can build
--- SpeechData with separate fields for each piece of information.
--- Does NOT compute damage -- damage comes from tooltip (game-computed).
--- @param itemEntity userdata  The item entity.
--- @return table|nil  {weaponProps, armorClass, description} or nil.
local function ReadItemStats(itemEntity)
    local result = {}

    local weapon = itemEntity.Weapon
    if weapon then
        local weaponProps = weapon.WeaponProperties
        if weaponProps and weaponProps ~= 0 then
            local flagNames = {}
            for _, flag in ipairs(WEAPON_FLAG_SPEECH) do
                if weaponProps % (flag.mask * 2) >= flag.mask then
                    flagNames[#flagNames + 1] = flag.name
                end
            end
            if #flagNames > 0 then
                result.weaponProps = table.concat(flagNames, ", ")
            end
        end
    end

    local armor = itemEntity.Armor
    if armor then
        local armorClass = armor.ArmorClass
        if armorClass and armorClass > 0 then
            local acStr = "AC " .. tostring(armorClass)
            if armor.Shield then
                acStr = acStr .. " (Shield)"
            end
            result.armorClass = acStr
        end
    end

    local descOk, description = pcall(ReadItemDescription, itemEntity)
    if descOk and description and description ~= "" then
        result.description = description
    end

    if not result.weaponProps and not result.armorClass
        and not result.description then
        return nil
    end
    return result
end

--- FormatItemStatsString: flattens ReadItemStats result into a single string.
--- Used by GatherEquipmentSpeechData (equipment slot tooltip path).
--- @param itemEntity userdata  The item entity.
--- @return string|nil  Formatted stats string, or nil.
local function FormatItemStatsString(itemEntity)
    local stats = ReadItemStats(itemEntity)
    if not stats then return nil end
    local parts = {}
    if stats.weaponProps then parts[#parts + 1] = stats.weaponProps end
    if stats.armorClass then parts[#parts + 1] = stats.armorClass end
    if stats.description then parts[#parts + 1] = stats.description end
    if #parts == 0 then return nil end
    return table.concat(parts, ". ")
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
-- Equipment speech data (game-computed damage from tooltips)
-- ============================================================================

--- GatherEquipmentSpeechData: builds a SpeechData object for an equipped
--- item's DETAILS from tooltip texts and entity components.
---
--- Does NOT include slot + item name (the handler speaks those immediately).
---
--- @param tooltipTexts table  Raw tooltip text array from C++.
--- @param slotName string  The equipment slot display name.
--- @param itemName string|nil  The item name from dcProps.
--- @return table  SpeechData object ready for :Format() or :Speak().
local function GatherEquipmentSpeechData(tooltipTexts, slotName, itemName)
    local speechData = Helpers.CreateSpeechData()

    local damageRange = nil
    local damageRoll = nil
    local damageType = nil
    local tooltipDescription = nil
    local tooltipDescriptionLength = 0
    local itemNameLower = itemName and itemName:lower() or nil
    local seen = {}

    for _, text in ipairs(tooltipTexts) do
        if not text or text == "" then goto nextTooltipText end
        local cleaned = Helpers.StripMarkupTags(text)
        if not cleaned or cleaned == "" then goto nextTooltipText end
        local lowerCleaned = cleaned:lower()

        -- Skip noise.
        if cleaned == "Inspect" then goto nextTooltipText end
        if cleaned:find("^Equipped by") then goto nextTooltipText end
        -- Bare numbers: skip.  Weight, gold, and AC come from the entity
        -- API, not tooltip number parsing.
        if cleaned:match("^[%d%.]+$") then goto nextTooltipText end
        -- "Armour Class" label: skip.  AC comes from entity API.
        if lowerCleaned == "armour class"
            or lowerCleaned == "armor class" then
            goto nextTooltipText
        end
        if cleaned:find("^Proficiency with") then goto nextTooltipText end
        if cleaned:find("s_HandleUnknown") then goto nextTooltipText end
        if cleaned:find("%[ForceUpdate%]") then goto nextTooltipText end
        if itemNameLower and lowerCleaned == itemNameLower then
            goto nextTooltipText
        end
        if seen[lowerCleaned] then goto nextTooltipText end
        seen[lowerCleaned] = true

        -- Damage range: "4~9 Damage" or "4~9".
        local rangeMatch = cleaned:match("^(%d+~%d+)%s*[Dd]amage")
            or cleaned:match("^(%d+~%d+)$")
        if rangeMatch then
            damageRange = rangeMatch:gsub("(%d+)~(%d+)", "%1 to %2")
            goto nextTooltipText
        end

        -- Damage roll: "1d6+3" or "2d8" pattern.
        if cleaned:match("^%d+d%d+") then
            damageRoll = cleaned
            goto nextTooltipText
        end

        -- Damage type: single word matching Ext.Enums.DamageType.
        if Ext.Enums and Ext.Enums.DamageType then
            local isDamageType = false
            pcall(function()
                isDamageType = Ext.Enums.DamageType[cleaned] ~= nil
            end)
            if isDamageType then
                damageType = cleaned
                goto nextTooltipText
            end
        end

        -- Description: longest remaining text after filtering.
        if #cleaned > tooltipDescriptionLength and #cleaned > 20 then
            tooltipDescription = cleaned:gsub("[%.:%s]+$", "")
            tooltipDescriptionLength = #cleaned
        end

        ::nextTooltipText::
    end

    -- Assemble damage line.
    if damageRange then
        local damagePart = damageRange
        if damageType then
            damagePart = damagePart .. " " .. damageType
        end
        damagePart = damagePart .. " damage"
        if damageRoll then
            damagePart = damagePart .. ", roll " .. damageRoll
        end
        speechData:Add("damage", damagePart, "brief")
    end

    -- Weapon properties and armor AC from entity.
    local entity = GetSelectedCharacterEntity()
    if entity then
        local slotType = nil
        if slotName then
            for enumLabel, friendlyName in pairs(EQUIPMENT_SLOT_NAMES) do
                if friendlyName == slotName then
                    slotType = enumLabel
                    break
                end
            end
        end
        if slotType then
            local slotIndex = nil
            if Ext.Enums and Ext.Enums.StatsItemSlot then
                local enumVal = Ext.Enums.StatsItemSlot[slotType]
                if type(enumVal) == "number" then
                    slotIndex = enumVal
                elseif enumVal ~= nil then
                    pcall(function() slotIndex = enumVal.Value end)
                end
            end
            if slotIndex then
                local getOk, itemEntity = pcall(
                    GetEquippedItemEntity, entity, slotIndex)
                if getOk and itemEntity then
                    local statsOk, statsText = pcall(
                        FormatItemStatsString, itemEntity)
                    if statsOk and statsText and statsText ~= "" then
                        speechData:Add("stats", statsText, "normal")
                    end
                    -- Weight and gold from entity (verbose tier).
                    -- Entity weight is in internal units (x1000).
                    pcall(function()
                        local itemData = itemEntity.Data
                        if itemData and itemData.Weight
                            and itemData.Weight > 0 then
                            local displayWeight =
                                itemData.Weight / 1000
                            speechData:Add("weight",
                                "Weight: " .. tostring(displayWeight),
                                "verbose")
                        end
                        local itemValue = itemEntity.Value
                        if itemValue and itemValue.Value
                            and itemValue.Value > 0 then
                            speechData:Add("gold",
                                tostring(itemValue.Value) .. " gold",
                                "verbose")
                        end
                    end)
                end
            end
        end
    end

    -- Fallback description from tooltip if entity didn't provide one.
    if not speechData:HasField("stats") and tooltipDescription then
        speechData:Add("description", tooltipDescription, "verbose")
    end

    return speechData
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

--- ParseTooltipForDetails: extract game-computed properties from cached
--- tooltip texts.  Returns a table of extracted fields:
---   effectDesc: short functional description (e.g., "Heals and removes Burning")
---   range: healing/damage range (e.g., "4 to 10 Healing")
---   roll: dice roll (e.g., "2d4+2")
---   actionCost: action cost (e.g., "Bonus Action")
---   singleUse: true if "Single Use" found
---   damageRange: damage range (e.g., "4 to 9 damage")
---   damageType: damage type (e.g., "Slashing")
--- @param tooltipTexts table|nil  Array of raw tooltip strings.
--- @param itemName string|nil  Item name to filter out of results.
--- @return table  Extracted fields (may be empty).
local function ParseTooltipForDetails(tooltipTexts, itemName)
    local result = {}
    if not tooltipTexts or #tooltipTexts == 0 then return result end

    local itemNameLower = itemName and itemName:lower() or nil
    local longestDesc = nil
    local longestDescLength = 0

    for _, rawText in ipairs(tooltipTexts) do
        if not rawText or rawText == "" then goto nextTooltip end
        local cleaned = Helpers.StripMarkupTags(rawText)
        if not cleaned or cleaned == "" then goto nextTooltip end
        local lowerCleaned = cleaned:lower()

        -- Skip noise.
        if cleaned == "Inspect" then goto nextTooltip end
        if cleaned:find("^Equipped by") then goto nextTooltip end
        -- Bare numbers (weight, gold, AC values).
        if cleaned:match("^[%d%.]+$") then goto nextTooltip end
        -- Item name itself.
        if itemNameLower and lowerCleaned == itemNameLower then
            goto nextTooltip
        end

        -- Healing range: "4~10 Healing" or "4~10".
        local healRange = cleaned:match("^(%d+~%d+)%s*[Hh]ealing")
        if healRange then
            result.range = healRange:gsub("(%d+)~(%d+)", "%1 to %2")
                .. " Healing"
            goto nextTooltip
        end

        -- Damage range: "4~9 Damage" or "4~9".
        local damageRange = cleaned:match("^(%d+~%d+)%s*[Dd]amage")
            or cleaned:match("^(%d+~%d+)$")
        if damageRange then
            result.damageRange = damageRange:gsub(
                "(%d+)~(%d+)", "%1 to %2") .. " damage"
            goto nextTooltip
        end

        -- Dice roll: "2d4+2", "1d6", etc.
        if cleaned:match("^%d+d%d+") then
            result.roll = cleaned
            goto nextTooltip
        end

        -- Action cost: "Bonus Action", "Action", "Reaction".
        if lowerCleaned == "bonus action"
            or lowerCleaned == "action"
            or lowerCleaned == "reaction" then
            result.actionCost = cleaned
            goto nextTooltip
        end

        -- Single Use.
        if lowerCleaned == "single use" then
            result.singleUse = true
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

        -- Armor class label: skip.
        if lowerCleaned == "armour class"
            or lowerCleaned == "armor class" then
            goto nextTooltip
        end

        -- Effect description: short functional text (not flavor).
        -- Prefer texts under ~80 chars that describe what the item does.
        if #cleaned > 10 and #cleaned < 80
            and not cleaned:find("^Proficiency with")
            and cleaned ~= result.range
            and not HasDetailLabel({}, cleaned) then
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

--- BuildVMItemDetailList: build detail list for inventory items.
--- @param dcProps table  DataContext properties from the focused VMItem.
--- @param tooltipTexts table|nil  Cached tooltip texts for extra fields.
--- @return table|nil  Array of {label, value}, or nil if empty.
local function BuildVMItemDetailList(dcProps, tooltipTexts)
    local detailList = {}

    -- Name.
    local itemName = ResolveDCPropString(
        dcProps.Name or dcProps.Text or dcProps.Title)
    if itemName then
        detailList[#detailList + 1] = {label = "Name", value = itemName}
    end

    -- Rarity (skip Common -- it's the default and not interesting).
    local rarity = dcProps.Rarity
    if rarity and rarity ~= "" and rarity ~= "Common" then
        detailList[#detailList + 1] = {label = "Rarity", value = rarity}
    end

    -- Category: prefer stat entry proficiency group (e.g., "Light Armour")
    -- over dcProps.ItemType (e.g., "Equipment" or "Container").
    -- Entity lookup happens later, so insert a placeholder index and
    -- fill it in during the entity pass.  If entity doesn't provide one,
    -- fall back to dcProps.ItemType.
    local categoryInsertIndex = #detailList + 1
    local categoryFromDCProps = dcProps.ItemType
    local categoryFilled = false

    -- Equipped status.
    local equippedProp = dcProps.Equipped
    if equippedProp and equippedProp ~= "" then
        local status = (equippedProp == "NotEquipped")
            and "Not Equipped" or "Equipped"
        detailList[#detailList + 1] = {label = "Status", value = status}
    end

    -- Stack count (only interesting when > 1).
    local stackCount = dcProps.Count
    if stackCount and stackCount ~= "" and stackCount ~= "1" then
        detailList[#detailList + 1] = {
            label = "Count", value = tostring(stackCount)}
    end

    -- Entity API: stats, weight, gold, description.
    local entityUUID = dcProps.EntityUUID
    if entityUUID and entityUUID ~= "" then
        pcall(function()
            local itemEntity = Ext.Entity.Get(entityUUID)
            if not itemEntity then return end

            -- Category from stat entry (e.g., "Light Armour").
            local category = ReadItemCategory(itemEntity)
            if category then
                table.insert(detailList, categoryInsertIndex,
                    {label = "Category", value = category})
                categoryFilled = true
            end

            local itemStats = ReadItemStats(itemEntity)
            if itemStats then
                if itemStats.armorClass then
                    detailList[#detailList + 1] = {
                        label = "Armor Class",
                        value = itemStats.armorClass,
                    }
                end
                if itemStats.weaponProps then
                    detailList[#detailList + 1] = {
                        label = "Properties",
                        value = itemStats.weaponProps,
                    }
                end
                if itemStats.description then
                    detailList[#detailList + 1] = {
                        label = "Description",
                        value = Helpers.StripMarkupTags(
                            itemStats.description),
                    }
                end
            end

            -- Weight (internal units x1000).
            local itemData = itemEntity.Data
            if itemData and itemData.Weight and itemData.Weight > 0 then
                detailList[#detailList + 1] = {
                    label = "Weight",
                    value = tostring(itemData.Weight / 1000),
                }
            end

            -- Gold value.
            local itemValue = itemEntity.Value
            if itemValue and itemValue.Value
                and itemValue.Value > 0 then
                detailList[#detailList + 1] = {
                    label = "Value",
                    value = tostring(itemValue.Value) .. " gold",
                }
            end
        end)
    end

    -- Fallback category from dcProps if entity didn't provide one.
    if not categoryFilled and categoryFromDCProps
        and categoryFromDCProps ~= "" then
        table.insert(detailList, categoryInsertIndex,
            {label = "Category", value = categoryFromDCProps})
    end

    -- Tooltip-derived fields: effect, healing/damage, roll, cost.
    local itemName = ResolveDCPropString(
        dcProps.Name or dcProps.Text or dcProps.Title)
    local tooltipData = ParseTooltipForDetails(tooltipTexts, itemName)
    if tooltipData.effectDesc then
        detailList[#detailList + 1] = {
            label = "Effect", value = tooltipData.effectDesc}
    end
    if tooltipData.range then
        detailList[#detailList + 1] = {
            label = "Healing", value = tooltipData.range}
    end
    if tooltipData.damageRange then
        local damageValue = tooltipData.damageRange
        if tooltipData.damageType then
            damageValue = damageValue .. ", " .. tooltipData.damageType
        end
        detailList[#detailList + 1] = {
            label = "Damage", value = damageValue}
    end
    if tooltipData.roll then
        -- Format: "1d6+3" -> "1d6, +3"
        local formattedRoll = tooltipData.roll:gsub(
            "(%d+d%d+)([%+%-])", "%1, %2")
        detailList[#detailList + 1] = {
            label = "Roll", value = formattedRoll}
    end
    if tooltipData.actionCost then
        detailList[#detailList + 1] = {
            label = "Cost", value = tooltipData.actionCost}
    end
    if tooltipData.singleUse then
        detailList[#detailList + 1] = {
            label = "Usage", value = "Single Use"}
    end

    -- Fallback description: prefer entity API description, then dcProps,
    -- then tooltip flavor text.
    if not HasDetailLabel(detailList, "Description") then
        local itemDescription = ResolveDCPropString(
            dcProps.Description)
        if itemDescription and itemDescription ~= "" then
            detailList[#detailList + 1] = {
                label = "Description",
                value = Helpers.StripMarkupTags(itemDescription),
            }
        elseif tooltipData.flavorDesc then
            detailList[#detailList + 1] = {
                label = "Description",
                value = Helpers.StripMarkupTags(tooltipData.flavorDesc),
            }
        end
    end

    -- Fallback gold from dcProps.
    if not HasDetailLabel(detailList, "Value") then
        local dcGold = dcProps.Gold
        if dcGold and dcGold ~= "" and dcGold ~= "0" then
            detailList[#detailList + 1] = {
                label = "Value", value = dcGold .. " gold"}
        end
    end

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

--- BuildEquipmentSlotDetailList: build detail list for equipment slots.
--- Uses entity API to read the equipped item's full stats (AC, weight,
--- gold, description), same data sources as GatherEquipmentSpeechData.
--- @param dcProps table  DataContext properties from the focused slot.
--- @param focusedData table  Full focused element data (not a snapshot).
--- @return table|nil  Array of {label, value}, or nil if empty.
local function BuildEquipmentSlotDetailList(dcProps, focusedData, tooltipTexts)
    -- Fields are gathered into temp vars, then appended in the
    -- final display order at the end of the function.
    local slotName = ExtractEquipmentSlotName(dcProps, nil)

    -- Empty slot: speak just Slot + Status.
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

    -- Gather fields into temp vars.
    local itemName = nil
    if type(dcProps.Item) == "table" then
        itemName = ResolveDCPropString(
            dcProps.Item.Name or dcProps.Item.DisplayName
            or dcProps.Item.Text)
    end
    local category = nil
    local armorClass = nil
    local weaponPropsField = nil
    local weight = nil
    local value = nil
    local description = nil

    -- Entity lookup: character -> equipment inventory -> slot -> item entity.
    local slotIndex = ResolveSlotIndex(slotName)
    local characterEntity = GetSelectedCharacterEntity()
    if slotIndex and characterEntity then
        pcall(function()
            local itemEntity = GetEquippedItemEntity(
                characterEntity, slotIndex)
            if not itemEntity then return end

            category = ReadItemCategory(itemEntity)

            local itemStats = ReadItemStats(itemEntity)
            if itemStats then
                armorClass = itemStats.armorClass
                weaponPropsField = itemStats.weaponProps
                if itemStats.description then
                    description = Helpers.StripMarkupTags(
                        itemStats.description)
                end
            end

            local itemData = itemEntity.Data
            if itemData and itemData.Weight and itemData.Weight > 0 then
                weight = tostring(itemData.Weight / 1000)
            end

            local itemValue = itemEntity.Value
            if itemValue and itemValue.Value
                and itemValue.Value > 0 then
                value = tostring(itemValue.Value) .. " gold"
            end
        end)
    end

    -- Tooltip-derived fields: damage, roll, type, cost.
    local tooltipData = ParseTooltipForDetails(tooltipTexts, itemName)
    local damageField = nil
    local healingField = nil
    local rollField = nil
    local effectField = tooltipData.effectDesc
    local costField = tooltipData.actionCost

    if tooltipData.damageRange then
        local damageValue = tooltipData.damageRange
        if tooltipData.damageType then
            damageValue = damageValue .. ", " .. tooltipData.damageType
        end
        damageField = damageValue
    end
    if tooltipData.range then
        healingField = tooltipData.range
    end
    if tooltipData.roll then
        -- Format: "1d6+3" -> "1d6, +3"
        local rollValue = tooltipData.roll:gsub(
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

    -- Assemble the detail list in final display order:
    -- Slot, Name, Category, Damage/Healing, Roll, Properties,
    -- Armor Class, Weight, Value, Description, Effect, Cost.
    local detailList = {}
    local function addField(label, val)
        if val and val ~= "" then
            detailList[#detailList + 1] = {label = label, value = val}
        end
    end
    addField("Slot", slotName)
    addField("Name", itemName)
    addField("Category", category)
    addField("Damage", damageField)
    addField("Healing", healingField)
    addField("Roll", rollField)
    addField("Properties", weaponPropsField)
    addField("Armor Class", armorClass)
    addField("Weight", weight)
    addField("Value", value)
    addField("Description", description)
    addField("Effect", effectField)
    addField("Cost", costField)

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

            -- Inventory items: build SpeechData from dcProps + entity API.
            -- VMItem dcProps include EntityUUID (for direct entity lookup)
            -- and Equipped ("NotEquipped" or slot enum value).
            if dcType == "ls.VMItem" and dcProps then
                local itemName = dcProps.Name or dcProps.Text
                    or dcProps.Title
                if type(itemName) == "table" then
                    itemName = itemName.Str or itemName.Text
                        or itemName.Name or nil
                end
                local itemDescription = dcProps.Description
                if type(itemDescription) == "table" then
                    itemDescription = itemDescription.Str
                        or itemDescription.Text or nil
                end
                if itemName and itemName ~= "" then
                    local speechData = Helpers.CreateSpeechData()
                    speechData:Add("itemName", itemName, "brief")
                    -- Equipped status: direct from dcProps (no scan needed).
                    local equippedProp = dcProps.Equipped
                    if equippedProp and equippedProp ~= ""
                        and equippedProp ~= "NotEquipped" then
                        speechData:Add("equipped", "Equipped", "brief")
                    end
                    -- Entity API: single lookup for stats, weight, gold.
                    -- Entity weight is in internal units (x1000).
                    local entityUUID = dcProps.EntityUUID
                    if entityUUID and entityUUID ~= "" then
                        pcall(function()
                            local itemEntity = Ext.Entity.Get(entityUUID)
                            if not itemEntity then return end
                            -- Stats: AC, weapon properties, description.
                            local itemStats = ReadItemStats(itemEntity)
                            if itemStats then
                                if itemStats.armorClass then
                                    speechData:Add("stats",
                                        itemStats.armorClass, "normal")
                                end
                                if itemStats.weaponProps then
                                    speechData:Add("weaponProps",
                                        itemStats.weaponProps, "normal")
                                end
                                if itemStats.description then
                                    speechData:Add("itemDesc",
                                        itemStats.description, "verbose")
                                end
                            end
                            -- Weight (x1000 internal units).
                            local itemData = itemEntity.Data
                            if itemData and itemData.Weight
                                and itemData.Weight > 0 then
                                local displayWeight =
                                    itemData.Weight / 1000
                                speechData:Add("weight",
                                    "Weight: " .. tostring(displayWeight),
                                    "verbose")
                            end
                            -- Gold value.
                            local itemValue = itemEntity.Value
                            if itemValue and itemValue.Value
                                and itemValue.Value > 0 then
                                speechData:Add("gold",
                                    tostring(itemValue.Value) .. " gold",
                                    "verbose")
                            end
                        end)
                    end
                    -- Fallback description from dcProps if entity API
                    -- didn't provide anything.
                    if not speechData:HasField("stats")
                        and not speechData:HasField("itemDesc")
                        and itemDescription and itemDescription ~= "" then
                        speechData:Add("itemDesc",
                            Helpers.StripMarkupTags(itemDescription),
                            "verbose")
                    end
                    -- Fallback gold from dcProps if entity didn't provide.
                    if not speechData:HasField("gold") then
                        local dcGold = dcProps.Gold
                        if dcGold and dcGold ~= ""
                            and dcGold ~= "0" then
                            speechData:Add("gold",
                                dcGold .. " gold", "verbose")
                        end
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
                        local speechData = Helpers.CreateSpeechData()
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
                            speechData:Add("gold",
                                "Gold: " .. extras[1], "normal")
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
                            speechData:Add("weight",
                                "Weight: " .. weightText, "normal")
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
        customTooltipFn = function(tooltipTexts, focusedDCType)
            if focusedDCType then
                if focusedDCType == "ls.VMEquipmentSlot" then
                    if equipmentSlotEmpty then return "" end
                    return GatherEquipmentSpeechData(
                        tooltipTexts, equipmentSlotName, equipmentItemName)
                end
                -- Inventory items.
                if focusedDCType == "ls.VMItem" then
                    return Helpers.FormatItemTooltip(tooltipTexts)
                end
                -- Action resources: suppress (handler already speaks all data).
                if focusedDCType == "ls.VMActionResource" then
                    return ""
                end
                -- Stats with breakdowns.
                if focusedDCType == "ls.VMStat"
                    or focusedDCType == "ls.VMRangeStat" then
                    return Helpers.FormatStatTooltip(tooltipTexts)
                end
                -- Combat stats.
                if focusedDCType == "gui::VMCharacterStats" then
                    return Helpers.FormatCombatStatTooltip(tooltipTexts)
                end
                -- Abilities, skills, proficiencies.
                if focusedDCType == "ls.VMAbility"
                    or focusedDCType == "ls.VMSkill"
                    or focusedDCType == "gui::VMEquipmentProficiency" then
                    return Helpers.FormatAbilityTooltip(tooltipTexts)
                end
                -- Class.
                if focusedDCType == "ls.VMClass" then
                    return Helpers.FormatFullTooltip(tooltipTexts)
                end
                -- Character info.
                if focusedDCType == "ls.Character" then
                    return Helpers.FormatStatTooltip(tooltipTexts)
                end
                -- Other tooltip-deferred DC types.
                if TOOLTIP_DEFERRED_DC_TYPES[focusedDCType] then
                    return Helpers.FormatFullTooltip(tooltipTexts)
                end
            end
            return nil
        end,
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
-- Equipment state accessors (for ProcessTooltip in WorldUI)
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
