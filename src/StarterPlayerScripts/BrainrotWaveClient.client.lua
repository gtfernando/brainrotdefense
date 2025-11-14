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
local DesignFolder = ReplicatedStorage:FindFirstChild("Design")
local BrainrotsUiTemplate: BillboardGui? = nil

if DesignFolder then
	local candidate = DesignFolder:FindFirstChild("BrainrotsUI")
	if candidate and candidate:IsA("BillboardGui") then
		BrainrotsUiTemplate = candidate
	end
end
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
	healthText: TextLabel?,
	fill: Frame?,
	nameText: TextLabel?,
}

export type ClientAgent = {
	id: string,
	model: Model,
	primary: BasePart,
	animationHandle: AnimationHandle?,
	sprintAnimationHandle: AnimationHandle?,
	activeAnimation: "default" | "sprint",
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
	isSprinting: boolean,
}

local visitorsRoot: Folder? = nil
local brainrotAssets: { [string]: Model } = {}
local faceAdjustmentCache: { [string]: CFrame? } = {}
local agents: { [string ]: ClientAgent } = {}
local defeatAnnouncements: { [number]: boolean } = {}

type WaveStatus = "idle" | "waitingStart" | "spawning" | "cooldown" | "defeated"

type RequirementState = {
	hasMoney: boolean,
	hasWeapon: boolean,
}

type WaveStatePayload = {
	plotIndex: number?,
	wave: number,
	status: WaveStatus,
	total: number,
	spawned: number,
	defeated: number,
	skipThreshold: number?,
	prompt: boolean?,
	requirements: RequirementState?,
}

type WaveHudHandle = {
	gui: ScreenGui,
	container: Frame,
	waveLabel: TextLabel,
	statusLabel: TextLabel,
	statusBadge: Frame,
	progressBar: Frame,
	progressFill: Frame,
	progressLabel: TextLabel,
	timerLabel: TextLabel,
	promptLabel: TextLabel,
	startButton: TextButton,
	skipButton: TextButton,
	requirementLabel: TextLabel,
}

type WaveTimerInfo = {
	wave: number,
	remaining: number,
	elapsed: number,
	timestamp: number,
}

local waveHud: WaveHudHandle? = nil
local currentWaveState: WaveStatePayload? = nil
local currentPlotIndex: number? = nil
local wavePromptWave: number? = nil
local waveTimerInfo: WaveTimerInfo = {
	wave = 0,
	remaining = 0,
	elapsed = 0,
	timestamp = 0,
}

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

local function hydrateWaveHudHandle(gui: ScreenGui): WaveHudHandle?
	local container = gui:FindFirstChild("WavePanel")
	if not container or not container:IsA("Frame") then
		return nil
	end

	local header = container:FindFirstChild("Header")
	local waveLabel = header and header:FindFirstChild("WaveLabel")
	local timerLabel = header and header:FindFirstChild("TimerLabel")

	local statusBadge = container:FindFirstChild("StatusBadge")
	local statusLabel = statusBadge and statusBadge:FindFirstChild("StatusLabel")

	local progressSection = container:FindFirstChild("ProgressSection")
	local progressBar = progressSection and progressSection:FindFirstChild("ProgressBar")
	local progressFill = progressBar and progressBar:FindFirstChild("ProgressFill")
	local progressLabel = progressSection and progressSection:FindFirstChild("ProgressLabel")

	local promptLabel = container:FindFirstChild("PromptLabel")
	local buttonRow = container:FindFirstChild("ButtonRow")
	local startButton = buttonRow and buttonRow:FindFirstChild("StartButton")
	local skipButton = buttonRow and buttonRow:FindFirstChild("SkipButton")
	local requirementLabel = gui:FindFirstChild("RequirementLabel")

	if not (waveLabel and timerLabel and statusBadge and statusLabel and progressBar and progressFill and progressLabel and promptLabel and startButton and skipButton and requirementLabel) then
		return nil
	end

	return {
		gui = gui,
		container = container,
		waveLabel = waveLabel :: TextLabel,
		statusLabel = statusLabel :: TextLabel,
		statusBadge = statusBadge :: Frame,
		progressBar = progressBar :: Frame,
		progressFill = progressFill :: Frame,
		progressLabel = progressLabel :: TextLabel,
		timerLabel = timerLabel :: TextLabel,
		promptLabel = promptLabel :: TextLabel,
		startButton = startButton :: TextButton,
		skipButton = skipButton :: TextButton,
		requirementLabel = requirementLabel :: TextLabel,
	}
