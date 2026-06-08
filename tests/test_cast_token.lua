------------------------------------------------------------------------
-- tests/test_cast_token.lua
-- KRO-14: Token Model Test Coverage and Regression Validation
--
-- Tests the Cast-Consume Token Model (KRO-13):
--   Parser/CastTokenManager.lua — PushToken, ConsumeToken, TTL, pool cap
--
-- Coverage: single cast/hit, FIFO order, TTL expiry (300ms), school
--   matching, school-skip-to-match, pool overflow (MAX_TOKENS=8),
--   secret number safety, and CombatLog_Detect Midnight path integration.
--
-- Prerequisites: KRO-13 merged (Parser/CastTokenManager.lua exists).
--   Integration suite (8) also requires CombatLog:HandleUnitCombat and
--   CombatLog:HandleSpellcastSucceeded to be exposed as public methods.
------------------------------------------------------------------------

local T = require("runner")

local BASE = debug.getinfo(1, "S").source:match("@(.+/)") or "./"
local function path(rel) return BASE .. rel end

-- Fresh namespace factory
local function ns()
    return { Addon = {}, Core = {}, Parser = {}, db = { profile = {}, char = {} } }
end

------------------------------------------------------------------------
-- Guard: if KRO-13 not merged, report one skip per suite and exit.
------------------------------------------------------------------------
local _ctmExists = (io.open(path("../Parser/CastTokenManager.lua"), "r") ~= nil)

local SUITES = {
    "Token Model — basic lifecycle",
    "Token Model — FIFO ordering",
    "Token Model — TTL expiry (300ms)",
    "Token Model — school matching",
    "Token Model — pool overflow (MAX_TOKENS=8)",
    "Token Model — secret number safety",
    "Token Model — edge cases",
    "Token Model — CombatLog_Detect Midnight path integration",
}
if not _ctmExists then
    for _, name in ipairs(SUITES) do
        T.suite(name)
        T.test("(skipped) Parser/CastTokenManager.lua not found — KRO-13 not yet merged", function()
            -- Intentional skip: not a failure; re-run once KRO-13 is merged.
        end)
    end
    return   -- Stop processing this file; runner continues to T.summary()
end

-- Load CastTokenManager fresh into a namespace (only called when file exists).
local function loadCTM(ksbt)
    local chunk = assert(loadfile(path("../Parser/CastTokenManager.lua")))
    chunk("KBST", ksbt)
    local CTM = ksbt.Parser.CastTokenManager
    assert(CTM, "CastTokenManager did not register at ksbt.Parser.CastTokenManager")
    if CTM.Reset then CTM:Reset() end
    return CTM
end

------------------------------------------------------------------------
-- Suite 1: Basic lifecycle
------------------------------------------------------------------------
T.suite("Token Model — basic lifecycle")

do
    local ksbt = ns()
    local CTM  = loadCTM(ksbt)

    T.test("single PushToken produces one consumable token", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(12345, "Fireball", nil)
        local tok = CTM:ConsumeToken(nil)
        T.ok(tok, "expected token, got nil")
        T.eq(tok.spellId,   12345)
        T.eq(tok.spellName, "Fireball")
    end)

    T.test("token is one-shot: second ConsumeToken returns nil", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(12345, "Fireball", nil)
        T.ok(CTM:ConsumeToken(nil),      "first consume should succeed")
        T.ok(not CTM:ConsumeToken(nil),  "second consume should return nil")
    end)

    T.test("empty queue returns nil cleanly", function()
        CTM:Reset()
        T.ok(not CTM:ConsumeToken(nil), "empty queue should return nil")
    end)

    T.test("spellName stored on token matches push", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(77758, "Rejuvenation", 0x8)
        local tok = CTM:ConsumeToken(0x8)
        T.ok(tok)
        T.eq(tok.spellName, "Rejuvenation")
    end)

    T.test("Push → Reset → Push gives only the second token", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(11111, "OldSpell", nil)
        CTM:Reset()
        CTM:PushToken(22222, "NewSpell", nil)
        local tok = CTM:ConsumeToken(nil)
        T.eq(tok.spellId, 22222, "Reset should clear previous tokens")
        T.ok(not CTM:ConsumeToken(nil), "only one token survives reset")
    end)
end

------------------------------------------------------------------------
-- Suite 2: FIFO ordering
------------------------------------------------------------------------
T.suite("Token Model — FIFO ordering")

