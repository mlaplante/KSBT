------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Parser Normalization Helpers (Skeleton)
-- Responsibility: normalize raw game data into a consistent event table.
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

KSBT.Parser = KSBT.Parser or {}
KSBT.Parser.Normalize = KSBT.Parser.Normalize or {}
local Normalize = KSBT.Parser.Normalize
local Addon     = KSBT.Addon

-- Create a normalized event shell (placeholder)
function Normalize:NewEvent(kind, payload)
    local evt = payload or {}
    evt.kind = kind or "UNKNOWN"

    -- Timestamp is optional; avoid forcing behavior.
    -- The parser may set it later using GetTime().
    return evt
end
