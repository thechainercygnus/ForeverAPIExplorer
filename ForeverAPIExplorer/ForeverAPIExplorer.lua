local ADDON, API = ...

local ADDON_VERSION = "0.3.0"

-- Scanner configuration
local MAX_DEPTH = 15
local MAX_ENTRIES = 100000
local MAX_STRING_LENGTH = 512
local ENTRIES_PER_FRAME = 400

local frame = CreateFrame("Frame")

local scan = nil

-- ============================================================
-- Logging
-- ============================================================

local function Print(message)
    print("|cff00ccff[ForeverAPI]|r " .. tostring(message))
end

local function DebugPrint(message)
    if scan and scan.debug then
        Print("[Debug] " .. tostring(message))
    end
end

-- ============================================================
-- Utility functions
-- ============================================================

local function GetClientInfo()
    local info = {}

    if GetBuildInfo then
        local ok, version, build, buildDate, interface =
            pcall(GetBuildInfo)

        if ok then
            info.version = version
            info.build = build
            info.buildDate = buildDate
            info.interface = interface
        end
    end

    if GetLocale then
        local ok, locale = pcall(GetLocale)

        if ok then
            info.locale = locale
        end
    end

    return info
end

-- Build a readable Lua-style path for a table key.
local function BuildPath(parent, key)
    if type(key) == "number" then
        return parent .. "[" .. tostring(key) .. "]"
    end

    if type(key) == "string" then
        if key:match("^[%a_][%w_]*$") then
            return parent .. "." .. key
        end

        return parent .. "[" .. string.format("%q", key) .. "]"
    end

    return nil
end

local function SortByPath(a, b)
    return a.path < b.path
end

-- ============================================================
-- Scanner
-- ============================================================

local function FinishScan()
    if not scan then return end

    local state = scan

    -- Sort records for easier external inspection.
    table.sort(state.result.functions, SortByPath)
    table.sort(state.result.tables, SortByPath)
    table.sort(state.result.values, SortByPath)
    table.sort(state.result.other, SortByPath)

    local result = state.result

    result.schemaVersion = 1
    result.addonVersion = ADDON_VERSION
    result.capturedAt = time()
    result.scanStartedAt = state.startedAt
    result.client = GetClientInfo()

    result.statistics = {
        functions = #result.functions,
        tables = #result.tables,
        values = #result.values,
        other = #result.other,
        entriesScanned = state.entriesScanned,
        unsupportedKeys = state.unsupportedKeys,
        traversalErrors = state.traversalErrors,
        maxDepth = MAX_DEPTH,
        truncated = state.truncated,
    }

    -- Persist the completed export.
    ForeverAPIExplorerDB = result

    scan = nil
    frame:SetScript("OnUpdate", nil)

    Print("API export completed!")
    Print("Functions: " .. result.statistics.functions)
    Print("Tables: " .. result.statistics.tables)
    Print("Values: " .. result.statistics.values)
    Print("Other: " .. result.statistics.other)
    Print("Entries scanned: " .. result.statistics.entriesScanned)

    if result.statistics.truncated then
        Print("WARNING: Export reached the entry limit.")
    end

    Print("Use /reload to save the export to disk.")
end

local function ProcessEntry(task, key, value)
    local path = BuildPath(task.path, key)

    if not path then
        scan.unsupportedKeys = scan.unsupportedKeys + 1
        return
    end

    local valueType = type(value)

    if valueType == "function" then
        table.insert(scan.result.functions, {
            path = path,
            type = valueType,
        })
    elseif valueType == "table" then
        table.insert(scan.result.tables, {
            path = path,
            depth = task.depth + 1,
        })

        -- Avoid cycles and repeated traversal of aliases.
        if not scan.visited[value] then
            scan.visited[value] = true

            if task.depth + 1 <= MAX_DEPTH then
                table.insert(scan.queue, {
                    value = value,
                    path = path,
                    depth = task.depth + 1,
                    started = false,
                })
            end
        end
    elseif valueType == "string" then
        local storedValue = value
        local truncated = false

        if #storedValue > MAX_STRING_LENGTH then
            storedValue = string.sub(
                storedValue,
                1,
                MAX_STRING_LENGTH
            )
            truncated = true
        end

        table.insert(scan.result.values, {
            path = path,
            type = valueType,
            value = storedValue,
            truncated = truncated,
        })
    elseif valueType == "number"
        or valueType == "boolean" then
        table.insert(scan.result.values, {
            path = path,
            type = valueType,
            value = value,
        })
    else
        table.insert(scan.result.other, {
            path = path,
            type = valueType,
        })
    end
end

