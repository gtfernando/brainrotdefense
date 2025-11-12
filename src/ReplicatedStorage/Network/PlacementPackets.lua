--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packet = require(ReplicatedStorage.Network.Packets)

local PlacementPackets = {}

PlacementPackets.Init = Packet("PlacementInit", Packet.Any, Packet.Any)
PlacementPackets.Update = Packet("PlacementUpdate", Packet.String, Packet.Any)
PlacementPackets.Request = Packet("PlacementRequest", Packet.String, Packet.Vector2F32, Packet.NumberU8, Packet.Any):Response(Packet.Boolean8, Packet.Any)
PlacementPackets.ZonePurchase = Packet("PlacementZonePurchase", Packet.String):Response(Packet.Boolean8, Packet.Any)
PlacementPackets.Pickup = Packet("PlacementPickup", Packet.String):Response(Packet.Boolean8, Packet.Any)
PlacementPackets.Upgrade = Packet("PlacementUpgrade", Packet.String, Packet.String, Packet.Any):Response(Packet.Boolean8, Packet.Any)

return PlacementPackets
