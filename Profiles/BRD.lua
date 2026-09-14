------------------------------------------------------------
-- BRD JOB PROFILE
------------------------------------------------------------
--
-- Bard -- Party songs, self buffs.
--
-- Loaded by Lazy.lua into JOB_PROFILES.BRD
------------------------------------------------------------

JOB_PROFILES.BRD = {

    --------------------------------------------------------
    -- MELEE / ENGAGE SETTINGS
    --------------------------------------------------------

    auto_engage = false,
    use_weaponskills = false,

    haste_active = false,
    self_buffs = {},

    --------------------------------------------------------
    -- PARTY SONGS
    --------------------------------------------------------

    party_buffs = {
        -- Put actual songs you want to sing here.
        { spell = 'Victory March',  targets = 'ALL_PLAYERS', interval = 3, range = 20, self = true },
        { spell = 'Honor March',    targets = 'ALL_PLAYERS', interval = 3, range = 20, self = true },
        { spell = 'Valor Minuet V', targets = 'ALL_PLAYERS', interval = 3, range = 20, self = true },
        { spell = 'Valor Minuet V', targets = 'ALL_PLAYERS', interval = 3, range = 20, self = true },
        { spell = 'Blade Madrigal', targets = 'ALL_PLAYERS', interval = 3, range = 20, self = true },
    },

    --------------------------------------------------------
    -- TARGET DEBUFFS
    --------------------------------------------------------

    debuffs = {
        { name = {'Light Threnody II', 'Light Threnody'}, target = '<bt>', interval = 3 },
        { name = 'Carnage Elegy',                         target = '<bt>', interval = 3 },
        { name = 'Foe Requiem VII',                       target = '<bt>', interval = 3 },
    },

    --------------------------------------------------------
    -- TARGET DISPEL
    --------------------------------------------------------
    -- BRD has no Dispel; Finale strips a buff instead.

    dispel = {
        spell = 'Finale',
        interval = 20, -- seconds; blind safety cast, not gated on buff detection
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

    needed_buffs = {},

    food = 'Red Curry Bun',
}