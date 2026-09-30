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
            and tp >= starter[2]
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
        then
            Cast_Spell(settings.spell)
        end
    elseif target
        and settings.spell_active
        and Can_Cast_Spell(settings.spell)
        and not Is_Blacklisted(target.name)
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
-- BUFF SYSTEM
function Buff_Tick()
    if not settings.buffs_active or not active_profile then return end
    if pending_cast and os.clock() - pending_cast.sent_at > 10 then
        pending_cast = nil
    end
    if isBusy > 0 or isCasting or pending_cast then return end
    local player = windower.ffxi.get_player()
    if not player then return end
    local now = os.clock()
    Update_Job_Profile()
    -- 1. DEBUFF LOGIC
    if active_profile.debuffs then
        Ensure_Debuff_Target()
        local target = windower.ffxi.get_mob_by_target('t')
        local pet = windower.ffxi.get_mob_by_target('pet')
        if target
            and target.hpp
            and target.hpp > 0
            and not Is_Blacklisted(target.name)
        then
            for _, debuff in ipairs(active_profile.debuffs) do
                local names
                local interval
                local target_spec
                local require_no_pet
                local use_ability_before
                local use_ability_after
                if type(debuff) == 'string' then
                    names = {debuff}
                    interval = 1
                    target_spec = '<t>'
                elseif type(debuff) == 'table' then
                    names = type(debuff.name) == 'table' and debuff.name or {debuff.name}
                    interval = debuff.interval or 1
                    target_spec = debuff.target or '<t>'
                    require_no_pet = debuff.require_no_pet
                    use_ability_before = debuff.use_ability_before
                    use_ability_after = debuff.use_ability_after
                end
                if names and names[1] then
                    local key = names[1]
                    local last = debuff_last_cast[key]
                    local cooldown = interval * 60
                    local pet_ok = true
                    if require_no_pet and pet then
                        pet_ok = false
                    end
                    if pet_ok and (not last or now - last >= cooldown) then
                        if use_ability_before and Can_Cast_Ability(use_ability_before) then
                            Cast_Ability(use_ability_before)
                            return
                        end
                        local fired = false
                        for _, name in ipairs(names) do
                            local spell = res.spells:with('name', name)
                            if spell and Cast_Spell_On(name, target_spec) then
                                pending_cast = {
                                    store = debuff_last_cast,
                                    key = key,
                                    spell_id = spell.id,
                                    sent_at = now,
                                }
                                if use_ability_after then
                                    Schedule_Follow_Up(use_ability_after, require_no_pet)
                                end
                                fired = true
                                break
                            end
                            local ability = res.job_abilities:with('name', name)
                            if ability and Cast_Ability_On(name, target_spec) then
                                debuff_last_cast[key] = now
                                if use_ability_after then
                                    local follow_up = use_ability_after
                                    coroutine.schedule(function()
                                        coroutine.sleep(2.5)
                                        if Can_Cast_Ability(follow_up) then
                                            Cast_Ability(follow_up)
                                        end
                                    end, 0)
                                end
                                fired = true
                                break
                            end
                        end
                        if fired then return end
                    end
                end
            end
        end
    end
    -- DISPEL
    if active_profile.dispel then
        local dispel_cfg = active_profile.dispel
        local dispel_ok = true
        if dispel_cfg.require_buff and not buffactive[dispel_cfg.require_buff] then
            dispel_ok = false
        end
        local last = dispel_last_cast[dispel_cfg.spell]
        local interval = dispel_cfg.interval or 20
        if dispel_ok and (not last or now - last >= interval) then
            local target = windower.ffxi.get_mob_by_target('t')
            if target
                and target.name
                and target.hpp
                and target.hpp > 0
                and not Is_Blacklisted(target.name)
                and Is_Dispel_Whitelisted(target.name)
            then
                local spell = res.spells:with('name', dispel_cfg.spell)
                if spell and Cast_Spell_On(dispel_cfg.spell, '<t>') then
                    windower.add_to_chat(207, '[Lazy] Safety-cast ' .. dispel_cfg.spell .. ' on ' .. target.name .. '.')
                    pending_cast = {
                        store = dispel_last_cast,
                        key = dispel_cfg.spell,
                        spell_id = spell.id,
                        sent_at = now,
                    }
                    return
                end
            end
        end
    end
    -- MOB-SPECIFIC SPELLS
    if active_profile.mob_spells then
        local target = windower.ffxi.get_mob_by_target('t')
        if target and target.name and target.hpp and target.hpp > 0 then
            for _, entry in ipairs(active_profile.mob_spells) do
                if string.lower(target.name) == string.lower(entry.mob_name) then
                    local names = type(entry.names) == 'table' and entry.names or {entry.names}
                    local key = 'mobspell:' .. entry.mob_name .. ':' .. names[1]
                    local last = mob_spell_last_cast[key]
                    local interval = entry.interval or 1
                    if not last or now - last >= interval then
                        for _, name in ipairs(names) do
                            local spell = res.spells:with('name', name)
                            if spell and Cast_Spell_On(name, entry.target or '<t>') then
                                pending_cast = {
                                    store = mob_spell_last_cast,
                                    key = key,
                                    spell_id = spell.id,
                                    sent_at = now,
                                }
                                return
                            end
                        end
                    end
                end
            end
        end
    end
    --JOB ABILITIES
    for _, ability_name in ipairs(active_profile.job_abilities or {}) do
        if Can_Cast_Ability(ability_name) then
            Cast_Ability(ability_name)
            return
        end
    end
    -- SELF BUFFS
    for _, buff in ipairs(active_profile.self_buffs or {}) do
        local names = type(buff.name) == 'table' and buff.name or {buff.name}
        local key = names[1]
        local interval = (buff.interval or 20) * 60
        local last = self_buff_last_cast[key]
        local buff_ok = true
        if buff.require_buff and not buffactive[buff.require_buff] then
            buff_ok = false
        end
        if buff_ok and (not last or now - last >= interval) then
            for _, name in ipairs(names) do
                local spell = res.spells:with('name', name)
                if spell and Cast_Spell_On(name, '<me>') then
                    pending_cast = {
                        store = self_buff_last_cast,
                        key = key,
                        spell_id = spell.id,
                        sent_at = now,
                    }
                    return
                end
            end
        end
    end
    -- SELF ABILITIES: Extended Pet & MP logic.
    local self_ability_list = {}
    for _, ab in ipairs(active_profile.self_abilities or {}) do
        self_ability_list[#self_ability_list + 1] = ab
    end
    do
        local sub = player.sub_job
        if haste_samba_active and sub and subjob_abilities and subjob_abilities[sub] then
            for _, ab in ipairs(subjob_abilities[sub]) do
                self_ability_list[#self_ability_list + 1] = ab
            end
        end
    end
    for _, ab in ipairs(self_ability_list) do
        local interval = (ab.interval or 20) * 60
        local last = self_ability_last_cast[ab.name]
        local due = not last or now - last >= interval
        if due then
            local pet_ok = true
            local mp_ok = true
            local pet = windower.ffxi.get_mob_by_target('pet')
            if ab.require_pet and not pet then
                pet_ok = false
            elseif ab.max_pet_hpp and pet and pet.hpp and pet.hpp > ab.max_pet_hpp then
                pet_ok = false
            elseif ab.min_pet_hpp and pet and pet.hpp and pet.hpp < ab.min_pet_hpp then
                pet_ok = false
            end
            if ab.max_mp_percent and player.vitals and player.vitals.mpp then
                if player.vitals.mpp > ab.max_mp_percent then
                    mp_ok = false
                end
            end
            if pet_ok and mp_ok and Can_Cast_Ability(ab.name) then
                Cast_Ability(ab.name)
                self_ability_last_cast[ab.name] = now
                return
            end
        end
    end
    -- ENTRUST BUFFS
    if active_profile.entrust_buffs then
        local me_zone = windower.ffxi.get_info().zone
        local party = windower.ffxi.get_party()
        for _, eb in ipairs(active_profile.entrust_buffs) do
            local interval = (eb.interval or 1) * 60
            local last = entrust_last_cast[eb.spell]
            if not last or now - last >= interval then
                local chosen_target = nil
                if type(eb.targets) == 'table' and eb.targets.jobs and party then
                    for _, job in ipairs(eb.targets.jobs) do
                        if chosen_target then break end
                        for _, key in ipairs({'p0','p1','p2','p3','p4','p5'}) do
                            local m = party[key]
                            if m
                                and m.name
                                and m.mob
                                and m.mob.id
                                and m.zone == me_zone
                                and not m.mob.is_npc
                                and key ~= 'p0'
                                and m.main_job == job
                                and m.mob.distance
                                and math.sqrt(m.mob.distance) <= 20
                            then
                                chosen_target = m.name
                                break
                            end
                        end
                    end
                end
                if chosen_target then
                    local ent = eb.ability or 'Entrust'
                    if not buffactive[ent] then
                        if Can_Cast_Ability(ent) then
                            Cast_Ability(ent)
                            return
                        end
                    else
                        local spell = res.spells:with('name', eb.spell)
                        if spell and Cast_Spell_On(eb.spell, chosen_target) then
                            pending_cast = {
                                store = entrust_last_cast,
                                key = eb.spell,
                                spell_id = spell.id,
                                sent_at = now,
                            }
                            return
                        end
                    end
                end
            end
        end
    end
    -- PARTY BUFFS
    if active_profile.party_buffs then
        local me_zone = windower.ffxi.get_info().zone
        local party = windower.ffxi.get_party()
        for _, pb in ipairs(active_profile.party_buffs) do
            local spell_name = pb.spell
            local interval = (pb.interval or 6) * 60
            local range = pb.range or 20
            local targets = {}
            if pb.targets == 'ALL_PLAYERS' then
                if party then
                    for _, key in ipairs({'p0','p1','p2','p3','p4','p5'}) do
                        local m = party[key]
                        if m
                            and m.name
                            and m.mob
                            and m.mob.id
                            and m.zone == me_zone
                            and not m.mob.is_npc
                            and (pb.self or key ~= 'p0')
                            and not Is_Haste_Blacklisted(m.name)
                            and m.mob.distance
                            and math.sqrt(m.mob.distance) <= range
                        then
                            targets[#targets + 1] = m.name
                        end
                    end
                end
            elseif type(pb.targets) == 'table' and pb.targets.jobs then
                if party then
                    for _, key in ipairs({'p0','p1','p2','p3','p4','p5'}) do
                        local m = party[key]
                        if m
                            and m.name
                            and m.mob
                            and m.mob.id
                            and m.zone == me_zone
                            and not m.mob.is_npc
                            and (pb.self or key ~= 'p0')
                            and m.mob.distance
                            and math.sqrt(m.mob.distance) <= range
                        then
                            for _, job in ipairs(pb.targets.jobs) do
                                if m.main_job == job then
                                    targets[#targets + 1] = m.name
                                    break
                                end
                            end
                        end
                    end
                end
            end
            for _, tname in ipairs(targets) do
                local cache_key = spell_name .. ':' .. tname
                local last = party_buff_last_cast[cache_key]
                if not last or now - last >= interval then
                    local spell = res.spells:with('name', spell_name)
                    if spell and Cast_Spell_On(spell_name, tname) then
                        pending_cast = {
                            store = party_buff_last_cast,
                            key = cache_key,
                            spell_id = spell.id,
                            sent_at = now,
                        }
                        return
                    end
                end
            end
        end
    end
    -- HASTE HANDLING
    if active_profile.haste_active and not active_profile.party_buffs then
        local self_interval = (active_profile.haste_self_interval or 20) * 60
        local self_last = haste_last_cast.me
        local haste_spell = active_profile.haste_spell or 'Haste II'
        if not self_last or now - self_last >= self_interval then
            local spell = res.spells:with('name', haste_spell)
            if spell and Cast_Spell_On(haste_spell, '<me>') then
                pending_cast = {
                    store = haste_last_cast,
                    key = 'me',
                    spell_id = spell.id,
                    sent_at = now,
                }
                return
            end
        end
        local party_interval = (active_profile.haste_party_interval or 6) * 60
        local haste_targets = active_profile.haste_targets
        local me_zone = windower.ffxi.get_info().zone
        if haste_targets == 'ALL_PLAYERS' then
            haste_targets = {}
            local party = windower.ffxi.get_party()
            if party then
                for _, key in ipairs({'p0','p1','p2','p3','p4','p5'}) do
                    local m = party[key]
                    if m
                        and m.name
                        and m.mob
                        and m.mob.id
                        and key ~= 'p0'
                        and m.zone == me_zone
                        and not m.mob.is_npc
                        and not Is_Haste_Blacklisted(m.name)
                        and m.mob.distance
                        and math.sqrt(m.mob.distance) <= 20
                    then
                        haste_targets[#haste_targets + 1] = m.name
                    end
                end
            end
        end
        for _, tname in ipairs(haste_targets or {}) do
            local last = haste_last_cast[tname]
            if not last or now - last >= party_interval then
                local spell = res.spells:with('name', haste_spell)
                if spell and Cast_Spell_On(haste_spell, tname) then
                    pending_cast = {
                        store = haste_last_cast,
                        key = tname,
                        spell_id = spell.id,
                        sent_at = now,
                    }
                    return
                end
            end
        end
    end
    -- REFRESH HANDLING
    if active_profile.refresh_targets and not active_profile.party_buffs then
        local refresh = active_profile.refresh_targets
        local interval = (refresh.interval or 6) * 60
        local spell_name = refresh.spell or 'Refresh III'
        local me_zone = windower.ffxi.get_info().zone
        local party = windower.ffxi.get_party()
        if party then
            for _, key in ipairs({'p0','p1','p2','p3','p4','p5'}) do
                local m = party[key]
                if m
                    and m.name
                    and m.mob
                    and m.mob.id
                    and m.zone == me_zone
                    and not m.mob.is_npc
                    and m.mob.distance
                    and math.sqrt(m.mob.distance) <= 20
                then
                    local allowed = false
                    for _, job in ipairs(refresh.jobs or {}) do
                        if m.main_job == job then
                            allowed = true
                            break
                        end
                    end
                    if allowed then
                        local cache_key = 'refresh:' .. m.name
                        local last = refresh_last_cast[cache_key]
                        if not last or now - last >= interval then
                            local spell = res.spells:with('name', spell_name)
                            if spell and Cast_Spell_On(spell_name, m.name) then
                                pending_cast = {
                                    store = refresh_last_cast,
                                    key = cache_key,
                                    spell_id = spell.id,
                                    sent_at = now,
                                }
                                return
                            end
                        end
                    end
                end
            end
        end
    end
end
function Buff_Monitor()
    while Start_Engine do
        Safe_Tick('Buff_Tick', Buff_Tick)
        coroutine.sleep(1)
    end
end
-- CURE BOT
function Party_Has_WHM()
    local party = windower.ffxi.get_party()
    if not party then return false end
    for _, key in ipairs({'p0','p1','p2','p3','p4','p5'}) do
        local m = party[key]
        if m then
            if m.main_job == 'WHM' or m.job == 'WHM' then
                return true
            end
            if m.mob and m.mob.main_job == 'WHM' then
                return true
            end
        end
    end
    return false
end
function Cure_Bot_Tick()
    if not settings.cure_active or not active_profile then return end
    Update_Job_Profile()
    local cure_active = active_profile.cure_bot_active
    if current_job == 'SCH' and active_profile.cure_bot_if_no_whm then
        cure_active = not Party_Has_WHM()
    end
    if cure_active and active_profile.cure_bot_requires_buff then
        cure_active = buffactive[active_profile.cure_bot_requires_buff] and true or false
    end
    -- FAILSAFE CURING
    local failsafe = false
    if not cure_active and active_profile.emergency_cure then
        cure_active = true
        failsafe = true
    end
    if not cure_active then return end
    if pending_cast and os.clock() - pending_cast.sent_at > 10 then
        pending_cast = nil
    end
    if isBusy > 0 or isCasting or pending_cast then return end
    local player = windower.ffxi.get_player()
    if not player then return end
    local party = windower.ffxi.get_party()
    if not party then return end
    local worst_member, worst_hpp = nil, 999
    -- We can attempt to reach anyone up to 30y away. <=20y: cure immediately.
    -- 20-30y: move/follow closer, then cure.
    -- >30y: ignore them.
    for _, key in ipairs({'p0','p1','p2','p3','p4','p5'}) do
        local m = party[key]
        if m
            and m.hp
            and m.hp > 0
            and m.hpp
            and m.hpp < worst_hpp
            and Party_Member_In_Range(m, 30)
        then
            worst_hpp = m.hpp
            worst_member = m
        end
    end
    local threshold = failsafe
        and (active_profile.emergency_cure_threshold or 25)
        or 75
    if not worst_member or worst_hpp > threshold then return end
    local target_name = worst_member.name
        or (worst_member.mob and worst_member.mob.name)
    if not target_name then return end
    -- hpp can round to 0 while hp > 0; avoid dividing by zero.
    local max_hp = worst_member.hp / (math.max(worst_hpp, 1) / 100)
    local missing_hp = math.floor(max_hp - worst_member.hp)
    if missing_hp <= 0 then return end
    local distance = worst_member.mob and worst_member.mob.distance
        and math.sqrt(worst_member.mob.distance)
        or 999
    -- If they are reachable but outside normal cure range,move toward them. Do not chase anyone beyond 30y.
    if distance > 20 then
        windower.send_command('input /follow "' .. target_name .. '"')
        return
    end
    local target = (target_name == player.name) and '<me>' or target_name
    for _, tier in ipairs(active_profile.cure_tiers or {}) do
        local min_m = tier.min_missing or 0
        local max_m = tier.max_missing or 999999
        if missing_hp >= min_m and missing_hp <= max_m then
            for _, spell_name in ipairs(tier.spells) do
                if Cast_Spell_On(spell_name, target) then
                    if failsafe then
                        windower.add_to_chat(
                            167,
                            '[Lazy] Failsafe cure -- ' .. target_name .. ' at ' .. worst_hpp .. '% HP, no healer response'
                        )
                    end
                    windower.send_command('input /follow off')
                    return
                end
            end
            return
        end
    end
end
function Cure_Monitor()
    while Start_Engine do
        Safe_Tick('Cure_Bot_Tick', Cure_Bot_Tick)
        coroutine.sleep(0.5)
    end
end
-- REST
local REST_MP_THRESHOLD = 500
local REST_THREAT_WINDOW = 10
local REST_PARTY_HP_THRESHOLD = 60
local REST_PARTY_MAX_RANGE = 30
local REST_CURE_RANGE = 20
local rest_started_at = 0
-- Only jobs that actually run on a meaningful MP pool rest at all.
-- DNC's MP is too small/situational to be worth kneeling for,
-- and every pure-melee job has none.
local REST_ELIGIBLE_JOBS = {
    WHM = true,
    RDM = true,
    BLM = true,
    GEO = true,
    SCH = true,
    SMN = true,
}
local function Being_Hit()
    return last_damage_taken_time
        and (os.clock() - last_damage_taken_time) <= REST_THREAT_WINDOW
end
-- Someone else in the party is hurt badly enough to stop resting.
-- Up to 30y counts because the Cure Bot can move closer.
-- Beyond 30y is intentionally ignored.
local function Party_Needs_Rest_Intervention()
    local party = windower.ffxi.get_party()
    if not party then return false end
    for _, key in ipairs({'p1','p2','p3','p4','p5'}) do
        local member = party[key]
        if member
            and member.hp
            and member.hp > 0
            and member.hpp
            and member.hpp < REST_PARTY_HP_THRESHOLD
            and Party_Member_In_Range(member, REST_PARTY_MAX_RANGE)
        then
            return true
        end
    end
    return false
end
local function Magic_Burst_Needed()
    if not active_profile or not active_profile.magic_burst then
        return false
    end
    local target = windower.ffxi.get_mob_by_target('t')
    if not target
        or not target.id
        or not target.hpp
        or target.hpp <= 0
    then
        return false
    end
    if active_profile.magic_burst_requires_buff
        and not buffactive[active_profile.magic_burst_requires_buff]
    then
        return false
    end
    -- An active skillchain window means the MB job should wake up.
    -- Follow/combat logic is responsible for getting into range.
    return sc_active and sc_active(target.id) or false
end
local function Rest_Tick()
    local player = windower.ffxi.get_player()
    -- Anything that stands us up invalidates the resting flag.
    -- Grace period prevents a slow server acknowledgement after /heal
    -- from immediately flipping the state back off.
    if is_resting
        and player
        and player.status ~= 33
        and (os.clock() - rest_started_at) > 4
    then
        is_resting = false
    end
    local idle_and_alive = player
        and player.status ~= 1
        and player.vitals
        and player.vitals.hpp
        and player.vitals.hpp > 0
    local threat = Being_Hit()
    local party_needs_help = Party_Needs_Rest_Intervention()
    local magic_burst_needed = Magic_Burst_Needed()
    -- INTERRUPT REST WHEN THERE IS ACTUALLY SOMETHING TO DO
    if idle_and_alive
        and is_resting
        and (threat or party_needs_help or magic_burst_needed)
    then
        windower.send_command('input /heal off')
        is_resting = false
        return
    end
    -- BEING ATTACKED WHILE IDLE
    if idle_and_alive
        and threat
        and last_damage_source_id
    then
        local current = windower.ffxi.get_mob_by_target('t')
        local attacker = windower.ffxi.get_mob_by_id(last_damage_source_id)
        if attacker
            and attacker.valid_target
            and attacker.hpp
            and attacker.hpp > 0
            and (attacker.claim_id == 0 or attacker.claim_id == player.id)
            and (not current or current.id ~= attacker.id)
        then
            windower.add_to_chat(
                167,
                '[Lazy] Being hit by ' .. attacker.name .. ' -- engaging.'
            )
            Select_Target(attacker)
            return
        end
    end
    -- ACTUAL RESTING
    if idle_and_alive
        and settings.rest_active
        and REST_ELIGIBLE_JOBS[current_job]
    then
        local mp = player.vitals.mp or 0
        local mpp = player.vitals.mpp or 0
        local mp_full = mp >= REST_MP_THRESHOLD or mpp >= 100
        if is_resting then
            if mp_full then
                windower.send_command('input /heal off')
                is_resting = false
            end
        elseif not threat
            and not party_needs_help
            and not magic_burst_needed
            and not mp_full
        then
            windower.send_command('input /heal on')
            is_resting = true
            rest_started_at = os.clock()
        end
    elseif is_resting then
        windower.send_command('input /heal off')
        is_resting = false
    end
end
function Rest_Monitor()
    while Start_Engine do
        Safe_Tick('Rest_Tick', Rest_Tick)
        coroutine.sleep(2)
    end
end