-- ============================================================================
-- BG3Access Combat Module
--
-- Receives combat events from the server (Osiris listeners relayed via
-- net messages) and generates screen reader speech for:
--   - Turn changes (whose turn, round number)
--   - Combat start / end
--   - Death / downed announcements
--   - Status effects applied / removed (party members)
--   - Damage dealt (party member involved)
--
-- Also provides on-demand combat info:
--   - Turn order list (for RS HUD reader)
--   - Combat state queries (for other modules)
-- ============================================================================

local Log = BG3Access.Client.Log
local SpeechData = BG3Access.Client.SpeechData

local COMBAT_CHANNEL = "BG3Access_Combat"

-- ---------------------------------------------------------------------------
-- Combat state
-- ---------------------------------------------------------------------------

local inCombat = false
local currentTurnCharacterName = nil
local currentTurnCharacterGuid = nil
local currentRound = 0
local pendingRoundAnnouncement = nil

-- Rapid-fire status events (applied/removed on the same character
-- within this window) are suppressed.  BG3 re-applies surface
-- statuses on every tick the character remains on the surface, so
-- walking through water with "Wet" / "Difficult Terrain" produces
-- dozens of apply/remove cycles per minute.  A 2 second window
-- swallows the thrash while still announcing genuine status
-- changes (new buff cast, enemy applies poison, debuff wears off).
local STATUS_DEDUP_WINDOW_MS = 2000
-- Key = characterGuid|statusId|kind (applied/removed).  Value =
-- last announce timestamp in ms from Ext.Utils.MonotonicTime.  The
-- table grows bounded by party size * active statuses * 2 kinds,
-- which is well under 100 entries in practice -- no eviction
-- needed.  Cleared on ResetState.
local statusLastAnnounceTime = {}

-- ---------------------------------------------------------------------------
-- Speech helpers
-- ---------------------------------------------------------------------------

--- Speak combat text with interrupt (cuts off previous speech).
--- Combat events are background events that bypass the SpeechData
--- field system via SpeakAlert.
local function SpeakCombatInterrupt(text)
    if not text or text == "" then return end
    SpeechData.Alert(text, "interrupt")
end

--- Speak combat text queued (appends after current speech).
local function SpeakCombatQueued(text)
    if not text or text == "" then return end
    SpeechData.Alert(text, "queue")
end

-- ---------------------------------------------------------------------------
-- Event handlers
-- ---------------------------------------------------------------------------

-- Forward declaration so HandleCombatStarted can call
-- ReadTurnOrder (defined later in the file for context-locality
-- with SpeakTurnOrder).  Assigned in the same `local function`
-- declaration pattern that Lua resolves through the captured
-- local at call time.
local ReadTurnOrder

