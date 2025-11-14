--!strict

local RunService = game:GetService("RunService")

if RunService:IsClient() then
	return
end

local ModulesFolder = script.Parent:WaitForChild("Modules")
local RuntimeFolder = ModulesFolder:WaitForChild("WaveController")
local Runtime = require(RuntimeFolder:WaitForChild("Runtime"))

Runtime.Init()
