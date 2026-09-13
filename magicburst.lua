------------------------------------------------------------
-- MAGICBURST.LUA
--
-- Shared magic / burst engine for:
--   BLM / RDM / GEO / SCH / NIN
--
-- Handles:
--   * Skillchain element detection
--   * Magic Burst spell selection
--   * Magic Burst casting
--   * Solo nuking
--   * BLM SOLO/BURST mode
--   * RDM SOLO/BURST mode
--
-- Job profiles define:
--   magic_burst
--   burst_spells
--   solo_spells
--   solo_mode
--
-- Optional profile functions:
--   BLM_Get_Mode()
--   RDM_Get_Mode()
------------------------------------------------------------


------------------------------------------------------------
-- SKILLCHAIN ELEMENTS
------------------------------------------------------------

local SC_ELEMENTS = {
    -- Level 4 skillchains
    Radiance = 'Wind',
    Umbra = 'Darkness',

    -- Level 3 skillchains
    Light = 'Wind',
    Darkness = 'Darkness',

    -- Level 2 skillchains
    Gravitation = 'Earth',
    Fragmentation = 'Wind',
    Distortion = 'Ice',
    Fusion = 'Fire',

    -- Level 1 skillchains
    Compression = 'Darkness',
    Liquefaction = 'Fire',
    Induration = 'Ice',
    Reverberation = 'Water',
    Transfixion = 'Wind',
    Scission = 'Earth',
    Detonation = 'Wind',
    Impaction = 'Lightning',
}


------------------------------------------------------------
-- SC ELEMENT -> MAGIC ELEMENT
------------------------------------------------------------
--
-- FFXI's skillchain element names do not always match
-- the spell family names used by the profile.
--
-- Wind      -> Aero
-- Lightning -> Thunder
------------------------------------------------------------

local MAGIC_ELEMENTS = {
    Wind = 'Aero',
    Lightning = 'Thunder',
}


------------------------------------------------------------
-- GET SKILLCHAIN ELEMENT
------------------------------------------------------------

function Get_SC_Element(target)
    if not target then return nil end
    if not target.id then return nil end
    if not sc_get_property then return nil end

    local property = sc_get_property(target.id)

    if not property then
        return nil
    end

    return SC_ELEMENTS[property]
end


------------------------------------------------------------
-- GET MAGIC ELEMENT
------------------------------------------------------------

local function Get_Magic_Element(sc_element)
    if not sc_element then
        return nil
    end

    return MAGIC_ELEMENTS[sc_element] or sc_element
end


------------------------------------------------------------
-- GET CURRENT MAGIC TARGET
------------------------------------------------------------

local function Get_Magic_Target()
    local target = windower.ffxi.get_mob_by_target('t')

    if not target then
        return nil
    end

    if not target.valid_target then
        return nil
    end

    if not target.is_npc then
        return nil
    end

    if not target.hpp or target.hpp <= 0 then
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
    -- Absolute casting lock.
    if isCasting then
        return false
    end

    -- Action delay lock.
    if isBusy > 0 then
        return false
    end

    -- Do not cast while resting.
    if mp_resting then
        return false
    end

    -- Do not cast while moving.
    if Is_Moving() then
        return false
    end

    return true
end


------------------------------------------------------------
-- GET SPELL DATA
------------------------------------------------------------

local function Get_Spell_Data(spell_name)
    if not spell_name or spell_name == '' then
        return nil
    end

    return res.spells:with('name', spell_name)
end


------------------------------------------------------------
-- CHECK SPELL AVAILABILITY
------------------------------------------------------------

local function Spell_Is_Available(spell_name, player, recasts)
    if not spell_name then
        return false
    end

    if not player then
        return false
    end

    if not recasts then
        return false
    end

    local spell = Get_Spell_Data(spell_name)

    if not spell then
        return false
    end

    -- Spell must be completely off cooldown.
    if recasts[spell.id] ~= 0 then
        return false
    end

    -- Must have enough MP.
    if player.vitals.mp < spell.mp_cost then
        return false
    end

    return true
