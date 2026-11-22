-- One Piece TCG - DON!! and Power Modifier
-- Simplified Global-script adaptation of Easy Modules Unified.
-- Requires Encoder v4.20+.
--
-- Card data is stored independently:
--   donAttached     = attached DON!! count (cannot go below 0)
--   powerMod        = temporary power modifier (increments of 1000)
--   displayPowerMod = whether the DON!! / power buttons are visible

moduleVersion = 1.1

-- Tabletop Simulator object references supplied by the user.
local ENCODER_GUID = "02e062"
local MODULE_CHIP_GUID = "b93b40"

-- Keep the module namespace separate from the original MTG module.
pID = "_OPTCG_DON_POWER"
local valueID = "opOnePiece"

-- Second Encoder property: imported card stats (cost/power/counter/etc.),
-- populated by CardImporter.lua. Kept as its own property/value pair so it
-- can be enabled independently of the DON!!/Power counters.
statsPID = "_OPTCG_CARD_STATS"
local statsValueID = "opCardStats"

local autoActivateModule = true
local isRegistered = false
local encVersion = 0

-- Physical DON!! card assets (Steam Cloud URLs supplied by the user).
local DON_FRONT_URL = "https://steamusercontent-a.akamaihd.net/ugc/14669153559823385968/46792876A27844B60ED43F1E78F3196A55711F88/"
local DON_BACK_URL = "https://steamusercontent-a.akamaihd.net/ugc/15229813050283377381/69A44302DCD5AA0476D68F9982DEC5B88B7D0BDC/"
local DON_CARD_COUNT = 10
local DON_CARD_TAG = "OPTCG_DON"
local DON_DECK_TAG = "OPTCG_DON_DECK"
local DON_PLAYER_COLORS = {"White", "Red", "Blue", "Green"}
local donDeckGuids = {}
local donSetupInProgress = false
local donPendingDecks = 0

local function GetEncoder()
    local encoder = getObjectFromGUID(ENCODER_GUID)
    if encoder == nil then
        encoder = Global.getVar("Encoder")
    end
    return encoder
end

local function GetModuleChip()
    return getObjectFromGUID(MODULE_CHIP_GUID)
end

local function DefaultCardData()
    return {
        donAttached = 0,
        powerMod = 0,
        displayPowerMod = false
    }
end

local function DefaultCardStats()
    return {
        cardSetID = "",
        cardName = "",
        cost = 0,
        power = 0,
        counter = 0,
        color = "",
        cardType = "",
        attribute = "",
        life = 0,
        subTypes = "",
        rulesText = "",
        imageURL = "",
        displayStats = false
    }
end

local function GetCardData(card, encoder)
    local allData = encoder.call("APIobjGetPropData", {
        obj = card,
        propID = pID
    }) or {}

    local data = allData[valueID]
    if data == nil then
        data = DefaultCardData()
    end

    -- Fill any fields missing from data saved by an earlier version.
    if data.donAttached == nil then data.donAttached = 0 end
    if data.powerMod == nil then data.powerMod = 0 end
    if data.displayPowerMod == nil then data.displayPowerMod = false end

    return allData, data
end

local function SaveCardData(card, encoder, allData, data)
    allData[valueID] = data
    encoder.call("APIobjSetPropData", {
        obj = card,
        propID = pID,
        data = allData
    })
    encoder.call("APIrebuildButtons", {obj = card})
end

local function GetCardStats(card, encoder)
    local allData = encoder.call("APIobjGetPropData", {
        obj = card,
        propID = statsPID
    }) or {}

    local data = allData[statsValueID]
    if data == nil then
        data = DefaultCardStats()
    end

    return allData, data
end

local function SaveCardStats(card, encoder, allData, data)
    allData[statsValueID] = data
    encoder.call("APIobjSetPropData", {
        obj = card,
        propID = statsPID,
        data = allData
    })
    encoder.call("APIrebuildButtons", {obj = card})
end

local function ChangeCardValue(card, field, amount)
    local encoder = GetEncoder()
    if encoder == nil or card == nil then return end

    local allData, data = GetCardData(card, encoder)
    data[field] = (tonumber(data[field]) or 0) + amount

    if field == "donAttached" then
        data.donAttached = math.max(0, data.donAttached)
    end

    SaveCardData(card, encoder, allData, data)
end

-- -----------------------------------------------------------------------------
-- Global lifecycle and registration
-- -----------------------------------------------------------------------------

