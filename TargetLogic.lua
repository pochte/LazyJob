------------------------------------------------------------
-- TARGETLOGIC
------------------------------------------------------------
-- Everything about deciding what to fight and how to get there --
-- split out of Lazy.lua since it had grown into its own large,
-- fairly self-contained subsystem (roughly 40% of the file by line
-- count). Loaded by Lazy.lua via dofile, same as skillchain.lua/
-- magicburst.lua/DNCQueen.lua.
--
-- Covers: origin/pathing (Set_Origin, Origin_Distance,
-- Path_To_Origin), the pure target-finding helpers (Find_Nearest_
-- Target, Find_Named_Target, Find_Party_Target, Find_Nearest_Party_
-- Claimed_Target, Is_Legitimate_Target, Choose_Target), the combat-
-- stall/assist-jump watch, the post-death engagement/aggro-queue
-- fallback chain (Engagement_Sync), and the actual per-tick
-- targeting/follow/target-validation loop (Targeting, Follow_Monitor,
-- Target_Monitor).
--
-- Several variables here are declared without `local` on purpose:
-- Lazy.lua's core reset block (//lazy start) and packet handlers
-- touch them directly, and dofile'd chunks don't share locals across
-- file boundaries in Lua -- only globals do. Anything that's genuinely
-- private to this file (constants, internal-only state) stays local.
------------------------------------------------------------
-- ORIGIN / PATHING STATE
local origin_x = nil
local origin_y = nil
local origin_z = nil
local origin_z_tolerance = 15 -- yalms of vertical separation still considered "in range"
local pathing_to_origin = false
local path_tick = 0
local path_last_distance = nil
local path_last_progress_time = nil
local path_stuck_alerted = false
local origin_unreachable_since = nil
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
    windower.ffxi.follow(0)
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
function Is_Legitimate_Target(mob, expected_name, party_ids)
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
        -- A named target is still only legitimate if it's ours,
        -- the party's, or unclaimed -- matching the name alone
        -- isn't enough, or we'd happily keep "targeting" a mob a
        -- total stranger has already claimed.
        return string.lower(mob.name or '') == string.lower(expected_name)
            and claimed_by_us_or_party
    end
    if claimed_by_us_or_party then
        return true
    end
    return Is_Targetable_Monster(mob.name)
end
function Choose_Target(party_ids)
    local player = windower.ffxi.get_player()
    if not player then return -1 end
    local current = windower.ffxi.get_mob_by_target('t')
    if Is_Legitimate_Target(current, nil, party_ids) then
        return current.index
    end
    local party_target = Find_Party_Target(party_ids)
    if party_target then return party_target end
    return Find_Nearest_Target()
end
-- MONITORS 
local FOLLOW_MELEE_RANGE = 3
function Follow_Monitor()
    while Start_Engine do
        local target = windower.ffxi.get_mob_by_target('t')
        if not target then
            windower.ffxi.follow(0)
        elseif isCasting or isBusy > 0 then
            windower.ffxi.follow(0)
        else
            local distance = target.distance and math.sqrt(target.distance)
            if distance and distance <= FOLLOW_MELEE_RANGE then
                windower.ffxi.follow(0)
            else
                windower.ffxi.follow(target.index)
            end
        end
        coroutine.sleep(0.2)
    end