local function StartScan()
    if API.CharacterBusy() then
        Print("Wait for the character capture to finish.")
        return
    end
    if scan then
        Print("An export is already running.")
        return
    end

    Print("Starting API environment scan...")

    scan = {
        startedAt = time(),

        queue = {
            {
                value = _G,
                path = "_G",
                depth = 0,
                started = false,
            },
        },

        queueHead = 1,
        visited = {
            [_G] = true,
        },

        entriesScanned = 0,
        unsupportedKeys = 0,
        traversalErrors = 0,
        truncated = false,

        result = {
            functions = {},
            tables = {},
            values = {},
            other = {},
        },
    }

    -- Process a limited number of entries each frame.
    frame:SetScript("OnUpdate", function(self, elapsed)
        if not scan then
            self:SetScript("OnUpdate", nil)
            return
        end

        local processed = 0

        while processed < ENTRIES_PER_FRAME do
            local task = scan.queue[scan.queueHead]

            if not task then
                FinishScan()
                return
            end

            -- Fetch the next key/value pair.
            local ok, key, value

            if not task.started then
                ok, key, value = pcall(next, task.value)
                task.started = true
            else
                ok, key, value = pcall(
                    next,
                    task.value,
                    task.lastKey
                )
            end

            if not ok then
                scan.traversalErrors =
                    scan.traversalErrors + 1

                DebugPrint("Traversal error: " .. task.path)

                scan.queueHead = scan.queueHead + 1
            elseif key == nil then
                scan.queueHead = scan.queueHead + 1
            else
                task.lastKey = key

                scan.entriesScanned = scan.entriesScanned + 1

                ProcessEntry(task, key, value)

                processed = processed + 1

                if scan.entriesScanned >= MAX_ENTRIES then
                    scan.truncated = true
                    FinishScan()
                    return
                end
            end
        end
    end)
end

-- ============================================================
-- Commands
-- ============================================================

local function HandleCommand(input)
    local command = input:match("^(%S+)")

    if not command then
        command = "help"
    end

    command = command:lower()

    if command == "help" then
        Print("Available commands:")
        Print("/api export - Discover Lua environment paths (limited scan)")
        Print("/api character - Capture reviewed character queries")
        Print("/api characterstatus - Show the last character capture")
        Print("/api clearcharacter - Clear the character capture")
        Print("/api status - Show export status")
        Print("/api clear - Clear the previous export")
    elseif command == "character" then
        if scan then Print("Wait for the environment scan to finish."); return end
        API.StartCharacter(ADDON_VERSION, GetClientInfo(), Print)
    elseif command == "characterstatus" then
        if API.CharacterBusy() then Print("Character capture in progress.")
        elseif ForeverAPIExplorerCharacterDB then
            local result = ForeverAPIExplorerCharacterDB
            local stats = result.statistics
            Print("Character captured: " .. tostring(result.capturedAt))
            Print("Queries: " .. stats.queries .. "; OK: " .. stats.ok ..
                "; errors: " .. stats.error .. "; unavailable: " .. stats.unavailable)
        else Print("No character capture found.") end
    elseif command == "clearcharacter" then
        if scan or API.CharacterBusy() then Print("Wait for the capture to finish."); return end
        ForeverAPIExplorerCharacterDB = nil
        Print("Character capture cleared. Use /reload to save.")
    elseif command == "export" then
        StartScan()
    elseif command == "status" then
        if scan then
            Print("Scan in progress.")
            Print("Entries scanned: " .. scan.entriesScanned)
            Print("Tables queued: " ..
                (#scan.queue - scan.queueHead + 1))
        elseif ForeverAPIExplorerDB then
            local stats = ForeverAPIExplorerDB.statistics

            if stats then
                Print("Previous export:")
                Print("Captured: " ..
                    tostring(ForeverAPIExplorerDB.capturedAt))
                Print("Functions: " .. stats.functions)
                Print("Tables: " .. stats.tables)
                Print("Values: " .. stats.values)
                Print("Entries: " .. stats.entriesScanned)
            else
                Print("No completed export found.")
            end
        else
            Print("No export found.")
        end
    elseif command == "clear" then
        if scan then
            Print("Cannot clear while scanning.")
            return
        end

        ForeverAPIExplorerDB = nil
        Print("Previous export cleared.")
    else
        Print("Unknown command. Use /api help.")
    end
end

-- ============================================================
-- Initialization
-- ============================================================

frame:RegisterEvent("ADDON_LOADED")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...

        if name ~= ADDON then return end

        ForeverAPIExplorerDB = ForeverAPIExplorerDB or {}

        SLASH_FOREVERAPIEXPLORER1 = "/api"
        SlashCmdList["FOREVERAPIEXPLORER"] = HandleCommand

        Print("API Explorer loaded.")
        Print("Type /api help for commands.")
    end
end)
