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
-- CLEU Event Probe (#2)
-- Registers a standalone frame that dumps COMBAT_LOG_EVENT_UNFILTERED
-- events to chat for a set duration. Filters to player srcGUID/destGUID.
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

    local playerGUID = UnitGUID("player")

    local GetInfo = CombatLogGetCurrentEventInfo
        or (C_CombatLog and C_CombatLog.GetCurrentEventInfo)

    _eventProbeFrame = CreateFrame("Frame")

    _eventProbeFrame:SetScript("OnEvent", function()
        local ts, sub, _, srcGUID, srcName, srcFlags, _,
              destGUID, destName, destFlags = GetInfo()

        local isPlayer = (srcGUID == playerGUID) or (destGUID == playerGUID)
        if not isPlayer then return end

        local dir = (srcGUID == playerGUID) and "OUT" or "IN"
        local argStr = ""
        for i = 12, math.min(select("#", GetInfo()), 19) do
            argStr = argStr .. " " .. tostring(select(i, GetInfo()))
        end

        print("|cffff9900KSBT-Probe|r [" .. dir .. "] " .. tostring(sub)
            .. " src=" .. tostring(srcName)
            .. " dst=" .. tostring(destName)
            .. argStr)
    end)

    -- Only attempt CLEU registration if the API exists (removed in Midnight).
    if GetInfo then
        _eventProbeFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    else
        self:Print("CLEU event probe: combat log API not available in this client")
    end

    self:Print(("CLEU event probe STARTED for %ds. Attack something or take damage."):format(seconds))

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
-- Outgoing Probe (#3)
-- Reports registration status and dumps UNIT_COMBAT "target" events
-- to chat. Helps diagnose why outgoing combat text isn't working.
------------------------------------------------------------------------
local _outProbeFrame = nil
local _outProbeTimer = nil

function Addon:StartOutgoingProbe(secondsStr)
    local seconds = tonumber(secondsStr) or 30
    if seconds < 5 then seconds = 5 end
    if seconds > 60 then seconds = 60 end

    if _outProbeFrame then
        self:Print("Outgoing probe already running. Use '/ksbt probeout stop'.")
        return
    end

    -- Report current registration status
    local cl = KSBT.Parser and KSBT.Parser.CombatLog
    self:Print("|cffff9900=== Outgoing Diagnostic ===|r")
    self:Print("  CLEU registered: " .. tostring(cl and cl._cleuRegistered or "N/A"))
    self:Print("  UNIT_COMBAT registered: " .. tostring(cl and cl._ucRegistered or "N/A"))
    self:Print("  CombatLog enabled: " .. tostring(cl and cl._enabled or "N/A"))
    self:Print("  CombatLogGetCurrentEventInfo: " .. tostring(CombatLogGetCurrentEventInfo ~= nil))
    self:Print("  C_CombatLog.GetCurrentEventInfo: " .. tostring(C_CombatLog and C_CombatLog.GetCurrentEventInfo ~= nil or false))
    self:Print("  RegisterUnitEvent exists: " .. tostring(CreateFrame("Frame").RegisterUnitEvent ~= nil))

    -- Create a fresh probe frame for UNIT_COMBAT on target
    _outProbeFrame = CreateFrame("Frame")
    _outProbeFrame:SetScript("OnEvent", function(_, event, unit, action, indicator, amount, school)
        if event == "UNIT_COMBAT" then
            print(("|cff00ff00KSBT-OutProbe|r UC unit=%s action=%s ind=%s amt=%s school=%s"):format(
                tostring(unit), tostring(action), tostring(indicator),
                tostring(amount), tostring(school)))
        elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
            print(("|cff00ff00KSBT-OutProbe|r SPELL unit=%s spellId=%s"):format(
                tostring(unit), tostring(indicator)))
        end
    end)

    -- Try multiple registration approaches and report which works
    local ucOk = pcall(function()
        if _outProbeFrame.RegisterUnitEvent then
            _outProbeFrame:RegisterUnitEvent("UNIT_COMBAT", "player", "target")
        else
            _outProbeFrame:RegisterEvent("UNIT_COMBAT")
        end
    end)
    self:Print("  Probe UNIT_COMBAT register: " .. (ucOk and "|cff00ff00OK|r" or "|cffff4444FAILED|r"))

    -- Also try registering UNIT_COMBAT for target only
    if not ucOk then
        local ucOk2 = pcall(function()
            _outProbeFrame:RegisterUnitEvent("UNIT_COMBAT", "target")
        end)
        self:Print("  Probe UC target-only register: " .. (ucOk2 and "|cff00ff00OK|r" or "|cffff4444FAILED|r"))
    end

    -- Try plain RegisterEvent as fallback
    if not ucOk then
        local ucOk3 = pcall(function()
            _outProbeFrame:RegisterEvent("UNIT_COMBAT")
        end)
        self:Print("  Probe UC plain register: " .. (ucOk3 and "|cff00ff00OK|r" or "|cffff4444FAILED|r"))
    end

    self:Print(("Outgoing probe STARTED for %ds. Target something and attack."):format(seconds))

    _outProbeTimer = C_Timer.After(seconds, function()
        Addon:StopOutgoingProbe(true)
    end)
end

function Addon:StopOutgoingProbe(auto)
    if not _outProbeFrame then
        self:Print("Outgoing probe is not running.")
        return
    end
    _outProbeFrame:UnregisterAllEvents()
    _outProbeFrame:SetScript("OnEvent", nil)
    _outProbeFrame = nil
    _outProbeTimer = nil
    self:Print("Outgoing probe " .. (auto and "ended (timeout)." or "stopped."))
end
