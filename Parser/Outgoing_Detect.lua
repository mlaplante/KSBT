local ADDON_NAME, KSBT = ...

KSBT.Parser = KSBT.Parser or {}
KSBT.Parser.Outgoing = KSBT.Parser.Outgoing or {}
local Outgoing = KSBT.Parser.Outgoing

local band = bit.band
local AFFILIATION_MINE = COMBATLOG_OBJECT_AFFILIATION_MINE or 0x00000001
local TYPE_PLAYER      = COMBATLOG_OBJECT_TYPE_PLAYER      or 0x00000400

local function DebugPrint(msg)
    local db = KSBT.db and KSBT.db.profile
    local lvl = db and db.diagnostics and db.diagnostics.debugLevel or 0
    if lvl >= 1 then
        print("|cff00ff00KSBT-Outgoing|r " .. tostring(msg))
    end
end

local function IsPlayerSource(flags)
    if not flags then return false end
    return band(flags, AFFILIATION_MINE) ~= 0 and band(flags, TYPE_PLAYER) ~= 0
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

local function SafeBool(val)
    local ok, b = pcall(function() return val and true or false end)
    return ok and b or false
end

local function Normalize(info)
    local subevent    = info[2]
    local sourceFlags = info[6]
    if not IsPlayerSource(sourceFlags) then return nil end

    local db = DB()
    if not db or not db.outgoing then return nil end

    local ev = {
        timestamp  = info[1],
        sourceName = info[5],
        targetName = info[9],
        destFlags  = info[10],
    }

    if subevent == "SWING_DAMAGE" then
        if not (db.outgoing.damage and db.outgoing.damage.enabled) then return nil end
        ev.kind       = "damage"
        ev.amount     = info[12]
        ev.schoolMask = tonumber(info[14]) or 1
        ev.spellId    = 6603
        ev.spellName  = "Auto Attack"
        ev.isAuto     = true
        ev.isCrit     = SafeBool(info[18])

    elseif subevent == "RANGE_DAMAGE" or subevent == "SPELL_DAMAGE" or subevent == "SPELL_PERIODIC_DAMAGE" then
        if not (db.outgoing.damage and db.outgoing.damage.enabled) then return nil end
        local spellId = tonumber(info[12])
        ev.kind       = "damage"
        ev.spellId    = spellId
        ev.spellName  = info[13]
        ev.schoolMask = tonumber(info[14]) or 1
        ev.amount     = info[15]
        ev.isCrit     = SafeBool(info[21])
        ev.isAuto     = (subevent == "RANGE_DAMAGE") or (spellId == 75)

    elseif subevent == "SPELL_HEAL" or subevent == "SPELL_PERIODIC_HEAL" then
        if not (db.outgoing.healing and db.outgoing.healing.enabled) then return nil end
        ev.kind       = "heal"
        ev.spellId    = tonumber(info[12])
        ev.spellName  = info[13]
        ev.schoolMask = tonumber(info[14]) or 1
        ev.amount     = info[15]
        ev.overheal   = info[16]
        ev.isCrit     = SafeBool(info[18])
        ev.isAuto     = false

    else
        return nil
    end

    if ev.kind == "damage" then
        local dmg = db.outgoing.damage or {}
        if not dmg.showTargets then ev.targetName = nil end
        if ev.isAuto then
            local mode = dmg.autoAttackMode or "Show All"
            if mode == "Hide" then return nil end
            if mode == "Show Only Crits" and not ev.isCrit then return nil end
        end
    else
        local heal = db.outgoing.healing or {}
        if not heal.showOverheal then ev.overheal = nil end
    end

    DebugPrint("Normalize OK: kind=" .. tostring(ev.kind) .. " spell=" .. tostring(ev.spellName))
    return ev
end

local function _handleCLEU()
    if not Outgoing._enabled then return end
    local info = { CombatLogGetCurrentEventInfo() }
    if #info == 0 then return end
    local ok, evtOrErr = pcall(Normalize, info)
    if not ok then
        DebugPrint("Normalize ERROR: " .. tostring(evtOrErr))
        return
    end
    if evtOrErr then Emit(evtOrErr) end
end

------------------------------------------------------------------------
-- Event registration
--
-- COMBAT_LOG_EVENT_UNFILTERED is permanently blocked for addon code in
-- WoW Midnight (ADDON_ACTION_FORBIDDEN, regardless of combat state).
--
-- COMBAT_LOG_EVENT is the filtered variant (player-involved events only).
-- We try to register it; if also forbidden, fall back silently — the
-- Incoming parser handles incoming events via UNIT_COMBAT independently.
------------------------------------------------------------------------
local f = CreateFrame("Frame")
Outgoing._frame   = f
Outgoing._enabled = false

local _registered = false
local function _tryRegister()
    if _registered then return end
    local ok = pcall(f.RegisterEvent, f, "COMBAT_LOG_EVENT")
    if ok then
        _registered = true
        DebugPrint("COMBAT_LOG_EVENT registered OK")
    else
        -- Also forbidden — outgoing via CLEU unavailable on this build.
        print("|cffff9900KSBT-Outgoing|r COMBAT_LOG_EVENT also forbidden; outgoing CLEU unavailable.")
    end
end

f:SetScript("OnEvent", function(self, event)
    if event ~= "COMBAT_LOG_EVENT" then return end
    _handleCLEU()
end)

function Outgoing:Enable()
    if self._enabled then return end
    self._enabled = true
    _tryRegister()
end

function Outgoing:Disable()
    if not self._enabled then return end
    self._enabled = false
end
