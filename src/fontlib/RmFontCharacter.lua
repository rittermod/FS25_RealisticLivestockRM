-- RmFontCharacter.lua
-- Stripped from FS25_FontLibrary by Arrow
-- Modified for RealisticLivestockRM - 3D text only

RmFontCharacter = {}

local RmFontCharacter_mt = Class(RmFontCharacter)


function RmFontCharacter.new(font)

	local self = setmetatable({}, RmFontCharacter_mt)

	self.font = font
	self.variations = {}

	return self

end


function RmFontCharacter:loadFromXMLFile(xmlFile, key, imageWidth, imageHeight, cellWidth, cellHeight)

	self.character = xmlFile:getString(key .. "#character")
	self.byte = xmlFile:getInt(key .. "#byte")
	self.index = xmlFile:getInt(key .. "#uvIndex")
	self.type = xmlFile:getString(key .. "#type", "alphabetical")

	for _, variationKey, variationName in xmlFile:iteratorChildren(key) do

		self.variations[variationName] = self:loadVariation(xmlFile, variationKey, imageWidth, (variationName == "italic" or variationName == "boldItalic") and (imageHeight * 2) or imageHeight, cellWidth, cellHeight)

	end

end


function RmFontCharacter:loadVariation(xmlFile, key, imageWidth, imageHeight, cellWidth, cellHeight)

	local variation = {
		["strokes"] = {}
	}

	xmlFile:iterate(key .. ".stroke", function(_, strokeKey)

		local stroke = {}
		local strokeWidth = xmlFile:getString(strokeKey .. "#strokeWidth", "0")

		stroke.width = xmlFile:getInt(strokeKey .. "#width", cellWidth)
		stroke.height = xmlFile:getInt(strokeKey .. "#height", cellHeight)

		stroke.x = xmlFile:getInt(strokeKey .. "#x")
		stroke.y = xmlFile:getInt(strokeKey .. "#y")

		if strokeWidth == "0" then

			stroke.left = (xmlFile:getFloat(strokeKey .. "#left") - 2) / (cellWidth / 2)
			stroke.right = (xmlFile:getFloat(strokeKey .. "#right") + 2) / (cellWidth / 2)

		end

		stroke.screenWidth, stroke.screenHeight = getNormalizedScreenValues(stroke.width, stroke.height)
		stroke.imageWidth, stroke.imageHeight = imageWidth, imageHeight

		stroke.uvs = GuiUtils.getUVs({ stroke.x, stroke.y, stroke.width, stroke.height }, { imageWidth, imageHeight })

		variation.strokes[strokeWidth] = stroke

	end)

	return variation

end


function RmFontCharacter:getVariation(variation, strokeWidth)

	return self.variations[variation].strokes[strokeWidth or "0"]

end
