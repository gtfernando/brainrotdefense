--!strict

local RunService = game:GetService("RunService")
if RunService:IsClient() then
	return {}
end

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local ModulesFolder = script.Parent
local PlotRegistry = require(ModulesFolder.Parent.Placement.PlotRegistry)
local RunServiceScheduler = require(ModulesFolder.RunServiceScheduler)
local PlacementInventory = require(ModulesFolder.PlacementInventory)
local Profiles = require(ModulesFolder.Profiles)
local PlacementService = require(ModulesFolder.Parent.Placement.Service)

local PlacementModule = ReplicatedStorage:WaitForChild("Placement")
local PlacementPackage = require(PlacementModule)
local PlacementAssetRegistry = PlacementPackage.AssetRegistry

local Catalog = require(ReplicatedStorage.Data.CrateTopoCatalog)
local AmmoBuildings = require(ReplicatedStorage.Data.AmmoBuildings)

type SchedulerHandle = any
type PlotSlot = any
type Range = Vector2

type CatalogDefaults = {
	assetFolderName: string?,
	assetName: string?,
	cooldownRange: Range?,
	stayDurationRange: Range?,
	riseTime: number?,
	fallTime: number?,
	hiddenDepth: number?,
	surfaceOffset: number?,
	initialDelayRange: Range?,
	maxHealth: number?,
}

type CatalogCrateDefinition = {
	name: string?,
	price: number?,
	asset: string?,
	weight: number?,
	health: number?,
	cooldownRange: Range?,
	stayDurationRange: Range?,
	riseTime: number?,
	fallTime: number?,
	hiddenDepth: number?,
	surfaceOffset: number?,
	Rewards: { [string]: number }?,
}

type CatalogTable = {
	Defaults: CatalogDefaults?,
	Crates: { [string]: CatalogCrateDefinition } | { CatalogCrateDefinition },
}

type NormalizedCrateDefinition = {
	id: string,
	name: string,
	price: number,
	asset: string,
	weight: number,
	maxHealth: number,
	cooldownRange: Range?,
	stayDurationRange: Range?,
	riseTime: number?,
	fallTime: number?,
	hiddenDepth: number?,
	surfaceOffset: number?,
	rewards: { [string]: number }?,
}

type SlotController = {
	key: string,
	slot: PlotSlot,
	slotIndex: number?,
	folderName: string,
	folder: Folder,
	rewardOverrides: { [string]: number }?,
	assetTemplates: { [string]: Model }?,
	ownerId: number?,
	active: boolean,
	destroyed: boolean,
	runners: { [BasePart]: SlotRunner },
	runnerOrder: { SlotRunner },
	connections: { RBXScriptConnection },
	rng: Random,
}

type SlotRunner = {
	part: BasePart,
	controller: SlotController,
	active: boolean,
	destroyed: boolean,
	thread: thread?,
	connections: { RBXScriptConnection },
	rng: Random,
	currentModel: Model?,
	currentTween: Tween?,
	locked: boolean,
	currentState: CrateState?,
}

type CrateStatus = "hidden" | "rising" | "exposed" | "purchased" | "hiding" | "destroyed"

type CrateState = {
	id: string,
	definition: NormalizedCrateDefinition,
	runner: SlotRunner,
	controller: SlotController,
	model: Model?,
	primary: BasePart?,
	hiddenCFrame: CFrame,
	visibleCFrame: CFrame,
	status: CrateStatus,
	price: number,
	ownerId: number?,
	slotIndex: number?,
	maxHealth: number,
	health: number,
	rewards: { [string]: number }?,
	spawnTime: number,
	fullyExposedAt: number?,
	purchasedAt: number?,
	purchaserUserId: number?,
	highlight: Highlight?,
	lastUiText: string?,
	hitAnimationTrack: AnimationTrack?,
}

local DEFAULT_SETTINGS = {
	assetFolderName = "Crates",
	assetName = "CrateProto",
	cooldownRange = Vector2.new(2.5, 5.0),
	stayDurationRange = Vector2.new(4.5, 6.0),
	riseTime = 0.45,
	fallTime = 0.4,
	hiddenDepth = 4,
	surfaceOffset = 0,
	initialDelayRange = Vector2.new(0.5, 2.5),
	fallbackCooldown = 2.5,
	maxHealth = 100,
}

local serviceState = {
	initialized = false,
	settings = table.clone(DEFAULT_SETTINGS),
	cratePool = {} :: { NormalizedCrateDefinition },
	totalWeight = 0,
	assetFolder = nil :: Folder?,
	assetTemplates = {} :: { [string]: Model },
	gunAssetFolder = nil :: Folder?,
	gunAssetTemplates = nil :: { [string]: Model }?,
	controllers = {} :: { [string]: SlotController },
	schedulerHandle = nil :: SchedulerHandle?,
	missingAssets = {} :: { [string]: boolean },
	globalRng = Random.new(),
	uiTemplate = nil :: Instance?,
	warnedMissingUi = false,
	cratesById = {} :: { [string]: CrateState },
	gunRewards = nil :: { [string]: number }?,
}

local HIGHLIGHT_DEFAULT_COLOR = Color3.fromRGB(255, 214, 94)
local HIGHLIGHT_PURCHASED_COLOR = Color3.fromRGB(83, 255, 129)
local HIGHLIGHT_DAMAGE_COLOR = Color3.fromRGB(255, 255, 255)
local HIT_ANIMATION_ID = "rbxassetid://121494417865868"
local HIT_ANIMATION_FADE_TIME = 0.05
local HIT_ANIMATION_SPEED = 1

local hitAnimationTemplate: Animation? = nil

local DEFAULT_CRATE_FOLDER_NAME = "CrateTopo"
local GUN_CRATE_FOLDER_NAME = "GunCrates"

local GUN_SLOT_WHITELIST = {}
for index = 1, 9 do
	GUN_SLOT_WHITELIST[index] = true
end

local function sanitizeString(value: any): string?
	if typeof(value) == "string" then
		local trimmed = string.match(value, "^%s*(.-)%s*$")
		if trimmed ~= "" then
			return trimmed
		end
	end
	return nil
end

local function sanitizeNumber(value: any, fallback: number?, minValue: number?): number?
	local numeric = tonumber(value)
	if numeric and (numeric ~= numeric or numeric == math.huge or numeric == -math.huge) then
		numeric = nil
	end
	if numeric and minValue and numeric < minValue then
		numeric = minValue
	end
	if numeric ~= nil then
		return numeric
	end
	return fallback
end

local function sanitizeRange(value: any, fallback: Range?): Range?
	if typeof(value) == "Vector2" then
		local minValue = math.min(value.X, value.Y)
		local maxValue = math.max(value.X, value.Y)
		return Vector2.new(minValue, maxValue)
	elseif typeof(value) == "table" then
		local minCandidate = sanitizeNumber(value.min or value[1], nil, nil)
		local maxCandidate = sanitizeNumber(value.max or value[2], nil, nil)
		if minCandidate and maxCandidate then
			local minValue = math.min(minCandidate, maxCandidate)
			local maxValue = math.max(minCandidate, maxCandidate)
			return Vector2.new(minValue, maxValue)
		end
	end
	return fallback
