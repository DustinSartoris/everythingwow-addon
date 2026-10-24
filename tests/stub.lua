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
    -- The localized class name, the class file token, and the class id
    -- UnitClass returns for the player.
    class = { "Shaman", "SHAMAN", 7 },
    combat = false,
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
    -- From 0.2.6, a set of event names C_EventUtils.IsEventValid answers
    -- false for, the way a client answers an event it does not carry.
    -- Empty by default, so every event is valid.
    invalidEvents = {},
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
  -- The project ids Burning Crusade Classic Anniversary and Mists of
  -- Pandaria Classic report, so the tests can load the addon against each
  -- one with its own id. Neither is the mainline id, which is all the addon
  -- itself ever asks of a project id.
  env.WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 5
  env.WOW_PROJECT_MISTS_CLASSIC = 19
  -- From 0.2.5, the project ids Wrath of the Lich King Classic and
  -- Cataclysm Classic report, for the same reason. The tests load the first
  -- with Titan Reforged's version string, 3.80.2, the one 3.x client still
  -- running, and the second with 4.4.2.
  env.WOW_PROJECT_WRATH_CLASSIC = 11
  env.WOW_PROJECT_CATACLYSM_CLASSIC = 14
  env.GOLD_AMOUNT = "%d Gold"
  env.SILVER_AMOUNT = "%d Silver"
  env.COPPER_AMOUNT = "%d Copper"

  env.time = function() return stub.state.time end
  -- unpack is a global in Lua 5.1, the game's own Lua, and moved under
  -- table in 5.2, so either interpreter runs the suite.
  env.GetBuildInfo = function() return (table.unpack or unpack)(stub.state.build) end
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
  env.UnitClass = function()
    local class = stub.state.class
    return class[1], class[2], class[3]
  end
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

  env.InCombatLockdown = function() return stub.state.combat == true end

  -- Asked by the modern auction reader before it registers an event. Both
  -- Retail and the classic clients carry it.
  env.C_EventUtils = {
    IsEventValid = function(event) return not stub.state.invalidEvents[event] end,
  }

  env.GameTooltip = {
    HookScript = function(self, which, handler) self[which] = handler end,
  }

  return env
end

--[[
The talent functions, which no client stub carries by default, so that the
snapshot and every other test reads a client without them, exactly as the
suite always has. A talent test installs the shape it needs and removes it
again when it is done.
]]
local TALENT_GLOBALS = {
  "GetNumTalentTabs", "GetTalentTabInfo", "GetNumTalents", "GetTalentInfo",
  "GetTalentPrereqs", "GetTalentLink", "C_ClassTalents", "C_Traits", "C_Spell",
}

function stub.RemoveTalentApis(env)
  for _, name in ipairs(TALENT_GLOBALS) do env[name] = nil end
end

--[[ The classic talent functions over a list of tabs. A tab with an id
     answers GetTalentTabInfo in the Wrath of the Lich King Classic shape,
     id first; one without answers in the Classic Era shape, name first. A
     talent with a prereq answers GetTalentPrereqs with its tier and column,
     and one with an id answers GetTalentLink with a talent link. ]]
function stub.InstallClassicTalents(env, tabs)
  local function talent(tab, index) return ((tabs[tab] or {}).talents or {})[index] end
  env.GetNumTalentTabs = function() return #tabs end
  env.GetTalentTabInfo = function(tab)
    local row = tabs[tab]
    if not row then return nil end
    if row.id then return row.id, row.name, "A description.", row.icon, 0, row.background, 0, true end
    return row.name, row.icon, 0, row.background
  end
  env.GetNumTalents = function(tab) return #((tabs[tab] or {}).talents or {}) end
  env.GetTalentInfo = function(tab, index)
    local row = talent(tab, index)
    if not row then return nil end
    if row.numericFirst then
      -- The row and column talents of later clients answer an id first.
      return 19000 + index, row.name, row.icon, false, true, 1234
    end
    return row.name, row.icon, row.tier, row.column, row.rank or 0, row.maxRank, row.exceptional or false, true
  end
  env.GetTalentPrereqs = function(tab, index)
    local row = talent(tab, index)
    if not row or not row.prereq then return nil end
    return row.prereq[1], row.prereq[2], true
  end
  env.GetTalentLink = function(tab, index)
    local row = talent(tab, index)
    if not row or not row.id then return nil end
    return "|cff4e96f7|Htalent:" .. row.id .. ":-1|h[" .. row.name .. "]|h|r"
  end
end

