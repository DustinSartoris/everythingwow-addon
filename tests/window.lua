--[[
The window's tests, run from tests/run.lua.

The client's frames are stood in for by a frame that accepts any method,
keeps the text it is given, whether it is shown and the scripts set on it.
The window is then opened, typed into and clicked the way a player would,
and what it shows is read back. The last part proves that a client on which
the window cannot be built loses nothing: /ewow prints the status there.
]]

return function(t)
  local check, equal, stub = t.check, t.equal, t.stub

  local function MockFrame(kind, name)
    local mock = { shown = true, scripts = {}, kind = kind, name = name }
    return setmetatable(mock, { __index = function(_, key)
      if type(key) ~= "string" or not key:match("^%u") then return nil end
      if key == "SetText" then return function(self, text) self.text = text end end
      if key == "GetText" then return function(self) return self.text end end
      if key == "Show" then return function(self) self.shown = true end end
      if key == "Hide" then return function(self) self.shown = false end end
      if key == "IsShown" then return function(self) return self.shown end end
      if key == "SetScript" then return function(self, which, handler) self.scripts[which] = handler end end
      if key == "SetPoint" then return function(self, ...) self.point = { ... } end end
      if key == "SetTexture" then
        return function(self, texture)
          -- With a stand in for the minimap's files, a file that is not
          -- there is refused, as the client refuses it.
          local files = rawget(_G, "EW_TEST_TILES")
          if files and type(texture) == "string" and texture:lower():find("minimaps", 1, true) and not files(texture) then
            self.texture = nil
            return false
          end
          self.texture = texture
          return true
        end
      end
      if key == "GetTexture" then
        return function(self)
          if rawget(_G, "EW_TEST_TILES") then return self.texture end
          return nil
        end
      end
      if key == "GetEffectiveScale" then return function() return 1 end end
      if key == "GetLeft" then return function(self) return self.left or 0 end end
      if key == "GetTop" then return function(self) return self.top or 0 end end
      if key == "SetSize" then return function(self, width, height) self.size = { width, height } end end
      if key == "SetStartPoint" then return function(self, ...) self.startPoint = { ... } end end
      if key == "SetEndPoint" then return function(self, ...) self.endPoint = { ... } end end
      if key == "CreateFontString" or key == "CreateTexture" or key == "CreateMaskTexture" then
        return function() return MockFrame("Region") end
      end
      if key == "CreateLine" then
        if rawget(_G, "EW_TEST_NO_LINES") then return nil end
        return function() return MockFrame("Line") end
      end
      return function() end
    end })
  end
  local function click(widget) widget.scripts.OnClick(widget) end

  local realCreateFrame = _G.CreateFrame
  local built = {}
  _G.CreateFrame = function(kind, name, ...)
    if kind == "Frame" and name == "EverythingWoWFrame" then return realCreateFrame(kind, name, ...) end
    local frame = MockFrame(kind, name)
    built[#built + 1] = frame
    return frame
  end
  local savedMinimap, savedParent = rawget(_G, "Minimap"), rawget(_G, "UIParent")
  rawset(_G, "Minimap", MockFrame("Minimap"))
  rawset(_G, "UIParent", MockFrame("Frame", "UIParent"))

  local EW = t.LoadFreshAddon(2, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  EW.WINDOW_STEP_ROWS = 2

  -- The answers, before any window.
  equal("no destination asks for one", EW.RouteAnswer("Orgrimmar", "  ").message, "Click a place on the map, or type where you want to go.")
  equal("a place not on the map is refused in the site's words",
    EW.RouteAnswer("Orgrimmar", "Shattrath").message, "That place is not on this map.")
  stub.state.map = nil
  equal("an empty From on an unknown map asks for the start",
    EW.RouteAnswer("", "Undercity").message, "The planner does not know the map you are on. Right-click a place to start from it, or type it.")
  stub.state.map = 1454
  local found = EW.RouteAnswer("", "undercity")
  equal("an empty From is where the character stands", found.title, "Orgrimmar to Undercity (On foot)")
  check("with the estimate", found.estimate:find("^Estimated travel time ") ~= nil, found.estimate)
  check("and the numbered steps", #found.steps >= 2 and found.steps[1]:find("^1%. Orgrimmar to ") ~= nil, found.steps[1])
  equal("one place twice is the planner's own refusal", EW.RouteAnswer("Undercity", "undercity").message, "Pick two different places.")

  -- /ewow opens the window.
  stub.state.printed = {}
  EW.SlashCommand("")
  check("a bare /ewow builds the window", EW.window ~= nil, EW.windowError)
  local window = EW.window
  equal("and shows it", window:IsShown(), true)
  equal("it prints nothing", #stub.state.printed, 0)
  equal("it opens on the Route page, asking where to", window.heading.text, "Where to?")
  equal("the speed button says the speed", window.speed.text, "Speed: On foot")
  equal("the Recorded page's lines are hidden", window.held:IsShown(), false)

  -- Typing a trip and planning it.
  window.from:SetText("Orgrimmar")
  window.to:SetText("Undercity")
  EW.WindowPlan()
  equal("the heading is the trip", window.heading.text, "Orgrimmar to Undercity (On foot)")
  check("the estimate is under it", window.estimate.text:find("^Estimated travel time ") ~= nil, window.estimate.text)
  check("the first step is in the first row", window.steps[1].text:find("^1%. Orgrimmar to ") ~= nil, window.steps[1].text)
  equal("a second row holds the second step", window.steps[2]:IsShown(), true)
  local plan = EW.RouteAnswer("Orgrimmar", "Undercity")
  check("a trip of more steps than rows is paged", #plan.steps > 2 and window.pageText:IsShown() and window.pageText.text == "Page 1 of " .. math.ceil(#plan.steps / 2), window.pageText.text)
  click(window.next)
  check("Next shows the third step", window.steps[1].text:find("^3%. ") ~= nil, window.steps[1].text)
  click(window.next)
  click(window.next)
  click(window.next)
  equal("Next stops at the last page", window.pageText.text, string.format("Page %d of %d", math.ceil(#plan.steps / 2), math.ceil(#plan.steps / 2)))
  click(window.prev)
  click(window.prev)
  click(window.prev)
  click(window.prev)
  equal("Previous stops at the first", window.pageText.text:match("^Page (%d+)"), "1")

  -- Enter in a box plans too.
  window.to:SetText("Thunder Bluff")
  window.to.scripts.OnEnterPressed(window.to)
  equal("Enter in the To box plans the trip", window.heading.text, "Orgrimmar to Thunder Bluff (On foot)")

  -- The speed button goes round the four and plans again.
  click(window.speed)
  equal("a click sets the next speed", EW.Database().travelSpeed, "travel_form")
  equal("the button says so", window.speed.text, "Speed: Travel form")
  equal("and the trip is planned again at it", window.heading.text, "Orgrimmar to Thunder Bluff (Travel form)")
  click(window.speed)
  click(window.speed)
  equal("the fourth speed", window.speed.text, "Speed: Mount 100%")
  click(window.speed)
  equal("then round to the first", window.speed.text, "Speed: On foot")

  -- A refusal is shown as the heading, with no steps.
  window.to:SetText("Shattrath")
  EW.WindowPlan()
  equal("a refusal takes the heading", window.heading.text, "That place is not on this map.")
  equal("with no estimate", window.estimate.text, "")
  equal("and no step", window.steps[1]:IsShown(), false)
  equal("and no paging", window.pageText:IsShown(), false)

  -- The map: every zone's outline, every zone's name, a dot for every place.
  local map = window.map
  check("the Route page has a map", map ~= nil, EW.mapError)
  local M, T = EW.TRAVEL_MAP, EW.TRAVEL
  local segments = 0
  for _, zoneRings in pairs(M.OUTLINES) do
    for _, ring in ipairs(zoneRings) do segments = segments + #ring / 2 end
  end
  equal("a line for every side of every outline", map.lines, segments)
  check("of which there are several hundred, not thousands", segments > 400 and segments < 1500, segments)
  local pins, inside = 0, true
  for key, pin in pairs(map.pins) do
    pins = pins + 1
    local x, y = pin.point[4], -pin.point[5]
    if x < 0 or y < 0 or x > EW.WINDOW_MAP_HEIGHT * M.width / M.height or y > EW.WINDOW_MAP_HEIGHT then inside = false end
  end
  equal("a dot for every place the planner knows", pins, #T.PLACES)
  check("every dot lies on the map", inside)
  local names = 0
  for _ in pairs(map.zones) do names = names + 1 end
  equal("a name for every zone", names, #T.ZONE_ORDER)
  for key, zoneRings in pairs(M.OUTLINES) do
    for _, ring in ipairs(zoneRings) do
      for index = 1, #ring, 2 do
        if ring[index] < 0 or ring[index] > M.width or ring[index + 1] < 0 or ring[index + 1] > M.height then
          check("the outline of " .. key .. " lies on the map", false, ring[index] .. " " .. ring[index + 1])
        end
      end
    end
  end
  local function near(a, b) return math.abs(a - b) < 0.01 end
  local scale = EW.WINDOW_MAP_HEIGHT / M.height
  local orgX, orgY = EW.MapPoint(710.8, 720)
  check("a place west of every cut keeps its spot, less the origin", near(orgX, 710.8 - M.originX) and near(orgY, 720 - M.originY))
  local moved = 0
  for _, cut in ipairs(M.CUTS) do moved = moved + cut.shift end
  local eastX = EW.MapPoint(2000, 500)
  check("a place east of every cut is moved west by all of them", near(eastX, 2000 - moved - M.originX))
  local orgrimmar = map.pins.orgrimmar
  check("Orgrimmar's dot is at Orgrimmar",
    orgrimmar.point[1] == "CENTER" and orgrimmar.point[2] == map and near(orgrimmar.point[4], orgX * scale) and near(orgrimmar.point[5], -orgY * scale))
  equal("it carries the planner's own node", orgrimmar.node, "place:orgrimmar")
  equal("and its name for the tooltip", orgrimmar.tipName, "Orgrimmar")
  equal("with what it is and where", orgrimmar.tipKind, "Capital, Durotar")
  equal("its picture is the addon's own dot", orgrimmar.scripts.OnEnter ~= nil and EW.MEDIA, "Interface\\AddOns\\EverythingWoW\\Media\\")
  equal("the map says how to use it", map.hint.text, "Click where you start, then where you want to go. Right-click: go there from where you stand. Wheel: zoom. Drag: move.")
  equal("and has a key of seven kinds of dot", #map.key, 7)
  equal("which begins with the capitals", map.key[1].text, "Capital")

  -- A right-click on a place goes there from where the character stands.
  stub.state.map = 1454
  window.from:SetText("")
  window.to:SetText("")
  map.pins.undercity.scripts.OnClick(map.pins.undercity, "RightButton")
  equal("a right-click on a place plans the trip there from where the character stands", window.heading.text, "Orgrimmar to Undercity (On foot)")
  equal("and writes its name in the To box", window.to.text, "Undercity")
  local drawn = EW.RouteAnswer("", "", nil, "place:undercity")
  check("the way is drawn, a line a step", map.routeShown >= 2 and map.routeShown <= #drawn.plan.steps, map.routeShown)
  equal("each line shown", map.route[1]:IsShown(), true)
  local firstStep = drawn.plan.steps[1]
  local ax, ay = EW.MapNodePoint(firstStep.fromNode)
  check("the first line starts where the first step starts",
    near(map.route[1].startPoint[3], ax * scale) and near(map.route[1].startPoint[4], -ay * scale))
  equal("the gold ring is on the destination", map.goal.node, "place:undercity")
  equal("shown", map.goal:IsShown(), true)
  equal("the green ring is where the trip starts", map.here.node, "place:orgrimmar")
  equal("and says so", map.hereText.text, "You are here")
  equal("the From box's caption says where the trip starts", window.fromCaption.text, "From (where you stand: Orgrimmar)")

  -- The first click is where the trip starts, the second where it ends.
  map.pins.bootybay.scripts.OnClick(map.pins.bootybay, "LeftButton")
  equal("a click is where the trip starts", window.from.text, "Booty Bay")
  equal("the trip before it is put away", window.to.text, "")
  equal("the window says where from", window.heading.text, "From Booty Bay")
  equal("and asks for the end", window.estimate.text, "Now click where you want to go.")
  equal("no way is drawn yet", map.routeShown, 0)
  equal("nor a gold ring", map.goal:IsShown(), false)
  equal("the green ring moves to the start", map.here.node, "place:bootybay")
  equal("and is named the start", map.hereText.text, "Start")
  equal("the caption is plain once a start is picked", window.fromCaption.text, "From")
  equal("the end is waited for", EW.MapClickStage(), 1)
  equal("no trip is in hand between the clicks", EW.trip, nil)
  map.pins.bootybay.scripts.OnClick(map.pins.bootybay, "LeftButton")
  equal("the start clicked again is no trip, and the end is still waited for", window.heading.text, "From Booty Bay")
  map.pins.undercity.scripts.OnClick(map.pins.undercity, "LeftButton")
  equal("the second click is where it ends, and the trip is planned", window.heading.text, "Booty Bay to Undercity (On foot)")
  equal("its name is in the To box", window.to.text, "Undercity")
  equal("the gold ring is on it", map.goal.node, "place:undercity")
  equal("nothing is waited for", EW.MapClickStage(), 0)

  -- A click after that starts a new trip.
  map.pins.orgrimmar.scripts.OnClick(map.pins.orgrimmar, "LeftButton")
  equal("a third click starts a new trip", window.heading.text, "From Orgrimmar")
  equal("with the old end gone", window.to.text, "")
  map.pins.bootybay.scripts.OnClick(map.pins.bootybay, "LeftButton")
  equal("and the fourth ends it", window.heading.text, "Orgrimmar to Booty Bay (On foot)")

  -- A right-click between the two clicks is still the short way.
  map.pins.bootybay.scripts.OnClick(map.pins.bootybay, "LeftButton")
  map.pins.undercity.scripts.OnClick(map.pins.undercity, "RightButton")
  equal("a right-click drops the start that was clicked", window.from.text, "")
  equal("and goes from where the character stands", window.heading.text, "Orgrimmar to Undercity (On foot)")
  equal("with nothing waited for", EW.MapClickStage(), 0)

  -- Clear puts the window back as it opened.
  map.pins.bootybay.scripts.OnClick(map.pins.bootybay, "LeftButton")
  click(window.clear)
  equal("Clear empties the From box", window.from.text, "")
  equal("and the To box", window.to.text, "")
  equal("and asks where to", window.heading.text, "Where to?")
  equal("and how", window.estimate.text, "Click where you start, then where you want to go. Right-click a place to go there from where you stand.")
  equal("with no way drawn", map.routeShown, 0)
  equal("no gold ring", map.goal:IsShown(), false)
  equal("and the green ring back where the character stands", map.here.node, "place:orgrimmar")
  equal("a start that was waited on is forgotten", EW.MapClickStage(), 0)

  -- A zone's name can be picked too.
  map.pins.bootybay.scripts.OnClick(map.pins.bootybay, "LeftButton")
  map.zones.westfall.scripts.OnClick(map.zones.westfall, "LeftButton")
  equal("a click on a zone's name goes to the zone", window.heading.text, "Booty Bay to Westfall (On foot)")
  equal("the ring is on the zone's middle", map.goal.node, "zone:westfall")

  -- A typed name takes the place of a picked one.
  window.to.scripts.OnTextChanged(window.to, false)
  window.to:SetText("Thunder Bluff")
  EW.WindowPlan()
  equal("text set by the window itself does not undo a pick", window.heading.text, "Booty Bay to Westfall (On foot)")
  window.to.scripts.OnTextChanged(window.to, true)
  window.from.scripts.OnTextChanged(window.from, true)
  window.from:SetText("Orgrimmar")
  EW.WindowPlan()
  equal("a typed name takes the place of a picked one", window.heading.text, "Orgrimmar to Thunder Bluff (On foot)")

  -- A refusal draws no way.
  window.to:SetText("Shattrath")
  EW.WindowPlan()
  equal("a refusal draws no way", map.routeShown, 0)
  equal("and hides the lines of the last one", map.route[1]:IsShown(), false)
  equal("and the gold ring", map.goal:IsShown(), false)

  -- The Recorded page hides the map.
  EW.ShowWindow("recorded")
  equal("the Recorded page puts the map away", map:IsShown(), false)
  EW.ShowWindow("route")
  equal("and the Route page brings it back", map:IsShown(), true)

  -- The Recorded page.
  EW.Record("npc", "npc", 3100, 1411, 0.5, 0.5, { name = "Elder Mottled Boar" })
  EW.Record("npc", "npc", 3101, 1411, 0.5, 0.5, { name = "Mottled Boar" })
  EW.Record("flight", "flight", nil, 1454, 0.4, 0.6, { from = "A", to = "B", s = 60, f = "horde" })
  local rows, held, dropped = EW.RecordedRows()
  equal("three observations are held", held, 3)
  equal("none dropped", dropped, 0)
  equal("the kinds come in the file's order with the site's labels", rows[1][1] .. " " .. rows[1][2], "NPC Sightings 2")
  equal("flights among them", rows[2][1] .. " " .. rows[2][2], "Flight Paths 1")
  EW.ShowWindow("recorded")
  equal("the Recorded page says how much is held", window.held.text, "3 observations held, 0 dropped to keep the file small.")
  check("and how far the flight recorder has got", window.travel.text:find("flight recorder:", 1, true) ~= nil, window.travel.text)
  check("and the ride recorder", window.travel.text:find("ride recorder:", 1, true) ~= nil, window.travel.text)
  equal("its first line is the first kind", window.kinds[1].text, "NPC Sightings: 2")
  equal("the second the second", window.kinds[2].text, "Flight Paths: 1")
  equal("lines with no kind are hidden", window.kinds[3]:IsShown(), false)
  equal("the Route page's widgets are hidden", window.heading:IsShown(), false)
  equal("the empty note is hidden when something is held", window.none:IsShown(), false)
  EW.SlashCommand("clear")
  stub.state.printed = {}
  EW.ShowWindow("recorded")
  equal("an empty file says so", window.none:IsShown(), true)
  equal("and counts nothing", window.held.text, "0 observations held, 0 dropped to keep the file small.")

  -- /ewow route with no place opens the Route page.
  EW.SlashCommand("route")
  equal("/ewow route with no place shows the Route page", window.heading:IsShown(), true)
  equal("and prints nothing", #stub.state.printed, 0)

  -- Toggling.
  equal("the window is open", window:IsShown(), true)
  EW.ToggleWindow()
  equal("a toggle closes it", window:IsShown(), false)
  EW.ToggleWindow()
  equal("and opens it again", window:IsShown(), true)

  -- The button on the minimap.
  equal("no minimap button before the world is entered", EW.minimapButton, nil)
  stub.Fire("PLAYER_ENTERING_WORLD")
  check("entering the world builds the minimap button", EW.minimapButton ~= nil)
  local button = EW.minimapButton
  equal("and shows it", button:IsShown(), true)
  equal("anchored to the minimap", button.point[2], _G.Minimap)
  equal("it is one picture, the site's mark cut round with its rim", button.icon.texture, "Interface\\AddOns\\EverythingWoW\\Media\\minimap")
  check("set in the middle of the button", button.icon.point[1] == "CENTER" and button.icon.point[2] == button and button.icon.point[4] == 0 and button.icon.point[5] == 0)
  check("at the size of the game's own round buttons, inside a button a little larger",
    button.icon.size[1] == 24 and button.icon.size[2] == 24 and button.size[1] == 31)
  equal("with no ring apart from it to fall out of line", button.ring, nil)
  equal("with no size to read it sits 80 from the middle", EW.MinimapRadius(), 80)
  _G.Minimap.GetWidth = function() return 140 end
  equal("on a minimap 140 wide it sits 75 from the middle, just past the edge", EW.MinimapRadius(), 75)
  _G.Minimap.GetWidth = function() return 198 end
  equal("on one 198 wide, 104", EW.MinimapRadius(), 104)
  EW.RefreshMinimapButton()
  check("and is put there",
    math.abs(button.point[4] - math.cos(math.rad(215)) * 104) < 0.001 and math.abs(button.point[5] - math.sin(math.rad(215)) * 104) < 0.001)
  _G.Minimap.GetWidth = nil
  EW.RefreshMinimapButton()
  local function near(a, b) return math.abs(a - b) < 0.001 end
  check("at its first place on the edge, lower left",
    near(button.point[4], math.cos(math.rad(215)) * 80) and near(button.point[5], math.sin(math.rad(215)) * 80))
  stub.Fire("PLAYER_ENTERING_WORLD")
  equal("entering the world again builds no second button", EW.minimapButton, button)

  -- Dragging it round the edge.
  equal("straight right of the middle is 0 degrees", EW.MinimapAngleOf(150, 100, 100, 100), 0)
  equal("straight up is 90", EW.MinimapAngleOf(100, 180, 100, 100), 90)
  equal("straight left is 180", EW.MinimapAngleOf(20, 100, 100, 100), 180)
  equal("straight down is 270", EW.MinimapAngleOf(100, 20, 100, 100), 270)
  local savedCursor = rawget(_G, "GetCursorPosition")
  rawset(_G, "GetCursorPosition", function() return 400, 600 end)
  _G.Minimap.GetEffectiveScale = function() return 2 end
  _G.Minimap.GetCenter = function() return 200, 200 end
  equal("no drag, no update script", button.scripts.OnUpdate, nil)
  button.scripts.OnDragStart(button)
  check("a drag starts following the pointer", type(button.scripts.OnUpdate) == "function")
  button.scripts.OnUpdate(button)
  equal("the pointer straight above the minimap puts the button at 90 degrees", EW.Database().minimapAngle, 90)
  check("and moves it there", near(button.point[4], 0) and near(button.point[5], 80), tostring(button.point[4]) .. " " .. tostring(button.point[5]))
  button.scripts.OnDragStop(button)
  equal("letting go stops following", button.scripts.OnUpdate, nil)
  rawset(_G, "GetCursorPosition", function() return nil end)
  button.scripts.OnDragStart(button)
  button.scripts.OnUpdate(button)
  equal("a pointer the client cannot place moves nothing", EW.Database().minimapAngle, 90)
  button.scripts.OnDragStop(button)
  rawset(_G, "GetCursorPosition", savedCursor)
  window:Hide()
  click(button)
  equal("a click on it opens the window", window:IsShown(), true)
  click(button)
  equal("another closes it", window:IsShown(), false)
  EW.SlashCommand("minimap")
  equal("/ewow minimap hides the button", button:IsShown(), false)
  equal("and remembers it", EW.Database().minimapHidden, true)
  check("and says how to bring it back", stub.state.printed[#stub.state.printed]:find("/ewow minimap shows it again", 1, true) ~= nil)
  EW.SlashCommand("minimap")
  equal("/ewow minimap again shows it", button:IsShown(), true)
  equal("and forgets the flag", EW.Database().minimapHidden, nil)
  stub.state.printed = {}

  -- /ewow status still prints.
  EW.SlashCommand("status")
  check("/ewow status still prints the status", #stub.state.printed > 3)
  stub.state.printed = {}

  -- Off WoW Forever the Route page says where the planner works.
  _G.CreateFrame = function(kind, name, ...)
    if kind == "Frame" and name == "EverythingWoWFrame" then return realCreateFrame(kind, name, ...) end
    return MockFrame(kind, name)
  end
  local retail = t.LoadFreshAddon(1, { "12.1.0", "60000", "Sep 17 2026", 120100 })
  equal("on another client the answer says where the planner works",
    retail.RouteAnswer("Orgrimmar", "Undercity").message, "The route planner covers WoW Forever only.")
  retail.SlashCommand("")
  check("the window still opens there", retail.window ~= nil and retail.window:IsShown())
  equal("on the Recorded page, which every client has", retail.window.held:IsShown(), true)
  equal("with the Route page put away", retail.window.heading:IsShown(), false)
  retail.SlashCommand("route")
  equal("/ewow route there shows the Route page", retail.window.heading:IsShown(), true)
  retail.WindowPlan()
  equal("which says where the planner works", retail.window.heading.text, "The route planner covers WoW Forever only.")
  equal("no map is drawn there", retail.window.map, nil)
  equal("and a note stands in its place", retail.window.mapNote.text, "The map and the route planner cover WoW Forever only.")

  -- A client that cannot draw lines still gets the names, the dots and the trip.
  rawset(_G, "EW_TEST_NO_LINES", true)
  local lineless = t.LoadFreshAddon(2, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  stub.state.map = 1454
  lineless.SlashCommand("")
  check("without line drawing the map is still built", lineless.window ~= nil and lineless.window.map ~= nil, lineless.mapError)
  equal("with no outline", lineless.window.map.lines, 0)
  check("but every dot", lineless.window.map.pins.orgrimmar ~= nil)
  local linelessMap = lineless.window.map
  linelessMap.pins.undercity.scripts.OnClick(linelessMap.pins.undercity, "RightButton")
  equal("a click still plans the trip", lineless.window.heading.text, "Orgrimmar to Undercity (On foot)")
  equal("and the ring still marks the destination", linelessMap.goal.node, "place:undercity")
  rawset(_G, "EW_TEST_NO_LINES", nil)

  -- The game's own map, where the client can give its pictures and place
  -- the zones: tests/fakeworld.lua stands in for the client's maps.
  local real = t.LoadFreshAddon(2, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  local world = dofile(t.root .. "tests/fakeworld.lua")(real)
  stub.state.map = 1454
  real.SlashCommand("")
  local realMap = real.window and real.window.map
  check("where the client gives its pictures, the window shows the game's own map",
    realMap ~= nil and realMap.real == true, tostring(real.realMapError or real.mapError))
  local mapWide, mapHigh = real.WINDOW_MAP_WIDTH, real.WINDOW_MAP_HEIGHT
  equal("it opens on the continent the character is on", realMap.continent, world.KALIMDOR)
  equal("with a button for each continent", #realMap.tabs, 2)
  equal("named as the client names it", realMap.tabs[2].text, "Eastern Kingdoms")
  local west = realMap.sheets[world.KALIMDOR]
  equal("the continent is twelve pictures", #west.tiles, 12)
  equal("the client's own files", west.tiles[2].texture, world.KALIMDOR * 100 + 2)
  check("laid out from the corner", west.tiles[1].point[1] == "TOPLEFT" and west.tiles[1].point[4] == 0 and west.tiles[1].point[5] == 0)
  check("the second a tile to the right", near(west.tiles[2].point[4], 256 / 1002 * mapWide) and west.tiles[2].point[5] == 0)
  check("the fifth a tile down", west.tiles[5].point[4] == 0 and near(west.tiles[5].point[5], -256 / 668 * mapHigh))
  equal("the other continent is not made until it is asked for", realMap.sheets[world.EASTERN], nil)
  local realX, realY = real.Places.Spot("orgrimmar", world.KALIMDOR)
  check("Orgrimmar's dot is where the client says Orgrimmar is",
    near(realMap.pins.orgrimmar.point[4], realX * mapWide) and near(realMap.pins.orgrimmar.point[5], -realY * mapHigh))
  equal("a place of the other continent has no dot here", realMap.pins.undercity, nil)
  check("a zone of this continent has its name", realMap.zones.durotar ~= nil and realMap.zones.westfall == nil)
  equal("a place put by its neighbors says so", realMap.pins["senjin-village"].estimated, true)
  check("in its tooltip", realMap.pins["senjin-village"].tipKind:find("its spot is an estimate", 1, true) ~= nil, realMap.pins["senjin-village"].tipKind)
  equal("a place with a real spot does not", realMap.pins.orgrimmar.tipKind, "Capital, Durotar")
  check("the green ring is where the character really stands",
    near(realMap.here.point[4], 0.61 * mapWide) and near(realMap.here.point[5], -0.44 * mapHigh))
  equal("and says so", realMap.hereText.text, "You are here")

  realMap.pins.ratchet.scripts.OnClick(realMap.pins.ratchet, "RightButton")
  equal("a click on a place plans the trip there", real.window.heading.text, "Orgrimmar to Ratchet (On foot)")
  check("the way is drawn on the real map", realMap.routeShown >= 1, realMap.routeShown)
  local ratchetX, ratchetY = real.Places.Spot("ratchet", world.KALIMDOR)
  check("and the gold ring is on the place itself",
    near(realMap.goal.point[4], ratchetX * mapWide) and near(realMap.goal.point[5], -ratchetY * mapHigh))

  click(realMap.tabs[2])
  equal("the second button shows the other continent", realMap.continent, world.EASTERN)
  equal("the first continent's dots are put away", west.pins.orgrimmar:IsShown(), false)
  equal("and its pictures", west.tiles[1]:IsShown(), false)
  check("the other continent's dots are there", realMap.pins.undercity ~= nil and realMap.pins.undercity:IsShown() == true)
  equal("its pictures are its own", realMap.sheets[world.EASTERN].tiles[1].texture, world.EASTERN * 100 + 1)
  equal("a way that lies on the first continent is not drawn on the second", realMap.routeShown, 0)
  equal("nor the rings", realMap.goal:IsShown(), false)
  equal("the character is not on this continent, so no green ring", realMap.here:IsShown(), false)
  realMap.pins.undercity.scripts.OnClick(realMap.pins.undercity, "RightButton")
  equal("a click there plans the trip across the sea", real.window.heading.text, "Orgrimmar to Undercity (On foot)")
  equal("the gold ring marks it", realMap.goal.node, "place:undercity")
  click(realMap.tabs[1])
  equal("the first button brings the first continent back", west.pins.orgrimmar:IsShown(), true)
  equal("with the second's dots put away", realMap.sheets[world.EASTERN].pins.undercity:IsShown(), false)
  equal("and the green ring on the character again", realMap.here:IsShown(), true)
  equal("the destination is on the other side, so no gold ring here", realMap.goal:IsShown(), false)

  -- Nothing the window keeps on a frame may take the name of one of the
  -- frame's own calls: 0.4.0 kept its "show this continent" under Show, and
  -- the map could not be shown again once the Route page had been left.
  for _, own in ipairs({ "Show", "Hide", "IsShown", "SetPoint", "SetSize", "SetScript", "GetParent", "SetShown", "IsVisible", "SetScale", "GetWidth", "GetHeight", "Enable", "Disable", "SetText", "GetText", "Clear", "Raise", "Lower" }) do
    check("the map keeps nothing under the frame's own " .. own, rawget(realMap, own) == nil)
    check("nor the window", rawget(real.window, own) == nil)
  end

  -- Leaving the Route page and coming back brings the real map back.
  real.ShowWindow("recorded")
  equal("the Recorded page puts the real map away", realMap:IsShown(), false)
  real.ShowWindow("route")
  equal("and coming back to the Route page shows it again", realMap:IsShown(), true)
  equal("on the continent it was on", realMap.continent, world.KALIMDOR)
  equal("with its dots", realMap.pins.orgrimmar:IsShown(), true)
  click(realMap.tabs[2])
  real.ShowWindow("recorded")
  real.ShowWindow("route")
  equal("or on the other, if that was the one shown", realMap.continent, world.EASTERN)
  equal("still there", realMap:IsShown(), true)
  click(realMap.tabs[1])

  -- On a client that does not give the ground's pictures, the map still zooms.
  equal("this client gave no picture of the ground", real.terrain.ok, false)
  check("and the status line says which was asked for",
    real.TerrainReport():find("terrain map: off, the client gave no picture for world/minimaps/", 1, true) ~= nil, real.TerrainReport())
  equal("so the map zooms no further than its own picture is worth", realMap.zoomMax, real.MAP_ZOOM_MAX_DRAWN)
  realMap.zoomTo(100)
  equal("the zoom stops there", realMap.zoom, real.MAP_ZOOM_MAX_DRAWN)
  equal("with no square of the ground drawn", realMap.terrainShown, 0)
  click(realMap.tabs[1])
  equal("a continent's button shows it whole again", realMap.zoom, 1)

  -- A client that gives the minimap's pictures of the ground.
  local asked = {}
  rawset(_G, "EW_TEST_TILES", function(name)
    asked[#asked + 1] = name
    if name:find("^world/minimaps/kalimdor/map%d%d_%d%d%.blp$") == nil then return false end
    return name ~= "world/minimaps/kalimdor/map22_22.blp"
  end)
  local savedPointer = rawget(_G, "GetCursorPosition")
  local pointerX, pointerY = nil, nil
  rawset(_G, "GetCursorPosition", function() return pointerX, pointerY and -pointerY end)
  local grounded = t.LoadFreshAddon(2, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  stub.state.map = 1454
  grounded.SlashCommand("")
  local gmap = grounded.window.map
  check("the window's map is the real one", gmap ~= nil and gmap.real == true, tostring(grounded.realMapError))
  equal("the client was asked for the square a capital stands on, and gave it", grounded.terrain.ok, true)
  check("by its name in the minimap's folder", grounded.terrain.name:find("^world/minimaps/kalimdor/map%d%d_%d%d%.blp$") ~= nil, grounded.terrain.name)
  check("and the status line says so", grounded.TerrainReport():find("terrain map: on (world/minimaps/kalimdor/", 1, true) ~= nil)
  equal("so the map zooms all the way in", gmap.zoomMax, grounded.MAP_ZOOM_MAX)
  equal("it opens on the whole continent", gmap.zoom, 1)
  equal("where a square of the ground is too small to draw", gmap.terrainShown, 0)
  local GP = grounded.Places
  local orgX, orgY = GP.Spot("orgrimmar", world.KALIMDOR)

  -- The wheel zooms about the pointer, or the middle where there is none.
  gmap.scripts.OnMouseWheel(gmap, 1)
  equal("a turn of the wheel zooms in by a step", gmap.zoom, 1.5)
  check("about the middle of the window", near(gmap.offsetX, -(1.5 - 1) * mapWide / 2) and near(gmap.offsetY, -(1.5 - 1) * mapHigh / 2))
  check("Orgrimmar's dot moves with the map",
    near(gmap.pins.orgrimmar.point[4], orgX * mapWide * 1.5 + gmap.offsetX) and near(gmap.pins.orgrimmar.point[5], -(orgY * mapHigh * 1.5 + gmap.offsetY)))
  local firstTile = gmap.sheets[world.KALIMDOR].tiles[1]
  check("the continent's pictures grow with it", near(firstTile.size[1], 256 / 1002 * mapWide * 1.5) and near(firstTile.point[4], gmap.offsetX))
  gmap.scripts.OnMouseWheel(gmap, -1)
  equal("a turn back zooms out", gmap.zoom, 1)
  check("to where it was", gmap.offsetX == 0 and gmap.offsetY == 0)
  gmap.scripts.OnMouseWheel(gmap, -1)
  equal("and no further than the whole continent", gmap.zoom, 1)
  -- One step in, a square of the ground is still too small, however many
  -- of them the window may hold.
  local savedMost = grounded.TERRAIN_TILES_MAX
  grounded.TERRAIN_TILES_MAX = 100000
  gmap.zoomTo(1.5)
  equal("a square narrower than it is worth drawing is not drawn", gmap.terrainShown, 0)
  grounded.TERRAIN_TILES_MAX = savedMost
  gmap.zoomTo(1)
  pointerX, pointerY = orgX * mapWide, orgY * mapHigh
  gmap.scripts.OnMouseWheel(gmap, 1)
  gmap.scripts.OnMouseWheel(gmap, 1)
  check("zooming with the pointer on Orgrimmar keeps Orgrimmar under the pointer",
    near(gmap.pins.orgrimmar.point[4], pointerX) and near(gmap.pins.orgrimmar.point[5], -pointerY))
  equal("two steps in", gmap.zoom, 2.25)

  -- A dot that has run out of the window is put away.
  local out, outKey = 0, nil
  for key, pin in pairs(gmap.pins) do
    local x, y = pin.point[4], -pin.point[5]
    local inside = x >= -12 and x <= mapWide + 12 and y >= -12 and y <= mapHigh + 12
    if not inside then out, outKey = out + 1, key end
    if pin:IsShown() ~= inside then outKey = "wrong:" .. key end
  end
  check("zoomed in, some dots lie outside the window", out > 0, out)
  check("and exactly those are put away", outKey ~= nil and not tostring(outKey):find("^wrong:"), outKey)
  equal("Orgrimmar's, under the pointer, is shown", gmap.pins.orgrimmar:IsShown(), true)

  -- Zoomed in far enough, the ground itself is drawn.
  local shownTiles = 0
  for _ in pairs(gmap.ground) do shownTiles = shownTiles + 1 end
  check("at that zoom the ground's own pictures are drawn", gmap.terrainShown > 4 and gmap.terrainShown == shownTiles, gmap.terrainShown)
  check("no more of them than the window holds", gmap.terrainShown <= grounded.TERRAIN_TILES_MAX)
  local x0, y0 = -gmap.offsetX / (mapWide * gmap.zoom), -gmap.offsetY / (mapHigh * gmap.zoom)
  local columnA, columnB, rowA, rowB = GP.TileRange(world.KALIMDOR, x0, y0, x0 + 1 / gmap.zoom, y0 + 1 / gmap.zoom)
  local inRange, placed = true, true
  for key, picture in pairs(gmap.ground) do
    local column, row = picture.square[1], picture.square[2]
    if key ~= column * 64 + row or column < columnA or column > columnB or row < rowA or row > rowB then inRange = false end
    local bx0, by0, bx1, by1 = GP.TileBox(world.KALIMDOR, column, row)
    if picture.texture ~= string.format("world/minimaps/kalimdor/map%02d_%02d.blp", column, row)
      or not near(picture.point[4], bx0 * mapWide * gmap.zoom + gmap.offsetX)
      or not near(picture.point[5], -(by0 * mapHigh * gmap.zoom + gmap.offsetY))
      or not near(picture.size[1], (bx1 - bx0) * mapWide * gmap.zoom) or picture:IsShown() ~= true then
      placed = false
    end
  end
  check("each is a square in view", inRange)
  check("each the client's own file, laid where the client says the square is", placed)
  equal("a square is a third of 1,600 yards a side", GP.TILE_YARDS, 1600 / 3)
  local bx0, _, bx1 = GP.TileBox(world.KALIMDOR, 30, 30)
  check("which the stand in world makes a known part of the continent", near(bx1 - bx0, GP.TILE_YARDS / 10000))

  -- A square with no picture, as the sea has none, is left to the map under it.
  gmap.zoomTo(1)
  gmap.zoomTo(2.25, (32 - 22 - 0.5) * GP.TILE_YARDS / 10000 * mapWide, (32 - 22 - 0.5) * GP.TILE_YARDS / 10000 * mapHigh)
  check("the ground is drawn about the missing square", gmap.terrainShown > 4, gmap.terrainShown)
  equal("but the missing square itself is not", gmap.ground[22 * 64 + 22], nil)
  local asksBefore = #asked
  gmap.moveTo(gmap.offsetX + 1, gmap.offsetY)
  local again = 0
  for index = asksBefore + 1, #asked do
    if asked[index]:find("map22_22", 1, true) then again = again + 1 end
  end
  equal("and the client is not asked for it again at every move", again, 0)

  -- Dragging moves the map; a click that was no drag picks the ground.
  gmap.zoomTo(1)
  gmap.zoomTo(2.25)
  local beforeX, beforeY = gmap.offsetX, gmap.offsetY
  pointerX, pointerY = 300, 200
  gmap.scripts.OnMouseDown(gmap, "LeftButton")
  pointerX, pointerY = 260, 180
  gmap.scripts.OnUpdate(gmap)
  check("a drag moves the map with the pointer", near(gmap.offsetX, beforeX - 40) and near(gmap.offsetY, beforeY - 20))
  gmap.scripts.OnMouseUp(gmap, "LeftButton")
  equal("and letting go after a drag picks nothing", grounded.MapClickStage(), 0)
  equal("the drag is over", gmap.scripts.OnUpdate, nil)
  gmap.moveTo(5000, 5000)
  check("the map cannot be dragged past its own corner", gmap.offsetX == 0 and gmap.offsetY == 0)
  gmap.moveTo(-50000, -50000)
  check("nor past the far one", near(gmap.offsetX, mapWide - mapWide * 2.25) and near(gmap.offsetY, mapHigh - mapHigh * 2.25))
  gmap.zoomTo(1)
  local durotar, barrens = world.rect[grounded.Places.ZoneMap("durotar")], world.rect[grounded.Places.ZoneMap("barrens")]
  equal("the client names the zone at a spot", GP.ZoneAt(world.KALIMDOR, (durotar[1] + durotar[3]) / 2, (durotar[2] + durotar[4]) / 2), "durotar")
  equal("and none in the sea", GP.ZoneAt(world.KALIMDOR, 0.001, 0.999), nil)
  pointerX, pointerY = (durotar[1] + durotar[3]) / 2 * mapWide, (durotar[2] + durotar[4]) / 2 * mapHigh
  gmap.scripts.OnMouseDown(gmap, "LeftButton")
  gmap.scripts.OnMouseUp(gmap, "LeftButton")
  equal("a click on the ground starts the trip in the zone there", grounded.window.heading.text, "From Durotar")
  pointerX, pointerY = barrens[1] * mapWide + 3, barrens[2] * mapHigh + 3
  local second = GP.ZoneAt(world.KALIMDOR, pointerX / mapWide, pointerY / mapHigh)
  gmap.scripts.OnMouseDown(gmap, "LeftButton")
  gmap.scripts.OnMouseUp(gmap, "LeftButton")
  equal("and a second click ends it in the zone there", grounded.trip and grounded.trip.to, "zone:" .. tostring(second))
  pointerX, pointerY = 0.001 * mapWide, 0.999 * mapHigh
  equal("a click on the sea picks nothing", gmap.clickAt(pointerX, pointerY, "LeftButton"), false)

  -- A press that only trembles is still a click, and a click on a zoomed
  -- map picks what is under the pointer there.
  grounded.WindowClear()
  local middleX, middleY = (durotar[1] + durotar[3]) / 2, (durotar[2] + durotar[4]) / 2
  gmap.zoomTo(1.5)
  pointerX, pointerY = middleX * mapWide * gmap.zoom + gmap.offsetX, middleY * mapHigh * gmap.zoom + gmap.offsetY
  check("the zone's middle has moved in the window, and is still in it",
    math.abs(pointerX - middleX * mapWide) > 5 and pointerX > 0 and pointerX < mapWide and pointerY > 0 and pointerY < mapHigh, pointerX)
  gmap.scripts.OnMouseDown(gmap, "LeftButton")
  pointerX = pointerX + 2
  gmap.scripts.OnUpdate(gmap)
  gmap.scripts.OnMouseUp(gmap, "LeftButton")
  equal("a click on the zoomed map picks the zone under the pointer", grounded.window.heading.text, "From Durotar")
  grounded.WindowClear()
  gmap.zoomTo(1)

  -- Where the client names a city's own map at a spot, the city is picked.
  local savedAt = _G.C_Map.GetMapInfoAtPosition
  _G.C_Map.GetMapInfoAtPosition = function() return { mapID = 1454 } end
  local zoneThere, cityThere = GP.ZoneAt(world.KALIMDOR, 0.5, 0.5)
  check("a city's map is the city, not a zone", zoneThere == nil and cityThere == "orgrimmar", tostring(zoneThere) .. " " .. tostring(cityThere))
  gmap.clickAt(10, 10, "LeftButton")
  equal("and a click there starts the trip in the city", grounded.window.heading.text, "From Orgrimmar")
  _G.C_Map.GetMapInfoAtPosition = savedAt
  grounded.WindowClear()
  pointerX, pointerY = barrens[1] * mapWide + 3, barrens[2] * mapHigh + 3
  grounded.WindowClear()
  gmap.scripts.OnMouseDown(gmap, "RightButton")
  gmap.scripts.OnMouseUp(gmap, "RightButton")
  equal("a right-click on the ground goes there from where the character stands",
    grounded.window.heading.text, "Orgrimmar to " .. grounded.TRAVEL.ZONES[second].name .. " (On foot)")

  -- The green ring is a button: start where the character stands.
  grounded.WindowClear()
  check("the ring on the character can be clicked", gmap.hereButton ~= nil and gmap.hereButton:IsShown())
  gmap.hereButton.scripts.OnClick(gmap.hereButton, "LeftButton")
  equal("a click on it starts the trip where the character stands", grounded.window.heading.text, "From where you stand")
  gmap.pins.ratchet.scripts.OnClick(gmap.pins.ratchet, "LeftButton")
  equal("and the next click ends it", grounded.window.heading.text, "Orgrimmar to Ratchet (On foot)")
  equal("such a trip follows the character", grounded.trip.here, true)
  gmap.pins.ratchet.scripts.OnClick(gmap.pins.ratchet, "LeftButton")
  equal("with a start picked the ring on the character is no button", gmap.hereButton:IsShown(), false)
  grounded.WindowClear()

  -- The two buttons zoom for a player with no wheel.
  pointerX, pointerY = nil, nil
  click(gmap.zoomIn)
  equal("the plus button zooms in a step", gmap.zoom, 1.5)
  click(gmap.zoomOut)
  equal("and the minus button out", gmap.zoom, 1)
  gmap.zoomTo(1000, orgX * mapWide, orgY * mapHigh)
  equal("the zoom stops at its largest", gmap.zoom, grounded.MAP_ZOOM_MAX)
  check("where only a square or two of the ground is in view", gmap.terrainShown >= 1 and gmap.terrainShown <= 6, gmap.terrainShown)
  click(gmap.tabs[2])
  equal("the other continent opens whole", gmap.zoom, 1)
  equal("with none of the first one's ground", gmap.terrainShown, 0)
  for _, own in ipairs({ "Show", "Hide", "IsShown", "SetPoint", "SetSize", "SetScript", "SetScale", "GetScale", "GetLeft", "GetTop", "GetWidth", "GetHeight" }) do
    check("the zooming map keeps nothing under the frame's own " .. own, rawget(gmap, own) == nil)
  end
  rawset(_G, "EW_TEST_TILES", nil)
  rawset(_G, "GetCursorPosition", savedPointer)
  stub.state.printed = {}

  -- A client whose pictures do not fill their rows gets the drawn map.
  world.files = 11
  local drawn = t.LoadFreshAddon(2, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  drawn.SlashCommand("")
  check("where the pictures cannot be laid out the drawn map stands in", drawn.window.map ~= nil and drawn.window.map.real == false)
  check("with its outlines", drawn.window.map.lines > 400)
  world.files = 12
  world.Remove()
  stub.state.map = nil

  -- The pictures the addon ships, as the game reads them.
  for _, picture in ipairs({ { "icon", 64 }, { "minimap", 64 }, { "dot", 16 }, { "ring", 32 }, { "mark-ring", 32 }, { "mark-diamond", 32 }, { "mark-square", 32 } }) do
    local handle = io.open(t.root .. "Media/" .. picture[1] .. ".tga", "rb")
    check("Media/" .. picture[1] .. ".tga is shipped", handle ~= nil)
    if handle then
      local head = handle:read(18)
      handle:close()
      equal(picture[1] .. " is an uncompressed true color picture", head:byte(3), 2)
      equal(picture[1] .. " is " .. picture[2] .. " wide", head:byte(13) + head:byte(14) * 256, picture[2])
      equal(picture[1] .. " is " .. picture[2] .. " tall", head:byte(15) + head:byte(16) * 256, picture[2])
      equal(picture[1] .. " has 32 bits a point", head:byte(17), 32)
    end
  end
  for _, toc in ipairs({ "EverythingWoW.toc", "EverythingWoW_Vanilla.toc" }) do
    local handle = assert(io.open(t.root .. toc, "r"))
    local text = handle:read("*a")
    handle:close()
    check(toc .. " names the site's mark as the addon's icon",
      text:find("## IconTexture: Interface\\AddOns\\EverythingWoW\\Media\\icon", 1, true) ~= nil)
    check(toc .. " loads the maps and the places before the window", text:find("TravelMap.lua\nTravelCoords.lua\nPlaces.lua\nWindow.lua", 1, true) ~= nil)
  end

  -- A client that cannot build the window keeps the commands.
  _G.CreateFrame = realCreateFrame
  rawset(_G, "Minimap", savedMinimap)
  rawset(_G, "UIParent", savedParent)
  local plain = t.LoadFreshAddon(2, { "1.60.1", "70000", "Nov 4 2026", 16001 })
  stub.state.printed = {}
  plain.SlashCommand("")
  equal("where the window cannot be built there is none", plain.window, nil)
  check("and a bare /ewow prints the status as it always did",
    table.concat(stub.state.printed, "\n"):find("observations held", 1, true) ~= nil)
  stub.state.printed = {}
  plain.SlashCommand("route")
  check("and /ewow route with no place prints the usage",
    #stub.state.printed == 1 and stub.state.printed[1]:find("Usage: /ewow route", 1, true) ~= nil)
  stub.Fire("PLAYER_ENTERING_WORLD")
  equal("and no minimap button is built", plain.minimapButton, nil)
  stub.state.timers = {}
  stub.state.printed = {}
  stub.state.map = nil
end