function onLoad(savedData)
    if savedData ~= nil and savedData ~= "" then
        local ok, decoded = pcall(function() return JSON.decode(savedData) end)
        if ok and type(decoded) == "table" then
            if decoded.autoActivateModule ~= nil then
                autoActivateModule = decoded.autoActivateModule
            end
            if type(decoded.donDeckGuids) == "table" then
                donDeckGuids = decoded.donDeckGuids
            end
        end
    end

    -- Encoder and the chip may finish loading after Global. Retry registration.
    Timer.destroy("onePieceModuleRegister")
    Timer.create({
        identifier = "onePieceModuleRegister",
        function_name = "TryRegisterModule",
        function_owner = Global,
        delay = 2
    })
end

function onSave()
    return JSON.encode({
        autoActivateModule = autoActivateModule,
        donDeckGuids = donDeckGuids
    })
end

function TryRegisterModule()
    RegisterModule()
end

function RegisterModule()
    local encoder = GetEncoder()
    if encoder == nil then
        print("[One Piece TCG] Encoder not found (expected GUID " .. ENCODER_GUID .. ").")
        RefreshModuleChipButtons()
        return
    end

    local versionText = encoder.getVar("version")
    if versionText == nil then
        print("[One Piece TCG] Could not read Encoder version.")
        return
    end

    encVersion = tonumber(tostring(versionText):match("%d+%.%d+")) or 0
    if encVersion < 4.2 then
        broadcastToAll("[One Piece TCG] Encoder v4.20 or newer is required.")
        return
    end

    local properties = {
        propID = pID,
        name = "One Piece TCG Counters",
        values = {valueID},
        funcOwner = Global,
        tags = "basic,counter",
        visible = false,
        visible_in_hand = 0,
        activateFunc = "ModuleActivation"
    }

    encoder.call("APIregisterProperty", properties)
    encoder.call("APIregisterValue", {
        valueID = valueID,
        validType = "nil",
        desc = "One Piece TCG DON!! and power modifier data",
        default = DefaultCardData()
    })

    encoder.call("APIregisterProperty", {
        propID = statsPID,
        name = "One Piece TCG Card Stats",
        values = {statsValueID},
        funcOwner = Global,
        tags = "basic,counter",
        visible = false,
        visible_in_hand = 0,
        activateFunc = "StatsModuleActivation"
    })
    encoder.call("APIregisterValue", {
        valueID = statsValueID,
        validType = "nil",
        desc = "One Piece TCG imported card stats",
        default = DefaultCardStats()
    })

    isRegistered = true
    RefreshModuleChipButtons()
    print("[One Piece TCG] Module registered with Encoder v" .. tostring(encVersion) .. ".")
end

-- Compatibility entry point used by some Encoder/module setups.
function registerModule()
    RegisterModule()
end

function ModuleActivation(card, player)
    local encoder = GetEncoder()
    if encoder ~= nil and card ~= nil then
        encoder.call("APItoggleProperty", {obj = card, propID = pID})
    end
end

function StatsModuleActivation(card, player)
    local encoder = GetEncoder()
    if encoder ~= nil and card ~= nil then
        encoder.call("APItoggleProperty", {obj = card, propID = statsPID})
    end
end

-- -----------------------------------------------------------------------------
-- Module chip controls. These are created on the chip object, not on Global.
-- -----------------------------------------------------------------------------

function DoNothing()
end

function ToggleAutoActivate()
    autoActivateModule = not autoActivateModule
    RefreshModuleChipButtons()
end

function ClearModuleChipButtons()
    local chip = GetModuleChip()
    if chip == nil then
        print("[One Piece TCG] Module chip not found (expected GUID " .. MODULE_CHIP_GUID .. ").")
        return
    end

    local buttons = chip.getButtons() or {}
    for index = #buttons - 1, 0, -1 do
        chip.removeButton(index)
    end
end

