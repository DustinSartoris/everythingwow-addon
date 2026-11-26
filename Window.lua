--[[
The Companion's window.

/ewow opens it, and so does the button on the minimap. It has two pages.

Route. A map on the left and the trip on the right. The map is the game's
own, a continent at a time, with every place the planner knows as a dot
where the game has the place; where the client cannot give its map, a map
drawn from the site's own zone outlines stands in. Click a place, or a
zone's name, to go there: the trip is planned from where your character stands, the steps
are listed beside the map and the way is drawn on it. Right-click a place
to start from it instead. The two boxes still take a typed name, and the
speed button goes round the four speeds.

Recorded. What the file holds now, kind by kind, in the words the site's
upload page uses, how many observations were dropped to keep the file small,
where the file is written, and where to upload it.

A third button opens the list of auctions under vendor price, which keeps
its own window beside the auction house.

Every frame is built inside a pcall and with the game's own templates where
the client has them. A client on which the window cannot be built gets the
chat commands as before, and one on which only the map cannot be drawn
keeps the two boxes. The window reads what the commands read, and saves
nothing but where the minimap button sits.
]]

local ADDON_NAME, EW = ...

EW.WINDOW_STEP_ROWS = 7
EW.WINDOW_MAP_WIDTH = 720
EW.WINDOW_MAP_HEIGHT = 480
EW.WINDOW_SIDE_WIDTH = 270

local MEDIA = "Interface\\AddOns\\" .. tostring(ADDON_NAME) .. "\\Media\\"
EW.MEDIA = MEDIA

local SPEED_LABELS = { foot = "On foot", travel_form = "Travel form", mount_60 = "Mount 60%", mount_100 = "Mount 100%" }

-- The site's own labels for the kinds, from its upload page.
local KIND_LABELS = {
  npc = "NPC Sightings",
  object = "Object Sightings",
  quest_start = "Quests Started",
  quest_end = "Quests Completed",
  objective = "Objectives",
  loot = "Loot Events",
  vendor = "Vendors",
  trainer = "Trainers",
  flight = "Flight Paths",
  auction = "Auction Rows",
  rare = "Rare Sightings",
  character_snapshot = "Character Snapshots",
  item = "Items",
  transit = "Transport Rides",
}

-- How each kind of place is drawn on the map: its size, its color, the
-- word for it, and how far above the others it lies.
local PIN_STYLES = {
  capital_city = { size = 16, color = { 1, 0.82, 0.25 }, label = "Capital", level = 6 },
  town = { size = 10, color = { 0.95, 0.93, 0.88 }, label = "Town", level = 4 },
  harbor = { size = 11, color = { 0.35, 0.8, 0.95 }, label = "Harbor", level = 5 },
  zeppelin_tower = { size = 11, color = { 0.35, 0.8, 0.95 }, label = "Zeppelin tower", level = 5 },
  sky_dock = { size = 11, color = { 0.35, 0.8, 0.95 }, label = "Sky dock", level = 5 },
  dungeon = { size = 10, color = { 0.7, 0.5, 0.95 }, label = "Dungeon", level = 3 },
  raid = { size = 11, color = { 0.95, 0.4, 0.75 }, label = "Raid", level = 3 },
  battleground = { size = 10, color = { 0.95, 0.35, 0.3 }, label = "Battleground", level = 3 },
  landmark = { size = 8, color = { 0.65, 0.65, 0.65 }, label = "Landmark", level = 2 },
}

-- The color of a zone's outline and name, by whose land it is.
local ZONE_COLORS = {
  alliance = { 0.35, 0.6, 1 },
  horde = { 0.95, 0.35, 0.3 },
  contested = { 0.9, 0.75, 0.35 },
  neutral = { 0.5, 0.85, 0.55 },
  none = { 0.6, 0.6, 0.6 },
}

-- The color of a step's line on the map, by how it is traveled.
local STEP_COLORS = {
  flight = { 0.6, 0.85, 1 },
  ride = { 0.3, 0.95, 0.8 },
}
local STEP_COLOR = { 1, 0.82, 0.2 }
-- The world map of WorldMap.lua draws the same dots and the same lines.
EW.PIN_STYLES, EW.STEP_COLORS, EW.STEP_COLOR = PIN_STYLES, STEP_COLORS, STEP_COLOR

local window, windowFailed = nil, false
local page, stepPage = "route", 1
local answer = nil
-- The places picked on the map, as the planner's own nodes.
local picks = { from = nil, to = nil }

--------------------------------------------------------------------------
-- What the pages show, as plain values, so the tests can read them
--------------------------------------------------------------------------

local function Trim(text)
  if type(text) ~= "string" then return "" end
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local PLACE_BY_KEY = {}
if EW.TRAVEL and EW.TRAVEL.PLACES then
  for _, place in ipairs(EW.TRAVEL.PLACES) do PLACE_BY_KEY[place.key] = place end
end

--[[ Where a point of the atlas lies on the window's map, in the map's own
     units from its top left corner. ]]
function EW.MapPoint(x, y)
  local M = EW.TRAVEL_MAP
  if not M or type(x) ~= "number" or type(y) ~= "number" then return nil end
  local moved = x
  for _, cut in ipairs(M.CUTS) do
    if x >= cut.x then moved = moved - cut.shift end
  end
  return moved - M.originX, y - M.originY
end

--[[ Where one of the planner's nodes lies on the map: a place at its own
     spot, a zone at its middle. ]]
function EW.MapNodePoint(node)
  if type(node) ~= "string" or not EW.TRAVEL then return nil end
  local kind, key = node:match("^(%a+):(.+)$")
  if kind == "place" and PLACE_BY_KEY[key] then
    return EW.MapPoint(PLACE_BY_KEY[key].x, PLACE_BY_KEY[key].y)
  end
  if kind == "zone" and EW.TRAVEL.ZONES[key] then
    return EW.MapPoint(EW.TRAVEL.ZONES[key].x, EW.TRAVEL.ZONES[key].y)
  end
  return nil
end

