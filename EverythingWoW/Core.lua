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

EW.ADDON_VERSION = "0.2.1"
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

Forever is not detectable by project id. Blizzard has published none of its
own for it, and the owner's own build 1.60.1 reading came back carrying
WOW_PROJECT_ID equal to WOW_PROJECT_MAINLINE, the same id Retail reports,
rather than the Classic id this function was written expecting. This
function is left unchanged regardless: the site's versions table has no
enabled row for forever yet (that lands with EW.RunProbe below and a
version rows change on the site), so an upload has to keep sending a key
the site already accepts. A Forever session is therefore attributed to
retail here, not classic_era as first assumed, which is honest about what
this function alone can tell, though EW.ReadClient below no longer makes
the same mistake for anything that is not this one saved field: see
EW.Client and db.client.
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
The client this addon is running on, and the capability table gated on it.

Every class A and class B call in the compatibility inventory sits behind a
named capability here, resolved once per client rather than assumed to work
until it errors, which is the assumption World of Warcraft: Forever proved
backwards: the addon was blocked with an alert naming no function, on build
1.60.1, for using something "available only to the Blizzard UI."

WOW_PROJECT_ID cannot name Forever by itself, and the owner's own build
1.60.1 reading proved it worse than merely silent: that session's
WOW_PROJECT_ID was the mainline id, the same one Retail reports, not the
Classic id this addon first expected Forever to share. A project id check
run ahead of the version string, as 0.2.0 ran it, therefore reads a Forever
client as Retail outright and switches on every capability 0.2.0 shipped
off for it, which is the exact alert this addon exists to stop causing. The
version string is what actually, and only, separates Forever from
everything else: Classic Era's patches run 1.14 and 1.15, and Forever's run
1.60 and up, so the client key is read off the version string's major and
minor first, before WOW_PROJECT_ID is even asked, whatever project id the
client turns out to carry. A version string this will not parse, and a
project id this table then has no row for either, is treated as the most
restrictive client there is: a client the table does not recognize gets its
own unknown row, off in exactly the same shape as Forever's, not the most
permissive one, because a permissive guess is exactly the mistake the alert
punished.

EW.Client and EW.Caps are built here, at load, rather than waiting for
ADDON_LOADED. The tooltip hook in Objects.lua and the combat log
registration in Loot.lua run as those files load, in the same table of
contents pass, and both finish before ADDON_LOADED for this addon can fire,
so EW.Caps has to exist before either of them runs. WOW_PROJECT_ID and
GetBuildInfo are both globals the client sets before any addon file
executes, so neither one needs to wait for the event either.
]]
EW.CAPABILITY_NAMES = { "worldCursor", "unitGuid", "combatLog" }

-- Forever's own detectable patch line starts at 1.60. Adjust this once the
-- owner's /dump confirms the interface number and, if Blizzard ever ships an
-- earlier or later starting minor for it, the minor it actually launches on.
local FOREVER_MIN_MINOR = 60

local CAPABILITY_TABLE = {
  -- Retail: every path here is proven, live, in the 0.1.1 sample.
  retail      = { worldCursor = true,  unitGuid = true,  combatLog = true  },
  -- Classic Era and Hardcore: C_TooltipInfo does not exist on this client at
  -- all, so worldCursor was already effectively off; unitGuid and combatLog
  -- are the addon's long standing, unblocked behavior on this client.
  classic_era = { worldCursor = false, unitGuid = true,  combatLog = true  },
  hardcore    = { worldCursor = false, unitGuid = true,  combatLog = true  },
  -- Forever: nothing restricted is proven safe yet. Every capability starts
  -- off until an owner's paste turns one on.
  forever     = { worldCursor = false, unitGuid = false, combatLog = false },
  -- A client this table cannot place: the same row as Forever, not the same
  -- row as Classic Era, because the safe default is the restrictive one.
  unknown     = { worldCursor = false, unitGuid = false, combatLog = false },
}

--[[ A fresh capability table for a client key, defaulting to the unknown
     (most restrictive) row for a key the table does not carry. ]]
function EW.CapsFor(key)
  local row = CAPABILITY_TABLE[key] or CAPABILITY_TABLE.unknown
  local caps = {}
  for _, name in ipairs(EW.CAPABILITY_NAMES) do
    caps[name] = row[name] == true
  end
  return caps
