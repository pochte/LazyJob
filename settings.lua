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
-- MAGIC BURST TIMING
-- 'final' (default): burst only at the END of a chain. A closed chain
--   (Radiance / Umbra, or past the last step) can't be continued by anyone,
--   so it is burst right away. An open one, Light included, counts as ended
--   once nobody has continued it for burst_quiet seconds.
-- 'any': burst any open window as soon as it opens.
burst_when = 'final'
burst_quiet = 2       -- seconds an open chain must sit untouched to count as ended
burst_min_left = 0.8  -- don't start a burst with less window than this left
burst_gap = 0.7       -- seconds between burst casts (fast cast can burst 2-3 times)
-- Which elements burst which skillchain, tried in order (a weakness that
-- fits goes first). The defaults follow bg-wiki; override one if you like:
-- burst_elements = { Light = { 'Wind', 'Fire' }, Darkness = { 'Dark', 'Ice' } }
-- PARTYCHAIN (//lazy partychain): when two weaponskills make the same level
-- of skillchain, favour them in this order. Optional, a profile can set it.
-- partychain_prefer = { 'Blade: Shun', 'Blade: Kamu' }
-- FREE NUKE WEAKNESSES (BLM, SCH: //lazy freenuke)
-- Which element a mob is weak to, so free nukes use the right spell. Matched
-- as whole words in the mob's name, case-insensitive, first match wins. The
-- element is the spell family: Fire, Blizzard, Aero, Stone, Thunder, Water.
-- A profile can set its own nuke_weakness. Mobs that match nothing are not
-- free nuked (a note is printed once per mob name); set nuke_default to nuke
-- them with some element anyway.
nuke_weakness = {
    { 'Worm',   'Fire' },
    { 'Bat',    'Aero' },
    { 'Beetle', 'Blizzard' },
    { 'Eft',    'Blizzard' },
    { 'Crab',   'Blizzard' },
}
-- nuke_default = 'Thunder'
-- ORDERED SKILLCHAIN (optional, works in a profile too)
-- Up to 5 weaponskills fired in this exact order. Entry 1 opens, the
-- chain stops after the last entry. An entry is a name, or { name, min_tp }
-- (default 1000). When set it replaces ws_sc_starter / ws_sc_closers.
-- ws_sc_chain = {
--     { 'Savage Blade', 2000 },
--     'Aeolian Edge',
--     'Evisceration',
--     "Rudra's Storm",
--     'Exenterator',
-- }
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
-- PARTY COMMANDS (Logic/PartyCommands.lua)
-- Say these in PARTY chat (the whole line, exactly). Who may use them is the
-- trusted_players list in settings.xml: //lazy trust add|remove|list|clear.
-- Empty list = everyone.
--   reset     everyone re-anchors their origin where they stand (stuck behind a rock)
--   go home   everyone warps (items below, in order), then Lazy stops and prints stats
--   stop / start   stop or start Lazy on everyone
--   hold      no new pulls until "resume"      resume   continue + new origin here
--   regroup   run to the party leader and hold  (then say "resume")
--   rebuff    forget every buff timer so everything is recast
--   tnl       print this character's session stats to the console (also //lazy tnl)
-- Automatic: a dead player says "rez" and a WHM > SCH > RDM > PLD > anyone with a
-- raise sub job raises them; the party waits for Weakness to wear off. Doom is
-- announced once, Holy Water is used, and Cursna casters work on it. Other
-- debuffs are cleansed by WHM/SCH (main or sub) except those in cleanse_ignore.
party_commands = {
    -- phrases = { go_home = 'go home' },     -- rename any phrase here
    rez_enabled = true,
    rez_timeout = 180,         -- dead this long with no raise: Lazy stops (as before)
    rez_step = 4,              -- seconds between each raiser's turn
    rez_last_ditch_wait = 10,  -- extra wait for jobs that only raise from a sub job
    rez_give_up = 90,          -- stop working on one corpse after this long
    rez_pause_max = 900,       -- never keep the party paused longer than this
    wait_for_weakness = true,
    raise_accept_param = 0,    -- dead character accepting the raise prompt (try 1 if it declines)
    doom_holy_water = true,
    holy_water_tries = 8,
    cleanse_step = 2,
    cleanse_ignore = { 'Evasion Down' },
    regroup_timeout = 45,
    -- Warp items, tried in order. slot = where to equip it first (nil = just use it).
    go_home_items = {
        { name = 'Warp Ring',   slot = 'ring2' },
        { name = 'Treat Staff', slot = 'main' },
        { name = 'Warp Cudgel', slot = 'main' },
        { name = 'Instant Warp' },
    },
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