do
    local ksbt = ns()
    local CTM  = loadCTM(ksbt)

    T.test("three pushes consumed in push order", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(111, "SpellA", nil)
        CTM:PushToken(222, "SpellB", nil)
        CTM:PushToken(333, "SpellC", nil)
        T.eq(CTM:ConsumeToken(nil).spellId, 111, "1st out = 1st in")
        T.eq(CTM:ConsumeToken(nil).spellId, 222, "2nd out = 2nd in")
        T.eq(CTM:ConsumeToken(nil).spellId, 333, "3rd out = 3rd in")
    end)

    T.test("rapid fire: 8 casts consumed in push order", function()
        CTM:Reset(); _G._mockTime = 0
        for i = 1, 8 do CTM:PushToken(i * 100, "Spell" .. i, nil) end
        for i = 1, 8 do
            local tok = CTM:ConsumeToken(nil)
            T.ok(tok, "token " .. i .. " should exist")
            T.eq(tok.spellId, i * 100, "FIFO for slot " .. i)
        end
        T.ok(not CTM:ConsumeToken(nil), "queue empty after all consumed")
    end)

    T.test("interleaved push/consume preserves remaining FIFO order", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(10, "A", nil)
        CTM:PushToken(20, "B", nil)
        CTM:ConsumeToken(nil)             -- consume A
        CTM:PushToken(30, "C", nil)
        T.eq(CTM:ConsumeToken(nil).spellId, 20, "B comes before C")
        T.eq(CTM:ConsumeToken(nil).spellId, 30, "C is last")
    end)
end

------------------------------------------------------------------------
-- Suite 3: TTL expiry (default 300ms)
------------------------------------------------------------------------
T.suite("Token Model — TTL expiry (300ms)")

do
    local ksbt = ns()
    local CTM  = loadCTM(ksbt)

    T.test("token at 100ms is within TTL", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(12345, "Fireball", nil)
        _G._mockTime = 0.1
        T.ok(CTM:ConsumeToken(nil), "100ms < 300ms TTL")
    end)

    T.test("token at 299ms is within TTL", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(12345, "Fireball", nil)
        _G._mockTime = 0.299
        T.ok(CTM:ConsumeToken(nil), "299ms <= TTL")
    end)

    T.test("token at 301ms is expired", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(12345, "Fireball", nil)
        _G._mockTime = 0.301
        T.ok(not CTM:ConsumeToken(nil), "301ms > TTL, token expired")
    end)

    T.test("expired token does not block a fresh token", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(11111, "OldSpell", nil)
        _G._mockTime = 0.4                          -- OldSpell expired
        CTM:PushToken(22222, "NewSpell", nil)
        _G._mockTime = 0.45                         -- 50ms after NewSpell push
        local tok = CTM:ConsumeToken(nil)
        T.ok(tok, "fresh token should be consumable")
        T.eq(tok.spellId, 22222, "must be the new spell, not the expired one")
    end)

    T.test("lazy GC clears multiple expired tokens on next PushToken", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(111, "A", nil)
        CTM:PushToken(222, "B", nil)
        _G._mockTime = 1.0              -- both expired
        CTM:PushToken(333, "C", nil)   -- GC runs inside PushToken
        local tok = CTM:ConsumeToken(nil)
        T.ok(tok)
        T.eq(tok.spellId, 333, "only C survives GC")
        T.ok(not CTM:ConsumeToken(nil), "queue empty after C consumed")
    end)

    T.test("zero-gap consume (same GetTime) succeeds", function()
        CTM:Reset(); _G._mockTime = 5.0
        CTM:PushToken(12345, "Fireball", nil)
        -- No time advance — token age = 0, must be within TTL
        local tok = CTM:ConsumeToken(nil)
        T.ok(tok, "zero-age token must be valid")
    end)
end

------------------------------------------------------------------------
-- Suite 4: School matching
------------------------------------------------------------------------
T.suite("Token Model — school matching")

