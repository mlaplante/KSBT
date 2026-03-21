------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Combat Log Detection (CLEU + UNIT_COMBAT)
--
-- Responsibility:
--   - Register COMBAT_LOG_EVENT_UNFILTERED (pcall + retry)
--   - Register UNIT_COMBAT on "player" as incoming fallback
--   - Parse combat event payloads
--   - Route outgoing events (sourceFlags MINE+PLAYER) to OutgoingProbe
--   - Route incoming events (destFlags MINE+PLAYER) to IncomingProbe
--   - Detect secret values via issecretvalue() for restricted content
--   - All operations on potentially secret values are pcall-wrapped
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

KSBT.Parser = KSBT.Parser or {}
KSBT.Parser.CombatLog = KSBT.Parser.CombatLog or {}
local CombatLog = KSBT.Parser.CombatLog
local Addon     = KSBT.Addon

CombatLog._enabled = CombatLog._enabled or false

CombatLog._cleuRegistered = false
CombatLog._ucRegistered   = false

-- Resolve the correct API: Midnight moved it to C_CombatLog namespace.
local GetCombatLogInfo = CombatLogGetCurrentEventInfo
    or (C_CombatLog and C_CombatLog.GetCurrentEventInfo)

-- Bitwise helpers for sourceFlags / destFlags attribution.
-- Safer than GUID comparison because GUIDs can be secret in restricted content.
local band = bit.band
local FLAG_MINE   = COMBATLOG_OBJECT_AFFILIATION_MINE or 0x00000001
local FLAG_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER       or 0x00000400

local function Debug(level, ...)
    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(level, ...)
    end
end

local function IsSecret(val)
    return issecretvalue and issecretvalue(val) or false
end

-- Safe crit check: the `critical` field from CLEU can be a secret boolean.
local function IsCrit(critical)
    if critical == nil then return false end
    local ok, result = pcall(function() return critical == true or critical == 1 end)
    return ok and result or false
end

local function IsPlayerMine(flags)
    if not flags then return false end
    -- flags can be a secret number in boss encounters; pcall protects band()
    local ok, result = pcall(function()
        return band(flags, FLAG_MINE) ~= 0 and band(flags, FLAG_PLAYER) ~= 0
    end)
    return ok and result or false
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
        local ok, info = pcall(C_Spell.GetSpellInfo, spellId)
        return ok and info and info.name
    end
    if GetSpellInfo then
        local ok, name = pcall(GetSpellInfo, spellId)
        return ok and name
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

-- Deduplication timestamps: if CLEU already handled an event this frame, skip UC.
local _lastCLEUIncoming = 0
local _lastCLEUOutgoing = 0

-- CLEU gating for outgoing UNIT_COMBAT: mark that the player hit the target
-- this frame, so UNIT_COMBAT "target" knows it was our damage.
local _cleuOutgoingMark = false

-- Last spell cast tracker (for UNIT_COMBAT which lacks spellId).
local _lastCastSpellId   = nil
local _lastCastSpellName = nil
local _lastCastTime      = 0

