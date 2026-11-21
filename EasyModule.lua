-- One Piece TCG DON!! + Power Modifier
-- Simplified Tabletop Simulator module for Encoder v4.20+
--
-- Card data is stored independently:
--   donAttached       = number of DON!! attached to this card
--   powerMod          = temporary power adjustment (in increments of 1000)
--   displayPowerMod   = whether the two counters are visible
--
-- Left-click a counter to increase it. Right-click to decrease it.
-- The printed card power is never modified.

moduleVersion = 1.0
pID = "_OPTCG_DON_POWER"
valueID = "opOnePiece"

autoActivateModule = true
isRegistered = false
encVersion = 0

local function getEncoder()
    return Global.getVar("Encoder")
end

local function defaultCardData()
    return {
        donAttached = 0,
        powerMod = 0,
        displayPowerMod = false
    }
end

local function getCardData(card, encoder)
    local allData = encoder.call("APIobjGetPropData", {
        obj = card,
        propID = pID
    }) or {}

    local data = allData[valueID] or defaultCardData()

    -- Fill missing fields when loading data created by an older script.
    if data.donAttached == nil then data.donAttached = 0 end
    if data.powerMod == nil then data.powerMod = 0 end
    if data.displayPowerMod == nil then data.displayPowerMod = false end

    return allData, data
end

local function saveCardData(card, encoder, allData, data)
    allData[valueID] = data
    encoder.call("APIobjSetPropData", {
        obj = card,
        propID = pID,
        data = allData
    })
    encoder.call("APIrebuildButtons", {obj = card})
end

local function changeCardValue(card, field, amount)
    local encoder = getEncoder()
    if encoder == nil then return end

    local allData, data = getCardData(card, encoder)
    data[field] = (tonumber(data[field]) or 0) + amount

    -- DON!! cannot be negative. Power modifiers may be positive or negative.
    if field == "donAttached" then
        data[field] = math.max(0, data[field])
    end

    saveCardData(card, encoder, allData, data)
end

local function setCardValue(card, field, value)
    local encoder = getEncoder()
    if encoder == nil then return end

    local allData, data = getCardData(card, encoder)
    data[field] = value
    saveCardData(card, encoder, allData, data)
end

function DoNothing()
end

-- Counter button callbacks. TTS passes alt=true for right-click.
function ReceiveDonClick(card, playerColor, alt)
    changeCardValue(card, "donAttached", alt and -1 or 1)
end

function ReceivePowerClick(card, playerColor, alt)
    changeCardValue(card, "powerMod", alt and -1000 or 1000)
end

function ToggleDisplayPowerMod(card, playerColor, alt)
    local encoder = getEncoder()
    if encoder == nil then return end

    local allData, data = getCardData(card, encoder)
    data.displayPowerMod = not data.displayPowerMod
    saveCardData(card, encoder, allData, data)
end

-- Called by Encoder when it rebuilds a card's buttons.
-- Keep this lowercase name for compatibility with the original module API.
function createButtons(t)
    local encoder = getEncoder()
    if encoder == nil or t == nil or t.obj == nil then return end

    local card = t.obj
    local allData = encoder.call("APIobjGetPropData", {
        obj = card,
        propID = pID
    }) or {}
    local data = allData[valueID]
    if data == nil then return end

    local flip = encoder.call("APIgetFlip", {obj = card}) or 0
    local lightGrey = {177/255, 177/255, 177/255}
    local darkGrey = {40/255, 40/255, 40/255}

    card.createButton({
        click_function = "ToggleDisplayPowerMod",
        function_owner = self,
        label = "OP",
        tooltip = (data.displayPowerMod and "Hide" or "Show") .. " DON!! and power counters",
        font_size = 45,
        font_color = data.displayPowerMod and {1, 0.8, 0.4, 0.9} or {0.8, 0.8, 0.8, 0.8},
        height = 90,
        width = 90,
        color = data.displayPowerMod and {0, 0, 0, 0.9} or {0, 0, 0, 0.7},
        hover_color = {0, 0, 0, 1},
        rotation = {0, 0, 90 - 90 * flip},
        position = {-1.035 * flip, 0.35 * flip, -0.16}
    })

    if not data.displayPowerMod then return end

    local verticalOffset = 1.3315
    local donLabel = tostring(data.donAttached) .. " DON!!"
    local powerLabel = (data.powerMod >= 0 and "+" or "") .. tostring(data.powerMod)

    -- DON!! counter background and interactive label.
    card.createButton({
        click_function = "DoNothing",
        function_owner = self,
        height = 146,
        width = 246,
        color = lightGrey,
        position = {-0.52 * flip, 0.28 * flip, verticalOffset},
        rotation = {0, 0, -90 - 90 * flip}
    })
    card.createButton({
        label = donLabel,
        tooltip = "Left-click: +1 DON!!\nRight-click: -1 DON!!",
        click_function = "ReceiveDonClick",
        function_owner = self,
        position = {-0.52 * flip, 0.35 * flip, verticalOffset},
        height = 120,
        width = 220,
        color = darkGrey,
        font_size = 65,
        font_color = {1, 0.85, 0.3},
        rotation = {0, 0, 90 - 90 * flip}
    })

    -- Power modifier background and interactive label.
    card.createButton({
        click_function = "DoNothing",
        function_owner = self,
        height = 146,
        width = 306,
        color = lightGrey,
        position = {0.42 * flip, 0.28 * flip, verticalOffset},
        rotation = {0, 0, -90 - 90 * flip}
    })
    card.createButton({
        label = powerLabel,
        tooltip = "Left-click: +1000 power\nRight-click: -1000 power",
        click_function = "ReceivePowerClick",
        function_owner = self,
        position = {0.42 * flip, 0.35 * flip, verticalOffset},
        height = 120,
        width = 280,
        color = darkGrey,
        font_size = 75,
        font_color = {1, 1, 1},
        rotation = {0, 0, 90 - 90 * flip}
    })
