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
    printed = {},
    combatLog = nil,
    realm = "Tichondrius",
    hardcore = false,
  }
end
reset()
stub.Reset = reset

local frames = {}

local function CreateFrame(_, name)
  local frame = { events = {}, name = name }
  function frame:RegisterEvent(event) self.events[event] = true end
  function frame:UnregisterEvent(event) self.events[event] = nil end
  function frame:SetScript(which, handler) self[which] = handler end
  function frame:HookScript(which, handler) self[which .. "_hook"] = handler end
  frames[#frames + 1] = frame
  return frame
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

  env.C_Timer = { After = function() end, NewTicker = function() end }

  local function unit(token) return stub.state.units[token] end
  env.UnitExists = function(token) return unit(token) ~= nil end
  env.UnitIsPlayer = function(token) return (unit(token) or {}).isPlayer == true end
  env.UnitGUID = function(token) return (unit(token) or {}).guid end
  env.UnitName = function(token) return (unit(token) or {}).name end
  env.UnitLevel = function(token) return (unit(token) or {}).level end
  env.UnitClassification = function(token) return (unit(token) or {}).classification end
  env.UnitReaction = function(_, token) return (unit(token) or {}).reaction end
  env.UnitClass = function() return "Shaman", "SHAMAN" end
  env.UnitRace = function() return "Orc", "Orc" end
  env.UnitFactionGroup = function() return "Horde" end

  env.IsInRaid = function() return false end
  env.GetNumGroupMembers = function() return 0 end

  env.GetQuestID = function() return stub.state.questId end
  env.GetTitleText = function() return stub.state.questTitle end

  env.GetMerchantNumItems = function() return #stub.state.merchant end
  env.GetMerchantItemInfo = function(index)
    local row = stub.state.merchant[index]
    if not row then return nil end
    return row.name, nil, row.price, row.quantity or 1
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
    return nil, 1, "|cffffffff|Hcurrency:" .. row.currency .. "|h[Token]|h|r"
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
