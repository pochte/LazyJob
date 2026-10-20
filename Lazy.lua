--Lazy Lua--
require('chat')
require('logger')
require('tables')
config = require('config')
res = require('resources')
packets = require('packets')
-- MODULES & FALLBACK DEFINITIONS
dofile(windower.addon_path .. 'settings.lua')
dofile(windower.addon_path .. 'Logic/skillchain.lua')
dofile(windower.addon_path .. 'Logic/magicburst.lua')
dofile(windower.addon_path .. 'Logic/joblogic.lua')
local loaded_job_logic = {}
-- Jobs that load HealBuffLogic.lua (cure bot, buffs, debuffs, dispel,
-- haste, refresh) and RestLogic.lua. Everything else keeps the inline
-- Buff_Tick / cure code in this file. Edit this list to change it.
local MAGE_LOGIC_JOBS = {
WHM = true, RDM = true, BLM = true, GEO = true, SCH = true, SMN = true,
}
-- Loaded once per session, on demand, from Update_Job_Profile().
-- These files redefine functions this file also defines, so they MUST be
-- loaded at runtime (after this whole file has run) for them to win.
function Load_Profile_Logic(profile)
if not profile then
return
end
-- DNC logic
if profile == 'DNC' and not loaded_job_logic.DNC then
dofile(windower.addon_path .. 'Logic/dnc_logic.lua')
loaded_job_logic.DNC = true
end
-- COR rolls
if profile == 'COR' and not loaded_job_logic.COR then
dofile(windower.addon_path .. 'Logic/rolls.lua')
loaded_job_logic.COR = true
end
-- Mage jobs: healing/buff logic + resting
if MAGE_LOGIC_JOBS[profile] and not loaded_job_logic.MAGE then
dofile(windower.addon_path .. 'Logic/HealBuffLogic.lua')
dofile(windower.addon_path .. 'Logic/RestLogic.lua')
loaded_job_logic.MAGE = true
Start_Rest_Monitor()
end
end
-- RestLogic.lua's Rest_Monitor runs once per //lazy start, and only once
-- the mage logic has been loaded.
rest_monitor_started = false
function Start_Rest_Monitor()
if Start_Engine and Rest_Monitor and not rest_monitor_started then
rest_monitor_started = true
coroutine.schedule(Rest_Monitor, 0)
end
end
-- Fallback structures to prevent nil comparison errors
ws_sc_starter = ws_sc_starter or {}
ws_sc_closers = ws_sc_closers or {}
needed_buffs = needed_buffs or {}
food = food or nil
spell_blacklist = spell_blacklist or {}
haste_blacklist = haste_blacklist or {}
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
-- These are shared with TargetLogic.lua, so they must not be local.
origin_x = nil
origin_y = nil
origin_z = nil
origin_radius = 10
origin_z_tolerance = 15
pathing_to_origin = false
path_tick = 0
path_last_distance = nil
path_last_progress_time = nil
path_stuck_alerted = false
PATH_STUCK_TIMEOUT = 8
PATH_STUCK_EPSILON = 1
origin_unreachable_since = nil
ORIGIN_UNREACHABLE_TIMEOUT = 600
local last_known_pos = nil
local move_threshold = 0.05
-- COMBAT STATE
local trust_ws_countdown = 0
lockon_done = false
local ws_index = 1
PlayerH = 0
-- DNC
dnc_flourish_pending = false  -- global: Combat, dnc_logic.lua and Try_DNC_Actions share it
local DNC_WALTZ_TIERS = {
'Curing Waltz V',
'Curing Waltz IV',
'Curing Waltz III',
'Curing Waltz II',
'Curing Waltz',
}
-- CAST TRACKING
-- Global: HealBuffLogic.lua reads and writes these.
self_buff_last_cast = {}
self_ability_last_cast = {}
haste_last_cast = {}
debuff_last_cast = {}
refresh_last_cast = {}
party_buff_last_cast = {}
entrust_last_cast = {}
entrust_ability_last_attempt = {}
entrust_ability_last_success = {}
dispel_last_cast = {}
mob_spell_last_cast = {}
-- Shared with TrustLogic.lua; must be global.
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
local file = io.open(path, 'r')
if file then
file:close()
-- Load the profile and capture any syntax/runtime errors.
local ok, result = pcall(dofile, path)
if not ok then
windower.add_to_chat(
167,
'[Lazy] ERROR loading ' .. job .. '.lua: '
.. tostring(result)
)
windower.add_to_chat(
167,
'[Lazy] ' .. job
.. ' profile NOT loaded. Fix the error above, '
.. 'then run //lua reload lazy.'
)
elseif type(JOB_PROFILES[job]) ~= 'table' then
windower.add_to_chat(
167,
'[Lazy] ERROR: ' .. job
.. '.lua did not define JOB_PROFILES.'
.. job .. ' as a table.'
)
end
else
windower.add_to_chat(
123,
'[Lazy] Profile not found: ' .. job
.. '.lua — using DEFAULT if available.'
)
end
end
-- Ensure a fallback profile always exists.
JOB_PROFILES.DEFAULT = JOB_PROFILES.DEFAULT or {}
active_profile = JOB_PROFILES.DEFAULT
-- NOTE: Ensure_Debuff_Target() now lives in TargetLogic.lua (global).
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
if (dx * dx + dy * dy) > (move_threshold * move_threshold) then
moving = true
end
end
last_known_pos = {
x = mob.x,
y = mob.y,
}
return moving
end
-- JOB PROFILE
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
refresh_last_cast = {}
party_buff_last_cast = {}
entrust_last_cast = {}
entrust_ability_last_attempt = {}
entrust_ability_last_success = {}
dispel_last_cast = {}
mob_spell_last_cast = {}
Load_Profile_Logic(job)
windower.add_to_chat(2, '[Lazy] Main job: ' .. job)
end
-- PROFILE HELPERS
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
rest_active = true,
}
settings = config.load(defaults)
-- LOAD SHARED LOGIC MODULES
-- TargetLogic.lua owns ALL targeting: selection, combat lock, origin/pathing,
-- follow/target monitors, damage tracking, aggro queue, Engagement_Sync.
-- TrustLogic.lua owns trust snapshots, tracking and resummoning.
-- Load them after shared state and settings have been initialized.
-- Debug.lua owns ALL debug logging/tracing and the /attack safety gate.
-- It must load before TargetLogic.lua, which calls Debug.* everywhere.
dofile(windower.addon_path .. 'debug/Debug.lua')
dofile(windower.addon_path .. 'Logic/TargetLogic.lua')
dofile(windower.addon_path .. 'Logic/TrustLogic.lua')
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
-- Damage tracking (last_damage_source, last_damage_source_id,
-- last_damage_kind) and the aggro queue are OWNED by TargetLogic.lua.
-- They are globals; Death_Monitor only reads them to report a cause.
local death_reported = false
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
'[Lazy] You died -- killed by ' .. cause .. '. Stopping Lazy.'
)
Start_Engine = false
end
else
death_reported = false
end
coroutine.sleep(0.5)
end
end
-- NOTE: Engagement_Sync() is defined once, in TargetLogic.lua.
-- It is only scheduled from here (see //lazy start).
-- OUTGOING PACKETS
windower.register_event('outgoing chunk', function(id, data)
if id ~= 0x015 then return end
local action = packets.parse('outgoing', data)
PlayerH = action.Rotation
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
print('//lazy buffs on/off')
print('//lazy cure on/off')
print('//lazy rest on/off')
print('//lazy range <yalms>')
print('//lazy burstmode   (BLM/SCH: nuke only during magic burst)')
print('//lazy freenuke    (BLM/SCH: tier IV and lower on the target, V/VI for burst)')
print('//lazy chainmode   (fire the full ordered ws_sc_chain)')
print('//lazy partychain  (continue any open skillchain with the best weaponskill)')
print('//lazy openmode    (opener + closers only)')
print('//lazy retrust')
print('//lazy join <name>   (same as them telling you the phrase)')
print('//lazy join cancel')
print('//lazy sync <name>   (level sync to that party member)')
print('//lazy sync off')
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
if Start_Engine then return end
windower.add_to_chat(2, '....Starting Lazy Helper....')
Set_Origin()
-- RESET TARGETLOGIC STATE
if Clear_Combat_Target then
Clear_Combat_Target()
end
lockon_done = false
Start_Engine = true
-- RESET CAST TRACKING
self_buff_last_cast = {}
self_ability_last_cast = {}
haste_last_cast = {}
debuff_last_cast = {}
refresh_last_cast = {}
party_buff_last_cast = {}
entrust_last_cast = {}
entrust_ability_last_attempt = {}
entrust_ability_last_success = {}
dispel_last_cast = {}
mob_spell_last_cast = {}
pending_cast = nil
-- RESET MOVEMENT / PATHING STATE
path_last_distance = nil
path_last_progress_time = nil
path_stuck_alerted = false
origin_unreachable_since = nil
-- RESET COMBAT / MONITOR STATE
Reset_Damage_Tracking()
death_reported = false
is_resting = false
rest_monitor_started = false
-- DEFAULT MODE
if settings.assist == '' and not settings.autotarget then
settings.autotarget = true
windower.add_to_chat(207, '[Lazy] No mode selected -- defaulting to leader.')
end
-- JOB / TRUST INITIALIZATION
Update_Job_Profile()
Start_Rest_Monitor()
-- Defaults only help people who know they exist, so say what they are.
if active_profile and active_profile.use_weaponskills then
windower.add_to_chat(207, '[Lazy] WS mode: ' .. Get_WS_Mode_Text() .. '  (//lazy chainmode, //lazy openmode, //lazy partychain)')
end
local start_nuke_text = Get_Nuke_Mode_Text and Get_Nuke_Mode_Text()
if start_nuke_text then
windower.add_to_chat(207, '[Lazy] Nuke mode: ' .. start_nuke_text .. '  (//lazy burstmode, //lazy freenuke)')
end
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
coroutine.schedule(Burst_Monitor, 0)
return
end
if command == 'stop' then
windower.add_to_chat(2, '....Stopping Lazy Helper....')
Start_Engine = false
return
end
if command == 'reload' then
-- Full addon reload (all files), not just config. Saves settings first,
-- and restarts afterward only if the engine was running.
windower.add_to_chat(2, '....Reloading Lazy....')
local player = windower.ffxi.get_player()
if player then
config.save(settings, player.name)
end
local restart = Start_Engine and '; wait 3; lazy start' or ''
windower.send_command('wait 0.5; lua reload lazy' .. restart)
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
windower.add_to_chat(11, 'WS mode: ' .. Get_WS_Mode_Text())
local nuke_text = Get_Nuke_Mode_Text and Get_Nuke_Mode_Text()
if nuke_text then
windower.add_to_chat(11, 'Nuke mode: ' .. nuke_text)
end
windower.add_to_chat(11, 'Target: ' .. settings.target)
windower.add_to_chat(11, 'Buffs: ' .. tostring(settings.buffs_active))
windower.add_to_chat(11, 'Cure Bot: ' .. tostring(settings.cure_active))
windower.add_to_chat(11, 'Rest: ' .. tostring(settings.rest_active))
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
windower.add_to_chat(
2,
'Origin radius set to ' .. origin_radius .. ' yalms'
)
else
windower.add_to_chat(2, 'Current radius: ' .. origin_radius)
end
return
end
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
if command == 'fight' then
-- Grabs whatever mob is on <t> and locks Lazy onto that exact name,
-- same as //lazy target but filled in from your current target.
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
if command == 'rest' then
settings.rest_active = (args[2] ~= 'off')
windower.add_to_chat(3, 'Rest: ' .. tostring(settings.rest_active))
return
end
if command == 'retrust' then
Snapshot_Trusts()
return
end
if command == 'burstmode' then
Update_Job_Profile()
Set_Nuke_Mode('burst')
return
end
if command == 'freenuke' then
Update_Job_Profile()
Set_Nuke_Mode('free')
return
end
if command == 'partychain' then
Update_Job_Profile()
Set_WS_Mode('party')
return
end
if command == 'chainmode' then
Update_Job_Profile()
Set_WS_Mode('chain')
return
end
if command == 'openmode' then
Update_Job_Profile()
Set_WS_Mode('open')
return
end
if command == 'join' then
if args[2] == 'cancel' then
Party_Join_Cancel()
return
end
if not raw_args[2] then
print('//lazy join <name>  |  //lazy join cancel')
return
end
Party_Join_Begin(raw_args[2])
return
end
if command == 'sync' then
if args[2] == 'off' then
Clear_Level_Sync()
return
end
if not raw_args[2] then
print('//lazy sync <name>  |  //lazy sync off')
return
end
Set_Level_Sync(raw_args[2])
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
-- NOTE: HeadingTo, TurnToTarget and Combat now live in TargetLogic.lua.
-- NOTE:
-- Origin_Distance, Set_Origin and Path_To_Origin are now supplied by
-- TargetLogic.lua. They are intentionally not redefined here.
-- NOTE:
-- Is_Player_Pet, Find_Named_Target, Is_Targetable_Monster,
-- Find_Nearest_Target, Get_Party_Claim_Ids, Find_Party_Target,
-- Is_Legitimate_Target, Choose_Target, Follow_Monitor,
-- Target_Monitor and Targeting are supplied by TargetLogic.lua.
-- Their duplicate implementations have been removed from this file.
-- ENGINE
function Engine()
while Start_Engine do
local player = windower.ffxi.get_player()
if player then
Update_Job_Profile()
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
if player
and not (current_job == 'RDM' and Debuff_Pending and Debuff_Pending())
and player.status == 1
and isBusy < 1
and player.vitals.tp >= 1000
then
local target = windower.ffxi.get_mob_by_target('t')
if target and sc_ready and sc_ready(target.id) then
local chain = Get_WS_Chain()
if chain then
-- Ordered chain: step N has landed, so entry N + 1 is next.
-- Past the last entry the chain is finished; the opener fires
-- again once the window is gone.
local step = sc_get_step and sc_get_step(target.id)
local nxt = step and chain[step + 1]
if nxt and player.vitals.tp >= nxt[2] then
windower.send_command('input /ws \"' .. nxt[1] .. '\" <t>')
isBusy = Action_Delay
dnc_flourish_pending = true
end
elseif ws_mode == 'party' then
-- Partychain: continue the open skillchain with the best weaponskill we
-- can use right now, whoever started it. Nothing continues it: do nothing,
-- the burst takes the end of the chain.
local ranked = sc_rank_ws and sc_rank_ws(target.id, Get_Party_Prefer()) or {}
local best = ranked[1]
if best and active_profile and active_profile.use_weaponskills ~= false then
windower.send_command('input /ws \"' .. best.name .. '\" <t>')
isBusy = Action_Delay
dnc_flourish_pending = true
end
else
local options = sc_get_ws(target.id) or {}
local fired = false
for _, ws in ipairs(options) do
if fired then break end
for _, closer in ipairs(Get_WS_Closers() or {}) do
if ws == closer then
windower.send_command('input /ws \"' .. closer .. '\" <t>')
isBusy = Action_Delay
dnc_flourish_pending = true
fired = true
break
end
end
end
end
end
end
coroutine.sleep(0.5)
end
end
-- COMBAT
-- DNC ROTATION
function Try_DNC_Actions()
local player = windower.ffxi.get_player()
if not player or not player.vitals then return false end
if player.vitals.hpp and player.vitals.hpp <= 50 then
for _, waltz in ipairs(DNC_WALTZ_TIERS) do
local ability = res.job_abilities:with('name', waltz)
if ability
and Can_Cast_Ability(waltz)
and player.vitals.mp >= (ability.mp_cost or 0)
then
windower.add_to_chat(
167,
'[Lazy] Emergency Waltz -- ' ..
waltz .. ' (' .. player.vitals.hpp .. '% HP)'
)
Cast_Ability(waltz)
return true
end
end
end
local target = windower.ffxi.get_mob_by_target('t')
if not target
or not target.distance
or math.sqrt(target.distance) > 5
then
return false
end
local stacks = buffactive['Finishing Move'] or 0
if (stacks >= 5 or dnc_flourish_pending)
and Can_Cast_Ability('Reverse Flourish')
then
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
-- NOTE: Can_Cast_Spell, Cast_Spell, Cast_Spell_On, Cast_Ability (and the
-- other cast helpers) live in Logic/JobLogic.lua.
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
if target
and target.hpp
and target.hpp > 0
and not Is_Blacklisted(target.name)
then
for _, debuff in ipairs(active_profile.debuffs) do
local last = debuff_last_cast[debuff.name]
local interval = (debuff.interval or 1) * 60
local pet_ok = true
if debuff.require_no_pet and pet then
pet_ok = false
end
-- GEO failsafe: if the profile marks a Luopan-creating geomancy spell
-- for pet recovery, a missing pet overrides the normal per-spell timer.
-- A living pet still blocks this path via require_no_pet above.
local pet_recovery_due = debuff.recast_if_no_pet and not pet
local debuff_due = pet_recovery_due or not last or now - last >= interval
if pet_ok and debuff_due then
-- Pre-ability check (e.g., Blaze of Glory)
if debuff.use_ability_before
and Can_Cast_Ability(debuff.use_ability_before)
then
Cast_Ability(debuff.use_ability_before)
return
end
local spell_target = debuff.target or '<t>'
local spell = res.spells:with('name', debuff.name)
if spell and Cast_Spell_On(debuff.name, spell_target) then
pending_cast = {
store = debuff_last_cast,
key = debuff.name,
spell_id = spell.id,
sent_at = now,
}
-- Post-ability sequence (e.g., Ecliptic Attrition)
if debuff.use_ability_after then
local follow_up = debuff.use_ability_after
coroutine.schedule(function()
coroutine.sleep(2.5)
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
-- 2. JOB ABILITIES
for _, ability_name in ipairs(active_profile.job_abilities or {}) do
if Can_Cast_Ability(ability_name) then
Cast_Ability(ability_name)
return
end
end
-- 3. SELF BUFFS
for _, buff in ipairs(active_profile.self_buffs or {}) do
local interval = (buff.interval or 20) * 60
local last = self_buff_last_cast[buff.name]
if not last or now - last >= interval then
local spell = res.spells:with('name', buff.name)
if spell and Cast_Spell_On(buff.name, '<me>') then
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
-- 5. ENTRUST BUFFS
if active_profile.entrust_buffs then
local info = windower.ffxi.get_info()
local me_zone = info and info.zone
local party = windower.ffxi.get_party()
entrust_ability_last_success =
entrust_ability_last_success or {}
for _, eb in ipairs(active_profile.entrust_buffs) do
local interval = (eb.interval or 1) * 60
local last = entrust_last_cast[eb.spell]
if not last or now - last >= interval then
local chosen_target = nil
-- Find an eligible party member for Entrust.
if type(eb.targets) == 'table'
and type(eb.targets.jobs) == 'table'
and party
then
for _, job in ipairs(eb.targets.jobs) do
if chosen_target then
break
end
for _, key in ipairs({
'p0', 'p1', 'p2', 'p3', 'p4', 'p5'
}) do
local member = party[key]
local mob = member and member.mob
if member
and member.name
and mob
and mob.id
and member.zone == me_zone
and not mob.is_npc
and key ~= 'p0'
and member.main_job == job
and mob.distance
and math.sqrt(mob.distance) <= 20
then
chosen_target = member.name
break
end
end
end
end
if chosen_target then
local ability_name = eb.ability or 'Entrust'
local last_attempt =
entrust_ability_last_attempt[ability_name]
local last_success =
entrust_ability_last_success[ability_name]
-- Attempt Entrust at most once every five seconds.
if not last_attempt or now - last_attempt >= 5 then
entrust_ability_last_attempt[ability_name] = now
if Can_Cast_Ability(ability_name) then
Cast_Ability(ability_name)
entrust_ability_last_success[ability_name] = now
else
-- A failed readiness check invalidates any
-- previous authorization to cast the Indi spell.
entrust_ability_last_success[ability_name] = nil
return
end
-- Allow the ability command time to process.
return
end
-- Don't cast Indi if the latest ability attempt failed.
if not last_success or last_success < last_attempt then
return
end
local spell = res.spells:with('name', eb.spell)
if spell
and Cast_Spell_On(eb.spell, chosen_target)
then
pending_cast = {
store = entrust_last_cast,
key = eb.spell,
spell_id = spell.id,
sent_at = now,
}
-- Consume the authorization after sending the spell.
entrust_ability_last_success[ability_name] = nil
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
for _, key in ipairs({'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}) do
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
for _, key in ipairs({'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}) do
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
for _, key in ipairs({'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}) do
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
for _, key in ipairs({'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}) do
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
for _, key in ipairs({'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}) do
local m = party[key]
if m then
if m.main_job == 'WHM' or m.job == 'WHM' then
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
if not settings.cure_active or not active_profile then return end
Update_Job_Profile()
local cure_active = active_profile.cure_bot_active
if current_job == 'SCH' and active_profile.cure_bot_if_no_whm then
cure_active = not Party_Has_WHM()
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
for _, key in ipairs({'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}) do
local m = party[key]
if m and m.hp and m.hp > 0 and m.hpp and m.hpp < worst_hpp then
worst_hpp = m.hpp
worst_member = m
end
end
local threshold =
failsafe
and (active_profile.emergency_cure_threshold or 25)
or 75
if not worst_member or worst_hpp > threshold then return end
local target_name =
worst_member.name
or (worst_member.mob and worst_member.mob.name)
if not target_name then return end
local max_hp = worst_member.hp / (worst_hpp / 100)
local missing_hp = math.floor(max_hp - worst_member.hp)
if missing_hp <= 0 then return end
local target = (target_name == player.name) and '<me>' or target_name
if failsafe then
windower.add_to_chat(
167,
'[Lazy] Failsafe cure -- ' ..
target_name .. ' at ' .. worst_hpp .. '% HP, no healer response'
)
end
for _, tier in ipairs(active_profile.cure_tiers or {}) do
local min_m = tier.min_missing or 0
local max_m = tier.max_missing or 999999
if missing_hp >= min_m and missing_hp <= max_m then
for _, spell_name in ipairs(tier.spells) do
if Cast_Spell_On(spell_name, target) then
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
-- TRUST
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