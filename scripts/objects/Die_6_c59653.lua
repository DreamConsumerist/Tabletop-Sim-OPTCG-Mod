-- Who-goes-first die (stock-die version). Labels this die's own faces with
-- seat colors -- scoped to just the two seats in Description (e.g.
-- "White,Blue") if set, or every currently seated player if Description is
-- empty -- and auto-detects the roll's settled result once the die stops
-- moving, reporting it to Global.lua's OnWhoGoesFirstSettled so the turn
-- system can start counting turns from the winner.
--
-- Replaces the originally-inherited "Who goes first" die (scripts/objects/
-- Who goes first__ee33ec.lua), a custom-image die driven by an external PHP
-- service at 0rganics.org that is now dead -- confirmed live, it returns
-- HTTP 500 with an empty body, which made self.reload() wipe that object
-- out entirely the moment a roll was attempted. This uses one of this
-- repo's own plain stock dice instead, so there's no external dependency
-- left to break.

function onLoad()
    Wait.time(function() RelabelFaces() end, 1)
end

function onPlayerChangeColor(col)
    pcall(RelabelFaces)
end

function onPickedUp()
    pcall(RelabelFaces)
end

function onObjectRandomize(obj)
    if obj == self then
        pcall(RelabelFaces)
    end
end

local function GetScopedColors()
    local desc = self.getDescription() or ""
    if desc == "" then return nil end
    local allowed = {}
    for color in desc:gmatch("[^,]+") do
        allowed[color] = true
    end
    return allowed
end

-- Always identifies which role this die plays (Four Emperors vs a named
-- pair), so the table never ends up with 2-3 dice all displaying the same
-- generic name -- confirmed live this was a real point of confusion: once
-- rolled, every die's name collapsed to the same generic text with nothing
-- distinguishing them.
local function RoleLabel()
    local desc = self.getDescription() or ""
    if desc == "" then return "Four Emperors" end
    return desc:gsub(",", "/")
end

-- The die's own body tint always reflects what it can ACTUALLY roll right
-- now, rather than a fixed per-role color -- confirmed live a fixed color
-- was actively misleading (a Pair A die tinted blue when only White was
-- seated looked like "blue wins" when every face was really White). One
-- seated color in scope -> that exact color (a guaranteed win is honestly
-- shown as that color); more than one -> the average of them, which is
-- what actually told the 3 dice apart in the common all-seated case.
local function AverageTint(colors)
    if #colors == 0 then return {0.5, 0.5, 0.5} end
    local r, g, b = 0, 0, 0
    for _, color in ipairs(colors) do
        local rgb = stringColorToRGB(color)
        r = r + rgb.r
        g = g + rgb.g
        b = b + rgb.b
    end
    return {r / #colors, g / #colors, b / #colors}
end

-- Distributes this die's existing faces (whatever TTS's own stock die
-- already assigned -- confirmed live via getRotationValues(), no need to
-- build faces from scratch) as evenly as possible among the seated colors
-- in scope, relabeling each face's .value to a color string while keeping
-- its original .rotation untouched.
function RelabelFaces()
    local existing = self.getRotationValues()
    local faceCount = #existing
    if faceCount == 0 then return end

    local scoped = GetScopedColors()
    local allColors = {"Red","Orange","Yellow","Green","Teal","Blue","Purple","Pink","Brown","White"}
    local seated = {}
    for _, color in ipairs(allColors) do
        if Player[color].seated and (scoped == nil or scoped[color]) then
            table.insert(seated, color)
        end
    end
    self.setColorTint(AverageTint(seated))

    if #seated == 0 then
        local rotvals = {}
        for i, rv in ipairs(existing) do
            rotvals[i] = {value = "", rotation = rv.rotation}
        end
        self.setRotationValues(rotvals)
        self.setName("Who goes first? (" .. RoleLabel() .. ") - no one seated")
        return
    end

    local base = math.floor(faceCount / #seated)
    local extra = faceCount - base * #seated
    local rotvals = {}
    local faceIndex = 1
    for i, color in ipairs(seated) do
        local count = base + ((i <= extra) and 1 or 0)
        for _ = 1, count do
            if faceIndex > faceCount then break end
            rotvals[faceIndex] = {value = color, rotation = existing[faceIndex].rotation}
            faceIndex = faceIndex + 1
        end
    end
    -- base*#seated + extra always equals faceCount, so this shouldn't run,
    -- but repeats the last color rather than leaving a face unlabeled if
    -- the math above is ever off by one.
    while faceIndex <= faceCount do
        rotvals[faceIndex] = {value = seated[#seated], rotation = existing[faceIndex].rotation}
        faceIndex = faceIndex + 1
    end

    self.setRotationValues(rotvals)
    self.setName("Who goes first? (" .. RoleLabel() .. ")")
end

local pollGeneration = 0

-- Standard TTS pattern (same one the stock Die_6/Die_8 scripts this
-- replaces already used for their own floating-score popup): poll
-- self.resting, then read the settled face's label via getRotationValue().
-- The generation counter guards against an older poll (from a roll that
-- got re-rolled before settling) reporting a stale result after a newer
-- roll has already started.
local function BeginResultPoll()
    pollGeneration = pollGeneration + 1
    local myGeneration = pollGeneration
    Wait.condition(function()
        if pollGeneration ~= myGeneration then return end
        Global.call("OnWhoGoesFirstSettled", {dieGuid = self.getGUID(), result = self.getRotationValue()})
    end, function()
        return pollGeneration ~= myGeneration or self.resting
    end)
end

function onDrop(playerColor)
    BeginResultPoll()
end

function onRandomize(playerColor)
    BeginResultPoll()
end
