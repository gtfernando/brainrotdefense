local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPack = game:GetService("StarterPack")
local MarketplaceService = game:GetService("MarketplaceService")
local HttpService = game:GetService("HttpService")

local PlacementModule = ReplicatedStorage:WaitForChild("Placement") :: ModuleScript
local PlacementPackage = require(PlacementModule)
local AssetRegistry = PlacementPackage.AssetRegistry
local Grid = PlacementPackage.Grid
local PlacementPackets = PlacementPackage.Packets

local PlacementStats = require(script.Parent:WaitForChild("Stats"))
local PlacementWorld = require(script.Parent:WaitForChild("World"))
local PlacementEarnings = require(script.Parent:WaitForChild("Earnings"))
local PlotRegistry = require(script.Parent:WaitForChild("PlotRegistry"))

local PlacementInventory = require(ServerScriptService.Work.Modules.PlacementInventory)
local Profiles = require(ServerScriptService.Work.Modules.Profiles)

local ModulesFolder = script.Parent.Parent:WaitForChild("Modules")
local GunBuildingServiceModule = ModulesFolder:WaitForChild("GunBuildingService")
local BrainrotTourismServiceModule = ModulesFolder:WaitForChild("BrainrotTourismService")
local InstanceUtils = require(ModulesFolder:WaitForChild("InstanceUtils"))
local gunBuildingService: any = nil

local findFirstDescendant = InstanceUtils.findFirstDescendant

local function getGunBuildingService()
	if not gunBuildingService then
		gunBuildingService = require(GunBuildingServiceModule)
	end
	return gunBuildingService
end

local OfflinePackets = require(ReplicatedStorage.Network.OfflinePackets)

local BuildingsData = require(ReplicatedStorage.Data.Buildings)
local LockedZonePrices = require(ReplicatedStorage.Data.LockedZonesPrices)
local AmmoBuildingsData = require(ReplicatedStorage.Data.AmmoBuildings)

local placementInitPacket = PlacementPackets.Init
local placementUpdatePacket = PlacementPackets.Update
local placementRequestPacket = PlacementPackets.Request
local zonePurchasePacket = PlacementPackets.ZonePurchase
local placementPickupPacket = PlacementPackets.Pickup
local placementUpgradePacket = PlacementPackets.Upgrade

local ZERO_VECTOR = Vector3.new(0, 0, 0)
local PLACEMENT_TOOLS_FOLDER_NAME = "PlacementTools"

local OFFLINE_BASE_CAP_SECONDS = 4 * 60 * 60
local OFFLINE_RAW_CAP_SECONDS = 12 * 60 * 60
local OFFLINE_GAMEPASS_ID = 0

type PlotSlot = PlotRegistry.PlotSlot
type ZoneState = {
	id: string?,
	min: Vector2?,
	max: Vector2?,
	locked: boolean?,
	markerCFrame: CFrame?,
	markerSize: Vector3?,
}
type BlockingData = {
	zones: { ZoneState }?,
	cellsMap: { [number]: { [number]: string } },
	cellsList: { { x: number, y: number, zone: string } },
	zoneLookup: { [string]: ZoneState },
	zoneAlignments: { [string]: Vector3 }?,
	unlocked: { any }?,
}
type PlacementData = {
	id: string,
	asset: string,
	position: Vector2,
	rotation: number,
	cells: { Vector2 },
	level: number,
}
type PlacementHealthUi = {
	container: Instance?,
	healthLabel: TextLabel?,
	healthFill: GuiObject?,
	fillYScale: number?,
	fillYOffset: number?,
}
type PlacementRecord = {
	entity: number,
	assetId: string,
	level: number,
	maxHealth: number,
	health: number,
	model: Model?,
	ui: PlacementHealthUi?,
}
type Session = {
	player: Player,
	ownerId: number,
	profile: any,
	slot: PlotSlot,
	plotEntity: any,
	placements: { [string]: PlacementRecord },
	blocking: BlockingData,
	characterConnection: RBXScriptConnection?,
	pendingPlacements: { [string]: boolean },
	offlineState: { [string]: any }?,
	storedTokenMap: { [string]: string },
}
type PlacementLookup = {
	session: Session,
	id: string,
}
type PendingProductInfo = {
	placementId: string,
}

local sessions: { [Player]: Session } = {}
local pendingProductUpgrades: { [number]: { [number]: PendingProductInfo } } = {}
local placementsByEntity: { [number]: PlacementLookup } = {}

local buildingUiTemplate: Instance? = nil

local updatePlacementHealthUi: (PlacementRecord) -> () = function(_record: PlacementRecord)
	return
end

local function debugHealthUi(...)
	--print("[PlacementHealthUI]", ...)
end

local function isGunPlacement(assetId: string): boolean
	if typeof(assetId) ~= "string" or assetId == "" then
		return false
	end

	local definition = AmmoBuildingsData[assetId]
	return typeof(definition) == "table"
end

local function registerGunPlacement(session: Session, placementEntity: number, placementId: string, assetId: string, level: number?, model: Model?, initialState: { [string]: any }?)
	if not model or not isGunPlacement(assetId) then
		return
	end

	local slotIndex = nil
	local slot = session.slot
	if slot and (slot :: any).index then
		slotIndex = (slot :: any).index
	end

	local gunService = getGunBuildingService()
	local params = {
		placementEntity = placementEntity,
		placementId = placementId,
		assetId = assetId,
		model = model,
		ownerUserId = session.ownerId,
		slotIndex = slotIndex,
		level = math.max(1, tonumber(level) or 1),
	}

	if typeof(initialState) == "table" then
		params.initialState = initialState
	end

	gunService.RegisterPlacement(params)
end

local function unregisterGunPlacement(placementEntity: number?, placementId: string?)
	if placementEntity then
		local gunService = getGunBuildingService()
		gunService.UnregisterPlacement(placementEntity)
	end
	if placementId then
		local gunService = getGunBuildingService()
		gunService.UnregisterPlacement(placementId)
	end
end

local function applyPlacementAttributes(record: PlacementRecord)
	local model = record.model or PlacementWorld.GetPlacementModel(record.entity)
	if model then
		record.model = model
		model:SetAttribute("PlacementHealth", record.health)
		model:SetAttribute("PlacementMaxHealth", record.maxHealth)
	end

	return record.model
end

local function attachPlacementModel(record: PlacementRecord, model: Model?)
	record.model = model
	if model then
		applyPlacementAttributes(record)
	end

	updatePlacementHealthUi(record)
end

local computeZoneAlignments: (slot: PlotSlot, zones: { ZoneState }?) -> { [string]: Vector3 }
local getZoneAlignment: (blocking: BlockingData, cell: Vector2) -> Vector3
local assignTokenToStoredEntry
local clearStoredToken
local findStoredPlacementEntryById
local getLevelsTable
local getLevelEntry

local function round(value: number): number
	return math.floor(value + 0.5)
end

local function formatMoney(amount: number): string
	if math.abs(amount - math.round(amount)) < 0.001 then
		return string.format("%d", math.round(amount))
	end
	return string.format("%.2f", amount)
end

local function findFirstTextLabel(root: Instance, name: string): TextLabel?
	local found = root:FindFirstChild(name, true)
	if found then
		if found:IsA("TextLabel") then
			return found
		end

		local nestedLabel = found:FindFirstChildWhichIsA("TextLabel", true)
		if nestedLabel then
			return nestedLabel
		end
	end

	for _, descendant in root:GetDescendants() do
		if descendant:IsA("TextLabel") and descendant.Name == name then
			return descendant
		end
	end

	return nil
end

local function resolveBillboardAnchor(model: Model): BasePart?
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

local function resolveBuildingUiTemplate(): Instance?
	if buildingUiTemplate and buildingUiTemplate.Parent then
		return buildingUiTemplate
	end

	local designFolder = ReplicatedStorage:FindFirstChild("Design")
	if designFolder then
		local candidate = designFolder:FindFirstChild("BuildingsUI")
		if candidate then
			buildingUiTemplate = candidate
			return buildingUiTemplate
		end

		local ok, result = pcall(function()
			return designFolder:WaitForChild("BuildingsUI", 5)
		end)
		if ok and result then
			buildingUiTemplate = result
			return buildingUiTemplate
		end
	end

	return nil
end

