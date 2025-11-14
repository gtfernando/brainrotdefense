--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local WorkFolder = ServerScriptService:WaitForChild("Work")
local ModulesFolder = WorkFolder:WaitForChild("Modules")
local PlacementFolder = WorkFolder:WaitForChild("Placement")

local PlotRegistry = require(PlacementFolder:WaitForChild("PlotRegistry"))
local PlacementWorld = require(PlacementFolder:WaitForChild("World"))
local RunServiceScheduler = require(ModulesFolder:WaitForChild("RunServiceScheduler"))
local BrainrotNavigationRegistry = require(ModulesFolder:WaitForChild("BrainrotNavigationRegistry"))
local MutationService = require(ModulesFolder:WaitForChild("MutationService"))
local Profiles = require(ServerScriptService.Work.Modules.Profiles)

local Promise = require(ReplicatedStorage.Packages.Promise)
local Signal = require(ReplicatedStorage.Packages.Signal)
local Jecs = require(ReplicatedStorage.Packages.jecs)

local TourismPackets = require(ReplicatedStorage.Network.BrainrotTourismPackets)
local BrainrotData = require(ReplicatedStorage.Data.Brainrots)
local BrainrotWaves = require(ReplicatedStorage.Data.BrainrotWaves)
local BuildingsData = require(ReplicatedStorage.Data.Buildings)
local AmmoBuildingsData = require(ReplicatedStorage.Data.AmmoBuildings)

local AssetsFolder = ReplicatedStorage:FindFirstChild("Assets")
local BrainrotAssetsFolder = AssetsFolder and AssetsFolder:FindFirstChild("Brainrots")

local defaultsAny = (BrainrotData.Defaults or {}) :: { [string]: any }
local defaultAttack = (defaultsAny.attack or {}) :: { [string]: any }
local defaultReward = (defaultsAny.reward or {}) :: { [string]: any }

local MOVE_INTERVAL = 0.03
local TIMER_BROADCAST_STEP = 0.25
local DEFAULT_MOVE_SPEED = (defaultsAny.moveSpeed or 12) :: number
local DEFAULT_TOLERANCE = (defaultsAny.arrivalTolerance or 1.2) :: number
local DEFAULT_MAX_HEALTH = (defaultsAny.maxHealth or 1600) :: number
local DEFAULT_ATTACK_INTERVAL = (defaultAttack.interval or 2.4) :: number
local DEFAULT_ATTACK_DAMAGE = (defaultAttack.damage or 110) :: number
local DEFAULT_ATTACK_RADIUS = (defaultAttack.radius or 10) :: number
local DEFAULT_REWARD_MIN = ((defaultReward.money and defaultReward.money.min) or 150) :: number
local DEFAULT_REWARD_MAX = ((defaultReward.money and defaultReward.money.max) or 220) :: number
local DEFAULT_PROGRESSION_VALUE = (defaultReward.progression or 1) :: number

local WAVE_START_DELAY = 0.25
local MAX_ACTIVE_AGENTS = 36

local SPRINT_FEATURE_ENABLED = true
local SPRINT_ELIGIBLE_CHANCE = 0.55
local SPRINT_MIN_COOLDOWN = 3.5
local SPRINT_MAX_COOLDOWN = 7
local SPRINT_MIN_DURATION = 1.1
local SPRINT_MAX_DURATION = 2.6
local SPRINT_SPEED_MULTIPLIER = 2


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

type BossDefinition = {
	name: string,
	tier: number,
	unlockScore: number,
	maxHealth: number,
	moveSpeed: number,
	baseMoveSpeed: number,
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
	arrivalTolerance: number,
	attackInterval: number,
	attackCooldown: number,
	attackDamage: number,
	attackRadius: number,
	maxHealth: number,
	health: number,
	rewardMoney: number,
	progressionValue: number,
	waveIndex: number,
	faceRotationAdjustment: CFrame?,
	attackAnchor: Vector3?,
	extents: Vector3?,
	sprintEligible: boolean,
	sprintActive: boolean,
	sprintRemaining: number,
	sprintCooldown: number,
	sprintMultiplier: number,
}

export type PlacementAsset = {
	entity: number,
	placementId: string,
	assetId: string,
	position: Vector3,
	health: number,
	maxHealth: number,
}

type RequirementState = {
	hasMoney: boolean,
	hasWeapon: boolean,
}

local EMPTY_REQUIREMENTS: RequirementState = {
	hasMoney = false,
	hasWeapon = false,
}

local PLACEMENT_SNAPSHOT_TTL = 0.25

type PlacementSnapshot = {
	timestamp: number,
	placements: { number },
	assets: { PlacementAsset },
	requirements: RequirementState,
}

local placementSnapshotByPlot: { [number]: PlacementSnapshot } = {}

type WaveStatus = "idle" | "waitingStart" | "spawning" | "cooldown" | "defeated"

type WaveTimerInfo = {
	mode: "idle" | "spawning" | "cooldown",
	duration: number,
	elapsed: number,
	remaining: number,
}

type SpawnGroupRuntime = {
	brainrot: string,
	remaining: number,
	interval: number,
	spawnDelay: number,
	burst: boolean,
	cooldown: number,
}

type WaveRuntime = {
	index: number,
	status: WaveStatus,
	skipThreshold: number,
	rewardMultiplier: number,
	total: number,
	spawned: number,
	defeated: number,
	promptIssued: boolean,
	groups: { SpawnGroupRuntime },
	timer: WaveTimerInfo,
	countdownPromise: Promise.Promise? ,
}

type WaveSignals = {
	stateChanged: Signal.Signal<()>,
	timerChanged: Signal.Signal<()>,
	promptChanged: Signal.Signal<()>,
}

type WaveController = {
	index: number,
	slot: any,
	navEntry: NavigationData,
	agents: { BrainrotAgent },
	activeTargets: { [number]: boolean },
	ownerUserId: number?,
	progressLoadedFor: number?,
	wave: WaveRuntime,
	signals: WaveSignals,
	waveEntity: number?,
	assetCache: { PlacementAsset },
	placementsCache: { number },
	requirementState: RequirementState?,
	assetRefreshElapsed: number,
	defeated: boolean,
	hadAssets: boolean,
	recentSpawnHistory: { SpawnEntry },
	recentSpawnLookup: { [SpawnEntry]: boolean },
	agentCounter: number,
	movementCooldown: number,
 	alive: boolean,
	timerBroadcastElapsed: number,
}

local brainrotAssets: { [string]: Model } = {}
local bossDefinitionCache: { [string]: BossDefinition } = {}
local rng = Random.new()
local controllers: { [number]: WaveController } = {}
local agentById: { [string]: BrainrotAgent } = {}
local agentsByOwner: { [number]: { [string]: BrainrotAgent } } = {}
local agentControllerMap: { [string]: WaveController } = {}
local currentMutationTotals: MutationTotals = {}
local ensureWaveEntity: (WaveController) -> () = function() end
local syncWaveEntity: (WaveController) -> () = function() end
local resetWaveRuntime: (WaveController, number) -> () = function() end
local DEFAULT_WAVE_INDEX = 1
local WAVE_ROLLBACK_STEP = 5

