--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local ModulesFolder = script.Parent
local WorkFolder = ModulesFolder.Parent
local PlacementFolder = WorkFolder:WaitForChild("Placement")

local PlotRegistry = require(PlacementFolder:WaitForChild("PlotRegistry"))
local PlacementWorld = require(PlacementFolder:WaitForChild("World"))
local RunServiceScheduler = require(ModulesFolder:WaitForChild("RunServiceScheduler"))
local BrainrotNavigationRegistry = require(ModulesFolder:WaitForChild("BrainrotNavigationRegistry"))
local MutationService = require(ModulesFolder:WaitForChild("MutationService"))
local Profiles = require(ServerScriptService.Work.Modules.Profiles)
local TourismPackets = require(ReplicatedStorage.Network.BrainrotTourismPackets)

local BrainrotData = require(ReplicatedStorage.Data.Brainrots)
local BuildingsData = require(ReplicatedStorage.Data.Buildings)
local AmmoBuildingsData = require(ReplicatedStorage.Data.AmmoBuildings)

local AssetsFolder = ReplicatedStorage:FindFirstChild("Assets")
local BrainrotAssetsFolder = AssetsFolder and AssetsFolder:FindFirstChild("Brainrots")

type PlacementServiceApi = {
	GetPlacementStateByEntity: (number) -> (any, any, string?),
	ApplyDamageToPlacement: (number, number) -> (boolean, { destroyed: boolean }?),
}

local placementServiceApi: PlacementServiceApi? = nil

local defaultsAny = (BrainrotData.Defaults or {}) :: { [string]: any }
local defaultAttack = (defaultsAny.attack or {}) :: { [string]: any }
local defaultReward = (defaultsAny.reward or {}) :: { [string]: any }

local MOVE_INTERVAL = 0.03
local DEFAULT_MOVE_SPEED = (defaultsAny.moveSpeed or 12) :: number
local DEFAULT_TOLERANCE = (defaultsAny.arrivalTolerance or 1.2) :: number
local DEFAULT_MAX_HEALTH = (defaultsAny.maxHealth or 1600) :: number
local DEFAULT_ATTACK_INTERVAL = (defaultAttack.interval or 2.4) :: number
local DEFAULT_ATTACK_DAMAGE = (defaultAttack.damage or 110) :: number
local DEFAULT_ATTACK_RADIUS = (defaultAttack.radius or 10) :: number
local DEFAULT_REWARD_MIN = ((defaultReward.money and defaultReward.money.min) or 150) :: number
local DEFAULT_REWARD_MAX = ((defaultReward.money and defaultReward.money.max) or 220) :: number
local DEFAULT_PROGRESSION_VALUE = (defaultReward.progression or 1) :: number

local COOLDOWN_RANGE = Vector2.new(1.0, 2.0)
local ATTACK_COOLDOWN_VARIATION = Vector2.new(0.6, 1.35)
local ATTACK_DAMAGE_VARIATION = Vector2.new(0.65, 1.15)
local BASE_AGENT_CAP = 2
local MAX_AGENT_CAP = 10
local PLACEMENTS_PER_EXTRA_AGENT = 2
local MAX_TOTAL_AGENT_CAP = 24
local MIN_SPAWN_COOLDOWN = 0.3
local DIFFICULTY_PERCENT_CAP = 1000
local DIFFICULTY_GAIN_PER_SECOND = 0.2
local HEALTH_SCALE_PER_PERCENT = 0.01
local MOVE_SPEED_SCALE_PER_PERCENT = 0.004
local ATTACK_DAMAGE_SCALE_PER_PERCENT = 0.01
local ATTACK_INTERVAL_REDUCTION_PER_PERCENT = 0.004
local MIN_ATTACK_INTERVAL = 0.25
local ASSET_REFRESH_INTERVAL = 0.4

local function clampDifficultyPercent(value: any): number
	local numeric = tonumber(value) or 0
	if numeric < 0 then
		numeric = 0
	elseif numeric > DIFFICULTY_PERCENT_CAP then
		numeric = DIFFICULTY_PERCENT_CAP
	end
	return numeric
end

local function getPlayerLabel(player: Player): string
	local displayName = player.DisplayName
	if typeof(displayName) == "string" and displayName ~= "" then
		return displayName
	end
	return player.Name
end

export type SpawnEntry = {
	name: string,
	position: Vector3,
	cframe: CFrame,
}

export type WaypointEntry = {
	name: string,
	position: Vector3,
	cframe: CFrame,
}

export type NavigationData = {
	name: string,
	spawns: { SpawnEntry },
	spawnPositions: { Vector3 },
	waypoints: { Vector3 },
	waypointEntries: { WaypointEntry },
	waypointGraph: { [number]: { number } },
}

export type PlacementAsset = {
	entity: number,
	placementId: string,
	assetId: string,
	position: Vector3,
	health: number,
	maxHealth: number,
}

type BossDefinition = {
	name: string,
	tier: number,
	unlockScore: number,
	maxHealth: number,
	moveSpeed: number,
	arrivalTolerance: number,
	attackInterval: number,
	attackDamage: number,
	attackRadius: number,
	rewardMin: number,
	rewardMax: number,
	progressionValue: number,
}

type AgentState = "toBuilding" | "attacking"

type BrainrotAgent = {
	id: string,
	definition: BossDefinition,
	brainrotName: string,
	state: AgentState,
	path: { Vector3 },
	pathIndex: number,
	goalWaypointIndex: number,
	navEntry: NavigationData,
	spawnEntry: SpawnEntry,
	position: Vector3,
	targetPosition: Vector3,
	targetEntity: number,
	ownerUserId: number,
	moveSpeed: number,
	baseMoveSpeed: number,
	arrivalTolerance: number,
	attackInterval: number,
	attackCooldown: number,
	attackDamage: number,
	baseAttackDamage: number,
	attackRadius: number,
	maxHealth: number,
	health: number,
	rewardMoney: number,
	progressionValue: number,
	faceRotationAdjustment: CFrame?,
	attackAnchor: Vector3?,
}

type PlotController = {
	index: number,
	slot: any,
	navEntry: NavigationData,
	agents: { BrainrotAgent },
	activeTargets: { [number]: boolean },
	cooldown: number,
	agentCounter: number,
	defeated: boolean,
	difficultyPercent: number,
	progressAccumulator: number,
	trackedOwnerId: number?,
	lastPersistedPercent: number,
	paused: boolean,
	lastAssetsSnapshot: { PlacementAsset },
	cachedPlacements: { number },
	assetRefreshElapsed: number,
	hadAssets: boolean,
}

type SchedulerHandle = { _id: number }

local BrainrotTourismService = {}

local cleanupController: (PlotController) -> () = function(_controller: PlotController)
	return
end

