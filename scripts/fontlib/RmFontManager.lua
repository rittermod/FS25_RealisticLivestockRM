-- RmFontManager.lua
-- Stripped from FS25_FontLibrary by Arrow
-- Modified for RealisticLivestockRM - 3D linked text only
-- All 2D rendering, UI, and settings code removed

RmFontManager = {}

local RmFontManager_mt = Class(RmFontManager)

local closestCharacters = {
    [163] = 36,
    [8364] = 36,
    [192] = 65,
    [193] = 65,
    [194] = 65,
    [195] = 65,
    [196] = 65,
    [199] = 67,
    [200] = 69,
    [201] = 69,
    [202] = 69,
    [203] = 69,
    [204] = 73,
    [206] = 73,
    [207] = 73,
    [210] = 79,
    [212] = 79,
    [214] = 79,
    [219] = 85,
    [220] = 85,
    [224] = 97,
    [226] = 97,
    [227] = 97,
    [228] = 97,
    [231] = 99,
    [232] = 101,
    [233] = 101,
    [234] = 101,
    [235] = 101,
    [237] = 105,
    [238] = 105,
    [239] = 105,
    [241] = 110,
    [243] = 111,
    [244] = 111,
    [245] = 111,
    [246] = 111,
    [250] = 117,
    [251] = 117,
    [252] = 117,
    [8216] = 39,
    [8217] = 39
}

local invalidCharacters = {
    [8592] = true,
    [8593] = true,
    [8594] = true,
    [8595] = true,
    [9003] = true,
    [9166] = true
}


function RmFontManager.new(modDirectory)

    local self = setmetatable({}, RmFontManager_mt)

    self.modDirectory = modDirectory
    self.fonts = {}
    self.languages = {}
    self.language = "latin"
    self.defaultFont = "dejavu_sans"
    self.cache3DLinked = {}

    self.args = {
        ["colour"] = { 1, 1, 1, 1 },
        ["bold"] = false,
        ["italic"] = false,
        ["alignX"] = RenderText.ALIGN_LEFT,
        ["alignY"] = RenderText.VERTICAL_ALIGN_MIDDLE,
        ["font"] = self.defaultFont,
        ["lines3D"] = {
            ["indentation"] = 0,
            ["width"] = 0,
            ["max"] = 0,
            ["heightScale"] = RenderText.DEFAULT_LINE_HEIGHT_SCALE,
            ["autoScale"] = false,
            ["removeSpaces"] = false,
            ["numWords"] = 0
        }
    }

    self:loadFonts()

    return self

end


function RmFontManager:loadFonts()

    self.fontHolder = g_i3DManager:loadI3DFile(self.modDirectory .. "fonts/fontHolder.i3d")
    self.template = I3DUtil.indexToObject(self.fontHolder, "0|0")

    local i3dNode = g_i3DManager:loadI3DFile(self.modDirectory .. "fonts/text.i3d")
    self.text = getChildAt(i3dNode, 0)
    self.textGroup = createTransformGroup("rlrm_fontlib_texts")

    link(getRootNode(), self.textGroup)
    link(self.textGroup, self.text)

    setVisibility(self.text, false)
    setVisibility(self.fontHolder, false)

end


function RmFontManager:loadFontsFromXMLFile(xmlPath, directory)

    local xmlFile = XMLFile.loadIfExists("fontsXML", xmlPath)
    local fontIds = {}

    if xmlFile == nil then return fontIds end

    xmlFile:iterate("fonts.font", function(_, key)

        local path = directory .. xmlFile:getString(key .. "#path")
        local fontXML = XMLFile.loadIfExists("fontXML", path .. "font.xml")

        if fontXML == nil then
            fontXML = XMLFile.loadIfExists("fontXML", path .. "/font.xml")
            path = path .. "/"
        end

        if fontXML ~= nil then

            local id, name = self:loadFont(fontXML, "font", path)
            fontIds[name] = id
            fontXML:delete()

        end

    end)

    xmlFile:delete()

    return fontIds

end


