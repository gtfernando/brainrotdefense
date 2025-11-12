--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ChestPackets = require(ReplicatedStorage.Network.ChestPackets)
local AmmoBuildingPackets = require(ReplicatedStorage.Network.AmmoBuildingPackets)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local function createChestTemplate()
    local button = Instance.new("TextButton")
    button.Name = "Chest"
    button.Size = UDim2.new(1, -10, 0, 90)
    button.BackgroundColor3 = Color3.fromRGB(32, 32, 32)
    button.BorderSizePixel = 0
    button.Text = ""
    button.AutoButtonColor = true
    button.TextTransparency = 1

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Name = "ChestName"
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextSize = 20
    nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.BackgroundTransparency = 1
    nameLabel.Position = UDim2.new(0, 16, 0, 8)
    nameLabel.Size = UDim2.new(0.7, -16, 0, 24)
    nameLabel.Text = "Chest"
    nameLabel.Parent = button

    local priceLabel = Instance.new("TextLabel")
    priceLabel.Name = "Price"
    priceLabel.Font = Enum.Font.Gotham
    priceLabel.TextSize = 18
    priceLabel.TextColor3 = Color3.fromRGB(230, 230, 120)
    priceLabel.TextXAlignment = Enum.TextXAlignment.Left
    priceLabel.BackgroundTransparency = 1
    priceLabel.Position = UDim2.new(0, 16, 0, 36)
    priceLabel.Size = UDim2.new(0.5, -16, 0, 20)
    priceLabel.Text = "0"
    priceLabel.Parent = button

    local luckyLabel = Instance.new("TextLabel")
    luckyLabel.Name = "Lucky"
    luckyLabel.Font = Enum.Font.Gotham
    luckyLabel.TextSize = 18
    luckyLabel.TextColor3 = Color3.fromRGB(120, 220, 255)
    luckyLabel.TextXAlignment = Enum.TextXAlignment.Left
    luckyLabel.BackgroundTransparency = 1
    luckyLabel.Position = UDim2.new(0, 16, 0, 58)
    luckyLabel.Size = UDim2.new(0.5, -16, 0, 20)
    luckyLabel.Text = "1x"
    luckyLabel.Parent = button

    local timeLabel = Instance.new("TextLabel")
    timeLabel.Name = "Time"
    timeLabel.Font = Enum.Font.Gotham
    timeLabel.TextSize = 18
    timeLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
    timeLabel.TextXAlignment = Enum.TextXAlignment.Left
    timeLabel.BackgroundTransparency = 1
    timeLabel.Position = UDim2.new(0, 16, 0, 78)
    timeLabel.Size = UDim2.new(0.5, -16, 0, 20)
    timeLabel.Text = "0s"
    timeLabel.Parent = button

    local image = Instance.new("ImageLabel")
    image.Name = "Image"
    image.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
    image.BorderSizePixel = 0
    image.Size = UDim2.new(0, 64, 0, 64)
    image.Position = UDim2.new(1, -80, 0, 12)
    image.ImageColor3 = Color3.fromRGB(255, 255, 255)
    image.ScaleType = Enum.ScaleType.Fit
    image.Parent = button

    return button
end

local function createBuyTemplate()
    local frame = Instance.new("Frame")
    frame.Name = "Buy"
    frame.Size = UDim2.new(1, -10, 0, 120)
    frame.BackgroundColor3 = Color3.fromRGB(28, 28, 28)
    frame.BorderSizePixel = 0
    frame.Visible = false

    local moneyButton = Instance.new("TextButton")
    moneyButton.Name = "MoneyButton"
    moneyButton.Size = UDim2.new(0.48, -10, 0, 48)
    moneyButton.Position = UDim2.new(0, 10, 0, 16)
    moneyButton.BackgroundColor3 = Color3.fromRGB(60, 160, 80)
    moneyButton.BorderSizePixel = 0
    moneyButton.Font = Enum.Font.GothamBold
    moneyButton.TextSize = 18
    moneyButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    moneyButton.Text = "Comprar"
    moneyButton.Parent = frame

    local moneyPrice = Instance.new("TextLabel")
    moneyPrice.Name = "Price"
    moneyPrice.Font = Enum.Font.Gotham
    moneyPrice.TextSize = 16
    moneyPrice.TextColor3 = Color3.fromRGB(255, 255, 255)
    moneyPrice.BackgroundTransparency = 1
    moneyPrice.Position = UDim2.new(0, 0, 1, -18)
    moneyPrice.Size = UDim2.new(1, 0, 0, 18)
    moneyPrice.Text = "0"
    moneyPrice.Parent = moneyButton

    local robuxButton = moneyButton:Clone()
    robuxButton.Name = "RobuxButton"
    robuxButton.Position = UDim2.new(0.52, 0, 0, 16)
    robuxButton.BackgroundColor3 = Color3.fromRGB(0, 170, 0)
    robuxButton.Text = "Comprar Robux"
    robuxButton.Parent = frame

    local robuxPrice = robuxButton:FindFirstChild("Price") :: TextLabel
    if robuxPrice then
        robuxPrice.Text = "nil"
    end

    return frame
