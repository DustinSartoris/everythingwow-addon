--[[
The talent tree recorder, `/ewow talents`.

The site's Classic and Forever talent calculators need every class's trees
as the game client itself draws them: each tree, each talent's place in the
grid, its maximum rank, and the arrow from its one prerequisite. Blizzard's
Classic Game Data API publishes no talent document, and a datamined table or
another site's database is not a source this project uses, so the one
allowed source is the client's own talent functions read on a character of
each class. This file is that read, and nothing else.

It records the layout of the trees, never a build: no rank the character has
spent, no character name, no realm. The class is the only thing about the
character it names, beside the level, which says how far the client had
opened the trees when the read was taken.

Two client APIs can carry the trees, and Forever's is not known before its
launch: the owner's build 1.60.1 session carries the mainline project id, the
id Retail reports, so its talents may come through the classic functions
(GetNumTalentTabs, GetTalentTabInfo, GetNumTalents, GetTalentInfo,
GetTalentPrereqs) or through the modern ones (C_ClassTalents and C_Traits'
config, tree, node, entry and definition info). Both are read behind feature
detection, every call inside pcall, the classic shape first because it is
the three tree shape Forever's trees keep. Where both answer, the second is
kept beside the first rather than thrown away, because the launch day read
is the one chance to see which of the two the client means. Where neither
answers, a diagnostic naming which of the functions exist is written
instead, so a failed read still says why.

None of these functions is protected or restricted in combat; they read
what the talent frame reads. The command still waits for the player to
leave combat, which costs nothing and keeps the read away from the one
moment the client is strictest.

The captures are kept in their own saved variable, EverythingWoWTalentsDB,
beside EverythingWoWDB in the same EverythingWoW.lua file. The site's upload
page reads EverythingWoWDB alone and sends only its version, patch, addon
and observations, so a capture never reaches the upload's validation, its
5,000 observation count, or its payload caps, and /ewow clear, which empties
the observations, leaves the captures alone. One capture is held per class
per client, keyed "<client>:<CLASS>", so a second read of the same class on
the same client replaces the first and nine classes give nine entries.
]]

local ADDON_NAME, EW = ...

EW.TALENTS_FORMAT = "everythingwow/companion-talents/1"
-- A Classic Era tree holds about twenty talents and a class about sixty, so
-- these are far above any real tree and exist only to bound what a client
-- answering nonsense could write into the file.
EW.TALENT_TREE_CAP = 12
EW.TALENT_CAP = 400
EW.TALENT_PREREQ_CAP = 4

-- The site's class slugs, which are its talent calculator addresses, from
-- the class file token UnitClass returns second.
local CLASS_SLUGS = {
  WARRIOR = "warrior", PALADIN = "paladin", HUNTER = "hunter", ROGUE = "rogue",
  PRIEST = "priest", SHAMAN = "shaman", MAGE = "mage", WARLOCK = "warlock",
  DRUID = "druid", DEATHKNIGHT = "death-knight", MONK = "monk",
  DEMONHUNTER = "demon-hunter", EVOKER = "evoker",
}

--[[ The class slug for a class file token: the site's own spelling where
     the table holds one, and the token lowercased otherwise, so a class
     this table has never seen is still recorded under a readable key. ]]
function EW.ClassSlug(classFile)
  if type(classFile) ~= "string" or classFile == "" then return nil end
  return CLASS_SLUGS[classFile] or string.lower(classFile)
end

-- The functions the two paths read, named for the diagnostic. A dotted name
-- is a member of a C_ namespace.
EW.TALENT_API_NAMES = {
  "GetNumTalentTabs", "GetTalentTabInfo", "GetNumTalents", "GetTalentInfo",
  "GetTalentPrereqs", "GetTalentLink",
  "C_ClassTalents", "C_ClassTalents.GetActiveConfigID",
  "C_Traits", "C_Traits.GetConfigInfo", "C_Traits.GetTreeNodes", "C_Traits.GetNodeInfo",
  "C_Traits.GetEntryInfo", "C_Traits.GetDefinitionInfo",
  "C_Spell.GetSpellName", "C_Spell.GetSpellTexture", "GetSpellInfo",
  "GetNumSpecializations", "GetSpecializationInfo",
}

