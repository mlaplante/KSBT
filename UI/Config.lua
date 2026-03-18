------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Configuration UI
-- Builds the master AceConfig-3.0 options table with all 8 tabs.
-- Each tab is constructed in ConfigTabs.lua and assembled here.
------------------------------------------------------------------------

local ADDON_NAME, KSBT = ...
local Addon = KSBT.Addon
local LSM = LibStub("LibSharedMedia-3.0")

------------------------------------------------------------------------
-- Helper: Build a dropdown values table from a key/value table
------------------------------------------------------------------------
function KSBT.ValuesFromKeys(tbl)
    local out = {}
    for k, _ in pairs(tbl) do
        out[k] = k
    end
    return out
end

------------------------------------------------------------------------
-- Helper: Get available scroll area names from current profile
------------------------------------------------------------------------
function KSBT.GetScrollAreaNames()
    local names = {}
    if KSBT.db and KSBT.db.profile and KSBT.db.profile.scrollAreas then
        for name, _ in pairs(KSBT.db.profile.scrollAreas) do
            names[name] = name
        end
    end
    return names
end

------------------------------------------------------------------------
-- Helper: Build font dropdown values from LibSharedMedia
-- Returns a table suitable for AceConfig select "values".
-- Uses standard select type - no LSM30_Font widget required.
------------------------------------------------------------------------
function KSBT.BuildFontDropdown()
    local fonts = {}
    if LSM then
        for _, name in ipairs(LSM:List("font")) do
            fonts[name] = name
        end
    end
    -- Ensure default WoW font is always present
    if not fonts["Friz Quadrata TT"] then
        fonts["Friz Quadrata TT"] = "Friz Quadrata TT"
    end
    return fonts
end

------------------------------------------------------------------------
-- Helper: Build sound dropdown values from LibSharedMedia
-- Returns a table suitable for AceConfig select "values".
-- Uses standard select type - no LSM30_Sound widget required.
-- Always includes a "None" option at the top.
------------------------------------------------------------------------
function KSBT.BuildSoundDropdown()
    local sounds = { ["None"] = "None" }
    if LSM then
        for _, name in ipairs(LSM:List("sound")) do
            sounds[name] = name
        end
    end
    return sounds
end

------------------------------------------------------------------------
-- Helper: Play an LSM sound by key name
-- Used by "Test" buttons next to sound dropdowns.
------------------------------------------------------------------------
function KSBT.PlayLSMSound(soundKey)
    if not soundKey or soundKey == "None" then return end
    if not LSM then return end
    local path = LSM:Fetch("sound", soundKey)
    if path then
        PlaySoundFile(path, "Master")
    end
end

------------------------------------------------------------------------
-- Build the complete options table
-- Called once during OnInitialize.
-- Profiles tab is injected by Init.lua after DB creation.
------------------------------------------------------------------------
function KSBT.BuildOptionsTable()
    -- Ensure ConfigTabs has been loaded
    assert(KSBT.BuildTab_General, "ConfigTabs.lua must be loaded before Config.lua")

    local options = {
        type = "group",
        name = "|cFF4A9EFF\226\154\148|r Kroth's Scrolling Battle Text",
        childGroups = "tab",
        args = {
            ----------------------------------------------------------------
            -- Tab 1: General
            ----------------------------------------------------------------
            general = KSBT.BuildTab_General(),

            ----------------------------------------------------------------
            -- Tab 2: Scroll Areas
            ----------------------------------------------------------------
            scrollAreas = KSBT.BuildTab_ScrollAreas(),

            ----------------------------------------------------------------
            -- Tab 3: Incoming
            ----------------------------------------------------------------
            incoming = KSBT.BuildTab_Incoming(),

            ----------------------------------------------------------------
            -- Tab 4: Outgoing
            ----------------------------------------------------------------
            outgoing = KSBT.BuildTab_Outgoing(),

            ----------------------------------------------------------------
            -- Tab 5: Pets
            ----------------------------------------------------------------
            pets = KSBT.BuildTab_Pets(),

            ----------------------------------------------------------------
            -- Tab 6: Spam Control
            ----------------------------------------------------------------
            spamControl = KSBT.BuildTab_SpamControl(),

            ----------------------------------------------------------------
            -- Tab 7: Cooldowns
            ----------------------------------------------------------------
            cooldowns = KSBT.BuildTab_Cooldowns(),

            ----------------------------------------------------------------
            -- Tab 8: Media
            ----------------------------------------------------------------
            media = KSBT.BuildTab_Media(),

            ----------------------------------------------------------------
            -- Tab 9: Spell Filters
            ----------------------------------------------------------------
            spellFilters = KSBT.BuildTab_SpellFilters(),

            ----------------------------------------------------------------
            -- Profiles tab placeholder (injected by Init.lua after DB init)
            ----------------------------------------------------------------
        },
    }

    return options
