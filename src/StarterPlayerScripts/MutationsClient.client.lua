--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local MutationPackets = require(ReplicatedStorage.Network.MutationPackets)

local LOCAL_PLAYER = Players.LocalPlayer
local DESIGN_FOLDER = ReplicatedStorage:WaitForChild("Design")
local ICONS_FOLDER = DESIGN_FOLDER:FindFirstChild("Icons")

local MUTATION_ICON_OVERRIDES: { [string]: string } = {
	Day = "Sun",
	Night = "Moon",
}

local playerGui = LOCAL_PLAYER:WaitForChild("PlayerGui")
local mainGui = playerGui:WaitForChild("Main")
local mutationsContainer = mainGui:WaitForChild("Mutations")

local activeMetadata: { [string]: { [string]: any } } = {}
local activeCountdowns: { [string]: TextLabel } = {}
local countdownConnection: RBXScriptConnection? = nil

local function findExistingIcon(mutationId: string)
	for _, child in ipairs(mutationsContainer:GetChildren()) do
		if child:GetAttribute("MutationId") == mutationId then
			return child
		end
	end
	return nil
end

local function findCountdownLabel(root: Instance): TextLabel?
	local secondsObject = root:FindFirstChild("Seconds", true)
	if secondsObject then
		if secondsObject:IsA("TextLabel") then
			return secondsObject
		end
		local nested = secondsObject:FindFirstChild("Text", true)
		if nested and nested:IsA("TextLabel") then
			return nested
		end
		local fallback = secondsObject:FindFirstChildWhichIsA("TextLabel", true)
		if fallback then
			return fallback
		end
	end
	return nil
end

local function formatDuration(seconds: number): string
	local remaining = math.max(0, seconds)
	local displaySeconds = math.max(0, math.ceil(remaining))
	local minutes = math.floor(displaySeconds / 60)
	local secs = displaySeconds % 60
	return string.format("%02d:%02d", minutes, secs)
end

local function configureIcon(mutationId: string, icon: Instance)
	icon:SetAttribute("MutationId", mutationId)
	local metadata = activeMetadata[mutationId]
	local expiresAt = metadata and metadata.expiresAt
	if typeof(expiresAt) ~= "number" then
		expiresAt = nil
	end
	icon:SetAttribute("ExpiresAt", expiresAt)

	local secondsLabel = findCountdownLabel(icon)
	if secondsLabel then
		if expiresAt then
			secondsLabel.Visible = true
			local now = Workspace:GetServerTimeNow()
			secondsLabel.Text = formatDuration(math.max(0, expiresAt - now))
			activeCountdowns[mutationId] = secondsLabel
		else
			secondsLabel.Visible = false
			activeCountdowns[mutationId] = nil
		end
	else
		activeCountdowns[mutationId] = nil
	end
end

local function ensureCountdownUpdater()
	if countdownConnection then
		return
	end

	countdownConnection = RunService.RenderStepped:Connect(function()
		local now = Workspace:GetServerTimeNow()
		for mutationId, label in pairs(activeCountdowns) do
			if not label or not label.Parent then
				activeCountdowns[mutationId] = nil
			else
				local metadata = activeMetadata[mutationId]
				local expiresAt = metadata and metadata.expiresAt
				if typeof(expiresAt) ~= "number" then
					label.Visible = false
					activeCountdowns[mutationId] = nil
				else
					local remaining = math.max(0, expiresAt - now)
					label.Text = formatDuration(remaining)
				end
			end
		end
	end)
end

local function removeMissingIcons(activeSet: { [string]: boolean })
	for _, child in ipairs(mutationsContainer:GetChildren()) do
		local mutationId = child:GetAttribute("MutationId")
		if mutationId and not activeSet[mutationId] then
			activeCountdowns[mutationId] = nil
			child:Destroy()
		end
	end
end

local function addRequiredIcons(activeSet: { [string]: boolean })
	if not ICONS_FOLDER then
		return
	end

	for mutationId in pairs(activeSet) do
		if not findExistingIcon(mutationId) then
			local iconName = MUTATION_ICON_OVERRIDES[mutationId] or mutationId
			local template = ICONS_FOLDER:FindFirstChild(iconName)
			if template and template:IsA("GuiObject") then
				local clone = template:Clone()
				clone.Visible = true
				clone.Parent = mutationsContainer
				configureIcon(mutationId, clone)
			end
		else
			local existing = findExistingIcon(mutationId)
			if existing then
				configureIcon(mutationId, existing)
			end
		end
	end
end

local function updateExistingIcons()
	for _, child in ipairs(mutationsContainer:GetChildren()) do
		local mutationId = child:GetAttribute("MutationId")
		if mutationId then
			configureIcon(mutationId, child)
		end
	end
end

local function renderMutations(payload: any)
	local mutationList: { string } = {}
	local metadataBlock: { [string]: { [string]: any } } = {}

	if typeof(payload) == "table" then
		local typedPayload = payload :: any
		if typeof(typedPayload.list) == "table" then
			for _, mutationId in ipairs(typedPayload.list) do
				if typeof(mutationId) == "string" then
					mutationList[#mutationList + 1] = mutationId
				end
			end
			if typeof(typedPayload.metadata) == "table" then
				for key, value in pairs(typedPayload.metadata) do
					if typeof(key) == "string" and typeof(value) == "table" then
						metadataBlock[key] = table.clone(value :: { [string]: any })
					end
				end
			end
		elseif #typedPayload > 0 then
			for _, mutationId in ipairs(typedPayload) do
				if typeof(mutationId) == "string" then
					mutationList[#mutationList + 1] = mutationId
				end
			end
		end
	end

	local activeSet: { [string]: boolean } = {}
	for _, mutationId in ipairs(mutationList) do
		activeSet[mutationId] = true
	end

	local newMetadata: { [string]: { [string]: any } } = {}
	for mutationId in pairs(activeSet) do
		local entry = metadataBlock[mutationId]
		if entry then
			newMetadata[mutationId] = entry
		else
			newMetadata[mutationId] = {}
		end
	end
	activeMetadata = newMetadata

	removeMissingIcons(activeSet)
	addRequiredIcons(activeSet)
	updateExistingIcons()
	ensureCountdownUpdater()
end

MutationPackets.MutationsState.OnClientEvent:Connect(renderMutations)
