--!strict

local RunService = game:GetService("RunService")

if RunService:IsClient() then
	return
end

local ModulesFolder = script.Parent:WaitForChild("Modules")
local BrainrotChaosService = require(ModulesFolder:WaitForChild("BrainrotChaosService"))

BrainrotChaosService.Init({
	minInterval = 10,
	maxInterval = 10,
})
