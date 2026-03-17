------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Initialization
-- Creates the addon object, registers chat commands, initializes DB.
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

------------------------------------------------------------------------
-- Create the Ace3 addon object
------------------------------------------------------------------------
KSBT.Addon = LibStub("AceAddon-3.0"):NewAddon("KrothSBT", "AceConsole-3.0")

local Addon = KSBT.Addon

------------------------------------------------------------------------
-- OnInitialize: Fires once when addon loads (before PLAYER_LOGIN)
------------------------------------------------------------------------
function Addon:OnInitialize()
    -- Initialize AceDB with our defaults and enable profiles
    self.db = LibStub("AceDB-3.0"):New("KrothSBTDB", KSBT.DEFAULTS, true)

    -- Store reference in shared namespace for cross-file access
    KSBT.db = self.db

    -- One-time migration: convert pixel offsets to screen-percentage offsets.
    -- Old values were in -500..500 (pixels); new values are -50..50 (%).
    -- Any |offset| > 50 is certainly an old pixel value.
    if self.db.profile and self.db.profile.scrollAreas then
        local screenW, screenH = UIParent:GetWidth(), UIParent:GetHeight()
        for name, area in pairs(self.db.profile.scrollAreas) do
            if area.xOffset and (area.xOffset > 50 or area.xOffset < -50) then
                area.xOffset = (area.xOffset / screenW) * 100
                area.xOffset = math.floor(area.xOffset * 10 + 0.5) / 10
            end
            if area.yOffset and (area.yOffset > 50 or area.yOffset < -50) then
                area.yOffset = (area.yOffset / screenH) * 100
                area.yOffset = math.floor(area.yOffset * 10 + 0.5) / 10
            end
        end
    end

    if KSBT.Core and KSBT.Core.Minimap and KSBT.Core.Minimap.Init then
        KSBT.Core.Minimap:Init()
    end

    -- Register LibSharedMedia-3.0 defaults (ensure base WoW font is listed)
    local LSM = LibStub("LibSharedMedia-3.0", true)
    if LSM then
        -- LSM auto-registers system fonts; no custom media to add yet.
        -- Addon-bundled fonts/sounds can be registered here in future:
        -- LSM:Register("font", "My Custom Font", [[Interface\AddOns\KBST\Media\MyFont.ttf]])
    end

    -- Register slash commands
    self:RegisterChatCommand("ksbt", "HandleSlashCommand")
    self:RegisterChatCommand("krothsbt", "HandleSlashCommand")

    -- Build and register Ace3 options table (assembled in Config.lua)
    if KSBT.BuildOptionsTable then
        local options = KSBT.BuildOptionsTable()

        -- Inject the AceDBOptions-3.0 profiles tab into the options tree
        local AceDBOptions = LibStub("AceDBOptions-3.0", true)
        if AceDBOptions then
            local profilesTable = AceDBOptions:GetOptionsTable(self.db)
            profilesTable.order = 100 -- Place after all other tabs
            options.args.profiles = profilesTable
        end

        LibStub("AceConfig-3.0"):RegisterOptionsTable("KrothSBT", options)
        self.configDialog = LibStub("AceConfigDialog-3.0")

        -- Set the default size for the config dialog
        self.configDialog:SetDefaultSize("KrothSBT", KSBT.CONFIG_WIDTH,
                                         KSBT.CONFIG_HEIGHT)

        -- Apply Strike Silver color scheme to config frame
        if KSBT.ApplyStrikeSilverStyling then
            KSBT.ApplyStrikeSilverStyling()
        end
    end

    self:Print(KSBT.ADDON_TITLE .. " v" .. KSBT.VERSION ..
                   " loaded. Type /ksbt to configure.")
end

------------------------------------------------------------------------
-- OnEnable: Fires when addon is enabled (after PLAYER_LOGIN)
------------------------------------------------------------------------
function Addon:OnEnable()
    local masterEnabled = self.db and self.db.profile and
                              self.db.profile.general and
                              self.db.profile.general.enabled == true

    -- Always init core once (safe, no-op skeleton)
    if KSBT.Core and KSBT.Core.Init then KSBT.Core:Init() end

    if masterEnabled then
        if KSBT.Core and KSBT.Core.Enable then KSBT.Core:Enable() end

        if KSBT.Parser then
            if KSBT.Parser.CombatLog and KSBT.Parser.CombatLog.Enable then
                KSBT.Parser.CombatLog:Enable()
            end
            if KSBT.Parser.Cooldowns and KSBT.Parser.Cooldowns.Enable then
                KSBT.Parser.Cooldowns:Enable()
            end
        end
        if KSBT.Core and KSBT.Core.LowHealth and KSBT.Core.LowHealth.Enable then
            KSBT.Core.LowHealth:Enable()
        end
    else
        -- Respect saved disabled state
        if KSBT.Parser then
            if KSBT.Parser.CombatLog and KSBT.Parser.CombatLog.Disable then KSBT.Parser.CombatLog:Disable() end
            if KSBT.Parser.Cooldowns and KSBT.Parser.Cooldowns.Disable then KSBT.Parser.Cooldowns:Disable() end
        end
        if KSBT.Core and KSBT.Core.Disable then KSBT.Core:Disable() end
        if KSBT.Core and KSBT.Core.LowHealth and KSBT.Core.LowHealth.Disable then
            KSBT.Core.LowHealth:Disable()
        end
    end
