------------------------------------------------------------
-- MAGICBURST.LUA
--
-- Shared Magic Burst engine for:
-- BLM / GEO / SCH / NIN
--
-- Job profiles define which spells are available.
-- This file only handles:
--
--   * Determining the current skillchain element
--   * Finding the best available burst spell
--   * Checking burst conditions
--   * Casting the burst
--
-- Requires globals/functions from lazy.lua:
--
--   active_profile
--   current_job
--   isCasting
--   isBusy
--   Start_Engine
--   Action_Delay
--   Is_Moving()
--   Is_Blacklisted()
--   sc_active()
--   sc_ready()
--   sc_get_property()
--   res
--   windower
------------------------------------------------------------


------------------------------------------------------------
-- SKILLCHAIN ELEMENTS
------------------------------------------------------------

local SC_ELEMENTS = {

	--------------------------------------------------------
	-- LEVEL 4
	--------------------------------------------------------

	Radiance      = 'Light',
	Umbra         = 'Darkness',


	--------------------------------------------------------
	-- LEVEL 3
	--------------------------------------------------------

	Light         = 'Light',
	Darkness      = 'Darkness',

	Gravitation   = 'Earth',
	Fragmentation = 'Wind',
	Distortion    = 'Ice',
	Fusion        = 'Fire',


	--------------------------------------------------------
	-- LEVEL 2
	--------------------------------------------------------

	Compression   = 'Darkness',
	Liquefaction  = 'Fire',
	Induration    = 'Ice',
	Reverberation = 'Water',
	Transfixion   = 'Light',
	Scission      = 'Earth',
	Detonation    = 'Wind',
	Impaction     = 'Lightning',
}


------------------------------------------------------------
-- GET SKILLCHAIN ELEMENT
------------------------------------------------------------
--
-- Returns the element that should be used for the current
-- skillchain.
--
-- Normally this comes directly from the SC property.
--
-- Special job-specific choices belong in the JOB PROFILE,
-- not here.
------------------------------------------------------------

function Get_SC_Element(target)

	if not target then
		return nil
	end

	local property =
		sc_get_property(target.id)

	if not property then
		return nil
	end

	return SC_ELEMENTS[property]
end


------------------------------------------------------------
-- FIND BURST SPELL
------------------------------------------------------------
--
-- Looks at the active job's burst_spells table and returns
-- the strongest spell currently available.
--
-- Example:
--
--   SC element = Fire
--
--   BLM profile:
--      Fire VI
--      Fire V
--      Fire IV
--
-- If Fire VI is unavailable but Fire V is ready,
-- Fire V is returned.
------------------------------------------------------------

function Get_Burst_Spell(target)

	if not target then
		return nil
	end

	if not active_profile then
		return nil
	end

	if not active_profile.burst_spells then
		return nil
	end


	--------------------------------------------------------
	-- Determine SC element.
	--------------------------------------------------------

	local element =
		Get_SC_Element(target)

	if not element then
		return nil
	end


	--------------------------------------------------------
	-- Get spells for this element.
	--------------------------------------------------------

	local candidates =
		active_profile.burst_spells[element]

	if not candidates then
		return nil
	end


	--------------------------------------------------------
	-- Player / recasts.
	--------------------------------------------------------

	local player =
		windower.ffxi.get_player()

	if not player then
		return nil
	end

	local recasts =
		windower.ffxi.get_spell_recasts()


	--------------------------------------------------------
	-- Find strongest available spell.
	--------------------------------------------------------

	for _, spell_name in ipairs(candidates) do

		local spell =
			res.spells:with(
				'name',
				spell_name
			)

		if spell then

			local recast =
				recasts[spell.id]

			local mp =
				player.vitals.mp


			if recast == 0
				and mp >= spell.mp_cost then

				return spell_name
			end
		end
	end


	return nil
end


------------------------------------------------------------
-- ATTEMPT MAGIC BURST
------------------------------------------------------------

function Try_Magic_Burst()

	--------------------------------------------------------
	-- Job must have magic burst enabled.
	--------------------------------------------------------

	if not active_profile
		or not active_profile.magic_burst then

		return false
	end


	--------------------------------------------------------
	-- Target.
	--------------------------------------------------------

	local target =
		windower.ffxi.get_mob_by_target('t')

	if not target then
		return false
	end

	if target.hpp <= 0 then
		return false
	end


	--------------------------------------------------------
	-- Blacklist.
	--------------------------------------------------------

	if Is_Blacklisted(target.name) then
		return false
	end


	--------------------------------------------------------
	-- There must be an active skillchain.
	--------------------------------------------------------

	if not sc_active(target.id) then
		return false
	end


	--------------------------------------------------------
	-- Must be inside the burst window.
	--------------------------------------------------------

	if not sc_ready(target.id) then
		return false
	end


	--------------------------------------------------------
	-- Don't interrupt another action.
	--------------------------------------------------------

	if isCasting
		or isBusy > 0 then

		return false
	end


	--------------------------------------------------------
	-- Don't try to cast while moving.
	--------------------------------------------------------

	if Is_Moving() then
		return false
	end


	--------------------------------------------------------
	-- Find the strongest available spell.
	--------------------------------------------------------

	local spell_name =
		Get_Burst_Spell(target)

	if not spell_name then
		return false
	end


	--------------------------------------------------------
	-- Resolve spell.
	--------------------------------------------------------

	local spell =
		res.spells:with(
			'name',
			spell_name
		)

	if not spell then
		return false
	end


	--------------------------------------------------------
	-- Final MP / recast check.
	--------------------------------------------------------

	local player =
		windower.ffxi.get_player()

	if not player then
		return false
	end

	local recasts =
		windower.ffxi.get_spell_recasts()

	if recasts[spell.id] ~= 0 then
		return false
	end

	if player.vitals.mp < spell.mp_cost then
		return false
	end


	--------------------------------------------------------
	-- CAST
	--------------------------------------------------------

	windower.send_command(
		'input /ma "'..
		spell_name..
		'" <t>'
	)

	isBusy =
		Action_Delay

	return true
end