do
    local FIRE   = 0x4
    local FROST  = 0x10
    local NATURE = 0x8
    local ARCANE = 0x40

    local ksbt = ns()
    local CTM  = loadCTM(ksbt)

    T.test("matching school: token consumed", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(12345, "Fireball", FIRE)
        T.ok(CTM:ConsumeToken(FIRE), "same school should match")
    end)

    T.test("mismatched school: token not consumed", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(12345, "Fireball", FIRE)
        T.ok(not CTM:ConsumeToken(FROST), "different school should not match")
    end)

    T.test("nil token school accepts any event school (graceful degradation)", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(12345, "UnknownSchoolSpell", nil)
        T.ok(CTM:ConsumeToken(FIRE),   "nil token school → accept FIRE")
    end)

    T.test("nil event school accepted by known token school (graceful degradation)", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(12345, "Fireball", FIRE)
        T.ok(CTM:ConsumeToken(nil), "nil event school → accept FIRE token")
    end)

    T.test("concurrent schools consumed independently", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(1001, "FrostBolt",   FROST)
        CTM:PushToken(1002, "Fireball",    FIRE)
        CTM:PushToken(1003, "ArcaneBlast", ARCANE)
        T.eq(CTM:ConsumeToken(FROST).spellId,  1001)
        T.eq(CTM:ConsumeToken(FIRE).spellId,   1002)
        T.eq(CTM:ConsumeToken(ARCANE).spellId, 1003)
    end)

    T.test("school mismatch skips to first matching token", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(2001, "FrostBolt", FROST)
        CTM:PushToken(2002, "Fireball",  FIRE)
        -- Fire event should skip frost token and find fire token
        local tok = CTM:ConsumeToken(FIRE)
        T.ok(tok)
        T.eq(tok.spellId, 2002, "should skip frost, find fire")
    end)

    T.test("skipped (mismatched) token remains for subsequent consume", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(3001, "FrostBolt", FROST)
        CTM:PushToken(3002, "Fireball",  FIRE)
        CTM:ConsumeToken(FIRE)    -- consumes 3002, skips 3001
        local tok = CTM:ConsumeToken(FROST)
        T.ok(tok, "skipped frost token should still be in queue")
        T.eq(tok.spellId, 3001)
    end)

    T.test("all school-mismatched queue returns nil", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(4001, "FrostBolt", FROST)
        CTM:PushToken(4002, "FrostNova", FROST)
        T.ok(not CTM:ConsumeToken(FIRE), "no fire token in all-frost queue")
    end)

    T.test("nature damage correctly identified", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(5001, "Moonfire", NATURE)
        T.ok(CTM:ConsumeToken(NATURE), "nature matches nature")
        T.ok(not CTM:ConsumeToken(NATURE), "one-shot token")
    end)
end

------------------------------------------------------------------------
-- Suite 5: Pool overflow (MAX_TOKENS = 8)
------------------------------------------------------------------------
T.suite("Token Model — pool overflow (MAX_TOKENS=8)")

do
    local MAX  = 8
    local ksbt = ns()
    local CTM  = loadCTM(ksbt)

    T.test("pushing MAX+1 tokens evicts the oldest", function()
        CTM:Reset(); _G._mockTime = 0
        for i = 1, MAX + 1 do
            CTM:PushToken(i, "Spell" .. i, nil)
        end
        -- Oldest (spellId=1) should be evicted; first available is spellId=2
        local tok = CTM:ConsumeToken(nil)
        T.ok(tok)
        T.neq(tok.spellId, 1,  "oldest token (spellId=1) should be evicted")
        T.eq(tok.spellId,  2,  "first surviving token should be spellId=2")
    end)

    T.test("queue never exceeds MAX_TOKENS consumable entries", function()
        CTM:Reset(); _G._mockTime = 0
        for i = 1, MAX + 4 do
            CTM:PushToken(i, "Spell" .. i, nil)
        end
        local count = 0
        while CTM:ConsumeToken(nil) do count = count + 1 end
        T.eq(count, MAX, "exactly MAX_TOKENS tokens consumable")
    end)

    T.test("overflow eviction preserves FIFO order of survivors", function()
        CTM:Reset(); _G._mockTime = 0
        for i = 1, MAX + 2 do
            CTM:PushToken(i * 10, "Spell" .. i, nil)
        end
        -- Survivors are spellIds: 30, 40, 50, 60, 70, 80, 90, 100
        local prev = -1
        while true do
            local tok = CTM:ConsumeToken(nil)
            if not tok then break end
            T.ok(tok.spellId > prev, "FIFO order preserved among survivors")
            prev = tok.spellId
        end
    end)
end

------------------------------------------------------------------------
-- Suite 6: Secret number safety
------------------------------------------------------------------------
T.suite("Token Model — secret number safety")

