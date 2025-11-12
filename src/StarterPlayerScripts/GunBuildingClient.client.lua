--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local AmmoBuildingPackets = require(ReplicatedStorage:WaitForChild("Network"):WaitForChild("AmmoBuildingPackets"))
local AmmoBuildings = require(ReplicatedStorage:WaitForChild("Data"):WaitForChild("AmmoBuildings"))

local MIN_TRAVEL_TIME = 0.05
local MAX_TRAVEL_TIME = 3
local DEFAULT_PROJECTILE_SPEED = 150
local DEFAULT_RAYCAST_SIZE = Vector3.new(0.4, 0.4, 2)
local DEFAULT_RAYCAST_COLOR = Color3.fromRGB(240, 240, 240)
local DEFAULT_RAYCAST_TRANSPARENCY = 0.25

type ProjectileState = {
	origin: Vector3,
	direction: Vector3,
	speed: number,
	traveled: number,
	maxDistance: number,
	impactDistance: number,
	destroyOnImpact: boolean,
}

local projectileFolder: Folder? = nil
local activeProjectiles: {[BasePart]: ProjectileState} = {}

local function ensureProjectileFolder(): Folder
	local existing = projectileFolder
	if existing and existing.Parent then
		return existing
	end

	local found = Workspace:FindFirstChild("GunProjectiles")
	if found and found:IsA("Folder") then
		projectileFolder = found
	else
		local created = Instance.new("Folder")
		created.Name = "GunProjectiles"
		created.Parent = Workspace
		projectileFolder = created
	end

	return projectileFolder :: Folder
end


local function destroyProjectile(projectile: BasePart)
	activeProjectiles[projectile] = nil
	projectile:Destroy()
end

RunService.Heartbeat:Connect(function(deltaTime)
	if deltaTime <= 0 then
		return
	end

	if next(activeProjectiles) == nil then
		return
	end

	local toDestroy = table.create(4)

	for projectile, state in pairs(activeProjectiles) do
		if projectile.Parent == nil then
			toDestroy[#toDestroy + 1] = projectile
			continue
		end

		local previousTravel = state.traveled
		local newTravel = previousTravel + math.max(state.speed, 0) * deltaTime
		local clampedTravel = math.min(newTravel, state.maxDistance)
		state.traveled = clampedTravel

		local position = state.origin + state.direction * clampedTravel
		projectile.CFrame = CFrame.lookAt(position, position + state.direction)

		local reachedImpact = state.destroyOnImpact and previousTravel < state.impactDistance and newTravel >= state.impactDistance
		local reachedLimit = clampedTravel >= state.maxDistance

		if reachedImpact or reachedLimit then
			toDestroy[#toDestroy + 1] = projectile
		end
	end

	for _, projectile in ipairs(toDestroy) do
		if activeProjectiles[projectile] then
			destroyProjectile(projectile)
		else
			projectile:Destroy()
		end
	end
end)


local function resolveRaycastProperties(assetId: string, payload: {[string]: any})
	local size = payload.size
	local color = payload.color
	local transparencyValue = payload.transparency
	local transparency: number? = if typeof(transparencyValue) == "number" then transparencyValue else nil

	if typeof(size) ~= "Vector3" or typeof(color) ~= "Color3" or transparency == nil then
		local definition = AmmoBuildings[assetId]
		if typeof(definition) == "table" then
			local raycast = definition.raycast
			if typeof(raycast) == "table" then
				if typeof(size) ~= "Vector3" and typeof(raycast.Size) == "Vector3" then
					size = raycast.Size
				end
				if typeof(color) ~= "Color3" and typeof(raycast.Color) == "Color3" then
					color = raycast.Color
				end
				if transparency == nil and raycast.Transparency ~= nil then
					local numeric = tonumber(raycast.Transparency)
					if numeric then
						transparency = math.clamp(numeric, 0, 1)
					end
				end
			end
		end
	end

	local resolvedSize = if typeof(size) == "Vector3" then size else DEFAULT_RAYCAST_SIZE
	local resolvedColor = if typeof(color) == "Color3" then color else DEFAULT_RAYCAST_COLOR
	local resolvedTransparency = math.clamp(transparency or DEFAULT_RAYCAST_TRANSPARENCY, 0, 1)

	return resolvedSize, resolvedColor, resolvedTransparency
end

local function computeTravelTime(origin: Vector3, target: Vector3, provided: any): number
	local value = if typeof(provided) == "number" then provided else nil
	if value then
		return math.clamp(value, MIN_TRAVEL_TIME, MAX_TRAVEL_TIME)
	end

	local distance = (target - origin).Magnitude
	if distance <= 0 then
		return MIN_TRAVEL_TIME
	end

	return math.clamp(distance / DEFAULT_PROJECTILE_SPEED, MIN_TRAVEL_TIME, MAX_TRAVEL_TIME)
end

AmmoBuildingPackets.ProjectileFired.OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end

	local origin = payload.origin
	local target = payload.target
	if typeof(origin) ~= "Vector3" or typeof(target) ~= "Vector3" then
		return
	end

	local direction = target - origin
	local distance = direction.Magnitude
	if distance <= 0 then
		return
	end

	local assetIdValue = payload.assetId
	local assetId = if typeof(assetIdValue) == "string" then assetIdValue else ""

	local size, color, transparency = resolveRaycastProperties(assetId, payload)
	local travelTime = computeTravelTime(origin, target, payload.travelTime)
	local projectileSpeedValue = payload.projectileSpeed
	local projectileSpeed = if typeof(projectileSpeedValue) == "number" and projectileSpeedValue > 0 then projectileSpeedValue else distance / math.max(travelTime, MIN_TRAVEL_TIME)

	if projectileSpeed <= 0 then
		projectileSpeed = DEFAULT_PROJECTILE_SPEED
	elseif projectileSpeed > DEFAULT_PROJECTILE_SPEED * 4 then
		projectileSpeed = math.min(projectileSpeed, DEFAULT_PROJECTILE_SPEED * 4)
	end

	local rangeValue = payload.range
	local maxDistance = distance
	if typeof(rangeValue) == "number" and rangeValue > maxDistance then
		maxDistance = rangeValue
	end

	local hitExpectedValue = payload.hitExpected
	local destroyOnImpact = if typeof(hitExpectedValue) == "boolean" then hitExpectedValue else true
	local impactDistance = if destroyOnImpact then math.min(distance, maxDistance) else math.huge

	local directionUnit = direction.Unit

	local projectile = Instance.new("Part")
	projectile.Name = "GunProjectile"
	projectile.Anchored = true
	projectile.CanCollide = false
	projectile.CanTouch = false
	projectile.CanQuery = false
	projectile.Material = Enum.Material.Neon
	projectile.Size = size
	projectile.Color = color
	projectile.Transparency = transparency
	projectile.CastShadow = false
	projectile.CFrame = CFrame.lookAt(origin, origin + directionUnit)
	projectile.Parent = ensureProjectileFolder()

	activeProjectiles[projectile] = {
		origin = origin,
		direction = directionUnit,
		speed = projectileSpeed,
		traveled = 0,
		maxDistance = maxDistance,
		impactDistance = impactDistance,
		destroyOnImpact = destroyOnImpact,
	}
end)
