
------------------------------------------------------------
-- BLM JOB PROFILE
------------------------------------------------------------
--
-- Loaded by Lazy.lua into JOB_PROFILES.BLM
------------------------------------------------------------


------------------------------------------------------------
-- PARTY MODE
------------------------------------------------------------

local function BLM_Has_Real_Player_Party()
    local party = windower.ffxi.get_party()
    if not party then return false end

    -- p0 is ourselves, so start at p1.
    for i = 1, 5 do
        local member = party['p' .. i]
        if member and member.name and member.name ~= '' and not member.trust then
            return true
        end
    end

    return false
end

function BLM_Get_Mode()
    if BLM_Has_Real_Player_Party() then return 'BURST' end
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
    {name = {'Windstorm'}, interval = 3, party_only = true, require_buff = 'Dark Arts'},
    {name = {'Klimaform'}, interval = 3},
},


    --------------------------------------------------------
    -- JOB ABILITIES
    --------------------------------------------------------
self_abilities = {
    {name = 'Dark Arts', interval = 10},
    {name = 'Sublimation', interval = 5},
    {name = 'Mana Well', interval = 3},
},
    --------------------------------------------------------
    -- MAGIC BURST
    --------------------------------------------------------

    magic_burst = true,

    -- Checked in this order. Aero is always preferred over Fire.
    burst_priority = {
        'Aero',
        'Fire',
        'Blizzard',
        'Stone',
        'Thunder',
        'Water',
        'Darkness',
    },

    burst_spells = {
        Aero = {'Aero VI', 'Aero V', 'Aero IV'},
        Fire = {'Fire VI', 'Fire V', 'Fire IV'},
        Blizzard = {'Blizzard VI', 'Blizzard V', 'Blizzard IV'},
        Stone = {'Stone VI', 'Stone V', 'Stone IV'},
        Thunder = {'Thunder VI', 'Thunder V', 'Thunder IV'},
        Water = {'Water VI', 'Water V', 'Water IV'},
        Darkness = {'Comet', 'Impact'},
    },
    --------------------------------------------------------
    -- CURE BOT
    --------------------------------------------------------

    cure_bot_active = false,

    cure_tiers = {
        {min_missing = 100, max_missing = 350, spells = {'Cure II', 'Cure'}},
        {min_missing = 351, max_missing = 800, spells = {'Cure III', 'Cure II'}},
        {min_missing = 801, max_missing = 999999, spells = {'Cure IV', 'Cure III'}},
    },
}

