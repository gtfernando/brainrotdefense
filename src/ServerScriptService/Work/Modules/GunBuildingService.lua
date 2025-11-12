--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ModulesFolder = ServerScriptService:WaitForChild("Work"):WaitForChild("Modules")

local AmmoBuildings = require(ReplicatedStorage:WaitForChild("Data"):WaitForChild("AmmoBuildings"))
local AmmoBuildingPackets = require(ReplicatedStorage:WaitForChild("Network"):WaitForChild("AmmoBuildingPackets"))
local RunServiceScheduler = require(ModulesFolder:WaitForChild("RunServiceScheduler"))
local BrainrotTourismServiceModule = ModulesFolder:WaitForChild("BrainrotTourismService")
local InstanceUtils = require(ModulesFolder:WaitForChild("InstanceUtils"))
local tourismService: any = nil

local findFirstDescendant = InstanceUtils.findFirstDescendant

local function getBrainrotTourismService()
    if not tourismService then
        tourismService = require(BrainrotTourismServiceModule)
    end
    return tourismService
end

local GunBuildingService = {}

export type GunDefinition = {
    assetId: string,
    level: number,
    bullets: number,
    damage: number,
    cooldown: number,
    reloadTime: number,
    health: number,
    range: number,
    projectileSpeed: number,
    raycast: {
        Color: Color3,
        Size: Vector3,
        Transparency: number,
    },
}

type GunUiHandle = {
    container: Instance?,
    bullets: TextLabel?,
    healthLabel: TextLabel?,
    healthFill: Frame?,
}

export type GunState = {
    entity: number,
    placementId: string,
    assetId: string,
    definition: GunDefinition,
    level: number,
    ownerUserId: number?,
    slotIndex: number?,
    model: Model?,
    root: BasePart?,
    muzzle: BasePart?,
    ammo: number,
    reloadRemaining: number,
    cooldownRemaining: number,
    health: number,
    disabled: boolean,
    ui: GunUiHandle?,
    connections: { RBXScriptConnection },
}

type InitialGunState = {
    ammo: number?,
    reloadRemaining: number?,
    cooldownRemaining: number?,
    health: number?,
    disabled: boolean?,
}

type RegisterParams = {
    placementEntity: number,
    placementId: string,
    assetId: string,
    model: Model?,
    ownerUserId: number?,
    slotIndex: number?,
    level: number?,
 	initialState: InitialGunState?,
}

type SchedulerHandle = RunServiceScheduler.SchedulerHandle
type AgentState = "toBuilding" | "hidden" | "toSpawn"
type ActiveAgent = {
    id: string,
    position: Vector3,
    state: AgentState,
    targetEntity: number?,
    ownerUserId: number?,
}

local registerPlacement: (RegisterParams) -> ()
local unregisterPlacement: (number | string) -> ()
local applyDamage: (string, number) -> (boolean, number)
local getStateByPlacementId: (string) -> GunState?
local initService: () -> ()

local defCache: { [string]: { [number]: GunDefinition | false } } = {}
local activeByEntity: { [number]: GunState } = {}
local activeByPlacementId: { [string]: GunState } = {}
local schedulerHandle: SchedulerHandle? = nil
local gunUiTemplate: BillboardGui? = nil

local DEFAULT_COOLDOWN = 0.6
local DEFAULT_RELOAD = 3
local DEFAULT_DAMAGE = 10
local DEFAULT_BULLETS = 12
local DEFAULT_HEALTH = 100
local DEFAULT_RANGE = 120
local DEFAULT_PROJECTILE_SPEED = 150
local DEFAULT_RAYCAST_SIZE = Vector3.new(0.4, 0.4, 2)
local DEFAULT_RAYCAST_COLOR = Color3.fromRGB(240, 240, 240)
local DEFAULT_RAYCAST_TRANSPARENCY = 0.25
local MAX_TRAVEL_TIME = 3
local MIN_TRAVEL_TIME = 0.05
local UPDATE_INTERVAL = 0.1

