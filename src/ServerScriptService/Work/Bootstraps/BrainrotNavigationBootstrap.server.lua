local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Modules = ServerScriptService:WaitForChild("Work"):WaitForChild("Modules")

if RunService:IsClient() then
    return
end

local registry = require(Modules.BrainrotNavigationRegistry)
registry.Bootstrap()

local tourismService = require(Modules.WaveController.Runtime)
tourismService.Init()