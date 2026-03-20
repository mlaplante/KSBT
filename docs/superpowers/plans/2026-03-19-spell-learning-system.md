# Spell Learning System Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a hybrid spell-damage attribution system that learns spell fingerprints from confirmed CLEU events and uses rule elimination + Bayesian scoring to label unidentified UNIT_COMBAT damage events.

**Architecture:** Four new files (CastHistory, SpellFingerprints, SpellMatcher, DebugFrame) wired into the existing CombatLog_Detect.lua pipeline. Learning is additive — no existing behavior changes. Per-character persistence via SavedVariablesPerCharacter.

**Tech Stack:** WoW Lua (Ace3 framework), SavedVariablesPerCharacter, ScrollingMessageFrame widget

**Spec:** `docs/superpowers/specs/2026-03-19-spell-learning-system-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Core/Constants.lua` | Modify | Add spell learning constants (lines after 79) |
| `Parser/CastHistory.lua` | Create | Circular buffer of recent spell casts |
| `Core/SpellFingerprints.lua` | Create | Per-character spell profile database with EMA |
| `Core/SpellMatcher.lua` | Create | Two-phase hybrid matching engine |
| `UI/DebugFrame.lua` | Create | Scrollable diagnostic window |
| `Parser/CombatLog_Detect.lua` | Modify | Wire new systems into event pipeline |
| `Core/Init.lua` | Modify | Add slash commands, initialize new systems |
| `KBST.toc` | Modify | Add new files and SavedVariablesPerCharacter |

---

## Chunk 1: Foundation (Constants + Cast History)

### Task 1: Add Spell Learning Constants

**Files:**
- Modify: `Core/Constants.lua:79` (after school mask constants)

- [ ] **Step 1: Add constants to Constants.lua**

After line 79 (`KSBT.SCHOOL_ARCANE = 0x40`), add:

```lua
-- ── Spell Learning System ──────────────────────────────────
KSBT.CAST_HISTORY_SIZE      = 20     -- max entries in cast buffer
KSBT.CAST_EXPIRY_SECONDS    = 3.0    -- seconds before a cast expires
KSBT.FINGERPRINT_MATURITY   = 10     -- observations before damage range scoring
KSBT.CONFIDENCE_THRESHOLD_MATCH = 0.65  -- minimum score to label
KSBT.CONFIDENCE_MARGIN_MATCH    = 0.15  -- minimum gap vs runner-up
KSBT.EMA_ALPHA              = 0.1    -- EMA smoothing factor (after warmup)
KSBT.EMA_WARMUP_COUNT       = 5      -- use simple avg for first N samples
KSBT.MAX_FINGERPRINTS       = 200    -- max fingerprints per character
KSBT.SCHEMA_VERSION         = 1      -- fingerprint schema version

-- Bayesian signal weights
KSBT.WEIGHT_DAMAGE_RANGE    = 0.40
KSBT.WEIGHT_CAST_TIMING     = 0.30
KSBT.WEIGHT_CRIT_CONSISTENCY = 0.15
KSBT.WEIGHT_CAST_ORDER      = 0.15
```

- [ ] **Step 2: Commit**

```bash
git add Core/Constants.lua
git commit -m "feat(learning): add spell learning system constants"
```

---

### Task 2: Create Cast History Tracker

**Files:**
- Create: `Parser/CastHistory.lua`

- [ ] **Step 1: Create CastHistory.lua**

