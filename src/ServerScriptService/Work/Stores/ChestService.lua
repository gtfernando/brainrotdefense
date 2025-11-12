--!strict

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")

local Profiles = require(ServerScriptService.Work.Modules.Profiles)
local PlacementInventory = require(ServerScriptService.Work.Modules.PlacementInventory)
local PromptService = require(ReplicatedStorage.ProximityPrompts)
local PlotRegistry = require(script.Parent.Parent.Placement.PlotRegistry)
local ChestRewards = require(script.Parent.ChestRewards)
local PlacementModule = ReplicatedStorage:WaitForChild("Placement")
local Placement = require(PlacementModule)
local PlacementService = require(script.Parent.Parent.Placement.Service)
local PlacementAssetRegistry = Placement.AssetRegistry

local ChestPackets = require(ReplicatedStorage.Network.ChestPackets)
local ChestDefinitions = require(ReplicatedStorage.Data.Chests)

type PlotSlot = PlotRegistry.PlotSlot

type ChestDefinition = {
	name: string,
	price: number,
	lucky: number,
	time: number,
	image: string,
	robuxProduct: number,
	skipProductId: number,
	layoutOrder: number,
	Rewards: { [string]: number }?,
	breakHealth: number,
}

local ORDER_ATTRIBUTE = "OwnerUserId"
local EXPECTED_PROMPT_NAME = "OpenChest"

local openPacket = ChestPackets.Open
local moneyPacket = ChestPackets.MoneyPurchase
local robuxPacket = ChestPackets.RobuxPurchase

type PromptDescriptor = {
	id: string,
	parent: Instance,
	parentPath: {string}?,
	parentTag: string?,
	actionText: string?,
	objectText: string?,
	holdDuration: number?,
	requiresLineOfSight: boolean?,
	maxActivationDistance: number?,
	keyboardKeyCode: Enum.KeyCode?,
	gamepadKeyCode: Enum.KeyCode?,
	style: Enum.ProximityPromptStyle?,
	enabled: boolean?,
	uiOffset: Vector2?,
	name: string?,
}

type ManagedPrompt = {
	id: string,
	slot: PlotSlot,
	source: ProximityPrompt,
	descriptor: PromptDescriptor,
	ownerId: number?,
}

local slotPrompts: { [PlotSlot]: { [string]: ManagedPrompt } } = {}
local promptIndex: { [ProximityPrompt]: ManagedPrompt } = {}
local slotConnections: { [PlotSlot]: RBXScriptConnection } = {}
local playerSlots: { [number]: PlotSlot } = {}

local orderedChests: {ChestDefinition} = {}
local chestLookup: { [string]: ChestDefinition } = {}

type ChestState = {
	id: string,
	definition: ChestDefinition,
	player: Player,
	userId: number,
	slot: PlotSlot,
	cratePart: BasePart,
	model: Model?,
	primaryPart: BasePart,
	ui: Instance?,
	secondsLabel: TextLabel?,
	maxHealth: number,
	health: number,
	remaining: number,
	readyAt: number,
	createdAt: number,
	ready: boolean,
	active: boolean,
	skipPromptId: string?,
	openPromptId: string?,
	anchorTag: string?,
	connections: { RBXScriptConnection },
	modelDestroyConnection: RBXScriptConnection?,
	crateDestroyConnection: RBXScriptConnection?,
	countdownThread: thread?,
	cleaned: boolean,
	pendingSkip: boolean,
	skipPromptLastRefresh: number?,
}

local chestAssetsFolderCache: Folder? = nil
local chestUITemplateCache: Instance? = nil

local crateSlotCache: { [PlotSlot]: { BasePart } } = {}
local crateOccupants: { [BasePart]: ChestState } = {}
local activeChestsByPlayer: { [number]: { [string]: ChestState } } = {}
local pendingSkipQueues: { [number]: { [number]: {ChestState} } } = {}
local pendingRestoreQueue: { [number]: boolean } = {}

local DEFAULT_BREAK_HEALTH = 100

local chestStatesById: { [string]: ChestState } = {}

local function getDefinitionBreakHealth(definition: ChestDefinition): number
	local value = definition.breakHealth
	if typeof(value) ~= "number" or value <= 0 then
		return DEFAULT_BREAK_HEALTH
	end
	return value
end

local function updateChestAttributes(state: ChestState)
	local primaryPart = state.primaryPart
	if primaryPart then
		primaryPart:SetAttribute("ChestId", state.id)
		primaryPart:SetAttribute("ChestHealth", state.health)
		primaryPart:SetAttribute("ChestMaxHealth", state.maxHealth)
	end

	local model = state.model
	if model then
		model:SetAttribute("ChestId", state.id)
		model:SetAttribute("ChestName", state.definition.name)
		model:SetAttribute("ChestHealth", state.health)
		model:SetAttribute("ChestMaxHealth", state.maxHealth)
	end
end

local function clearChestAttributes(state: ChestState)
	local primaryPart = state.primaryPart
	if primaryPart then
		primaryPart:SetAttribute("ChestHealth", nil)
		primaryPart:SetAttribute("ChestMaxHealth", nil)
		primaryPart:SetAttribute("ChestId", nil)
	end

	local model = state.model
	if model then
		model:SetAttribute("ChestId", nil)
		model:SetAttribute("ChestName", nil)
		model:SetAttribute("ChestHealth", nil)
		model:SetAttribute("ChestMaxHealth", nil)
	end
end

local ChestServiceApi = {}

local resolvePlayerSlot: (Player) -> PlotSlot?
local restoreChestsForPlayer: (Player, PlotSlot) -> ()

local warnedMissingChestAssets = false
local warnedMissingChestUI = false

type StoredChestRecord = {
	id: string,
	name: string,
	slotIndex: number,
	crateName: string,
	readyAt: number,
	createdAt: number,
	health: number?,
}

type ChestStorage = {
	version: number,
	active: { [string]: StoredChestRecord },
}

local STORAGE_VERSION = 2

