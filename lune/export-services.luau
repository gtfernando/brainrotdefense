-- lune run export-services
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local process = require("@lune/process")

local okStdio, stdio = pcall(require, "@lune/stdio")
if not okStdio then
	stdio = nil
end

local function formatMessage(fmt, ...)
	if select("#", ...) == 0 then
		return fmt
	end
	return string.format(fmt, ...)
end

local function logInfo(fmt, ...)
	local message = formatMessage(fmt, ...)
	if stdio and stdio.stdout and stdio.stdout.write then
		stdio.stdout:write(message .. "\n")
	else
		print(message)
	end
end

local function logWarn(fmt, ...)
	local message = formatMessage(fmt, ...)
	if stdio and stdio.stderr and stdio.stderr.write then
		stdio.stderr:write(message .. "\n")
	else
		warn(message)
	end
end

local function logErrorAndExit(fmt, ...)
	logWarn(fmt, ...)
	process.exit(1)
end

local PLACE_DEFAULT = "build.rbxl"

local SCRIPT_HANDLERS = {
	ModuleScript = {
		extension = ".lua",
		initFile = "init.lua",
	},
	Script = {
		extension = ".server.lua",
		initFile = "init.server.lua",
	},
	LocalScript = {
		extension = ".client.lua",
		initFile = "init.client.lua",
	},
}

local INVALID_CHAR_PATTERN = "[%c%z<>:\"/\\|%?%*]"

local function sanitizeName(name)
	local sanitized = name:gsub(INVALID_CHAR_PATTERN, "_")
	sanitized = sanitized:gsub("^%s+", ""):gsub("%s+$", "")
	sanitized = sanitized:gsub("%s+", " ")
	sanitized = sanitized:gsub("%.$", "")
	if sanitized == "" then
		sanitized = "UnnamedInstance"
	end
	return sanitized
end

local function ensureDir(path)
	if fs.isDir(path) then
		return
	end

	local current = ""
	for segment in path:gmatch("[^/]+") do
		current = current == "" and segment or (current .. "/" .. segment)
		if not fs.isDir(current) then
			fs.writeDir(current)
		end
	end
end

local function clearDir(path)
	if fs.isDir(path) then
		for _, entry in ipairs(fs.readDir(path)) do
			local fullPath = string.format("%s/%s", path, entry)
			if fs.isDir(fullPath) then
				fs.removeDir(fullPath)
			else
				fs.removeFile(fullPath)
			end
		end
	elseif fs.isFile(path) then
		fs.removeFile(path)
	end
end

local usedNames = {}

local function reserveName(dir, base, suffix)
	local perDir = usedNames[dir]
	if not perDir then
		perDir = {}
		usedNames[dir] = perDir
	end

	local candidate = base
	local index = 1
	while perDir[candidate .. suffix] do
		index += 1
		candidate = string.format("%s_%d", base, index)
	end

	perDir[candidate .. suffix] = true
	return candidate
end

local stats = {
	scripts = 0,
	models = 0,
	folders = 0,
	services = {},
}

local meshWarnings = {}

local function getInstancePath(instance)
	local path = {}
	local current = instance
	while current do
		table.insert(path, 1, current.Name ~= "" and current.Name or string.format("[%s]", current.ClassName))
		current = current.Parent
		if not current or current:IsA("DataModel") then
			break
		end
	end
	return table.concat(path, ".")
end

local function warnMeshContent(instance, serviceName, reason)
	local entry = string.format("%s -> %s: %s", serviceName, getInstancePath(instance), reason)
	table.insert(meshWarnings, entry)
end

local function recordServiceExport(serviceName)
	stats.services[serviceName] = (stats.services[serviceName] or 0) + 1
end

local exportInstance

local function exportChildren(container, targetDir, serviceName)
	ensureDir(targetDir)

	for _, child in container:GetChildren() do
		exportInstance(child, targetDir, serviceName)
	end
end

