local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlacementModule = ReplicatedStorage:WaitForChild("Placement") :: ModuleScript
local Placement = require(PlacementModule)
local AssetRegistry = Placement.AssetRegistry
local Grid = Placement.Grid
local Packets = Placement.Packets
local Constants = Placement.Constants

local localPlayer = Players.LocalPlayer

local Controller = {}
Controller.__index = Controller

local function getPlayerGui(): Instance?
	local existing = localPlayer:FindFirstChildOfClass("PlayerGui")
	if existing then
		return existing
	end

	local ok, result = pcall(function()
		return localPlayer:WaitForChild("PlayerGui", 5)
	end)

	if ok then
		return result
	end

	return nil
end

local placementInitPacket = Packets.Init
local placementUpdatePacket = Packets.Update
local placementRequestPacket = Packets.Request

local function toVector2(value): Vector2
	if typeof(value) == "Vector2" then
		return value
	end

	return Vector2.new(value.x or value.X, value.y or value.Y)
end

local function createRaycastParams(ignore: { Instance? }?): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter = {}
	if ignore then
		for _, instance in ignore do
			if typeof(instance) == "Instance" then
				table.insert(filter, instance)
			end
		end
	end
	params.FilterDescendantsInstances = filter
	params.RespectCanCollide = false
	return params
end

local function buildBlockedCellMap(list)
	local blocked = {}
	if not list then
		return blocked
	end

	for _, entry in list do
		local x = entry.x or entry.X
		local y = entry.y or entry.Y
		local zone = entry.zone or entry.id
		if typeof(x) == "number" and typeof(y) == "number" then
			x = math.floor(x + 0.5)
			y = math.floor(y + 0.5)

			local column = blocked[x]
			if not column then
				column = {}
				blocked[x] = column
			end
			column[y] = zone or true
		end
	end

	return blocked
end

local function buildZoneDictionary(list)
	local lookup = {}
	if not list then
		return lookup
	end

	for _, zone in list do
		if zone.id then
			lookup[zone.id] = zone
		end
	end

	return lookup
end

local function extractZoneNumber(zoneId: string?): number?
	if typeof(zoneId) ~= "string" then
		return nil
	end

	local numeric = zoneId:match("LockedZone_(%d+)")
	if not numeric then
		numeric = zoneId:match("Zone[_%-]?(%d+)")
	end
	if not numeric then
		numeric = zoneId:match("(%d+)$")
	end

	if numeric then
		local value = tonumber(numeric)
		if value then
			return value
		end
	end

	return nil
end

function Controller.new()
	local self = setmetatable({}, Controller)

	self._connections = {}
	self._plot = nil
	self._placements = {}
	self._occupied = {}
	self._currentAsset = nil
	self._currentPlacementToken = nil
	self._currentLevel = 1
	self._rotation = 0
	self._ghostModel = nil
	self._ghostParts = {}
	self._ghostHighlight = nil
	self._blockedCells = {}
	self._blockedZones = {}
	self._blockedZoneLookup = {}
	self._zoneVisuals = {}
	self._zoneVisualFolder = nil
	self._remoteZoneVisuals = {}
	self._remoteBlockedCells = {}
	self._zoneDataList = {}
	self._zoneDataById = {}
	self._currentCell = nil
	self._canPlace = false
	self._autoBind = false
	self._started = false
	self._usingTouch = false
	self._pointerLocation = nil
	self._mobileGui = nil
	self._mobileButtons = {}
	self._mobileButtonConnections = {}

	return self
end

function Controller:_shouldUseTouch(lastInputType: Enum.UserInputType?)
	if not UserInputService.TouchEnabled then
		return false
	end

	if lastInputType == Enum.UserInputType.Touch then
		return true
	end

	if UserInputService.MouseEnabled or UserInputService.KeyboardEnabled or UserInputService.GamepadEnabled then
		return false
	end

	return true
end

function Controller:_createMobileButton(name: string, labelText: string, order: number)
	local button = Instance.new("TextButton")
	button.Name = name
	button.LayoutOrder = order
	button.Size = UDim2.new(0, 170, 0, 58)
	button.BackgroundColor3 = Color3.fromRGB(38, 38, 38)
	button.BackgroundTransparency = 0.15
	button.TextColor3 = Color3.new(1, 1, 1)
	button.TextScaled = true
	button.AutoButtonColor = true
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamMedium
	button.Text = labelText
	button.Active = true

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = button

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Transparency = 0.35
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Parent = button

	return button
end

function Controller:_clearMobileButtonConnections()
	for _, connection in self._mobileButtonConnections do
		connection:Disconnect()
	end
	self._mobileButtonConnections = {}
end

