local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Placement = {}

Placement.Constants = require(script.Constants)
Placement.AssetRegistry = require(script.AssetRegistry)
Placement.Grid = require(script.Grid)
Placement.Packets = require(ReplicatedStorage.Network.PlacementPackets)

return Placement
