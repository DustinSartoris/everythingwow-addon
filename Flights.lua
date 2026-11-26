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
takeoff, once the client says the character is on a taxi, which it does a
moment later. From then on the addon asks four times a second whether the
character is still on the taxi, and the first no is the landing. Until
0.4.3 it waited for the client to say that control had come back and
asked once, there and then; the real client answers that question a moment
late, so no flight was ever seen to land, and none was written. A flight
that was not seen from end to end is not written: one you ended early with
the request to land, one a loading screen cut, one the client never
confirmed as a taxi, and anything shorter than five seconds or longer than
half an hour.

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
-- How often the client is asked whether the character is on the taxi, and
-- how many times it is asked before a takeoff is given up on.
EW.FLIGHT_POLL_SECONDS = 0.25
EW.FLIGHT_CONFIRM_TRIES = 20

-- Where the open flight map stands, the destination just picked, the
-- takeoff waiting to be confirmed, and the flight in the air.
local origin, pending, candidate, flying = nil, nil, nil, nil

-- What the recorder has seen this session, for /ewow status: it says how
-- far a flight got when none was written.
local counts = { opened = 0, picked = 0, lost = 0, tookOff = 0, landed = 0, written = 0 }
local lastReason = nil

local function Note(reason)
  lastReason = reason
end

local function Clock()
  local now
  pcall(function() if type(GetTime) == "function" then now = GetTime() end end)
  if type(now) == "number" then return now end
  return EW.Now()
end

--[[ True where the client holds a value back from addons. ]]
local function Hidden(value)
  local hidden = false
  pcall(function()
    if type(issecretvalue) == "function" and issecretvalue(value) then hidden = true end
  end)
  return hidden
end

--[[ Whether the character is on a taxi: true, false, or nil where the
     client will not say. ]]
local function OnTaxi()
  local on
  local ok = pcall(function()
    local value = UnitOnTaxi("player")
    if not Hidden(value) then on = value and true or false end
  end)
  if not ok then return nil end
  return on
end

--[[ Asks the client to call back in a moment. False where it cannot. ]]
local function After(seconds, call)
  local queued = false
  pcall(function()
    if C_Timer and C_Timer.After then
      C_Timer.After(seconds, call)
      queued = true
    end
  end)
  return queued
end

--[[ A flight point's name as the flight map gives it, or nil where it is
     not fit to store. ]]
local function CleanName(name)
  local clean
  pcall(function()
    if Hidden(name) or type(name) ~= "string" or name == "" then return end
    if #name > EW.FLIGHT_NAME_BYTES or name:find("|", 1, true) or name:find("%c") then return end
    clean = name
  end)
  return clean
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
  counts.opened = counts.opened + 1
  local map, x, y = EW.PlayerPosition()
  origin = { name = CurrentNode(), map = map, x = x, y = y }
end

--[[ A destination was picked. The hook runs after the game's own call, so
     the flight map is still the one the character stands at. ]]
local function OnTakeTaxiNode(slot)
  pending = nil
  local to = NodeName(slot)
  local from = (origin and origin.name) or CurrentNode()
  if not to or not from or to == from then
    Note("the flight map did not name both ends")
    return
  end
  counts.picked = counts.picked + 1
  local map, x, y
  if origin and origin.map then
    map, x, y = origin.map, origin.x, origin.y
  else
    map, x, y = EW.PlayerPosition()
  end
  pending = { from = from, to = to, map = map, x = x, y = y, at = Clock() }
end

--[[ The flight is over: write it down if it was seen whole. ]]
local function Land(flight, now)
  if flying == flight then flying = nil end
  counts.landed = counts.landed + 1
  -- The client says control is back at the landing itself, a moment before
  -- it stops saying "on a taxi"; that moment is the better time.
  local landedAt = now
  if flight.gained and now - flight.gained <= 2 then landedAt = flight.gained end
  if flight.broken then
    Note("ended early or cut by a loading screen")
    return
  end
  local seconds = landedAt - flight.start
  if seconds < EW.FLIGHT_MIN_SECONDS or seconds > EW.FLIGHT_MAX_SECONDS then
    Note("shorter than five seconds or longer than half an hour")
    return
  end
  local faction = Faction()
  if not faction then
    Note("the character has no faction")
    return
  end
  local landMap, landX, landY = EW.PlayerPosition()
  local written = EW.Record("flight", "flight", nil, flight.map, flight.x, flight.y, {
    from = flight.from,
    to = flight.to,
    s = EW.Round(seconds, 1),
    f = faction,
    tm = landMap,
    tx = landX,
    ty = landY,
  })
  if written == false then
    Note("the file would not take it")
  else
    counts.written = counts.written + 1
    lastReason = nil
  end
end

--[[ While a flight is in the air: is the character still on the taxi? ]]
local function Watch()
  local flight = flying
  if not flight then return end
  local now = Clock()
  if now - flight.start > EW.FLIGHT_MAX_SECONDS + 60 then
    flying = nil
    Note("never seen to land")
    return
  end
  if OnTaxi() == false then
    Land(flight, now)
    return
  end
  if not After(EW.FLIGHT_POLL_SECONDS, Watch) then flight.unwatched = true end
end

--[[ After the takeoff: has the client put the character on the taxi yet? ]]
local function Confirm()
  local picked = candidate
  if not picked then return end
  picked.tries = (picked.tries or 0) + 1
  if OnTaxi() == true then
    candidate = nil
    flying = picked
    counts.tookOff = counts.tookOff + 1
    if not After(EW.FLIGHT_POLL_SECONDS, Watch) then picked.unwatched = true end
    return
  end
  if picked.tries >= EW.FLIGHT_CONFIRM_TRIES or not After(EW.FLIGHT_POLL_SECONDS, Confirm) then
    candidate = nil
    Note("the client never said the character was on a taxi")
  end
end

local function OnControlLost()
  counts.lost = counts.lost + 1
  local picked = pending
  pending = nil
  if not picked or flying or candidate then return end
  if Clock() - picked.at > EW.FLIGHT_PICK_SECONDS then
    Note("no takeoff followed the pick")
    return
  end
  picked.start = Clock()
  candidate = picked
  Confirm()
end

local function OnControlGained()
  local flight = flying
  if not flight then return end
  flight.gained = Clock()
  -- With no timer to ask again, this is the one chance to see the landing.
  if flight.unwatched and OnTaxi() == false then Land(flight, flight.gained) end
end

--[[ A loading screen or a logout in the air: the landing was not seen. ]]
local function OnWorldChange()
  pending, candidate = nil, nil
  if flying then flying.broken = true end
end

--[[ For the tests: the flight in the air, and the destination picked. ]]
function EW.FlightState()
  return flying, pending, candidate
end

function EW.ForgetFlight()
  origin, pending, candidate, flying = nil, nil, nil, nil
end

--[[ One line for /ewow status: how far flights have got this session. ]]
function EW.FlightReport()
  if not EW.FLIGHTS_HOOKED then return "flight recorder: off, this client gives no way to learn the destination" end
  local line = string.format(
    "flight recorder: flight maps opened %d, destinations picked %d, takeoffs %d, landings %d, written %d",
    counts.opened, counts.picked, counts.tookOff, counts.landed, counts.written)
  if lastReason then line = line .. " (last not written: " .. lastReason .. ")" end
  return line
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
