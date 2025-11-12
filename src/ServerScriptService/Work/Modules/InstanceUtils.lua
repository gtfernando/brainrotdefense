--!strict

local InstanceUtils = {}

function InstanceUtils.findFirstDescendant(root: Instance?, name: string, className: string?): Instance?
	if not root then
		return nil
	end

	if root.Name == name and (not className or root.ClassName == className) then
		return root
	end

	for _, descendant in root:GetDescendants() do
		if descendant.Name == name and (not className or descendant.ClassName == className) then
			return descendant
		end
	end

	return nil
end

return InstanceUtils
