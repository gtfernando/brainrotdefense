--[[
    BRAINROT / BOSS CUSTOMIZATION NOTES
    1. `Defaults` define los valores base cuando un boss no especifica algo (velocidad, vida, recompensas, etc.).
       Cambia estos numeros si quieres que TODOS los brainrots compartan nuevos minimos.
    2. Cada entrada dentro de `Bosses` representa un brainrot/boss jugable:
       - `tier`: orden de dificultad (se usa en progresion y desbloqueos).
       - `unlockScore`: puntos necesarios para que empiece a salir.
       - `maxHealth`, `moveSpeed`, `attack.interval/damage/radius`: stats de combate.
       - `reward.money.min/max` y `reward.progression`: recompensa que otorga al morir.
         - `animationId`: animacion personalizada (0 = usa la por defecto).
         - `runAnimationId` (opcional): animacion usada cuando entra al modo sprint.
    3. La lista `Order` determina el orden en que `BrainrotWaves` usa los nombres.
       Asegurate de incluir aqui cualquier boss nuevo para que pueda spawnear en las waves.
    4. Para crear un nuevo brainrot copia uno existente dentro de `Bosses`, cambia el nombre de la llave
       (por ejemplo "MiBossNuevo"), ajusta sus stats y agregalo tambien en `Order`.
    5. EJEMPLOS PRODUCCION:
       - **Sprinter Elite:**
           ```
           Bosses["FastFootera"] = {
               tier = 1,
               unlockScore = 0,
               maxHealth = 240,
               moveSpeed = 20,
               attack = {
                   interval = 1.8,
                   damage = 28,
                   radius = 10,
               },
               reward = {
                   money = { min = 210, max = 260 },
                   progression = 1,
               },
               animationId = 0,
           }
           table.insert(Order, "FastFootera")
           ```
       - **Boss Tanque (evento):**
           ```
           Bosses["EventoColoso"] = {
               tier = 3,
               unlockScore = 20,
               maxHealth = 5200,
               moveSpeed = 6,
               attack = {
                   interval = 2.8,
                   damage = 140,
                   radius = 16,
               },
               reward = {
                   money = { min = 800, max = 1100 },
                   progression = 5,
               },
               animationId = 0,
           }
           table.insert(Order, "EventoColoso")
           ```
       - **Jefe nocturno desbloqueable:** define `unlockScore = 50` y colocalo solo en waves tardias para
         simular contenido exclusivo de madrugada.
]]

local Defaults = {
    moveSpeed = 10,
    arrivalTolerance = 1.5,
    attack = {
        interval = 2.4,
        damage = 110,
        radius = 10,
    },
    reward = {
        money = {
            min = 150,
            max = 220,
        },
        progression = 1,
    },
    maxHealth = 1600,
}

local Bosses = {
    ["GangsterFootera"] = {
        tier = 1,
        unlockScore = 0,
        maxHealth = 200,
        moveSpeed = 11,
        attack = {
            interval = 2.1,
            damage = 30,
            radius = 12,
        },
        reward = {
            money = {
                min = 200,
                max = 280,
            },
            progression = 2,
        },
        animationId = 88452794834653,
    },
    ["BrriBrriBicusDicusBombicus"] = {
        tier = 2,
        unlockScore = 6,
        maxHealth = 240,
        moveSpeed = 9,
        attack = {
            interval = 1.6,
            damage = 50,
            radius = 14,
        },
        reward = {
            money = {
                min = 320,
                max = 420,
            },
            progression = 3,
        },
        animationId = 0,
    },
}

local Order = {
    "GangsterFootera",
    "BrriBrriBicusDicusBombicus",
}

local Brainrots = {
    Defaults = Defaults,
    Order = Order,
}

for name, definition in pairs(Bosses) do
    Brainrots[name] = definition
end

return Brainrots