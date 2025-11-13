--!strict

export type Range = Vector2

export type CrateDefinition = {
	name: string,
	price: number,
	asset: string?,
	weight: number?,
	health: number?,
	cooldownRange: Range?,
	stayDurationRange: Range?,
	riseTime: number?,
	fallTime: number?,
	hiddenDepth: number?,
	surfaceOffset: number?,
	Rewards: { [string]: number }?,
}

export type CatalogDefaults = {
	assetFolderName: string,
	assetName: string,
	cooldownRange: Range,
	stayDurationRange: Range,
	riseTime: number,
	fallTime: number,
	hiddenDepth: number,
	surfaceOffset: number,
	initialDelayRange: Range,
	maxHealth: number,
}

export type Catalog = {
	Defaults: CatalogDefaults,
	Crates: { [string]: CrateDefinition },
}

local Catalog: Catalog = {
	Defaults = {
		assetFolderName = "Crates",
		assetName = "CrateProto",
		cooldownRange = Vector2.new(2.5, 5.0),
		stayDurationRange = Vector2.new(4.5, 6.0),
		riseTime = 0.45,
		fallTime = 0.4,
		hiddenDepth = 4,
		surfaceOffset = 0,
		initialDelayRange = Vector2.new(0.5, 2.5),
		maxHealth = 100,
	},
	Crates = {
		CrateProto = {
			name = "CrateProto",
			price = 100,
			weight = 1,
			health = 100,
			Rewards = {
				["Dominos Piza"] = 60,
				["Peper Piza"] = 40,
			},
		},
	},
}

return Catalog
