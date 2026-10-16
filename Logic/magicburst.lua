
-- MAGICBURST.LUA
-- Shared magic burst and free nuke logic.

-- SKILLCHAIN ELEMENTS
local SC_ELEMENTS = {
	Radiance      = 'Light',
	Umbra         = 'Darkness',

	Light         = 'Light',
	Darkness      = 'Darkness',
	Gravitation   = 'Earth',
	Fragmentation = 'Wind',
	Distortion    = 'Ice',
	Fusion        = 'Fire',

	Compression   = 'Darkness',
	Liquefaction  = 'Fire',
	Induration    = 'Ice',
	Reverberation = 'Water',
	Transfixion   = 'Light',
	Scission      = 'Earth',
	Detonation    = 'Wind',
	Impaction     = 'Lightning',
}

-- Translate skillchain elements into spell-family keys.
local SC_FAMILY = {
	Fire      = 'Fire',
	Ice       = 'Blizzard',
	Wind      = 'Aero',
	Earth     = 'Stone',
	Lightning = 'Thunder',
	Water     = 'Water',
	Light     = 'Light',
	Darkness  = 'Darkness',
}

-- RDM MP-based burst settings.
local RDM_NO_BURST_MP = 350
local RDM_REDUCED_TIER_MP = 500

-- Nuke mode:
--   burst = burst spells only
--   free  = free nukes between skillchains, if enabled for the job
--   off   = disable automatic nuking
nuke_mode = nuke_mode or 'burst'

-- Return the element for the target's current skillchain.
function Get_SC_Element(target)
	if not target or not sc_get_property then
		return nil
	end

	local property = sc_get_property(target.id)
	if not property then
		return nil
	end

	return SC_ELEMENTS[property]
end

-- Return a spell's tier from its Roman numeral suffix.
local function Get_Burst_Spell_Tier(spell_name)
	if not spell_name then
		return nil
	end

	local roman = spell_name:match(' ([IVX]+)$')

	if not roman then
		-- Impact is a special spell, not a normal elemental nuke tier.
		if spell_name == 'Impact' then
			return nil
		end

		return 1
	end

	local tiers = {
		I = 1,
		II = 2,
		III = 3,
		IV = 4,
		V = 5,
		VI = 6,
	}

	return tiers[roman]
end

-- Return the strongest available spell for the current skillchain.
-- RDM:
--   501+ MP: normal spell priority.
--   351-500 MP: Tier III or lower.
--   350 MP or less: no burst.
function Get_Burst_Spell(target)
	if nuke_mode == 'off' then
		return nil
	end

	if not target or not active_profile or not active_profile.burst_spells then
		return nil
	end

	local element = Get_SC_Element(target)
	if not element then
		return nil
	end

	local family = SC_FAMILY[element] or element
	local candidates = active_profile.burst_spells[family]

	if not candidates then
		return nil
	end

	local player = windower.ffxi.get_player()
	if not player or not player.vitals then
		return nil
	end

	local mp = player.vitals.mp
	local is_rdm = player.main_job == 'RDM'

	if is_rdm and mp <= RDM_NO_BURST_MP then
		return nil
	end

	local recasts = windower.ffxi.get_spell_recasts()

	-- Spell lists are ordered strongest first.
	for _, spell_name in ipairs(candidates) do
		local spell = res.spells:with('name', spell_name)

		if spell
			and recasts[spell.id] == 0
			and mp >= spell.mp_cost
		then
			if is_rdm and mp <= RDM_REDUCED_TIER_MP then
				local tier = Get_Burst_Spell_Tier(spell_name)

				if tier and tier <= 3 then
					return spell_name
				end
			else
				return spell_name
			end
		end
	end

	return nil
end