local function attachBuildingUI(model: Model, assetId: string, level: number, accumulated: number?): (PlacementEarnings.UIHandle?, PlacementHealthUi?)
	debugHealthUi(string.format("attach start asset=%s level=%d model=%s", assetId, level, model:GetFullName()))
	if isGunPlacement(assetId) then
		debugHealthUi("asset treated as gun placement; skipping health UI", assetId)
		return nil, nil
	end

	local template = resolveBuildingUiTemplate()
	if not template then
		debugHealthUi("BuildingsUI template not available")
		return nil, nil
	end

	local templateName = template.Name
	local templateClass = template.ClassName
	local uiContainer = model:FindFirstChild("UI")
	local gunUiContainer = model:FindFirstChild("GunBuildingsUI")
	local anchor = resolveBillboardAnchor(model)

	local function findExisting(container: Instance?): Instance?
		if not container then
			return nil
		end
		local direct = container:FindFirstChild(templateName)
		if direct and direct.ClassName == templateClass then
			return direct
		end
		for _, child in container:GetChildren() do
			if child.Name == templateName and child.ClassName == templateClass then
				return child
			end
		end
		return nil
	end

	local uiInstance = findExisting(uiContainer)
	if not uiInstance and gunUiContainer then
		debugHealthUi("Found dedicated GunBuildingsUI container", gunUiContainer:GetFullName())
		uiInstance = findExisting(gunUiContainer)
		if not uiInstance then
			uiInstance = gunUiContainer
		end
	end
	if not uiInstance and anchor then
		uiInstance = findExisting(anchor)
	end
	if not uiInstance then
		uiInstance = findExisting(model)
	end

	if not uiInstance then
		uiInstance = template:Clone()
		uiInstance.Name = templateName

		if uiContainer then
			if uiInstance:IsA("BillboardGui") then
				if uiContainer:IsA("Attachment") or uiContainer:IsA("BasePart") then
					uiInstance.Adornee = uiContainer
				elseif anchor then
					uiInstance.Adornee = anchor
				end
			end
			uiInstance.Parent = uiContainer
		else
			if not anchor then
				debugHealthUi("No anchor found for model", model:GetFullName())
				uiInstance:Destroy()
				return nil, nil
			end
			if uiInstance:IsA("BillboardGui") then
				uiInstance.Adornee = anchor
				uiInstance.Parent = model
			else
				uiInstance.Parent = anchor
			end
		end
	else
		if uiInstance:IsA("BillboardGui") and not uiInstance.Adornee then
			if uiContainer and (uiContainer:IsA("Attachment") or uiContainer:IsA("BasePart")) then
				uiInstance.Adornee = uiContainer
			elseif anchor then
				uiInstance.Adornee = anchor
			end
		end
	end

	local moneyPerSecond = PlacementStats.GetMoneyPerSecond(assetId, level)
	local moneyLabel = findFirstTextLabel(uiInstance, "MoneyPerSecond")
	if moneyLabel then
		moneyLabel.Text = formatMoney(moneyPerSecond) .. " $/s"
	end

	local levelLabel = findFirstTextLabel(uiInstance, "CurrentLevel")
	if levelLabel then
		levelLabel.Text = "Level " .. tostring(math.max(level, 1))
	end

	local accumulatedLabel = findFirstTextLabel(uiInstance, "MoneyAcummulated")
	if not accumulatedLabel then
		accumulatedLabel = findFirstTextLabel(uiInstance, "MoneyAccumulated")
	end
	if accumulatedLabel then
		accumulatedLabel.Text = formatMoney(accumulated or 0) .. " $"
	end

	local costLabel = findFirstTextLabel(uiInstance, "Cost")
	if costLabel then
		local costText = ""
		local levels = getLevelsTable(assetId)
		if levels then
			local nextLevel = math.max(1, level + 1)
			local nextEntry = getLevelEntry(levels, nextLevel)
			if typeof(nextEntry) == "table" then
				local requiredMoney = tonumber(nextEntry.RequiredMoney)
				if requiredMoney then
					costText = formatMoney(requiredMoney) .. " $"
				end
			end
		end
		costLabel.Text = costText
	end

	local healthLabel = findFirstTextLabel(uiInstance, "Health")
	if not healthLabel then
		local healthContainer = findFirstDescendant(uiInstance, "Health")
		if healthContainer then
			local nestedLabel = healthContainer:FindFirstChildWhichIsA("TextLabel", true)
			if nestedLabel then
				healthLabel = nestedLabel
			end
		end
	end

	local healthBarContainer = findFirstDescendant(uiInstance, "HealthBar")
	if healthBarContainer and healthBarContainer:IsA("GuiObject") then
		local nestedBar = findFirstDescendant(healthBarContainer, "Bar")
		if nestedBar and nestedBar:IsA("GuiObject") then
			healthBarContainer = nestedBar
		end
	end

	local healthFill: GuiObject? = nil
	local function resolveFill(from: Instance?)
		if not from then
			return
		end
		local fillCandidate = findFirstDescendant(from, "Fill")
		if fillCandidate and fillCandidate:IsA("GuiObject") then
			healthFill = fillCandidate
		end
	end

	resolveFill(healthBarContainer)
	if not healthFill then
		resolveFill(uiInstance)
	end

	if not healthLabel then
		debugHealthUi("Health label not located", uiInstance:GetFullName())
	else
		debugHealthUi("Health label found", healthLabel:GetFullName())
	end

	if not healthFill then
		debugHealthUi("Health fill frame not located", uiInstance:GetFullName())
	else
		debugHealthUi("Health fill frame found", healthFill:GetFullName(), healthFill.Size)
	end

	local placementUi: PlacementHealthUi? = nil
	if healthLabel or healthFill then
		placementUi = {
			container = uiInstance,
			healthLabel = healthLabel,
			healthFill = healthFill,
			fillYScale = healthFill and healthFill.Size.Y.Scale or nil,
			fillYOffset = healthFill and healthFill.Size.Y.Offset or nil,
		}
		debugHealthUi("Health UI handle prepared", assetId, placementUi ~= nil)
	end

	return {
		ui = uiInstance,
		accumulatedLabel = accumulatedLabel,
	}, placementUi
end

updatePlacementHealthUi = function(record: PlacementRecord)
	local ui = record.ui
	if not ui then
		debugHealthUi("No health UI bound for asset", record.assetId or "?", "entity", record.entity)
		return
	end

	local maxHealth = math.max(1, tonumber(record.maxHealth) or 0)
	local currentValue = tonumber(record.health) or 0
	local clampedHealth = math.clamp(currentValue, 0, maxHealth)
	debugHealthUi(string.format("Update entity=%s asset=%s current=%d max=%d", tostring(record.entity), tostring(record.assetId), clampedHealth, maxHealth))

	if ui.healthLabel and ui.healthLabel.Parent then
		ui.healthLabel.Text = string.format("Vida: %d/%d", math.floor(clampedHealth + 0.5), maxHealth)
	else
		debugHealthUi("Health label missing parent", record.assetId or "?", record.entity)
	end

	if ui.healthFill and ui.healthFill.Parent then
		local ratio = if maxHealth > 0 then math.clamp(clampedHealth / maxHealth, 0, 1) else 0
		local yScale = ui.fillYScale or ui.healthFill.Size.Y.Scale
		local yOffset = ui.fillYOffset or ui.healthFill.Size.Y.Offset
		ui.healthFill.Size = UDim2.new(ratio, 0, yScale, yOffset)
		if ratio <= 0.15 then
			ui.healthFill.BackgroundColor3 = Color3.fromRGB(220, 70, 60)
		elseif ratio <= 0.45 then
			ui.healthFill.BackgroundColor3 = Color3.fromRGB(235, 170, 60)
		else
			ui.healthFill.BackgroundColor3 = Color3.fromRGB(60, 200, 80)
		end
	else
		debugHealthUi("Health fill missing parent", record.assetId or "?", record.entity)
	end
end


local function ensureOfflineState(profileData: any): { [string]: any }
	if typeof(profileData) ~= "table" then
		return {
			lastTimestamp = 0,
			pendingBase = 0,
			pendingRaw = 0,
			hasGamepass = false,
		}
	end

	local offlineState = profileData.Offline
	if typeof(offlineState) ~= "table" then
		offlineState = {
			lastTimestamp = 0,
			pendingBase = 0,
			pendingRaw = 0,
			hasGamepass = false,
		}
		profileData.Offline = offlineState
	end

	local pendingBase = math.max(0, tonumber(offlineState.pendingBase) or 0)
	local pendingRaw = math.max(0, tonumber(offlineState.pendingRaw) or 0)
	if pendingBase > pendingRaw then
		pendingRaw = pendingBase
	end

	offlineState.pendingBase = pendingBase
	offlineState.pendingRaw = pendingRaw
	offlineState.lastTimestamp = tonumber(offlineState.lastTimestamp) or 0
	offlineState.hasGamepass = offlineState.hasGamepass == true

	return offlineState
end

local function computePlacementRate(profileData: any): number
	if typeof(profileData) ~= "table" then
		return 0
	end

	local placementState = profileData.placement
	if typeof(placementState) ~= "table" then
		return 0
	end

	local objects = placementState.objects
	if typeof(objects) ~= "table" then
		return 0
	end

	local total = 0
	for _, record in objects do
		if typeof(record) == "table" and record.stored ~= true then
			local assetId = record.asset
			if typeof(assetId) == "string" then
				local level = math.max(1, tonumber(record.level) or 1)
				local perSecond = PlacementStats.GetMoneyPerSecond(assetId, level)
				if perSecond > 0 then
					total += perSecond
				end
			end
		end
	end

	return total
end

local function processOfflineRewards(session: Session)
	local profile = session.profile
	if not profile or typeof(profile.Data) ~= "table" then
		return
	end

	local profileData = profile.Data
	local offlineState = ensureOfflineState(profileData)
	session.offlineState = offlineState

	local hasPass = offlineState.hasGamepass == true
	if not hasPass and OFFLINE_GAMEPASS_ID > 0 then
		local ok, ownsPass = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, session.player.UserId, OFFLINE_GAMEPASS_ID)
		if ok and ownsPass then
			hasPass = true
			offlineState.hasGamepass = true
		end
	end

	local nowUnix = os.time()
	local lastTimestamp = tonumber(offlineState.lastTimestamp) or 0
	local elapsedSeconds = 0
	if lastTimestamp > 0 then
		elapsedSeconds = math.max(0, nowUnix - lastTimestamp)
	end

	local ratePerSecond = computePlacementRate(profileData)
	--print(`Procesando ingreso offline para {session.player.Name}; lastTs={lastTimestamp} now={nowUnix} elapsed={elapsedSeconds} rate={ratePerSecond}`)

	if elapsedSeconds > 0 and ratePerSecond > 0 then
		local cappedRawSeconds = math.min(elapsedSeconds, OFFLINE_RAW_CAP_SECONDS)
		local cappedBaseSeconds = math.min(elapsedSeconds, OFFLINE_BASE_CAP_SECONDS)

		local newRaw = ratePerSecond * cappedRawSeconds
		local newBase = ratePerSecond * cappedBaseSeconds

		local pendingRaw = math.max(0, tonumber(offlineState.pendingRaw) or 0) + newRaw
		local pendingBase = math.max(0, tonumber(offlineState.pendingBase) or 0) + newBase
		if pendingBase > pendingRaw then
			pendingBase = pendingRaw
		end

		offlineState.pendingRaw = pendingRaw
		offlineState.pendingBase = pendingBase

		--print(`{session.player.Name} acumuló offline: newBase={newBase}, newRaw={newRaw}, totalBase={pendingBase}, totalRaw={pendingRaw}`)
	else
		--print(`Sin acumulación offline para {session.player.Name}; elapsed={elapsedSeconds}, rate={ratePerSecond}`)
	end

	offlineState.lastTimestamp = nowUnix

	local pendingRaw = math.max(0, tonumber(offlineState.pendingRaw) or 0)
	local pendingBase = math.max(0, math.min(tonumber(offlineState.pendingBase) or 0, pendingRaw))
	offlineState.pendingRaw = pendingRaw
	offlineState.pendingBase = pendingBase

	local displayAmount = if hasPass then pendingRaw else pendingBase
	local canBuy = not hasPass and pendingRaw > pendingBase and OFFLINE_GAMEPASS_ID > 0

	if displayAmount > 0 or pendingRaw > 0 then
		--print(` Enviando UI offline a {session.player.Name}: display={displayAmount}, raw={pendingRaw}, hasPass={hasPass}, canBuy={canBuy}`)
		OfflinePackets.Show:FireClient(session.player, displayAmount, pendingRaw, hasPass, canBuy)
	else
		print(`Nada que mostrar para {session.player.Name}`)
	end
