--[[
Everything WoW Companion, the recorder core.

This file owns the saved file, the ring buffer that fills it, the payload
caps, the de-duplication rule, the event dispatch every recorder registers
against, and the slash command. The recorders in the other files only gather
a value and hand it to EW.Record.

The saved table is the observation file contract version 1, which the site
reads at everythingwow.com/addons/companion/upload. The reader that has to
accept this file is src/lib/companion/read.ts in the application repository,
so the names here are its names and not a second vocabulary: schema is the
number 1, version is the game version key, addon is this addon's version,
patch comes from GetBuildInfo, and every observation carries kind, id,
subject, map, x, y, t, and payload.
]]

local ADDON_NAME, EW = ...

EW.ADDON_VERSION = "0.1.1"
EW.SCHEMA = 1

-- The ring buffer holds this many observations and drops the oldest when it
-- is full, because the site sends at most 5,000 observations in one upload.
EW.MAX_OBSERVATIONS = 5000
-- The per kind payload caps the reader applies, in bytes of JSON. An
-- observation above its cap is dropped by the reader rather than emptied, so
-- the writer trims before it stores.
EW.PAYLOAD_CAP = 4000
EW.SNAPSHOT_PAYLOAD_CAP = 64000
-- One pin sighting per subject per map per five minutes.
EW.DEDUPE_SECONDS = 300

-- The kinds the reader accepts, in its own order.
EW.KINDS = {
  "npc", "object", "quest_start", "quest_end", "objective", "loot",
  "vendor", "trainer", "flight", "auction", "rare", "character_snapshot",
}

local KIND_SET = {}
for _, kind in ipairs(EW.KINDS) do KIND_SET[kind] = true end

-- The kinds the de-duplication rule covers. A loot observation is one kill or
-- one open of a source and the drop rate denominator counts them, so loot is
-- never de-duplicated. A character snapshot is taken on login and on demand
-- and both are wanted. An auction page is a fresh reading every time.
local DEDUPE_KINDS = {
  npc = true, rare = true, object = true, vendor = true,
  quest_start = true, quest_end = true, trainer = true, flight = true,
}

-- The order in which a payload's lists give up entries when it is over its
-- cap. The first list that still holds an entry loses its last one, and the
-- payload is measured again.
local TRIM_ORDER = {
  character_snapshot = { "reputations", "currencies", "professions", "talents", "gear" },
  loot = { "items" },
  vendor = { "items" },
  auction = { "items" },
}
local DEFAULT_TRIM_ORDER = { "items" }

local lastSeen = {}
local lastSeenCount = 0

local function Now()
  local ok, value = pcall(time)
  if ok and type(value) == "number" then return math.floor(value) end
  return 0
end
EW.Now = Now

function EW.Print(text)
  local line = "|cff8b5cf6Everything WoW|r: " .. tostring(text)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(line)
  else
    print(line)
  end
end

--[[
The game version key, which is one of the keys the site's versions table
holds. WOW_PROJECT_ID is the only documented way a client says which game it
is: WOW_PROJECT_MAINLINE is Retail and every other project is in the Classic
Era family for our purposes, where a hardcore realm reports hardcore.

Forever is not detectable. Blizzard has published no project id for it, so a
Forever client answers with whatever project id its build carries and this
function records it as classic_era. The rule stands until Blizzard ships a
project id constant for Forever, at which point one branch is added here and
nothing else in the addon changes. A Forever upload is therefore attributed
to Classic Era until then, which is honest about what the client can tell us.
]]
function EW.VersionKey()
  local project = rawget(_G, "WOW_PROJECT_ID")
  local mainline = rawget(_G, "WOW_PROJECT_MAINLINE")
  if project == nil or (mainline ~= nil and project == mainline) then
    return "retail"
  end

  local hardcore = false
  pcall(function()
    if C_GameRules and C_GameRules.IsHardcoreActive then
      hardcore = C_GameRules.IsHardcoreActive() and true or false
    elseif type(rawget(_G, "IsHardcoreActive")) == "function" then
      hardcore = IsHardcoreActive() and true or false
    end
  end)
  if hardcore then return "hardcore" end
  return "classic_era"
end

--[[ The patch string, such as 12.1.0 on Retail and 1.15.9 on Classic Era. ]]
function EW.Patch()
  local patch
  pcall(function() patch = (GetBuildInfo()) end)
  if type(patch) ~= "string" or patch == "" then return nil end
  return string.sub(patch, 1, 32)
