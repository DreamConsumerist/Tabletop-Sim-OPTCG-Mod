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
-- This table's actual 4 seats (confirmed live via Player.getAvailableColors()).
-- "Green" is not a seat here; the correct fourth color is "Yellow".
local TABLE_SEAT_COLORS = {"White", "Red", "Yellow", "Blue"}
local donDeckGuids = {}
local donSetupInProgress = false
local donPendingDecks = 0

-- Ruleset-agnostic card zone layout (Deck/Trash/Life/Leader/Character/Stage/
-- DON!! zones). Same layout for every seat regardless of game mode
-- (split-table vs. Four Emperors) -- see the "Table zone layout" section
-- near the end of this file.
local zoneGuids = {}
local zoneSetupInProgress = false
local zonePendingZones = 0

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
            if type(decoded.zoneGuids) == "table" then
                zoneGuids = decoded.zoneGuids
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

    -- Self-healing: the 16 inherited per-seat action buttons live on their
    -- target objects, not Global, so they survive a script reload on their
    -- own -- but a full table/game reload (e.g. loading an older save) can
    -- wipe them, and when that happens they stay silently dead until
    -- recreated (confirmed live: button count drops to 0 with no error).
    -- Recreating them every time Global loads means that never needs a
    -- manual fix again.
    Timer.destroy("onePieceSeatButtons")
    Timer.create({
        identifier = "onePieceSeatButtons",
        function_name = "CreateSeatActionButtons",
        function_owner = Global,
        delay = 2
    })

    Timer.destroy("onePieceMulliganButtons")
    Timer.create({
        identifier = "onePieceMulliganButtons",
        function_name = "CreateMulliganButtons",
        function_owner = Global,
        delay = 2
    })
end

