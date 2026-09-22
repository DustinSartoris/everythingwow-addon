--[[
The game object and gathering node recorder.

This is the recorder that cannot always do its job, and it says so rather
than guessing. A world object under the cursor has no documented API that
returns its game object id: GameTooltip:GetOwner() returns the frame the
tooltip is anchored to and not the thing in the world, so it is not a source
of an id. Two paths do yield a real id, and this file uses only those two:

1. C_TooltipInfo.GetWorldCursor, which exists on Retail from the tooltip
   rework onward, returns tooltip data whose id field is the object's id for
   the object under the cursor. Where the function or the id is missing, the
   sighting is passed over and counted under ignored in the saved file, which
   /ewow status prints by reason. Only an object that has an id the client
   will not place is counted as skipped, because only that is a loss.
2. A loot source GUID of type GameObject, which carries the object id in the
   same field a creature GUID carries the creature id. This is exact, and it
   is where most chest, herb, and vein sightings come from in practice,
   because a node is opened rather than hovered.

Classic Era has no C_TooltipInfo, so on that client path 2 is the only path
and an object the player never loots is not recorded at all. That is the
honest limit of version 0.1.0.

A node is an object the player gathers. The one non-guessing signal for it is
the tooltip line type the client itself reports for a profession requirement,
read by name from Enum.TooltipDataLineType so that a client without that
member simply records every object as an object.
]]

local ADDON_NAME, EW = ...

local function NodeLineType()
  local value
  pcall(function()
    if Enum and Enum.TooltipDataLineType then
      value = Enum.TooltipDataLineType.ProfessionRequirement
    end
  end)
  return value
end

--[[ Records one object from a GUID, which is the exact path. ]]
function EW.RecordObjectFromGuid(guid, isNode)
  local subject, id = EW.SubjectFromGuid(guid)
  if subject ~= "object" or not id then return false end
  local mapId, x, y = EW.PlayerPosition()
  if not mapId then
    EW.CountSkipped("no_map")
    return false
  end
  if x == nil or y == nil then
    EW.CountSkipped("no_position")
    return false
  end
  local kind = "object"
  local subjectType = isNode and "node" or "object"
  return EW.Record(kind, subjectType, id, mapId, x, y, nil)
end

--[[ Records the object under the cursor, where the client will name it.
     Gated behind caps.worldCursor: this is the leading cause of the Forever
     block, and where the capability is off, C_TooltipInfo.GetWorldCursor is
     never called at all rather than called and caught. ]]
local function RecordCursorObject()
  if not (EW.Caps and EW.Caps.worldCursor) then
    EW.CountIgnored("no_world_cursor")
    return false
  end

  local data
  local ok = pcall(function()
    if C_TooltipInfo and C_TooltipInfo.GetWorldCursor then
      data = C_TooltipInfo.GetWorldCursor()
    end
  end)
  if not ok or type(data) ~= "table" then
    -- Either the client has no world cursor function, or the tooltip is over
    -- something that is not in the world at all: a bag item, a unit frame, a
    -- button. This is the common case by far and it is not a loss, so it is
    -- counted under ignored. Version 0.1.0 counted it as skipped, which is
    -- why a few minutes in a city reported hundreds of them.
    EW.CountIgnored("no_world_cursor")
    return false
  end

  local id = tonumber(data.id)
  if not id or id <= 0 then
    -- No id can be read, so nothing is written. A guessed id is worse than a
    -- missing sighting, because the site would publish it as a pin.
    EW.CountIgnored("no_object_id")
    return false
  end

  local isNode = false
  local nodeLineType = NodeLineType()
  if nodeLineType and type(data.lines) == "table" then
    for _, line in ipairs(data.lines) do
      if type(line) == "table" and line.type == nodeLineType then isNode = true end
    end
  end

  -- An object with an id the client will not place is a real loss.
  local mapId, x, y = EW.PlayerPosition()
  if not mapId then
    EW.CountSkipped("no_map")
    return false
  end
  if x == nil or y == nil then
    EW.CountSkipped("no_position")
    return false
  end

  local payload = nil
  if type(data.lines) == "table" and type(data.lines[1]) == "table" then
    local name = data.lines[1].leftText
    if type(name) == "string" and name ~= "" then payload = { name = name } end
  end

  return EW.Record("object", isNode and "node" or "object", id, mapId, x, y, payload)
end

EW.RecordCursorObject = RecordCursorObject

-- The tooltip showing over the world is the moment the cursor is on an
-- object. The hook is a script hook on the shared tooltip, which adds no
-- taint and replaces nothing, but it is also the leading cause the
-- compatibility note names: insecure code running inside a Blizzard frame's
-- handler, at load, on every tooltip. Where caps.worldCursor is off, the
-- hook is never installed in the first place, rather than installed and
-- left to call a capability check on every tooltip show.
if EW.Caps and EW.Caps.worldCursor and GameTooltip and GameTooltip.HookScript then
  pcall(function()
    GameTooltip:HookScript("OnShow", function()
      if EW.Caps and EW.Caps.worldCursor and C_TooltipInfo and C_TooltipInfo.GetWorldCursor then
        pcall(RecordCursorObject)
      end
    end)
  end)
end
