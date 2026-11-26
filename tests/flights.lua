--[[
The flight recorder's tests, run from tests/run.lua.

A stand in for the game's flight map is set up before the addon loads, the
way the client has it before any addon does: the nodes of one flight
master's map, the call that picks a destination, and a clock. Then flights
are flown: a plain one, one with a stop on the way, and each kind that must
not be written.
]]

return function(t)
  local check, equal, stub = t.check, t.equal, t.stub

  -- The flight map of the flight master the character stands at.
  local nodes = {
    { name = "Orgrimmar, Durotar", type = "CURRENT" },
    { name = "Crossroads, The Barrens", type = "REACHABLE" },
    { name = "Thunder Bluff, Mulgore", type = "REACHABLE" },
    { name = "Far |cffff0000Away|r", type = "REACHABLE" },
    { name = "Nowhere", type = "DISTANT" },
  }
  local clock, onTaxi = 1000, false
  local hooks = {}
  local saved = {}
  local function set(name, value)
    saved[name] = rawget(_G, name)
    rawset(_G, name, value)
  end
  set("GetTime", function() return clock end)
  set("UnitOnTaxi", function(unit) return unit == "player" and onTaxi end)
  set("NumTaxiNodes", function() return #nodes end)
  set("TaxiNodeName", function(slot) return nodes[slot] and nodes[slot].name end)
  set("TaxiNodeGetType", function(slot) return nodes[slot] and nodes[slot].type end)
  set("TakeTaxiNode", function() end)
  set("TaxiRequestEarlyLanding", function() end)
  set("hooksecurefunc", function(name, hook)
    local original = rawget(_G, name)
    hooks[name] = hook
    rawset(_G, name, function(...)
      local result = original(...)
      hook(...)
      return result
    end)
  end)

  local EW = t.LoadFreshAddon(2, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  equal("the recorder finds the game's hook", EW.FLIGHTS_HOOKED, true)
  check("it hooks the call that picks a destination", type(hooks.TakeTaxiNode) == "function")

  local function flights()
    local found = {}
    for _, observation in ipairs(EW.Database().observations) do
      if observation.kind == "flight" then found[#found + 1] = observation end
    end
    return found
  end
  local function at(map, x, y)
    stub.state.map = map
    stub.state.position = { x = x, y = y }
  end
  --[[ One flight: open the map, pick a slot, take off, and land after
       the given seconds at the given place. ]]
  local function fly(slot, seconds, options)
    options = options or {}
    at(1454, 0.4512, 0.6388)
    stub.Fire("TAXIMAP_OPENED")
    TakeTaxiNode(slot)
    clock = clock + (options.delay or 1)
    onTaxi = options.neverTaxi ~= true
    stub.Fire("PLAYER_CONTROL_LOST")
    if options.midway then options.midway() end
    clock = clock + seconds
    at(options.landMap or 1413, 0.5161, 0.3043)
    if options.lateTaxi then
      -- The real client's order: control comes back first, and only a
      -- moment later does it stop saying "on a taxi".
      stub.Fire("PLAYER_CONTROL_GAINED")
      stub.RunTimers(2)
      clock = clock + options.lateTaxi
      onTaxi = false
    else
      onTaxi = false
      stub.Fire("PLAYER_CONTROL_GAINED")
    end
    -- The recorder asks again and again whether the taxi is over.
    stub.RunTimers(30)
  end

  -- A plain flight.
  equal("nothing is written before a flight", #flights(), 0)
  fly(2, 79.26)
  local list = flights()
  equal("one flight is one observation", #list, 1)
  local flight = list[1]
  equal("its subject is a flight", flight.subject, "flight")
  equal("it has no id", flight.id, nil)
  equal("its place is the flight master's map", flight.map, 1454)
  equal("and position", flight.x, 0.4512)
  equal("to four places", flight.y, 0.6388)
  equal("from, as the flight map names it", flight.payload.from, "Orgrimmar, Durotar")
  equal("to, the same way", flight.payload.to, "Crossroads, The Barrens")
  equal("the seconds, to a tenth", flight.payload.s, 79.3)
  equal("the faction of the network", flight.payload.f, "horde")
  equal("the map it landed on", flight.payload.tm, 1413)
  equal("and where", flight.payload.tx, 0.5161)
  equal("to four places too", flight.payload.ty, 0.3043)
  local inAir, picked, waiting = EW.FlightState()
  check("nothing is left in the air, picked or waiting", inAir == nil and picked == nil and waiting == nil)
  check("the status line counts it", EW.FlightReport():find("takeoffs 1, landings 1, written 1", 1, true) ~= nil, EW.FlightReport())

  -- The same flight again is a second measurement, not a repeat. It lands
  -- the way the real client lands: control back first, off the taxi after.
  -- Until 0.4.3 that order left the flight in the air for good, and no
  -- flight was ever written.
  fly(2, 80, { lateTaxi = 0.4 })
  equal("a flight whose taxi ends a moment after control comes back is written", #flights(), 2)
  equal("timed to the moment control came back", flights()[2].payload.s, 80)
  check("and nothing is left in the air after it", (EW.FlightState()) == nil)

  -- A stop on the way hands control back for a moment while still on the taxi.
  fly(3, 200, {
    midway = function()
      clock = clock + 60
      onTaxi = true
      stub.Fire("PLAYER_CONTROL_GAINED")
      stub.Fire("PLAYER_CONTROL_LOST")
    end,
  })
  list = flights()
  equal("a flight with a stop is one flight", #list, 3)
  equal("timed from the first takeoff to the last landing", list[3].payload.s, 260)
  equal("to the destination picked", list[3].payload.to, "Thunder Bluff, Mulgore")

  -- What must not be written.
  local before = #flights()
  fly(2, 3)
  equal("a flight under five seconds is not a flight", #flights(), before)
  fly(2, 2000)
  equal("nor one over half an hour", #flights(), before)
  fly(2, 90, { delay = 20 })
  equal("a loss of control long after the pick is not the takeoff", #flights(), before)
  fly(2, 90, { neverTaxi = true })
  equal("a loss of control the client never calls a taxi is not a flight", #flights(), before)
  check("and the status line says why", EW.FlightReport():find("never said the character was on a taxi", 1, true) ~= nil, EW.FlightReport())
  fly(2, 90, { midway = function() TaxiRequestEarlyLanding() end })
  equal("a flight ended early is not the whole flight", #flights(), before)
  fly(2, 90, { midway = function() stub.Fire("PLAYER_LEAVING_WORLD") end })
  equal("a flight a loading screen cut is not written", #flights(), before)
  fly(1, 90)
  equal("picking the flight master you stand at is no flight", #flights(), before)
  fly(4, 90)
  equal("a name with a color code in it is refused", #flights(), before)
  fly(9, 90)
  equal("a slot the map does not have is refused", #flights(), before)

  -- Control lost with nothing picked, a stun or a fear, is ignored.
  stub.Fire("PLAYER_CONTROL_LOST")
  clock = clock + 30
  stub.Fire("PLAYER_CONTROL_GAINED")
  equal("losing control with no destination picked writes nothing", #flights(), before)

  -- The client says "on a taxi" only a moment after the takeoff.
  at(1454, 0.4512, 0.6388)
  stub.Fire("TAXIMAP_OPENED")
  TakeTaxiNode(2)
  clock = clock + 1
  onTaxi = false
  stub.state.timers = {}
  stub.Fire("PLAYER_CONTROL_LOST")
  onTaxi = true
  stub.RunTimers(1)
  clock = clock + 70
  onTaxi = false
  stub.Fire("PLAYER_CONTROL_GAINED")
  stub.RunTimers(5)
  equal("a taxi the client confirms a moment late is still a flight", #flights(), before + 1)
  before = before + 1

  -- A character of neither faction has no network to name.
  local faction = _G.UnitFactionGroup
  _G.UnitFactionGroup = function() return "Neutral" end
  fly(2, 90)
  equal("no faction, no flight written", #flights(), before)
  _G.UnitFactionGroup = function() return "Alliance" end
  fly(2, 90)
  equal("an Alliance flight is written", #flights(), before + 1)
  equal("as the Alliance's", flights()[#flights()].payload.f, "alliance")
  _G.UnitFactionGroup = faction

  -- A flight map opened where the position cannot be read still times the flight.
  stub.state.position = nil
  stub.Fire("TAXIMAP_OPENED")
  TakeTaxiNode(2)
  clock = clock + 1
  onTaxi = true
  stub.Fire("PLAYER_CONTROL_LOST")
  clock = clock + 75
  onTaxi = false
  stub.Fire("PLAYER_CONTROL_GAINED")
  stub.RunTimers(5)
  local last = flights()[#flights()]
  equal("with no position the flight is still written", last.payload.s, 75)
  equal("without a place", last.x, nil)

  -- A client that holds "on a taxi" back from addons: the flight is not
  -- ended on a value that cannot be read.
  at(1454, 0.4512, 0.6388)
  stub.Fire("TAXIMAP_OPENED")
  TakeTaxiNode(2)
  clock = clock + 1
  onTaxi = true
  stub.Fire("PLAYER_CONTROL_LOST")
  clock = clock + 40
  rawset(_G, "issecretvalue", function(value) return value == true or value == false end)
  stub.RunTimers(5)
  check("a flight is kept while the client will not say", (EW.FlightState()) ~= nil)
  rawset(_G, "issecretvalue", nil)
  clock = clock + 40
  onTaxi = false
  stub.Fire("PLAYER_CONTROL_GAINED")
  stub.RunTimers(5)
  equal("and written once it says the taxi is over", flights()[#flights()].payload.s, 80)

  -- The status line counts the kind like any other.
  stub.state.printed = {}
  EW.SlashCommand("status")
  check("status counts the flights", table.concat(stub.state.printed, "\n"):find("flight", 1, true) ~= nil)
  stub.state.printed = {}

  -- Put the client back as the other tests expect it.
  for name, value in pairs(saved) do rawset(_G, name, value) end
  rawset(_G, "GetTime", saved.GetTime)
  rawset(_G, "hooksecurefunc", saved.hooksecurefunc)
  rawset(_G, "TakeTaxiNode", saved.TakeTaxiNode)
  rawset(_G, "TaxiRequestEarlyLanding", saved.TaxiRequestEarlyLanding)
  rawset(_G, "NumTaxiNodes", saved.NumTaxiNodes)
  rawset(_G, "TaxiNodeName", saved.TaxiNodeName)
  rawset(_G, "TaxiNodeGetType", saved.TaxiNodeGetType)
  rawset(_G, "UnitOnTaxi", saved.UnitOnTaxi)
  stub.state.map = nil
  stub.state.position = nil

  -- On a client with no hook to give, the recorder registers nothing.
  local plain = t.LoadFreshAddon(2, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  equal("without the hook the recorder stays off", plain.FLIGHTS_HOOKED, false)
end
