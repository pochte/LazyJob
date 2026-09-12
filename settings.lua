
-- Lazy addon — user configuration
-- Reload in-game with: //lazy reload


------------------------------------------------------------
-- WEAPON SKILLS
------------------------------------------------------------

-- WS used to open a skillchain: {ws_name, minimum_tp}
ws_sc_starter = {}

-- WS eligible to close a skillchain. First matching WS fires.
ws_sc_closers = {
    'Savage Blade',
}


------------------------------------------------------------
-- MAGIC BURST
------------------------------------------------------------

-- When true, settings.spell only fires into an already-open
-- skillchain window for magic burst damage.
magic_burst_active = true


------------------------------------------------------------
-- SPELL BLACKLIST
------------------------------------------------------------

-- Mobs Lazy should NEVER cast settings.spell on.
-- Names are matched case-insensitively.
spell_blacklist = {
    'Locus Colibri',
}


------------------------------------------------------------
-- HASTE BLACKLIST
------------------------------------------------------------

-- Players who never receive Haste II from Lazy.
-- Self-haste is unaffected.
haste_blacklist = {
    'Ulmia',
    'Joachim',
    'Yoran-Oran',
    'Sylvie',
    'Kuru-Moru',
}


------------------------------------------------------------
-- TARGETING
------------------------------------------------------------

targeting = {

    -- Monster names Lazy is allowed to target.
    monsters = {
        'Colibri',
        'Bat',
        'Apex Eft',
    },

    -- Only target mobs that nobody has claimed.
    only_unclaimed = true,

    -- Never target dead mobs.
    only_alive = true,

    -- Only target mobs inside the origin radius.
    within_origin = true,
}


------------------------------------------------------------
-- NEEDED BUFFS
------------------------------------------------------------

-- Buffs to maintain before weapon skilling.
-- Applied in order; first missing/off-cooldown entry wins.
-- 'Food' is a special entry that triggers food use.
-- Job profiles may override this list.
needed_buffs = {}


------------------------------------------------------------
-- SUBJOB ABILITIES
------------------------------------------------------------

-- Master switch. If false/nil, nothing below fires.
haste_samba_active = true

-- Abilities granted by a specific SUBJOB.
-- Any job /DNC gets Haste Samba automatically.
-- Interval is measured in minutes.
subjob_abilities = {
    DNC = {
        {
            name = 'Haste Samba',
            interval = 2,
        },
    },
}


------------------------------------------------------------
-- SELF ABILITY DEBUG
------------------------------------------------------------

-- When true, Lazy prints ability detection information
-- to chat every buff tick.
debug_self_abilities = false


------------------------------------------------------------
-- FOOD
------------------------------------------------------------

-- Food item used when 'Food' is included in needed_buffs.
food = 'Red Curry Bun'

