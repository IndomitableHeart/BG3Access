-- File: Client/Settings.lua
--
-- Persistent, ordered key/value store for all mod settings.  Backed by
-- a JSON file in the user profile directory (BG3Access_settings.json).
--
-- Architecture:
--   - Modules call Settings.RegisterDefault(...) at load time to declare
--     each setting they care about.  Optionally pass a category key so
--     the setting lives inside a submenu rather than at the root.
--   - Modules call Settings.RegisterCategory(key, label, parentKey?) to
--     declare a category (a submenu node).  Categories can nest under
--     other categories for sub-sub-menus (e.g. "entityCategories"
--     under "gpsSettings").
--   - On first registration of a given key, Settings consults the
--     loaded persisted state: if a value is on disk, that wins; if not,
--     the default is recorded.
--   - Settings.Get(key) returns the current value.
--   - Settings.Set(key, value) updates the in-memory value and marks
--     the file dirty.  Settings.Save() flushes pending writes.
--
-- Hierarchy:
--   - Each entry (setting OR category) belongs to exactly one parent:
--     either ROOT_KEY (top level) or another category's key.
--   - childrenByParent[parentKey] preserves registration order within
--     that parent so the SettingsMenu enumerates predictably.
--   - Settings.GetEntriesIn(parentKey) returns the ordered list of
--     direct children of a given parent.  Pass Settings.ROOT_KEY for
--     the top level.
--   - Settings.IsCategory(key) distinguishes a category entry from a
--     setting entry, so the menu knows whether to drill in (A) or
--     cycle values (D-pad Left/Right).
--
-- Two flavors of setting registration:
--   - User-facing: valueOptions + label provided.  Appears in the
--     SettingsMenu at its registered category.
--   - Internal: no valueOptions or label.  Persistence only -- the
--     SettingsMenu filters these out.  Used by Welcome.lua to remember
--     whether the first-launch message has played.
--
-- File format: a plain JSON object mapping key -> value.  Keys are
-- registered programmatically by modules so there's no schema to keep
-- in sync.  Boolean / string / number values all round-trip cleanly
-- through Ext.Json.  Categories aren't serialized; only setting
-- values land in the file.

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

local Log = BG3Access.Client.Log

local SETTINGS_FILE_PATH = "BG3Access_settings.json"

-- Sentinel for the top-level menu.  Exposed via Settings.ROOT_KEY so
-- callers can pass it to GetEntriesIn without depending on the literal
-- string.  Underscore prefix means no real key collision is possible
-- (registrations use camelCase).
local ROOT_KEY = "__root"

-- Settings registry: key -> {defaultValue, valueOptions, label,
-- currentValue, isUserFacing, categoryKey}.
local settingsRegistry = {}

-- Categories registry: key -> {label, parentKey}.  Categories are
-- containers; they don't have values or default themselves.
local categoriesRegistry = {}

-- childrenByParent[parentKey] = ordered array of entry keys (settings
-- OR categories) that live directly under parentKey.  Root entries
-- live under ROOT_KEY.  Order is registration order.
local childrenByParent = { [ROOT_KEY] = {} }

-- Persisted values loaded from disk at startup.  Kept as a separate
-- table from settingsRegistry because settings may be persisted before
-- their owning module loads (we read the file once at startup, then
-- modules register their defaults in arbitrary order).
local persistedValues = {}

-- Dirty flag: true when in-memory values diverge from disk.  Save()
-- is a no-op when this is false, so closing the SettingsMenu without
-- changing anything doesn't incur a disk write.
local pendingSave = false

-- Tier presets: per-setting target values for each global verbosity
-- preset.  Modules opt in by calling Settings.RegisterTierPresets;
-- settings without entries here are preserved across global cycles
-- (e.g. playerFacingFormat is a format choice, not a verbosity
-- scale).
-- Shape: tierPresets[settingKey] = { brief = X, normal = Y, verbose = Z }
local tierPresets = {}

-- Reentrancy guard for Settings.Set.  ApplyVerbosityPreset iterates
-- and calls Set on each participating setting; this flag prevents
-- the side effects (ApplyVerbosityPreset on verbosity, CheckCustomization
-- on participants) from re-firing during a batch preset apply.
local applyingPreset = false

