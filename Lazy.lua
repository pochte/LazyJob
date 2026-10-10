-- LAZY
require('chat')
require('logger')
require('tables')
config = require('config')
res = require('resources')
packets = require('packets')
-- MODULES
dofile(windower.addon_path .. 'Logic/skillchain.lua')
dofile(windower.addon_path .. 'Logic/magicburst.lua')
dofile(windower.addon_path .. 'Logic/dnc_logic.lua')
dofile(windower.addon_path .. 'debug/Debug.lua')
dofile(windower.addon_path .. 'Logic/TargetLogic.lua')
dofile(windower.addon_path .. 'Logic/JobLogic.lua')
dofile(windower.addon_path .. 'Logic/HealBuffLogic.lua')
dofile(windower.addon_path .. 'Logic/TrustLogic.lua')
dofile(windower.addon_path .. 'Logic/RestLogic.lua')
dofile(windower.addon_path .. 'settings.lua')
-- FALLBACK STRUCTURES
ws_sc_starter = ws_sc_starter or {}
ws_sc_closers = ws_sc_closers or {}
needed_buffs = needed_buffs or {}
food = food or nil
spell_blacklist = spell_blacklist or {}
magic_burst_blacklist = magic_burst_blacklist or {}
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
origin_x = nil
origin_y = nil
origin_z = nil
origin_radius = 15
origin_z_tolerance = 15
pathing_to_origin = false
path_tick = 0
local last_known_pos = nil
local move_threshold = 0.05
path_last_distance = nil
path_last_progress_time = nil
path_stuck_alerted = false
PATH_STUCK_TIMEOUT = 8
PATH_STUCK_EPSILON = 1
origin_unreachable_since = nil
ORIGIN_UNREACHABLE_TIMEOUT = 600
-- COMBAT STATE
local trust_ws_countdown = 0
lockon_done = false
ws_index = 1
PlayerH = 0
engaged_since = nil
is_resting = false
-- CAST TRACKING
self_buff_last_cast = {}
self_ability_last_cast = {}
haste_last_cast = {}
debuff_last_cast = {}
dispel_last_cast = {}
mob_spell_last_cast = {}
refresh_last_cast = {}
party_buff_last_cast = {}
entrust_last_cast = {}
pending_cast = nil
-- JOB STATE
current_job = nil
active_profile = nil
-- JOB PROFILES
JOB_PROFILES = {}
local profile_list = {'RDM', 'GEO', 'BLM', 'SCH', 'DNC', 'NIN', 'WHM', 'WAR', 'THF', 'COR', 'BRD', 'DEFAULT'} ---add your job here if not already done. 
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
JOB_PROFILES.DEFAULT = JOB_PROFILES.DEFAULT or {}
active_profile = JOB_PROFILES.DEFAULT
-- BACKLINE & DISENGAGE OVERRIDES
local function Enforce_Backline_Rules()
    local player = windower.ffxi.get_player()
    if not player or not active_profile then
        return
    end
    if player.status == 1 and active_profile.auto_engage == false then
        windower.send_command('input /attack off')
    end
end
function Ensure_Debuff_Target()
    local player = windower.ffxi.get_player()
    if not player or not active_profile then
        return
    end
    if (active_profile.debuffs or active_profile.magic_burst)
        and active_profile.auto_engage == false
        and not windower.ffxi.get_mob_by_target('t')
    then
        windower.send_command(
            'input /target <p1>; wait 0.2; input /target <bt>'
        )
    end
end
-- MOVEMENT DETECTION
local last_move_sample = 0
local last_move_result = false
function Is_Moving()
    local now = os.clock()
    if now - last_move_sample < 0.25 then
        return last_move_result
    end
    local player = windower.ffxi.get_player()
    if not player then
        return false
    end
    local mob = windower.ffxi.get_mob_by_id(player.id)
    if not mob then
        return false
    end
    local moving = false
    if last_known_pos then
        local dx = mob.x - last_known_pos.x
        local dy = mob.y - last_known_pos.y
        if (dx * dx + dy * dy) > (move_threshold * move_threshold) then
            moving = true
        end
    end
    last_known_pos = {
        x = mob.x,
        y = mob.y
    }
    last_move_sample = now
    last_move_result = moving
    return moving
