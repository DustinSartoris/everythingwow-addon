--[[
The loot recorder, which is also the kill counter.

The site computes a drop rate as drops over kills, and it counts one loot
observation as one kill or one open of a source, so this recorder has to
write an observation for a kill that dropped nothing as well as for one that
dropped something. It does that by remembering the creatures the player or
the player's group killed and writing an empty loot observation for any kill
that is not looted within the grace period.

Kills are taken from COMBAT_LOG_EVENT_UNFILTERED. A creature counts as ours
when the player, the player's pet, or a group member damaged or healed
through it, or when it was the player's target as it died. The group members'
GUIDs are held in memory for that check alone and are never written to the
saved file, because another player is never recorded.

Loot slots are grouped by their source GUID, so looting two corpses at once
writes two observations rather than one mixed one. Gold is written as a gold
entry rather than an item, because gold is not an item and the aggregation
skips it.
]]

local ADDON_NAME, EW = ...

EW.KILL_GRACE_SECONDS = 60
EW.LOOT_ITEM_CAP = 60

local pendingKills = {}
local engaged = {}
local groupGuids = {}

local function RefreshGroup()
  groupGuids = {}
  pcall(function()
    local raid = IsInRaid and IsInRaid() or false
    local size = GetNumGroupMembers and GetNumGroupMembers() or 0
    for index = 1, size do
      local unit = raid and ("raid" .. index) or ("party" .. index)
      local guid = UnitGUID(unit)
      if guid then groupGuids[guid] = true end
    end
  end)
end

local function IsOurs(guid)
  if not guid then return false end
  local player = UnitGUID("player")
  if guid == player then return true end
  local pet = UnitGUID("pet")
  if pet and guid == pet then return true end
  return groupGuids[guid] == true
end

--[[ Writes an observation for every kill that was never looted. ]]
local function FlushKills(force)
  local now = EW.Now()
  for guid, record in pairs(pendingKills) do
    if force or (now - record.at) >= EW.KILL_GRACE_SECONDS then
      pendingKills[guid] = nil
      EW.Record("loot", record.subject, record.id, record.map, record.x, record.y, {
        items = {},
        source_type = record.subject,
        source_id = record.id,
        kills = 1,
      })
    end
  end
end
EW.FlushKills = FlushKills

local function OnCombatLog()
  local ok, _, subevent, _, sourceGuid, _, _, _, destGuid = pcall(CombatLogGetCurrentEventInfo)
  if not ok or type(subevent) ~= "string" then return end

  if subevent == "UNIT_DIED" then
    local subject, id = EW.SubjectFromGuid(destGuid)
    if subject ~= "npc" or not id then return end
    local isTarget = destGuid == UnitGUID("target")
    if not isTarget and not engaged[destGuid] then return end
    engaged[destGuid] = nil
    local mapId, x, y = EW.PlayerPosition()
    pendingKills[destGuid] = { subject = subject, id = id, map = mapId, x = x, y = y, at = EW.Now() }
    FlushKills(false)
    return
  end

  if IsOurs(sourceGuid) then
    local subject = EW.SubjectFromGuid(destGuid)
    if subject == "npc" then engaged[destGuid] = EW.Now() end
  end
end
EW.OnCombatLog = OnCombatLog

--[[ Turns a localized money string into copper, using the client's own
     amount templates so that it reads in every locale. ]]
local function ToPattern(template)
  if type(template) ~= "string" then return nil end
  local sentinel = "\1"
  local text = template:gsub("%%d", sentinel)
  text = text:gsub("(%W)", function(character)
    if character == sentinel then return character end
    return "%" .. character
  end)
  text = text:gsub(sentinel, "(%%d+)")
  return text
end

local function CopperFromText(text)
  if type(text) ~= "string" then return nil end
  local total = 0
  local found = false
  local parts = {
    { rawget(_G, "GOLD_AMOUNT"), 10000 },
    { rawget(_G, "SILVER_AMOUNT"), 100 },
    { rawget(_G, "COPPER_AMOUNT"), 1 },
  }
  for _, part in ipairs(parts) do
    local pattern = ToPattern(part[1])
    if pattern then
      local amount = tonumber(text:match(pattern))
      if amount then
        total = total + amount * part[2]
        found = true
      end
    end
  end
  if not found then return nil end
  return total
end
EW.CopperFromText = CopperFromText

local function OnLootOpened()
  local slots = 0
  pcall(function() slots = GetNumLootItems() or 0 end)
  if slots < 1 then return end

  local mapId, x, y = EW.PlayerPosition()
  local order = {}
  local bySource = {}

  for slot = 1, slots do
    local guid
    pcall(function() guid = (GetLootSourceInfo(slot)) end)
    guid = guid or "loot-window"
    if not bySource[guid] then
      bySource[guid] = {}
      order[#order + 1] = guid
    end
    local items = bySource[guid]
    if #items < EW.LOOT_ITEM_CAP then
      local link
      pcall(function() link = GetLootSlotLink(slot) end)
      local itemId = EW.IdFromLink(link)
      if itemId then
        local quantity
        pcall(function()
          local _, _, slotQuantity = GetLootSlotInfo(slot)
          quantity = slotQuantity
        end)
        local entry = { id = itemId }
        if type(quantity) == "number" and quantity > 1 then entry.q = quantity end
        items[#items + 1] = entry
      else
        local text
        pcall(function()
          local _, slotText = GetLootSlotInfo(slot)
          text = slotText
        end)
        local copper = CopperFromText(text)
        if copper then items[#items + 1] = { gold = copper } end
      end
    end
  end

  for _, guid in ipairs(order) do
    local subject, id = EW.SubjectFromGuid(guid)
    if subject == "object" and id then
      -- An opened object is also a sighting with an exact id, which is the
      -- one place a node's id can be read on every client.
      EW.RecordObjectFromGuid(guid, true)
    end
    if (subject == "npc" or subject == "object") and id then
      pendingKills[guid] = nil
      EW.Record("loot", subject, id, mapId, x, y, {
        items = bySource[guid],
        source_type = subject,
        source_id = id,
        kills = 1,
      })
    end
  end

  FlushKills(false)
end
EW.OnLootOpened = OnLootOpened

-- Gated behind caps.combatLog: this is the second ranked cause, thousands of
-- events an hour, and where the capability is off the listener is never
-- registered at all rather than registered and made to check on every
-- event. Loot windows, quests, and vendors keep working either way, because
-- none of them depends on the combat log.
if EW.Caps and EW.Caps.combatLog then
  EW.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLog)
end
EW.RegisterEvent("LOOT_OPENED", OnLootOpened)
EW.RegisterEvent("GROUP_ROSTER_UPDATE", RefreshGroup)
EW.RegisterEvent("PLAYER_ENTERING_WORLD", RefreshGroup)
EW.RegisterEvent("PLAYER_LOGOUT", function() FlushKills(true) end)

pcall(function()
  if C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(EW.KILL_GRACE_SECONDS, function() FlushKills(false) end)
  end
end)
