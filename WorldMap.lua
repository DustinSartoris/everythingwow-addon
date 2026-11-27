--[[
The planner on the game's own world map, for the player who asks for it,
and the tracker.

The window of Window.lua is where a trip is planned. The map players
already open, with the M key, is left as the game draws it unless the
player turns the planner's places on there: /ewow pins, or the window's
World Map Dots button. Then the places are marks on that map too: a click
on a mark is where the trip starts, the next click is where it ends, a
right-click goes there from where the character stands, and the way is
drawn over the map in the same colors the window uses.

Which places are shown goes by the map. A zone's map shows every place the
planner has in it. A continent's map shows the capitals, the towns and the
places boats and zeppelins leave from. The map of the whole world shows the
capitals. The places a planned trip passes through are always shown.

The marks sit on the map's own canvas, so they move and zoom with the map,
and they are sized against the canvas's scale, so they stay the same size on
the screen. From 0.5.1 a mark is hollow, so the map's own picture of the
place shows through it, and its shape says what the place is: a ring for a
city, a town or a landmark, a diamond for a place boats and zeppelins leave
from, and a square for a dungeon, a raid or a battleground. How large the
marks are is the player's to say: the window's World Map Dots button goes
round the sizes and Off, and /ewow pins does the same by hand.

The tracker is a small panel that holds the trip in hand: where to, how
long, and the next steps, the next one first. It can be dragged anywhere and
stays where it was left. Its Map button opens the window and its cross ends
the trip. /ewow tracker hides it and shows it again.

A trip that starts where the character stands follows the character. Every
couple of seconds the addon asks the client which map the character is on.
When that is a new zone or a city, the trip is planned again from there, so
the first step shown is always the next one; and when it is the place the
trip was going to, the trip ends and a line in chat says so. Nothing is
planned again in the air or on a boat.

All of it is WoW Forever's, where the planner's map is. It reads the map
that is shown, the character's place on it and whether the character is on
a taxi, and registers no event of its own. Nothing here is saved but three
small settings: whether the dots are on and how large they are, whether
the tracker is hidden, and where the tracker was left.
]]

local ADDON_NAME, EW = ...

-- How large a mark is on the world map, as a percent of its size in the
-- window: the sizes the button goes round, and the one a new player gets.
EW.WORLD_MAP_SIZES = { 50, 75, 100, 125, 150 }
EW.WORLD_MAP_SIZE = 75
-- No mark is drawn smaller than this, and none is harder to hit than this.
EW.WORLD_MAP_SMALLEST = 7
EW.WORLD_MAP_HIT = 14
EW.TRACKER_ROWS = 5
EW.TRACKER_WIDTH = 260
EW.TRIP_FOLLOW_SECONDS = 2
-- How near its destination, as a part of the zone's map, the character
-- must stand for the trip to have ended.
EW.ARRIVED_WITHIN = 0.025

local T = EW.TRAVEL
local MEDIA = EW.MEDIA or ("Interface\\AddOns\\" .. tostring(ADDON_NAME) .. "\\Media\\")

local PLACE = {}
if T then
  for _, place in ipairs(T.PLACES) do PLACE[place.key] = place end
end

local function Forever()
  return EW.VersionKey() == "forever" and T ~= nil and EW.Travel ~= nil
end

--[[ A number the client lets an addon read, or nil. ]]
local function Plain(value)
  local hidden = false
  pcall(function()
    if type(issecretvalue) == "function" and issecretvalue(value) then hidden = true end
  end)
  if hidden or type(value) ~= "number" or value ~= value then return nil end
  return value
end

local function ReadNode(node)
  if type(node) ~= "string" then return nil end
  return node:match("^(%a+):(.+)$")
end

--------------------------------------------------------------------------
-- The world map
--------------------------------------------------------------------------

-- The kinds of place a continent's map shows, and the whole world's.
local ON_A_CONTINENT = { capital_city = true, town = true, harbor = true, zeppelin_tower = true, sky_dock = true }
local ON_THE_WORLD = { capital_city = true }

--[[ The kinds of place shown on a map of a type, as the client numbers the
     types: 0 and 1 are the worlds, 2 is a continent, and the rest are
     zones and smaller. Nil is every kind. ]]
