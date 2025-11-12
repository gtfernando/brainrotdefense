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