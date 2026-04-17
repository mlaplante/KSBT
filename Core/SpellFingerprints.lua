------------------------------------------------------------------------
--  Core/SpellFingerprints.lua – Per-character spell profile database
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

local GetSpecialization     = GetSpecialization
local GetSpecializationInfo = GetSpecializationInfo
local math_min  = math.min
local math_max  = math.max
local math_sqrt = math.sqrt
local math_abs  = math.abs
local pairs     = pairs
local issecretvalue = issecretvalue

-- ── Module ──────────────────────────────────────────────────
local SpellFingerprints = {}
KSBT.SpellFingerprints  = SpellFingerprints

local _db = {}  -- the actual fingerprint table, keyed by "specId:spellId"

------------------------------------------------------------------------
--  Get current spec ID (returns 0 if unavailable)
------------------------------------------------------------------------
local function GetCurrentSpecId()
    local specIndex = GetSpecialization()
    if not specIndex then return 0 end
    local specId = GetSpecializationInfo(specIndex)
    return specId or 0
end

------------------------------------------------------------------------
--  Build composite key: "specId:spellId"
------------------------------------------------------------------------
local function MakeKey(spellId)
    return GetCurrentSpecId() .. ":" .. spellId
end

------------------------------------------------------------------------
--  Initialize from SavedVariablesPerCharacter
------------------------------------------------------------------------
function SpellFingerprints:Load()
    KSBT_SpellFingerprints = KSBT_SpellFingerprints or {}
    local saved = KSBT_SpellFingerprints

    -- Schema migration: wipe if wrong version
    if saved.schemaVersion ~= KSBT.SCHEMA_VERSION then
        KSBT_SpellFingerprints = { schemaVersion = KSBT.SCHEMA_VERSION, fingerprints = {} }
        saved = KSBT_SpellFingerprints
    end

    saved.fingerprints = saved.fingerprints or {}
    _db = saved.fingerprints
end

------------------------------------------------------------------------
--  Get a fingerprint by spellId (uses current spec)
------------------------------------------------------------------------
function SpellFingerprints:Get(spellId)
    return _db[MakeKey(spellId)]
end

------------------------------------------------------------------------
--  Get a fingerprint by raw key (for iteration)
------------------------------------------------------------------------
function SpellFingerprints:GetByKey(key)
    return _db[key]
end

------------------------------------------------------------------------
--  Iterate all fingerprints (returns key, fp pairs)
------------------------------------------------------------------------
function SpellFingerprints:Iter()
    return pairs(_db)
end

------------------------------------------------------------------------
--  Compute effective alpha for EMA (simple avg during warmup)
------------------------------------------------------------------------
local function EffectiveAlpha(count)
    if count <= KSBT.EMA_WARMUP_COUNT then
        return 1.0 / count  -- simple average: weight = 1/n
    end
    return KSBT.EMA_ALPHA
end

------------------------------------------------------------------------
--  Record a confirmed observation from a CLEU event
--  amount may be nil/secret (only non-numeric signals recorded)
------------------------------------------------------------------------
function SpellFingerprints:RecordObservation(spellId, spellName, amount, isCrit, isPeriodic, schoolMask, castDelay)
    local key = MakeKey(spellId)
    local fp  = _db[key]

    if not fp then
        -- Enforce size cap
        self:_EnforceSizeCap()

        fp = {
            spellId        = spellId,
            spellName      = spellName or ("Spell#" .. spellId),
            schoolMask     = schoolMask,
            isPeriodic     = isPeriodic or false,
            damageMin      = nil,
            damageMax      = nil,
            damageAvg      = nil,
            damageVar      = 0,
            damageCount    = 0,
            critCount      = 0,
            sampleCount    = 0,
            avgCastToHitDelay = nil,
            delayVar       = 0,
            maxHitsPerCast = 1,
            schemaVersion  = KSBT.SCHEMA_VERSION,
        }
        _db[key] = fp
    end

    -- Update always-available signals
    fp.sampleCount = fp.sampleCount + 1
    if isCrit then
        fp.critCount = fp.critCount + 1
    end
    if schoolMask then
        fp.schoolMask = schoolMask  -- refresh in case it was nil before
    end
    fp.isPeriodic = fp.isPeriodic or (isPeriodic or false)
    fp.spellName  = spellName or fp.spellName  -- keep latest name

    -- Update damage range (only if amount is a real number)
    local isSecret = amount and issecretvalue and issecretvalue(amount)
    if amount and not isSecret then
        fp.damageCount = fp.damageCount + 1
        local n     = fp.damageCount
        local alpha = EffectiveAlpha(n)

        if not fp.damageAvg then
            -- First observation
            fp.damageAvg = amount
            fp.damageMin = amount
            fp.damageMax = amount
            fp.damageVar = 0
        else
            -- EMA update for avg
            local oldAvg = fp.damageAvg
            fp.damageAvg = (1 - alpha) * oldAvg + alpha * amount
            -- EMA update for variance
            local diff = amount - oldAvg
            fp.damageVar = (1 - alpha) * fp.damageVar + alpha * (diff * diff)
            -- Update min/max (these track all-time extremes)
            fp.damageMin = math_min(fp.damageMin, amount)
            fp.damageMax = math_max(fp.damageMax, amount)
        end
    end

    -- Update cast-to-hit delay (if available)
    if castDelay and castDelay >= 0 then
        local delayCount = fp.sampleCount  -- use sampleCount for delay alpha
        local alpha = EffectiveAlpha(delayCount)

        if not fp.avgCastToHitDelay then
            fp.avgCastToHitDelay = castDelay
            fp.delayVar = 0
        else
            local oldDelay = fp.avgCastToHitDelay
            fp.avgCastToHitDelay = (1 - alpha) * oldDelay + alpha * castDelay
            local diff = castDelay - oldDelay
            fp.delayVar = (1 - alpha) * fp.delayVar + alpha * (diff * diff)
        end
    end
