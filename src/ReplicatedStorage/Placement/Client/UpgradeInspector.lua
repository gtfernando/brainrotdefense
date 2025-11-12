local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local placementModule = ReplicatedStorage:WaitForChild("Placement") :: ModuleScript
local placementPackage = require(placementModule)

local controllerModule = placementModule:WaitForChild("Client"):WaitForChild("Controller") :: ModuleScript
local Controller = require(controllerModule)

local Packets = placementPackage.Packets
local upgradePacket = Packets.Upgrade
local placementUpdatePacket = Packets.Update

local BuildingsData = require(ReplicatedStorage.Data.Buildings)
local AmmoBuildingsData = require(ReplicatedStorage.Data.AmmoBuildings)

local localPlayer = Players.LocalPlayer

local PLACEMENT_FILL_COLOR = Color3.fromRGB(255, 224, 64)
local PLACEMENT_FILL_TRANSPARENCY = 0.35
local PLACEMENT_OUTLINE_COLOR = Color3.fromRGB(255, 255, 255)
local PLACEMENT_OUTLINE_TRANSPARENCY = 0.05
local RAYCAST_LENGTH = placementPackage.Constants and placementPackage.Constants.RAYCAST_LENGTH or 512
local RING_MIN_SIZE = Vector3.new(0.25, 0.05, 0.05)
local RING_MAX_SIZE = Vector3.new(0.25, 20, 20)
local RING_TRANSPARENCY = 0.7
local RING_APPEAR_TIME = 0.15
local RING_DISAPPEAR_TIME = 0.03
local RING_ROTATION = CFrame.Angles(0, 0, math.pi * 0.5)

local UpgradeInspector = {}
UpgradeInspector.__index = UpgradeInspector

local function findDescendant(root: Instance?, name: string?, className: string?): Instance?
	if not root then
		return nil
	end

	if (not name or root.Name == name) and (not className or root.ClassName == className) then
		return root
	end

	for _, descendant in root:GetDescendants() do
		if (not name or descendant.Name == name) and (not className or descendant.ClassName == className) then
			return descendant
		end
	end

	return nil
end

local function findModelBasePart(model: Model?): BasePart?
	if not model then
		return nil
	end

	local primary = model.PrimaryPart
	if primary then
		return primary
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			return descendant
		end
	end

	return nil
end

local function createRaycastParams(ignoreList: { Instance }): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreList
	params.IgnoreWater = true
	params.RespectCanCollide = false
	return params
end

local function getPlayerGui(): PlayerGui?
	if not localPlayer then
		return nil
	end

	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		return playerGui
	end

	local ok, result = pcall(function()
		return localPlayer:WaitForChild("PlayerGui", 3)
	end)
	if ok then
		return result
	end

	return nil
end

local function formatMoney(amount: number): string
	if not amount then
		return "0"
	end

	local absAmount = math.abs(amount)
	if absAmount >= 1_000_000_000 then
		return string.format("%.1fB", amount / 1_000_000_000)
	elseif absAmount >= 1_000_000 then
		return string.format("%.1fM", amount / 1_000_000)
	elseif absAmount >= 1_000 then
		return string.format("%.1fk", amount / 1_000)
	end

	if amount % 1 == 0 then
		return tostring(math.round(amount))
	end

	return string.format("%.2f", amount)
end

local function formatRate(amount: number?): string
	if not amount then
		return "0/s"
	end
	return formatMoney(amount) .. "/s"
end

local function formatStat(value: any, unit: string?): string
	if value == nil then
		return "-"
	end

	if typeof(value) == "number" then
		local display: string
		if math.abs(value) >= 1_000 then
			display = formatMoney(value)
		elseif value % 1 == 0 then
			display = tostring(math.round(value))
		else
			display = string.format("%.2f", value)
		end

		if unit and unit ~= "" then
			return display .. unit
		end

		return display
	end

	local text = tostring(value)
	if unit and unit ~= "" then
		return text .. unit
	end

	return text
end

local function normalizeLevel(value: any): number
	local numeric = tonumber(value)
	if not numeric then
		return 1
	end

	numeric = math.floor(numeric + 0.0001)
	if numeric < 1 then
		numeric = 1
	end

	return numeric
end

local function isGunAsset(assetId: string?): boolean
	if not assetId then
		return false
	end

	return AmmoBuildingsData[assetId] ~= nil
end

local function getAmmoStats(assetId: string?, level: number?): ({ [string]: any }?, { [string]: any }?)
	if not assetId or not level then
		return nil, nil
	end

	local definition = AmmoBuildingsData[assetId]
	if typeof(definition) ~= "table" then
		return nil, nil
	end

	local levels = definition.Level or definition.Levels
	if typeof(levels) ~= "table" then
		return nil, nil
	end

	local entry = levels[level]
	if typeof(entry) ~= "table" then
		return nil, nil
	end

	local stats = entry.Stats
	if typeof(stats) ~= "table" then
		stats = nil
	end

	return stats, entry
