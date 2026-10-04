-- TARGETLOGIC
-- Target selection, origin/pathing, follow, and combat target management.
-- COMBAT RULE: once /attack on is sent and FFXI reports status == 1, combaowns the target. Don't reselect, don't resend /attack, don't watch
-- target.hpp or stale mob-table data, and don't release the lock whileengaged. Player status is the only authority for ending combat.
-- PRE-ENGAGE: a committed target can be followed before combat starts.

-- ORIGIN / PATHING
function Origin_Distance(x, y, z)
    if not origin_x then
        return math.huge
    end
    if origin_z
        and z
        and math.abs(z - origin_z) > origin_z_tolerance
    then
        return math.huge
    end
    return math.sqrt(
        (x - origin_x)^2 +
        (y - origin_y)^2
    )
end
function Set_Origin()
    local player =
        windower.ffxi.get_player()
    if not player then
        return
    end
    local mob =
        windower.ffxi.get_mob_by_id(
            player.id
        )
    if not mob then
        return
    end
    origin_x = mob.x
    origin_y = mob.y
    origin_z = mob.z
    path_last_distance = nil
    path_last_progress_time = nil
    path_stuck_alerted = false
    origin_unreachable_since = nil
    windower.add_to_chat(
        2,
        'Origin set: (' ..
        math.floor(origin_x) ..
        ', ' ..
        math.floor(origin_y) ..
        ') radius: ' ..
        origin_radius
    )
end
function Path_To_Origin()
    if not origin_x then
        return
    end
    local player =
        windower.ffxi.get_player()
    if not player then
        return
    end
    local mob =
        windower.ffxi.get_mob_by_id(
            player.id
        )
    if not mob then
        return
    end
    local distance =
        Origin_Distance(mob.x, mob.y,mob.z)
    if distance == math.huge then
        windower.ffxi.run(false)
        local now = os.clock()
        if not origin_unreachable_since then
            origin_unreachable_since = now
        end
        if
            (now - origin_unreachable_since)
            >= ORIGIN_UNREACHABLE_TIMEOUT
        then
            windower.add_to_chat(
                2,
                '[Lazy] Origin unreachable for ' ..
                math.floor(
                    ORIGIN_UNREACHABLE_TIMEOUT / 60
                ) ..
                ' min -- re-anchoring origin and retargeting.'
            )
            Set_Origin()
            return
        end
        if not path_stuck_alerted then
            windower.add_to_chat(
                167,
                '[Lazy] Origin unreachable at current elevation -- stopping autopath. Will re-anchor here after ' ..
                math.floor(
                    ORIGIN_UNREACHABLE_TIMEOUT / 60
                ) ..
                ' min if still stuck.'
            )
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
        if not path_last_distance
            or distance <
                path_last_distance - PATH_STUCK_EPSILON
        then
            path_last_distance = distance
            path_last_progress_time = now
            path_stuck_alerted = false
        elseif path_last_progress_time
            and
            (now - path_last_progress_time)
                >= PATH_STUCK_TIMEOUT
        then
            windower.ffxi.run(false)
            if not path_stuck_alerted then
                windower.add_to_chat(
                    167,
                    '[Lazy] Stuck pathing to origin (no progress in ' ..
                    PATH_STUCK_TIMEOUT ..
                    's) -- stopping autopath.'
                )
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
-- UNATTACKABLE TRACKING
unattackable_until = {}
function Is_Unattackable(id)
    local until_time =
        id
        and unattackable_until[id]
    if not until_time then
        return false
    end
    if os.clock() >= until_time then
        unattackable_until[id] = nil
        return false
    end
    return true
