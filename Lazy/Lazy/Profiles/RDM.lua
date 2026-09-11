------------------------------------------------------------
-- RDM JOB PROFILE
------------------------------------------------------------
--
-- Red Mage -- frontline melee, debuff, party buffs, weaponskills.
--
-- Loaded by Lazy.lua into JOB_PROFILES.RDM
------------------------------------------------------------

JOB_PROFILES.RDM = {

    --------------------------------------------------------
    -- MELEE / ENGAGE SETTINGS
    --------------------------------------------------------

    auto_engage = true,
    use_weaponskills = true,

    weaponskills = {
        primary_ws = 'Savage Blade',
        min_tp = 1000,
    },

    --------------------------------------------------------
    -- SELF BUFFS
    --------------------------------------------------------

    self_buffs = {
        { name = 'Refresh III',   interval = 15 },
        { name = 'Haste II',      interval = 23 },
        { name = 'Temper II',     interval = 5  },
        { name = 'Gain-STR',      interval = 15 },
        { name = 'Enfire II',     interval = 20 },
    },

    --------------------------------------------------------
    -- DEBUFFS (Cast ONCE per target ID)
    --------------------------------------------------------

    debuffs = {
        { name = 'Distract III' },
        { name = 'Inundation' },
        { name = 'Dia III' },
    },

    --------------------------------------------------------
    -- PARTY BUFFS
    --------------------------------------------------------

    party_buffs = {

        {
            spell     = 'Haste II',
            targets   = 'ALL_PLAYERS',
            interval  = 10,
            range     = 20,
            self      = false,
        },

        {
            spell     = 'Refresh III',
            targets   = {
                jobs = { 'RDM', 'WHM', 'SCH', 'BLM', 'GEO', 'PLD' }
            },
            interval  = 8,
            range     = 20,
            self      = false,
        },
    },

    --------------------------------------------------------
    -- JOB ABILITIES
    --------------------------------------------------------

    self_abilities = {
        { name = 'Composure',   interval = 20 },
        { name = 'Saboteur',    interval = 3 },
        { name = 'Haste Samba', interval = 1 },
    },

    --------------------------------------------------------
    -- FAILSAFE CURING
    --
    -- Not the intended healer -- normally a WHM trust/player is
    -- handling that -- but if anyone drops to 25% HP anyway,
    -- something's clearly gone wrong on the healer's end, and
    -- this steps in to keep the party alive. Tiers capped at
    -- Cure IV (what RDM actually has); doesn't fire at all unless
    -- someone's genuinely in trouble.
    --------------------------------------------------------

    emergency_cure           = true,
    emergency_cure_threshold = 25,

    cure_tiers = {
        {
            max_missing = 250,
            spells = {
                'Cure II',
                'Cure',
            },
        },

        {
            max_missing = 600,
            spells = {
                'Cure III',
                'Cure II',
            },
        },

        {
            max_missing = math.huge,
            spells = {
                'Cure IV',
                'Cure III',
            },
        },
    },
}