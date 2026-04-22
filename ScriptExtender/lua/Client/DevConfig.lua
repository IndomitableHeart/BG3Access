-- File: Client/DevConfig.lua
--
-- Developer-only configuration.  THIS FILE IS NOT DISTRIBUTED WITH
-- RELEASES.  Its presence is how the mod detects it's running in a
-- developer environment, enabling dev-only code paths (mid-session
-- reload recovery, verbose diagnostic logs, test helpers, etc.).
--
-- On a user's machine this file is absent, so the pcall(Ext.Require)
-- in Client/_Init.lua fails silently and BG3Access.DevMode stays nil.
-- Every `if BG3Access.DevMode then` branch becomes dead code.
--
-- To ship a release:
--   * Exclude this file from the packaged mod zip / release artifact.
--   * Do NOT delete it from the working tree; keep it committed so
--     fresh clones work out of the box for development.

BG3Access = BG3Access or {}
BG3Access.DevMode = true

-- ---------------------------------------------------------------------------
-- Dev-only bindings.
-- ---------------------------------------------------------------------------
-- Any controller chord, console command, or keybind that exists solely
-- for developer iteration goes here.  Because this file is excluded from
-- release packaging, users never see these bindings fire.
--
-- Ext.Events subscriptions register a callback that runs later at event
-- time -- the symbols the callback needs (BG3Access.Client.CycleLogLevel,
-- etc.) don't have to exist at subscription time, only at event time.
-- By the time a user actually presses buttons in-game, all modules have
-- loaded and the callback's references resolve.

-- L3 click: cycle log level OFF -> INFO -> DEBUG -> OFF.  Speech
-- announces the new level via SpeechData.Alert.  At DEBUG level, Lua
-- Log.Debug calls AND the C++ BG3A_TRACE firehose both fire; at INFO,
-- quiet diagnostic view; at OFF, silent.  Flip on before reproducing
-- an issue, flip off after.
--
-- Stick clicks have no standalone in-game action (holding both
-- together triggers the game's photo mode, but individual clicks do
-- nothing), so the single-button chord avoids any conflict.
Ext.Events.ControllerButtonInput:Subscribe(function(event)
    local buttonName = tostring(event.Button)
    if event.Pressed and BG3Access.Client and BG3Access.Client.Log then
        BG3Access.Client.Log.Debug("INPUT: " .. buttonName)
    end
    if event.Pressed and buttonName == "LeftStick" then
        BG3Access.Client.CycleLogLevel()
    end
end)
