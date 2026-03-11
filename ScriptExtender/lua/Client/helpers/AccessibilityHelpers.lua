-- File: Client/Helpers/AccessibilityHelpers.lua

BG3Access = BG3Access or {}
BG3Access.Helpers = BG3Access.Helpers or {}

local Helpers = BG3Access.Helpers

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

function Helpers._IsElementValid(uiElement)
    if not uiElement then return false end
    local ok, typeValue = pcall(function() return uiElement.Type end)
    if not ok or type(typeValue) ~= "string" then return false end
    if typeValue == "Noesis::DependencyObject" then
        local readOk, _ = pcall(uiElement.GetProperty, uiElement, "Name")
        if not readOk then return false end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Localization helper
-- ---------------------------------------------------------------------------

function Helpers.GetTranslatedStringIfHandle(text)
    if not text or type(text) ~= "string" or text == "" then return text end
    if Ext.Loca and Ext.Loca.GetTranslatedString then
        local translated = Ext.Loca.GetTranslatedString(text)
        if translated and translated ~= "" and translated ~= text then
            return translated
        end
    end
    return text
end

-- ---------------------------------------------------------------------------
-- Visual tree walking — gather TextBlock text
-- (Kept for future use once we discover where real text lives.)
-- ---------------------------------------------------------------------------

function Helpers.GatherTextBlockTexts(element, maxDepth)
    if not element or maxDepth <= 0 then return {} end
    local texts = {}

    local okT, typeName = pcall(function() return element.Type end)
    if okT and type(typeName) == "string" and typeName:find("TextBlock") then
        -- Try GetProperty("Text") first (works for non-bound values)
        local okV, text = pcall(element.GetProperty, element, "Text")
        if okV and type(text) == "string" and text ~= "" then
            table.insert(texts, Helpers.GetTranslatedStringIfHandle(text))
        else
            -- Fallback: ToString() calls Noesis TextBlock::ToString() override
            -- which returns the rendered text content (resolves data bindings).
            local okS, str = pcall(element.ToString, element)
            if okS and type(str) == "string" and str ~= "" then
                -- Filter out the type name itself — ToString on non-TextBlock
                -- returns just the type name, which isn't useful text.
                if not str:find("TextBlock") then
                    table.insert(texts, Helpers.GetTranslatedStringIfHandle(str))
                end
            end
        end
    else
        local okC, count = pcall(function() return element.VisualChildrenCount end)
        if okC and type(count) == "number" then
            for i = 1, count do
                local okCh, child = pcall(element.VisualChild, element, i)
                if okCh and child then
                    local childTexts = Helpers.GatherTextBlockTexts(child, maxDepth - 1)
                    for _, t in ipairs(childTexts) do
                        table.insert(texts, t)
                    end
                end
            end
        end
    end

    return texts
end

-- ---------------------------------------------------------------------------
-- Debug: dump the visual tree structure to the log (one-time diagnostic).
-- Logs type, child count, Name, and Text for each element.
-- ---------------------------------------------------------------------------

function Helpers.DebugVisualTree(element, depth, indent)
    indent = indent or ""
    if not element or depth <= 0 then return end

    local okT, typeName = pcall(function() return element.Type end)
    typeName = (okT and type(typeName) == "string") and typeName or "?"

    local okC, childCount = pcall(function() return element.VisualChildrenCount end)
    childCount = (okC and type(childCount) == "number") and childCount or -1

    local okN, name = pcall(element.GetProperty, element, "Name")
    name = (okN and type(name) == "string" and name ~= "") and name or ""

    local okTx, textVal = pcall(element.GetProperty, element, "Text")
    textVal = (okTx and type(textVal) == "string" and textVal ~= "") and textVal or ""

    -- Also try Content property for ContentControls
    local okCo, contentVal = pcall(function() return element.Content end)
    local contentStr = ""
    if okCo and contentVal ~= nil then
        if type(contentVal) == "string" then
            contentStr = " Content=\"" .. contentVal .. "\""
        else
            contentStr = " Content=[" .. type(contentVal) .. "]"
        end
    end

    Ext.Utils.Print("[BG3Access] TREE: " .. indent .. typeName
        .. " children=" .. tostring(childCount)
        .. (name ~= "" and (" Name=\"" .. name .. "\"") or "")
        .. (textVal ~= "" and (" Text=\"" .. textVal .. "\"") or "")
        .. contentStr)

    if childCount > 0 then
        for i = 1, childCount do
            local okCh, child = pcall(element.VisualChild, element, i)
            if okCh and child then
                Helpers.DebugVisualTree(child, depth - 1, indent .. "  ")
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Name cleanup: "NewGameButton" → "New Game"
-- Strips common suffixes, inserts spaces before capitals.
-- ---------------------------------------------------------------------------

