--!strict

local RunService = game:GetService("RunService")

if RunService:IsClient() then
	return
end

local ModulesFolder = script.Parent:FindFirstChild("Modules")
if not ModulesFolder then
	warn("CrateTopoBootstrap: Modules folder not available")
	return
end

local moduleInstance = ModulesFolder:FindFirstChild("CrateTopoService")
if not moduleInstance or not moduleInstance:IsA("ModuleScript") then
	warn("CrateTopoBootstrap: CrateTopoService module not found")
	return
end

local CrateTopoService = require(moduleInstance)

if typeof(CrateTopoService) ~= "table" or typeof(CrateTopoService.Init) ~= "function" then
	warn("CrateTopoBootstrap: CrateTopoService.Init no disponible")
	return
end

CrateTopoService.Init()
