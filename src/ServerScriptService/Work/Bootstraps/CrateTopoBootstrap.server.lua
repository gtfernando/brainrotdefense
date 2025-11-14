--!strict

local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Modules = ServerScriptService:WaitForChild("Work"):WaitForChild("Modules")

if RunService:IsClient() then
	return
end

local moduleInstance = Modules:FindFirstChild("CrateTopoService")
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
