--[[
The travel planner.

This is everythingwow.com's own route planner, the one behind its WoW Forever
map, written again in Lua and run on the same facts (TravelData.lua). Ask it
for a trip and it answers the way the website does: the steps, in order, and
how long the whole trip takes, as a low, a usual and a high time.

How it works, as on the site. The world is a graph. A zone is a node and so
is a place a traveler passes through: a capital, a harbor, a zeppelin tower,
a flight master. The edges are the ways between them: a crossing from one
zone to the next, the walk from a place into its zone or to another place of
the same zone, a link inside a city, a boat, zeppelin, tram or portal, and a
flight between two flight masters of one continent. The cheapest path is
found, tried under a few weightings of the walking, and the winner is timed
again leg by leg from where the traveler really stands.

It reads nothing of the player but the faction, the race and the map the
character stands on, sends nothing, and writes nothing to the saved file but
the one setting /ewow route speed makes.

It runs on WoW Forever alone: the facts are that world's.
]]

local ADDON_NAME, EW = ...

local T = EW.TRAVEL
local Travel = {}
EW.Travel = Travel

if type(T) ~= "table" then return end

local M = T.MODEL
local ZONES = T.ZONES

local PLACE = {}
for _, place in ipairs(T.PLACES) do PLACE[place.key] = place end

-- Each gate, by the two zones it joins, either way round.
local GATES = {}
for _, edge in ipairs(T.LAND_EDGES) do
  local gate = { x = edge.gx, y = edge.gy }
  GATES[edge.from .. "|" .. edge.to] = gate
  GATES[edge.to .. "|" .. edge.from] = gate
end

-- Measured flights, by faction and by the two names either way round. The
-- first row of a pair is the one kept.
local MEASURED = { alliance = {}, horde = {} }
for faction, rows in pairs(T.FLIGHTS) do
  local index = MEASURED[faction]
  for _, row in ipairs(rows) do
    local a, b = row[1] .. "|" .. row[2], row[2] .. "|" .. row[1]
    if index[a] == nil then index[a] = row[3] end
    if index[b] == nil then index[b] = row[3] end
  end
end

-- The pairs a city link joins, which the zone walk leaves to the link.
local LINKED = {}
for _, link in ipairs(T.CITY_LINKS) do
  LINKED[link.from .. "|" .. link.to] = true
  LINKED[link.to .. "|" .. link.from] = true
end

Travel.SPEEDS = { "foot", "travel_form", "mount_60", "mount_100" }

--------------------------------------------------------------------------
-- Nodes
--------------------------------------------------------------------------

local function ReadNode(node)
  if type(node) ~= "string" then return nil end
  if node:sub(1, 5) == "zone:" then return "zone", node:sub(6) end
  if node:sub(1, 6) == "place:" then return "place", node:sub(7) end
  return nil
end

local function ZoneNode(key) return "zone:" .. key end
local function PlaceNode(key) return "place:" .. key end

local function NodeName(node)
  local kind, key = ReadNode(node)
  if kind == "zone" then return ZONES[key] and ZONES[key].name or nil end
  if kind == "place" then return PLACE[key] and PLACE[key].name or nil end
  return nil
end
Travel.NodeName = NodeName

local function ZoneOf(node)
  local kind, key = ReadNode(node)
  if kind == "zone" then return key end
  if kind == "place" then return PLACE[key] and PLACE[key].zone or nil end
  return nil
end

local function ContinentOfZone(zoneKey)
  if not zoneKey then return nil end
  return ZONES[zoneKey] and ZONES[zoneKey].continent or nil
end

local function ContinentOfNode(node)
  local kind, key = ReadNode(node)
  if kind == "zone" then return ZONES[key] and ZONES[key].continent or nil end
  if kind == "place" then
    local place = PLACE[key]
    if not place or not place.zone then return nil end
    return ContinentOfZone(place.zone)
  end
  return nil
end

