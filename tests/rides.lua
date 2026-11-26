--[[
The ride recorder's tests, run from tests/run.lua.

A ride is told by looks at the character, two a second. Here the looks are
made up: a character that stands on a deck while the deck crosses the sea,
one that walks, one that rides in a circle, and each case that must not be
written. Then the client itself is stood in for, and looked at the way the
ticker looks at it.
]]

return function(t)
  local check, equal, stub = t.check, t.equal, t.stub

  local EW = t.LoadFreshAddon(2, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  equal("with no ticker to give, the recorder registers nothing", EW.RIDES_STARTED, false)
  equal("and its status line says so", EW.RideReport(), "ride recorder: off on this client")

  local function rides()
    local found = {}
    for _, observation in ipairs(EW.Database().observations) do
      if observation.kind == "transit" then found[#found + 1] = observation end
    end
    return found
  end

  -- The made up character: a clock, a place in the world, and a map.
  local clock, x, y, instance = 1000, 0, 0, 1
  local map, mapX, mapY = 1413, 0.6312, 0.3856
  local last
  --[[ Looks for a number of seconds while the character moves over the
       ground at a speed, in yards a second, with its own speed given. ]]
  local function pass(seconds, over, own, more)
    for _ = 1, seconds * 2 do
      clock = clock + 0.5
      x = x + over * 0.5
      local look = { t = clock, x = x, y = y, instance = instance, own = own, map = map, mapX = mapX, mapY = mapY }
      for key, value in pairs(more or {}) do look[key] = value end
      last = EW.RideLook(look)
    end
    return last
  end
  local function reset()
    EW.ForgetRide()
    clock, x, y, instance = clock + 100, 0, 0, 1
    map, mapX, mapY = 1413, 0.6312, 0.3856
  end

  -- A plain crossing with no loading screen: stand, be carried, come to rest.
  pass(5, 0, 0)
  equal("standing still is no ride", last, nil)
  local setOff = clock
  pass(100, 20, 0)
  equal("being carried is a ride in hand", last, "ride")
  equal("nothing is written while it lasts", #rides(), 0)
  local cameToRest = clock
  map, mapX, mapY = 1434, 0.2731, 0.7712
  pass(3.5, 0, 0)
  equal("a short rest does not end it", last, "ride")
  pass(1, 0, 0)
  local list = rides()
  equal("coming to rest ends it, and it is written", #list, 1)
  local ride = list[1]
  equal("its subject is a ride", ride.subject, "transit")
  equal("it has no id", ride.id, nil)
  equal("its place is where it set off: the map", ride.map, 1413)
  equal("and the position", ride.x, 0.6312)
  equal("to four places", ride.y, 0.3856)
  equal("the seconds, from setting off to coming to rest", ride.payload.s, cameToRest - setOff)
  equal("the faction of the character", ride.payload.f, "horde")
  equal("the map it ended on", ride.payload.tm, 1434)
  equal("and where", ride.payload.tx, 0.2731)
  equal("to four places too", ride.payload.ty, 0.7712)
  equal("with no loading screen", ride.payload.n, 0)
  equal("nothing is left in hand", (EW.RideState()), nil)

  -- A crossing between continents: the loading screen is part of the ride.
  reset()
  pass(2, 0, 0)
  setOff = clock
  pass(40, 20, 0)
  EW.RideLoadingScreen(false)
  clock = clock + 20
  local savedTime = rawget(_G, "GetTime")
  rawset(_G, "GetTime", function() return clock end)
  instance, x, y = 0, -8000, 300
  EW.RideLoadingScreen(true)
  pass(30, 20, 0)
  cameToRest = clock
  map, mapX, mapY = 1434, 0.27, 0.77
  pass(5, 0, 0)
  list = rides()
  equal("a crossing with a loading screen is one ride", #list, 2)
  equal("timed through the loading screen", list[2].payload.s, cameToRest - setOff)
  equal("which it counts", list[2].payload.n, 1)

  -- A boat that is already at rest when the far side loads.
  reset()
  pass(2, 0, 0)
  setOff = clock
  pass(60, 20, 0)
  EW.RideLoadingScreen(false)
  clock = clock + 15
  instance, x, y = 0, -8000, 300
  EW.RideLoadingScreen(true)
  local loaded = clock
  pass(5, 0, 0)
  list = rides()
  equal("a ride that ends with the loading screen is written", #list, 3)
  equal("up to the moment the far side appeared", list[3].payload.s, loaded - setOff)

  -- What is not a ride.
  local before = #rides()
  reset()
  pass(120, 7, 7)
  equal("walking, however long, is no ride", #rides(), before)
  equal("and none is in hand", (EW.RideState()), nil)
  pass(5, 0, 0)
  reset()
  pass(2, 0, 0)
  pass(60, 27, 7)
  pass(5, 0, 0)
  equal("running about the deck of a moving boat is still a ride", #rides(), before + 1)
  before = before + 1

  reset()
  pass(2, 0, 0)
  pass(10, 20, 0)
  pass(5, 0, 0)
  equal("a ride under half a minute is not written", #rides(), before)
  reset()
  pass(2, 0, 0)
  pass(950, 20, 0)
  pass(5, 0, 0)
  equal("nor one over a quarter of an hour", #rides(), before)
  equal("which is let go of", (EW.RideState()), nil)

  reset()
  pass(2, 0, 0)
  pass(40, 20, 0)
  pass(2, 0, 0, { taxi = true })
  pass(20, 20, 0)
  pass(5, 0, 0)
  equal("a flight in the middle throws the ride away, and the rest is too short", #rides(), before)
  reset()
  pass(2, 0, 0)
  pass(60, 20, 0, { indoors = true })
  pass(5, 0, 0)
  equal("nothing inside an instance is a ride", #rides(), before)

  -- Carried out and back to where it began, with no loading screen.
  reset()
  pass(2, 0, 0)
  pass(30, 20, 0)
  pass(30, -20, 0)
  pass(5, 0, 0)
  equal("a ride that ends where it began is no crossing", #rides(), before)

  -- Where the character's own speed cannot be read.
  reset()
  pass(2, 0, nil)
  pass(60, 20, nil)
  pass(5, 0, nil)
  equal("with no speed of its own to read, standing still and moving fast is a ride", #rides(), before + 1)
  before = before + 1
  reset()
  pass(2, 0, nil)
  pass(60, 20, nil, { walking = true })
  pass(5, 0, nil)
  equal("but not while it walks", #rides(), before)
  reset()
  pass(2, 0, nil)
  pass(60, 20, nil, { falling = true })
  pass(5, 0, nil)
  equal("nor while it falls", #rides(), before)
  reset()
  pass(2, 0, nil)
  pass(60, 6, nil)
  pass(5, 0, nil)
  equal("nor slower than a boat goes", #rides(), before)

  -- Looks the client would not answer, in the middle of a ride.
  reset()
  pass(2, 0, 0)
  setOff = clock
  pass(40, 20, 0)
  for _ = 1, 10 do
    clock = clock + 0.5
    x = x + 10
    EW.RideLook({ t = clock, instance = instance, own = 0, map = map })
  end
  equal("a ride is kept through looks that went unanswered", (EW.RideState()) ~= nil, true)
  pass(30, 20, 0)
  cameToRest = clock
  pass(5, 0, 0)
  equal("and written when it ends", #rides(), before + 1)
  equal("for its whole length", rides()[#rides()].payload.s, cameToRest - setOff)
  before = before + 1

  -- A character of neither faction.
  local faction = _G.UnitFactionGroup
  _G.UnitFactionGroup = function() return "Neutral" end
  reset()
  pass(2, 0, 0)
  pass(60, 20, 0)
  pass(5, 0, 0)
  equal("no faction, no ride written", #rides(), before)
  _G.UnitFactionGroup = faction

  -- The client itself, looked at the way the ticker looks at it.
  local saved = {}
  local function set(name, value)
    saved[name] = rawget(_G, name)
    rawset(_G, name, value)
  end
  local north, west, continent, speed, onTaxi = 0, 0, 1, 0, false
  set("UnitPosition", function(unit) if unit == "player" then return north, west, 12, continent end end)
  set("GetUnitSpeed", function() return speed end)
  set("UnitOnTaxi", function() return onTaxi end)
  set("IsInInstance", function() return false end)
  local function tick(seconds, over)
    local result
    for _ = 1, seconds * 2 do
      clock = clock + 0.5
      west = west + over * 0.5
      result = EW.RideTick()
    end
    return result
  end
  EW.ForgetRide()
  clock = clock + 100
  stub.state.map = 1413
  stub.state.position = { x = 0.63121, y = 0.38559 }
  tick(2, 0)
  setOff = clock
  equal("the client's own answers make a ride", tick(50, 18), "ride")
  cameToRest = clock
  stub.state.map = 1434
  stub.state.position = { x = 0.2731, y = 0.7712 }
  tick(5, 0)
  local written = rides()[#rides()]
  equal("which is written", #rides(), before + 1)
  equal("from the map the client gave", written.map, 1413)
  equal("the position rounded to four places", written.x, 0.6312)
  equal("to the map it ended on", written.payload.tm, 1434)
  equal("in its seconds", written.payload.s, cameToRest - setOff)
  before = before + 1

  onTaxi = true
  tick(2, 0)
  onTaxi = false
  EW.ForgetRide()
  rawset(_G, "issecretvalue", function(value) return value == west end)
  tick(2, 0)
  tick(60, 18)
  tick(5, 0)
  equal("a position the client holds back makes no ride", #rides(), before)
  rawset(_G, "issecretvalue", nil)

  -- The status and the window count the kind like any other.
  stub.state.printed = {}
  EW.SlashCommand("status")
  check("status counts the rides", table.concat(stub.state.printed, "\n"):find("transit", 1, true) ~= nil)
  stub.state.printed = {}
  local rows = EW.RecordedRows()
  local labelled = false
  for _, row in ipairs(rows) do
    if row[1] == "Transport Rides" and row[2] == #rides() then labelled = true end
  end
  check("and the Recorded page names them as the site's upload page does", labelled)

  for name, value in pairs(saved) do rawset(_G, name, value) end
  rawset(_G, "UnitPosition", saved.UnitPosition)
  rawset(_G, "GetUnitSpeed", saved.GetUnitSpeed)
  rawset(_G, "UnitOnTaxi", saved.UnitOnTaxi)
  rawset(_G, "IsInInstance", saved.IsInInstance)
  rawset(_G, "GetTime", savedTime)
  stub.state.map = nil
  stub.state.position = nil

  -- Off WoW Forever the recorder is not started even with a ticker to give.
  local ticker = rawget(_G.C_Timer, "NewTicker")
  local started = 0
  _G.C_Timer.NewTicker = function() started = started + 1 end
  rawset(_G, "UnitPosition", function() return 0, 0, 0, 1 end)
  rawset(_G, "GetUnitSpeed", function() return 0 end)
  local forever = t.LoadFreshAddon(2, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  equal("on WoW Forever, with a ticker and a position to read, it starts", forever.RIDES_STARTED, true)
  equal("its status line begins at nothing seen", forever.RideReport(), "ride recorder: looks 0, unanswered 0, rides begun 0, written 0")
  forever.RideLook({ t = 1, x = 0, y = 0, instance = 1, own = 0 })
  forever.RideLook({ t = 1.5, instance = 1, own = 0 })
  equal("and counts the looks, answered and not", forever.RideReport(), "ride recorder: looks 2, unanswered 1, rides begun 0, written 0")
  local startedOnForever = started
  local era = t.LoadFreshAddon(2, { "1.15.9", "50000", "Sep 17 2026", 11509 })
  equal("on Classic Era it does not", era.RIDES_STARTED, false)
  _G.C_Timer.NewTicker = ticker
  rawset(_G, "UnitPosition", saved.UnitPosition)
  rawset(_G, "GetUnitSpeed", saved.GetUnitSpeed)
  check("and asks for one ticker of its own", startedOnForever >= 1)
end
