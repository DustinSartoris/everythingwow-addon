--[[
The flight recorder.

How long a flight takes is something only a flight tells. The site's map
knows the time of 195 Classic flights, measured by players long ago, and for
every flight master new in WoW Forever it can only guess from the distance.
From 0.3.1 the addon times each flight you take and writes it down, so the
guesses can be replaced by what the flight really took.

One flight is one observation of the kind "flight". Its place, the map and
position the observation itself carries, is where you stood when you opened
the flight master's map, which is the flight master's own spot. Its payload
holds: from and to, the two flight points by the names the game's flight map
gives them; s, the seconds from takeoff to landing, to a tenth; f, the
faction whose flight network it is, alliance or horde; and tm, tx and ty,
the map and position where you landed.

How it is timed. Picking a destination on the flight map names the two
ends. Losing control of the character within a few seconds of that is the
takeoff, and getting it back while no longer on a taxi is the landing. A
flight that was not seen from end to end is not written: one you ended
early with the request to land, one a loading screen cut, one the client
never confirmed as a taxi, and anything shorter than five seconds or longer
than half an hour.

It reads nothing of the player but the faction, asks the client nothing the
flight map does not already ask, and writes nothing where the hook or the
events are missing.
]]

local ADDON_NAME, EW = ...

EW.FLIGHT_MIN_SECONDS = 5
EW.FLIGHT_MAX_SECONDS = 1800
EW.FLIGHT_NAME_BYTES = 80
-- How long a picked destination waits for the takeoff.
EW.FLIGHT_PICK_SECONDS = 15

-- Where the open flight map stands, the destination just picked, and the
-- flight in the air.
local origin, pending, flying = nil, nil, nil

local function Clock()
  local now
  pcall(function() if type(GetTime) == "function" then now = GetTime() end end)
  if type(now) == "number" then return now end
  return EW.Now()
end

local function OnTaxi()
  local on = false
  pcall(function() on = UnitOnTaxi("player") and true or false end)
  return on
end

--[[ A flight point's name as the flight map gives it, or nil where it is
     not fit to store. ]]
local function CleanName(name)
  if type(name) ~= "string" or name == "" then return nil end
  if #name > EW.FLIGHT_NAME_BYTES or name:find("|", 1, true) or name:find("%c") then return nil end
  return name
end

local function NodeName(slot)
  local name
  pcall(function() name = TaxiNodeName(slot) end)
  return CleanName(name)
end

--[[ The flight point the open flight map belongs to. ]]
local function CurrentNode()
  local found
  pcall(function()
    for slot = 1, NumTaxiNodes() do
      if TaxiNodeGetType(slot) == "CURRENT" then
        found = NodeName(slot)
        return
      end
    end
  end)
  return found
end

local function Faction()
  local faction
  pcall(function() faction = UnitFactionGroup("player") end)
  if faction == "Alliance" then return "alliance" end
  if faction == "Horde" then return "horde" end
  return nil
end

--[[ The flight map opened: the character stands at the flight master. ]]
local function OnTaxiMapOpened()
  local map, x, y = EW.PlayerPosition()
  origin = { name = CurrentNode(), map = map, x = x, y = y }
end

--[[ A destination was picked. The hook runs after the game's own call, so
     the flight map is still the one the character stands at. ]]
local function OnTakeTaxiNode(slot)
  pending = nil
  local to = NodeName(slot)
  local from = (origin and origin.name) or CurrentNode()
  if not to or not from or to == from then return end
  local map, x, y
  if origin and origin.map then
    map, x, y = origin.map, origin.x, origin.y
  else
    map, x, y = EW.PlayerPosition()
  end
  pending = { from = from, to = to, map = map, x = x, y = y, at = Clock() }
end

local function OnControlLost()
  local picked = pending
  pending = nil
  if not picked or flying then return end
  if Clock() - picked.at > EW.FLIGHT_PICK_SECONDS then return end
  picked.start = Clock()
  picked.seen = OnTaxi()
  flying = picked
  -- The client may say the character is on a taxi only a moment later.
  pcall(function()
    if C_Timer and C_Timer.After then
      C_Timer.After(2, function()
        if flying == picked and OnTaxi() then picked.seen = true end
      end)
    end
  end)
end

local function OnControlGained()
  local flight = flying
  if not flight then return end
  -- Control comes back for a moment at a stop on the way; the flight goes on.
  if OnTaxi() then
    flight.seen = true
    return
  end
  flying = nil
  if flight.broken or not flight.seen then return end
  local seconds = Clock() - flight.start
  if seconds < EW.FLIGHT_MIN_SECONDS or seconds > EW.FLIGHT_MAX_SECONDS then return end
  local faction = Faction()
  if not faction then return end
  local landMap, landX, landY = EW.PlayerPosition()
  EW.Record("flight", "flight", nil, flight.map, flight.x, flight.y, {
    from = flight.from,
    to = flight.to,
    s = EW.Round(seconds, 1),
    f = faction,
    tm = landMap,
    tx = landX,
    ty = landY,
  })
end

--[[ A loading screen or a logout in the air: the landing was not seen. ]]
local function OnWorldChange()
  pending = nil
  if flying then flying.broken = true end
end

--[[ For the tests: the flight in the air, and the destination picked. ]]
function EW.FlightState()
  return flying, pending
end

function EW.ForgetFlight()
  origin, pending, flying = nil, nil, nil
end

-- Without the hook there is no way to know the destination, so nothing is
-- registered and nothing is ever written.
local hooked = false
pcall(function()
  if type(hooksecurefunc) == "function" and type(TakeTaxiNode) == "function" then
    hooksecurefunc("TakeTaxiNode", function(slot) pcall(OnTakeTaxiNode, slot) end)
    hooked = true
  end
end)
pcall(function()
  if type(hooksecurefunc) == "function" and type(TaxiRequestEarlyLanding) == "function" then
    hooksecurefunc("TaxiRequestEarlyLanding", function()
      if flying then flying.broken = true end
    end)
  end
end)

if hooked then
  EW.RegisterEvent("TAXIMAP_OPENED", OnTaxiMapOpened)
  EW.RegisterEvent("PLAYER_CONTROL_LOST", OnControlLost)
  EW.RegisterEvent("PLAYER_CONTROL_GAINED", OnControlGained)
  EW.RegisterEvent("PLAYER_LEAVING_WORLD", OnWorldChange)
  EW.RegisterEvent("PLAYER_ENTERING_WORLD", OnWorldChange)
end
EW.FLIGHTS_HOOKED = hooked
