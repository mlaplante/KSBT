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
    if not flags or type(flags) ~= "number" then return false end
    return band(flags, FLAG_MINE) ~= 0 and band(flags, FLAG_PLAYER) ~= 0
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
-- Cast history is managed by KSBT.CastHistory (Parser/CastHistory.lua)
-- Legacy single-cast tracking removed in favor of rolling buffer

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
            local isCrit = IsCrit(critical)
            EmitOutgoing({
                ts         = now,
                kind       = "damage",
                amount     = amount,
                isSecret   = secret,
                isAuto     = false,
                isCrit     = isCrit,
                isPeriodic = isPeriodic,
                spellId    = spellId,
                spellName  = spellName or SpellNameForId(spellId),
                schoolMask = spellSchool or school or 1,
                destFlags  = destFlags,
                targetName = destName,
            })

                -- Record observation for spell learning
                if KSBT.SpellFingerprints then
                    local castDelay
                    local castEntry = KSBT.CastHistory:FindMostRecentCast(spellId, now)
                    if castEntry then
                        castDelay = now - castEntry.timestamp
                    end
                    KSBT.SpellFingerprints:RecordObservation(
                        spellId, spellName, amount, isCrit, isPeriodic, spellSchool or school or 1, castDelay)

                    -- Debug log (level 2)
                    if KSBT.DebugLog and KSBT.DebugLog:GetLevel() >= 2 then
                        KSBT.DebugLog:Add(2, "green",
                            string.format("Learned: %s #%d — %s%s [sample #%d]",
                                spellName or "?", spellId,
                                tostring(amount),
                                isCrit and " (crit)" or "",
                                KSBT.SpellFingerprints:Get(spellId)
                                    and KSBT.SpellFingerprints:Get(spellId).sampleCount or 1))
                    end
                end
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

        -- UNIT_COMBAT "target" fires for ALL sources hitting the target.
        -- Only emit if CLEU marked this as our hit, OR if CLEU is not
        -- registered (no gating available, accept false positives).
        if CombatLog._cleuRegistered and not _cleuOutgoingMark then return end
        _cleuOutgoingMark = false

        local evt = {
            ts         = now,
            kind       = kind,
            amount     = amount,
            isSecret   = secret,
            isAuto     = true,
            isCrit     = isCrit,
            isPeriodic = false,
            spellId    = nil,
            spellName  = nil,
            schoolMask = school or 1,
            destFlags  = nil,
            targetName = nil,
        }

        -- Attempt spell attribution via learning system (damage only, not heals)
        if not evt.spellId and evt.kind == "damage" then
            local matchId, matchName, confidence = KSBT.SpellMatcher:Match(
                evt.amount, evt.schoolMask, evt.isCrit, evt.isPeriodic, now)
            if matchId then
                evt.spellId   = matchId
                evt.spellName = matchName
            end
        end

        EmitOutgoing(evt)
    end
end

------------------------------------------------------------------------
-- UNIT_SPELLCAST_SUCCEEDED tracker: gives UNIT_COMBAT spell context.
------------------------------------------------------------------------
local function HandleSpellcastSucceeded(unit, _, spellId)
    if unit ~= "player" then return end
    local name = SpellNameForId(spellId)
    KSBT.CastHistory:Push(spellId, name, GetTime())

    -- Debug log (level 2 = observations + cast tracking)
    if KSBT.DebugLog and KSBT.DebugLog:GetLevel() >= 2 then
        KSBT.DebugLog:Add(2, "gray",
            string.format("Cast: %s #%d at %s",
                name or "?", spellId, date("%H:%M:%S.") .. string.format("%03d", (GetTime() % 1) * 1000)))
    end
end

local function HandleChannelStart(unit, _, spellId)
    if unit ~= "player" then return end
    local name = SpellNameForId(spellId)
    KSBT.CastHistory:Push(spellId, name, GetTime())

    if KSBT.DebugLog and KSBT.DebugLog:GetLevel() >= 2 then
        KSBT.DebugLog:Add(2, "gray",
            string.format("Channel: %s #%d at %s",
                name or "?", spellId, date("%H:%M:%S.") .. string.format("%03d", (GetTime() % 1) * 1000)))
    end
end

------------------------------------------------------------------------
-- Event Registration (pcall + retry for Midnight protected phases)
------------------------------------------------------------------------
local _cleuFrame    = CreateFrame("Frame")
local _ucFrame      = CreateFrame("Frame")
local _spellFrame   = CreateFrame("Frame")

-- CLEU handler
_cleuFrame:SetScript("OnEvent", function()
    if CombatLog._enabled then
        local ok, err = pcall(HandleCLEU)
        if not ok then
            Debug(2, "Parser.CombatLog: CLEU handler error: " .. tostring(err))
        end
    end
end)

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
_spellFrame:SetScript("OnEvent", function(_, event, unit, _, spellId)
    if not CombatLog._enabled then return end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        pcall(HandleSpellcastSucceeded, unit, nil, spellId)
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        pcall(HandleChannelStart, unit, nil, spellId)
    end
end)

local function TryRegisterCLEU()
    if CombatLog._cleuRegistered then return end
    local ok = pcall(function()
        _cleuFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    end)
    if ok then
        CombatLog._cleuRegistered = true
        Debug(1, "Parser.CombatLog: CLEU registered successfully")
    else
        C_Timer.After(0.5, TryRegisterCLEU)
    end
end

local function TryRegisterUnitCombat()
    if CombatLog._ucRegistered then return end
    local ok = pcall(function()
        if _ucFrame.RegisterUnitEvent then
            -- Register for both "player" (incoming) and "target" (outgoing).
            _ucFrame:RegisterUnitEvent("UNIT_COMBAT", "player", "target")
        else
            _ucFrame:RegisterEvent("UNIT_COMBAT")
        end
    end)
    if ok then
        CombatLog._ucRegistered = true
        Debug(1, "Parser.CombatLog: UNIT_COMBAT registered successfully")
    else
        C_Timer.After(0.5, TryRegisterUnitCombat)
    end
end

local _spellRegistered = false
local function TryRegisterSpellcast()
    if _spellRegistered then return end
    local ok = pcall(function()
        if _spellFrame.RegisterUnitEvent then
            _spellFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
            _spellFrame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
        else
            _spellFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
            _spellFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
        end
    end)
    if ok then
        _spellRegistered = true
        Debug(1, "Parser.CombatLog: UNIT_SPELLCAST_SUCCEEDED registered")
    else
        C_Timer.After(0.5, TryRegisterSpellcast)
    end
end

-- Delay initial attempts to let the client settle after load.
C_Timer.After(1, TryRegisterUnitCombat)
C_Timer.After(1, TryRegisterSpellcast)
C_Timer.After(2, TryRegisterCLEU)

-- If player reloads during combat, retry registration when combat ends.
do
    local regenFrame = CreateFrame("Frame")
    local ok = pcall(function()
        regenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    end)
    if ok then
        regenFrame:SetScript("OnEvent", function()
            if not CombatLog._cleuRegistered then TryRegisterCLEU() end
            if not CombatLog._ucRegistered then TryRegisterUnitCombat() end
            if not _spellRegistered then TryRegisterSpellcast() end
        end)
    end
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