end

local function ParseMajorMinor(version)
  if type(version) ~= "string" then return nil, nil end
  local major, minor = version:match("^(%d+)%.(%d+)")
  return tonumber(major), tonumber(minor)
end

--[[ Reads the client from WOW_PROJECT_ID, the version string GetBuildInfo
     returns first, and the fourth return of GetBuildInfo, the interface
     number, kept for reporting rather than for the key itself. ]]
function EW.ReadClient()
  local version, build, date, interface
  pcall(function() version, build, date, interface = GetBuildInfo() end)

  local project = rawget(_G, "WOW_PROJECT_ID")
  local mainline = rawget(_G, "WOW_PROJECT_MAINLINE")
  local major, minor = ParseMajorMinor(version)

  local key
  if major == 1 and minor ~= nil and minor >= FOREVER_MIN_MINOR then
    -- Checked before WOW_PROJECT_ID, whatever project id comes back: the
    -- owner's own Forever session carried the mainline id, and a project
    -- id check ahead of this one reads that session as Retail.
    key = "forever"
  elseif project ~= nil and mainline ~= nil and project == mainline then
    key = "retail"
  elseif major ~= nil and minor ~= nil then
    local hardcore = false
    pcall(function()
      if C_GameRules and C_GameRules.IsHardcoreActive then
        hardcore = C_GameRules.IsHardcoreActive() and true or false
      elseif type(rawget(_G, "IsHardcoreActive")) == "function" then
        hardcore = IsHardcoreActive() and true or false
      end
    end)
    key = hardcore and "hardcore" or "classic_era"
  else
    key = "unknown"
  end

  return { key = key, project = project, interface = interface, version = version, build = build }
end

EW.Client = EW.ReadClient()
EW.Caps = EW.CapsFor(EW.Client.key)

--[[ The function name an ADDON_ACTION_FORBIDDEN or ADDON_ACTION_BLOCKED
     event names, mapped to the capability that call belongs to. A frame
     method the client blames by its own name, such as RegisterEvent, is
     never one of these keys: the same method serves every event this addon
     registers, so it is not itself owned by one capability. See
     EVENT_CAPABILITY and EW.lastRegisterAttempt below for how a
     RegisterEvent refusal is placed instead, which the owner's own alert on
     build 1.60.1, naming "EverythingWoWFrame:RegisterEvent()", needed and
     0.2.0 did not have. ]]
local FUNCTION_CAPABILITY = {
  GetWorldCursor = "worldCursor",
  ["C_TooltipInfo.GetWorldCursor"] = "worldCursor",
  CombatLogGetCurrentEventInfo = "combatLog",
  UnitGUID = "unitGuid",
}

function EW.CapabilityForFunction(fn)
  if type(fn) ~= "string" then return nil end
  return FUNCTION_CAPABILITY[fn]
end

--[[
The event name a RegisterEvent call was attempting, mapped to the
capability the data that event feeds is gated behind. EW.RegisterEvent
below records the event it is mid call on in EW.lastRegisterAttempt before
it ever reaches the client, so a forbidden report naming the RegisterEvent
method itself, rather than one of FUNCTION_CAPABILITY's own named calls,
can still be placed at the one capability the refused event belongs to
instead of every capability at once, which is what 0.2.0's handler did with
exactly this report because RegisterEvent named a method, not a capability.

An event with no row here, such as LOOT_OPENED or ADDON_LOADED, feeds no
gated capability at all, so a refusal naming one of those still falls back
to every capability off, the same fallback a report this table cannot
place at all already gets.
]]
local EVENT_CAPABILITY = {
  NAME_PLATE_UNIT_ADDED = "unitGuid",
  UPDATE_MOUSEOVER_UNIT = "unitGuid",
  PLAYER_TARGET_CHANGED = "unitGuid",
  COMBAT_LOG_EVENT_UNFILTERED = "combatLog",
}

function EW.CapabilityForEvent(event)
  if type(event) ~= "string" then return nil end
  return EVENT_CAPABILITY[event]
end

