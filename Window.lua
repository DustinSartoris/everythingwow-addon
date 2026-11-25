--[[
The Companion's window.

Until 0.3.2 everything the addon could do was a chat command. The window
gives it a face: /ewow opens it, and so does the button on the minimap.

It has two pages.

Route. Two boxes, From and To, a speed, and a button. Leave From empty and
the trip starts where your character stands. The answer is the planner's
own, the one /ewow route prints: the trip, the estimate, and the steps in
order, shown as a list you can page through.

Recorded. What the file holds now, kind by kind, in the words the site's
upload page uses, how many observations were dropped to keep the file small,
where the file is written, and where to upload it.

A third button opens the list of auctions under vendor price, which keeps
its own window beside the auction house.

Every frame is built inside a pcall and with the game's own templates where
the client has them. A client on which the window cannot be built gets the
chat commands as before, and /ewow prints the status line there as it
always did. The window reads what the commands read and saves nothing.
]]

local ADDON_NAME, EW = ...

EW.WINDOW_STEP_ROWS = 8
EW.WINDOW_WIDTH = 560
EW.WINDOW_HEIGHT = 420

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

local window, windowFailed = nil, false
local page, stepPage = "route", 1
local answer = nil

--------------------------------------------------------------------------
-- What the pages show, as plain values, so the tests can read them
--------------------------------------------------------------------------

local function Trim(text)
  if type(text) ~= "string" then return "" end
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--[[
Plans the trip the two boxes ask for. Returns { ok = true, title, estimate,
steps } where a route was found and { ok = false, message } otherwise. An
empty From is where the character stands.
]]
function EW.RouteAnswer(fromText, toText)
  local Travel = EW.Travel
  if not Travel or EW.VersionKey() ~= "forever" then
    return { ok = false, message = "The route planner covers WoW Forever only." }
  end
  fromText, toText = Trim(fromText), Trim(toText)
  if toText == "" then return { ok = false, message = "Type where you want to go." } end
  local from
  if fromText == "" then
    from = Travel.Here()
    if not from then
      return { ok = false, message = "The planner does not know the map you are on. Type where you start from." }
    end
  else
    from = Travel.Find(fromText)
  end
  local to = Travel.Find(toText)
  if not from or not to then return { ok = false, message = Travel.Refusal("not_on_map") } end
  local lines, found = Travel.Lines(from, to)
  if not found then return { ok = false, message = lines[1] } end
  local steps = {}
  for index = 3, #lines do steps[#steps + 1] = lines[index] end
  return { ok = true, title = lines[1], estimate = lines[2], steps = steps }
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
    frame.estimate:SetText("Leave From empty to start where you stand.")
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
  answer = EW.RouteAnswer(fromText, toText)
  stepPage = 1
  pcall(function()
    window.from:ClearFocus()
    window.to:ClearFocus()
  end)
  Refresh()
end
EW.WindowPlan = Plan

local function BuildWindow()
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

  frame:SetSize(EW.WINDOW_WIDTH, EW.WINDOW_HEIGHT)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  frame:SetFrameStrata("HIGH")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) pcall(self.StartMoving, self) end)
  frame:SetScript("OnDragStop", function(self) pcall(self.StopMovingOrSizing, self) end)

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", frame, "TOP", 0, -6)
  title:SetText("Everything WoW Companion")

  local function Button(label, width, onClick)
    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetSize(width, 22)
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

  -- The Route page.
  local function Box(label, x, width)
    local caption = Route(Text("GameFontNormalSmall"))
    caption:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -64)
    caption:SetText(label)
    local box = Route(CreateFrame("EditBox", nil, frame, "InputBoxTemplate"))
    box:SetSize(width, 20)
    box:SetPoint("TOPLEFT", frame, "TOPLEFT", x + 4, -78)
    box:SetAutoFocus(false)
    pcall(function() box:SetMaxLetters(60) end)
    box:SetScript("OnEnterPressed", function() pcall(Plan) end)
    box:SetScript("OnEscapePressed", function(self) pcall(self.ClearFocus, self) end)
    return box
  end
  frame.from = Box("From", 14, 180)
  frame.to = Box("To", 210, 180)
  local plan = Route(Button("Plan Route", 100, Plan))
  plan:SetPoint("TOPLEFT", frame, "TOPLEFT", 406, -77)
  frame.speed = Route(Button("Speed", 150, function()
    EW.NextTravelSpeed()
    -- A new speed is a new answer to the same question.
    if answer then Plan() else Refresh() end
  end))
  frame.speed:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -108)

  frame.heading = Route(Text("GameFontNormal"))
  frame.heading:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -142)
  frame.heading:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -142)
  frame.estimate = Route(Text("GameFontHighlightSmall"))
  frame.estimate:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -160)
  frame.estimate:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -160)

  frame.steps = {}
  for index = 1, EW.WINDOW_STEP_ROWS do
    local row = Route(Text("GameFontHighlightSmall"))
    row:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -182 - (index - 1) * 26)
    row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -182 - (index - 1) * 26)
    row:SetHeight(24)
    pcall(function() row:SetWordWrap(true) end)
    pcall(function() row:SetJustifyV("TOP") end)
    frame.steps[index] = row
  end
  frame.prev = Route(Button("Previous", 80, function() stepPage = stepPage - 1 Refresh() end))
  frame.prev:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 10)
  frame.next = Route(Button("Next", 80, function() stepPage = stepPage + 1 Refresh() end))
  frame.next:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 10)
  frame.pageText = Route(Text("GameFontHighlightSmall", "CENTER"))
  frame.pageText:SetPoint("BOTTOM", frame, "BOTTOM", 0, 15)

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
local function PlaceMinimapButton()
  local db = EW.Database()
  local angle = math.rad(type(db.minimapAngle) == "number" and db.minimapAngle or EW.MINIMAP_ANGLE)
  minimapButton:ClearAllPoints()
  minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80)
end

local function BuildMinimapButton()
  local button = CreateFrame("Button", "EverythingWoWMinimapButton", Minimap)
  button:SetSize(32, 32)
  button:SetFrameStrata("MEDIUM")
  pcall(function() button:SetFrameLevel(8) end)
  local icon = button:CreateTexture(nil, "BACKGROUND")
  icon:SetSize(20, 20)
  icon:SetPoint("CENTER", button, "CENTER", 0, 0)
  icon:SetTexture("Interface\\ICONS\\INV_Misc_Book_09")
  local border = button:CreateTexture(nil, "OVERLAY")
  border:SetSize(54, 54)
  border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
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
      GameTooltip:AddLine("Click to open: plan a route, see what is recorded.", 1, 1, 1)
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