--[[ A global function or a namespace member, read with rawget so that an
     absent one is nil rather than an error. ]]
local function Lookup(name)
  local found
  pcall(function()
    local space, member = string.match(name, "^([%w_]+)%.([%w_]+)$")
    if space then
      local namespace = rawget(_G, space)
      if type(namespace) == "table" then found = namespace[member] end
    else
      found = rawget(_G, name)
    end
  end)
  return found
end

--[[ Which of the talent functions this client carries, as a set of the
     names present. A name the client lacks is left out rather than written
     as false, which keeps the diagnostic short. ]]
function EW.TalentApiPresence()
  local present = {}
  for _, name in ipairs(EW.TALENT_API_NAMES) do
    local value = Lookup(name)
    if value ~= nil then present[name] = type(value) end
  end
  return present
end

local function Number(value)
  if type(value) == "number" and value == value then return value end
  return nil
end

local function Text(value)
  if type(value) == "string" and value ~= "" then return string.sub(value, 1, 128) end
  return nil
end

-- An icon is a file id on the modern clients and a texture path on the old
-- ones, and either is written as the client gave it.
local function Icon(value)
  return Number(value) or Text(value)
end

--[[
The classic path: GetNumTalentTabs, GetTalentTabInfo, GetNumTalents,
GetTalentInfo and GetTalentPrereqs, the functions Classic Era's own talent
frame reads.

GetTalentTabInfo has two shapes. Classic Era answers name, icon, points
spent and background file; Wrath of the Lich King Classic and later answer
id, name, description, icon, points spent and background. The first return
says which: a number is the id of the second shape. GetTalentInfo answers
name, icon, tier, column, rank, maximum rank and whether the talent is a
milestone ("exceptional") on every classic client; the rank is the
character's own and is not recorded. GetTalentLink, where the client has it,
carries the talent id in a "talent:<id>" link. GetTalentPrereqs answers
tier, column and whether it is learnable, three values per prerequisite.
]]
local function ClassicTabInfo(tab)
  local info = {}
  pcall(function() info = { GetTalentTabInfo(tab) } end)
  if type(info[1]) == "number" and type(info[2]) == "string" then
    return { id = info[1], name = Text(info[2]), icon = Icon(info[4]), background = Text(info[6]) }
  end
  return { name = Text(info[1]), icon = Icon(info[2]), background = Text(info[4]) }
end

local function ClassicTalentId(tab, index)
  local id
  pcall(function()
    if type(rawget(_G, "GetTalentLink")) ~= "function" then return end
    local link = GetTalentLink(tab, index)
    if type(link) == "string" then id = tonumber(string.match(link, "talent:(%d+)")) end
  end)
  return id
end

