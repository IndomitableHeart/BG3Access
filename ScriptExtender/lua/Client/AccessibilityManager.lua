-- File: Client/AccessibilityManager.lua
--
-- Accessibility manager using C++ GlobalFocusMonitor.
--
-- The C++ monitor runs every frame, tracks focus (Strategies 1+2) and
-- selection (Strategy 3) INDEPENDENTLY.  Selection changes take priority
-- (tab switch, option selection); when selection is stable, focus changes
-- drive the callback (d-pad navigation, button focus).  This prevents a
-- non-null selection from permanently suppressing focus detection.
--
-- Lua determines element type and handles accordingly:
--   Option item  (has DataContext.Text)  → speak name + value
--   Tab item     (ListBoxItem type)     → speak tab name + first option
--   Button/other                         → speak normally
--
-- Plus INPC on DataContext (C++):
--   Fires when a ViewModel property changes (tickbox toggle, slider
--   adjust, combo selection).  Speaks the new value immediately.

BG3Access = BG3Access or {}
BG3Access.Client = BG3Access.Client or {}

local Helpers = BG3Access.Helpers

-- ---------------------------------------------------------------------------
-- State
--
-- IMPORTANT: Noesis element references expire after the tick they are
-- obtained in.  We NEVER store element references across ticks.  All
-- cross-tick tracking uses identity strings from GetElementId().
-- ---------------------------------------------------------------------------

local lastSpokenName      = nil   -- identity of last spoken element
local lastSpokenFullText  = nil   -- full "Name: Value" text of last speech
local lastSpokenTab       = nil   -- tab NAME (not elemId) of last spoken tab
local pendingOptionRetry  = 0     -- retry counter for FindFirstOptionItem after tab switch
local pendingOptionDelay  = 0     -- settle frames before retrying (lets stale content clear)
local tabHintSpoken       = false -- true after we've spoken the navigation hint this visit

-- ---------------------------------------------------------------------------
-- Get a stable identity string for an element (object refs expire each tick).
-- ---------------------------------------------------------------------------
local function GetElementId(elem)
    if not elem then return nil end
    local okN, name = pcall(elem.GetProperty, elem, "Name")
    local okT, typeName = pcall(function() return elem.Type end)
    local n = (okN and type(name) == "string") and name or ""
    local t = (okT and type(typeName) == "string") and typeName or "?"

    -- For ViewModel-driven elements (Options menu ContentPresenters etc.),
    -- include DataContext.Text to distinguish items with the same type/name.
    local dcId = ""
    if n == "" then
        local okDC, dc = pcall(elem.GetProperty, elem, "DataContext")
        if okDC and dc and type(dc) == "userdata" then
            local okDCT, txt = pcall(dc.GetProperty, dc, "Text")
            if okDCT and type(txt) == "string" then
                dcId = txt
            end
        end
    end

    return t .. "::" .. n .. "::" .. dcId
end

-- ---------------------------------------------------------------------------
-- Check if an element is an "option item" (has DataContext with "Text").
-- Returns true for options like "Show Tutorials", false for tab items.
-- ---------------------------------------------------------------------------
local function IsOptionItem(elem)
    local okDC, dc = pcall(elem.GetProperty, elem, "DataContext")
    if not okDC or not dc or type(dc) ~= "userdata" then return false end
    local hasProp = false
    local okH = pcall(function() hasProp = Ext.UI.HasProperty(dc, "Text") end)
    if not okH or not hasProp then return false end
    local okT, txt = pcall(dc.GetProperty, dc, "Text")
    return okT and type(txt) == "string" and txt ~= ""
end

-- ---------------------------------------------------------------------------
-- Check if an element looks like a tab/carousel item (ListBoxItem type).
-- ---------------------------------------------------------------------------
local function IsTabItem(elem)
    local okT, typeName = pcall(function() return elem.Type end)
    if not okT or type(typeName) ~= "string" then return false end
    return typeName:find("ListBoxItem") ~= nil
        or typeName:find("ListItem") ~= nil