end
windower.register_event('incoming text', function(original)
    if not Start_Engine or not original then return end
    if string.find(original, '[Lazy DEBUG]', 1, true) then return end
    if string.find(original, 'You cannot attack that target', 1, true) then
        local target = windower.ffxi.get_mob_by_target('t')
        if Debug.enabled then
            local player = windower.ffxi.get_player()
            Debug.Log('!!! FFXI REJECTED ATTACK !!!')
            Debug.Log('Message: ' .. tostring(original))
            Debug.Target('TARGET WHEN ATTACK WAS REJECTED', target)
            Debug.State('STATE WHEN ATTACK WAS REJECTED')
            Debug.Log(string.format(
                'REJECTION STATE | player_status=%s managed=%s locked=%s engage_sent=%s combat_started=%s',
                tostring(player and player.status), tostring(managed_target_id),
                tostring(combat_locked_target_id), tostring(engage_sent_target_id),
                tostring(combat_started)))
        end
        -- If combat never actually started, the engage attempt failed and
        -- the target may be retried. Once combat has started, NEVER release
        -- the combat lock because of this message.
        if target and target.id then
            if target.id == combat_locked_target_id and not combat_started then
                Debug.Target('ATTACK REJECTED BEFORE COMBAT - CLEARING LOCK', target)
                unattackable_until[target.id] = os.clock() + 20
                Clear_Combat_Target()
            elseif target.id ~= combat_locked_target_id then
                unattackable_until[target.id] = os.clock() + 20
            end
        end
    end
end)
-- RANGED PULL
pull_attempts = {}
function Try_Ranged_Pull(mob, distance)
    local rp =
        active_profile
        and active_profile.ranged_pull
    if not rp
        or not mob
        or mob.claim_id ~= 0
    then
        return false
    end
    if not distance
        or distance > (rp.range or 20)
    then
        return false
    end
    windower.ffxi.follow(0)
    local current =
        windower.ffxi.get_mob_by_target('t')
    if not current
        or current.id ~= mob.id
    then
        Debug.Target(
            'RANGED PULL SELECT',
            mob
        )
        Select_Target(mob)
        return true
    end
    if isBusy > 0
        or isCasting
        or (
            Is_Moving
            and Is_Moving()
        )
    then
        return true
    end
    local now = os.clock()
    local info =
        pull_attempts[mob.id]
        or {
            count = 0,
            last = 0
        }
    local retry =
        rp.retry or 6
    if now - info.last < retry then
        return true
    end
    if info.count >= (rp.max_tries or 3) then
        unattackable_until[mob.id] =
            now + 20
        pull_attempts[mob.id] = nil
        return true
    end
    Debug.Target(
        'RANGED PULL',
        mob
    )
    windower.send_command(
        'input /ra <t>'
    )
    info.count = info.count + 1
    info.last = now
    pull_attempts[mob.id] = info
    isBusy = Action_Delay
    return true
end
-- TARGETING HELPERS
function Find_Named_Target(target_name)
    local mob_array =
        windower.ffxi.get_mob_array()
    if not mob_array then return nil end
    local candidates = {}
    for key, mob in pairs(mob_array) do
        if mob and mob.distance and not Is_Player_Pet(mob) then
            candidates[#candidates + 1] = {
                key = key,
                mob = mob,
                dist = math.sqrt(mob.distance),
            }
        end
    end
    table.sort(
        candidates,
        function(a, b)
            return a.dist < b.dist
        end
    )
    for _, entry in ipairs(candidates) do
        local mob = entry.mob
        local in_range = true
        if origin_x
            and mob.x
        then
            in_range = Origin_Distance(mob.x,mob.y,mob.z) <= origin_radius
        end
        if
            string.lower(mob.name or '') ==
                string.lower(target_name or '')
            and mob.valid_target
            and mob.hpp
            and mob.hpp > 0
            and in_range
            and mob.claim_id == 0
            and not Is_Unattackable(mob.id)
        then
            return entry.key
        end
    end
    return -1
end
function Is_Targetable_Monster(name)
    if not name then
        return false
    end
    for _, monster in ipairs(
        targeting.monsters or {}
    ) do
        if
            string.lower(name) ==
                string.lower(monster)
        then
            return true
        end
    end
    return false
end
function Find_Nearest_Target()
    local mob_array =
        windower.ffxi.get_mob_array()
    if not mob_array then return -1 end
    local candidates = {}
    for key, mob in pairs(mob_array) do
        if mob and mob.distance and not Is_Player_Pet(mob) then
            candidates[#candidates + 1] = {
                key = key,
                mob = mob,
                dist = math.sqrt(mob.distance),
            }
        end
    end
    table.sort(
        candidates,
        function(a, b)
            return a.dist < b.dist
        end
    )
    for _, entry in ipairs(candidates) do
        local mob = entry.mob
        local valid =
            Is_Targetable_Monster(mob.name)
            and mob.valid_target
            and (
                not targeting.only_alive
                or (
                    mob.hpp
                    and mob.hpp > 0
                )
            )
            and (
                not targeting.within_origin
                or not origin_x
                or not mob.x
                or Origin_Distance(mob.x, mob.y, mob.z) <= origin_radius
            )
            and (not targeting.only_unclaimed
                    or mob.claim_id == 0)
            and not Is_Unattackable(mob.id)
        if valid then
            return entry.key
        end
    end
    return -1
