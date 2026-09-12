------------------------------------------------------------
-- BLM JOB PROFILE
------------------------------------------------------------
--
-- Black Mage -- magic burst spell tiers (Tier VI cap).
--
-- Loaded by Lazy.lua into JOB_PROFILES.BLM
------------------------------------------------------------

JOB_PROFILES.BLM = {

    --------------------------------------------------------
    -- MELEE / ENGAGE SETTINGS
    --------------------------------------------------------

    auto_engage = false,
    use_weaponskills = false,

    --------------------------------------------------------
    -- SUPPORT / BUFFS
    --------------------------------------------------------

    self_buffs = {
        { name = {'Thunderstorm'}, interval = 3, require_buff = 'Dark Arts' },
        { name = {'Klimaform'}, interval = 3 },
    },

    --------------------------------------------------------
    -- MAGIC BURST
    --------------------------------------------------------

    magic_burst = true,

    burst_spells = {
        Fire     = { 'Fire VI', 'Fire V', 'Fire IV' },
        Blizzard = { 'Blizzard VI', 'Blizzard V', 'Blizzard IV' },
        Aero     = { 'Aero VI', 'Aero V', 'Aero IV' },
        Stone    = { 'Stone VI', 'Stone V', 'Stone IV' },
        Thunder  = { 'Thunder VI', 'Thunder V', 'Thunder IV' },
        Water    = { 'Water VI', 'Water V', 'Water IV' },
        Darkness = { 'Comet', 'Impact' },
    },

    --------------------------------------------------------
    -- CURE BOT
    --------------------------------------------------------

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