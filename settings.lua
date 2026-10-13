-- Settings.Lua — GLOBAL CONFIGURATION
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
-- DISPEL WHITELIST
-- Mobs Lazy is allowed to safety-cast Dispel (or Finale, for BRD) on.
-- Matched as a case-insensitive substring against the target's name, so
-- one entry like 'Beetle' covers every named Beetle mob.
dispel_whitelist = {
    'Beetle',
    'Crab',
}
-- HASTE BLACKLIST
-- Players who must never receive Haste II from Lazy.
-- Self-haste is unaffected.
haste_blacklist = {
    'Ulmia',
    'Joachim',
    'Yoran-Oran',
    'Sylvie',
    'Koru-Moru',
}
-- PARTY JOIN (TrustLogic.lua)
-- Someone sends the bot a tell containing exactly the phrase below:
-- new pulls pause, they get invited, the party level-syncs to the lowest
-- level / master level, and trusts are resummoned minus however many
-- slots the new player needs.
party_join = {
    enabled = true,
    phrase = 'chicken nuggets',
    -- {} = anyone who knows the phrase can use it. Or limit it:
    -- allowed_senders = { 'Faceroll', 'Norrec' },
    allowed_senders = {},
    invite_timeout = 60,   -- seconds to wait for them to accept the invite
    fight_timeout = 120,   -- seconds to let a fight in progress finish first
    level_sync = true,
}
-- Trust names exactly as the party list shows them, and their jobs.
-- (Game data has no job for trusts, so this is hardcoded.)
trust_jobs = {
    ['Ulmia'] = 'BRD',
    ['Joachim'] = 'BRD',
    ['Koru-Moru'] = 'RDM',
    ['Yoran-Oran'] = 'WHM',
    ['Sylvie'] = 'GEO',
    ['Qultada'] = 'COR',
}
-- Who gets dropped when the new player's job matches none of the trusts.
-- One group per step; inside a group, whichever is out is dropped first.
trust_sacrifice_order = {
    { 'Ulmia', 'Joachim' },
    { 'Qultada' },
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