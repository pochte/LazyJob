-- RESTLOGIC
local REST_MP_THRESHOLD = 500
local REST_THREAT_WINDOW = 10
local REST_PARTY_HP_THRESHOLD = 60
local REST_PARTY_MAX_RANGE = 30
local REST_CURE_RANGE = 20
local rest_started_at = 0
-- Only jobs that actually run on a meaningful MP pool rest at all.
-- RDM remains eligible, except when playing RDM/NIN.
local REST_ELIGIBLE_JOBS = {
    WHM = true,
    RDM = true,
    BLM = true,
    GEO = true,
    SCH = true,
    SMN = true,
}
local function Being_Hit()
    return last_damage_taken_time
        and (os.clock() - last_damage_taken_time) <= REST_THREAT_WINDOW
end
-- Someone else in the party is hurt badly enough to stop resting.
-- Up to 30y counts because the Cure Bot can move closer.
-- Beyond 30y is intentionally ignored.
local function Party_Needs_Rest_Intervention()
    local party = windower.ffxi.get_party()
    if not party then return false end
    for _, key in ipairs({'p1','p2','p3','p4','p5'}) do
        local member = party[key]
        if member
            and member.hp
            and member.hp > 0
            and member.hpp
            and member.hpp < REST_PARTY_HP_THRESHOLD
            and Party_Member_In_Range(member, REST_PARTY_MAX_RANGE)
        then
            return true
        end
    end
    return false
end
local function Magic_Burst_Needed()
    if not active_profile or not active_profile.magic_burst then
        return false
    end
    local target = windower.ffxi.get_mob_by_target('t')
    if not target
        or not target.id
        or not target.hpp
        or target.hpp <= 0
    then
        return false
    end
    if active_profile.magic_burst_requires_buff
        and not buffactive[active_profile.magic_burst_requires_buff]
    then
        return false
    end
    -- An active skillchain window means the MB job should wake up.
    -- Follow/combat logic is responsible for getting into range.
    return sc_active and sc_active(target.id) or false
end
local function Rest_Tick()
    local player = windower.ffxi.get_player()
    -- Anything that stands us up invalidates the resting flag.
    -- Grace period prevents a slow server acknowledgement after /heal
    -- from immediately flipping the state back off.
    if is_resting
        and player
        and player.status ~= 33
        and (os.clock() - rest_started_at) > 4
    then
        is_resting = false
    end
    local idle_and_alive = player
        and player.status ~= 1
        and player.vitals
        and player.vitals.hpp
        and player.vitals.hpp > 0
    local threat = Being_Hit()
    local party_needs_help = Party_Needs_Rest_Intervention()
    local magic_burst_needed = Magic_Burst_Needed()
    -- INTERRUPT REST WHEN THERE IS ACTUALLY SOMETHING TO DO
    if idle_and_alive
        and is_resting
        and (threat or party_needs_help or magic_burst_needed)
    then
        windower.send_command('input /heal off')
        is_resting = false
        return
    end
    -- BEING ATTACKED WHILE IDLE
    if idle_and_alive
        and threat
        and last_damage_source_id
    then
        local current = windower.ffxi.get_mob_by_target('t')
        local attacker = windower.ffxi.get_mob_by_id(last_damage_source_id)
        if attacker
            and attacker.valid_target
            and attacker.hpp
            and attacker.hpp > 0
            and (attacker.claim_id == 0 or attacker.claim_id == player.id)
            and (not current or current.id ~= attacker.id)
        then
            windower.add_to_chat(
                167,
                '[Lazy] Being hit by ' .. attacker.name .. ' -- engaging.'
            )
            Select_Target(attacker)
            return
        end
    end
    -- ACTUAL RESTING
    -- RDM/NIN does not rest; other eligible job/subjob combinations can.
    local should_rest_for_job = REST_ELIGIBLE_JOBS[current_job]
        and not (current_job == 'RDM' and player.sub_job == 'NIN')
    if idle_and_alive
        and settings.rest_active
        and should_rest_for_job
    then
        local mp = player.vitals.mp or 0
        local mpp = player.vitals.mpp or 0
        local mp_full = mp >= REST_MP_THRESHOLD or mpp >= 100
        if is_resting then
            if mp_full then
                windower.send_command('input /heal off')
                is_resting = false
            end
        elseif not threat
            and not party_needs_help
            and not magic_burst_needed
            and not mp_full
        then
            windower.send_command('input /heal on')
            is_resting = true
            rest_started_at = os.clock()
        end
    elseif is_resting then
        windower.send_command('input /heal off')
        is_resting = false
    end
end
function Rest_Monitor()
    while Start_Engine do
        Safe_Tick('Rest_Tick', Rest_Tick)
        coroutine.sleep(2)
    end
end