-- WHM JOB PROFILE
-- White Mage primary healing and support.
JOB_PROFILES.WHM = {
	-- ENGAGE
	auto_engage = false,
	use_weaponskills = false,

	-- BUFFS
	haste_active = false,
	self_buffs = {
		{ name = 'Protectra V', interval = 30 },
		{ name = 'Shellra V', interval = 30 },
		{ name = 'Auspice', interval = 300 },
		{ name = 'Baraero', interval = 300 },
		{ name = 'Reraise IV', fallback = 'Reraise III', interval = 3600 },
	},

	-- CURE BOT
	cure_bot_active = true,
	cure_tiers = {
		{ max_missing = 250,  spells = { 'Cure II', 'Cure' } },
		{ max_missing = 600,  spells = { 'Cure III', 'Cure II' } },
		{ max_missing = 1100, spells = { 'Cure IV', 'Cure III' } },
		{ max_missing = 1700, spells = { 'Cure V', 'Cure IV' } },
		{ max_missing = math.huge, spells = { 'Cure VI', 'Cure V' } },
	},

	job_abilities = {},
}