end

local function createGunBuildingTemplate()
    local frame = Instance.new("Frame")
    frame.Name = "GunBuilding"
    frame.Size = UDim2.new(1, -10, 0, 150)
    frame.BackgroundColor3 = Color3.fromRGB(32, 32, 32)
    frame.BorderSizePixel = 0
    frame.Visible = true

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Name = "Name"
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextSize = 22
    nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.BackgroundTransparency = 1
    nameLabel.Position = UDim2.new(0, 16, 0, 10)
    nameLabel.Size = UDim2.new(0.6, -16, 0, 26)
    nameLabel.Text = "Gun"
    nameLabel.Parent = frame

    local priceLabel = Instance.new("TextLabel")
    priceLabel.Name = "Price"
    priceLabel.Font = Enum.Font.Gotham
    priceLabel.TextSize = 18
    priceLabel.TextColor3 = Color3.fromRGB(230, 230, 120)
    priceLabel.TextXAlignment = Enum.TextXAlignment.Left
    priceLabel.BackgroundTransparency = 1
    priceLabel.Position = UDim2.new(0, 16, 0, 42)
    priceLabel.Size = UDim2.new(0.4, -16, 0, 22)
    priceLabel.Text = "0"
    priceLabel.Parent = frame

    local statsFrame = Instance.new("Frame")
    statsFrame.Name = "Stats"
    statsFrame.BackgroundTransparency = 1
    statsFrame.Position = UDim2.new(0, 16, 0, 68)
    statsFrame.Size = UDim2.new(0.6, -16, 0, 64)
    statsFrame.Parent = frame

    local bulletsLabel = Instance.new("TextLabel")
    bulletsLabel.Name = "Bullets"
    bulletsLabel.Font = Enum.Font.Gotham
    bulletsLabel.TextSize = 16
    bulletsLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
    bulletsLabel.TextXAlignment = Enum.TextXAlignment.Left
    bulletsLabel.BackgroundTransparency = 1
    bulletsLabel.Position = UDim2.new(0, 0, 0, 0)
    bulletsLabel.Size = UDim2.new(1, 0, 0, 20)
    bulletsLabel.Text = "Balas: 0"
    bulletsLabel.Parent = statsFrame

    local damageLabel = Instance.new("TextLabel")
    damageLabel.Name = "Damage"
    damageLabel.Font = Enum.Font.Gotham
    damageLabel.TextSize = 16
    damageLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
    damageLabel.TextXAlignment = Enum.TextXAlignment.Left
    damageLabel.BackgroundTransparency = 1
    damageLabel.Position = UDim2.new(0, 0, 0, 18)
    damageLabel.Size = UDim2.new(1, 0, 0, 20)
    damageLabel.Text = "Daño: 0"
    damageLabel.Parent = statsFrame

    local cooldownLabel = Instance.new("TextLabel")
    cooldownLabel.Name = "Cooldown"
    cooldownLabel.Font = Enum.Font.Gotham
    cooldownLabel.TextSize = 16
    cooldownLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
    cooldownLabel.TextXAlignment = Enum.TextXAlignment.Left
    cooldownLabel.BackgroundTransparency = 1
    cooldownLabel.Position = UDim2.new(0, 0, 0, 36)
    cooldownLabel.Size = UDim2.new(1, 0, 0, 20)
    cooldownLabel.Text = "Cooldown: 0s"
    cooldownLabel.Parent = statsFrame

    local reloadLabel = Instance.new("TextLabel")
    reloadLabel.Name = "Reload"
    reloadLabel.Font = Enum.Font.Gotham
    reloadLabel.TextSize = 16
    reloadLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
    reloadLabel.TextXAlignment = Enum.TextXAlignment.Left
    reloadLabel.BackgroundTransparency = 1
    reloadLabel.Position = UDim2.new(0, 0, 0, 54)
    reloadLabel.Size = UDim2.new(1, 0, 0, 20)
    reloadLabel.Text = "Reload: 0s"
    reloadLabel.Parent = statsFrame

    local imageHolder = Instance.new("ImageLabel")
    imageHolder.Name = "Image"
    imageHolder.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
    imageHolder.BorderSizePixel = 0
    imageHolder.Size = UDim2.new(0, 80, 0, 80)
    imageHolder.Position = UDim2.new(1, -96, 0, 16)
    imageHolder.ImageColor3 = Color3.fromRGB(255, 255, 255)
    imageHolder.ScaleType = Enum.ScaleType.Fit
    imageHolder.Parent = frame

    local buyButton = Instance.new("TextButton")
    buyButton.Name = "BuyButton"
    buyButton.Size = UDim2.new(0, 120, 0, 32)
    buyButton.Position = UDim2.new(0, 16, 1, -40)
    buyButton.BackgroundColor3 = Color3.fromRGB(60, 160, 80)
    buyButton.BorderSizePixel = 0
    buyButton.Font = Enum.Font.GothamBold
    buyButton.TextSize = 18
    buyButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    buyButton.Text = "Comprar"
    buyButton.Parent = frame

    local robuxButton = buyButton:Clone()
    robuxButton.Name = "RobuxButton"
    robuxButton.Position = UDim2.new(0, 152, 1, -40)
    robuxButton.BackgroundColor3 = Color3.fromRGB(0, 170, 0)
    robuxButton.Text = "Robux"
    robuxButton.Parent = frame

    return frame
