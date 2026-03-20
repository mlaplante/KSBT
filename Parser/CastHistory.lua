------------------------------------------------------------------------
--  Parser/CastHistory.lua – Rolling buffer of recent spell casts
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

local GetTime     = GetTime
local C_Spell     = C_Spell
local pcall       = pcall

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
