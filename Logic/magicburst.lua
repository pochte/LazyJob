-- MAGICBURST.LUA
-- Shared magic burst and free nuke logic.
-- ELEMENTAL ALIGNMENTS
-- Which elements can burst each skillchain (bg-wiki, Magic Burst), in the
-- order they are tried when the target has no weakness that fits. Light and
-- Radiance prefer Wind, Darkness and Umbra prefer Dark (Comet, Impact).
-- Override one in settings.lua: burst_elements = { Light = { 'Fire' } }
local SC_BURST_ELEMENTS = {
	Transfixion   = { 'Light' },
	Compression   = { 'Dark' },
	Liquefaction  = { 'Fire' },
	Scission      = { 'Earth' },
	Reverberation = { 'Water' },
	Detonation    = { 'Wind' },
	Induration    = { 'Ice' },
	Impaction     = { 'Lightning' },
	Fusion        = { 'Fire', 'Light' },
	Fragmentation = { 'Wind', 'Lightning' },
	Gravitation   = { 'Earth', 'Dark' },
	Distortion    = { 'Ice', 'Water' },
	Light         = { 'Wind', 'Lightning', 'Fire', 'Light' },
	Radiance      = { 'Wind', 'Lightning', 'Fire', 'Light' },
	Darkness      = { 'Dark', 'Ice', 'Water', 'Earth' },
	Umbra         = { 'Dark', 'Ice', 'Water', 'Earth' },
}
-- Element -> the spell family name profiles use in burst_spells.
local ELEMENT_FAMILY = {
	Fire = 'Fire', Ice = 'Blizzard', Wind = 'Aero', Earth = 'Stone',
	Lightning = 'Thunder', Water = 'Water', Light = 'Light', Dark = 'Darkness',
}
-- MP-limited burst settings.
-- These jobs hold back MP for curing/buffs/etc:
--   above REDUCED MP : normal spell priority.
--   NO_BURST..REDUCED: Tier III or lower only.
--   NO_BURST or less : no burst.
-- BLM is deliberately NOT listed: it nukes until empty and the rest
-- monitor handles recovery.
local MP_LIMITED_JOBS = { RDM = true, GEO = true, SCH = true }
local BURST_NO_BURST_MP = 350
local BURST_REDUCED_TIER_MP = 500
-- NINJUTSU TOOLS
-- Spell prefix -> { specific tool, its toolbag }. The universal tool
-- (Shihei) and its toolbag also satisfy any ninjutsu.
-- Set check_tools = false in a profile to skip the check.
local NIN_TOOLS = {
	Katon  = { 'Uchitake',     'Toolbag (Uchi)'  },
	Hyoton = { 'Tsurara',      'Toolbag (Tsura)' },
	Huton  = { 'Kawahori-ogi', 'Toolbag (Kawa)'  },
	Doton  = { 'Makibishi',    'Toolbag (Maki)'  },
	Raiton = { 'Hiraishin',    'Toolbag (Hira)'  },
	Suiton = { 'Mizu-deppo',   'Toolbag (Mizu)'  },
}
local NIN_UNIVERSAL = { 'Shihei', 'Toolbag (Shihe)' }
-- Nuke mode:
--   burst = burst spells only
--   free  = free nukes between skillchains, if enabled for the job
--   off   = disable automatic nuking
nuke_mode = nuke_mode or 'burst'
-- When to burst (burst_when in settings.lua):
--   final = only at the END of a chain: a skillchain that can no longer be
--           continued (Radiance / Umbra, or past the last step). Bursting
--           mid-chain costs the chain its timing. This is the default.
--   any   = burst any open skillchain window
burst_when = burst_when or 'final'
-- An open chain counts as ended once nobody has continued it for this many
-- seconds (capped at 40% of the window). A closed chain needs no waiting.
burst_quiet = burst_quiet or 2
-- Do not start a burst with less than this much window left.
burst_min_left = burst_min_left or 0.8
-- Gap between burst casts, so fast casts can burst two or three times in
-- one window without double-sending a command.
burst_gap = burst_gap or 0.7
local burst_gap_until = 0
-- The skillchain property to burst right now, or nil.
--   final: a closed chain right away; an open chain once nobody has
--          continued it for burst_quiet seconds (that is the end of it).
--   any:   any open window.
function Burst_Window_Property(target)
	if not target or not sc_burst_window then
		return nil
	end
	local property, final, left, since_go, length = sc_burst_window(target.id)
	if not property then
		return nil
	end
	if left < burst_min_left then
		return nil
	end
	if burst_when == 'any' or final then
		return property
	end
	if since_go >= math.min(burst_quiet, length * 0.4) then
		return property
	end
	return nil
