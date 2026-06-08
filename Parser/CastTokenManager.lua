------------------------------------------------------------------------
-- Parser/CastTokenManager.lua
-- Kroth's Scrolling Battle Text - Cast-Consume Token Model
--
-- Maintains a FIFO pool of cast tokens minted by UNIT_SPELLCAST_SUCCEEDED.
-- Outgoing combat events (UNIT_COMBAT) consume tokens to confirm that the
-- hit was caused by the player's spell cast, not another source.
--
-- API:
--   CTM:PushToken(spellId, spellName, school)  -- call on spell cast
--   CTM:ConsumeToken(eventSchool)              -- call on combat event; returns token or nil
--   CTM:Reset()                                -- clears pool (used by tests / reload)
--
-- School matching rules (graceful degradation):
--   - nil token school  → accepts any event school
--   - nil event school  → accepted by any token school
--   - secret school     → treated as nil (accept any)
--   - equal schools     → match
--   - different schools → skip (token stays in pool for a future match)
--
-- Expired tokens are discarded lazily on PushToken and ConsumeToken.
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

KSBT.Parser = KSBT.Parser or {}
KSBT.Parser.CastTokenManager = KSBT.Parser.CastTokenManager or {}
local CTM = KSBT.Parser.CastTokenManager

local MAX_TOKENS = 8
local TOKEN_TTL  = 0.3   -- seconds (300 ms)

CTM._pool = CTM._pool or {}

------------------------------------------------------------------------
-- Time helper — honours _G._mockTime for unit tests.
------------------------------------------------------------------------
local function Now()
    if _G._mockTime ~= nil then return _G._mockTime end
    return GetTime and GetTime() or 0
end

local function IsSecretVal(v)
    return issecretvalue ~= nil and issecretvalue(v)
end

------------------------------------------------------------------------
-- Reset: clear all tokens.
------------------------------------------------------------------------
function CTM:Reset()
    self._pool = {}
end

------------------------------------------------------------------------
-- PushToken: mint a new token and append to the FIFO pool.
--
-- Runs lazy GC (discards expired tokens) then enforces the MAX_TOKENS
-- cap by evicting the oldest entry before inserting the new one.
------------------------------------------------------------------------
function CTM:PushToken(spellId, spellName, school)
    local now = Now()

    -- Lazy GC: discard expired tokens.
    local alive = {}
    for _, tok in ipairs(self._pool) do
        if (now - tok.time) <= TOKEN_TTL then
            alive[#alive + 1] = tok
        end
    end
    self._pool = alive

    -- Enforce pool cap: evict oldest when at or above limit.
    while #self._pool >= MAX_TOKENS do
        table.remove(self._pool, 1)
    end

    -- Normalize secret school values to nil (graceful degradation).
    local safeSchool = school
    if IsSecretVal(safeSchool) then safeSchool = nil end

    self._pool[#self._pool + 1] = {
        spellId   = spellId,
        spellName = spellName,
        school    = safeSchool,
        time      = now,
    }
end

------------------------------------------------------------------------
-- ConsumeToken: find and remove the oldest non-expired, school-matching
-- token from the FIFO pool. Returns the token table, or nil if no match.
--
-- Expired tokens encountered during the scan are discarded (lazy GC).
-- School-mismatched tokens are kept for a future matching consume call.
------------------------------------------------------------------------
function CTM:ConsumeToken(eventSchool)
    local now = Now()

    -- Normalize secret event school to nil.
    local safeEventSchool = eventSchool
    if IsSecretVal(safeEventSchool) then safeEventSchool = nil end

    local found   = nil
    local newPool = {}

    for _, tok in ipairs(self._pool) do
        if found then
            -- Match already found: preserve all remaining entries as-is.
            newPool[#newPool + 1] = tok
        elseif (now - tok.time) > TOKEN_TTL then
            -- Expired: discard silently (lazy GC on consume path).
        else
            local schoolMatch = (tok.school == nil)
                             or (safeEventSchool == nil)
                             or (tok.school == safeEventSchool)
            if schoolMatch then
                found = tok  -- consume this token; don't add to newPool
            else
                -- School mismatch: keep for a future matching consume.
                newPool[#newPool + 1] = tok
            end
        end
    end

    self._pool = newPool
    return found
end
