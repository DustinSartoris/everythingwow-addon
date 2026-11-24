--[[
The item recorder.

Blizzard's item API does not hold every item of WoW Forever. On 23 November
2026 the site's worker asked it by id for four items its own auction houses
sell and each answered 404, and 295 of the 296 auction items the site had no
page for were new WoW Forever items, ids above 200,000. Their names and what
they are can only come from players, so from 0.2.12 the addon notes an item
the first time it meets one: at the auction house, in loot, at a vendor and
in a quest's rewards.

One item observation is the item as the client's own item cache describes
it, the same for every player: n, the name; ql, the quality number; il, the
item level; rl, the level it requires; c and sc, the class and subclass
numbers; slot, the equip location token such as INVTYPE_HEAD; stack, where it
stacks; sell, what a vendor pays in copper; bind, the binding number; stats,
the base item's stats by the client's own key, such as
ITEM_MOD_STAMINA_SHORT; and sp, the spell a use triggers. The item is always
asked for by its bare id, never by the link in front of the player, so a
random suffix, an enchant or a maker's name never reaches the file, and two
players describe the same item the same way.

Nothing of the player is in it, no position is written, and no request is
sent that the game's own windows do not already send: the facts are read
from the item cache, and an item the client has not loaded yet is tried
again the next few times an item is met, the way the deals window reads a
sell price.

It runs on WoW Forever alone, and only for ids from EW.ITEM_ID_FLOOR up,
where the gap is. From 0.2.13 it also leaves alone every item in
EW.KNOWN_ITEMS, the list in Known.lua of the items the site already has from
Blizzard: the owner's first file from 0.2.12 spent 340 of its 400 item
observations on such items. An item is written once: the saved file remembers the day
each was noted and notes it again only after EW.ITEM_RENOTE_DAYS, after a
patch, or after /ewow clear, and a session writes at most
EW.ITEMS_PER_SESSION of them, so a first walk through a full auction house
never pushes the NPCs, loot and quests out of the buffer.
]]

local ADDON_NAME, EW = ...

EW.ITEM_ID_FLOOR = 200000
EW.ITEMS_PER_SESSION = 400
EW.ITEM_RENOTE_DAYS = 14
EW.ITEM_NAME_BYTES = 80
EW.ITEM_STAT_CAP = 16
EW.ITEM_STAT_KEY_BYTES = 48
EW.ITEM_PENDING_CAP = 600
EW.ITEM_PENDING_TRIES = 5
EW.ITEM_SWEEP = 40
-- Raised when the payload's shape changes, so every item is noted afresh.
EW.ITEM_FORMAT = 1

-- The session's own memory: ids already settled, ids the client had not
-- loaded yet, and how many observations this session has written.
local settled = {}
local pending, pendingCount = {}, 0
local written = 0
local lastSweep = 0
local on = nil

--[[
Whether the site already has the item from Blizzard, by EW.KNOWN_ITEMS: a
string of ids and "low-high" ranges in rising order. It is read once into two
arrays and searched by halving. A list that cannot be read is no list, so
every item is noted, as before 0.2.13.
]]
local knownFrom, knownLow, knownHigh = nil, {}, {}
local function ReadKnown()
  knownFrom, knownLow, knownHigh = EW.KNOWN_ITEMS, {}, {}
  if type(knownFrom) ~= "string" then return end
  local low, high, last, count = {}, {}, 0, 0
  for part in knownFrom:gmatch("[^,]+") do
    local a, b = part:match("^(%d+)%-(%d+)$")
    if not a then a = part:match("^(%d+)$") b = a end
    a, b = tonumber(a), tonumber(b)
    -- One entry out of order or out of shape and the whole list is refused.
    if not a or not b or a <= last or b < a then return end
    count = count + 1
    low[count], high[count], last = a, b, b
  end
  knownLow, knownHigh = low, high
end

local function Known(itemId)
  if knownFrom ~= EW.KNOWN_ITEMS then pcall(ReadKnown) end
  local first, last = 1, #knownLow
  while first <= last do
    local middle = math.floor((first + last) / 2)
    if itemId < knownLow[middle] then
      last = middle - 1
    elseif itemId > knownHigh[middle] then
      first = middle + 1
    else
      return true
    end
  end
  return false
end
EW.ItemKnown = Known

local function On()
  if on == nil then
    local key
    pcall(function() key = EW.VersionKey() end)
    on = key == "forever"
  end
  return on
end

--[[ The saved memory of which items this file has noted, and on which day.
     It starts over when the payload's shape or the game's patch changes. ]]
local function Memory()
  local db = EW.Database()
  if type(db.items) ~= "table" or db.itemsFormat ~= EW.ITEM_FORMAT or db.itemsPatch ~= db.patch then
    db.items = {}
    db.itemsFormat = EW.ITEM_FORMAT
    db.itemsPatch = db.patch
  end
  return db.items
end

local function Today()
  return math.floor(EW.Now() / 86400)
end

local function ItemFunction(name)
  local found
  pcall(function()
    local api = rawget(_G, "C_Item")
    if type(api) == "table" and type(api[name]) == "function" then
      found = api[name]
    elseif type(rawget(_G, name)) == "function" then
      found = rawget(_G, name)
    end
  end)
  return found
end

local function WholeNumber(value, low, high)
  if type(value) ~= "number" or value ~= value then return nil end
  value = math.floor(value)
  if value < low or value > high then return nil end
  return value
end

