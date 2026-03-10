------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Low Health Sound Monitor
-- Plays a configured sound when the player's health drops below
-- the configured threshold. Fires once per combat encounter.
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

KSBT.Core = KSBT.Core or {}
KSBT.Core.LowHealth = KSBT.Core.LowHealth or {}
local LowHealth = KSBT.Core.LowHealth
local Addon     = KSBT.Addon

LowHealth._enabled  = LowHealth._enabled  or false
LowHealth._fired    = LowHealth._fired    or false   -- true once sound played this combat

local function Debug(level, ...)
    if Addon and Addon.DebugPrint then Addon:DebugPrint(level, ...) end
end

local function CheckHealth()
    local db = KSBT.db and KSBT.db.profile
    if not db or not db.media then return end

    local soundName = db.media.sounds and db.media.sounds.lowHealth
    if not soundName or soundName == "None" or soundName == "" then return end

    -- Only fire once per combat encounter
    if LowHealth._fired then return end

    local threshold = tonumber(
        db.media.sounds and db.media.sounds.lowHealthThreshold
    ) or 20

    -- 12.0.1+: UnitHealth/UnitHealthMax return secret (tainted) numbers that
    -- addons cannot read or compare. UnitHealthPercent is the Blizzard-sanctioned
    -- replacement that returns a plain, non-tainted percentage.
    if not UnitHealthPercent then
        Debug(1, "LowHealth: UnitHealthPercent unavailable, feature disabled")
        return
    end

    local pct = UnitHealthPercent("player")
    if pct == nil or pct > threshold then return end

    LowHealth._fired = true
    Debug(1, ("LowHealth: %.0f%% <= %d%% threshold, playing sound"):format(pct, threshold))

    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    local soundPath = LSM and LSM:Fetch("sound", soundName)
    if soundPath then
        PlaySoundFile(soundPath, "SFX")
    end
end

local function OnCombatEnd()
    -- Reset so the sound can fire again next combat
    LowHealth._fired = false
end

-- Defer RegisterEvent via C_Timer.After(0) to avoid taint.
do
    local f = CreateFrame("Frame")
    LowHealth._frame = f
    f:SetScript("OnEvent", function(_, event, unit)
        if not LowHealth._enabled then return end
        if event == "UNIT_HEALTH" and unit == "player" then
            CheckHealth()
        elseif event == "PLAYER_REGEN_ENABLED" then
            OnCombatEnd()
        end
    end)
    C_Timer.After(0, function()
        f:RegisterEvent("UNIT_HEALTH")
        f:RegisterEvent("PLAYER_REGEN_ENABLED")
    end)
end

function LowHealth:Enable()
    if self._enabled then return end
    self._enabled = true
    self._fired   = false
    Debug(1, "LowHealth:Enable()")
end

function LowHealth:Disable()
    if not self._enabled then return end
    self._enabled = false
    Debug(1, "LowHealth:Disable()")
end
