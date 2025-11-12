--!strict

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")

local Profiles = require(ServerScriptService.Work.Modules.Profiles)
local PlacementInventory = require(ServerScriptService.Work.Modules.PlacementInventory)
local PromptService = require(ReplicatedStorage.ProximityPrompts)
local PlotRegistry = require(script.Parent.Parent.Placement.PlotRegistry)
local PlacementModule = ReplicatedStorage:WaitForChild("Placement")
local Placement = require(PlacementModule)
local PlacementService = require(script.Parent.Parent.Placement.Service)
local PlacementAssetRegistry = Placement.AssetRegistry

local AmmoPackets = require(ReplicatedStorage.Network.AmmoBuildingPackets)
local AmmoDefinitions = require(ReplicatedStorage.Data.AmmoBuildings)

type PlotSlot = PlotRegistry.PlotSlot

type AmmoDefinition = {
	id: string,
	assetId: string,
	displayName: string,
	price: number,
	robuxProduct: number,
	image: string,
	bullets: number,
	damage: number,
	cooldown: number,
	reloadTime: number,
	layoutOrder: number,
}

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

local ORDER_ATTRIBUTE = "OwnerUserId"
local EXPECTED_PROMPT_NAME = "OpenGunBuilding"
local PROMPT_ID_ATTRIBUTE = "GunStorePromptId"

local openPacket = AmmoPackets.Open
local closePacket = AmmoPackets.Close
local moneyPacket = AmmoPackets.MoneyPurchase
local robuxPacket = AmmoPackets.RobuxPurchase

local orderedBuildings: {AmmoDefinition} = {}
local buildingLookup: { [string]: AmmoDefinition } = {}

local slotPrompts: { [PlotSlot]: { [string]: ManagedPrompt } } = {}
local promptIndex: { [ProximityPrompt]: ManagedPrompt } = {}
local slotConnections: { [PlotSlot]: RBXScriptConnection } = {}
local playerSlots: { [number]: PlotSlot } = {}

local function formatDisplayName(assetId: string): string
	local spaced = assetId:gsub("_", " ")
	spaced = spaced:gsub("(%l)(%u)", "%1 %2")
	spaced = spaced:gsub("(%u)(%u%l)", "%1 %2")
	spaced = spaced:gsub("^%s+", "")
	if spaced == "" then
		return assetId
	end
	return spaced
end

local function resolveDisplayName(assetId: string, raw: { [string]: any }): string
	local candidate = raw.name or raw.Name
	if typeof(candidate) ~= "string" or candidate == "" then
		local data = raw.data
		if typeof(data) == "table" then
			candidate = data.Name or data.DisplayName
		end
	end
	if typeof(candidate) ~= "string" or candidate == "" then
		candidate = formatDisplayName(assetId)
	end
	return candidate
end

local function coerceNumber(value: any, default: number): number
	local numeric = tonumber(value)
	if not numeric then
		return default
	end
	return numeric
end

local function cloneDefinition(definition: AmmoDefinition)
	return {
		id = definition.id,
		name = definition.displayName,
		price = definition.price,
		robuxProduct = definition.robuxProduct,
		image = definition.image,
		bullets = definition.bullets,
		damage = definition.damage,
		cooldown = definition.cooldown,
		reloadTime = definition.reloadTime,
		layoutOrder = definition.layoutOrder,
	}
end

local function getLevelStats(raw: { [string]: any }?, level: number): { [string]: any }?
	if typeof(raw) ~= "table" then
		return nil
	end

	local levels = raw.Level or raw.level or raw.Levels or raw.levels
	if typeof(levels) ~= "table" then
		return nil
	end

	local entry = levels[level] or levels[tostring(level)]
	if typeof(entry) ~= "table" then
		return nil
	end

	local stats = entry.Stats
	if typeof(stats) == "table" then
		return stats
	end

	return entry
end

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

local function getOrCreatePromptId(prompt: ProximityPrompt, slotIndex: number): string
	local existing = prompt:GetAttribute(PROMPT_ID_ATTRIBUTE)
	if typeof(existing) == "string" and existing ~= "" then
		return existing
	end

	local generated = `GunBuildingStore_{slotIndex}_{HttpService:GenerateGUID(false)}`
	prompt:SetAttribute(PROMPT_ID_ATTRIBUTE, generated)
	return generated
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