--[[ Whether a reported function name is the RegisterEvent call itself,
     such as "EverythingWoWFrame:RegisterEvent()" or a bare
     "RegisterEvent", rather than one of the specific calls
     FUNCTION_CAPABILITY already places. ]]
local function NamesRegisterEvent(fn)
  return type(fn) == "string" and fn:find("RegisterEvent", 1, true) ~= nil
end
EW.NamesRegisterEvent = NamesRegisterEvent

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
  -- Gated behind caps.unitGuid: under the secret value system a GUID for a
  -- unit outside the player's group may not be pattern matched or compared,
  -- so where the capability is off this returns nothing rather than
  -- touching the value at all. Every caller already treats a subject this
  -- returns nothing for as a subject it could not place, so nothing else
  -- has to change for the recorders to fall back to what a window's own
  -- links and text can tell them.
  if not (EW.Caps and EW.Caps.unitGuid) then return nil, nil end
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
  -- An extra field beside the upload's version key, not a replacement for
  -- it: db.version has to stay a key the site's versions table already
  -- enables, and forever is not one of those yet, so this addon's own
  -- corrected client detection rides along under its own name instead.
  -- readCompanionFile in the site's read.ts reads specific keys off this
  -- table and ignores the rest, so an extra one here is carried, not
  -- refused.
  db.client = EW.Client and EW.Client.key or nil
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
  if type(db.forbidden) ~= "table" then db.forbidden = {} end
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

--[[
Every RegisterEvent call in this addon goes through here, one event at a
time, rather than through the frame directly, so that a forbidden report
naming the RegisterEvent method itself can still be attributed to the exact
event that was mid call when it fired: EW.lastRegisterAttempt names that
event for as long as the client is being asked and nothing longer, cleared
whether the call succeeded, failed, or was refused. OnForbiddenAction below
reads it, and so does EW.ProbeOneEvent, which calls frame:RegisterEvent
directly for its own reasons but sets this the same way first.
]]
function EW.RegisterEvent(event, handler)
  if not handlers[event] then
    handlers[event] = {}
    EW.lastRegisterAttempt = event
    local ok = pcall(function() frame:RegisterEvent(event) end)
    EW.lastRegisterAttempt = nil
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

--[[
ADDON_ACTION_FORBIDDEN and ADDON_ACTION_BLOCKED, named at this addon. The
client fires one of these instead of the alert continuing silently a second
time, and this is what turns a screenshot into evidence in the upload: the
reported function, the client this ran on, and when, written into the saved
file, with the matching capability turned off for the rest of this session
so the addon stops making the call the client just refused.

The owner's own alert on build 1.60.1 names the RegisterEvent method rather
than no function at all, and it is that method, not a report with truly no
function name, that this handler now tries to place through
EW.lastRegisterAttempt and EVENT_CAPABILITY before it falls back to turning
every restricted capability off. A report this handler still cannot place
by either path, including one that genuinely names no function, keeps the
0.2.0 fallback: every capability off for the session rather than none.
]]
local function DisableAllCapabilities()
  if not EW.Caps then return end
  for _, capability in ipairs(EW.CAPABILITY_NAMES) do
    EW.Caps[capability] = false
  end
end

local function OnForbiddenAction(kind, addonName, functionName)
  if type(addonName) ~= "string" or addonName ~= ADDON_NAME then return end

  local db = EW.Database()
  local fn = (type(functionName) == "string" and functionName ~= "") and functionName or nil
  -- Only meaningful while a RegisterEvent call this handler's own report
  -- names is actually mid call: NamesRegisterEvent(fn) is what tells a
  -- report of "EverythingWoWFrame:RegisterEvent()" apart from one naming
  -- GetWorldCursor or UnitGUID directly, which never touches this at all.
  local attemptedEvent = NamesRegisterEvent(fn) and EW.lastRegisterAttempt or nil
  local record = {
    event = kind,
    fn = fn,
    attemptedEvent = attemptedEvent,
    client = EW.Client and EW.Client.key or "unknown",
    build = EW.Client and EW.Client.version or nil,
    interface = EW.Client and EW.Client.interface or nil,
    t = Now(),
  }
  table.insert(db.forbidden, record)
  while #db.forbidden > 50 do table.remove(db.forbidden, 1) end
  db.lastForbidden = record

  local capability = EW.CapabilityForFunction(fn) or EW.CapabilityForEvent(attemptedEvent)
  if capability then
    if EW.Caps then EW.Caps[capability] = false end
  else
    DisableAllCapabilities()
  end
  -- Read by EW.ProbeOneEvent, which is the only other caller that sets
  -- EW.lastRegisterAttempt and needs to know, right after its own
  -- RegisterEvent call returns, whether this handler just fired for it.
  if attemptedEvent then EW.probeRefusedEvent = attemptedEvent end

  EW.Print(string.format(
    "%s reported for %s on build %s. %s.",
    kind,
    fn or "an unnamed function",
    tostring(record.build),
    capability and (capability .. " turned off for this session")
      or "every restricted capability turned off for this session"
  ))
