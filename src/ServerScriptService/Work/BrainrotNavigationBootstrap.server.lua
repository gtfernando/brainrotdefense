local RunService = game:GetService("RunService")

if RunService:IsClient() then
    return
end

local registry = require(script.Parent.Modules.BrainrotNavigationRegistry)
registry.Bootstrap()

local tourismService = require(script.Parent.Modules.BrainrotTourismService)
tourismService.Init()