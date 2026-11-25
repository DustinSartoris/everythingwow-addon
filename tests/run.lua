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

local FILES = { "Core", "Known", "Items", "Units", "Objects", "Quests", "Vendor", "Loot", "Flights", "Rides", "Snapshot", "Talents", "Auction", "Deals", "TravelData", "Travel", "TravelMap", "TravelCoords", "Places", "Window" }

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
equal("addon is the addon version", saved.addon, "0.4.1")
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

-- 0.2.8: the creature type, and the title from the unit's own tooltip.
clear()
stub.state.units.mouseover = {
  guid = "Creature-0-3888-0-11-6740-000136DFC1", name = "Innkeeper Allison", level = 30,
  reaction = 5, classification = "normal", creatureType = "Humanoid",
}
stub.state.tooltip = { unit = "mouseover", line2 = "Innkeeper" }
stub.Fire("UPDATE_MOUSEOVER_UNIT")
equal("an npc carries its creature type", last().payload.creature_type, "Humanoid")
equal("an npc carries the title its tooltip shows", last().payload.title, "Innkeeper")

clear()
stub.state.units.mouseover = {
  guid = "Creature-0-3888-0-11-6741-000136DFC2", name = "Mottled Boar", level = 2,
  reaction = 4, classification = "normal", creatureType = "Beast",
}
stub.state.tooltip = { unit = "mouseover", line2 = "Level 2 Beast" }
stub.Fire("UPDATE_MOUSEOVER_UNIT")
equal("a creature with no title still carries its type", last().payload.creature_type, "Beast")
equal("the level line is never taken for a title", last().payload.title, nil)

clear()
stub.state.units.nameplate1 = {
  guid = "Creature-0-3888-0-11-6742-000136DFC3", name = "Stormwind Guard", level = 55,
  reaction = 5, classification = "normal", creatureType = "Humanoid",
}
stub.state.tooltip = { unit = "mouseover", line2 = "Innkeeper" }
stub.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
equal("a tooltip on another unit gives no title", last().payload.title, nil)
equal("and the type is still read from the unit itself", last().payload.creature_type, "Humanoid")

clear()
stub.state.units.mouseover = {
  guid = "Creature-0-3888-0-11-6743-000136DFC4", name = "Odd One", level = 10,
  reaction = 4, classification = "normal",
}
stub.state.tooltip = { unit = "mouseover", line2 = "|cffff0000Painted|r" }
stub.Fire("UPDATE_MOUSEOVER_UNIT")
equal("a line with a color code is not a title", last().payload.title, nil)
equal("no creature type is written where the client names none", last().payload.creature_type, nil)
stub.state.tooltip = { unit = "mouseover", line2 = string.rep("x", 65) }
stub.state.units.mouseover.guid = "Creature-0-3888-0-11-6744-000136DFC5"
stub.Fire("UPDATE_MOUSEOVER_UNIT")
equal("a line past 64 characters is not a title", last().payload.title, nil)
stub.state.tooltip = nil
stub.state.units.mouseover.guid = "Creature-0-3888-0-11-6745-000136DFC6"
stub.Fire("UPDATE_MOUSEOVER_UNIT")
equal("no tooltip gives no title", last().payload.title, nil)

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

-- 0.2.11: what the quest window says, with the player scrubbed out of it.
clear()
stub.state.questId = 2865
stub.state.questTitle = "Scarab Shells"
stub.state.questText = "Thalos, my cousin in Booty Bay needs shells.\r\n\r\nBring them to me, |cffffd200Thalos|r!"
stub.state.questObjectives = "Bring 5 Uncracked Scarab Shells to Tran'rek in Gadgetzan."
stub.state.questCompletion = "Oh, great! You got them!\n\nThanks, Thalos. You're a real lifesaver!"
stub.state.questRewards = { { id = 9527, name = "Spellshifter Rod" }, { id = 4306, q = 5, name = "Silk Cloth" } }
stub.state.questChoices = {
  { id = 9531, name = "Gemshale Pauldrons" }, { id = 270098, noLink = true, name = "Dank Shoulderpads" },
  { id = 9533, name = "A |cffff0000painted|r name" },
}
stub.state.questMoney = 8500
stub.state.questXp = 2650
_G.C_QuestLog = { GetQuestDifficultyLevel = function(questId) return questId == 2865 and 45 or 0 end }
stub.Fire("QUEST_DETAIL")
local offered = last()
equal("the offer keeps its title", offered.payload.title, "Scarab Shells")
equal("the offer records the quest's text with the player's name scrubbed and its color codes gone",
  offered.payload.text, "<name>, my cousin in Booty Bay needs shells.\n\nBring them to me, <name>!")
equal("the offer records the objectives", offered.payload.objectives,
  "Bring 5 Uncracked Scarab Shells to Tran'rek in Gadgetzan.")
