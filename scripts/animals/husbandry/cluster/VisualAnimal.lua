VisualAnimal = {}


local VisualAnimal_mt = Class(VisualAnimal)


--- Safely resolve a pipe-separated node path (e.g. "0|0|0|1|0") against a root node.
--- Returns the resolved node, or nil if any step in the path has insufficient children.
--- Unlike I3DUtil.indexToObject, this does NOT log errors on invalid paths.
local function safeIndexToObject(root, path)
    if root == nil or root == 0 or path == nil then return nil end

    local node = root
    for indexStr in path:gmatch("[^|]+") do
        local childIndex = tonumber(indexStr)
        if childIndex == nil or childIndex >= getNumOfChildren(node) then
            return nil
        end
        node = getChildAt(node, childIndex)
    end

    return node
end


function VisualAnimal.new(animal, husbandryId, animalId)

	local self = setmetatable({}, VisualAnimal_mt)

	self.animal = animal
	self.husbandryId = husbandryId
	self.animalId = animalId

	self.nodes = {
		["root"] = getAnimalRootNode(husbandryId, animalId)
	}
	self.texts = {
		["earTagLeft"] = {},
		["earTagRight"] = {}
	}

	self.leftTextColour, self.rightTextColour = { 0, 0, 0 }, { 0, 0, 0 }

	return self

end


function VisualAnimal:delete()

	for _, nodeType in pairs(self.texts) do

		for _, nodes in pairs(nodeType) do

			for _, node in pairs(nodes) do RealisticLivestock.delete3DLinkedText(node) end

		end

	end

end


function VisualAnimal:load()

	local nodes = self.nodes
	if nodes.root == nil or nodes.root == 0 then return end

	local visualData = g_currentMission.animalSystem:getVisualByAge(self.animal.subTypeIndex, self.animal.age, self.animal)

	if visualData.monitor ~= nil then nodes.monitor = safeIndexToObject(nodes.root, visualData.monitor) end
	if visualData.noseRing ~= nil then nodes.noseRing = safeIndexToObject(nodes.root, visualData.noseRing) end
	if visualData.bumId ~= nil then nodes.bumId = safeIndexToObject(nodes.root, visualData.bumId) end
	if visualData.marker ~= nil then nodes.marker = safeIndexToObject(nodes.root, visualData.marker) end
	if visualData.earTagLeft ~= nil then nodes.earTagLeft = safeIndexToObject(nodes.root, visualData.earTagLeft) end
	if visualData.earTagRight ~= nil then nodes.earTagRight = safeIndexToObject(nodes.root, visualData.earTagRight) end

	self:setMonitor()
	self:setNoseRing()
	self:setBumId()
	self:setMarker()
	self:setLeftEarTag()
	self:setRightEarTag()

end


function VisualAnimal:setMonitor()

	if self.nodes.monitor == nil then return end

    setVisibility(self.nodes.monitor, self.animal.monitor.active)

end


function VisualAnimal:setNoseRing()

	if self.nodes.noseRing == nil then return end

    setVisibility(self.nodes.noseRing, self.animal.gender == "male")

end


function VisualAnimal:setBumId()

	if self.nodes.bumId == nil then return end

	local uniqueId = self.animal.uniqueId

	for i = 0, 3 do
		local child = getChildAt(self.nodes.bumId, i)
		local digit = tonumber(string.sub(uniqueId, 3 + i, 3 + i)) or 0
		setShaderParameter(child, "playScale", digit, 0, 64, 1, false)
	end

end


VisualAnimal.DEFAULT_MARKER_COLOUR = { 1, 1, 1 }


function VisualAnimal:setMarker()

	if self.nodes.marker == nil then return end

	local breedColour = AnimalSystem.BREED_TO_MARKER_COLOUR[self.animal.breed]
    local markerColour = breedColour or VisualAnimal.DEFAULT_MARKER_COLOUR
    local isMarked = self.animal:getMarked()

    setVisibility(self.nodes.marker, isMarked)
    if isMarked then
        setShaderParameter(self.nodes.marker, "colorScale", markerColour[1], markerColour[2], markerColour[3], nil, false)
        if breedColour == nil then
            local Log = RmLogging.getLogger("RLRM")
            Log:trace("VisualAnimal:setMarker: no breed colour for breed='%s' (animal uniqueId=%s) - applying default %s",
                tostring(self.animal.breed), tostring(self.animal.uniqueId),
                string.format("{%.2f,%.2f,%.2f}", markerColour[1], markerColour[2], markerColour[3]))
        end
    end

end



function VisualAnimal:setEarTagColours(leftTag, leftText, rightTag, rightText)

	if self.nodes.earTagLeft ~= nil then

		if leftTag ~= nil then setShaderParameter(self.nodes.earTagLeft, "colorScale", leftTag[1], leftTag[2], leftTag[3], nil, false) end

		if leftText ~= nil then

			self.leftTextColour = leftText
		
			for _, nodes in pairs(self.texts.earTagLeft) do
				for _, node in pairs(nodes) do RealisticLivestock.change3DLinkedTextColour(node, leftText[1], leftText[2], leftText[3], 1) end
			end

		end

	end

	if self.nodes.earTagRight ~= nil then

		if rightTag ~= nil then setShaderParameter(self.nodes.earTagRight, "colorScale", rightTag[1], rightTag[2], rightTag[3], nil, false) end

		if rightText ~= nil then

			self.rightTextColour = rightText
		
			for _, nodes in pairs(self.texts.earTagRight) do
				for _, node in pairs(nodes) do RealisticLivestock.change3DLinkedTextColour(node, rightText[1], rightText[2], rightText[3], 1) end
			end

		end

	end