end

function ModuleActivation(card, player)
    local encoder = getEncoder()
    if encoder ~= nil then
        encoder.call("APItoggleProperty", {obj = card, propID = pID})
    end
end

-- Automatically encode and enable the module when a card is dropped.
function TryTimedEncoding(card)
    if card == nil or card.tag ~= "Card" then return end
    if card.getVar("noencode") == true then return end

    local encoder = getEncoder()
    if encoder == nil then return end
    if encoder.call("APIpropertyExists", {propID = pID}) == false then return end

    if encoder.call("APIobjectExists", {obj = card}) == false then
        encoder.call("APIencodeObject", {obj = card})
    end

    if encoder.call("APIobjIsPropEnabled", {obj = card, propID = pID}) == false then
        encoder.call("APIobjEnableProp", {obj = card, propID = pID})

        local allData, data = getCardData(card, encoder)
        allData[valueID] = data
        encoder.call("APIobjSetPropData", {
            obj = card,
            propID = pID,
            data = allData
        })
        encoder.call("APIrebuildButtons", {obj = card})
    end
end

function onObjectDropped(playerColor, object)
    if autoActivateModule then
        TryTimedEncoding(object)
    end
end

-- Registration -------------------------------------------------------------

function RefreshEncoderVersion(encoder)
    local versionText = encoder.getVar("version") or ""
    encVersion = tonumber(versionText:match("%d+%.%d+")) or 0
end

function RegisterModule()
    local encoder = getEncoder()
    if encoder == nil then
        broadcastToAll("[OP TCG] Encoder not found. Install Encoder v4.20 or newer.")
        return
    end

    RefreshEncoderVersion(encoder)
    if encVersion < 4.2 then
        broadcastToAll("[OP TCG] Encoder v4.20 or newer is required.")
        return
    end

    local properties
    if encVersion < 4.4 then
        properties = {
            propID = pID,
            name = "One Piece TCG Counters",
            values = {valueID},
            funcOwner = self,
            callOnActivate = false,
            visible = false,
            activateFunc = ""
        }
    else
        properties = {
            propID = pID,
            name = "One Piece TCG Counters",
            values = {valueID},
            funcOwner = self,
            tags = "basic,counter",
            visible = false,
            visible_in_hand = 0,
            activateFunc = "ModuleActivation"
        }
    end

    encoder.call("APIregisterProperty", properties)
    encoder.call("APIregisterValue", {
        valueID = valueID,
        validType = "nil",
        desc = "One Piece TCG DON!! and power modifier data",
        default = defaultCardData()
    })

    isRegistered = true
    RefreshModuleChipButtons()
    broadcastToAll("[OP TCG] DON!! and power module registered.")
end

-- Keep compatibility with Encoder versions that call the lowercase name.
function registerModule()
    RegisterModule()
end

function TryAutoRegister()
    local encoder = getEncoder()
    if encoder ~= nil then
        RegisterModule()
    end
end

-- Module chip --------------------------------------------------------------

function ClearModuleChipButtons()
    local buttons = self.getButtons()
    for i = #buttons - 1, 0, -1 do
        self.removeButton(i)
    end
end

function CreateModuleChipButtons()
    local encoder = getEncoder()
    isRegistered = encoder ~= nil and
        encoder.call("APIpropertyExists", {propID = pID}) == true

    self.createButton({
        label = "ONE PIECE TCG",
        click_function = "DoNothing",
        function_owner = self,
        position = {0, 0.15, -0.18},
        height = 0,
        width = 0,
        font_size = 90,
        font_color = {1, 0.8, 0.4}
    })

    self.createButton({
        label = isRegistered and "REGISTERED" or "REGISTER MODULE",
        click_function = isRegistered and "DoNothing" or "RegisterModule",
        function_owner = self,
        position = {0, 0.15, 0.12},
        height = 70,
        width = 600,
        font_size = 65,
        color = {0.35, 0.12, 0.2},
        font_color = {1, 0.8, 0.4}
    })

    self.createButton({
        label = "AUTO " .. (autoActivateModule and "ON" or "OFF"),
        tooltip = "Automatically enable the module when cards are dropped",
        click_function = "ToggleAutoActivate",
        function_owner = self,
        position = {0, -0.15, 0},
        rotation = {180, 180, 0},
        width = 600,
        height = 80,
        font_size = 65,
        color = {0.35, 0.12, 0.2},
        font_color = {1, 0.8, 0.4}
    })
end

function RefreshModuleChipButtons()
    ClearModuleChipButtons()
    CreateModuleChipButtons()
end

function ToggleAutoActivate()
    autoActivateModule = not autoActivateModule
    RefreshModuleChipButtons()
end

-- Save/load ---------------------------------------------------------------

function onLoad(savedData)
    if savedData ~= nil and savedData ~= "" then
        local ok, saved = pcall(JSON.decode, savedData)
        if ok and type(saved) == "table" and saved.autoActivateModule ~= nil then
            autoActivateModule = saved.autoActivateModule
        end
    end

    CreateModuleChipButtons()

    Timer.destroy("opTcgModuleAutoRegister")
    Timer.create({
        identifier = "opTcgModuleAutoRegister",
        function_name = "TryAutoRegister",
        function_owner = self,
        delay = 2
    })
end

function onSave()
    return JSON.encode({
        autoActivateModule = autoActivateModule
    })
end
