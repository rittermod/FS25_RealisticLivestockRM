RL_HandToolSystem = {}

local modName = g_currentModName


function RL_HandToolSystem:loadHandToolFromXML(superFunc, xmlFile, key)

	print("RL_HandToolSystem: loadHandToolFromXML called for key: " .. tostring(key))

	local rawFilename = xmlFile:getValue(key .. "#filename")
	print("RL_HandToolSystem: Raw filename from XML: " .. tostring(rawFilename))

	local returnValue = superFunc(self, xmlFile, key)
	print("RL_HandToolSystem: Base game superFunc returned: " .. tostring(returnValue))

	if returnValue then return true end

	local filename = NetworkUtil.convertFromNetworkFilename(rawFilename)
	print("RL_HandToolSystem: Converted filename: " .. tostring(filename))
	print("RL_HandToolSystem: modName: " .. tostring(modName))
	print("RL_HandToolSystem: Contains modName: " .. tostring(string.contains(filename, modName)))

	if not string.contains(filename, modName) then
		print("RL_HandToolSystem: Filename does not contain modName, skipping")
		return false
	end

	print("RL_HandToolSystem: Attempting to load tempXml from: " .. tostring(filename))
	local tempXml = XMLFile.loadIfExists("tempHandTool", filename, HandTool.xmlSchema)
	if tempXml == nil then
		print("RL_HandToolSystem: Failed to load tempXml - file does not exist or invalid")
		return false
	end

	local typeName = tempXml:getValue("handTool#type")
	print("RL_HandToolSystem: typeName from straw.xml: " .. tostring(typeName))

	tempXml:delete()

	self.handToolsToLoad = self.handToolsToLoad + 1

	local fullTypeName = modName .. "." .. typeName
	print("RL_HandToolSystem: Looking for type: " .. tostring(fullTypeName))

	local type = g_handToolTypeManager:getTypeByName(fullTypeName)
	if type == nil then
		print("RL_HandToolSystem: ERROR - type not found in handToolTypeManager!")
		return false
	end

	print("RL_HandToolSystem: Type found, className: " .. tostring(type.className))

	local handTool = _G[type.className].new(g_currentMission:getIsServer(), g_currentMission:getIsClient())

	handTool:setType(type)
	handTool:setLoadCallback(self.loadHandToolFinished, self)
	handTool:loadNonStoreItem({ ["savegameData"] = { ["xmlFile"] = xmlFile, ["key"] = key } }, filename)

	print("RL_HandToolSystem: Successfully started loading hand tool")
	return true

end

HandToolSystem.loadHandToolFromXML = Utils.overwrittenFunction(HandToolSystem.loadHandToolFromXML, RL_HandToolSystem.loadHandToolFromXML)