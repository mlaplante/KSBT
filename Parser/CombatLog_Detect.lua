------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Combat Log Detection (Skeleton)
-- Responsibility: listen to raw combat events and forward normalized data.
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

KSBT.Parser = KSBT.Parser or {}
KSBT.Parser.CombatLog = KSBT.Parser.CombatLog or {}
local CombatLog = KSBT.Parser.CombatLog
local Addon     = KSBT.Addon

function CombatLog:Enable()
    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(1, "Parser.CombatLog:Enable()")
    end

    -- Do not register events yet (skeleton only).
end

function CombatLog:Disable()
    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(1, "Parser.CombatLog:Disable()")
    end
end
