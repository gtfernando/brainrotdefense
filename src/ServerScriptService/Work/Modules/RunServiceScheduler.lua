--!strict

local RunService = game:GetService("RunService")

export type SchedulerHandle = {
	_id: number,
}

type Registration = {
	interval: number,
	callback: (number, number) -> any,
	accumulator: number,
}

local Scheduler = {}

local registrations: { [number]: Registration } = {}
local nextId = 0
local heartbeatConnection: RBXScriptConnection? = nil

local function cleanupConnectionIfIdle()
	if heartbeatConnection and next(registrations) == nil then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
end

local function step(dt: number)
	if next(registrations) == nil then
		cleanupConnectionIfIdle()
		return
	end

	for id, entry in registrations do
		local interval = entry.interval
		entry.accumulator += dt
		if entry.accumulator >= interval then
			local ticks = math.max(1, math.floor(entry.accumulator / interval))
			local totalDelta = ticks * interval
			entry.accumulator -= totalDelta

			local success, result = pcall(entry.callback, totalDelta, ticks)
			if not success then
				warn("RunServiceScheduler callback error:\n" .. tostring(result))
			elseif result == false then
				registrations[id] = nil
			end
		end
	end

	cleanupConnectionIfIdle()
end

local function ensureHeartbeat()
	if heartbeatConnection then
		return
	end

	heartbeatConnection = RunService.Heartbeat:Connect(step)
end

function Scheduler.register(interval: number, callback: (number, number) -> any): SchedulerHandle
	if typeof(interval) ~= "number" or interval <= 0 then
		error("RunServiceScheduler.register requires a positive numeric interval", 2)
	end

	if typeof(callback) ~= "function" then
		error("RunServiceScheduler.register requires a callback function", 2)
	end

	nextId += 1
	local id = nextId

	registrations[id] = {
		interval = interval,
		callback = callback,
		accumulator = 0,
	}

	ensureHeartbeat()

	return { _id = id }
end

function Scheduler.unregister(handle: SchedulerHandle?)
	if typeof(handle) ~= "table" or typeof(handle._id) ~= "number" then
		return
	end

	registrations[handle._id] = nil
	cleanupConnectionIfIdle()
end

function Scheduler.isRegistered(handle: SchedulerHandle?): boolean
	if typeof(handle) ~= "table" or typeof(handle._id) ~= "number" then
		return false
	end

	return registrations[handle._id] ~= nil
end

return Scheduler