local function CleanUpName(name)
    if not name or name == "" then return nil end
    -- Strip common suffixes
    local cleaned = name
    cleaned = cleaned:gsub("Button$", "")
    cleaned = cleaned:gsub("Btn$", "")
    cleaned = cleaned:gsub("Label$", "")
    cleaned = cleaned:gsub("Text$", "")
    if cleaned == "" then return name end  -- don't strip everything
    -- Insert spaces before uppercase letters (CamelCase → words)
    cleaned = cleaned:gsub("(%l)(%u)", "%1 %2")
    -- Also handle sequences like "UIElement" → "UI Element"
    cleaned = cleaned:gsub("(%u%u)(%u%l)", "%1 %2")
    return cleaned
end

-- ---------------------------------------------------------------------------
-- DataContext (ViewModel) helpers — generic, no type-specific checks.
-- Works for all BG3 ViewModel types: ls.VMTickBoxSetting,
-- ls.VMComboBoxSetting, gui::VMSliderSetting, etc.
-- ---------------------------------------------------------------------------

-- Safely try to read a single property from a userdata object.
-- Uses C++ HasProperty to check existence first — avoids error spam
-- from probing properties that don't exist on a given ViewModel type.
local function TryRead(obj, propName)
    if not Ext.UI.HasProperty(obj, propName) then return nil end
    local ok, val = pcall(obj.GetProperty, obj, propName)
    if ok and val ~= nil then
        if type(val) == "string" and val ~= "" then
            return Helpers.GetTranslatedStringIfHandle(val)
        elseif type(val) ~= "string" then
            return val  -- bool, number, userdata, etc.
        end
    end
    return nil
end

-- Read the current value from a DataContext ViewModel (generic).
-- Returns a human-readable string, or nil.
local function ReadGenericValue(dc)
    -- Try "Value" — works for tickboxes (bool) and sliders (number).
    local val = TryRead(dc, "Value")
    if type(val) == "boolean" then return val and "On" or "Off" end
    if type(val) == "number" then return string.format("%.0f", val) end

    -- Try "SelectedItem" — works for comboboxes.
    local sel = TryRead(dc, "SelectedItem")
    if sel then
        if type(sel) == "string" then return sel end
        if type(sel) == "userdata" then
            -- Try common property names on the selected item object.
            for _, p in ipairs({"Name", "Label", "Text"}) do
                local pv = TryRead(sel, p)
                if type(pv) == "string" then return pv end
            end
        end
    end
    return nil
end

-- Format an option name with an optional value string.
local function FormatNameValue(name, value)
    if value and value ~= "" then
        return name .. ": " .. value
    end
    return name
end

-- ---------------------------------------------------------------------------
-- Public DataContext text reader — reads the option name + current value.
-- Returns "Option Name: Value" or just "Option Name", or nil.
-- ---------------------------------------------------------------------------
function Helpers.ReadDataContextText(dc)
    if not dc or type(dc) ~= "userdata" then return nil end
    local name = TryRead(dc, "Text")
    if not name or type(name) ~= "string" then return nil end
    local value = ReadGenericValue(dc)
    return FormatNameValue(name, value)
end

-- ---------------------------------------------------------------------------
-- Public value-only reader — returns just the current value ("On", "Off",
-- "75", combo selection text, etc.) without the option name.  Used by the
-- INPC callback so value changes speak concisely (e.g. "On" not
-- "Show Tutorials: On").  Returns nil if no value can be read.
-- ---------------------------------------------------------------------------
function Helpers.ReadDataContextValue(dc)
    if not dc or type(dc) ~= "userdata" then return nil end
    return ReadGenericValue(dc)
end

