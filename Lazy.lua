require('chat')
require('logger')
require('tables')

config  = require('config')
res     = require('resources')
packets = require('packets')

------------------------------------------------------------
-- MODULES & FALLBACK DEFINITIONS
------------------------------------------------------------

dofile(windower.addon_path .. 'skillchain.lua')
dofile(windower.addon_path .. 'magicburst.lua')
dofile(windower.addon_path .. 'settings.lua')

ws_sc_starter      = ws_sc_starter or {}
ws_sc_closers      = ws_sc_closers or {}
needed_buffs       = needed_buffs or {}
food               = food or nil
spell_blacklist    = spell_blacklist or {}
haste_blacklist    = haste_blacklist or {}
subjob_abilities   = subjob_abilities or {}
haste_samba_active = haste_samba_active or false

targeting = targeting or {
    monsters = {},
    only_alive = true,
    within_origin = true,
    only_unclaimed = true,
}

------------------------------------------------------------
-- ADDON
------------------------------------------------------------

_addon.name     = 'lazy'
_addon.author   = 'Ulli'
_addon.version  = '0.9'
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

local origin_x           = nil
local origin_y           = nil
local origin_z           = nil
local origin_radius      = 10
local origin_z_tolerance = 15
local pathing_to_origin  = false
local path_tick          = 0
local last_known_pos     = nil
local move_threshold     = 0.05

local path_last_distance      = nil
local path_last_progress_time = nil
local path_stuck_alerted      = false
local PATH_STUCK_TIMEOUT      = 8
local PATH_STUCK_EPSILON      = 1

local origin_unreachable_since   = nil
local ORIGIN_UNREACHABLE_TIMEOUT = 600

------------------------------------------------------------
-- COMBAT STATE
------------------------------------------------------------

local trust_ws_countdown = 0
local lockon_done        = false
local ws_index           = 1
local PlayerH            = 0
local engaged_since      = nil

local dnc_flourish_pending = false

local DNC_WALTZ_TIERS = {
    'Curing Waltz V',
    'Curing Waltz IV',
    'Curing Waltz III',
    'Curing Waltz II',
    'Curing Waltz',
}

------------------------------------------------------------
-- CAST TRACKING
------------------------------------------------------------

local self_buff_last_cast    = {}
local self_ability_last_cast = {}
local haste_last_cast        = {}
local debuff_last_cast       = {}
local refresh_last_cast      = {}
local party_buff_last_cast   = {}
local entrust_last_cast      = {}

local pending_cast = nil

------------------------------------------------------------
-- MP REST
------------------------------------------------------------

local MP_REST_THRESHOLD = 500

local MP_REST_JOBS = {
    WHM = true,
    RDM = true,
    BLM = true,
    GEO = true,
}

local mp_resting = false

function MP_Rest_Allowed()
    return current_job
        and MP_REST_JOBS[current_job] == true
end

function Start_MP_Rest()
    if not MP_Rest_Allowed() then return false end
    if mp_resting then return true end

    local player = windower.ffxi.get_player()
    if not player or not player.vitals then return false end

    if player.status == 1 then return false end

    if isCasting or isBusy > 0 or pending_cast then
        return false
    end

    if player.vitals.mp
        and player.vitals.mp < MP_REST_THRESHOLD
    then
        windower.send_command('input /heal on')
        mp_resting = true
        return true
    end

    return false
end

function Stop_MP_Rest()
    if not mp_resting then return end

    windower.send_command('input /heal off')
    mp_resting = false
end

function MP_Rest_Tick()
    if not MP_Rest_Allowed() then
        if mp_resting then
            Stop_MP_Rest()
        end
        return false
    end

    local player = windower.ffxi.get_player()
    if not player or not player.vitals then return false end

    if player.status == 1 then
        if mp_resting then
            Stop_MP_Rest()
        end
        return false
    end

    if player.vitals.mp
        and player.vitals.mp >= MP_REST_THRESHOLD
    then
        if mp_resting then
            Stop_MP_Rest()
        end
        return false
    end

    if isCasting or isBusy > 0 or pending_cast then
        return false
    end

    return Start_MP_Rest()
end

------------------------------------------------------------
-- JOB STATE
------------------------------------------------------------

current_job    = nil
active_profile = nil

------------------------------------------------------------
-- JOB PROFILES
------------------------------------------------------------

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
            '[Lazy] Profile not found: ' .. job .. '.lua -> using DEFAULT'
        )
    end
end

JOB_PROFILES.DEFAULT = JOB_PROFILES.DEFAULT or {}
active_profile = JOB_PROFILES.DEFAULT

------------------------------------------------------------
-- BACKLINE & DISENGAGE OVERRIDES
------------------------------------------------------------

local function Enforce_Backline_Rules()
    local player = windower.ffxi.get_player()
    if not player or not active_profile then return end

    if player.status == 1
        and active_profile.auto_engage == false
    then
        windower.send_command('input /attack off')
    end
end

local function Ensure_Debuff_Target()
    local player = windower.ffxi.get_player()
    if not player or not active_profile then return end

    if (active_profile.debuffs or active_profile.magic_burst)
        and active_profile.auto_engage == false
        and not windower.ffxi.get_mob_by_target('t')
    then
        windower.send_command(
            'input /target <p1>; wait 0.2; input /target <bt>'
        )
    end
end

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

        if (dx * dx + dy * dy)
            > (move_threshold * move_threshold)
        then
            moving = true
        end
    end

    last_known_pos = {
        x = mob.x,
        y = mob.y
    }

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

    if mp_resting then
        Stop_MP_Rest()
    end

    current_job    = job
    active_profile = JOB_PROFILES[job] or JOB_PROFILES.DEFAULT

    self_buff_last_cast    = {}
    self_ability_last_cast = {}
    haste_last_cast        = {}
    debuff_last_cast       = {}
    refresh_last_cast      = {}
    party_buff_last_cast   = {}
    entrust_last_cast      = {}

    windower.add_to_chat(
        2,
        '[Lazy] Main job: ' .. job
    )
end

------------------------------------------------------------
-- PROFILE HELPERS
------------------------------------------------------------

function Get_WS_Starter()
    return active_profile
        and active_profile.ws_sc_starter
        or ws_sc_starter
end

function Get_WS_Closers()
    return active_profile
        and active_profile.ws_sc_closers
        or ws_sc_closers
end

