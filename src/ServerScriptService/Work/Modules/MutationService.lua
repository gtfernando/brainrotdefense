--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Signal = require(ReplicatedStorage.Packages.Signal)
local MutationPackets = require(ReplicatedStorage.Network.MutationPackets)

local MutationService = {}

local initialized = false
local activeMutations: { [string]: boolean } = {}
local mutationMetadata: { [string]: { [string]: any } } = {}
local changedSignal = Signal.new()

local function cloneState(): { string }
	local list = table.create(8)
	for name, isActive in pairs(activeMutations) do
		if isActive then
			list[#list + 1] = name
		end
	end
	table.sort(list)
	return list
end

local function cloneMetadata(): { [string]: { [string]: any } }
	local copy: { [string]: { [string]: any } } = {}
	for name, metadata in pairs(mutationMetadata) do
		if activeMutations[name] then
			copy[name] = table.clone(metadata)
		end
	end
	return copy
end

local function broadcast()
	local state = cloneState()
	local metadata = cloneMetadata()

	local payload = {
		list = state,
		metadata = metadata,
	}

	for _, player in ipairs(Players:GetPlayers()) do
		MutationPackets.MutationsState:FireClient(player, payload)
	end

	changedSignal:Fire(state)
end

function MutationService.Init()
	if RunService:IsClient() then
		return
	end

	if initialized then
		return
	end

	initialized = true

	Players.PlayerAdded:Connect(function(player)
		MutationPackets.MutationsState:FireClient(player, {
			list = cloneState(),
			metadata = cloneMetadata(),
		})
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		MutationPackets.MutationsState:FireClient(player, {
			list = cloneState(),
			metadata = cloneMetadata(),
		})
	end
end

local function sanitizeMetadata(metadata: { [string]: any }?): { [string]: any }?
	if typeof(metadata) ~= "table" then
		return nil
	end
	return table.clone(metadata)
end

function MutationService.SetActive(mutationName: string, isActive: boolean, metadata: { [string]: any }?)
	assert(type(mutationName) == "string", "Mutation name must be a string")

	if RunService:IsClient() then
		return
	end

	local sanitizedMetadata = sanitizeMetadata(metadata)
	if isActive then
		local alreadyActive = activeMutations[mutationName] == true
		activeMutations[mutationName] = true
		if sanitizedMetadata then
			mutationMetadata[mutationName] = sanitizedMetadata
		elseif not alreadyActive then
			mutationMetadata[mutationName] = nil
		end
		if alreadyActive and not sanitizedMetadata then
			return
		end
	else
		if not activeMutations[mutationName] then
			return
		end
		activeMutations[mutationName] = nil
		mutationMetadata[mutationName] = nil
	end

	broadcast()
end

function MutationService.Clear()
	if RunService:IsClient() then
		return
	end

	if next(activeMutations) == nil then
		return
	end

	table.clear(activeMutations)
	table.clear(mutationMetadata)
	broadcast()
end

function MutationService.IsActive(mutationName: string): boolean
	return activeMutations[mutationName] == true
end

function MutationService.GetActiveMutations(): { string }
	return cloneState()
end

function MutationService.GetMutationMetadata(mutationName: string): { [string]: any }?
	local metadata = mutationMetadata[mutationName]
	if not metadata then
		return nil
	end
	return table.clone(metadata)
end

function MutationService.GetAllMetadata(): { [string]: { [string]: any } }
	return cloneMetadata()
end

function MutationService.Observe(callback: (state: { string }) -> ())
	return changedSignal:Connect(callback)
end

MutationService.MutationsChanged = changedSignal

return MutationService
