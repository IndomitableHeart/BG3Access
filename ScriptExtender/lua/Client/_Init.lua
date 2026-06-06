-- Dev-only config.  Sets BG3Access.DevMode = true when present.
-- Release packaging strips this line (see marker below) and excludes
-- DevConfig.lua from the distributed zip.  Must load BEFORE any
-- module that checks BG3Access.DevMode.

-- Load order notes:
--   - Logger first so every other module can Log.Info/Warn on load.
--   - Settings second so any module can call RegisterDefault on load.
--   - SpeechData next: registers the "verbosity" setting and reads
--     it on every Format() call.
--   - SettingsMenu must load AFTER SpeechData (it captures
--     BG3Access.Client.SpeechData at module-load time).  Putting it
--     near the end keeps it close to EventRouter (its caller) without
--     forcing any other module to depend on it.
--   - Welcome last: it consults Settings (for the welcomeShown flag)
--     and SpeechData (to speak the message), both of which must
--     already be loaded.
BG3Access.Shared.RequireFiles("Client/", {
"Logger",
"Settings",
"SpeechData",
"Helpers",
"Scheduler",
"ColorDescriptions",
"DetailView",
"CompareView",
"Dispatcher",
"CharCreation",
"Cutscene",
"CharSheet",
"SpellBook",
"TadpolePowers",
"WorldUI",
"Menus",
"DiceRolls",
"Combat",
"TargetSelect",
"Locations",
"Subregion",
"Notifications",
"WorldNav",
"HUDReader",
"SettingsMenu",
"EventRouter",
"UpdateNotice",
"Welcome",
})