--- LoadFromFile: read the JSON settings file from user profile.
--- Returns a plain table mapping key -> value.  Returns empty table
--- on any failure (no file yet, corrupted JSON, file system error) --
--- callers treat empty as "use defaults," which is the right behavior
--- for first-launch and recovery alike.
local function LoadFromFile()
    local readOk, contents = pcall(Ext.IO.LoadFile, SETTINGS_FILE_PATH)
    if not readOk or type(contents) ~= "string" or contents == "" then
        if Log and Log.Info then
            Log.Info("Settings: no persisted file at "
                .. SETTINGS_FILE_PATH .. " (first launch or empty)")
        end
        return {}
    end
    local parseOk, data = pcall(Ext.Json.Parse, contents)
    if not parseOk or type(data) ~= "table" then
        if Log and Log.Warn then
            Log.Warn("Settings: failed to parse "
                .. SETTINGS_FILE_PATH .. " (treating as empty)")
        end
        return {}
    end
    if Log and Log.Info then
        local keyCount = 0
        for _ in pairs(data) do keyCount = keyCount + 1 end
        Log.Info("Settings: loaded " .. keyCount
            .. " persisted value(s) from " .. SETTINGS_FILE_PATH)
    end
    return data
end

--- SaveToFile: serialize all persisted values to the settings file.
--- pcall'd so a write failure doesn't crash the calling code -- worst
--- case the settings revert on next launch, which is annoying but not
--- breaking.
local function SaveToFile()
    local stringifyOk, encoded = pcall(Ext.Json.Stringify, persistedValues)
    if not stringifyOk or type(encoded) ~= "string" then
        if Log and Log.Warn then
            Log.Warn("Settings: failed to stringify "
                .. "persisted values; skipping save")
        end
        return false
    end
    local writeOk, writeErr = pcall(Ext.IO.SaveFile,
        SETTINGS_FILE_PATH, encoded)
    if not writeOk then
        if Log and Log.Warn then
            Log.Warn("Settings: SaveFile failed: " .. tostring(writeErr))
        end
        return false
    end
    if Log and Log.Info then
        Log.Info("Settings: wrote " .. #encoded
            .. " bytes to " .. SETTINGS_FILE_PATH)
    end
    return true
end

-- Load persisted state once at module load.  Registrations happening
-- later will consult this table to seed their currentValue with any
-- existing on-disk value.
persistedValues = LoadFromFile()

local Settings = {}
Settings.ROOT_KEY = ROOT_KEY

--- RegisterCategory: declare a category (a container that appears as
--- "Verbosity settings", "GPS settings", etc. in the menu).  Pressing
--- A on a category entry drills into it.
---
--- @param key string  Internal key (e.g. "verbositySettings",
---     "gpsSettings").  Used as the parent reference for child
---     registrations.  By convention, suffix category keys with
---     "Settings" so they can't collide with a setting's own key
---     (see the assertion below for why).
--- @param label string  User-facing label spoken in the menu
---     (e.g. "Verbosity settings").
--- @param parentCategoryKey string|nil  Parent category key for
---     sub-sub-menus; pass nil for top-level categories.
function Settings.RegisterCategory(key, label, parentCategoryKey)
    if categoriesRegistry[key] then return end
    -- Defense against name collision with a setting key.  A key
    -- registered as both a category and a setting confuses
    -- IsCategory / GetEntry and produces an infinite-drill bug
    -- where pressing A on the category enters a submenu that
    -- contains itself.  Hard fail at registration time -- this is
    -- a developer error, not a runtime condition.
    assert(settingsRegistry[key] == nil,
        "Settings.RegisterCategory: key '" .. tostring(key)
        .. "' is already registered as a setting; pick a distinct "
        .. "category key (e.g. add a 'Settings' suffix).")
    local parentKey = parentCategoryKey or ROOT_KEY
    categoriesRegistry[key] = {
        label     = label,
        parentKey = parentKey,
    }
    childrenByParent[parentKey] = childrenByParent[parentKey] or {}
    table.insert(childrenByParent[parentKey], key)
    childrenByParent[key] = childrenByParent[key] or {}
    if Log and Log.Info then
        Log.Info("Settings: registered category '" .. key
            .. "' under '" .. parentKey .. "'")
    end
end

