--[[
A small stand in for the World of Warcraft client.

It provides only the globals, frames, and events the addon actually uses, so
that the recorders can be loaded and driven outside the game. Every value a
test wants to steer lives in stub.state, and stub.Fire is the event the
client would have sent.
]]

local stub = { state = {} }

local function reset()
  stub.state = {
    time = 1700000000,
    project = 1,
    build = { "12.1.0", "60000", "Sep 17 2026", 120100 },
    map = 84,
    position = { x = 0.4213, y = 0.6187 },
    units = {},
    merchant = {},
    loot = {},
    lootSources = {},
    auction = {},
    inventory = {},
    currencies = {},
    timers = {},
    merchantApi = "modern",
    printed = {},
    combatLog = nil,
    realm = "Tichondrius",
    hardcore = false,
    -- A set of event names this client refuses to register at all: RegisterEvent
    -- for one of these fires ADDON_ACTION_FORBIDDEN naming the RegisterEvent
    -- method itself, the way the owner's own Forever alert read, and never
    -- actually registers the event. Empty by default, which is every other
    -- client's behavior today.
    forbiddenEvents = {},
    -- A set of event names this client refuses to unregister, regardless of
    -- whether they are actually registered: UnregisterEvent for one of these
    -- fires ADDON_ACTION_FORBIDDEN naming the UnregisterEvent method itself.
    -- Used to prove a refusal there is attributed to the exact event rather
    -- than falling back to every capability off. Empty by default.
    forbiddenUnregisterEvents = {},
    -- How many times UnregisterEvent has actually been called for each event
    -- name, so a test can prove a refused RegisterEvent is never followed by
    -- an unregister call at all, rather than merely one that fails quietly.
    unregisterAttempts = {},
  }
end
reset()
stub.Reset = reset

local frames = {}