local function ensureChestStorage(profileData: any): ChestStorage
	local container = profileData.Chests
	if typeof(container) ~= "table" then
		container = { version = STORAGE_VERSION, active = {} }
		profileData.Chests = container
	end

	if typeof(container.version) ~= "number" or container.version < STORAGE_VERSION then
		container.version = STORAGE_VERSION
	end

	if typeof(container.active) ~= "table" then
		container.active = {}
	end

	return container :: ChestStorage
end

local function mutateChestStorage(player: Player, handler: (ChestStorage, any) -> any)
	return Profiles.Mutate(player, function(profileData)
		local storage = ensureChestStorage(profileData)
		return handler(storage, profileData)
	end)
end

local function removeStoredPlacementEntry(player: Player, entryId: string)
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
		warn(`Recompensa "{assetId}" no registrada en ReplicatedStorage.Assets: {definitionOrMessage}`)
		return false
	end

	local adjustResult = PlacementInventory.Adjust(player, assetId, 1, 1)
	if not adjustResult then
		warn(`No se pudo actualizar el inventario de placement para {player.Name} con "{assetId}"`)
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
		warn(`No se pudo otorgar la herramienta de placement "{assetId}" a {player.Name}: {message}`)
		PlacementInventory.Adjust(player, assetId, -1, adjustResult.level)
		if storedEntryId then
			removeStoredPlacementEntry(player, storedEntryId)
		end
		return false
	end

	return true
end

local function syncChestStateToProfile(state: ChestState)
	if state.cleaned then
		return
	end

	local player = state.player
	if not player then
		return
	end

	local cratePart = state.cratePart
	if not cratePart or cratePart.Parent == nil then
		return
	end

	local readyAt = state.readyAt or (os.time() + math.max(0, state.remaining))
	local createdAt = state.createdAt or os.time()
	local persistedHealth = state.health
	if typeof(persistedHealth) ~= "number" then
		persistedHealth = getDefinitionBreakHealth(state.definition)
	end
	persistedHealth = math.clamp(math.floor((persistedHealth :: number) + 0.5), 0, getDefinitionBreakHealth(state.definition))

	mutateChestStorage(player, function(storage)
		storage.active[state.id] = {
			id = state.id,
			name = state.definition.name,
			slotIndex = state.slot.index,
			crateName = cratePart.Name,
			readyAt = readyAt,
			createdAt = createdAt,
			health = persistedHealth,
		}
		return true
	end)
end

local function removeChestFromProfile(player: Player, chestId: string)
	mutateChestStorage(player, function(storage)
		storage.active[chestId] = nil
		return true
	end)
end

local function getStoredChestRecords(player: Player): { [string]: StoredChestRecord }?
	local data = Profiles.GetProfileData(player)
	if not data then
		return nil
	end

	local storage = ensureChestStorage(data)
	return storage.active
end

local function scheduleRestore(player: Player)
	if pendingRestoreQueue[player.UserId] then
		return
	end

	if not player.Parent then
		return
	end

	pendingRestoreQueue[player.UserId] = true

	task.delay(1.5, function()
		pendingRestoreQueue[player.UserId] = nil
		if not player.Parent then
			return
		end

		local slot = resolvePlayerSlot(player)
		if slot then
			restoreChestsForPlayer(player, slot)
		else
			scheduleRestore(player)
		end
	end)
end

local function cloneChest(definition: ChestDefinition): ChestDefinition
	return {
		name = definition.name,
		price = definition.price,
		lucky = definition.lucky,
		time = definition.time,
		image = definition.image,
		robuxProduct = definition.robuxProduct,
		skipProductId = definition.skipProductId,
		layoutOrder = definition.layoutOrder,
		Rewards = if definition.Rewards then table.clone(definition.Rewards) else nil,
		breakHealth = definition.breakHealth,
	}
end

