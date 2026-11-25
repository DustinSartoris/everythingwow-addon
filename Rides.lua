--[[
The ride recorder.

How long a boat, a zeppelin or the tram takes is something only a ride
tells. The site's map guesses it for every line. From 0.4.1 the addon times
each ride you take and writes it down, as it does each flight, so the
guesses can be replaced by what the ride really took.

How a ride is told from walking. On a boat your character stands still, or
strolls about the deck, and yet moves over the ground fast. So twice a
second the addon compares two things: how far the character has moved in
the world since the last look, and how fast the character itself is moving
on its own feet. Moving over the ground a good deal faster than its own
speed, for a few looks running, is a ride. The ride ends when that stops
for a few seconds: the boat has come to rest at a dock.

One ride is one observation of the kind "transit". Its place, the map and
position the observation itself carries, is where the ride began. Its
payload holds: s, the seconds from setting off to coming to rest, to a
tenth; f, the faction of the character, alliance or horde; tm, tx and ty,
the map and position where it ended; and n, how many loading screens the
ride passed through, which is one for a crossing between continents.

A boat that calls at a dock on its way, as the one from Menethil Harbor by
Southshore does, is written as one ride for each leg.

What is not written: a flight, which the flight recorder times; anything
inside an instance; a ride shorter than half a minute or longer than a
quarter of an hour; and one that ended within a stone's throw of where it
began without a loading screen between, which is no crossing.

It runs on WoW Forever alone, where the planner's lines are. It reads the
character's position and speed and its faction, and nothing else. Where the
client will not give a value to an addon, that look is passed over.
]]

local ADDON_NAME, EW = ...

-- Yards a second faster than the character's own speed that count as
-- being carried.
EW.RIDE_EXCESS = 2.25
-- Where its own speed cannot be read: this fast over the ground while
-- neither walking nor falling.
EW.RIDE_FALLBACK = 8.5
-- Looks running that must show it before a ride is begun.
EW.RIDE_STREAK = 3
-- Seconds without it before the ride is taken to have ended.
EW.RIDE_REST_SECONDS = 4
EW.RIDE_MIN_SECONDS = 30
EW.RIDE_MAX_SECONDS = 900
-- A ride with no loading screen must end at least this many yards from
-- where it began.
EW.RIDE_MIN_YARDS = 150
EW.RIDE_LOOK_SECONDS = 0.5

-- The last look, the looks that showed it running, and the ride in hand.
local last, streak, first, ride = nil, 0, nil, nil

local function Faction()
  local faction
  pcall(function() faction = UnitFactionGroup("player") end)
  if faction == "Alliance" then return "alliance" end
  if faction == "Horde" then return "horde" end
  return nil
end

local function Forget()
  last, streak, first, ride = nil, 0, nil, nil
end
EW.ForgetRide = Forget

--[[ For the tests: the ride in hand, and how many looks have shown one
     beginning. ]]
function EW.RideState()
  return ride, streak
end

--[[ The ride has come to rest: write it down if it was one. ]]
local function Finish(look)
  local done = ride
  ride, streak, first = nil, 0, nil
  if not done then return false end
  local seconds = done.lastFast - done.depart
  if seconds < EW.RIDE_MIN_SECONDS or seconds > EW.RIDE_MAX_SECONDS then return false end
  if done.loads == 0 then
    local dx, dy = done.lastX - done.x, done.lastY - done.y
    if dx * dx + dy * dy < EW.RIDE_MIN_YARDS * EW.RIDE_MIN_YARDS then return false end
  end
  local faction = Faction()
  if not faction then return false end
  local endMap, endX, endY = look.map, look.mapX, look.mapY
  EW.Record("transit", "transit", nil, done.map, done.mapX, done.mapY, {
    s = EW.Round(seconds, 1),
    f = faction,
    tm = endMap,
    tx = endX,
    ty = endY,
    n = done.loads,
  })
  return true
end

