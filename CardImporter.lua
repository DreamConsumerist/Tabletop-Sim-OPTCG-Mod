-- One Piece TCG Card Importer
--
-- Paste a decklist (one "<qty>x<cardID>" line per entry, e.g. "4xOP16-064",
-- matching the format used by the user's own OPTCGSim .deck files -- no
-- header, no comments, no blank-line separators) and click IMPORT DECK.
-- Card data comes from https://optcgapi.com/api/ (no auth/key). Fetched
-- records are cached in this object's own saved state, keyed by card ID, so
-- repeated imports don't re-hit the network.
--
-- Every card is fetched individually (never via a bulk /sets/{set_id}/
-- call). That was the original design -- bulk fetching one call per set
-- instead of one per card -- but measured live: TTS's native JSON.decode()
-- took 3-5 BLOCKING seconds per ~100KB bulk-set response (8 such sets in one
-- test deck == 28+ seconds of frozen game), while every per-card response
-- (under ~12KB) decoded in well under 0.3s. There's no documented way to
-- filter a bulk response down to just the cards actually needed, so
-- per-card is the only fetch shape that doesn't freeze the game on a normal
-- deck import. See git history on this file if bulk fetching is ever
-- reconsidered -- the numbers that ruled it out are worth re-checking
-- against the live API first.
--
-- Spawned cards carry their stats in GMNotes as "OPTCG_CARD=<json>" rather
-- than being pushed into Encoder directly -- a card is still packed inside
-- a Deck object at spawn time and can't be called into. Global.lua's
-- onObjectDropped picks the stats up lazily the first time a card is
-- actually drawn/dropped onto the table (see TryActivateCardStatsFromGMNotes).

local API_BASE = "https://optcgapi.com/api"
local CARD_BACK_URL = "https://steamusercontent-a.akamaihd.net/ugc/9637735862396937445/7DC779F1C946E11B010AF8D039FF4DAAF09C8868/"
local WEB_GET_TIMEOUT = 15
local PANEL_ID = "cardImporterPanel"
local INPUT_ID = "cardImporterDecklistInput"

local lastDecklistText = ""

-- Fixed per-seat Leader/Deck spawn coordinates, matching the Leader Area and
-- Deck zone layout -- measured live against placeholder objects positioned
-- at each seat (the placeholders themselves are not part of the finished
-- table). A seat missing from one of these tables falls back to the
-- hand-relative offset in BuildSpawnDeckData below.
local LEADER_SPAWN_POSITIONS = {
    White  = {23.3202934265137, 0.983632862567902, -15.4720487594604},
    Red    = {-21.2356739044189, 0.983604907989502, -15.5559482574463},
    Yellow = {-23.2967567443848, 0.983605027198792, 15.5890121459961},
    Blue   = {21.2492065429688, 0.983574151992798, 15.6570253372192}
}

local DECK_SPAWN_POSITIONS = {
    White  = {40.8893737792969, 0.984133362770081, -15.471492767334},
    Red    = {-3.687087059021, 0.983604907989502, -15.5756874084473},
    Yellow = {-40.8182487487793, 0.983604907989502, 15.6064376831055},
    Blue   = {3.7502646446228, 0.983075618743896, 15.5067720413208}
}

-- Fixed per-seat DON!! deck spawn coordinates -- same measured-placeholder
-- pattern as LEADER_SPAWN_POSITIONS/DECK_SPAWN_POSITIONS above. Previously
-- these spawned via a separate manual "CREATE 4 DON!! DECKS" button on the
-- Global.lua module chip (CreateOneDonDeck/CreateDonDecks there, using a
-- hand-relative GetDonAreaPositions formula); that button was removed and
-- DON!! decks now spawn automatically alongside the deck/leader on import
-- instead, one seat at a time, at these fixed positions.
local DON_SPAWN_POSITIONS = {
    White  = {4.09209489822388, 0.983085036277771, -22.2640419006348},
    Red    = {-40.5021629333496, 0.983604967594147, -22.1983089447021},
    Yellow = {-4.03835678100586, 0.983604907989502, 22.3025150299072},
    Blue   = {40.5390167236328, 0.984123826026917, 22.3270950317383}
}

