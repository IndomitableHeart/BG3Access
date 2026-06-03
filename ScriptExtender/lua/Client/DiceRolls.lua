-- ============================================================================
-- BG3Access DiceRolls Module
--
-- All dice-roll narration, independent of combat / non-combat context.
-- BG3's ActiveRoll widget hosts every d20 the engine surfaces to the
-- player: attack rolls, damage rolls, saving throws (death saves,
-- ability saves), skill checks (Sleight of Hand, Persuasion, Perception,
-- Investigation, ...) during dialogue or exploration, and lockpicking /
-- disarm-trap checks.  This module owns:
--
--   * The ActiveRoll widget reveal pipeline: poll the widget's
--     DataContext while the dice animate, speak the natural d20 + total
--     + outcome + reroll-prompt when the result card lands.  Multi-cycle
--     aware: a single ActiveRoll session can host the original roll
--     plus inspiration / try-again rerolls, and we speak each cycle.
--
--   * The commit-side relay (server's RollFinished event): full
--     breakdown of saves and checks ("Tav rolled 14, Wisdom save,
--     DC 13, passed").  Attack rolls go through CacheAttackRoll instead
--     -- they merge into the damage / miss speech via
--     BuildRollPrefixFragment.
--
--   * The roll-detail setting (diceRollDetailEnabled): one toggle
--     that gates everything in this module.  Off = silent dice; on =
--     full narration.  Tier presets attach it to the Global verbosity
--     dial (verbose tier on, brief / normal off) because the per-attack
--     "rolled X" prefix is the chattiest combat detail.
--
-- Events arrive on the BG3Access_Events net channel, dispatched into
-- this module by Combat.lua's EVENT_HANDLERS table (Combat.lua owns the
-- listener registration; the channel itself is event-generic, not
-- combat-specific).
-- ============================================================================

local Log = BG3Access.Client.Log
local SpeechData = BG3Access.Client.SpeechData

-- ---------------------------------------------------------------------------
-- Setting registration
-- ---------------------------------------------------------------------------

-- Single user-facing toggle that gates EVERY dice-roll announcement
-- this module makes: the attack-roll prefix in damage speech, the
-- stand-alone save / check announcements, and the ActiveRoll reveal
-- preview.  Default on -- without roll detail a blind player can't tell
-- whether a missed attack was "rolled a 3" (unlucky) vs "rolled a 19,
-- missed by 1" (close call, modifier issue) which changes their
-- subsequent decisions.
--
-- Renamed from the legacy "combatRollsEnabled" key during the
-- Combat.lua / DiceRolls.lua split -- the setting is no longer
-- combat-specific, so the name shouldn't pretend it is.  Users will
-- see this default to true after the rename (their previous
-- combatRollsEnabled preference doesn't migrate); easy to flip back
-- off if they had it disabled.
if BG3Access.Client.Settings then
    BG3Access.Client.Settings.RegisterDefault(
        "diceRollDetailEnabled", true, { true, false },
        "Dice roll detail", "verbositySettings")
    BG3Access.Client.Settings.RegisterTierPresets(
        "diceRollDetailEnabled",
        { brief = false, normal = false, verbose = true })
end

--- IsDiceRollDetailEnabled: convenience accessor for the dice-roll
--- speech gate.  Covers all roll narration in this module.  Defaults
--- to enabled when Settings isn't loaded yet (graceful fallback).
local function IsDiceRollDetailEnabled()
    local Settings = BG3Access.Client.Settings
    if Settings and Settings.Get
        and Settings.Get("diceRollDetailEnabled") == false then
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Speech helpers
-- ---------------------------------------------------------------------------

--- Speak text with interrupt (cuts off previous speech).  Dice-roll
--- events use Alert speech rather than the SpeechData field system
--- because they're background narration, not focused-element data.
local function SpeakInterrupt(text)
    if not text or text == "" then return end
    SpeechData.Alert(text, "interrupt")
end

--- Speak text queued (appends after current speech).  Used for
--- save / check outcomes that should follow the damage event that
--- triggered them (concentration save after a hit, death save after
--- downing) so the cause-effect ordering is preserved.
local function SpeakQueued(text)
    if not text or text == "" then return end
    SpeechData.Alert(text, "queue")
end

-- ---------------------------------------------------------------------------
-- Attack-roll cache (server fires the roll microseconds before the
-- matching AttackedBy / MissedBy Osiris event; cache briefly so the
-- damage / miss handlers can prepend "rolled N plus M, total X" to
-- their speech).
-- ---------------------------------------------------------------------------

local ROLL_CACHE_TTL_MS = 500

local attackRollCache = {}  -- "<attacker>|<defender>" -> {data, expiresAtMs}

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

-- ---------------------------------------------------------------------------
-- Roll prefix formatting (used by both attack-roll merge and the
-- save / check standalone speech)
-- ---------------------------------------------------------------------------

--- Format a "rolled N plus M" fragment.  Advantage / disadvantage
--- get a short suffix.  Natural 20 / natural 1 become "critical hit"
--- / "critical miss" phrasing so the user hears the crit immediately.
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

--- Build the optional "rolled N plus M, total X" fragment that
--- prepends to damage / miss speech when roll detail is cached AND
--- the user has dice-roll detail enabled.  Returns a trailing period
--- + space so callers can concatenate directly, or an empty string.
--- Public: Combat.lua's HandleAttackedBy / HandleMissedBy call this.
local function BuildRollPrefixFragment(attackerName, defenderName)
    if not IsDiceRollDetailEnabled() then return "" end
    local rollData = ConsumeAttackRoll(attackerName, defenderName)
    if not rollData then return "" end
    return BuildRollPrefix(rollData) .. ".  "
end

-- ---------------------------------------------------------------------------
-- Enum / skill name humanization (used by save / check speech)
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Standalone save / check speech (server's RollFinished event for
-- the "save" and "check" buckets)
-- ---------------------------------------------------------------------------

--- Speak a standalone saving-throw outcome.  Format:
---   "<roller> rolled <natural> plus <mod>, total <N>,
---    <ability> save DC <DC>, passed/failed."
--- DC phrase omitted when the server reported no DC.
local function HandleRollFinishedSave(eventData)
    if not IsDiceRollDetailEnabled() then return end
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
    SpeakQueued(table.concat(parts, ", "))
end

--- Speak a standalone skill / ability check outcome.  Same shape as
--- the save handler but uses skill name when available.
local function HandleRollFinishedCheck(eventData)
    if not IsDiceRollDetailEnabled() then return end
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

    -- Queue (not interrupt), same rationale as saves: an in-context
    -- check is typically adjacent to the event that triggered it;
    -- interrupting cuts off the cause.  Out-of-context checks drain
    -- the queue immediately since nothing else is queued.
    SpeakQueued(table.concat(parts, ", "))
end

-- ---------------------------------------------------------------------------
-- ActiveRoll widget reveal pipeline (the "RollPreview" path)
-- ---------------------------------------------------------------------------

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
-- Poll the widget's DataContext at a tight cadence instead.
local pendingRollPreviews = {}

-- Poll interval for widget reads during the reveal wait.  100ms is
-- fast enough that the user doesn't perceive the gap between the
-- visual reveal and the speech; slow enough that the cost is
-- negligible (~20 reads max over a 2s animation).
local ROLL_PREVIEW_POLL_INTERVAL_MS = 100

-- Safety cap so a stuck / missing ActiveRoll widget doesn't leave a
-- poll running indefinitely.  NOT sized to the animation duration:
-- the server's OnChange fires at screen entry (BG3 computes the
-- roll immediately -- Y-press just triggers the visual reveal), so
-- the poll begins long BEFORE the user has pressed Y, and must
-- survive however long the user spends browsing bonuses AND any
-- subsequent rerolls.  Sized to "longer than any reasonable
-- session" so the timeout only fires on a genuinely stuck widget.
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

--- Read the reveal content from the ActiveRoll widget:
---   * dieFace      -- the natural d20 value, from DataContext.FinalResult.
---                     This is the actual die face that physically
---                     rolled (the number sighted players see during
---                     the spin animation as the die comes to rest).
---   * totalNumber  -- die + modifiers, from DataContext.ResultNumber.
---                     The total the game compares to the DC.  Shown
---                     prominently in the d20 visual on the FAILURE
---                     card (BG3 displays the total there, not the
---                     natural die).  May equal dieFace when there's
---                     no modifier on the roll.
---   * outcomeLabel -- which outcome card rendered (success / failure /
---                     critical success / critical failure), via the
---                     rendered TextBlocks (the outcome word is what
---                     BG3 actually puts on screen).
---   * inspirationCount    -- DataContext.InspirationPoints.  Half of
---                            the visibility predicate for the
---                            InspirationRerollHolder UI: see XAML
---                            ActiveRoll_c.xaml:1926-1932.
---   * canRespondToCommands -- DataContext.CanRespondToCommands.  Other
---                            half of the same predicate.  False during
---                            the dice animation, flips True when the
---                            result card settles and input is allowed.
---   * contextObjectCount   -- DataContext.ContextObjectCount.  Used
---                            together with rollContext to decide
---                            whether the "Try Again" prompt is visible
---                            (XAML 1899-1907: lockpick / disarm-trap
---                            with >1 tools).
---   * rollContext          -- DataContext.RollContext.  String like
---                            "Lockpick" / "DisarmTrap" / etc.; gates
---                            the Try Again prompt by activity type.
---   * widgetPresent        -- boolean.  False when FindNameInWidget
---                            cannot locate the ActiveRoll widget --
---                            meaning the player dismissed the card
---                            (A-press / Continue) and the widget was
---                            torn down.  Lets the poll loop know to
---                            stop without false-positive bails on the
---                            mid-animation frames where all numeric
---                            fields read as nil/zero.
--- Returns (dieFace, totalNumber, outcomeLabel, inspirationCount,
---          canRespondToCommands, contextObjectCount, rollContext,
---          widgetPresent) with any nil if not yet rendered.
local function ReadActiveRollReveal()
    local findOk, activeRollElem = pcall(
        Ext.UI.FindNameInWidget, "ActiveRoll")
    if not findOk or not activeRollElem then
        return nil, nil, nil, nil, nil, nil, nil, false
    end
    local dieFace = nil
    local totalNumber = nil
    local inspirationCount = nil
    local canRespondToCommands = nil
    local contextObjectCount = nil
    local rollContext = nil
    pcall(function()
        local dataContext = activeRollElem.DataContext
        if dataContext then
            local finalResultValue = tonumber(dataContext.FinalResult)
            if finalResultValue and finalResultValue > 0 then
                dieFace = finalResultValue
            end
            local resultNumberValue = tonumber(dataContext.ResultNumber)
            if resultNumberValue and resultNumberValue > 0 then
                totalNumber = resultNumberValue
            end
            local inspirationValue =
                tonumber(dataContext.InspirationPoints)
            if inspirationValue and inspirationValue >= 0 then
                inspirationCount = inspirationValue
            end
            -- CanRespondToCommands comes through the bridge as a Lua
            -- boolean (the dump logs it as true/false).
            local canRespondValue = dataContext.CanRespondToCommands
            if canRespondValue ~= nil then
                canRespondToCommands = (canRespondValue == true)
            end
            local contextCountValue =
                tonumber(dataContext.ContextObjectCount)
            if contextCountValue and contextCountValue >= 0 then
                contextObjectCount = contextCountValue
            end
            local rollContextValue = dataContext.RollContext
            if type(rollContextValue) == "string" then
                rollContext = rollContextValue
            end
        end
    end)
    local outcomeLabel = nil
    local readOk, entries = pcall(
        Ext.UI.ReadElementStructuredTextBlocks, activeRollElem)
    if readOk and entries then
        for _, entry in ipairs(entries) do
            local entryText = entry.text or ""
            local mapped = OUTCOME_TEXTS[entryText:upper()]
            if mapped then
                outcomeLabel = mapped
                break
            end
        end
    end
    return dieFace, totalNumber, outcomeLabel, inspirationCount,
        canRespondToCommands, contextObjectCount, rollContext, true
end

--- Speak the reveal.  Matches the sighted experience:
---   * dieFace              -- "rolled N" -- what the die physically
---                             showed during the spin animation.
---   * totalNumber          -- "total M" -- die + modifiers, the number
---                             BG3 compares to the DC and that gets
---                             displayed on the FAILURE card.  Omitted
---                             when it equals the natural die
---                             (no-modifier rolls), so we don't say
---                             "rolled 14, total 14" redundantly.
---   * outcomeLabel         -- "success" / "failure" / etc., word that
---                             appeared on the reveal card.
---   * inspirationCount     -- number of Inspiration points the player
---                             has.  Half of the InspirationRerollHolder
---                             predicate.
---   * canRespondToCommands -- whether the failure card has settled and
---                             input is permitted.  Other half of the
---                             predicate.  Both halves required.
---   * contextObjectCount   -- count of usable tools (thieves' tools,
---                             etc.) for the Try Again mechanism.
---   * rollContext          -- "Lockpick" / "DisarmTrap" / etc.; gates
---                             the Try Again prompt by activity type.
--- Predicates mirror ActiveRoll_c.xaml triggers:
---   InspirationRerollHolder: canRespond + InspirationPoints > 0
---     (line 1926-1932)
---   TryAgainHolder: canRespond + RollContext in {Lockpick, DisarmTrap}
---     + ContextObjectCount > 1 (line 1899-1907)
--- Both can be true simultaneously (lockpick failure with both
--- inspiration AND spare tools), so we announce them additively.
--- Any value may be nil; speech still fires with whatever subset is
--- available.  Server-side RollFinished still relays the full
--- breakdown a moment later.
local function SpeakRollReveal(rollerName, dieFace, totalNumber,
                               outcomeLabel, inspirationCount,
                               canRespondToCommands, contextObjectCount,
                               rollContext)
    local parts = { rollerName }
    if dieFace then
        parts[#parts + 1] = "rolled " .. tostring(dieFace)
    end
    if totalNumber and totalNumber ~= dieFace then
        parts[#parts + 1] = "total " .. tostring(totalNumber)
    end
    if outcomeLabel then
        parts[#parts + 1] = outcomeLabel
    end
    local isFailure = outcomeLabel == "failure"
        or outcomeLabel == "critical failure"
    if isFailure and canRespondToCommands then
        if inspirationCount and inspirationCount > 0 then
            -- The (N) shown in "Use Inspiration (N)" on screen is the
            -- player's available inspiration count (XAML binds the Run
            -- directly to InspirationPoints), not the per-reroll cost.
            -- A reroll always costs 1 point; the count tells the
            -- player how many they have to spend.  We mirror the
            -- on-screen count so a sighted-parity user knows their
            -- reserve.
            local rerollWord = "inspiration point"
            if inspirationCount ~= 1 then
                rerollWord = "inspiration points"
            end
            parts[#parts + 1] = "X to reroll, "
                .. tostring(inspirationCount) .. " "
                .. rerollWord .. " available"
        end
        local isToolContext = rollContext == "Lockpick"
            or rollContext == "DisarmTrap"
        if isToolContext and contextObjectCount
            and contextObjectCount > 1 then
            -- ContextObjectCount is the current tool count; -1 because
            -- the current attempt is already "using" one of them per
            -- the XAML's "({ContextObjectCount-1})" display.  Spare
            -- tools available for future Try Again attempts.
            local spareTools = contextObjectCount - 1
            local toolsWord = "set"
            if spareTools ~= 1 then
                toolsWord = "sets"
            end
            parts[#parts + 1] = "Y to try again, "
                .. tostring(spareTools) .. " spare "
                .. toolsWord .. " of tools"
        end
    end
    SpeakInterrupt(table.concat(parts, ", "))
end

--- Poll the ActiveRoll widget for reveal text across one or more
--- roll cycles.  A single ActiveRoll session can host multiple rolls
--- when the player uses inspiration ("Roll Again") or another set of
--- tools ("Try Again") on a failure -- each reroll re-runs the dice
--- animation and renders a fresh outcome card.  Server-side
--- RollPreview only fires for the INITIAL roll, so the reroll's
--- outcome won't trigger a new HandleRollPreview call.  Therefore we
--- keep polling the widget after speaking the first outcome and
--- re-speak whenever the (dieFace, outcomeLabel) pair changes.
---
--- Exit conditions:
---   (a) Widget gone (FindNameInWidget returned nil) -- player
---       pressed A / Continue, the ActiveRoll widget was torn down.
---   (b) Commit-side RollFinished canceled this entry (server-side
---       speech path will deliver the full breakdown).
---   (c) MAX_WAIT elapsed -- safety cap, normally unreachable.
---
--- Per-cycle speech triggers when BOTH dieFace and outcomeLabel are
--- non-nil AND differ from the last spoken pair.  Mid-animation
--- frames (dieFace=0, outcomeLabel=nil) are skipped automatically by
--- the differ-from-last check.
local function PollForReveal(pendingEntry, rollUuid, rollerName,
                             elapsedMs)
    local function cleanup()
        if rollUuid ~= "" then pendingRollPreviews[rollUuid] = nil end
    end
    if pendingEntry.canceled then
        cleanup()
        return
    end

    local dieFace, totalNumber, outcomeLabel, inspirationCount,
        canRespondToCommands, contextObjectCount, rollContext,
        widgetPresent = ReadActiveRollReveal()

    if not widgetPresent then
        -- Player dismissed the card; nothing more to read.
        pendingEntry.canceled = true
        cleanup()
        return
    end

    -- Cycle boundary detection: when the outcome card disappears
    -- (outcomeLabel transitions from non-nil back to nil), BG3 is
    -- between rolls -- the user has pressed Roll Again / Try Again
    -- and the dice are re-arming.  Two things to do:
    --
    --   1. Clear the spoken-tracking so the NEXT outcome speaks even
    --      if it happens to be numerically identical to the previous
    --      one (e.g., natural 7 twice in a row).
    --
    --   2. Announce that we're back at the pre-roll prompt.  The
    --      screen shows the same "Roll Dice [Y] / Add Bonus [X]" UI
    --      as the initial entry, but WorldUI's screen-entry path
    --      doesn't fire because the widget didn't re-appear -- it's
    --      the same widget, mid-cycle.  Without this prompt, the
    --      user hears the failure / reroll-option line and then
    --      silence, with no signal that they need to press Y again
    --      to trigger the actual reroll.
    if not outcomeLabel and pendingEntry.lastSpokenOutcome then
        pendingEntry.lastSpokenDieFace = nil
        pendingEntry.lastSpokenOutcome = nil
        -- Bonus cards are NOT focusable on the reroll pre-roll
        -- screen (unlike the initial screen-entry where d-pad
        -- left / right cycles them), so the "browse bonuses" hint
        -- from the screen-entry speech is omitted here.
        SpeakInterrupt("Press Y to roll dice. X to add bonus.")
    end

    -- Speak when we see a NEW outcome pair (different from whatever
    -- we last spoke).  First-cycle entries have nil last-spoken
    -- fields, so any rendered outcome qualifies.
    if outcomeLabel and dieFace then
        local newDie = pendingEntry.lastSpokenDieFace ~= dieFace
        local newOutcome = pendingEntry.lastSpokenOutcome ~= outcomeLabel
        if newDie or newOutcome then
            pendingEntry.lastSpokenDieFace = dieFace
            pendingEntry.lastSpokenOutcome = outcomeLabel
            SpeakRollReveal(rollerName, dieFace, totalNumber,
                outcomeLabel, inspirationCount, canRespondToCommands,
                contextObjectCount, rollContext)
        end
    end

    local nextElapsedMs = elapsedMs + ROLL_PREVIEW_POLL_INTERVAL_MS
    if nextElapsedMs >= ROLL_PREVIEW_MAX_WAIT_MS then
        -- Timed out.  Bail silently.  The commit-side RollFinished
        -- still fires its full breakdown on A-press.
        pendingEntry.canceled = true
        cleanup()
        return
    end
    BG3Access.Client.Scheduler.RunAfterMs(ROLL_PREVIEW_POLL_INTERVAL_MS,
        function()
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
    if not IsDiceRollDetailEnabled() then return end
    local rollBucket = eventData.rollBucket or ""
    -- Attack rolls merge roll detail into AttackedBy / MissedBy via
    -- BuildRollPrefixFragment at damage time -- skip the reveal
    -- preview path for those.
    if rollBucket == "attack" then return end

    local rollerName = eventData.rollerName or "Unknown"
    local rollUuid = eventData.rollUuid or ""

    -- Dedup: BG3's server-side RollPreview fires twice per roll (once
    -- on initial commit, once on a refresh tick) for the same RollUuid.
    -- Without this guard each call schedules an independent poll, both
    -- find the outcome at roughly the same time, and the reveal speech
    -- fires twice.  If we've already got a pending entry for this
    -- rollUuid, ignore the duplicate event.
    if rollUuid ~= "" and pendingRollPreviews[rollUuid] then
        return
    end

    local pendingEntry = { canceled = false }
    if rollUuid ~= "" then
        pendingRollPreviews[rollUuid] = pendingEntry
    end
    BG3Access.Client.Scheduler.RunAfterMs(ROLL_PREVIEW_POLL_INTERVAL_MS,
        function()
            PollForReveal(pendingEntry, rollUuid, rollerName,
                ROLL_PREVIEW_POLL_INTERVAL_MS)
        end)
end

--- Cancel any pending preview poll for this roll.  Called from
--- HandleRollFinished so a fast A-press beats the reveal poll and
--- we skip the preview (the full commit-side breakdown covers it,
--- so the bare "rolled N" preview would just be redundant).
local function CancelPendingRollPreview(rollUuid)
    if not rollUuid or rollUuid == "" then return end
    local pendingEntry = pendingRollPreviews[rollUuid]
    if pendingEntry then
        pendingEntry.canceled = true
        pendingRollPreviews[rollUuid] = nil
    end
end

-- ---------------------------------------------------------------------------
-- Top-level RollFinished dispatcher (chooses save / check / attack
-- merge based on bucket and routes accordingly)
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- State management
-- ---------------------------------------------------------------------------

--- Reset per-session dice-roll state.  Called from Combat.ResetState
--- on GameStateChanged so cached attack rolls and pending preview
--- polls don't leak across save loads / level transitions.
local function ResetState()
    attackRollCache = {}
    -- Mark all pending polls as canceled; the next scheduler tick
    -- consumes the flag and cleans up the entry.  Don't clear the
    -- table directly -- the in-flight poll closures still reference
    -- their pendingEntry by identity.
    for _, pendingEntry in pairs(pendingRollPreviews) do
        pendingEntry.canceled = true
    end
    pendingRollPreviews = {}
end

Log.Debug("DiceRolls module loaded")

-- ============================================================================
-- Module Table
-- ============================================================================

BG3Access.Client.DiceRolls = {
    -- Settings predicate (also used by Combat.lua to gate the attack
    -- roll prefix and damage-dice breakdown in attack speech).
    IsDiceRollDetailEnabled = IsDiceRollDetailEnabled,

    -- Low-level "rolled N plus M" formatter.  Combat.lua's
    -- SpeakAttackHit calls this directly for hit-resolution speech
    -- (the eventData table format has the same fields BuildRollPrefix
    -- expects, so no adapter needed).
    BuildRollPrefix         = BuildRollPrefix,

    -- Attack-roll prefix used by HandleAttackedBy / HandleMissedBy.
    BuildRollPrefixFragment = BuildRollPrefixFragment,

    -- Event handlers wired into Combat.lua's EVENT_HANDLERS table.
    HandleRollFinished      = HandleRollFinished,
    HandleRollPreview       = HandleRollPreview,
    HandleRollFinishedSave  = HandleRollFinishedSave,
    HandleRollFinishedCheck = HandleRollFinishedCheck,
    CancelPendingRollPreview = CancelPendingRollPreview,

    -- State reset (called from Combat.ResetState).
    ResetState              = ResetState,
}
