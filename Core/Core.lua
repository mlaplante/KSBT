------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Core Orchestrator (Skeleton)
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

KSBT.Core = KSBT.Core or {}
local Core  = KSBT.Core
local Addon = KSBT.Addon

Core._initialized = Core._initialized or false
Core._enabled     = Core._enabled or false

------------------------------------------------------------------------
-- Shared number formatter: converts amounts to display strings.
-- Reads profile.general.numberFormat for style and decimal config.
------------------------------------------------------------------------
function KSBT.FormatNumber(amount)
    local rounded = math.floor(amount + 0.5)
    local db = KSBT.db and KSBT.db.profile
    local conf = db and db.general and db.general.numberFormat
    if not conf then return tostring(rounded) end

    local style = conf.style or "Full"
    if style == "Full" then
        return tostring(rounded)
    end

    local decimals = tonumber(conf.decimals) or 1

    if style == "Short (no decimal)" then
        if rounded >= 1000000 then
            return tostring(math.floor(rounded / 1000000 + 0.5)) .. "m"
        elseif rounded >= 1000 then
            return tostring(math.floor(rounded / 1000 + 0.5)) .. "k"
        end
        return tostring(rounded)
    end

    -- "Short" style with configurable decimals
    if rounded >= 1000000 then
        local val = rounded / 1000000
        return string.format("%." .. decimals .. "f", val) .. "m"
    elseif rounded >= 1000 then
        local val = rounded / 1000
        return string.format("%." .. decimals .. "f", val) .. "k"
    end
    return tostring(rounded)
end


function Core:IsMasterEnabled()
    return KSBT.db
       and KSBT.db.profile
       and KSBT.db.profile.general
       and KSBT.db.profile.general.enabled == true
end

function Core:IsCombatOnlyEnabled()
    return KSBT.db
       and KSBT.db.profile
       and KSBT.db.profile.general
       and KSBT.db.profile.general.combatOnly == true
end

function Core:ShouldEmitNow(meta)
    if not self:IsMasterEnabled() then return false end
    if self:IsCombatOnlyEnabled() and not UnitAffectingCombat("player") then
        -- Allow combat events through even if UnitAffectingCombat hasn't
        -- caught up yet.  The first hit that starts combat arrives before
        -- PLAYER_REGEN_DISABLED, so the API still returns false.  Probe
        -- events are inherently combat actions — let them pass.
        if not (meta and meta.probe) then
            return false
        end
    end
    return true
end

-- Attempt to suppress Blizzard floating combat text via CVars.
-- NOTE: Blizzard may lock/ignore these on some client builds.
function Core:ApplyBlizzardFCTCVars()
    if not KSBT.db or not KSBT.db.profile or not KSBT.db.profile.general then return end

    local g = KSBT.db.profile.general

    -- Only apply suppression when KSBT is enabled (your requested UX).
    if not g.enabled then return end

    local function trySet(name, value)
        if type(SetCVar) ~= "function" or type(GetCVar) ~= "function" then
            return
        end

        -- If CVar doesn't exist on this client build, skip silently.
        local before = GetCVar(name)
        if before == nil then return end

        local ok = pcall(SetCVar, name, value)
        if not ok then
            local after = GetCVar(name)
            if Addon and Addon.Print then
                Addon:Print(("Failed to set %s=%s (current: %s). Blizzard may be locking this CVar."):format(
                    name, tostring(value), tostring(after)
                ))
            end
        end
    end

    -- These are the historical CVars. If Blizzard changes them again, we'll adapt.
    if g.suppressBlizzardDamage then
        trySet("floatingCombatTextCombatDamage", "0")
    else
        trySet("floatingCombatTextCombatDamage", "1")
    end

    if g.suppressBlizzardHealing then
        trySet("floatingCombatTextCombatHealing", "0")
    else
        trySet("floatingCombatTextCombatHealing", "1")
    end
end

function Core:Init()
    if self._initialized then return end
    self._initialized = true

    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(1, "Core:Init()")
    end

    -- Incoming probe/replay harness init (UI/UX validation only).
    if self.IncomingProbe and self.IncomingProbe.Init then
        self.IncomingProbe:Init()
    end

    -- Outgoing probe/replay harness init.
    if self.OutgoingProbe and self.OutgoingProbe.Init then
        self.OutgoingProbe:Init()
    end
end

function Core:Enable()
    if self._enabled then return end
    self:Init()
    self._enabled = true

    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(1, "Core:Enable()")
    end

    -- Apply Blizzard suppression knobs (best-effort).
    self:ApplyBlizzardFCTCVars()

    if self.Display and self.Display.Enable then self.Display:Enable() end
    if self.Cooldowns and self.Cooldowns.Enable then self.Cooldowns:Enable() end
    if self.Combat and self.Combat.Enable then self.Combat:Enable() end
end

function Core:Disable()
    if not self._enabled then return end
    self._enabled = false

    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(1, "Core:Disable()")
    end

    if self.Combat and self.Combat.Disable then self.Combat:Disable() end
    if self.Cooldowns and self.Cooldowns.Disable then self.Cooldowns:Disable() end
    if self.Display and self.Display.Disable then self.Display:Disable() end
end
