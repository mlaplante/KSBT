------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Cooldowns Decision Layer
-- Receives cooldown-ready events and emits notification text.
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

KSBT.Core = KSBT.Core or {}
KSBT.Core.Cooldowns = KSBT.Core.Cooldowns or {}
local Cooldowns = KSBT.Core.Cooldowns
local Addon     = KSBT.Addon

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

    local db = KSBT.db and KSBT.db.profile
    if not db or not db.cooldowns or not db.cooldowns.enabled then return end

    -- Gate on master enable + combat-only mode
    if KSBT.Core and KSBT.Core.ShouldEmitNow and not KSBT.Core:ShouldEmitNow() then
        return
    end

    local spellId = event.spellId
    local conf    = db.cooldowns
    local area    = conf.scrollArea or "Notifications"
    local fmt     = conf.format or "%s Ready!"

    -- Resolve spell name: SpellData table first, then live API
    local spellName
    local spellData = KSBT.SPELLS and KSBT.SPELLS.RESTO_DRUID and
                      KSBT.SPELLS.RESTO_DRUID[spellId]
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

    if KSBT.DisplayText then
        KSBT.DisplayText(area, text, color, { kind = "cooldown", spellId = spellId })
    elseif KSBT.Core and KSBT.Core.Display and KSBT.Core.Display.Emit then
        KSBT.Core.Display:Emit(area, text, color, { kind = "cooldown", spellId = spellId })
    end

    -- Play cooldown-ready sound if configured
    local soundName = conf.sound
    if soundName and soundName ~= "None" and soundName ~= "" then
        local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
        local soundPath = LSM and LSM:Fetch("sound", soundName)
        if soundPath and PlaySoundFile then
            PlaySoundFile(soundPath, "SFX")
        end
    end
end
