--[[
The addon's tests.

Run them with a Lua interpreter from the repository root:

    lua5.4 tests/run.lua [output file]

or lua5.1, the game's own Lua, the same way.

They load the real addon files against the stub client in stub.lua, fire the
events the recorders listen for, and assert the shape of EverythingWoWDB: the
contract's field names, the payload spellings, the caps, the ring buffer, the
de-duplication rule, and the byte trimming. The last test serializes the
table the way the game's own SavedVariables writer does and writes it to the
output file, which defaults to the scratchpad path below, and five more
beside it, from a Forever, a Burning Crusade Classic, a Mists Classic, a
Wrath of the Lich King Classic, and a Cataclysm Classic session, named for
the first with -forever, -tbc, -mists, -wrath, and -cata before its
extension. From 0.2.6 the first two also carry EverythingWoWTalentsDB,
the talent captures, beside EverythingWoWDB, the way the client writes the
addon's two saved variables into one file. The worker's
addon/tests/check-file.mjs then reads any written file with the site's own
parser.
]]

local root = (arg and arg[0] or "tests/run.lua"):gsub("tests/run%.lua$", "")
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

local FILES = { "Core", "Units", "Objects", "Quests", "Vendor", "Loot", "Snapshot", "Talents", "Auction" }

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
  _G.EverythingWoWTalentsDB = nil
  local fresh = {}
  for _, name in ipairs(FILES) do
    local chunk = assert(loadfile(root .. name .. ".lua"))
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
equal("addon is the addon version", saved.addon, "0.2.6")
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
_G.C_AuctionHouse = { GetBrowseResults = function() return {} end }
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
-- From 0.2.6 the scan steps aside only where the modern reader can read the
-- browse list, so a C_AuctionHouse table without it leaves the scan running.
clear()
_G.C_AuctionHouse = { GetAuctionItemSubClasses = function() return {} end }
equal("auction scanning still runs beside a partial C_AuctionHouse", EW.OnAuctionListUpdate(), true)
_G.C_AuctionHouse = nil
clear()

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
real files once per client: Retail, Classic Era, Burning Crusade Classic
Anniversary and Mists of Pandaria Classic (from 0.2.4), Wrath of the Lich
King Classic and Cataclysm Classic (from 0.2.5), Forever, a client the site
holds no row for, and a client the table does not recognize at all.
]]
_G.GameTooltip.OnShow = nil
local retailGate = LoadFreshAddon(1, { "12.1.0", "60000", "Sep 17 2026", 120100 })
equal("retail reads as the retail client", retailGate.Client.key, "retail")
equal("retail's world cursor capability is on", retailGate.Caps.worldCursor, true)
equal("retail's unit guid capability is on", retailGate.Caps.unitGuid, true)
equal("retail's combat log capability is on", retailGate.Caps.combatLog, true)
equal("retail's auction capability is on", retailGate.Caps.auction, true)
check("retail installs the tooltip hook", _G.GameTooltip.OnShow ~= nil)
-- 0.2.3: the upload's own version key, asserted per client from here on.
equal("retail's saved version key is retail", retailGate.Database().version, "retail")
equal("retail's saved client rides beside it", retailGate.Database().client, "retail")

_G.GameTooltip.OnShow = nil
local classicGate = LoadFreshAddon(2, { "1.15.9", "50000", "Sep 17 2026", 11509 })
equal("a 1.15 build reads as classic era", classicGate.Client.key, "classic_era")
equal("classic era's world cursor capability is off", classicGate.Caps.worldCursor, false)
equal("classic era's unit guid capability is on", classicGate.Caps.unitGuid, true)
equal("classic era's combat log capability is on", classicGate.Caps.combatLog, true)
equal("classic era's auction capability is on, its own scan being the only path", classicGate.Caps.auction, true)
check("classic era never installs the tooltip hook", _G.GameTooltip.OnShow == nil)
equal("classic era's saved version key is classic era", classicGate.Database().version, "classic_era")
stub.state.hardcore = true
equal("a hardcore realm on the classic era client still saves hardcore",
  classicGate.Database().version, "hardcore")
stub.state.hardcore = false

--[[
0.2.4: Burning Crusade Classic Anniversary (2.5.6) and Mists of Pandaria
Classic (5.5.4), each on its own project id, neither of them the mainline
one. 0.2.3 read both as classic_era and wrote classic_era into db.version,
so their recordings would have landed under Classic Era. Each now reads its
own key, saves it in both db.version and db.client, and carries the Classic
Era capability row.
]]
local function CheckClassicClient(label, project, build, key)
  _G.GameTooltip.OnShow = nil
  local gate = LoadFreshAddon(project, build)
  equal(label .. " reads as " .. key, gate.Client.key, key)
  equal(label .. "'s version key is " .. key, gate.VersionKey(), key)
  equal(label .. "'s saved version key is " .. key, gate.Database().version, key)
  equal(label .. "'s saved client rides beside it", gate.Database().client, key)
  equal(label .. "'s world cursor capability is off", gate.Caps.worldCursor, false)
  equal(label .. "'s unit guid capability is on", gate.Caps.unitGuid, true)
  equal(label .. "'s combat log capability is on", gate.Caps.combatLog, true)
  equal(label .. "'s auction capability is on", gate.Caps.auction, true)
  check(label .. " never installs the tooltip hook", _G.GameTooltip.OnShow == nil)
  -- The hardcore rule belongs to the Classic Era family alone, so a hardcore
  -- reading cannot pull either client's key back to hardcore.
  stub.state.hardcore = true
  equal(label .. " keeps its own version key on a hardcore reading", gate.Database().version, key)
  stub.state.hardcore = false
  stub.state.printed = {}
  gate.SlashCommand("status")
  local text = table.concat(stub.state.printed, "\n")
  check(label .. "'s status prints its game key", text:find("game " .. key, 1, true) ~= nil, text)
  check(label .. "'s status prints its client line", text:find("client " .. key .. " (interface", 1, true) ~= nil, text)
  return gate
end

local tbcGate = CheckClassicClient("burning crusade classic", _G.WOW_PROJECT_BURNING_CRUSADE_CLASSIC,
  { "2.5.6", "63000", "Sep 17 2026", 20506 }, "classic_tbc")
equal("burning crusade classic keeps its interface for status", tbcGate.Client.interface, 20506)
local mopGate = CheckClassicClient("mists classic", _G.WOW_PROJECT_MISTS_CLASSIC,
  { "5.5.4", "64000", "Sep 17 2026", 50504 }, "classic_mop")
equal("mists classic keeps its interface for status", mopGate.Client.interface, 50504)

-- A 2.5 or 5.5 version string on the mainline project id is still Retail's
-- rule, as it always was: the project id check comes first for everything
-- but Forever.
_G.GameTooltip.OnShow = nil
local mainlineTwo = LoadFreshAddon(1, { "2.5.6", "63000", "Sep 17 2026", 20506 })
equal("a 2.5 build on the mainline project id reads as retail", mainlineTwo.Client.key, "retail")

