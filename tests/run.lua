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
equal("addon is the addon version", saved.addon, "0.2.0")
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
check("retail installs the tooltip hook", _G.GameTooltip.OnShow ~= nil)

_G.GameTooltip.OnShow = nil
local classicGate = LoadFreshAddon(2, { "1.15.9", "50000", "Sep 17 2026", 11509 })
equal("a 1.15 build reads as classic era", classicGate.Client.key, "classic_era")
equal("classic era's world cursor capability is off", classicGate.Caps.worldCursor, false)
equal("classic era's unit guid capability is on", classicGate.Caps.unitGuid, true)
equal("classic era's combat log capability is on", classicGate.Caps.combatLog, true)
check("classic era never installs the tooltip hook", _G.GameTooltip.OnShow == nil)

_G.GameTooltip.OnShow = nil
-- Build 1.60.1 is the owner's own reading, on what the note expects to be
-- the shared Classic project id.
local foreverGate = LoadFreshAddon(2, { "1.60.1", "70000", "Nov 4 2026", 16001 })
equal("a 1.60 build on the classic project id reads as forever", foreverGate.Client.key, "forever")
equal("forever's world cursor capability defaults off", foreverGate.Caps.worldCursor, false)
equal("forever's unit guid capability defaults off", foreverGate.Caps.unitGuid, false)
equal("forever's combat log capability defaults off", foreverGate.Caps.combatLog, false)
check("forever never installs the tooltip hook", _G.GameTooltip.OnShow == nil)

-- Firing every gated event on the Forever instance writes no observation and
-- raises no error, because the capability is checked before the client is
-- ever asked anything, not after.
do
  stub.state.units.nameplate1 = {
    guid = "Creature-0-3888-0-11-2914-000136DF91", name = "Kobold Vermin",
    level = 3, reaction = 2,
  }
  stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
  equal("a gated guid reader writes no npc observation on forever",
    #foreverGate.Database().observations, 0)
  equal("a gated guid reader is counted as no id, not as a skip",
    foreverGate.Database().skipped, 0)

  stub.state.units.target = { guid = "Creature-0-3888-0-11-2914-000136DF91" }
  stub.state.combatLog = { subevent = "UNIT_DIED", destGuid = "Creature-0-3888-0-11-2914-000136DF91" }
  stub.Fire("COMBAT_LOG_EVENT_UNFILTERED")
  equal("the combat log listener is never registered on forever",
    #foreverGate.Database().observations, 0)

  local before = foreverGate.Database().ignored
  equal("the world cursor path refuses without calling the client", foreverGate.RecordCursorObject(), false)
  equal("and it is counted as ignored, the same reason as no world cursor at all",
    foreverGate.Database().ignored, before + 1)
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
    secondGate.Caps.unitGuid and secondGate.Caps.combatLog)
  stub.Fire("ADDON_ACTION_BLOCKED", "EverythingWoW")
  check("a report naming no function turns every capability off",
    not secondGate.Caps.unitGuid and not secondGate.Caps.combatLog and not secondGate.Caps.worldCursor)
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
check("an unknown client never installs the tooltip hook", _G.GameTooltip.OnShow == nil)

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
