-- Roll detection and logging, ported from RollTracker by Balloon

local roll_lucky = {
    ["Allies'"]      = {3, 10}, ["Beast"]        = {4,  8},
    ["Blitzer's"]    = {4,  9}, ["Bolter's"]     = {3,  9},
    ["Caster's"]     = {2,  7}, ["Chaos"]        = {4,  8},
    ["Choral"]       = {2,  6}, ["Companion's"]  = {2, 10},
    ["Corsair's"]    = {5,  9}, ["Courser's"]    = {3,  9},
    ["Dancer's"]     = {3,  7}, ["Drachen"]      = {4,  8},
    ["Evoker's"]     = {5,  9}, ["Fighter's"]    = {5,  9},
    ["Gallant's"]    = {3,  7}, ["Healer's"]     = {3,  7},
    ["Hunter's"]     = {4,  8}, ["Magus's"]      = {2,  6},
    ["Miser's"]      = {5,  7}, ["Monk's"]       = {3,  7},
    ["Naturalist's"] = {3,  7}, ["Ninja"]        = {4,  8},
    ["Puppet"]       = {3,  7}, ["Rogue's"]      = {5,  9},
    ["Runeist's"]    = {4,  8}, ["Samurai"]      = {2,  6},
    ["Scholar's"]    = {2,  6}, ["Tactician's"]  = {5,  8},
    ["Warlock's"]    = {4,  8}, ["Wizard's"]     = {5,  9},
}

local roll_info     = {}
local roll_callback = nil

function rolls_set_callback(fn)
    roll_callback = fn
end

windower.register_event('load', function()
    local names = {
        "Allies'", "Beast", "Blitzer's", "Bolter's", "Caster's", "Chaos", "Choral",
        "Companion's", "Corsair's", "Courser's", "Dancer's", "Drachen", "Evoker's",
        "Fighter's", "Gallant's", "Healer's", "Hunter's", "Magus's", "Miser's",
        "Monk's", "Naturalist's", "Ninja", "Puppet", "Rogue's", "Runeist's",
        "Samurai", "Scholar's", "Tactician's", "Warlock's", "Wizard's",
    }
    for _, name in ipairs(names) do
        local ability = res.job_abilities:with('english', name .. ' Roll')
        if ability then
            roll_info[ability.id] = name
        end
    end
end)

windower.register_event('action', function(act)
    if act.category ~= 6 then return end
    local name = roll_info[act.param]
    if not name then return end
    if not (act.targets and act.targets[1] and act.targets[1].actions and act.targets[1].actions[1]) then return end

    local num = act.targets[1].actions[1].param
    local actor = windower.ffxi.get_mob_by_id(act.actor_id)
    local actor_name = actor and actor.name or 'Unknown'

    local suffix = ''
    if num == 12 then
        suffix = ' [BUST!]'
    elseif num == 11 then
        suffix = ' [Lucky!]'
    elseif roll_lucky[name] then
        if num == roll_lucky[name][1] then
            suffix = ' [Lucky!]'
        elseif num == roll_lucky[name][2] then
            suffix = ' [Unlucky]'
        end
    end

    windower.add_to_chat(2, actor_name .. ': ' .. name .. ' Roll ' .. tostring(num) .. suffix)
    if roll_callback and act.actor_id == windower.ffxi.get_player().id then
        local lucky = roll_lucky[name]
        local is_lucky = num == 11 or (lucky and num == lucky[1])
        roll_callback(name, num, is_lucky)
    end
end)
