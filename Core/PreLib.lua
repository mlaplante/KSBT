------------------------------------------------------------------------
-- PreLib: Snapshot ALL function references on shared Ace3 library tables
-- before our bundled libs load.
--
-- Other addons (ElvUI, AddOnSkins, etc.) may have already wrapped or
-- hooked methods on AceGUI-3.0 and AceConfigDialog-3.0 for skinning.
-- When our higher-version libs win the LibStub race, every method on
-- the shared table gets overwritten — destroying those hooks.
--
-- We snapshot every function-type value so PostLib.lua can restore any
-- that changed, preserving third-party hooks regardless of which
-- specific methods they target.
------------------------------------------------------------------------
local _, KSBT = ...

KSBT._preLib = {}

if not LibStub then return end

-- Snapshot all function references on a library table
local function SnapshotLib(name)
    local lib = LibStub(name, true)
    if not lib then return end
    local snap = {}
    for key, val in pairs(lib) do
        if type(val) == "function" then
            snap[key] = val
        end
    end
    return snap
end

KSBT._preLib.AceGUI           = SnapshotLib("AceGUI-3.0")
KSBT._preLib.AceConfigDialog  = SnapshotLib("AceConfigDialog-3.0")
