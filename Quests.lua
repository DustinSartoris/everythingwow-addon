--[[
The quest recorder.

QUEST_DETAIL fires with the quest the player is being offered and
QUEST_COMPLETE fires at the turn in, and at both moments GetQuestID returns
the quest id and the npc unit token is the giver. Those are the two events
Section 9.2 asks for, and the subject type is quest for both so that the
site's quest giver layer holds the start and the end of the same quest.

The objective kind the contract allows is not recorded in version 0.1.0.
Objective progress needs the quest log watched frame by frame and the
location an objective completed at, and doing that badly would write pins
where the player happened to stand. It is named here so the gap is on the
record rather than hidden.

0.2.11 records what the quest window says. On 23 November 2026 the owner
asked for the quest's text, objectives and rewards, because Blizzard's WoW
Forever quest index holds a small part of the game's quests and the pages
the site makes from this recorder's titles carried a name and a quest giver
and nothing else. Both events use only functions the quest window itself is
drawn from, each inside pcall, and no new event:

  At the offer (quest_start): text, the quest's description, from
  GetQuestText; objectives, what the player is asked to do, from
  GetObjectiveText.

  At the turn in (quest_end): completion, what the NPC says, from
  GetRewardText.

  At both, where the window shows them: rewards and choices, each a list of
  { id, q, n } from GetQuestItemInfo and GetQuestItemLink, n being the item's
  name as the window shows it; money in copper from
  GetRewardMoney; xp from GetRewardXP; and level, the quest's level, where
  the client has C_QuestLog.GetQuestDifficultyLevel.

The player is never recorded. The game writes the character's own name into
quest text ("Thanks, <name>."), so every text is scrubbed before it is
stored: the name, whole and word by word, becomes the token <name>, which
the site shows as a placeholder. A text that still carries a client color
code or any other pipe sequence after its color codes are removed is not
recorded at all, and neither is one with a control character other than a
line break. Class and race words are left as the game wrote them.

A text is cut to a length the site can use, on a character boundary, and the
whole payload is then held under the reader's 4,000 byte cap by shortening
the longest text first, so a long quest is recorded shorter rather than
dropped.
]]

local ADDON_NAME, EW = ...

-- The most bytes kept of each text. A cut text ends at a character boundary.
EW.QUEST_TEXT_BYTES = 1600
EW.QUEST_OBJECTIVES_BYTES = 600
EW.QUEST_COMPLETION_BYTES = 1200
EW.QUEST_REWARD_CAP = 10
EW.QUEST_ITEM_NAME_BYTES = 80
-- Room left under the reader's cap for the keys and the small fields.
EW.QUEST_PAYLOAD_BYTES = 3800

local function GiverId()
  local guid = UnitGUID("npc")
  local subject, id = EW.SubjectFromGuid(guid)
  if subject == "npc" then return id end
  return nil
end

