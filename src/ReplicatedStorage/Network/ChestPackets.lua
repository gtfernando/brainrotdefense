--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packet = require(ReplicatedStorage.Network.Packets)

local ChestPackets = {}

ChestPackets.Open = Packet("ChestOpen", Packet.Any)
ChestPackets.Close = Packet("ChestClose")
ChestPackets.MoneyPurchase = Packet("ChestPurchaseMoney", Packet.String):Response(Packet.Boolean8, Packet.String)
ChestPackets.RobuxPurchase = Packet("ChestPurchaseRobux", Packet.String):Response(Packet.Boolean8, Packet.String)

return ChestPackets