function Get_Needed_Buffs()
    return active_profile
        and active_profile.needed_buffs
        or needed_buffs
end

function Get_Food()
    return active_profile
        and active_profile.food
        or food
end

------------------------------------------------------------
-- SETTINGS
------------------------------------------------------------

defaults = {
    spell              = '',
    spell_active       = false,
    weaponskill        = '',
    weaponskill_active = false,
    autotarget         = false,
    target             = '',
    assist             = '',
    buffs_active       = true,
    cure_active        = true,
}

settings = config.load(defaults)

------------------------------------------------------------
-- INCOMING PACKETS
------------------------------------------------------------

windower.register_event('incoming chunk', function(id, data)
    if id ~= 0x028 then return end

    local action = packets.parse('incoming', data)
    local player = windower.ffxi.get_player()

    if not player
        or action.Actor ~= player.id
    then
        return
    end

    if action.Category == 4 then
        isCasting = false

        if pending_cast then
            local matches =
                action.Param == pending_cast.spell_id

            local reaction =
                action['Target 1 Action 1 Reaction']

            if matches and reaction == 0 then
                pending_cast.store[
                    pending_cast.key
                ] = pending_cast.sent_at
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

local last_damage_source    = nil
local last_damage_source_id = nil
local last_damage_kind      = nil
local death_reported        = false

local aggro_queue     = {}
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

    local current =
        windower.ffxi.get_mob_by_target('t')

    local current_id =
        current and current.id

    local target_count =
        action['Target Count'] or 1

    for t = 1, target_count do
        if action['Target ' .. t .. ' ID'] == player.id then
            local reaction =
                action[
                    'Target ' .. t ..
                    ' Action 1 Reaction'
                ]

            if reaction == 0 then
                local actor_id = action.Actor
                local actor =
                    windower.ffxi.get_mob_by_id(actor_id)

                last_damage_source =
                    actor and actor.name
                    or last_damage_source
                    or 'something unseen'

                last_damage_source_id = actor_id
                last_damage_kind =
                    Resolve_Attack_Name(action.Param)

                if actor_id
                    and actor_id ~= current_id
                then
                    local already_queued = false

                    for _, qid in ipairs(aggro_queue) do
                        if qid == actor_id then
                            already_queued = true
                            break
                        end
                    end

                    if not already_queued then
                        aggro_queue[#aggro_queue + 1] =
                            actor_id

                        if #aggro_queue > AGGRO_QUEUE_CAP then
                            table.remove(
                                aggro_queue,
                                1
                            )
                        end
                    end
                end
            end

            break
        end
    end
end)

function Death_Monitor()
    while Start_Engine do
        local player = windower.ffxi.get_player()

        if player
            and player.vitals
            and player.vitals.hp
            and player.vitals.hp <= 0
        then
            if not death_reported then
                death_reported = true

                local cause =
                    last_damage_source
                    or 'unknown causes'

                if last_damage_kind then
                    cause =
                        cause
                        .. ' ('
                        .. last_damage_kind
                        .. ')'
                elseif last_damage_source then
                    cause = cause .. ' (melee)'
                end

                windower.add_to_chat(
                    167,
                    '[Lazy] You died -- killed by '
                    .. cause
                    .. '. Stopping Lazy.'
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
-- ENGAGEMENT SYNC
------------------------------------------------------------

function Engagement_Sync()
    while Start_Engine do
        local player = windower.ffxi.get_player()

        if player then
            for i = #aggro_queue, 1, -1 do
                local candidate =
                    windower.ffxi.get_mob_by_id(
                        aggro_queue[i]
                    )

                if not candidate
                    or not candidate.valid_target
                    or not candidate.hpp
                    or candidate.hpp <= 0
                    or (
                        candidate.claim_id ~= 0
                        and candidate.claim_id ~= player.id
                    )
                then
                    table.remove(
                        aggro_queue,
                        i
                    )
                end
            end
        end

        if player
            and player.status == 1
        then
            local current =
                windower.ffxi.get_mob_by_target('t')

            local current_ok =
                current
                and current.valid_target
                and current.hpp
                and current.hpp > 0
                and current.distance
                and math.sqrt(current.distance) <= 5

            if not current_ok then
                local switched = false

                while #aggro_queue > 0
                    and not switched
                do
                    local candidate_id =
                        table.remove(
                            aggro_queue,
                            1
                        )

                    local candidate =
                        windower.ffxi.get_mob_by_id(
                            candidate_id
                        )

                    if candidate
                        and candidate.valid_target
                        and candidate.hpp
                        and candidate.hpp > 0
                        and (
                            candidate.claim_id == 0
                            or candidate.claim_id == player.id
                        )
                    then
                        windower.add_to_chat(
                            2,
                            '[Lazy] Finishing that off, now dealing with: '
                            .. candidate.name
                        )

                        windower.send_command(
                            'input /target "'
                            .. candidate.name
                            .. '"'
                        )

                        switched = true
                    end
                end

                if not switched
                    and last_damage_source_id
                then
                    local attacker =
                        windower.ffxi.get_mob_by_id(
                            last_damage_source_id
                        )

                    if attacker
                        and attacker.valid_target
                        and attacker.hpp
                        and attacker.hpp > 0
                        and (
                            attacker.claim_id == 0
                            or attacker.claim_id == player.id
                        )
                        and (
                            not current
                            or attacker.id ~= current.id
                        )
                    then
                        windower.add_to_chat(
                            2,
                            '[Lazy] Engaged target mismatch -- retargeting to '
                            .. attacker.name
                        )

                        windower.send_command(
                            'input /target "'
                            .. attacker.name
                            .. '"'
                        )
                    end
                end
            end
        end

        coroutine.sleep(10)
    end
end

------------------------------------------------------------
-- OUTGOING PACKETS
------------------------------------------------------------

windower.register_event('outgoing chunk', function(id, data)
    if id ~= 0x015 then return end

    local action =
        packets.parse('outgoing', data)

    PlayerH = action.Rotation
end)

------------------------------------------------------------
-- STATUS CHANGE LISTENERS
------------------------------------------------------------

windower.register_event('status change', function(new_status_id)
    if new_status_id == 1 then
        Enforce_Backline_Rules()
    end
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

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
        local player =
            windower.ffxi.get_player()

        if player
            and player.vitals
            and player.vitals.hp
            and player.vitals.hp <= 0
        then
            windower.add_to_chat(
                167,
                '[Lazy] You are dead. Stop being a floor decoration, then //lazy start again.'
            )
            return
        end

        windower.add_to_chat(
            2,
            '....Starting Lazy Helper....'
        )

        Set_Origin()

        if Start_Engine then
            return
        end

        Start_Engine = true
        mp_resting = false
        lockon_done = false

        self_buff_last_cast    = {}
        self_ability_last_cast = {}
        haste_last_cast        = {}
        debuff_last_cast       = {}
        refresh_last_cast      = {}
        party_buff_last_cast   = {}
        entrust_last_cast      = {}

        path_last_distance       = nil
        path_last_progress_time  = nil
        path_stuck_alerted       = false
        origin_unreachable_since = nil

        last_damage_source    = nil
        last_damage_source_id = nil
        last_damage_kind      = nil
        death_reported        = false
        aggro_queue           = {}

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

        return
    end

    if command == 'stop' then
        windower.add_to_chat(
            2,
            '....Stopping Lazy Helper....'
        )

        if mp_resting then
            Stop_MP_Rest()
        end

        windower.ffxi.follow(0)
        windower.ffxi.run(false)

        Start_Engine = false
        lockon_done = false

        return
    end

    if command == 'reload' then
        windower.add_to_chat(
            2,
            '....Reloading Config....'
        )

        config.reload(settings)
        dofile(
            windower.addon_path .. 'settings.lua'
        )

        return
    end

    if command == 'save' then
        local player =
            windower.ffxi.get_player()

        if player then
            config.save(
                settings,
                player.name
            )
        end

        return
    end

    if command == 'show' then
        Update_Job_Profile()

        windower.add_to_chat(
            11,
            'Main job: '
            .. tostring(current_job)
        )

        windower.add_to_chat(
            11,
            'Autotarget: '
            .. tostring(settings.autotarget)
        )

        windower.add_to_chat(
            11,
            'Spell: '
            .. settings.spell
        )

        windower.add_to_chat(
            11,
            'Use Spell: '
            .. tostring(settings.spell_active)
        )

        windower.add_to_chat(
            11,
            'Weaponskill: '
            .. settings.weaponskill
        )

        windower.add_to_chat(
            11,
            'Use Weaponskill: '
            .. tostring(settings.weaponskill_active)
        )

        windower.add_to_chat(
            11,
            'Target: '
            .. settings.target
        )

        windower.add_to_chat(
            11,
            'Buffs: '
            .. tostring(settings.buffs_active)
        )

        windower.add_to_chat(
            11,
            'Cure Bot: '
            .. tostring(settings.cure_active)
        )

        return
    end

    if command == 'autotarget' then
        settings.autotarget =
            (args[2] == 'on')

        windower.add_to_chat(
            3,
            'Autotarget: '
            .. tostring(settings.autotarget)
        )

        return
    end

    if command == 'target' then
        settings.target =
            args[2] or ''

        return
    end

    if command == 'assist' then
        settings.assist =
            args[2] or ''

        windower.add_to_chat(
            2,
            'Assist: '
            .. (
                settings.assist ~= ''
                and settings.assist
                or 'OFF'
            )
        )

        if settings.assist ~= '' then
            windower.send_command(
                'input /assist '
                .. settings.assist
            )

            if active_profile
                and active_profile.auto_engage == false
            then
                windower.send_command(
                    'wait 0.4; input /attack off'
                )
            end
        end

        return
    end

    if command == 'buffs' then
        settings.buffs_active =
            (args[2] ~= 'off')

        windower.add_to_chat(
            3,
            'Buffs: '
            .. tostring(settings.buffs_active)
        )

        return
    end

    if command == 'cure' then
        settings.cure_active =
            (args[2] ~= 'off')

        windower.add_to_chat(
            3,
            'Cure Bot: '
            .. tostring(settings.cure_active)
        )

        return
    end

    if command == 'range' then
        local value =
            tonumber(args[2])

        if value then
            origin_radius = value

            windower.add_to_chat(
                2,
                'Origin radius set to '
                .. origin_radius
                .. ' yalms'
            )
        else
            windower.add_to_chat(
                2,
                'Current radius: '
                .. origin_radius
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
    local closers =
        Get_WS_Closers()

    if not closers
        or #closers == 0
    then
        return nil
    end

    local ws =
        closers[ws_index]

    ws_index =
        (ws_index % #closers) + 1

    return ws
end

------------------------------------------------------------
-- HEADING / MOVEMENT
------------------------------------------------------------

function HeadingTo(x, y)
    local player =
        windower.ffxi.get_mob_by_id(
            windower.ffxi.get_player().id
        )

    if not player then return 0 end

    local dx = x - player.x
    local dy = y - player.y

    return math.atan2(dx, dy) - 1.5708
end

function TurnToTarget()
    local target =
        windower.ffxi.get_mob_by_target('t')

    if not target then return end

    local desired =
        math.deg(
            HeadingTo(
                target.x,
                target.y
            )
        )

    if math.abs(PlayerH - desired) > 10 then
        windower.ffxi.turn(
            HeadingTo(
                target.x,
                target.y
            )
        )
    end
end

------------------------------------------------------------
-- ORIGIN DISTANCE
------------------------------------------------------------

function Origin_Distance(x, y, z)
    if not origin_x then
        return math.huge
    end

    if origin_z
        and z
        and math.abs(z - origin_z)
            > origin_z_tolerance
    then
        return math.huge
    end

    return math.sqrt(
        (x - origin_x)^2
        + (y - origin_y)^2
    )
end

function Set_Origin()
    local player =
        windower.ffxi.get_mob_by_id(
            windower.ffxi.get_player().id
        )

    if not player then return end

    origin_x = player.x
    origin_y = player.y
    origin_z = player.z

    path_last_distance       = nil
    path_last_progress_time  = nil
    path_stuck_alerted       = false
    origin_unreachable_since = nil

    windower.add_to_chat(
        2,
        'Origin set: ('
        .. math.floor(origin_x)
        .. ', '
        .. math.floor(origin_y)
        .. ') radius: '
        .. origin_radius
    )
end

function Path_To_Origin()
    if not origin_x then return end

    local player =
        windower.ffxi.get_mob_by_id(
            windower.ffxi.get_player().id
        )

    if not player then return end

    local distance =
        Origin_Distance(
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

        if (
            now - origin_unreachable_since
        ) >= ORIGIN_UNREACHABLE_TIMEOUT
        then
            windower.add_to_chat(
                2,
                '[Lazy] Origin unreachable for '
                .. math.floor(
                    ORIGIN_UNREACHABLE_TIMEOUT / 60
                )
                .. ' min -- re-anchoring origin here and retargeting.'
            )

            Set_Origin()
            return
        end

        if not path_stuck_alerted then
            windower.add_to_chat(
                167,
                '[Lazy] Origin unreachable at current elevation -- stopping autopath. '
                .. 'Will re-anchor here after '
                .. math.floor(
                    ORIGIN_UNREACHABLE_TIMEOUT / 60
                )
                .. ' min if still stuck.'
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
            or distance
                < path_last_distance
                    - PATH_STUCK_EPSILON
        then
            path_last_distance =
                distance

            path_last_progress_time =
                now

            path_stuck_alerted =
                false

        elseif path_last_progress_time
            and (
                now - path_last_progress_time
            ) >= PATH_STUCK_TIMEOUT
        then
            windower.ffxi.run(false)

            if not path_stuck_alerted then
                windower.add_to_chat(
                    167,
                    '[Lazy] Stuck pathing to origin (no progress in '
                    .. PATH_STUCK_TIMEOUT
                    .. 's) -- stopping autopath.'
                )

                path_stuck_alerted = true
            end

            pathing_to_origin = false
            path_tick = 0

            return
        end

        path_tick =
            path_tick + 1

        if path_tick % 4 == 1 then
            windower.ffxi.run(false)

        elseif path_tick % 4 == 2 then
            windower.ffxi.turn(
                HeadingTo(
                    origin_x,
                    origin_y
                )
            )

        else
            windower.ffxi.run(true)
        end

    else
        windower.ffxi.run(false)

        pathing_to_origin       = false
        path_tick               = 0
        path_last_distance      = nil
        path_last_progress_time = nil
        path_stuck_alerted       = false
    end
end

------------------------------------------------------------
-- TARGETING HELPERS
------------------------------------------------------------

function Find_Named_Target(target_name)
    if not target_name
        or target_name == ''
    then
        return -1
    end

    local mob_array =
        windower.ffxi.get_mob_array()

    local candidates = {}

    for key, mob in pairs(mob_array) do
        if mob
            and mob.distance
            and mob.valid_target
            and mob.hpp
            and mob.hpp > 0
            and mob.name
            and mob.name ~= ''
        then
            local in_origin = true

            if origin_x
                and mob.x
            then
                in_origin =
                    Origin_Distance(
                        mob.x,
                        mob.y,
                        mob.z
                    ) <= origin_radius
            end

            if string.lower(mob.name)
                == string.lower(target_name)
                and in_origin
                and (
                    not targeting.only_unclaimed
                    or mob.claim_id == 0
                )
            then
                candidates[#candidates + 1] = {
                    key = key,
                    mob = mob,
                    dist = math.sqrt(
                        mob.distance
                    ),
                }
            end
        end
    end

    table.sort(
        candidates,
        function(a, b)
            return a.dist < b.dist
        end
    )

    if candidates[1] then
        return candidates[1].key
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
        if string.lower(name)
            == string.lower(monster)
        then
            return true
        end
    end

    return false
end

function Find_Nearest_Target()
    local mob_array =
        windower.ffxi.get_mob_array()

    local best_id = -1
    local best_distance = nil

    for key, mob in pairs(mob_array) do
        if mob
            and mob.distance
            and mob.valid_target
            and mob.hpp
            and mob.hpp > 0
            and mob.name
            and mob.name ~= ''
        then
            local in_origin = true

            if targeting.within_origin
                and origin_x
                and mob.x
            then
                in_origin =
                    Origin_Distance(
                        mob.x,
                        mob.y,
                        mob.z
                    ) <= origin_radius
            end

            local unclaimed = true

            if targeting.only_unclaimed then
                unclaimed =
                    mob.claim_id == 0
            end

            if Is_Targetable_Monster(mob.name)
                and in_origin
                and unclaimed
            then
                local distance =
                    math.sqrt(mob.distance)

                if not best_distance
                    or distance < best_distance
                then
                    best_id = key
                    best_distance = distance
                end
            end
        end
    end

    return best_id
end

------------------------------------------------------------
-- PARTY LEADER
------------------------------------------------------------

function Get_Party_Leader_ID()
    local party =
        windower.ffxi.get_party()

    if not party then
        return nil
    end

    if party.party1_leader
        and party.party1_leader ~= 0
    then
        return party.party1_leader
    end

    return nil
end

function Get_Party_Leader()
    local leader_id =
        Get_Party_Leader_ID()

    if leader_id then
        return windower.ffxi.get_mob_by_id(
            leader_id
        )
    end

    -- No party leader means we're solo.
    local player =
        windower.ffxi.get_player()

    if not player then
        return nil
    end

    local party =
        windower.ffxi.get_party()

    local count = 0

    for i = 0, 5 do
        local member =
            party and party['p' .. i]

        if member and member.name then
            count = count + 1
        end
    end

    if count <= 1 then
        return windower.ffxi.get_mob_by_id(
            player.id
        )
    end

    return nil
end

function Is_Party_Leader()
    local player =
        windower.ffxi.get_player()

    if not player then
        return false
    end

    local leader_id =
        Get_Party_Leader_ID()

    -- Solo = leader.
    if not leader_id then
        local party =
            windower.ffxi.get_party()

        local count = 0

        for i = 0, 5 do
            local member =
                party and party['p' .. i]

            if member and member.name then
                count = count + 1
            end
        end

        return count <= 1
    end

    return leader_id == player.id
end

------------------------------------------------------------
-- LEADER TARGET
------------------------------------------------------------

function Get_Leader_Target()
    local leader =
        Get_Party_Leader()

    if not leader then
        return nil
    end

    local player =
        windower.ffxi.get_player()

    -- We are the leader.
    if player
        and leader.id == player.id
    then
        local target =
            windower.ffxi.get_mob_by_target('t')

        if target
            and target.valid_target
            and target.hpp
            and target.hpp > 0
            and target.is_npc
        then
            return target
        end

        return nil
    end

    -- Follower: try leader's target index.
    if leader.target_index
        and leader.target_index > 0
    then
        local target =
            windower.ffxi.get_mob_by_index(
                leader.target_index
            )

        if target
            and target.valid_target
            and target.hpp
            and target.hpp > 0
            and target.is_npc
        then
            return target
        end
    end

    -- Fallback to battle target.
    local bt =
        windower.ffxi.get_mob_by_target('bt')

    if bt
        and bt.valid_target
        and bt.hpp
        and bt.hpp > 0
        and bt.is_npc
    then
        return bt
    end

    return nil
end

function Is_Leader_Engaged()
    local leader =
        Get_Party_Leader()

    if not leader then
        return false
    end

    return leader.status == 1
end

------------------------------------------------------------
-- TARGET MONITOR
------------------------------------------------------------

function Target_Monitor()
    while Start_Engine do
        local player =
            windower.ffxi.get_player()

        if player
            and player.status ~= 1
            and Is_Party_Leader()
            and not mp_resting
        then
            local target =
                windower.ffxi.get_mob_by_target('t')

            if target
                and target.valid_target
                and target.hpp
                and target.hpp > 0
            then
                local valid = true

                if settings.target
                    and settings.target ~= ''
                then
                    if string.lower(
                        target.name or ''
                    ) ~= string.lower(
                        settings.target
                    )
                    then
                        valid = false
                    end
                end

                if valid
                    and targeting.within_origin
                    and origin_x
                    and target.x
                then
                    if Origin_Distance(
                        target.x,
                        target.y,
                        target.z
                    ) > origin_radius
                    then
                        valid = false
                    end
                end

                if valid
                    and targeting.only_unclaimed
                    and target.claim_id ~= 0
                then
                    valid = false
                end

                if not valid then
                    windower.send_command(
                        'input /target <me>'
                    )
                end
            end
        end

        coroutine.sleep(0.5)
    end
end

------------------------------------------------------------
-- TARGETING
------------------------------------------------------------

function Targeting()
    while Start_Engine do
        local player =
            windower.ffxi.get_player()

        if player
            and player.status ~= 1
            and not mp_resting
        then
            local is_leader =
                Is_Party_Leader()

            ------------------------------------------------
            -- ASSIST MODE
            ------------------------------------------------

            if settings.assist
                and settings.assist ~= ''
                and not is_leader
            then
                windower.send_command(
                    'input /assist '
                    .. settings.assist
                )

                local target =
                    windower.ffxi.get_mob_by_target(
                        't'
                    )

                if target
                    and target.valid_target
                    and target.hpp
                    and target.hpp > 0
                then
                    if active_profile
                        and active_profile.auto_engage == false
                    then
                        windower.send_command(
                            'input /attack off'
                        )

                    elseif Is_Leader_Engaged() then
                        local distance =
                            target.distance
                            and math.sqrt(
                                target.distance
                            )

                        if distance
                            and distance <= 3
                        then
                            windower.ffxi.follow(0)

                            windower.send_command(
                                'input /attack on'
                            )

                            if not lockon_done then
                                windower.send_command(
                                    'input /lockon'
                                )

                                lockon_done = true
                            end
                        end
                    end
                end

            ------------------------------------------------
            -- PARTY LEADER / SOLO
            ------------------------------------------------

            elseif is_leader then

                if settings.autotarget then
                    local target_id = -1

                    if settings.target
                        and settings.target ~= ''
                    then
                        target_id =
                            Find_Named_Target(
                                settings.target
                            )
                    else
                        target_id =
                            Find_Nearest_Target()
                    end

                    if target_id > 0 then
                        pathing_to_origin = false
                        path_tick = 0

                        local mob =
                            windower.ffxi.get_mob_by_index(
                                target_id
                            )

                        if mob
                            and mob.valid_target
                            and mob.hpp
                            and mob.hpp > 0
                        then
                            local in_range = true

                            if origin_x
                                and mob.x
                            then
                                in_range =
                                    Origin_Distance(
                                        mob.x,
                                        mob.y,
                                        mob.z
                                    ) <= origin_radius
                            end

                            if in_range then
                                local distance =
                                    mob.distance
                                    and math.sqrt(
                                        mob.distance
                                    )

                                if distance
                                    and distance <= 3
                                then
                                    windower.ffxi.follow(0)

                                    local current =
                                        windower.ffxi.get_mob_by_target(
                                            't'
                                        )

                                    if not current
                                        or current.id ~= mob.id
                                    then
                                        windower.send_command(
                                            'input /target "'
                                            .. mob.name
                                            .. '"'
                                        )
                                    end

                                    if active_profile
                                        and active_profile.auto_engage ~= false
                                    then
                                        windower.send_command(
                                            'input /attack on'
                                        )

                                        if not lockon_done then
                                            windower.send_command(
                                                'input /lockon'
                                            )

                                            lockon_done = true
                                        end
                                    else
                                        windower.send_command(
                                            'input /attack off'
                                        )
                                    end

                                else
                                    windower.ffxi.follow(
                                        target_id
                                    )
                                end

                            else
                                Path_To_Origin()
                            end
                        end

                    else
                        Path_To_Origin()
                    end
                end

            ------------------------------------------------
            -- PARTY FOLLOWER
            ------------------------------------------------

            else
                local leader_target =
                    Get_Leader_Target()

                if leader_target then
                    local current =
                        windower.ffxi.get_mob_by_target(
                            't'
                        )

                    if not current
                        or current.id ~= leader_target.id
                    then
                        windower.send_command(
                            'input /target "'
                            .. leader_target.name
                            .. '"'
                        )
                    end

                    -- BACKLINE:
                    -- target the leader's target,
                    -- but never attack it.
                    if active_profile
                        and active_profile.auto_engage == false
                    then
                        windower.send_command(
                            'input /attack off'
                        )

                    -- MELEE FOLLOWER:
                    -- engage only when leader is engaged.
                    elseif Is_Leader_Engaged() then
                        local distance =
                            leader_target.distance
                            and math.sqrt(
                                leader_target.distance
                            )

                        if distance
                            and distance <= 3
                        then
                            windower.ffxi.follow(0)

                            windower.send_command(
                                'input /attack on'
                            )

                            if not lockon_done then
                                windower.send_command(
                                    'input /lockon'
                                )

                                lockon_done = true
                            end
                        else
                            local leader =
                                Get_Party_Leader()

                            if leader
                                and leader.index
                            then
                                windower.ffxi.follow(
                                    leader.index
                                )
                            end
                        end
                    end
                end
            end
        end

        coroutine.sleep(0.5)
    end
end

------------------------------------------------------------
-- FOLLOW MONITOR
------------------------------------------------------------

function Follow_Monitor()
    while Start_Engine do

        if mp_resting then
            windower.ffxi.follow(0)

        else
            local player =
                windower.ffxi.get_player()

            if player then
                if Is_Party_Leader() then
                    -- Leader never follows the monster
                    -- or another party member.
                    windower.ffxi.follow(0)

                elseif isCasting
                    or isBusy > 0
                then
                    windower.ffxi.follow(0)

                else
                    local leader =
                        Get_Party_Leader()

                    if leader
                        and leader.index
                    then
                        windower.ffxi.follow(
                            leader.index
                        )
                    else
                        windower.ffxi.follow(0)
                    end
                end
            end
        end

        coroutine.sleep(0.2)
    end
end

------------------------------------------------------------
-- DIRECT TARGET SET
------------------------------------------------------------

function setTarget(target, unlock)
    local player =
        windower.ffxi.get_player()

    if not player
        or not target
    then
        return false
    end

    packets.inject(
        packets.new('incoming', 0x058, {
            ['Player'] = player.id,
            ['Target'] = target.id,
            ['Player Index'] = player.index,
        })
    )

    if unlock then
        windower.send_command(
            'wait 1; input /lockon'
        )
    end

    return true
end

------------------------------------------------------------
-- SPELL / ABILITY HELPERS
------------------------------------------------------------

function Is_Blacklisted(name)
    if not name then return false end

    for _, blocked in ipairs(
        spell_blacklist or {}
    ) do
        if string.lower(name)
            == string.lower(blocked)
        then
            return true
        end
    end

    return false
end

function Is_Haste_Blacklisted(name)
    if not name then return false end

    for _, blocked in ipairs(
        haste_blacklist or {}
    ) do
        if string.lower(name)
            == string.lower(blocked)
        then
            return true
        end
    end

    return false
end

function Can_Cast_Spell(spell_name)
    if not spell_name
        or spell_name == ''
    then
        return false
    end

    local spell =
        res.spells:with(
            'name',
            spell_name
        )

    if not spell then return false end

    local player =
        windower.ffxi.get_player()

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

    if mp_resting then
        Stop_MP_Rest()
    end

    windower.send_command(
        'input /ma "'
        .. spell_name
        .. '" <t>'
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

    local player =
        windower.ffxi.get_player()

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

    if mp_resting then
        Stop_MP_Rest()
    end

    windower.send_command(
        'input /ma "'
        .. spell_name
        .. '" '
        .. target
    )

    isBusy = Action_Delay

    return true
end

function Cast_Ability(ability_name)
    if mp_resting then
        Stop_MP_Rest()
    end

    windower.send_command(
        'input /ja "'
        .. ability_name
        .. '" <me>'
    )

    isBusy = Action_Delay
end

------------------------------------------------------------
-- ENGINE
------------------------------------------------------------

function Engine()
    while Start_Engine do

        Update_Job_Profile()

        ----------------------------------------------------
        -- ACTION TIMER
        ----------------------------------------------------

        if isBusy > 0 then
            isBusy = isBusy - 0.1

            if isBusy < 0 then
                isBusy = 0
            end
        end

        ----------------------------------------------------
        -- MP REST
        ----------------------------------------------------

        MP_Rest_Tick()

        ----------------------------------------------------
        -- BACKLINE SAFETY
        ----------------------------------------------------

        Enforce_Backline_Rules()

        ----------------------------------------------------
        -- RESET LOCKON WHEN DISENGAGED
        ----------------------------------------------------

        local player =
            windower.ffxi.get_player()

        if player then
            if player.status ~= 1 then
                lockon_done = false

                if engaged_since then
                    engaged_since = nil
                end
            elseif not engaged_since then
                engaged_since = os.clock()
            end
        end

        ----------------------------------------------------
        -- DON'T LET MOVEMENT FIGHT RESTING
        ----------------------------------------------------

        if mp_resting then
            windower.ffxi.follow(0)
            windower.ffxi.run(false)
        end

        coroutine.sleep(0.1)
    end
end

------------------------------------------------------------
-- SKILLCHAIN MONITOR
------------------------------------------------------------

function SC_Monitor()
    while Start_Engine do
        -- Skillchain/magic-burst modules may maintain their
        -- own state. This monitor deliberately stays passive
        -- unless those modules expose their own tick function.
        coroutine.sleep(0.5)
    end
end

------------------------------------------------------------
-- BUFF SYSTEM
------------------------------------------------------------

function Buff_Tick()
    if not settings.buffs_active
        or not active_profile
    then
        return
    end

    if pending_cast
        and os.clock()
            - pending_cast.sent_at > 10
    then
        pending_cast = nil
    end

    if isBusy > 0
        or isCasting
        or pending_cast
    then
        return
    end

    local player =
        windower.ffxi.get_player()

    if not player then return end

    local now = os.clock()

    Update_Job_Profile()

    --------------------------------------------------------
    -- 1. DEBUFF LOGIC
    --------------------------------------------------------

    if active_profile.debuffs then
        Ensure_Debuff_Target()

        local target =
            windower.ffxi.get_mob_by_target('t')

        local pet =
            windower.ffxi.get_mob_by_target('pet')

        if target
            and target.hpp
            and target.hpp > 0
            and not Is_Blacklisted(target.name)
        then
            for _, debuff in ipairs(
                active_profile.debuffs
            ) do
                local names =
                    type(debuff.name) == 'table'
                    and debuff.name
                    or { debuff.name }

                local key = names[1]

                local last =
                    debuff_last_cast[key]

                local interval =
                    (debuff.interval or 1) * 60

                local pet_ok = true

                if debuff.require_no_pet
                    and pet
                then
                    pet_ok = false
                end

                if pet_ok
                    and (
                        not last
                        or now - last >= interval
                    )
                then
                    if debuff.use_ability_before
                        and Can_Cast_Ability(
                            debuff.use_ability_before
                        )
                    then
                        Cast_Ability(
                            debuff.use_ability_before
                        )

                        return
                    end

                    local spell_target =
                        debuff.target
                        or '<t>'

                    for _, name in ipairs(names) do
                        local spell =
                            res.spells:with(
                                'name',
                                name
                            )

                        if spell
                            and Cast_Spell_On(
                                name,
                                spell_target
                            )
                        then
                            pending_cast = {
                                store = debuff_last_cast,
                                key = key,
                                spell_id = spell.id,
                                sent_at = now,
                            }

                            if debuff.use_ability_after then
                                local follow_up =
                                    debuff.use_ability_after

                                coroutine.schedule(
                                    function()
                                        coroutine.sleep(
                                            2.5
                                        )

                                        if Can_Cast_Ability(
                                            follow_up
                                        ) then
                                            Cast_Ability(
                                                follow_up
                                            )
                                        end
                                    end,
                                    0
                                )
                            end

                            return
                        end
                    end
                end
            end
        end
    end

    --------------------------------------------------------
    -- 2. JOB ABILITIES
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
    -- 3. SELF BUFFS
    --------------------------------------------------------

    for _, buff in ipairs(
        active_profile.self_buffs or {}
    ) do
        local names =
            type(buff.name) == 'table'
            and buff.name
            or { buff.name }

        local key = names[1]

        local interval =
            (buff.interval or 20) * 60

        local last =
            self_buff_last_cast[key]

        local buff_ok = true

        if buff.require_buff
            and not buffactive[
                buff.require_buff
            ]
        then
            buff_ok = false
        end

        if buff_ok
            and (
                not last
                or now - last >= interval
            )
        then
            for _, name in ipairs(names) do
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

    --------------------------------------------------------
    -- 4. SELF ABILITIES
    --------------------------------------------------------

    local self_ability_list = {}

    for _, ab in ipairs(
        active_profile.self_abilities or {}
    ) do
        self_ability_list[
            #self_ability_list + 1
        ] = ab
    end

    do
        local sub = player.sub_job

        if haste_samba_active
            and sub
            and subjob_abilities
            and subjob_abilities[sub]
        then
            for _, ab in ipairs(
                subjob_abilities[sub]
            ) do
                self_ability_list[
                    #self_ability_list + 1
                ] = ab
            end
        end
    end

    for _, ab in ipairs(
        self_ability_list
    ) do
        local interval =
            (ab.interval or 20) * 60

        local last =
            self_ability_last_cast[ab.name]

        local due =
            not last
            or now - last >= interval

        if due then
            local pet_ok = true
            local mp_ok = true

            local pet =
                windower.ffxi.get_mob_by_target(
                    'pet'
                )

            if ab.require_pet
                and not pet
            then
                pet_ok = false

            elseif ab.max_pet_hpp
                and pet
                and pet.hpp
                and pet.hpp > ab.max_pet_hpp
            then
                pet_ok = false

            elseif ab.min_pet_hpp
                and pet
                and pet.hpp
                and pet.hpp < ab.min_pet_hpp
            then
                pet_ok = false
            end

            if ab.max_mp_percent
                and player.vitals
                and player.vitals.mpp
            then
                if player.vitals.mpp
                    > ab.max_mp_percent
                then
                    mp_ok = false
                end
            end

            if pet_ok
                and mp_ok
                and Can_Cast_Ability(ab.name)
            then
                Cast_Ability(ab.name)

                self_ability_last_cast[
                    ab.name
                ] = now

                return
            end
        end
    end

    --------------------------------------------------------
    -- 5. ENTRUST BUFFS
    --------------------------------------------------------

    if active_profile.entrust_buffs then
        local me_zone =
            windower.ffxi.get_info().zone

        local party =
            windower.ffxi.get_party()

        for _, eb in ipairs(
            active_profile.entrust_buffs
        ) do
            local interval =
                (eb.interval or 1) * 60

            local last =
                entrust_last_cast[eb.spell]

            if not last
                or now - last >= interval
            then
                local chosen_target = nil

                if type(eb.targets) == 'table'
                    and eb.targets.jobs
                    and party
                then
                    for _, job in ipairs(
                        eb.targets.jobs
                    ) do
                        if chosen_target then
                            break
                        end

                        for _, key in ipairs({
                            'p0',
                            'p1',
                            'p2',
                            'p3',
                            'p4',
                            'p5'
                        }) do
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
                                and math.sqrt(
                                    m.mob.distance
                                ) <= 20
                            then
                                chosen_target =
                                    m.name

                                break
                            end
                        end
                    end
                end

                if chosen_target then
                    if Can_Cast_Ability(
                        eb.ability or 'Entrust'
                    )
                    then
                        Cast_Ability(
                            eb.ability or 'Entrust'
                        )

                        return
                    end

                    local spell =
                        res.spells:with(
                            'name',
                            eb.spell
                        )

                    if spell
                        and Cast_Spell_On(
                            eb.spell,
                            chosen_target
                        )
                    then
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

    --------------------------------------------------------
    -- 6. PARTY BUFFS
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

            local interval =
                (pb.interval or 6) * 60

            local range =
                pb.range or 20

            local targets = {}

            if pb.targets == 'ALL_PLAYERS' then
                if party then
                    for _, key in ipairs({
                        'p0',
                        'p1',
                        'p2',
                        'p3',
                        'p4',
                        'p5'
                    }) do
                        local m = party[key]

                        if m
                            and m.name
                            and m.mob
                            and m.mob.id
                            and m.zone == me_zone
                            and not m.mob.is_npc
                            and (
                                pb.self
                                or key ~= 'p0'
                            )
                            and not Is_Haste_Blacklisted(
                                m.name
                            )
                            and m.mob.distance
                            and math.sqrt(
                                m.mob.distance
                            ) <= range
                        then
                            targets[
                                #targets + 1
                            ] = m.name
                        end
                    end
                end

            elseif type(pb.targets) == 'table'
                and pb.targets.jobs
            then
                if party then
                    for _, key in ipairs({
                        'p0',
                        'p1',
                        'p2',
                        'p3',
                        'p4',
                        'p5'
                    }) do
                        local m = party[key]

                        if m
                            and m.name
                            and m.mob
                            and m.mob.id
                            and m.zone == me_zone
                            and not m.mob.is_npc
                            and (
                                pb.self
                                or key ~= 'p0'
                            )
                            and m.mob.distance
                            and math.sqrt(
                                m.mob.distance
                            ) <= range
                        then
                            for _, job in ipairs(
                                pb.targets.jobs
                            ) do
                                if m.main_job == job then
                                    targets[
                                        #targets + 1
                                    ] = m.name

                                    break
                                end
                            end
                        end
                    end
                end
            end

            for _, tname in ipairs(targets) do
                local cache_key =
                    spell_name
                    .. ':'
                    .. tname

                local last =
                    party_buff_last_cast[
                        cache_key
                    ]

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
    -- 7. HASTE HANDLING
    --------------------------------------------------------

    if active_profile.haste_active
        and not active_profile.party_buffs
    then
        local self_interval =
            (
                active_profile.haste_self_interval
                or 20
            ) * 60

        local self_last =
            haste_last_cast.me

        local haste_spell =
            active_profile.haste_spell
            or 'Haste II'

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
            (
                active_profile.haste_party_interval
                or 6
            ) * 60

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
                    'p0',
                    'p1',
                    'p2',
                    'p3',
                    'p4',
                    'p5'
                }) do
                    local m = party[key]

                    if m
                        and m.name
                        and m.mob
                        and m.mob.id
                        and key ~= 'p0'
                        and m.zone == me_zone
                        and not m.mob.is_npc
                        and not Is_Haste_Blacklisted(
                            m.name
                        )
                        and m.mob.distance
                        and math.sqrt(
                            m.mob.distance
                        ) <= 20
                    then
                        haste_targets[
                            #haste_targets + 1
                        ] = m.name
                    end
                end
            end
        end

        for _, tname in ipairs(
            haste_targets or {}
        ) do
            local last =
                haste_last_cast[tname]

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
    -- 8. REFRESH HANDLING
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
                'p0',
                'p1',
                'p2',
                'p3',
                'p4',
                'p5'
            }) do
                local m = party[key]

                if m
                    and m.name
                    and m.mob
                    and m.mob.id
                    and m.zone == me_zone
                    and not m.mob.is_npc
                    and m.mob.distance
                    and math.sqrt(
                        m.mob.distance
                    ) <= 20
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
                            'refresh:'
                            .. m.name

                        local last =
                            refresh_last_cast[
                                cache_key
                            ]

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
    local party =
        windower.ffxi.get_party()

    if not party then return false end

    for _, key in ipairs({
        'p0',
        'p1',
        'p2',
        'p3',
        'p4',
        'p5'
    }) do
        local m = party[key]

        if m then
            if m.main_job == 'WHM'
                or m.job == 'WHM'
            then
                return true
            end

            if m.mob
                and m.mob.main_job == 'WHM'
            then
                return true
            end
        end
    end

    return false
end

function Cure_Bot_Tick()
    if not settings.cure_active
        or not active_profile
    then
        return
    end

    Update_Job_Profile()

    local cure_active =
        active_profile.cure_bot_active

    if current_job == 'SCH'
        and active_profile.cure_bot_if_no_whm
    then
        cure_active =
            not Party_Has_WHM()
    end

    if cure_active
        and active_profile.cure_bot_requires_buff
    then
        cure_active =
            buffactive[
                active_profile.cure_bot_requires_buff
            ]
            and true
            or false
    end

    local failsafe = false

    if not cure_active
        and active_profile.emergency_cure
    then
        cure_active = true
        failsafe = true
    end

    if not cure_active then return end

    if pending_cast
        and os.clock()
            - pending_cast.sent_at > 10
    then
        pending_cast = nil
    end

    if isBusy > 0
        or isCasting
        or pending_cast
    then
        return
    end

    local player =
        windower.ffxi.get_player()

    if not player then return end

    local party =
        windower.ffxi.get_party()

    if not party then return end

    local worst_member
    local worst_hpp = 999

    for _, key in ipairs({
        'p0',
        'p1',
        'p2',
        'p3',
        'p4',
        'p5'
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

    local threshold =
        failsafe
        and (
            active_profile.emergency_cure_threshold
            or 25
        )
        or 75

    if not worst_member
        or worst_hpp > threshold
    then
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
        worst_member.hp
        / (worst_hpp / 100)

    local missing_hp =
        math.floor(
            max_hp - worst_member.hp
        )

    if missing_hp <= 0 then return end

    local target =
        target_name == player.name
        and '<me>'
        or target_name

    if failsafe then
        windower.add_to_chat(
            167,
            '[Lazy] Failsafe cure -- '
            .. target_name
            .. ' at '
            .. worst_hpp
            .. '% HP, no healer response'
        )
    end

    for _, tier in ipairs(
        active_profile.cure_tiers or {}
    ) do
        local min_m =
            tier.min_missing or 0

        local max_m =
            tier.max_missing or 999999

        if missing_hp >= min_m
            and missing_hp <= max_m
        then
            for _, spell_name in ipairs(
                tier.spells
            ) do
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

local tracked_trusts      = {}
local trust_resummon_last = {}

function Snapshot_Trusts()
    tracked_trusts = {}

    local party =
        windower.ffxi.get_party()

    if not party then return end

    for _, key in ipairs({
        'p0',
        'p1',
        'p2',
        'p3',
        'p4',
        'p5'
    }) do
        local m = party[key]

        if m
            and m.name
            and m.mob
            and m.mob.is_npc
        then
            tracked_trusts[
                #tracked_trusts + 1
            ] = m.name
        end
    end

    if #tracked_trusts > 0 then
        windower.add_to_chat(
            2,
            '[Lazy] Tracking trusts for resummon: '
            .. table.concat(
                tracked_trusts,
                ', '
            )
        )
    end
end

function Trust_Tick()
    if #tracked_trusts == 0 then
        return
    end

    if pending_cast
        and os.clock()
            - pending_cast.sent_at > 10
    then
        pending_cast = nil
    end

    if isBusy > 0
        or isCasting
        or pending_cast
    then
        return
    end

    local party =
        windower.ffxi.get_party()

    if not party then return end

    local present = {}

    for _, key in ipairs({
        'p0',
        'p1',
        'p2',
        'p3',
        'p4',
        'p5'
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

    for _, name in ipairs(
        tracked_trusts
    ) do
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
                    '[Lazy] Resummoning trust: '
                    .. name
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
-- BUFF LIST CONVERTER
------------------------------------------------------------

function convert_buff_list(bufflist)
    local buffs = {}

    for _, buff_id in pairs(
        bufflist or {}
    ) do
        local buff =
            res.buffs[buff_id]

        if buff then
            if buff.english then
                buffs[buff.english] =
                    (
                        buffs[buff.english]
                        or 0
                    ) + 1
            end

            buffs[buff_id] =
                (
                    buffs[buff_id]
                    or 0
                ) + 1
        end
    end

    return buffs
end

------------------------------------------------------------
-- INIT
------------------------------------------------------------

Update_Job_Profile()