--[[
One look at the character. look holds: t, the clock in seconds; x and y,
where the character is in the world, in yards; instance, the continent the
client counts that on; own, the character's own speed in yards a second, or
nil where it cannot be read; walking and falling, where own is nil; taxi and
indoors, true on a flight and inside an instance; and map, mapX and mapY,
the character's map and its place on it. Returns "ride" while a ride is in
hand, "written" when one was just written down, and nil otherwise.
]]
function EW.RideLook(look)
  if type(look) ~= "table" or type(look.t) ~= "number" then return nil end
  if look.taxi or look.indoors then
    Forget()
    return nil
  end
  if type(look.x) ~= "number" or type(look.y) ~= "number" then
    -- The client would not say where the character is. A ride in hand is
    -- kept for a while; anything just beginning is dropped.
    last, streak, first = nil, 0, nil
    if ride and look.t - ride.lastFast > 120 then ride = nil end
    return ride and "ride" or nil
  end

  -- A look tells the speed only against the look before it.
  local fast, told = false, false
  if last and last.instance == look.instance and look.t > last.t and look.t - last.t <= 2 then
    told = true
    local dx, dy = look.x - last.x, look.y - last.y
    local over = math.sqrt(dx * dx + dy * dy) / (look.t - last.t)
    if type(look.own) == "number" then
      fast = over >= math.max(EW.RIDE_EXCESS, look.own + EW.RIDE_EXCESS)
    else
      fast = over >= EW.RIDE_FALLBACK and not look.walking and not look.falling
    end
  end
  local before = last
  last = { t = look.t, x = look.x, y = look.y, instance = look.instance }

  if ride then
    if look.t - ride.depart > EW.RIDE_MAX_SECONDS + 60 then
      ride, streak, first = nil, 0, nil
      return nil
    end
    if fast then
      ride.lastFast, ride.lastX, ride.lastY, ride.restSince = look.t, look.x, look.y, nil
      return "ride"
    end
    -- Only a look that told the speed, and told it slow, counts as rest:
    -- one that could not tell, after a loading screen or an unanswered
    -- look, leaves the ride as it is.
    if told then
      ride.restSince = ride.restSince or look.t
      if look.t - ride.restSince >= EW.RIDE_REST_SECONDS - EW.RIDE_LOOK_SECONDS then
        return Finish(look) and "written" or nil
      end
    end
    return "ride"
  end

  if fast then
    streak = streak + 1
    if streak == 1 then
      -- The ride set off between the look before and this one.
      first = {
        t = before.t, x = before.x, y = before.y,
        map = look.map, mapX = look.mapX, mapY = look.mapY,
      }
    end
    if streak >= EW.RIDE_STREAK then
      ride = {
        depart = first.t, x = first.x, y = first.y,
        map = first.map, mapX = first.mapX, mapY = first.mapY,
        lastFast = look.t, lastX = look.x, lastY = look.y,
        loads = 0,
      }
      streak, first = 0, nil
      return "ride"
    end
  else
    streak, first = 0, nil
  end
  return nil
end

--[[ A loading screen. A ride in hand goes on beyond it, on the far side of
     the sea; the look before it is no use for the speed after it. ]]
local function OnLeavingWorld()
  last, streak, first = nil, 0, nil
end
local function OnEnteringWorld()
  last, streak, first = nil, 0, nil
  if ride then
    ride.loads = ride.loads + 1
    -- The clock ran on through the loading screen, and so did the boat.
    ride.lastFast = EW.RideClock()
  end
end

--[[ True where the client holds a value back from addons. ]]
local function Hidden(value)
  local hidden = false
  pcall(function()
    if type(issecretvalue) == "function" and issecretvalue(value) then hidden = true end
  end)
  return hidden
end

local function Readable(value)
  if Hidden(value) or type(value) ~= "number" or value ~= value then return nil end
  return value
end

function EW.RideClock()
  local now
  pcall(function() if type(GetTime) == "function" then now = GetTime() end end)
  if type(now) == "number" then return now end
  return EW.Now()
end

local function Flag(call, ...)
  local value = false
  local arguments = { ... }
  pcall(function()
    local answer = call((unpack or table.unpack)(arguments))
    if not Hidden(answer) and answer then value = true end
  end)
  return value
end

--[[ Reads the client and takes one look. ]]
function EW.RideTick()
  local look = { t = EW.RideClock() }
  look.taxi = type(UnitOnTaxi) == "function" and Flag(UnitOnTaxi, "player") or false
  look.indoors = type(IsInInstance) == "function" and Flag(IsInInstance) or false
  pcall(function()
    -- The client gives north first, then west, then up, then the continent.
    local north, west, _, instance = UnitPosition("player")
    look.y, look.x, look.instance = Readable(north), Readable(west), Readable(instance)
  end)
  pcall(function() look.own = Readable(GetUnitSpeed("player")) end)
  if look.own == nil then
    look.walking = type(IsPlayerMoving) == "function" and Flag(IsPlayerMoving) or false
    look.falling = type(IsFalling) == "function" and Flag(IsFalling) or false
  end
  look.map, look.mapX, look.mapY = EW.PlayerPosition()
  return EW.RideLook(look)
end

-- The recorder needs the character's place in the world and a clock that
-- ticks; without them it registers nothing and writes nothing.
local started = false
pcall(function()
  if EW.VersionKey() ~= "forever" then return end
  if type(UnitPosition) ~= "function" or type(GetUnitSpeed) ~= "function" then return end
  if not (C_Timer and C_Timer.NewTicker) then return end
  C_Timer.NewTicker(EW.RIDE_LOOK_SECONDS, function() pcall(EW.RideTick) end)
  EW.RegisterEvent("PLAYER_LEAVING_WORLD", OnLeavingWorld)
  EW.RegisterEvent("PLAYER_ENTERING_WORLD", OnEnteringWorld)
  started = true
end)
EW.RIDES_STARTED = started
EW.RideLoadingScreen = function(entering)
  if entering then OnEnteringWorld() else OnLeavingWorld() end
end
