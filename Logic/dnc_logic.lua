
------------------------------------------------------------
-- DNC_LOGIC
-- Dancer rotation logic for LazyJob.
--
-- Responsibilities:
--   * Haste Samba maintenance
--   * Emergency Waltz
--   * Trance for persistent status ailments
--   * Box Step / Presto opener
--   * Contradance once per fight
--   * Grand Pas when a WS is ready and no FM remain
--   * Reverse Flourish
--   * Box Step maintenance
--   * Filler abilities
--   * Pre-weaponskill Flourish hook
--
-- Gear swapping remains the responsibility of GearSwap.
-- Lazy.lua should load this file and call Try_DNC_Actions().
------------------------------------------------------------

------------------------------------------------------------
-- STATE
------------------------------------------------------------

dnc_flourish_pending = false
dnc_opening_step = 1
dnc_last_target_id = nil
dnc_contradance_used = false
dnc_grand_pas_used = false

DNC_WALTZ_TIERS = {
    'Curing Waltz V',
    'Curing Waltz IV',
    'Curing Waltz III',
    'Curing Waltz II',
    'Curing Waltz',
}

-- Status ailments that can trigger Trance.
local DNC_TRACKED_DEBUFFS = {
    'Poison', 'Paralysis', 'Blindness', 'Silence',
    'Petrification', 'Disease', 'Curse', 'Doom',
    'Amnesia', 'Sleep', 'Sleep II', 'Charm', 'Charm II',
    'Terror', 'Stun', 'Weight', 'Slow', 'Slow II',
    'Addle', 'Addle II', 'Bind', 'Plague', 'Intoxication',
    'Frost', 'Choke', 'Rasp', 'Shock', 'Drown', 'Flash',
    'Elegy', 'Requiem', 'Threnody', 'Dia', 'Dia II',
    'Dia III', 'Bio', 'Bio II', 'Bio III', 'Burn',
    'Frazzle', 'Frazzle II', 'Malaise', 'Malaise II',
}

-- Filler abilities are considered in this order.
local DNC_FILLER_ABILITIES = {
    'Saber Dance',
    'Fan Dance',
    'No Foot Rise',
}

-- os.time() measures wall-clock seconds, unlike os.clock(),
-- which measures CPU time.
local dnc_debuff_since = nil

------------------------------------------------------------
-- RESET
------------------------------------------------------------

function Reset_DNC_Opening()
    dnc_opening_step = 1
    dnc_flourish_pending = false
end

local function Reset_DNC_Fight()
    Reset_DNC_Opening()
    dnc_contradance_used = false
    dnc_grand_pas_used = false
end

------------------------------------------------------------
-- PRE-WEAPONSKILL FLOURISH
--
-- Called by Lazy.lua before a weaponskill is executed.
-- Returns true if an ability was queued.
------------------------------------------------------------

function Try_DNC_Pre_WS_Flourish()
    if buffactive['Climactic Flourish']
        or buffactive['Violent Flourish'] then
        return false
    end

    if Can_Cast_Ability('Climactic Flourish') then
        windower.send_command(
            'input /ja "Climactic Flourish" <me>'
        )
        isBusy = Action_Delay
        return true
    end

    if Can_Cast_Ability('Violent Flourish') then
        windower.send_command(
            'input /ja "Violent Flourish" <t>'
        )
        isBusy = Action_Delay
        return true
    end

    return false
end

------------------------------------------------------------
-- DNC ROTATION
------------------------------------------------------------

