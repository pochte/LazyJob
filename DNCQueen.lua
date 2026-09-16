------------------------------------------------------------
-- DNCQUEEN
------------------------------------------------------------

dnc_flourish_pending = false
dnc_opening_steps = 0

DNC_WALTZ_TIERS = {
    'Curing Waltz V',
    'Curing Waltz IV',
    'Curing Waltz III',
    'Curing Waltz II',
    'Curing Waltz',
}

------------------------------------------------------------
-- DNC WS GEAR
------------------------------------------------------------
function Equip_DNC_WS_Set(spell)
    if not sets.ws or not sets.ws[spell.name] then
        return false
    end

    if buffactive['Climactic Flourish']
        and sets.ws.crit
        and sets.ws.crit[spell.name] then

        equip(sets.ws.crit[spell.name])
        return true
    end

    equip(sets.ws[spell.name])
    return true
end

------------------------------------------------------------
-- DNC ROTATION
------------------------------------------------------------
function Try_DNC_Actions()
    local player = windower.ffxi.get_player()
    if not player or not player.vitals then
        return false
    end

    --------------------------------------------------------
    -- HASTE SAMBA
    -- Always maintain Haste Samba while engaged.
    --------------------------------------------------------
    if not buffactive['Haste Samba']
        and Can_Cast_Ability('Haste Samba') then

        windower.send_command('input /ja "Haste Samba" <me>')
        isBusy = Action_Delay
        return true
    end

    --------------------------------------------------------
    -- EMERGENCY WALTZ
    --------------------------------------------------------
    if player.vitals.hpp and player.vitals.hpp <= 50 then
        for _, waltz in ipairs(DNC_WALTZ_TIERS) do
            local ability = res.job_abilities:with('name', waltz)

            if ability and Can_Cast_Ability(waltz)
                and player.vitals.mp >= (ability.mp_cost or 0) then

                windower.add_to_chat(
                    167,
                    '[Lazy] Emergency Waltz -- ' ..
                    waltz .. ' (' .. player.vitals.hpp .. '% HP)'
                )

                Cast_Ability(waltz)
                return true
            end
        end
    end

    --------------------------------------------------------
    -- TARGET CHECK
    --------------------------------------------------------
    local target = windower.ffxi.get_mob_by_target('t')

    if not target
        or not target.distance
        or math.sqrt(target.distance) > 5 then
        return false
    end

    local stacks = buffactive['Finishing Move'] or 0

    --------------------------------------------------------
    -- OPENING SETUP
    --
    -- Presto -> Box Step -> Presto -> Box Step
    --------------------------------------------------------
    if dnc_opening_steps < 4 then

        -- Presto
        if dnc_opening_steps % 2 == 0 then
            if Can_Cast_Ability('Presto') then
                windower.send_command('input /ja "Presto" <t>')
                isBusy = Action_Delay
                dnc_opening_steps = dnc_opening_steps + 1
                return true
            end

        -- Box Step
        else
            if Can_Cast_Ability('Box Step') then
                windower.send_command('input /ja "Box Step" <t>')
                isBusy = Action_Delay
                dnc_opening_steps = dnc_opening_steps + 1
                return true
            end
        end

        return false
    end

    --------------------------------------------------------
    -- REVERSE FLOURISH
    --------------------------------------------------------
    if (stacks >= 5 or dnc_flourish_pending)
        and Can_Cast_Ability('Reverse Flourish') then

        windower.send_command('input /ja "Reverse Flourish" <me>')
        isBusy = Action_Delay
        dnc_flourish_pending = false
        return true
    end

    --------------------------------------------------------
    -- BOX STEP
    --------------------------------------------------------
    if stacks < 5 and Can_Cast_Ability('Box Step') then
        windower.send_command('input /ja "Box Step" <t>')
        isBusy = Action_Delay
        return true
    end

    return false
end

------------------------------------------------------------
-- RESET DNC OPENER
------------------------------------------------------------
function Reset_DNC_Opening()
    dnc_opening_steps = 0
    dnc_flourish_pending = false
end