function CreateModuleChipButtons()
    local chip = GetModuleChip()
    if chip == nil then
        print("[One Piece TCG] Cannot create chip buttons; chip GUID " .. MODULE_CHIP_GUID .. " was not found.")
        return
    end

    local encoder = GetEncoder()
    isRegistered = encoder ~= nil and encoder.call("APIpropertyExists", {propID = pID}) == true

    chip.createButton({
        label = "ONE PIECE TCG",
        click_function = "DoNothing",
        function_owner = Global,
        position = {0, 0.15, -0.16},
        height = 0,
        width = 0,
        font_size = 95,
        font_color = {1, 0.72, 0.25}
    })

    chip.createButton({
        label = "DON!! + POWER",
        click_function = "DoNothing",
        function_owner = Global,
        position = {0, 0.15, 0.08},
        height = 0,
        width = 0,
        font_size = 55,
        font_color = {0.85, 0.85, 0.85}
    })

    chip.createButton({
        label = isRegistered and "REGISTERED" or "REGISTER MODULE",
        click_function = isRegistered and "DoNothing" or "RegisterModule",
        function_owner = Global,
        position = {0, 0.15, 0.32},
        height = 65,
        width = 570,
        font_size = 55,
        color = isRegistered and {0.12, 0.48, 0.22} or {0.8, 0.42, 0.08},
        font_color = {1, 1, 1}
    })

    chip.createButton({
        label = "AUTO-ACTIVATE: " .. (autoActivateModule and "ON" or "OFF"),
        tooltip = "When enabled, cards dropped on the table are automatically encoded and this module is enabled.",
        click_function = "ToggleAutoActivate",
        function_owner = Global,
        position = {0, -0.15, 0},
        rotation = {180, 180, 0},
        height = 75,
        width = 650,
        font_size = 48,
        color = autoActivateModule and {0.12, 0.48, 0.22} or {0.35, 0.35, 0.35},
        font_color = {1, 1, 1}
    })

    chip.createButton({
        label = "CREATE 4 DON!! DECKS",
        tooltip = "Creates one 10-card DON!! deck for each TTS seat. Existing decks are not duplicated.",
        click_function = "CreateDonDecks",
        function_owner = Global,
        position = {0, -0.15, 0.30},
        rotation = {180, 180, 0},
        height = 75,
        width = 650,
        font_size = 48,
        color = {0.12, 0.32, 0.58},
        font_color = {1, 1, 1}
    })
end

function RefreshModuleChipButtons()
    ClearModuleChipButtons()
    CreateModuleChipButtons()
end

-- -----------------------------------------------------------------------------
-- Physical DON!! decks
-- -----------------------------------------------------------------------------

local function VectorComponents(v)
    if v == nil then return 0, 0, 0 end
    return v.x or v[1] or 0, v.y or v[2] or 0, v.z or v[3] or 0
end

local function AddScaledVector(position, direction, distance)
    local px, py, pz = VectorComponents(position)
    local dx, dy, dz = VectorComponents(direction)
    return {px + dx * distance, py + dy * distance, pz + dz * distance}
end

local function GetDonAreaPositions(playerColor)
    local player = Player[playerColor]
    if player == nil then return nil end

    local hand = player.getHandTransform(1)
    if hand == nil or hand.position == nil then return nil end

    -- Hand forward points toward the table. The row is laid out left-to-right
    -- from that player's perspective, just in front of their hand.
    local rowCenter = AddScaledVector(hand.position, hand.forward, 2.6)
    return {
        deck = AddScaledVector(rowCenter, hand.right, -3.0),
        field = rowCenter,
        trash = AddScaledVector(rowCenter, hand.right, 3.0),
        rotation = hand.rotation or {0, 0, 0}
    }
end

local function ExistingDonDeck(playerColor)
    local guid = donDeckGuids[playerColor]
    if guid == nil then return nil end
    local deck = getObjectFromGUID(guid)
    if deck ~= nil then return deck end
    donDeckGuids[playerColor] = nil
    return nil
end

local function FinishDonDeck(playerColor, cards, position)
    local grouped = group(cards) or {}
    local deck = grouped[1]
    if deck == nil then
        broadcastToAll("[One Piece TCG] Could not group DON!! cards for " .. playerColor .. ".")
        donPendingDecks = math.max(0, donPendingDecks - 1)
        if donPendingDecks == 0 then donSetupInProgress = false end
        return
    end

    deck.setName(playerColor .. " DON!! Deck")
    deck.setDescription("10 physical DON!! cards owned by " .. playerColor .. ".")
    deck.addTag(DON_DECK_TAG)
    deck.setPositionSmooth(position, false, true)
    donDeckGuids[playerColor] = deck.getGUID()
    print("[One Piece TCG] Created " .. playerColor .. " DON!! deck (" .. deck.getGUID() .. ").")
    donPendingDecks = math.max(0, donPendingDecks - 1)
    if donPendingDecks == 0 then
        donSetupInProgress = false
        broadcastToAll("[One Piece TCG] Four-seat DON!! deck setup complete.")
    end
