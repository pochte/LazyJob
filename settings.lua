-- LAZY — GLOBAL CONFIGURATION
-- Shared configuration and fallback values.
--
-- Job-specific rotations, buffs, food, and combat behaviour
-- belong in profiles/*.lua and are handled by JobLogic.lua.
--
-- Reload in-game with: //lazy reload
-- WEAPON SKILL FALLBACKS
-- Used when the active job profile does not define these.
ws_sc_starter = {'Savage Blade',}
ws_sc_closers = {
    'Savage Blade',
}
-- SPELL BLACKLIST
-- Monster names Lazy must never cast its configured offensive
-- spell on. Names are matched case-insensitively.
spell_blacklist = {
    'Locus Colibri',
}
-- HASTE BLACKLIST
-- Players who must never receive Haste II from Lazy.
-- Self-haste is unaffected.
haste_blacklist = {
    'Ulmia',
    'Joachim',
    'Yoran-Oran',
    'Sylvie',
    'Kuru-Moru',
}
-- TARGETING
-- Shared monster whitelist and targeting rules.
--
-- Player-owned pets and GEO Luopans must be excluded by
-- TargetLogic.lua using ownership checks. Do not exclude
-- pets as a general category; DRG and SMN behaviour must
-- remain unaffected.
targeting = {
    -- Monster names Lazy is allowed to target.
    monsters = {
        'Colibri',
        'Bat',
        'Apex Eft',
    },
    -- Only target mobs nobody has claimed.
    only_unclaimed = true,
    -- Never target dead mobs.
    only_alive = true,
    -- Restrict target selection to the configured origin radius.
    within_origin = true,
}
-- DEFAULT BUFF / FOOD FALLBACKS
-- Used when the active job profile does not provide these.
needed_buffs = {}
food = 'Red Curry Bun'
-- SUBJOB ABILITIES
-- Abilities granted by a specific subjob, independent of
-- the main-job profile.
--
-- Any job subbing DNC can use Haste Samba.
-- Intervals are measured in minutes.
haste_samba_active = true
subjob_abilities = {
    DNC = {
        {
            name = 'Haste Samba',
            interval = 2,
        },
    },
}