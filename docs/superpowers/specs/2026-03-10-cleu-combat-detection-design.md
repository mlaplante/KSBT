# Unified CLEU Combat Detection

**Date:** 2026-03-10
**Status:** Approved

## Problem

WoW Midnight (12.0) removed `UNIT_COMBAT` and permanently restricted `COMBAT_LOG_EVENT_UNFILTERED` values during boss encounters and M+ runs. KSBT's outgoing combat text is disabled (`OUTGOING_READY = false`) because the `UNIT_COMBAT + UNIT_SPELLCAST_SUCCEEDED` approach cannot accurately attribute damage to the player in group content. The incoming parser also uses the removed `UNIT_COMBAT` event and needs migration.

## Solution

Replace both the incoming and outgoing detection layers with a single `COMBAT_LOG_EVENT_UNFILTERED` listener. CLEU still fires in Midnight — amounts become secret values only during restricted content (boss fights, M+ runs). Use `issecretvalue()` for per-event detection and gracefully degrade arithmetic-dependent features when secrets are present.

## Architecture

### Unified CLEU Parser (`Parser/CombatLog_Detect.lua`)

Single event frame registers `COMBAT_LOG_EVENT_UNFILTERED`. On each event, calls `CombatLogGetCurrentEventInfo()` and routes based on GUID:

- `srcGUID == UnitGUID("player")` -> Outgoing pipeline (OutgoingProbe)
- `destGUID == UnitGUID("player")` -> Incoming pipeline (IncomingProbe)

### CLEU Sub-events Handled

**Outgoing (src = player):**

| Sub-event | Kind | Notes |
|-----------|------|-------|
| SWING_DAMAGE | damage | isAuto=true |
| SPELL_DAMAGE | damage | |
| SPELL_PERIODIC_DAMAGE | damage | isPeriodic=true |
| RANGE_DAMAGE | damage | |
| SPELL_HEAL | heal | includes overheal |
| SPELL_PERIODIC_HEAL | heal | isPeriodic=true |

**Incoming (dest = player):**

| Sub-event | Kind | Notes |
|-----------|------|-------|
| SWING_DAMAGE | damage | |
| SPELL_DAMAGE | damage | |
| SPELL_PERIODIC_DAMAGE | damage | isPeriodic=true |
| ENVIRONMENTAL_DAMAGE | damage | |
| SPELL_HEAL | heal | |
| SPELL_PERIODIC_HEAL | heal | isPeriodic=true |

### Secret Value Handling (Hybrid Approach)

Per-event detection using `issecretvalue()`. No mode switching, no dual code paths.

**Works normally with secrets:**
- Event routing (GUIDs not secret)
- Crit detection (boolean flag, not secret)
- Spell names, spell IDs, school masks (not secret)
- Auto-attack vs spell classification (sub-event type)
- Periodic detection (sub-event type)
- Color assignment (based on crit/school, not amount)
- Dummy suppression (uses destFlags bitmask)
- Display via `tostring(amount)` (Blizzard metamethod)

**Degrades gracefully with secrets:**
- Thresholds: skipped (can't compare)
- Merging/spam control: skipped (can't compare amounts)
- Auto-attack hide-by-amount: skipped
- Overheal subtraction: skipped (raw amount displayed)

### Event Contracts

**Outgoing event (to OutgoingProbe):**

```lua
{
  ts = number,                -- GetTime()
  kind = "damage" | "heal",
  amount = number | secret,   -- secret during restricted content
  isSecret = boolean,         -- true when amount is a secret value
  overheal = number | secret | nil,
  isAuto = boolean,           -- true for SWING_DAMAGE
  isCrit = boolean,           -- from CLEU critical flag
  isPeriodic = boolean,       -- DoTs/HoTs
  spellId = number | nil,     -- from CLEU payload
  spellName = string | nil,   -- from CLEU payload
  schoolMask = number,        -- from CLEU payload
  destFlags = number | nil,   -- for dummy detection
  targetName = string | nil,  -- destName from CLEU
}
```

**Incoming event (to IncomingProbe):**

```lua
{
  ts = number,
  kind = "damage" | "heal",
  amount = number | secret,
  isSecret = boolean,
  isCrit = boolean,           -- NEW: was missing from UNIT_COMBAT
  isPeriodic = boolean,       -- NEW
  schoolMask = number | nil,
  spellId = number | nil,     -- NEW: know what hit you
  spellName = string | nil,   -- NEW
  sourceName = string | nil,  -- NEW: who hit you
  absorbed = number | nil,    -- NEW
}
```

## File Changes

### Create/Rewrite

| File | Action |
|------|--------|
| `Parser/CombatLog_Detect.lua` | Rewrite from skeleton to full CLEU listener |

### Modify

| File | Change |
|------|--------|
| `Core/Core.lua` | Remove `OUTGOING_READY` gate and conditionals |
| `Core/Init.lua` | Simplify enable/disable — CombatLog parser replaces Incoming + Outgoing; remove `probecombattext` slash command |
| `Core/Outgoing_Probe.lua` | Replace `TryReadAmount` pcall hack with `issecretvalue()`; accept `evt.isSecret` flag |
| `Core/Incoming_Probe.lua` | Add `isSecret` awareness; add crit support; update capability report |
| `Core/Diagnostics.lua` | Update `probeevents` to dump CLEU; remove `probecombattext` |
| `UI/Config.lua` | Uncomment the Outgoing tab |
| `KSBT.toc` | Remove deleted files from load order |

### Delete

| File | Reason |
|------|--------|
| `Parser/Outgoing_Detect.lua` | Replaced by CombatLog_Detect |
| `Parser/Incoming_Detect.lua` | Replaced by CombatLog_Detect |

### Untouched

- `Core/Outgoing_Probe.lua` — ring buffer, capture/replay, merging, display routing intact
- `Core/Incoming_Probe.lua` — same, minor additions only
- `UI/ConfigTabs.lua` — Outgoing tab already fully built
- `Core/Defaults.lua` — outgoing defaults already correct
- `Core/Display_Decide.lua`, `UI/ScrollAreaFrames.lua` — display pipeline untouched

## Risk Assessment

- **Low risk**: Outgoing — new feature, currently disabled, nothing to regress
- **Medium risk**: Incoming — currently working, migration to CLEU is a net improvement but needs in-game validation. Clean cut recommended since `UNIT_COMBAT` is documented as removed in 12.0.

## Key Technical Decisions

1. **Single CLEU listener** rather than separate parsers per direction — reduces event overhead, shared frame
2. **`issecretvalue()` per-event** rather than mode-based detection — simpler, no edge cases at transition boundaries
3. **No pcall** — `issecretvalue()` is the sanctioned Midnight API; pcall-based secret detection is outdated
4. **Delete old parsers** rather than keep as fallback — `UNIT_COMBAT` is removed in 12.0, dead code causes confusion
5. **Direct `RegisterEvent` call** — CLEU registration is not a protected call, no pcall wrapper needed

## References

- [Patch 12.0.0 API Changes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes)
- [Secret Values](https://warcraft.wiki.gg/wiki/Secret_Values)
- [BlizzSCT source](https://github.com/Vast-Studios/BlizzSCT) — reference implementation proving CLEU works in Midnight
- [Combat Addon Restrictions Eased](https://www.icy-veins.com/wow/news/combat-addon-restrictions-eased-in-midnight/) — restrictions only apply during boss/M+ encounters
