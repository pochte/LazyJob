------------------------------------------------------------
-- BLM JOB PROFILE
------------------------------------------------------------
--
-- Black Mage
--
-- SOLO:
--   Repeatedly nukes targets without waiting for skillchains.
--
-- PLAYER PARTY:
--   Uses Magic Burst mode and waits for skillchains.
--
-- Trust-only parties count as SOLO.
--
-- Loaded by Lazy.lua into JOB_PROFILES.BLM
------------------------------------------------------------


------------------------------------------------------------
-- PARTY MODE
------------------------------------------------------------

local function BLM_Has_Real_Player_Party()
    local party = windower.ffxi.get_party()

    if not party then
        return false
    end

    -- p0 is ourselves, so start at p1.
    for i = 1, 5 do
        local member = party['p' .. i]

        if member
            and member.name
            and member.name ~= ''
            and not member.trust
        then
            return true
        end
    end

    return false
end


function BLM_Get_Mode()
    if BLM_Has_Real_Player_Party() then
        return 'BURST'
    end

    return 'SOLO'
end


------------------------------------------------------------
-- BLM JOB PROFILE
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
        { name = {'Windstorm'}, interval = 3, require_buff = 'Dark Arts' },
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
    -- SOLO NUKE MODE
    --------------------------------------------------------
    --
    -- Used when there are no actual player party members.
    -- Trusts do NOT count as players.
    --
    -- Lazy.lua can repeatedly cast from this list instead
    -- of waiting for a skillchain / magic burst window.
    --------------------------------------------------------

    solo_mode = false,

    solo_spells = {
        'Fire VI',
        'Blizzard VI',
        'Aero VI',
        'Stone VI',
        'Thunder VI',
        'Water VI',
    },

    --------------------------------------------------------
    -- CURE BOT
    --------------------------------------------------------

    cure_bot_active = false,

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