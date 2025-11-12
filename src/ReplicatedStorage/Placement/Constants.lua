local Constants = {
	CELL_SIZE = 5,
	ASSET_ROOT_NAME = "RootPart",
	DEFAULT_ROTATION_STEP = math.rad(90),
	RAYCAST_LENGTH = 512,
	PLOT = {
		GRID_CELLS = Vector2.new(20, 20),
		PLOTS_PER_ROW = 5,
		SLOT_SPACING = Vector2.new(25, 25),
		START_CFRAME = CFrame.new(0, 0, 0),
		ELEVATION = 0,
		BASE = {
			ENABLED = true,
			HEIGHT = 2,
			MATERIAL = Enum.Material.Grass,
			COLOR = Color3.fromRGB(84, 170, 95),
			NAME = "PlotBase",
		},
		BLOCKING = {
			ENABLED = true,
			TILE_CELLS = Vector2.new(4, 4), -- 4 cells * 5 studs = 20 stud tiles
			DEFAULT_LOCKED = true,
			UNLOCKED_ZONE_IDS = { 2, 3, 4, 8 },
			OVERRIDES = {},
		},
		FOLDER_NAME = "PlacementPlots",
	},
}

return Constants
