local ADDON_NAME, KSBT = ...
print("|cff00ff00KSBT-Outgoing|r Outgoing_Detect.lua: file loading...")

KSBT.Parser = KSBT.Parser or {}
KSBT.Parser.Outgoing = KSBT.Parser.Outgoing or {}
local Outgoing = KSBT.Parser.Outgoing
print("|cff00ff00KSBT-Outgoing|r Outgoing_Detect.lua: table created, defining functions...")

local band = bit.band
print("|cff00ff00KSBT-Outgoing|r Outgoing_Detect.lua: bit.band=" .. tostring(band))
local AFFILIATION_MINE = COMBATLOG_OBJECT_AFFILIATION_MINE or 0x00000001
local TYPE_PLAYER      = COMBATLOG_OBJECT_TYPE_PLAYER      or 0x00000400

local function Debug(level, ...)
    if KSBT.Core and KSBT.Core.Debug then
        KSBT.Core:Debug(level, ...)
    elseif KSBT.Debug then
        KSBT.Debug(level, ...)
    end
end

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

local function Normalize(info)
    local ts       = info[1]
    local subevent = info[2]
    local sourceFlags = info[6]
    if not IsPlayerSource(sourceFlags) then
        -- Only log spell/swing events to avoid spam
        if subevent == "SWING_DAMAGE" or subevent == "SPELL_DAMAGE"
        or subevent == "SPELL_HEAL" or subevent == "SPELL_PERIODIC_HEAL"
        or subevent == "SPELL_PERIODIC_DAMAGE" or subevent == "RANGE_DAMAGE" then
            DebugPrint("IsPlayerSource FAILED for " .. tostring(subevent)
                .. " flags=" .. tostring(sourceFlags))
        end
        return nil
    end

    DebugPrint("IsPlayerSource OK: " .. tostring(subevent)
        .. " flags=" .. tostring(sourceFlags))

    local db = DB()
    if not db or not db.outgoing then
        DebugPrint("DB check FAILED: db=" .. tostring(db ~= nil)
            .. " outgoing=" .. tostring(db and db.outgoing ~= nil))
        return nil
    end

    local ev = {
        timestamp  = ts,
        sourceName = info[5],
        targetName = info[9],
        destFlags  = info[10],   -- destination unit type flags (for dummy detection)
    }

    if subevent == "SWING_DAMAGE" then
        if not (db.outgoing.damage and db.outgoing.damage.enabled) then return nil end
        ev.kind       = "damage"
        ev.amount     = tonumber(info[12]) or 0
        ev.schoolMask = tonumber(info[14]) or 1
        ev.spellId    = 6603
        ev.spellName  = "Auto Attack"
        ev.isAuto     = true
        ev.isCrit     = info[18] and true or false

    elseif subevent == "RANGE_DAMAGE" or subevent == "SPELL_DAMAGE" or subevent == "SPELL_PERIODIC_DAMAGE" then
        if not (db.outgoing.damage and db.outgoing.damage.enabled) then return nil end
        local spellId = tonumber(info[12])
        ev.kind       = "damage"
        ev.spellId    = spellId
        ev.spellName  = info[13]
        ev.schoolMask = tonumber(info[14]) or 1
        ev.amount     = tonumber(info[15]) or 0
        ev.isCrit     = info[20] and true or false
        ev.isAuto     = (subevent == "RANGE_DAMAGE") or (spellId == 75)

    elseif subevent == "SPELL_HEAL" or subevent == "SPELL_PERIODIC_HEAL" then
        if not (db.outgoing.healing and db.outgoing.healing.enabled) then return nil end
        ev.kind       = "heal"
        ev.spellId    = tonumber(info[12])
        ev.spellName  = info[13]
        ev.schoolMask = tonumber(info[14]) or 1
        ev.amount     = tonumber(info[15]) or 0
        ev.overheal   = tonumber(info[16]) or 0
        ev.isCrit     = info[18] and true or false
        ev.isAuto     = false

    else
        return nil
    end

    -- Outgoing tab gating relevant to probe visibility
    if ev.kind == "damage" then
        local dmg = db.outgoing.damage or {}
        if not dmg.showTargets then
            ev.targetName = nil
        end

        if ev.isAuto then
            local mode = dmg.autoAttackMode or "Show All"
            if mode == "Hide" then return nil end
            if mode == "Show Only Crits" and not ev.isCrit then return nil end
        end
    else
        local heal = db.outgoing.healing or {}
        if not heal.showOverheal then
            ev.overheal = 0
        end
    end

    DebugPrint("Normalize OK: kind=" .. tostring(ev.kind)
        .. " amount=" .. tostring(ev.amount)
        .. " spell=" .. tostring(ev.spellName))
    return ev
end

-- Frame wiring (no AceEvent)
local f = CreateFrame("Frame")
Outgoing._frame = f
Outgoing._enabled = false

local _relevantSubevents = {
    SWING_DAMAGE=true, SPELL_DAMAGE=true, SPELL_PERIODIC_DAMAGE=true,
    RANGE_DAMAGE=true, SPELL_HEAL=true, SPELL_PERIODIC_HEAL=true,
}

local _onEventCount = 0
f:SetScript("OnEvent", function(self, event)
    _onEventCount = _onEventCount + 1
    if _onEventCount <= 5 then
        print("|cff00ff00KSBT-Outgoing|r OnEvent #" .. _onEventCount
            .. " event=" .. tostring(event))
    end
    if event == "PLAYER_REGEN_DISABLED" then return end  -- diagnostic only
    if not Outgoing._enabled then return end
    local info = { CombatLogGetCurrentEventInfo() }
    if _onEventCount <= 5 then
        print("|cff00ff00KSBT-Outgoing|r #info=" .. tostring(#info)
            .. " subevent=" .. tostring(info[2]))
    end
    if #info == 0 then return end
    -- Only log relevant subevents to avoid chat spam
    if _relevantSubevents[info[2]] then
        DebugPrint("CLEU relevant: subevent=" .. tostring(info[2])
            .. " src=" .. tostring(info[5])
            .. " srcFlags=" .. tostring(info[6]))
    end

    local ok, evtOrErr = pcall(Normalize, info)
    if not ok then
        Debug(1, "Parser.Outgoing normalize error:", tostring(evtOrErr))
        print("|cffff0000KSBT-Outgoing|r Normalize ERROR: " .. tostring(evtOrErr))
        return
    end

    local evt = evtOrErr
    if evt then Emit(evt) end
end)

function Outgoing:Enable()
    if self._enabled then return end
    self._enabled = true
    f:Show()
    f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    f:RegisterEvent("COMBAT_LOG_EVENT")
    f:RegisterEvent("PLAYER_REGEN_DISABLED")  -- diagnostic: enters combat
    print("|cff00ff00KSBT-Outgoing|r Enable() - registered CLEU/COMBAT_LOG_EVENT/PLAYER_REGEN_DISABLED, shown=" .. tostring(f:IsShown()))
    Debug(1, "Parser.Outgoing enabled.")
end

function Outgoing:Disable()
    if not self._enabled then return end
    self._enabled = false
    f:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    Debug(1, "Parser.Outgoing disabled.")
end

print("|cff00ff00KSBT-Outgoing|r Outgoing_Detect.lua: FULLY LOADED, Enable=" .. tostring(Outgoing.Enable))