end

------------------------------------------------------------------------
--  Update maxHitsPerCast for AoE detection
--  Called after a CLEU event confirms multiple hits from same cast
------------------------------------------------------------------------
function SpellFingerprints:UpdateMaxHits(spellId, hitCount)
    local fp = _db[MakeKey(spellId)]
    if fp and hitCount > (fp.maxHitsPerCast or 1) then
        fp.maxHitsPerCast = hitCount
    end
end

------------------------------------------------------------------------
--  Enforce the size cap by evicting lowest sampleCount entry
------------------------------------------------------------------------
function SpellFingerprints:_EnforceSizeCap()
    local count = 0
    local minKey, minSamples

    for k, fp in pairs(_db) do
        count = count + 1
        if not minKey or fp.sampleCount < minSamples then
            minKey     = k
            minSamples = fp.sampleCount
        end
    end

    if count >= KSBT.MAX_FINGERPRINTS and minKey then
        _db[minKey] = nil
    end
end

------------------------------------------------------------------------
--  Get the standard deviation from EMA variance
------------------------------------------------------------------------
function SpellFingerprints:GetDamageStdDev(fp)
    if not fp or fp.damageVar == 0 then return 0 end
    return math_sqrt(fp.damageVar)
end

function SpellFingerprints:GetDelayStdDev(fp)
    if not fp or fp.delayVar == 0 then return 0 end
    return math_sqrt(fp.delayVar)
end

------------------------------------------------------------------------
--  Check if a fingerprint is mature (enough samples for range scoring)
------------------------------------------------------------------------
function SpellFingerprints:IsMature(fp)
    return fp and fp.damageCount >= KSBT.FINGERPRINT_MATURITY
end

------------------------------------------------------------------------
--  Get crit ratio for a fingerprint
------------------------------------------------------------------------
function SpellFingerprints:GetCritRatio(fp)
    if not fp or fp.sampleCount == 0 then return 0.5 end  -- default 50%
    return fp.critCount / fp.sampleCount
end

------------------------------------------------------------------------
--  Reset all fingerprints (e.g., from slash command)
------------------------------------------------------------------------
function SpellFingerprints:Reset()
    _db = {}
    if KSBT_SpellFingerprints then
        KSBT_SpellFingerprints.fingerprints = _db
    end
end

------------------------------------------------------------------------
--  Get summary for /ksbt fingerprints command
------------------------------------------------------------------------
function SpellFingerprints:GetSummary()
    local lines = {}
    for key, fp in pairs(_db) do
        local avgStr = fp.damageAvg and string.format("%.0f", fp.damageAvg) or "?"
        local sdStr  = self:IsMature(fp)
            and string.format("%.0f", self:GetDamageStdDev(fp))
            or "immature"
        local schoolStr = fp.schoolMask and string.format("0x%X", fp.schoolMask) or "?"
        lines[#lines + 1] = string.format(
            "%s (#%d) — avg:%s sd:%s school:%s samples:%d crits:%d",
            fp.spellName, fp.spellId, avgStr, sdStr, schoolStr,
            fp.sampleCount, fp.critCount
        )
    end
    table.sort(lines)
    return lines
end
