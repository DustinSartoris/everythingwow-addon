--[[
Where the planner's places lie on the game's own maps.

The site's map is a drawing: its places stand where the drawing puts them,
which is not where the game's map has them. To show a place on the real
map, the addon needs the place as the game knows it. TravelCoords.lua holds
that for most places: the zone, and how far across and down that zone's own
map the place lies. From there the client itself says where the place is on
any other map, a continent's or a neighbor zone's: the zone's spot is turned
into a spot in the world, and the spot in the world into a spot on the map
that is shown.

A place with no such entry has only its drawn spot. It is put on the real
map by its neighbors: the nearest place of its continent that has a real
spot, moved by as much as the drawing moves, at the scale the drawing and
the real map have between them on that continent. Such a spot is marked as
an estimate.

Everything here asks the client and nothing is saved. Where the client
lacks a call, or answers with a value it will not let an addon read, the
answer is nil and the caller draws nothing there.
]]

local ADDON_NAME, EW = ...

local Places = {}
EW.Places = Places

local T = EW.TRAVEL
local COORDS = EW.TRAVEL_COORDS or {}

local PLACE = {}
if T then
  for _, place in ipairs(T.PLACES) do PLACE[place.key] = place end
end

-- The game's number for each zone's map, from the planner's own table the
-- other way round.
local ZONE_MAP = {}
if T then
  for mapId, key in pairs(T.ZONE_MAPS) do ZONE_MAP[key] = mapId end
end

--[[ True where the client holds a value back from addons. ]]
local function Hidden(value)
  local hidden = false
  pcall(function()
    if type(issecretvalue) == "function" and issecretvalue(value) then hidden = true end
  end)
  return hidden
end

local function Number(value)
  if Hidden(value) or type(value) ~= "number" then return nil end
  if value ~= value then return nil end
  return value
end

