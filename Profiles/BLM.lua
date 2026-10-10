-- BLM JOB PROFILE
-- Black Mage magic burst spells (Tier VI cap).

JOB_PROFILES.BLM = {
	-- MELEE
	auto_engage = false,
	use_weaponskills = false,

	-- SUPPORT
	haste_active = false,
	self_buffs = {},

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