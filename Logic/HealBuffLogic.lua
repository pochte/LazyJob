-- NOTE: Get_Party_Member_Job() lives in TrustLogic.lua (party info tracker).
function Party_Has_WHM()
    local party = windower.ffxi.get_party()
    if not party then return false end
    for _, key in ipairs({'p0','p1','p2','p3','p4','p5'}) do
        if Get_Party_Member_Job(party[key]) == 'WHM' then
            return true
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
-- ENTRUST HELPERS
entrust_last_cast   = entrust_last_cast   or {}
entrust_last_target = entrust_last_target or {}
entrust_warn_last   = entrust_warn_last   or {}
ENTRUST_BUBBLE_DURATION = 300 -- seconds; a player holds ONE Indi, so don't overwrite another entrust spell's target within this window

local function Member_Job(m)
    return Get_Party_Member_Job(m)
end

local function Entrust_Candidate_Ok(key, m, me_zone)
    return key ~= 'p0'                     -- Entrust is never self-cast
        and m
        and m.name
        and m.hp and m.hp > 0
        and m.mob
        and m.mob.id
        and m.zone == me_zone
        and not m.mob.is_npc               -- players only, no trusts
        and m.mob.distance
        and math.sqrt(m.mob.distance) <= 20
end

-- Names already holding a *different* entrust spell from us.
local function Entrust_Claimed(this_spell, now)
    local claimed = {}
    for spell, rec in pairs(entrust_last_target) do
        if spell ~= this_spell and rec and now - rec.at < ENTRUST_BUBBLE_DURATION then
            claimed[rec.name] = true
        end
    end
    return claimed
end

-- The ONE other player in the party, or nil when there is none or more
-- than one. A member we cannot see (other zone) counts as a player, since
-- trusts are always next to us.
local function Only_Other_Player(party)
    local found, count = nil, 0
    for _, key in ipairs({'p1','p2','p3','p4','p5'}) do
        local m = party[key]
        if m and m.name and not (m.mob and m.mob.is_npc) then
            found, count = { key = key, m = m }, count + 1
        end
    end
    if count == 1 then
        return found
    end
    return nil
end

-- Supports targets = { jobs = {...} } (priority order),
-- targets = { players_only = true, exclude_self = true } (any in-range player)
-- and targets = { lone_leader_unknown_job = true }: the only other player in
-- the party, when their job could not be read and they hold party leader.
function Find_Entrust_Target(eb, party, me_zone, now)
    local t = eb.targets
    if type(t) ~= 'table' or not party then return nil end
    local keys = {'p0','p1','p2','p3','p4','p5'}
    local claimed = Entrust_Claimed(eb.spell, now)
    if t.lone_leader_unknown_job then
        local only = Only_Other_Player(party)
        if only
            and Entrust_Candidate_Ok(only.key, only.m, me_zone)
            and Member_Job(only.m) == nil
            and party.party1_leader == only.m.mob.id
            and not claimed[only.m.name]
        then
            return only.m.name
        end
        return nil
    end
    if t.jobs then
        for _, job in ipairs(t.jobs) do
            for _, key in ipairs(keys) do
                local m = party[key]
                if Entrust_Candidate_Ok(key, m, me_zone)
                    and Member_Job(m) == job
                    and not claimed[m.name]
                then
                    return m.name
                end
            end
        end
        return nil
    end
    if t.players_only then
        for _, key in ipairs(keys) do
            local m = party[key]
            if Entrust_Candidate_Ok(key, m, me_zone) and not claimed[m.name] then
                return m.name
            end
        end
    end
    return nil
end


-- Set false once Entrust is working.
ENTRUST_DEBUG = (ENTRUST_DEBUG == nil) and true or ENTRUST_DEBUG
local entrust_dbg_last = {}
function Entrust_Debug(key, msg)
    if not ENTRUST_DEBUG then return end
    local t = os.clock()
    if entrust_dbg_last[key] and t - entrust_dbg_last[key] < 5 then return end
    entrust_dbg_last[key] = t
    windower.add_to_chat(207, '[Lazy][Entrust] ' .. msg)