end


local WAVE_STATUS_TEXT: { [WaveStatus]: string } = {
	idle = "No activity",
	waitingStart = "Ready to start",
	spawning = "Wave in progress",
	cooldown = "Cooldown",
	defeated = "Defeated",
}

local STATUS_BADGE_COLOR: { [WaveStatus]: Color3 } = {
	idle = Color3.fromRGB(40, 44, 58),
	waitingStart = Color3.fromRGB(57, 74, 115),
	spawning = Color3.fromRGB(237, 124, 88),
	cooldown = Color3.fromRGB(70, 110, 90),
	defeated = Color3.fromRGB(108, 46, 59),
}


local START_BUTTON_TEXT: { [WaveStatus]: string } = {
	waitingStart = "START WAVE",
	defeated = "Retry",
}

local function asWaveStatus(value: any): WaveStatus
	if value == "waitingStart" or value == "arming" then
		return "waitingStart"
	elseif value == "spawning" then
		return "spawning"
	elseif value == "cooldown" then
		return "cooldown"
	elseif value == "defeated" then
		return "defeated"
	end
	return "idle"
end

local function toNonNegativeInteger(value: any): number
	local numeric = tonumber(value)
	if not numeric then
		return 0
	end
	if numeric <= 0 then
		return 0
	end
	return math.floor(numeric)
end

local EMPTY_REQUIREMENTS: RequirementState = {
	hasMoney = false,
	hasWeapon = false,
}

local function parseRequirementState(value: any): RequirementState
	if typeof(value) ~= "table" then
		return {
			hasMoney = false,
			hasWeapon = false,
		}
	end
	return {
		hasMoney = value.hasMoney == true,
		hasWeapon = value.hasWeapon == true,
	}
end

local function formatSeconds(seconds: number): string
	local clamped = math.max(0, seconds)
	local totalSeconds = math.floor(clamped + 0.5)
	local minutes = math.floor(totalSeconds / 60)
	local secs = totalSeconds % 60
	return string.format("%02d:%02d", minutes, secs)
end

local function sendWaveControl(action: string)
	if action ~= "start" and action ~= "skip" then
		return
	end

	local payload: { plotIndex: number }? = nil
	if currentPlotIndex then
		payload = { plotIndex = currentPlotIndex }
	end

	TourismPackets.WaveControl:Fire(action, payload)
end