local BRAINROT_PROGRESS_DEFAULTS = {
	version = 3,
	score = 0,
	defeated = {},
	defeatedIndex = {},
	highestTier = 0,
	lastBoss = "",
	currentWave = DEFAULT_WAVE_INDEX,
}

type PendingRewardBucket = {
	money: number,
	score: number,
	highestTier: number,
	defeated: { [string]: number },
	lastBoss: string?,
}

local pendingRewardBuckets: { [number]: PendingRewardBucket } = {}

local function normalizeWaveIndex(value: any): number
	local numeric = tonumber(value)
	if not numeric or numeric < 1 then
		return DEFAULT_WAVE_INDEX
	end
	return math.max(DEFAULT_WAVE_INDEX, math.floor(numeric + 0.5))
end

local function computeRollbackWaveIndex(currentWave: number): number
	local normalized = normalizeWaveIndex(currentWave)
	return math.max(DEFAULT_WAVE_INDEX, normalized - WAVE_ROLLBACK_STEP)
end

local function ensureBrainrotProgress(data: any): any
	if typeof(data) ~= "table" then
		return nil
	end
	local progress = data.BrainrotProgress
	if typeof(progress) ~= "table" then
		progress = {
			version = BRAINROT_PROGRESS_DEFAULTS.version,
			score = BRAINROT_PROGRESS_DEFAULTS.score,
			defeated = {},
			defeatedIndex = {},
			highestTier = BRAINROT_PROGRESS_DEFAULTS.highestTier,
			lastBoss = BRAINROT_PROGRESS_DEFAULTS.lastBoss,
			currentWave = BRAINROT_PROGRESS_DEFAULTS.currentWave,
		}
		data.BrainrotProgress = progress
		return progress
	end
	if typeof(progress.version) ~= "number" or progress.version < BRAINROT_PROGRESS_DEFAULTS.version then
		progress.version = BRAINROT_PROGRESS_DEFAULTS.version
	end
	if typeof(progress.defeated) ~= "table" then
		progress.defeated = {}
	end
	if typeof(progress.defeatedIndex) ~= "table" then
		progress.defeatedIndex = {}
	end
	if typeof(progress.highestTier) ~= "number" then
		progress.highestTier = BRAINROT_PROGRESS_DEFAULTS.highestTier
	end
	if typeof(progress.lastBoss) ~= "string" then
		progress.lastBoss = BRAINROT_PROGRESS_DEFAULTS.lastBoss
	end
	if typeof(progress.currentWave) ~= "number" or progress.currentWave < 1 then
		progress.currentWave = BRAINROT_PROGRESS_DEFAULTS.currentWave
	end
	return progress
end

local function getSavedWaveFromPlayer(player: Player?): number
	if not player then
		return DEFAULT_WAVE_INDEX
	end
	local data = Profiles.GetProfileData(player)
	if typeof(data) ~= "table" then
		return DEFAULT_WAVE_INDEX
	end
	local progress = data.BrainrotProgress
	if typeof(progress) ~= "table" then
		return DEFAULT_WAVE_INDEX
	end
	return normalizeWaveIndex(progress.currentWave)
end

local function saveWaveProgressForPlayer(player: Player?, waveIndex: number)
	if not player then
		return
	end
	local clamped = normalizeWaveIndex(waveIndex)
	Profiles.Mutate(player, function(data)
		local progress = ensureBrainrotProgress(data)
		if progress and progress.currentWave ~= clamped then
			progress.currentWave = clamped
		end
		return nil
	end)
end

local function saveControllerWaveProgress(controller: WaveController, waveIndex: number)
	local ownerId = controller.ownerUserId
	if not ownerId then
		return
	end
	local player = Players:GetPlayerByUserId(ownerId)
	if not player then
		return
	end
	saveWaveProgressForPlayer(player, waveIndex)
end

local function applySavedWaveProgress(controller: WaveController)
	local ownerId = controller.ownerUserId
	if not ownerId then
		controller.progressLoadedFor = nil
		return
	end
	if controller.progressLoadedFor == ownerId then
		return
	end
	local player = Players:GetPlayerByUserId(ownerId)
	if not player then
		return
	end
	controller.progressLoadedFor = ownerId
	local savedWave = getSavedWaveFromPlayer(player)
	resetWaveRuntime(controller, savedWave)
end
local evaluateSkipPrompt: (WaveController) -> ()
local tryCompleteWave: (WaveController) -> ()
local waveWorld = Jecs.World.new()
local WaveComponents = {
	Controller = waveWorld:component(),
	WaveNumber = waveWorld:component(),
	Status = waveWorld:component(),
	Spawned = waveWorld:component(),
	Defeated = waveWorld:component(),
	SkipThreshold = waveWorld:component(),
	PromptIssued = waveWorld:component(),
}
local schedulerHandle: any = nil
local mutationConnection: RBXScriptConnection? = nil
local waveControlConnection: RBXScriptConnection? = nil
local playerAddedConnection: RBXScriptConnection? = nil

local function registerAgent(controller: WaveController, agent: BrainrotAgent)
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

local function gatherBrainrotAssets()
	if not BrainrotAssetsFolder then
		warn("BrainrotTourism: missing ReplicatedStorage.Assets.Brainrots")
		brainrotAssets = {}
		return
	end

	brainrotAssets = {}
	for _, child in ipairs(BrainrotAssetsFolder:GetChildren()) do
		if child:IsA("Model") then
			brainrotAssets[child.Name] = child
		end
	end

	if next(brainrotAssets) == nil then
		warn("BrainrotTourism: no brainrot models were found")
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

	local faceRelative = primary.CFrame:ToObjectSpace(facePart.CFrame)
	local rotationOnly = CFrame.fromMatrix(Vector3.zero, faceRelative.RightVector, faceRelative.UpVector, faceRelative.LookVector)
	return rotationOnly:Inverse()
end

local placementServiceApi: {
	GetPlacementStateByEntity: (number) -> (any, any, string?),
	ApplyDamageToPlacement: (number, number) -> (boolean, { destroyed: boolean }?),
}? = nil

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
	return typeof(BuildingsData[assetId]) == "table"
end

local function isWeaponPlacement(assetId: string): boolean
	if typeof(assetId) ~= "string" or assetId == "" then
		return false
	end
	return typeof(AmmoBuildingsData[assetId]) == "table"
end

local function summarizePlacementRequirements(assets: { PlacementAsset }): RequirementState
	local summary: RequirementState = {
		hasMoney = false,
		hasWeapon = false,
	}
	for _, asset in ipairs(assets) do
		if not summary.hasMoney and isMoneyPlacement(asset.assetId) then
			summary.hasMoney = true
		end
		if not summary.hasWeapon and isWeaponPlacement(asset.assetId) then
			summary.hasWeapon = true
		end
		if summary.hasMoney and summary.hasWeapon then
			break
		end
	end
	return summary
end

local function cloneRequirementState(state: RequirementState?): RequirementState
	if not state then
		return {
			hasMoney = false,
			hasWeapon = false,
		}
	end
	return {
		hasMoney = state.hasMoney,
		hasWeapon = state.hasWeapon,
	}
end