end
-- PARTY / TRUST HELPERS
function Is_Party_Member(actor_id)
    if not actor_id then return false end
    local party = windower.ffxi.get_party()
    if not party then return false end
    for _, key in ipairs({'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}) do
        local m = party[key]
        local id = m and ((m.mob and m.mob.id) or m.id)
        if id == actor_id then return true end
    end
    return false
end
function Is_Solo_Leader()
    if not settings or settings.assist ~= '' then return false end
    local party = windower.ffxi.get_party()
    if not party then return true end
    for _, key in ipairs({'p1', 'p2', 'p3', 'p4', 'p5'}) do
        local m = party[key]
        if m and (not m.mob or not m.mob.is_npc) then return false end
    end
    return true
end
function Get_Party_Claim_Ids()
    local ids = {}
    local party = windower.ffxi.get_party()
    if not party then return ids end
    local player = windower.ffxi.get_player()
    for _, key in ipairs({'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}) do
        local m = party[key]
        local id = m and ((m.mob and m.mob.id) or m.id)
        if id and (not player or id ~= player.id) then ids[id] = true end
    end
    return ids
end
function Find_Party_Target(party_ids)
    if not party_ids or next(party_ids) == nil then return nil end
    local mob_array = windower.ffxi.get_mob_array()
    if not mob_array then return nil end
    for index, mob in pairs(mob_array) do
        if mob
            and not Is_Player_Pet(mob)
            and mob.valid_target
            and mob.hpp and mob.hpp > 0
            and not Is_Unattackable(mob.id)
            and mob.claim_id and party_ids[mob.claim_id]
            and (not (origin_x and mob.x)
                or Origin_Distance(mob.x, mob.y, mob.z) <= origin_radius)
        then
            return index
        end
    end
    return nil
end
function Find_Nearest_Party_Claimed_Target(party_ids)
    if not party_ids or next(party_ids) == nil then return nil end
    local mob_array = windower.ffxi.get_mob_array()
    if not mob_array then return nil end
    local candidates = {}
    for _, mob in pairs(mob_array) do
        if mob
            and not Is_Player_Pet(mob)
            and mob.valid_target
            and mob.hpp and mob.hpp > 0
            and not Is_Unattackable(mob.id)
            and mob.claim_id and party_ids[mob.claim_id]
            and mob.distance
            and (not (origin_x and mob.x)
                or Origin_Distance(mob.x, mob.y, mob.z) <= origin_radius)
        then
            candidates[#candidates + 1] = {mob = mob, dist = math.sqrt(mob.distance)}
        end
    end
       table.sort(candidates, function(a, b) return a.dist < b.dist end)
    return candidates[1] and candidates[1].mob
end
-- PLAYER PET / LUOPAN FILTER
-- `is_pet` and `owner_id` are not real fields on Windower's mob table --
-- checking them was a silent no-op, always false, for every mob. The
-- documented, reliable signal is `pet_index` on a PC's own mob entry: it
-- points at their active pet's index in the mob array (Luopan, avatar,
-- automaton, wyvern, charmed pet -- any of them, for any party member,
-- not just yourself). A mob is a player's pet if its index matches
-- anyone in the party's pet_index.
function Is_Player_Pet(mob)
    if not mob or not mob.index then return false end
    local party = windower.ffxi.get_party()
    if not party then return false end
    for _, key in ipairs({'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}) do
        local m = party[key]
        if m and m.mob and m.mob.pet_index
            and m.mob.pet_index > 0
            and m.mob.pet_index == mob.index
        then
            return true
        end
    end
    return false
end

-- TARGET LEGITIMACY
function Is_Legitimate_Target(mob, expected_name, party_ids, already_engaged)
    if not mob or Is_Player_Pet(mob) or not mob.valid_target or not mob.hpp or mob.hpp <= 0 then return false end
    if origin_x and mob.x and Origin_Distance(mob.x, mob.y, mob.z) > origin_radius then
        return false
    end
    local player = windower.ffxi.get_player()
    if (player and mob.id == player.id)
        or Is_Party_Member(mob.id)
        or Is_Unattackable(mob.id)
    then
        return false
    end
    local ours = mob.claim_id == 0
        or (player and mob.claim_id == player.id)
        or (party_ids and party_ids[mob.claim_id])
    if expected_name then
        return string.lower(mob.name or '') == string.lower(expected_name) and ours
    end
    if ours then return true end
    if already_engaged and player and player.status == 1 then return true end
    -- Not claimed by us/the party, and not something we're already
    -- fighting -- being on the autotarget whitelist by name doesn't
    -- override that. This used to fall through to
    -- Is_Targetable_Monster(mob.name), which only checks the name and
    -- ignores claim_id entirely -- so a mob a stranger claimed still
    -- came back "legitimate" as long as it was on the whitelist.
    return false
end
function Choose_Target(party_ids)
    if not windower.ffxi.get_player() then return -1 end
    local current = windower.ffxi.get_mob_by_target('t')
    if Is_Legitimate_Target(current, nil, party_ids, true) then return current.index end
    local nearest = Find_Nearest_Target()
    if nearest > 0 then return nearest end
    if Is_Solo_Leader() then return -1 end
    return Find_Party_Target(party_ids) or -1
end
-- TARGET STATE
managed_target_id =
    managed_target_id or nil
pending_target_id =
    pending_target_id or nil
pending_target_time =
    pending_target_time or 0
local TARGET_SELECT_TIMEOUT = 3
combat_locked_target_id =
    combat_locked_target_id or nil
engage_sent_target_id =
    engage_sent_target_id or nil
combat_lock_time =
    combat_lock_time or nil
-- True only after FFXI has actually reported status == 1
-- for the currently committed combat target.
combat_started =
    combat_started or false
-- CLEAR COMBAT STATE
function Clear_Combat_Target()
    Debug.State(
        'CLEARING COMBAT STATE'
    )
    combat_locked_target_id = nil
    managed_target_id = nil
    pending_target_id = nil
    pending_target_time = 0
    engage_sent_target_id = nil
    combat_lock_time = nil
    combat_started = false
end
-- EXACT TARGET SELECTION
function Select_Target(mob)
    if not mob
        or not mob.id
        or not mob.index
    then
        return false
    end
    if combat_locked_target_id then
        if combat_locked_target_id == mob.id then
            return true
        end
        Debug.Target(
            'BLOCKED SELECT - COMBAT LOCK',
            mob
        )
        return false
    end
    local player =
        windower.ffxi.get_player()
    if not player then
        return false
    end
    Debug.Target(
        'SELECT',
        mob
    )
    Debug.State(
        'BEFORE SELECT'
    )
    pending_target_id = mob.id
    pending_target_time = os.clock()
    -- /target by name is the real, reliable way to set <t> -- it's
    -- what every other targeting call site in this file already uses
    -- (//lazy target, //lazy fight, Target_Monitor, Engagement_Sync).
    -- The previous approach here -- injecting a fake *incoming* 0x058
    -- packet -- doesn't reliably set the client's actual current
    -- target, since target selection is local client state, not
    -- something driven by an incoming server packet. That's almost
    -- certainly why engagement failed intermittently: Confirm_Target
    -- would time out waiting for a <t> the injected packet never
    -- actually produced.
    windower.send_command(
        'input /target "' .. mob.name .. '"'
    )
    return true
end
confirm_fail_count = confirm_fail_count or {}
local CONFIRM_FAIL_LIMIT = 2 -- consecutive timeouts before giving up on this mob

function Confirm_Target()
    if not pending_target_id then
        return nil
    end
    local target =
        windower.ffxi.get_mob_by_target('t')
    if target
        and target.id == pending_target_id
    then
        Debug.Target(
            'CONFIRM TARGET',
            target
        )
        Debug.State(
            'AFTER TARGET CONFIRM'
        )
        confirm_fail_count[pending_target_id] = nil
        pending_target_id = nil
        pending_target_time = 0
        return target
    end
    if
        os.clock() - pending_target_time
            >= TARGET_SELECT_TIMEOUT
    then
        Debug.State(
            'TARGET CONFIRM TIMEOUT'
        )
        -- /target "name" grabs the nearest mob with that name, with no
        -- way to specify a particular instance. If a nearer same-named
        -- mob (one claimed by someone else, say) keeps winning the pick
        -- instead of the one we actually chose, <t> never matches
        -- pending_target_id and this times out every time. A single
        -- timeout is normal jitter; repeated ones mean by-name
        -- selection genuinely can't reach this specific mob right now
        -- -- bench it and drop managed_target_id too, so Choose_Target
        -- picks something else next tick instead of retrying the same
        -- doomed selection forever.
        local failed_id = pending_target_id
        confirm_fail_count[failed_id] =
            (confirm_fail_count[failed_id] or 0) + 1
        if confirm_fail_count[failed_id] >= CONFIRM_FAIL_LIMIT then
            Debug.Log(
                '>>> GIVING UP ON TARGET (by-name select unreliable) <<< target=' ..
                tostring(failed_id)
            )
            unattackable_until[failed_id] = os.clock() + 20
            confirm_fail_count[failed_id] = nil
            managed_target_id = nil
        end
        pending_target_id = nil
        pending_target_time = 0
    end
    return nil
end
-- NORMAL FFXI ENGAGE
function Engage_Target(mob)
    if Debug.enabled then
        local current =
            windower.ffxi.get_mob_by_target('t')
        local player =
            windower.ffxi.get_player()
        Debug.Log(
            string.format(
                '>>> Engage_Target CALLED <<< requested=%s id=%s <t>=%s status=%s managed=%s locked=%s engage_sent=%s combat_started=%s',
                tostring(
                    mob and mob.name
                ),
                tostring(
                    mob and mob.id
                ),
                tostring(
                    current and current.id
                ),
                tostring(
                    player and player.status
                ),
                tostring(managed_target_id),
                tostring(combat_locked_target_id),
                tostring(engage_sent_target_id),
                tostring(combat_started)
            )
        )
    end
    -- INVALID
    if not mob
        or not mob.id
    then
        Debug.Log(
            'ENGAGE FAILED - INVALID TARGET'
        )
        return false
    end
    -- NEVER engage a player-owned pet or Luopan.
    if Is_Player_Pet(mob) then
        Debug.Target('ENGAGE BLOCKED - PLAYER PET/LUPON', mob)
        return false
    end
    -- COMBAT ALREADY LOCKED
    if combat_locked_target_id then
        if combat_locked_target_id == mob.id then
            Debug.State(
                'ENGAGE IGNORED - ALREADY LOCKED'
            )
            return true
        end
        Debug.Target(
            'ENGAGE BLOCKED - DIFFERENT COMBAT LOCK',
            mob
        )
        return false
    end
    local player =
        windower.ffxi.get_player()
    if not player then
        return false
    end
    -- PLAYER ALREADY ENGAGED
    if player.status == 1 then
        Debug.State(
            'ENGAGE BLOCKED - PLAYER ALREADY ENGAGED'
        )
        return false
    end
    -- EXACT <t> CHECK
    local target =
        windower.ffxi.get_mob_by_target('t')
    if not target
        or target.id ~= mob.id
    then
        Debug.Log(
            string.format(
                'TARGET MISMATCH requested=%s actual=%s -- RESELECTING',
                tostring(mob.id),
                tostring(
                    target and target.id
                )
            )
        )
        Select_Target(mob)
        return false
    end
    -- AUTO ENGAGE DISABLED
    if active_profile
        and active_profile.auto_engage == false
    then
        pending_target_id = nil
        pending_target_time = 0
        windower.ffxi.follow(0)
        Debug.State(
            'AUTO ENGAGE DISABLED'
        )
        return true
    end
    -- UNATTACKABLE
    if Is_Unattackable(mob.id) then
        Debug.Target(
            'BLOCKED - MARKED UNATTACKABLE',
            mob
        )
        return false
    end
    -- CLAIMED BY SOMEONE ELSE
    -- Belt-and-suspenders: the managed-target loop already drops a
    -- target the moment someone else's claim shows up, but check again
    -- here too in case a claim landed in the gap between that check and
    -- this call -- never commit the combat lock to a fight that was
    -- never ours.
    if mob.claim_id ~= 0
        and mob.claim_id ~= player.id
        and not Get_Party_Claim_Ids()[mob.claim_id]
    then
        Debug.Target(
            'ENGAGE BLOCKED - CLAIMED BY SOMEONE ELSE',
            mob
        )
        return false
    end
    -- COMMIT COMBAT
    combat_locked_target_id = mob.id
    managed_target_id = mob.id
    engage_sent_target_id = mob.id
    combat_lock_time = os.clock()
    combat_started = false
    pending_target_id = nil
    pending_target_time = 0
    windower.ffxi.follow(0)
    -- FINAL TARGET SNAPSHOT
    local final_target =
        windower.ffxi.get_mob_by_target('t')
    Debug.Target(
        'FINAL MANAGED MOB',
        mob
    )
    Debug.Target(
        'FINAL <t> BEFORE ATTACK',
        final_target
    )
    -- SEND /ATTACK ON EXACTLY ONCE
    Debug.Log(
        string.format(
            '>>> SENDING /attack on <<< name=%s id=%s index=%s hpp=%s claim=%s dist=%s status=%s managed=%s locked=%s engage_sent=%s <t>=%s',
            tostring(mob.name),
            tostring(mob.id),
            tostring(mob.index),
            tostring(mob.hpp),
            tostring(mob.claim_id),
            mob.distance
                and string.format(
                    '%.2f',
                    math.sqrt(mob.distance)
                )
                or 'nil',
            tostring(player.status),
            tostring(managed_target_id),
            tostring(combat_locked_target_id),
            tostring(engage_sent_target_id),
            tostring(
                final_target
                and final_target.id
            )
        )
    )
    windower.send_command(
        'input /attack on'
    )
    -- LOCK CAMERA ONCE
    if not lockon_done then
        windower.send_command(
            'input /lockon'
        )
        lockon_done = true
    end
    return true
end
-- RANGE
local MELEE_ENGAGE_RANGE = 3
local FOLLOW_CAST_RANGE = 20
function Stop_Range(mob)
    local rp =
        active_profile
        and active_profile.ranged_pull
    if rp
        and mob
        and mob.claim_id == 0
    then
        return rp.range or 20
    end
    if rp
        and mob
        and mob.claim_id ~= 0
    then
        return
            rp.engage_distance
            or MELEE_ENGAGE_RANGE
    end
    if active_profile
        and active_profile.engage_distance
    then
        return active_profile.engage_distance
    end
    if active_profile
        and active_profile.auto_engage == false
    then
        return FOLLOW_CAST_RANGE
    end
    return MELEE_ENGAGE_RANGE
end
function Follow_Monitor()
    while Start_Engine do
        if combat_locked_target_id then
            local target = windower.ffxi.get_mob_by_id(combat_locked_target_id)
            if target and target.valid_target then
                -- Same Stop_Range() everything else in this file uses,
                -- not a separate hardcoded distance -- a job with its
                -- own engage_distance (THF's ranged-pull setup, say)
                -- was getting dragged back to a flat 3 yalms the moment
                -- it locked onto something, ignoring that override.
                -- This is also what actually re-chases a target that
                -- runs off (e.g. hate switching to a ranged party
                -- member) once combat is already locked in.
                local distance = target.distance and math.sqrt(target.distance)
                local stop_range = Stop_Range(target)
                if distance and distance > stop_range then
                    windower.ffxi.follow(target.index)
                else
                    windower.ffxi.follow(0)
                end
            else
                windower.ffxi.follow(0)
            end
        elseif is_resting then
            windower.ffxi.follow(0)
        elseif isCasting or isBusy > 0 then
            windower.ffxi.follow(0)
        else
            local target = windower.ffxi.get_mob_by_target('t')
            if not target then
                windower.ffxi.follow(0)
            elseif managed_target_id and target.id ~= managed_target_id then
                Debug.Target('FOLLOW MONITOR DIFFERENT <t>', target)
                local mob = windower.ffxi.get_mob_by_id(managed_target_id)
                if mob and mob.valid_target then
                    Select_Target(mob)
                    windower.ffxi.follow(0)
                else
                    windower.ffxi.follow(0)
                end
            else
                local distance = target.distance and math.sqrt(target.distance)
                local stop_range = Stop_Range(target)
                if distance and distance <= stop_range then
                    windower.ffxi.follow(0)
                else
                    windower.ffxi.follow(target.index)
                end
            end
        end
        coroutine.sleep(0.2)
    end
end
-- COMBAT DAMAGE WATCH
last_party_damage_to_target = nil
damage_watch_target_id = nil
party_activity = {}
last_self_hit_on_current_target = nil
windower.register_event(
    'incoming chunk',
    function(id, data)
        if id ~= 0x028 then
            return
        end
        local action =
            packets.parse(
                'incoming',
                data
            )
        local player =
            windower.ffxi.get_player()
        if not player then
            return
        end
        local current =
            windower.ffxi.get_mob_by_target('t')
        local current_id =
            current and current.id
        if damage_watch_target_id ~= current_id then
            damage_watch_target_id = current_id
            last_party_damage_to_target =
                current_id
                and os.clock()
                or nil
            last_self_hit_on_current_target =
                current_id
                and os.clock()
                or nil
        end
        local is_self =
            action.Actor == player.id
        local is_party =
            is_self
            or Is_Party_Member(
                action.Actor
            )
        if not is_party then
            return
        end
        local target_count =
            action['Target Count']
            or 1
        for t = 1, target_count do
            local tid =
                action[
                    'Target ' ..
                    t ..
                    ' ID'
                ]
            if
                tid
                and action[
                    'Target ' ..
                    t ..
                    ' Action 1 Reaction'
                ] == 0
            then
                if tid == current_id then
                    last_party_damage_to_target =
                        os.clock()
                    if is_self then
                        last_self_hit_on_current_target =
                            os.clock()
                    end
                end
                if not is_self then
                    party_activity[
                        action.Actor
                    ] = {
                        last_hit = os.clock(),
                        target_id = tid,
                    }
                end
                break
            end
        end
    end
)
-- COMBAT STALL MONITOR
function Combat_Stall_Monitor()
    while Start_Engine do
        coroutine.sleep(5)
    end
end
-- ENGAGEMENT SYNC
function Engagement_Sync()
    while Start_Engine do
        coroutine.sleep(2)
    end
end
-- TARGET MONITOR
function Target_Monitor()
    while Start_Engine do
        local player =
            windower.ffxi.get_player()
        local target =
            windower.ffxi.get_mob_by_target('t')
        local target_id =
            target and target.id
        Debug.Target_Changed(target)
        -- COMBAT LOCK OWNS EVERYTHING
        if combat_locked_target_id then
            pending_target_id = nil
            pending_target_time = 0
            -- FFXI has actually entered combat.
            if player
                and player.status == 1
            then
                if not combat_started then
                    Debug.Log(
                        '>>> COMBAT STARTED <<< target=' ..
                        tostring(
                            combat_locked_target_id
                        )
                    )
                end
                combat_started = true
            -- Combat was previously active and has now
            -- ended. This is the ONLY normal path that
            -- releases the combat lock.
            elseif combat_started then
                Debug.Log(
                    '>>> COMBAT ENDED <<< target=' ..
                    tostring(
                        combat_locked_target_id
                    )
                )
                Clear_Combat_Target()
            else
                -- Pre-engage lock that never actually reached combat.
                -- If the target died, despawned, or otherwise vanished
                -- before we got there, nothing was releasing this --
                -- Targeting()/Follow_Monitor just quietly idled on it
                -- forever, which is the "staring into space" freeze.
                local locked =
                    windower.ffxi.get_mob_by_id(
                        combat_locked_target_id
                    )
                if not locked
                    or not locked.valid_target
                    or not locked.hpp
                    or locked.hpp <= 0
                then
                    Debug.Log(
                        '>>> PRE-ENGAGE TARGET LOST <<< target=' ..
                        tostring(
                            combat_locked_target_id
                        )
                    )
                    Clear_Combat_Target()
                end
            end
            coroutine.sleep(0.1)
        -- ALREADY ENGAGED WITHOUT OUR LOCK
        elseif player
            and player.status == 1
        then
            if target
                and target.id
            then
                managed_target_id =
                    target.id
                combat_locked_target_id =
                    target.id
                engage_sent_target_id =
                    target.id
                combat_lock_time = nil
                combat_started = true
                pending_target_id = nil
                pending_target_time = 0
                Debug.Target(
                    'ADOPTING EXISTING COMBAT TARGET',
                    target
                )
            end
        -- MANAGED TARGET OUTSIDE COMBAT
        elseif managed_target_id then
            if not target
                or target.id ~= managed_target_id
            then
                local mob =
                    windower.ffxi.get_mob_by_id(
                        managed_target_id
                    )
                if mob
                    and mob.valid_target
                then
                    Debug.Target(
                        'TARGET MONITOR RESELECT',
                        mob
                    )
                    Select_Target(mob)
                end
            end
        end
        coroutine.sleep(0.1)
    end
end
-- MAIN TARGETING LOOP
function Targeting()
    while Start_Engine do
        local player =
            windower.ffxi.get_player()
        if player then
            -- COMBAT LOCK
            if combat_locked_target_id then
                pending_target_id = nil
                pending_target_time = 0
                -- Follow_Monitor owns movement for the locked target.
            -- RESTING
            elseif is_resting then
                windower.ffxi.follow(0)
            -- PLAYER ALREADY ENGAGED
            elseif player.status == 1 then
                local target =
                    windower.ffxi.get_mob_by_target('t')
                if target
                    and target.id
                then
                    managed_target_id =
                        target.id
                    combat_locked_target_id =
                        target.id
                    engage_sent_target_id =
                        target.id
                    combat_lock_time = nil
                    combat_started = true
                    pending_target_id = nil
                    pending_target_time = 0
                    Debug.Target(
                        'PLAYER ALREADY ENGAGED - LOCKING',
                        target
                    )
                    Debug.State(
                        'EXISTING COMBAT LOCK'
                    )
                end
                windower.ffxi.follow(0)
            -- WAITING FOR TARGET SELECTION
            elseif pending_target_id then
                local confirmed =
                    Confirm_Target()
                if confirmed then
                    local distance =
                        confirmed.distance
                        and math.sqrt(
                            confirmed.distance
                        )
                    local stop_range =
                        Stop_Range(confirmed)
                    Debug.Target(
                        'CONFIRMED TARGET WAITING FOR RANGE',
                        confirmed
                    )
                    -- STILL TOO FAR AWAY:
                    -- FOLLOW THE CONFIRMED TARGET.
                    if distance
                        and distance > stop_range
                    then
                        Debug.Target(
                            'CONFIRMED TARGET OUT OF RANGE - FOLLOWING',
                            confirmed
                        )
                        windower.ffxi.follow(
                            confirmed.index
                        )
                    -- IN RANGE:
                    -- stop following and engage.
                    elseif distance
                        and distance <= stop_range
                    then
                        windower.ffxi.follow(0)
                        Debug.Target(
                            'CONFIRMED TARGET IN ENGAGE RANGE',
                            confirmed
                        )
                        Engage_Target(
                            confirmed
                        )
                    -- Distance unavailable:
                    -- use the confirmed target rather than
                    -- getting stuck forever.
                    else
                        Debug.Target(
                            'CONFIRMED TARGET HAS NO DISTANCE - ENGAGING',
                            confirmed
                        )
                        windower.ffxi.follow(0)
                        Engage_Target(
                            confirmed
                        )
                    end
                end
            -- EXISTING MANAGED TARGET
            elseif managed_target_id then
                local target =
                    windower.ffxi.get_mob_by_target('t')
                if not target
                    or target.id ~= managed_target_id
                then
                    local mob =
                        windower.ffxi.get_mob_by_id(
                            managed_target_id
                        )
                    if mob
                        and mob.valid_target
                    then
                        Debug.Target(
                            'MAIN LOOP RESELECT',
                            mob
                        )
                        Select_Target(mob)
                    else
                        Debug.State(
                            'MANAGED TARGET DEAD/GONE'
                        )
                        managed_target_id = nil
                        pending_target_id = nil
                        pending_target_time = 0
                        engage_sent_target_id = nil
                        combat_lock_time = nil
                        combat_started = false
                    end
                elseif target.claim_id ~= 0
                    and target.claim_id ~= player.id
                    and not Get_Party_Claim_Ids()[target.claim_id]
                then
                    -- Someone else claimed it. Waiting for FFXI's
                    -- "cannot attack" message only catches this once
                    -- we're already in range trying to attack -- from
                    -- any further out, Lazy just sat there following
                    -- a fight that was never going to be ours, right
                    -- up until it died to someone else. Drop it now
                    -- and let the next tick pick something else.
                    Debug.Target(
                        'MANAGED TARGET CLAIMED BY SOMEONE ELSE',
                        target
                    )
                    managed_target_id = nil
                    pending_target_id = nil
                    pending_target_time = 0
                    engage_sent_target_id = nil
                    combat_lock_time = nil
                    combat_started = false
                    windower.ffxi.follow(0)
                else
                    local distance =
                        target.distance
                        and math.sqrt(
                            target.distance
                        )
                    local stop_range =
                        Stop_Range(target)
                    -- OUT OF RANGE:
                    -- FOLLOW THE TARGET.
                    if distance
                        and distance > stop_range
                    then
                        Debug.Target(
                            'MANAGED TARGET OUT OF RANGE - FOLLOWING',
                            target
                        )
                        windower.ffxi.follow(
                            target.index
                        )
                    -- IN RANGE:
                    -- stop following and engage.
                    elseif distance
                        and distance <= stop_range
                    then
                        windower.ffxi.follow(0)
                        Engage_Target(
                            target
                        )
                    -- No distance:
                    -- engage rather than becoming stuck.
                    else
                        windower.ffxi.follow(0)
                        Engage_Target(
                            target
                        )
                    end
                end
            -- ASSIST MODE
            elseif settings.assist ~= '' then
                windower.send_command(
                    'input /assist ' ..
                    settings.assist
                )
                local target =
                    windower.ffxi.get_mob_by_target('t')
                Debug.Target(
                    'ASSIST TARGET',
                    target
                )
                if target
                    and not Is_Player_Pet(target)
                    and target.valid_target
                    and target.hpp
                    and target.hpp > 0
                then
                    managed_target_id =
                        target.id
                    engage_sent_target_id = nil
                    if target.distance
                        and math.sqrt(
                            target.distance
                        ) <= Stop_Range(target)
                    then
                        Engage_Target(target)
                    else
                        windower.ffxi.follow(
                            target.index
                        )
                    end
                end
                if not lockon_done
                    and active_profile.auto_engage ~= false
                then
                    windower.send_command(
                        'input /lockon'
                    )
                    lockon_done = true
                end
            -- AUTOTARGET
            elseif settings.autotarget then
                local target_id
                local expected_name =
                    (
                        settings.target
                        and settings.target ~= ''
                    )
                    and settings.target
                    or nil
                local party_ids =
                    Get_Party_Claim_Ids()
                if expected_name then
                    target_id =
                        Find_Named_Target(
                            settings.target
                        )
                else
                    target_id =
                        Choose_Target(
                            party_ids
                        )
                end
                if target_id <= 0 then
                    Path_To_Origin()
                else
                    local mob =
                        windower.ffxi.get_mob_by_index(
                            target_id
                        )
                    if mob
                        and Is_Legitimate_Target(
                            mob,
                            expected_name,
                            party_ids,
                            false
                        )
                    then
                        pathing_to_origin = false
                        path_tick = 0
                        managed_target_id =
                            mob.id
                        pending_target_id = nil
                        pending_target_time = 0
                        engage_sent_target_id = nil
                        combat_lock_time = nil
                        combat_started = false
                        Debug.Target(
                            'AUTOTARGET CHOSE',
                            mob
                        )
                        Debug.State(
                            'AFTER AUTOTARGET'
                        )
                        local distance =
                            mob.distance
                            and math.sqrt(mob.distance)
                        if not Try_Ranged_Pull(
                            mob,
                            distance
                        ) then
                            Select_Target(mob)
                        end
                    else
                        Path_To_Origin()
                    end
                end
            end
        end
        coroutine.sleep(0.5)
    end
end