local function ensureGunUiTemplate(): BillboardGui
    if gunUiTemplate and gunUiTemplate.Parent then
        return gunUiTemplate
    end

    local design = ReplicatedStorage:FindFirstChild("Design")
    local uiFolder = design and design:FindFirstChild("UIs")
    local candidate = uiFolder and uiFolder:FindFirstChild("GunBuildingsUI")
    if candidate and candidate:IsA("BillboardGui") then
        gunUiTemplate = candidate
        return candidate
    end

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "GunBuildingsUI"
    billboard.Size = UDim2.new(0, 140, 0, 70)
    billboard.AlwaysOnTop = true
    billboard.StudsOffset = Vector3.new(0, 6, 0)

    local frame = Instance.new("Frame")
    frame.Name = "Container"
    frame.Size = UDim2.fromScale(1, 1)
    frame.BackgroundColor3 = Color3.fromRGB(16, 16, 16)
    frame.BackgroundTransparency = 0.35
    frame.BorderSizePixel = 0
    frame.Parent = billboard

    local bulletsLabel = Instance.new("TextLabel")
    bulletsLabel.Name = "Bullets"
    bulletsLabel.BackgroundTransparency = 1
    bulletsLabel.Size = UDim2.new(1, -8, 0, 22)
    bulletsLabel.Position = UDim2.new(0, 4, 0, 4)
    bulletsLabel.Font = Enum.Font.GothamBold
    bulletsLabel.TextSize = 18
    bulletsLabel.TextColor3 = Color3.new(1, 1, 1)
    bulletsLabel.TextXAlignment = Enum.TextXAlignment.Left
    bulletsLabel.Text = "Balas: 0"
    bulletsLabel.Parent = frame

    local healthLabel = Instance.new("TextLabel")
    healthLabel.Name = "Health"
    healthLabel.BackgroundTransparency = 1
    healthLabel.Size = UDim2.new(1, -8, 0, 18)
    healthLabel.Position = UDim2.new(0, 4, 0, 32)
    healthLabel.Font = Enum.Font.GothamBold
    healthLabel.TextSize = 16
    healthLabel.TextColor3 = Color3.new(1, 1, 1)
    healthLabel.TextXAlignment = Enum.TextXAlignment.Left
    healthLabel.Text = "Vida"
    healthLabel.Parent = frame

    local barBg = Instance.new("Frame")
    barBg.Name = "HealthBar"
    barBg.Size = UDim2.new(1, -8, 0, 10)
    barBg.Position = UDim2.new(0, 4, 0, 52)
    barBg.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
    barBg.BorderSizePixel = 0
    barBg.Parent = frame

    local barFill = Instance.new("Frame")
    barFill.Name = "Fill"
    barFill.Size = UDim2.new(1, 0, 1, 0)
    barFill.BackgroundColor3 = Color3.fromRGB(60, 200, 80)
    barFill.BorderSizePixel = 0
    barFill.Parent = barBg

    gunUiTemplate = billboard
    return billboard
end

local function broadcastProjectile(state: GunState, origin: Vector3, targetPosition: Vector3, travelTime: number)
    AmmoBuildingPackets.ProjectileFired:Fire({
        id = state.placementId,
        assetId = state.assetId,
        origin = origin,
        target = targetPosition,
        travelTime = travelTime,
        range = state.definition.range,
        projectileSpeed = state.definition.projectileSpeed,
        hitExpected = true,
        size = state.definition.raycast.Size,
        color = state.definition.raycast.Color,
        transparency = state.definition.raycast.Transparency,
    })
end

local function resolveMuzzlePart(model: Model, fallback: BasePart): BasePart
    local gunModel = findFirstDescendant(model, "GunBuildingModel", nil)
    if gunModel and gunModel:IsA("Model") then
        local directShot = gunModel:FindFirstChild("ShotPart")
        if directShot and directShot:IsA("BasePart") then
            return directShot
        end

        local nestedShot = findFirstDescendant(gunModel, "ShotPart", "BasePart")
        if nestedShot and nestedShot:IsA("BasePart") then
            return nestedShot
        end
    end

    local shotPart = findFirstDescendant(model, "ShotPart", "BasePart")
    if shotPart and shotPart:IsA("BasePart") then
        return shotPart
    end

    local muzzleCandidate = findFirstDescendant(model, "Muzzle", "BasePart")
    if muzzleCandidate and muzzleCandidate:IsA("BasePart") then
        return muzzleCandidate
    end

    return fallback
