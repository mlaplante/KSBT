------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Diagnostics
-- Debug output and SavedVariables event logging.
------------------------------------------------------------------------

local ADDON_NAME, KSBT = ...
local Addon = KSBT.Addon

------------------------------------------------------------------------
-- Debug Print (respects current debug level)
------------------------------------------------------------------------
function Addon:DebugPrint(requiredLevel, ...)
    local currentLevel = self.db and self.db.profile.diagnostics.debugLevel or 0
    if currentLevel >= requiredLevel then
        self:Print("|cFF4A9EFF[Debug " .. requiredLevel .. "]|r", ...)
    end
end

------------------------------------------------------------------------
-- Log Event to SavedVariables (for post-session analysis)
------------------------------------------------------------------------
function Addon:LogEvent(eventData)
    local diag = self.db and self.db.profile.diagnostics
    if not diag or not diag.captureEnabled then
        return
    end

    -- Bounded insertion: drop oldest if at capacity
    local log = diag.log
    if #log >= diag.maxEntries then
        table.remove(log, 1)
    end

    eventData.timestamp = GetTime()
    log[#log + 1] = eventData
end

------------------------------------------------------------------------
-- Clear Diagnostic Log
------------------------------------------------------------------------
function Addon:ClearDiagnosticLog()
    if self.db and self.db.profile.diagnostics then
        wipe(self.db.profile.diagnostics.log)
        self:Print("Diagnostic log cleared.")
    end
end

------------------------------------------------------------------------
-- Test Display Chain (#1)
-- Fires text directly into the Outgoing scroll area, bypassing all
-- event detection. Tests: ShouldEmitNow, scroll area config, FireTestText.
------------------------------------------------------------------------
function Addon:TestDisplay()
    self:Print("Testing display chain for 'Outgoing' area...")

    -- Check master gate directly so we can report WHY it fails
    if not (KSBT.db and KSBT.db.profile and KSBT.db.profile.general
            and KSBT.db.profile.general.enabled) then
        self:Print("|cffff4444FAIL:|r KSBT master enable is OFF. Enable the addon first.")
        return
    end

    local combatOnly = KSBT.db.profile.general.combatOnly
    if combatOnly and not UnitAffectingCombat("player") then
        self:Print("|cffff4444FAIL:|r Combat-Only mode is ON and you are not in combat. "
                .. "Disable Combat-Only or enter combat to test.")
        return
    end

    local area = KSBT.db.profile.scrollAreas and KSBT.db.profile.scrollAreas["Outgoing"]
    if not area then
        self:Print("|cffff4444FAIL:|r No 'Outgoing' scroll area found in profile.")
        return
    end

    if type(KSBT.FireTestText) ~= "function" then
        self:Print("|cffff4444FAIL:|r KSBT.FireTestText is not defined. ScrollAreaFrames.lua may not be loaded.")
        return
    end

    -- Fire directly through FireTestText, bypassing the ShouldEmitNow gate
    -- (we already checked it above with human-readable errors)
    local fontFace, fontSize, outlineFlag, fontAlpha = KSBT.ResolveFontForArea("Outgoing")
    local anchorH = (area.alignment == "Left" and "LEFT") or (area.alignment == "Right" and "RIGHT") or "CENTER"
    local dirMult = (area.direction == "Down") and -1 or 1
    local speed = tonumber(area.animSpeed) or 1.0
    if speed <= 0 then speed = 1.0 end
    local duration = 1.2 / speed

    KSBT.FireTestText("Outgoing", "DMG 9999!",  area, fontFace, fontSize, outlineFlag, fontAlpha,
                      anchorH, dirMult, duration, {r=1.0, g=0.25, b=0.25})
    C_Timer.After(0.25, function()
        KSBT.FireTestText("Outgoing", "HEAL 4567!", area, fontFace, fontSize, outlineFlag, fontAlpha,
                          anchorH, dirMult, duration, {r=0.2, g=1.0, b=0.2})
    end)
    self:Print("|cff00ff00OK:|r Fired test text into Outgoing area. "
            .. "If nothing appears on screen, check scroll area position (xOffset="
            .. tostring(area.xOffset) .. " yOffset=" .. tostring(area.yOffset) .. ").")
end

------------------------------------------------------------------------
-- UNIT_COMBAT Event Probe (#2)
-- Registers a standalone frame that dumps ALL UNIT_COMBAT events for
-- "player" and "target" to chat for a set duration.
------------------------------------------------------------------------
local _eventProbeFrame = nil
local _eventProbeTimer = nil

function Addon:StartEventProbe(secondsStr)
    local seconds = tonumber(secondsStr) or 30
    if seconds < 5 then seconds = 5 end
    if seconds > 120 then seconds = 120 end

    if _eventProbeFrame then
        self:Print("Event probe already running. Use '/ksbt probeevents stop' to stop it.")
        return
    end

    _eventProbeFrame = CreateFrame("Frame")
    _eventProbeFrame:RegisterUnitEvent("UNIT_COMBAT", "player")
    _eventProbeFrame:RegisterUnitEvent("UNIT_COMBAT", "target")
    _eventProbeFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

    _eventProbeFrame:SetScript("OnEvent", function(self, event, ...)
        local a1, a2, a3, a4, a5 = ...
        print("|cffff9900KSBT-Probe|r " .. event
            .. " u=" .. tostring(a1)
            .. " a=" .. tostring(a2)
            .. " f=" .. tostring(a3)
            .. " amt=" .. tostring(a4)
            .. " s=" .. tostring(a5))
    end)

    self:Print(("Event probe STARTED for %ds. Attack something — UNIT_COMBAT and "
             .. "UNIT_SPELLCAST_SUCCEEDED will print here."):format(seconds))

    _eventProbeTimer = C_Timer.After(seconds, function()
        Addon:StopEventProbe(true)
    end)
end

function Addon:StopEventProbe(auto)
    if not _eventProbeFrame then
        self:Print("Event probe is not running.")
        return
    end
    _eventProbeFrame:UnregisterAllEvents()
    _eventProbeFrame:SetScript("OnEvent", nil)
    _eventProbeFrame = nil
    _eventProbeTimer = nil
    self:Print("Event probe " .. (auto and "ended (timeout)." or "stopped."))
end

------------------------------------------------------------------------
-- COMBAT_TEXT_UPDATE Probe (#3)
-- Tests whether COMBAT_TEXT_UPDATE fires in Midnight for outgoing
-- player combat events. If it does, it's a cleaner attribution source
-- than UNIT_COMBAT (player-only, no false positives from group members).
------------------------------------------------------------------------
local _ctuProbeFrame = nil
local _ctuProbeTimer = nil

function Addon:StartCombatTextProbe(secondsStr)
    local seconds = tonumber(secondsStr) or 30
    if seconds < 5 then seconds = 5 end
    if seconds > 120 then seconds = 120 end

    if _ctuProbeFrame then
        self:Print("COMBAT_TEXT_UPDATE probe already running. Use '/ksbt probecombattext stop' to stop it.")
        return
    end

    _ctuProbeFrame = CreateFrame("Frame")
    local ok = pcall(function()
        _ctuProbeFrame:RegisterEvent("COMBAT_TEXT_UPDATE")
    end)

    if not ok then
        _ctuProbeFrame = nil
        self:Print("|cffff4444FAIL:|r COMBAT_TEXT_UPDATE is forbidden/unavailable in this build.")
        return
    end

    _ctuProbeFrame:SetScript("OnEvent", function(self, event, combatTextType, arg1, arg2)
        print("|cff00ccffKSBT-CTU|r type=" .. tostring(combatTextType)
            .. " arg1=" .. tostring(arg1)
            .. " arg2=" .. tostring(arg2))
    end)

    self:Print(("COMBAT_TEXT_UPDATE probe STARTED for %ds. Deal damage or cast a heal. "
             .. "If this event fires, we can use it for clean outgoing attribution."):format(seconds))

    _ctuProbeTimer = C_Timer.After(seconds, function()
        Addon:StopCombatTextProbe(true)
    end)
end

function Addon:StopCombatTextProbe(auto)
    if not _ctuProbeFrame then
        self:Print("COMBAT_TEXT_UPDATE probe is not running.")
        return
    end
    _ctuProbeFrame:UnregisterAllEvents()
    _ctuProbeFrame:SetScript("OnEvent", nil)
    _ctuProbeFrame = nil
    _ctuProbeTimer = nil
    self:Print("COMBAT_TEXT_UPDATE probe " .. (auto and "ended (timeout)." or "stopped."))
end
