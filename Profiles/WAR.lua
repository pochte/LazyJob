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

	-- //lazy chainmode: Upheaval > Ukkos Fury > Upheaval, then the opener fires again once
	-- the window ends, so it repeats. //lazy openmode uses the starter and
	-- closers above instead.
	ws_sc_chain = {
		{ 'Upheaval', 2000 },
		{ "Ukko's Fury", 1000 },
		{ 'Upheaval', 1000 },
	},
	food = 'Red Curry Bun',

	-- STUCK RECOVERY
	-- Provoke and re-face if engaged without landing hits.
	provoke_if_stuck = false,
	stuck_threshold = 10,
}