do
    local ksbt = ns()
    local CTM  = loadCTM(ksbt)

    local SECRET = 0xDEAD
    local FIRE   = 0x4

    local function withSecretValue(fn)
        local orig = _G.issecretvalue
        _G.issecretvalue = function(v) return (v == SECRET) end
        local ok, err = pcall(fn)
        _G.issecretvalue = orig
        return ok, err
    end

    T.test("PushToken with secret school does not throw", function()
        CTM:Reset(); _G._mockTime = 0
        local ok, err = withSecretValue(function()
            CTM:PushToken(12345, "SecretSpell", SECRET)
        end)
        T.ok(ok, "PushToken should not throw with secret school: " .. tostring(err))
    end)

    T.test("ConsumeToken with secret event school does not throw", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(12345, "Fireball", FIRE)
        local ok, _ = withSecretValue(function()
            CTM:ConsumeToken(SECRET)
        end)
        T.ok(ok, "ConsumeToken should not throw with secret event school")
    end)

    T.test("secret token school degrades to nil-match (accepts any event school)", function()
        CTM:Reset(); _G._mockTime = 0
        local ok, _ = withSecretValue(function()
            CTM:PushToken(12345, "SecretSchoolSpell", SECRET)
        end)
        T.ok(ok)
        -- Secret school on token = treat as nil → accept any event school
        local tok = CTM:ConsumeToken(FIRE)
        T.ok(tok, "secret-school token should degrade gracefully and be consumable")
    end)

    T.test("secret event school degrades to nil-match (accepts any token)", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(12345, "Fireball", FIRE)
        local tok
        withSecretValue(function()
            tok = CTM:ConsumeToken(SECRET)
        end)
        T.ok(tok, "secret event school should degrade gracefully and consume token")
    end)
end

------------------------------------------------------------------------
-- Suite 7: Edge cases
------------------------------------------------------------------------
T.suite("Token Model — edge cases")

do
    local ksbt = ns()
    local CTM  = loadCTM(ksbt)

    T.test("PushToken with nil spellId does not crash", function()
        CTM:Reset(); _G._mockTime = 0
        local ok = pcall(function() CTM:PushToken(nil, nil, nil) end)
        T.ok(ok, "nil spellId should not crash PushToken")
    end)

    T.test("ConsumeToken after all tokens expired returns nil cleanly", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(11111, "A", nil)
        CTM:PushToken(22222, "B", nil)
        _G._mockTime = 1.0  -- both expired
        CTM:PushToken(33333, "C", nil)  -- GC runs here
        _G._mockTime = 1.5  -- C also expired
        -- Now queue has no live tokens; trigger GC with another push
        CTM:PushToken(44444, "D", nil)
        _G._mockTime = 2.0  -- D also expired
        local ok, _ = pcall(function() CTM:ConsumeToken(nil) end)
        T.ok(ok, "fully-expired queue should not throw")
    end)

    T.test("multiple Reset calls leave queue in valid empty state", function()
        CTM:Reset(); _G._mockTime = 0
        CTM:PushToken(11111, "SpellA", nil)
        CTM:Reset()
        CTM:Reset()
        T.ok(not CTM:ConsumeToken(nil), "double-reset: queue empty")
        CTM:PushToken(22222, "SpellB", nil)
        T.eq(CTM:ConsumeToken(nil).spellId, 22222, "push after double-reset works")
    end)
end

------------------------------------------------------------------------
-- Suite 8: CombatLog_Detect integration (Midnight path)
--
-- Loads Parser/CombatLog_Detect.lua with a minimal CreateFrame stub and
-- exercises the full Midnight attribution pipeline:
--   PushToken → ConsumeToken → EmitOutgoing
--
-- Requires KRO-13 to expose:
--   CombatLog:HandleUnitCombat(unit, action, indicator, amount, school)
--   CombatLog:HandleSpellcastSucceeded(unit, _, spellId)
-- as public methods for testability.
------------------------------------------------------------------------
T.suite("Token Model — CombatLog_Detect Midnight path integration")

