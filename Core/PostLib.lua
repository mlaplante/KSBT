------------------------------------------------------------------------
-- PostLib: Restore third-party library wrappers that our bundled Ace3
-- libs may have replaced during the LibStub version race.
--
-- Problem:  ElvUI (and similar addons) replace AceGUI.RegisterAsWidget
--           / RegisterAsContainer with skinning wrappers.  If our
--           bundled AceGUI or AceConfigDialog has a *higher* minor
--           version, LibStub lets our code re-run, which overwrites
--           those wrappers with vanilla implementations — breaking
--           ElvUI's frame skinning for every addon using AceGUI.
--
-- Fix:      Compare the current function references to the pre-lib
--           snapshot.  If they changed (our version won the race),
--           restore the saved wrappers so the skinning stays intact.
------------------------------------------------------------------------
local _, KSBT = ...

local saved = KSBT._preLib
if not saved then return end

if not LibStub then return end

local AceGUI = LibStub("AceGUI-3.0", true)
if not AceGUI then return end

-- Only restore if the function reference actually changed (meaning our
-- lib version won and replaced the wrapper).
if saved.RegisterAsWidget
    and saved.RegisterAsWidget ~= AceGUI.RegisterAsWidget then
    AceGUI.RegisterAsWidget = saved.RegisterAsWidget
end

if saved.RegisterAsContainer
    and saved.RegisterAsContainer ~= AceGUI.RegisterAsContainer then
    AceGUI.RegisterAsContainer = saved.RegisterAsContainer
end

-- Clean up — no longer needed.
KSBT._preLib = nil
