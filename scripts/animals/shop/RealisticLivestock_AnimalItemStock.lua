RealisticLivestock_AnimalItemStock = {}
local mt = Class(AnimalItemStock)

local Log = RmLogging.getLogger("RLRM")

function RealisticLivestock_AnimalItemStock:getClusterId(_)
    return RLAnimalUtil.resolveClusterId(self.cluster)
end

AnimalItemStock.getClusterId = Utils.overwrittenFunction(AnimalItemStock.getClusterId, RealisticLivestock_AnimalItemStock.getClusterId)


--- A dealer item stock for one animal: its visual, title, price and info rows (the type's rows last).
--- @param animal table Animal instance
--- @return table itemStock
function RealisticLivestock_AnimalItemStock.new(animal)

    local self = setmetatable({}, mt)

    self.cluster = animal
	self.visual = g_currentMission.animalSystem:getVisualByAge(animal.subTypeIndex, animal:getAge())
	local subType = g_currentMission.animalSystem:getSubTypeByIndex(animal.subTypeIndex)
	self.title = g_fillTypeManager:getFillTypeTitleByIndex(subType.fillTypeIndex)

	self.cachedSellPrice = animal:getSellPrice()

	local genetics = animal.getGenetics and animal:getGenetics() or nil
	if genetics ~= nil then
		local total = 0
		local count = 0
		for _, value in pairs(genetics) do
			if value ~= nil then
				total = total + value
				count = count + 1
			end
		end
		self.cachedAvgGenetics = count > 0 and (total / count) or 0
	else
		self.cachedAvgGenetics = 0
	end

	local hasMonitor = animal.monitor ~= nil and (animal.monitor.active or animal.monitor.removed)
	
	self.infos = {
		{
			title = g_i18n:getText("ui_age"),
			value = g_i18n:formatNumMonth(animal:getAge())
		}
	}

	if hasMonitor then

		table.insert(self.infos, {
			title = g_i18n:getText("ui_horseHealth"),
			value = string.format("%.f%%", animal:getHealthFactor() * 100)
		})

	end
	
	if subType.supportsReproduction and animal.reproduction > 0 and animal:getAge() >= subType.reproductionMinAgeMonth then
		local newInfo = {
			title = g_i18n:getText("infohud_reproductionStatus"),
			value = string.format("%.f%%", animal:getReproductionFactor() * 100)
		}
		table.insert(self.infos, newInfo)
	end

	if animal.isIndividual then

		local yes = g_i18n:getText("rl_ui_yes")
		local no = g_i18n:getText("rl_ui_no")

		if subType.supportsReproduction and animal.reproduction <= 0 then

			local valueText = nil
			local healthFactor = animal:getHealthFactor()

            if animal.age < subType.reproductionMinAgeMonth then
                valueText = g_i18n:getText("rl_ui_tooYoung")
            elseif animal.isParent and animal.monthsSinceLastBirth <= 2 then
                valueText = g_i18n:getText("rl_ui_recoveringLastBirth")
            elseif not RealisticLivestock.hasMaleAnimalInPen(animal.clusterSystem, animal.subType, animal) then
                valueText = g_i18n:getText("rl_ui_noMaleAnimal")
            elseif healthFactor < subType.reproductionMinHealth then
                valueText = g_i18n:getText("rl_ui_unhealthy")
            end

            if valueText ~= nil then
				table.insert(self.infos, {
					title = g_i18n:getText("rl_ui_canReproduce"),
					value = valueText
				})
			end

		end


		local pregnancy = animal.pregnancy

        if pregnancy ~= nil and pregnancy.pregnancies and #pregnancy.pregnancies > 0 then

            table.insert(self.infos, { ["title"] = g_i18n:getText("rl_ui_pregnancyExpecting"), ["value"] = string.format("%s %s", #pregnancy.pregnancies, g_i18n:getText("rl_ui_pregnancy" .. (#pregnancy.pregnancies == 1 and "Baby" or "Babies"))) })
            table.insert(self.infos, { ["title"] = g_i18n:getText("rl_ui_pregnancyExpected"), ["value"] = string.format("%s/%s/%s", pregnancy.expected.day, pregnancy.expected.month, pregnancy.expected.year + RLConstants.START_YEAR.FULL) })         

		end

		if hasMonitor then

			table.insert(self.infos, {
				title = g_i18n:getText("rl_ui_weight"),
				value = string.format("%.2f", animal.weight or 50) .. "kg"
			})
		
			table.insert(self.infos, {
				title = g_i18n:getText("rl_ui_targetWeight"),
				value = string.format("%.2f", animal.targetWeight or 50) .. "kg"
			})
		
			if animal.animalTypeIndex == AnimalType.COW and animal.gender == "female" and animal:getAge() >= subType.reproductionMinAgeMonth then
		
				table.insert(self.infos, {
					title = g_i18n:getText("rl_ui_lactating"),
					value = animal.isLactating and yes or no
				})

			end

		end

		if animal.gender == "male" and animal:getAge() >= subType.reproductionMinAgeMonth then
			
			table.insert(self.infos, {
				title = g_i18n:getText("rl_ui_maleNumImpregnatable"),
				value = animal:getNumberOfImpregnatableFemalesForMale() or 0
			})

		end

	end

	local typeModule = animal:getTypeModule()
	if typeModule ~= nil and typeModule.addDealerInfos ~= nil then
		Log:trace("AnimalItemStock.new: the type's dealer rows (farmId=%s uniqueId=%s)", tostring(animal.farmId),
			tostring(animal.uniqueId))
		typeModule.addDealerInfos(animal, self.infos)
	end
	
	return self
end

AnimalItemStock.new = RealisticLivestock_AnimalItemStock.new


function AnimalItemStock:getDisplayName()

	return RLAnimalDisplayHelper.formatDisplayName(self.cluster:getName(), self.cluster)

end


function AnimalItemStock:getPrice()

	return self.cachedSellPrice

end


function AnimalItemStock:getHasAnyDisease()

	return self.cluster.getHasAnyDisease and self.cluster:getHasAnyDisease() or false

end