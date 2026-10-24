--[[
The auction recorder.

Section 9.2 asks for auction scans on the versions without an auction API,
which is exactly what this records: it runs on Classic Era and Hardcore,
where C_AuctionHouse does not exist, and it does nothing at all on Retail,
where Blizzard's own auction API is what the site reads.

It never runs a query of its own. The addon reads the page the player's own
search has already loaded, which is what AUCTION_ITEM_LIST_UPDATE announces,
so the addon never sends a request to Blizzard's servers and never slows the
auction house down for the player.

The seller is never recorded. GetAuctionItemInfo returns the owner's name and
that name is another player, so it is read past and thrown away.

0.2.2 adds the auction capability, gating AUCTION_ITEM_LIST_UPDATE and the
functions below: the owner's own Forever probe refused the event outright,
which is the client this addon most needs to stay quiet for, so this
recorder now checks caps.auction before it ever registers rather than
finding out from an alert.

0.2.6 adds a second reader below this scan, for clients whose auction house
is C_AuctionHouse but whose realms Blizzard's auction API does not cover,
Forever first among them, and makes an idle recorder silent at login.
]]

local ADDON_NAME, EW = ...

EW.AUCTION_ROWS_PER_OBSERVATION = 50
EW.AUCTION_ROW_CAP = 500

-- From 0.2.6 the classic scan steps aside only where the modern reader
-- below can actually read the browse list, rather than wherever a
-- C_AuctionHouse table exists at all, so a client carrying a partial
-- C_AuctionHouse beside the classic list functions is still scanned.
local function HasModernAuctionApi()
  local present = false
  pcall(function()
    local api = rawget(_G, "C_AuctionHouse")
    present = type(api) == "table" and type(api.GetBrowseResults) == "function"
  end)
  return present
end