function Controller:_ensureMobileUI()
	if self._mobileGui and self._mobileGui.Parent then
		return
	end

	local playerGui = getPlayerGui()
	if not playerGui then
		warn("PlacementController: Failed to locate PlayerGui for mobile controls")
		return
	end

	self:_clearMobileButtonConnections()

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "PlacementMobileControls"
	screenGui.ResetOnSpawn = false
	screenGui.Enabled = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui

	local container = Instance.new("Frame")
	container.Name = "ButtonContainer"
	container.AnchorPoint = Vector2.new(0.5, 1)
	container.Position = UDim2.new(0.5, 0, 1, -28)
	container.Size = UDim2.new(0, 364, 0, 142)
	container.BackgroundTransparency = 1
	container.Parent = screenGui

	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.new(0, 170, 0, 58)
	layout.CellPadding = UDim2.new(0, 12, 0, 12)
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.FillDirectionMaxCells = 2
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = container

	local placeButton = self:_createMobileButton("PlaceButton", "Colocar", 1)
	placeButton.Parent = container

	local cancelButton = self:_createMobileButton("CancelButton", "Cancelar", 2)
	cancelButton.Parent = container

	local rotateLeftButton = self:_createMobileButton("RotateLeftButton", "Rotar -", 3)
	rotateLeftButton.Parent = container

	local rotateRightButton = self:_createMobileButton("RotateRightButton", "Rotar +", 4)
	rotateRightButton.Parent = container

	local connections = {
		placeButton.Activated:Connect(function()
			self:_attemptPlacement()
		end),
		cancelButton.Activated:Connect(function()
			self:StopPlacement()
		end),
		rotateLeftButton.Activated:Connect(function()
			self:Rotate(-1)
		end),
		rotateRightButton.Activated:Connect(function()
			self:Rotate(1)
		end),
	}

	self._mobileButtons = {
		place = placeButton,
		cancel = cancelButton,
		rotateLeft = rotateLeftButton,
		rotateRight = rotateRightButton,
	}
	self._mobileGui = screenGui
	self._mobileButtonConnections = connections
end

function Controller:_teardownMobileUI()
	self:_clearMobileButtonConnections()
	self._mobileButtons = {}
	if self._mobileGui then
		self._mobileGui:Destroy()
		self._mobileGui = nil
	end
end

function Controller:_updateMobileUiVisibility()
	if not self._mobileGui then
		return
	end

	local shouldShow = self._usingTouch and self._currentAsset ~= nil
	self._mobileGui.Enabled = shouldShow

	local placeButton = self._mobileButtons.place
	if placeButton then
		placeButton.Active = shouldShow
	end

	local cancelButton = self._mobileButtons.cancel
	if cancelButton then
		cancelButton.Active = shouldShow
	end

	local rotateLeftButton = self._mobileButtons.rotateLeft
	if rotateLeftButton then
		rotateLeftButton.Active = shouldShow
	end

	local rotateRightButton = self._mobileButtons.rotateRight
	if rotateRightButton then
		rotateRightButton.Active = shouldShow
	end
end

function Controller:_updateMobileButtonStates()
	local placeButton = self._mobileButtons.place
	if not placeButton then
		return
	end

	local enabled = self._canPlace and self._currentCell ~= nil
	placeButton.TextTransparency = enabled and 0 or 0.4
	placeButton.BackgroundTransparency = enabled and 0.15 or 0.35
	placeButton.AutoButtonColor = enabled
	placeButton.Active = enabled
end

function Controller:_getViewportCenter(): Vector2?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end

	local size = camera.ViewportSize
	return Vector2.new(size.X * 0.5, size.Y * 0.5)
end

function Controller:_getPointerLocation(): Vector2?
	if self._usingTouch then
		return self._pointerLocation or self:_getViewportCenter()
	end

	local mouseLocation = UserInputService:GetMouseLocation()
	if typeof(mouseLocation) == "Vector2" then
		return mouseLocation
	end

	if mouseLocation then
		return Vector2.new(mouseLocation.X or 0, mouseLocation.Y or 0)
	end

	return self:_getViewportCenter()
end

function Controller:_setPointerFromInput(input: InputObject?)
	if not input then
		return
	end

	if input.UserInputType == Enum.UserInputType.Touch then
		local position = input.Position
		if position then
			self._pointerLocation = toVector2(position)
		end
	elseif input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.MouseButton2 then
		local position = input.Position
		if position then
			self._pointerLocation = toVector2(position)
		end
	end
end

function Controller:_handleInputChanged(input: InputObject, processed: boolean)
	if processed then
		return
	end

	self:_setPointerFromInput(input)
	if input.UserInputType == Enum.UserInputType.Touch then
		self:_updateInputMode(Enum.UserInputType.Touch)
	elseif input.UserInputType == Enum.UserInputType.MouseMovement then
		self:_updateInputMode(Enum.UserInputType.MouseMovement)
	end
end

function Controller:_handleInputEnded(input: InputObject, processed: boolean)
	if processed then
		return
	end

	if input.UserInputType == Enum.UserInputType.Touch then
		self:_updateInputMode(Enum.UserInputType.Touch)
	end
end

function Controller:_handleTouchTap(worldPosition: Vector3?)
	if not self._usingTouch then
		return
	end

	if worldPosition then
		local camera = Workspace.CurrentCamera
		if camera then
			local viewportPoint = camera:WorldToViewportPoint(worldPosition)
			self._pointerLocation = Vector2.new(viewportPoint.X, viewportPoint.Y)
		end
	end

	self:_updateGhostPosition()
	self:_attemptPlacement()
end

function Controller:_updateInputMode(lastInputType: Enum.UserInputType?)
	local shouldUseTouch = self:_shouldUseTouch(lastInputType)
	if shouldUseTouch then
		self._usingTouch = true
		self:_ensureMobileUI()
	else
		if self._usingTouch then
			self:_teardownMobileUI()
		end
		self._usingTouch = false
	end

	self:_updateMobileUiVisibility()
	if self._usingTouch then
		self:_updateMobileButtonStates()
	end
end

local function occupyCells(occupied: { [number]: { [number]: string } }, placementId: string, cells: { Vector2 })
	for _, cell in cells do
		local column = occupied[cell.X]
		if not column then
			column = {}
			occupied[cell.X] = column
		end
		column[cell.Y] = placementId
	end
end

local function clearCells(occupied: { [number]: { [number]: string } }, placementId: string, cells: { Vector2 })
	for _, cell in cells do
		local column = occupied[cell.X]
		if column and column[cell.Y] == placementId then
			column[cell.Y] = nil
			if next(column) == nil then
				occupied[cell.X] = nil
			end
		end
	end