```lua
------------------------------------------------------------------------
--  Parser/CastHistory.lua – Rolling buffer of recent spell casts
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

local GetTime     = GetTime
local C_Spell     = C_Spell
local pcall       = pcall
local band        = bit.band

-- ── Module ──────────────────────────────────────────────────
local CastHistory = {}
KSBT.CastHistory  = CastHistory

local _buffer     = {}   -- circular buffer entries
local _head       = 0    -- next write index (1-based, wraps)
local _size       = 0    -- current number of valid entries

------------------------------------------------------------------------
--  Push a new cast into the buffer
--  Called from CombatLog_Detect on UNIT_SPELLCAST_SUCCEEDED / CHANNEL_START
------------------------------------------------------------------------
function CastHistory:Push(spellId, spellName, timestamp)
    if not spellId then return end

    -- Look up school mask (may be nil for some spells)
    local schoolMask
    local ok, info = pcall(C_Spell.GetSpellInfo, spellId)
    if ok and info then
        schoolMask = info.school  -- can be nil
    end

    local idx = (_head % KSBT.CAST_HISTORY_SIZE) + 1
    _buffer[idx] = {
        spellId    = spellId,
        spellName  = spellName or ("Spell#" .. spellId),
        timestamp  = timestamp,
        schoolMask = schoolMask,
        consumed   = 0,
    }
    _head = idx
    if _size < KSBT.CAST_HISTORY_SIZE then
        _size = _size + 1
    end
end

------------------------------------------------------------------------
--  Get all non-expired, non-consumed casts as candidates
--  Returns array of {entry, index} sorted by recency (newest first)
------------------------------------------------------------------------
function CastHistory:GetCandidates(now, fingerprints)
    local expiry = KSBT.CAST_EXPIRY_SECONDS
    local candidates = {}

    for i = 1, _size do
        local entry = _buffer[i]
        if entry and (now - entry.timestamp) <= expiry then
            -- Check consumed status
            local maxHits = 1
            if fingerprints then
                local fp = fingerprints:Get(entry.spellId)
                if fp and fp.maxHitsPerCast and fp.maxHitsPerCast > 1 then
                    maxHits = fp.maxHitsPerCast
                end
            end

            if entry.consumed < maxHits then
                candidates[#candidates + 1] = entry
            end
        end
    end

    -- Sort newest first (most recent cast = highest timestamp)
    table.sort(candidates, function(a, b)
        return a.timestamp > b.timestamp
    end)

    return candidates
end

------------------------------------------------------------------------
--  Find the most recent cast entry for a specific spellId
--  Used for computing cast-to-hit delay during CLEU learning
------------------------------------------------------------------------
function CastHistory:FindMostRecentCast(spellId, now)
    local expiry = KSBT.CAST_EXPIRY_SECONDS
    local best

    for i = 1, _size do
        local entry = _buffer[i]
        if entry
            and entry.spellId == spellId
            and (now - entry.timestamp) <= expiry
        then
            if not best or entry.timestamp > best.timestamp then
                best = entry
            end
        end
    end

    return best
end

------------------------------------------------------------------------
--  Mark a cast entry as consumed (increment hit count)
------------------------------------------------------------------------
function CastHistory:MarkConsumed(entry)
    if entry then
        entry.consumed = entry.consumed + 1
    end
end

------------------------------------------------------------------------
--  Clear the buffer (e.g., on spec change or reset)
------------------------------------------------------------------------
function CastHistory:Clear()
    _buffer = {}
    _head   = 0
    _size   = 0
end

------------------------------------------------------------------------
--  Debug: return current buffer size
------------------------------------------------------------------------
function CastHistory:GetSize()
    return _size
end
```

- [ ] **Step 2: Commit**

```bash
git add Parser/CastHistory.lua
git commit -m "feat(learning): add CastHistory rolling buffer"
```

---

## Chunk 2: Spell Fingerprint Database

### Task 3: Create SpellFingerprints Module

**Files:**
- Create: `Core/SpellFingerprints.lua`

- [ ] **Step 1: Create SpellFingerprints.lua**

```lua
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
```

- [ ] **Step 2: Commit**

```bash
git add Core/SpellFingerprints.lua
git commit -m "feat(learning): add SpellFingerprints database with EMA"
```

---

## Chunk 3: Spell Matcher

### Task 4: Create SpellMatcher Module

**Files:**
- Create: `Core/SpellMatcher.lua`

- [ ] **Step 1: Create SpellMatcher.lua**