-- Cast the best available spell during a valid skillchain window.
function Try_Magic_Burst()
	if nuke_mode == 'off' then
		return false
	end

	if not active_profile or not active_profile.magic_burst then
		return false
	end

	local target = windower.ffxi.get_mob_by_target('t')
	if not target or target.hpp <= 0 then
		return false
	end

	if Is_Blacklisted(target.name) then
		return false
	end

	if not sc_active(target.id) or not sc_ready(target.id) then
		return false
	end

	if isCasting or isBusy > 0 or Is_Moving() then
		return false
	end

	local spell_name = Get_Burst_Spell(target)
	if not spell_name then
		return false
	end

	local spell = res.spells:with('name', spell_name)
	if not spell then
		return false
	end

	local player = windower.ffxi.get_player()
	if not player or not player.vitals then
		return false
	end

	local recasts = windower.ffxi.get_spell_recasts()

	-- Recheck affordability immediately before casting.
	if recasts[spell.id] ~= 0 or player.vitals.mp < spell.mp_cost then
		return false
	end

	-- Recheck the RDM MP cutoff in case MP changed during selection.
	if player.main_job == 'RDM'
		and player.vitals.mp <= RDM_NO_BURST_MP
	then
		return false
	end

	-- Recheck the low-MP tier restriction.
	if player.main_job == 'RDM'
		and player.vitals.mp <= RDM_REDUCED_TIER_MP
	then
		local tier = Get_Burst_Spell_Tier(spell_name)

		if not tier or tier > 3 then
			return false
		end
	end

	windower.send_command('input /ma "' .. spell_name .. '" <t>')
	isBusy = Action_Delay

	return true
end

-- FREE NUKE SETTINGS
-- Free nukes are only available to profiles with free_nuke = true.
local ROMAN = { '', ' II', ' III', ' IV', ' V', ' VI' }

local FAMILY_ELEMENT_ID = {
	Fire = 0,
	Blizzard = 1,
	Aero = 2,
	Stone = 3,
	Thunder = 4,
	Water = 5,
}

local STORM_NAMES = {
	[0] = 'Firestorm',
	[1] = 'Hailstorm',
	[2] = 'Windstorm',
	[3] = 'Sandstorm',
	[4] = 'Thunderstorm',
	[5] = 'Rainstorm',
	[6] = 'Aurorastorm',
	[7] = 'Voidstorm',
}

local NUKE_RANGE = 19
local WEATHER_RETRY = 20

local weather_last_try = {}
local nuke_unknown_warned = {}

-- Check if a spell is learned, available to the current job level,
-- and not on recast.
local function Spell_Ready(spell, player, recasts, known)
	if not spell or not recasts or recasts[spell.id] ~= 0 then
		return false
	end

	if known and not known[spell.id] then
		return false
	end

	local levels = spell.levels

	if levels then
		local allowed = false

		local main_req = levels[player.main_job_id]
		if main_req and (player.main_job_level or 0) >= main_req then
			allowed = true
		end

		local sub_req = levels[player.sub_job_id]
		if sub_req and (player.sub_job_level or 0) >= sub_req then
			allowed = true
		end

		if not allowed then
			return false
		end
	end

	return true
end

-- Valid monster target, in range, not blacklisted or a party member,
-- and unclaimed or claimed by us or our party.
local function Nukeable(target, player)
	if not target or not target.hpp or target.hpp <= 0 then
		return false
	end

	if target.valid_target == false or target.id == player.id then
		return false
	end

	if target.spawn_type and target.spawn_type ~= 16 then
		return false
	end

	if Is_Party_Member(target.id) or Is_Player_Pet(target) then
		return false
	end

	if Is_Blacklisted(target.name) then
		return false
	end

	local claim = target.claim_id

	if claim and claim ~= 0 and claim ~= player.id and not Is_Party_Member(claim) then
		return false
	end

	if not target.distance or math.sqrt(target.distance) > NUKE_RANGE then
		return false
	end

	return true
end

-- Find the spell family for the target's known elemental weakness.
local function Nuke_Family_For(target)
	local list = (active_profile and active_profile.nuke_weakness)
		or nuke_weakness
		or {}

	local padded = ' ' .. (string.lower(target.name or ''):gsub('[^%w]+', ' ')) .. ' '

	for _, row in ipairs(list) do
		local key = string.lower(row[1] or ''):gsub('[^%w]+', ' ')

		if key ~= '' and padded:find(' ' .. key .. ' ', 1, true) then
			return row[2]
		end
	end

	return (active_profile and active_profile.nuke_default) or nuke_default
end

-- MP to reserve so the family's top burst spell remains affordable.
local function Burst_Reserve_MP(family)
	local list = active_profile
		and active_profile.burst_spells
		and active_profile.burst_spells[family]

	local top = list and res.spells:with('name', list[1])

	return top and top.mp_cost or 0
end

-- True if current weather or our own storm matches the element.
function Weather_Matches(element_id)
	local info = windower.ffxi.get_info()
	local weather = info and info.weather and res.weather[info.weather]

	if weather and weather.element == element_id then
		return true
	end

	local storm = STORM_NAMES[element_id]

	return (storm and buffactive and buffactive[storm]) and true or false
