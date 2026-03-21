------------------------------------------------------------------------
-- Test helpers: factory for a fresh KSBT table + loaded probe modules.
-- Each call to makeKSBT() reloads the Lua files from disk, giving a
-- completely clean _mergeState / _spellHistory for every test.
------------------------------------------------------------------------

local BASE = debug.getinfo(1, "S").source:match("@(.+/)")  -- dir of this file
    or "./"

-- Resolve a path relative to the tests/ directory (one level up for Core/)
local function path(rel)
    return BASE .. rel
end

-- Deep-copy a table (one level, sufficient for config overrides)
local function merge(dst, src)
    for k, v in pairs(src or {}) do
        if type(v) == "table" and type(dst[k]) == "table" then
            merge(dst[k], v)
        else
            dst[k] = v
        end
    end
end

------------------------------------------------------------------------
-- makeKSBT(profileOverrides, charOverrides)
--
-- Returns: ksbt, outProbe, inProbe, emitted
--   ksbt      — the addon namespace table
--   outProbe  — KSBT.Core.OutgoingProbe (loaded fresh)
--   inProbe   — KSBT.Core.IncomingProbe (loaded fresh)
--   emitted   — array of { area, text, color, meta } captures
------------------------------------------------------------------------
local function makeKSBT(profileOverrides, charOverrides)
    -- Default profile config
    local profile = {
        outgoing = {
            damage  = {
                enabled        = true,
                minThreshold   = 0,
                showTargets    = false,
                autoAttackMode = "Show All",
                scrollArea     = "Outgoing",
            },
            healing = {
                enabled      = true,
                minThreshold = 0,
                showOverheal = false,
                scrollArea   = "Outgoing",
            },
            showSpellNames = false,
        },
        incoming = {
            damage  = {
                enabled      = true,
                minThreshold = 0,
                showFlags    = false,
                scrollArea   = "Incoming",
            },
            healing = {
                enabled      = true,
                minThreshold = 0,
                scrollArea   = "Incoming",
            },
            useSchoolColors = false,
        },
    }

    -- Default char config
    local char = {
        spellFilters = {},
        spamControl  = {
            merging = {
                enabled   = false,
                window    = 1.5,
                showCount = false,
            },
            throttling = {
                minDamage       = 0,
                minHealing      = 0,
                hideAutoBelow   = 0,
                postMergeDamage = 0,
                postMergeHealing = 0,
            },
            suppressDummyDamage = false,
            percentileScaling   = {
                enabled    = false,
                percentile = 95,
                maxScale   = 1.5,
            },
        },
    }

    merge(profile, profileOverrides or {})
    merge(char,    charOverrides    or {})

    -- Emission capture
    local emitted = {}

    local ksbt = {
        Addon = {},
        Core  = {},
        db    = { profile = profile, char = char },

        FormatNumber = function(n)
            return tostring(math.floor(n + 0.5))
        end,

        -- Capture display output
        DisplayText = function(area, text, color, meta)
            table.insert(emitted, { area = area, text = text, color = color, meta = meta })
        end,
    }

    -- Load Outgoing_Probe.lua fresh (gives clean _mergeState + _spellHistory)
    local outChunk = assert(loadfile(path("../Core/Outgoing_Probe.lua")))
    outChunk("KBST", ksbt)
    local outProbe = ksbt.Core.OutgoingProbe
    outProbe:Init()

    -- Load Incoming_Probe.lua fresh
    local inChunk = assert(loadfile(path("../Core/Incoming_Probe.lua")))
    inChunk("KBST", ksbt)
    local inProbe = ksbt.Core.IncomingProbe
    inProbe:Init()

    return ksbt, outProbe, inProbe, emitted
end

-- Reset emission capture between tests (same KSBT instance)
local function clearEmitted(emitted)
    for i = #emitted, 1, -1 do emitted[i] = nil end
end

-- Reset pending timers and emission list
local function resetState(emitted)
    clearEmitted(emitted)
    _G._pendingTimers = {}
    _G._mockTime      = 0
end

-- Build a basic outgoing damage event
local function damageEvt(overrides)
    local e = {
        kind       = "damage",
        amount     = 1000,
        isCrit     = false,
        isAuto     = false,
        isPeriodic = false,
        spellId    = 12345,
        spellName  = "Moonfire",
        schoolMask = 0x8,  -- nature
        destFlags  = 0x00000400,  -- player target (non-dummy)
        targetName = "Target",
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    return e
end

-- Build a basic outgoing heal event
local function healEvt(overrides)
    local e = {
        kind      = "heal",
        amount    = 2000,
        overheal  = 0,
        isCrit    = false,
        spellId   = 77758,
        spellName = "Rejuvenation",
        schoolMask = 0x8,
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    return e
end

-- Build a basic incoming damage event
local function inDamageEvt(overrides)
    local e = {
        kind       = "damage",
        amount     = 500,
        isCrit     = false,
        spellId    = 99999,
        spellName  = "Fire Blast",
        schoolMask = 0x4,  -- fire
        sourceName = "Mob",
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    return e
end

return {
    makeKSBT     = makeKSBT,
    clearEmitted = clearEmitted,
    resetState   = resetState,
    damageEvt    = damageEvt,
    healEvt      = healEvt,
    inDamageEvt  = inDamageEvt,
}
