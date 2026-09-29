-- TARGETLOGIC
-- Target selection, pathing, following, and combat engagement.
-- Loaded by Lazy.lua via dofile.
--
-- Globals shared with Lazy.lua are intentionally not local.
-- ORIGIN / PATHING STATE
-- origin_x/y/z, origin_z_tolerance, pathing_to_origin, path_tick,
-- path_last_distance, path_last_progress_time, path_stuck_alerted,
-- and origin_unreachable_since are managed by Lazy.lua.
-- Do not redeclare them as local here.
-- FOLLOW STATE
-- Keep follow under one owner to prevent follow/cancel spam.
-- Never follow while engaged.
local follow_active = false
local follow_target_id = nil
local function Stop_Follow()
    if follow_active then
        windower.ffxi.follow(0)
        follow_active = false
        follow_target_id = nil
    end
end
local function Start_Follow(target_index, target_id)
    if not target_index then return end
    -- Already following this exact target. Do not re-issue follow().
    if follow_active and follow_target_id == target_id then
        return
    end
    -- If following something else, cancel it before changing targets.
    if follow_active then
        windower.ffxi.follow(0)
    end
    windower.ffxi.follow(target_index)
    follow_active = true
    follow_target_id = target_id
end
-- ORIGIN DISTANCE
function Origin_Distance(x, y, z)
    if not origin_x then return math.huge end
    if origin_z and z and math.abs(z - origin_z) > origin_z_tolerance then
        return math.huge
    end
    return math.sqrt((x - origin_x)^2 + (y - origin_y)^2)
end
function Set_Origin()
    local player = windower.ffxi.get_mob_by_id(windower.ffxi.get_player().id)
    if not player then return end
    origin_x = player.x
    origin_y = player.y
    origin_z = player.z
    path_last_distance = nil
    path_last_progress_time = nil
    path_stuck_alerted = false
    origin_unreachable_since = nil
    windower.add_to_chat(2, 'Origin set: (' .. math.floor(origin_x) .. ', ' .. math.floor(origin_y) .. ') radius: ' .. origin_radius)
end
function Path_To_Origin()
    if not origin_x then return end
    local player = windower.ffxi.get_mob_by_id(windower.ffxi.get_player().id)
    if not player then return end
    local distance = Origin_Distance(player.x, player.y, player.z)
    if distance == math.huge then
        Stop_Follow()
        windower.ffxi.run(false)
        local now = os.clock()
        if not origin_unreachable_since then
            origin_unreachable_since = now
        end
        if (now - origin_unreachable_since) >= ORIGIN_UNREACHABLE_TIMEOUT then
            windower.add_to_chat(2, '[Lazy] Origin unreachable for '
                .. math.floor(ORIGIN_UNREACHABLE_TIMEOUT / 60)
                .. ' min -- re-anchoring origin here and retargeting.')
            Set_Origin()
            return
        end
        if not path_stuck_alerted then
            windower.add_to_chat(167, '[Lazy] Origin unreachable at current elevation -- stopping autopath. Will re-anchor here after '
                .. math.floor(ORIGIN_UNREACHABLE_TIMEOUT / 60) .. ' min if still stuck.')
            path_stuck_alerted = true
        end
        pathing_to_origin = false
        path_tick = 0
        return
    end
    origin_unreachable_since = nil
    -- Pathing to origin is manual movement, not follow movement.
    -- Cancel Lazy's follow state once before taking over movement.
    Stop_Follow()
    if distance > 3 then
        local now = os.clock()
        if not path_last_distance or distance < path_last_distance - PATH_STUCK_EPSILON then
            path_last_distance = distance
            path_last_progress_time = now
            path_stuck_alerted = false
        elseif path_last_progress_time
            and (now - path_last_progress_time) >= PATH_STUCK_TIMEOUT then
            windower.ffxi.run(false)
            if not path_stuck_alerted then
                windower.add_to_chat(167, '[Lazy] Stuck pathing to origin (no progress in ' .. PATH_STUCK_TIMEOUT .. 's) -- stopping autopath.')
                path_stuck_alerted = true
            end
            pathing_to_origin = false
            path_tick = 0
            return
        end
        path_tick = path_tick + 1
        if path_tick % 4 == 1 then
            windower.ffxi.run(false)
        elseif path_tick % 4 == 2 then
            windower.ffxi.turn(HeadingTo(origin_x, origin_y))
        else
            windower.ffxi.run(true)
        end
    else
        windower.ffxi.run(false)
        pathing_to_origin = false
        path_tick = 0
        path_last_distance = nil
        path_last_progress_time = nil
        path_stuck_alerted = false
    end
