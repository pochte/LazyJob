require('chat')
require('logger')
require('tables')
config = require('config')
res = require('resources')
packets = require('packets')
 
-- MODULES & FALLBACK DEFINITIONS 

dofile(windower.addon_path .. 'skillchain.lua')
dofile(windower.addon_path .. 'magicburst.lua')
dofile(windower.addon_path .. 'settings.lua')

-- Fallback structures to prevent nil comparison errors
ws_sc_starter = ws_sc_starter or {}
ws_sc_closers = ws_sc_closers or {}
needed_buffs = needed_buffs or {}
food = food or nil
spell_blacklist = spell_blacklist or {}
haste_blacklist = haste_blacklist or {}
dispel_whitelist = dispel_whitelist or {}
subjob_abilities = subjob_abilities or {}
haste_samba_active = haste_samba_active or false

targeting = targeting or {
    monsters = {},
    only_alive = true,
    within_origin = true,
    only_unclaimed = true,
}
 
-- ADDON 

_addon.name = 'lazy'
_addon.author = 'Ulli'
_addon.version = '0.9'
_addon.commands = {'lazy'}
 
-- GLOBAL STATE 

Start_Engine = false
isCasting = false
isBusy = 0
buffactive = {}
Action_Delay = 2
 
-- MOVEMENT / POSITION 

local origin_x = nil
local origin_y = nil
local origin_z = nil
local origin_radius = 15
local origin_z_tolerance = 15
local pathing_to_origin = false
local path_tick = 0
local last_known_pos = nil
local move_threshold = 0.05

local path_last_distance = nil
local path_last_progress_time = nil
local path_stuck_alerted = false
local PATH_STUCK_TIMEOUT = 8
local PATH_STUCK_EPSILON = 1

local origin_unreachable_since = nil
local ORIGIN_UNREACHABLE_TIMEOUT = 600
 
-- COMBAT STATE 

local trust_ws_countdown = 0
local lockon_done = false
local ws_index = 1
local PlayerH = 0
local engaged_since = nil

