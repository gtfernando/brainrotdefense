--!strict

local RunService = game:GetService("RunService")
if RunService:IsClient() then
	return
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
require(ReplicatedStorage:WaitForChild("ProximityPrompts"))
