"""Execute the actual Lua addon against a small mocked game environment."""
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.test-deps'))
from lupa.lua51 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('''
frames = {}; messages = {}; clock = 123
function time() return clock end
function print(s) table.insert(messages, s) end
function CreateFrame()
    local f = { scripts = {} }
    function f:SetScript(event, fn) self.scripts[event] = fn end
    function f:RegisterEvent() end
    table.insert(frames, f); return f
end
SlashCmdList = {}
function GetBuildInfo() return "test", "1", "today", 16001 end
function GetLocale() return "enUS" end
function UnitName(unit) assert(unit == "player"); return "Test", nil, false, nil end
function UnitHealth() error("test failure") end
function GetMoney() return 0 end
function GetInventoryItemID(unit, slot) assert(unit == "player"); return slot end
function GetInventoryItemDurability(slot) assert(type(slot) == "number"); return 50, 100 end
C_QuestLog = {
    GetNumQuestLogEntries = function() return 2, 1 end,
    GetInfo = function(i) return {questID=i, isHeader=false} end,
}
function GetNumSkillLines() return 1002 end
function GetSkillLineInfo(i) return i end
function GetNumFactions() return 0 end
function GetCurrencyListSize() return 1 end
function GetCurrencyListInfo()
    local t = {}; t.self = t; return t
end
function tick()
    for _, f in ipairs(frames) do
        if f.scripts.OnUpdate then f.scripts.OnUpdate(f, 0.01) end
    end
end
''')
api = lua.table()
for name in ['CharacterCapture.lua', 'ForeverAPIExplorer.lua']:
    lua.execute((ROOT / 'ForeverAPIExplorer' / name).read_text(), 'ForeverAPIExplorer', api)
lua.globals().frames[2].scripts.OnEvent(lua.globals().frames[2], 'ADDON_LOADED', 'ForeverAPIExplorer')
lua.execute('''
ForeverAPIExplorerDB = { sentinel = true }
SlashCmdList.FOREVERAPIEXPLORER("character")
assert(ForeverAPIExplorerCharacterDB == nil)
SlashCmdList.FOREVERAPIEXPLORER("export") -- must not overlap
SlashCmdList.FOREVERAPIEXPLORER("clearcharacter") -- must not interrupt
for i=1,200 do tick() end
assert(ForeverAPIExplorerDB.sentinel)
local d = ForeverAPIExplorerCharacterDB
assert(d.kind == "character" and d.client.locale == "enUS")
assert(d.collectionLimitReached and d.statistics.queries == #d.queries)
assert(d.statistics.ok + d.statistics.error + d.statistics.unavailable == #d.queries)
local found = {}; local skills = 0; local quests = 0
for _, q in ipairs(d.queries) do
    found[q.path] = q
    if q.path == "_G.GetSkillLineInfo" then skills = skills + 1 end
    if q.path == "_G.C_QuestLog.GetInfo" then quests = quests + 1 end
end
assert(skills == 1000 and quests == 2)
local q = found["_G.UnitName"]
assert(q.returnCount == 4 and q.returns[2].type == "nil")
assert(q.returns[3].value == false and q.returns[4].type == "nil")
assert(q.arguments[1].value == "player")
assert(found["_G.UnitHealth"].status == "error")
assert(found["_G.UnitRace"].status == "unavailable")
assert(found["_G.GetMoney"].returns[1].value == 0)
assert(found["_G.GetCurrencyListInfo"].returns[1].entries[1].value.truncated == "cycleOrAlias")
SlashCmdList.FOREVERAPIEXPLORER("characterstatus")
SlashCmdList.FOREVERAPIEXPLORER("clearcharacter")
assert(ForeverAPIExplorerCharacterDB == nil and ForeverAPIExplorerDB.sentinel)
-- Check legacy quest fallback and the opposite overlap guard.
C_QuestLog = nil
function GetNumQuestLogEntries() return 1 end
function GetQuestLogTitle(i) return "quest", i end
SlashCmdList.FOREVERAPIEXPLORER("character")
for i=1,200 do tick() end
local legacy = false
for _, q in ipairs(ForeverAPIExplorerCharacterDB.queries) do
    if q.path == "_G.GetQuestLogTitle" then legacy = q.status == "ok" end
end
assert(legacy)
SlashCmdList.FOREVERAPIEXPLORER("export")
SlashCmdList.FOREVERAPIEXPLORER("character")
''')
assert not api.CharacterBusy()
print('PASS: Lua 5.1 capture, nil slots, errors, unavailable APIs, collection bounds, cycles, legacy fallback, persistence isolation, overlap guards')