end

-- ---------------------------------------------------------------------------
-- Speak a focused element.  `focused` MUST be from the current tick.
--
-- `interrupt` (default true): if true, interrupts current speech.
--   Set to false when queuing speech after a tab name announcement.
--
-- Subscribes to INPC on the element's DataContext for value changes.
-- The INPC callback uses Helpers.ReadDataContextText(sender) to read
-- from the ViewModel directly — NOT from the expired element reference.
-- ---------------------------------------------------------------------------
local function SpeakFocused(focused, interrupt)
    if interrupt == nil then interrupt = true end

    lastSpokenName = GetElementId(focused)

    -- Unsubscribe from previous ViewModel's property changes.
    Ext.UI.UnsubscribePropertyChanged()

    -- Extract and speak text.
    local text = Helpers.ExtractTextFromElement(focused)
    lastSpokenFullText = text
    local okT, typeName = pcall(function() return focused.Type end)
    typeName = (okT and type(typeName) == "string") and typeName or "?"
    Ext.Utils.Print("[BG3Access] Focus -> " .. typeName .. "  text=" .. tostring(text))

    if text and text ~= "" then
        Ext.Tolk.Speak(text, interrupt)
    end
    -- If no useful text found, stay silent rather than speaking raw type name.

    -- Subscribe to INPC on the element's DataContext for value changes
    -- (checkbox toggle, slider adjust, combo selection).
    -- IMPORTANT: The callback reads from `sender` (the ViewModel), NOT from
    -- `focused` (which expires after this tick).
    local okDC, dc = pcall(focused.GetProperty, focused, "DataContext")
    if okDC and dc and type(dc) == "userdata" then
        local subOk, subErr = pcall(Ext.UI.SubscribePropertyChanged, dc, function(sender, prop)
            local pOk, pErr = pcall(function()
                -- Read the full "Name: Value" string for dedup tracking,
                -- but only speak the value part (e.g. "On" not "Show Tutorials: On").
                local newText = Helpers.ReadDataContextText(sender)
                if newText and newText ~= "" and newText ~= lastSpokenFullText then
                    lastSpokenFullText = newText
                    local valueOnly = Helpers.ReadDataContextValue(sender)
                    local speakText = valueOnly or newText
                    Ext.Utils.Print("[BG3Access] INPC -> " .. speakText)
                    Ext.Tolk.Speak(speakText, true)
                end
            end)
            if not pOk then
                Ext.Utils.Print("[BG3Access] INPC callback error: " .. tostring(pErr))
            end
        end)
        if subOk then
            Ext.Utils.Print("[BG3Access] INPC subscribed on " .. typeName)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Handle a focus or selection change from the C++ monitor.
