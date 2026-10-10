-- HEALBUFFLOGIC
-- Healing, buffs, debuffs, dispel, haste, and refresh.
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
    -- Follow Logic
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
-- buff logic
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
    -- 1. DEBUFF LOGIC :Once per mob
    if active_profile.debuffs then
        Ensure_Debuff_Target()
        local target = windower.ffxi.get_mob_by_target('t')
        local pet = windower.ffxi.get_mob_by_target('pet')
        if target
            and target.hpp
            and target.hpp > 0
            and not Is_Blacklisted(target.name)
        then
            local mob_id = target.id or target.index or target.name
            for _, debuff in ipairs(active_profile.debuffs) do
                local names
                local target_spec
                local require_no_pet
                local use_ability_before
                local use_ability_after
                if type(debuff) == 'string' then
                    names = {debuff}
                    target_spec = '<t>'
                elseif type(debuff) == 'table' then
                    names = type(debuff.name) == 'table'
                        and debuff.name or {debuff.name}
                    target_spec = debuff.target or '<t>'
                    require_no_pet = debuff.require_no_pet
                    use_ability_before = debuff.use_ability_before
                    use_ability_after = debuff.use_ability_after
                end
                if names and names[1] then
                    local spell_key = tostring(mob_id)
                        .. ':' .. tostring(names[1])
                    local before_key = 'before:' .. spell_key
                    local pet_ok = not (require_no_pet and pet)
                    if pet_ok and not debuff_last_cast[spell_key] then
                        -- Run any setup ability once for this mob.
                        if use_ability_before
                            and not debuff_last_cast[before_key]
                            and Can_Cast_Ability(use_ability_before)
                        then
                            Cast_Ability(use_ability_before)
                            debuff_last_cast[before_key] = os.clock()
                            return
                        end
                        local fired = false
                        for _, name in ipairs(names) do
                            local spell = res.spells:with('name', name)
                            if spell and Cast_Spell_On(name, target_spec) then
                                local cast_time = os.clock()
                                debuff_last_cast[spell_key] = cast_time
                                pending_cast = {
                                    store = debuff_last_cast,
                                    key = spell_key,
                                    spell_id = spell.id,
                                    sent_at = cast_time,
                                }
                                if use_ability_after then
                                    Schedule_Follow_Up(
                                        use_ability_after,
                                        require_no_pet
                                    )
                                end
                                fired = true
                                break
                            end
                            local ability = res.job_abilities:with('name', name)
                            if ability and Cast_Ability_On(name, target_spec) then
                                debuff_last_cast[spell_key] = os.clock()
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
end
function Buff_Monitor()
    while Start_Engine do
        Safe_Tick('Buff_Tick', Buff_Tick)
        coroutine.sleep(1)
    end
end