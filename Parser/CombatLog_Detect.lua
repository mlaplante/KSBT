------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Combat Log Detection (CLEU)
--
-- Responsibility:
--   - Register COMBAT_LOG_EVENT_UNFILTERED
--   - Parse CombatLogGetCurrentEventInfo() payloads
--   - Route outgoing events (srcGUID == player) to OutgoingProbe
--   - Route incoming events (destGUID == player) to IncomingProbe
--   - Detect secret values via issecretvalue() for restricted content
--
-- Replaces the old Incoming_Detect.lua (UNIT_COMBAT on player) and
-- Outgoing_Detect.lua (UNIT_COMBAT on target + UNIT_SPELLCAST_SUCCEEDED).
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

KSBT.Parser = KSBT.Parser or {}
KSBT.Parser.CombatLog = KSBT.Parser.CombatLog or {}
local CombatLog = KSBT.Parser.CombatLog
local Addon     = KSBT.Addon

CombatLog._enabled = CombatLog._enabled or false
CombatLog._frame   = CombatLog._frame or nil

local _playerGUID = nil

local function Debug(level, ...)
    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(level, ...)
    end
end

local function IsSecret(val)
    return issecretvalue and issecretvalue(val) or false
end

local function GetPlayerGUID()
    if not _playerGUID then
        _playerGUID = UnitGUID("player")
    end
    return _playerGUID
end

local function EmitOutgoing(evt)
    local probe = KSBT.Core and KSBT.Core.OutgoingProbe
    if probe and probe.OnOutgoingDetected then
        probe:OnOutgoingDetected(evt)
    end
end

local function EmitIncoming(evt)
    local probe = KSBT.Core and KSBT.Core.IncomingProbe
    if probe and probe.OnIncomingDetected then
        probe:OnIncomingDetected(evt)
    end
end

local function SpellNameForId(spellId)
    if not spellId then return nil end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellId)
        return info and info.name
    end
    if GetSpellInfo then
        return (GetSpellInfo(spellId))
    end
end

------------------------------------------------------------------------
-- CLEU Sub-event Handlers
------------------------------------------------------------------------

local SPELL_DAMAGE_EVENTS = {
    SPELL_DAMAGE = true,
    SPELL_PERIODIC_DAMAGE = true,
    RANGE_DAMAGE = true,
}

local SPELL_HEAL_EVENTS = {
    SPELL_HEAL = true,
    SPELL_PERIODIC_HEAL = true,
}

