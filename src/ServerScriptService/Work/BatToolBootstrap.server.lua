local RunService = game:GetService("RunService")

if RunService:IsClient() then
	return
end

local ModulesFolder = script.Parent:WaitForChild("Modules")
local BatToolService = require(ModulesFolder:WaitForChild("BatToolService"))

BatToolService.Init()
