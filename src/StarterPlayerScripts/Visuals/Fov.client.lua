local Players = game:GetService("Players")
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local function applyFOV()
	camera.FieldOfView = 60
end

player.CharacterAdded:Connect(applyFOV)
task.spawn(applyFOV)