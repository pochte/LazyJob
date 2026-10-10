-- WAR JOB PROFILE
-- Warrior weaponskill and buff settings.

JOB_PROFILES.WAR = {
	-- ENGAGE
	auto_engage = true,
	use_weaponskills = true,

	haste_active = false,
	self_buffs = {},

	-- WEAPONSKILLS
	ws_sc_starter = { 'Upheaval', 2000 },
	ws_sc_closers = { "Ukko's Fury" },

	-- BUFFS
	needed_buffs = {
		'Hasso', 'Berserk', 'Blood Rage', 'Aggressor',
	},

	food = 'Red Curry Bun',

	-- STUCK RECOVERY
	-- Provoke and re-face if engaged without landing hits.
	provoke_if_stuck = true,
	stuck_threshold = 10,
}