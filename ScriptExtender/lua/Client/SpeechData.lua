-- File: Client/SpeechData.lua
--
-- Standardized speech data module for BG3Access.
-- Replaces CreateSpeechData() from Helpers.lua.
--
-- All speech output flows through this module.  Handlers populate
-- semantic fields (name, value, description, etc.) and call Speak().
-- The formatter walks fields in a fixed order so speech output is
-- consistent regardless of insertion order.
--
-- Core fields (fixed output order):
--   1.  title                 -- page/screen/panel context
--   2.  sectionLabel          -- group header within a page
--   3.  navigationHint        -- how to navigate (once per visit)
--   4.  name                  -- focused item identity
--   5.  controlType           -- what the UI element is
--   6.  state                 -- UI state (Equipped, Selected, etc.)
--   7.  count                 -- stack quantity ("N available") for
--                                stackable items (potions, scrolls,
--                                ammo, duplicate equipment, ingredients,
--                                gold piles, bags/containers, etc.)
--   8.  value                 -- numeric value of focused thing
--   9.  position              -- where in a list (X of Y)
--  10.  status                -- transient state info
--  11.  technicalDescription  -- mechanical/functional description
--  12.  [properties]          -- key-value pairs (canonical order, see
--                                PROPERTY_ORDER below)
--  13.  description           -- longer flavor/explanatory text
--  14.  additionalDescription -- secondary explanatory text ("Also applies...")
--  15.  instructionHint       -- actionable hint at the END
--
-- Properties: AddProperty(label, value, tier) for flexible data
-- (Damage, Range, Cost, Weight, Gold, etc.) spoken as "label: value".
--
-- SpeakAlert: standalone function for background events (combat,
-- companion approval) that bypass the field system entirely.

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

local Log  -- set when module table is first accessed

-- Core fields in speech output order.
local CORE_FIELD_LIST = {
    "title",
    "sectionLabel",
    "navigationHint",
    "name",
    "controlType",
    "state",
    "count",
    "value",
    "position",
    "status",
    "technicalDescription",
    -- properties inserted here by Format()
    "description",
    "additionalDescription",
    "instructionHint",
}

-- O(1) validity check for core field names.
local CORE_FIELD_SET = {}
for _, fieldName in ipairs(CORE_FIELD_LIST) do
    CORE_FIELD_SET[fieldName] = true
end

-- Index in CORE_FIELD_LIST after which properties are inserted.
-- Currently points to "technicalDescription" (slot 11), so the
-- output order is: core 1..10 -> technicalDescription -> properties
-- -> description -> additionalDescription -> instructionHint.
local PROPERTIES_AFTER_INDEX = 11

-- Canonical output order for properties, by label.  Lower priority
-- = spoken earlier.  Labels not listed here fall to the end in
-- insertion order (via math.huge priority + stable sort).
--
-- Rationale (rough grouping):
--   10-19: item classification (Category, School)
--   20-39: primary stats (AC, main damage/heal range)
--   40-59: dice and attack mechanics
--   60-79: usage constraints (Single Use, Cost, Duration)
--   80-99: secondary mechanical info (breakdown, stats lines)
--   100-119: counts and grouped info (Reactions, ability lists)
--   120-139: ownership and character info
--   140-159: bookkeeping (Gold, Weight)
--   160+: meta/navigation (Equipped by, location, etc.)
local PROPERTY_ORDER = {
    -- Ownership/identity comes first -- sighted tooltip puts
    -- "Equipped by X" right under the item title, and it reads
    -- naturally as part of item identification.
    ["Equipped by"]       = 5,
    ["Category"]          = 10,
    ["School"]            = 15,
    ["Ability"]           = 20,
    ["Armour Class"]      = 30,
    ["Amount"]            = 35,
    ["Damage"]            = 40,
    ["Damage type"]       = 45,
    ["Healing"]           = 35,
    ["Dice"]              = 50,
    ["Bonus dice"]        = 55,
    ["Range"]             = 60,
    ["AoE radius"]        = 62,
    ["Radius"]            = 62,
    ["Attack type"]       = 65,
    ["Saving throw"]      = 70,
    ["Saving throws"]     = 70,
    ["Save"]              = 72,
    ["Save type"]         = 72,
    ["Casting"]           = 75,
    ["Concentration"]     = 78,
    ["Usage"]             = 80,
    ["Cost"]              = 85,
    ["Duration"]          = 88,
    ["Frequency"]         = 90,
    ["Cooldown"]          = 92,
    ["Breakdown"]         = 100,
    ["Stats"]             = 105,
    ["Weapon properties"] = 108,
    ["Effect"]            = 110,
    ["Property"]          = 115,
    ["Modifier"]          = 118,
    ["Total"]             = 120,
    ["Warning"]           = 122,
    ["Metamagic"]         = 125,
    ["Reactions"]         = 130,
    ["Reaction"]          = 132,
    ["Level"]             = 140,
    ["Class"]             = 142,
    -- "Status" used by TargetSelect.lua for the target's combat
    -- statuses (Threatened, Burning, etc.).  Sits between Level and
    -- HP so the speech reads "Devourer. Level: 1. Status: Threatened.
    -- HP: 9/15." -- mirroring the screen's nameplate-grouping order.
    ["Status"]            = 143,
    ["HP"]                = 145,
    ["Resource"]          = 148,
    ["Round"]             = 149,
    ["Gold"]              = 150,
    ["Weight"]            = 155,
    ["Info"]              = 180,
    -- Italic flavor text Larian renders at the bottom of tooltips
    -- (legendary item quotes, some passive features).  Lowest of the
    -- listed priorities so it speaks last among properties, just
    -- before the description field.  Verbose tier in handlers'
    -- AddProperty calls so it only speaks at the deepest verbosity.
    ["Lore"]              = 200,
}

-- Pattern-based priority fallback for dynamically-built labels that
-- can't be enumerated in PROPERTY_ORDER (e.g. action-prefixed hit
-- chance like "Fire Bolt hit chance" or "Main Hand Attack hit
-- chance").  Checked AFTER exact match in PROPERTY_ORDER and AFTER
-- per-instance overrides, before falling to math.huge.  Patterns are
-- Lua patterns; first match wins.
local PROPERTY_ORDER_PATTERNS = {
    -- Action-prefixed hit chance.  Sits at 150 so it speaks just
    -- after HP (145) and before the target-context Damage override
    -- (155 set by TargetSelect.lua).
    {pattern = " hit chance$", priority = 150},
}

--- Resolve the sort priority for a property label.
--- @param label string  The property's label (or empty string).
--- @param instanceOverrides table|nil  Optional {[label]=priority}
---     map set by the caller via SpeechData.priorityOverrides.
---     Wins over PROPERTY_ORDER and patterns.
--- @return number  Priority (lower = spoken earlier; math.huge if
---     unmapped, in which case insertion order resolves ties).
local function LookupPropertyPriority(label, instanceOverrides)
    if instanceOverrides and instanceOverrides[label] then
        return instanceOverrides[label]
    end
    if PROPERTY_ORDER[label] then
        return PROPERTY_ORDER[label]
    end
    if label and label ~= "" then
        for _, entry in ipairs(PROPERTY_ORDER_PATTERNS) do
            if label:find(entry.pattern) then
                return entry.priority
            end
        end
    end
    return math.huge
end

-- Verbosity tier ranks.  Lower = more essential.
local TIER_RANK = {brief = 1, normal = 2, verbose = 3}

-- Global verbosity.  Format() filters out fields/properties whose
-- tier exceeds this.  Callers can override per-call by passing an
-- explicit verbosity to Format(); when omitted, the global is used.
-- Cycled at runtime via the RS-Down controller chord (see
-- BG3Access.Client.CycleVerbosity below).
local currentVerbosity = "verbose"

-- Global hint toggle.  When false, Format() omits hint fields.
local hintsEnabled = true

-- Strip XML/markup tags.
local function StripMarkupTags(text)
    if not text then return nil end
    return text:gsub("<[^>]+>", "")
end

-- Normalize for value comparison (lowercase, strip spaces/hyphens/dots).
local function NormalizeForCompare(text)
    if not text then return "" end
    return text:lower():gsub("[%s%-%.]+", "")