-- Determines what kind of element it is and handles accordingly.
-- ---------------------------------------------------------------------------
local function HandleFocusChange(element)
    if not element then return end

    local elemId = GetElementId(element)
    local okT, typeName = pcall(function() return element.Type end)
    typeName = (okT and type(typeName) == "string") and typeName or "?"
    local isOpt = IsOptionItem(element)
    local isTab = IsTabItem(element)

    Ext.Utils.Print("[BG3Access] HandleFocusChange: type=" .. typeName
        .. " isOpt=" .. tostring(isOpt) .. " isTab=" .. tostring(isTab)
        .. " elemId=" .. tostring(elemId)
        .. " lastSpokenName=" .. tostring(lastSpokenName)
        .. " lastSpokenTab=" .. tostring(lastSpokenTab))

    -- Option item (ContentPresenter with DataContext.Text) → speak normally
    if isOpt then
        pendingOptionRetry = 0  -- Cancel any pending tab-option retry
        pendingOptionDelay = 0
        if elemId == lastSpokenName then
            Ext.Utils.Print("[BG3Access]   -> SKIP option (same as lastSpokenName)")
            return
        end
        SpeakFocused(element)
        return
    end

    -- Tab/carousel item (ListBoxItem type without DataContext.Text)
    -- NOTE: All ListBoxItems produce identical elemId ("ListBoxItem::::"),
    -- so we use the extracted tab NAME for dedup instead.
    if isTab then
        local tabName = Helpers.ExtractTabName(element)
        Ext.Utils.Print("[BG3Access]   -> TAB name=" .. tostring(tabName))

        -- Same tab as last spoken?
        if tabName and tabName == lastSpokenTab then
            -- Phase 1: Settle delay — let stale content from the previous tab clear.
            -- The content area takes 2-3 frames to rebuild after a tab switch.
            if pendingOptionDelay > 0 then
                pendingOptionDelay = pendingOptionDelay - 1
                Ext.Utils.Print("[BG3Access]   -> WAIT for content (" .. pendingOptionDelay .. " frames left)")
                Ext.UI.ForceGlobalFocusUpdate()
            -- Phase 2: Real retries — search for the first option.
            elseif pendingOptionRetry > 0 then
                pendingOptionRetry = pendingOptionRetry - 1
                Ext.Utils.Print("[BG3Access]   -> RETRY FindFirstOptionItem (" .. pendingOptionRetry .. " retries left)")
                local root = Ext.UI.GetRoot()
                if root then
                    local firstOption = Helpers.FindFirstOptionItem(root)
                    if firstOption then
                        -- Extra safety: reject if text matches what was spoken before tab switch.
                        local text = Helpers.ExtractTextFromElement(firstOption)
                        if text and text ~= lastSpokenFullText then
                            pendingOptionRetry = 0
                            pendingOptionDelay = 0
                            Ext.Utils.Print("[BG3Access]   -> RETRY found NEW option: " .. text)
                            SpeakFocused(firstOption, false)
                            -- On first tab entry, speak a navigation hint so the
                            -- player knows how to interact with the options menu.
                            if not tabHintSpoken then
                                tabHintSpoken = true
                                Ext.Tolk.Speak("Use LB and RB to switch tabs. Pressing down once will enter the options list, subsequent presses move through options. Left and right change values.", false)
                            end
                        elseif pendingOptionRetry > 0 then
                            Ext.Utils.Print("[BG3Access]   -> RETRY found STALE option (" .. tostring(text) .. "), retrying")
                            Ext.UI.ForceGlobalFocusUpdate()
                        else
                            Ext.Utils.Print("[BG3Access]   -> RETRY exhausted, content still stale")
                        end
                    elseif pendingOptionRetry > 0 then
                        Ext.UI.ForceGlobalFocusUpdate()
                    else
                        -- No option items found — this tab has informational
                        -- text instead of settings (e.g. Cross-Play description).
                        -- Fall back to reading visible text, scoped to the tab's
                        -- content area (not root) to avoid main menu/footer junk.
                        Ext.Utils.Print("[BG3Access]   -> RETRY exhausted, falling back to scoped text")
                        local texts = Helpers.GatherTabContentText(root)
                        if #texts > 0 then
                            local seen = {}
                            local filtered = {}
                            for _, t in ipairs(texts) do
                                -- Skip binding placeholders like [ForceUpdate]
                                if t:find("^%[") then goto skip end
                                -- Skip very short strings (tab labels, "0", etc.)
                                if #t < 4 then goto skip end
                                -- Skip the tab name we already spoke
                                if t == lastSpokenTab then goto skip end
                                -- Skip text already spoken (e.g. button that got focus)
                                if lastSpokenFullText and lastSpokenFullText:find(t, 1, true) then goto skip end
                                -- Skip duplicates
                                if seen[t] then goto skip end
                                seen[t] = true
                                table.insert(filtered, t)
                                ::skip::
                            end
                            if #filtered > 0 then
                                local fullText = table.concat(filtered, ". ")
                                lastSpokenFullText = fullText
                                Ext.Utils.Print("[BG3Access]   -> FALLBACK text: " .. fullText)
                                Ext.Tolk.Speak(fullText, false)
                            end
                        end
                    end
                end
            else
                Ext.Utils.Print("[BG3Access]   -> SKIP tab (same name as lastSpokenTab)")
            end
            return
        end

        -- New tab detected
        lastSpokenTab = tabName
        lastSpokenName = nil  -- Reset element dedup so first option isn't skipped

        if tabName then
            Ext.Tolk.Speak(tabName, true)
        end

        -- Wait 3 frames for stale content to clear, then 5 real retries.
        -- The content area takes 2-3 frames to rebuild after a tab switch.
        -- During the settle delay, we don't call FindFirstOptionItem at all
        -- to avoid picking up leftover content from the previous tab.
        pendingOptionDelay = 3
        pendingOptionRetry = 5
        Ext.UI.ForceGlobalFocusUpdate()
        Ext.Utils.Print("[BG3Access]   -> Scheduling first option detection (delay=" .. pendingOptionDelay .. " retries=" .. pendingOptionRetry .. ")")
        return
    end

    -- Everything else (buttons, etc.)
    --
    -- If we're in the middle of tab detection (retries/delay pending),
    -- a content-area button may get focus (e.g. "Enable Cross-Play").
    -- Speak it but DON'T cancel the tab context — let retries finish
    -- so the fallback can still read informational body text.
    if pendingOptionRetry > 0 or pendingOptionDelay > 0 then
        if elemId ~= lastSpokenName then
            Ext.Utils.Print("[BG3Access]   -> Speak during tab detection (retries preserved)")
            SpeakFocused(element)
        end
        return
    end

    -- Normal path — no active tab detection.
    lastSpokenTab = nil  -- Reset tab context (fixes re-entry into Options)
    tabHintSpoken = false  -- Reset hint so it speaks again on next Options entry
    if elemId == lastSpokenName then
        -- Same structural identity — but might be a different element with
        -- the same type and Name (e.g., multiplayer lobby entries all named
        -- "Bg").  Fall back to text comparison before skipping.
        local text = Helpers.ExtractTextFromElement(element)
        if not text or text == lastSpokenFullText then
            Ext.Utils.Print("[BG3Access]   -> SKIP other (same identity and text)")
            return
        end
        Ext.Utils.Print("[BG3Access]   -> Same elemId but different text, speaking")
    end
    SpeakFocused(element)
