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

local EW = {}
stub.Install(_G)

local FILES = { "Core", "Units", "Objects", "Quests", "Vendor", "Loot", "Snapshot", "Auction" }
for _, name in ipairs(FILES) do
  local chunk = assert(loadfile(root .. "EverythingWoW/" .. name .. ".lua"))
  chunk("EverythingWoW", EW)
end

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
equal("addon is the addon version", saved.addon, "0.1.0")
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
equal("an object whose id cannot be read is skipped and counted", db().skipped, skippedBefore + 1)

-- The character snapshot.
clear()
stub.state.inventory = { [1] = 19019, [5] = 16963, [16] = 17182 }
stub.state.factions = {}
for index = 1, 400 do
  stub.state.factions[index] = { id = 60 + index, name = "Faction " .. index, standing = 4, value = 2100 }
end
equal("a snapshot is recorded", EW.TakeSnapshot(), true)
local snapshot = last()
equal("snapshot kind", snapshot.kind, "character_snapshot")
equal("snapshot subject", snapshot.subject, "character")
equal("snapshot has no subject id", snapshot.id, nil)
equal("snapshot names the character", snapshot.payload.name, "Thalos")
equal("gear is stored as an item string", snapshot.payload.gear[1].item, "item:19019:6229::::::::80:::::")
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
EW.TakeSnapshot()
EW.OnAuctionListUpdate()

local file = assert(io.open(outputPath, "w"))
file:write("\nEverythingWoWDB = " .. Serialize(db(), 0) .. "\n")
file:close()

check("the written file holds every kind the run recorded", #observations() >= 7, #observations())
print(string.format("%d passed, %d failed. File written to %s with %d observations.",
  passed, failed, outputPath, #observations()))
if failed > 0 then os.exit(1) end
