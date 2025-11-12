local Brainrots = {
    ["GunnyniBuildini"] = {
        raycast = { -- bullet properties
            transparency = 0,
            Color = Color3.fromRGB(217, 204, 64),
            Size = Vector3.new(0.25, 0.25, 3),
        },
        Level = {
            [1] = {
                RequiredMoney = 0,
                RobuxPurchaseId = 0,
                Stats = {
                    bullets = 30,
                    dmg = 10,
                    cooldown = 0.2,
                    reloadTime = 3,
                    health = 300,
                    range = 60,
                    projectileSpeed = 160,
                },
            },
            [2] = {
                RequiredMoney = 5000,
                RobuxPurchaseId = 0,
                Stats = {
                    bullets = 40,
                    dmg = 2,
                    cooldown = 0.18,
                    reloadTime = 2.7,
                    health = 360,
                    range = 150,
                    projectileSpeed = 175,
                },
            },
            [3] = {
                RequiredMoney = 12500,
                RobuxPurchaseId = 0,
                Stats = {
                    bullets = 52,
                    dmg = 3,
                    cooldown = 0.15,
                    reloadTime = 2.3,
                    health = 420,
                    range = 200,
                    projectileSpeed = 190,
                },
            },
        },
        data = {
            Price = 250,
            RobuxProduct = 0,
            Image = "",
        },
    },
}

return Brainrots