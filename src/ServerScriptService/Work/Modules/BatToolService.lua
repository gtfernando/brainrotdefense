--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local ModulesFolder = script.Parent :: Folder
local WorkFolder = ModulesFolder.Parent :: Instance
local PlacementFolder = (WorkFolder:WaitForChild("Placement") :: Folder)
local StoresFolder = (WorkFolder:WaitForChild("Stores") :: Folder)
local NetworkFolder = ReplicatedStorage:WaitForChild("Network") :: Folder

local BrainrotTourismServiceModule = ModulesFolder:WaitForChild("BrainrotTourismService") :: ModuleScript
local PlotRegistryModule = PlacementFolder:WaitForChild("PlotRegistry") :: ModuleScript
local BatToolPacketsModule = NetworkFolder:WaitForChild("BatToolPackets") :: ModuleScript
local ChestServiceModule = StoresFolder:WaitForChild("ChestService") :: ModuleScript
local CrateTopoServiceModule = ModulesFolder:WaitForChild("CrateTopoService") :: ModuleScript

local BrainrotTourismService = require(BrainrotTourismServiceModule) :: any
local PlotRegistry = require(PlotRegistryModule) :: any
local BatToolPackets = require(BatToolPacketsModule) :: any
local ChestService = require(ChestServiceModule) :: any
local CrateTopoService = require(CrateTopoServiceModule) :: any

local BatToolService = {}

local DETECTION_DURATION = 0.25
local HITBOX_SIZE = Vector3.new(6, 6, 6)
local HITBOX_HALF_SIZE = HITBOX_SIZE * 0.5
local HITBOX_MARGIN = 0.75
local HITBOX_OFFSET = Vector3.new(0, 0, -3)
local MAX_DETECTION_RADIUS = HITBOX_HALF_SIZE.Magnitude + 4
local DAMAGE_MIN = 10
local DAMAGE_MAX = 18

type AgentDetail = { [string]: any }

local detectConnection: any = nil
local damageRng = Random.new()

local function shallowCopy(source: { [string]: any }): { [string]: any }
	local copy = {}
	for key, value in pairs(source) do
		copy[key] = value
	end
	return copy
end

local function asVector3(value: any): Vector3?
	if typeof(value) == "Vector3" then
		return value
	end
	return nil
end

local DetectionSession = {}
DetectionSession.__index = DetectionSession

function DetectionSession.new(player: Player)
	local self = setmetatable({}, DetectionSession)
	self.player = player
	self.character = player.Character

	local rootCandidate = if self.character then self.character:FindFirstChild("HumanoidRootPart") else nil
	self.humanoidRoot = if rootCandidate and rootCandidate:IsA("BasePart") then rootCandidate else nil

	local humanoidCandidate = if self.character then self.character:FindFirstChildOfClass("Humanoid") else nil
	self.humanoid = humanoidCandidate

	return self
end

function DetectionSession:isValid(): boolean
	if not self.player.Parent then
		return false
	end

	if not self.character or not self.humanoidRoot then
		return false
	end

	if not self.humanoid or self.humanoid.Health <= 0 then
		return false
	end

	return true
end

function DetectionSession:getDetectionCFrame(): CFrame
	local root = self.humanoidRoot
	if not root then
		error("HumanoidRootPart missing")
	end

	local baseRoot = root :: BasePart
	return baseRoot.CFrame * CFrame.new(HITBOX_OFFSET)
end

function DetectionSession:spawnHitbox()
	local character = self.character
	local root = self.humanoidRoot
	if not character or not root then
		return
	end

	local hitbox = Instance.new("Part")
	hitbox.Name = "BatDetectionHitbox"
	hitbox.Size = HITBOX_SIZE
	hitbox.Material = Enum.Material.ForceField
	hitbox.Transparency = 0
	hitbox.CanCollide = false
	hitbox.CanTouch = false
	hitbox.CanQuery = false
	hitbox.Massless = true
	hitbox.Anchored = false
	local rootBase = root :: BasePart
	local offsetCFrame = CFrame.new(HITBOX_OFFSET)
	hitbox.CFrame = rootBase.CFrame * offsetCFrame
	hitbox.Parent = character

	local weld = Instance.new("WeldConstraint")
	weld.Name = "BatDetectionWeld"
	weld.Part0 = rootBase
	weld.Part1 = hitbox
	weld.Parent = hitbox

	Debris:AddItem(hitbox, DETECTION_DURATION)