local DON_CARD_COUNT = 10

-- A hidden template DON!! card that every import clones instead of building
-- a fresh CardCustom object from raw face/back URLs each time. Spawning a
-- brand-new custom card via script (spawnObject + setCustomObject) reliably
-- pops TTS's own custom-card-creation modal (confirmed live -- that's what
-- was flashing/blocking during import, not our own modal, and setCustomObject
-- in the callback does NOT suppress it the way TTS's docs imply). clone()
-- does not trigger that modal.
--
-- This template is created ONCE, manually, by the user (right-click >
-- Custom > Card in TTS, same as any custom card) -- not spawned by this
-- script at all, specifically so the modal never has a script-driven path
-- to appear on again. GUID is fixed; if the template is ever deleted, a new
-- one needs to be hand-created and this constant updated.
local DON_TEMPLATE_GUID = "7f2099"

-- Spawns the importing seat's 10-card physical DON!! deck at their fixed
-- table position, tagged/GMNotes'd the same way Global.lua's old
-- CreateOneDonDeck did (Global.lua's GetDonOwner still reads this same
-- "OPTCG_DON_OWNER=<color>" convention). A no-op if the importing player
-- isn't one of the 4 seats this table knows about, or if the template is
-- missing (never auto-recreated -- see above).
function SpawnDonDeck(player)
    if player == nil or DON_SPAWN_POSITIONS[player.color] == nil then return end

    local template = getObjectFromGUID(DON_TEMPLATE_GUID)
    if template == nil then
        broadcastToAll("[Card Importer] DON!! template (" .. DON_TEMPLATE_GUID .. ") is missing -- can't spawn a DON!! deck. Create a new template card and update DON_TEMPLATE_GUID.", {1, 0.3, 0.3})
        return
    end

    local position = DON_SPAWN_POSITIONS[player.color]
    local hand = player.getHandTransform(1)
    local seatRotY = hand and ((hand.rotation.y + 180) % 360) or 0
    local rotation = {0, seatRotY, 180} -- face down by default, same flip convention as the main deck (rotZ=180)
    local ownerColor = player.color

    local spawnedCards = {}
    for cardIndex = 1, DON_CARD_COUNT do
        local cardPosition = {
            position[1] + (cardIndex - 1) * 0.025,
            position[2] + 1.5 + (cardIndex - 1) * 0.015,
            position[3]
        }
        local card = template.clone({position = cardPosition, rotation = rotation})
        if card ~= nil then
            card.setName("DON!!")
            card.setDescription("Physical DON!! resource card")
            card.setGMNotes("OPTCG_DON_OWNER=" .. ownerColor)
            card.removeTag("OPTCG_DON_TEMPLATE")
            card.addTag("OPTCG_DON")
            card.setLock(false)
            card.interactable = true
            card.setInvisibleTo({})
            table.insert(spawnedCards, card)
        end
    end

    if #spawnedCards == DON_CARD_COUNT then
        local grouped = group(spawnedCards) or {}
        local deck = grouped[1]
        if deck ~= nil then
            deck.setName(ownerColor .. " DON!! Deck")
            deck.setDescription("10 physical DON!! cards owned by " .. ownerColor .. ".")
            deck.addTag("OPTCG_DON_DECK")
            deck.setPositionSmooth(position, false, true)
        end
    end
end

-- -----------------------------------------------------------------------------
-- Low-level fetch helpers
-- -----------------------------------------------------------------------------

function WebGetSSL(url, callback, timeoutSec)
    timeoutSec = timeoutSec or WEB_GET_TIMEOUT
    local settled = false
    Wait.time(function()
        if settled then return end
        settled = true
        callback({is_error = true, error = "Timeout after " .. timeoutSec .. "s", text = ""})
    end, timeoutSec)

    WebRequest.custom(url, "GET", true, nil, {["Accept"] = "application/json"}, function(wr)
        if settled then return end
        settled = true
        callback(wr)
    end)
