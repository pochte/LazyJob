-- JOBLOGIC
-- Combat execution, job actions, buffs, healing, resting, and WS/SC logic.
local last_tick_error = {}
function Safe_Tick(name, fn)
    local ok, err = pcall(fn)
    if not ok and last_tick_error[name] ~= err then
        last_tick_error[name] = err
        windower.add_to_chat(167, '[Lazy] ' .. name .. ' error: ' .. tostring(err))
    end
end
-- PROFILE HELPERS
function Get_WS_Starter()
    return active_profile and active_profile.ws_sc_starter or ws_sc_starter
end
function Get_WS_Closers()
    return active_profile and active_profile.ws_sc_closers or ws_sc_closers
end
function Get_Needed_Buffs()
    return active_profile and active_profile.needed_buffs or needed_buffs
end
function Get_Food()
    return active_profile and active_profile.food or food
end
-- PARTY HELPER
function Party_Member_In_Range(m, range)
    if not m or not m.mob or not m.mob.distance then return false end
    if m.zone ~= windower.ffxi.get_info().zone then return false end
    return math.sqrt(m.mob.distance) <= (range or 20)
end
-- WEAPONSKILLS
function Next_WS()
    local closers = Get_WS_Closers()
    if not closers or #closers == 0 then return nil end
    local idx = ws_index or 1
    if idx > #closers then idx = 1 end
    ws_index = (idx % #closers) + 1
    return closers[idx]
end
function TurnToTarget()
    local target = windower.ffxi.get_mob_by_target('t')
    local p = windower.ffxi.get_player()
    if not target or not p then return end
    local me = windower.ffxi.get_mob_by_id(p.id)
    if not me or not me.heading then return end
    local desired = HeadingTo(target.x, target.y)
    local d = desired - me.heading
    d = math.atan2(math.sin(d), math.cos(d))
    if math.abs(d) > math.rad(10) then
        windower.ffxi.turn(desired)
    end
end
local function SC_Tick()
    local player = windower.ffxi.get_player()
    if player and player.status == 1 and isBusy < 1 and not isCasting and player.vitals.tp >= 1000 then
        local target = windower.ffxi.get_mob_by_target('t')
        if target and sc_ready and sc_ready(target.id) and active_profile and active_profile.use_weaponskills ~= false then
            local options = sc_get_ws(target.id) or {}
            local fired = false
            for _, ws in ipairs(options) do
                if fired then break end
                for _, closer in ipairs(Get_WS_Closers() or {}) do
                    if ws == closer then
                        if current_job == 'DNC' and Try_DNC_Pre_WS_Flourish() then
                            fired = true
                            break
                        end
                        windower.send_command('input /ws "' .. closer .. '" <t>')
                        isBusy = Action_Delay
                        dnc_flourish_pending = true
                        fired = true
                        break
                    end
                end
            end
        end
    end
end
function SC_Monitor()
    while Start_Engine do
        Safe_Tick('SC_Tick', SC_Tick)
        coroutine.sleep(0.5)
    end
end
-- NUKES: BURST ONLY
-- magic_burst_active (settings.lua) was defined but never read. For a
-- job whose profile does magic_burst, settings.spell now only fires
-- into an already-open skillchain window -- never as a free nuke --
-- and never into a window on a mob on magic_burst_blacklist (the plain
-- spell_blacklist this cast checks is the debuff list, not the burst
-- one). Set magic_burst_active = false to go back to free casting.
function Spell_Allowed_Now(target)
    if not (magic_burst_active and active_profile and active_profile.magic_burst) then
        return true
    end
    if not target or not sc_active or not sc_ready then return false end
    if Is_Magic_Burst_Blacklisted(target.name) then return false end
    return (sc_active(target.id) and sc_ready(target.id)) and true or false
end
function Combat()
    local player = windower.ffxi.get_player()
    if not player then return end
    local target = windower.ffxi.get_mob_by_target('t')
    local starter = Get_WS_Starter()
    if player.status == 1 then
        if not engaged_since then
            engaged_since = os.clock()
        end
    else
        engaged_since = nil
    end
    if active_profile and active_profile.provoke_if_stuck
        and player.status == 1
        and target
        and engaged_since
        and (os.clock() - engaged_since) >= (active_profile.stuck_threshold or 10)
    then
        if Can_Cast_Ability('Provoke') then
            Cast_Ability('Provoke')
        end
        TurnToTarget()
    end
    local magic_burst_ok = active_profile and active_profile.magic_burst
    if magic_burst_ok and active_profile.magic_burst_requires_buff then
        magic_burst_ok = buffactive[active_profile.magic_burst_requires_buff] and true or false
    end
    if magic_burst_ok then
        if Try_Magic_Burst and Try_Magic_Burst() then return end
        if current_job == 'BLM'
            or current_job == 'GEO'
            or current_job == 'SCH'
            or current_job == 'NIN'
        then
            return
        end
    end
    if active_profile and active_profile.dnc_rotation and current_job == 'DNC' then
        if Try_DNC_Actions() then return end
    end
    if target
        and target.distance
        and math.sqrt(target.distance) <= 3
        and player.vitals.tp >= 3000
        and isBusy == 0
        and not isCasting
        and starter
        and starter[1]
        and active_profile
        and active_profile.use_weaponskills ~= false
    then
        if current_job == 'DNC' and Try_DNC_Pre_WS_Flourish() then return end
        windower.send_command('input /ws "' .. starter[1] .. '" <t>')
        isBusy = Action_Delay
        dnc_flourish_pending = true
        return
    end
    if player.status ~= 1
        and (not active_profile or active_profile.auto_engage ~= false)
    then
        return
    end
    lockon_done = false
    if player.vitals.tp >= 400 and target and target.distance and math.sqrt(target.distance) <= 3 then
        local recasts = windower.ffxi.get_ability_recasts()
        for _, ability_name in ipairs(Get_Needed_Buffs() or {}) do
            if not buffactive[ability_name] then
                if ability_name == 'Food' then
                    local food_item = Get_Food()
                    if food_item then
                        windower.send_command('input /item "' .. food_item .. '" <me>')
                        isBusy = Action_Delay
                        return
                    end
                else
                    local ability = res.job_abilities:with('name', ability_name)
                    if ability and recasts[ability.recast_id] == 0 then
                        Cast_Ability(ability_name)
                        return
                    end
                end
            end
        end
    end
    TurnToTarget()
    if target and target.distance and math.sqrt(target.distance) <= 3 then
        local tp = player.vitals.tp
        if sc_active
            and not sc_active(target.id)
            and starter
            and starter[1]
            and tp >= (starter[2] or 1000)
            and active_profile
            and active_profile.use_weaponskills ~= false
        then
            if current_job == 'DNC' and Try_DNC_Pre_WS_Flourish() then return end
            windower.send_command('input /ws "' .. starter[1] .. '" <t>')
            isBusy = Action_Delay
            dnc_flourish_pending = true
            return
        end
        if settings.spell_active
            and Can_Cast_Spell(settings.spell)
            and not Is_Blacklisted(target.name)
            and Spell_Allowed_Now(target)
        then
            Cast_Spell(settings.spell)
        end
    elseif target
        and settings.spell_active
        and Can_Cast_Spell(settings.spell)
        and not Is_Blacklisted(target.name)
        and Spell_Allowed_Now(target)
    then
        Cast_Spell(settings.spell)
    end
end
-- SPELL / ABILITY HELPERS
function Is_Blacklisted(name)
    if not name then return false end
    for _, blocked in ipairs(spell_blacklist or {}) do
        if string.lower(name) == string.lower(blocked) then
            return true
        end
    end
    return false
end
-- Separate from Is_Blacklisted -- a mob can be fine to debuff but
-- dangerous to magic burst, or the reverse. Checked only by
-- Try_Magic_Burst.
function Is_Magic_Burst_Blacklisted(name)
    if not name then return false end
    for _, blocked in ipairs(magic_burst_blacklist or {}) do
        if string.lower(name) == string.lower(blocked) then
            return true
        end
    end
    return false
end
function Is_Haste_Blacklisted(name)
    if not name then return false end
    for _, blocked in ipairs(haste_blacklist or {}) do
        if string.lower(name) == string.lower(blocked) then
            return true
        end
    end
    return false
end
function Is_Dispel_Whitelisted(name)
    if not name then return false end
    local lname = string.lower(name)
    for _, entry in ipairs(dispel_whitelist or {}) do
        if string.find(lname, string.lower(entry), 1, true) then
            return true
        end
    end
    return false
end
-- Unlearned spells would otherwise report "castable" (recast 0, enough MP) and stall every fallback list. Trusts are exempt from the check.
local function Spell_Known(spell)
    if spell.type == 'Trust' then return true end
    local known = windower.ffxi.get_spells()
    return known and known[spell.id] and true or false
end
function Can_Cast_Spell(spell_name)
    if not spell_name or spell_name == '' then return false end
    local spell = res.spells:with('name', spell_name)
    if not spell then return false end
    if not Spell_Known(spell) then return false end
    local player = windower.ffxi.get_player()
    if not player then return false end
    local recasts = windower.ffxi.get_spell_recasts()
    return recasts[spell.id] == 0
        and not isCasting
        and isBusy == 0
        and player.vitals.mp >= spell.mp_cost
        and not Is_Moving()
end
function Can_Cast_Ability(ability_name)
    local ability = res.job_abilities:with('name', ability_name)
    if not ability then return false end
    local recasts = windower.ffxi.get_ability_recasts()
    return recasts[ability.recast_id] == 0
        and not isCasting
        and isBusy == 0
end
function Cast_Spell(spell_name)
    local spell = res.spells:with('name', spell_name)
    if not spell then return false end
    if not Spell_Known(spell) then return false end
    local recasts = windower.ffxi.get_spell_recasts()
    if recasts[spell.id] ~= 0 or isCasting or isBusy > 0 then
        return false
    end
    windower.send_command('input /ma "' .. spell_name .. '" <t>')
    isBusy = Action_Delay
    return true
end
function Cast_Spell_On(spell_name, target)
    local spell = res.spells:with('name', spell_name)
    if not spell then return false end
    if not Spell_Known(spell) then return false end
    if Is_Moving() then return false end
    local player = windower.ffxi.get_player()
    if not player then return false end
    local recasts = windower.ffxi.get_spell_recasts()
    if recasts[spell.id] ~= 0
        or isCasting
        or isBusy > 0
        or player.vitals.mp < spell.mp_cost
    then
        return false
    end
    windower.send_command('input /ma "' .. spell_name .. '" ' .. target)
    isBusy = Action_Delay
    return true
end
-- Self-targeted job ability.
function Cast_Ability(ability_name)
    if not Can_Cast_Ability(ability_name) then return false end
    windower.send_command('input /ja "' .. ability_name .. '" <me>')
    isBusy = Action_Delay
    return true
end
-- Targeted job ability.
function Cast_Ability_On(ability_name, target)
    if not Can_Cast_Ability(ability_name) then return false end
    windower.send_command('input /ja "' .. ability_name .. '" ' .. target)
    isBusy = Action_Delay
    return true
end
-- Follow-up job ability after a debuff SPELL (e.g. Geo-Poison -> Radial Arcana).
local function Schedule_Follow_Up(ability_name, wait_for_pet)
    coroutine.schedule(function()
        local deadline = os.clock() + 15
        coroutine.sleep(2.5)
        while os.clock() < deadline do
            local pet_ok = (not wait_for_pet) or windower.ffxi.get_mob_by_target('pet')
            if pet_ok and not isCasting and Can_Cast_Ability(ability_name) then
                Cast_Ability(ability_name)
                return
            end
            coroutine.sleep(0.5)
        end
    end, 0)
end