```lua
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
```

- [ ] **Step 2: Commit**

```bash
git add Core/SpellMatcher.lua
git commit -m "feat(learning): add SpellMatcher hybrid engine"
```

---

## Chunk 4: Debug Frame

### Task 5: Create Debug Frame

**Files:**
- Create: `UI/DebugFrame.lua`

- [ ] **Step 1: Create DebugFrame.lua**

```lua
------------------------------------------------------------------------
--  UI/DebugFrame.lua – Scrollable diagnostic window for spell learning
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

-- ── Module ──────────────────────────────────────────────────
local DebugLog = {}
KSBT.DebugLog  = DebugLog

local _frame
local _scrollFrame
local _level = 0  -- debug level (0=off, 1-3 = increasing verbosity)

-- Color table: name → {r, g, b}
local COLORS = {
    green  = { 0.0, 1.0, 0.0 },
    yellow = { 1.0, 1.0, 0.0 },
    cyan   = { 0.0, 1.0, 1.0 },
    orange = { 1.0, 0.6, 0.0 },
    red    = { 1.0, 0.3, 0.3 },
    gray   = { 0.6, 0.6, 0.6 },
    white  = { 1.0, 1.0, 1.0 },
}

------------------------------------------------------------------------
--  Create the debug frame (lazy, called on first show)
------------------------------------------------------------------------
local function EnsureFrame()
    if _frame then return end

    -- Main frame
    local f = CreateFrame("Frame", "KSBTDebugFrame", UIParent, "BackdropTemplate")
    f:SetSize(500, 350)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:SetResizable(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(300, 200, 800, 600)
    end
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")

    -- Backdrop
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })

    -- Title bar drag region
    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetHeight(24)
    titleBar:SetPoint("TOPLEFT", 4, -4)
    titleBar:SetPoint("TOPRIGHT", -4, -4)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
    titleBar:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        DebugLog:SavePosition()
    end)

    -- Title text
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", 8, 0)
    title:SetText("KSBT Spell Learning Debug")
    title:SetTextColor(0.29, 0.62, 1.0)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Clear button
    local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearBtn:SetSize(60, 20)
    clearBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -4, -4)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function()
        if _scrollFrame then
            _scrollFrame:Clear()
        end
    end)

    -- Scrolling message frame
    local sf = CreateFrame("ScrollingMessageFrame", nil, f)
    sf:SetPoint("TOPLEFT", 8, -32)
    sf:SetPoint("BOTTOMRIGHT", -28, 8)
    sf:SetFontObject(GameFontNormalSmall)
    sf:SetJustifyH("LEFT")
    sf:SetMaxLines(KSBT.DIAG_MAX_ENTRIES or 1000)
    sf:SetFading(false)
    sf:SetInsertMode("BOTTOM")
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then
            self:ScrollUp()
        else
            self:ScrollDown()
        end
    end)

    -- Resize grip
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        DebugLog:SavePosition()
    end)

    _frame       = f
    _scrollFrame = sf

    -- Restore saved position
    DebugLog:RestorePosition()

    f:Hide()
end

------------------------------------------------------------------------
--  Add a message to the debug frame
--  level: minimum debug level for this message (1-3)
--  color: "green", "yellow", "cyan", "orange", "red", "gray"
--  msg:   the text string
------------------------------------------------------------------------
function DebugLog:Add(level, color, msg)
    if _level < level then return end
    if not _scrollFrame then return end

    local c = COLORS[color] or COLORS.white
    local timestamp = date("%H:%M:%S")
    _scrollFrame:AddMessage(
        string.format("|cff888888%s|r %s", timestamp, msg),
        c[1], c[2], c[3]
    )
end

------------------------------------------------------------------------
--  Toggle visibility
------------------------------------------------------------------------
function DebugLog:Toggle()
    EnsureFrame()
    if _frame:IsShown() then
        _frame:Hide()
    else
        _frame:Show()
    end
end

------------------------------------------------------------------------
--  Set debug level
------------------------------------------------------------------------
function DebugLog:SetLevel(level)
    _level = tonumber(level) or 0
    if _level < 0 then _level = 0 end
    if _level > 3 then _level = 3 end
    print("|cFF4A9EFFKSBT|r Debug level set to " .. _level)
end

function DebugLog:GetLevel()
    return _level
end

------------------------------------------------------------------------
--  Position persistence (uses KSBT_SpellFingerprints.debugFramePos)
------------------------------------------------------------------------
function DebugLog:SavePosition()
    if not _frame then return end
    KSBT_SpellFingerprints = KSBT_SpellFingerprints or {}
    local point, _, relPoint, x, y = _frame:GetPoint()
    local w, h = _frame:GetSize()
    KSBT_SpellFingerprints.debugFramePos = {
        point = point, relPoint = relPoint,
        x = x, y = y, w = w, h = h,
    }
end

function DebugLog:RestorePosition()
    if not _frame then return end
    KSBT_SpellFingerprints = KSBT_SpellFingerprints or {}
    local pos = KSBT_SpellFingerprints.debugFramePos
    if pos then
        _frame:ClearAllPoints()
        _frame:SetPoint(pos.point or "CENTER", UIParent, pos.relPoint or "CENTER",
            pos.x or 0, pos.y or 0)
        if pos.w and pos.h then
            _frame:SetSize(pos.w, pos.h)
        end
    end
end
```