end
-- TARGETING HELPERS
function Find_Named_Target(target_name)
    local mob_array = windower.ffxi.get_mob_array()
    local candidates = {}
    for key, mob in pairs(mob_array) do
        if mob.distance then
            candidates[#candidates + 1] = {
                key = key,
                mob = mob,
                dist = math.sqrt(mob.distance),
            }
        end
    end
    table.sort(candidates, function(a, b) return a.dist < b.dist end)
    for _, entry in ipairs(candidates) do
        local mob = entry.mob
        local in_range = true
        if origin_x and mob.x then
            in_range = Origin_Distance(mob.x, mob.y, mob.z) <= origin_radius
        end
        if string.lower(mob.name or '') == string.lower(target_name or '')
            and mob.valid_target
            and mob.hpp and mob.hpp > 0
            and in_range
            and mob.claim_id == 0
        then
            return entry.key
        end
    end
    return -1
end
function Is_Targetable_Monster(name)
    if not name then return false end
    for _, monster in ipairs(targeting.monsters or {}) do
        if string.lower(name) == string.lower(monster) then
            return true
        end
    end
    return false
end
function Find_Nearest_Target()
    local mob_array = windower.ffxi.get_mob_array()
    local candidates = {}
    for key, mob in pairs(mob_array) do
        if mob.distance then
            candidates[#candidates + 1] = {
                key = key,
                mob = mob,
                dist = math.sqrt(mob.distance),
            }
        end
    end
    table.sort(candidates, function(a, b) return a.dist < b.dist end)
    for _, entry in ipairs(candidates) do
        local mob = entry.mob
        local valid =
            Is_Targetable_Monster(mob.name)
            and mob.valid_target
            and (not targeting.only_alive or (mob.hpp and mob.hpp > 0))
            and (not targeting.within_origin or not origin_x or not mob.x
                or Origin_Distance(mob.x, mob.y, mob.z) <= origin_radius)
            and (not targeting.only_unclaimed or mob.claim_id == 0)
        if valid then return entry.key end
    end
    return -1
end
-- PARTY-AWARE TARGET PRIORITY
-- Target priority:
--   1. Current legitimate target.
--   2. Party member's target.
--   3. Nearest unclaimed whitelist target.
-- Used only for plain autotarget. Named targets always override.
function Get_Party_Claim_Ids()
    local ids = {}
    local party = windower.ffxi.get_party()
    if not party then return ids end
    local player = windower.ffxi.get_player()
    for _, key in ipairs({'p0','p1','p2','p3','p4','p5'}) do
        local m = party[key]
        if m then
            local id = (m.mob and m.mob.id) or m.id
            if id and (not player or id ~= player.id) then
                ids[id] = true
            end
        end
    end
    return ids
end
function Find_Party_Target(party_ids)
    if not party_ids or next(party_ids) == nil then return nil end
    local mob_array = windower.ffxi.get_mob_array()
    if not mob_array then return nil end
    for index, mob in pairs(mob_array) do
        if mob.valid_target and mob.hpp and mob.hpp > 0
            and mob.claim_id and party_ids[mob.claim_id] then
            local in_range = true
            if origin_x and mob.x then
                in_range = Origin_Distance(mob.x, mob.y, mob.z) <= origin_radius
            end
            if in_range then return index end
        end
    end
    return nil