local function grantBuildingToPlayer(player: Player, definition: AmmoDefinition): (boolean, string?)
	local ok, assetDefinition = pcall(PlacementAssetRegistry.Get, definition.assetId)
	if not ok or assetDefinition == nil then
		return false, `Asset "{definition.assetId}" no registrado`
	end

	local adjustResult = PlacementInventory.Adjust(player, definition.assetId, 1, 1)
	if not adjustResult then
		return false, "No se pudo actualizar tu inventario"
	end

	local storedEntryId: string? = nil
	local createdEntries = adjustResult.storedEntryIds
	if typeof(createdEntries) == "table" and #createdEntries > 0 then
		storedEntryId = createdEntries[#createdEntries]
	end

	local successGrant, payload = PlacementService.GrantPlacementTool(player, definition.assetId, storedEntryId, adjustResult.level)
	if not successGrant then
		local message = if typeof(payload) == "string" then payload else "No se pudo entregar la herramienta"
		PlacementInventory.Adjust(player, definition.assetId, -1, adjustResult.level)
		if storedEntryId then
			removeStoredPlacementEntry(player, storedEntryId)
		end
		return false, message
	end

	return true, nil
end

local function broadcastOpen(player: Player, slot: PlotSlot)
	local payload = {
		slot = slot.index,
		buildings = table.create(#orderedBuildings),
	}

	for index, definition in orderedBuildings do
		payload.buildings[index] = cloneDefinition(definition)
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

local function getSlotFolder(slot: PlotSlot): Instance?
	return slot:GetFolder()
end

local function addPromptToSlot(slot: PlotSlot, prompt: ProximityPrompt)
	if promptIndex[prompt] then
		return
	end

	local promptId = getOrCreatePromptId(prompt, slot.index)
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

local function isGunBuildingPrompt(instance: Instance): boolean
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

	if instance:GetAttribute("GunBuildingStorePrompt") == true then
		return true
	end

	return false
end

local function handleDescendant(slot: PlotSlot, instance: Instance)
	if isGunBuildingPrompt(instance) then
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

local function resolvePlayerSlot(player: Player): PlotSlot?
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

local function handleMoneyPurchase(player: Player, buildingId: any)
	if typeof(buildingId) ~= "string" then
		return false, "Petición inválida"
	end

	local definition = buildingLookup[buildingId]
	if not definition then
		return false, "Edificio desconocido"
	end

	local slot = resolvePlayerSlot(player)
	if not slot then
		return false, "Necesitas un terreno asignado"
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

	local granted, message = grantBuildingToPlayer(player, definition)
	if not granted then
		Profiles.Mutate(player, function(profileData)
			profileData.Money = (profileData.Money or 0) + definition.price
		end)
		return false, message or "No se pudo entregar el edificio"
	end

	return true, message or `Recibiste {definition.displayName}`
end

local function handleRobuxPurchase(player: Player, buildingId: any)
	if typeof(buildingId) ~= "string" then
		return false, "Petición inválida"
	end

	local definition = buildingLookup[buildingId]
	if not definition then
		return false, "Edificio desconocido"
	end

	local productId = definition.robuxProduct
	if typeof(productId) ~= "number" or productId <= 0 then
		return false, "Producto no configurado"
	end

	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, productId)
	end)

	if not ok then
		warn(`No se pudo iniciar compra de producto {productId} para {player.Name}: {err}`)
		return false, "Error de compra"
	end

	return true, "Prompt enviado"
end

local function buildCatalog()
	table.clear(orderedBuildings)
	table.clear(buildingLookup)

	local temp: {AmmoDefinition} = {}

	for id, raw in AmmoDefinitions do
		if typeof(id) == "string" and typeof(raw) == "table" then
			local rawTable = raw :: { [string]: any }
			local data = rawTable.data
			local levelOneStats = getLevelStats(rawTable, 1)
			local baseBullets = if levelOneStats and levelOneStats.bullets ~= nil then levelOneStats.bullets else rawTable.bullets
			local baseDamageValue = nil
			if levelOneStats then
				baseDamageValue = levelOneStats.dmg or levelOneStats.damage
			end
			if baseDamageValue == nil then
				baseDamageValue = rawTable.dmg or rawTable.damage
			end
			local baseCooldown = if levelOneStats and levelOneStats.cooldown ~= nil then levelOneStats.cooldown else rawTable.cooldown
			local baseReload = if levelOneStats and levelOneStats.reloadTime ~= nil then levelOneStats.reloadTime else rawTable.reloadTime

			local definition: AmmoDefinition = {
				id = id,
				assetId = id,
				displayName = resolveDisplayName(id, rawTable),
				price = if typeof(data) == "table" then coerceNumber(data.Price, 0) else 0,
				robuxProduct = if typeof(data) == "table" then coerceNumber(data.RobuxProduct, 0) else 0,
				image = if typeof(data) == "table" and typeof(data.Image) == "string" then data.Image else "",
				bullets = coerceNumber(baseBullets, 0),
				damage = coerceNumber(baseDamageValue, 0),
				cooldown = coerceNumber(baseCooldown, 0),
				reloadTime = coerceNumber(baseReload, 0),
				layoutOrder = 0,
			}

			temp[#temp + 1] = definition
		end
	end

	table.sort(temp, function(a, b)
		if a.price == b.price then
			return a.displayName < b.displayName
		end
		return a.price < b.price
	end)

	for index, definition in temp do
		definition.layoutOrder = index * 10
		local frozen = table.freeze(definition)
		orderedBuildings[#orderedBuildings + 1] = frozen
		buildingLookup[definition.id] = frozen
	end
end

local function init()
	buildCatalog()

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
				warn(`No se pudo resolver el terreno para {player.Name} (AmmoBuildingStore)`)
				return
			end

			playerSlots[player.UserId] = slot
			applyOwnership(slot, player.UserId)
		end)
	end)

	Profiles.ProfileReleased:Connect(function(player)
		task.defer(function()
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

	closePacket.OnServerEvent:Connect(function(player)
		local slot = resolvePlayerSlot(player)
		if not slot then
			return
		end

		local entries = slotPrompts[slot]
		if not entries then
			return
		end

		for _, info in entries do
			if info.ownerId == player.UserId then
				PromptService.registerForPlayer(player, info.descriptor, function(triggeringPlayer)
					if triggeringPlayer.UserId ~= player.UserId then
						return
					end
					broadcastOpen(triggeringPlayer, slot)
				end)
			end
		end
	end)
end

init()

return {}