exportInstance = function(instance, targetDir, serviceName)
	local baseName = sanitizeName(instance.Name)

	if instance:IsA("Folder") then
		local uniqueName = reserveName(targetDir, baseName, "/")
		local folderPath = string.format("%s/%s", targetDir, uniqueName)
		ensureDir(folderPath)
		stats.folders += 1
		recordServiceExport(serviceName)
		exportChildren(instance, folderPath, serviceName)
		return
	end

	local scriptHandler = SCRIPT_HANDLERS[instance.ClassName]
	if scriptHandler then
		local children = instance:GetChildren()
		local hasChildren = #children > 0

		if hasChildren then
			local folderName = reserveName(targetDir, baseName, "/")
			local folderPath = string.format("%s/%s", targetDir, folderName)
			ensureDir(folderPath)
			stats.folders += 1
			recordServiceExport(serviceName)

			local scriptPath = string.format("%s/%s", folderPath, scriptHandler.initFile)
			fs.writeFile(scriptPath, instance.Source or "")
			stats.scripts += 1
			recordServiceExport(serviceName)

			exportChildren(instance, folderPath, serviceName)
		else
			local uniqueName = reserveName(targetDir, baseName, scriptHandler.extension)
			local filePath = string.format("%s/%s%s", targetDir, uniqueName, scriptHandler.extension)
			fs.writeFile(filePath, instance.Source or "")
			stats.scripts += 1
			recordServiceExport(serviceName)
		end

		return
	end

	if instance:IsA("MeshPart") then
		local meshId = instance.MeshId
		if type(meshId) ~= "string" or meshId == "" then
			warnMeshContent(instance, serviceName, "MeshPart has no MeshId; Studio will show a block")
		elseif meshId:match("^rbxasset://") then
			warnMeshContent(instance, serviceName, "MeshPart uses a local MeshId (rbxasset://); export a .mesh file or upload the asset")
		end
	elseif instance:IsA("UnionOperation") then
		local assetId = instance.AssetId
		if type(assetId) ~= "string" or assetId == "" then
			warnMeshContent(instance, serviceName, "UnionOperation is missing AssetId; sync will show a block")
		elseif assetId:match("^rbxasset://") then
			warnMeshContent(instance, serviceName, "UnionOperation uses local AssetId; publish the union or convert to mesh")
		end
	elseif instance:IsA("SpecialMesh") then
		local meshId = instance.MeshId
		if type(meshId) ~= "string" or meshId == "" then
			warnMeshContent(instance, serviceName, "SpecialMesh has no MeshId")
		elseif meshId:match("^rbxasset://") then
			warnMeshContent(instance, serviceName, "SpecialMesh uses local MeshId; consider exporting .mesh and .mtl files")
		end
	end

	local uniqueName = reserveName(targetDir, baseName, ".rbxmx")
	local modelPath = string.format("%s/%s.rbxmx", targetDir, uniqueName)
	local serialized = roblox.serializeModel({ instance }, true)
	fs.writeFile(modelPath, serialized)
	stats.models += 1
	recordServiceExport(serviceName)
end

local SERVICE_TARGETS = {
	{
		name = "ReplicatedStorage",
		target = "src/ReplicatedStorage",
		resolver = function(game)
			return game:GetService("ReplicatedStorage")
		end,
	},
	{
		name = "ReplicatedFirst",
		target = "src/ReplicatedFirst",
		resolver = function(game)
			return game:GetService("ReplicatedFirst")
		end,
	},
	{
		name = "ServerScriptService",
		target = "src/ServerScriptService",
		resolver = function(game)
			return game:GetService("ServerScriptService")
		end,
	},
	{
		name = "StarterGui",
		target = "src/StarterGui",
		resolver = function(game)
			return game:GetService("StarterGui")
		end,
	},
	{
		name = "StarterPack",
		target = "src/StarterPack",
		resolver = function(game)
			return game:GetService("StarterPack")
		end,
	},
	{
		name = "StarterPlayerScripts",
		target = "src/StarterPlayerScripts",
		resolver = function(game)
			local starterPlayer = game:GetService("StarterPlayer")
			return starterPlayer and starterPlayer:FindFirstChild("StarterPlayerScripts")
		end,
	},
}

local args = process.args
local placePath = PLACE_DEFAULT
if #args > 0 then
	placePath = args[1]
end

logInfo("Reading place file: %s", placePath)

if not fs.isFile(placePath) then
	logErrorAndExit("Place file not found at %s", placePath)
end

local ok, placeContents = pcall(fs.readFile, placePath)
if not ok then
	logErrorAndExit("Failed to read %s: %s", placePath, placeContents)
end

local okDeserialize, game = pcall(roblox.deserializePlace, placeContents)
if not okDeserialize then
	logErrorAndExit("Failed to deserialize place file: %s", game)
end

for _, target in ipairs(SERVICE_TARGETS) do
	local service = target.resolver(game)
	if not service then
		logWarn("Warning: service %s not found in place file", target.name)
	else
		clearDir(target.target)
		ensureDir(target.target)

		exportChildren(service, target.target, target.name)

		local count = stats.services[target.name] or 0
		logInfo("✔ Exported %d items from %s -> %s", count, target.name, target.target)
	end
end

logInfo("")
logInfo("Summary:")
logInfo("  Scripts: %d", stats.scripts)
logInfo("  Models/instances: %d", stats.models)
logInfo("  Folders: %d", stats.folders)

if #meshWarnings > 0 then
	logWarn("")
	logWarn("Mesh/content warnings (manual action recommended):")
	for _, message in ipairs(meshWarnings) do
		logWarn("  - %s", message)
	end
end
