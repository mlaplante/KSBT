------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Minimap Button (simple native implementation, no LDB)
-- Left Click:  Open config
-- Right Click: Close config (if open)
-- Middle Click: Toggle KSBT enabled/disabled
-- Drag (Left): Move around minimap ring
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

KSBT.Core = KSBT.Core or {}
KSBT.Core.Minimap = KSBT.Core.Minimap or {}
local MM = KSBT.Core.Minimap
local Addon = KSBT.Addon

local BUTTON_NAME = "KrothSBT_MinimapButton"

-- Built-in "gear-ish" icon (no media shipped)
local ICON_TEXTURE = "Interface\\Buttons\\UI-OptionsButton"

local RADIUS = 80

local function clampAngle(a)
    if a == nil then return 220 end
    a = a % 360
    if a < 0 then a = a + 360 end
    return a
end

local function angleToXY(angle)
    local rad = math.rad(angle)
    local x = math.cos(rad) * RADIUS
    local y = math.sin(rad) * RADIUS
    return x, y
end

local function cursorAngleFromMinimap()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale

    local dx = cx - mx
    local dy = cy - my
    local angle = math.deg(math.atan2(dy, dx))
    return clampAngle(angle)
end

function MM:ApplyPosition()
    if not self.button or not KSBT.db then return end

    local angle = clampAngle(KSBT.db.profile.general.minimap.angle)
    local x, y = angleToXY(angle)

    -- Critical: clear points first to avoid anchor-family conflicts.
    self.button:ClearAllPoints()
    self.button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function MM:UpdateVisibility()
    if not self.button or not KSBT.db then return end
    if KSBT.db.profile.general.minimap.hide then
        self.button:Hide()
    else
        self.button:Show()
        self:ApplyPosition()
    end
end

function MM:SetHidden(hidden)
    if not KSBT.db then return end
    KSBT.db.profile.general.minimap.hide = hidden and true or false
    self:UpdateVisibility()
end

function MM:Init()
    if self.button then
        self:UpdateVisibility()
        return
    end

    if not Minimap or not KSBT.db or not KSBT.db.profile or not KSBT.db.profile.general then return end

    local b = CreateFrame("Button", BUTTON_NAME, Minimap)
    b:SetSize(32, 32)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)

    -- Icon (gear)
    b:SetNormalTexture(ICON_TEXTURE)
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")

    local tex = b:GetNormalTexture()
    if tex then
        tex:SetTexCoord(0.1, 0.9, 0.1, 0.9)
    end

    b:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
    b:RegisterForDrag("LeftButton")

    --------------------------------------------------------------------
    -- Tooltip (attach ONCE; not inside OnClick)
    --------------------------------------------------------------------
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:ClearLines()

        GameTooltip:AddLine("Kroth's Scrolling Battle Text", 1, 1, 1)
        GameTooltip:AddLine(" ")

        GameTooltip:AddLine("Left-Click:", 0.9, 0.9, 0.9)
        GameTooltip:AddLine("  Open configuration", 1, 1, 1)

        GameTooltip:AddLine("Right-Click:", 0.9, 0.9, 0.9)
        GameTooltip:AddLine("  Close configuration", 1, 1, 1)

        GameTooltip:AddLine("Middle-Click:", 0.9, 0.9, 0.9)
        GameTooltip:AddLine("  Toggle Enable KSBT", 1, 1, 1)

        GameTooltip:Show()
    end)

    b:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    --------------------------------------------------------------------
    -- Dragging: constrained to minimap ring (no StartMoving)
    --------------------------------------------------------------------
    b:SetScript("OnDragStart", function(self)
        self.isDragging = true
        self:SetScript("OnUpdate", function()
            local angle = cursorAngleFromMinimap()
            KSBT.db.profile.general.minimap.angle = angle
            MM:ApplyPosition()
        end)
    end)

    b:SetScript("OnDragStop", function(self)
        self.isDragging = false
        self:SetScript("OnUpdate", nil)
        -- position already saved continuously
    end)

    --------------------------------------------------------------------
    -- Click behavior
    --------------------------------------------------------------------
    b:SetScript("OnClick", function(_, btn)
        local g = KSBT.db.profile.general

        -- Left click: open config
        if btn == "LeftButton" then
            if Addon and Addon.OpenConfig then
                Addon:OpenConfig()
            end
            return
        end

        -- Right click: close config (if open)
        if btn == "RightButton" then
            if Addon and Addon.configDialog then
                local frame = Addon.configDialog.OpenFrames
                    and Addon.configDialog.OpenFrames["KrothSBT"]

                if frame and frame.frame then
                    frame.frame.tsbtAllowClose = true
                    frame.frame:Hide()
                    frame.frame.tsbtAllowClose = false
                end
            end
            return
        end

        -- Middle click: toggle addon enabled/disabled
        if btn == "MiddleButton" then
            g.enabled = not g.enabled

            if KSBT.Core and KSBT.Core.Enable and KSBT.Core.Disable then
                if g.enabled then
                    KSBT.Core:Enable()
                else
                    KSBT.Core:Disable()
                end
            end

            if Addon and Addon.Print then
                Addon:Print(("KSBT %s."):format(g.enabled and "enabled" or "disabled"))
            end

            -- Refresh config UI if it's open so checkbox updates immediately.
            local ACR = LibStub("AceConfigRegistry-3.0", true)
            if ACR then
                ACR:NotifyChange("KrothSBT")
            end

            return
        end
    end)

    self.button = b
    self:UpdateVisibility()
end