-- ---------------------------------------------------------------------------
-- Main text extraction
-- ---------------------------------------------------------------------------

function Helpers.ExtractTextFromElement(element)
    if not Helpers._IsElementValid(element) then return nil end

    local okT, typeName = pcall(function() return element.Type end)
    typeName = (okT and type(typeName) == "string") and typeName or "?"

    local texts = {}

    -----------------------------------------------------------------------
    -- Step 0: Try DataContext (ViewModel) — generic property reading.
    -- Works for Options menu and any ViewModel-driven menu without
    -- needing per-menu handler code.  Reads "Text" (option name) and
    -- "Value" / "SelectedItem" (current value) from the ViewModel.
    -----------------------------------------------------------------------
    local okDC, dc = pcall(element.GetProperty, element, "DataContext")
    if okDC and dc and type(dc) == "userdata" then
        local dcName = TryRead(dc, "Text")
        if dcName and type(dcName) == "string" then
            local dcValue = ReadGenericValue(dc)
            local result = FormatNameValue(dcName, dcValue)
            Ext.Utils.Print("[BG3Access]   -> DataContext: " .. result)
            return result
        end
    end

    -----------------------------------------------------------------------
    -- Step 1: Walk the element's visual subtree for TextBlocks (depth 10).
    -----------------------------------------------------------------------
    texts = Helpers.GatherTextBlockTexts(element, 10)
    if #texts > 0 then
        Ext.Utils.Print("[BG3Access]   -> VisualTree walk: " .. table.concat(texts, " | "))
    end

    -----------------------------------------------------------------------
    -- Step 2: Walk UP looking for ContentPresenter / ListBoxItem, then
    -- walk that ancestor's subtree.
    -----------------------------------------------------------------------
    if #texts == 0 then
        local best = nil
        local cur = element
        for _ = 1, 6 do
            local okPT, t = pcall(function() return cur.Type end)
            if okPT and type(t) == "string" then
                if t == "ContentPresenter" or t == "ls.LSListBoxItem" or t == "ListBoxItem" then
                    best = cur
                    break
                end
            end
            local okP, parent = pcall(function() return cur.Parent end)
            if not okP or not parent or not Helpers._IsElementValid(parent) then break end
            cur = parent
        end
        if best then
            texts = Helpers.GatherTextBlockTexts(best, 10)
            if #texts > 0 then
                Ext.Utils.Print("[BG3Access]   -> Ancestor walk: " .. table.concat(texts, " | "))
            end
        end
    end

    -----------------------------------------------------------------------
    -- Step 3: Try element Name, cleaned up (strip "Button", split CamelCase).
    -----------------------------------------------------------------------
    if #texts == 0 then
        local okN, name = pcall(element.GetProperty, element, "Name")
        if okN and type(name) == "string" and name ~= "" then
            local cleaned = CleanUpName(name)
            if cleaned then
                Ext.Utils.Print("[BG3Access]   -> Name fallback: " .. name .. " -> " .. cleaned)
                table.insert(texts, cleaned)
            end
        end
    end

    -----------------------------------------------------------------------
    -- Step 4: For checkboxes/tickboxes only, append On/Off from IsChecked.
    -----------------------------------------------------------------------
    if #texts > 0 and (typeName:find("TickBox") or typeName:find("CheckBox")) then
        local okIC, isChecked = pcall(element.GetProperty, element, "IsChecked")
        if okIC and type(isChecked) == "boolean" then
            table.insert(texts, isChecked and "On" or "Off")
        end
    end

    if #texts == 0 then
        Ext.Utils.Print("[BG3Access]   -> No text found for " .. typeName)
        return nil
    end
    if #texts == 1 then return texts[1] end
    return texts[1] .. ": " .. table.concat(texts, ", ", 2)
end

-- ---------------------------------------------------------------------------
-- Tab name extraction — for carousel/tab items (ListBoxItem, ls.LSListItem)
-- that don't have a DataContext with "Text".  Tries multiple approaches:
-- visual TextBlocks, Content property, DataContext properties, Name cleanup.
-- ---------------------------------------------------------------------------

