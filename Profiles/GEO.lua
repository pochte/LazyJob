-- GEO JOB PROFILE 
JOB_PROFILES.GEO = {
       -- MELEE / ENGAGE SETTINGS
    auto_engage = false,
    use_weaponskills = false,
       -- SELF BUFFS & ABILITIES
    self_buffs = {
        { name = 'Indi-Fury', interval = 3 },
    },
    
	-- FREE NUKE (//lazy freenuke). Tier IV and lower are cast on the target
	-- between bursts; V and VI are saved for magic burst.
	free_nuke = true,
	free_nuke_max_tier = 3,
	free_nuke_weather = true, -- failsafe: cast the matching Storm if the weather is wrong
    self_abilities = {
        -- Restores MP using Luopan when player MP drops below 50%
        { 
            name = 'Radial Arcana', 
            interval = 1, 
            require_pet = true, 
            max_mp_percent = 50, 
            min_pet_hpp = 20 
        }, 
        -- Grants Luopan temporary invulnerability when HP drops below 30%
        { 
            name = 'Dematerialize', 
            interval = 1, 
            require_pet = true, 
            max_pet_hpp = 30 
        },
        -- Restores Luopan HP when it drops below 40%
        { 
            name = 'Life Cycle', 
            interval = 1, 
            require_pet = true, 
            max_pet_hpp = 40 
        },
    },
    -- ENTRUST BUFFS
    -- Indi-Refresh on a mage player if one's in range; otherwise Indi-Frailty on any player.
    entrust_buffs = {
        {
            ability  = 'Entrust',
            spell    = 'Indi-Refresh',
            targets  = { jobs = { 'RDM', 'WHM', 'SCH', 'BLM', 'SMN', } },
            interval = 1,
        },
        {
            -- The only other player, job unreadable, holds party leader:
            -- assume a melee leader and give them Indi-Haste.
            ability  = 'Entrust',
            spell    = 'Indi-Haste',
            targets  = { lone_leader_unknown_job = true },
            interval = 1,
        },
        {
            ability  = 'Entrust',
            spell    = 'Indi-Frailty',
            targets  = { players_only = true },
            fallback = true,  -- only when no mage target exists
            interval = 1,
        },
    },
-- TARGET DEBUFFS
debuffs = {
    {
        name = 'Geo-Frailty',
        target = '<bt>',
        interval = 1,
        require_no_pet = true,
        recast_if_no_pet = true,
        use_ability_before = 'Blaze of Glory',
        use_ability_after = 'Ecliptic Attrition',
    },
},

    
       -- MAGIC BURST
    magic_burst = true,
    burst_spells = {
        Fire     = { 'Fire V', 'Fire IV', 'Fire III' },
        Blizzard = { 'Blizzard V', 'Blizzard IV', 'Blizzard III' },
        Aero     = { 'Aero V', 'Aero IV', 'Aero III' },
        Stone    = { 'Stone V', 'Stone IV', 'Stone III' },
        Thunder  = { 'Thunder V', 'Thunder IV', 'Thunder III' },
        Water    = { 'Water V', 'Water IV', 'Water III' },
        Darkness = { 'Impact' },
    },
       -- CURE BOT
    cure_bot_active = true,
    cure_tiers = {
        {
            min_missing = 100,
            max_missing = 350,
            spells = { 'Cure II', 'Cure' },
        },
        {
            min_missing = 351,
            max_missing = 800,
            spells = { 'Cure III', 'Cure II' },
        },
        {
            min_missing = 801,
            max_missing = 999999,
            spells = { 'Cure IV', 'Cure III' },
        },
    },
}