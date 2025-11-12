local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local placementModule = ReplicatedStorage:WaitForChild("Placement") :: ModuleScript
local placementPackage = require(placementModule)

local controllerModule = placementModule:WaitForChild("Client"):WaitForChild("Controller") :: ModuleScript
local Controller = require(controllerModule)

local Grid = placementPackage.Grid
local Constants = placementPackage.Constants
local Packets = placementPackage.Packets

local dataFolder = ReplicatedStorage:WaitForChild("Data") :: Folder
local pricesModule = dataFolder:WaitForChild("LockedZonesPrices") :: ModuleScript
local LockedZonesPrices = require(pricesModule)

local designFolder = ReplicatedStorage:WaitForChild("Design") :: Folder
local uiFolder = designFolder:WaitForChild("UIs") :: Folder
local zoneUiTemplate = designFolder:WaitForChild("ZoneUI") :: BillboardGui
local expandConfirmationTemplate = uiFolder:WaitForChild("ExpandConfirmation")

local zonePurchasePacket = Packets.ZonePurchase
local pickupPacket = Packets.Pickup

local LOOKUP_REFRESH_INTERVAL = 0.5
local MIN_HIGHLIGHT_HEIGHT = 0.2
local RAYCAST_LENGTH = Constants and Constants.RAYCAST_LENGTH or 512

local HoverMouse = {}
HoverMouse.__index = HoverMouse

local function now()
	return Workspace:GetServerTimeNow()
end

local function formatPrice(value: number): string
	return string.format("%d", value)
end

local function buildCellZoneMap(source)
	local map = {}
	if not source then
		return map
	end

	local isList = false
	for key, value in source do
		if typeof(key) == "number" and typeof(value) == "table" and ((value.x or value.X) ~= nil) then
			isList = true
			break
		end
	end

	if not isList then
		for x, column in source do
			if typeof(x) == "number" and typeof(column) == "table" then
				local cloneColumn = {}
				for y, zoneId in column do
					cloneColumn[y] = zoneId
				end
				map[x] = cloneColumn
			end
		end
		return map
	end

	for _, entry in source do
		if typeof(entry) == "table" then
			local x = entry.x or entry.X
			local y = entry.y or entry.Y
			local zoneId = entry.zone or entry.id
			if typeof(x) == "number" and typeof(y) == "number" and typeof(zoneId) == "string" then
				x = math.floor(x + 0.5)
				y = math.floor(y + 0.5)
				local column = map[x]
				if not column then
					column = {}
					map[x] = column
				end
				column[y] = zoneId
			end
		end
	end

	return map
end

function HoverMouse.new(tool: Tool)
	local player = Players.LocalPlayer

	local highlight = Instance.new("Highlight")
	highlight.Name = "LockedZoneHoverHighlight"
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = Color3.fromRGB(255, 0, 0)
	highlight.FillTransparency = 0
	highlight.OutlineColor = Color3.fromRGB(175, 13, 13)
	highlight.OutlineTransparency = 0
	highlight.Enabled = false
	highlight.Parent = tool

	local self = setmetatable({}, HoverMouse)

	self._tool = tool
	self._player = player
	self._highlight = highlight
	self._highlightPart = nil :: BasePart?
	self._active = false
	self._renderConn = nil :: RBXScriptConnection?
	self._lookupRefreshDeadline = 0
	self._lastPrintedZoneId = nil :: string?
	self._hoveredZone = nil
	self._hoveredZoneId = nil :: string?
	self._plot = nil
	self._zoneById = {}
	self._cellZoneMap = {}
	self._zoneUiTemplate = zoneUiTemplate
	self._activeZoneUi = nil :: BillboardGui?
	self._activeZoneUiZoneId = nil :: string?
	self._confirmationTemplate = expandConfirmationTemplate
	self._zonePurchasePacket = zonePurchasePacket
	self._confirmationGui = nil
	self._confirmationZoneId = nil :: string?
	self._confirmationConnections = {}
	self._isProcessingPurchase = false
	self._playerGui = nil
	self._zoneFolderName = string.format("PlacementZones_%d", player.UserId)
	self._zoneFolder = nil :: Folder?
	self._zonePartsById = {} :: { [string]: BasePart }
	self._hoverMode = nil :: string?
	self._hoveredPlacementId = nil :: string?
	self._hoveredPlacementModel = nil :: Model?
	self._hoveredPlacementAsset = nil :: string?
	self._placementPickupPacket = pickupPacket
	self._pendingPlacementPickups = {}

	return self