end
function UpgradeInspector:_ensureSelectionRing(): Part
 local ring = self._selectionRing
 if ring and ring.Parent then
  return ring
 end

 ring = Instance.new("Part")
 ring.Name = "UpgradeSelectionRing"
 ring.Shape = Enum.PartType.Cylinder
 ring.Anchored = true
 ring.CanCollide = false
 ring.CanTouch = false
 ring.CanQuery = false
 ring.TopSurface = Enum.SurfaceType.Smooth
 ring.BottomSurface = Enum.SurfaceType.Smooth
 ring.Material = Enum.Material.Neon
 ring.Color = PLACEMENT_FILL_COLOR
 ring.Transparency = RING_TRANSPARENCY
 ring.Size = RING_MIN_SIZE
 ring.Parent = Workspace

 self._selectionRing = ring
 return ring
end

function UpgradeInspector:_stopRingTween()
	if self._ringTweenConnection then
		self._ringTweenConnection:Disconnect()
		self._ringTweenConnection = nil
	end

	if self._ringTween then
		self._ringTween:Cancel()
		self._ringTween = nil
	end
end

function UpgradeInspector:_updateSelectionRing(model: Model)
 local ring = self:_ensureSelectionRing()
 local basePart = findModelBasePart(model)
 local boundingCFrame, boundingSize = model:GetBoundingBox()
 local baseHeight = boundingCFrame.Position.Y - (boundingSize.Y * 0.5)

 if basePart then
  local partBase = basePart.Position.Y - (basePart.Size.Y * 0.5)
  baseHeight = math.max(baseHeight, partBase)
 end

 local targetY = baseHeight + (RING_MIN_SIZE.Y * 0.5) + 0.02
 local position = Vector3.new(boundingCFrame.Position.X, targetY, boundingCFrame.Position.Z)

 ring.CFrame = CFrame.new(position) * RING_ROTATION
 ring.Parent = Workspace
end

