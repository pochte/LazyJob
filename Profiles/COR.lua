-- COR JOB PROFILE 
-- Corsair -- Rolls, Quick Draw, ranged weaponskills.
-- Loaded by Lazy.lua into JOB_PROFILES.COR 
dofile(windower.addon_path .. 'Logic/rolls.lua')
JOB_PROFILES.COR = {
	auto_engage = true,
	use_weaponskills = true,
	haste_active = false,
	-- Haste Samba (DNC sub) is controlled by the global
	-- haste_samba_active switch in settings.lua, not a per-profile
	-- field -- this one did nothing, same for the dead fields below.
	self_buffs = {},
	needed_buffs = {
		'Fighter\'s Roll',
		'Chaos Roll',
	},
	ws_sc_starter = {
		'Wildfire',
		1000,
	},
	ws_sc_closers = {
		'Wildfire',},
	food = 'Red Curry Bun',
}