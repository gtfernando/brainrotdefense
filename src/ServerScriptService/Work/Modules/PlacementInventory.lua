--!strict

local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")

local Profiles = require(ServerScriptService.Work.Modules.Profiles)

export type PlacementItemRecord = {
	level: number,
	available: number,
}

export type PlacementInventoryState = {
	version: number,
	placementItems: { [string]: PlacementItemRecord },
	storedCounts: { [string]: number },
}

export type PlacementAdjustResult = {
	level: number,
	available: number,
	storedEntryIds: { string }?,
}

local INVENTORY_VERSION = 1

local PlacementInventory = {}

local function ensureInventory(profileData: any): PlacementInventoryState
	profileData.Inventory = profileData.Inventory or {
		version = INVENTORY_VERSION,
		placementItems = {},
		storedCounts = {},
	}

	local inventory = profileData.Inventory

	if typeof(inventory.version) ~= "number" then
		inventory.version = INVENTORY_VERSION
	end

	if typeof(inventory.placementItems) ~= "table" then
		inventory.placementItems = {}
	end

	if typeof(inventory.storedCounts) ~= "table" then
		inventory.storedCounts = {}
	end

	return inventory :: PlacementInventoryState
end

local function normalizeEntry(entry: any, defaultLevel: number?): PlacementItemRecord
	local level = tonumber(entry and entry.level) or defaultLevel or 1
	if level < 1 then
		level = 1
	end

	local available = tonumber(entry and entry.available) or 0
	if available < 0 then
		available = 0
	end

	return {
		level = level,
		available = available,
	}
end

local function ensurePlacementObjects(profileData: any): { any }
	if typeof(profileData) ~= "table" then
		return {}
	end

	local placementState = profileData.placement
	if typeof(placementState) ~= "table" then
		placementState = {
			version = 2,
			objects = {},
			zones = {
				version = 1,
				unlocked = {},
			},
		}
		profileData.placement = placementState
	end

	local objects = placementState.objects
	if typeof(objects) ~= "table" then
		objects = {}
		placementState.objects = objects
	end

	return objects
end

local function ensureStoredCounts(inventory: any): { [string]: number }
	if typeof(inventory.storedCounts) ~= "table" then
		inventory.storedCounts = {}
	end
	return inventory.storedCounts
end

local function computeStoredCount(objects: { any }, assetId: string): number
	local count = 0
	for _, entry in objects do
		if typeof(entry) == "table" and entry.asset == assetId and entry.stored == true then
			count += 1
		end
	end
	return count
end

function PlacementInventory.Adjust(player: Player, assetId: string, delta: number, defaultLevel: number?): PlacementAdjustResult?
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return nil
	end

	if typeof(assetId) ~= "string" or assetId == "" then
		return nil
	end

	delta = tonumber(delta) or 0
	local desiredLevel = if defaultLevel ~= nil then tonumber(defaultLevel) else nil

	local result = Profiles.Mutate(player, function(profileData)
		local inventory = ensureInventory(profileData)
		local placementItems = inventory.placementItems
		local storedCounts = ensureStoredCounts(inventory)

		local current = placementItems[assetId]
		local normalized = normalizeEntry(current, desiredLevel)

		normalized.available = normalized.available + delta
		if normalized.available < 0 then
			normalized.available = 0
		end

		if desiredLevel and normalized.level < desiredLevel then
			normalized.level = desiredLevel
		elseif normalized.level < 1 then
			normalized.level = 1
		end

		placementItems[assetId] = normalized

		local storedEntryIds: { string } = {}
		if delta > 0 then
			local objects = ensurePlacementObjects(profileData)
			local storedCount = storedCounts[assetId]
			if storedCount == nil then
				storedCount = computeStoredCount(objects, assetId)
				storedCounts[assetId] = storedCount
			end

			local targetCount = math.max(0, normalized.available)
			local deficit = targetCount - storedCount
			if deficit > 0 then
				local baseLevel = desiredLevel or normalized.level or 1
				local clampedLevel = math.max(1, math.floor((tonumber(baseLevel) or 1) + 0.5))
				for _ = 1, deficit do
					local storedId = HttpService:GenerateGUID(false)
					objects[#objects + 1] = {
						id = storedId,
						asset = assetId,
						level = clampedLevel,
						stored = true,
						position = nil,
						rotation = nil,
						token = nil,
					}
					storedEntryIds[#storedEntryIds + 1] = storedId
				end
				storedCounts[assetId] = storedCount + deficit
			else
				storedCounts[assetId] = storedCount
			end
		elseif storedCounts[assetId] ~= nil then
			storedCounts[assetId] = math.min(storedCounts[assetId], math.max(0, normalized.available))
		end

		return {
			level = normalized.level,
			available = normalized.available,
			storedEntryIds = storedEntryIds,
		}
	end)

	return result
end

function PlacementInventory.GetEntry(profileData: any, assetId: string): PlacementItemRecord?
	if typeof(profileData) ~= "table" then
		return nil
	end

	if typeof(assetId) ~= "string" or assetId == "" then
		return nil
	end

	local inventory = profileData.Inventory
	if typeof(inventory) ~= "table" then
		return nil
	end

	local placementItems = inventory.placementItems
	if typeof(placementItems) ~= "table" then
		return nil
	end

	local entry = placementItems[assetId]
	if typeof(entry) ~= "table" then
		return nil
	end

	return normalizeEntry(entry)
end

function PlacementInventory.GetAll(profileData: any): { [string]: PlacementItemRecord }
	local collection: { [string]: PlacementItemRecord } = {}

	if typeof(profileData) ~= "table" then
		return collection
	end

	local inventory = profileData.Inventory
	if typeof(inventory) ~= "table" then
		return collection
	end

	local placementItems = inventory.placementItems
	if typeof(placementItems) ~= "table" then
		return collection
	end

	for assetId, entry in placementItems do
		if typeof(assetId) == "string" and typeof(entry) == "table" then
			collection[assetId] = normalizeEntry(entry)
		end
	end

	return collection
end

return PlacementInventory