function RmFontManager:loadFont(xmlFile, key, directory)

    local transformGroup = clone(self.template, true, false, false)

    local language = xmlFile:getString(key .. "#language", "latin")
    local name = xmlFile:getString(key .. "#name")
    local id, i = name, 0

    if self.fonts[language] == nil then
        self.fonts[language] = {}
        self.languages[language] = {}
    end

    while self.fonts[language][id] ~= nil do

        i = i + 1
        id = name .. "_" .. i

    end

    setName(transformGroup, id)

    if xmlFile:getBool(key .. "#default", false) then self.languages[language].default = id end

    local font = {
        ["name"] = name,
        ["id"] = id,
        ["nodes"] = {},
        ["imageWidth"] = xmlFile:getInt(key .. ".image#width", 8192),
        ["imageHeight"] = xmlFile:getInt(key .. ".image#height", 256),
        ["cellWidth"] = xmlFile:getInt(key .. ".cell#width", 128),
        ["cellHeight"] = xmlFile:getInt(key .. ".cell#height", 128),
        ["variations"] = {
            ["regular"] = {
                ["0"] = string.format("%s%s_0.dds", directory, name),
                ["1.5"] = string.format("%s%s_1.5.dds", directory, name)
            },
            ["bold"] = {
                ["0"] = string.format("%s%sBold_0.dds", directory, name),
                ["1.5"] = string.format("%s%sBold_1.5.dds", directory, name)
            },
            ["italic"] = {
                ["0"] = string.format("%s%sItalic_0.dds", directory, name),
                ["1.5"] = string.format("%s%sItalic_1.5.dds", directory, name)
            },
            ["boldItalic"] = {
                ["0"] = string.format("%s%sBoldItalic_0.dds", directory, name),
                ["1.5"] = string.format("%s%sBoldItalic_1.5.dds", directory, name)
            }
        },
        ["characters"] = {},
        ["useable"] = xmlFile:getBool(key .. "#useable", true)
    }

    font.scale = 128 / font.cellWidth

    local files = {
        ["regular"] = string.format("%s%s_alpha.dds", directory, name),
        ["bold"] = string.format("%s%sBold_alpha.dds", directory, name),
        ["italic"] = string.format("%s%sItalic_alpha.dds", directory, name),
        ["boldItalic"] = string.format("%s%sBoldItalic_alpha.dds", directory, name)
    }


    local templateNode = getChild(transformGroup, "template")


    for variation, file in pairs(files) do

        local node = clone(templateNode, true, false, false)

        setName(node, variation)
        local material = setMaterialCustomMapFromFile(getMaterial(node, 0), "alphaMap", file, false, true, false)
        setMaterial(node, material, 0)
        setShaderParameter(node, "widthAndHeight", font.imageWidth / font.cellWidth, (font.imageHeight * 2) / font.cellHeight, nil, nil, false)

        font.nodes[variation] = node

    end

    xmlFile:iterate(key .. ".character", function(_, charKey)

        local character = RmFontCharacter.new(font)

        character:loadFromXMLFile(xmlFile, charKey, font.imageWidth, font.imageHeight, font.cellWidth, font.cellHeight)

        font.characters[character.byte] = character

    end)

    self.fonts[language][id] = font

    print(string.format("RLRM FontLib - Loaded font '%s' (%s) as %s", name, id, language:upper()))

    return id, name

end


function RmFontManager:getFont(id)

    if self.fonts[self.language] and self.fonts[self.language][id] ~= nil then
        return self.fonts[self.language][id]
    end

    if self.fonts.latin and self.fonts.latin[id] ~= nil then
        return self.fonts.latin[id]
    end

    if self.languages[self.language] ~= nil and self.fonts[self.language] then
        return self.fonts[self.language][self.languages[self.language].default]
    end

    if self.fonts.latin then
        return self.fonts.latin[self.languages.latin and self.languages.latin.default or self.defaultFont]
    end

    return nil

end


function RmFontManager:getCharacter(font, character)

    if character == nil then return nil end

    local byte = utf8ToUnicode(character)

    if invalidCharacters[byte] then return nil, true end

    if byte == 32 or byte == 160 then return nil end

    if font.characters[byte] ~= nil then return font.characters[byte], false end
    if closestCharacters[byte] ~= nil then return font.characters[closestCharacters[byte]], false end

    byte = utf8ToUnicode(utf8ToUpper(character))

    if font.characters[byte] ~= nil then return font.characters[byte], false end
    if closestCharacters[byte] ~= nil then return font.characters[closestCharacters[byte]], false end

    return nil, false

end


-- State setters
function RmFontManager:setTextFont(fontName)
    self.args.font = fontName
end


function RmFontManager:setTextColor(r, g, b, a)
    self.args.colour = { r, g, b, a }
end


function RmFontManager:setTextBold(isBold)
    self.args.bold = isBold
end


function RmFontManager:setTextAlignment(value)
    self.args.alignX = value
end


function RmFontManager:setTextVerticalAlignment(value)
    self.args.alignY = value
end


function RmFontManager:setTextLineHeightScale(heightScale)
    self.args.lines3D.heightScale = heightScale or 1.1
end


function RmFontManager:set3DTextWrapWidth(width)
    self.args.lines3D.width = width or 0
end


function RmFontManager:set3DTextAutoScale(autoScale)
    self.args.lines3D.autoScale = autoScale or false
end


function RmFontManager:set3DTextRemoveSpaces(removeSpaces)
    self.args.lines3D.removeSpaces = removeSpaces or false
end


function RmFontManager:set3DTextWordsPerLine(numWords)
    self.args.lines3D.numWords = numWords or 0
end


