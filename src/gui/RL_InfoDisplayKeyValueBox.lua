RL_InfoDisplayKeyValueBox = {}
local rl_InfoDisplayKeyValueBox_mt = Class(RL_InfoDisplayKeyValueBox, InfoDisplayBox)


function RL_InfoDisplayKeyValueBox.new(infoDisplay, uiScale)

    local self = InfoDisplayBox.new(infoDisplay, uiScale, rl_InfoDisplayKeyValueBox_mt)

    self.lines = {}
    self.title = "Unknown Title"

    local r, g, b, a = unpack(HUD.COLOR.BACKGROUND)
    self.bgScale = g_overlayManager:createOverlay("gui.fieldInfo_middle", 0, 0, 0, 0)
    self.bgScale:setColor(r, g, b, a)
    self.bgBottom = g_overlayManager:createOverlay("gui.fieldInfo_bottom", 0, 0, 0, 0)
    self.bgBottom:setColor(r, g, b, a)
    self.bgTop = g_overlayManager:createOverlay("gui.fieldInfo_top", 0, 0, 0, 0)
    self.bgTop:setColor(r, g, b, a)

    r, g, b, a = unpack(HUD.COLOR.ACTIVE)
    self.warningIcon = g_overlayManager:createOverlay("gui.fieldInfo_warning", 0, 0, 0, 0)
    self.warningIcon:setColor(r, g, b, a)

    return self

end


function RL_InfoDisplayKeyValueBox:delete()

    self.bgScale:delete()
    self.bgBottom:delete()
    self.bgTop:delete()
    self.warningIcon:delete()

end


function RL_InfoDisplayKeyValueBox:storeScaledValues()

    local infoDisplay = self.infoDisplay
    local x, z = infoDisplay:scalePixelValuesToScreenVector(340, 6)
    local y = infoDisplay:scalePixelToScreenHeight(6)

    self.bgBottom:setDimension(x, z)
    self.bgTop:setDimension(x, y)
    self.bgScale:setDimension(x, 0)
    self.boxWidth = infoDisplay:scalePixelToScreenWidth(340)
    self.keyTextSize = infoDisplay:scalePixelToScreenHeight(14)
    self.valueTextSize = infoDisplay:scalePixelToScreenHeight(14)
    self.titleTextSize = infoDisplay:scalePixelToScreenHeight(15)
    self.titleToLineOffsetY = infoDisplay:scalePixelToScreenHeight(-24)
    self.lineToLineOffsetY = infoDisplay:scalePixelToScreenHeight(-21)
    self.lineHeight = infoDisplay:scalePixelToScreenHeight(21)
    self.titleAndBoxHeight = infoDisplay:scalePixelToScreenHeight(45)
    self.dashedLineHeight = g_pixelSizeY
    self.dashWidth = infoDisplay:scalePixelToScreenWidth(6)
    self.dashGapWidth = infoDisplay:scalePixelToScreenWidth(3)
    self.keyOffsetX = infoDisplay:scalePixelToScreenWidth(30)

    local a, b = infoDisplay:scalePixelValuesToScreenVector(30, -3)
    self.warningOffsetX = a
    self.warningOffsetY = b
    self.valueOffsetX = infoDisplay:scalePixelToScreenWidth(-14)

    local c, d = infoDisplay:scalePixelValuesToScreenVector(14, -27)
    self.titleOffsetX = c
    self.titleOffsetY = d
    self.titleMaxWidth = infoDisplay:scalePixelToScreenWidth(312)

    local e, f = infoDisplay:scalePixelValuesToScreenVector(20, 20)

    self.warningIcon:setDimension(e, f)
    local g, h = infoDisplay:scalePixelValuesToScreenVector(10, -4)
    self.warningIconOffsetX = g
    self.warningIconOffsetY = h

end


