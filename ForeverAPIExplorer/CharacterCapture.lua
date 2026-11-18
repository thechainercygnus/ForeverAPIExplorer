local _, API = ...
local frame = CreateFrame("Frame")
local active
local unpackArgs = unpack or table.unpack
local function Pack(...) return { n = select("#", ...), ... } end

-- Typed nodes preserve nil slots, false, and opaque objects in SavedVariables.
-- The budget bounds even unexpectedly large, recursive return tables.
local function Encode(value, depth, seen, budget)
    local t = type(value)
    local node = { type = t }
    -- Never compare, stringify, index or persist a secret value.
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret then
            node.restricted = true
            budget.restricted = (budget.restricted or 0) + 1
            return node
        end
    end
    budget.left = budget.left - 1
    if budget.left < 0 then node.truncated = "nodeLimit"; return node end
    if t == "string" then
        node.value = string.sub(value, 1, 4096)
        if #value > 4096 then node.truncated = "stringLimit" end
    elseif t == "number" then
        if value == value and value ~= math.huge and value ~= -math.huge then
            node.value = value
        else node.truncated = "nonFiniteNumber" end
    elseif t == "boolean" then node.value = value
    elseif t == "table" then
        if seen[value] then node.truncated = "cycleOrAlias"; return node end
        if depth >= 6 then node.truncated = "depthLimit"; return node end
        seen[value] = true
        node.entries = {}
        for k, v in pairs(value) do
            if #node.entries >= 200 or budget.left < 2 then
                node.truncated = "entryLimit"; break
            end
            table.insert(node.entries, {
                key = Encode(k, depth + 1, seen, budget),
                value = Encode(v, depth + 1, seen, budget),
            })
        end
    end
    return node
end

-- Follow-up queries consume only serialized public data, never raw returns.
local function Public(node)
    if node.restricted or node.truncated then return nil end
    if node.type ~= "table" then return node.value end
    local result = {}
    for _, entry in ipairs(node.entries or {}) do
        local key = Public(entry.key)
        if type(key) == "string" or type(key) == "number" or type(key) == "boolean" then
            result[key] = Public(entry.value)
        end
    end
    return result
end

local function Resolve(path)
    local value = _G
    for part in string.gmatch(path, "[^.]+") do
        if type(value) ~= "table" then return nil end
        value = value[part]
    end
    if type(value) == "function" then return value end
end

function API.CharacterBusy() return active ~= nil end