local plotControllers: { [number]: PlotController } = {}
local activeHandle: SchedulerHandle? = nil
local brainrotAssets: { [string]: Model } = {}
local bossDefinitionCache: { [string]: BossDefinition } = {}
local rng = Random.new()
local agentById: { [string]: BrainrotAgent } = {}
local agentsByOwner: { [number]: { [string]: BrainrotAgent } } = {}
local agentControllerMap: { [string]: PlotController } = {}

type MutationEffect = { [string]: number }
type MutationTotals = { [string]: number }

-- Table of additive percentage modifiers each mutation applies to agent stats.
local MUTATION_MODIFIERS: { [string]: MutationEffect } = {
	Night = {
		moveSpeed = 0.15,
		attackDamage = 0.15,
	},
	BrainrotsCrazy = {
		moveSpeed = 0.5,
	},
}

local PROPERTY_APPLIERS: { [string]: (BrainrotAgent, number) -> boolean } = {
	moveSpeed = function(agent: BrainrotAgent, percent: number): boolean
		if not agent.baseMoveSpeed then
			agent.baseMoveSpeed = agent.moveSpeed
		end

		local desired = math.max(1, agent.baseMoveSpeed * (1 + percent))
		if math.abs(agent.moveSpeed - desired) > 1e-3 then
			agent.moveSpeed = desired
			return true
		end
		return false
	end,
	attackDamage = function(agent: BrainrotAgent, percent: number): boolean
		if not agent.baseAttackDamage then
			agent.baseAttackDamage = agent.attackDamage
		end

		local desired = math.max(1, math.floor(agent.baseAttackDamage * (1 + percent) + 0.5))
		if agent.attackDamage ~= desired then
			agent.attackDamage = desired
			return true
		end
		return false
	end,
}

local mutationConnection: RBXScriptConnection? = nil
local currentMutationTotals: MutationTotals = {}

