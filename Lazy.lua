require('chat')
require('logger')
require('tables')

config  = require('config')
res     = require('resources')
packets = require('packets')

------------------------------------------------------------
-- MODULES
------------------------------------------------------------

dofile(windower.addon_path .. 'skillchain.lua')
dofile(windower.addon_path .. 'magicburst.lua')
dofile(windower.addon_path .. 'settings.lua')

------------------------------------------------------------
-- ADDON
------------------------------------------------------------

_addon.name     = 'lazy'
_addon.author   = 'Ulli'
_addon.version  = '0.7'
_addon.commands = {'lazy'}

------------------------------------------------------------
-- GLOBAL STATE
------------------------------------------------------------

Start_Engine = false
isCasting    = false
isBusy       = 0
buffactive   = {}
Action_Delay = 2

------------------------------------------------------------
-- MOVEMENT / POSITION
------------------------------------------------------------

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

------------------------------------------------------------
-- COMBAT STATE
------------------------------------------------------------

local trust_ws_countdown = 0
local lockon_done = false
local ws_index = 1
local PlayerH = 0
local engaged_since = nil

------------------------------------------------------------
-- CAST TRACKING
------------------------------------------------------------

local self_buff_last_cast = {}
local self_ability_last_cast = {}
local haste_last_cast = {}
local debuff_last_cast = {}
local refresh_last_cast = {}
local party_buff_last_cast = {}

local pending_cast = nil

------------------------------------------------------------
-- JOB STATE
------------------------------------------------------------

current_job = nil
active_profile = nil

------------------------------------------------------------
-- JOB PROFILES
------------------------------------------------------------

JOB_PROFILES = {}

local profile_list = {
    'RDM', 'GEO', 'BLM', 'SCH', 'DNC',
    'NIN', 'WHM', 'WAR', 'THF', 'COR',
    'BRD', 'DEFAULT'
}

for _, job in ipairs(profile_list) do
    local path = windower.addon_path .. 'profiles/' .. job .. '.lua'
    local f = io.open(path, 'r')

    if f then
        f:close()

        local ok, err = pcall(dofile, path)

        if not ok then
            windower.add_to_chat(
                167,
                '[Lazy] ERROR loading ' .. job .. '.lua: ' .. tostring(err)
            )
            windower.add_to_chat(
                167,
                '[Lazy] ' .. job ..
                ' profile NOT loaded -- fix the syntax error above and //lua reload lazy'
            )
        end
    else
        windower.add_to_chat(
            123,
            '[Lazy] Profile not found: ' .. job .. '.lua → using DEFAULT'
        )
    end
end

active_profile = JOB_PROFILES.DEFAULT

------------------------------------------------------------
-- MOVEMENT DETECTION
------------------------------------------------------------

function Is_Moving()
    local player = windower.ffxi.get_player()
    if not player then return false end

    local mob = windower.ffxi.get_mob_by_id(player.id)
    if not mob then return false end

    local moving = false

    if last_known_pos then
        local dx = mob.x - last_known_pos.x
        local dy = mob.y - last_known_pos.y

        if (dx * dx + dy * dy) > (move_threshold * move_threshold) then
            moving = true
        end
    end

    last_known_pos = {x = mob.x, y = mob.y}
    return moving
end

------------------------------------------------------------
-- JOB PROFILE
------------------------------------------------------------

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
    refresh_last_cast = {}
    party_buff_last_cast = {}

    windower.add_to_chat(2, '[Lazy] Main job: ' .. job)
end

------------------------------------------------------------
-- PROFILE HELPERS
------------------------------------------------------------

function Get_WS_Starter()
    return active_profile.ws_sc_starter or ws_sc_starter
end

function Get_WS_Closers()
    return active_profile.ws_sc_closers or ws_sc_closers
end

function Get_Needed_Buffs()
    return active_profile.needed_buffs or needed_buffs
end

function Get_Food()
    return active_profile.food or food
end

------------------------------------------------------------
-- SETTINGS
------------------------------------------------------------

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

------------------------------------------------------------
-- INCOMING PACKETS
------------------------------------------------------------

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

------------------------------------------------------------
-- DEATH WATCH
------------------------------------------------------------

local last_damage_source = nil
local last_damage_kind = nil
local death_reported = false

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

    local target_count = action['Target Count'] or 1

    for t = 1, target_count do
        if action['Target ' .. t .. ' ID'] == player.id then
            local reaction =
                action['Target ' .. t .. ' Action 1 Reaction']

            if reaction == 0 then
                local actor = windower.ffxi.get_mob_by_id(action.Actor)

                last_damage_source =
                    actor and actor.name
                    or last_damage_source
                    or 'something unseen'

                last_damage_kind = Resolve_Attack_Name(action.Param)
            end

            break
        end
    end
end)

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

                windower.add_to_chat(
                    167,
                    '[Lazy] You died -- killed by ' .. cause ..
                    '. Stopping Lazy.'
                )

                Start_Engine = false
            end
        else
            death_reported = false
        end

        coroutine.sleep(0.5)
    end
end

------------------------------------------------------------
-- OUTGOING PACKETS
------------------------------------------------------------