end

local function normalizeLevelValue(value: any): number
    local numeric = tonumber(value)
    if not numeric then
        return 1
    end

    if numeric < 1 then
        numeric = 1
    end

    return math.floor(numeric + 0.5)
end

local function resolveGunLevelsTable(raw: { [string]: any }?): { [any]: any }?
    if typeof(raw) ~= "table" then
        return nil
    end

    local levels = raw.Level or raw.level or raw.Levels or raw.levels
    if typeof(levels) ~= "table" then
        return nil
    end

    return levels
end

local function resolveGunLevelEntry(raw: { [string]: any }?, requestedLevel: number): ({ [string]: any }?, number?)
    local levels = resolveGunLevelsTable(raw)
    if not levels then
        return nil, nil
    end

    local direct = levels[requestedLevel]
    if typeof(direct) == "table" then
        return direct, requestedLevel
    end

    local stringEntry = levels[tostring(requestedLevel)]
    if typeof(stringEntry) == "table" then
        return stringEntry, requestedLevel
    end

    local bestEntry = nil
    local bestLevel = nil
    local higherEntry = nil
    local higherLevel = nil

    for key, value in levels do
        if typeof(value) == "table" then
            local numeric = if typeof(key) == "number" then key else tonumber(key)
            if numeric then
                if numeric <= requestedLevel then
                    if not bestLevel or numeric > bestLevel then
                        bestLevel = numeric
                        bestEntry = value
                    end
                elseif not higherLevel or numeric < higherLevel then
                    higherLevel = numeric
                    higherEntry = value
                end
            end
        end
    end

    if bestEntry then
        return bestEntry, bestLevel
    end

    if higherEntry then
        return higherEntry, higherLevel
    end

    return nil, nil
end

local function pickLevelStat(base: { [string]: any }?, levelEntry: { [string]: any }?, statName: string, defaultValue: any)
    if levelEntry then
        local stats = levelEntry.Stats
        if typeof(stats) == "table" and stats[statName] ~= nil then
            return stats[statName]
        end

        if levelEntry[statName] ~= nil then
            return levelEntry[statName]
        end
    end

    if base and base[statName] ~= nil then
        return base[statName]
    end

    return defaultValue
end

local function resolveRaycastProperties(base: { [string]: any }?, levelEntry: { [string]: any }?): { [string]: any }?
    local combined: { [string]: any } = {}

    local function merge(source: any)
        if typeof(source) ~= "table" then
            return
        end
        for key, value in source do
            combined[key] = value
        end
    end

    if base then
        merge(base.raycast)
    end

    if levelEntry then
        local stats = levelEntry.Stats
        if typeof(stats) == "table" then
            merge(stats.raycast)
        end
        merge(levelEntry.raycast)
    end

    if next(combined) == nil then
        return nil
    end

    return combined
end

local function coerceNumber(value: any, defaultValue: number): number
    local numeric = tonumber(value)
    if not numeric then
        return defaultValue
    end
    return numeric
end