end


------------------------------------------------------------
-- CAST MAGIC SPELL
------------------------------------------------------------

local function Cast_Magic_Spell(spell_name)
    if not spell_name then
        return false
    end

    if not Can_Cast() then
        return false
    end

    local spell = Get_Spell_Data(spell_name)

    if not spell then
        return false
    end

    local player = windower.ffxi.get_player()

    if not player then
        return false
    end

    local recasts = windower.ffxi.get_spell_recasts()

    if not recasts then
        return false
    end

    if not Spell_Is_Available(spell_name, player, recasts) then
        return false
    end

    --------------------------------------------------------
    -- Lock immediately before issuing the command.
    --
    -- This prevents another coroutine / combat pass from
    -- trying to issue another spell during this action.
    --------------------------------------------------------

    isBusy = Action_Delay

    windower.send_command(
        'input /ma "' .. spell_name .. '" <t>'
    )

    return true
end


------------------------------------------------------------
-- FIND BURST SPELL
------------------------------------------------------------
--
-- The skillchain determines the ONLY legal element.
--
-- Radiance      -> Wind      -> Aero
-- Light         -> Wind      -> Aero
-- Fragmentation -> Wind      -> Aero
-- Detonation    -> Wind      -> Aero
-- Transfixion   -> Wind      -> Aero
--
-- Impaction     -> Lightning -> Thunder
--
-- Fusion        -> Fire
-- Liquefaction  -> Fire
--
-- Distortion    -> Ice
-- Induration    -> Ice
--
-- Gravitation   -> Earth
-- Scission      -> Earth
--
-- Reverberation -> Water
--
-- Compression  -> Darkness
-- Darkness     -> Darkness
-- Umbra        -> Darkness
--
-- IMPORTANT:
-- burst_priority is NOT used here.
--
-- The skillchain element must always win.
--
-- Example:
--
--   Wind SC  -> Aero VI/V/IV
--   Fire SC  -> Fire VI/V/IV
--
-- We do NOT cast Fire simply because it happens to be
-- earlier in a profile priority list.
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
    -- Read the current skillchain.
    --------------------------------------------------------

    local sc_element = Get_SC_Element(target)

    if not sc_element then
        return nil
    end

    --------------------------------------------------------
    -- Convert FFXI element names to profile spell families.
    --------------------------------------------------------

    local magic_element = Get_Magic_Element(sc_element)

    if not magic_element then
        return nil
    end

    --------------------------------------------------------
    -- Get ONLY the spell list for this SC element.
    --------------------------------------------------------

    local candidates =
        active_profile.burst_spells[magic_element]

    if not candidates then
        return nil
    end

    local player = windower.ffxi.get_player()

    if not player then
        return nil
    end

    local recasts = windower.ffxi.get_spell_recasts()

    if not recasts then
        return nil
    end

    --------------------------------------------------------
    -- Candidates must already be ordered strongest -> weakest
    -- in the job profile.
    --
    -- Example:
    --   Aero VI
    --   Aero V
    --   Aero IV
    --
    -- We never invent a lower tier here.
    -- If none are available, the burst simply fails.
    --------------------------------------------------------

    for _, spell_name in ipairs(candidates) do
        if Spell_Is_Available(
            spell_name,
            player,
            recasts
        ) then
            return spell_name
        end
    end

    return nil
end


------------------------------------------------------------
-- ATTEMPT MAGIC BURST
------------------------------------------------------------

function Try_Magic_Burst()
    if not active_profile then
        return false
    end

    if not active_profile.magic_burst then
        return false
    end

    --------------------------------------------------------
    -- Absolute action/movement lock.
    --------------------------------------------------------

    if not Can_Cast() then
        return false
    end

    --------------------------------------------------------
    -- Get the target.
    --------------------------------------------------------

    local target = Get_Magic_Target()

    if not target then
        return false
    end

    --------------------------------------------------------
    -- A skillchain must currently exist.
    --------------------------------------------------------

    if not sc_active(target.id) then
        return false
    end

    --------------------------------------------------------
    -- We must still be inside the Magic Burst window.
    --------------------------------------------------------

    if not sc_ready(target.id) then
        return false
    end

    --------------------------------------------------------
    -- Determine the burst spell from the CURRENT SC.
    --------------------------------------------------------

    local spell_name = Get_Burst_Spell(target)

    if not spell_name then
        return false
    end

    --------------------------------------------------------
    -- Cast it.
    --
    -- Cast_Magic_Spell performs its own final cooldown,
    -- MP, movement and casting checks.
    --------------------------------------------------------

    return Cast_Magic_Spell(spell_name)
