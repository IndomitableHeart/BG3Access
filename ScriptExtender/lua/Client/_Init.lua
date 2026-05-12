-- Dev-only config.  Sets BG3Access.DevMode = true when present.
-- Release packaging strips this line (see marker below) and excludes
-- DevConfig.lua from the distributed zip.  Must load BEFORE any
-- module that checks BG3Access.DevMode.
pcall(Ext.Require, "Client/DevConfig.lua")  -- DEV-ONLY: strip on release

BG3Access.Shared.RequireFiles("Client/", {
"Logger",
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
"Combat",
"TargetSelect",
"Subregion",
"Notifications",
"WorldNav",
"HUDReader",
"EventRouter",
})
