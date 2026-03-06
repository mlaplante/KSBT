------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Cooldowns Decision Layer
-- Receives cooldown-ready events and emits notification text.
------------------------------------------------------------------------
local ADDON_NAME, TSBT = ...

TSBT.Core = TSBT.Core or {}
TSBT.Core.Cooldowns = TSBT.Core.Cooldowns or {}
local Cooldowns = TSBT.Core.Cooldowns
local Addon     = TSBT.Addon

function Cooldowns:Enable()
    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(1, "Cooldowns:Enable()")
    end
end

function Cooldowns:Disable()
    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(1, "Cooldowns:Disable()")
    end
end

-- Called by Parser.Cooldowns when a tracked spell comes off cooldown.
-- event = { spellId = number }
function Cooldowns:OnCooldownReady(event)
    if not event or not event.spellId then return end

    local db = TSBT.db and TSBT.db.profile
    if not db or not db.cooldowns or not db.cooldowns.enabled then return end

    -- Gate on master enable + combat-only mode
    if TSBT.Core and TSBT.Core.ShouldEmitNow and not TSBT.Core:ShouldEmitNow() then
        return
    end

    local spellId = event.spellId
    local conf    = db.cooldowns
    local area    = conf.scrollArea or "Notifications"
    local fmt     = conf.format or "%s Ready!"

    -- Resolve spell name: SpellData table first, then live API
    local spellName
    local spellData = TSBT.SPELLS and TSBT.SPELLS.RESTO_DRUID and
                      TSBT.SPELLS.RESTO_DRUID[spellId]
    if spellData then
        spellName = spellData.name
    elseif C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellId)
        spellName = info and info.name
    end

    if not spellName then
        spellName = "Spell " .. tostring(spellId)
    end

    local text  = fmt:format(spellName)
    local color = {r = 1.00, g = 0.85, b = 0.00}   -- gold for notifications

    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(2, ("Cooldowns:OnCooldownReady spellId=%d name=%s"):format(
            spellId, spellName))
    end

    if TSBT.DisplayText then
        TSBT.DisplayText(area, text, color, { kind = "cooldown", spellId = spellId })
    elseif TSBT.Core and TSBT.Core.Display and TSBT.Core.Display.Emit then
        TSBT.Core.Display:Emit(area, text, color, { kind = "cooldown", spellId = spellId })
    end
end