--[[ Where one name goes: on its spot, or a line up or down where it would
     lie on a dot or on a name already set. taken is the list of boxes set
     so far, each { x, y, width, height } about its middle, and gains this
     name's own. ]]
function EW.MapNameSpot(taken, x, y, name)
  -- A little wider than the name is drawn, so two names do not touch.
  local width, height = #name * 6.4 + 8, 11
  local best, bestHits = 0, nil
  for _, move in ipairs({ 0, 11, -11, 22, -22, 33, -33 }) do
    local hits = 0
    for _, box in ipairs(taken) do
      if math.abs(x - box[1]) * 2 < width + box[3] and math.abs(y + move - box[2]) * 2 < height + box[4] then
        hits = hits + 1
      end
    end
    if not bestHits or hits < bestHits then best, bestHits = move, hits end
    if hits == 0 then break end
  end
  taken[#taken + 1] = { x, y + best, width, height }
  return x, y + best
end

--[[
Where each zone's name goes on a map drawn at a scale, in pixels from the
map's top left corner: { [zone key] = { x, y } }. A name starts on its
zone's middle and is moved up or down a line where it would lie on a
place's dot or on a name already set, so that as few as can be collide.
]]
function EW.MapLabelSpots(scale)
  local T = EW.TRAVEL
  local spots, taken = {}, {}
  if not T or not EW.TRAVEL_MAP then return spots end
  for _, place in ipairs(T.PLACES) do
    local x, y = EW.MapPoint(place.x, place.y)
    local style = PIN_STYLES[place.kind] or PIN_STYLES.landmark
    if x then taken[#taken + 1] = { x * scale, y * scale, style.size + 2, style.size + 2 } end
  end
  for _, key in ipairs(T.ZONE_ORDER) do
    local zone = T.ZONES[key]
    local x, y = EW.MapPoint(zone.x, zone.y)
    if x then
      local nameX, nameY = EW.MapNameSpot(taken, x * scale, y * scale, zone.name)
      spots[key] = { nameX, nameY }
    end
  end
  return spots
end

--[[
Plans a trip. The two texts are what the boxes hold; the two nodes are what
was picked on the map, and a picked node wins over its box. An empty From
is where the character stands. Returns { ok = true, title, estimate, steps,
plan, from, to, here } where a route was found and { ok = false, message }
otherwise, with from and to where they were understood. here is true where
the trip starts from where the character stands, which is the trip that
follows the character as it goes.
]]
function EW.RouteAnswer(fromText, toText, fromNode, toNode)
  local Travel = EW.Travel
  if not Travel or EW.VersionKey() ~= "forever" then
    return { ok = false, message = "The route planner covers WoW Forever only." }
  end
  fromText, toText = Trim(fromText), Trim(toText)
  local from, to = fromNode, toNode
  local here = false
  if not from and fromText ~= "" then from = Travel.Find(fromText) end
  if not to then
    if toText == "" then
      return { ok = false, from = from, message = "Click a place on the map, or type where you want to go." }
    end
    to = Travel.Find(toText)
  end
  if not from and fromText == "" then
    from = Travel.Here()
    here = true
    if not from then
      return {
        ok = false,
        to = to,
        message = "The planner does not know the map you are on. Right-click a place to start from it, or type it.",
      }
    end
  end
  if not from or not to then return { ok = false, from = from, to = to, message = Travel.Refusal("not_on_map") } end
  local lines, found, plan = Travel.Lines(from, to)
  if not found then return { ok = false, from = from, to = to, message = lines[1] } end
  local steps = {}
  for index = 3, #lines do steps[#steps + 1] = lines[index] end
  return { ok = true, title = lines[1], estimate = lines[2], steps = steps, plan = plan, from = from, to = to, here = here }
end

--[[ What the file holds: the rows of the Recorded page, a heading line
     first. Each row is { label, count }. ]]
function EW.RecordedRows()
  local db = EW.Database()
  local counts = {}
  for _, observation in ipairs(db.observations) do
    counts[observation.kind] = (counts[observation.kind] or 0) + 1
  end
  local rows = {}
  for _, kind in ipairs(EW.KINDS) do
    if counts[kind] then rows[#rows + 1] = { KIND_LABELS[kind] or kind, counts[kind] } end
  end
  return rows, #db.observations, db.dropped or 0
end

local function CurrentSpeed()
  local speed = EW.Database().travelSpeed
  if type(speed) ~= "string" or not SPEED_LABELS[speed] then return "foot" end
  return speed
end

--[[ The next speed after the one set, round the four. ]]
function EW.NextTravelSpeed()
  local order = (EW.Travel and EW.Travel.SPEEDS) or { "foot", "travel_form", "mount_60", "mount_100" }
  local current = CurrentSpeed()
  local nextSpeed = order[1]
  for index, speed in ipairs(order) do
    if speed == current then nextSpeed = order[(index % #order) + 1] end
  end
  EW.Database().travelSpeed = nextSpeed
  return nextSpeed
end

--------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------

local function ShowAll(list, shown)
  for _, widget in ipairs(list) do
    if shown then widget:Show() else widget:Hide() end
  end
end

--[[ Puts a ring on the map at a spot, in pixels from its top left corner,
     or takes it away. ]]
local function PlaceMarker(map, marker, x, y, node)
  if not x then
    marker:Hide()
    marker.node = nil
    return
  end
  marker:ClearAllPoints()
  marker:SetPoint("CENTER", map, "TOPLEFT", x, -y)
  marker:Show()
  marker.node = node
end

--[[ Draws the planned way on the map, a line for each step whose two ends
     are on the map shown, and the two rings: where the trip starts and
     where it ends. ]]
local function DrawRoute()
  local map = window and window.map
  if not map then return end
  -- The lines need the client's line drawing; the rings do not.
  pcall(function()
    local used = 0
    if answer and answer.ok and answer.plan then
      for _, step in ipairs(answer.plan.steps) do
        local ax, ay = map.pixelOf(step.fromNode)
        local bx, by = map.pixelOf(step.toNode)
        if ax and bx and (ax ~= bx or ay ~= by) then
          local line = map.route[used + 1]
          if not line then
            line = map:CreateLine(nil, "ARTWORK")
            line:SetThickness(3)
            map.route[used + 1] = line
          end
          used = used + 1
          local color = STEP_COLORS[step.family] or STEP_COLOR
          line:SetColorTexture(color[1], color[2], color[3], 0.95)
          line:SetStartPoint("TOPLEFT", map, ax, -ay)
          line:SetEndPoint("TOPLEFT", map, bx, -by)
          line:Show()
        end
      end
    end
    for index = used + 1, #map.route do map.route[index]:Hide() end
    map.routeShown = used
  end)
  local from = picks.from or (answer and answer.from) or (EW.Travel and EW.Travel.Here()) or nil
  local to = picks.to or (answer and answer.to) or nil
  local hereX, hereY
  -- With no start picked, the real map knows where the character itself
  -- stands, which is better than the middle of its zone.
  if not picks.from and map.playerPixel then hereX, hereY = map.playerPixel() end
  if hereX then
    PlaceMarker(map, map.here, hereX, hereY, from or "player")
  else
    local x, y
    if from then x, y = map.pixelOf(from) end
    PlaceMarker(map, map.here, x, y, from)
  end
  local goalX, goalY
  if to then goalX, goalY = map.pixelOf(to) end
  PlaceMarker(map, map.goal, goalX, goalY, to)
  -- The words beside the green ring: where the character is, or where the
  -- trip was told to start.
  if map.here.node then
    map.hereText:SetText(picks.from and "Start" or "You are here")
    map.hereText:Show()
  else
    map.hereText:Hide()
  end
end

--[[ What stands over the From box: where the trip starts when the box is
     left empty. ]]
local function FromCaption()
  if picks.from then return "From" end
  local typed = ""
  pcall(function() typed = Trim(window.from:GetText() or "") end)
  if typed ~= "" then return "From" end
  local here = EW.Travel and EW.VersionKey() == "forever" and EW.Travel.Here() or nil
  local name = here and EW.Travel.NodeName(here) or nil
  if name then return "From (where you stand: " .. name .. ")" end
  return "From"
end

local function RefreshRoute()
  local frame = window
  frame.speed:SetText("Speed: " .. SPEED_LABELS[CurrentSpeed()])
  frame.fromCaption:SetText(FromCaption())
  local steps = (answer and answer.ok and answer.steps) or {}
  local perPage = EW.WINDOW_STEP_ROWS
  local pages = math.max(1, math.ceil(#steps / perPage))
  if stepPage > pages then stepPage = pages end
  if stepPage < 1 then stepPage = 1 end
  if not answer then
    frame.heading:SetText("Where to?")
    if frame.map then
      frame.estimate:SetText("Click a place on the map to go there from where you stand.")
    else
      frame.estimate:SetText("Leave From empty to start where you stand.")
    end
  elseif answer.ok then
    frame.heading:SetText(answer.title)
    frame.estimate:SetText(answer.estimate)
  else
    frame.heading:SetText(answer.message)
    frame.estimate:SetText("")
  end
  local first = (stepPage - 1) * perPage
  for index, row in ipairs(frame.steps) do
    local line = steps[first + index]
    if line then
      row:SetText(line)
      row:Show()
    else
      row:SetText("")
      row:Hide()
    end
  end
  if pages > 1 then
    frame.pageText:SetText(string.format("Page %d of %d", stepPage, pages))
    frame.pageText:Show()
    frame.prev:Show()
    frame.next:Show()
  else
    frame.pageText:Hide()
    frame.prev:Hide()
    frame.next:Hide()
  end
  pcall(DrawRoute)
end

local function RefreshRecorded()
  local frame = window
  local rows, held, dropped = EW.RecordedRows()
  frame.held:SetText(string.format("%d observations held, %d dropped to keep the file small.", held, dropped))
  for index, line in ipairs(frame.kinds) do
    local row = rows[index]
    if row then
      line:SetText(row[1] .. ": " .. row[2])
      line:Show()
    else
      line:SetText("")
      line:Hide()
    end
  end
  if held == 0 then
    frame.none:Show()
  else
    frame.none:Hide()
  end
  local reports = {}
  if EW.FlightReport then reports[#reports + 1] = EW.FlightReport() end
  if EW.RideReport then reports[#reports + 1] = EW.RideReport() end
  frame.travel:SetText(table.concat(reports, "\n"))
end

--[[ The World Map Dots button says the size set, or Off. ]]
function EW.RefreshDotsButton()
  if window and window.dots and EW.WorldMapDotsLabel then window.dots:SetText(EW.WorldMapDotsLabel()) end
end

local function Refresh()
  if not window then return end
  pcall(EW.RefreshDotsButton)
  ShowAll(window.routeWidgets, page == "route")
  ShowAll(window.recordedWidgets, page == "recorded")
  if page == "route" then
    RefreshRoute()
  else
    RefreshRecorded()
  end
end

--[[ Tells whoever else shows the trip, the world map and the tracker,
     that it has changed. EW.trip is the answer in hand, or nil. ]]
local function Tell()
  EW.trip = answer
  if EW.OnTrip then pcall(EW.OnTrip, answer) end
end

--[[ Plans the trip the picks and the boxes ask for. It works before the
     window has ever been opened, for a pick made on the world map. ]]
local function Plan()
  local fromText, toText = "", ""
  if window then
    pcall(function()
      fromText = window.from:GetText() or ""
      toText = window.to:GetText() or ""
    end)
  end
  answer = EW.RouteAnswer(fromText, toText, picks.from, picks.to)
  stepPage = 1
  if window then
    pcall(function()
      window.from:ClearFocus()
      window.to:ClearFocus()
    end)
  end
  Refresh()
  Tell()
end
EW.WindowPlan = Plan

--[[ A place or a zone was picked on the map: a click is where to go, a
     right-click is where to start. The box takes its name, and the trip is
     planned at once. ]]
function EW.WindowPick(node, mouseButton)
  if type(node) ~= "string" then return end
  local name = (EW.Travel and EW.Travel.NodeName(node)) or ""
  -- The boxes are written only where the window has been made; a pick on
  -- the world map before that is kept, and the boxes take it when it is.
  local function Box(which, text)
    if window then pcall(function() window[which]:SetText(text) end) end
  end
  if mouseButton == "RightButton" then
    picks.from = node
    Box("from", name)
    -- One place cannot be both ends: the newer pick stays and the other end
    -- is asked for again.
    if picks.to == node then
      picks.to = nil
      Box("to", "")
    end
  else
    picks.to = node
    Box("to", name)
    -- The start goes back to where the character stands.
    if picks.from == node then
      picks.from = nil
      Box("from", "")
    end
  end
  Plan()
end

--[[ Empties both ends and the answer: the window as it first opened. ]]
function EW.WindowClear()
  picks.from, picks.to = nil, nil
  answer = nil
  stepPage = 1
  if window then
    pcall(function()
      window.from:SetText("")
      window.to:SetText("")
    end)
  end
  Refresh()
  Tell()
end

--[[ The tooltip of a dot or a zone's name on the map. ]]
local function ShowMapTip(owner)
  pcall(function()
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(owner.tipName, 1, 1, 1)
    if owner.tipKind then GameTooltip:AddLine(owner.tipKind, 0.9, 0.8, 0.5) end
    GameTooltip:AddLine("Click to go here. Right-click to start here.", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
end
local function HideMapTip() pcall(function() GameTooltip:Hide() end) end

--[[ One thing on the map that can be picked. ]]
local function Pickable(button, node, name, kind)
  button.node, button.tipName, button.tipKind = node, name, kind
  pcall(function() button:RegisterForClicks("LeftButtonUp", "RightButtonUp") end)
  button:SetScript("OnClick", function(self, mouseButton) pcall(EW.WindowPick, self.node, mouseButton) end)
  button:SetScript("OnEnter", ShowMapTip)
  button:SetScript("OnLeave", HideMapTip)
end
EW.MapPickable = Pickable

--[[ A zone's name on a map, at a spot in pixels. A name is a button: a
     click picks the zone. ]]
local function MakeZoneName(map, key, x, y, level)
  local zone = EW.TRAVEL.ZONES[key]
  local color = ZONE_COLORS[zone.faction] or ZONE_COLORS.none
  local button = CreateFrame("Button", nil, map)
  button:SetSize(#zone.name * 5.8 + 4, 11)
  button:SetPoint("CENTER", map, "TOPLEFT", x, -y)
  pcall(function() button:SetFrameLevel(level) end)
  local text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetPoint("CENTER", button, "CENTER", 0, 0)
  pcall(function()
    local font = text:GetFont()
    text:SetFont(font, 9, "OUTLINE")
  end)
  text:SetText(zone.name)
  text:SetTextColor(color[1], color[2], color[3], 1)
  pcall(function() button:SetSize(math.max(24, text:GetStringWidth() + 2), 11) end)
  button.text = text
  Pickable(button, "zone:" .. key, zone.name, "Zone")
  return button
end

--[[ A place's dot on a map, at a spot in pixels. ]]
local function MakePin(map, place, x, y, level, estimated)
  local style = PIN_STYLES[place.kind] or PIN_STYLES.landmark
  local pin = CreateFrame("Button", nil, map)
  pin:SetSize(style.size, style.size)
  pin:SetPoint("CENTER", map, "TOPLEFT", x, -y)
  pcall(function() pin:SetFrameLevel(level + style.level) end)
  local rim = pin:CreateTexture(nil, "BACKGROUND")
  rim:SetPoint("TOPLEFT", pin, "TOPLEFT", -1, 1)
  rim:SetPoint("BOTTOMRIGHT", pin, "BOTTOMRIGHT", 1, -1)
  rim:SetTexture(MEDIA .. "dot")
  rim:SetVertexColor(0, 0, 0, 0.9)
  local dot = pin:CreateTexture(nil, "ARTWORK")
  dot:SetAllPoints(pin)
  dot:SetTexture(MEDIA .. "dot")
  dot:SetVertexColor(style.color[1], style.color[2], style.color[3], 1)
  pcall(function() pin:SetHighlightTexture(MEDIA .. "ring") end)
  local zone = place.zone and EW.TRAVEL.ZONES[place.zone]
  local what = zone and (style.label .. ", " .. zone.name) or style.label
  if estimated then what = what .. " (its spot is an estimate)" end
  Pickable(pin, "place:" .. place.key, place.name, what)
  pin.estimated = estimated and true or false
  return pin
end

--[[ What every map carries over its picture: the two rings, the key, and
     the line that says how to use it. ]]
local function FinishMap(map)
  local function Ring(size, r, g, b)
    local ring = map:CreateTexture(nil, "OVERLAY")
    ring:SetSize(size, size)
    ring:SetTexture(MEDIA .. "ring")
    ring:SetVertexColor(r, g, b, 1)
    ring:Hide()
    return ring
  end
  map.here = Ring(22, 0.3, 1, 0.4)
  map.goal = Ring(26, 1, 0.82, 0.2)
  map.hereText = map:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  map.hereText:SetPoint("BOTTOM", map.here, "TOP", 0, 1)
  map.hereText:SetTextColor(0.3, 1, 0.4, 1)
  map.hereText:Hide()

  -- A dark band along the foot, so the key reads over any picture.
  local band = map:CreateTexture(nil, "BORDER")
  band:SetPoint("BOTTOMLEFT", map, "BOTTOMLEFT", 0, 0)
  band:SetPoint("BOTTOMRIGHT", map, "BOTTOMRIGHT", 0, 0)
  band:SetHeight(36)
  band:SetColorTexture(0, 0, 0, 0.7)

  -- The key: what each color of dot is.
  map.key = {}
  local keyLeft = 6
  for _, entry in ipairs({
    { "capital_city", "Capital" }, { "town", "Town" }, { "harbor", "Harbor or tower" },
    { "dungeon", "Dungeon" }, { "raid", "Raid" }, { "battleground", "Battleground" }, { "landmark", "Landmark" },
  }) do
    local style = PIN_STYLES[entry[1]]
    local dot = map:CreateTexture(nil, "OVERLAY")
    dot:SetSize(9, 9)
    dot:SetTexture(MEDIA .. "dot")
    dot:SetVertexColor(style.color[1], style.color[2], style.color[3], 1)
    dot:SetPoint("BOTTOMLEFT", map, "BOTTOMLEFT", keyLeft, 22)
    local word = map:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    word:SetPoint("LEFT", dot, "RIGHT", 3, 0)
    word:SetText(entry[2])
    map.key[#map.key + 1] = word
    keyLeft = keyLeft + 16 + #entry[2] * 5.6 + 8
  end

  local hint = map:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", map, "BOTTOMLEFT", 6, 6)
  hint:SetText("Click a place to go there from where you stand. Right-click a place to start from it instead.")
  map.hint = hint
end

--[[
The game's own map, a continent at a time. The pictures are the client's
own, asked for by the continent's number and laid out as the client lays
them out; every place is a dot where the client says the place is, and the
green ring is where the character really stands. A button for each
continent sits in the corner. Returns nil where the client cannot give
the pictures or cannot place the zones, and the drawn map is used instead.
]]
local function BuildRealMap(frame, left, top, width, height)
  local T, P = EW.TRAVEL, EW.Places
  if not P then return nil end
  local continents = P.Continents()
  if #continents == 0 then return nil end
  local tilesOf = {}
  for _, continent in ipairs(continents) do
    local tiles = P.Tiles(continent.map)
    if not tiles then return nil end
    tilesOf[continent.map] = tiles
  end

  local map = CreateFrame("Frame", nil, frame)
  map:SetSize(width, height)
  map:SetPoint("TOPLEFT", frame, "TOPLEFT", left, top)
  pcall(function() map:SetClipsChildren(true) end)
  local sea = map:CreateTexture(nil, "BACKGROUND", nil, -8)
  sea:SetAllPoints(map)
  sea:SetColorTexture(0.04, 0.07, 0.11, 1)
  map.real = true
  map.lines, map.route, map.sheets, map.tabs = 0, {}, {}, {}
  map.pins, map.zones = {}, {}

  local baseLevel = 1
  pcall(function() baseLevel = map:GetFrameLevel() + 1 end)

  --[[ One continent's sheet: its pictures, its dots and its names, made
       the first time the continent is shown. ]]
  local function Sheet(continent)
    local sheet = map.sheets[continent.map]
    if sheet then return sheet end
    sheet = { map = continent.map, tiles = {}, pins = {}, zones = {} }
    for _, tile in ipairs(tilesOf[continent.map]) do
      local picture = map:CreateTexture(nil, "BACKGROUND", nil, 1)
      picture:SetSize(tile.width * width, tile.height * height)
      picture:SetPoint("TOPLEFT", map, "TOPLEFT", tile.left * width, -tile.top * height)
      picture:SetTexture(tile.file)
      sheet.tiles[#sheet.tiles + 1] = picture
    end
    local taken = {}
    for _, place in ipairs(T.PLACES) do
      local x, y, estimated = P.Spot(place.key, continent.map)
      if x then
        local style = PIN_STYLES[place.kind] or PIN_STYLES.landmark
        sheet.pins[place.key] = MakePin(map, place, x * width, y * height, baseLevel, estimated)
        taken[#taken + 1] = { x * width, y * height, style.size + 2, style.size + 2 }
      end
    end
    for _, key in ipairs(T.ZONE_ORDER) do
      local x, y = P.ZoneSpot(key, continent.map)
      if x then
        local nameX, nameY = EW.MapNameSpot(taken, x * width, y * height, T.ZONES[key].name)
        sheet.zones[key] = MakeZoneName(map, key, nameX, nameY, baseLevel)
      end
    end
    map.sheets[continent.map] = sheet
    return sheet
  end

  local function ShowSheet(sheet, shown)
    for _, list in ipairs({ sheet.tiles, sheet.pins, sheet.zones }) do
      for _, widget in pairs(list) do
        if shown then widget:Show() else widget:Hide() end
      end
    end
  end

  --[[ Shows one continent and puts the others away. It must not be named
       Show: that is the frame's own, which the window calls to bring the
       whole map back when the Route page is returned to. ]]
  function map.showContinent(continentMap)
    local chosen
    for _, continent in ipairs(continents) do
      if continent.map == continentMap then chosen = continent end
    end
    if not chosen then return false end
    for _, sheet in pairs(map.sheets) do ShowSheet(sheet, false) end
    local sheet = Sheet(chosen)
    ShowSheet(sheet, true)
    map.continent, map.pins, map.zones = chosen.map, sheet.pins, sheet.zones
    for _, tab in ipairs(map.tabs) do
      pcall(function()
        if tab.continent == chosen.map then tab:LockHighlight() else tab:UnlockHighlight() end
      end)
    end
    pcall(DrawRoute)
    return true
  end

  function map.pixelOf(node)
    local x, y = P.NodeSpot(node, map.continent)
    if not x then return nil end
    return x * width, y * height
  end

  function map.playerPixel()
    local x, y = P.Player(map.continent)
    if not x then return nil end
    return x * width, y * height
  end

  -- A button for each continent, in the top left corner.
  local tabLeft = 6
  for _, continent in ipairs(continents) do
    local tab = CreateFrame("Button", nil, map, "UIPanelButtonTemplate")
    local tabWidth = math.max(70, #tostring(continent.name) * 7 + 20)
    tab:SetSize(tabWidth, 20)
    tab:SetPoint("TOPLEFT", map, "TOPLEFT", tabLeft, -6)
    tab:SetText(continent.name)
    pcall(function() tab:SetFrameLevel(baseLevel + 20) end)
    tab.continent = continent.map
    tab:SetScript("OnClick", function() pcall(map.showContinent, continent.map) end)
    map.tabs[#map.tabs + 1] = tab
    tabLeft = tabLeft + tabWidth + 4
  end

  FinishMap(map)

  -- Open on the continent the character is on.
  local first = P.PlayerContinent()
  if not map.showContinent(first) then map.showContinent(continents[1].map) end
  return map
end

--[[
The drawn map: the sea, each zone's outline in the color of whose land it
is, each zone's name, and a dot for every place, all where the site's own
map draws them. It stands in where the client cannot give its own map's
pictures. The outlines need the client's line drawing; where it has none,
the names and the dots are drawn without them.
]]
local function BuildMap(frame, left, top, width, height)
  local T, M = EW.TRAVEL, EW.TRAVEL_MAP
  local map = CreateFrame("Frame", nil, frame)
  map:SetSize(width, height)
  map:SetPoint("TOPLEFT", frame, "TOPLEFT", left, top)
  pcall(function() map:SetClipsChildren(true) end)
  local sea = map:CreateTexture(nil, "BACKGROUND")
  sea:SetAllPoints(map)
  sea:SetColorTexture(0.04, 0.07, 0.11, 1)
  local scale = math.min(height / M.height, width / M.width)
  map.scale = scale
  map.real = false
  map.lines, map.route, map.pins, map.zones = 0, {}, {}, {}

  function map.pixelOf(node)
    local x, y = EW.MapNodePoint(node)
    if not x then return nil end
    return x * scale, y * scale
  end

  pcall(function()
    for _, key in ipairs(T.ZONE_ORDER) do
      local zone = T.ZONES[key]
      local color = ZONE_COLORS[zone.faction] or ZONE_COLORS.none
      for _, ring in ipairs(M.OUTLINES[key] or {}) do
        local count = #ring / 2
        for index = 1, count do
          local after = index % count + 1
          local line = map:CreateLine(nil, "BORDER")
          line:SetThickness(1.2)
          line:SetColorTexture(color[1], color[2], color[3], 0.8)
          line:SetStartPoint("TOPLEFT", map, ring[index * 2 - 1] * scale, -ring[index * 2] * scale)
          line:SetEndPoint("TOPLEFT", map, ring[after * 2 - 1] * scale, -ring[after * 2] * scale)
          map.lines = map.lines + 1
        end
      end
    end
  end)

  local baseLevel = 1
  pcall(function() baseLevel = map:GetFrameLevel() + 1 end)

  local spots = EW.MapLabelSpots(scale)
  for _, key in ipairs(T.ZONE_ORDER) do
    local spot = spots[key]
    if spot then map.zones[key] = MakeZoneName(map, key, spot[1], spot[2], baseLevel) end
  end
  for _, place in ipairs(T.PLACES) do
    local x, y = EW.MapPoint(place.x, place.y)
    if x then map.pins[place.key] = MakePin(map, place, x * scale, y * scale, baseLevel, false) end
  end

  FinishMap(map)
  return map
end

local function BuildWindow()
  local forever = EW.VersionKey() == "forever" and EW.TRAVEL ~= nil and EW.TRAVEL_MAP ~= nil
  local mapHeight = EW.WINDOW_MAP_HEIGHT
  local mapWidth = EW.WINDOW_MAP_WIDTH
  local side = EW.WINDOW_SIDE_WIDTH
  local width = 14 + mapWidth + 12 + side + 14
  local height = 64 + mapHeight + 14
  EW.WINDOW_WIDTH, EW.WINDOW_HEIGHT = width, height

  local frame
  local templated = pcall(function()
    frame = CreateFrame("Frame", "EverythingWoWWindow", UIParent, "BasicFrameTemplateWithInset")
  end)
  if not templated or not frame then
    frame = CreateFrame("Frame", "EverythingWoWWindow", UIParent)
    local shade = frame:CreateTexture(nil, "BACKGROUND")
    shade:SetAllPoints(frame)
    shade:SetColorTexture(0.05, 0.05, 0.07, 0.92)
    pcall(function()
      local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
      close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    end)
  end

  frame:SetSize(width, height)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  frame:SetFrameStrata("HIGH")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) pcall(self.StartMoving, self) end)
  frame:SetScript("OnDragStop", function(self) pcall(self.StopMovingOrSizing, self) end)
  -- On a small screen the whole window is drawn smaller rather than cut off.
  pcall(function()
    local fit = math.min(1, (UIParent:GetWidth() - 40) / width, (UIParent:GetHeight() - 60) / height)
    if fit < 1 then frame:SetScale(math.max(0.5, fit)) end
  end)

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", frame, "TOP", 0, -6)
  title:SetText("Everything WoW Companion")

  local function Button(label, buttonWidth, onClick)
    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetSize(buttonWidth, 22)
    button:SetText(label)
    button:SetScript("OnClick", function() pcall(onClick) end)
    return button
  end
  local function Text(font, justify)
    local text = frame:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    text:SetJustifyH(justify or "LEFT")
    return text
  end

  -- The page buttons, across the top.
  local routeTab = Button("Route", 90, function() page = "route" Refresh() end)
  routeTab:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -30)
  local recordedTab = Button("Recorded", 90, function() page = "recorded" Refresh() end)
  recordedTab:SetPoint("LEFT", routeTab, "RIGHT", 6, 0)
  local dealsTab = Button("Deals", 90, function() if EW.ToggleDeals then EW.ToggleDeals() end end)
  dealsTab:SetPoint("LEFT", recordedTab, "RIGHT", 6, 0)
  -- How large the places are drawn on the game's own world map, from 0.5.1:
  -- a click goes round the sizes and Off.
  if forever and EW.NextWorldMapSize then
    frame.dots = Button("World Map Dots", 170, function()
      EW.NextWorldMapSize()
      EW.RefreshDotsButton()
    end)
    frame.dots:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -30)
    frame.dots:SetScript("OnEnter", function(self)
      pcall(function()
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Places on the world map")
        GameTooltip:AddLine("Click to change how large the places are drawn on the game's own map, or to turn them off.", 1, 1, 1, true)
        GameTooltip:Show()
      end)
    end)
    frame.dots:SetScript("OnLeave", function() pcall(function() GameTooltip:Hide() end) end)
  end

  local routeWidgets, recordedWidgets = {}, {}
  local function Route(widget) routeWidgets[#routeWidgets + 1] = widget return widget end
  local function Recorded(widget) recordedWidgets[#recordedWidgets + 1] = widget return widget end

  -- The Route page: the map on the left.
  if forever then
    -- The game's own map where the client can give it, the drawn one where
    -- it cannot.
    local ok, map = pcall(BuildRealMap, frame, 14, -64, mapWidth, mapHeight)
    if not ok then EW.realMapError = tostring(map) end
    if not ok or not map then
      ok, map = pcall(BuildMap, frame, 14, -64, mapWidth, mapHeight)
    end
    if ok and map then
      frame.map = Route(map)
    else
      EW.mapError = tostring(map)
    end
  end
  if not frame.map then
    local note = Route(Text("GameFontDisable", "CENTER"))
    note:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -64 - mapHeight / 2)
    note:SetWidth(mapWidth)
    if forever then
      note:SetText("The map could not be drawn on this client. Type the two places instead.")
    else
      note:SetText("The map and the route planner cover WoW Forever only.")
    end
    frame.mapNote = note
  end

  -- The Route page: the trip on the right.
  local column = 14 + mapWidth + 12
  local function Box(label, top, which)
    local caption = Route(Text("GameFontNormalSmall"))
    caption:SetPoint("TOPLEFT", frame, "TOPLEFT", column, top)
    caption:SetText(label)
    if which == "from" then frame.fromCaption = caption end
    local box = Route(CreateFrame("EditBox", nil, frame, "InputBoxTemplate"))
    box:SetSize(side - 8, 20)
    box:SetPoint("TOPLEFT", frame, "TOPLEFT", column + 6, top - 14)
    box:SetAutoFocus(false)
    pcall(function() box:SetMaxLetters(60) end)
    box:SetScript("OnEnterPressed", function() pcall(Plan) end)
    box:SetScript("OnEscapePressed", function(self) pcall(self.ClearFocus, self) end)
    -- A typed name takes the place of one picked on the map.
    box:SetScript("OnTextChanged", function(_, userInput)
      if userInput then picks[which] = nil end
      if which == "from" and frame.fromCaption then pcall(function() frame.fromCaption:SetText(FromCaption()) end) end
    end)
    return box
  end
  frame.from = Box("From", -64, "from")
  frame.to = Box("To", -104, "to")
  frame.speed = Route(Button("Speed", 130, function()
    EW.NextTravelSpeed()
    -- A new speed is a new answer to the same question.
    if answer then Plan() else Refresh() end
  end))
  frame.speed:SetPoint("TOPLEFT", frame, "TOPLEFT", column, -146)
  local plan = Route(Button("Plan", 62, Plan))
  plan:SetPoint("LEFT", frame.speed, "RIGHT", 6, 0)
  frame.clear = Route(Button("Clear", 62, EW.WindowClear))
  frame.clear:SetPoint("LEFT", plan, "RIGHT", 6, 0)

  frame.heading = Route(Text("GameFontNormal"))
  frame.heading:SetPoint("TOPLEFT", frame, "TOPLEFT", column, -180)
  frame.heading:SetWidth(side)
  frame.heading:SetHeight(30)
  frame.estimate = Route(Text("GameFontHighlightSmall"))
  frame.estimate:SetPoint("TOPLEFT", frame, "TOPLEFT", column, -212)
  frame.estimate:SetWidth(side)
  frame.estimate:SetHeight(26)
  for _, text in ipairs({ frame.heading, frame.estimate }) do
    pcall(function() text:SetWordWrap(true) end)
    pcall(function() text:SetJustifyV("TOP") end)
  end

  frame.steps = {}
  for index = 1, EW.WINDOW_STEP_ROWS do
    local row = Route(Text("GameFontHighlightSmall"))
    row:SetPoint("TOPLEFT", frame, "TOPLEFT", column, -244 - (index - 1) * 40)
    row:SetWidth(side)
    row:SetHeight(38)
    pcall(function() row:SetWordWrap(true) end)
    pcall(function() row:SetJustifyV("TOP") end)
    frame.steps[index] = row
  end
  frame.prev = Route(Button("Previous", 80, function() stepPage = stepPage - 1 Refresh() end))
  frame.prev:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", column, 12)
  frame.next = Route(Button("Next", 80, function() stepPage = stepPage + 1 Refresh() end))
  frame.next:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 12)
  frame.pageText = Route(Text("GameFontHighlightSmall", "CENTER"))
  frame.pageText:SetPoint("BOTTOM", frame, "BOTTOMLEFT", column + side / 2, 17)

  -- The Recorded page.
  frame.held = Recorded(Text("GameFontNormal"))
  frame.held:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -66)
  frame.held:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -66)
  frame.kinds = {}
  for index = 1, #EW.KINDS do
    local line = Recorded(Text("GameFontHighlightSmall"))
    line:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -72 - index * 16)
    frame.kinds[index] = line
  end
  frame.none = Recorded(Text("GameFontDisable"))
  frame.none:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -88)
  frame.none:SetText("Nothing yet. Play, and what you meet is written down.")
  -- How far the two travel recorders have got this session.
  frame.travel = Recorded(Text("GameFontDisableSmall"))
  frame.travel:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 78)
  frame.travel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 78)
  local where = Recorded(Text("GameFontHighlightSmall"))
  where:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 44)
  where:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 44)
  where:SetText("The file is written when you log out or reload the interface:\nWTF\\Account\\<ACCOUNT>\\SavedVariables\\EverythingWoW.lua")
  local upload = Recorded(Text("GameFontNormalSmall"))
  upload:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 20)
  upload:SetText("Upload it at everythingwow.com/addons/companion/upload")

  frame.routeWidgets, frame.recordedWidgets = routeWidgets, recordedWidgets

  -- Escape closes it, as it closes any panel.
  pcall(function()
    local special = rawget(_G, "UISpecialFrames")
    if type(special) == "table" then table.insert(special, "EverythingWoWWindow") end
  end)
  frame:Hide()
  return frame
end

local function EnsureWindow()
  if window or windowFailed then return window end
  local ok, built = pcall(BuildWindow)
  if ok and built then
    window = built
    EW.window = built
    -- The planner is WoW Forever's, so elsewhere the window opens on what
    -- every client has: the Recorded page.
    if EW.VersionKey() ~= "forever" then page = "recorded" end
  else
    windowFailed = true
    EW.windowError = tostring(built)
  end
  return window
end

--[[ Opens the window on a page, "route" or "recorded". False where the
     client cannot build it. ]]
function EW.ShowWindow(which)
  local made = window == nil
  if not EnsureWindow() then return false end
  if which == "route" or which == "recorded" then page = which end
  -- A pick made on the world map before the window existed goes into its box.
  if made and EW.Travel then
    pcall(function()
      if picks.from then window.from:SetText(EW.Travel.NodeName(picks.from) or "") end
      if picks.to then window.to:SetText(EW.Travel.NodeName(picks.to) or "") end
    end)
  end
  local ok = pcall(function()
    window:Show()
    Refresh()
  end)
  return ok
end

function EW.ToggleWindow()
  if not EnsureWindow() then return false end
  local shown = false
  pcall(function() shown = window:IsShown() end)
  if shown then
    pcall(function() window:Hide() end)
    return true
  end
  return EW.ShowWindow()
end

--------------------------------------------------------------------------
-- The button on the minimap
--------------------------------------------------------------------------

EW.MINIMAP_ANGLE = 215
EW.MINIMAP_ICON_SIZE = 24

--[[ A small round button on the edge of the minimap: a click opens or
     closes the window, a drag moves it round the edge, and /ewow minimap
     hides it or shows it again. ]]
local minimapButton, minimapFailed = nil, false

--[[ The angle, in whole degrees from 0 to 359, of a point as seen from the
     middle of the minimap. ]]
function EW.MinimapAngleOf(x, y, centerX, centerY)
  local atan2 = math.atan2 or math.atan
  local degrees = math.deg(atan2(y - centerY, x - centerX))
  return math.floor(degrees + 0.5) % 360
end

--[[ While the button is dragged: put it where the pointer is, on the edge. ]]
local function FollowPointer()
  local x, y = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  local centerX, centerY = Minimap:GetCenter()
  if type(x) ~= "number" or type(y) ~= "number" or type(scale) ~= "number" or scale <= 0
    or type(centerX) ~= "number" or type(centerY) ~= "number" then
    return
  end
  EW.Database().minimapAngle = EW.MinimapAngleOf(x / scale, y / scale, centerX, centerY)
  EW.RefreshMinimapButton()
end

--[[ How far from the middle of the minimap the button sits: just past the
     minimap's own edge, whatever size this client draws it. ]]
function EW.MinimapRadius()
  local radius = 80
  pcall(function()
    local width = Minimap:GetWidth()
    if type(width) == "number" and width > 0 then radius = width / 2 + 5 end
  end)
  return radius
end

local function PlaceMinimapButton()
  local db = EW.Database()
  local angle = math.rad(type(db.minimapAngle) == "number" and db.minimapAngle or EW.MINIMAP_ANGLE)
  local radius = EW.MinimapRadius()
  minimapButton:ClearAllPoints()
  minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

--[[
The button is one picture: everythingwow.com's mark, cut round, with its
gold rim drawn on it. It is set in the middle of the button, at the size
the game's own round buttons are, so there are no parts for a client to set apart from one another, which is
how 0.3.3's ring and icon came out of line.
]]
local function BuildMinimapButton()
  local button = CreateFrame("Button", "EverythingWoWMinimapButton", Minimap)
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  pcall(function() button:SetFrameLevel(8) end)
  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(MEDIA .. "minimap")
  icon:SetPoint("CENTER", button, "CENTER", 0, 0)
  -- The game's own round buttons show a ring about this wide; the button
  -- itself stays a little larger so it is easy to hit.
  icon:SetSize(EW.MINIMAP_ICON_SIZE, EW.MINIMAP_ICON_SIZE)
  button.icon = icon
  pcall(function()
    button:SetHighlightTexture(MEDIA .. "ring")
    local glow = button:GetHighlightTexture()
    glow:SetBlendMode("ADD")
    glow:SetVertexColor(1, 0.9, 0.5, 0.6)
  end)
  button:RegisterForClicks("AnyUp")
  button:SetScript("OnClick", function() pcall(EW.ToggleWindow) end)
  pcall(function()
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", function(self)
      self:SetScript("OnUpdate", function() pcall(FollowPointer) end)
    end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  end)
  button:SetScript("OnEnter", function(self)
    pcall(function()
      GameTooltip:SetOwner(self, "ANCHOR_LEFT")
      GameTooltip:SetText("Everything WoW Companion")
      GameTooltip:AddLine("Click to open the map and plan a route.", 1, 1, 1)
      GameTooltip:AddLine("Drag to move it round the minimap.", 0.7, 0.7, 0.7)
      GameTooltip:Show()
    end)
  end)
  button:SetScript("OnLeave", function() pcall(function() GameTooltip:Hide() end) end)
  return button
end

function EW.RefreshMinimapButton()
  local db = EW.Database()
  if db.minimapHidden then
    if minimapButton then pcall(function() minimapButton:Hide() end) end
    return false
  end
  if not minimapButton then
    -- One try: a client that cannot build it is not asked at every loading screen.
    if minimapFailed then return false end
    local ok, built = pcall(BuildMinimapButton)
    if not ok or not built then
      minimapFailed = true
      return false
    end
    minimapButton = built
    EW.minimapButton = built
  end
  local ok = pcall(function()
    PlaceMinimapButton()
    minimapButton:Show()
  end)
  return ok
end

--[[ /ewow minimap: hides the button, or shows it again. ]]
function EW.MinimapCommand()
  local db = EW.Database()
  db.minimapHidden = not db.minimapHidden and true or nil
  EW.RefreshMinimapButton()
  if db.minimapHidden then
    EW.Print("The minimap button is hidden. /ewow minimap shows it again, and /ewow opens the window.")
  else
    EW.Print("The minimap button is shown.")
  end
end

-- Entering the world is an event the addon already listens for on every
-- client, and the minimap is there by then.
EW.RegisterEvent("PLAYER_ENTERING_WORLD", function() pcall(EW.RefreshMinimapButton) end)