--[[
0.2.5: Wrath of the Lich King Classic and Cataclysm Classic. The site gained
classic_wrath and classic_cata rows on 28 September 2026, left disabled, and
its upload path reads every row whether or not it is enabled, so a 3.x or
4.x session now reads as its own key, saves it in db.version and db.client,
and carries the Classic Era capability row. 0.2.4 read both as unknown,
sent unknown, and the site refused the upload. Neither client is declared
in a table of contents. The 3.x build is Titan Reforged's 3.80.2, the one
3.x client still running.
]]
local wrathGate = CheckClassicClient("wrath classic", _G.WOW_PROJECT_WRATH_CLASSIC,
  { "3.80.2", "60000", "Sep 17 2026", 38002 }, "classic_wrath")
equal("wrath classic keeps its interface for status", wrathGate.Client.interface, 38002)
equal("a 3.80.2 build reads as classic_wrath, the site now holding a wrath row", wrathGate.Client.key, "classic_wrath")
equal("its unit guid capability is on, the classic row", wrathGate.Caps.unitGuid, true)
equal("its combat log capability is on too", wrathGate.Caps.combatLog, true)
local cataGate = CheckClassicClient("cataclysm classic", _G.WOW_PROJECT_CATACLYSM_CLASSIC,
  { "4.4.2", "60000", "Sep 17 2026", 40402 }, "classic_cata")
equal("cataclysm classic keeps its interface for status", cataGate.Client.interface, 40402)
equal("a 4.4 build reads as classic_cata, the site now holding a cataclysm row", cataGate.Client.key, "classic_cata")
equal("a 4.4 build's upload key is classic_cata rather than unknown", cataGate.VersionKey(), "classic_cata")
equal("a 3.80.2 build's upload key is classic_wrath rather than unknown", wrathGate.VersionKey(), "classic_wrath")

-- A readable major of 6 or above off the mainline project id still has no
-- row on the site, so it still reads as unknown, sends unknown, and takes
-- the unknown row's capabilities.
_G.GameTooltip.OnShow = nil
local sixGate = LoadFreshAddon(99, { "6.2.4", "60000", "Sep 17 2026", 60204 })
equal("a 6.x build off the mainline project id still reads as unknown", sixGate.Client.key, "unknown")
equal("its upload key is still unknown", sixGate.VersionKey(), "unknown")
equal("its saved version key is still unknown", sixGate.Database().version, "unknown")
equal("its unit guid capability is off, the unknown row", sixGate.Caps.unitGuid, false)
equal("its combat log capability is off too", sixGate.Caps.combatLog, false)
equal("its auction capability is off too", sixGate.Caps.auction, false)
check("it never installs the tooltip hook", _G.GameTooltip.OnShow == nil)

_G.GameTooltip.OnShow = nil
-- Build 1.60.1 is the owner's own reading, on what the note expects to be
-- the shared Classic project id. 0.2.2 settles this row on the owner's own
-- probe transcript: NAME_PLATE_UNIT_ADDED, UPDATE_MOUSEOVER_UNIT, and
-- PLAYER_TARGET_CHANGED came back allowed and a manual /ewow cap on for
-- worldCursor and unitGuid raised no alert, while COMBAT_LOG_EVENT_UNFILTERED
-- and AUCTION_ITEM_LIST_UPDATE came back refused.
local foreverGate = LoadFreshAddon(2, { "1.60.1", "70000", "Nov 4 2026", 16001 })
equal("a 1.60 build on the classic project id reads as forever", foreverGate.Client.key, "forever")
equal("forever on the classic project id saves the forever version key",
  foreverGate.Database().version, "forever")
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
-- listener at all, and announced once at the next PLAYER_ENTERING_WORLD
-- that the auction recorder was idle. From 0.2.6 it says nothing: the owner
-- asked for silence on 24 October 2026, and /ewow status names the idle
-- recorders instead.
do
  stub.state.printed = {}
  stub.Fire("PLAYER_ENTERING_WORLD", true, false)
  stub.Fire("PLAYER_ENTERING_WORLD", false, true)
  local text = table.concat(stub.state.printed, "\n")
  check("the idle auction recorder no longer prints at login",
    text:find("Auction recording is off", 1, true) == nil, text)
  equal("nothing at all prints at login on forever", #stub.state.printed, 0)
  stub.state.printed = {}
  foreverGate.SlashCommand("status")
  text = table.concat(stub.state.printed, "\n")
  check("status still names forever's idle kill counter",
    text:find("idle on this client: kill counter (combatLog off)", 1, true) ~= nil, text)
  stub.state.printed = {}
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
-- 0.2.3 changes nothing here: an unknown client is not forever, so its
-- version key answers exactly as it did in 0.2.2, off the project id alone,
-- and a project id other than the mainline one reads as classic era.
equal("an unknown client's version key is unknown, which the site refuses", unknownGate.VersionKey(), "unknown")
equal("an unknown client's saved version key is unknown too", unknownGate.Database().version, "unknown")
equal("an unknown client's saved client key stays unknown", unknownGate.Database().client, "unknown")

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
0.2.3: the owner's own session, build 1.60.1 on the mainline project id,
sends the forever version key. The site's versions table has had its forever
row enabled since 24 September 2026, so db.version no longer holds retail for
this session, and db.client rides beside it with the same key.
]]
equal("forever on the mainline project id has the forever version key",
  foreverOnMainline.VersionKey(), "forever")
equal("forever on the mainline project id saves forever as db.version",
  foreverOnMainline.Database().version, "forever")
equal("forever on the mainline project id saves forever as db.client",
  foreverOnMainline.Database().client, "forever")
do
  stub.state.printed = {}
  foreverOnMainline.SlashCommand("status")
  local text = table.concat(stub.state.printed, "\n")
  check("status still reads game forever for the owner's own session",
    text:find("game forever", 1, true) ~= nil, text)
  check("status prints the 0.2.6 addon version",
    text:find("version 0.2.6", 1, true) ~= nil, text)
end

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
    text:find("18 allowed, 1 refused", 1, true) ~= nil, text)

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
  -- From 0.2.6 the probe also asks about the modern auction reader's seven
  -- events, which this stand in client allows.
  check("the probe still tallies all nineteen events, seventeen allowed and two refused",
    text:find("17 allowed, 2 refused", 1, true) ~= nil, text)

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

--[[
0.2.6: the modern auction reader in Auction.lua, for a client whose auction
house is C_AuctionHouse and whose realms Blizzard's auction API does not
cover. Each client is loaded with stub.InstallModernAuction in place before
the addon loads, because the reader decides at load whether to listen for
the auction house opening at all, and the shape is removed after, so
nothing above or below this block reads a client with C_AuctionHouse.
]]
local AUCTION_SPEC = {
  browse = {
    { id = 2589, q = 400, min = 120 },
    { id = 2592, q = 35, min = 410 },
    -- A battle pet's row names the pet cage, so it is passed over.
    { id = 82800, q = 1, min = 990000, pet = 39 },
  },
  commodities = {
    [2589] = { { q = 20, unit = 120 }, { q = 5, unit = 125 }, { q = 200, unit = 131 } },
  },
  items = {
    [19019] = { { q = 1, buyout = 25000000 }, { q = 1 } },
  },
}

