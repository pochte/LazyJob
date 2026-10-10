-- TRUSTLOGIC
-- Tracks and resummons trusts that leave the party.
-- Loaded by Lazy.lua via dofile.
-- Shared globals are intentionally not local.
-- TRUST RESUMMON
tracked_trusts = {}
trust_resummon_last = {}
function Snapshot_Trusts()
    tracked_trusts = {}
    local party = windower.ffxi.get_party()
    if not party then
        return
    end
    for _, key in ipairs({'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}) do
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
    if #tracked_trusts == 0 then
        return
    end
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
    if not party then
        return
    end
    local present = {}
    for _, key in ipairs({'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}) do
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
            local spell = res.spells:with('name', name)
            if spell
                and Cast_Spell_On(name, '<me>')
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