end

local function SafeJSON(text)
    if text == nil or text == "" then return nil end
    if text:match("^%s*<") then return nil end -- HTML error page, not JSON
    local ok, decoded = pcall(function() return JSON.decode(text) end)
    if ok then return decoded end
    return nil
end

-- -----------------------------------------------------------------------------
-- CardLookup: the only module that knows optcgapi.com's response shape.
-- Everything downstream only ever calls CardLookup.GetCard.
-- -----------------------------------------------------------------------------

CardLookup = {cache = {}}

function CardLookup.NormalizeCardRecord(apiRecord)
    return {
        cardSetID = apiRecord.card_set_id or "",
        cardName = apiRecord.card_name or "",
        cost = tonumber(apiRecord.card_cost) or 0,
        power = tonumber(apiRecord.card_power) or 0,
        counter = tonumber(apiRecord.counter_amount) or 0,
        color = apiRecord.card_color or "",
        cardType = apiRecord.card_type or "",
        attribute = apiRecord.attribute or "",
        life = tonumber(apiRecord.life) or 0,
        subTypes = apiRecord.sub_types or "",
        rulesText = apiRecord.card_text or "",
        imageURL = apiRecord.card_image or ""
    }
end

-- A card lookup can return multiple printings sharing the same card_set_id
-- (a base print, "(Parallel)" foil, "(Alternate Art)", manga-art "(SP)"
-- promo reprint, etc. -- variant naming isn't consistent enough to
-- pattern-match on). The reliable signal instead: the base printing's
-- card_image_id is always exactly equal to card_set_id, while every variant's
-- card_image_id carries a suffix (e.g. "OP14-033_p1"). A record that matches
-- gets stored unconditionally (always the right pick); a record that
-- doesn't match is only stored as a last resort if nothing else has claimed
-- that ID yet.
function CardLookup.StoreRecord(apiRecord)
    if apiRecord == nil or apiRecord.card_set_id == nil then return end
    local isCanonical = apiRecord.card_image_id == apiRecord.card_set_id
    if not isCanonical and CardLookup.cache[apiRecord.card_set_id] ~= nil then return end
    CardLookup.cache[apiRecord.card_set_id] = CardLookup.NormalizeCardRecord(apiRecord)
end

-- Derives the ID prefix letters from a card ID like "OP16-064" -> "OP",
-- "PRB02-014" -> "PRB", "P-999" -> "P". Returns nil if the ID doesn't match
-- the expected shape at all.
function CardLookup.SplitCardID(cardID)
    return cardID:match("^(%a+)%d*-%d+$")
end

-- Fetches one card by ID from whichever per-card endpoint matches its
-- prefix family: main sets (OP-/EB-/PRB-) via /sets/card/, starter decks
-- (ST-) via /decks/card/, promos (P-) via /promos/card/. A response can be
-- a bare object or an array of printings (see CardLookup.StoreRecord) --
-- both shapes are handled the same way here.
function CardLookup.FetchCard(cardID, callback)
    local letters = CardLookup.SplitCardID(cardID)
    local urlPath, notFoundLabel
    if letters == "ST" then
        urlPath, notFoundLabel = "/decks/card/", "Starter card"
    elseif letters == "P" then
        urlPath, notFoundLabel = "/promos/card/", "Promo card"
    else
        urlPath, notFoundLabel = "/sets/card/", "Card"
    end

    WebGetSSL(API_BASE .. urlPath .. cardID .. "/", function(wr)
        if wr.is_error then
            callback(false, "Request failed: " .. tostring(wr.error))
            return
        end
        local decoded = SafeJSON(wr.text)
        if decoded == nil or decoded["Error!"] ~= nil or decoded.error ~= nil then
            callback(false, notFoundLabel .. " " .. cardID .. " not found.")
            return
        end
        local records = decoded[1] ~= nil and decoded or {decoded}
        for _, record in ipairs(records) do
            CardLookup.StoreRecord(record)
        end
        callback(true)
    end)
