
------------------------------------------------------------
-- MAGICBURST.LUA
--
-- Shared magic / burst engine for:
--
--   BLM / RDM / GEO / SCH / NIN
--
-- Handles:
--
--   * Skillchain element detection
--   * Magic Burst spell selection
--   * Magic Burst casting
--   * Solo nuking
--   * BLM SOLO/BURST mode
--   * RDM SOLO/BURST mode
--
-- Job profiles define:
--
--   magic_burst
--   burst_spells
--   solo_spells
--   solo_mode
--
-- Optional profile functions:
--
--   BLM_Get_Mode()
--   RDM_Get_Mode()
--
-- Required globals/functions from lazy.lua:
--
--   active_profile
--   current_job
--   isCasting
--   isBusy
--   Start_Engine
--   Action_Delay
--   Is_Moving()
--   Is_Blacklisted()
--   sc_active()
--   sc_ready()
--   sc_get_property()
--   res
--   windower
------------------------------------------------------------


------------------------------------------------------------
-- SKILLCHAIN ELEMENTS
------------------------------------------------------------

local SC_ELEMENTS = {

    --------------------------------------------------------
    -- LEVEL 4
    --------------------------------------------------------

    Radiance      = 'Light',
    Umbra         = 'Darkness',


    --------------------------------------------------------
    -- LEVEL 3
    --------------------------------------------------------

    Light         = 'Light',
    Darkness      = 'Darkness',

    Gravitation   = 'Earth',
    Fragmentation = 'Wind',
    Distortion    = 'Ice',
    Fusion        = 'Fire',


    --------------------------------------------------------
    -- LEVEL 2
    --------------------------------------------------------

    Compression   = 'Darkness',
    Liquefaction  = 'Fire',
    Induration    = 'Ice',
    Reverberation = 'Water',
    Transfixion   = 'Light',
    Scission      = 'Earth',
    Detonation    = 'Wind',
    Impaction     = 'Lightning',
}


------------------------------------------------------------
-- GET SKILLCHAIN ELEMENT
------------------------------------------------------------

function Get_SC_Element(target)

    if not target then
        return nil
    end

    if not target.id then
        return nil
    end

    if not sc_get_property then
        return nil
    end

    local property =
        sc_get_property(target.id)

    if not property then
        return nil
    end

    return SC_ELEMENTS[property]
end


------------------------------------------------------------
-- GET CURRENT MAGIC TARGET
------------------------------------------------------------

local function Get_Magic_Target()

    local target =
        windower.ffxi.get_mob_by_target('t')

    if not target then
        return nil
    end

    if not target.valid_target then
        return nil
    end

    if not target.is_npc then
        return nil
    end

    if not target.hpp
        or target.hpp <= 0
    then
        return nil
    end

    if not target.id then
        return nil
    end

    if Is_Blacklisted(target.name) then
        return nil
    end

    return target
end


------------------------------------------------------------
-- CAN CAST
------------------------------------------------------------

local function Can_Cast()

    if isCasting then
        return false
    end

    if isBusy > 0 then
        return false
    end

    if Is_Moving() then
        return false
    end

    return true
end


------------------------------------------------------------
-- CAST SPELL
------------------------------------------------------------

local function Cast_Magic_Spell(spell_name)

    if not spell_name then
        return false
    end


    --------------------------------------------------------
    -- Resolve spell.
    --------------------------------------------------------

    local spell =
        res.spells:with(
            'name',
            spell_name
        )

    if not spell then
        return false
    end


    --------------------------------------------------------
    -- Player.
    --------------------------------------------------------

    local player =
        windower.ffxi.get_player()

    if not player then
        return false
    end


    --------------------------------------------------------
    -- Recasts.
    --------------------------------------------------------

    local recasts =
        windower.ffxi.get_spell_recasts()

    if not recasts then
        return false
    end

    if recasts[spell.id] ~= 0 then
        return false
    end


    --------------------------------------------------------
    -- MP.
    --------------------------------------------------------

    if player.vitals.mp < spell.mp_cost then
        return false
    end


    --------------------------------------------------------
    -- Don't cast if something started between checks.
    --------------------------------------------------------

    if isCasting
        or isBusy > 0
    then
        return false
    end

    if Is_Moving() then
        return false
    end


    --------------------------------------------------------
    -- Cast.
    --------------------------------------------------------

    windower.send_command(
        'input /ma "' ..
        spell_name ..
        '" <t>'
    )

    isBusy =
        Action_Delay

    return true
end


------------------------------------------------------------
-- FIND BURST SPELL
------------------------------------------------------------
--
-- The profile supplies spells strongest -> weakest.
--
-- Example:
--
-- Fire = {
--     'Fire VI',
--     'Fire V',
--     'Fire IV',
-- }
--
-- If Fire VI is unavailable, Fire V is tried.
------------------------------------------------------------

function Get_Burst_Spell(target)

    if not target then
        return nil
    end

    if not active_profile then
        return nil
    end

    if not active_profile.burst_spells then
        return nil
    end


    --------------------------------------------------------
    -- Determine SC element.
    --------------------------------------------------------

    local element =
        Get_SC_Element(target)

    if not element then
        return nil
    end


    --------------------------------------------------------
    -- Candidate spells.
    --------------------------------------------------------

    local candidates =
        active_profile.burst_spells[element]

    if not candidates then
        return nil
    end


    --------------------------------------------------------
    -- Player.
    --------------------------------------------------------

    local player =
        windower.ffxi.get_player()

    if not player then
        return nil
    end


    --------------------------------------------------------
    -- Recasts.
    --------------------------------------------------------

    local recasts =
        windower.ffxi.get_spell_recasts()

    if not recasts then
        return nil
    end


    --------------------------------------------------------
    -- Strongest available spell.
    --------------------------------------------------------

    for _, spell_name in ipairs(candidates) do

        local spell =
            res.spells:with(
                'name',
                spell_name
            )

        if spell then

            local recast =
                recasts[spell.id]

            if recast == 0
                and player.vitals.mp >= spell.mp_cost
            then
                return spell_name
            end
        end
    end


    return nil