--[[
The item as the client's item cache describes it, or nil with a reason:
"unloaded" where the client has not loaded the item yet, which is worth
trying again, and "refused" where the name is not fit to store, which is not.
]]
local function ItemFacts(itemId)
  local facts, reason = nil, "unloaded"
  pcall(function()
    local get = ItemFunction("GetItemInfo")
    if not get then reason = "refused" return end
    local name, _, quality, itemLevel, minLevel, _, _, stack, equipLoc, _, sell, classId, subclassId, bindType =
      get(itemId)
    if type(name) ~= "string" or name == "" then return end
    if #name > EW.ITEM_NAME_BYTES or name:find("|", 1, true) or name:find("%c") then
      reason = "refused"
      return
    end
    facts = { n = name }
    facts.ql = WholeNumber(quality, 0, 8)
    facts.il = WholeNumber(itemLevel, 1, 2000)
    facts.rl = WholeNumber(minLevel, 1, 100)
    facts.c = WholeNumber(classId, 0, 99)
    facts.sc = WholeNumber(subclassId, 0, 99)
    facts.stack = WholeNumber(stack, 2, 100000)
    facts.sell = WholeNumber(sell, 1, 99999999999)
    facts.bind = WholeNumber(bindType, 1, 9)
    if type(equipLoc) == "string" and #equipLoc <= 32 and equipLoc:find("^INVTYPE_[A-Z0-9_]+$") then
      facts.slot = equipLoc
    end
  end)
  if not facts then return nil, reason end

  -- The base item's stats, asked for by the bare id for the reason above.
  pcall(function()
    local get = ItemFunction("GetItemStats")
    if not get then return end
    local stats = get("item:" .. itemId)
    if type(stats) ~= "table" then return end
    local keys = {}
    for key, value in pairs(stats) do
      if type(key) == "string" and #key <= EW.ITEM_STAT_KEY_BYTES and key:find("^[A-Z][A-Z0-9_]*$")
        and type(value) == "number" and value == value and value ~= 0
        and value > -1000000 and value < 1000000 then
        keys[#keys + 1] = key
      end
    end
    if #keys == 0 then return end
    table.sort(keys)
    local kept = {}
    for index = 1, math.min(#keys, EW.ITEM_STAT_CAP) do
      kept[keys[index]] = EW.Round(stats[keys[index]], 2)
    end
    facts.stats = kept
  end)

  -- The spell a use triggers, where the item has one.
  pcall(function()
    local get = ItemFunction("GetItemSpell")
    if not get then return end
    local _, spellId = get(itemId)
    facts.sp = WholeNumber(spellId, 1, 9999999)
  end)

  return facts
end
EW.ItemFacts = ItemFacts

local function Forget(itemId)
  if pending[itemId] ~= nil then
    pending[itemId] = nil
    pendingCount = pendingCount - 1
  end
end

--[[ Writes one item, or keeps it for another try. True where it was written. ]]
local function Try(itemId)
  if written >= EW.ITEMS_PER_SESSION then return false end
  local facts, reason = ItemFacts(itemId)
  if not facts then
    if reason == "refused" then
      settled[itemId] = true
      Forget(itemId)
      return false
    end
    local tries = (pending[itemId] or 0) + 1
    if tries > EW.ITEM_PENDING_TRIES then
      -- Left for another session rather than asked for without end.
      settled[itemId] = true
      Forget(itemId)
    elseif pending[itemId] ~= nil then
      pending[itemId] = tries
    elseif pendingCount < EW.ITEM_PENDING_CAP then
      pending[itemId] = tries
      pendingCount = pendingCount + 1
    end
    return false
  end
  settled[itemId] = true
  Forget(itemId)
  if not EW.Record("item", "item", itemId, nil, nil, nil, facts) then return false end
  Memory()[itemId] = Today()
  written = written + 1
  return true
end

--[[ Tries a few of the items the client had not loaded, at most once a second. ]]
local function Sweep()
  if pendingCount < 1 then return end
  local now = EW.Now()
  if now == lastSweep then return end
  lastSweep = now
  local batch = {}
  for itemId in pairs(pending) do
    batch[#batch + 1] = itemId
    if #batch >= EW.ITEM_SWEEP then break end
  end
  for _, itemId in ipairs(batch) do Try(itemId) end
end

--[[
Called by every recorder that meets an item, with the item's id and, where
there is one, the link it was read from. A link that is not an item's, a
currency's for one, is left alone. Returns true where an observation was
written.
]]
function EW.NoteItem(itemId, link)
  if not On() then return false end
  if type(itemId) ~= "number" or itemId ~= itemId then return false end
  itemId = math.floor(itemId)
  if itemId < EW.ITEM_ID_FLOOR or itemId > 9999999 then return false end
  if type(link) == "string" and not link:find("item:%d") then return false end
  local wrote = false
  if not settled[itemId] and Known(itemId) then settled[itemId] = true end
  if not settled[itemId] then
    local ok = pcall(function()
      local noted = Memory()[itemId]
      if type(noted) == "number" and (Today() - noted) < EW.ITEM_RENOTE_DAYS then
        settled[itemId] = true
      else
        wrote = Try(itemId)
      end
    end)
    if not ok then settled[itemId] = true end
  end
  pcall(Sweep)
  return wrote
end

--[[ /ewow clear empties the buffer, so the memory of what it held goes too. ]]
function EW.ForgetItems()
  settled = {}
  pending, pendingCount = {}, 0
  written = 0
  lastSweep = 0
  local db = EW.Database()
  db.items, db.itemsFormat, db.itemsPatch = nil, nil, nil
end

--[[ For the status line and the tests: written this session, and waiting. ]]
function EW.ItemCounts()
  return written, pendingCount
end
