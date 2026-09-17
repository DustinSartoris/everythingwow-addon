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

local function RecordUnit(unit)
  if not unit or not UnitExists(unit) then return end
  -- Another player is never recorded, under any kind, for any reason.
  if UnitIsPlayer(unit) then return end

  local guid = UnitGUID(unit)
  local subject, id = EW.SubjectFromGuid(guid)
  if subject ~= "npc" or not id then return end

  local classification
  pcall(function() classification = UnitClassification(unit) end)
  local isRare = classification ~= nil and RARE_CLASSIFICATIONS[classification] == true

  local mapId, x, y = EW.PlayerPosition()
  if not mapId then return end

  local payload = {}
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