-- DNC: set true whenever any weaponskill fires (Combat's starter/closer,
-- or SC_Monitor's closer), so Try_DNC_Actions knows to fire Reverse
-- Flourish right after -- consulted only when current_job == 'DNC'.
local dnc_flourish_pending = false

local DNC_WALTZ_TIERS = {
    'Curing Waltz V',
    'Curing Waltz IV',
    'Curing Waltz III',
    'Curing Waltz II',
    'Curing Waltz',
}
 
-- CAST TRACKING 

local self_buff_last_cast = {}
local self_ability_last_cast = {}
local haste_last_cast = {}
local debuff_last_cast = {}
local dispel_last_cast = {}
local mob_spell_last_cast = {}
local refresh_last_cast = {}
local party_buff_last_cast = {}
local entrust_last_cast = {}
local pending_cast = nil
 
-- JOB STATE 

current_job = nil
active_profile = nil
 
-- JOB PROFILES 

JOB_PROFILES = {}

local profile_list = {
    'RDM', 'GEO', 'BLM', 'SCH', 'DNC',
    'NIN', 'WHM', 'WAR', 'THF', 'COR', 'BRD', 'DEFAULT'
}

for _, job in ipairs(profile_list) do
    local path = windower.addon_path .. 'profiles/' .. job .. '.lua'
    local f = io.open(path, 'r')
    if f then
        f:close()
        local ok, err = pcall(dofile, path)
        if not ok then
            windower.add_to_chat(167, '[Lazy] ERROR loading ' .. job .. '.lua: ' .. tostring(err))
            windower.add_to_chat(167, '[Lazy] ' .. job .. ' profile NOT loaded -- fix the syntax error above and //lua reload lazy')
        end
    else
        windower.add_to_chat(123, '[Lazy] Profile not found: ' .. job .. '.lua → using DEFAULT')
    end
end

JOB_PROFILES.DEFAULT = JOB_PROFILES.DEFAULT or {}
active_profile = JOB_PROFILES.DEFAULT
 
-- BACKLINE & DISENGAGE OVERRIDES 

local function Enforce_Backline_Rules()
    local player = windower.ffxi.get_player()
    if not player or not active_profile then return end

    if player.status == 1 and active_profile.auto_engage == false then
        windower.send_command('input /attack off')
    end
end

local function Ensure_Debuff_Target()
    local player = windower.ffxi.get_player()
    if not player or not active_profile then return end

    if (active_profile.debuffs or active_profile.magic_burst)
       and active_profile.auto_engage == false
       and not windower.ffxi.get_mob_by_target('t') then
        windower.send_command('input /target <p1>; wait 0.2; input /target <bt>')
    end
end
 
-- MOVEMENT DETECTION 

function Is_Moving()
    local player = windower.ffxi.get_player()
    if not player then return false end

    local mob = windower.ffxi.get_mob_by_id(player.id)
    if not mob then return false end

    local moving = false
    if last_known_pos then
        local dx = mob.x - last_known_pos.x
        local dy = mob.y - last_known_pos.y
        if (dx*dx + dy*dy) > (move_threshold * move_threshold) then
            moving = true
        end
    end

    last_known_pos = { x = mob.x, y = mob.y }
    return moving
end
 
-- JOB PROFILE 

function Update_Job_Profile()
    local player = windower.ffxi.get_player()
    if not player or not player.main_job then return end

    local job = player.main_job
    if job == current_job then return end

    current_job = job
    active_profile = JOB_PROFILES[job] or JOB_PROFILES.DEFAULT

    self_buff_last_cast = {}
    self_ability_last_cast = {}
    haste_last_cast = {}
    debuff_last_cast = {}
    dispel_last_cast = {}
    mob_spell_last_cast = {}
    refresh_last_cast = {}
    party_buff_last_cast = {}
    entrust_last_cast = {}

    windower.add_to_chat(2, '[Lazy] Main job: ' .. job)
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
 
-- SETTINGS 

defaults = {
    spell = '',
    spell_active = false,
    weaponskill = '',
    weaponskill_active = false,
    autotarget = false,
    target = '',
    assist = '',
    buffs_active = true,
    cure_active = true,
}

settings = config.load(defaults)
 
-- INCOMING PACKETS 

windower.register_event('incoming chunk', function(id, data)
    if id ~= 0x028 then return end

    local action = packets.parse('incoming', data)
    local player = windower.ffxi.get_player()
    if not player or action.Actor ~= player.id then return end

    if action.Category == 4 then
        isCasting = false
        if pending_cast then
            local matches = action.Param == pending_cast.spell_id
            local reaction = action['Target 1 Action 1 Reaction']
            if matches and reaction == 0 then
                pending_cast.store[pending_cast.key] = pending_cast.sent_at
            end
            pending_cast = nil
        end
    elseif action.Category == 8 then
        isCasting = true
        if action['Target 1 Action 1 Message'] == 0 then
            isCasting = false
            isBusy = Action_Delay
            pending_cast = nil
        end
    elseif action.Category == 11 then
        trust_ws_countdown = 5
    end
end)
 
-- DEATH WATCH 

local last_damage_source = nil
local last_damage_source_id = nil
local last_damage_kind = nil
local death_reported = false

-- Aggro queue: ids of things that have hit us that AREN'T our current
-- <t>. Adds go on the end as they hit us; we don't touch them while our
-- current target is still alive -- finish that fight first, then work
-- through whoever else started swinging on us, oldest first.
local aggro_queue = {}
local AGGRO_QUEUE_CAP = 10

local function Resolve_Attack_Name(param)
    if not param or param == 0 then return nil end
    local hit =
        res.monster_abilities[param]
        or res.spells[param]
        or res.weapon_skills[param]
        or res.job_abilities[param]
    return hit and hit.en or nil
end

windower.register_event('incoming chunk', function(id, data)
    if id ~= 0x028 then return end

    local action = packets.parse('incoming', data)
    local player = windower.ffxi.get_player()
    if not player then return end

    local current = windower.ffxi.get_mob_by_target('t')
    local current_id = current and current.id

    local target_count = action['Target Count'] or 1

    for t = 1, target_count do
        if action['Target ' .. t .. ' ID'] == player.id then
            local reaction = action['Target ' .. t .. ' Action 1 Reaction']

            if reaction == 0 then
                local actor_id = action.Actor
                local actor = windower.ffxi.get_mob_by_id(actor_id)

                last_damage_source = actor and actor.name or last_damage_source or 'something unseen'
                last_damage_source_id = actor_id
                last_damage_kind = Resolve_Attack_Name(action.Param)

                if actor_id and actor_id ~= current_id then
                    local already_queued = false
                    for _, qid in ipairs(aggro_queue) do
                        if qid == actor_id then
                            already_queued = true
                            break
                        end
                    end
                    if not already_queued then
                        aggro_queue[#aggro_queue + 1] = actor_id
                        if #aggro_queue > AGGRO_QUEUE_CAP then
                            table.remove(aggro_queue, 1)
                        end
                    end
                end
            end

            break
        end
    end
end)

-- COMBAT STALL / ASSIST WATCH
--
-- Tracks who's actually landing hits, separate from the death-watch
-- tracker above (which is about damage taken, not dealt). Two trackers:
--   last_party_damage_to_target -- last time ANYONE (us or party)
--     landed a hit on our current <t>. If this goes 20s with no hits
--     at all, the fight's stalled -- nothing's dying, drop it and let
--     normal targeting pick something else.
--   last_self_damage_to_target -- last time WE landed a hit on our
--     current <t>, specifically. If we're whiffing for 20s while a
--     party member is actively landing hits on something else, jump
--     over and help them with that one mob, then revert once it dies.
-- party_activity tracks the latter half: who in the party hit what,
-- and when, regardless of what our own target is.
local last_party_damage_to_target = nil
local last_self_damage_to_target  = nil
local damage_watch_target_id      = nil
local party_activity              = {}  -- [actor_id] = {last_hit = os.clock(), target_id = mob id}
local temp_assist_mob_id          = nil -- non-nil while temporarily helping someone else's fight

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
        last_self_damage_to_target  = current_id and os.clock() or nil
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
                if is_self then last_self_damage_to_target = os.clock() end
            end
            if not is_self then
                party_activity[action.Actor] = {last_hit = os.clock(), target_id = tid}
            end
            break
        end
    end
end)

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

            elseif last_self_damage_to_target and now - last_self_damage_to_target >= 20 then
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

function Death_Monitor()
    while Start_Engine do
        local player = windower.ffxi.get_player()

        if player and player.vitals and player.vitals.hp and player.vitals.hp <= 0 then
            if not death_reported then
                death_reported = true

                local cause = last_damage_source or 'unknown causes'
                if last_damage_kind then
                    cause = cause .. ' (' .. last_damage_kind .. ')'
                elseif last_damage_source then
                    cause = cause .. ' (melee)'
                end

                windower.add_to_chat(167, '[Lazy] You died -- killed by ' .. cause .. '. Stopping Lazy.')
                Start_Engine = false
            end
        else
            death_reported = false
        end

        coroutine.sleep(0.5)
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
                    end
                end
            end
        end

        coroutine.sleep(10)
    end
end
 
-- OUTGOING PACKETS 

windower.register_event('outgoing chunk', function(id, data)
    if id ~= 0x015 then return end
    local action = packets.parse('outgoing', data)
    PlayerH = action.Rotation
end)
 
-- STATUS CHANGE LISTENERS 

windower.register_event('status change', function(new_status_id)
    if new_status_id == 1 then -- Engaged
        Enforce_Backline_Rules()
    end
end)
 
-- COMMANDS 

windower.register_event('addon command', function(...)
    local raw_args = {...}
    local args = {}
    for i, v in ipairs(raw_args) do
        args[i] = string.lower(tostring(v))
    end
    local command = args[1]

    if not command or command == 'help' then
        print('Lazy commands:')
        print('//lazy start')
        print('//lazy stop')
        print('//lazy reload')
        print('//lazy save')
        print('//lazy show')
        print('//lazy autotarget on/off')
        print('//lazy target <name>')
        print('//lazy assist <player>')
        print('//lazy buffs on/off')
        print('//lazy cure on/off')
        print('//lazy range <yalms>')
        print('//lazy retrust')
        return
    end

    if command == 'start' then
        local player = windower.ffxi.get_player()
        if player and player.vitals and player.vitals.hp and player.vitals.hp <= 0 then
            windower.add_to_chat(167, '[Lazy] You are dead. Stop being a floor decoration, then //lazy start again.')
            return
        end

        windower.add_to_chat(2, '....Starting Lazy Helper....')
        Set_Origin()
        if Start_Engine then return end

        Start_Engine = true
        self_buff_last_cast = {}
        self_ability_last_cast = {}
        haste_last_cast = {}
        debuff_last_cast = {}
        refresh_last_cast = {}
        party_buff_last_cast = {}
        entrust_last_cast = {}
        path_last_distance = nil
        path_last_progress_time = nil
        path_stuck_alerted = false
        origin_unreachable_since = nil
        last_damage_source = nil
        last_damage_source_id = nil
        last_damage_kind = nil
        death_reported = false
        aggro_queue = {}
        last_party_damage_to_target = nil
        last_self_damage_to_target = nil
        damage_watch_target_id = nil
        party_activity = {}
        temp_assist_mob_id = nil
        autotarget_was_off = false

        Update_Job_Profile()
        Snapshot_Trusts()

        coroutine.schedule(Engine, 0)
        coroutine.schedule(SC_Monitor, 0)
        coroutine.schedule(Target_Monitor, 0)
        coroutine.schedule(Targeting, 0)
        coroutine.schedule(Follow_Monitor, 0)
        coroutine.schedule(Buff_Monitor, 0)
        coroutine.schedule(Cure_Monitor, 0)
        coroutine.schedule(Trust_Monitor, 0)
        coroutine.schedule(Death_Monitor, 0)
        coroutine.schedule(Engagement_Sync, 0)
        coroutine.schedule(Combat_Stall_Monitor, 0)
        return
    end

    if command == 'stop' then
        windower.add_to_chat(2, '....Stopping Lazy Helper....')
        Start_Engine = false
        return
    end

    if command == 'reload' then
        windower.add_to_chat(2, '....Reloading Config....')
        config.reload(settings)
        dofile(windower.addon_path .. 'settings.lua')
        return
    end

    if command == 'save' then
        local player = windower.ffxi.get_player()
        if player then config.save(settings, player.name) end
        return
    end

    if command == 'show' then
        Update_Job_Profile()
        windower.add_to_chat(11, 'Main job: ' .. tostring(current_job))
        windower.add_to_chat(11, 'Assist: ' .. (settings.assist ~= '' and settings.assist or 'OFF'))
        windower.add_to_chat(11, 'Autotarget: ' .. tostring(settings.autotarget))
        windower.add_to_chat(11, 'Spell: ' .. settings.spell)
        windower.add_to_chat(11, 'Use Spell: ' .. tostring(settings.spell_active))
        windower.add_to_chat(11, 'Weaponskill: ' .. settings.weaponskill)
        windower.add_to_chat(11, 'Use Weaponskill:' .. tostring(settings.weaponskill_active))
        windower.add_to_chat(11, 'Target: ' .. settings.target)
        windower.add_to_chat(11, 'Buffs: ' .. tostring(settings.buffs_active))
        windower.add_to_chat(11, 'Cure Bot: ' .. tostring(settings.cure_active))
        return
    end

    if command == 'autotarget' then
        settings.autotarget = (args[2] == 'on')
        windower.add_to_chat(3, 'Autotarget: ' .. tostring(settings.autotarget))
        return
    end

    if command == 'target' then
        settings.target = args[2] or ''
        return
    end

    if command == 'assist' then
        settings.assist = args[2] or ''
        windower.add_to_chat(2, 'Assist: ' .. (settings.assist ~= '' and settings.assist or 'OFF'))

        if settings.assist ~= '' then
            windower.send_command('input /assist ' .. settings.assist)
            if active_profile and active_profile.auto_engage == false then
                windower.send_command('wait 0.4; input /attack off')
            end
        end
        return
    end

    if command == 'buffs' then
        settings.buffs_active = (args[2] ~= 'off')
        windower.add_to_chat(3, 'Buffs: ' .. tostring(settings.buffs_active))
        return
    end

    if command == 'cure' then
        settings.cure_active = (args[2] ~= 'off')
        windower.add_to_chat(3, 'Cure Bot: ' .. tostring(settings.cure_active))
        return
    end

    if command == 'range' then
        local value = tonumber(args[2])
        if value then
            origin_radius = value
            windower.add_to_chat(2, 'Origin radius set to ' .. origin_radius .. ' yalms')
        else
            windower.add_to_chat(2, 'Current radius: ' .. origin_radius)
        end
        return
    end

    if command == 'retrust' then
        Snapshot_Trusts()
        return
    end
end)
 
-- WEAPONSKILLS 

function Next_WS()
    local closers = Get_WS_Closers()
    if not closers or #closers == 0 then return nil end
    local ws = closers[ws_index]
    ws_index = (ws_index % #closers) + 1
    return ws
end
 
-- HEADING / MOVEMENT 

function HeadingTo(x, y)
    local player = windower.ffxi.get_mob_by_id(windower.ffxi.get_player().id)
    if not player then return 0 end
    local dx = x - player.x
    local dy = y - player.y
    return math.atan2(dx, dy) - 1.5708
end

function TurnToTarget()
    local target = windower.ffxi.get_mob_by_target('t')
    if not target then return end
    local desired = math.deg(HeadingTo(target.x, target.y))
    if math.abs(PlayerH - desired) > 10 then
        windower.ffxi.turn(HeadingTo(target.x, target.y))
    end
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

function Engine()
    while Start_Engine do
        local player = windower.ffxi.get_player()
        if player then
            Update_Job_Profile()
            Enforce_Backline_Rules()
            buffactive = convert_buff_list(player.buffs or {})
            if isBusy < 1 then
                pcall(Combat)
            else
                isBusy = isBusy - 1
            end
        end
        coroutine.sleep(1)
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

local autotarget_was_off = false

function Targeting()
    while Start_Engine do
        local player = windower.ffxi.get_player()

        -- STUPIDITY FIXER: autotarget getting left off (forgotten after
        -- testing, fat-fingered, whatever) means Lazy just sits there
        -- doing nothing forever with no other symptom. Force it back on
        -- unconditionally -- there's no legitimate reason to want it off
        -- while the addon's running. One chat line per incident, not
        -- spammed every tick.
        if not settings.autotarget then
            settings.autotarget = true
            if not autotarget_was_off then
                windower.add_to_chat(207, '[Lazy] Autotarget was off -- turned it back on.')
                autotarget_was_off = true
            end
        else
            autotarget_was_off = false
        end

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
 
-- COMBAT
-- DNC ROTATION
-- Priority:
--   1. Emergency Waltz at <=50% HP.
--   2. Reverse Flourish at 5 Finishing Moves or after a WS.
--   3. Box Step until 5 Finishing Moves.

function Try_DNC_Actions()
    local player = windower.ffxi.get_player()
    if not player or not player.vitals then return false end

    if player.vitals.hpp and player.vitals.hpp <= 50 then
        for _, waltz in ipairs(DNC_WALTZ_TIERS) do
            local ability = res.job_abilities:with('name', waltz)
            if ability and Can_Cast_Ability(waltz)
                and player.vitals.mp >= (ability.mp_cost or 0) then

                windower.add_to_chat(167, '[Lazy] Emergency Waltz -- ' .. waltz .. ' (' .. player.vitals.hpp .. '% HP)')
                Cast_Ability(waltz)
                return true
            end
        end
    end

    local target = windower.ffxi.get_mob_by_target('t')
    if not target or not target.distance or math.sqrt(target.distance) > 5 then
        return false
    end

    local stacks = buffactive['Finishing Move'] or 0

    if (stacks >= 5 or dnc_flourish_pending) and Can_Cast_Ability('Reverse Flourish') then
        windower.send_command('input /ja "Reverse Flourish" <me>')
        isBusy = Action_Delay
        dnc_flourish_pending = false
        return true
    end

    if stacks < 5 and Can_Cast_Ability('Box Step') then
        windower.send_command('input /ja "Box Step" <t>')
        isBusy = Action_Delay
        return true
    end

    return false
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
 
-- TRUST RESUMMON 

local tracked_trusts = {}
local trust_resummon_last = {}

function Snapshot_Trusts()
    tracked_trusts = {}
    local party = windower.ffxi.get_party()
    if not party then return end

    for _, key in ipairs({'p0','p1','p2','p3','p4','p5'}) do
        local m = party[key]
        if m and m.name and m.mob and m.mob.is_npc then
            tracked_trusts[#tracked_trusts + 1] = m.name
        end
    end

    if #tracked_trusts > 0 then
        windower.add_to_chat(2, '[Lazy] Tracking trusts for resummon: ' .. table.concat(tracked_trusts, ', '))
    end
end

function Trust_Tick()
    if #tracked_trusts == 0 then return end

    if pending_cast and os.clock() - pending_cast.sent_at > 10 then
        pending_cast = nil
    end
    if isBusy > 0 or isCasting or pending_cast then return end

    local party = windower.ffxi.get_party()
    if not party then return end

    local present = {}
    for _, key in ipairs({'p0','p1','p2','p3','p4','p5'}) do
        local m = party[key]
        if m and m.name and m.hp and m.hp > 0 then
            present[m.name] = true
        end
    end

    for _, name in ipairs(tracked_trusts) do
        if not present[name] then
            local spell = res.spells:with('name', name)
            if spell and Cast_Spell_On(name, '<me>') then
                pending_cast = {
                    store = trust_resummon_last,
                    key = name,
                    spell_id = spell.id,
                    sent_at = os.clock(),
                }
                windower.add_to_chat(2, '[Lazy] Resummoning trust: ' .. name)
                return
            end
        end
    end
end

function Trust_Monitor()
    while Start_Engine do
        pcall(Trust_Tick)
        coroutine.sleep(1)
    end
end
 
-- BUFF LIST CONVERTER 

function convert_buff_list(bufflist)
    local buffs = {}
    for _, buff_id in pairs(bufflist or {}) do
        local buff = res.buffs[buff_id]
        if buff then
            if buff.english then
                buffs[buff.english] = (buffs[buff.english] or 0) + 1
            end
            buffs[buff_id] = (buffs[buff_id] or 0) + 1
        end
    end
    return buffs
end
 
-- INIT 

Update_Job_Profile()