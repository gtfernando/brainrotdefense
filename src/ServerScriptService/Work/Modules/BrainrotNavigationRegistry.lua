local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local freeze = table.freeze or function(tableToFreeze)
    return tableToFreeze
end

local PlacementModule = ReplicatedStorage:WaitForChild("Placement") :: ModuleScript
local PlacementConstants = require(PlacementModule).Constants

local PLOT_PREFIX = "PlotSlot_"
local SPAWN_FOLDER_NAME = "BrainrotSpawns"
local WAYPOINT_FOLDER_NAME = "Waypoints"
local EXPECTED_PLOT_COUNT = 6
local WAIT_TIMEOUT = 10

local plotRootName = PlacementConstants and PlacementConstants.PLOT and PlacementConstants.PLOT.FOLDER_NAME
if not plotRootName then
    plotRootName = "PlacementPlots"
end

local plotRootFolder = Workspace:WaitForChild(plotRootName)
if not plotRootFolder then
    error(`BrainrotNavigationRegistry expected Workspace.{plotRootName} to exist`)
end

local BrainrotNavigationRegistry = {}

local cached
local cachedByName

local function extractNumericSuffix(name)
    if typeof(name) ~= "string" then
        return nil
    end

    local suffix = string.match(name, "(%d+)$")
    if suffix then
        return tonumber(suffix)
    end

    return nil
end

local function sortParts(parts)
    table.sort(parts, function(a, b)
        local aIndex = extractNumericSuffix(a.Name) or math.huge
        local bIndex = extractNumericSuffix(b.Name) or math.huge
        if aIndex ~= bIndex then
            return aIndex < bIndex
        end
        return a.Name < b.Name
    end)
end

local function collectBaseParts(folder)
    if not folder or not (folder:IsA("Folder") or folder:IsA("Model")) then
        return {}
    end

    local parts = {}
    for _, child in folder:GetChildren() do
        if child:IsA("BasePart") then
            parts[#parts + 1] = child
        end
    end

    if #parts > 1 then
        sortParts(parts)
    end

    return parts
end

local function packEntries(parts)
    local entries = table.create(#parts)
    for index, part in ipairs(parts) do
        entries[index] = freeze({
            name = part.Name,
            position = part.Position,
            cframe = part.CFrame,
        })
    end

    return freeze(entries)
end

local function packPositionList(entries)
    local positions = table.create(#entries)
    for index, entry in ipairs(entries) do
        positions[index] = entry.position
    end

    return freeze(positions)
end

local function buildWaypointGraph(entries)
    local count = #entries
    if count <= 1 then
        return freeze({})
    end

    local axisTolerance = 0.1
    local adjacency = table.create(count)
    for index = 1, count do
        adjacency[index] = {}
    end

    for i = 1, count - 1 do
        local originPos = entries[i].position
        for j = i + 1, count do
            local targetPos = entries[j].position

            local sameX = math.abs(originPos.X - targetPos.X) <= axisTolerance
            local sameZ = math.abs(originPos.Z - targetPos.Z) <= axisTolerance

            if sameX or sameZ then
                local axisMin = if sameX then originPos.Z else originPos.X
                local axisMax = if sameX then targetPos.Z else targetPos.X
                if axisMax < axisMin then
                    axisMin, axisMax = axisMax, axisMin
                end

                local hasBetween = false
                for k = 1, count do
                    if k ~= i and k ~= j then
                        local candidatePos = entries[k].position
                        local candidateSame = if sameX
                            then math.abs(candidatePos.X - originPos.X) <= axisTolerance
                            else math.abs(candidatePos.Z - originPos.Z) <= axisTolerance

                        if candidateSame then
                            local axisValue = if sameX then candidatePos.Z else candidatePos.X
                            if axisValue > axisMin + axisTolerance and axisValue < axisMax - axisTolerance then
                                hasBetween = true
                                break
                            end
                        end
                    end
                end

                if not hasBetween then
                    local neighborsA = adjacency[i]
                    neighborsA[#neighborsA + 1] = j
                    local neighborsB = adjacency[j]
                    neighborsB[#neighborsB + 1] = i
                end
            end
        end
    end

    for index = 1, count do
        adjacency[index] = freeze(adjacency[index])
    end

    return freeze(adjacency)
end

local function buildCache()
    local byIndex = table.create(EXPECTED_PLOT_COUNT)
    local byName = {}

    for index = 1, EXPECTED_PLOT_COUNT do
        local plotName = PLOT_PREFIX .. index
        local plotFolder = plotRootFolder:FindFirstChild(plotName) or plotRootFolder:WaitForChild(plotName, WAIT_TIMEOUT)

        if not plotFolder then
            warn(`BrainrotNavigationRegistry could not find {plotRootName}.{plotName} when scanning waypoints`)
            byIndex[index] = freeze({
                name = plotName,
                spawns = freeze({}),
                spawnPositions = freeze({}),
                waypoints = freeze({}),
            })
            byName[plotName] = byIndex[index]
            continue
        end

        local spawnFolder = plotFolder:FindFirstChild(SPAWN_FOLDER_NAME)
        local waypointFolder = plotFolder:FindFirstChild(WAYPOINT_FOLDER_NAME)

        local spawnParts = collectBaseParts(spawnFolder)
        local waypointParts = collectBaseParts(waypointFolder)

    local spawnEntries = packEntries(spawnParts)
    local waypointEntries = packEntries(waypointParts)

        local plotEntry = freeze({
            name = plotName,
            spawns = spawnEntries,
            spawnPositions = packPositionList(spawnEntries),
            waypoints = packPositionList(waypointEntries),
            waypointEntries = waypointEntries,
            waypointGraph = buildWaypointGraph(waypointEntries),
        })

        byIndex[index] = plotEntry
        byName[plotName] = plotEntry

        if spawnFolder then
            spawnFolder:Destroy()
        end

        if waypointFolder then
            waypointFolder:Destroy()
        end
    end

    cached = freeze(byIndex)
    cachedByName = freeze(byName)
end

local function ensureCache()
    if not cached then
        buildCache()
    end

    return cached, cachedByName
end

function BrainrotNavigationRegistry.Bootstrap()
    ensureCache()
end

function BrainrotNavigationRegistry.GetPlot(slotId)
    local byIndex, byName = ensureCache()

    if typeof(slotId) == "number" then
        return byIndex[slotId]
    end

    if typeof(slotId) == "string" then
        return byName[slotId]
    end

    error("BrainrotNavigationRegistry.GetPlot expects a number or string identifier")
end

function BrainrotNavigationRegistry.GetAll()
    return ensureCache()
end

return BrainrotNavigationRegistry
