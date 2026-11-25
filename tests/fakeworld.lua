--[[
A stand in for the client's maps, for the tests.

Two continents, each with the pictures of a map 1002 by 668 cut into tiles
of 256, and every zone of the planner as a rectangle on its continent, taken
from where the site's drawing has the zone. A spot on a zone's map is a spot
in that rectangle, and the world is the continent's map times 10,000, so the
answers can be worked out by hand.

Install(EW) puts the calls on the client's C_Map and returns the world, with
Remove() to take them off again.
]]

return function(EW)
  local T, M = EW.TRAVEL, EW.TRAVEL_MAP
  local world = { KALIMDOR = 1414, EASTERN = 1415, AZEROTH = 947 }
  local continentMap = { kalimdor = world.KALIMDOR, eastern_kingdoms = world.EASTERN }
  local continentId = { [world.KALIMDOR] = 1, [world.EASTERN] = 0 }
  local zoneMap = {}
  for mapId, key in pairs(T.ZONE_MAPS) do zoneMap[key] = mapId end

  -- Each continent's extent in the drawing, and each zone's rectangle on it.
  local extent = {}
  local box = {}
  for key, rings in pairs(M.OUTLINES) do
    local continent = continentMap[T.ZONES[key].continent]
    local own = { math.huge, math.huge, -math.huge, -math.huge }
    for _, ring in ipairs(rings) do
      for index = 1, #ring, 2 do
        own[1], own[2] = math.min(own[1], ring[index]), math.min(own[2], ring[index + 1])
        own[3], own[4] = math.max(own[3], ring[index]), math.max(own[4], ring[index + 1])
      end
    end
    box[key] = own
    if continent then
      local whole = extent[continent] or { math.huge, math.huge, -math.huge, -math.huge }
      whole[1], whole[2] = math.min(whole[1], own[1]), math.min(whole[2], own[2])
      whole[3], whole[4] = math.max(whole[3], own[3]), math.max(whole[4], own[4])
      extent[continent] = whole
    end
  end
  world.rect = {}
  for key, own in pairs(box) do
    local continent = continentMap[T.ZONES[key].continent]
    if continent and zoneMap[key] then
      local whole = extent[continent]
      local function across(value) return 0.2 + 0.6 * (value - whole[1]) / (whole[3] - whole[1]) end
      local function down(value) return 0.05 + 0.9 * (value - whole[2]) / (whole[4] - whole[2]) end
      world.rect[zoneMap[key]] = { across(own[1]), down(own[2]), across(own[3]), down(own[4]), continent = continent }
    end
  end

  local function Vector(x, y)
    return { x = x, y = y, GetXY = function(self) return self.x, self.y end }
  end
  world.Vector = Vector
  world.player = { [world.KALIMDOR] = { 0.61, 0.44 } }
  world.names = { [world.KALIMDOR] = "Kalimdor", [world.EASTERN] = "Eastern Kingdoms" }
  world.files = 12

  local calls = {}
  function calls.GetMapInfo(mapId)
    if continentId[mapId] then return { mapID = mapId, mapType = 2, parentMapID = world.AZEROTH, name = world.names[mapId] } end
    if mapId == world.AZEROTH then return { mapID = mapId, mapType = 1, parentMapID = 946, name = "Azeroth" } end
    if world.rect[mapId] then return { mapID = mapId, mapType = 3, parentMapID = world.rect[mapId].continent, name = T.ZONES[T.ZONE_MAPS[mapId]].name } end
    local city = T.CITY_MAPS[mapId]
    if city then
      for _, place in ipairs(T.PLACES) do
        if place.key == city then return { mapID = mapId, mapType = 3, parentMapID = zoneMap[place.zone], name = place.name } end
      end
    end
    if T.ZONE_MAPS[mapId] then return { mapID = mapId, mapType = 3, parentMapID = world.AZEROTH, name = T.ZONES[T.ZONE_MAPS[mapId]].name } end
    return nil
  end
  function calls.GetWorldPosFromMapPos(mapId, vector)
    local x, y = vector:GetXY()
    if continentId[mapId] then return continentId[mapId], Vector(x * 10000, y * 10000) end
    local rect = world.rect[mapId]
    if not rect then return nil end
    return continentId[rect.continent], Vector((rect[1] + x * (rect[3] - rect[1])) * 10000, (rect[2] + y * (rect[4] - rect[2])) * 10000)
  end
  function calls.GetMapPosFromWorldPos(continent, vector, mapId)
    local x, y = vector:GetXY()
    x, y = x / 10000, y / 10000
    if continentId[mapId] then
      if continentId[mapId] ~= continent then return nil end
      return mapId, Vector(x, y)
    end
    local rect = world.rect[mapId]
    if not rect or continentId[rect.continent] ~= continent then return nil end
    return mapId, Vector((x - rect[1]) / (rect[3] - rect[1]), (y - rect[2]) / (rect[4] - rect[2]))
  end
  function calls.GetMapArtLayers(mapId)
    if not continentId[mapId] then return nil end
    return { { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256 } }
  end
  function calls.GetMapArtLayerTextures(mapId, layer)
    if not continentId[mapId] or layer ~= 1 then return nil end
    local files = {}
    for index = 1, world.files do files[index] = mapId * 100 + index end
    return files
  end
  function calls.GetPlayerMapPosition(mapId, unit)
    local spot = unit == "player" and world.player[mapId]
    if not spot then return nil end
    return Vector(spot[1], spot[2])
  end

  local saved = {}
  for name, call in pairs(calls) do
    saved[name] = rawget(_G.C_Map, name)
    _G.C_Map[name] = call
  end
  local savedVector = rawget(_G, "CreateVector2D")
  rawset(_G, "CreateVector2D", Vector)

  function world.Remove()
    for name in pairs(calls) do _G.C_Map[name] = saved[name] end
    rawset(_G, "CreateVector2D", savedVector)
  end
  return world
end
