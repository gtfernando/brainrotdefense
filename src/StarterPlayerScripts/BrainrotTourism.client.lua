--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local TourismPackets = require(ReplicatedStorage.Network.BrainrotTourismPackets)
local BrainrotData = require(ReplicatedStorage.Data.Brainrots)

local AssetsFolder = ReplicatedStorage:WaitForChild("Assets")
local BrainrotAssetsFolder = AssetsFolder:WaitForChild("Brainrots")
local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local DEFAULT_MOVE_SPEED = 14
local DEFAULT_ARRIVAL_TOLERANCE = 0.2
local DEFAULT_MAX_HEALTH = 1600
local HEALTH_BAR_SIZE = UDim2.new(0, 160, 0, 48)
local HEALTH_BAR_OFFSET = Vector3.new(0, 7, 0)

export type AnimationHandle = {
	animation: Animation,
	track: AnimationTrack,
}

export type AgentState = "toBuilding" | "hidden" | "toSpawn"

type HealthUiHandle = {
	billboard: BillboardGui,
	label: TextLabel,
	fill: Frame,
}

export type ClientAgent = {
	id: string,
	model: Model,
	primary: BasePart,
	animationHandle: AnimationHandle?,
	state: AgentState,
	path: { Vector3 },
	pathIndex: number,
	position: Vector3,
	moveSpeed: number,
	arrivalTolerance: number,
	faceAdjustment: CFrame?,
	buildingPosition: Vector3?,
	visitPosition: Vector3?,
	brainrotName: string,
	spawnCFrame: CFrame,
	health: number?,
	maxHealth: number?,
	healthUi: HealthUiHandle?,
}

local visitorsRoot: Folder? = nil
local brainrotAssets: { [string]: Model } = {}
local faceAdjustmentCache: { [string]: CFrame? } = {}
local agents: { [string ]: ClientAgent } = {}
local defeatAnnouncements: { [number]: boolean } = {}
local difficultyUi: {
	gui: ScreenGui,
	valueLabel: TextLabel,
	fill: Frame,
}? = nil
local currentDifficultyPercent = 0
local difficultyPercentCap = 1000

local function ensureVisitorsRoot(): Folder
	if visitorsRoot and visitorsRoot.Parent then
		return visitorsRoot
	end

	local folder = Instance.new("Folder")
	folder.Name = "BrainrotVisitors"
	folder.Parent = Workspace
	visitorsRoot = folder
	return folder
end

local function gatherBrainrotAssets()
	for _, child in BrainrotAssetsFolder:GetChildren() do
		if child:IsA("Model") then
			brainrotAssets[child.Name] = child
		end
	end
end

gatherBrainrotAssets()

local function createRoundedFrame(parent: Instance, size: UDim2, position: UDim2, bgColor: Color3, transparency: number?): Frame
	local frame = Instance.new("Frame")
	frame.Size = size
	frame.Position = position
	frame.BackgroundColor3 = bgColor
	frame.BackgroundTransparency = transparency or 0
	frame.BorderSizePixel = 0
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	return frame
end

local function ensureDifficultyUi()
	if difficultyUi and difficultyUi.gui.Parent then
		return difficultyUi
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "BrainrotDifficultyTestHud"
	gui.DisplayOrder = 5000
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	local container = createRoundedFrame(gui, UDim2.new(0, 240, 0, 64), UDim2.new(1, -16, 0.5, 0), Color3.fromRGB(16, 16, 20), 0.25)
	container.AnchorPoint = Vector2.new(1, 0.5)
	container.Active = false

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, -16, 0, 22)
	title.Position = UDim2.new(0, 8, 0, 6)
	title.BackgroundTransparency = 1
	title.Text = "Brainrot Difficulty"
	title.TextColor3 = Color3.fromRGB(230, 230, 235)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 18
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = container

	local barBg = createRoundedFrame(container, UDim2.new(1, -16, 0, 14), UDim2.new(0, 8, 0, 32), Color3.fromRGB(36, 36, 46), 0.1)

	local fill = createRoundedFrame(barBg, UDim2.new(0, 0, 1, 0), UDim2.new(0, 0, 0, 0), Color3.fromRGB(85, 170, 255), 0)
	fill.ZIndex = 2

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Name = "Value"
	valueLabel.Size = UDim2.new(1, -16, 0, 16)
	valueLabel.Position = UDim2.new(0, 8, 0, 46)
	valueLabel.BackgroundTransparency = 1
	valueLabel.Text = "0%"
	valueLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
	valueLabel.Font = Enum.Font.Gotham
	valueLabel.TextSize = 16
	valueLabel.TextXAlignment = Enum.TextXAlignment.Left
	valueLabel.Parent = container

	local handle = {
		gui = gui,
		valueLabel = valueLabel,
		fill = fill,
	}
	difficultyUi = handle
	return handle