local function ClassicPrereqs(tab, index)
  local requires = {}
  pcall(function()
    if type(rawget(_G, "GetTalentPrereqs")) ~= "function" then return end
    local values = { GetTalentPrereqs(tab, index) }
    for offset = 1, EW.TALENT_PREREQ_CAP * 3, 3 do
      local tier, column = Number(values[offset]), Number(values[offset + 1])
      if not tier or not column then break end
      requires[#requires + 1] = { tier = tier, column = column }
    end
  end)
  return requires
end

--[[ Points each prerequisite at the talent standing at its tier and column
     in the same tree, so it carries that talent's index and, where the
     client gave one, its id. ]]
local function ResolveClassicPrereqs(talents)
  local at = {}
  for _, talent in ipairs(talents) do
    at[tostring(talent.tier) .. ":" .. tostring(talent.column)] = talent
  end
  for _, talent in ipairs(talents) do
    for _, requirement in ipairs(talent.requires or {}) do
      local target = at[tostring(requirement.tier) .. ":" .. tostring(requirement.column)]
      if target then
        requirement.index = target.index
        requirement.id = target.id
      end
    end
  end
end

local function ClassicTrees(budget)
  if type(rawget(_G, "GetNumTalentTabs")) ~= "function"
    or type(rawget(_G, "GetNumTalents")) ~= "function"
    or type(rawget(_G, "GetTalentInfo")) ~= "function" then
    return nil, "absent", 0
  end
  local tabs = 0
  pcall(function() tabs = Number(GetNumTalentTabs()) or 0 end)
  if tabs < 1 then return nil, "no_tabs", 0 end
  if tabs > EW.TALENT_TREE_CAP then tabs = EW.TALENT_TREE_CAP end

  local trees, count = {}, 0
  for tab = 1, tabs do
    local tree = ClassicTabInfo(tab)
    tree.index = tab
    tree.talents = {}
    local total = 0
    pcall(function() total = Number(GetNumTalents(tab)) or 0 end)
    for index = 1, total do
      if count >= budget then break end
      local name, icon, tier, column, maxRank, exceptional
      pcall(function()
        local rank
        name, icon, tier, column, rank, maxRank, exceptional = GetTalentInfo(tab, index)
      end)
      -- A first return that is not a name is a different function under the
      -- same global, such as the row and column talents of later clients,
      -- and is not read as a classic talent.
      if type(name) == "string" and Number(tier) and Number(column) then
        count = count + 1
        tree.talents[#tree.talents + 1] = {
          index = index,
          id = ClassicTalentId(tab, index),
          name = Text(name),
          icon = Icon(icon),
          tier = tier,
          column = column,
          max_rank = Number(maxRank),
          exceptional = exceptional and true or nil,
          requires = ClassicPrereqs(tab, index),
        }
      end
    end
    ResolveClassicPrereqs(tree.talents)
    trees[#trees + 1] = tree
  end
  if count == 0 then return nil, "no_talents", 0 end
  return trees, "ok", count
end

--[[
The modern path: C_ClassTalents.GetActiveConfigID for the character's own
loadout, C_Traits.GetConfigInfo for its trees, then each tree's nodes, each
node's entries, and each entry's definition, whose spell gives the name and
icon where the definition carries no override.

A trait node has a position rather than a tier and column, so the tier is
the node's rank among the distinct heights in its tree and the column its
rank among the distinct widths, both counted from 1, and the raw position is
written beside them. An arrow is an edge in the node's visibleEdges, which
points from the prerequisite to the node it opens, so each node's
prerequisites are the nodes whose edges name it.
]]
local function SpellName(spellId)
  local name
  pcall(function()
    if C_Spell and C_Spell.GetSpellName then
      name = C_Spell.GetSpellName(spellId)
    elseif type(rawget(_G, "GetSpellInfo")) == "function" then
      name = (GetSpellInfo(spellId))
    end
  end)
  return Text(name)
end

local function SpellIcon(spellId)
  local icon
  pcall(function()
    if C_Spell and C_Spell.GetSpellTexture then
      icon = C_Spell.GetSpellTexture(spellId)
    elseif type(rawget(_G, "GetSpellInfo")) == "function" then
      local _, _, texture = GetSpellInfo(spellId)
      icon = texture
    end
  end)
  return Icon(icon)
end

local function TraitEntry(configId, entryId)
  local entry = { entry = entryId }
  pcall(function()
    local info = C_Traits.GetEntryInfo(configId, entryId)
    if type(info) ~= "table" then return end
    entry.definition = Number(info.definitionID)
    entry.max_rank = Number(info.maxRanks)
    if not entry.definition or not C_Traits.GetDefinitionInfo then return end
    local definition = C_Traits.GetDefinitionInfo(entry.definition)
    if type(definition) ~= "table" then return end
    entry.spell = Number(definition.spellID)
    entry.name = Text(definition.overrideName)
    entry.icon = Icon(definition.overrideIcon)
  end)
  if entry.spell then
    entry.name = entry.name or SpellName(entry.spell)
    entry.icon = entry.icon or SpellIcon(entry.spell)
  end
  return entry
end

--[[ Ranks a list of numbers: each distinct value's place in ascending
     order, from 1. ]]
local function Ranks(values)
  local distinct, seen = {}, {}
  for _, value in ipairs(values) do
    if not seen[value] then
      seen[value] = true
      distinct[#distinct + 1] = value
    end
  end
  table.sort(distinct)
  local rank = {}
  for index, value in ipairs(distinct) do rank[value] = index end
  return rank
end

local function TraitTabName(treeIndex)
  if type(rawget(_G, "GetTalentTabInfo")) ~= "function" then return nil end
  local tab = ClassicTabInfo(treeIndex)
  return tab.name, tab.icon, tab.background
end

local function TraitTrees(budget)
  local traits = rawget(_G, "C_Traits")
  local classTalents = rawget(_G, "C_ClassTalents")
  if type(traits) ~= "table" or type(classTalents) ~= "table"
    or type(classTalents.GetActiveConfigID) ~= "function"
    or type(traits.GetConfigInfo) ~= "function"
    or type(traits.GetTreeNodes) ~= "function"
    or type(traits.GetNodeInfo) ~= "function"
    or type(traits.GetEntryInfo) ~= "function" then
    return nil, "absent", 0
  end

  local configId
  pcall(function() configId = C_ClassTalents.GetActiveConfigID() end)
  if not Number(configId) then return nil, "no_config", 0 end
  local treeIds
  pcall(function()
    local info = C_Traits.GetConfigInfo(configId)
    if type(info) == "table" and type(info.treeIDs) == "table" then treeIds = info.treeIDs end
  end)
  if not treeIds or #treeIds == 0 then return nil, "no_trees", 0 end

  local trees, count = {}, 0
  for treeIndex, treeId in ipairs(treeIds) do
    if treeIndex > EW.TALENT_TREE_CAP then break end
    local name, icon, background = TraitTabName(treeIndex)
    local tree = { id = Number(treeId), index = treeIndex, name = name, icon = icon, background = background, talents = {} }
    local nodeIds = {}
    pcall(function() nodeIds = C_Traits.GetTreeNodes(treeId) or {} end)

    local byNode, sources, xs, ys = {}, {}, {}, {}
    for _, nodeId in ipairs(nodeIds) do
      if count >= budget then break end
      local node
      pcall(function() node = C_Traits.GetNodeInfo(configId, nodeId) end)
      -- An id of 0 or none is the client's answer for a node this
      -- character's tree does not hold.
      if type(node) == "table" and Number(node.ID) and node.ID ~= 0 then
        local entries = {}
        for _, entryId in ipairs(type(node.entryIDs) == "table" and node.entryIDs or {}) do
          entries[#entries + 1] = TraitEntry(configId, entryId)
        end
        local first = entries[1] or {}
        local talent = {
          id = node.ID,
          entry = first.entry,
          definition = first.definition,
          spell = first.spell,
          name = first.name,
          icon = first.icon,
          max_rank = Number(node.maxRanks) or first.max_rank,
          pos_x = Number(node.posX),
          pos_y = Number(node.posY),
          node_type = Number(node.type),
          requires = {},
        }
        -- A choice node holds more than one entry, and each is kept.
        if #entries > 1 then talent.choices = entries end
        count = count + 1
        tree.talents[#tree.talents + 1] = talent
        byNode[node.ID] = talent
        if talent.pos_x then xs[#xs + 1] = talent.pos_x end
        if talent.pos_y then ys[#ys + 1] = talent.pos_y end
        for _, edge in ipairs(type(node.visibleEdges) == "table" and node.visibleEdges or {}) do
          if type(edge) == "table" and Number(edge.targetNode) then
            sources[#sources + 1] = { from = node.ID, to = edge.targetNode }
          end
        end
      end
    end

    local columns, tiers = Ranks(xs), Ranks(ys)
    for _, talent in ipairs(tree.talents) do
      talent.column = talent.pos_x and columns[talent.pos_x] or nil
      talent.tier = talent.pos_y and tiers[talent.pos_y] or nil
    end
    for _, edge in ipairs(sources) do
      local target, source = byNode[edge.to], byNode[edge.from]
      if target and source and #target.requires < EW.TALENT_PREREQ_CAP then
        target.requires[#target.requires + 1] = { id = source.id, tier = source.tier, column = source.column }
      end
    end
    trees[#trees + 1] = tree
  end
  if count == 0 then return nil, "no_nodes", 0 end
  return trees, "ok", count
end

--[[ The saved variable, created on first use. The client loads it before
     ADDON_LOADED, so by the time anyone types the command it holds every
     capture an earlier session wrote. ]]
function EW.TalentDatabase()
  local db = rawget(_G, "EverythingWoWTalentsDB")
  if type(db) ~= "table" then
    db = {}
    _G.EverythingWoWTalentsDB = db
  end
  db.format = EW.TALENTS_FORMAT
  if type(db.captures) ~= "table" then db.captures = {} end
  return db
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

--[[ Reads the current character's class trees and returns the capture, or
     nil and the reason none could be taken. Writes nothing. ]]
function EW.ReadTalentTrees()
  local className, classFile, classId
  pcall(function() className, classFile, classId = UnitClass("player") end)
  if type(classFile) ~= "string" or classFile == "" then return nil, "no_class" end

  local level
  pcall(function() level = UnitLevel("player") end)
  local version, build, _, interface
  pcall(function() version, build, _, interface = GetBuildInfo() end)

  local capture = {
    class = classFile,
    class_slug = EW.ClassSlug(classFile),
    class_id = Number(classId),
    client = EW.Client and EW.Client.key or "unknown",
    project = Number(rawget(_G, "WOW_PROJECT_ID")),
    build = Text(version),
    build_number = Text(build) or Number(build),
    interface = Number(interface),
    level = Number(level),
    t = EW.Now(),
    addon = EW.ADDON_VERSION,
    api = EW.TalentApiPresence(),
  }

  local classic, classicState, classicCount = ClassicTrees(EW.TALENT_CAP)
  local traits, traitsState, traitsCount = TraitTrees(EW.TALENT_CAP)
  capture.paths = { classic = classicState, traits = traitsState }

  if classic then
    capture.source, capture.trees, capture.talents = "classic", classic, classicCount
    if traits then capture.alt = { source = "traits", trees = traits, talents = traitsCount } end
  elseif traits then
    capture.source, capture.trees, capture.talents = "traits", traits, traitsCount
  else
    capture.trees, capture.talents = {}, 0
  end
  return capture, nil, className
end

--[[ The capture key, one per class per client. ]]
function EW.TalentCaptureKey(capture)
  return tostring(capture.client) .. ":" .. tostring(capture.class)
end

--[[ The classes held for one client, sorted, for the confirmation line. ]]
local function HeldFor(db, client)
  local held = {}
  for _, capture in pairs(db.captures) do
    if type(capture) == "table" and capture.client == client and (capture.talents or 0) > 0 then
      held[#held + 1] = tostring(capture.class_slug or capture.class)
    end
  end
  table.sort(held)
  return held
end

--[[
`/ewow talents`. Reads the trees and keeps them. A read that found trees
replaces whatever was held for the same class on the same client. A read
that found none is kept as a diagnostic under the same key only when no
good capture is held there, so a failed second attempt never throws away a
good first one; it is always kept at lastDiagnostic as well.
]]
function EW.RecordTalents()
  if InCombat() then
    EW.Print("Leave combat, then type /ewow talents again.")
    return false
  end
  local capture, reason, className = EW.ReadTalentTrees()
  if not capture then
    EW.Print("Your class could not be read (" .. tostring(reason) .. "). Nothing was recorded.")
    return false
  end

  local db = EW.TalentDatabase()
  local key = EW.TalentCaptureKey(capture)
  local label = Text(className) or capture.class

  if capture.talents > 0 then
    db.captures[key] = capture
    local held = HeldFor(db, capture.client)
    EW.Print(string.format("Recorded %d trees, %d talents for %s. /reload or log out to save.",
      #capture.trees, capture.talents, label))
    EW.Print(string.format("Classes held for %s (%d): %s.",
      tostring(capture.client), #held, table.concat(held, ", ")))
    return true
  end

  db.lastDiagnostic = capture
  local held = db.captures[key]
  if type(held) ~= "table" or (held.talents or 0) == 0 then db.captures[key] = capture end
  EW.Print(string.format(
    "No talent trees could be read for %s (classic %s, traits %s). A diagnostic was saved instead.",
    label, tostring(capture.paths.classic), tostring(capture.paths.traits)))
  if (capture.level or 0) < 10 then
    EW.Print("Talents open at level 10 on some clients. Try again at level 10.")
  end
  EW.Print("/reload or log out to save, then send the file to the Orchestrator.")
  return false
end

--[[ `/ewow talents clear`. Throws away every talent capture, which /ewow
     clear never touches, for once the file has been sent. ]]
function EW.ClearTalents()
  local db = EW.TalentDatabase()
  db.captures = {}
  db.lastDiagnostic = nil
  EW.Print("Talent captures cleared. /reload or log out to save.")
end
