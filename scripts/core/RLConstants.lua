-- RLConstants.lua
-- Shared constants used across the mod (area codes, days per month, marks,
-- etc.). Extracted from RealisticLivestock.lua to break reverse dependency.

RLConstants = {}

local Log = RmLogging.getLogger("RLRM")


RLConstants.MARKS = {
    ["AI_MANAGER_SELL"] = {
        ["key"] = "AI_MANAGER_SELL",
        ["active"] = false,
        ["priority"] = 3,
        ["text"] = "aiManager_sell"
    },
    ["AI_MANAGER_CASTRATE"] = {
        ["key"] = "AI_MANAGER_CASTRATE",
        ["active"] = false,
        ["priority"] = 5,
        ["text"] = "aiManager_castrate"
    },
    ["AI_MANAGER_DISEASE"] = {
        ["key"] = "AI_MANAGER_DISEASE",
        ["active"] = false,
        ["priority"] = 2,
        ["text"] = "aiManager_disease"
    },
    ["AI_MANAGER_INSEMINATE"] = {
        ["key"] = "AI_MANAGER_INSEMINATE",
        ["active"] = false,
        ["priority"] = 4,
        ["text"] = "aiManager_ai"
    },
    ["AI_MANAGER_MOVE"] = {
        ["key"] = "AI_MANAGER_MOVE",
        ["active"] = false,
        ["priority"] = 6,
        ["text"] = "aiManager_move"
    },
    ["PLAYER"] = {
        ["key"] = "PLAYER",
        ["active"] = false,
        ["priority"] = 1,
        ["text"] = "player"
    }
}


RLConstants.MAP_TO_AREA_CODE = {
    ["Riverbend Springs"] = 2,
    ["Hutan Pantai"] = 3,
    ["Zielonka"] = 5,
    ["Zacieczki"] = 5,
    ["Szpakowo"] = 5,
    ["Pallegney"] = 4,
    ["Oberschwaben"] = 6,
    ["Starowies"] = 5,
    ["Lipinki"] = 5,
    ["Rhönplateu"] = 6,
    ["Schwesing Bahnhof"] = 6,
    ["Riverview"] = 1,
    ["Sobolewo"] = 5,
    ["Tässi Farm"] = 8,
    ["HORSCH AgroVation"] = 10,
    ["New Bartelshagenn"] = 6,
    ["HermannsHausen"] = 5,
    ["Oak Bridge Farm"] = 1,
    ["Calmsden Farm"] = 1,
    ["Frankenmuth Farming Map"] = 2,
    ["North Frisian 25"] = 6,
    ["Alma, Missouri"] = 2,
    ["Michigan Map"] = 2
}

RLConstants.AREA_CODES = {
    [1] = {
        ["code"] = "UK",
        ["country"] = "United Kingdom"
    },
    [2] = {
        ["code"] = "US",
        ["country"] = "United States"
    },
    [3] = {
        ["code"] = "CH",
        ["country"] = "China"
    },
    [4] = {
        ["code"] = "FR",
        ["country"] = "France"
    },
    [5] = {
        ["code"] = "PL",
        ["country"] = "Poland"
    },
    [6] = {
        ["code"] = "DE",
        ["country"] = "Germany"
    },
    [7] = {
        ["code"] = "CA",
        ["country"] = "Canada"
    },
    [8] = {
        ["code"] = "EE",
        ["country"] = "Estonia"
    },
    [9] = {
        ["code"] = "IT",
        ["country"] = "Italy"
    },
    [10] = {
        ["code"] = "CZ",
        ["country"] = "Czech Republic"
    },
    [11] = {
        ["code"] = "RU",
        ["country"] = "Russia"
    },
    [12] = {
        ["code"] = "SW",
        ["country"] = "Sweden"
    },
    [13] = {
        ["code"] = "NO",
        ["country"] = "Norway"
    },
    [14] = {
        ["code"] = "FI",
        ["country"] = "Finland"
    },
    [15] = {
        ["code"] = "JP",
        ["country"] = "Japan"
    },
    [16] = {
        ["code"] = "SP",
        ["country"] = "Spain"
    }
}


-- Reverse lookup: RL area-code string ("DE") -> AREA_CODES index. Built once
-- from AREA_CODES so the two tables can never drift.
RLConstants.AREA_CODES_BY_CODE = {}

for index, entry in ipairs(RLConstants.AREA_CODES) do
    RLConstants.AREA_CODES_BY_CODE[entry.code] = index
end


RLConstants.DAYS_PER_MONTH = {
    [1] = 31,
    [2] = 28,
    [3] = 31,
    [4] = 30,
    [5] = 31,
    [6] = 30,
    [7] = 31,
    [8] = 31,
    [9] = 30,
    [10] = 31,
    [11] = 30,
    [12] = 31
}


RLConstants.START_YEAR = {
    ["FULL"] = 2024,
    ["PARTIAL"] = 24
}


-- AI insemination straw-purchase quantity ladder. A CONTIGUOUS 1..22 array:
-- consumers both iterate it with pairs() (to build stepper labels) and index it
-- positionally by stepper state ([state]), so the order and the gap-free 1..22
-- keys are load-bearing - keep it a plain sequence, never a sparse map.
RLConstants.DEWAR_QUANTITIES = {
    1,
    2,
    3,
    4,
    5,
    10,
    15,
    20,
    25,
    30,
    40,
    50,
    75,
    100,
    150,
    200,
    250,
    300,
    400,
    500,
    750,
    1000
}


-- Genetics domain bounds. Every genetics trait value the mod generates, stores
-- or transports lives in [GENETICS_MIN, GENETICS_MAX]. This is the intended one
-- home for the domain: RLGeneticsDraw reads these rather than carrying its own
-- copies, and new consumers are expected to do the same. Retrofitting the
-- literals that predate this constant is tracked separately and NOT done yet,
-- so hardcoded 0.25 / 1.75 / 1.5 still survive across the tree. GENETICS_SPAN is
-- DERIVED, never a literal, so it cannot drift from the bounds it summarises.
RLConstants.GENETICS_MIN = 0.25
RLConstants.GENETICS_MAX = 1.75
RLConstants.GENETICS_SPAN = RLConstants.GENETICS_MAX - RLConstants.GENETICS_MIN


-- Maximum lifespan in months per animal type, keyed by the UPPERCASE type NAME.
-- The index is registration order and shifts with load order, so a name is the
-- only stable key; the caller resolves the name and passes it.
--
-- The same numbers already appear in the old-age death mechanic, in two places:
-- AnimalHealth.calculateOldAgeMonthlyAnimalDeaths and
-- RealisticLivestock.calculateOldAgeMonthlyAnimalDeaths. This table is a THIRD
-- copy and nothing compares the three - both of those hold their numbers inline
-- in an if/elseif chain, which no test can read - so a change here has to be
-- made in all three by hand.
--
-- A type absent from this table has no entry rather than a default, matching
-- what the two authorities do with an unrecognised type: they leave it at a
-- minAge of 20000 and it never dies of old age.
--
-- READ-ONLY by contract. Consumers share this object rather than a copy, so a
-- mutation reaches all of them; there is deliberately no defensive copy and no
-- metatable freeze.
RLConstants.MAX_LIFESPAN_MONTHS_BY_TYPE = {
    COW = 240,
    PIG = 240,
    SHEEP = 144,
    HORSE = 360,
    CHICKEN = 96
}


Log:info("RLConstants loaded")