end

local function updateDifficultyUi(percent: number?, cap: number?)
	local handle = ensureDifficultyUi()
	if cap and cap > 0 then
		difficultyPercentCap = cap
	end
	if percent then
		currentDifficultyPercent = math.clamp(percent, 0, difficultyPercentCap)
	end

	local ratio = if difficultyPercentCap > 0 then currentDifficultyPercent / difficultyPercentCap else 0
	handle.fill.Size = UDim2.new(math.clamp(ratio, 0, 1), 0, 1, 0)
	handle.valueLabel.Text = string.format("%d%% / %d%%", math.floor(currentDifficultyPercent + 0.5), difficultyPercentCap)
	handle.gui.Enabled = true
end

updateDifficultyUi(0, difficultyPercentCap)

local function handleDifficultyUpdate(percent: number?, cap: number?)
	updateDifficultyUi(percent, cap)
end

local function ensurePrimaryPart(model: Model): BasePart?
	if model.PrimaryPart then
		return model.PrimaryPart
	end

	local primary = model:FindFirstChildWhichIsA("BasePart", true)
	if primary then
		model.PrimaryPart = primary
	end

	return primary
end

local function setAnchored(model: Model, anchored: boolean)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = anchored
			descendant.CanCollide = false
			descendant.Massless = true
		end
	end
end

local function ensureHealthUi(agent: ClientAgent): HealthUiHandle?
	local model = agent.model
	local primary = agent.primary
	if not model or not primary then
		return nil
	end

	local existing = agent.healthUi
	if existing and existing.billboard.Parent then
		if existing.billboard.Adornee ~= primary then
			existing.billboard.Adornee = primary
		end
		existing.billboard.Enabled = agent.state ~= "hidden"
		return existing
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "BrainrotHealth"
	billboard.Size = HEALTH_BAR_SIZE
	billboard.StudsOffset = HEALTH_BAR_OFFSET
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 400
	billboard.Adornee = primary
	billboard.Enabled = agent.state ~= "hidden"
	billboard.Parent = model

	local frame = Instance.new("Frame")
	frame.Name = "Container"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Parent = billboard

	local label = Instance.new("TextLabel")
	label.Name = "HealthLabel"
	label.Size = UDim2.new(1, -12, 0, 18)
	label.Position = UDim2.new(0, 6, 0, 4)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 16
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = ""
	label.Parent = frame

	local barBg = Instance.new("Frame")
	barBg.Name = "HealthBar"
	barBg.Size = UDim2.new(1, -12, 0, 12)
	barBg.Position = UDim2.new(0, 6, 0, 26)
	barBg.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
	barBg.BorderSizePixel = 0
	barBg.Parent = frame

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(60, 200, 80)
	fill.BorderSizePixel = 0
	fill.Parent = barBg

	local handle: HealthUiHandle = {
		billboard = billboard,
		label = label,
		fill = fill,
	}

	agent.healthUi = handle
	return handle
end

local function updateHealthUi(agent: ClientAgent)
	local handle = ensureHealthUi(agent)
	if not handle then
		return
	end

	local maxHealth = math.max(agent.maxHealth or DEFAULT_MAX_HEALTH, 1)
	local health = math.clamp(agent.health or maxHealth, 0, maxHealth)
	handle.billboard.Enabled = agent.state ~= "hidden"

	local ratio = math.clamp(health / maxHealth, 0, 1)
	handle.fill.Size = UDim2.new(ratio, 0, 1, 0)
	if ratio <= 0.15 then
		handle.fill.BackgroundColor3 = Color3.fromRGB(220, 70, 60)
	elseif ratio <= 0.45 then
		handle.fill.BackgroundColor3 = Color3.fromRGB(235, 170, 60)
	else
		handle.fill.BackgroundColor3 = Color3.fromRGB(60, 200, 80)
	end

	handle.label.Text = string.format("%d / %d", math.floor(health + 0.5), math.floor(maxHealth + 0.5))
end