local function normalizeDefinition(assetId: string, level: number?): GunDefinition?
    local requestedLevel = normalizeLevelValue(level or 1)

    local cacheForAsset = defCache[assetId]
    if not cacheForAsset then
        cacheForAsset = {}
        defCache[assetId] = cacheForAsset
    else
        local cached = cacheForAsset[requestedLevel]
        if cached ~= nil then
            if cached == false then
                return nil
            end
            return cached :: GunDefinition
        end
    end

    local raw = AmmoBuildings[assetId]
    if typeof(raw) ~= "table" then
        cacheForAsset[requestedLevel] = false
        return nil
    end

    local levelEntry, resolvedLevel = resolveGunLevelEntry(raw, requestedLevel)

    local bullets = math.max(1, math.floor(coerceNumber(pickLevelStat(raw, levelEntry, "bullets", DEFAULT_BULLETS), DEFAULT_BULLETS)))
    local damageSource = pickLevelStat(raw, levelEntry, "dmg", pickLevelStat(raw, levelEntry, "damage", DEFAULT_DAMAGE))
    local damage = math.max(1, math.floor(coerceNumber(damageSource, DEFAULT_DAMAGE)))
    local cooldown = math.max(0.05, coerceNumber(pickLevelStat(raw, levelEntry, "cooldown", DEFAULT_COOLDOWN), DEFAULT_COOLDOWN))
    local reloadTime = math.max(0.1, coerceNumber(pickLevelStat(raw, levelEntry, "reloadTime", DEFAULT_RELOAD), DEFAULT_RELOAD))
    local health = math.max(1, math.floor(coerceNumber(pickLevelStat(raw, levelEntry, "health", DEFAULT_HEALTH), DEFAULT_HEALTH)))
    local range = math.max(8, coerceNumber(pickLevelStat(raw, levelEntry, "range", DEFAULT_RANGE), DEFAULT_RANGE))
    local projectileSpeed = math.max(10, coerceNumber(pickLevelStat(raw, levelEntry, "projectileSpeed", DEFAULT_PROJECTILE_SPEED), DEFAULT_PROJECTILE_SPEED))

    local raycastSource = resolveRaycastProperties(raw, levelEntry)
    local rayColor = DEFAULT_RAYCAST_COLOR
    local raySize = DEFAULT_RAYCAST_SIZE
    local rayTransparency = DEFAULT_RAYCAST_TRANSPARENCY

    if typeof(raycastSource) == "table" then
        local colorCandidate = raycastSource.Color or raycastSource.color
        if typeof(colorCandidate) == "Color3" then
            rayColor = colorCandidate
        end

        local sizeCandidate = raycastSource.Size or raycastSource.size
        if typeof(sizeCandidate) == "Vector3" then
            raySize = sizeCandidate
        end

        local transparencyCandidate = raycastSource.Transparency or raycastSource.transparency
        if transparencyCandidate ~= nil then
            rayTransparency = math.clamp(tonumber(transparencyCandidate) or rayTransparency, 0, 1)
        end
    end

    local definition: GunDefinition = {
        assetId = assetId,
        level = resolvedLevel or requestedLevel,
        bullets = bullets,
        damage = damage,
        cooldown = cooldown,
        reloadTime = reloadTime,
        health = health,
        range = range,
        projectileSpeed = projectileSpeed,
        raycast = {
            Color = rayColor,
            Size = raySize,
            Transparency = rayTransparency,
        },
    }

    cacheForAsset[requestedLevel] = definition
    return definition
end

local function updateGunUi(state: GunState)
    local ui = state.ui
    if not ui then
        return
    end

    if ui.bullets then
        local ammoText = string.format("Balas: %d", math.max(0, state.ammo))
        if state.reloadRemaining > 0 then
            ammoText ..= " (recargando)"
        end
        ui.bullets.Text = ammoText
    end

    if ui.healthLabel then
        local maxHealth = math.max(1, state.definition.health)
        local clamped = math.clamp(state.health, 0, maxHealth)
        ui.healthLabel.Text = string.format("Vida: %d/%d", math.floor(clamped + 0.5), maxHealth)
    end

    if ui.healthFill then
        local maxHealth = math.max(1, state.definition.health)
        local ratio = math.clamp(state.health / maxHealth, 0, 1)
        ui.healthFill.Size = UDim2.new(ratio, 0, 1, 0)
        if ratio <= 0.15 then
            ui.healthFill.BackgroundColor3 = Color3.fromRGB(220, 70, 60)
        elseif ratio <= 0.45 then
            ui.healthFill.BackgroundColor3 = Color3.fromRGB(235, 170, 60)
        else
            ui.healthFill.BackgroundColor3 = Color3.fromRGB(60, 200, 80)
        end
    end
end

local function attachUi(state: GunState)
    local model = state.model
    if not model then
        return
    end

    local template = ensureGunUiTemplate()
    local uiHandle = template:Clone()
    local root = state.root

    if uiHandle:IsA("BillboardGui") then
        if root and (root:IsA("BasePart") or root:IsA("Attachment")) then
            uiHandle.Adornee = root
        elseif model.PrimaryPart then
            uiHandle.Adornee = model.PrimaryPart
        else
            local firstPart = model:FindFirstChildWhichIsA("BasePart", true)
            if firstPart then
                uiHandle.Adornee = firstPart
            else
                uiHandle:Destroy()
                return
            end
        end
    end

    uiHandle.Parent = model

    state.ui = {
        container = uiHandle :: Instance,
        bullets = findFirstDescendant(uiHandle, "Bullets", "TextLabel") :: TextLabel?,
        healthLabel = findFirstDescendant(uiHandle, "Health", "TextLabel") :: TextLabel?,
        healthFill = findFirstDescendant(uiHandle, "Fill", "Frame") :: Frame?,
    }

    updateGunUi(state)
