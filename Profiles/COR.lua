------------------------------------------------------------
-- COR JOB PROFILE
------------------------------------------------------------
--
-- Corsair -- Rolls, Quick Draw, ranged weaponskills.
--
-- Loaded by Lazy.lua into JOB_PROFILES.COR
------------------------------------------------------------

JOB_PROFILES.COR = {

	auto_engage = true,
	use_weaponskills = true,

	haste_active = false,
	haste_samba_active = true,
	self_buffs = {},

	needed_buffs = {
		'Fighter\'s Roll',
		'Chaos Roll',
		'Box Step',
		'Reverse Flourish',
	},

	ws_sc_starter = {
		'Wildfire',
		1000,
	},

	ws_sc_closers = {
		'Wildfire',
	},

	box_step = true,
	reverse_flourish = true,
	saber_dance = true,
	haste_samba = true,
	
	food = 'Red Curry Bun',
}