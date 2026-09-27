--[[
The NPC and rare recorder.

A nameplate appearing and a mouseover are the two cheap, documented moments
where a creature unit token exists, and both give a GUID, which is the only
place a creature id can be read. UnitClassification separates a rare from an
ordinary creature, and the two are recorded under their own kinds so the
site's rare layer is a layer and not a filter over everything.

What this recorder cannot capture: the vendor and quest giver flags Section
9.2 names. Nothing on a nameplate says whether a creature sells or gives a
quest, so those flags are left to the vendor and quest recorders, which know
it because the player opened the window.
]]

local ADDON_NAME, EW = ...

local RARE_CLASSIFICATIONS = { rare = true, rareelite = true, worldboss = true }

--[[
Whether a unit belongs to a player rather than to the world. A player, a pet,
a guardian, and a player's vehicle all answer yes, and none of them is ever
recorded: UnitName on any of them can be a player's name, and a vehicle GUID
carries the vehicle's creature id, so the name and the id would not even
describe the same thing. Passing one of these over is expected and is counted
under ignored rather than under skipped.
]]
local function PlayerOwned(unit)
  if UnitIsPlayer(unit) then return "player" end
  local controlled = false
  pcall(function()
    if type(rawget(_G, "UnitPlayerControlled")) == "function" then
      controlled = UnitPlayerControlled(unit) and true or false
    end
  end)
  if not controlled then return nil end
  local isPet = false
  pcall(function()
    if type(rawget(_G, "UnitIsUnit")) == "function" then
      isPet = UnitIsUnit(unit, "pet") and true or false
    end
  end)
  if isPet then return "pet" end
  return "vehicle"
end
EW.PlayerOwned = PlayerOwned

local function RecordUnit(unit)
  if not unit or not UnitExists(unit) then return end
  -- Another player, a pet, or a vehicle is never recorded, under any kind,
  -- for any reason. The name on one of them can be a person.
  local owned = PlayerOwned(unit)
  if owned then
    EW.CountIgnored(owned)
    return
  end

  local guid = UnitGUID(unit)
  local subject, id = EW.SubjectFromGuid(guid)
  if subject ~= "npc" or not id then
    -- Not a creature the contract has an id for, which is not a loss.
    EW.CountIgnored("no_id")
    return
  end

  local classification
  pcall(function() classification = UnitClassification(unit) end)
  local isRare = classification ~= nil and RARE_CLASSIFICATIONS[classification] == true

  -- A creature with an id that the client will not place is the one real
  -- loss this recorder can suffer, so it is the one thing counted as skipped.
  local mapId, x, y = EW.PlayerPosition()
  if not mapId then
    EW.CountSkipped("no_map")
    return
  end
  if x == nil or y == nil then
    EW.CountSkipped("no_position")
    return
  end

  local payload = {}
  -- UnitName on a creature unit is the creature's name. The player owned
  -- check above is what keeps a person's name out of this field.
  local name = UnitName(unit)
  if type(name) == "string" and name ~= "" then payload.name = name end
  local level = UnitLevel(unit)
  if type(level) == "number" and level > 0 then payload.level = level end
  local reaction = UnitReaction("player", unit)
  if type(reaction) == "number" then payload.reaction = reaction end
  if classification then payload.classification = classification end

  EW.Record(isRare and "rare" or "npc", isRare and "rare" or "npc", id, mapId, x, y, payload)
end

EW.RecordUnit = RecordUnit

EW.RegisterEvent("NAME_PLATE_UNIT_ADDED", function(unit) RecordUnit(unit) end)
EW.RegisterEvent("UPDATE_MOUSEOVER_UNIT", function() RecordUnit("mouseover") end)
EW.RegisterEvent("PLAYER_TARGET_CHANGED", function() RecordUnit("target") end)
