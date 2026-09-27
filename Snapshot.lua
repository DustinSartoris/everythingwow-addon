--[[
The character snapshot.

This is the player's own character and nothing else: the gear worn, the
talents chosen, the professions learned, the reputations earned, and the
currencies held. It is the one kind whose payload may reach 64,000 bytes,
because the character page is built from it on the versions where Blizzard's
Profile API is missing.

Gear is stored as each slot's item string, the item:id:enchant:gem part of
the item link, rather than the whole link. The client writes a saved string
with its pipe characters doubled, and a doubled pipe is not an escape the
site's reader understands, so the color codes are stripped here instead of
being mangled there. Everything the site needs, the enchant and the gems
included, is inside the item string.

Talents come from C_Traits on Retail, where one import string holds the whole
loadout, and from GetTalentInfo on Classic Era, where a rank per talent is
the whole of it. Both are wrapped, because this is exactly the API that
differs between clients.
]]

local ADDON_NAME, EW = ...

EW.SNAPSHOT_SLOTS = 19
EW.REPUTATION_CAP = 100
EW.CURRENCY_CAP = 60
--[[
When a snapshot is taken, and why so few of them.

The first live sample held two snapshots a hundred seconds apart, identical
except for their currencies: the login one fired before the client had loaded
the currency list, so it carried an empty list, and a second one was written
soon after for no gain. One snapshot a session is the rule now.

SNAPSHOT_LOGIN_DELAY is how long after entering the world the first attempt
is made, and the attempt is repeated every SNAPSHOT_RETRY_SECONDS until the
client answers with gear and currencies or SNAPSHOT_READY_TRIES attempts have
passed, at which point it is taken anyway, because a level one character with
an empty bag and no currencies is a real character and its snapshot is real.

After that, another snapshot is written only on /ewow snapshot, or when at
least SNAPSHOT_MIN_SECONDS have passed and the gear or the level has changed.
]]
EW.SNAPSHOT_LOGIN_DELAY = 10
EW.SNAPSHOT_RETRY_SECONDS = 5
EW.SNAPSHOT_READY_TRIES = 6
EW.SNAPSHOT_MIN_SECONDS = 3600

local function ItemString(link)
  if type(link) ~= "string" then return nil end
  local itemString = link:match("|H(item[%-%d:]+)|h")
  if itemString then return itemString end
  if link:match("^item:") then return link end
  return nil
end
EW.ItemString = ItemString