local function PointOf(node)
  local kind, key = ReadNode(node)
  if kind == "zone" then
    local zone = ZONES[key]
    return zone and { x = zone.x, y = zone.y } or nil
  end
  if kind == "place" then
    local place = PLACE[key]
    return place and { x = place.x, y = place.y } or nil
  end
  return nil
end

local function Distance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

--------------------------------------------------------------------------
-- Weights
--------------------------------------------------------------------------

local function FootSecondsPerUnit(zoneKey)
  local yards = (zoneKey and M.footYards[zoneKey]) or M.footYardsDefault
  return (M.footSecondsPerUnit * yards) / M.footYardsDefault
end

local function WalkSeconds(units, speed, zoneKey)
  local multiplier = M.speeds[speed] or 1
  return (units * FootSecondsPerUnit(zoneKey)) / multiplier
end

local function EntrySeconds(units, speed, zoneKey)
  local raw = WalkSeconds(units, speed, zoneKey) * M.entryFactor
  return math.max(M.entryMinimum, raw)
end

local function MeanWait(rideKey)
  local ride = M.rides[rideKey]
  if not ride then return 0 end
  return (ride.waitMin + ride.waitMax) / 2
end

local function IsHub(place)
  return place.kind == "capital_city" or place.kind == "harbor" or place.kind == "zeppelin_tower"
    or place.kind == "sky_dock" or place.fm ~= nil
end

local function Includes(list, value)
  for _, entry in ipairs(list) do
    if entry == value then return true end
  end
  return false
end

--[[ Either restricted flight master must list the other end. ]]
local function FlightLinked(fromKey, toKey)
  local from, to = M.flightLinks[fromKey], M.flightLinks[toKey]
  return (not from or Includes(from, toKey)) and (not to or Includes(to, fromKey))
end

--------------------------------------------------------------------------
-- The graph
--------------------------------------------------------------------------

