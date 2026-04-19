-- ---------------------------------------------------------------------------
-- ColorDescriptions: converts ARGB hex color codes (from UIColor on
-- character creation color swatch ViewModels) into plain-English spoken
-- descriptions via HSL binning.
--
-- Covers skin, hair, and eye colors.  The CC handler passes the hex
-- code from snapshot.inlineCarouselColorHex and receives a description
-- like "medium, warm undertone" or "golden blonde" or "light blue".
--
-- Ported from tools/color_namer_prototype.py.  Runtime conversion --
-- works with modded color presets, no static lookup tables needed.
-- ---------------------------------------------------------------------------

local Log = BG3Access.Client.Log

-- Convert "#AARRGGBB" or "#RRGGBB" hex to (hue, saturation, lightness).
-- Hue in [0, 360], saturation and lightness in [0, 100].
local function HexToHSL(hexString)
    local hex = hexString:gsub("^#", "")
    -- Strip alpha channel from ARGB format
    if #hex == 8 then hex = hex:sub(3) end
    if #hex ~= 6 then return 0, 0, 0 end

    local red = tonumber(hex:sub(1, 2), 16) / 255
    local green = tonumber(hex:sub(3, 4), 16) / 255
    local blue = tonumber(hex:sub(5, 6), 16) / 255

    local maxChannel = math.max(red, green, blue)
    local minChannel = math.min(red, green, blue)
    local lightness = (maxChannel + minChannel) / 2

    if maxChannel == minChannel then
        return 0, 0, lightness * 100
    end

    local delta = maxChannel - minChannel
    local saturation
    if lightness > 0.5 then
        saturation = delta / (2 - maxChannel - minChannel)
    else
        saturation = delta / (maxChannel + minChannel)
    end

    local hue
    if maxChannel == red then
        hue = (green - blue) / delta
        if green < blue then hue = hue + 6 end
    elseif maxChannel == green then
        hue = (blue - red) / delta + 2
    else
        hue = (red - green) / delta + 4
    end
    hue = hue * 60

    return hue, saturation * 100, lightness * 100
end

-- Describe a skin color hex code.
-- Produces descriptions like "fair ivory, warm undertone" or
-- "medium brown, golden undertone" or "light lavender" (fantasy).
local function DescribeSkinColor(hexString)
    local hue, saturation, lightness = HexToHSL(hexString)

    -- Very low saturation = gray/ashen skin (fantasy races like drow)
    if saturation < 8 then
        if lightness > 80 then return "pale gray"
        elseif lightness > 60 then return "light gray"
        elseif lightness > 40 then return "medium gray"
        elseif lightness > 25 then return "dark gray"
        else return "very dark gray" end
    end

    -- Fantasy hues (non-human skin): green, blue, purple, pink
    if hue >= 70 and hue < 160 then
        -- Green skin (orcs, goblins, etc.)
        if lightness > 65 then return "light green"
        elseif lightness > 45 then return "medium green"
        elseif lightness > 30 then return "dark green"
        else return "very dark green" end
    elseif hue >= 160 and hue < 250 then
        -- Blue/cool skin (genasi, some tieflings)
        if lightness > 65 then return "light blue"
        elseif lightness > 45 then return "medium blue"
        elseif lightness > 30 then return "dark blue"
        else return "very dark blue" end
    elseif hue >= 250 and hue < 290 then
        -- Purple skin (drow, tieflings)
        if lightness > 65 then return "light lavender"
        elseif lightness > 45 then return "medium purple"
        elseif lightness > 30 then return "dark purple"
        else return "very dark purple" end
    elseif hue >= 290 and hue <= 340 then
        -- Pink skin (tieflings)
        if lightness > 65 then return "light pink"
        elseif lightness > 45 then return "medium pink"
        elseif lightness > 30 then return "dark pink"
        else return "very dark pink" end
    end

    -- Natural human-range hues (0-70): rosy, warm, golden, olive
    -- Base color encodes shade.  Finer bins to differentiate adjacent
    -- game tones (e.g. Ochre Tone 3 vs 4 are ~5 lightness apart).
    local baseColor
    if lightness > 85 then baseColor = "fair porcelain"
    elseif lightness > 78 then baseColor = "light ivory"
    elseif lightness > 70 then baseColor = "light peach"
    elseif lightness > 62 then baseColor = "medium peach"
    elseif lightness > 55 then baseColor = "medium tan"
    elseif lightness > 48 then baseColor = "light brown"
    elseif lightness > 42 then baseColor = "medium brown"
    elseif lightness > 36 then baseColor = "dark tan"
    elseif lightness > 30 then baseColor = "dark brown"
    elseif lightness > 24 then baseColor = "deep brown"
    elseif lightness > 18 then baseColor = "very deep brown"
    else baseColor = "ebony" end

    -- Undertone from hue
    local undertone
    if hue < 15 or hue > 340 then undertone = "rosy"
    elseif hue < 30 then undertone = "warm"
    elseif hue < 45 then undertone = "golden"
    else undertone = "olive" end

    return baseColor .. ", " .. undertone .. " undertone"
