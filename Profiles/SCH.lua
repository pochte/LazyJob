-- SCH JOB PROFILE
-- Scholar magic bursts and backup healing when no WHM is present.

JOB_PROFILES.SCH = {
	-- ENGAGE
	auto_engage = false,
	use_weaponskills = false,

	-- SUPPORT
	haste_active = false,
	self_buffs = {},
	magic_burst = true,
	cure_bot_if_no_whm = true,

	-- CURE TIERS
	cure_tiers = {
		{ max_missing = 250,  spells = { 'Cure II', 'Cure' } },
		{ max_missing = 600,  spells = { 'Cure III', 'Cure II' } },
		{ max_missing = 1100, spells = { 'Cure IV', 'Cure III' } },
		{ max_missing = math.huge, spells = { 'Cure IV', 'Cure III' } },
	},

	-- FREE NUKE (//lazy freenuke). Tier IV and lower are cast on the target
	-- between bursts; V and VI are saved for magic burst.
	free_nuke = true,
	free_nuke_max_tier = 4,
	free_nuke_weather = true, -- failsafe: cast the matching Storm if the weather is wrong

	-- MAGIC BURST
	burst_spells = {
		Fire     = { 'Fire V', 'Fire IV', 'Fire III' },
		Blizzard = { 'Blizzard V', 'Blizzard IV', 'Blizzard III' },
		Aero     = { 'Aero V', 'Aero IV', 'Aero III' },
		Stone    = { 'Stone V', 'Stone IV', 'Stone III' },
		Thunder  = { 'Thunder V', 'Thunder IV', 'Thunder III' },
		Water    = { 'Water V', 'Water IV', 'Water III' },
		Darkness = { 'Impact' },
	},
}