local function setAgentHealth(agent: ClientAgent, healthValue: number?, maxHealthValue: number?)
	if maxHealthValue ~= nil then
		agent.maxHealth = math.max(1, maxHealthValue)
	elseif not agent.maxHealth or agent.maxHealth <= 0 then
		agent.maxHealth = DEFAULT_MAX_HEALTH
	end

	local maxHealth = agent.maxHealth or DEFAULT_MAX_HEALTH
	if healthValue ~= nil then
		agent.health = math.clamp(healthValue, 0, maxHealth)
	elseif agent.health == nil then
		agent.health = maxHealth
	end

	updateHealthUi(agent)
end

local function computeFaceRotationAdjustment(model: Model, primary: BasePart): CFrame?
	local facePart = model:FindFirstChild("Face", true)
	if not facePart or not facePart:IsA("BasePart") then
		return nil
	end

	local faceRelative = primary.CFrame:ToObjectSpace((facePart :: BasePart).CFrame)
	local rotationOnly = CFrame.fromMatrix(Vector3.zero, faceRelative.RightVector, faceRelative.UpVector, faceRelative.LookVector)
	return rotationOnly:Inverse()
end

local function resolveAnimationId(brainrotName: string): string?
	local data = BrainrotData[brainrotName]
	if typeof(data) ~= "table" then
		return nil
	end

	local animationId = data.animationId or data.AnimationId
	if animationId == nil or animationId == 0 then
		return nil
	end

	if typeof(animationId) == "number" then
		if animationId == 0 then
			return nil
		end
		return "rbxassetid://" .. tostring(animationId)
	elseif typeof(animationId) == "string" then
		if animationId == "" or animationId == "0" then
			return nil
		end
		if animationId:match("^rbxassetid://") then
			return animationId
		end
		return "rbxassetid://" .. animationId
	end

	return nil
end

local function loadAnimation(model: Model, brainrotName: string): AnimationHandle?
	local animationId = resolveAnimationId(brainrotName)
	if not animationId then
		return nil
	end

	local controller = model:FindFirstChildWhichIsA("AnimationController")
	if not controller then
		return nil
	end

	local animator = controller:FindFirstChildWhichIsA("Animator")
	if not animator then
		local newAnimator = Instance.new("Animator")
		newAnimator.Parent = controller
		animator = newAnimator
	end

	local animation = Instance.new("Animation")
	animation.Name = brainrotName .. "_BrainrotAnimation"
	animation.AnimationId = animationId
	animation.Parent = model

	local track = (animator :: Animator):LoadAnimation(animation)
	track.Looped = true
	track:Play()

	return {
		animation = animation,
		track = track,
	}
end

local function pivotModel(model: Model, position: Vector3, direction: Vector3?, rotationAdjustment: CFrame?)
	local forward = if direction and direction.Magnitude > 0 then direction.Unit else Vector3.new(0, 0, -1)
	local pivot = CFrame.lookAt(position, position + forward)
	if rotationAdjustment then
		pivot *= rotationAdjustment
	end
	model:PivotTo(pivot)
end

local function cleanupAnimation(handle: AnimationHandle?)
	if not handle then
		return
	end

	if handle.track then
		handle.track:Stop()
	end
	if handle.animation then
		handle.animation:Destroy()
	end
end

local function destroyAgent(agent: ClientAgent)
	cleanupAnimation(agent.animationHandle)
	if agent.model then
		agent.model:Destroy()
	end
	agent.healthUi = nil
	agents[agent.id] = nil
end

local function announceDefeat(plotIndex: number?, message: string)
	if plotIndex and defeatAnnouncements[plotIndex] then
		return
	end

	if plotIndex then
		defeatAnnouncements[plotIndex] = true
	end

	local announcement = message
	if announcement == "" then
		return
	end

	task.defer(function()
		local notified = pcall(function()
			StarterGui:SetCore("SendNotification", {
				Title = "Derrota",
				Text = announcement,
				Duration = 6,
			})
		end)

		if not notified then
			pcall(function()
				StarterGui:SetCore("ChatMakeSystemMessage", {
					Text = announcement,
					Color = Color3.fromRGB(255, 80, 80),
				})
			end)
		end
	end)
end