end
EW.OnForbiddenAction = OnForbiddenAction

EW.RegisterEvent("ADDON_ACTION_FORBIDDEN", function(...) OnForbiddenAction("ADDON_ACTION_FORBIDDEN", ...) end)
EW.RegisterEvent("ADDON_ACTION_BLOCKED", function(...) OnForbiddenAction("ADDON_ACTION_BLOCKED", ...) end)

--[[
`/ewow probe`. Every event a recorder in this addon registers, tried one at
a time: an event this session already has running is reported allowed
without being touched again, since registering or unregistering it here
would test nothing and would take a working listener away for nothing, and
an event that is not already running is registered fresh, through the same
EW.lastRegisterAttempt path every other registration uses, then immediately
unregistered whether the client allowed it or refused it, so the probe
leaves nothing behind that was not already there. This is the systematic
version of what the owner's alert forced one event at a time: rather than
learning which event a client refuses only when gameplay happens to trip
it, every event the addon cares about is asked once, in a controlled order.
]]
EW.PROBE_EVENTS = {
  "NAME_PLATE_UNIT_ADDED",
  "UPDATE_MOUSEOVER_UNIT",
  "PLAYER_TARGET_CHANGED",
  "COMBAT_LOG_EVENT_UNFILTERED",
  "LOOT_OPENED",
  "GROUP_ROSTER_UPDATE",
  "PLAYER_ENTERING_WORLD",
  "PLAYER_LOGOUT",
  "QUEST_DETAIL",
  "QUEST_COMPLETE",
  "MERCHANT_SHOW",
  "AUCTION_ITEM_LIST_UPDATE",
}

--[[ Probes one event and returns whether the client allowed it. ]]
local function ProbeOneEvent(event)
  if frame.IsEventRegistered and frame:IsEventRegistered(event) then
    -- Already registered and running, which only happens because the
    -- client already allowed this event earlier in the session.
    return true
  end
  EW.probeRefusedEvent = nil
  EW.lastRegisterAttempt = event
  local ok = pcall(function() frame:RegisterEvent(event) end)
  EW.lastRegisterAttempt = nil
  local refused = (not ok) or (EW.probeRefusedEvent == event)
  pcall(function() frame:UnregisterEvent(event) end)
  return not refused
end
EW.ProbeOneEvent = ProbeOneEvent

