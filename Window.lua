--[[
The Companion's window.

/ewow opens it, and so does the button on the minimap. It has two pages.

Route. A map of the world on the left and the trip on the right. The map is
drawn from the same zone outlines everythingwow.com's map draws, with every
place the planner knows as a dot on it. Click a place, or a zone's name, to
go there: the trip is planned from where your character stands, the steps
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

EW.WINDOW_STEP_ROWS = 8
EW.WINDOW_MAP_HEIGHT = 540
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
}

-- How each kind of place is drawn on the map: its size, its color, the
-- word for it, and how far above the others it lies.
local PIN_STYLES = {
  capital_city = { size = 13, color = { 1, 0.82, 0.25 }, label = "Capital", level = 6 },
  town = { size = 8, color = { 0.95, 0.93, 0.88 }, label = "Town", level = 4 },
  harbor = { size = 9, color = { 0.35, 0.8, 0.95 }, label = "Harbor", level = 5 },
  zeppelin_tower = { size = 9, color = { 0.35, 0.8, 0.95 }, label = "Zeppelin tower", level = 5 },
  sky_dock = { size = 9, color = { 0.35, 0.8, 0.95 }, label = "Sky dock", level = 5 },
  dungeon = { size = 8, color = { 0.7, 0.5, 0.95 }, label = "Dungeon", level = 3 },
  raid = { size = 9, color = { 0.95, 0.4, 0.75 }, label = "Raid", level = 3 },
  battleground = { size = 8, color = { 0.95, 0.35, 0.3 }, label = "Battleground", level = 3 },
  landmark = { size = 7, color = { 0.65, 0.65, 0.65 }, label = "Landmark", level = 2 },
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
  local function Hits(x, y, width, height)
    local hits = 0
    for _, box in ipairs(taken) do
      if math.abs(x - box[1]) * 2 < width + box[3] and math.abs(y - box[2]) * 2 < height + box[4] then
        hits = hits + 1
      end
    end
    return hits
  end
  for _, key in ipairs(T.ZONE_ORDER) do
    local zone = T.ZONES[key]
    local x, y = EW.MapPoint(zone.x, zone.y)
    if x then
      x, y = x * scale, y * scale
      local width, height = #zone.name * 5.2 + 4, 11
      local best, bestHits = 0, nil
      for _, move in ipairs({ 0, 11, -11, 21, -21 }) do
        local hits = Hits(x, y + move, width, height)
        if not bestHits or hits < bestHits then best, bestHits = move, hits end
        if hits == 0 then break end
      end
      spots[key] = { x, y + best }
      taken[#taken + 1] = { x, y + best, width, height }
    end
  end
  return spots
end

--[[
Plans a trip. The two texts are what the boxes hold; the two nodes are what
was picked on the map, and a picked node wins over its box. An empty From
is where the character stands. Returns { ok = true, title, estimate, steps,
plan, from, to } where a route was found and { ok = false, message }
otherwise, with from and to where they were understood.
]]
function EW.RouteAnswer(fromText, toText, fromNode, toNode)
  local Travel = EW.Travel
  if not Travel or EW.VersionKey() ~= "forever" then
    return { ok = false, message = "The route planner covers WoW Forever only." }
  end
  fromText, toText = Trim(fromText), Trim(toText)
  local from, to = fromNode, toNode
  if not from and fromText ~= "" then from = Travel.Find(fromText) end
  if not to then
    if toText == "" then
      return { ok = false, from = from, message = "Click a place on the map, or type where you want to go." }
    end
    to = Travel.Find(toText)
  end
  if not from and fromText == "" then
    from = Travel.Here()
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
  return { ok = true, title = lines[1], estimate = lines[2], steps = steps, plan = plan, from = from, to = to }
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

--[[ Puts a ring on the map at a node, or takes it away. ]]
local function PlaceMarker(map, marker, node)
  local x, y
  if node then x, y = EW.MapNodePoint(node) end
  if not x then
    marker:Hide()
    marker.node = nil
    return
  end
  marker:ClearAllPoints()
  marker:SetPoint("CENTER", map, "TOPLEFT", x * map.scale, -y * map.scale)
  marker:Show()
  marker.node = node
end

--[[ Draws the planned way on the map, a line for each step, and the two
     rings: where the trip starts and where it ends. ]]
local function DrawRoute()
  local map = window and window.map
  if not map then return end
  -- The lines need the client's line drawing; the rings do not.
  pcall(function()
    local used = 0
    if answer and answer.ok and answer.plan then
      for _, step in ipairs(answer.plan.steps) do
        local ax, ay = EW.MapNodePoint(step.fromNode)
        local bx, by = EW.MapNodePoint(step.toNode)
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
          line:SetStartPoint("TOPLEFT", map, ax * map.scale, -ay * map.scale)
          line:SetEndPoint("TOPLEFT", map, bx * map.scale, -by * map.scale)
          line:Show()
        end
      end
    end
    for index = used + 1, #map.route do map.route[index]:Hide() end
    map.routeShown = used
  end)
  local from = picks.from or (answer and answer.from) or (EW.Travel and EW.Travel.Here()) or nil
  local to = picks.to or (answer and answer.to) or nil
  PlaceMarker(map, map.here, from)
  PlaceMarker(map, map.goal, to)
end

local function RefreshRoute()
  local frame = window
  frame.speed:SetText("Speed: " .. SPEED_LABELS[CurrentSpeed()])
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
end

local function Refresh()
  if not window then return end
  ShowAll(window.routeWidgets, page == "route")
  ShowAll(window.recordedWidgets, page == "recorded")
  if page == "route" then
    RefreshRoute()
  else
    RefreshRecorded()
  end
end

local function Plan()
  if not window then return end
  local fromText, toText = "", ""
  pcall(function()
    fromText = window.from:GetText() or ""
    toText = window.to:GetText() or ""
  end)
  answer = EW.RouteAnswer(fromText, toText, picks.from, picks.to)
  stepPage = 1
  pcall(function()
    window.from:ClearFocus()
    window.to:ClearFocus()
  end)
  Refresh()
end
EW.WindowPlan = Plan

--[[ A place or a zone was picked on the map: a click is where to go, a
     right-click is where to start. The box takes its name, and the trip is
     planned at once. ]]
function EW.WindowPick(node, mouseButton)
  if not window or type(node) ~= "string" then return end
  local name = (EW.Travel and EW.Travel.NodeName(node)) or ""
  if mouseButton == "RightButton" then
    picks.from = node
    window.from:SetText(name)
  else
    picks.to = node
    window.to:SetText(name)
  end
  Plan()
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

--[[
The map: the sea, each zone's outline in the color of whose land it is,
each zone's name, and a dot for every place. Returns the map's frame. The
outlines need the client's line drawing; where it has none, the names and
the dots are drawn without them.
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
  local scale = height / M.height
  map.scale = scale
  map.lines, map.route, map.pins, map.zones = 0, {}, {}, {}

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

  -- The zones' names. A name is a button: a click picks the zone.
  local spots = EW.MapLabelSpots(scale)
  for _, key in ipairs(T.ZONE_ORDER) do
    local zone = T.ZONES[key]
    local spot = spots[key]
    if spot then
      local color = ZONE_COLORS[zone.faction] or ZONE_COLORS.none
      local button = CreateFrame("Button", nil, map)
      button:SetSize(#zone.name * 5.2 + 4, 11)
      button:SetPoint("CENTER", map, "TOPLEFT", spot[1], -spot[2])
      pcall(function() button:SetFrameLevel(baseLevel) end)
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
      map.zones[key] = button
    end
  end

  -- The places, each a dot.
  for _, place in ipairs(T.PLACES) do
    local x, y = EW.MapPoint(place.x, place.y)
    if x then
      local style = PIN_STYLES[place.kind] or PIN_STYLES.landmark
      local pin = CreateFrame("Button", nil, map)
      pin:SetSize(style.size, style.size)
      pin:SetPoint("CENTER", map, "TOPLEFT", x * scale, -y * scale)
      pcall(function() pin:SetFrameLevel(baseLevel + style.level) end)
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
      local zone = place.zone and T.ZONES[place.zone]
      Pickable(pin, "place:" .. place.key, place.name, zone and (style.label .. ", " .. zone.name) or style.label)
      map.pins[place.key] = pin
    end
  end

  -- The two rings: where the trip starts, and where it ends.
  local function Ring(size, r, g, b)
    local ring = map:CreateTexture(nil, "OVERLAY")
    ring:SetSize(size, size)
    ring:SetTexture(MEDIA .. "ring")
    ring:SetVertexColor(r, g, b, 1)
    ring:Hide()
    return ring
  end
  map.here = Ring(20, 0.3, 1, 0.4)
  map.goal = Ring(24, 1, 0.82, 0.2)

  local hint = map:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", map, "BOTTOMLEFT", 6, 6)
  hint:SetText("Click a place to go there. Right-click a place to start from it.")
  map.hint = hint
  return map
end

local function BuildWindow()
  local forever = EW.VersionKey() == "forever" and EW.TRAVEL ~= nil and EW.TRAVEL_MAP ~= nil
  local mapHeight = EW.WINDOW_MAP_HEIGHT
  local mapWidth = 636
  if EW.TRAVEL_MAP then mapWidth = math.floor(mapHeight * EW.TRAVEL_MAP.width / EW.TRAVEL_MAP.height) end
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

  local routeWidgets, recordedWidgets = {}, {}
  local function Route(widget) routeWidgets[#routeWidgets + 1] = widget return widget end
  local function Recorded(widget) recordedWidgets[#recordedWidgets + 1] = widget return widget end

  -- The Route page: the map on the left.
  if forever then
    local ok, map = pcall(BuildMap, frame, 14, -64, mapWidth, mapHeight)
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
    end)
    return box
  end
  frame.from = Box("From", -64, "from")
  frame.to = Box("To", -104, "to")
  frame.speed = Route(Button("Speed", 150, function()
    EW.NextTravelSpeed()
    -- A new speed is a new answer to the same question.
    if answer then Plan() else Refresh() end
  end))
  frame.speed:SetPoint("TOPLEFT", frame, "TOPLEFT", column, -146)
  local plan = Route(Button("Plan Route", 110, Plan))
  plan:SetPoint("LEFT", frame.speed, "RIGHT", 8, 0)

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
  if not EnsureWindow() then return false end
  if which == "route" or which == "recorded" then page = which end
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
The button is drawn the way the game's own round minimap buttons are: a
dark disc, the icon on it, and the gold ring over both. The ring's picture
is a little different on the modern client and on the classic ones, so the
sizes follow the client. The icon is everythingwow.com's own mark.
]]
local function BuildMinimapButton()
  local button = CreateFrame("Button", "EverythingWoWMinimapButton", Minimap)
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  pcall(function() button:SetFrameLevel(8) end)
  local modern = false
  pcall(function() modern = WOW_PROJECT_ID ~= nil and WOW_PROJECT_ID == WOW_PROJECT_MAINLINE end)
  local ground = button:CreateTexture(nil, "BACKGROUND")
  ground:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(MEDIA .. "icon")
  local ring = button:CreateTexture(nil, "OVERLAY")
  ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  ring:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
  if modern then
    ring:SetSize(50, 50)
    ground:SetSize(24, 24)
    ground:SetPoint("CENTER", button, "CENTER", 0, 1)
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER", button, "CENTER", 0, 1)
  else
    ring:SetSize(53, 53)
    ground:SetSize(20, 20)
    ground:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -5)
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -6)
  end
  -- A round cut for the square icon, where the client can make one.
  pcall(function()
    local mask = button:CreateMaskTexture()
    mask:SetAllPoints(icon)
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    icon:AddMaskTexture(mask)
  end)
  button.icon, button.ring, button.modern = icon, ring, modern
  pcall(function() button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight") end)
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