end


------------------------------------------------------------
-- DETERMINE SOLO / BURST MODE
------------------------------------------------------------

local function Get_Magic_Mode()
    --------------------------------------------------------
    -- BLM can provide its own mode logic.
    --------------------------------------------------------

    if current_job == 'BLM' then
        if BLM_Get_Mode then
            return BLM_Get_Mode()
        end
    end

    --------------------------------------------------------
    -- RDM can provide its own mode logic.
    --------------------------------------------------------

    if current_job == 'RDM' then
        if RDM_Get_Mode then
            return RDM_Get_Mode()
        end
    end

    --------------------------------------------------------
    -- Other jobs use the profile's explicit solo_mode.
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
    if not active_profile then
        return false
    end

    if not active_profile.solo_spells then
        return false
    end

    --------------------------------------------------------
    -- BLM / RDM use their own SOLO/BURST mode functions.
    --------------------------------------------------------

    if current_job == 'BLM'
        or current_job == 'RDM'
    then
        if Get_Magic_Mode() ~= 'SOLO' then
            return false
        end

    --------------------------------------------------------
    -- Other jobs must explicitly enable solo mode.
    --------------------------------------------------------

    elseif active_profile.solo_mode ~= true then
        return false
    end

    --------------------------------------------------------
    -- Absolute casting/movement lock.
    --------------------------------------------------------

    if not Can_Cast() then
        return false
    end

    local target = Get_Magic_Target()

    if not target then
        return false
    end

    local player = windower.ffxi.get_player()

    if not player then
        return false
    end

    local recasts = windower.ffxi.get_spell_recasts()

    if not recasts then
        return false
    end

    --------------------------------------------------------
    -- Solo spells are ordered strongest -> weakest by the
    -- job profile.
    --------------------------------------------------------

    for _, spell_name in ipairs(active_profile.solo_spells) do
        if Spell_Is_Available(
            spell_name,
            player,
            recasts
        ) then
            return Cast_Magic_Spell(spell_name)
        end
    end

    return false
end


------------------------------------------------------------
-- MAGIC BURST MONITOR
------------------------------------------------------------
--
-- IMPORTANT ORDER:
--
--   1. If a burst is available, BURST FIRST.
--   2. Only perform solo nukes when the job is actually in
--      SOLO mode.
--
-- This prevents a normal nuke from stealing an opportunity
-- that should have been a Magic Burst.
--
-- Lazy.lua owns SC_Monitor().
-- This function does NOT overwrite SC_Monitor().
------------------------------------------------------------

function MagicBurst_Monitor()
    while Start_Engine do

        ----------------------------------------------------
        -- Never attempt another action while casting,
        -- busy, or resting.
        ----------------------------------------------------

        if isCasting
            or isBusy > 0
            or mp_resting
        then
            coroutine.sleep(0.2)

        else

            ------------------------------------------------
            -- BURST FIRST.
            --
            -- If we're inside an MB window, this gets first
            -- chance to act.
            ------------------------------------------------

            local burst_done = Try_Magic_Burst()

            if burst_done then
                coroutine.sleep(Action_Delay)

            else

                ------------------------------------------------
                -- No burst available.
                --
                -- This is where SOLO mode may nuke.
                ------------------------------------------------

                local solo_done = Try_Solo_Nuke()

                if solo_done then
                    coroutine.sleep(Action_Delay)
                else
                    coroutine.sleep(0.2)
                end
            end
        end
    end
end