end

local designRoot = ReplicatedStorage:FindFirstChild("Design")
local uiFolder = designRoot and designRoot:FindFirstChild("UIs")

local chestTemplateSource = if uiFolder then uiFolder:FindFirstChild("Chest") else nil
local buyTemplateSource = if uiFolder then uiFolder:FindFirstChild("Buy") else nil
local gunTemplateSource = if uiFolder then uiFolder:FindFirstChild("GunBuildingsUI") else nil

if not chestTemplateSource then
    warn("Chest template not found in ReplicatedStorage.Design.UIs; using fallback")
    chestTemplateSource = createChestTemplate()
end

if not buyTemplateSource then
    warn("Buy template not found in ReplicatedStorage.Design.UIs; using fallback")
    buyTemplateSource = createBuyTemplate()
end

if not gunTemplateSource then
    warn("Gun building template not found in ReplicatedStorage.Design.UIs; using fallback")
    gunTemplateSource = createGunBuildingTemplate()
end

local storesGui = playerGui:FindFirstChild("Stores") :: ScreenGui?
if not storesGui then
    local newGui = Instance.new("ScreenGui")
    newGui.Name = "Stores"
    newGui.ResetOnSpawn = false
    newGui.IgnoreGuiInset = true
    newGui.DisplayOrder = 5
    newGui.Enabled = false
    newGui.Parent = playerGui
    storesGui = newGui
end

local storesGuiTyped = storesGui :: ScreenGui

local chestsFrame = storesGuiTyped:FindFirstChild("Chests") :: Frame?
if not chestsFrame then
    local newFrame = Instance.new("Frame")
    newFrame.Name = "Chests"
    newFrame.Size = UDim2.new(0, 420, 0, 320)
    newFrame.Position = UDim2.new(0.5, -210, 0.5, -160)
    newFrame.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
    newFrame.BackgroundTransparency = 0.15
    newFrame.BorderSizePixel = 0
    newFrame.Visible = false
    newFrame.Parent = storesGuiTyped
    chestsFrame = newFrame
end

local chestsFrameTyped = chestsFrame :: Frame

