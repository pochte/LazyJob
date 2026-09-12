------------------------------------------------------------
-- SCH JOB PROFILE
------------------------------------------------------------
--
-- Scholar -- magic burst spell tiers, backup cure bot when no WHM.
--
-- Loaded by Lazy.lua into JOB_PROFILES.SCH
------------------------------------------------------------

JOB_PROFILES.SCH = {

    --------------------------------------------------------
    -- MELEE / ENGAGE SETTINGS
    --------------------------------------------------------

    auto_engage = false,
    use_weaponskills = false,

    haste_active = false,

    --------------------------------------------------------
    -- ARTS-GATED STORM MAINTENANCE
    --
    -- Thunderstorm only goes up (and stays up) while in Dark Arts,
    -- for magic bursting. Aurorastorm only goes up while in Light
    -- Arts, for cure potency. require_buff checks the player's own
    -- buff list, so each only fires in its matching stance.
    --------------------------------------------------------

    self_buffs = {
        { name = {'Thunderstorm II', 'Thunderstorm'}, interval = 4, require_buff = 'Dark Arts' },
        { name = 'Aurorastorm', interval = 4, require_buff = 'Light Arts' },
        { name = {'Klimaform'}, interval = 3 },
    },

    --------------------------------------------------------
    -- MAGIC BURST
    --
    -- Only attempted while in Dark Arts.
    --------------------------------------------------------

    magic_burst = true,
    magic_burst_requires_buff = 'Dark Arts',

    burst_spells = {
        Fire     = { 'Fire V', 'Fire IV', 'Fire III' },
        Blizzard = { 'Blizzard V', 'Blizzard IV', 'Blizzard III' },
        Aero     = { 'Aero V', 'Aero IV', 'Aero III' },
        Stone    = { 'Stone V', 'Stone IV', 'Stone III' },
        Thunder  = { 'Thunder V', 'Thunder IV', 'Thunder III' },
        Water    = { 'Water V', 'Water IV', 'Water III' },
        Darkness = { 'Impact' },
    },

    --------------------------------------------------------
    -- CURE BOT
    --
    -- Backup healer when no WHM is in the party, but only actually
    -- cures while in Light Arts.
    --------------------------------------------------------

    cure_bot_if_no_whm = true,
    cure_bot_requires_buff = 'Light Arts',

    cure_tiers = {
        { max_missing = 250,  spells = { 'Cure II', 'Cure' } },
        { max_missing = 600,  spells = { 'Cure III', 'Cure II' } },
        { max_missing = 1100, spells = { 'Cure IV', 'Cure III' } },
        { max_missing = math.huge, spells = { 'Cure IV', 'Cure III' } },
    },
}