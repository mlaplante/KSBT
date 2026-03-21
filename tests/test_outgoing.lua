------------------------------------------------------------------------
-- Tests: Core/Outgoing_Probe.lua — damage and heal pipeline
------------------------------------------------------------------------

local T = require("runner")
local H = require("helpers")

------------------------------------------------------------------------
-- DAMAGE — basic filtering
------------------------------------------------------------------------
T.suite("Outgoing Damage — basic")

do
    local ksbt, out, _, emitted = H.makeKSBT()

    T.test("emits basic damage event", function()
        H.resetState(emitted)
        out:ProcessOutgoingEvent(H.damageEvt(), false)
        T.count(emitted, 1)
        T.eq(emitted[1].text, "1000")
        T.eq(emitted[1].area, "Outgoing")
    end)

    T.test("suppresses damage below minThreshold", function()
        H.resetState(emitted)
        ksbt.db.profile.outgoing.damage.minThreshold = 5000
        out:ProcessOutgoingEvent(H.damageEvt({ amount = 100 }), false)
        T.count(emitted, 0)
        ksbt.db.profile.outgoing.damage.minThreshold = 0
    end)

    T.test("allows damage at or above minThreshold", function()
        H.resetState(emitted)
        ksbt.db.profile.outgoing.damage.minThreshold = 1000
        out:ProcessOutgoingEvent(H.damageEvt({ amount = 1000 }), false)
        T.count(emitted, 1)
        ksbt.db.profile.outgoing.damage.minThreshold = 0
    end)

    T.test("suppresses when damage is disabled", function()
        H.resetState(emitted)
        ksbt.db.profile.outgoing.damage.enabled = false
        out:ProcessOutgoingEvent(H.damageEvt(), false)
        T.count(emitted, 0)
        ksbt.db.profile.outgoing.damage.enabled = true
    end)

    T.test("crit damage text ends with !", function()
        H.resetState(emitted)
        out:ProcessOutgoingEvent(H.damageEvt({ isCrit = true }), false)
        T.count(emitted, 1)
        T.contains(emitted[1].text, "!")
    end)

    T.test("normal hit text does not end with !", function()
        H.resetState(emitted)
        out:ProcessOutgoingEvent(H.damageEvt({ isCrit = false }), false)
        T.count(emitted, 1)
        T.not_contains(emitted[1].text, "!")
    end)
end

------------------------------------------------------------------------
-- DAMAGE — spell name and target display
------------------------------------------------------------------------
T.suite("Outgoing Damage — text formatting")

do
    local ksbt, out, _, emitted = H.makeKSBT()

    T.test("includes spell name when showSpellNames=true", function()
        H.resetState(emitted)
        ksbt.db.profile.outgoing.showSpellNames = true
        out:ProcessOutgoingEvent(H.damageEvt({ spellName = "Moonfire" }), false)
        T.count(emitted, 1)
        T.contains(emitted[1].text, "Moonfire")
        ksbt.db.profile.outgoing.showSpellNames = false
    end)

    T.test("omits spell name when showSpellNames=false", function()
        H.resetState(emitted)
        ksbt.db.profile.outgoing.showSpellNames = false
        out:ProcessOutgoingEvent(H.damageEvt({ spellName = "Moonfire" }), false)
        T.count(emitted, 1)
        T.not_contains(emitted[1].text, "Moonfire")
    end)

    T.test("includes target name when showTargets=true", function()
        H.resetState(emitted)
        ksbt.db.profile.outgoing.damage.showTargets = true
        out:ProcessOutgoingEvent(H.damageEvt({ targetName = "Hogger" }), false)
        T.count(emitted, 1)
        T.contains(emitted[1].text, "Hogger")
        ksbt.db.profile.outgoing.damage.showTargets = false
    end)

    T.test("omits target name when showTargets=false", function()
        H.resetState(emitted)
        ksbt.db.profile.outgoing.damage.showTargets = false
        out:ProcessOutgoingEvent(H.damageEvt({ targetName = "Hogger" }), false)
        T.count(emitted, 1)
        T.not_contains(emitted[1].text, "Hogger")
    end)

    T.test("omits spell name for auto-attacks even when showSpellNames=true", function()
        H.resetState(emitted)
        ksbt.db.profile.outgoing.showSpellNames = true
        out:ProcessOutgoingEvent(H.damageEvt({ isAuto = true, spellName = "Auto Attack" }), false)
        T.count(emitted, 1)
        T.not_contains(emitted[1].text, "Auto Attack")
        ksbt.db.profile.outgoing.showSpellNames = false
    end)