- [ ] **Step 2: Commit**

```bash
git add UI/DebugFrame.lua
git commit -m "feat(learning): add DebugFrame diagnostic window"
```

---

## Chunk 5: Pipeline Integration

### Task 6: Update TOC File

**Files:**
- Modify: `KBST.toc`

- [ ] **Step 1: Add SavedVariablesPerCharacter line**

In `KBST.toc`, after line 6 (`## SavedVariables: KrothSBTDB`), add:

```
## SavedVariablesPerCharacter: KSBT_SpellFingerprints
```

- [ ] **Step 2: Add new files to load order**

After the line `Core\Diagnostics.lua`, add:

```
Core\SpellFingerprints.lua
Core\SpellMatcher.lua
```

After the line `Parser\Normalize.lua` (before `Parser\CombatLog_Detect.lua`), add:

```
Parser\CastHistory.lua
```

After the last line `UI\ScrollAreaFrames.lua`, add:

```
UI\DebugFrame.lua
```

Note: Use content anchors, not line numbers, since earlier insertions shift subsequent lines.

The final TOC should have this structure:
```
## SavedVariables: KrothSBTDB
## SavedVariablesPerCharacter: KSBT_SpellFingerprints

...
Core\Diagnostics.lua
Core\SpellFingerprints.lua
Core\SpellMatcher.lua

...
Parser\Normalize.lua
Parser\CastHistory.lua
Parser\CombatLog_Detect.lua

...
UI\ScrollAreaFrames.lua
UI\DebugFrame.lua
```

- [ ] **Step 3: Commit**

```bash
git add KBST.toc
git commit -m "feat(learning): add new files and SavedVariablesPerCharacter to TOC"
```

---

### Task 7: Wire Cast History into CombatLog_Detect.lua

**Files:**
- Modify: `Parser/CombatLog_Detect.lua:107-109` (replace last-cast vars)
- Modify: `Parser/CombatLog_Detect.lua:358-363` (replace HandleSpellcastSucceeded)
- Modify: `Parser/CombatLog_Detect.lua:332-336` (replace UNIT_COMBAT spell attachment)
- Modify: `Parser/CombatLog_Detect.lua:435` (add UNIT_SPELLCAST_CHANNEL_START registration)

- [ ] **Step 1: Remove _lastCast variables AND replace their usage in UNIT_COMBAT handler (atomic)**

At lines 107-109, remove the old variables:
```lua
local _lastCastSpellId   = nil
local _lastCastSpellName = nil
local _lastCastTime      = 0
```

