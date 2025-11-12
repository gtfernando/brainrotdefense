--!strict

local RunService = game:GetService("RunService")

if RunService:IsClient() then
	return
end

local ModulesFolder = script.Parent:WaitForChild("Modules")
local DayNightService = require(ModulesFolder:WaitForChild("DayNightService"))

DayNightService.Init({
	dayDuration = 10,
	nightDuration = 5,
	dayClockTime = 12,
	nightClockTime = 24,
})