end

-- The single public entry point. Everything else only ever calls this.
-- Cache-checked first; the OP-18 local-asset fallback (and any future
-- second data source) would plug in here as an extra branch before the
-- final "not found" result, without changing anything downstream.
function CardLookup.GetCard(cardID)
    return CardLookup.cache[cardID]
end

-- -----------------------------------------------------------------------------
-- Decklist parsing
-- -----------------------------------------------------------------------------

function ParseDecklistText(text)
    local entries = {}
    local warnings = {}

    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then
            local qty, cardID = line:match("^(%d+)[xX](%S+)$")
            if qty ~= nil then
                table.insert(entries, {cardID = cardID, qty = tonumber(qty)})
            else
                table.insert(warnings, "Could not parse line: \"" .. line .. "\"")
            end
        end
    end

    return entries, warnings
end

-- -----------------------------------------------------------------------------
-- Spawning
-- -----------------------------------------------------------------------------

local function BuildCardData(n, stats)
    return {
        Transform = {posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 0, rotZ = 0, scaleX = 1, scaleY = 1, scaleZ = 1},
        Name = "Card",
        Nickname = stats.cardName,
        Description = stats.rulesText,
        GMNotes = "OPTCG_CARD=" .. JSON.encode(stats),
        CardID = n * 100,
        CustomDeck = {
            [tostring(n)] = {
                FaceURL = stats.imageURL,
                BackURL = CARD_BACK_URL,
                NumWidth = 1,
                NumHeight = 1,
                Type = 0,
                BackIsHidden = true,
                UniqueBack = false
            }
        }
    }
end

-- Expands each decklist line into `qty` flat copies, builds one CustomDeck
-- slot per copy, pulls the Leader out to spawn separately face-up, and
-- spawns everything else as one deck object. Spawns in front of the
-- importing player's own seat (via their hand zone transform) so each
-- player gets their deck in their own area rather than everyone's decks
-- piling up on top of the importer object itself; falls back to spawning
-- near the importer if that player isn't seated (e.g. testing solo).
function BuildSpawnDeckData(entries, missing, player)
    local deckPosition, leaderPosition, seatRotY
    local hand = player and player.getHandTransform(1)
    if hand then
        local fwd = hand.forward
        local right = hand.right
        local centerX, centerY, centerZ = hand.position.x + fwd.x * 4.25, hand.position.y + 2, hand.position.z + fwd.z * 4.25
        deckPosition = {centerX - right.x * 5, centerY, centerZ - right.z * 5}
        leaderPosition = {centerX + right.x * 5, centerY, centerZ + right.z * 5}
        seatRotY = (hand.rotation.y + 180) % 360
    else
        local basePosition = self.getPosition()
        deckPosition = {basePosition.x, basePosition.y + 2, basePosition.z + 2}
        leaderPosition = {basePosition.x, basePosition.y + 2, basePosition.z + 3.5}
        seatRotY = 0
    end

    if player and LEADER_SPAWN_POSITIONS[player.color] then
        leaderPosition = LEADER_SPAWN_POSITIONS[player.color]
    end
    if player and DECK_SPAWN_POSITIONS[player.color] then
        deckPosition = DECK_SPAWN_POSITIONS[player.color]
    end

    -- spawnObjectData's `rotation` param fully overrides data.Transform's
    -- rotation (not just the Y component), so the deck's face-down flip has
    -- to live in the spawn rotation, not in deckDat.Transform. Flipping via
    -- rotX also mirrors how rotY reads (upside-down relative to the seat);
    -- rotZ=180 flips face-down while keeping the seat's yaw reading correct.
    local deckRotation = {0, seatRotY, 180}
    local leaderRotation = {0, seatRotY, 0}

    local leaderStats = nil
    local deckDat = {
        Transform = {posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 0, rotZ = 0, scaleX = 1, scaleY = 1, scaleZ = 1},
        Name = "Deck",
        Nickname = "Imported Deck",
        DeckIDs = {},
        CustomDeck = {},
        ContainedObjects = {}
    }

    local n = 1
    local deckIndex = 1
    for _, entry in ipairs(entries) do
        local stats = CardLookup.GetCard(entry.cardID)
        if stats == nil then
            table.insert(missing, entry.cardID)
        else
            for _ = 1, entry.qty do
                if stats.cardType == "Leader" and leaderStats == nil then
                    leaderStats = stats
                else
                    local cardDat = BuildCardData(n, stats)
                    deckDat.DeckIDs[deckIndex] = cardDat.CardID
                    deckDat.CustomDeck[tostring(n)] = cardDat.CustomDeck[tostring(n)]
                    deckDat.ContainedObjects[deckIndex] = cardDat
                    n = n + 1
                    deckIndex = deckIndex + 1
                end
            end
        end
    end

    -- Y (the 2nd component) is card/deck *thickness* in TTS's own axis
    -- convention, and it's a dead end: confirmed live across three separate
    -- methods (spawnObjectData's inline scale here, Object.setScale after
    -- the fact, and group()+setScale on an assembled deck) that TTS silently
    -- clamps it back to 1 for CardCustom-derived objects every time, no
    -- error either. TTS's own "thickness" attribute only exists for Custom
    -- Tiles, not cards/decks -- there's no scripting path to thicker cards
    -- here, so this stays 1. Only X/Z (card footprint) are actually
    -- adjustable.
    local cardScale = {2, 1, 2}

    if deckIndex > 1 then
        spawnObjectData({data = deckDat, position = deckPosition, rotation = deckRotation, scale = cardScale})
    end

    if leaderStats ~= nil then
        local leaderCardDat = BuildCardData(n, leaderStats)
        spawnObjectData({data = leaderCardDat, position = leaderPosition, rotation = leaderRotation, scale = cardScale})
    end

    return deckIndex - 1, leaderStats ~= nil
