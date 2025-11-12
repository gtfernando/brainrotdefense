--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataFolder = ReplicatedStorage:WaitForChild("Data")
local BuildingsModule = DataFolder:WaitForChild("Buildings") :: ModuleScript
local AmmoBuildingsModule = DataFolder:WaitForChild("AmmoBuildings") :: ModuleScript
local BuildingsData = require(BuildingsModule)
local AmmoBuildingsData = require(AmmoBuildingsModule)

local PlacementStats = {}

local function normalizeLevel(value: any): number
	local numeric = tonumber(value)
	if not numeric then
		return 1
	end

	if numeric < 1 then
		numeric = 1
	end

	return math.max(1, math.floor(numeric + 0.5))
end

local function getBuilding(assetId: string): { [string]: any }?
	if typeof(assetId) ~= "string" or assetId == "" then
		return nil
	end

	local building = BuildingsData[assetId]
	if typeof(building) ~= "table" then
		return nil
	end

	return building
end

local function getAmmoBuilding(assetId: string): { [string]: any }?
	if typeof(assetId) ~= "string" or assetId == "" then
		return nil
	end

	local definition = AmmoBuildingsData[assetId]
	if typeof(definition) ~= "table" then
		return nil
	end

	return definition
end

local function buildOrderedLevels(assetData: { [string]: any }?): { { level: number, info: { [string]: any } } }?
	if not assetData then
		return nil
	end

	local source = assetData.Level or assetData.Levels
	if typeof(source) ~= "table" then
		return nil
	end

	local ordered = {}
	local seenLevels: { [number]: boolean } = {}
	for key, value in source do
		if typeof(value) == "table" then
			local numericKey = if typeof(key) == "number" then key else tonumber(key)
			if numericKey then
				local normalizedLevel = normalizeLevel(numericKey)
				if not seenLevels[normalizedLevel] then
					seenLevels[normalizedLevel] = true
					ordered[#ordered + 1] = {
						level = normalizedLevel,
						info = value,
					}
				end
			end
		end
	end

	if #ordered == 0 then
		return nil
	end

	table.sort(ordered, function(left, right)
		return left.level < right.level
	end)

	return ordered
end

local function resolveNearestLevel(orderedLevels: { { level: number, info: { [string]: any } } }?, level: number): ({ [string]: any }?, number?)
	if not orderedLevels then
		return nil, nil
	end

	local targetLevel = normalizeLevel(level)
	local previous = orderedLevels[1]

	for index = 1, #orderedLevels do
		local entry = orderedLevels[index]
		if entry.level == targetLevel then
			return entry.info, entry.level
		end

		if entry.level > targetLevel then
			return previous.info, previous.level
		end

		previous = entry
	end

	return previous.info, previous.level
end

local function getNearestLevelInfo(assetData: { [string]: any }?, level: number): ({ [string]: any }?, number?)
	local ordered = buildOrderedLevels(assetData)
	return resolveNearestLevel(ordered, level)
end

local function resolveAmmoLevelInfo(assetId: string, level: number): ({ [string]: any }?, number?)
	local ammoData = getAmmoBuilding(assetId)
	if not ammoData then
		return nil, nil
	end

	return getNearestLevelInfo(ammoData, level)
end

local function coercePositiveNumber(value: any): number?
	local numeric = tonumber(value)
	if not numeric then
		return nil
	end

	if numeric < 0 then
		numeric = 0
	end

	return numeric
end

function PlacementStats.GetMoneyPerSecond(assetId: string, level: number): number
	local buildingData = getBuilding(assetId)
	if not buildingData then
		return 0
	end

	local ordered = buildOrderedLevels(buildingData)
	if not ordered then
		return 0
	end

	local levelInfo = select(1, resolveNearestLevel(ordered, level))
	if not levelInfo then
		return 0
	end

	local explicit = coercePositiveNumber(levelInfo.MoneyPerSecond)
	if explicit then
		return explicit
	end

	local multiplier = coercePositiveNumber(levelInfo.Multiplier)
	if multiplier then
		local baseInfo = select(1, resolveNearestLevel(ordered, 1))
		local baseAmount = 0
		if baseInfo then
			baseAmount = coercePositiveNumber(baseInfo.MoneyPerSecond) or 0
		end
		return baseAmount * multiplier
	end

	return 0
end

function PlacementStats.GetLevelInfo(assetId: string, level: number): { [string]: any }?
	local buildingData = getBuilding(assetId)
	local info, resolvedLevel = getNearestLevelInfo(buildingData, level)
	if info and resolvedLevel then
		return info, resolvedLevel
	end

	local ammoInfo, ammoLevel = resolveAmmoLevelInfo(assetId, level)
	if ammoInfo and ammoLevel then
		return ammoInfo, ammoLevel
	end

	return ammoInfo
end

function PlacementStats.GetMaxHealth(assetId: string, level: number): number
local buildingData = getBuilding(assetId)
local info = select(1, getNearestLevelInfo(buildingData, level))
if info then
	local explicit = coercePositiveNumber(info.MaxHealth or info.maxHealth)
	if not explicit then
		local statsTable = info.Stats or info.stats
		if typeof(statsTable) == "table" then
			explicit = coercePositiveNumber(statsTable.health or statsTable.Health)
		end
	end
	if explicit and explicit > 0 then
		return explicit
	end
end

if buildingData then
	local fallback = coercePositiveNumber((buildingData :: any).MaxHealth or (buildingData :: any).maxHealth)
	if fallback and fallback > 0 then
		return fallback
	end
end

local ammoInfo = select(1, resolveAmmoLevelInfo(assetId, level))
if ammoInfo then
	local statsTable = ammoInfo.Stats or ammoInfo.stats
	if typeof(statsTable) == "table" then
		local explicit = coercePositiveNumber(statsTable.health or statsTable.Health)
		if explicit and explicit > 0 then
			return explicit
		end
	end
	local explicit = coercePositiveNumber(ammoInfo.health or ammoInfo.Health)
	if explicit and explicit > 0 then
		return explicit
	end
end

local ammoData = getAmmoBuilding(assetId)
if ammoData then
	local fallback = coercePositiveNumber((ammoData :: any).MaxHealth or (ammoData :: any).maxHealth)
	if fallback and fallback > 0 then
		return fallback
	end
end

return 0
end

return PlacementStats