local bossOrder: { string } = {}
do
	local order = BrainrotData.Order
	if typeof(order) == "table" then
		for _, name in ipairs(order) do
			bossOrder[#bossOrder + 1] = name
		end
	else
		for name, value in pairs(BrainrotData) do
			if typeof(value) == "table" and name ~= "Defaults" and name ~= "Order" then
				bossOrder[#bossOrder + 1] = name
			end
		end
		table.sort(bossOrder)
	end
end

local function randomInRange(range: Vector2): number
	return rng:NextNumber(math.min(range.X, range.Y), math.max(range.X, range.Y))
end

local function computeAgentCap(placementCount: number): number
	if placementCount <= 0 then
		return 0
	end

	local bonus = math.floor(math.max(placementCount - 1, 0) / PLACEMENTS_PER_EXTRA_AGENT)
	local cap = BASE_AGENT_CAP + bonus
	return math.clamp(cap, BASE_AGENT_CAP, MAX_AGENT_CAP)
end

local function gatherBrainrotAssets()
	if not BrainrotAssetsFolder then
		warn("BrainrotTourismService could not find ReplicatedStorage.Assets.Brainrots")
		return
	end

	brainrotAssets = {}
	for _, child in BrainrotAssetsFolder:GetChildren() do
		if child:IsA("Model") then
			brainrotAssets[child.Name] = child
		end
	end

	if next(brainrotAssets) == nil then
		warn("BrainrotTourismService did not find any usable brainrot models in ReplicatedStorage.Assets.Brainrots")
	end
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

local function computeFaceRotationAdjustment(model: Model, primary: BasePart): CFrame?
	local facePart = model:FindFirstChild("Face", true)
	if not facePart or not facePart:IsA("BasePart") then
		return nil
	end

	local faceRelative = primary.CFrame:ToObjectSpace((facePart :: BasePart).CFrame)
	local rotationOnly = CFrame.fromMatrix(Vector3.zero, faceRelative.RightVector, faceRelative.UpVector, faceRelative.LookVector)
	return rotationOnly:Inverse()
end

local function resolveBossDefinition(name: string): BossDefinition?
	local cached = bossDefinitionCache[name]
	if cached then
		return cached
	end

	local raw = BrainrotData[name]
	if typeof(raw) ~= "table" then
		return nil
	end

	local attack = raw.attack or {}
	local reward = raw.reward or {}

	local definition: BossDefinition = {
		name = name,
		tier = raw.tier or 1,
		unlockScore = raw.unlockScore or 0,
		maxHealth = raw.maxHealth or DEFAULT_MAX_HEALTH,
		moveSpeed = raw.moveSpeed or DEFAULT_MOVE_SPEED,
		arrivalTolerance = raw.arrivalTolerance or DEFAULT_TOLERANCE,
		attackInterval = attack.interval or DEFAULT_ATTACK_INTERVAL,
		attackDamage = attack.damage or DEFAULT_ATTACK_DAMAGE,
		attackRadius = attack.radius or DEFAULT_ATTACK_RADIUS,
		rewardMin = (reward.money and reward.money.min) or DEFAULT_REWARD_MIN,
		rewardMax = (reward.money and reward.money.max) or DEFAULT_REWARD_MAX,
		progressionValue = reward.progression or DEFAULT_PROGRESSION_VALUE,
	}

	bossDefinitionCache[name] = definition
	return definition
end

local function ensureBrainrotProgress(data: any)
	local progress = data.BrainrotProgress
	if typeof(progress) ~= "table" then
		progress = {
			score = 0,
			highestTier = 0,
			defeated = {},
			defeatedIndex = {},
			lastBoss = "",
			difficultyPercent = 0,
		}
		data.BrainrotProgress = progress
	else
		progress.score = tonumber(progress.score) or 0
		progress.highestTier = tonumber(progress.highestTier) or 0
		progress.defeated = typeof(progress.defeated) == "table" and progress.defeated or {}
		progress.defeatedIndex = typeof(progress.defeatedIndex) == "table" and progress.defeatedIndex or {}
		progress.lastBoss = typeof(progress.lastBoss) == "string" and progress.lastBoss or ""
		progress.difficultyPercent = clampDifficultyPercent(progress.difficultyPercent)
	end

	progress.difficultyPercent = clampDifficultyPercent(progress.difficultyPercent)

	return progress
end

local function getDifficultyPercent(ownerUserId: number): number
	if not ownerUserId or ownerUserId <= 0 then
		return 0
	end

	local player = Players:GetPlayerByUserId(ownerUserId)
	if not player then
		return 0
	end

	local data = Profiles.GetProfileData(player)
	if typeof(data) ~= "table" then
		return 0
	end

	local progress = ensureBrainrotProgress(data)
	return clampDifficultyPercent(progress.difficultyPercent)
end

local function persistDifficultyPercent(ownerUserId: number, percent: number)
	if not ownerUserId or ownerUserId <= 0 then
		return
	end

	local player = Players:GetPlayerByUserId(ownerUserId)
	if not player then
		return
	end

	local clamped = clampDifficultyPercent(percent)

	Profiles.Mutate(player, function(data)
		if typeof(data) ~= "table" then
			return nil
		end

		local progress = ensureBrainrotProgress(data)
		progress.difficultyPercent = clamped
		return nil
	end)

	print(string.format("[BrainrotDifficulty] %s (%d) -> %d%%", getPlayerLabel(player), player.UserId, math.floor(clamped)))

	TourismPackets.DifficultyUpdate:FireClient(player, math.floor(clamped + 0.5), DIFFICULTY_PERCENT_CAP)
end

local function syncControllerOwner(controller: PlotController, ownerId: number?)
	if not ownerId then
		if controller.trackedOwnerId ~= nil then
			local previousOwner = controller.trackedOwnerId
			controller.trackedOwnerId = nil
			controller.difficultyPercent = 0
			controller.progressAccumulator = 0
			controller.lastPersistedPercent = 0
			controller.paused = false
			controller.lastAssetsSnapshot = {}
			controller.cachedPlacements = {}
			controller.assetRefreshElapsed = ASSET_REFRESH_INTERVAL
			controller.hadAssets = false
			local previousPlayer = Players:GetPlayerByUserId(previousOwner)
			if previousPlayer then
				TourismPackets.DifficultyUpdate:FireClient(previousPlayer, 0, DIFFICULTY_PERCENT_CAP)
			end
		end
		return
	end

	if controller.trackedOwnerId ~= ownerId then
		controller.trackedOwnerId = ownerId
		cleanupController(controller)
		table.clear(controller.activeTargets)
		controller.agentCounter = 0
		controller.defeated = false
		controller.cooldown = randomInRange(COOLDOWN_RANGE)
		controller.difficultyPercent = getDifficultyPercent(ownerId)
		controller.progressAccumulator = 0
		controller.lastPersistedPercent = math.floor(controller.difficultyPercent)
		controller.paused = false
		controller.lastAssetsSnapshot = {}
		controller.cachedPlacements = {}
		controller.assetRefreshElapsed = ASSET_REFRESH_INTERVAL
		controller.hadAssets = false

		local player = Players:GetPlayerByUserId(ownerId)
		if player then
			print(string.format("[BrainrotDifficulty] %s (%d) retomo en %d%%", getPlayerLabel(player), ownerId, controller.lastPersistedPercent))
			TourismPackets.DifficultyUpdate:FireClient(player, controller.lastPersistedPercent, DIFFICULTY_PERCENT_CAP)
		end
	end
end

local function updateDifficultyProgress(controller: PlotController, ownerId: number, deltaTime: number, hasActivePlacements: boolean)
	if controller.defeated then
		return
	end

	if not hasActivePlacements then
		controller.progressAccumulator = 0
		return
	end

	if controller.difficultyPercent >= DIFFICULTY_PERCENT_CAP then
		controller.progressAccumulator = 0
		return
	end

	if deltaTime <= 0 then
		return
	end

	controller.progressAccumulator += deltaTime * DIFFICULTY_GAIN_PER_SECOND
	if controller.progressAccumulator < 1 then
		return
	end

	local gained = math.floor(controller.progressAccumulator)
	controller.progressAccumulator -= gained
	if gained <= 0 then
		return
	end

	controller.difficultyPercent = clampDifficultyPercent(controller.difficultyPercent + gained)
	local floored = math.floor(controller.difficultyPercent)
	if floored ~= controller.lastPersistedPercent then
		controller.lastPersistedPercent = floored
		persistDifficultyPercent(ownerId, floored)
	end
end

local function computeScaledStats(definition: BossDefinition, percent: number)
	local clamped = clampDifficultyPercent(percent)
	local healthMultiplier = 1 + (clamped * HEALTH_SCALE_PER_PERCENT)
	local moveMultiplier = 1 + (clamped * MOVE_SPEED_SCALE_PER_PERCENT)
	local damageMultiplier = 1 + (clamped * ATTACK_DAMAGE_SCALE_PER_PERCENT)
	local intervalMultiplier = math.max(1 - (clamped * ATTACK_INTERVAL_REDUCTION_PER_PERCENT), 0)

	local scaledMaxHealth = math.max(1, math.floor(definition.maxHealth * healthMultiplier + 0.5))
	local scaledMoveSpeed = math.max(1, definition.moveSpeed * moveMultiplier)
	local scaledDamage = math.max(1, math.floor(definition.attackDamage * damageMultiplier + 0.5))
	local scaledInterval = math.max(MIN_ATTACK_INTERVAL, definition.attackInterval * intervalMultiplier)

	return {
		maxHealth = scaledMaxHealth,
		moveSpeed = scaledMoveSpeed,
		attackDamage = scaledDamage,
		attackInterval = scaledInterval,
	}
end

local function computeDifficultySettings(percent: number)
	local clamped = clampDifficultyPercent(percent)
	local capBonus = math.clamp(math.floor(clamped / 90), 0, 8)
	local waveSize = math.clamp(1 + math.floor(clamped / 140), 1, 6)
	local flankSpread = math.clamp(1 + math.floor(clamped / 220), 1, 4)
	local cooldownScale = math.clamp(1 - (clamped / DIFFICULTY_PERCENT_CAP) * 0.6, 0.35, 1)

	return {
		capBonus = capBonus,
		waveSize = waveSize,
		flankSpread = flankSpread,
		cooldownScale = cooldownScale,
	}
end

local function scaleCooldownRange(range: Vector2, scale: number): Vector2
	local clampedScale = math.clamp(scale, 0.25, 1)
	local minValue = math.max(MIN_SPAWN_COOLDOWN, range.X * clampedScale)
	local maxValue = math.max(minValue + 0.05, range.Y * clampedScale)
	return Vector2.new(minValue, maxValue)
end

local function pickBossDefinition(_ownerUserId: number): BossDefinition?
	local pool: { BossDefinition } = {}

	for _, name in ipairs(bossOrder) do
		local definition = resolveBossDefinition(name)
		if definition then
			pool[#pool + 1] = definition
		end
	end

	if #pool == 0 then
		return nil
	end

	return pool[rng:NextInteger(1, #pool)]
end

local function collectPlacementAssets(placements: { number }): { PlacementAsset }
	local api = placementServiceApi
	if not api then
		return {}
	end

	local results: { PlacementAsset } = {}

	for _, placementEntity in ipairs(placements) do
		local record, _, placementId = api.GetPlacementStateByEntity(placementEntity)
		if record and record.health > 0 then
			local model = PlacementWorld.GetPlacementModel(placementEntity)
			if model then
				local primary = ensurePrimaryPart(model)
				if primary then
					local healthValue = math.max(0, tonumber(record.health) or 0)
					local maxHealthValue = math.max(1, tonumber(record.maxHealth) or healthValue)
					results[#results + 1] = {
						entity = placementEntity,
						placementId = placementId or "",
						assetId = record.assetId or "",
						position = primary.Position,
						health = healthValue,
						maxHealth = maxHealthValue,
					}
				end
			end
		end
	end

	return results
end

local function isMoneyPlacement(assetId: string): boolean
	if typeof(assetId) ~= "string" or assetId == "" then
		return false
	end

	if typeof(BuildingsData) ~= "table" then
		return false
	end

	return typeof(BuildingsData[assetId]) == "table"
end

local function isWeaponPlacement(assetId: string): boolean
	if typeof(assetId) ~= "string" or assetId == "" then
		return false
	end

	if typeof(AmmoBuildingsData) ~= "table" then
		return false
	end

	return typeof(AmmoBuildingsData[assetId]) == "table"
end

local function hasRequiredPlacements(assets: { PlacementAsset }): boolean
	local hasMoney = false
	local hasWeapon = false

	for _, asset in ipairs(assets) do
		local assetId = asset.assetId
		if not hasMoney and isMoneyPlacement(assetId) then
			hasMoney = true
		end
		if not hasWeapon and isWeaponPlacement(assetId) then
			hasWeapon = true
		end
		if hasMoney and hasWeapon then
			return true
		end
	end

	return false
end

local function getClosestWaypointIndex(entries: { WaypointEntry }, position: Vector3): number?
	local closestIndex: number? = nil
	local closestDistance = math.huge
	for index, entry in ipairs(entries) do
		local distance = (entry.position - position).Magnitude
		if distance < closestDistance then
			closestDistance = distance
			closestIndex = index
		end
	end
	return closestIndex
end

local function reconstructPath(previous: { [number]: number }, target: number, start: number): { number }
	local stack: { number } = { target }
	local current = target
	while current ~= start do
		local parent = previous[current]
		if not parent then
			break
		end
		table.insert(stack, 1, parent)
		current = parent
	end
	return stack
end

local function searchWaypointPath(navEntry: NavigationData, startIndex: number, goalIndex: number): { number }?
	if startIndex == goalIndex then
		return { startIndex }
	end

	local graph = navEntry.waypointGraph
	local queue: { number } = { startIndex }
	local head = 1
	local visited: { [number]: boolean } = { [startIndex] = true }
	local previous: { [number]: number } = {}

	while head <= #queue do
		local node = queue[head]
		head += 1

		local neighbors = graph[node]
		if neighbors then
			for _, neighbor in ipairs(neighbors) do
				if not visited[neighbor] then
					visited[neighbor] = true
					previous[neighbor] = node
					if neighbor == goalIndex then
						return reconstructPath(previous, goalIndex, startIndex)
					end
					queue[#queue + 1] = neighbor
				end
			end
		end
	end

	return nil
end

local function computeWaypointPositions(navEntry: NavigationData, startPosition: Vector3, goalPosition: Vector3): ({ Vector3 }?, number?)
	local entries = navEntry.waypointEntries
	if not entries or #entries == 0 then
		return nil, nil
	end

	local startIndex = getClosestWaypointIndex(entries, startPosition)
	local goalIndex = getClosestWaypointIndex(entries, goalPosition)
	if not startIndex or not goalIndex then
		return nil, nil
	end

	local indexPath = searchWaypointPath(navEntry, startIndex, goalIndex)
	if not indexPath then
		return nil, nil
	end

	local positions = table.create(#indexPath)
	for idx, waypointIndex in ipairs(indexPath) do
		positions[idx] = entries[waypointIndex].position
	end

	return positions, goalIndex
end

local function computeReward(definition: BossDefinition): number
	local minValue = math.floor(math.max(0, definition.rewardMin))
	local maxValue = math.floor(math.max(minValue, definition.rewardMax))
	return rng:NextInteger(minValue, maxValue)
end

local function buildAgentSnapshot(controller: PlotController, agent: BrainrotAgent)
	local spawnCFrame = agent.spawnEntry.cframe or CFrame.new(agent.spawnEntry.position)
	return {
		id = agent.id,
		plotIndex = controller.index,
		ownerUserId = agent.ownerUserId,
		brainrotName = agent.brainrotName,
		state = agent.state,
		position = agent.position,
		path = agent.path,
		pathIndex = agent.pathIndex,
		goalWaypointIndex = agent.goalWaypointIndex,
		spawnCFrame = spawnCFrame,
		moveSpeed = agent.moveSpeed,
		arrivalTolerance = agent.arrivalTolerance,
		health = agent.health,
		maxHealth = agent.maxHealth,
		faceAdjustment = agent.faceRotationAdjustment,
		targetPosition = agent.targetPosition,
	}
end

local function applyMutationEffectsToAgent(agent: BrainrotAgent, totals: MutationTotals): boolean
	local changed = false
	for property, applier in pairs(PROPERTY_APPLIERS) do
		local percent = totals[property] or 0
		if applier(agent, percent) then
			changed = true
		end
	end
	return changed
end

local function applyMutationEffectsToController(controller: PlotController, totals: MutationTotals)
	for _, agent in ipairs(controller.agents) do
		if applyMutationEffectsToAgent(agent, totals) then
			TourismPackets.AgentSpawn:Fire(buildAgentSnapshot(controller, agent))
		end
	end
end

local function applyMutationEffectsToAllControllers(totals: MutationTotals)
	for _, controller in pairs(plotControllers) do
		applyMutationEffectsToController(controller, totals)
	end
end

local function computeMutationTotals(state: { string }): MutationTotals
	local totals: MutationTotals = {}
	for _, name in ipairs(state) do
		local effect = MUTATION_MODIFIERS[name]
		if effect then
			for property, delta in pairs(effect) do
				totals[property] = (totals[property] or 0) + delta
			end
		end
	end
	return totals
end

local function mutationTotalsEqual(a: MutationTotals, b: MutationTotals): boolean
	for key, value in pairs(a) do
		if math.abs((b[key] or 0) - value) > 1e-4 then
			return false
		end
	end
	for key, value in pairs(b) do
		if math.abs((a[key] or 0) - value) > 1e-4 then
			return false
		end
	end
	return true
end

local function registerAgent(controller: PlotController, agent: BrainrotAgent)
	agentById[agent.id] = agent
	agentControllerMap[agent.id] = controller

	local ownerId = agent.ownerUserId
	if ownerId and ownerId > 0 then
		local bucket = agentsByOwner[ownerId]
		if not bucket then
			bucket = {}
			agentsByOwner[ownerId] = bucket
		end
		bucket[agent.id] = agent
	end
end

local function unregisterAgent(agent: BrainrotAgent)
	local ownerId = agent.ownerUserId
	if ownerId and ownerId > 0 then
		local bucket = agentsByOwner[ownerId]
		if bucket then
			bucket[agent.id] = nil
			if next(bucket) == nil then
				agentsByOwner[ownerId] = nil
			end
		end
	end

	agentById[agent.id] = nil
	agentControllerMap[agent.id] = nil
end

local function buildAgentDetails(controller: PlotController, agent: BrainrotAgent)
	local spawnEntry = agent.spawnEntry
	local definition = agent.definition

	return {
		id = agent.id,
		plotIndex = controller.index,
		plotName = controller.navEntry and controller.navEntry.name or nil,
		ownerUserId = agent.ownerUserId,
		brainrotName = agent.brainrotName,
		state = agent.state,
		position = agent.position,
		targetPosition = agent.targetPosition,
		targetEntity = agent.targetEntity,
		goalWaypointIndex = agent.goalWaypointIndex,
		moveSpeed = agent.moveSpeed,
		arrivalTolerance = agent.arrivalTolerance,
		attackInterval = agent.attackInterval,
		attackDamage = agent.attackDamage,
		attackRadius = agent.attackRadius,
		health = agent.health,
		maxHealth = agent.maxHealth,
		rewardMoney = agent.rewardMoney,
		progressionValue = agent.progressionValue,
		definition = {
			name = definition.name,
			tier = definition.tier,
			unlockScore = definition.unlockScore,
			maxHealth = definition.maxHealth,
			moveSpeed = definition.moveSpeed,
			arrivalTolerance = definition.arrivalTolerance,
			attackInterval = definition.attackInterval,
			attackDamage = definition.attackDamage,
			attackRadius = definition.attackRadius,
			rewardMin = definition.rewardMin,
			rewardMax = definition.rewardMax,
			progressionValue = definition.progressionValue,
		},
		spawn = if spawnEntry
			then {
				name = spawnEntry.name,
				position = spawnEntry.position,
				cframe = spawnEntry.cframe,
			}
			else nil,
	}
end


local function grantBossReward(agent: BrainrotAgent)
	local ownerUserId = agent.ownerUserId
	if not ownerUserId or ownerUserId <= 0 then
		return
	end

	local ownerPlayer = Players:GetPlayerByUserId(ownerUserId)
	if not ownerPlayer then
		return
	end

	Profiles.Mutate(ownerPlayer, function(data)
		if typeof(data) ~= "table" then
			return nil
		end

		local progress = ensureBrainrotProgress(data)
		progress.score += agent.progressionValue
		progress.highestTier = math.max(progress.highestTier, agent.definition.tier)
		local defeated = progress.defeated
		defeated[agent.brainrotName] = (defeated[agent.brainrotName] or 0) + 1
		local defeatedIndex = progress.defeatedIndex
		defeatedIndex[agent.brainrotName] = true
		progress.lastBoss = agent.brainrotName

		data.Money = (tonumber(data.Money) or 0) + agent.rewardMoney

		return nil
	end)
end

local function destroyAgent(controller: PlotController, index: number, reason: string?, reward: number?)
	local agent = controller.agents[index]
	if not agent then
		return
	end

	unregisterAgent(agent)

	if agent.targetEntity then
		controller.activeTargets[agent.targetEntity] = nil
	end

	TourismPackets.AgentRemoved:Fire({
		id = agent.id,
		plotIndex = controller.index,
		reason = reason or "Removed",
		reward = reward,
	})

	table.remove(controller.agents, index)
end

local function enterManualPause(controller: PlotController)
	if controller.paused then
		return
	end

	controller.paused = true
	controller.progressAccumulator = 0
	controller.cooldown = math.huge
	controller.cachedPlacements = {}
	controller.assetRefreshElapsed = ASSET_REFRESH_INTERVAL
	cleanupController(controller)
	table.clear(controller.activeTargets)
end

local function exitManualPause(controller: PlotController)
	if not controller.paused then
		return
	end

	controller.paused = false
	controller.cooldown = randomInRange(COOLDOWN_RANGE)
	controller.assetRefreshElapsed = ASSET_REFRESH_INTERVAL
end

local function announcePlayerDefeat(controller: PlotController)
	if controller.defeated then
		return
	end

	controller.defeated = true
	controller.paused = false
	controller.hadAssets = false

	local slot = controller.slot
	local ownerId = slot and slot:GetOwnerId()
	local announceName = "EL JUGADOR"
	if ownerId then
		local player = Players:GetPlayerByUserId(ownerId)
		if player then
			local displayName = player.DisplayName
			if typeof(displayName) == "string" and displayName ~= "" then
				announceName = displayName
			else
				announceName = player.Name
			end
		else
			announceName = string.format("Jugador %d", ownerId)
		end
	end

	local message = string.format("%s You Lost : ( You need to start again...", string.upper(announceName))

	TourismPackets.AgentRemoved:Fire({
		announce = true,
		plotIndex = controller.index,
		message = message,
	})

	for index = #controller.agents, 1, -1 do
		destroyAgent(controller, index, "Defeat")
	end

	table.clear(controller.activeTargets)
	controller.difficultyPercent = 0
	controller.progressAccumulator = 0
	controller.lastPersistedPercent = 0
	controller.cachedPlacements = {}
	controller.assetRefreshElapsed = ASSET_REFRESH_INTERVAL
	if ownerId then
		persistDifficultyPercent(ownerId, 0)
	end
	controller.cooldown = math.huge
end

local function removeAgentById(agentId: string, reason: string?, reward: number?)
	for _, controller in pairs(plotControllers) do
		for index, agent in ipairs(controller.agents) do
			if agent.id == agentId then
				destroyAgent(controller, index, reason, reward)
				return true
			end
		end
	end
	return false
end

local function spawnAgent(
	controller: PlotController,
	plotEntity: number,
	ownerUserId: number,
	placementsOverride: { number }?,
	assetsOverride: { PlacementAsset }?,
	spawnEntryOverride: SpawnEntry?
): boolean
	if controller.defeated then
		return false
	end

	local navEntry = controller.navEntry
	if not navEntry.spawns or #navEntry.spawns == 0 then
		return false
	end
	if not navEntry.waypointEntries or #navEntry.waypointEntries == 0 then
		return false
	end
	if next(brainrotAssets) == nil then
		return false
	end

	local placements = placementsOverride or PlacementWorld.ListPlacements(plotEntity)
	if #placements == 0 then
		return false
	end

	local assets = assetsOverride or collectPlacementAssets(placements)
	if #assets == 0 then
		return false
	end

	local definition = pickBossDefinition(ownerUserId)
	if not definition then
		return false
	end

	local spawnEntry = spawnEntryOverride or navEntry.spawns[rng:NextInteger(1, #navEntry.spawns)]
	local spawnPosition = spawnEntry.position

	local availableAssets: { PlacementAsset } = {}
	for _, asset in ipairs(assets) do
		if not controller.activeTargets[asset.entity] then
			availableAssets[#availableAssets + 1] = asset
		end
	end

	if #availableAssets == 0 then
		return false
	end

	local targetAsset = availableAssets[rng:NextInteger(1, #availableAssets)]
	local path, goalIndex = computeWaypointPositions(navEntry, spawnPosition, targetAsset.position)
	if not path or #path == 0 then
		return false
	end

	local template = brainrotAssets[definition.name]
	if not template then
		return false
	end

	local primary = ensurePrimaryPart(template)
	if not primary then
		return false
	end

	local faceAdjustment = computeFaceRotationAdjustment(template, primary)
	controller.activeTargets[targetAsset.entity] = true
	controller.agentCounter += 1
	local agentId = string.format("%d_%d", controller.index, controller.agentCounter)
	local scaledStats = computeScaledStats(definition, controller.difficultyPercent)

	local agent: BrainrotAgent = {
		id = agentId,
		definition = definition,
		brainrotName = definition.name,
		state = "toBuilding",
		path = path,
		pathIndex = 1,
		goalWaypointIndex = goalIndex or 1,
		navEntry = navEntry,
		spawnEntry = spawnEntry,
		position = spawnPosition,
		targetPosition = targetAsset.position,
		targetEntity = targetAsset.entity,
		ownerUserId = ownerUserId,
		moveSpeed = scaledStats.moveSpeed,
		baseMoveSpeed = scaledStats.moveSpeed,
		arrivalTolerance = definition.arrivalTolerance,
		attackInterval = scaledStats.attackInterval,
		attackCooldown = scaledStats.attackInterval,
		attackDamage = scaledStats.attackDamage,
		baseAttackDamage = scaledStats.attackDamage,
		attackRadius = definition.attackRadius,
		maxHealth = scaledStats.maxHealth,
		health = scaledStats.maxHealth,
		rewardMoney = computeReward(definition),
		progressionValue = definition.progressionValue,
		faceRotationAdjustment = faceAdjustment,
	}

		applyMutationEffectsToAgent(agent, currentMutationTotals)
		controller.agents[#controller.agents + 1] = agent
		registerAgent(controller, agent)
		TourismPackets.AgentSpawn:Fire(buildAgentSnapshot(controller, agent))

	return true
end

local function spawnWave(
	controller: PlotController,
	plotEntity: number,
	ownerUserId: number,
	placements: { number },
	assets: { PlacementAsset },
	desiredCount: number,
	flankSpread: number,
	cap: number
): number
	if desiredCount <= 0 then
		return 0
	end

	local spawnEntries = controller.navEntry.spawns
	local usedSpawns: { [SpawnEntry]: boolean } = {}
	local uniqueUsed = 0
	local uniqueLimit = 0
	if spawnEntries and #spawnEntries > 0 then
		uniqueLimit = math.min(flankSpread, #spawnEntries)
	end

	local spawned = 0
	local attempts = 0
	local maxAttempts = math.max(desiredCount * 3, desiredCount)

	while spawned < desiredCount and attempts < maxAttempts do
		if #controller.agents >= cap then
			break
		end

		attempts += 1
		local spawnPreference: SpawnEntry? = nil

		if spawnEntries and #spawnEntries > 0 then
			if uniqueLimit > 0 and uniqueUsed < uniqueLimit then
				local innerAttempts = 0
				repeat
					local candidate = spawnEntries[rng:NextInteger(1, #spawnEntries)]
					innerAttempts += 1
					if not usedSpawns[candidate] then
						usedSpawns[candidate] = true
						uniqueUsed += 1
						spawnPreference = candidate
						break
					elseif innerAttempts >= 4 then
						spawnPreference = candidate
						break
					end
				until innerAttempts >= 4
			else
				spawnPreference = spawnEntries[rng:NextInteger(1, #spawnEntries)]
			end
		end

		if spawnAgent(controller, plotEntity, ownerUserId, placements, assets, spawnPreference) then
			spawned += 1
		end
	end

	return spawned
end

local function computeAttackCooldown(agent: BrainrotAgent): number
	local baseInterval = math.max(agent.attackInterval, 0.4)
	local minCooldown = math.max(baseInterval * ATTACK_COOLDOWN_VARIATION.X, 0.25)
	local maxCooldown = math.max(minCooldown, baseInterval * ATTACK_COOLDOWN_VARIATION.Y)
	return rng:NextNumber(minCooldown, maxCooldown)
end

local function tryAssignNewTarget(controller: PlotController, agent: BrainrotAgent): boolean
	if controller.defeated then
		return false
	end

	if agent.targetEntity then
		controller.activeTargets[agent.targetEntity] = nil
	end

	local slot = controller.slot
	local ownerId = slot and slot:GetOwnerId()
	if not ownerId then
		return false
	end

	local plotEntity = PlacementWorld.GetPlotByOwner(ownerId)
	if not plotEntity then
		return false
	end

	local placements = PlacementWorld.ListPlacements(plotEntity)
	if #placements == 0 then
		return false
	end

	local assets = collectPlacementAssets(placements)
	if #assets == 0 then
		return false
	end

	local available: { PlacementAsset } = {}
	for _, asset in ipairs(assets) do
		if asset.entity ~= agent.targetEntity and not controller.activeTargets[asset.entity] then
			available[#available + 1] = asset
		end
	end

	local selection = if #available > 0 then available else assets
	if #selection == 0 then
		return false
	end

	local newTarget = selection[rng:NextInteger(1, #selection)]
	local path, goalIndex = computeWaypointPositions(controller.navEntry, agent.position, newTarget.position)
	if not path or #path == 0 then
		return false
	end

	controller.activeTargets[newTarget.entity] = true
	agent.targetEntity = newTarget.entity
	agent.targetPosition = newTarget.position
	agent.state = "toBuilding"
	agent.path = path
	agent.pathIndex = 1
	agent.goalWaypointIndex = goalIndex or agent.goalWaypointIndex
	agent.attackAnchor = nil
	agent.attackCooldown = computeAttackCooldown(agent)

	TourismPackets.AgentSpawn:Fire(buildAgentSnapshot(controller, agent))
	return true
end

local function attackBuilding(controller: PlotController, agent: BrainrotAgent): "continue" | "lost" | "destroyed"
	local api = placementServiceApi
	if not api then
		return "lost"
	end

	local varianceMin = math.min(ATTACK_DAMAGE_VARIATION.X, ATTACK_DAMAGE_VARIATION.Y)
	local varianceMax = math.max(ATTACK_DAMAGE_VARIATION.X, ATTACK_DAMAGE_VARIATION.Y)
	local damageScale = rng:NextNumber(varianceMin, varianceMax)
	local baseDamage = math.max(1, math.floor(agent.attackDamage + 0.5))
	local scaledDamage = math.max(1, math.floor(baseDamage * damageScale + 0.5))

	local success, result = api.ApplyDamageToPlacement(agent.targetEntity, scaledDamage)
	if not success or not result then
		return "lost"
	end

	if result.destroyed then
		return "destroyed"
	end

	return "continue"
end

local function stepAgent(controller: PlotController, agent: BrainrotAgent, deltaTime: number): (boolean, string?)
	if agent.state == "toBuilding" then
		local path = agent.path
		if #path == 0 then
			return false, "TargetLost"
		end

		local target = path[agent.pathIndex]
		if not target then
			return false, "TargetLost"
		end

		local deltaVec = target - agent.position
		local distance = deltaVec.Magnitude
		if distance <= agent.arrivalTolerance then
			agent.position = target
			agent.pathIndex += 1
			if agent.pathIndex > #path then
				agent.state = "attacking"
				agent.path = {}
				agent.pathIndex = 0
				local anchor = target or agent.targetPosition
				if not anchor then
					anchor = agent.position
				end
				agent.attackAnchor = anchor
				agent.position = anchor
				agent.attackCooldown = rng:NextNumber(0.2, math.max(0.5, agent.attackInterval * 0.6))
				TourismPackets.AgentSpawn:Fire(buildAgentSnapshot(controller, agent))
				return true, nil
			end
			target = path[agent.pathIndex]
			deltaVec = target - agent.position
			distance = deltaVec.Magnitude
			if distance <= agent.arrivalTolerance then
				agent.position = target
				return true, nil
			end
		end

		if distance <= 0 then
			return true, nil
		end

		local moveDistance = agent.moveSpeed * deltaTime
		if moveDistance >= distance then
			agent.position = target
		else
			agent.position += (deltaVec / distance) * moveDistance
		end

		return true, nil
	end

	if agent.state == "attacking" then
		agent.attackCooldown -= deltaTime
		if agent.attackCooldown > 0 then
			return true, nil
		end

		local outcome = attackBuilding(controller, agent)
		if outcome == "continue" then
			agent.attackCooldown = computeAttackCooldown(agent)
			return true, nil
		end

		if tryAssignNewTarget(controller, agent) then
			return true, nil
		end

		announcePlayerDefeat(controller)
		if outcome == "destroyed" then
			return false, "TargetDestroyed"
		end

		return false, "TargetLost"
	end

	return true, nil
end

local function updateAgents(controller: PlotController, deltaTime: number)
	local index = 1
	while index <= #controller.agents do
		local agent = controller.agents[index]
		local alive, reason = stepAgent(controller, agent, deltaTime)
		if alive then
			index += 1
		else
			destroyAgent(controller, index, reason)
		end
	end
end

local function updateController(controller: PlotController, deltaTime: number)
	updateAgents(controller, deltaTime)

	local slot = controller.slot
	if not slot then
		syncControllerOwner(controller, nil)
		return
	end

	local ownerId = slot:GetOwnerId()
	if not ownerId then
		syncControllerOwner(controller, nil)
		controller.cooldown = randomInRange(COOLDOWN_RANGE)
		return
	end

	syncControllerOwner(controller, ownerId)

	local plotEntity = PlacementWorld.GetPlotByOwner(ownerId)
	if not plotEntity then
		controller.cooldown = randomInRange(COOLDOWN_RANGE)
		return
	end

	local previousSnapshot = controller.lastAssetsSnapshot or {}
	local refreshElapsed = controller.assetRefreshElapsed + deltaTime
	local shouldRefresh = refreshElapsed >= ASSET_REFRESH_INTERVAL or controller.cachedPlacements == nil

	local placements = controller.cachedPlacements or {}
	local assets = controller.lastAssetsSnapshot or {}

	if shouldRefresh then
		placements = PlacementWorld.ListPlacements(plotEntity)
		assets = collectPlacementAssets(placements)
		controller.cachedPlacements = placements
		controller.lastAssetsSnapshot = assets
		refreshElapsed = 0
	end

	controller.assetRefreshElapsed = refreshElapsed

	local hasAssets = #assets > 0
	local hasRequired = hasRequiredPlacements(assets)
	if hasAssets then
		controller.hadAssets = true
	end

	if controller.paused then
		if hasAssets and hasRequired then
			exitManualPause(controller)
		else
			updateDifficultyProgress(controller, ownerId, deltaTime, hasAssets)
			controller.lastAssetsSnapshot = assets
			return
		end
	end

	local shouldPause = false
	if not hasAssets and #previousSnapshot > 0 then
		-- All placements vanished treat this as a manual pause only if every prior placement was at full health
		local allFullHealth = true
		for _, snapshot in ipairs(previousSnapshot) do
			local maxHealth = math.max(1, snapshot.maxHealth)
			if snapshot.health < maxHealth then
				allFullHealth = false
				break
			end
		end
		shouldPause = allFullHealth
	end

	if controller.defeated then
		if not hasAssets or not hasRequired then
			updateDifficultyProgress(controller, ownerId, deltaTime, hasAssets)
			controller.lastAssetsSnapshot = assets
			return
		end

		controller.assetRefreshElapsed = ASSET_REFRESH_INTERVAL
		controller.defeated = false
		controller.cooldown = randomInRange(COOLDOWN_RANGE)
	end

	updateDifficultyProgress(controller, ownerId, deltaTime, hasAssets)

	if shouldPause then
		enterManualPause(controller)
		controller.lastAssetsSnapshot = assets
		return
	end

	if not hasAssets then
		if controller.hadAssets then
			announcePlayerDefeat(controller)
		end
		controller.lastAssetsSnapshot = assets
		return
	end

	controller.lastAssetsSnapshot = assets

	local difficultySettings = computeDifficultySettings(controller.difficultyPercent)
	local baseCap = computeAgentCap(#assets)
	local cap = math.clamp(baseCap + difficultySettings.capBonus, BASE_AGENT_CAP, MAX_TOTAL_AGENT_CAP)
	if cap <= 0 then
		controller.cooldown = randomInRange(COOLDOWN_RANGE)
		return
	end

	if #controller.agents >= cap then
		controller.cooldown = math.max(0, controller.cooldown - deltaTime)
		return
	end

	controller.cooldown -= deltaTime
	if controller.cooldown > 0 then
		return
	end

	local availableSlots = math.max(0, cap - #controller.agents)
	if availableSlots <= 0 then
		controller.cooldown = randomInRange(scaleCooldownRange(Vector2.new(1.8, 3.2), difficultySettings.cooldownScale))
		return
	end

	local desiredWave = math.min(difficultySettings.waveSize, availableSlots)
	local spawnedCount = spawnWave(controller, plotEntity, ownerId, placements, assets, desiredWave, difficultySettings.flankSpread, cap)
	local cooldownRange = if spawnedCount > 0 then Vector2.new(1.4, 2.6) else Vector2.new(2.6, 3.6)
	controller.cooldown = randomInRange(scaleCooldownRange(cooldownRange, difficultySettings.cooldownScale))
end

local function stepAll(deltaTime: number)
	for _, controller in pairs(plotControllers) do
		updateController(controller, deltaTime)
	end
end

local function sendSnapshotsToPlayer(player: Player)
	local agentsPayload = {}
	for _, controller in pairs(plotControllers) do
		for _, agent in ipairs(controller.agents) do
			agentsPayload[#agentsPayload + 1] = buildAgentSnapshot(controller, agent)
		end
	end

	if #agentsPayload == 0 then
		return
	end

	TourismPackets.AgentSnapshot:FireClient(player, {
		agents = agentsPayload,
	})
end

cleanupController = function(controller: PlotController)
	for index = #controller.agents, 1, -1 do
		destroyAgent(controller, index, "Cleanup")
	end
	table.clear(controller.activeTargets)
	controller.cachedPlacements = {}
	controller.lastAssetsSnapshot = {}
	controller.assetRefreshElapsed = ASSET_REFRESH_INTERVAL
	controller.hadAssets = false
end

function BrainrotTourismService.Init()
	if activeHandle then
		return
	end

	gatherBrainrotAssets()

	local navByIndex = BrainrotNavigationRegistry.GetAll()
	if typeof(navByIndex) ~= "table" then
		warn("BrainrotTourismService could not retrieve navigation data")
		return
	end

	for index, navEntry in pairs(navByIndex) do
		local typedNav = navEntry :: NavigationData
		local hasSpawns = typedNav.spawns and #typedNav.spawns > 0
		local hasWaypoints = typedNav.waypointEntries and #typedNav.waypointEntries > 0
		if hasSpawns and hasWaypoints then
			plotControllers[index] = {
				index = index,
				slot = PlotRegistry.GetSlot(index),
				navEntry = typedNav,
				agents = {},
				activeTargets = {},
				cooldown = randomInRange(Vector2.new(0.6, 1.4)),
				agentCounter = 0,
				defeated = false,
				difficultyPercent = 0,
				progressAccumulator = 0,
				trackedOwnerId = nil,
				lastPersistedPercent = 0,
				paused = false,
				lastAssetsSnapshot = {},
				cachedPlacements = {},
				assetRefreshElapsed = ASSET_REFRESH_INTERVAL,
				hadAssets = false,
			}
		end
	end

	MutationService.Init()

	currentMutationTotals = computeMutationTotals(MutationService.GetActiveMutations())
	applyMutationEffectsToAllControllers(currentMutationTotals)

	if mutationConnection then
		mutationConnection:Disconnect()
		mutationConnection = nil
	end

	mutationConnection = MutationService.Observe(function(state)
		local newTotals = computeMutationTotals(state)
		if mutationTotalsEqual(currentMutationTotals, newTotals) then
			return
		end
		currentMutationTotals = newTotals
		applyMutationEffectsToAllControllers(currentMutationTotals)
	end)

	Players.PlayerAdded:Connect(function(player)
		sendSnapshotsToPlayer(player)
	end)

	for _, player in Players:GetPlayers() do
		sendSnapshotsToPlayer(player)
	end

	activeHandle = RunServiceScheduler.register(MOVE_INTERVAL, function(totalDelta: number, ticks: number)
		local steps = math.max(1, ticks)
		local delta = totalDelta / steps
		for _ = 1, steps do
			stepAll(delta)
		end
		return nil
	end)
end

local function pointInsideBox(position: Vector3, boxCFrame: CFrame, halfSize: Vector3): boolean
	local relative = boxCFrame:PointToObjectSpace(position)
	return math.abs(relative.X) <= halfSize.X
		and math.abs(relative.Y) <= halfSize.Y
		and math.abs(relative.Z) <= halfSize.Z
end

function BrainrotTourismService.GetAgentDetails(agentId: string): { [string]: any }?
	local agent = agentById[agentId]
	if not agent then
		return nil
	end

	local controller = agentControllerMap[agentId]
	if not controller then
		return nil
	end

	return buildAgentDetails(controller, agent)
end

function BrainrotTourismService.GetAgentsForOwner(ownerUserId: number): { { [string]: any } }
	if not ownerUserId or ownerUserId <= 0 then
		return {}
	end

	local bucket = agentsByOwner[ownerUserId]
	if not bucket then
		return {}
	end

	local results = {}
	for _, agent in pairs(bucket) do
		local controller = agentControllerMap[agent.id]
		if controller then
			results[#results + 1] = buildAgentDetails(controller, agent)
		end
	end

	return results
end

function BrainrotTourismService.GetAgentsInBox(centerCFrame: CFrame, size: Vector3, ownerUserId: number?): { { [string]: any } }
	if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
		return {}
	end

	local halfSize = size * 0.5
	local source = if ownerUserId and ownerUserId > 0 then agentsByOwner[ownerUserId] else agentById
	if not source then
		return {}
	end

	local results = {}
	for _, agent in pairs(source) do
		if pointInsideBox(agent.position, centerCFrame, halfSize) then
			local controller = agentControllerMap[agent.id]
			if controller then
				results[#results + 1] = buildAgentDetails(controller, agent)
			end
		end
	end

	return results
end

function BrainrotTourismService.GetActiveAgentsForPlot(plotIndex: number): { { id: string, position: Vector3, state: AgentState, targetEntity: number?, ownerUserId: number?, health: number, maxHealth: number } }
	local controller = plotControllers[plotIndex]
	if not controller then
		return {}
	end

	local results = table.create(#controller.agents)
	for _, agent in ipairs(controller.agents) do
		results[#results + 1] = {
			id = agent.id,
			position = agent.position,
			state = agent.state,
			targetEntity = agent.targetEntity,
			ownerUserId = agent.ownerUserId,
			health = agent.health,
			maxHealth = agent.maxHealth,
		}
	end

	return results
end

function BrainrotTourismService.ApplyDamage(agentId: string, amount: number, _metadata: any?): (boolean, number?)
	for _, controller in pairs(plotControllers) do
		for index, agent in ipairs(controller.agents) do
			if agent.id == agentId then
				local damage = math.max(0, tonumber(amount) or 0)
				if damage <= 0 then
					return true, agent.health
				end

				agent.health = math.max(0, agent.health - damage)
				if agent.health <= 0 then
					agent.health = 0
					grantBossReward(agent)
					destroyAgent(controller, index, "Defeated", agent.rewardMoney)
				else
					TourismPackets.AgentSpawn:Fire(buildAgentSnapshot(controller, agent))
				end

				return true, agent.health
			end
		end
	end

	return false, nil
end

function BrainrotTourismService.RemoveAgent(agentId: string, reason: string?): boolean
	return removeAgentById(agentId, reason or "Removed", nil)
end

function BrainrotTourismService.Shutdown()
	if not activeHandle then
		return
	end

	if mutationConnection then
		mutationConnection:Disconnect()
		mutationConnection = nil
	end

	currentMutationTotals = {}

	for _, controller in pairs(plotControllers) do
		cleanupController(controller)
	end

	RunServiceScheduler.unregister(activeHandle)
	activeHandle = nil
end

function BrainrotTourismService.ConfigurePlacementService(api: PlacementServiceApi?)
	placementServiceApi = api
end

return BrainrotTourismService
