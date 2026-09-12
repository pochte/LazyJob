------------------------------------------------------------
-- GEO JOB PROFILE
------------------------------------------------------------

JOB_PROFILES.GEO = {

    --------------------------------------------------------
    -- MELEE / ENGAGE SETTINGS
    --------------------------------------------------------

    auto_engage = false,
    use_weaponskills = false,

    --------------------------------------------------------
    -- SELF BUFFS & ABILITIES
    --------------------------------------------------------

    self_buffs = {
        { name = 'Indi-Fury', interval = 3 },
    },

    self_abilities = {
        -- Restores MP using Luopan when player MP drops below 50%
        {
            name = 'Radial Arcana',
            interval = 1,
            require_pet = true,
            max_mp_percent = 50,
            min_pet_hpp = 20,
        },

        -- Grants Luopan temporary invulnerability when HP drops below 30%
        {
            name = 'Dematerialize',
            interval = 1,
            require_pet = true,
            max_pet_hpp = 30,
        },

        -- Restores Luopan HP when it drops below 40%
        {
            name = 'Life Cycle',
            interval = 1,
            require_pet = true,
            max_pet_hpp = 40,
        },
    },

    --------------------------------------------------------
    -- ENTRUST BUFFS
    --------------------------------------------------------

    entrust_buffs = {
        {
            ability = 'Entrust',
            spell = 'Indi-Refresh',
            targets = { jobs = { 'RDM', 'WHM', 'SCH' } },
            interval = 1,
        },
    },

    --------------------------------------------------------
    -- TARGET DEBUFFS
    --------------------------------------------------------

    debuffs = {
        {
            name = 'Geo-Frailty',
            target = '<bt>',
            interval = 3,
            require_no_pet = true,                    -- Avoids recasting if Luopan is currently active
            use_ability_before = 'Blaze of Glory',     -- Pops BoG before summoning Luopan
            use_ability_after = 'Ecliptic Attrition',  -- Pops Ecliptic Attrition right after Luopan is summoned
        },
    },

    --------------------------------------------------------
    -- MAGIC BURST
    --------------------------------------------------------

    magic_burst = true,

    burst_spells = {
        Aero     = { 'Aero V', 'Aero IV', 'Aero III' },
        Fire     = { 'Fire V', 'Fire IV', 'Fire III' },
        Blizzard = { 'Blizzard V', 'Blizzard IV', 'Blizzard III' },
        Stone    = { 'Stone V', 'Stone IV', 'Stone III' },
        Thunder  = { 'Thunder V', 'Thunder IV', 'Thunder III' },
        Water    = { 'Water V', 'Water IV', 'Water III' },
        Darkness = { 'Impact' },
    },

    --------------------------------------------------------
    -- CURE BOT
    --------------------------------------------------------

    cure_bot_active = true,

    cure_tiers = {
        {min_missing = 100,max_missing = 350,spells = {'Cure II','Cure'}},
        {min_missing = 351,max_missing = 800,spells = {'Cure III','Cure II'}},
        {min_missing = 801,max_missing = 999999,spells = {'Cure IV','Cure III'}},
    },
}