end

local function CreateOneDonDeck(playerColor)
    local existing = ExistingDonDeck(playerColor)
    if existing ~= nil then
        print("[One Piece TCG] " .. playerColor .. " DON!! deck already exists; skipping.")
        return true
    end

    local area = GetDonAreaPositions(playerColor)
    if area == nil then
        broadcastToAll("[One Piece TCG] Could not find the hand transform for " .. playerColor .. ".")
        return false
    end
    local position = area.deck
    local rotation = area.rotation

    donPendingDecks = donPendingDecks + 1
    local spawnedCards = {}
    local completed = 0
    local ownerColor = playerColor
    for cardIndex = 1, DON_CARD_COUNT do
        local cardPosition = {
            position[1] + (cardIndex - 1) * 0.025,
            position[2] + 1.5 + (cardIndex - 1) * 0.015,
            position[3]
        }
        spawnObject({
            type = "CardCustom",
            position = cardPosition,
            rotation = rotation,
            sound = false,
            callback_function = function(card)
                if card == nil then return end
                card.setCustomObject({face = DON_FRONT_URL, back = DON_BACK_URL})
                card.setName("DON!!")
                card.setDescription("Physical DON!! resource card")
                card.setGMNotes("OPTCG_DON_OWNER=" .. ownerColor)
                card.addTag(DON_CARD_TAG)
                table.insert(spawnedCards, card)
                completed = completed + 1

                if completed == DON_CARD_COUNT then
                    FinishDonDeck(ownerColor, spawnedCards, position)
                end
            end
        })
    end
    return true
end

function CreateDonDecks()
    if donSetupInProgress then
        broadcastToAll("[One Piece TCG] DON!! deck creation is already running.")
        return
    end

    donSetupInProgress = true
    donPendingDecks = 0
    for _, playerColor in ipairs(DON_PLAYER_COLORS) do
        CreateOneDonDeck(playerColor)
    end
    if donPendingDecks == 0 then
        donSetupInProgress = false
        broadcastToAll("[One Piece TCG] All four DON!! decks already exist or could not be created.")
    else
        broadcastToAll("[One Piece TCG] Creating DON!! decks for all four seats...")
    end
end

function GetDonOwner(card)
    if card == nil or card.tag ~= "Card" then return nil end
    local notes = card.getGMNotes() or ""
    return notes:match("OPTCG_DON_OWNER=(%w+)")
end

-- -----------------------------------------------------------------------------
-- Card buttons created by Encoder
-- -----------------------------------------------------------------------------

local function CreateDonPowerButtons(obj, encoder, flip, lightGrey, darkGrey)
    local allData = encoder.call("APIobjGetPropData", {obj = obj, propID = pID}) or {}
    local data = allData[valueID]
    if data == nil then return end

    if data.donAttached == nil then data.donAttached = 0 end
    if data.powerMod == nil then data.powerMod = 0 end
    if data.displayPowerMod == nil then data.displayPowerMod = false end

    obj.createButton({
        click_function = "ToggleDisplayPowerMod",
        function_owner = Global,
        label = "PWR",
        font_size = 45,
        font_color = data.displayPowerMod and {1, 0.8, 0.4, 0.9} or {0.8, 0.8, 0.8, 0.8},
        tooltip = (data.displayPowerMod and "Hide" or "Show") .. " Power and DON!! counters",
        height = 90,
        width = 90,
        color = data.displayPowerMod and {0, 0, 0, 0.9} or {0, 0, 0, 0.7},
        hover_color = {0, 0, 0, 1},
        rotation = {0, 0, 90 - 90 * flip},
        position = {-1.035 * flip, 0.35 * flip, -0.16}
    })

    if not data.displayPowerMod then return end

    local statHeight = 1.3315
    local donLabel = tostring(data.donAttached) .. " DON"
    local powerLabel = (data.powerMod >= 0 and "+" or "") .. tostring(data.powerMod)

    obj.createButton({
        click_function = "DoNothing",
        function_owner = Global,
        height = 146,
        width = 246,
        color = lightGrey,
        position = {-0.52 * flip, 0.28 * flip, statHeight},
        rotation = {0, 0, -90 - 90 * flip}
    })
    obj.createButton({
        label = donLabel,
        tooltip = "Left-click: +1 DON!!\nRight-click: -1 DON!!",
        click_function = "ReceiveDonClick",
        function_owner = Global,
        position = {-0.52 * flip, 0.35 * flip, statHeight},
        height = 120,
        width = 220,
        color = darkGrey,
        font_size = 65,
        font_color = {1, 0.85, 0.3},
        rotation = {0, 0, 90 - 90 * flip}
    })

    obj.createButton({
        click_function = "DoNothing",
        function_owner = Global,
        height = 146,
        width = 306,
        color = lightGrey,
        position = {0.42 * flip, 0.28 * flip, statHeight},
        rotation = {0, 0, -90 - 90 * flip}
    })
    obj.createButton({
        label = powerLabel,
        tooltip = "Left-click: +1000 Power\nRight-click: -1000 Power",
        click_function = "ReceivePowerClick",
        function_owner = Global,
        position = {0.42 * flip, 0.35 * flip, statHeight},
        height = 120,
        width = 280,
        color = darkGrey,
        font_size = 75,
        font_color = {1, 1, 1},
        rotation = {0, 0, 90 - 90 * flip}
    })