end
-- Same idea as Find_Party_Target, but nearest-first rather than
-- first-found -- used specifically for "my target just died, what's
-- the closest thing the party's already fighting" (Engagement_Sync),
-- where distance actually matters. Returns the mob itself (not just
-- its index) since the caller needs its name to /target by.
function Find_Nearest_Party_Claimed_Target(party_ids)
    if not party_ids or next(party_ids) == nil then return nil end
    local mob_array = windower.ffxi.get_mob_array()
    if not mob_array then return nil end
    local candidates = {}
    for index, mob in pairs(mob_array) do
        if mob.valid_target and mob.hpp and mob.hpp > 0
            and mob.claim_id and party_ids[mob.claim_id]
            and mob.distance then
            local in_range = true
            if origin_x and mob.x then
                in_range = Origin_Distance(mob.x, mob.y, mob.z) <= origin_radius
            end
            if in_range then
                candidates[#candidates + 1] = { mob = mob, dist = math.sqrt(mob.distance) }
            end
        end
    end
    table.sort(candidates, function(a, b) return a.dist < b.dist end)
    if candidates[1] then return candidates[1].mob end
    return nil
end
function Is_Legitimate_Target(mob, expected_name, party_ids, already_engaged)
    if not mob or not mob.valid_target or not mob.hpp or mob.hpp <= 0 then
        return false
    end
    local in_range = true
    if origin_x and mob.x then
        in_range = Origin_Distance(mob.x, mob.y, mob.z) <= origin_radius
    end
    if not in_range then return false end
    local player = windower.ffxi.get_player()
    local claimed_by_us_or_party =
        mob.claim_id == 0
        or (player and mob.claim_id == player.id)
        or (party_ids and party_ids[mob.claim_id])
    if expected_name then
        return string.lower(mob.name or '') == string.lower(expected_name)
            and claimed_by_us_or_party
    end
    if claimed_by_us_or_party then
        return true
    end
    if already_engaged and player and player.status == 1 then
        return true
    end
    return Is_Targetable_Monster(mob.name)
end
function Choose_Target(party_ids)
    local player = windower.ffxi.get_player()
    if not player then return -1 end
    local current = windower.ffxi.get_mob_by_target('t')
    if Is_Legitimate_Target(current, nil, party_ids, true) then
        return current.index
    end
    local party_target = Find_Party_Target(party_ids)
    if party_target then return party_target end
    return Find_Nearest_Target()
end
-- MONITORS
local FOLLOW_MELEE_RANGE = 3
local FOLLOW_CAST_RANGE = 20
local function Engage_Distance(melee_default)
    if active_profile and active_profile.engage_distance then
        return active_profile.engage_distance
    end
    if active_profile and active_profile.auto_engage == false then
        return FOLLOW_CAST_RANGE
    end
    return melee_default or 1
end
function Follow_Monitor()
    while Start_Engine do
        local player = windower.ffxi.get_player()
        -- CRITICAL:
        -- Once FFXI reports us as engaged, follow is completely disabled.
        -- This prevents this 0.2s coroutine from undoing the combat stop
        -- issued by Targeting()/Target_Monitor().
        if player and player.status == 1 then
            Stop_Follow()
        elseif is_resting then
            Stop_Follow()
        else
            local target = windower.ffxi.get_mob_by_target('t')
            if not target then
                Stop_Follow()
            elseif isCasting or isBusy > 0 then
                Stop_Follow()
            else
                local distance = target.distance and math.sqrt(target.distance)
                local stop_range = Engage_Distance(FOLLOW_MELEE_RANGE)
                if not distance or distance <= stop_range then
                    Stop_Follow()
                else
                    Start_Follow(target.index, target.id)
                end
            end
        end
        coroutine.sleep(0.2)
    end
end
-- COMBAT STALL / ASSIST WATCH
last_party_damage_to_target = nil
damage_watch_target_id      = nil
party_activity              = {}
temp_assist_mob_id          = nil
function Is_Party_Member(actor_id)
    if not actor_id then return false end
    local party = windower.ffxi.get_party()
    if not party then return false end
    for _, key in ipairs({'p0','p1','p2','p3','p4','p5'}) do
        local m = party[key]
        local mid = m and ((m.mob and m.mob.id) or m.id)
        if mid == actor_id then return true end
    end
    return false
end
windower.register_event('incoming chunk', function(id, data)
    if id ~= 0x028 then return end
    local action = packets.parse('incoming', data)
    local player = windower.ffxi.get_player()
    if not player then return end
    local current    = windower.ffxi.get_mob_by_target('t')
    local current_id = current and current.id
    if damage_watch_target_id ~= current_id then
        damage_watch_target_id      = current_id
        last_party_damage_to_target = current_id and os.clock() or nil
    end
    local is_self  = action.Actor == player.id
    local is_party = is_self or Is_Party_Member(action.Actor)
    if not is_party then return end
    local target_count = action['Target Count'] or 1
    for t = 1, target_count do
        local tid = action['Target ' .. t .. ' ID']
        if tid and action['Target ' .. t .. ' Action 1 Reaction'] == 0 then
            if tid == current_id then
                last_party_damage_to_target = os.clock()
            end
            if not is_self then
                party_activity[action.Actor] = {
                    last_hit = os.clock(),
                    target_id = tid
                }
            end
            break
        end
    end
end)
local COMBAT_SAFETY_HP_THRESHOLD = 25
function Combat_Stall_Monitor()
    while Start_Engine do
        local player = windower.ffxi.get_player()
        local current = player and windower.ffxi.get_mob_by_target('t')
        if player and player.status == 1 and current
            and current.valid_target and current.hpp and current.hpp > 0 then
            -- We are already fighting. Never allow any follow state
            -- to remain active while the stall/assist monitor works.
            Stop_Follow()
            local now = os.clock()
            if last_party_damage_to_target and now - last_party_damage_to_target >= 20 then
                windower.add_to_chat(207, '[Lazy] No damage landing on ' .. current.name .. ' for 20s -- switching targets.')
                windower.send_command('input /attack off; input /target <me>')
                temp_assist_mob_id = nil
            elseif player.vitals.hpp and player.vitals.hpp > COMBAT_SAFETY_HP_THRESHOLD then
                local helper_target_id = nil
                for actor_id, info in pairs(party_activity) do
                    if now - info.last_hit <= 5 and info.target_id ~= current.id then
                        helper_target_id = info.target_id
                        break
                    end
                end
                if helper_target_id then
                    local mob = windower.ffxi.get_mob_by_id(helper_target_id)
                    if mob and mob.valid_target and mob.hpp and mob.hpp > 0 then
                        windower.add_to_chat(207, '[Lazy] Not landing hits on ' .. current.name .. ' -- helping with ' .. mob.name .. ' instead.')
                        windower.send_command('input /target "' .. mob.name .. '"; wait 0.2; input /attack on')
                        temp_assist_mob_id = mob.id
                    end
                end
            end
        elseif temp_assist_mob_id then
            local mob = windower.ffxi.get_mob_by_id(temp_assist_mob_id)
            if not mob or not mob.valid_target or not mob.hpp or mob.hpp <= 0 then
                windower.add_to_chat(207, '[Lazy] Done helping -- back to normal targeting.')
                temp_assist_mob_id = nil
                Stop_Follow()
                windower.send_command('input /attack off; input /target <me>')
            end
        end
        coroutine.sleep(5)
    end
end
-- ENGAGEMENT SYNC
function Engagement_Sync()
    while Start_Engine do
        local player = windower.ffxi.get_player()
        if player then
            for i = #aggro_queue, 1, -1 do
                local candidate = windower.ffxi.get_mob_by_id(aggro_queue[i])
                if not candidate
                    or not candidate.valid_target
                    or not candidate.hpp or candidate.hpp <= 0
                    or (candidate.claim_id ~= 0 and candidate.claim_id ~= player.id) then
                    table.remove(aggro_queue, i)
                end
            end
        end
        if player and player.status == 1 then
            -- Engaged means combat owns movement. Kill any leftover
            -- Lazy follow state before doing engagement sync.
            Stop_Follow()
            local current = windower.ffxi.get_mob_by_target('t')
            local current_ok =
                current
                and current.valid_target
                and current.hpp and current.hpp > 0
                and current.distance and math.sqrt(current.distance) <= 5
            if not current_ok then
                local switched = false
                while #aggro_queue > 0 and not switched do
                    local candidate_id = table.remove(aggro_queue, 1)
                    local candidate = windower.ffxi.get_mob_by_id(candidate_id)
                    if candidate and candidate.valid_target
                        and candidate.hpp and candidate.hpp > 0
                        and (candidate.claim_id == 0 or candidate.claim_id == player.id) then
                        windower.add_to_chat(2, '[Lazy] Finishing that off, now dealing with: ' .. candidate.name)
                        windower.send_command('input /target "' .. candidate.name .. '"')
                        switched = true
                    end
                end
                if not switched and last_damage_source_id then
                    local attacker = windower.ffxi.get_mob_by_id(last_damage_source_id)
                    if attacker and attacker.valid_target
                        and attacker.hpp and attacker.hpp > 0
                        and (attacker.claim_id == 0 or attacker.claim_id == player.id)
                        and (not current or attacker.id ~= current.id) then
                        windower.add_to_chat(2, '[Lazy] Engaged target mismatch -- retargeting to ' .. attacker.name)
                        windower.send_command('input /target "' .. attacker.name .. '"')
                        switched = true
                    end
                end
                if not switched then
                    local party_ids = Get_Party_Claim_Ids()
                    local mob = Find_Nearest_Party_Claimed_Target(party_ids)
                    if mob and (not current or mob.id ~= current.id) then
                        windower.add_to_chat(2, '[Lazy] Current target down -- joining party on: ' .. mob.name)
                        windower.send_command('input /target "' .. mob.name .. '"')
                        switched = true
                    end
                end
            end
        end
        coroutine.sleep(10)
    end
end
function Target_Monitor()
    while Start_Engine do
        local player = windower.ffxi.get_player()
        -- Never do target movement while already engaged.
        if player and player.status == 1 then
            Stop_Follow()
        elseif player then
            local target = windower.ffxi.get_mob_by_target('t')
            if target and settings.target ~= '' and target.id ~= player.id then
                local name_ok =
                    string.lower(target.name or '') == string.lower(settings.target)
                local in_range = true
                if origin_x and target.x then
                    in_range = Origin_Distance(target.x, target.y, target.z) <= origin_radius
                end
                if not name_ok or not in_range or target.claim_id ~= 0 then
                    Stop_Follow()
                    windower.add_to_chat(2, 'Invalid target (' .. target.name .. ') - resetting')
                    windower.send_command('input /target <me>')
                elseif target.distance and math.sqrt(target.distance) <= Engage_Distance(FOLLOW_MELEE_RANGE)
                    and active_profile.auto_engage ~= false then
                    -- We are close enough. STOP FOLLOWING BEFORE ATTACKING.
                    Stop_Follow()
                    windower.send_command('input /attack on')
                end
            end
        end
        coroutine.sleep(0.5)
    end
end
function Targeting()
    while Start_Engine do
        local player = windower.ffxi.get_player()
        if player and player.status == 1 then
            -- Combat has absolute priority over follow.
            Stop_Follow()
        elseif player then
            if is_resting then
                Stop_Follow()
            elseif settings.assist ~= '' then
                windower.send_command('input /assist ' .. settings.assist)
                local target = windower.ffxi.get_mob_by_target('t')
                if target and target.claim_id ~= 0 then
                    local distance = target.distance and math.sqrt(target.distance)
                    local stop_range = Engage_Distance(FOLLOW_MELEE_RANGE)
                    if distance and distance > stop_range then
                        Start_Follow(target.index, target.id)
                    else
                        -- In position: stop following before attacking.
                        Stop_Follow()
                        if active_profile.auto_engage ~= false then
                            windower.send_command('input /attack on')
                        end
                    end
                else
                    Stop_Follow()
                end
                if not lockon_done and active_profile.auto_engage ~= false then
                    windower.send_command('input /lockon')
                    lockon_done = true
                end
            elseif settings.autotarget then
                local target_id
                local expected_name =
                    (settings.target and settings.target ~= '')
                    and settings.target
                    or nil
                local party_ids = Get_Party_Claim_Ids()
                if expected_name then
                    target_id = Find_Named_Target(settings.target)
                else
                    target_id = Choose_Target(party_ids)
                end
                if target_id > 0 then
                    local mob = windower.ffxi.get_mob_by_index(target_id)
                    if mob and Is_Legitimate_Target(mob, expected_name, party_ids, false) then
                        pathing_to_origin = false
                        path_tick = 0
                        local distance = mob.distance and math.sqrt(mob.distance)
                        local stop_range = Engage_Distance(FOLLOW_MELEE_RANGE)
                        if distance and distance > stop_range then
                            -- Still approaching. Follow the selected target.
                            Start_Follow(mob.index, mob.id)
                        else
                            -- We have arrived. Follow MUST stop before
                            -- the attack command is issued.
                            Stop_Follow()
                            windower.send_command('input /target "' .. mob.name .. '"')
                            if active_profile.auto_engage ~= false then
                                windower.send_command('input /attack on')
                                if not lockon_done then
                                    windower.send_command('input /lockon')
                                    lockon_done = true
                                end
                            end
                        end
                    else
                        Stop_Follow()
                    end
                else
                    Stop_Follow()
                    Path_To_Origin()
                end
            end
        end
        coroutine.sleep(0.5)
    end
end