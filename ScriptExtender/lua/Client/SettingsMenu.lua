-- File: Client/SettingsMenu.lua
--
-- Spoken settings UI.  Opens via RS Down (toggled), navigates a
-- hierarchical menu (top level -> category submenus -> optional
-- sub-sub-menus) with D-pad and A/B, closes via RS Down or B at
-- the root level.  Each navigation press announces the new state
-- through Tolk; no visual UI is rendered.
--
-- Controls while open:
--   D-pad Up   -- previous entry at current level (wraps)
--   D-pad Down -- next entry at current level (wraps)
--   D-pad Left -- cycle current value backwards (settings only;
--                 no-op on categories)
--   D-pad Right -- cycle current value forwards (settings only;
--                  no-op on categories)
--   A button   -- enter submenu (categories only; no-op on settings)
--   B button   -- back one level; close menu when at the root
--   RS Down    -- close + save (from any level)
--
-- Hierarchy state:
--   pathStack -- stack of category keys descended into.  Empty
--                means we're at the root.  E.g. {"gps"} = inside
--                GPS settings submenu.  {"gps","entityCategories"}
--                = inside the entity categories sub-sub-menu.
--   indexStack -- parallel stack of the parent-level index we came
--                from, so B restores the cursor position rather
--                than jumping to the top of the parent menu.
--   currentIndex -- 1-based index into the current level's entries.

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

local Log        = BG3Access.Client.Log
local SpeechData = BG3Access.Client.SpeechData

-- Settings reference resolved on first use so module load order doesn't
-- need to be perfect.
local Settings = nil
local function ResolveSettings()
    Settings = Settings or BG3Access.Client.Settings
    return Settings
end

local isOpen = false
local pathStack = {}
local indexStack = {}
local currentIndex = 1
local buttonSubscription = nil
local axisSubscription = nil

-- Once-per-session flag for the "Press X for help" reminder.  Set true
-- the first time SettingsMenu.Open is called in this Lua session; not
-- reset on Close, so subsequent re-opens skip the reminder.  The user
-- only needs to hear the binding once -- they remember it after that,
-- and if they don't, re-opening fresh would be the wrong recovery
-- (they can just press X to test what it does).
local hintReminderSpoken = false