end

-- -----------------------------------------------------------------------------
-- Import pipeline
-- -----------------------------------------------------------------------------

-- Runs `jobs` (each a function(done) that must call done() when finished),
-- staggered as a courtesy to the API's informal "don't do an insane amount
-- of calls" ask, and calls onAllDone() once every job has finished. A no-op
-- if `jobs` is empty.
local function RunFetchJobs(jobs, onAllDone)
    if #jobs == 0 then
        onAllDone()
        return
    end

    local remaining = #jobs
    local function JobDone()
        remaining = remaining - 1
        if remaining == 0 then
            onAllDone()
        end
    end

    for i, job in ipairs(jobs) do
        Wait.time(function() job(JobDone) end, (i - 1) * 0.3)
    end
end

-- One fetch job per distinct card ID not already cached.
local function BuildFetchJobs(entries)
    local seen = {}
    local jobs = {}
    for _, entry in ipairs(entries) do
        if not seen[entry.cardID] and CardLookup.GetCard(entry.cardID) == nil then
            seen[entry.cardID] = true
            table.insert(jobs, function(done)
                CardLookup.FetchCard(entry.cardID, function(ok, err)
                    if not ok then broadcastToAll("[Card Importer] " .. err, {1, 0.6, 0.2}) end
                    done()
                end)
            end)
        end
    end
    return jobs
end

