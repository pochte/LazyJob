------------------------------------------------------------
-- MAGIC BURST MODULE
------------------------------------------------------------

mb_window = mb_window or {}

-- Map Skillchains to primary/secondary elements
local element_map = {
    ['Light']         = {'Fire', 'Wind', 'Lightning', 'Light'},
    ['Darkness']      = {'Earth', 'Water', 'Ice', 'Dark'},
    ['Fusion']        = {'Fire', 'Light'},
    ['Fragmentation'] = {'Wind', 'Lightning'},
    ['Distortion']    = {'Ice', 'Water'},
    ['Gravitation']   = {'Earth', 'Dark'},
    ['Liquefaction']  = {'Fire'},
    ['Induration']   = {'Ice'},
    ['Reverberation'] = {'Water'},
    ['Transmutation'] = {'Lightning'},
    ['Scission']      = {'Earth'},
    ['Detonation']    = {'Wind'},
    ['Compression']   = {'Dark'},
    ['Impaction']     = {'Lightning'}
}

-- Map elemental affinity to spell names for burst jobs
local spell_tier_map = {
    ['BLM'] = {
        ['Fire']      = 'Fire V',
        ['Ice']       = 'Blizzard V',
        ['Wind']      = 'Aero V',
        ['Earth']     = 'Stone V',
        ['Lightning'] = 'Thunder V',
        ['Water']     = 'Water V',
        ['Light']     = 'Holy',
        ['Dark']      = 'Comet'
    },
    ['SCH'] = {
        ['Fire']      = 'Fire V',
        ['Ice']       = 'Blizzard V',
        ['Wind']      = 'Aero V',
        ['Earth']     = 'Stone V',
        ['Lightning'] = 'Thunder V',
        ['Water']     = 'Water V',
        ['Light']     = 'Luminohelix',
        ['Dark']      = 'Noctohelix'
    },
    ['GEO'] = {
        ['Fire']      = 'Fire V',
        ['Ice']       = 'Blizzard V',
        ['Wind']      = 'Aero V',
        ['Earth']     = 'Stone V',
        ['Lightning'] = 'Thunder V',
        ['Water']     = 'Water V'
    },
    ['NIN'] = {
        ['Fire']      = 'Katon: San',
        ['Ice']       = 'Huton: San',
        ['Wind']      = 'Hyoton: San',
        ['Earth']     = 'Doton: San',
        ['Lightning'] = 'Raiton: San',
        ['Water']     = 'Suiton: San'
    }
}

-- Target tracking for active Skillchains
windower.register_event('incoming chunk', function(id, data)
    if id == 0x028 then
        local action = packets.parse('incoming', data)
        -- Category 11: Weapon Skill execution / Skillchain creation
        if action.Category == 11 or action.Category == 13 then
            local target_id = action['Target 1 ID']
            local sc_id = action['Target 1 Primary Animation']
            
            -- Map animation/effect to Skillchain element if present
            if sc_id and sc_id > 0 then
                local sc_info = res.skillchains[sc_id]
                if sc_info then
                    mb_window[target_id] = {
                        name = sc_info.en,
                        expires = os.clock() + 8.0 -- MB window duration (~8s)
                    }
                end
            end
        end
    end
end)

------------------------------------------------------------
-- GLOBAL FUNCTION CALLED BY LAZY.LUA
------------------------------------------------------------
function Try_Magic_Burst()
    local target = windower.ffxi.get_mob_by_target('t')
    if not target then return false end

    local window = mb_window[target.id]
    if not window then return false end

    -- Check if window expired
    if os.clock() > window.expires then
        mb_window[target.id] = nil
        return false
    end

    local elements = element_map[window.name]
    if not elements or #elements == 0 then return false end

    local job = current_job or 'DEFAULT'
    local job_spells = spell_tier_map[job]
    if not job_spells then return false end

    -- Pick the primary element spell
    local primary_elem = elements[1]
    local spell_to_cast = job_spells[primary_elem]

    if spell_to_cast and Can_Cast_Spell(spell_to_cast) then
        if Cast_Spell_On(spell_to_cast, '<t>') then
            -- Clear the burst window state so we don't attempt duplicate bursts on the same window
            mb_window[target.id] = nil
            return true
        end
    end

    return false
end