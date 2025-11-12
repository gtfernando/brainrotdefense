--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packet = require(ReplicatedStorage.Network.Packets)

local MutationPackets = {}

MutationPackets.MutationsState = Packet("MutationsState", Packet.Any)

return MutationPackets
