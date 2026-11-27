--[[
The tests of the world map's dots and the tracker, run from tests/run.lua.

The client's frames are stood in for as in tests/window.lua, and the world
map by a frame with a canvas of a known size and scale, which says which
map it shows and can be told that the map has changed. tests/fakeworld.lua
stands in for the client's maps. The tracker is tried first on a client
with no world map at all, which must lose nothing but the dots.
]]

return function(t)
  local check, equal, stub = t.check, t.equal, t.stub
  local FOREVER = { "1.60.1", "70000", "Nov 4 2026", 16001 }
  local function near(a, b) return type(a) == "number" and type(b) == "number" and math.abs(a - b) < 1e-6 end

  local function MockFrame(kind, name, parent)
    local mock = { shown = true, scripts = {}, hooks = {}, kind = kind, name = name, parent = parent }
    return setmetatable(mock, { __index = function(_, key)
      if type(key) ~= "string" or not key:match("^%u") then return nil end
      if key == "SetText" then return function(self, text) self.text = text end end
      if key == "GetText" then return function(self) return self.text end end
      if key == "Show" then return function(self) self.shown = true end end
      if key == "Hide" then return function(self) self.shown = false end end
      if key == "IsShown" then return function(self) return self.shown end end
      if key == "SetScript" then return function(self, which, handler) self.scripts[which] = handler end end
      if key == "HookScript" then return function(self, which, handler) self.hooks[which] = handler end end
      if key == "SetPoint" then return function(self, ...) self.point = { ... } end end
      if key == "GetPoint" then return function(self) return (table.unpack or unpack)(self.point or {}) end end
      if key == "SetTexture" then return function(self, texture) self.texture = texture end end
      if key == "SetSize" then return function(self, width, height) self.size = { width, height } end end
      if key == "SetHeight" then return function(self, height) self.height = height end end
      if key == "GetWidth" then return function(self) return self.width end end
      if key == "GetHeight" then return function(self) return self.height end end
      if key == "GetScale" then return function(self) return self.scale end end
      if key == "SetFrameLevel" then return function(self, level) self.level = level end end
      if key == "GetFrameLevel" then return function(self) return self.level or 1 end end
      if key == "SetVertexColor" then return function(self, ...) self.color = { ... } end end
      if key == "SetTextColor" then return function(self, ...) self.textColor = { ... } end end
      if key == "SetThickness" then return function(self, thickness) self.thickness = thickness end end
      if key == "SetStartPoint" then return function(self, ...) self.startPoint = { ... } end end
      if key == "SetEndPoint" then return function(self, ...) self.endPoint = { ... } end end
      if key == "CreateFontString" or key == "CreateTexture" then
        return function() return MockFrame("Region") end
      end
      if key == "CreateLine" then
        if rawget(_G, "EW_TEST_NO_LINES") then return nil end
        return function() return MockFrame("Line") end
      end
      return function() end
    end })
  end

  local saved = {}
  for _, name in ipairs({ "CreateFrame", "UIParent", "Minimap", "WorldMapFrame", "hooksecurefunc", "UnitOnTaxi" }) do
    saved[name] = rawget(_G, name)
  end
  local realCreateFrame = saved.CreateFrame
  _G.CreateFrame = function(kind, name, parent, ...)
    if kind == "Frame" and name == "EverythingWoWFrame" then return realCreateFrame(kind, name, parent, ...) end
    return MockFrame(kind, name, parent)
  end
  rawset(_G, "Minimap", MockFrame("Minimap"))
  rawset(_G, "UIParent", MockFrame("Frame", "UIParent"))
  rawset(_G, "WorldMapFrame", nil)
  rawset(_G, "hooksecurefunc", function(target, name, hook)
    local original = target[name]
    if type(original) ~= "function" then error("hooksecurefunc: no such function") end
    rawset(target, name, function(...)
      original(...)
      hook(...)
    end)
  end)
  local onTaxi = false
  rawset(_G, "UnitOnTaxi", function(unit) return unit == "player" and onTaxi end)

  --------------------------------------------------------------------
  -- A client with no world map: the tracker and the trip that follows.
  --------------------------------------------------------------------
  local bare = t.LoadFreshAddon(2, FOREVER)
  bare.TRACKER_ROWS = 2
  local world = dofile(t.root .. "tests/fakeworld.lua")(bare)
  local zoneMap = {}
  for mapId, key in pairs(bare.TRAVEL.ZONE_MAPS) do zoneMap[key] = mapId end
  local ORGRIMMAR, UNDERCITY = 1454, 1458
  stub.state.map = ORGRIMMAR
  stub.state.printed = {}

  equal("with no world map there is nothing to lay the dots on", bare.WorldMapStart(), false)
  equal("and no sheet is made", bare.worldMapLayer, nil)
  equal("on WoW Forever the trip is followed", bare.TRIP_FOLLOWING, true)
  equal("a trip from an empty From starts where the character stands", bare.RouteAnswer("", "Undercity").here, true)
  equal("a trip from a named place does not", bare.RouteAnswer("Orgrimmar", "Undercity").here, false)
  equal("no trip, no tracker", bare.RefreshTracker(), false)
  equal("none is built for nothing", bare.tracker, nil)

  bare.WindowPick("place:undercity", "LeftButton")
  local tracker = bare.tracker
  check("a planned trip builds the tracker", tracker ~= nil, bare.trackerError)
  equal("and shows it", tracker:IsShown(), true)
  equal("named as the client can find it", tracker.name, "EverythingWoWTracker")
  equal("its heading is the trip", tracker.title.text, "Orgrimmar to Undercity (On foot)")
  check("the estimate is under it", tracker.estimate.text:find("^Estimated travel time ") ~= nil, tracker.estimate.text)
  check("the first row is the first step", tracker.rows[1].text:find("^1%. Orgrimmar to ") ~= nil, tracker.rows[1].text)
  equal("which stands out in white", tracker.rows[1].textColor[1], 1)
  check("the steps after it are grayer", tracker.rows[2].textColor[1] < 1)
  equal("it has a row for each of its steps to show", #tracker.rows, bare.TRACKER_ROWS)
  local steps = #bare.trip.steps
  check("this trip has more steps than the tracker has rows", steps > bare.TRACKER_ROWS, steps)
  equal("by one", steps - bare.TRACKER_ROWS, 1)
  equal("so the last line says there is one more", tracker.more.text, "and 1 more step")
  equal("and is shown", tracker.more:IsShown(), true)
  bare.WindowPick("place:stormwind", "LeftButton")
  local longer = #bare.trip.steps - bare.TRACKER_ROWS
  check("a longer trip has several more", longer > 1, longer)
  equal("and says how many", tracker.more.text, string.format("and %d more steps", longer))
  bare.WindowPick("place:undercity", "LeftButton")
  check("it opens on the left of the screen", tracker.point[1] == "LEFT" and tracker.point[3] == "LEFT")
  equal("it prints nothing", #stub.state.printed, 0)

  -- A short trip fills only the rows it needs.
  stub.state.map = zoneMap.durotar
  bare.WindowPick("place:razor-hill", "LeftButton")
  equal("a short trip is all in the rows", tracker.more:IsShown(), false)
  equal("the rows past its last step are put away", tracker.rows[#bare.trip.steps + 1]:IsShown(), false)
  equal("its first row is shown", tracker.rows[1]:IsShown(), true)
  stub.state.map = ORGRIMMAR
  bare.WindowPick("place:undercity", "LeftButton")

  -- Its two buttons.
  equal("the window has not been opened yet", bare.window, nil)
  tracker.open.scripts.OnClick(tracker.open)
  check("the Map button opens the window", bare.window ~= nil and bare.window:IsShown())
  equal("on the trip in hand", bare.window.heading.text, "Orgrimmar to Undercity (On foot)")
  equal("with the picked place in its box", bare.window.to.text, "Undercity")
  tracker.close.scripts.OnClick(tracker.close)
  equal("the cross ends the trip", bare.trip, nil)
  equal("and puts the tracker away", tracker:IsShown(), false)
  equal("the window goes back to asking where to", bare.window.heading.text, "Where to?")

  -- Dragging it.
  bare.WindowPick("place:undercity", "LeftButton")
  equal("the next trip shows it again", tracker:IsShown(), true)
  tracker.point = { "TOPRIGHT", _G.UIParent, "TOPRIGHT", -120.4, -200.6 }
  tracker.scripts.OnDragStop(tracker)
  local spot = bare.Database().trackerSpot
  check("where it was dropped is saved in whole numbers",
    spot and spot[1] == "TOPRIGHT" and spot[2] == "TOPRIGHT" and spot[3] == -120 and spot[4] == -201,
    spot and table.concat(spot, " "))
  tracker.point = { "NOWHERE", _G.UIParent, "TOPRIGHT", 5, 5 }
  tracker.scripts.OnDragStop(tracker)
  equal("a spot the client gives no sound name for is not saved", bare.Database().trackerSpot[1], "TOPRIGHT")

  -- /ewow tracker.
  stub.state.printed = {}
  bare.SlashCommand("tracker")
  equal("/ewow tracker hides it", tracker:IsShown(), false)
  equal("and says how to bring it back", stub.state.printed[#stub.state.printed]:find("/ewow tracker shows it again", 1, true) ~= nil, true)
  check("the trip is still in hand", bare.trip ~= nil and bare.trip.ok)
  bare.WindowPick("place:thunderbluff", "LeftButton")
  equal("a new trip does not bring a hidden tracker back", tracker:IsShown(), false)
  bare.SlashCommand("tracker")
  equal("/ewow tracker again shows it", tracker:IsShown(), true)
  equal("with the trip in hand", tracker.title.text, "Orgrimmar to Thunder Bluff (On foot)")
  check("and says so", stub.state.printed[#stub.state.printed]:find("The route tracker is shown.", 1, true) ~= nil)

  -- The trip follows the character.
  bare.WindowPick("place:undercity", "LeftButton")
  equal("standing where the trip began changes nothing", bare.TripFollow(), nil)
  equal("the trip starts in the city", bare.trip.from, "place:orgrimmar")
  stub.state.map = zoneMap.durotar
  equal("in a new zone the trip is planned again", bare.TripFollow(), "replanned")
  equal("from that zone", bare.trip.from, "zone:durotar")
  equal("to the same place", bare.trip.to, "place:undercity")
  equal("and the tracker says so", tracker.title.text, "Durotar to Undercity (On foot)")
  equal("it still starts where the character stands", bare.trip.here, true)
  equal("a second look in the same zone changes nothing", bare.TripFollow(), nil)
  onTaxi = true
  stub.state.map = zoneMap.barrens
  equal("in the air the zone below is not where the trip stands", bare.TripFollow(), nil)
  equal("so the trip is left as it was", bare.trip.from, "zone:durotar")
  onTaxi = false
  stub.state.map = nil
  equal("on a map the planner does not know the trip is kept", bare.TripFollow(), nil)
  equal("as it was", bare.trip.from, "zone:durotar")
  stub.state.map = zoneMap.tirisfal
  local realAnswer = bare.RouteAnswer
  bare.RouteAnswer = function() return { ok = false, message = "no way" } end
  equal("where no way on can be planned the steps in hand are kept", bare.TripFollow(), nil)
  equal("unchanged", bare.trip.from, "zone:durotar")
  bare.RouteAnswer = realAnswer
  equal("in the last zone it is planned again", bare.TripFollow(), "replanned")
  equal("from there", bare.trip.from, "zone:tirisfal")
  stub.state.printed = {}
  stub.state.map = UNDERCITY
  equal("in the city the trip was going to, it has arrived", bare.TripFollow(), "arrived")
  equal("the trip is ended", bare.trip, nil)
  equal("the tracker is put away", tracker:IsShown(), false)
  equal("and a line in chat says so", stub.state.printed[#stub.state.printed]:find("You have arrived at Undercity.", 1, true) ~= nil, true)
  equal("with no trip there is nothing to follow", bare.TripFollow(), nil)

  -- A zone is reached by reaching any place in it.
  stub.state.map = ORGRIMMAR
  bare.WindowPick("zone:tirisfal", "LeftButton")
  check("a trip to a zone is planned", bare.trip and bare.trip.ok, bare.trip and bare.trip.message)
  stub.state.map = UNDERCITY
  equal("a city of that zone is in that zone", bare.TripFollow(), "arrived")

  -- A place with no map of its own is reached by standing near it.
  stub.state.map = zoneMap.barrens
  bare.WindowPick("place:ratchet", "LeftButton")
  equal("a trip to a town of the zone the character is in", bare.trip.title, "The Barrens to Ratchet (On foot)")
  world.player[zoneMap.barrens] = { 0.2, 0.8 }
  equal("far from it the trip goes on", bare.TripFollow(), nil)
  local coords = bare.TRAVEL_COORDS.ratchet
  world.player[zoneMap.barrens] = { coords.x + 0.01, coords.y - 0.01 }
  equal("near it the trip has arrived", bare.TripFollow(), "arrived")
  world.player[zoneMap.barrens] = nil

  -- A trip told where to start does not follow.
  stub.state.map = ORGRIMMAR
  bare.WindowPick("place:undercity", "LeftButton")
  bare.WindowPick("place:thunderbluff", "RightButton")
  equal("a picked start is not where the character stands", bare.trip.here, false)
  stub.state.map = zoneMap.durotar
  equal("so the trip does not follow the character", bare.TripFollow(), nil)
  equal("and keeps its start", bare.trip.from, "place:thunderbluff")
  bare.WindowClear()

  -- /ewow pins with no world map changes the setting and breaks nothing.
  stub.state.printed = {}
  bare.SlashCommand("pins")
  equal("/ewow pins is kept with no world map to draw on", bare.Database().worldMapOn, true)
  bare.SlashCommand("pins")
  equal("and undone the same way", bare.Database().worldMapOn, nil)
  equal("each says what it did", #stub.state.printed, 2)

  --------------------------------------------------------------------
  -- The world map.
  --------------------------------------------------------------------
  local function MakeWorldMap()
    local canvas = MockFrame("Frame", "Canvas")
    canvas.width, canvas.height, canvas.scale, canvas.level = 1002, 668, 1, 40
    local frame = MockFrame("Frame", "WorldMapFrame")
    rawset(frame, "GetCanvas", function() return canvas end)
    rawset(frame, "GetMapID", function(self) return self.mapId end)
    rawset(frame, "OnMapChanged", function() end)
    return frame, canvas
  end
  local worldMap, canvas = MakeWorldMap()
  local asked = {}
  local levels = {
    PIN_FRAME_LEVEL_AREA_POI = 300, PIN_FRAME_LEVEL_FLIGHT_POINT = 320,
    PIN_FRAME_LEVEL_DUNGEON_ENTRANCE = 310, PIN_FRAME_LEVEL_GROUP_MEMBER = 900,
  }
  rawset(worldMap, "GetPinFrameLevelsManager", function()
    return { GetValidFrameLevel = function(_, name) asked[#asked + 1] = name return levels[name] end }
  end)
  rawset(_G, "WorldMapFrame", worldMap)
  stub.state.map = ORGRIMMAR
  world.player[world.KALIMDOR] = { 0.61, 0.44 }

  local mapped = t.LoadFreshAddon(2, FOREVER)
  local layer = mapped.worldMapLayer
  check("with a world map the sheet is laid as the addon loads", layer ~= nil, mapped.worldMapError)
  equal("asking again makes no second sheet", mapped.WorldMapStart(), true)
  equal("still the one", mapped.worldMapLayer, layer)
  equal("it lies on the map's own canvas", layer.parent, canvas)
  equal("named as the client can find it", layer.name, "EverythingWoWWorldMapLayer")
  equal("over the map's own flight points", layer.level, 321)
  equal("with no map shown yet there are no dots", layer.pinsShown, 0)

  local P, T = mapped.Places, mapped.TRAVEL
  local styles = mapped.PIN_STYLES
  local function Expected(mapId, kinds)
    local count, first = 0, nil
    for _, place in ipairs(T.PLACES) do
      local x, y = P.Spot(place.key, mapId)
      if x and (not kinds or kinds[place.kind]) then
        count = count + 1
        first = first or { place = place, x = x, y = y }
      end
    end
    return count, first
  end
  local function PinOf(key)
    for _, pin in ipairs(layer.pins) do
      if pin:IsShown() and pin.place == key then return pin end
    end
    return nil
  end
  local function Shown()
    local count = 0
    for _, pin in ipairs(layer.pins) do
      if pin:IsShown() then count = count + 1 end
    end
    return count
  end

  -- The game's own map is left alone until the player asks.
  worldMap.mapId = zoneMap.durotar
  worldMap:OnMapChanged()
  equal("the sheet follows the map", layer.mapId, zoneMap.durotar)
  equal("but a new player's world map has no marks on it", layer.pinsShown, 0)
  equal("and the window's button would say so", mapped.WorldMapDotsLabel(), "World Map Dots: Off")
  stub.state.printed = {}
  mapped.SlashCommand("pins")
  equal("/ewow pins puts the places on it", mapped.Database().worldMapOn, true)
  check("and says how to use them", stub.state.printed[1]:find("Click one to start a route there, then click where to go.", 1, true) ~= nil)

  -- A zone's map shows every place in it.
  worldMap:OnMapChanged()
  equal("the map says it has changed and the sheet is drawn for it", layer.mapId, zoneMap.durotar)
  local durotarCount, durotarFirst = Expected(zoneMap.durotar)
  check("the zone has places", durotarCount >= 3, durotarCount)
  equal("a zone's map shows every place the client can put on it", layer.pinsShown, durotarCount)
  equal("each as a dot that is shown", Shown(), durotarCount)
  local razor = PinOf("razor-hill")
  check("Razor Hill has its dot", razor ~= nil)
  local razorX, razorY = P.Spot("razor-hill", zoneMap.durotar)
  check("where the client says Razor Hill is, on the canvas",
    razor.point[1] == "CENTER" and razor.point[2] == layer and near(razor.point[4], razorX * 1002) and near(razor.point[5], -razorY * 668))
  equal("a new player's marks are drawn at three quarters of the window's size", mapped.WorldMapSize(), 75)
  check("so a town's is", near(razor.mark.size[1], styles.town.size * 0.75) and near(razor.mark.size[2], styles.town.size * 0.75))
  check("in a button a little larger, so a small mark is easy to hit", near(razor.size[1], mapped.WORLD_MAP_HIT))
  equal("a town's mark is a hollow ring", razor.mark.texture, mapped.MEDIA .. "mark-ring")
  check("in the town's color", razor.mark.color[1] == styles.town.color[1] and razor.mark.color[3] == styles.town.color[3])
  equal("set in the middle of its button", razor.mark.point[1], "CENTER")
  equal("its tooltip names it", razor.tipName, "Razor Hill")
  equal("and says what it is", razor.tipKind, "Town, Durotar")
  equal("above the sheet by its kind", razor.level, 321 + 1 + styles.town.level)
  worldMap.mapId = zoneMap.barrens
  worldMap:OnMapChanged()
  check("a dungeon is shown on its zone's map", PinOf("wailing-caverns") ~= nil)
  equal("as a hollow square", PinOf("wailing-caverns").mark.texture, mapped.MEDIA .. "mark-square")
  equal("a harbor as a hollow diamond", PinOf("ratchet").mark.texture, mapped.MEDIA .. "mark-diamond")
  check("a landmark's mark is no smaller than the smallest",
    near(math.max(mapped.WORLD_MAP_SMALLEST, styles.landmark.size * 0.75), mapped.WORLD_MAP_SMALLEST))
  equal("the dots of the zone before are not", PinOf("razor-hill"), nil)

  -- A continent's map shows the larger places.
  worldMap.mapId = world.KALIMDOR
  worldMap:OnMapChanged()
  local major = mapped.WorldMapKinds(2)
  local continentCount = Expected(world.KALIMDOR, major)
  local everyCount = Expected(world.KALIMDOR)
  check("the continent holds more places than it shows", everyCount > continentCount and continentCount > 5, continentCount)
  equal("a continent's map shows the capitals, the towns and the harbors", layer.pinsShown, continentCount)
  equal("and puts the other dots away", Shown(), continentCount)
  check("Orgrimmar is there", PinOf("orgrimmar") ~= nil)
  check("and Ratchet", PinOf("ratchet") ~= nil)
  check("a place put by its neighbors says so", PinOf("senjin-village").tipKind:find("its spot is an estimate", 1, true) ~= nil)
  equal("one with a real spot does not", PinOf("orgrimmar").tipKind, "Capital, Durotar")
  equal("a dungeon is not", PinOf("wailing-caverns"), nil)
  check("though the client could put it there", P.Spot("wailing-caverns", world.KALIMDOR) ~= nil)
  equal("the world's maps show the capitals alone", mapped.WorldMapKinds(1).town, nil)
  equal("of which a town is not one", mapped.WorldMapKinds(0).capital_city, true)
  equal("a zone's map shows every kind", mapped.WorldMapKinds(3), nil)

  -- A map the client cannot place things on.
  worldMap.mapId = world.AZEROTH
  worldMap:OnMapChanged()
  equal("a map the client cannot put a place on has no dots", layer.pinsShown, 0)
  equal("none left over from the map before", Shown(), 0)

  -- Zooming: the dots stay the same size on the screen.
  worldMap.mapId = world.KALIMDOR
  worldMap:OnMapChanged()
  canvas.scale = 0.5
  worldMap:OnCanvasScaleChanged()
  check("at half the scale a mark is drawn twice as large", near(PinOf("orgrimmar").mark.size[1], styles.capital_city.size * 0.75 * 2))
  check("and its button", near(PinOf("orgrimmar").size[1], (styles.capital_city.size * 0.75 + 4) * 2))
  canvas.scale = 1
  worldMap:OnCanvasScaleChanged()
  check("and back", near(PinOf("orgrimmar").mark.size[1], styles.capital_city.size * 0.75))
  equal("a capital's mark is a ring too, the largest", PinOf("orgrimmar").mark.texture, mapped.MEDIA .. "mark-ring")

  -- How large the marks are is the player's to say.
  stub.state.printed = {}
  mapped.SlashCommand("pins bigger")
  equal("/ewow pins bigger takes the next size up", mapped.WorldMapSize(), 100)
  check("and the marks are drawn at it", near(PinOf("orgrimmar").mark.size[1], styles.capital_city.size))
  check("and says so", stub.state.printed[#stub.state.printed]:find("drawn at 100%%") ~= nil, stub.state.printed[#stub.state.printed])
  mapped.SlashCommand("pins smaller")
  mapped.SlashCommand("pins smaller")
  equal("/ewow pins smaller twice takes it two down", mapped.WorldMapSize(), 50)
  check("a mark is never drawn smaller than the smallest", near(PinOf("ratchet").mark.size[1], mapped.WORLD_MAP_SMALLEST))
  mapped.SlashCommand("pins smaller")
  equal("and stops at the smallest size", mapped.WorldMapSize(), 50)
  mapped.SlashCommand("pins 60")
  equal("/ewow pins 60 sets it by hand", mapped.Database().worldMapSize, 60)
  mapped.SlashCommand("pins size 140%")
  equal("as does /ewow pins size 140%", mapped.WorldMapSize(), 140)
  mapped.SlashCommand("pins bigger")
  equal("bigger from between two sizes is the next one up", mapped.WorldMapSize(), 150)
  mapped.SlashCommand("pins bigger")
  equal("and stops at the largest", mapped.WorldMapSize(), 150)
  stub.state.printed = {}
  mapped.SlashCommand("pins 500")
  equal("a size out of range changes nothing", mapped.WorldMapSize(), 150)
  check("and prints how to use it", stub.state.printed[1]:find("Usage: /ewow pins", 1, true) ~= nil)
  mapped.SlashCommand("pins sideways")
  equal("nor does a word it does not know", #stub.state.printed, 2)
  mapped.SlashCommand("pins off")
  equal("/ewow pins off takes them off", Shown(), 0)
  mapped.SlashCommand("pins on")
  equal("and /ewow pins on puts them back", Shown(), continentCount)
  mapped.Database().worldMapSize = "large"
  equal("a size that is no number is passed over for the usual one", mapped.WorldMapSize(), 75)
  mapped.Database().worldMapSize = 900
  equal("as is a saved size far too large", mapped.WorldMapSize(), 75)
  mapped.Database().worldMapSize = 5
  equal("or far too small", mapped.WorldMapSize(), 75)
  mapped.Database().worldMapSize = nil

  -- The window's button goes round the sizes and Off.
  equal("the button's words say the size", mapped.WorldMapDotsLabel(), "World Map Dots: 75%")
  equal("a click takes the next size", mapped.NextWorldMapSize(), "World Map Dots: 100%")
  mapped.NextWorldMapSize()
  equal("and the next", mapped.NextWorldMapSize(), "World Map Dots: 150%")
  equal("after the largest comes Off", mapped.NextWorldMapSize(), "World Map Dots: Off")
  equal("with no mark on the map", Shown(), 0)
  equal("and after Off the smallest", mapped.NextWorldMapSize(), "World Map Dots: 50%")
  equal("with the marks back", Shown(), continentCount)
  mapped.NextWorldMapSize()
  equal("back at the size a new player gets", mapped.WorldMapSize(), 75)

  -- Opening the map draws it for the map it opens on.
  worldMap.mapId = zoneMap.durotar
  check("the map's opening is hooked", type(worldMap.hooks.OnShow) == "function")
  worldMap.hooks.OnShow(worldMap)
  equal("and draws the map it opens on", layer.mapId, zoneMap.durotar)
  worldMap.mapId = world.KALIMDOR
  worldMap:OnMapChanged()

  -- A click plans the trip.
  equal("no trip yet, so no way is drawn", layer.routeShown, 0)
  equal("and no ring", layer.goal:IsShown(), false)
  local ratchet = PinOf("ratchet")
  ratchet.scripts.OnClick(ratchet, "RightButton")
  check("a right-click on a mark plans the trip there", mapped.trip and mapped.trip.ok, mapped.trip and mapped.trip.message)
  equal("from where the character stands", mapped.trip.title, "Orgrimmar to Ratchet (On foot)")
  check("the way is drawn on the world map", layer.routeShown >= 1, layer.routeShown)
  local ratchetX, ratchetY = P.Spot("ratchet", world.KALIMDOR)
  equal("the gold ring is on the destination", layer.goal.node, "place:ratchet")
  check("at its spot", near(layer.goal.point[4], ratchetX * 1002) and near(layer.goal.point[5], -ratchetY * 668))
  equal("the character's own arrow marks the start, so no ring does", layer.start:IsShown(), false)
  local firstLine = layer.route[1]
  check("the first line sets off from the character",
    near(firstLine.startPoint[3], 0.61 * 1002) and near(firstLine.startPoint[4], -0.44 * 668))
  check("drawn a little thinner at three quarters", near(firstLine.thickness, 2.25))
  check("the gold ring a little smaller too", near(layer.goal.size[1], 26 * 0.75))
  check("the tracker shows the trip too", mapped.tracker ~= nil and mapped.tracker:IsShown() and mapped.tracker.title.text == "Orgrimmar to Ratchet (On foot)")
  equal("the window was never opened for it", mapped.window, nil)

  -- While the map is open the first line keeps to the character.
  world.player[world.KALIMDOR] = { 0.6, 0.5 }
  layer.scripts.OnUpdate(layer, 0.3)
  check("a moment later the line has not moved yet", near(firstLine.startPoint[3], 0.61 * 1002))
  layer.scripts.OnUpdate(layer, 0.3)
  check("after half a second it follows the character", near(firstLine.startPoint[3], 0.6 * 1002) and near(firstLine.startPoint[4], -0.5 * 668))
  world.player[world.KALIMDOR] = nil
  equal("where the client will not say where the character is, the line stays", mapped.WorldMapFollow(), false)
  world.player[world.KALIMDOR] = { 0.61, 0.44 }

  -- The places a trip passes through are shown whatever their kind.
  mapped.WindowPick("place:wailing-caverns", "LeftButton")
  check("a trip to a dungeon shows the dungeon on the continent's map", PinOf("wailing-caverns") ~= nil)
  equal("with the ring on it", layer.goal.node, "place:wailing-caverns")
  equal("one dot more than the continent shows by itself", layer.pinsShown, continentCount + 1)

  -- A click is where the trip starts, and the next click where it ends.
  local crossroads = PinOf("the-crossroads")
  crossroads.scripts.OnClick(crossroads, "LeftButton")
  equal("a click on a mark is where the trip starts", mapped.MapClickStage(), 1)
  equal("no trip is planned until the second click", mapped.trip, nil)
  equal("the world map draws no way between the two clicks", layer.routeShown, 0)
  mapped.MapClick("place:wailing-caverns", "LeftButton")
  equal("the second click plans the trip from the first", mapped.trip.from, "place:the-crossroads")
  equal("the green ring marks the picked start", layer.start.node, "place:the-crossroads")
  equal("and is shown", layer.start:IsShown(), true)
  equal("no line follows the character then", layer.follow, nil)
  equal("the trip is still to the dungeon", mapped.trip.to, "place:wailing-caverns")

  -- The other continent's map.
  worldMap.mapId = world.EASTERN
  worldMap:OnMapChanged()
  equal("a way that lies on one continent is not drawn on the other", layer.routeShown, 0)
  equal("nor its rings", layer.goal:IsShown(), false)
  equal("neither of them", layer.start:IsShown(), false)
  check("that continent's own places are there", PinOf("undercity") ~= nil and PinOf("orgrimmar") == nil)
  worldMap.mapId = world.KALIMDOR
  worldMap:OnMapChanged()
  check("back on the first, the way is drawn again", layer.routeShown >= 1 and layer.goal:IsShown())

  -- /ewow pins.
  stub.state.printed = {}
  mapped.SlashCommand("pins")
  equal("/ewow pins takes the dots off the world map", Shown(), 0)
  equal("and the way", layer.routeShown, 0)
  equal("and the rings", layer.goal:IsShown(), false)
  check("and says how to put them back", stub.state.printed[#stub.state.printed]:find("/ewow pins puts them on it", 1, true) ~= nil)
  check("the trip itself is kept", mapped.trip ~= nil and mapped.trip.ok and mapped.tracker:IsShown())
  worldMap:OnMapChanged()
  equal("another map shows none either", Shown(), 0)
  mapped.SlashCommand("pins")
  equal("/ewow pins again puts them back", Shown(), continentCount + 1)
  check("with the way", layer.routeShown >= 1)

  -- The button in the window.
  mapped.SlashCommand("")
  local dots = mapped.window.dots
  check("the window has a World Map Dots button", dots ~= nil)
  equal("which says the size", dots.text, "World Map Dots: 75%")
  dots.scripts.OnClick(dots)
  equal("a click takes the next size and says it", dots.text, "World Map Dots: 100%")
  check("and the marks on the map follow", near(PinOf("orgrimmar").mark.size[1], styles.capital_city.size))
  mapped.SlashCommand("pins 75")
  equal("the command and the button agree", dots.text, "World Map Dots: 75%")
  mapped.SlashCommand("pins")
  equal("off by the command reads Off on the button", dots.text, "World Map Dots: Off")
  mapped.SlashCommand("pins")
  equal("and on again reads the size", dots.text, "World Map Dots: 75%")
  mapped.window:Hide()

  -- Ending the trip.
  mapped.WindowClear()
  equal("ending the trip takes the way off the map", layer.routeShown, 0)
  equal("and the rings", layer.goal:IsShown(), false)
  equal("the dots of the map stay", Shown(), continentCount)
  equal("the tracker is put away", mapped.tracker:IsShown(), false)

  -- Nothing kept on a frame may take the name of one of the frame's own calls.
  for _, own in ipairs({ "Show", "Hide", "IsShown", "SetPoint", "SetSize", "SetScript", "GetParent", "SetShown", "IsVisible", "SetScale", "GetWidth", "GetHeight", "SetHeight", "Enable", "Disable", "SetText", "GetText", "Clear", "Raise", "Lower", "Close" }) do
    check("the sheet keeps nothing under the frame's own " .. own, rawget(layer, own) == nil)
    check("nor the tracker", rawget(mapped.tracker, own) == nil)
  end

  -- A client that cannot draw lines still gets the dots and the rings.
  rawset(_G, "EW_TEST_NO_LINES", true)
  local lineless = t.LoadFreshAddon(2, FOREVER)
  worldMap.mapId = world.KALIMDOR
  lineless.Database().worldMapOn = true
  lineless.RefreshWorldMap()
  local linelessLayer = lineless.worldMapLayer
  check("without line drawing the sheet is still laid", linelessLayer ~= nil, lineless.worldMapError)
  equal("with its dots", linelessLayer.pinsShown, continentCount)
  lineless.WindowPick("place:ratchet", "LeftButton")
  equal("a trip draws no line there", linelessLayer.routeShown, 0)
  equal("but the ring marks where it goes", linelessLayer.goal.node, "place:ratchet")
  rawset(_G, "EW_TEST_NO_LINES", nil)

  -- A client whose map does not hand out its canvas by a call.
  local olderMap, olderCanvas = MakeWorldMap()
  rawset(olderMap, "GetCanvas", function() return nil end)
  rawset(olderMap, "ScrollContainer", { Child = olderCanvas })
  rawset(_G, "WorldMapFrame", olderMap)
  local older = t.LoadFreshAddon(2, FOREVER)
  check("the canvas is found under the map's scroll frame too", older.worldMapLayer ~= nil and older.worldMapLayer.parent == olderCanvas)
  equal("with no word on the map's levels the sheet lies just over the canvas", older.worldMapLayer.level, 42)

  -- A world map that comes after the addon has loaded.
  rawset(_G, "WorldMapFrame", nil)
  local late = t.LoadFreshAddon(2, FOREVER)
  equal("with no world map at loading there is no sheet", late.worldMapLayer, nil)
  local lateMap = MakeWorldMap()
  rawset(_G, "WorldMapFrame", lateMap)
  stub.Fire("PLAYER_ENTERING_WORLD")
  check("entering the world finds a map that came later", late.worldMapLayer ~= nil)

  -- Another client: nothing of it.
  local retail = t.LoadFreshAddon(1, { "12.1.0", "60000", "Sep 17 2026", 120100 })
  retail.SlashCommand("")
  equal("off WoW Forever the window has no World Map Dots button", retail.window.dots, nil)
  retail.window:Hide()
  equal("off WoW Forever no sheet is laid on the world map", retail.worldMapLayer, nil)
  equal("asking for it says no", retail.WorldMapStart(), false)
  equal("no trip is followed", retail.TRIP_FOLLOWING, false)
  stub.state.printed = {}
  retail.SlashCommand("tracker")
  equal("/ewow tracker says where the tracker works", stub.state.printed[1]:match(": (.+)$"), "The route tracker covers WoW Forever only.")
  retail.SlashCommand("pins")
  equal("/ewow pins likewise", stub.state.printed[2]:match(": (.+)$"), "The places on the world map cover WoW Forever only.")
  equal("and neither is saved", retail.Database().trackerHidden == nil and retail.Database().worldMapOn == nil, true)

  for _, toc in ipairs({ "EverythingWoW.toc", "EverythingWoW_Vanilla.toc" }) do
    local handle = assert(io.open(t.root .. toc, "r"))
    local text = handle:read("*a")
    handle:close()
    check(toc .. " loads the world map after the window", text:find("Window.lua\nWorldMap.lua", 1, true) ~= nil)
  end

  world.Remove()
  for name, value in pairs(saved) do rawset(_G, name, value) end
  for _, name in ipairs({ "CreateFrame", "UIParent", "Minimap", "WorldMapFrame", "hooksecurefunc", "UnitOnTaxi" }) do
    if saved[name] == nil then rawset(_G, name, nil) end
  end
  stub.state.timers = {}
  stub.state.printed = {}
  stub.state.map = nil
end