end

local function applyCatalogDefaults(settings, defaults: CatalogDefaults?)
	if typeof(defaults) ~= "table" then
		return
	end

	local assetFolder = sanitizeString(defaults.assetFolderName)
	if assetFolder then
		settings.assetFolderName = assetFolder
	end

	local assetName = sanitizeString(defaults.assetName)
	if assetName then
		settings.assetName = assetName
	end

	local cooldownRange = sanitizeRange(defaults.cooldownRange, nil)
	if cooldownRange then
		settings.cooldownRange = cooldownRange
	end

	local stayDurationRange = sanitizeRange(defaults.stayDurationRange, nil)
	if stayDurationRange then
		settings.stayDurationRange = stayDurationRange
	end

	local riseTime = sanitizeNumber(defaults.riseTime, nil, 0)
	if riseTime then
		settings.riseTime = riseTime
	end

	local fallTime = sanitizeNumber(defaults.fallTime, nil, 0)
	if fallTime then
		settings.fallTime = fallTime
	end

	local hiddenDepth = sanitizeNumber(defaults.hiddenDepth, nil, 0)
	if hiddenDepth then
		settings.hiddenDepth = hiddenDepth
	end

	local surfaceOffset = sanitizeNumber(defaults.surfaceOffset, nil, nil)
	if surfaceOffset then
		settings.surfaceOffset = surfaceOffset
	end

	local initialDelayRange = sanitizeRange(defaults.initialDelayRange, nil)
	if initialDelayRange then
		settings.initialDelayRange = initialDelayRange
	end

	local maxHealth = sanitizeNumber(defaults.maxHealth, nil, 1)
	if maxHealth then
		settings.maxHealth = math.max(1, math.floor(maxHealth + 0.5))
	end
end

local function applyOverrides(settings, overrides: { [string]: any }?)
	if typeof(overrides) ~= "table" then
		return
	end

	local assetFolder = sanitizeString(overrides.assetFolderName)
	if assetFolder then
		settings.assetFolderName = assetFolder
	end

	local assetName = sanitizeString(overrides.assetName)
	if assetName then
		settings.assetName = assetName
	end

	local cooldownRange = sanitizeRange(overrides.cooldownRange, nil)
	if cooldownRange then
		settings.cooldownRange = cooldownRange
	end

	local stayDurationRange = sanitizeRange(overrides.stayDurationRange, nil)
	if stayDurationRange then
		settings.stayDurationRange = stayDurationRange
	end

	local riseTime = sanitizeNumber(overrides.riseTime, nil, 0)
	if riseTime then
		settings.riseTime = riseTime
	end

	local fallTime = sanitizeNumber(overrides.fallTime, nil, 0)
	if fallTime then
		settings.fallTime = fallTime
	end

	local hiddenDepth = sanitizeNumber(overrides.hiddenDepth, nil, 0)
	if hiddenDepth then
		settings.hiddenDepth = hiddenDepth
	end

	local surfaceOffset = sanitizeNumber(overrides.surfaceOffset, nil, nil)
	if surfaceOffset then
		settings.surfaceOffset = surfaceOffset
	end

	local initialDelayRange = sanitizeRange(overrides.initialDelayRange, nil)
	if initialDelayRange then
		settings.initialDelayRange = initialDelayRange
	end

	local fallbackCooldown = sanitizeNumber(overrides.fallbackCooldown, nil, 0)
	if fallbackCooldown then
		settings.fallbackCooldown = fallbackCooldown
	end

	local maxHealth = sanitizeNumber(overrides.maxHealth, nil, 1)
	if maxHealth then
		settings.maxHealth = math.max(1, math.floor(maxHealth + 0.5))
	end
end

local function resolveAssetsFolder(folderName: string): Folder?
	local assetsRoot = ReplicatedStorage:FindFirstChild("Assets")
	if not assetsRoot then
		warn("ReplicatedStorage.Assets no está disponible.")
		return nil
	end

	local folder = assetsRoot:FindFirstChild(folderName)
	if folder and folder:IsA("Folder") then
		return folder
	end

	warn(string.format("ReplicatedStorage.Assets.%s no encontrado.", folderName))
	return nil
end

local function loadAssetTemplates(folder: Folder): { [string]: Model }
	local templates: { [string]: Model } = {}
	for _, child in folder:GetChildren() do
		if child:IsA("Model") then
			templates[child.Name] = child
		end
	end
	return templates
end

local function resolveCrateUiTemplate(): Instance?
	local cached = serviceState.uiTemplate
	if cached and cached.Parent then
		return cached
	end

	local designFolder = ReplicatedStorage:FindFirstChild("Design")
	if not designFolder then
		if not serviceState.warnedMissingUi then
			warn("ReplicatedStorage.Design no disponible; CratesUI no se mostrará.")
			serviceState.warnedMissingUi = true
		end
		serviceState.uiTemplate = nil
		return nil
	end

	local template = designFolder:FindFirstChild("CratesUI")
	if template then
		serviceState.uiTemplate = template
		serviceState.warnedMissingUi = false
		return template
	end

	if not serviceState.warnedMissingUi then
		warn("ReplicatedStorage.Design.CratesUI no encontrado.")
		serviceState.warnedMissingUi = true
	end

	serviceState.uiTemplate = nil
	return nil
end

local function formatPrice(amount: number): string
	local numeric = math.floor((tonumber(amount) or 0) + 0.5)
	local sign = ""
	if numeric < 0 then
		sign = "-"
		numeric = math.abs(numeric)
	end
	local text = tostring(numeric)
	local parts = {}
	while #text > 3 do
		table.insert(parts, 1, text:sub(-3))
		text = text:sub(1, -4)
	end
	parts[1] = text
	local formatted = table.concat(parts, ",")
	return sign .. formatted .. "$"
end

local function setMoneyLabel(root: Instance, text: string)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("TextLabel") and descendant.Name == "Money" then
			descendant.Text = text
			return
		end
	end

	local direct = root:FindFirstChild("Money")
	if direct and direct:IsA("TextLabel") then
		direct.Text = text
	end
end

local function applyMoneyText(root: Instance, price: number)
	setMoneyLabel(root, formatPrice(price))
end

local function attachCrateUi(primary: BasePart, definition: NormalizedCrateDefinition)
	local template = resolveCrateUiTemplate()
	if not template then
		return
	end

	local existing = primary:FindFirstChild("CrateTopoUIAttachment")
	local crateAttachment: Attachment
	if existing and existing:IsA("Attachment") then
		crateAttachment = existing
	else
		crateAttachment = Instance.new("Attachment")
		crateAttachment.Name = "CrateTopoUIAttachment"
		crateAttachment.Parent = primary
	end

	crateAttachment.Position = Vector3.new(0, (primary.Size.Y * 0.5) + 0.75, 0)

	for _, child in crateAttachment:GetChildren() do
		child:Destroy()
	end

	local clone = template:Clone()
	clone.Name = "CrateTopoUI"

	if clone:IsA("BillboardGui") then
		clone.Adornee = crateAttachment
		clone.Parent = crateAttachment
	elseif clone:IsA("Attachment") then
		clone.Parent = primary
		clone.Name = "CrateTopoUIAttachment"
		clone.Position = crateAttachment.Position
		crateAttachment:Destroy()
		crateAttachment = clone
	else
		clone.Parent = crateAttachment
	end

	applyMoneyText(clone, definition.price)
