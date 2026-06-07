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
-- DiceRolls owns all roll-related narration (attack-roll prefix in
-- damage speech, standalone save / check outcomes, ActiveRoll widget
-- reveal preview).  Loaded before Combat per the _Init order, so this
-- reference is always populated when Combat.lua runs.
local DiceRolls = BG3Access.Client.DiceRolls
-- Cutscene owns audio-description playback in response to the
-- server's Osi.MoviePlay / MovieFinished relay (BG3Access_Events
-- carries MovieStarted / MovieFinished entries alongside combat
-- events, dispatched through the same EVENT_HANDLERS table below).
local Cutscene = BG3Access.Client.Cutscene

-- User-facing setting owned by Combat: per-swing damage announcements.
-- The roll-detail toggle (diceRollDetailEnabled) lives in DiceRolls.lua
-- since it gates more than just combat now.
if BG3Access.Client.Settings then
    BG3Access.Client.Settings.RegisterDefault(
        "combatDamageEnabled", true, { true, false },
        "Combat damage announcements", "verbositySettings")
    -- Tier preset for the Global verbosity dial.  Damage stays on at
    -- every tier (essential info for blind play).
    BG3Access.Client.Settings.RegisterTierPresets(
        "combatDamageEnabled",
        { brief = true, normal = true, verbose = true })
end

--- IsCombatDamageEnabled: convenience accessor for the per-attack
--- hit-resolution speech gate.  Defaults to enabled when Settings
--- isn't loaded yet (graceful fallback).
local function IsCombatDamageEnabled()
    local Settings = BG3Access.Client.Settings
    if Settings and Settings.Get
        and Settings.Get("combatDamageEnabled") == false then
        return false
    end
    return true
end