--- CurrentParentKey: the key whose children we're currently listing.
--- Empty pathStack -> ROOT_KEY; otherwise the top of the stack.
local function CurrentParentKey()
    if not ResolveSettings() then return nil end
    if #pathStack == 0 then return Settings.ROOT_KEY end
    return pathStack[#pathStack]
end

--- CurrentEntries: ordered list of entry keys at the current level.
local function CurrentEntries()
    if not ResolveSettings() then return {} end
    return Settings.GetEntriesIn(CurrentParentKey())
end

--- FormatValue: produce a spoken representation of a setting value.
--- Booleans become "on" / "off"; strings get their first letter
--- capitalized; numbers stringify directly.
local function FormatValue(value)
    if type(value) == "boolean" then
        return value and "on" or "off"
    end
    if type(value) == "string" then
        if value == "" then return value end
        return value:sub(1, 1):upper() .. value:sub(2)
    end
    return tostring(value)
end

--- DescribeEntry: build the spoken phrase for a single entry at the
--- current level.  Settings read as "Label: value"; categories read
--- as "Label, submenu" so the user knows pressing A drills in.
---
--- Special case for the Global verbosity entry: when individual
--- participating settings have diverged from the current tier's
--- preset (Settings.IsCustomized()), the value reads "Custom"
--- instead of the stored tier name.  Cycling the dial via D-pad
--- Left/Right reapplies the preset and clears Custom.
local function DescribeEntry(entryKey)
    if not ResolveSettings() then return entryKey end
    local entry = Settings.GetEntry(entryKey)
    if not entry then return entryKey end
    if Settings.IsCategory(entryKey) then
        return entry.label .. ", submenu"
    end
    if entryKey == "verbosity" and Settings.IsCustomized
        and Settings.IsCustomized() then
        return entry.label .. ": Custom"
    end
    -- Custom phrasing for the About entry: read as "BG3Access version
    -- X.Y.Z" rather than the standard "About: X.Y.Z" formatting.  The
    -- label "About" is still used by HINTS lookup (X-button help) and
    -- any future generic UI; just the spoken form on navigation differs.
    if entryKey == "about" then
        return "BG3Access version " .. FormatValue(entry.currentValue)
    end
    return entry.label .. ": " .. FormatValue(entry.currentValue)
end

--- Speak the current entry, optionally prefixed by a context phrase
--- (e.g. on enter, on submenu transition).  Interrupt priority --
--- holding D-pad through rapid cycles stays responsive.
local function SpeakCurrent(prefix)
    local entries = CurrentEntries()
    if #entries == 0 then
        local emptyMessage = (prefix and (prefix .. ". ") or "")
            .. "No settings available."
        if SpeechData and SpeechData.Alert then
            SpeechData.Alert(emptyMessage, "interrupt")
        else
            pcall(Ext.Tolk.Speak, emptyMessage, true)
        end
        return
    end
    if currentIndex < 1 or currentIndex > #entries then
        currentIndex = 1
    end
    local entryKey = entries[currentIndex]
    local text = (prefix and (prefix .. ". ") or "")
        .. DescribeEntry(entryKey)
    if SpeechData and SpeechData.Alert then
        SpeechData.Alert(text, "interrupt")
    else
        pcall(Ext.Tolk.Speak, text, true)
    end
end

-- HINTS: all spoken-help text for settings and categories lives here.
-- Authored in one place so reviewing, rewording, and grepping for
-- coverage is a single-file operation.  Module registrations elsewhere
-- (Combat / Notifications / SpeechData / Subregion / WorldNav) stay
-- pure data -- they declare storage, default, and options only; they
-- don't carry any UI vocabulary.  See SpeakHintForCurrent below for
-- the lookup rules.
--
-- Each entry is keyed by the setting or category key as registered
-- via Settings.RegisterDefault / Settings.RegisterCategory.  Values
-- can be:
--
--   * string -- a single hint used for every value of the setting.
--     Used for booleans (the value was already announced as On/Off
--     before X), numerics (the value is self-describing), and
--     categories (no value).
--
--   * table  -- a per-value hint table keyed by the setting's stored
--     value.  Used for multi-choice settings where each option has a
--     meaningfully different behavior worth describing separately.
--     The verbosity entry also includes a "custom" key consulted when
--     Settings.IsCustomized() is true (no stored value, just a
--     derived display state).
--
-- If a setting has no entry here, the X press speaks "No help
-- available for this setting." -- distinguishes a silent button
-- (broken binding) from a deliberately undocumented case.
local HINTS = {
    -- ============================================================
    -- Root-level info entries
    -- ============================================================
    about = "Shows the installed version of BG3Access.  Updates "
        .. "automatically on each release; in a development build "
        .. "the version reads 'dev build' instead of a number.",

    -- ============================================================
    -- Categories (submenu nodes)
    -- ============================================================
    verbositySettings = "Controls how much detail the mod speaks. "
        .. "The Global verbosity dial sets a preset -- Brief, Normal, "
        .. "or Verbose -- that adjusts most settings together. "
        .. "Individual toggles below override the preset for fine "
        .. "control.",
    gpsSettings = "Settings for the navigation system. Controls how "
        .. "the mod describes direction, when it warns about hazards "
        .. "or enemies, and what shows up in the routing list when "
        .. "you select a target.",
    gpsRoutingCategoriesSettings = "Toggles which categories of "
        .. "things appear in the routing list when you press "
        .. "right-stick left to enter Routing mode. Turn off "
        .. "categories you never want to navigate to so the list "
        .. "stays focused on what matters to you.",

    -- ============================================================
    -- GPS settings -- single-string (booleans and numeric)
    -- ============================================================
    hazardRadarEnabled = "Warns about deep water, fire, traps, and "
        .. "other dangerous terrain you're about to walk into.",
    playerFacingEnabled = "Announces which way your character is "
        .. "facing each time you turn with the left stick.",
    subregionEntryEnabled = "Announces named regions as you enter "
        .. "them, like 'Ravaged Beach' or 'Druid Grove'.",
    routingListRange = "Sets how far in meters things show up in "
        .. "the routing list. Above about 50 meters the game may not "
        .. "have loaded the entities yet, so wider values are safe "
        .. "but may not surface more.",

    -- ============================================================
    -- GPS settings -- per-value (multi-choice with distinct behaviors)
    -- ============================================================
    directionFormat = {
        cardinal  = "Directions spoken as world compass labels like "
            .. "'north' or 'south-southwest'.",
        clockface = "Directions spoken as camera-relative positions "
            .. "like '3 o'clock' or '12 o'clock', with 12 straight "
            .. "ahead of the camera.",
    },
    guidanceMode = {
        audio = "A spatial sound beacon plays from the target's "
            .. "direction. No per-tick direction speech.",
        voice = "Direction and distance to the target are spoken as "
            .. "you walk. No spatial sound beacon.",
    },
    routingBehavior = {
        ["automatic"] = "Moves your character to the target via the "
            .. "in-game pathfinder.",
        ["manually guided"] = "Provides audio or spoken cues while "
            .. "you control character movement with the left stick.",
    },

    -- ============================================================
    -- Routing list categories (14 boolean toggles, single-string)
    -- Keys derived from CategorySettingKey() in WorldNav.lua:
    -- "routingCategory_" + lower(name with spaces -> underscores).
    -- ============================================================
    routingCategory_companions       = "Party members: alive, downed, "
        .. "or dead. Findable anywhere on the map regardless of "
        .. "routing list range.",
    routingCategory_npcs             = "Alive non-party characters: "
        .. "friendly, neutral, and hostile.",
    routingCategory_waypoints        = "Unlocked fast-travel shrines.",
    routingCategory_discovered_places = "Named subregions you've "
        .. "entered this session, such as Druid Grove or Goblin Camp.",
    routingCategory_doors            = "Doors, hatches, and traversal "
        .. "objects.",
    routingCategory_containers       = "Chests, crates, barrels, "
        .. "corpses -- anything lootable.",
    routingCategory_quest_items      = "Items flagged as story or "
        .. "quest-relevant.",
    routingCategory_consumables      = "Potions, scrolls, grenades, "
        .. "and similar usable items.",
    routingCategory_food             = "Items that heal three hit "
        .. "points or less.",
    routingCategory_herbs            = "Harvestable plants and "
        .. "alchemy ingredients.",
    routingCategory_equipment        = "Weapons, armor, and other "
        .. "wearable gear.",
    routingCategory_loot             = "Valuable items above a gold "
        .. "threshold.",
    routingCategory_books_and_keys   = "Readable books, letters, "
        .. "prayers, and key items.",
    routingCategory_miscellaneous    = "Anything that doesn't fit "
        .. "another category -- scenery, props, uncategorized items.",

    -- ============================================================
    -- Verbosity settings -- Global verbosity is per-value with a
    -- special "custom" entry consulted when Settings.IsCustomized().
    -- ============================================================
    verbosity = {
        brief   = "Quietest preset. Hazards, combat damage, and game "
            .. "notifications stay on. Facing, subregion entry, item "
            .. "details, spell details, and combat dice rolls are "
            .. "silenced.",
        normal  = "Default preset. Adds facing, subregion entry, "
            .. "basic item details like weight and gold, plus spell "
            .. "duration, recharge, and stat bonuses. Deeper spell "
            .. "breakdowns and combat dice rolls stay off.",
        verbose = "Most detailed preset. Everything on -- weapon "
            .. "properties, full spell breakdowns, combat dice rolls, "
            .. "and stat math.",
        custom  = "One or more settings have been individually "
            .. "adjusted away from the current preset. Press D-pad "
            .. "left or right to re-apply a preset and clear Custom.",
    },

    -- ============================================================
    -- Verbosity settings -- single-string (booleans)
    -- ============================================================
    speakItemWeight = "Speaks an item's weight when you focus it in "
        .. "inventory, containers, or trade.",
    speakItemGold = "Speaks an item's gold value when you focus it.",
    speakWeaponProperties = "Weapons read their properties like "
        .. "Finesse, Heavy, Light, Two-handed, or Versatile when "
        .. "focused.",
    speakDescription = "Items and spells include their description "
        .. "text when focused.",
    speakCost = "Spells and abilities include their action cost when "
        .. "focused, such as Action, Bonus Action, or spell slot "
        .. "level.",
    speakDice = "Spells include their damage dice and bonuses when "
        .. "focused, like '2d6 fire damage plus 3'.",
    speakDuration = "Spells include how long their effect lasts when "
        .. "focused.",
    speakFrequency = "Abilities include how often they refresh when "
        .. "focused, such as per turn, per short rest, or per long "
        .. "rest.",
    speakRecharge = "Abilities include their recharge rules when "
        .. "focused, such as 'recharges on a roll of five or six'.",
    speakBreakdown = "Character stats explain their math when "
        .. "focused, such as 'AC 16: 14 from leather armor plus 2 "
        .. "from Dexterity'.",
    speakBonus = "Stats include the ability bonus they grant when "
        .. "focused, such as 'Strength 16, plus 3 modifier'.",
    speakNavigationHints = "Speaks brief navigation hints when you "
        .. "enter a new screen or panel, like 'Press A to confirm, B "
        .. "to go back'.",
    combatDamageEnabled = "Speaks damage dealt and taken during "
        .. "combat, including who attacked whom and the damage type.",
    diceRollDetailEnabled = "Speaks dice roll outcomes, including "
        .. "attack rolls, saving throws, and skill checks with their "
        .. "results.  Applies in combat and out (dialogue checks, "
        .. "lockpicking, perception, etc.).",
    notificationsEnabled = "Speaks one-shot game notifications as "
        .. "they appear, like 'Quest updated', 'Recipe learned', or "
        .. "'Companion approved'.",
}

--- SpeakHintForCurrent: speak the authored help text for the entry
--- under the cursor.  Wired to the X button in HandleButton.
---
--- Lookup rules:
---   * Key not in HINTS                       -> "No help available"
---   * HINTS[key] is a string                 -> speak the string
---   * HINTS[key] is a table                  -> look up by current
---                                                value (or by "custom"
---                                                for the verbosity
---                                                special case below)
---   * Looked-up table entry is missing       -> "No help available"
---
--- Custom special case: when entryKey is "verbosity" and
--- Settings.IsCustomized() returns true, look up HINTS.verbosity.custom
--- instead of the per-tier hint.  The dial reads "Custom" in that state
--- (see DescribeEntry) and the user wants to know what Custom MEANS,
--- not what their last-applied tier would do.
---
--- Interrupt priority because the user explicitly asked for the hint
--- and shouldn't have to wait through queued speech to hear it.
local function SpeakHintForCurrent()
    if not ResolveSettings() then return end
    local entries = CurrentEntries()
    if #entries == 0 then return end
    if currentIndex < 1 or currentIndex > #entries then
        currentIndex = 1
    end
    local entryKey = entries[currentIndex]
    local hint = HINTS[entryKey]
    local text = "No help available for this setting."
    if type(hint) == "string" and hint ~= "" then
        text = hint
    elseif type(hint) == "table" then
        local lookupValue = nil
        if entryKey == "verbosity"
            and Settings.IsCustomized and Settings.IsCustomized() then
            lookupValue = "custom"
        else
            local entry = Settings.GetEntry(entryKey)
            if entry then lookupValue = entry.currentValue end
        end
        if lookupValue ~= nil then
            local perValue = hint[lookupValue]
            if type(perValue) == "string" and perValue ~= "" then
                text = perValue
            end
        end
    end
    if SpeechData and SpeechData.Alert then
        SpeechData.Alert(text, "interrupt")
    else
        pcall(Ext.Tolk.Speak, text, true)
    end
end

local function SelectNext()
    local entries = CurrentEntries()
    if #entries == 0 then return end
    currentIndex = (currentIndex % #entries) + 1
    SpeakCurrent()
end

local function SelectPrev()
    local entries = CurrentEntries()
    if #entries == 0 then return end
    currentIndex = ((currentIndex - 2) % #entries) + 1
    SpeakCurrent()
end

--- ChangeValue: cycle the current entry's value (settings only; no-op
--- on categories).  direction is "next" or "prev".
---
--- Speech is the new VALUE only ("on", "off", "Verbose", etc.), not
--- the full "Item weight: off" phrase.  The user navigated onto this
--- entry just before pressing left/right, so they already heard the
--- label -- restating it on every value tick is noise that slows
--- down rapid cycling.  Re-navigating to the entry (D-pad up/down)
--- speaks the full label-and-value again for re-orientation.
---
--- Special case: the Global verbosity entry can read "Custom" instead
--- of the stored tier name when participating settings have diverged
--- from the preset.  Cycling the dial reapplies the preset and
--- clears Custom, so the new value here is always a tier name.
local function ChangeValue(direction)
    if not ResolveSettings() then return end
    local entries = CurrentEntries()
    if #entries == 0 then return end
    local entryKey = entries[currentIndex]
    if not entryKey or Settings.IsCategory(entryKey) then return end
    if direction == "prev" then
        Settings.CyclePrev(entryKey)
    else
        Settings.CycleNext(entryKey)
    end
    local entry = Settings.GetEntry(entryKey)
    local valueText = entry and FormatValue(entry.currentValue)
        or "(unknown)"
    if SpeechData and SpeechData.Alert then
        SpeechData.Alert(valueText, "interrupt")
    else
        pcall(Ext.Tolk.Speak, valueText, true)
    end
end

--- EnterSubmenu: drill into the focused category.  Saves the current
--- index so B can restore it later.  No-op when the focused entry
--- isn't a category.
local function EnterSubmenu()
    if not ResolveSettings() then return end
    local entries = CurrentEntries()
    if #entries == 0 then return end
    local entryKey = entries[currentIndex]
    if not entryKey or not Settings.IsCategory(entryKey) then return end
    local entry = Settings.GetEntry(entryKey)
    table.insert(indexStack, currentIndex)
    table.insert(pathStack, entryKey)
    currentIndex = 1
    if Log and Log.Info then
        Log.Info("SETTINGS MENU: entered '" .. entryKey .. "'")
    end
    SpeakCurrent(entry.label)
end

--- LeaveSubmenu: back out one level.  Returns false at the root
--- (caller closes the menu instead); true after a successful pop.
local function LeaveSubmenu()
    if #pathStack == 0 then return false end
    table.remove(pathStack)
    currentIndex = table.remove(indexStack) or 1
    if Log and Log.Info then
        Log.Info("SETTINGS MENU: left submenu, back to '"
            .. CurrentParentKey() .. "'")
    end
    -- Speak the entry the cursor returned to so the user has clear
    -- context after the back gesture.
    SpeakCurrent()
    return true
end

local SettingsMenu = {}

--- HandleButton: routed ControllerButtonInput handler.  Active only
--- while the menu is open.  Calls PreventAction on EVERY button so
--- nothing reaches BG3.  D-pad / A / B drive menu navigation; other
--- buttons are silently absorbed.
local function HandleButton(event)
    if not event then return end
    pcall(function() event:PreventAction() end)
    if not event.Pressed then return end
    local buttonName = tostring(event.Button)
    if buttonName == "DPadDown" then
        SelectNext()
    elseif buttonName == "DPadUp" then
        SelectPrev()
    elseif buttonName == "DPadLeft" then
        ChangeValue("prev")
    elseif buttonName == "DPadRight" then
        ChangeValue("next")
    elseif buttonName == "A" then
        EnterSubmenu()
    elseif buttonName == "B" then
        -- Back one level; close if we were at the root.
        local popped = LeaveSubmenu()
        if not popped then
            SettingsMenu.Close()
        end
    elseif buttonName == "X" then
        -- Speak the authored hint for the entry under the cursor.
        -- See SpeakHintForCurrent above for the missing-hint fallback.
        SpeakHintForCurrent()
    end
end

--- HandleAxis: absorb every axis event while open so left-stick
--- movement, right-stick rotation, and triggers can't reach BG3.
--- The RS-Down toggle that closes the menu is handled by EventRouter's
--- own subscription and still fires; ActionPrevented is sticky across
--- subscribers so BG3 sees the event as cancelled either way.
local function HandleAxis(event)
    if not event then return end
    pcall(function() event:PreventAction() end)
end

--- Open: enter the menu at the root level.  Subscribes to button +
--- axis input; resets the path stack and cursor.  Re-entrant.
function SettingsMenu.Open()
    if isOpen then return end
    isOpen = true
    pathStack = {}
    indexStack = {}
    currentIndex = 1
    if Ext.Events and Ext.Events.ControllerButtonInput then
        buttonSubscription = Ext.Events.ControllerButtonInput
            :Subscribe(HandleButton)
    end
    if Ext.Events and Ext.Events.ControllerAxisInput then
        axisSubscription = Ext.Events.ControllerAxisInput
            :Subscribe(HandleAxis)
    end
    if Log and Log.Info then
        Log.Info("SETTINGS MENU: opened")
    end
    -- Compose the greeting prefix so the X-press hint reminder folds
    -- into the same interrupt-priority phrase as the menu name and
    -- the first entry description.  Without the inline composition we'd
    -- fire two interrupt-priority Alerts back-to-back and the entry
    -- description would clobber the reminder.  Set the flag before
    -- speaking so a re-entrant Open from the alert callback doesn't
    -- speak it twice.
    local greeting = "Settings menu"
    if not hintReminderSpoken then
        greeting = greeting .. ". Press X for help on any setting"
        hintReminderSpoken = true
    end
    SpeakCurrent(greeting)
end

--- Close: leave the menu entirely, save changes, speak confirmation.
--- Re-entrant (no-op when already closed).  Called via RS-Down at
--- any level, or via B at the root level.
function SettingsMenu.Close()
    if not isOpen then return end
    isOpen = false
    if buttonSubscription and Ext.Events
        and Ext.Events.ControllerButtonInput then
        pcall(Ext.Events.ControllerButtonInput.Unsubscribe,
            Ext.Events.ControllerButtonInput, buttonSubscription)
        buttonSubscription = nil
    end
    if axisSubscription and Ext.Events
        and Ext.Events.ControllerAxisInput then
        pcall(Ext.Events.ControllerAxisInput.Unsubscribe,
            Ext.Events.ControllerAxisInput, axisSubscription)
        axisSubscription = nil
    end
    if ResolveSettings() and Settings.Save then
        Settings.Save()
    end
    if Log and Log.Info then
        Log.Info("SETTINGS MENU: closed")
    end
    if SpeechData and SpeechData.Alert then
        SpeechData.Alert("Settings closed", "interrupt")
    else
        pcall(Ext.Tolk.Speak, "Settings closed", true)
    end
end

--- Toggle: open if closed, close if open.  EventRouter calls this on
--- RS Down so the same gesture opens and closes from any level.
function SettingsMenu.Toggle()
    if isOpen then
        SettingsMenu.Close()
    else
        SettingsMenu.Open()
    end
end

--- IsOpen: query the menu state.  Other input subscribers gate on
--- this to bow out while the menu is up.
function SettingsMenu.IsOpen()
    return isOpen
end

BG3Access.Client.SettingsMenu = SettingsMenu

return SettingsMenu