local function applyTransform(agent: ClientAgent)
	if agent.state == "hidden" then
		if agent.model.Parent then
			agent.model.Parent = nil
		end
		if agent.healthUi then
			agent.healthUi.billboard.Enabled = false
		end
		return
	end

	agent.model.Parent = ensureVisitorsRoot()
	local targetDirection: Vector3? = nil
	if agent.path and agent.path[agent.pathIndex] then
		targetDirection = agent.path[agent.pathIndex] - agent.position
	elseif agent.state == "toBuilding" and agent.buildingPosition then
		targetDirection = agent.buildingPosition - agent.position
	end
	pivotModel(agent.model, agent.position, targetDirection, agent.faceAdjustment)

	if agent.healthUi then
		agent.healthUi.billboard.Enabled = true
	end
end

local function updateAgentState(agent: ClientAgent, data: any)
	agent.state = (data.state :: AgentState) or agent.state
	agent.path = data.path or agent.path or {}
	local pathLength = #agent.path
	if pathLength > 0 then
		agent.pathIndex = math.clamp(data.pathIndex or agent.pathIndex or 1, 1, pathLength)
	else
		agent.pathIndex = 1
	end
	agent.position = data.position or agent.position
	agent.moveSpeed = data.moveSpeed or agent.moveSpeed or DEFAULT_MOVE_SPEED
	agent.arrivalTolerance = data.arrivalTolerance or agent.arrivalTolerance or DEFAULT_ARRIVAL_TOLERANCE
	agent.buildingPosition = data.buildingPosition or agent.buildingPosition
	agent.visitPosition = data.visitPosition or agent.visitPosition

	if data.faceAdjustment then
		agent.faceAdjustment = data.faceAdjustment
	end
	if data.spawnCFrame then
		agent.spawnCFrame = data.spawnCFrame
	end

	local healthValue = tonumber((data :: any).health)
	local maxHealthValue = tonumber((data :: any).maxHealth)
	setAgentHealth(agent, healthValue, maxHealthValue)

	applyTransform(agent)
end

local function createAgent(data: any): ClientAgent?
	local template = brainrotAssets[data.brainrotName]
	if not template then
		return nil
	end

	local model = template:Clone()
	model.Name = template.Name
	model:SetAttribute("BrainrotAgentId", data.id)
	setAnchored(model, true)
	model.Parent = ensureVisitorsRoot()

	local primary = ensurePrimaryPart(model)
	if not primary then
		model:Destroy()
		return nil
	end

	local adjustment = data.faceAdjustment
	if not adjustment then
		adjustment = faceAdjustmentCache[template.Name]
		if adjustment == nil then
			adjustment = computeFaceRotationAdjustment(model, primary)
			faceAdjustmentCache[template.Name] = adjustment
		end
	end

	local spawnCFrame = data.spawnCFrame or CFrame.new(data.position or primary.Position)
	if adjustment then
		model:PivotTo(spawnCFrame * adjustment)
	else
		model:PivotTo(spawnCFrame)
	end

	local animationHandle = loadAnimation(model, template.Name)

	local path = data.path or {}
	local pathLength = #path
	local initialIndex = data.pathIndex or 1
	if pathLength > 0 then
		initialIndex = math.clamp(initialIndex, 1, pathLength)
	else
		initialIndex = 1
	end

	local agent: ClientAgent = {
		id = data.id,
		model = model,
		primary = primary,
		animationHandle = animationHandle,
		state = (data.state :: AgentState) or "toBuilding",
		path = path,
		pathIndex = initialIndex,
		position = data.position or spawnCFrame.Position,
		moveSpeed = data.moveSpeed or DEFAULT_MOVE_SPEED,
		arrivalTolerance = data.arrivalTolerance or DEFAULT_ARRIVAL_TOLERANCE,
		faceAdjustment = adjustment,
		buildingPosition = data.buildingPosition,
		visitPosition = data.visitPosition or data.position,
		brainrotName = template.Name,
		spawnCFrame = spawnCFrame,
	}

	setAgentHealth(agent, tonumber((data :: any).health), tonumber((data :: any).maxHealth))

	agents[agent.id] = agent
	return agent
end

local function getOrCreateAgent(data: any): ClientAgent?
	local agent = agents[data.id]
	if agent then
		local model = agent.model
		if model and model:GetAttribute("BrainrotAgentId") ~= agent.id then
			model:SetAttribute("BrainrotAgentId", agent.id)
		end
		return agent
	end
	return createAgent(data)
end

local function handleAgentSpawn(data: any)
	local agent = getOrCreateAgent(data)
	if not agent then
		return
	end

	if agent.state ~= "hidden" and agent.model.Parent == nil then
		agent.model.Parent = ensureVisitorsRoot()
	end

	updateAgentState(agent, data)
