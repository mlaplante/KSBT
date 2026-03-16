------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Constants
-- Named constants used throughout the addon. No magic numbers.
------------------------------------------------------------------------

local ADDON_NAME, KSBT = ...

------------------------------------------------------------------------
-- Version & Identity
------------------------------------------------------------------------
KSBT.VERSION = "1.2.0"
KSBT.ADDON_TITLE = "Kroth's Scrolling Battle Text"
KSBT.SLASH_PRIMARY = "/ksbt"
KSBT.SLASH_SECONDARY = "/krothsbt"

------------------------------------------------------------------------
-- Debug Levels
------------------------------------------------------------------------
KSBT.DEBUG_LEVEL_NONE       = 0    -- Production mode
KSBT.DEBUG_LEVEL_SUPPRESSED = 1    -- Show filtered/suppressed events
KSBT.DEBUG_LEVEL_CONFIDENCE = 2    -- Show confidence scores
KSBT.DEBUG_LEVEL_ALL_EVENTS = 3    -- Everything (verbose)

------------------------------------------------------------------------
-- Confidence Thresholds
------------------------------------------------------------------------
KSBT.CONFIDENCE_THRESHOLD_SOLO  = 0.6
KSBT.CONFIDENCE_THRESHOLD_GROUP = 0.85

-- Confidence contribution factors
KSBT.CONFIDENCE_DIRECT_CAST     = 0.7
KSBT.CONFIDENCE_PET_OWNERSHIP   = 0.5
KSBT.CONFIDENCE_ACTIVE_AURA     = 0.2
KSBT.CONFIDENCE_AUTO_ATTACK     = 0.3

------------------------------------------------------------------------
-- Deduplication
------------------------------------------------------------------------
KSBT.FINGERPRINT_HISTORY_SIZE = 30    -- Number of fingerprints to retain

------------------------------------------------------------------------
-- Diagnostics
------------------------------------------------------------------------
KSBT.DIAG_MAX_ENTRIES = 1000          -- Max diagnostic log entries

------------------------------------------------------------------------
-- UI Dimensions
------------------------------------------------------------------------
KSBT.CONFIG_WIDTH  = 650
KSBT.CONFIG_HEIGHT = 720

------------------------------------------------------------------------
-- Slider Ranges
------------------------------------------------------------------------
KSBT.FONT_SIZE_MIN = 8
KSBT.FONT_SIZE_MAX = 32
KSBT.ALPHA_MIN     = 0
KSBT.ALPHA_MAX     = 1

KSBT.SCROLL_OFFSET_MIN  = -50   -- percent of screen width/height from center
KSBT.SCROLL_OFFSET_MAX  = 50
KSBT.SCROLL_WIDTH_MIN   = 100
KSBT.SCROLL_WIDTH_MAX   = 800
KSBT.SCROLL_HEIGHT_MIN  = 100
KSBT.SCROLL_HEIGHT_MAX  = 600

KSBT.MERGE_WINDOW_MIN = 0.5
KSBT.MERGE_WINDOW_MAX = 5.0

------------------------------------------------------------------------
-- Damage School Indices (matches WoW API school masks)
------------------------------------------------------------------------
KSBT.SCHOOL_PHYSICAL = 0x1
KSBT.SCHOOL_HOLY     = 0x2
KSBT.SCHOOL_FIRE     = 0x4
KSBT.SCHOOL_NATURE   = 0x8
KSBT.SCHOOL_FROST    = 0x10
KSBT.SCHOOL_SHADOW   = 0x20
KSBT.SCHOOL_ARCANE   = 0x40

------------------------------------------------------------------------
-- Color Scheme: "Strike Silver"
------------------------------------------------------------------------
KSBT.COLORS = {
    PRIMARY       = { r = 0.75, g = 0.75, b = 0.75 },   -- #C0C0C0  (general chrome/silver)
    TAB_INACTIVE  = { r = 1.00, g = 1.00, b = 1.00 },   -- #FFFFFF  (inactive tab text - pure white)
    PRIMARY_LIGHT = { r = 0.91, g = 0.91, b = 0.91 },   -- #E8E8E8
    ACCENT        = { r = 0.29, g = 0.62, b = 1.00 },   -- #4A9EFF  (active tab, highlights)
    DARK          = { r = 0.12, g = 0.16, b = 0.22 },   -- #1F2938  (main frame background - dark gunmetal)
    DARK_MID      = { r = 0.17, g = 0.24, b = 0.31 },   -- #2C3E50  (original gunmetal, kept for reference)
    BORDER        = { r = 0.55, g = 0.60, b = 0.66 },   -- #8B98A8  (chrome border - visible on dark bg)
    TEXT_LIGHT    = { r = 0.95, g = 0.95, b = 0.95 },   -- near white
}

------------------------------------------------------------------------
-- Outline Styles (keys for dropdown, values for WoW fontstring flags)
------------------------------------------------------------------------
KSBT.OUTLINE_STYLES = {
    ["None"]       = "",
    ["Thin"]       = "OUTLINE",
    ["Thick"]      = "THICKOUTLINE",
    ["Monochrome"] = "MONOCHROME",
}

------------------------------------------------------------------------
-- Animation Styles
------------------------------------------------------------------------
KSBT.ANIMATION_STYLES = {
    ["Arc"]      = "arc",       -- Radiates outward from center at a random angle, curves toward vertical
    ["Parabola"] = "parabola",
    ["Straight"] = "straight",
    ["Static"]   = "static",
}

------------------------------------------------------------------------
-- Text Alignment
------------------------------------------------------------------------
KSBT.TEXT_ALIGNMENTS = {
    ["Left"]   = "LEFT",
    ["Center"] = "CENTER",
    ["Right"]  = "RIGHT",
}

------------------------------------------------------------------------
-- Scroll Direction
------------------------------------------------------------------------
KSBT.SCROLL_DIRECTIONS = {
    ["Up"]   = "UP",
    ["Down"] = "DOWN",
}

------------------------------------------------------------------------
-- Auto-Attack Display Modes
------------------------------------------------------------------------
KSBT.AUTOATTACK_MODES = {
    ["Show All"]        = "all",
    ["Show Only Crits"] = "crits",
    ["Hide"]            = "hide",
}

------------------------------------------------------------------------
-- Pet Aggregation Styles
------------------------------------------------------------------------
KSBT.PET_AGGREGATION = {
    ["Generic (\"Pet Hit X\")"]   = "generic",
    ["Attempt Pet Name"]          = "named",
}
