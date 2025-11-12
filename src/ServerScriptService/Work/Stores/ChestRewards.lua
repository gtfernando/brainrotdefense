--!strict

local RandomGenerator = Random.new()

local ChestRewards = {}

type WeightedEntry = {
	name: string,
	weight: number,
}

local function buildEntries(rewardsTable: {[string]: any}): ({WeightedEntry}, number)
	local entries: {WeightedEntry} = {}
	local totalWeight = 0

	for rewardName, rawWeight in rewardsTable do
		if typeof(rewardName) == "string" then
			local numericWeight = tonumber(rawWeight)
			if numericWeight and numericWeight > 0 then
				totalWeight += numericWeight
				entries[#entries + 1] = {
					name = rewardName,
					weight = numericWeight,
				}
			end
		end
	end

	table.sort(entries, function(a, b)
		return a.name < b.name
	end)

	return entries, totalWeight
end

function ChestRewards.pickReward(definition: { Rewards: {[string]: any}? }): string?
	if typeof(definition) ~= "table" then
		return nil
	end

	local rewards = definition.Rewards
	if typeof(rewards) ~= "table" then
		return nil
	end

	local entries, totalWeight = buildEntries(rewards)
	if totalWeight <= 0 or #entries == 0 then
		return nil
	end

	local roll = RandomGenerator:NextNumber() * totalWeight
	local accumulated = 0
	for _, entry in entries do
		accumulated += entry.weight
		if roll < accumulated then
			return entry.name
		end
	end

	return entries[#entries].name
end

return ChestRewards