Replace with:
```lua
-- Cast history is managed by KSBT.CastHistory (Parser/CastHistory.lua)
-- Legacy single-cast tracking removed in favor of rolling buffer
```

**In the same step**, at lines 332-336, replace the old spell attachment:
```lua
if _lastCastSpellId and (now - _lastCastTime) < 1.5 then
    evt.spellId   = _lastCastSpellId
    evt.spellName = _lastCastSpellName
end
```

With the SpellMatcher call:
```lua
-- Attempt spell attribution via learning system
if not evt.spellId then
    local matchId, matchName, confidence = KSBT.SpellMatcher:Match(
        evt.amount, evt.schoolMask, evt.isCrit, evt.isPeriodic, now)
    if matchId then
        evt.spellId   = matchId
        evt.spellName = matchName
    end
end
```

Both changes must be made together since removing the variables without updating their usage would break the addon.

- [ ] **Step 2: Update HandleSpellcastSucceeded to push to CastHistory**

At lines 358-363, the current handler is:
```lua
local function HandleSpellcastSucceeded(unit, _, spellId)
    if unit ~= "player" then return end
    _lastCastSpellId   = spellId
    _lastCastSpellName = SpellNameForId(spellId)
    _lastCastTime      = GetTime()
end
```

Replace with:
```lua
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
```

- [ ] **Step 3: Add channel start handler**

After the updated `HandleSpellcastSucceeded` function, add:
```lua
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
```

- [ ] **Step 4: Update _spellFrame OnEvent handler and register UNIT_SPELLCAST_CHANNEL_START**

The current `_spellFrame` handler at line 393 does not capture the event name:
```lua
_spellFrame:SetScript("OnEvent", function(_, _, unit, _, spellId)
    if CombatLog._enabled then
        pcall(HandleSpellcastSucceeded, unit, nil, spellId)
    end
end)
```

Replace with a dispatch that handles both events:
```lua
_spellFrame:SetScript("OnEvent", function(_, event, unit, _, spellId)
    if not CombatLog._enabled then return end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        pcall(HandleSpellcastSucceeded, unit, nil, spellId)
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        pcall(HandleChannelStart, unit, nil, spellId)
    end
end)
```

In `TryRegisterSpellcast()` (around line 431), after the `UNIT_SPELLCAST_SUCCEEDED` registration, also register channel start:
```lua
local ok = pcall(function()
    if _spellFrame.RegisterUnitEvent then
        _spellFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
        _spellFrame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
    else
        _spellFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        _spellFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    end
end)
```

- [ ] **Step 6: Commit**

```bash
git add Parser/CombatLog_Detect.lua
git commit -m "feat(learning): wire CastHistory and SpellMatcher into CombatLog_Detect"
```

---

### Task 8: Wire Fingerprint Learning into CLEU Handler

**Files:**
- Modify: `Parser/CombatLog_Detect.lua:179-216` (SPELL_DAMAGE event block)

- [ ] **Step 1: Add fingerprint recording after outgoing SPELL_DAMAGE events**

In the SPELL_DAMAGE handler block (around line 185, after `EmitOutgoing(evt)` is called for outgoing events), add the fingerprint recording call:

```lua
-- Record observation for spell learning
if KSBT.SpellFingerprints then
    local castDelay
    local castEntry = KSBT.CastHistory:FindMostRecentCast(spellId, now)
    if castEntry then
        castDelay = now - castEntry.timestamp
    end
    KSBT.SpellFingerprints:RecordObservation(
        spellId, spellName, amount, isCrit, isPeriodic, schoolMask, castDelay)

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
```

This should be added for outgoing SPELL_DAMAGE, RANGE_DAMAGE, and SPELL_PERIODIC_DAMAGE events only (not heals, not incoming).

- [ ] **Step 2: Commit**

```bash
git add Parser/CombatLog_Detect.lua
git commit -m "feat(learning): record fingerprint observations from CLEU events"
```

---

