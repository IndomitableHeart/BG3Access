# Changelog

All notable changes to BG3Access are documented here. Newest versions
on top.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/).
Versions follow [Semantic Versioning](https://semver.org/): MAJOR.MINOR.PATCH.

---

## 0.1.4 - 2026-06-07

### Fixed

- Per-turn announcements in combat ("X's turn") no longer fire for
  non-combatant environment objects (illithid bulbs, chests, barrels
  with sentinel -20 initiative).  Previously the user would hear
  "Chest's turn", "Bulb's turn", etc. cycling between every real
  combatant's turn.  Now the announcement is suppressed for these
  entries and only real combatants are announced.
- Reduced log volume.  Several per-tick / per-call internal traces
  that were logged at Info level (visible whenever LogRuntime is on)
  are now Debug level (only logged when log verbosity is explicitly
  raised).  Single-event logs like spoken phrases, target reads, and
  combat transitions remain at Info.

---

## 0.1.3 - 2026-06-07

### Added

- An "About" entry at the top of the settings menu (right-stick
  down to open) that reads the installed BG3Access version when
  you navigate to it.

---

## 0.1.2 - 2026-06-07

### Fixed

- Audio description Part 2 volume reduced so it no longer drowns out
  game audio during the opening cinematic.

---

## 0.1.1 - 2026-06-06

### Added

- Auto-update mechanism. The Script Extender loader now checks for
  new versions of BG3Access on each game launch and downloads them
  automatically. After a successful update, BG3Access speaks a brief
  announcement confirming the new version.

### Fixed

- Combat turn-order narration no longer includes non-combatant
  environment objects (illithid bulbs, chests, barrels, etc.). These
  appear in the game's turn order but don't actually act, so
  including them in the spoken list was just noise.
- Installer no longer fails with "error 126" on clean BG3 installs.
  A required runtime dependency was missing from the previous
  installer package.

---

## 0.1.0 - 2026-06-05

Initial alpha release.

### Added

- Screen reader narration via Tolk for the entire pre-game flow
  (Main Menu, Options, Multiplayer, Difficulty selection, Save/Load,
  Mod Manager).
- Character Creation narration across Origin, Race, Subrace, Class,
  Subclass, Background, Deity, Feat, Abilities, Skills, Cantrips,
  Spells, and Appearance (including inline appearance carousels).
- In-game UI narration: pause menu, shortcuts radial (RT), action
  radial (RB), character sheet, spellbook, journal, camp supplies,
  pickpocketing, alchemy, examine panel, loot containers, context
  menus.
- Dialogue narration with answer-choice navigation.
- Combat narration: turn announcements, combat start/end, status
  applied/removed (party only), damage dealt, downed and death
  events, dice rolls (skill checks, saves, attack rolls).
- Dice roll detail readout: skill, ability, DC, advantage state,
  modifier navigation, spell-derived boosts, inspiration rerolls.
- GPS navigation: clock-face direction announcements with distance
  and hazard warnings, spatial-audio beacon with bucketed cadence
  (front/back disambiguation via tick rate, not panning).
- HUD reader (RS Up = character, RS Down = settings, RS Right =
  resources, RS Left = detail view).
- Audio description playback hooks for major cinematics. Production
  AD files landed for the opening cinematic (Part 1 and Part 2).
- Welcome message on first launch, persisted via the unified
  settings file.
- Installer that handles all setup automatically.

### Notes

- Tested on Windows 10 with JAWS and NVDA.
- Compatible with BG3 patch 4.65.83.0 and later.
- Alpha quality. Expect rough edges.
