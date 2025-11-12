--!strict

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Packet = require(ReplicatedStorage.Network.Packets)

export type PromptDescriptor = {
	id: string,
	parent: Instance,
	parentPath: {string}?,
	parentTag: string?,
	actionText: string?,
	objectText: string?,
	holdDuration: number?,
	requiresLineOfSight: boolean?,
	maxActivationDistance: number?,
	keyboardKeyCode: Enum.KeyCode?,
	gamepadKeyCode: Enum.KeyCode?,
	style: Enum.ProximityPromptStyle?,
	enabled: boolean?,
	uiOffset: Vector2?,
	name: string?,
}

local controlPacket = Packet("ProximityPromptControl", Packet.String, Packet.String, Packet.Any)
local signalPacket = Packet("ProximityPromptSignal", Packet.String)

if RunService:IsServer() then
	type EncodedDescriptor = {
		id: string,
		parent: Instance,
		parentPath: {string}?,
		parentTag: string?,
		actionText: string?,
		objectText: string?,
		holdDuration: number?,
		requiresLineOfSight: boolean?,
		maxActivationDistance: number?,
		keyboardKeyCode: Enum.KeyCode?,
		gamepadKeyCode: Enum.KeyCode?,
		style: Enum.ProximityPromptStyle?,
		enabled: boolean?,
		uiOffset: Vector2?,
		name: string?,
	}
	type ServerEntry = {
		descriptor: EncodedDescriptor,
		callback: ((Player) -> ())?,
	}

	local active: { [Player]: { [string]: ServerEntry } } = {}

	local function buildParentPath(instance: Instance): {string}?
		local segments = {}
		local current: Instance? = instance
		while current do
			if current == game then
				break
			end

			table.insert(segments, 1, current.Name)
			current = current.Parent
		end

		if #segments == 0 then
			return nil
		end

		return segments
	end

	local function sanitize(descriptor: PromptDescriptor): EncodedDescriptor
		assert(descriptor ~= nil, "Prompt descriptor is required")
		local id = descriptor.id
		if typeof(id) ~= "string" or id == "" then
			error("Prompt descriptor must include a non-empty string id", 3)
		end

		local parent = descriptor.parent
		if typeof(parent) ~= "Instance" then
			error("Prompt descriptor must include a parent Instance", 3)
		end

		local path = descriptor.parentPath
		if typeof(path) ~= "table" then
			path = buildParentPath(parent)
		end

		local encoded: EncodedDescriptor = {
			id = id,
			parent = parent,
			parentPath = path,
			parentTag = descriptor.parentTag,
			actionText = descriptor.actionText,
			objectText = descriptor.objectText,
			holdDuration = descriptor.holdDuration,
			requiresLineOfSight = descriptor.requiresLineOfSight,
			maxActivationDistance = descriptor.maxActivationDistance,
			keyboardKeyCode = descriptor.keyboardKeyCode,
			gamepadKeyCode = descriptor.gamepadKeyCode,
			style = descriptor.style,
			enabled = if descriptor.enabled == nil then true else descriptor.enabled,
			uiOffset = descriptor.uiOffset,
			name = descriptor.name,
		}

		return encoded
	end

	local function removeForPlayer(player: Player, promptId: string)
		local playerEntries = active[player]
		if not playerEntries then
			return
		end

		if playerEntries[promptId] then
			playerEntries[promptId] = nil
			controlPacket:FireClient(player, promptId, "remove", {})
			if next(playerEntries) == nil then
				active[player] = nil
			end
		end
	end

	signalPacket.OnServerEvent:Connect(function(player: Player, promptId: string)
		local playerEntries = active[player]
		if not playerEntries then
			return
		end

		local entry = playerEntries[promptId]
		if not entry then
			return
		end

		local callback = entry.callback
		if not callback then
			return
		end

		local ok, err = (pcall :: any)(callback, player)
		if not ok then
			warn(`Prompt callback for {promptId} failed: {err}`)
		end
	end)

	local function clearPlayer(player: Player)
		local playerEntries = active[player]
		if not playerEntries then
			return
		end

		active[player] = nil
		for promptId in playerEntries do
			controlPacket:FireClient(player, promptId, "remove", {})
		end
	end

	local function replayPlayerPrompts(player: Player)
		local playerEntries = active[player]
		if not playerEntries then
			return
		end

		for promptId, entry in playerEntries do
			controlPacket:FireClient(player, promptId, "create", entry.descriptor)
		end
	end

	Players.PlayerRemoving:Connect(function(player)
		active[player] = nil
	end)

	controlPacket.OnServerEvent:Connect(function(player: Player, promptId: string, action: string, payload: any)
		if promptId == "__sync__" then
			replayPlayerPrompts(player)
			return
		end

		if promptId == "__clear__" then
			clearPlayer(player)
			return
		end
	end)

	local function registerForPlayer(player: Player, descriptor: PromptDescriptor, callback: ((Player) -> ())?)
		local encoded = sanitize(descriptor)

		local playerEntries = active[player]
		if not playerEntries then
			playerEntries = {}
			active[player] = playerEntries
		end

		if playerEntries[encoded.id] then
			controlPacket:FireClient(player, encoded.id, "remove", {})
		end

		playerEntries[encoded.id] = {
			descriptor = encoded,
			callback = callback,
		}

		controlPacket:FireClient(player, encoded.id, "create", encoded)
	end

	return table.freeze({
		registerForPlayer = registerForPlayer,
		removeForPlayer = removeForPlayer,
		clearPlayer = clearPlayer,
	})