### Task 9: Add Slash Commands and Initialization

**Files:**
- Modify: `Core/Init.lua:34-84` (OnInitialize — add fingerprint loading)
- Modify: `Core/Init.lua:146-199` (HandleSlashCommand — add new commands)

- [ ] **Step 1: Initialize SpellFingerprints and SpellMatcher in OnInitialize**

In `OnInitialize()` (around line 82, before the print statement), add:

```lua
-- Initialize spell learning system
if KSBT.SpellFingerprints then
    KSBT.SpellFingerprints:Load()
end
if KSBT.SpellMatcher then
    KSBT.SpellMatcher:Init()
end
```

- [ ] **Step 2: Add slash commands to HandleSlashCommand**

In `HandleSlashCommand` (around line 191, after the `probeout` branch), add these new command branches:

```lua
elseif cmd == "debugframe" then
    if KSBT.DebugLog then
        KSBT.DebugLog:Toggle()
    else
        print("|cFF4A9EFFKSBT|r Debug frame not available")
    end

elseif cmd == "debuglevel" then
    if KSBT.DebugLog then
        KSBT.DebugLog:SetLevel(rest)
    else
        print("|cFF4A9EFFKSBT|r Debug frame not available")
    end

elseif cmd == "fingerprints" then
    if KSBT.SpellFingerprints then
        local lines = KSBT.SpellFingerprints:GetSummary()
        if #lines == 0 then
            print("|cFF4A9EFFKSBT|r No fingerprints recorded yet.")
        else
            -- Output to debug frame if available, else to chat
            if KSBT.DebugLog then
                KSBT.DebugLog:Toggle()  -- ensure visible
                for _, line in ipairs(lines) do
                    KSBT.DebugLog:Add(0, "white", line)
                end
            else
                for _, line in ipairs(lines) do
                    print("|cFF4A9EFFKSBT|r " .. line)
                end
            end
        end
    end

elseif cmd == "resetfingerprints" then
    if KSBT.SpellFingerprints then
        KSBT.SpellFingerprints:Reset()
        print("|cFF4A9EFFKSBT|r Fingerprints reset.")
    end
```

- [ ] **Step 3: Update usage help text**

At lines 201-205 of Init.lua, update the help text to include new commands. After the existing `probeout` line, add:

```lua
    self:Print("  debugframe               — toggle spell learning debug window")
    self:Print("  debuglevel [0-3]         — set spell learning debug verbosity")
    self:Print("  fingerprints             — dump learned spell profiles")
    self:Print("  resetfingerprints        — clear all learned spell data")
```

- [ ] **Step 4: Commit**

```bash
git add Core/Init.lua
git commit -m "feat(learning): add slash commands and initialization for spell learning"
```

---

## Chunk 6: Final Verification

### Task 10: Verify File Structure and Load Order

- [ ] **Step 1: Verify all new files exist**

```bash
ls -la Parser/CastHistory.lua Core/SpellFingerprints.lua Core/SpellMatcher.lua UI/DebugFrame.lua
```

Expected: all four files present.

- [ ] **Step 2: Verify TOC has all entries**

Read `KBST.toc` and confirm:
- `## SavedVariablesPerCharacter: KSBT_SpellFingerprints` is present
- `Parser\CastHistory.lua` appears before `Parser\CombatLog_Detect.lua`
- `Core\SpellFingerprints.lua` and `Core\SpellMatcher.lua` appear after `Core\Diagnostics.lua`
- `UI\DebugFrame.lua` appears after `UI\ScrollAreaFrames.lua`

- [ ] **Step 3: Verify no Lua syntax errors**

```bash
# If luacheck is available:
luacheck Parser/CastHistory.lua Core/SpellFingerprints.lua Core/SpellMatcher.lua UI/DebugFrame.lua --no-global --no-unused
```

- [ ] **Step 4: Final commit with all changes**

Review `git status` and `git diff` to ensure everything is clean and committed.

```bash
git status
```
