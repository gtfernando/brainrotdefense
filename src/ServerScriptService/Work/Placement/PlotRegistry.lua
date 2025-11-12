local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlacementModule = ReplicatedStorage:WaitForChild("Placement") :: ModuleScript
local Constants = require(PlacementModule).Constants

local config = Constants.PLOT
local folderName = config.FOLDER_NAME or "PlacementPlots"

local rootFolder = Workspace:FindFirstChild(folderName)
if not rootFolder then
	error(`PlotRegistry expected Workspace.{folderName} to exist`)
end

local DEFAULT_BASE_NAME = if config.BASE and config.BASE.NAME then config.BASE.NAME else "PlotBase"
local SPAWN_NAME = "Spawn"
local DEFAULT_SPAWN_HEIGHT_OFFSET = config.SPAWN_HEIGHT_OFFSET or (Constants.CELL_SIZE * 0.5)

local function round(number: number): number
	return math.floor(number + 0.5)
end

local function ensureAssetsFolder(container: Instance): Folder
	local assets = container:FindFirstChild("Assets")
	if assets and assets:IsA("Folder") then
		return assets
	end

	local newFolder = Instance.new("Folder")
	newFolder.Name = "Assets"
	newFolder.Parent = container
	return newFolder
end

local function computeGridSize(basePart: BasePart, cellSize: number): Vector2
	local width = math.max(1, round(basePart.Size.X / cellSize))
	local depth = math.max(1, round(basePart.Size.Z / cellSize))
	return Vector2.new(width, depth)
end

local function computeOrigin(basePart: BasePart): CFrame
	local halfSize = basePart.Size * 0.5
	return basePart.CFrame * CFrame.new(-halfSize.X, halfSize.Y, -halfSize.Z)
end

local function extractZoneIndex(name: string?): number?
	if typeof(name) ~= "string" then
		return nil
	end

	local numeric = name:match("LockedZone_(%d+)$")
	if numeric then
		return tonumber(numeric)
	end

	numeric = name:match("Zone[_%-]?(%d+)$")
	if numeric then
		return tonumber(numeric)
	end

	numeric = name:match("(%d+)$")
	if numeric then
		return tonumber(numeric)
	end

	return nil
end

