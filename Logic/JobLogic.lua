-- JOBLOGIC
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
-- PARTY HELPER
function Party_Member_In_Range(m, range)
    if not m or not m.mob or not m.mob.distance then return false end
    if m.zone ~= windower.ffxi.get_info().zone then return false end
    return math.sqrt(m.mob.distance) <= (range or 20)
end
-- WEAPONSKILLS
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
-- Not learned spells logic
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
    windower.send_command(
        'input /ma "' .. spell_name .. '" <t>'
    )
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
    windower.send_command(
        'input /ma "' .. spell_name .. '" ' .. target
    )
    isBusy = Action_Delay
    return true
end
-- Self-targeted job ability.
function Cast_Ability(ability_name)
    if not Can_Cast_Ability(ability_name) then return false end
    windower.send_command(
        'input /ja "' .. ability_name .. '" <me>'
    )
    isBusy = Action_Delay
    return true
end
-- Targeted job ability.
function Cast_Ability_On(ability_name, target)
    if not Can_Cast_Ability(ability_name) then return false end
    windower.send_command(
        'input /ja "' .. ability_name .. '" ' .. target
    )
    isBusy = Action_Delay
    return true
end
-- Follow-up job ability after a debuff SPELL
-- (e.g. Geo-Poison -> Radial Arcana).
function Schedule_Follow_Up(ability_name, wait_for_pet)
    coroutine.schedule(function()
        local deadline = os.clock() + 15
        coroutine.sleep(2.5)
        while os.clock() < deadline do
            local pet_ok = (not wait_for_pet)
                or windower.ffxi.get_mob_by_target('pet')
            if pet_ok and not isCasting and Can_Cast_Ability(ability_name) then
                Cast_Ability(ability_name)
                return
            end
            coroutine.sleep(0.5)
        end
    end, 0)
end