end

-- Cast Storm II or Storm if weather doesn't match.
local function Try_Weather(element_id, player, recasts, known, mp_after)
	if Weather_Matches(element_id) then
		return false
	end

	local now = os.clock()

	if now - (weather_last_try[element_id] or -999) < WEATHER_RETRY then
		return false
	end

	local base = STORM_NAMES[element_id]
	if not base then
		return false
	end

	for _, name in ipairs({ base .. ' II', base }) do
		local spell = res.spells:with('name', name)

		if Spell_Ready(spell, player, recasts, known)
			and player.vitals.mp >= spell.mp_cost + mp_after
		then
			weather_last_try[element_id] = now

			windower.send_command('input /ma "' .. name .. '" <me>')
			isBusy = Action_Delay

			return true
		end
	end

	return false
end

-- Cast one free nuke or its matching weather spell.
function Try_Free_Nuke()
	-- This gate also ensures the off mode blocks free nuking.
	if nuke_mode ~= 'free' then
		return false
	end

	if not active_profile or not active_profile.free_nuke then
		return false
	end

	if isCasting or isBusy > 0 or Is_Moving() then
		return false
	end

	local player = windower.ffxi.get_player()

	if not player or not player.vitals or player.vitals.hp <= 0 then
		return false
	end

	local target = windower.ffxi.get_mob_by_target('t')

	if not Nukeable(target, player) then
		return false
	end

	-- A skillchain window belongs to the burst.
	if sc_active and sc_active(target.id) then
		return false
	end

	-- Don't start a new pull while targeting is paused.
	if Targeting_Paused and Targeting_Paused() and not combat_locked_target_id then
		return false
	end

	local family = Nuke_Family_For(target)
	local element_id = family and FAMILY_ELEMENT_ID[family]

	if not element_id then
		if not nuke_unknown_warned[target.name] then
			nuke_unknown_warned[target.name] = true

			windower.add_to_chat(
				207,
				"[Lazy] Free nuke: no weakness known for '" ..
				tostring(target.name) ..
				"'. Add it to nuke_weakness (or set nuke_default) in settings.lua."
			)
		end

		return false
	end

	local recasts = windower.ffxi.get_spell_recasts()
	local known = windower.ffxi.get_spells()
	local reserve = Burst_Reserve_MP(family)
	local max_tier = math.min(active_profile.free_nuke_max_tier or 4, 6)

	local chosen

	for tier = max_tier, 1, -1 do
		local name = family .. ROMAN[tier]
		local spell = res.spells:with('name', name)

		if Spell_Ready(spell, player, recasts, known)
			and player.vitals.mp >= spell.mp_cost + reserve
		then
			chosen = spell
			break
		end
	end

	if not chosen then
		return false
	end

	if active_profile.free_nuke_weather ~= false
		and Try_Weather(
			element_id,
			player,
			recasts,
			known,
			chosen.mp_cost + reserve
		)
	then
		return true
	end

	windower.send_command('input /ma "' .. chosen.en .. '" <t>')
	isBusy = Action_Delay

	return true
end

-- Command handler: //lazy burstmode, //lazy freenuke, //lazy nukeoff
function Set_Nuke_Mode(mode)
	if mode == 'off' then
		nuke_mode = 'off'

		windower.add_to_chat(
			167,
			'[Lazy] NUKES OFF. Automatic magic nuking disabled.'
		)

		return
	end

	if mode == 'free' then
		if not (active_profile and active_profile.free_nuke) then
			windower.add_to_chat(
				167,
				'[Lazy] Free nuke is not enabled for this job. Staying in burst mode.'
			)

			return
		end

		nuke_mode = 'free'

		windower.add_to_chat(
			2,
			'[Lazy] Nuke mode: FREE NUKE.'
		)

		return
	end

	nuke_mode = 'burst'

	if active_profile and active_profile.magic_burst then
		windower.add_to_chat(
			2,
			'[Lazy] Nuke mode: BURST ONLY.'
		)
	else
		windower.add_to_chat(
			167,
			'[Lazy] Burst mode selected; this job has no magic burst enabled.'
		)
	end
end

function Get_Nuke_Mode_Text()
	if nuke_mode == 'off' then
		return 'nukes off'
	end

	if not (active_profile and active_profile.magic_burst) then
		return nil
	end

	if nuke_mode == 'free' and active_profile.free_nuke then
		return 'free nuke'
	end

	return 'burst only'
end