end

------------------------------------------------------------------------
-- DAMAGE — auto-attack filtering modes
------------------------------------------------------------------------
T.suite("Outgoing Damage — auto-attack modes")

do
    local ksbt, out, _, emitted = H.makeKSBT()

    T.test("autoAttackMode=Show All: normal auto shown", function()
        H.resetState(emitted)
        ksbt.db.profile.outgoing.damage.autoAttackMode = "Show All"
        out:ProcessOutgoingEvent(H.damageEvt({ isAuto = true, isCrit = false }), false)
        T.count(emitted, 1)
    end)

    T.test("autoAttackMode=Hide: auto suppressed", function()
        H.resetState(emitted)
        ksbt.db.profile.outgoing.damage.autoAttackMode = "Hide"
        out:ProcessOutgoingEvent(H.damageEvt({ isAuto = true }), false)
        T.count(emitted, 0)
    end)

    T.test("autoAttackMode=Show Only Crits: normal auto suppressed", function()
        H.resetState(emitted)
        ksbt.db.profile.outgoing.damage.autoAttackMode = "Show Only Crits"
        out:ProcessOutgoingEvent(H.damageEvt({ isAuto = true, isCrit = false }), false)
        T.count(emitted, 0)
    end)

    T.test("autoAttackMode=Show Only Crits: auto crit shown", function()
        H.resetState(emitted)
        ksbt.db.profile.outgoing.damage.autoAttackMode = "Show Only Crits"
        out:ProcessOutgoingEvent(H.damageEvt({ isAuto = true, isCrit = true }), false)
        T.count(emitted, 1)
        T.contains(emitted[1].text, "!")
    end)

    T.test("autoAttackMode=Show All: spell (non-auto) always shown", function()
        H.resetState(emitted)
        ksbt.db.profile.outgoing.damage.autoAttackMode = "Hide"
        out:ProcessOutgoingEvent(H.damageEvt({ isAuto = false }), false)
        T.count(emitted, 1)  -- Hide only suppresses autos, not spells
    end)
end

------------------------------------------------------------------------
-- DAMAGE — dummy suppression
------------------------------------------------------------------------
T.suite("Outgoing Damage — training dummy suppression")

do
    local ksbt, out, _, emitted = H.makeKSBT()

    -- Training dummy flags: NPC type + neutral reaction
    local DUMMY_FLAGS = 0x00000800 | 0x00000020

    T.test("suppresses dummy targets when suppressDummyDamage=true", function()
        H.resetState(emitted)
        ksbt.db.char.spamControl.suppressDummyDamage = true
        out:ProcessOutgoingEvent(H.damageEvt({ destFlags = DUMMY_FLAGS }), false)
        T.count(emitted, 0)
        ksbt.db.char.spamControl.suppressDummyDamage = false
    end)

    T.test("allows dummy targets when suppressDummyDamage=false", function()
        H.resetState(emitted)
        ksbt.db.char.spamControl.suppressDummyDamage = false
        out:ProcessOutgoingEvent(H.damageEvt({ destFlags = DUMMY_FLAGS }), false)
        T.count(emitted, 1)
    end)

    T.test("non-dummy NPC not suppressed", function()
        H.resetState(emitted)
        ksbt.db.char.spamControl.suppressDummyDamage = true
        -- NPC type but hostile (not neutral), should not be suppressed as dummy
        local hostileNpc = 0x00000800 | 0x00000040  -- NPC + hostile
        out:ProcessOutgoingEvent(H.damageEvt({ destFlags = hostileNpc }), false)
        T.count(emitted, 1)
        ksbt.db.char.spamControl.suppressDummyDamage = false
    end)
end

------------------------------------------------------------------------
-- DAMAGE — global throttle (minDamage)
------------------------------------------------------------------------
T.suite("Outgoing Damage — global throttle")