local ammoFrame = storesGuiTyped:FindFirstChild("GunBuildings") :: Frame?
if not ammoFrame then
    local newFrame = Instance.new("Frame")
    newFrame.Name = "GunBuildings"
    newFrame.Size = UDim2.new(0, 460, 0, 360)
    newFrame.Position = UDim2.new(0.5, -230, 0.5, -180)
    newFrame.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
    newFrame.BackgroundTransparency = 0.15
    newFrame.BorderSizePixel = 0
    newFrame.Visible = false
    newFrame.Parent = storesGuiTyped
    ammoFrame = newFrame
end

local ammoFrameTyped = ammoFrame :: Frame

local function updateGuiEnabled()
    storesGuiTyped.Enabled = chestsFrameTyped.Visible or ammoFrameTyped.Visible
end

local closeButton = chestsFrameTyped:FindFirstChild("CloseButton") :: TextButton?
if not closeButton then
    local button = Instance.new("TextButton")
    button.Name = "CloseButton"
    button.Size = UDim2.fromOffset(28, 28)
    button.AnchorPoint = Vector2.new(1, 0)
    button.Position = UDim2.new(1, -12, 0, 12)
    button.Text = "X"
    button.Font = Enum.Font.GothamBold
    button.TextSize = 18
    button.TextColor3 = Color3.fromRGB(255, 255, 255)
    button.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
    button.BorderSizePixel = 0
    button.AutoButtonColor = true
    button.ZIndex = 2
    button.Parent = chestsFrameTyped
    closeButton = button
end

local ammoCloseButton = ammoFrameTyped:FindFirstChild("CloseButton") :: TextButton?
if not ammoCloseButton then
    local button = Instance.new("TextButton")
    button.Name = "CloseButton"
    button.Size = UDim2.fromOffset(28, 28)
    button.AnchorPoint = Vector2.new(1, 0)
    button.Position = UDim2.new(1, -12, 0, 12)
    button.Text = "X"
    button.Font = Enum.Font.GothamBold
    button.TextSize = 18
    button.TextColor3 = Color3.fromRGB(255, 255, 255)
    button.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
    button.BorderSizePixel = 0
    button.AutoButtonColor = true
    button.ZIndex = 2
    button.Parent = ammoFrameTyped
    ammoCloseButton = button
end

local listFrame = chestsFrameTyped:FindFirstChild("ScrollingFrame") :: ScrollingFrame?
if not listFrame then
    local newList = Instance.new("ScrollingFrame")
    newList.Name = "ScrollingFrame"
    newList.Size = UDim2.new(1, -20, 1, -20)
    newList.Position = UDim2.new(0, 10, 0, 10)
    newList.CanvasSize = UDim2.new(0, 0, 0, 0)
    newList.AutomaticCanvasSize = Enum.AutomaticSize.Y
    newList.ScrollBarThickness = 6
    newList.BackgroundTransparency = 1
    newList.BorderSizePixel = 0
    newList.Parent = chestsFrameTyped
    listFrame = newList
end

local listFrameTyped = listFrame :: ScrollingFrame

if not listFrameTyped:FindFirstChildOfClass("UIListLayout") then
    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 6)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = listFrameTyped
end

local ammoListFrame = ammoFrameTyped:FindFirstChild("ScrollingFrame") :: ScrollingFrame?
if not ammoListFrame then
    local newList = Instance.new("ScrollingFrame")
    newList.Name = "ScrollingFrame"
    newList.Size = UDim2.new(1, -20, 1, -60)
    newList.Position = UDim2.new(0, 10, 0, 44)
    newList.CanvasSize = UDim2.new(0, 0, 0, 0)
    newList.AutomaticCanvasSize = Enum.AutomaticSize.Y
    newList.ScrollBarThickness = 6
    newList.BackgroundTransparency = 1
    newList.BorderSizePixel = 0
    newList.Parent = ammoFrameTyped
    ammoListFrame = newList
end

local ammoListFrameTyped = ammoListFrame :: ScrollingFrame

if not ammoListFrameTyped:FindFirstChildOfClass("UIListLayout") then
    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 8)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = ammoListFrameTyped
end

local openPacket = ChestPackets.Open
local closePacket = ChestPackets.Close
local moneyPacket = ChestPackets.MoneyPurchase
local robuxPacket = ChestPackets.RobuxPurchase