function Try_DNC_Actions()
    local player = windower.ffxi.get_player()

    if not player or not player.vitals then
        return false
    end

    local target = windower.ffxi.get_mob_by_target('t')
    local target_id = target and target.id

    --------------------------------------------------------
    -- NEW FIGHT DETECTION
    --
    -- Reset only when a valid target ID changes.
    -- Losing target temporarily does not reset the opener.
    --------------------------------------------------------

    if target_id and target_id ~= dnc_last_target_id then
        Reset_DNC_Fight()
    end

    if target_id then
        dnc_last_target_id = target_id
    end

    --------------------------------------------------------
    -- HASTE SAMBA
    --------------------------------------------------------

    if not buffactive['Haste Samba']
        and Can_Cast_Ability('Haste Samba') then

        windower.send_command(
            'input /ja "Haste Samba" <me>'
        )
        isBusy = Action_Delay
        return true
    end

    --------------------------------------------------------
    -- EMERGENCY WALTZ
    --------------------------------------------------------

    if player.vitals.hpp and player.vitals.hpp <= 50 then
        for _, waltz in ipairs(DNC_WALTZ_TIERS) do
            local ability = res.job_abilities:with(
                'name', waltz
            )

            if ability
                and Can_Cast_Ability(waltz)
                and (player.vitals.mp or 0)
                    >= (ability.mp_cost or 0) then

                windower.add_to_chat(
                    167,
                    '[Lazy] Emergency Waltz -- '
                    .. waltz .. ' ('
                    .. player.vitals.hpp .. '% HP)'
                )

                Cast_Ability(waltz)
                return true
            end
        end
    end

    --------------------------------------------------------
    -- TRANCE
    --
    -- Use Trance if a tracked status ailment persists
    -- for at least 10 wall-clock seconds.
    --------------------------------------------------------

    local currently_debuffed = false

    for _, name in ipairs(DNC_TRACKED_DEBUFFS) do
        if buffactive[name] then
            currently_debuffed = true
            break
        end
    end

    if currently_debuffed then
        if not dnc_debuff_since then
            dnc_debuff_since = os.time()
        end
    else
        dnc_debuff_since = nil
    end

    if currently_debuffed
        and dnc_debuff_since
        and (os.time() - dnc_debuff_since) >= 10
        and Can_Cast_Ability('Trance') then

        windower.add_to_chat(
            167,
            '[Lazy] Debuffed 10s+ -- using Trance.'
        )

        Cast_Ability('Trance')
        dnc_debuff_since = nil
        return true
    end

    --------------------------------------------------------
    -- TARGET / RANGE CHECK
    --------------------------------------------------------

    if not target
        or not target.distance
        or math.sqrt(target.distance) > 5 then
        return false
    end

    local stacks = buffactive['Finishing Move'] or 0

    --------------------------------------------------------
    -- OPENING SETUP
    --
    -- 1. Box Step
    -- 2. Presto
    -- 3. Box Step
    -- 4. Presto
    --
    -- One action is queued per rotation call.
    --------------------------------------------------------

    if dnc_opening_step <= 4 then

        if dnc_opening_step == 1
            or dnc_opening_step == 3 then

            if Can_Cast_Ability('Box Step') then
                windower.send_command(
                    'input /ja "Box Step" <t>'
                )
                isBusy = Action_Delay
                dnc_opening_step = dnc_opening_step + 1
                return true
            end

        elseif dnc_opening_step == 2
            or dnc_opening_step == 4 then

            if Can_Cast_Ability('Presto') then
                windower.send_command(
                    'input /ja "Presto" <me>'
                )
                isBusy = Action_Delay
                dnc_opening_step = dnc_opening_step + 1
                return true
            end
        end

        -- Keep the opener in sequence if the next ability
        -- is unavailable. Do not skip ahead to another step.
        return false
    end

    --------------------------------------------------------
    -- CONTRADANCE
    --
    -- Once per fight, while the target is at 90%+ HP.
    --------------------------------------------------------

    if not dnc_contradance_used
        and target.hpp
        and target.hpp >= 90
        and Can_Cast_Ability('Contradance') then

        windower.send_command(
            'input /ja "Contradance" <me>'
        )
        isBusy = Action_Delay
        dnc_contradance_used = true
        return true
    end

    --------------------------------------------------------
    -- GRAND PAS
    --
    -- Once per fight, when no Finishing Moves remain
    -- and enough TP is available to start a WS.
    --------------------------------------------------------

    local ws_starter = nil

    if type(Get_WS_Starter) == 'function' then
        ws_starter = Get_WS_Starter()
    end

    local ws_min_tp = ws_starter and ws_starter[2] or 1000

    if not dnc_grand_pas_used
        and stacks == 0
        and player.vitals.tp
        and player.vitals.tp >= ws_min_tp
        and Can_Cast_Ability('Grand Pas') then

        windower.send_command(
            'input /ja "Grand Pas" <me>'
        )
        isBusy = Action_Delay
        dnc_grand_pas_used = true
        return true
    end

    --------------------------------------------------------
    -- REVERSE FLOURISH
    --------------------------------------------------------

    if (stacks >= 5 or dnc_flourish_pending)
        and Can_Cast_Ability('Reverse Flourish') then

        windower.send_command(
            'input /ja "Reverse Flourish" <me>'
        )
        isBusy = Action_Delay
        dnc_flourish_pending = false
        return true
    end

    --------------------------------------------------------
    -- BOX STEP MAINTENANCE
    --------------------------------------------------------

    if stacks < 5 and Can_Cast_Ability('Box Step') then
        windower.send_command(
            'input /ja "Box Step" <t>'
        )
        isBusy = Action_Delay
        return true
    end

    --------------------------------------------------------
    -- FILLER ABILITIES
    --
    -- Only considered when higher-priority actions
    -- have nothing to do.
    --------------------------------------------------------

    for _, ability_name in ipairs(DNC_FILLER_ABILITIES) do
        if Can_Cast_Ability(ability_name) then
            windower.send_command(
                'input /ja "' .. ability_name .. '" <me>'
            )
            isBusy = Action_Delay
            return true
        end
    end

    return false
end
