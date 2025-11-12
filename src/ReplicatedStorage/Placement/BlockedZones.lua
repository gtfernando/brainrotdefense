local Constants = require(script.Parent.Constants)


export type ZoneDefinition = {
	id: string?,
	min: Vector2 | { [string]: number },
	max: Vector2 | { [string]: number },
	locked: boolean?,
}

export type NormalizedZone = {
	id: string,
	min: Vector2,
	max: Vector2,
	locked: boolean,
}

local function toVector2(value: Vector2 | { [string]: number }): Vector2
	if typeof(value) == "Vector2" then
		return value
	end

	local x = value.x or value.X
	local y = value.y or value.Y
	assert(type(x) == "number" and type(y) == "number", "Blocked zone coordinates must contain x/y")
	return Vector2.new(math.floor(x + 0.5), math.floor(y + 0.5))
end

local function clampToGrid(vec: Vector2, grid: Vector2): Vector2
	return Vector2.new(math.clamp(vec.X, 1, grid.X), math.clamp(vec.Y, 1, grid.Y))
end

local GRID_SIZE = Constants.PLOT.GRID_CELLS
local blockingConfig = Constants.PLOT.BLOCKING or {}
local tileCells = blockingConfig.TILE_CELLS or Vector2.new(4, 4)
local TILE_WIDTH = math.max(1, tileCells.X)
local TILE_HEIGHT = math.max(1, tileCells.Y)

local function generateDefaultTiles()
	local tiles = {}
	local idCounter = 1

	for y = 1, GRID_SIZE.Y, TILE_HEIGHT do
		for x = 1, GRID_SIZE.X, TILE_WIDTH do
			local minCell = Vector2.new(x, y)
			local maxCell = Vector2.new(
				math.min(x + TILE_WIDTH - 1, GRID_SIZE.X),
				math.min(y + TILE_HEIGHT - 1, GRID_SIZE.Y)
			)

			tiles[#tiles + 1] = {
				id = `LockedZone_{idCounter}`,
				min = minCell,
				max = maxCell,
				locked = true,
			}

			idCounter += 1
		end
	end

	return tiles
end

local DEFAULT_TILES = generateDefaultTiles()
local slotOverrides: { [number]: { [number]: ZoneDefinition } } = {}

local BlockedZones = {}

local function cloneZone(zone: ZoneDefinition, index: number): NormalizedZone
	local id = zone.id or `LockedZone_{index}`
	local min = clampToGrid(toVector2(zone.min), GRID_SIZE)
	local max = clampToGrid(toVector2(zone.max), GRID_SIZE)

	return {
		id = id,
		min = Vector2.new(math.min(min.X, max.X), math.min(min.Y, max.Y)),
		max = Vector2.new(math.max(min.X, max.X), math.max(min.Y, max.Y)),
		locked = zone.locked ~= false,
	}
end

local function cloneZones(source: { ZoneDefinition }): { NormalizedZone }
	local cloned = table.create(#source)
	for index, zone in source do
		cloned[index] = cloneZone(zone, index)
	end
	return cloned
end

function BlockedZones.GetForSlot(slotIndex: number): { NormalizedZone }
	local override = slotOverrides[slotIndex]
	if override then
		return cloneZones(override)
	end
	return cloneZones(DEFAULT_TILES)
end

return BlockedZones
