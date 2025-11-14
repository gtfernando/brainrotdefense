--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local NetworkFolder = ReplicatedStorage:WaitForChild("Network")
local SoundsFolder: Folder? = nil
local BatToolPackets = require(NetworkFolder:WaitForChild("BatToolPackets")) :: any

local SWING_ANIMATION_ID = "rbxassetid://104602786221151"
local SWING_SPEED_MULTIPLIER = 0.6

local BatCombatFramework = {}
BatCombatFramework.__index = BatCombatFramework

local LOCAL_PLAYER = Players.LocalPlayer

local modelCache: { [string]: Model } = {}
local crateModelCache: { [string]: Model } = {}

local function resolveSoundsFolder(): Folder?
	local cached = SoundsFolder
	if cached and cached.Parent then
		return cached
	end

	local found = ReplicatedStorage:FindFirstChild("Sounds")
	if not found then
		local ok, result = pcall(function()
			return ReplicatedStorage:WaitForChild("Sounds")
		end)
		if ok then
			found = result
		end
	end

	if found and found:IsA("Folder") then
		SoundsFolder = found
		return found
	end

	warn("BatCombatFramework could not resolve ReplicatedStorage.Sounds")
	return nil
end

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

local function resolveCrateModel(crateId: string): Model?
	local cached = crateModelCache[crateId]
	if cached and cached.Parent then
		return cached
	end

	for _, descendant in ipairs(Workspace:GetDescendants()) do
		if descendant:IsA("Model") and descendant:GetAttribute("CrateTopoInstanceId") == crateId then
			crateModelCache[crateId] = descendant
			return descendant
		end
	end

	crateModelCache[crateId] = nil
	return nil
end

function BatCombatFramework.new(tool: Tool)
	local self = setmetatable({} :: any, BatCombatFramework)
	self.tool = tool
	self.player = LOCAL_PLAYER
	self._connections = {} :: { any }
	self._equipped = false
	self._resultConnection = nil :: RBXScriptConnection?
	self._swingAnimation = nil :: Animation?
	self._activeSwingTrack = nil :: AnimationTrack?

	self:_connect(self.tool.Activated, function()
		self:_onActivated()
	end)

	self:_connect(self.tool.Equipped, function()
		self._equipped = true
	end)

	self:_connect(self.tool.Unequipped, function()
		self._equipped = false
		self:_stopSwingAnimation()
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

	self:_playSwingAnimation()
	self:_playSwingSound()
	BatToolPackets.Detect:Fire()
end

function BatCombatFramework:_ensureSwingAnimation(): Animation?
	local animation = self._swingAnimation
	if animation and animation.Parent then
		return animation
	end

	local created = Instance.new("Animation")
	created.Name = "BatSwingAnimation"
	created.AnimationId = SWING_ANIMATION_ID
	created.Parent = self.tool
	self._swingAnimation = created
	return created
end

function BatCombatFramework:_stopSwingAnimation()
	local currentTrack: AnimationTrack? = self._activeSwingTrack
	if currentTrack ~= nil then
		self._activeSwingTrack = nil :: any
		local activeTrack = currentTrack :: AnimationTrack
		local ok, err = pcall(function()
			activeTrack:Stop(0.05)
		end)
		if not ok then
			warn("BatCombatFramework failed to stop swing animation", err)
			activeTrack:Destroy()
		end
	end
end

function BatCombatFramework:_playSwingAnimation()
	local character = self.player and self.player.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local animator = humanoid:FindFirstChildOfClass("Animator") :: Animator?
	if not animator then
		local newAnimator = Instance.new("Animator")
		newAnimator.Name = "BatAnimator"
		newAnimator.Parent = humanoid
		animator = newAnimator
	end

	local animation = self:_ensureSwingAnimation()
	if not animation then
		return
	end

	self:_stopSwingAnimation()

	local success, trackResult = pcall(function()
		return (animator :: Animator):LoadAnimation(animation)
	end)
	if not success or not trackResult then
		return
	end

	local track = trackResult :: AnimationTrack
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = false
	track:Play(0.05, 1, 1)
	track:AdjustSpeed(SWING_SPEED_MULTIPLIER)
	self._activeSwingTrack = track

	local connection: RBXScriptConnection?
	connection = track.Stopped:Connect(function()
		if self._activeSwingTrack == track then
			self._activeSwingTrack = nil :: any
		end
		track:Destroy()
		local activeConnection = connection
		connection = nil
		if activeConnection then
			activeConnection:Disconnect()
			for index, value in ipairs(self._connections) do
				local typedValue = value :: RBXScriptConnection?
				if typedValue == activeConnection then
					table.remove(self._connections, index)
					break
				end
			end
		end
	end)
	if connection then
		self._connections[#self._connections + 1] = connection
	end
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

	local targetKind = tostring(agent.targetKind or "Brainrot")

	local soundsFolder = resolveSoundsFolder()
	local hitSoundName = "Hit"
	if targetKind == "CrateTopo" then
		local crunchAvailable = soundsFolder and soundsFolder:FindFirstChild("Crunch") ~= nil
		hitSoundName = if crunchAvailable then "Crunch" else "Hit"
	end
	self:_playSound(hitSoundName)

	local targetModel
	if targetKind == "CrateTopo" then
		targetModel = resolveCrateModel(agentId)
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
	local fillColor = if targetKind == "CrateTopo" then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(255, 0, 0)
	highlight.FillColor = fillColor
	local startTransparency = if targetKind == "CrateTopo" then 0.3 else 0.3
	highlight.FillTransparency = startTransparency
	highlight.OutlineTransparency = 1
	highlight.Adornee = targetModel
	highlight.Parent = targetModel

	local tweenTime = if targetKind == "CrateTopo" then 0.35 else 0.18
	local tweenStyle = if targetKind == "CrateTopo" then Enum.EasingStyle.Sine else Enum.EasingStyle.Quad
	local tween = TweenService:Create(highlight, TweenInfo.new(tweenTime, tweenStyle, Enum.EasingDirection.Out), {
		FillTransparency = 1,
	})
	tween:Play()

	tween.Completed:Connect(function()
		highlight:Destroy()
	end)

	local cleanupDelay = math.max(tweenTime, 0.24)
	task.delay(cleanupDelay, function()
		if highlight.Parent then
			highlight:Destroy()
		end
	end)
end

function BatCombatFramework:_playSound(soundName: string)
	local soundsFolder = resolveSoundsFolder()
	if not soundsFolder then
		return
	end

	local template = soundsFolder:FindFirstChild(soundName)
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
	self:_stopSwingAnimation()
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
		self._resultConnection = nil :: any
	end

	if self._swingAnimation then
		self._swingAnimation:Destroy()
		self._swingAnimation = nil :: any
	end
end

return BatCombatFramework