--- RegisterDefault: declare a setting and its default value.  Safe to
--- call multiple times for the same key -- subsequent calls are
--- ignored (first registration wins).
---
--- @param key string  Internal key, used in Get/Set.
--- @param defaultValue any  Used when no on-disk value exists for this
---     key.  Boolean, string, or number.
--- @param valueOptions table|nil  Ordered list of valid values for
---     D-pad cycling in the SettingsMenu.  Pass nil for internal
---     state (Welcome.welcomeShown etc.) that should not appear in
---     the menu.
--- @param label string|nil  User-facing label.  Required for user-
---     facing settings (paired with valueOptions); nil for internal.
--- @param categoryKey string|nil  Category to place this setting in.
---     Pass nil for root-level settings.  Must match a key registered
---     via RegisterCategory; otherwise the setting still works but
---     won't appear in the menu (children of unknown parents are
---     silently dropped from enumeration).
function Settings.RegisterDefault(key, defaultValue, valueOptions,
        label, categoryKey)
    if settingsRegistry[key] then return end
    -- Symmetric defense against name collision with a category key.
    assert(categoriesRegistry[key] == nil,
        "Settings.RegisterDefault: key '" .. tostring(key)
        .. "' is already registered as a category; pick a distinct "
        .. "setting key.")
    local persistedValue = persistedValues[key]
    -- Explicit if/else, NOT `(cond) and persistedValue or defaultValue`.
    -- The and/or ternary collapses to defaultValue when persistedValue
    -- is false (Lua treats false as falsy in `and`), silently corrupting
    -- any boolean setting that the user set to false.
    local effectiveValue
    if persistedValue ~= nil then
        effectiveValue = persistedValue
    else
        effectiveValue = defaultValue
    end
    local isUserFacing = (valueOptions ~= nil and label ~= nil)
    settingsRegistry[key] = {
        defaultValue = defaultValue,
        valueOptions = valueOptions,
        label        = label,
        currentValue = effectiveValue,
        isUserFacing = isUserFacing,
        categoryKey  = categoryKey,
    }
    if isUserFacing then
        local parentKey = categoryKey or ROOT_KEY
        childrenByParent[parentKey] = childrenByParent[parentKey] or {}
        table.insert(childrenByParent[parentKey], key)
    end
    if persistedValue ~= nil then
        persistedValues[key] = persistedValue
    end
    if Log and Log.Info and isUserFacing then
        Log.Info("Settings: registered '" .. key .. "' = "
            .. tostring(effectiveValue)
            .. (persistedValue ~= nil and " (from disk)"
                or " (default)")
            .. (categoryKey and (" in '" .. categoryKey .. "'")
                or " at root"))
    end
end

--- RegisterTierPresets: declare a setting as participating in the
--- global verbosity preset system, and provide the preset values
--- for each tier (brief / normal / verbose).
---
--- When the user cycles the global verbosity dial, every registered
--- participant gets Settings.Set called with its tier value, batch-
--- overwriting individual customizations.
---
--- When the user changes an individual participant outside of a
--- preset application, isCustomized flips to true if the new value
--- doesn't match the current tier's preset, and the menu displays
--- "Custom" on the Global verbosity entry.
---
--- Settings that aren't registered here are preserved across global
--- cycles -- format choices, internal flags, etc.  Register only
--- the on/off settings (or scaled settings) that should be commanded
--- by the global dial.
---
--- The "verbosity" setting itself is NOT registered as a participant;
--- it's the driver.  ApplyVerbosityPreset reads its current value to
--- pick which preset to apply but doesn't try to set it.
---
--- @param key string  Setting key (must already have a RegisterDefault).
--- @param presets table  { brief = X, normal = Y, verbose = Z }.
function Settings.RegisterTierPresets(key, presets)
    tierPresets[key] = presets
end

--- ApplyVerbosityPreset: set every participating setting to the
--- preset value for the given tier.  Called automatically when the
--- user changes the "verbosity" setting via Settings.Set, but also
--- callable directly if you want to apply a preset programmatically.
---
--- Clears the customization flag at the end so the menu reads the
--- tier name (Brief / Normal / Verbose) rather than "Custom".
---
--- @param tier string  "brief", "normal", or "verbose".
function Settings.ApplyVerbosityPreset(tier)
    applyingPreset = true
    for key, presets in pairs(tierPresets) do
        local presetValue = presets[tier]
        if presetValue ~= nil then
            Settings.Set(key, presetValue)
        end
    end
    applyingPreset = false
    if Log and Log.Info then
        Log.Info("Settings: applied '" .. tostring(tier) .. "' preset")
    end
