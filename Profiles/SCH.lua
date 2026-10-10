    
-- SCH JOB PROFILE 
--
-- Scholar -- magic burst spell tiers, backup cure bot when no WHM.
--
-- Loaded by Lazy.lua into JOB_PROFILES.SCH 

JOB_PROFILES.SCH = {

	      ---------
	-- MELEE / ENGAGE SETTINGS
	      ---------

	auto_engage = false,
	use_weaponskills = false,

	haste_active = false,
	self_buffs = {},

	magic_burst = true,

	cure_bot_if_no_whm = true,

	cure_tiers = {

		{
			max_missing = 250,
			spells = {
				'Cure II',
				'Cure',
			},
		},

		{
			max_missing = 600,
			spells = {
				'Cure III',
				'Cure II',
			},
		},

		{
			max_missing = 1100,
			spells = {
				'Cure IV',
				'Cure III',
			},
		},

		{
			max_missing = math.huge,
			spells = {
				'Cure IV',
				'Cure III',
			},
		},
	},

	burst_spells = {

		Fire = {
			'Fire V',
			'Fire IV',
			'Fire III',
		},

		Blizzard = {
			'Blizzard V',
			'Blizzard IV',
			'Blizzard III',
		},

		Aero = {
			'Aero V',
			'Aero IV',
			'Aero III',
		},

		Stone = {
			'Stone V',
			'Stone IV',
			'Stone III',
		},

		Thunder = {
			'Thunder V',
			'Thunder IV',
			'Thunder III',
		},

		Water = {
			'Water V',
			'Water IV',
			'Water III',
		},

		Darkness = {
			'Blizzard V',
			'Blizzard IV',
			'Blizzard III',
		},
	},
}