function EW.WorldMapKinds(mapType)
  if mapType == 0 or mapType == 1 then return ON_THE_WORLD end
  if mapType == 2 then return ON_A_CONTINENT end
  return nil
end

-- The world map's frame, its canvas, and the addon's own sheet over it.
local host, canvas, layer = nil, nil, nil
local startFailed = false
local pins, routeLines = {}, {}

-- For each map: the places the client can put on it, each as
-- { place, x, y, estimated }.
local spotsOf = {}

local function Spots(mapId)
  local cached = spotsOf[mapId]
  if cached then return cached end
  local list = {}
  for _, place in ipairs(T.PLACES) do
    local x, y, estimated = EW.Places.Spot(place.key, mapId)
    if x then list[#list + 1] = { place = place, x = x, y = y, estimated = estimated } end
  end
  -- A client that could not yet say is asked again the next time.
  if #list > 0 then spotsOf[mapId] = list end
  return list
end

local function MapType(mapId)
  local mapType
  pcall(function()
    local info = C_Map.GetMapInfo(mapId)
    if type(info) == "table" then mapType = Plain(info.mapType) end
  end)
  return mapType
end

--[[ The places a trip passes through, by key. ]]
local function TripPlaces(trip)
  local keys = {}
  if type(trip) ~= "table" then return keys end
  local function Add(node)
    local kind, key = ReadNode(node)
    if kind == "place" then keys[key] = true end
  end
  Add(trip.from)
  Add(trip.to)
  if trip.ok and trip.plan then
    for _, step in ipairs(trip.plan.steps) do
      Add(step.fromNode)
      Add(step.toNode)
    end
  end
  return keys
end

-- The shape of a kind's mark: the picture in Media/ that draws it.
local MARKS = {
  capital_city = "mark-ring", town = "mark-ring", landmark = "mark-ring",
  harbor = "mark-diamond", zeppelin_tower = "mark-diamond", sky_dock = "mark-diamond",
  dungeon = "mark-square", raid = "mark-square", battleground = "mark-square",
}

--[[ How large the marks are, as a percent: what the player set, or the
     size a new player gets. ]]
function EW.WorldMapSize()
  local size = Plain(EW.Database().worldMapSize)
  if not size or size < 30 or size > 200 then return EW.WORLD_MAP_SIZE end
  return size
end

local function PinAt(index)
  local pin = pins[index]
  if pin then return pin end
  pin = CreateFrame("Button", nil, layer)
  -- One picture, in the middle of a button that is a little larger than it
  -- so a small mark is still easy to hit.
  local mark = pin:CreateTexture(nil, "ARTWORK")
  mark:SetPoint("CENTER", pin, "CENTER", 0, 0)
  pin.mark = mark
  pcall(function() pin:SetHighlightTexture(MEDIA .. "ring") end)
  EW.MapPickable(pin, nil, "", nil)
  pins[index] = pin
  return pin
end

local function Ring(r, g, b)
  local ring = layer:CreateTexture(nil, "OVERLAY")
  ring:SetTexture(MEDIA .. "ring")
  ring:SetVertexColor(r, g, b, 1)
  ring:Hide()
  return ring
end

--[[ Puts a ring on a node of the trip, or takes it away. ]]
local function PlaceRing(ring, node, mapId, width, height, size)
  local x, y
  if node then x, y = EW.Places.NodeSpot(node, mapId) end
  if not x then
    ring:Hide()
    ring.node = nil
    return
  end
  ring:SetSize(size, size)
  ring:ClearAllPoints()
  ring:SetPoint("CENTER", layer, "TOPLEFT", x * width, -y * height)
  ring:Show()
  ring.node = node
end

--[[ How much a size is grown so it looks the same whatever the canvas's
     scale. ]]
local function Grow(scale)
  scale = Plain(scale)
  if not scale or scale <= 0 then return 1 end
  return math.max(0.25, math.min(8, 1 / scale))
end

--[[ Draws the dots, the way and the rings for the map that is shown. ]]
local function Draw()
  if not layer then return end
  local db = EW.Database()
  local mapId, width, height, scale
  pcall(function() mapId = Plain(host:GetMapID()) end)
  pcall(function() width, height, scale = Plain(canvas:GetWidth()), Plain(canvas:GetHeight()), canvas:GetScale() end)
  local usedPins, usedLines = 0, 0
  local trip = EW.trip
  layer.follow = nil

  if db.worldMapOn and mapId and width and height and width > 0 and height > 0 then
    local grow = Grow(scale)
    local percent = EW.WorldMapSize() / 100
    local styles = EW.PIN_STYLES
    local kinds = EW.WorldMapKinds(MapType(mapId))
    local onTrip = TripPlaces(trip)
    local baseLevel = 1
    pcall(function() baseLevel = layer:GetFrameLevel() + 1 end)

    for _, spot in ipairs(Spots(mapId)) do
      local place = spot.place
      if not kinds or kinds[place.kind] or onTrip[place.key] then
        usedPins = usedPins + 1
        local pin = PinAt(usedPins)
        local style = styles[place.kind] or styles.landmark
        local drawn = math.max(EW.WORLD_MAP_SMALLEST, style.size * percent)
        local hit = math.max(EW.WORLD_MAP_HIT, drawn + 4)
        pin:SetSize(hit * grow, hit * grow)
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", layer, "TOPLEFT", spot.x * width, -spot.y * height)
        pcall(function() pin:SetFrameLevel(baseLevel + style.level) end)
        pin.mark:SetTexture(MEDIA .. (MARKS[place.kind] or "mark-ring"))
        pin.mark:SetSize(drawn * grow, drawn * grow)
        pin.mark:SetVertexColor(style.color[1], style.color[2], style.color[3], 1)
        local zone = place.zone and T.ZONES[place.zone]
        local what = zone and (style.label .. ", " .. zone.name) or style.label
        if spot.estimated then what = what .. " (its spot is an estimate)" end
        pin.node, pin.tipName, pin.tipKind = "place:" .. place.key, place.name, what
        pin.place = place.key
        pin:Show()
      end
    end

    -- The way: a line for each step whose two ends are on this map. The
    -- lines need the client's line drawing; the rings do not.
    pcall(function()
      if not (trip and trip.ok and trip.plan) then return end
      for index, step in ipairs(trip.plan.steps) do
        local ax, ay = EW.Places.NodeSpot(step.fromNode, mapId)
        local followed = false
        -- A trip from where the character stands sets off from the
        -- character, not from the middle of its zone.
        if index == 1 and trip.here then
          local px, py = EW.Places.Player(mapId)
          if px then ax, ay, followed = px, py, true end
        end
        local bx, by = EW.Places.NodeSpot(step.toNode, mapId)
        if ax and bx and (ax ~= bx or ay ~= by) then
          local line = routeLines[usedLines + 1]
          if not line then
            line = layer:CreateLine(nil, "ARTWORK")
            routeLines[usedLines + 1] = line
          end
          usedLines = usedLines + 1
          local color = EW.STEP_COLORS[step.family] or EW.STEP_COLOR
          line:SetThickness(math.max(2, 3 * percent) * grow)
          line:SetColorTexture(color[1], color[2], color[3], 0.95)
          line:SetStartPoint("TOPLEFT", layer, ax * width, -ay * height)
          line:SetEndPoint("TOPLEFT", layer, bx * width, -by * height)
          line:Show()
          if followed then layer.follow = { line = line, map = mapId, width = width, height = height } end
        end
      end
    end)

    local to = trip and trip.to or nil
    -- Where the character stands the client's own arrow already shows, so
    -- only a start that was picked gets a ring.
    local from = trip and not trip.here and trip.from or nil
    PlaceRing(layer.goal, to, mapId, width, height, math.max(18, 26 * percent) * grow)
    PlaceRing(layer.start, from, mapId, width, height, math.max(16, 22 * percent) * grow)
  else
    PlaceRing(layer.goal, nil)
    PlaceRing(layer.start, nil)
  end

  for index = usedPins + 1, #pins do pins[index]:Hide() end
  for index = usedLines + 1, #routeLines do routeLines[index]:Hide() end
  layer.pinsShown, layer.routeShown, layer.mapId = usedPins, usedLines, mapId
end

--[[ While the map is open, the first line's start keeps to the character. ]]
function EW.WorldMapFollow()
  local follow = layer and layer.follow
  if not follow then return false end
  local x, y = EW.Places.Player(follow.map)
  if not x then return false end
  follow.line:SetStartPoint("TOPLEFT", layer, x * follow.width, -y * follow.height)
  return true
end

--[[ How far above the map's own canvas the sheet lies: over the map's
     points of interest and its flight points, under the marks of the
     character and its group, where the client can say where those are. ]]
local function LayerLevel()
  local level = 3
  pcall(function() level = canvas:GetFrameLevel() + 2 end)
  pcall(function()
    local levels = host:GetPinFrameLevelsManager()
    local function Of(name)
      local value
      pcall(function() value = Plain(levels:GetValidFrameLevel(name)) end)
      return value
    end
    local over
    for _, name in ipairs({ "PIN_FRAME_LEVEL_AREA_POI", "PIN_FRAME_LEVEL_FLIGHT_POINT", "PIN_FRAME_LEVEL_DUNGEON_ENTRANCE" }) do
      local value = Of(name)
      if value and (not over or value > over) then over = value end
    end
    if over then level = over + 1 end
    local under = Of("PIN_FRAME_LEVEL_GROUP_MEMBER") or Of("PIN_FRAME_LEVEL_UNIT")
    if under and level >= under then level = math.max(1, under - 1) end
  end)
  return level
end

--[[ Finds the world map and lays the sheet over it. True once that is
     done; false where there is no world map yet, or none the addon can
     draw on. It is asked again when the world is entered and when a trip
     is planned. ]]
function EW.WorldMapStart()
  if layer then return true end
  if startFailed or not Forever() or not EW.Places or not EW.MapPickable or not EW.PIN_STYLES then return false end
  local frame = rawget(_G, "WorldMapFrame")
  if type(frame) ~= "table" then return false end
  local found
  pcall(function() found = frame:GetCanvas() end)
  if not found then pcall(function() found = frame.ScrollContainer.Child end) end
  if not found then return false end

  host, canvas = frame, found
  local ok, problem = pcall(function()
    local sheet = CreateFrame("Frame", "EverythingWoWWorldMapLayer", found)
    sheet:SetAllPoints(found)
    pcall(function() sheet:SetFrameLevel(LayerLevel()) end)
    layer = sheet
    sheet.goal = Ring(1, 0.82, 0.2)
    sheet.start = Ring(0.3, 1, 0.4)
    sheet.pins, sheet.route = pins, routeLines
    sheet.waited = 0
    -- Shown only while the world map is, so this costs nothing otherwise.
    sheet:SetScript("OnUpdate", function(self, elapsed)
      if not self.follow then return end
      self.waited = (self.waited or 0) + (Plain(elapsed) or 0)
      if self.waited < 0.5 then return end
      self.waited = 0
      pcall(EW.WorldMapFollow)
    end)
  end)
  if not ok or not layer then
    startFailed, layer, host, canvas = true, nil, nil, nil
    EW.worldMapError = tostring(problem)
    return false
  end
  EW.worldMapLayer = layer

  -- The map says when it shows another map, when it is zoomed and when it
  -- is opened. A client without one of these keeps the others.
  local function Redraw() pcall(Draw) end
  pcall(function() hooksecurefunc(frame, "OnMapChanged", Redraw) end)
  pcall(function()
    if type(frame.OnCanvasScaleChanged) == "function" then hooksecurefunc(frame, "OnCanvasScaleChanged", Redraw) end
  end)
  pcall(function() frame:HookScript("OnShow", Redraw) end)
  pcall(Draw)
  return true
end

function EW.RefreshWorldMap()
  if not EW.WorldMapStart() then return false end
  return (pcall(Draw))
end

--[[ What the window's button says: how large the marks are, or that they
     are off. ]]
function EW.WorldMapDotsLabel()
  if not EW.Database().worldMapOn then return "World Map Dots: Off" end
  return string.format("World Map Dots: %d%%", EW.WorldMapSize())
end

--[[ Sets how large the marks are, as a percent, and shows them. ]]
function EW.SetWorldMapSize(percent)
  percent = Plain(percent)
  if not percent then return false end
  local db = EW.Database()
  db.worldMapSize = math.max(30, math.min(200, math.floor(percent + 0.5)))
  db.worldMapOn = true
  EW.RefreshWorldMap()
  return true
end

--[[ The next of the sizes after the one set, or the one before it: the
     smallest and the largest are where it stops. ]]
local function Step(up)
  local sizes, now = EW.WORLD_MAP_SIZES, EW.WorldMapSize()
  local chosen
  if up then
    for index = #sizes, 1, -1 do
      if sizes[index] > now then chosen = sizes[index] end
    end
  else
    for index = 1, #sizes do
      if sizes[index] < now then chosen = sizes[index] end
    end
  end
  return chosen or now
end

--[[ The window's button: round the sizes, smallest first, then off, then
     the smallest again. ]]
function EW.NextWorldMapSize()
  local db = EW.Database()
  local sizes = EW.WORLD_MAP_SIZES
  if not db.worldMapOn then
    EW.SetWorldMapSize(sizes[1])
  elseif EW.WorldMapSize() >= sizes[#sizes] then
    db.worldMapOn = nil
    EW.RefreshWorldMap()
  else
    EW.SetWorldMapSize(Step(true))
  end
  return EW.WorldMapDotsLabel()
end

--[[ /ewow pins: takes the places off the world map, or puts them back.
     /ewow pins smaller, /ewow pins bigger and /ewow pins 60 set how large
     they are. ]]
function EW.PinsCommand(rest)
  if not Forever() then
    EW.Print("The places on the world map cover WoW Forever only.")
    return
  end
  local db = EW.Database()
  local word = string.lower(tostring(rest or "")):gsub("^%s+", ""):gsub("%s+$", "")
  word = word:gsub("^size%s*", ""):gsub("%%$", "")
  if word == "off" or word == "on" then
    db.worldMapOn = word == "on" and true or nil
    EW.RefreshWorldMap()
    EW.Print(word == "off" and "The places are off the world map. /ewow pins puts them on it."
      or "The places are on the world map. Click one to start a route there, then click where to go.")
  elseif word ~= "" then
    local percent = tonumber(word)
    if word == "smaller" or word == "small" then percent = Step(false) end
    if word == "bigger" or word == "larger" or word == "big" then percent = Step(true) end
    if not percent or percent < 30 or percent > 200 then
      EW.Print("Usage: /ewow pins hides or shows the places on the world map. /ewow pins smaller, /ewow pins bigger, or /ewow pins 30 to 200 sets their size in percent.")
      return
    end
    EW.SetWorldMapSize(percent)
    EW.Print(string.format("The places on the world map are drawn at %d%%.", EW.WorldMapSize()))
  else
    db.worldMapOn = not db.worldMapOn and true or nil
    EW.RefreshWorldMap()
    if not db.worldMapOn then
      EW.Print("The places are off the world map. /ewow pins puts them on it.")
    else
      EW.Print("The places are on the world map. Click one to start a route there, then click where to go.")
    end
  end
  if EW.RefreshDotsButton then pcall(EW.RefreshDotsButton) end
end

--------------------------------------------------------------------------
-- The tracker
--------------------------------------------------------------------------

local tracker, trackerFailed = nil, false

local ANCHORS = {
  TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
  RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

--[[ Where the tracker was left, as { point, relativePoint, x, y }, or nil
     where nothing sound is saved. ]]
local function SavedSpot()
  local spot = EW.Database().trackerSpot
  if type(spot) ~= "table" then return nil end
  if not ANCHORS[spot[1]] or not ANCHORS[spot[2]] then return nil end
  if type(spot[3]) ~= "number" or type(spot[4]) ~= "number" then return nil end
  if spot[3] ~= spot[3] or spot[4] ~= spot[4] then return nil end
  return spot
end

local function PlaceTracker()
  local spot = SavedSpot()
  tracker:ClearAllPoints()
  if spot then
    tracker:SetPoint(spot[1], UIParent, spot[2], spot[3], spot[4])
  else
    tracker:SetPoint("LEFT", UIParent, "LEFT", 24, 40)
  end
end

--[[ After a drag: remember where the tracker was left. ]]
local function KeepSpot()
  local point, _, relativePoint, x, y = tracker:GetPoint(1)
  x, y = Plain(x), Plain(y)
  if ANCHORS[point] and ANCHORS[relativePoint] and x and y then
    EW.Database().trackerSpot = { point, relativePoint, math.floor(x + 0.5), math.floor(y + 0.5) }
  end
end

--[[ How tall a line of text stands once it has wrapped. ]]
local function Tall(text, fallback)
  local tall
  pcall(function() tall = Plain(text:GetStringHeight()) end)
  if not tall or tall <= 0 then return fallback end
  return tall
end

local function BuildTracker()
  local width = EW.TRACKER_WIDTH
  local frame = CreateFrame("Frame", "EverythingWoWTracker", UIParent)
  frame:SetSize(width, 90)
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) pcall(self.StartMoving, self) end)
  frame:SetScript("OnDragStop", function(self)
    pcall(self.StopMovingOrSizing, self)
    pcall(KeepSpot)
  end)

  local shade = frame:CreateTexture(nil, "BACKGROUND")
  shade:SetAllPoints(frame)
  shade:SetColorTexture(0, 0, 0, 0.6)
  local bar = frame:CreateTexture(nil, "BORDER")
  bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
  bar:SetHeight(2)
  bar:SetColorTexture(1, 0.82, 0.25, 0.9)

  local function Text(font, textWidth)
    local text = frame:CreateFontString(nil, "OVERLAY", font)
    text:SetJustifyH("LEFT")
    text:SetWidth(textWidth)
    pcall(function() text:SetWordWrap(true) end)
    pcall(function() text:SetJustifyV("TOP") end)
    return text
  end

  -- The cross ends the trip; the button beside it opens the window.
  pcall(function()
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetSize(22, 22)
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 2, 0)
    close:SetScript("OnClick", function() pcall(EW.WindowClear) end)
    frame.close = close
  end)
  pcall(function()
    local open = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    open:SetSize(44, 18)
    open:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -20, -4)
    open:SetText("Map")
    open:SetScript("OnClick", function() pcall(EW.ShowWindow, "route") end)
    frame.open = open
  end)

  frame.title = Text("GameFontNormal", width - 16 - 66)
  frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -8)
  frame.estimate = Text("GameFontHighlightSmall", width - 16)
  frame.estimate:SetPoint("TOPLEFT", frame.title, "BOTTOMLEFT", 0, -4)
  frame.rows = {}
  local above = frame.estimate
  for index = 1, EW.TRACKER_ROWS do
    local row = Text("GameFontHighlightSmall", width - 16)
    row:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, index == 1 and -8 or -4)
    frame.rows[index] = row
    above = row
  end
  frame.more = Text("GameFontDisableSmall", width - 16)
  frame:Hide()
  return frame