local function EscapePattern(text)
  return (text:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

--[[ The player's own name in every form the game might write it: whole,
     and each of its words, longest first so a surname is not left behind. ]]
local function PlayerNames()
  local names, seen = {}, {}
  local function Add(value)
    if type(value) ~= "string" then return end
    value = value:match("^%s*(.-)%s*$")
    if #value < 2 or seen[value] then return end
    seen[value] = true
    names[#names + 1] = value
  end
  pcall(function()
    local name = UnitName("player")
    Add(name)
    if type(name) == "string" then
      for word in name:gmatch("%S+") do Add(word) end
    end
  end)
  pcall(function()
    if type(rawget(_G, "UnitFullName")) == "function" then
      local name = UnitFullName("player")
      Add(name)
      if type(name) == "string" then
        for word in name:gmatch("%S+") do Add(word) end
      end
    end
  end)
  table.sort(names, function(a, b) return #a > #b end)
  return names
end

--[[ Cuts a string to at most max bytes without splitting a UTF-8 character. ]]
local function CutBytes(text, max)
  if #text <= max then return text end
  local cut = max
  -- Step back off continuation bytes, then off the lead byte they belong to.
  while cut > 0 do
    local byte = text:byte(cut + 1)
    if not byte or byte < 128 or byte >= 192 then break end
    cut = cut - 1
  end
  return (text:sub(1, cut):gsub("%s+$", ""))
end
EW.CutBytes = CutBytes

--[[
One of the quest window's texts, made fit to store, or nil.

Line endings become single line feeds, the client's color codes are removed,
and the player's own name becomes <name>. A text left holding a pipe, or a
control character other than a line feed, is refused whole: the site prints
what it is sent, and neither belongs in a sentence.
]]
function EW.QuestText(value, maxBytes)
  if type(value) ~= "string" then return nil end
  local text = value:gsub("\r\n", "\n"):gsub("\r", "\n")
  text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  if text:find("|", 1, true) then return nil end
  if (text:gsub("\n", "")):find("%c") then return nil end
  for _, name in ipairs(PlayerNames()) do
    local pattern = EscapePattern(name)
    if name:find("^[%w]+$") then
      text = text:gsub("%f[%w]" .. pattern .. "%f[%W]", "<name>")
    else
      text = text:gsub(pattern, "<name>")
    end
  end
  text = text:gsub("\n\n\n+", "\n\n"):match("^%s*(.-)%s*$")
  if text == "" then return nil end
  return CutBytes(text, maxBytes)
end

--[[ The items one list of the quest window shows, "reward" or "choice". ]]
local function QuestItems(kind, countFunction)
  local items = {}
  local count = 0
  pcall(function()
    local get = rawget(_G, countFunction)
    if type(get) == "function" then count = get() or 0 end
  end)
  if type(count) ~= "number" or count < 1 then return items end
  if count > EW.QUEST_REWARD_CAP then count = EW.QUEST_REWARD_CAP end
  for index = 1, count do
    pcall(function()
      local itemId, quantity, name
      if type(rawget(_G, "GetQuestItemLink")) == "function" then
        itemId = EW.IdFromLink and EW.IdFromLink(GetQuestItemLink(kind, index)) or nil
      end
      if type(rawget(_G, "GetQuestItemInfo")) == "function" then
        local itemName, _, itemCount, _, _, infoId = GetQuestItemInfo(kind, index)
        quantity, name = itemCount, itemName
        if not itemId and type(infoId) == "number" and infoId > 0 then itemId = infoId end
      end
      if type(itemId) == "number" and itemId > 0 then
        local entry = { id = math.floor(itemId) }
        if type(quantity) == "number" and quantity > 1 then entry.q = math.floor(quantity) end
        -- The item's name as the window shows it, so the site can name a
        -- reward Blizzard's item index does not hold. A name with a pipe, a
        -- control character or more than 80 bytes is left out.
        if type(name) == "string" and name ~= "" and #name <= EW.QUEST_ITEM_NAME_BYTES
          and not name:find("|", 1, true) and not name:find("%c") then
          entry.n = name
        end
        items[#items + 1] = entry
      end
    end)
  end
  return items
end

local function PositiveNumber(functionName)
  local value
  pcall(function()
    local get = rawget(_G, functionName)
    if type(get) == "function" then value = get() end
  end)
  if type(value) == "number" and value > 0 then return math.floor(value) end
  return nil
end

--[[ Shortens the longest text until the payload fits under the cap. ]]
local TEXT_FIELDS = { "text", "completion", "objectives" }
local function Fit(payload)
  local guard = 0
  while EW.JsonBytes(payload) > EW.QUEST_PAYLOAD_BYTES and guard < 200 do
    guard = guard + 1
    local longest, length = nil, 0
    for _, field in ipairs(TEXT_FIELDS) do
      local value = payload[field]
      if type(value) == "string" and #value > length then longest, length = field, #value end
    end
    if not longest then
      -- No text is left to shorten: the item names go, and the ids stay.
      local named = false
      for _, list in ipairs({ payload.choices or {}, payload.rewards or {} }) do
        for _, entry in ipairs(list) do
          if entry.n ~= nil then entry.n, named = nil, true end
        end
      end
      if not named then break end
      payload.cut = true
    else
      if length <= 200 then
        payload[longest] = nil
      else
        payload[longest] = CutBytes(payload[longest], length - 200)
      end
      payload.cut = true
    end
  end
  return payload
end

local function RecordQuest(kind)
  local questId
  pcall(function() questId = GetQuestID() end)
  if type(questId) ~= "number" or questId <= 0 then return false end

  local mapId, x, y = EW.PlayerPosition()
  local payload = {}
  local npcId = GiverId()
  if npcId then payload.npc_id = npcId end
  local title
  pcall(function() title = GetTitleText() end)
  if type(title) == "string" and title ~= "" then payload.title = title end

  if kind == "quest_start" then
    pcall(function()
      if type(rawget(_G, "GetQuestText")) == "function" then
        payload.text = EW.QuestText(GetQuestText(), EW.QUEST_TEXT_BYTES)
      end
    end)
    pcall(function()
      if type(rawget(_G, "GetObjectiveText")) == "function" then
        payload.objectives = EW.QuestText(GetObjectiveText(), EW.QUEST_OBJECTIVES_BYTES)
      end
    end)
  else
    pcall(function()
      if type(rawget(_G, "GetRewardText")) == "function" then
        payload.completion = EW.QuestText(GetRewardText(), EW.QUEST_COMPLETION_BYTES)
      end
    end)
  end

  local rewards = QuestItems("reward", "GetNumQuestRewards")
  if #rewards > 0 then payload.rewards = rewards end
  local choices = QuestItems("choice", "GetNumQuestChoices")
  if #choices > 0 then payload.choices = choices end
  payload.money = PositiveNumber("GetRewardMoney")
  payload.xp = PositiveNumber("GetRewardXP")
  pcall(function()
    local log = rawget(_G, "C_QuestLog")
    if type(log) == "table" and type(log.GetQuestDifficultyLevel) == "function" then
      local level = log.GetQuestDifficultyLevel(questId)
      if type(level) == "number" and level > 0 and level <= 100 then payload.level = math.floor(level) end
    end
  end)

  return EW.Record(kind, "quest", questId, mapId, x, y, Fit(payload))
end

EW.RecordQuest = RecordQuest

EW.RegisterEvent("QUEST_DETAIL", function() RecordQuest("quest_start") end)
EW.RegisterEvent("QUEST_COMPLETE", function() RecordQuest("quest_end") end)
