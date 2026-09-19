------------------------------------------------------------
-- JOBLOGIC
------------------------------------------------------------
-- Job-rotation and combat-execution logic -- split out of Lazy.lua
-- alongside TargetLogic.lua for the same reason (file had grown too
-- large). Loaded by Lazy.lua via dofile.
--
-- Covers: profile accessors (Get_WS_Starter/Closers/Needed_Buffs/
-- Food), weaponskill helpers (Next_WS, TurnToTarget), the skillchain-
-- closer firing loop (SC_Monitor), the main melee/WS execution loop
-- (Combat), spell/ability cast gating and dispatch (Can_Cast_Spell,
-- Can_Cast_Ability, Cast_Spell, Cast_Spell_On, Cast_Ability), the
-- blacklist/whitelist checks, the whole buff/dispel/debuff/party-buff
-- tick (Buff_Tick), the cure bot, and resting (Rest_Monitor).
--
-- Same cross-file note as TargetLogic.lua: variables declared without
-- `local` are shared with Lazy.lua's core (reset block, packet
-- handlers) or with TargetLogic.lua directly (e.g. lockon_done,
-- PlayerH). Genuinely private state stays local.
------------------------------------------------------------
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
-- WEAPONSKILLS 
function Next_WS()
    local closers = Get_WS_Closers()
    if not closers or #closers == 0 then return nil end
    local ws = closers[ws_index]
    ws_index = (ws_index % #closers) + 1
    return ws
end
function TurnToTarget()
    local target = windower.ffxi.get_mob_by_target('t')
    if not target then return end
    local desired = math.deg(HeadingTo(target.x, target.y))
    if math.abs(PlayerH - desired) > 10 then
        windower.ffxi.turn(HeadingTo(target.x, target.y))
    end
end
function SC_Monitor()
    while Start_Engine do
        local player = windower.ffxi.get_player()
        if player and player.status == 1 and isBusy < 1 and player.vitals.tp >= 1000 then
            local target = windower.ffxi.get_mob_by_target('t')
            if target and sc_ready and sc_ready(target.id) then
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
        if current_job == 'BLM' or current_job == 'GEO'
            or current_job == 'SCH' or current_job == 'NIN' then
            return
        end
    end
    if active_profile and active_profile.dnc_rotation and current_job == 'DNC' then
        if Try_DNC_Actions() then return end
    end
    if target and target.distance and math.sqrt(target.distance) <= 3
        and player.vitals.tp >= 3000 and isBusy == 0 and not isCasting
        and starter and starter[1]
        and active_profile.use_weaponskills ~= false
    then
        if current_job == 'DNC' and Try_DNC_Pre_WS_Flourish() then return end
        windower.send_command('input /ws "' .. starter[1] .. '" <t>')
        isBusy = Action_Delay
        dnc_flourish_pending = true
        return
    end
    if player.status ~= 1 and active_profile.auto_engage ~= false then return end
    lockon_done = false
    if player.vitals.tp >= 400 and target and target.distance
        and math.sqrt(target.distance) <= 3
    then
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
        if sc_active and not sc_active(target.id) and starter and tp >= starter[2]
            and active_profile.use_weaponskills ~= false then
            if current_job == 'DNC' and Try_DNC_Pre_WS_Flourish() then return end
            windower.send_command('input /ws "' .. starter[1] .. '" <t>')
            isBusy = Action_Delay
            dnc_flourish_pending = true
            return
        end
        if settings.spell_active and Can_Cast_Spell(settings.spell)
            and not Is_Blacklisted(target.name)
        then
            Cast_Spell(settings.spell)
        end
    elseif settings.spell_active and Can_Cast_Spell(settings.spell)
        and not (target and Is_Blacklisted(target.name))
    then
        Cast_Spell(settings.spell)
    end
end
-- SPELL / ABILITY HELPERS 
function Is_Blacklisted(name)
    if not name then return false end
    for _, blocked in ipairs(spell_blacklist or {}) do
        if string.lower(name) == string.lower(blocked) then return true end
    end
    return false
end
function Is_Haste_Blacklisted(name)
    if not name then return false end
    for _, blocked in ipairs(haste_blacklist or {}) do
        if string.lower(name) == string.lower(blocked) then return true end
    end
    return false
end
function Is_Dispel_Whitelisted(name)
    if not name then return false end
    local lname = string.lower(name)
    for _, entry in ipairs(dispel_whitelist or {}) do
        if string.find(lname, string.lower(entry), 1, true) then return true end
    end
    return false
end
function Can_Cast_Spell(spell_name)
    if not spell_name or spell_name == '' then return false end
    local spell = res.spells:with('name', spell_name)
    if not spell then return false end
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
    return recasts[ability.recast_id] == 0 and not isCasting and isBusy == 0
end
function Cast_Spell(spell_name)
    local spell = res.spells:with('name', spell_name)
    if not spell then return false end
    local recasts = windower.ffxi.get_spell_recasts()
    if recasts[spell.id] ~= 0 or isCasting or isBusy > 0 then return false end
    windower.send_command('input /ma "' .. spell_name .. '" <t>')
    isBusy = Action_Delay
    return true
end
function Cast_Spell_On(spell_name, target)
    local spell = res.spells:with('name', spell_name)
    if not spell then return false end
    if Is_Moving() then return false end
    local player = windower.ffxi.get_player()
    if not player then return false end
    local recasts = windower.ffxi.get_spell_recasts()
    if recasts[spell.id] ~= 0 or isCasting or isBusy > 0
        or player.vitals.mp < spell.mp_cost
    then
        return false
    end
    windower.send_command('input /ma "' .. spell_name .. '" ' .. target)
    isBusy = Action_Delay
    return true
end
function Cast_Ability(ability_name)
    windower.send_command('input /ja "' .. ability_name .. '" <me>')
    isBusy = Action_Delay
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
    -- 1. DEBUFF LOGIC (With require_no_pet & post-ability logic)
    if active_profile.debuffs then
        Ensure_Debuff_Target()
        local target = windower.ffxi.get_mob_by_target('t')
        local pet = windower.ffxi.get_mob_by_target('pet')
        if target and target.hpp and target.hpp > 0 and not Is_Blacklisted(target.name) then
            for _, debuff in ipairs(active_profile.debuffs) do
                local names = type(debuff.name) == 'table' and debuff.name or {debuff.name}
                local key = names[1]
                local last = debuff_last_cast[key]
                local interval = (debuff.interval or 1) * 60
                local pet_ok = true
                if debuff.require_no_pet and pet then
                    pet_ok = false
                end
                if pet_ok and (not last or now - last >= interval) then
                    -- Pre-ability check
                    if debuff.use_ability_before and Can_Cast_Ability(debuff.use_ability_before) then
                        Cast_Ability(debuff.use_ability_before)
                        return
                    end
                    local spell_target = debuff.target or '<t>'
                    for _, name in ipairs(names) do
                        local spell = res.spells:with('name', name)
                        if spell and Cast_Spell_On(name, spell_target) then
                            pending_cast = {
                                store = debuff_last_cast,
                                key = key,
                                spell_id = spell.id,
                                sent_at = now,
                            }
                            -- Post-ability sequence 
                            if debuff.use_ability_after then
                                local follow_up = debuff.use_ability_after
                                coroutine.schedule(function()
                                    coroutine.sleep(2.5) -- Wait for spell finish animation
                                    if Can_Cast_Ability(follow_up) then
                                        Cast_Ability(follow_up)
                                    end
                                end, 0)
                            end
                            return
                        end
                    end
                end
            end
        end
    end
    -- 1B. DISPEL
    -- Safety-net cast on the configured whitelist at set intervals.
    -- Uses case-insensitive substring matching; require_buff still applies.
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
            if target and target.name and target.hpp and target.hpp > 0
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
    -- 1C. MOB-SPECIFIC SPELLS
    -- Casts the configured spell/fallback on matching mobs when ready.
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
    -- 2. JOB ABILITIES
    for _, ability_name in ipairs(active_profile.job_abilities or {}) do
        if Can_Cast_Ability(ability_name) then
            Cast_Ability(ability_name)
            return
        end
    end
    -- 3. SELF BUFFS
    for _, buff in ipairs(active_profile.self_buffs or {}) do
        -- buff.name may be a spell or priority-ordered fallback list.
        local names = type(buff.name) == 'table' and buff.name or {buff.name}
        local key = names[1]
        local interval = (buff.interval or 20) * 60
        local last = self_buff_last_cast[key]
        -- require_buff lets an entry only fire while a given player
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
    -- 4. SELF ABILITIES (Extended Pet & MP logic)
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
    -- 5. ENTRUST BUFFS
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
                            if m and m.name and m.mob and m.mob.id
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
                    if Can_Cast_Ability(eb.ability or 'Entrust') then
                        Cast_Ability(eb.ability or 'Entrust')
                        return
                    end
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
    -- 6. PARTY BUFFS
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
                        if m and m.name and m.mob and m.mob.id
                            and m.zone == me_zone
                            and not m.mob.is_npc
                            and (pb.self or key ~= 'p0')
                            and not Is_Haste_Blacklisted(m.name)
                            and m.mob.distance
                            and math.sqrt(m.mob.distance) <= range
                        then
                            targets[#targets+1] = m.name
                        end
                    end
                end
            elseif type(pb.targets) == 'table' and pb.targets.jobs then
                if party then
                    for _, key in ipairs({'p0','p1','p2','p3','p4','p5'}) do
                        local m = party[key]
                        if m and m.name and m.mob and m.mob.id
                            and m.zone == me_zone
                            and not m.mob.is_npc
                            and (pb.self or key ~= 'p0')
                            and m.mob.distance
                            and math.sqrt(m.mob.distance) <= range
                        then
                            for _, job in ipairs(pb.targets.jobs) do
                                if m.main_job == job then
                                    targets[#targets+1] = m.name
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
    -- 7. HASTE HANDLING
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
                    if m and m.name and m.mob and m.mob.id
                        and key ~= 'p0'
                        and m.zone == me_zone
                        and not m.mob.is_npc
                        and not Is_Haste_Blacklisted(m.name)
                        and m.mob.distance
                        and math.sqrt(m.mob.distance) <= 20
                    then
                        haste_targets[#haste_targets+1] = m.name
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
    -- 8. REFRESH HANDLING
    if active_profile.refresh_targets and not active_profile.party_buffs then
        local refresh = active_profile.refresh_targets
        local interval = (refresh.interval or 6) * 60
        local spell_name = refresh.spell or 'Refresh III'
        local me_zone = windower.ffxi.get_info().zone
        local party = windower.ffxi.get_party()
        if party then
            for _, key in ipairs({'p0','p1','p2','p3','p4','p5'}) do
                local m = party[key]
                if m and m.name and m.mob and m.mob.id
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
        pcall(Buff_Tick)
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
            if m.main_job == 'WHM' or m.job == 'WHM' then return true end
            if m.mob and m.mob.main_job == 'WHM' then return true end
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
    -- Emergency cure for low HP when the profile isn't already healing.
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
    for _, key in ipairs({'p0','p1','p2','p3','p4','p5'}) do
        local m = party[key]
        if m and m.hp and m.hp > 0 and m.hpp and m.hpp < worst_hpp then
            worst_hpp = m.hpp
            worst_member = m
        end
    end
    local threshold = failsafe and (active_profile.emergency_cure_threshold or 25) or 75
    if not worst_member or worst_hpp > threshold then return end
    local target_name = worst_member.name or (worst_member.mob and worst_member.mob.name)
    if not target_name then return end
    local max_hp = worst_member.hp / (worst_hpp / 100)
    local missing_hp = math.floor(max_hp - worst_member.hp)
    if missing_hp <= 0 then return end
    local target = (target_name == player.name) and '<me>' or target_name
    if failsafe then
        windower.add_to_chat(167, '[Lazy] Failsafe cure -- ' .. target_name .. ' at ' .. worst_hpp .. '% HP, no healer response')
    end
    for _, tier in ipairs(active_profile.cure_tiers or {}) do
        local min_m = tier.min_missing or 0
        local max_m = tier.max_missing or 999999
        if missing_hp >= min_m and missing_hp <= max_m then
            for _, spell_name in ipairs(tier.spells) do
                if Cast_Spell_On(spell_name, target) then return end
            end
            return
        end
    end
end
function Cure_Monitor()
    while Start_Engine do
        pcall(Cure_Bot_Tick)
        coroutine.sleep(0.5)
    end
end
-- REST 
--
-- Auto-kneels (/heal) when idle and MP is under REST_MP_THRESHOLD.
-- HP isn't a factor at all -- that's what self-cure is for. Single
-- absolute MP threshold, no separate resume percentage: under it,
-- rest; at or above it, don't.
--
-- "Threat" is simple: are we actually being hit right now, via the
-- existing last_damage_taken_time/last_damage_source_id tracking (the
-- same tracker Death_Monitor uses) -- not "is something merely
-- targeted and nearby." If nothing's hit us recently, it's safe, rest.
-- If something IS hitting us, don't just stand there: target and
-- engage the attacker so it actually gets fought, same idea as
-- Engagement_Sync's retarget-to-attacker logic but for when we're not
-- already engaged.
--
-- Also interrupted (stood up, not engaged) by a self-buff that's due
-- or an open skillchain window on a job that can magic burst -- those
-- get to actually fire via the existing Buff_Tick/Combat logic, not
-- duplicated here, and this just re-kneels next pass if MP still
-- calls for it.
--
-- Tracks its own is_resting flag rather than trusting player.status
-- for "am I already resting" -- kneeling doesn't reliably change
-- status in this client, so a self-tracked flag is what's reliable.
local REST_MP_THRESHOLD = 500 -- absolute MP, not a percentage
local REST_THREAT_WINDOW = 10 -- seconds; how recent a hit still counts as "being hit"
-- Only jobs that actually run on a meaningful MP pool rest at all.
-- DNC's MP is too small/situational to be worth kneeling for, and
-- every pure-melee job has none -- for those, resting would just be
-- standing around risking exactly the movement-blocking problem
-- fixed above, for no real benefit.
local REST_ELIGIBLE_JOBS = {
    WHM = true,
    RDM = true,
    BLM = true,
    GEO = true,
    SCH = true,
    SMN = true,
}
local function Being_Hit()
    return last_damage_taken_time and (os.clock() - last_damage_taken_time) <= REST_THREAT_WINDOW
end
local function Self_Buff_Due()
    if not active_profile then return false end
    local now = os.clock()
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
            return true
        end
    end
    return false
end
local function Skillchain_Burst_Pending()
    if not active_profile or not active_profile.magic_burst then return false end
    if not sc_active then return false end
    local target = windower.ffxi.get_mob_by_target('t')
    return target and sc_active(target.id) or false
end
function Rest_Monitor()
    while Start_Engine do
        local player = windower.ffxi.get_player()
        local idle_and_alive = player and player.status ~= 1
            and player.vitals and player.vitals.hpp and player.vitals.hpp > 0
        -- Being hit while idle and not already fighting the culprit:
        -- go kill it before it kills us, instead of just standing
        -- there. This runs for every job -- it's not an MP/resting
        -- thing, just "don't stand there getting hit."
        if idle_and_alive then
            local threat = Being_Hit()
            if threat and last_damage_source_id then
                local current = windower.ffxi.get_mob_by_target('t')
                local attacker = windower.ffxi.get_mob_by_id(last_damage_source_id)
                if attacker and attacker.valid_target and attacker.hpp and attacker.hpp > 0
                    and (attacker.claim_id == 0 or attacker.claim_id == player.id)
                    and (not current or current.id ~= attacker.id) then
                    windower.add_to_chat(167, '[Lazy] Being hit by ' .. attacker.name .. ' -- engaging.')
                    windower.send_command('input /target "' .. attacker.name .. '"; input /attack on')
                end
            end
        end
        -- Actual resting (kneeling for MP) only applies to jobs that
        -- run on a meaningful MP pool -- see REST_ELIGIBLE_JOBS above.
        if idle_and_alive and settings.rest_active and REST_ELIGIBLE_JOBS[current_job] then
            local mp = player.vitals.mp or 0
            local threat = Being_Hit()
            -- A legitimate current target means autotarget already
            -- picked the next mob and is trying to walk us there --
            -- kneeling blocks movement entirely, so resting can't be
            -- allowed to fight that. This is separate from "threat"
            -- (Being_Hit) -- it's not about whether something's
            -- attacking us, just whether we're supposed to be moving.
            local current_target = windower.ffxi.get_mob_by_target('t')
            local pursuing_target = current_target and current_target.valid_target
                and current_target.hpp and current_target.hpp > 0
            local should_pause = threat or pursuing_target or Self_Buff_Due() or Skillchain_Burst_Pending()
            if is_resting then
                if should_pause or mp >= REST_MP_THRESHOLD then
                    windower.send_command('input /heal off')
                    is_resting = false
                end
            else
                if not should_pause and mp < REST_MP_THRESHOLD then
                    -- Clear any stale/next target before kneeling. Targeting()
                    -- pauses while is_resting is true, so leader-mode autotarget
                    -- cannot immediately reacquire a mob and cancel /heal.
                    windower.send_command('input /target <me>; input /heal')
                    is_resting = true
                end
            end
        elseif is_resting then
            -- Not idle-and-alive anymore, rest toggled off, or this
            -- job isn't MP-eligible (e.g. switched off a caster mid-
            -- kneel) -- don't stay kneeling into something that needs
            -- us moving.
            windower.send_command('input /heal off')
            is_resting = false
        end
        coroutine.sleep(2)
    end
end