end

--[[ Shows the trip in hand in the tracker, or puts the tracker away where
     there is none or it has been hidden. True where it is shown. ]]
function EW.RefreshTracker()
  local trip = EW.trip
  local wanted = Forever() and type(trip) == "table" and trip.ok and not EW.Database().trackerHidden
  if not wanted then
    if tracker then pcall(function() tracker:Hide() end) end
    return false
  end
  if not tracker then
    -- One try: a client that cannot build it is not asked at every trip.
    if trackerFailed then return false end
    local ok, built = pcall(BuildTracker)
    if not ok or not built then
      trackerFailed = true
      EW.trackerError = tostring(built)
      return false
    end
    tracker = built
    EW.tracker = built
    pcall(PlaceTracker)
  end
  local ok = pcall(function()
    local steps = trip.steps or {}
    tracker.title:SetText(trip.title)
    tracker.estimate:SetText(trip.estimate)
    local height = 8 + Tall(tracker.title, 14) + 4 + Tall(tracker.estimate, 22)
    local last = tracker.estimate
    for index, row in ipairs(tracker.rows) do
      local line = steps[index]
      if line then
        row:SetText(line)
        -- The next step stands out from the ones after it.
        if index == 1 then row:SetTextColor(1, 1, 1, 1) else row:SetTextColor(0.72, 0.72, 0.72, 1) end
        row:Show()
        height = height + (index == 1 and 8 or 4) + Tall(row, 22)
        last = row
      else
        row:SetText("")
        row:Hide()
      end
    end
    local left = #steps - #tracker.rows
    if left > 0 then
      tracker.more:ClearAllPoints()
      tracker.more:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -4)
      tracker.more:SetText(left == 1 and "and 1 more step" or string.format("and %d more steps", left))
      tracker.more:Show()
      height = height + 4 + Tall(tracker.more, 11)
    else
      tracker.more:SetText("")
      tracker.more:Hide()
    end
    tracker:SetHeight(height + 8)
    tracker:Show()
  end)
  return ok