end


function VisualAnimal:setLeftEarTag()

	if self.nodes.earTagLeft == nil then return end

	for _, nodes in pairs(self.texts.earTagLeft) do
		for _, node in pairs(nodes) do RealisticLivestock.delete3DLinkedText(node) end
	end

    local uniqueId = self.animal.uniqueId
    local farmId = self.animal.farmId
    local birthday = self.animal:getBirthday()
	local countryCode = birthday ~= nil and birthday.country ~= nil and (RLConstants.AREA_CODES[birthday.country] or RealisticLivestock.getMapCountryCode()).code
	local node = self.nodes.earTagLeft
	local colour = self.leftTextColour

	local front = getChild(node, "front")
	local back = getChild(node, "back")
	
	RealisticLivestock.setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)
	RealisticLivestock.setTextAlignment(RenderText.ALIGN_CENTER)
	RealisticLivestock.setTextColor(colour[1], colour[2], colour[3], 1)
	RealisticLivestock.setTextFont(RealisticLivestock.FONTS.dejavu_sans)

	self.texts.earTagLeft = {
		["uniqueId"] = {
			["back"] = RealisticLivestock.create3DLinkedText(back, 0, -0.006, -0.015, 0, 0, 0, 0.035, uniqueId),
			["front"] = RealisticLivestock.create3DLinkedText(front, 0, -0.006, -0.015, 0, 0, 0, 0.035, uniqueId)
		},
		["farmId"] = {
			["back"] = RealisticLivestock.create3DLinkedText(back, 0, -0.041, -0.02, 0, 0, 0, 0.05, farmId),
			["front"] = RealisticLivestock.create3DLinkedText(front, 0, -0.041, -0.02, 0, 0, 0, 0.05, farmId)
		},
		["country"] = {
			["back"] = RealisticLivestock.create3DLinkedText(back, 0, 0.021, -0.015, 0, 0, 0, 0.03, countryCode),
			["front"] = RealisticLivestock.create3DLinkedText(front, 0, 0.021, -0.015, 0, 0, 0, 0.03, countryCode)
		}
	}

	
	RealisticLivestock.setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
	RealisticLivestock.setTextAlignment(RenderText.ALIGN_LEFT)
	RealisticLivestock.setTextColor(1, 1, 1, 1)
	RealisticLivestock.setTextFont()

end


function VisualAnimal:setRightEarTag()

	if self.nodes.earTagRight == nil then return end

	for _, nodes in pairs(self.texts.earTagRight) do
		for _, node in pairs(nodes) do RealisticLivestock.delete3DLinkedText(node) end
	end
	
	local node = self.nodes.earTagRight
	local colour = self.rightTextColour
	local name = self.animal:getName()
    local birthday = self.animal:getBirthday()
	local day, month, year = birthday.day, birthday.month, birthday.year + RLConstants.START_YEAR.PARTIAL
	local birthdayText = string.format("%s%s/%s%s/%s%s", day < 10 and 0 or "", day, month < 10 and 0 or "", month, year < 10 and 0 or "", year)

	local front = getChild(node, "front")
	local back = getChild(node, "back")

	RealisticLivestock.set3DTextAutoScale(true)
	RealisticLivestock.set3DTextRemoveSpaces(true)
	RealisticLivestock.set3DTextWrapWidth(0.14)
	RealisticLivestock.setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)
	RealisticLivestock.setTextAlignment(RenderText.ALIGN_CENTER)
	RealisticLivestock.setTextColor(colour[1], colour[2], colour[3], 1)
	RealisticLivestock.set3DTextWordsPerLine(1)
	RealisticLivestock.setTextLineHeightScale(0.75)
	RealisticLivestock.setTextFont(RealisticLivestock.FONTS.toms_handwritten)


	self.texts.earTagRight = {
		["name"] = {
			["back"] = RealisticLivestock.create3DLinkedText(back, 0, -0.01, -0.015, 0, 0, 0, 0.035, name),
			["front"] = RealisticLivestock.create3DLinkedText(front, 0, -0.01, -0.015, 0, 0, 0, 0.035, name)
		}
	}

	RealisticLivestock.set3DTextWrapWidth(0)
	RealisticLivestock.setTextFont(RealisticLivestock.FONTS.dejavu_sans)
	
	self.texts.earTagRight.birthday = {
		["back"] = RealisticLivestock.create3DLinkedText(back, 0, 0.018, -0.015, 0, 0, 0, 0.02, birthdayText),
		["front"] = RealisticLivestock.create3DLinkedText(front, 0, 0.018, -0.015, 0, 0, 0, 0.02, birthdayText)
	}

	
	RealisticLivestock.setTextLineHeightScale(1.1)
	RealisticLivestock.set3DTextWordsPerLine(0)
	RealisticLivestock.set3DTextAutoScale(false)
	RealisticLivestock.set3DTextRemoveSpaces(false)
	RealisticLivestock.setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
	RealisticLivestock.setTextAlignment(RenderText.ALIGN_LEFT)
	RealisticLivestock.setTextColor(1, 1, 1, 1)
	RealisticLivestock.setTextFont()

end