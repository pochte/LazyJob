    
-- WAR JOB PROFILE 
--
-- Warrior -- weaponskill skillchain settings, needed buffs before WS.
--
-- Loaded by Lazy.lua into JOB_PROFILES.WAR 

JOB_PROFILES.WAR = {

	      
	-- MELEE / ENGAGE SETTINGS
	      

	auto_engage = true,
	use_weaponskills = true,

	haste_active = false,

	self_buffs = {},

	ws_sc_starter = {
		'Upheaval',
		2000,
	},

	ws_sc_closers = {
		"Ukko's Fury",
	},

	needed_buffs = {
		'Hasso',
		'Berserk',
		'Blood Rage',
		'Aggressor',
	},

	food = 'Red Curry Bun',


	      
	-- STUCK RECOVERY
	      
	--
	-- Norrec sometimes gets wedged on terrain (hills etc.)
	-- while "engaged" but never actually landing hits. If
	-- he's been continuously engaged this long with no fix,
	-- Provoke and re-face the target as a recovery kick.
	      

	provoke_if_stuck = true,
	stuck_threshold  = 10,   -- seconds
}