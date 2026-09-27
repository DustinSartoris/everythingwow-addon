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
]]

local ADDON_NAME, EW = ...

EW.AUCTION_ROWS_PER_OBSERVATION = 50
EW.AUCTION_ROW_CAP = 500

local function HasModernAuctionApi()
  return C_AuctionHouse ~= nil
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
-- every time the player opens the auction house. Where it is off, this
-- recorder says so once in chat at the next login rather than staying
-- silently idle, the same as every other recorder that cannot do its job on
-- a client.
if EW.Caps and EW.Caps.auction then
  EW.RegisterEvent("AUCTION_ITEM_LIST_UPDATE", OnListUpdate)
else
  EW.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    if EW.auctionIdleAnnounced then return end
    EW.auctionIdleAnnounced = true
    EW.Print("Auction recording is off for this client; the auction listener stays idle.")
  end)
end
