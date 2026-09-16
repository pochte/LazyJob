-- Lazy addon — user configuration
-- Edit this file to customize weapon skills, buffs, food, and targeting.
-- Reload in-game with: //lazy reload
-- WEAPON SKILLS 
-- Weapon skill used to open a skillchain.
-- Format: {ws_name, minimum_tp}
ws_sc_starter = {}
-- Weapon skills eligible to close a skillchain.
-- Checked against what the SC system says is available;
-- first matching WS fires.
ws_sc_closers = {
	'Savage Blade',
}
-- MAGIC BURST 
-- When true, settings.spell only fires into an already-open
-- skillchain window for magic burst damage.
magic_burst_active = true
-- SPELL BLACKLIST 
-- Mobs Lazy should NEVER cast settings.spell on.
-- Names are matched case-insensitively.
spell_blacklist = {
	'Locus Colibri',
}
-- DISPEL WHITELIST 
-- Mobs Lazy is allowed to safety-cast Dispel (or Finale, for BRD)
-- on. Matched as a case-insensitive substring against the target's
-- name, so one entry like 'Beetle' covers every named Beetle mob.
--
-- Add new families/names here -- no need to touch any job profile.
dispel_whitelist = {
	'Beetle',
	'Crab',
}
-- HASTE BLACKLIST 
-- Players who never receive Haste II from Lazy, no matter what.
-- Names are matched case-insensitively.
-- Self-haste is unaffected.
-- This only filters party/ALL_PLAYERS haste target lists.
haste_blacklist = {
	'Ulmia',
	'Joachim',
	'Yoran-Oran',
	'Sylvie',
	'Kuru-Moru',
}
-- TARGETING 
targeting = {
	      ---------
	-- MONSTERS LAZY IS ALLOWED TO TARGET
	      ---------
	monsters = {
		'Colibri',
		'Bat',
		'Apex Eft'
	},
	      ---------
	-- TARGETING RULES
	      ---------
	-- Only target mobs that nobody has claimed.
	only_unclaimed = true,
	-- Never target dead mobs.
	only_alive = true,
	-- Only target mobs inside the origin radius.
	within_origin = true,
}
-- NEEDED BUFFS 
-- Buffs to maintain before weapon skilling.
-- Applied in order — first missing and off cooldown wins.
--
-- Use 'Food' as a special entry to trigger food use.
--
-- Job-specific profiles can override this list with their own
-- needed_buffs settings.
needed_buffs = {}
-- SUBJOB ABILITIES 
-- Master switch. Lazy.lua checks this before ever looking at
-- subjob_abilities below -- if this is false (or missing, which
-- is the same as false/nil in Lua), NOTHING here fires, for ANY
-- job, regardless of subjob. This was accidentally dropped from
-- a previous version of this file, which is why Haste Samba
-- stopped firing even with everything else configured correctly.
haste_samba_active = true
-- Job abilities granted by a specific SUBJOB.
--
-- These are completely independent of the main job profile.
-- If the current subjob matches one of the entries below,
-- those abilities are added to the self-ability rotation.
--
-- Therefore:
--
--     THF/DNC -> Haste Samba
--     COR/DNC -> Haste Samba
--     RDM/DNC -> Haste Samba
--     WAR/DNC -> Haste Samba
--     WHM/DNC -> Haste Samba
--     etc.
--
-- Any job /DNC gets Haste Samba automatically.
--
-- Interval is measured in minutes.
subjob_abilities = {
	DNC = {
		{
			name = 'Haste Samba',
			interval = 2,
		},
	},
}
-- SELF ABILITY DEBUG 
-- Set to true only when debugging subjob/self abilities.
-- When true, Lazy prints ability detection information
-- to chat every buff tick.
debug_self_abilities = false
-- FOOD 
-- Food item used when 'Food' is included in needed_buffs.
food = 'Red Curry Bun'