end

local function updateOfflineTimestamp(profileData: any, playerName: string?)
	if typeof(profileData) ~= "table" then
		return
	end

	local offlineState = ensureOfflineState(profileData)
	local nowUnix = os.time()
	offlineState.lastTimestamp = nowUnix
	--print(`Actualizando lastTimestamp a {nowUnix} para {playerName or "Desconocido"}`)
end

local function creditOfflineMoney(player: Player, amount: number): boolean
	if amount <= 0 then
		return false
	end

	local success = false
	Profiles.Mutate(player, function(profileData)
		local current = tonumber(profileData.Money) or 0
		profileData.Money = current + amount
		success = true
		return profileData.Money
	end)

	return success
end


local function buildZonePayload(session: Session)
	local slot = session.slot
	return {
		ownerId = session.ownerId,
		slot = slot.index,
		origin = slot:GetOrigin(),
		cellSize = slot:GetCellSize(),
		gridSize = slot:GetGridSize(),
		blockedZones = session.blocking.zones,
		blockedCells = session.blocking.cellsList,
	}
end

local function broadcastZoneState(session: Session)
	placementUpdatePacket:Fire("ZonesSet", buildZonePayload(session))
end

local function sendAllZoneStatesTo(player: Player)
	for _, otherSession in sessions do
		if otherSession.player ~= player then
			placementUpdatePacket:FireClient(player, "ZonesSet", buildZonePayload(otherSession))
		end
	end
end

local function broadcastZoneRemoval(session: Session)
	placementUpdatePacket:Fire("ZonesClear", {
		ownerId = session.ownerId,
		slot = session.slot.index,
	})
end

local function ensureUnlockList(session: Session)
	local placementZones = session.profile.Data.placement and session.profile.Data.placement.zones
	if placementZones then
		placementZones.unlocked = placementZones.unlocked or {}
	else
		session.profile.Data.placement = session.profile.Data.placement or {}
		session.profile.Data.placement.zones = { version = 1, unlocked = {} }
		placementZones = session.profile.Data.placement.zones
	end

	session.blocking.unlocked = session.blocking.unlocked or placementZones.unlocked
	placementZones.unlocked = session.blocking.unlocked

	return placementZones.unlocked
end