end

-- Why Can_Cast_Ability said no, for the debug output.
function Ability_Block_Reason(name)
    local ability = res.job_abilities:with('name', name)
    if not ability then
        return 'not in resources'
    end
    local left = windower.ffxi.get_ability_recasts()[ability.recast_id]
    if left and left > 0 then
        return 'on recast, ' .. math.ceil(left) .. 's left'
    end
    if isCasting then
        return 'busy: still casting'
    end
    if isBusy > 0 then
        return 'busy: action delay'
    end
    return 'no reason found'
end
-- One line describing every party slot, for the debug output.
function Entrust_Party_Summary(party, me_zone)
    if not party then return 'no party table' end
    local out = {}
    for _, key in ipairs({'p0','p1','p2','p3','p4','p5'}) do
        local m = party[key]
        if m and m.name then
            local d = m.mob and m.mob.distance and math.floor(math.sqrt(m.mob.distance)) or '?'
            out[#out + 1] = string.format('%s=%s(%s,%sy%s%s)', key, m.name,
                tostring(Get_Party_Member_Job(m) or 'job?'), tostring(d),
                (m.mob and m.mob.is_npc) and ',npc' or '',
                (m.zone ~= me_zone) and ',other zone' or '') ..
                ((party.party1_leader and m.mob and m.mob.id == party.party1_leader) and ',leader' or '')
        end
    end
    return #out > 0 and table.concat(out, ' ') or 'empty'
end
-- buffactive may be missing/stale in a standalone addon; fall back to scanning player.buffs.
function Has_Buff_Named(name)
    if buffactive and buffactive[name] then return true end
    local pl = windower.ffxi.get_player()
    if pl and pl.buffs then
        for _, id in ipairs(pl.buffs) do
            local b = res.buffs[id]
            if b and b.en == name then return true end
        end
    end
    return false
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
        local buff_ok = not Has_Buff_Named('Entrust')
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
        local earlier_target_exists = false  -- an earlier (higher priority) entry has a valid target
        for _, eb in ipairs(active_profile.entrust_buffs) do
            local interval = (eb.interval or 1) * 60
            local last = entrust_last_cast[eb.spell]
            local candidate = Find_Entrust_Target(eb, party, me_zone, now)
            local skip = eb.fallback and earlier_target_exists
            if candidate and not eb.fallback then earlier_target_exists = true end
            local ent = eb.ability or 'Entrust'
            if skip then
                Entrust_Debug(eb.spell .. ':skip', eb.spell .. ' skipped (fallback; a mage target exists)')
            elseif last and now - last < interval then
                Entrust_Debug(eb.spell .. ':cd', eb.spell .. ' on interval, ' .. math.ceil(interval - (now - last)) .. 's left')
            elseif not candidate then
                Entrust_Debug(eb.spell .. ':nt', 'no valid target in range for ' .. tostring(eb.spell) .. ' | party: ' .. Entrust_Party_Summary(party, me_zone))
            else
                local armed = Has_Buff_Named(ent)
                if not armed then
                    local ok = Can_Cast_Ability(ent)
                    Entrust_Debug(eb.spell .. ':ja', 'target ' .. candidate .. '; ' .. ent .. ' not active; Can_Cast_Ability=' .. tostring(ok) .. (ok and '' or (' (' .. Ability_Block_Reason(ent) .. ')')))
                    if ok then
                        Cast_Ability(ent)
                        return
                    end
                else
                    local spell = res.spells:with('name', eb.spell)
                    local ok = spell and Cast_Spell_On(eb.spell, candidate)
                    Entrust_Debug(eb.spell .. ':sp', ent .. ' active; Cast_Spell_On(' .. eb.spell .. ', ' .. candidate .. ')=' .. tostring(ok and true or false) .. (spell and '' or ' (spell not in res)'))
                    if ok then
                        entrust_last_target[eb.spell] = { name = candidate, at = now }
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
                                if Get_Party_Member_Job(m) == job then
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