end

-- Describe a hair color hex code.
local function DescribeHairColor(hexString)
    local hue, saturation, lightness = HexToHSL(hexString)

    -- Very low saturation = gray/silver/white/black
    if saturation < 10 then
        if lightness > 85 then return "white"
        elseif lightness > 70 then return "silver"
        elseif lightness > 50 then return "medium gray"
        elseif lightness > 30 then return "dark gray"
        elseif lightness > 15 then return "charcoal"
        else return "black" end
    end

    -- Natural hair colors (hue 15-70)
    if hue < 15 or hue > 350 then
        -- Pure red range handled below as fantasy color
    elseif hue < 30 then
        if lightness > 70 then return "strawberry blonde"
        elseif lightness > 50 then return "auburn"
        elseif lightness > 35 then return "copper"
        else return "dark auburn" end
    elseif hue < 50 then
        if lightness > 75 then return "light golden blonde"
        elseif lightness > 60 then return "golden blonde"
        elseif lightness > 45 then return "dark blonde"
        elseif lightness > 30 then return "light brown"
        else return "medium brown" end
    elseif hue < 70 then
        if lightness > 60 then return "ash blonde"
        elseif lightness > 40 then return "light brown"
        elseif lightness > 25 then return "brown"
        else return "dark brown" end
    end

    -- Fantasy colors (green, blue, purple, pink, vivid red)
    local base
    if hue < 15 or hue > 350 then base = "red"
    elseif hue < 160 then base = "green"
    elseif hue < 250 then base = "blue"
    elseif hue < 290 then base = "purple"
    elseif hue < 340 then base = "pink"
    else base = "red" end

    local shade
    if lightness > 75 then shade = "light"
    elseif lightness > 50 then shade = "medium"
    elseif lightness > 30 then shade = "dark"
    else shade = "very dark" end

    return shade .. " " .. base
end

-- Describe an eye color hex code.
local function DescribeEyeColor(hexString)
    local hue, saturation, lightness = HexToHSL(hexString)

    -- Low saturation = gray eyes
    if saturation < 15 then
        if lightness > 60 then return "light gray"
        elseif lightness > 40 then return "gray"
        elseif lightness > 25 then return "dark gray"
        else return "very dark gray" end
    end

    -- Hue-based eye naming
    if hue < 15 or hue > 350 then
        if lightness > 50 then return "light red"
        else return "deep red" end
    elseif hue < 40 then
        if lightness > 60 then return "amber"
        elseif lightness > 40 then return "hazel"
        else return "dark hazel" end
    elseif hue < 65 then
        if lightness > 60 then return "golden"
        elseif lightness > 40 then return "hazel"
        else return "dark brown" end
    elseif hue < 90 then
        if lightness > 50 then return "yellow-green"
        else return "olive green" end
    elseif hue < 160 then
        if lightness > 60 then return "light green"
        elseif lightness > 40 then return "green"
        else return "dark green" end
    elseif hue < 200 then
        if lightness > 60 then return "light teal"
        elseif lightness > 40 then return "teal"
        else return "dark teal" end
    elseif hue < 250 then
        if lightness > 60 then return "light blue"
        elseif lightness > 40 then return "blue"
        else return "dark blue" end
    elseif hue < 290 then
        if lightness > 50 then return "light purple"
        elseif lightness > 30 then return "purple"
        else return "dark purple" end
    else
        if lightness > 50 then return "pink"
        else return "dark pink" end
    end
