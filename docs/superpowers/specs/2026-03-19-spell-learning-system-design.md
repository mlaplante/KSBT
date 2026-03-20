# Spell Learning System — Design Spec

**Date:** 2026-03-19
**Status:** Approved
**Approach:** Hybrid (Rule-Based Elimination + Bayesian Scoring)

## Problem

KSBT cannot reliably attribute damage numbers to specific spells in all scenarios:

1. **CLEU unreliable in group content** — events sometimes don't fire, forcing fallback to UNIT_COMBAT which carries no spell ID
2. **Secret values in restricted content** — CLEU provides spell IDs but damage amounts are secret (non-arithmetic), while UNIT_COMBAT provides real numbers but no spell identity

**Goal:** Accurate spell reporting for damage numbers. Only label damage with a spell name when confidence is high. Show unlabeled damage as just the number when uncertain.

## Design Decisions

- **Accuracy over coverage:** Only label when confident (threshold 0.65+, margin 0.15+)
- **Per-character persistence:** Each character has its own learned spell profiles via SavedVariablesPerCharacter
- **Additive only:** No existing behavior changes — if the system can't match, behavior is identical to today
- **All matching signals used:** Damage school, crit flag, cast history, damage range, timing, periodic flag
- **Damage only:** The learning system applies to damage events only. Heals already come through CLEU with full spell info reliably and do not need matching. The matcher is never invoked for heal events.
- **Per-spec fingerprints:** Fingerprints are keyed by `(specId, spellId)` to prevent pollution when switching specs (e.g., Holy Shock deals different damage as Holy vs. Ret Paladin). Spec ID obtained via `GetSpecializationInfo(GetSpecialization())`.

## Components

### 1. Cast History Tracker

**File:** `Parser/CastHistory.lua`

**Purpose:** Maintain a rolling window of recent spell casts so we know what spells are "in flight" when an unidentified damage event arrives.

**Implementation:**
- Listen to `UNIT_SPELLCAST_SUCCEEDED` for the player
- Also listen to `UNIT_SPELLCAST_CHANNEL_START` — channeled spells (Arcane Missiles, Mind Flay, etc.) produce multiple damage ticks during the channel but `UNIT_SPELLCAST_SUCCEEDED` only fires at channel end. Channel start ensures ticks during the channel can be matched.
- Circular buffer of the last 20 casts, each entry storing:
  - `spellId`, `spellName`, `timestamp`, `schoolMask` (via `C_Spell.GetSpellInfo`, may be nil for some spells — see school match handling below), `consumed` (number of hits matched against this cast, default 0)
- Entries expire after 3 seconds (covers cast time + travel time for ranged abilities)
- When a damage event needs matching, query buffer for all non-expired casts

**Integration:** Replaces current `_lastCastSpellId` single-value tracking in `CombatLog_Detect.lua` with buffer push.

**Note on proc spells:** Some proc-triggered abilities (e.g., instant casts from procs) may not fire `UNIT_SPELLCAST_SUCCEEDED`. These will only be attributable via CLEU when available. This is an accepted limitation — the system does not attempt to match damage that has no cast history entry.

### 2. Spell Fingerprint Database

**File:** `Core/SpellFingerprints.lua`

**Purpose:** Learn and store statistical profiles for each spell based on confirmed CLEU observations.

**Fingerprint structure per spell:**
- `spellId`, `spellName`
- `schoolMask` (constant per spell)
- `isPeriodic` (constant per spell)
- `damageMin`, `damageMax`, `damageAvg` (exponential moving average)
- `damageVar` (EMA-based variance for standard deviation scoring: `var = (1-α)*var + α*(obs-avg)²`)
- `damageCount` (total non-secret observations for damage range)
- `critCount`, `sampleCount` (total confirmed observations)
- `avgCastToHitDelay`, `delayVar` (EMA-based mean and variance)
- `maxHitsPerCast` (learned max for AoE detection: if a spell regularly produces multiple hits per cast, track the observed max)
- `schemaVersion` (integer, current version = 1 — used for migration when structure changes)

**Learning trigger:** When a CLEU event arrives with both spell ID and a non-secret damage amount, record a full observation. When amount is secret, record non-numeric signals only (school, crit, periodic, delay).

**Maturity threshold:** 10+ observations before fingerprint is used for damage range scoring. Immature fingerprints still participate in rule-based matching.

**Decay:** Exponential moving average (EMA) instead of simple running average. Recent observations weigh more heavily. After gear upgrades, old damage ranges fade out over ~20-30 observations.

**Persistence:** `SavedVariablesPerCharacter` under `KSBT_SpellFingerprints`.

**Schema migration:** On load, check `schemaVersion` of each fingerprint entry. If missing or < current version, wipe stale data (v1 is the first version, so any missing version field triggers a reset).