end

local function detachUi(state: GunState)
    local ui = state.ui
    if not ui then
        return
    end

    state.ui = nil
    local container = ui.container
    if container and container.Parent then
        container:Destroy()
    end
end

local function cleanupConnections(state: GunState)
    for _, connection in ipairs(state.connections) do
        if connection.Connected then
            connection:Disconnect()
        end
    end

    state.connections = {}
end

local function cleanupSchedulerIfIdle()
    if next(activeByEntity) ~= nil then
        return
    end

    if schedulerHandle then
        RunServiceScheduler.unregister(schedulerHandle)
        schedulerHandle = nil
    end
end

local function acquireTarget(state: GunState): ActiveAgent?
    local slotIndex = state.slotIndex
    local root = state.muzzle or state.root
    if not slotIndex or not root then
        return nil
    end

    local service = getBrainrotTourismService()
    local agents = service.GetActiveAgentsForPlot(slotIndex)
    if #agents == 0 then
        return nil
    end

    local origin = root.Position
    local bestAgent: ActiveAgent? = nil
    local bestDistance = math.huge

    for _, agent in ipairs(agents) do
        local distance = (agent.position - origin).Magnitude
        if distance <= state.definition.range then
            if not bestAgent or distance < bestDistance then
                bestAgent = agent
                bestDistance = distance
            end
        end
    end

    return bestAgent
end

local function fireAtTarget(state: GunState, agent: ActiveAgent): boolean
    local root = state.muzzle or state.root
    if not root then
        return false
    end

    local origin = root.Position
    local targetPosition = agent.position
    local direction = targetPosition - origin
    local distance = direction.Magnitude
    if distance <= 0 then
        return false
    end

    local travelTime = math.clamp(distance / state.definition.projectileSpeed, MIN_TRAVEL_TIME, MAX_TRAVEL_TIME)
    broadcastProjectile(state, origin, targetPosition, travelTime)

    local targetId = agent.id
    local projectileDamage = math.max(1, math.floor((state.definition.damage or DEFAULT_DAMAGE) + 0.5))
    task.delay(travelTime, function()
        local service = getBrainrotTourismService()
        if not service then
            return
        end

        local applyDamage = (service :: any).ApplyDamage
        if typeof(applyDamage) == "function" then
            local success, _ = applyDamage(targetId, projectileDamage, {
                placementId = state.placementId,
                assetId = state.assetId,
                ownerUserId = state.ownerUserId,
            })
            if success then
                return
            end
        end

        local removeAgent = (service :: any).RemoveAgent
        if typeof(removeAgent) == "function" then
            removeAgent(targetId, "GunHit")
        end
    end)

    return true
end

local function stepGun(state: GunState, delta: number)
    if state.disabled then
        return
    end

    if state.reloadRemaining > 0 then
        state.reloadRemaining = math.max(0, state.reloadRemaining - delta)
        if state.reloadRemaining == 0 then
            state.ammo = state.definition.bullets
            updateGunUi(state)
        end
    end

    if state.cooldownRemaining > 0 then
        state.cooldownRemaining = math.max(0, state.cooldownRemaining - delta)
    end

    if state.reloadRemaining > 0 or state.cooldownRemaining > 0 then
        return
    end

    if state.ammo <= 0 then
        state.reloadRemaining = state.definition.reloadTime
        updateGunUi(state)
        return
    end

    local target = acquireTarget(state)
    if not target then
        return
    end

    if fireAtTarget(state, target) then
        state.ammo -= 1
        if state.ammo <= 0 then
            state.ammo = 0
            state.reloadRemaining = state.definition.reloadTime
        end
        state.cooldownRemaining = state.definition.cooldown
        updateGunUi(state)
    end
end

