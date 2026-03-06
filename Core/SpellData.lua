------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Spell Data
-- Known spell lists used for cooldown tracking and display enrichment.
-- Spell IDs sourced from WoW Midnight 12.0.x (Restoration Druid).
------------------------------------------------------------------------

local ADDON_NAME, KSBT = ...

------------------------------------------------------------------------
-- Restoration Druid - All Healing Spells
-- Format: [spellId] = { name, cooldown (seconds, 0 = no CD), isHoT }
------------------------------------------------------------------------
KSBT.SPELLS = KSBT.SPELLS or {}

KSBT.SPELLS.RESTO_DRUID = {

    ----------------------------------------------------------------
    -- Core Heals
    ----------------------------------------------------------------
    [774]    = { name = "Rejuvenation",       cooldown = 0,    isHoT = true  },
    [8936]   = { name = "Regrowth",           cooldown = 0,    isHoT = false },
    [33763]  = { name = "Lifebloom",          cooldown = 0,    isHoT = true  },
    [48438]  = { name = "Wild Growth",        cooldown = 10,   isHoT = true  },
    [18562]  = { name = "Swiftmend",          cooldown = 15,   isHoT = false },
    [145205] = { name = "Efflorescence",      cooldown = 0,    isHoT = true  },

    ----------------------------------------------------------------
    -- Major Cooldowns
    ----------------------------------------------------------------
    [740]    = { name = "Tranquility",        cooldown = 180,  isHoT = true  },
    [102342] = { name = "Ironbark",           cooldown = 90,   isHoT = false },
    [132158] = { name = "Nature's Swiftness", cooldown = 60,   isHoT = false },
    [102351] = { name = "Cenarion Ward",      cooldown = 30,   isHoT = true  },

    ----------------------------------------------------------------
    -- Talent Cooldowns
    ----------------------------------------------------------------
    [197721] = { name = "Flourish",           cooldown = 90,   isHoT = false },
    [391888] = { name = "Adaptive Swarm",     cooldown = 25,   isHoT = true  },
    [391528] = { name = "Convoke the Spirits",cooldown = 180,  isHoT = false },
    [22842]  = { name = "Frenzied Regeneration", cooldown = 18, isHoT = false },

    ----------------------------------------------------------------
    -- Periodic / Proc Heals (no cast, tracked for display only)
    ----------------------------------------------------------------
    [207386] = { name = "Spring Blossoms",    cooldown = 0,    isHoT = true  },
    [81262]  = { name = "Efflorescence (Ground)", cooldown = 0, isHoT = true },
    [189877] = { name = "Infusion of Nature", cooldown = 0,    isHoT = true  },
}

------------------------------------------------------------------------
-- Helper: returns a cooldowns.tracked-compatible table for all
-- Resto Druid spells that have a meaningful cooldown (cooldown > 0).
------------------------------------------------------------------------
function KSBT.BuildRestoDruidCooldownDefaults()
    local t = {}
    for spellId, data in pairs(KSBT.SPELLS.RESTO_DRUID) do
        if data.cooldown > 0 then
            t[spellId] = true
        end
    end
    return t
end
