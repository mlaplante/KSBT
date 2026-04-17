------------------------------------------------------------------------
--  UI/DebugFrame.lua – Scrollable diagnostic window for spell learning
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

-- ── Module ──────────────────────────────────────────────────
local DebugLog = {}
KSBT.DebugLog  = DebugLog

local _frame
local _scrollFrame
local _level = 0  -- debug level (0=off, 1-3 = increasing verbosity)

-- Color table: name → {r, g, b}
local COLORS = {
    green  = { 0.0, 1.0, 0.0 },
    yellow = { 1.0, 1.0, 0.0 },
    cyan   = { 0.0, 1.0, 1.0 },
    orange = { 1.0, 0.6, 0.0 },
    red    = { 1.0, 0.3, 0.3 },
    gray   = { 0.6, 0.6, 0.6 },
    white  = { 1.0, 1.0, 1.0 },
}

------------------------------------------------------------------------
--  Create the debug frame (lazy, called on first show)
------------------------------------------------------------------------
local function EnsureFrame()
    if _frame then return end

    -- Main frame
    local f = CreateFrame("Frame", "KSBTDebugFrame", UIParent, "BackdropTemplate")
    f:SetSize(500, 350)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:SetResizable(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(300, 200, 800, 600)
    end
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")

    -- Backdrop
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })

    -- Title bar drag region
    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetHeight(24)
    titleBar:SetPoint("TOPLEFT", 4, -4)
    titleBar:SetPoint("TOPRIGHT", -4, -4)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
    titleBar:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        DebugLog:SavePosition()
    end)

    -- Title text
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", 8, 0)
    title:SetText("KSBT Spell Learning Debug")
    title:SetTextColor(0.29, 0.62, 1.0)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Clear button
    local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearBtn:SetSize(60, 20)
    clearBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -4, -4)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function()
        if _scrollFrame then
            _scrollFrame:Clear()
        end
    end)

    -- Scrolling message frame
    local sf = CreateFrame("ScrollingMessageFrame", nil, f)
    sf:SetPoint("TOPLEFT", 8, -32)
    sf:SetPoint("BOTTOMRIGHT", -28, 8)
    sf:SetFontObject(GameFontNormalSmall)
    sf:SetJustifyH("LEFT")
    sf:SetMaxLines(KSBT.DIAG_MAX_ENTRIES or 1000)
    sf:SetFading(false)
    sf:SetInsertMode("BOTTOM")
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then
            self:ScrollUp()
        else
            self:ScrollDown()
        end
    end)

    -- Resize grip
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        DebugLog:SavePosition()
    end)

    _frame       = f
    _scrollFrame = sf

    -- Restore saved position
    DebugLog:RestorePosition()

    f:Hide()
end

------------------------------------------------------------------------
--  Add a message to the debug frame
--  level: minimum debug level for this message (1-3)
--  color: "green", "yellow", "cyan", "orange", "red", "gray"
--  msg:   the text string
------------------------------------------------------------------------
function DebugLog:Add(level, color, msg)
    if _level < level then return end
    if not _scrollFrame then return end

    local c = COLORS[color] or COLORS.white
    local timestamp = date("%H:%M:%S")
    _scrollFrame:AddMessage(
        string.format("|cff888888%s|r %s", timestamp, msg),
        c[1], c[2], c[3]
    )
end

------------------------------------------------------------------------
--  Toggle visibility
------------------------------------------------------------------------
function DebugLog:Toggle()
    EnsureFrame()
    if _frame:IsShown() then
        _frame:Hide()
    else
        _frame:Show()
    end
end

------------------------------------------------------------------------
--  Set debug level
------------------------------------------------------------------------
function DebugLog:SetLevel(level)
    _level = tonumber(level) or 0
    if _level < 0 then _level = 0 end
    if _level > 3 then _level = 3 end
    print("|cFF4A9EFFKSBT|r Debug level set to " .. _level)
end

function DebugLog:GetLevel()
    return _level
end

------------------------------------------------------------------------
--  Position persistence (uses KSBT_SpellFingerprints.debugFramePos)
------------------------------------------------------------------------
function DebugLog:SavePosition()
    if not _frame then return end
    KSBT_SpellFingerprints = KSBT_SpellFingerprints or {}
    local point, _, relPoint, x, y = _frame:GetPoint()
    local w, h = _frame:GetSize()
    KSBT_SpellFingerprints.debugFramePos = {
        point = point, relPoint = relPoint,
        x = x, y = y, w = w, h = h,
    }
end

function DebugLog:RestorePosition()
    if not _frame then return end
    KSBT_SpellFingerprints = KSBT_SpellFingerprints or {}
    local pos = KSBT_SpellFingerprints.debugFramePos
    if pos then
        _frame:ClearAllPoints()
        _frame:SetPoint(pos.point or "CENTER", UIParent, pos.relPoint or "CENTER",
            pos.x or 0, pos.y or 0)
        if pos.w and pos.h then
            _frame:SetSize(pos.w, pos.h)
        end
    end
end
