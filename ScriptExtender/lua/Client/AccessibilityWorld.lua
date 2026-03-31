-- File: Client/AccessibilityWorld.lua
--
-- In-game world accessibility handler.
--
-- Handles UI elements that appear during gameplay (not menus):
-- - RT shortcuts radial (character sheet, spell book, journal, etc.)
-- - RB action radial (hotbar actions, spells, passives)
-- - Future: spatial awareness, context menus, combat UI
--
-- The Manager detects radial snapshot events and delegates here.
-- C++ provides the radial slot data (title, description, tag) via
-- TickSnapshot.radialSlotChanged.
--
-- HotBar slots (RB action radial): C++ passes VMHotBarSlot Content
-- sub-object properties as radialSlotTag ("key1=val1;key2=val2;...").
-- XAML binds descriptions to Content.ShortDescription (spells/actions)
-- and Content.Description (passives fallback).  If those resolve to
-- LocaString handles, Lua falls back to Ext.Stats API lookups.

local Log = BG3Access.Client.Log
local H = BG3Access.Client.Helpers

-- ============================================================================
-- State
-- ============================================================================

-- No Lua-side dedup state needed -- C++ handles radial dedup via
-- pointer address comparison with center-rest reset.

-- ============================================================================
-- Tag parsing
-- ============================================================================

--- ParseTagProps: parse "key1=val1;key2=val2;..." into a table.
--- @param tagString string  Serialized properties from C++.
--- @return table  {key = value, ...}
local function ParseTagProps(tagString)
    local props = {}
    if not tagString or tagString == "" then return props end
    for pair in tagString:gmatch("[^;]+") do
        local key, value = pair:match("^([^=]+)=(.*)$")
        if key then
            props[key] = value
        end
    end
    return props
end

--- IsValidText: check if a string is usable text (not empty, not a
--- LocaString handle, not a ForceUpdate placeholder).
local function IsValidText(text)
    if not text or text == "" then return false end
    if text:find("%[ForceUpdate%]") then return false end
    if text:match("^h%x+g") then return false end
    if text:find("s_HandleUnknown") then return false end
    return true
end

-- ============================================================================
-- API-based description lookup for HotBar slots
-- ============================================================================

--- LookupHotBarDescription: resolve description for an action/spell/item.
---
--- Strategy (API-first per CLAUDE.md):
--- ALL paths use SE APIs via H.ReadStatDescription (shared helper).
--- ViewModel props are LAST RESORT fallback.
---
--- Lookup order (all API-based):
--- 1. Ext.Stats.Get(PrototypeID) for spells/actions.
--- 2. Ext.Stats.Get(PassiveName) for passives.
--- 3. Ext.Entity.Get(EntityUUID) -> SpellBook.Spells for linked spells.
--- 4. Ext.Entity.Get(EntityUUID) -> Data.StatsId -> Ext.Stats for items.
--- 5. ViewModel Description prop (last resort fallback).
---
--- @param contentProps table  Parsed Content sub-object properties.
--- @return string|nil  The description text, or nil if not found.
local function LookupHotBarDescription(contentProps)
    -- Stat types that have a Description attribute, per the game's schema:
    -- Public\Shared\Stats\Generated\Structure\Modifiers.txt
    -- Types WITHOUT Description: Armor, Character, CriticalHitTypeData,
    -- Object, Weapon.  Accessing Description on these triggers SE's
    -- __debugbreak in Debug builds, which kills the game without a debugger.
    local STAT_TYPES_WITH_DESCRIPTION = {
        SpellData = true,
        StatusData = true,
        PassiveData = true,
        InterruptData = true,
    }

    -- Helper: try Ext.Stats.Get(id) -> H.ReadStatDescription.
    -- Skips stat types that don't have Description per the game's schema.
    local function TryStatsDescription(statsId, label)
        if not statsId or statsId == "" then return nil end
        Log.Debug("  HotBar API: " .. label .. "=" .. statsId)
        local statsOk, statsData = pcall(Ext.Stats.Get, statsId)
        if statsOk and statsData then
            -- Check the stat's ModifierList (type) before reading Description.
            -- Reading Description on Armor/Character/Object/Weapon/CriticalHitTypeData
            -- triggers __debugbreak in SE Debug builds.
            local typeOk, statType = pcall(function()
                return statsData.ModifierList
            end)
            if typeOk and statType and not STAT_TYPES_WITH_DESCRIPTION[statType] then
                Log.Debug("  HotBar API: " .. label .. " stat type="
                    .. tostring(statType) .. " (no Description attribute, skipping)")
                return nil
            end
            local resolved = H.ReadStatDescription(statsData)
            if resolved and resolved ~= "" then
                Log.Debug("  HotBar desc (" .. label .. "): " .. resolved)
                return resolved
            end
        end
        return nil
    end

    -- 1. Spell/action lookup via PrototypeID (most common path).
    local result = TryStatsDescription(contentProps["PrototypeID"], "PrototypeID")
    if result then return result end

    -- 2. Passive lookup via PassiveName.
    result = TryStatsDescription(contentProps["PassiveName"], "PassiveName")
    if result then return result end

    -- 3-4. Entity-based lookup for items.
    --      APIs from D:\API.md:
    --      - Ext.Entity.Get(uuid) (line 182)
    --      - entity.SpellBook.Spells (line 200)
    --      - entity:GetAllComponentNames() (line 799)
    local entityUuid = contentProps["EntityUUID"]
    if entityUuid and entityUuid ~= "" then
        Log.Debug("  HotBar API: EntityUUID=" .. entityUuid)
        local entityOk, entity = pcall(Ext.Entity.Get, entityUuid)
        if entityOk and entity then
            -- 3. SpellBook.Spells: linked spells (scrolls, wands).
            local spellBookOk, spellBook = pcall(function()
                return entity.SpellBook
            end)
            if spellBookOk and spellBook then
                local spellsOk, spells = pcall(function()
                    return spellBook.Spells
                end)
                if spellsOk and spells then
                    for spellIndex = 1, #spells do
                        local entryOk, spellId = pcall(function()
                            local entry = spells[spellIndex]
                            local entryId = entry.Id
                            if entryId then
                                return entryId.OriginatorPrototype
                                    or entryId.Prototype
                            end
                            return nil
                        end)
                        if entryOk and spellId and spellId ~= "" then
                            result = TryStatsDescription(spellId, "SpellBook")
                            if result then return result end
                        end
                    end
                end
            end

            -- 4. Item stats via entity Data component.
            local dataOk, statsId = pcall(function()
                return entity.Data and entity.Data.StatsId
            end)
            if dataOk and statsId and statsId ~= "" then
                result = TryStatsDescription(statsId, "Entity/StatsId")
                if result then return result end
            end

            -- Diagnostic: dump component names if all API paths missed.
            local namesOk, componentNames = pcall(function()
                return entity:GetAllComponentNames()
            end)
            if namesOk and componentNames then
                local nameList = table.concat(componentNames, ", ")
                Log.Debug("  HotBar entity components: " .. nameList)
            end
        end
    end

    -- 5. Last resort: ViewModel Description prop from content data.
    local directDescription = contentProps["Description"]
    if IsValidText(directDescription) then
        Log.Debug("  HotBar desc (ViewModel fallback): " .. directDescription)
        return directDescription
    end

    Log.Debug("  HotBar desc: no match found")
    return nil
