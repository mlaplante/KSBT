------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Display Decision Layer
-- Responsibility: accept "emit requests" and route to the active render
-- system.
--
-- For now (UI/UX harness phase): use ScrollAreaFrames.lua test renderer
-- (TSBT.FireTestText) as the common animation sink.
------------------------------------------------------------------------

local ADDON_NAME, TSBT = ...

TSBT.Core = TSBT.Core or {}
TSBT.Core.Display = TSBT.Core.Display or {}
local Display = TSBT.Core.Display
local Addon   = TSBT.Addon

function Display:Enable()
    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(1, "Display:Enable()")
    end
end

function Display:Disable()
    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(1, "Display:Disable()")
    end
end

-- Primary contract: engine calls this to request output.
function Display:Emit(areaName, text, color, meta)
    -- Global gating (Enable KSBT + Combat Only Mode)
    if TSBT.Core and TSBT.Core.ShouldEmitNow and not TSBT.Core:ShouldEmitNow() then
        return
    end

    if not (areaName and text) then
        return
    end

    local profile = TSBT.db and TSBT.db.profile
    local area = profile and profile.scrollAreas and profile.scrollAreas[areaName] or nil
    if not area then
        -- Safe fallback: chat-only when a scroll area is missing
        if Addon and Addon.Print then
            Addon:Print(("%s [%s]"):format(text, areaName))
        end
        return
    end

    -- Require the test renderer (ScrollAreaFrames.lua)
    if type(TSBT.FireTestText) ~= "function" then
        if Addon and Addon.Print then
            Addon:Print(("%s [%s]"):format(text, areaName))
        end
        return
    end

    local fontFace, fontSize, outlineFlag, fontAlpha = TSBT.ResolveFontForArea(areaName)
    local anchorH = (area.alignment == "Left" and "LEFT") or (area.alignment == "Right" and "RIGHT") or "CENTER"
    local dirMult = (area.direction == "Down") and -1 or 1
    local speed = tonumber(area.animSpeed) or 1.0
    if speed <= 0 then speed = 1.0 end
    local duration = 1.2 / speed

    TSBT.FireTestText(areaName, text, area, fontFace, fontSize, outlineFlag, fontAlpha,
        anchorH, dirMult, duration, color)
end

-- Shared school color resolver. Returns {r,g,b} or nil.
-- Single-bit schoolMask only; multi-school masks return nil.
-- Physical (0x1) returns nil — use kind-based color (red/green) for physical.
-- Reads from profile.media.schoolColors when configured.
function TSBT.SchoolColorFromMask(mask)
    if type(mask) ~= "number" or mask <= 0 then return nil end
    local band = bit and bit.band
    if type(band) ~= "function" then return nil end
    -- Multi-school: skip
    if band(mask, mask - 1) ~= 0 then return nil end
    -- Physical: no school color
    if mask == TSBT.SCHOOL_PHYSICAL then return nil end

    local profile = TSBT.db and TSBT.db.profile
    local sc = profile and profile.media and profile.media.schoolColors

    if mask == TSBT.SCHOOL_HOLY   then return sc and sc.holy   or {r=1.00,g=0.90,b=0.50} end
    if mask == TSBT.SCHOOL_FIRE   then return sc and sc.fire   or {r=1.00,g=0.30,b=0.00} end
    if mask == TSBT.SCHOOL_NATURE then return sc and sc.nature or {r=0.30,g=1.00,b=0.30} end
    if mask == TSBT.SCHOOL_FROST  then return sc and sc.frost  or {r=0.40,g=0.80,b=1.00} end
    if mask == TSBT.SCHOOL_SHADOW then return sc and sc.shadow or {r=0.60,g=0.20,b=1.00} end
    if mask == TSBT.SCHOOL_ARCANE then return sc and sc.arcane or {r=1.00,g=0.50,b=1.00} end
    return nil
end

-- Backward-compat contract
if TSBT.DisplayText == nil then
    function TSBT.DisplayText(areaName, text, color, meta)
        return Display:Emit(areaName, text, color, meta)
    end
end
