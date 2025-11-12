--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local OfflinePackets = require(ReplicatedStorage.Network.OfflinePackets)

local DESIGN_FOLDER = ReplicatedStorage:WaitForChild("Design", math.huge)
local UIS_FOLDER = DESIGN_FOLDER:WaitForChild("UIs", math.huge)
local OFFLINE_TEMPLATE = UIS_FOLDER:WaitForChild("GetOfflineMoney", math.huge)

local currentGui: Instance? = nil
local activeConnections: { RBXScriptConnection } = {}
local updateUi: (number, number, boolean, boolean) -> ()

local function disconnectConnections()
	for index = #activeConnections, 1, -1 do
		local connection = activeConnections[index]
		connection:Disconnect()
		activeConnections[index] = nil
	end
end

local function destroyGui()
	if currentGui then
		disconnectConnections()
		currentGui:Destroy()
		currentGui = nil
	end
end

local function formatMoney(amount: number): string
	if math.abs(amount - math.round(amount)) < 0.001 then
		return string.format("%d $", math.round(amount))
	end
	return string.format("%.2f $", amount)
end

local function formatAccumulatedText(displayAmount: number, rawAmount: number, hasPass: boolean, canBuy: boolean): string
	if displayAmount <= 0 then
		if hasPass then
			return formatMoney(0)
		end
		if canBuy and rawAmount > 0 then
			return formatMoney(rawAmount) .. " con gamepass"
		end
		return formatMoney(0)
	end

	local baseText = formatMoney(displayAmount)
	if hasPass then
		return baseText
	end

	local premiumAmount = math.max(0, rawAmount - displayAmount)
	if premiumAmount > 0 and canBuy then
		return string.format("%s + %s con gamepass", baseText, formatMoney(premiumAmount))
	end

	return baseText
end

local function setLabel(root: Instance, name: string, value: string)
	local found = root:FindFirstChild(name, true)
	if found and found:IsA("TextLabel") then
		found.Text = value
	end
end

local function setButtonVisible(root: Instance, name: string, visible: boolean)
	local button = root:FindFirstChild(name, true)
	if button and button:IsA("GuiButton") then
		button.Visible = visible
		button.Active = visible
	end
end

local function setClaimEnabled(root: Instance, enabled: boolean)
	local button = root:FindFirstChild("Claim", true)
	if button and button:IsA("GuiButton") then
		button.Active = enabled
		if button:IsA("TextButton") then
			button.AutoButtonColor = enabled
		end
	end
end

local function ensureGui(): Instance?
	local mainGui = playerGui:FindFirstChild("Main")
	if not mainGui then
		mainGui = playerGui:WaitForChild("Main", 5)
	end
	if not mainGui then
		return nil
	end

	if currentGui and currentGui.Parent == nil then
		destroyGui()
	end

	if not currentGui then
		local clone = OFFLINE_TEMPLATE:Clone()
		clone.Parent = mainGui
		currentGui = clone

		local claimButton = clone:FindFirstChild("Claim", true)
		if claimButton and claimButton:IsA("TextButton") then
			activeConnections[#activeConnections + 1] = claimButton.Activated:Connect(function()
				task.spawn(function()
					local success, displayAmount, rawAmount, hasPass, canBuy, message = OfflinePackets.Claim:Fire()
					if not success then
						if message and #message > 0 then
							warn(message)
						end
						return
					end

					updateUi(displayAmount, rawAmount, hasPass, canBuy)
				end)
			end)
		end

		local buyButton = clone:FindFirstChild("BuyGamepass", true)
		if buyButton and buyButton:IsA("TextButton") then
			activeConnections[#activeConnections + 1] = buyButton.Activated:Connect(function()
				task.spawn(function()
					local success, message = OfflinePackets.BuyGamepass:Fire()
					if not success and message and #message > 0 then
						warn(message)
					end
				end)
			end)
		end

		local closeButton = clone:FindFirstChild("Close", true)
		if closeButton and closeButton:IsA("TextButton") then
			activeConnections[#activeConnections + 1] = closeButton.Activated:Connect(function()
				destroyGui()
			end)
		end
	end

	return currentGui
end

updateUi = function(displayAmount: number, rawAmount: number, hasPass: boolean, canBuy: boolean)
	if (displayAmount <= 0 and rawAmount <= 0) or (displayAmount <= 0 and not canBuy) then
		destroyGui()
		return
	end

	local gui = ensureGui()
	if not gui then
		return
	end

	setLabel(gui, "Accumulated", formatAccumulatedText(displayAmount, rawAmount, hasPass, canBuy))
	setButtonVisible(gui, "BuyGamepass", canBuy)
	setClaimEnabled(gui, displayAmount > 0)
end

OfflinePackets.Show.OnClientEvent:Connect(function(displayAmount, rawAmount, hasPass, canBuy)
	updateUi(displayAmount, rawAmount, hasPass, canBuy)
end)

player.AncestryChanged:Connect(function(_, parent)
	if not parent then
		destroyGui()
	end
end)