--- Read the turn order, sort by initiative descending, and return
--- "Initiative, Name N, Name M, ..." or nil when nothing speakable.
--- Extracted so HandleCombatStarted can call it both synchronously
--- (preferred path -- queues the initiative line BEFORE Osiris
--- fires TurnStarted) and as a deferred fallback when the
--- turn-order components aren't populated yet.
local function BuildInitiativeAnnouncement()
    if not ReadTurnOrder then return nil end
    local turnEntries = ReadTurnOrder()
    if not turnEntries or #turnEntries == 0 then return nil end

    -- Sort by descending initiative so we announce fastest first
    -- (matches actual turn order; BG3 rolls high-to-low too).
    -- Preserve stable order among equal rolls.
    local sorted = {}
    for index, entry in ipairs(turnEntries) do
        sorted[#sorted + 1] = {
            entry = entry, originalIndex = index,
        }
    end
    table.sort(sorted, function(a, b)
        local aInit = tonumber(a.entry.initiative) or -1
        local bInit = tonumber(b.entry.initiative) or -1
        if aInit ~= bInit then return aInit > bInit end
        return a.originalIndex < b.originalIndex
    end)

    local parts = {"Initiative"}
    for _, wrapped in ipairs(sorted) do
        local entry = wrapped.entry
        if entry.initiative then
            parts[#parts + 1] = (entry.name or "Unknown")
                .. " " .. tostring(entry.initiative)
        end
    end
    if #parts <= 1 then return nil end
    return table.concat(parts, ", ")
end

local function HandleCombatStarted(eventData)
    inCombat = true
    currentRound = 0
    currentTurnCharacterName = nil
    currentTurnCharacterGuid = nil
    pendingRoundAnnouncement = nil
    SpeakCombatInterrupt("Combat started")

    -- Queue the initiative summary IMMEDIATELY so it lands in the
    -- speech queue before Osiris fires TurnStarted (which arrives
    -- ~100ms later from the server relay).  Empirically the
    -- ParticipantComponent.InitiativeRoll values are populated by
    -- the time CombatStarted fires, so reading synchronously
    -- works.  If the read returns nothing (race on slow machines /
    -- mod-induced reorder), fall back to a 150ms retry -- but in
    -- that case the order will be Combat started -> turn ->
    -- initiative, which is the lesser evil compared to silently
    -- losing the initiative line.
    local initiativeText = BuildInitiativeAnnouncement()
    if initiativeText then
        SpeakCombatQueued(initiativeText)
    else
        Ext.Timer.WaitFor(150, function()
            if not inCombat then return end
            local fallbackText = BuildInitiativeAnnouncement()
            if fallbackText then
                SpeakCombatQueued(fallbackText)
            end
        end)
    end
end

local function HandleCombatEnded(eventData)
    inCombat = false
    -- Clear target-select cache so the effects view (RS-Left)
    -- stops serving stale target data the moment combat ends.
    -- Out-of-combat RS-Left should fall through to whatever panel
    -- handler owns the current context (character sheet, inventory,
    -- etc.) -- not a dead combat target from the last fight.
    local TargetSelect = BG3Access.Client.TargetSelect
    if TargetSelect and TargetSelect.ResetState then
        TargetSelect.ResetState()
    end
    currentTurnCharacterName = nil
    currentTurnCharacterGuid = nil
    currentRound = 0
    pendingRoundAnnouncement = nil
    SpeakCombatInterrupt("Combat ended")
end

local function HandleRoundStarted(eventData)
    local round = eventData.round or 0
    currentRound = round
    -- Don't speak immediately -- prepend to the next TurnStarted
    -- so "Round 2. Tav's turn" is a single uninterrupted speech.
    pendingRoundAnnouncement = round
end

local function HandleTurnStarted(eventData)
    local characterName = eventData.characterName or "Unknown"
    currentTurnCharacterName = characterName
    currentTurnCharacterGuid = eventData.characterGuid

    local text = characterName .. "'s turn"

    -- Prepend pending round announcement.
    if pendingRoundAnnouncement then
        text = "Round " .. tostring(pendingRoundAnnouncement)
            .. ". " .. text
        pendingRoundAnnouncement = nil
    end

    -- ALL turn announcements queue, including the player's own
    -- turn.  Interrupt here was the original bug that clobbered
    -- damage announcements: a prior enemy's attack speech is
    -- queued, an intermediate NPC turn queues behind it, then
    -- "Tav's turn" fired as an interrupt and wiped the entire
    -- pending queue -- the user heard the first few words of
    -- damage and then "Tav's turn" without the rest.
    --
    -- Queuing Tav's turn means the user hears the full sequence
    -- in order: "Intellect Devourer hit Tav for 8 damage, 2 of 10
    -- remaining. Round 3. Tav's turn."  They still learn it's
    -- their turn, just after the damage info they need.  Since
    -- acting requires opening the radial menu (another button
    -- press), there's no race where they'd miss their turn.
    SpeakCombatQueued(text)
end

local function HandleDied(eventData)
    local characterName = eventData.characterName or "Unknown"
    -- Proactively invalidate the TargetSelect effects-view cache if
    -- this is the creature the user was inspecting.  Prevents later
    -- RS-Left reads from dereferencing an ECS entity that is in the
    -- middle of teardown (the suspected cause of recent "dead
    -- object" SEH faults that manifest as game hangs).
    if eventData.characterGuid then
        local TargetSelect = BG3Access.Client.TargetSelect
        if TargetSelect and TargetSelect.ClearCachedTargetByUuid then
            TargetSelect.ClearCachedTargetByUuid(
                eventData.characterGuid)
        end
    end
    if eventData.isPartyMember then
        SpeakCombatInterrupt(characterName .. " is down")
    else
        SpeakCombatInterrupt(characterName .. " died")
    end
end

--- Return true if this status event should be announced; false if
--- it duplicates a recent announcement for the same character +
--- status + kind.  Updates the timestamp on a true return so the
--- next caller sees a fresh window.
local function ShouldAnnounceStatusEvent(characterGuid, statusId, kind)
    local key = tostring(characterGuid)
        .. "|" .. tostring(statusId)
        .. "|" .. kind
    local now = Ext.Utils.MonotonicTime()
    local lastAnnounced = statusLastAnnounceTime[key]
    if lastAnnounced
        and (now - lastAnnounced) < STATUS_DEDUP_WINDOW_MS then
        return false
    end
    statusLastAnnounceTime[key] = now
    return true
end

local function HandleStatusApplied(eventData)
    if not ShouldAnnounceStatusEvent(
        eventData.characterGuid, eventData.statusId, "applied") then
        return
    end
    local characterName = eventData.characterName or "Unknown"
    local statusName = eventData.statusDisplayName
        or eventData.statusId or "unknown status"
    SpeakCombatQueued(characterName .. ": " .. statusName)
end

local function HandleStatusRemoved(eventData)
    if not ShouldAnnounceStatusEvent(
        eventData.characterGuid, eventData.statusId, "removed") then
        return
    end
    local characterName = eventData.characterName or "Unknown"
    local statusName = eventData.statusDisplayName
        or eventData.statusId or "unknown status"
    SpeakCombatQueued(statusName .. " expired on " .. characterName)
end

--- Concentration loss announcement.  Server fires this when a
--- party member's concentration is interrupted (failed Con save
--- on damage, death, dispel, etc.) per the
--- ConcentrationChangedOneFrameComponent path documented in
--- BootstrapServer.lua.  The Constitution save's pass/fail was
--- already announced by the existing roll relay; this announcement
--- adds the affected spell so the user knows which buff just
--- dropped.  Queue (not interrupt) so it falls naturally after the
--- Con-save outcome that triggered it: the user hears
---   "Goblin hit Shadowheart for 11 damage, 9 of 20 remaining"
---   "Shadowheart, rolled 8 plus 4, total 12, Constitution save,
---    DC 11, failed"
---   "Shadowheart lost concentration on Bless"
--- in cause-effect order.
local function HandleConcentrationLost(eventData)
    local casterName = eventData.casterName or "Unknown"
    local spellName = eventData.spellName or "spell"
    SpeakCombatQueued(
        casterName .. " lost concentration on " .. spellName)
end

--- Build a "N of M remaining" suffix for defender HP.  Returns an
--- empty string when HP data is unavailable so callers can unconditionally
--- concatenate.
---
--- We announce enemy HP as well as party HP: BG3 already shows enemy
--- HP visually (the TargetInfo_c health bar, and numeric HP on the
--- target panel when focused).  A blind player needs the same
--- information to decide whether their next attack will finish the
--- enemy or if they should save resources.  Suppressing enemy HP
--- would be accessibility-harmful, not a secrecy feature.
local function BuildHitpointsSuffix(eventData)
    local currentHp = eventData.defenderHp
    local maxHp = eventData.defenderMaxHp
    if not currentHp or not maxHp then return "" end
    return ".  " .. tostring(currentHp) .. " of "
        .. tostring(maxHp) .. " remaining"
end

-- ---------------------------------------------------------------------------
-- Roll-detail cache + speech
--
-- The server relays every finished roll (attack / save / check)
-- via the "RollFinished" event.  Attack rolls fire microseconds
-- before their companion AttackedBy / MissedBy Osiris event, so we
-- cache them briefly and prepend the d20 breakdown to the existing
-- damage or miss announcement.  Saves / checks are standalone --
-- they don't have a follow-up Osiris event to merge into, so we
-- speak them directly.
--
-- Cache is keyed by (rollerName, subjectName) and expires after a
-- short window.  BG3 fires one roll then one hit/miss within a few
-- ticks, so the window is small -- 500ms is plenty.  The TTL
-- prevents stale roll data from leaking into a later attack from
-- the same attacker.
-- ---------------------------------------------------------------------------

local ROLL_CACHE_TTL_MS = 500

local attackRollCache = {}  -- "<attacker>|<defender>" -> {rollData, expiresAtMs}

local function CacheAttackRoll(eventData)
    local key = tostring(eventData.rollerName or "")
        .. "|" .. tostring(eventData.subjectName or "")
    attackRollCache[key] = {
        data = eventData,
        expiresAtMs = Ext.Utils.MonotonicTime() + ROLL_CACHE_TTL_MS,
    }
end

local function ConsumeAttackRoll(attackerName, defenderName)
    local key = tostring(attackerName or "")
        .. "|" .. tostring(defenderName or "")
    local cached = attackRollCache[key]
    if not cached then return nil end
    attackRollCache[key] = nil
    if Ext.Utils.MonotonicTime() > cached.expiresAtMs then
        return nil
    end
    return cached.data
end

--- Returns true when the current verbosity level opts into roll
--- detail.  Brief mode keeps combat announcements terse by
--- skipping the d20 breakdown; normal and verbose include it.
local function ShouldSpeakRollDetail()
    local verbosity = SpeechData.GetVerbosity
        and SpeechData.GetVerbosity() or "normal"
    return verbosity ~= "brief"
end

--- Format a "rolled N plus M" fragment that prepends to damage
--- and miss announcements.  Advantage / disadvantage gets a short
--- suffix.  Natural 20 / natural 1 become "critical hit" / "critical
--- miss" phrasing so the user hears the crit immediately.
local function BuildRollPrefix(rollData)
    local natural = tonumber(rollData.naturalRoll) or 0
    local total = tonumber(rollData.total) or natural
    local modifier = tonumber(rollData.modifier) or 0

    local parts = {}
    parts[#parts + 1] = "rolled " .. tostring(natural)
    if modifier ~= 0 then
        if modifier > 0 then
            parts[#parts + 1] = "plus " .. tostring(modifier)
        else
            parts[#parts + 1] = "minus " .. tostring(-modifier)
        end
        parts[#parts + 1] = "total " .. tostring(total)
    end
    if natural == 20 then
        parts[#parts + 1] = "critical hit"
    elseif natural == 1 then
        parts[#parts + 1] = "critical miss"
    end
    if rollData.advantage then
        parts[#parts + 1] = "with advantage"
    elseif rollData.disadvantage then
        parts[#parts + 1] = "with disadvantage"
    end
    return table.concat(parts, ", ")
end

--- Convert a PascalCase enum name to space-separated words so TTS
--- pronounces each word instead of reading the camel blob as one
--- token.  "SleightOfHand" -> "Sleight of Hand".  "AnimalHandling"
--- -> "Animal Handling".  "DeathSavingThrow" -> "Death Saving Throw".
--- Lowercases short linking words (Of / And / The) mid-phrase so the
--- result reads naturally rather than "Sleight Of Hand".
local SMALL_WORDS = {
    Of = "of", And = "and", The = "the",
    In = "in", On = "on", To = "to",
}

local function HumanizeEnumName(name)
    if not name or name == "" then return "" end
    -- Insert spaces at lowercase -> uppercase boundaries, and also
    -- at the end of capital runs followed by lowercase (handles
    -- mixed cases like "DCArea" -> "DC Area"; harmless elsewhere).
    local spaced = name
        :gsub("(%l)(%u)", "%1 %2")
        :gsub("(%u+)(%u%l)", "%1 %2")
    spaced = spaced:gsub("(%S+)", function(word)
        return SMALL_WORDS[word] or word
    end)
    return spaced
end

--- Speak a standalone saving-throw outcome.  Format:
---   "<roller> rolled <natural> plus <mod>, total <N>,
---    <ability> save DC <DC>, passed/failed."
--- DC phrase omitted when the server reported no DC.
local function HandleRollFinishedSave(eventData)
    if not ShouldSpeakRollDetail() then return end
    local rollerName = eventData.rollerName or "Unknown"
    local abilityName = eventData.abilityName or ""
    local dc = tonumber(eventData.dc)
    local total = tonumber(eventData.total)
        or tonumber(eventData.rollTotal)
    local prefix = BuildRollPrefix(eventData)

    -- Label resolution order:
    --   1. Death saves are ability-less by design (straight d20 vs
    --      DC 10), so rollTypeName="DeathSavingThrow" is the ONLY
    --      signal -- abilityName comes through as "None".  Check
    --      this first, unconditionally.
    --   2. Ability-based save with a known ability name: "Wisdom
    --      save", "Constitution save", etc.
    --   3. No name available: omit the label rather than say
    --      something generic like "saving throw" (user can infer
    --      from context).
    local saveLabel = nil
    if eventData.rollTypeName == "DeathSavingThrow" then
        saveLabel = "death saving throw"
    elseif abilityName ~= "" and abilityName ~= "None" then
        saveLabel = HumanizeEnumName(abilityName) .. " save"
    end

    local parts = { rollerName, prefix }
    if saveLabel then
        parts[#parts + 1] = saveLabel
    end
    if dc then
        parts[#parts + 1] = "DC " .. tostring(dc)
    end

    -- Pass / fail callout when we have both a DC and a total.
    -- Death saves use DC 10 as the game constant; other saves
    -- carry an explicit DC from the spell / effect.  Server
    -- relays `total` (= natural + modifier) when the roll is
    -- computed, so "<total> >= <dc>" gives us the outcome
    -- without needing the server to relay a pass/fail flag.
    if dc and total then
        if total >= dc then
            parts[#parts + 1] = "passed"
        else
            parts[#parts + 1] = "failed"
        end
    end

    -- Forced-by-party-spell context.  Server populates
    -- forcingSpellName only when the standard party gate would
    -- have skipped the relay (enemy-vs-enemy save) AND the save
    -- target was just hit by a party spell cast (per the
    -- pendingPartyCastTargets cache in BootstrapServer.lua).
    -- Append "against <spell>" so the player knows which of their
    -- spells just got resisted / soaked: "Goblin, rolled 14,
    -- Wisdom save, DC 13, passed against Sleep" tells them their
    -- Sleep didn't take this enemy.  Nil for normal party-side
    -- rolls -- omit suffix entirely so no awkward "against nil".
    if eventData.forcingSpellName
        and eventData.forcingSpellName ~= "" then
        parts[#parts + 1] = "against " .. eventData.forcingSpellName
    end

    -- Queue instead of interrupt.  A saving throw fired during
    -- combat (concentration save, death save) is the DIRECT
    -- consequence of the damage announcement that triggered it;
    -- interrupting the damage to speak the save result cuts off
    -- the cause mid-sentence.  Queue means the user hears:
    --   "Intellect Devourer hit Tav for 8 damage, 0 of 10 remaining"
    --   "Tav: Downed"
    --   "Tav rolled 14, death saving throw, DC 10, passed"
    -- in order, which is the natural cause-effect sequence.
    SpeakCombatQueued(table.concat(parts, ", "))
end

--- Speak a standalone skill / ability check outcome.  Same shape as
--- the save handler but uses skill name when available.
local function HandleRollFinishedCheck(eventData)
    if not ShouldSpeakRollDetail() then return end
    local rollerName = eventData.rollerName or "Unknown"
    local skillName = eventData.skillName or ""
    local abilityName = eventData.abilityName or ""
    local dc = tonumber(eventData.dc)
    local total = tonumber(eventData.total)
        or tonumber(eventData.rollTotal)
    local prefix = BuildRollPrefix(eventData)

    local parts = { rollerName, prefix }
    if skillName ~= "" and skillName ~= "None" then
        parts[#parts + 1] = HumanizeEnumName(skillName) .. " check"
    elseif abilityName ~= "" and abilityName ~= "None" then
        parts[#parts + 1] = HumanizeEnumName(abilityName) .. " check"
    end
    if dc then parts[#parts + 1] = "DC " .. tostring(dc) end

    -- Pass / fail callout.  Same logic as saves -- total >= DC is
    -- success.  Matches the on-screen "SUCCESS" / "FAILURE" text
    -- the ActiveRoll reveal reads sighted players (which we also
    -- speak via RollPreview at reveal moment).
    if dc and total then
        if total >= dc then
            parts[#parts + 1] = "passed"
        else
            parts[#parts + 1] = "failed"
        end
    end

    -- Queue (not interrupt), same rationale as saves: a combat
    -- check is typically adjacent to the event that triggered it;
    -- interrupting cuts off the cause.  Out-of-combat checks drain
    -- the queue immediately since nothing else is queued.
    SpeakCombatQueued(table.concat(parts, ", "))
end

-- Forward declaration so HandleRollFinished can call into the roll-
-- preview cancellation path even though the preview helpers are
-- defined later in the file.  Without this, Lua resolves the name
-- as a global at call time and throws "attempt to call a nil value
-- (global 'CancelPendingRollPreview')".  Assigned by the later
-- `CancelPendingRollPreview = function(...)` below.
local CancelPendingRollPreview

local function HandleRollFinished(eventData)
    -- If the user pressed A before the preview's reveal delay
    -- expired, cancel the pending preview: the full breakdown that
    -- follows includes the natural, so the preview would just repeat
    -- what we're about to say.
    CancelPendingRollPreview(eventData.rollUuid)

    local bucket = eventData.rollBucket or ""
    if bucket == "attack" then
        -- Cache for merge with AttackedBy / MissedBy.  No speech
        -- here -- the subsequent Osiris handler does the speech
        -- and prepends our cached roll data via ConsumeAttackRoll.
        CacheAttackRoll(eventData)
    elseif bucket == "save" then
        HandleRollFinishedSave(eventData)
    elseif bucket == "check" then
        HandleRollFinishedCheck(eventData)
    end
end

--- Build the optional "rolled N plus M, total X" fragment that
--- prepends to damage / miss speech when roll detail is cached
--- AND verbosity allows it.  Returns a trailing period + space so
--- callers can concatenate directly, or an empty string.
local function BuildRollPrefixFragment(attackerName, defenderName)
    if not ShouldSpeakRollDetail() then return "" end
    local rollData = ConsumeAttackRoll(attackerName, defenderName)
    if not rollData then return "" end
    return BuildRollPrefix(rollData) .. ".  "
end

-- Recently-spoken CombatHit pairs, used to suppress the redundant
-- AttackedBy announcements that fire alongside a HitResultEvent.
-- BG3 fires a separate AttackedBy Osiris event per damage sub-
-- instance (spell primary + surface tick + resistance absorption),
-- so a single Fire Bolt can produce 3 AttackedBy relays.  The
-- HitResultEvent rolls them all up into a single coherent damage
-- summary -- so whenever we've just spoken a CombatHit for
-- (attacker, target), we suppress any AttackedBy for that same
-- pair for a short window.  Non-hit damage (standalone DoT ticks
-- on later turns, environmental damage with no attacker) falls
-- through because the cache won't match.
local combatHitSpokenCache = {}
local COMBAT_HIT_SUPPRESS_MS = 500

local function MarkCombatHitSpoken(attackerName, targetName)
    local key = tostring(attackerName or "") .. "|"
        .. tostring(targetName or "")
    combatHitSpokenCache[key] =
        Ext.Utils.MonotonicTime() + COMBAT_HIT_SUPPRESS_MS
end

local function WasCombatHitSpokenRecently(attackerName, targetName)
    local key = tostring(attackerName or "") .. "|"
        .. tostring(targetName or "")
    local expiresAt = combatHitSpokenCache[key]
    if not expiresAt then return false end
    if Ext.Utils.MonotonicTime() > expiresAt then
        combatHitSpokenCache[key] = nil
        return false
    end
    return true
end

--- CauseType classification:
---   Attack / Offhand         -> direct attack (has to-hit roll)
---   StatusEnter / StatusTick -> damage from a status (Burning etc.)
---   SurfaceMove / SurfaceCreate / SurfaceStatus -> damage from a
---                               surface (Fire, Poison, Lava, etc.)
---   AURA                     -> damage from a persistent aura
---   InventoryItem / WorldItemThrow -> thrown / item effect
---   None / Unknown11         -> fallback
---
--- From Stats.inl:760-773.  We branch speech on this so the user
--- hears the actual source ("Burning dealt 3 fire damage to Tav",
--- "Fire surface dealt 1 fire damage to Intellect Devourer") rather
--- than attributing every tick to the spell-caster.
local ATTACK_CAUSES = {
    ["Attack"] = true, ["Offhand"] = true,
}

local STATUS_CAUSES = {
    ["StatusEnter"] = true, ["StatusTick"] = true,
}

local SURFACE_CAUSES = {
    ["SurfaceMove"]   = true,
    ["SurfaceCreate"] = true,
    ["SurfaceStatus"] = true,
}

--- Humanize a status ID for speech.  "BURNING" -> "Burning",
--- "SH_POISONED" -> "Poisoned".  Strips common Larian prefixes
--- (SH_, etc.) and converts UPPER_SNAKE to Title case.
local function HumanizeStatusId(statusId)
    if not statusId or statusId == "" then return "" end
    -- Strip Larian prefixes.
    local stripped = statusId:gsub("^SH_", ""):gsub("^LSS_", "")
    -- Convert UPPER_SNAKE / mixed to words: split on _ or space.
    local words = {}
    for word in stripped:gmatch("[^_%s]+") do
        if word ~= "" then
            -- Title-case each word.  If already mixed case, leave
            -- leading cap alone but lowercase the rest.
            local first = word:sub(1, 1):upper()
            local rest = word:sub(2):lower()
            words[#words + 1] = first .. rest
        end
    end
    return table.concat(words, " ")
end

--- Format damage as "<N> <type>" or "<N>" (no type).  Reuses
--- damagePhrase from the server if present; falls back to
--- "<damageAmount> damage" when no per-type breakdown.
local function FormatCombatDamage(damageAmount, damagePhrase)
    if damagePhrase and damagePhrase ~= "" then
        return damagePhrase .. " damage"
    end
    if damageAmount and damageAmount > 0 then
        return tostring(damageAmount) .. " damage"
    end
    return ""
end

--- Format the target-HP suffix or return "".  Skipped entirely for
--- pure misses (nothing changed) or when we don't have HP data.
local function FormatHpSuffix(defenderHp, defenderMaxHp)
    if not defenderHp or not defenderMaxHp then return "" end
    return tostring(defenderHp) .. " of "
        .. tostring(defenderMaxHp) .. " remaining"
end

--- Speak a standard attack hit (CauseType Attack / Offhand).
--- Includes roll breakdown when available.
local function SpeakAttackHit(eventData)
    local attackerName = eventData.attackerName or "Unknown"
    local targetName = eventData.targetName or "Unknown"
    local damageAmount = tonumber(eventData.damageAmount) or 0
    local critical = eventData.critical == true
    local criticalMiss = eventData.criticalMiss == true
    local isMiss = eventData.isMiss == true
    local lethal = eventData.lethal == true
    local hasRoll = tonumber(eventData.naturalRoll) ~= nil

    local parts = { attackerName }

    -- Roll detail (crit hit / crit miss phrasing already included
    -- by BuildRollPrefix -- do NOT repeat in action clause).
    if ShouldSpeakRollDetail() and hasRoll then
        local rollPrefix = BuildRollPrefix({
            naturalRoll  = eventData.naturalRoll,
            modifier     = eventData.modifier,
            total        = eventData.rollTotal,
            advantage    = eventData.advantage == true,
            disadvantage = eventData.disadvantage == true,
        })
        if rollPrefix and rollPrefix ~= "" then
            parts[#parts + 1] = rollPrefix
        end
    end

    -- Action clause.  Immune is its own branch: even if the rolled
    -- damage was non-zero, the target ate it all -- the player needs
    -- to know the spell did NOTHING so they can adjust their plan
    -- (switch damage type, target someone else).  isMiss / criticalMiss
    -- still take precedence (no damage was even rolled).
    local wasImmune = eventData.wasImmune == true
    if isMiss or criticalMiss then
        parts[#parts + 1] = "missed " .. targetName
    elseif wasImmune then
        parts[#parts + 1] = "hit " .. targetName
            .. ", immune to "
            .. tostring(tonumber(eventData.rolledDamage)
                or eventData.originalDamage or 0)
            .. " damage"
    elseif damageAmount == 0 then
        parts[#parts + 1] = "hit " .. targetName .. " for no damage"
    else
        parts[#parts + 1] = "hit " .. targetName
    end

    if damageAmount > 0 then
        local damageText = FormatCombatDamage(
            damageAmount, eventData.damagePhrase)
        if damageText ~= "" then
            parts[#parts + 1] = "for " .. damageText
        end
        -- Resistance hint: server flagged that the rolled damage
        -- exceeded what was applied (resistance, partial absorption,
        -- temp HP).  Append "(resisted from N)" so the player
        -- understands why the actual number is lower than the dice
        -- they rolled.  wasImmune branch above already covers
        -- damageAmount == 0; this branch is for partial reduction.
        if eventData.wasReduced == true and not wasImmune then
            local rolled = tonumber(eventData.rolledDamage)
                or tonumber(eventData.originalDamage)
            if rolled and rolled > damageAmount then
                parts[#parts + 1] = "resisted from "
                    .. tostring(rolled)
            end
        end
    end

    -- HP suffix skipped for pure misses.  Immune cases still get
    -- the suffix because HP didn't change but the player benefits
    -- from confirmation ("HP unchanged at 20 of 20").
    if not (isMiss or criticalMiss) then
        local hpSuffix = FormatHpSuffix(
            tonumber(eventData.defenderHp),
            tonumber(eventData.defenderMaxHp))
        if hpSuffix ~= "" then
            parts[#parts + 1] = hpSuffix
        end
    end

    if lethal then
        parts[#parts + 1] = targetName .. " is down"
    end

    SpeakCombatQueued(table.concat(parts, ", "))
end

--- Speak a status-caused hit (Burning, Poisoned, etc. dealing
--- tick damage).  Attribute to the status, not the entity that
--- applied it -- "Burning dealt 3 fire damage to Tav".
local function SpeakStatusHit(eventData)
    local targetName = eventData.targetName or "Unknown"
    local damageAmount = tonumber(eventData.damageAmount) or 0
    if damageAmount == 0 then return end

    local statusDisplay = HumanizeStatusId(eventData.statusId or "")
    if statusDisplay == "" then statusDisplay = "Status effect" end

    local damageText = FormatCombatDamage(
        damageAmount, eventData.damagePhrase)
    local parts = {
        statusDisplay,
        "dealt " .. damageText,
        "to " .. targetName,
    }
    local hpSuffix = FormatHpSuffix(
        tonumber(eventData.defenderHp),
        tonumber(eventData.defenderMaxHp))
    if hpSuffix ~= "" then parts[#parts + 1] = hpSuffix end
    if eventData.lethal == true then
        parts[#parts + 1] = targetName .. " is down"
    end

    SpeakCombatQueued(table.concat(parts, ", "))
end

--- Speak a surface-caused hit (Fire Surface, Poison Cloud, etc.).
--- Attribute to the surface, not the entity that created it.
local function SpeakSurfaceHit(eventData)
    local targetName = eventData.targetName or "Unknown"
    local damageAmount = tonumber(eventData.damageAmount) or 0
    if damageAmount == 0 then return end

    local surfaceTypeName = eventData.surfaceType or ""
    -- Humanize surface enum: "Fire" -> "fire surface",
    -- "WaterElectrified" -> "electrified water surface".
    local surfaceLabel = "Surface"
    if surfaceTypeName ~= "" and surfaceTypeName ~= "None" then
        local humanized = surfaceTypeName
            :gsub("(%l)(%u)", "%1 %2"):lower()
        surfaceLabel = humanized .. " surface"
        -- Capitalize first letter for sentence start.
        surfaceLabel = surfaceLabel:sub(1, 1):upper()
            .. surfaceLabel:sub(2)
    end

    local damageText = FormatCombatDamage(
        damageAmount, eventData.damagePhrase)
    local parts = {
        surfaceLabel,
        "dealt " .. damageText,
        "to " .. targetName,
    }
    local hpSuffix = FormatHpSuffix(
        tonumber(eventData.defenderHp),
        tonumber(eventData.defenderMaxHp))
    if hpSuffix ~= "" then parts[#parts + 1] = hpSuffix end
    if eventData.lethal == true then
        parts[#parts + 1] = targetName .. " is down"
    end

    SpeakCombatQueued(table.concat(parts, ", "))
end

--- Dispatch a HitResultEvent relay to the correct speech builder
--- based on CauseType.  Attack-type causes go to SpeakAttackHit
--- (full roll detail); status/surface/other causes go to their
--- own builders which attribute damage to the right source.
---
--- Dedup marking: ANY speech we emit from the HitResultEvent path
--- has to mark the cache, because the follow-up Osiris AttackedBy
--- / MissedBy relays fire for all these causes and we don't want
--- to speak them twice.  Previously only Attack/Offhand marked,
--- which meant the fallback "cause=None, miss=true" path spoke
--- the primary announcement AND let the two Osiris follow-ups
--- fire -- you'd hear the miss announced three times.
local function HandleCombatHit(eventData)
    local attackerName = eventData.attackerName or "Unknown"
    local targetName = eventData.targetName or "Unknown"
    local causeType = eventData.causeType or ""

    if STATUS_CAUSES[causeType] then
        -- Status-caused damage (Burning tick, Poisoned tick).  Don't
        -- mark the cache -- this is independent of any attack, and
        -- a real attack on the same pair should still speak.
        SpeakStatusHit(eventData)
        return
    end

    if SURFACE_CAUSES[causeType] then
        -- Surface-caused damage (fire surface tick, etc.).  Same
        -- rationale as status: don't suppress real attacks.
        SpeakSurfaceHit(eventData)
        return
    end

    -- Everything else goes through SpeakAttackHit: Attack, Offhand,
    -- AURA, InventoryItem, WorldItemThrow, None (misses), Unknown11.
    -- All of these correspond to a hit-resolution event whose
    -- Osiris AttackedBy / MissedBy follow-ups are redundant with
    -- what SpeakAttackHit already announces -- so mark the cache
    -- unconditionally for this branch.
    MarkCombatHitSpoken(attackerName, targetName)
    SpeakAttackHit(eventData)
end

local function HandleAttackedBy(eventData)
    local attackerName = eventData.attackerName or "Unknown"
    local defenderName = eventData.defenderName or "Unknown"
    local damageAmount = eventData.damageAmount or 0
    local damageType = eventData.damageType or ""

    -- Dedup: if a HitResultEvent for this attacker/target just
    -- fired, its CombatHit speech already rolled up every damage
    -- sub-instance.  Silently drop the redundant AttackedBy relay.
    if WasCombatHitSpokenRecently(attackerName, defenderName) then
        return
    end

    local rollPrefix = BuildRollPrefixFragment(attackerName, defenderName)

    if damageAmount > 0 then
        local damageText = attackerName .. " "
            .. rollPrefix
            .. "dealt " .. tostring(damageAmount)
        if damageType ~= "" then
            damageText = damageText .. " " .. damageType
        end
        damageText = damageText .. " damage to " .. defenderName
            .. BuildHitpointsSuffix(eventData)
        SpeakCombatQueued(damageText)
    else
        -- AttackedBy with damageAmount == 0 is rare (resisted or
        -- absorbed-by-temp-HP on a damaging roll).  Treat as a
        -- no-damage-but-hit message, distinct from an outright miss.
        SpeakCombatQueued(attackerName .. " " .. rollPrefix
            .. "hit " .. defenderName .. " for no damage")
    end
end

local function HandleMissedBy(eventData)
    local attackerName = eventData.attackerName or "Unknown"
    local defenderName = eventData.defenderName or "Unknown"

    -- Dedup: HitResultEvent also fires on misses (damage=0).  If
    -- HandleCombatHit just spoke a "missed <target>" or "hit
    -- <target> for no damage" announcement for this pair, skip
    -- the Osiris MissedBy relay.
    if WasCombatHitSpokenRecently(attackerName, defenderName) then
        return
    end

    local rollPrefix = BuildRollPrefixFragment(attackerName, defenderName)
    SpeakCombatQueued(attackerName .. " " .. rollPrefix
        .. "missed " .. defenderName)
end

-- Pending preview polls keyed by RollUuid.  The server fires the
-- preview immediately when the roll is computed (server-side, which
-- is instant on Y-press), but sighted players don't see the number
-- until the dice animation plays and the ResultHolder template
-- becomes visible -- triggered by the ActiveRoll widget's Tag DP
-- transitioning to "RevealResultAnimation" (see
-- ResultCountTemplateStyle in DiceAnimation.xaml:3009 and the
-- DieRollAnimation AnimDone handler in ActiveRoll_c.xaml:1637-1639).
-- That's the exact moment the number appears on screen, regardless
-- of which outcome template (success / fail / crit) plays -- each
-- has a different storyboard duration, so any fixed delay is wrong
-- for some subset of rolls.
--
-- The legacy C++ Ext.UI.SubscribeDPChanged hook that could have
-- given us this signal directly was deleted from the extender.
-- Poll the widget's Tag property at a tight cadence instead: bounded
-- to the animation window (cap at ~3s), and the entry is consumed
-- on either Tag reveal or the subsequent commit A-press.
local pendingRollPreviews = {}

-- Poll interval for widget Tag reads during the reveal wait.  100ms
-- is fast enough that the user doesn't perceive the gap between the
-- visual reveal and the speech; slow enough that the cost is
-- negligible (~20 reads max over a 2s animation).
local ROLL_PREVIEW_POLL_INTERVAL_MS = 100

-- Safety cap so a stuck / missing ActiveRoll widget doesn't leave a
-- poll running indefinitely.  NOT sized to the animation duration:
-- the server's OnChange fires at screen entry (BG3 computes the
-- roll immediately -- Y-press just triggers the visual reveal), so
-- the poll begins long BEFORE the user has pressed Y, and must
-- survive however long the user spends browsing bonuses.  Sized to
-- "longer than any reasonable browse session" so the timeout only
-- fires on a genuinely stuck widget, and on timeout we bail
-- SILENTLY -- speaking a preview when the reveal never happened
-- would be worse than saying nothing (the commit path will still
-- speak the full breakdown on A-press).
local ROLL_PREVIEW_MAX_WAIT_MS = 60000

-- Outcome text the reveal template puts on screen as TextBlocks.
-- BG3 displays one of these four translated strings at the moment
-- the number appears; we match literally (case-insensitive) to
-- identify which outcome rendered.  See SuccessResultTemplate and
-- FailResultTemplate in DiceAnimation.xaml (textBlockResult).
local OUTCOME_TEXTS = {
    ["CRITICAL SUCCESS"] = "critical success",
    ["CRITICAL FAILURE"] = "critical failure",
    ["SUCCESS"]          = "success",
    ["FAILURE"]          = "failure",
}

--- Scan the ActiveRoll widget's rendered TextBlocks for the reveal
--- content: the displayed die face (bare 1-20 integer) and the
--- outcome label.  Returns (dieFace, outcomeLabel) with either
--- or both as nil if not yet rendered.  The XAML places both
--- inside the ActiveRoll widget subtree, so reading from the
--- widget root picks them up regardless of template depth.
---
--- Critically, this reads what is ACTUALLY DISPLAYED on screen --
--- no server-side component tracking, no guessing about
--- advantage/disadvantage.  Whatever number the user would see if
--- they were sighted is the number we speak.
local function ReadActiveRollReveal()
    local findOk, activeRollElem = pcall(
        Ext.UI.FindNameInWidget, "ActiveRoll")
    if not findOk or not activeRollElem then
        return nil, nil
    end
    local readOk, entries = pcall(
        Ext.UI.ReadElementStructuredTextBlocks, activeRollElem)
    if not readOk or not entries or #entries == 0 then
        return nil, nil
    end
    local dieFace = nil
    local outcomeLabel = nil
    for _, entry in ipairs(entries) do
        local text = entry.text or ""
        if not dieFace and text:match("^%d+$") then
            local value = tonumber(text)
            if value and value >= 1 and value <= 20 then
                dieFace = value
            end
        end
        if not outcomeLabel then
            local mapped = OUTCOME_TEXTS[text:upper()]
            if mapped then outcomeLabel = mapped end
        end
        if dieFace and outcomeLabel then break end
    end
    return dieFace, outcomeLabel
end

--- Speak the reveal.  Matches the sighted experience: number + outcome.
local function SpeakRollReveal(rollerName, dieFace, outcomeLabel)
    local parts = { rollerName, "rolled " .. tostring(dieFace) }
    if outcomeLabel then
        parts[#parts + 1] = outcomeLabel
    end
    SpeakCombatInterrupt(table.concat(parts, ", "))
end

--- Poll the ActiveRoll widget for the reveal text.  Fires every
--- POLL_INTERVAL ms until either:
---   (a) Both number and outcome text are visible on screen, then
---       speak and stop.  This is the normal path.
---   (b) commit (HandleRollFinished) cancels the poll, speak the
---       full breakdown via RollFinished instead.
---   (c) MAX_WAIT elapses without either signal; bail silently
---       (skill check was canceled, widget torn down, etc).
---
--- We require BOTH number and outcome before speaking so we don't
--- announce "rolled 14" at the frame the dice land but before the
--- "SUCCESS" / "FAILURE" text fades in.
local function PollForReveal(pendingEntry, rollUuid, rollerName,
                             elapsedMs)
    local function cleanup()
        if rollUuid ~= "" then pendingRollPreviews[rollUuid] = nil end
    end
    if pendingEntry.canceled then
        cleanup()
        return
    end
    local dieFace, outcomeLabel = ReadActiveRollReveal()
    if dieFace and outcomeLabel then
        pendingEntry.canceled = true
        cleanup()
        SpeakRollReveal(rollerName, dieFace, outcomeLabel)
        return
    end
    local nextElapsedMs = elapsedMs + ROLL_PREVIEW_POLL_INTERVAL_MS
    if nextElapsedMs >= ROLL_PREVIEW_MAX_WAIT_MS then
        -- Timed out.  Bail silently.  The commit-side RollFinished
        -- still fires its full breakdown on A-press.
        pendingEntry.canceled = true
        cleanup()
        return
    end
    Ext.Timer.WaitFor(ROLL_PREVIEW_POLL_INTERVAL_MS, function()
        PollForReveal(pendingEntry, rollUuid, rollerName,
            nextElapsedMs)
    end)
end

--- Handle the server's RollPreview event.  The event tells us
--- "a roll is in flight, start watching the ActiveRoll widget for
--- the visual reveal."  We IGNORE the server's NaturalRoll field
--- -- it's populated on the first OnChange fire and may be a
--- preliminary die for advantage / disadvantage rolls that gets
--- overridden later.  The widget's rendered text carries the real
--- final die and outcome, so we read from there.
local function HandleRollPreview(eventData)
    if not ShouldSpeakRollDetail() then return end
    local rollBucket = eventData.rollBucket or ""
    -- Attack rolls merge roll detail into AttackedBy / MissedBy via
    -- BuildRollPrefixFragment at damage time -- skip the reveal
    -- preview path for those.
    if rollBucket == "attack" then return end

    local rollerName = eventData.rollerName or "Unknown"
    local rollUuid = eventData.rollUuid or ""

    local pendingEntry = { canceled = false }
    if rollUuid ~= "" then
        pendingRollPreviews[rollUuid] = pendingEntry
    end
    Ext.Timer.WaitFor(ROLL_PREVIEW_POLL_INTERVAL_MS, function()
        PollForReveal(pendingEntry, rollUuid, rollerName,
            ROLL_PREVIEW_POLL_INTERVAL_MS)
    end)
end

--- Cancel any pending preview poll for this roll.  Called from
--- HandleRollFinished so a fast A-press beats the reveal poll and
--- we skip the preview (the full commit-side breakdown covers it,
--- so the bare "rolled N" preview would just be redundant).
--- Assigned to the forward-declared local at the top of the file.
CancelPendingRollPreview = function(rollUuid)
    if not rollUuid or rollUuid == "" then return end
    local pendingEntry = pendingRollPreviews[rollUuid]
    if pendingEntry then
        pendingEntry.canceled = true
        pendingRollPreviews[rollUuid] = nil
    end
end

-- ---------------------------------------------------------------------------
-- Event dispatch
-- ---------------------------------------------------------------------------

local EVENT_HANDLERS = {
    CombatStarted      = HandleCombatStarted,
    CombatEnded        = HandleCombatEnded,
    RoundStarted       = HandleRoundStarted,
    TurnStarted        = HandleTurnStarted,
    Died               = HandleDied,
    StatusApplied      = HandleStatusApplied,
    StatusRemoved      = HandleStatusRemoved,
    AttackedBy         = HandleAttackedBy,
    MissedBy           = HandleMissedBy,
    RollFinished       = HandleRollFinished,
    RollPreview        = HandleRollPreview,
    -- HitResultEvent relay (server-side) fires once per combat
    -- attack resolution with the full roll + damage + HP picture.
    -- HandleCombatHit speaks the coherent announcement and
    -- suppresses the AttackedBy sub-damage fires that follow.
    CombatHit          = HandleCombatHit,
    -- Concentration interrupted on a party member.  Pairs with the
    -- existing Constitution-save announcement to tell the user
    -- which spell just dropped.  See server BootstrapServer.lua
    -- ConcentrationChanged subscription.
    ConcentrationLost  = HandleConcentrationLost,
}

local function HandleCombatEvent(eventData)
    local eventType = eventData.event
    if not eventType then return end

    local handler = EVENT_HANDLERS[eventType]
    if handler then
        handler(eventData)
    else
        Log.Debug("Combat: unknown event type '" .. eventType .. "'")
    end
end

-- Register net listener for combat events from server.
Ext.RegisterNetListener(COMBAT_CHANNEL,
    function(channel, payload, userId)
        local parseOk, eventData = pcall(Ext.Json.Parse, payload)
        if not parseOk or type(eventData) ~= "table" then
            Log.Error("Combat: bad event payload")
            return
        end
        local handleOk, handleErr = pcall(HandleCombatEvent, eventData)
        if not handleOk then
            Log.Error("Combat event handler: " .. tostring(handleErr))
        end
    end)

-- ---------------------------------------------------------------------------
-- On-demand combat info (for RS HUD reader)
-- ---------------------------------------------------------------------------

--- Read the turn order from entity components.
--- Returns a list of {name=string, isCurrent=bool, initiative=int,
--- entity=..., hp=int, maxHp=int} entries, or nil.
--- Assigned to the forward-declared `local ReadTurnOrder` above
--- so HandleCombatStarted can call it without recursion-order
--- issues.
ReadTurnOrder = function()
    local entitiesOk, entities = pcall(
        Ext.Entity.GetAllEntitiesWithComponent, "TurnOrder")
    if not entitiesOk or not entities or #entities == 0 then
        return nil
    end

    local turnEntries = {}

    --- Pull {hp, maxHp} off an entity's Health component.  Returns
    --- nil for entities without Health (pure scenery / props in the
    --- turn order), so the speaker can skip the HP phrase for those.
    local function ReadEntityHp(memberEntity)
        if not memberEntity then return nil end
        local readOk, hp = pcall(function()
            local health = memberEntity.Health
            if not health then return nil end
            local currentHp = tonumber(health.Hp)
            local maxHp = tonumber(health.MaxHp)
            if not currentHp or not maxHp then return nil end
            return { hp = currentHp, maxHp = maxHp }
        end)
        if readOk and hp then return hp end
        return nil
    end

    --- Pull the initiative roll value off an entity's
    --- CombatParticipant component.  Returns a number or nil.
    --- Verified against Combat.h:24 --
    --- `eoc::combat::ParticipantComponent.InitiativeRoll` is an
    --- int stored on every combatant at combat start.
    local function ReadEntityInitiative(memberEntity)
        if not memberEntity then return nil end
        local readOk, rollValue = pcall(function()
            local participant = memberEntity.CombatParticipant
            if not participant then return nil end
            return tonumber(participant.InitiativeRoll)
        end)
        if readOk and rollValue then return rollValue end
        return nil
    end

    for _, combatEntity in ipairs(entities) do
        local groupsOk, groups = pcall(function()
            return combatEntity.TurnOrder.Participants
        end)
        -- Try .Participants first, fall back to .Groups
        if not groupsOk or not groups then
            groupsOk, groups = pcall(function()
                return combatEntity.TurnOrder.Groups
            end)
        end
        if not groupsOk or not groups then break end

        for _, group in ipairs(groups) do
            -- Each group may have Members, or may be a direct entry.
            local members = nil
            local membersOk = false
            membersOk, members = pcall(function()
                return group.Members
            end)
            if membersOk and members then
                -- Group with Members array.
                for _, member in ipairs(members) do
                    local nameOk, memberName = pcall(function()
                        local memberEntity = member.Entity
                        if not memberEntity
                            or not memberEntity.DisplayName then
                            return nil
                        end
                        local nameKey =
                            memberEntity.DisplayName.NameKey
                        if nameKey and nameKey.Handle
                            and nameKey.Handle.Handle then
                            return Ext.Loca.GetTranslatedString(
                                nameKey.Handle.Handle)
                        end
                        return nil
                    end)

                    local isCurrent = false
                    pcall(function()
                        local memberEntity = member.Entity
                        if memberEntity
                            and memberEntity.TurnBased then
                            isCurrent =
                                memberEntity.TurnBased
                                    .IsActiveCombatTurn == true
                        end
                    end)

                    local hpInfo = ReadEntityHp(member.Entity)

                    if nameOk and memberName
                        and memberName ~= "" then
                        turnEntries[#turnEntries + 1] = {
                            name = memberName,
                            isCurrent = isCurrent,
                            hp = hpInfo and hpInfo.hp or nil,
                            maxHp = hpInfo and hpInfo.maxHp or nil,
                            initiative = ReadEntityInitiative(
                                member.Entity),
                            -- Entity reference so downstream code
                            -- can enumerate statuses, components,
                            -- etc. without having to re-scan by
                            -- display name (ambiguous for duplicate
                            -- enemies like "Intellect Devourer" x2).
                            entity = member.Entity,
                        }
                    end
                end
            else
                -- Direct entry (group IS the participant).
                local nameOk, memberName = pcall(function()
                    local memberEntity = group.Entity
                        or group.Character
                    if not memberEntity
                        or not memberEntity.DisplayName then
                        return nil
                    end
                    local nameKey =
                        memberEntity.DisplayName.NameKey
                    if nameKey and nameKey.Handle
                        and nameKey.Handle.Handle then
                        return Ext.Loca.GetTranslatedString(
                            nameKey.Handle.Handle)
                    end
                    return nil
                end)

                local isCurrent = false
                pcall(function()
                    local memberEntity = group.Entity
                        or group.Character
                    if memberEntity
                        and memberEntity.TurnBased then
                        isCurrent =
                            memberEntity.TurnBased
                                .IsActiveCombatTurn == true
                    end
                end)

                local hpInfo = ReadEntityHp(
                    group.Entity or group.Character)

                if nameOk and memberName
                    and memberName ~= "" then
                    turnEntries[#turnEntries + 1] = {
                        name = memberName,
                        isCurrent = isCurrent,
                        hp = hpInfo and hpInfo.hp or nil,
                        maxHp = hpInfo and hpInfo.maxHp or nil,
                        initiative = ReadEntityInitiative(
                            group.Entity or group.Character),
                        entity = group.Entity or group.Character,
                    }
                end
            end
        end

        -- Only need one TurnOrder entity.
        if #turnEntries > 0 then break end
    end

    return #turnEntries > 0 and turnEntries or nil
end

--- Speak the full turn order list.
--- Used by RS HUD reader (RS Right in combat).
local function SpeakTurnOrder()
    local turnEntries = ReadTurnOrder()
    if not turnEntries then
        SpeakCombatInterrupt("Turn order not available")
        return
    end

    -- Build each entry as "Current: Name HP N of M" (or just
    -- "Name" for entries without a Health component, like pure
    -- scenery with a TurnOrder slot).  The "HP" keyword keeps the
    -- two numbers from smearing into the next entry when TTS runs
    -- them together across a comma.
    local parts = {}
    for _, entry in ipairs(turnEntries) do
        local piece = entry.isCurrent
            and ("Current: " .. entry.name)
            or entry.name
        if entry.hp ~= nil and entry.maxHp ~= nil then
            piece = piece
                .. " HP " .. tostring(entry.hp)
                .. " of " .. tostring(entry.maxHp)
        end
        parts[#parts + 1] = piece
    end
    SpeakCombatInterrupt(
        "Turn order: " .. table.concat(parts, ", "))
end

-- ---------------------------------------------------------------------------
-- State management
-- ---------------------------------------------------------------------------

--- Reset combat state.  Called on GameStateChanged.
local function ResetState()
    inCombat = false
    currentTurnCharacterName = nil
    currentTurnCharacterGuid = nil
    currentRound = 0
    pendingRoundAnnouncement = nil
    statusLastAnnounceTime = {}
    attackRollCache = {}
end

--- Query: are we currently in combat?
local function IsInCombat()
    return inCombat
end

--- Query: current turn character name (or nil).
local function GetCurrentTurnName()
    return currentTurnCharacterName
end

--- Query: current round number (0 if not in combat).
local function GetCurrentRound()
    return currentRound
end

Log.Debug("Combat module loaded")

-- ============================================================================
-- Module Table
-- ============================================================================

BG3Access.Client.Combat = {
    IsInCombat        = IsInCombat,
    GetCurrentTurnName = GetCurrentTurnName,
    GetCurrentRound   = GetCurrentRound,
    ReadTurnOrder     = ReadTurnOrder,
    SpeakTurnOrder    = SpeakTurnOrder,
    ResetState        = ResetState,
}
