"""Regression tests for modern getters and public-only follow-up expansion."""
import runpy
from pathlib import Path

context = runpy.run_path(str(Path(__file__).with_name('test_character_capture.py')))
lua, api = context['lua'], context['api']
lua.globals().captureAPI = api
lua.execute('''
frames[2]:SetScript("OnUpdate", nil) -- isolate from prior scanner guard test
GetNumSkillLines = nil
-- Numeric sentinel mocks the detector; stock Lua cannot create WoW secrets.
function issecretvalue(value) return type(value) == "number" and value == 777 end
function UnitHealth() return 777 end
function UnitPower() return {current = 777, maximum = 500} end
function GetProfessions() return 6, nil, 7, 6, nil end
function GetProfessionInfo(index) assert(index == 6 or index == 7); return "Profession", index end
C_TradeSkillUI = {
    GetAllProfessionTradeSkillLines = function() return {164, 171, 164} end,
    GetProfessionInfoBySkillLineID = function(id) return {skillLineID=id} end,
}
C_SpecializationInfo = {GetSpecialization = function() return nil end}
C_Reputation = {
    GetNumFactions = function() return 2 end,
    GetFactionDataByIndex = function(i) return {factionID=i, name="Faction"} end,
}
C_CurrencyInfo = {
    GetCurrencyListSize = function() return 1 end,
    GetCurrencyListInfo = function(i) return {name="Currency", quantity=0} end,
}
Enum = {SpellBookSpellBank={Player=0}}
C_SpellBook = {
    GetNumSpellBookSkillLines = function() return 3 end,
    GetSpellBookSkillLineInfo = function(i)
        if i == 3 then return {itemIndexOffset=777, numSpellBookItems=2} end
        return {itemIndexOffset=i-1, numSpellBookItems=2}
    end,
    GetSpellBookItemInfo = function(slot, bank)
        assert(bank == 0 and slot >= 1 and slot <= 3)
        return {spellID=100+slot}
    end,
    GetSpellBookItemName = function(slot, bank) assert(bank == 0); return "Spell", nil end,
}
captureAPI.StartCharacter("test", {}, print)
for i=1,200 do tick() end
assert(not captureAPI.CharacterBusy())
local d = ForeverAPIExplorerCharacterDB
local byPath = {}
for _, q in ipairs(d.queries) do
    byPath[q.path] = byPath[q.path] or {}
    table.insert(byPath[q.path], q)
end
local health = byPath["_G.UnitHealth"][1]
assert(health.status == "ok" and health.hasRestrictedValues)
assert(health.returns[1].restricted and health.returns[1].value == nil)
assert(d.statistics.restrictedQueries == 3) -- health, nested power, one skill line
assert(#byPath["_G.GetProfessionInfo"] == 2)
assert(#byPath["_G.C_TradeSkillUI.GetProfessionInfoBySkillLineID"] == 2)
assert(#byPath["_G.C_Reputation.GetFactionDataByIndex"] == 2)
assert(#byPath["_G.C_CurrencyInfo.GetCurrencyListInfo"] == 1)
assert(byPath["_G.GetNumFactions"] == nil)
assert(byPath["_G.C_SpecializationInfo.GetSpecialization"][1].status == "ok")
assert(#byPath["_G.C_SpellBook.GetSpellBookItemInfo"] == 3) -- overlapping lines deduplicated
assert(#byPath["_G.C_SpellBook.GetSpellBookItemName"] == 3)
assert(d.statistics.ok + d.statistics.error + d.statistics.unavailable == #d.queries)
-- No detector on legacy clients, and invalid metadata must not stall capture.
issecretvalue = nil; C_SpellBook = nil
function GetNumSpellTabs() return 1 end
function GetSpellTabInfo() return "General", 0, 0, 2 end
function GetSpellBookItemInfo(slot, bank) assert(bank == "spell"); return "SPELL", slot end
function GetSpellBookItemName(slot, bank) return "Legacy Spell" end
captureAPI.StartCharacter("test", {}, print)
for i=1,200 do tick() end
local n = 0
for _, q in ipairs(ForeverAPIExplorerCharacterDB.queries) do
    if q.path == "_G.GetSpellBookItemInfo" then n=n+1; assert(q.status == "ok") end
end
assert(n == 2)
-- Invalid counts must not stall capture.
C_SpellBook = {
    GetNumSpellBookSkillLines = function() return 1 end,
    GetSpellBookSkillLineInfo = function() return {itemIndexOffset=0, numSpellBookItems=2} end,
}
Enum = {SpellBookSpellBank={Player=0/0}} -- invalid enum; getters can fail independently
C_Reputation.GetNumFactions = function() return math.huge end
captureAPI.StartCharacter("test", {}, print)
for i=1,200 do tick() end
assert(not captureAPI.CharacterBusy())
''')
# Replay the real captured skill-line metadata without executing SavedVariables.
import re
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'ForeverAPIAtlas' / 'scripts'))
from import_dump import parse
dump = Path(__file__).resolve().parents[1] / 'data/ForeverAPIExplorer-20261116-201908.lua'
text = dump.read_text(encoding='utf-8-sig').split('ForeverAPIExplorerCharacterDB =', 1)[1]
capture = parse('ForeverAPIExplorerDB = ' + text)
lines = [q['returns'][0] for q in capture['queries']
         if q['path'] == '_G.C_SpellBook.GetSpellBookSkillLineInfo']
line_data = [lua.table_from({e['key']['value']: e['value'].get('value')
                           for e in node['entries']}) for node in lines]
lua.globals().replayedLines = lua.table_from(line_data)
lua.execute('''
Enum = {SpellBookSpellBank={Player=0}}
C_SpellBook.GetNumSpellBookSkillLines = function() return #replayedLines end
C_SpellBook.GetSpellBookSkillLineInfo = function(i) return replayedLines[i] end
C_SpellBook.GetSpellBookItemInfo = function(slot, bank)
    assert(slot >= 1 and slot <= 28 and bank == 0); return {spellID=slot}
end
C_SpellBook.GetSpellBookItemName = function(slot, bank) return "Replay " .. slot end
captureAPI.StartCharacter("test", {}, print)
for i=1,200 do tick() end
local count = 0
for _, q in ipairs(ForeverAPIExplorerCharacterDB.queries) do
    if q.path == "_G.C_SpellBook.GetSpellBookItemInfo" then
        count=count+1; assert(q.status == "ok")
    end
end
assert(count == 28)
''')
print('PASS: modern collections, profession IDs/indices, spell slots and legacy fallback, restricted values, real dump metadata schedules 28 spells')