local function HandleCLEU()
    local timestamp, subevent, hideCaster,
          srcGUID, srcName, srcFlags, srcRaidFlags,
          destGUID, destName, destFlags, destRaidFlags
          = CombatLogGetCurrentEventInfo()

    local playerGUID = GetPlayerGUID()
    if not playerGUID then return end

    local isOutgoing = (srcGUID == playerGUID)
    local isIncoming = (destGUID == playerGUID)
    if not isOutgoing and not isIncoming then return end

    local now = GetTime()

    ----------------------------------------------------------------
    -- SWING_DAMAGE: no spell prefix
    ----------------------------------------------------------------
    if subevent == "SWING_DAMAGE" then
        local amount, overkill, school, resisted, blocked, absorbed, critical = select(12, CombatLogGetCurrentEventInfo())
        local secret = IsSecret(amount)

        if isOutgoing then
            EmitOutgoing({
                ts         = now,
                kind       = "damage",
                amount     = amount,
                isSecret   = secret,
                isAuto     = true,
                isCrit     = (critical == true) or (critical == 1),
                isPeriodic = false,
                spellId    = nil,
                spellName  = nil,
                schoolMask = school or 1,
                destFlags  = destFlags,
                targetName = destName,
            })
        end
        if isIncoming then
            EmitIncoming({
                ts         = now,
                kind       = "damage",
                amount     = amount,
                isSecret   = secret,
                isCrit     = (critical == true) or (critical == 1),
                isPeriodic = false,
                schoolMask = school or 1,
                spellId    = nil,
                spellName  = nil,
                sourceName = srcName,
                absorbed   = absorbed,
            })
        end
        return
    end

    ----------------------------------------------------------------
    -- SPELL_DAMAGE / SPELL_PERIODIC_DAMAGE / RANGE_DAMAGE
    ----------------------------------------------------------------
    if SPELL_DAMAGE_EVENTS[subevent] then
        local spellId, spellName, spellSchool, amount, overkill, school, resisted, blocked, absorbed, critical = select(12, CombatLogGetCurrentEventInfo())
        local secret = IsSecret(amount)
        local isPeriodic = (subevent == "SPELL_PERIODIC_DAMAGE")

        if isOutgoing then
            EmitOutgoing({
                ts         = now,
                kind       = "damage",
                amount     = amount,
                isSecret   = secret,
                isAuto     = false,
                isCrit     = (critical == true) or (critical == 1),
                isPeriodic = isPeriodic,
                spellId    = spellId,
                spellName  = spellName or SpellNameForId(spellId),
                schoolMask = spellSchool or school or 1,
                destFlags  = destFlags,
                targetName = destName,
            })
        end
        if isIncoming then
            EmitIncoming({
                ts         = now,
                kind       = "damage",
                amount     = amount,
                isSecret   = secret,
                isCrit     = (critical == true) or (critical == 1),
                isPeriodic = isPeriodic,
                schoolMask = spellSchool or school or 1,
                spellId    = spellId,
                spellName  = spellName or SpellNameForId(spellId),
                sourceName = srcName,
                absorbed   = absorbed,
            })
        end
        return
    end

    ----------------------------------------------------------------
    -- ENVIRONMENTAL_DAMAGE (incoming only)
    ----------------------------------------------------------------
    if subevent == "ENVIRONMENTAL_DAMAGE" then
        if not isIncoming then return end
        local envType, amount, overkill, school, resisted, blocked, absorbed, critical = select(12, CombatLogGetCurrentEventInfo())
        local secret = IsSecret(amount)

        EmitIncoming({
            ts         = now,
            kind       = "damage",
            amount     = amount,
            isSecret   = secret,
            isCrit     = (critical == true) or (critical == 1),
            isPeriodic = false,
            schoolMask = school or 1,
            spellId    = nil,
            spellName  = envType,
            sourceName = envType,
            absorbed   = absorbed,
        })
        return
    end

    ----------------------------------------------------------------
    -- SPELL_HEAL / SPELL_PERIODIC_HEAL
    ----------------------------------------------------------------
    if SPELL_HEAL_EVENTS[subevent] then
        local spellId, spellName, spellSchool, amount, overhealing, absorbed, critical = select(12, CombatLogGetCurrentEventInfo())
        local secret = IsSecret(amount)
        local isPeriodic = (subevent == "SPELL_PERIODIC_HEAL")

        if isOutgoing then
            EmitOutgoing({
                ts         = now,
                kind       = "heal",
                amount     = amount,
                isSecret   = secret,
                overheal   = overhealing,
                isAuto     = false,
                isCrit     = (critical == true) or (critical == 1),
                isPeriodic = isPeriodic,
                spellId    = spellId,
                spellName  = spellName or SpellNameForId(spellId),
                schoolMask = spellSchool or 1,
                destFlags  = destFlags,
                targetName = destName,
            })
        end
        if isIncoming then
            EmitIncoming({
                ts         = now,
                kind       = "heal",
                amount     = amount,
                isSecret   = secret,
                isCrit     = (critical == true) or (critical == 1),
                isPeriodic = isPeriodic,
                schoolMask = spellSchool or 1,
                spellId    = spellId,
                spellName  = spellName or SpellNameForId(spellId),
                sourceName = srcName,
                absorbed   = absorbed,
            })
        end
        return
    end
end

------------------------------------------------------------------------
-- Enable / Disable
------------------------------------------------------------------------
-- Create frame and register CLEU at load time (untainted execution path).
-- OnEnable/OnDisable runs through AceAddon which can carry taint from other
-- addons, making RegisterEvent() a protected-call violation in Midnight.
do
    local f = CreateFrame("Frame")
    CombatLog._frame = f
    f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    f:SetScript("OnEvent", function()
        if CombatLog._enabled then
            HandleCLEU()
        end
    end)
end

function CombatLog:Enable()
    if self._enabled then return end
    self._enabled = true
    _playerGUID = UnitGUID("player")
    Debug(1, "Parser.CombatLog:Enable()")
end

function CombatLog:Disable()
    if not self._enabled then return end
    self._enabled = false
    Debug(1, "Parser.CombatLog:Disable()")
end
