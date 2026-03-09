local ADDON_NAME, KSBT = ...

------------------------------------------------------------------------
-- WoW Midnight: COMBAT_LOG_EVENT_UNFILTERED and COMBAT_LOG_EVENT are
-- both permanently protected for addon code (ADDON_ACTION_FORBIDDEN).
-- We use UNIT_COMBAT + UNIT_SPELLCAST_SUCCEEDED instead.
--
-- Known limitations vs CLEU:
--   • Damage on "target" shows ALL hits (any source), not just the player's.
--     Acceptable for solo / follower content; minor false-positives in groups.
--   • Heals require a recent player cast (500ms window) for attribution.
--   • No overheal data (UNIT_COMBAT doesn't provide it).
------------------------------------------------------------------------

KSBT.Parser = KSBT.Parser or {}
KSBT.Parser.Outgoing = KSBT.Parser.Outgoing or {}
local Outgoing = KSBT.Parser.Outgoing

local function DebugPrint(msg)
    local db = KSBT.db and KSBT.db.profile
    local lvl = db and db.diagnostics and db.diagnostics.debugLevel or 0
    if lvl >= 1 then
        print("|cff00ff00KSBT-Outgoing|r " .. tostring(msg))
    end
end

local function DB()
    return KSBT.db and KSBT.db.profile
end

local function Emit(evt)
    local probe = KSBT.Core and KSBT.Core.OutgoingProbe
    if probe and probe.OnOutgoingDetected then
        probe:OnOutgoingDetected(evt)
    end
end

local function SpellNameForId(spellId)
    if not spellId then return nil end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellId)
        return info and info.name
    end
    if GetSpellInfo then
        return (GetSpellInfo(spellId))  -- legacy; returns name as first value
    end
end

-- Track the player's most recent spell cast for heal/damage attribution.
local _lastCast  = nil   -- {spellId, spellName, time}
local CAST_WINDOW = 0.5  -- seconds

local function GetLastCast()
    if not _lastCast then return nil end
    if (GetTime() - _lastCast.time) > CAST_WINDOW then return nil end
    return _lastCast
end

------------------------------------------------------------------------
-- Frame + event wiring
-- Register at file-load time (safest; avoids any OnEnable context issues).
------------------------------------------------------------------------
local f = CreateFrame("Frame")
Outgoing._frame   = f
Outgoing._enabled = false

-- UNIT_COMBAT and UNIT_SPELLCAST_SUCCEEDED are not protected events.
f:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
f:RegisterUnitEvent("UNIT_COMBAT", "player")
f:RegisterUnitEvent("UNIT_COMBAT", "target")
f:RegisterUnitEvent("UNIT_COMBAT", "party1")
f:RegisterUnitEvent("UNIT_COMBAT", "party2")
f:RegisterUnitEvent("UNIT_COMBAT", "party3")
f:RegisterUnitEvent("UNIT_COMBAT", "party4")

f:SetScript("OnEvent", function(self, event, ...)
    if not Outgoing._enabled then return end

    -- Track player's last spell cast for attribution.
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellId = ...
        if unit ~= "player" then return end
        _lastCast = { spellId = spellId, spellName = SpellNameForId(spellId), time = GetTime() }
        return
    end

    if event ~= "UNIT_COMBAT" then return end
    local unit, action, flagText, amount, schoolMask = ...

    local db = DB()
    if not db or not db.outgoing then return end

    local isCrit = (flagText == "CRITICAL")

    -- Outgoing damage: any hit landing on the current target.
    if action == "WOUND" and unit == "target" then
        local conf = db.outgoing.damage
        if not conf or not conf.enabled then return end
        local cast = GetLastCast()
        Emit({
            kind       = "damage",
            amount     = amount,
            isCrit     = isCrit,
            schoolMask = tonumber(schoolMask) or 1,
            isAuto     = (cast == nil),
            spellId    = cast and cast.spellId,
            spellName  = cast and cast.spellName,
        })
        DebugPrint("WOUND on target amt=" .. tostring(amount))
        return
    end

    -- Outgoing heals: player's recent cast attributed to HEAL events on
    -- themselves or party members.
    if action == "HEAL" then
        local conf = db.outgoing.healing
        if not conf or not conf.enabled then return end

        local cast = GetLastCast()

        -- For "player": only show if player recently cast (avoid incoming heals from others).
        if unit == "player" and not cast then return end

        -- For party units: always require recent cast for attribution.
        if (unit == "party1" or unit == "party2" or unit == "party3" or unit == "party4")
        and not cast then return end

        Emit({
            kind       = "heal",
            amount     = amount,
            overheal   = 0,
            isCrit     = isCrit,
            schoolMask = tonumber(schoolMask) or 1,
            isAuto     = false,
            spellId    = cast and cast.spellId,
            spellName  = cast and cast.spellName,
        })
        DebugPrint("HEAL on " .. unit .. " amt=" .. tostring(amount))
    end
end)

function Outgoing:Enable()
    if self._enabled then return end
    self._enabled = true
end

function Outgoing:Disable()
    if not self._enabled then return end
    self._enabled = false
end
