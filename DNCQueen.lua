------------------------------------------------------------
-- DNCQUEEN
------------------------------------------------------------
-- DNC rotation logic, split out of Lazy.lua -- it had grown into
-- its own sizeable chunk and didn't need to live in the main file.
--
-- Opening (every fight, not just the first):
--   Box Step -> Presto -> Box Step -> Presto
--   (twice through guarantees 5 Finishing Move stacks)
--
-- Priority order:
--   1. Keep Haste Samba active.
--   2. Emergency Waltz at <=50% HP.
--   3. Trance if debuffed for more than 10s (trusts should clear it,
--      but sometimes don't -- this is the backup).
--   4. Opener (see above).
--   5. Contradance, once, early -- only while the mob's still at
--      90%+ HP, so it doesn't fire mid/late fight.
--   6. Grand Pas if Finishing Moves are at 0 and TP is already up
--      for a WS -- otherwise there's nothing to spend on the
--      pre-WS Reverse Flourish buff in time.
--   7. Reverse Flourish at 5 Finishing Moves or after a WS.
--   8. Box Step while below 5 Finishing Moves.
--   9. Filler -- Saber Dance / Fan Dance / No Foot Rise, whichever's
--      off cooldown -- only when nothing above had anything to do.
--
-- Before every weaponskill (hooked from Lazy.lua's Combat()/
-- SC_Monitor(), not handled here -- see Try_DNC_Pre_WS_Flourish):
--   Climactic Flourish, or Violent Flourish if that's down.
--
-- Gear-swapping for any of this is handled entirely by GearSwap on
-- the personal job-file side, not here -- Lazy doesn't touch gear.

dnc_flourish_pending = false
dnc_opening_step = 1
dnc_last_target_id = nil

DNC_WALTZ_TIERS = {
    'Curing Waltz V',
    'Curing Waltz IV',
    'Curing Waltz III',
    'Curing Waltz II',
    'Curing Waltz',
}

-- Status ailments Trance should react to. FFXI/Windower resources
-- don't reliably expose an "is this a debuff" flag across versions,
-- so this is an explicit list instead of trying to detect it
-- generically -- add to it if something slips through uncovered.
local DNC_TRACKED_DEBUFFS = {
    'Poison', 'Paralysis', 'Blindness', 'Silence', 'Petrification',
    'Disease', 'Curse', 'Doom', 'Amnesia', 'Sleep', 'Sleep II',
    'Charm', 'Charm II', 'Terror', 'Stun', 'Weight', 'Slow', 'Slow II',
    'Addle', 'Addle II', 'Bind', 'Plague', 'Intoxication', 'Frost',
    'Choke', 'Rasp', 'Shock', 'Drown', 'Flash', 'Elegy', 'Requiem',
    'Threnody', 'Dia', 'Dia II', 'Dia III', 'Bio', 'Bio II', 'Bio III',
    'Burn', 'Frazzle', 'Frazzle II', 'Malaise', 'Malaise II',
}

local debuff_since = nil -- os.clock() of when we first noticed a tracked debuff up

-- Filler abilities used only when nothing higher-priority needs to
-- happen -- tried in this order, first one off cooldown wins.
local DNC_FILLER_ABILITIES = {
    'Saber Dance',
    'Fan Dance',
    'No Foot Rise',
}

------------------------------------------------------------
-- PRE-WEAPONSKILL FLOURISH
--
-- Called from Lazy.lua right before any WS actually fires (both the
-- TP-capped/starter paths in Combat() and the skillchain-closer path
-- in SC_Monitor()). Returns true if it used a flourish this pass --
-- callers should hold off firing the WS and let it retry next tick,
-- once the flourish has actually landed. Returns false if there's
-- nothing to do (already buffed, or both flourishes are down --
-- don't hold the WS hostage waiting on a long cooldown).
------------------------------------------------------------
function Try_DNC_Pre_WS_Flourish()
    if buffactive['Climactic Flourish'] or buffactive['Violent Flourish'] then
        return false
    end

    if Can_Cast_Ability('Climactic Flourish') then
        windower.send_command('input /ja "Climactic Flourish" <me>')
        isBusy = Action_Delay
        return true
    end

    if Can_Cast_Ability('Violent Flourish') then
        windower.send_command('input /ja "Violent Flourish" <me>')
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

    --------------------------------------------------------
    -- NEW FIGHT DETECTION
    -- Reset the opener every time the current target changes to a
    -- different mob, so it plays out every fight, not just the
    -- first one each session.
    --------------------------------------------------------
    local target = windower.ffxi.get_mob_by_target('t')
    local target_id = target and target.id

    if target_id and target_id ~= dnc_last_target_id then
        Reset_DNC_Opening()
    end
    dnc_last_target_id = target_id

    --------------------------------------------------------
    -- HASTE SAMBA
    -- Always keep Haste Samba active.
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

            if ability
                and Can_Cast_Ability(waltz)
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
    -- TRANCE
    -- Trusts should clear our debuffs -- sometimes they don't.
    -- Backup: if we've been sitting on a tracked ailment for more
    -- than 10s, clear it ourselves.
    --------------------------------------------------------
    local currently_debuffed = false
    for _, name in ipairs(DNC_TRACKED_DEBUFFS) do
        if buffactive[name] then
            currently_debuffed = true
            break
        end
    end

    if currently_debuffed then
        if not debuff_since then debuff_since = os.clock() end
    else
        debuff_since = nil
    end

    if currently_debuffed and debuff_since
        and (os.clock() - debuff_since) >= 10
        and Can_Cast_Ability('Trance') then

        windower.add_to_chat(167, '[Lazy] Debuffed 10s+ -- using Trance.')
        Cast_Ability('Trance')
        debuff_since = nil
        return true
    end

    --------------------------------------------------------
    -- TARGET CHECK
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
    -- Step 1: Box Step
    -- Step 2: Presto
    -- Step 3: Box Step
    -- Step 4: Presto
    --
    -- Once step 4 is completed, the opener is finished for THIS
    -- fight. It resets automatically above as soon as the target
    -- changes to a new mob.
    --------------------------------------------------------
    if dnc_opening_step <= 4 then

        ----------------------------------------------------
        -- BOX STEP
        ----------------------------------------------------
        if dnc_opening_step == 1
            or dnc_opening_step == 3 then

            if Can_Cast_Ability('Box Step') then
                windower.send_command('input /ja "Box Step" <t>')
                isBusy = Action_Delay
                dnc_opening_step = dnc_opening_step + 1
                return true
            end

        ----------------------------------------------------
        -- PRESTO
        ----------------------------------------------------
        elseif dnc_opening_step == 2
            or dnc_opening_step == 4 then

            if Can_Cast_Ability('Presto') then
                windower.send_command('input /ja "Presto" <t>')
                isBusy = Action_Delay
                dnc_opening_step = dnc_opening_step + 1
                return true
            end
        end

        return false
    end

    --------------------------------------------------------
    -- CONTRADANCE
    -- Early-fight party Regain -- only while the mob's still at
    -- 90%+ HP, so it doesn't fire mid/late fight once it's down.
    --------------------------------------------------------
    if target.hpp and target.hpp >= 90 and Can_Cast_Ability('Contradance') then
        windower.send_command('input /ja "Contradance" <me>')
        isBusy = Action_Delay
        return true
    end

    --------------------------------------------------------
    -- GRAND PAS
    -- Finishing Moves are at 0 with TP already up for a WS --
    -- nothing to spend on the pre-WS Reverse Flourish buff in time,
    -- so grant stacks directly instead of waiting on Box Step.
    --------------------------------------------------------
    local ws_starter = Get_WS_Starter()
    local ws_min_tp = ws_starter and ws_starter[2] or 1000

    if stacks == 0 and player.vitals.tp and player.vitals.tp >= ws_min_tp
        and Can_Cast_Ability('Grand Pas') then

        windower.send_command('input /ja "Grand Pas" <me>')
        isBusy = Action_Delay
        return true
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

    --------------------------------------------------------
    -- FILLER
    -- Nothing above had anything to do -- use whatever's off
    -- cooldown from the filler list instead of standing around.
    --------------------------------------------------------
    for _, ability_name in ipairs(DNC_FILLER_ABILITIES) do
        if Can_Cast_Ability(ability_name) then
            windower.send_command('input /ja "' .. ability_name .. '" <me>')
            isBusy = Action_Delay
            return true
        end
    end

    return false
end

------------------------------------------------------------
-- RESET DNC OPENER
------------------------------------------------------------
function Reset_DNC_Opening()
    dnc_opening_step = 1
    dnc_flourish_pending = false
end