local function buildChestCatalog()
	local temp: {ChestDefinition} = {}

	for name, raw in ChestDefinitions do
		if typeof(name) == "string" and typeof(raw) == "table" then
			local rawTable = raw :: { [string]: any }
			local rewards = rawTable.Rewards
			local frozenRewards: { [string]: number }? = nil
			if typeof(rewards) == "table" then
				frozenRewards = table.freeze(table.clone(rewards :: { [string]: number }))
			end
			local breakHealth = rawTable.BreakHealth or rawTable.Health or DEFAULT_BREAK_HEALTH
			local definition: ChestDefinition = {
				name = name,
				price = rawTable.Price or 0,
				lucky = rawTable.Lucky or 0,
				time = rawTable.Time or 0,
				image = rawTable.Image or "",
				robuxProduct = rawTable.RobuxProduct or 0,
				skipProductId = rawTable.SkipProduct or rawTable.SkipCooldownProduct or 0,
				layoutOrder = 0,
				Rewards = frozenRewards,
				breakHealth = math.max(1, breakHealth),
			}
			temp[#temp + 1] = definition
		end
	end

	table.sort(temp, function(a, b)
		if a.price == b.price then
			return a.name < b.name
		end
		return a.price < b.price
	end)

	for index, definition in temp do
		definition.layoutOrder = index * 10
		local frozen = table.freeze(definition)
		orderedChests[#orderedChests + 1] = frozen
		chestLookup[definition.name] = frozen
	end
end

local function getSlotFolder(slot: PlotSlot): Instance?
	return slot:GetFolder()
end

local function resolveChestAssetsFolder(): Folder?
	local cached = chestAssetsFolderCache
	if cached and cached.Parent then
		return cached
	end

	local assetsRoot = ReplicatedStorage:FindFirstChild("Assets")
	if not assetsRoot then
		if not warnedMissingChestAssets then
			warn("ReplicatedStorage.Assets no disponible; no se pueden generar cofres.")
			warnedMissingChestAssets = true
		end
		chestAssetsFolderCache = nil
		return nil
	end

	local chestsFolder = assetsRoot:FindFirstChild("Chests")
	if chestsFolder and chestsFolder:IsA("Folder") then
		chestAssetsFolderCache = chestsFolder
		warnedMissingChestAssets = false
		return chestsFolder
	end

	if not warnedMissingChestAssets then
		warn("ReplicatedStorage.Assets.Chests no encontrado; no se pueden generar cofres.")
		warnedMissingChestAssets = true
	end

	chestAssetsFolderCache = nil
	return nil
end

local function resolveChestUITemplate(): Instance?
	local cached = chestUITemplateCache
	if cached and cached.Parent then
		return cached
	end

	local designRoot = ReplicatedStorage:FindFirstChild("Design")
	if not designRoot then
		if not warnedMissingChestUI then
			warn("ReplicatedStorage.Design no disponible; ChestUI no se mostrará.")
			warnedMissingChestUI = true
		end
		chestUITemplateCache = nil
		return nil
	end

	local template = designRoot:FindFirstChild("ChestUI")
	if template then
		chestUITemplateCache = template
		warnedMissingChestUI = false
		return template
	end

	if not warnedMissingChestUI then
		warn("ReplicatedStorage.Design.ChestUI no encontrado; ChestUI no se mostrará.")
		warnedMissingChestUI = true
	end

	chestUITemplateCache = nil
	return nil
end

local function refreshCrateSlotCache(slot: PlotSlot): { BasePart }
	local slots: { BasePart } = {}

	local folder = slot:GetFolder()
	if folder then
		local crateFolder = folder:FindFirstChild("CrateSlots")
		if crateFolder then
			for _, child in crateFolder:GetChildren() do
				if child:IsA("BasePart") then
					slots[#slots + 1] = child
				end
			end
		end
	end

	table.sort(slots, function(a, b)
		local aValue = tonumber((string.match(a.Name, "(%d+)") or ""))
		local bValue = tonumber((string.match(b.Name, "(%d+)") or ""))
		if aValue and bValue then
			if aValue == bValue then
				return a.Name < b.Name
			end
			return aValue < bValue
		elseif aValue then
			return true
		elseif bValue then
			return false
		end
		return a.Name < b.Name
	end)

	crateSlotCache[slot] = slots
	return slots
end

local function computeChestPivot(slot: PlotSlot, cratePart: BasePart): CFrame
	local basePart = slot:GetBasePart()
	if not basePart then
		return cratePart.CFrame
	end

	local cratePosition = cratePart.CFrame.Position
	local basePosition = basePart.CFrame.Position
	local offset = basePosition - cratePosition
	local absX = math.abs(offset.X)
	local absZ = math.abs(offset.Z)

	local forward: Vector3
	if absX > absZ then
		local signX = if offset.X >= 0 then 1 else -1
		forward = Vector3.new(signX, 0, 0)
	elseif absZ > 0 then
		local signZ = if offset.Z >= 0 then 1 else -1
		forward = Vector3.new(0, 0, signZ)
	else
		forward = Vector3.new(0, 0, -1)
	end

	return CFrame.lookAt(cratePosition, cratePosition + forward, Vector3.new(0, 1, 0))
end

local function getCrateSlots(slot: PlotSlot): { BasePart }
	local cached = crateSlotCache[slot]
	if cached then
		local allValid = true
		for _, part in cached do
			if part.Parent == nil then
				allValid = false
				break
			end
		end
		if allValid then
			return cached
		end
	end

	return refreshCrateSlotCache(slot)
end

local function isCrateOccupied(crate: BasePart): boolean
	local state = crateOccupants[crate]
	if state and not state.cleaned then
		return true
	end

	local attributeValue = crate:GetAttribute("ChestOccupied")
	if typeof(attributeValue) == "string" then
		if state and state.id == attributeValue then
			return true
		end
		if not state or state.cleaned then
			crate:SetAttribute("ChestOccupied", nil)
		end
	elseif attributeValue ~= nil then
		crate:SetAttribute("ChestOccupied", nil)
	end

	return false
end

local function findAvailableCrateSlot(slot: PlotSlot): BasePart?
	for _, crate in getCrateSlots(slot) do
		if not isCrateOccupied(crate) then
			return crate
		end
	end
	return nil
end

resolvePlayerSlot = function(player: Player): PlotSlot?
	local slot = playerSlots[player.UserId]
	if slot and slot:GetOwnerId() == player.UserId then
		return slot
	end

	local assigned = PlotRegistry.GetAssigned(player.UserId)
	if assigned and assigned:GetOwnerId() == player.UserId then
		playerSlots[player.UserId] = assigned
		return assigned
	end

	return nil
end

local function formatRemaining(seconds: number): string
	local rounded = math.max(0, math.ceil(seconds))
	return `{rounded}s`
end

local function findFirstTextLabel(root: Instance, name: string): TextLabel?
	local found = root:FindFirstChild(name, true)
	if found and found:IsA("TextLabel") then
		return found
	end
	return nil
end

local function updateSecondsLabel(state: ChestState)
	local label = state.secondsLabel
	if not label then
		return
	end

	if state.ready or state.remaining <= 0 then
		label.Text = "OPEN IT"
	else
		label.Text = formatRemaining(state.remaining)
	end
end

local function registerChestState(state: ChestState)
	chestStatesById[state.id] = state
	crateOccupants[state.cratePart] = state
	state.cratePart:SetAttribute("ChestOccupied", state.id)

	local playerMap = activeChestsByPlayer[state.userId]
	if not playerMap then
		playerMap = {}
		activeChestsByPlayer[state.userId] = playerMap
	end
	playerMap[state.id] = state

	updateChestAttributes(state)
end

local function buildChestDetectionDetail(state: ChestState): { [string]: any }?
	if state.cleaned then
		return nil
	end

	local primaryPart = state.primaryPart
	if not primaryPart or primaryPart.Parent == nil then
		return nil
	end

	local position = primaryPart.Position
	return {
		id = state.id,
		targetKind = "Chest",
		definitionName = state.definition.name,
		position = position,
		attackAnchor = position,
		chestOwnerId = state.userId,
		health = state.health,
		maxHealth = state.maxHealth,
	}
end

local function removeStateFromSkipQueue(state: ChestState)
	local userQueue = pendingSkipQueues[state.userId]
	if not userQueue then
		return
	end

	for productId, queue in userQueue do
		for index = #queue, 1, -1 do
			if queue[index] == state then
				table.remove(queue, index)
			end
		end
		if #queue == 0 then
			userQueue[productId] = nil
		end
	end

	if next(userQueue) == nil then
		pendingSkipQueues[state.userId] = nil
	end
end

local function attachChestUI(state: ChestState)
	local template = resolveChestUITemplate()
	if not template then
		return
	end

	local clone = template:Clone()
	clone.Parent = state.primaryPart

	if clone:IsA("BillboardGui") then
		clone.Adornee = state.primaryPart
	end

	local nameLabel = findFirstTextLabel(clone, "ChestName")
	if nameLabel then
		nameLabel.Text = state.definition.name
	end

	local secondsLabel = findFirstTextLabel(clone, "Seconds")
	state.secondsLabel = secondsLabel
	updateSecondsLabel(state)

	state.ui = clone
end

local function destroySkipPrompt(state: ChestState)
	local promptId = state.skipPromptId
	if not promptId then
		return
	end

	state.skipPromptId = nil
	state.skipPromptLastRefresh = nil

	local player = state.player
	if player then
		PromptService.removeForPlayer(player, promptId)
	end
end

local function destroyOpenPrompt(state: ChestState)
	local promptId = state.openPromptId
	if not promptId then
		return
	end

	state.openPromptId = nil

	local player = state.player
	if player then
		PromptService.removeForPlayer(player, promptId)
	end
end

local function cleanupChestState(state: ChestState, options: { destroyModel: boolean?, keepStorage: boolean? }?)
	if state.cleaned then
		return
	end

	state.cleaned = true
	state.active = false
	state.pendingSkip = false
	chestStatesById[state.id] = nil

	removeStateFromSkipQueue(state)
	destroySkipPrompt(state)
	destroyOpenPrompt(state)

	if state.modelDestroyConnection then
		state.modelDestroyConnection:Disconnect()
		state.modelDestroyConnection = nil
	end

	if state.crateDestroyConnection then
		state.crateDestroyConnection:Disconnect()
		state.crateDestroyConnection = nil
	end

	for index = #state.connections, 1, -1 do
		local connection = state.connections[index]
		connection:Disconnect()
		table.remove(state.connections, index)
	end

	crateOccupants[state.cratePart] = nil
	if state.cratePart and state.cratePart.Parent then
		state.cratePart:SetAttribute("ChestOccupied", nil)
	end

	if state.anchorTag then
		local primaryPart = state.primaryPart
		if primaryPart and CollectionService:HasTag(primaryPart, state.anchorTag) then
			CollectionService:RemoveTag(primaryPart, state.anchorTag)
		end
	end

	clearChestAttributes(state)

	local playerMap = activeChestsByPlayer[state.userId]
	if playerMap then
		playerMap[state.id] = nil
		if next(playerMap) == nil then
			activeChestsByPlayer[state.userId] = nil
		end
	end

	if state.ui then
		state.ui:Destroy()
		state.ui = nil
	end
	state.secondsLabel = nil

	local shouldDestroyModel = true
	if options and options.destroyModel == false then
		shouldDestroyModel = false
	end

	local model = state.model
	if model and model.Parent then
		if shouldDestroyModel then
			model:Destroy()
		end
	end

	if not (options and options.keepStorage) and state.player then
		removeChestFromProfile(state.player, state.id)
	end

	state.model = nil
	state.countdownThread = nil
	state.anchorTag = nil
	state.skipPromptLastRefresh = nil
end

local function queueSkipRequest(state: ChestState, productId: number)
	local userQueue = pendingSkipQueues[state.userId]
	if not userQueue then
		userQueue = {}
		pendingSkipQueues[state.userId] = userQueue
	end

	local queue = userQueue[productId]
	if not queue then
		queue = {}
		userQueue[productId] = queue
	end

	queue[#queue + 1] = state
end

local markChestReady: (ChestState) -> ()

local function applySkipSuccess(state: ChestState)
	if state.cleaned or state.ready then
		return
	end

	state.remaining = 0
	state.readyAt = os.time()

	updateSecondsLabel(state)

	if state.remaining <= 0 then
		markChestReady(state)
	else
		syncChestStateToProfile(state)
	end
end

local function handleSkipPromptTriggered(state: ChestState, player: Player)
	if state.cleaned or state.ready then
		return
	end

	if player ~= state.player then
		return
	end

	if state.pendingSkip then
		return
	end

	local productId = state.definition.skipProductId or 0
	if productId <= 0 then
		state.remaining = 0
		state.readyAt = os.time()
		updateSecondsLabel(state)
		if state.remaining <= 0 then
			markChestReady(state)
		else
			syncChestStateToProfile(state)
		end
		return
	end

	state.pendingSkip = true
	queueSkipRequest(state, productId)

	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, productId)
	end)

	if not ok then
		state.pendingSkip = false
		removeStateFromSkipQueue(state)
		warn(`No se pudo solicitar el skip del cofre: {err}`)
	end
end

-- Re-register the skip prompt periodically so it recovers if the client misses an earlier create event
local SKIP_PROMPT_REFRESH_INTERVAL = 1

local function shouldShowSkipPrompt(state: ChestState): boolean
	if state.cleaned or state.ready then
		return false
	end

	if state.remaining <= 0 then
		return false
	end

	local player = state.player
	if not player or player.Parent == nil then
		return false
	end

	local primaryPart = state.primaryPart
	if not primaryPart or primaryPart.Parent == nil then
		return false
	end

	return true
end

local function createSkipPrompt(state: ChestState, forceRefresh: boolean?)
	if not shouldShowSkipPrompt(state) then
		destroySkipPrompt(state)
		return
	end

	local now = os.clock()
	if not forceRefresh then
		local last = state.skipPromptLastRefresh or 0
		if now - last < SKIP_PROMPT_REFRESH_INTERVAL and state.skipPromptId ~= nil then
			return
		end
	end

	local player = state.player
	local primaryPart = state.primaryPart
	if not player or not primaryPart then
		return
	end

	local promptId = state.skipPromptId or `ChestSkip_{state.id}`
	state.skipPromptId = promptId
	state.skipPromptLastRefresh = now

	PromptService.registerForPlayer(player, {
		id = promptId,
		parent = primaryPart,
		parentTag = state.anchorTag,
		actionText = "Saltar Espera",
		objectText = state.definition.name,
		holdDuration = 0,
		requiresLineOfSight = false,
		maxActivationDistance = 12,
		keyboardKeyCode = Enum.KeyCode.E,
		style = Enum.ProximityPromptStyle.Custom,
		name = "SkipChestCooldown",
	}, function(triggeringPlayer)
		handleSkipPromptTriggered(state, triggeringPlayer)
	end)
end

local function handleOpenPromptTriggered(state: ChestState, player: Player)
	if state.cleaned or not state.ready then
		return
	end

	if player ~= state.player then
		return
	end

	local reward = ChestRewards.pickReward(state.definition)
	if reward then
		if grantPlacementReward(player, reward) then
			print(`{player.Name} gano "{reward}" del {state.definition.name}`)
		else
			warn(`{player.Name} abrio {state.definition.name} pero la recompensa "{reward}" no se pudo entregar`)
		end
	else
		warn(`{player.Name} abrió {state.definition.name} pero no hay recompensa configurada`)
	end
	cleanupChestState(state)
end

local function createOpenPrompt(state: ChestState)
	destroyOpenPrompt(state)

	local player = state.player
	if not player then
		return
	end

	local primaryPart = state.primaryPart
	if not primaryPart or primaryPart.Parent == nil then
		return
	end

	local promptId = `ChestOpen_{state.id}`
	state.openPromptId = promptId

	PromptService.registerForPlayer(player, {
		id = promptId,
		parent = primaryPart,
		parentTag = state.anchorTag,
		actionText = "Abrir Chest",
		objectText = state.definition.name,
		holdDuration = 0,
		requiresLineOfSight = false,
		maxActivationDistance = 12,
		keyboardKeyCode = Enum.KeyCode.E,
		style = Enum.ProximityPromptStyle.Custom,
		name = "OpenChest",
	}, function(triggeringPlayer)
		handleOpenPromptTriggered(state, triggeringPlayer)
	end)
end

markChestReady = function(state: ChestState)
	if state.cleaned or state.ready then
		return
	end

	state.ready = true
	state.active = false
	state.remaining = 0
	local now = os.time()
	state.readyAt = math.min(state.readyAt or now, now)
	state.health = 0
	updateSecondsLabel(state)
	destroySkipPrompt(state)
	createOpenPrompt(state)
	updateChestAttributes(state)
	syncChestStateToProfile(state)
end

function ChestServiceApi.GetChestTargetsForOwner(ownerUserId: number): { { [string]: any } }
	local bucket = activeChestsByPlayer[ownerUserId]
	if not bucket then
		return {}
	end

	local results = {}
	for _, state in bucket do
		local detail = buildChestDetectionDetail(state)
		if detail then
			results[#results + 1] = detail
		end
	end

	return results
end

function ChestServiceApi.GetChestState(chestId: string): ChestState?
	return chestStatesById[chestId]
end

function ChestServiceApi.ApplyDamage(chestId: string, amount: number, metadata: { [string]: any }?): (boolean, number?, number?)
	if typeof(chestId) ~= "string" or chestId == "" then
		return false, nil, 0
	end

	local state = chestStatesById[chestId]
	if not state or state.cleaned then
		return false, nil, 0
	end

	local attackerId = metadata and metadata.attacker
	if attackerId and attackerId ~= state.userId then
		return false, state.health, 0
	end

	local numericAmount = math.floor(tonumber(amount) or 0)
	if numericAmount <= 0 then
		return true, state.health, 0
	end

	local previousHealthValue = state.health
	if typeof(previousHealthValue) ~= "number" then
		previousHealthValue = state.maxHealth
	end

	local previousHealth = math.clamp(previousHealthValue :: number, 0, state.maxHealth)
	if previousHealth <= 0 then
		return true, 0, 0
	end

	local newHealth = math.max(0, previousHealth - numericAmount)
	local damageApplied = previousHealth - newHealth
	if damageApplied <= 0 then
		return true, newHealth, 0
	end

	state.health = newHealth
	if newHealth <= 0 then
		markChestReady(state)
	else
		updateChestAttributes(state)
		syncChestStateToProfile(state)
	end

	return true, state.health, damageApplied
end

local function startCountdown(state: ChestState)
	if state.cleaned then
		return
	end

	state.remaining = math.max(0, state.readyAt - os.time())
	if state.remaining <= 0 then
		markChestReady(state)
		return
	end

	state.active = true
	updateSecondsLabel(state)
	createSkipPrompt(state, true)

	state.countdownThread = task.spawn(function()
		while state.active and state.remaining > 0 do
			local step = math.min(1, math.max(0.1, state.remaining))
			task.wait(step)
			if not state.active then
				return
			end
			state.remaining = math.max(0, state.remaining - step)
			updateSecondsLabel(state)
			createSkipPrompt(state)
		end

		if state.cleaned then
			return
		end

		markChestReady(state)
	end)
end

	local function restoreChestFromRecord(player: Player, slot: PlotSlot, record: StoredChestRecord): boolean
		local definition = chestLookup[record.name]
		if not definition then
			removeChestFromProfile(player, record.id)
			warn(`Chest almacenado desconocido "{record.name}" para {player.Name}; eliminado`)
			return true
		end

		local cratePart: BasePart? = nil
		local slotFolder = slot:GetFolder()
		if slotFolder then
			local crateFolder = slotFolder:FindFirstChild("CrateSlots")
			if crateFolder then
				local candidate = crateFolder:FindFirstChild(record.crateName)
				if candidate and candidate:IsA("BasePart") and not isCrateOccupied(candidate) then
					cratePart = candidate
				end
			end
		end

		if not cratePart then
			cratePart = findAvailableCrateSlot(slot)
			if not cratePart then
				return false
			end
		end

	local resolvedCratePart = cratePart :: BasePart

		local assetsFolder = resolveChestAssetsFolder()
		if not assetsFolder then
			return false
		end

		local template = assetsFolder:FindFirstChild(definition.name)
		if not template or not template:IsA("Model") then
			removeChestFromProfile(player, record.id)
			warn(`Modelo faltante para cofre "{definition.name}"; se elimino el registro persistente`)
			return true
		end

		local model = template:Clone()
		if not model.PrimaryPart then
			local fallbackPrimary = model:FindFirstChildWhichIsA("BasePart")
			if fallbackPrimary then
				model.PrimaryPart = fallbackPrimary
			end
		end

		local primaryPart = model.PrimaryPart
		if not primaryPart then
			model:Destroy()
			removeChestFromProfile(player, record.id)
			warn(`El cofre "{definition.name}" no tiene PrimaryPart se elimino el registro persistente`)
			return true
		end

		model.Name = definition.name
		model.Parent = slot:GetAssetsFolder()
		model:PivotTo(computeChestPivot(slot, resolvedCratePart))

		local now = os.time()
		local readyAt = record.readyAt or now
		local remaining = math.max(0, readyAt - now)
		local anchorTag = `ChestPromptAnchor_{record.id}`
		local maxHealth = getDefinitionBreakHealth(definition)
		local storedHealthValue = record.health
		local resolvedHealth = maxHealth
		if typeof(storedHealthValue) == "number" then
			resolvedHealth = math.clamp(math.floor((storedHealthValue :: number) + 0.5), 0, maxHealth)
		end

		local state: ChestState = {
			id = record.id,
			definition = definition,
			player = player,
			userId = player.UserId,
			slot = slot,
			cratePart = resolvedCratePart,
			model = model,
			primaryPart = primaryPart,
			ui = nil,
			secondsLabel = nil,
			maxHealth = maxHealth,
			health = resolvedHealth,
			remaining = remaining,
			readyAt = readyAt,
			createdAt = record.createdAt or now,
			ready = false,
			active = false,
			skipPromptId = nil,
			openPromptId = nil,
			anchorTag = anchorTag,
			connections = {},
			modelDestroyConnection = nil,
			crateDestroyConnection = nil,
			countdownThread = nil,
			cleaned = false,
			pendingSkip = false,
			skipPromptLastRefresh = nil,
		}

		CollectionService:AddTag(primaryPart, anchorTag)

		registerChestState(state)
		if model.Parent then
			model:SetAttribute("ChestId", state.id)
			model:SetAttribute("ChestName", definition.name)
		end

		state.modelDestroyConnection = model.Destroying:Connect(function()
			cleanupChestState(state, { destroyModel = false })
		end)

		state.crateDestroyConnection = resolvedCratePart.Destroying:Connect(function()
			cleanupChestState(state)
		end)

		attachChestUI(state)
		syncChestStateToProfile(state)

		if state.remaining <= 0 then
			markChestReady(state)
		else
			startCountdown(state)
		end

		return true
	end

	restoreChestsForPlayer = function(player: Player, slot: PlotSlot)
		local existing = activeChestsByPlayer[player.UserId]
		if existing and next(existing) ~= nil then
			return
		end

		local stored = getStoredChestRecords(player)
		if not stored then
			return
		end

		local matchingSlot: {StoredChestRecord} = {}
		local mismatchedSlot: {StoredChestRecord} = {}

		for _, record in stored do
			local clone = table.clone(record)
			if record.slotIndex == nil or record.slotIndex == slot.index then
				matchingSlot[#matchingSlot + 1] = clone
			else
				mismatchedSlot[#mismatchedSlot + 1] = clone
			end
		end

		local function sortRecords(list: {StoredChestRecord})
			table.sort(list, function(a, b)
				local aCreated = a.createdAt or 0
				local bCreated = b.createdAt or 0
				if aCreated == bCreated then
					return a.id < b.id
				end
				return aCreated < bCreated
			end)
		end

		sortRecords(matchingSlot)
		sortRecords(mismatchedSlot)

		local needsRetry = false

		local function process(records: {StoredChestRecord})
			for _, record in records do
				local ok = restoreChestFromRecord(player, slot, record)
				if ok == false then
					needsRetry = true
				end
			end
		end

		process(matchingSlot)
		process(mismatchedSlot)

		if needsRetry then
			scheduleRestore(player)
		end
	end

local function ensurePlacementPrerequisites(slot: PlotSlot?, definition: ChestDefinition): (boolean, string?)
	if not slot then
		return false, "No tienes un terreno asignado"
	end

	if not findAvailableCrateSlot(slot) then
		return false, "Todos tus espacios de cofres están ocupados"
	end

	local assetsFolder = resolveChestAssetsFolder()
	if not assetsFolder then
		return false, "Los modelos de cofres no están disponibles"
	end

	local template = assetsFolder:FindFirstChild(definition.name)
	if not template or not template:IsA("Model") then
		return false, `El cofre "{definition.name}" no existe en Assets`
	end

	local primaryPart = template.PrimaryPart or template:FindFirstChildWhichIsA("BasePart")
	if not primaryPart then
		return false, `El cofre "{definition.name}" no tiene PrimaryPart`
	end

	return true, nil
end

local function placeChestForPlayer(player: Player, slot: PlotSlot, definition: ChestDefinition): (boolean, string?)
	local cratePart = findAvailableCrateSlot(slot)
	if not cratePart then
		return false, "Todos tus espacios de cofres están ocupados"
	end

	local assetsFolder = resolveChestAssetsFolder()
	if not assetsFolder then
		return false, "Los modelos de cofres no están disponibles"
	end

	local template = assetsFolder:FindFirstChild(definition.name)
	if not template or not template:IsA("Model") then
		return false, `El cofre "{definition.name}" no existe en Assets`
	end

	local model = template:Clone()
	if not model.PrimaryPart then
		local fallbackPrimary = model:FindFirstChildWhichIsA("BasePart")
		if fallbackPrimary then
			model.PrimaryPart = fallbackPrimary
		end
	end

	local primaryPart = model.PrimaryPart
	if not primaryPart then
		model:Destroy()
		return false, `El cofre "{definition.name}" no tiene PrimaryPart`
	end

	model.Name = definition.name
	model.Parent = slot:GetAssetsFolder()
	model:PivotTo(computeChestPivot(slot, cratePart))

	local now = os.time()
	local initialRemaining = math.max(0, definition.time)
	local readyAt = if initialRemaining <= 0 then now else now + initialRemaining
	local chestId = HttpService:GenerateGUID(false)
	local anchorTag = `ChestPromptAnchor_{chestId}`
	local maxHealth = getDefinitionBreakHealth(definition)

	local state: ChestState = {
		id = chestId,
		definition = definition,
		player = player,
		userId = player.UserId,
		slot = slot,
		cratePart = cratePart,
		model = model,
		primaryPart = primaryPart,
		ui = nil,
		secondsLabel = nil,
		maxHealth = maxHealth,
		health = maxHealth,
		remaining = initialRemaining,
		readyAt = readyAt,
		createdAt = now,
		ready = false,
		active = false,
		skipPromptId = nil,
		openPromptId = nil,
		anchorTag = anchorTag,
		connections = {},
		modelDestroyConnection = nil,
		crateDestroyConnection = nil,
		countdownThread = nil,
		cleaned = false,
		pendingSkip = false,
		skipPromptLastRefresh = nil,
	}

	CollectionService:AddTag(primaryPart, anchorTag)

	registerChestState(state)
	if model.Parent then
		model:SetAttribute("ChestId", state.id)
		model:SetAttribute("ChestName", definition.name)
	end

	state.modelDestroyConnection = model.Destroying:Connect(function()
		cleanupChestState(state, { destroyModel = false })
	end)

	state.crateDestroyConnection = cratePart.Destroying:Connect(function()
		cleanupChestState(state)
	end)

	attachChestUI(state)
	syncChestStateToProfile(state)

	if state.remaining <= 0 then
		markChestReady(state)
	else
		startCountdown(state)
	end

	return true, "Cofre colocado"
end

local function cleanupPlayerChests(player: Player)
	local chestMap = activeChestsByPlayer[player.UserId]
	if not chestMap then
		return
	end

	local snapshot = table.clone(chestMap)
	for _, state in snapshot do
		cleanupChestState(state, { keepStorage = true })
	end
end

MarketplaceService.PromptProductPurchaseFinished:Connect(function(player, productId, wasPurchased)
	local userQueue = pendingSkipQueues[player.UserId]
	if not userQueue then
		return
	end

	local queue = userQueue[productId]
	if not queue then
		return
	end

	local state: ChestState? = nil
	while #queue > 0 do
		local candidate = table.remove(queue, 1)
		if candidate and not candidate.cleaned and candidate.userId == player.UserId then
			state = candidate
			break
		end
	end

	if #queue == 0 then
		userQueue[productId] = nil
	end

	if next(userQueue) == nil then
		pendingSkipQueues[player.UserId] = nil
	end

	if not state then
		return
	end

	state.pendingSkip = false

	if wasPurchased then
		applySkipSuccess(state)
	else
		createSkipPrompt(state, true)
	end
end)

local function buildDescriptorFromPrompt(prompt: ProximityPrompt, promptId: string): PromptDescriptor?
	local parent = prompt.Parent
	if not parent then
		return nil
	end

	return {
		id = promptId,
		parent = parent,
		parentPath = nil,
		parentTag = nil,
		actionText = prompt.ActionText,
		objectText = prompt.ObjectText,
		holdDuration = prompt.HoldDuration,
		requiresLineOfSight = prompt.RequiresLineOfSight,
		maxActivationDistance = prompt.MaxActivationDistance,
		keyboardKeyCode = prompt.KeyboardKeyCode,
		gamepadKeyCode = prompt.GamepadKeyCode,
		style = prompt.Style,
		enabled = true,
		uiOffset = prompt.UIOffset,
		name = prompt.Name,
	}
end

local function broadcastOpen(player: Player, slot: PlotSlot)
	local payload = {
		slot = slot.index,
		chests = table.create(#orderedChests),
	}

	for index, definition in orderedChests do
		payload.chests[index] = cloneChest(definition)
	end

	openPacket:FireClient(player, payload)
end

local function assignPromptToOwner(info: ManagedPrompt, ownerId: number?)
	if info.ownerId then
		local previousPlayer = Players:GetPlayerByUserId(info.ownerId)
		if previousPlayer then
			PromptService.removeForPlayer(previousPlayer, info.id)
		end
	end

	info.ownerId = ownerId

	if info.source.Parent then
		info.source:SetAttribute(ORDER_ATTRIBUTE, ownerId)
	end

	if not ownerId then
		return
	end

	local player = Players:GetPlayerByUserId(ownerId)
	if not player then
		return
	end

	PromptService.registerForPlayer(player, info.descriptor, function(triggeringPlayer)
		if triggeringPlayer.UserId ~= ownerId then
			return
		end
		broadcastOpen(triggeringPlayer, info.slot)
	end)
end

local function addPromptToSlot(slot: PlotSlot, prompt: ProximityPrompt)
	if promptIndex[prompt] then
		return
	end

	local parent = prompt.Parent
	if not parent then
		return
	end

	local existingId = prompt:GetAttribute("ChestPromptId")
	local promptId: string
	if typeof(existingId) == "string" and existingId ~= "" then
		promptId = existingId
	else
		promptId = `ChestPrompt_{slot.index}_{HttpService:GenerateGUID(false)}`
		prompt:SetAttribute("ChestPromptId", promptId)
	end

	local descriptor = buildDescriptorFromPrompt(prompt, promptId)
	if not descriptor then
		return
	end

	local info: ManagedPrompt = {
		id = promptId,
		slot = slot,
		source = prompt,
		descriptor = descriptor,
		ownerId = nil,
	}

	prompt.Enabled = false
	prompt:SetAttribute(ORDER_ATTRIBUTE, slot:GetOwnerId())

	promptIndex[prompt] = info

	local slotMap = slotPrompts[slot]
	if not slotMap then
		slotMap = {}
		slotPrompts[slot] = slotMap
	end
	slotMap[promptId] = info

	assignPromptToOwner(info, slot:GetOwnerId())

	prompt.Destroying:Connect(function()
		if info.ownerId then
			local player = Players:GetPlayerByUserId(info.ownerId)
			if player then
				PromptService.removeForPlayer(player, info.id)
			end
		end

		promptIndex[prompt] = nil
		local slotEntries = slotPrompts[slot]
		if slotEntries then
			slotEntries[info.id] = nil
			if next(slotEntries) == nil then
				slotPrompts[slot] = nil
			end
		end
	end)
end

local function isChestPrompt(instance: Instance): boolean
	if not instance:IsA("ProximityPrompt") then
		return false
	end

	if instance.Name == EXPECTED_PROMPT_NAME then
		return true
	end

	local parent = instance.Parent
	if parent and parent.Name == EXPECTED_PROMPT_NAME then
		return true
	end

	local attribute = instance:GetAttribute("ChestPrompt")
	if attribute == true then
		return true
	end

	return false
end

local function handleDescendant(slot: PlotSlot, instance: Instance)
	if isChestPrompt(instance) then
		addPromptToSlot(slot, instance :: ProximityPrompt)
	end
end

local function observeSlot(slot: PlotSlot)
	if slotConnections[slot] then
		return
	end

	local folder = getSlotFolder(slot)
	if not folder then
		return
	end

	for _, descendant in folder:GetDescendants() do
		handleDescendant(slot, descendant)
	end

	slotConnections[slot] = folder.DescendantAdded:Connect(function(instance)
		handleDescendant(slot, instance)
	end)
end

local function applyOwnership(slot: PlotSlot, ownerId: number?)
	local folder = getSlotFolder(slot)
	if folder then
		folder:SetAttribute(ORDER_ATTRIBUTE, ownerId)
	end

	local entries = slotPrompts[slot]
	if not entries then
		return
	end

	for _, info in entries do
		assignPromptToOwner(info, ownerId)
	end
end

local function handleMoneyPurchase(player: Player, chestName: any)
	if typeof(chestName) ~= "string" then
		return false, "Petición inválida"
	end

	local definition = chestLookup[chestName]
	if not definition then
		return false, "Cofre desconocido"
	end

	local slot = resolvePlayerSlot(player)
	local canPlace, reason = ensurePlacementPrerequisites(slot, definition)
	if not canPlace then
		return false, reason or "No se pudo colocar el cofre"
	end

	local result = Profiles.Mutate(player, function(profileData)
		profileData.Money = profileData.Money or 0
		if profileData.Money < definition.price then
			return { success = false, message = "Fondos insuficientes" }
		end

		profileData.Money -= definition.price
		return { success = true, message = "Comprado" }
	end)

	if not result then
		return false, "Perfil no disponible"
	end

	if result.success ~= true then
		return false, result.message or "Compra rechazada"
	end

	slot = slot or resolvePlayerSlot(player)
	if not slot then
		Profiles.Mutate(player, function(profileData)
			profileData.Money = (profileData.Money or 0) + definition.price
		end)
		return false, "No tienes un terreno asignado"
	end

	local placed, placementMessage = placeChestForPlayer(player, slot, definition)
	if not placed then
		Profiles.Mutate(player, function(profileData)
			profileData.Money = (profileData.Money or 0) + definition.price
		end)
		return false, placementMessage or "No se pudo colocar el cofre"
	end
	return true, placementMessage or result.message or "Comprado"
end

local function handleRobuxPurchase(player: Player, chestName: any)
	if typeof(chestName) ~= "string" then
		return false, "Petición inválida"
	end

	local definition = chestLookup[chestName]
	if not definition then
		return false, "Cofre desconocido"
	end

	local productId = definition.robuxProduct
	if typeof(productId) ~= "number" or productId <= 0 then
		return false, "Producto no configurado"
	end

	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, productId)
	end)

	if not ok then
		warn(`Failed to prompt product purchase for {player.Name}: {err}`)
		return false, "Error de compra"
	end

	return true, "Prompt enviado"
end

local function init()
	buildChestCatalog()

	for _, slot in PlotRegistry.GetSlots() do
		observeSlot(slot)
		local ownerId = slot:GetOwnerId()
		if ownerId then
			playerSlots[ownerId] = slot
			applyOwnership(slot, ownerId)
		end
	end

	moneyPacket.OnServerInvoke = handleMoneyPurchase
	robuxPacket.OnServerInvoke = handleRobuxPurchase

	Profiles.ProfileLoaded:Connect(function(player)
		task.spawn(function()
			local slot: PlotSlot? = nil
			for _ = 1, 60 do
				slot = PlotRegistry.GetAssigned(player.UserId)
				if slot then
					break
				end
				task.wait(0.1)
			end

			if not slot then
				warn(`Could not resolve plot slot for {player.Name}`)
				return
			end

			playerSlots[player.UserId] = slot
			applyOwnership(slot, player.UserId)
			restoreChestsForPlayer(player, slot)
		end)
	end)

	Profiles.ProfileReleased:Connect(function(player)
		task.defer(function()
			cleanupPlayerChests(player)

			local slot: PlotSlot? = playerSlots[player.UserId]
			if not slot then
				slot = PlotRegistry.GetAssigned(player.UserId)
			end
			if not slot then
				return
			end

			playerSlots[player.UserId] = nil
			applyOwnership(slot :: PlotSlot, nil)
		end)
	end)
end

init()

return ChestServiceApi