end

-- NOTE: panel positions below are a first pass, not yet checked against a
-- real card in TTS. Expect to nudge the row heights (statsRow1/statsRow2/
-- rulesRow) and widths once this is visible in-game (see the plan's
-- verification step 4) -- nothing about the data flow depends on them.
local function CreateCardStatsButtons(obj, encoder, flip, lightGrey, darkGrey)
    local _, data = GetCardStats(obj, encoder)

    obj.createButton({
        click_function = "ToggleDisplayCardStats",
        function_owner = Global,
        label = "STATS",
        font_size = 32,
        font_color = data.displayStats and {1, 0.8, 0.4, 0.9} or {0.8, 0.8, 0.8, 0.8},
        tooltip = (data.displayStats and "Hide" or "Show") .. " imported card stats",
        height = 90,
        width = 90,
        color = data.displayStats and {0, 0, 0, 0.9} or {0, 0, 0, 0.7},
        hover_color = {0, 0, 0, 1},
        rotation = {0, 0, 90 - 90 * flip},
        position = {1.035 * flip, 0.35 * flip, -0.16}
    })

    if not data.displayStats then return end

    local bgY = 0.28 * flip
    local labelY = 0.35 * flip
    local statsRow1 = 1.75
    local statsRow2 = 2.15
    local rulesRow = 2.6

    local function StatPanel(z, x, width, label)
        obj.createButton({
            click_function = "DoNothing",
            function_owner = Global,
            height = 110,
            width = width,
            color = lightGrey,
            position = {x * flip, bgY, z},
            rotation = {0, 0, -90 - 90 * flip}
        })
        obj.createButton({
            click_function = "DoNothing",
            function_owner = Global,
            label = label,
            position = {x * flip, labelY, z},
            height = 90,
            width = width - 20,
            color = darkGrey,
            font_size = 36,
            font_color = {1, 1, 1},
            rotation = {0, 0, 90 - 90 * flip}
        })
    end

    local counterLabel = (data.counter ~= nil and data.counter ~= 0) and ("+" .. tostring(data.counter)) or "-"
    StatPanel(statsRow1, -0.8, 230, "Cost " .. tostring(data.cost))
    StatPanel(statsRow1, -0.3, 230, "Pwr " .. tostring(data.power))
    StatPanel(statsRow1, 0.3, 230, "Ctr " .. counterLabel)
    StatPanel(statsRow1, 0.8, 230, data.color ~= "" and data.color or "-")

    StatPanel(statsRow2, data.cardType == "Leader" and -0.6 or -0.3, 300, data.cardType ~= "" and data.cardType or "-")
    StatPanel(statsRow2, data.cardType == "Leader" and 0.0 or 0.3, 300, data.attribute ~= "" and data.attribute or "-")
    if data.cardType == "Leader" then
        StatPanel(statsRow2, 0.6, 300, "Life " .. tostring(data.life))
    end

    if data.rulesText ~= nil and data.rulesText ~= "" then
        local text = data.rulesText
        if #text > 220 then
            text = text:sub(1, 217) .. "..."
        end
        local _, fsize = encoder.call("APIformatButton", {
            str = text,
            font_size = 40,
            max_len = 420,
            xJust = "left",
            yJust = "top"
        })
        obj.createButton({
            click_function = "DoNothing",
            function_owner = Global,
            label = text,
            height = 260,
            width = 700,
            color = darkGrey,
            font_size = fsize or 28,
            font_color = {1, 1, 1},
            position = {0, labelY, rulesRow},
            rotation = {0, 0, 90 - 90 * flip}
        })
    end