end

-- ---------------------------------------------------------------------------
-- Subscribe to the C++ per-frame GlobalFocusMonitor.
-- This single callback fires for EVERY focus/selection change in ANY menu.
-- ---------------------------------------------------------------------------
local function SetupGlobalFocusMonitor()
    local ok, result = pcall(Ext.UI.SubscribeGlobalFocusChanged, function(element, prop)
        local hOk, hErr = pcall(HandleFocusChange, element)
        if not hOk then
            Ext.Utils.Print("[BG3Access] ERROR in HandleFocusChange: " .. tostring(hErr))
        end
    end)
    if ok and result then
        Ext.Utils.Print("[BG3Access] Global focus monitor active")
    else
        Ext.Utils.Print("[BG3Access] ERROR: could not subscribe global focus: " .. tostring(result))
    end
end

-- Try immediately (root may exist already at script load time).
SetupGlobalFocusMonitor()

-- Re-subscribe on game state changes (UI tree rebuilt, focus monitor
-- auto-resets in C++ but we need to reset Lua state and re-subscribe).
Ext.Events.GameStateChanged:Subscribe(function(e)
    Ext.Utils.Print("[BG3Access] GameStateChanged -> resetting")
    lastSpokenName = nil
    lastSpokenFullText = nil
    lastSpokenTab = nil
    pendingOptionRetry = 0
    pendingOptionDelay = 0
    tabHintSpoken = false
    SetupGlobalFocusMonitor()
end)

-- ---------------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------------
Ext.Utils.Print("[BG3Access] Accessibility ready (GlobalFocusMonitor + INPC).")
Ext.Tolk.Speak("accessibility ready", false)
