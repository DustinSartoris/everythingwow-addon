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
]]

local ADDON_NAME, EW = ...

local function GiverId()
  local guid = UnitGUID("npc")
  local subject, id = EW.SubjectFromGuid(guid)
  if subject == "npc" then return id end
  return nil
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

  return EW.Record(kind, "quest", questId, mapId, x, y, payload)
end

EW.RecordQuest = RecordQuest

EW.RegisterEvent("QUEST_DETAIL", function() RecordQuest("quest_start") end)
EW.RegisterEvent("QUEST_COMPLETE", function() RecordQuest("quest_end") end)
