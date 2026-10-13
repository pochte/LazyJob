-- TRUSTLOGIC
-- Party management: trust tracking/resummon, party member info (job, level,
-- master level), level sync, and the "someone wants to join" flow.
tracked_trusts = tracked_trusts or {}
trust_resummon_last = trust_resummon_last or {}
trust_recovery_paused = trust_recovery_paused or false
trust_recovery_pending = trust_recovery_pending or {}
trust_recovery_casting = trust_recovery_casting or nil
-- Party-join state. party_join_active is read by TargetLogic.lua's
-- Targeting_Paused(); party_join_resummon_ok lets Trust_Tick resummon.
party_join_active = party_join_active or false
party_join_resummon_ok = party_join_resummon_ok or false
local TRUST_PARTY_KEYS = {'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}
local TRUST_CAST_TIMEOUT = 10
local TRUST_RETRY_INTERVAL = 3
local MAX_PARTY_SIZE = 6
-- PARTY MEMBER INFO
-- windower.ffxi.get_party() does not report other members' jobs or levels,
-- so they are read from packet 0x0DD (party member update). Our own master
-- level comes from 0x061 (character stats).
party_member_info = party_member_info or {}   -- [mob id] = {job, level, master_level}
my_master_level = my_master_level or nil
local job_abbr_by_name = nil
local function Job_Abbr(job_name)
    if not job_name then
        return nil
    end
    if not job_abbr_by_name then
        job_abbr_by_name = {}
        for _, j in pairs(res.jobs) do
            if j.name and j.ens then
                job_abbr_by_name[j.name] = j.ens
            end
        end
    end
    return job_abbr_by_name[job_name]
end
if not party_info_installed then
    party_info_installed = true
    windower.register_event('incoming chunk', function(id, data)
        if id ~= 0x0DD and id ~= 0x061 then
            return
        end
        local ok, p = pcall(packets.parse, 'incoming', data)
        if not ok or not p then
            return
        end
        if id == 0x0DD then
            if not p.ID then
                return
            end
            local abbr = Job_Abbr(p['Main job'])
            party_member_info[p.ID] = {
                job = (abbr and abbr ~= 'NON') and abbr or nil,
                level = p['Main job level'],
                master_level = p['Master Level'] or 0,
            }
        else
            my_master_level = p['Master Level'] or 0
        end
    end)
end
-- Main job ('WHM') of a get_party() entry, or nil if not known yet.
function Get_Party_Member_Job(m)
    if not m then
        return nil
    end
    local direct = m.main_job or m.job or (m.mob and m.mob.main_job)
    if direct then
        return direct
    end
    local id = m.mob and m.mob.id
    if not id then
        return nil
    end
    local me = windower.ffxi.get_player()
    if me and me.id == id then
        return me.main_job
    end
    local info = party_member_info[id]
    return info and info.job or nil
end
-- TRUST RECORDER
function Snapshot_Trusts()
    tracked_trusts = {}
    trust_recovery_pending = {}
    trust_recovery_casting = nil
    trust_recovery_paused = false
    local party = windower.ffxi.get_party()
    if not party then
        return
    end
    for _, key in ipairs(TRUST_PARTY_KEYS) do
        local member = party[key]
        if member
            and member.name
            and member.mob
            and member.mob.is_npc
        then
            tracked_trusts[#tracked_trusts + 1] = member.name
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
local function Get_Living_Trusts()
    local party = windower.ffxi.get_party()
    local living = {}
    if not party then
        return living
    end
    for _, key in ipairs(TRUST_PARTY_KEYS) do
        local member = party[key]
        if member
            and member.name
            and member.hp
            and member.hp > 0
        then
            living[member.name] = true
        end
    end
    return living
end
--Summon Names
local function Trust_Spell(party_name)
    local spell = res.spells:with('name', party_name)
    if spell and spell.type == 'Trust' then
        return spell
    end
    spell = res.spells:with('party_name', party_name)
    if spell and spell.type == 'Trust' then
        return spell
    end
    return nil
end
-- DEATH / RECOVERY STATE
local function Update_Trust_Recovery(living)
    local missing = {}
    for _, name in ipairs(tracked_trusts) do
        if not living[name] then
            missing[#missing + 1] = name
        end
    end
    trust_recovery_pending = {}
    for _, name in ipairs(missing) do
        trust_recovery_pending[name] = true
    end
    trust_recovery_paused = (#missing > 0)
    return missing
end
function Trust_Tick()
    -- Mid party-join the roster is being rebuilt; nothing is resummoned
    -- until the new player is in, synced, and the roster is final.
    if party_join_active and not party_join_resummon_ok then
        return
    end
    if #tracked_trusts == 0 then
        trust_recovery_paused = false
        return
    end
    local now = os.clock()
    if pending_cast
        and pending_cast.sent_at
        and now - pending_cast.sent_at > TRUST_CAST_TIMEOUT
    then
        pending_cast = nil
    end
    local living = Get_Living_Trusts()
    local missing = Update_Trust_Recovery(living)
    if #missing == 0 then
        trust_recovery_casting = nil
        return
    end
    if isBusy > 0 or isCasting or pending_cast then
        return
    end
    if trust_recovery_casting
        and now - trust_recovery_casting.sent_at < TRUST_RETRY_INTERVAL
    then
        return
    end
    trust_recovery_casting = nil
    for _, name in ipairs(missing) do
        local last_attempt = trust_resummon_last[name] or 0
        if now - last_attempt >= TRUST_RETRY_INTERVAL then
            local spell = Trust_Spell(name)
            if spell and Cast_Spell_On(spell.en, '<me>') then
                trust_resummon_last[name] = now
                trust_recovery_casting = { name = name, spell_id = spell.id,sent_at = now, }
                pending_cast = {store = trust_resummon_last,key = name, spell_id = spell.id, sent_at = now,}
                windower.add_to_chat(2,'[Lazy] Resummoning trust: ' .. name)
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
-- LEVEL SYNC
-- Level sync is packet 0x077 (the same "change permissions" packet used to
-- hand over party leader): Kind 0 = party, ChangeKind 6 = set level sync to
-- the named member, 7 = disable. 24 bytes: 4 header, 16 name, kind, change
-- kind, 2 padding. Built by hand because Windower's packet library pads it
-- to 28. Only the party leader's request is accepted by the server.
local GROUP_KIND_PARTY = 0
local GROUP_CHANGE_SET_LEVEL_SYNC = 6
local GROUP_CHANGE_DISABLE_LEVEL_SYNC = 7
local function Send_Group_Change(name, change_kind)
    name = tostring(name or ''):sub(1, 15)
    local raw = string.char(0x77, 0x0C, 0x00, 0x00)
        .. name .. string.rep('\0', 16 - #name)
        .. string.char(GROUP_KIND_PARTY, change_kind, 0, 0)
    windower.packets.inject_outgoing(0x077, raw)
end
function Set_Level_Sync(name)
    windower.add_to_chat(2, '[Lazy] Level sync -> ' .. tostring(name))
    Send_Group_Change(name, GROUP_CHANGE_SET_LEVEL_SYNC)
end
function Clear_Level_Sync()
    local me = windower.ffxi.get_player()
    windower.add_to_chat(2, '[Lazy] Level sync off (takes ~30s to uncap)')
    Send_Group_Change(me and me.name or '', GROUP_CHANGE_DISABLE_LEVEL_SYNC)
end
local function Level_Sync_Buff_Id()
    local buff = res.buffs and res.buffs:with('en', 'Level Sync')
    return buff and buff.id or 269
end
local function Has_Level_Sync()
    local me = windower.ffxi.get_player()
    if not me or not me.buffs then
        return false
    end
    local id = Level_Sync_Buff_Id()
    for _, b in pairs(me.buffs) do
        if b == id then
            return true
        end
    end
    return false
end
-- Asks the server to resend our character stats (0x061), which carries our
-- own master level. Same packet the client sends when opening Equipment.
local function Request_Own_Status()
    pcall(function()
        packets.inject(packets.new('outgoing', 0x061))
    end)
end
-- PARTY JOIN
local function Join_Config()
    local cfg = party_join or {}
    return {
        enabled = cfg.enabled ~= false,
        phrase = string.lower(cfg.phrase or 'chicken nuggets'),
        allowed = cfg.allowed_senders or {},
        invite_timeout = cfg.invite_timeout or 60,
        fight_timeout = cfg.fight_timeout or 120,
        level_sync = cfg.level_sync ~= false,
    }
end
local function Say(msg)
    windower.add_to_chat(2, '[Lazy] ' .. msg)
end
local function Tell(name, msg)
    windower.send_command('input /t ' .. name .. ' ' .. msg)
end
local function Find_Party_Member(name)
    local party = windower.ffxi.get_party()
    if not party then
        return nil
    end
    local want = string.lower(name)
    for _, key in ipairs(TRUST_PARTY_KEYS) do
        local m = party[key]
        if m and m.name and string.lower(m.name) == want then
            return m, key
        end
    end
    return nil
end
local function Is_Trust_Member(m)
    return m and m.mob and m.mob.is_npc and true or false
end
-- Real players in the party (us included). A member we cannot see is
-- assumed to be a player, since trusts are always next to us.
local function Party_Players()
    local out = {}
    local party = windower.ffxi.get_party()
    if not party then
        return out
    end
    for _, key in ipairs(TRUST_PARTY_KEYS) do
        local m = party[key]
        if m and m.name and not Is_Trust_Member(m) then
            out[#out + 1] = m
        end
    end
    return out
end
local function Count_Trusts_In_Party()
    local n = 0
    local party = windower.ffxi.get_party()
    if not party then
        return 0
    end
    for _, key in ipairs(TRUST_PARTY_KEYS) do
        if Is_Trust_Member(party[key]) then
            n = n + 1
        end
    end
    return n
end
-- Lowest level, then lowest master level, among real players. Returns the
-- member to sync to and whether anyone is actually higher than them.
-- Non-master-breakers count as master level 0.
local function Pick_Sync_Target()
    local me = windower.ffxi.get_player()
    if not me then
        return nil, false, 'no player'
    end
    local lowest, lowest_key, highest_key = nil, nil, nil
    for _, m in ipairs(Party_Players()) do
        local level, ml
        if m.name == me.name then
            level = me.main_job_level
            ml = me.master_level or my_master_level
        else
            local info = m.mob and party_member_info[m.mob.id]
            if info then
                level, ml = info.level, info.master_level
            end
        end
        if not level then
            return nil, false, 'level of ' .. m.name .. ' not known yet'
        end
        local key = level * 1000 + (ml or 0)
        if not lowest_key or key < lowest_key then
            lowest, lowest_key = m, key
        end
        if not highest_key or key > highest_key then
            highest_key = key
        end
    end
    if not lowest then
        return nil, false, 'no players in party'
    end
    return lowest, highest_key > lowest_key, nil
end
-- Which trusts to keep. A trust whose job matches the joiner's goes
-- first, then trust_sacrifice_order, then whoever was summoned last.
local function Choose_Trusts_To_Keep(roster, joiner_job, cut)
    local keep = {}
    for i, name in ipairs(roster) do
        keep[i] = name
    end
    local dropped = {}
    local function index_of(name)
        for i, n in ipairs(keep) do
            if n == name then
                return i
            end
        end
        return nil
    end
    local jobs = trust_jobs or {}
    for _ = 1, cut do
        local victim = nil
        if joiner_job then
            for _, name in ipairs(keep) do
                if jobs[name] == joiner_job then
                    victim = name
                    break
                end
            end
        end
        if not victim then
            for _, group in ipairs(trust_sacrifice_order or {}) do
                for _, name in ipairs(group) do
                    if index_of(name) then
                        victim = name
                        break
                    end
                end
                if victim then
                    break
                end
            end
        end
        if not victim then
            victim = keep[#keep]
        end
        if victim then
            table.remove(keep, index_of(victim))
            dropped[#dropped + 1] = victim
        end
    end
    return keep, dropped
end
-- Each run owns an id; bumping party_join_run_id (cancel, or a newer run)
-- tells a running join to stop at its next check.
local party_join_run_id = 0
local function Join_Aborted(run_id)
    return run_id ~= party_join_run_id or not Start_Engine
end
-- The whole flow. Sleeps live at this level (no pcall around them).
local function Party_Join_Run(name, run_id)
    local cfg = Join_Config()
    Say('Party join for ' .. name .. ': no new pulls until they are in.')
    -- 1. Let a fight in progress finish.
    local started = os.clock()
    while not Join_Aborted(run_id) do
        local me = windower.ffxi.get_player()
        if not me or me.status ~= 1 then
            break
        end
        if os.clock() - started > cfg.fight_timeout then
            Say('Fight is taking too long, carrying on anyway.')
            break
        end
        coroutine.sleep(1)
    end
    if Join_Aborted(run_id) then
        return
    end
    -- 2. Invite and wait for them to accept.
    if not Find_Party_Member(name) then
        Tell(name, 'Sending the invite now, please accept it.')
        windower.send_command('input /pcmd add ' .. name)
    end
    local waited = 0
    local resent = false
    while not Find_Party_Member(name) do
        if Join_Aborted(run_id) then
            return
        end
        if waited >= cfg.invite_timeout then
            Say(name .. ' never accepted the invite. Back to botting.')
            Tell(name, 'The invite timed out. Tell me again when you are ready.')
            return
        end
        if not resent and waited >= cfg.invite_timeout / 2 then
            resent = true
            windower.send_command('input /pcmd add ' .. name)
        end
        coroutine.sleep(1)
        waited = waited + 1
    end
    Say(name .. ' joined the party.')
    -- 3. Give their job / level / master level a moment to arrive.
    local joiner, info
    for _ = 1, 8 do
        joiner = Find_Party_Member(name)
        info = joiner and joiner.mob and party_member_info[joiner.mob.id]
        if info then
            break
        end
        coroutine.sleep(1)
    end
    local joiner_job = info and info.job or nil
    Say(name .. ': ' .. tostring(joiner_job or 'job unknown') ..
        (info and (' lv' .. tostring(info.level) .. ' ML' .. tostring(info.master_level)) or ''))
    -- 4. Level sync to the lowest level / master level.
    if cfg.level_sync then
        if Has_Level_Sync() then
            Say('A level sync is already active, leaving it alone.')
        else
            if my_master_level == nil then
                Request_Own_Status()
                for _ = 1, 3 do
                    if my_master_level ~= nil then
                        break
                    end
                    coroutine.sleep(1)
                end
            end
            if my_master_level == nil and not (windower.ffxi.get_player() or {}).master_level then
                Say('Own master level unknown, assuming 0.')
            end
            local target, need, why = Pick_Sync_Target()
            if not target then
                Say('No level sync: ' .. tostring(why) .. '.')
            elseif not need then
                Say('Everyone is the same level, no sync needed.')
            else
                Set_Level_Sync(target.name)
                local synced = false
                for _ = 1, 8 do
                    coroutine.sleep(1)
                    if Has_Level_Sync() then
                        synced = true
                        break
                    end
                end
                if synced then
                    Say('Level sync active.')
                else
                    Say('Level sync did not take. Do it from the party menu, I will wait up to 45s.')
                    for _ = 1, 45 do
                        if Join_Aborted(run_id) or Has_Level_Sync() then
                            break
                        end
                        coroutine.sleep(1)
                    end
                end
            end
        end
    end
    if Join_Aborted(run_id) then
        return
    end
    -- 5. Trust roster: the party has six slots and the new player took one.
    local roster = {}
    for i, n in ipairs(tracked_trusts) do
        roster[i] = n
    end
    local humans = #Party_Players()
    local max_trusts = math.max(0, MAX_PARTY_SIZE - humans)
    local cut = math.max(0, #roster - max_trusts)
    local keep, dropped = Choose_Trusts_To_Keep(roster, joiner_job, cut)
    if #dropped > 0 then
        Say('Not resummoning: ' .. table.concat(dropped, ', '))
    end
    -- If a trust has to go and some are still out, dismiss them all so the
    -- slot is free and the roster comes back clean. (Level sync and a
    -- full-party invite already dismiss them; with nothing to drop and no
    -- sync the trusts that are out are simply left alone.)
    if #dropped > 0 and Count_Trusts_In_Party() > 0 then
        windower.send_command('input /retr all')
        for _ = 1, 5 do
            if Count_Trusts_In_Party() == 0 then
                break
            end
            coroutine.sleep(1)
        end
    end
    tracked_trusts = keep
    trust_resummon_last = {}
    trust_recovery_casting = nil
    party_join_resummon_ok = true
    if #keep > 0 then
        Say('Resummoning: ' .. table.concat(keep, ', '))
        local deadline = os.clock() + 150
        while not Join_Aborted(run_id) and os.clock() < deadline do
            local living = Get_Living_Trusts()
            local all_up = true
            for _, n in ipairs(keep) do
                if not living[n] then
                    all_up = false
                    break
                end
            end
            if all_up then
                break
            end
            coroutine.sleep(1)
        end
    end
    Tell(name, 'You are in! Back to botting.')
    Say('Party join finished.')
end
local function Party_Join_Reset()
    party_join_active = false
    party_join_resummon_ok = false
end
function Party_Join_Cancel()
    if not party_join_active then
        Say('No party join in progress.')
        return
    end
    party_join_run_id = party_join_run_id + 1
    Party_Join_Reset()
    Say('Party join cancelled.')
end
function Party_Join_Begin(name)
    if not Start_Engine then
        Say('Start Lazy first (//lazy start).')
        return false
    end
    if party_join_active then
        Say('A party join is already in progress.')
        return false
    end
    if not Join_Config().enabled then
        return false
    end
    party_join_active = true
    party_join_resummon_ok = false
    party_join_run_id = party_join_run_id + 1
    local run_id = party_join_run_id
    coroutine.schedule(function()
        Party_Join_Run(name, run_id)
        -- Only the run that still owns the flag may clear it.
        if run_id == party_join_run_id then
            Party_Join_Reset()
        end
    end, 0)
    -- Watchdog: if the run dies on an error the flags would stay set and
    -- pulls would stay paused forever.
    coroutine.schedule(function()
        coroutine.sleep(600)
        if run_id == party_join_run_id and party_join_active then
            Say('Party join watchdog fired, resuming.')
            Party_Join_Reset()
        end
    end, 0)
    return true
end
-- Incoming tell: "chicken nuggets"
windower.register_event('chat message', function(message, sender, mode, gm)
    if mode ~= 3 or not message or not sender then
        return
    end
    if not Start_Engine or party_join_active then
        return
    end
    local cfg = Join_Config()
    if not cfg.enabled then
        return
    end
    local text = string.lower(message):gsub('%s+', ' '):match('^%s*(.-)%s*$')
    if text ~= cfg.phrase then
        return
    end
    local me = windower.ffxi.get_player()
    if me and string.lower(me.name) == string.lower(sender) then
        return
    end
    if #cfg.allowed > 0 then
        local ok = false
        for _, allowed in ipairs(cfg.allowed) do
            if string.lower(allowed) == string.lower(sender) then
                ok = true
                break
            end
        end
        if not ok then
            Say('Ignored the party phrase from ' .. sender .. ' (not allowed).')
            return
        end
    end
    Party_Join_Begin(sender)
end)