local function ensureZoneRecorded(unlockedList, zoneId: string)
	local numericId = tonumber(zoneId:match("LockedZone_(%d+)") or "")

	for _, entry in unlockedList do
		if entry == zoneId then
			return
		end
		if numericId and typeof(entry) == "number" and entry == numericId then
			return
		end
		if typeof(entry) == "string" then
			local entryNumeric = tonumber(entry:match("LockedZone_(%d+)") or "")
			if entry == zoneId or (numericId and entryNumeric and entryNumeric == numericId) then
				return
			end
		end
	end

	unlockedList[#unlockedList + 1] = zoneId
end

local function rebuildBlockingState(session: Session)
	local zones = session.blocking.zones
	local blockedMap, blockedList, zoneLookup = PlotRegistry.BuildBlockedCellDataFromZones(zones)
	session.blocking.cellsMap = blockedMap
	session.blocking.cellsList = blockedList
	session.blocking.zoneLookup = zoneLookup
	session.blocking.zoneAlignments = computeZoneAlignments(session.slot, zones)

	PlacementWorld.ApplyBlockingState(session.plotEntity, {
		cellsMap = blockedMap,
		zones = zones,
	})
end

local function getPlacementToolsFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(PLACEMENT_TOOLS_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = PLACEMENT_TOOLS_FOLDER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

local function findPlacementToolTemplate(assetId: string): Tool?
	local toolsFolder = ReplicatedStorage:FindFirstChild(PLACEMENT_TOOLS_FOLDER_NAME)
	if toolsFolder then
		local candidate = toolsFolder:FindFirstChild(assetId)
		if candidate and candidate:IsA("Tool") then
			return candidate
		end
	end

	if StarterPack then
		local starterCandidate = StarterPack:FindFirstChild(assetId)
		if starterCandidate and starterCandidate:IsA("Tool") then
			return starterCandidate
		end
	end

	return nil
end

local function getBasePlacementTool(): Tool?
	local base = PlacementModule:FindFirstChild("ToolTemplate")
	if base and base:IsA("Tool") then
		return base
	end

	if not base then
		warn("Placement.ToolTemplate no disponible; se requiere un template para las herramientas de placement")
	else
		warn(`Placement.ToolTemplate tipo inesperado ({base.ClassName})`)
	end

	return nil
end

local function ensurePlacementToolTemplate(assetId: string): Tool?
	local existing = findPlacementToolTemplate(assetId)
	if existing then
		return existing
	end

	local baseTemplate = getBasePlacementTool()
	if not baseTemplate then
		return nil
	end

	local toolsFolder = getPlacementToolsFolder()
	local synthesized = baseTemplate:Clone()
	synthesized.Name = assetId
	synthesized.Parent = toolsFolder

	return synthesized
end

local function applyToolAttributes(tool: Tool, token: string?, level: number?)
	if token then
		tool:SetAttribute("PlacementToken", token)
	else
		tool:SetAttribute("PlacementToken", nil)
	end

	if level then
		tool:SetAttribute("PlacementLevel", level)
	else
		tool:SetAttribute("PlacementLevel", nil)
	end
end

local function givePlacementTool(player: Player, assetId: string, token: string?, level: number?)
	local template = ensurePlacementToolTemplate(assetId)
	if not template then
		warn(`No placement tool template found for asset "{assetId}"`)
		return false
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		local ok, result = pcall(function()
			return player:WaitForChild("Backpack", 5)
		end)
		if ok then
			backpack = result
		end
	end

	if not backpack then
		warn(`Backpack not available for player {player.Name}`)
		return false
	end

	local tool = template:Clone()
	applyToolAttributes(tool, token, level)
	tool.Parent = backpack

	local starterGear = player:FindFirstChild("StarterGear")
	if starterGear then
		local sgTool = template:Clone()
		applyToolAttributes(sgTool, token, level)
		sgTool.Parent = starterGear
	end

	return true
end

local function matchesToolToken(tool: Tool, token: string?): boolean
	local value = tool:GetAttribute("PlacementToken")
	if token == nil then
		return value == nil
	end

	return value == token
end

local function findToolIn(container: Instance?, assetId: string, token: string?): Tool?
	if not container then
		return nil
	end

	for _, child in container:GetChildren() do
		if child:IsA("Tool") and child.Name == assetId then
			if matchesToolToken(child, token) then
				return child
			end
		end
	end

	return nil
end


local function hasPlacementTool(player: Player, assetId: string, token: string?): boolean
	local character = player.Character
	if character and findToolIn(character, assetId, token) then
		return true
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack and findToolIn(backpack, assetId, token) then
		return true
	end

	return false
end

local function removeToolsFrom(container: Instance?, assetId: string, token: string?, limit: number?)
	if not container then
		return 0
	end

	local removed = 0
	for _, child in container:GetChildren() do
		if child:IsA("Tool") and child.Name == assetId then
			if matchesToolToken(child, token) then
				child:Destroy()
				removed += 1
				if limit and removed >= limit then
					break
				end
			end
		end
	end

	return removed
end

local function consumePlacementTool(player: Player, assetId: string, token: string?): boolean
	local removed = removeToolsFrom(player.Character, assetId, token, 1)

	if removed == 0 then
		local backpack = player:FindFirstChildOfClass("Backpack")
		if backpack then
			removed = removeToolsFrom(backpack, assetId, token, 1)
		end
	end

	local starterGear = player:FindFirstChild("StarterGear")
	if starterGear then
		local starterRemoved = removeToolsFrom(starterGear, assetId, token, 1)
		if removed == 0 then
			removed = starterRemoved
		end
	end

	return removed > 0
end

local function cleanupPendingProduct(userId: number, productId: number)
	local pending = pendingProductUpgrades[userId]
	if not pending then
		return
	end

	pending[productId] = nil
	if next(pending) == nil then
		pendingProductUpgrades[userId] = nil
	end
end

local function cancelPendingProductsForPlacement(userId: number, placementId: string)
	local pending = pendingProductUpgrades[userId]
	if not pending then
		return
	end

	for productId, info in pending do
		if info and info.placementId == placementId then
			pending[productId] = nil
		end
	end

	if next(pending) == nil then
		pendingProductUpgrades[userId] = nil
	end
end

local function grantPlacementTool(player: Player, assetId: string, storedEntryId: string?, preferredLevel: number?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, "Jugador invalido"
	end

	if typeof(assetId) ~= "string" or assetId == "" then
		return false, "Asset invalido"
	end

	local ok, result = pcall(AssetRegistry.Get, assetId)
	if not ok or result == nil then
		return false, `Asset "{assetId}" no registrado`
	end

	local function clampLevel(value)
		if value == nil then
			return nil
		end
		local numeric = tonumber(value)
		if not numeric then
			return nil
		end
		numeric = math.max(1, math.floor(numeric + 0.5))
		return numeric
	end

	local levelForTool = clampLevel(preferredLevel)

	local session = sessions[player]
	local profileData = nil
	if session and session.profile and session.profile.Data then
		profileData = session.profile.Data
	else
		profileData = Profiles.GetProfileData(player)
	end

	if not levelForTool and profileData then
		if typeof(storedEntryId) == "string" and storedEntryId ~= "" then
			local storedEntry = findStoredPlacementEntryById(profileData, storedEntryId)
			if typeof(storedEntry) == "table" then
				levelForTool = clampLevel(storedEntry.level)
			end
		end

		if not levelForTool then
			local inventoryEntry = PlacementInventory.GetEntry(profileData, assetId)
			if inventoryEntry then
				levelForTool = clampLevel(inventoryEntry.level)
			end
		end
	end

	levelForTool = levelForTool or 1

	local token = HttpService:GenerateGUID(false)
	local delivered = givePlacementTool(player, assetId, token, levelForTool)
	if not delivered then
		return false, `No se pudo entregar la herramienta de placement "{assetId}"`
	end

	if not hasPlacementTool(player, assetId, token) then
		return false, `Herramienta "{assetId}" no disponible despues de otorgarla`
	end

	if session then
		assignTokenToStoredEntry(session, assetId, token, storedEntryId)
	end

	return true, token
end

local function removePlacement(session: Session, placementId: string, options: { store: boolean? }?)
	local record = session.placements[placementId]
	if not record then
		return false, "Placement desconocido"
	end

	local placementEntity = record.entity
	local serialized = PlacementWorld.SerializePlacement(placementEntity)
	if not serialized then
		return false, "Datos de placement no disponibles"
	end

	local storedHealth = math.max(0, math.floor((tonumber(record.health) or 0) + 0.5))
	local storedMaxHealth = math.max(1, math.floor((tonumber(record.maxHealth) or 1) + 0.5))
	local gunSnapshot: { [string]: any }? = nil

	if isGunPlacement(record.assetId) then
		local gunService = getGunBuildingService()
		if gunService and typeof((gunService :: any).GetStateByPlacementId) == "function" then
			local gunState = (gunService :: any).GetStateByPlacementId(placementId)
			if gunState then
				gunSnapshot = {
					ammo = math.max(0, math.floor((tonumber(gunState.ammo) or 0) + 0.5)),
					reloadRemaining = math.max(0, tonumber(gunState.reloadRemaining) or 0),
					cooldownRemaining = math.max(0, tonumber(gunState.cooldownRemaining) or 0),
					disabled = gunState.disabled == true,
					health = storedHealth,
				}
			end
		end
	end

	serialized.health = storedHealth
	serialized.maxHealth = storedMaxHealth
	if gunSnapshot then
		serialized.gunState = gunSnapshot
	end

	PlacementEarnings.Unregister(placementEntity)
	cancelPendingProductsForPlacement(session.player.UserId, placementId)
	unregisterGunPlacement(placementEntity, placementId)

	placementsByEntity[placementEntity] = nil
	session.placements[placementId] = nil

	PlacementWorld.DestroyPlacement(placementEntity)

	local shouldStore = options == nil or options.store ~= false
	local objectsContainer = session.profile and session.profile.Data and session.profile.Data.placement
	local objects = objectsContainer and objectsContainer.objects
	if objectsContainer and typeof(objects) ~= "table" then
		objects = {}
		objectsContainer.objects = objects
	end

	local storedLevel = math.max(1, tonumber(serialized.level) or 1)
	if objects then
		if shouldStore then
			local storedRecorded = false
			for _, entry in objects do
				if entry and entry.id == placementId then
					entry.level = storedLevel
					entry.position = nil
					entry.rotation = nil
					entry.stored = true
					entry.token = nil
					entry.health = storedHealth
					entry.maxHealth = storedMaxHealth
					entry.gunState = gunSnapshot
					storedRecorded = true
					break
				end
			end

			if not storedRecorded then
				objects[#objects + 1] = {
					id = placementId,
					asset = serialized.asset,
					level = storedLevel,
					stored = true,
					position = nil,
					rotation = nil,
					token = nil,
					health = storedHealth,
					maxHealth = storedMaxHealth,
					gunState = gunSnapshot,
				}
			end
		else
			local newList = {}
			for _, entry in objects do
				if entry and entry.id ~= placementId then
					newList[#newList + 1] = entry
				end
			end
			objectsContainer.objects = newList
		end
	end

	placementUpdatePacket:Fire("Remove", { id = placementId })

	return true, serialized
end

getLevelsTable = function(assetId: string)
	local definition = BuildingsData[assetId]
	if typeof(definition) ~= "table" then
		local ammoDefinition = AmmoBuildingsData[assetId]
		if typeof(ammoDefinition) ~= "table" then
			return nil
		end

		return ammoDefinition.Level or ammoDefinition.Levels
	end

	return definition.Level or definition.Levels
end

getLevelEntry = function(levels: { [any]: any }?, level: number)
	if typeof(levels) ~= "table" then
		return nil
	end

	local direct = levels[level]
	if typeof(direct) == "table" then
		return direct
	end

	local stringEntry = levels[tostring(level)]
	if typeof(stringEntry) == "table" then
		return stringEntry
	end

	return nil
end

local function computeUpgradeContext(assetId: string, currentLevel: number)
	if typeof(assetId) ~= "string" or assetId == "" then
		return nil, "Asset invalido"
	end

	local levels = getLevelsTable(assetId)
	if not levels then
		return nil, "Datos de building no disponibles"
	end

	local nextLevel = math.max(1, currentLevel + 1)
	local entry = getLevelEntry(levels, nextLevel)
	if typeof(entry) ~= "table" then
		return nil, "Nivel maximo alcanzado"
	end

	local requiredMoney = tonumber(entry.RequiredMoney) or 0
	local productId = tonumber(entry.RobuxPurchaseId) or 0

	local context = {
		assetId = assetId,
		currentLevel = currentLevel,
		nextLevel = nextLevel,
		requiredMoney = requiredMoney,
		productId = productId > 0 and productId or nil,
		nextMoneyPerSecond = PlacementStats.GetMoneyPerSecond(assetId, nextLevel),
	}

	return context, nil
end


local function getPlacementUpgradeContext(session: Session, placementId: string)
	local record = session.placements[placementId]
	if not record then
		return nil, "Placement desconocido"
	end

	local placementEntity = record.entity
	local serialized = PlacementWorld.SerializePlacement(placementEntity)
	if not serialized then
		return nil, "Datos de placement no disponibles"
	end

	local assetId = serialized.asset
	if typeof(assetId) ~= "string" or assetId == "" then
		return nil, "Asset invalido"
	end

	local currentLevel = math.max(1, tonumber(serialized.level) or tonumber(record.level) or 1)
	local context, err = computeUpgradeContext(assetId, currentLevel)
	if not context then
		return nil, err
	end

	return context, nil
end

local function findProfilePlacementEntry(profileData: any, placementId: string)
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

	for _, entry in objects do
		if typeof(entry) == "table" and entry.id == placementId then
			return entry
		end
	end

	return nil
end

findStoredPlacementEntryById = function(profileData: any, placementId: string)
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

	for _, entry in objects do
		if typeof(entry) == "table" and entry.id == placementId and entry.stored == true then
			return entry
		end
	end

	return nil
end

local function findStoredPlacementEntryByToken(profileData: any, token: string?)
	if typeof(profileData) ~= "table" or typeof(token) ~= "string" then
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

	for _, entry in objects do
		if typeof(entry) == "table" and entry.stored == true and entry.token == token then
			return entry
		end
	end

	return nil
end

local function findStoredPlacementEntry(profileData: any, assetId: string)
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

	local bestEntry = nil
	local bestLevel = -math.huge

	for _, entry in objects do
		if typeof(entry) == "table" and entry.asset == assetId and entry.stored == true and entry.token == nil then
			local numericLevel = tonumber(entry.level) or 1
			if numericLevel > bestLevel then
				bestLevel = numericLevel
				bestEntry = entry
			end
		end
	end

	return bestEntry
end

local function countStoredEntries(profileData: any, assetId: string): number
	if typeof(profileData) ~= "table" then
		return 0
	end

	local placementState = profileData.placement
	if typeof(placementState) ~= "table" then
		return 0
	end

	local objects = placementState.objects
	if typeof(objects) ~= "table" then
		return 0
	end

	local total = 0
	for _, entry in objects do
		if typeof(entry) == "table" and entry.asset == assetId and entry.stored == true then
			total += 1
		end
	end

	return total
end

assignTokenToStoredEntry = function(session: Session?, assetId: string, token: string, storedEntryId: string?)
	if not session or typeof(token) ~= "string" or token == "" then
		return
	end

	local profile = session.profile
	local profileData = profile and profile.Data
	if typeof(profileData) ~= "table" then
		return
	end

	local targetEntry = nil
	if typeof(storedEntryId) == "string" and storedEntryId ~= "" then
		targetEntry = findStoredPlacementEntryById(profileData, storedEntryId)
	end

	if not targetEntry then
		targetEntry = findStoredPlacementEntry(profileData, assetId)
	end

	if targetEntry then
		targetEntry.token = token
		session.storedTokenMap[token] = targetEntry.id
	else
		session.storedTokenMap[token] = nil
	end
end

clearStoredToken = function(session: Session?, token: string?)
	if not session or typeof(token) ~= "string" then
		return
	end

	local storedId = session.storedTokenMap[token]
	local profile = session.profile
	local profileData = profile and profile.Data
	if storedId and typeof(profileData) == "table" then
		local entry = findProfilePlacementEntry(profileData, storedId)
		if entry then
			entry.token = nil
		end
	end

	session.storedTokenMap[token] = nil
end

local spawnModel = nil

local function applyPlacementUpgrade(session: Session, placementId: string, context)
	if typeof(context) ~= "table" or typeof(context.nextLevel) ~= "number" then
		return false, "Contexto de upgrade invalido"
	end

	local record = session.placements[placementId]
	if not record then
		return false, "Placement desconocido"
	end

	local placementEntity = record.entity

	local serialized = PlacementWorld.SerializePlacement(placementEntity)
	if not serialized then
		return false, "Datos de placement no disponibles"
	end

	local assetId = serialized.asset
	local assetDef = AssetRegistry.Get(assetId)
	local newLevel = math.max(1, context.nextLevel)

	local profile = session.profile
	local profileData = profile and profile.Data
	if typeof(profileData) ~= "table" then
		return false, "Perfil no disponible"
	end

	local profileEntry = findProfilePlacementEntry(profileData, placementId)
	if not profileEntry then
		return false, "Registro de placement no encontrado"
	end

	profileEntry.level = newLevel
	record.level = newLevel

	PlacementWorld.SetPlacementLevel(placementEntity, newLevel)

	local previousAccumulated = PlacementEarnings.GetAccumulated(placementEntity) or 0
	PlacementEarnings.Unregister(placementEntity)

	serialized.level = newLevel
	local orientedFootprint = Grid.getOrientedFootprint(assetDef.footprint, serialized.rotation or 0)
	local newModel = spawnModel(session, assetDef, serialized, orientedFootprint)
	if not newModel then
		return false, "No se pudo generar el nuevo modelo"
	end

	PlacementWorld.ReplacePlacementModel(placementEntity, newModel)
	record.maxHealth = math.max(100, PlacementStats.GetMaxHealth(assetId, newLevel))
	record.health = record.maxHealth
	attachPlacementModel(record, newModel)

	local uiHandle, healthUi = attachBuildingUI(newModel, assetId, newLevel, previousAccumulated)
	record.ui = healthUi
	updatePlacementHealthUi(record)
	PlacementEarnings.Register({
		entity = placementEntity,
		placementId = placementId,
		assetId = assetId,
		level = newLevel,
		model = newModel,
		root = newModel.PrimaryPart,
		ownerUserId = session.ownerId,
		uiHandle = uiHandle,
		initialAccumulated = previousAccumulated,
	})
	registerGunPlacement(session, placementEntity, placementId, assetId, newLevel, newModel, nil)

	local moneyPerSecond = PlacementStats.GetMoneyPerSecond(assetId, newLevel)

	PlacementInventory.Adjust(session.player, assetId, 0, newLevel)

	local nextContext = computeUpgradeContext(assetId, newLevel)
	local payload = {
		id = placementId,
		level = newLevel,
		moneyPerSecond = moneyPerSecond,
		nextMoneyPerSecond = nextContext and nextContext.nextMoneyPerSecond or nil,
		requiredMoney = nextContext and nextContext.requiredMoney or nil,
		nextLevel = nextContext and nextContext.nextLevel or nil,
		hasNext = nextContext ~= nil,
	}

	placementUpdatePacket:FireClient(session.player, "LevelChanged", payload)

	return true, payload
end

local function handleCurrencyUpgrade(session: Session, placementId: string)
	local context, err = getPlacementUpgradeContext(session, placementId)
	if not context then
		return false, err
	end

	local requiredMoney = math.max(0, tonumber(context.requiredMoney) or 0)
	local profile = session.profile
	local profileData = profile and profile.Data
	if typeof(profileData) ~= "table" then
		return false, "Perfil no disponible"
	end

	local currentMoneyValue = tonumber(profileData.Money)
	if not currentMoneyValue then
		return false, "Fondos invalidos"
	end

	if currentMoneyValue < requiredMoney then
		return false, "Fondos insuficientes"
	end

	profileData.Money = currentMoneyValue - requiredMoney

	local success, payload = applyPlacementUpgrade(session, placementId, context)
	if not success then
		profileData.Money = currentMoneyValue
		return false, payload
	end

	return true, payload
end

local function handleProductUpgrade(session: Session, placementId: string, productId: number)
	if productId <= 0 then
		return false, "Producto invalido"
	end

	local context, err = getPlacementUpgradeContext(session, placementId)
	if not context then
		return false, err
	end

	if context.productId ~= productId then
		return false, "Producto invalido"
	end

	local userId = session.player.UserId
	local pending = pendingProductUpgrades[userId]
	if not pending then
		pending = {}
		pendingProductUpgrades[userId] = pending
	end

	if pending[productId] then
		return false, "Compra en progreso"
	end

	pending[productId] = {
		placementId = placementId,
	}

	local ok, promptErr = pcall(MarketplaceService.PromptProductPurchase, MarketplaceService, session.player, productId)
	if not ok then
		warn(`No se pudo iniciar compra del producto {productId} para {session.player.Name}: {promptErr}`)
		cleanupPendingProduct(userId, productId)
		return false, "No se pudo iniciar la compra"
	end

	return true, nil
end
local function vectorFromTable(value): Vector2
	return Vector2.new(value.x or value.X, value.y or value.Y)
end

local function serializePlacementForClient(data: PlacementData, record: PlacementRecord?)
	local payload = {
		id = data.id,
		asset = data.asset,
		position = data.position,
		rotation = data.rotation,
		level = math.max(1, tonumber(data.level) or 1),
	}

	if record then
		payload.health = math.max(0, tonumber(record.health) or 0)
		payload.maxHealth = math.max(0, tonumber(record.maxHealth) or 0)
	end

	return payload
end

local function placementDataToProfileEntry(data: PlacementData)
	return {
		id = data.id,
		asset = data.asset,
		position = { x = data.position.X, y = data.position.Y },
		rotation = data.rotation,
		level = math.max(1, tonumber(data.level) or 1),
	}
end

local function ensurePlacementCells(assetDef, position: Vector2, rotation: number)
	local orientedFootprint = Grid.getOrientedFootprint(assetDef.footprint, rotation)
	local cells = Grid.enumerateCells(position, orientedFootprint)
	return orientedFootprint, cells
end

local function findBlockedCell(blockedCells: { [number]: { [number]: string } }, cells: { Vector2 })
	for _, cell in cells do
		local column = blockedCells[cell.X]
		if column then
			local zoneId = column[cell.Y]
			if zoneId then
				return cell, zoneId
			end
		end
	end
	return nil, nil
end

local function findZoneForCell(zones: { ZoneState }?, cell: Vector2): ZoneState?
	if not zones then
		return nil
	end

	for _, zone in zones do
		local minBound = zone.min
		local maxBound = zone.max
		if minBound and maxBound then
			if cell.X >= minBound.X and cell.X <= maxBound.X and cell.Y >= minBound.Y and cell.Y <= maxBound.Y then
				return zone
			end
		end
	end

	return nil
end

computeZoneAlignments = function(slot: PlotSlot, zones: { ZoneState }?): { [string]: Vector3 }
	local result: { [string]: Vector3 } = {}
	if not zones or #zones == 0 then
		return result
	end

	local origin = slot:GetOrigin()
	local cellSize = slot:GetCellSize()

	for _, zone in zones do
		local zoneId = zone.id
		if zoneId then
			local alignment = ZERO_VECTOR
			local markerCFrame = zone.markerCFrame
			local markerSize = zone.markerSize
			if typeof(markerCFrame) == "CFrame" and typeof(markerSize) == "Vector3" then
				local halfX = markerSize.X * 0.5
				local halfZ = markerSize.Z * 0.5
				local widthCells = math.max(1, round(markerSize.X / cellSize))
				local depthCells = math.max(1, round(markerSize.Z / cellSize))
				local found = false

				for ix = 1, widthCells do
					for iy = 1, depthCells do
						local offsetX = -halfX + (ix - 0.5) * cellSize
						local offsetZ = -halfZ + (iy - 0.5) * cellSize
						local worldPosition = markerCFrame:PointToWorldSpace(Vector3.new(offsetX, 0, offsetZ))
						local cellCoord = Grid.worldToCell(origin, cellSize, worldPosition)

						local withinZone = true
						if zone.min and zone.max then
							if cellCoord.X < zone.min.X or cellCoord.X > zone.max.X or cellCoord.Y < zone.min.Y or cellCoord.Y > zone.max.Y then
								withinZone = false
							end
						end

						if withinZone then
							local cellCFrame = Grid.cellToWorld(origin, cellSize, cellCoord)
							alignment = worldPosition - cellCFrame.Position
							found = true
							break
						end
					end
					if found then
						break
					end
				end
			end

			result[zoneId] = alignment
		end
	end

	return result
end

getZoneAlignment = function(blocking: BlockingData, cell: Vector2): Vector3
	local zone = findZoneForCell(blocking and blocking.zones, cell)
	if not zone or not zone.id then
		return ZERO_VECTOR
	end

	local alignments = blocking.zoneAlignments
	if not alignments then
		return ZERO_VECTOR
	end

	return alignments[zone.id] or ZERO_VECTOR
end

local function ensureCellsWithinSingleZone(blocking: BlockingData, cells: { Vector2 }): (boolean, string?)
	local zones = blocking and blocking.zones
	if not zones or #zones == 0 then
		return true, nil
	end

	local referenceZone: ZoneState? = nil

	for _, cell in cells do
		local zone = findZoneForCell(zones, cell)
		if not zone then
			return false, "Fuera de cualquier zona disponible"
		end

		if zone.locked ~= false then
			local zoneId = zone.id or "Zona"
			return false, `Zona bloqueada ({zoneId})`
		end

		if referenceZone and zone ~= referenceZone then
			return false, "Debes mantenerte dentro de una sola zona"
		end

		referenceZone = referenceZone or zone
	end

	return true, nil
end

local function configurePlacementModel(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanQuery = true
			descendant.CanTouch = false
			descendant.CanCollide = false
			descendant.Massless = true
		end
	end
end

function spawnModel(session: Session, assetDef, placementData: PlacementData, orientedFootprint: Vector2)
	local model = AssetRegistry.Clone(assetDef.id, placementData.level)
	if not model then
		return nil
	end
	local slot = session.slot
	local heightOffset = assetDef.heightOffset
	local primary = model.PrimaryPart
	if primary then
		local pivotOffset = primary.PivotOffset
		local pivotOffsetY = if pivotOffset then pivotOffset.Position.Y else 0
		heightOffset = primary.Size.Y * 0.5 + pivotOffsetY
	end
	local cframe = Grid.computePlacementCFrame(
		slot:GetOrigin(),
		slot:GetCellSize(),
		placementData.position,
		placementData.rotation,
		orientedFootprint,
		heightOffset
	)

	local alignmentOffset = getZoneAlignment(session.blocking, placementData.position)
	if alignmentOffset.Magnitude > 0 then
		cframe = cframe + alignmentOffset
	end
	model:PivotTo(cframe)
	model.Parent = slot:GetAssetsFolder()

	configurePlacementModel(model)

	model:SetAttribute("PlacementId", placementData.id)
	model:SetAttribute("PlacementAsset", placementData.asset)
	model:SetAttribute("PlacementOwnerId", session.ownerId)
	model:SetAttribute("PlacementLevel", math.max(1, tonumber(placementData.level) or 1))

	return model
end

type SavedPlacement = {
	id: string?,
	asset: string,
	position: (Vector2 | { x: number, y: number, X: number?, Y: number? })?,
	rotation: number?,
	level: number?,
	stored: boolean?,
	token: string?,
	health: number?,
	maxHealth: number?,
	gunState: { [string]: any }?,
}

local function applyPlacementData(session: Session, placementEntry: SavedPlacement)
	if placementEntry.stored == true then
		return
	end

	local positionTable = placementEntry.position
	if not positionTable then
		warn(`Skipping placement for {session.player.Name}; stored placement is missing position data`)
		return
	end

	(placementEntry :: any).token = nil

	local assetId = placementEntry.asset
	local assetDef = AssetRegistry.Get(assetId)
	local position = vectorFromTable(positionTable)
	local rotation = placementEntry.rotation or 0

	local placementLevel = 1

	local profile = session.profile
	local profileData = profile and profile.Data
	if typeof(profileData) == "table" then
		local inventoryEntry = PlacementInventory.GetEntry(profileData, assetId)
		local storedLevel = inventoryEntry and tonumber(inventoryEntry.level)
		if storedLevel and storedLevel >= 1 then
			placementLevel = math.max(1, math.floor(storedLevel + 0.5))
		end
	end
	local storedLevel = tonumber(placementEntry.level)
	if storedLevel then
		placementLevel = math.max(1, storedLevel)
	end

	local orientedFootprint, cells = ensurePlacementCells(assetDef, position, rotation)

	if not Grid.isWithinBounds(session.slot:GetGridSize(), position, orientedFootprint) then
		warn(`Skipping placement for {session.player.Name}; stored position is out of bounds`)
		return
	end

	local blockedCell, zoneId = findBlockedCell(session.blocking.cellsMap, cells)
	if blockedCell then
		warn(`Skipping placement for {session.player.Name}; stored position intersects locked zone {zoneId}`)
		return
	end

	local zoneOk, zoneMessage = ensureCellsWithinSingleZone(session.blocking, cells)
	if not zoneOk then
		warn(`Skipping placement for {session.player.Name}; {zoneMessage}`)
		return
	end

	local placementData: PlacementData = {
		id = placementEntry.id or HttpService:GenerateGUID(false),
		asset = assetId,
		position = position,
		rotation = rotation,
		cells = cells,
		level = placementLevel,
	}

	placementEntry.id = placementData.id

	if not PlacementWorld.IsAreaFree(session.plotEntity, cells) then
		warn(`Overlapping placement detected for {session.player.Name}; skipping"`)
		return
	end

	local accumulatedAmount = 0
	local placementEntryAny = placementEntry :: any
	if placementEntryAny.accumulated ~= nil then
		placementEntryAny.accumulated = nil
	end
	placementEntry.level = placementLevel

	local model = spawnModel(session, assetDef, placementData, orientedFootprint)
	local placementEntity = PlacementWorld.CreatePlacement(session.plotEntity, placementData, model)
	local maxHealth = math.max(100, PlacementStats.GetMaxHealth(assetId, placementLevel))

	local storedMax = tonumber(placementEntryAny.maxHealth)
	if storedMax then
		maxHealth = math.max(1, math.floor(storedMax + 0.5))
	end

	local healthValue = tonumber(placementEntryAny.health)
	local placementHealth = maxHealth
	if healthValue then
		placementHealth = math.clamp(math.floor(healthValue + 0.5), 0, maxHealth)
	end

	local initialGunState = nil
	local rawGunState = placementEntryAny.gunState
	if typeof(rawGunState) == "table" then
		local ammoValue = rawGunState.ammo
		local reloadValue = rawGunState.reloadRemaining
		local cooldownValue = rawGunState.cooldownRemaining
		local stateHealth = rawGunState.health
		initialGunState = {
			ammo = if ammoValue ~= nil then tonumber(ammoValue) else nil,
			reloadRemaining = if reloadValue ~= nil then tonumber(reloadValue) else nil,
			cooldownRemaining = if cooldownValue ~= nil then tonumber(cooldownValue) else nil,
			health = math.clamp(math.floor((tonumber(stateHealth) or placementHealth) + 0.5), 0, maxHealth),
			disabled = rawGunState.disabled,
		}
	elseif placementHealth < maxHealth then
		initialGunState = {
			health = placementHealth,
		}
	end
	local placementRecord: PlacementRecord = {
		entity = placementEntity,
		assetId = assetId,
		level = placementLevel,
		maxHealth = maxHealth,
		health = placementHealth,
		model = model,
		ui = nil,
	}
	attachPlacementModel(placementRecord, model)
	session.placements[placementData.id] = placementRecord
	placementsByEntity[placementEntity] = {
		session = session,
		id = placementData.id,
	}

	if model then
		model:SetAttribute("PlacementLevel", placementLevel)
		local uiHandle, healthUi = attachBuildingUI(model, assetId, placementLevel, accumulatedAmount)
		placementRecord.ui = healthUi
		updatePlacementHealthUi(placementRecord)
		PlacementEarnings.Register({
			entity = placementEntity,
			placementId = placementData.id,
			assetId = assetId,
			level = placementLevel,
			model = model,
			root = model.PrimaryPart,
			ownerUserId = session.ownerId,
			uiHandle = uiHandle,
			initialAccumulated = accumulatedAmount,
		})
		registerGunPlacement(session, placementEntity, placementData.id, assetId, placementLevel, model, initialGunState)
	end

		MarketplaceService.PromptProductPurchaseFinished:Connect(function(player, productId, wasPurchased)
			local pending = pendingProductUpgrades[player.UserId]
			if not pending then
				return
			end

			local info = pending[productId]
			if not info then
				return
			end

			cleanupPendingProduct(player.UserId, productId)

			if not wasPurchased then
				return
			end

			local session = sessions[player]
			if not session then
				return
			end

			local context, err = getPlacementUpgradeContext(session, info.placementId)
			if not context then
				if err then
					warn(`No se pudo completar la compra del producto {productId} para {player.Name}: {err}`)
				end
				return
			end

			if context.productId ~= productId then
				return
			end

			local success, result = applyPlacementUpgrade(session, info.placementId, context)
			if not success then
				warn(`No se pudo aplicar el upgrade del producto {productId} para {player.Name}: {result}`)
			end
		end)
end

local function restorePlacementTools(session: Session)
	local profile = session.profile
	if not profile or typeof(profile.Data) ~= "table" then
		return
	end

	local player = session.player
	if not player or not player.Parent then
		return
	end

		local placementState = profile.Data.placement
		local storedByAsset: { [string]: { any } } = {}
		if typeof(placementState) == "table" and typeof(placementState.objects) == "table" then
			for _, entry in placementState.objects do
				if typeof(entry) == "table" and entry.asset and entry.stored == true then
					local assetKey = entry.asset
					local list = storedByAsset[assetKey]
					if not list then
						list = {}
						storedByAsset[assetKey] = list
					end
					list[#list + 1] = entry
				end
			end
		end

		local records = PlacementInventory.GetAll(profile.Data)
	for assetId, record in records do
		local available = math.max(0, tonumber(record.available) or 0)
		if available > 0 then
				local storedList = storedByAsset[assetId]
				if not storedList then
					storedList = {}
					storedByAsset[assetId] = storedList
				else
					local filtered = {}
					for _, entry in storedList do
						if typeof(entry) == "table" then
							filtered[#filtered + 1] = entry
						end
					end
					storedList = filtered
					storedByAsset[assetId] = storedList
				end
			for _ = 1, available do
				if not player.Parent then
					return
				end

					local storedEntry = nil
					if #storedList > 0 then
						storedEntry = table.remove(storedList)
					end
					local storedEntryId = storedEntry and storedEntry.id or nil
					local preferredLevel = storedEntry and storedEntry.level or record.level
					local success, payload = grantPlacementTool(player, assetId, storedEntryId, preferredLevel)
				if not success then
					local message = if typeof(payload) == "string" then payload else "Fallo desconocido"
					warn(`No se pudo restaurar la herramienta "{assetId}" para {player.Name}: {message}`)
					break
				end
			end
		end
	end
end

local function loadSession(player: Player, profile: any)
	local userId = player.UserId
	local placementState = profile.Data.placement

	pendingProductUpgrades[userId] = nil

	placementState.objects = placementState.objects or {}
	placementState.slot = nil
	placementState.zones = placementState.zones or { version = 1, unlocked = {} }
	placementState.zones.unlocked = placementState.zones.unlocked or {}
	for _, entry in placementState.objects do
		if typeof(entry) == "table" then
			entry.token = nil
		end
	end

	local slot = PlotRegistry.Assign(userId)
	if not slot then
		warn(`No available plot slots for player {player.Name}`)
		return
	end

	local baseZones = slot:GetBlockedZones()
	PlotRegistry.ApplyUnlockList(baseZones, placementState.zones.unlocked)
	local blockedCellsMap, blockedCellList, zoneLookup = PlotRegistry.BuildBlockedCellDataFromZones(baseZones)

	local blockingData: BlockingData = {
		zones = baseZones,
		cellsMap = blockedCellsMap,
		cellsList = blockedCellList,
		zoneLookup = zoneLookup,
		zoneAlignments = computeZoneAlignments(slot, baseZones),
		unlocked = placementState.zones.unlocked,
	}

	local plotEntity = PlacementWorld.CreatePlot({
		ownerId = userId,
		slot = slot.index,
		origin = slot:GetOrigin(),
		gridSize = slot:GetGridSize(),
		cellSize = slot:GetCellSize(),
		assetsFolder = slot:GetAssetsFolder(),
		basePart = slot:GetBasePart(),
		spawnCFrame = slot:GetSpawnCFrame(),
		blockedCells = blockingData.cellsMap,
		blockedZones = blockingData.zones,
	})

	local session: Session = {
		player = player,
		ownerId = userId,
		profile = profile,
		slot = slot,
		plotEntity = plotEntity,
		placements = {},
		blocking = blockingData,
		characterConnection = nil,
		pendingPlacements = {},
		offlineState = nil,
		storedTokenMap = {},
	}

	sessions[player] = session

	for _, placementEntry in placementState.objects do
		applyPlacementData(session, placementEntry)
	end

	if slot:GetSpawnCFrame() then
		local function teleportCharacter(character: Model)
			slot:TeleportCharacter(character)
		end

		if player.Character then
			teleportCharacter(player.Character)
		end

		session.characterConnection = player.CharacterAdded:Connect(teleportCharacter)
	end

	local plotDescription = {
		slot = slot.index,
		origin = slot:GetOrigin(),
		cellSize = slot:GetCellSize(),
		gridSize = slot:GetGridSize(),
		blockedCells = blockingData.cellsList,
		blockedZones = blockingData.zones,
	}
	local clientPlacements = {}
	for _, placementRecord in session.placements do
		local data = PlacementWorld.SerializePlacement(placementRecord.entity)
		if data then
			data.health = math.max(0, tonumber(placementRecord.health) or 0)
			data.maxHealth = math.max(0, tonumber(placementRecord.maxHealth) or 0)
			clientPlacements[#clientPlacements + 1] = data
		end
	end

	restorePlacementTools(session)

	placementInitPacket:FireClient(player, plotDescription, clientPlacements)
	sendAllZoneStatesTo(player)
	broadcastZoneState(session)
	processOfflineRewards(session)
end

local function clearSession(player: Player)
	local session = sessions[player]
	if not session then
		return
	end

	broadcastZoneRemoval(session)
	local profile = session.profile
	if profile and typeof(profile.Data) == "table" then
		updateOfflineTimestamp(profile.Data, session.player.Name)
	end

	pendingProductUpgrades[player.UserId] = nil
	sessions[player] = nil

	for placementId, placementRecord in pairs(session.placements) do
		PlacementEarnings.Unregister(placementRecord.entity)
		unregisterGunPlacement(placementRecord.entity, placementId)
		placementsByEntity[placementRecord.entity] = nil
		PlacementWorld.DestroyPlacement(placementRecord.entity)
		session.placements[placementId] = nil
	end

	PlacementWorld.DestroyPlot(session.plotEntity)

	if session.characterConnection then
		session.characterConnection:Disconnect()
		session.characterConnection = nil
	end
	PlotRegistry.Release(player.UserId)
end

local function onProfileLoaded(player, profile)
	loadSession(player, profile)
end

local function onProfileReleased(player)
	clearSession(player)
end

Profiles.ProfileLoaded:Connect(onProfileLoaded)
Profiles.ProfileReleased:Connect(onProfileReleased)

local function getPlacementRecordByEntity(placementEntity: number): (PlacementRecord?, Session?, string?)
	local lookup = placementsByEntity[placementEntity]
	if not lookup then
		return nil, nil, nil
	end

	local session = lookup.session
	local record = session and session.placements[lookup.id]
	if not record then
		placementsByEntity[placementEntity] = nil
		return nil, nil, nil
	end

	return record, session, lookup.id
end

local function applyPlacementDamage(placementEntity: number, amount: number): (boolean, { id: string, remaining: number, maxHealth: number, destroyed: boolean }?)
	local record, session, placementId = getPlacementRecordByEntity(placementEntity)
	if not record or not session or not placementId then
		return false, nil
	end

	local damage = math.max(0, tonumber(amount) or 0)
	if damage <= 0 then
		return true, {
			id = placementId,
			remaining = record.health,
			maxHealth = record.maxHealth,
			destroyed = false,
		}
	end

	record.health = math.max(0, record.health - damage)

	if isGunPlacement(record.assetId) then
		local gunService = getGunBuildingService()
		if gunService and typeof((gunService :: any).ApplyDamage) == "function" then
			(gunService :: any).ApplyDamage(placementId, damage)
		end
	end

	local destroyed = record.health <= 0
	if destroyed then
		record.health = 0
		removePlacement(session, placementId, { store = false })
	else
		applyPlacementAttributes(record)
		updatePlacementHealthUi(record)
		placementUpdatePacket:Fire("HealthChanged", {
			id = placementId,
			remaining = record.health,
			maxHealth = record.maxHealth,
			destroyed = false,
		})
	end

	return true, {
		id = placementId,
		remaining = record.health,
		maxHealth = record.maxHealth,
		destroyed = destroyed,
	}
end

local function configureBrainrotTourismService()
	local success, service = pcall(require, BrainrotTourismServiceModule)
	if not success then
		warn("PlacementService failed to require BrainrotTourismService:", service)
		return
	end

	local setter = service :: any
	if typeof(setter) == "table" and typeof(setter.ConfigurePlacementService) == "function" then
		setter.ConfigurePlacementService({
			GetPlacementStateByEntity = getPlacementRecordByEntity,
			ApplyDamageToPlacement = applyPlacementDamage,
		})
	end
end

local function handleOfflineClaim(player: Player)
	local session = sessions[player]
	if not session or not session.profile or typeof(session.profile.Data) ~= "table" then
		return false, 0, 0, false, false, "Sesion no disponible"
	end

	local profileData = session.profile.Data
	local offlineState = session.offlineState or ensureOfflineState(profileData)
	session.offlineState = offlineState

	local rawAmount = math.max(0, tonumber(offlineState.pendingRaw) or 0)
	local baseAmount = math.max(0, math.min(tonumber(offlineState.pendingBase) or 0, rawAmount))
	offlineState.pendingRaw = rawAmount
	offlineState.pendingBase = baseAmount

	local hasPass = offlineState.hasGamepass == true
	local claimAmount = if hasPass then rawAmount else baseAmount

	--print(`{player.Name} solicitó claim; hasPass={hasPass}, base={baseAmount}, raw={rawAmount}`)

	local initialCanBuy = not hasPass and rawAmount > baseAmount and OFFLINE_GAMEPASS_ID > 0
	if claimAmount <= 0 then
		return false, baseAmount, rawAmount, hasPass, initialCanBuy, "Sin dinero offline para reclamar"
	end

	local credited = creditOfflineMoney(player, claimAmount)
	if not credited then
		warn(`No se pudo acreditar {claimAmount} a {player.Name}`)
		return false, baseAmount, rawAmount, hasPass, initialCanBuy, "No se pudo acreditar el dinero"
	end

	if hasPass then
		offlineState.pendingRaw = 0
		offlineState.pendingBase = 0
	else
		offlineState.pendingBase = math.max(offlineState.pendingBase - claimAmount, 0)
		offlineState.pendingRaw = math.max(offlineState.pendingRaw - claimAmount, 0)
	end

	offlineState.lastTimestamp = os.time()

	local remainingRaw = math.max(0, tonumber(offlineState.pendingRaw) or 0)
	local remainingBase = math.max(0, math.min(tonumber(offlineState.pendingBase) or 0, remainingRaw))
	offlineState.pendingRaw = remainingRaw
	offlineState.pendingBase = remainingBase

	local displayAmount = if hasPass then remainingRaw else remainingBase
	local canBuy = not hasPass and remainingRaw > remainingBase and OFFLINE_GAMEPASS_ID > 0

	--print(`{player.Name} reclamó {claimAmount}; base restante={remainingBase}, raw restante={remainingRaw}`)

	return true, displayAmount, remainingRaw, hasPass, canBuy, ""
end

OfflinePackets.Claim.OnServerInvoke = handleOfflineClaim

OfflinePackets.BuyGamepass.OnServerInvoke = function(player: Player)
	local session = sessions[player]
	if not session or not session.profile or typeof(session.profile.Data) ~= "table" then
		return false, "Sesion no disponible"
	end

	if OFFLINE_GAMEPASS_ID <= 0 then
		return false, "Compra no disponible"
	end

	local success, err = pcall(MarketplaceService.PromptGamePassPurchase, MarketplaceService, player, OFFLINE_GAMEPASS_ID)
	if not success then
		warn(`No se pudo iniciar la compra de gamepass offline para {player.Name}: {err}`)
		return false, "No se pudo iniciar la compra"
	end

	return true, ""
end

local function handlePlacementRequest(player: Player, assetId: string, position: Vector2, rotation: number, toolToken: string?)
	local session = sessions[player]
	if not session then
		return false, "Session not ready"
	end

	if typeof(assetId) ~= "string" then
		return false, "Invalid asset"
	end

	if typeof(position) ~= "Vector2" then
		return false, "Invalid position"
	end

	rotation = math.floor(rotation or 0) % 4

	local pendingPlacements = session.pendingPlacements or {}
	session.pendingPlacements = pendingPlacements
	local pendingKey = toolToken or assetId
	if pendingPlacements[pendingKey] then
		return false, "Herramienta en uso"
	end
	pendingPlacements[pendingKey] = true

	local function fail(message)
		pendingPlacements[pendingKey] = nil
		return false, message
	end

	local ok, assetDefResult = pcall(AssetRegistry.Get, assetId)
	if not ok then
		return fail("Unknown asset")
	end
	local assetDef = assetDefResult

	if not hasPlacementTool(player, assetId, toolToken) then
		return fail("Herramienta no disponible")
	end

	local orientedFootprint, cells = ensurePlacementCells(assetDef, position, rotation)

	if not Grid.isWithinBounds(session.slot:GetGridSize(), position, orientedFootprint) then
		return fail("Out of bounds")
	end

	local blockedCell, zoneId = findBlockedCell(session.blocking.cellsMap, cells)
	if blockedCell then
		return fail(`Locked zone ({zoneId})`)
	end

	local zoneOk, zoneMessage = ensureCellsWithinSingleZone(session.blocking, cells)
	if not zoneOk then
		return fail(zoneMessage or "Zona invalida")
	end

	if not PlacementWorld.IsAreaFree(session.plotEntity, cells) then
		return fail("Space occupied")
	end

	local profile = session.profile
	local profileData = profile and profile.Data

	local reusedEntry = nil
	local placementLevel = 1

	if typeof(profileData) == "table" then
		if toolToken then
			local mappedId = session.storedTokenMap[toolToken]
			if mappedId then
				reusedEntry = findStoredPlacementEntryById(profileData, mappedId)
				if not reusedEntry then
					session.storedTokenMap[toolToken] = nil
				end
			end

			if not reusedEntry then
				reusedEntry = findStoredPlacementEntryByToken(profileData, toolToken)
				if reusedEntry then
					session.storedTokenMap[toolToken] = reusedEntry.id
				end
			end
		end

		if not reusedEntry then
			reusedEntry = findStoredPlacementEntry(profileData, assetId)
		end

		if reusedEntry then
			local storedLevel = tonumber(reusedEntry.level)
			if storedLevel then
				placementLevel = math.max(placementLevel, math.max(1, math.floor(storedLevel + 0.5)))
			end
		else
			local storedCount = countStoredEntries(profileData, assetId)
			local inventoryEntry = PlacementInventory.GetEntry(profileData, assetId)
			if storedCount == 0 and inventoryEntry then
				local inventoryLevel = tonumber(inventoryEntry.level)
				if inventoryLevel then
					placementLevel = math.max(placementLevel, math.max(1, math.floor(inventoryLevel + 0.5)))
				end
			end
		end
	end

	local placementId = HttpService:GenerateGUID(false)
	if reusedEntry and typeof(reusedEntry.id) == "string" and reusedEntry.id ~= "" then
		placementId = reusedEntry.id
	else
		reusedEntry = nil
	end

	local placementData: PlacementData = {
		id = placementId,
		asset = assetId,
		position = position,
		rotation = rotation,
		cells = cells,
		level = placementLevel,
	}

	local accumulatedAmount = 0

	local model = spawnModel(session, assetDef, placementData, orientedFootprint)
	local uiHandle = nil
	local healthUi: PlacementHealthUi? = nil
	if model then
		model:SetAttribute("PlacementLevel", placementLevel)
		uiHandle, healthUi = attachBuildingUI(model, assetId, placementLevel, accumulatedAmount)
	end
	local placementEntity = PlacementWorld.CreatePlacement(session.plotEntity, placementData, model)
	local maxHealth = math.max(100, PlacementStats.GetMaxHealth(assetId, placementLevel))
	local placementHealth = maxHealth
	local initialGunState = nil

	if reusedEntry then
		local entryAny = reusedEntry :: any
		local storedMax = tonumber(entryAny.maxHealth)
		if storedMax then
			maxHealth = math.max(1, math.floor(storedMax + 0.5))
			placementHealth = maxHealth
		end

		local storedHealth = tonumber(entryAny.health)
		if storedHealth then
			placementHealth = math.clamp(math.floor(storedHealth + 0.5), 0, maxHealth)
		end

		local rawGunState = entryAny.gunState
		if typeof(rawGunState) == "table" then
			local ammoValue = rawGunState.ammo
			local reloadValue = rawGunState.reloadRemaining
			local cooldownValue = rawGunState.cooldownRemaining
			local stateHealth = rawGunState.health
			initialGunState = {
				ammo = if ammoValue ~= nil then tonumber(ammoValue) else nil,
				reloadRemaining = if reloadValue ~= nil then tonumber(reloadValue) else nil,
				cooldownRemaining = if cooldownValue ~= nil then tonumber(cooldownValue) else nil,
				health = math.clamp(math.floor((tonumber(stateHealth) or placementHealth) + 0.5), 0, maxHealth),
				disabled = rawGunState.disabled,
			}
		elseif placementHealth < maxHealth then
			initialGunState = {
				health = placementHealth,
			}
		end
	end

	local placementRecord: PlacementRecord = {
		entity = placementEntity,
		assetId = assetId,
		level = placementLevel,
		maxHealth = maxHealth,
		health = placementHealth,
		model = model,
		ui = healthUi,
	}
	attachPlacementModel(placementRecord, model)
	updatePlacementHealthUi(placementRecord)
	session.placements[placementData.id] = placementRecord
	placementsByEntity[placementEntity] = {
		session = session,
		id = placementData.id,
	}

	if reusedEntry then
		reusedEntry.id = placementData.id
		reusedEntry.asset = assetId
		reusedEntry.position = { x = position.X, y = position.Y }
		reusedEntry.rotation = rotation
		reusedEntry.level = placementLevel
		reusedEntry.stored = nil
		reusedEntry.token = nil
	else
		local profileEntry = placementDataToProfileEntry(placementData)
		table.insert(session.profile.Data.placement.objects, profileEntry)
	end

	clearStoredToken(session, toolToken)

	if model then
		PlacementEarnings.Register({
			entity = placementEntity,
			placementId = placementData.id,
			assetId = assetId,
			level = placementLevel,
			model = model,
			root = model.PrimaryPart,
			ownerUserId = session.ownerId,
			uiHandle = uiHandle,
			initialAccumulated = accumulatedAmount,
		})
		registerGunPlacement(session, placementEntity, placementData.id, assetId, placementLevel, model, initialGunState)
	end

	local serializedPlacement = serializePlacementForClient(placementData, placementRecord)
	placementUpdatePacket:FireClient(player, "Add", serializedPlacement)

	if not consumePlacementTool(player, assetId, toolToken) then
		warn(`No se encontro herramienta de placement "{assetId}" para {player.Name} al consumir`)
	else
		local adjustResult = PlacementInventory.Adjust(player, assetId, -1, placementLevel)
		if not adjustResult then
			warn(`No se pudo descontar "{assetId}" del inventario de placement para {player.Name}`)
		end
	end

	pendingPlacements[pendingKey] = nil

	return true, serializedPlacement
end

local function handlePlacementUpgrade(player: Player, placementId: string, method: string, payload: any)
	if typeof(placementId) ~= "string" then
		return false, "Placement invalido"
	end

	local session = sessions[player]
	if not session then
		return false, "Sesion no disponible"
	end

	if typeof(method) ~= "string" then
		return false, "Metodo invalido"
	end

	local normalized = string.upper(method)
	if normalized == "CURRENCY" then
		return handleCurrencyUpgrade(session, placementId)
	elseif normalized == "PRODUCT" then
		local productId = if payload then tonumber((payload :: any).productId) else nil
		if not productId or productId <= 0 then
			return false, "Producto invalido"
		end
		return handleProductUpgrade(session, placementId, productId)
	end

	return false, "Metodo invalido"
end

placementUpgradePacket.OnServerInvoke = handlePlacementUpgrade

placementRequestPacket.OnServerInvoke = handlePlacementRequest
zonePurchasePacket.OnServerInvoke = function(player: Player, zoneId)
	if typeof(zoneId) ~= "string" then
		return false, "Zona invalida"
	end

	local session = sessions[player]
	if not session then
		return false, "Sesion no disponible"
	end

	local zoneLookup = session.blocking.zoneLookup
	local zone = zoneLookup and zoneLookup[zoneId]
	if not zone then
		return false, "Zona desconocida"
	end

	if zone.locked == false then
		return false, "Zona ya desbloqueada"
	end

	local price = LockedZonePrices[zoneId]
	if typeof(price) ~= "number" then
		return false, "Precio no configurado"
	end

	local profileData = session.profile and session.profile.Data
	if not profileData then
		return false, "Perfil no disponible"
	end

	local currentMoney = profileData.Money
	if typeof(currentMoney) ~= "number" then
		return false, "Fondos invalidos"
	end

	if currentMoney < price then
		return false, "Fondos insuficientes"
	end

	profileData.Money = currentMoney - price

	local unlockedList = ensureUnlockList(session)
	ensureZoneRecorded(unlockedList, zoneId)
	zone.locked = false

	rebuildBlockingState(session)
	broadcastZoneState(session)

	return true, {
		zoneId = zoneId,
		price = price,
		money = profileData.Money,
	}
end

placementPickupPacket.OnServerInvoke = function(player: Player, placementId)
	if typeof(placementId) ~= "string" then
		return false, "Placement invalido"
	end

	local session = sessions[player]
	if not session then
		return false, "Sesion no disponible"
	end

	local success, result = removePlacement(session, placementId)
	if not success then
		return false, result
	end

	local successGrant, tokenOrMessage = grantPlacementTool(player, result.asset, result.id, result.level)
	if not successGrant then
		warn(`No se pudo devolver la herramienta "{result.asset}" a {player.Name} al recoger: {tokenOrMessage}`)
	else
		local toolToken = tokenOrMessage :: string
		local defaultLevel = math.max(1, tonumber(result.level) or 1)
		local adjustResult = PlacementInventory.Adjust(player, result.asset, 1, defaultLevel)
		if not adjustResult then
			warn(`No se pudo registrar la herramienta "{result.asset}" para {player.Name} al devolverla`)
		end

		return true, {
			placement = result,
			token = toolToken,
		}
	end

	return false, "No se pudo otorgar la herramienta"
end

configureBrainrotTourismService()

return {
	GetSession = function(player: Player): Session?
		return sessions[player]
	end,
	GrantPlacementTool = grantPlacementTool,
	GetPlacementStateByEntity = function(placementEntity: number)
		return getPlacementRecordByEntity(placementEntity)
	end,
	ApplyDamageToPlacement = applyPlacementDamage,
}
