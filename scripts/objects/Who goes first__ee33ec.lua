whoGoesFirstVersion = 3.14

function onLoad()
    -- Full whoGoesFirst() (not just a NameSides relabel) so a freshly
    -- cloned pair-scoped die (see GetScopedColors below -- Global.lua's
    -- EnsurePairDice clones this object for Split-table) immediately
    -- recomputes its own image/labels for its own scope, instead of
    -- showing whatever the original die last displayed. Delayed one
    -- second: a clone needs a moment to settle before self.reload() (which
    -- this can trigger) is safe to call on it.
    Wait.time(function() whoGoesFirst() end, 1)
end

function onPlayerChangeColor(col)
  pcall(function()
    whoGoesFirst()
  end)
end

function onPickedUp()
    pcall(function() whoGoesFirst() end)
end

function onObjectRandomize(obj)
    if obj == self then
        whoGoesFirst()
    end
end

-- Optional pair scoping: Description = "White,Blue" restricts this die to
-- rolling between just those two seats, regardless of who else is seated
-- at the table -- used for Split-table's two per-pair dice (Global.lua's
-- EnsurePairDice). An empty Description (the original die) rolls among
-- every seated player, unchanged from the inherited behavior -- that's
-- what Four Emperors uses.
local function GetScopedColors()
    local desc = self.getDescription() or ""
    if desc == "" then return nil end
    local allowed = {}
    for color in desc:gmatch("[^,]+") do
        allowed[color] = true
    end
    return allowed
end

local pollGeneration = 0

-- Auto-detects the roll's result once the die stops moving -- the standard
-- TTS pattern: poll self.resting, then read the settled face's label via
-- getRotationValue() -- and reports it to Global so the turn system can
-- start counting turns from the winner (see Global.lua's
-- OnWhoGoesFirstSettled). The generation counter guards against an older
-- poll (from a previous roll that got interrupted/re-rolled before
-- settling) reporting a stale result after a newer roll has started.
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

function whoGoesFirst()
    pcall(function()
      local scoped = GetScopedColors()
      local seated = ""
      local dietype = 1
      local colors = {"Red","Orange","Yellow","Green","Teal","Blue","Purple","Pink","Brown","White"}
      local shortc = {"r","o","y","g","t","b","p","i","n","w"}
      for k,color in pairs(colors) do
          if Player[color].seated and (scoped == nil or scoped[color]) then
              seated = seated .. shortc[k]
          end
      end

      if string.len(seated) > 0 then
          if string.len(seated) == 7 or string.len(seated) == 9 then
              seated = seated .. 'x'
          end

          if string.len(seated) == 1 or string.len(seated) == 2 or string.len(seated) == 3 or string.len(seated) == 6 then
              rep = math.floor(6/string.len(seated))
              dietype = 1
          elseif string.len(seated) == 4 or string.len(seated) == 7 or string.len(seated) == 8 then
              rep = math.floor(8/string.len(seated))
              dietype = 2
          elseif string.len(seated) == 5 or string.len(seated) == 9 or string.len(seated) == 10 then
              rep = math.floor(10/string.len(seated))
              dietype = 3
          end
          seated = string.rep(seated,rep)
      end

      local url = "0rganics.org/tts/wgf/2.php?v=" .. whoGoesFirstVersion .. "&c=" .. seated
      local arr = {image=url,type=dietype}
      local cur = self.getCustomObject()
      if cur.image != url then
          self.setCustomObject(arr)
          self.reload()
      else
          whoGoesFirstNameSides()
      end
    end)
end

function whoGoesFirstNameSides()
    local url = "0rganics.org/tts/wgf/2.php?v=" .. whoGoesFirstVersion .. "&c="
    local cur = self.getCustomObject()
    local rotvals = {}
    local hasResult = false

    if cur.image != url then
        local colors = {"Red","Orange","Yellow","Green","Teal","Blue","Purple","Pink","Brown","White"}
        local shortc = {"r","o","y","g","t","b","p","i","n","w"}
        local c = string.sub(cur.image,string.len(url))
        local playersides = {}
        local k = 1

        if string.len(c) > 0 then
            hasResult = true
            while k <= string.len(c) do
                if string.sub(c,k,k) == "x" then
                    table.insert(playersides,"Roll again to see who")
                else
                    for i=1,10 do
            			if string.sub(c,k,k) == shortc[i] then
                            -- Labeled with the seat COLOR itself, not the
                            -- Steam display name: Global.lua's
                            -- OnWhoGoesFirstSettled needs an unambiguous,
                            -- machine-readable result to start the turn
                            -- system from, and the color is exactly as
                            -- readable to players as a name since every
                            -- other table control is already color-keyed.
                            table.insert(playersides,colors[i])
            				break
            			end
            		end
                end
                k = k + 1
            end

            if cur.type == 1 then
                rotvals[1] = {value=playersides[1],rotation={-90,0,0}}
                rotvals[2] = {value=playersides[2],rotation={0,0,0}}
                rotvals[3] = {value=playersides[3],rotation={0,0,-90}}
                rotvals[4] = {value=playersides[4],rotation={0,0,90}}
                rotvals[5] = {value=playersides[5],rotation={0,0,-180}}
                rotvals[6] = {value=playersides[6],rotation={90,0,0}}
            elseif cur.type == 2 then
                rotvals[1] = {value=playersides[1],rotation={-33,0,90}}
                rotvals[2] = {value=playersides[2],rotation={-33,0,180}}
                rotvals[3] = {value=playersides[3],rotation={33,180,-180}}
                rotvals[4] = {value=playersides[4],rotation={33,180,90}}
                rotvals[5] = {value=playersides[5],rotation={33,180,-90}}
                rotvals[6] = {value=playersides[6],rotation={33,180,0}}
                rotvals[7] = {value=playersides[7],rotation={-33,0,0}}
                rotvals[8] = {value=playersides[8],rotation={-33,0,-90}}
            elseif cur.type == 3 then
                rotvals[1] = {value=playersides[1],rotation={-38,180,234}}
                rotvals[2] = {value=playersides[2],rotation={38,180,-233}}
                rotvals[3] = {value=playersides[3],rotation={-38,0,20}}
                rotvals[4] = {value=playersides[4],rotation={38,180,-17}}
                rotvals[5] = {value=playersides[5],rotation={-38,0,90}}
                rotvals[6] = {value=playersides[6],rotation={38,180,-161}}
                rotvals[7] = {value=playersides[7],rotation={-38,0,307}}
                rotvals[8] = {value=playersides[8],rotation={38,180,-304}}
                rotvals[9] = {value=playersides[9],rotation={-38,0,163}}
                rotvals[10] = {value=playersides[10],rotation={38,180,-90}}
            end
            self.setName("goes first!")
        else
            self.setName("Who goes first?")
        end
    else
        self.setName("Who goes first?")
    end
    self.setRotationValues(rotvals);
    if hasResult then
        BeginResultPoll()
    end
end
