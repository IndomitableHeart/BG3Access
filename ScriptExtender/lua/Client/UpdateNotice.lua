-- File: Client/UpdateNotice.lua
--
-- Reads the update notice marker the loader (DWrite.dll's GameMod
-- updater) writes after successfully installing a new version of the
-- mod.  Speaks the version transition and any release notes via
-- SpeechData.Alert.
--
-- File location:
--   <BG3 user profile>\Script Extender\BG3AccessMod\update_notice.json
--   (relative path passed to Ext.IO.LoadFile: "BG3AccessMod/update_notice.json")
--
-- File shape:
--   { "from": "0.1.0", "to": "0.1.1", "notice": "Free-form release notes" }
--
-- Lifecycle:
--   1. Loader writes the file after a successful download + extract +
--      atomic swap of the new mod content.
--   2. BG3 launches, mod loads, this module runs.
--   3. Ext.IO.LoadFile returns the file contents.
--   4. We parse the JSON, queue an announcement, then OVERWRITE the
--      file with an empty string (Ext.IO has no Delete; empty is our
--      "consumed" marker).
--   5. Next launch: file is empty, we return early, no announcement.
--
-- Failure modes:
--   - File missing: normal steady-state (no recent update).
--   - File empty: previously announced, now consumed.
--   - File present but unparseable: log warning, treat as missing,
--     overwrite with empty so we don't retry every launch.

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

local Log        = BG3Access.Client.Log
local SpeechData = BG3Access.Client.SpeechData
local Scheduler  = BG3Access.Client.Scheduler

-- File path is relative to the user profile's Script Extender folder.
-- Subfolder is the resource Name from the manifest entry ("BG3AccessMod"),
-- matching what the loader writes in GameModUpdater::WriteNoticeFile.
local NOTICE_FILE_PATH = "BG3AccessMod/update_notice.json"

-- Same audio-device-warmup delay Welcome.lua uses.  Tolk reports ready
-- before audio output is ready; speaking immediately risks losing the
-- first phoneme on cold launches.
local SPEAK_DELAY_MS = 800


--- ReadNotice: returns the parsed table or nil.  Distinguishes
--- "file missing" / "file empty" (return nil silently) from
--- "file present but broken" (log + return nil).
local function ReadNotice()
    if not Ext or not Ext.IO or not Ext.IO.LoadFile then
        return nil
    end

    local ok, raw = pcall(Ext.IO.LoadFile, NOTICE_FILE_PATH)
    if not ok or not raw or raw == "" then
        return nil  -- normal: no recent update, or already consumed
    end

    local parseOk, data = pcall(Ext.Json.Parse, raw)
    if not parseOk or type(data) ~= "table" then
        if Log then
            Log.Warn("UpdateNotice: marker file present but unparseable"
                .. " -- consuming it to avoid replay loop")
        end
        return nil
    end

    return data
end


--- ConsumeNotice: overwrite the file with an empty string so subsequent
--- launches don't replay the same announcement.  Ext.IO doesn't expose
--- a Delete; empty content is our convention for "already handled".
local function ConsumeNotice()
    if not Ext or not Ext.IO or not Ext.IO.SaveFile then return end
    pcall(Ext.IO.SaveFile, NOTICE_FILE_PATH, "")
end


--- TrimTrailingZeroComponents: convert a 4-component version like
--- "0.1.1.0" into the shortest semver-ish form by dropping trailing
--- ".0" segments.  "0.1.1.0" -> "0.1.1".  "0.1.0.0" -> "0.1".  Never
--- trims below 2 components (a version like "1.0.0.0" becomes "1.0",
--- not "1") so the announcement still sounds like a version number.
---
--- The loader writes 4-component versions because that's what the C++
--- VersionNumber parser requires (FromString uses %d.%d.%d.%d).  Users
--- shouldn't have to hear "version zero point one point one point zero".
local function TrimTrailingZeroComponents(versionString)
    if not versionString or versionString == "" then return versionString end
    local parts = {}
    for segment in string.gmatch(versionString, "[^.]+") do
        parts[#parts + 1] = segment
    end
    while #parts > 2 and parts[#parts] == "0" do
        parts[#parts] = nil
    end
    return table.concat(parts, ".")
end


--- BuildAnnouncement: assemble the spoken text from notice data.
--- Format: "BG3Access successfully updated to version X.Y.Z. See the
--- changelog for further details."
---
--- Intentionally minimal -- the per-release patch notes live in
--- CHANGELOG.md inside the mod folder, not in this announcement.
--- Reasons:
---   - Keeps the launch-time interruption short.
---   - Patch notes vary in length; speaking them all on launch makes
---     for an unpredictable speech duration.
---   - Users who want the detail can read the changelog at their pace.
---
--- The `notice` field is still written to the marker file in case a
--- future feature wants to surface it (e.g. an in-game "what's new"
--- reader on button press) -- we just don't speak it here.
local function BuildAnnouncement(data)
    local toVer = data.to or ""
    if toVer == "" then
        return nil  -- can't announce a transition with no destination
    end

    return "BG3Access successfully updated to version "
        .. TrimTrailingZeroComponents(toVer)
        .. ". See the changelog in the mod's settings menu for details."
end


--- MaybeAnnounceUpdate: entry point.  Runs once on module load.
--- Reads + parses the notice file; if present, schedules a delayed
--- announcement (audio device warmup), then consumes the file so
--- the announcement plays exactly once per update.
local function MaybeAnnounceUpdate()
    local data = ReadNotice()
    if not data then
        -- Even when we couldn't parse, consume the file so a corrupt
        -- marker doesn't generate warnings on every launch forever.
        if data == nil and Ext and Ext.IO then
            -- ReadNotice already logged the warn for the unparseable
            -- case; we just overwrite without further noise.
            ConsumeNotice()
        end
        return
    end

    local message = BuildAnnouncement(data)
    if not message then
        ConsumeNotice()
        return
    end

    if Log then
        Log.Info("UpdateNotice: queueing announcement: " .. message)
    end

    local function speak()
        if SpeechData and SpeechData.Alert then
            SpeechData.Alert(message, "queue")
        else
            -- Fallback if SpeechData isn't loaded for some reason.
            pcall(Ext.Tolk.Speak, message, false)
        end
        ConsumeNotice()
    end

    if Scheduler and Scheduler.RunAfterMs then
        Scheduler.RunAfterMs(SPEAK_DELAY_MS, speak)
    else
        speak()
    end
end


MaybeAnnounceUpdate()


local UpdateNoticeModule = {
    -- Exposed only for testability / debug commands.  No one else
    -- should call this in normal flow.
    MaybeAnnounceUpdate = MaybeAnnounceUpdate,
}

BG3Access.Client.UpdateNotice = UpdateNoticeModule

return UpdateNoticeModule