equal("the offer carries no completion text", offered.payload.completion, nil)
equal("the offer lists the rewards", #offered.payload.rewards, 2)
equal("a reward's id is read from its link", offered.payload.rewards[1].id, 9527)
equal("a reward of one writes no quantity", offered.payload.rewards[1].q, nil)
equal("a reward of several writes how many", offered.payload.rewards[2].q, 5)
equal("the offer lists the choices", #offered.payload.choices, 3)
equal("a choice with no link is read from its item info", offered.payload.choices[2].id, 270098)
equal("a reward carries its name as the window shows it", offered.payload.rewards[1].n, "Spellshifter Rod")
equal("so does a choice the item index may not hold", offered.payload.choices[2].n, "Dank Shoulderpads")
equal("a name with a color code is left out and its id kept", offered.payload.choices[3].n, nil)
equal("with its id", offered.payload.choices[3].id, 9533)
equal("the offer records the money in copper", offered.payload.money, 8500)
equal("the offer records the experience", offered.payload.xp, 2650)
equal("the offer records the quest's level", offered.payload.level, 45)
equal("the offer is not marked cut", offered.payload.cut, nil)
stub.Fire("QUEST_COMPLETE")
local handedIn = last()
equal("the turn in records what the NPC says, scrubbed", handedIn.payload.completion,
  "Oh, great! You got them!\n\nThanks, <name>. You're a real lifesaver!")
equal("the turn in carries no offer text", handedIn.payload.text, nil)
equal("the turn in lists the rewards too", #handedIn.payload.rewards, 2)
for _, observation in ipairs(observations()) do
  for _, field in ipairs({ "text", "objectives", "completion" }) do
    local value = observation.payload and observation.payload[field]
    check("no recorded quest text holds the player's name", value == nil or value:find("Thalos", 1, true) == nil, value)
  end
end

-- A name of two words is scrubbed whole and word by word.
do
  local held = stub.state.units.player
  stub.state.units.player = { guid = held.guid, name = "Aldric Stonehand", level = 80, isPlayer = true }
  equal("a surname alone is scrubbed", EW.QuestText("Stonehand, is it? Aldric Stonehand and Aldric.", 500),
    "<name>, is it? <name> and <name>.")
  equal("a longer word that only starts with the name is left alone", EW.QuestText("Aldrics are common here.", 500),
    "Aldrics are common here.")
  stub.state.units.player = held
end

-- What is refused, and what is cut.
equal("a text holding a link is refused whole", EW.QuestText("Take this |Hitem:1::|h[Thing]|h to him.", 500), nil)
equal("a text holding a control character is refused whole", EW.QuestText("Take\tthis.", 500), nil)
equal("an empty text is nothing", EW.QuestText("  \r\n ", 500), nil)
equal("a value that is not text is nothing", EW.QuestText(42, 500), nil)
equal("three blank lines become one", EW.QuestText("One.\n\n\n\nTwo.", 500), "One.\n\nTwo.")
equal("a long text is cut to its length", #EW.QuestText(string.rep("word ", 1000), 1600) <= 1600, true)
equal("a cut never splits a character", EW.CutBytes("\195\169\195\169\195\169", 3), "\195\169")
equal("a cut at a boundary keeps the whole characters", EW.CutBytes("\195\169\195\169\195\169", 4), "\195\169\195\169")
equal("a short text is not cut", EW.CutBytes("short", 100), "short")

-- A quest whose text swells in JSON is shortened to fit, never dropped.
clear()
stub.state.questId = 2866
stub.state.questTitle = "A Quest of Many Quotes"
stub.state.questText = string.rep('"', 1600)
stub.state.questObjectives = string.rep('"', 600)
stub.Fire("QUEST_DETAIL")
local swollen = last()
equal("the swollen quest is still recorded", swollen.id, 2866)
check("its payload fits the reader's cap", EW.JsonBytes(swollen.payload) <= EW.PAYLOAD_CAP, EW.JsonBytes(swollen.payload))
equal("and says it was cut", swollen.payload.cut, true)
check("and still holds text", type(swollen.payload.text) == "string" and #swollen.payload.text > 0)
equal("and was not replaced by the trim marker", swollen.payload.trimmed, nil)

-- A client with none of the quest window functions records as before.
clear()
do
  local held = {}
  for _, name in ipairs({ "GetQuestText", "GetObjectiveText", "GetRewardText", "GetNumQuestRewards",
    "GetNumQuestChoices", "GetQuestItemLink", "GetQuestItemInfo", "GetRewardMoney", "GetRewardXP" }) do
    held[name] = _G[name]
    _G[name] = nil
  end
  _G.C_QuestLog = nil
  stub.state.questId = 2867
  stub.state.questTitle = "A Plain Quest"
  stub.Fire("QUEST_DETAIL")
  local plain = last()
  equal("a client without the functions still records the quest", plain.id, 2867)
  equal("with its title", plain.payload.title, "A Plain Quest")
  equal("and no text", plain.payload.text, nil)
  equal("and no rewards", plain.payload.rewards, nil)
  equal("and raises nothing", EW.lastError, nil)
  for name, value in pairs(held) do _G[name] = value end
end
stub.state.questText, stub.state.questObjectives, stub.state.questCompletion = nil, nil, nil
stub.state.questRewards, stub.state.questChoices, stub.state.questMoney, stub.state.questXp = nil, nil, nil, nil
_G.C_QuestLog = nil

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

-- The byte budgets, from 0.2.7. Auction pages give up their own oldest first
-- and never push out the rest, the whole buffer stays under its file budget,
-- and a file already over budget shrinks when the addon loads.
local function AuctionPage(seed)
  local rows = {}
  for index = 1, 50 do
    rows[index] = { id = 100000 + seed * 100 + index, q = 20, unit = 123456789, buyout = 987654321 }
  end
  return { source = "browse", items = rows }
end
local function AuctionBytes()
  local _, auction = EW.BufferBytes()
  return auction
end
local function JsonTotal()
  local total, auction = 0, 0
  for _, observation in ipairs(observations()) do
    local bytes = EW.JsonBytes(observation)
    total = total + bytes
    if observation.kind == "auction" then auction = auction + bytes end
  end
  return total, auction
end

clear()
for index = 1, 50 do
  EW.Record("npc", "npc", 910000 + index, 84, 0.5, 0.5, { level = 1 })
end
local auctionPages = 0
while AuctionBytes() <= EW.MAX_AUCTION_BYTES - 4000 do
  auctionPages = auctionPages + 1
  EW.Record("auction", "auction", nil, nil, nil, nil, AuctionPage(auctionPages))
end
equal("nothing is dropped while auction pages fit their budget", db().dropped, 0)
for index = 1, 200 do
  auctionPages = auctionPages + 1
  EW.Record("auction", "auction", nil, nil, nil, nil, AuctionPage(auctionPages))
end
check("auction pages stay inside their budget", AuctionBytes() <= EW.MAX_AUCTION_BYTES, AuctionBytes())
check("pages over the auction budget are dropped and counted", db().dropped >= 200, db().dropped)
equal("auction pages never push out an npc", observations()[1].id, 910001)
local npcsLeft = 0
for _, observation in ipairs(observations()) do
  if observation.kind == "npc" then npcsLeft = npcsLeft + 1 end
end
equal("every npc is still held", npcsLeft, 50)
equal("the newest auction page is held", last().payload.items[1].id, 100000 + auctionPages * 100 + 1)
local runningTotal, runningAuction = EW.BufferBytes()
local measuredTotal, measuredAuction = JsonTotal()
equal("the running total matches a fresh measure", runningTotal, measuredTotal)
equal("the running auction total matches a fresh measure", runningAuction, measuredAuction)

-- The file budget binds on everything, oldest first.
clear()
local big = {}
for index = 1, 60 do big[index] = { id = 200000 + index, price = 123456, currency = 1166 } end
for index = 1, 1600 do
  EW.Record("vendor", "vendor", 920000 + index, 84, 0.1, 0.1, { items = big })
end
local fileTotal = EW.BufferBytes()
check("the buffer stays under its file budget", fileTotal <= EW.MAX_FILE_BYTES, fileTotal)
check("the file budget drops the oldest", observations()[1].id > 920001, observations()[1].id)
equal("the newest vendor is held", last().id, 921600)

-- A file written before 0.2.7, over both budgets, shrinks when the addon loads.
local oversized = { schema = 1, version = "forever", observations = {}, dropped = 0 }
for index = 1, 4000 do
  oversized.observations[index] = {
    kind = "auction", subject = "auction", t = index, payload = AuctionPage(index),
  }
end
_G.EverythingWoWDB = oversized
stub.Fire("ADDON_LOADED", "EverythingWoW")
local loadedTotal, loadedAuction = EW.BufferBytes()
check("an old oversized file is pruned to the auction budget", loadedAuction <= EW.MAX_AUCTION_BYTES, loadedAuction)
check("an old oversized file is pruned to the file budget", loadedTotal <= EW.MAX_FILE_BYTES, loadedTotal)
equal("pruning keeps the newest page", last().t, 4000)
equal("pruning counts what it let go", db().dropped, 4000 - #observations())
_G.EverythingWoWDB = nil
clear()

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
  check("status prints the 0.2.7 addon version",
    text:find("version 0.4.1", 1, true) ~= nil, text)
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
0.2.12: the item recorder in Items.lua. Blizzard's item API answers 404 for
the new WoW Forever items its own auction houses sell, so the addon notes
such an item once, from the client's item cache, wherever a recorder meets
one. The stand in cache below answers GetItemInfo, GetItemStats and
GetItemSpell from ITEM_CACHE; an id it does not hold is an item the client
has not loaded yet.
]]
do
  local ITEM_CACHE = {
    [263015] = { name = "Skyborne Scout's Hood", quality = 3, level = 48, min = 43, stack = 1,
      slot = "INVTYPE_HEAD", sell = 12045, class = 4, subclass = 2, bind = 2,
      stats = { ITEM_MOD_STAMINA_SHORT = 9, ITEM_MOD_AGILITY_SHORT = 14, RESISTANCE0_NAME = 112,
        ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 12.3456, lowercase_key = 4, ZERO = 0, ["BAD KEY"] = 3 } },
    [274048] = { name = "Zephras Dustbloom", quality = 1, level = 40, min = 0, stack = 200,
      slot = "", sell = 95, class = 7, subclass = 9, spell = 440221 },
    [216483] = { name = "Painted |cffff0000Thing|r", quality = 1, level = 1 },
    [19019] = { name = "Thunderfury", quality = 5, level = 80, sell = 30000000 },
  }
  local asked = {}
  local function InstallItemCache()
    _G.GetItemInfo = function(item)
      asked[#asked + 1] = item
      local row = type(item) == "number" and ITEM_CACHE[item] or nil
      if not row then return nil end
      return row.name, "|cffffffff|Hitem:" .. item .. "::::::::80:::::|h[" .. row.name .. "]|h|r", row.quality,
        row.level, row.min, "Armor", "Leather", row.stack, row.slot, 135000, row.sell, row.class, row.subclass,
        row.bind, 0, nil, false
    end
    _G.GetItemStats = function(link)
      local id = tonumber(tostring(link):match("^item:(%d+)$"))
      local row = id and ITEM_CACHE[id] or nil
      return row and row.stats or nil
    end
    _G.GetItemSpell = function(item)
      local row = ITEM_CACHE[item]
      if row and row.spell then return "Use", row.spell end
      return nil
    end
  end
  local function RemoveItemCache()
    _G.GetItemInfo, _G.GetItemStats, _G.GetItemSpell = nil, nil, nil
  end
  local function Items(addon)
    local list = {}
    for _, observation in ipairs(addon.Database().observations) do
      if observation.kind == "item" then list[#list + 1] = observation end
    end
    return list
  end

  -- These cases use made up ids, so every session starts with an empty list of known items.
  local function FreshItems(project, build)
    local addon = LoadFreshAddon(project, build)
    addon.KNOWN_ITEMS = ""
    return addon
  end
  local savedLoot, savedMerchant, savedTime = stub.state.loot, stub.state.merchant, stub.state.time
  local savedRewards, savedQuestId, savedQuestTitle = stub.state.questRewards, stub.state.questId, stub.state.questTitle
  local savedNpc = stub.state.units.npc
  InstallItemCache()
  -- The auction house is the modern one, as on the owner's client, and it
  -- has to stand before the addon loads for the reader to find it.
  stub.InstallModernAuction(_G, { browse = { { id = 213422, q = 40, min = 300 }, { id = 2589, q = 5, min = 120 } } })

  -- Forever, the one client the recorder runs on.
  local gate = FreshItems(1, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  gate.SlashCommand("clear")
  equal("an item under the floor is not noted", gate.NoteItem(19019), false)
  equal("and the item cache was never asked for it", #asked, 0)
  equal("a link that is a currency's is left alone", gate.NoteItem(263015, "|Hcurrency:263015|h[Coin]|h"), false)
  equal("something that is not a number is left alone", gate.NoteItem("263015"), false)
  equal("no observation was written for any of them", #Items(gate), 0)

  equal("a new forever item is noted the first time it is met", gate.NoteItem(263015), true)
  local hood = Items(gate)[1]
  equal("the observation's kind is item", hood.kind, "item")
  equal("its subject is item", hood.subject, "item")
  equal("its id is the item's", hood.id, 263015)
  equal("it carries no map", hood.map, nil)
  equal("it carries no position", hood.x, nil)
  equal("the name is the client's", hood.payload.n, "Skyborne Scout's Hood")
  equal("the quality number", hood.payload.ql, 3)
  equal("the item level", hood.payload.il, 48)
  equal("the level it requires", hood.payload.rl, 43)
  equal("the class number", hood.payload.c, 4)
  equal("the subclass number", hood.payload.sc, 2)
  equal("the equip location token", hood.payload.slot, "INVTYPE_HEAD")
  equal("a stack of one is left out", hood.payload.stack, nil)
  equal("what a vendor pays", hood.payload.sell, 12045)
  equal("the binding number", hood.payload.bind, 2)
  equal("a stat by the client's own key", hood.payload.stats.ITEM_MOD_STAMINA_SHORT, 9)
  equal("armor rides with the stats", hood.payload.stats.RESISTANCE0_NAME, 112)
  equal("a fraction is kept to two places", hood.payload.stats.ITEM_MOD_DAMAGE_PER_SECOND_SHORT, 12.35)
  equal("a key that is not the client's kind is left out", hood.payload.stats.lowercase_key, nil)
  equal("a key with a space is left out", hood.payload.stats["BAD KEY"], nil)
  equal("a stat of zero is left out", hood.payload.stats.ZERO, nil)
  equal("an item with no use carries no spell", hood.payload.sp, nil)
  check("the payload sits far under the reader's cap", gate.JsonBytes(hood.payload) < 600, gate.JsonBytes(hood.payload))
  equal("the item was asked for by its bare id", asked[#asked], 263015)

  equal("the same item is not noted twice", gate.NoteItem(263015), false)
  equal("so the file still holds one", #Items(gate), 1)
  equal("the saved file remembers the day it was noted", gate.Database().items[263015],
    math.floor(stub.state.time / 86400))

  equal("a stacking item with a use is noted too", gate.NoteItem(274048, "|Hitem:274048::::|h[Zephras Dustbloom]|h"), true)
  local bloom = Items(gate)[2]
  equal("its stack size is kept", bloom.payload.stack, 200)
  equal("the spell its use triggers is kept", bloom.payload.sp, 440221)
  equal("a required level of zero is left out", bloom.payload.rl, nil)
  equal("an empty equip location is left out", bloom.payload.slot, nil)
  equal("an item with no stats carries no stats table", bloom.payload.stats, nil)

  equal("a name holding a client code is refused", gate.NoteItem(216483), false)
  local before = #asked
  equal("and is not asked for again this session", gate.NoteItem(216483), false)
  equal("the cache was left alone", #asked, before)

  -- An item the client has not loaded is tried again when it has.
  equal("an item the client has not loaded writes nothing", gate.NoteItem(287014), false)
  local _, waiting = gate.ItemCounts()
  equal("it waits for another try", waiting, 1)
  ITEM_CACHE[287014] = { name = "Emberwake Signet", quality = 2, level = 44, slot = "INVTYPE_FINGER", sell = 4410 }
  stub.state.time = stub.state.time + 2
  gate.NoteItem(263015)
  equal("the next item met a second later brings it in", #Items(gate), 3)
  equal("under its own id", Items(gate)[3].id, 287014)
  _, waiting = gate.ItemCounts()
  equal("and nothing is left waiting", waiting, 0)

  -- An item the client never loads is given up on for the session.
  for _ = 1, gate.ITEM_PENDING_TRIES + 2 do
    stub.state.time = stub.state.time + 2
    gate.NoteItem(299999)
  end
  _, waiting = gate.ItemCounts()
  equal("an item that never loads stops being asked for", waiting, 0)

  -- The recorders that meet items hand them over.
  ITEM_CACHE[270099] = { name = "Magister Cowl", quality = 2, level = 45, slot = "INVTYPE_HEAD", sell = 5120 }
  ITEM_CACHE[270098] = { name = "Dank Shoulderpads", quality = 2, level = 44, slot = "INVTYPE_SHOULDER", sell = 4980 }
  ITEM_CACHE[279886] = { name = "Skyborne Ration", quality = 1, level = 45, stack = 20, sell = 125 }
  ITEM_CACHE[213422] = { name = "Zephras Silk", quality = 1, level = 40, stack = 200, sell = 150 }
  stub.state.loot = { { id = 270099, quantity = 1, source = "Creature-0-3888-0-11-2914-000136DF99" } }
  stub.Fire("LOOT_OPENED")
  local function Has(addon, itemId)
    for _, observation in ipairs(Items(addon)) do
      if observation.id == itemId then return true end
    end
    return false
  end
  check("an item in a loot window is noted", Has(gate, 270099))
  stub.state.units.npc = { guid = "Creature-0-3888-0-11-3500-000136DF9A", name = "Vendor", level = 30 }
  stub.state.merchant = { { id = 279886, price = 500, quantity = 5 } }
  stub.Fire("MERCHANT_SHOW")
  check("an item a vendor sells is noted", Has(gate, 279886))
  stub.state.questId = 96026
  stub.state.questTitle = "Step Two: More Rock"
  stub.state.questRewards = { { id = 270098, name = "Dank Shoulderpads" } }
  stub.Fire("QUEST_COMPLETE")
  check("an item a quest rewards is noted", Has(gate, 270098))
  stub.Fire("AUCTION_HOUSE_SHOW")
  stub.state.time = stub.state.time + 61
  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  check("an item in the auction house's browse list is noted", Has(gate, 213422))
  check("an old item in the same list is not", not Has(gate, 2589))
  equal("the auction reader sent no query for it", stub.state.auctionCalls.SendBrowseQuery, nil)
  stub.RemoveModernAuction(_G)

  -- The session cap, the fortnight and the clear.
  local count = #Items(gate)
  local wrote = gate.ItemCounts()
  equal("the session counts what it wrote", wrote, count)
  for id = 280001, 280000 + gate.ITEMS_PER_SESSION do
    ITEM_CACHE[id] = { name = "Item " .. id, quality = 1, level = 40 }
    gate.NoteItem(id)
  end
  wrote = gate.ItemCounts()
  equal("a session writes no more than its cap", wrote, gate.ITEMS_PER_SESSION)
  local lastId = 280000 + gate.ITEMS_PER_SESSION
  equal("an item past the cap is not remembered as noted", gate.Database().items[lastId], nil)

  gate.SlashCommand("clear")
  equal("clear forgets which items were noted", gate.Database().items, nil)
  equal("so an item is noted again after it", gate.NoteItem(263015), true)
  stub.state.time = stub.state.time + (gate.ITEM_RENOTE_DAYS - 1) * 86400
  equal("inside the fortnight a new session's memory holds", gate.Database().items[263015] ~= nil, true)

  -- A new session reads the saved memory: the same file, a fresh load.
  local savedDb = _G.EverythingWoWDB
  local second = FreshItems(1, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  _G.EverythingWoWDB = savedDb
  equal("a new session does not note an item the file remembers", second.NoteItem(263015), false)
  stub.state.time = stub.state.time + 2 * 86400
  equal("nor again later in that session", second.NoteItem(263015), false)
  equal("an item the file does not remember is noted in it", second.NoteItem(270099), true)
  savedDb = _G.EverythingWoWDB
  local third = FreshItems(1, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  _G.EverythingWoWDB = savedDb
  equal("a session past the fortnight notes it again", third.NoteItem(263015), true)
  equal("but not an item noted inside it", third.NoteItem(270099), false)
  savedDb = _G.EverythingWoWDB
  local patched = FreshItems(1, { "1.60.2", "70400", "Dec 2 2026", 16001 })
  _G.EverythingWoWDB = savedDb
  equal("after a patch every item is noted afresh", patched.NoteItem(274048), true)
  equal("and the memory starts over for the patch", patched.Database().itemsPatch, "1.60.2")

  -- Every other client leaves items alone.
  for _, client in ipairs({
    { "retail", 1, { "12.1.0", "60000", "Sep 17 2026", 120100 } },
    { "classic era", 2, { "1.15.9", "60000", "Sep 17 2026", 11509 } },
    { "mists classic", 19, { "5.5.4", "60000", "Sep 17 2026", 50504 } },
  }) do
    local other = FreshItems(client[2], client[3])
    equal(client[1] .. " notes no item", other.NoteItem(263015), false)
    equal(client[1] .. " writes no item observation", #Items(other), 0)
    equal(client[1] .. " keeps no item memory", other.Database().items, nil)
  end

  RemoveItemCache()
  -- A client with no item cache functions at all writes nothing and throws nothing.
  local bare = FreshItems(1, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  equal("forever with no item functions notes nothing", bare.NoteItem(263015), false)

  stub.state.loot, stub.state.merchant, stub.state.time = savedLoot, savedMerchant, savedTime
  stub.state.questRewards, stub.state.questId, stub.state.questTitle = savedRewards, savedQuestId, savedQuestTitle
  stub.state.units.npc = savedNpc
end

--[[
0.2.13: the list of items the site already has, in Known.lua. On 24 November
2026 the owner's first file from 0.2.12 held 400 item observations and 340
of them were items the site had from Blizzard, so the recorder now leaves a
listed item alone. The list is a string of ids and "low-high" ranges.
]]
do
  local asked = {}
  _G.GetItemInfo = function(item)
    asked[#asked + 1] = item
    return "Item " .. tostring(item), nil, 1, 40, nil, "Armor", "Cloth", 1, "", 135000, 10, 4, 1
  end
  local gate = LoadFreshAddon(1, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  gate.SlashCommand("clear")

  -- The shipped list.
  local count, ids, last, ordered = 0, 0, 0, true
  for part in gate.KNOWN_ITEMS:gmatch("[^,]+") do
    local low, high = part:match("^(%d+)%-(%d+)$")
    if not low then low = part:match("^(%d+)$") high = low end
    low, high = tonumber(low), tonumber(high)
    if not low or low <= last or high < low then ordered = false break end
    count, ids, last = count + 1, ids + high - low + 1, high
  end
  check("the shipped list is ids and ranges in rising order", ordered)
  equal("the shipped list holds 2,147 ranges", count, 2147)
  equal("covering 11,770 ids", ids, 11770)
  check("every listed id is at or above the recorder's floor", tonumber(gate.KNOWN_ITEMS:match("^(%d+)")) >= gate.ITEM_ID_FLOOR)
  equal("the list carries its date", gate.KNOWN_ITEMS_DATE, "2026-11-24")
  equal("an item the site has is known", gate.ItemKnown(277104), true)
  equal("the first listed id is known", gate.ItemKnown(202251), true)
  equal("the last listed id is known", gate.ItemKnown(291874), true)
  equal("an item the site lacks is not", gate.ItemKnown(274048), false)
  equal("an id above the list is not", gate.ItemKnown(291875), false)
  equal("an id under the list is not", gate.ItemKnown(202250), false)

  equal("a listed item is not noted", gate.NoteItem(277104), false)
  equal("and the item cache is never asked for it", #asked, 0)
  equal("an unlisted item is noted", gate.NoteItem(274048), true)
  equal("an id past the end of the list is noted", gate.NoteItem(291875), true)

  -- A list of the test's own: the ends of a range, a single id, the gaps.
  gate.KNOWN_ITEMS = "250000-250010,250020,250030-250031"
  for id, known in pairs({ [249999] = false, [250000] = true, [250005] = true, [250010] = true, [250011] = false,
    [250019] = false, [250020] = true, [250021] = false, [250030] = true, [250031] = true, [250032] = false }) do
    equal("in the test's list, " .. id .. " reads as " .. tostring(known), gate.ItemKnown(id), known)
  end
  equal("a listed id of the test's list is not noted", gate.NoteItem(250005), false)
  equal("the id beside it is", gate.NoteItem(250011), true)

  -- A list that cannot be read is no list: everything is noted, as before.
  for _, bad in ipairs({ "250000-249000", "250010,250005", "250000-abc", "250000--250010", 5 }) do
    gate.KNOWN_ITEMS = bad
    equal("a list written as " .. tostring(bad) .. " knows nothing", gate.ItemKnown(250005), false)
  end
  gate.KNOWN_ITEMS = nil
  equal("no list at all knows nothing", gate.ItemKnown(250005), false)
  equal("and its items are noted", gate.NoteItem(250006), true)
  gate.KNOWN_ITEMS = ""
  equal("an empty list knows nothing", gate.ItemKnown(250005), false)

  _G.GetItemInfo = nil
end

--[[
0.2.9: the vendor deal finder in Deals.lua. It reads the same loaded results
as the recorder and compares each price with what a vendor pays, which the
stand in client answers from SELL below through GetItemInfo. Nothing it
finds is written to the saved file. The window is built against a stand in
frame that accepts any call, installed for these tests alone; without it the
window cannot be built, which is the path that prints the list in chat.
]]
local SELL = {}
local function InstallItemInfo()
  _G.GetItemInfo = function(item)
    local id = type(item) == "number" and item or tonumber(tostring(item):match("item:(%d+)"))
    local row = id and SELL[id] or nil
    if not row then return nil end
    return row.name, "|cffffffff|Hitem:" .. id .. "::::::::80:::::|h[" .. row.name .. "]|h|r", 1,
      nil, nil, nil, nil, nil, nil, nil, row.sell
  end
end
local function RemoveItemInfo() _G.GetItemInfo = nil end

local function Plain(text)
  return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", ""))
end

--[[ A frame that accepts any method, keeps the text it is given and whether
     it is shown, and hands out more of itself for font strings and textures. ]]
local function MockFrame()
  local mock = { shown = true, scripts = {} }
  return setmetatable(mock, { __index = function(_, key)
    if type(key) ~= "string" or not key:match("^%u") then return nil end
    if key == "SetText" then return function(self, text) self.text = text end end
    if key == "Show" then return function(self) self.shown = true end end
    if key == "Hide" then return function(self) self.shown = false end end
    if key == "IsShown" then return function(self) return self.shown end end
    if key == "SetScript" then return function(self, which, handler) self.scripts[which] = handler end end
    if key == "CreateFontString" or key == "CreateTexture" then return function() return MockFrame() end end
    return function() end
  end })
end
local realCreateFrame
local function InstallWindowFrames()
  realCreateFrame = _G.CreateFrame
  _G.CreateFrame = function(kind, name, ...)
    if name == "EverythingWoWDealsFrame" or kind == "Button" then return MockFrame() end
    return realCreateFrame(kind, name, ...)
  end
end
local function RemoveWindowFrames()
  if realCreateFrame then _G.CreateFrame = realCreateFrame end
  realCreateFrame = nil
end

local function DealFor(addon, itemId)
  for _, deal in ipairs(addon.DealList()) do
    if deal.id == itemId then return deal end
  end
  return nil
end

equal("money reads as gold, silver and copper", Plain(EW.Money(123456)), "12g 34s 56c")
equal("money under a silver reads as copper alone", Plain(EW.Money(7)), "7c")
equal("money of a whole gold keeps its zeros", Plain(EW.Money(10000)), "1g 0s 0c")
equal("money that is not a number reads as unknown", EW.Money(nil), "?")

local DEAL_SPEC = {
  browse = {
    { id = 2589, q = 400, min = 120 },
    { id = 2592, q = 35, min = 410 },
    { id = 4306, q = 9, min = 90 },
    { id = 82800, q = 1, min = 990000, pet = 39 },
  },
  commodities = {
    -- Twenty at 120 and five at 124 are under the vendor's 125; three of
    -- the five are the player's own, so two of them are theirs to buy.
    [2589] = { { q = 20, unit = 120 }, { q = 5, unit = 124, own = 3 }, { q = 5, unit = 125 }, { q = 200, unit = 131 } },
  },
  items = {
    [19019] = {
      { q = 1, buyout = 25000000 }, { q = 1 }, { q = 1, buyout = 26000000, mine = true },
      { q = 1, buyout = 31000000 },
    },
    -- The owner's own screen of 23 November 2026: the client groups
    -- identical auctions into one row, and its buyout is the price of one.
    [856] = {
      { q = 15, buyout = 867 }, { q = 10, buyout = 869 }, { q = 1, buyout = 875 },
      { q = 5, buyout = 880 }, { q = 2, buyout = 1000 },
    },
  },
}

-- Forever, on the mainline project id, with the window buildable.
do
  _G.GameTooltip.OnShow = nil
  SELL = {
    [2589] = { name = "Linen Cloth", sell = 125 },
    [2592] = { name = "Wool Cloth", sell = 400 },
    [4306] = { name = "Silk Cloth", sell = 0 },
    [19019] = { name = "Thunderfury", sell = 30000000 },
    [856] = { name = "Blue Leather Bag", sell = 875 },
  }
  InstallItemInfo()
  InstallWindowFrames()
  stub.InstallModernAuction(_G, DEAL_SPEC)
  local gate = LoadFreshAddon(1, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  gate.SlashCommand("clear")
  equal("forever's deal finder reads the modern auction house", gate.DealsMode(), "modern")

  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  equal("no deal is read before the auction house first opens", gate.DealCount(), 0)

  stub.state.combat = true
  stub.Fire("AUCTION_HOUSE_SHOW")
  equal("opening the auction house in combat registers no deal reader", gate.dealsModernEvents, nil)
  stub.state.combat = false

  stub.state.printed = {}
  stub.Fire("AUCTION_HOUSE_SHOW")
  equal("the deal finder registers the six result events", gate.dealsModernEvents, 6)
  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  equal("the browse list finds the one item under its vendor price", gate.DealCount(), 1)
  local linen = DealFor(gate, 2589)
  check("the deal is the linen cloth", linen ~= nil)
  equal("a browse row is not exact", linen.exact, false)
  equal("a browse row is the price of one", linen.count, 1)
  equal("a browse row keeps the lowest price", linen.low, 120)
  equal("a browse row's profit is the vendor price less the lowest price", linen.profit, 5)
  equal("an item priced over its vendor price is no deal", DealFor(gate, 2592), nil)
  equal("an item no vendor buys is never a deal", DealFor(gate, 4306), nil)
  equal("a battle pet's row is passed over", DealFor(gate, 82800), nil)
  equal("a browse row reads as one or more", Plain(gate.DealLine(linen)),
    "[Linen Cloth]: from 1s 20c each, vendor 1s 25c each, profit 5c or more")

  check("the window opened by itself for the first deal", gate.dealsWindow ~= nil and gate.dealsWindow:IsShown())
  equal("the window's first row names the item", Plain(gate.dealsWindow.rows[1].name.text), "[Linen Cloth]")
  equal("the window's first row says what one costs", Plain(gate.dealsWindow.rows[1].buy.text), "1+ from 1s 20c each")
  equal("the window's second row is hidden", gate.dealsWindow.rows[2]:IsShown(), false)
  equal("the window prints nothing in chat", #stub.state.printed, 0)

  stub.Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
  linen = DealFor(gate, 2589)
  equal("a commodity search makes the row exact", linen.exact, true)
  equal("it counts every unit under the vendor price but the player's own", linen.count, 22)
  equal("it adds up what they cost", linen.cost, 20 * 120 + 2 * 124)
  equal("it adds up what a vendor pays", linen.value, 22 * 125)
  equal("its profit is the difference", linen.profit, 22 * 125 - (20 * 120 + 2 * 124))
  equal("an exact row reads as what to buy", Plain(gate.DealLine(linen)),
    "[Linen Cloth]: buy 22 for 26s 48c, vendor 27s 50c, profit 1s 2c")
  equal("the open window follows the search", Plain(gate.dealsWindow.rows[1].buy.text), "Buy 22 for 26s 48c")
  equal("and shows the profit", Plain(gate.dealsWindow.rows[1].profit.text), "+1s 2c")

  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  equal("going back to the list keeps the exact row", DealFor(gate, 2589).exact, true)

  stub.Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 19019, itemLevel = 80, itemSuffix = 0, battlePetSpeciesID = 0 })
  local sword = DealFor(gate, 19019)
  check("an item search finds the auction under its vendor price", sword ~= nil)
  equal("it leaves out the auction with no buyout, the player's own and the dear one", sword.count, 1)
  equal("it costs the auction's buyout", sword.cost, 25000000)
  equal("its profit is the vendor price less the buyout", sword.profit, 5000000)
  equal("the list puts the most profit first", gate.DealList()[1].id, 19019)
  equal("the window's first row is now the sword", Plain(gate.dealsWindow.rows[1].name.text), "[Thunderfury]")

  -- 0.2.10: a row of many at one price is the price of one, times how many.
  stub.Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 856, itemLevel = 15, itemSuffix = 0, battlePetSpeciesID = 0 })
  local bag = DealFor(gate, 856)
  check("a grouped item row under its vendor price is a deal", bag ~= nil)
  equal("it counts only the rows priced under the vendor price", bag.count, 25)
  equal("it costs the price of one times how many, row by row", bag.cost, 15 * 867 + 10 * 869)
  equal("a vendor pays for each of them", bag.value, 25 * 875)
  equal("its profit is the small difference, not the whole price", bag.profit, 25 * 875 - (15 * 867 + 10 * 869))
  equal("the row reads as it would in the auction house", Plain(gate.DealLine(bag)),
    "[Blue Leather Bag]: buy 25 for 2g 16s 95c, vendor 2g 18s 75c, profit 1s 80c")
  local bagRows = {}
  for _, observation in ipairs(gate.Database().observations) do
    if observation.kind == "auction" and observation.payload.source == "item" then
      for _, item in ipairs(observation.payload.items) do
        if item.id == 856 then bagRows[#bagRows + 1] = item end
      end
    end
  end
  equal("the recorder writes the five grouped rows", #bagRows, 5)
  equal("with the price of one as the unit", bagRows[1].unit, 867)
  equal("and the price of the whole row as the buyout", bagRows[1].buyout, 15 * 867)
  equal("and how many there are", bagRows[1].q, 15)

  -- A floor on the profit, for a list full of deals worth a few copper.
  equal("money is read as the player types it", gate.ParseMoney("1g 20s"), 12000)
  equal("a bare number is copper", gate.ParseMoney("75"), 75)
  equal("silver alone is read", gate.ParseMoney("50s"), 5000)
  equal("anything else is refused", gate.ParseMoney("lots"), nil)
  equal("and so is a number with a stray word", gate.ParseMoney("5s please"), nil)
  gate.SlashCommand("deals min 1s")
  equal("the floor is kept", gate.DealsMinProfit(), 100)
  equal("a deal under the floor is not counted", gate.DealCount(), 3)
  equal("nor listed", DealFor(gate, 2589) ~= nil and DealFor(gate, 2589).profit >= 100, true)
  gate.SlashCommand("deals min 2s")
  equal("a higher floor hides more", gate.DealCount(), 1)
  stub.state.printed = {}
  gate.SlashCommand("deals min soon")
  check("a floor that is not money prints how to use it",
    table.concat(stub.state.printed, "\n"):find("/ewow deals min 50s", 1, true) ~= nil)
  gate.SlashCommand("deals min 0")
  equal("a floor of nothing shows every deal again", gate.DealCount(), 3)

  equal("the deal finder sent no browse query", stub.state.auctionCalls.SendBrowseQuery, nil)
  equal("the deal finder sent no search query", stub.state.auctionCalls.SendSearchQuery, nil)
  equal("the deal finder sent no sell search query", stub.state.auctionCalls.SendSellSearchQuery, nil)

  local saved = gate.Database()
  for _, observation in ipairs(saved.observations) do
    check("only the recorder's own kinds reach the saved file", observation.kind == "auction", observation.kind)
  end
  check("the saved file never names a deal", not Mentions(saved, "deal") and not Mentions(saved, "profit"))

  -- The market moves: the cheap linen is bought out and the search says so.
  DEAL_SPEC.commodities[2589] = { { q = 5, unit = 125 }, { q = 200, unit = 131 } }
  stub.Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
  equal("a search with nothing under the vendor price drops the row", DealFor(gate, 2589), nil)
  DEAL_SPEC.commodities[2589] = { { q = 20, unit = 120 }, { q = 5, unit = 124, own = 3 }, { q = 5, unit = 125 }, { q = 200, unit = 131 } }

  stub.state.combat = true
  equal("nothing is read in combat", gate.OnDealCommodityResults(2589), 0)
  stub.state.combat = false

  -- The slash command.
  gate.SlashCommand("deals")
  equal("/ewow deals closes the open window", gate.dealsWindow:IsShown(), false)
  gate.SlashCommand("deals")
  equal("/ewow deals opens it again", gate.dealsWindow:IsShown(), true)
  stub.state.printed = {}
  gate.SlashCommand("deals list")
  local listed = Plain(table.concat(stub.state.printed, "\n"))
  check("/ewow deals list prints the deals", listed:find("2 items under vendor price:", 1, true) ~= nil
    and listed:find("[Thunderfury]: buy 1 for 2500g 0s 0c, vendor 3000g 0s 0c, profit 500g 0s 0c", 1, true) ~= nil, listed)
  gate.SlashCommand("deals clear")
  equal("/ewow deals clear empties the list", gate.DealCount(), 0)
  stub.state.printed = {}
  gate.SlashCommand("help")
  check("the command list names /ewow deals", table.concat(stub.state.printed, "\n"):find("/ewow deals", 1, true) ~= nil)

  -- A new visit starts a new list, and with auto off it says so in chat once.
  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  equal("the list fills again", gate.DealCount(), 1)
  gate.SlashCommand("deals auto off")
  equal("auto can be turned off", gate.DealsAutoOpen(), false)
  gate.dealsWindow:Hide()
  stub.Fire("AUCTION_HOUSE_SHOW")
  equal("opening the auction house again clears the list", gate.DealCount(), 0)
  stub.state.printed = {}
  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  equal("with auto off the window stays closed", gate.dealsWindow:IsShown(), false)
  equal("and one line of chat says a deal was found", #stub.state.printed, 1)
  check("naming the command", Plain(stub.state.printed[1]):find("1 item is listed under vendor price. Type /ewow deals to see them.", 1, true) ~= nil,
    stub.state.printed[1])

  -- An item the client has not loaded has no sell price yet, and is asked again.
  gate.SlashCommand("deals auto on")
  stub.Fire("AUCTION_HOUSE_SHOW")
  local held = SELL[2589]
  SELL[2589] = nil
  stub.state.timers = {}
  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  equal("an item not loaded yet is no deal", gate.DealCount(), 0)
  check("and a retry is queued", #stub.state.timers == 1)
  SELL[2589] = held
  stub.RunTimers(5)
  equal("once the client has loaded it the deal appears", gate.DealCount(), 1)
  equal("and nothing was raised along the way", gate.lastError, nil)

  stub.RemoveModernAuction(_G)
  RemoveWindowFrames()
  RemoveItemInfo()
end

-- Forever again, on a client where the window cannot be built: the list
-- goes to chat instead, and nothing is raised.
do
  _G.GameTooltip.OnShow = nil
  InstallItemInfo()
  stub.InstallModernAuction(_G, DEAL_SPEC)
  local gate = LoadFreshAddon(1, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  stub.Fire("AUCTION_HOUSE_SHOW")
  stub.state.printed = {}
  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  equal("a window that cannot be built leaves none", gate.dealsWindow, nil)
  local printed = Plain(table.concat(stub.state.printed, "\n"))
  check("and the deal is printed in chat instead", printed:find("[Linen Cloth]: from 1s 20c each", 1, true) ~= nil, printed)
  stub.state.printed = {}
  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  equal("but only once in a visit", #stub.state.printed, 0)
  equal("and nothing is raised", gate.lastError, nil)
  stub.RemoveModernAuction(_G)
  RemoveItemInfo()
end

-- Forever with no sell prices at all, as before 0.2.9's stand in existed:
-- the finder holds nothing, prints nothing and asks for nothing.
do
  _G.GameTooltip.OnShow = nil
  stub.InstallModernAuction(_G, DEAL_SPEC)
  local gate = LoadFreshAddon(1, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  stub.Fire("AUCTION_HOUSE_SHOW")
  stub.state.printed = {}
  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  equal("a client that gives no item info finds no deal", gate.DealCount(), 0)
  equal("and prints nothing", #stub.state.printed, 0)
  stub.RemoveModernAuction(_G)
end

-- Retail: the addon does not read its auction house, and neither does the finder.
do
  _G.GameTooltip.OnShow = nil
  InstallItemInfo()
  stub.InstallModernAuction(_G, DEAL_SPEC)
  local gate = LoadFreshAddon(1, { "12.1.0", "60000", "Sep 17 2026", 120100 })
  equal("retail's deal finder is idle", gate.DealsMode(), "idle")
  stub.Fire("AUCTION_HOUSE_SHOW")
  stub.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  stub.Fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
  equal("retail registers no deal reader", gate.dealsModernEvents, nil)
  equal("retail finds no deal", gate.DealCount(), 0)
  equal("retail's finder asks the client for nothing", next(stub.state.auctionCalls), nil)
  stub.RemoveModernAuction(_G)
  RemoveItemInfo()
end

-- Classic Era, without C_AuctionHouse: one page of the list.
do
  _G.GameTooltip.OnShow = nil
  InstallItemInfo()
  InstallWindowFrames()
  local gate = LoadFreshAddon(2, { "1.15.9", "50000", "Sep 17 2026", 11509 })
  equal("classic era's deal finder reads the classic list", gate.DealsMode(), "classic")
  local heldAuction, heldPlayer = stub.state.auction, stub.state.units.player
  stub.state.units.player = { guid = "Player-3888-0A1B2C3E", name = "Thalos", level = 60, isPlayer = true }
  stub.state.auction = {
    { id = 2589, count = 20, buyout = 2000 },
    { id = 2589, count = 10, buyout = 1300 },
    { id = 2589, count = 5, buyout = 500, owner = "Thalos" },
    { id = 2589, count = 3 },
    { id = 2592, count = 2, buyout = 900 },
  }
  stub.Fire("AUCTION_HOUSE_SHOW")
  stub.Fire("AUCTION_ITEM_LIST_UPDATE")
  local linen = DealFor(gate, 2589)
  check("the classic page finds the stack under its vendor price", linen ~= nil)
  equal("it counts the one stack that is a deal", linen.count, 20)
  equal("it costs that stack's buyout", linen.cost, 2000)
  equal("its profit is what a vendor pays less the buyout", linen.profit, 20 * 125 - 2000)
  equal("a classic row is exact", linen.exact, true)
  equal("the dear stack is no deal", DealFor(gate, 2592), nil)
  equal("the page is read once however often it is announced", (function()
    stub.Fire("AUCTION_ITEM_LIST_UPDATE")
    return DealFor(gate, 2589).count
  end)(), 20)
  stub.state.auction = { { id = 2592, count = 2, buyout = 900 } }
  stub.Fire("AUCTION_ITEM_LIST_UPDATE")
  check("a deal on an earlier page is kept while another page is read", DealFor(gate, 2589) ~= nil)
  stub.state.auction, stub.state.units.player = heldAuction, heldPlayer
  equal("and nothing was raised", gate.lastError, nil)
  RemoveWindowFrames()
  RemoveItemInfo()
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
  equal("the capture holds the addon version", capture.addon, "0.4.1")
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
-- 0.2.11: the Forever file carries a quest with its text, line breaks, an
-- apostrophe, a quotation mark and the name token, so the site's own parser
-- is shown everything the quest recorder can write.
stub.state.questText = "Thalos, they say \"the shells are worth a fortune\".\r\n\r\nDon't believe it, Thalos."
stub.state.questObjectives = "Bring 5 Uncracked Scarab Shells to Tran'rek in Gadgetzan."
stub.state.questRewards = { { id = 9527 }, { id = 4306, q = 5 } }
stub.state.questChoices = { { id = 9531 } }
stub.state.questMoney = 8500
stub.state.questXp = 2650
stub.Fire("QUEST_DETAIL")
stub.state.questText, stub.state.questObjectives = nil, nil
stub.state.questRewards, stub.state.questChoices, stub.state.questMoney, stub.state.questXp = nil, nil, nil, nil
stub.Fire("MERCHANT_SHOW")
stub.state.loot = { { id = 2589, quantity = 2, source = "Creature-0-3888-0-11-2914-000136DF96" } }
stub.Fire("LOOT_OPENED")
foreverFile.RecordObjectFromGuid("GameObject-0-3888-0-11-1731-000136DF98", true)
foreverFile.TakeSnapshot(true)
-- 0.2.12: the Forever file carries one item observation, with its stats
-- table, and the saved memory of the day it was noted, a table keyed by
-- item id at the root, so the site's own parser is shown both.
_G.GetItemInfo = function(item)
  if item ~= 263015 then return nil end
  return "Skyborne Scout's Hood", nil, 3, 48, 43, "Armor", "Leather", 1, "INVTYPE_HEAD", 135000, 12045, 4, 2, 2
end
_G.GetItemStats = function() return { ITEM_MOD_STAMINA_SHORT = 9, ITEM_MOD_AGILITY_SHORT = 14, RESISTANCE0_NAME = 112 } end
equal("the forever file notes a new item", foreverFile.NoteItem(263015), true)
_G.GetItemInfo, _G.GetItemStats = nil, nil
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
equal("the forever file carries the 0.4.1 addon version", foreverDb.addon, "0.4.1")
check("the forever file holds what that client records", #foreverDb.observations >= 8, #foreverDb.observations)
equal("the forever file's last observation is the item", foreverDb.observations[#foreverDb.observations].kind, "item")
check("the forever file remembers the item it noted", type(foreverDb.items) == "table" and foreverDb.items[263015] ~= nil)
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
  equal("the " .. suffix .. " file carries the 0.4.1 addon version", saved.addon, "0.4.1")
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

-- The flight recorder, from 0.3.1.
dofile(root .. "tests/flights.lua")({ check = check, equal = equal, stub = stub, root = root, LoadFreshAddon = LoadFreshAddon })

-- The ride recorder, from 0.4.1.
dofile(root .. "tests/rides.lua")({ check = check, equal = equal, stub = stub, root = root, LoadFreshAddon = LoadFreshAddon })

-- The route planner, from 0.3.0: its own file of cases and checks.
dofile(root .. "tests/travel.lua")({ check = check, equal = equal, stub = stub, root = root, LoadFreshAddon = LoadFreshAddon })

-- The window and the minimap button, from 0.4.1.
dofile(root .. "tests/places.lua")({ check = check, equal = equal, stub = stub, root = root, LoadFreshAddon = LoadFreshAddon })

-- The window, with the places on the game's own maps before it, from 0.4.1.
dofile(root .. "tests/window.lua")({ check = check, equal = equal, stub = stub, root = root, LoadFreshAddon = LoadFreshAddon })

print(string.format("%d passed, %d failed. File written to %s with %d observations, %s with %d, %s with %d, %s with %d, %s with %d, and %s with %d.",
  passed, failed, outputPath, mainCount, foreverOutputPath, #foreverDb.observations,
  tbcOutputPath, tbcCount, mopOutputPath, mopCount, wrathOutputPath, wrathCount, cataOutputPath, cataCount))
if failed > 0 then os.exit(1) end