local ammoOpenPacket = AmmoBuildingPackets.Open
local ammoClosePacket = AmmoBuildingPackets.Close
local ammoMoneyPacket = AmmoBuildingPackets.MoneyPurchase
local ammoRobuxPacket = AmmoBuildingPackets.RobuxPurchase

type ChestPayload = {
    name: string,
    price: number,
    lucky: number,
    time: number,
    image: string,
    robuxProduct: number,
    layoutOrder: number,
}

type GunBuildingPayload = {
    id: string,
    name: string,
    price: number,
    robuxProduct: number,
    image: string,
    bullets: number,
    damage: number,
    cooldown: number,
    reloadTime: number,
    layoutOrder: number,
}

local chestConnections: { RBXScriptConnection } = {}
local currentSelection: ChestPayload? = nil

local ammoConnections: { RBXScriptConnection } = {}

local closeChestUI
local closeAmmoUI

local buyFrame = (buyTemplateSource:Clone()) :: Frame
buyFrame.Name = "BuyPanel"
buyFrame.Visible = false
buyFrame:SetAttribute("ChestBuyPanel", true)
buyFrame.Parent = listFrameTyped

local moneyButton = buyFrame:WaitForChild("MoneyButton") :: TextButton
local robuxButton = buyFrame:WaitForChild("RobuxButton") :: TextButton
local moneyPrice = moneyButton:WaitForChild("Price") :: TextLabel
local robuxPrice = robuxButton:WaitForChild("Price") :: TextLabel

local function disconnectChestConnections()
    for _, connection in chestConnections do
        connection:Disconnect()
    end
    table.clear(chestConnections)
end

local function clearChestEntries()
    disconnectChestConnections()
    for _, child in listFrameTyped:GetChildren() do
        if child ~= buyFrame and child:GetAttribute("ChestEntry") then
            child:Destroy()
        end
    end
    currentSelection = nil
    buyFrame.Visible = false
end

local function disconnectAmmoConnections()
    for _, connection in ammoConnections do
        connection:Disconnect()
    end
    table.clear(ammoConnections)
end

local function clearGunEntries()
    disconnectAmmoConnections()
    for _, child in ammoListFrameTyped:GetChildren() do
        if child:GetAttribute("GunEntry") then
            child:Destroy()
        end
    end
end

local function setButtonState(button: TextButton, enabled: boolean)
    button.AutoButtonColor = enabled
    button.Active = enabled
    button.Selectable = enabled
    if not enabled then
        button.BackgroundTransparency = 0.5
    else
        button.BackgroundTransparency = 0
    end
end

local function formatLucky(value: number): string
    if math.floor(value) == value then
        return string.format("%dx", value)
    end
    return string.format("%.2fx", value)
end

local function formatTime(value: number): string
    if math.floor(value) == value then
        return string.format("%ds", value)
    end
    return string.format("%.1fs", value)
end

local function formatStat(value: number): string
    if math.floor(value) == value then
        return tostring(value)
    end
    return string.format("%.2f", value)
end

local function formatSecondsValue(value: number): string
    if math.floor(value) == value then
        return string.format("%ds", value)
    end
    return string.format("%.2fs", value)
end

local function decorateChestButton(button: TextButton, data: ChestPayload, layoutOrder: number)
    button.Name = `Chest_{data.name}`
    button.LayoutOrder = layoutOrder
    button.Visible = true
    button:SetAttribute("ChestEntry", true)
    button:SetAttribute("ChestName", data.name)

    local chestName = button:FindFirstChild("ChestName")
    if chestName and chestName:IsA("TextLabel") then
        chestName.Text = data.name
    end

    local priceLabel = button:FindFirstChild("Price")
    if priceLabel and priceLabel:IsA("TextLabel") then
        priceLabel.Text = tostring(data.price)
    end

    local luckyLabel = button:FindFirstChild("Lucky")
    if luckyLabel and luckyLabel:IsA("TextLabel") then
        luckyLabel.Text = formatLucky(data.lucky)
    end

    local timeLabel = button:FindFirstChild("Time")
    if timeLabel and timeLabel:IsA("TextLabel") then
        timeLabel.Text = formatTime(data.time)
    end

    local imageLabel = button:FindFirstChild("Image")
    if imageLabel and imageLabel:IsA("ImageLabel") then
        imageLabel.Image = data.image or ""
    end
end