local function HandleCLEU()
    if not GetCombatLogInfo then return end

    local timestamp, subevent, hideCaster,
          srcGUID, srcName, srcFlags, srcRaidFlags,
          destGUID, destName, destFlags, destRaidFlags
          = GetCombatLogInfo()

    -- Use sourceFlags/destFlags for attribution (safe with secret GUIDs).
    local isOutgoing = IsPlayerMine(srcFlags)
    local isIncoming = IsPlayerMine(destFlags)
    if not isOutgoing and not isIncoming then return end

    local now = GetTime()

    -- Mark CLEU handled this frame for deduplication against UNIT_COMBAT.
    if isOutgoing then
        _lastCLEUOutgoing = now
        _cleuOutgoingMark = true
    end
    if isIncoming then
        _lastCLEUIncoming = now
    end

    ----------------------------------------------------------------
    -- SWING_DAMAGE: no spell prefix
    ----------------------------------------------------------------
    if subevent == "SWING_DAMAGE" then
        local amount, overkill, school, resisted, blocked, absorbed, critical = select(12, GetCombatLogInfo())
        local secret = IsSecret(amount)

        if isOutgoing then
            EmitOutgoing({
                ts         = now,
                kind       = "damage",
                amount     = amount,
                isSecret   = secret,
                isAuto     = true,
                isCrit     = IsCrit(critical),
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
                isCrit     = IsCrit(critical),
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
        local spellId, spellName, spellSchool, amount, overkill, school, resisted, blocked, absorbed, critical = select(12, GetCombatLogInfo())
        local secret = IsSecret(amount)
        local isPeriodic = (subevent == "SPELL_PERIODIC_DAMAGE")

        if isOutgoing then
            EmitOutgoing({
                ts         = now,
                kind       = "damage",
                amount     = amount,
                isSecret   = secret,
                isAuto     = false,
                isCrit     = IsCrit(critical),
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
                isCrit     = IsCrit(critical),
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
        local envType, amount, overkill, school, resisted, blocked, absorbed, critical = select(12, GetCombatLogInfo())
        local secret = IsSecret(amount)

        EmitIncoming({
            ts         = now,
            kind       = "damage",
            amount     = amount,
            isSecret   = secret,
            isCrit     = IsCrit(critical),
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
        local spellId, spellName, spellSchool, amount, overhealing, absorbed, critical = select(12, GetCombatLogInfo())
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
                isCrit     = IsCrit(critical),
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
                isCrit     = IsCrit(critical),
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
-- UNIT_COMBAT fallback (fires even when CLEU registration fails).
-- "player" = incoming, "target" = outgoing (gated by CLEU mark).
-- Uses deduplication: if CLEU already emitted this frame, skip.
------------------------------------------------------------------------
local UNIT_COMBAT_KIND = {
    WOUND  = "damage",
    HEAL   = "heal",
}

local function HandleUnitCombat(unit, action, indicator, amount, school)
    local kind = UNIT_COMBAT_KIND[action]
    if not kind then return end

    local now = GetTime()
    local secret = IsSecret(amount)
    local isCrit = (indicator == "CRITICAL")

    if unit == "player" then
        -- Incoming fallback: skip if CLEU already handled this frame.
        if now == _lastCLEUIncoming then return end

        EmitIncoming({
            ts         = now,
            kind       = kind,
            amount     = amount,
            isSecret   = secret,
            isCrit     = isCrit,
            isPeriodic = false,
            schoolMask = school or 1,
            spellId    = nil,
            spellName  = nil,
            sourceName = nil,
        })

    elseif unit == "target" then
        -- Outgoing fallback: skip if CLEU already handled this frame.
        if now == _lastCLEUOutgoing then return end

        -- UNIT_COMBAT "target" fires for ALL sources hitting the target
        -- (entire raid/group). Attribution strategy depends on CLEU:
        --
        -- CLEU available (Classic/Retail): require _cleuOutgoingMark flag
        -- set by HandleCLEU when source flags match the player.
        --
        -- CLEU unavailable (Midnight): use spell-cast correlation — only
        -- accept the event if UNIT_SPELLCAST_SUCCEEDED fired within 400ms.
        -- This means auto-attacks are skipped (no cast event), but all
        -- spell/ability damage is attributed correctly.
        local spellId, spellName

        if CombatLog._cleuRegistered then
            -- CLEU path: strict flag-based attribution
            if not _cleuOutgoingMark then return end
            _cleuOutgoingMark = false

            -- Attach last-cast spell info if recent enough (1.5s window).
            if _lastCastTime and (now - _lastCastTime) < 1.5 then
                spellId   = _lastCastSpellId
                spellName = _lastCastSpellName
            end
        else
            -- Midnight path: cast-consume token model.
            -- Reject if no token available — event was not caused by the player's cast
            -- (auto-attack, pet, or another player in the group).
            local mgr = KSBT.Parser and KSBT.Parser.CastTokenManager
            if not mgr then return end
            local tok = mgr:ConsumeToken(school)
            if not tok then return end
            spellId   = tok.spellId
            spellName = tok.spellName
        end

        EmitOutgoing({
            ts         = now,
            kind       = kind,
            amount     = amount,
            isSecret   = secret,
            isAuto     = (spellId == nil),
            isCrit     = isCrit,
            isPeriodic = false,
            spellId    = spellId,
            spellName  = spellName,
            schoolMask = school or 1,
            destFlags  = nil,
            targetName = nil,
        })
    end
end

------------------------------------------------------------------------
-- UNIT_SPELLCAST_SUCCEEDED tracker: gives UNIT_COMBAT spell context.
------------------------------------------------------------------------
local function HandleSpellcastSucceeded(unit, _, spellId)
    if unit ~= "player" then return end
    _lastCastSpellId   = spellId
    _lastCastSpellName = SpellNameForId(spellId)
    _lastCastTime      = GetTime()

    -- Push a cast token for Midnight attribution (school deferred — unknown at cast time).
    local mgr = KSBT.Parser and KSBT.Parser.CastTokenManager
    if mgr then
        mgr:PushToken(spellId, _lastCastSpellName, nil)
    end
end

------------------------------------------------------------------------
-- Event Registration
--
-- Register at file load time (trusted execution context). Never use
-- pcall + retry for RegisterEvent — pcall does NOT suppress WoW's
-- ADDON_ACTION_FORBIDDEN; each attempt generates taint that spreads
-- to NPC/vendor frames.
--
-- CLEU: skip entirely if the API doesn't exist (removed in Midnight).
-- UNIT_COMBAT / UNIT_SPELLCAST_SUCCEEDED: register directly.
------------------------------------------------------------------------
local _ucFrame      = CreateFrame("Frame")
local _spellFrame   = CreateFrame("Frame")

-- UNIT_COMBAT handler (incoming "player" + outgoing "target")
_ucFrame:SetScript("OnEvent", function(_, _, unit, action, indicator, amount, school)
    if CombatLog._enabled then
        local ok, err = pcall(HandleUnitCombat, unit, action, indicator, amount, school)
        if not ok then
            Debug(2, "Parser.CombatLog: UNIT_COMBAT handler error: " .. tostring(err))
        end
    end
end)

-- Spell cast tracker (enriches UNIT_COMBAT with spell info)
_spellFrame:SetScript("OnEvent", function(_, _, unit, _, spellId)
    if CombatLog._enabled then
        pcall(HandleSpellcastSucceeded, unit, nil, spellId)
    end
end)

-- CLEU: only register if the combat log API actually exists.
if GetCombatLogInfo then
    local _cleuFrame = CreateFrame("Frame")
    _cleuFrame:SetScript("OnEvent", function()
        if CombatLog._enabled then
            local ok, err = pcall(HandleCLEU)
            if not ok then
                Debug(2, "Parser.CombatLog: CLEU handler error: " .. tostring(err))
            end
        end
    end)
    _cleuFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    CombatLog._cleuRegistered = true
    Debug(1, "Parser.CombatLog: CLEU registered successfully")
else
    Debug(1, "Parser.CombatLog: CLEU API not available, skipping registration")
end

-- UNIT_COMBAT: register directly at load time.
-- Always register for both "player" (incoming) and "target" (outgoing).
-- When CLEU is available: outgoing is gated by _cleuOutgoingMark.
-- When CLEU is unavailable (Midnight): outgoing is gated by spell-cast
-- correlation (400ms window from UNIT_SPELLCAST_SUCCEEDED).
if _ucFrame.RegisterUnitEvent then
    _ucFrame:RegisterUnitEvent("UNIT_COMBAT", "player", "target")
    if CombatLog._cleuRegistered then
        Debug(1, "Parser.CombatLog: UNIT_COMBAT registered for player + target (CLEU gated)")
    else
        Debug(1, "Parser.CombatLog: UNIT_COMBAT registered for player + target (spell-cast correlated)")
    end
else
    _ucFrame:RegisterEvent("UNIT_COMBAT")
    Debug(1, "Parser.CombatLog: UNIT_COMBAT registered (legacy, ungated)")
end
CombatLog._ucRegistered = true

-- UNIT_SPELLCAST_SUCCEEDED: register directly at load time.
if _spellFrame.RegisterUnitEvent then
    _spellFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
else
    _spellFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
end
Debug(1, "Parser.CombatLog: UNIT_SPELLCAST_SUCCEEDED registered")

------------------------------------------------------------------------
-- Public handler wrappers (used by integration tests in Suite 8).
------------------------------------------------------------------------
function CombatLog:HandleUnitCombat(unit, action, indicator, amount, school)
    local ok, err = pcall(HandleUnitCombat, unit, action, indicator, amount, school)
    if not ok then
        Debug(2, "Parser.CombatLog: HandleUnitCombat error: " .. tostring(err))
    end
end

function CombatLog:HandleSpellcastSucceeded(unit, arg2, spellId)
    pcall(HandleSpellcastSucceeded, unit, arg2, spellId)
end

------------------------------------------------------------------------
-- Enable / Disable
------------------------------------------------------------------------
function CombatLog:Enable()
    if self._enabled then return end
    self._enabled = true
    Debug(1, "Parser.CombatLog:Enable()")
end

function CombatLog:Disable()
    if not self._enabled then return end
    self._enabled = false
    Debug(1, "Parser.CombatLog:Disable()")
end