end

function HoverMouse:Enable()
	if self._active then
		return
	end

	self._active = true
	self._lookupRefreshDeadline = 0

	self._renderConn = RunService.RenderStepped:Connect(function()
		self:_onRenderStep()
	end)
end

function HoverMouse:Disable()
	if not self._active then
		return
	end

	self._active = false

	if self._renderConn then
		self._renderConn:Disconnect()
		self._renderConn = nil
	end

	self:_clearHover()
	self:_cleanupConfirmation()
end

function HoverMouse:Destroy()
	self:Disable()

	if self._highlight then
		self._highlight:Destroy()
		self._highlight = nil :: Highlight?
	end

	if self._highlightPart then
		self._highlightPart:Destroy()
		self._highlightPart = nil
	end

	if self._activeZoneUi then
		self._activeZoneUi:Destroy()
		self._activeZoneUi = nil
		self._activeZoneUiZoneId = nil
	end

	self:_cleanupConfirmation()
end

function HoverMouse:HandleActivation()
	if not self._active then
		return
	end

	if self._hoveredZoneId then
		local zone = self._hoveredZone
		local price = zone and self:_getZonePrice(zone.id)
		if zone and price then
			self:_openConfirmation(zone, price)
		else
			warn("No se pudo abrir la confirmacion de compra: datos incompletos")
		end
	end
end

function HoverMouse:_onRenderStep()
	if not self._active then
		return
	end

	local nowTime = now()
	if nowTime >= self._lookupRefreshDeadline then
		self:_refreshPlotState()
		self._lookupRefreshDeadline = nowTime + LOOKUP_REFRESH_INTERVAL
	end

	self:_updateZoneFolder()
	self:_updateHoverFromMouse()
end