local function tickGuns(totalDelta: number, ticks: number)
    if next(activeByEntity) == nil then
        return
    end

    local steps = math.max(1, math.floor(ticks + 0.5))
    local stepDelta = totalDelta / steps

    for _, state in pairs(activeByEntity) do
        for _ = 1, steps do
            stepGun(state, stepDelta)
        end
    end

    cleanupSchedulerIfIdle()
end

local function ensureScheduler()
    if schedulerHandle then
        return
    end

    schedulerHandle = RunServiceScheduler.register(UPDATE_INTERVAL, tickGuns)
end

unregisterPlacement = function(placementEntityOrId: number | string)
    local state: GunState? = nil
    if typeof(placementEntityOrId) == "number" then
        state = activeByEntity[placementEntityOrId]
    else
        state = activeByPlacementId[placementEntityOrId]
    end

    if not state then
        return
    end

    activeByEntity[state.entity] = nil
    activeByPlacementId[state.placementId] = nil

    cleanupConnections(state)
    detachUi(state)

    cleanupSchedulerIfIdle()
end

registerPlacement = function(params: RegisterParams)
    local definition = normalizeDefinition(params.assetId, params.level)
    if not definition then
        return
    end

    local entity = params.placementEntity
    if activeByEntity[entity] then
        unregisterPlacement(entity)
    end

    local model = params.model
    if not model then
        return
    end

    local root = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
    if not root then
        return
    end

    local muzzle = resolveMuzzlePart(model, root)

    local resolvedLevel = definition.level or normalizeLevelValue(params.level or 1)

    local state: GunState = {
        entity = entity,
        placementId = params.placementId,
        assetId = params.assetId,
        definition = definition,
        level = resolvedLevel,
        ownerUserId = params.ownerUserId,
        slotIndex = params.slotIndex,
        model = model,
        root = root,
        muzzle = muzzle,
        ammo = definition.bullets,
        reloadRemaining = 0,
        cooldownRemaining = 0,
        health = definition.health,
        disabled = false,
        ui = nil,
        connections = {},
    }

    activeByEntity[entity] = state
    activeByPlacementId[state.placementId] = state

    local initial = params.initialState
    if typeof(initial) == "table" then
        local ammoValue = tonumber(initial.ammo)
        if ammoValue then
            state.ammo = math.clamp(math.floor(ammoValue + 0.5), 0, definition.bullets)
        end

        local reloadValue = tonumber(initial.reloadRemaining)
        if reloadValue then
            state.reloadRemaining = math.max(0, reloadValue)
        end

        local cooldownValue = tonumber(initial.cooldownRemaining)
        if cooldownValue then
            state.cooldownRemaining = math.max(0, cooldownValue)
        end

        local healthValue = tonumber(initial.health)
        if healthValue then
            state.health = math.clamp(math.floor(healthValue + 0.5), 0, definition.health)
        end

        if initial.disabled ~= nil then
            state.disabled = initial.disabled == true
        elseif state.health <= 0 then
            state.disabled = true
        end
    end

    attachUi(state)
    updateGunUi(state)
    ensureScheduler()

    table.insert(state.connections, model.AncestryChanged:Connect(function(_, newParent)
        if newParent == nil then
            unregisterPlacement(entity)
        end
    end))

    table.insert(state.connections, model.Destroying:Connect(function()
        unregisterPlacement(entity)
    end))
end

applyDamage = function(placementId: string, amount: number): (boolean, number)
    local state = activeByPlacementId[placementId]
    if not state then
        return false, 0
    end

    if state.disabled then
        return true, math.max(0, state.health)
    end

    local damage = math.max(0, tonumber(amount) or 0)
    if damage <= 0 then
        return true, state.health
    end

    state.health -= damage
    if state.health <= 0 then
        state.health = 0
        state.disabled = true
        detachUi(state)
    else
        updateGunUi(state)
    end

    return true, state.health
end

getStateByPlacementId = function(placementId: string): GunState?
    return activeByPlacementId[placementId]
end

initService = function()
end

GunBuildingService.RegisterPlacement = registerPlacement
GunBuildingService.UnregisterPlacement = unregisterPlacement
GunBuildingService.ApplyDamage = applyDamage
GunBuildingService.GetStateByPlacementId = getStateByPlacementId
GunBuildingService.Init = initService

return GunBuildingService
