-- Skillchain detection for Lazy
-- Logic ported from SkillChains by Ivaar

require('actions')
local skills = dofile(windower.addon_path .. 'skills.lua')

local sc_info = {
    Radiance     = {'Fire','Wind','Lightning','Light', lvl=4},
    Umbra        = {'Earth','Ice','Water','Dark', lvl=4},

    Light        = {
        'Fire','Wind','Lightning','Light',
        Light={4,'Light','Radiance'},
        lvl=3
    },

    Darkness     = {
        'Earth','Ice','Water','Dark',
        Darkness={4,'Darkness','Umbra'},
        lvl=3
    },

    Gravitation  = {
        'Earth','Dark',
        Distortion={3,'Darkness'},
        Fragmentation={2,'Fragmentation'},
        lvl=2
    },

    Fragmentation = {
        'Wind','Lightning',
        Fusion={3,'Light'},
        Distortion={2,'Distortion'},
        lvl=2
    },

    Distortion = {
        'Ice','Water',
        Gravitation={3,'Darkness'},
        Fusion={2,'Fusion'},
        lvl=2
    },

    Fusion = {
        'Fire','Light',
        Fragmentation={3,'Light'},
        Gravitation={2,'Gravitation'},
        lvl=2
    },

    Compression = {
        'Darkness',
        Transfixion={1,'Transfixion'},
        Detonation={1,'Detonation'},
        lvl=1
    },

    Liquefaction = {
        'Fire',
        Impaction={2,'Fusion'},
        Scission={1,'Scission'},
        lvl=1
    },

    Induration = {
        'Ice',
        Reverberation={2,'Fragmentation'},
        Compression={1,'Compression'},
        Impaction={1,'Impaction'},
        lvl=1
    },

    Reverberation = {
        'Water',
        Induration={1,'Induration'},
        Impaction={1,'Impaction'},
        lvl=1
    },

    Transfixion = {
        'Light',
        Scission={2,'Distortion'},
        Reverberation={1,'Reverberation'},
        Compression={1,'Compression'},
        lvl=1
    },

    Scission = {
        'Earth',
        Liquefaction={1,'Liquefaction'},
        Reverberation={1,'Reverberation'},
        Detonation={1,'Detonation'},
        lvl=1
    },

    Detonation = {
        'Wind',
        Compression={2,'Gravitation'},
        Scission={1,'Scission'},
        lvl=1
    },

    Impaction = {
        'Lightning',
        Liquefaction={1,'Liquefaction'},
        Detonation={1,'Detonation'},
        lvl=1
    },
}

 
-- SKILLCHAIN MESSAGE IDS 

local skillchain_ids = {
    [288]=true,
    [289]=true,
    [290]=true,
    [291]=true,
    [292]=true,
    [293]=true,
    [294]=true,
    [295]=true,
    [296]=true,
    [297]=true,
    [298]=true,
    [299]=true,
    [300]=true,
    [301]=true,

    [385]=true,
    [386]=true,
    [387]=true,
    [388]=true,
    [389]=true,
    [390]=true,
    [391]=true,
    [392]=true,
    [393]=true,
    [394]=true,
    [395]=true,
    [396]=true,
    [397]=true,

    [767]=true,
    [768]=true,
    [769]=true,
    [770]=true,
}

 
-- ACTION MESSAGE IDS 

local message_ids = {
    [110]=true,
    [185]=true,
    [187]=true,
    [317]=true,
    [802]=true,
}

 
-- ACTION CATEGORIES THAT CAN CREATE
-- SKILLCHAIN RESONANCE 

local ws_categories = {
    weaponskill_finish = true,
    ranged_finish      = true,
    ability_finish     = true,
    mob_tp_finish      = true,
    avatar_tp_finish   = true,
    pet_tp_finish      = true,
}

 
-- ACTIVE SKILLCHAINS
--
-- target_id ->
-- {
--     active = {'Fusion'},
--     delay  = timestamp,
--     times  = timestamp,
--     step   = number,
--     closed = boolean,
-- } 

local resonating = {}

 
-- CHECK WHETHER TWO SETS OF SC PROPERTIES
-- CAN COMBINE 

local function check_props(old, new)

    for k = 1, #old do

        local first = old[k]
        local combo = sc_info[first]

        if combo then

            for i = 1, #new do

                local second = new[i]

                local result =
                    combo[second]

                if result then
                    return unpack(result)
                end

                if #old > 3
                    and combo.lvl == sc_info[second]
                    and sc_info[second].lvl then

                    break
                end
            end
        end
    end
end

 
-- CREATE / UPDATE ACTIVE SC 

local function apply_properties(
    target,
    active,
    delay,
    step,
    closed
)

    local clock = os.clock()

    resonating[target] = {

        active = active,

        delay =
            clock + delay,

        times =
            clock + delay + 8 - step,

        step =
            step,

        closed =
            closed or false,
    }
end

 
-- TRUE WHEN SC WINDOW EXISTS
--
-- This includes both:
--
-- RED  "Wait"
-- GREEN "Go!" 

function sc_active(target_id)

    local reson =
        resonating[target_id]

    if not reson then
        return false
    end

    if reson.closed then

        resonating[target_id] =
            nil

        return false
    end

    local now =
        os.clock()

    if now > reson.times then

        resonating[target_id] =
            nil

        return false
    end

    return true