end

local function setCrateUiMoneyText(state: CrateState, text: string)
	local primary = state.primary
	if not primary or primary.Parent == nil then
		return
	end

	local containers: { Instance } = {}
	local attachment = primary:FindFirstChild("CrateTopoUIAttachment")
	if attachment then
		containers[#containers + 1] = attachment
		for _, child in attachment:GetChildren() do
			containers[#containers + 1] = child
		end
	end

	local direct = primary:FindFirstChild("CrateTopoUI")
	if direct then
		containers[#containers + 1] = direct
	end

	local model = state.model
	if model then
		containers[#containers + 1] = model
	end

	for _, container in containers do
		if container then
			setMoneyLabel(container, text)
		end
	end
end

local function refreshCrateUi(state: CrateState)
	local targetText: string
	if state.status == "purchased" then
		targetText = `HP: {math.max(0, math.floor(state.health + 0.5))}`
	else
		targetText = formatPrice(state.price)
	end

	if state.lastUiText ~= targetText then
		setCrateUiMoneyText(state, targetText)
		state.lastUiText = targetText
	end
end

local function ensureCrateHighlight(state: CrateState): Highlight?
	local existing = state.highlight
	if existing and existing.Parent then
		return existing
	end

	local model = state.model
	if not model then
		state.highlight = nil
		return nil
	end

	local newHighlight = Instance.new("Highlight")
	local highlight = newHighlight :: Highlight
	highlight.Name = "CrateTopoHighlight"
	highlight.FillTransparency = 1
	highlight.FillColor = HIGHLIGHT_DEFAULT_COLOR
	highlight.OutlineTransparency = 0
	highlight.OutlineColor = HIGHLIGHT_DEFAULT_COLOR
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Enabled = false
	highlight.Adornee = model
	highlight.Parent = model
	state.highlight = highlight
	return highlight
end

local function setCrateHighlightState(state: CrateState, enabled: boolean, color: Color3?)
	local highlight = ensureCrateHighlight(state)
	if not highlight then
		return
	end

	if color == HIGHLIGHT_PURCHASED_COLOR then
		highlight.Enabled = false
		highlight.FillTransparency = 1
		highlight.OutlineColor = HIGHLIGHT_DEFAULT_COLOR
		highlight.FillColor = HIGHLIGHT_DEFAULT_COLOR
		return
	end

	highlight.Enabled = enabled
	if color then
		highlight.OutlineColor = color
		highlight.FillColor = color
	elseif not enabled then
		highlight.OutlineColor = HIGHLIGHT_DEFAULT_COLOR
		highlight.FillColor = HIGHLIGHT_DEFAULT_COLOR
	end

	if not enabled then
		highlight.FillTransparency = 1
	elseif color == HIGHLIGHT_PURCHASED_COLOR then
		highlight.FillTransparency = 1
	else
		highlight.FillTransparency = 0.65
	end
end

local function flashCrateHighlight(state: CrateState, color: Color3?)
	local highlight = ensureCrateHighlight(state)
	if not highlight then
		return
	end

	local flashColor = color or HIGHLIGHT_DAMAGE_COLOR
	highlight.OutlineColor = flashColor
	highlight.FillColor = flashColor
	highlight.Enabled = true
	highlight.FillTransparency = 0.3

	task.delay(0.3, function()
		if state.highlight ~= highlight or not highlight.Parent then
			return
		end

		if state.status == "purchased" then
			highlight.OutlineColor = HIGHLIGHT_DEFAULT_COLOR
			highlight.FillColor = HIGHLIGHT_DEFAULT_COLOR
			highlight.FillTransparency = 1
			highlight.Enabled = false
		else
			highlight.OutlineColor = HIGHLIGHT_DEFAULT_COLOR
			highlight.FillColor = HIGHLIGHT_DEFAULT_COLOR
			highlight.FillTransparency = 1
			highlight.Enabled = false
		end
	end)
end

local function getHitAnimation(): Animation
	local cached = hitAnimationTemplate
	if cached then
		return cached
	end

	local animation = Instance.new("Animation")
	animation.Name = "CrateTopoHitAnimation"
	animation.AnimationId = HIT_ANIMATION_ID
	hitAnimationTemplate = animation
	return animation
end

local function ensureCrateAnimator(model: Model): Animator?
	local controller = model:FindFirstChildWhichIsA("AnimationController", true)
	if not controller then
		return nil
	end

	local animator = controller:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end

	local newAnimator = Instance.new("Animator")
	newAnimator.Name = "CrateTopoAnimator"
	newAnimator.Parent = controller
	return newAnimator
end

local function playCrateHitAnimation(state: CrateState)
	local model = state.model
	if not model then
		return
	end

	local animator = ensureCrateAnimator(model)
	if not animator then
		return
	end

	local track = state.hitAnimationTrack
	if not track or track.Parent ~= animator then
		if track then
			track:Destroy()
		end

		local ok, loadedTrackOrError = pcall(function()
			return animator:LoadAnimation(getHitAnimation())
		end)
		if not ok then
			warn(string.format("[CrateTopoService] Error al cargar animación de golpe: %s", tostring(loadedTrackOrError)))
			state.hitAnimationTrack = nil
			return
		end

		local loadedTrack = loadedTrackOrError :: AnimationTrack
		loadedTrack.Name = "CrateTopoHitTrack"
		loadedTrack.Looped = false
		loadedTrack.Priority = Enum.AnimationPriority.Action
		state.hitAnimationTrack = loadedTrack
		track = loadedTrack
	end

	if not track then
		return
	end

	local okPlay, playError = pcall(function()
		if track.IsPlaying then
			track:Stop(0)
		end
		track:Play(HIT_ANIMATION_FADE_TIME, 1, HIT_ANIMATION_SPEED)
		if track.TimePosition ~= 0 then
			track.TimePosition = 0
		end
	end)

	if not okPlay then
		warn(string.format("[CrateTopoService] Error al reproducir animación de golpe: %s", tostring(playError)))
	end
end

local function updateCrateAttributes(state: CrateState)
	local model = state.model
	if not model then
		return
	end

	model:SetAttribute("CrateTopoHealth", state.health)
	model:SetAttribute("CrateTopoMaxHealth", state.maxHealth)
	model:SetAttribute("CrateTopoOwnerId", state.ownerId)
	model:SetAttribute("CrateTopoPurchased", state.status == "purchased")
end

local function createCrateState(
	runner: SlotRunner,
	definition: NormalizedCrateDefinition,
	model: Model,
	primary: BasePart,
	hiddenCFrame: CFrame,
	visibleCFrame: CFrame
): CrateState
	local crateId = HttpService:GenerateGUID(false)
	local controller = runner.controller
	local slotIndex = controller.slotIndex
	local ownerId = controller.ownerId
	local maxHealth = math.max(1, math.floor(definition.maxHealth or serviceState.settings.maxHealth or DEFAULT_SETTINGS.maxHealth))

	local rewards = definition.rewards and table.clone(definition.rewards) or nil
	if controller.rewardOverrides then
		rewards = controller.rewardOverrides
	end

	local state: CrateState = {
		id = crateId,
		definition = definition,
		runner = runner,
		controller = controller,
		model = model,
		primary = primary,
		hiddenCFrame = hiddenCFrame,
		visibleCFrame = visibleCFrame,
		status = "hidden",
		price = definition.price,
		ownerId = ownerId,
		slotIndex = slotIndex,
		maxHealth = maxHealth,
		health = maxHealth,
		rewards = rewards,
		spawnTime = os.clock(),
		fullyExposedAt = nil,
		purchasedAt = nil,
		purchaserUserId = nil,
		highlight = nil,
		lastUiText = nil,
		hitAnimationTrack = nil,
	}

	serviceState.cratesById[crateId] = state
	runner.currentState = state

	model:SetAttribute("CrateTopoId", definition.id)
	model:SetAttribute("CrateTopoInstanceId", crateId)
	model:SetAttribute("CrateTopoDefinitionId", definition.id)
	model:SetAttribute("CrateTopoName", definition.name)
	model:SetAttribute("CrateTopoPrice", definition.price)
	model:SetAttribute("CrateTopoAsset", definition.asset)
	model:SetAttribute("CrateTopoSlotPart", runner.part.Name)
	if slotIndex then
		model:SetAttribute("CrateTopoSlotIndex", slotIndex)
	end

	updateCrateAttributes(state)
	refreshCrateUi(state)

	return state
end

local function cleanupCrateState(state: CrateState, destroyModel: boolean)
	serviceState.cratesById[state.id] = nil

	local runner = state.runner
	if runner and runner.currentState == state then
		runner.currentState = nil
	end
	if runner and runner.currentModel == state.model then
		runner.currentModel = nil
	end

	if destroyModel then
		local model = state.model
		if model then
			model:Destroy()
		end
	end

	local highlight = state.highlight
	if highlight then
		state.highlight = nil
		if highlight.Parent then
			highlight:Destroy()
		end
	end

	local hitTrack = state.hitAnimationTrack
	if hitTrack then
		state.hitAnimationTrack = nil
		if hitTrack.IsPlaying then
			hitTrack:Stop(0)
		end
		hitTrack:Destroy()
	end

	state.model = nil
	state.primary = nil
	state.status = "destroyed"
	state.lastUiText = nil
end

local function removeStoredPlacementEntry(player: Player, entryId: string?)
	if typeof(entryId) ~= "string" or entryId == "" then
		return
	end

	Profiles.Mutate(player, function(profileData)
		if typeof(profileData) ~= "table" then
			return nil
		end

		local placementState = profileData.placement
		if typeof(placementState) ~= "table" then
			return nil
		end

		local objects = placementState.objects
		if typeof(objects) ~= "table" then
			return nil
		end

		for index = #objects, 1, -1 do
			local entry = objects[index]
			if typeof(entry) == "table" and entry.id == entryId and entry.stored == true then
				table.remove(objects, index)
				break
			end
		end

		return nil
	end)
end

local function grantPlacementReward(player: Player, assetId: string): boolean
	local ok, definitionOrMessage = pcall(PlacementAssetRegistry.Get, assetId)
	if not ok or definitionOrMessage == nil then
		warn(`[CrateTopoService] Recompensa "{assetId}" no registrada: {definitionOrMessage}`)
		return false
	end

	local adjustResult = PlacementInventory.Adjust(player, assetId, 1, 1)
	if not adjustResult then
		warn(`[CrateTopoService] No se pudo actualizar el inventario de placement para {player.Name} con "{assetId}"`)
		return false
	end

	local storedEntryId = nil
	local createdEntries = (adjustResult :: any).storedEntryIds
	if typeof(createdEntries) == "table" and #createdEntries > 0 then
		storedEntryId = createdEntries[#createdEntries]
	end

	local success, payload = PlacementService.GrantPlacementTool(player, assetId, storedEntryId, adjustResult.level)
	if not success then
		local message = if typeof(payload) == "string" then payload else "Fallo desconocido"
		warn(`[CrateTopoService] No se pudo otorgar la herramienta "{assetId}" a {player.Name}: {message}`)
		PlacementInventory.Adjust(player, assetId, -1, adjustResult.level)
		if storedEntryId then
			removeStoredPlacementEntry(player, storedEntryId)
		end
		return false
	end

	return true
end


local function buildCratePool(settings, cratesData: any): ({ NormalizedCrateDefinition }, number)
	local pool: { NormalizedCrateDefinition } = {}
	local totalWeight = 0

	local function addEntry(key: any, raw: any)
		if typeof(raw) ~= "table" then
			return
		end

		local rawName = sanitizeString(raw.name)
		local keyName = if typeof(key) == "string" then sanitizeString(key) else nil
		local name = rawName or keyName or sanitizeString(raw.asset) or settings.assetName
		if not name then
			return
		end

		local asset = sanitizeString(raw.asset) or name or settings.assetName
		if not asset then
			return
		end

		local price = sanitizeNumber(raw.price, 0, 0) or 0
		local weight = sanitizeNumber(raw.weight, 1, 0) or 1
		if weight <= 0 then
			return
		end

		local healthValue = sanitizeNumber(raw.health, nil, 1) or sanitizeNumber(raw.maxHealth, nil, 1)
		local resolvedHealthBase = healthValue
		if not resolvedHealthBase then
			resolvedHealthBase = settings.maxHealth
		end
		local resolvedHealth = math.max(1, math.floor((resolvedHealthBase or DEFAULT_SETTINGS.maxHealth) + 0.5))

		local rewardsTable = nil
		if typeof(raw.Rewards) == "table" then
			rewardsTable = table.clone(raw.Rewards)
		end

		local entry: NormalizedCrateDefinition = {
			id = keyName or name,
			name = name,
			price = price,
			asset = asset,
			weight = weight,
			maxHealth = resolvedHealth,
			cooldownRange = sanitizeRange(raw.cooldownRange, nil),
			stayDurationRange = sanitizeRange(raw.stayDurationRange, nil),
			riseTime = sanitizeNumber(raw.riseTime, nil, 0),
			fallTime = sanitizeNumber(raw.fallTime, nil, 0),
			hiddenDepth = sanitizeNumber(raw.hiddenDepth, nil, 0),
			surfaceOffset = sanitizeNumber(raw.surfaceOffset, nil, nil),
			rewards = rewardsTable,
		}

		pool[#pool + 1] = entry
		totalWeight += weight
	end

	if typeof(cratesData) == "table" then
		local isArray = (#cratesData > 0)
		if isArray then
			for index, value in cratesData do
				addEntry(index, value)
			end
		else
			for key, value in cratesData do
				addEntry(key, value)
			end
		end
	end

	if totalWeight <= 0 then
		local fallbackName = settings.assetName or "CrateProto"
		pool[1] = {
			id = fallbackName,
			name = fallbackName,
			price = 0,
			asset = fallbackName,
			weight = 1,
			maxHealth = settings.maxHealth or DEFAULT_SETTINGS.maxHealth,
			cooldownRange = nil,
			stayDurationRange = nil,
			riseTime = nil,
			fallTime = nil,
			hiddenDepth = nil,
			surfaceOffset = nil,
			rewards = nil,
		}
		totalWeight = 1
	end

	return pool, totalWeight
end

local function buildGunRewardTable(ammoData: any): { [string]: number }
	local rewards: { [string]: number } = {}
	if typeof(ammoData) ~= "table" then
		return rewards
	end

	for name, entry in ammoData do
		if typeof(name) == "string" and name ~= "" then
			local weight = 1
			if typeof(entry) == "table" then
				local dataBlock = entry.data or entry.Data
				if typeof(dataBlock) == "table" then
					local priceValue = dataBlock.Price or dataBlock.price
					local numeric = tonumber(priceValue)
					if numeric and numeric > 0 then
						weight = math.max(1, math.floor(numeric + 0.5))
					end
				end
			end
			rewards[name] = weight
		end
	end

	return rewards
end

local function isSlotPart(instance: Instance): boolean
	if not instance:IsA("BasePart") then
		return false
	end

	local attribute = instance:GetAttribute("CrateTopoSlot")
	if attribute == false then
		return false
	end

	if attribute == true then
		return true
	end

	return string.match(instance.Name, "^Slot%d+") ~= nil
end

local function extractSlotNumber(part: BasePart): number?
	local digits = string.match(part.Name, "(%d+)$")
	if digits then
		return tonumber(digits)
	end
	return nil
end

local function compareRunners(a: SlotRunner, b: SlotRunner): boolean
	local aIndex = extractSlotNumber(a.part)
	local bIndex = extractSlotNumber(b.part)
	if aIndex and bIndex then
		if aIndex ~= bIndex then
			return aIndex < bIndex
		end
	elseif aIndex then
		return true
	elseif bIndex then
		return false
	end
	return a.part.Name < b.part.Name
end

local function selectCrateDefinition(rng: Random): NormalizedCrateDefinition?
	local totalWeight = serviceState.totalWeight
	if totalWeight <= 0 then
		return nil
	end

	local roll = rng:NextNumber(0, totalWeight)
	local accumulator = 0
	for _, entry in ipairs(serviceState.cratePool) do
		accumulator += entry.weight
		if roll <= accumulator then
			return entry
		end
	end

	return serviceState.cratePool[#serviceState.cratePool]
end

local function randomFromRange(rng: Random, range: Range?, fallback: number): number
	if range then
		local minValue = math.min(range.X, range.Y)
		local maxValue = math.max(range.X, range.Y)
		return rng:NextNumber(minValue, maxValue)
	end
	return fallback
end

local function waitWithAbort(runner: SlotRunner, duration: number): boolean
	local elapsed = 0
	while elapsed < duration do
		if runner.destroyed or not runner.active or not runner.controller.active then
			return false
		end

		local remaining = duration - elapsed
		local step = if remaining > 0.35 then 0.35 else remaining
		local delta = task.wait(step)
		elapsed += delta
	end
	return runner.active and not runner.destroyed and runner.controller.active
end

local function waitVisibleDuration(runner: SlotRunner, state: CrateState, duration: number): boolean
	local elapsed = 0
	while elapsed < duration do
		if runner.destroyed or not runner.active or not runner.controller.active then
			return false
		end

		if state.status == "purchased" or state.status == "destroyed" or state.model == nil then
			return false
		end

		local remaining = duration - elapsed
		local step = if remaining > 0.3 then 0.3 else remaining
		local delta = task.wait(step)
		elapsed += delta
	end

	return runner.active and not runner.destroyed and runner.controller.active and state.status ~= "purchased"
end

local function cleanupRunnerModel(runner: SlotRunner)
	local currentTween = runner.currentTween
	if currentTween then
		runner.currentTween = nil
		currentTween:Cancel()
	end

	local model = runner.currentModel
	if model then
		runner.currentModel = nil
		model:Destroy()
	end
end


local function spawnCrateModel(
	runner: SlotRunner,
	definition: NormalizedCrateDefinition,
	assetTemplates: { [string]: Model }?
): (Model?, BasePart?)
	local controller = runner.controller
	local templateSet = assetTemplates or controller.assetTemplates or serviceState.assetTemplates
	if not templateSet then
		return nil, nil
	end

	local template = templateSet[definition.asset]
	if not template then
		local missingKey = string.format("%s::%s", controller.folderName, definition.asset)
		if not serviceState.missingAssets[missingKey] then
			serviceState.missingAssets[missingKey] = true
			warn(string.format("Asset '%s' no encontrado para %s.", definition.asset, controller.folderName))
		end
		return nil, nil
	end

	local model = template:Clone()
	local primary = model.PrimaryPart
	if not primary then
		primary = model:FindFirstChildWhichIsA("BasePart", true)
		if primary then
			model.PrimaryPart = primary
		end
	end

	if not primary then
		model:Destroy()
		warn(string.format("El modelo '%s' no tiene una PrimaryPart válida.", definition.asset))
		return nil, nil
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end

	model.Parent = controller.folder
	attachCrateUi(primary, definition)
	return model, primary
end

local function computeCrateCFrames(part: BasePart, primary: BasePart, definition: NormalizedCrateDefinition, settings)
	local partCFrame = part.CFrame
	local up = partCFrame.UpVector
	local right = partCFrame.RightVector
	local look = partCFrame.LookVector

	local surfaceOffset = definition.surfaceOffset
	if surfaceOffset == nil then
		surfaceOffset = settings.surfaceOffset
	end

	local partHalfHeight = part.Size.Y * 0.5
	local surfacePosition = partCFrame.Position + up * (partHalfHeight + (surfaceOffset or 0))

	local crateHalfHeight = primary.Size.Y * 0.5
	local visiblePosition = surfacePosition + up * crateHalfHeight

	local hiddenDepthCandidate = definition.hiddenDepth
	if hiddenDepthCandidate == nil then
		hiddenDepthCandidate = settings.hiddenDepth
	end
	local hiddenDepth = tonumber(hiddenDepthCandidate) or 0
	if hiddenDepth < 0 then
		hiddenDepth = 0
	end

	local hiddenPosition = surfacePosition - up * (crateHalfHeight + hiddenDepth)

	local visibleCFrame = CFrame.fromMatrix(visiblePosition, right, up, look)
	local hiddenCFrame = CFrame.fromMatrix(hiddenPosition, right, up, look)

	return hiddenCFrame, visibleCFrame
end

local function pickRewardFromTable(rewards: { [string]: any }?, rng: Random?): string?
	if typeof(rewards) ~= "table" then
		return nil
	end

	local entries = table.create(8)
	local totalWeight = 0
	for rewardName, rawWeight in rewards do
		if typeof(rewardName) == "string" then
			local numericWeight = tonumber(rawWeight)
			if numericWeight and numericWeight > 0 then
				totalWeight += numericWeight
				entries[#entries + 1] = {
					name = rewardName,
					weight = numericWeight,
				}
			end
		end
	end

	if totalWeight <= 0 or #entries == 0 then
		return nil
	end

	local randomGenerator = rng or serviceState.globalRng
	local roll = randomGenerator:NextNumber(0, totalWeight)
	local accumulated = 0
	for _, entry in entries do
		accumulated += entry.weight
		if roll <= accumulated then
			return entry.name
		end
	end

	return entries[#entries].name
end

local function selectCrateReward(state: CrateState): string?
	local rewards = state.rewards
	return pickRewardFromTable(rewards, state.runner and state.runner.rng)
end

local function buildCrateDetectionDetail(state: CrateState): { [string]: any }?
	if state.status ~= "exposed" and state.status ~= "purchased" then
		return nil
	end

	local primary = state.primary
	if not primary or primary.Parent == nil then
		return nil
	end

	local position = primary.Position
	local extents = primary.Size * 0.5
	return {
		id = state.id,
		targetKind = "CrateTopo",
		crateName = state.definition.name,
		definitionId = state.definition.id,
		position = position,
		attackAnchor = position,
		extents = extents,
		price = state.price,
		cratePrice = state.price,
		health = state.health,
		maxHealth = state.maxHealth,
		purchased = state.status == "purchased",
		slotIndex = state.slotIndex,
		ownerId = state.ownerId,
	}
end

local function resolvePlayerFromMetadata(metadata: { [string]: any }?, ownerId: number?): Player?
	if typeof(metadata) == "table" then
		local metadataPlayer = metadata.player
		if typeof(metadataPlayer) == "Instance" and metadataPlayer:IsA("Player") then
			return metadataPlayer
		end

		local attackerUserId = metadata.attacker
		if typeof(attackerUserId) == "number" then
			local playerFromAttacker = Players:GetPlayerByUserId(attackerUserId)
			if playerFromAttacker then
				return playerFromAttacker
			end
		end
	end

	if typeof(ownerId) == "number" then
		local ownerPlayer = Players:GetPlayerByUserId(ownerId)
		if ownerPlayer then
			return ownerPlayer
		end
	end

	return nil
end

local function attemptCratePurchase(state: CrateState, player: Player?): (boolean, { [string]: any }?)
	if state.status == "purchased" then
		return true, { purchased = true, price = 0 }
	end

	local ownerId = state.ownerId
	local userId = if player then player.UserId else nil
	if typeof(ownerId) == "number" then
		if ownerId ~= userId then
			return false, {
				reason = "not_owner",
				ownerId = ownerId,
			}
		end
	end

	if state.price <= 0 then
		state.status = "purchased"
		state.purchasedAt = os.clock()
		state.purchaserUserId = userId
		updateCrateAttributes(state)
		refreshCrateUi(state)
		setCrateHighlightState(state, true, HIGHLIGHT_PURCHASED_COLOR)
		flashCrateHighlight(state, HIGHLIGHT_PURCHASED_COLOR)
		return true, {
			purchased = true,
			price = 0,
		}
	end

	if not player then
		return false, {
			reason = "player_required",
		}
	end

	local result = Profiles.Mutate(player, function(profileData)
		profileData.Money = profileData.Money or 0
		if profileData.Money < state.price then
			return { success = false, balance = profileData.Money }
		end

		profileData.Money -= state.price
		return { success = true, balance = profileData.Money }
	end)

	if not result then
		return false, {
			reason = "profile_unavailable",
		}
	end

	if result.success ~= true then
		return false, {
			reason = "insufficient_funds",
			balance = result.balance,
		}
	end

	state.status = "purchased"
	state.purchasedAt = os.clock()
	state.purchaserUserId = userId
	updateCrateAttributes(state)
	refreshCrateUi(state)
	setCrateHighlightState(state, true, HIGHLIGHT_PURCHASED_COLOR)
	flashCrateHighlight(state, HIGHLIGHT_PURCHASED_COLOR)

	return true, {
		purchased = true,
		price = state.price,
		balance = result.balance,
	}
end

local function mergeInfo(target: { [string]: any }, source: { [string]: any }?)
	if typeof(source) ~= "table" then
		return
	end

	for key, value in source do
		target[key] = value
	end
end

local function handleCrateDestroyed(state: CrateState, player: Player?): string?
	state.status = "destroyed"
	state.health = 0
	updateCrateAttributes(state)
	refreshCrateUi(state)

	local rewardName = selectCrateReward(state)
	if rewardName and player then
		if not grantPlacementReward(player, rewardName) then
			rewardName = nil
		end
	end

	local fallTime = state.definition.fallTime or serviceState.settings.fallTime or DEFAULT_SETTINGS.fallTime
	task.spawn(function()
		local runner = state.runner
		local primary = state.primary
		if runner and not runner.destroyed and primary and primary.Parent then
			local tween = TweenService:Create(
				primary,
				TweenInfo.new(math.max(0.08, fallTime), Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ CFrame = state.hiddenCFrame }
			)
			runner.currentTween = tween
			tween:Play()
			tween.Completed:Wait()
			if runner.currentTween == tween then
				runner.currentTween = nil
			end
		end

		cleanupCrateState(state, true)
	end)

	return rewardName
end

local function runnerLoop(runner: SlotRunner)
	local controller = runner.controller
	local rng = runner.rng
	local settings = serviceState.settings

	local initialDelay = randomFromRange(rng, settings.initialDelayRange, settings.fallbackCooldown)
	if not waitWithAbort(runner, initialDelay) then
		cleanupRunnerModel(runner)
		runner.active = false
		return
	end

	while runner.active and not runner.destroyed and controller.active do
		local crateState: CrateState? = nil
		local function clearCrateState(destroyModel: boolean)
			if crateState then
				cleanupCrateState(crateState, destroyModel)
				crateState = nil
			end
		end

		local definition = selectCrateDefinition(rng)
		local cooldownRange = settings.cooldownRange
		if definition and definition.cooldownRange then
			cooldownRange = definition.cooldownRange
		end

		local cooldownDuration = randomFromRange(rng, cooldownRange, settings.fallbackCooldown)
		if not waitWithAbort(runner, cooldownDuration) then
			clearCrateState(true)
			break
		end

		if not runner.active or runner.destroyed or not controller.active then
			clearCrateState(true)
			break
		end

		if not definition then
			if not waitWithAbort(runner, settings.fallbackCooldown) then
				clearCrateState(true)
				break
			end
			continue
		end

		local model, primary = spawnCrateModel(runner, definition, runner.controller.assetTemplates)
		if not model or not primary then
			if not waitWithAbort(runner, settings.fallbackCooldown) then
				clearCrateState(true)
				break
			end
			continue
		end

		runner.currentModel = model

		local hiddenCFrame, visibleCFrame = computeCrateCFrames(runner.part, primary, definition, settings)
		model:PivotTo(hiddenCFrame)

		crateState = createCrateState(runner, definition, model, primary, hiddenCFrame, visibleCFrame)
		if crateState then
			crateState.status = "rising"
			crateState.spawnTime = os.clock()
			updateCrateAttributes(crateState)
			refreshCrateUi(crateState)
			setCrateHighlightState(crateState, false, nil)
		end

		local riseTime = math.max(0.05, definition.riseTime or settings.riseTime)
		local fallTime = math.max(0.05, definition.fallTime or settings.fallTime)
		local stayDuration = randomFromRange(rng, definition.stayDurationRange or settings.stayDurationRange, 5)

		local riseTween = TweenService:Create(
			primary,
			TweenInfo.new(riseTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = visibleCFrame }
		)
		runner.currentTween = riseTween
		riseTween:Play()
		local riseState = riseTween.Completed:Wait()
		runner.currentTween = nil

		local continueCycle = riseState == Enum.PlaybackState.Completed
			and runner.active
			and not runner.destroyed
			and controller.active

		if not continueCycle then
			clearCrateState(true)
			cleanupRunnerModel(runner)
			if not runner.active or runner.destroyed or not controller.active then
				break
			end
			continue
		end

		if crateState then
			crateState.status = "exposed"
			crateState.fullyExposedAt = os.clock()
			updateCrateAttributes(crateState)
			refreshCrateUi(crateState)
		end

		local stayedVisible = false
		if crateState then
			stayedVisible = waitVisibleDuration(runner, crateState, stayDuration)
		end

		if crateState and stayedVisible then
			crateState.status = "hiding"
			updateCrateAttributes(crateState)

			local fallTween = TweenService:Create(
				primary,
				TweenInfo.new(fallTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ CFrame = hiddenCFrame }
			)
			runner.currentTween = fallTween
			fallTween:Play()
			fallTween.Completed:Wait()
			runner.currentTween = nil

			clearCrateState(true)
		else
			if crateState and crateState.status == "purchased" then
				while runner.active
					and not runner.destroyed
					and controller.active do
					if crateState.status ~= "purchased" or crateState.model == nil then
						break
					end
					task.wait(0.2)
				end
			end

			if crateState then
				if crateState.status == "destroyed" or crateState.model == nil then
					crateState = nil
				else
					clearCrateState(true)
				end
			end
		end

		cleanupRunnerModel(runner)

		if not runner.active or runner.destroyed or not controller.active then
			break
		end
	end

	cleanupRunnerModel(runner)
	runner.active = false
end

local function startRunner(runner: SlotRunner)
	if runner.destroyed or runner.active then
		return
	end

	runner.active = true
	runner.thread = task.spawn(runnerLoop, runner)
end

local function stopRunner(runner: SlotRunner, immediate: boolean)
	if not runner.active and not immediate then
		return
	end

	runner.active = false
	if immediate then
		cleanupRunnerModel(runner)
	end
end

local function removeRunner(controller: SlotController, part: BasePart, immediate: boolean)
	local runner = controller.runners[part]
	if not runner then
		return
	end

	controller.runners[part] = nil

	for index, entry in ipairs(controller.runnerOrder) do
		if entry == runner then
			table.remove(controller.runnerOrder, index)
			break
		end
	end

	runner.destroyed = true
	stopRunner(runner, true)

	for _, connection in runner.connections do
		connection:Disconnect()
	end
	runner.connections = {}

	if immediate then
		cleanupRunnerModel(runner)
	end
end

local function createRunner(controller: SlotController, part: BasePart): SlotRunner
	local runner: SlotRunner = {
		part = part,
		controller = controller,
		active = false,
		destroyed = false,
		thread = nil,
		connections = {},
		rng = Random.new(serviceState.globalRng:NextInteger(1, 1_000_000)),
		currentModel = nil,
		currentTween = nil,
		locked = false,
		currentState = nil,
	}

	runner.connections[#runner.connections + 1] = part.AncestryChanged:Connect(function(_, parent)
		if not parent then
			removeRunner(controller, part, true)
		end
	end)

	return runner
end

local function attachRunner(controller: SlotController, part: BasePart)
	if controller.destroyed then
		return
	end

	if controller.runners[part] then
		return
	end

	local runner = createRunner(controller, part)
	controller.runners[part] = runner
	controller.runnerOrder[#controller.runnerOrder + 1] = runner
	table.sort(controller.runnerOrder, compareRunners)

	if controller.active then
		startRunner(runner)
	end
end

local function destroyController(controller: SlotController)
	if controller.destroyed then
		return
	end

	controller.destroyed = true
	controller.active = false

	local snapshot = table.clone(controller.runnerOrder)
	for _, runner in ipairs(snapshot) do
		removeRunner(controller, runner.part, true)
	end

	for _, connection in controller.connections do
		connection:Disconnect()
	end
	controller.connections = {}

	serviceState.controllers[controller.key] = nil
end

type SlotControllerOptions = {
	rewardOverrides: { [string]: number }?,
	slotWhitelist: { [number]: boolean }?,
	assetTemplates: { [string]: Model }?,
}

local function createSlotController(slot: PlotSlot, folderName: string, options: SlotControllerOptions?): SlotController?
	local slotFolder = slot:GetFolder()
	if not slotFolder then
		return nil
	end

	local crateFolder = slotFolder:FindFirstChild(folderName)
	if not crateFolder or not crateFolder:IsA("Folder") then
		return nil
	end

	local slotIndex: number? = nil
	local ok, value = pcall(function()
		return (slot :: any).index
	end)
	if ok and typeof(value) == "number" then
		slotIndex = value
	end

	if options and options.slotWhitelist then
		if not slotIndex or not options.slotWhitelist[slotIndex] then
			return nil
		end
	end

	local controllerKey = string.format("%s::%s", slotFolder:GetFullName(), folderName)
	local rewardOverrides = if options then options.rewardOverrides else nil
	local assetTemplates = if options and options.assetTemplates then options.assetTemplates else serviceState.assetTemplates
	if not assetTemplates then
		return nil
	end

	local controller: SlotController = {
		key = controllerKey,
		slot = slot,
		slotIndex = slotIndex,
		folderName = folderName,
		folder = crateFolder,
		rewardOverrides = rewardOverrides,
		assetTemplates = assetTemplates,
		ownerId = slot:GetOwnerId(),
		active = false,
		destroyed = false,
		runners = {},
		runnerOrder = {},
		connections = {},
		rng = Random.new(serviceState.globalRng:NextInteger(1, 1_000_000)),
	}

	local function processInstance(instance: Instance)
		if isSlotPart(instance) then
			attachRunner(controller, instance :: BasePart)
		end
		for _, descendant in instance:GetDescendants() do
			if isSlotPart(descendant) then
				attachRunner(controller, descendant :: BasePart)
			end
		end
	end

	controller.connections[#controller.connections + 1] = crateFolder.ChildAdded:Connect(function(instance)
		processInstance(instance)
	end)

	controller.connections[#controller.connections + 1] = crateFolder.ChildRemoved:Connect(function(instance)
		if instance:IsA("BasePart") then
			removeRunner(controller, instance :: BasePart, true)
		else
			for _, descendant in instance:GetDescendants() do
				if descendant:IsA("BasePart") then
					removeRunner(controller, descendant :: BasePart, true)
				end
			end
		end
	end)

	controller.connections[#controller.connections + 1] = crateFolder.AncestryChanged:Connect(function(_, parent)
		if not parent then
			destroyController(controller)
		end
	end)

	processInstance(crateFolder)

	return controller
end

local function startController(controller: SlotController)
	if controller.destroyed or controller.active then
		return
	end

	controller.active = true
	for _, runner in ipairs(controller.runnerOrder) do
		startRunner(runner)
	end
end

local function stopController(controller: SlotController, immediate: boolean)
	if controller.destroyed then
		return
	end

	if not controller.active and not immediate then
		return
	end

	controller.active = false
	for _, runner in ipairs(controller.runnerOrder) do
		stopRunner(runner, true)
	end
end

local function updateControllerOwnership(controller: SlotController, forceStart: boolean)
	if controller.destroyed then
		return
	end

	local ownerId = controller.slot:GetOwnerId()
	if ownerId ~= controller.ownerId then
		controller.ownerId = ownerId
		if ownerId then
			startController(controller)
		else
			stopController(controller, true)
		end
	elseif forceStart and ownerId and not controller.active then
		startController(controller)
	end
end

local function refreshControllers(forceStart: boolean)
	for key, controller in pairs(serviceState.controllers) do
		if controller.destroyed then
			serviceState.controllers[key] = nil
		else
			updateControllerOwnership(controller, forceStart)
		end
	end
end

local function registerController(controller: SlotController?)
	if not controller then
		return
	end

	serviceState.controllers[controller.key] = controller
end

local function buildControllers()
	local slots = PlotRegistry.GetSlots()
	local gunRewards = serviceState.gunRewards
	local gunTemplates = serviceState.gunAssetTemplates
	local enableGunControllers = gunRewards ~= nil and next(gunRewards) ~= nil and gunTemplates ~= nil

	for _, slot in slots do
		registerController(createSlotController(slot, DEFAULT_CRATE_FOLDER_NAME, nil))

		if enableGunControllers then
			registerController(
				createSlotController(slot, GUN_CRATE_FOLDER_NAME, {
					rewardOverrides = gunRewards,
					slotWhitelist = GUN_SLOT_WHITELIST,
					assetTemplates = gunTemplates,
				})
			)
		end
	end
end

local CrateTopoService = {}

function CrateTopoService.GetCrateTargetsForOwner(ownerUserId: number): { { [string]: any } }
	local results = {}
	if typeof(ownerUserId) ~= "number" then
		return results
	end

	for _, state in serviceState.cratesById do
		if state.ownerId == ownerUserId then
			local detail = buildCrateDetectionDetail(state)
			if detail then
				results[#results + 1] = detail
			end
		end
	end

	return results
end

function CrateTopoService.GetCrateState(crateId: string): CrateState?
	if typeof(crateId) ~= "string" then
		return nil
	end

	return serviceState.cratesById[crateId]
end

function CrateTopoService.ApplyDamage(crateId: string, amount: number, metadata: { [string]: any }?): (boolean, number?, number?, { [string]: any }?)
	if typeof(crateId) ~= "string" or crateId == "" then
		return false, nil, 0, { reason = "invalid_id" }
	end

	local state = serviceState.cratesById[crateId]
	if not state then
		return false, nil, 0, { reason = "not_found" }
	end

	if state.status == "destroyed" then
		return false, 0, 0, { reason = "already_destroyed" }
	end

	if state.status == "hidden" or state.status == "rising" or state.status == "hiding" then
		return false, state.health, 0, { reason = "not_visible" }
	end

	local ownerId = state.ownerId
	local player = resolvePlayerFromMetadata(metadata, ownerId)
	if typeof(ownerId) == "number" then
		if not player or player.UserId ~= ownerId then
			return false, state.health, 0, {
				reason = "not_owner",
				ownerId = ownerId,
			}
		end
	end

	local info = { crateId = crateId, price = state.price }
	if typeof(metadata) == "table" then
		local toolValue = metadata.tool
		if typeof(toolValue) == "string" then
			info.tool = toolValue
		end

		local referenceValue = metadata.reference
		if typeof(referenceValue) == "string" then
			info.reference = referenceValue
		end
	end

	local purchaseInfo = nil
	if state.status ~= "purchased" then
		local success, details = attemptCratePurchase(state, player)
		if not success then
			info.reason = details and details.reason or "purchase_failed"
			mergeInfo(info, details)
			return false, state.health, 0, info
		end
		purchaseInfo = details
		mergeInfo(info, details)
	end

	local numericAmount = math.max(0, math.floor(tonumber(amount) or 0))
	if numericAmount <= 0 then
		info.purchased = true
		return true, state.health, 0, info
	end

	local previousHealth = math.max(0, state.health)
	if previousHealth <= 0 then
		info.purchased = true
		return true, 0, 0, info
	end

	local newHealth = math.max(0, previousHealth - numericAmount)
	local appliedDamage = previousHealth - newHealth
	if appliedDamage <= 0 then
		info.purchased = true
		return true, state.health, 0, info
	end

	state.health = newHealth
	updateCrateAttributes(state)
	refreshCrateUi(state)
	playCrateHitAnimation(state)

	if newHealth <= 0 then
		local rewardName = handleCrateDestroyed(state, player)
		if rewardName then
			info.reward = rewardName
		end
	end

	info.purchased = true
	mergeInfo(info, purchaseInfo)

	return true, newHealth, appliedDamage, info
end

function CrateTopoService.Init(overrides: { [string]: any }?)
	if serviceState.initialized then
		return
	end

	local catalogTable = Catalog :: CatalogTable
	local settings = table.clone(DEFAULT_SETTINGS)
	applyCatalogDefaults(settings, catalogTable.Defaults)
	applyOverrides(settings, overrides)
	serviceState.settings = settings

	local assetFolder = resolveAssetsFolder(settings.assetFolderName)
	if not assetFolder then
		warn("Servicio de CrateTopo deshabilitado por falta de assets.")
		return
	end

	serviceState.assetFolder = assetFolder
	serviceState.assetTemplates = loadAssetTemplates(assetFolder)

	local gunAssetFolder = resolveAssetsFolder("GunCrates")
	serviceState.gunAssetFolder = gunAssetFolder
	if gunAssetFolder then
		serviceState.gunAssetTemplates = loadAssetTemplates(gunAssetFolder)
	else
		serviceState.gunAssetTemplates = nil
	end

	local pool, totalWeight = buildCratePool(settings, catalogTable.Crates)
	serviceState.cratePool = pool
	serviceState.totalWeight = totalWeight

	local gunRewards = buildGunRewardTable(AmmoBuildings)
	if gunRewards and next(gunRewards) ~= nil then
		serviceState.gunRewards = gunRewards
	else
		serviceState.gunRewards = nil
	end

	if totalWeight <= 0 then
		warn("No se encontraron crates configurados.")
		return
	end

	buildControllers()
	refreshControllers(true)

	serviceState.schedulerHandle = RunServiceScheduler.register(1, function()
		refreshControllers(false)
		return nil
	end)

	serviceState.initialized = true
end

return CrateTopoService
