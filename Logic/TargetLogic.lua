-- TARGETLOGIC
-- THE single authority for choosing, selecting and managing targets.
-- Owns: target discovery/filtering, party-claim priority, pet/Luopan
-- exclusion, combat lock, engage/retry, origin + pathing, follow,
-- ranged pulls, Target_Monitor/Targeting/Follow_Monitor, incoming
-- damage tracking, the aggro queue, and Engagement_Sync().
-- Lazy.lua only schedules the coroutines and reads last_damage_* for
-- Death_Monitor. All debug logic lives in Debug.lua (loaded by Lazy.lua
-- before this file); nothing debug-related is defined here.
--
-- COMBAT: Once engaged (status == 1), keep the target lock until
-- combat ends. Never retarget during an active fight.
--
-- PRE-ENGAGE: Follow committed targets until in range.
--
-- TRUSTS: Finish the current fight, then pause new targeting until
-- TrustLogic.lua confirms all tracked trusts are alive.
-- TARGETING PAUSE
-- True while TrustLogic.lua is recovering dead trusts, or while a player
-- is being brought into the party (party_join_active). Blocks new target
-- acquisition, new engagements and approaching; never touches an
-- established combat lock.
function Targeting_Paused()
return (trust_recovery_paused or party_join_active) and true or false
end
-- ORIGIN / PATHING
function Origin_Distance(x, y, z)
if type(origin_x) ~= 'number'
or type(origin_y) ~= 'number'
or type(x) ~= 'number'
or type(y) ~= 'number'
then
return math.huge
end
if type(origin_z) == 'number'
and type(z) == 'number'
and type(origin_z_tolerance) == 'number'
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
local player = windower.ffxi.get_player()
if not player then
return false
end
local mob = windower.ffxi.get_mob_by_id(player.id)
if not mob
or type(mob.x) ~= 'number'
or type(mob.y) ~= 'number'
or type(mob.z) ~= 'number'
then
Debug.Log('SET ORIGIN FAILED - PLAYER POSITION UNAVAILABLE')
return false
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
tostring(origin_radius)
)
return true
end
function Path_To_Origin()
if type(origin_x) ~= 'number'
or type(origin_y) ~= 'number'
then
return
end
local player = windower.ffxi.get_player()
if not player then
return
end
local mob = windower.ffxi.get_mob_by_id(player.id)
if not mob
or type(mob.x) ~= 'number'
or type(mob.y) ~= 'number'
or type(mob.z) ~= 'number'
then
windower.ffxi.run(false)
pathing_to_origin = false
path_tick = 0
return
end
local distance = Origin_Distance(mob.x, mob.y, mob.z)
if distance == math.huge then
windower.ffxi.run(false)
local now = os.clock()
if not origin_unreachable_since then
origin_unreachable_since = now
end
if (now - origin_unreachable_since) >= ORIGIN_UNREACHABLE_TIMEOUT then
windower.add_to_chat(
2,
'[Lazy] Origin unreachable for ' ..
math.floor(ORIGIN_UNREACHABLE_TIMEOUT / 60) ..
' min -- re-anchoring origin and retargeting.'
)
Set_Origin()
return
end
if not path_stuck_alerted then
windower.add_to_chat(
167,
'[Lazy] Origin unreachable at current elevation -- stopping autopath. Will re-anchor here after ' ..
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
and (now - path_last_progress_time) >= PATH_STUCK_TIMEOUT
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
path_tick = (path_tick or 0) + 1
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
local until_time = id and unattackable_until[id]
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
if not Start_Engine or not original then
return
end
if string.find(original, '[Lazy DEBUG]', 1, true) then
return
end
if not string.find(
original,
'You cannot attack that target',
1,
true
) then
return
end
local target = windower.ffxi.get_mob_by_target('t')
if Debug and Debug.enabled then
local player = windower.ffxi.get_player()
Debug.Log('!!! FFXI REJECTED ATTACK !!!')
Debug.Log('Message: ' .. tostring(original))
Debug.Target('TARGET WHEN ATTACK WAS REJECTED', target)
Debug.State('STATE WHEN ATTACK WAS REJECTED')
Debug.Log(string.format(
'REJECTION STATE | player_status=%s managed=%s locked=%s engage_sent=%s combat_started=%s',
tostring(player and player.status),
tostring(managed_target_id),
tostring(combat_locked_target_id),
tostring(engage_sent_target_id),
tostring(combat_started)
))
end
if not target or not target.id then
return
end
-- If combat never actually started, the engage attempt failed.
-- Once combat has started, NEVER release the combat lock because
-- of this message.
if target.id == combat_locked_target_id then
if not combat_started then
Debug.Target(
'ATTACK REJECTED BEFORE COMBAT - CLEARING LOCK',
target
)
unattackable_until[target.id] = os.clock() + 20
Clear_Combat_Target()
end
else
-- A rejection for a different target must not affect the
-- existing combat lock.
unattackable_until[target.id] = os.clock() + 20
end
end)
-- RANGED PULL
pull_attempts = {}
function Try_Ranged_Pull(mob, distance)
local rp = active_profile and active_profile.ranged_pull
if not rp or not mob or not mob.id then
return false
end
-- Ranged pulls are only for unclaimed enemies.
if mob.claim_id ~= 0 then
return false
end
-- Never attempt to pull invalid, dead, or player-owned targets.
if not mob.valid_target
or not mob.hpp
or mob.hpp <= 0
then
return false
end
if Is_Player_Pet and Is_Player_Pet(mob) then
return false
end
if Is_Unattackable(mob.id) then
return false
end
if not distance or distance > (rp.range or 20) then
return false
end
windower.ffxi.follow(0)
local current = windower.ffxi.get_mob_by_target('t')
if not current or current.id ~= mob.id then
Debug.Target('RANGED PULL SELECT', mob)
Select_Target(mob)
return true
end
if (isBusy or 0) > 0
or isCasting
or (Is_Moving and Is_Moving())
then
return true
end
local now = os.clock()
local info = pull_attempts[mob.id] or {
count = 0,
last = 0
}
local retry = rp.retry or 6
if now - info.last < retry then
return true
end
if info.count >= (rp.max_tries or 3) then
unattackable_until[mob.id] = now + 20
pull_attempts[mob.id] = nil
return true
end
Debug.Target('RANGED PULL', mob)
windower.send_command('input /ra <t>')
info.count = info.count + 1
info.last = now
pull_attempts[mob.id] = info
isBusy = Action_Delay
return true
end
-- TARGETING HELPERS
function Find_Named_Target(target_name)
if not target_name then
return -1
end
local mob_array = windower.ffxi.get_mob_array()
if not mob_array then
return -1
end
local candidates = {}
for key, mob in pairs(mob_array) do
if mob
and type(mob.distance) == 'number'
and mob.distance >= 0
and not Is_Player_Pet(mob)
then
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
local wanted_name = string.lower(target_name)
for _, entry in ipairs(candidates) do
local mob = entry.mob
local in_range = true
if origin_x then
if type(mob.x) == 'number'
and type(mob.y) == 'number'
and type(mob.z) == 'number'
and type(origin_radius) == 'number'
then
in_range =
Origin_Distance(mob.x, mob.y, mob.z) <= origin_radius
else
in_range = false
end
end
if string.lower(mob.name or '') == wanted_name
and mob.valid_target
and type(mob.hpp) == 'number'
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
local config = targeting or {}
local monsters = config.monsters or {}
local wanted_name = string.lower(name)
for _, monster in ipairs(monsters) do
if type(monster) == 'string'
and wanted_name == string.lower(monster)
then
return true
end
end
return false
end
function Find_Nearest_Target()
local mob_array = windower.ffxi.get_mob_array()
if not mob_array then
return -1
end
local config = targeting or {}
local candidates = {}
for key, mob in pairs(mob_array) do
if mob
and type(mob.distance) == 'number'
and mob.distance >= 0
and not Is_Player_Pet(mob)
then
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
local valid =
Is_Targetable_Monster(mob.name)
and mob.valid_target
and (
not config.only_alive
or (
type(mob.hpp) == 'number'
and mob.hpp > 0
)
)
and (
not config.within_origin
or not origin_x
or type(mob.x) ~= 'number'
or type(mob.y) ~= 'number'
or type(mob.z) ~= 'number'
or (
type(origin_radius) == 'number'
and Origin_Distance(mob.x, mob.y, mob.z) <= origin_radius
)
)
and (
not config.only_unclaimed
or mob.claim_id == 0
)
and not Is_Unattackable(mob.id)
if valid then
return entry.key
end
end
return -1
end
-- PARTY / TRUST HELPERS
function Is_Party_Member(actor_id)
if not actor_id then
return false
end
local party = windower.ffxi.get_party()
if not party then
return false
end
for _, key in ipairs({'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}) do
local m = party[key]
local id = m and ((m.mob and m.mob.id) or m.id)
if id == actor_id then
return true
end
end
return false
end
function Is_Solo_Leader()
if not settings or settings.assist ~= '' then
return false
end
local party = windower.ffxi.get_party()
if not party then
return true
end
for _, key in ipairs({'p1', 'p2', 'p3', 'p4', 'p5'}) do
local m = party[key]
if m and (not m.mob or not m.mob.is_npc) then
return false
end
end
return true
end
function Get_Party_Claim_Ids()
local ids = {}
local party = windower.ffxi.get_party()
if not party then
return ids
end
local player = windower.ffxi.get_player()
for _, key in ipairs({'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}) do
local m = party[key]
local id = m and ((m.mob and m.mob.id) or m.id)
if id and (not player or id ~= player.id) then
ids[id] = true
end
end
return ids
end
function Find_Party_Target(party_ids)
if not party_ids or next(party_ids) == nil then
return nil
end
local mob_array = windower.ffxi.get_mob_array()
if not mob_array then
return nil
end
for index, mob in pairs(mob_array) do
if mob
and not Is_Player_Pet(mob)
and mob.valid_target
and mob.hpp and mob.hpp > 0
and not Is_Unattackable(mob.id)
and mob.claim_id and party_ids[mob.claim_id]
and (
not (origin_x and mob.x)
or Origin_Distance(mob.x, mob.y, mob.z) <= origin_radius
)
then
return index
end
end
return nil
end
function Find_Nearest_Party_Claimed_Target(party_ids)
if not party_ids or next(party_ids) == nil then
return nil
end
local mob_array = windower.ffxi.get_mob_array()
if not mob_array then
return nil
end
local candidates = {}
for _, mob in pairs(mob_array) do
if mob
and not Is_Player_Pet(mob)
and mob.valid_target
and mob.hpp and mob.hpp > 0
and not Is_Unattackable(mob.id)
and mob.claim_id and party_ids[mob.claim_id]
and mob.distance
and (
not (origin_x and mob.x)
or Origin_Distance(mob.x, mob.y, mob.z) <= origin_radius
)
then
candidates[#candidates + 1] = {
mob = mob,
dist = math.sqrt(mob.distance)
}
end
end
table.sort(candidates, function(a, b)
return a.dist < b.dist
end)
return candidates[1] and candidates[1].mob
end
-- PLAYER PET / LUOPAN FILTER
--
-- Windower exposes a player's active pet through pet_index on that
-- player's mob entry. Compare pet_index to the candidate mob's INDEX,
-- not its server ID. This is ownership-based, not name/job-based, so
-- it covers Luopans, wyverns, avatars/spirits, BST pets, automatons,
-- and other active pets when Windower exposes their owner relationship.
--
-- Scan the main party and both alliance parties. Alliance members matter
-- because their pets can appear in the same mob array and must not become
-- autotarget candidates either.
function Is_Player_Pet(mob)
if not mob or not mob.index then
return false
end
local party = windower.ffxi.get_party()
if not party then
return false
end
local owner_slots = {
'p0', 'p1', 'p2', 'p3', 'p4', 'p5',
'a10', 'a11', 'a12', 'a13', 'a14', 'a15',
'a20', 'a21', 'a22', 'a23', 'a24', 'a25',
}
for _, key in ipairs(owner_slots) do
local member = party[key]
if member then
-- member.mob is normally populated for visible members.
-- Fall back to the live mob table when only the member ID
-- is available (for example, after party data refreshes).
local owner_mob = member.mob
if not owner_mob or not owner_mob.pet_index then
local owner_id = (owner_mob and owner_mob.id) or member.id
if owner_id then
local live_owner_mob = windower.ffxi.get_mob_by_id(owner_id)
if live_owner_mob and live_owner_mob.pet_index then
owner_mob = live_owner_mob
end
end
end
local pet_index = owner_mob and owner_mob.pet_index
if pet_index and pet_index > 0 and pet_index == mob.index then
return true
end
end
end
return false
end
-- TARGET LEGITIMACY
function Is_Legitimate_Target(mob, expected_name, party_ids, already_engaged)
if not mob
or Is_Player_Pet(mob)
or not mob.valid_target
or type(mob.hpp) ~= 'number'
or mob.hpp <= 0
then
return false
end
-- Enforce the origin boundary when an origin is configured.
if origin_x then
if type(mob.x) ~= 'number'
or type(mob.y) ~= 'number'
or type(mob.z) ~= 'number'
or type(origin_radius) ~= 'number'
then
return false
end
if Origin_Distance(mob.x, mob.y, mob.z) > origin_radius then
return false
end
end
local player = windower.ffxi.get_player()
if (player and mob.id == player.id)
or Is_Party_Member(mob.id)
or Is_Unattackable(mob.id)
then
return false
end
-- Legitimate ownership:
--   * Unclaimed target
--   * Claimed by the player
--   * Claimed by a party member
local ours =
mob.claim_id == 0
or (player and mob.claim_id == player.id)
or (party_ids and mob.claim_id and party_ids[mob.claim_id])
if expected_name then
return string.lower(mob.name or '') ==
string.lower(expected_name) and not not ours
end
if ours then
return true
end
-- Preserve an existing target while the player is engaged.
-- This does not make unrelated targets valid for fresh selection.
if already_engaged
and player
and player.status == 1
then
return true
end
-- Being on the autotarget whitelist does not override claim rules.
return false
end
function Choose_Target(party_ids)
if not windower.ffxi.get_player() then
return -1
end
-- Keep the current target if it remains legitimate.
-- This prevents unnecessary target switching during combat.
local current = windower.ffxi.get_mob_by_target('t')
if Is_Legitimate_Target(current, nil, party_ids, true) then
return current.index
end
-- Otherwise, select the nearest configured target.
local nearest = Find_Nearest_Target()
if type(nearest) == 'number' and nearest > 0 then
return nearest
end
-- Solo leaders do not fall back to party-claimed targets.
if Is_Solo_Leader() then
return -1
end
return Find_Party_Target(party_ids) or -1
end
-- TARGET STATE
managed_target_id = managed_target_id or nil
pending_target_id = pending_target_id or nil
pending_target_time = pending_target_time or 0
local TARGET_SELECT_TIMEOUT = 3
combat_locked_target_id = combat_locked_target_id or nil
engage_sent_target_id = engage_sent_target_id or nil
combat_lock_time = combat_lock_time or nil
-- True only after FFXI has actually reported status == 1
-- for the currently committed combat target.
combat_started = combat_started or false
-- CLEAR COMBAT STATE
function Clear_Combat_Target()
Debug.State('CLEARING COMBAT STATE')
combat_locked_target_id = nil
managed_target_id = nil
pending_target_id = nil
pending_target_time = 0
engage_sent_target_id = nil
combat_lock_time = nil
combat_started = false
end
-- EXACT TARGET SELECTION
-- Select a specific mob by ID, avoiding name-based ambiguity.
function Select_Target_By_Id(mob)
if not mob or not mob.id or not mob.index then
Debug.Log('EXACT SELECT FAILED - INVALID MOB')
return false
end
if Is_Player_Pet(mob) then
Debug.Target('EXACT SELECT BLOCKED - PLAYER PET/LUPON', mob)
return false
end
local player = windower.ffxi.get_player()
if not player or not player.id then
Debug.Log('EXACT SELECT FAILED - PLAYER UNAVAILABLE')
return false
end
local player_mob = windower.ffxi.get_mob_by_id(player.id)
if not player_mob or not player_mob.index then
Debug.Log('EXACT SELECT FAILED - PLAYER MOB INDEX UNAVAILABLE')
return false
end
-- Re-fetch the mob to avoid acting on a stale mob-table entry.
local current_mob = windower.ffxi.get_mob_by_id(mob.id)
if not current_mob
or not current_mob.valid_target
or type(current_mob.hpp) ~= 'number'
or current_mob.hpp <= 0
or current_mob.index ~= mob.index
then
Debug.Log(
'EXACT SELECT FAILED - MOB NO LONGER VALID: ' ..
tostring(mob.id)
)
return false
end
local ok, err = pcall(function()
packets.inject(packets.new('incoming', 0x058, {
['Player'] = player.id,
['Target'] = current_mob.id,
['Player Index'] = player_mob.index,
}))
end)
if not ok then
Debug.Log('EXACT SELECT PACKET FAILED: ' .. tostring(err))
return false
end
Debug.Target('EXACT TARGET SELECT SENT', current_mob)
return true
end
-- General selection entry point.
-- Always uses exact-ID selection rather than mob names.
function Select_Target(mob)
if not mob then
Debug.Log('SELECT TARGET FAILED - NO MOB')
return false
end
return Select_Target_By_Id(mob)
end
-- Confirm whether the current target matches the requested mob.
-- If no mob is supplied, check the current combat lock.
function Confirm_Target(mob)
local expected_id
if mob then
expected_id = mob.id
else
expected_id = combat_locked_target_id
end
if not expected_id then
Debug.Log('CONFIRM TARGET FAILED - NO EXPECTED TARGET')
return false
end
local target = windower.ffxi.get_mob_by_target('t')
if not target or target.id ~= expected_id then
Debug.Log(
'TARGET CONFIRM FAILED - EXPECTED ' ..
tostring(expected_id) ..
', ACTUAL ' ..
tostring(target and target.id or 'NONE')
)
return false
end
return true
end
-- NORMAL FFXI ENGAGE
function Engage_Target(mob)
if Debug.enabled then
local current = windower.ffxi.get_mob_by_target('t')
local player = windower.ffxi.get_player()
Debug.Log(string.format(
'>>> Engage_Target CALLED <<< requested=%s id=%s <t>=%s status=%s managed=%s locked=%s engage_sent=%s combat_started=%s',
tostring(mob and mob.name),
tostring(mob and mob.id),
tostring(current and current.id),
tostring(player and player.status),
tostring(managed_target_id),
tostring(combat_locked_target_id),
tostring(engage_sent_target_id),
tostring(combat_started)
))
end
-- INVALID
if not mob or not mob.id then
Debug.Log('ENGAGE FAILED - INVALID TARGET')
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
Debug.State('ENGAGE IGNORED - ALREADY LOCKED')
return true
end
Debug.Target('ENGAGE BLOCKED - DIFFERENT COMBAT LOCK', mob)
return false
end
-- Trust recovery blocks new engagements but must not affect
-- an already established combat lock.
if Targeting_Paused() then
Debug.Target('ENGAGE BLOCKED - TRUST RECOVERY', mob)
return false
end
local player = windower.ffxi.get_player()
if not player then
return false
end
-- PLAYER ALREADY ENGAGED
if player.status == 1 then
Debug.State('ENGAGE BLOCKED - PLAYER ALREADY ENGAGED')
return false
end
-- EXACT <t> CHECK
local target = windower.ffxi.get_mob_by_target('t')
if not target or target.id ~= mob.id then
Debug.Log(string.format(
'TARGET MISMATCH requested=%s actual=%s -- RESELECTING',
tostring(mob.id),
tostring(target and target.id)
))
Select_Target(mob)
-- Selection must be confirmed before attempting engagement.
-- The caller must retry after the target actually changes.
return false
end
-- AUTO ENGAGE DISABLED
if active_profile and active_profile.auto_engage == false then
pending_target_id = nil
pending_target_time = 0
windower.ffxi.follow(0)
Debug.State('AUTO ENGAGE DISABLED')
return true
end
-- UNATTACKABLE
if Is_Unattackable(mob.id) then
Debug.Target('BLOCKED - MARKED UNATTACKABLE', mob)
return false
end
-- CLAIMED BY SOMEONE ELSE
local claim_id = mob.claim_id
local party_ids = Get_Party_Claim_Ids()
if claim_id == nil
or (
claim_id ~= 0
and claim_id ~= player.id
and not (party_ids and party_ids[claim_id])
)
then
Debug.Target('ENGAGE BLOCKED - CLAIMED BY SOMEONE ELSE OR UNKNOWN CLAIM', mob)
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
local final_target = windower.ffxi.get_mob_by_target('t')
Debug.Target('FINAL MANAGED MOB', mob)
Debug.Target('FINAL <t> BEFORE ATTACK', final_target)
-- SEND /ATTACK ON EXACTLY ONCE
Debug.Log(string.format(
'>>> SENDING /attack on <<< name=%s id=%s index=%s hpp=%s claim=%s dist=%s status=%s managed=%s locked=%s engage_sent=%s <t>=%s',
tostring(mob.name),
tostring(mob.id),
tostring(mob.index),
tostring(mob.hpp),
tostring(mob.claim_id),
type(mob.distance) == 'number'
and string.format('%.2f', math.sqrt(mob.distance))
or 'nil',
tostring(player.status),
tostring(managed_target_id),
tostring(combat_locked_target_id),
tostring(engage_sent_target_id),
tostring(final_target and final_target.id)
))
windower.send_command('input /attack on')
-- LOCK CAMERA ONCE
if not lockon_done then
windower.send_command('input /lockon')
lockon_done = true
end
return true
end
-- RANGE
local MELEE_ENGAGE_RANGE = 3
local FOLLOW_CAST_RANGE = 20
function Stop_Range(mob)
local rp = active_profile and active_profile.ranged_pull
if rp and mob and mob.claim_id == 0 then
return rp.range or 20
end
if rp and mob and mob.claim_id ~= 0 then
return rp.engage_distance or MELEE_ENGAGE_RANGE
end
if active_profile and active_profile.engage_distance then
return active_profile.engage_distance
end
if active_profile and active_profile.auto_engage == false then
return FOLLOW_CAST_RANGE
end
return MELEE_ENGAGE_RANGE
end
function Follow_Monitor()
while Start_Engine do
if combat_locked_target_id then
-- Preserve the combat lock. Never switch targets here.
local target = windower.ffxi.get_mob_by_id(combat_locked_target_id)
if target and target.valid_target then
-- Follow the locked target during combat, including
-- when hate switches to a ranged party member.
local distance = type(target.distance) == 'number'
and math.sqrt(target.distance)
or nil
local stop_range = Stop_Range(target)
if distance and distance > stop_range then
windower.ffxi.follow(target.index)
else
windower.ffxi.follow(0)
end
else
windower.ffxi.follow(0)
end
elseif Targeting_Paused() then
-- Do not follow or approach a new target while recovering.
windower.ffxi.follow(0)
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
end
windower.ffxi.follow(0)
else
local distance = type(target.distance) == 'number'
and math.sqrt(target.distance)
or nil
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
-- DEBUFF-CASTER TARGET FALLBACK (moved from Lazy.lua; called by Buff_Tick)
function Ensure_Debuff_Target()
local player = windower.ffxi.get_player()
if not player or not active_profile then
return
end
if (active_profile.debuffs or active_profile.magic_burst)
and active_profile.auto_engage == false
and not windower.ffxi.get_mob_by_target('t')
then
windower.send_command('input /target <p1>; wait 0.2; input /target <bt>')
end
end
-- COMBAT DAMAGE WATCH
last_party_damage_to_target = nil
damage_watch_target_id = nil
party_activity = {}
last_self_hit_on_current_target = nil
-- DAMAGE TAKEN / AGGRO QUEUE
-- Globals (not local): Lazy.lua's Death_Monitor reads last_damage_source
-- and last_damage_kind, and //lazy start calls Reset_Damage_Tracking().
last_damage_source = nil
last_damage_source_id = nil
last_damage_kind = nil
-- os.clock() of the last genuine hit on us; RestLogic.lua reads this.
last_damage_taken_time = nil
aggro_queue = {}
AGGRO_QUEUE_CAP = 10
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
function Reset_Damage_Tracking()
last_damage_source = nil
last_damage_source_id = nil
last_damage_kind = nil
last_damage_taken_time = nil
aggro_queue = {}
last_party_damage_to_target = nil
damage_watch_target_id = nil
last_self_hit_on_current_target = nil
party_activity = {}
end
local function Track_Damage_Taken(action, player, current_id)
local target_count = action['Target Count'] or 1
for t = 1, target_count do
if action['Target ' .. t .. ' ID'] == player.id then
local actor_id = action.Actor
-- Reaction 0 can represent a heal/buff landing as well as
-- an attack, so party members and trusts are excluded.
if action['Target ' .. t .. ' Action 1 Reaction'] == 0
and actor_id
and not Is_Party_Member(actor_id)
then
local actor = windower.ffxi.get_mob_by_id(actor_id)
last_damage_source =
actor and actor.name
or last_damage_source
or 'something unseen'
last_damage_source_id = actor_id
last_damage_kind = Resolve_Attack_Name(action.Param)
last_damage_taken_time = os.clock()
if actor_id ~= current_id then
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
end
-- Single 0x028 handler for everything targeting cares about.
windower.register_event('incoming chunk', function(id, data)
if id ~= 0x028 then
return
end
local action = packets.parse('incoming', data)
if not action then
return
end
local player = windower.ffxi.get_player()
if not player then
return
end
local current = windower.ffxi.get_mob_by_target('t')
local current_id = current and current.id
-- Damage taken by us (death cause + aggro queue)
Track_Damage_Taken(action, player, current_id)
-- Party activity on the current target
if damage_watch_target_id ~= current_id then
damage_watch_target_id = current_id
last_party_damage_to_target = current_id and os.clock() or nil
last_self_hit_on_current_target = current_id and os.clock() or nil
end
local is_self = action.Actor == player.id
local is_party = is_self or Is_Party_Member(action.Actor)
if not is_party then
return
end
local target_count = action['Target Count'] or 1
for t = 1, target_count do
local tid = action['Target ' .. t .. ' ID']
if tid and action['Target ' .. t .. ' Action 1 Reaction'] == 0 then
if tid == current_id then
last_party_damage_to_target = os.clock()
if is_self then
last_self_hit_on_current_target = os.clock()
end
end
if not is_self then
party_activity[action.Actor] = {
last_hit = os.clock(),
target_id = tid,
}
end
break
end
end
end)
-- COMBAT STALL MONITOR
function Combat_Stall_Monitor()
while Start_Engine do
coroutine.sleep(5)
end
end
-- ENGAGEMENT SYNC
-- Keeps the combat target valid while engaged, working through the aggro
-- queue (oldest first) and then the last attacker once the current
-- target is genuinely finished.
--
-- COMBAT LOCK RULES:
--   * A live locked target is never touched, regardless of distance,
--     other incoming aggro, or whether a trust died.
--   * A locked target missing from the mob table is only treated as lost
--     after LOCK_LOST_GRACE seconds of continuously missing.
--   * The lock is only handed to a new target. It is never simply cleared
--     here; Target_Monitor releases it when combat actually ends.
local ENGAGEMENT_SYNC_INTERVAL = 2
local LOCK_LOST_GRACE = 4
local function Is_Live_Enemy(mob)
return mob
and mob.id
and mob.valid_target
and type(mob.hpp) == 'number'
and mob.hpp > 0
end
local function Can_Switch_To(mob, player)
if not mob
or not player
or not Is_Live_Enemy(mob)
or Is_Player_Pet(mob)
or Is_Party_Member(mob.id)
or Is_Unattackable(mob.id)
then
return false
end
-- Allow unclaimed mobs, mobs claimed by us, and mobs claimed
-- by our party or alliance.
local party_ids = Get_Party_Claim_Ids() or {}
return mob.claim_id == 0
or mob.claim_id == player.id
or party_ids[mob.claim_id] == true
end
local function Prune_Aggro_Queue(player)
local party_ids = Get_Party_Claim_Ids() or {}
for i = #aggro_queue, 1, -1 do
local candidate =
windower.ffxi.get_mob_by_id(aggro_queue[i])
if not Is_Live_Enemy(candidate)
or Is_Player_Pet(candidate)
or Is_Party_Member(candidate.id)
or Is_Unattackable(candidate.id)
or (
candidate.claim_id ~= 0
and candidate.claim_id ~= player.id
and not party_ids[candidate.claim_id]
)
then
table.remove(aggro_queue, i)
end
end
end
-- Hand the combat lock to `mob` and select it. Player is already
-- engaged (status == 1), so this is a continuation of the same fight.
local function Handoff_Combat_Lock(mob, message)
local player = windower.ffxi.get_player()
if not player or not mob or not mob.id or not mob.index then
return false
end
-- Validate claim ownership as well as target validity. A handoff
-- must not move the lock to another player's unshared target.
if not Can_Switch_To(mob, player) then
Debug.Target('COMBAT HANDOFF REJECTED', mob)
return false
end
-- Select before committing the new lock. A failed selection must
-- not leave the combat state locked to a target we did not select.
if not Select_Target_By_Id(mob) then
Debug.Target('COMBAT HANDOFF EXACT SELECT FAILED', mob)
return false
end
combat_locked_target_id = mob.id
managed_target_id = mob.id
engage_sent_target_id = mob.id
combat_lock_time = nil
combat_started = true
pending_target_id = nil
pending_target_time = 0
windower.add_to_chat(2, message .. mob.name)
return true
end
-- Pick the next target once the locked one is truly finished: the aggro
-- queue first (oldest first), then the last thing that hit us. Handoff
-- moves the lock to the new target; it never just clears it.
-- (This definition went missing in the Oct 15 "fixes" commit while
-- Engagement_Sync still called it, which killed that loop on the first
-- lost target.)
local function Recover_Combat_Target(player, current_id)
while #aggro_queue > 0 do
local candidate = windower.ffxi.get_mob_by_id(table.remove(aggro_queue, 1))
if Can_Switch_To(candidate, player) then
if Handoff_Combat_Lock(candidate, '[Lazy] Finishing that off, now dealing with: ') then
return true
end
end
end
if last_damage_source_id and last_damage_source_id ~= current_id then
local attacker = windower.ffxi.get_mob_by_id(last_damage_source_id)
if Can_Switch_To(attacker, player) then
if Handoff_Combat_Lock(attacker, '[Lazy] Engaged target mismatch -- retargeting to ') then
return true
end
end
end
return false
end
function Engagement_Sync()
local lock_missing_since = nil
while Start_Engine do
local player = windower.ffxi.get_player()
if player then
Prune_Aggro_Queue(player)
end
if player and player.status == 1 then
local target_ok = false
local current_id = nil
if combat_locked_target_id then
current_id = combat_locked_target_id
local locked =
windower.ffxi.get_mob_by_id(combat_locked_target_id)
if Is_Live_Enemy(locked) then
target_ok = true
lock_missing_since = nil
elseif locked
and type(locked.hpp) == 'number'
and locked.hpp <= 0
then
-- Confirmed dead.
lock_missing_since = nil
else
-- Missing / not targetable right now. This could be
-- a brief mob-table blip, so hold the lock temporarily.
local now = os.clock()
lock_missing_since = lock_missing_since or now
if now - lock_missing_since < LOCK_LOST_GRACE then
target_ok = true
end
end
else
lock_missing_since = nil
local current = windower.ffxi.get_mob_by_target('t')
current_id = current and current.id
target_ok =
Is_Live_Enemy(current)
and not Is_Player_Pet(current)
end
if not target_ok then
if Recover_Combat_Target(player, current_id) then
lock_missing_since = nil
end
end
else
lock_missing_since = nil
end
coroutine.sleep(ENGAGEMENT_SYNC_INTERVAL)
end
end
-- FACING + COMBAT ROTATION
-- Moved here from Lazy.lua / JobLogic.lua so there is exactly one copy.
-- engaged_since is global (Combat's stuck-target Provoke timer).
engaged_since = nil
-- Heading (radians) from the player to a world position.
function HeadingTo(x, y)
local player = windower.ffxi.get_mob_by_id(windower.ffxi.get_player().id)
if not player then return 0 end
local dx = x - player.x
local dy = y - player.y
return math.atan2(dx, dy) - 1.5708
end
-- Turns the player to face <t> if more than 10 degrees off.
function TurnToTarget()
local target = windower.ffxi.get_mob_by_target('t')
local p = windower.ffxi.get_player()
if not target or not p then return end
local me = windower.ffxi.get_mob_by_id(p.id)
if not me or not me.heading then return end
local desired = HeadingTo(target.x, target.y)
local d = desired - me.heading
d = math.atan2(math.sin(d), math.cos(d))
if math.abs(d) > math.rad(10) then
windower.ffxi.turn(desired)
end
end
-- Per-tick combat rotation (called by Lazy.lua's Engine via pcall).
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
if active_profile
and active_profile.provoke_if_stuck
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
magic_burst_ok = buffactive[active_profile.magic_burst_requires_buff]
and true
or false
end
if magic_burst_ok then
-- (Try_Magic_Burst leaves the window to this job's own chain by itself.)
if Try_Magic_Burst and Try_Magic_Burst() then return end
if Try_Free_Nuke and Try_Free_Nuke() then return end
-- Jobs that never melee (auto_engage = false: BLM, GEO, SCH) stop here.
-- A melee job with magic burst (NIN) carries on to the weaponskill code
-- below. It used to return here too, so NIN never opened a skillchain.
if active_profile.auto_engage == false then
return
end
-- A melee job (NIN) must not open a new chain on top of a window it is
-- about to burst: the opener would replace the skillchain mid-cast.
if Burst_Window_Open
and Get_Burst_Spell
and Burst_Window_Open(target)
and Get_Burst_Spell(target)
then
return
end
end
if active_profile
and active_profile.dnc_rotation
and current_job == 'DNC'
then
if Try_DNC_Actions() then return end
end
if target
and target.distance
and math.sqrt(target.distance) <= 3
and player.vitals.tp >= 3000
and isBusy == 0
and not isCasting
-- With an ordered chain, a window that is open belongs to
-- SC_Monitor; do not smash the opener on top of it.
and not (Get_WS_Chain() and sc_active and sc_active(target.id))
and starter
and starter[1]
and active_profile
and active_profile.use_weaponskills ~= false
then
if current_job == 'DNC' and Try_DNC_Pre_WS_Flourish() then
return
end
windower.send_command(
'input /ws "' .. starter[1] .. '" <t>'
)
isBusy = Action_Delay
dnc_flourish_pending = true
return
end
if player.status ~= 1
and (not active_profile or active_profile.auto_engage ~= false)
then
return
end
lockon_done = false
if player.vitals.tp >= 400
and target
and target.distance
and math.sqrt(target.distance) <= 3
then
local recasts = windower.ffxi.get_ability_recasts()
for _, ability_name in ipairs(Get_Needed_Buffs() or {}) do
if not buffactive[ability_name] then
if ability_name == 'Food' then
local food_item = Get_Food()
if food_item then
windower.send_command(
'input /item "' .. food_item .. '" <me>'
)
isBusy = Action_Delay
return
end
else
local ability = res.job_abilities:with(
'name',
ability_name
)
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
if sc_active
and not sc_active(target.id)
and starter
and tp >= starter[2]
and active_profile
and active_profile.use_weaponskills ~= false
then
if current_job == 'DNC'
and Try_DNC_Pre_WS_Flourish()
then
return
end
windower.send_command(
'input /ws "' .. starter[1] .. '" <t>'
)
isBusy = Action_Delay
dnc_flourish_pending = true
return
end
if settings.spell_active
and Can_Cast_Spell(settings.spell)
and not Is_Blacklisted(target.name)
then
Cast_Spell(settings.spell)
end
elseif target
and settings.spell_active
and Can_Cast_Spell(settings.spell)
and not Is_Blacklisted(target.name)
then
Cast_Spell(settings.spell)
end
end
-- TARGET MONITOR
function Target_Monitor()
while Start_Engine do
local player = windower.ffxi.get_player()
local target = windower.ffxi.get_mob_by_target('t')
local target_id = target and target.id
Debug.Target_Changed(target)
-- COMBAT LOCK OWNS EVERYTHING
if combat_locked_target_id then
pending_target_id = nil
pending_target_time = 0
-- FFXI has actually entered combat.
if player and player.status == 1 then
if not combat_started then
Debug.Log(
'>>> COMBAT STARTED <<< target=' ..
tostring(combat_locked_target_id)
)
end
combat_started = true
-- Combat was previously active and has now ended.
-- This is the ONLY normal path that releases the combat lock.
elseif combat_started then
Debug.Log(
'>>> COMBAT ENDED <<< target=' ..
tostring(combat_locked_target_id)
)
Clear_Combat_Target()
else
-- Pre-engage lock that never actually reached combat.
local locked =
windower.ffxi.get_mob_by_id(combat_locked_target_id)
if locked and Is_Player_Pet(locked) then
Debug.Target(
'PRE-ENGAGE LOCK IS PLAYER PET/LUPON - CLEARING',
locked
)
Clear_Combat_Target()
elseif not locked
or not locked.valid_target
or not locked.hpp
or locked.hpp <= 0
then
Debug.Log(
'>>> PRE-ENGAGE TARGET LOST <<< target=' ..
tostring(combat_locked_target_id)
)
Clear_Combat_Target()
else
-- Retry an engage that may have been ignored while
-- casting. Restore the locked target if necessary;
-- never attack whichever mob happens to be <t>.
local now = os.clock()
local lock_age = combat_lock_time
and (now - combat_lock_time)
or 0
if lock_age > 10 then
Debug.Log(
'>>> ENGAGE NEVER STARTED - GIVING UP <<< target=' ..
tostring(combat_locked_target_id)
)
unattackable_until[combat_locked_target_id] =
now + 15
Clear_Combat_Target()
elseif lock_age >= 2
and not isCasting
and now - (engage_retry_time or 0) >= 2
then
engage_retry_time = now
local cur =
windower.ffxi.get_mob_by_target('t')
if not cur or cur.id ~= locked.id then
Debug.Log(
'>>> RESTORING LOCKED TARGET <<< target=' ..
tostring(locked.id)
)
Select_Target_By_Id(locked)
else
local dist = locked.distance
and math.sqrt(locked.distance)
if dist
and dist <= Stop_Range(locked) + 1
then
Debug.Log(
'>>> RESENDING /attack on <<< target=' ..
tostring(locked.id)
)
windower.send_command('input /attack on')
end
end
end
end
end
coroutine.sleep(0.1)
-- ALREADY ENGAGED WITHOUT OUR LOCK
-- Preserve an active fight even if recovery started before this
-- monitor adopted the target.
elseif player and player.status == 1 then
if target and target.id and not Is_Player_Pet(target) then
managed_target_id = target.id
combat_locked_target_id = target.id
engage_sent_target_id = target.id
combat_lock_time = nil
combat_started = true
pending_target_id = nil
pending_target_time = 0
Debug.Target('ADOPTING EXISTING COMBAT TARGET', target)
end
-- TRUST RECOVERY
-- Combat has ended and there is no active lock. Do not adopt
-- a pre-engage target or select a replacement while recovering.
elseif Targeting_Paused() then
pending_target_id = nil
pending_target_time = 0
-- MANAGED TARGET OUTSIDE COMBAT
elseif managed_target_id then
if not target or target.id ~= managed_target_id then
local mob = windower.ffxi.get_mob_by_id(managed_target_id)
if mob and mob.valid_target then
Debug.Target('TARGET MONITOR RESELECT', mob)
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
local player = windower.ffxi.get_player()
if player then
-- COMBAT LOCK
-- Always let the current fight continue, even when a trust
-- dies. Follow_Monitor owns movement for the locked target.
if combat_locked_target_id then
pending_target_id = nil
pending_target_time = 0
-- RESTING
elseif is_resting then
windower.ffxi.follow(0)
-- PLAYER ALREADY ENGAGED
-- Do not interrupt an active fight merely because recovery
-- is pending. Adopt the current target so its lock is kept.
elseif player.status == 1 then
local target = windower.ffxi.get_mob_by_target('t')
if target and Is_Player_Pet(target) then
Debug.Target('CURRENT <t> IS PLAYER PET/LUPON - STOPPING ATTACK', target)
windower.send_command('input /attack off')
Clear_Combat_Target()
windower.ffxi.follow(0)
elseif target and target.id then
managed_target_id = target.id
combat_locked_target_id = target.id
engage_sent_target_id = target.id
combat_lock_time = nil
combat_started = true
pending_target_id = nil
pending_target_time = 0
Debug.Target('PLAYER ALREADY ENGAGED - LOCKING', target)
Debug.State('EXISTING COMBAT LOCK')
end
windower.ffxi.follow(0)
-- TRUST RECOVERY
-- No active combat lock and not engaged: wait for TrustLogic.
-- This check must precede pending targets, managed targets,
-- assist mode, and autotarget.
elseif Targeting_Paused() then
pending_target_id = nil
pending_target_time = 0
windower.ffxi.follow(0)
-- WAITING FOR TARGET SELECTION
elseif pending_target_id then
local expected_id = pending_target_id
local confirmed = Confirm_Target({ id = expected_id })
if confirmed then
local mob = windower.ffxi.get_mob_by_id(expected_id)
if not mob
or not mob.valid_target
or type(mob.hpp) ~= 'number'
or mob.hpp <= 0
or Is_Player_Pet(mob)
then
Debug.State('CONFIRMED TARGET NO LONGER VALID')
pending_target_id = nil
pending_target_time = 0
else
local distance = type(mob.distance) == 'number'
and math.sqrt(mob.distance)
or nil
local stop_range = Stop_Range(mob)
Debug.Target('CONFIRMED TARGET WAITING FOR RANGE', mob)
if distance and distance > stop_range then
Debug.Target('CONFIRMED TARGET OUT OF RANGE - FOLLOWING', mob)
windower.ffxi.follow(mob.index)
else
windower.ffxi.follow(0)
Debug.Target('CONFIRMED TARGET READY TO ENGAGE', mob)
Engage_Target(mob)
end
end
end
-- EXISTING MANAGED TARGET
elseif managed_target_id then
local target = windower.ffxi.get_mob_by_target('t')
local managed_mob =
windower.ffxi.get_mob_by_id(managed_target_id)
if managed_mob and Is_Player_Pet(managed_mob) then
Debug.Target(
'MANAGED TARGET IS PLAYER PET/LUPON - DROPPING',
managed_mob
)
managed_target_id = nil
pending_target_id = nil
pending_target_time = 0
engage_sent_target_id = nil
combat_lock_time = nil
combat_started = false
windower.ffxi.follow(0)
elseif not managed_mob or not managed_mob.valid_target then
Debug.State('MANAGED TARGET DEAD/GONE')
managed_target_id = nil
pending_target_id = nil
pending_target_time = 0
engage_sent_target_id = nil
combat_lock_time = nil
combat_started = false
windower.ffxi.follow(0)
elseif not target or target.id ~= managed_target_id then
Debug.Target('MAIN LOOP RESELECT', managed_mob)
Select_Target(managed_mob)
else
local party_ids = Get_Party_Claim_Ids() or {}
if target.claim_id ~= 0
and target.claim_id ~= player.id
and not party_ids[target.claim_id]
then
-- Someone else claimed it. Drop it and allow a new
-- target to be selected on a later tick.
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
elseif Is_Unattackable(target.id) then
Debug.Target('MANAGED TARGET BENCHED - DROPPING', target)
managed_target_id = nil
pending_target_id = nil
pending_target_time = 0
engage_sent_target_id = nil
combat_lock_time = nil
combat_started = false
windower.ffxi.follow(0)
else
local distance = type(target.distance) == 'number'
and math.sqrt(target.distance)
or nil
local stop_range = Stop_Range(target)
if distance and distance > stop_range then
Debug.Target(
'MANAGED TARGET OUT OF RANGE - FOLLOWING',
target
)
windower.ffxi.follow(target.index)
else
windower.ffxi.follow(0)
Engage_Target(target)
end
end
end
-- ASSIST MODE
elseif settings.assist ~= '' then
windower.send_command('input /assist ' .. settings.assist)
local target = windower.ffxi.get_mob_by_target('t')
Debug.Target('ASSIST TARGET', target)
if target
and not Is_Player_Pet(target)
and target.valid_target
and type(target.hpp) == 'number'
and target.hpp > 0
then
managed_target_id = target.id
engage_sent_target_id = nil
if type(target.distance) == 'number'
and math.sqrt(target.distance) <= Stop_Range(target)
then
Engage_Target(target)
else
windower.ffxi.follow(target.index)
end
end
if not lockon_done
and active_profile
and active_profile.auto_engage ~= false
then
windower.send_command('input /lockon')
lockon_done = true
end
-- AUTOTARGET
elseif settings.autotarget then
local target_id
local expected_name =
(settings.target and settings.target ~= '')
and settings.target
or nil
local party_ids = Get_Party_Claim_Ids() or {}
if expected_name then
target_id = Find_Named_Target(settings.target)
else
target_id = Choose_Target(party_ids)
end
if type(target_id) ~= 'number' or target_id <= 0 then
Path_To_Origin()
else
local mob = windower.ffxi.get_mob_by_index(target_id)
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
managed_target_id = mob.id
pending_target_id = nil
pending_target_time = 0
engage_sent_target_id = nil
combat_lock_time = nil
combat_started = false
Debug.Target('AUTOTARGET CHOSE', mob)
Debug.State('AFTER AUTOTARGET')
local distance = type(mob.distance) == 'number'
and math.sqrt(mob.distance)
or nil
if not Try_Ranged_Pull(mob, distance) then
-- Record the requested target so the target
-- confirmation logic can track the selection.
pending_target_id = mob.id
pending_target_time = os.clock()
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