function Helpers.ExtractTabName(element)
    if not Helpers._IsElementValid(element) then return nil end

    -- Try 1: Visual tree walk for TextBlocks (deep search)
    local texts = Helpers.GatherTextBlockTexts(element, 15)
    if #texts > 0 then return texts[1] end

    -- Try 2: Content property (some tab items store text here)
    local okC, content = pcall(element.GetProperty, element, "Content")
    if okC and type(content) == "string" and content ~= "" then
        return Helpers.GetTranslatedStringIfHandle(content)
    end

    -- Try 3: Header property
    local okH, header = pcall(element.GetProperty, element, "Header")
    if okH and type(header) == "string" and header ~= "" then
        return Helpers.GetTranslatedStringIfHandle(header)
    end

    -- Try 4: DataContext properties (try common naming patterns)
    local okDC, dc = pcall(element.GetProperty, element, "DataContext")
    if okDC and dc and type(dc) == "userdata" then
        for _, prop in ipairs({"Text", "Name", "Label", "Header", "Title"}) do
            local hasProp = pcall(function() return Ext.UI.HasProperty(dc, prop) end)
            if hasProp then
                local okP, val = pcall(dc.GetProperty, dc, prop)
                if okP and type(val) == "string" and val ~= "" then
                    return Helpers.GetTranslatedStringIfHandle(val)
                end
            end
        end
    end

    -- Try 5: ToString on element (some elements return useful text)
    local okS, str = pcall(element.ToString, element)
    if okS and type(str) == "string" and str ~= "" then
        local okT2, typeName = pcall(function() return element.Type end)
        typeName = (okT2 and type(typeName) == "string") and typeName or "?"
        -- Filter out the type name itself
        if str ~= typeName and not str:find("^Noesis::") and not str:find("^ls%.") then
            return Helpers.GetTranslatedStringIfHandle(str)
        end
    end

    -- Try 6: Element Name cleanup
    local okN, name = pcall(element.GetProperty, element, "Name")
    if okN and type(name) == "string" and name ~= "" then
        -- Strip common suffixes, insert spaces in CamelCase
        local cleaned = name:gsub("Button$", ""):gsub("Btn$", ""):gsub("Tab$", "")
        cleaned = cleaned:gsub("(%l)(%u)", "%1 %2"):gsub("(%u%u)(%u%l)", "%1 %2")
        if cleaned ~= "" then return cleaned end
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Find the first REAL option item in the UI tree.  Used to auto-speak the
-- first option after a tab switch.  Walks depth-first from `root`.
--
-- A real option is a ContentPresenter whose DataContext has:
--   - "Text" property (the option name, e.g. "Show Tutorials")
--   - "Value" OR "SelectedItem" property (the current setting)
-- This filters out section headers like "General" which only have "Text".
-- ---------------------------------------------------------------------------

function Helpers.FindFirstOptionItem(root, maxDepth)
    maxDepth = maxDepth or 20
    if not Helpers._IsElementValid(root) or maxDepth <= 0 then return nil end

    local okT, typeName = pcall(function() return root.Type end)
    typeName = (okT and type(typeName) == "string") and typeName or "?"

    -- ContentPresenter with DataContext that has "Text" AND a value property
    if typeName == "ContentPresenter" then
        local okDC, dc = pcall(root.GetProperty, root, "DataContext")
        if okDC and dc and type(dc) == "userdata" then
            local hasText = false
            local okH = pcall(function() hasText = Ext.UI.HasProperty(dc, "Text") end)
            if okH and hasText then
                local okTxt, txt = pcall(dc.GetProperty, dc, "Text")
                if okTxt and type(txt) == "string" and txt ~= "" then
                    -- Must also have a value property to be a real option
                    -- (not just a section header like "General").
                    local hasValue = false
                    pcall(function() hasValue = Ext.UI.HasProperty(dc, "Value") end)
                    if not hasValue then
                        pcall(function() hasValue = Ext.UI.HasProperty(dc, "SelectedItem") end)
                    end
                    if hasValue then
                        return root
                    end
                end
            end
        end
    end

    -- Recurse into children
    local okC, count = pcall(function() return root.VisualChildrenCount end)
    if okC and type(count) == "number" then
        for i = 1, count do
            local okCh, child = pcall(root.VisualChild, root, i)
            if okCh and child then
                local found = Helpers.FindFirstOptionItem(child, maxDepth - 1)
                if found then return found end
            end
        end
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Find the selected ListBoxItem in the tree (Lua equivalent of the C++
-- FindSelectedTabInTree).  Returns the first ListBoxItem-type element
-- whose IsSelected property is true.
-- ---------------------------------------------------------------------------