end

--[[
The player's map and position. C_Map gives the position as two fractions from
0 to 1 with the origin at the top left of the map image, which is the
coordinate contract the site and the aggregation are written against, so
nothing is converted here beyond rounding to four decimals.
]]
function EW.PlayerPosition()
  local mapId, x, y
  pcall(function()
    if not C_Map or not C_Map.GetBestMapForUnit then return end
    mapId = C_Map.GetBestMapForUnit("player")
    if not mapId then return end
    local position = C_Map.GetPlayerMapPosition(mapId, "player")
    if not position then return end
    if position.GetXY then
      x, y = position:GetXY()
    else
      x, y = position.x, position.y
    end
  end)
  if type(x) ~= "number" or type(y) ~= "number" then return mapId, nil, nil end
  if x < 0 or x > 1 or y < 0 or y > 1 then return mapId, nil, nil end
  return mapId, EW.Round(x, 4), EW.Round(y, 4)
end

function EW.Round(value, places)
  local factor = 10 ^ (places or 0)
  return math.floor(value * factor + 0.5) / factor
end

--[[
The subject type and the id inside a GUID. A creature GUID is
Creature-0-serverId-instanceId-zoneUid-creatureId-spawnUid and a game object
GUID has the same sixth field, so one reader serves both. A player GUID
carries no id we record, and this returns nothing for it, which is how the
recorders avoid ever writing another player.
]]
function EW.SubjectFromGuid(guid)
  if type(guid) ~= "string" then return nil, nil end
  local unitType = string.match(guid, "^(%a+)%-")
  if not unitType then return nil, nil end
  local sixth = string.match(guid, "^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
  local id = tonumber(sixth)
  if unitType == "Creature" or unitType == "Vehicle" then
    return "npc", id
  elseif unitType == "GameObject" then
    return "object", id
  elseif unitType == "Item" then
    return "item", nil
  end
  return nil, nil
end

--[[ Byte counting that matches the reader, which measures JSON.stringify. ]]
local function NumberBytes(value)
  if value ~= value or value == math.huge or value == -math.huge then return 4 end
  if math.floor(value) == value and math.abs(value) < 1e15 then
    return #string.format("%d", value)
  end
  return #string.format("%.14g", value)
end

local function StringBytes(value)
  local bytes = 2
  for index = 1, #value do
    local byte = string.byte(value, index)
    if byte == 34 or byte == 92 then
      bytes = bytes + 2
    elseif byte == 8 or byte == 9 or byte == 10 or byte == 12 or byte == 13 then
      bytes = bytes + 2
    elseif byte < 32 then
      bytes = bytes + 6
    else
      bytes = bytes + 1
    end
  end
  return bytes
end

function EW.IsArray(value)
  if type(value) ~= "table" then return false end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" then return false end
    count = count + 1
  end
  return count > 0 and count == #value
end

function EW.JsonBytes(value)
  local kind = type(value)
  if kind == "number" then return NumberBytes(value) end
  if kind == "string" then return StringBytes(value) end
  if kind == "boolean" then return value and 4 or 5 end
  if kind ~= "table" then return 4 end

  if EW.IsArray(value) then
    local bytes = 2
    for index = 1, #value do
      if index > 1 then bytes = bytes + 1 end
      bytes = bytes + EW.JsonBytes(value[index])
    end
    return bytes
  end

  local bytes = 2
  local first = true
  for key, item in pairs(value) do
    if not first then bytes = bytes + 1 end
    first = false
    bytes = bytes + StringBytes(tostring(key)) + 1 + EW.JsonBytes(item)
  end
  return bytes
end

function EW.CapFor(kind)
  if kind == "character_snapshot" then return EW.SNAPSHOT_PAYLOAD_CAP end
  return EW.PAYLOAD_CAP
end

--[[
Trims a payload to its kind's cap before it is stored, because the reader
drops an oversized observation rather than emptying it. Lists give up their
last entry in the order TRIM_ORDER declares, and a payload that cannot be
brought under the cap that way is replaced by a marker, which is a small
honest record rather than a silently lost one.
]]
function EW.TrimPayload(kind, payload)
  if type(payload) ~= "table" then return payload end
  local cap = EW.CapFor(kind)
  if EW.JsonBytes(payload) <= cap then return payload end

  local order = TRIM_ORDER[kind] or DEFAULT_TRIM_ORDER
  payload.trimmed = true
  local guard = 0
  while EW.JsonBytes(payload) > cap and guard < 20000 do
    guard = guard + 1
    local removed = false
    for _, field in ipairs(order) do
      local list = payload[field]
      if type(list) == "table" and #list > 0 then
        table.remove(list, #list)
        removed = true
        break
      end
    end
    if not removed then
      return { trimmed = true }
    end
  end
  return payload
end

--[[ The saved table, created once and then only appended to. ]]
function EW.Database()
  local db = rawget(_G, "EverythingWoWDB")
  if type(db) ~= "table" then
    db = {}
    _G.EverythingWoWDB = db
  end
  db.schema = EW.SCHEMA
  db.version = EW.VersionKey()
  db.addon = EW.ADDON_VERSION
  db.patch = EW.Patch() or db.patch
  if type(db.observations) ~= "table" then db.observations = {} end
  if type(db.dropped) ~= "number" then db.dropped = 0 end
  if type(db.skipped) ~= "number" then db.skipped = 0 end
  if type(db.deduped) ~= "number" then db.deduped = 0 end
  if type(db.ignored) ~= "number" then db.ignored = 0 end
  if type(db.skips) ~= "table" then db.skips = {} end
  if type(db.dedupes) ~= "table" then db.dedupes = {} end
  if type(db.ignores) ~= "table" then db.ignores = {} end
  return db
end

--[[
The three counters, and why there are three rather than one.

Version 0.1.0 counted everything it did not write under skipped, so a few
minutes in Orgrimmar reported 802 skipped when almost nothing had been lost:
every tooltip over a bag item, every nameplate on another player, and every
sighting already written inside the five minute window was counted the same
way as a real loss. The three are now separated and each carries a reason, so
/ewow status says what actually happened.

skipped  A real loss: the addon had a subject id and could not place it,
         because the client returned no map or no position for the player.
         This is the only counter that means something went wrong.
deduped  A sighting inside the five minute de-duplication window. Expected,
         and the rule working.
ignored  Something the addon saw and was never going to record: another
         player, a pet, a vehicle, a tooltip that is not a world object. Also
         expected, and never a loss.
]]
local function Count(field, table_, reason)
  local db = EW.Database()
  db[field] = (db[field] or 0) + 1
  local counts = db[table_]
  if type(counts) == "table" then
    local key = tostring(reason or "unknown")
    counts[key] = (counts[key] or 0) + 1
  end
end

--[[ Counts a subject the addon could have recorded and could not place. ]]
function EW.CountSkipped(reason)
  Count("skipped", "skips", reason)
end

--[[ Counts a sighting the de-duplication window already holds. ]]
function EW.CountDeduped(reason)
  Count("deduped", "dedupes", reason)
end

--[[ Counts something the addon was never going to record. ]]
function EW.CountIgnored(reason)
  Count("ignored", "ignores", reason)
end

local function DedupeKey(kind, subject, id, map)
  return table.concat({ kind, tostring(subject), tostring(id), tostring(map) }, "|")
end

--[[
The one writer. Every recorder calls this and nothing else touches the saved
table. It applies the de-duplication rule, trims the payload to its cap, and
keeps the buffer at MAX_OBSERVATIONS by dropping the oldest observation and
counting it in dropped.
]]
function EW.Record(kind, subject, id, map, x, y, payload)
  if not KIND_SET[kind] then return false end
  local db = EW.Database()
  local now = Now()

  if DEDUPE_KINDS[kind] and id then
    local key = DedupeKey(kind, subject, id, map)
    local seen = lastSeen[key]
    if seen and (now - seen) < EW.DEDUPE_SECONDS then
      -- The window holding a sighting back is the rule working, not a loss.
      EW.CountDeduped(kind)
      return false
    end
    if lastSeen[key] == nil then lastSeenCount = lastSeenCount + 1 end
    lastSeen[key] = now
    -- The de-duplication memory is a session's, not a file's, so it is wiped
    -- rather than grown without bound.
    if lastSeenCount > 20000 then
      lastSeen = {}
      lastSeenCount = 0
    end
  end

  local observation = {
    kind = kind,
    subject = subject,
    id = id,
    map = map,
    x = x,
    y = y,
    t = now,
    payload = payload and EW.TrimPayload(kind, payload) or nil,
  }

  local list = db.observations
  list[#list + 1] = observation
  while #list > EW.MAX_OBSERVATIONS do
    table.remove(list, 1)
    db.dropped = db.dropped + 1
  end
  return true
end

--[[ Event dispatch. A recorder registers a handler and never owns a frame. ]]
local handlers = {}
local frame = CreateFrame("Frame", "EverythingWoWFrame")

function EW.RegisterEvent(event, handler)
  if not handlers[event] then
    handlers[event] = {}
    local ok = pcall(function() frame:RegisterEvent(event) end)
    if not ok then handlers[event] = nil end
  end
  if handlers[event] then
    table.insert(handlers[event], handler)
  end
end

function EW.Dispatch(event, ...)
  local list = handlers[event]
  if not list then return end
  for _, handler in ipairs(list) do
    -- A recorder that throws must never break the others or the game, and an
    -- API that differs between clients is exactly where that happens.
    local ok, err = pcall(handler, ...)
    if not ok then EW.lastError = tostring(err) end
  end
end

frame:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    local name = ...
    if name == ADDON_NAME then EW.Database() end
  end
  EW.Dispatch(event, ...)
end)
frame:RegisterEvent("ADDON_LOADED")

--[[ The slash command. ]]
--[[ The reasons in the order status prints them, so a reason a build stopped
     using still prints if the saved file holds it. ]]
local REASON_LABELS = {
  no_id = "no id",
  no_map = "no map",
  no_position = "no position",
  no_object_id = "tooltip with no object id",
  no_world_cursor = "no world cursor on this client",
  player = "player unit",
  pet = "own pet",
  vehicle = "vehicle",
}

local function ReasonLine(counts)
  local keys = {}
  for key in pairs(counts or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = string.format("%s %d", REASON_LABELS[key] or key, counts[key])
  end
  if #parts == 0 then return nil end
  return table.concat(parts, ", ")
end
EW.ReasonLine = ReasonLine

local function Status()
  local db = EW.Database()
  local counts = {}
  for _, observation in ipairs(db.observations) do
    counts[observation.kind] = (counts[observation.kind] or 0) + 1
  end
  EW.Print(string.format("version %s, game %s, patch %s.", EW.ADDON_VERSION, tostring(db.version), tostring(db.patch)))
  EW.Print(string.format("%d observations held, %d dropped.", #db.observations, db.dropped))
  for _, kind in ipairs(EW.KINDS) do
    if counts[kind] then EW.Print(string.format("  %s: %d", kind, counts[kind])) end
  end
  EW.Print(string.format("%d skipped, %d deduped, %d ignored.", db.skipped, db.deduped, db.ignored))
  local skips = ReasonLine(db.skips)
  if skips then EW.Print("  skipped: " .. skips) end
  local dedupes = ReasonLine(db.dedupes)
  if dedupes then EW.Print("  deduped: " .. dedupes) end
  local ignores = ReasonLine(db.ignores)
  if ignores then EW.Print("  ignored: " .. ignores) end
  EW.Print("Only skipped is a loss. Deduped and ignored are the addon working as it should.")
  EW.Print("Upload the file at https://everythingwow.com/addons/companion/upload")
end

local function Clear()
  local db = EW.Database()
  db.observations = {}
  db.dropped = 0
  db.skipped = 0
  db.deduped = 0
  db.ignored = 0
  db.skips = {}
  db.dedupes = {}
  db.ignores = {}
  lastSeen = {}
  lastSeenCount = 0
  EW.Print("Cleared. Nothing recorded before now is still held.")
end

function EW.SlashCommand(message)
  local command = string.lower(string.match(tostring(message or ""), "^%s*(%S*)") or "")
  if command == "status" or command == "" then
    Status()
  elseif command == "clear" then
    Clear()
  elseif command == "snapshot" then
    if EW.TakeSnapshot and EW.TakeSnapshot(true) then
      EW.Print("Character snapshot recorded.")
    else
      EW.Print("The snapshot could not be taken. Try again once the character sheet has loaded.")
    end
  elseif command == "path" then
    EW.Print("World of Warcraft\\WTF\\Account\\<ACCOUNT>\\SavedVariables\\EverythingWoW.lua")
    EW.Print("The file is written when you log out or reload the interface.")
  else
    EW.Print("Commands: /ewow status, /ewow clear, /ewow snapshot, /ewow path.")
  end
end

SLASH_EWOW1 = "/ewow"
SLASH_EWOW2 = "/everythingwow"
SlashCmdList["EWOW"] = EW.SlashCommand

_G.EverythingWoW = EW
