--[[
The places on the game's own maps: tests, run from tests/run.lua.

tests/fakeworld.lua stands in for the client's maps. In it a zone is a
rectangle on its continent and the world is the continent's map times
10,000, so where a place must come out can be worked out here by hand.
]]

return function(t)
  local check, equal, stub = t.check, t.equal, t.stub
  local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-9 end

  local EW = t.LoadFreshAddon(2, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  local P = EW.Places

  -- With no maps to ask, nothing is placed and nothing breaks.
  equal("with no maps to ask there are no continents", #P.Continents(), 0)
  equal("no place has a spot", P.Spot("orgrimmar", 1414), nil)
  equal("no pictures", P.Tiles(1414), nil)
  P.Forget()

  local world = dofile(t.root .. "tests/fakeworld.lua")(EW)
  local K, E = world.KALIMDOR, world.EASTERN

  -- The continents.
  equal("a zone's continent is the one above it", P.ContinentMap(1411), K)
  equal("a continent is its own", P.ContinentMap(K), K)
  equal("a capital's map is found through its zone", P.ContinentMap(1454), K)
  equal("the world's map has none", P.ContinentMap(world.AZEROTH), nil)
  local continents = P.Continents()
  equal("the planner's zones lie on two continents", #continents, 2)
  equal("the western one first", continents[1].map, K)
  equal("by the client's own name", continents[1].name, "Kalimdor")
  equal("then the eastern", continents[2].name, "Eastern Kingdoms")
  equal("each with the planner's word for it", continents[2].key, "eastern_kingdoms")

  -- A place with a real spot.
  local spot = EW.TRAVEL_COORDS.orgrimmar
  equal("Orgrimmar's spot is given on Durotar's map", spot.zone, "durotar")
  local x, y, estimated = P.Spot("orgrimmar", 1411)
  check("on its own zone's map a place lies where it was given", near(x, spot.x) and near(y, spot.y))
  equal("and that is no estimate", estimated, false)
  local rect = world.rect[1411]
  x, y = P.Spot("orgrimmar", K)
  check("on the continent it lies in the zone's rectangle, as far across and down",
    near(x, rect[1] + spot.x * (rect[3] - rect[1])) and near(y, rect[2] + spot.y * (rect[4] - rect[2])))
  equal("it is not on the other continent", P.Spot("orgrimmar", E), nil)
  local barrens = world.rect[1413]
  local onBarrensX = (x - barrens[1]) / (barrens[3] - barrens[1])
  local bx = P.Spot("orgrimmar", 1413)
  check("on a neighbor zone's map it lies where the world puts it, or off it",
    (onBarrensX < 0 or onBarrensX > 1) and bx == nil or near(bx, onBarrensX))
  equal("a place of the other continent is found there", P.Spot("undercity", E) ~= nil, true)
  equal("a place far off a zone's map is not on it", P.Spot("auberdine", 1411), nil)

  -- A place with only a drawn spot is put by its neighbors.
  equal("Sen'jin Village has no spot of its own", EW.TRAVEL_COORDS["senjin-village"], nil)
  local sx, sy, guessed = P.Spot("senjin-village", K)
  check("it is still put on its continent", sx ~= nil and sy ~= nil)
  equal("as an estimate", guessed, true)
  local rx, ry = P.Spot("razor-hill", K)
  check("near its neighbors of the drawing", rx and math.abs(sx - rx) < 0.2 and math.abs(sy - ry) < 0.2, tostring(sx) .. " " .. tostring(sy))
  equal("a place of no zone is not placed", P.Spot("darkspear-islands", K), nil)
  equal("nor a place that is not the planner's", P.Spot("nowhere", K), nil)

  -- Zones and nodes.
  local zx, zy = P.ZoneSpot("durotar", K)
  check("a zone's middle is the middle of its rectangle", near(zx, (rect[1] + rect[3]) / 2) and near(zy, (rect[2] + rect[4]) / 2))
  equal("on its own map, the middle", select(1, P.ZoneSpot("durotar", 1411)), 0.5)
  equal("a zone with no continent is not on one", P.ZoneSpot("zephras", K), nil)
  local nx = P.NodeSpot("place:orgrimmar", K)
  check("a place's node is the place", near(nx, x))
  check("a zone's node is the zone's middle", near(P.NodeSpot("zone:durotar", K), zx))
  equal("anything else is nowhere", P.NodeSpot("orgrimmar", K), nil)

  -- The character.
  local px, py = P.Player(K)
  check("the character is where the client says", near(px, 0.61) and near(py, 0.44))
  equal("and nowhere on a map it is not on", P.Player(E), nil)
  stub.state.map = 1454
  equal("its continent is its map's", P.PlayerContinent(), K)
  rawset(_G, "issecretvalue", function(value) return value == 0.61 end)
  equal("a spot the client holds back is no spot", P.Player(K), nil)
  rawset(_G, "issecretvalue", nil)

  -- The pictures.
  local tiles, aspect = P.Tiles(K)
  equal("a continent's map is twelve pictures", #tiles, 12)
  check("three across for every two down", near(aspect, 1002 / 668))
  check("the first in the corner, a tile wide and high", tiles[1].left == 0 and tiles[1].top == 0 and near(tiles[1].width, 256 / 1002) and near(tiles[1].height, 256 / 668))
  check("four to a row: the fifth starts the second row", tiles[5].left == 0 and near(tiles[5].top, 256 / 668))
  check("the fourth runs past the right edge, as the client's own does", tiles[4].left + tiles[4].width > 1)
  equal("each is the client's own file", tiles[7].file, K * 100 + 7)
  world.files = 11
  equal("a count that does not fill the rows is refused", P.Tiles(K), nil)
  world.files = 12
  equal("a zone's map has none here", P.Tiles(1411), nil)

  world.Remove()
  P.Forget()
  stub.state.map = nil
end
