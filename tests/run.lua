--[[
The addon's tests.

Run them with a Lua interpreter from the repository root:

    lua5.4 addon/tests/run.lua [output file]

They load the real addon files against the stub client in stub.lua, fire the
events the recorders listen for, and assert the shape of EverythingWoWDB: the
contract's field names, the payload spellings, the caps, the ring buffer, the
de-duplication rule, and the byte trimming. The last test serializes the
table the way the game's own SavedVariables writer does and writes it to the
output file, which defaults to the scratchpad path below. addon/tests/
check-file.mjs then reads that file with the site's own parser.
]]

local root = (arg and arg[0] or "addon/tests/run.lua"):gsub("tests/run%.lua$", "")
local outputPath = (arg and arg[1]) or "/tmp/EverythingWoW.lua"

package.path = root .. "tests/?.lua;" .. package.path
local stub = dofile(root .. "tests/stub.lua")

local passed, failed = 0, 0
local function check(name, condition, detail)
  if condition then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or ""))
  end
end
local function equal(name, actual, expected)
  check(name, actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

stub.Install(_G)

local FILES = { "Core", "Units", "Objects", "Quests", "Vendor", "Loot", "Snapshot", "Auction" }

--[[ Loads every addon file fresh into a new table, the way the game loads
     them once at login: EW.Client and EW.Caps are computed as Core.lua
     loads, and the tooltip hook and the combat log registration run, or do
     not, in that same pass. Used to prove the capability gates against a
     client set before any file is loaded, which a single already loaded EW
     instance cannot be re-pointed at. ]]
local function LoadFreshAddon(project, build)
  _G.WOW_PROJECT_ID = project
  stub.state.build = build
  stub.state.project = project
  stub.ResetFrames()
  _G.EverythingWoWDB = nil
  local fresh = {}
  for _, name in ipairs(FILES) do
    local chunk = assert(loadfile(root .. "EverythingWoW/" .. name .. ".lua"))
    chunk("EverythingWoW", fresh)
  end
  return fresh
end

local EW = LoadFreshAddon(1, { "12.1.0", "60000", "Sep 17 2026", 120100 })

stub.state.units.player = { guid = "Player-3888-0A1B2C3E", name = "Thalos", level = 80, isPlayer = true }

local function db() return EW.Database() end
local function clear()
  EW.SlashCommand("clear")
  stub.state.printed = {}
end
local function observations() return db().observations end
local function last() local list = observations() return list[#list] end

-- The version key.
equal("version key is retail on the mainline project", EW.VersionKey(), "retail")
_G.WOW_PROJECT_ID = 2
equal("version key is classic era off the mainline project", EW.VersionKey(), "classic_era")
stub.state.hardcore = true
equal("version key is hardcore on a hardcore realm", EW.VersionKey(), "hardcore")
stub.state.hardcore = false
_G.WOW_PROJECT_ID = 1

-- The saved table.
_G.EverythingWoWDB = nil
local saved = db()
equal("schema is the number one", saved.schema, 1)
equal("version is the version key", saved.version, "retail")
equal("client rides beside version as its own field", saved.client, "retail")
equal("addon is the addon version", saved.addon, "0.2.2")
equal("patch comes from GetBuildInfo", saved.patch, "12.1.0")
check("observations is a list", type(saved.observations) == "table")
equal("dropped starts at zero", saved.dropped, 0)

-- The NPC and rare recorder.
clear()
stub.state.units.nameplate1 = {
  guid = "Creature-0-3888-0-11-2914-000136DF91",
  name = "Kobold Vermin", level = 3, reaction = 2, classification = "normal",
}
stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
local npc = last()
equal("npc kind", npc.kind, "npc")
equal("npc subject", npc.subject, "npc")
equal("npc id comes from the guid", npc.id, 2914)
equal("map id", npc.map, 84)
equal("x is a fraction from the top left", npc.x, 0.4213)
equal("y is a fraction from the top left", npc.y, 0.6187)
equal("t is a unix timestamp in seconds", npc.t, 1700000000)
equal("npc payload holds the name", npc.payload.name, "Kobold Vermin")
equal("npc payload holds the level", npc.payload.level, 3)
equal("npc payload holds the reaction", npc.payload.reaction, 2)

-- The de-duplication rule.
local before = #observations()
stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
equal("the same sighting inside five minutes is not written twice", #observations(), before)
stub.state.time = stub.state.time + 299
stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
equal("still not written at four minutes and fifty nine seconds", #observations(), before)
stub.state.time = stub.state.time + 2
stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
equal("written again past five minutes", #observations(), before + 1)

-- A rare, and a player.
clear()
stub.state.units.mouseover = {
  guid = "Creature-0-3888-0-11-50052-000136DF92", name = "Vrykul Skeleton", level = 32,
  reaction = 2, classification = "rare",
}
stub.Fire("UPDATE_MOUSEOVER_UNIT")
equal("a rare is recorded under the rare kind", last().kind, "rare")
equal("a rare carries the rare subject", last().subject, "rare")
local afterRare = #observations()
stub.state.units.mouseover = { guid = "Player-3888-0A1B2C3D", name = "Someone", isPlayer = true }
stub.Fire("UPDATE_MOUSEOVER_UNIT")
equal("another player is never recorded", #observations(), afterRare)

-- Quests.
clear()
stub.state.units.npc = { guid = "Creature-0-3888-0-11-1234-000136DF93", name = "Marshal Dughan" }
stub.state.questId = 62
stub.state.questTitle = "A Threat Within"
stub.Fire("QUEST_DETAIL")
local questStart = last()
equal("quest start kind", questStart.kind, "quest_start")
equal("quest start subject", questStart.subject, "quest")
equal("quest start id is the quest id", questStart.id, 62)
equal("quest start names the giver", questStart.payload.npc_id, 1234)
stub.Fire("QUEST_COMPLETE")
equal("quest end kind", last().kind, "quest_end")

-- The vendor recorder.
clear()
stub.state.merchant = {}
for index = 1, 120 do
  stub.state.merchant[index] = { id = 4000 + index, name = "Stock " .. index, price = 1000 + index }
end
stub.state.merchant[1].costCount = 1
stub.state.merchant[1].currency = 1166
stub.Fire("MERCHANT_SHOW")
local vendor = last()
equal("vendor kind", vendor.kind, "vendor")
equal("vendor subject", vendor.subject, "vendor")
equal("vendor id is the npc", vendor.id, 1234)
check("a visit reads at most one hundred items", #vendor.payload.items <= 100, #vendor.payload.items)
equal("a vendor item carries id", vendor.payload.items[1].id, 4001)
equal("a vendor item carries price in copper", vendor.payload.items[1].price, 1001)
equal("a vendor item carries the currency where there is one", vendor.payload.items[1].currency, 1166)
check("the vendor payload is inside the four thousand byte cap", EW.JsonBytes(vendor.payload) <= 4000, EW.JsonBytes(vendor.payload))
equal("a vendor item carries the currency amount", vendor.payload.items[1].currency_q, 1)

-- The same window on a client that still has the positional global, which is
-- the Classic Era shape. Retail has C_MerchantFrame.GetItemInfo and no global
-- at all, and reading only the global is what wrote a live file with ids and
-- no prices in 0.1.0.
clear()
stub.state.merchantApi = "legacy"
stub.Fire("MERCHANT_SHOW")
equal("the positional merchant api is read too", last().payload.items[1].price, 1001)
equal("the positional merchant api gives the stack size", last().payload.items[2].q, nil)
stub.state.merchantApi = "modern"

-- An item bought with a currency: no copper price, an extended cost, and a
-- currency that has to be recorded beside the zero rather than instead of it.
clear()
stub.state.merchant = {
  { id = 210655, name = "Token Item", price = 0, costCount = 1, currency = 3008, currencyAmount = 25 },
  { id = 210656, name = "Stack Item", price = 400, quantity = 5 },
}
stub.Fire("MERCHANT_SHOW")
local extended = last().payload.items
equal("a zero copper price is written and not dropped", extended[1].price, 0)
equal("an extended cost records the currency", extended[1].currency, 3008)
equal("an extended cost records how much of it", extended[1].currency_q, 25)
equal("a copper price is still copper", extended[2].price, 400)
equal("a stack of five is recorded", extended[2].q, 5)
equal("an item bought with copper has no currency", extended[2].currency, nil)

-- Loot, with a kill.
clear()
stub.state.units.target = { guid = "Creature-0-3888-0-11-2914-000136DF95" }
stub.state.combatLog = { subevent = "UNIT_DIED", destGuid = "Creature-0-3888-0-11-2914-000136DF95" }
stub.Fire("COMBAT_LOG_EVENT_UNFILTERED")
equal("a kill alone writes nothing yet", #observations(), 0)
stub.state.loot = {
  { id = 2589, quantity = 2, source = "Creature-0-3888-0-11-2914-000136DF95" },
  { text = "1 Gold 20 Silver 5 Copper", source = "Creature-0-3888-0-11-2914-000136DF95" },
}
stub.Fire("LOOT_OPENED")
local loot = last()
equal("loot kind", loot.kind, "loot")
equal("loot subject is the source type", loot.subject, "npc")
equal("loot id is the source id", loot.id, 2914)
equal("loot items are spelled items", type(loot.payload.items), "table")
equal("a loot item is spelled id", loot.payload.items[1].id, 2589)
equal("a loot item quantity is spelled q", loot.payload.items[1].q, 2)
equal("loot names the source type", loot.payload.source_type, "npc")
equal("loot names the source id", loot.payload.source_id, 2914)
equal("loot counts one kill", loot.payload.kills, 1)
equal("gold is written as gold and not as an item", loot.payload.items[2].gold, 12005)

-- A kill nobody looted still counts.
clear()
stub.state.combatLog = { subevent = "UNIT_DIED", destGuid = "Creature-0-3888-0-11-2914-000136DF96" }
stub.state.units.target = { guid = "Creature-0-3888-0-11-2914-000136DF96" }
stub.Fire("COMBAT_LOG_EVENT_UNFILTERED")
stub.state.time = stub.state.time + 61
EW.FlushKills(false)
local unlooted = last()
equal("an unlooted kill is one loot observation", unlooted.kind, "loot")
equal("an unlooted kill holds no items", #unlooted.payload.items, 0)
equal("an unlooted kill still counts one kill", unlooted.payload.kills, 1)

-- 0.2.2: a loot window whose slot carries no source guid at all, which
-- GetLootSourceInfo returning nothing for a slot always looks like on every
-- client, not only a combatLog-off one. The items are still recorded rather
-- than thrown away, with the source marked unknown.
clear()
stub.state.loot = { { id = 2591, quantity = 3 } }
stub.Fire("LOOT_OPENED")
local unknownSource = last()
equal("an unplaceable loot source is still recorded, not dropped", unknownSource.kind, "loot")
equal("its subject is marked unknown rather than npc or object", unknownSource.subject, "unknown")
equal("it has no subject id to guess at", unknownSource.id, nil)
equal("its item is still held", unknownSource.payload.items[1].id, 2591)
equal("its item quantity is still held", unknownSource.payload.items[1].q, 3)
equal("its payload also marks the source unknown", unknownSource.payload.source_type, "unknown")
equal("it still counts as one opening", unknownSource.payload.kills, 1)

-- Objects and nodes.
clear()
equal("an object id read from a game object guid is exact",
  EW.RecordObjectFromGuid("GameObject-0-3888-0-11-1731-000136DF97", true), true)
local node = last()
equal("a node is recorded under the object kind", node.kind, "object")
equal("a node carries the node subject", node.subject, "node")
equal("a node id comes from the guid", node.id, 1731)
local skippedBefore = db().skipped
EW.RecordCursorObject()
equal("a tooltip that is not a world object is not a skip", db().skipped, skippedBefore)
equal("a tooltip that is not a world object is counted as ignored", db().ignores.no_world_cursor, 1)

--[[
What the three counters mean. The live 0.1.0 sample reported 802 skipped in a
few minutes, which read as though the addon were losing sightings by the
hundred; almost all of it was tooltips over bag items, nameplates on other
players, and sightings the five minute window already held. Only a subject the
addon could have placed and could not is a loss.
]]
clear()
stub.state.units.nameplate2 = { guid = "Player-3888-0A1B2C40", name = "Someone", isPlayer = true }
stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
equal("a nameplate on another player is not a skip", db().skipped, 0)
equal("a nameplate on another player is counted as a player", db().ignores.player, 1)

stub.state.units.pet = { guid = "Pet-0-3888-0-11-165189-0200136DFA", name = "Fluffy", playerControlled = true }
stub.state.units.nameplate3 = { guid = "Pet-0-3888-0-11-165189-0200136DFA", name = "Fluffy", playerControlled = true }
stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
equal("the player's own pet is not a skip", db().skipped, 0)
equal("the player's own pet is counted as a pet", db().ignores.pet, 1)

stub.state.units.nameplate4 = {
  guid = "Vehicle-0-3888-0-11-32906-000136DFB1", name = "Someone's Chopper", playerControlled = true,
}
stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate4")
equal("a player's vehicle is counted as a vehicle", db().ignores.vehicle, 1)

stub.state.units.nameplate5 = {
  guid = "Creature-0-3888-0-11-2914-000136DFB2", name = "Kobold Vermin", level = 3, reaction = 2,
}
stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate5")
stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate5")
equal("a sighting inside the window is deduped", db().dedupes.npc, 1)
equal("a sighting inside the window is not a skip", db().skipped, 0)

stub.state.position = nil
stub.state.units.mouseover = { guid = "Creature-0-3888-0-11-4000-000136DFB3", name = "Placeless" }
stub.Fire("UPDATE_MOUSEOVER_UNIT")
equal("a creature the client will not place is the one real skip", db().skips.no_position, 1)
equal("and it is the only skip", db().skipped, 1)
stub.state.map = nil
stub.state.units.mouseover = { guid = "Creature-0-3888-0-11-4001-000136DFB4", name = "Mapless" }
stub.Fire("UPDATE_MOUSEOVER_UNIT")
equal("a creature on no map is a skip with its own reason", db().skips.no_map, 1)
stub.state.map = 84
stub.state.position = { x = 0.4213, y = 0.6187 }

stub.state.printed = {}
EW.SlashCommand("status")
local statusText = table.concat(stub.state.printed, "\n")
check("status prints the skip reasons", statusText:find("no position", 1, true) ~= nil, statusText)
check("status prints the dedupe count", statusText:find("deduped", 1, true) ~= nil, statusText)
check("status prints the ignore reasons", statusText:find("player unit", 1, true) ~= nil, statusText)

--[[
The character snapshot, and when it is taken. The live 0.1.0 sample held two
of them a hundred seconds apart, identical except that the first had an empty
currency list because it fired before the client had loaded one. One snapshot
a session on login, once the client answers, and after that only on demand or
on a real change.
]]
clear()
stub.state.inventory = {}
stub.state.currencies = {}
stub.Fire("PLAYER_ENTERING_WORLD", true, false)
stub.RunTimers(1)
equal("the login snapshot waits for a client with nothing loaded", #observations(), 0)
stub.state.inventory = { [1] = 19019, [5] = 16963, [16] = 17182 }
stub.state.currencies = {
  { id = 1155, name = "Ancient Mana", quantity = 5 },
  { id = 2032, name = "Trader's Tender", quantity = 4215 },
}
stub.RunTimers(1)
equal("the login snapshot is written once the client answers", #observations(), 1)
equal("the login snapshot carries the currencies", #last().payload.currencies, 2)
equal("a currency carries its id", last().payload.currencies[1].id, 1155)
stub.Fire("PLAYER_ENTERING_WORLD", false, true)
stub.RunTimers()
equal("a reload writes no second snapshot in the same session", #observations(), 1)
equal("nothing changed, so no snapshot is written", EW.TakeSnapshot(), false)
stub.state.time = stub.state.time + 3601
equal("an hour later with nothing changed still writes nothing", EW.TakeSnapshot(), false)
stub.state.units.player.level = 81
equal("an hour later with a level gained writes one", EW.TakeSnapshot(), true)
stub.state.time = stub.state.time + 3601
stub.state.inventory[1] = 19020
equal("an hour later with the gear changed writes one", EW.TakeSnapshot(), true)
equal("the same again inside the hour writes nothing", EW.TakeSnapshot(), false)
equal("the slash command takes one whenever it is asked", EW.TakeSnapshot(true), true)

clear()
stub.state.factions = {}
for index = 1, 400 do
  stub.state.factions[index] = { id = 60 + index, name = "Faction " .. index, standing = 4, value = 2100 }
end
equal("a snapshot is recorded", EW.TakeSnapshot(true), true)
local snapshot = last()
equal("snapshot kind", snapshot.kind, "character_snapshot")
equal("snapshot subject", snapshot.subject, "character")
equal("snapshot has no subject id", snapshot.id, nil)
equal("snapshot names the character", snapshot.payload.name, "Thalos")
equal("snapshot names the realm", snapshot.payload.realm, "Tichondrius")
equal("gear is stored as an item string", snapshot.payload.gear[1].item, "item:19020:6229::::::::80:::::")
check("no gear string carries a pipe", snapshot.payload.gear[1].item:find("|") == nil)
check("reputations are capped", #snapshot.payload.reputations <= 100, #snapshot.payload.reputations)
check("the snapshot payload is inside the sixty four thousand byte cap",
  EW.JsonBytes(snapshot.payload) <= 64000, EW.JsonBytes(snapshot.payload))
check("professions are read", #snapshot.payload.professions > 0)

-- The auction recorder.
clear()
equal("auction is on for this fresh retail instance", EW.Caps.auction, true)
stub.state.auction = {}
for index = 1, 120 do
  stub.state.auction[index] = { id = 2447, count = 5, buyout = 5000 + index }
end
_G.C_AuctionHouse = { Stub = true }
equal("auction scanning does nothing where Blizzard has an auction api", EW.OnAuctionListUpdate(), false)
_G.C_AuctionHouse = nil
equal("auction scanning runs where there is none", EW.OnAuctionListUpdate(), true)
local auctionRows = 0
for _, observation in ipairs(observations()) do
  if observation.kind == "auction" then auctionRows = auctionRows + #observation.payload.items end
end
equal("every auction row is recorded", auctionRows, 120)
local auction = observations()[1]
equal("an auction row carries the item id", auction.payload.items[1].id, 2447)
equal("an auction row carries the quantity", auction.payload.items[1].q, 5)
equal("an auction row carries the unit price in copper", auction.payload.items[1].unit, 1000)
for _, observation in ipairs(observations()) do
  check("an auction payload is inside its cap", EW.JsonBytes(observation.payload) <= 4000)
end

-- The ring buffer.
clear()
for index = 1, 5100 do
  EW.Record("npc", "npc", 900000 + index, 84, 0.5, 0.5, { level = 1 })
end
equal("the buffer holds five thousand observations", #observations(), 5000)
equal("the oldest are dropped and counted", db().dropped, 100)
equal("the oldest is gone", observations()[1].id, 900101)

-- Byte trimming, on a payload nothing else would cap.
clear()
local items = {}
for index = 1, 400 do items[index] = { id = 100000 + index, price = 123456, currency = 1166 } end
EW.Record("vendor", "vendor", 4242, 84, 0.1, 0.1, { items = items })
local trimmed = last()
check("an oversized payload is trimmed to its cap", EW.JsonBytes(trimmed.payload) <= 4000, EW.JsonBytes(trimmed.payload))
check("trimming drops entries from the end", #trimmed.payload.items < 400)
equal("the first entry survives trimming", trimmed.payload.items[1].id, 100001)

-- The slash command.
clear()
EW.SlashCommand("status")
check("status prints", #stub.state.printed > 0)
stub.state.printed = {}
EW.Record("npc", "npc", 12, 84, 0.2, 0.2, nil)
EW.SlashCommand("clear")
equal("clear empties the buffer", #observations(), 0)
EW.SlashCommand("snapshot")
equal("snapshot records one observation", #observations(), 1)
equal("snapshot is the snapshot kind", last().kind, "character_snapshot")

--[[
The client capability gates. Each client is loaded fresh, because
EW.Client and EW.Caps are built once when Core.lua loads and the tooltip
hook and the combat log registration in the other files run in that same
pass, before any event can fire. A single already loaded instance cannot be
re-pointed at a different client, so this proves the gates by loading the
real files four times over: Retail, Classic Era, Forever, and a client the
table does not recognize at all.
]]
_G.GameTooltip.OnShow = nil
local retailGate = LoadFreshAddon(1, { "12.1.0", "60000", "Sep 17 2026", 120100 })
equal("retail reads as the retail client", retailGate.Client.key, "retail")
equal("retail's world cursor capability is on", retailGate.Caps.worldCursor, true)
equal("retail's unit guid capability is on", retailGate.Caps.unitGuid, true)
equal("retail's combat log capability is on", retailGate.Caps.combatLog, true)
equal("retail's auction capability is on", retailGate.Caps.auction, true)
check("retail installs the tooltip hook", _G.GameTooltip.OnShow ~= nil)

_G.GameTooltip.OnShow = nil
local classicGate = LoadFreshAddon(2, { "1.15.9", "50000", "Sep 17 2026", 11509 })
equal("a 1.15 build reads as classic era", classicGate.Client.key, "classic_era")
equal("classic era's world cursor capability is off", classicGate.Caps.worldCursor, false)
equal("classic era's unit guid capability is on", classicGate.Caps.unitGuid, true)
equal("classic era's combat log capability is on", classicGate.Caps.combatLog, true)
equal("classic era's auction capability is on, its own scan being the only path", classicGate.Caps.auction, true)
check("classic era never installs the tooltip hook", _G.GameTooltip.OnShow == nil)

_G.GameTooltip.OnShow = nil
-- Build 1.60.1 is the owner's own reading, on what the note expects to be
-- the shared Classic project id. 0.2.2 settles this row on the owner's own
-- probe transcript: NAME_PLATE_UNIT_ADDED, UPDATE_MOUSEOVER_UNIT, and
-- PLAYER_TARGET_CHANGED came back allowed and a manual /ewow cap on for
-- worldCursor and unitGuid raised no alert, while COMBAT_LOG_EVENT_UNFILTERED
-- and AUCTION_ITEM_LIST_UPDATE came back refused.
local foreverGate = LoadFreshAddon(2, { "1.60.1", "70000", "Nov 4 2026", 16001 })
equal("a 1.60 build on the classic project id reads as forever", foreverGate.Client.key, "forever")
equal("forever's world cursor capability defaults on, from the owner's probe",
  foreverGate.Caps.worldCursor, true)
equal("forever's unit guid capability defaults on, from the owner's probe",
  foreverGate.Caps.unitGuid, true)
equal("forever's combat log capability defaults off, the probe having refused it",
  foreverGate.Caps.combatLog, false)
equal("forever's auction capability defaults off, the probe having refused it too",
  foreverGate.Caps.auction, false)
check("forever installs the tooltip hook, world cursor now defaulting on",
  _G.GameTooltip.OnShow ~= nil)

-- Firing a nameplate event on Forever now writes an npc observation, because
-- unitGuid defaults on there since 0.2.2. The combat log and auction
-- listeners are still never registered at all, because their capabilities
-- default off, and the capability is checked before the client is ever
-- asked anything, not after.
do
  stub.state.units.nameplate1 = {
    guid = "Creature-0-3888-0-11-2914-000136DF91", name = "Kobold Vermin",
    level = 3, reaction = 2,
  }
  stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
  equal("unit guid being on for forever writes an npc observation",
    #foreverGate.Database().observations, 1)
  equal("the observation is attributed to the right creature id",
    foreverGate.Database().observations[1].id, 2914)
  equal("nothing is skipped for it", foreverGate.Database().skipped, 0)

  stub.state.units.target = { guid = "Creature-0-3888-0-11-2914-000136DF91" }
  stub.state.combatLog = { subevent = "UNIT_DIED", destGuid = "Creature-0-3888-0-11-2914-000136DF91" }
  stub.Fire("COMBAT_LOG_EVENT_UNFILTERED")
  equal("the combat log listener is still never registered on forever",
    #foreverGate.Database().observations, 1)

  stub.Fire("AUCTION_ITEM_LIST_UPDATE")
  equal("the auction listener is never registered on forever either",
    #foreverGate.Database().observations, 1)

  local before = foreverGate.Database().ignored
  equal("the world cursor path returns false where the stub gives no client function",
    foreverGate.RecordCursorObject(), false)
  equal("and it is counted as ignored either way",
    foreverGate.Database().ignored, before + 1)
end

-- 0.2.2: with auction off, Auction.lua registers no AUCTION_ITEM_LIST_UPDATE
-- listener at all, and instead announces once, at the next
-- PLAYER_ENTERING_WORLD, that the auction recorder is idle.
do
  stub.state.printed = {}
  stub.Fire("PLAYER_ENTERING_WORLD", false, true)
  local text = table.concat(stub.state.printed, "\n")
  check("the idle auction recorder announces itself once at login",
    text:find("Auction recording is off", 1, true) ~= nil, text)
  stub.state.printed = {}
  stub.Fire("PLAYER_ENTERING_WORLD", false, true)
  equal("it does not announce itself a second time in the same session",
    #stub.state.printed, 0)
end

--[[
ADDON_ACTION_FORBIDDEN and ADDON_ACTION_BLOCKED. Fired at the Forever
instance built above, since that is the one client where these are expected.
This runs before the unknown client scenario below, because that scenario's
own LoadFreshAddon resets the frame list and would otherwise take Forever's
frame out of stub.Fire's reach.
]]
do
  equal("no forbidden action is recorded before one fires",
    foreverGate.Database().lastForbidden, nil)
  stub.Fire("ADDON_ACTION_FORBIDDEN", "SomeOtherAddon", "UnitGUID")
  equal("a report naming a different addon is not recorded",
    foreverGate.Database().lastForbidden, nil)

  stub.Fire("ADDON_ACTION_FORBIDDEN", "EverythingWoW", "UnitGUID")
  local forbidden = foreverGate.Database().lastForbidden
  check("a report naming this addon is recorded", forbidden ~= nil)
  equal("the record names the reported function", forbidden.fn, "UnitGUID")
  equal("the record names the client", forbidden.client, "forever")
  equal("the record names the build", forbidden.build, "1.60.1")
  equal("the matching capability is turned off for the session",
    foreverGate.Caps.unitGuid, false)
  equal("an unrelated capability is left alone",
    foreverGate.Caps.combatLog, false)
  check("one line is printed to chat", #stub.state.printed > 0)
end

-- status prints the client, the capabilities, and the last forbidden record.
-- This has to read foreverGate's own saved file before anything else reloads
-- the addon: EverythingWoWDB is one global, the same one the real client
-- would give a single addon instance, so a later LoadFreshAddon call resets
-- it out from under whichever instance's data was read last.
do
  stub.state.printed = {}
  foreverGate.SlashCommand("status")
  local text = table.concat(stub.state.printed, "\n")
  check("status prints the client key", text:find("forever", 1, true) ~= nil, text)
  check("status prints the capability table", text:find("capabilities:", 1, true) ~= nil, text)
  check("status prints the last forbidden action", text:find("last forbidden action", 1, true) ~= nil, text)
  check("status names the reported function", text:find("UnitGUID", 1, true) ~= nil, text)
end

-- The owner's own alert names no function at all. Every restricted
-- capability that was still on is the one this addon can turn off in
-- response to a report it cannot otherwise place.
do
  local secondGate = LoadFreshAddon(2, { "1.15.9", "50000", "Sep 17 2026", 11509 })
  equal("classic era's world cursor capability starts off, as always",
    secondGate.Caps.worldCursor, false)
  check("classic era's other capabilities start on",
    secondGate.Caps.unitGuid and secondGate.Caps.combatLog and secondGate.Caps.auction)
  stub.Fire("ADDON_ACTION_BLOCKED", "EverythingWoW")
  check("a report naming no function turns every capability off",
    not secondGate.Caps.unitGuid and not secondGate.Caps.combatLog
      and not secondGate.Caps.worldCursor and not secondGate.Caps.auction)
  equal("the record still holds, with no function name",
    secondGate.Database().lastForbidden.fn, nil)
  equal("the record still names the event", secondGate.Database().lastForbidden.event, "ADDON_ACTION_BLOCKED")
end

-- An unrecognized client, project id and version string both unreadable, is
-- the most restrictive client there is, not the most permissive.
_G.GameTooltip.OnShow = nil
local unknownGate = LoadFreshAddon(99, { "", "0", "", nil })
equal("an unreadable client is the unknown key", unknownGate.Client.key, "unknown")
equal("an unknown client defaults the world cursor capability off", unknownGate.Caps.worldCursor, false)
equal("an unknown client defaults the unit guid capability off", unknownGate.Caps.unitGuid, false)
equal("an unknown client defaults the combat log capability off", unknownGate.Caps.combatLog, false)
equal("an unknown client defaults the auction capability off", unknownGate.Caps.auction, false)
check("an unknown client never installs the tooltip hook", _G.GameTooltip.OnShow == nil)

--[[
0.2.1: Forever is read off the version string before WOW_PROJECT_ID is even
asked, because the owner's own build 1.60.1 session carried the mainline
project id, the same one Retail reports, not the Classic id 0.2.0 expected
Forever to share. A project id check run ahead of the version string, the
way 0.2.0 ran it, reads this exact session as Retail and switches every
capability back on, which is the misclassification 0.2.1 fixes. The
capability values themselves are 0.2.2's settled profile, the same as
foreverGate above; this only proves the client key itself is unaffected by
which project id the mainline reading carries.
]]
_G.GameTooltip.OnShow = nil
local foreverOnMainline = LoadFreshAddon(1, { "1.60.1", "70000", "Nov 4 2026", 16001 })
equal("a 1.60 build on the mainline project id still reads as forever",
  foreverOnMainline.Client.key, "forever")
equal("forever's world cursor capability is on on the mainline project id too",
  foreverOnMainline.Caps.worldCursor, true)
equal("forever's unit guid capability is on on the mainline project id too",
  foreverOnMainline.Caps.unitGuid, true)
equal("forever's combat log capability defaults off on the mainline project id too",
  foreverOnMainline.Caps.combatLog, false)
equal("forever's auction capability defaults off on the mainline project id too",
  foreverOnMainline.Caps.auction, false)
check("forever on the mainline project id installs the tooltip hook too",
  _G.GameTooltip.OnShow ~= nil)

--[[
Attributing a RegisterEvent refusal to the exact event being registered,
rather than to every capability at once. The owner's own alert named
"EverythingWoWFrame:RegisterEvent()", the method every recorder's own
registration goes through, not GetWorldCursor, UnitGUID, or
CombatLogGetCurrentEventInfo, so FUNCTION_CAPABILITY alone could never place
it and 0.2.0 turned every capability off in response. Run against a fresh
Retail instance, where every capability starts on, so a selective turn off
proves the fix rather than a client that already had everything off to
begin with. stub.state.forbiddenEvents makes the stub's own RegisterEvent
refuse one named event exactly the way the owner's alert read.
]]
do
  _G.GameTooltip.OnShow = nil
  stub.state.forbiddenEvents = { NAME_PLATE_UNIT_ADDED = true }
  local attributionGate = LoadFreshAddon(1, { "12.1.0", "60000", "Sep 17 2026", 120100 })
  stub.state.forbiddenEvents = {}

  local forbidden = attributionGate.Database().lastForbidden
  check("registering the refused event at load recorded a forbidden action", forbidden ~= nil)
  check("the record names the RegisterEvent method, not one of a capability's own functions",
    forbidden ~= nil and forbidden.fn ~= nil and forbidden.fn:find("RegisterEvent", 1, true) ~= nil,
    forbidden and forbidden.fn)
  equal("the record names the exact event that was mid registration",
    forbidden and forbidden.attemptedEvent, "NAME_PLATE_UNIT_ADDED")
  equal("only the capability that event feeds is turned off",
    attributionGate.Caps.unitGuid, false)
  equal("an unrelated capability is left on, unlike 0.2.0's every capability off fallback",
    attributionGate.Caps.worldCursor, true)
  equal("a second unrelated capability is also left on",
    attributionGate.Caps.combatLog, true)
  equal("a third unrelated capability is also left on",
    attributionGate.Caps.auction, true)
end

--[[
`/ewow probe`. Built against a fresh Retail instance with the combat log
listener refused, so the run proves both an allowed line and a refused
line in one pass, and drives EW.RunProbe's C_Timer.After chain with
stub.RunTimers the way the owner's own client would drive it one tick at a
time rather than all at once.
]]
do
  _G.GameTooltip.OnShow = nil
  stub.state.forbiddenEvents = { COMBAT_LOG_EVENT_UNFILTERED = true }
  local probeGate = LoadFreshAddon(1, { "12.1.0", "60000", "Sep 17 2026", 120100 })
  equal("the refused event's capability is already off from the load time attempt",
    probeGate.Caps.combatLog, false)

  stub.state.printed = {}
  probeGate.SlashCommand("probe")
  stub.RunTimers(#probeGate.PROBE_EVENTS + 5)
  local text = table.concat(stub.state.printed, "\n")
  check("the probe prints a line for an allowed event",
    text:find("NAME_PLATE_UNIT_ADDED: allowed", 1, true) ~= nil, text)
  check("the probe prints a line for the refused event",
    text:find("COMBAT_LOG_EVENT_UNFILTERED: refused", 1, true) ~= nil, text)
  check("the probe reports its own tally",
    text:find("11 allowed, 1 refused", 1, true) ~= nil, text)

  local probe = probeGate.Database().probe
  check("the probe result is written to the saved file", probe ~= nil)
  equal("the saved probe holds one result per probed event",
    probe and #probe.results, #probeGate.PROBE_EVENTS)
  local combatLogResult
  for _, result in ipairs(probe and probe.results or {}) do
    if result.event == "COMBAT_LOG_EVENT_UNFILTERED" then combatLogResult = result end
  end
  check("the saved probe holds the refused event's own result",
    combatLogResult ~= nil and combatLogResult.allowed == false)
  stub.state.forbiddenEvents = {}
end

--[[
0.2.2: the owner's own Forever probe transcript, reproduced. Combat log and
auction are both refused, which is what the owner's own build 1.60.1 session
showed for COMBAT_LOG_EVENT_UNFILTERED and AUCTION_ITEM_LIST_UPDATE.
0.2.1's probe called frame:UnregisterEvent unconditionally after a refused
RegisterEvent, and the owner's own transcript showed the client also
forbidding that call, naming "EverythingWoWFrame:UnregisterEvent()" with
EW.lastRegisterAttempt already cleared, so 0.2.1's handler could not place
it and fell back to turning every restricted capability off, worldCursor and
unitGuid included, on a client where the owner had proven both of those
safe. This proves the fix: a refused registration is never followed by an
unregister call at all, so no second forbidden report ever fires, and
worldCursor and unitGuid come through the probe exactly where the Forever
profile default put them.
]]
do
  _G.GameTooltip.OnShow = nil
  stub.state.forbiddenEvents = { COMBAT_LOG_EVENT_UNFILTERED = true, AUCTION_ITEM_LIST_UPDATE = true }
  local ownerGate = LoadFreshAddon(2, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  equal("the owner's own session reads as forever", ownerGate.Client.key, "forever")
  equal("world cursor starts on for forever", ownerGate.Caps.worldCursor, true)
  equal("unit guid starts on for forever", ownerGate.Caps.unitGuid, true)
  equal("combat log is already off, never being registered at load",
    ownerGate.Caps.combatLog, false)
  equal("auction is already off, never being registered at load",
    ownerGate.Caps.auction, false)

  stub.state.printed = {}
  ownerGate.SlashCommand("probe")
  stub.RunTimers(#ownerGate.PROBE_EVENTS + 5)
  local text = table.concat(stub.state.printed, "\n")

  check("the probe never reports a forbidden UnregisterEvent call",
    text:find("UnregisterEvent", 1, true) == nil, text)
  check("the probe reports combat log refused",
    text:find("COMBAT_LOG_EVENT_UNFILTERED: refused", 1, true) ~= nil, text)
  check("the probe reports auction refused",
    text:find("AUCTION_ITEM_LIST_UPDATE: refused", 1, true) ~= nil, text)
  check("the probe still tallies all twelve events, ten allowed and two refused",
    text:find("10 allowed, 2 refused", 1, true) ~= nil, text)

  equal("world cursor survives the probe, unlike the owner's own 0.2.1 session",
    ownerGate.Caps.worldCursor, true)
  equal("unit guid survives the probe too", ownerGate.Caps.unitGuid, true)
  equal("combat log stays off", ownerGate.Caps.combatLog, false)
  equal("auction stays off", ownerGate.Caps.auction, false)

  equal("a refused combat log registration is never followed by an unregister call",
    stub.state.unregisterAttempts["COMBAT_LOG_EVENT_UNFILTERED"], nil)
  equal("the same is true for the refused auction registration",
    stub.state.unregisterAttempts["AUCTION_ITEM_LIST_UPDATE"], nil)

  local ownerForbidden = ownerGate.Database().forbidden
  local combatLogReports, auctionReports = 0, 0
  for _, record in ipairs(ownerForbidden) do
    if record.attemptedEvent == "COMBAT_LOG_EVENT_UNFILTERED" then combatLogReports = combatLogReports + 1 end
    if record.attemptedEvent == "AUCTION_ITEM_LIST_UPDATE" then auctionReports = auctionReports + 1 end
  end
  equal("the combat log refusal is reported exactly once, not once more for a phantom unregister",
    combatLogReports, 1)
  equal("the same is true for the auction refusal",
    auctionReports, 1)

  local ownerProbe = ownerGate.Database().probe
  check("the probe result is saved", ownerProbe ~= nil)
  equal("the tally counts every probed event exactly once",
    ownerProbe and #ownerProbe.results, #ownerGate.PROBE_EVENTS)
  local seen, duplicate = {}, false
  for _, result in ipairs(ownerProbe and ownerProbe.results or {}) do
    if seen[result.event] then duplicate = true end
    seen[result.event] = true
  end
  check("no probed event is counted twice", not duplicate)

  stub.state.forbiddenEvents = {}
end

--[[
0.2.2: attributing an UnregisterEvent refusal to the exact event, the same
way EW.RegisterEvent already attributes a RegisterEvent refusal.
EW.UnregisterEvent, which the probe now calls only to undo a registration the
client actually allowed, sets EW.lastRegisterAttempt around the client call
exactly as EW.RegisterEvent does, so a report naming
"EverythingWoWFrame:UnregisterEvent()" -- which NamesRegisterEvent also
matches, "UnregisterEvent" carrying "RegisterEvent" inside it -- still places
the one capability that event feeds rather than falling back to every
capability at once. Run on Forever, where combatLog is not registered at
load, so the probe attempts it fresh and the client allows the registration
before refusing only the cleanup unregister.
]]
do
  stub.state.forbiddenUnregisterEvents = { COMBAT_LOG_EVENT_UNFILTERED = true }
  local unregisterGate = LoadFreshAddon(2, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  stub.state.printed = {}
  unregisterGate.SlashCommand("probe")
  stub.RunTimers(#unregisterGate.PROBE_EVENTS + 5)

  local forbidden = unregisterGate.Database().lastForbidden
  check("the unregister refusal is recorded", forbidden ~= nil)
  check("the record names the UnregisterEvent method",
    forbidden ~= nil and forbidden.fn ~= nil and forbidden.fn:find("UnregisterEvent", 1, true) ~= nil,
    forbidden and forbidden.fn)
  equal("the record names the exact event that was mid unregistration",
    forbidden and forbidden.attemptedEvent, "COMBAT_LOG_EVENT_UNFILTERED")
  equal("only the capability that event feeds is turned off",
    unregisterGate.Caps.combatLog, false)
  equal("an unrelated capability is left on, not wiped by the every-capability fallback",
    unregisterGate.Caps.worldCursor, true)
  equal("a second unrelated capability is also left on",
    unregisterGate.Caps.unitGuid, true)
  equal("a capability that was already off is left exactly there, not touched again",
    unregisterGate.Caps.auction, false)

  stub.state.forbiddenUnregisterEvents = {}
end

--[[ `/ewow cap <name> on|off`, the session only override for testing the
     tooltip hook and the GUID path once the probe has told the owner which
     events the client allows. ]]
do
  local capGate = LoadFreshAddon(1, { "12.1.0", "60000", "Sep 17 2026", 120100 })
  equal("world cursor starts on for a fresh retail instance", capGate.Caps.worldCursor, true)
  capGate.SlashCommand("cap worldCursor off")
  equal("cap turns a capability off for the session", capGate.Caps.worldCursor, false)
  capGate.SlashCommand("cap worldCursor on")
  equal("cap turns a capability back on for the session", capGate.Caps.worldCursor, true)
  stub.state.printed = {}
  capGate.SlashCommand("cap notARealCapability on")
  equal("an unknown capability name changes nothing", capGate.Caps.worldCursor, true)
  check("an unknown capability name prints a usage line",
    table.concat(stub.state.printed, "\n"):find("Usage", 1, true) ~= nil)
end

-- The rest of this file continues against a fresh, unrelated retail
-- instance, so the scenarios above cannot leak into the SavedVariables file
-- this script writes at the end.
_G.GameTooltip.OnShow = nil
EW = LoadFreshAddon(1, { "12.1.0", "60000", "Sep 17 2026", 120100 })
stub.state.units.player = { guid = "Player-3888-0A1B2C3E", name = "Thalos", level = 80, isPlayer = true }

--[[
The live capture from 0.1.0, anonymized.

fixtures/live-0.1.0.lua is the file a Retail client wrote in a few minutes in
Orgrimmar, with the character renamed and everything else left as it was: the
same kinds, ids, map, and coordinates. It is kept because it is the evidence
for the three fixes in 0.1.1, and these assertions are that evidence written
down: a vendor row with no price, two snapshots in one short session with the
first one's currency list empty, and 802 counted as skipped. Nothing in 0.1.1
may write a file that looks like this again.
]]
local fixturePath = root .. "tests/fixtures/live-0.1.0.lua"
local fixtureFile = io.open(fixturePath, "r")
check("the live capture is kept with the tests", fixtureFile ~= nil, fixturePath)
if fixtureFile then
  local text = fixtureFile:read("a")
  fixtureFile:close()
  local env = {}
  local chunk = assert(load(text, "live-0.1.0", "t", env))
  chunk()
  local captured = env.EverythingWoWDB
  equal("the capture is the same schema", captured.schema, 1)
  equal("the capture was written by 0.1.0", captured.addon, "0.1.0")
  local kinds, vendorItem, snapshots = {}, nil, {}
  for _, observation in ipairs(captured.observations) do
    kinds[observation.kind] = (kinds[observation.kind] or 0) + 1
    if observation.kind == "vendor" then vendorItem = observation.payload.items[1] end
    if observation.kind == "character_snapshot" then snapshots[#snapshots + 1] = observation end
  end
  equal("the capture holds twenty two npc sightings", kinds.npc, 22)
  equal("the capture holds one vendor visit", kinds.vendor, 1)
  equal("0.1.0 wrote a vendor item with no price", vendorItem.price, nil)
  equal("0.1.0 wrote a vendor item with no currency either", vendorItem.currency, nil)
  equal("0.1.0 wrote two snapshots in one session", #snapshots, 2)
  equal("the first one fired before the currencies loaded", #snapshots[1].payload.currencies, 0)
  check("the second one was a hundred seconds later",
    snapshots[2].t - snapshots[1].t < 3600, snapshots[2].t - snapshots[1].t)
  equal("and 0.1.0 counted eight hundred and two as skipped", captured.skipped, 802)
  equal("the capture carries no player but the contributor", snapshots[1].payload.name, "Thalos")
end

--[[
The writer. The game serializes SavedVariables as one global assignment per
table, tab indented, with string keys in bracket form, positional entries
followed by an index comment, and pipe characters doubled. This writes the
same thing, so that what the site's parser is fed in check-file.mjs is what
the client would have written.
]]
local function EscapeString(value)
  value = value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
  return value:gsub("|", "||")
end

local function WriteNumber(value)
  if math.type and math.type(value) == "integer" then return string.format("%d", value) end
  if value == math.floor(value) and math.abs(value) < 1e15 then return string.format("%d", value) end
  return string.format("%.14g", value)
end

local function Serialize(value, indent, out)
  local pad = string.rep("\t", indent)
  if type(value) ~= "table" then
    if type(value) == "string" then return '"' .. EscapeString(value) .. '"' end
    if type(value) == "number" then return WriteNumber(value) end
    return tostring(value)
  end

  local lines = { "{" }
  local isArray = EW.IsArray(value)
  if isArray then
    for index = 1, #value do
      lines[#lines + 1] = pad .. "\t" .. Serialize(value[index], indent + 1, out) .. ", -- [" .. index .. "]"
    end
  else
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
      local written
      if type(key) == "number" then
        written = "[" .. WriteNumber(key) .. "]"
      else
        written = '["' .. EscapeString(tostring(key)) .. '"]'
      end
      lines[#lines + 1] = pad .. "\t" .. written .. " = " .. Serialize(value[key], indent + 1, out) .. ","
    end
  end
  lines[#lines + 1] = pad .. "}"
  return table.concat(lines, "\n")
end

-- One file holding everything the tests recorded above.
clear()
stub.state.units.nameplate1 = {
  guid = "Creature-0-3888-0-11-2914-000136DF91", name = "Kobold Vermin",
  level = 3, reaction = 2, classification = "normal",
}
stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
stub.Fire("QUEST_DETAIL")
stub.Fire("MERCHANT_SHOW")
stub.state.loot = { { id = 2589, quantity = 2, source = "Creature-0-3888-0-11-2914-000136DF95" } }
stub.state.combatLog = { subevent = "UNIT_DIED", destGuid = "Creature-0-3888-0-11-2914-000136DF95" }
stub.state.units.target = { guid = "Creature-0-3888-0-11-2914-000136DF95" }
stub.Fire("COMBAT_LOG_EVENT_UNFILTERED")
stub.Fire("LOOT_OPENED")
EW.RecordObjectFromGuid("GameObject-0-3888-0-11-1731-000136DF97", true)
EW.TakeSnapshot(true)
EW.OnAuctionListUpdate()

local file = assert(io.open(outputPath, "w"))
file:write("\nEverythingWoWDB = " .. Serialize(db(), 0) .. "\n")
file:close()

check("the written file holds every kind the run recorded", #observations() >= 7, #observations())
print(string.format("%d passed, %d failed. File written to %s with %d observations.",
  passed, failed, outputPath, #observations()))
if failed > 0 then os.exit(1) end
