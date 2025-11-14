--!strict

local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Modules = ServerScriptService:WaitForChild("Work"):WaitForChild("Modules")

if RunService:IsClient() then
	return
end

local BrainrotChaosService = require(Modules:WaitForChild("BrainrotChaosService"))

BrainrotChaosService.Init({
	minInterval = 10,
	maxInterval = 10,
})
