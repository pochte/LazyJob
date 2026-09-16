--GEO JOB PROFILE 
JOB_PROFILES.GEO = {
    auto_engage = false,
    use_weaponskills = false,
    self_buffs = {
        { name = 'Indi-Fury', interval = 3 },
    },
    self_abilities = {
        { name = 'Radial Arcana', interval = 1, require_pet = true, max_mp_percent = 50, min_pet_hpp = 20 },
        { name = 'Dematerialize', interval = 1, require_pet = true, max_pet_hpp = 30 },
        { name = 'Life Cycle', interval = 1, require_pet = true, max_pet_hpp = 40 },
    },
    entrust_buffs = {
        { ability = 'Entrust', spell = 'Indi-Refresh', targets = { jobs = { 'RDM', 'WHM', 'SCH' } }, interval = 1 },
    },
    debuffs = {
        {
            name = 'Geo-Frailty',
            target = '<bt>',
            interval = 3,
            require_no_pet = true,
            use_ability_before = 'Blaze of Glory',
            use_ability_after = 'Ecliptic Attrition',
        },
    },
    dispel = {
        spell = 'Dispel',
        interval = 20,        
    },
    magic_burst = true,
    burst_spells = {
        Aero = { 'Aero V', 'Aero IV', 'Aero III' },
        Fire = { 'Fire V', 'Fire IV', 'Fire III' },
        Blizzard = { 'Blizzard V', 'Blizzard IV', 'Blizzard III' },
        Stone = { 'Stone V', 'Stone IV', 'Stone III' },
        Thunder = { 'Thunder V', 'Thunder IV', 'Thunder III' },
        Water = { 'Water V', 'Water IV', 'Water III' },
        Darkness = { 'Impact' },
    },
    cure_bot_active = true,
    cure_tiers = {
        { min_missing = 100, max_missing = 350, spells = { 'Cure II', 'Cure' } },
        { min_missing = 351, max_missing = 800, spells = { 'Cure III', 'Cure II' } },
        { min_missing = 801, max_missing = 999999, spells = { 'Cure IV', 'Cure III' } },
    },
}