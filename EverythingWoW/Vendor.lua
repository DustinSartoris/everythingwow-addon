--[[
The vendor recorder.

One merchant window is one observation: the vendor npc is the subject and the
payload holds the stock. Prices are in copper, which is the unit the client
returns and the unit the site stores.

Reading the price is the thing this recorder got wrong in 0.1.0. Retail no
longer has the GetMerchantItemInfo global: the merchant frame moved to
C_MerchantFrame.GetItemInfo, which answers with one table rather than ten
return values. The old call was wrapped in pcall, so on a live Retail client
it failed silently and every item was written with its id alone, which is
exactly what the first live sample shows. Both shapes are read here, the
table first and the positional call second, so the same file serves Retail
and Classic Era:

  C_MerchantFrame.GetItemInfo(index) -> { name, texture, price, stackCount,
      numAvailable, isPurchasable, isUsable, hasExtendedCost, currencyID,
      spellID }
  GetMerchantItemInfo(index) -> name, texture, price, stackCount,
      numAvailable, isPurchasable, isUsable, extendedCost

Where an item is bought with something other than copper, the copper price is
zero and the client has an extended cost: GetMerchantItemCostInfo reports how
many cost items it takes and GetMerchantItemCostItem(index, 1) returns that
cost's texture, its amount, and its link, so the currency id and the amount
are both recorded. A zero copper price with an extended cost is written as a
price of zero and a currency, never as a price alone, because the item is not
free and a missing currency would read as though it were.

At most 100 items are read from one visit, which is the cap Section 9.2's
vendor lists need and which keeps the payload inside the 4,000 byte cap after
trimming.
]]

local ADDON_NAME, EW = ...

EW.VENDOR_ITEM_CAP = 100

local function IdFromLink(link)
  if type(link) ~= "string" then return nil end
  local itemId = link:match("|?H?item:(%d+)")
  if itemId then return tonumber(itemId) end
  local currencyId = link:match("|?H?currency:(%d+)")
  if currencyId then return tonumber(currencyId) end
  return nil
end
EW.IdFromLink = IdFromLink

--[[ The copper price, the stack size, and whether the client says this item
     carries an extended cost, from whichever merchant API the client has. ]]
local function ItemInfo(index)
  local price, quantity, extended
  pcall(function()
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
      local info = C_MerchantFrame.GetItemInfo(index)
      if type(info) == "table" then
        price = info.price
        quantity = info.stackCount
        local flag = info.hasExtendedCost
        if flag == nil then flag = info.extendedCost end
        extended = flag and true or false
        return
      end
    end
    if type(rawget(_G, "GetMerchantItemInfo")) == "function" then
      local _, _, itemPrice, stackCount, _, _, _, extendedCost = GetMerchantItemInfo(index)
      price = itemPrice
      quantity = stackCount
      extended = extendedCost and true or false
    end
  end)
  return price, quantity, extended
end
EW.MerchantItemInfo = ItemInfo

--[[ The currency an extended cost is paid in, as an id and an amount. ]]
local function CurrencyFor(index)
  local costCount
  pcall(function() costCount = GetMerchantItemCostInfo(index) end)
  if type(costCount) ~= "number" or costCount < 1 then return nil end
  local link, amount
  pcall(function()
    local _, itemValue, itemLink = GetMerchantItemCostItem(index, 1)
    link, amount = itemLink, itemValue
  end)
  local id = IdFromLink(link)
  if not id then return nil end
  if type(amount) ~= "number" or amount < 0 then amount = nil end
  return id, amount
end
EW.MerchantCurrency = CurrencyFor

local function RecordMerchant()
  local guid = UnitGUID("npc")
  local subject, npcId = EW.SubjectFromGuid(guid)
  if subject ~= "npc" or not npcId then
    EW.CountIgnored("no_id")
    return false
  end

  local count = 0
  pcall(function() count = GetMerchantNumItems() or 0 end)
  if count < 1 then return false end
  if count > EW.VENDOR_ITEM_CAP then count = EW.VENDOR_ITEM_CAP end

  local items = {}
  for index = 1, count do
    local link
    pcall(function() link = GetMerchantItemLink(index) end)
    local itemId = IdFromLink(link)
    if itemId then
      local price, quantity, extended = ItemInfo(index)
      local currency, amount = CurrencyFor(index)
      local entry = { id = itemId }
      if type(price) == "number" and price >= 0 then
        -- Zero is a price: it is what an item bought with a currency costs in
        -- copper, and it is written beside that currency rather than dropped.
        entry.price = math.floor(price)
      end
      if type(quantity) == "number" and quantity > 1 then entry.q = quantity end
      if currency then
        entry.currency = currency
        if amount then entry.currency_q = amount end
        if entry.price == nil then entry.price = 0 end
      elseif extended then
        -- The client says there is an extended cost and would not name it, so
        -- the copper price alone would misread as the whole price.
        entry.extended = true
      end
      items[#items + 1] = entry
    end
  end

  if #items == 0 then return false end

  local mapId, x, y = EW.PlayerPosition()
  if not mapId then
    EW.CountSkipped("no_map")
  elseif x == nil or y == nil then
    EW.CountSkipped("no_position")
  end
  return EW.Record("vendor", "vendor", npcId, mapId, x, y, { items = items })
end

EW.RecordMerchant = RecordMerchant

EW.RegisterEvent("MERCHANT_SHOW", function() RecordMerchant() end)
