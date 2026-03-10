------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Cooldowns Detection
-- Listens to SPELL_UPDATE_COOLDOWN and tracks which tracked spells
-- transition from on-cooldown to off-cooldown, then fires the decide layer.
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

KSBT.Parser = KSBT.Parser or {}
KSBT.Parser.Cooldowns = KSBT.Parser.Cooldowns or {}
local Cooldowns = KSBT.Parser.Cooldowns
local Addon     = KSBT.Addon

-- Track spells currently on real cooldown (spellId -> true)
Cooldowns._onCooldown = Cooldowns._onCooldown or {}
Cooldowns._enabled    = Cooldowns._enabled or false
Cooldowns._frame      = Cooldowns._frame or nil

local function Debug(level, ...)
    if Addon and Addon.DebugPrint then Addon:DebugPrint(level, ...) end
end

-- Returns true if the spell has a real cooldown remaining (ignores GCD, < 1.6s).
-- Uses C_Spell.GetSpellCooldown (Midnight+) with fallback to legacy GetSpellCooldown.
local function IsOnCooldown(spellId)
    local start, duration
    if C_Spell and C_Spell.GetSpellCooldown then
        local info = C_Spell.GetSpellCooldown(spellId)
        if info then
            start    = info.startTime
            duration = info.duration
        end
    else
        start, duration = GetSpellCooldown(spellId)  -- legacy clients
    end
    if not start or not duration then return false end
    -- In restricted content, cooldown values may be secret numbers.
    if issecretvalue and (issecretvalue(start) or issecretvalue(duration)) then
        return true  -- assume on cooldown; safe default avoids false "ready" fires
    end
    return (start + duration - GetTime()) > 1.6
end

local function CheckAllTracked()
    local db = KSBT.db and KSBT.db.profile
    if not db or not db.cooldowns or not db.cooldowns.enabled then return end
    local tracked = db.cooldowns.tracked
    if not tracked then return end

    for spellId, _ in pairs(tracked) do
        local id = tonumber(spellId)
        if id then
            local nowOnCD = IsOnCooldown(id)
            if Cooldowns._onCooldown[id] and not nowOnCD then
                -- Transitioned: was on cooldown, now ready
                local decide = KSBT.Core and KSBT.Core.Cooldowns
                if decide and decide.OnCooldownReady then
                    decide:OnCooldownReady({ spellId = id })
                end
            end
            -- Store state: true if on cooldown, nil if not (keeps table sparse)
            Cooldowns._onCooldown[id] = nowOnCD or nil
        end
    end
end

-- Seed initial cooldown states to avoid false-fires on first SPELL_UPDATE_COOLDOWN
local function SeedCooldownStates()
    local db = KSBT.db and KSBT.db.profile
    if not db or not db.cooldowns or not db.cooldowns.tracked then return end
    for spellId, _ in pairs(db.cooldowns.tracked) do
        local id = tonumber(spellId)
        if id then
            Cooldowns._onCooldown[id] = IsOnCooldown(id) or nil
        end
    end
end

-- pcall + retry for RegisterEvent to handle Midnight protected-call phases.
local _cdRegistered = false
local function TryRegisterCooldowns()
    if _cdRegistered then return end
    local ok = pcall(function()
        Cooldowns._frame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    end)
    if ok then
        _cdRegistered = true
    else
        C_Timer.After(0.5, TryRegisterCooldowns)
    end
end

do
    local f = CreateFrame("Frame")
    Cooldowns._frame = f
    f:SetScript("OnEvent", function()
        if Cooldowns._enabled then
            CheckAllTracked()
        end
    end)
    C_Timer.After(2, TryRegisterCooldowns)
end

function Cooldowns:Enable()
    if self._enabled then return end
    self._enabled = true
    Debug(1, "Parser.Cooldowns:Enable()")
    SeedCooldownStates()
end

function Cooldowns:Disable()
    if not self._enabled then return end
    self._enabled = false
    Debug(1, "Parser.Cooldowns:Disable()")
    wipe(self._onCooldown)
end
