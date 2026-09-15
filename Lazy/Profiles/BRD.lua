    
-- BRD JOB PROFILE 
--
-- Bard -- Party songs, self buffs.
--
-- Loaded by Lazy.lua into JOB_PROFILES.BRD 

JOB_PROFILES.BRD = {

	      ---------
	-- MELEE / ENGAGE SETTINGS
	      ---------

	auto_engage = false,
	use_weaponskills = false,

	haste_active = false,
	self_buffs = {},

	      ---------
	-- PARTY SONGS
	      ---------

	party_buffs = {

		{
			spell    = 'Honor March',
			targets  = 'ALL_PLAYERS',
			interval = 3,
			range    = 20,
			self     = true,
		},

		{
			spell    = "Knight's Minne V",
			targets  = 'ALL_PLAYERS',
			interval = 3,
			range    = 20,
			self     = true,
		},
	},

	needed_buffs = {},

	food = 'Red Curry Bun',
}