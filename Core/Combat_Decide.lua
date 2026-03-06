------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Combat Decision Layer (Skeleton)
-- Responsibility: accept normalized combat events and decide emission.
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

KSBT.Core = KSBT.Core or {}
KSBT.Core.Combat = KSBT.Core.Combat or {}
local Combat = KSBT.Core.Combat
local Addon  = KSBT.Addon

function Combat:Enable()
    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(1, "Combat:Enable()")
    end
end

function Combat:Disable()
    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(1, "Combat:Disable()")
    end
end

-- Contract for Parser -> Core handoff (not used yet)
function Combat:OnCombatEvent(event)
    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(3, "Combat:OnCombatEvent() (stub)")
    end
end