-- Net channel for all server-relayed narration events: combat events
-- AND dice rolls (BG3 fires rolls during exploration too, so the
-- channel isn't combat-specific despite the historic name).  Combat.lua
-- owns the listener registration; events get dispatched to either
-- Combat handlers or DiceRolls handlers via EVENT_HANDLERS below.
local EVENTS_CHANNEL = "BG3Access_Events"

-- ---------------------------------------------------------------------------
-- Combat state
-- ---------------------------------------------------------------------------

local inCombat = false
local currentTurnCharacterName = nil
local currentTurnCharacterGuid = nil
local currentRound = 0
local pendingRoundAnnouncement = nil

-- Initiative threshold below which a participant is treated as a
-- non-combatant -- environment objects (illithid bulbs, chests,
-- barrels, etc.) that BG3 puts in the turn order with sentinel
-- InitiativeRoll = -20 so they sit at the bottom and never act.
-- Worst-case legitimate roll is 1 + (-5) = -4 (DEX 1 creature
-- rolling a natural 1), so -20 cleanly separates sentinels from
-- real combatants.  Used in BOTH ReadTurnOrder (for the "Initiative:
-- X, Y, Z" announcement and the RS-Right HUD reader) AND
-- HandleTurnStarted (so the user doesn't hear "Bulb's turn",
-- "Chest's turn" cycling through every non-combatant between
-- real turns).
local NON_COMBATANT_INITIATIVE_THRESHOLD = -20

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

    -- Force GPS fully off on combat start.  SuspendForCombat:
    --   - sets gpsMode = OFF (so ticks don't run proximity / hazard
    --     scans during enemy turns, and AutoWalk's "arrived" event
    --     can't re-enter Exploration mode mid-combat)
    --   - calls ClearGPSState which clears autoWalkActive, the entity
    --     list (entityListOpen=false), tracking target, all latch
    --     state -- so resume-after-combat starts from a clean slate
    --   - stays silent (combat already has Initiative + first-turn
    --     announcement playing; an extra "GPS off" alert would drown
    --     them out)
    -- Without this, an AutoWalk that was in flight when combat
    -- started would, on arrival, fire EnterExplorationMode and
    -- re-enable proximity scans during the enemy's first turn.
    -- Falls back to CloseEntityList (older API) for safety on
    -- older WorldNav versions that don't export SuspendForCombat.
    local WorldNav = BG3Access.Client.WorldNav
    if WorldNav and WorldNav.SuspendForCombat then
        WorldNav.SuspendForCombat()
    elseif WorldNav and WorldNav.CloseEntityList then
        WorldNav.CloseEntityList()
    end

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
        BG3Access.Client.Scheduler.RunAfterMs(150, function()
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

    -- Skip non-combatants.  BG3 fires TurnStarted for every entity
    -- in the turn order, including environment objects (bulbs, chests,
    -- barrels) with sentinel InitiativeRoll = -20.  Without this
    -- filter the user hears "Chest's turn", "Bulb's turn" cycling
    -- through every non-combatant between real turns -- pure noise.
    -- Same threshold ReadTurnOrder uses to filter the spoken
    -- initiative announcement.
    if eventData.characterGuid then
        local entityOk, entity = pcall(Ext.Entity.Get, eventData.characterGuid)
        if entityOk and entity then
            local initOk, initiative = pcall(function()
                if not entity.CombatParticipant then return nil end
                return tonumber(entity.CombatParticipant.InitiativeRoll)
            end)
            if initOk and initiative
                and initiative <= NON_COMBATANT_INITIATIVE_THRESHOLD then
                Log.Debug("Combat.HandleTurnStarted: skipping non-combatant '"
                    .. characterName .. "' (initiative "
                    .. initiative .. ")")
                -- IMPORTANT: do NOT update currentTurnCharacterName /
                -- currentTurnCharacterGuid for non-combatants.  Other
                -- modules query those to know whose turn it actually
                -- is for damage attribution, status filtering, etc.
                -- Letting a chest set itself as "current turn" would
                -- confuse downstream callers.
                return
            end
        end
    end

    -- Real combatant: update state and announce.
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
        -- Party-member down is urgent: interrupt anything in
        -- progress so the player hears "Tav is down" immediately.
        SpeakCombatInterrupt(characterName .. " is down")
    else
        -- Enemy death is informational and arrives RIGHT after the
        -- killing-blow announcement (e.g. "...0 of 15 remaining").
        -- Using interrupt cuts off the kill-blow speech mid-sentence.
        -- Queue instead so the kill-blow finishes, then "X died"
        -- naturally follows.
        SpeakCombatQueued(characterName .. " died")
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

--- Verbose-tier dice breakdown for damage rolls.  Server populates
--- eventData.damageRolls from hitDesc.Damage.DamageRolls -- a per-
--- damage-type, per-instance array of {damageType, diceCount,
--- diceSize, modifier, naturalRoll, total, isNegative}.  Returns
--- nil when the array is empty (status ticks, surface ticks, and
--- other pre-rolled / static damage paths) OR when no entry has
--- real dice (modifier-only entries skip aloud since "rolled 0 on
--- 0 dice plus 2" reads worse than the simple damage phrase).
---
--- Format examples (used as a clause inserted before the existing
--- "for 4 slashing damage" phrase):
---   "rolled 2 on 1d4 plus 2"           single instance, +mod
---   "rolled 8 on 1d10"                  single instance, no mod
---   "rolled 5 on 1d6 minus 1"           single instance, -mod
---   "rolled 5 on 1d8 plus 3, plus rolled 2 on 1d4"   multi-type
local function BuildDamageRollPhrase(damageRolls)
    if not damageRolls or #damageRolls == 0 then return nil end
    local instances = {}
    for _, roll in ipairs(damageRolls) do
        local hasDice = (roll.diceCount or 0) > 0 and roll.diceSize
        if hasDice then
            local part = "rolled " .. tostring(roll.naturalRoll or 0)
                .. " on " .. tostring(roll.diceCount)
                .. "d" .. tostring(roll.diceSize)
            local modifier = tonumber(roll.modifier) or 0
            if modifier > 0 then
                part = part .. " plus " .. tostring(modifier)
            elseif modifier < 0 then
                part = part .. " minus " .. tostring(-modifier)
            end
            instances[#instances + 1] = part
        end
    end
    if #instances == 0 then return nil end
    return table.concat(instances, ", plus ")
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
    if DiceRolls.IsDiceRollDetailEnabled() and hasRoll then
        local rollPrefix = DiceRolls.BuildRollPrefix({
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
        -- Dice breakdown clause inserted before the damage phrase:
        --   "...hit Devourer, rolled 2 on 1d4 plus 2, for 4 slashing
        --    damage, 6 of 15 remaining"
        -- Gated by the dice-roll-detail toggle alone -- damage dice
        -- are part of the roll detail the user opted into via the
        -- diceRollDetailEnabled setting.  The Global verbosity dial
        -- drives that toggle via its registered tier presets
        -- (brief=false / normal=false / verbose=true), so cycling
        -- Global verbosity has the expected effect, but the toggle
        -- itself is authoritative at speech time.  Skipped when
        -- damageRolls is empty (status / surface ticks have no
        -- dice) so a Burning tick stays as "Burning, dealt 2 fire
        -- damage..." with no dice prefix.
        if DiceRolls.IsDiceRollDetailEnabled() then
            local dicePhrase = BuildDamageRollPhrase(eventData.damageRolls)
            if dicePhrase then
                parts[#parts + 1] = dicePhrase
            end
        end
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

--- Speak a bonus-damage instance: the second-or-later attack-like
--- damage event in a burst (Sneak Attack, Smite, Hex, magic-weapon
--- proc).  The primary attack event already announced attacker +
--- to-hit roll + main damage, so the bonus event reads as a
--- continuation: "plus 5 piercing from Sneak Attack".  When the
--- source spell name isn't resolvable, falls back to "plus 5
--- piercing damage" so the player still hears it landed.
---
--- Verbose tier still emits the dice breakdown for the bonus die
--- ("rolled 5 on 1d6") inside the same clause so the player can
--- hear the actual roll.
---
--- HP suffix and lethal/down announcements still attach to this
--- event when it's the burst's last (server marked it on the
--- final event).
local function SpeakBonusHit(eventData)
    local damageAmount = tonumber(eventData.damageAmount) or 0
    if damageAmount == 0 then return end
    local targetName = eventData.targetName or "Unknown"
    local spellName = eventData.spellName or ""

    local parts = { "plus" }

    -- Dice breakdown clause lives between "plus" and the damage
    -- phrase: "plus rolled 5 on 1d6 for 5 piercing damage".
    -- Toggle-authority model: gated by diceRollDetailEnabled alone,
    -- the Global verbosity dial drives the toggle indirectly via
    -- tier presets.
    if DiceRolls.IsDiceRollDetailEnabled() then
        local dicePhrase = BuildDamageRollPhrase(eventData.damageRolls)
        if dicePhrase then
            parts[#parts + 1] = dicePhrase
        end
    end

    local damageText = FormatCombatDamage(
        damageAmount, eventData.damagePhrase)
    if damageText ~= "" then
        if spellName ~= "" then
            parts[#parts + 1] = damageText .. " from " .. spellName
        else
            parts[#parts + 1] = damageText
        end
    end

    local hpSuffix = FormatHpSuffix(
        tonumber(eventData.defenderHp),
        tonumber(eventData.defenderMaxHp))
    if hpSuffix ~= "" then parts[#parts + 1] = hpSuffix end
    if eventData.lethal == true then
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
    if not IsCombatDamageEnabled() then return end
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

    -- Bonus damage: server marked this as a follow-up attack-like
    -- event in a multi-event burst (Sneak Attack, Smite, magic-
    -- weapon proc, Hex, Hunter's Mark).  The primary event already
    -- announced the to-hit roll and main damage; speak this one as
    -- a continuation clause.  Cache already marked by the primary,
    -- so AttackedBy follow-ups stay suppressed.
    if eventData.isBonusDamage == true then
        SpeakBonusHit(eventData)
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

--- Action declaration speech: "X cast Y on Z" or "X cast Y" (no
--- target).  Server only relays this for non-party casters in active
--- combat, so we never double up with the radial menu's "Tav cast
--- Fire Bolt" announcement.  The follow-up damage / save event will
--- arrive as a separate CombatHit / AttackedBy / RollFinished and
--- speak the outcome -- two announcements per cast is intentional
--- and matches the sighted experience (spell name pops + damage
--- number floats).
local function HandleSpellCastDeclared(eventData)
    local casterName = eventData.casterName or "Unknown"
    local spellName = eventData.spellName
    local targetName = eventData.targetName

    local text
    if spellName and spellName ~= "" then
        if targetName and targetName ~= "" then
            text = casterName .. " cast " .. spellName
                .. " on " .. targetName
        else
            text = casterName .. " cast " .. spellName
        end
    else
        -- Spell name failed to resolve (rare -- prototype lookup
        -- found nothing).  Fall back to a generic phrasing rather
        -- than reading the raw "Target_Foo" prototype string.
        if targetName and targetName ~= "" then
            text = casterName .. " cast a spell on " .. targetName
        else
            text = casterName .. " cast a spell"
        end
    end
    SpeakCombatQueued(text)
end

local function HandleAttackedBy(eventData)
    if not IsCombatDamageEnabled() then return end
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

    local rollPrefix = DiceRolls.BuildRollPrefixFragment(attackerName, defenderName)

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
    if not IsCombatDamageEnabled() then return end
    local attackerName = eventData.attackerName or "Unknown"
    local defenderName = eventData.defenderName or "Unknown"

    -- Dedup: HitResultEvent also fires on misses (damage=0).  If
    -- HandleCombatHit just spoke a "missed <target>" or "hit
    -- <target> for no damage" announcement for this pair, skip
    -- the Osiris MissedBy relay.
    if WasCombatHitSpokenRecently(attackerName, defenderName) then
        return
    end

    local rollPrefix = DiceRolls.BuildRollPrefixFragment(attackerName, defenderName)
    SpeakCombatQueued(attackerName .. " " .. rollPrefix
        .. "missed " .. defenderName)
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
    -- Action declaration relay (UsingSpellOnTarget / UsingSpell on
    -- the server).  In BG3 every action -- including Main Hand
    -- Attack, Claws, Help, Shove -- is a spell in the engine, so
    -- this single hook covers the full surface.  Server gates to
    -- non-party casters in active combat and dedups the parallel
    -- UsingSpell+UsingSpellOnTarget pair the engine fires for each
    -- targeted cast.  Closes the gap a blind player has compared
    -- to a sighted player who sees the spell-name overlay.
    SpellCastDeclared  = HandleSpellCastDeclared,
    -- Dice-roll events live in DiceRolls.lua (the channel itself
    -- carries both combat and non-combat events; routing splits
    -- them here at the dispatcher).
    RollFinished       = DiceRolls.HandleRollFinished,
    RollPreview        = DiceRolls.HandleRollPreview,
    -- HitResultEvent relay (server-side) fires once per combat
    -- attack resolution with the full roll + damage + HP picture.
    -- HandleCombatHit speaks the coherent announcement and
    -- suppresses the AttackedBy sub-damage fires that follow.
    -- For multi-event chains (Fire Bolt + Burning), the server
    -- emits one CombatHit per event, with HP suffix only on the
    -- last event in the burst.  See FlushDamageBurst on the
    -- server for the rationale.
    CombatHit          = HandleCombatHit,
    -- Concentration interrupted on a party member.  Pairs with the
    -- existing Constitution-save announcement to tell the user
    -- which spell just dropped.  See server BootstrapServer.lua
    -- ConcentrationChanged subscription.
    ConcentrationLost  = HandleConcentrationLost,
    -- Cinematic / audio-description events (server relays
    -- Osi.MoviePlay and Osi.MovieFinished through this channel
    -- alongside combat events; routing handled by event.event
    -- string).  Cutscene.lua looks up the AD track by movie name
    -- and plays / stops Ext.Audio accordingly.
    MovieStarted       = Cutscene.HandleMovieStarted,
    MovieFinished      = Cutscene.HandleMovieFinished,
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

-- Register net listener for the shared events channel (combat events
-- AND dice rolls).  Dispatched to Combat.lua handlers or DiceRolls
-- handlers per the EVENT_HANDLERS table above.
Ext.RegisterNetListener(EVENTS_CHANNEL,
    function(channel, payload, userId)
        local parseOk, eventData = pcall(Ext.Json.Parse, payload)
        if not parseOk or type(eventData) ~= "table" then
            Log.Error("Events channel: bad event payload")
            return
        end
        local handleOk, handleErr = pcall(HandleCombatEvent, eventData)
        if not handleOk then
            Log.Error("Events channel handler: " .. tostring(handleErr))
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

    -- Filter out non-combatants.  Threshold is the module-level
    -- NON_COMBATANT_INITIATIVE_THRESHOLD constant (shared with
    -- HandleTurnStarted -- same rule applied in both code paths).
    -- See its declaration near the top of this file for rationale.
    --
    -- Keep entries with unknown initiative (nil) -- failing to read
    -- the component shouldn't silently drop a combatant.  Better to
    -- over-announce than under-announce when data is missing.
    local filteredEntries = {}
    local droppedCount = 0
    for _, entry in ipairs(turnEntries) do
        if not entry.initiative
            or entry.initiative > NON_COMBATANT_INITIATIVE_THRESHOLD then
            filteredEntries[#filteredEntries + 1] = entry
        else
            droppedCount = droppedCount + 1
        end
    end
    if droppedCount > 0 and Log then
        Log.Debug("Combat.ReadTurnOrder: filtered "
            .. droppedCount
            .. " non-combatant entries (initiative <= "
            .. NON_COMBATANT_INITIATIVE_THRESHOLD
            .. ")")
    end
    turnEntries = filteredEntries

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

--- Reset combat state.  Called on GameStateChanged.  Also delegates
--- to DiceRolls.ResetState so cached attack-roll data and pending
--- preview polls clear at the same time (they used to live in this
--- file, so resetting them was inline; now they're in the DiceRolls
--- module and we call across).
local function ResetState()
    inCombat = false
    currentTurnCharacterName = nil
    currentTurnCharacterGuid = nil
    currentRound = 0
    pendingRoundAnnouncement = nil
    statusLastAnnounceTime = {}
    if DiceRolls and DiceRolls.ResetState then
        DiceRolls.ResetState()
    end
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
    IsInCombat         = IsInCombat,
    GetCurrentTurnName = GetCurrentTurnName,
    GetCurrentRound    = GetCurrentRound,
    ReadTurnOrder      = ReadTurnOrder,
    SpeakTurnOrder     = SpeakTurnOrder,
    ResetState         = ResetState,
}
