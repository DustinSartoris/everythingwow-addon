--[[
The vendor recorder.

One merchant window is one observation: the vendor npc is the subject and the
payload holds the stock. Prices are in copper, which is the unit the client
returns and the unit the site stores. Where an item is bought with something
other than copper, GetMerchantItemCostInfo reports how many cost items it
takes and GetMerchantItemCostItem names the first of them, and its id is
recorded as the currency.

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

local function CurrencyFor(index)
  local costCount
  pcall(function() costCount = GetMerchantItemCostInfo(index) end)
  if type(costCount) ~= "number" or costCount < 1 then return nil end
  local link
  pcall(function()
    local _, _, itemLink = GetMerchantItemCostItem(index, 1)
    link = itemLink
  end)
  return IdFromLink(link)
end

local function RecordMerchant()
  local guid = UnitGUID("npc")
  local subject, npcId = EW.SubjectFromGuid(guid)
  if subject ~= "npc" or not npcId then return false end

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
      local price, quantity
      pcall(function()
        local _, _, itemPrice, itemQuantity = GetMerchantItemInfo(index)
        price, quantity = itemPrice, itemQuantity
      end)
      local entry = { id = itemId }
      if type(price) == "number" and price >= 0 then entry.price = math.floor(price) end
      if type(quantity) == "number" and quantity > 1 then entry.q = quantity end
      local currency = CurrencyFor(index)
      if currency then entry.currency = currency end
      items[#items + 1] = entry
    end
  end

  if #items == 0 then return false end

  local mapId, x, y = EW.PlayerPosition()
  return EW.Record("vendor", "vendor", npcId, mapId, x, y, { items = items })
end

EW.RecordMerchant = RecordMerchant

EW.RegisterEvent("MERCHANT_SHOW", function() RecordMerchant() end)