end

--- IsCustomized: true when any participating setting's current
--- value differs from the preset value for the current verbosity
--- tier.  Computed on demand from the actual stored values, so it
--- is correct immediately after a fresh load (no need for any
--- Set() to have fired yet).  Cheap -- iterates the handful of
--- registered tier-preset entries.
---
--- The SettingsMenu reads this to decide whether to display the
--- Global verbosity entry as "Brief / Normal / Verbose" (its
--- stored value) or "Custom" (deviation indicator).
function Settings.IsCustomized()
    local verbosityEntry = settingsRegistry["verbosity"]
    local currentTier = (verbosityEntry and verbosityEntry.currentValue)
        or "normal"
    for key, presets in pairs(tierPresets) do
        local presetValue = presets[currentTier]
        local entry = settingsRegistry[key]
        if presetValue ~= nil and entry then
            if entry.currentValue ~= presetValue then
                return true
            end
        end
    end
    return false
end

--- Get: read the current in-memory value of a setting.  Returns nil
--- if the key isn't registered.
function Settings.Get(key)
    local entry = settingsRegistry[key]
    if not entry then return nil end
    return entry.currentValue
end

--- Set: change a setting's in-memory value.  Validates against
--- valueOptions when present.  Marks the file dirty so Save() will
--- write.  No-op when the new value equals the current value.
---
--- Preset-system side effect: setting "verbosity" triggers
--- ApplyVerbosityPreset, which overwrites every participating
--- setting with that tier's preset value.  Skipped when
--- applyingPreset is true so ApplyVerbosityPreset's batch Set
--- calls don't cause reentrant self-triggers.
---
--- The "Custom" display state is computed on demand by
--- IsCustomized() rather than tracked as a cached flag, so it's
--- correct after a fresh load even when no Set has fired yet --
--- the persisted values themselves are the source of truth.
function Settings.Set(key, value)
    local entry = settingsRegistry[key]
    if not entry then return end
    if entry.currentValue == value then return end
    if entry.valueOptions then
        local valid = false
        for _, allowedValue in ipairs(entry.valueOptions) do
            if allowedValue == value then
                valid = true
                break
            end
        end
        if not valid then
            if Log and Log.Warn then
                Log.Warn("Settings: rejected invalid value '"
                    .. tostring(value) .. "' for key '" .. key
                    .. "' (not in valueOptions)")
            end
            return
        end
    end
    entry.currentValue = value
    persistedValues[key] = value
    pendingSave = true

    if applyingPreset then return end

    if key == "verbosity" then
        Settings.ApplyVerbosityPreset(value)
    end
end

--- Save: flush pending changes to disk.  No-op when nothing has
--- changed since the last save.
function Settings.Save()
    if not pendingSave then return end
    local saved = SaveToFile()
    if saved then
        pendingSave = false
        if Log and Log.Info then
            Log.Info("Settings: saved to " .. SETTINGS_FILE_PATH)
        end
    end
end