do
    local ksbt, out, _, emitted = H.makeKSBT()

    T.test("suppresses below minDamage throttle", function()
        H.resetState(emitted)
        ksbt.db.char.spamControl.throttling.minDamage = 2000
        out:ProcessOutgoingEvent(H.damageEvt({ amount = 500 }), false)
        T.count(emitted, 0)
        ksbt.db.char.spamControl.throttling.minDamage = 0
    end)

    T.test("allows at or above minDamage throttle", function()
        H.resetState(emitted)
        ksbt.db.char.spamControl.throttling.minDamage = 1000
        out:ProcessOutgoingEvent(H.damageEvt({ amount = 1000 }), false)
        T.count(emitted, 1)
        ksbt.db.char.spamControl.throttling.minDamage = 0
    end)

    T.test("hideAutoBelow suppresses small auto-attacks", function()
        H.resetState(emitted)
        ksbt.db.char.spamControl.throttling.hideAutoBelow = 500
        out:ProcessOutgoingEvent(H.damageEvt({ isAuto = true, amount = 100 }), false)
        T.count(emitted, 0)
        ksbt.db.char.spamControl.throttling.hideAutoBelow = 0
    end)

    T.test("hideAutoBelow does not affect spell damage", function()
        H.resetState(emitted)
        ksbt.db.char.spamControl.throttling.hideAutoBelow = 500
        out:ProcessOutgoingEvent(H.damageEvt({ isAuto = false, amount = 100 }), false)
        T.count(emitted, 1)
        ksbt.db.char.spamControl.throttling.hideAutoBelow = 0
    end)
end

------------------------------------------------------------------------
-- DAMAGE — spell filter (whitelist / blacklist)
------------------------------------------------------------------------
T.suite("Outgoing Damage — spell filters")

do
    local ksbt, out, _, emitted = H.makeKSBT()
    local SPELL = 11111

    T.test("first-time spell auto-discovers into spellFilters", function()
        H.resetState(emitted)
        ksbt.db.char.spellFilters = {}
        out:ProcessOutgoingEvent(H.damageEvt({ spellId = SPELL }), false)
        T.ok(ksbt.db.char.spellFilters[tostring(SPELL)], "should be registered")
        T.eq(ksbt.db.char.spellFilters[tostring(SPELL)].mode, "auto")
    end)

    T.test("blacklisted spell (mode=hide) suppressed", function()
        H.resetState(emitted)
        ksbt.db.char.spellFilters[tostring(SPELL)] = { mode = "hide", name = "Test", kind = "damage" }
        out:ProcessOutgoingEvent(H.damageEvt({ spellId = SPELL, amount = 9999 }), false)
        T.count(emitted, 0)
    end)

    T.test("whitelisted spell (mode=show) shown below threshold", function()
        H.resetState(emitted)
        ksbt.db.profile.outgoing.damage.minThreshold = 5000
        ksbt.db.char.spellFilters[tostring(SPELL)] = { mode = "show", name = "Test", kind = "damage" }
        out:ProcessOutgoingEvent(H.damageEvt({ spellId = SPELL, amount = 100 }), false)
        T.count(emitted, 1, "whitelist bypasses threshold")
        ksbt.db.profile.outgoing.damage.minThreshold = 0
    end)

    T.test("auto-mode spell respects threshold normally", function()
        H.resetState(emitted)
        ksbt.db.profile.outgoing.damage.minThreshold = 5000
        ksbt.db.char.spellFilters[tostring(SPELL)] = { mode = "auto", name = "Test", kind = "damage" }
        out:ProcessOutgoingEvent(H.damageEvt({ spellId = SPELL, amount = 100 }), false)
        T.count(emitted, 0, "auto mode should respect threshold")
        ksbt.db.profile.outgoing.damage.minThreshold = 0
    end)
end

------------------------------------------------------------------------
-- DAMAGE — merge (spam control)
------------------------------------------------------------------------
T.suite("Outgoing Damage — merging")

