------------------------------------------------------------------------
-- PreLib: Snapshot existing library function references before our
-- bundled Ace3 libs load.  Other addons (ElvUI, etc.) may have already
-- wrapped these functions for skinning; our lib upgrade would discard
-- those wrappers.  PostLib.lua restores them after the libs finish.
------------------------------------------------------------------------
local _, KSBT = ...

KSBT._preLib = {}

if not LibStub then return end

local AceGUI = LibStub("AceGUI-3.0", true)
if AceGUI then
    KSBT._preLib.RegisterAsWidget     = AceGUI.RegisterAsWidget
    KSBT._preLib.RegisterAsContainer  = AceGUI.RegisterAsContainer
end
