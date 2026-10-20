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
function Get_Living_Trusts()
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
-- The trust SPELL for a party-list name. Most trusts share the name, but
-- the UC ones don't ("Yoran-Oran" in the party, "Yoran-Oran (UC)" as the
-- spell), so fall back to the spell's party_name field.
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
function Has_Level_Sync()
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
function Request_Own_Status()
    pcall(function()
        packets.inject(packets.new('outgoing', 0x061))
    end)
end