local function FindSelectedTabLua(element, depth)
    if not element or depth <= 0 then return nil end
    local okT, typeName = pcall(function() return element.Type end)
    if okT and type(typeName) == "string" then
        if typeName:find("ListBoxItem") or typeName:find("ListItem") then
            local okSel, isSel = pcall(element.GetProperty, element, "IsSelected")
            if okSel and isSel == true then
                return element
            end
        end
    end
    local okC, count = pcall(function() return element.VisualChildrenCount end)
    if okC and type(count) == "number" then
        for i = 1, count do
            local okCh, child = pcall(element.VisualChild, element, i)
            if okCh and child then
                local found = FindSelectedTabLua(child, depth - 1)
                if found then return found end
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Gather text scoped to the tab's content area.
--
-- Instead of walking from root (which picks up the main menu, footer,
-- version text, and stale content from other tabs), this finds the
-- selected tab's carousel, walks up to the container holding both the
-- carousel and the content panel, and gathers text only from there.
--
-- Tree structure (typical):
--   Container (Grid/Panel)
--     ├── Carousel (ListBox with tab ListBoxItems)
--     └── ContentArea (the tab's body text, buttons, etc.)
--
-- We find: tab → walk up to carousel (ListBox parent) → walk up to
-- container (carousel's parent, skipping wrappers like Border).
-- ---------------------------------------------------------------------------

function Helpers.GatherTabContentText(root)
    local tab = FindSelectedTabLua(root, 20)
    if not tab then
        Ext.Utils.Print("[BG3Access]   -> GatherTabContentText: no selected tab found")
        return {}
    end

    -- Walk up from tab to find its carousel parent (ListBox/ItemsControl)
    local carousel = nil
    local cur = tab
    for i = 1, 6 do
        local okP, parent = pcall(function() return cur.Parent end)
        if not okP or not parent or not Helpers._IsElementValid(parent) then break end
        local okT, typeName = pcall(function() return parent.Type end)
        if okT and type(typeName) == "string" then
            if typeName:find("ListBox") or typeName:find("ItemsControl")
                or typeName:find("Selector") or typeName:find("LSList") then
                carousel = parent
                break
            end
        end
        cur = parent
    end

    if not carousel then
        Ext.Utils.Print("[BG3Access]   -> GatherTabContentText: no carousel parent found")
        return {}
    end

    -- Walk up from carousel to find the container that holds BOTH the
    -- tab strip AND the content area.  The first Grid/Panel above the
    -- carousel is typically just the tab strip wrapper — we need to go
    -- past it to the outer container.  Strategy: find the SECOND
    -- Grid/Panel in the ancestor chain (skip the first one).
    local container = nil
    local panelCount = 0
    cur = carousel
    for i = 1, 6 do
        local okP, parent = pcall(function() return cur.Parent end)
        if not okP or not parent or not Helpers._IsElementValid(parent) then break end
        local okT, typeName = pcall(function() return parent.Type end)
        if okT and type(typeName) == "string" then
            if typeName:find("Grid") or typeName:find("Panel")
                or typeName:find("StackPanel") or typeName:find("DockPanel") then
                panelCount = panelCount + 1
                if panelCount >= 2 then
                    container = parent
                    break
                end
            end
        end
        cur = parent
    end
    -- If only one panel found, use it anyway (better than nothing)
    if not container and panelCount == 1 then
        container = cur
    end

    if not container then
        Ext.Utils.Print("[BG3Access]   -> GatherTabContentText: no container found")
        return {}
    end

    local okCT, containerType = pcall(function() return container.Type end)
    Ext.Utils.Print("[BG3Access]   -> GatherTabContentText: scoped to "
        .. ((okCT and type(containerType) == "string") and containerType or "?"))

    return Helpers.GatherTextBlockTexts(container, 20)
end

Ext.Utils.Print("[AccessibilityHelpers.lua] Loaded.")
