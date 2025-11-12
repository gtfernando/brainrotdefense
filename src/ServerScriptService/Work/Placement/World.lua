local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local PlacementModule = ReplicatedStorage:WaitForChild("Placement") :: ModuleScript
local Placement = require(PlacementModule)
local Constants = Placement.Constants

local jecs = require(ReplicatedStorage.Packages.jecs)

local world = jecs.World.new()

local Components = {
	PlotOwnerId = world:component(),
	PlotSlot = world:component(),
	PlotOrigin = world:component(),
	PlotGridSize = world:component(),
	PlotCellSize = world:component(),
	PlotOccupied = world:component(),
	PlotPlacements = world:component(),
	PlotAssetsFolder = world:component(),
	PlotBasePart = world:component(),
	PlotSpawnCFrame = world:component(),
	PlotBlockedCells = world:component(),
	PlotBlockedZones = world:component(),

	PlacementPlot = world:component(),
	PlacementId = world:component(),
	PlacementAsset = world:component(),
	PlacementPosition = world:component(),
	PlacementRotation = world:component(),
	PlacementCells = world:component(),
	PlacementModel = world:component(),
	PlacementData = world:component(),
	PlacementOwner = world:component(),
	PlacementRoot = world:component(),
	PlacementMoneyRate = world:component(),
	PlacementAccumulated = world:component(),
	PlacementDisplayedAccumulated = world:component(),
	PlacementAccumulatedLabel = world:component(),
	PlacementEarningsMeta = world:component(),
}

local PlacementWorld = {}
PlacementWorld.World = world
PlacementWorld.Components = Components

local function getOccupied(plotEntity)
	return world:get(plotEntity, Components.PlotOccupied) :: { [number]: { [number]: number } }
end

local function getPlacementsSet(plotEntity)
	return world:get(plotEntity, Components.PlotPlacements) :: { [number]: true }
end

local function cloneBlockedCellsMap(original: { [number]: { [number]: string } })
	local copy = {}
	for x, column in original do
		local newColumn = {}
		for y, zoneId in column do
			newColumn[y] = zoneId
		end
		copy[x] = newColumn
	end
	return copy
end

