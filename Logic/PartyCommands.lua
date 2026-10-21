-- PARTYCOMMANDS
-- Everything that lets other players (or you, via //lazy) manage the party:
--   * "chicken nuggets": tell the bot the phrase and it pauses pulls, invites
--     you, level-syncs the party and resummons trusts minus the slots you need.
--   * //lazy join <name> | cancel, //lazy sync <name> | off
-- Add new party commands in Party_Command() / Party_Command_Help() at the
-- bottom. Shared trust helpers (Get_Living_Trusts, Has_Level_Sync,
-- Request_Own_Status, Set_Level_Sync, Clear_Level_Sync, Get_Party_Member_Job)
-- come from TrustLogic.lua, which loads first.
local TRUST_PARTY_KEYS = {'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}
local MAX_PARTY_SIZE = 6
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
local function Count_Party_Members()
    local n = 0
    local party = windower.ffxi.get_party()
    if not party then
        return 0
    end
    for _, key in ipairs(TRUST_PARTY_KEYS) do
        if party[key] and party[key].name then
            n = n + 1
        end
    end
    return n
end
-- Lowest master level among real players. ONLY characters with a master
-- level of 1 or higher count: syncing to a non-master would drop everyone
-- below what they can fight at. Returns the member to sync to, whether
-- anyone counted is higher than them, a reason when there is no answer,
-- and the master level synced to.
local function Pick_Sync_Target()
    local me = windower.ffxi.get_player()
    if not me then
        return nil, false, 'no player'
    end
    local lowest, lowest_ml, highest_ml = nil, nil, nil
    for _, m in ipairs(Party_Players()) do
        local ml
        if m.name == me.name then
            ml = me.master_level or my_master_level
        else
            local info = m.mob and party_member_info[m.mob.id]
            ml = info and info.master_level
        end
        if ml == nil then
            return nil, false, 'master level of ' .. m.name .. ' not known yet'
        end
        if ml >= 1 then
            if not lowest_ml or ml < lowest_ml then
                lowest, lowest_ml = m, ml
            end
            if not highest_ml or ml > highest_ml then
                highest_ml = ml
            end
        end
    end
    if not lowest then
        return nil, false, 'nobody in the party has a master level'
    end
    return lowest, highest_ml > lowest_ml, nil, lowest_ml
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
-- Dismiss trusts and verify the party data updates before trying to invite.
-- A full party cannot accept the player, so waiting for the invite first would
-- deadlock the join flow when all six slots are occupied by us and trusts.
local function Dismiss_Trusts_And_Wait(run_id, timeout)
    if Count_Trusts_In_Party() == 0 then
        return true
    end
    windower.send_command('input /retr all')
    for _ = 1, timeout do
        if Join_Aborted(run_id) then
            return false
        end
        if Count_Trusts_In_Party() == 0 then
            return true
        end
        coroutine.sleep(1)
    end
    return Count_Trusts_In_Party() == 0
end
-- The whole flow. Sleeps live at this level (no pcall around them).
local function Party_Join_Run(name, run_id)
    local cfg = Join_Config()
    Say('Party join for ' .. name .. ': no new pulls until they are in.')
    -- 1. Let a fight in progress finish. "Engaged" only counts while <t> is
    -- a live monster: with trusts out the character can sit engaged on
    -- nothing, and that used to burn the whole fight_timeout.
    local started = os.clock()
    local last_report = started
    local idle_checks = 0
    while not Join_Aborted(run_id) do
        local me = windower.ffxi.get_player()
        if not me or me.status ~= 1 then
            break
        end
        local t = windower.ffxi.get_mob_by_target('t')
        local live_fight = t and t.id and t.is_npc
            and type(t.hpp) == 'number' and t.hpp > 0
            and not Is_Party_Member(t.id)
        if live_fight then
            idle_checks = 0
        else
            idle_checks = idle_checks + 1
            if idle_checks >= 4 then
                Say('Engaged with nothing to fight, disengaging.')
                windower.send_command('input /attack off')
                if Clear_Combat_Target then
                    Clear_Combat_Target()
                end
                break
            end
        end
        local now = os.clock()
        if now - started > cfg.fight_timeout then
            Say('Fight is taking too long, carrying on anyway.')
            break
        end
        if now - last_report >= 20 then
            last_report = now
            Say('Waiting for the fight to finish' ..
                (t and t.name and (' (' .. t.name .. ')') or '') .. '...')
        end
        coroutine.sleep(1)
    end
    if Join_Aborted(run_id) then
        return
    end
    -- 2. Make sure there is a free party slot BEFORE inviting. If the party
    -- is full and trusts occupy any slots, dismiss them and verify they are
    -- gone; otherwise the invite cannot be accepted and this routine waits
    -- until the invite timeout without ever reaching trust cleanup.
    if not Find_Party_Member(name) and Count_Party_Members() >= MAX_PARTY_SIZE then
        if Count_Trusts_In_Party() > 0 then
            Say('Party is full. Dismissing trusts to make room for ' .. name .. '.')
            if not Dismiss_Trusts_And_Wait(run_id, 10) then
                if not Join_Aborted(run_id) then
                    Say('Could not dismiss trusts; cancelling party join instead of waiting on an invite.')
                    Tell(name, 'I could not dismiss my trusts to make room. Please try again shortly.')
                end
                return
            end
        else
            Say('Party is full of players; cannot make room for ' .. name .. '.')
            Tell(name, 'The party is full and has no trusts to dismiss. Please try again when a slot is free.')
            return
        end
    end
    -- Invite and wait for them to accept.
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
            local target, need, why, target_ml = Pick_Sync_Target()
            if not target then
                Say('No level sync: ' .. tostring(why) .. '.')
            elseif not need then
                Say('No level sync needed: ' .. target.name .. ' ML' ..
                    tostring(target_ml) .. ' is the lowest and nobody counted is higher.')
            else
                if Count_Trusts_In_Party() > 0 then
                    Say('Dismissing trusts before the level sync.')
                    if not Dismiss_Trusts_And_Wait(run_id, 10) then
                        Say('Could not dismiss trusts first; trying the level sync anyway.')
                    end
                end
                if Join_Aborted(run_id) then
                    return
                end
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
        Say('Dismissing trusts before resummoning the selected roster.')
        if not Dismiss_Trusts_And_Wait(run_id, 10) then
            if not Join_Aborted(run_id) then
                Say('Trust dismissal did not complete; leaving the join paused for safety. Use //lazy join cancel if needed.')
            end
            return
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
-- ===========================================================================
-- PARTY COMMANDS
-- ===========================================================================
-- Party-chat phrases (exact match on the WHOLE line, like "chicken nuggets"):
--   reset | go home | stop | start | hold | resume | regroup | rebuff | tnl
-- Rename any of them in settings.lua -> party_commands.phrases.
-- Who may use them: settings.xml trusted_players (empty = everyone). Manage
-- it with //lazy trust add/remove/list/clear <name>.
-- Also automatic: rez (dead players), doom + debuff cleansing, session stats.
-- Test any phrase locally with  //lazy party <phrase>.

-- Globals read by TargetLogic.lua / Lazy.lua.
party_hold = false              -- "hold": no new pulls until "resume"
regroup_active = false          -- running to the leader
go_home_active = false          -- warp in progress
rez_pause_active = false        -- somebody is dead / weak from a raise
party_follow_override = false   -- rez / regroup own movement right now
party_rez_busy = false          -- this character is actively raising
party_buffs = {}                -- [member id] = { [buff id] = true } (0x076)

local DEFAULT_PHRASES = {
    reset = 'reset', go_home = 'go home', stop = 'stop', start = 'start',
    hold = 'hold', resume = 'resume', regroup = 'regroup', rebuff = 'rebuff',
    tnl = 'tnl', rezzing = 'rezzing',
}
local DEFAULT_WARP_ITEMS = {
    { name = 'Warp Ring',   slot = 'ring2' },
    { name = 'Treat Staff', slot = 'main' },
    { name = 'Warp Cudgel', slot = 'main' },
    { name = 'Instant Warp' },
}
local WEAKNESS_BUFF_ID = 1
local RAISE_RANGE = 17

local function Opt(name, default)
    local v = (party_commands or {})[name]
    if v == nil then
        return default
    end
    return v
end
local function Phrase(name)
    local p = (party_commands or {}).phrases
    return string.lower((p and p[name]) or DEFAULT_PHRASES[name])
end
local function Normalize(message)
    local t = string.lower(message):gsub('%s+', ' ')
    return (t:match('^%s*(.-)%s*$'))
end
local function Chat(msg)
    windower.send_command('input /p ' .. msg)
end
local function Clear_Table(t)
    if type(t) == 'table' then
        for k in pairs(t) do
            t[k] = nil
        end
    end
end

-- TRUSTED SENDERS (settings.xml: trusted_players = "Name,Name")
local function Trusted_Names()
    local out = {}
    local raw = settings and settings.trusted_players
    if type(raw) == 'string' then
        for name in string.gmatch(raw, '[^,%s]+') do
            out[#out + 1] = name
        end
    end
    return out
end
local function Save_Trusted(list)
    settings.trusted_players = table.concat(list, ',')
    local p = windower.ffxi.get_player()
    if p then
        config.save(settings, p.name)
    end
end
function Party_Is_Trusted(sender)
    local list = Trusted_Names()
    if #list == 0 then
        return true
    end
    local want = string.lower(sender or '')
    for _, n in ipairs(list) do
        if string.lower(n) == want then
            return true
        end
    end
    return false
end

-- ROSTER / BUFFS
-- Real players only (trusts excluded). dead = 0 HP in this zone, but only
-- once it has held for a few seconds and the member has been in the party a
-- while: a player who has just joined (or just zoned) shows 0 HP until their
-- data arrives, and that must not look like a corpse.
local member_seen = {}
local dead_since = {}
local DEAD_CONFIRM_SECONDS = 4
local NEW_MEMBER_GRACE_SECONDS = 15
local function Roster()
    local out = {}
    local now = os.clock()
    local present = {}
    local party = windower.ffxi.get_party()
    local me = windower.ffxi.get_player()
    local info = windower.ffxi.get_info()
    if not party or not me or not info then
        return out
    end
    for _, key in ipairs(TRUST_PARTY_KEYS) do
        local m = party[key]
        if m and m.name and not Is_Trust_Member(m) then
            local mob = m.mob
            local is_me = (m.name == me.name)
            local in_zone = (m.zone == nil) or (m.zone == info.zone)
            present[m.name] = true
            member_seen[m.name] = member_seen[m.name] or now
            local raw_dead = in_zone and m.hp ~= nil and m.hp <= 0
                and (m.hpp == nil or m.hpp <= 0)
            local dead
            if is_me then
                dead = (me.vitals and me.vitals.hp and me.vitals.hp <= 0) and true or false
            else
                if raw_dead then
                    dead_since[m.name] = dead_since[m.name] or now
                else
                    dead_since[m.name] = nil
                end
                dead = raw_dead
                    and (now - dead_since[m.name]) >= DEAD_CONFIRM_SECONDS
                    and (now - member_seen[m.name]) >= NEW_MEMBER_GRACE_SECONDS
            end
            out[#out + 1] = {
                m = m,
                name = m.name,
                id = mob and mob.id or nil,
                mob = mob,
                job = Get_Party_Member_Job(m),
                dist = mob and type(mob.distance) == 'number' and math.sqrt(mob.distance) or nil,
                in_zone = in_zone,
                dead = dead and true or false,
                is_me = is_me,
            }
        end
    end
    for name in pairs(member_seen) do
        if not present[name] then
            member_seen[name] = nil
            dead_since[name] = nil
        end
    end
    return out
end
-- Party buffs packet (others only; never ourselves). Each entry is 0x30
-- bytes from offset 0x04: id(4) index(2) ?(2) bitmask(8) buffs(32).
-- Buff id = byte + 256 * (two bits from the mask).
windower.register_event('incoming chunk', function(id, data)
    if id ~= 0x076 then
        return
    end
    for k = 0, 4 do
        local base = 4 + k * 48
        local b1, b2, b3, b4 = data:byte(base + 1, base + 4)
        if b1 then
            local pid = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
            if pid ~= 0 then
                local set = {}
                for n = 1, 32 do
                    local low = data:byte(base + 16 + n)
                    local mask = data:byte(base + 8 + math.floor((n - 1) / 4) + 1)
                    if low and mask then
                        local high = math.floor(mask / (2 ^ (((n - 1) % 4) * 2))) % 4
                        local bid = low + 256 * high
                        if bid ~= 255 then
                            set[bid] = true
                        end
                    end
                end
                party_buffs[pid] = set
            end
        end
    end
end)
local function Buff_Set(entry)
    if entry.is_me then
        local p = windower.ffxi.get_player()
        local set = {}
        for _, b in pairs((p and p.buffs) or {}) do
            set[b] = true
        end
        return set
    end
    return (entry.id and party_buffs[entry.id]) or {}
end
local function Buff_Name(bid)
    local b = res.buffs[bid]
    return b and b.en and string.lower(b.en) or nil
end

-- SPELL / ITEM HELPERS
local known_cache = nil
-- The spell, if our main or sub job knows it at our (synced) level.
local function Spell_Capable(spell_name)
    local spell = res.spells:with('name', spell_name)
    if not spell or not spell.levels then
        return nil
    end
    local known = known_cache or windower.ffxi.get_spells()
    if not (known and known[spell.id]) then
        return nil
    end
    local p = windower.ffxi.get_player()
    if not p then
        return nil
    end
    local ml = spell.levels[p.main_job_id]
    if ml and (p.main_job_level or 0) >= ml then
        return spell
    end
    local sl = p.sub_job_id and spell.levels[p.sub_job_id]
    if sl and (p.sub_job_level or 0) >= sl then
        return spell
    end
    return nil
end
local function Item_Id(name)
    local it = res.items:with('en', name)
    return it and it.id or nil
end
local function Count_Item(name)
    local id = Item_Id(name)
    if not id then
        return 0
    end
    local items = windower.ffxi.get_items()
    local bag = items and items.inventory
    local n = 0
    if bag then
        for i = 1, (bag.max or 80) do
            local e = bag[i]
            if e and e.id == id then
                n = n + (e.count or 1)
            end
        end
    end
    return n
end

-- REZ
-- Order: WHM, SCH, RDM, PLD, then anyone else whose sub job can raise (GEO
-- /WHM, GEO/RDM...). Each waits its turn so only one casts; "rezzing" in
-- party chat tells the others to stand down.
local RAISE_TIERS = { 'Arise', 'Raise III', 'Raise II', 'Raise' }
local RAISE_RANK = { WHM = 1, SCH = 2, RDM = 3, PLD = 4 }
local rez_first_seen = {}   -- [name] = when we first saw them dead
local rez_started_at = {}   -- [name] = when we began working on them
local rez_announced = {}    -- [name] = last "rezzing"
local rez_claim_until = 0   -- someone else is raising
local rez_walking = false
local rez_pause_since = nil
local regroup_run = 0
local regroup_walking = false

local function Sync_Override()
    party_follow_override = (rez_walking or regroup_walking) and true or false
end
local function Best_Raise()
    for _, name in ipairs(RAISE_TIERS) do
        if Spell_Capable(name) then
            return name
        end
    end
    return nil
end
local function Rank_Of(e)
    return RAISE_RANK[e.job or ''] or 5
end
-- How long this character waits before acting, by its place in line.
local function My_Turn_Delay(roster, step, last_ditch_extra)
    local alive = {}
    for _, e in ipairs(roster) do
        if not e.dead and e.in_zone then
            alive[#alive + 1] = e
        end
    end
    table.sort(alive, function(a, b)
        local ra, rb = Rank_Of(a), Rank_Of(b)
        if ra ~= rb then
            return ra < rb
        end
        return a.name < b.name
    end)
    for i, e in ipairs(alive) do
        if e.is_me then
            return (i - 1) * step + ((Rank_Of(e) == 5) and last_ditch_extra or 0)
        end
    end
    return nil
end
local function Rez_Tick(roster, me)
    local now = os.clock()
    local dead = {}
    for _, e in ipairs(roster) do
        if e.dead and not e.is_me then
            dead[#dead + 1] = e
            rez_first_seen[e.name] = rez_first_seen[e.name] or now
        end
    end
    for name in pairs(rez_first_seen) do
        local still = false
        for _, e in ipairs(dead) do
            if e.name == name then
                still = true
            end
        end
        if not still then
            rez_first_seen[name] = nil
            rez_started_at[name] = nil
        end
    end
    party_rez_busy = false
    local was_walking = rez_walking
    rez_walking = false
    if #dead > 0 and not me.dead and now >= rez_claim_until then
        local spell_name = Best_Raise()
        local delay = spell_name and My_Turn_Delay(roster, Opt('rez_step', 4), Opt('rez_last_ditch_wait', 10))
        if delay then
            table.sort(dead, function(a, b)
                return rez_first_seen[a.name] < rez_first_seen[b.name]
            end)
            for _, v in ipairs(dead) do
                if v.mob and v.dist and (now - rez_first_seen[v.name]) >= delay then
                    rez_started_at[v.name] = rez_started_at[v.name] or now
                    if (now - rez_started_at[v.name]) <= Opt('rez_give_up', 90) then
                        party_rez_busy = true
                        if v.dist > RAISE_RANGE then
                            rez_walking = true
                            Sync_Override()
                            windower.ffxi.follow(v.mob.index)
                        else
                            rez_walking = true
                            Sync_Override()
                            windower.ffxi.follow(0)
                            if Cast_Spell_On(spell_name, v.name) then
                                if not rez_announced[v.name] or now - rez_announced[v.name] >= 12 then
                                    rez_announced[v.name] = now
                                    Chat('rezzing')
                                end
                            end
                        end
                        break
                    end
                end
            end
        end
    end
    if was_walking and not rez_walking then
        windower.ffxi.follow(0)
    end
    Sync_Override()
end

-- Death_Monitor (Lazy.lua) calls these.
function Party_Death_Begin()
    if Opt('rez_enabled', true) == false then
        return false
    end
    local others = 0
    for _, e in ipairs(Roster()) do
        if not e.is_me and not e.dead then
            others = others + 1
        end
    end
    if others == 0 then
        return false
    end
    Chat('rez')
    rez_pause_active = true
    return true
end
function Party_Rez_Timeout()
    return Opt('rez_timeout', 180)
end
-- Raise prompt on the dead character: accept it.
local function Accept_Raise()
    local me = windower.ffxi.get_player()
    local mob = me and windower.ffxi.get_mob_by_id(me.id)
    if not mob or not me.vitals or me.vitals.hp > 0 then
        return
    end
    Say('Accepting the raise.')
    pcall(function()
        packets.inject(packets.new('outgoing', 0x01A, {
            ['Target'] = me.id,
            ['Target Index'] = mob.index,
            ['Category'] = 0x0D,
            ['Param'] = Opt('raise_accept_param', 0),
            ['X Offset'] = 0,
            ['Z Offset'] = 0,
            ['Y Offset'] = 0,
        }))
    end)
end
windower.register_event('incoming chunk', function(id, data)
    if id ~= 0x0F9 or not Start_Engine or Opt('rez_enabled', true) == false then
        return
    end
    local me = windower.ffxi.get_player()
    if not me or not me.vitals or me.vitals.hp > 0 then
        return
    end
    local ok, p = pcall(packets.parse, 'incoming', data)
    if ok and p and (p.Category == 2 or p.Category == 'Tractor dialogue') then
        return
    end
    coroutine.schedule(Accept_Raise, 1.2)
end)

-- DOOM + DEBUFF CLEANSING (healers: WHM / SCH main or sub)
local CLEANSE_SPELL = {
    ['doom'] = 'Cursna', ['curse'] = 'Cursna', ['poison'] = 'Poisona',
    ['paralysis'] = 'Paralyna', ['blindness'] = 'Blindna', ['silence'] = 'Silena',
    ['petrification'] = 'Stona', ['disease'] = 'Viruna', ['plague'] = 'Viruna',
    ['slow'] = 'Erase', ['weight'] = 'Erase', ['bind'] = 'Erase', ['addle'] = 'Erase',
    ['attack down'] = 'Erase', ['defense down'] = 'Erase',
    ['magic def. down'] = 'Erase', ['max hp down'] = 'Erase',
}
local CLEANSE_PRIORITY = {}
for i, n in ipairs({
    'doom', 'curse', 'petrification', 'silence', 'paralysis', 'blindness', 'poison',
    'disease', 'plague', 'slow', 'bind', 'weight', 'addle', 'attack down',
    'defense down', 'magic def. down', 'max hp down',
}) do
    CLEANSE_PRIORITY[n] = i
end
local cleanse_seen = {}
local cleanse_cd = {}
local doom_announced = false
local holy_last = nil
local holy_tries = 0
local function Cleanse_Tick(roster)
    if not settings.cure_active then
        return
    end
    local now = os.clock()
    local ignore = {}
    for _, n in ipairs(Opt('cleanse_ignore', { 'Evasion Down' })) do
        ignore[string.lower(n)] = true
    end
    local delay = My_Turn_Delay(roster, Opt('cleanse_step', 2), 0)
    if not delay then
        return
    end
    local seen_now = {}
    local best
    for _, e in ipairs(roster) do
        if e.in_zone and not e.dead and (e.is_me or (e.dist and e.dist <= 20)) then
            for bid in pairs(Buff_Set(e)) do
                local nm = Buff_Name(bid)
                local spell_name = nm and CLEANSE_SPELL[nm]
                if spell_name and not ignore[nm] and Spell_Capable(spell_name) then
                    local key = e.name .. ':' .. nm
                    seen_now[key] = true
                    cleanse_seen[key] = cleanse_seen[key] or now
                    local wait = (nm == 'doom') and (delay / 2) or delay
                    if now - cleanse_seen[key] >= wait and (cleanse_cd[key] or 0) <= now then
                        local pri = CLEANSE_PRIORITY[nm] or 99
                        if not best or pri < best.pri then
                            best = { e = e, spell = spell_name, key = key, pri = pri }
                        end
                    end
                end
            end
        end
    end
    for key in pairs(cleanse_seen) do
        if not seen_now[key] then
            cleanse_seen[key] = nil
        end
    end
    if best then
        local target = best.e.is_me and '<me>' or best.e.name
        if Cast_Spell_On(best.spell, target) then
            cleanse_cd[best.key] = now + 6
        end
    end
end
-- Our own doom: say it ONCE, use Holy Water, healers cast Cursna meanwhile.
local function Doom_Self_Tick(me)
    local doomed = false
    for bid in pairs(Buff_Set(me)) do
        if Buff_Name(bid) == 'doom' then
            doomed = true
            break
        end
    end
    if not doomed then
        doom_announced = false
        holy_tries = 0
        return
    end
    if not doom_announced then
        doom_announced = true
        Chat('Doomed! Cursna please.')
    end
    if Opt('doom_holy_water', true)
        and holy_tries < Opt('holy_water_tries', 8)
        and (not holy_last or os.clock() - holy_last >= 4)
        and not isCasting
        and (isBusy or 0) == 0
        and not Is_Moving()
        and Count_Item('Holy Water') > 0
    then
        holy_last = os.clock()
        holy_tries = holy_tries + 1
        windower.send_command('input /item "Holy Water" <me>')
        isBusy = Action_Delay
    end
end

-- SESSION STATS ("tnl")
party_stats = { start = nil, kills = 0, exp = 0, lp = 0, cur = nil, req = nil }
function Party_Stats_Reset()
    party_stats.start = os.time()
    party_stats.kills = 0
    party_stats.exp = 0
    party_stats.lp = 0
end
local function Commas(n)
    local s = tostring(math.floor(n or 0))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (out:gsub('^,', ''))
end
local function Fmt_Duration(sec)
    sec = math.floor(sec)
    return string.format('%dh %02dm %02ds', math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60)
end
function Party_Print_Stats()
    local s = party_stats
    if not s.start then
        print('[Lazy] No session yet. //lazy start first.')
        return
    end
    local elapsed = math.max(1, os.time() - s.start)
    local per_hr = 3600 / elapsed
    print(string.format('[Lazy] Ran for %s | kills: %d (%.1f/hr) | EXP: %s (%s/hr) | limit points: %s',
        Fmt_Duration(elapsed), s.kills, s.kills * per_hr,
        Commas(s.exp), Commas(s.exp * per_hr), Commas(s.lp)))
    if s.cur and s.req and s.req > 0 then
        local remaining = s.req - s.cur
        local line = '[Lazy] EXP to next level: ' .. Commas(remaining)
        if s.exp > 0 then
            line = line .. ' (about ' .. Fmt_Duration(remaining / (s.exp / elapsed)) .. ' at this rate)'
        end
        print(line)
    end
end
function Party_Tnl()
    Request_Own_Status()
    coroutine.schedule(Party_Print_Stats, 1.5)
end
windower.register_event('incoming text', function(original)
    if not Start_Engine or not party_stats.start or not original then
        return
    end
    local me = windower.ffxi.get_player()
    if not me then
        return
    end
    local n = string.match(original, me.name .. ' gains (%d+) experience points')
    if n then
        party_stats.kills = party_stats.kills + 1
        party_stats.exp = party_stats.exp + tonumber(n)
        return
    end
    n = string.match(original, me.name .. ' gains (%d+) limit points')
    if n then
        party_stats.kills = party_stats.kills + 1
        party_stats.lp = party_stats.lp + tonumber(n)
    end
end)
windower.register_event('incoming chunk', function(id, data)
    if id ~= 0x061 then
        return
    end
    local ok, p = pcall(packets.parse, 'incoming', data)
    if ok and p then
        party_stats.cur = p['Current EXP']
        party_stats.req = p['Required EXP']
    end
end)

-- GO HOME
go_home_zoned = false
local WARP_BAGS = {
    'inventory', 'wardrobe', 'wardrobe2', 'wardrobe3', 'wardrobe4',
    'wardrobe5', 'wardrobe6', 'wardrobe7', 'wardrobe8', 'satchel', 'sack', 'case',
}
local BAG_ID = { satchel = 5, sack = 6, case = 7 }
local function Find_Item(item_id)
    local items = windower.ffxi.get_items()
    if not items then
        return nil
    end
    for _, bag in ipairs(WARP_BAGS) do
        local t = items[bag]
        if type(t) == 'table' then
            for i = 1, (t.max or 80) do
                local e = t[i]
                if e and e.id == item_id then
                    return bag, i, e
                end
            end
        end
    end
    return nil
end
local extdata_ok, extdata = pcall(require, 'extdata')
local function Usable_Now(entry)
    if not extdata_ok or not entry then
        return nil
    end
    local ok, ed = pcall(extdata.decode, entry)
    if ok and ed then
        return ed.usable, ed
    end
    return nil
end
local function Wait_For_Zone(seconds)
    local deadline = os.clock() + seconds
    while os.clock() < deadline and go_home_active do
        if go_home_zoned then
            return true
        end
        coroutine.sleep(0.5)
    end
    return go_home_zoned
end
-- Move (satchel/sack/case), equip, wait out the equip delay, then use.
local function Warp_Via(spec)
    local id = Item_Id(spec.name)
    if not id then
        return false
    end
    local bag, index, entry = Find_Item(id)
    if not bag then
        return false
    end
    if BAG_ID[bag] then
        Say('Moving ' .. spec.name .. ' to inventory.')
        pcall(function()
            packets.inject(packets.new('outgoing', 0x029, {
                ['Count'] = 1,
                ['Bag'] = BAG_ID[bag],
                ['Target Bag'] = 0,
                ['Current Index'] = index,
                ['Target Index'] = 0x52,
            }))
        end)
        for _ = 1, 6 do
            coroutine.sleep(1)
            bag, index, entry = Find_Item(id)
            if bag and not BAG_ID[bag] then
                break
            end
        end
        if not bag or BAG_ID[bag] then
            return false
        end
    end
    if not spec.slot and bag ~= 'inventory' then
        return false
    end
    if spec.slot then
        if not (entry and entry.status == 5) then
            windower.send_command('input /equip ' .. spec.slot .. ' "' .. spec.name .. '"')
            coroutine.sleep(2)
        end
        local started = os.clock()
        local ready = false
        while go_home_active and os.clock() - started < 35 do
            bag, index, entry = Find_Item(id)
            local usable, ed = Usable_Now(entry)
            if usable == true then
                ready = true
                break
            end
            if ed and ed.charges_remaining == 0 then
                return false
            end
            if usable == nil and os.clock() - started >= 12 then
                ready = true
                break
            end
            coroutine.sleep(1)
        end
        if not ready then
            return false
        end
    end
    Say('Using ' .. spec.name .. '...')
    windower.send_command('input /item "' .. spec.name .. '" <me>')
    return Wait_For_Zone(25)
end
local function Party_Go_Home()
    local me = windower.ffxi.get_player()
    if not me or not Start_Engine or go_home_active then
        return
    end
    if me.vitals and me.vitals.hp <= 0 then
        Say('Dead, cannot go home.')
        return
    end
    go_home_active = true
    go_home_zoned = false
    Say('Going home...')
    windower.send_command('input /attack off')
    if Clear_Combat_Target then
        Clear_Combat_Target()
    end
    windower.ffxi.follow(0)
    windower.ffxi.run(false)
    -- Keep the rest of Lazy from starting casts while the item is used.
    coroutine.schedule(function()
        while go_home_active do
            isBusy = math.max(isBusy or 0, 3)
            coroutine.sleep(1)
        end
    end, 0)
    for _, spec in ipairs(Opt('go_home_items', DEFAULT_WARP_ITEMS)) do
        if not go_home_active then
            return
        end
        if Warp_Via(spec) then
            return
        end
    end
    if not go_home_active then
        return
    end
    go_home_active = false
    Start_Engine = false
    print('go home command executed, no way home. Character has been logged out.')
    windower.send_command('input /logout')
end
windower.register_event('zone change', function()
    party_buffs = {}
    if go_home_active then
        go_home_active = false
        go_home_zoned = true
        Start_Engine = false
        windower.add_to_chat(2, '....Stopping Lazy Helper....')
        Party_Print_Stats()
    end
end)

-- MONITOR
function Party_Tick()
    local me_player = windower.ffxi.get_player()
    if not me_player then
        return
    end
    -- A party join ("chicken nuggets") owns the party until it finishes.
    if party_join_active then
        rez_pause_active = false
        party_rez_busy = false
        return
    end
    known_cache = windower.ffxi.get_spells()
    local roster = Roster()
    local me
    for _, e in ipairs(roster) do
        if e.is_me then
            me = e
        end
    end
    if not me then
        return
    end
    -- Pause the party while anyone is dead, and (optionally) until the raised
    -- player's Weakness is gone. Capped so an AFK corpse cannot freeze it.
    local want_pause = false
    if Opt('rez_enabled', true) ~= false then
        for _, e in ipairs(roster) do
            if e.dead then
                want_pause = true
            elseif Opt('wait_for_weakness', true) and e.in_zone and Buff_Set(e)[WEAKNESS_BUFF_ID] then
                want_pause = true
            end
        end
    end
    local now = os.clock()
    if want_pause then
        rez_pause_since = rez_pause_since or now
        rez_pause_active = (now - rez_pause_since) <= Opt('rez_pause_max', 900)
    else
        rez_pause_since = nil
        rez_pause_active = false
    end
    if me.dead then
        return
    end
    Doom_Self_Tick(me)
    Rez_Tick(roster, me)
    if not party_rez_busy then
        Cleanse_Tick(roster)
    end
end
function Party_Monitor()
    while Start_Engine do
        Safe_Tick('Party_Tick', Party_Tick)
        coroutine.sleep(1)
    end
    rez_walking = false
    regroup_walking = false
    party_rez_busy = false
    Sync_Override()
end
function Party_Start()
    party_hold = false
    regroup_active = false
    go_home_active = false
    go_home_zoned = false
    rez_pause_active = false
    party_rez_busy = false
    rez_walking = false
    regroup_walking = false
    rez_pause_since = nil
    rez_claim_until = 0
    Clear_Table(rez_first_seen)
    Clear_Table(rez_started_at)
    Clear_Table(cleanse_seen)
    Clear_Table(cleanse_cd)
    Sync_Override()
    Party_Stats_Reset()
end
-- TargetLogic.lua reads these.
function Party_Paused()
    return (party_hold or regroup_active or go_home_active or rez_pause_active) and true or false
end
function Party_Hold_Combat()
    return (party_rez_busy or go_home_active) and true or false
end

-- PARTY-CHAT PHRASES
local PHRASE_HANDLERS = {}
PHRASE_HANDLERS.reset = function(sender)
    if not Start_Engine then
        return
    end
    Say('Reset requested by ' .. sender .. ': re-anchoring the origin here.')
    windower.ffxi.run(false)
    windower.ffxi.follow(0)
    Clear_Table(unattackable_until)
    Set_Origin()
end
PHRASE_HANDLERS.go_home = function(sender)
    if not Start_Engine or go_home_active then
        return
    end
    Say('Go home requested by ' .. sender .. '.')
    coroutine.schedule(Party_Go_Home, 0)
end
PHRASE_HANDLERS.stop = function(sender)
    if not Start_Engine then
        return
    end
    Say('Stop requested by ' .. sender .. '.')
    windower.add_to_chat(2, '....Stopping Lazy Helper....')
    Start_Engine = false
    windower.ffxi.follow(0)
    windower.ffxi.run(false)
end
PHRASE_HANDLERS.start = function(sender)
    if Start_Engine then
        return
    end
    Say('Start requested by ' .. sender .. '.')
    windower.send_command('lazy start')
end
PHRASE_HANDLERS.hold = function(sender)
    if not Start_Engine then
        return
    end
    party_hold = true
    Say('Holding (' .. sender .. '): no new pulls. Say "' .. Phrase('resume') .. '" to continue.')
end
PHRASE_HANDLERS.resume = function(sender)
    if not Start_Engine then
        return
    end
    regroup_run = regroup_run + 1
    regroup_walking = false
    regroup_active = false
    party_hold = false
    Sync_Override()
    Say('Resuming (' .. sender .. '): new origin set here.')
    windower.ffxi.follow(0)
    Set_Origin()
end
PHRASE_HANDLERS.regroup = function(sender)
    if not Start_Engine then
        return
    end
    local party = windower.ffxi.get_party()
    local me = windower.ffxi.get_player()
    local leader_id = party and party.party1_leader
    if not leader_id or not me then
        return
    end
    party_hold = true
    if leader_id == me.id then
        Say('Leader holding here (' .. sender .. '). Say "' .. Phrase('resume') .. '" to continue.')
        return
    end
    regroup_run = regroup_run + 1
    local run = regroup_run
    regroup_active = true
    regroup_walking = true
    Sync_Override()
    Say('Regrouping on the leader (' .. sender .. '). Say "' .. Phrase('resume') .. '" to continue.')
    coroutine.schedule(function()
        local deadline = os.clock() + Opt('regroup_timeout', 45)
        while run == regroup_run and Start_Engine and os.clock() < deadline do
            local leader = windower.ffxi.get_mob_by_id(leader_id)
            if leader and type(leader.distance) == 'number' then
                if math.sqrt(leader.distance) > 4 then
                    windower.ffxi.follow(leader.index)
                else
                    break
                end
            end
            coroutine.sleep(0.5)
        end
        if run == regroup_run then
            windower.ffxi.follow(0)
            regroup_active = false
            regroup_walking = false
            Sync_Override()
        end
    end, 0)
end
PHRASE_HANDLERS.rebuff = function(sender)
    if not Start_Engine then
        return
    end
    for _, t in ipairs({
        self_buff_last_cast, self_ability_last_cast, haste_last_cast,
        refresh_last_cast, party_buff_last_cast, entrust_last_cast,
        entrust_ability_last_attempt, entrust_ability_last_success,
    }) do
        Clear_Table(t)
    end
    Say('Rebuffing everything (' .. sender .. ').')
end
PHRASE_HANDLERS.tnl = function()
    Party_Tnl()
end
windower.register_event('chat message', function(message, sender, mode, gm)
    if mode ~= 4 or not message or not sender then
        return
    end
    local me = windower.ffxi.get_player()
    if not me then
        return
    end
    -- Our own party chat counts for the phrases (so /p hold works on the
    -- character you typed it on) but never as someone else's "rezzing".
    local is_self = string.lower(sender) == string.lower(me.name)
    local text = Normalize(message)
    if text == Phrase('rezzing') then
        if not is_self then
            rez_claim_until = os.clock() + 25
        end
        return
    end
    for name, handler in pairs(PHRASE_HANDLERS) do
        if text == Phrase(name) then
            if not is_self and not Party_Is_Trusted(sender) then
                Say('Ignored "' .. text .. '" from ' .. sender .. ' (not on the trusted list).')
                return
            end
            handler(sender)
            return
        end
    end
end)

-- COMMAND DISPATCH
-- Called by Lazy.lua's //lazy handler before its own commands. Return true
-- when the command was handled here. Add new //lazy commands below, and new
-- party-chat phrases as PHRASE_HANDLERS.<name> (+ DEFAULT_PHRASES entry).
function Party_Command(command, args, raw_args)
    if command == 'join' then
        if args[2] == 'cancel' then
            Party_Join_Cancel()
        elseif not raw_args[2] then
            print('//lazy join <name>  |  //lazy join cancel')
        else
            Party_Join_Begin(raw_args[2])
        end
        return true
    end
    if command == 'sync' then
        if args[2] == 'off' then
            Clear_Level_Sync()
        elseif not raw_args[2] then
            print('//lazy sync <name>  |  //lazy sync off')
        else
            Set_Level_Sync(raw_args[2])
        end
        return true
    end
    if command == 'trust' then
        local sub = args[2]
        local list = Trusted_Names()
        if (sub == 'add' or sub == 'remove') and raw_args[3] then
            local want = string.lower(raw_args[3])
            local out, found = {}, false
            for _, n in ipairs(list) do
                if string.lower(n) == want then
                    found = true
                    if sub == 'add' then
                        out[#out + 1] = n
                    end
                else
                    out[#out + 1] = n
                end
            end
            if sub == 'add' and not found then
                out[#out + 1] = raw_args[3]
            end
            Save_Trusted(out)
            list = out
        elseif sub == 'clear' then
            Save_Trusted({})
            list = {}
        end
        if #list == 0 then
            Say('Trusted players: everyone (list is empty).')
        else
            Say('Trusted players: ' .. table.concat(list, ', '))
        end
        return true
    end
    if command == 'tnl' then
        Party_Tnl()
        return true
    end
    if command == 'party' then
        local phrase = Normalize(table.concat(raw_args, ' ', 2))
        for name, handler in pairs(PHRASE_HANDLERS) do
            if phrase == Phrase(name) or phrase == (name:gsub('_', ' ')) then
                handler('console')
                return true
            end
        end
        print('//lazy party <reset|go home|stop|start|hold|resume|regroup|rebuff|tnl>')
        return true
    end
    return false
end
-- Lines for //lazy help.
function Party_Command_Help()
    print('//lazy join <name>   (same as them telling you the phrase)')
    print('//lazy join cancel')
    print('//lazy sync <name>   (level sync to that party member)')
    print('//lazy sync off')
    print('//lazy trust add|remove <name>  |  //lazy trust list|clear   (who may use party commands; empty = everyone)')
    print('//lazy tnl   (session time, kills, EXP, EXP to next level)')
    print('//lazy party <phrase>   (run a party command locally)')
    print('Party chat: reset | go home | stop | start | hold | resume | regroup | rebuff | tnl')
end