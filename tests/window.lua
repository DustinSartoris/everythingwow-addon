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
      if key == "CreateFontString" or key == "CreateTexture" then return function() return MockFrame("Region") end end
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
  equal("no destination asks for one", EW.RouteAnswer("Orgrimmar", "  ").message, "Type where you want to go.")
  equal("a place not on the map is refused in the site's words",
    EW.RouteAnswer("Orgrimmar", "Shattrath").message, "That place is not on this map.")
  stub.state.map = nil
  equal("an empty From on an unknown map asks for the start",
    EW.RouteAnswer("", "Undercity").message, "The planner does not know the map you are on. Type where you start from.")
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