local function AuctionObservations(addon)
  local found = {}
  for _, observation in ipairs(addon.Database().observations) do
    if observation.kind == "auction" then found[#found + 1] = observation end
  end
  return found
end

--[[ Whether a string appears anywhere inside a value, keys included. ]]
local function Mentions(value, needle)
  if type(value) == "string" then return value:find(needle, 1, true) ~= nil end
  if type(value) ~= "table" then return false end
  for key, item in pairs(value) do
    if Mentions(key, needle) or Mentions(item, needle) then return true end
  end
  return false
end

-- Forever, on the mainline project id, with C_AuctionHouse.
do
  _G.GameTooltip.OnShow = nil
  stub.InstallModernAuction(_G, AUCTION_SPEC)
  local gate = LoadFreshAddon(1, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  gate.SlashCommand("clear")
  equal("forever's modern auction capability is on", gate.Caps.auctionModern, true)
  equal("forever's classic auction capability stays off", gate.Caps.auction, false)
  equal("forever reads its auction house through the modern reader", gate.AuctionMode(), "modern")

  stub.state.printed = {}
  stub.Fire("PLAYER_ENTERING_WORLD", true, false)
  equal("forever prints nothing at login with the modern reader either", #stub.state.printed, 0)

  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  equal("no result event is read before the auction house first opens", #AuctionObservations(gate), 0)

  stub.state.combat = true
  stub.Fire("AUCTION_HOUSE_SHOW")
  equal("opening the auction house in combat registers nothing", gate.auctionModernEvents, nil)
  stub.state.combat = false
  stub.Fire("AUCTION_HOUSE_SHOW")
  equal("opening it out of combat registers all six result events", gate.auctionModernEvents, 6)
  stub.Fire("AUCTION_HOUSE_SHOW")
  equal("a second opening registers nothing twice", gate.auctionModernEvents, 6)

  -- Browse results.
  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  local found = AuctionObservations(gate)
  equal("a browse page is one observation", #found, 1)
  local browse = found[1]
  equal("the browse observation is the auction kind and subject", browse.subject, "auction")
  equal("the browse observation carries no subject id", browse.id, nil)
  equal("the browse observation carries the map", browse.map, 84)
  equal("it names its source", browse.payload.source, "browse")
  equal("the pet cage row is passed over", #browse.payload.items, 2)
  equal("a browse row carries the item id from the item key", browse.payload.items[1].id, 2589)
  equal("a browse row carries the total quantity", browse.payload.items[1].q, 400)
  equal("a browse row carries the lowest price as its unit", browse.payload.items[1].unit, 120)
  equal("a browse row carries no buyout, the client giving none", browse.payload.items[1].buyout, nil)
  equal("the second browse row is read too", browse.payload.items[2].unit, 410)

  table.insert(AUCTION_SPEC.browse, { id = 2594, q = 12, min = 800 })
  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", {})
  found = AuctionObservations(gate)
  equal("rows the client appends are one more observation", #found, 2)
  equal("only the appended row is read, not the page again", #found[2].payload.items, 1)
  equal("the appended row is the new item", found[2].payload.items[1].id, 2594)
  table.remove(AUCTION_SPEC.browse)

  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  equal("a fresh browse search is read from its first row again", #AuctionObservations(gate), 3)

  -- Commodity results.
  stub.Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
  found = AuctionObservations(gate)
  local commodity = found[#found]
  equal("a commodity search names its source", commodity.payload.source, "commodity")
  equal("every listing is read", #commodity.payload.items, 3)
  equal("a listing carries the item id", commodity.payload.items[1].id, 2589)
  equal("a listing carries its quantity", commodity.payload.items[1].q, 20)
  equal("a listing carries its unit price", commodity.payload.items[1].unit, 120)
  equal("a listing carries the whole listing's price as its buyout", commodity.payload.items[1].buyout, 2400)
  equal("the last listing is read too", commodity.payload.items[3].unit, 131)
  local before = #found
  stub.Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
  equal("the same listings inside a minute are not read twice", #AuctionObservations(gate), before)
  stub.state.time = stub.state.time + 61
  stub.Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
  equal("the same search past a minute is a fresh reading", #AuctionObservations(gate), before + 1)
  stub.Fire("COMMODITY_SEARCH_RESULTS_UPDATED", "not an item id")
  equal("an event with no item id reads nothing", #AuctionObservations(gate), before + 1)

  -- Item results.
  stub.Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 19019, itemLevel = 60, itemSuffix = 0, battlePetSpeciesID = 0 }, 2001)
  found = AuctionObservations(gate)
  local item = found[#found]
  equal("an item search names its source", item.payload.source, "item")
  equal("every auction of the item is read", #item.payload.items, 2)
  equal("an auction carries the item id", item.payload.items[1].id, 19019)
  equal("an auction carries its quantity", item.payload.items[1].q, 1)
  equal("an auction carries its buyout", item.payload.items[1].buyout, 25000000)
  equal("an auction carries its unit price", item.payload.items[1].unit, 25000000)
  equal("an auction with no buyout keeps its quantity", item.payload.items[2].q, 1)
  equal("an auction with no buyout carries no price", item.payload.items[2].unit, nil)

  -- No player data, and never a query of the addon's own.
  local db = gate.Database()
  check("no seller name reaches the file", not Mentions(db.observations, "SomeSeller"))
  check("no bidder reaches the file", not Mentions(db.observations, "Player-"))
  check("no owners field reaches the file", not Mentions(db.observations, "owners"))
  for _, name in ipairs({ "SendBrowseQuery", "SendSearchQuery", "SendSellSearchQuery" }) do
    equal("the reader never calls " .. name, stub.state.auctionCalls[name], nil)
  end
  equal("no handler raised an error", gate.lastError, nil)

  -- The caps: 1,200 listings of one commodity, read 500 at a time in
  -- observations of 50 rows, each inside the four thousand byte cap.
  gate.SlashCommand("clear")
  local many = {}
  for index = 1, 1200 do many[index] = { q = 1 + (index % 20), unit = 1000000 + index } end
  AUCTION_SPEC.commodities[2590] = many
  stub.Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2590)
  found = AuctionObservations(gate)
  local rows, widest, largest = 0, 0, 0
  for _, observation in ipairs(found) do
    rows = rows + #observation.payload.items
    if #observation.payload.items > widest then widest = #observation.payload.items end
    local bytes = gate.JsonBytes(observation.payload)
    if bytes > largest then largest = bytes end
  end
  equal("one announcement reads at most five hundred rows", rows, 500)
  equal("five hundred rows are ten observations", #found, 10)
  equal("no observation holds more than fifty rows", widest, 50)
  check("every observation is inside the four thousand byte cap", largest <= 4000, largest)
  equal("the first row is the first listing", found[1].payload.items[1].unit, 1000001)
  stub.Fire("COMMODITY_SEARCH_RESULTS_ADDED", 2590)
  found = AuctionObservations(gate)
  equal("the next announcement reads the next five hundred", #found, 20)
  equal("starting at the five hundred and first listing", found[11].payload.items[1].unit, 1000501)
  AUCTION_SPEC.commodities[2590] = nil

  -- Nothing runs in combat.
  gate.SlashCommand("clear")
  stub.state.time = stub.state.time + 61
  stub.state.combat = true
  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  stub.Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
  equal("no result is read in combat", #AuctionObservations(gate), 0)
  stub.state.combat = false

  -- A refusal of the reader's own events turns off the reader alone.
  equal("a refused result event is placed at auctionModern",
    gate.CapabilityForEvent("COMMODITY_SEARCH_RESULTS_UPDATED"), "auctionModern")
  equal("so is the auction house opening",
    gate.CapabilityForEvent("AUCTION_HOUSE_SHOW"), "auctionModern")
  equal("a reported getter is placed at auctionModern too",
    gate.CapabilityForFunction("C_AuctionHouse.GetBrowseResults"), "auctionModern")
  gate.SlashCommand("cap auctionModern off")
  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  equal("with auctionModern off no result is read", #AuctionObservations(gate), 0)
  gate.SlashCommand("cap auctionModern on")

  stub.state.printed = {}
  gate.SlashCommand("status")
  local text = table.concat(stub.state.printed, "\n")
  check("status prints the modern auction capability", text:find("auctionModern on", 1, true) ~= nil, text)
  check("status does not call the auction house idle on forever",
    text:find("auction recording", 1, true) == nil, text)
  stub.RemoveModernAuction(_G)
end

-- A throwing getter, a partial namespace, and an event the client does not
-- carry: every one is silent.
do
  _G.GameTooltip.OnShow = nil
  stub.InstallModernAuction(_G, { omit = { "GetNumCommoditySearchResults" } })
  stub.state.invalidEvents = { ITEM_SEARCH_RESULTS_ADDED = true }
  local gate = LoadFreshAddon(1, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  _G.C_AuctionHouse.GetBrowseResults = function() error("the client refused") end
  stub.state.printed = {}
  stub.Fire("AUCTION_HOUSE_SHOW")
  equal("only the browse events and the one valid item event are registered", gate.auctionModernEvents, 3)
  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  stub.Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
  equal("a getter that throws writes nothing", #AuctionObservations(gate), 0)
  equal("and raises nothing", gate.lastError, nil)
  equal("and prints nothing", #stub.state.printed, 0)
  stub.state.invalidEvents = {}
  stub.RemoveModernAuction(_G)
end

-- Forever with no C_AuctionHouse at all.
do
  _G.GameTooltip.OnShow = nil
  local gate = LoadFreshAddon(1, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  stub.state.printed = {}
  stub.Fire("PLAYER_ENTERING_WORLD", true, false)
  stub.Fire("AUCTION_HOUSE_SHOW")
  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  stub.Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
  equal("a missing auction api registers nothing", gate.auctionModernEvents, nil)
  equal("a missing auction api writes nothing", #AuctionObservations(gate), 0)
  equal("a missing auction api prints nothing", #stub.state.printed, 0)
  equal("a missing auction api raises nothing", gate.lastError, nil)
  equal("its auction house reads as idle", gate.AuctionMode(), "idle")
  gate.SlashCommand("status")
  local text = table.concat(stub.state.printed, "\n")
  check("status names the idle auction recorder when asked",
    text:find("auction recording (no auction API this addon can read)", 1, true) ~= nil, text)
end

-- Retail, with C_AuctionHouse: the site reads Blizzard's API, so the reader
-- stays idle and asks the client for nothing.
do
  _G.GameTooltip.OnShow = nil
  stub.InstallModernAuction(_G, AUCTION_SPEC)
  local gate = LoadFreshAddon(1, { "12.1.0", "60000", "Sep 17 2026", 120100 })
  equal("retail's modern auction capability is off", gate.Caps.auctionModern, false)
  equal("retail's auction house reads as idle", gate.AuctionMode(), "idle")
  stub.state.printed = {}
  stub.Fire("PLAYER_ENTERING_WORLD", true, false)
  stub.Fire("AUCTION_HOUSE_SHOW")
  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  stub.Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
  stub.Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 19019 })
  stub.Fire("AUCTION_ITEM_LIST_UPDATE")
  equal("retail registers no result event", gate.auctionModernEvents, nil)
  equal("retail writes no auction observation", #AuctionObservations(gate), 0)
  equal("retail never reads the browse list", stub.state.auctionCalls.GetBrowseResults, nil)
  equal("retail prints nothing at login", #stub.state.printed, 0)
  gate.SlashCommand("status")
  local text = table.concat(stub.state.printed, "\n")
  check("retail's status says why its auction recording is idle",
    text:find("auction recording (the site reads Blizzard's auction API)", 1, true) ~= nil, text)
  stub.RemoveModernAuction(_G)
end

-- Cataclysm Classic with C_AuctionHouse: the modern reader serves it and the
-- classic scan steps aside.
do
  _G.GameTooltip.OnShow = nil
  stub.InstallModernAuction(_G, AUCTION_SPEC)
  local gate = LoadFreshAddon(14, { "4.4.2", "60000", "Sep 17 2026", 40402 })
  equal("cataclysm classic's modern auction capability is on", gate.Caps.auctionModern, true)
  equal("cataclysm classic reads its auction house through the modern reader", gate.AuctionMode(), "modern")
  stub.Fire("AUCTION_HOUSE_SHOW")
  stub.Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
  equal("a cataclysm classic commodity search is recorded", #AuctionObservations(gate), 1)
  equal("the classic scan steps aside for it", gate.OnAuctionListUpdate(), false)
  stub.RemoveModernAuction(_G)
end

-- Classic Era without C_AuctionHouse keeps the classic scan.
do
  _G.GameTooltip.OnShow = nil
  local gate = LoadFreshAddon(2, { "1.15.9", "50000", "Sep 17 2026", 11509 })
  equal("classic era's modern auction capability is on", gate.Caps.auctionModern, true)
  equal("but classic era, with no C_AuctionHouse, reads through the classic scan", gate.AuctionMode(), "classic")
  stub.Fire("AUCTION_HOUSE_SHOW")
  equal("and registers no modern result event", gate.auctionModernEvents, nil)
end

--[[
0.2.6: `/ewow talents`, the talent tree recorder in Talents.lua. Each shape
is installed on the stand in client only for its own test and removed after,
so nothing above or below this block reads a client with talent functions.
The classic shape is three trees with an arrow between two talents in the
first, read on the owner's own Forever session; the C_Traits shape is two
trees of positioned nodes with an edge, a choice node and an empty node; and
the last shape has neither, which must still write a diagnostic.
]]
local function HoldsString(value, needle)
  if type(value) == "string" then return value:find(needle, 1, true) ~= nil end
  if type(value) ~= "table" then return false end
  for key, item in pairs(value) do
    if HoldsString(key, needle) or HoldsString(item, needle) then return true end
  end
  return false
end

local function CountKeys(value)
  local count = 0
  for _ in pairs(value or {}) do count = count + 1 end
  return count
end

local CLASSIC_TABS = {
  {
    id = 161, name = "Arms", icon = 132355, background = "WarriorArms",
    talents = {
      { id = 9001, name = "Arms One", icon = 132282, tier = 1, column = 1, maxRank = 3 },
      -- Listed before its prerequisite, which is how the client's own
      -- talent indexes can fall, so the arrow is resolved by tier and
      -- column rather than by order.
      { id = 9003, name = "Arms Three", icon = 132284, tier = 3, column = 2, maxRank = 3, prereq = { 1, 2 } },
      { id = 9002, name = "Arms Two", icon = 132283, tier = 1, column = 2, maxRank = 5, rank = 2 },
      { id = 9004, name = "Arms Four", icon = 132285, tier = 2, column = 3, maxRank = 2 },
      { id = 9005, name = "Arms Five", icon = 132286, tier = 5, column = 2, maxRank = 1, exceptional = true },
    },
  },
  {
    id = 164, name = "Fury", icon = 132347, background = "WarriorFury",
    talents = {
      { id = 9101, name = "Fury One", icon = 132290, tier = 1, column = 2, maxRank = 5 },
      { id = 9102, name = "Fury Two", icon = 132291, tier = 1, column = 3, maxRank = 5 },
      { id = 9103, name = "Fury Three", icon = 132292, tier = 2, column = 1, maxRank = 2 },
    },
  },
  {
    id = 163, name = "Protection", icon = 134952, background = "WarriorProtection",
    talents = {
      { id = 9201, name = "Protection One", icon = 132300, tier = 1, column = 2, maxRank = 5 },
      { id = 9202, name = "Protection Two", icon = 132301, tier = 1, column = 3, maxRank = 5 },
    },
  },
}

-- The classic shape, read on a Forever session on the mainline project id.
do
  _G.GameTooltip.OnShow = nil
  local talentGate = LoadFreshAddon(1, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  stub.state.units.player = { guid = "Player-3888-0A1B2C3E", name = "Thalos", level = 1, isPlayer = true }
  stub.state.class = { "Warrior", "WARRIOR", 1 }
  stub.InstallClassicTalents(_G, CLASSIC_TABS)
  talentGate.SlashCommand("clear")
  talentGate.TakeSnapshot(true)
  local observationsBefore = #talentGate.Database().observations
  stub.state.printed = {}
  talentGate.SlashCommand("talents")
  local printed = table.concat(stub.state.printed, "\n")
  check("talents prints the confirmation line",
    printed:find("Recorded 3 trees, 10 talents for Warrior. /reload or log out to save.", 1, true) ~= nil, printed)
  check("talents prints the classes held for the client",
    printed:find("Classes held for forever (1): warrior.", 1, true) ~= nil, printed)

  local talentDb = _G.EverythingWoWTalentsDB
  check("the captures live in their own saved variable", type(talentDb) == "table")
  equal("the talent saved variable names its format", talentDb.format, "everythingwow/companion-talents/1")
  local capture = talentDb.captures["forever:WARRIOR"]
  check("a capture is keyed by client and class", type(capture) == "table")
  equal("the capture holds the class file token", capture.class, "WARRIOR")
  equal("the capture holds the site's class slug", capture.class_slug, "warrior")
  equal("the capture holds the class id", capture.class_id, 1)
  equal("the capture holds the client key", capture.client, "forever")
  equal("the capture holds the project id", capture.project, 1)
  equal("the capture holds the build", capture.build, "1.60.1")
  equal("the capture holds the build number", capture.build_number, "70000")
  equal("the capture holds the interface number", capture.interface, 16001)
  equal("the capture holds the character's level", capture.level, 1)
  equal("the capture holds a timestamp", capture.t, stub.state.time)
  equal("the capture holds the addon version", capture.addon, "0.2.6")
  equal("the capture names the classic path", capture.source, "classic")
  equal("the classic path reports ok", capture.paths.classic, "ok")
  equal("the traits path reports absent on this client", capture.paths.traits, "absent")
  equal("the api diagnostic names a classic function present", capture.api.GetTalentInfo, "function")
  equal("the api diagnostic leaves out a function absent", capture.api.C_Traits, nil)
  equal("no second path is kept where only one answered", capture.alt, nil)
  equal("three trees are recorded", #capture.trees, 3)
  equal("ten talents are counted", capture.talents, 10)

  local arms = capture.trees[1]
  equal("a tree carries its id in the id first shape", arms.id, 161)
  equal("a tree carries its index", arms.index, 1)
  equal("a tree carries its name", arms.name, "Arms")
  equal("a tree carries its icon", arms.icon, 132355)
  equal("a tree carries its background", arms.background, "WarriorArms")
  equal("the first tree holds five talents", #arms.talents, 5)
  equal("the third tree holds two talents", #capture.trees[3].talents, 2)
  local first, third = arms.talents[1], arms.talents[2]
  equal("a talent carries its index", first.index, 1)
  equal("a talent carries its id from the talent link", first.id, 9001)
  equal("a talent carries its name", first.name, "Arms One")
  equal("a talent carries its icon", first.icon, 132282)
  equal("a talent carries its tier", first.tier, 1)
  equal("a talent carries its column", first.column, 1)
  equal("a talent carries its maximum rank", first.max_rank, 3)
  equal("a talent with no arrow requires nothing", #first.requires, 0)
  equal("a talent with an arrow requires one talent", #third.requires, 1)
  equal("the prerequisite carries its tier", third.requires[1].tier, 1)
  equal("the prerequisite carries its column", third.requires[1].column, 2)
  equal("the prerequisite resolves to the talent's id", third.requires[1].id, 9002)
  equal("the prerequisite resolves to the talent's index", third.requires[1].index, 3)
  equal("a milestone talent is marked exceptional", arms.talents[5].exceptional, true)
  equal("a talent that is not a milestone carries no mark", first.exceptional, nil)
  equal("the character's spent rank is never recorded", arms.talents[3].rank, nil)
  check("the character's name is never in the capture", not HoldsString(talentDb, "Thalos"))
  check("the realm is never in the capture", not HoldsString(talentDb, "Tichondrius"))
  equal("the talents never become observations",
    #talentGate.Database().observations, observationsBefore)
  equal("the observation file carries no talent key", talentGate.Database().talents, nil)

  -- A second read of the same class replaces the first; another class adds one.
  stub.state.time = stub.state.time + 60
  talentGate.SlashCommand("talents")
  equal("a second read of a class keeps one capture", CountKeys(talentDb.captures), 1)
  equal("a second read replaces the first", talentDb.captures["forever:WARRIOR"].t, stub.state.time)
  stub.state.class = { "Druid", "DRUID", 11 }
  talentGate.SlashCommand("talents")
  equal("a second class adds a second capture", CountKeys(talentDb.captures), 2)
  equal("the druid capture has the druid slug", talentDb.captures["forever:DRUID"].class_slug, "druid")
  stub.state.class = { "Death Knight", "DEATHKNIGHT", 6 }
  talentGate.SlashCommand("talents")
  equal("a two word class takes the site's hyphenated slug",
    talentDb.captures["forever:DEATHKNIGHT"].class_slug, "death-knight")

  -- /ewow clear empties the observations and leaves the captures alone.
  talentGate.SlashCommand("clear")
  equal("clear leaves the talent captures", CountKeys(_G.EverythingWoWTalentsDB.captures), 3)

  -- In combat nothing is read or written.
  stub.state.combat = true
  stub.state.printed = {}
  stub.state.class = { "Mage", "MAGE", 8 }
  talentGate.SlashCommand("talents")
  equal("talents in combat records nothing", talentDb.captures["forever:MAGE"], nil)
  check("talents in combat says to leave combat",
    table.concat(stub.state.printed, "\n"):find("Leave combat", 1, true) ~= nil)
  stub.state.combat = false

  -- A GetTalentInfo answering an id first is a different function under the
  -- same name, and is not read as a classic talent.
  stub.InstallClassicTalents(_G, { { name = "Rows", talents = { { name = "Row Talent", numericFirst = true } } } })
  local rowCapture = talentGate.ReadTalentTrees()
  equal("an id first GetTalentInfo is not read as classic", rowCapture.paths.classic, "no_talents")
  -- /ewow talents clear throws the captures away, and only those.
  talentGate.Record("npc", "npc", 12, 84, 0.2, 0.2, nil)
  talentGate.SlashCommand("talents clear")
  equal("talents clear empties the captures", CountKeys(_G.EverythingWoWTalentsDB.captures), 0)
  equal("talents clear leaves the observations", #talentGate.Database().observations, 1)
  stub.RemoveTalentApis(_G)
  stub.state.class = { "Shaman", "SHAMAN", 7 }
end

-- The name first shape of GetTalentTabInfo, on a Classic Era session, keyed
-- under classic_era rather than beside Forever's capture of the same class.
do
  _G.GameTooltip.OnShow = nil
  local eraGate = LoadFreshAddon(2, { "1.15.9", "50000", "Sep 17 2026", 11509 })
  stub.state.units.player = { guid = "Player-3888-0A1B2C3E", name = "Thalos", level = 60, isPlayer = true }
  stub.state.class = { "Warrior", "WARRIOR", 1 }
  stub.InstallClassicTalents(_G, {
    { name = "Arms", icon = "Interface\\Icons\\Ability_Rogue_Eviscerate", background = "WarriorArms",
      talents = { { name = "Arms One", icon = "Interface\\Icons\\Ability_Rogue_Ambush", tier = 1, column = 1, maxRank = 3 } } },
  })
  eraGate.SlashCommand("talents")
  local capture = _G.EverythingWoWTalentsDB.captures["classic_era:WARRIOR"]
  check("a classic era read is keyed classic_era", type(capture) == "table")
  equal("the name first shape gives the tree name", capture.trees[1].name, "Arms")
  equal("the name first shape gives a texture path icon", capture.trees[1].icon, "Interface\\Icons\\Ability_Rogue_Eviscerate")
  equal("the name first shape gives the background", capture.trees[1].background, "WarriorArms")
  equal("the name first shape has no tree id", capture.trees[1].id, nil)
  equal("a talent with no link has no id", capture.trees[1].talents[1].id, nil)
  equal("a classic era read records the classic era build", capture.build, "1.15.9")
  stub.RemoveTalentApis(_G)
  stub.state.class = { "Shaman", "SHAMAN", 7 }
end

local TRAITS_SPEC = {
  configId = 4242,
  spells = {
    [5001] = { name = "Spell One", icon = 136001 },
    [5002] = { name = "Spell Two", icon = 136002 },
    [5003] = { name = "Spell Three", icon = 136003 },
    [5004] = { name = "Spell Four", icon = 136004 },
    [5005] = { name = "Spell Five", icon = 136005 },
  },
  trees = {
    {
      id = 790,
      nodes = {
        { id = 80001, x = 1200, y = 1500, maxRanks = 2, entries = { { id = 70001, definition = 60001, spell = 5001 } }, edges = { 80003 } },
        { id = 80002, x = 1800, y = 1500, maxRanks = 1, entries = { { id = 70002, definition = 60002, spell = 5002, overrideName = "Override Two" } } },
        { id = 80003, x = 1200, y = 2100, maxRanks = 1,
          entries = { { id = 70003, definition = 60003, spell = 5003 }, { id = 70004, definition = 60004, spell = 5004 } } },
        { id = 80004, empty = true },
      },
    },
    {
      id = 791,
      nodes = {
        { id = 81001, x = 600, y = 900, maxRanks = 3, entries = { { id = 71001, definition = 61001, spell = 5005 } } },
      },
    },
  },
}

-- The C_Traits shape, on a Retail session with no classic functions.
do
  _G.GameTooltip.OnShow = nil
  local traitsGate = LoadFreshAddon(1, { "12.1.0", "60000", "Sep 17 2026", 120100 })
  stub.state.units.player = { guid = "Player-3888-0A1B2C3E", name = "Thalos", level = 80, isPlayer = true }
  stub.state.class = { "Druid", "DRUID", 11 }
  stub.InstallTraits(_G, TRAITS_SPEC)
  stub.state.printed = {}
  traitsGate.SlashCommand("talents")
  check("the traits read prints the confirmation line",
    table.concat(stub.state.printed, "\n"):find("Recorded 2 trees, 4 talents for Druid.", 1, true) ~= nil,
    table.concat(stub.state.printed, "\n"))
  local capture = _G.EverythingWoWTalentsDB.captures["retail:DRUID"]
  equal("the capture names the traits path", capture.source, "traits")
  equal("the classic path reports absent", capture.paths.classic, "absent")
  equal("the traits path reports ok", capture.paths.traits, "ok")
  equal("the trait trees are recorded", #capture.trees, 2)
  equal("a trait tree carries its tree id", capture.trees[1].id, 790)
  equal("a node the tree does not hold is passed over", #capture.trees[1].talents, 3)
  local one, two, three = capture.trees[1].talents[1], capture.trees[1].talents[2], capture.trees[1].talents[3]
  equal("a trait talent's id is its node id", one.id, 80001)
  equal("a trait talent carries its entry", one.entry, 70001)
  equal("a trait talent carries its definition", one.definition, 60001)
  equal("a trait talent carries its spell", one.spell, 5001)
  equal("a trait talent's name falls back to its spell's", one.name, "Spell One")
  equal("a trait talent's icon falls back to its spell's", one.icon, 136001)
  equal("an override name wins over the spell's", two.name, "Override Two")
  equal("a trait talent carries its maximum rank", one.max_rank, 2)
  equal("a trait talent keeps its raw x", one.pos_x, 1200)
  equal("a trait talent keeps its raw y", one.pos_y, 1500)
  equal("the tier is the rank among the tree's heights", three.tier, 2)
  equal("the column is the rank among the tree's widths", two.column, 2)
  equal("the first column is 1", one.column, 1)
  equal("an edge makes its source a prerequisite", #three.requires, 1)
  equal("the prerequisite carries the source node's id", three.requires[1].id, 80001)
  equal("the prerequisite carries the source node's tier", three.requires[1].tier, 1)
  equal("the prerequisite carries the source node's column", three.requires[1].column, 1)
  equal("a node no edge names requires nothing", #two.requires, 0)
  equal("a choice node keeps each entry", #three.choices, 2)
  equal("a choice entry carries its own name", three.choices[2].name, "Spell Four")
  equal("a single entry node keeps no choices", one.choices, nil)

  -- Where both shapes answer, the classic one leads and the traits one is kept.
  stub.InstallClassicTalents(_G, CLASSIC_TABS)
  stub.state.class = { "Warrior", "WARRIOR", 1 }
  traitsGate.SlashCommand("talents")
  local both = _G.EverythingWoWTalentsDB.captures["retail:WARRIOR"]
  equal("where both answer the classic path leads", both.source, "classic")
  equal("where both answer the traits path is kept beside it", both.alt.source, "traits")
  equal("the kept traits read holds its trees", #both.alt.trees, 2)
  equal("the kept traits read counts its talents", both.alt.talents, 4)
  stub.RemoveTalentApis(_G)
  stub.state.class = { "Shaman", "SHAMAN", 7 }
end

-- Neither shape: a diagnostic rather than silence, and never over a good capture.
do
  _G.GameTooltip.OnShow = nil
  local noneGate = LoadFreshAddon(1, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  stub.state.units.player = { guid = "Player-3888-0A1B2C3E", name = "Thalos", level = 1, isPlayer = true }
  stub.state.class = { "Rogue", "ROGUE", 4 }
  stub.RemoveTalentApis(_G)
  stub.state.printed = {}
  local ok = pcall(noneGate.SlashCommand, "talents")
  check("talents on a client with neither api never throws", ok)
  local printed = table.concat(stub.state.printed, "\n")
  check("talents on a client with neither api says so",
    printed:find("No talent trees could be read for Rogue (classic absent, traits absent).", 1, true) ~= nil, printed)
  check("a level one read is told to try at level 10", printed:find("level 10", 1, true) ~= nil, printed)
  local talentDb = _G.EverythingWoWTalentsDB
  local diagnostic = talentDb.captures["forever:ROGUE"]
  check("the diagnostic is kept under the class's key", type(diagnostic) == "table")
  equal("the diagnostic holds no trees", #diagnostic.trees, 0)
  equal("the diagnostic counts no talents", diagnostic.talents, 0)
  equal("the diagnostic names no source", diagnostic.source, nil)
  equal("the diagnostic reports the classic path absent", diagnostic.paths.classic, "absent")
  equal("the diagnostic reports the traits path absent", diagnostic.paths.traits, "absent")
  check("the diagnostic carries the api presence table", type(diagnostic.api) == "table")
  equal("the diagnostic leaves out a function the client lacks", diagnostic.api.GetTalentInfo, nil)
  equal("the diagnostic is kept as the last diagnostic", talentDb.lastDiagnostic, diagnostic)

  -- A tree read first, then a failed read of the same class, keeps the tree.
  stub.InstallClassicTalents(_G, CLASSIC_TABS)
  noneGate.SlashCommand("talents")
  equal("a good read replaces a diagnostic", talentDb.captures["forever:ROGUE"].talents, 10)
  stub.RemoveTalentApis(_G)
  noneGate.SlashCommand("talents")
  equal("a failed read never replaces a good capture", talentDb.captures["forever:ROGUE"].talents, 10)
  equal("the failed read is still kept as the last diagnostic", talentDb.lastDiagnostic.talents, 0)

  -- Traits present but answering no config, which is what a character
  -- before its talents open can look like on a modern client.
  stub.InstallTraits(_G, { configId = nil, trees = {} })
  local early = noneGate.ReadTalentTrees()
  equal("traits with no active config report no_config", early.paths.traits, "no_config")
  stub.RemoveTalentApis(_G)
  stub.state.class = { "Shaman", "SHAMAN", 7 }
end

-- The rest of this file continues against a fresh, unrelated retail
-- instance, so the scenarios above cannot leak into the SavedVariables file
-- this script writes at the end.
_G.GameTooltip.OnShow = nil
EW = LoadFreshAddon(1, { "12.1.0", "60000", "Sep 17 2026", 120100 })
stub.state.units.player = { guid = "Player-3888-0A1B2C3E", name = "Thalos", level = 80, isPlayer = true }

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
-- From 0.2.6 the file carries the talent captures as a second global beside
-- EverythingWoWDB, the way the client writes an addon's two saved
-- variables, so check-file.mjs proves the site's parser still accepts it.
stub.state.class = { "Druid", "DRUID", 11 }
stub.InstallTraits(_G, TRAITS_SPEC)
EW.SlashCommand("talents")
stub.RemoveTalentApis(_G)
stub.state.class = { "Shaman", "SHAMAN", 7 }

local file = assert(io.open(outputPath, "w"))
file:write("\nEverythingWoWDB = " .. Serialize(db(), 0) .. "\n")
file:write("EverythingWoWTalentsDB = " .. Serialize(_G.EverythingWoWTalentsDB, 0) .. "\n")
file:close()

check("the written file holds every kind the run recorded", #observations() >= 7, #observations())
local mainCount = #observations()

--[[
0.2.3: a second file from a Forever session, the owner's own build 1.60.1 on
the mainline project id, so check-file.mjs can prove the site's parser
reads its forever version key. Combat log and the classic auction scan are
off on Forever, so this file holds what that client actually records: an npc
sighting, a quest start, a vendor, a loot window read off its own source
guid, an object, and a snapshot, and from 0.2.6 a browse page and a
commodity search read through the modern auction reader.
]]
local foreverOutputPath = (outputPath:gsub("%.lua$", "")) .. "-forever.lua"
_G.GameTooltip.OnShow = nil
stub.InstallModernAuction(_G, AUCTION_SPEC)
local foreverFile = LoadFreshAddon(1, { "1.60.1", "70000", "Nov 4 2026", 16001 })
stub.state.units.player = { guid = "Player-3888-0A1B2C3E", name = "Thalos", level = 11, isPlayer = true }
foreverFile.SlashCommand("clear")
stub.Fire("AUCTION_HOUSE_SHOW")
stub.state.time = stub.state.time + 61
stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
stub.Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
stub.RemoveModernAuction(_G)
stub.state.units.nameplate1 = {
  guid = "Creature-0-3888-0-11-2914-000136DF91", name = "Kobold Vermin",
  level = 3, reaction = 2, classification = "normal",
}
stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
stub.Fire("QUEST_DETAIL")
stub.Fire("MERCHANT_SHOW")
stub.state.loot = { { id = 2589, quantity = 2, source = "Creature-0-3888-0-11-2914-000136DF96" } }
stub.Fire("LOOT_OPENED")
foreverFile.RecordObjectFromGuid("GameObject-0-3888-0-11-1731-000136DF98", true)
foreverFile.TakeSnapshot(true)
-- The launch day read: three classic trees for each of nine classes, so the
-- Forever file carries the size the owner's own file will.
stub.InstallClassicTalents(_G, CLASSIC_TABS)
for _, class in ipairs({
  { "Warrior", "WARRIOR", 1 }, { "Paladin", "PALADIN", 2 }, { "Hunter", "HUNTER", 3 },
  { "Rogue", "ROGUE", 4 }, { "Priest", "PRIEST", 5 }, { "Shaman", "SHAMAN", 7 },
  { "Mage", "MAGE", 8 }, { "Warlock", "WARLOCK", 9 }, { "Druid", "DRUID", 11 },
}) do
  stub.state.class = class
  foreverFile.SlashCommand("talents")
end
stub.RemoveTalentApis(_G)
stub.state.class = { "Shaman", "SHAMAN", 7 }
local foreverTalents = _G.EverythingWoWTalentsDB
equal("nine classes give nine forever captures", CountKeys(foreverTalents.captures), 9)
local foreverDb = foreverFile.Database()
equal("the forever file's version key is forever", foreverDb.version, "forever")
equal("the forever file's client key is forever", foreverDb.client, "forever")
equal("the forever file carries the 0.2.6 addon version", foreverDb.addon, "0.2.6")
check("the forever file holds what that client records", #foreverDb.observations >= 7, #foreverDb.observations)
local foreverAuctions = 0
for _, observation in ipairs(foreverDb.observations) do
  if observation.kind == "auction" then foreverAuctions = foreverAuctions + 1 end
end
equal("the forever file holds a browse page and a commodity search", foreverAuctions, 2)
local foreverHandle = assert(io.open(foreverOutputPath, "w"))
foreverHandle:write("\nEverythingWoWDB = " .. Serialize(foreverDb, 0) .. "\n")
foreverHandle:write("EverythingWoWTalentsDB = " .. Serialize(foreverTalents, 0) .. "\n")
foreverHandle:close()

--[[
0.2.4: a Burning Crusade Classic file and a Mists Classic file, so
check-file.mjs can prove the site's parser reads classic_tbc and
classic_mop, joined in 0.2.5 by a Wrath of the Lich King Classic file and a
Cataclysm Classic file for classic_wrath and classic_cata. All four clients
carry the Classic Era row, so each records what Classic Era records: an npc sighting, a quest start, a vendor on the
positional merchant api, a kill and its loot, an object, a snapshot, and an
auction page off the scan.
]]
local function WriteClassicFile(suffix, project, build, key)
  local path = (outputPath:gsub("%.lua$", "")) .. "-" .. suffix .. ".lua"
  _G.GameTooltip.OnShow = nil
  local addon = LoadFreshAddon(project, build)
  stub.state.units.player = { guid = "Player-3888-0A1B2C3E", name = "Thalos", level = 60, isPlayer = true }
  addon.SlashCommand("clear")
  stub.state.merchantApi = "legacy"
  stub.state.units.nameplate1 = {
    guid = "Creature-0-3888-0-11-2914-000136DF91", name = "Kobold Vermin",
    level = 3, reaction = 2, classification = "normal",
  }
  stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
  stub.Fire("QUEST_DETAIL")
  stub.Fire("MERCHANT_SHOW")
  stub.state.loot = { { id = 2589, quantity = 2, source = "Creature-0-3888-0-11-2914-000136DF97" } }
  stub.state.combatLog = { subevent = "UNIT_DIED", destGuid = "Creature-0-3888-0-11-2914-000136DF97" }
  stub.state.units.target = { guid = "Creature-0-3888-0-11-2914-000136DF97" }
  stub.Fire("COMBAT_LOG_EVENT_UNFILTERED")
  stub.Fire("LOOT_OPENED")
  addon.RecordObjectFromGuid("GameObject-0-3888-0-11-1731-000136DF99", true)
  addon.TakeSnapshot(true)
  stub.Fire("AUCTION_ITEM_LIST_UPDATE")
  stub.state.merchantApi = "modern"
  local saved = addon.Database()
  equal("the " .. suffix .. " file's version key is " .. key, saved.version, key)
  equal("the " .. suffix .. " file's client key is " .. key, saved.client, key)
  equal("the " .. suffix .. " file carries the 0.2.6 addon version", saved.addon, "0.2.6")
  local kinds = {}
  for _, observation in ipairs(saved.observations) do kinds[observation.kind] = true end
  check("the " .. suffix .. " file holds an auction page off the scan", kinds.auction == true)
  check("the " .. suffix .. " file holds a kill's loot", kinds.loot == true)
  check("the " .. suffix .. " file holds what that client records", #saved.observations >= 7, #saved.observations)
  local handle = assert(io.open(path, "w"))
  handle:write("\nEverythingWoWDB = " .. Serialize(saved, 0) .. "\n")
  handle:close()
  return path, #saved.observations
end

local tbcOutputPath, tbcCount = WriteClassicFile("tbc", 5, { "2.5.6", "63000", "Sep 17 2026", 20506 }, "classic_tbc")
local mopOutputPath, mopCount = WriteClassicFile("mists", 19, { "5.5.4", "64000", "Sep 17 2026", 50504 }, "classic_mop")
local wrathOutputPath, wrathCount = WriteClassicFile("wrath", 11, { "3.80.2", "60000", "Sep 17 2026", 38002 }, "classic_wrath")
local cataOutputPath, cataCount = WriteClassicFile("cata", 14, { "4.4.2", "60000", "Sep 17 2026", 40402 }, "classic_cata")

print(string.format("%d passed, %d failed. File written to %s with %d observations, %s with %d, %s with %d, %s with %d, %s with %d, and %s with %d.",
  passed, failed, outputPath, mainCount, foreverOutputPath, #foreverDb.observations,
  tbcOutputPath, tbcCount, mopOutputPath, mopCount, wrathOutputPath, wrathCount, cataOutputPath, cataCount))
if failed > 0 then os.exit(1) end