local function OnListUpdate()
  if HasModernAuctionApi() then return false end
  if type(rawget(_G, "GetNumAuctionItems")) ~= "function" then return false end

  local batch = 0
  pcall(function() batch = (GetNumAuctionItems("list")) or 0 end)
  if batch < 1 then return false end
  if batch > EW.AUCTION_ROW_CAP then batch = EW.AUCTION_ROW_CAP end

  local mapId = EW.PlayerPosition()
  local items = {}
  local written = 0

  local function Flush()
    if #items == 0 then return end
    EW.Record("auction", "auction", nil, mapId, nil, nil, { items = items })
    written = written + 1
    items = {}
  end

  for index = 1, batch do
    local itemId, count, buyout
    pcall(function()
      local link
      link = GetAuctionItemLink and GetAuctionItemLink("list", index) or nil
      itemId = EW.IdFromLink(link)
      local _, _, quantity, _, _, _, _, _, _, buyoutPrice = GetAuctionItemInfo("list", index)
      count, buyout = quantity, buyoutPrice
    end)
    if itemId and type(count) == "number" and count > 0 then
      local entry = { id = itemId, q = count }
      if type(buyout) == "number" and buyout > 0 then
        entry.unit = math.floor(buyout / count)
        entry.buyout = math.floor(buyout)
      end
      items[#items + 1] = entry
      if #items >= EW.AUCTION_ROWS_PER_OBSERVATION then Flush() end
    end
  end
  Flush()

  return written > 0
end

EW.OnAuctionListUpdate = OnListUpdate

-- Gated behind caps.auction: the owner's own Forever probe refused
-- AUCTION_ITEM_LIST_UPDATE outright, so where the capability is off the
-- listener is never registered at all rather than registered and refused
-- every time the player opens the auction house.
--
-- 0.2.2 also printed a chat line at the next login where the capability was
-- off, saying the auction listener stayed idle. 0.2.6 drops it on the
-- owner's word of 24 October 2026, "It should be silent": an idle recorder is
-- the addon working as designed for that client, not something the player
-- can act on, and `/ewow status` still names every idle recorder for anyone
-- who asks.
if EW.Caps and EW.Caps.auction then
  EW.RegisterEvent("AUCTION_ITEM_LIST_UPDATE", OnListUpdate)
end

--[[
The modern auction reader, from 0.2.6.

Forever's client carries the Retail project id, and the classic event this
file listens for above is one that client does not know: the owner's probe
reported AUCTION_ITEM_LIST_UPDATE refused with no forbidden report beside
it, where the combat log's refusal raised one, which is what a client
answering an unknown event looks like rather than one forbidding it. The
mainline client's auction house is C_AuctionHouse, and Blizzard publishes no
auction API for Forever's realms, so the player's own browsing is the only
source the site has there. This reader is that source. It also serves any
classic family client that carries C_AuctionHouse, such as Cataclysm Classic
and Mists Classic, where the classic scan above steps aside. It is off on
Retail through caps.auctionModern, because the site reads Retail's auctions
from Blizzard's own API.

It is passive in exactly the way the classic scan is. It never sends a query
of its own: no SendBrowseQuery, no SendSearchQuery, no
SendSellSearchQuery, nothing that asks Blizzard's servers for a page. It reads
only what the player's own search has already loaded, at the moment the
client announces it:

  AUCTION_HOUSE_BROWSE_RESULTS_UPDATED and _ADDED, through
      C_AuctionHouse.GetBrowseResults(): the item key, the lowest price and
      the total quantity of each result row.
  COMMODITY_SEARCH_RESULTS_UPDATED and _ADDED, through
      GetNumCommoditySearchResults and GetCommoditySearchResultInfo: each
      listing's unit price and quantity.
  ITEM_SEARCH_RESULTS_UPDATED and _ADDED, through GetNumItemSearchResults
      and GetItemSearchResultInfo: each auction's buyout and quantity.

The seller is never recorded. A commodity or item result carries an owners
list of player names, and nothing here reads it, nor the bidder, nor the
flags saying whether a listing is the player's own.

Every row is written in the classic scan's own shape, { id, q, unit, buyout }
in copper, 50 rows to an observation and at most 500 rows for one
announcement, so the site's reader and its upload definer take it unchanged.
The payload also names which of the three reads wrote it in source, because
a browse row's unit is the lowest price across every listing of the item
while a commodity or item row is one listing, and the two cannot be told
apart by their fields alone.

Safety. Every C_AuctionHouse call sits inside pcall. The result events are
registered only once the player first opens the auction house, never at
login, so a client that refused them would do so at the auction house
rather than on every login; from load the reader listens only for
AUCTION_HOUSE_SHOW, the window opening, the same kind of event as
MERCHANT_SHOW, which the owner's probe allowed. Each result event is
registered only where the client says
the event exists (C_EventUtils.IsEventValid, where the client has it) and
the functions that read it exist. A registration that throws is swallowed by
EW.RegisterEvent, and one the client forbids turns off auctionModern alone,
through EVENT_CAPABILITY in Core.lua. None of these functions is protected,
and nothing here runs in combat: a handler that fires in combat returns at
once.
]]

-- A search the player repeats inside this window reads only the rows the
-- client added since the last read; past it, the whole result is a fresh
-- reading and is read again from the first row.
EW.AUCTION_REREAD_SECONDS = 60

local MODERN_EVENTS = {
  { event = "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", read = "browse", fresh = true },
  { event = "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", read = "browse" },
  { event = "COMMODITY_SEARCH_RESULTS_UPDATED", read = "commodity" },
  { event = "COMMODITY_SEARCH_RESULTS_ADDED", read = "commodity" },
  { event = "ITEM_SEARCH_RESULTS_UPDATED", read = "item" },
  { event = "ITEM_SEARCH_RESULTS_ADDED", read = "item" },
}
EW.AUCTION_MODERN_EVENTS = {}
for _, row in ipairs(MODERN_EVENTS) do
  EW.AUCTION_MODERN_EVENTS[#EW.AUCTION_MODERN_EVENTS + 1] = row.event
end

-- The C_AuctionHouse functions each read needs, every one of them a getter.
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

--[[ Whether the client knows an event. Asked through C_EventUtils where the
     client has it, which answers without registering anything; a client
     without it is taken at its word that the event may exist, and the
     function check beside it is what decides. ]]
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

local function InCombat()
  local fighting = false
  pcall(function()
    if type(rawget(_G, "InCombatLockdown")) == "function" then
      fighting = InCombatLockdown() and true or false
    end
  end)
  return fighting
end

local function ModernOn()
  return EW.Caps ~= nil and EW.Caps.auctionModern == true
end

--[[ One entry in the classic scan's shape, or nil for a row with no item id
     or no quantity. unit is the price of one, and buyout is the price of the
     whole listing where the client gives one. ]]
local function Entry(itemId, quantity, unit, buyout)
  if type(itemId) ~= "number" or itemId <= 0 then return nil end
  if type(quantity) ~= "number" or quantity <= 0 then return nil end
  local entry = { id = math.floor(itemId), q = math.floor(quantity) }
  if type(buyout) == "number" and buyout > 0 then
    entry.buyout = math.floor(buyout)
    if type(unit) ~= "number" or unit <= 0 then unit = buyout / quantity end
  end
  if type(unit) == "number" and unit > 0 then entry.unit = math.floor(unit) end
  return entry
end

--[[ Writes a list of entries as observations of 50 rows each. ]]
local function Write(entries, source)
  if #entries == 0 then return 0 end
  local mapId = EW.PlayerPosition()
  local written = 0
  local items = {}
  local function Flush()
    if #items == 0 then return end
    if EW.Record("auction", "auction", nil, mapId, nil, nil, { items = items, source = source }) then
      written = written + 1
    end
    items = {}
  end
  for _, entry in ipairs(entries) do
    items[#items + 1] = entry
    if #items >= EW.AUCTION_ROWS_PER_OBSERVATION then Flush() end
  end
  Flush()
  return written
end

--[[ How far each result has been read: the browse list as a whole, and each
     commodity or item search by its key. Held in memory for the session. ]]
local readUpTo = {}

local function StartFor(key, total)
  local now = EW.Now()
  local seen = readUpTo[key]
  if not seen or total < seen.n or (now - seen.t) >= EW.AUCTION_REREAD_SECONDS then
    return 1
  end
  return seen.n + 1
end

local function MarkRead(key, upTo)
  readUpTo[key] = { n = upTo, t = EW.Now() }
end

--[[ The browse list. A fresh search (the _UPDATED event) is read from its
     first row; rows the client appends (the _ADDED event) from the first
     one not yet read. A battle pet's row names the pet cage rather than the
     pet, so it is passed over rather than priced as the cage. ]]
local function ReadBrowse(fresh)
  if not ModernOn() or InCombat() or not CanRead("browse") then return 0 end
  local results
  pcall(function() results = C_AuctionHouse.GetBrowseResults() end)
  if type(results) ~= "table" then return 0 end
  local total = #results
  if fresh then readUpTo.browse = nil end
  local start = StartFor("browse", total)
  if start > total then return 0 end
  local last = math.min(total, start + EW.AUCTION_ROW_CAP - 1)

  local entries = {}
  for index = start, last do
    local entry
    pcall(function()
      local row = results[index]
      local key = type(row) == "table" and row.itemKey or nil
      if type(key) ~= "table" then return end
      if type(key.battlePetSpeciesID) == "number" and key.battlePetSpeciesID > 0 then return end
      entry = Entry(key.itemID, row.totalQuantity, row.minPrice, nil)
    end)
    if entry then entries[#entries + 1] = entry end
  end
  MarkRead("browse", last)
  return Write(entries, "browse")
end
EW.OnAuctionBrowseResults = ReadBrowse

--[[ One commodity's listings, each a unit price and a quantity. ]]
local function ReadCommodity(itemId)
  if not ModernOn() or InCombat() or not CanRead("commodity") then return 0 end
  if type(itemId) ~= "number" or itemId <= 0 then return 0 end
  local total = 0
  pcall(function() total = C_AuctionHouse.GetNumCommoditySearchResults(itemId) or 0 end)
  if type(total) ~= "number" or total < 1 then return 0 end
  local key = "commodity:" .. itemId
  local start = StartFor(key, total)
  if start > total then return 0 end
  local last = math.min(total, start + EW.AUCTION_ROW_CAP - 1)

  local entries = {}
  for index = start, last do
    local entry
    pcall(function()
      local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemId, index)
      if type(info) ~= "table" then return end
      local quantity, unit = info.quantity, info.unitPrice
      local buyout = (type(unit) == "number" and type(quantity) == "number") and unit * quantity or nil
      entry = Entry(info.itemID or itemId, quantity, unit, buyout)
    end)
    if entry then entries[#entries + 1] = entry end
  end
  MarkRead(key, last)
  return Write(entries, "commodity")
end
EW.OnAuctionCommodityResults = ReadCommodity

local function ItemKeyString(itemKey)
  return table.concat({
    tostring(itemKey.itemID), tostring(itemKey.itemLevel or 0),
    tostring(itemKey.itemSuffix or 0), tostring(itemKey.battlePetSpeciesID or 0),
  }, ":")
end

--[[ One item's auctions, each a buyout for the whole auction and its
     quantity. An auction with a bid and no buyout still records its
     quantity, as the classic scan does. ]]
local function ReadItem(itemKey)
  if not ModernOn() or InCombat() or not CanRead("item") then return 0 end
  if type(itemKey) ~= "table" or type(itemKey.itemID) ~= "number" then return 0 end
  if type(itemKey.battlePetSpeciesID) == "number" and itemKey.battlePetSpeciesID > 0 then return 0 end
  local total = 0
  pcall(function() total = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0 end)
  if type(total) ~= "number" or total < 1 then return 0 end
  local key = "item:" .. ItemKeyString(itemKey)
  local start = StartFor(key, total)
  if start > total then return 0 end
  local last = math.min(total, start + EW.AUCTION_ROW_CAP - 1)

  local entries = {}
  for index = start, last do
    local entry
    pcall(function()
      local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, index)
      if type(info) ~= "table" then return end
      local id = type(info.itemKey) == "table" and info.itemKey.itemID or itemKey.itemID
      entry = Entry(id, info.quantity, nil, info.buyoutAmount)
    end)
    if entry then entries[#entries + 1] = entry end
  end
  MarkRead(key, last)
  return Write(entries, "item")
end
EW.OnAuctionItemResults = ReadItem

local HANDLERS = {
  browse = function(fresh) return function() ReadBrowse(fresh) end end,
  commodity = function() return function(itemId) ReadCommodity(itemId) end end,
  item = function() return function(itemKey) ReadItem(itemKey) end end,
}

--[[ Registers every result event this client can read, once, the first time
     the player opens the auction house out of combat. Returns how many
     events it asked for; one the client refuses is swallowed by
     EW.RegisterEvent and placed at auctionModern by the forbidden handler. ]]
local modernRegistered = false
local function RegisterModernReader()
  if modernRegistered or not ModernOn() or InCombat() then return 0 end
  modernRegistered = true
  local count = 0
  for _, row in ipairs(MODERN_EVENTS) do
    if CanRead(row.read) and EventExists(row.event) then
      pcall(function()
        EW.RegisterEvent(row.event, HANDLERS[row.read](row.fresh))
        count = count + 1
      end)
    end
  end
  EW.auctionModernEvents = count
  return count
end
EW.RegisterModernAuctionReader = RegisterModernReader

--[[ Which auction recorder this client runs, for `/ewow status`: "modern"
     where the reader above can read at least one result, "classic" where
     the classic scan runs, and "idle" otherwise, which is Retail by design
     and any client whose auction house neither path can read. ]]
function EW.AuctionMode()
  if ModernOn() and (CanRead("browse") or CanRead("commodity") or CanRead("item")) then
    return "modern"
  end
  if EW.Caps and EW.Caps.auction and not HasModernAuctionApi()
    and type(rawget(_G, "GetNumAuctionItems")) == "function" then
    return "classic"
  end
  return "idle"
end

-- Gated behind caps.auctionModern, and only where the client carries at
-- least one of the three reads, so Retail, an unknown client, and a classic
-- client without C_AuctionHouse register nothing for it at all.
if ModernOn() and (CanRead("browse") or CanRead("commodity") or CanRead("item"))
  and EventExists("AUCTION_HOUSE_SHOW") then
  EW.RegisterEvent("AUCTION_HOUSE_SHOW", function() RegisterModernReader() end)
end