end

--- Detect binary garbage that sometimes leaks through Noesis reads
--- of stale / freed elements (C++ SEH catches the crash but not the
--- bogus return value -- we see "dead object in ToString" logs
--- followed by random memory interpreted as a string).  Speaking
--- that garbage is both useless and irritating.
---
--- Check: any control character below 0x20 that ISN'T whitespace
--- (tab 0x09, LF 0x0A, CR 0x0D) indicates non-text content.
--- Legitimate game strings -- even fully localized with accents,
--- CJK, etc. -- never carry these bytes.  High-bit bytes alone are
--- NOT a garbage signal (UTF-8 uses them for non-ASCII text).
local function LooksLikeBinaryGarbage(text)
    if type(text) ~= "string" or text == "" then return false end
    for i = 1, #text do
        local byte = string.byte(text, i)
        if byte < 0x20
            and byte ~= 0x09   -- tab
            and byte ~= 0x0A   -- LF
            and byte ~= 0x0D   -- CR
        then
            return true
        end
    end
    return false
end

-- ============================================================================
-- SpeechData instance methods (attached to each created object)
-- ============================================================================

-- Forward-declare Create so Delta/Diff can call it.
local Create

--- Add a core field.
--- @param self table  The SpeechData object.
--- @param fieldName string  One of the 15 core field names in CORE_FIELD_LIST.
--- @param fieldValue string|nil  Text to speak.  Nil/empty skipped.
--- @param tier string|nil  "brief", "normal", or "verbose" (default "normal").
local function Add(self, fieldName, fieldValue, tier)
    if not fieldValue or fieldValue == "" then return end
    if LooksLikeBinaryGarbage(fieldValue) then
        if Log then
            Log.Warn("SpeechData: dropped binary garbage from field '"
                .. tostring(fieldName)
                .. "' (likely stale Noesis read)")
        end
        return
    end
    if not CORE_FIELD_SET[fieldName] then
        if Log then
            Log.Warn("SpeechData: unknown core field '"
                .. tostring(fieldName)
                .. "', use AddProperty() for custom data")
        end
        return
    end
    self.coreFields[fieldName] = fieldValue
    self.tiers[fieldName] = tier or "normal"
end

--- Add a flexible property (spoken as "label: value").
--- @param self table  The SpeechData object.
--- @param label string  User-facing label (e.g., "Damage", "Range").
--- @param propertyValue string|nil  The value.  Nil/empty skipped.
--- @param tier string|nil  "brief", "normal", or "verbose" (default "normal").
local function AddProperty(self, label, propertyValue, tier)
    if not propertyValue or propertyValue == "" then return end
    if LooksLikeBinaryGarbage(propertyValue) then
        if Log then
            Log.Warn("SpeechData: dropped binary garbage from property '"
                .. tostring(label)
                .. "' (likely stale Noesis read)")
        end
        return
    end
    self.properties[#self.properties + 1] = {
        label = label,
        value = propertyValue,
        tier = tier or "normal",
    }
end

--- Check if a core field is populated, or any property has the given label.
--- @param self table  The SpeechData object.
--- @param fieldName string  Core field name or property label.
--- @return boolean
local function HasField(self, fieldName)
    if self.coreFields[fieldName] ~= nil then return true end
    for _, prop in ipairs(self.properties) do
        if prop.label == fieldName then return true end
    end
    return false
end

--- Remove all properties with the given label.  Used by handlers
--- to drop redundant or mislabeled entries after FromTooltip (e.g.
--- strip a duplicate armor-display label, remove a property that
--- duplicates a Category value).
--- @param self table  The SpeechData object.
--- @param label string  The property label to remove.
local function RemoveProperty(self, label)
    local kept = {}
    for _, prop in ipairs(self.properties) do
        if prop.label ~= label then
            kept[#kept + 1] = prop
        end
    end
    self.properties = kept
end

--- Remove all properties where predicate(prop) returns true.
--- The predicate receives {label, value, tier} and returns boolean.
--- Used for handler-specific filtering (duplicate-value removal,
--- aggregation into a count, etc.).
--- @param self table  The SpeechData object.
--- @param predicate function  Function(prop) -> boolean.
local function RemoveProperties(self, predicate)
    local kept = {}
    for _, prop in ipairs(self.properties) do
        if not predicate(prop) then
            kept[#kept + 1] = prop
        end
    end
    self.properties = kept
end

--- Clear a core field and its associated tier.  Companion to
--- RemoveProperty for the 15 core fields (title, sectionLabel,
--- name, controlType, ...).  Used by handlers that need to drop
--- a field FromTooltip set but the handler considers redundant
--- in its specific context (e.g. VMAbility formatter dropping
--- the AbilityModifiersLabel sectionLabel because the synthesized
--- Breakdown property already conveys the same context).
--- @param self table  The SpeechData object.
--- @param fieldName string  Core field name (must be in CORE_FIELD_SET).
local function RemoveCoreField(self, fieldName)
    if not CORE_FIELD_SET[fieldName] then
        if Log then
            Log.Warn("SpeechData: RemoveCoreField on unknown core field '"
                .. tostring(fieldName) .. "'")
        end
        return
    end
    self.coreFields[fieldName] = nil
    self.tiers[fieldName] = nil
end

--- Build the spokenRoles map key for a property.  Properties are
--- keyed by "property:<label>:<NORMALIZED value>" so multiple entries
--- sharing a label (e.g. PropertyText emitting Melee + Light + Finesse
--- all with label "Property") each get their own slot, AND so
--- formatting variations of the same value (trailing whitespace, casing)
--- collapse to one slot.
local function PropertyKey(label, value)
    return "property:" .. label .. ":" .. NormalizeForCompare(value)
end

--- Cross-off rule for tooltip role lookup.  See FromTooltip's
--- header docstring for the full key-scheme description.  Returns
--- true when an incoming entry should be suppressed.
---
--- Comparison is normalization-based (NormalizeForCompare strips
--- whitespace/punctuation/case) so trailing-period and casing
--- mismatches between the row's stored text and the tooltip's
--- rendered text don't defeat the cross-off.
local function ShouldSkipSpoken(spoken, key, entryText)
    if not spoken then return false end
    local prevValue = spoken[key]
    if prevValue == nil then return false end
    if prevValue == true then return true end  -- wildcard
    if type(prevValue) ~= "string" then return false end
    return NormalizeForCompare(prevValue) == NormalizeForCompare(entryText)
end

--- Populate a spokenRoles map with this SpeechData's field keys
--- and values.  Mirrors the recording done inside Speak() so callers
--- that bypass Speak (rare) can still feed the cross-off mechanism.
---
--- Keys written:
---   <fieldName>             for each populated core field.
---   property:<label>        for each property.
---
--- Values written: NormalizeForCompare-normalized rendered text.
--- ShouldSkipSpoken normalizes the incoming entryText too at compare
--- time, so trailing-whitespace / casing / punctuation differences
--- between sources (API row text vs XAML rendering) don't break the
--- cross-off.  Pre-mark with the literal `true` for wildcard skip
--- regardless of value.
---
--- @param self table  The SpeechData object.
--- @param spokenRoles table  Map to populate (key -> normalized value
---     for core fields, or `true` for property keys / wildcards).
local function PopulateSpokenRoles(self, spokenRoles)
    for fieldName, fieldValue in pairs(self.coreFields) do
        spokenRoles[fieldName] = NormalizeForCompare(fieldValue)
    end
    for _, prop in ipairs(self.properties) do
        spokenRoles[PropertyKey(prop.label, prop.value)] = true
    end
end

--- Reassign property tiers via a predicate.  Predicate receives
--- {label, value, tier} and returns either a new tier string ("brief",
--- "normal", "verbose") or nil to leave the tier unchanged.  Used by
--- handlers that need to apply a context-specific tier policy after
--- FromTooltip's universal-map classification (e.g. radial fallback
--- demoting non-damage properties to verbose so brief/normal stay
--- terse, while keeping the universal map's tier values intact for
--- panel use).
--- @param self table  The SpeechData object.
--- @param predicate function  Function(prop) -> string|nil.
local function RetierProperties(self, predicate)
    for _, prop in ipairs(self.properties) do
        local newTier = predicate(prop)
        if newTier then
            prop.tier = newTier
        end
    end
end

--- Rename all properties with label `fromLabel` to `toLabel`.
--- Used by handlers that need DC-type-specific relabeling of a
--- generic FromTooltip label (e.g. "Property" -> "Breakdown" for
--- stat tooltips, "Property" -> "Effect" for ability tooltips).
--- @param self table  The SpeechData object.
--- @param fromLabel string  The current label.
--- @param toLabel string  The new label.
local function RelabelProperty(self, fromLabel, toLabel)
    for _, prop in ipairs(self.properties) do
        if prop.label == fromLabel then
            prop.label = toLabel
        end
    end
end

--- Delta: return a new SpeechData with only fields that changed
--- or were added compared to `previous`.  Used for INPC value-only
--- updates so only the changed part is spoken.
--- @param self table  The new SpeechData.
--- @param previous table|nil  The previous SpeechData.
--- @return table  New SpeechData with only changed/new fields.
local function Delta(self, previous)
    if not previous then return self end
    local result = Create()

    -- Compare core fields.
    for fieldName, fieldValue in pairs(self.coreFields) do
        local previousValue = previous.coreFields
            and previous.coreFields[fieldName]
        if not previousValue
            or NormalizeForCompare(fieldValue)
                ~= NormalizeForCompare(previousValue) then
            result:Add(fieldName, fieldValue, self.tiers[fieldName])
        end
    end

    -- Handle state removal: "Equipped" removed -> "Unequipped".
    if previous.coreFields and previous.coreFields["state"]
        and not self.coreFields["state"] then
        local previousState = previous.coreFields["state"]
        if previousState == "Equipped" then
            result:Add("state", "Unequipped", "brief")
        end
    end

    -- Properties: include only new or changed labels.  Build a
    -- lookup of previous properties by label, then scan self for
    -- entries that are new or whose normalized value differs.
    local previousProperties = {}
    if previous.properties then
        for _, prop in ipairs(previous.properties) do
            previousProperties[prop.label] = prop.value
        end
    end
    for _, prop in ipairs(self.properties) do
        local previousValue = previousProperties[prop.label]
        if not previousValue
            or NormalizeForCompare(prop.value)
                ~= NormalizeForCompare(previousValue) then
            result:AddProperty(prop.label, prop.value, prop.tier)
        end
    end

    return result
end

--- Diff: return a new SpeechData with only fields/properties that
--- aren't suppressed by `other`.  Uses the SAME scoped-key cross-off
--- as ShouldSkipSpoken (no flat value-set), so cross-field collisions
--- can't occur (e.g. an item's Count="10" no longer accidentally
--- suppresses a tooltip's Damage="10").
---
--- For each field in self, look up by (scoped) key in other:
---   - Core field key = field name.  Suppress if other's same field
---     has a normalized value matching self's.
---   - Property key = "property:label:NormalizedValue" (PropertyKey).
---     Suppress if other has the same (label, normalized-value) pair.
---
--- Mirrors how Speak's accumulate populates handlerState.spokenRoles
--- after every speech.  One rule, no parallel cross-off paths.
---
--- @param self table  The tooltip SpeechData.
--- @param other table|nil  The handler's SpeechData (or any prior
---     SpeechData to dedup against).
--- @return table  New SpeechData with unmatched fields only.
local function Diff(self, other)
    if not other then return self end

    -- Build the same kind of map Speak's auto-accumulate produces:
    -- core fields keyed by name -> normalized value, properties keyed
    -- by PropertyKey -> true.
    local scopedMap = {}
    if other.coreFields then
        for fieldName, fieldValue in pairs(other.coreFields) do
            scopedMap[fieldName] = NormalizeForCompare(fieldValue)
        end
    end
    if other.properties then
        for _, prop in ipairs(other.properties) do
            scopedMap[PropertyKey(prop.label, prop.value)] = true
        end
    end

    local result = Create()
    for fieldName, fieldValue in pairs(self.coreFields) do
        if not ShouldSkipSpoken(scopedMap, fieldName, fieldValue) then
            result:Add(fieldName, fieldValue, self.tiers[fieldName])
        end
    end
    for _, prop in ipairs(self.properties) do
        if not ShouldSkipSpoken(scopedMap,
            PropertyKey(prop.label, prop.value), prop.value) then
            result:AddProperty(prop.label, prop.value, prop.tier)
        end
    end
    return result