function OnImportClicked(player)
    local entries, warnings = ParseDecklistText(lastDecklistText)
    for _, warning in ipairs(warnings) do
        broadcastToAll("[Card Importer] " .. warning, {1, 0.6, 0.2})
    end

    if #entries == 0 then
        broadcastToAll("[Card Importer] No valid decklist lines found.", {1, 0.3, 0.3})
        return
    end

    UI.setAttribute(PANEL_ID, "active", "false")

    local jobs = BuildFetchJobs(entries)
    if #jobs > 0 then
        broadcastToAll("[Card Importer] Fetching " .. #jobs .. " card(s)...", {0.6, 0.6, 1})
    end

    RunFetchJobs(jobs, function()
        FinishImport(entries, player)
    end)
end

function FinishImport(entries, player)
    local missing = {}
    local spawnedCount, spawnedLeader = BuildSpawnDeckData(entries, missing, player)
    SpawnDonDeck(player)

    for _, cardID in ipairs(missing) do
        broadcastToAll("[Card Importer] Could not find card data for \"" .. cardID .. "\".", {1, 0.3, 0.3})
    end

    if spawnedCount > 0 or spawnedLeader then
        broadcastToAll("[Card Importer] Spawned " .. spawnedCount .. " card(s)"
            .. (spawnedLeader and " plus Leader." or "."), {0.4, 1, 0.4})
    else
        broadcastToAll("[Card Importer] Nothing was spawned.", {1, 0.3, 0.3})
    end
end

-- -----------------------------------------------------------------------------
-- UI
--
-- The import form lives entirely in a screen-space modal (self.UI, TTS's
-- per-object XML UI), not drawn onto the object's physical surface -- that
-- was the original design, and it covered the whole card with no exposed
-- margin to grab/move/delete it (same mistake as the DoNothing-button-sized
-- margins elsewhere; here the whole face was the "button"). The object
-- itself now carries just one small button that opens the modal, matching
-- the inherited "rikrassen" importer's own UX (scripts/objects/
-- _b_rikrassen_s__b__MTG Deck_Draft_Cube Importer_*.lua: one small
-- createButton calling UI.setXmlTable to show its modal).
-- -----------------------------------------------------------------------------