local function ensureWaveHud(): WaveHudHandle
	if waveHud and waveHud.gui.Parent then
		return waveHud
	end

	local existingGui = playerGui:FindFirstChild("BrainrotWaveHud")
	if existingGui and existingGui:IsA("ScreenGui") then
		local hydrated = hydrateWaveHudHandle(existingGui)
		if hydrated then
			waveHud = hydrated
			return hydrated
		else
			existingGui:Destroy()
		end
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "BrainrotWaveHud"
	gui.DisplayOrder = 5000
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	local container = Instance.new("Frame")
	container.Name = "WavePanel"
	container.Size = UDim2.new(0, 360, 0, 190)
	container.Position = UDim2.new(0, 28, 1, -32)
	container.AnchorPoint = Vector2.new(0, 1)
	container.BackgroundColor3 = Color3.fromRGB(9, 11, 15)
	container.BackgroundTransparency = 0.05
	container.BorderSizePixel = 0
	container.Active = false
	container.Parent = gui

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 12)
	panelCorner.Parent = container

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = Color3.fromRGB(255, 255, 255)
	panelStroke.Thickness = 1.25
	panelStroke.Transparency = 0.85
	panelStroke.Parent = container

	local panelGradient = Instance.new("UIGradient")
	panelGradient.Color = ColorSequence.new(
		Color3.fromRGB(18, 20, 28),
		Color3.fromRGB(12, 13, 18)
	)
	panelGradient.Rotation = 35
	panelGradient.Parent = container

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 16)
	padding.PaddingBottom = UDim.new(0, 16)
	padding.PaddingLeft = UDim.new(0, 18)
	padding.PaddingRight = UDim.new(0, 18)
	padding.Parent = container

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 34)
	header.BackgroundTransparency = 1
	header.Parent = container

	local waveLabel = Instance.new("TextLabel")
	waveLabel.Name = "WaveLabel"
	waveLabel.Size = UDim2.new(0.6, 0, 1, 0)
	waveLabel.BackgroundTransparency = 1
	waveLabel.Text = "Wave 1"
	waveLabel.TextColor3 = Color3.fromRGB(236, 238, 245)
	waveLabel.Font = Enum.Font.GothamSemibold
	waveLabel.TextSize = 20
	waveLabel.TextXAlignment = Enum.TextXAlignment.Left
	waveLabel.Parent = header

	local timerLabel = Instance.new("TextLabel")
	timerLabel.Name = "TimerLabel"
	timerLabel.Size = UDim2.new(0.4, 0, 1, 0)
	timerLabel.Position = UDim2.new(0.6, 0, 0, 0)
	timerLabel.BackgroundTransparency = 1
	timerLabel.Text = ""
	timerLabel.TextColor3 = Color3.fromRGB(180, 188, 203)
	timerLabel.Font = Enum.Font.Gotham
	timerLabel.TextSize = 16
	timerLabel.TextXAlignment = Enum.TextXAlignment.Right
	timerLabel.Parent = header

	local statusBadge = Instance.new("Frame")
	statusBadge.Name = "StatusBadge"
	statusBadge.Size = UDim2.new(0, 120, 0, 24)
	statusBadge.Position = UDim2.new(1, -120, 0, 36)
	statusBadge.AnchorPoint = Vector2.new(1, 0)
	statusBadge.BackgroundColor3 = Color3.fromRGB(40, 42, 52)
	statusBadge.BackgroundTransparency = 0.1
	statusBadge.BorderSizePixel = 0
	statusBadge.Parent = container

	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(0, 6)
	badgeCorner.Parent = statusBadge

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "StatusLabel"
	statusLabel.Size = UDim2.new(1, 0, 1, 0)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Font = Enum.Font.GothamSemibold
	statusLabel.Text = WAVE_STATUS_TEXT.idle
	statusLabel.TextColor3 = Color3.fromRGB(235, 238, 250)
	statusLabel.TextSize = 14
	statusLabel.TextXAlignment = Enum.TextXAlignment.Center
	statusLabel.Parent = statusBadge

	local progressSection = Instance.new("Frame")
	progressSection.Name = "ProgressSection"
	progressSection.Size = UDim2.new(1, 0, 0, 72)
	progressSection.Position = UDim2.new(0, 0, 0, 72)
	progressSection.BackgroundTransparency = 1
	progressSection.Parent = container

	local progressBar = Instance.new("Frame")
	progressBar.Name = "ProgressBar"
	progressBar.Size = UDim2.new(1, 0, 0, 12)
	progressBar.Position = UDim2.new(0, 0, 0, 0)
	progressBar.BackgroundColor3 = Color3.fromRGB(30, 36, 44)
	progressBar.BorderSizePixel = 0
	progressBar.Parent = progressSection

	local progressCorner = Instance.new("UICorner")
	progressCorner.CornerRadius = UDim.new(0, 6)
	progressCorner.Parent = progressBar

	local progressFill = Instance.new("Frame")
	progressFill.Name = "ProgressFill"
	progressFill.Size = UDim2.new(0, 0, 1, 0)
	progressFill.BackgroundColor3 = Color3.fromRGB(255, 141, 99)
	progressFill.BorderSizePixel = 0
	progressFill.Parent = progressBar

	local progressFillCorner = Instance.new("UICorner")
	progressFillCorner.CornerRadius = UDim.new(0, 6)
	progressFillCorner.Parent = progressFill

	local progressLabel = Instance.new("TextLabel")
	progressLabel.Name = "ProgressLabel"
	progressLabel.Size = UDim2.new(1, 0, 0, 28)
	progressLabel.Position = UDim2.new(0, 0, 0, 20)
	progressLabel.BackgroundTransparency = 1
	progressLabel.Font = Enum.Font.Gotham
	progressLabel.Text = "No active invasion"
	progressLabel.TextSize = 15
	progressLabel.TextColor3 = Color3.fromRGB(205, 210, 223)
	progressLabel.TextXAlignment = Enum.TextXAlignment.Left
	progressLabel.Parent = progressSection

	local promptLabel = Instance.new("TextLabel")
	promptLabel.Name = "PromptLabel"
	promptLabel.Size = UDim2.new(1, 0, 0, 32)
	promptLabel.Position = UDim2.new(0, 0, 0, 112)
	promptLabel.BackgroundColor3 = Color3.fromRGB(255, 214, 130)
	promptLabel.BackgroundTransparency = 0.85
	promptLabel.BorderSizePixel = 0
	promptLabel.Text = ""
	promptLabel.TextColor3 = Color3.fromRGB(62, 45, 7)
	promptLabel.Font = Enum.Font.GothamSemibold
	promptLabel.TextSize = 14
	promptLabel.TextXAlignment = Enum.TextXAlignment.Left
	promptLabel.TextYAlignment = Enum.TextYAlignment.Center
	promptLabel.TextWrapped = true
	promptLabel.Visible = false
	promptLabel.Parent = container

	local promptCorner = Instance.new("UICorner")
	promptCorner.CornerRadius = UDim.new(0, 6)
	promptCorner.Parent = promptLabel

	local buttonRow = Instance.new("Frame")
	buttonRow.Name = "ButtonRow"
	buttonRow.Size = UDim2.new(1, 0, 0, 38)
	buttonRow.Position = UDim2.new(0, 0, 1, -6)
	buttonRow.AnchorPoint = Vector2.new(0, 1)
	buttonRow.BackgroundTransparency = 1
	buttonRow.Parent = container

	local startButton = Instance.new("TextButton")
	startButton.Name = "StartButton"
	startButton.Size = UDim2.new(0.5, -6, 1, 0)
	startButton.BackgroundColor3 = Color3.fromRGB(255, 193, 92)
	startButton.AutoButtonColor = false
	startButton.Text = "START WAVE"
	startButton.Font = Enum.Font.GothamBold
	startButton.TextSize = 16
	startButton.TextColor3 = Color3.fromRGB(37, 26, 7)
	startButton.Visible = false
	startButton.Active = false
	startButton.Parent = buttonRow

	local startCorner = Instance.new("UICorner")
	startCorner.CornerRadius = UDim.new(0, 6)
	startCorner.Parent = startButton

	local skipButton = Instance.new("TextButton")
	skipButton.Name = "SkipButton"
	skipButton.Size = UDim2.new(0.5, -6, 1, 0)
	skipButton.Position = UDim2.new(0.5, 6, 0, 0)
	skipButton.BackgroundColor3 = Color3.fromRGB(40, 46, 60)
	skipButton.AutoButtonColor = false
	skipButton.Text = "SKIP WAVE"
	skipButton.Font = Enum.Font.GothamSemibold
	skipButton.TextSize = 16
	skipButton.TextColor3 = Color3.fromRGB(235, 239, 255)
	skipButton.Visible = false
	skipButton.Active = false
	skipButton.Parent = buttonRow

	local skipCorner = Instance.new("UICorner")
	skipCorner.CornerRadius = UDim.new(0, 6)
	skipCorner.Parent = skipButton

	local requirementLabel = Instance.new("TextLabel")
	requirementLabel.Name = "RequirementLabel"
	requirementLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	requirementLabel.Position = UDim2.new(0.5, 0, 0.75, 0)
	requirementLabel.Size = UDim2.new(0.7, 0, 0, 64)
	requirementLabel.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
	requirementLabel.BackgroundTransparency = 0.08
	requirementLabel.BorderSizePixel = 0
	requirementLabel.TextColor3 = Color3.fromRGB(255, 249, 235)
	requirementLabel.TextSize = 18
	requirementLabel.Font = Enum.Font.GothamSemibold
	requirementLabel.TextWrapped = true
	requirementLabel.TextXAlignment = Enum.TextXAlignment.Center
	requirementLabel.TextYAlignment = Enum.TextYAlignment.Center
	requirementLabel.Visible = false
	requirementLabel.ZIndex = 20
	requirementLabel.Parent = gui

	local requirementCorner = Instance.new("UICorner")
	requirementCorner.CornerRadius = UDim.new(0, 12)
	requirementCorner.Parent = requirementLabel

	local requirementStroke = Instance.new("UIStroke")
	requirementStroke.Color = Color3.fromRGB(255, 255, 255)
	requirementStroke.Transparency = 0.8
	requirementStroke.Thickness = 1
	requirementStroke.Parent = requirementLabel

	gui.Enabled = false

	startButton.Activated:Connect(function()
		sendWaveControl("start")
	end)

	skipButton.Activated:Connect(function()
		sendWaveControl("skip")
	end)

	local handle: WaveHudHandle = {
		gui = gui,
		container = container,
		waveLabel = waveLabel,
		statusLabel = statusLabel,
		statusBadge = statusBadge,
		progressBar = progressBar,
		progressFill = progressFill,
		progressLabel = progressLabel,
		timerLabel = timerLabel,
		promptLabel = promptLabel,
		startButton = startButton,
		skipButton = skipButton,
		requirementLabel = requirementLabel,
	}
	waveHud = handle
	return handle
