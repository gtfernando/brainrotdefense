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
BrainrotTourismPackets.WaveState = Packet("BrainrotWaveState", Packet.Any)
BrainrotTourismPackets.WaveTimer = Packet("BrainrotWaveTimer", Packet.NumberU16, Packet.NumberF32, Packet.NumberF32)
BrainrotTourismPackets.WavePrompt = Packet("BrainrotWavePrompt", Packet.Any)
BrainrotTourismPackets.WaveControl = Packet("BrainrotWaveControl", Packet.String, Packet.Any)

return BrainrotTourismPackets