end

function Controller:_resetState()
	self._placements = {}
	self._occupied = {}
	self._currentCell = nil
	self._canPlace = false
	self._currentPlacementToken = nil
	self._currentLevel = 1
	self._zoneDataList = {}
	self._zoneDataById = {}
	self:_clearZoneVisuals()
end

function Controller:_registerPlacement(data)
	local assetDefinition = AssetRegistry.Get(data.asset)
	local position = toVector2(data.position)
	local rotation = data.rotation or 0
	local orientedFootprint = Grid.getOrientedFootprint(assetDefinition.footprint, rotation)
	local cells = Grid.enumerateCells(position, orientedFootprint)
 	local level = math.max(1, tonumber(data.level) or 1)

	local entry = {
		id = data.id,
		asset = data.asset,
		position = position,
		rotation = rotation,
		cells = cells,
		level = level,
	}

	local maxHealthValue = tonumber((data :: any).maxHealth)
	if maxHealthValue then
		entry.maxHealth = math.max(0, maxHealthValue)
	end

	local healthValue = tonumber((data :: any).health)
	if healthValue then
		entry.health = math.max(0, healthValue)
	end

	self._placements[data.id] = entry
	occupyCells(self._occupied, data.id, cells)
end

function Controller:_removePlacement(id: string)
	local entry = self._placements[id]
	if not entry then
		return
	end

	self._placements[id] = nil
	clearCells(self._occupied, id, entry.cells)
end

function Controller:_handlePlacementLevelChange(payload)
	if typeof(payload) ~= "table" then
		return
	end

	local placementId = payload.id
	if typeof(placementId) ~= "string" then
		return
	end

	local entry = self._placements[placementId]
	if not entry then
		return
	end

	local newLevel = payload.level
	if newLevel ~= nil then
		local numericLevel = tonumber(newLevel)
		if numericLevel then
			entry.level = math.max(1, math.floor(numericLevel + 0.5))
		end
	end

	if payload.moneyPerSecond ~= nil then
		entry.moneyPerSecond = tonumber(payload.moneyPerSecond) or entry.moneyPerSecond
	end

	if payload.nextMoneyPerSecond ~= nil then
		entry.nextMoneyPerSecond = tonumber(payload.nextMoneyPerSecond)
	end

	if payload.requiredMoney ~= nil then
		entry.requiredMoney = tonumber(payload.requiredMoney)
	end

	if payload.nextLevel ~= nil then
		local numericNext = tonumber(payload.nextLevel)
		if numericNext then
			entry.nextLevel = math.max(1, math.floor(numericNext + 0.5))
		end
	end

	if payload.hasNext ~= nil then
		entry.hasNext = payload.hasNext == true
	end
end

function Controller:_handlePlacementHealthChange(payload)
	if typeof(payload) ~= "table" then
		return
	end

	local placementId = payload.id
	if typeof(placementId) ~= "string" then
		return
	end

	local entry = self._placements[placementId]
	if not entry then
		return
	end

	if payload.destroyed == true then
		self:_removePlacement(placementId)
		return
	end

	local maxHealthValue = tonumber(payload.maxHealth)
	if maxHealthValue then
		entry.maxHealth = math.max(0, maxHealthValue)
	end

	local remaining = tonumber(payload.remaining)
	if remaining then
		entry.health = math.max(0, remaining)
	end
end

function Controller:_setGhostModel(model: Model?)
	if self._ghostModel then
		if self._ghostHighlight then
			self._ghostHighlight:Destroy()
			self._ghostHighlight = nil
		end
		self._ghostModel:Destroy()
	end

	self._ghostModel = model
	self._ghostParts = {}
	self._ghostHighlight = nil

	if not model then
		return
	end

	local parent = Workspace.CurrentCamera or Workspace
	model.Parent = parent

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Material = Enum.Material.SmoothPlastic
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.Anchored = true
			descendant.CastShadow = false
			descendant.Transparency = 0.4
			table.insert(self._ghostParts, descendant)
		end
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "PlacementGhostHighlight"
	highlight.Adornee = model
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.OutlineTransparency = 1
	highlight.FillTransparency = 0.65
	highlight.FillColor = Color3.fromRGB(255, 88, 88)
	highlight.Parent = model
	self._ghostHighlight = highlight

	self:_updateGhostVisual()
end

function Controller:_clearZoneVisuals()
	if self._zoneVisualFolder and self._zoneVisualFolder.Parent then
		self._zoneVisualFolder:Destroy()
	end
	self._zoneVisualFolder = nil
	self._zoneVisuals = {}
end

function Controller:_getLocalPlotFolder(): Instance?
	local plot = self._plot
	local slotIndex = plot and plot.slot
	if not slotIndex then
		return nil
	end

	local config = Constants.PLOT or {}
	local folderName = config.FOLDER_NAME or "PlacementPlots"
	local root = Workspace:FindFirstChild(folderName)
	if not root then
		return nil
	end

	return root:FindFirstChild(`PlotSlot_{slotIndex}`)
end

function Controller:_getZonePart(zoneId: string): BasePart?
	local numericId = extractZoneNumber(zoneId)
	if not numericId then
		return nil
	end

	local plotFolder = self:_getLocalPlotFolder()
	if not plotFolder then
		return nil
	end

	local plotsFolder = plotFolder:FindFirstChild("Plots")
	if not plotsFolder then
		return nil
	end

	local candidates = {
		`Zone{numericId}`,
		`Zone_{numericId}`,
		`LockedZone_{numericId}`,
		zoneId,
	}

	for _, name in candidates do
		local instance = plotsFolder:FindFirstChild(name)
		if instance and instance:IsA("BasePart") then
			return instance
		end
	end

	return nil
