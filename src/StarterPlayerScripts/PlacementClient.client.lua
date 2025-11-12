local ReplicatedStorage = game:GetService("ReplicatedStorage")

local placementModule = ReplicatedStorage:WaitForChild("Placement") :: ModuleScript
local clientFolder = placementModule:WaitForChild("Client")
local controllerModule = clientFolder:WaitForChild("Controller") :: ModuleScript
local Controller = require(controllerModule)

Controller:Start()