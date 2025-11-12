--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packet = require(ReplicatedStorage.Network.Packets)

local BrainrotTourismPackets = {}

BrainrotTourismPackets.AgentSpawn = Packet("BrainrotAgentSpawn", Packet.Any)
BrainrotTourismPackets.AgentHidden = Packet("BrainrotAgentHidden", Packet.Any)
BrainrotTourismPackets.AgentReturn = Packet("BrainrotAgentReturn", Packet.Any)
BrainrotTourismPackets.AgentRemoved = Packet("BrainrotAgentRemoved", Packet.Any)
BrainrotTourismPackets.AgentSnapshot = Packet("BrainrotAgentSnapshot", Packet.Any)
BrainrotTourismPackets.DifficultyUpdate = Packet("BrainrotDifficultyUpdate", Packet.NumberU16, Packet.NumberU16)

return BrainrotTourismPackets