end

--[[ /ewow tracker: hides the tracker, or shows it again. ]]
function EW.TrackerCommand()
  if not Forever() then
    EW.Print("The route tracker covers WoW Forever only.")
    return
  end
  local db = EW.Database()
  db.trackerHidden = not db.trackerHidden and true or nil
  EW.RefreshTracker()
  if db.trackerHidden then
    EW.Print("The route tracker is hidden. /ewow tracker shows it again.")
  else
    EW.Print("The route tracker is shown. It appears when a route is planned.")
  end
end

--------------------------------------------------------------------------
-- A trip that follows the character
--------------------------------------------------------------------------

--[[ True in the air and on a boat, where the map under the character is
     not where the trip stands. ]]
local function Carried()
  local carried = false
  pcall(function()
    if type(UnitOnTaxi) == "function" and UnitOnTaxi("player") then carried = true end
  end)
  if not carried and EW.RideState then
    pcall(function() if EW.RideState() then carried = true end end)
  end
  return carried
end

--[[ True where the character, at the node here, has reached the node to. ]]
local function Arrived(here, to)
  if here == to then return true end
  local hereKind, hereKey = ReadNode(here)
  local toKind, toKey = ReadNode(to)
  if toKind == "zone" then
    return hereKind == "place" and PLACE[hereKey] ~= nil and PLACE[hereKey].zone == toKey
  end
  if toKind ~= "place" or not EW.Places then return false end
  -- A place with no map of its own: near enough to its spot on the map the
  -- character is on.
  local mapId
  pcall(function() mapId = Plain(C_Map.GetBestMapForUnit("player")) end)
  if not mapId then return false end
  local x, y, estimated = EW.Places.Spot(toKey, mapId)
  local px, py = EW.Places.Player(mapId)
  if not x or not px or estimated then return false end
  local dx, dy = x - px, y - py
  return dx * dx + dy * dy <= EW.ARRIVED_WITHIN * EW.ARRIVED_WITHIN