local function collectPlotParts(folder: Instance): { BasePart }
	local plotsFolder = folder:FindFirstChild("Plots")
	if not plotsFolder then
		return {}
	end

	local parts = {}
	for _, child in plotsFolder:GetChildren() do
		if child:IsA("BasePart") then
			parts[#parts + 1] = child
		end
	end

	table.sort(parts, function(a, b)
		local aIndex = extractZoneIndex(a.Name) or math.huge
		local bIndex = extractZoneIndex(b.Name) or math.huge
		if aIndex ~= bIndex then
			return aIndex < bIndex
		end
		return a.Name < b.Name
	end)

	return parts
end

local function computeCompositeGeometry(parts: { BasePart }, cellSize: number)
	if #parts == 0 then
		return nil
	end

	local reference = parts[1]
	local referenceCFrame = reference.CFrame
	local infoList = table.create(#parts)
	local minX, minZ = math.huge, math.huge
	local maxX, maxZ = -math.huge, -math.huge
	local maxTopOffset = reference.Size.Y * 0.5

	for _, part in parts do
		local localCenter = referenceCFrame:PointToObjectSpace(part.CFrame.Position)
		local halfX = part.Size.X * 0.5
		local halfY = part.Size.Y * 0.5
		local halfZ = part.Size.Z * 0.5

		local minLocalX = localCenter.X - halfX
		local maxLocalX = localCenter.X + halfX
		local minLocalZ = localCenter.Z - halfZ
		local maxLocalZ = localCenter.Z + halfZ

		infoList[#infoList + 1] = {
			part = part,
			localMinX = minLocalX,
			localMaxX = maxLocalX,
			localMinZ = minLocalZ,
			localMaxZ = maxLocalZ,
		}

		if minLocalX < minX then
			minX = minLocalX
		end
		if maxLocalX > maxX then
			maxX = maxLocalX
		end
		if minLocalZ < minZ then
			minZ = minLocalZ
		end
		if maxLocalZ > maxZ then
			maxZ = maxLocalZ
		end

		local topOffset = localCenter.Y + halfY
		if topOffset > maxTopOffset then
			maxTopOffset = topOffset
		end
	end

	if minX == math.huge or minZ == math.huge then
		return nil
	end

	local zoneDescriptors = table.create(#infoList)
	local cellBounds = {
		minX = math.huge,
		maxX = -math.huge,
		minZ = math.huge,
		maxZ = -math.huge,
	}

	for _, info in infoList do
		local widthCells = math.max(1, round(info.part.Size.X / cellSize))
		local depthCells = math.max(1, round(info.part.Size.Z / cellSize))

		local localMinCellX = round((info.localMinX - minX) / cellSize)
		local localMinCellZ = round((info.localMinZ - minZ) / cellSize)

		local minCellX = localMinCellX + 1
		local minCellZ = localMinCellZ + 1
		local maxCellX = minCellX + widthCells - 1
		local maxCellZ = minCellZ + depthCells - 1

		if minCellX < cellBounds.minX then
			cellBounds.minX = minCellX
		end
		if maxCellX > cellBounds.maxX then
			cellBounds.maxX = maxCellX
		end
		if minCellZ < cellBounds.minZ then
			cellBounds.minZ = minCellZ
		end
		if maxCellZ > cellBounds.maxZ then
			cellBounds.maxZ = maxCellZ
		end

		zoneDescriptors[#zoneDescriptors + 1] = {
			part = info.part,
			minCell = Vector2.new(minCellX, minCellZ),
			maxCell = Vector2.new(maxCellX, maxCellZ),
			widthCells = widthCells,
			depthCells = depthCells,
			zoneIndex = extractZoneIndex(info.part.Name),
		}
	end

	local totalWidthCells = math.max(1, cellBounds.maxX - cellBounds.minX + 1)
	local totalDepthCells = math.max(1, cellBounds.maxZ - cellBounds.minZ + 1)

	if cellBounds.minX ~= 1 or cellBounds.minZ ~= 1 then
		local offsetX = cellBounds.minX - 1
		local offsetZ = cellBounds.minZ - 1
		for _, descriptor in zoneDescriptors do
			descriptor.minCell = Vector2.new(descriptor.minCell.X - offsetX, descriptor.minCell.Y - offsetZ)
			descriptor.maxCell = Vector2.new(descriptor.maxCell.X - offsetX, descriptor.maxCell.Y - offsetZ)
		end
	end

	local coverage = table.create(totalWidthCells)
	for x = 1, totalWidthCells do
		coverage[x] = table.create(totalDepthCells)
	end

	for _, descriptor in zoneDescriptors do
		for x = descriptor.minCell.X, descriptor.maxCell.X do
			local column = coverage[x]
			for y = descriptor.minCell.Y, descriptor.maxCell.Y do
				column[y] = true
			end
		end
	end

	local origin = referenceCFrame * CFrame.new(minX, maxTopOffset, minZ)

	return {
		origin = origin,
		gridSize = Vector2.new(totalWidthCells, totalDepthCells),
		descriptors = zoneDescriptors,
		coverage = coverage,
	}
end

local function cloneZoneList(zones)
	local copy = table.create(#zones)
	for i, zone in zones do
		copy[i] = {
			id = zone.id,
			min = Vector2.new(zone.min.X, zone.min.Y),
			max = Vector2.new(zone.max.X, zone.max.Y),
			locked = zone.locked,
		}
		if zone.markerCFrame then
			copy[i].markerCFrame = zone.markerCFrame
		end
		if zone.markerSize then
			local size = zone.markerSize
			copy[i].markerSize = Vector3.new(size.X, size.Y, size.Z)
		end
	end
	return copy
end

local function buildBlockedCellData(zones)
	local blockedMap: { [number]: { [number]: string } } = {}
	local blockedList = {}
	local zoneLookup = {}

	for _, zone in zones do
		zoneLookup[zone.id] = zone
		if zone.locked then
			for x = zone.min.X, zone.max.X do
				local column = blockedMap[x]
				if not column then
					column = {}
					blockedMap[x] = column
				end
				for y = zone.min.Y, zone.max.Y do
					if column[y] and column[y] ~= zone.id then
						warn(`Blocked cell conflict at ({x}, {y}) between zones {column[y]} and {zone.id}`)
					end
					column[y] = zone.id
					blockedList[#blockedList + 1] = { x = x, y = y, zone = zone.id }
				end
			end
		end
	end

	return blockedMap, blockedList, zoneLookup
end

local function cloneBlockedMap(map)
	local copy = {}
	for x, column in map do
		local newColumn = {}
		for y, zoneId in column do
			newColumn[y] = zoneId
		end
		copy[x] = newColumn
	end
	return copy
end

local function cloneCellList(list)
	local copy = table.create(#list)
	for i, cell in list do
		copy[i] = { x = cell.x, y = cell.y, zone = cell.zone }
	end
	return copy
end

local function applyCoverageBlocking(
	coverage: { [number]: { [number]: boolean } }?,
	gridSize: Vector2,
	blockedCells: { [number]: { [number]: string } },
	blockedCellList: { { x: number, y: number, zone: string } }
)
	if not coverage then
		return
	end

	for x = 1, gridSize.X do
		local coverageColumn = coverage[x]
		for y = 1, gridSize.Y do
			local covered = coverageColumn and coverageColumn[y]
			if not covered then
				local column = blockedCells[x]
				if not column then
					column = {}
					blockedCells[x] = column
				end

				if column[y] == nil then
					local zoneId = `LockedZone_Static_{x}_{y}`
					column[y] = zoneId
					blockedCellList[#blockedCellList + 1] = { x = x, y = y, zone = zoneId }
				end
			end
		end
	end
end

local blockingConfig = config.BLOCKING or {}

local function addIdentifierToLookup(lookup, identifier)
	if typeof(identifier) == "number" then
		lookup[identifier] = true
		lookup[`LockedZone_{identifier}`] = true
	elseif typeof(identifier) == "string" then
		lookup[identifier] = true
		local numeric = identifier:match("LockedZone_(%d+)")
		if numeric then
			local numValue = tonumber(numeric)
			if numValue then
				lookup[numValue] = true
				lookup[`LockedZone_{numValue}`] = true
			end
		end
	end
end

local function buildIdentifierLookup(list)
	local lookup = {}
	if list then
		for _, identifier in list do
			addIdentifierToLookup(lookup, identifier)
		end
	end
	return lookup
end

local unlockedZoneLookup = buildIdentifierLookup(blockingConfig.UNLOCKED_ZONE_IDS)

local function buildZonesFromDescriptors(descriptors)
	if not descriptors or #descriptors == 0 then
		return nil
	end

	local sorted = table.create(#descriptors)
	for index, descriptor in descriptors do
		sorted[index] = descriptor
	end

	table.sort(sorted, function(a, b)
		local aIndex = a.zoneIndex
		local bIndex = b.zoneIndex
		if aIndex and bIndex then
			if aIndex ~= bIndex then
				return aIndex < bIndex
			end
		elseif aIndex then
			return true
		elseif bIndex then
			return false
		end

		if a.minCell.Y == b.minCell.Y then
			if a.minCell.X == b.minCell.X then
				local aName = a.part and a.part.Name or ""
				local bName = b.part and b.part.Name or ""
				return aName < bName
			end
			return a.minCell.X < b.minCell.X
		end
		return a.minCell.Y < b.minCell.Y
	end)

	local zones = table.create(#sorted)
	local used = {}
	for index, descriptor in sorted do
		local zoneNumber = descriptor.zoneIndex
		if zoneNumber and used[zoneNumber] then
			zoneNumber = nil
		end

		if not zoneNumber then
			zoneNumber = index
			while used[zoneNumber] do
				zoneNumber += 1
			end
		end

		used[zoneNumber] = true
		local zoneId = `LockedZone_{zoneNumber}`
		local unlocked = unlockedZoneLookup[zoneNumber] or unlockedZoneLookup[zoneId]
		local minCell = descriptor.minCell
		local maxCell = descriptor.maxCell
 		local markerCFrame = descriptor.part and descriptor.part.CFrame
 		local markerSize = descriptor.part and descriptor.part.Size

		zones[#zones + 1] = {
			id = zoneId,
			min = Vector2.new(minCell.X, minCell.Y),
			max = Vector2.new(maxCell.X, maxCell.Y),
			locked = not unlocked,
 			markerCFrame = markerCFrame,
 			markerSize = markerSize,
		}
	end

	return zones
end

local function generateDefaultZones()
	local zones = {}
	local enabled = blockingConfig.ENABLED ~= false
	if not enabled then
		return zones
	end

	local tileCells = blockingConfig.TILE_CELLS or Vector2.new(4, 4)
	local tileWidth = math.max(1, tileCells.X)
	local tileHeight = math.max(1, tileCells.Y)
	local defaultLocked = if blockingConfig.DEFAULT_LOCKED == nil then true else blockingConfig.DEFAULT_LOCKED
	local idCounter = 1

	for y = 1, config.GRID_CELLS.Y, tileHeight do
		for x = 1, config.GRID_CELLS.X, tileWidth do
			local minCell = Vector2.new(x, y)
			local maxCell = Vector2.new(
				math.min(x + tileWidth - 1, config.GRID_CELLS.X),
				math.min(y + tileHeight - 1, config.GRID_CELLS.Y)
			)

			zones[#zones + 1] = {
				id = `LockedZone_{idCounter}`,
				min = minCell,
				max = maxCell,
				locked = (not unlockedZoneLookup[idCounter]) and (not unlockedZoneLookup[`LockedZone_{idCounter}`]) and defaultLocked,
			}

			idCounter += 1
		end
	end

	return zones
end

local defaultZoneSet = generateDefaultZones()
local slotOverrides = blockingConfig.OVERRIDES or {}

local function getZonesForSlot(slotIndex: number)
	local override = slotOverrides[slotIndex]
	if override then
		return cloneZoneList(override)
	end
	return cloneZoneList(defaultZoneSet)
end

local Slot = {}
Slot.__index = Slot

export type PlotSlot = {
	index: number,
	ownerId: number?,
	Assign: (self: PlotSlot, ownerId: number) -> (),
	Release: (self: PlotSlot) -> (),
	GetDescription: (self: PlotSlot) -> { slot: number, origin: CFrame, cellSize: number, gridSize: Vector2 },
	GetOrigin: (self: PlotSlot) -> CFrame,
	GetGridSize: (self: PlotSlot) -> Vector2,
	GetCellSize: (self: PlotSlot) -> number,
	GetAssetsFolder: (self: PlotSlot) -> Folder,
	GetFolder: (self: PlotSlot) -> Instance,
	GetBasePart: (self: PlotSlot) -> BasePart,
	GetSpawnCFrame: (self: PlotSlot) -> CFrame?,
	GetSpawnOffset: (self: PlotSlot) -> Vector3,
	TeleportCharacter: (self: PlotSlot, character: Model) -> (),
	GetBlockedZones: (self: PlotSlot) -> { { id: string, min: Vector2, max: Vector2, locked: boolean } },
	GetBlockedCells: (self: PlotSlot) -> { [number]: { [number]: string } },
	GetBlockedCellsList: (self: PlotSlot) -> { { x: number, y: number, zone: string } },
	IsCellBlocked: (self: PlotSlot, cell: Vector2) -> boolean,
	GetBlockingZoneId: (self: PlotSlot, cell: Vector2) -> string?,
	GetBlockedZone: (self: PlotSlot, zoneId: string) -> { id: string, min: Vector2, max: Vector2, locked: boolean }?,
	GetOwnerId: (self: PlotSlot) -> number?,
}

type SlotInternal = {
	index: number,
	folder: Instance,
	assetsFolder: Folder,
	basePart: BasePart,
	spawnPart: BasePart?,
	origin: CFrame,
	gridSize: Vector2,
	cellSize: number,
	spawnOffsetDistance: number,
	ownerId: number?,
	blockedZones: { { id: string, min: Vector2, max: Vector2, locked: boolean } },
	blockedCells: { [number]: { [number]: string } },
	blockedCellList: { { x: number, y: number, zone: string } },
	zoneLookup: { [string]: { id: string, min: Vector2, max: Vector2, locked: boolean } },
}

local function validateSpawnPart(index: number, spawn: Instance?): BasePart?
	if not spawn then
		warn(`PlotSlot_{index} is missing a Spawn part; teleport will be skipped`)
		return nil
	end

	if not spawn:IsA("BasePart") then
		warn(`PlotSlot_{index} Spawn must be a BasePart`)
		return nil
	end

	return spawn
end

function Slot.new(index: number, folder: Instance): PlotSlot
	local plotParts = collectPlotParts(folder)
	local base = folder:FindFirstChild(DEFAULT_BASE_NAME)
	local baseCandidate = if base and base:IsA("BasePart") then base :: BasePart else nil

	local cellSize = Constants.CELL_SIZE
	local origin: CFrame
	local gridSize: Vector2
	local basePart: BasePart
	local zoneDescriptors
	local zoneCoverage

	if #plotParts > 0 then
		local geometry = computeCompositeGeometry(plotParts, cellSize)
		if not geometry then
			error(`PlotSlot_{index} Plots folder must contain valid BaseParts to compute the grid layout`)
		end

		origin = geometry.origin
		gridSize = geometry.gridSize
		basePart = baseCandidate or plotParts[1]
		zoneDescriptors = geometry.descriptors
		zoneCoverage = geometry.coverage
	else
		if not baseCandidate then
			error(
				`PlotSlot_{index} must contain a BasePart named "{DEFAULT_BASE_NAME}" or a Plots folder with BaseParts`
			)
		end

		basePart = baseCandidate
		origin = computeOrigin(basePart)
		gridSize = computeGridSize(basePart, cellSize)
	end

	local assetsFolder = ensureAssetsFolder(folder)
	local spawnPart = validateSpawnPart(index, folder:FindFirstChild(SPAWN_NAME))

	local expectedGrid = config.GRID_CELLS
	if expectedGrid and (expectedGrid.X ~= gridSize.X or expectedGrid.Y ~= gridSize.Y) and #plotParts == 0 then
		warn(
			`PlotSlot_{index} layout grid ({gridSize.X}x{gridSize.Y}) does not match configured size ({expectedGrid.X}x{expectedGrid.Y})`
		)
	end

	local zones = if zoneDescriptors
		then buildZonesFromDescriptors(zoneDescriptors)
		else nil

	if not zones or #zones == 0 then
		zones = getZonesForSlot(index)
	end
	local blockedCells, blockedCellList, zoneLookup = buildBlockedCellData(zones)
	applyCoverageBlocking(zoneCoverage, gridSize, blockedCells, blockedCellList)

	local slot: SlotInternal = {
		index = index,
		folder = folder,
		assetsFolder = assetsFolder,
		basePart = basePart,
		spawnPart = spawnPart,
		origin = origin,
		gridSize = gridSize,
		cellSize = cellSize,
		spawnOffsetDistance = if spawnPart
			then (spawnPart.Size.Y * 0.5) + DEFAULT_SPAWN_HEIGHT_OFFSET
			else DEFAULT_SPAWN_HEIGHT_OFFSET,
		ownerId = nil,
		blockedZones = zones,
		blockedCells = blockedCells,
		blockedCellList = blockedCellList,
		zoneLookup = zoneLookup,
	}

	return setmetatable(slot, Slot) :: any
end

function Slot:Assign(ownerId: number)
	if self.ownerId ~= ownerId then
		self.assetsFolder:ClearAllChildren()
	end
	self.ownerId = ownerId
end

function Slot:Release()
	self.ownerId = nil
	self.assetsFolder:ClearAllChildren()
end

function Slot:GetDescription()
	return {
		slot = self.index,
		origin = self.origin,
		cellSize = self.cellSize,
		gridSize = self.gridSize,
		blockedCells = self:GetBlockedCellsList(),
		blockedZones = self:GetBlockedZones(),
	}
end

function Slot:GetOrigin()
	return self.origin
end

function Slot:GetGridSize()
	return self.gridSize
end

function Slot:GetCellSize()
	return self.cellSize
end

function Slot:GetAssetsFolder()
	return self.assetsFolder
end

function Slot:GetFolder(): Instance
	return self.folder
end

function Slot:GetBasePart()
	return self.basePart
end

function Slot:GetSpawnCFrame(): CFrame?
	if self.spawnPart then
		return self.spawnPart.CFrame
	end
	return nil
end

function Slot:GetSpawnOffset(): Vector3
	if not self.spawnPart then
		return Vector3.new(0, self.spawnOffsetDistance, 0)
	end
	return self.spawnPart.CFrame.UpVector * self.spawnOffsetDistance
end

function Slot:GetBlockedZones()
	return cloneZoneList(self.blockedZones)
end

function Slot:GetBlockedCells()
	return cloneBlockedMap(self.blockedCells)
end

function Slot:GetBlockedCellsList()
	return cloneCellList(self.blockedCellList)
end

function Slot:IsCellBlocked(cell: Vector2): boolean
	local column = self.blockedCells[cell.X]
	if not column then
		return false
	end
	return column[cell.Y] ~= nil
end

function Slot:GetBlockingZoneId(cell: Vector2): string?
	local column = self.blockedCells[cell.X]
	if not column then
		return nil
	end
	return column[cell.Y]
end

function Slot:GetBlockedZone(zoneId: string)
	return self.zoneLookup[zoneId]
end

function Slot:GetOwnerId(): number?
	return self.ownerId
end

function Slot:TeleportCharacter(character: Model)
	local spawnCFrame = self:GetSpawnCFrame()
	if not spawnCFrame then
		return
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	root.CFrame = spawnCFrame + self:GetSpawnOffset()

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:ChangeState(Enum.HumanoidStateType.Landed)
	end
end

local slots: { [number]: PlotSlot } = {}
local slotOrder: { number } = {}
local ownerToSlot: { [number]: PlotSlot } = {}
local rng = Random.new()

for _, child in rootFolder:GetChildren() do
	if child:IsA("Folder") or child:IsA("Model") then
		local indexString = string.match(child.Name, "^PlotSlot_(%d+)$")
		if indexString then
			local slotIndex = tonumber(indexString)
			slots[slotIndex] = Slot.new(slotIndex, child)
			slotOrder[#slotOrder + 1] = slotIndex
		end
	end
end

table.sort(slotOrder)

if #slotOrder == 0 then
	error("PlotRegistry could not find any PlotSlot_X folders under " .. folderName)
end

local PlotRegistry = {}

function PlotRegistry.GetSlot(slotIndex: number): PlotSlot
	local slot = slots[slotIndex]
	if not slot then
		error(`PlotSlot_{slotIndex} does not exist`)
	end
	return slot
end

local function getAvailableSlots(): { PlotSlot }
	local available = {}
	for _, index in slotOrder do
		local slot = slots[index]
		if slot.ownerId == nil then
			available[#available + 1] = slot
		end
	end
	return available
end

function PlotRegistry.Assign(userId: number, preferredSlot: number?): PlotSlot?
	local existing = ownerToSlot[userId]
	if existing then
		return existing
	end

	if preferredSlot then
		local preferred = slots[preferredSlot]
		if preferred and (preferred.ownerId == nil or preferred.ownerId == userId) then
			preferred:Assign(userId)
			ownerToSlot[userId] = preferred
			return preferred
		end
	end

	local available = getAvailableSlots()
	if #available == 0 then
		return nil
	end

	local chosen = available[rng:NextInteger(1, #available)]
	chosen:Assign(userId)
	ownerToSlot[userId] = chosen
	return chosen
end

function PlotRegistry.Release(userId: number)
	local slot = ownerToSlot[userId]
	if not slot then
		return
	end

	ownerToSlot[userId] = nil
	slot:Release()
end

function PlotRegistry.GetAssigned(userId: number): PlotSlot?
	return ownerToSlot[userId]
end

function PlotRegistry.GetDescription(slot: PlotSlot)
	return slot:GetDescription()
end

function PlotRegistry.GetSlots()
	local copy = {}
	for index, slot in slots do
		copy[index] = slot
	end
	return copy
end

function PlotRegistry.ApplyUnlockList(zones, unlockList)
	if not zones or not unlockList then
		return zones
	end

	local lookup = buildIdentifierLookup(unlockList)
	if next(lookup) == nil then
		return zones
	end

	for _, zone in zones do
		local zoneId = zone.id
		local numericId = nil
		if typeof(zoneId) == "string" then
			numericId = tonumber(zoneId:match("LockedZone_(%d+)") or "")
		end

		if lookup[zoneId] or (numericId and lookup[numericId]) then
			zone.locked = false
		end
	end

	return zones
end

function PlotRegistry.BuildBlockedCellDataFromZones(zones)
	local blockedMap, blockedList, zoneLookup = buildBlockedCellData(zones)
	return blockedMap, blockedList, zoneLookup
end

function PlotRegistry.BuildUnlockLookup(list)
	return buildIdentifierLookup(list)
end

return PlotRegistry
