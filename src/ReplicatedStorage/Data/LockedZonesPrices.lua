local LockedZonesPrices = {
    LockedZone_1 = 1000,
    LockedZone_5 = 2000,
    LockedZone_6 = 2000,
    LockedZone_7 = 2000,
    LockedZone_9 = 2000,
    LockedZone_10 = 2000,
    LockedZone_11 = 2000,
    LockedZone_12 = 3000,
    LockedZone_13 = 2000,
    LockedZone_14 = 3000,
    LockedZone_15 = 3000,
    LockedZone_16 = 3000,
    LockedZone_17 = 3000,
    LockedZone_18 = 3000,
    LockedZone_19 = 3000,
    LockedZone_20 = 3000,
    LockedZone_21 = 4000,
    LockedZone_22 = 4000,
    LockedZone_23 = 4000,
    LockedZone_24 = 4000,
    LockedZone_25 = 4000,
}

local function sanitizeId(zoneId)
    if typeof(zoneId) == "number" then
        return `LockedZone_{zoneId}`
    end

    if typeof(zoneId) ~= "string" then
        return nil
    end

    if zoneId:find("Static") then
        return nil
    end

    local numeric = zoneId:match("LockedZone[_%-]?(%d+)")
        or zoneId:match("Zone[_%-]?(%d+)")
        or zoneId:match("(%d+)$")

    if not numeric then
        return nil
    end

    local value = tonumber(numeric)
    if not value then
        return nil
    end

    return `LockedZone_{value}`
end

function LockedZonesPrices.GetPrice(zoneId)
    if zoneId and LockedZonesPrices[zoneId] then
        return LockedZonesPrices[zoneId]
    end

    local canonical = sanitizeId(zoneId)
    if canonical then
        return LockedZonesPrices[canonical]
    end

    return nil
end

return LockedZonesPrices
