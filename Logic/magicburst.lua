-- MAGICBURST.LUA
-- Shared magic burst logic for BLM, GEO, SCH, and NIN.
-- SKILLCHAIN ELEMENTS
local SC_ELEMENTS = {
	-- Level 4
	Radiance      = 'Light',
	Umbra         = 'Darkness',
	-- Level 3
	Light         = 'Light',
	Darkness      = 'Darkness',
	Gravitation   = 'Earth',
	Fragmentation = 'Wind',
	Distortion    = 'Ice',
	Fusion        = 'Fire',
	-- Level 2
	Compression   = 'Darkness',
	Liquefaction  = 'Fire',
	Induration    = 'Ice',
	Reverberation = 'Water',
	Transfixion   = 'Light',
	Scission      = 'Earth',
	Detonation    = 'Wind',
	Impaction     = 'Lightning',
}
-- Return the element for the target's current skillchain.
function Get_SC_Element(target)
	if not target then
		return nil
	end
	local property = sc_get_property(target.id)
	if not property then
		return nil
	end
	return SC_ELEMENTS[property]
end
-- Return the strongest available spell for the skillchain element.
-- Spell priority is defined by the active job profile.
function Get_Burst_Spell(target)
	if not target or not active_profile or not active_profile.burst_spells then
		return nil
	end
	local element = Get_SC_Element(target)
	if not element then
		return nil
	end
	local candidates = active_profile.burst_spells[element]
	if not candidates then
		return nil
	end
	local player = windower.ffxi.get_player()
	if not player then
		return nil
	end
	local recasts = windower.ffxi.get_spell_recasts()
	for _, spell_name in ipairs(candidates) do
		local spell = res.spells:with('name', spell_name)
		if spell
			and recasts[spell.id] == 0
			and player.vitals.mp >= spell.mp_cost
		then
			return spell_name
		end
	end
	return nil
end
-- Cast the best available spell during a valid skillchain window.
function Try_Magic_Burst()
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
	if not player then
		return false
	end
	local recasts = windower.ffxi.get_spell_recasts()
	if recasts[spell.id] ~= 0 or player.vitals.mp < spell.mp_cost then
		return false
	end
	windower.send_command('input /ma "' .. spell_name .. '" <t>')
	isBusy = Action_Delay
	return true
end