--[[
Runs the probe across every event in EW.PROBE_EVENTS, one per tick of
C_Timer.After: waiting a tick between attempts gives a real forbidden
action, which the client raises as its own event rather than as a Lua
return value, room to arrive and be attributed before the next attempt
starts, using the client's own event loop rather than a fixed delay this
addon would have to guess at. onEvent is called with each event's result
{event, allowed} as it completes and onDone with the full list once every
event has been tried.
]]
function EW.RunProbe(onEvent, onDone)
  local index = 0
  local results = {}
  local function step()
    index = index + 1
    local event = EW.PROBE_EVENTS[index]
    if not event then
      if onDone then onDone(results) end
      return
    end
    local allowed = ProbeOneEvent(event)
    local result = { event = event, allowed = allowed }
    results[#results + 1] = result
    if onEvent then onEvent(result) end
    if C_Timer and C_Timer.After then
      C_Timer.After(0, step)
    else
      step()
    end
  end
  step()
end

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

--[[ The capability table as one line, in EW.CAPABILITY_NAMES order. ]]
local function CapsLine()
  if not EW.Caps then return nil end
  local parts = {}
  for _, name in ipairs(EW.CAPABILITY_NAMES) do
    parts[#parts + 1] = string.format("%s %s", name, EW.Caps[name] and "on" or "off")
  end
  return table.concat(parts, ", ")
end
EW.CapsLine = CapsLine

local function Status()
  local db = EW.Database()
  local counts = {}
  for _, observation in ipairs(db.observations) do
    counts[observation.kind] = (counts[observation.kind] or 0) + 1
  end
  -- "game" reads EW.Client.key, not db.version: db.version is the upload's
  -- own field and has to keep sending a key the site's versions table
  -- already enables, which is not yet true of forever, while this line is
  -- read by a person and should say what client this addon actually found.
  EW.Print(string.format("version %s, game %s, patch %s.",
    EW.ADDON_VERSION, tostring(EW.Client and EW.Client.key or db.version), tostring(db.patch)))
  EW.Print(string.format("client %s (interface %s, build %s).",
    EW.Client and EW.Client.key or "unknown",
    EW.Client and tostring(EW.Client.interface) or "?",
    EW.Client and tostring(EW.Client.version) or "?"))
  local caps = CapsLine()
  if caps then EW.Print("capabilities: " .. caps) end
  local lastForbidden = db.lastForbidden
  if lastForbidden then
    EW.Print(string.format("last forbidden action: %s for %s on build %s (client %s).",
      lastForbidden.event, lastForbidden.fn or "an unnamed function",
      tostring(lastForbidden.build), tostring(lastForbidden.client)))
  else
    EW.Print("no forbidden action reported yet.")
  end
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

--[[ Runs the probe and prints one line per event, then saves the result to
     the saved file so the upload carries it: the payload tolerates an
     unknown top level field, the same reason db.client rides beside
     db.version above, so nothing else has to change for it to travel. ]]
local function Probe()
  EW.Print(string.format("Probing %d events, one per tick. Watch for a forbidden action alert.",
    #EW.PROBE_EVENTS))
  EW.RunProbe(function(result)
    EW.Print(string.format("  %s: %s", result.event, result.allowed and "allowed" or "refused"))
  end, function(results)
    local db = EW.Database()
    db.probe = { t = Now(), results = results }
    local refused = 0
    for _, result in ipairs(results) do
      if not result.allowed then refused = refused + 1 end
    end
    EW.Print(string.format(
      "Probe complete: %d allowed, %d refused. Saved to the file for the next upload.",
      #results - refused, refused))
  end)
end

--[[ `/ewow cap <name> on|off`, flipping one capability for the session so
     the owner can test the tooltip hook or the GUID path on its own once
     the probe has said which events the client allows. This does not
     persist and does not touch what a forbidden report already turned
     off; it is a session only override for testing. ]]
local function Cap(rest)
  local name, state = string.match(rest, "^(%S+)%s+(%S+)$")
  state = state and string.lower(state)
  local canonical
  if name then
    local lowerName = string.lower(name)
    for _, capName in ipairs(EW.CAPABILITY_NAMES) do
      if string.lower(capName) == lowerName then canonical = capName end
    end
  end
  if not canonical or (state ~= "on" and state ~= "off") then
    EW.Print("Usage: /ewow cap <name> on|off. Names: " .. table.concat(EW.CAPABILITY_NAMES, ", "))
    return
  end
  if EW.Caps then EW.Caps[canonical] = (state == "on") end
  EW.Print(string.format("%s turned %s for this session.", canonical, state))
end

function EW.SlashCommand(message)
  local text = tostring(message or "")
  local command = string.lower(string.match(text, "^%s*(%S*)") or "")
  local rest = string.match(text, "^%s*%S*%s*(.-)%s*$") or ""
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
  elseif command == "probe" then
    Probe()
  elseif command == "cap" then
    Cap(rest)
  else
    EW.Print("Commands: /ewow status, /ewow clear, /ewow snapshot, /ewow path, /ewow probe, /ewow cap <name> on|off.")
  end
end

SLASH_EWOW1 = "/ewow"
SLASH_EWOW2 = "/everythingwow"
SlashCmdList["EWOW"] = EW.SlashCommand

_G.EverythingWoW = EW
