JOB_PROFILES.RDM = {
    auto_engage = true,
    use_weaponskills = true,

    weaponskills = {
        primary_ws = 'Savage Blade',
        min_tp = 1000,
    },

    self_buffs = {
        { name = 'Haste II', interval = 23 },
        { name = 'Temper II', interval = 5 },
        { name = 'Gain-STR', interval = 15 },
        { name = 'Enfire II', interval = 20 },
    },

    debuffs = {
        { name = 'Distract III' },
        { name = 'Inundation' },
        { name = 'Dia III' },
    },

    party_buffs = {
        {
            spell = 'Haste II',
            targets = 'ALL_PLAYERS',
            interval = 10,
            range = 20,
            self = false,
        },
        {
            spell = 'Refresh III',
            targets = { jobs = { 'RDM', 'WHM', 'SCH', 'BLM', 'GEO', 'PLD' } },
            interval = 8,
            range = 20,
            self = false,
        },
    },

    self_abilities = {
        { name = 'Composure', interval = 20 },
        { name = 'Saboteur', interval = 3 },
        { name = 'Haste Samba', interval = 1 },
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

    emergency_cure = true,
    emergency_cure_threshold = 25,

    cure_tiers = {
        { max_missing = 250, spells = { 'Cure II', 'Cure' } },
        { max_missing = 600, spells = { 'Cure III', 'Cure II' } },
        { max_missing = math.huge, spells = { 'Cure IV', 'Cure III' } },
    },
}