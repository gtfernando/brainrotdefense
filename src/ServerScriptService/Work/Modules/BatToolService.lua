--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local ModulesFolder = script.Parent :: Folder
local WorkFolder = ModulesFolder.Parent :: Instance
local PlacementFolder = (WorkFolder:WaitForChild("Placement") :: Folder)
local NetworkFolder = ReplicatedStorage:WaitForChild("Network") :: Folder

local WaveControllerFolder = ModulesFolder:WaitForChild("WaveController")
local BrainrotRuntimeModule = WaveControllerFolder:WaitForChild("Runtime")
local PlotRegistryModule = PlacementFolder:WaitForChild("PlotRegistry") :: ModuleScript
local BatToolPacketsModule = NetworkFolder:WaitForChild("BatToolPackets") :: ModuleScript
local CrateTopoServiceModule = ModulesFolder:WaitForChild("CrateTopoService") :: ModuleScript

local BrainrotTourismService = require(BrainrotRuntimeModule) :: any
local PlotRegistry = require(PlotRegistryModule) :: any
local BatToolPackets = require(BatToolPacketsModule) :: any
local CrateTopoService = require(CrateTopoServiceModule) :: any

local BatToolService = {}

local DETECTION_DURATION = 0.25
local HITBOX_SIZE = Vector3.new(10, 10, 10)
local HITBOX_HALF_SIZE = HITBOX_SIZE * 0.5
local HITBOX_OFFSET = Vector3.new(0, 0, -3)
local HITBOX_TOLERANCE = 0.35
local HITBOX_CORNER_TOLERANCE = 1.5
local HITBOX_CORNER_RADIUS = HITBOX_HALF_SIZE.Magnitude
local FALLBACK_SEARCH_PADDING = Vector3.new(6, 6, 6)
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

local function clampToHitbox(localPoint: Vector3): Vector3
	return Vector3.new(
		math.clamp(localPoint.X, -HITBOX_HALF_SIZE.X, HITBOX_HALF_SIZE.X),
		math.clamp(localPoint.Y, -HITBOX_HALF_SIZE.Y, HITBOX_HALF_SIZE.Y),
		math.clamp(localPoint.Z, -HITBOX_HALF_SIZE.Z, HITBOX_HALF_SIZE.Z)
	)
end

local function withinAabb(localPoint: Vector3, halfSize: Vector3, padding: number): boolean
	return math.abs(localPoint.X) <= halfSize.X + padding
		and math.abs(localPoint.Y) <= halfSize.Y + padding
		and math.abs(localPoint.Z) <= halfSize.Z + padding
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
	hitbox.Transparency = 1
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
	local rejections = {}
	local damageAppliedCount = 0

	local function gatherSamplePoints(detail: AgentDetail): { { point: Vector3, label: string } }
		local samples = {}
		local function push(value: any, label: string)
			if typeof(value) == "Vector3" then
				samples[#samples + 1] = { point = value :: Vector3, label = label }
			end
		end

		push(detail.position, "position")
		push(detail.targetPosition, "target")
		push(detail.attackAnchor, "anchor")

		return samples
	end

	local function evaluateCandidate(detail: AgentDetail): (AgentDetail?, { [string]: any }?)
		local copy = shallowCopy(detail)
		local samples = gatherSamplePoints(detail)
		local bestDistance: number? = nil
		local bestLabel: string? = nil

		local function accept(localPoint: Vector3, label: string, distance: number, clampResult: boolean)
			copy.relativePosition = if clampResult then clampToHitbox(localPoint) else localPoint
			copy.hitContext = label
			copy.distanceFromCenter = distance
			return copy, nil
		end

		local function consider(worldPoint: Vector3?, label: string, extentsPadding: Vector3?)
			if typeof(worldPoint) ~= "Vector3" then
				return nil
			end

			local distance = (worldPoint - detectionCFrame.Position).Magnitude
			if not bestDistance or distance < bestDistance then
				bestDistance = distance
				bestLabel = label
			end

			local localPoint = detectionCFrame:PointToObjectSpace(worldPoint)
			local halfSize = HITBOX_HALF_SIZE
			local clampResult = false
			local extraRadius = 0
			if extentsPadding then
				halfSize += extentsPadding
				clampResult = true
				extraRadius = extentsPadding.Magnitude
			end

			if withinAabb(localPoint, halfSize, HITBOX_TOLERANCE) then
				return accept(localPoint, label, distance, clampResult)
			end

			local allowedRadius = HITBOX_CORNER_RADIUS + HITBOX_CORNER_TOLERANCE + extraRadius
			if distance <= allowedRadius then
				return accept(localPoint, label .. "_corner", distance, true)
			end

			return nil
		end

		for _, sample in ipairs(samples) do
			local accepted = consider(sample.point, sample.label, nil)
			if accepted then
				return accepted
			end
		end

		local extents = asVector3(detail.extents)
		local positionVector = if typeof(detail.position) == "Vector3" then detail.position :: Vector3 else nil
		if extents and positionVector then
			local accepted = consider(positionVector, "extents", extents)
			if accepted then
				return accepted
			end
		end

		return nil, {
			reason = "out_of_hitbox",
			distance = bestDistance,
			reference = bestLabel,
		}
	end

	local function recordRejection(detail: AgentDetail?, info: any)
		if not detail then
			return
		end
		if #rejections >= 5 then
			return
		end

		local entry: { [string]: any } = {
			id = detail.id,
			reason = "filtered",
		}

		if typeof(info) == "string" then
			entry.reason = info
		elseif typeof(info) == "table" then
			if info.reason then
				entry.reason = info.reason
			end
			if typeof(info.distance) == "number" then
				entry.distance = info.distance
			end
			if typeof(info.reference) == "string" then
				entry.reference = info.reference
			end
		end

		rejections[#rejections + 1] = entry
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
	local fallbackSearchSize = HITBOX_SIZE + FALLBACK_SEARCH_PADDING
	for _, detail in ipairs(BrainrotTourismService.GetAgentsInBox(detectionCFrame, fallbackSearchSize)) do
		if push(detail) then
			fallbackCandidateCount += 1
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
				if targetKind == "CrateTopo" then
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
				if targetKind == "CrateTopo" then
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