local function decorateGunEntry(frame: Frame, data: GunBuildingPayload, layoutOrder: number)
    frame.Name = `Gun_{data.id}`
    frame.LayoutOrder = layoutOrder
    frame.Visible = true
    frame:SetAttribute("GunEntry", true)
    frame:SetAttribute("GunId", data.id)

    local nameLabel = frame:FindFirstChild("Name")
    if nameLabel and nameLabel:IsA("TextLabel") then
        nameLabel.Text = data.name
    end

    local priceLabel = frame:FindFirstChild("Price")
    if priceLabel and priceLabel:IsA("TextLabel") then
        priceLabel.Text = tostring(data.price)
    end

    local statsFrame = frame:FindFirstChild("Stats")
    if statsFrame and statsFrame:IsA("Frame") then
        local bulletsLabel = statsFrame:FindFirstChild("Bullets")
        if bulletsLabel and bulletsLabel:IsA("TextLabel") then
            bulletsLabel.Text = "Balas: " .. formatStat(data.bullets)
        end

        local damageLabel = statsFrame:FindFirstChild("Damage")
        if damageLabel and damageLabel:IsA("TextLabel") then
            damageLabel.Text = "Daño: " .. formatStat(data.damage)
        end

        local cooldownLabel = statsFrame:FindFirstChild("Cooldown")
        if cooldownLabel and cooldownLabel:IsA("TextLabel") then
            cooldownLabel.Text = "Cooldown: " .. formatSecondsValue(data.cooldown)
        end

        local reloadLabel = statsFrame:FindFirstChild("Reload")
        if reloadLabel and reloadLabel:IsA("TextLabel") then
            reloadLabel.Text = "Recarga: " .. formatSecondsValue(data.reloadTime)
        end
    end

    local imageLabel = frame:FindFirstChild("Image")
    if imageLabel and imageLabel:IsA("ImageLabel") then
        imageLabel.Image = data.image or ""
    end

    local buyButton = frame:FindFirstChild("BuyButton")
    if buyButton and buyButton:IsA("TextButton") then
        buyButton:SetAttribute("GunId", data.id)
        setButtonState(buyButton, true)
    end

    local robuxButton = frame:FindFirstChild("RobuxButton")
    if robuxButton and robuxButton:IsA("TextButton") then
        if data.robuxProduct and data.robuxProduct > 0 then
            robuxButton.Visible = true
            robuxButton:SetAttribute("GunId", data.id)
            robuxButton:SetAttribute("RobuxProduct", data.robuxProduct)
            setButtonState(robuxButton, true)
        else
            robuxButton.Visible = false
            setButtonState(robuxButton, false)
        end
    end
end

