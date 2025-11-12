-- !strict

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Profiles = require(ServerScriptService.Work.Modules.Profiles)
local RunServiceScheduler = require(ServerScriptService.Work.Modules.RunServiceScheduler)
local PlacementStats = require(script.Parent:WaitForChild("Stats"))
local PlacementWorld = require(script.Parent:WaitForChild("World"))

local world = PlacementWorld.World
local Components = PlacementWorld.Components

local PlacementEarnings = {}

local TICK_INTERVAL = 3

export type UIHandle = {
	ui: Instance?,
	accumulatedLabel: TextLabel?,
}

export type RegisterParams = {
	entity: number,
	placementId: string?,
	assetId: string,
	level: number,
	model: Model,
	root: BasePart?,
	ownerUserId: number,
	uiHandle: UIHandle?,
	initialAccumulated: number?,
}

type MetaState = {
	touchConnection: RBXScriptConnection?,
	modelDestroyConnection: RBXScriptConnection?,
	rootDestroyConnection: RBXScriptConnection?,
	claiming: boolean,
}

type SchedulerHandle = RunServiceScheduler.SchedulerHandle

local schedulerHandle: SchedulerHandle? = nil
local activeCount = 0

local placementsQuery = world
	:query(
		Components.PlacementMoneyRate,
		Components.PlacementAccumulated,
		Components.PlacementOwner,
		Components.PlacementModel,
		Components.PlacementRoot
	)
	:cached()

local function formatMoney(amount: number): string
	if math.abs(amount - math.round(amount)) < 0.001 then
		return string.format("%d", math.round(amount))
	end
	return string.format("%.2f", amount)
end

local function cleanupMeta(entity: number)
	local meta = world:get(entity, Components.PlacementEarningsMeta) :: MetaState?
	if not meta then
		return
	end

	if meta.touchConnection then
		meta.touchConnection:Disconnect()
		meta.touchConnection = nil
	end

	if meta.modelDestroyConnection then
		meta.modelDestroyConnection:Disconnect()
		meta.modelDestroyConnection = nil
	end

	if meta.rootDestroyConnection then
		meta.rootDestroyConnection:Disconnect()
		meta.rootDestroyConnection = nil
	end

	meta.claiming = false
end

local function stopScheduler()
	if schedulerHandle then
		RunServiceScheduler.unregister(schedulerHandle)
		schedulerHandle = nil
	end
end

local function ensureScheduler()
	if schedulerHandle then
		return
	end

	schedulerHandle = RunServiceScheduler.register(TICK_INTERVAL, function(totalDelta)
		if activeCount <= 0 then
			schedulerHandle = nil
			return false
		end

		if totalDelta > 0 then
			for entity, moneyRate, accumulated, _, model, root in placementsQuery do
				if not model.Parent or not root.Parent then
					PlacementEarnings.Unregister(entity)
				else
					local increment = moneyRate * totalDelta
					if increment > 0 then
						local newAmount = accumulated + increment
						world:set(entity, Components.PlacementAccumulated, newAmount)
						world:set(entity, Components.PlacementDisplayedAccumulated, -1)
						PlacementEarnings._updateLabel(entity)
					end
				end
			end
		end

		if activeCount <= 0 then
			schedulerHandle = nil
			return false
		end

		return nil
	end)
end

local function addMoneyToPlayer(player: Player, amount: number): boolean
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

local function updateActiveCount(wasRegistered: boolean, isRegistered: boolean)
	if not wasRegistered and isRegistered then
		activeCount += 1
		ensureScheduler()
	elseif wasRegistered and not isRegistered then
		activeCount -= 1
		if activeCount <= 0 then
			activeCount = 0
			stopScheduler()
		end
	end
end

local function ensureLabel(entity: number)
	local label = world:get(entity, Components.PlacementAccumulatedLabel)
	if not label or not label.Parent then
		world:remove(entity, Components.PlacementAccumulatedLabel)
		world:remove(entity, Components.PlacementDisplayedAccumulated)
		return nil
	end

	return label :: TextLabel
end

function PlacementEarnings._updateLabel(entity: number)
	local label = ensureLabel(entity)
	if not label then
		return
	end

	local amount = world:get(entity, Components.PlacementAccumulated)
	local numeric = tonumber(amount) or 0
	local displayed = world:get(entity, Components.PlacementDisplayedAccumulated)
	local displayedNumeric = if displayed ~= nil then tonumber(displayed) else nil

	if displayedNumeric and math.abs(numeric - displayedNumeric) < 0.001 then
		return
	end

	label.Text = formatMoney(numeric) .. " $"
	world:set(entity, Components.PlacementDisplayedAccumulated, numeric)
end

local function getRootPart(model: Model): BasePart?
	local root = model:FindFirstChild("RootPart")
	if root and root:IsA("BasePart") then
		return root
	end

	local primary = model.PrimaryPart
	if primary and primary:IsA("BasePart") then
		return primary
	end

	return model:FindFirstChildWhichIsA("BasePart")
end