end

 
-- TRUE WHEN SC WINDOW IS IN THE
-- GREEN "GO!" / BURST PHASE 

function sc_ready(target_id)

    local reson =
        resonating[target_id]

    if not reson then
        return false
    end

    if reson.closed then

        resonating[target_id] =
            nil

        return false
    end

    local now =
        os.clock()

    if now > reson.times then

        resonating[target_id] =
            nil

        return false
    end

    return now >= reson.delay
end

 
-- GET CURRENT SKILLCHAIN PROPERTY
--
-- Examples:
--
--     Light
--     Darkness
--     Fusion
--     Fragmentation
--     Distortion
--     Gravitation
--     etc.
--
-- This is used by the magic-burst logic
-- in lazy.lua. 

function sc_get_property(target_id)

    local reson =
        resonating[target_id]

    if not reson then
        return nil
    end

    if reson.closed then

        resonating[target_id] =
            nil

        return nil
    end

    local now =
        os.clock()

    if now > reson.times then

        resonating[target_id] =
            nil

        return nil
    end

    if not reson.active then
        return nil
    end

    return reson.active[1]
end

 
-- GET MAIN WEAPON NAME 

local function get_main_weapon_name()

    local items =
        windower.ffxi.get_items()

    if not items
        or not items.equipment then

        return ''
    end

    local main_idx =
        items.equipment.main

    if not main_idx
        or main_idx == 0 then

        return ''
    end

    local main_item =
        windower.ffxi.get_items(
            0,
            main_idx
        )

    if not main_item
        or not main_item.id
        or main_item.id == 0 then

        return ''
    end

    local res_item =
        res.items[main_item.id]

    return
        res_item
        and res_item.en
        or ''
end

 
-- GET SKILLCHAIN PROPERTIES FOR A WS 

local function get_sc_props(
    skill,
    weapon_name
)

    if skill.aeonic
        and skill.weapon == weapon_name then

        local props = {}

        for i, v in ipairs(
            skill.skillchain
        ) do

            props[i] = v
        end

        props[#props + 1] =
            skill.aeonic

        return props
    end

    return skill.skillchain
end

 
-- GET AVAILABLE WS THAT CAN CLOSE
-- THE CURRENT SKILLCHAIN 

function sc_get_ws(target_id)

    local reson =
        resonating[target_id]

    if not reson then
        return {}
    end

    local ws_ids =
        windower.ffxi.get_abilities().weapon_skills

    local main_name =
        get_main_weapon_name()

    local result = {}

    for k = 1, #ws_ids do

        local id =
            ws_ids[k]

        local skill =
            skills.weapon_skills[id]

        if skill then

            local props =
                get_sc_props(
                    skill,
                    main_name
                )

            local lv, prop =
                check_props(
                    reson.active,
                    props
                )

            if prop then

                result[#result + 1] =
                    skill.en
            end
        end
    end

    return result
end

 
-- ACTION PACKET HANDLER 

local function action_handler(act)

    local ap =
        ActionPacket.new(act)

    local category =
        ap:get_category_string()

    if not ws_categories[category]
        or act.param == 0 then

        return
    end

    local target =
        ap:get_targets()()

    if not target then
        return
    end

    local action =
        target:get_actions()()

    if not action then
        return
    end

    local message_id =
        action:get_message_id()

    local add_effect =
        action:get_add_effect()

    local param,
          resource,
          action_id,
          interruption,
          conclusion =
        action:get_spell()

    local ability =
        skills[resource]
        and skills[resource][action_id]


       -- NEW SKILLCHAIN FORMED
   
    if add_effect
        and skillchain_ids[
            add_effect.message_id
        ] then

        local sc_name =
            add_effect.animation:ucfirst()

        local sc_data =
            sc_info[sc_name]

        local level =
            sc_data
            and sc_data.lvl
            or 1

        local reson =
            resonating[target.id]

        local delay =
            ability
            and ability.delay
            or 3

        local step =
            (reson and reson.step or 1) + 1

        local closed =
            step > 5
            or level == 4

        apply_properties(
            target.id,
            {sc_name},
            delay,
            step,
            closed
        )


       -- INITIAL WEAPONSKILL / ABILITY
   
    elseif ability
        and message_ids[message_id] then

        local props =
            ability.skillchain

        if act.actor_id ==
            windower.ffxi.get_player().id then

            props =
                get_sc_props(
                    ability,
                    get_main_weapon_name()
                )
        end

        apply_properties(
            target.id,
            props,
            ability.delay or 3,
            1,
            false
        )
    end
end

 
-- ACTION PACKET LISTENER 

ActionPacket.open_listener(
    function(act)

        local ok, err =
            pcall(
                action_handler,
                act
            )

        if not ok then

            windower.add_to_chat(
                2,
                '[SC] action_handler error: '..
                tostring(err)
            )
        end
    end
)

 
-- CLEAN UP EXPIRED SKILLCHAINS 

local prerender_next = 0

windower.register_event(
    'prerender',
    function()

        local now =
            os.clock()

        if now < prerender_next then
            return
        end

        prerender_next =
            now + 0.1

        for id, reson in pairs(
            resonating
        ) do

            if now > reson.times then

                resonating[id] =
                    nil
            end
        end
    end
)