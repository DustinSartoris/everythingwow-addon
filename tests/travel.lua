--[[
The route planner's tests, run from tests/run.lua.

The planner is the site's own, written again in Lua, so the first thing
proved is that it answers as the site does: tests/travel_cases.lua holds
trips the site's planner answered, and each is asked again here and compared
step by step, to the second and to the word. The rest proves the part that
only exists in the game: finding a place by name, knowing where the
character stands, the chat command, and that nothing runs off WoW Forever.
]]

return function(t)
  local check, equal, stub = t.check, t.equal, t.stub

  local EW = t.LoadFreshAddon(2, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  local Travel = EW.Travel
  check("the planner loads with its facts", type(Travel) == "table" and type(EW.TRAVEL) == "table")

  -- The facts, counted as the site's files count them.
  local zones = 0
  for _ in pairs(EW.TRAVEL.ZONES) do zones = zones + 1 end
  equal("46 zones", zones, 46)
  equal("the zone order lists each zone once", #EW.TRAVEL.ZONE_ORDER, 46)
  equal("127 places", #EW.TRAVEL.PLACES, 127)
  equal("49 land crossings", #EW.TRAVEL.LAND_EDGES, 49)
  equal("15 transport routes", #EW.TRAVEL.ROUTES, 15)
  equal("195 measured flights", #EW.TRAVEL.FLIGHTS.alliance + #EW.TRAVEL.FLIGHTS.horde, 195)
  local mapped = 0
  for _, key in pairs(EW.TRAVEL.ZONE_MAPS) do
    mapped = mapped + 1
    check("the map of " .. key .. " names a zone the planner has", EW.TRAVEL.ZONES[key] ~= nil)
  end
  equal("44 zones carry the game's map number", mapped, 44)

  -- The site's answers.
  local cases = dofile(t.root .. "tests/travel_cases.lua")
  check("the cases are there", #cases > 200, #cases)
  local function near(a, b) return math.abs(a - b) <= 1e-6 * math.max(1, math.abs(b)) end
  local routed, refused, enemy = 0, 0, 0
  for index, case in ipairs(cases) do
    local name = "case " .. index .. " " .. case.from .. " to " .. case.to .. " " .. case.faction .. " " .. case.speed
    local result = Travel.Plan(case)
    equal(name .. ": routed or refused as on the site", result.ok, case.ok)
    if result.ok and case.ok then
      routed = routed + 1
      if case.enemyTransport then enemy = enemy + 1 end
      equal(name .. ": the number of steps", #result.steps, #case.steps)
      local same = #result.steps == #case.steps
      for at, want in ipairs(case.steps) do
        local step = result.steps[at]
        if step then
          same = same and step.family == want[1] and step.fromNode == want[2] and step.toNode == want[3]
            and near(step.seconds, want[4]) and Travel.StepLine(step) == want[5]
          if not same then
            check(name .. ": step " .. at, false, Travel.StepLine(step) .. " | " .. want[5])
            break
          end
        end
      end
      check(name .. ": every step is the site's", same)
      check(name .. ": the band is the site's",
        near(result.band.low, case.low) and near(result.band.mid, case.mid) and near(result.band.high, case.high))
      equal(name .. ": the estimate is the site's sentence", Travel.Estimate(result.band), case.estimate)
      equal(name .. ": the land weighting", result.factor, case.factor)
      equal(name .. ": enemy transport", result.enemyTransport, case.enemyTransport)
    elseif not result.ok and not case.ok then
      refused = refused + 1
      equal(name .. ": the reason", result.reason, case.reason)
      equal(name .. ": the place named", result.place, case.place)
    end
  end
  check("most cases route", routed > 150, routed)
  check("some cases are refused", refused > 10, refused)

  -- The words.
  equal("no time at all", Travel.Duration(0), "0 min")
  equal("under a minute is a minute", Travel.Duration(20), "1 min")
  equal("minutes round to the nearest", Travel.Duration(89), "1 min")
  equal("and up from the half", Travel.Duration(90), "2 min")
  equal("an hour and more", Travel.Duration(3900), "1 h 5")
  equal("the refusal for one place twice", Travel.Refusal("same_place"), "Pick two different places.")
  equal("the refusal inside a zone", Travel.Refusal("already_in_zone", "Durotar"),
    "The starting place is already inside Durotar.")
  equal("an unknown reason reads as no way", Travel.Refusal("something"), "There is no known way between these two places.")

  -- Finding a place by name.
  equal("an exact place", Travel.Find("Booty Bay"), "place:bootybay")
  equal("whatever the case and the spaces", Travel.Find("  booty bay "), "place:bootybay")
  equal("an exact zone", Travel.Find("Westfall"), "zone:westfall")
  equal("the start of a name", Travel.Find("gadget"), "place:gadgetzan")
  equal("words inside a name", Travel.Find("hope chapel"), "place:lights-hope-chapel")
  equal("a place before a zone of the same start", Travel.Find("Stormwind"), "place:stormwind")
  equal("nothing for no words", Travel.Find("   "), nil)
  equal("nothing for a name not on the map", Travel.Find("Shattrath"), nil)
  equal("nothing for a number", Travel.Find(42), nil)
  equal("a pattern character is read as a letter", Travel.Find("%"), nil)

  -- Where the character stands.
  stub.state.map = 1454
  equal("a capital's map is the capital", Travel.Here(), "place:orgrimmar")
  stub.state.map = 1413
  equal("a zone's map is the zone", Travel.Here(), "zone:barrens")
  stub.state.map = 99999
  equal("a map the planner does not know is nowhere", Travel.Here(), nil)
  stub.state.map = nil
  equal("no map is nowhere", Travel.Here(), nil)

  -- The command.
  local function run(text)
    stub.state.printed = {}
    EW.SlashCommand(text)
    local lines = {}
    for index, line in ipairs(stub.state.printed) do lines[index] = (line:gsub("^|c%x+Everything WoW|r: ", "")) end
    return lines
  end
  local lines = run("route Orgrimmar > Undercity")
  equal("the trip heads the answer", lines[1], "Orgrimmar to Undercity (On foot)")
  check("then the estimate", lines[2] and lines[2]:find("^Estimated travel time %d+ min to %d+ min, typically %d+ min%.$") ~= nil, lines[2])
  check("then the numbered steps", lines[3] and lines[3]:find("^1%. Orgrimmar to ") ~= nil, lines[3])
  check("a Horde trip to Undercity takes the zeppelin", table.concat(lines, "\n"):find("zeppelin", 1, true) ~= nil)
  local plan = Travel.Plan({ from = "place:orgrimmar", to = "place:undercity", faction = "horde", speed = "foot", flightPaths = true, skyborne = false })
  equal("the command prints every step of the plan", #lines, 2 + #plan.steps)

  stub.state.map = 1454
  lines = run("route undercity")
  equal("one place is a trip from where the character stands", lines[1], "Orgrimmar to Undercity (On foot)")
  stub.state.map = nil
  lines = run("route undercity")
  check("off every known map the planner asks for both places", #lines == 1 and lines[1]:find("Name both places", 1, true) ~= nil, lines[1])
  lines = run("route")
  check("no words prints the usage", #lines == 1 and lines[1]:find("^Usage: /ewow route ") ~= nil, lines[1])
  lines = run("route Orgrimmar > Shattrath")
  equal("a place not on the map is refused in the site's words", lines[1], "That place is not on this map.")
  lines = run("route Orgrimmar > orgrimmar")
  equal("one place twice is refused", lines[1], "Pick two different places.")
  lines = run("route Gilneas > Orgrimmar")
  equal("a closed zone is refused", lines[1], "That zone is closed in Forever, so no route can enter it.")

  -- The speed is the one thing the planner saves.
  equal("no speed is saved until one is set", EW.Database().travelSpeed, nil)
  lines = run("route speed 100")
  equal("the speed is saved", EW.Database().travelSpeed, "mount_100")
  equal("and said", lines[1], "Routes are now timed at: Mount 100%.")
  lines = run("route Orgrimmar > Undercity")
  equal("the next trip is timed at it", lines[1], "Orgrimmar to Undercity (Mount 100%)")
  lines = run("route speed 60%")
  equal("a percent sign is fine", EW.Database().travelSpeed, "mount_60")
  lines = run("route speed fast")
  check("an unknown speed lists the speeds and changes nothing",
    lines[1]:find("^Speeds: foot, travel, 60, 100%. Now: Mount 60%%%.$") ~= nil and EW.Database().travelSpeed == "mount_60", lines[1])
  EW.Database().travelSpeed = "warp"
  lines = run("route Orgrimmar > Undercity")
  equal("a saved speed the planner does not know reads as on foot", lines[1], "Orgrimmar to Undercity (On foot)")
  run("route speed foot")

  -- The faction and the race are the character's.
  local faction = _G.UnitFactionGroup
  _G.UnitFactionGroup = function() return "Alliance" end
  lines = run("route Stormwind > Ironforge")
  check("an Alliance trip from Stormwind to Ironforge takes the tram", table.concat(lines, "\n"):find("Deeprun Tram", 1, true) ~= nil, lines[3])
  _G.UnitFactionGroup = function() return "Neutral" end
  lines = run("route Stormwind > Ironforge")
  check("a character of neither faction is told so", #lines == 1 and lines[1]:find("Alliance or the Horde", 1, true) ~= nil, lines[1])
  _G.UnitFactionGroup = function() error("no faction yet") end
  lines = run("route Stormwind > Ironforge")
  check("a client that cannot say the faction is told the same, with no error", #lines == 1 and lines[1]:find("Alliance or the Horde", 1, true) ~= nil)
  _G.UnitFactionGroup = faction

  local race = _G.UnitRace
  local function steps(text)
    local found = run(text)
    return table.concat(found, "\n")
  end
  _G.UnitFactionGroup = function() return "Alliance" end
  _G.UnitRace = function() return "High Order Skyborne", "HighOrderSkyborne" end
  local skyborne = steps("route Dalaran > Stormwind")
  _G.UnitRace = function() return "Human", "Human" end
  local human = steps("route Dalaran > Stormwind")
  check("a Skyborne is offered the Skyborne portal and a Human is not",
    skyborne:find("portal", 1, true) ~= nil and human:find("portal", 1, true) == nil)
  _G.UnitRace = race
  _G.UnitFactionGroup = faction

  -- Nothing but the speed reaches the saved file, and no observation is made.
  local before = #EW.Database().observations
  run("route Orgrimmar > Booty Bay")
  equal("planning a route records nothing", #EW.Database().observations, before)

  -- Off WoW Forever the planner declines.
  local retail = t.LoadFreshAddon(1, { "12.1.0", "60000", "Sep 17 2026", 120100 })
  stub.state.printed = {}
  retail.SlashCommand("route Orgrimmar > Undercity")
  equal("on another client the command says where the planner works", #stub.state.printed, 1)
  check("in one line", stub.state.printed[1]:find("covers WoW Forever only", 1, true) ~= nil, stub.state.printed[1])
  stub.state.printed = {}

  -- The beach north of Theramore is the Alliance's way alone, walked and
  -- with its warning; the Horde is never offered it.
  local function beach(faction)
    local plan = Travel.Plan({ from = "place:theramore", to = "place:ratchet", faction = faction, speed = "foot", flightPaths = false, skyborne = false })
    if not plan.ok then return nil, plan end
    for _, step in ipairs(plan.steps) do
      if step.family == "city" and step.what == "the beach north of Theramore" then return step, plan end
    end
    return nil, plan
  end
  local crossing, alliancePlan = beach("alliance")
  check("the Alliance walks the beach from Theramore to Ratchet", crossing ~= nil and #alliancePlan.steps == 1)
  equal("with the warning on the step", crossing and crossing.caution, "Murlocs of level 37 to 38 hold the beach: swim around them.")
  equal("and in its line", crossing and Travel.StepLine(crossing),
    "Theramore Isle to Ratchet, the beach north of Theramore, Murlocs of level 37 to 38 hold the beach: swim around them, 7 min")
  local hordeCrossing, hordePlan = beach("horde")
  check("the Horde is not offered the beach", hordeCrossing == nil and hordePlan.ok == true)

  -- The two Riverglades flight masters fly only where players have seen them fly.
  local function flightsFrom(plan, name)
    local found = {}
    for _, step in ipairs(plan.steps) do
      if step.family == "flight" and (step.from == name or step.to == name) then
        found[#found + 1] = step.from == name and step.to or step.from
      end
    end
    return table.concat(found, ", ")
  end
  local toFarholde = Travel.Plan({ from = "place:orgrimmar", to = "place:farholde", faction = "alliance", speed = "foot", flightPaths = true, skyborne = false })
  equal("Farholde Keep is reached by flight from Lakeshire", toFarholde.ok and flightsFrom(toFarholde, "Farholde Keep"), "Lakeshire")
  local toRogmar = Travel.Plan({ from = "place:undercity", to = "place:rogmar", faction = "horde", speed = "foot", flightPaths = true, skyborne = false })
  equal("Rog'mar by flight from Hammerfall", toRogmar.ok and flightsFrom(toRogmar, "Rog'mar"), "Hammerfall")
  local toPowderfuse = Travel.Plan({ from = "place:stormwind", to = "place:powderfuse", faction = "alliance", speed = "foot", flightPaths = true, skyborne = false })
  equal("no flight lands at Powderfuse Port, which has no flight master yet", toPowderfuse.ok and flightsFrom(toPowderfuse, "Powderfuse Port"), "")

  -- The planner changes nothing it was given.
  local input = { from = "place:orgrimmar", to = "zone:westfall", faction = "horde", speed = "foot", flightPaths = true, skyborne = false }
  local first = Travel.Plan(input)
  local second = Travel.Plan(input)
  check("asked twice, it answers twice the same",
    first.ok and second.ok and #first.steps == #second.steps and first.band.mid == second.band.mid)
  equal("and leaves the question as it was", input.from .. input.to .. input.speed, "place:orgrimmarzone:westfallfoot")
end