end
function Burst_Window_Open(target)
	return Burst_Window_Property(target) ~= nil
end
-- First element that bursts the target's current skillchain, or nil.
function Get_SC_Element(target)
	local property = Burst_Window_Property(target)
	local elements = property and SC_BURST_ELEMENTS[property]
	return elements and elements[1] or nil
end
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
-- Resolve an item name to its id once and cache it.
local item_id_cache = {}
local function Item_Id(name)
	if item_id_cache[name] == nil then
		local item = res.items:with('en', name)
		item_id_cache[name] = item and item.id or false
	end
	return item_id_cache[name]
end
-- True if the player carries the tool (or universal tool, or a toolbag
-- for either) needed for this ninjutsu. Non-ninjutsu spells always pass.
local function Has_Ninja_Tools(spell_name)
	local prefix = spell_name:match('^(%a+):')
	local tools = prefix and NIN_TOOLS[prefix]
	if not tools then
		return true
	end
	local wanted = {}
	for _, name in ipairs({
		tools[1],
		tools[2],
		NIN_UNIVERSAL[1],
		NIN_UNIVERSAL[2],
	}) do
		local id = Item_Id(name)
		if id then
			wanted[id] = true
		end
	end
	local inventory = windower.ffxi.get_items(0)
	-- Can't read the bag: don't block the cast over it.
	if not inventory then
		return true
	end
	for slot = 1, inventory.max or 80 do
		local entry = inventory[slot]
		if entry
			and entry.id
			and wanted[entry.id]
			and (entry.count or 0) > 0
		then
			return true
		end
	end
	return false
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
-- RDM / GEO / SCH (see MP_LIMITED_JOBS):
--   501+ MP: normal spell priority.
--   351-500 MP: Tier III or lower.
--   350 MP or less: no burst.
-- Spells must be learned, available at the current level, off recast,
-- affordable, and (ninjutsu) have the tools to cast.
-- The spell families to try, in order, for this skillchain on this target:
-- the target's weakness first when the skillchain can be burst with it,
-- then the alignment order above.
local function Burst_Families(property, target)
	local elements = (burst_elements and burst_elements[property])
		or SC_BURST_ELEMENTS[property]
	if not elements then
		return {}
	end
	local order, seen = {}, {}
	local weak = Nuke_Family_For and Nuke_Family_For(target)
	if weak then
		for _, element in ipairs(elements) do
			if ELEMENT_FAMILY[element] == weak and not seen[weak] then
				seen[weak] = true
				order[#order + 1] = weak
			end
		end
	end
	for _, element in ipairs(elements) do
		local family = ELEMENT_FAMILY[element]
		if family and not seen[family] then
			seen[family] = true
			order[#order + 1] = family
		end
	end
	return order
end
function Get_Burst_Spell(target)
	if nuke_mode == 'off' then
		return nil
	end
	if not target or not active_profile or not active_profile.burst_spells then
		return nil
	end
	local property = Burst_Window_Property(target)
	if not property then
		return nil
	end
	local player = windower.ffxi.get_player()
	if not player or not player.vitals then
		return nil
	end
	local mp = player.vitals.mp
	local mp_limited = MP_LIMITED_JOBS[player.main_job]
	if mp_limited and mp <= BURST_NO_BURST_MP then
		return nil
	end
	local recasts = windower.ffxi.get_spell_recasts()
	local known = windower.ffxi.get_spells()
	local check_tools = active_profile.check_tools ~= false
	for _, family in ipairs(Burst_Families(property, target)) do
		local candidates = active_profile.burst_spells[family]
		-- Spell lists are ordered strongest first.
		for _, spell_name in ipairs(candidates or {}) do
			local spell = res.spells:with('name', spell_name)
			if spell
				and Spell_Ready(spell, player, recasts, known)
				and mp >= spell.mp_cost
				and (not check_tools or Has_Ninja_Tools(spell_name))
			then
				if mp_limited and mp <= BURST_REDUCED_TIER_MP then
					local tier = Get_Burst_Spell_Tier(spell_name)
					if tier and tier <= 3 then
						return spell_name
					end
				else
					return spell_name
				end
			end
		end
	end
	return nil
end
-- True while this job's own weaponskill chain still wants the open window:
-- an ordered chain with a next step it can afford, or partychain with a
-- weaponskill that continues the skillchain. The burst waits for it.
function Chain_Wants_Window(target)
	local player = windower.ffxi.get_player()
	if not target or not player or not player.vitals or player.status ~= 1 then
		return false
	end
	local tp = player.vitals.tp or 0
	local chain = Get_WS_Chain and Get_WS_Chain()
	if chain then
		local step = sc_get_step and sc_get_step(target.id)
		local next_step = step and chain[step + 1]
		return (next_step and tp >= next_step[2]) and true or false
	end
	if ws_mode == 'party'
		and active_profile
		and active_profile.use_weaponskills
		and sc_rank_ws
		and tp >= 1000
	then
		local ranked = sc_rank_ws(target.id, Get_Party_Prefer and Get_Party_Prefer())
		return ranked[1] ~= nil
	end
	return false
end
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
	if not Burst_Window_Open(target) then
		return false
	end
	-- A window is short, so action delay does not apply, but never overlap
	-- a cast and leave burst_gap between casts.
	if isCasting or Is_Moving() or os.clock() < burst_gap_until then
		return false
	end
	-- This job's own chain keeps the window until it has finished.
	if Chain_Wants_Window(target) then
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
	-- Recheck the MP cutoff in case MP changed during selection.
	if MP_LIMITED_JOBS[player.main_job]
		and player.vitals.mp <= BURST_NO_BURST_MP
	then
		return false
	end
	-- Recheck the low-MP tier restriction.
	if MP_LIMITED_JOBS[player.main_job]
		and player.vitals.mp <= BURST_REDUCED_TIER_MP
	then
		local tier = Get_Burst_Spell_Tier(spell_name)
		if not tier or tier > 3 then
			return false
		end
	end
	windower.send_command('input /ma "' .. spell_name .. '" <t>')
	burst_gap_until = os.clock() + burst_gap
	-- Hold the other monitors off for a moment; the next burst does not
	-- wait for it (Burst_Monitor below).
	isBusy = 1
	return true
end
-- Fast path. Combat only runs once a second, and every cast used to cost an
-- Action_Delay, so one burst per window. With fast cast a window can take
-- two or three, so while one is open this checks four times a second.
function Burst_Monitor()
	while Start_Engine do
		local delay = 1
		if active_profile and active_profile.magic_burst and nuke_mode ~= 'off' then
			delay = 0.5
			local target = windower.ffxi.get_mob_by_target('t')
			if target and Burst_Window_Open(target) then
				delay = 0.25
				pcall(Try_Magic_Burst)
			end
		end
		coroutine.sleep(delay)
	end
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
function Nuke_Family_For(target)
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
	-- A window we could burst belongs to the burst.
	if Burst_Window_Open(target) then
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