--[[
The whole graph for one traveler. options: faction, speed, flightPaths,
skyborne, landWeightFactor, enemyTransport, exits, endpoints (a set of node
keys). Each edge is { to, weight, detail, at }, at being the order it was
added in, which keeps the sort of a node's edges steady.
]]
local function BuildGraph(options)
  local graph, count = {}, 0
  local endpoints = options.endpoints or {}
  local factor = options.landWeightFactor or M.landFactors[1] or 1
  local speed = options.speed

  local function Push(from, to, weight, detail)
    local list = graph[from]
    if not list then
      list = {}
      graph[from] = list
    end
    count = count + 1
    list[#list + 1] = { to = to, weight = weight, detail = detail, at = count }
  end
  local function Join(a, b, weight, detail)
    Push(a, b, weight, detail)
    Push(b, a, weight, detail)
  end
  local function Admitted(place)
    return IsHub(place) or endpoints[PlaceNode(place.key)] == true
  end

  -- Land: zone center to gate to zone center.
  for _, edge in ipairs(T.LAND_EDGES) do
    local from, to = ZONES[edge.from], ZONES[edge.to]
    if from and to then
      local gate = { x = edge.gx, y = edge.gy }
      Join(
        ZoneNode(edge.from),
        ZoneNode(edge.to),
        (WalkSeconds(Distance(from, gate), speed, edge.from) + WalkSeconds(Distance(gate, to), speed, edge.to)) * factor,
        { family = "land", crossing = edge.crossing, claim = edge.claim, caution = edge.caution }
      )
    end
  end

  -- Entry: a place joins the zone it stands in.
  for _, place in ipairs(T.PLACES) do
    if not M.ferryOnly[place.key] and Admitted(place) then
      if place.zone then
        local center = ZONES[place.zone]
        if center then
          Join(
            PlaceNode(place.key),
            ZoneNode(place.zone),
            EntrySeconds(Distance(place, center), speed, place.zone),
            { family = "entry", placeKey = place.key, zoneKey = place.zone }
          )
        end
      else
        -- A place that names no zone joins the zone of the nearest gate.
        local bestZone, bestUnits = nil, math.huge
        for _, edge in ipairs(T.LAND_EDGES) do
          local units = Distance(place, { x = edge.gx, y = edge.gy })
          if units < bestUnits then
            bestUnits = units
            bestZone = edge.from
          end
        end
        if bestZone then
          Join(
            PlaceNode(place.key),
            ZoneNode(bestZone),
            EntrySeconds(bestUnits, speed, bestZone),
            { family = "entry", placeKey = place.key, zoneKey = nil }
          )
        end
      end
    end
  end

  -- Exits: a hub goes straight to each way out of its zone. One way.
  if options.exits then
    for _, place in ipairs(T.PLACES) do
      if not M.ferryOnly[place.key] and IsHub(place) and place.zone then
        for _, edge in ipairs(T.LAND_EDGES) do
          local other = nil
          if edge.from == place.zone then
            other = edge.to
          elseif edge.to == place.zone then
            other = edge.from
          end
          local center = other and ZONES[other]
          if center then
            local gate = { x = edge.gx, y = edge.gy }
            Push(
              PlaceNode(place.key),
              ZoneNode(other),
              (WalkSeconds(Distance(place, gate), speed, place.zone) + WalkSeconds(Distance(gate, center), speed, other))
                * factor,
              { family = "land", crossing = edge.crossing, claim = edge.claim, caution = edge.caution }
            )
          end
        end
      end
    end
  end

  -- City: the links inside a city, a fixed one paying its own cost.
  for _, link in ipairs(T.CITY_LINKS) do
    local from, to = PLACE[link.from], PLACE[link.to]
    if from and to then
      local weight = link.fixed
      if weight == nil then weight = EntrySeconds(Distance(from, to), speed, from.zone) end
      Join(PlaceNode(link.from), PlaceNode(link.to), weight, {
        family = "city",
        crossing = link.crossing,
        verb = link.verb,
        fixedSeconds = link.fixed,
      })
    end
  end

  -- Walk: two hubs of one zone are joined directly.
  local places = T.PLACES
  for i = 1, #places do
    local from = places[i]
    if from.zone and IsHub(from) and not M.ferryOnly[from.key] then
      for j = i + 1, #places do
        local to = places[j]
        if to.zone == from.zone and IsHub(to) and not M.ferryOnly[to.key]
          and not LINKED[from.key .. "|" .. to.key] then
          local weight = math.max(M.walkMinimum, WalkSeconds(Distance(from, to), speed, from.zone) * factor)
          Join(PlaceNode(from.key), PlaceNode(to.key), weight, {
            family = "walk",
            zoneKey = from.zone,
            fromName = from.name,
            toName = to.name,
          })
        end
      end
    end
  end

  -- Ride: every route this traveler may board, and, where asked for, the others.
  for _, route in ipairs(T.ROUTES) do
    local friendly = route.faction == "neutral" or route.faction == options.faction
    local admitted = (friendly or options.enemyTransport)
      and not (not friendly and route.skyborne)
      and not (route.skyborne and not options.skyborne)
    local rideKey = M.ferryRoutes[route.key] and "ferry" or route.kind
    local ride = M.rides[rideKey]
    if admitted and ride then
      local weight = ride.onBoard + MeanWait(rideKey)
      local sequence = { route.from }
      for _, stop in ipairs(route.stops or {}) do sequence[#sequence + 1] = stop end
      sequence[#sequence + 1] = route.to
      if route.oneWay and route.stops and #route.stops > 0 then sequence[#sequence + 1] = route.from end
      for index = 1, #sequence - 1 do
        local from, to = PLACE[sequence[index]], PLACE[sequence[index + 1]]
        if from and to then
          local detail = {
            family = "ride",
            routeKey = route.key,
            kind = route.kind,
            rideKey = rideKey,
            note = route.note,
            claim = route.claim,
            fromName = from.name,
            toName = to.name,
            waitMin = ride.waitMin,
            waitMax = ride.waitMax,
            enemy = not friendly,
            routeFaction = route.faction,
          }
          if route.oneWay then
            Push(PlaceNode(from.key), PlaceNode(to.key), weight, detail)
          else
            Join(PlaceNode(from.key), PlaceNode(to.key), weight, detail)
          end
        end
      end
    end
  end

  -- Flight: every pair of usable flight masters on one continent.
  if options.flightPaths then
    local masters = {}
    for _, place in ipairs(T.PLACES) do
      if place.fm == options.faction or place.fm == "both" then masters[#masters + 1] = place end
    end
    local measured = MEASURED[options.faction] or {}
    for i = 1, #masters do
      local from = masters[i]
      local continent = ContinentOfZone(from.zone)
      if continent ~= nil then
        for j = i + 1, #masters do
          local to = masters[j]
          if FlightLinked(from.key, to.key) and continent == ContinentOfZone(to.zone) then
            local known = measured[from.name .. "|" .. to.name]
            local seconds = known
            if seconds == nil then seconds = Distance(from, to) * M.flightSecondsPerUnit + M.flightFixed end
            Join(PlaceNode(from.key), PlaceNode(to.key), seconds + M.flightBoard, {
              family = "flight",
              measured = known ~= nil,
              fromName = from.name,
              toName = to.name,
            })
          end
        end
      end
    end
  end

  return graph
end
Travel.BuildGraph = BuildGraph

--------------------------------------------------------------------------
-- The cheapest path
--------------------------------------------------------------------------

--[[ The penalty for arriving at one node over one edge. It steers the
     choice and is never charged to the traveler. ]]
local function PenaltyFor(from, to, edge, faction, seaPenalty)
  local penalty = 0
  local kind, key = ReadNode(to)
  if kind == "zone" then
    local zoneFaction = ZONES[key] and ZONES[key].faction
    if (zoneFaction == "alliance" or zoneFaction == "horde") and zoneFaction ~= faction then
      penalty = penalty + M.enemyZonePenalty
    end
  end
  if edge.detail.family == "ride" then
    local before, after = ContinentOfNode(from), ContinentOfNode(to)
    if seaPenalty and before ~= nil and after ~= nil and before ~= after then
      penalty = penalty + M.seaPenalty
    end
    if edge.detail.enemy then penalty = penalty + M.enemyTransportPenalty end
  end
  return penalty
end

--[[ A plain Dijkstra. Equal costs are broken on the node key, so one graph
     always answers one path. Returns { nodes, edges, seconds } or nil. ]]
local function ShortestPath(graph, from, to, faction, seaPenalty)
  if not graph[from] or not graph[to] then return nil end
  if from == to then return { nodes = { from }, edges = {}, seconds = 0 } end

  local cost, real = { [from] = 0 }, { [from] = 0 }
  local cameFrom, settled, open = {}, {}, { [from] = true }

  while true do
    local current, currentCost = nil, math.huge
    for node in pairs(open) do
      local value = cost[node] or math.huge
      if value < currentCost or (value == currentCost and current ~= nil and node < current) then
        current = node
        currentCost = value
      end
    end
    if current == nil then break end
    open[current] = nil
    settled[current] = true
    if current == to then break end

    local edges = {}
    for index, edge in ipairs(graph[current] or {}) do edges[index] = edge end
    table.sort(edges, function(a, b)
      if a.to ~= b.to then return a.to < b.to end
      return a.at < b.at
    end)
    for _, edge in ipairs(edges) do
      if not settled[edge.to] then
        local nextCost = currentCost + edge.weight + PenaltyFor(current, edge.to, edge, faction, seaPenalty)
        local known = cost[edge.to] or math.huge
        if nextCost < known then
          cost[edge.to] = nextCost
          real[edge.to] = (real[current] or 0) + edge.weight
          cameFrom[edge.to] = { node = current, edge = edge }
          open[edge.to] = true
        end
      end
    end
  end

  if not settled[to] then return nil end

  local nodes, edges = { to }, {}
  local cursor = to
  while cursor ~= from do
    local step = cameFrom[cursor]
    if not step then return nil end
    edges[#edges + 1] = step.edge
    nodes[#nodes + 1] = step.node
    cursor = step.node
  end
  local function Reverse(list)
    local low, high = 1, #list
    while low < high do
      list[low], list[high] = list[high], list[low]
      low, high = low + 1, high - 1
    end
  end
  Reverse(nodes)
  Reverse(edges)
  return { nodes = nodes, edges = edges, seconds = real[to] or 0 }
end
Travel.ShortestPath = ShortestPath

--------------------------------------------------------------------------
-- The plan
--------------------------------------------------------------------------

local function StepOf(from, to, edge)
  local detail = edge.detail
  local step = {
    family = detail.family,
    from = NodeName(from) or from,
    to = NodeName(to) or to,
    fromNode = from,
    toNode = to,
    seconds = edge.weight,
    enemy = false,
  }
  if detail.family == "land" then
    step.what, step.claim, step.caution = detail.crossing, detail.claim, detail.caution
  elseif detail.family == "city" then
    step.what, step.verb = detail.crossing, detail.verb
  elseif detail.family == "ride" then
    step.routeKey, step.what, step.claim = detail.routeKey, detail.note, detail.claim
    step.waitMin, step.waitMax = detail.waitMin, detail.waitMax
    step.enemy = detail.enemy
    step.enemyFaction = detail.enemy and detail.routeFaction or nil
  elseif detail.family == "flight" then
    step.measured = detail.measured
  end
  return step
end

--[[
One found path timed from its real geometry. The graph's weights hop from
one zone center to the next and are scaled for choice, so they only pick the
path; the seconds shown are measured here, leg by leg, from the point the
traveler actually stands on.
]]
local function Retime(path, input, factor)
  local steps, zones = {}, {}
  local startZone = ZoneOf(input.from)
  if startZone then zones[startZone] = true end
  local at = PointOf(input.from) or { x = 0, y = 0 }
  local land, fixed, rideLow, rideHigh, crossings = 0, 0, 0, 0, 0
  local function Leg(to, zoneKey)
    local seconds = WalkSeconds(Distance(at, to), input.speed, zoneKey)
    at = to
    return seconds
  end

  for index, edge in ipairs(path.edges) do
    local from, to = path.nodes[index], path.nodes[index + 1]
    local step = StepOf(from, to, edge)
    local detail = edge.detail
    local toZone = ZoneOf(to)
    local toPoint = PointOf(to) or at
    if detail.family == "land" then
      local fromZone = ZoneOf(from)
      local gate = GATES[tostring(fromZone) .. "|" .. tostring(toZone)] or toPoint
      step.seconds = Leg(gate, fromZone)
      land = land + step.seconds
      if toZone then zones[toZone] = true end
    elseif detail.family == "entry" or detail.family == "walk" then
      if ReadNode(to) == "place" then
        step.seconds = Leg(toPoint, toZone)
        land = land + step.seconds
      else
        step.seconds = 0
        if toZone then zones[toZone] = true end
      end
    elseif detail.family == "flight" then
      step.seconds = edge.weight - M.flightBoard
      fixed = fixed + step.seconds
      at = toPoint
      if toZone then zones[toZone] = true end
    elseif detail.family == "city" then
      local walked = Leg(toPoint, toZone)
      if detail.fixedSeconds ~= nil then
        step.seconds = detail.fixedSeconds
        fixed = fixed + step.seconds
      else
        step.seconds = math.max(M.entryMinimum, walked)
        land = land + step.seconds
      end
    else
      local onBoard = edge.weight - (detail.waitMin + detail.waitMax) / 2
      step.seconds = edge.weight
      rideLow = rideLow + onBoard + detail.waitMin
      rideHigh = rideHigh + onBoard + detail.waitMax
      if ContinentOfZone(ZoneOf(from)) ~= ContinentOfZone(toZone) then crossings = crossings + 1 end
      at = toPoint
      if toZone then zones[toZone] = true end
    end
    -- A place stepping into its own zone costs nothing by itself: the next
    -- step carries the walk, so the two read as one step from the place.
    local previous = steps[#steps]
    if previous and previous.family == "entry" and previous.seconds == 0 and ReadNode(previous.toNode) == "zone" then
      steps[#steps] = nil
      step.from = previous.from
      step.fromNode = previous.fromNode
    end
    steps[#steps + 1] = step
  end

  -- The last stretch, from the last gate to the middle of the zone asked for.
  local endZone = ZoneOf(input.to)
  if endZone then zones[endZone] = true end
  local finish = PointOf(input.to)
  if finish then
    local last = Leg(finish, endZone)
    local lastStep = steps[#steps]
    if lastStep and last > 0 then
      lastStep.seconds = lastStep.seconds + last
      land = land + last
    end
  end

  local other = input.faction == "horde" and "alliance" or "horde"
  local hostile = 0
  for zoneKey in pairs(zones) do
    if ZONES[zoneKey] and ZONES[zoneKey].faction == other then hostile = hostile + 1 end
  end
  local mid = land + fixed + (rideLow + rideHigh) / 2
  return {
    steps = steps,
    band = { low = land * 0.8 + fixed + rideLow, mid = mid, high = land * 1.25 + fixed + rideHigh },
    factor = factor,
    score = mid + hostile * M.enemyZonePenalty + crossings * M.seaPenalty,
  }
end

local function Known(node)
  local kind, key = ReadNode(node)
  if kind == "zone" then return ZONES[key] ~= nil end
  if kind == "place" then return PLACE[key] ~= nil end
  return false
end

local function Closed(node)
  local zoneKey = ZoneOf(node)
  if not zoneKey then return false end
  return ZONES[zoneKey] ~= nil and ZONES[zoneKey].status == "closed"
end

--[[
The plan for one trip, or the refusal that trip earns. input: from, to (node
keys), faction ("alliance" or "horde"), speed (one of Travel.SPEEDS),
flightPaths, skyborne. Answers { ok = true, steps, band, factor,
enemyTransport } or { ok = false, reason, place }, the reason one of
same_place, not_on_map, closed_zone, already_in_zone and no_path.
]]
function Travel.Plan(input)
  if input.from == input.to then
    return { ok = false, reason = "same_place", place = NodeName(input.from) }
  end
  if not Known(input.from) or not Known(input.to) then return { ok = false, reason = "not_on_map" } end
  if Closed(input.from) then return { ok = false, reason = "closed_zone", place = NodeName(input.from) } end
  if Closed(input.to) then return { ok = false, reason = "closed_zone", place = NodeName(input.to) } end
  local toKind, toKey = ReadNode(input.to)
  local fromKind, fromKey = ReadNode(input.from)
  if toKind == "zone" and fromKind == "place" and PLACE[fromKey] and PLACE[fromKey].zone == toKey then
    return { ok = false, reason = "already_in_zone", place = NodeName(input.to) }
  end

  local endpoints = { [input.from] = true, [input.to] = true }
  local function Search(enemyTransport)
    local best, seen = nil, {}
    for _, exits in ipairs({ true, false }) do
      -- The sea penalty does not change the graph, so one graph serves both.
      local graphs = {}
      for _, seaPenalty in ipairs({ true, false }) do
        for index, factor in ipairs(M.landFactors) do
          local graph = graphs[index]
          if not graph then
            graph = BuildGraph({
              faction = input.faction,
              speed = input.speed,
              flightPaths = input.flightPaths,
              skyborne = input.skyborne,
              landWeightFactor = factor,
              enemyTransport = enemyTransport,
              exits = exits,
              endpoints = endpoints,
            })
            graphs[index] = graph
          end
          local path = ShortestPath(graph, input.from, input.to, input.faction, seaPenalty)
          if path then
            local families = {}
            for at, edge in ipairs(path.edges) do families[at] = edge.detail.family end
            local key = table.concat(path.nodes, ">") .. "|" .. table.concat(families, ",")
            if not seen[key] then
              seen[key] = true
              local timed = Retime(path, input, factor)
              if best == nil or timed.score < best.score then best = timed end
            end
          end
        end
      end
    end
    return best
  end

  local friendly = Search(false)
  if friendly then
    return { ok = true, steps = friendly.steps, band = friendly.band, factor = friendly.factor, enemyTransport = false }
  end
  local enemy = Search(true)
  if not enemy then return { ok = false, reason = "no_path" } end
  return { ok = true, steps = enemy.steps, band = enemy.band, factor = enemy.factor, enemyTransport = true }
end

--------------------------------------------------------------------------
-- The words, the site's own
--------------------------------------------------------------------------

--[[ A span of time as the site writes it: whole minutes, never under one
     unless it is nothing at all, and hours from sixty minutes up. ]]
local function Duration(seconds)
  local total = math.max(0, math.floor(seconds + 0.5))
  if total == 0 then return "0 min" end
  local minutes = math.max(1, math.floor(total / 60 + 0.5))
  if minutes < 60 then return minutes .. " min" end
  return math.floor(minutes / 60) .. " h " .. (minutes % 60)
end
Travel.Duration = Duration

local function Unperiod(text)
  if text:sub(-1) == "." then return text:sub(1, -2) end
  return text
end

local function WaitLabel(waitMin, waitMax)
  local low, high = Duration(waitMin), Duration(waitMax)
  local bare = low
  if low:sub(-4) == " min" and high:sub(-4) == " min" then bare = low:sub(1, -5) end
  return "wait " .. bare .. " to " .. high
end

--[[ One step as one line: where from, where to, what the traveler does,
     and how long it takes. ]]
function Travel.StepLine(step)
  local line = step.from .. " to " .. step.to
  if step.verb then line = line .. ", " .. step.verb end
  if step.what then line = line .. ", " .. Unperiod(step.what) end
  local waits = step.waitMin ~= nil and step.waitMax ~= nil
  if waits then line = line .. ", " .. WaitLabel(step.waitMin, step.waitMax) end
  if step.caution then line = line .. ", " .. Unperiod(step.caution) end
  if waits then
    return line .. ", about " .. Duration(step.seconds) .. " in all"
  end
  return line .. ", " .. Duration(step.seconds)
end

function Travel.Estimate(band)
  return "Estimated travel time " .. Duration(band.low) .. " to " .. Duration(band.high)
    .. ", typically " .. Duration(band.mid) .. "."
end

local REFUSALS = {
  same_place = "Pick two different places.",
  not_on_map = "That place is not on this map.",
  closed_zone = "That zone is closed in Forever, so no route can enter it.",
  no_path = "There is no known way between these two places.",
}

function Travel.Refusal(reason, place)
  if reason == "already_in_zone" then return "The starting place is already inside " .. (place or "") .. "." end
  return REFUSALS[reason] or REFUSALS.no_path
end

--------------------------------------------------------------------------
-- In the game
--------------------------------------------------------------------------

local SPEED_LABELS = { foot = "On foot", travel_form = "Travel form", mount_60 = "Mount 60%", mount_100 = "Mount 100%" }
local SPEED_WORDS = {
  foot = "foot", walk = "foot", travel = "travel_form", form = "travel_form",
  ["60"] = "mount_60", mount60 = "mount_60", ["100"] = "mount_100", mount100 = "mount_100", epic = "mount_100",
}

local function Lower(text)
  return (string.lower(text))
end

--[[
The node a name means. An exact name wins, a place before a zone; then a
name that starts with the words; then one that holds them; among several,
the shortest name. Returns the node, or nil.
]]
function Travel.Find(text)
  if type(text) ~= "string" then return nil end
  local wanted = Lower(text):gsub("^%s+", ""):gsub("%s+$", "")
  if wanted == "" then return nil end
  local best, bestRank, bestLength = nil, 9, math.huge
  local function Offer(node, name, bias)
    local lower = Lower(name)
    local rank
    if lower == wanted then
      rank = 1
    elseif lower:sub(1, #wanted) == wanted then
      rank = 3
    elseif lower:find(wanted, 1, true) then
      rank = 5
    else
      return
    end
    rank = rank + bias
    if rank < bestRank or (rank == bestRank and #name < bestLength) then
      best, bestRank, bestLength = node, rank, #name
    end
  end
  for _, place in ipairs(T.PLACES) do Offer(PlaceNode(place.key), place.name, 0) end
  for _, key in ipairs(T.ZONE_ORDER) do Offer(ZoneNode(key), ZONES[key].name, 1) end
  return best
end

--[[ Where the character stands: a capital where the game's map is a city's,
     else the zone. nil where the map is none this planner knows. ]]
function Travel.Here()
  local mapId
  pcall(function()
    if C_Map and C_Map.GetBestMapForUnit then mapId = C_Map.GetBestMapForUnit("player") end
  end)
  if type(mapId) ~= "number" then return nil end
  local city = T.CITY_MAPS[mapId]
  if city and PLACE[city] then return PlaceNode(city) end
  local zone = T.ZONE_MAPS[mapId]
  if zone and ZONES[zone] then return ZoneNode(zone) end
  return nil
end

local function Faction()
  local faction
  pcall(function() faction = UnitFactionGroup("player") end)
  if faction == "Alliance" then return "alliance" end
  if faction == "Horde" then return "horde" end
  return nil
end

local function Skyborne()
  local found = false
  pcall(function()
    local name, file = UnitRace("player")
    for _, value in ipairs({ name, file }) do
      if type(value) == "string" and Lower(value):find("skyborne", 1, true) then found = true end
    end
  end)
  return found
end

local function Speed()
  local db = EW.Database()
  local speed = db.travelSpeed
  if type(speed) ~= "string" or not SPEED_LABELS[speed] then return "foot" end
  return speed
end

--[[ Plans one trip for the character and returns the lines to show: the
     trip, the estimate, and each step. The second value is true where a
     route was found. ]]
function Travel.Lines(from, to)
  local faction = Faction()
  if not faction then return { "The route planner needs a character of the Alliance or the Horde." }, false end
  local speed = Speed()
  local result = Travel.Plan({
    from = from,
    to = to,
    faction = faction,
    speed = speed,
    flightPaths = true,
    skyborne = Skyborne(),
  })
  if not result.ok then return { Travel.Refusal(result.reason, result.place) }, false end
  local lines = {
    (NodeName(from) or from) .. " to " .. (NodeName(to) or to) .. " (" .. SPEED_LABELS[speed] .. ")",
    Travel.Estimate(result.band),
  }
  for index, step in ipairs(result.steps) do lines[#lines + 1] = index .. ". " .. Travel.StepLine(step) end
  return lines, true
end

--[[
/ewow route <place>            from where the character stands
/ewow route <place> > <place>  between two places
/ewow route speed <speed>      foot, travel, 60 or 100
]]
function Travel.Command(rest)
  if EW.VersionKey() ~= "forever" then
    EW.Print("The route planner covers WoW Forever only.")
    return
  end
  rest = type(rest) == "string" and rest or ""
  local word, value = rest:match("^%s*(%S+)%s*(.-)%s*$")
  if word and Lower(word) == "speed" then
    local speed = SPEED_WORDS[Lower(value):gsub("[%s%%]", "")]
    if not speed then
      EW.Print("Speeds: foot, travel, 60, 100. Now: " .. SPEED_LABELS[Speed()] .. ".")
      return
    end
    EW.Database().travelSpeed = speed
    EW.Print("Routes are now timed at: " .. SPEED_LABELS[speed] .. ".")
    return
  end
  local fromText, toText = rest:match("^%s*(.-)%s*>%s*(.-)%s*$")
  local from, to
  if fromText then
    from, to = Travel.Find(fromText), Travel.Find(toText)
  else
    from, to = Travel.Here(), Travel.Find(rest)
    if rest:gsub("%s", "") == "" then
      EW.Print("Usage: /ewow route Booty Bay, or /ewow route Orgrimmar > Undercity. Speed: /ewow route speed 60.")
      return
    end
    if not from then
      EW.Print("The planner does not know the map you are on. Name both places: /ewow route Orgrimmar > Undercity.")
      return
    end
  end
  if not from or not to then
    EW.Print(Travel.Refusal("not_on_map"))
    return
  end
  local lines = Travel.Lines(from, to)
  for _, line in ipairs(lines) do EW.Print(line) end
end