end

--- Format: assemble fields into a speech string in fixed order.
--- Properties are inserted between status and description.
--- @param self table  The SpeechData object.
--- @param verbosity string|nil  "brief", "normal", or "verbose".
---     When nil, falls back to the module-global currentVerbosity
---     (set via SpeechData.SetVerbosity / CycleVerbosity).  Explicit
---     arg overrides the global per-call if callers ever need it.
--- @return string|nil  Assembled speech, or nil if empty.
local function Format(self, verbosity)
    verbosity = verbosity or currentVerbosity
    local maxRank = TIER_RANK[verbosity] or 3
    local parts = {}

    -- Walk core fields in defined order.
    for fieldIndex, fieldName in ipairs(CORE_FIELD_LIST) do
        local fieldValue = self.coreFields[fieldName]
        if fieldValue then
            local include = false
            if fieldName == "title" or fieldName == "sectionLabel" then
                -- Always included regardless of verbosity.
                include = true
            elseif fieldName == "navigationHint"
                or fieldName == "instructionHint" then
                -- Globally toggleable.
                include = hintsEnabled
            else
                local fieldRank = TIER_RANK[self.tiers[fieldName]] or 2
                include = fieldRank <= maxRank
            end
            if include then
                local cleaned = fieldValue:gsub("[%.%s]+$", "")
                if cleaned ~= "" then
                    parts[#parts + 1] = cleaned
                end
            end
        end

        -- Insert properties after technicalDescription, before
        -- description.  Sort by canonical PROPERTY_ORDER (stable
        -- fallback to insertion order for unmapped labels).
        if fieldIndex == PROPERTIES_AFTER_INDEX then
            local sortedProps = {}
            for insertIndex, prop in ipairs(self.properties) do
                sortedProps[#sortedProps + 1] = {
                    prop = prop,
                    priority = LookupPropertyPriority(
                        prop.label, self.priorityOverrides),
                    insertIndex = insertIndex,
                }
            end
            table.sort(sortedProps, function(firstEntry, secondEntry)
                if firstEntry.priority ~= secondEntry.priority then
                    return firstEntry.priority < secondEntry.priority
                end
                return firstEntry.insertIndex < secondEntry.insertIndex
            end)
            for _, sortedEntry in ipairs(sortedProps) do
                local prop = sortedEntry.prop
                local propRank = TIER_RANK[prop.tier] or 2
                if propRank <= maxRank then
                    -- Empty/nil label = render just the value as a
                    -- standalone phrase.  Used for self-explanatory
                    -- context text that doesn't need a field prefix
                    -- (e.g. "Target is too close" for disadvantage
                    -- reasons -- the phrase IS the explanation).
                    local propText
                    if prop.label and prop.label ~= "" then
                        propText = prop.label .. ": " .. prop.value
                    else
                        propText = prop.value
                    end
                    propText = propText:gsub("[%.%s]+$", "")
                    if propText ~= "" then
                        parts[#parts + 1] = propText
                    end
                end
            end
        end
    end

    if #parts == 0 then return nil end
    return StripMarkupTags(table.concat(parts, ". "))
end

--- SpeakDelta: speak only what changed vs a prior SpeechData,
--- but record the FULL self into handlerState.  Used by handlers
--- that re-speak the same focused element repeatedly as its
--- properties update (e.g. an alchemy expander whose IsChecked
--- toggles, an INPC-driven slider value): the user wants to hear
--- only the delta ("expanded" or "+5") rather than the entire
--- entity restated, but the next delta computation needs the
--- full current state as the baseline.
---
--- Differs from Speak() in that the spoken text is the delta
--- but the recorded handlerState.spokenRoles + lastSpokenFullText
--- reflect the FULL self.  This way tooltip cross-off references
--- "everything currently true about this focus", and the next
--- delta call diffs against the right baseline.
---
--- @param self table  The SpeechData object (full current state).
--- @param handlerState table  Handler's isolated state.
--- @param previousSpeechData table|nil  Prior SpeechData to diff
---     against (typically handlerState.previousSpeechData).
--- @param isScreenEntry boolean  Whether this is a screen entry.
--- @param verbosity string|nil  Verbosity level.
--- @param userInitiated boolean|nil  True when user navigated.
--- @param logTag string|nil  Log prefix (default "DELTA SPEAK").
local function SpeakDelta(self, handlerState, previousSpeechData,
                          isScreenEntry, verbosity, userInitiated,
                          logTag)
    local delta = self:Delta(previousSpeechData)
    local deltaAssembled = delta:Format(verbosity)

    -- Always record the full state (lastSpokenFullText + spokenRoles)
    -- regardless of whether the delta produced spoken output.  The
    -- next delta needs this as its baseline; tooltip cross-off needs
    -- the full set of currently-spoken roles.
    local fullAssembled = self:Format(verbosity)
    if fullAssembled and fullAssembled ~= "" then
        handlerState.lastSpokenFullText = fullAssembled
    end
    if not handlerState.spokenRoles then
        handlerState.spokenRoles = {}
    end
    for fieldName, fieldValue in pairs(self.coreFields) do
        handlerState.spokenRoles[fieldName] = NormalizeForCompare(fieldValue)
    end
    for _, prop in ipairs(self.properties) do
        handlerState.spokenRoles[
            PropertyKey(prop.label, prop.value)] = true
    end

    if not deltaAssembled or deltaAssembled == "" then return end

    local interrupt = isScreenEntry or (userInitiated == true)
    Log.Info((logTag or "DELTA SPEAK")
        .. (interrupt and "" or " (append)")
        .. ": " .. deltaAssembled)
    Ext.Tolk.Speak(deltaAssembled, interrupt)
end

--- Speak: format and speak with interrupt logic.  Accumulates
--- spoken role keys onto handlerState.spokenRoles for tooltip
--- cross-off.  Callers control reset by clearing
--- handlerState.spokenRoles at focus / selection boundaries
--- (via the panel factory's RecordSpokenRoles or by direct
--- assignment); within one focus, every Speak / tooltip Speak
--- adds to the set so the cross-off correctly suppresses fields
--- across multiple speech events on the same focus.
--- @param self table  The SpeechData object.
--- @param handlerState table  Handler's isolated state.
--- @param isScreenEntry boolean  Whether this is a screen entry.
--- @param verbosity string|nil  Verbosity level (default "verbose").
--- @param userInitiated boolean|nil  True when user navigated.
--- @param logTag string|nil  Log prefix (default "SPEAK").  Allows
---     callers like the radial path to keep their distinct log
---     prefix ("RADIAL [HotBar]", "TOOLTIP (radial fallback)") for
---     debugging while still going through the architectural Speak.
--- Returns the assembled text on emit, or nil if nothing was
--- spoken (empty SpeechData / cross-off skipped everything).
--- Callers can use the return value to gate state-change
--- detection ("did a tooltip actually speak on this focus").
local function Speak(self, handlerState, isScreenEntry, verbosity,
                     userInitiated, logTag)
    local assembled = self:Format(verbosity)
    if not assembled or assembled == "" then return nil end

    -- Interrupt on user-initiated events or screen entries.
    -- System events (widget scans, post-settle) append.
    local interrupt = isScreenEntry or (userInitiated == true)

    -- Loading tips / visual-only text: always append so tips queue.
    if not userInitiated
        and self.coreFields["description"]
        and not self.coreFields["title"]
        and not self.coreFields["navigationHint"]
        and not self.coreFields["name"] then
        interrupt = false
    end

    Log.Info((logTag or "SPEAK")
        .. (interrupt and "" or " (append)")
        .. ": " .. assembled)
    Ext.Tolk.Speak(assembled, interrupt)
    handlerState.lastSpokenFullText = assembled

    -- Accumulate spoken role keys + values.  Caller is responsible
    -- for resetting handlerState.spokenRoles at context boundaries
    -- (focus / selection change, screen entry).  Within one focus,
    -- multiple Speaks (initial focus speech + each progressive-
    -- load tooltip wave) build up the map so subsequent FromTooltip
    -- calls do value-aware cross-off (skip on match, emit on
    -- state change -- see ShouldSkipSpoken).
    if not handlerState.spokenRoles then
        handlerState.spokenRoles = {}
    end
    for fieldName, fieldValue in pairs(self.coreFields) do
        handlerState.spokenRoles[fieldName] = NormalizeForCompare(fieldValue)
    end
    for _, prop in ipairs(self.properties) do
        handlerState.spokenRoles[
            PropertyKey(prop.label, prop.value)] = true
    end
    return assembled
end

-- ============================================================================
-- Constructor
-- ============================================================================

--- Create a new SpeechData instance.
--- @return table  SpeechData object with Add, AddProperty, HasField,
---     Delta, Diff, Format, Speak methods.
Create = function()
    return {
        coreFields = {},
        properties = {},
        tiers = {},
        Add = Add,
        AddProperty = AddProperty,
        HasField = HasField,
        RemoveProperty = RemoveProperty,
        RemoveProperties = RemoveProperties,
        RemoveCoreField = RemoveCoreField,
        RetierProperties = RetierProperties,
        RelabelProperty = RelabelProperty,
        PopulateSpokenRoles = PopulateSpokenRoles,
        Delta = Delta,
        Diff = Diff,
        Format = Format,
        Speak = Speak,
        SpeakDelta = SpeakDelta,
    }
end

-- ============================================================================
-- Module-level functions
-- ============================================================================

local SpeechDataModule = {}

--- Create a new SpeechData instance.
SpeechDataModule.Create = Create

--- SpeakAlert: standalone function for background events.
--- Bypasses the SpeechData field system entirely.
--- @param text string  The text to speak.
--- @param priority string  "interrupt" or "queue".
function SpeechDataModule.Alert(text, priority)
    if not text or text == "" then return end
    if LooksLikeBinaryGarbage(text) then
        if Log then
            Log.Warn("SpeechData.Alert: dropped binary garbage"
                .. " (likely stale Noesis read)")
        end
        return
    end
    local interrupt = (priority == "interrupt")
    Log.Info("ALERT"
        .. (interrupt and "" or " (queue)")
        .. ": " .. text)
    Ext.Tolk.Speak(text, interrupt)
end

-- ============================================================================
-- Shared tooltip role mapping
-- ============================================================================
--
-- Universal mapping from XAML x:Name roles to SpeechData fields.
-- This is a fact about the XAML templates, not a handler decision.
-- Handlers call FromTooltip() to get a SpeechData, then do
-- handler-specific post-processing (label overrides, extra properties).

-- x:Name -> {field, label, tier}.
-- field = core field name for :Add(), or "property" for :AddProperty().
-- label = property label (only used when field == "property").
local TOOLTIP_ROLE_MAP = {
    -- Title variants -> name (the item/spell/ability identity).
    Title              = {field = "name",        tier = "brief"},
    TitleName          = {field = "name",        tier = "brief"},
    TitleText          = {field = "name",        tier = "brief"},
    TitleArea          = {field = "name",        tier = "brief"},

    -- Description variants -> description.  The XAML uses both
    -- TitleCase and camelCase variants of the same name across
    -- different templates; map both.
    ContentText        = {field = "description", tier = "verbose"},
    contentText        = {field = "description", tier = "verbose"},
    BaseDescription    = {field = "description", tier = "verbose"},
    baseDescription    = {field = "description", tier = "verbose"},
    -- TechnicalDescription is the mechanical "what it does" text
    -- (own core field so it doesn't collide with flavor description).
    -- Tier "normal" -- this is gameplay-essential (damage numbers,
    -- save rules, effect descriptions), not flavor prose.
    TechnicalDescription  = {field = "technicalDescription",
                             tier = "normal"},
    technicalDescription  = {field = "technicalDescription",
                             tier = "normal"},

    -- Additional description (secondary "also applies" text).
    AdditionalDescription = {field = "additionalDescription",
                          tier = "verbose"},
    -- SubTitleContainer is the item subtype shown under the title
    -- (e.g. "Light Armour").  Map to a "Category" property so it
    -- doesn't collide with the flavor description from ContentText.
    -- Tier "normal" (not "brief"): the slot navigation already
    -- announced item identity (e.g. "Off Hand: Studded Shield"),
    -- so the category is meaningful detail, not bare-bones info.
    SubTitleContainer  = {field = "property", label = "Category",
                          tier = "normal"},
    subtitleText       = {field = "property", label = "Category",
                          tier = "normal"},

    -- Description variants (additional templates).
    ExtraDescription   = {field = "description", tier = "verbose"},
    Description        = {field = "description", tier = "verbose"},
    DescriptionText    = {field = "description", tier = "verbose"},
    PassiveExtraDescription = {field = "description", tier = "verbose"},
    -- Generic tooltip body role (XP bar, Class, Race, Background
    -- tooltips put their body text under this role).
    tooltipContent     = {field = "description", tier = "verbose"},
    -- Character sheet ProficiencyGroup expander headers (Simple
    -- Weapons / Martial Weapons / Armours).  XAML
    -- PreloadedCharacterPanel_c.xaml:1541 -- a TextBlock whose
    -- bound text changes per group via DataTriggers.  Pure
    -- explanatory body text ("Most people can use simple Weapons
    -- with Proficiency...") -- belongs in description, not as a
    -- property labeled with the raw XAML name.
    ProficiencyGroupTooltip = {field = "description",
                          tier = "verbose"},

    -- Value field.
    SkillValue         = {field = "value",       tier = "brief"},

    -- Property entries (formatted as "label: value").
    --
    -- DamageLabel / SpellDamageText: XAML renders the value with the
    -- type word baked in ("1 to 4 Damage" or "1d4 Damage").  Strip
    -- the trailing word so "Damage: 1 to 4 Damage" doesn't double
    -- the noun.  Same transform damageDisplayText already uses.
    DamageLabel        = {field = "property", label = "Damage",
                          tier = "normal",
                          transform = function(text)
                              return (text:gsub(
                                  "%s+[Dd]amage$", "")
                                  :gsub("%s+[Hh]ealing$", ""))
                          end},
    SpellDamageText    = {field = "property", label = "Damage",
                          tier = "normal",
                          transform = function(text)
                              return (text:gsub(
                                  "%s+[Dd]amage$", "")
                                  :gsub("%s+[Hh]ealing$", ""))
                          end},
    DiceValue          = {field = "property", label = "Dice",
                          tier = "normal"},
    DamageType         = {field = "property", label = "Damage type",
                          tier = "normal"},
    EquippedByText     = {field = "property", label = "Equipped by",
                          tier = "brief",
                          -- XAML renders "Equipped by {character}";
                          -- strip the prefix so the label doesn't
                          -- double-print ("Equipped by: Equipped by Tav").
                          transform = function(text)
                              return (text:gsub(
                                  "^Equipped by%s+", ""))
                          end},
    -- Weight and Gold are factual bookkeeping that the user typically
    -- only wants when they're explicitly evaluating an item (compare
    -- view, merchant decisions).  At normal tier, equipment-slot
    -- navigation should be terse -- "what is this and what does it
    -- do" -- not "what does it weigh".  Verbose tier exposes both.
    weightText         = {field = "property", label = "Weight",
                          tier = "verbose"},
    GoldContainer      = {field = "property", label = "Gold",
                          tier = "verbose"},
    -- ArmorText carries the AC value; the label "Armour Class" is
    -- duplicated in the separate armorDisplay TextBlock which
    -- equipment handlers should drop after FromTooltip.  Tier
    -- "normal" -- AC is meaningful detail (the headline armor stat),
    -- equivalent to the Damage prose for weapons.  Brief tier stays
    -- terse with just identifying info ("Equipped by: X").
    ArmorText          = {field = "property", label = "Armour Class",
                          tier = "normal"},
    -- DamageRange: the calculated min-max for attack or heal effects.
    -- Value embeds the context word (e.g. "4 to 10 Healing" or
    -- "4 to 9 Damage"), so we use a neutral "Amount" label.  Handlers
    -- can post-process for item-specific phrasing.
    DamageRange        = {field = "property", label = "Amount",
                          tier = "brief"},
    -- damageDisplayText: VMItem weapon tooltip's calculated damage
    -- range.  Complements the DamageLabel dice notation (1d6+3) with
    -- the computed min-max (4 to 9).  Value bakes the type word in
    -- ("4 to 9 Damage"); strip it so "Range: 4 to 9" doesn't repeat
    -- the Damage type: entry that follows.
    damageDisplayText  = {field = "property", label = "Range",
                          tier = "normal",
                          transform = function(text)
                              return (text:gsub(
                                  "%s+[Dd]amage$", "")
                                  :gsub("%s+[Hh]ealing$", ""))
                          end},
    -- FooterItem: bottom-of-tooltip entries like "Bonus Action",
    -- "Action", "Reaction".  Typically action cost.
    FooterItem         = {field = "property", label = "Cost",
                          tier = "normal"},
    -- ReactionStatusText: trigger mode shown on the reaction
    -- tooltip (Reactions tab in character sheet, in-combat
    -- reaction popup).  Values are user-facing strings: "Will
    -- not trigger" / "Trigger automatically" / "Ask".  Maps to
    -- the state core field so the user hears the toggle state
    -- alongside the reaction's name and description.  Speaks on
    -- focus arrival AND on tooltip refresh after A/X toggle.
    ReactionStatusText = {field = "state", tier = "brief"},
    PropertyText       = {field = "property", label = "Property",
                          tier = "normal"},
    SectionDuration    = {field = "property", label = "Duration",
                          tier = "normal"},
    AbilityModifierDesc = {field = "property", label = "Modifier",
                          tier = "normal"},
    SavingThrows       = {field = "property", label = "Saving throws",
                          tier = "normal"},
    ClassAndLevel      = {field = "property", label = "Level",
                          tier = "brief",
                          -- "Lv 1 Rogue" is UI shorthand; the
                          -- "Level" label makes "Lv" redundant.
                          transform = function(text)
                              return (text:gsub("^Lv%s+", ""))
                          end},

    -- HealthText: HP values in character tooltips (SelectionFlyOut
    -- search menu, character-under-cursor hover, etc.).  XAML
    -- renders the value as "N/M"; transform to natural-language
    -- "N of M" so TTS doesn't speak the slash character.
    HealthText         = {field = "property", label = "HP",
                          tier = "brief",
                          transform = function(text)
                              return (text:gsub(
                                  "(%d+)%s*/%s*(%d+)", "%1 of %2"))
                          end},

    -- MovementText: remaining movement for the character.  XAML
    -- renders "N /Mm" (note the space before the slash and the
    -- trailing unit letter); transform to "N of M metres".
    MovementText       = {field = "property", label = "Movement",
                          tier = "brief",
                          transform = function(text)
                              return (text:gsub(
                                  "(%d+)%s*/%s*(%d+)m",
                                  "%1 of %2 metres"))
                          end},

    -- Texts: status / condition badges on a character tooltip
    -- (e.g. "Dead", "Unconscious", "Burning", "Poisoned").  XAML
    -- x:Name is pluralized because this renders an ItemsControl
    -- of conditions, not a single TextBlock.  "Status" as the
    -- spoken label fits both single and multiple values.
    Texts              = {field = "property", label = "Status",
                          tier = "normal"},

    -- Alchemy ingredient / product tooltip block.  XAML uses
    -- AlchemyTitle (the alchemy category), AlchemyResultName
    -- (the item produced), AlchemyResultType (the category of
    -- the produced item).  All three appear when hovering an
    -- alchemy ingredient in the search flyout or inventory.
    AlchemyTitle       = {field = "property", label = "Category",
                          tier = "brief"},
    AlchemyResultName  = {field = "property", label = "Result",
                          tier = "normal"},
    AlchemyResultType  = {field = "property", label = "Result type",
                          tier = "normal"},

    -- PassiveInfo: the passive / ingredient description block on
    -- an item (e.g. "Alchemical Ingredient: Combine 3 of these to
    -- calcinate them into Ashes").  The game's own text embeds an
    -- inline prefix ("Alchemical Ingredient: ...") that serves as
    -- the visible label for sighted players -- there is no
    -- external "Passive:" / "Info:" label on screen.  Mapping to
    -- additionalDescription keeps that parity: no added label,
    -- and it doesn't collide with the flavor description slot
    -- that the item-focus speech already claims (so cross-off
    -- doesn't suppress it).
    PassiveInfo        = {field = "additionalDescription",
                          tier = "normal"},
    -- Note: "txt" is deliberately NOT in this map.  It's a generic
    -- XAML x:Name reused across many templates (CC spell tooltips
    -- show "Evocation Cantrip" under it, party-line tooltips show
    -- "Level Up" under it).  Handlers post-process it per context.
    AbilityName        = {field = "property", label = "Ability",
                          tier = "normal"},
    -- Introductory label before a breakdown list.  Handlers may
    -- post-process the following Value/Description entries into a
    -- single breakdown string.
    AbilityModifiersLabel = {field = "sectionLabel",
                          tier = "normal"},

    -- ==========================================================
    -- Inspect side-panel roles (PinnedTooltips_c side cards).
    -- Shared Tooltips.xaml templates used across status, saving
    -- throw, ability, resource-recharge, and similar small cards.
    -- ==========================================================

    -- "root" is a generic top-level container name on many
    -- inspect-side tooltip templates (StatusTooltip,
    -- VMActionResourceTooltip, CharacterTooltipTemplate, etc.).
    -- When inner TextBlocks lack an x:Name, CollectTooltipEntries
    -- promotes the parent "root" as the entry role.  Always
    -- semantic body/description text in practice.
    root                   = {field = "description", tier = "verbose"},

    -- "nameRun" is the primary heading Run inside a TextBlock
    -- (e.g. "Bonus Action" in the resource-recharge panel).
    nameRun                = {field = "title", tier = "brief"},

    -- "SubTitle" is the subtitle/category under the primary
    -- heading (e.g. "Replenishable Resource" under "Bonus
    -- Action").  Maps to sectionLabel -- the canonical subtitle
    -- slot (Format speaks it right after title).
    SubTitle               = {field = "sectionLabel", tier = "brief"},

    -- "AbilityText" is the ability name under an attack/save
    -- panel (e.g. "Dexterity" under "Attack Roll" or "Difficulty
    -- Class").  Semantic subtitle.
    AbilityText            = {field = "sectionLabel", tier = "brief"},

    -- "DifficultyClassText" / "DifficultyClassValue": the DC
    -- label and number as separate TextBlocks in the DC side
    -- panel.
    DifficultyClassText    = {field = "title", tier = "brief"},
    DifficultyClassValue   = {field = "value", tier = "brief"},

    -- "SavingThrowDescriptionText": body paragraph in the DC /
    -- saving throw side panel.
    SavingThrowDescriptionText = {field = "description",
                                  tier = "verbose"},

    -- "RechargeType": recharge condition value ("Once per turn"
    -- or "On Short Rest") in the resource recharge panel.
    RechargeType           = {field = "property", label = "Recharge",
                              tier = "brief"},

    -- "slotInfo": hotbar slot count indicator.  Template renders
    -- the count in two TextBlocks both named "slotInfo" (visual
    -- emphasis); the duplicate collapses naturally since `count`
    -- is a singular core field (second Add overwrites with same
    -- value).  Transform appends " available" so this emits the
    -- same "N available" phrasing as the rest of the count
    -- callers (radial, inventory, detail view).
    slotInfo               = {field = "count", tier = "brief",
                              transform = function(text)
                                  return text .. " available"
                              end},
}

-- Text values that are junk (button labels, decorative punctuation).
local TOOLTIP_JUNK = {
    ["Inspect"] = true,
    ["Close"]   = true,
    ["OK"]      = true,
    ["."]       = true,
    [":"]       = true,
}

--- CleanTooltipText: apply the standard tooltip text cleanup used
--- by FromTooltip.  Handlers that post-process empty-role entries
--- (which FromTooltip skips) should call this to get text in the
--- same form FromTooltip would have produced.
---
--- Pipeline:
---   1. StripMarkupTags (remove XML-style tags)
---   2. Strip trailing punctuation/whitespace
---   3. Normalize numeric ranges ("4~9" -> "4 to 9")
---   4. Reject junk strings (Inspect/Close/OK/.,:)
---
--- Note: numeric-only strings are NOT rejected here.  A tooltip
--- entry with a meaningful role (e.g. weightText = "9",
--- ArmorText = "11") is legitimate data.  Empty-role numeric
--- leaks are handled by FromTooltip skipping empty-role entries
--- entirely.
---
--- @param rawText string|nil  Raw tooltipEntry.text from C++.
--- @return string|nil  Cleaned text, or nil if empty/junk.
function SpeechDataModule.CleanTooltipText(rawText)
    if not rawText or rawText == "" then return nil end
    local cleaned = StripMarkupTags(rawText)
    if not cleaned or cleaned == "" then return nil end
    cleaned = cleaned:gsub("[%.:%s]+$", "")
    if cleaned == "" then return nil end
    cleaned = cleaned:gsub("(%d+)~(%d+)", "%1 to %2")
    if TOOLTIP_JUNK[cleaned] then return nil end
    return cleaned
end

--- ShouldSkipSpoken: cross-off rule for FromTooltip.  Returns true
--- when an incoming tooltip entry should be suppressed because it
--- matches what was already spoken on this focus.
---
--- Two key schemes for spokenRoles:
---
---   Core fields (key = "<fieldName>", e.g. "name", "description"):
---     - Stored value is the spoken text.  Value comparison handles
---       state changes correctly: same value = skip, different value
---       = emit (e.g. Reactions toggle: state = "Will not trigger"
---       on wave 1, "Trigger automatically" on wave 2 -> values
---       differ -> emit).
---     - The literal `true` is a wildcard sentinel: skip any value
---       for this role (used by handlers that announce a role via
---       a non-canonical format, e.g. VMAbility row says "STR" via
---       AddProperty while the tooltip's Title -> name carries
---       "Strength").
---
---   Properties (key = "property:<label>:<value>"):
---     - Stored value is `true`.  Match is presence-based because
---       the value is already encoded in the key.
---     - This handles multi-instance properties correctly:
---       PropertyText XAML emits multiple entries with label
---       "Property" and different values (Melee, DEX Save, Attack
---       Roll).  With a value-suffixed key, each (label, value)
---       pair has its own slot -> wave 2's same pairs match and
---       skip; new pairs emit.
---
--- This is the architectural dedup rule.  Speak / PopulateSpokenRoles
--- record into the map; FromTooltip consults it.  No string compares
--- of full assembled output, no parallel diff stashes -- one map,
--- one rule.
---
--- Implementation lives near the top of this file (above the
--- Speak family), not here, so that Speak / SpeakDelta /
--- PopulateSpokenRoles can capture them in their lexical scope.
--- Lua local functions are only visible to code defined after
--- them, so forward references would otherwise read as global
--- nil lookups.

--- FromTooltip: build a SpeechData from structured tooltip data using
--- the universal role mapping.  Handles junk filtering, markup
--- stripping, and optional cross-off against already-spoken roles.
---
--- @param structuredData table  Array of {role, text, fontSize?} from C++.
--- @param spokenRoles table|nil  Handler's spokenRoles map (see
---     ShouldSkipSpoken).  When provided, fields whose role+value
---     match (or are wildcard-marked) are left nil.
--- @return table  SpeechData object with fields populated.
function SpeechDataModule.FromTooltip(structuredData, spokenRoles)
    local result = Create()
    if not structuredData then return result end

    local spoken = spokenRoles or {}

    for _, tooltipEntry in ipairs(structuredData) do
        local role = tooltipEntry.role or ""
        local entryText = SpeechDataModule.CleanTooltipText(
            tooltipEntry.text)
        if not entryText then goto nextTooltipEntry end

        local mapping = TOOLTIP_ROLE_MAP[role]

        if mapping then
            -- Optional per-role value transform (e.g. strip redundant
            -- "Lv " prefix from ClassAndLevel).
            if mapping.transform then
                entryText = mapping.transform(entryText)
            end
            if mapping.field == "property" then
                -- Property key includes value; same (label, value)
                -- pair is presence-skipped.  Multi-instance labels
                -- (PropertyText -> "Property: Melee", "Property:
                -- Light", etc.) each get their own slot.
                if not ShouldSkipSpoken(spoken,
                    PropertyKey(mapping.label, entryText),
                    entryText) then
                    result:AddProperty(mapping.label, entryText,
                        mapping.tier)
                end
            else
                -- Core field: value-comparison cross-off (state
                -- changes emit, identical values skip).
                if not ShouldSkipSpoken(spoken,
                    mapping.field, entryText) then
                    result:Add(mapping.field, entryText, mapping.tier)
                end
            end
        elseif role ~= "" then
            -- Unknown but named role: keep as property.
            -- The role IS a meaningful XAML name we haven't mapped yet.
            if not ShouldSkipSpoken(spoken,
                PropertyKey(role, entryText), entryText) then
                result:AddProperty(role, entryText, "normal")
            end
        end
        -- Empty role with no mapping: skip (unnamed TextBlock,
        -- handler must call CleanTooltipText + custom parsing).

        ::nextTooltipEntry::
    end

    return result
end

--- PairKeyValueEntries: collapse XAML KeyValue WrapPanel pairs into
--- single property-shaped entries.
---
--- Tooltips.xaml defines a reusable KeyValue WrapPanel template
--- (line 1507) with four children: icon, key TextBlock, separator
--- TextBlock, value TextBlock.  When CollectTooltipEntries runs on
--- a subtree containing KeyValue panels, the inner TextBlocks have
--- no x:Name, so it promotes the parent WrapPanel's x:Name ("KeyValue")
--- as the entry role.  The separator (":") gets filtered by
--- CleanTooltipText.  Result: two consecutive entries with
--- role="KeyValue" per pair -- first is the key, second is the
--- value.
---
--- This pre-pass walks the tooltip-texts array and merges each
--- such pair into a single entry shaped `{role = <key>, text = <value>}`.
--- FromTooltip's fall-through path then renders it as
--- `AddProperty(<key>, <value>)` which speaks as "key: value"
--- naturally.
---
--- Odd/unpaired KeyValue entries are emitted as
--- `{role = "", text = <content>}` so FromTooltip skips them
--- (empty-role entries are intentionally unspoken).
---
--- Safe to call on any tooltip-texts array: if no KeyValue entries
--- are present, returns a copy of the input unchanged.
---
--- @param tooltipTexts table  Array of {role, text, ...} from C++.
--- @return table  New array with KeyValue pairs merged.
function SpeechDataModule.PairKeyValueEntries(tooltipTexts)
    local result = {}
    if not tooltipTexts then return result end
    local pendingKey = nil
    for _, entry in ipairs(tooltipTexts) do
        if (entry.role or "") == "KeyValue" then
            -- Clean the text with the same pipeline FromTooltip uses
            -- so the separator TextBlock (the ":" between key and
            -- value in the XAML KeyValue WrapPanel) is dropped BEFORE
            -- pairing.  Without this, pendingKey would pair with ":"
            -- and the real value ("2 metres") would dangle unpaired.
            local cleanedText = SpeechDataModule.CleanTooltipText(
                entry.text)
            if not cleanedText then
                -- Junk/separator inside the KeyValue row; skip without
                -- disturbing the pending key.
                goto nextPairEntry
            end
            if pendingKey then
                -- Second KeyValue in a pair: key is pending, this
                -- entry's text is the value.  Emit as {role=key}.
                result[#result + 1] = {
                    role = pendingKey,
                    text = cleanedText,
                }
                pendingKey = nil
            else
                -- First KeyValue in a pair: stash the key text.
                pendingKey = cleanedText
            end
        else
            -- Non-KeyValue entry flushes any dangling pendingKey.
            if pendingKey then
                result[#result + 1] = {
                    role = "",
                    text = pendingKey,
                }
                pendingKey = nil
            end
            result[#result + 1] = entry
        end
        ::nextPairEntry::
    end
    -- Dangling unpaired key at the end.
    if pendingKey then
        result[#result + 1] = {role = "", text = pendingKey}
    end
    return result
end

--- ParseValueDescriptionBreakdown: stat and ability tooltips use
--- a paired Value + Description pattern for component breakdowns
--- (e.g. Value=11, Description="from Armour"; Value=+3,
--- Description="from Dexterity").  The Description role is also
--- used for the stat/ability's actual description text when not
--- preceded by a Value.
---
--- This helper walks raw tooltip entries and:
---   1. Pairs each Value with the next following Description into a
---      breakdown string ("{value} {description}").
---   2. Captures the FIRST unpaired Description as the real
---      description (subsequent unpaired Descriptions are dropped).
---   3. Clears any FromTooltip-set description (it's likely polluted
---      with a breakdown label since FromTooltip maps each
---      Description entry to the same core field, last-wins).
---   4. Drops any "Value" properties FromTooltip may have added
---      (unpaired Value is meaningless on its own).
---   5. Adds a single "Breakdown" property with the paired entries
---      joined by ", " (if any).
---   6. Sets description core field from captured realDescription
---      (if any).
---
--- @param speechData table  SpeechData from FromTooltip.
--- @param tooltipTexts table  Raw {role, text} array from C++.
function SpeechDataModule.ParseValueDescriptionBreakdown(
    speechData, tooltipTexts)
    if not speechData or not tooltipTexts then return end

    -- FromTooltip's description field is polluted by breakdown
    -- labels on stat/ability tooltips.  Clear before rebuild.
    speechData.coreFields["description"] = nil
    speechData.tiers["description"] = nil
    speechData:RemoveProperty("Value")

    local breakdownParts = {}
    local pendingValue = nil
    local realDescription = nil
    for _, entry in ipairs(tooltipTexts) do
        local role = entry.role or ""
        local text = SpeechDataModule.CleanTooltipText(entry.text)
        if text then
            if role == "Value" then
                pendingValue = text
            elseif role == "Description" then
                if pendingValue then
                    breakdownParts[#breakdownParts + 1] =
                        pendingValue .. " " .. text
                    pendingValue = nil
                elseif not realDescription then
                    realDescription = text
                end
            end
        end
    end

    if realDescription then
        speechData:Add("description", realDescription, "verbose")
    end
    if #breakdownParts > 0 then
        speechData:AddProperty("Breakdown",
            table.concat(breakdownParts, ", "), "normal")
    end
end

--- PromoteEmptyRoleDescription: many tooltips put their body text
--- in an empty-role TextBlock (no x:Name in the XAML template) that
--- FromTooltip skips.  When the resulting SpeechData has no
--- description field, scan the raw tooltip entries for the longest
--- empty-role text and promote it to description.
---
--- Common case: stat tooltips (Initiative, Movement Speed, HP, AC)
--- whose "how it works" paragraph is in an unnamed TextBlock.
---
--- @param speechData table  The SpeechData from FromTooltip.
--- @param tooltipTexts table  Raw {role, text} array from C++.
--- @param minLength number|nil  Minimum length to qualify (default 30).
function SpeechDataModule.PromoteEmptyRoleDescription(
    speechData, tooltipTexts, minLength)
    if not speechData or not tooltipTexts then return end
    if speechData:HasField("description") then return end
    local longest = nil
    local longestLen = minLength or 30
    for _, entry in ipairs(tooltipTexts) do
        if (entry.role or "") == "" then
            local text = SpeechDataModule.CleanTooltipText(entry.text)
            if text and #text > longestLen then
                longest = text
                longestLen = #text
            end
        end
    end
    if longest then
        speechData:Add("description", longest, "verbose")
    end
end

--- PromoteEmptyRoleTitle: companion to PromoteEmptyRoleDescription for
--- SHORT empty-role entries.  Some tooltip templates have unnamed
--- TextBlocks for the heading row (e.g. StatusTooltip's "Off Balance"
--- name + "Condition" subtitle both live under an unnamed StackPanel
--- inside an unnamed Border, so parent-role promotion in C++ can't
--- find a named ancestor).
---
--- Walks empty-role entries in BFS order, collects short texts with
--- no period, and fills the title and sectionLabel core fields if
--- not already set (so named-role mappings always win).
---
--- CRITICAL: treats `name` as title-equivalent.  The TOOLTIP_ROLE_MAP
--- routes role="Title" -> `name` core field (an item's title IS its
--- identity), so if `name` is already populated, the panel has a
--- primary heading and we must NOT invent a title from arbitrary
--- empty-role tag text (e.g. "Single Use" in a potion tooltip's
--- footer row).  Only promote to title when neither title NOR name
--- is set -- that's the genuine "unnamed heading" case this helper
--- was built for (StatusTooltip).
---
--- @param speechData table  The SpeechData from FromTooltip.
--- @param tooltipTexts table  Raw {role, text} array from C++.
--- @param maxLength number|nil  Max length to qualify as short (default 30).
function SpeechDataModule.PromoteEmptyRoleTitle(
    speechData, tooltipTexts, maxLength)
    if not speechData or not tooltipTexts then return end
    local hasTitle = speechData:HasField("title")
    local hasName = speechData:HasField("name")
    local hasSectionLabel = speechData:HasField("sectionLabel")
    local hasIdentity = hasTitle or hasName
    -- Fully populated identity + subtitle -> nothing to fill.
    if hasIdentity and hasSectionLabel then return end
    local limit = maxLength or 30
    local shorts = {}
    for _, entry in ipairs(tooltipTexts) do
        if (entry.role or "") == "" then
            local text = SpeechDataModule.CleanTooltipText(entry.text)
            if text and #text <= limit and not text:find("%.") then
                shorts[#shorts + 1] = text
                if #shorts >= 2 then break end
            end
        end
    end
    -- Fill title ONLY when no named identity exists.  When `name` is
    -- set, the panel's primary heading is covered; empty-role shorts
    -- are tags/markers that do not belong in the title slot.
    if not hasIdentity and #shorts >= 1 then
        speechData:Add("title", shorts[1], "brief")
    end
    if not hasSectionLabel and #shorts >= 2 then
        speechData:Add("sectionLabel", shorts[2], "brief")
    end
end

--- RelabelOrphanDamageDice: find "Damage" properties whose value is
--- pure dice notation (matches "NdM" or "NdM+K" / "NdM-K") AND have
--- NO accompanying Range or Damage type property, and relabel them
--- from "Damage" to "Dice".
---
--- Rationale: weapons always emit Damage alongside Range and Damage
--- type (their combination forms the weapon attack phrase).
--- Consumables like potions and scrolls emit Damage alone -- the
--- dice notation describes what the item does mechanically (healing,
--- effect strength, etc.), not literal damage.  Labeling a potion's
--- "2d4+2" healing dice as "Damage: 2d4+2" reads wrong.
---
--- Both FormatItemTooltip (inventory/equipment focus) and
--- SpeakInspectData (inspect-widget overview) call this so the
--- labeling stays consistent across tooltip surfaces.
---
--- @param speechData table  The SpeechData to mutate.
function SpeechDataModule.RelabelOrphanDamageDice(speechData)
    if not speechData or not speechData.properties then return end
    local hasRange = false
    local hasDamageType = false
    for _, prop in ipairs(speechData.properties) do
        if prop.label == "Range" then
            hasRange = true
        elseif prop.label == "Damage type" then
            hasDamageType = true
        end
    end
    -- If Range or Damage type present, Damage is likely in weapon
    -- context; leave the label alone (weapon-combining post-pass
    -- elsewhere handles the phrase assembly).
    if hasRange or hasDamageType then return end
    for _, prop in ipairs(speechData.properties) do
        if prop.label == "Damage"
            and prop.value:match("^%d+d%d+[%+%-]?%d*$") then
            prop.label = "Dice"
        end
    end
end

--- CollapseProperties: combine all properties with the same source
--- label into a single property under a different target label,
--- with values joined by ", ".  Replaces N separate "Label: X"
--- phrases with one "TargetLabel: X, Y, Z" phrase.
---
--- Common case: weapon tooltips emit "Property: Shortsword",
--- "Property: Light", "Property: Finesse" as three entries.  Most
--- item types will want to collapse these into one "Weapon
--- properties: Light, Finesse" line (often dropping the type-name
--- duplicate via excludeValue = item name).
---
--- Keeps the source-label entries' insertion order for the joined
--- value.  Target property is added fresh; its PROPERTY_ORDER slot
--- controls where it sorts in the output (may differ from the
--- source label's slot).
---
--- @param speechData table  The SpeechData to mutate.
--- @param sourceLabel string  Label to collect (e.g. "Property").
--- @param targetLabel string  Label for the combined entry.
--- @param excludeValue string|nil  Case-insensitive value to drop
---   before joining (e.g. item name to skip "Property: Shortsword"
---   on a Shortsword).  Nil = no filtering.
--- @param tier string|nil  Verbosity tier for the combined entry
---   (default "normal").
function SpeechDataModule.CollapseProperties(
    speechData, sourceLabel, targetLabel, excludeValue, tier)
    if not speechData or not sourceLabel or not targetLabel then
        return
    end
    local excludeLower = excludeValue and excludeValue:lower() or nil
    local collectedValues = {}
    local foundAnySourceEntry = false
    for _, prop in ipairs(speechData.properties) do
        if prop.label == sourceLabel then
            foundAnySourceEntry = true
            if not (excludeLower
                and prop.value:lower() == excludeLower) then
                collectedValues[#collectedValues + 1] = prop.value
            end
        end
    end
    -- Nothing to do if the source label never appeared.  When it
    -- did appear but every value was excluded (e.g. only entry was
    -- "Property: Mace" on an item titled "Mace"), we still need to
    -- strip the source entries -- otherwise the duplicate-of-title
    -- leaks through as "Property: Mace" because the early return
    -- skipped the RemoveProperties call.
    if not foundAnySourceEntry then return end
    speechData:RemoveProperties(function(prop)
        return prop.label == sourceLabel
    end)
    if #collectedValues > 0 then
        speechData:AddProperty(targetLabel,
            table.concat(collectedValues, ", "), tier or "normal")
    end
end

function SpeechDataModule.SetHintsEnabled(enabled)
    hintsEnabled = enabled
end

function SpeechDataModule.GetHintsEnabled()
    return hintsEnabled
end

--- SetVerbosity: set the module-global verbosity level.  Validates
--- the level against TIER_RANK (accepts "brief", "normal",
--- "verbose"); ignores invalid input.
function SpeechDataModule.SetVerbosity(level)
    if TIER_RANK[level] then
        currentVerbosity = level
    end
end

function SpeechDataModule.GetVerbosity()
    return currentVerbosity
end

-- Next step in the CycleVerbosity rotation: most detail -> least
-- detail -> wrap.
local VERBOSITY_NEXT = {
    verbose = "normal",
    normal  = "brief",
    brief   = "verbose",
}

--- CycleVerbosity: advance the module-global verbosity to the next
--- step in the cycle (verbose -> normal -> brief -> verbose) and
--- announce the new level via SpeechData.Alert.  Used by the RS-Down
--- controller chord in EventRouter.lua to let the user toggle
--- speech detail on demand without a settings UI.
function BG3Access.Client.CycleVerbosity()
    local nextLevel = VERBOSITY_NEXT[currentVerbosity] or "verbose"
    currentVerbosity = nextLevel
    local label = nextLevel:sub(1, 1):upper() .. nextLevel:sub(2)
    Log.Info("Verbosity: " .. label)
    SpeechDataModule.Alert("Verbosity " .. label, "interrupt")
end

-- Deferred Log binding: Log module loads before SpeechData,
-- so we can grab it at file scope.
Log = BG3Access.Client.Log

BG3Access.Client.SpeechData = SpeechDataModule
