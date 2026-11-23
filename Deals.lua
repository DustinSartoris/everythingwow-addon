--[[
The vendor deal finder, from 0.2.9.

On 23 November 2026 the owner asked for the addon to look for auctions
listed below what a vendor pays for the item, and to show a window of what
to buy and for how much. This file is that: it is the one part of the addon
made for the player rather than for the site, and nothing it finds is
written to the saved file or uploaded.

It reads the auction house exactly as Auction.lua does and no further. It
never sends a query of its own: no SendBrowseQuery, no SendSearchQuery, no
QueryAuctionItems. It reads only the results the player's own search has
already loaded, at the moment the client announces them, through the same
getters and the same events as the recorder. It never buys anything and
never places a bid: the window says what is worth buying, and the player
buys it in the auction house as they would anything else.

What counts as a deal. A vendor pays an item's sell price for each one. An
auction is a deal when its buyout for one item is lower than that price, so
buying it and selling it to any vendor leaves a profit; the auction house
takes its cut from the seller, never from the buyer. An item no vendor buys
(a sell price of 0) is never a deal.

How exact a row is depends on what the client has loaded:

  A commodity search or an item search gives every listing, so the row is
  exact: how many to buy, what they cost together, what a vendor pays for
  them and the profit. Both give the price of one and how many there are at
  that price; 0.2.9 took an item row's price for the whole row, which made
  a row of 15 at 8 silver 67 each read as 15 for 8 silver 67.

  The browse list gives only the lowest price of each item, so the row is
  the price of one, marked "1+": open the item in the auction house and its
  listings replace the row with an exact one.

  The classic list, on a client without C_AuctionHouse, gives each auction
  on the page with its buyout, so its rows are exact for that page.

The seller is never read into anything kept. A listing the player posted
themselves is passed over, by the client's own flag on the modern auction
house and by comparing the owner to the player's own name on the classic
one, and neither is stored.

Safety follows Auction.lua's. Every client call sits inside pcall. The
result events are the ones the recorder already listens for, registered the
first time the player opens the auction house and never at login, each only
where the client says the event exists and the getters that read it exist.
Nothing here runs in combat. The window is an ordinary frame the addon
creates for itself; it touches no secure frame and calls no protected
function, and if any part of it cannot be built on a client the list is
printed in chat instead.
]]

local ADDON_NAME, EW = ...

-- The most rows read from one search result or one browse announcement.
EW.DEALS_ROW_CAP = 500
EW.DEALS_BROWSE_CAP = 2000
-- An exact row is kept against a later browse row of the same lowest price
-- for this long, so going back to the list does not blur what a search told.
EW.DEALS_EXACT_SECONDS = 300
-- An item the client has not loaded yet has no sell price to compare with;
-- it is asked again this many times, this many seconds apart.
EW.DEALS_RETRIES = 3
EW.DEALS_RETRY_SECONDS = 1
EW.DEALS_PENDING_CAP = 500
-- The rows the window shows on one page.
EW.DEALS_PAGE_ROWS = 12

local deals = {}
local pending = {}
local pendingCount = 0
local retriesLeft = 0
local retryQueued = false
local autoOpen = true
-- A deal of less profit than this, in copper, is held but not shown or
-- counted. Set with `/ewow deals min`, for the session; 0 shows every deal.
local minProfit = 0
local shownThisVisit = false
local announcedThisVisit = false

local function InCombat()
  local fighting = false
  pcall(function()
    if type(rawget(_G, "InCombatLockdown")) == "function" then
      fighting = InCombatLockdown() and true or false
    end
  end)
  return fighting
end

--[[ An item's name, link, quality and vendor sell price in copper, from the
     client's own item cache. Every value is nil where the client has not
     loaded the item yet, which asking is what makes it load. ]]