end

local function updateTimerText()
	local handle = waveHud
	if not handle then
		return
	end

	local state = currentWaveState
	if not state then
		if handle.timerLabel.Text ~= "" then
			handle.timerLabel.Text = ""
		end
		return
	end

	local status = state.status
	if status ~= "cooldown" and status ~= "spawning" then
		if handle.timerLabel.Text ~= "" then
			handle.timerLabel.Text = ""
		end
		return
	end

	local baseTimestamp = waveTimerInfo.timestamp
	local delta = 0
	if baseTimestamp > 0 then
		delta = math.max(0, os.clock() - baseTimestamp)
	end

	local remaining = math.max(0, waveTimerInfo.remaining - delta)
	local elapsed = math.max(0, waveTimerInfo.elapsed + delta)

	local newText = ""
	if status == "cooldown" then
		newText = string.format("Next wave in %s", formatSeconds(remaining))
	else
		newText = string.format("In battle · %s", formatSeconds(elapsed))
	end

	if handle.timerLabel.Text ~= newText then
		handle.timerLabel.Text = newText
	end
end

local function refreshWaveHud()
	local state = currentWaveState
	local handle = ensureWaveHud()

	if not state then
		handle.gui.Enabled = false
		handle.waveLabel.Text = "Wave 1"
		handle.statusLabel.Text = WAVE_STATUS_TEXT.idle
		handle.progressFill.Size = UDim2.new(0, 0, 1, 0)
		handle.progressLabel.Text = "No active invasion"
		handle.promptLabel.Visible = false
		handle.promptLabel.Text = ""
		handle.startButton.Visible = false
		handle.startButton.Active = false
		handle.skipButton.Visible = false
		handle.skipButton.Active = false
		handle.timerLabel.Text = ""
		handle.requirementLabel.Visible = false
		handle.requirementLabel.Text = ""
		return
	end

	handle.gui.Enabled = true
	handle.waveLabel.Text = string.format("Wave %d", math.max(1, state.wave))
	local status = state.status
	handle.statusLabel.Text = WAVE_STATUS_TEXT[status] or WAVE_STATUS_TEXT.idle
	handle.statusBadge.BackgroundColor3 = STATUS_BADGE_COLOR[status] or STATUS_BADGE_COLOR.idle

	local total = math.max(0, state.total)
	local defeated = math.max(0, state.defeated)
	local spawned = math.max(defeated, math.max(0, state.spawned))
	local active = math.max(0, spawned - defeated)
	local ratio = if total > 0 then math.clamp(defeated / total, 0, 1) else 0
	handle.progressFill.Size = UDim2.new(ratio, 0, 1, 0)

	if total > 0 then
		local activeText = if active > 0 then string.format("· %d active", active) else "· no threats"
		handle.progressLabel.Text = string.format("%d of %d defeated %s", defeated, total, activeText)
	else
		handle.progressLabel.Text = "No active invasion"
	end

	local startText = START_BUTTON_TEXT[status]
	if startText then
		handle.startButton.Visible = true
		handle.startButton.Active = true
		handle.startButton.Text = startText
	else
		handle.startButton.Visible = false
		handle.startButton.Active = false
	end

	local promptActive = status == "spawning" and ((state.prompt == true) or (wavePromptWave ~= nil and wavePromptWave == state.wave))
	local thresholdPercent = math.clamp(math.floor(((state.skipThreshold or 0) * 100) + 0.5), 0, 100)
	if thresholdPercent < 75 then
		thresholdPercent = 75
	end
	if promptActive then
		handle.skipButton.Visible = true
		handle.skipButton.Active = true
		handle.promptLabel.Visible = true
		local defeatedPercent = math.max(thresholdPercent, math.floor(ratio * 100 + 0.5))
		handle.promptLabel.Text = string.format("%d%% defeated. Over %d%%, skip now.", defeatedPercent, thresholdPercent)
	else
		handle.skipButton.Visible = false
		handle.skipButton.Active = false
		handle.promptLabel.Visible = false
		handle.promptLabel.Text = ""
	end

	local requirementLabel = handle.requirementLabel
	if requirementLabel then
		local reqState = state.requirements or EMPTY_REQUIREMENTS
		local needsMoney = reqState.hasMoney ~= true
		local needsWeapon = reqState.hasWeapon ~= true
		local shouldShow = (needsMoney or needsWeapon) and status ~= "spawning"
		if shouldShow then
			requirementLabel.Visible = true
			local waveNumber = math.max(1, state.wave)
			local waveText = string.format("Wave %d", waveNumber)
			if needsMoney and needsWeapon then
				requirementLabel.Text = string.format("Place a building and a gun building before starting %s", waveText)
			elseif needsMoney then
				requirementLabel.Text = string.format("Place a money-generating building to start %s", waveText)
			else
				requirementLabel.Text = string.format("Place a gun building to start %s", waveText)
			end
		else
			requirementLabel.Visible = false
			requirementLabel.Text = ""
		end
	end

	updateTimerText()
