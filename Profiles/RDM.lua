JOB_PROFILES.RDM = {
    auto_engage = true,
    use_weaponskills = true,
    ws_sc_starter = {
        'Savage Blade',
        1000,
    },
    ws_sc_closers = {
        'Savage Blade',
    },
    self_buffs = {
        { name = 'Haste II', interval = 23 },
        { name = 'Refresh III', interval = 8 },
        { name = 'Temper II', interval = 5 },
        { name = 'Gain-STR', interval = 15 },
        { name = 'Enfire II', interval = 20 },
    },
    debuffs = {
        { name = 'Distract III', once_per_mob = true },
        { name = 'Inundation', once_per_mob = true },
        { name = 'Dia III', once_per_mob = true },
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
        { max_missing = 600, spells = { 'Cure III', 'Cure II' } },
        { max_missing = math.huge, spells = { 'Cure IV', 'Cure III' } },
    },
}