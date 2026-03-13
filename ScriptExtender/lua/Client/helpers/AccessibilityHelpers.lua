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

    -- Skip elements that are not actually visible on screen.
    -- IsVisible is a computed boolean that accounts for parent Collapsed/Hidden
    -- state (a TextBlock inside a Collapsed panel has Visibility="Visible"
    -- locally, but IsVisible=false).  This prevents text from panels belonging
    -- to other tabs (e.g. CrossplayDisabledWarning on the LAN tab, or
    -- MainList column headers on the Cross-Play tab).
    -- IsVisible is a computed boolean that accounts for ancestor visibility.
    -- A TextBlock inside a Collapsed parent has IsVisible=false even though
    -- its own local Visibility is "Visible".  The BG3SE bridge returns this
    -- as a boolean (confirmed via diagnostic logging).
    local okIsVis, isVis = pcall(element.GetProperty, element, "IsVisible")
    if okIsVis and type(isVis) == "boolean" and isVis == false then
        return {}
    end

    local texts = {}

    local okT, typeName = pcall(function() return element.Type end)
    if okT and type(typeName) == "string" then
        -- Skip interactive list containers — these hold repeating items
        -- (lobby entries, settings rows, etc.) that should be navigated
        -- individually via focus, not dumped wholesale in a fallback.
        if typeName == "ListView" or typeName == "ListBox"
            or typeName == "DataGrid" then
            return {}
        end
    end

    if okT and type(typeName) == "string" and typeName:find("TextBlock") then
        -- Try GetProperty("Text") first (works for local/non-bound values)
        local okV, text = pcall(element.GetProperty, element, "Text")
        if okV and type(text) == "string" and text ~= ""
            and not text:find("%[ForceUpdate%]") then
            table.insert(texts, Helpers.GetTranslatedStringIfHandle(text))
        end

        -- Try Inlines collection — formatter-populated text lives here as
        -- Run objects.  Collections use array-style access: #col, col[i].
        if #texts == 0 then
            local okInl, inlines = pcall(element.GetProperty, element, "Inlines")
            if okInl and inlines then
                local okLen, inlLen = pcall(function() return #inlines end)
                if okLen and type(inlLen) == "number" and inlLen > 0 then
                    local parts = {}
                    for i = 1, inlLen do
                        local okI, inline = pcall(function() return inlines[i] end)
                        if okI and inline then
                            local okIT, iType = pcall(function() return inline.Type end)
                            iType = (okIT and type(iType) == "string") and iType or ""
                            if iType:find("Run") then
                                local okRT, runText = pcall(inline.GetProperty, inline, "Text")
                                if okRT and type(runText) == "string" and runText ~= ""
                                    and not runText:find("%[ForceUpdate%]") then
                                    table.insert(parts, runText)
                                end
                            elseif iType:find("LineBreak") then
                                -- Sentence boundary — insert space
                                table.insert(parts, " ")
                            end
                        end
                    end
                    if #parts > 0 then
                        local joined = table.concat(parts, "")
                        -- Collapse multiple spaces
                        joined = joined:gsub("  +", " "):gsub("^ ", ""):gsub(" $", "")
                        if joined ~= "" then
                            table.insert(texts, Helpers.GetTranslatedStringIfHandle(joined))
                        end
                    end
                end
            end
        end

        -- Last resort: ToString() which may return rendered text content.
        if #texts == 0 then
            local okS, str = pcall(element.ToString, element)
            if okS and type(str) == "string" and str ~= ""
                and not str:find("TextBlock") and not str:find("%[ForceUpdate%]") then
                table.insert(texts, Helpers.GetTranslatedStringIfHandle(str))
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
-- Logical tree walking -- gather TextBlock text from authored elements.
--
-- Page-level TextBlocks (CrossPlayWarningTitle, etc.) appear in the logical
-- tree.  Only template-internal TextBlocks are visual-tree-only.  This is
-- dramatically more efficient than visual tree walking (~80% fewer nodes)
-- because the logical tree omits Borders, Images, Rectangles, etc.
--
-- IMPORTANT: Do NOT recurse into TextBlock's logical children -- those are
-- Inline objects (Run, LineBreak) which the three-step extraction already
-- handles.  Also guard against non-element types (ls.VMInputEvent,
-- ls.VMTickBoxSetting, Boxed<String>, etc.) that appear as logical children
-- of ItemsControl and throw errors on GetProperty("Name").
-- ---------------------------------------------------------------------------

function Helpers.GatherLogicalTextBlockTexts(element, maxDepth)
    if not element or maxDepth <= 0 then return {} end

    -- Guard: non-element types in logical tree (ViewModels, boxed values)
    -- have no Type property or throw on property access.
    local okT, typeName = pcall(function() return element.Type end)
    if not okT or type(typeName) ~= "string" then return {} end

    -- Skip invisible elements (same as visual tree version).
    local okIsVis, isVis = pcall(element.GetProperty, element, "IsVisible")
    if okIsVis and type(isVis) == "boolean" and isVis == false then
        return {}
    end

    local texts = {}

    -- Skip interactive list containers.
    if typeName == "ListView" or typeName == "ListBox"
        or typeName == "DataGrid" then
        return {}
    end

    if typeName:find("TextBlock") then
        -- Three-step extraction (same logic as GatherTextBlockTexts).
        -- Step 1: GetProperty("Text")
        local okV, text = pcall(element.GetProperty, element, "Text")
        if okV and type(text) == "string" and text ~= ""
            and not text:find("%[ForceUpdate%]") then
            table.insert(texts, Helpers.GetTranslatedStringIfHandle(text))
        end

        -- Step 2: Inlines collection
        if #texts == 0 then
            local okInl, inlines = pcall(element.GetProperty, element, "Inlines")
            if okInl and inlines then
                local okLen, inlLen = pcall(function() return #inlines end)
                if okLen and type(inlLen) == "number" and inlLen > 0 then
                    local parts = {}
                    for i = 1, inlLen do
                        local okI, inline = pcall(function() return inlines[i] end)
                        if okI and inline then
                            local okIT, iType = pcall(function() return inline.Type end)
                            iType = (okIT and type(iType) == "string") and iType or ""
                            if iType:find("Run") then
                                local okRT, runText = pcall(inline.GetProperty, inline, "Text")
                                if okRT and type(runText) == "string" and runText ~= ""
                                    and not runText:find("%[ForceUpdate%]") then
                                    table.insert(parts, runText)
                                end
                            elseif iType:find("LineBreak") then
                                table.insert(parts, " ")
                            end
                        end
                    end
                    if #parts > 0 then
                        local joined = table.concat(parts, "")
                        joined = joined:gsub("  +", " "):gsub("^ ", ""):gsub(" $", "")
                        if joined ~= "" then
                            table.insert(texts, Helpers.GetTranslatedStringIfHandle(joined))
                        end
                    end
                end
            end
        end

        -- Step 3: ToString()
        if #texts == 0 then
            local okS, str = pcall(element.ToString, element)
            if okS and type(str) == "string" and str ~= ""
                and not str:find("TextBlock") and not str:find("%[ForceUpdate%]") then
                table.insert(texts, Helpers.GetTranslatedStringIfHandle(str))
            end
        end

        -- Do NOT recurse into TextBlock children (Inlines are logical children).
    else
        -- Recurse into logical children.
        local okC, count = pcall(function() return element.ChildrenCount end)
        if okC and type(count) == "number" then
            for i = 1, count do
                local okCh, child = pcall(element.Child, element, i)
                if okCh and child then
                    local childTexts = Helpers.GatherLogicalTextBlockTexts(child, maxDepth - 1)
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

    -- Try reading "Text" from dc as a ViewModel (normal path).
    -- Wrapped in pcall because dc might be an ls.LocaString, not a ViewModel.
    local name = nil
    local ok, val = pcall(function() return TryRead(dc, "Text") end)
    if ok and val and type(val) == "string" then
        name = val
    end

    -- If dc has no "Text" property, it might BE the localization handle itself.
    -- ls.LocaString is userdata, not a Lua string, so we tostring() it to get
    -- the handle (e.g. "h5c6f6ec7g160ag..."), then translate.
    if not name then
        local okStr, strVal = pcall(tostring, dc)
        if okStr and type(strVal) == "string" and strVal ~= "" then
            local translated = Helpers.GetTranslatedStringIfHandle(strVal)
            if translated and translated ~= strVal then
                name = translated
            elseif strVal:match("^h%x") then
                -- Looks like an unresolved loca handle, return it anyway
                name = strVal
            end
        end
    end

    if not name or type(name) ~= "string" then return nil end

    -- Filter binding placeholders
    if name:find("%[ForceUpdate%]") then return nil end

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
    local ok, val = pcall(ReadGenericValue, dc)
    if ok and val then
        if type(val) == "string" and val:find("%[ForceUpdate%]") then return nil end
        return val
    end
    return nil
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
        local dcText = Helpers.ReadDataContextText(dc)
        if dcText then
            Ext.Utils.Print("[BG3Access]   -> DataContext: " .. dcText)
            return dcText
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
-- Walk up the parent chain to the widget root (the top-level element
-- whose Parent is nil).  This is typically a Grid named 'Root', ~5 hops
-- from any focused element.  Find() works from this element because it
-- shares a NameScope with all authored x:Name elements in the widget.
--
-- NOTE: Ext.UI.GetRoot() returns the APPLICATION root, which is ABOVE
-- the widget NameScope boundary — Find() from there returns nil for
-- widget-level names.  Always use this helper instead.
-- ---------------------------------------------------------------------------
local function GetWidgetRoot(element)
    local cur = element
    for i = 1, 30 do
        local okP, parent = pcall(function() return cur.Parent end)
        if not okP or not parent then
            return cur
        end
        cur = parent
    end
    return cur
end

-- ---------------------------------------------------------------------------
-- Find the first REAL option item in the UI tree.  Used to auto-speak the
-- first option after a tab switch.
--
-- Optimized path: finds the selected tab -> walks up to widget root ->
-- uses Find("Options") to locate the ItemsControl directly -> walks only
-- its small visual subtree (~90% fewer nodes than full DFS from app root).
--
-- Falls back to full DFS if Find("Options") fails (non-Options menu).
--
-- A real option is a ContentPresenter whose DataContext has:
--   - "Text" property (the option name, e.g. "Show Tutorials")
--   - "Value" OR "SelectedItem" property (the current setting)
-- This filters out section headers like "General" which only have "Text".
-- ---------------------------------------------------------------------------

-- Inner recursive search for a ContentPresenter with the right DataContext.
-- Walks VISUAL tree because ItemsControl's logical children are ViewModels,
-- not ContentPresenters (those are generated in the visual tree under
-- ScrollViewer -> ItemsPresenter -> StackPanel).
local function FindFirstOptionDFS(elem, maxDepth)
    if not elem or maxDepth <= 0 then return nil end

    local okT, typeName = pcall(function() return elem.Type end)
    typeName = (okT and type(typeName) == "string") and typeName or "?"

    if typeName == "ContentPresenter" then
        local okDC, dc = pcall(elem.GetProperty, elem, "DataContext")
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
                        return elem
                    end
                end
            end
        end
    end

    local okC, count = pcall(function() return elem.VisualChildrenCount end)
    if okC and type(count) == "number" then
        for i = 1, count do
            local okCh, child = pcall(elem.VisualChild, elem, i)
            if okCh and child then
                local found = FindFirstOptionDFS(child, maxDepth - 1)
                if found then return found end
            end
        end
    end

    return nil
end

function Helpers.FindFirstOptionItem(root, maxDepth)
    maxDepth = maxDepth or 20
    if not Helpers._IsElementValid(root) then return nil end

    -- Optimized path: use Find("Options") from widget root to narrow the search.
    -- root is typically Ext.UI.GetRoot() (app root), so we first need to get
    -- inside the widget via FindSelectedTabLua, then walk up to widget root.
    local tab = FindSelectedTabLua(root, 20)
    if tab then
        local widgetRoot = GetWidgetRoot(tab)
        if widgetRoot then
            local okF, optionsCtrl = pcall(widgetRoot.Find, widgetRoot, "Options")
            if okF and optionsCtrl then
                Ext.Utils.Print("[BG3Access]   -> FindFirstOptionItem: using Find('Options') shortcut")
                return FindFirstOptionDFS(optionsCtrl, maxDepth)
            end
        end
    end

    -- Fallback: full DFS from root (handles non-Options menus).
    Ext.Utils.Print("[BG3Access]   -> FindFirstOptionItem: falling back to full DFS")
    return FindFirstOptionDFS(root, maxDepth)
end

-- ---------------------------------------------------------------------------
-- Gather text scoped to the tab's content area.
--
-- Uses Find() from the widget root to locate the carousel by name
-- ("HeaderCarouselList"), then walks up to the shared parent that holds
-- both the carousel and content as sibling branches.  Gathers text from
-- all sibling branches EXCEPT the one containing the carousel.
--
-- Uses the LOGICAL tree for sibling walking and text gathering (~80%
-- fewer nodes than visual tree).  Page-level TextBlocks appear in the
-- logical tree; only template-internal ones are visual-tree-only.
--
-- Tree structure (both Options and Multiplayer menus):
--   SharedParent (Grid/Panel)
--     +-- CarouselBranch (contains HeaderCarouselList)
--     +-- ContentBranch  (tab body text, buttons, etc.)
--     +-- ...            (optional footer/other branches)
-- ---------------------------------------------------------------------------

function Helpers.GatherTabContentText(root)
    -- Step 1: Find the selected tab by walking DOWN the visual tree.
    -- We need an element INSIDE the widget so we can walk UP to the
    -- widget root (where Find() works).  Ext.UI.GetRoot() returns the
    -- APPLICATION root which is ABOVE the widget NameScope boundary.
    local tab = FindSelectedTabLua(root, 20)
    if not tab then
        Ext.Utils.Print("[BG3Access]   -> GatherTabContentText: no selected tab found")
        return {}
    end

    -- Step 2: Walk up from the tab to the widget root.
    local widgetRoot = GetWidgetRoot(tab)
    if not widgetRoot then
        Ext.Utils.Print("[BG3Access]   -> GatherTabContentText: no widget root")
        return {}
    end

    -- Step 3: Find the carousel by name -- both Options and Multiplayer
    -- menus use "HeaderCarouselList" as the ListBox containing tab items.
    local okF, carousel = pcall(widgetRoot.Find, widgetRoot, "HeaderCarouselList")
    if not okF or not carousel then
        Ext.Utils.Print("[BG3Access]   -> GatherTabContentText: Find('HeaderCarouselList') failed")
        return {}
    end

    -- Step 4: Build ancestor set from carousel upward so we can identify
    -- which logical child of any candidate shared parent contains the
    -- carousel branch.
    local ancestors = {}
    local cur = carousel
    for i = 1, 12 do
        ancestors[tostring(cur)] = true
        local okP, parent = pcall(function() return cur.Parent end)
        if not okP or not parent or not Helpers._IsElementValid(parent) then break end
        cur = parent
        ancestors[tostring(cur)] = true
    end

    -- Step 5: Walk up from carousel, trying each Grid/Panel with 2+
    -- logical children as a candidate shared parent.  Gather text from
    -- all sibling branches except the carousel's.  Stop as soon as we
    -- get text (avoids picking up footer/version strings from higher
    -- levels).
    cur = carousel
    for level = 1, 8 do
        local okP, parent = pcall(function() return cur.Parent end)
        if not okP or not parent or not Helpers._IsElementValid(parent) then break end

        local isContainer = false
        local okT, typeName = pcall(function() return parent.Type end)
        if okT and type(typeName) == "string" then
            if typeName:find("Grid") or typeName:find("Panel")
                or typeName:find("StackPanel") or typeName:find("DockPanel") then
                isContainer = true
            end
        end

        if isContainer then
            -- Use logical children (ChildrenCount/Child) instead of
            -- visual children.  The logical tree has the authored
            -- structure without template expansion.
            local okCC, childCount = pcall(function() return parent.ChildrenCount end)
            if okCC and type(childCount) == "number" and childCount >= 2 then
                -- Find which direct logical child branch contains the carousel.
                local carouselBranchIndex = nil
                for i = 1, childCount do
                    local okCh, child = pcall(parent.Child, parent, i)
                    if okCh and child and ancestors[tostring(child)] then
                        carouselBranchIndex = i
                        break
                    end
                end

                Ext.Utils.Print("[BG3Access]   -> GatherTabContentText: level="
                    .. tostring(level) .. " parent="
                    .. ((okT and type(typeName) == "string") and typeName or "?")
                    .. " logicalChildren=" .. tostring(childCount)
                    .. " carouselBranch=" .. tostring(carouselBranchIndex))

                -- Gather text from all logical children EXCEPT the carousel branch.
                -- Uses GatherLogicalTextBlockTexts for efficient logical tree walk.
                local allTexts = {}
                for i = 1, childCount do
                    if i ~= carouselBranchIndex then
                        local okCh, child = pcall(parent.Child, parent, i)
                        if okCh and child then
                            local childTexts = Helpers.GatherLogicalTextBlockTexts(child, 20)
                            for _, t in ipairs(childTexts) do
                                table.insert(allTexts, t)
                            end
                        end
                    end
                end

                if #allTexts > 0 then
                    return allTexts
                end
                -- No text at this level -- keep walking up.
            end
        end

        cur = parent
    end

    Ext.Utils.Print("[BG3Access]   -> GatherTabContentText: no text found at any level")
    return {}
end

Ext.Utils.Print("[AccessibilityHelpers.lua] Loaded.")