end

-- ============================================================================
-- Data gathering (one function collects all data into a result table)
-- ============================================================================

--- GatherRadialSlotData: collect all data for a radial slot event.
--- Returns a structured table with title, description, slotType, etc.
--- Does NOT speak -- that's the caller's job.
---
--- For ShortcutsMenu (RT): title and description come from C++ directly
--- (ActionTitle and Description TextBlocks, localized by XAML DataTriggers).
---
--- For HotBar (RB): title comes from C++. Description is resolved here
--- via SE APIs (API-first: Stats, Entity, then ViewModel fallback).
---
--- @param snapshot table  The full TickSnapshot from C++.
--- @return table|nil  {title, description, slotType} or nil if nothing to say.
local function GatherRadialSlotData(snapshot)
    local title = snapshot.radialTitleText
    local slotType = snapshot.radialSlotType or "?"

    if not title or title == "" then
        Log.Debug("RADIAL [" .. slotType .. "]: no title, skipping")
        return nil
    end

    local description = snapshot.radialDescriptionText

    -- HotBar slots: resolve description via API.
    if slotType == "HotBar" and not IsValidText(description) then
        local contentProps = ParseTagProps(snapshot.radialSlotTag)
        description = LookupHotBarDescription(contentProps)
    end

    return {
        title       = title,
        description = description,
        slotType    = slotType,
    }
end

-- ============================================================================
-- Speech output (decides what and how to speak from gathered data)
-- ============================================================================

--- SpeakRadialSlot: format and speak the gathered radial slot data.
--- @param slotData table  From GatherRadialSlotData.
local function SpeakRadialSlot(slotData)
    local speechParts = { slotData.title }
    if slotData.description and slotData.description ~= "" then
        table.insert(speechParts, slotData.description)
    end
    local fullText = H.StripMarkupTags(table.concat(speechParts, ". "))

    -- No Lua-side dedup for radial events.  C++ handles dedup via
    -- pointer address comparison and resets on center rest.
    Log.Info("RADIAL [" .. slotData.slotType .. "]: " .. fullText)
    Ext.Tolk.Speak(fullText, true)
end

-- ============================================================================
-- Entry point (called by AccessibilityManager)
-- ============================================================================

--- HandleRadialSlot: gather data then speak.
--- @param snapshot table  The full TickSnapshot from C++.
local function HandleRadialSlot(snapshot)
    local slotData = GatherRadialSlotData(snapshot)
    if slotData then
        SpeakRadialSlot(slotData)
    end
end

--- ResetState: clear radial tracking state.
--- Called on GameStateChanged to prevent stale dedup across sessions.
local function ResetState()
    -- No Lua state to reset -- C++ handles all radial dedup.
end

-- ============================================================================
-- Exports
-- ============================================================================

BG3Access.Client.World = {
    HandleRadialSlot = HandleRadialSlot,
    ResetState       = ResetState,
}