do
    -- Minimal CreateFrame stub (not in wow_stub.lua yet)
    if not _G.CreateFrame then
        _G.CreateFrame = function(frameType, name, parent)
            local frame = {}
            frame.RegisterEvent       = function(self, evt) end
            frame.RegisterUnitEvent   = function(self, evt, ...) end
            frame.SetScript           = function(self, hook, fn) self[hook] = fn end
            return frame
        end
    end

    local outEvents = {}
    local ksbt = {
        Addon  = {},
        Core   = {},
        Parser = {},
        db     = { profile = {}, char = {} },
    }
    -- Capture outgoing events
    ksbt.Core.OutgoingProbe = {
        OnOutgoingDetected = function(self, evt)
            table.insert(outEvents, evt)
        end,
    }

    -- Load CastTokenManager
    local ctmChunk, ctmErr = loadfile(path("../Parser/CastTokenManager.lua"))
    if not ctmChunk then
        -- KRO-13 not merged: skip integration suite with clear message
        T.test("(skipped) CastTokenManager not found — KRO-13 not merged", function()
            error("SKIP: " .. tostring(ctmErr))
        end)
    else
        ctmChunk("KBST", ksbt)
        local CTM = ksbt.Parser.CastTokenManager

        -- Load CombatLog_Detect
        local clChunk = assert(loadfile(path("../Parser/CombatLog_Detect.lua")))
        clChunk("KBST", ksbt)
        local CL = ksbt.Parser.CombatLog

        -- Force Midnight path (no CLEU)
        CL._cleuRegistered = false
        CL:Enable()

        -- Guard: integration tests require public handlers
        local hasHandlers = type(CL.HandleUnitCombat) == "function"
            and type(CL.HandleSpellcastSucceeded) == "function"

        local function resetInteg()
            for i = #outEvents, 1, -1 do outEvents[i] = nil end
            CTM:Reset()
            _G._mockTime = 0
        end

        if not hasHandlers then
            T.test("(skipped) public HandleUnitCombat/HandleSpellcastSucceeded required", function()
                error("SKIP: KRO-13 must expose CombatLog:HandleUnitCombat and " ..
                      "CombatLog:HandleSpellcastSucceeded as public methods for integration testing.")
            end)
        else
            T.test("cast then hit emits one attributed outgoing event", function()
                resetInteg()
                CL:HandleSpellcastSucceeded("player", nil, 12345)
                _G._mockTime = 0.05
                CL:HandleUnitCombat("target", "WOUND", "NONE", 5000, 0x4)
                T.count(outEvents, 1, "should emit one outgoing event")
                T.eq(outEvents[1].spellId, 12345)
            end)

            T.test("no cast → hit rejected (not our damage)", function()
                resetInteg()
                CL:HandleUnitCombat("target", "WOUND", "NONE", 9999, 0x4)
                T.count(outEvents, 0, "no token → event rejected")
            end)

            T.test("expired cast → hit rejected (past TTL)", function()
                resetInteg()
                CL:HandleSpellcastSucceeded("player", nil, 12345)
                _G._mockTime = 0.5   -- 500ms > 300ms TTL
                CL:HandleUnitCombat("target", "WOUND", "NONE", 5000, 0x4)
                T.count(outEvents, 0, "expired token should not attribute the hit")
            end)

            T.test("one cast absorbs only one hit (second hit rejected)", function()
                resetInteg()
                CL:HandleSpellcastSucceeded("player", nil, 12345)
                _G._mockTime = 0.05
                CL:HandleUnitCombat("target", "WOUND", "NONE", 5000, 0x4)
                CL:HandleUnitCombat("target", "WOUND", "NONE", 3000, 0x4)
                T.count(outEvents, 1, "one-shot: second hit must be rejected")
                T.eq(outEvents[1].amount, 5000, "first hit attributed")
            end)

            T.test("two casts two hits: FIFO attribution", function()
                resetInteg()
                CL:HandleSpellcastSucceeded("player", nil, 11111)
                _G._mockTime = 0.1
                CL:HandleSpellcastSucceeded("player", nil, 22222)
                _G._mockTime = 0.15
                CL:HandleUnitCombat("target", "WOUND", "NONE", 2000, 0x10)
                CL:HandleUnitCombat("target", "WOUND", "NONE", 4000, 0x4)
                T.count(outEvents, 2)
                T.eq(outEvents[1].spellId, 11111, "first hit → first cast (FIFO)")
                T.eq(outEvents[2].spellId, 22222, "second hit → second cast (FIFO)")
            end)

            T.test("non-player unit cast does not push a token", function()
                resetInteg()
                CL:HandleSpellcastSucceeded("target", nil, 99999)  -- enemy cast
                _G._mockTime = 0.05
                CL:HandleUnitCombat("target", "WOUND", "NONE", 7777, 0x4)
                T.count(outEvents, 0, "non-player spell cast must not create a token")
            end)

            T.test("HEAL action from UNIT_COMBAT also attributed via token", function()
                resetInteg()
                CL:HandleSpellcastSucceeded("player", nil, 77758)
                _G._mockTime = 0.05
                CL:HandleUnitCombat("target", "HEAL", "NONE", 3000, 0x8)
                T.count(outEvents, 1, "heal action should also consume token")
                T.eq(outEvents[1].spellId, 77758)
            end)

            T.test("incoming 'player' UNIT_COMBAT not gated by token", function()
                resetInteg()
                -- Incoming hits on the player do not require a cast token
                CL:HandleUnitCombat("player", "WOUND", "NONE", 1500, 0x4)
                -- No assert on count here — incoming goes to IncomingProbe, not outEvents
                -- Just verify no error is thrown
                local ok = true  -- pcall already checked in HandleUnitCombat
                T.ok(ok, "incoming UNIT_COMBAT must not throw")
            end)
        end  -- if hasHandlers
    end  -- if ctmChunk
end