local function Gear()
  local gear = {}
  for slot = 1, EW.SNAPSHOT_SLOTS do
    local link
    pcall(function() link = GetInventoryItemLink("player", slot) end)
    local itemString = ItemString(link)
    if itemString then gear[#gear + 1] = { slot = slot, item = itemString } end
  end
  return gear
end

local function RetailTalents()
  local talents
  pcall(function()
    if not C_ClassTalents or not C_ClassTalents.GetActiveConfigID then return end
    local configId = C_ClassTalents.GetActiveConfigID()
    if not configId then return end
    local export
    if C_Traits and C_Traits.GenerateImportString then
      export = C_Traits.GenerateImportString(configId)
    end
    if type(export) == "string" and export ~= "" then
      talents = { { config = configId, export = export } }
      return
    end
    -- No import string, so the loadout is written node by node.
    if not C_Traits or not C_Traits.GetConfigInfo then return end
    local info = C_Traits.GetConfigInfo(configId)
    if type(info) ~= "table" or type(info.treeIDs) ~= "table" then return end
    local nodes = {}
    for _, treeId in ipairs(info.treeIDs) do
      for _, nodeId in ipairs(C_Traits.GetTreeNodes(treeId) or {}) do
        local node = C_Traits.GetNodeInfo(configId, nodeId)
        if type(node) == "table" and (node.ranksPurchased or 0) > 0 then
          nodes[#nodes + 1] = { n = nodeId, e = node.activeEntry and node.activeEntry.entryID or nil, r = node.ranksPurchased }
        end
      end
    end
    if #nodes > 0 then talents = nodes end
  end)
  return talents
end

local function ClassicTalents()
  local talents
  pcall(function()
    if type(rawget(_G, "GetTalentInfo")) ~= "function" then return end
    if type(rawget(_G, "GetNumTalentTabs")) ~= "function" then return end
    local rows = {}
    for tab = 1, (GetNumTalentTabs() or 0) do
      for index = 1, (GetNumTalents(tab) or 0) do
        local _, _, _, _, rank = GetTalentInfo(tab, index)
        if type(rank) == "number" and rank > 0 then
          rows[#rows + 1] = { tab = tab, i = index, r = rank }
        end
      end
    end
    if #rows > 0 then talents = rows end
  end)
  return talents
end

local function Professions()
  local professions = {}
  pcall(function()
    if type(rawget(_G, "GetProfessions")) == "function" then
      local indexes = { GetProfessions() }
      for _, index in ipairs(indexes) do
        local name, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(index)
        if name then
          professions[#professions + 1] = { id = skillLine, name = name, rank = rank, max = maxRank }
        end
      end
      return
    end
    if type(rawget(_G, "GetNumSkillLines")) == "function" then
      for index = 1, (GetNumSkillLines() or 0) do
        local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(index)
        if name and not isHeader and type(maxRank) == "number" and maxRank > 1 then
          professions[#professions + 1] = { name = name, rank = rank, max = maxRank }
        end
      end
    end
  end)
  return professions
end

local function Reputations()
  local reputations = {}
  pcall(function()
    if C_Reputation and C_Reputation.GetNumFactions and C_Reputation.GetFactionDataByIndex then
      for index = 1, (C_Reputation.GetNumFactions() or 0) do
        if #reputations >= EW.REPUTATION_CAP then return end
        local data = C_Reputation.GetFactionDataByIndex(index)
        if type(data) == "table" and not data.isHeader and data.factionID then
          reputations[#reputations + 1] = { id = data.factionID, s = data.reaction, v = data.currentStanding }
        end
      end
      return
    end
    if type(rawget(_G, "GetNumFactions")) == "function" then
      for index = 1, (GetNumFactions() or 0) do
        if #reputations >= EW.REPUTATION_CAP then return end
        local name, _, standing, _, _, value, _, _, isHeader, _, _, _, _, factionId = GetFactionInfo(index)
        if name and not isHeader then
          reputations[#reputations + 1] = { id = factionId, s = standing, v = value }
        end
      end
    end
  end)
  return reputations
end

local function Currencies()
  local currencies = {}
  pcall(function()
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then return end
    for index = 1, (C_CurrencyInfo.GetCurrencyListSize() or 0) do
      if #currencies >= EW.CURRENCY_CAP then return end
      local info = C_CurrencyInfo.GetCurrencyListInfo(index)
      if type(info) == "table" and not info.isHeader then
        local id
        if C_CurrencyInfo.GetCurrencyListLink then
          id = EW.IdFromLink(C_CurrencyInfo.GetCurrencyListLink(index))
        end
        currencies[#currencies + 1] = { id = id, name = info.name, q = info.quantity }
      end
    end
  end)
  return currencies
end

--[[ True once the client has answered with the things a snapshot is made of.
     Gear is the first thing to arrive and the currency list the last, so both
     are asked, and a character wearing nothing is not held back by the gear
     half alone. ]]
function EW.SnapshotReady()
  local hasGear = false
  for slot = 1, EW.SNAPSHOT_SLOTS do
    local link
    pcall(function() link = GetInventoryItemLink("player", slot) end)
    if type(link) == "string" and link ~= "" then
      hasGear = true
      break
    end
  end

  local currencyApi, hasCurrency = false, false
  pcall(function()
    if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize then
      currencyApi = true
      hasCurrency = (C_CurrencyInfo.GetCurrencyListSize() or 0) > 0
    end
  end)
  if not currencyApi then return hasGear end
  return hasGear and hasCurrency
end

--[[ The snapshot the session has already written, held in memory alone. ]]
local last = { at = nil, level = nil, gear = nil }
EW.snapshotState = last

local function GearSignature(gear)
  local parts = {}
  for _, entry in ipairs(gear or {}) do
    parts[#parts + 1] = tostring(entry.slot) .. ":" .. tostring(entry.item)
  end
  return table.concat(parts, "|")
end

--[[ Whether this snapshot is worth writing beside the one already held. ]]
function EW.ShouldSnapshot(force, level, signature)
  if force then return true end
  if last.at == nil then return true end
  if (EW.Now() - last.at) < EW.SNAPSHOT_MIN_SECONDS then return false end
  if level ~= last.level then return true end
  if signature ~= last.gear then return true end
  return false
end

--[[ Takes the snapshot. The character's own name and realm are part of it,
     because the snapshot exists to enrich that character's page; no other
     character and no other player appears anywhere in it. UnitName is called
     on "player" alone here, which is the contributor's own character. ]]
function EW.TakeSnapshot(force)
  local payload = {}
  local ok = pcall(function()
    payload.name = UnitName("player")
    payload.realm = GetRealmName and GetRealmName() or nil
    payload.level = UnitLevel("player")
    local className, classFile = UnitClass("player")
    payload.class = classFile or className
    local raceName, raceFile = UnitRace("player")
    payload.race = raceFile or raceName
    payload.faction = UnitFactionGroup("player")
  end)
  if not ok or not payload.name then return false end

  payload.gear = Gear()
  local signature = GearSignature(payload.gear)
  if not EW.ShouldSnapshot(force, payload.level, signature) then return false end

  payload.talents = RetailTalents() or ClassicTalents() or {}
  payload.professions = Professions()
  payload.reputations = Reputations()
  payload.currencies = Currencies()

  local mapId, x, y = EW.PlayerPosition()
  local written = EW.Record("character_snapshot", "character", nil, mapId, x, y, payload)
  if written then
    last.at = EW.Now()
    last.level = payload.level
    last.gear = signature
  end
  return written
end

--[[ The one login snapshot, once the client has the data to fill it. ]]
local scheduled = false

local function Attempt(try)
  if EW.SnapshotReady() or try >= EW.SNAPSHOT_READY_TRIES then
    pcall(EW.TakeSnapshot, false)
    return
  end
  local ok = pcall(function()
    C_Timer.After(EW.SNAPSHOT_RETRY_SECONDS, function() Attempt(try + 1) end)
  end)
  if not ok then pcall(EW.TakeSnapshot, false) end
end

function EW.ScheduleLoginSnapshot()
  if scheduled then return false end
  scheduled = true
  local ok, timed = pcall(function()
    if C_Timer and C_Timer.After then
      C_Timer.After(EW.SNAPSHOT_LOGIN_DELAY, function() Attempt(1) end)
      return true
    end
    return false
  end)
  -- A client with no timer takes it now and accepts what it has.
  if not (ok and timed) then pcall(EW.TakeSnapshot, false) end
  return true
end

EW.RegisterEvent("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
  if isLogin == false and isReload == false then return end
  EW.ScheduleLoginSnapshot()
end)