function onSave()
    return JSON.encode({
        autoActivateModule = autoActivateModule,
        donDeckGuids = donDeckGuids,
        zoneGuids = zoneGuids
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

    chip.createButton({
        label = "CREATE TABLE ZONES",
        tooltip = "Creates the Deck/Trash/Life/Leader/Character/Stage/DON!! zone layout for each TTS seat. Existing zones are not duplicated.",
        click_function = "CreateTableZones",
        function_owner = Global,
        position = {0, -0.15, 0.56},
        rotation = {180, 180, 0},
        height = 75,
        width = 650,
        font_size = 48,
        color = {0.15, 0.5, 0.3},
        font_color = {1, 1, 1}
    })

    chip.createButton({
        label = "CLEAR TABLE ZONES",
        tooltip = "Deletes every OPTCG table zone. Use this to re-run CREATE TABLE ZONES after tweaking the layout.",
        click_function = "ClearTableZones",
        function_owner = Global,
        position = {0, -0.15, 0.82},
        rotation = {180, 180, 0},
        height = 75,
        width = 650,
        font_size = 48,
        color = {0.55, 0.18, 0.18},
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
    for _, playerColor in ipairs(TABLE_SEAT_COLORS) do
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
-- Table zone layout
-- -----------------------------------------------------------------------------
-- One fixed set of scripting-trigger zones per seat, laid out relative to
-- that seat's hand transform the same way GetDonAreaPositions works above.
-- This layout is deliberately ruleset-agnostic: it is identical for
-- split-table and Four Emperors, carries no rule enforcement of its own, and
-- exists only as named/tagged regions (plus the GetPlayerZone lookup) for
-- future rule scripting -- life reveal, DON!! cost tracking, attack
-- targeting, etc. -- to build on.

-- A resting card's center sits at ~0.98 off the table surface (measured
-- live); the recorded zone transforms below sit at y=1 for a small buffer
-- above that.
local ZONE_HEIGHT = 5

-- Scripting-trigger zones are invisible to players during normal play by TTS
-- design (confirmed against TTS's own docs -- only the host's Gizmo Tool
-- shows their outline).

-- Per-zone-key metadata shared across every seat: display label, and any
-- zone-type behavior (currently just Life's fan-stacking/face-down forcing).
local ZONE_KEYS = {"trash", "deck", "donDeck", "donArea", "characterArea", "stageArea", "life", "leaderArea"}
local ZONE_META = {
    trash         = {label = "Trash"},
    deck          = {label = "Deck"},
    donDeck       = {label = "DON!! Deck"},
    donArea       = {label = "DON!! Area"},
    characterArea = {label = "Character Area"},
    stageArea     = {label = "Stage Area"},
    life          = {label = "Life", fanStep = {forward = 0.5, up = 0.25}, faceDown = true},
    leaderArea    = {label = "Leader Area"},
}

-- Absolute per-seat world position + footprint (world units), captured
-- directly from the live table after manually placing every zone for every
-- seat individually. This replaces an earlier shared forward/right-from-
-- one-seat formula entirely -- confirmed live that approach was
-- mathematically self-consistent (every seat's zone landed exactly where
-- the formula said it should) yet still didn't match the actual table,
-- which isn't a simple mirror/rotation of one seat's layout onto the
-- others. Rotation isn't stored here since it's seat-intrinsic --
-- CreateOneZone reads it fresh from that seat's own hand transform.
local ZONE_TRANSFORMS = {
    White = {
        trash         = {pos = {40.9237, 1, -22.1813}, width = 4.3000,  length = 6.1500},
        deck          = {pos = {40.8182, 1, -15.6064}, width = 4.3000,  length = 6.1500},
        donDeck       = {pos = {4.0004,  1, -22.3921}, width = 4.3000,  length = 6.1500},
        donArea       = {pos = {22.8735, 1, -22.7750}, width = 30.4080, length = 6.1500},
        characterArea = {pos = {26.1053, 1, -8.6145},  width = 35.1248, length = 6.1500},
        stageArea     = {pos = {29.7447, 1, -15.6913}, width = 4.3000,  length = 6.1500},
        life          = {pos = {4.1961,  1, -11.8757}, width = 6.9644,  length = 13.3758},
        leaderArea    = {pos = {23.2968, 1, -15.5890}, width = 4.3000,  length = 6.1500},
    },
    Red = {
        trash         = {pos = {-3.7153,  1, -22.1813}, width = 4.3000,  length = 6.1500},
        deck          = {pos = {-3.8747,  1, -15.6064}, width = 4.3000,  length = 6.1500},
        donDeck       = {pos = {-40.6324, 1, -22.3921}, width = 4.3000,  length = 6.1500},
        donArea       = {pos = {-21.9476, 1, -22.7750}, width = 30.4080, length = 6.1500},
        characterArea = {pos = {-18.8921, 1, -8.6145},  width = 35.1248, length = 6.1500},
        stageArea     = {pos = {-14.8335, 1, -15.6913}, width = 4.3000,  length = 6.1500},
        life          = {pos = {-40.3474, 1, -11.8757}, width = 6.9644,  length = 13.3758},
        leaderArea    = {pos = {-21.3310, 1, -15.5890}, width = 4.3000,  length = 6.1500},
    },
    Yellow = {
        trash         = {pos = {-40.9237, 1, 22.1813},  width = 4.3000,  length = 6.1500},
        deck          = {pos = {-40.8182, 1, 15.6064},  width = 4.3000,  length = 6.1500},
        donDeck       = {pos = {-4.0004,  1, 22.3921},  width = 4.3000,  length = 6.1500},
        donArea       = {pos = {-22.8735, 1, 22.7750},  width = 30.4080, length = 6.1500},
        characterArea = {pos = {-26.1053, 1, 8.6145},   width = 35.1248, length = 6.1500},
        stageArea     = {pos = {-29.7447, 1, 15.6913},  width = 4.3000,  length = 6.1500},
        life          = {pos = {-4.1961,  1, 11.8757},  width = 6.9644,  length = 13.3758},
        leaderArea    = {pos = {-23.2968, 1, 15.5890},  width = 4.3000,  length = 6.1500},
    },
    Blue = {
        trash         = {pos = {3.6574,  1, 22.1241}, width = 4.3000,  length = 6.1500},
        deck          = {pos = {3.6967,  1, 15.5494}, width = 4.3000,  length = 6.1500},
        donDeck       = {pos = {40.5272, 1, 22.4637}, width = 4.3000,  length = 6.1500},
        donArea       = {pos = {21.6955, 1, 22.3145}, width = 30.4080, length = 6.1500},
        characterArea = {pos = {18.7517, 1, 8.4668},  width = 35.1248, length = 6.1500},
        stageArea     = {pos = {14.6267, 1, 15.5384}, width = 4.3000,  length = 6.1500},
        life          = {pos = {40.4501, 1, 11.9470}, width = 6.9644,  length = 13.3758},
        leaderArea    = {pos = {21.2612, 1, 15.5933}, width = 4.3000,  length = 6.1500},
    },
}

-- Every zone's GMNotes are "OPTCG_ZONE=<key>;OWNER=<color>".
local function ParseZoneNotes(obj)
    local notes = obj.getGMNotes() or ""
    return notes:match("OPTCG_ZONE=([%w]+);OWNER=(%w+)")
end

local function ExistingZone(playerColor, key)
    local seatZones = zoneGuids[playerColor]
    if seatZones == nil then return nil end
    local guid = seatZones[key]
    if guid == nil then return nil end
    local zone = getObjectFromGUID(guid)
    if zone ~= nil then return zone end
    seatZones[key] = nil
    return nil
end

local function CreateOneZone(playerColor, hand, key)
    if ExistingZone(playerColor, key) ~= nil then return end

    local seatTransforms = ZONE_TRANSFORMS[playerColor]
    local transform = seatTransforms and seatTransforms[key]
    local meta = ZONE_META[key]
    if transform == nil or meta == nil then return end

    zoneGuids[playerColor] = zoneGuids[playerColor] or {}
    zonePendingZones = zonePendingZones + 1
    local ownerColor = playerColor

    spawnObject({
        type = "ScriptingTrigger",
        position = transform.pos,
        rotation = hand.rotation or {0, 0, 0},
        scale = {transform.width, ZONE_HEIGHT, transform.length},
        sound = false,
        callback_function = function(zone)
            if zone == nil then
                zonePendingZones = math.max(0, zonePendingZones - 1)
                if zonePendingZones == 0 then zoneSetupInProgress = false end
                return
            end

            -- Deliberately no addTag() here: a zone's own custom tags gate
            -- which objects count as "inside" it for getObjects()/
            -- onObjectEnterZone (confirmed live -- an untagged card registers
            -- as 0 objects in a tagged zone, compatible tags required). Plain
            -- game cards carry no custom tags, so the zone itself must not
            -- carry any either, or it stops detecting them entirely.
            zone.setName(ownerColor .. " " .. meta.label)
            zone.setGMNotes("OPTCG_ZONE=" .. key .. ";OWNER=" .. ownerColor)
            zoneGuids[ownerColor][key] = zone.getGUID()

            zonePendingZones = math.max(0, zonePendingZones - 1)
            if zonePendingZones == 0 then
                zoneSetupInProgress = false
                broadcastToAll("[One Piece TCG] Table zone layout complete.")
            end
        end
    })
end

-- Zones with a fanStep (currently just Life) auto-arrange cards dropped into
-- them into a visibly-countable staggered pile instead of letting them land
-- wherever physics puts them, matching how a physical Life pile is read at a
-- glance. Only reacts to standalone Card objects; a Deck entering is left
-- alone (dropping a handful of life cards in one motion is the normal case
-- this is built for).
local function FanStackCardInZone(zone, card, def)
    local _, ownerColor = ParseZoneNotes(zone)
    local hand = ownerColor and Player[ownerColor] and Player[ownerColor].getHandTransform(1)
    if hand == nil then return end

    local others = 0
    for _, occupant in ipairs(zone.getObjects()) do
        if occupant.tag == "Card" and occupant.getGUID() ~= card.getGUID() then
            others = others + 1
        end
    end

    local position = AddScaledVector(zone.getPosition(), hand.forward, def.fanStep.forward * others)
    local _, baseY = VectorComponents(position)
    position[2] = baseY + def.fanStep.up * others

    -- rotation.z is the face-up(0)/face-down(180) flip for a resting card
    -- (confirmed live: is_face_down reads true at z=180). x is left as-is
    -- (flat-resting cards sit at x=0) and only yaw (y) and, if requested,
    -- the face are forced.
    local cardX, _, cardZ = VectorComponents(card.getRotation())
    local _, handYaw = VectorComponents(hand.rotation)
    local faceZ = def.faceDown and 180 or cardZ

    card.setPosition(position)
    card.setRotation({cardX, handYaw, faceZ})
end

function onObjectEnterZone(zone, object)
    if object == nil or object.tag ~= "Card" then return end

    local key = ParseZoneNotes(zone)
    local meta = key and ZONE_META[key]
    if meta == nil or meta.fanStep == nil then return end

    FanStackCardInZone(zone, object, meta)
end

function CreateTableZones()
    if zoneSetupInProgress then
        broadcastToAll("[One Piece TCG] Table zone creation is already running.")
        return
    end

    zoneSetupInProgress = true
    zonePendingZones = 0
    for _, playerColor in ipairs(TABLE_SEAT_COLORS) do
        local player = Player[playerColor]
        local hand = player and player.getHandTransform(1)
        if hand == nil then
            broadcastToAll("[One Piece TCG] Could not find the hand transform for " .. playerColor .. ".")
        else
            for _, key in ipairs(ZONE_KEYS) do
                CreateOneZone(playerColor, hand, key)
            end
        end
    end

    if zonePendingZones == 0 then
        zoneSetupInProgress = false
        broadcastToAll("[One Piece TCG] All table zones already exist or could not be created.")
    else
        broadcastToAll("[One Piece TCG] Creating table zone layout for all four seats...")
    end
end

function ClearTableZones()
    local zoneCount = 0
    for _, seatZones in pairs(zoneGuids) do
        for _, guid in pairs(seatZones) do
            local zone = getObjectFromGUID(guid)
            if zone ~= nil then
                zone.destruct()
                zoneCount = zoneCount + 1
            end
        end
    end

    zoneGuids = {}
    broadcastToAll("[One Piece TCG] Cleared " .. zoneCount .. " table zone(s).")
end

-- Public lookup for future rule scripting: the zone object a given seat's
-- named zone lives in (one of the ZONE_KEYS above), or nil.
function GetPlayerZone(playerColor, key)
    return ExistingZone(playerColor, key)
end

-- 16 inherited per-seat action button objects (Untap/Draw/Mill/Scry x4
-- seats). Each is tied to a fixed seat regardless of who clicks it -- TTS's
-- click_function(object, player_color, alt) passes the CLICKER's color, not
-- the button's own seat, so the target seat has to come from the button's
-- GUID instead of the player_color parameter. Also the single source of
-- truth CreateSeatActionButtons uses to (re)create the buttons themselves --
-- see that function for why they need recreating at all, rather than just
-- relying on whatever the original MTG mod already set up.
local SEAT_ACTION_BUTTONS = {
    {guid = "18fb5d", seat = "White",  label = "UNTAP", click_function = "playerUntap"},
    {guid = "86e447", seat = "Red",    label = "UNTAP", click_function = "playerUntap"},
    {guid = "e2f7ae", seat = "Blue",   label = "UNTAP", click_function = "playerUntap"},
    {guid = "1f3e4a", seat = "Yellow", label = "UNTAP", click_function = "playerUntap"},
    {guid = "26775a", seat = "White",  label = "DRAW",  click_function = "playerDraw"},
    {guid = "885f49", seat = "Red",    label = "DRAW",  click_function = "playerDraw"},
    {guid = "b49d50", seat = "Blue",   label = "DRAW",  click_function = "playerDraw"},
    {guid = "305c12", seat = "Yellow", label = "DRAW",  click_function = "playerDraw"},
    {guid = "57914a", seat = "White",  label = "MILL",  click_function = "playerMill"},
    {guid = "da5d0d", seat = "Red",    label = "MILL",  click_function = "playerMill"},
    {guid = "d06889", seat = "Blue",   label = "MILL",  click_function = "playerMill"},
    {guid = "67b4a5", seat = "Yellow", label = "MILL",  click_function = "playerMill"},
    {guid = "614515", seat = "White",  label = "SCRY",  click_function = "playerScry"},
    {guid = "ffa67c", seat = "Red",    label = "SCRY",  click_function = "playerScry"},
    {guid = "4e19c8", seat = "Blue",   label = "SCRY",  click_function = "playerScry"},
    {guid = "8a4c8b", seat = "Yellow", label = "SCRY",  click_function = "playerScry"}
}

local SEAT_BUTTON_OWNERS = {}
local SEAT_BUTTON_ACTIONS = {}
for _, entry in ipairs(SEAT_ACTION_BUTTONS) do
    SEAT_BUTTON_OWNERS[entry.guid] = entry.seat
    SEAT_BUTTON_ACTIONS[entry.guid] = entry.click_function
end

-- The original MTG mod created these buttons with an explicit
-- function_owner, but (confirmed live) they currently resolve to nothing on
-- click: TTS's click_function defaults to looking for the function on the
-- button's OWN object when function_owner isn't set, and these 16 objects
-- all carry blank scripts -- so whatever owner they had, it isn't resolving
-- to Global where playerUntap/playerDraw/playerMill/playerScry now live.
-- Also confirmed live: a full game/table reload (distinct from a Global
-- script reload) can wipe a button list down to 0 entirely, silently, with
-- no error. Recreating them explicitly with function_owner = Global on every
-- Global load (see onLoad) sidesteps both problems at once.
--
-- No `label` here (confirmed against the original MTG mod's own buttons,
-- which are label=nil too): the button is just a dark overlay over the
-- Tile's own printed icon, identified on hover via `tooltip` instead of
-- baked-on text.
function CreateSeatActionButtons()
    local count = 0
    for _, entry in ipairs(SEAT_ACTION_BUTTONS) do
        local obj = getObjectFromGUID(entry.guid)
        if obj ~= nil then
            obj.clearButtons()
            obj.createButton({
                tooltip = entry.seat .. " " .. entry.label:sub(1, 1) .. entry.label:sub(2):lower(),
                click_function = entry.click_function,
                function_owner = Global,
                position = {0, 0.3, 0},
                -- These tiles are circular, not square -- TTS buttons are
                -- always rectangular, so a square sized to the full
                -- diameter (1000) overhung past the circle's edge into
                -- visually-empty corners (confirmed live: "hitbox too
                -- big"). Sizing to the circle's INSCRIBED square instead
                -- (side = diameter / sqrt(2) ~= 0.707) keeps every clickable
                -- pixel inside the visible circle, at the cost of a thin
                -- sliver near the circle's own edge not being clickable.
                height = 700,
                width = 700,
                color = {0, 0, 0, 0},
                hover_color = {1, 1, 1, 0.15}
            })
            -- Without this, onObjectNumberTyped never fires at all for this
            -- object (confirmed live: typing a number while hovering did
            -- nothing, on an unlocked object with no button overlay either
            -- -- max_typed_number defaults to 0, i.e. "accept zero digits").
            -- The MTG mod set this explicitly on its own Scry button for
            -- the same reason; missed porting it over the first time.
            obj.max_typed_number = 99
            count = count + 1
        end
    end
    print("[One Piece TCG] Wired " .. count .. "/" .. #SEAT_ACTION_BUTTONS .. " seat action button(s).")
end

-- 4 inherited per-seat Mulligan tiles (same GUIDs/seat split as the MTG mod
-- this table was converted from -- seat mapping confirmed live from each
-- tile's table position, since unlike the Untap/Draw/Mill/Scry tiles these
-- don't encode their seat in a shared naming/position row). Same
-- self-healing reasoning as CreateSeatActionButtons above: blank scripts,
-- needs an explicit function_owner = Global.
local MULLIGAN_HAND_SIZE = 5
local MULLIGAN_BUTTONS = {
    {guid = "3b07ae", seat = "White"},
    {guid = "c53ac6", seat = "Red"},
    {guid = "47645d", seat = "Yellow"},
    {guid = "e0a3bc", seat = "Blue"},
}

local MULLIGAN_BUTTON_OWNERS = {}
for _, entry in ipairs(MULLIGAN_BUTTONS) do
    MULLIGAN_BUTTON_OWNERS[entry.guid] = entry.seat
end

function CreateMulliganButtons()
    local count = 0
    for _, entry in ipairs(MULLIGAN_BUTTONS) do
        local obj = getObjectFromGUID(entry.guid)
        if obj ~= nil then
            obj.clearButtons()
            obj.createButton({
                tooltip = entry.seat .. " Mulligan\nShuffle your hand back into your deck and draw " ..
                          MULLIGAN_HAND_SIZE .. " new cards.\nDouble-click to confirm if cards are already in play.",
                click_function = "playerMulligan",
                function_owner = Global,
                position = {0, 0.3, 0},
                height = 1000,
                width = 1600, -- this tile is a wide rectangle, not square like the others (confirmed live: ~2.5 x 0.9 world units)
                color = {0, 0, 0, 0},
                hover_color = {1, 1, 1, 0.15}
            })
            count = count + 1
        end
    end
    print("[One Piece TCG] Wired " .. count .. "/" .. #MULLIGAN_BUTTONS .. " mulligan button(s).")
end

-- True if obj is currently sitting in any seat's hand -- a zone's bounding
-- volume can overlap the hand zone near it (confirmed live: the Deck/Trash
-- row sits close enough to the hand that zone.getObjects() picks up literal
-- in-hand cards too), and nothing in a hand should ever be touched by a
-- board-wide action like Untap, or mistaken for "the deck" by Draw/Mill/Scry.
local function IsInAnyHand(obj)
    for _, color in ipairs(TABLE_SEAT_COLORS) do
        for _, handObj in ipairs(Player[color].getHandObjects()) do
            if handObj == obj then return true end
        end
    end
    return false
end

-- The object currently sitting in a seat's Deck zone -- a Deck while 2+
-- cards remain, a lone Card for the last one. nil if the deck is empty.
local function GetSeatDeckPile(seatColor)
    local zone = GetPlayerZone(seatColor, "deck")
    if zone == nil then return nil end
    for _, obj in ipairs(zone.getObjects()) do
        if (obj.tag == "Deck" or obj.tag == "Card") and not IsInAnyHand(obj) then
            return obj
        end
    end
    return nil
end

-- A card's normal "on the battlefield" yaw is NOT the hand's own yaw -- it's
-- flipped 180 so it reads the same direction as the Leader (across the
-- table, readable by both players), matching the seatRotY convention
-- CardImporter.lua already uses for the Leader/Deck spawn rotation. Using
-- the hand's raw yaw here was a real bug (confirmed: cards ended up facing
-- backwards after Untap).
local function GetSeatYaw(seatColor)
    local hand = Player[seatColor] and Player[seatColor].getHandTransform(1)
    if hand == nil then return 0 end
    return (hand.rotation.y + 180) % 360
end

-- Ported from the original MTG mod's identical helpers (buttonPress/
-- buttonCooldown there): a physical "press" -- the whole button-bearing tile
-- dips down and springs back -- plus a "cooldown" that flips every button on
-- it upside-down for a few seconds. Without these, resolving an action reads
-- as an instant, silent state swap instead of something happening.
local function ButtonPress(obj, seconds)
    if obj == nil then return end
    local posUp = obj.getPosition()
    local posDown = obj.getPosition()
    posDown.y = posDown.y - 0.1
    obj.setPositionSmooth(posDown, false, true)
    Wait.time(function() obj.setPositionSmooth(posUp, false, true) end, math.max(seconds, 0.05))
end

local function ButtonCooldown(obj, seconds)
    if obj == nil then return end
    local buttons = obj.getButtons() or {}
    for _, but in ipairs(buttons) do
        local rot = but.rotation
        local index = but.index
        obj.editButton({index = index, rotation = {rot.x, rot.y, 180}})
        Wait.time(function() obj.editButton({index = index, rotation = {rot.x, rot.y, 0}}) end, seconds)
    end
end

-- Safety net ported from the original MTG mod's checkMoveSuccess: a smooth
-- move can get interrupted by physics (a resting Deck in the way, etc.)
-- before it reaches its target -- if the card is still off by more than a
-- card's width shortly after the animation should have finished, snap it the
-- rest of the way rather than leaving it stranded mid-table.
local function CorrectCardPosition(card, targetPos)
    if card == nil then return end
    local cx, _, cz = VectorComponents(card.getPosition())
    local tx, _, tz = VectorComponents(targetPos)
    local dx, dz = cx - tx, cz - tz
    if math.sqrt(dx * dx + dz * dz) > 1 then
        card.setPosition(targetPos)
    end
end

-- Unlike the original MTG version (stun counters, exert, hardcoded card-name
-- checks, etc. -- none of which exist in OPTCG), this just resets every
-- card/deck across the button's seat's own zones back to that seat's normal
-- (non-rested) orientation, preserving face-up/down and flatness.
function playerUntap(button, playerColor, alt)
    local seatColor = SEAT_BUTTON_OWNERS[button.getGUID()]
    if seatColor == nil then return end

    ButtonPress(button, 0.3)

    local seatYaw = GetSeatYaw(seatColor)
    local count = 0
    for _, key in ipairs(ZONE_KEYS) do
        local zone = GetPlayerZone(seatColor, key)
        if zone ~= nil then
            for _, obj in ipairs(zone.getObjects()) do
                if (obj.tag == "Card" or obj.tag == "Deck") and not IsInAnyHand(obj) then
                    local x, _, z = VectorComponents(obj.getRotation())
                    obj.setRotationSmooth({x, seatYaw, z}, false, true)
                    count = count + 1
                end
            end
        end
    end

    broadcastToAll("[One Piece TCG] " .. seatColor .. " untapped " .. count .. " object(s).")
end

-- Deals the top card of the seat's deck into that seat's hand. Object.deal
-- works on both a Deck and a lone Card, so GetSeatDeckPile's result can be
-- used directly either way, and already animates the card flying to hand on
-- its own. Pulled out to its own function (not just inlined in playerDraw)
-- so onObjectNumberTyped below can also drive it for an arbitrary count --
-- same "type a number over the button" shortcut the MTG mod's Draw/Mill/
-- Scry buttons supported, not just a fixed per-click amount.
function DrawCards(seatColor, count)
    Wait.time(function()
        local pile = GetSeatDeckPile(seatColor)
        if pile == nil then
            broadcastToAll("[One Piece TCG] " .. seatColor .. "'s deck is empty.")
            return
        end
        pile.deal(1, seatColor)
    end, 0.15, count)
end

function playerDraw(button, playerColor, alt)
    local seatColor = SEAT_BUTTON_OWNERS[button.getGUID()]
    if seatColor == nil then return end

    ButtonPress(button, 0.3)
    DrawCards(seatColor, 1)
end

-- Moves the top card of the seat's deck straight into their Trash zone, face
-- up (same as any card resting in Trash), no reveal/choice involved. Animated
-- with takeObject's own smooth option (Deck branch) or setPositionSmooth/
-- setRotationSmooth (lone-Card branch), same as the original MTG mod's
-- mill1, with CorrectCardPosition as the same landing-safety-net it used.
local function Mill1(seatColor)
    local pile = GetSeatDeckPile(seatColor)
    if pile == nil then
        broadcastToAll("[One Piece TCG] " .. seatColor .. "'s deck is empty.")
        return
    end

    local trashZone = GetPlayerZone(seatColor, "trash")
    if trashZone == nil then return end

    local tx, ty, tz = VectorComponents(trashZone.getPosition())
    local dropPosition = {tx, ty + 1, tz}
    local dropRotation = {0, GetSeatYaw(seatColor), 0}

    if pile.tag == "Deck" then
        pile.takeObject({
            position = dropPosition, rotation = dropRotation, smooth = true,
            callback_function = function(card)
                Wait.time(function() CorrectCardPosition(card, dropPosition) end, 0.5)
            end
        })
    else
        pile.setPositionSmooth(dropPosition, false, true)
        pile.setRotationSmooth(dropRotation, false, true)
        Wait.time(function() CorrectCardPosition(pile, dropPosition) end, 0.5)
    end

    broadcastToAll("[One Piece TCG] " .. seatColor .. " milled a card.")
end

-- Same reasoning as DrawCards above -- split out so a typed number can
-- repeat it, staggered the same way the MTG mod staggered its own
-- mill/scry/draw repeats (drawDelay between each, not all at once).
function MillCards(seatColor, count)
    Wait.time(function() Mill1(seatColor) end, 0.15, count)
end

function playerMill(button, playerColor, alt)
    local seatColor = SEAT_BUTTON_OWNERS[button.getGUID()]
    if seatColor == nil then return end

    ButtonPress(button, 0.3)
    MillCards(seatColor, 1)
end

-- OPTCG's "look at the top X cards of your deck" is a group reveal where
-- the cards' relative order matters (effects let you rearrange them, not
-- just resolve one at a time) -- different from MTG's "scry" which this was
-- first ported from 1:1 (πScry_de4346.lua) before that turned out to be the
-- wrong mechanic entirely. Each scried card carries Top/Bottom/Trash buttons
-- (▲/▼/☠, same glyphs/positions as the MTG mod's πScry property).
--
-- Now genuinely ported like the MTG mod: cards are dealt into the seat's
-- own second hand zone (Player[color].getHandTransform(2)/deal(1,color,2)),
-- which a table-edit added to this save (4 new HandTrigger objects, one per
-- seat, positioned just past each hand's own pickup trigger -- see the
-- commit/session notes for exact transforms). A real hand zone gives this
-- for free: private to the owner, legible orientation, and "drag it out ==
-- done resolving" via Player[color].getHandObjects(2) membership, no custom
-- invisible zone or visibility bookkeeping needed at all.
--
-- Note on timing: createButton must NOT be called on the object returned
-- directly by takeObject -- confirmed live, it silently has no effect.
-- "Objects taken out of a container take one or more frames to spawn" per
-- TTS's own docs; takeObject's callback_function (called once actually
-- spawned) is the correct place for it, not the synchronous return value.
local scryCardSeats = {}

local function ClearScryCard(card)
    scryCardSeats[card.getGUID()] = nil
    card.clearButtons()
end

local function CreateScryButtons(card, seatColor)
    scryCardSeats[card.getGUID()] = seatColor

    local function AddResolveButton(label, tooltip, fn, z)
        card.createButton({
            click_function = "DoNothing", function_owner = Global,
            width = 500, height = 400, font_size = 250,
            scale = {0.55, 0.55, 0.55}, rotation = {0, 0, 180}, position = {-0.8, 0.1, z},
            color = {0.7, 0.7, 0.7}, font_color = {1, 1, 1}
        })
        card.createButton({
            label = label, tooltip = tooltip, click_function = fn, function_owner = Global,
            width = 500, height = 400, font_size = 250,
            scale = {0.5, 0.5, 0.5}, rotation = {0, 0, 0}, position = {-0.8, 0.1, z},
            color = {0.16, 0.16, 0.16}, font_color = {1, 1, 1}, hover_color = {0.4, 0.4, 0.4}
        })
    end

    AddResolveButton("▲", "Move to top of deck", "ScryToTop", -2.2)
    AddResolveButton("▼", "Move to bottom of deck", "ScryToBottom", -1.77)
    AddResolveButton("X", "Move to Trash", "ScryToTrash", 1.77)
end

function ScryToTrash(card, playerColor, alt)
    local seatColor = scryCardSeats[card.getGUID()]
    if seatColor == nil then return end
    ClearScryCard(card)

    local zone = GetPlayerZone(seatColor, "trash")
    if zone == nil then return end
    local zx, zy, zz = VectorComponents(zone.getPosition())

    -- No delayed position-correction here on purpose -- see MergeScriedCard
    -- above for why touching the card again after a delay risks a null
    -- reference if it's already been auto-merged by then. Trash doesn't
    -- care about stacking order, so there's nothing to correct for anyway.
    --
    -- Same hand-ownership issue as MergeScriedCard: the card is still
    -- resting in hand-2, so its transform is owned by TTS's hand system
    -- until use_hands is turned off -- without this it just jerks in place
    -- instead of actually leaving the hand (confirmed live).
    card.use_hands = false
    card.setRotationSmooth({0, GetSeatYaw(seatColor), 0}, false, false) -- face up, flip first, then travel
    Wait.time(function()
        if card == nil then return end
        card.setPositionSmooth({zx, zy + 2, zz}, false, false)
    end, 0.4)
end

-- Both Top and Bottom share the same core trick, confirmed live: a card
-- lingering near a deck for any length of time (a Wait.time-delayed
-- "correct its position" check, a slow setPositionSmooth animation that
-- ends close to the deck, etc.) can get silently auto-merged by TTS's own
-- physics *before* our own script gets to act on it -- any later code that
-- still touches that Lua reference then throws "Object reference not set
-- to an instance of an object" (confirmed live, matches the error players
-- were hitting), and a merge that happens this way isn't reliably ordered
-- either (that's why Bottom kept landing back on top no matter what height
-- was used).
--
-- pile.putObject(card) sidesteps both problems: it's a single synchronous
-- call that merges immediately based on the card's position *at that exact
-- moment* (above the pile = new top card, below = new bottom card,
-- confirmed live both ways) -- no settling time for TTS's own auto-merge to
-- race ahead of, and no later callback that might find the card already
-- gone. The card still gets a brief smooth flight from hand-2 first for
-- the animation; the merge itself only happens in one atomic snap right
-- after, same as how a manual drag-and-drop merge isn't animated either.
local function MergeScriedCard(card, seatColor, verticalOffset)
    local deckZone = GetPlayerZone(seatColor, "deck")
    if deckZone == nil then return end
    local dx, dy, dz = VectorComponents(deckZone.getPosition())

    -- A card resting IN a hand zone is rendered/positioned by TTS's hand
    -- system, not normal physics -- setPositionSmooth on it was teleporting
    -- instantly with zero visible travel (confirmed live) because the hand
    -- system owns its transform until it's released. use_hands=false frees
    -- it to move like an ordinary table object again, same as the MTG mod's
    -- handTrigger() did for this exact hand-to-deck move.
    -- Park on the SAME side as the final merge (above the deck for Top,
    -- below it for Bottom) -- parking above for both (confirmed live) made
    -- "move to bottom" visually read as moving to the top, since the only
    -- thing the player sees is "hover above, then vanish."
    local parkOffset = verticalOffset + (verticalOffset >= 0 and 1 or -1)

    -- Flip in place first, then move -- doing both at once read as the
    -- card tumbling on its way over instead of two distinct, readable
    -- beats (flip, then travel).
    card.use_hands = false
    card.setRotationSmooth({0, GetSeatYaw(seatColor), 180}, false, false) -- face down, same as every other library card

    Wait.time(function()
        if card == nil then return end
        card.setPositionSmooth({dx, dy + parkOffset, dz}, false, false) -- straight toward the deck, on the correct side of it -- fast=false for a slower, more visible flight

        Wait.time(function()
            if card == nil then return end
            local pile = GetSeatDeckPile(seatColor)
            card.setPosition({dx, dy + verticalOffset, dz})
            if pile ~= nil and pile.getGUID() ~= card.getGUID() then
                pile.putObject(card)
            end
        end, 1.1) -- matches the slower fast=false flight above -- let it actually arrive before snapping into the deck
    end, 0.4) -- give the flip time to actually finish before the move starts
end

function ScryToTop(card, playerColor, alt)
    local seatColor = scryCardSeats[card.getGUID()]
    if seatColor == nil then return end
    ClearScryCard(card)
    MergeScriedCard(card, seatColor, 3)
end

function ScryToBottom(card, playerColor, alt)
    local seatColor = scryCardSeats[card.getGUID()]
    if seatColor == nil then return end
    ClearScryCard(card)
    MergeScriedCard(card, seatColor, -2)
end

-- Called from onObjectDropped (see the "Automatic activation" section) for
-- every card drop in the game -- same event and same check the original MTG
-- mod's πScry used (onObjectDrop): if this card is still tracked as a scry
-- card but is no longer sitting in the seat's hand-2, the player dragged it
-- out to resolve it by hand instead of clicking a button -- clear it either
-- way.
function TryClearScryIfLeftZone(object)
    if object == nil or object.tag ~= "Card" then return end
    local seatColor = scryCardSeats[object.getGUID()]
    if seatColor == nil then return end

    for _, handObj in ipairs(Player[seatColor].getHandObjects(2)) do
        if handObj == object then return end -- still resting in hand-2
    end
    ClearScryCard(object)
end

-- Pulled out from playerScry so onObjectNumberTyped below can drive an
-- arbitrary count too, same as DrawCards/MillCards.
function ScryCards(seatColor, count)
    if Player[seatColor] == nil or Player[seatColor].getHandTransform(2) == nil then
        broadcastToAll("[One Piece TCG] " .. seatColor .. " has no second hand zone set up for Scry.")
        return
    end

    local staged = 0
    local anyEmpty = false
    for i = 1, count do
        local pile = GetSeatDeckPile(seatColor)
        if pile == nil then
            anyEmpty = true
            break
        end

        -- Same two-step the MTG mod's scry1 used: extract the card first
        -- and wait for it to finish spawning, then deal *that* reference
        -- into hand-2 -- dealing straight off the Deck object doesn't hand
        -- back a reference to attach the Top/Bottom/Trash buttons to.
        --
        -- Extracting to the SAME position as the remaining deck (confirmed
        -- live -- that's what this did before) invites an immediate
        -- TTS auto-re-merge before Wait.condition/deal() ever runs, and
        -- touching that already-merged reference afterward is exactly what
        -- threw the "Object reference not set to an instance of an object"
        -- error players were hitting on every single scry. Popping it out
        -- a few units above first keeps it clear of the deck's own
        -- collider until it's safely dealt into hand-2.
        local px, py, pz = VectorComponents(pile.getPosition())
        local extractPos = {px, py + 3, pz}

        -- deal() is itself animated/async (the card visibly flies into
        -- hand-2 over time, same as a normal draw) -- creating the
        -- Top/Bottom/Trash buttons immediately raced TTS's own
        -- onObjectDropped firing mid-flight, before the card actually
        -- registered in Player[seatColor].getHandObjects(2) yet. Since
        -- TryClearScryIfLeftZone only acts on cards already tracked in
        -- scryCardSeats, waiting to populate that (via CreateScryButtons)
        -- until the card is *confirmed* resting in hand-2 makes any
        -- mid-flight onObjectDropped a harmless no-op instead of a race
        -- that strips the buttons the instant they're created (confirmed
        -- live).
        local function IsInHand2(obj)
            for _, handObj in ipairs(Player[seatColor].getHandObjects(2)) do
                if handObj == obj then return true end
            end
            return false
        end

        local function FinishCard(topCard)
            if topCard == nil then return end
            Wait.condition(function()
                topCard.deal(1, seatColor, 2)
                Wait.condition(function()
                    CreateScryButtons(topCard, seatColor)
                end, function() return IsInHand2(topCard) end)
            end, function() return not topCard.spawning end)
        end

        if pile.tag == "Deck" then
            pile.takeObject({position = extractPos, rotation = pile.getRotation(), smooth = false, callback_function = FinishCard})
        else
            FinishCard(pile)
        end
        staged = staged + 1
    end

    if staged == 0 then
        broadcastToAll("[One Piece TCG] " .. seatColor .. "'s deck is empty.")
    else
        broadcastToAll("[One Piece TCG] " .. seatColor .. " is looking at " .. staged .. ".")
        if anyEmpty then
            broadcastToAll("[One Piece TCG] " .. seatColor .. "'s deck ran out early.")
        end
    end
end

function playerScry(button, playerColor, alt)
    local seatColor = SEAT_BUTTON_OWNERS[button.getGUID()]
    if seatColor == nil then return end

    ButtonPress(button, 0.3)
    ScryCards(seatColor, alt and 3 or 1)
end

-- Shuffles the seat's hand back into their deck and draws a fresh
-- MULLIGAN_HAND_SIZE-card hand. No once-per-game limit here by design --
-- that's left to the players to self-police. Adapted from the MTG mod's
-- playerMulligan -- ported directly are the double-click safety check
-- (refuses a mid-game press unless clicked again within 0.5s, in case this
-- was an accidental press) and the staggered reshuffle-then-deal timing.
-- Not ported: the shrinking 7/6/5/...-card count (MTG-specific, no OPTCG
-- equivalent) and the land-ratio "smart mulligan" toggle (there are no
-- lands in OPTCG).
local mulliganClickTimes = {}

function playerMulligan(button, playerColor, alt)
    local seatColor = MULLIGAN_BUTTON_OWNERS[button.getGUID()]
    if seatColor == nil then return end

    local now = os.clock()
    local isDoubleClick = mulliganClickTimes[seatColor] ~= nil and (now - mulliganClickTimes[seatColor]) < 0.5
    mulliganClickTimes[seatColor] = now

    local inPlay = false
    for _, key in ipairs({"characterArea", "stageArea"}) do
        local zone = GetPlayerZone(seatColor, key)
        if zone ~= nil then
            for _, obj in ipairs(zone.getObjects()) do
                if obj.tag == "Card" or obj.tag == "Deck" then inPlay = true end
            end
        end
    end

    if inPlay and not isDoubleClick then
        Player[playerColor].broadcast(
            "Cards already in play -- accidental mulligan press mid-game?\n" ..
            "If you still wish to mulligan, click the button again within half a second.")
        return
    end

    local deck = GetSeatDeckPile(seatColor)
    if deck == nil or deck.tag ~= "Deck" then
        broadcastToAll("[One Piece TCG] " .. seatColor .. "'s deck can't be shuffled right now.")
        return
    end

    ButtonPress(button, 0.3)
    ButtonCooldown(button, 2)

    for _, obj in ipairs(Player[seatColor].getHandObjects(1)) do
        if obj.tag == "Card" then
            deck.putObject(obj)
        end
    end

    Wait.time(function() deck.shuffle() end, 0.1, 7)
    Wait.time(function()
        local freshPile = GetSeatDeckPile(seatColor)
        if freshPile ~= nil then
            freshPile.deal(MULLIGAN_HAND_SIZE, seatColor)
        end
    end, 0.8)

    broadcastToAll("[One Piece TCG] " .. seatColor .. " is taking a mulligan.")
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
    TryClearScryIfLeftZone(object)
end

-- "Type a number while hovering a button" shortcut, same as the MTG mod's
-- Draw/Mill/Scry buttons (the tooltip text already promised this: "or type
-- the desired amount") -- TTS calls this for ANY object whenever a player
-- types digits while hovering it, not just these; SEAT_BUTTON_ACTIONS is
-- how it's narrowed down to just our own seat-action tiles.
function onObjectNumberTyped(obj, playerColor, number)
    if number == nil or number <= 0 then return end
    local seatColor = SEAT_BUTTON_OWNERS[obj.getGUID()]
    if seatColor == nil then return end

    local action = SEAT_BUTTON_ACTIONS[obj.getGUID()]
    if action == "playerDraw" then
        broadcastToAll("[One Piece TCG] " .. seatColor .. " draws " .. number .. ".")
        DrawCards(seatColor, number)
    elseif action == "playerMill" then
        broadcastToAll("[One Piece TCG] " .. seatColor .. " mills " .. number .. ".")
        MillCards(seatColor, number)
    elseif action == "playerScry" then
        ScryCards(seatColor, number)
    end
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