local function cloneBlockedZones(zones: { { id: string, min: Vector2, max: Vector2, locked: boolean } })
	local copy = table.create(#zones)
	for index, zone in zones do
		copy[index] = {
			id = zone.id,
			min = Vector2.new(zone.min.X, zone.min.Y),
			max = Vector2.new(zone.max.X, zone.max.Y),
			locked = zone.locked,
		}
	end
	return copy
end

local function occupyCells(plotEntity, placementEntity, cells)
	local occupied = getOccupied(plotEntity)
	for _, cell in cells do
		local column = occupied[cell.X]
		if not column then
			column = {}
			occupied[cell.X] = column
		end
		column[cell.Y] = placementEntity
	end
end

local function clearCells(plotEntity, placementEntity, cells)
	local occupied = getOccupied(plotEntity)
	for _, cell in cells do
		local column = occupied[cell.X]
		if column and column[cell.Y] == placementEntity then
			column[cell.Y] = nil
			if next(column) == nil then
				occupied[cell.X] = nil
			end
		end
	end
end

function PlacementWorld.CreatePlot(params)
	local entity = world:entity()

	world:set(entity, Components.PlotOwnerId, params.ownerId)
	world:set(entity, Components.PlotSlot, params.slot)
	world:set(entity, Components.PlotOrigin, params.origin)
	world:set(entity, Components.PlotGridSize, params.gridSize)
	world:set(entity, Components.PlotCellSize, params.cellSize or Constants.CELL_SIZE)
	world:set(entity, Components.PlotOccupied, {})
	world:set(entity, Components.PlotPlacements, {})
	world:set(entity, Components.PlotAssetsFolder, params.assetsFolder)
	if params.blockedCells then
		world:set(entity, Components.PlotBlockedCells, cloneBlockedCellsMap(params.blockedCells))
	else
		world:set(entity, Components.PlotBlockedCells, {})
	end
	if params.blockedZones then
		world:set(entity, Components.PlotBlockedZones, cloneBlockedZones(params.blockedZones))
	else
		world:set(entity, Components.PlotBlockedZones, {})
	end
	if params.basePart then
		world:set(entity, Components.PlotBasePart, params.basePart)
	end
	if params.spawnCFrame then
		world:set(entity, Components.PlotSpawnCFrame, params.spawnCFrame)
	end

	return entity
end


function PlacementWorld.DestroyPlot(plotEntity)
	for placementEntity in world:each(Components.PlacementPlot) do
		local owner = world:get(placementEntity, Components.PlacementPlot)
		if owner == plotEntity then
			PlacementWorld.DestroyPlacement(placementEntity)
		end
	end

	world:delete(plotEntity)
end

function PlacementWorld.GetPlotByOwner(ownerId: number)
	for entity, storedOwnerId in world:query(Components.PlotOwnerId) do
		if storedOwnerId == ownerId then
			return entity
		end
	end
	return nil
end

function PlacementWorld.GetPlotData(plotEntity)
	local origin, gridSize, cellSize = world:get(plotEntity, Components.PlotOrigin, Components.PlotGridSize, Components.PlotCellSize)
	return {
		origin = origin,
		gridSize = gridSize,
		cellSize = cellSize,
	}
end

function PlacementWorld.GetPlotBase(plotEntity): BasePart?
	return world:get(plotEntity, Components.PlotBasePart)
end

function PlacementWorld.GetPlotSpawnCFrame(plotEntity): CFrame?
	return world:get(plotEntity, Components.PlotSpawnCFrame)
end

function PlacementWorld.GetBlockedCells(plotEntity)
	return world:get(plotEntity, Components.PlotBlockedCells) :: { [number]: { [number]: string } }
end

function PlacementWorld.GetBlockedZones(plotEntity)
	return world:get(plotEntity, Components.PlotBlockedZones) :: { { id: string, min: Vector2, max: Vector2, locked: boolean } }
end

function PlacementWorld.GetBlockingZoneId(plotEntity, cell: Vector2): string?
	local blocked = PlacementWorld.GetBlockedCells(plotEntity)
	local column = blocked and blocked[cell.X]
	if not column then
		return nil
	end
	return column[cell.Y]
end

function PlacementWorld.IsCellBlocked(plotEntity, cell: Vector2): boolean
	return PlacementWorld.GetBlockingZoneId(plotEntity, cell) ~= nil
end

function PlacementWorld.IsAreaFree(plotEntity, cells)
	local occupied = getOccupied(plotEntity)
	local blocked = PlacementWorld.GetBlockedCells(plotEntity)
	for _, cell in cells do
		local column = occupied[cell.X]
		if column and column[cell.Y] then
			return false
		end
		local blockedColumn = blocked[cell.X]
		if blockedColumn and blockedColumn[cell.Y] then
			return false
		end
	end
	return true
end

local function clonePlacementData(data)
	return {
		id = data.id,
		asset = data.asset,
		position = Vector2.new(data.position.X, data.position.Y),
		rotation = data.rotation,
		level = data.level,
	}
end

function PlacementWorld.CreatePlacement(plotEntity, placementData, model)
	local entity = world:entity()

	world:set(entity, Components.PlacementPlot, plotEntity)
	world:set(entity, Components.PlacementId, placementData.id)
	world:set(entity, Components.PlacementAsset, placementData.asset)
	world:set(entity, Components.PlacementPosition, placementData.position)
	world:set(entity, Components.PlacementRotation, placementData.rotation)
	world:set(entity, Components.PlacementCells, placementData.cells)
	world:set(entity, Components.PlacementModel, model)
	world:set(entity, Components.PlacementData, clonePlacementData(placementData))

	occupyCells(plotEntity, entity, placementData.cells)
	local placementsSet = getPlacementsSet(plotEntity)
	placementsSet[entity] = true

	return entity
end

function PlacementWorld.DestroyPlacement(placementEntity)
	local plotEntity, cells, model = world:get(placementEntity, Components.PlacementPlot, Components.PlacementCells, Components.PlacementModel)
	if plotEntity then
		clearCells(plotEntity, placementEntity, cells)
		local placementsSet = getPlacementsSet(plotEntity)
		placementsSet[placementEntity] = nil
	end

	if model and model.Parent then
		model:Destroy()
	end

	world:delete(placementEntity)
end

function PlacementWorld.SerializePlacement(placementEntity)
	local data = world:get(placementEntity, Components.PlacementData)
	return clonePlacementData(data)
end

function PlacementWorld.GetPlacementModel(placementEntity): Model?
	return world:get(placementEntity, Components.PlacementModel)
end

function PlacementWorld.ReplacePlacementModel(placementEntity, newModel: Model?)
	if typeof(placementEntity) ~= "number" then
		return
	end

	local currentModel = PlacementWorld.GetPlacementModel(placementEntity)
	if currentModel and currentModel ~= newModel then
		currentModel:Destroy()
	end

	if newModel and newModel:IsA("Model") then
		world:set(placementEntity, Components.PlacementModel, newModel)
	else
		world:remove(placementEntity, Components.PlacementModel)
	end
end

function PlacementWorld.SetPlacementLevel(placementEntity, newLevel: number)
	local data = world:get(placementEntity, Components.PlacementData)
	if not data then
		return
	end

	data.level = math.max(1, math.floor(newLevel + 0.5))
end

function PlacementWorld.GeneratePlacementData(assetId: string, position: Vector2, rotation: number)
	return {
		id = HttpService:GenerateGUID(false),
		asset = assetId,
		position = position,
		rotation = rotation,
		cells = {},
		level = 1,
	}
end

function PlacementWorld.ListPlacements(plotEntity)
	local results = {}
	for placementEntity, placementPlot in world:query(Components.PlacementPlot) do
		if placementPlot == plotEntity then
			results[#results + 1] = placementEntity
		end
	end
	return results
end

function PlacementWorld.ApplyBlockingState(plotEntity, params: { cellsMap: { [number]: { [number]: string } }?, zones: { { id: string, min: Vector2, max: Vector2, locked: boolean } }? })
	if params.cellsMap then
		world:set(plotEntity, Components.PlotBlockedCells, cloneBlockedCellsMap(params.cellsMap))
	end

	if params.zones then
		world:set(plotEntity, Components.PlotBlockedZones, cloneBlockedZones(params.zones))
	end
end

return PlacementWorld
