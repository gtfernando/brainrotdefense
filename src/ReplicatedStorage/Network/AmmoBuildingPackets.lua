--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packet = require(ReplicatedStorage.Network.Packets)

local AmmoBuildingPackets = {}

AmmoBuildingPackets.Open = Packet("AmmoBuildingOpen", Packet.Any)
AmmoBuildingPackets.Close = Packet("AmmoBuildingClose")
AmmoBuildingPackets.MoneyPurchase = Packet("AmmoBuildingPurchaseMoney", Packet.String):Response(Packet.Boolean8, Packet.String)
AmmoBuildingPackets.RobuxPurchase = Packet("AmmoBuildingPurchaseRobux", Packet.String):Response(Packet.Boolean8, Packet.String)
AmmoBuildingPackets.ProjectileFired = Packet("AmmoBuildingProjectileFired", Packet.Any)

return AmmoBuildingPackets