local function populateGunBuildings(buildings: {GunBuildingPayload})
    clearGunEntries()

    local sorted = table.clone(buildings)
    table.sort(sorted, function(a, b)
        if a.price == b.price then
            return a.name < b.name
        end
        return a.price < b.price
    end)

    ammoListFrameTyped.CanvasPosition = Vector2.new(0, 0)

    for index, data in ipairs(sorted) do
        local entry = (gunTemplateSource:Clone()) :: Frame
        decorateGunEntry(entry, data, index * 10)
        entry.Parent = ammoListFrameTyped

        local buyButton = entry:FindFirstChild("BuyButton")
        if buyButton and buyButton:IsA("TextButton") then
            local connection = buyButton.MouseButton1Click:Connect(function()
                if buyButton.Parent == nil then
                    return
                end

                setButtonState(buyButton, false)
                task.spawn(function()
                    local success, message = ammoMoneyPacket:Fire(data.id)
                    if success then
                        print(message or "Comprado")
                    else
                        warn(message or "Compra rechazada")
                    end
                    if buyButton.Parent then
                        setButtonState(buyButton, true)
                    end
                end)
            end)
            ammoConnections[#ammoConnections + 1] = connection
        end

        local robuxButton = entry:FindFirstChild("RobuxButton")
        if robuxButton and robuxButton:IsA("TextButton") and robuxButton.Visible then
            local connection = robuxButton.MouseButton1Click:Connect(function()
                if robuxButton.Parent == nil then
                    return
                end

                setButtonState(robuxButton, false)
                task.spawn(function()
                    local success, message = ammoRobuxPacket:Fire(data.id)
                    if not success then
                        warn(message or "No se pudo iniciar la compra")
                    end
                    if robuxButton.Parent then
                        setButtonState(robuxButton, true)
                    end
                end)
            end)
            ammoConnections[#ammoConnections + 1] = connection
        end
    end
end

local function updateBuyPanel(selection: ChestPayload, sourceButton: TextButton)
    currentSelection = selection

    buyFrame.LayoutOrder = sourceButton.LayoutOrder + 5
    buyFrame.Visible = true

    moneyPrice.Text = tostring(selection.price)
    moneyButton:SetAttribute("ChestName", selection.name)

    if selection.robuxProduct and selection.robuxProduct > 0 then
        robuxPrice.Text = tostring(selection.robuxProduct)
        setButtonState(robuxButton, true)
        robuxButton:SetAttribute("ChestName", selection.name)
        robuxButton:SetAttribute("RobuxProduct", selection.robuxProduct)
    else
        robuxPrice.Text = "nil"
        setButtonState(robuxButton, false)
        robuxButton:SetAttribute("ChestName", selection.name)
        robuxButton:SetAttribute("RobuxProduct", 0)
    end
end

local function onChestButtonClicked(button: TextButton, data: ChestPayload)
    updateBuyPanel(data, button)
end

local function populateChests(chests: {ChestPayload})
    clearChestEntries()

    local sorted = table.clone(chests)

    table.sort(sorted, function(a, b)
        if a.price == b.price then
            return a.name < b.name
        end
        return a.price < b.price
    end)

    for index, data in ipairs(sorted) do
        local button = (chestTemplateSource:Clone()) :: TextButton
        decorateChestButton(button, data, index * 10)
        button.Parent = listFrameTyped

        local connection = button.MouseButton1Click:Connect(function()
            onChestButtonClicked(button, data)
        end)
        chestConnections[#chestConnections + 1] = connection
    end
end

closeChestUI = function()
    buyFrame.Visible = false
    currentSelection = nil
    chestsFrameTyped.Visible = false
    updateGuiEnabled()
end

closeAmmoUI = function()
    ammoFrameTyped.Visible = false
    updateGuiEnabled()
end

local function openChestUI(payload)
    local chests = payload and payload.chests
    if typeof(chests) ~= "table" then
        warn("Invalid chest payload")
        return
    end

    closeAmmoUI()
    populateChests(chests :: {ChestPayload})
    chestsFrameTyped.Visible = true
    updateGuiEnabled()
end

local function openAmmoUI(payload)
    local buildings = payload and payload.buildings
    if typeof(buildings) ~= "table" then
        warn("Invalid ammo building payload")
        return
    end

    closeChestUI()
    populateGunBuildings(buildings :: {GunBuildingPayload})
    ammoFrameTyped.Visible = true
    updateGuiEnabled()
end

if closeButton then
    closeButton.MouseButton1Click:Connect(function()
        closeChestUI()
        closePacket:Fire()
    end)
end

if ammoCloseButton then
    ammoCloseButton.MouseButton1Click:Connect(function()
        closeAmmoUI()
        ammoClosePacket:Fire()
    end)
end

    moneyButton.MouseButton1Click:Connect(function()
        local selection = currentSelection
        if not selection then
            return
        end

        task.spawn(function()
            local success, message = moneyPacket:Fire(selection.name)
            if success then
                print(message or "Comprado")
            else
                warn(message or "Compra rechazada")
            end
        end)
    end)

    robuxButton.MouseButton1Click:Connect(function()
        local selection = currentSelection
        if not selection then
            return
        end

        local productId = robuxButton:GetAttribute("RobuxProduct")
        if typeof(productId) ~= "number" or productId <= 0 then
            warn("No Robux product configured for this chest")
            return
        end

        task.spawn(function()
            local success, message = robuxPacket:Fire(selection.name)
            if not success then
                warn(message or "No se pudo iniciar la compra")
            end
        end)
    end)

openPacket.OnClientEvent:Connect(openChestUI)
closePacket.OnClientEvent:Connect(closeChestUI)
ammoOpenPacket.OnClientEvent:Connect(openAmmoUI)
ammoClosePacket.OnClientEvent:Connect(closeAmmoUI)

buyFrame.Visible = false
closeChestUI()
closeAmmoUI()