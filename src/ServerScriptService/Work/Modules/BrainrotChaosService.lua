--!strict

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ModulesFolder = script.Parent
local MutationService = require(ModulesFolder:WaitForChild("MutationService"))

local BrainrotChaosService = {}

local MUTATION_NAME = "BrainrotsCrazy"

local DEFAULT_MIN_INTERVAL = 120
local DEFAULT_MAX_INTERVAL = 240
local DEFAULT_DURATION = 60

local configured = false
local running = false
local active = false
local mutationConnection: RBXScriptConnection? = nil

local minInterval = DEFAULT_MIN_INTERVAL
local maxInterval = DEFAULT_MAX_INTERVAL
local duration = DEFAULT_DURATION

local rng = Random.new()

local function copyNumber(value: any): number?
	if typeof(value) ~= "number" then
		return nil
	end
	return value
end

local function getServerTime(): number
	return Workspace:GetServerTimeNow()
end

local function deactivate()
	if not active then
		MutationService.SetActive(MUTATION_NAME, false)
		return
	end

	active = false
	MutationService.SetActive(MUTATION_NAME, false)
end

local function activate()
	if active then
		return
	end

	active = true
	local expiresAt = getServerTime() + duration
	MutationService.SetActive(MUTATION_NAME, true, {
		expiresAt = expiresAt,
	})
end

local function waitSeconds(seconds: number)
	if not running then
		return
	end

	local remaining = math.max(0, seconds)
	if remaining <= 0 then
		return
	end

	local waited = task.wait(remaining)
	if waited < remaining and running then
		local leftover = remaining - waited
		if leftover > 0 then
			waitSeconds(leftover)
		end
	end
end

local function cycleLoop()
	while running do
		local interval = rng:NextNumber(minInterval, maxInterval)
		waitSeconds(interval)
		if not running then
			break
		end

		activate()
		waitSeconds(duration)
		deactivate()
	end
end

local function observeMutations(state: { string })
	for _, name in ipairs(state) do
		if name == MUTATION_NAME then
			return
		end
	end
	active = false
end

function BrainrotChaosService.Init(config: { [string]: any }?)
	if RunService:IsClient() then
		return
	end

	if running then
		return
	end

	MutationService.Init()

	if not configured then
		configured = true
		if config then
			local minValue = copyNumber(config.minInterval)
			if minValue and minValue > 0 then
				minInterval = minValue
			end

			local maxValue = copyNumber(config.maxInterval)
			if maxValue and maxValue >= minInterval then
				maxInterval = maxValue
			end

			local durationValue = copyNumber(config.duration)
			if durationValue and durationValue > 0 then
				duration = durationValue
			end
		end
	end

	running = true
	mutationConnection = MutationService.Observe(observeMutations)
	task.spawn(cycleLoop)
end

function BrainrotChaosService.Stop()
	if not running then
		return
	end

	running = false
	if mutationConnection then
		mutationConnection:Disconnect()
		mutationConnection = nil
	end

	deactivate()
end

return BrainrotChaosService