do
    local ksbt, out, _, emitted = H.makeKSBT()
    ksbt.db.char.spamControl.merging.enabled = true
    ksbt.db.char.spamControl.merging.window  = 1.5

    T.test("single event not emitted until timer fires", function()
        H.resetState(emitted)
        out:ProcessOutgoingEvent(H.damageEvt({ amount = 1000 }), false)
        T.count(emitted, 0, "should be held in merge buffer")
    end)

    T.test("two events same spell merge into one on timer fire", function()
        -- Flush any pending timers from the previous test before proceeding
        FireAllTimers()
        H.resetState(emitted)
        out:ProcessOutgoingEvent(H.damageEvt({ amount = 1000, spellId = 12345 }), false)
        out:ProcessOutgoingEvent(H.damageEvt({ amount = 500,  spellId = 12345 }), false)
        FireAllTimers()
        T.count(emitted, 1, "should produce one merged result")
        T.eq(emitted[1].text, "1500")
    end)

    T.test("merged crit: any crit in group marks merged text with !", function()
        FireAllTimers()
        H.resetState(emitted)
        out:ProcessOutgoingEvent(H.damageEvt({ amount = 1000, spellId = 12345, isCrit = false }), false)
        out:ProcessOutgoingEvent(H.damageEvt({ amount = 500,  spellId = 12345, isCrit = true  }), false)
        FireAllTimers()
        T.count(emitted, 1)
        T.contains(emitted[1].text, "!")
    end)

    T.test("merge count suffix when showCount=true", function()
        FireAllTimers()
        H.resetState(emitted)
        ksbt.db.char.spamControl.merging.showCount = true
        out:ProcessOutgoingEvent(H.damageEvt({ amount = 300, spellId = 12345 }), false)
        out:ProcessOutgoingEvent(H.damageEvt({ amount = 300, spellId = 12345 }), false)
        out:ProcessOutgoingEvent(H.damageEvt({ amount = 300, spellId = 12345 }), false)
        FireAllTimers()
        T.count(emitted, 1)
        T.contains(emitted[1].text, "x3")
        ksbt.db.char.spamControl.merging.showCount = false
    end)

    T.test("post-merge threshold discards low merged total", function()
        FireAllTimers()
        H.resetState(emitted)
        ksbt.db.char.spamControl.throttling.postMergeDamage = 5000
        out:ProcessOutgoingEvent(H.damageEvt({ amount = 100, spellId = 12345 }), false)
        out:ProcessOutgoingEvent(H.damageEvt({ amount = 100, spellId = 12345 }), false)
        FireAllTimers()
        T.count(emitted, 0, "merged total 200 < postMerge 5000 should be discarded")
        ksbt.db.char.spamControl.throttling.postMergeDamage = 0
    end)

    T.test("different spells produce separate merge groups", function()
        FireAllTimers()
        H.resetState(emitted)
        out:ProcessOutgoingEvent(H.damageEvt({ amount = 1000, spellId = 11111 }), false)
        out:ProcessOutgoingEvent(H.damageEvt({ amount = 2000, spellId = 22222 }), false)
        FireAllTimers()
        T.count(emitted, 2, "different spells should not merge")
    end)
end

------------------------------------------------------------------------
-- HEALING — basic
------------------------------------------------------------------------
T.suite("Outgoing Healing — basic")

do
    local ksbt, out, _, emitted = H.makeKSBT()

    T.test("emits basic heal event", function()
        H.resetState(emitted)
        out:ProcessOutgoingEvent(H.healEvt({ amount = 3000, overheal = 0 }), false)
        T.count(emitted, 1)
        T.eq(emitted[1].text, "3000")
    end)

    T.test("full overheal suppressed (net = 0)", function()
        H.resetState(emitted)
        out:ProcessOutgoingEvent(H.healEvt({ amount = 1000, overheal = 1000 }), false)
        T.count(emitted, 0, "full overheal should produce 0 net and be suppressed")
    end)

    T.test("partial overheal: shows net heal amount by default", function()
        H.resetState(emitted)
        out:ProcessOutgoingEvent(H.healEvt({ amount = 3000, overheal = 1000 }), false)
        T.count(emitted, 1)
        T.eq(emitted[1].text, "2000", "should show 3000 - 1000 = 2000")
    end)

    T.test("showOverheal=true: shows gross amount with overheal annotation", function()
        H.resetState(emitted)
        ksbt.db.profile.outgoing.healing.showOverheal = true
        out:ProcessOutgoingEvent(H.healEvt({ amount = 3000, overheal = 1000 }), false)
        T.count(emitted, 1)
        -- Gross amount (3000) is shown plus the overheal annotation "(OH 1000)"
        T.contains(emitted[1].text, "3000")
        T.contains(emitted[1].text, "OH")
        ksbt.db.profile.outgoing.healing.showOverheal = false
    end)

    T.test("heal below minThreshold suppressed", function()
        H.resetState(emitted)
        ksbt.db.profile.outgoing.healing.minThreshold = 5000
        out:ProcessOutgoingEvent(H.healEvt({ amount = 100, overheal = 0 }), false)
        T.count(emitted, 0)
        ksbt.db.profile.outgoing.healing.minThreshold = 0
    end)

    T.test("heal disabled suppresses output", function()
        H.resetState(emitted)
        ksbt.db.profile.outgoing.healing.enabled = false
        out:ProcessOutgoingEvent(H.healEvt(), false)
        T.count(emitted, 0)
        ksbt.db.profile.outgoing.healing.enabled = true
    end)
end
