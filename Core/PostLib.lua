------------------------------------------------------------------------
-- PostLib: Restore third-party library wrappers that our bundled Ace3
-- libs may have replaced during the LibStub version race.
--
-- Problem:  ElvUI (and similar addons) wrap or hooksecurefunc methods
--           on AceGUI-3.0 and AceConfigDialog-3.0 for frame skinning.
--           If our bundled version is higher, LibStub lets our code
--           re-run, overwriting every method — destroying those hooks
--           and breaking skinning for ALL addons sharing the library.
--
-- Fix:      Compare current function references to the pre-lib snapshot.
--           Any that changed (our version won the race and replaced them)
--           get restored so third-party hooks stay intact.
------------------------------------------------------------------------
local _, KSBT = ...

local saved = KSBT._preLib
if not saved then return end

if not LibStub then return end

-- Restore all changed function references on a library table
local function RestoreLib(name, snapshot)
    if not snapshot then return end
    local lib = LibStub(name, true)
    if not lib then return end
    for key, savedFunc in pairs(snapshot) do
        if lib[key] ~= savedFunc then
            lib[key] = savedFunc
        end
    end
end

RestoreLib("AceGUI-3.0",           saved.AceGUI)
RestoreLib("AceConfigDialog-3.0",  saved.AceConfigDialog)

-- Clean up — no longer needed.
KSBT._preLib = nil