end

function Controller:_constructZoneData(zone, origin: CFrame, cellSize: number)
	if not zone or not zone.min or not zone.max then
		return nil
	end

	local minVector = toVector2(zone.min)
	local maxVector = toVector2(zone.max)
	local data = {
		id = zone.id,
		zone = zone,
		min = minVector,
		max = maxVector,
		cells = {},
		cellLookup = {},
		minCell = nil,
		maxCell = nil,
		alignmentOffset = Vector3.zero,
	}

	local partInstance = self:_getZonePart(zone.id)
	local markerCFrame = zone.markerCFrame
	local markerSize = zone.markerSize
	local partCFrame = nil
	local partSize = nil

	if partInstance then
		partCFrame = partInstance.CFrame
		partSize = partInstance.Size
	elseif markerCFrame and markerSize then
		partCFrame = markerCFrame
		partSize = markerSize
	end

	if partCFrame and partSize then
		local halfX = partSize.X * 0.5
		local halfZ = partSize.Z * 0.5
		local widthCells = math.max(1, math.round(partSize.X / cellSize))
		local heightCells = math.max(1, math.round(partSize.Z / cellSize))
		local cells = {}
		local lookup = {}
		local minWorldX = math.huge
		local maxWorldX = -math.huge
		local minWorldZ = math.huge
		local maxWorldZ = -math.huge
		local minCellX = math.huge
		local maxCellX = -math.huge
		local minCellY = math.huge
		local maxCellY = -math.huge
		local alignmentOffset = nil

		for ix = 1, widthCells do
			for iy = 1, heightCells do
				local offsetX = -halfX + (ix - 0.5) * cellSize
				local offsetZ = -halfZ + (iy - 0.5) * cellSize
				local worldPosition = partCFrame:PointToWorldSpace(Vector3.new(offsetX, 0, offsetZ))
				if worldPosition.X < minWorldX then
					minWorldX = worldPosition.X
				end
				if worldPosition.X > maxWorldX then
					maxWorldX = worldPosition.X
				end
				if worldPosition.Z < minWorldZ then
					minWorldZ = worldPosition.Z
				end
				if worldPosition.Z > maxWorldZ then
					maxWorldZ = worldPosition.Z
				end

				local cellCoord = Grid.worldToCell(origin, cellSize, worldPosition)
				if cellCoord.X < minCellX then
					minCellX = cellCoord.X
				end
				if cellCoord.X > maxCellX then
					maxCellX = cellCoord.X
				end
				if cellCoord.Y < minCellY then
					minCellY = cellCoord.Y
				end
				if cellCoord.Y > maxCellY then
					maxCellY = cellCoord.Y
				end
				local column = lookup[cellCoord.X]
				if not column then
					column = {}
					lookup[cellCoord.X] = column
				end
				if not column[cellCoord.Y] then
					local cellCenter = Grid.cellToWorld(origin, cellSize, cellCoord).Position
					if not alignmentOffset then
						alignmentOffset = worldPosition - cellCenter
					end
					local entry = {
						cell = cellCoord,
						position = worldPosition,
						indexX = ix,
						indexY = iy,
						cellCenter = cellCenter,
					}
					column[cellCoord.Y] = entry
					cells[#cells + 1] = entry
				end
			end
		end

		local halfCell = cellSize * 0.5
		data.part = partInstance
		data.partCFrame = partCFrame
		data.partSize = partSize
		data.boundsType = "part"
		data.halfSizeX = halfX
		data.halfSizeZ = halfZ
		data.widthCells = widthCells
		data.heightCells = heightCells
		data.cells = cells
		data.cellLookup = lookup
		data.worldMinX = minWorldX - halfCell
		data.worldMaxX = maxWorldX + halfCell
		data.worldMinZ = minWorldZ - halfCell
		data.worldMaxZ = maxWorldZ + halfCell
		if minCellX ~= math.huge and minCellY ~= math.huge and maxCellX ~= -math.huge and maxCellY ~= -math.huge then
			data.minCell = Vector2.new(minCellX, minCellY)
			data.maxCell = Vector2.new(maxCellX, maxCellY)
		end
		if alignmentOffset then
			data.alignmentOffset = alignmentOffset
		end

		return data
	end

	local cells = {}
	local lookup = {}
	local halfCell = cellSize * 0.5
	local minWorldX = math.huge
	local maxWorldX = -math.huge
	local minWorldZ = math.huge
	local maxWorldZ = -math.huge
	local minCellX = minVector.X
	local maxCellX = maxVector.X
	local minCellY = minVector.Y
	local maxCellY = maxVector.Y

	for cellX = minVector.X, maxVector.X do
		local column = lookup[cellX]
		if not column then
			column = {}
			lookup[cellX] = column
		end
		for cellY = minVector.Y, maxVector.Y do
			local cellCoord = Vector2.new(cellX, cellY)
			local worldCFrame = Grid.cellToWorld(origin, cellSize, cellCoord)
			local worldPosition = worldCFrame.Position
			if worldPosition.X < minWorldX then
				minWorldX = worldPosition.X
			end
			if worldPosition.X > maxWorldX then
				maxWorldX = worldPosition.X
			end
			if worldPosition.Z < minWorldZ then
				minWorldZ = worldPosition.Z
			end
			if worldPosition.Z > maxWorldZ then
				maxWorldZ = worldPosition.Z
			end

			local entry = {
				cell = cellCoord,
				position = worldPosition,
				cellCenter = worldPosition,
			}
			column[cellY] = entry
			cells[#cells + 1] = entry
		end
	end

	data.boundsType = "grid"
	data.cells = cells
	data.cellLookup = lookup
	data.worldMinX = minWorldX - halfCell
	data.worldMaxX = maxWorldX + halfCell
	data.worldMinZ = minWorldZ - halfCell
	data.worldMaxZ = maxWorldZ + halfCell
	data.minCell = Vector2.new(minCellX, minCellY)
	data.maxCell = Vector2.new(maxCellX, maxCellY)
	data.alignmentOffset = Vector3.zero

	return data
end

function Controller:_rebuildLocalZoneData()
	local origin = self._plot and self._plot.origin
	local cellSize = self._plot and self._plot.cellSize or Constants.CELL_SIZE
	if not origin or not cellSize then
		self._zoneDataList = {}
		self._zoneDataById = {}
		return
	end

	local zones = self._blockedZones
	if not zones or #zones == 0 then
		self._zoneDataList = {}
		self._zoneDataById = {}
		return
	end

	local list = {}
	local lookup = {}
	for _, zone in zones do
		local data = self:_constructZoneData(zone, origin, cellSize)
		if data then
			list[#list + 1] = data
			lookup[zone.id] = data
		end
	end

	table.sort(list, function(a, b)
		local aUnlocked = a.zone and a.zone.locked == false
		local bUnlocked = b.zone and b.zone.locked == false
		if aUnlocked ~= bUnlocked then
			return aUnlocked
		end
		return tostring(a.id) < tostring(b.id)
	end)

	self._zoneDataList = list
	self._zoneDataById = lookup
end

function Controller:_findZoneForCell(cell: Vector2)
	for _, data in self._zoneDataList do
		local column = data.cellLookup and data.cellLookup[cell.X]
		local info = column and column[cell.Y]
		if info then
			return data
		end
		local minCell = data.minCell or data.min
		local maxCell = data.maxCell or data.max
		if minCell and maxCell then
			if cell.X >= minCell.X and cell.X <= maxCell.X and cell.Y >= minCell.Y and cell.Y <= maxCell.Y then
				return data
			end
		end
	end

	return nil
end

function Controller:_findZoneForPosition(position: Vector3)
	for _, data in self._zoneDataList do
		local zone = data.zone
		local unlocked = not zone or zone.locked == false
		if unlocked then
			if data.boundsType == "part" and data.partCFrame and data.halfSizeX and data.halfSizeZ then
				local localPoint = data.partCFrame:PointToObjectSpace(position)
				if math.abs(localPoint.X) <= data.halfSizeX and math.abs(localPoint.Z) <= data.halfSizeZ then
					return data
				end
			elseif data.worldMinX and data.worldMaxX and data.worldMinZ and data.worldMaxZ then
				if position.X >= data.worldMinX and position.X <= data.worldMaxX then
					if position.Z >= data.worldMinZ and position.Z <= data.worldMaxZ then
						return data
					end
				end
			end
		end
	end

	return nil
end

function Controller:_snapCellToZone(zoneEntry, orientedFootprint: Vector2, rotation: number, hitPosition: Vector3, heightOffset: number?): (Vector2?, Vector3?)
	if not zoneEntry then
		return nil, nil
	end

	local zone = zoneEntry.zone
	if not zone or zone.locked ~= false then
		return nil, nil
	end

	local origin = self._plot and self._plot.origin
	local cellSize = self._plot and self._plot.cellSize
	if not origin or not cellSize or cellSize <= 0 then
		return nil, nil
	end

	local zoneMax = zoneEntry.maxCell or zoneEntry.max
	local zoneMin = zoneEntry.minCell or zoneEntry.min
	if not zoneMax or not zoneMin then
		return nil
	end
	local cells = zoneEntry.cells
	local lookup = zoneEntry.cellLookup
	if not cells or not lookup or #cells == 0 then
		return nil, nil
	end

	local height = heightOffset or 0
	local bestCell: Vector2? = nil
	local bestDistance = math.huge

	local alignmentOffset = zoneEntry.alignmentOffset or Vector3.zero

	for _, baseInfo in cells do
		local baseCell = baseInfo.cell
		if baseCell and baseCell.X >= zoneMin.X and baseCell.Y >= zoneMin.Y then
			local maxCellX = baseCell.X + orientedFootprint.X - 1
			local maxCellY = baseCell.Y + orientedFootprint.Y - 1
			if maxCellX <= zoneMax.X and maxCellY <= zoneMax.Y then
				local fits = true
				if orientedFootprint.X > 1 or orientedFootprint.Y > 1 then
					for dx = 0, orientedFootprint.X - 1 do
						local column = lookup[baseCell.X + dx]
						if not column then
							fits = false
							break
						end
						for dy = 0, orientedFootprint.Y - 1 do
							local info = column[baseCell.Y + dy]
							if not info or not info.cell then
								fits = false
								break
							end
						end
						if not fits then
							break
						end
					end
				end

				if fits then
					local placementCFrame = Grid.computePlacementCFrame(origin, cellSize, baseCell, rotation, orientedFootprint, height)
					if alignmentOffset.Magnitude > 0 then
						placementCFrame = placementCFrame + alignmentOffset
					end
					local position = placementCFrame.Position
					local dx = position.X - hitPosition.X
					local dz = position.Z - hitPosition.Z
					local distance = dx * dx + dz * dz
					if distance < bestDistance then
						bestDistance = distance
						bestCell = baseCell
					end
				end
			end
		end
	end

	if bestCell then
		return bestCell, alignmentOffset
	end

	return nil, nil
end

function Controller:_clearRemoteZoneVisual(ownerId: number)
	local entry = self._remoteZoneVisuals[ownerId]
	if entry then
		local folder = entry.folder
		if folder and folder.Parent then
			folder:Destroy()
		end
		self._remoteZoneVisuals[ownerId] = nil
	end
	self._remoteBlockedCells[ownerId] = nil
end

function Controller:_clearAllRemoteZoneVisuals()
	for ownerId in self._remoteZoneVisuals do
		self:_clearRemoteZoneVisual(ownerId)
	end
end

function Controller:_renderZoneVisuals(ownerId: number, origin: CFrame, cellSize: number, blockedZones, options)
	local folder = Instance.new("Folder")
	folder.Name = `PlacementZones_{ownerId}`
	folder.Parent = Workspace

	local visuals = {}
	local color = options and options.color or Color3.fromRGB(255, 82, 82)
	local transparency = options and options.transparency or 0.75
	local material = options and options.material or Enum.Material.Neon

	for _, zone in blockedZones do
		if zone.locked ~= false then
			local markerCFrame = zone.markerCFrame
			local markerSize = zone.markerSize
			local part = Instance.new("Part")
			part.Name = zone.id or "BlockedZone"
			part.Anchored = true
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			part.Material = material
			part.Transparency = transparency
			part.Color = color

			if markerCFrame and markerSize then
				part.Size = Vector3.new(markerSize.X, markerSize.Y, markerSize.Z)
				local offset = markerSize.Y + 0.05
				part.CFrame = markerCFrame * CFrame.new(0, offset, 0)
			else
				local widthCells = zone.max.X - zone.min.X + 1
				local depthCells = zone.max.Y - zone.min.Y + 1
				local centerCell = Vector2.new(
					zone.min.X + (widthCells - 1) * 0.5,
					zone.min.Y + (depthCells - 1) * 0.5
				)
				local worldCFrame = Grid.cellToWorld(origin, cellSize, centerCell)
				part.Size = Vector3.new(widthCells * cellSize, 0.2, depthCells * cellSize)
				part.CFrame = worldCFrame * CFrame.new(0, part.Size.Y * 0.5 + 0.05, 0)
			end

			part.Parent = folder
			visuals[#visuals + 1] = part
		end
	end

	if #visuals == 0 then
		folder:Destroy()
		return nil, {}
	end

	return folder, visuals
end

function Controller:_createZoneVisuals(blockedZones, origin: CFrame?, cellSize: number?)
	self:_clearZoneVisuals()

	if not blockedZones or #blockedZones == 0 then
		return
	end

	origin = origin or (self._plot and self._plot.origin)
	cellSize = cellSize or (self._plot and self._plot.cellSize) or Constants.CELL_SIZE
	if not origin then
		return
	end

	local folder, visuals = self:_renderZoneVisuals(localPlayer.UserId, origin, cellSize, blockedZones, {
		color = Color3.fromRGB(7, 91, 18),
		transparency = 0,
		material = "SmoothPlastic"
	})

	if folder then
		self._zoneVisualFolder = folder
		self._zoneVisuals = visuals
	end
end

function Controller:_setRemoteZoneVisual(ownerId: number, payload)
	if ownerId == localPlayer.UserId then
		return
	end

	self:_clearRemoteZoneVisual(ownerId)

	local blockedZones = payload.blockedZones or {}
	local blockedCellsList = payload.blockedCells or {}
	self._remoteBlockedCells[ownerId] = buildBlockedCellMap(blockedCellsList)

	if not blockedZones or #blockedZones == 0 then
		return
	end

	local origin = payload.origin
	local cellSize = payload.cellSize or Constants.CELL_SIZE
	if not origin then
		return
	end

	local folder, visuals = self:_renderZoneVisuals(ownerId, origin, cellSize, blockedZones, {
		color = Color3.fromRGB(255, 38, 0),
		transparency = 0.85,
	})

	if folder then
		self._remoteZoneVisuals[ownerId] = {
			folder = folder,
			visuals = visuals,
		}
	end
end

function Controller:_applyZoneState(payload)
	if not payload then
		return
	end

	local ownerId = payload.ownerId
	if not ownerId then
		return
	end

	local blockedZones = payload.blockedZones or {}
	local blockedCellsList = payload.blockedCells or {}

	if ownerId == localPlayer.UserId then
		local currentOrigin = payload.origin or (self._plot and self._plot.origin)
		local currentCellSize = payload.cellSize or (self._plot and self._plot.cellSize) or Constants.CELL_SIZE

		self._blockedZones = blockedZones
		self._blockedZoneLookup = buildZoneDictionary(blockedZones)
		self._blockedCells = buildBlockedCellMap(blockedCellsList)

		self._plot = self._plot or {}
		self._plot.blockedZones = blockedZones
		self._plot.blockedCells = blockedCellsList
		if currentOrigin then
			self._plot.origin = currentOrigin
		end
		if payload.cellSize then
			self._plot.cellSize = payload.cellSize
		elseif not self._plot.cellSize then
			self._plot.cellSize = currentCellSize
		end
		if payload.gridSize then
			if typeof(payload.gridSize) == "Vector2" then
				self._plot.gridSize = payload.gridSize
			else
				local grid = payload.gridSize
				self._plot.gridSize = Vector2.new(grid.x or grid.X, grid.y or grid.Y)
			end
		end

		self:_rebuildLocalZoneData()
		self:_createZoneVisuals(blockedZones, currentOrigin, currentCellSize)
	else
		self:_setRemoteZoneVisual(ownerId, payload)
	end
end

function Controller:_handleZoneClear(payload)
	if not payload or not payload.ownerId then
		return
	end

	local ownerId = payload.ownerId
	if ownerId == localPlayer.UserId then
		self._blockedCells = {}
		self._blockedZones = {}
		self._blockedZoneLookup = {}
		self._zoneDataList = {}
		self._zoneDataById = {}
		if self._plot then
			self._plot.blockedCells = {}
			self._plot.blockedZones = {}
		end
		self:_clearZoneVisuals()
	else
		self:_clearRemoteZoneVisual(ownerId)
	end
end

function Controller:_setGhostTint(color: Color3, transparency: number)
	if self._ghostHighlight then
		self._ghostHighlight.FillColor = color
		self._ghostHighlight.FillTransparency = math.clamp(transparency + 0.2, 0, 1)
	end

	for _, part in self._ghostParts do
		part.Color = color
		part.Transparency = transparency
	end
end

function Controller:_updateGhostVisual()
	if not self._ghostModel then
		return
	end

	local color = if self._canPlace then Color3.fromRGB(96, 230, 135) else Color3.fromRGB(255, 88, 88)
	self:_setGhostTint(color, 0.4)
end

function Controller:_getBlockedZoneId(cell: Vector2)
	local blocked = self._blockedCells
	if not blocked then
		return nil
	end

	local column = blocked[cell.X]
	if not column then
		return nil
	end

	return column[cell.Y]
end

function Controller:_getBlockedZone(zoneId: string)
	return self._blockedZoneLookup[zoneId]
end

function Controller:_updateGhostPosition()
	if not self._ghostModel or not self._currentAsset or not self._plot then
		return
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	local pointerLocation = self:_getPointerLocation()
	if not pointerLocation then
		self._currentCell = nil
		self._canPlace = false
		self:_updateMobileButtonStates()
		return
	end

	local unitRay = camera:ViewportPointToRay(pointerLocation.X, pointerLocation.Y)
	local rayParams = createRaycastParams({ camera, self._ghostModel, localPlayer.Character })
	local result = Workspace:Raycast(unitRay.Origin, unitRay.Direction * Constants.RAYCAST_LENGTH, rayParams)

	local hitPosition = result and result.Position or (unitRay.Origin + unitRay.Direction * Constants.RAYCAST_LENGTH)
	local cellSize = self._plot.cellSize
	local rawCell = Grid.worldToCell(self._plot.origin, cellSize, hitPosition)
	local assetDefinition = AssetRegistry.Get(self._currentAsset)
	local orientedFootprint = Grid.getOrientedFootprint(assetDefinition.footprint, self._rotation)
	local heightOffset = assetDefinition.heightOffset
	local primary = self._ghostModel.PrimaryPart
	if primary then
		local pivotOffset = primary.PivotOffset
		local pivotOffsetY = if pivotOffset then pivotOffset.Position.Y else 0
		heightOffset = primary.Size.Y * 0.5 + pivotOffsetY
	end

	local zoneEntry = nil
	if self._zoneDataList and #self._zoneDataList > 0 then
		zoneEntry = self:_findZoneForPosition(hitPosition)
		if not zoneEntry then
			zoneEntry = self:_findZoneForCell(rawCell)
		end
	end

	local snappedCell = nil
	local alignmentOffset = Vector3.zero
	if zoneEntry then
		snappedCell, alignmentOffset = self:_snapCellToZone(zoneEntry, orientedFootprint, self._rotation, hitPosition, heightOffset)
		alignmentOffset = alignmentOffset or Vector3.zero
	end

	local canPlace = false
	local relevantCells = nil
	if snappedCell then
		relevantCells = Grid.enumerateCells(snappedCell, orientedFootprint)
		local withinBounds = Grid.isWithinBounds(self._plot.gridSize, snappedCell, orientedFootprint)
		canPlace = withinBounds

		if canPlace then
			for _, c in relevantCells do
				local column = self._occupied[c.X]
				if column and column[c.Y] then
					canPlace = false
					break
				end
			end
		end

		if canPlace then
			for _, c in relevantCells do
				if self:_getBlockedZoneId(c) then
					canPlace = false
					break
				end
			end
		end
	end

	self._currentCell = if canPlace then snappedCell else nil
	self._canPlace = canPlace

	local baseCell = snappedCell or rawCell
	local snappedCFrame = Grid.computePlacementCFrame(
		self._plot.origin,
		self._plot.cellSize,
		baseCell,
		self._rotation,
		orientedFootprint,
		heightOffset
	)

	if snappedCell and alignmentOffset.Magnitude > 0 then
		snappedCFrame = snappedCFrame + alignmentOffset
	end

	local placementCFrame = snappedCFrame
	if not snappedCell then
		local snappedPosition = snappedCFrame.Position
		local offset = Vector3.new(hitPosition.X - snappedPosition.X, 0, hitPosition.Z - snappedPosition.Z)
		placementCFrame = snappedCFrame + offset
	end

	self._ghostModel:PivotTo(placementCFrame)
	self:_updateGhostVisual()
	self:_updateMobileButtonStates()
end


function Controller:_onInit(plotData, rawObjects)
	self._plot = {
		slot = plotData.slot,
		origin = plotData.origin,
		cellSize = plotData.cellSize,
		gridSize = typeof(plotData.gridSize) == "Vector2" and plotData.gridSize
			or Vector2.new(plotData.gridSize.x or plotData.gridSize.X, plotData.gridSize.y or plotData.gridSize.Y),
	}

	self:_resetState()

	self:_applyZoneState({
		ownerId = localPlayer.UserId,
		origin = plotData.origin,
		cellSize = plotData.cellSize,
		gridSize = plotData.gridSize,
		blockedZones = plotData.blockedZones or {},
		blockedCells = plotData.blockedCells or {},
	})

	for _, placementData in rawObjects do
		self:_registerPlacement(placementData)
	end
end

function Controller:_onUpdate(updateType: string, payload)
	if updateType == "Add" then
		self:_registerPlacement(payload)
	elseif updateType == "Remove" then
		self:_removePlacement(payload.id)
	elseif updateType == "ZonesSet" then
		self:_applyZoneState(payload)
	elseif updateType == "ZonesClear" then
		self:_handleZoneClear(payload)
	elseif updateType == "LevelChanged" then
		self:_handlePlacementLevelChange(payload)
	elseif updateType == "HealthChanged" then
		self:_handlePlacementHealthChange(payload)
	end
end


function Controller:_attemptPlacement()
	if not (self._currentAsset and self._currentCell and self._canPlace) then
		return
	end

	local token = self._currentPlacementToken
	local success, payload = placementRequestPacket:Fire(self._currentAsset, self._currentCell, self._rotation, token)
	if success then
		if payload then
			self:_registerPlacement(payload)
		end

		self:StopPlacement()
	else
		local message = if typeof(payload) == "string" then payload else "Placement failed"
		warn(`{message}`)

		if message == "Herramienta no disponible" or message == "Herramienta en uso" then
			self:StopPlacement()
		end
	end
end

function Controller:_connectRender()
	self._connections[#self._connections + 1] = RunService.RenderStepped:Connect(function()
		if self._currentAsset then
			self:_updateGhostPosition()
		end
	end)
end

function Controller:_handleInputBegan(input: InputObject, processed: boolean)
	self:_updateInputMode(input.UserInputType)

	if processed or UserInputService:GetFocusedTextBox() then
		return
	end

	self:_setPointerFromInput(input)

	if input.UserInputType == Enum.UserInputType.Touch then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		self:_attemptPlacement()
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		self:Rotate(1)
	elseif input.KeyCode == Enum.KeyCode.R then
		self:Rotate(1)
	elseif input.KeyCode == Enum.KeyCode.Q then
		self:Rotate(-1)
	elseif input.KeyCode == Enum.KeyCode.Escape then
		self:StopPlacement()
	end
end

function Controller:_bindInput()
	if self._autoBind then
		return
	end

	self._autoBind = true
	self._connections[#self._connections + 1] = UserInputService.InputBegan:Connect(function(input, processed)
		self:_handleInputBegan(input, processed)
	end)

	self._connections[#self._connections + 1] = UserInputService.InputChanged:Connect(function(input, processed)
		self:_handleInputChanged(input, processed)
	end)

	self._connections[#self._connections + 1] = UserInputService.InputEnded:Connect(function(input, processed)
		self:_handleInputEnded(input, processed)
	end)

	self._connections[#self._connections + 1] = UserInputService.LastInputTypeChanged:Connect(function(lastInputType)
		self:_updateInputMode(lastInputType)
	end)

	if UserInputService.TouchEnabled then
		self._connections[#self._connections + 1] = UserInputService.TouchTapInWorld:Connect(function(position, processed, _tapCount, _target)
			if processed then
				return
			end

			self:_handleTouchTap(position)
		end)
	end

	self:_updateInputMode(UserInputService:GetLastInputType())
end

function Controller:_disconnectAll()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	self._connections = {}
end

function Controller:Start(options)
	if self._started then
		return
	end
	self._started = true

	options = options or {}

	self:_connectRender()

	self._connections[#self._connections + 1] = placementInitPacket.OnClientEvent:Connect(function(plotData, objects)
		self:_onInit(plotData, objects)
	end)

	self._connections[#self._connections + 1] = placementUpdatePacket.OnClientEvent:Connect(function(updateType, payload)
		self:_onUpdate(updateType, payload)
	end)

	if options.autoBindInput ~= false then
		self:_bindInput()
	else
		self:_updateInputMode(UserInputService:GetLastInputType())
	end

	if options.defaultAssetId then
		self:StartPlacement(options.defaultAssetId, options.defaultToken, options.defaultLevel)
	end
end

function Controller:Stop()
	self._started = false
	self:StopPlacement()
	self:_disconnectAll()
	self:_clearZoneVisuals()
	self:_clearAllRemoteZoneVisuals()
	self._remoteZoneVisuals = {}
	self._remoteBlockedCells = {}
	self:_teardownMobileUI()
	self._usingTouch = false
	self._pointerLocation = nil
end

function Controller:StartPlacement(assetId: string, token: string?, level: number?)
	local assetDefinition = AssetRegistry.Get(assetId)
	if not assetDefinition then
		error(`Unknown asset "{assetId}"`)
	end

	self._currentAsset = assetId
	self._currentPlacementToken = token
	if typeof(level) == "number" then
		self._currentLevel = math.max(1, math.floor(level + 0.5))
	else
		self._currentLevel = 1
	end
	self._rotation = 0
	self._canPlace = false
	self:_updateMobileUiVisibility()

	local ghost = AssetRegistry.Clone(assetId, self._currentLevel)
	self:_setGhostModel(ghost)
	self:_updateGhostVisual()
	self:_updateGhostPosition()
end

function Controller:StopPlacement()
	self._currentAsset = nil
	self._currentPlacementToken = nil
	self._currentLevel = 1
	self._rotation = 0
	self._currentCell = nil
	self._canPlace = false
	self:_setGhostModel(nil)
	self:_updateMobileButtonStates()
	self:_updateMobileUiVisibility()
end

function Controller:Rotate(step: number?)
	if not self._currentAsset then
		return
	end

	local amount = step or 1
	self._rotation = (self._rotation + amount) % 4
	self:_updateGhostPosition()
end

function Controller:GetPlot()
	return self._plot
end

function Controller:GetPlacements()
	return self._placements
end

function Controller:GetActiveAsset()
	return self._currentAsset
end

return Controller.new()