end


------------------------------------------------------------
-- ATTEMPT MAGIC BURST
------------------------------------------------------------

function Try_Magic_Burst()

    --------------------------------------------------------
    -- Need a profile.
    --------------------------------------------------------

    if not active_profile then
        return false
    end


    --------------------------------------------------------
    -- Profile must support magic bursts.
    --------------------------------------------------------

    if not active_profile.magic_burst then
        return false
    end


    --------------------------------------------------------
    -- Don't interrupt another action.
    --------------------------------------------------------

    if not Can_Cast() then
        return false
    end


    --------------------------------------------------------
    -- Target.
    --------------------------------------------------------

    local target =
        Get_Magic_Target()

    if not target then
        return false
    end


    --------------------------------------------------------
    -- Skillchain must be active.
    --------------------------------------------------------

    if not sc_active(target.id) then
        return false
    end


    --------------------------------------------------------
    -- Must be inside burst window.
    --------------------------------------------------------

    if not sc_ready(target.id) then
        return false
    end


    --------------------------------------------------------
    -- Find strongest available burst spell.
    --------------------------------------------------------

    local spell_name =
        Get_Burst_Spell(target)

    if not spell_name then
        return false
    end


    --------------------------------------------------------
    -- Cast.
    --------------------------------------------------------

    return Cast_Magic_Spell(spell_name)
end


------------------------------------------------------------
-- DETERMINE SOLO / BURST MODE
------------------------------------------------------------
--
-- BLM and RDM can provide their own mode functions.
--
-- Expected return:
--
--   'SOLO'
--   'BURST'
--
-- Generic jobs fall back to active_profile.solo_mode.
------------------------------------------------------------

local function Get_Magic_Mode()

    --------------------------------------------------------
    -- BLM.
    --------------------------------------------------------

    if current_job == 'BLM' then

        if BLM_Get_Mode then
            return BLM_Get_Mode()
        end
    end


    --------------------------------------------------------
    -- RDM.
    --------------------------------------------------------

    if current_job == 'RDM' then

        if RDM_Get_Mode then
            return RDM_Get_Mode()
        end
    end


    --------------------------------------------------------
    -- Generic profile fallback.
    --------------------------------------------------------

    if active_profile
        and active_profile.solo_mode
    then
        return 'SOLO'
    end

    return 'BURST'
end


------------------------------------------------------------
-- ATTEMPT SOLO NUKE
------------------------------------------------------------

function Try_Solo_Nuke()

    --------------------------------------------------------
    -- Need a profile.
    --------------------------------------------------------

    if not active_profile then
        return false
    end


    --------------------------------------------------------
    -- Need solo spells.
    --------------------------------------------------------

    if not active_profile.solo_spells then
        return false
    end


    --------------------------------------------------------
    -- Determine mode.
    --------------------------------------------------------

    if current_job == 'BLM'
        or current_job == 'RDM'
    then

        if Get_Magic_Mode() ~= 'SOLO' then
            return false
        end

    elseif active_profile.solo_mode ~= true then

        return false
    end


    --------------------------------------------------------
    -- Don't interrupt another action.
    --------------------------------------------------------

    if not Can_Cast() then
        return false
    end


    --------------------------------------------------------
    -- Target.
    --------------------------------------------------------

    local target =
        Get_Magic_Target()

    if not target then
        return false
    end


    --------------------------------------------------------
    -- Player.
    --------------------------------------------------------

    local player =
        windower.ffxi.get_player()

    if not player then
        return false
    end


    --------------------------------------------------------
    -- Recasts.
    --------------------------------------------------------

    local recasts =
        windower.ffxi.get_spell_recasts()

    if not recasts then
        return false
    end


    --------------------------------------------------------
    -- Try strongest -> weakest.
    --------------------------------------------------------

    for _, spell_name in ipairs(active_profile.solo_spells) do

        local spell =
            res.spells:with(
                'name',
                spell_name
            )

        if spell then

            local recast =
                recasts[spell.id]

            if recast == 0
                and player.vitals.mp >= spell.mp_cost
            then

                return Cast_Magic_Spell(
                    spell_name
                )
            end
        end
    end


    return false
end


------------------------------------------------------------
-- SKILLCHAIN / MAGIC MONITOR
------------------------------------------------------------
--
-- This is the active engine.
--
-- BLM:
--
--   SOLO  -> repeatedly nuke
--   BURST -> wait for SC and burst
--
-- RDM:
--
--   SOLO  -> repeatedly nuke
--   BURST -> wait for SC and burst
--
-- Other jobs:
--
--   Uses their profile's solo_mode / magic_burst settings.
------------------------------------------------------------

function SC_Monitor()

    while Start_Engine do

        ----------------------------------------------------
        -- Don't interfere with another action.
        ----------------------------------------------------

        if isCasting
            or isBusy > 0
        then

            coroutine.sleep(0.2)

        else

            ------------------------------------------------
            -- SOLO MODE
            ------------------------------------------------

            local solo_done =
                Try_Solo_Nuke()

            if solo_done then

                coroutine.sleep(
                    Action_Delay
                )

            else

                ------------------------------------------------
                -- MAGIC BURST MODE
                ------------------------------------------------

                local burst_done =
                    Try_Magic_Burst()

                if burst_done then

                    coroutine.sleep(
                        Action_Delay
                    )

                else

                    coroutine.sleep(0.2)
                end
            end
        end
    end
end

