-- File: Mods/BG3Access/ScriptExtender/Lua/Shared/Init.lua
-- Purpose: Defines shared utilities like RequireFiles and loads foundational systems.

BG3Access = BG3Access or {} 
BG3Access.Shared = BG3Access.Shared or {}

--- Loads Lua files using Ext.Require.
-- This utility is attached to the mod's shared namespace.
-- @param basePath string The folder path, must end with a slash.
-- @param files table A list of file names (without .lua extension).
function BG3Access.Shared.RequireFiles(basePath, files)
    Ext.Utils.Print(string.format("[BG3Access.Shared.RequireFiles] Loading from: %s", basePath))
    for _, fileStem in ipairs(files) do
        local fullPath = basePath .. fileStem .. ".lua"
        Ext.Require(fullPath)
    end
end
Ext.Utils.Print("[Shared/Init.lua] BG3Access.Shared.RequireFiles utility defined.")

Ext.Utils.Print("[Shared/Init.lua] Loading ClassInit.")
BG3Access.Shared.RequireFiles("Shared/", {
    "ClassInit" 
})
Ext.Utils.Print("[Shared/Init.lua] ClassInit loaded (expected _Class to be global or on BG3Access.Lib).")

Ext.Utils.Print("[Shared/Init.lua] Shared foundational components initialization complete.")