end

--[[
One look at where the character is, for a trip that started where it
stood. Returns "arrived" where the trip has ended, "replanned" where it was
planned again from a new zone or city, and nil where nothing changed.
]]
function EW.TripFollow()
  local trip = EW.trip
  if type(trip) ~= "table" or not trip.ok or not trip.here or not Forever() then return nil end
  if Carried() then return nil end
  local here = EW.Travel.Here()
  if not here then return nil end
  if Arrived(here, trip.to) then
    local name = EW.Travel.NodeName(trip.to)
    EW.WindowClear()
    EW.Print(name and ("You have arrived at " .. name .. ".") or "You have arrived.")
    return "arrived"
  end
  if here == trip.from then return nil end
  -- Only a trip that can still be planned takes the place of the one in
  -- hand: a zone with no way on keeps the steps already shown.
  local ahead = EW.RouteAnswer("", "", nil, trip.to)
  if not ahead.ok then return nil end
  EW.WindowPick(trip.to, "LeftButton")
  return "replanned"
end

--------------------------------------------------------------------------
-- Starting
--------------------------------------------------------------------------

-- The window says when the trip in hand has changed.
EW.OnTrip = function()
  pcall(EW.RefreshWorldMap)
  pcall(EW.RefreshTracker)
end

local following = false
pcall(function()
  if not Forever() then return end
  pcall(EW.WorldMapStart)
  -- Entering the world is an event the addon already listens for; the
  -- world map is there by then where it was not when the addon loaded.
  EW.RegisterEvent("PLAYER_ENTERING_WORLD", function() pcall(EW.WorldMapStart) end)
  if C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(EW.TRIP_FOLLOW_SECONDS, function() pcall(EW.TripFollow) end)
    following = true
  end
end)
EW.TRIP_FOLLOWING = following