local function BuildUI()
    return {
        {
            tag = "Panel",
            attributes = {
                id = PANEL_ID,
                active = "false",
                rectAlignment = "MiddleCenter",
                width = "1000",
                height = "750",
                color = "#1a1a1aee",
                padding = "45 45 45 45"
            },
            children = {
                {
                    tag = "VerticalLayout",
                    attributes = {
                        width = "910",
                        height = "660",
                        spacing = "20",
                        childForceExpandWidth = "true",
                        childForceExpandHeight = "false"
                    },
                    children = {
                        {
                            tag = "Text",
                            value = "One Piece TCG Card Importer",
                            attributes = {
                                fontSize = "28",
                                color = "#FFFFFF",
                                alignment = "MiddleCenter",
                                minHeight = "50",
                                preferredHeight = "50",
                                flexibleHeight = "0",
                                flexibleWidth = "1"
                            }
                        },
                        {
                            tag = "InputField",
                            attributes = {
                                id = INPUT_ID,
                                placeholder = "Paste decklist here (one \"4xOP16-064\" line per entry)",
                                characterLimit = "20000",
                                multiLine = "true",
                                textAlignment = "UpperLeft",
                                fontSize = "20",
                                minHeight = "300",
                                flexibleHeight = "1",
                                flexibleWidth = "1",
                                onValueChanged = self.getGUID() .. "/ReceiveDecklistInput"
                            }
                        },
                        {
                            tag = "HorizontalLayout",
                            attributes = {
                                minHeight = "20",
                                preferredHeight = "40",
                                flexibleHeight = "0",
                                flexibleWidth = "1",
                                spacing = "10",
                                childForceExpandWidth = "true",
                                childForceExpandHeight = "false"
                            },
                            children = {
                                {
                                    tag = "Button",
                                    value = "IMPORT DECK",
                                    attributes = {
                                        onClick = self.getGUID() .. "/OnImportClicked",
                                        color = "#1E5296",
                                        textColor = "#FFFFFF",
                                        fontSize = "22",
                                        minHeight = "60",
                                        preferredHeight = "60",
                                        flexibleHeight = "0",
                                        flexibleWidth = "1"
                                    }
                                },
                                {
                                    tag = "Button",
                                    value = "CLEAR CACHE",
                                    attributes = {
                                        onClick = self.getGUID() .. "/OnClearCacheClicked",
                                        color = "#592033",
                                        textColor = "#FFFFFF",
                                        fontSize = "22",
                                        minHeight = "60",
                                        preferredHeight = "60",
                                        flexibleHeight = "0",
                                        flexibleWidth = "1"
                                    }
                                },
                                {
                                    tag = "Button",
                                    value = "CLOSE",
                                    attributes = {
                                        onClick = self.getGUID() .. "/OnCloseImporterClicked",
                                        color = "#444444",
                                        textColor = "#FFFFFF",
                                        fontSize = "22",
                                        minHeight = "60",
                                        preferredHeight = "60",
                                        flexibleHeight = "0",
                                        flexibleWidth = "1"
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
end

function ReceiveDecklistInput(player, value, id)
    lastDecklistText = value
end

function OnClearCacheClicked()
    CardLookup.cache = {}
    broadcastToAll("[Card Importer] Cache cleared.", {0.6, 0.6, 1})
end

-- Calling self.UI.setXmlTable/setValue from onLoad's own call path threw a
-- native null-reference that even pcall couldn't catch (confirmed live --
-- checkpoints showed it dying mid-call, not returning a caught error), and
-- that reproduced at every delay tried (1 frame, 2s, pcall-and-retry).
-- Confirmed separately (via exec against an already-settled object) that
-- this exact XML table is valid and applies instantly once the object has
-- genuinely finished loading -- so this isn't a malformed structure, it's
-- onLoad's own call path specifically. Sidestep it entirely: the panel
-- starts closed anyway, so there's no reason to touch the UI until the
-- player actually clicks the open button -- by which point the game has
-- definitely finished loading and there's no race left to guess around.
--
-- Uses the GLOBAL UI (UI.setXmlTable), not self.UI: self.UI renders as a
-- world-space panel anchored near the object itself (tracks it around the
-- table) -- confirmed live, it's not a screen-space modal at all. The
-- reference importer's floating dialog comes specifically from using the
-- global UI instead.
local uiBuilt = false

function OnOpenImporterClicked()
    if uiBuilt then
        UI.setAttribute(PANEL_ID, "active", "true")
        return
    end

    -- First open only: setXmlTable doesn't finish instantiating a
    -- structure this size (Panel > Text/InputField/HorizontalLayout[3
    -- Buttons]) synchronously -- touching any element by id immediately
    -- after it (setValue, or even setAttribute on the Panel itself)
    -- threw an uncatchable native null-reference. One frame of separation
    -- is enough; confirmed once built, every later open (the `if uiBuilt`
    -- branch above) can touch it immediately with no issue.
    UI.setXmlTable(BuildUI())
    uiBuilt = true
    Wait.frames(function()
        UI.setValue(INPUT_ID, lastDecklistText)
        UI.setAttribute(PANEL_ID, "active", "true")
    end, 1)
end

function OnCloseImporterClicked()
    UI.setAttribute(PANEL_ID, "active", "false")
end

function CreateAll()
    self.createButton({
        label = "OPEN\nIMPORTER",
        tooltip = "Open the One Piece TCG Card Importer",
        click_function = "OnOpenImporterClicked",
        function_owner = self,
        position = {0, 0.3, 0},
        height = 400,
        width = 400,
        font_size = 60,
        color = {0.12, 0.32, 0.58},
        font_color = {1, 1, 1}
    })
end

function onLoad(savedData)
    if savedData ~= nil and savedData ~= "" then
        local ok, decoded = pcall(function() return JSON.decode(savedData) end)
        if ok and type(decoded) == "table" then
            if type(decoded.cache) == "table" then
                CardLookup.cache = decoded.cache
            end
            if type(decoded.lastDecklistText) == "string" then
                lastDecklistText = decoded.lastDecklistText
            end
        end
    end

    CreateAll()
end

function onSave()
    return JSON.encode({
        cache = CardLookup.cache,
        lastDecklistText = lastDecklistText
    })
end