function API.StartCharacter(version, client, log)
    if active then log("A character capture is already running."); return end
    local state = {
        queue = {}, head = 1,
        result = {
            schemaVersion = 1, addonVersion = version, client = client,
            captureStartedAt = time(), kind = "character", queries = {},
            limits = { queriesPerFrame = 10, maxCollectionEntries = 1000,
                returnNodes = 2000, tableDepth = 6, tableEntries = 200,
                stringBytes = 4096, maxQueries = 10000 },
            statistics = { ok = 0, error = 0, unavailable = 0, restrictedQueries = 0 },
            notes = "Queries span multiple frames; this is not an atomic snapshot. Nil or empty results may reflect unavailable context or uncached data. Collection counts may include collapsed headers; no UI expansion or data requests are performed.",
        },
    }
    local function Add(section, path, args, after)
        if #state.queue >= 10000 then
            state.result.queryLimitReached = true
            return
        end
        table.insert(state.queue, { section = section, path = path,
            args = args or {}, after = after })
    end
    local function BoundedCount(count)
        if type(count) ~= "number" or count ~= count or count < 0
            or count == math.huge then return nil end
        count = math.floor(count)
        if count > 1000 then
            state.result.collectionLimitReached = true
            count = 1000
        end
        return count
    end
    local function Collection(section, countPath, itemPath, afterItem)
        Add(section, countPath, {}, function(raw)
            local count = BoundedCount(raw[2])
            if not count then return end
            for i = 1, count do Add(section, itemPath, { i }, afterItem) end
        end)
    end
    local function Prefer(modern, legacy)
        if Resolve(modern) then return modern end
        return legacy
    end
    for _, path in ipairs({ "UnitName", "UnitGUID", "UnitLevel", "UnitClass",
        "UnitRace", "UnitSex", "UnitFactionGroup", "UnitHealth", "UnitHealthMax",
        "UnitPowerType", "UnitPower", "UnitPowerMax", "UnitArmor",
        "UnitAttackPower", "UnitRangedAttackPower", "UnitDamage",
        "UnitAttackSpeed" }) do Add("identityAndStats", path, { "player" }) end
    for i = 1, 5 do Add("stats", "UnitStat", { "player", i }) end
    for _, path in ipairs({ "GetRealmName", "GetMoney", "GetXPExhaustion",
        }) do Add("character", path) end
    Add("character", Prefer("C_SpecializationInfo.GetSpecialization", "GetSpecialization"))
    local professionsSeen = {}
    Add("professions", "GetProfessions", {}, function(raw)
        for i = 2, raw.n do
            local index = raw[i]
            if type(index) == "number" and index > 0 and not professionsSeen[index] then
                professionsSeen[index] = true
                Add("professions", "GetProfessionInfo", { index })
            end
        end
    end)
    -- Profession skill lines supplement the legacy general skill list;
    -- they do not imply coverage of weapon or other non-profession skills.
    Add("professionSkillLines", "C_TradeSkillUI.GetAllProfessionTradeSkillLines", {}, function(raw)
        local ids = raw[2]
        if type(ids) ~= "table" then return end
        local seen = {}
        for i = 1, BoundedCount(#ids) or 0 do
            local id = ids[i]
            if type(id) == "number" and id > 0 and not seen[id] then
                seen[id] = true
                Add("professionSkillLines", "C_TradeSkillUI.GetProfessionInfoBySkillLineID", { id })
            end
        end
    end)
    Add("experience", "UnitXP", { "player" })
    Add("experience", "UnitXPMax", { "player" })
    for slot = 1, 19 do
        for _, path in ipairs({ "GetInventoryItemID", "GetInventoryItemLink",
            "GetInventoryItemCount", "GetInventoryItemQuality" }) do
            Add("equipment", path, { "player", slot })
        end
        Add("equipment", "GetInventoryItemDurability", { slot })
    end
    -- Prefer observed namespace APIs; retain explicit legacy fallbacks.
    if Resolve("C_QuestLog.GetNumQuestLogEntries") then
        Collection("quests", "C_QuestLog.GetNumQuestLogEntries", "C_QuestLog.GetInfo")
    else Collection("quests", "GetNumQuestLogEntries", "GetQuestLogTitle") end
    Collection("skills", "GetNumSkillLines", "GetSkillLineInfo")
    if Resolve("C_Reputation.GetNumFactions") then
        Collection("reputation", "C_Reputation.GetNumFactions", "C_Reputation.GetFactionDataByIndex")
    else Collection("reputation", "GetNumFactions", "GetFactionInfo") end
    if Resolve("C_CurrencyInfo.GetCurrencyListSize") then
        Collection("currency", "C_CurrencyInfo.GetCurrencyListSize", "C_CurrencyInfo.GetCurrencyListInfo")
    else Collection("currency", "GetCurrencyListSize", "GetCurrencyListInfo") end
    local spellSlots = {}
    local function Spells(offset, count, modern)
        count = BoundedCount(count)
        if not count or type(offset) ~= "number" or offset < 0 or offset ~= math.floor(offset)
            or offset == math.huge then return end
        local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
        if modern and type(bank) ~= "number" then
            state.result.spellBankUnavailable = true
            return
        end
        for i = 1, count do
            local slot = offset + i
            if not spellSlots[slot] then
                spellSlots[slot] = true
                if modern then
                    Add("spells", "C_SpellBook.GetSpellBookItemInfo", { slot, bank })
                    Add("spells", "C_SpellBook.GetSpellBookItemName", { slot, bank })
                else
                    Add("spells", "GetSpellBookItemInfo", { slot, "spell" })
                    Add("spells", "GetSpellBookItemName", { slot, "spell" })
                end
            end
        end
    end
    if Resolve("C_SpellBook.GetNumSpellBookSkillLines") then
        Collection("spellSkillLines", "C_SpellBook.GetNumSpellBookSkillLines",
            "C_SpellBook.GetSpellBookSkillLineInfo", function(raw)
                local info = raw[2]
                if type(info) == "table" then Spells(info.itemIndexOffset, info.numSpellBookItems, true) end
            end)
    else Collection("spellSkillLines", "GetNumSpellTabs", "GetSpellTabInfo", function(raw)
        Spells(raw[4], raw[5], false)
    end) end
    active = state
    log("Starting character capture...")
    frame:SetScript("OnUpdate", function()
        for _ = 1, 10 do
            local task = state.queue[state.head]
            if not task then
                state.result.capturedAt = time()
                state.result.statistics.queries = #state.result.queries
                ForeverAPIExplorerCharacterDB = state.result
                active = nil
                frame:SetScript("OnUpdate", nil)
                log("Character capture completed: " .. #state.result.queries ..
                    " queries. Use /reload to save to disk.")
                return
            end
            state.head = state.head + 1
            local record = { section = task.section, path = "_G." .. task.path,
                arguments = {}, argumentCount = #task.args, capturedAt = time() }
            for i = 1, #task.args do
                record.arguments[i] = Encode(task.args[i], 0, {}, { left = 2000 })
            end
            local fn = Resolve(task.path)
            if not fn then record.status = "unavailable"
            else
                local raw = Pack(pcall(fn, unpackArgs(task.args)))
                if not raw[1] then
                    record.status = "error"
                    record.error = string.sub(tostring(raw[2]), 1, 4096)
                else
                    record.status = "ok"
                    record.returnCount = raw.n - 1
                    record.returns = {}
                    local budget = { left = 2000 }
                    local ok, err = pcall(function()
                        for i = 2, raw.n do
                            record.returns[i - 1] = Encode(raw[i], 0, {}, budget)
                        end
                    end)
                    if not ok then
                        record.status = "error"
                        record.serializationError = string.sub(tostring(err), 1, 4096)
                    else
                        if budget.restricted then
                            record.hasRestrictedValues = true
                            state.result.statistics.restrictedQueries =
                                state.result.statistics.restrictedQueries + 1
                        end
                        if task.after then
                            local public = { n = raw.n, [1] = true }
                            local expanded, expansionError = pcall(function()
                                for i = 2, raw.n do public[i] = Public(record.returns[i - 1]) end
                                task.after(public)
                            end)
                            if not expanded then
                                record.status = "error"
                                record.expansionError = string.sub(tostring(expansionError), 1, 4096)
                            end
                        end
                    end
                end
            end
            local stats = state.result.statistics
            stats[record.status] = stats[record.status] + 1
            table.insert(state.result.queries, record)
        end
    end)
end