end

local function handleAgentHidden(data: any)
	local agent = agents[data.id]
	if not agent then
		return
	end

	agent.state = "hidden"
	agent.path = {}
	agent.pathIndex = 1
	agent.visitPosition = agent.position
	applyTransform(agent)
end

local function handleAgentReturn(data: any)
	local agent = agents[data.id]
	if not agent then
		local created = createAgent(data)
		if not created then
			return
		end
		agent = created
	end

	agent = agent :: ClientAgent
	agent.state = "toSpawn"
	agent.path = data.path or {}
	agent.pathIndex = 1
	agent.moveSpeed = data.moveSpeed or agent.moveSpeed
	agent.arrivalTolerance = data.arrivalTolerance or agent.arrivalTolerance
	agent.faceAdjustment = data.faceAdjustment or agent.faceAdjustment
	agent.spawnCFrame = data.spawnCFrame or agent.spawnCFrame
	agent.position = data.reappearPosition or agent.visitPosition or agent.position
	agent.visitPosition = agent.position
	setAgentHealth(agent, tonumber((data :: any).health), tonumber((data :: any).maxHealth))
	applyTransform(agent)
end

local function handleAgentRemoved(payload: any)
	if typeof(payload) == "string" then
		local agent = agents[payload]
		if agent then
			destroyAgent(agent)
		end
		return
	end

	if typeof(payload) ~= "table" then
		return
	end

	local id = payload.id
	if typeof(id) == "string" then
		local agent = agents[id]
		if agent then
			destroyAgent(agent)
		end
	end

	if payload.announce then
		local message = payload.message
		if typeof(message) == "string" then
			local indexValue = payload.plotIndex
			local plotIndex = if typeof(indexValue) == "number" then indexValue else nil
			announceDefeat(plotIndex, message)
		end
	end
end

local function handleAgentSnapshot(payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	local list = payload.agents
	if typeof(list) ~= "table" then
		return
	end

	for _, entry in ipairs(list) do
		local agent = getOrCreateAgent(entry)
		if agent then
			updateAgentState(agent, entry)
		end
	end
end

local function stepAgent(agent: ClientAgent, deltaTime: number)
	if agent.state == "hidden" then
		return
	end

	local path = agent.path
	if typeof(path) ~= "table" or #path == 0 then
		return
	end

	local target = path[agent.pathIndex]
	if not target then
		return
	end

	local currentPosition = agent.position
	local toTarget = target - currentPosition
	local distance = toTarget.Magnitude
	local tolerance = agent.arrivalTolerance

	if distance <= tolerance then
		agent.position = target
		agent.pathIndex += 1
		if agent.pathIndex > #path then
			agent.pathIndex = #path
			agent.path = {}
			if agent.state == "toBuilding" then
				agent.visitPosition = target
			end
			applyTransform(agent)
			return
		end

		target = path[agent.pathIndex]
		toTarget = target - agent.position
		distance = toTarget.Magnitude
	end

	if distance <= 0 then
		return
	end

	local stepDistance = agent.moveSpeed * deltaTime
	if stepDistance >= distance then
		agent.position = target
	else
		agent.position = agent.position + (toTarget / distance) * stepDistance
	end

	if agent.state == "toBuilding" then
		agent.visitPosition = agent.position
	end

	local direction = target - agent.position
	if direction.Magnitude < 1e-3 then
		if agent.state == "toBuilding" and agent.buildingPosition then
			direction = agent.buildingPosition - agent.position
		else
			direction = Vector3.new(0, 0, -1)
		end
	end
	pivotModel(agent.model, agent.position, direction, agent.faceAdjustment)
end

TourismPackets.AgentSpawn.OnClientEvent:Connect(handleAgentSpawn)
TourismPackets.AgentHidden.OnClientEvent:Connect(handleAgentHidden)
TourismPackets.AgentReturn.OnClientEvent:Connect(handleAgentReturn)
TourismPackets.AgentRemoved.OnClientEvent:Connect(handleAgentRemoved)
TourismPackets.AgentSnapshot.OnClientEvent:Connect(handleAgentSnapshot)
TourismPackets.DifficultyUpdate.OnClientEvent:Connect(handleDifficultyUpdate)

RunService.Heartbeat:Connect(function(deltaTime)
	for _, agent in pairs(agents) do
		stepAgent(agent, deltaTime)
	end
end)
