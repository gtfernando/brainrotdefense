--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packet = require(ReplicatedStorage.Network.Packets)

local BatToolPackets = {}

BatToolPackets.Detect = Packet("BatToolDetect")
BatToolPackets.DetectResult = Packet("BatToolDetectResult", Packet.Any)

return BatToolPackets
