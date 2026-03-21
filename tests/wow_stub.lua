------------------------------------------------------------------------
-- WoW API Stub — provides all globals the addon needs outside of WoW.
-- Designed for Lua 5.3+ (brew install lua) or LuaJIT.
------------------------------------------------------------------------

-- Bitwise compatibility: Lua 5.3+ has native & / | operators but no 'bit' global.
-- LuaJIT provides 'bit' natively; don't override if already present.
if not bit then
    bit = {
        band  = function(a, b) return a & b  end,
        bor   = function(a, b) return a | b  end,
        bxor  = function(a, b) return a ~ b  end,
        bnot  = function(a)    return ~a     end,
        lshift = function(a, b) return a << b end,
        rshift = function(a, b) return a >> b end,
    }
end

-- Combat log affiliation / type flags (WoW constants)
COMBATLOG_OBJECT_AFFILIATION_MINE  = 0x00000001
COMBATLOG_OBJECT_TYPE_PLAYER       = 0x00000400
COMBATLOG_OBJECT_TYPE_NPC          = 0x00000800
COMBATLOG_OBJECT_REACTION_NEUTRAL  = 0x00000020

-- Simulated time (advance with _G._mockTime = N in tests)
_G._mockTime = 0
GetTime = function() return _G._mockTime end

-- Pending timers: tests call FireAllTimers() to flush synchronously.
_G._pendingTimers = {}

local function _clearTimers()
    _G._pendingTimers = {}
end

function FireAllTimers()
    local pending = _G._pendingTimers
    _G._pendingTimers = {}
    for _, t in ipairs(pending) do
        if not t._cancelled then t._fn() end
    end
end

C_Timer = {
    After = function(delay, fn)
        local t = { _cancelled = false, _fn = fn }
        t.Cancel = function(self) self._cancelled = true end
        t.Fire   = function(self)
            if not self._cancelled then self._fn() end
        end
        table.insert(_G._pendingTimers, t)
        return t
    end,
    NewTimer = function(delay, fn)
        local t = { _cancelled = false, _fn = fn }
        t.Cancel = function(self) self._cancelled = true end
        t.Fire   = function(self)
            if not self._cancelled then self._fn() end
        end
        table.insert(_G._pendingTimers, t)
        return t
    end,
}

-- Secret value detection: always false in tests (amounts are plain numbers)
issecretvalue = function(v) return false end

-- Spell info lookup stub
C_Spell = {
    GetSpellInfo = function(spellId)
        return { name = "Spell" .. tostring(spellId), iconID = 0, originalIconID = 0 }
    end,
}

-- Noop debug / print (addon guards these with Addon.Print)
-- Left as nil so addon's nil-checks pass silently.