function UpgradeInspector:_showSelectionRing(model: Model, placementId: string)
 self._ringPlacementId = placementId
 local ring = self:_ensureSelectionRing()

 self:_stopRingTween()

 ring.Size = RING_MIN_SIZE
 self:_updateSelectionRing(model)

 local tweenInfo = TweenInfo.new(RING_APPEAR_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
 self._ringTween = TweenService:Create(ring, tweenInfo, { Size = RING_MAX_SIZE })
 self._ringTween:Play()
 self._ringTweenConnection = self._ringTween.Completed:Connect(function(state)
  if state == Enum.PlaybackState.Completed then
   self._ringTween = nil
   self._ringTweenConnection = nil
  end
 end)
end

function UpgradeInspector:_hideSelectionRing()
 local ring = self._selectionRing
 if not ring then
  return
 end

 self:_stopRingTween()

 local tweenInfo = TweenInfo.new(RING_DISAPPEAR_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
 self._ringTween = TweenService:Create(ring, tweenInfo, { Size = RING_MIN_SIZE })
 self._ringTween:Play()
 self._ringTweenConnection = self._ringTween.Completed:Connect(function()
  self._ringTween = nil
  self._ringTweenConnection = nil
  if not self._hoveredPlacementId then
   ring.Parent = nil
  end
 end)
end

function UpgradeInspector:_destroySelectionRing()
 self:_stopRingTween()
 if self._selectionRing then
  self._selectionRing:Destroy()
  self._selectionRing = nil
 end
 self._ringPlacementId = nil
end

function UpgradeInspector.new(tool: Tool)
	local highlight = Instance.new("Highlight")
	highlight.Name = "PlacementUpgradeHighlight"
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = PLACEMENT_FILL_COLOR
	highlight.FillTransparency = PLACEMENT_FILL_TRANSPARENCY
	highlight.OutlineColor = PLACEMENT_OUTLINE_COLOR
	highlight.OutlineTransparency = PLACEMENT_OUTLINE_TRANSPARENCY
	highlight.Enabled = false
	highlight.Parent = tool

	local self = setmetatable({}, UpgradeInspector)

	self._tool = tool
	self._player = localPlayer
	self._highlight = highlight
	self._active = false
	self._renderConnection = nil
	self._inputConnections = {}
	self._hoveredPlacementId = nil :: string?
	self._hoveredPlacementModel = nil :: Model?
	self._hoveredAssetId = nil :: string?
	self._hoveredLevel = nil :: number?
	self._usingTouch = false
	self._pointerLocation = nil :: Vector2?
	self._uiTemplateCache = {} :: { [string]: Instance }
	self._uiInstance = nil :: Instance?
	self._uiConnections = {}
	self._uiPlacementId = nil :: string?
	self._statusLabel = nil :: TextLabel?
	self._upgradeButton = nil :: TextButton?
	self._buyButton = nil :: TextButton?
	self._currentLabel = nil :: TextLabel?
	self._nextLabel = nil :: TextLabel?
	self._currentBulletsLabel = nil :: TextLabel?
	self._nextBulletsLabel = nil :: TextLabel?
	self._currentDamageLabel = nil :: TextLabel?
	self._nextDamageLabel = nil :: TextLabel?
	self._currentHealthLabel = nil :: TextLabel?
	self._nextHealthLabel = nil :: TextLabel?
	self._currentReloadLabel = nil :: TextLabel?
	self._nextReloadLabel = nil :: TextLabel?
	self._currentCooldownLabel = nil :: TextLabel?
	self._nextCooldownLabel = nil :: TextLabel?
	self._costLabel = nil :: TextLabel?
	self._closeButton = nil :: TextButton?
	self._playerGuiMain = nil :: Instance?
	self._uiBusy = false
	self._isGunUi = false
	self._activeTemplateName = nil :: string?
	self._lastPromptProductId = nil :: number?
	self._placementUpdateConnection = placementUpdatePacket.OnClientEvent:Connect(function(updateType, payload)
		self:_handlePlacementPacket(updateType, payload)
	end)
	 self._selectionRing = nil :: Part?
	 self._ringTween = nil :: Tween?
	 self._ringTweenConnection = nil :: RBXScriptConnection?
	 self._ringPlacementId = nil :: string?

	return self
end

function UpgradeInspector:Enable()
	if self._active then
		return
	end

	self._active = true
	self:_updateInputMode(UserInputService:GetLastInputType())
	self:_connectInputs()
	self._renderConnection = RunService.RenderStepped:Connect(function()
		self:_onRenderStep()
	end)
end

function UpgradeInspector:Disable()
	if not self._active then
		return
	end

	self._active = false

	self:_disconnectRender()
	self:_disconnectInputs()
	self:_clearHover()
	self:_closeUpgradeUi()
	 self:_destroySelectionRing()
end

function UpgradeInspector:Destroy()
	self:Disable()

	if self._placementUpdateConnection then
		self._placementUpdateConnection:Disconnect()
		self._placementUpdateConnection = nil
	end

	if self._highlight then
		self._highlight:Destroy()
		self._highlight = nil
	end

	 self:_destroySelectionRing()
end

function UpgradeInspector:HandleActivation()
	if not self._hoveredPlacementId then
		return
	end

	self:_openUpgradeUi(self._hoveredPlacementId, self._hoveredPlacementModel, self._hoveredAssetId, self._hoveredLevel)
end

function UpgradeInspector:_disconnectRender()
	if self._renderConnection then
		self._renderConnection:Disconnect()
		self._renderConnection = nil
	end
end

function UpgradeInspector:_connectInputs()
	if self._inputConnections.inputBegan then
		return
	end

	self._inputConnections.inputBegan = UserInputService.InputBegan:Connect(function(input, processed)
		self:_handleInputBegan(input, processed)
	end)

	self._inputConnections.inputChanged = UserInputService.InputChanged:Connect(function(input, processed)
		self:_handleInputChanged(input, processed)
	end)

	self._inputConnections.inputEnded = UserInputService.InputEnded:Connect(function(input, processed)
		self:_handleInputEnded(input, processed)
	end)

	self._inputConnections.lastInputChanged = UserInputService.LastInputTypeChanged:Connect(function(lastInputType)
		self:_updateInputMode(lastInputType)
	end)

	if UserInputService.TouchEnabled then
		self._inputConnections.touchTap = UserInputService.TouchTapInWorld:Connect(function(position, processed)
			if processed then
				return
			end

			self:_handleTouchTap(position)
		end)
	end
end

function UpgradeInspector:_disconnectInputs()
	for key, connection in self._inputConnections do
		connection:Disconnect()
		self._inputConnections[key] = nil
	end
end

function UpgradeInspector:_handleInputBegan(input: InputObject, processed: boolean)
	self:_updateInputMode(input.UserInputType)
	if processed or UserInputService:GetFocusedTextBox() then
		return
	end

	self:_setPointerFromInput(input)
end

function UpgradeInspector:_handleInputChanged(input: InputObject, processed: boolean)
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

function UpgradeInspector:_handleInputEnded(input: InputObject, processed: boolean)
	if processed then
		return
	end

	if input.UserInputType == Enum.UserInputType.Touch then
		self:_updateInputMode(Enum.UserInputType.Touch)
	end
end

function UpgradeInspector:_handleTouchTap(worldPosition: Vector3?)
	if not self._usingTouch then
		return
	end

	local camera = Workspace.CurrentCamera
	if worldPosition and camera then
		local viewportPoint = camera:WorldToViewportPoint(worldPosition)
		self._pointerLocation = Vector2.new(viewportPoint.X, viewportPoint.Y)
	end

	self:_updateHover(true)
	self:HandleActivation()
end

function UpgradeInspector:_setPointerFromInput(input: InputObject)
	if input.UserInputType == Enum.UserInputType.Touch then
		local position = input.Position
		if position then
			self._pointerLocation = Vector2.new(position.X, position.Y)
		end
	elseif input.Position then
		self._pointerLocation = Vector2.new(input.Position.X, input.Position.Y)
	end
end

function UpgradeInspector:_updateInputMode(lastInputType: Enum.UserInputType?)
	local shouldUseTouch = false
	if UserInputService.TouchEnabled then
		if lastInputType == Enum.UserInputType.Touch then
			shouldUseTouch = true
		elseif not (UserInputService.MouseEnabled or UserInputService.KeyboardEnabled or UserInputService.GamepadEnabled) then
			shouldUseTouch = true
		end
	end

	self._usingTouch = shouldUseTouch
end

function UpgradeInspector:_getPointerLocation(): Vector2?
	if self._usingTouch then
		if self._pointerLocation then
			return self._pointerLocation
		end

		local camera = Workspace.CurrentCamera
		if camera then
			local viewportSize = camera.ViewportSize
			return Vector2.new(viewportSize.X * 0.5, viewportSize.Y * 0.5)
		end

		return nil
	end

	local mouseLocation = UserInputService:GetMouseLocation()
	if typeof(mouseLocation) == "Vector2" then
		return mouseLocation
	end

	if mouseLocation then
		return Vector2.new(mouseLocation.X or 0, mouseLocation.Y or 0)
	end

	return nil
end

function UpgradeInspector:_onRenderStep()
	if not self._active then
		return
	end

	self:_updateHover(false)
end

function UpgradeInspector:_updateHover(forceRefresh: boolean)
	local pointer = self:_getPointerLocation()
	if not pointer then
		if forceRefresh then
			self:_clearHover()
		end
		return
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		self:_clearHover()
		return
	end

	local unitRay = camera:ViewportPointToRay(pointer.X, pointer.Y)
	local ignoreList = {}
	if camera then
		ignoreList[#ignoreList + 1] = camera
	end
	if self._highlight then
		ignoreList[#ignoreList + 1] = self._highlight
	end
	if localPlayer.Character then
		ignoreList[#ignoreList + 1] = localPlayer.Character
	end

	local rayParams = createRaycastParams(ignoreList)
	local result = Workspace:Raycast(unitRay.Origin, unitRay.Direction * RAYCAST_LENGTH, rayParams)
	local placementId, model, assetId, level = self:_resolvePlacement(result and result.Instance)
	if placementId and model then
		self:_setHoverPlacement(placementId, model, assetId, level)
	else
		self:_clearHover()
	end
end

function UpgradeInspector:_resolvePlacement(instance: Instance?): (string?, Model?, string?, number?)
	if not instance then
		return nil, nil, nil, nil
	end

	local target = if instance:IsA("Model") then instance else instance:FindFirstAncestorOfClass("Model")
	if not target then
		return nil, nil, nil, nil
	end

	local placementId = target:GetAttribute("PlacementId")
	if typeof(placementId) ~= "string" then
		return nil, nil, nil, nil
	end

	local ownerId = target:GetAttribute("PlacementOwnerId")
	if typeof(ownerId) == "number" and ownerId ~= localPlayer.UserId then
		return nil, nil, nil, nil
	end

	local placements = Controller:GetPlacements()
	local entry = placements and placements[placementId]

	local assetId = entry and entry.asset or target:GetAttribute("PlacementAsset")
	local levelValue = entry and entry.level or target:GetAttribute("PlacementLevel")
	local numericLevel = tonumber(levelValue)
	if numericLevel then
		numericLevel = normalizeLevel(numericLevel)
	else
		numericLevel = nil
	end

	return placementId, target, assetId, numericLevel
end

function UpgradeInspector:_setHoverPlacement(placementId: string, model: Model, assetId: string?, level: number?)
	if typeof(placementId) ~= "string" or not model then
		self:_clearHover()
		return
	end

	local previousId = self._hoveredPlacementId
	self._hoveredPlacementId = placementId
	self._hoveredPlacementModel = model
	self._hoveredAssetId = assetId
	self._hoveredLevel = level and normalizeLevel(level) or nil

	if self._highlight then
		self._highlight.FillColor = PLACEMENT_FILL_COLOR
		self._highlight.FillTransparency = PLACEMENT_FILL_TRANSPARENCY
		self._highlight.OutlineColor = PLACEMENT_OUTLINE_COLOR
		self._highlight.OutlineTransparency = PLACEMENT_OUTLINE_TRANSPARENCY
		self._highlight.Adornee = model
		self._highlight.Enabled = true
	end

	if model:IsA("Model") then
		if not previousId or previousId ~= placementId or not self._selectionRing then
			self:_showSelectionRing(model, placementId)
		else
			self:_updateSelectionRing(model)
		end
	else
		self:_hideSelectionRing()
	end
end

function UpgradeInspector:_clearHover()
	self._hoveredPlacementId = nil
	self._hoveredPlacementModel = nil
	self._hoveredAssetId = nil
	self._hoveredLevel = nil

	if self._highlight then
		self._highlight.Adornee = nil
		self._highlight.Enabled = false
	end

	self:_hideSelectionRing()
end

function UpgradeInspector:_openUpgradeUi(placementId: string?, model: Model?, assetId: string?, level: number?)
	if not placementId then
		return
	end

	local placements = Controller:GetPlacements()
	local entry = placements and placements[placementId]
	if not entry then
		return
	end

	local resolvedAsset = assetId or entry.asset
	local resolvedLevel = normalizeLevel(level or entry.level)

	if resolvedAsset then
		self._hoveredAssetId = resolvedAsset
	end

	if not self:_ensureUpgradeUi(resolvedAsset) then
		return
	end

	self._uiPlacementId = placementId
	self:_updateUpgradeUi({
		id = placementId,
		level = resolvedLevel,
		moneyPerSecond = entry.moneyPerSecond,
		nextMoneyPerSecond = entry.nextMoneyPerSecond,
		requiredMoney = entry.requiredMoney,
		nextLevel = entry.nextLevel,
		hasNext = entry.hasNext,
	})

	if model then
		self._hoveredPlacementModel = model
	end
end

function UpgradeInspector:_handlePlacementPacket(updateType: string, payload: any)
	if updateType == "Remove" then
		local removedId = if typeof(payload) == "table" then payload.id else nil
		if removedId == self._hoveredPlacementId then
			self:_clearHover()
		end
		if removedId == self._uiPlacementId then
			self:_closeUpgradeUi()
		end
		if removedId == self._ringPlacementId then
			self:_hideSelectionRing()
		end
		return
	end

	if updateType == "LevelChanged" and typeof(payload) == "table" then
		if payload.id == self._hoveredPlacementId and payload.level ~= nil then
			self._hoveredLevel = normalizeLevel(payload.level)
		end
		if payload.id == self._uiPlacementId then
			self:_updateUpgradeUi(payload)
		end
		return
	end

	if updateType == "Add" and typeof(payload) == "table" then
		if payload.id == self._uiPlacementId then
			self:_updateUpgradeUi(payload)
		end
	end
end

function UpgradeInspector:_ensureUpgradeUi(assetId: string?): boolean
	local isGun = isGunAsset(assetId)
	local templateName = if isGun then "UpgradeGunBuildingTab" else "UpgradeTab"

	if self._uiInstance and self._uiInstance.Parent and self._activeTemplateName == templateName then
		self._isGunUi = isGun
		return true
	end

	self:_disconnectUiConnections()
	if self._uiInstance then
		self._uiInstance:Destroy()
	end
	self._uiInstance = nil
	self._currentLabel = nil
	self._nextLabel = nil
	self._currentBulletsLabel = nil
	self._nextBulletsLabel = nil
	self._currentDamageLabel = nil
	self._nextDamageLabel = nil
	self._currentHealthLabel = nil
	self._nextHealthLabel = nil
	self._currentReloadLabel = nil
	self._nextReloadLabel = nil
	self._currentCooldownLabel = nil
	self._nextCooldownLabel = nil
	self._statusLabel = nil
	self._upgradeButton = nil
	self._buyButton = nil
	self._closeButton = nil
	self._costLabel = nil

	local template = self._uiTemplateCache[templateName]
	if not template or not template.Parent then
		local designFolder = ReplicatedStorage:FindFirstChild("Design")
		if not designFolder then
			warn("ReplicatedStorage.Design no encontrado; " .. templateName .. " no disponible")
			return false
		end

		local uiFolder = designFolder:FindFirstChild("UIs")
		if not uiFolder then
			warn("ReplicatedStorage.Design.UIs no encontrado; " .. templateName .. " no disponible")
			return false
		end

		template = uiFolder:FindFirstChild(templateName)
		if not template then
			warn(`ReplicatedStorage.Design.UIs.{templateName} no disponible`)
			return false
		end

		self._uiTemplateCache[templateName] = template
	end

	local playerGui = getPlayerGui()
	if not playerGui then
		warn("PlayerGui no disponible para mostrar panel de mejora")
		return false
	end

	local main = self._playerGuiMain
	if not main or not main.Parent then
		local ok, result = pcall(function()
			return playerGui:WaitForChild("Main", 3)
		end)
		if ok then
			main = result
		else
			main = playerGui
		end
		self._playerGuiMain = main
	end

	local clone = template:Clone()
	clone.Name = if isGun then "PlacementUpgradeGunBuildingTab" else "PlacementUpgradeTab"
	clone.Parent = main

	self._uiInstance = clone
	self._activeTemplateName = templateName
	self._isGunUi = isGun

	self._statusLabel = findDescendant(clone, "Status", "TextLabel")
	self._upgradeButton = findDescendant(clone, "Upgrade", "TextButton")
	self._buyButton = findDescendant(clone, "BuyGamepass", "TextButton")
	self._closeButton = findDescendant(clone, "Close", "TextButton")
	self._costLabel = findDescendant(clone, "Cost", "TextLabel") or findDescendant(clone, "UpgradeCost", "TextLabel")

	if isGun then
		self._currentBulletsLabel = findDescendant(clone, "CurrentBullets", "TextLabel")
		self._nextBulletsLabel = findDescendant(clone, "NextBullets", "TextLabel")
		self._currentDamageLabel = findDescendant(clone, "CurrentDmg", "TextLabel")
		self._nextDamageLabel = findDescendant(clone, "NextDmg", "TextLabel")
		self._currentHealthLabel = findDescendant(clone, "CurrentHealth", "TextLabel")
		self._nextHealthLabel = findDescendant(clone, "NextHealth", "TextLabel")
		self._currentReloadLabel = findDescendant(clone, "CurrentReloadtime", "TextLabel")
		self._nextReloadLabel = findDescendant(clone, "NextReloadtime", "TextLabel")
		self._currentCooldownLabel = findDescendant(clone, "CurrentCooldown", "TextLabel")
		self._nextCooldownLabel = findDescendant(clone, "NextCooldown", "TextLabel")
		self._currentLabel = nil
		self._nextLabel = nil
	else
		self._currentLabel = findDescendant(clone, "CurrentMoneyPerSecond", "TextLabel")
		self._nextLabel = findDescendant(clone, "NextMoneyPerSecond", "TextLabel") or findDescendant(clone, "CurrentMoneyPerSecondNext", "TextLabel")
		self._currentBulletsLabel = nil
		self._nextBulletsLabel = nil
		self._currentDamageLabel = nil
		self._nextDamageLabel = nil
		self._currentHealthLabel = nil
		self._nextHealthLabel = nil
		self._currentReloadLabel = nil
		self._nextReloadLabel = nil
		self._currentCooldownLabel = nil
		self._nextCooldownLabel = nil
	end

	self:_disconnectUiConnections()

	if self._upgradeButton then
		self._uiConnections.upgrade = self._upgradeButton.Activated:Connect(function()
			self:_requestCurrencyUpgrade()
		end)
	end

	if self._buyButton then
		self._uiConnections.buy = self._buyButton.Activated:Connect(function()
			self:_requestProductUpgrade()
		end)
	end

	if self._closeButton then
		self._uiConnections.close = self._closeButton.Activated:Connect(function()
			self:_closeUpgradeUi()
		end)
	end

	return true
end

function UpgradeInspector:_disconnectUiConnections()
	for key, connection in self._uiConnections do
		connection:Disconnect()
		self._uiConnections[key] = nil
	end
end

function UpgradeInspector:_closeUpgradeUi()
	self:_disconnectUiConnections()
	if self._uiInstance then
		self._uiInstance:Destroy()
	end
	self._uiInstance = nil
	self._currentLabel = nil
	self._nextLabel = nil
	self._currentBulletsLabel = nil
	self._nextBulletsLabel = nil
	self._currentDamageLabel = nil
	self._nextDamageLabel = nil
	self._currentHealthLabel = nil
	self._nextHealthLabel = nil
	self._currentReloadLabel = nil
	self._nextReloadLabel = nil
	self._currentCooldownLabel = nil
	self._nextCooldownLabel = nil
	self._statusLabel = nil
	self._upgradeButton = nil
	self._buyButton = nil
	self._closeButton = nil
	self._costLabel = nil
	self._uiPlacementId = nil
	self._uiBusy = false
	self._isGunUi = false
	self._activeTemplateName = nil
end

function UpgradeInspector:_setStatus(message: string?, isError: boolean?)
	local label = self._statusLabel
	if not label then
		return
	end

	if not message or message == "" then
		label.Visible = false
		label.Text = ""
		return
	end

	label.Visible = true
	label.Text = message
	if isError then
		label.TextColor3 = Color3.fromRGB(255, 88, 88)
	else
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
	end
end

function UpgradeInspector:_updateUpgradeUi(payload)
	if not self._uiInstance or not self._uiPlacementId then
		return
	end

	local placements = Controller:GetPlacements()
	local entry = placements and placements[self._uiPlacementId]
	if not entry then
		return
	end

	if typeof(payload) == "table" then
		if payload.level ~= nil then
			entry.level = normalizeLevel(payload.level)
		end
		if payload.moneyPerSecond ~= nil then
			entry.moneyPerSecond = tonumber(payload.moneyPerSecond)
		end
		if payload.nextMoneyPerSecond ~= nil then
			entry.nextMoneyPerSecond = tonumber(payload.nextMoneyPerSecond)
		end
		if payload.requiredMoney ~= nil then
			entry.requiredMoney = tonumber(payload.requiredMoney)
		end
		if payload.nextLevel ~= nil then
			entry.nextLevel = normalizeLevel(payload.nextLevel)
		end
		if payload.hasNext ~= nil then
			entry.hasNext = payload.hasNext == true
		end
	end

	local assetId = entry.asset or self._hoveredAssetId
	local currentLevel = normalizeLevel(entry.level)

	if self._isGunUi then
		local currentStats, _ = getAmmoStats(assetId, currentLevel)
		local nextStats, nextEntry = getAmmoStats(assetId, currentLevel + 1)
		local hasNext = nextEntry ~= nil

		entry.hasNext = hasNext
		entry.nextLevel = hasNext and (currentLevel + 1) or nil
		entry.requiredMoney = if hasNext and nextEntry then tonumber(nextEntry.RequiredMoney) else nil

		local function applyStat(currentLabel: TextLabel?, nextLabel: TextLabel?, currentValue: any, nextValue: any, unit: string?)
			if currentLabel then
				currentLabel.Text = formatStat(currentValue, unit)
			end
			if nextLabel then
				nextLabel.Text = if hasNext then formatStat(nextValue, unit) else "MAX"
			end
		end

		applyStat(self._currentBulletsLabel, self._nextBulletsLabel, currentStats and currentStats.bullets, nextStats and nextStats.bullets, nil)
		applyStat(self._currentDamageLabel, self._nextDamageLabel, currentStats and (currentStats.dmg or currentStats.damage), nextStats and (nextStats.dmg or nextStats.damage), nil)
		applyStat(self._currentHealthLabel, self._nextHealthLabel, currentStats and currentStats.health, nextStats and nextStats.health, nil)
		applyStat(self._currentReloadLabel, self._nextReloadLabel, currentStats and (currentStats.reloadTime or currentStats.reload), nextStats and (nextStats.reloadTime or nextStats.reload), "s")
		applyStat(self._currentCooldownLabel, self._nextCooldownLabel, currentStats and currentStats.cooldown, nextStats and nextStats.cooldown, "s")

		if self._costLabel then
			local requiredMoney = if hasNext then entry.requiredMoney else nil
			self._costLabel.Text = requiredMoney and formatMoney(requiredMoney) or ""
		end

		if self._upgradeButton then
			self._upgradeButton.Active = hasNext
			self._upgradeButton.AutoButtonColor = hasNext
			self._upgradeButton.Visible = true
			self._upgradeButton.TextTransparency = hasNext and 0 or 0.4
			self._upgradeButton.BackgroundTransparency = hasNext and 0.15 or 0.35
		end

		if self._buyButton then
			local productId = self:_getProductId(assetId, currentLevel + 1)
			local active = hasNext and productId ~= nil and productId > 0
			self._buyButton.Active = active
			self._buyButton.AutoButtonColor = active
			self._buyButton.Visible = true
			self._buyButton.TextTransparency = active and 0 or 0.4
			self._buyButton.BackgroundTransparency = active and 0.15 or 0.35
		end

		self:_setStatus(nil)
		self._uiBusy = false
		return
	end

	local currentRate = tonumber(entry.moneyPerSecond)
	if not currentRate then
		currentRate = self:_computeMoneyPerSecond(assetId, currentLevel)
	end

	local nextRate = entry.nextMoneyPerSecond
	local hasNext = entry.hasNext
	if nextRate == nil or hasNext == nil then
		nextRate, entry.requiredMoney, hasNext = self:_computeNextLevelInfo(assetId, currentLevel)
		entry.hasNext = hasNext
		entry.nextLevel = hasNext and (currentLevel + 1) or nil
	end

	if hasNext == false then
		entry.requiredMoney = nil
	end

	if self._currentLabel then
		self._currentLabel.Text = formatRate(currentRate)
	end

	if self._nextLabel then
		self._nextLabel.Text = if hasNext and nextRate then formatRate(nextRate) else "MAX"
	end

	if self._costLabel then
		local requiredMoney = if hasNext then tonumber(entry.requiredMoney) else nil
		self._costLabel.Text = requiredMoney and formatMoney(requiredMoney) or ""
	end

	if self._upgradeButton then
		self._upgradeButton.Active = hasNext == true
		self._upgradeButton.AutoButtonColor = hasNext == true
		self._upgradeButton.Visible = true
		self._upgradeButton.TextTransparency = hasNext and 0 or 0.4
		self._upgradeButton.BackgroundTransparency = hasNext and 0.15 or 0.35
	end

	if self._buyButton then
		local productId = self:_getProductId(assetId, currentLevel + 1)
		local active = hasNext == true and productId ~= nil and productId > 0
		self._buyButton.Active = active
		self._buyButton.AutoButtonColor = active
		self._buyButton.Visible = true
		self._buyButton.TextTransparency = active and 0 or 0.4
		self._buyButton.BackgroundTransparency = active and 0.15 or 0.35
	end

	self:_setStatus(nil)
	self._uiBusy = false
end

function UpgradeInspector:_computeMoneyPerSecond(assetId: string?, level: number): number
	if not assetId then
		return 0
	end

	local levelsTable = self:_getLevelsTable(assetId)
	if not levelsTable then
		return 0
	end

	local levelEntry = levelsTable[level]
	if typeof(levelEntry) ~= "table" then
		return 0
	end

	local value = tonumber(levelEntry.MoneyPerSecond)
	return value or 0
end

function UpgradeInspector:_computeNextLevelInfo(assetId: string?, currentLevel: number)
	if not assetId then
		return nil, nil, false
	end

	local levelsTable = self:_getLevelsTable(assetId)
	if not levelsTable then
		return nil, nil, false
	end

	local nextLevel = currentLevel + 1
	local entry = levelsTable[nextLevel]
	if typeof(entry) ~= "table" then
		return nil, nil, false
	end

	local nextRate = tonumber(entry.MoneyPerSecond)
	local requiredMoney = tonumber(entry.RequiredMoney)

	return nextRate, requiredMoney, true
end

function UpgradeInspector:_getLevelsTable(assetId: string?)
	if not assetId then
		return nil
	end

	local definition = BuildingsData[assetId]
	if typeof(definition) == "table" then
		local buildingLevels = definition.Level or definition.Levels
		if typeof(buildingLevels) == "table" then
			return buildingLevels
		end
	end

	local ammoDefinition = AmmoBuildingsData[assetId]
	if typeof(ammoDefinition) == "table" then
		return ammoDefinition.Level or ammoDefinition.Levels
	end

	return nil
end

function UpgradeInspector:_getProductId(assetId: string?, targetLevel: number?)
	if not assetId or not targetLevel then
		return nil
	end

	local levels = self:_getLevelsTable(assetId)
	if not levels then
		return nil
	end

	local entry = levels[targetLevel]
	if typeof(entry) ~= "table" then
		return nil
	end

	local productId = tonumber(entry.RobuxPurchaseId)
	if productId and productId > 0 then
		return productId
	end

	return nil
end

function UpgradeInspector:_requestCurrencyUpgrade()
	if self._uiBusy or not self._uiPlacementId then
		return
	end

	self._uiBusy = true
	self:_setStatus("Actualizando...", false)

	local success, payload = upgradePacket:Fire(self._uiPlacementId, "Currency", nil)
	self._uiBusy = false

	if not success then
		self:_setStatus(typeof(payload) == "string" and payload or "No se pudo mejorar", true)
		return
	end

	if typeof(payload) == "table" then
		self:_updateUpgradeUi(payload)
	end

	self:_setStatus("Mejora aplicada", false)
end

function UpgradeInspector:_requestProductUpgrade()
	if self._uiBusy or not self._uiPlacementId then
		return
	end

	local placementId = self._uiPlacementId
	local placements = Controller:GetPlacements()
	local entry = placements and placements[placementId]
	if not entry then
		return
	end

	local assetId = entry.asset or self._hoveredAssetId
	local productId = self:_getProductId(assetId, normalizeLevel(entry.level) + 1)
	if not productId then
		self:_setStatus("Compra no disponible", true)
		return
	end

	self._uiBusy = true
	self:_setStatus("Procesando compra...", false)

	local success, payload = upgradePacket:Fire(placementId, "Product", {
		productId = productId,
	})

	self._uiBusy = false

	if not success then
		self:_setStatus(typeof(payload) == "string" and payload or "No se pudo iniciar la compra", true)
		return
	end

	self._lastPromptProductId = productId
	self:_setStatus("Continua la compra en la ventana emergente", false)
end

return UpgradeInspector