windower.register_event('outgoing chunk', function(id, data)
    if id ~= 0x015 then return end

    local action = packets.parse('outgoing', data)
    PlayerH = action.Rotation
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

windower.register_event('addon command', function(...)
    local args = T{...}:map(string.lower)
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
            windower.add_to_chat(
                167,
                '[Lazy] You are dead. Stop being a floor decoration, then //lazy start again.'
            )
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

        path_last_distance = nil
        path_last_progress_time = nil
        path_stuck_alerted = false
        origin_unreachable_since = nil

        last_damage_source = nil
        last_damage_kind = nil
        death_reported = false

        leader_target_id = 0
        leader_target_index = 0
        leader_target_changed = false
        last_broadcast_target = 0
        last_broadcast_index = 0
        last_broadcast_engaged = false

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

        return
    end

    if command == 'stop' then
        windower.add_to_chat(2, '....Stopping Lazy Helper....')

        Start_Engine = false
        windower.ffxi.run(false)
        windower.ffxi.follow(0)

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

        if player then
            config.save(settings, player.name)
        end

        return
    end

    if command == 'show' then
        Update_Job_Profile()

        windower.add_to_chat(11, 'Main job: ' .. tostring(current_job))
        windower.add_to_chat(11, 'Autotarget: ' .. tostring(settings.autotarget))
        windower.add_to_chat(11, 'Spell: ' .. settings.spell)
        windower.add_to_chat(11, 'Use Spell: ' .. tostring(settings.spell_active))
        windower.add_to_chat(11, 'Weaponskill: ' .. settings.weaponskill)
        windower.add_to_chat(11, 'Use Weaponskill: ' .. tostring(settings.weaponskill_active))
        windower.add_to_chat(11, 'Target: ' .. settings.target)
        windower.add_to_chat(11, 'Buffs: ' .. tostring(settings.buffs_active))
        windower.add_to_chat(11, 'Cure Bot: ' .. tostring(settings.cure_active))

        return
    end

    if command == 'autotarget' then
        settings.autotarget = args[2] == 'on'

        windower.add_to_chat(
            3,
            'Autotarget: ' .. tostring(settings.autotarget)
        )

        return
    end

    if command == 'target' then
        settings.target = args[2] or ''
        return
    end

    if command == 'assist' then
        settings.assist = args[2] or ''

        windower.add_to_chat(
            2,
            'Assist: ' ..
            (settings.assist ~= '' and settings.assist or 'OFF')
        )

        return
    end

    if command == 'buffs' then
        settings.buffs_active = args[2] ~= 'off'

        windower.add_to_chat(
            3,
            'Buffs: ' .. tostring(settings.buffs_active)
        )

        return
    end

    if command == 'cure' then
        settings.cure_active = args[2] ~= 'off'

        windower.add_to_chat(
            3,
            'Cure Bot: ' .. tostring(settings.cure_active)
        )

        return
    end

    if command == 'range' then
        local value = tonumber(args[2])

        if value then
            origin_radius = value

            windower.add_to_chat(
                2,
                'Origin radius set to ' .. origin_radius .. ' yalms'
            )
        else
            windower.add_to_chat(
                2,
                'Current radius: ' .. origin_radius
            )
        end

        return
    end

    if command == 'retrust' then
        Snapshot_Trusts()
        return
    end
end)

------------------------------------------------------------
-- WEAPONSKILLS
------------------------------------------------------------

function Next_WS()
    local closers = Get_WS_Closers()

    if not closers or #closers == 0 then
        return nil
    end

    local ws = closers[ws_index]
    ws_index = (ws_index % #closers) + 1

    return ws
end

------------------------------------------------------------
-- HEADING / MOVEMENT
------------------------------------------------------------

function HeadingTo(x, y)
    local player = windower.ffxi.get_mob_by_id(
        windower.ffxi.get_player().id
    )

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
        windower.ffxi.turn(
            HeadingTo(target.x, target.y)
        )
    end
end

------------------------------------------------------------
-- ORIGIN
------------------------------------------------------------

function Origin_Distance(x, y, z)
    if not origin_x then
        return math.huge
    end

    if origin_z and z and math.abs(z - origin_z) > origin_z_tolerance then
        return math.huge
    end

    return math.sqrt(
        (x - origin_x)^2 +
        (y - origin_y)^2
    )
end

function Set_Origin()
    local player = windower.ffxi.get_mob_by_id(
        windower.ffxi.get_player().id
    )

    if not player then return end

    origin_x = player.x
    origin_y = player.y
    origin_z = player.z

    path_last_distance = nil
    path_last_progress_time = nil
    path_stuck_alerted = false
    origin_unreachable_since = nil

    windower.add_to_chat(
        2,
        'Origin set: (' ..
        math.floor(origin_x) .. ', ' ..
        math.floor(origin_y) ..
        ') radius: ' .. origin_radius
    )
end

------------------------------------------------------------
-- MOVEMENT LOCK
------------------------------------------------------------

function Movement_Locked()
    if isCasting then return true end
    if mp_resting then return true end
    return false
end

function Stop_Movement()
    windower.ffxi.run(false)
    windower.ffxi.follow(0)
end

------------------------------------------------------------
-- RETURN TO ORIGIN
------------------------------------------------------------

function Path_To_Origin()
    if not origin_x then return end

    if Movement_Locked() then
        Stop_Movement()
        return
    end

    local player = windower.ffxi.get_mob_by_id(
        windower.ffxi.get_player().id
    )

    if not player then return end

    local distance = Origin_Distance(
        player.x,
        player.y,
        player.z
    )

    if distance == math.huge then
        windower.ffxi.run(false)

        local now = os.clock()

        if not origin_unreachable_since then
            origin_unreachable_since = now
        end

        if now - origin_unreachable_since >= ORIGIN_UNREACHABLE_TIMEOUT then
            windower.add_to_chat(
                2,
                '[Lazy] Origin unreachable for ' ..
                math.floor(ORIGIN_UNREACHABLE_TIMEOUT / 60) ..
                ' min -- re-anchoring origin here and retargeting.'
            )

            Set_Origin()
            return
        end

        if not path_stuck_alerted then
            windower.add_to_chat(
                167,
                '[Lazy] Origin unreachable at current elevation -- stopping autopath. ' ..
                'Will re-anchor here after ' ..
                math.floor(ORIGIN_UNREACHABLE_TIMEOUT / 60) ..
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
            or distance < path_last_distance - PATH_STUCK_EPSILON
        then
            path_last_distance = distance
            path_last_progress_time = now
            path_stuck_alerted = false

        elseif path_last_progress_time
            and now - path_last_progress_time >= PATH_STUCK_TIMEOUT
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
            windower.ffxi.turn(
                HeadingTo(origin_x, origin_y)
            )
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

------------------------------------------------------------
-- PARTY / LEADER
------------------------------------------------------------

function Get_Party_Leader_ID()
    local party = windower.ffxi.get_party()
    if not party then return nil end

    if party.party1_leader
        and party.party1_leader ~= 0
    then
        return party.party1_leader
    end

    return nil
end

function Get_Party_Leader()
    local player = windower.ffxi.get_player()
    if not player then return nil end

    local leader_id = Get_Party_Leader_ID()

    if not leader_id then
        return windower.ffxi.get_mob_by_id(player.id)
    end

    return windower.ffxi.get_mob_by_id(leader_id)
end

function Is_Party_Leader()
    local player = windower.ffxi.get_player()
    if not player then return false end

    local leader_id = Get_Party_Leader_ID()

    -- Solo = leader.
    if not leader_id then
        return true
    end

    return leader_id == player.id
end

function Is_Leader_Engaged()
    local leader = Get_Party_Leader()
    if not leader then return false end

    return leader.status == 1
end

function Can_Auto_Engage()
    return active_profile
        and active_profile.auto_engage == true
end

------------------------------------------------------------
-- TARGET VALIDATION
------------------------------------------------------------

function Is_Valid_Combat_Target(mob)
    if not mob then return false end
    if not mob.valid_target then return false end
    if not mob.is_npc then return false end
    if not mob.hpp or mob.hpp <= 0 then return false end
    if Is_Blacklisted(mob.name) then return false end

    return true
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

function Is_Targeting_Allowed(mob)
    if not Is_Valid_Combat_Target(mob) then
        return false
    end

    if settings.target and settings.target ~= '' then
        if string.lower(mob.name or '')
            ~= string.lower(settings.target)
        then
            return false
        end
    elseif not Is_Targetable_Monster(mob.name) then
        return false
    end

    if targeting.only_alive
        and (not mob.hpp or mob.hpp <= 0)
    then
        return false
    end

    if targeting.only_unclaimed
        and mob.claim_id ~= 0
    then
        return false
    end

    if targeting.within_origin
        and origin_x
        and mob.x
        and Origin_Distance(
            mob.x,
            mob.y,
            mob.z
        ) > origin_radius
    then
        return false
    end

    return true
end

------------------------------------------------------------
-- FIND TARGET
------------------------------------------------------------

function Find_Named_Target(target_name)
    if not target_name or target_name == '' then
        return -1
    end

    local candidates = {}

    for key, mob in pairs(
        windower.ffxi.get_mob_array() or {}
    ) do
        if mob.distance then
            candidates[#candidates + 1] = {
                key = key,
                mob = mob,
                dist = math.sqrt(mob.distance),
            }
        end
    end

    table.sort(candidates, function(a, b)
        return a.dist < b.dist
    end)

    for _, entry in ipairs(candidates) do
        local mob = entry.mob

        if string.lower(mob.name or '')
            == string.lower(target_name)
            and Is_Targeting_Allowed(mob)
        then
            return entry.key
        end
    end

    return -1
end

function Find_Nearest_Target()
    local candidates = {}

    for key, mob in pairs(
        windower.ffxi.get_mob_array() or {}
    ) do
        if mob.distance then
            candidates[#candidates + 1] = {
                key = key,
                mob = mob,
                dist = math.sqrt(mob.distance),
            }
        end
    end

    table.sort(candidates, function(a, b)
        return a.dist < b.dist
    end)

    for _, entry in ipairs(candidates) do
        if Is_Targeting_Allowed(entry.mob) then
            return entry.key
        end
    end

    return -1
end

------------------------------------------------------------
-- EXACT TARGET SELECTION
--
-- windower.ffxi.set_target() DOES NOT EXIST.
--
-- FFXI outgoing 0x01A / category 0x0F is Switch Target.
------------------------------------------------------------

function Set_Target_By_Mob(mob)
    if not mob
        or not mob.id
        or not mob.index
        or mob.index <= 0
    then
        return false
    end

    local current = windower.ffxi.get_mob_by_target('t')

    if current and current.id == mob.id then
        return true
    end

    local packet = packets.new(
        'outgoing',
        0x01A,
        {
            ['Target'] = mob.id,
            ['Target Index'] = mob.index,
            ['Category'] = 0x0F,
            ['Param'] = 0,
        }
    )

    packets.inject(packet)
    return true
end

------------------------------------------------------------
-- LEADER TARGET IPC
------------------------------------------------------------

local leader_target_id = 0
local leader_target_index = 0
local leader_target_changed = false

local last_broadcast_target = 0
local last_broadcast_index = 0
local last_broadcast_engaged = false

function Broadcast_Leader_Target()
    if not Is_Party_Leader() then return end

    local target = windower.ffxi.get_mob_by_target('t')
    local target_id = 0
    local target_index = 0

    if target and target.id and target.index then
        target_id = target.id
        target_index = target.index
    end

    local player = windower.ffxi.get_player()
    local engaged = player and player.status == 1 or false

    if target_id == last_broadcast_target
        and target_index == last_broadcast_index
        and engaged == last_broadcast_engaged
    then
        return
    end

    last_broadcast_target = target_id
    last_broadcast_index = target_index
    last_broadcast_engaged = engaged

    windower.send_ipc_message(
        'lazy_target ' ..
        tostring(target_id) .. ' ' ..
        tostring(target_index) .. ' ' ..
        (engaged and '1' or '0')
    )
end

windower.register_event('ipc message', function(message)
    if not message then return end

    local id, index, engaged = message:match(
        '^lazy_target%s+(%d+)%s+(%d+)%s+(%d+)'
    )

    if not id then return end
    if Is_Party_Leader() then return end

    leader_target_id = tonumber(id) or 0
    leader_target_index = tonumber(index) or 0
    leader_target_changed = true
end)

function Sync_To_Leader_Target()
    if Is_Party_Leader() then return end
    if not leader_target_changed then return end
    if isCasting then return end

    leader_target_changed = false

    if leader_target_id <= 0
        or leader_target_index <= 0
    then
        return
    end

    local target =
        windower.ffxi.get_mob_by_id(leader_target_id)
        or windower.ffxi.get_mob_by_index(leader_target_index)

    if target then
        Set_Target_By_Mob(target)
    end
end

------------------------------------------------------------
-- LEADER TARGET ACQUISITION
------------------------------------------------------------

function Leader_Acquire_Target()
    if not Is_Party_Leader() then return nil end
    if not settings.autotarget then return nil end

    local current = windower.ffxi.get_mob_by_target('t')

    if Is_Targeting_Allowed(current) then
        return current
    end

    local target_id

    if settings.target and settings.target ~= '' then
        target_id = Find_Named_Target(settings.target)
    else
        target_id = Find_Nearest_Target()
    end

    if not target_id or target_id <= 0 then
        return nil
    end

    local target =
        windower.ffxi.get_mob_by_index(target_id)

    if not target or not Is_Targeting_Allowed(target) then
        return nil
    end

    Set_Target_By_Mob(target)
    lockon_done = false

    return target
end

------------------------------------------------------------
-- LEADER MOVEMENT
------------------------------------------------------------

function Leader_Approach_Target(target)
    if not target then return end

    if Movement_Locked() then
        Stop_Movement()
        return
    end

    -- BLM/GEO/etc. never run to the target.
    if not Can_Auto_Engage() then
        Stop_Movement()
        return
    end

    local distance =
        target.distance
        and math.sqrt(target.distance)

    if not distance then
        Stop_Movement()
        return
    end

    if distance <= 3 then
        Stop_Movement()

        if not lockon_done then
            windower.send_command('input /lockon')
            lockon_done = true
        end

        if target.claim_id == 0 then
            windower.send_command('input /attack on')
        end

        return
    end

    -- Leader directly approaches the monster.
    -- NEVER follow(target).
    windower.ffxi.turn(
        HeadingTo(target.x, target.y)
    )

    windower.ffxi.run(true)
end

------------------------------------------------------------
-- FOLLOW MONITOR
------------------------------------------------------------

function Follow_Monitor()
    while Start_Engine do
        if Movement_Locked() then
            Stop_Movement()

        elseif Is_Party_Leader() then
            -- Leader follows nothing.
            windower.ffxi.follow(0)

        else
            local leader = Get_Party_Leader()

            if not leader then
                Stop_Movement()
            else
                local distance =
                    leader.distance
                    and math.sqrt(leader.distance)

                if distance and distance > 3 then
                    windower.ffxi.follow(leader.index)
                else
                    windower.ffxi.follow(0)
                end
            end
        end

        coroutine.sleep(0.2)
    end
end

------------------------------------------------------------
-- TARGET MONITOR
------------------------------------------------------------

function Target_Monitor()
    while Start_Engine do
        if Is_Party_Leader() then
            Broadcast_Leader_Target()
        else
            Sync_To_Leader_Target()
        end

        coroutine.sleep(0.2)
    end
end

------------------------------------------------------------
-- TARGETING
------------------------------------------------------------

function Targeting()
    while Start_Engine do
        local player = windower.ffxi.get_player()

        if player then
            if Movement_Locked() then
                Stop_Movement()

            elseif not Is_Party_Leader() then
                -- Follower movement belongs exclusively to Follow_Monitor.

            elseif settings.assist and settings.assist ~= '' then
                windower.send_command(
                    'input /assist ' .. settings.assist
                )

                local target =
                    windower.ffxi.get_mob_by_target('t')

                if target and Is_Targeting_Allowed(target) then
                    if Can_Auto_Engage() then
                        Leader_Approach_Target(target)
                    else
                        Stop_Movement()
                    end
                else
                    Stop_Movement()
                end

            elseif settings.autotarget then
                local target = Leader_Acquire_Target()

                if target then
                    if Can_Auto_Engage() then
                        Leader_Approach_Target(target)
                    else
                        Stop_Movement()
                    end
                else
                    Path_To_Origin()
                end

            else
                Stop_Movement()
            end
        end

        coroutine.sleep(0.2)
    end
end

------------------------------------------------------------
-- ENGINE
------------------------------------------------------------

function Engine()
    while Start_Engine do
        local player = windower.ffxi.get_player()

        if player then
            Update_Job_Profile()

            buffactive =
                convert_buff_list(player.buffs or {})

            if isBusy < 1 then
                pcall(Combat)
            else
                isBusy = isBusy - 1
            end
        end

        coroutine.sleep(1)
    end
end

------------------------------------------------------------
-- SKILLCHAIN MONITOR
------------------------------------------------------------

function SC_Monitor()
    while Start_Engine do
        local player = windower.ffxi.get_player()

        if player
            and player.status == 1
            and not isCasting
            and not mp_resting
            and isBusy < 1
            and player.vitals.tp >= 1000
        then
            local target =
                windower.ffxi.get_mob_by_target('t')

            if target and sc_ready(target.id) then
                local options = sc_get_ws(target.id)
                local fired = false

                for _, ws in ipairs(options or {}) do
                    if fired then break end

                    for _, closer in ipairs(Get_WS_Closers() or {}) do
                        if ws == closer then
                            if not isCasting
                                and not mp_resting
                                and isBusy == 0
                            then
                                windower.send_command(
                                    'input /ws "' .. closer .. '" <t>'
                                )

                                isBusy = Action_Delay
                                fired = true
                            end

                            break
                        end
                    end
                end
            end
        end

        coroutine.sleep(0.5)
    end
end

------------------------------------------------------------
-- COMBAT
------------------------------------------------------------

function Combat()
    local player = windower.ffxi.get_player()
    if not player then return end

    -- Absolute cast lock.
    if isCasting then return end

    -- Resting lock.
    if mp_resting then return end

    local target =
        windower.ffxi.get_mob_by_target('t')

    local starter = Get_WS_Starter()

    if player.status == 1 then
        if not engaged_since then
            engaged_since = os.clock()
        end
    else
        engaged_since = nil
    end

    if active_profile.provoke_if_stuck
        and player.status == 1
        and target
        and engaged_since
        and os.clock() - engaged_since >=
            (active_profile.stuck_threshold or 10)
    then
        if Can_Cast_Ability('Provoke') then
            Cast_Ability('Provoke')
        end

        TurnToTarget()
    end

    --------------------------------------------------------
    -- MAGIC BURST
    --------------------------------------------------------

    if active_profile.magic_burst then
        if Try_Magic_Burst() then
            return
        end

        if current_job == 'BLM'
            or current_job == 'GEO'
            or current_job == 'SCH'
            or current_job == 'NIN'
            or current_job == 'RDM'
        then
            return
        end
    end

    --------------------------------------------------------
    -- TP CAP
    --------------------------------------------------------

    if target
        and target.distance
        and math.sqrt(target.distance) <= 3
        and player.vitals.tp >= 3000
        and isBusy == 0
        and not isCasting
        and starter
        and starter[1]
    then
        windower.send_command(
            'input /ws "' .. starter[1] .. '" <t>'
        )

        isBusy = Action_Delay
        return
    end

    if player.status ~= 1 then
        return
    end

    lockon_done = false

    --------------------------------------------------------
    -- JOB ABILITIES / FOOD
    --------------------------------------------------------

    if player.vitals.tp >= 400
        and target
        and target.distance
        and math.sqrt(target.distance) <= 3
    then
        local recasts =
            windower.ffxi.get_ability_recasts()

        for _, ability_name in ipairs(Get_Needed_Buffs() or {}) do
            if not buffactive[ability_name] then
                if ability_name == 'Food' then
                    local food_name = Get_Food()

                    if food_name then
                        windower.send_command(
                            'input /item "' .. food_name .. '" <me>'
                        )

                        isBusy = Action_Delay
                        return
                    end
                else
                    local ability =
                        res.job_abilities:with(
                            'name',
                            ability_name
                        )

                    if ability
                        and recasts[ability.recast_id] == 0
                    then
                        Cast_Ability(ability_name)
                        return
                    end
                end
            end
        end
    end

    --------------------------------------------------------
    -- FACE TARGET
    --------------------------------------------------------

    if not isCasting then
        TurnToTarget()
    end

    --------------------------------------------------------
    -- MELEE RANGE
    --------------------------------------------------------

    if target
        and target.distance
        and math.sqrt(target.distance) <= 3
    then
        local tp = player.vitals.tp

        if not sc_active(target.id)
            and starter
            and tp >= starter[2]
        then
            if not isCasting then
                windower.send_command(
                    'input /ws "' .. starter[1] .. '" <t>'
                )

                isBusy = Action_Delay
                return
            end
        end

        if settings.spell_active
            and Can_Cast_Spell(settings.spell)
            and not Is_Blacklisted(target.name)
        then
            Cast_Spell(settings.spell)
            return
        end

    elseif settings.spell_active
        and Can_Cast_Spell(settings.spell)
        and not (
            target
            and Is_Blacklisted(target.name)
        )
    then
        Cast_Spell(settings.spell)
        return
    end
end

------------------------------------------------------------
-- SPELL / ABILITY HELPERS
------------------------------------------------------------

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

function Can_Cast_Spell(spell_name)
    if not spell_name or spell_name == '' then
        return false
    end

    local spell =
        res.spells:with('name', spell_name)

    if not spell then return false end

    local player = windower.ffxi.get_player()
    if not player then return false end

    local recasts =
        windower.ffxi.get_spell_recasts()

    return recasts[spell.id] == 0
        and not isCasting
        and isBusy == 0
        and player.vitals.mp >= spell.mp_cost
        and not Is_Moving()
end

function Can_Cast_Ability(ability_name)
    local ability =
        res.job_abilities:with(
            'name',
            ability_name
        )

    if not ability then return false end

    local recasts =
        windower.ffxi.get_ability_recasts()

    return recasts[ability.recast_id] == 0
        and not isCasting
        and isBusy == 0
end

function Cast_Spell(spell_name)
    local spell =
        res.spells:with(
            'name',
            spell_name
        )

    if not spell then return false end

    local recasts =
        windower.ffxi.get_spell_recasts()

    if recasts[spell.id] ~= 0
        or isCasting
        or isBusy > 0
    then
        return false
    end

    windower.send_command(
        'input /ma "' .. spell_name .. '" <t>'
    )

    isBusy = Action_Delay
    return true
end

function Cast_Spell_On(spell_name, target)
    local spell =
        res.spells:with(
            'name',
            spell_name
        )

    if not spell then return false end

    if Is_Moving() then
        return false
    end

    local player = windower.ffxi.get_player()
    if not player then return false end

    local recasts =
        windower.ffxi.get_spell_recasts()

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

function Cast_Ability(ability_name)
    if isCasting then return false end

    windower.send_command(
        'input /ja "' .. ability_name .. '" <me>'
    )

    isBusy = Action_Delay
    return true
end

------------------------------------------------------------
-- BUFF SYSTEM
------------------------------------------------------------

function Buff_Tick()
    if not settings.buffs_active then return end

    if pending_cast
        and os.clock() - pending_cast.sent_at > 10
    then
        pending_cast = nil
    end

    if isBusy > 0
        or isCasting
        or pending_cast
    then
        return
    end

    local player = windower.ffxi.get_player()
    if not player then return end

    local now = os.clock()
    Update_Job_Profile()

    --------------------------------------------------------
    -- DEBUFFS
    --------------------------------------------------------

    if active_profile.debuffs then
        local target =
            windower.ffxi.get_mob_by_target('t')

        if target
            and target.hpp
            and target.hpp > 0
            and not Is_Blacklisted(target.name)
        then
            for _, debuff in ipairs(active_profile.debuffs) do
                local last =
                    debuff_last_cast[debuff.name]

                local interval =
                    (debuff.interval or 1) * 60

                if not last or now - last >= interval then
                    local spell =
                        res.spells:with(
                            'name',
                            debuff.name
                        )

                    if spell
                        and Cast_Spell_On(
                            debuff.name,
                            '<t>'
                        )
                    then
                        pending_cast = {
                            store = debuff_last_cast,
                            key = debuff.name,
                            spell_id = spell.id,
                            sent_at = now,
                        }

                        return
                    end
                end
            end
        end
    end

    --------------------------------------------------------
    -- JOB ABILITIES
    --------------------------------------------------------

    for _, ability_name in ipairs(
        active_profile.job_abilities or {}
    ) do
        if Can_Cast_Ability(ability_name) then
            Cast_Ability(ability_name)
            return
        end
    end

    --------------------------------------------------------
    -- SELF BUFFS
    --------------------------------------------------------

    for _, buff in ipairs(
        active_profile.self_buffs or {}
    ) do
        local interval =
            (buff.interval or 20) * 60

        local last =
            self_buff_last_cast[buff.name]

        if not last or now - last >= interval then
            local spell =
                res.spells:with(
                    'name',
                    buff.name
                )

            if spell
                and Cast_Spell_On(
                    buff.name,
                    '<me>'
                )
            then
                pending_cast = {
                    store = self_buff_last_cast,
                    key = buff.name,
                    spell_id = spell.id,
                    sent_at = now,
                }

                return
            end
        end
    end

    --------------------------------------------------------
    -- SELF ABILITIES
    --------------------------------------------------------

    local self_ability_list = {}

    for _, ab in ipairs(
        active_profile.self_abilities or {}
    ) do
        self_ability_list[#self_ability_list + 1] = ab
    end

    do
        local sub = player.sub_job

        if debug_self_abilities then
            windower.add_to_chat(
                8,
                '[Lazy debug] sub_job=' .. tostring(sub) ..
                ' haste_samba_active=' .. tostring(haste_samba_active) ..
                ' has_table=' ..
                tostring(
                    subjob_abilities
                    and subjob_abilities[sub] ~= nil
                )
            )
        end

        if haste_samba_active
            and sub
            and subjob_abilities
            and subjob_abilities[sub]
        then
            for _, ab in ipairs(
                subjob_abilities[sub]
            ) do
                self_ability_list[#self_ability_list + 1] = ab
            end
        end
    end

    for _, ab in ipairs(self_ability_list) do
        local interval =
            (ab.interval or 20) * 60

        local last =
            self_ability_last_cast[ab.name]

        local due =
            not last
            or now - last >= interval

        if debug_self_abilities then
            local ability =
                res.job_abilities:with(
                    'name',
                    ab.name
                )

            local recasts =
                windower.ffxi.get_ability_recasts()

            windower.add_to_chat(
                8,
                '[Lazy debug] ' .. ab.name ..
                ' due=' .. tostring(due) ..
                ' known_ability=' ..
                tostring(ability ~= nil) ..
                ' recast=' ..
                tostring(
                    ability
                    and recasts[ability.recast_id]
                ) ..
                ' can_cast=' ..
                tostring(
                    Can_Cast_Ability(ab.name)
                )
            )
        end

        if due and Can_Cast_Ability(ab.name) then
            Cast_Ability(ab.name)
            self_ability_last_cast[ab.name] = now
            return
        end
    end

    --------------------------------------------------------
    -- GENERIC PARTY BUFFS
    --------------------------------------------------------

    if active_profile.party_buffs then
        local me_zone =
            windower.ffxi.get_info().zone

        local party =
            windower.ffxi.get_party()

        for _, pb in ipairs(
            active_profile.party_buffs
        ) do
            local spell_name = pb.spell
            local interval = (pb.interval or 6) * 60
            local range = pb.range or 20
            local targets = {}

            if pb.targets == 'ALL_PLAYERS' then
                if party then
                    for _, key in ipairs({
                        'p0', 'p1', 'p2',
                        'p3', 'p4', 'p5'
                    }) do
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

            elseif type(pb.targets) == 'table'
                and pb.targets.jobs
            then
                if party then
                    for _, key in ipairs({
                        'p0', 'p1', 'p2',
                        'p3', 'p4', 'p5'
                    }) do
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
                            for _, job in ipairs(
                                pb.targets.jobs
                            ) do
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
                local cache_key =
                    spell_name .. ':' .. tname

                local last =
                    party_buff_last_cast[cache_key]

                if not last
                    or now - last >= interval
                then
                    local spell =
                        res.spells:with(
                            'name',
                            spell_name
                        )

                    if spell
                        and Cast_Spell_On(
                            spell_name,
                            tname
                        )
                    then
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

    --------------------------------------------------------
    -- LEGACY HASTE
    --------------------------------------------------------

    if active_profile.haste_active
        and not active_profile.party_buffs
    then
        local self_interval =
            (active_profile.haste_self_interval or 20) * 60

        local self_last = haste_last_cast.me
        local haste_spell =
            active_profile.haste_spell or 'Haste II'

        if not self_last
            or now - self_last >= self_interval
        then
            local spell =
                res.spells:with(
                    'name',
                    haste_spell
                )

            if spell
                and Cast_Spell_On(
                    haste_spell,
                    '<me>'
                )
            then
                pending_cast = {
                    store = haste_last_cast,
                    key = 'me',
                    spell_id = spell.id,
                    sent_at = now,
                }

                return
            end
        end

        local party_interval =
            (active_profile.haste_party_interval or 6) * 60

        local haste_targets =
            active_profile.haste_targets

        local me_zone =
            windower.ffxi.get_info().zone

        if haste_targets == 'ALL_PLAYERS' then
            haste_targets = {}

            local party =
                windower.ffxi.get_party()

            if party then
                for _, key in ipairs({
                    'p0', 'p1', 'p2',
                    'p3', 'p4', 'p5'
                }) do
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

            if not last
                or now - last >= party_interval
            then
                local spell =
                    res.spells:with(
                        'name',
                        haste_spell
                    )

                if spell
                    and Cast_Spell_On(
                        haste_spell,
                        tname
                    )
                then
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

    --------------------------------------------------------
    -- LEGACY REFRESH
    --------------------------------------------------------

    if active_profile.refresh_targets
        and not active_profile.party_buffs
    then
        local refresh =
            active_profile.refresh_targets

        local interval =
            (refresh.interval or 6) * 60

        local spell_name =
            refresh.spell or 'Refresh III'

        local me_zone =
            windower.ffxi.get_info().zone

        local party =
            windower.ffxi.get_party()

        if party then
            for _, key in ipairs({
                'p0', 'p1', 'p2',
                'p3', 'p4', 'p5'
            }) do
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

                    for _, job in ipairs(
                        refresh.jobs or {}
                    ) do
                        if m.main_job == job then
                            allowed = true
                            break
                        end
                    end

                    if allowed then
                        local cache_key =
                            'refresh:' .. m.name

                        local last =
                            refresh_last_cast[cache_key]

                        if not last
                            or now - last >= interval
                        then
                            local spell =
                                res.spells:with(
                                    'name',
                                    spell_name
                                )

                            if spell
                                and Cast_Spell_On(
                                    spell_name,
                                    m.name
                                )
                            then
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

------------------------------------------------------------
-- CURE BOT
------------------------------------------------------------

function Party_Has_WHM()
    local party = windower.ffxi.get_party()
    if not party then return false end

    for _, key in ipairs({
        'p0', 'p1', 'p2',
        'p3', 'p4', 'p5'
    }) do
        local m = party[key]

        if m then
            if m.main_job == 'WHM'
                or m.job == 'WHM'
            then
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
    if not settings.cure_active then return end

    Update_Job_Profile()

    local cure_active =
        active_profile.cure_bot_active

    if current_job == 'SCH'
        and active_profile.cure_bot_if_no_whm
    then
        cure_active = not Party_Has_WHM()
    end

    if not cure_active then return end

    if pending_cast
        and os.clock() - pending_cast.sent_at > 10
    then
        pending_cast = nil
    end

    if isBusy > 0
        or isCasting
        or pending_cast
    then
        return
    end

    local player = windower.ffxi.get_player()
    if not player then return end

    local party = windower.ffxi.get_party()
    if not party then return end

    local worst_member = nil
    local worst_hpp = 999

    for _, key in ipairs({
        'p0', 'p1', 'p2',
        'p3', 'p4', 'p5'
    }) do
        local m = party[key]

        if m
            and m.hp
            and m.hp > 0
            and m.hpp
            and m.hpp < worst_hpp
        then
            worst_hpp = m.hpp
            worst_member = m
        end
    end

    if not worst_member or worst_hpp >= 100 then
        return
    end

    local target_name =
        worst_member.name
        or (
            worst_member.mob
            and worst_member.mob.name
        )

    if not target_name then return end

    local max_hp =
        worst_member.hp / (worst_hpp / 100)

    local missing_hp =
        math.floor(max_hp - worst_member.hp)

    if missing_hp <= 0 then return end

    local target =
        target_name == player.name
        and '<me>'
        or target_name

    for _, tier in ipairs(
        active_profile.cure_tiers or {}
    ) do
        if missing_hp < tier.max_missing then
            for _, spell_name in ipairs(tier.spells) do
                if Cast_Spell_On(
                    spell_name,
                    target
                ) then
                    return
                end
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

------------------------------------------------------------
-- TRUST RESUMMON
------------------------------------------------------------

local tracked_trusts = {}
local trust_resummon_last = {}

function Snapshot_Trusts()
    tracked_trusts = {}

    local party = windower.ffxi.get_party()
    if not party then return end

    for _, key in ipairs({
        'p0', 'p1', 'p2',
        'p3', 'p4', 'p5'
    }) do
        local m = party[key]

        if m
            and m.name
            and m.mob
            and m.mob.is_npc
        then
            tracked_trusts[#tracked_trusts + 1] = m.name
        end
    end

    if #tracked_trusts > 0 then
        windower.add_to_chat(
            2,
            '[Lazy] Tracking trusts for resummon: ' ..
            table.concat(tracked_trusts, ', ')
        )
    end
end

function Trust_Tick()
    if #tracked_trusts == 0 then return end

    if pending_cast
        and os.clock() - pending_cast.sent_at > 10
    then
        pending_cast = nil
    end

    if isBusy > 0
        or isCasting
        or pending_cast
    then
        return
    end

    local party = windower.ffxi.get_party()
    if not party then return end

    local present = {}

    for _, key in ipairs({
        'p0', 'p1', 'p2',
        'p3', 'p4', 'p5'
    }) do
        local m = party[key]

        if m
            and m.name
            and m.hp
            and m.hp > 0
        then
            present[m.name] = true
        end
    end

    for _, name in ipairs(tracked_trusts) do
        if not present[name] then
            local spell =
                res.spells:with(
                    'name',
                    name
                )

            if spell
                and Cast_Spell_On(
                    name,
                    '<me>'
                )
            then
                pending_cast = {
                    store = trust_resummon_last,
                    key = name,
                    spell_id = spell.id,
                    sent_at = os.clock(),
                }

                windower.add_to_chat(
                    2,
                    '[Lazy] Resummoning trust: ' .. name
                )

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

------------------------------------------------------------
-- BUFF LIST
------------------------------------------------------------

function convert_buff_list(bufflist)
    local buffs = {}

    for _, buff_id in pairs(bufflist or {}) do
        local buff = res.buffs[buff_id]

        if buff then
            if buff.english then
                buffs[buff.english] =
                    (buffs[buff.english] or 0) + 1
            end

            buffs[buff_id] =
                (buffs[buff_id] or 0) + 1
        end
    end

    return buffs
end

------------------------------------------------------------
-- INIT
------------------------------------------------------------

Update_Job_Profile()