local function ItemInfo(item)
  local name, link, quality, sell
  pcall(function()
    local api = rawget(_G, "C_Item")
    local get = (type(api) == "table" and type(api.GetItemInfo) == "function") and api.GetItemInfo
      or rawget(_G, "GetItemInfo")
    if type(get) ~= "function" then return end
    local n, l, q, _, _, _, _, _, _, _, price = get(item)
    name, link, quality, sell = n, l, q, price
  end)
  if type(sell) ~= "number" then sell = nil end
  return name, link, quality, sell
end
EW.DealItemInfo = ItemInfo

--[[ Copper as gold, silver and copper, the way the game writes a price. ]]
function EW.Money(copper)
  if type(copper) ~= "number" then return "?" end
  local negative = copper < 0
  copper = math.floor(math.abs(copper) + 0.5)
  local gold = math.floor(copper / 10000)
  local silver = math.floor((copper % 10000) / 100)
  local rest = copper % 100
  local parts = {}
  if gold > 0 then parts[#parts + 1] = gold .. "|cffffd700g|r" end
  if silver > 0 or gold > 0 then parts[#parts + 1] = silver .. "|cffc7c7cfs|r" end
  parts[#parts + 1] = rest .. "|cffeda55fc|r"
  return (negative and "-" or "") .. table.concat(parts, " ")
end

local function Forget(itemId)
  deals[itemId] = nil
end

--[[
Weighs what one read said of one item against the vendor's price.

raw.rows lists what was read, each row a quantity and either the price of
one (unit) or the buyout of the whole auction, with the row's own item link
where the client gave one, since two auctions of one item can be different
versions of it with different sell prices. raw.source names the read.

Returns "deal" where the item is now held as a deal, "none" where it is
not, and "unknown" where a sell price was not loaded yet, in which case the
read is kept to be weighed again.
]]
local function Evaluate(itemId, raw)
  local name, link, quality, baseSell = ItemInfo(itemId)
  local count, cost, value, low = 0, 0, 0, nil
  local unknown = false
  local dealLink, dealSell

  for _, row in ipairs(raw.rows) do
    local quantity = row.q
    local unit = row.unit
    if type(unit) ~= "number" and type(row.buyout) == "number" and type(quantity) == "number" and quantity > 0 then
      unit = row.buyout / quantity
    end
    if type(quantity) == "number" and quantity > 0 and type(unit) == "number" and unit > 0 then
      local sell = baseSell
      local rowLink = nil
      if type(row.link) == "string" then
        local _, exactLink, _, exactSell = ItemInfo(row.link)
        -- The row's own version of the item where the client has it loaded,
        -- else the plain item's price, which is the same for most items.
        if exactSell ~= nil then sell = exactSell end
        rowLink = exactLink or row.link
      end
      if sell == nil then
        unknown = true
      elseif sell > 0 and unit < sell then
        local price = type(row.buyout) == "number" and row.buyout or unit * quantity
        count = count + quantity
        cost = cost + price
        value = value + sell * quantity
        if low == nil or unit < low then low = unit end
        if dealLink == nil then dealLink, dealSell = rowLink, sell end
      end
    end
  end

  if count == 0 then
    Forget(itemId)
    if unknown then return "unknown" end
    return "none"
  end

  local existing = deals[itemId]
  if raw.source == "browse" and existing and existing.exact
    and (EW.Now() - existing.t) < EW.DEALS_EXACT_SECONDS and existing.low == math.floor(low) then
    return "deal"
  end

  deals[itemId] = {
    id = itemId,
    name = name or ("Item " .. tostring(itemId)),
    link = dealLink or link,
    quality = quality,
    sell = dealSell or baseSell,
    count = math.floor(count),
    cost = math.floor(cost),
    value = math.floor(value),
    profit = math.floor(value - cost),
    low = math.floor(low),
    exact = raw.source ~= "browse",
    total = raw.total,
    source = raw.source,
    t = EW.Now(),
  }
  if unknown then return "unknown" end
  return "deal"
end

local function Weigh(itemId, raw)
  local outcome = Evaluate(itemId, raw)
  if outcome == "unknown" then
    if pending[itemId] == nil then
      if pendingCount >= EW.DEALS_PENDING_CAP then return outcome end
      pendingCount = pendingCount + 1
    end
    pending[itemId] = raw
  elseif pending[itemId] ~= nil then
    pending[itemId] = nil
    pendingCount = pendingCount - 1
  end
  return outcome
end

--[[ The deals held, the most profit first, then by name. ]]
function EW.DealList()
  local list = {}
  for _, deal in pairs(deals) do
    if deal.profit >= minProfit then list[#list + 1] = deal end
  end
  table.sort(list, function(a, b)
    if a.profit ~= b.profit then return a.profit > b.profit end
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
  end)
  return list
end

function EW.DealCount()
  local count = 0
  for _, deal in pairs(deals) do
    if deal.profit >= minProfit then count = count + 1 end
  end
  return count
end

--[[ An amount of money as the player types it: "50s", "1g", "1g 20s", "75c",
     or a bare number of copper. Nil for anything else. ]]
function EW.ParseMoney(text)
  text = string.lower(tostring(text or ""))
  if text:match("^%s*%d+%s*$") then return tonumber(text:match("%d+")) end
  local total, found = 0, false
  for amount, unit in text:gmatch("(%d+)%s*([gsc])") do
    found = true
    total = total + tonumber(amount) * (unit == "g" and 10000 or unit == "s" and 100 or 1)
  end
  if not found or text:gsub("%d+%s*[gsc]", ""):match("%S") then return nil end
  return total
end

function EW.DealsMinProfit() return minProfit end

function EW.ClearDeals()
  deals = {}
  pending = {}
  pendingCount = 0
  retriesLeft = 0
end

--[[ One deal as a line of chat, and the same words the window's row uses. ]]
function EW.DealLine(deal)
  local what = deal.link or deal.name
  if deal.exact then
    return string.format("%s: buy %d for %s, vendor %s, profit %s",
      what, deal.count, EW.Money(deal.cost), EW.Money(deal.value), EW.Money(deal.profit))
  end
  return string.format("%s: from %s each, vendor %s each, profit %s or more",
    what, EW.Money(deal.low), EW.Money(deal.sell), EW.Money(deal.profit))
end

-- The window is built further down; a read calls this once it has finished.
local AfterRead

--[[ Asks again for the items whose sell price the client had not loaded. ]]
local function Retry()
  retryQueued = false
  if pendingCount == 0 then return end
  local again = {}
  for itemId, raw in pairs(pending) do again[itemId] = raw end
  for itemId, raw in pairs(again) do Weigh(itemId, raw) end
  if AfterRead then AfterRead(false) end
end
EW.RetryDeals = Retry

local function QueueRetry(reset)
  if reset then retriesLeft = EW.DEALS_RETRIES end
  if pendingCount == 0 or retriesLeft <= 0 or retryQueued then return end
  local timer = rawget(_G, "C_Timer")
  if type(timer) ~= "table" or type(timer.After) ~= "function" then return end
  retriesLeft = retriesLeft - 1
  retryQueued = true
  local ok = pcall(timer.After, EW.DEALS_RETRY_SECONDS, function()
    pcall(Retry)
    QueueRetry(false)
  end)
  if not ok then retryQueued = false end
end

local function Finish()
  if AfterRead then pcall(AfterRead, true) end
  QueueRetry(true)
end

--[[ The modern auction house, C_AuctionHouse. ]]

local READ_FUNCTIONS = {
  browse = { "GetBrowseResults" },
  commodity = { "GetNumCommoditySearchResults", "GetCommoditySearchResultInfo" },
  item = { "GetNumItemSearchResults", "GetItemSearchResultInfo" },
}

local function HasAuctionFunction(name)
  local present = false
  pcall(function()
    local api = rawget(_G, "C_AuctionHouse")
    present = type(api) == "table" and type(api[name]) == "function"
  end)
  return present
end

local function CanRead(read)
  for _, name in ipairs(READ_FUNCTIONS[read]) do
    if not HasAuctionFunction(name) then return false end
  end
  return true
end

local function EventExists(event)
  local valid = true
  pcall(function()
    local utils = rawget(_G, "C_EventUtils")
    if type(utils) == "table" and type(utils.IsEventValid) == "function" then
      valid = utils.IsEventValid(event) and true or false
    end
  end)
  return valid
end

--[[ Whether the deal finder may read the modern auction house here. It
     follows the recorder's own capability, so it reads exactly where the
     recorder reads and a client that refuses the reader turns this off with
     it. That leaves it off on Retail, where the addon does not read the
     auction house at all, and on a client the addon cannot place. ]]
local function ModernOn()
  return EW.Caps ~= nil and EW.Caps.auctionModern == true
end

local browseRead = 0

local function ReadBrowse(fresh)
  if not ModernOn() or InCombat() or not CanRead("browse") then return 0 end
  local results
  pcall(function() results = C_AuctionHouse.GetBrowseResults() end)
  if type(results) ~= "table" then return 0 end
  local total = #results
  if fresh or total < browseRead then browseRead = 0 end
  local start = browseRead + 1
  if start > total then return 0 end
  local last = math.min(total, start + EW.DEALS_BROWSE_CAP - 1)

  local read = 0
  for index = start, last do
    pcall(function()
      local row = results[index]
      local key = type(row) == "table" and row.itemKey or nil
      if type(key) ~= "table" or type(key.itemID) ~= "number" or key.itemID <= 0 then return end
      if type(key.battlePetSpeciesID) == "number" and key.battlePetSpeciesID > 0 then return end
      if row.containsOwnerItem == true then return end
      if type(row.minPrice) ~= "number" or row.minPrice <= 0 then return end
      read = read + 1
      Weigh(key.itemID, {
        source = "browse",
        total = type(row.totalQuantity) == "number" and row.totalQuantity or nil,
        rows = { { q = 1, unit = row.minPrice } },
      })
    end)
  end
  browseRead = last
  Finish()
  return read
end
EW.OnDealBrowseResults = ReadBrowse

local function ReadCommodity(itemId)
  if not ModernOn() or InCombat() or not CanRead("commodity") then return 0 end
  if type(itemId) ~= "number" or itemId <= 0 then return 0 end
  local total = 0
  pcall(function() total = C_AuctionHouse.GetNumCommoditySearchResults(itemId) or 0 end)
  if type(total) ~= "number" then return 0 end
  local last = math.min(total, EW.DEALS_ROW_CAP)

  local rows = {}
  for index = 1, last do
    pcall(function()
      local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemId, index)
      if type(info) ~= "table" then return end
      local quantity, unit = info.quantity, info.unitPrice
      if type(quantity) ~= "number" or type(unit) ~= "number" then return end
      -- The player's own share of a listing is not theirs to buy.
      if type(info.numOwnerItems) == "number" and info.numOwnerItems > 0 then
        quantity = quantity - info.numOwnerItems
      elseif info.containsOwnerItem == true then
        quantity = 0
      end
      if quantity > 0 then rows[#rows + 1] = { q = quantity, unit = unit } end
    end)
  end
  Weigh(math.floor(itemId), { source = "commodity", rows = rows })
  Finish()
  return #rows
end
EW.OnDealCommodityResults = ReadCommodity

local function ReadItem(itemKey)
  if not ModernOn() or InCombat() or not CanRead("item") then return 0 end
  if type(itemKey) ~= "table" or type(itemKey.itemID) ~= "number" or itemKey.itemID <= 0 then return 0 end
  if type(itemKey.battlePetSpeciesID) == "number" and itemKey.battlePetSpeciesID > 0 then return 0 end
  local total = 0
  pcall(function() total = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0 end)
  if type(total) ~= "number" then return 0 end
  local last = math.min(total, EW.DEALS_ROW_CAP)

  local rows = {}
  for index = 1, last do
    pcall(function()
      local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, index)
      if type(info) ~= "table" then return end
      if info.containsOwnerItem == true then return end
      local quantity = type(info.quantity) == "number" and info.quantity or 1
      if type(info.buyoutAmount) ~= "number" or info.buyoutAmount <= 0 or quantity <= 0 then return end
      -- The client groups identical auctions into one row: buyoutAmount is
      -- the price of one, and quantity is how many there are at that price.
      rows[#rows + 1] = {
        q = quantity,
        unit = info.buyoutAmount,
        link = type(info.itemLink) == "string" and info.itemLink or nil,
      }
    end)
  end
  Weigh(math.floor(itemKey.itemID), { source = "item", rows = rows })
  Finish()
  return #rows
end
EW.OnDealItemResults = ReadItem

--[[ The classic auction house, on a client without C_AuctionHouse. One page
     of the list is read as the client loads it; an item on the page is
     weighed by the page's own auctions of it. ]]

local function HasModernAuctionApi()
  return HasAuctionFunction("GetBrowseResults")
end

local function ClassicOn()
  if not EW.Caps or EW.Caps.auction ~= true then return false end
  if HasModernAuctionApi() then return false end
  return type(rawget(_G, "GetNumAuctionItems")) == "function"
    and type(rawget(_G, "GetAuctionItemInfo")) == "function"
end

local function ReadClassicList()
  if not ClassicOn() or InCombat() then return 0 end
  local batch = 0
  pcall(function() batch = (GetNumAuctionItems("list")) or 0 end)
  if type(batch) ~= "number" or batch < 1 then return 0 end
  if batch > EW.DEALS_ROW_CAP then batch = EW.DEALS_ROW_CAP end

  local own
  pcall(function() own = UnitName("player") end)

  local byItem = {}
  local read = 0
  for index = 1, batch do
    pcall(function()
      local link = GetAuctionItemLink and GetAuctionItemLink("list", index) or nil
      local itemId = EW.IdFromLink and EW.IdFromLink(link) or nil
      if not itemId then return end
      local _, _, quantity, _, _, _, _, _, _, buyout, _, _, _, owner = GetAuctionItemInfo("list", index)
      -- The owner is compared with the player's own name and dropped.
      if own ~= nil and owner == own then return end
      if type(quantity) ~= "number" or quantity <= 0 then return end
      local rows = byItem[itemId]
      if not rows then
        rows = {}
        byItem[itemId] = rows
      end
      if type(buyout) == "number" and buyout > 0 then
        rows[#rows + 1] = { q = quantity, buyout = buyout, link = type(link) == "string" and link or nil }
      end
      read = read + 1
    end)
  end
  for itemId, rows in pairs(byItem) do
    Weigh(itemId, { source = "classic", rows = rows })
  end
  Finish()
  return read
end
EW.OnDealClassicList = ReadClassicList

--[[ The window. Every call into the client's frame API is inside pcall, and
     a window that cannot be built leaves EW.dealsWindow nil, in which case
     the list goes to chat. ]]

local window
local windowFailed = false
local page = 1

local function AuctionFrame()
  local frame
  pcall(function()
    frame = rawget(_G, "AuctionHouseFrame") or rawget(_G, "AuctionFrame")
  end)
  return frame
end

local function RowText(deal)
  local name = deal.link or deal.name
  if deal.exact then
    return name,
      string.format("Buy %d for %s", deal.count, EW.Money(deal.cost)),
      string.format("Vendor %s", EW.Money(deal.value)),
      string.format("+%s", EW.Money(deal.profit))
  end
  return name,
    string.format("1+ from %s each", EW.Money(deal.low)),
    string.format("Vendor %s each", EW.Money(deal.sell)),
    string.format("+%s", EW.Money(deal.profit))
end
EW.DealRowText = RowText

local function RefreshWindow()
  if not window then return end
  local list = EW.DealList()
  local perPage = EW.DEALS_PAGE_ROWS
  local pages = math.max(1, math.ceil(#list / perPage))
  if page > pages then page = pages end
  if page < 1 then page = 1 end
  local first = (page - 1) * perPage
  for index, row in ipairs(window.rows) do
    local deal = list[first + index]
    row.deal = deal
    if deal then
      local name, buy, vendor, profit = RowText(deal)
      row.name:SetText(name)
      row.buy:SetText(buy)
      row.vendor:SetText(vendor)
      row.profit:SetText("|cff40c040" .. profit .. "|r")
      row:Show()
    else
      row:Hide()
    end
  end
  if #list == 0 then
    window.empty:SetText("Nothing is listed under its vendor price yet.\nSearch the auction house and anything that is shows up here.")
    window.empty:Show()
  else
    window.empty:Hide()
  end
  window.pageText:SetText(string.format("Page %d of %d", page, pages))
  if window.prev.SetEnabled then
    window.prev:SetEnabled(page > 1)
    window.next:SetEnabled(page < pages)
  end
end

local function BuildWindow()
  local frame
  local templated = pcall(function()
    frame = CreateFrame("Frame", "EverythingWoWDealsFrame", UIParent, "BasicFrameTemplateWithInset")
  end)
  if not templated or not frame then
    frame = CreateFrame("Frame", "EverythingWoWDealsFrame", UIParent)
    local shade = frame:CreateTexture(nil, "BACKGROUND")
    shade:SetAllPoints(frame)
    shade:SetColorTexture(0.05, 0.05, 0.07, 0.92)
    pcall(function()
      local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
      close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    end)
  end

  local rowHeight = 20
  frame:SetSize(634, 96 + EW.DEALS_PAGE_ROWS * rowHeight)
  frame:SetFrameStrata("HIGH")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) pcall(self.StartMoving, self) end)
  frame:SetScript("OnDragStop", function(self) pcall(self.StopMovingOrSizing, self) end)

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", frame, "TOP", 0, -6)
  title:SetText("Auctions Under Vendor Price")

  local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hint:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -32)
  hint:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -32)
  hint:SetJustifyH("LEFT")
  hint:SetText("Buy these on the auction house, then sell them to any vendor. Rows marked 1+ show the lowest price only: open the item to see how many.")

  local empty = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  empty:SetPoint("CENTER", frame, "CENTER", 0, 0)
  empty:Hide()

  local rows = {}
  for index = 1, EW.DEALS_PAGE_ROWS do
    local row = CreateFrame("Button", nil, frame)
    row:SetSize(606, rowHeight)
    row:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -60 - (index - 1) * rowHeight)
    pcall(function() row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD") end)

    local function Column(left, width, justify, font)
      local text = row:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
      text:SetPoint("LEFT", row, "LEFT", left, 0)
      text:SetWidth(width)
      text:SetJustifyH(justify)
      pcall(function() text:SetWordWrap(false) end)
      return text
    end
    row.name = Column(2, 200, "LEFT", "GameFontNormalSmall")
    row.buy = Column(206, 170, "LEFT")
    row.vendor = Column(380, 130, "LEFT")
    row.profit = Column(514, 90, "RIGHT")

    row:SetScript("OnEnter", function(self)
      pcall(function()
        if not self.deal or not self.deal.link then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.deal.link)
        GameTooltip:Show()
      end)
    end)
    row:SetScript("OnLeave", function() pcall(function() GameTooltip:Hide() end) end)
    -- A click hands the item's link to the client the way a shift click on
    -- any item does, which the auction house reads as "search for this".
    -- The addon sends no query itself; the search is the client's own.
    row:SetScript("OnClick", function(self)
      pcall(function()
        if not self.deal or not self.deal.link then return end
        local util = rawget(_G, "ChatFrameUtil")
        if type(util) == "table" and type(util.InsertLink) == "function" then
          util.InsertLink(self.deal.link)
        elseif type(rawget(_G, "ChatEdit_InsertLink")) == "function" then
          ChatEdit_InsertLink(self.deal.link)
        end
      end)
    end)
    rows[index] = row
  end

  local function PageButton(label, anchor, x, step)
    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetSize(70, 20)
    button:SetPoint(anchor, frame, anchor, x, 8)
    button:SetText(label)
    button:SetScript("OnClick", function()
      page = page + step
      pcall(RefreshWindow)
    end)
    return button
  end
  local prev = PageButton("Previous", "BOTTOMLEFT", 14, -1)
  local nextButton = PageButton("Next", "BOTTOMRIGHT", -14, 1)
  local pageText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  pageText:SetPoint("BOTTOM", frame, "BOTTOM", 0, 13)

  frame.rows, frame.empty, frame.prev, frame.next, frame.pageText = rows, empty, prev, nextButton, pageText

  -- Beside the auction house where there is one, else the middle of the screen.
  local anchored = false
  pcall(function()
    local auction = AuctionFrame()
    if auction and auction.IsShown and auction:IsShown() then
      frame:SetPoint("TOPLEFT", auction, "TOPRIGHT", 8, 0)
      anchored = true
    end
  end)
  if not anchored then frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0) end

  -- Escape closes it, as it closes any panel.
  pcall(function()
    local special = rawget(_G, "UISpecialFrames")
    if type(special) == "table" then table.insert(special, "EverythingWoWDealsFrame") end
  end)
  frame:Hide()
  return frame
end

--[[ The window goes away with the auction house. The auction house's own
     frame exists only once the player has opened it, so this is tried each
     time the window is shown until it has been done once. ]]
local hideHooked = false
local function HookAuctionHide()
  if hideHooked or not window then return end
  pcall(function()
    local auction = AuctionFrame()
    if auction and auction.HookScript then
      auction:HookScript("OnHide", function() pcall(function() window:Hide() end) end)
      hideHooked = true
    end
  end)
end

local function EnsureWindow()
  if window or windowFailed then return window end
  local ok, built = pcall(BuildWindow)
  if ok and built then
    window = built
    EW.dealsWindow = built
  else
    windowFailed = true
    EW.dealsWindowError = tostring(built)
  end
  return window
end

local function PrintDeals(limit)
  local list = EW.DealList()
  if #list == 0 then
    EW.Print("Nothing is listed under its vendor price yet. Search the auction house and anything that is shows up here.")
    return
  end
  EW.Print(string.format("%d %s under vendor price:", #list, #list == 1 and "item" or "items"))
  for index, deal in ipairs(list) do
    if limit and index > limit then
      EW.Print(string.format("  and %d more.", #list - limit))
      break
    end
    EW.Print("  " .. EW.DealLine(deal))
  end
end
EW.PrintDeals = PrintDeals

--[[ Opens the window, or prints the list where the window cannot be built. ]]
function EW.ShowDeals()
  local frame = EnsureWindow()
  if not frame then
    PrintDeals(20)
    return false
  end
  HookAuctionHide()
  local ok = pcall(function()
    RefreshWindow()
    frame:Show()
  end)
  if not ok then
    PrintDeals(20)
    return false
  end
  return true
end

function EW.ToggleDeals()
  local shown = false
  pcall(function() shown = window ~= nil and window:IsShown() and true or false end)
  if shown then
    pcall(function() window:Hide() end)
    return false
  end
  return EW.ShowDeals()
end

AfterRead = function(fromRead)
  local count = EW.DealCount()
  local shown = false
  pcall(function() shown = window ~= nil and window:IsShown() and true or false end)
  if shown then
    pcall(RefreshWindow)
    return
  end
  if count == 0 then return end
  if autoOpen and not shownThisVisit then
    shownThisVisit = true
    if EW.ShowDeals() then return end
  end
  if not announcedThisVisit and not autoOpen then
    announcedThisVisit = true
    EW.Print(string.format("%d %s under vendor price. Type /ewow deals to see them.",
      count, count == 1 and "item is listed" or "items are listed"))
  end
end

--[[ `/ewow deals`, with `list`, `clear`, `min <amount>` and `auto on|off`. ]]
function EW.DealsCommand(rest)
  local word = string.lower(string.match(tostring(rest or ""), "^%s*(%S*)") or "")
  local argument = string.lower(string.match(tostring(rest or ""), "^%s*%S*%s*(%S*)") or "")
  if word == "list" then
    PrintDeals(nil)
  elseif word == "clear" then
    EW.ClearDeals()
    pcall(RefreshWindow)
    EW.Print("The list of auctions under vendor price is cleared.")
  elseif word == "min" then
    local amount = EW.ParseMoney(string.match(tostring(rest or ""), "^%s*%S*%s*(.-)%s*$"))
    if amount == nil then
      EW.Print("Use /ewow deals min with an amount, such as /ewow deals min 50s or /ewow deals min 1g. /ewow deals min 0 shows every deal.")
    else
      minProfit = amount
      pcall(RefreshWindow)
      EW.Print(amount > 0 and string.format("Only deals with a profit of %s or more are shown. This lasts until you log out or reload.", EW.Money(amount))
        or "Every deal is shown, whatever its profit.")
    end
  elseif word == "auto" then
    if argument == "on" or argument == "off" then
      autoOpen = (argument == "on")
      EW.Print(autoOpen and "The window opens by itself when an auction under vendor price is found."
        or "The window stays closed until you type /ewow deals. This lasts until you log out or reload.")
    else
      EW.Print("Use /ewow deals auto on or /ewow deals auto off.")
    end
  else
    EW.ToggleDeals()
  end
end

function EW.DealsAutoOpen() return autoOpen end

--[[ Which read the deal finder uses on this client, for anyone who asks. ]]
function EW.DealsMode()
  if ModernOn() and (CanRead("browse") or CanRead("commodity") or CanRead("item")) then return "modern" end
  if ClassicOn() then return "classic" end
  return "idle"
end

--[[ A new visit to the auction house starts a new list: yesterday's prices
     are no use, and the window may open again for the first deal found. ]]
local function OnAuctionHouseShow()
  EW.ClearDeals()
  browseRead = 0
  shownThisVisit = false
  announcedThisVisit = false
  page = 1
  pcall(RefreshWindow)
end
EW.OnDealAuctionHouseShow = OnAuctionHouseShow

local MODERN_EVENTS = {
  { event = "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", read = "browse", handler = function() ReadBrowse(true) end },
  { event = "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", read = "browse", handler = function() ReadBrowse(false) end },
  { event = "COMMODITY_SEARCH_RESULTS_UPDATED", read = "commodity", handler = function(itemId) ReadCommodity(itemId) end },
  { event = "COMMODITY_SEARCH_RESULTS_ADDED", read = "commodity", handler = function(itemId) ReadCommodity(itemId) end },
  { event = "ITEM_SEARCH_RESULTS_UPDATED", read = "item", handler = function(itemKey) ReadItem(itemKey) end },
  { event = "ITEM_SEARCH_RESULTS_ADDED", read = "item", handler = function(itemKey) ReadItem(itemKey) end },
}

local modernRegistered = false
local function RegisterModern()
  if modernRegistered or not ModernOn() or InCombat() then return 0 end
  modernRegistered = true
  local count = 0
  for _, row in ipairs(MODERN_EVENTS) do
    if CanRead(row.read) and EventExists(row.event) then
      pcall(function()
        EW.RegisterEvent(row.event, row.handler)
        count = count + 1
      end)
    end
  end
  EW.dealsModernEvents = count
  return count
end
EW.RegisterModernDeals = RegisterModern

if ModernOn() and (CanRead("browse") or CanRead("commodity") or CanRead("item"))
  and EventExists("AUCTION_HOUSE_SHOW") then
  EW.RegisterEvent("AUCTION_HOUSE_SHOW", function()
    RegisterModern()
    OnAuctionHouseShow()
  end)
elseif ClassicOn() then
  EW.RegisterEvent("AUCTION_ITEM_LIST_UPDATE", ReadClassicList)
  if EventExists("AUCTION_HOUSE_SHOW") then
    EW.RegisterEvent("AUCTION_HOUSE_SHOW", OnAuctionHouseShow)
  end
end