end
-- COMBAT STALL / ASSIST WATCH
--
-- Tracks who's actually landing hits, separate from the death-watch
-- tracker above (which is about damage taken, not dealt).
--   last_party_damage_to_target -- last time ANYONE (us or party)
--     landed a hit on our current <t>. If this goes 20s with no hits
--     at all, the fight's stalled -- nothing's dying, drop it and let
--     normal targeting pick something else.
--   party_activity -- who in the party hit what, and when, regardless
--     of what our own target is. If a party member's actively fighting
--     something other than our own <t>, jump over and help with that
--     one mob right away (no waiting to first prove we're whiffing),
--     then revert once it dies.
last_party_damage_to_target = nil
damage_watch_target_id      = nil
party_activity              = {}  -- [actor_id] = {last_hit = os.clock(), target_id = mob id}
temp_assist_mob_id          = nil -- non-nil while temporarily helping someone else's fight
local function Is_Party_Member(actor_id)
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
    -- New/changed target -- give it a clean 20s grace period instead of
    -- inheriting a stale timer from whatever we were fighting before.
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
                party_activity[action.Actor] = {last_hit = os.clock(), target_id = tid}
            end
            break
        end
    end
end)
-- Below this HP%, don't let automation volunteer the player for a
-- brand new fight it doesn't have to be in (see the whiff-and-assist
-- gate in Combat_Stall_Monitor below). Not a flee system -- just
-- stops digging the hole deeper while already hurt.
local COMBAT_SAFETY_HP_THRESHOLD = 25
function Combat_Stall_Monitor()
    while Start_Engine do
        local player = windower.ffxi.get_player()
        local current = player and windower.ffxi.get_mob_by_target('t')
        if player and player.status == 1 and current
            and current.valid_target and current.hpp and current.hpp > 0 then
            local now = os.clock()
            if last_party_damage_to_target and now - last_party_damage_to_target >= 20 then
                windower.add_to_chat(207, '[Lazy] No damage landing on ' .. current.name .. ' for 20s -- switching targets.')
                windower.send_command('input /attack off; input /target <me>')
                temp_assist_mob_id = nil
            elseif player.vitals.hpp and player.vitals.hpp > COMBAT_SAFETY_HP_THRESHOLD then
                -- No more waiting to prove we're not contributing --
                -- if a party member's actively fighting something
                -- else, jump over right away. Jumping INTO a second,
                -- separate mob while already hurt is how a melee dies
                -- for no reason though, so this still won't volunteer
                -- for a new fight below the safety threshold. Still
                -- allowed to bail on a genuinely stalled fight above
                -- (that's risk-reducing, not risk-adding).
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
            -- The mob we jumped over to help with is dead/gone --
            -- drop it and let normal targeting take back over.
            local mob = windower.ffxi.get_mob_by_id(temp_assist_mob_id)
            if not mob or not mob.valid_target or not mob.hpp or mob.hpp <= 0 then
                windower.add_to_chat(207, '[Lazy] Done helping -- back to normal targeting.')
                temp_assist_mob_id = nil
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
            --------------------------------------------------------
            -- Prune the aggro queue: drop anything that's died,
            -- despawned, or been claimed by someone else in the
            -- meantime -- other people are often around, and there's
            -- no point queuing up a fight with something someone else
            -- already has. Just falls through to the next entry.
            --------------------------------------------------------
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
            local current = windower.ffxi.get_mob_by_target('t')
            local current_ok =
                current
                and current.valid_target
                and current.hpp and current.hpp > 0
                and current.distance and math.sqrt(current.distance) <= 5
            if not current_ok then
                --------------------------------------------------------
                -- Current target's dead/gone -- work through whoever
                -- else started hitting us while we were busy, oldest
                -- first, before falling back to a generic guess. We
                -- never touch the queue while current_ok is true, so
                -- an in-progress fight is never interrupted by an add
                -- joining in -- finish the kill, then deal with it.
                -- (Already-claimed-by-someone-else entries were pruned
                -- above, so anything left here is fair game.)
                --------------------------------------------------------
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
                    -- Nothing specifically attacked us -- fall back to
                    -- whatever's closest that the party's already
                    -- fighting, instead of leaving us standing around
                    -- until fresh autotarget finds something unclaimed.
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
        if player and player.status ~= 1 then
            local target = windower.ffxi.get_mob_by_target('t')
            if target and settings.target ~= '' and target.id ~= player.id then
                local name_ok = string.lower(target.name or '') == string.lower(settings.target)
                local in_range = true
                if origin_x and target.x then
                    in_range = Origin_Distance(target.x, target.y, target.z) <= origin_radius
                end
                if not name_ok or not in_range or target.claim_id ~= 0 then
                    windower.add_to_chat(2, 'Invalid target (' .. target.name .. ') - resetting')
                    windower.send_command('input /target <me>')
                elseif target.distance <= 1 and active_profile.auto_engage ~= false then
                    windower.send_command('input /attack on')
                    windower.ffxi.follow(target.index)
                end
            end
        end
        coroutine.sleep(0.5)
    end
end
function Targeting()
    while Start_Engine do
        local player = windower.ffxi.get_player()
        if player and player.status ~= 1 then
            if settings.assist ~= '' then
                windower.send_command('input /assist ' .. settings.assist)
                local target = windower.ffxi.get_mob_by_target('t')
                if target and target.claim_id ~= 0 then
                    windower.ffxi.follow(target.index)
                    if active_profile.auto_engage ~= false then
                        windower.send_command('input /attack on')
                    end
                end
                if not lockon_done and active_profile.auto_engage ~= false then
                    windower.send_command('input /lockon')
                    lockon_done = true
                end
            elseif settings.autotarget then
                local target_id
                local expected_name = (settings.target and settings.target ~= '') and settings.target or nil
                local party_ids = Get_Party_Claim_Ids()
                if expected_name then
                    target_id = Find_Named_Target(settings.target)
                else
                    target_id = Choose_Target(party_ids)
                end
                if target_id > 0 then
                    pathing_to_origin = false
                    path_tick = 0
                    windower.ffxi.follow(target_id)
                    local mob = windower.ffxi.get_mob_by_index(target_id)
                    if Is_Legitimate_Target(mob, expected_name, party_ids) then
                        local distance = math.sqrt(mob.distance)
                        if distance < 1 then
                            windower.send_command('input /target "' .. mob.name .. '"')
                            if active_profile.auto_engage ~= false then
                                windower.send_command('input /attack on')
                                if not lockon_done then
                                    windower.send_command('input /lockon')
                                    lockon_done = true
                                end
                            end
                        end
                    end
                else
                    Path_To_Origin()
                end
            end
        end
        coroutine.sleep(0.5)
    end
end