--[[ C_ClassTalents and C_Traits over one config. spec.trees lists each
     tree's id and nodes; a node lists its position, maximum rank, entries
     (each an id, a definition, a spell, and an optional override name) and
     the nodes its arrows point to. A node marked empty answers with an ID
     of 0, which is the client's answer for a node the tree does not hold.
     spec.spells gives each spell's name and icon. ]]
function stub.InstallTraits(env, spec)
  local nodes, entries, definitions = {}, {}, {}
  for _, tree in ipairs(spec.trees) do
    for _, node in ipairs(tree.nodes) do
      nodes[node.id] = node
      for _, entry in ipairs(node.entries or {}) do
        entries[entry.id] = entry
        definitions[entry.definition] = entry
      end
    end
  end
  env.C_ClassTalents = { GetActiveConfigID = function() return spec.configId end }
  env.C_Traits = {
    GetConfigInfo = function(configId)
      if configId ~= spec.configId then return nil end
      local treeIds = {}
      for _, tree in ipairs(spec.trees) do treeIds[#treeIds + 1] = tree.id end
      return { ID = configId, type = 1, name = "Loadout", treeIDs = treeIds }
    end,
    GetTreeNodes = function(treeId)
      for _, tree in ipairs(spec.trees) do
        if tree.id == treeId then
          local ids = {}
          for _, node in ipairs(tree.nodes) do ids[#ids + 1] = node.id end
          return ids
        end
      end
      return {}
    end,
    GetNodeInfo = function(_, nodeId)
      local node = nodes[nodeId]
      if not node or node.empty then return { ID = 0, entryIDs = {}, visibleEdges = {} } end
      local entryIds, edges = {}, {}
      for _, entry in ipairs(node.entries or {}) do entryIds[#entryIds + 1] = entry.id end
      for _, target in ipairs(node.edges or {}) do
        edges[#edges + 1] = { visualStyle = 1, type = 0, targetNode = target, isActive = false }
      end
      return {
        ID = node.id, posX = node.x, posY = node.y, maxRanks = node.maxRanks, currentRank = 0,
        ranksPurchased = 0, type = #entryIds > 1 and 2 or 0, entryIDs = entryIds, visibleEdges = edges,
      }
    end,
    GetEntryInfo = function(_, entryId)
      local entry = entries[entryId]
      if not entry then return nil end
      return { definitionID = entry.definition, maxRanks = entry.maxRanks or 1, type = 1 }
    end,
    GetDefinitionInfo = function(definitionId)
      local entry = definitions[definitionId]
      if not entry then return nil end
      return { spellID = entry.spell, overrideName = entry.overrideName }
    end,
  }
  env.C_Spell = {
    GetSpellName = function(spellId) return ((spec.spells or {})[spellId] or {}).name end,
    GetSpellTexture = function(spellId) return ((spec.spells or {})[spellId] or {}).icon end,
  }
end

--[[
C_AuctionHouse's getters over the player's own loaded results, for the
modern auction reader from 0.2.6. No client stub carries C_AuctionHouse by
default, so the classic scan's tests read a client without it, exactly as
the suite always has; a test installs this shape and removes it again.

spec.browse lists browse rows, each an item id, a total quantity, a lowest
price and an optional battle pet species. spec.commodities maps an item id
to its listings, each a quantity and a unit price. spec.items maps an item
id to its auctions, each a quantity and an optional buyout. Every commodity
and item answer carries an owners list and a bidder, so a test can prove
neither ever reaches the file. spec.omit names functions to leave out, so a
test can stand in for a client carrying only part of the namespace. Every
call is counted in stub.state.auctionCalls by name, and the Send query
functions are present only so a test can prove the reader never calls one.
]]
function stub.InstallModernAuction(env, spec)
  stub.state.auctionCalls = {}
  local function count(name) stub.state.auctionCalls[name] = (stub.state.auctionCalls[name] or 0) + 1 end
  local api = {
    GetBrowseResults = function()
      count("GetBrowseResults")
      local results = {}
      for _, row in ipairs(spec.browse or {}) do
        results[#results + 1] = {
          itemKey = { itemID = row.id, itemLevel = row.level or 0, itemSuffix = 0,
            battlePetSpeciesID = row.pet or 0 },
          totalQuantity = row.q, minPrice = row.min, containsOwnerItem = false,
        }
      end
      return results
    end,
    GetNumCommoditySearchResults = function(itemId)
      count("GetNumCommoditySearchResults")
      return #((spec.commodities or {})[itemId] or {})
    end,
    GetCommoditySearchResultInfo = function(itemId, index)
      count("GetCommoditySearchResultInfo")
      local row = ((spec.commodities or {})[itemId] or {})[index]
      if not row then return nil end
      return {
        itemID = itemId, quantity = row.q, unitPrice = row.unit, auctionID = 1000 + index,
        owners = { "SomeSeller" }, totalNumberOfOwners = 1, timeLeftSeconds = 3600,
        numOwnerItems = 0, containsOwnerItem = false, containsAccountItem = false,
      }
    end,
    GetNumItemSearchResults = function(itemKey)
      count("GetNumItemSearchResults")
      return #((spec.items or {})[itemKey.itemID] or {})
    end,
    GetItemSearchResultInfo = function(itemKey, index)
      count("GetItemSearchResultInfo")
      local row = ((spec.items or {})[itemKey.itemID] or {})[index]
      if not row then return nil end
      return {
        itemKey = itemKey, owners = { "SomeSeller" }, totalNumberOfOwners = 1, timeLeft = 2,
        auctionID = 2000 + index, quantity = row.q, buyoutAmount = row.buyout,
        bidder = "Player-3888-0A1B2C3D", minBid = 1,
        containsOwnerItem = false, containsAccountItem = false, containsSocketedItem = false,
      }
    end,
    SendBrowseQuery = function() count("SendBrowseQuery") end,
    SendSearchQuery = function() count("SendSearchQuery") end,
    SendSellSearchQuery = function() count("SendSellSearchQuery") end,
  }
  for _, name in ipairs(spec.omit or {}) do api[name] = nil end
  env.C_AuctionHouse = api
end

function stub.RemoveModernAuction(env)
  env.C_AuctionHouse = nil
end

return stub