-- 3D Linked Text Creation
function RmFontManager:create3DLinkedText(parent, x, y, z, rx, ry, rz, size, text, fontName)

    local args = self.args
    fontName = fontName or args.font or self.defaultFont


    local variationName = "regular"

    if args.bold and args.italic then
        variationName = "boldItalic"
    elseif args.bold then
        variationName = "bold"
    elseif args.italic then
        variationName = "italic"
    end

    local node = clone(self.text, false, false, false)
    link(parent, node)
    setVisibility(node, true)

    setTranslation(node, x + 0.25 * size, y, z)
    setRotation(node, rx, ry + math.pi / 2, rz)

    local font = self:getFont(fontName)
    if font == nil then
        print("RLRM FontLib WARNING: Font not found: " .. tostring(fontName))
        return node
    end

    local variationNode = font.nodes[variationName]
    local xOffset, yOffset = 0, 0

    local colour = args.colour
    setScale(node, size, size, 0)

    local words = string.split(text, " ")
    local lines = { { ["text"] = "", ["width"] = 0, ["x"] = 0, ["y"] = 0, ["scale"] = 1 } }
    local lineConfig = args.lines3D
    local line = lines[1]

    local numWordsOnLine = 0


    for j, word in pairs(words) do

        local wordWidth = 0

        for i = 1, #word do

            local character = self:getCharacter(font, utf8Substr(word, i - 1, 1))

            if character == nil then
                wordWidth = wordWidth + 0.5
            else
                local variation = character:getVariation(variationName)
                wordWidth = (wordWidth - variation.left) + variation.right
            end

        end

        if (lineConfig.numWords ~= 0 and lineConfig.numWords == numWordsOnLine) or (lineConfig.width ~= 0 and (line.width + wordWidth) * size > lineConfig.width) then

            if line.text == "" and lineConfig.autoScale then
                line.scale = lineConfig.width / (wordWidth * size)
            elseif line.text ~= "" then
                table.insert(lines, { ["text"] = "", ["width"] = 0, ["x"] = 0, ["y"] = 0, ["scale"] = 1 })
                line = lines[#lines]
                numWordsOnLine = 0
            end

        end

        line.text = line.text .. word
        line.width = line.width + wordWidth
        numWordsOnLine = numWordsOnLine + 1

        if not lineConfig.removeSpaces and j ~= #words then
            line.text = line.text .. " "
            line.width = line.width + 0.5
        end

    end


    local lowestX, lowestY, highestX, highestY


    for j, line in pairs(lines) do

        if args.alignX == RenderText.ALIGN_CENTER then
            line.x = line.x - line.width / 2
        elseif args.alignX == RenderText.ALIGN_RIGHT then
            line.x = line.x - line.width
        end

        if #lines > 1 then

            if args.alignY == RenderText.VERTICAL_ALIGN_BASELINE then
                line.y = 1.5 - j
            elseif args.alignY == RenderText.VERTICAL_ALIGN_TOP then
                line.y = 0.5 - j
            elseif args.alignY == RenderText.VERTICAL_ALIGN_MIDDLE then
                local centerLine = math.ceil(#lines / 2)
                if j ~= centerLine then line.y = centerLine - j end
            elseif args.alignY == RenderText.VERTICAL_ALIGN_BOTTOM then
                line.y = 0.5 + (#lines - j)
            end

            line.y = line.y * lineConfig.heightScale

        end

        local xOffset = 0

        for i = 1, #line.text do

            local character = self:getCharacter(font, utf8Substr(line.text, i - 1, 1))

            if character == nil then
                xOffset = xOffset + 0.5
            else
                local charNode = clone(variationNode, false, false, false)
                link(node, charNode)

                setShaderParameter(charNode, "index", character.index, nil, nil, nil, false)
                setShaderParameter(charNode, "colorScale", colour[1], colour[2], colour[3], colour[4], false)

                if line.scale ~= 1 then
                    setScale(charNode, line.scale, line.scale, 1)
                    xOffset = xOffset - (i - 1) * line.scale
                end

                local variation = character:getVariation(variationName)
                if i == #line.text and (highestX == nil or line.x + xOffset > highestX) then highestX = line.x + xOffset end
                xOffset = xOffset - variation.left
                setTranslation(charNode, line.x + xOffset, line.y, 0)
                if i == 1 and (lowestX == nil or line.x - variation.right < lowestX) then lowestX = line.x - variation.right end
                xOffset = xOffset + variation.right
            end

        end

        if lowestY == nil or line.y - 0.25 < lowestY then lowestY = line.y - 0.25 end
        if highestY == nil or line.y + 0.5 > highestY then highestY = line.y + 0.5 end

    end


    self.cache3DLinked[node] = {
        ["x"] = x,
        ["y"] = y,
        ["z"] = z,
        ["rx"] = rx,
        ["ry"] = ry,
        ["rz"] = rz,
        ["size"] = size,
        ["text"] = text,
        ["fontName"] = fontName
    }

    return node

end


function RmFontManager:change3DLinkedTextColour(node, r, g, b, a)

    if node == nil or node == 0 then return end

    for i = 0, getNumOfChildren(node) - 1 do

        local child = getChildAt(node, i)
        setShaderParameter(child, "colorScale", r, g, b, a, false)

    end

end


function RmFontManager:delete3DLinkedText(node)

    if entityExists(node) then delete(node) end

    self.cache3DLinked[node] = nil

end
