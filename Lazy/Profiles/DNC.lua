    
-- DNC JOB PROFILE 
--
-- Dancer -- weaponskill skillchain settings, step/flourish/waltz
-- rotation (see Try_DNC_Actions in Lazy.lua).
--
-- Loaded by Lazy.lua into JOB_PROFILES.DNC 

JOB_PROFILES.DNC = {

	auto_engage = true,
	use_weaponskills = true,

	haste_active = false,
	self_buffs = {},

	ws_sc_starter = {
		"Rudra's Storm",
		2000,
	},

	ws_sc_closers = {
		"Rudra's Storm",
	},

	      
	-- STEP / FLOURISH / WALTZ ROTATION
	--
	-- Box Step until Finishing Move hits 5 stacks, then
	-- Reverse Flourish (also fires right after any
	-- weaponskill, even below 5 stacks). Emergency Curing
	-- Waltz -- highest tier affordable on current MP --
	-- takes priority over both any time HP drops to 50%.
	      

	dnc_rotation = true,

	food = 'Soy Ramen',
}