require('chat')
require('logger')
require('tables')
config = require('config')
res = require('resources')
packets = require('packets')
-- MODULES & FALLBACK DEFINITIONS 
dofile(windower.addon_path .. 'skillchain.lua')
dofile(windower.addon_path .. 'magicburst.lua')
dofile(windower.addon_path .. 'DNCQueen.lua')
dofile(windower.addon_path .. 'TargetLogic.lua')
dofile(windower.addon_path .. 'JobLogic.lua')
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
local PATH_STUCK_TIMEOUT = 8
local PATH_STUCK_EPSILON = 1
origin_unreachable_since = nil
local ORIGIN_UNREACHABLE_TIMEOUT = 600
-- COMBAT STATE 
local trust_ws_countdown = 0
lockon_done = false
ws_index = 1
PlayerH = 0
local engaged_since = nil
is_resting = false
-- DNC rotation state (dnc_flourish_pending, DNC_WALTZ_TIERS) and
-- Try_DNC_Actions() now live in DNCQueen.lua.
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
last_damage_source_id = nil
last_damage_taken_time = nil
local last_damage_kind = nil
local death_reported = false
-- Aggro queue: ids of things that have hit us that AREN'T our current
-- <t>. Adds go on the end as they hit us; we don't touch them while our
-- current target is still alive -- finish that fight first, then work
-- through whoever else started swinging on us, oldest first.
aggro_queue = {}
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
        last_damage_taken_time = nil
        last_damage_kind = nil
        death_reported = false
        aggro_queue = {}
        last_party_damage_to_target = nil
        damage_watch_target_id = nil
        party_activity = {}
        temp_assist_mob_id = nil
        is_resting = false
        -- DEFAULT MODE: if nobody's explicitly picked leader or
        -- follower (no assist target set, autotarget off), assume
        -- leader. Checked once here, at startup. Deliberately does
        -- NOT touch autotarget when assist is already set -- that's
        -- follower mode correctly sitting with autotarget off, and
        -- stomping it here would undo what //lazy follower set on
        -- purpose and break the atomic leader/follower invariant.
        if settings.assist == '' and not settings.autotarget then
            settings.autotarget = true
            windower.add_to_chat(207, '[Lazy] No mode selected -- defaulting to leader.')
        end
        Update_Job_Profile()
        Snapshot_Trusts()
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
        windower.add_to_chat(11, 'Rest: ' .. tostring(settings.rest_active))
        local mode = 'OFF (neither leader nor follower)'
        if settings.assist ~= '' then
            mode = 'FOLLOWER (assisting ' .. settings.assist .. ')'
        elseif settings.autotarget then
            mode = 'LEADER'
        end
        windower.add_to_chat(11, 'Mode: ' .. mode)
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
    -- LEADER / FOLLOWER 
    --
    -- Two atomic mode switches, on top of the existing granular
    -- assist/autotarget commands -- the actual bug this fixes is that
    -- assist and autotarget were two separate flags you had to keep in
    -- sync by hand, and a stale saved assist value from a previous
    -- session would silently win (Targeting() checks assist first),
    -- leaving autotarget's on/off state meaningless without you
    -- realizing it. These two commands always set BOTH flags together,
    -- so there's no in-between state to get stuck in.
    if command == 'leader' then
        settings.assist = ''
        settings.autotarget = true
        windower.add_to_chat(3, '[Lazy] Leader mode -- autotarget on, assist cleared.')
        return
    end
    if command == 'follower' then
        local name = args[2]
        if not name or name == '' then
            windower.add_to_chat(167, '[Lazy] Follower mode needs a name: //lazy follower <name>')
            return
        end
        settings.assist = name
        settings.autotarget = false
        windower.add_to_chat(3, '[Lazy] Follower mode -- assisting ' .. name .. ', autotarget off.')
        windower.send_command('input /assist ' .. name)
        if active_profile and active_profile.auto_engage == false then
            windower.send_command('wait 0.4; input /attack off')
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
    if command == 'rest' then
        settings.rest_active = (args[2] ~= 'off')
        windower.add_to_chat(3, 'Rest: ' .. tostring(settings.rest_active))
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
-- HEADING / MOVEMENT 
function HeadingTo(x, y)
    local player = windower.ffxi.get_mob_by_id(windower.ffxi.get_player().id)
    if not player then return 0 end
    local dx = x - player.x
    local dy = y - player.y
    return math.atan2(dx, dy) - 1.5708
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