else
	type ClientEntry = {
		prompt: ProximityPrompt,
		connections: { RBXScriptConnection },
	}

	local active: { [string]: ClientEntry } = {}
	local pendingState: { [string]: { payload: {[string]: any}, attempts: number } } = {}
	local MAX_PARENT_ATTEMPTS = 200

	local function applyPayload(prompt: ProximityPrompt, payload: {[string]: any})
		if payload.actionText ~= nil then
			prompt.ActionText = payload.actionText
		end

		if payload.objectText ~= nil then
			prompt.ObjectText = payload.objectText
		end

		if payload.holdDuration ~= nil then
			prompt.HoldDuration = payload.holdDuration
		end

		if payload.requiresLineOfSight ~= nil then
			prompt.RequiresLineOfSight = payload.requiresLineOfSight
		end

		if payload.maxActivationDistance ~= nil then
			prompt.MaxActivationDistance = payload.maxActivationDistance
		end

		if payload.keyboardKeyCode ~= nil then
			prompt.KeyboardKeyCode = payload.keyboardKeyCode
		end

		if payload.gamepadKeyCode ~= nil then
			prompt.GamepadKeyCode = payload.gamepadKeyCode
		end

		if payload.style ~= nil then
			prompt.Style = payload.style
		end

		if payload.uiOffset ~= nil then
			prompt.UIOffset = payload.uiOffset
		end

		prompt.Enabled = payload.enabled ~= false
	end

	local function disconnectAll(connections: { RBXScriptConnection })
		for index = #connections, 1, -1 do
			local connection = connections[index]
			connection:Disconnect()
			connections[index] = nil
		end
	end

	local function teardown(promptId: string, destroyPrompt: boolean)
		local entry = active[promptId]
		if not entry then
			return
		end

		active[promptId] = nil
		pendingState[promptId] = nil
		disconnectAll(entry.connections)

		if destroyPrompt then
			entry.prompt:Destroy()
		end
	end

	local function resolveParent(payload: {[string]: any}): Instance?
		local parent = payload.parent
		if typeof(parent) == "Instance" then
			return parent :: Instance
		end

		local tag = payload.parentTag
		if typeof(tag) == "string" and tag ~= "" then
			local tagged = CollectionService:GetTagged(tag)
			for _, instance in tagged do
				if instance and instance.Parent then
					return instance
				end
			end
		end

		local path = payload.parentPath
		if typeof(path) ~= "table" then
			path = nil
		end

		if path then
			local current: Instance? = game
			for _, segment in ipairs(path :: {string}) do
				if current == nil then
					current = nil
					break
				end

				if current == game then
					local ok, service = pcall(game.GetService, game, segment)
					if ok and service then
						current = service
					else
						current = game:FindFirstChild(segment)
					end
				else
					current = current:FindFirstChild(segment)
				end

				if not current then
					break
				end
			end

			if current and current.Parent then
				return current
			end
		end

		return nil
	end

	local function finalizePrompt(promptId: string, payload: {[string]: any}, parent: Instance)
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = if typeof(payload.name) == "string" and payload.name ~= "" then payload.name else promptId
		prompt.RequiresLineOfSight = false
		prompt.MaxActivationDistance = 12
		prompt.HoldDuration = 0

		prompt.Parent = parent
		applyPayload(prompt, payload)

		local entry: ClientEntry = {
			prompt = prompt,
			connections = {},
		}

		entry.connections[#entry.connections + 1] = prompt.Destroying:Connect(function()
			teardown(promptId, false)
		end)

		entry.connections[#entry.connections + 1] = prompt.Triggered:Connect(function()
			signalPacket:Fire(promptId)
		end)

		active[promptId] = entry
	end

	local scheduleRetry: (promptId: string) -> ()

	local function tryConstruct(promptId: string)
		local state = pendingState[promptId]
		if not state then
			return
		end

		local parent = resolveParent(state.payload)
		if not parent then
			if state.attempts >= MAX_PARENT_ATTEMPTS then
				pendingState[promptId] = nil
				warn(`Timed out waiting for parent of prompt {promptId}`)
				return
			end

			scheduleRetry(promptId)
			return
		end

		pendingState[promptId] = nil
		finalizePrompt(promptId, state.payload, parent)
	end

	scheduleRetry = function(promptId: string)
		task.delay(0.1, function()
			local state = pendingState[promptId]
			if not state then
				return
			end

			state.attempts += 1
			tryConstruct(promptId)
		end)
	end

	controlPacket.OnClientEvent:Connect(function(promptId: string, action: string, payload: {[string]: any})
		if action == "remove" then
			pendingState[promptId] = nil
			teardown(promptId, true)
			return
		end

		if action ~= "create" then
			return
		end

		teardown(promptId, true)
		pendingState[promptId] = {payload = payload, attempts = 0}
		tryConstruct(promptId)
	end)

	task.defer(function()
		controlPacket:Fire("__sync__", "", {})
	end)

	local function getPrompt(promptId: string): ProximityPrompt?
		local entry = active[promptId]
		return if entry then entry.prompt else nil
	end

	local function serverOnly(methodName: string)
		return function()
			error(`ProximityPrompts.{methodName} is only available on the server`, 2)
		end
	end

	return {
		registerForPlayer = serverOnly("registerForPlayer"),
		removeForPlayer = serverOnly("removeForPlayer"),
		clearPlayer = serverOnly("clearPlayer"),
		getPrompt = getPrompt,
		removeLocal = function(promptId: string)
			teardown(promptId, true)
		end,
	}
end