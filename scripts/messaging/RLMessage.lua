-- Severity: WARNING = serious and still actionable, NOTICE = a setback (a death), SUCCESS = a good outcome,
-- INFO = a chosen action. A daily summary takes the severity of the messages it folds.
RLMessage = {
	["PREGNANCY_SINGLE"] = {
		["text"] = "pregnancySingle",
		["title"] = "pregnancy",
		["severity"] = RLConstants.SEVERITY.SUCCESS
	},
	["PREGNANCY_MULTIPLE"] = {
		["text"] = "pregnancyMultiple",
		["title"] = "pregnancy",
		["severity"] = RLConstants.SEVERITY.SUCCESS
	},
	["PREGNANCY_SOLD"] = {
		["text"] = "pregnancySold",
		["title"] = "pregnancy",
		["severity"] = RLConstants.SEVERITY.WARNING
	},
	["PREGNANCY_DIED"] = {
		["text"] = "pregnancyDied",
		["title"] = "pregnancy",
		["severity"] = RLConstants.SEVERITY.NOTICE
	},
	["DEATH"] = {
		["text"] = "death",
		["title"] = "death",
		["severity"] = RLConstants.SEVERITY.NOTICE
	},
	["DISEASE_CONTRACTED"] = {
		["text"] = "diseaseContracted",
		["title"] = "disease",
		["severity"] = RLConstants.SEVERITY.WARNING
	},
	["DISEASE_CURED"] = {
		["text"] = "diseaseCured",
		["title"] = "disease",
		["severity"] = RLConstants.SEVERITY.SUCCESS
	},
	["DISEASE_TREATMENT_START"] = {
		["text"] = "diseaseTreatment_start",
		["title"] = "disease",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["DISEASE_TREATMENT_RESUME"] = {
		["text"] = "diseaseTreatment_resume",
		["title"] = "disease",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["DISEASE_TREATMENT_STOP"] = {
		["text"] = "diseaseTreatment_stop",
		["title"] = "disease",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	-- A course that ended without a cure: per animal, INDIVIDUAL (not in RLMessageAggregator.AGGREGATABLE).
	["DISEASE_TREATMENT_FAILED"] = {
		["text"] = "diseaseTreatment_failed",
		["title"] = "disease",
		["severity"] = RLConstants.SEVERITY.WARNING
	},
	["NAME_CHANGE"] = {
		["text"] = "nameChange",
		["title"] = "name",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["NAME_ADDED"] = {
		["text"] = "nameAdded",
		["title"] = "name",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["NAME_DELETED"] = {
		["text"] = "nameDeleted",
		["title"] = "name",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["BOUGHT_ANIMALS_SINGLE"] = {
		["text"] = "boughtAnimals_single",
		["title"] = "movement",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["BOUGHT_ANIMALS_MULTIPLE"] = {
		["text"] = "boughtAnimals_multiple",
		["title"] = "movement",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["SOLD_ANIMALS_SINGLE"] = {
		["text"] = "soldAnimals_single",
		["title"] = "movement",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["SOLD_ANIMALS_MULTIPLE"] = {
		["text"] = "soldAnimals_multiple",
		["title"] = "movement",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["MOVED_ANIMALS_SOURCE_SINGLE"] = {
		["text"] = "movedAnimalsTo_single",
		["title"] = "movement",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["MOVED_ANIMALS_SOURCE_MULTIPLE"] = {
		["text"] = "movedAnimalsTo_multiple",
		["title"] = "movement",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["MOVED_ANIMALS_TARGET_SINGLE"] = {
		["text"] = "movedAnimalsFrom_single",
		["title"] = "movement",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["MOVED_ANIMALS_TARGET_MULTIPLE"] = {
		["text"] = "movedAnimalsFrom_multiple",
		["title"] = "movement",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_BOUGHT_SINGLE"] = {
		["text"] = "aiManager_boughtAnimals_single",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_BOUGHT_MULTIPLE"] = {
		["text"] = "aiManager_boughtAnimals_multiple",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_SOLD_SINGLE"] = {
		["text"] = "aiManager_soldAnimals_single",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_SOLD_MULTIPLE"] = {
		["text"] = "aiManager_soldAnimals_multiple",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_CASTRATED_SINGLE"] = {
		["text"] = "aiManager_castrated_single",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_CASTRATED_MULTIPLE"] = {
		["text"] = "aiManager_castrated_multiple",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_NAMED_SINGLE"] = {
		["text"] = "aiManager_named_single",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_NAMED_MULTIPLE"] = {
		["text"] = "aiManager_named_multiple",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_MARK_SELL_SINGLE"] = {
		["text"] = "aiManager_mark_sell_single",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_MARK_SELL_MULTIPLE"] = {
		["text"] = "aiManager_mark_sell_multiple",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_MARK_CASTRATE_SINGLE"] = {
		["text"] = "aiManager_mark_castrate_single",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_MARK_CASTRATE_MULTIPLE"] = {
		["text"] = "aiManager_mark_castrate_multiple",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_MARK_DISEASE_SINGLE"] = {
		["text"] = "aiManager_mark_disease_single",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_MARK_DISEASE_MULTIPLE"] = {
		["text"] = "aiManager_mark_disease_multiple",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["INSEMINATION_SUCCESS"] = {
		["text"] = "insemination_success",
		["title"] = "insemination",
		["severity"] = RLConstants.SEVERITY.SUCCESS
	},
	["INSEMINATION_FAIL"] = {
		["text"] = "insemination_fail",
		["title"] = "insemination",
		["severity"] = RLConstants.SEVERITY.NOTICE
	},
	["AI_MANAGER_INSEMINATED_SINGLE"] = {
		["text"] = "aiManager_ai_single",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_INSEMINATED_MULTIPLE"] = {
		["text"] = "aiManager_ai_multiple",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_MARK_INSEMINATED_SINGLE"] = {
		["text"] = "aiManager_mark_ai_single",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_MARK_INSEMINATED_MULTIPLE"] = {
		["text"] = "aiManager_mark_ai_multiple",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	-- Herdsman move op (count-only, no money). Net-new herdsman family (the legacy day-tick emits no
	-- move message); separate from the player-path MOVED_ANIMALS_SOURCE_*/TARGET_* movement ids.
	["AI_MANAGER_MOVED_SINGLE"] = {
		["text"] = "aiManager_movedAnimals_single",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_MOVED_MULTIPLE"] = {
		["text"] = "aiManager_movedAnimals_multiple",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_MARK_MOVE_SINGLE"] = {
		["text"] = "aiManager_mark_move_single",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_MARK_MOVE_MULTIPLE"] = {
		["text"] = "aiManager_mark_move_multiple",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	-- Herdsman horse-care op (count-only, no money - the wage is charged by the executor and never
	-- reported here). Net-new herdsman family with no mark variant: horse care is perform-only.
	["AI_MANAGER_HORSE_CARE_SINGLE"] = {
		["text"] = "aiManager_horseCare_single",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_HORSE_CARE_MULTIPLE"] = {
		["text"] = "aiManager_horseCare_multiple",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	-- Herdsman vaccination op (money: the day's dose total for the pen, which the executor charges
	-- once per farm as medicine). Perform-only, so no mark variant.
	["AI_MANAGER_VACCINATED_SINGLE"] = {
		["text"] = "aiManager_vaccinated_single",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["AI_MANAGER_VACCINATED_MULTIPLE"] = {
		["text"] = "aiManager_vaccinated_multiple",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	-- Herdsman move age-skip (EPP butcher destinations): animals outside the butcher's
	-- accepted age window are skipped at delivery. Count-only, INDIVIDUAL (not in
	-- RLMessageAggregator.AGGREGATABLE) - exceptional + actionable, so it stays out of the daily
	-- summary fold. Emitted alongside (not instead of) the moved message when a move partially skips.
	["AI_MANAGER_MOVE_SKIPPED_AGE_SINGLE"] = {
		["text"] = "aiManager_moveSkippedAge_single",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.NOTICE
	},
	["AI_MANAGER_MOVE_SKIPPED_AGE_MULTIPLE"] = {
		["text"] = "aiManager_moveSkippedAge_multiple",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.NOTICE
	},
	-- Herdsman move sick-skip (EPP butcher destinations): animals showing symptoms stay in the pen.
	-- Same shape as the age-skip pair: count-only, INDIVIDUAL, beside or instead of the moved message.
	["AI_MANAGER_MOVE_SKIPPED_SICK_SINGLE"] = {
		["text"] = "aiManager_moveSkippedSick_single",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.NOTICE
	},
	["AI_MANAGER_MOVE_SKIPPED_SICK_MULTIPLE"] = {
		["text"] = "aiManager_moveSkippedSick_multiple",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.NOTICE
	},
	-- Daily summary message types
	["DAILY_BIRTHS_SUMMARY"] = {
		["text"] = "dailyBirthsSummary",
		["title"] = "pregnancy",
		["severity"] = RLConstants.SEVERITY.SUCCESS
	},
	["DAILY_DEATHS_SUMMARY"] = {
		["text"] = "dailyDeathsSummary",
		["title"] = "death",
		["severity"] = RLConstants.SEVERITY.NOTICE
	},
	["DAILY_SALES_SUMMARY"] = {
		["text"] = "dailySalesSummary",
		["title"] = "movement",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["DAILY_OVERCROWDING_SUMMARY"] = {
		["text"] = "dailyOvercrowdingSummary",
		["title"] = "pregnancy",
		["severity"] = RLConstants.SEVERITY.WARNING
	},
	["DAILY_PURCHASES_SUMMARY"] = {
		["text"] = "dailyPurchasesSummary",
		["title"] = "movement",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	-- New herdsman daily summaries (M-Tick T5). title="aiManager" groups them with the
	-- per-op herdsman messages.
	["DAILY_CASTRATIONS_SUMMARY"] = {
		["text"] = "dailyCastrationsSummary",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["DAILY_NAMINGS_SUMMARY"] = {
		["text"] = "dailyNamingsSummary",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["DAILY_INSEMINATIONS_SUMMARY"] = {
		["text"] = "dailyInseminationsSummary",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["DAILY_MARK_SELL_SUMMARY"] = {
		["text"] = "dailyMarkSellSummary",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["DAILY_MARK_CASTRATE_SUMMARY"] = {
		["text"] = "dailyMarkCastrateSummary",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["DAILY_MARK_INSEMINATE_SUMMARY"] = {
		["text"] = "dailyMarkInseminateSummary",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["DAILY_MOVES_SUMMARY"] = {
		["text"] = "dailyMovesSummary",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["DAILY_MARK_MOVE_SUMMARY"] = {
		["text"] = "dailyMarkMoveSummary",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["DAILY_HORSE_CARE_SUMMARY"] = {
		["text"] = "dailyHorseCareSummary",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	},
	["DAILY_VACCINATIONS_SUMMARY"] = {
		["text"] = "dailyVaccinationsSummary",
		["title"] = "aiManager",
		["severity"] = RLConstants.SEVERITY.INFO
	}
}