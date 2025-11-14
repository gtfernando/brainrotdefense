--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BrainrotData = require(ReplicatedStorage.Data.Brainrots)

--[[
	WAVE CUSTOMIZATION NOTES
	1. Puedes cambiar los tipos de brainrots disponibles editando `Brainrots.lua` (lista `Order` y stats).
	2. Las waves 1-4 estan definidas manualmente en `BASE_WAVES`; modifica `label`, `groups` y `rewardMultiplier` alli para personalizar cada oleada.
	3. A partir de la wave 5, `inflateWave` genera el patron automaticamente; ajusta `primaryCount`, `secondaryCount`, `tertiaryCount` o las formulas si quieres otro ritmo.
	4. Cada entrada de `groups` acepta:
	   - `brainrot`: nombre tal cual aparece en `Brainrots.lua`.
	   - `count`: total de unidades que saldran (se redondea al entero mas cercano).
	   - `interval`: segundos entre spawns dentro de ese grupo (usa valores pequenos para spam rapido).
	   - `spawnDelay`: segundos que espera el grupo antes de empezar (util para minibosses tardios).
	   - `burst = true`: ignora `interval` y spawnea todo instantaneo.
	5. `skipThreshold` controla que porcentaje de la wave debe morir para poder saltarla (0.75 = 75%).
	6. `rewardMultiplier` multiplica el dinero base que sueltan los brainrots en esa wave.
	7. EJEMPLOS PRODUCCION:
	   - **Wave Temprana (sprinters + miniboss):**
	       ```
	       BASE_WAVES[2] = {
	           index = 2,
	           label = "Presion Temprana",
	           groups = {
	               { brainrot = "GangsterFootera", count = 5, interval = 1.0 },
	               { brainrot = "BrriBrriBicusDicusBombicus", count = 1, spawnDelay = 6, interval = 2.2 },
	           },
	           skipThreshold = 0.8,
	           rewardMultiplier = 1.15,
	       }
	       ```
	   - **Wave Media (boss doble fase):**
	       ```
	       BASE_WAVES[6] = {
	           index = 6,
	           label = "Guardianes Gemelos",
	           groups = {
	               { brainrot = "GangsterFootera", count = 8, interval = 0.7 },
	               { brainrot = "EventoColoso", count = 1, spawnDelay = 10, burst = true },
	               { brainrot = "EventoColoso", count = 1, spawnDelay = 20, burst = true },
	           },
	           skipThreshold = 0.9,
	           rewardMultiplier = 1.6,
	       }
	       ```
	   - **Wave Infinita (auto-generada):**
	       Ajusta la formula en `inflateWave` si quieres que a partir de la wave 10 solo aparezcan bosses.
	       Por ejemplo, si `primaryCount = 2` y `secondaryCount = 1` y siempre apuntas a nombres de bosses,
	       tendras un flujo constante de jefes.
]]

export type WaveSpawnGroup = {
	brainrot: string,
	count: number,
	interval: number?,
	spawnDelay: number?,
	burst: boolean?,
}

export type WaveConfig = {
	index: number,
	label: string?,
	groups: { WaveSpawnGroup },
	skipThreshold: number?,
	rewardMultiplier: number?,
}

local DEFAULT_SKIP_THRESHOLD = 0.75
local DEFAULT_INTERVAL = 1.25

local function deepCopyGroup(group: WaveSpawnGroup): WaveSpawnGroup
	return {
		brainrot = group.brainrot,
		count = math.max(1, math.floor(group.count + 0.5)),
		interval = group.interval,
		spawnDelay = group.spawnDelay,
		burst = group.burst,
	}
end