end

local function handleWaveState(payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	local rawWave = toNonNegativeInteger((payload :: any).wave)
	local waveNumber = rawWave
	if waveNumber == 0 then
		if currentWaveState then
			waveNumber = currentWaveState.wave
		else
			waveNumber = 1
		end
	end

	local total = toNonNegativeInteger((payload :: any).total)
	local spawned = toNonNegativeInteger((payload :: any).spawned)
	local defeated = toNonNegativeInteger((payload :: any).defeated)
	if spawned < defeated then
		spawned = defeated
	end

	local skipThresholdValue = tonumber((payload :: any).skipThreshold)
	local skipThreshold = if skipThresholdValue and skipThresholdValue >= 0 then math.clamp(skipThresholdValue, 0, 1) else nil

	local plotIndexValue = (payload :: any).plotIndex
	local plotIndex = if typeof(plotIndexValue) == "number" then plotIndexValue else currentPlotIndex
	currentPlotIndex = plotIndex

	local status = asWaveStatus((payload :: any).status)
	local promptFlag = (payload :: any).prompt == true
	local requirementsState = parseRequirementState((payload :: any).requirements)

	local newState: WaveStatePayload = {
		plotIndex = plotIndex,
		wave = waveNumber,
		status = status,
		total = total,
		spawned = spawned,
		defeated = defeated,
		skipThreshold = skipThreshold,
		prompt = promptFlag,
		requirements = requirementsState,
	}

	currentWaveState = newState

	if promptFlag then
		wavePromptWave = newState.wave
	elseif wavePromptWave and wavePromptWave == newState.wave then
		wavePromptWave = nil
	end

	if status ~= "cooldown" then
		waveTimerInfo.remaining = 0
	end
	if status ~= "spawning" then
		waveTimerInfo.elapsed = 0
	end
	if status ~= "cooldown" and status ~= "spawning" then
		waveTimerInfo.timestamp = 0
	end
	waveTimerInfo.wave = newState.wave

	refreshWaveHud()
end

local function handleWaveTimer(waveNumber: number, remaining: number, elapsed: number)
	waveTimerInfo.wave = toNonNegativeInteger(waveNumber)
	if waveTimerInfo.wave == 0 then
		if currentWaveState then
			waveTimerInfo.wave = currentWaveState.wave
		else
			waveTimerInfo.wave = 1
		end
	end

	waveTimerInfo.remaining = math.max(0, tonumber(remaining) or 0)
	waveTimerInfo.elapsed = math.max(0, tonumber(elapsed) or 0)
	waveTimerInfo.timestamp = os.clock()

	updateTimerText()
end

local function handleWavePrompt(payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	local plotIndexValue = (payload :: any).plotIndex
	if typeof(plotIndexValue) == "number" then
		currentPlotIndex = plotIndexValue
	end

	local waveNumber = toNonNegativeInteger((payload :: any).wave)
	if waveNumber == 0 then
		return
	end

	wavePromptWave = waveNumber
	if currentWaveState and currentWaveState.wave == waveNumber then
		currentWaveState.prompt = true
	end

	refreshWaveHud()
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
		if existing.nameText then
			existing.nameText.Text = agent.brainrotName
		end
		return existing
	end

	local billboard: BillboardGui? = nil
	local fillFrame: Frame? = nil
	local healthLabel: TextLabel? = nil
	local nameLabel: TextLabel? = nil

	if not BrainrotsUiTemplate then
		local design = DesignFolder
		if not design or not design.Parent then
			design = ReplicatedStorage:FindFirstChild("Design")
			if not design then
				design = ReplicatedStorage:WaitForChild("Design", 5)
			end
			DesignFolder = design
		end

		if design then
			local candidate = design:FindFirstChild("BrainrotsUI")
			if not candidate then
				candidate = design:WaitForChild("BrainrotsUI", 5)
			end
			if candidate and candidate:IsA("BillboardGui") then
				BrainrotsUiTemplate = candidate
			end
		end
	end

	if BrainrotsUiTemplate then
		local cloned = BrainrotsUiTemplate:Clone()
		cloned.Name = "BrainrotHealth"
		cloned.Adornee = primary
		cloned.Enabled = agent.state ~= "hidden"
		cloned.Parent = model

		local healthBar = cloned:FindFirstChild("HealthBar", true)
		if healthBar and healthBar:IsA("Frame") then
			local fillCandidate = healthBar:FindFirstChild("Fill")
			if fillCandidate and fillCandidate:IsA("Frame") then
				fillFrame = fillCandidate
			end
		end

		local healthInstance = cloned:FindFirstChild("Health", true)
		if healthInstance and healthInstance:IsA("TextLabel") then
			healthLabel = healthInstance
		end

		local nameInstance = cloned:FindFirstChild("BrainrotName", true)
		if nameInstance and nameInstance:IsA("TextLabel") then
			nameInstance.Text = agent.brainrotName
			nameLabel = nameInstance
		end

		billboard = cloned
	else
		local fallback = Instance.new("BillboardGui")
		fallback.Name = "BrainrotHealth"
		fallback.Size = HEALTH_BAR_SIZE
		fallback.StudsOffset = HEALTH_BAR_OFFSET
		fallback.AlwaysOnTop = true
		fallback.MaxDistance = 400
		fallback.Adornee = primary
		fallback.Enabled = agent.state ~= "hidden"
		fallback.Parent = model

		local frame = Instance.new("Frame")
		frame.Name = "Container"
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Parent = fallback

		local fallbackHealthLabel = Instance.new("TextLabel")
		fallbackHealthLabel.Name = "HealthLabel"
		fallbackHealthLabel.Size = UDim2.new(1, -12, 0, 18)
		fallbackHealthLabel.Position = UDim2.new(0, 6, 0, 4)
		fallbackHealthLabel.BackgroundTransparency = 1
		fallbackHealthLabel.Font = Enum.Font.GothamBold
		fallbackHealthLabel.TextSize = 16
		fallbackHealthLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		fallbackHealthLabel.TextXAlignment = Enum.TextXAlignment.Left
		fallbackHealthLabel.Text = ""
		fallbackHealthLabel.Parent = frame

		local barBg = Instance.new("Frame")
		barBg.Name = "HealthBar"
		barBg.Size = UDim2.new(1, -12, 0, 12)
		barBg.Position = UDim2.new(0, 6, 0, 26)
		barBg.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
		barBg.BorderSizePixel = 0
		barBg.Parent = frame

		local fallbackFill = Instance.new("Frame")
		fallbackFill.Name = "Fill"
		fallbackFill.Size = UDim2.new(1, 0, 1, 0)
		fallbackFill.BackgroundColor3 = Color3.fromRGB(60, 200, 80)
		fallbackFill.BorderSizePixel = 0
		fallbackFill.Parent = barBg

		healthLabel = fallbackHealthLabel
		fillFrame = fallbackFill
		billboard = fallback
	end

	local activeBillboard = billboard
	if not activeBillboard then
		return nil
	end

	activeBillboard.StudsOffset = HEALTH_BAR_OFFSET
	activeBillboard.AlwaysOnTop = true
	activeBillboard.MaxDistance = 400

	local handle: HealthUiHandle = {
		billboard = activeBillboard,
		fill = fillFrame,
		healthText = healthLabel,
		nameText = nameLabel,
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
	local fillFrame = handle.fill
	if fillFrame then
		fillFrame.Size = UDim2.new(ratio, 0, 1, 0)
		if ratio <= 0.15 then
			fillFrame.BackgroundColor3 = Color3.fromRGB(220, 70, 60)
		elseif ratio <= 0.45 then
			fillFrame.BackgroundColor3 = Color3.fromRGB(235, 170, 60)
		else
			fillFrame.BackgroundColor3 = Color3.fromRGB(60, 200, 80)
		end
	end

	local healthLabel = handle.healthText
	if healthLabel then
		healthLabel.Text = string.format("%d / %d", math.floor(health + 0.5), math.floor(maxHealth + 0.5))
	end

	local nameLabel = handle.nameText
	if nameLabel then
		nameLabel.Text = agent.brainrotName
	end
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

local function coerceAnimationId(raw: any): string?
	if raw == nil then
		return nil
	end

	if typeof(raw) == "number" then
		if raw == 0 then
			return nil
		end
		return "rbxassetid://" .. tostring(raw)
	elseif typeof(raw) == "string" then
		if raw == "" or raw == "0" then
			return nil
		end
		if raw:match("^rbxassetid://") then
			return raw
		end
		return "rbxassetid://" .. raw
	end

	return nil
end

local sprintAnimationKeys = {
	"runAnimationId",
	"RunAnimationId",
	"sprintAnimationId",
	"SprintAnimationId",
	"runningAnimationId",
	"RunningAnimationId",
}

local defaultAnimationKeys = {
	"animationId",
	"AnimationId",
}

local function resolveAnimationId(brainrotName: string, variant: "default" | "sprint"?): string?
	local data = BrainrotData[brainrotName]
	if typeof(data) ~= "table" then
		return nil
	end

	if variant == "sprint" then
		for _, key in ipairs(sprintAnimationKeys) do
			local asset = coerceAnimationId((data :: any)[key])
			if asset then
				return asset
			end
		end
	end

	for _, key in ipairs(defaultAnimationKeys) do
		local asset = coerceAnimationId((data :: any)[key])
		if asset then
			return asset
		end
	end

	return nil
end

local function loadAnimation(model: Model, brainrotName: string, variant: "default" | "sprint"?, autoplay: boolean?): AnimationHandle?
	local animationId = resolveAnimationId(brainrotName, variant)
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

	local suffix = if variant == "sprint" then "_Sprint" else "_Brainrot"
	local animation = Instance.new("Animation")
	animation.Name = brainrotName .. suffix .. "Animation"
	animation.AnimationId = animationId
	animation.Parent = model

	local track = (animator :: Animator):LoadAnimation(animation)
	track.Looped = true
	if autoplay ~= false then
		track:Play()
	end

	return {
		animation = animation,
		track = track,
	}
end

local function playAnimationHandle(handle: AnimationHandle?)
	if not handle then
		return
	end

	local track = handle.track
	if not track then
		return
	end

	if track.IsPlaying then
		track:AdjustSpeed(1)
	else
		track:Play()
	end
end

local function stopAnimationHandle(handle: AnimationHandle?)
	if not handle then
		return
	end

	local track = handle.track
	if not track then
		return
	end

	track:Stop()
end

local function setAgentSprintVisual(agent: ClientAgent, isSprinting: boolean)
	if agent.isSprinting == isSprinting then
		return
	end

	agent.isSprinting = isSprinting
	local defaultHandle = agent.animationHandle
	local sprintHandle = agent.sprintAnimationHandle

	if sprintHandle then
		if isSprinting then
			stopAnimationHandle(defaultHandle)
			playAnimationHandle(sprintHandle)
			agent.activeAnimation = "sprint"
		else
			stopAnimationHandle(sprintHandle)
			playAnimationHandle(defaultHandle)
			agent.activeAnimation = "default"
		end
	else
		if defaultHandle and defaultHandle.track then
			defaultHandle.track:AdjustSpeed(isSprinting and 1.45 or 1)
		end
		agent.activeAnimation = "default"
	end
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

	stopAnimationHandle(handle)
	if handle.animation then
		handle.animation:Destroy()
	end
end

local function destroyAgent(agent: ClientAgent)
	cleanupAnimation(agent.animationHandle)
	cleanupAnimation(agent.sprintAnimationHandle)
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
					Title = "Defeat",
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

	if data.sprinting ~= nil then
		setAgentSprintVisual(agent, data.sprinting == true)
	end

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

	local animationHandle = loadAnimation(model, template.Name, nil, true)
	local sprintAnimationHandle = loadAnimation(model, template.Name, "sprint", false)

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
		sprintAnimationHandle = sprintAnimationHandle,
		activeAnimation = "default",
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
		isSprinting = false,
	}

	setAgentHealth(agent, tonumber((data :: any).health), tonumber((data :: any).maxHealth))
	setAgentSprintVisual(agent, data.sprinting == true)

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
	setAgentSprintVisual(agent, false)
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
	setAgentSprintVisual(agent, data.sprinting == true)
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
TourismPackets.WaveState.OnClientEvent:Connect(handleWaveState)
TourismPackets.WaveTimer.OnClientEvent:Connect(handleWaveTimer)
TourismPackets.WavePrompt.OnClientEvent:Connect(handleWavePrompt)

RunService.Heartbeat:Connect(function(deltaTime)
	for _, agent in pairs(agents) do
		stepAgent(agent, deltaTime)
	end

	updateTimerText()
end)