end

function createButtons(t)
    local encoder = GetEncoder()
    if encoder == nil or t == nil or t.obj == nil then return end

    t.obj.clearButtons()

    local flip = encoder.call("APIgetFlip", {obj = t.obj}) or 0
    local lightGrey = {177/255, 177/255, 177/255}
    local darkGrey = {40/255, 40/255, 40/255}

    if encoder.call("APIobjIsPropEnabled", {obj = t.obj, propID = pID}) == true then
        CreateDonPowerButtons(t.obj, encoder, flip, lightGrey, darkGrey)
    end

    if encoder.call("APIobjIsPropEnabled", {obj = t.obj, propID = statsPID}) == true then
        CreateCardStatsButtons(t.obj, encoder, flip, lightGrey, darkGrey)
    end
end

function ReceiveDonClick(card, playerColor, alt)
    ChangeCardValue(card, "donAttached", alt and -1 or 1)
end

function ReceivePowerClick(card, playerColor, alt)
    ChangeCardValue(card, "powerMod", alt and -1000 or 1000)
end

function ToggleDisplayPowerMod(card, playerColor, alt)
    local encoder = GetEncoder()
    if encoder == nil or card == nil then return end

    local allData, data = GetCardData(card, encoder)
    data.displayPowerMod = not data.displayPowerMod
    SaveCardData(card, encoder, allData, data)
end

function ToggleDisplayCardStats(card, playerColor, alt)
    local encoder = GetEncoder()
    if encoder == nil or card == nil then return end

    local allData, data = GetCardStats(card, encoder)
    data.displayStats = not data.displayStats
    SaveCardStats(card, encoder, allData, data)
end

-- -----------------------------------------------------------------------------
-- Automatic activation (no MTG card parsing)
-- -----------------------------------------------------------------------------

function onObjectDropped(playerColor, object)
    TryActivateDonPowerModule(object)
    TryActivateCardStatsFromGMNotes(object)
end

function TryActivateDonPowerModule(object)
    if not autoActivateModule or object == nil or object.tag ~= "Card" then return end
    if object.getVar("noencode") == true then return end

    local encoder = GetEncoder()
    if encoder == nil then return end

    if encoder.call("APIobjectExists", {obj = object}) == false then
        encoder.call("APIencodeObject", {obj = object})
    end

    if encoder.call("APIpropertyExists", {propID = pID}) ~= true then return end
    if encoder.call("APIobjIsPropEnabled", {obj = object, propID = pID}) ~= true then
        encoder.call("APIobjEnableProp", {obj = object, propID = pID})
        local allData, data = GetCardData(object, encoder)
        allData[valueID] = data
        encoder.call("APIobjSetPropData", {obj = object, propID = pID, data = allData})
        encoder.call("APIrebuildButtons", {obj = object})
    end
end

-- Unlike the DON!!/Power module, this runs regardless of autoActivateModule:
-- a card carrying imported stats should always pick them up on first drop.
-- Cards spawned by CardImporter.lua are still packed inside a Deck object at
-- spawn time, which can't be called into directly -- GMNotes is the only
-- place to stash the data until the card becomes a standalone Object, which
-- happens exactly when it's drawn/dropped onto the table.
function TryActivateCardStatsFromGMNotes(object)
    if object == nil or object.tag ~= "Card" then return end

    local notes = object.getGMNotes() or ""
    local payload = notes:match("^OPTCG_CARD=(.+)$")
    if payload == nil then return end

    local encoder = GetEncoder()
    if encoder == nil then return end

    if encoder.call("APIobjIsPropEnabled", {obj = object, propID = statsPID}) == true then return end

    local ok, decoded = pcall(function() return JSON.decode(payload) end)
    if not ok or type(decoded) ~= "table" then
        print("[One Piece TCG] Could not decode card stats from GMNotes.")
        return
    end

    if encoder.call("APIobjectExists", {obj = object}) == false then
        encoder.call("APIencodeObject", {obj = object})
    end

    encoder.call("APIobjEnableProp", {obj = object, propID = statsPID})
    local allData, data = GetCardStats(object, encoder)
    for field, value in pairs(decoded) do
        data[field] = value
    end
    SaveCardStats(object, encoder, allData, data)
end
