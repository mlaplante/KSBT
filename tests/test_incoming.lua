------------------------------------------------------------------------
-- Tests: Core/Incoming_Probe.lua — incoming damage and heal pipeline
------------------------------------------------------------------------

local T = require("runner")
local H = require("helpers")

------------------------------------------------------------------------
-- INCOMING DAMAGE — basic
------------------------------------------------------------------------
T.suite("Incoming Damage — basic")

do
    local ksbt, _, inc, emitted = H.makeKSBT()

    T.test("emits basic incoming damage", function()
        H.resetState(emitted)
        inc:ProcessIncomingEvent(H.inDamageEvt({ amount = 500 }), false)
        T.count(emitted, 1)
        T.eq(emitted[1].text, "500")
        T.eq(emitted[1].area, "Incoming")
    end)

    T.test("suppresses below minThreshold", function()
        H.resetState(emitted)
        ksbt.db.profile.incoming.damage.minThreshold = 1000
        inc:ProcessIncomingEvent(H.inDamageEvt({ amount = 100 }), false)
        T.count(emitted, 0)
        ksbt.db.profile.incoming.damage.minThreshold = 0
    end)

    T.test("allows at or above minThreshold", function()
        H.resetState(emitted)
        ksbt.db.profile.incoming.damage.minThreshold = 500
        inc:ProcessIncomingEvent(H.inDamageEvt({ amount = 500 }), false)
        T.count(emitted, 1)
        ksbt.db.profile.incoming.damage.minThreshold = 0
    end)

    T.test("suppresses when damage disabled", function()
        H.resetState(emitted)
        ksbt.db.profile.incoming.damage.enabled = false
        inc:ProcessIncomingEvent(H.inDamageEvt(), false)
        T.count(emitted, 0)
        ksbt.db.profile.incoming.damage.enabled = true
    end)

    T.test("zero or negative amount suppressed", function()
        H.resetState(emitted)
        inc:ProcessIncomingEvent(H.inDamageEvt({ amount = 0 }), false)
        T.count(emitted, 0)
    end)
end

------------------------------------------------------------------------
-- INCOMING DAMAGE — flag text
------------------------------------------------------------------------
T.suite("Incoming Damage — flag text")

do
    local ksbt, _, inc, emitted = H.makeKSBT()

    T.test("includes flagText when showFlags=true", function()
        H.resetState(emitted)
        ksbt.db.profile.incoming.damage.showFlags = true
        inc:ProcessIncomingEvent(H.inDamageEvt({ flagText = "DODGE" }), false)
        T.count(emitted, 1)
        T.contains(emitted[1].text, "DODGE")
        ksbt.db.profile.incoming.damage.showFlags = false
    end)

    T.test("omits flagText when showFlags=false", function()
        H.resetState(emitted)
        ksbt.db.profile.incoming.damage.showFlags = false
        inc:ProcessIncomingEvent(H.inDamageEvt({ flagText = "DODGE" }), false)
        T.count(emitted, 1)
        T.not_contains(emitted[1].text, "DODGE")
    end)
end

------------------------------------------------------------------------
-- INCOMING DAMAGE — spell filter
------------------------------------------------------------------------
T.suite("Incoming Damage — spell filters")

do
    local ksbt, _, inc, emitted = H.makeKSBT()
    local SPELL = 55555

    T.test("blacklisted spell suppressed", function()
        H.resetState(emitted)
        ksbt.db.char.spellFilters[tostring(SPELL)] = { mode = "hide", name = "Test", kind = "damage" }
        inc:ProcessIncomingEvent(H.inDamageEvt({ spellId = SPELL }), false)
        T.count(emitted, 0)
    end)

    T.test("whitelisted spell bypasses minThreshold", function()
        H.resetState(emitted)
        ksbt.db.profile.incoming.damage.minThreshold = 5000
        ksbt.db.char.spellFilters[tostring(SPELL)] = { mode = "show", name = "Test", kind = "damage" }
        inc:ProcessIncomingEvent(H.inDamageEvt({ spellId = SPELL, amount = 50 }), false)
        T.count(emitted, 1, "whitelisted should bypass threshold")
        ksbt.db.profile.incoming.damage.minThreshold = 0
    end)
end

------------------------------------------------------------------------
-- INCOMING HEALING — basic
------------------------------------------------------------------------
T.suite("Incoming Healing — basic")

do
    local ksbt, _, inc, emitted = H.makeKSBT()

    T.test("emits incoming heal event", function()
        H.resetState(emitted)
        inc:ProcessIncomingEvent({ kind = "heal", amount = 1500, spellId = 33333 }, false)
        T.count(emitted, 1)
        T.eq(emitted[1].text, "1500")
        T.eq(emitted[1].area, "Incoming")
    end)

    T.test("suppresses heal below minThreshold", function()
        H.resetState(emitted)
        ksbt.db.profile.incoming.healing.minThreshold = 2000
        inc:ProcessIncomingEvent({ kind = "heal", amount = 100, spellId = 33333 }, false)
        T.count(emitted, 0)
        ksbt.db.profile.incoming.healing.minThreshold = 0
    end)

    T.test("suppresses when healing disabled", function()
        H.resetState(emitted)
        ksbt.db.profile.incoming.healing.enabled = false
        inc:ProcessIncomingEvent({ kind = "heal", amount = 1500, spellId = 33333 }, false)
        T.count(emitted, 0)
        ksbt.db.profile.incoming.healing.enabled = true
    end)
end

------------------------------------------------------------------------
-- INCOMING — unknown kind is silently dropped
------------------------------------------------------------------------
T.suite("Incoming — edge cases")

do
    local _, _, inc, emitted = H.makeKSBT()

    T.test("unknown kind silently dropped", function()
        H.resetState(emitted)
        inc:ProcessIncomingEvent({ kind = "resource", amount = 100 }, false)
        T.count(emitted, 0)
    end)

    T.test("nil event silently dropped", function()
        H.resetState(emitted)
        inc:OnIncomingDetected(nil)
        T.count(emitted, 0)
    end)

    T.test("non-table event silently dropped", function()
        H.resetState(emitted)
        inc:OnIncomingDetected("bad input")
        T.count(emitted, 0)
    end)
end