local function deepCopyWave(source: WaveConfig): WaveConfig
	local groups = table.create(#source.groups)
	for index, group in ipairs(source.groups) do
		groups[index] = deepCopyGroup(group)
	end

	return {
		index = source.index,
		label = source.label,
		groups = groups,
		skipThreshold = source.skipThreshold,
		rewardMultiplier = source.rewardMultiplier,
	}
end

local ORDER: { string } = {}
if typeof(BrainrotData.Order) == "table" then
	for _, name in ipairs(BrainrotData.Order) do
		if typeof(name) == "string" then
			ORDER[#ORDER + 1] = name
		end
	end
end

if #ORDER == 0 then
	for name, value in pairs(BrainrotData) do
		if name ~= "Defaults" and typeof(value) == "table" then
			ORDER[#ORDER + 1] = name
		end
	end
	table.sort(ORDER)
end

local BASE_WAVES: { [number]: WaveConfig } = {
	[1] = {
		index = 1,
		label = "Primer Contacto",
		groups = {
			{ brainrot = ORDER[1] or "", count = 3, interval = 1.4 },
		},
		skipThreshold = DEFAULT_SKIP_THRESHOLD,
	},
	[2] = {
		index = 2,
		label = "Presión Temprana",
		groups = {
			{ brainrot = ORDER[1] or "", count = 4, interval = 1.1 },
			{ brainrot = ORDER[2] or ORDER[1] or "", count = 1, spawnDelay = 4, interval = 2 },
		},
		skipThreshold = DEFAULT_SKIP_THRESHOLD,
		rewardMultiplier = 1.1,
	},
	[3] = {
		index = 3,
		label = "Refuerzos",
		groups = {
			{ brainrot = ORDER[1] or "", count = 6, interval = 0.95 },
			{ brainrot = ORDER[2] or ORDER[1] or "", count = 2, spawnDelay = 6, interval = 1.8 },
		},
		skipThreshold = DEFAULT_SKIP_THRESHOLD,
		rewardMultiplier = 1.2,
	},
	[4] = {
		index = 4,
		label = "Embate",
		groups = {
			{ brainrot = ORDER[2] or ORDER[1] or "", count = 4, interval = 1.4 },
			{ brainrot = ORDER[3] or ORDER[1] or "", count = 1, spawnDelay = 5, interval = 1.9 },
			{ brainrot = ORDER[1] or "", count = 6, spawnDelay = 2, interval = 0.85 },
		},
		skipThreshold = DEFAULT_SKIP_THRESHOLD,
		rewardMultiplier = 1.35,
	},
}

local function resolveOrderedName(step: number): string
	if #ORDER == 0 then
		return ""
	end
	local index = ((step - 1) % #ORDER) + 1
	return ORDER[index]
end

local function inflateWave(index: number): WaveConfig
	local existing = BASE_WAVES[index]
	if existing then
		return deepCopyWave(existing)
	end

	local cycle = math.max(0, index - 1)
	local primary = resolveOrderedName(cycle + 1)
	local secondary = resolveOrderedName(cycle + 2)
	local tertiary = resolveOrderedName(cycle + 3)

	local primaryCount = 4 + math.floor(index * 0.8)
	local secondaryCount = math.max(0, math.floor(index / 2))
	local tertiaryCount = math.max(0, math.floor((index - 2) / 3))

	local interval = math.max(0.4, DEFAULT_INTERVAL - (index * 0.055))

	local groups: { WaveSpawnGroup } = {
		{
			brainrot = primary,
			count = primaryCount,
			interval = interval,
		},
	}

	if secondary ~= "" and secondaryCount > 0 then
		groups[#groups + 1] = {
			brainrot = secondary,
			count = secondaryCount,
			spawnDelay = 6,
			interval = math.max(interval * 1.35, 0.75),
		}
	end

	if tertiary ~= "" and tertiaryCount > 0 then
		groups[#groups + 1] = {
			brainrot = tertiary,
			count = tertiaryCount,
			spawnDelay = 10,
			interval = math.max(interval * 1.6, 0.95),
		}
	end

	return {
		index = index,
		label = `Wave {index}`,
		groups = groups,
		skipThreshold = DEFAULT_SKIP_THRESHOLD,
		rewardMultiplier = 1 + ((index - 1) * 0.15),
	}
end

local BrainrotWaves = {}

function BrainrotWaves.GetWave(index: number): WaveConfig
	local resolved = inflateWave(math.max(1, math.floor(index + 0.5)))
	for _, group in ipairs(resolved.groups) do
		if not group.interval or group.interval <= 0 then
			group.interval = DEFAULT_INTERVAL
		end
	end
	if not resolved.skipThreshold then
		resolved.skipThreshold = DEFAULT_SKIP_THRESHOLD
	end
	return resolved
end

function BrainrotWaves.Iterate(maxCount: number?): () -> (number?, WaveConfig?)
	local limit = if maxCount and maxCount > 0 then math.floor(maxCount + 0.5) else nil
	local index = 0
	return function()
		index += 1
		if limit and index > limit then
			return nil, nil
		end
		return index, BrainrotWaves.GetWave(index)
	end
end

function BrainrotWaves.GetOrder(): { string }
	local copy = table.create(#ORDER)
	for idx, name in ipairs(ORDER) do
		copy[idx] = name
	end
	return copy
end

BrainrotWaves.DEFAULT_SKIP_THRESHOLD = DEFAULT_SKIP_THRESHOLD

return BrainrotWaves