end

------------------------------------------------------------------------
-- OnDisable: Fires when addon is disabled
------------------------------------------------------------------------
function Addon:OnDisable()
    if KSBT.Parser then
        if KSBT.Parser.CombatLog and KSBT.Parser.CombatLog.Disable then
            KSBT.Parser.CombatLog:Disable()
        end
        if KSBT.Parser.Cooldowns and KSBT.Parser.Cooldowns.Disable then
            KSBT.Parser.Cooldowns:Disable()
        end
    end

    if KSBT.Core and KSBT.Core.Disable then KSBT.Core:Disable() end
    if KSBT.Core and KSBT.Core.LowHealth and KSBT.Core.LowHealth.Disable then
        KSBT.Core.LowHealth:Disable()
    end
end

------------------------------------------------------------------------
-- Slash Command Router
------------------------------------------------------------------------
function Addon:HandleSlashCommand(input)
    local cmd, rest = self:GetArgs(input, 2)

    if not cmd or cmd == "" then
        self:OpenConfig()
        return
    end

    cmd = cmd:lower()

    if cmd == "minimap" then
        if KSBT.Core and KSBT.Core.Minimap and KSBT.Core.Minimap.UpdateVisibility then
            local g = KSBT.db.profile.general
            g.minimap.hide = not g.minimap.hide
            KSBT.Core.Minimap:UpdateVisibility()
            self:Print(("Minimap button %s."):format(g.minimap.hide and "hidden" or "shown"))
        end
        return
    end

    if cmd == "debug" then
        self:HandleDebugCommand(rest)
        return
    elseif cmd == "reset" then
        self:HandleResetCommand()
        return
    elseif cmd == "version" then
        self:Print(KSBT.ADDON_TITLE .. " v" .. KSBT.VERSION)
        return

    end

    self:Print("Unknown command: " .. cmd)
    self:Print("Usage: /ksbt [minimap | debug 0-3 | reset | version]")
end

------------------------------------------------------------------------
-- Open Configuration Window
------------------------------------------------------------------------
function Addon:OpenConfig()
    if self.configDialog then
        self.configDialog:Open("KrothSBT")

        local frame = self.configDialog.OpenFrames["KrothSBT"]
        if frame and frame.frame then
            local f = frame.frame

            -- Prevent AceConfigDialog from auto-closing when spellbook opens
            if not f.tsbtHooked then
                f.tsbtHooked = true

                -- Store original Hide function
                local origHide = f.Hide

                -- Hook Hide to block auto-closes
                f.Hide = function(self, ...)
                    -- Only allow closes when explicitly permitted
                    if not self.tsbtAllowClose then return end
                    return origHide(self, ...)
                end
            end

            -- Find the close button by searching the frame's children
            local function findCloseButton(parent, depth)
                depth = depth or 0
                if depth > 0 then return end -- ONLY check depth 0!

                for i = 1, parent:GetNumChildren() do
                    local child = select(i, parent:GetChildren())
                    if child and child.GetObjectType and child:GetObjectType() ==
                        "Button" then
                        local text = child:GetText()
                        if text and (text:lower():match("close") or text == "X") then
                            child:HookScript("PreClick", function()
                                f.tsbtAllowClose = true
                                C_Timer.After(0.05, function()
                                    f.tsbtAllowClose = false
                                end)
                            end)
                        end
                    end
                end
            end

            findCloseButton(f)

            -- ESC key handler
            f:EnableKeyboard(true)
            f:SetPropagateKeyboardInput(true)
            f:SetScript("OnKeyDown", function(self, key)
                if key == "ESCAPE" then
                    self.tsbtAllowClose = true
                    self:Hide()
                    C_Timer.After(0.05, function()
                        if self then
                            self.tsbtAllowClose = false
                        end
                    end)
                end
            end)
        end
    end
end

------------------------------------------------------------------------
-- Debug Level Command
------------------------------------------------------------------------
function Addon:HandleDebugCommand(levelStr)
    local level = tonumber(levelStr)
    if not level or level < KSBT.DEBUG_LEVEL_NONE or level >
        KSBT.DEBUG_LEVEL_ALL_EVENTS then
        self:Print("Usage: /ksbt debug [0-3]")
        self:Print("  0 = Off, 1 = Suppressed, 2 = Confidence, 3 = All Events")
        return
    end

    self.db.profile.diagnostics.debugLevel = level
    local names = {
        [0] = "Off",
        [1] = "Suppressed",
        [2] = "Confidence",
        [3] = "All Events"
    }
    self:Print("Debug level set to " .. level .. " (" .. names[level] .. ")")
end

------------------------------------------------------------------------
-- Reset to Defaults (with confirmation gate)
------------------------------------------------------------------------
function Addon:HandleResetCommand()
    self.db:ResetProfile()
    self:Print("Profile reset to defaults.")
end