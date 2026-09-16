------------------------------------------------------------
-- DNCQUEEN
------------------------------------------------------------
-- DNC rotation logic, split out of Lazy.lua -- it had grown into
-- its own sizeable chunk and didn't need to live in the main file.
-- Loaded by Lazy.lua via dofile, same as skillchain.lua/magicburst.lua.
-- Everything here is global (no `local`) on purpose: Lazy.lua reads
-- and sets dnc_flourish_pending directly from SC_Monitor and Combat()
-- when a weaponskill fires, and dofile'd chunks don't share locals
-- across file boundaries in Lua -- only globals do.
-- Set true whenever any weaponskill fires (Combat's starter/closer,
-- or SC_Monitor's closer), so Try_DNC_Actions knows to fire Reverse
-- Flourish right after -- consulted only when current_job == 'DNC'.
dnc_flourish_pending = false
DNC_WALTZ_TIERS = {
    'Curing Waltz V',
    'Curing Waltz IV',
    'Curing Waltz III',
    'Curing Waltz II',
    'Curing Waltz',
}
-- DNC ROTATION
-- Priority:
--   1. Emergency Waltz at <=50% HP.  2. Reverse Flourish at 5 Finishing Moves or after a WS. 3. Box Step until 5 Finishing Moves.
function Try_DNC_Actions()
    local player = windower.ffxi.get_player()
    if not player or not player.vitals then return false end
    if player.vitals.hpp and player.vitals.hpp <= 50 then
        for _, waltz in ipairs(DNC_WALTZ_TIERS) do
            local ability = res.job_abilities:with('name', waltz)
            if ability and Can_Cast_Ability(waltz)
                and player.vitals.mp >= (ability.mp_cost or 0) then
                windower.add_to_chat(167, '[Lazy] Emergency Waltz -- ' .. waltz .. ' (' .. player.vitals.hpp .. '% HP)')
                Cast_Ability(waltz)
                return true
            end
        end
    end
    local target = windower.ffxi.get_mob_by_target('t')
    if not target or not target.distance or math.sqrt(target.distance) > 5 then
        return false
    end
    local stacks = buffactive['Finishing Move'] or 0
    if (stacks >= 5 or dnc_flourish_pending) and Can_Cast_Ability('Reverse Flourish') then
        windower.send_command('input /ja "Reverse Flourish" <me>')
        isBusy = Action_Delay
        dnc_flourish_pending = false
        return true
    end
    if stacks < 5 and Can_Cast_Ability('Box Step') then
        windower.send_command('input /ja "Box Step" <t>')
        isBusy = Action_Delay
        return true
    end
    return false
end