end
-- JOB PROFILE
function Update_Job_Profile()
    local player = windower.ffxi.get_player()
    if not player or not player.main_job then
        return
    end
    local job = player.main_job
    if job == current_job then
        return
    end
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
    windower.add_to_chat(
        2,
        '[Lazy] Main job: ' .. job
    )
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
    rest_active = true,     
}
settings = config.load(defaults)

-- INCOMING PACKETS
windower.register_event('incoming chunk', function(id, data)
    if id ~= 0x028 then
        return
    end
    local action = packets.parse('incoming', data)
    local player = windower.ffxi.get_player()
    if not player or action.Actor ~= player.id then
        return
    end
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
last_damage_source_id = nil
last_damage_taken_time = nil
local last_damage_kind = nil
local death_reported = false
-- AGGRO QUEUE
aggro_queue = {}
local AGGRO_QUEUE_CAP = 10
local function Resolve_Attack_Name(param)
    if not param or param == 0 then
        return nil
    end
    local hit =
        res.monster_abilities[param]
        or res.spells[param]
        or res.weapon_skills[param]
        or res.job_abilities[param]
    return hit and hit.en or nil
end
windower.register_event('incoming chunk', function(id, data)
    if id ~= 0x028 then
        return
    end
    local action = packets.parse('incoming', data)
    local player = windower.ffxi.get_player()
    if not player then
        return
    end
    local current = windower.ffxi.get_mob_by_target('t')
    local current_id = current and current.id
    local target_count = action['Target Count'] or 1
    for t = 1, target_count do
        if action['Target ' .. t .. ' ID'] == player.id then
            local reaction = action['Target ' .. t .. ' Action 1 Reaction']
            if reaction == 0 then
                local actor_id = action.Actor
                if Is_Party_Member(actor_id) then
                    break
                end
                local actor = windower.ffxi.get_mob_by_id(actor_id)
                last_damage_source =
                    actor and actor.name
                    or last_damage_source
                    or 'something unseen'
                last_damage_source_id = actor_id
                last_damage_taken_time = os.clock()
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
                local cause = last_damage_source or 'unknown causes'
                if last_damage_kind then
                    cause = cause .. ' (' .. last_damage_kind .. ')'
                elseif last_damage_source then
                    cause = cause .. ' (melee)'
                end
                windower.add_to_chat(
                    167,
                    '[Lazy] You died -- killed by ' ..
                    cause ..
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

-- OUTGOING PACKETS
windower.register_event('outgoing chunk', function(id, data)
    if id ~= 0x015 then
        return
    end
    local action = packets.parse('outgoing', data)
    PlayerH = action.Rotation
end)
-- STATUS CHANGE LISTENERS
windower.register_event('status change', function(new_status_id)
    if new_status_id == 1 then
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
        print('//lazy debug on/off')
        print('//lazy leader')
        print('//lazy follower <player>')
        print('//lazy autotarget on/off')
        print('//lazy target <name>')
        print('//lazy fight')
        print('//lazy assist <player>')
        print('//lazy buffs on/off')
        print('//lazy cure on/off')
        print('//lazy rest on/off')
        print('//lazy range <yalms>')
        print('//lazy retrust')
        return
    end  

    -- DEBUG  
    if command == 'debug' then
        local state = args[2]
        if state == 'on' then
            Debug.Set_Enabled(true)
            windower.add_to_chat(207, '[Lazy] Debug: ON')
        elseif state == 'off' then
            Debug.Set_Enabled(false)
            windower.add_to_chat(207, '[Lazy] Debug: OFF')
        else
            windower.add_to_chat(207, '[Lazy] Debug is ' .. (Debug.enabled and 'ON' or 'OFF'))
        end
        return
    end  

    -- START  
    if command == 'start' then
        local player = windower.ffxi.get_player()
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
        if Start_Engine then
            return
        end
        windower.add_to_chat(
            2,
            '....Starting Lazy Helper....'
        )
        Set_Origin()

        -- RESET TARGETLOGIC STATE
        if Clear_Combat_Target then
            Clear_Combat_Target()
        end
        lockon_done = false
        Start_Engine = true
        self_buff_last_cast = {}
        self_ability_last_cast = {}
        haste_last_cast = {}
        debuff_last_cast = {}
        refresh_last_cast = {}
        party_buff_last_cast = {}
        entrust_last_cast = {}
        dispel_last_cast = {}
        mob_spell_last_cast = {}
        path_last_distance = nil
        path_last_progress_time = nil
        path_stuck_alerted = false
        origin_unreachable_since = nil
        last_damage_source = nil
        last_damage_source_id = nil
        last_damage_taken_time = nil
        last_damage_kind = nil
        death_reported = false
        aggro_queue = {}
        last_party_damage_to_target = nil
        damage_watch_target_id = nil
        party_activity = {}
        temp_assist_mob_id = nil
        is_resting = false
        -- DEFAULT MODE
        if settings.assist == '' and not settings.autotarget then
            settings.autotarget = true
            windower.add_to_chat(
                207,
                '[Lazy] No mode selected -- defaulting to leader.'
            )
        end
        -- JOB / TRUST INITIALIZATION
        Update_Job_Profile()
        Snapshot_Trusts()
        -- ENGINE COROUTINES
        coroutine.schedule(Engine, 0)
        coroutine.schedule(SC_Monitor, 0)
        coroutine.schedule(Target_Monitor, 0)
        coroutine.schedule(Targeting, 0)
        coroutine.schedule(Follow_Monitor, 0)
        coroutine.schedule(Buff_Monitor, 0)
        coroutine.schedule(Cure_Monitor, 0)
        coroutine.schedule(Rest_Monitor, 0)
        coroutine.schedule(Trust_Monitor, 0)
        coroutine.schedule(Death_Monitor, 0)
        coroutine.schedule(Engagement_Sync, 0)
        coroutine.schedule(Combat_Stall_Monitor, 0)
        return
    end  
    -- STOP  
    if command == 'stop' then
        windower.add_to_chat(
            2,
            '....Stopping Lazy Helper....'
        )
        Start_Engine = false
        if Clear_Combat_Target then
            Clear_Combat_Target()
        end
        return
    end  
    -- RELOAD  
    if command == 'reload' then
        windower.add_to_chat(
            2,
            '....Reloading Config....'
        )
        config.reload(settings)
        dofile(windower.addon_path .. 'settings.lua')
        return
    end  
    -- SAVE  
    if command == 'save' then
        local player = windower.ffxi.get_player()
        if player then
            config.save(settings, player.name)
        end
        return
    end  
    -- SHOW
    if command == 'show' then
        Update_Job_Profile()
        local mode = 'OFF (neither leader nor follower)'
        if settings.assist ~= '' then
            mode = 'FOLLOWER (assisting ' .. settings.assist .. ')'
        elseif settings.autotarget then
            mode = 'LEADER'
        end
        local lines = {
            'Main job: ' .. tostring(current_job),
            'Assist: ' .. (settings.assist ~= '' and settings.assist or 'OFF'),
            'Autotarget: ' .. tostring(settings.autotarget),
            'Spell: ' .. settings.spell,
            'Use Spell: ' .. tostring(settings.spell_active),
            'Weaponskill: ' .. settings.weaponskill,
            'Use Weaponskill: ' .. tostring(settings.weaponskill_active),
            'Target: ' .. settings.target,
            'Buffs: ' .. tostring(settings.buffs_active),
            'Cure Bot: ' .. tostring(settings.cure_active),
            'Rest: ' .. tostring(settings.rest_active),
            'Mode: ' .. mode,
        }
        for _, line in ipairs(lines) do
            windower.add_to_chat(11, line)
        end
        return
    end
    -- AUTOTARGET  
    if command == 'autotarget' then
        settings.autotarget = (args[2] == 'on')
        windower.add_to_chat(
            3,
            'Autotarget: ' .. tostring(settings.autotarget)
        )
        return
    end  
    -- TARGET  
    if command == 'target' then
        settings.target = args[2] or ''
        if settings.target == '' then
            windower.add_to_chat(2, '[Lazy] Named target cleared -- back to the whitelist.')
        end
        return
    end
    -- FIGHT
    if command == 'fight' then
        -- Grabs whatever mob is currently on <t> and locks Lazy onto
        -- that exact name going forward -- same mechanism as //lazy
        -- target, just auto-filled from your current target instead
        -- of typed by hand.
        local player = windower.ffxi.get_player()
        local current = windower.ffxi.get_mob_by_target('t')

        if not current or not current.valid_target or not current.hpp or current.hpp <= 0 then
            windower.add_to_chat(167, '[Lazy] No valid target selected -- target the mob you want first, then //lazy fight.')
            return
        end
        if player and current.id == player.id then
            windower.add_to_chat(167, "[Lazy] That's you. Target a monster first.")
            return
        end
        if Is_Party_Member(current.id) then
            windower.add_to_chat(167, "[Lazy] That's a party member/trust, not a monster.")
            return
        end

        settings.target = current.name
        windower.add_to_chat(3, "[Lazy] Now locked onto '" .. current.name .. "' -- //lazy target (no name) clears it.")
        return
    end
    -- ASSIST  
    if command == 'assist' then
        settings.assist = args[2] or ''
        windower.add_to_chat(
            2,
            'Assist: ' ..
            (settings.assist ~= '' and settings.assist or 'OFF')
        )
        if settings.assist ~= '' then
            windower.send_command(
                'input /assist ' .. settings.assist
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
    -- LEADER  
    if command == 'leader' then
        settings.assist = ''
        settings.autotarget = true
        windower.add_to_chat(
            3,
            '[Lazy] Leader mode -- autotarget on, assist cleared.'
        )
        return
    end  
    -- FOLLOWER  
    if command == 'follower' then
        local name = args[2]
        if not name or name == '' then
            windower.add_to_chat(
                167,
                '[Lazy] Follower mode needs a name: //lazy follower <name>'
            )
            return
        end
        settings.assist = name
        settings.autotarget = false
        windower.add_to_chat(
            3,
            '[Lazy] Follower mode -- assisting ' ..
            name ..
            ', autotarget off.'
        )
        windower.send_command(
            'input /assist ' .. name
        )
        if active_profile
            and active_profile.auto_engage == false
        then
            windower.send_command(
                'wait 0.4; input /attack off'
            )
        end
        return
    end  
    -- BUFFS  
    if command == 'buffs' then
        settings.buffs_active = (args[2] ~= 'off')
        windower.add_to_chat(
            3,
            'Buffs: ' .. tostring(settings.buffs_active)
        )
        return
    end  
    -- CURE  
    if command == 'cure' then
        settings.cure_active = (args[2] ~= 'off')
        windower.add_to_chat(
            3,
            'Cure Bot: ' .. tostring(settings.cure_active)
        )
        return
    end  
    -- REST  
    if command == 'rest' then
        settings.rest_active = (args[2] ~= 'off')
        windower.add_to_chat(
            3,
            'Rest: ' .. tostring(settings.rest_active)
        )
        return
    end  
    -- RANGE  
    if command == 'range' then
        local value = tonumber(args[2])
        if value then
            origin_radius = value
            windower.add_to_chat(
                2,
                'Origin radius set to ' ..
                origin_radius ..
                ' yalms'
            )
        else
            windower.add_to_chat(
                2,
                'Current radius: ' .. origin_radius
            )
        end
        return
    end  
    -- RETRUST  
    if command == 'retrust' then
        Snapshot_Trusts()
        return
    end
end)
-- HEADING / MOVEMENT
function HeadingTo(x, y)
    local player =
        windower.ffxi.get_mob_by_id(
            windower.ffxi.get_player().id
        )
    if not player then
        return 0
    end
    local dx = x - player.x
    local dy = y - player.y
    return math.atan2(dx, dy) - 1.5708
end
-- MAIN ENGINE
function Engine()
    while Start_Engine do
        local player = windower.ffxi.get_player()
        if player then
            Update_Job_Profile()
            Enforce_Backline_Rules()
            buffactive =
                convert_buff_list(player.buffs or {})
            if isBusy < 1 then
                Safe_Tick('Combat', Combat)
            else
                isBusy = isBusy - 1
            end
        end
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
                buffs[buff.english] =
                    (buffs[buff.english] or 0) + 1
            end
            buffs[buff_id] =
                (buffs[buff_id] or 0) + 1
        end
    end
    return buffs
end
-- INIT
Update_Job_Profile()