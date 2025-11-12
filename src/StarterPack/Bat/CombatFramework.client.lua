--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local tool = script.Parent :: Tool
local framework = require(ReplicatedStorage:WaitForChild("Tools"):WaitForChild("Bat"):WaitForChild("Framework"))

local controller = framework.new(tool)

tool.Destroying:Once(function()
	controller:Destroy()
end)
