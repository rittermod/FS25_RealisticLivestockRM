RL_I18N = {}
local modName = g_currentModName
local isGithubVersion = true

-- Keys arriving with `modEnv == nil` that belong to this mod's translation environment;
-- routing them through `modName` resolves them from this mod's texts table. Every entry
-- added to `FinanceStats.statNames` needs both flavours here - `rl_ui_<stat>`, registered
-- with MoneyType, and `finance_<stat>`, what the Finance overview queries - or the Finance
-- row renders the missing-key fallback.
local MOD_ROUTED_KEYS = {
    rl_ui_monitorSubscriptions = true,
    finance_monitorSubscriptions = true,
    rl_ui_herdsmanWages = true,
    finance_herdsmanWages = true,
    rl_ui_semenPurchase = true,
    finance_semenPurchase = true,
    rl_ui_medicine = true,
    finance_medicine = true,
}

function RL_I18N:getText(superFunc, text, modEnv)

    -- A nil key reaches this global override when a caller looks up a missing localization
    -- key; delegate rather than crash in `string.contains` below, which requires a string.
    if text == nil then
        Log:warning("I18N: nil key passed to getText override; delegating to base implementation")
        return superFunc(self, text, modEnv)
    end

    if modEnv == nil and MOD_ROUTED_KEYS[text] then
        Log:trace("I18N: routing modless lookup '%s' through mod env", text)
        return superFunc(self, text, modName)
    end

    if isGithubVersion and string.contains(text, "rl_") then

        local env = self.modEnvironments[modName]

        if env == nil then return superFunc(self, text, modEnv) end

        if env.texts[text .. "_github"] ~= nil then return env.texts[text .. "_github"] end

    end

    return superFunc(self, text, modEnv)

end

I18N.getText = Utils.overwrittenFunction(I18N.getText, RL_I18N.getText)