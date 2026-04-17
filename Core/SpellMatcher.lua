------------------------------------------------------------------------
--  Core/SpellMatcher.lua – Hybrid rule elimination + Bayesian scoring
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

local band        = bit.band
local math_abs    = math.abs
local math_max    = math.max
local math_sqrt   = math.sqrt
local issecretvalue = issecretvalue

-- ── Module ──────────────────────────────────────────────────
local SpellMatcher = {}
KSBT.SpellMatcher  = SpellMatcher

-- Forward references (set during Init)
local CastHistory
local Fingerprints
local DebugLog  -- will be set when DebugFrame loads

function SpellMatcher:Init()
    CastHistory  = KSBT.CastHistory
    Fingerprints = KSBT.SpellFingerprints
    DebugLog     = KSBT.DebugLog  -- may be nil if DebugFrame not loaded yet
end

------------------------------------------------------------------------
--  Debug logging helper (no-op if DebugFrame not available)
------------------------------------------------------------------------
local function Log(level, color, msg)
    if DebugLog then
        DebugLog:Add(level, color, msg)
    end
end

------------------------------------------------------------------------
--  Match a UNIT_COMBAT damage event to a spell
--
--  Returns: spellId, spellName, confidence  (or nil, nil, 0)
------------------------------------------------------------------------
function SpellMatcher:Match(amount, schoolMask, isCrit, isPeriodic, timestamp)
    -- Refresh DebugLog reference (lazy init)
    if not DebugLog then DebugLog = KSBT.DebugLog end

    -- Get candidates from cast history
    local candidates = CastHistory:GetCandidates(timestamp, Fingerprints)
    if #candidates == 0 then
        Log(1, "orange",
            string.format("No match: %s %s — 0 candidates (no recent casts)",
                tostring(amount),
                schoolMask and string.format("school:0x%X", schoolMask) or ""))
        return nil, nil, 0
    end

    -- ── Phase 1: Rule-Based Elimination ─────────────────────
    local survivors = {}

    for _, entry in ipairs(candidates) do
        local dominated = false

        -- School match (composite-aware)
        if schoolMask and entry.schoolMask then
            if band(schoolMask, entry.schoolMask) == 0 then
                dominated = true
            end
        end
        -- If either school is nil, skip this filter (don't eliminate)

        -- Periodic flag
        if not dominated then
            local fp = Fingerprints:Get(entry.spellId)
            if fp and fp.sampleCount > 0 then
                if isPeriodic and not fp.isPeriodic then
                    dominated = true
                elseif not isPeriodic and fp.isPeriodic then
                    dominated = true
                end
            end
        end

        if not dominated then
            survivors[#survivors + 1] = entry
        end
    end

    if #survivors == 0 then
        Log(1, "orange",
            string.format("No match: %s %s — 0 survivors after elimination (%d candidates checked)",
                tostring(amount),
                schoolMask and string.format("school:0x%X", schoolMask) or "",
                #candidates))
        return nil, nil, 0
    end

    -- Single survivor = automatic match
    if #survivors == 1 then
        local winner = survivors[1]
        CastHistory:MarkConsumed(winner)
        Log(1, "cyan",
            string.format("Matched → %s (sole survivor, auto-confidence)",
                winner.spellName))
        return winner.spellId, winner.spellName, 1.0
    end

    -- ── Phase 2: Bayesian Scoring ───────────────────────────
    local isSecretAmount = amount and issecretvalue and issecretvalue(amount)
    local scores = {}

    -- Determine weights (redistribute if secret amount)
    local wDamage, wTiming, wCrit, wOrder
    if isSecretAmount then
        -- Skip damage range, redistribute proportionally
        wDamage = 0
        local remaining = KSBT.WEIGHT_CAST_TIMING + KSBT.WEIGHT_CRIT_CONSISTENCY + KSBT.WEIGHT_CAST_ORDER
        local scale = 1.0 / remaining
        wTiming = KSBT.WEIGHT_CAST_TIMING     * scale
        wCrit   = KSBT.WEIGHT_CRIT_CONSISTENCY * scale
        wOrder  = KSBT.WEIGHT_CAST_ORDER       * scale
    else
        wDamage = KSBT.WEIGHT_DAMAGE_RANGE
        wTiming = KSBT.WEIGHT_CAST_TIMING
        wCrit   = KSBT.WEIGHT_CRIT_CONSISTENCY
        wOrder  = KSBT.WEIGHT_CAST_ORDER
    end

    -- Compute per-candidate scores
    local newestTimestamp = survivors[1].timestamp  -- already sorted newest first
    local oldestTimestamp = survivors[#survivors].timestamp
    local timeSpan = newestTimestamp - oldestTimestamp

    for i, entry in ipairs(survivors) do
        local fp = Fingerprints:Get(entry.spellId)
        local score = 0

        -- Signal 1: Damage range fit
        if wDamage > 0 and fp and Fingerprints:IsMature(fp) and fp.damageAvg then
            local stddev = Fingerprints:GetDamageStdDev(fp)
            local dist   = math_abs(amount - fp.damageAvg)
            local rangeFit = math_max(0, 1.0 - dist / (stddev + 1))
            score = score + wDamage * rangeFit
        elseif wDamage > 0 then
            -- No fingerprint data: neutral score (0.5)
            score = score + wDamage * 0.5
        end

        -- Signal 2: Cast-to-hit timing
        if fp and fp.avgCastToHitDelay then
            local delay    = timestamp - entry.timestamp
            local delaySD  = Fingerprints:GetDelayStdDev(fp)
            local dist     = math_abs(delay - fp.avgCastToHitDelay)
            local timeFit  = math_max(0, 1.0 - dist / (delaySD + 0.05))
            score = score + wTiming * timeFit
        else
            score = score + wTiming * 0.5  -- neutral
        end

        -- Signal 3: Crit consistency
        if fp and fp.sampleCount > 0 then
            local critRatio = Fingerprints:GetCritRatio(fp)
            local critFit
            if isCrit then
                critFit = critRatio  -- higher crit ratio = better fit for crit events
            else
                critFit = 1.0 - critRatio  -- lower crit ratio = better fit for non-crit
            end
            score = score + wCrit * critFit
        else
            score = score + wCrit * 0.5
        end

        -- Signal 4: Cast order (newer casts score higher)
        if timeSpan > 0 then
            local recency = (entry.timestamp - oldestTimestamp) / timeSpan
            score = score + wOrder * recency
        else
            score = score + wOrder * 0.5  -- all same timestamp
        end

        scores[i] = { entry = entry, score = score }
    end

    -- Sort by score descending
    table.sort(scores, function(a, b) return a.score > b.score end)

    local best   = scores[1]
    local runner = scores[2]
    local margin = best.score - (runner and runner.score or 0)

    -- Build debug string for match attempt
    local candidateStrs = {}
    for _, s in ipairs(scores) do
        candidateStrs[#candidateStrs + 1] = string.format("%s(%.2f)", s.entry.spellName, s.score)
    end
    Log(2, "yellow",
        string.format("Matching: %s %s — candidates: %s",
            tostring(amount),
            schoolMask and string.format("school:0x%X", schoolMask) or "",
            table.concat(candidateStrs, ", ")))

    -- Apply confidence rules
    if best.score >= KSBT.CONFIDENCE_THRESHOLD_MATCH
        and margin >= KSBT.CONFIDENCE_MARGIN_MATCH
    then
        CastHistory:MarkConsumed(best.entry)
        Log(1, "cyan",
            string.format("Matched → %s (confidence: %.2f, margin: %.2f)",
                best.entry.spellName, best.score, margin))
        return best.entry.spellId, best.entry.spellName, best.score
    else
        Log(1, "red",
            string.format("Rejected: best=%s(%.2f), margin=%.2f — below threshold %.2f/%.2f",
                best.entry.spellName, best.score, margin,
                KSBT.CONFIDENCE_THRESHOLD_MATCH, KSBT.CONFIDENCE_MARGIN_MATCH))
        return nil, nil, 0
    end
end
