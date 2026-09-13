------------------------------------------------------------
-- MAGICBURST.LUA
--
-- Shared Magic Burst engine for:
-- BLM / GEO / SCH / NIN / RDM
--
-- Job profiles define which spells are available.
-- This file only handles:
--
--   * Reading the skillchain's component elements
--   * Finding the best available burst spell
--   * Checking burst conditions
--   * Casting the burst
--
-- Requires globals/functions from lazy.lua:
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
--   sc_get_elements()   -- from skillchain.lua
--   res
--   windower
------------------------------------------------------------


------------------------------------------------------------
-- FFXI ELEMENT NAME -> JOB PROFILE burst_spells KEY
--
-- skillchain.lua's sc_info speaks in plain FFXI element names
-- (Fire, Ice, Wind, Earth, Lightning, Water, Light, Dark).
-- Job profiles key burst_spells by the in-game SPELL FAMILY
-- name instead, which only matches for Fire/Water/Light: Ice
-- nukes are "Blizzard", Wind nukes are "Aero", Earth nukes are
-- "Stone", Lightning nukes are "Thunder", and Dark is written
-- "Darkness" in every profile. Get_Burst_Spell() below relies
-- on this table to bridge the two -- this used to be a partial/
-- inconsistent translation (or missing entirely), which is why
-- bursting worked for some skillchains and silently did nothing
-- for others (Fragmentation/Distortion/Gravitation/Scission/
-- Detonation/Impaction, and the Wind/Ice/Earth/Lightning
-- components of bigger chains like Light/Darkness/Fusion/etc.).
------------------------------------------------------------

local ELEMENT_TO_KEY = {
    Fire = 'Fire',
    Ice = 'Blizzard',
    Wind = 'Aero',
    Earth = 'Stone',
    Lightning = 'Thunder',
    Water = 'Water',
    Light = 'Light',
    Dark = 'Darkness',
    Darkness = 'Darkness',   -- skillchain.lua's sc_info spells this one out fully
}

------------------------------------------------------------
-- FIND BURST SPELL
--
-- A skillchain gives a magic burst bonus to EVERY element listed
-- in its sc_info entry, not just one -- e.g. a "Light" chain
-- bursts with Fire, Wind, Lightning, OR Light magic. This tries
-- every component element the active skillchain actually
-- supports, in the priority order skillchain.lua lists them
-- (strongest bonus first), and within each element's spell list,
-- the strongest currently-castable tier.
--
-- Example:
--
--   SC = Light  ->  elements = {Fire, Wind, Lightning, Light}
--
--   BLM profile:
--      Fire:  Fire VI, Fire V, Fire IV
--      Aero:  Aero VI, Aero V, Aero IV
--      ...
--
-- If Fire is all on cooldown, this falls through to try Aero
-- (Wind) next, rather than giving up on the whole burst just
-- because the first-choice element wasn't available.
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
    -- All elements this skillchain supports, strongest first.
    --------------------------------------------------------

    local elements = sc_get_elements(target.id)

    if not elements or #elements == 0 then
        return nil
    end

    --------------------------------------------------------
    -- Player / recasts.
    --------------------------------------------------------

    local player = windower.ffxi.get_player()

    if not player then
        return nil
    end

    local recasts = windower.ffxi.get_spell_recasts()

    --------------------------------------------------------
    -- Try each supported element in order; within each,
    -- try each tier strongest -> weakest.
    --------------------------------------------------------

    for _, sc_element in ipairs(elements) do
        local key = ELEMENT_TO_KEY[sc_element]
        local candidates = key and active_profile.burst_spells[key]

        if candidates then
            for _, spell_name in ipairs(candidates) do
                local spell = res.spells:with(
                    'name',
                    spell_name
                )

                if spell then
                    local recast = recasts[spell.id]
                    local mp = player.vitals.mp

                    if recast == 0
                        and mp >= spell.mp_cost then

                        return spell_name
                    end
                end
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
    -- Job must have magic burst enabled.
    --------------------------------------------------------

    if not active_profile
        or not active_profile.magic_burst then

        return false
    end

    --------------------------------------------------------
    -- Target.
    --------------------------------------------------------

    local target = windower.ffxi.get_mob_by_target('t')

    if not target then
        return false
    end

    if target.hpp <= 0 then
        return false
    end

    --------------------------------------------------------
    -- Blacklist.
    --------------------------------------------------------

    if Is_Blacklisted(target.name) then
        return false
    end

    --------------------------------------------------------
    -- There must be an active skillchain.
    --------------------------------------------------------

    if not sc_active(target.id) then
        return false
    end

    --------------------------------------------------------
    -- Must be inside the burst window.
    --------------------------------------------------------

    if not sc_ready(target.id) then
        return false
    end

    --------------------------------------------------------
    -- Don't interrupt another action.
    --------------------------------------------------------

    if isCasting
        or isBusy > 0 then

        return false
    end

    --------------------------------------------------------
    -- Don't try to cast while moving.
    --------------------------------------------------------

    if Is_Moving() then
        return false
    end

    --------------------------------------------------------
    -- Find the strongest available spell.
    --------------------------------------------------------

    local spell_name = Get_Burst_Spell(target)

    if not spell_name then
        return false
    end

    --------------------------------------------------------
    -- Resolve spell.
    --------------------------------------------------------

    local spell = res.spells:with(
        'name',
        spell_name
    )

    if not spell then
        return false
    end

    --------------------------------------------------------
    -- Final MP / recast check.
    --------------------------------------------------------

    local player = windower.ffxi.get_player()

    if not player then
        return false
    end

    local recasts = windower.ffxi.get_spell_recasts()

    if recasts[spell.id] ~= 0 then
        return false
    end

    if player.vitals.mp < spell.mp_cost then
        return false
    end

    --------------------------------------------------------
    -- CAST
    --------------------------------------------------------

    windower.send_command(
        'input /ma "'..
        spell_name..
        '" <t>'
    )

    isBusy = Action_Delay

    return true
end