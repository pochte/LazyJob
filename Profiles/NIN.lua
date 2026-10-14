-- NIN JOB PROFILE 
-- Ninja -- Frontline melee, magic bursts during skillchains.
-- Loaded by Lazy.lua into JOB_PROFILES.NIN 
JOB_PROFILES.NIN = {
	auto_engage = true,
	use_weaponskills = true,
	haste_active = false,
	self_buffs = {
		{ name = 'Kakka: Ichi', interval = 5 },
	},
	magic_burst = true,
	burst_spells = {
		Light = {
			'Raiton: San',
			'Raiton: Ni',
			'Raiton: Ichi',
		},
		Darkness = {
			'Hyoton: San',
			'Hyoton: Ni',
			'Hyoton: Ichi',
		},
	},
	ws_sc_starter = {
		'Blade: Ten',
		2000
	},
	ws_sc_closers = {
		'Blade: Ten'
	},
	-- //lazy chainmode: Shun > Kamu > Shun, then the opener fires again once
	-- the window ends, so it repeats. //lazy openmode uses the starter and
	-- closers above instead.
	ws_sc_chain = {
		{ 'Blade: Shun', 1000 },
		{ 'Blade: Kamu', 1000 },
		{ 'Blade: Shun', 1000 },
	},
	food = 'Soy Ramen',
}