local function clonePlacementList(source: { number }): { number }
	local copy = table.create(#source)
	for index, value in ipairs(source) do
		copy[index] = value
	end
	return copy
end

local function clonePlacementAssets(source: { PlacementAsset }): { PlacementAsset }
	local copy = table.create(#source)
	for index, asset in ipairs(source) do
		copy[index] = {
			entity = asset.entity,
			placementId = asset.placementId,
			assetId = asset.assetId,
			position = asset.position,
			health = asset.health,
			maxHealth = asset.maxHealth,
		}
	end
	return copy
end

local function getPlacementSnapshot(plotEntity: number): PlacementSnapshot
	local now = os.clock()
	local snapshot = placementSnapshotByPlot[plotEntity]
	if snapshot and (now - snapshot.timestamp) <= PLACEMENT_SNAPSHOT_TTL then
		return snapshot
	end

	local placements = PlacementWorld.ListPlacements(plotEntity)
	local assets = collectPlacementAssets(placements)
	local requirements = summarizePlacementRequirements(assets)
	snapshot = {
		timestamp = now,
		placements = placements,
		assets = assets,
		requirements = requirements,
	}
	placementSnapshotByPlot[plotEntity] = snapshot
	return snapshot
end

local function applySnapshotToController(controller: WaveController, plotEntity: number)
	local snapshot = getPlacementSnapshot(plotEntity)
	controller.placementsCache = clonePlacementList(snapshot.placements)
	controller.assetCache = clonePlacementAssets(snapshot.assets)
	controller.requirementState = cloneRequirementState(snapshot.requirements)
	controller.assetRefreshElapsed = 0
	if #controller.assetCache > 0 then
		controller.hadAssets = true
	end
end

local function invalidatePlacementSnapshot(plotEntity: number)
	placementSnapshotByPlot[plotEntity] = nil
end

local function invalidatePlacementSnapshotForOwner(ownerUserId: number?)
	if not ownerUserId or ownerUserId <= 0 then
		return
	end
	local plotEntity = PlacementWorld.GetPlotByOwner(ownerUserId)
	if plotEntity then
		invalidatePlacementSnapshot(plotEntity)
	end
end

local function requirementStatesEqual(lhs: RequirementState?, rhs: RequirementState?): boolean
	if lhs == rhs then
		return true
	end
	if not lhs or not rhs then
		return false
	end
	if lhs.hasMoney ~= rhs.hasMoney then
		return false
	end
	if lhs.hasWeapon ~= rhs.hasWeapon then
		return false
	end
	return true
end

local function hasRequiredPlacements(assets: { PlacementAsset }): (boolean, RequirementState)
	local summary = summarizePlacementRequirements(assets)
	return summary.hasMoney and summary.hasWeapon, summary
end

local function refreshControllerAssets(controller: WaveController): { PlacementAsset }
	local ownerId = controller.ownerUserId
	if not ownerId then
		controller.assetCache = {}
		controller.placementsCache = {}
		controller.requirementState = EMPTY_REQUIREMENTS
		return {}
	end

	local plotEntity = PlacementWorld.GetPlotByOwner(ownerId)
	if not plotEntity then
		controller.assetCache = {}
		controller.placementsCache = {}
		controller.requirementState = EMPTY_REQUIREMENTS
		return {}
	end

	applySnapshotToController(controller, plotEntity)
	return controller.assetCache or {}
end

local function controllerHasStartRequirements(controller: WaveController): boolean
	local assets = controller.assetCache
	if not assets or #assets == 0 then
		assets = refreshControllerAssets(controller)
	end
	assets = assets or {}
	local hasRequired, summary = hasRequiredPlacements(assets)
	controller.requirementState = summary
	return hasRequired
end

local function getClosestWaypointIndex(entries: { WaypointEntry }, position: Vector3): number?
	local closestIndex: number? = nil
	local closestDistance = math.huge
	for index, waypoint in ipairs(entries) do
		local distance = (waypoint.position - position).Magnitude
		if distance < closestDistance then
			closestDistance = distance
			closestIndex = index
		end
	end
	return closestIndex
end

local function cloneVectorArray(source: { Vector3 })
	local copy = table.create(#source)
	for index, value in ipairs(source) do
		copy[index] = value
	end
	return copy
end

local waypointCacheByNav: { [NavigationData]: { [string]: any } } = setmetatable({}, { __mode = "k" })

local function getWaypointCache(navEntry: NavigationData): { [string]: any }
	local cache = waypointCacheByNav[navEntry]
	if not cache then
		cache = {}
		waypointCacheByNav[navEntry] = cache
	end
	return cache
end

local function buildWaypointCacheKey(startIndex: number, finishIndex: number): string
	return string.format("%d:%d", startIndex, finishIndex)
end

local function computeWaypointPositions(navEntry: NavigationData, start: Vector3, finish: Vector3): ({ Vector3 }?, number?)
	local waypoints = navEntry.waypointEntries
	if not waypoints or #waypoints == 0 then
		return nil, nil
	end

	local startIndex = getClosestWaypointIndex(waypoints, start)
	local finishIndex = getClosestWaypointIndex(waypoints, finish)
	if not startIndex or not finishIndex then
		return nil, nil
	end

	local cache = getWaypointCache(navEntry)
	local cacheKey = buildWaypointCacheKey(startIndex, finishIndex)
	local cachedEntry = cache[cacheKey]
	if cachedEntry ~= nil then
		if cachedEntry == false then
			return nil, nil
		end
		return cloneVectorArray(cachedEntry.positions), cachedEntry.goalIndex
	end

	local graph = navEntry.waypointGraph
	if not graph then
		return nil, nil
	end

	local queue = { startIndex }
	local visited = { [startIndex] = true }
	local previous: { [number]: number } = {}
	local found = false

	while #queue > 0 do
		local current = table.remove(queue, 1)
		if current == finishIndex then
			found = true
			break
		end
		local neighbors = graph[current]
		if neighbors then
			for _, neighbor in ipairs(neighbors) do
				if not visited[neighbor] then
					visited[neighbor] = true
					previous[neighbor] = current
					queue[#queue + 1] = neighbor
				end
			end
		end
	end

	if not found then
		local fallback = { finish }
		cache[cacheKey] = {
			positions = cloneVectorArray(fallback),
			goalIndex = finishIndex,
		}
		return fallback, finishIndex
	end

	local path = {}
	local current = finishIndex
	while current do
		table.insert(path, 1, waypoints[current].position)
		current = previous[current]
	end

	cache[cacheKey] = {
		positions = cloneVectorArray(path),
		goalIndex = finishIndex,
	}
	return path, finishIndex
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

local function computeReward(definition: BossDefinition, multiplier: number): number
	local baseMin = math.max(1, math.floor(definition.rewardMin * multiplier + 0.5))
	local baseMax = math.max(baseMin, math.floor(definition.rewardMax * multiplier + 0.5))
	return rng:NextInteger(baseMin, baseMax)
end

local function bufferBossReward(agent: BrainrotAgent)
	local ownerUserId = agent.ownerUserId
	if not ownerUserId or ownerUserId <= 0 then
		return
	end
	local player = Players:GetPlayerByUserId(ownerUserId)
	if not player then
		return
	end

	local bucket = pendingRewardBuckets[ownerUserId]
	if not bucket then
		bucket = {
			money = 0,
			score = 0,
			highestTier = 0,
			defeated = {},
			lastBoss = nil,
		}
		pendingRewardBuckets[ownerUserId] = bucket
	end

	bucket.money += agent.rewardMoney
	bucket.score += agent.progressionValue
	bucket.highestTier = math.max(bucket.highestTier, agent.definition.tier)
	bucket.defeated[agent.brainrotName] = (bucket.defeated[agent.brainrotName] or 0) + 1
	bucket.lastBoss = agent.brainrotName
end

local function flushPendingRewards()
	for ownerUserId, bucket in pairs(pendingRewardBuckets) do
		local player = Players:GetPlayerByUserId(ownerUserId)
		if player then
			Profiles.Mutate(player, function(data)
				if typeof(data) ~= "table" then
					return nil
				end
				data.Money = (tonumber(data.Money) or 0) + bucket.money
				local progress = ensureBrainrotProgress(data)
				if progress then
					progress.score += bucket.score
					progress.highestTier = math.max(progress.highestTier, bucket.highestTier)
					for name, count in pairs(bucket.defeated) do
						local defeated = progress.defeated
						defeated[name] = (defeated[name] or 0) + count
						progress.defeatedIndex[name] = true
					end
					if bucket.lastBoss then
						progress.lastBoss = bucket.lastBoss
					end
				end
				return nil
			end)
		end
		pendingRewardBuckets[ownerUserId] = nil
	end
end

local function grantBossReward(agent: BrainrotAgent)
	bufferBossReward(agent)
end

type MutationEffect = { [string]: number }
type MutationTotals = { [string]: number }

local MUTATION_MODIFIERS: { [string]: MutationEffect } = {
	Night = {
		moveSpeed = 0.15,
		attackDamage = 0.15,
	},
	BrainrotsCrazy = {
		moveSpeed = 0.5,
	},
}

local function computeMutationTotals(state: { [string]: boolean }?): MutationTotals
	local totals: MutationTotals = {}
	if typeof(state) ~= "table" then
		return totals
	end
	for mutationId, active in pairs(state) do
		if active then
			local modifier = MUTATION_MODIFIERS[mutationId]
			if modifier then
				for property, percent in pairs(modifier) do
					totals[property] = (totals[property] or 0) + percent
				end
			end
		end
	end
	return totals
end

local function applyMutationEffectsToAgent(agent: BrainrotAgent, totals: MutationTotals)
	for property, percent in pairs(totals) do
		if property == "moveSpeed" then
			local multiplier = math.max(0, 1 + percent)
			agent.moveSpeed = math.max(1, agent.moveSpeed * multiplier)
			agent.baseMoveSpeed = math.max(1, agent.baseMoveSpeed * multiplier)
		elseif property == "attackDamage" then
			agent.attackDamage = math.max(1, math.floor(agent.attackDamage * (1 + percent) + 0.5))
		end
	end
end

local function computeWaveDifficultyPercent(waveIndex: number): number
	return math.clamp((waveIndex - 1) * 45, 0, 1000)
end

local function computeScaledStats(definition: BossDefinition, waveIndex: number)
	local percent = computeWaveDifficultyPercent(waveIndex)
	local healthMultiplier = 1 + (percent * 0.008)
	local moveMultiplier = 1 + (percent * 0.003)
	local damageMultiplier = 1 + (percent * 0.01)
	local intervalMultiplier = math.max(1 - (percent * 0.003), 0.2)

	local scaledMaxHealth = math.max(1, math.floor(definition.maxHealth * healthMultiplier + 0.5))
	local scaledMoveSpeed = math.max(1, definition.moveSpeed * moveMultiplier)
	local scaledDamage = math.max(1, math.floor(definition.attackDamage * damageMultiplier + 0.5))
	local scaledInterval = math.max(0.25, definition.attackInterval * intervalMultiplier)

	return {
		maxHealth = scaledMaxHealth,
		moveSpeed = scaledMoveSpeed,
		attackDamage = scaledDamage,
		attackInterval = scaledInterval,
	}
end

local function buildAgentSnapshot(controller: WaveController, agent: BrainrotAgent)
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
		sprinting = agent.sprintActive,
	}
end

local function rollSprintCooldown(): number
	return rng:NextNumber(SPRINT_MIN_COOLDOWN, SPRINT_MAX_COOLDOWN)
end

local function rollSprintDuration(): number
	return rng:NextNumber(SPRINT_MIN_DURATION, SPRINT_MAX_DURATION)
end

local function enableAgentSprint(agent: BrainrotAgent): boolean
	if agent.sprintActive then
		return false
	end

	agent.sprintActive = true
	agent.sprintRemaining = rollSprintDuration()
	agent.moveSpeed = math.max(1, agent.baseMoveSpeed * agent.sprintMultiplier)
	return true
end

local function disableAgentSprint(agent: BrainrotAgent, resetCooldown: boolean): boolean
	if not agent.sprintActive then
		if resetCooldown and agent.sprintCooldown <= 0 then
			agent.sprintCooldown = rollSprintCooldown()
		end
		return false
	end

	agent.sprintActive = false
	agent.sprintRemaining = 0
	agent.moveSpeed = agent.baseMoveSpeed
	if resetCooldown or agent.sprintCooldown <= 0 then
		agent.sprintCooldown = rollSprintCooldown()
	end
	return true
end

local function tickAgentSprint(controller: WaveController, agent: BrainrotAgent, deltaTime: number)
	if agent.state ~= "toBuilding" or not SPRINT_FEATURE_ENABLED or not agent.sprintEligible then
		if agent.sprintActive and disableAgentSprint(agent, true) then
			TourismPackets.AgentSpawn:Fire(buildAgentSnapshot(controller, agent))
		end
		return
	end

	if agent.sprintActive then
		agent.sprintRemaining -= deltaTime
		if agent.sprintRemaining <= 0 then
			if disableAgentSprint(agent, true) then
				TourismPackets.AgentSpawn:Fire(buildAgentSnapshot(controller, agent))
			end
		end
		return
	end

	agent.sprintCooldown -= deltaTime
	if agent.sprintCooldown <= 0 and enableAgentSprint(agent) then
		agent.sprintCooldown = rollSprintCooldown()
		TourismPackets.AgentSpawn:Fire(buildAgentSnapshot(controller, agent))
	end
end

local function computeAttackCooldown(agent: BrainrotAgent): number
	local baseInterval = math.max(agent.attackInterval, 0.4)
	local minCooldown = math.max(baseInterval * 0.5, 0.2)
	local maxCooldown = math.max(minCooldown + 0.05, baseInterval * 1.35)
	return rng:NextNumber(minCooldown, maxCooldown)
end

local function attackBuilding(agent: BrainrotAgent): "continue" | "lost" | "destroyed"
	local api = placementServiceApi
	if not api then
		return "lost"
	end

	local variance = rng:NextNumber(0.65, 1.25)
	local damage = math.max(1, math.floor(agent.attackDamage * variance + 0.5))
	local success, result = api.ApplyDamageToPlacement(agent.targetEntity, damage)
	if not success or not result then
		return "lost"
	end
	if result.destroyed then
		invalidatePlacementSnapshotForOwner(agent.ownerUserId)
		return "destroyed"
	end
	return "continue"
end

local function tryAssignNewTarget(controller: WaveController, agent: BrainrotAgent): boolean
	if controller.defeated then
		return false
	end

	if agent.targetEntity then
		controller.activeTargets[agent.targetEntity] = nil
	end

	local ownerId = controller.ownerUserId
	if not ownerId then
		return false
	end

	local plotEntity = PlacementWorld.GetPlotByOwner(ownerId)
	if not plotEntity then
		return false
	end

	local snapshot = getPlacementSnapshot(plotEntity)
	local placements = snapshot.placements
	if #placements == 0 then
		return false
	end

	local assets = snapshot.assets
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
	local target = selection[rng:NextInteger(1, #selection)]
	local path, goalIndex = computeWaypointPositions(controller.navEntry, agent.position, target.position)
	if not path or #path == 0 then
		return false
	end

	controller.activeTargets[target.entity] = true
	agent.targetEntity = target.entity
	agent.targetPosition = target.position
	agent.state = "toBuilding"
	agent.path = path
	agent.pathIndex = 1
	agent.goalWaypointIndex = goalIndex or agent.goalWaypointIndex
	agent.attackAnchor = nil
	agent.attackCooldown = computeAttackCooldown(agent)

	TourismPackets.AgentSpawn:Fire(buildAgentSnapshot(controller, agent))
	return true
end

local function destroyAgent(controller: WaveController, index: number, reason: string?, defeatedCredit: boolean?)
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
	})

	table.remove(controller.agents, index)

	if defeatedCredit and agent.waveIndex == controller.wave.index then
		controller.wave.defeated += 1
		controller.signals.stateChanged:Fire()
		syncWaveEntity(controller)
		evaluateSkipPrompt(controller)
		tryCompleteWave(controller)
	end
end

local function markControllerDefeated(controller: WaveController, reason: string?)
	controller.defeated = true
	local wave = controller.wave
	local rollbackWave = computeRollbackWaveIndex(wave.index)
	if wave.countdownPromise then
		wave.countdownPromise:cancel()
		wave.countdownPromise = nil
	end
	for index = #controller.agents, 1, -1 do
		destroyAgent(controller, index, reason or "Defeated", false)
	end
	wave.timer.mode = "idle"
	wave.timer.duration = 0
	wave.timer.elapsed = 0
	wave.timer.remaining = 0
	controller.timerBroadcastElapsed = 0
	wave.promptIssued = false
	wave.status = "defeated"
	wave.index = rollbackWave
	wave.total = 0
	wave.spawned = 0
	wave.defeated = 0
	syncWaveEntity(controller)
	controller.signals.stateChanged:Fire()
	controller.signals.timerChanged:Fire()

	saveControllerWaveProgress(controller, rollbackWave)
end

local function stepAgent(controller: WaveController, agent: BrainrotAgent, deltaTime: number): (boolean, string?)
	tickAgentSprint(controller, agent, deltaTime)
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
				if agent.sprintActive then
					disableAgentSprint(agent, true)
				end
				agent.state = "attacking"
				agent.path = {}
				agent.pathIndex = 0
				agent.attackAnchor = target
				agent.position = target
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

	agent.attackCooldown -= deltaTime
	if agent.attackCooldown > 0 then
		return true, nil
	end

	local outcome = attackBuilding(agent)
	if outcome == "continue" then
		agent.attackCooldown = computeAttackCooldown(agent)
		return true, nil
	end

	if tryAssignNewTarget(controller, agent) then
		return true, nil
	end

	return false, if outcome == "destroyed" then "TargetDestroyed" else "TargetLost"
end

local function updateAgents(controller: WaveController, deltaTime: number)
	local index = 1
	while index <= #controller.agents do
		local agent = controller.agents[index]
		local alive, reason = stepAgent(controller, agent, deltaTime)
		if alive then
			index += 1
		else
			destroyAgent(controller, index, reason, false)
		end
	end
end

local function spawnAgentForBrainrot(
	controller: WaveController,
	plotEntity: number,
	ownerUserId: number,
	placements: { number },
	assets: { PlacementAsset },
	spawnEntry: SpawnEntry?,
	brainrotName: string,
	rewardMultiplier: number
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

	if #placements == 0 then
		return false
	end
	if #assets == 0 then
		return false
	end

	local definition = resolveBossDefinition(brainrotName)
	if not definition then
		return false
	end

	local spawn = spawnEntry or navEntry.spawns[rng:NextInteger(1, #navEntry.spawns)]
	local spawnPosition = spawn.position

	local available: { PlacementAsset } = {}
	for _, asset in ipairs(assets) do
		if not controller.activeTargets[asset.entity] then
			available[#available + 1] = asset
		end
	end

	if #available == 0 then
		return false
	end

	local targetAsset = available[rng:NextInteger(1, #available)]
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

	local templateExtents = template:GetExtentsSize() * 0.5
	local stats = computeScaledStats(definition, controller.wave.index)
	controller.activeTargets[targetAsset.entity] = true
	controller.agentCounter += 1
	local agentId = string.format("%d_%d", controller.index, controller.agentCounter)

	local agent: BrainrotAgent = {
		id = agentId,
		definition = definition,
		brainrotName = definition.name,
		state = "toBuilding",
		path = path,
		pathIndex = 1,
		goalWaypointIndex = goalIndex or 1,
		navEntry = navEntry,
		spawnEntry = spawn,
		position = spawnPosition,
		targetPosition = targetAsset.position,
		targetEntity = targetAsset.entity,
		ownerUserId = ownerUserId,
		moveSpeed = stats.moveSpeed,
		baseMoveSpeed = stats.moveSpeed,
		arrivalTolerance = definition.arrivalTolerance or DEFAULT_TOLERANCE,
		attackInterval = stats.attackInterval,
		attackCooldown = stats.attackInterval,
		attackDamage = stats.attackDamage,
		attackRadius = definition.attackRadius,
		maxHealth = stats.maxHealth,
		health = stats.maxHealth,
		rewardMoney = computeReward(definition, rewardMultiplier),
		progressionValue = definition.progressionValue,
		waveIndex = controller.wave.index,
		faceRotationAdjustment = computeFaceRotationAdjustment(template, primary),
		sprintEligible = SPRINT_FEATURE_ENABLED and (rng:NextNumber() <= SPRINT_ELIGIBLE_CHANCE),
		sprintActive = false,
		sprintRemaining = 0,
		sprintCooldown = rollSprintCooldown(),
		sprintMultiplier = SPRINT_SPEED_MULTIPLIER,
	}

	agent.extents = Vector3.new(
		math.max(0.5, templateExtents.X),
		math.max(0.5, templateExtents.Y),
		math.max(0.5, templateExtents.Z)
	)

	applyMutationEffectsToAgent(agent, currentMutationTotals)
	controller.agents[#controller.agents + 1] = agent
	registerAgent(controller, agent)
	TourismPackets.AgentSpawn:Fire(buildAgentSnapshot(controller, agent))
	return true
end

local function computeWaveDuration(config: BrainrotWaves.WaveConfig): number
	local maxTime = 0
	for _, group in ipairs(config.groups) do
		local delay = math.max(0, group.spawnDelay or 0)
		local interval = math.max(0.1, group.interval or 1)
		local total = math.max(0, math.floor(group.count + 0.5))
		local duration = delay + (interval * math.max(total - 1, 0))
		if duration > maxTime then
			maxTime = duration
		end
	end
	return maxTime
end

local function buildSpawnQueue(config: BrainrotWaves.WaveConfig): { SpawnGroupRuntime }
	local queue: { SpawnGroupRuntime } = {}
	for _, group in ipairs(config.groups) do
		queue[#queue + 1] = {
			brainrot = group.brainrot,
			remaining = math.max(0, math.floor(group.count + 0.5)),
			interval = math.max(0.1, group.interval or 1),
			spawnDelay = math.max(0, group.spawnDelay or 0),
			burst = group.burst == true,
			cooldown = math.max(0, group.spawnDelay or 0),
		}
	end
	return queue
end

local function beginWave(controller: WaveController, waveIndex: number)
	local config = BrainrotWaves.GetWave(waveIndex)
	local queue = buildSpawnQueue(config)
	local total = 0
	for _, group in ipairs(queue) do
		total += group.remaining
	end

	local wave = controller.wave
	wave.index = waveIndex
	wave.status = "spawning"
	wave.groups = queue
	wave.total = total
	wave.spawned = 0
	wave.defeated = 0
	wave.promptIssued = false
	wave.skipThreshold = config.skipThreshold or BrainrotWaves.DEFAULT_SKIP_THRESHOLD
	wave.rewardMultiplier = config.rewardMultiplier or 1
	wave.timer.mode = "spawning"
	wave.timer.duration = math.max(1, computeWaveDuration(config))
	wave.timer.elapsed = 0
	wave.timer.remaining = wave.timer.duration
	controller.timerBroadcastElapsed = 0
	wave.countdownPromise = nil

	syncWaveEntity(controller)
	controller.signals.stateChanged:Fire()
	controller.signals.timerChanged:Fire()

	saveControllerWaveProgress(controller, waveIndex)
end

local function cancelCountdown(controller: WaveController)
	local wave = controller.wave
	if wave.countdownPromise then
		wave.countdownPromise:cancel()
		wave.countdownPromise = nil
	end
end

local function scheduleNextWave(controller: WaveController)
	cancelCountdown(controller)
	local wave = controller.wave
	wave.status = "cooldown"
	wave.timer.mode = "cooldown"
	local nextWaveIndex = wave.index + 1
	local duration = WAVE_START_DELAY
	wave.timer.duration = duration
	wave.timer.elapsed = 0
	wave.timer.remaining = duration
	controller.timerBroadcastElapsed = 0
	wave.promptIssued = false

	saveControllerWaveProgress(controller, math.max(1, nextWaveIndex))

	syncWaveEntity(controller)
	controller.signals.stateChanged:Fire()
	controller.signals.timerChanged:Fire()

	wave.countdownPromise = Promise.delay(duration):andThen(function()
		if not controller.alive then
			return
		end
		if not controller.ownerUserId then
			resetWaveRuntime(controller, math.max(1, nextWaveIndex))
			return
		end
		if not controllerHasStartRequirements(controller) then
			resetWaveRuntime(controller, math.max(1, nextWaveIndex))
			return
		end
		beginWave(controller, nextWaveIndex)
	end)
	wave.countdownPromise:catch(function() end)
end

evaluateSkipPrompt = function(controller: WaveController)
	local wave = controller.wave
	if wave.status ~= "spawning" then
		return
	end
	if wave.promptIssued then
		return
	end
	if wave.total <= 0 then
		return
	end
	local configuredThreshold = math.clamp(wave.skipThreshold or BrainrotWaves.DEFAULT_SKIP_THRESHOLD, 0, 1)
	local threshold = math.max(0.75, configuredThreshold)
	local progress = wave.defeated / math.max(1, wave.total)
	if progress > threshold then
		wave.promptIssued = true
		syncWaveEntity(controller)
		controller.signals.stateChanged:Fire()
		controller.signals.promptChanged:Fire()
	end
end

tryCompleteWave = function(controller: WaveController)
	local wave = controller.wave
	if wave.status ~= "spawning" then
		return
	end
	if wave.total == 0 then
		return
	end
	if wave.defeated >= wave.total and #controller.agents == 0 then
		scheduleNextWave(controller)
	end
end

local function tickWaveTimer(controller: WaveController, deltaTime: number)
	local wave = controller.wave
	local timer = wave.timer
	if timer.mode == "idle" then
		return
	end
	timer.elapsed += deltaTime
	timer.remaining = math.max(0, timer.duration - timer.elapsed)
	controller.timerBroadcastElapsed += deltaTime
	if controller.timerBroadcastElapsed >= TIMER_BROADCAST_STEP then
		controller.timerBroadcastElapsed -= TIMER_BROADCAST_STEP
		controller.signals.timerChanged:Fire()
	end
end

local function stepWaveSpawning(
	controller: WaveController,
	deltaTime: number,
	plotEntity: number,
	ownerUserId: number,
	placements: { number },
	assets: { PlacementAsset }
)
	local wave = controller.wave
	if wave.status ~= "spawning" then
		return
	end
	if wave.total == 0 then
		return
	end

	local capacity = math.max(0, MAX_ACTIVE_AGENTS - #controller.agents)
	if capacity <= 0 then
		return
	end

	for _, group in ipairs(wave.groups) do
		if capacity <= 0 then
			break
		end

		if group.remaining <= 0 then
			continue
		end

		if group.spawnDelay > 0 then
			group.spawnDelay = math.max(0, group.spawnDelay - deltaTime)
			group.cooldown = group.spawnDelay
			continue
		end

		group.cooldown -= deltaTime
		while group.remaining > 0 and group.cooldown <= 0 and capacity > 0 do
			if spawnAgentForBrainrot(controller, plotEntity, ownerUserId, placements, assets, nil, group.brainrot, wave.rewardMultiplier) then
				group.remaining -= 1
				wave.spawned += 1
				syncWaveEntity(controller)
				controller.signals.stateChanged:Fire()
				capacity -= 1
			else
				group.cooldown = group.interval
				break
			end

			if group.burst then
				group.cooldown = 0
			else
				group.cooldown += group.interval
			end
		end
	end
end

local function updateController(controller: WaveController, deltaTime: number)
	if not controller.alive then
		return
	end

	updateAgents(controller, deltaTime)
	tickWaveTimer(controller, deltaTime)

	local slot = controller.slot
	if not slot then
		return
	end

	local ownerId = slot:GetOwnerId()
	if not ownerId then
		if controller.ownerUserId then
			controller.ownerUserId = nil
			controller.progressLoadedFor = nil
			for index = #controller.agents, 1, -1 do
				destroyAgent(controller, index, "OwnerMissing", false)
			end
			resetWaveRuntime(controller, 1)
		end
		controller.assetCache = {}
		controller.placementsCache = {}
		controller.requirementState = EMPTY_REQUIREMENTS
		return
	end

	if controller.ownerUserId and controller.ownerUserId ~= ownerId then
		controller.progressLoadedFor = nil
		for index = #controller.agents, 1, -1 do
			destroyAgent(controller, index, "OwnerChanged", false)
		end
		resetWaveRuntime(controller, 1)
	end
	controller.ownerUserId = ownerId
	applySavedWaveProgress(controller)
	local plotEntity = PlacementWorld.GetPlotByOwner(ownerId)
	if not plotEntity then
		controller.requirementState = EMPTY_REQUIREMENTS
		return
	end

	controller.assetRefreshElapsed += deltaTime
	if controller.assetRefreshElapsed >= PLACEMENT_SNAPSHOT_TTL or not controller.placementsCache then
		applySnapshotToController(controller, plotEntity)
	end

 	local placements = controller.placementsCache or {}
 	local assets = controller.assetCache or {}
 	local hasAssets = #assets > 0
 	if hasAssets then
 		controller.hadAssets = true
 	end
	local previousRequirements = controller.requirementState
	local hasRequired, requirements = hasRequiredPlacements(assets)
	local requirementsChanged = not requirementStatesEqual(previousRequirements, requirements)
	controller.requirementState = requirements
	if requirementsChanged then
		controller.signals.stateChanged:Fire()
	end

	if controller.wave.status == "spawning" and not hasRequired then
		markControllerDefeated(controller, "PlacementsMissing")
		return
	end

	if controller.defeated then
		if hasRequired then
			resetWaveRuntime(controller, math.max(1, controller.wave.index))
		else
			if controller.wave.status ~= "defeated" then
				controller.wave.status = "defeated"
				syncWaveEntity(controller)
				controller.signals.stateChanged:Fire()
			end
			return
		end
	end

	if controller.wave.status ~= "spawning" and controller.wave.status ~= "cooldown" then
		local desiredStatus = if hasRequired then "waitingStart" else "idle"
		if controller.wave.status ~= desiredStatus then
			controller.wave.status = desiredStatus
			syncWaveEntity(controller)
			controller.signals.stateChanged:Fire()
		end
	end

	if not hasAssets then
		return
	end

	if controller.wave.status == "spawning" then
		stepWaveSpawning(controller, deltaTime, plotEntity, ownerId, placements, assets)
	end
end

local function handleStartRequested(player: Player, plotIndex: number?)
	local controller = if plotIndex then controllers[plotIndex] else nil
	if not controller then
		return
	end
	if controller.ownerUserId ~= player.UserId then
		return
	end

	if not controllerHasStartRequirements(controller) then
		return
	end

	local targetWave = controller.wave.index
	if controller.wave.status == "cooldown" then
		targetWave += 1
	end
	local startWave = math.max(1, targetWave)
	resetWaveRuntime(controller, startWave)
	beginWave(controller, startWave)
end

local function handleSkipRequested(player: Player, plotIndex: number?)
	local controller = if plotIndex then controllers[plotIndex] else nil
	if not controller then
		return
	end
	if controller.ownerUserId ~= player.UserId then
		return
	end
	local wave = controller.wave
	if wave.status ~= "spawning" then
		return
	end
	if not wave.promptIssued then
		return
	end

	wave.defeated = wave.total
	wave.promptIssued = false
	controller.signals.stateChanged:Fire()
	syncWaveEntity(controller)
	tryCompleteWave(controller)
end

local function sendSnapshotsToPlayer(player: Player)
	local payload = {}
	for _, controller in pairs(controllers) do
		for _, agent in ipairs(controller.agents) do
			payload[#payload + 1] = buildAgentSnapshot(controller, agent)
		end
	end
	if #payload > 0 then
		TourismPackets.AgentSnapshot:FireClient(player, { agents = payload })
	end
end

local function getOwnerPlayer(controller: WaveController): Player?
	local ownerId = controller.ownerUserId
	if not ownerId then
		return nil
	end
	return Players:GetPlayerByUserId(ownerId)
end

local function sendWaveState(controller: WaveController)
	local player = getOwnerPlayer(controller)
	if not player then
		return
	end

	local wave = controller.wave
	TourismPackets.WaveState:FireClient(player, {
		plotIndex = controller.index,
		wave = math.max(1, wave.index),
		status = wave.status,
		total = wave.total,
		spawned = wave.spawned,
		defeated = wave.defeated,
		skipThreshold = wave.skipThreshold,
		prompt = wave.promptIssued,
		requirements = controller.requirementState or EMPTY_REQUIREMENTS,
	})
end

local function sendWaveTimer(controller: WaveController)
	local player = getOwnerPlayer(controller)
	if not player then
		return
	end

	local timer = controller.wave.timer
	TourismPackets.WaveTimer:FireClient(
		player,
		controller.wave.index,
		math.max(0, timer.remaining),
		math.max(0, timer.elapsed)
	)
end

local function sendWavePrompt(controller: WaveController)
	local player = getOwnerPlayer(controller)
	if not player then
		return
	end

	TourismPackets.WavePrompt:FireClient(player, {
		plotIndex = controller.index,
		wave = controller.wave.index,
	})
end

local function newWaveTimer(): WaveTimerInfo
	return {
		mode = "idle",
		duration = 0,
		elapsed = 0,
		remaining = 0,
	}
end

local function newWaveRuntime(): WaveRuntime
	return {
		index = 1,
		status = "idle",
		skipThreshold = BrainrotWaves.DEFAULT_SKIP_THRESHOLD,
		rewardMultiplier = 1,
		total = 0,
		spawned = 0,
		defeated = 0,
		promptIssued = false,
		groups = {},
		timer = newWaveTimer(),
		countdownPromise = nil,
	}
end

resetWaveRuntime = function(controller: WaveController, startWave: number)
	local wave = controller.wave
	wave.index = math.max(1, startWave)
	wave.status = "idle"
	wave.total = 0
	wave.spawned = 0
	wave.defeated = 0
	wave.promptIssued = false
	wave.groups = {}
	wave.skipThreshold = BrainrotWaves.DEFAULT_SKIP_THRESHOLD
	wave.rewardMultiplier = 1
	if wave.countdownPromise then
		wave.countdownPromise:cancel()
	end
	wave.countdownPromise = nil
	wave.timer = newWaveTimer()
	controller.defeated = false
	controller.timerBroadcastElapsed = 0
	sendWaveState(controller)
	sendWaveTimer(controller)
end

local function initWaveSignals(controller: WaveController)
	local signals = {
		stateChanged = Signal.new(),
		timerChanged = Signal.new(),
		promptChanged = Signal.new(),
	}
	signals.stateChanged:Connect(function()
		sendWaveState(controller)
	end)
	signals.timerChanged:Connect(function()
		sendWaveTimer(controller)
	end)
	signals.promptChanged:Connect(function()
		sendWavePrompt(controller)
	end)
	controller.signals = signals
end

ensureWaveEntity = function(controller: WaveController)
	if controller.waveEntity then
		return
	end
	local entity = waveWorld:entity()
	waveWorld:set(entity, WaveComponents.Controller, controller.index)
	waveWorld:set(entity, WaveComponents.WaveNumber, controller.wave.index)
	waveWorld:set(entity, WaveComponents.Status, controller.wave.status)
	waveWorld:set(entity, WaveComponents.Spawned, controller.wave.spawned)
	waveWorld:set(entity, WaveComponents.Defeated, controller.wave.defeated)
	waveWorld:set(entity, WaveComponents.SkipThreshold, controller.wave.skipThreshold)
	waveWorld:set(entity, WaveComponents.PromptIssued, controller.wave.promptIssued)
	controller.waveEntity = entity
end

syncWaveEntity = function(controller: WaveController)
	local entity = controller.waveEntity
	if not entity then
		return
	end
	local wave = controller.wave
	waveWorld:set(entity, WaveComponents.WaveNumber, wave.index)
	waveWorld:set(entity, WaveComponents.Status, wave.status)
	waveWorld:set(entity, WaveComponents.Spawned, wave.spawned)
	waveWorld:set(entity, WaveComponents.Defeated, wave.defeated)
	waveWorld:set(entity, WaveComponents.SkipThreshold, wave.skipThreshold)
	waveWorld:set(entity, WaveComponents.PromptIssued, wave.promptIssued)
end

local function createController(index: number, navEntry: NavigationData)
	local slot = PlotRegistry.GetSlot(index)
	local controller: WaveController = {
		index = index,
		slot = slot,
		navEntry = navEntry,
		agents = {},
		activeTargets = {},
		ownerUserId = nil,
		progressLoadedFor = nil,
		wave = newWaveRuntime(),
		signals = ({} :: WaveSignals),
		waveEntity = nil,
		assetCache = {},
		placementsCache = {},
		requirementState = EMPTY_REQUIREMENTS,
		assetRefreshElapsed = 0,
		defeated = false,
		hadAssets = false,
		recentSpawnHistory = {},
		recentSpawnLookup = {},
		agentCounter = 0,
		movementCooldown = 0,
		timerBroadcastElapsed = 0,
		alive = true,
	}

	initWaveSignals(controller)

	ensureWaveEntity(controller)
	controllers[index] = controller
	return controller
end

local Runtime = {}

function Runtime.Init()
	if schedulerHandle then
		return
	end

	gatherBrainrotAssets()
	local navByIndex = BrainrotNavigationRegistry.GetAll()
	for index, entry in pairs(navByIndex) do
		if typeof(entry) == "table" and entry.spawns and #entry.spawns > 0 and entry.waypointEntries and #entry.waypointEntries > 0 then
			createController(index, entry)
		end
	end

	MutationService.Init()
	currentMutationTotals = computeMutationTotals(MutationService.GetActiveMutations())
	if mutationConnection then
		mutationConnection:Disconnect()
	end
	mutationConnection = MutationService.Observe(function(state)
		currentMutationTotals = computeMutationTotals(state)
	end)

	if waveControlConnection then
		waveControlConnection:Disconnect()
	end
	waveControlConnection = TourismPackets.WaveControl.OnServerEvent:Connect(function(player: Player, action: string, payload: { plotIndex: number }?)
		if action == "start" then
			handleStartRequested(player, payload and payload.plotIndex)
		elseif action == "skip" then
			handleSkipRequested(player, payload and payload.plotIndex)
		end
	end)

	if playerAddedConnection then
		playerAddedConnection:Disconnect()
	end
	playerAddedConnection = Players.PlayerAdded:Connect(sendSnapshotsToPlayer)
	for _, player in Players:GetPlayers() do
		sendSnapshotsToPlayer(player)
	end

	schedulerHandle = RunServiceScheduler.register(MOVE_INTERVAL, function(totalDelta: number, ticks: number)
		local steps = math.max(1, ticks)
		local delta = totalDelta / steps
		for _ = 1, steps do
			for _, controller in pairs(controllers) do
				updateController(controller, delta)
			end
		end
		flushPendingRewards()
	end)
end

function Runtime.Shutdown()
	if schedulerHandle then
		RunServiceScheduler.unregister(schedulerHandle)
		schedulerHandle = nil
	end
	if mutationConnection then
		mutationConnection:Disconnect()
		mutationConnection = nil
	end
	if waveControlConnection then
		waveControlConnection:Disconnect()
		waveControlConnection = nil
	end
	if playerAddedConnection then
		playerAddedConnection:Disconnect()
		playerAddedConnection = nil
	end
	for _, controller in pairs(controllers) do
		controller.alive = false
		for index = #controller.agents, 1, -1 do
			destroyAgent(controller, index, "Shutdown", false)
		end
	end
	controllers = {}
	agentById = {}
	agentControllerMap = {}
	agentsByOwner = {}
	pendingRewardBuckets = {}
end

function Runtime.ConfigurePlacementService(api)
	placementServiceApi = api
end

function Runtime.ApplyDamage(agentId: string, amount: number, _metadata: any?): (boolean, number?)
	local agent = agentById[agentId]
	if not agent then
		return false, nil
	end

	local damage = math.max(0, tonumber(amount) or 0)
	if damage <= 0 then
		return true, agent.health
	end

	agent.health = math.max(0, agent.health - damage)
	local controller = agentControllerMap[agentId]
	if not controller then
		return true, agent.health
	end

	if agent.health <= 0 then
		agent.health = 0
		grantBossReward(agent)
		for index, stored in ipairs(controller.agents) do
			if stored.id == agentId then
				destroyAgent(controller, index, "Defeated", true)
				break
			end
		end
	else
		TourismPackets.AgentSpawn:Fire(buildAgentSnapshot(controller, agent))
	end

	return true, agent.health
end

function Runtime.RemoveAgent(agentId: string, reason: string?): boolean
	local controller = agentControllerMap[agentId]
	if not controller then
		return false
	end
	for index, agent in ipairs(controller.agents) do
		if agent.id == agentId then
			destroyAgent(controller, index, reason or "Removed", false)
			return true
		end
	end
	return false
end

function Runtime.GetAgentDetails(agentId: string): { [string]: any }?
	local agent = agentById[agentId]
	local controller = agent and agentControllerMap[agentId]
	if not agent or not controller then
		return nil
	end
	return {
		id = agent.id,
		plotIndex = controller.index,
		ownerUserId = agent.ownerUserId,
		brainrotName = agent.brainrotName,
		state = agent.state,
		position = agent.position,
		targetEntity = agent.targetEntity,
		health = agent.health,
		maxHealth = agent.maxHealth,
	}
end

function Runtime.GetAgentsForOwner(ownerUserId: number)
	local bucket = agentsByOwner[ownerUserId]
	if not bucket then
		return {}
	end
	local results = {}
	for _, agent in pairs(bucket) do
		results[#results + 1] = {
			id = agent.id,
			plotIndex = agentControllerMap[agent.id] and agentControllerMap[agent.id].index or nil,
			brainrotName = agent.brainrotName,
			state = agent.state,
			position = agent.position,
			health = agent.health,
			maxHealth = agent.maxHealth,
		}
	end
	return results
end

function Runtime.GetAgentsInBox(centerCFrame: CFrame, size: Vector3, ownerUserId: number?)
	local source = if ownerUserId and ownerUserId > 0 then agentsByOwner[ownerUserId] else agentById
	if not source then
		return {}
	end
	local half = size * 0.5
	local results = {}
	for _, agent in pairs(source) do
		local relative = centerCFrame:PointToObjectSpace(agent.position)
		if math.abs(relative.X) <= half.X and math.abs(relative.Y) <= half.Y and math.abs(relative.Z) <= half.Z then
			results[#results + 1] = {
				id = agent.id,
				position = agent.position,
				state = agent.state,
			}
		end
	end
	return results
end

function Runtime.GetActiveAgentsForPlot(plotIndex: number)
	local controller = controllers[plotIndex]
	if not controller then
		return {}
	end
	local results = {}
	for _, agent in ipairs(controller.agents) do
		results[#results + 1] = {
			id = agent.id,
			position = agent.position,
			state = agent.state,
			health = agent.health,
			maxHealth = agent.maxHealth,
		}
	end
	return results
end

return Runtime