--[[ The two numbers of one of the client's points, or nil. ]]
local function XY(point)
  local x, y
  pcall(function() x, y = point:GetXY() end)
  x, y = Number(x), Number(y)
  if not x or not y then return nil end
  return x, y
end

local function Vector(x, y)
  local vector
  pcall(function() vector = CreateVector2D(x, y) end)
  return vector
end

--[[ A spot on one map as a spot in the world: the continent the client
     counts it on, and the client's own point. ]]
local function ToWorld(mapId, x, y)
  local vector = Vector(x, y)
  if not vector then return nil end
  local continent, world
  pcall(function() continent, world = C_Map.GetWorldPosFromMapPos(mapId, vector) end)
  if Number(continent) == nil or world == nil or not XY(world) then return nil end
  return continent, world
end

--[[ A spot in the world as a spot on a map, which may lie off the map. ]]
local function FromWorld(continent, world, mapId)
  local point
  pcall(function()
    local _, found = C_Map.GetMapPosFromWorldPos(continent, world, mapId)
    point = found
  end)
  if not point then return nil end
  return XY(point)
end

local mapInfo = {}
local function MapInfo(mapId)
  if mapInfo[mapId] == nil then
    local info
    pcall(function() info = C_Map.GetMapInfo(mapId) end)
    mapInfo[mapId] = type(info) == "table" and info or false
  end
  return mapInfo[mapId] or nil
end

--[[ The map of the continent a map belongs to: its own number where it is
     a continent's, else the first continent above it. ]]
local continentOf = {}
function Places.ContinentMap(mapId)
  if type(mapId) ~= "number" then return nil end
  if continentOf[mapId] ~= nil then return continentOf[mapId] or nil end
  local found, at = false, mapId
  for _ = 1, 6 do
    local info = MapInfo(at)
    if not info then break end
    if info.mapType == 2 then
      found = at
      break
    end
    if type(info.parentMapID) ~= "number" or info.parentMapID == 0 then break end
    at = info.parentMapID
  end
  continentOf[mapId] = found
  return found or nil
end

function Places.ZoneMap(zoneKey)
  return ZONE_MAP[zoneKey]
end

--[[ The continents the planner's zones lie on, west first: a list of
     { map, key, name }, where key is the planner's word for it. ]]
local continents
function Places.Continents()
  if continents then return continents end
  local found, seen = {}, {}
  if T then
    for _, zoneKey in ipairs(T.ZONE_ORDER) do
      local zone = T.ZONES[zoneKey]
      local map = ZONE_MAP[zoneKey] and Places.ContinentMap(ZONE_MAP[zoneKey])
      if map and not seen[map] then
        seen[map] = true
        local info = MapInfo(map)
        found[#found + 1] = { map = map, key = zone.continent, name = (info and info.name) or zone.continent }
      end
    end
  end
  if #found > 0 then continents = found end
  return found
end

--[[ The continent map of one of the planner's words for a continent. ]]
local function ContinentByKey(key)
  for _, continent in ipairs(Places.Continents()) do
    if continent.key == key then return continent.map end
  end
  return nil
end

--------------------------------------------------------------------------
-- A place in the world
--------------------------------------------------------------------------

-- { continent, world, estimated } for each place asked about, false where
-- the client could not say.
local worldOf = {}

-- For each continent map: the places with a real spot, each as
-- { drawn x, drawn y, real x, real y } on the continent's map, and the
-- scale between the drawing and the real map along each axis.
local fits = {}

local function KnownWorld(key)
  local spot = COORDS[key]
  local map = spot and ZONE_MAP[spot.zone]
  if not map then return nil end
  return ToWorld(map, spot.x, spot.y)
end

--[[ The slope of the line through the pairs, least squares, or nil. ]]
local function Slope(pairsList, from, to)
  local count = #pairsList
  if count < 2 then return nil end
  local sumX, sumY = 0, 0
  for _, pair in ipairs(pairsList) do
    sumX, sumY = sumX + pair[from], sumY + pair[to]
  end
  local meanX, meanY = sumX / count, sumY / count
  local over, under = 0, 0
  for _, pair in ipairs(pairsList) do
    over = over + (pair[from] - meanX) * (pair[to] - meanY)
    under = under + (pair[from] - meanX) * (pair[from] - meanX)
  end
  if under <= 0 then return nil end
  return over / under
end

local function Fit(continentMap)
  if fits[continentMap] ~= nil then return fits[continentMap] or nil end
  local known = {}
  for key in pairs(COORDS) do
    local place = PLACE[key]
    local map = place and ZONE_MAP[COORDS[key].zone]
    if place and map and Places.ContinentMap(map) == continentMap then
      local continent, world = KnownWorld(key)
      if continent then
        local x, y = FromWorld(continent, world, continentMap)
        if x then known[#known + 1] = { place.x, place.y, x, y } end
      end
    end
  end
  local scaleX, scaleY = Slope(known, 1, 3), Slope(known, 2, 4)
  local fit = false
  if scaleX and scaleY and scaleX > 0 and scaleY > 0 then
    fit = { known = known, scaleX = scaleX, scaleY = scaleY }
  end
  fits[continentMap] = fit
  return fit or nil
end

--[[ A place with only a drawn spot, put on its continent by its nearest
     neighbor with a real one. ]]
local function EstimatedWorld(key)
  local place = PLACE[key]
  local zone = place and place.zone and T.ZONES[place.zone]
  if not zone then return nil end
  local continentMap = ContinentByKey(zone.continent)
  local fit = continentMap and Fit(continentMap)
  if not fit then return nil end
  local nearest, nearestDistance
  for _, known in ipairs(fit.known) do
    local dx, dy = known[1] - place.x, known[2] - place.y
    local distance = dx * dx + dy * dy
    if not nearestDistance or distance < nearestDistance then nearest, nearestDistance = known, distance end
  end
  if not nearest then return nil end
  local x = nearest[3] + (place.x - nearest[1]) * fit.scaleX
  local y = nearest[4] + (place.y - nearest[2]) * fit.scaleY
  return ToWorld(continentMap, x, y)
end

--[[ Where a place is in the world: the continent, the client's point, and
     true where it is an estimate. Nil where it cannot be said. ]]
function Places.World(key)
  local cached = worldOf[key]
  if cached == nil then
    local continent, world = KnownWorld(key)
    local estimated = false
    if not continent and not COORDS[key] then
      continent, world = EstimatedWorld(key)
      estimated = true
    end
    cached = continent and { continent, world, estimated } or false
    worldOf[key] = cached
  end
  if not cached then return nil end
  return cached[1], cached[2], cached[3]
end

--[[ Where a place lies on a map, each from 0 to 1, and whether that is an
     estimate. Nil where the place is not on that map. ]]
function Places.Spot(key, mapId)
  local continent, world, estimated = Places.World(key)
  if not continent then return nil end
  local x, y = FromWorld(continent, world, mapId)
  if not x or x < 0 or x > 1 or y < 0 or y > 1 then return nil end
  return x, y, estimated
end

--[[ The middle of a zone on a map: of the zone's own map, as the client
     places it. ]]
function Places.ZoneSpot(zoneKey, mapId)
  local map = ZONE_MAP[zoneKey]
  if not map then return nil end
  if map == mapId then return 0.5, 0.5 end
  local continent, world = ToWorld(map, 0.5, 0.5)
  if not continent then return nil end
  local x, y = FromWorld(continent, world, mapId)
  if not x or x < 0 or x > 1 or y < 0 or y > 1 then return nil end
  return x, y
end

--[[ Where one of the planner's nodes lies on a map. ]]
function Places.NodeSpot(node, mapId)
  if type(node) ~= "string" then return nil end
  local kind, key = node:match("^(%a+):(.+)$")
  if kind == "place" then return Places.Spot(key, mapId) end
  if kind == "zone" then return Places.ZoneSpot(key, mapId) end
  return nil
end

--[[ Where the character stands on a map, or nil where the client will not
     say, as inside an instance. ]]
function Places.Player(mapId)
  local point
  pcall(function() point = C_Map.GetPlayerMapPosition(mapId, "player") end)
  if not point then return nil end
  local x, y = XY(point)
  if not x or x < 0 or x > 1 or y < 0 or y > 1 then return nil end
  if x == 0 and y == 0 then return nil end
  return x, y
end

--[[ The continent map the character is on, by the map the client says is
     the character's best. ]]
function Places.PlayerContinent()
  local mapId
  pcall(function() mapId = C_Map.GetBestMapForUnit("player") end)
  mapId = Number(mapId)
  if not mapId then return nil end
  return Places.ContinentMap(mapId)
end

--[[
The pictures a map is made of, as the client lays them out: a list of
{ file, left, top, width, height }, each as a part of the whole map from 0
to 1, the last row and column running past the edge as the client's own do.
Nil where the client gives none.
]]
function Places.Tiles(mapId)
  local layers, files
  pcall(function()
    layers = C_Map.GetMapArtLayers(mapId)
    files = C_Map.GetMapArtLayerTextures(mapId, 1)
  end)
  local layer = type(layers) == "table" and layers[1] or nil
  if type(layer) ~= "table" or type(files) ~= "table" or #files == 0 then return nil end
  local width, height = Number(layer.layerWidth), Number(layer.layerHeight)
  local tileWidth, tileHeight = Number(layer.tileWidth), Number(layer.tileHeight)
  if not width or not height or not tileWidth or not tileHeight then return nil end
  if width <= 0 or height <= 0 or tileWidth <= 0 or tileHeight <= 0 then return nil end
  local columns, rows = math.ceil(width / tileWidth), math.ceil(height / tileHeight)
  if columns * rows ~= #files then return nil end
  local tiles = {}
  for index, file in ipairs(files) do
    local column, row = (index - 1) % columns, math.floor((index - 1) / columns)
    tiles[index] = {
      file = file,
      left = column * tileWidth / width,
      top = row * tileHeight / height,
      width = tileWidth / width,
      height = tileHeight / height,
    }
  end
  return tiles, width / height
end

--[[ For the tests: forget what the client said before. ]]
function Places.Forget()
  mapInfo, continentOf, continents, worldOf, fits = {}, {}, nil, {}, {}
end
