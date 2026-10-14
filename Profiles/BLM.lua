-- BLM JOB PROFILE
-- Black Mage magic burst spells (Tier VI cap).

JOB_PROFILES.BLM = {
	-- MELEE
	auto_engage = false,
	use_weaponskills = false,

	-- SUPPORT
	haste_active = false,
	self_buffs = {},

	-- FREE NUKE (//lazy freenuke). Tier IV and lower are cast on the target
	-- between bursts; V and VI are saved for magic burst.
	free_nuke = true,
	free_nuke_max_tier = 4,
	free_nuke_weather = true, -- failsafe: cast the matching Storm if the weather is wrong

	-- MAGIC BURST
	magic_burst = true,
	burst_spells = {
		Fire      = { 'Fire VI', 'Fire V', 'Fire IV' },
		Blizzard  = { 'Blizzard VI', 'Blizzard V', 'Blizzard IV' },
		Aero      = { 'Aero VI', 'Aero V', 'Aero IV' },
		Stone     = { 'Stone VI', 'Stone V', 'Stone IV' },
		Thunder   = { 'Thunder VI', 'Thunder V', 'Thunder IV' },
		Water     = { 'Water VI', 'Water V', 'Water IV' },
		Darkness  = { 'Comet', 'Impact' },
	},
}