local function handleRootTouched(entity: number, otherPart: BasePart)
	local meta = world:get(entity, Components.PlacementEarningsMeta) :: MetaState?
	if not meta or meta.claiming then
		return
	end

	local character = otherPart.Parent
	if not character or character.ClassName ~= "Model" then
		return
	end

	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return
	end

	local ownerId = world:get(entity, Components.PlacementOwner)
	if typeof(ownerId) ~= "number" or ownerId ~= player.UserId then
		return
	end

	local accumulated = world:get(entity, Components.PlacementAccumulated)
	local amount = tonumber(accumulated) or 0
	if amount <= 0 then
		return
	end

	meta.claiming = true
	local success = addMoneyToPlayer(player, amount)
	if success then
		world:set(entity, Components.PlacementAccumulated, 0)
		world:set(entity, Components.PlacementDisplayedAccumulated, -1)
		PlacementEarnings._updateLabel(entity)
	else
		warn(string.format("No se pudo otorgar dinero recogido al jugador %s", player.Name))
	end
	meta.claiming = false
end

function PlacementEarnings.Register(params: RegisterParams)
	if typeof(params) ~= "table" then
		return
	end

	local entity = params.entity
	if typeof(entity) ~= "number" then
		return
	end

	local ownerId = params.ownerUserId
	if typeof(ownerId) ~= "number" then
		return
	end

	local model = params.model
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return
	end

	local root = params.root
	if not root or not root:IsA("BasePart") then
		root = getRootPart(model)
	end
	if not root then
		return
	end

	local moneyPerSecond = PlacementStats.GetMoneyPerSecond(params.assetId, params.level)
	local wasRegistered = world:has(entity, Components.PlacementMoneyRate)

	cleanupMeta(entity)

	world:set(entity, Components.PlacementOwner, ownerId)
	world:set(entity, Components.PlacementMoneyRate, moneyPerSecond)
	world:set(entity, Components.PlacementAccumulated, math.max(0, params.initialAccumulated or 0))
	world:set(entity, Components.PlacementDisplayedAccumulated, -1)
	world:set(entity, Components.PlacementRoot, root)
	if params.uiHandle and params.uiHandle.accumulatedLabel then
		world:set(entity, Components.PlacementAccumulatedLabel, params.uiHandle.accumulatedLabel)
	else
		world:remove(entity, Components.PlacementAccumulatedLabel)
	end

	local meta: MetaState = {
		touchConnection = nil,
		modelDestroyConnection = nil,
		rootDestroyConnection = nil,
		claiming = false,
	}
	world:set(entity, Components.PlacementEarningsMeta, meta)

	root.CanTouch = true
	meta.touchConnection = root.Touched:Connect(function(otherPart)
		if otherPart and otherPart:IsA("BasePart") then
			handleRootTouched(entity, otherPart)
		end
	end)

	meta.modelDestroyConnection = model.Destroying:Connect(function()
		PlacementEarnings.Unregister(entity)
	end)

	meta.rootDestroyConnection = root.Destroying:Connect(function()
		PlacementEarnings.Unregister(entity)
	end)

	updateActiveCount(wasRegistered, true)
	PlacementEarnings._updateLabel(entity)
end

function PlacementEarnings.Unregister(entity: number)
	if typeof(entity) ~= "number" then
		return
	end

	local wasRegistered = world:has(entity, Components.PlacementMoneyRate)

	cleanupMeta(entity)
	world:remove(entity, Components.PlacementEarningsMeta)
	world:remove(entity, Components.PlacementAccumulatedLabel)
	world:remove(entity, Components.PlacementDisplayedAccumulated)
	world:remove(entity, Components.PlacementRoot)
	world:remove(entity, Components.PlacementMoneyRate)
	world:remove(entity, Components.PlacementAccumulated)
	world:remove(entity, Components.PlacementOwner)

	updateActiveCount(wasRegistered, false)
end

function PlacementEarnings.ApplyUpgrade(entity: number, newLevel: number, uiHandle: UIHandle?)
	if typeof(entity) ~= "number" then
		return 0, 0
	end

	local assetId = world:get(entity, Components.PlacementAsset)
	if typeof(assetId) ~= "string" or assetId == "" then
		return 0, 0
	end

	local level = math.max(1, newLevel)
	local moneyPerSecond = PlacementStats.GetMoneyPerSecond(assetId, level)
	world:set(entity, Components.PlacementMoneyRate, moneyPerSecond)

	if uiHandle and uiHandle.accumulatedLabel then
		world:set(entity, Components.PlacementAccumulatedLabel, uiHandle.accumulatedLabel)
	else
		world:remove(entity, Components.PlacementAccumulatedLabel)
	end

	world:set(entity, Components.PlacementDisplayedAccumulated, -1)
	PlacementEarnings._updateLabel(entity)

	local accumulated = world:get(entity, Components.PlacementAccumulated)
	return moneyPerSecond, tonumber(accumulated) or 0
end

function PlacementEarnings.GetAccumulated(entity: number): number
	if typeof(entity) ~= "number" then
		return 0
	end

	local amount = world:get(entity, Components.PlacementAccumulated)
	return tonumber(amount) or 0
end

return PlacementEarnings