function RL_InfoDisplayKeyValueBox:draw(posX, posY)

    local leftX = posX - self.boxWidth
    local height = self.titleAndBoxHeight

    for _, line in ipairs(self.lines) do

        if line.isActive then
            height = height + self.lineHeight
            if line.isWarning then height = height + math.abs(self.warningOffsetY) end
        end

    end

    self.bgScale:setDimension(nil, height - self.bgBottom.height - self.bgTop.height)
    self.bgBottom:setPosition(leftX, posY)
    self.bgBottom:render()
    self.bgScale:setPosition(leftX, self.bgBottom.y + self.bgBottom.height)
    self.bgScale:render()
    self.bgTop:setPosition(leftX, self.bgScale.y + self.bgScale.height)
    self.bgTop:render()

    local a = leftX + self.titleOffsetX
    local b = self.bgTop.y + self.bgTop.height + self.titleOffsetY

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    setTextBold(true)
    renderText(a, b, self.titleTextSize, self.title)
    setTextBold(false)

    local c = leftX + self.keyOffsetX
    local d = leftX + self.warningOffsetX
    local e = leftX + self.warningIconOffsetX
    local f = posX + self.valueOffsetX
    local g = b + self.titleToLineOffsetY
    local h = HUD.COLOR.ACTIVE
    local i = HUD.COLOR.INACTIVE

    for _, line in ipairs(self.lines) do

        if line.isActive then
            local key = line.key
            local value = line.value

            if line.isWarning then
                setTextAlignment(RenderText.ALIGN_LEFT)
                setTextColor(h[1], h[2], h[3], h[4])
                setTextBold(true)
                g = g + self.warningOffsetY
                renderText(d, g, self.keyTextSize, key)
                setTextBold(false)
                self.warningIcon:setPosition(e, g + self.warningIconOffsetY)
                self.warningIcon:render()
            else

                if value == "rl_ui_genetics_extremelyLow" or value == "rl_ui_genetics_extremelyBad" then
                    setTextColor(1, 0, 0, 1)
                elseif value == "rl_ui_genetics_veryLow" or value == "rl_ui_genetics_veryBad" then
                    setTextColor(1, 0.2, 0, 1)
                elseif value == "rl_ui_genetics_low" or value == "rl_ui_genetics_bad" then
                    setTextColor(1, 0.52, 0, 1)
                elseif value == "rl_ui_genetics_average" then
                    setTextColor(1, 1, 0, 1)
                elseif value == "rl_ui_genetics_high" or value == "rl_ui_genetics_good" then
                    setTextColor(0.52, 1, 0, 1)
                elseif value == "rl_ui_genetics_veryHigh" or value == "rl_ui_genetics_veryGood" then
                    setTextColor(0.2, 1, 0, 1)
                else
                    setTextColor(0, 1, 0, 1)
                end

                value = g_i18n:getText(value)

                if key == "rl_ui_overall" then
                    setTextBold(true)
                    key = g_i18n:getText(key)
                end

                setTextAlignment(RenderText.ALIGN_LEFT)
                renderText(c, g, self.keyTextSize, key)
                local j = getTextWidth(self.keyTextSize, key)
                setTextAlignment(RenderText.ALIGN_RIGHT)
                renderText(f, g, self.valueTextSize, value)
                local k = getTextWidth(self.valueTextSize, value)
                local l = c + j + 3 * g_pixelSizeX
                local m = f - k - l - 3 * g_pixelSizeX
                drawDashedLine(l, g, m, self.dashedLineHeight, self.dashWidth, self.dashGapWidth, i[1], i[2], i[3], i[4], true)
                setTextBold(false)
            end

            g = g + self.lineToLineOffsetY
        end

    end

    local newPosY = self.bgTop.y + self.bgTop.height
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    self.doShowNextFrame = false

    return posX, newPosY

end


function RL_InfoDisplayKeyValueBox:canDraw()
    return self.doShowNextFrame
end


function RL_InfoDisplayKeyValueBox:showNextFrame()
    self.doShowNextFrame = true
end


function RL_InfoDisplayKeyValueBox:clear()

    for _, lines in ipairs(self.lines) do
        lines.isActive = false
    end
    self.currentLineIndex = 0

end


function RL_InfoDisplayKeyValueBox:addLine(key, value, accentuate)

    self.currentLineIndex = self.currentLineIndex + 1
    local line = self.lines[self.currentLineIndex]
    if line == nil then
        line = {
            ["key"] = "",
            ["value"] = "",
            ["isWarning"] = false
        }
        table.addElement(self.lines, line)
    end
    line.key = key
    line.value = value or ""
    line.isWarning = accentuate
    line.isActive = true

end


function RL_InfoDisplayKeyValueBox:setTitle(title)

    local newTitle = utf8ToUpper(title)
    if newTitle ~= self.title then
        self.title = Utils.limitTextToWidth(newTitle, self.titleTextSize, self.titleMaxWidth, false, "...")
    end

end