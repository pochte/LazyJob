-- THF JOB PROFILE 
-- Thief -- weaponskill skillchain settings, needed buffs before WS.
-- Loaded by Lazy.lua into JOB_PROFILES.THF 
JOB_PROFILES.THF = {
	auto_engage = true,
	use_weaponskills = true,
	haste_active = false,
	self_buffs = {},
	needed_buffs = {
		'Conspirator',
		'Sneak Attack',
		'Trick Attack',
		'Box Step',
		'Reverse Flourish',
	},
	ws_sc_starter = {
		"Rudra's Storm",
		1000,
	},
	ws_sc_closers = {
		"Rudra's Storm",},
	food = 'Soy Ramen',
}