end

local function buildResultPayload(
	player: Player,
	agents: { { [string]: any } },
	detectionCFrame: CFrame,
	plotIndex: number?,
	diagnostics: { [string]: any }?
): { [string]: any }
	local resolvedPlotIndex = plotIndex
	if resolvedPlotIndex == nil then
		local slot = PlotRegistry.GetAssigned(player.UserId)
		resolvedPlotIndex = if slot then (slot :: any).index else nil
	end

	return {
		success = #agents > 0,
		agents = agents,
		center = detectionCFrame.Position,
		size = HITBOX_SIZE,
		offset = HITBOX_OFFSET,
		plotIndex = resolvedPlotIndex,
		timestamp = os.clock(),
		diagnostics = diagnostics,
	}
end

function DetectionSession:execute()
	if not self:isValid() then
		BatToolPackets.DetectResult:FireClient(self.player, {
			success = false,
			reason = "CharacterUnavailable",
		})
		return
	end

	local assignedSlot = PlotRegistry.GetAssigned(self.player.UserId)
	local slotIndex = if assignedSlot then (assignedSlot :: any).index else nil

	self:spawnHitbox()

	local detectionCFrame = self:getDetectionCFrame()
	local halfSize = Vector3.new(
		HITBOX_HALF_SIZE.X + HITBOX_MARGIN,
		HITBOX_HALF_SIZE.Y + HITBOX_MARGIN,
		HITBOX_HALF_SIZE.Z + HITBOX_MARGIN
	)
	local sphereRadius = math.min(MAX_DETECTION_RADIUS, math.max(halfSize.X, halfSize.Z))
	local maxHorizontalRange = math.max(halfSize.X, halfSize.Z)
	local rejections = {}
	local damageAppliedCount = 0
	local function computeClosest(detail: AgentDetail?): (number?, Vector3?, string?)
		if typeof(detail) ~= "table" then
			return nil, nil, nil
		end

		local closestDistance: number? = nil
		local closestRelative: Vector3? = nil
		local closestKey: string? = nil

		local function evaluate(key: string, worldPoint: any)
			if typeof(worldPoint) ~= "Vector3" then
				return
			end

			local castPoint: Vector3 = worldPoint :: Vector3
			local delta: Vector3 = castPoint - detectionCFrame.Position
			local distance = delta.Magnitude
			if not closestDistance or distance < closestDistance then
				closestDistance = distance
				closestRelative = detectionCFrame:PointToObjectSpace(castPoint)
				closestKey = key
			end
		end

		evaluate("position", detail.position)
		evaluate("target", detail.targetPosition)
		evaluate("anchor", detail.attackAnchor)

		return closestDistance, closestRelative, closestKey
	end

	local function recordRejection(detail: AgentDetail?, reason: string)
		if not detail then
			return
		end
		if #rejections >= 5 then
			return
		end
		local distance, relative, key = computeClosest(detail)
		rejections[#rejections + 1] = {
			id = detail.id,
			reason = reason,
			distance = distance,
			relative = relative,
			reference = key,
		}
	end

	local function evaluatePoint(point: Vector3?, pointKind: string): (Vector3?, string?)
		if typeof(point) ~= "Vector3" then
			return nil, nil
		end

		local castPoint: Vector3 = point :: Vector3
		local relative = (detectionCFrame:PointToObjectSpace(castPoint)) :: Vector3
		if math.abs(relative.X) <= halfSize.X
			and math.abs(relative.Y) <= halfSize.Y
			and math.abs(relative.Z) <= halfSize.Z
		then
			return relative, pointKind .. ":box"
		end

		local horizontalDistance = math.sqrt(relative.X * relative.X + relative.Z * relative.Z)
		if horizontalDistance <= maxHorizontalRange and math.abs(relative.Y) <= halfSize.Y then
			return relative, pointKind .. ":cylinder"
		end

		return nil, nil
	end

	local function evaluateCandidate(detail: AgentDetail): (AgentDetail?, string?)
		local position = detail.position
		local targetPosition = detail.targetPosition
		local anchorPosition = detail.attackAnchor
		local extents = asVector3(detail.extents)

		local positionVector = asVector3(position)
		local centerRelative: Vector3? = nil
		if positionVector then
			centerRelative = (detectionCFrame:PointToObjectSpace(positionVector)) :: Vector3
		end

		local checkpoints = {
			{ key = "position", point = position },
			{ key = "target", point = targetPosition },
			{ key = "anchor", point = anchorPosition },
		}

		local relative: Vector3? = nil
		local hitKind: string? = nil
		local referencePoint: Vector3? = nil

		if centerRelative and extents and positionVector then
			local overlap = math.abs(centerRelative.X) <= (halfSize.X + extents.X)
				and math.abs(centerRelative.Y) <= (halfSize.Y + extents.Y)
				and math.abs(centerRelative.Z) <= (halfSize.Z + extents.Z)
			if overlap then
				relative = Vector3.new(
					math.clamp(centerRelative.X, -halfSize.X, halfSize.X),
					math.clamp(centerRelative.Y, -halfSize.Y, halfSize.Y),
					math.clamp(centerRelative.Z, -halfSize.Z, halfSize.Z)
				)
				hitKind = "extents:overlap"
				referencePoint = positionVector
			end
		end

		for _, entry in ipairs(checkpoints) do
			local candidateRelative, candidateKind = evaluatePoint(entry.point, entry.key)
			if candidateRelative then
				relative = candidateRelative
				hitKind = candidateKind
				if typeof(entry.point) == "Vector3" then
					referencePoint = entry.point :: Vector3
				end
				break
			end
		end

		if not relative then
			for _, entry in ipairs(checkpoints) do
				if typeof(entry.point) == "Vector3" then
					local castPoint: Vector3 = entry.point :: Vector3
					local fallbackRelative = (detectionCFrame:PointToObjectSpace(castPoint)) :: Vector3
					if fallbackRelative.Magnitude <= sphereRadius then
						relative = fallbackRelative
						hitKind = entry.key .. ":sphere"
						referencePoint = castPoint
						break
					end
				end
			end
		end

		if not relative and centerRelative then
			local radius = if extents then extents.Magnitude else 0

			if centerRelative.Magnitude <= sphereRadius + radius then
				relative = Vector3.new(
					math.clamp(centerRelative.X, -halfSize.X, halfSize.X),
					math.clamp(centerRelative.Y, -halfSize.Y, halfSize.Y),
					math.clamp(centerRelative.Z, -halfSize.Z, halfSize.Z)
				)
				hitKind = "extents:sphere"
				referencePoint = positionVector or referencePoint
			end
		end

		if not relative then
			return nil, "out_of_range"
		end

		local copy = shallowCopy(detail)
		copy.relativePosition = relative
		local referenceVector: Vector3? = referencePoint or (typeof(detail.position) == "Vector3" and detail.position :: Vector3 or nil)
		if referenceVector then
			copy.distanceFromCenter = (referenceVector - detectionCFrame.Position).Magnitude
		else
			copy.distanceFromCenter = relative.Magnitude
		end
		copy.hitContext = hitKind
		return copy, nil
	end

	local candidates: { AgentDetail } = {}
	local seen: { [string]: boolean } = {}

	local function push(detail: AgentDetail?): boolean
		if typeof(detail) ~= "table" then
			return false
		end

		local identifier = detail.id
		if identifier and seen[identifier] then
			return false
		end

		if identifier then
			seen[identifier] = true
		end

		candidates[#candidates + 1] = detail
		return true
	end

	local ownerCandidateCount = 0
	for _, detail in ipairs(BrainrotTourismService.GetAgentsForOwner(self.player.UserId)) do
		if push(detail) then
			ownerCandidateCount += 1
		end
	end

	local plotCandidateCount = 0
	if slotIndex then
		for _, summary in ipairs(BrainrotTourismService.GetActiveAgentsForPlot(slotIndex)) do
			local summaryId = summary.id
			if summaryId and not seen[summaryId] then
				local detail = BrainrotTourismService.GetAgentDetails(summaryId)
				if push(detail) then
					plotCandidateCount += 1
				end
			end
		end
	end

	local fallbackCandidateCount = 0
	local fallbackSearchSize = Vector3.new(
		math.max(HITBOX_SIZE.X, sphereRadius * 2),
		math.max(HITBOX_SIZE.Y, sphereRadius * 2),
		math.max(HITBOX_SIZE.Z, sphereRadius * 2)
	)
	for _, detail in ipairs(BrainrotTourismService.GetAgentsInBox(detectionCFrame, fallbackSearchSize)) do
		if push(detail) then
			fallbackCandidateCount += 1
		end
	end

	local chestCandidateCount = 0
	for _, detail in ipairs(ChestService.GetChestTargetsForOwner(self.player.UserId)) do
		if push(detail) then
			chestCandidateCount += 1
		end
	end

	local crateCandidateCount = 0
	for _, detail in ipairs(CrateTopoService.GetCrateTargetsForOwner(self.player.UserId)) do
		if push(detail) then
			crateCandidateCount += 1
		end
	end

	local detected: { AgentDetail } = {}
	for _, detail in ipairs(candidates) do
		local copy, rejection = evaluateCandidate(detail)
		if copy then
			local targetKind = tostring(copy.targetKind or detail.targetKind or "Brainrot")
			copy.targetKind = targetKind

			local damageAmount = damageRng:NextInteger(DAMAGE_MIN, DAMAGE_MAX)
			local damageSuccess = false
			local remainingHealth = nil
			local appliedDamage = 0
			local extras: { [string]: any }? = nil
			if damageAmount > 0 then
				if targetKind == "Chest" then
					damageSuccess, remainingHealth, appliedDamage = ChestService.ApplyDamage(copy.id, damageAmount, {
						tool = "Bat",
						attacker = self.player.UserId,
						reference = "BatHit",
					})
				elseif targetKind == "CrateTopo" then
					damageSuccess, remainingHealth, appliedDamage, extras = CrateTopoService.ApplyDamage(copy.id, damageAmount, {
						tool = "Bat",
						attacker = self.player.UserId,
						reference = copy.hitContext or "BatHit",
						player = self.player,
					})
				else
					damageSuccess, remainingHealth = BrainrotTourismService.ApplyDamage(copy.id, damageAmount, {
						tool = "Bat",
						attacker = self.player.UserId,
						reference = "BatHit",
					})
					if damageSuccess then
						appliedDamage = damageAmount
					end
				end
			else
				damageSuccess = true
			end

			if damageSuccess then
				local dealt
				if targetKind == "Chest" or targetKind == "CrateTopo" then
					dealt = appliedDamage
				else
					dealt = damageAmount
				end
				copy.damageDealt = dealt
				copy.wasDamaged = dealt > 0
				if remainingHealth ~= nil then
					copy.health = remainingHealth
				end
				if extras then
					for key, value in extras do
						copy[key] = value
					end
				end
				if copy.wasDamaged then
					damageAppliedCount += 1
				end
			else
				copy.damageDealt = 0
				copy.wasDamaged = false
				if extras then
					for key, value in extras do
						copy[key] = value
					end
				end
			end

			detected[#detected + 1] = copy
		else
			recordRejection(detail, rejection or "filtered")
		end
	end

	table.sort(detected, function(left, right)
		local leftDistance = left.distanceFromCenter or math.huge
		local rightDistance = right.distanceFromCenter or math.huge
		return leftDistance < rightDistance
	end)

	local diagnostics = {
		slotIndex = slotIndex,
		ownerCandidates = ownerCandidateCount,
		plotCandidates = plotCandidateCount,
		fallbackCandidates = fallbackCandidateCount,
		chestCandidates = chestCandidateCount,
		crateCandidates = crateCandidateCount,
		totalCandidates = #candidates,
		detected = #detected,
		rejections = rejections,
		damaged = damageAppliedCount,
	}

	BatToolPackets.DetectResult:FireClient(
		self.player,
		buildResultPayload(self.player, detected, detectionCFrame, slotIndex, diagnostics)
	)
end

local function onDetect(player: Player)
	if not player or RunService:IsClient() then
		return
	end

	local session = DetectionSession.new(player)
	local ok, err = pcall(function()
		session:execute()
	end)

	if not ok and RunService:IsStudio() then
		warn("BatToolService detection failed", err)
	end
end

function BatToolService.Init()
	if RunService:IsClient() then
		return
	end

	if detectConnection then
		return
	end

	detectConnection = BatToolPackets.Detect.OnServerEvent:Connect(onDetect)
end

return BatToolService
