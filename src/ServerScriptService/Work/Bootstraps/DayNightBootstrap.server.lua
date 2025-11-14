--!strict

local RunService = game:GetService("RunService")

local ServerScriptService = game:GetService("ServerScriptService")
local Modules = ServerScriptService:WaitForChild("Work"):WaitForChild("Modules")

if RunService:IsClient() then
	return
end

local DayNightService = require(Modules:WaitForChild("DayNightService"))

DayNightService.Init({
	dayDuration = 10,
	nightDuration = 5,
	dayClockTime = 12,
	nightClockTime = 24,
})