function HoverMouse:_refreshPlotState()
	local plot = Controller:GetPlot()
	self._plot = plot

	local zoneById = {}
	local blockedZones = {}

	if plot and plot.blockedZones then
		for _, zone in plot.blockedZones do
			if zone.id then
				zoneById[zone.id] = zone
				blockedZones[#blockedZones + 1] = zone
			end
		end
	end

	self._zoneById = zoneById
	self._cellZoneMap = buildCellZoneMap(plot and plot.blockedCells)
	self._blockedZones = blockedZones
	self:_updateZoneFolder()

	if self._hoveredZoneId and not zoneById[self._hoveredZoneId] then
		self:_clearHover()
	end
end

function HoverMouse:_updateZoneFolder()
	local current = self._zoneFolder
	if current and current.Parent == nil then
		current = nil
	end

	local candidate = Workspace:FindFirstChild(self._zoneFolderName)
	if candidate and not candidate:IsA("Folder") then
		candidate = nil
	end

	if candidate ~= current then
		self._zoneFolder = candidate
		self:_rescanZoneParts()
	end
end

function HoverMouse:_rescanZoneParts()
	local folder = self._zoneFolder
	local map = {}
	if folder then
		for _, child in folder:GetChildren() do
			if child:IsA("BasePart") then
				map[child.Name] = child
			end
		end
	end

	self._zonePartsById = map
end

function HoverMouse:_getZonePart(zoneId: string): BasePart?
	local part = self._zonePartsById[zoneId]
	if part and part.Parent then
		return part
	end

	if self._zoneFolder then
		self:_rescanZoneParts()
		part = self._zonePartsById[zoneId]
		if part and part.Parent then
			return part
		end
	end

	return nil
end

function HoverMouse:_releaseFallbackPart()
	if self._highlightPart then
		self._highlightPart.Parent = nil
	end
end

function HoverMouse:_updateHoverFromMouse()
	local plot = self._plot
	if not plot or not plot.origin or not plot.cellSize or not plot.gridSize then
		self:_clearHover()
		return
	end

	local cell = self:_getMouseCell(plot)
	if not cell then
		self:_clearHover()
		return
	end

	local zone = self:_findZoneAtCell(cell)
	if zone then
		self:_setHoverZone(zone)
	else
		self:_clearHover()
	end
end

function HoverMouse:_getMouseCell(plot)
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end

	local mousePosition = UserInputService:GetMouseLocation()
	local unitRay = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y)

	local ignoreList = { camera }
	local character = self._player.Character
	if character then
		ignoreList[#ignoreList + 1] = character
	end
	if self._highlightPart then
		ignoreList[#ignoreList + 1] = self._highlightPart
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreList
	params.RespectCanCollide = false

	local result = Workspace:Raycast(unitRay.Origin, unitRay.Direction * RAYCAST_LENGTH, params)
	local hitPosition = result and result.Position or (unitRay.Origin + unitRay.Direction * RAYCAST_LENGTH)
	local cell = Grid.worldToCell(plot.origin, plot.cellSize, hitPosition)

	if not Grid.isWithinBounds(plot.gridSize, cell, Vector2.new(1, 1)) then
		return nil
	end

	return cell
end

function HoverMouse:_findZoneAtCell(cell: Vector2)
	local column = self._cellZoneMap[cell.X]
	if not column then
		return nil
	end

	local zoneId = column[cell.Y]
	if not zoneId then
		return nil
	end

	local zone = self._zoneById[zoneId]
	if zone and zone.locked ~= false then
		return zone
	end

	return nil
end

function HoverMouse:_setHoverZone(zone)
	if not zone or not zone.id then
		self:_clearHover()
		return
	end

	self._hoveredZone = zone
	if self._hoveredZoneId ~= zone.id then
		self._hoveredZoneId = zone.id
	end

	self:_applyZoneHighlight(zone)
end

function HoverMouse:_applyZoneHighlight(zone)
	local plot = self._plot
	if not plot then
		return
	end

	local targetPart = self:_getZonePart(zone.id)
	local price = self:_getZonePrice(zone.id)

	if targetPart then
		self._highlight.Adornee = targetPart
		self._highlight.Enabled = true
		self:_releaseFallbackPart()
		self:_updateZoneUiDisplay(targetPart, zone.id, price)
		return
	end

	local fallbackPart = self:_ensureHighlightPart()
	local cellSize = plot.cellSize
	local widthCells = zone.max.X - zone.min.X + 1
	local depthCells = zone.max.Y - zone.min.Y + 1
	local height = math.max(cellSize * 0.1, MIN_HIGHLIGHT_HEIGHT)

	fallbackPart.Size = Vector3.new(widthCells * cellSize, height, depthCells * cellSize)

	local centerCell = Vector2.new(
		zone.min.X + (widthCells - 1) * 0.5,
		zone.min.Y + (depthCells - 1) * 0.5
	)

	local worldCFrame = Grid.cellToWorld(plot.origin, cellSize, centerCell)
	fallbackPart.CFrame = worldCFrame * CFrame.new(0, height * 0.5, 0)

	self._highlight.Adornee = fallbackPart
	self._highlight.Enabled = true
	self:_updateZoneUiDisplay(fallbackPart, zone.id, price)
end

function HoverMouse:_ensureHighlightPart()
	local part = self._highlightPart
	if not part then
		part = Instance.new("Part")
		part.Name = "LockedZoneHoverPart"
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.Transparency = 1
		self._highlightPart = part
	end

	if part.Parent ~= Workspace then
		part.Parent = Workspace
	end

	return part
end

function HoverMouse:_clearHover()
	self._hoveredZone = nil
	self._hoveredZoneId = nil
	self._lastPrintedZoneId = nil
	self._highlight.Adornee = nil
	self._highlight.Enabled = false

	if self._activeZoneUi then
		self._activeZoneUi:Destroy()
		self._activeZoneUi = nil
		self._activeZoneUiZoneId = nil
	end

	self:_releaseFallbackPart()
end

function HoverMouse:_getZonePrice(zoneId: string)
	return LockedZonesPrices[zoneId]
end

function HoverMouse:_updateZoneUiDisplay(part: BasePart?, zoneId: string, price: number?)
	if not part or not price then
		if self._activeZoneUi then
			self._activeZoneUi:Destroy()
			self._activeZoneUi = nil
			self._activeZoneUiZoneId = nil
		end
		return
	end

	local template = self._zoneUiTemplate
	if not template then
		return
	end

	if self._activeZoneUi and self._activeZoneUi.Parent == part and self._activeZoneUiZoneId == zoneId then
		self:_setZoneUiPrice(self._activeZoneUi, price)
		return
	end

	if self._activeZoneUi then
		self._activeZoneUi:Destroy()
		self._activeZoneUi = nil
		self._activeZoneUiZoneId = nil
	end

	local billboard = template:Clone()
	billboard.Name = "ZoneUI"
	billboard.Enabled = true
	billboard.Adornee = part
	billboard.Parent = part

	self:_setZoneUiPrice(billboard, price)

	self._activeZoneUi = billboard
	self._activeZoneUiZoneId = zoneId
end

function HoverMouse:_setZoneUiPrice(billboard: BillboardGui, price: number)
	local formatted = formatPrice(price)
	local costObject = billboard:FindFirstChild("Cost")
	if not costObject then
		return
	end

	if costObject:IsA("TextLabel") then
		costObject.Text = formatted
		return
	end

	local textChild = costObject:FindFirstChild("Text")
	if textChild and textChild:IsA("TextLabel") then
		textChild.Text = formatted
	end
end

function HoverMouse:_openConfirmation(zone, price: number)
	local template = self._confirmationTemplate
	if not template then
		warn("ExpandConfirmation template missing")
		return
	end

	local parent = self:_resolveConfirmationParent()
	if not parent then
		warn("No se encontro PlayerGui.Main para mostrar la confirmacion")
		return
	end

	if self._confirmationGui and self._confirmationGui.Parent and self._confirmationZoneId == zone.id then
		self._isProcessingPurchase = false
		self:_setConfirmationInfo(zone.id, price)
		self:_setConfirmationInteractable(true)
		return
	end

	self:_cleanupConfirmation()

	local gui = template:Clone()
	gui.Visible = true
	gui.Parent = parent

	self._confirmationGui = gui
	self._confirmationZoneId = zone.id
	self._isProcessingPurchase = false

	self:_setConfirmationInfo(zone.id, price)
	self:_bindConfirmationButtons(gui)
	self:_setConfirmationInteractable(true)
end

function HoverMouse:_resolveConfirmationParent()
	local playerGui = self._playerGui
	if not playerGui or not playerGui.Parent then
		playerGui = self._player:FindFirstChildOfClass("PlayerGui")
		if not playerGui then
			local ok, result = pcall(function()
				return self._player:WaitForChild("PlayerGui", 5)
			end)
			if ok then
				playerGui = result
			end
		end
		self._playerGui = playerGui
	end

	if not playerGui then
		return nil
	end

	local main = playerGui:FindFirstChild("Main")
	if main and (main:IsA("LayerCollector") or main:IsA("GuiObject")) then
		return main
	end

	return playerGui
end

function HoverMouse:_setConfirmationInfo(zoneId: string, price: number)
	local gui = self._confirmationGui
	if not gui then
		return
	end

	local formattedPrice = formatPrice(price)
	local costRoot = self:_findDescendant(gui, "Cost")
	if costRoot then
		if costRoot:IsA("TextLabel") then
			costRoot.Text = formattedPrice
		else
			local label = costRoot:FindFirstChildWhichIsA("TextLabel", true)
			if label then
				label.Text = formattedPrice
			end
		end
	end

	local zoneLabel = self:_findDescendant(gui, "Zone", "TextLabel")
	if zoneLabel then
		zoneLabel.Text = zoneId
	end

	local zoneIdLabel = self:_findDescendant(gui, "ZoneId", "TextLabel")
	if zoneIdLabel then
		zoneIdLabel.Text = zoneId
	end
end

function HoverMouse:_bindConfirmationButtons(gui: Instance)
	self._confirmationConnections = {}

	local yesButton = self:_findDescendant(gui, "Yes", "GuiButton")
	if yesButton and yesButton:IsA("GuiButton") then
		self._confirmationConnections[#self._confirmationConnections + 1] = yesButton.MouseButton1Click:Connect(function()
			self:_onConfirmationYes()
		end)
	end

	local noButton = self:_findDescendant(gui, "No", "GuiButton")
	if noButton and noButton:IsA("GuiButton") then
		self._confirmationConnections[#self._confirmationConnections + 1] = noButton.MouseButton1Click:Connect(function()
			self:_onConfirmationNo()
		end)
	end
end

function HoverMouse:_setConfirmationInteractable(enabled: boolean)
	local gui = self._confirmationGui
	if not gui then
		return
	end

	for _, name in { "Yes", "No" } do
		local button = self:_findDescendant(gui, name, "GuiButton")
		if button and button:IsA("GuiButton") then
			button.Active = enabled
			if button:IsA("TextButton") or button:IsA("ImageButton") then
				button.AutoButtonColor = enabled
			end
		end
	end
end

function HoverMouse:_onConfirmationYes()
	if self._isProcessingPurchase then
		return
	end

	local zoneId = self._confirmationZoneId
	if not zoneId then
		self:_cleanupConfirmation()
		return
	end

	self._isProcessingPurchase = true
	self:_setConfirmationInteractable(false)

	task.spawn(function()
		local success, _, message = self:_invokeZonePurchase(zoneId)
		if success then
			if self._confirmationZoneId == zoneId then
				self:_cleanupConfirmation()
			end
		else
			if self._confirmationZoneId == zoneId then
				self._isProcessingPurchase = false
				self:_setConfirmationInteractable(true)
			end
			if message then
				warn(message)
			end
		end
	end)
end

function HoverMouse:_onConfirmationNo()
	self:_cleanupConfirmation()
end

function HoverMouse:_invokeZonePurchase(zoneId: string)
	local packet = self._zonePurchasePacket
	if not packet then
		return false, nil, "Remote de compra no disponible"
	end

	local ok, success, payload = pcall(function()
		return packet:Fire(zoneId)
	end)

	if not ok then
		return false, nil, success
	end

	if success then
		return true, payload
	end

	return false, nil, payload
end

function HoverMouse:_cleanupConfirmation()
	for _, connection in self._confirmationConnections do
		connection:Disconnect()
	end
	self._confirmationConnections = {}

	if self._confirmationGui then
		self._confirmationGui:Destroy()
		self._confirmationGui = nil
	end

	self._confirmationZoneId = nil
	self._isProcessingPurchase = false
end

function HoverMouse:_findDescendant(root: Instance?, name: string, className: string?)
	if not root then
		return nil
	end

	local descendant = root:FindFirstChild(name, true)
	if not descendant then
		return nil
	end

	if className then
		if descendant:IsA(className) then
			return descendant
		end
		return nil
	end

	return descendant
end

return HoverMouse