end

------------------------------------------------------------------------
-- ElvUI Detection
-- Returns true if ElvUI is loaded and active.
--
-- We use _G["ElvUI"] as the primary check: ElvUI always registers itself
-- as a global table on load, making this the most reliable and version-
-- agnostic method (works on all WoW builds including Midnight 12.0).
-- As a belt-and-suspenders fallback we also check C_AddOns (12.0+) and
-- the legacy IsAddOnLoaded global (pre-12.0).
------------------------------------------------------------------------
local function IsElvUIActive()
    if _G["ElvUI"] ~= nil then return true end

    -- Fallback: addon-loaded API (version-safe)
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        return C_AddOns.IsAddOnLoaded("ElvUI") == true
    end

    -- Legacy pre-12.0 fallback
    if IsAddOnLoaded then
        return IsAddOnLoaded("ElvUI") == true
    end

    return false
end

------------------------------------------------------------------------
-- Strike Silver Styling
-- Hooks into AceConfigDialog:Open to apply custom backdrop and colors
-- to the configuration window after it's created by Ace3.
--
-- Design targets:
--   Background: Dark gunmetal (#1F2938), 95% opacity
--   Borders:    Chrome silver (#8B98A8), 2-3px, consistent everywhere
--   Active tab: Electric Blue (#4A9EFF)
--   Inactive:   Light Silver (#C0C0C0)
--
-- ElvUI compatibility:
--   When ElvUI is active it skins ALL AceGUI frames through its own
--   comprehensive skinning system. KSBT's custom styling would fight
--   with ElvUI's system, contaminate the shared AceGUI widget pool,
--   and leave visual artifacts on ElvUI's own option windows.
--
--   Therefore: if ElvUI is detected, ApplyStrikeSilverStyling() is a
--   no-op. ElvUI will apply its own skin to the KSBT config window
--   automatically, just as it does for every other AceConfigDialog
--   window. No cleanup hooks are needed because nothing was changed.
--
-- Cleanup strategy (non-ElvUI only):
--   We hook frame.frame:Hide() via hooksecurefunc inside the Open hook.
--   This fires on every real hide regardless of how the window was
--   closed, and runs before AceGUI releases widgets back to the pool,
--   giving us a guaranteed cleanup window to reset all backdrop colors
--   and ownership flags.
------------------------------------------------------------------------

-- Track whether we've already hooked (prevent double-hooking)
local strikeSilverHooked = false

-- Border sizes for rounded vs sharp borders
local BORDER_SIZE_SHARP   = 2
local BORDER_SIZE_ROUNDED = 20  -- Thicker border with better rounding visibility
local BORDER_INSET        = 3   -- No gap between blue frame and border

function KSBT.ApplyStrikeSilverStyling()
    ------------------------------------------------------------------------
    -- ElvUI guard: if ElvUI is active, skip ALL custom styling entirely.
    -- ElvUI owns the AceGUI widget pool and will skin the KSBT window
    -- through its own system. Any backdrop changes KSBT makes here would
    -- leak back into ElvUI's own option windows when the widgets are
    -- returned to the shared pool.
    ------------------------------------------------------------------------
    if IsElvUIActive() then return end

    if strikeSilverHooked then return end
    strikeSilverHooked = true

    local ACD = LibStub("AceConfigDialog-3.0", true)
    if not ACD then return end

    -- Hook Open so we can style the frame each time it appears
    hooksecurefunc(ACD, "Open", function(self, appName)
        if appName ~= "KrothSBT" then return end

        -- AceConfigDialog stores open frames in self.OpenFrames[appName]
        local frame = self.OpenFrames[appName]
        if not frame or not frame.frame then return end

        -- Mark this AceGUI frame tree as owned by us so hooks become
        -- no-ops once the widgets return to the shared pool.
        frame.ksbtOwned = true

        local f = frame.frame  -- The actual WoW frame widget
        local dk = KSBT.COLORS.DARK
        local border = KSBT.COLORS.BORDER

        -- Apply Strike Silver backdrop to main frame
        if not f.tsbtStyled then
            -- Ensure frame supports backdrops
            if not f.SetBackdrop then
                Mixin(f, BackdropTemplateMixin)
            end

            f:SetBackdrop({
                bgFile   = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = BORDER_SIZE_ROUNDED,
                insets   = { left = BORDER_INSET, right = BORDER_INSET,
                             top = BORDER_INSET, bottom = BORDER_INSET },
            })

            -- Frame background: Dark gunmetal
            f:SetBackdropColor(dk.r, dk.g, dk.b, 0.95)

            -- Border: Chrome silver - visible on dark background
            f:SetBackdropBorderColor(border.r, border.g, border.b, 1.0)

            -- Style the title bar text if present
            local titleRegion = f.GetTitleRegion and f:GetTitleRegion()
            if not titleRegion then
                -- AceConfigDialog title is typically a FontString child
                for _, region in pairs({ f:GetRegions() }) do
                    if region:IsObjectType("FontString") then
                        local text = region:GetText()
                        if text and text:find("KrothSBT") then
                            region:SetTextColor(KSBT.COLORS.TEXT_LIGHT.r,
                                                KSBT.COLORS.TEXT_LIGHT.g,
                                                KSBT.COLORS.TEXT_LIGHT.b, 1.0)
                        end
                    end
                end
            end

            f.tsbtStyled = true
        end

        -- Style the tab buttons each time Open fires
        KSBT.StyleTabButtons(frame)

        -- Style inner content containers (section borders, tab bar, etc.)
        KSBT.StyleInnerContainers(frame)

        -- Keep confirmation popups above the AceConfig window.
        if KSBT.EnsurePopupsOnTop then
            KSBT.EnsurePopupsOnTop(f)
        end

        ------------------------------------------------------------------------
        -- Reliable cleanup: hook frame.frame:Hide() via hooksecurefunc.
        --
        -- WHY NOT hooksecurefunc(ACD, "Close")?
        --   AceConfigDialog:Close() only sets a closing flag and schedules
        --   a Hide via OnUpdate. In practice the config window is often closed
        --   by calling frame:Hide() directly (e.g. the Close-button override
        --   in Init.lua calls origHide, bypassing ACD:Close entirely). The
        --   ACD:Close hook therefore fires either never or too early.
        --
        -- WHY hooksecurefunc on f.Hide?
        --   hooksecurefunc appends our function after every call to f:Hide(),
        --   regardless of how Hide was reached. It fires before AceGUI's
        --   OnHide -> OnClose -> Release chain removes widgets from the tree,
        --   so frame.children is still intact when we run ClearOwnership.
        --   The ksbtOwned guard in all SelectTab hooks ensures that after
        --   Release the hooks are no-ops for other addons' widgets.
        ------------------------------------------------------------------------
        if not f.tsbtHideHooked then
            f.tsbtHideHooked = true

            hooksecurefunc(f, "Hide", function(self)
                -- Reset drag-drop hook state so next open re-hooks cleanly
                if KSBT.ResetDragDropInline then
                    KSBT.ResetDragDropInline()
                end

                -- Reset main frame backdrop to neutral so pooled AceGUI
                -- frames don't carry KSBT's colors into other addons.
                if self.SetBackdrop then
                    self:SetBackdrop(nil)
                end
                if self.SetBackdropColor then
                    self:SetBackdropColor(0, 0, 0, 0.9)
                    self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1.0)
                end
                self.tsbtStyled = nil

                -- Walk the AceGUI widget tree and clear ownership flags,
                -- tab-hook guards, and all border backdrop colors/textures.
                local aceFrame = ACD.OpenFrames and ACD.OpenFrames["KrothSBT"]
                if aceFrame then
                    KSBT.ClearOwnership(aceFrame)
                end
            end)
        end
    end)
end

------------------------------------------------------------------------
-- Clear KSBT ownership flags and backdrop colors/textures from an
-- AceGUI widget tree. Once cleared, hooksecurefunc hooks installed on
-- pooled widgets become no-ops (via ksbtOwned guard), preventing style
-- bleed into other addons that reuse widgets from the AceGUI pool.
------------------------------------------------------------------------
function KSBT.ClearOwnership(widget)
    if not widget then return end
    widget.ksbtOwned = nil

    -- Reset border frame: remove the backdrop texture entirely (SetBackdrop nil)
    -- AND reset colors. Resetting only the color is not enough - the edgeFile
    -- texture (UI-Tooltip-Border) would remain visible on ElvUI's InlineGroup
    -- containers even with a transparent color.
    if widget.border then
        widget.border.tsbtStyled = nil
        if widget.border.SetBackdrop then
            widget.border:SetBackdrop(nil)
        end
        if widget.border.SetBackdropColor then
            widget.border:SetBackdropColor(0, 0, 0, 0)
            widget.border:SetBackdropBorderColor(1, 1, 1, 1)
        end
    end

    -- Clear the styled flag on the underlying WoW frame so the next
    -- Open() call re-applies KSBT styling from scratch.
    if widget.frame then
        widget.frame.tsbtStyled = nil
    end

    -- Clear the tab-hook guard so it can be re-registered if the widget
    -- is re-acquired from the pool for a future KSBT open.
    if widget.tsbtTabHooked then
        widget.tsbtTabHooked = nil
    end

    -- Recurse into children (TabGroup, InlineGroups, etc.)
    if widget.children then
        for _, child in ipairs(widget.children) do
            KSBT.ClearOwnership(child)
        end
    end
end

------------------------------------------------------------------------
-- Style tab buttons with Strike Silver colors
-- Finds the AceGUI TabGroup child and applies accent color to active tab.
------------------------------------------------------------------------
function KSBT.StyleTabButtons(aceFrame)
    if not aceFrame then return end

    -- The AceGUI Frame widget has children; the first is typically the TabGroup
    local tabGroup = nil
    if aceFrame.children then
        for _, child in ipairs(aceFrame.children) do
            if child.type == "TabGroup" then
                tabGroup = child
                break
            end
        end
    end

    if not tabGroup or not tabGroup.tabs then return end

    -- Propagate ownership flag to the TabGroup so hooks check it
    tabGroup.ksbtOwned = true

    local accent    = KSBT.COLORS.ACCENT
    local tabInactive = KSBT.COLORS.TAB_INACTIVE
    local border    = KSBT.COLORS.BORDER

    -- Style tab button backgrounds and text
    for _, tab in ipairs(tabGroup.tabs) do
        if tab and tab.GetFontString then
            local fs = tab:GetFontString()
            if fs then
                -- Default: Pure white for readability on dark background
                fs:SetTextColor(tabInactive.r, tabInactive.g, tabInactive.b, 1.0)
            end
        end
    end

    -- Hook tab selection to recolor active tab with accent.
    -- Guard: only apply colors while this widget is owned by us;
    -- once released to the AceGUI pool the hook becomes a no-op.
    if not tabGroup.tsbtTabHooked then
        tabGroup.tsbtTabHooked = true

        hooksecurefunc(tabGroup, "SelectTab", function(self, tabValue)
            if not self.ksbtOwned then return end
            if not self.tabs then return end

            -- Reset drag-drop hook on tab switch so it re-hooks on next render
            if KSBT.ResetDragDropInline then
                KSBT.ResetDragDropInline()
            end

            for _, tab in ipairs(self.tabs) do
                local fs = tab:GetFontString()
                if fs then
                    if tab.value == tabValue then
                        -- Active tab: Electric Blue accent
                        fs:SetTextColor(accent.r, accent.g, accent.b, 1.0)
                    else
                        -- Inactive tab: Pure white (#FFFFFF) - full opacity
                        fs:SetTextColor(tabInactive.r, tabInactive.g, tabInactive.b, 1.0)
                    end
                end
            end
        end)
    end

    -- Style the tab bar container backdrop if the border frame exists
    if tabGroup.border then
        local tabBorder = tabGroup.border
        if not tabBorder.SetBackdrop then
            Mixin(tabBorder, BackdropTemplateMixin)
        end
        tabBorder:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = BORDER_SIZE_ROUNDED,
            insets   = { left = BORDER_INSET, right = BORDER_INSET,
                         top = BORDER_INSET, bottom = BORDER_INSET },
        })
        local dk = KSBT.COLORS.DARK
        tabBorder:SetBackdropColor(dk.r, dk.g, dk.b, 0.8)
        tabBorder:SetBackdropBorderColor(border.r, border.g, border.b, 1.0)
        tabBorder.tsbtStyled = true
    end
end

------------------------------------------------------------------------
-- Style inner containers: section borders, scrollable content areas
-- Recursively walks AceGUI children to find InlineGroup/BlizOptionsGroup
-- and applies consistent chrome borders.
------------------------------------------------------------------------
function KSBT.StyleInnerContainers(aceFrame)
    if not aceFrame or not aceFrame.children then return end

    local dk     = KSBT.COLORS.DARK
    local border = KSBT.COLORS.BORDER

    local function styleChild(widget)
        -- InlineGroup and similar containers have a .border frame
        if widget.border then
            local b = widget.border
            if not b.tsbtStyled then
                if not b.SetBackdrop then
                    Mixin(b, BackdropTemplateMixin)
                end
                b:SetBackdrop({
                    bgFile   = "Interface\\Buttons\\WHITE8X8",
                    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    edgeSize = BORDER_SIZE_ROUNDED,
                    insets   = { left = BORDER_INSET, right = BORDER_INSET,
                                 top = BORDER_INSET, bottom = BORDER_INSET },
                })
                -- Slightly lighter than main background for depth
                b:SetBackdropColor(dk.r * 1.15, dk.g * 1.15, dk.b * 1.15, 0.9)
                b:SetBackdropBorderColor(border.r, border.g, border.b, 1.0)
                b.tsbtStyled = true
            end
        end

        -- Recurse into children
        if widget.children then
            for _, child in ipairs(widget.children) do
                styleChild(child)
            end
        end
    end

    for _, child in ipairs(aceFrame.children) do
        styleChild(child)
    end
end

------------------------------------------------------------------------
-- Popup / Z-Order Safety
-- Ensure StaticPopup confirmations don't hide behind the AceConfig frame.
------------------------------------------------------------------------

local popupsOnTopHooked = false

local function RaiseStaticPopupFrame(popupFrame, anchorFrame)
    if not popupFrame then return end
    popupFrame:SetFrameStrata("FULLSCREEN_DIALOG")

    local baseLevel = 0
    if anchorFrame and anchorFrame.GetFrameLevel then
        baseLevel = anchorFrame:GetFrameLevel() or 0
    end
    popupFrame:SetFrameLevel(baseLevel + 200)

    if popupFrame.SetToplevel then
        popupFrame:SetToplevel(true)
    end
end

function KSBT.EnsurePopupsOnTop(anchorFrame)
    if popupsOnTopHooked then return end
    popupsOnTopHooked = true

    if not StaticPopup_Show then return end

    hooksecurefunc("StaticPopup_Show", function()
        -- Only raise popups when our config window is open; modifying
        -- Blizzard's StaticPopup frames from addon code taints them,
        -- which blocks protected functions like UpgradeItem().
        if not anchorFrame or not anchorFrame:IsShown() then return end
        for i = 1, (STATICPOPUP_NUMDIALOGS or 4) do
            local f = _G["StaticPopup" .. i]
            if f and f:IsShown() then
                RaiseStaticPopupFrame(f, anchorFrame)
            end
        end
    end)
end

------------------------------------------------------------------------
-- Cooldown Drag-and-Drop (native AceGUI integration)
--
-- Instead of a floating WoW frame that hovers above the UI, we find
-- the actual FontString frame that AceGUI renders for the
-- "dragDropInline" description widget and enable drag-receiving on it.
-- This makes the drag zone sit exactly where AceGUI placed the text,
-- pushing other widgets down naturally like any other description widget.
--
-- Called via C_Timer.After(0) from the description widget's name()
-- function, so AceGUI has finished laying out the frame before we hook.
------------------------------------------------------------------------

local dragHookInstalled = false   -- true once EnableMouse/scripts are set
local dragTargetFrame   = nil     -- the AceGUI frame we hooked

local function HandleSpellDrop(cursorType, id, subType)
    if cursorType == "spell" then
        local spellID = nil
        if subType == "spell" or subType == "pet" then
            if C_SpellBook and C_SpellBook.GetSpellBookItemInfo then
                local bank = (subType == "pet") and Enum.SpellBookSpellBank.Pet
                                                 or Enum.SpellBookSpellBank.Player
                local info = C_SpellBook.GetSpellBookItemInfo(id, bank)
                if info then spellID = info.spellID end
            end
        else
            spellID = id
        end
        if spellID and spellID > 0 then
            if not KSBT.db.profile.cooldowns.tracked[spellID] then
                KSBT.db.profile.cooldowns.tracked[spellID] = true
                KSBT.Addon:Print("Now tracking spell ID: " .. spellID)
                LibStub("AceConfigRegistry-3.0"):NotifyChange("KrothSBT")
            else
                KSBT.Addon:Print("Already tracking spell ID: " .. spellID)
            end
        else
            KSBT.Addon:Print("Could not resolve spell ID. Try dragging from action bar.")
        end
        ClearCursor()

    elseif cursorType == "item" then
        local key = "item:" .. id
        if not KSBT.db.profile.cooldowns.tracked[key] then
            KSBT.db.profile.cooldowns.tracked[key] = true
            KSBT.Addon:Print("Now tracking item ID: " .. id)
            LibStub("AceConfigRegistry-3.0"):NotifyChange("KrothSBT")
        else
            KSBT.Addon:Print("Already tracking item ID: " .. id)
        end
        ClearCursor()

    elseif cursorType == "petaction" then
        ClearCursor()
        KSBT.Addon:Print("Pet abilities cannot be tracked.")
    else
        ClearCursor()
    end
end

function KSBT.HookDragDropInline()
    local ACD = LibStub("AceConfigDialog-3.0", true)
    if not ACD then return end
    local configFrame = ACD.OpenFrames and ACD.OpenFrames["KrothSBT"]
    if not configFrame then return end

    -- Walk the AceGUI widget tree to find the TabGroup's scroll child,
    -- then find the description widget named "dragDropInline".
    -- AceGUI description widgets expose their underlying frame as .frame
    -- on the AceGUI widget object, or we can walk the content children.
    local tabGroup = nil
    if configFrame.children then
        for _, c in ipairs(configFrame.children) do
            if c.type == "TabGroup" then tabGroup = c; break end
        end
    end
    if not tabGroup then return end

    -- Only hook when Cooldowns tab is active
    local selected = tabGroup.status and tabGroup.status.selected
    if selected ~= "cooldowns" then return end

    -- The TabGroup's content frame holds all rendered widgets as children.
    -- AceGUI description widgets render as FontStrings inside a plain Frame.
    -- We need the content frame itself as our drop target — it covers the
    -- entire tab area and will receive drag events over the description text.
    local contentFrame = tabGroup.content
    if not contentFrame then return end

    -- Find the specific description widget via the AceGUI child list.
    -- The widget's .frame is the actual WoW Frame we can EnableMouse on.
    local targetFrame = nil
    if tabGroup.children then
        for _, child in ipairs(tabGroup.children) do
            -- AceGUI description widgets have type "Label" internally
            -- and expose .frame. We identify ours by checking if its
            -- frame contains a FontString with our text.
            if child.frame then
                local f = child.frame
                for i = 1, f:GetNumRegions() do
                    local r = select(i, f:GetRegions())
                    if r and r.GetText and r:GetText() then
                        local t = r:GetText()
                        if t and t:find("Drag Spell Here") then
                            targetFrame = f
                            break
                        end
                    end
                end
            end
            if targetFrame then break end
        end
    end

    -- Fallback: if we can't find the specific widget frame, skip —
    -- better to do nothing than to hook the wrong frame.
    if not targetFrame then return end
    if dragTargetFrame == targetFrame and dragHookInstalled then return end

    dragTargetFrame   = targetFrame
    dragHookInstalled = true

    targetFrame:EnableMouse(true)
    targetFrame:RegisterForDrag("LeftButton")

    targetFrame:SetScript("OnReceiveDrag", function()
        local t, id, sub = GetCursorInfo()
        HandleSpellDrop(t, id, sub)
    end)

    targetFrame:SetScript("OnMouseUp", function(_, btn)
        if btn == "LeftButton" then
            local t, id, sub = GetCursorInfo()
            if t then HandleSpellDrop(t, id, sub) end
        end
    end)

    -- Hover highlight on the label frame
    if not targetFrame.ksbtBg then
        local accent = KSBT.COLORS and KSBT.COLORS.ACCENT or {r=0.29,g=0.62,b=1.0}
        local hl = targetFrame:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(accent.r, accent.g, accent.b, 0.15)
        targetFrame.ksbtBg = hl
    end
end

-- Called from the Hide hook to reset state so next open re-hooks cleanly
function KSBT.ResetDragDropInline()
    dragHookInstalled = false
    dragTargetFrame   = nil
end