end

-- Map CC appearance item labels to their description function.
-- The CC handler matches the focused item's elemText (the carousel label)
-- against these keys to choose the right describer.
local LABEL_TO_DESCRIBER = {
    ["Skin Colour"]         = DescribeSkinColor,
    ["Skin Color"]          = DescribeSkinColor,
    ["Hair Colour"]         = DescribeHairColor,
    ["Hair Color"]          = DescribeHairColor,
    ["Eye Colour"]          = DescribeEyeColor,
    ["Eye Color"]           = DescribeEyeColor,
    -- Heterochromia second eye uses same describer
    ["Left Eye Colour"]     = DescribeEyeColor,
    ["Left Eye Color"]      = DescribeEyeColor,
    ["Right Eye Colour"]    = DescribeEyeColor,
    ["Right Eye Color"]     = DescribeEyeColor,
    -- Tattoo and scarring colors
    ["Tattoo Colour"]       = DescribeHairColor,
    ["Tattoo Color"]        = DescribeHairColor,
}

--- DescribeColorHex: given a CC appearance item label and a UIColor hex
--- code, returns a plain-English color description.  Returns nil if the
--- label is not a color carousel or the hex is invalid.
--- @param itemLabel string  The focused element's text (e.g. "Skin Colour").
--- @param hexCode string  UIColor from C++ (e.g. "#FFFFF0E6").
--- @return string|nil  Description like "medium, warm undertone" or nil.
local function DescribeColorHex(itemLabel, hexCode)
    if not itemLabel or not hexCode or hexCode == "" then return nil end
    local describer = LABEL_TO_DESCRIBER[itemLabel]
    if not describer then return nil end
    local description = describer(hexCode)
    if description then
        Log.Debug("COLOR: " .. itemLabel .. " " .. hexCode
            .. " -> " .. description)
    end
    return description
end

-- ---------------------------------------------------------------------------
-- Manual override table: sighted-validated descriptions.
-- Loaded from AppearanceOverrides.lua if present.  Keyed by the carousel
-- display value (Name/ColorName from the SelectedItem ViewModel).
-- Takes priority over computed color descriptions.
-- Covers faces, hairstyles, genitals, tattoos, scarring -- anything
-- where the display name alone isn't descriptive enough.
-- ---------------------------------------------------------------------------
local appearanceOverrides = {}

-- Try loading the override table.  Missing file is fine (pcall).
local loadSuccess, overrideTable = pcall(Ext.Require,
    "Client/AppearanceOverrides.lua")
if loadSuccess and type(overrideTable) == "table" then
    appearanceOverrides = overrideTable
    Log.Info("COLOR: Loaded " .. tostring(#overrideTable)
        .. " appearance overrides")
end

--- DescribeAppearanceItem: looks up a manual override for any appearance
--- carousel item (faces, hairstyles, genitals, tattoos, scarring, or
--- sighted-corrected color descriptions).
--- @param carouselValue string  The display name the user currently hears.
--- @return string|nil  Sighted-authored description, or nil if no override.
local function DescribeAppearanceItem(carouselValue)
    if not carouselValue or carouselValue == "" then return nil end
    local override = appearanceOverrides[carouselValue]
    if override and override ~= "" then
        Log.Debug("COLOR: override for " .. carouselValue
            .. " -> " .. override)
        return override
    end
    return nil
end

BG3Access.Client.ColorDescriptions = {
    DescribeColorHex         = DescribeColorHex,
    DescribeAppearanceItem   = DescribeAppearanceItem,
    HexToHSL                 = HexToHSL,
}
