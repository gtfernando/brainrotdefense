local Constants = require(script.Parent.Constants)

local Grid = {}

function Grid.getOrientedFootprint(footprint: Vector2, rotation: number): Vector2
	if rotation % 2 ~= 0 then
		return Vector2.new(footprint.Y, footprint.X)
	end
	return footprint
end

function Grid.isWithinBounds(gridSize: Vector2, position: Vector2, footprint: Vector2): boolean
	if position.X < 1 or position.Y < 1 then
		return false
	end

	local maxX = position.X + footprint.X - 1
	local maxY = position.Y + footprint.Y - 1

	return maxX <= gridSize.X and maxY <= gridSize.Y
end

function Grid.enumerateCells(position: Vector2, footprint: Vector2): { Vector2 }
	local cells = table.create(footprint.X * footprint.Y)
	local index = 1

	for dx = 0, footprint.X - 1 do
		for dy = 0, footprint.Y - 1 do
			cells[index] = Vector2.new(position.X + dx, position.Y + dy)
			index += 1
		end
	end

	return cells
end

function Grid.cellToWorld(origin: CFrame, cellSize: number, position: Vector2): CFrame
	return origin * CFrame.new((position.X - 0.5) * cellSize, 0, (position.Y - 0.5) * cellSize)
end

function Grid.worldToCell(origin: CFrame, cellSize: number, worldPosition: Vector3): Vector2
	local localPoint = origin:PointToObjectSpace(worldPosition)
	local x = math.floor(localPoint.X / cellSize) + 1
	local y = math.floor(localPoint.Z / cellSize) + 1
	return Vector2.new(x, y)
end

function Grid.computePlacementCFrame(origin: CFrame, cellSize: number, position: Vector2, rotation: number, orientedFootprint: Vector2, heightOffset: number): CFrame
	local baseCFrame = Grid.cellToWorld(origin, cellSize, position)
	local rotationCFrame = CFrame.Angles(0, rotation * Constants.DEFAULT_ROTATION_STEP, 0)
	local offset = Vector3.new((orientedFootprint.X - 1) * cellSize * 0.5, heightOffset, (orientedFootprint.Y - 1) * cellSize * 0.5)
	return baseCFrame * rotationCFrame * CFrame.new(offset)
end

return Grid
