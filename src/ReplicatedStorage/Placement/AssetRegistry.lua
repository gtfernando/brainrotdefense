local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(script.Parent.Constants)

export type AssetDefinition = {
	id: string,
	model: Model,
	footprint: Vector2,
	heightOffset: number,
}

local AssetsFolder = ReplicatedStorage:WaitForChild("Assets", 5)
if not AssetsFolder then
	error("AssetRegistry requires ReplicatedStorage.Assets to exist")
end

local LevelModelsFolder = AssetsFolder:FindFirstChild("Levels")

local definitions: { [string]: AssetDefinition } = {}

local function computeFootprint(rootPart: BasePart): Vector2
	local cellSize = Constants.CELL_SIZE
	local width = math.max(1, math.round(rootPart.Size.X / cellSize))
	local depth = math.max(1, math.round(rootPart.Size.Z / cellSize))
	return Vector2.new(width, depth)
end

local function computeHeightOffset(rootPart: BasePart): number
	local pivotOffset = rootPart.PivotOffset
	local pivotOffsetY = if pivotOffset then pivotOffset.Position.Y else 0
	return rootPart.Size.Y * 0.5 + pivotOffsetY
end

local function findDirectRoot(model: Model): BasePart?
	local root = model:FindFirstChild(Constants.ASSET_ROOT_NAME)
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function ensurePrimaryPart(model: Model): BasePart?
	local root = model.PrimaryPart
	if root and root:IsA("BasePart") then
		return root
	end

	root = model:FindFirstChild(Constants.ASSET_ROOT_NAME, true)
	if root and root:IsA("BasePart") then
		model.PrimaryPart = root
		return root
	end

	return nil
end

local function indexAsset(model: Model)
	local root = findDirectRoot(model)
	if root == nil then
		error(`Asset "{model.Name}" is missing a BasePart named {Constants.ASSET_ROOT_NAME}`)
	end

	if not model.PrimaryPart then
		model.PrimaryPart = root
	end

	local definition: AssetDefinition = {
		id = model.Name,
		model = model,
		footprint = computeFootprint(root),
		heightOffset = computeHeightOffset(root),
	}

	definitions[definition.id] = definition
end

for _, descendant in AssetsFolder:GetDescendants() do
	if descendant:IsA("Model") then
		indexAsset(descendant)
	end
end

AssetsFolder.DescendantAdded:Connect(function(instance)
	if instance:IsA("Model") then
		indexAsset(instance)
	end
end)

AssetsFolder.DescendantRemoving:Connect(function(instance)
	if instance:IsA("Model") then
		definitions[instance.Name] = nil
	end
end)

local BuildingsData = nil
do
	local dataFolder = ReplicatedStorage:FindFirstChild("Data")
	if dataFolder then
		local buildingsModule = dataFolder:FindFirstChild("Buildings")
		if buildingsModule and buildingsModule:IsA("ModuleScript") then
			local ok, result = pcall(require, buildingsModule)
			if ok then
				BuildingsData = result
			end
		end
	end
end

local function resolveLevelModelName(assetId: string, level: number?): string?
	if not BuildingsData or not level or level <= 1 then
		return nil
	end

	local buildingEntry = BuildingsData[assetId]
	if typeof(buildingEntry) ~= "table" then
		return nil
	end

	local levelsTable = buildingEntry.Level or buildingEntry.level
	if typeof(levelsTable) ~= "table" then
		return nil
	end

	local levelEntry = levelsTable[level]
	if typeof(levelEntry) ~= "table" then
		return nil
	end

	local modelName = levelEntry.Model or levelEntry.model
	if typeof(modelName) ~= "string" or modelName == "" then
		return nil
	end

	return modelName
end

local function findLevelModel(name: string?): Model?
	if not name or name == "" then
		return nil
	end

	if not LevelModelsFolder then
		return nil
	end

	local direct = LevelModelsFolder:FindFirstChild(name)
	if direct and direct:IsA("Model") then
		return direct
	end

	local descendant = LevelModelsFolder:FindFirstChild(name, true)
	if descendant and descendant:IsA("Model") then
		return descendant
	end

	return nil
end

local function prepareClone(model: Model)
	local root = ensurePrimaryPart(model)
	if not root then
		warn(`Asset clone "{model.Name}" lacks {Constants.ASSET_ROOT_NAME}; pivot may be incorrect`)
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end
end

local AssetRegistry = {}

function AssetRegistry.Get(assetId: string): AssetDefinition
	local definition = definitions[assetId]
	if not definition then
		error(`Unknown asset id "{assetId}"`)
	end
	return definition
end

function AssetRegistry.GetAll(): { AssetDefinition }
	local list = {}
	for _, definition in definitions do
		list[#list + 1] = definition
	end
	return list
end

function AssetRegistry.Clone(assetId: string, level: number?): Model
	local definition = AssetRegistry.Get(assetId)
	local sourceModel: Model = definition.model

	local resolvedLevel = nil
	if typeof(level) == "number" then
		resolvedLevel = math.max(1, math.floor(level + 0.5))
	end

	local alternativeName = resolveLevelModelName(assetId, resolvedLevel)
	if alternativeName then
		local levelModel = findLevelModel(alternativeName)
		if levelModel then
			sourceModel = levelModel
		else
			warn(`AssetRegistry: Missing level model "{alternativeName}" for asset "{assetId}" (level {resolvedLevel or "?"})`)
		end
	end

	local clone = sourceModel:Clone()
	prepareClone(clone)

	return clone
end

return AssetRegistry
