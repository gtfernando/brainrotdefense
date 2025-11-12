--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packet = require(ReplicatedStorage.Network.Packets)

local OfflinePackets = {}

OfflinePackets.Show = Packet("OfflineShow", Packet.NumberF64, Packet.NumberF64, Packet.Boolean8, Packet.Boolean8)
OfflinePackets.Claim = Packet("OfflineClaim"):Response(Packet.Boolean8, Packet.NumberF64, Packet.NumberF64, Packet.Boolean8, Packet.Boolean8, Packet.String)
OfflinePackets.BuyGamepass = Packet("OfflineBuyGamepass"):Response(Packet.Boolean8, Packet.String)

return OfflinePackets