local function CreateFrame(_, name)
  local frame = { events = {}, name = name }
  function frame:RegisterEvent(event)
    if stub.state.forbiddenEvents[event] then
      -- The client refuses the registration itself rather than the call the
      -- handler would have made once registered, and names the method
      -- rather than the event, exactly as the owner's own alert did: "for
      -- EverythingWoWFrame:RegisterEvent()", naming this addon.
      stub.Fire("ADDON_ACTION_FORBIDDEN", "EverythingWoW", (self.name or "Frame") .. ":RegisterEvent()")
      return
    end
    self.events[event] = true
  end
  function frame:UnregisterEvent(event)
    stub.state.unregisterAttempts[event] = (stub.state.unregisterAttempts[event] or 0) + 1
    if stub.state.forbiddenUnregisterEvents[event]
      or (stub.state.forbiddenEvents[event] and not self.events[event]) then
      -- Either this client refuses unregistering this event outright, or it
      -- is the specific case the owner's own Forever session hit: an event
      -- whose registration was refused, so the client never actually
      -- registered it, and unregistering it anyway is itself forbidden.
      -- Named the same way the owner's own alert named it.
      stub.Fire("ADDON_ACTION_FORBIDDEN", "EverythingWoW", (self.name or "Frame") .. ":UnregisterEvent()")
      return
    end
    self.events[event] = nil
  end
  function frame:IsEventRegistered(event) return self.events[event] == true end
  function frame:SetScript(which, handler) self[which] = handler end
  function frame:HookScript(which, handler) self[which .. "_hook"] = handler end
  frames[#frames + 1] = frame
  return frame
end

--[[ Forgets every frame the addon has created so far, so a fresh load of
     the addon files (a different client, for the capability gate tests)
     starts from no listeners rather than piling its frame on top of the
     previous instance's. ]]
function stub.ResetFrames()
  frames = {}
end

--[[ Runs every timer the addon has queued, and any timer those queue in turn,
     which is how the login snapshot's retry loop is driven in a test. ]]
function stub.RunTimers(rounds)
  for _ = 1, (rounds or 10) do
    local pending = stub.state.timers
    if #pending == 0 then return end
    stub.state.timers = {}
    for _, timer in ipairs(pending) do
      stub.state.time = stub.state.time + math.floor(timer.delay or 0)
      timer.callback()
    end
  end
end

function stub.Fire(event, ...)
  for _, frame in ipairs(frames) do
    if frame.events[event] and frame.OnEvent then
      frame.OnEvent(frame, event, ...)
    end
  end
end

function stub.Install(env)
  env.CreateFrame = CreateFrame
  env.SlashCmdList = {}
  env.DEFAULT_CHAT_FRAME = {
    AddMessage = function(_, text) table.insert(stub.state.printed, text) end,
  }
  env.WOW_PROJECT_ID = stub.state.project
  env.WOW_PROJECT_MAINLINE = 1
  env.WOW_PROJECT_CLASSIC = 2
  env.GOLD_AMOUNT = "%d Gold"
  env.SILVER_AMOUNT = "%d Silver"
  env.COPPER_AMOUNT = "%d Copper"

  env.time = function() return stub.state.time end
  env.GetBuildInfo = function() return table.unpack(stub.state.build) end
  env.GetRealmName = function() return stub.state.realm end

  env.C_GameRules = { IsHardcoreActive = function() return stub.state.hardcore end }

  env.C_Map = {
    GetBestMapForUnit = function(unit)
      if unit ~= "player" then return nil end
      return stub.state.map
    end,
    GetPlayerMapPosition = function()
      local position = stub.state.position
      if not position then return nil end
      return { GetXY = function() return position.x, position.y end }
    end,
  }

  -- Timers are queued rather than run, so a test decides when the client's
  -- clock would have reached them. stub.RunTimers drains the queue.
  env.C_Timer = {
    After = function(delay, callback)
      table.insert(stub.state.timers, { delay = delay, callback = callback })
    end,
    NewTicker = function() end,
  }

  env.C_CurrencyInfo = {
    GetCurrencyListSize = function() return #stub.state.currencies end,
    GetCurrencyListInfo = function(index)
      local row = stub.state.currencies[index]
      if not row then return nil end
      return { name = row.name, quantity = row.quantity, isHeader = false }
    end,
    GetCurrencyListLink = function(index)
      local row = stub.state.currencies[index]
      if not row then return nil end
      return "|cffffffff|Hcurrency:" .. row.id .. "|h[" .. row.name .. "]|h|r"
    end,
  }

  local function unit(token) return stub.state.units[token] end
  env.UnitExists = function(token) return unit(token) ~= nil end
  env.UnitIsPlayer = function(token) return (unit(token) or {}).isPlayer == true end
  env.UnitGUID = function(token) return (unit(token) or {}).guid end
  env.UnitName = function(token) return (unit(token) or {}).name end
  env.UnitLevel = function(token) return (unit(token) or {}).level end
  env.UnitClassification = function(token) return (unit(token) or {}).classification end
  env.UnitPlayerControlled = function(token) return (unit(token) or {}).playerControlled == true end
  env.UnitIsUnit = function(first, second)
    local one, two = unit(first), unit(second)
    return one ~= nil and two ~= nil and one.guid == two.guid
  end
  env.UnitReaction = function(_, token) return (unit(token) or {}).reaction end
  env.UnitClass = function() return "Shaman", "SHAMAN" end
  env.UnitRace = function() return "Orc", "Orc" end
  env.UnitFactionGroup = function() return "Horde" end

  env.IsInRaid = function() return false end
  env.GetNumGroupMembers = function() return 0 end

  env.GetQuestID = function() return stub.state.questId end
  env.GetTitleText = function() return stub.state.questTitle end

  env.GetMerchantNumItems = function() return #stub.state.merchant end
  -- Retail has C_MerchantFrame.GetItemInfo and no GetMerchantItemInfo global;
  -- Classic Era has the global and no C_MerchantFrame. stub.state.merchantApi
  -- says which client this is, so both paths are driven by the tests.
  env.C_MerchantFrame = {
    GetItemInfo = function(index)
      if stub.state.merchantApi ~= "modern" then return nil end
      local row = stub.state.merchant[index]
      if not row then return nil end
      return {
        name = row.name,
        texture = nil,
        price = row.price,
        stackCount = row.quantity or 1,
        numAvailable = -1,
        isPurchasable = true,
        isUsable = true,
        hasExtendedCost = (row.costCount or 0) > 0,
      }
    end,
  }
  env.GetMerchantItemInfo = function(index)
    if stub.state.merchantApi ~= "legacy" then return nil end
    local row = stub.state.merchant[index]
    if not row then return nil end
    return row.name, nil, row.price, row.quantity or 1, -1, true, true, (row.costCount or 0) > 0
  end
  env.GetMerchantItemLink = function(index)
    local row = stub.state.merchant[index]
    if not row then return nil end
    return "|cffffffff|Hitem:" .. row.id .. "::::::::80:::::|h[" .. (row.name or "Item") .. "]|h|r"
  end
  env.GetMerchantItemCostInfo = function(index)
    local row = stub.state.merchant[index]
    return row and row.costCount or 0
  end
  env.GetMerchantItemCostItem = function(index)
    local row = stub.state.merchant[index]
    if not row or not row.currency then return nil end
    -- itemTexture, itemValue, itemLink, currencyName
    return nil, row.currencyAmount or 1, "|cffffffff|Hcurrency:" .. row.currency .. "|h[Token]|h|r", "Token"
  end

  env.GetNumLootItems = function() return #stub.state.loot end
  env.GetLootSlotLink = function(slot)
    local row = stub.state.loot[slot]
    if not row or not row.id then return nil end
    return "|cffffffff|Hitem:" .. row.id .. "::::::::80:::::|h[Loot]|h|r"
  end
  env.GetLootSlotInfo = function(slot)
    local row = stub.state.loot[slot]
    if not row then return nil end
    return nil, row.text, row.quantity or 1
  end
  env.GetLootSourceInfo = function(slot)
    local row = stub.state.loot[slot]
    if not row then return nil end
    return row.source, row.quantity or 1
  end

  env.CombatLogGetCurrentEventInfo = function()
    local entry = stub.state.combatLog
    if not entry then return nil end
    return entry.timestamp or 0, entry.subevent, false, entry.sourceGuid, entry.sourceName,
      0, 0, entry.destGuid, entry.destName, 0, 0
  end

  env.GetInventoryItemLink = function(_, slot)
    local itemId = stub.state.inventory[slot]
    if not itemId then return nil end
    return "|cffa335ee|Hitem:" .. itemId .. ":6229::::::::80:::::|h[Gear]|h|r"
  end

  env.GetProfessions = function() return 1, 2 end
  env.GetProfessionInfo = function(index)
    return index == 1 and "Mining" or "Herbalism", nil, 300, 300, nil, nil, index == 1 and 186 or 182
  end
  env.GetNumFactions = function() return #(stub.state.factions or {}) end
  env.GetFactionInfo = function(index)
    local row = (stub.state.factions or {})[index]
    if not row then return nil end
    return row.name, nil, row.standing, nil, nil, row.value, nil, nil, false, nil, nil, nil, nil, row.id
  end

  env.GetNumAuctionItems = function() return #stub.state.auction, #stub.state.auction end
  env.GetAuctionItemLink = function(_, index)
    local row = stub.state.auction[index]
    if not row then return nil end
    return "|cffffffff|Hitem:" .. row.id .. "::::::::80:::::|h[Auction]|h|r"
  end
  env.GetAuctionItemInfo = function(_, index)
    local row = stub.state.auction[index]
    if not row then return nil end
    return "Item", nil, row.count, nil, nil, nil, nil, nil, nil, row.buyout, nil, nil, nil,
      "SomeSeller", nil, nil, row.id, true
  end

  env.GameTooltip = {
    HookScript = function(self, which, handler) self[which] = handler end,
  }

  return env
end

return stub
