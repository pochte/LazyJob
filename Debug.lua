-- LAZY DEBUG
-- Centralized debug logging, packet tracing, and the /attack
-- safety gate. Debug output is OFF by default.
Debug = Debug or {}
Debug.enabled = Debug.enabled or false
Debug._log_handle = Debug._log_handle or nil
Debug._events_installed = Debug._events_installed or false
Debug._attack_wrapper_installed = Debug._attack_wrapper_installed or false
Debug._unload_installed = Debug._unload_installed or false
Debug._last_target_id = Debug._last_target_id or nil
local DEBUG_FILE = windower.addon_path .. 'TargetLogic_Debug.txt'
function Debug.Open_Log()
    if Debug._log_handle then
        return true
    end
    local ok, file = pcall(io.open, DEBUG_FILE, 'a')
    if not ok or not file then
        windower.add_to_chat(167, '[Lazy DEBUG] ERROR: Could not open TargetLogic_Debug.txt')
        return false
    end
    Debug._log_handle = file
    pcall(function()
        file:write('\n')
        file:write('============================================================\n')
        file:write('TARGETLOGIC DEBUG SESSION | ' .. os.date('%Y-%m-%d %H:%M:%S') .. '\n')
        file:write('============================================================\n')
        file:flush()
    end)
    return true
end
function Debug.Close_Log()
    if not Debug._log_handle then
        return
    end
    pcall(function()
        Debug._log_handle:write('TARGETLOGIC DEBUG SESSION CLOSED | ' .. os.date('%Y-%m-%d %H:%M:%S') .. '\n')
        Debug._log_handle:flush()
        Debug._log_handle:close()
    end)
    Debug._log_handle = nil
end
function Debug.Set_Enabled(enabled)
    Debug.enabled = enabled and true or false
    if Debug.enabled then
        Debug.Open_Log()
    else
        Debug.Close_Log()
    end
end
function Debug.Log(message)
    if not Debug.enabled then
        return
    end
    message = tostring(message or '')
    if not Debug._log_handle then
        Debug.Open_Log()
    end
    if Debug._log_handle then
        local ok = pcall(function()
            Debug._log_handle:write('[' .. os.date('%Y-%m-%d %H:%M:%S') .. '] ' .. message .. '\n')
            Debug._log_handle:flush()
        end)
        if not ok then
            Debug.Close_Log()
        end
    end
    windower.add_to_chat(207, '[Lazy DEBUG] ' .. message)
end
function Debug.Target(prefix, mob)
    if not Debug.enabled then
        return
    end
    if mob then
        local distance = mob.distance and math.sqrt(mob.distance)
        Debug.Log(string.format('%s | name=%s id=%s index=%s hpp=%s claim=%s dist=%s', prefix, tostring(mob.name), tostring(mob.id), tostring(mob.index), tostring(mob.hpp), tostring(mob.claim_id), distance and string.format('%.2f', distance) or 'nil'))
    else
        Debug.Log(prefix .. ' | TARGET=nil')
    end
end
function Debug.State(prefix)
    if not Debug.enabled then
        return
    end
    local target = windower.ffxi.get_mob_by_target('t')
    Debug.Log(string.format('%s | managed=%s locked=%s pending=%s engage_sent=%s combat_started=%s', prefix, tostring(managed_target_id), tostring(combat_locked_target_id), tostring(pending_target_id), tostring(engage_sent_target_id), tostring(combat_started)))
    Debug.Target('<t>', target)
end
function Debug.Target_Changed(target)
    local target_id = target and target.id
    if not Debug.enabled or target_id == Debug._last_target_id then
        return
    end
    Debug.Target('!!! <t> CHANGED !!!', target)
    Debug.State('TARGET CHANGE OBSERVED')
    Debug._last_target_id = target_id
end
if not Debug._events_installed then
    windower.register_event('outgoing chunk', function(id, data)
        if not Debug.enabled or id ~= 0x01A then
            return
        end
        local ok, action = pcall(packets.parse, 'outgoing', data)
        if not ok or not action then
            Debug.Log('>>> OUTGOING 0x01A PARSE FAILED <<<')
            return
        end
        local player = windower.ffxi.get_player()
        local target_id = action.Target
        local target = target_id and windower.ffxi.get_mob_by_id(target_id)
        Debug.Log(string.format('>>> OUTGOING 0x01A <<< category=%s target=%s id=%s index=%s param=%s status=%s managed=%s locked=%s pending=%s engage_sent=%s combat_started=%s', tostring(action.Category), tostring(target and target.name or 'UNKNOWN'), tostring(target_id), tostring(action['Target Index']), tostring(action.Param), tostring(player and player.status), tostring(managed_target_id), tostring(combat_locked_target_id), tostring(pending_target_id), tostring(engage_sent_target_id), tostring(combat_started)))
        if target then
            Debug.Target('OUTGOING PACKET TARGET', target)
        end
    end)
    Debug._events_installed = true
end
if not Debug._attack_wrapper_installed then
    Debug._original_send_command = windower.send_command
    windower.send_command = function(command)
        local cmd = tostring(command or '')
        local lower_cmd = string.lower(cmd)
        if string.find(lower_cmd, '/attack on', 1, true) then
            local player = windower.ffxi.get_player()
            local target = windower.ffxi.get_mob_by_target('t')
            if Debug.enabled then
                Debug.Log(string.format('[Lazy ATTACK TRACE] /attack on | target=%s id=%s status=%s managed=%s locked=%s engage_sent=%s', tostring(target and target.name), tostring(target and target.id), tostring(player and player.status), tostring(managed_target_id), tostring(combat_locked_target_id), tostring(engage_sent_target_id)))
                Debug.Log('[Lazy ATTACK TRACE] CALL STACK:\n' .. debug.traceback('ATTACK ON REQUEST', 2))
            end
            if not combat_locked_target_id then
                if Debug.enabled then Debug.Log('[Lazy ATTACK TRACE] BLOCKED /attack on -- NO COMBAT LOCK') end
                return
            end
            if target and target.id and target.id ~= combat_locked_target_id then
                if Debug.enabled then Debug.Log('[Lazy ATTACK TRACE] BLOCKED /attack on -- WRONG TARGET') end
                return
            end
            if player and player.status == 1 then
                if Debug.enabled then Debug.Log('[Lazy ATTACK TRACE] BLOCKED /attack on -- ALREADY ENGAGED') end
                return
            end
        end
        return Debug._original_send_command(command)
    end
    Debug._attack_wrapper_installed = true
end
if not Debug._unload_installed then
    windower.register_event('unload', function()
        Debug.Close_Log()
    end)
    Debug._unload_installed = true
end