--- CycleNext: advance the current value to the next entry in
--- valueOptions, wrapping at the end.  Returns the new value.
function Settings.CycleNext(key)
    local entry = settingsRegistry[key]
    if not entry or not entry.valueOptions then return nil end
    local options = entry.valueOptions
    local currentIndex = 1
    for i, allowedValue in ipairs(options) do
        if allowedValue == entry.currentValue then
            currentIndex = i
            break
        end
    end
    local nextIndex = (currentIndex % #options) + 1
    Settings.Set(key, options[nextIndex])
    return entry.currentValue
end

--- CyclePrev: same as CycleNext but in reverse direction.
function Settings.CyclePrev(key)
    local entry = settingsRegistry[key]
    if not entry or not entry.valueOptions then return nil end
    local options = entry.valueOptions
    local currentIndex = 1
    for i, allowedValue in ipairs(options) do
        if allowedValue == entry.currentValue then
            currentIndex = i
            break
        end
    end
    local prevIndex = ((currentIndex - 2) % #options) + 1
    Settings.Set(key, options[prevIndex])
    return entry.currentValue
end

--- GetEntriesIn: return the ordered list of entry keys (settings or
--- categories) that are direct children of parentKey.  Pass
--- Settings.ROOT_KEY for the top level.  Used by SettingsMenu to
--- enumerate the current menu page.
function Settings.GetEntriesIn(parentKey)
    return childrenByParent[parentKey or ROOT_KEY] or {}
end

--- GetEntry: return the full registration entry for a key.  Works
--- for both settings (returns settingsRegistry[key]) and categories
--- (returns categoriesRegistry[key]); IsCategory disambiguates.
--- Returns nil for unknown keys.
function Settings.GetEntry(key)
    return settingsRegistry[key] or categoriesRegistry[key]
end

--- IsCategory: true when the key refers to a category, false when
--- it refers to a setting (or doesn't exist).  Used by SettingsMenu
--- to decide whether D-pad Left/Right cycles a value or A enters a
--- submenu.
function Settings.IsCategory(key)
    return categoriesRegistry[key] ~= nil
end

--- GetParentOf: return the parent category key for any entry.  For
--- root-level entries, returns ROOT_KEY.  Used by SettingsMenu's
--- "back" navigation to know where to return after exiting a
--- submenu.
function Settings.GetParentOf(key)
    local cat = categoriesRegistry[key]
    if cat then return cat.parentKey end
    local setting = settingsRegistry[key]
    if setting then return setting.categoryKey or ROOT_KEY end
    return nil
end

-- Built-in top-level categories.  Order here controls root menu
-- order.  Other modules' RegisterDefault calls reference these by
-- key.  Modules may RegisterCategory of their own to add new
-- categories later; these two cover the bulk of current settings.
--
-- Naming convention: category keys end in "Settings" (e.g.
-- "verbositySettings", "gpsSettings") so they can't collide with a
-- setting key.  A category and a setting with the same key produced
-- an infinite-drill bug (pressing A on the category drilled into a
-- submenu whose first child WAS the same key, which IsCategory then
-- treated as another category, etc.).  The Register* defenses above
-- now hard-fail on collision; the "Settings" suffix is the
-- convention that avoids tripping the assertion.
Settings.RegisterCategory("verbositySettings", "Verbosity settings")
Settings.RegisterCategory("gpsSettings", "GPS settings")


--- TrimTrailingZeroComponents: turn "0.1.3.0" into "0.1.3" by
--- dropping trailing ".0" segments.  Never trims below 2 components,
--- so "1.0.0.0" becomes "1.0" not just "1".  Matches the version
--- format users see in the auto-update announcement (UpdateNotice.lua
--- uses the same logic) so the two stay consistent.
local function TrimTrailingZeroComponents(versionString)
    if not versionString or versionString == "" then
        return versionString
    end
    local parts = {}
    for segment in string.gmatch(versionString, "[^.]+") do
        parts[#parts + 1] = segment
    end
    while #parts > 2 and parts[#parts] == "0" do
        parts[#parts] = nil
    end
    return table.concat(parts, ".")
end


--- GetModVersion: read the auto-generated _Version.lua module that
--- build_release.py writes into the mod folder during release staging.
--- Returns the version string ("0.1.3.0") or "(dev build)" if the
--- file is absent -- the latter signals a dev workspace where no
--- release has been built.
local function GetModVersion()
    local ok, version = pcall(Ext.Require, "Client/_Version.lua")
    if not ok or type(version) ~= "string" or version == "" then
        return "(dev build)"
    end
    return TrimTrailingZeroComponents(version)
end


-- About entry.  Sits at the root of the Settings menu (no category).
-- The "value" of the setting is the version string itself, so when the
-- user navigates to it the menu reads "About: 0.1.3" (DescribeEntry's
-- standard "Label: value" formatting).
--
-- valueOptions is a single-item list containing only the current
-- version so the entry registers as user-facing (the menu skips
-- entries whose valueOptions is nil) but D-pad Left/Right have only
-- one option to cycle to -- effectively read-only.
--
-- Settings.Set after RegisterDefault forces the stored value to the
-- current version, overriding any stale value persisted from a
-- previous release.  Without this, a user who installed v0.1.3 then
-- updated to v0.1.4 would still see "About: 0.1.3" until they cleared
-- their settings file -- RegisterDefault prefers a persisted value
-- over the default we pass in.
local modVersionString = GetModVersion()
Settings.RegisterDefault("about", modVersionString,
    { modVersionString }, "About")
Settings.Set("about", modVersionString)

BG3Access.Client.Settings = Settings

return Settings
