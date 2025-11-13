--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local NetworkFolder = ReplicatedStorage:WaitForChild("Network")
local SoundsFolder = ReplicatedStorage:WaitForChild("Sounds", 5)
local BatToolPackets = require(NetworkFolder:WaitForChild("BatToolPackets")) :: any

local BatCombatFramework = {}
BatCombatFramework.__index = BatCombatFramework

local LOCAL_PLAYER = Players.LocalPlayer

local modelCache: { [string]: Model } = {}
local chestModelCache: { [string]: Model } = {}

local function resolveAgentModel(agentId: string): Model?
	local cached = modelCache[agentId]
	if cached and cached.Parent then
		return cached
	end

	local visitors = Workspace:FindFirstChild("BrainrotVisitors")
	if not visitors then
		modelCache[agentId] = nil
		return nil
	end

	for _, child in ipairs(visitors:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("BrainrotAgentId") == agentId then
			modelCache[agentId] = child
			return child
		end
	end

	modelCache[agentId] = nil
	return nil
end

local function resolveChestModel(chestId: string): Model?
	local cached = chestModelCache[chestId]
	if cached and cached.Parent then
		return cached
	end

	for _, descendant in ipairs(Workspace:GetDescendants()) do
		if descendant:IsA("Model") and descendant:GetAttribute("ChestId") == chestId then
			chestModelCache[chestId] = descendant
			return descendant
		end
	end

	chestModelCache[chestId] = nil
	return nil
end

function BatCombatFramework.new(tool: Tool)
	local self = setmetatable({}, BatCombatFramework)
	self.tool = tool
	self.player = LOCAL_PLAYER
	self._connections = {}
	self._equipped = false

	self:_connect(self.tool.Activated, function()
		self:_onActivated()
	end)

	self:_connect(self.tool.Equipped, function()
		self._equipped = true
	end)

	self:_connect(self.tool.Unequipped, function()
		self._equipped = false
	end)

	self:_connect(self.tool.Destroying, function()
		self:Destroy()
	end)

	self._resultConnection = BatToolPackets.DetectResult.OnClientEvent:Connect(function(payload)
		self:_handleResult(payload)
	end)

	return self
end

function BatCombatFramework:_connect(signal: RBXScriptSignal, handler: (...any) -> ())
	local connection = signal:Connect(handler)
	table.insert(self._connections, connection)
	return connection
end

function BatCombatFramework:_onActivated()
	if not self._equipped then
		return
	end

	self:_playSwingSound()
	BatToolPackets.Detect:Fire()
end

function BatCombatFramework:_handleResult(payload: any)
	if not payload then
		return
	end

	if payload.reason == "Cooldown" then
		return
	end

	if payload.reason == "CharacterUnavailable" then
		return
	end

	local agents = (payload.agents :: { any }) or {}
	local count = #agents
	if not payload.success or count == 0 then
		return
	end

	for _, rawAgent in ipairs(agents) do
		self:_playHitEffect(rawAgent)
	end
end

function BatCombatFramework:_playHitEffect(agent: { [string]: any })
	if not agent.wasDamaged then
		return
	end

	local agentId = agent.id
	if typeof(agentId) ~= "string" then
		return
	end

	self:_playHitSound()

	local targetKind = agent.targetKind or "Brainrot"
	local targetModel
	if targetKind == "Chest" then
		targetModel = resolveChestModel(agentId)
	else
		targetModel = resolveAgentModel(agentId)
	end
	if not targetModel then
		return
	end

	local existing = targetModel:FindFirstChild("BatHitHighlight")
	if existing and existing:IsA("Highlight") then
		existing:Destroy()
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "BatHitHighlight"
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	local fillColor = if targetKind == "Chest" or targetKind == "CrateTopo" then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(255, 0, 0)
	highlight.FillColor = fillColor
	highlight.FillTransparency = 0.3
	highlight.OutlineTransparency = 1
	highlight.Adornee = targetModel
	highlight.Parent = targetModel

	local tween = TweenService:Create(highlight, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		FillTransparency = 1,
	})
	tween:Play()

	tween.Completed:Connect(function()
		highlight:Destroy()
	end)

	task.delay(0.24, function()
		if highlight.Parent then
			highlight:Destroy()
		end
	end)
end

function BatCombatFramework:_playSound(soundName: string)
	if not SoundsFolder then
		return
	end

	local template = SoundsFolder:FindFirstChild(soundName)
	if not template or not template:IsA("Sound") then
		return
	end

	local sound = template:Clone()
	sound.Name = "Bat" .. soundName .. "Sound"
	sound.Looped = false
	sound.Parent = self.tool or (LOCAL_PLAYER.Character or Workspace)
	sound:Play()

	sound.Ended:Connect(function()
		sound:Destroy()
	end)

	task.delay(2, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

function BatCombatFramework:_playHitSound()
	self:_playSound("Hit")
end

function BatCombatFramework:_playSwingSound()
	self:_playSound("Swing")
end

function BatCombatFramework:Destroy()
	for _, connection in ipairs(self._connections) do
		if typeof(connection) == "RBXScriptConnection" then
			(connection :: RBXScriptConnection):Disconnect()
		elseif type(connection) == "table" and connection.Disconnect then
			(connection :: any):Disconnect()
		end
	end
	self._connections = {}

	if self._resultConnection then
		self._resultConnection:Disconnect()
		self._resultConnection = nil
	end
end

return BatCombatFramework
