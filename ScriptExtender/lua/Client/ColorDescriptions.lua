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

-- Perceptual luminance (0-100) from linear RGB.
-- More accurate than HSL lightness for how humans perceive shade.
local function PerceptualLuminance(hexString)
    local hex = hexString:gsub("^#", "")
    if #hex == 8 then hex = hex:sub(3) end
    if #hex ~= 6 then return 0 end

    local function linearize(channelByte)
        local normalized = channelByte / 255
        if normalized <= 0.04045 then
            return normalized / 12.92
        end
        return ((normalized + 0.055) / 1.055) ^ 2.4
    end

    local red = linearize(tonumber(hex:sub(1, 2), 16))
    local green = linearize(tonumber(hex:sub(3, 4), 16))
    local blue = linearize(tonumber(hex:sub(5, 6), 16))

    return (0.2126 * red + 0.7152 * green + 0.0722 * blue) * 100
end

-- Describe a skin color hex code.
-- Uses perceptual luminance for shade and HSL hue for undertone.
-- Fantasy skin (purple/pink/green/blue) uses luminance to shift
-- the COLOR NAME (pink -> purple -> eggplant), not just the shade.
local function DescribeSkinColor(hexString)
    local hue, saturation, lightness = HexToHSL(hexString)
    local luminance = PerceptualLuminance(hexString)

    -- Very low saturation = gray/ashen skin (drow, undead)
    if saturation < 8 then
        if luminance > 70 then return "pale gray"
        elseif luminance > 50 then return "light gray"
        elseif luminance > 30 then return "medium gray"
        elseif luminance > 15 then return "dark gray"
        else return "very dark gray" end
    end

    -- Fantasy hues: use luminance to shift the color NAME.
    -- Pink at high luminance, purple at mid, eggplant at low.
    if hue >= 70 and hue < 160 then
        -- Green skin
        if luminance > 50 then return "light green"
        elseif luminance > 30 then return "medium green"
        elseif luminance > 15 then return "dark green"
        else return "very dark green" end
    elseif hue >= 160 and hue < 250 then
        -- Blue/teal skin
        if luminance > 50 then return "light blue"
        elseif luminance > 30 then return "medium blue"
        elseif luminance > 15 then return "dark blue"
        else return "very dark blue" end
    elseif (hue >= 250 and hue < 340) then
        -- Purple/pink/mauve range.  Luminance determines
        -- whether it reads as pink, purple, or eggplant.
        if luminance > 55 then return "light pinkish-lavender"
        elseif luminance > 40 then return "soft lavender"
        elseif luminance > 28 then return "medium purple"
        elseif luminance > 18 then return "dark purple"
        elseif luminance > 10 then return "deep eggplant"
        else return "very dark eggplant" end
    end

    -- Natural human skin tones (hue 0-70).
    -- Shade from perceptual luminance, undertone from hue.
    local shade
    if luminance > 75 then shade = "very pale"
    elseif luminance > 60 then shade = "pale"
    elseif luminance > 48 then shade = "light"
    elseif luminance > 36 then shade = "medium"
    elseif luminance > 26 then shade = "medium-dark"
    elseif luminance > 18 then shade = "dark"
    elseif luminance > 10 then shade = "very dark"
    else shade = "deep dark" end

    -- Undertone from hue
    local undertone
    if hue < 15 or hue > 340 then undertone = "rosy"
    elseif hue < 25 then undertone = "warm"
    elseif hue < 38 then undertone = "golden"
    else undertone = "olive" end

    return shade .. " skin with " .. undertone .. " undertones"
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
-- Uses perceptual luminance + hue + saturation for accurate naming.
local function DescribeEyeColor(hexString)
    local hue, saturation, lightness = HexToHSL(hexString)
    local luminance = PerceptualLuminance(hexString)

    -- Low saturation: gray/silver eyes.
    -- High luminance + low sat = silver/ice.  Low = steel/dark.
    if saturation < 15 then
        if luminance > 55 then return "silver"
        elseif luminance > 40 then return "steel gray"
        elseif luminance > 25 then return "dark gray"
        else return "very dark gray" end
    end

    -- Red eyes
    if hue < 15 or hue > 350 then
        if luminance > 40 then return "light red"
        elseif luminance > 20 then return "red"
        else return "deep red" end

    -- Amber/hazel/brown (warm hues 15-40)
    elseif hue < 40 then
        if saturation > 60 and luminance > 35 then return "amber"
        elseif luminance > 50 then return "light amber"
        elseif luminance > 30 then return "hazel"
        elseif luminance > 18 then return "dark brown"
        else return "very dark brown" end

    -- Golden/yellow-brown (40-65)
    elseif hue < 65 then
        if luminance > 45 then return "golden"
        elseif luminance > 30 then return "hazel"
        elseif luminance > 18 then return "dark brown"
        else return "very dark brown" end

    -- Yellow-green / olive (65-90)
    elseif hue < 90 then
        if luminance > 40 then return "yellow-green"
        elseif luminance > 20 then return "olive"
        else return "dark olive" end

    -- Green (90-160)
    elseif hue < 160 then
        if luminance > 45 then return "light green"
        elseif luminance > 25 then return "green"
        elseif luminance > 12 then return "dark green"
        else return "very dark green" end

    -- Teal/cyan (160-200)
    elseif hue < 200 then
        if luminance > 45 then return "light teal"
        elseif luminance > 25 then return "teal"
        elseif luminance > 12 then return "dark teal"
        else return "very dark teal" end

    -- Blue (200-250)
    elseif hue < 250 then
        if luminance > 50 then return "ice blue"
        elseif luminance > 30 then return "blue"
        elseif luminance > 15 then return "dark blue"
        else return "very dark blue" end

    -- Purple/pink (250+) -- luminance determines which
    elseif hue < 310 then
        if luminance > 40 then return "light purple"
        elseif luminance > 25 then return "purple"
        elseif luminance > 12 then return "dark purple"
        else return "very dark purple" end
    else
        if luminance > 40 then return "pink"
        elseif luminance > 25 then return "dark pink"
        else return "deep magenta" end
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
