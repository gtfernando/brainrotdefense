--!strict

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local ModulesFolder = script.Parent
local MutationService = require(ModulesFolder:WaitForChild("MutationService"))

export type DayNightConfig = {
	dayDuration: number?,
	nightDuration: number?,
	dayClockTime: number?,
	nightClockTime: number?,
}

local DayNightService = {}

local settings = {
	dayDuration = 10,
	nightDuration = 5,
	dayClockTime = 12,
	nightClockTime = 18,
}

local initialized = false
local running = false
local currentPhase = "Day"
local cycleThread: thread? = nil

local function applyPhase(phase: string)
	if phase == "Day" then
		Lighting.ClockTime = settings.dayClockTime
		MutationService.SetActive("Day", true)
		MutationService.SetActive("Night", false)
	elseif phase == "Night" then
		Lighting.ClockTime = settings.nightClockTime
		MutationService.SetActive("Day", false)
		MutationService.SetActive("Night", true)
	end

	currentPhase = phase
end

local function cycleLoop()
	while running do
		applyPhase("Day")
		local step = settings.dayDuration
		local elapsed = 0
		while running and elapsed < step do
			local delta = task.wait()
			elapsed += delta
		end
		if not running then
			break
		end

		applyPhase("Night")
		step = settings.nightDuration
		elapsed = 0
		while running and elapsed < step do
			local delta = task.wait()
			elapsed += delta
		end
	end
end

local function ensureInitialized()
	if initialized then
		return
	end

	if RunService:IsClient() then
		return
	end

	MutationService.Init()
	initialized = true
end

function DayNightService.Configure(config: DayNightConfig?)
	if config == nil then
		return
	end

	if typeof(config.dayDuration) == "number" and config.dayDuration > 0 then
		settings.dayDuration = config.dayDuration
	end
	if typeof(config.nightDuration) == "number" and config.nightDuration > 0 then
		settings.nightDuration = config.nightDuration
	end
	if typeof(config.dayClockTime) == "number" then
		settings.dayClockTime = config.dayClockTime % 24
	end
	if typeof(config.nightClockTime) == "number" then
		settings.nightClockTime = config.nightClockTime % 24
	end
end

function DayNightService.Init(config: DayNightConfig?)
	if RunService:IsClient() then
		return
	end

	ensureInitialized()
	DayNightService.Configure(config)

	if running then
		return
	end

	running = true
	cycleThread = task.spawn(cycleLoop)
end

function DayNightService.Stop()
	if not running then
		return
	end

	running = false
	if cycleThread then
		task.cancel(cycleThread)
		cycleThread = nil
	end

	MutationService.SetActive("Day", false)
	MutationService.SetActive("Night", false)
end

function DayNightService.GetPhase(): string
	return currentPhase
end

function DayNightService.SetPhase(phase: "Day" | "Night")
	applyPhase(phase)
end

function DayNightService.GetSettings()
	return table.clone(settings)
end

return DayNightService