**Size cap:** Maximum 200 spell fingerprints per character. If exceeded, evict the entry with the lowest `sampleCount` (least-observed spells are least useful). This prevents unbounded growth from spec/expansion changes.

**EMA warmup:** For the first 5 observations, use simple averaging instead of EMA (alpha=1/n) to avoid the first observation having outsized persistence. After 5 observations, switch to `EMA_ALPHA`.

### 3. Spell Matcher (Hybrid Engine)

**File:** `Core/SpellMatcher.lua`

**Purpose:** When a UNIT_COMBAT damage event arrives without a spell ID, score all candidate spells and either label it or leave it unlabeled.

#### Phase 1: Rule-Based Elimination

Hard filters that remove impossible candidates from the cast history:

1. **No-cast-history shortcut** — if the cast history is empty (no recent casts), skip matching entirely. This handles auto-attacks (`SWING_DAMAGE`) which never fire `UNIT_SPELLCAST_SUCCEEDED`. Auto-attack damage passes through unlabeled (as today).
2. **School match** — damage school must be compatible with the spell's school. For composite school masks (e.g., Chaos Bolt = Fire+Shadow = 0x24), use `bit.band(eventSchool, spellSchool) ~= 0`. If the spell's `schoolMask` is nil (some spells don't report it), skip this filter for that candidate (don't eliminate, don't confirm).
3. **Periodic flag** — periodic damage only matches periodic spells (and vice versa)
4. **Cast recency** — spell must have been cast within the 3s expiry window
5. **Consumed check** — each cast history entry tracks a `consumed` hit count. For single-target spells (learned `maxHitsPerCast` <= 1 or immature), a cast is consumed after 1 match. For AoE spells (learned `maxHitsPerCast` > 1), a cast allows up to `maxHitsPerCast` matches. Once consumed, the cast is no longer a candidate. Consumed marks persist until the cast expires from the buffer.

If only **one candidate** survives Phase 1 → label immediately with high confidence.

#### Phase 2: Bayesian Scoring

When multiple candidates survive Phase 1, compute a weighted score:

| Signal | Weight | Method |
|--------|--------|--------|
| Damage range fit | 0.4 | Z-score from learned average using EMA stddev: `score = max(0, 1 - abs(amount - avg) / (stddev + 1))`. Only if fingerprint mature (10+ samples). |
| Cast-to-hit timing | 0.3 | Same z-score approach: `score = max(0, 1 - abs(delay - avgDelay) / (delayStddev + 0.05))`. The +0.05 floor prevents division by near-zero for instant spells. |
| Crit consistency | 0.15 | Prefer spells with matching crit ratio |
| Cast order | 0.15 | More recent casts score slightly higher |

**Confidence rules:**
- Top candidate must score above **0.65** (configurable)
- Top candidate must score at least **0.15** above the runner-up
- If either condition fails, leave damage unlabeled

**Secret value adjustment:** When UNIT_COMBAT amount is secret, skip damage range scoring. Redistribute its 0.4 weight proportionally to remaining signals (sum of remaining = 0.6, multiply each by 1/0.6 ≈ 1.667): timing → 0.50, crit → 0.25, cast order → 0.25.

**Cast delay computation:** When a CLEU `SPELL_DAMAGE` arrives, look up the most recent cast history entry with a matching `spellId`. The delay is `CLEUTimestamp - castTimestamp`. If no matching cast is found (proc spell, etc.), delay is not recorded for that observation.

### 4. Pipeline Integration

**Modified file:** `Parser/CombatLog_Detect.lua`

Event flow:

```
UNIT_SPELLCAST_SUCCEEDED
    → CastHistory:Push(spellId, spellName, schoolMask, timestamp)

CLEU SPELL_DAMAGE / RANGE_DAMAGE / SPELL_PERIODIC_DAMAGE (confirmed spell + amount)
    → SpellFingerprints:RecordObservation(spellId, amount, isCrit, isPeriodic, schoolMask, castDelay)
    → Existing outgoing pipeline (unchanged)

Note: SPELL_HEAL / SPELL_PERIODIC_HEAL are NOT sent through the learning system.
      SWING_DAMAGE is NOT sent through the learning system (auto-attacks have no spell ID).

UNIT_COMBAT damage (no spell ID)
    → SpellMatcher:Match(amount, schoolMask, isCrit, isPeriodic, timestamp)
    → If confident match → attach spellId + spellName to event
    → If no match → event passes through with nil spell info
    → Existing outgoing pipeline (unchanged)
```

**Key principle:** Additive only. If the matcher can't match, behavior is identical to today. No existing functionality breaks.

**Modified file:** `KBST.toc` — add new files to load order and SavedVariablesPerCharacter.

**TOC changes:**
```
## SavedVariablesPerCharacter: KSBT_SpellFingerprints

# Load order (add before CombatLog_Detect.lua):
Parser\CastHistory.lua
Core\SpellFingerprints.lua
Core\SpellMatcher.lua
# Load order (add after UI\Config.lua):
UI\DebugFrame.lua
```

**Pet/guardian damage:** The matcher is only called for events that pass the existing player-attribution check (`IsPlayerMine(flags)`). Pet and guardian damage uses different source flags and is not routed to the matcher. When CLEU is down and `UNIT_COMBAT` fires on "target", any damage not preceded by a player cast in the history will simply not match (no candidates), which is the correct behavior.

### 5. Debug Frame

**File:** `UI/DebugFrame.lua`

**Purpose:** Dedicated, resizable, scrollable window for spell learning diagnostics.

**UI:**
- Toggled via `/ksbt debugframe`
- Resizable, draggable, close button, "Clear" button
- `ScrollingMessageFrame` widget
- Position saved in `KSBT_SpellFingerprints.debugFramePos` (per-character)

**Color-coded log entries:**

| Color | Event |
|-------|-------|
| Green | Confirmed observation: "Learned: Aimed Shot #185358 — 42,531 (crit) [sample #14]" |
| Yellow | Match attempt: "Matching: 38,200 Physical — candidates: Aimed Shot(0.82), Kill Shot(0.41)" |
| Cyan | Confident match: "Matched → Aimed Shot (confidence: 0.82, margin: 0.41)" |
| Orange | No match: "No match: 15,300 Fire — 0 candidates after elimination" |
| Red | Low confidence: "Rejected: best=Arcane Shot(0.58), below threshold 0.65" |
| Gray | Cast tracked: "Cast: Aimed Shot #185358 at 14:32:05.123" |

**Debug levels:**
- Level 0: Off
- Level 1: Matches and rejections only (cyan, orange, red)
- Level 2: + observations and cast tracking (green, gray)
- Level 3: + full scoring breakdown for each candidate

**Slash commands:**
- `/ksbt debugframe` — toggle visibility
- `/ksbt debuglevel [0-3]` — set verbosity

### 6. Secret Value Handling

Handled across all new files with a consistent strategy:

- **Fingerprint learning:** When amount is secret, record non-numeric signals only (school, crit, periodic, delay). Skip damage range stats.
- **Matching:** When UNIT_COMBAT amount is secret, skip damage range scoring. Redistribute weight to other signals. Rule-based elimination and other Bayesian signals still work.
- **Debug output:** Use `tostring(amount)` for display (Blizzard metamethod renders secret values as a display string).

## New Files

| File | Purpose |
|------|---------|
| `Parser/CastHistory.lua` | Rolling cast buffer (20 entries, 3s expiry) |
| `Core/SpellFingerprints.lua` | Per-character learned spell profiles with EMA decay |
| `Core/SpellMatcher.lua` | Two-phase hybrid matching engine |
| `UI/DebugFrame.lua` | Scrollable diagnostic window |

## Modified Files

| File | Change |
|------|--------|
| `Parser/CombatLog_Detect.lua` | Wire cast history push, fingerprint recording, matcher calls |
| `KBST.toc` | Add new files to load order |

## New SavedVariablesPerCharacter

- `KSBT_SpellFingerprints` — per-character spell profiles

## New Slash Commands

- `/ksbt debugframe` — toggle debug window
- `/ksbt debuglevel [0-3]` — set debug verbosity
- `/ksbt fingerprints` — dump current fingerprint database summary to debug frame (spell name, sample count, damage range, school)

## Configuration Constants

| Constant | Default | Purpose |
|----------|---------|---------|
| `CAST_HISTORY_SIZE` | 20 | Max entries in cast buffer |
| `CAST_EXPIRY_SECONDS` | 3.0 | How long a cast stays eligible for matching |
| `FINGERPRINT_MATURITY` | 10 | Observations needed before damage range scoring |
| `CONFIDENCE_THRESHOLD` | 0.65 | Minimum score to label a match |
| `CONFIDENCE_MARGIN` | 0.15 | Minimum gap between top and runner-up |
| `EMA_ALPHA` | 0.1 | Exponential moving average smoothing factor (simple avg used for first 5 samples) |
| `MAX_FINGERPRINTS` | 200 | Maximum spell fingerprints per character before LRU eviction |
| `SCHEMA_VERSION` | 1 | Current fingerprint schema version for migration |

## Known Limitations

- **Proc spells:** Abilities triggered by procs that don't fire `UNIT_SPELLCAST_SUCCEEDED` cannot be matched via cast history. They are only attributable when CLEU is available.
- **Same-school overlap:** Classes with multiple same-school, similar-damage spells (e.g., Fire Mage during Combustion) may frequently fail the confidence margin check, resulting in unlabeled damage. This is intentional — accuracy over coverage.
- **Restricted content:** In M+/raids with secret values, damage range learning is unavailable. The system relies on school/timing/cast history signals only, which reduces accuracy but maintains functionality.
