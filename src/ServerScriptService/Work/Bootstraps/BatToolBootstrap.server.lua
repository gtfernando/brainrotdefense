local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Modules = ServerScriptService:WaitForChild("Work"):WaitForChild("Modules")

if RunService:IsClient() then
	return
end

local BatToolService = require(Modules:WaitForChild("BatToolService"))

BatToolService.Init()
