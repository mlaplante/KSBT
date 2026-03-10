# Unified CLEU Combat Detection Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace both incoming and outgoing combat detection with a single COMBAT_LOG_EVENT_UNFILTERED listener that provides accurate player attribution and handles Midnight secret values gracefully.

**Architecture:** A unified CLEU parser in `Parser/CombatLog_Detect.lua` registers one event, routes outgoing (srcGUID=player) to OutgoingProbe and incoming (destGUID=player) to IncomingProbe. Both Probes get updated to accept `evt.isSecret` and use `issecretvalue()` instead of the old pcall hack. Old UNIT_COMBAT-based parsers are deleted.

**Tech Stack:** WoW Lua, COMBAT_LOG_EVENT_UNFILTERED, CombatLogGetCurrentEventInfo(), issecretvalue(), Ace3

**Spec:** `docs/superpowers/specs/2026-03-10-cleu-combat-detection-design.md`

---

## Chunk 1: Core CLEU Parser & Probe Updates

### Task 1: Write the unified CLEU parser

**Files:**
- Rewrite: `Parser/CombatLog_Detect.lua` (currently a skeleton, lines 1-25)

**Context:** This file currently contains empty `Enable()`/`Disable()` stubs. It needs to become the single source of all combat event detection. It registers `COMBAT_LOG_EVENT_UNFILTERED`, parses `CombatLogGetCurrentEventInfo()` payloads, and routes normalized events to the appropriate Probe.

**CLEU payload reference** (from `CombatLogGetCurrentEventInfo()`):
- Returns: `timestamp, subevent, hideCaster, srcGUID, srcName, srcFlags, srcRaidFlags, destGUID, destName, destFlags, destRaidFlags, ...`
- Damage suffixes (`_DAMAGE`): `..., spellId, spellName, spellSchool, amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing, isOffHand`
- `SWING_DAMAGE`: no spell prefix — `..., amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing, isOffHand`
- Heal suffixes (`_HEAL`): `..., spellId, spellName, spellSchool, amount, overhealing, absorbed, critical`
- `ENVIRONMENTAL_DAMAGE`: `..., environmentalType, amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing, isOffHand`

- [ ] **Step 1: Write the full CombatLog_Detect.lua**

Replace the entire file with:

```lua
------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Combat Log Detection (CLEU)
--
-- Responsibility:
--   - Register COMBAT_LOG_EVENT_UNFILTERED
--   - Parse CombatLogGetCurrentEventInfo() payloads
--   - Route outgoing events (srcGUID == player) to OutgoingProbe
--   - Route incoming events (destGUID == player) to IncomingProbe
--   - Detect secret values via issecretvalue() for restricted content
--
-- Replaces the old Incoming_Detect.lua (UNIT_COMBAT on player) and
-- Outgoing_Detect.lua (UNIT_COMBAT on target + UNIT_SPELLCAST_SUCCEEDED).
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

KSBT.Parser = KSBT.Parser or {}
KSBT.Parser.CombatLog = KSBT.Parser.CombatLog or {}
local CombatLog = KSBT.Parser.CombatLog
local Addon     = KSBT.Addon

CombatLog._enabled = CombatLog._enabled or false
CombatLog._frame   = CombatLog._frame or nil

local _playerGUID = nil

local function Debug(level, ...)
    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(level, ...)
    end
end

local function IsSecret(val)
    return issecretvalue and issecretvalue(val) or false
end

local function GetPlayerGUID()
    if not _playerGUID then
        _playerGUID = UnitGUID("player")
    end
    return _playerGUID
end

local function EmitOutgoing(evt)
    local probe = KSBT.Core and KSBT.Core.OutgoingProbe
    if probe and probe.OnOutgoingDetected then
        probe:OnOutgoingDetected(evt)
    end
end

local function EmitIncoming(evt)
    local probe = KSBT.Core and KSBT.Core.IncomingProbe
    if probe and probe.OnIncomingDetected then
        probe:OnIncomingDetected(evt)
    end
end

-- Spell name resolver (CLEU provides spellName directly, but as fallback)
local function SpellNameForId(spellId)
    if not spellId then return nil end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellId)
        return info and info.name
    end
    if GetSpellInfo then
        return (GetSpellInfo(spellId))
    end
end

------------------------------------------------------------------------
-- CLEU Sub-event Handlers
------------------------------------------------------------------------

-- Damage sub-events that have a spell prefix: spellId, spellName, spellSchool, amount, ...
local SPELL_DAMAGE_EVENTS = {
    SPELL_DAMAGE = true,
    SPELL_PERIODIC_DAMAGE = true,
    RANGE_DAMAGE = true,
}

-- Heal sub-events: spellId, spellName, spellSchool, amount, overhealing, absorbed, critical
local SPELL_HEAL_EVENTS = {
    SPELL_HEAL = true,
    SPELL_PERIODIC_HEAL = true,
}

local function HandleCLEU()
    local timestamp, subevent, hideCaster,
          srcGUID, srcName, srcFlags, srcRaidFlags,
          destGUID, destName, destFlags, destRaidFlags,
          ... = CombatLogGetCurrentEventInfo()

    local playerGUID = GetPlayerGUID()
    if not playerGUID then return end

    local isOutgoing = (srcGUID == playerGUID)
    local isIncoming = (destGUID == playerGUID)
    if not isOutgoing and not isIncoming then return end

    local now = GetTime()

    ----------------------------------------------------------------
    -- SWING_DAMAGE: no spell prefix
    -- Payload: amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing, isOffHand
    ----------------------------------------------------------------
    if subevent == "SWING_DAMAGE" then
        local amount, overkill, school, resisted, blocked, absorbed, critical = ...
        local secret = IsSecret(amount)

        if isOutgoing then
            EmitOutgoing({
                ts         = now,
                kind       = "damage",
                amount     = amount,
                isSecret   = secret,
                isAuto     = true,
                isCrit     = (critical == true) or (critical == 1),
                isPeriodic = false,
                spellId    = nil,
                spellName  = nil,
                schoolMask = school or 1,
                destFlags  = destFlags,
                targetName = destName,
            })
        end
        if isIncoming then
            EmitIncoming({
                ts         = now,
                kind       = "damage",
                amount     = amount,
                isSecret   = secret,
                isCrit     = (critical == true) or (critical == 1),
                isPeriodic = false,
                schoolMask = school or 1,
                spellId    = nil,
                spellName  = nil,
                sourceName = srcName,
                absorbed   = absorbed,
            })
        end
        return
    end

    ----------------------------------------------------------------
    -- SPELL_DAMAGE / SPELL_PERIODIC_DAMAGE / RANGE_DAMAGE
    -- Payload: spellId, spellName, spellSchool, amount, overkill, school, resisted, blocked, absorbed, critical
    ----------------------------------------------------------------
    if SPELL_DAMAGE_EVENTS[subevent] then
        local spellId, spellName, spellSchool, amount, overkill, school, resisted, blocked, absorbed, critical = ...
        local secret = IsSecret(amount)
        local isPeriodic = (subevent == "SPELL_PERIODIC_DAMAGE")

        if isOutgoing then
            EmitOutgoing({
                ts         = now,
                kind       = "damage",
                amount     = amount,
                isSecret   = secret,
                isAuto     = false,
                isCrit     = (critical == true) or (critical == 1),
                isPeriodic = isPeriodic,
                spellId    = spellId,
                spellName  = spellName or SpellNameForId(spellId),
                schoolMask = spellSchool or school or 1,
                destFlags  = destFlags,
                targetName = destName,
            })
        end
        if isIncoming then
            EmitIncoming({
                ts         = now,
                kind       = "damage",
                amount     = amount,
                isSecret   = secret,
                isCrit     = (critical == true) or (critical == 1),
                isPeriodic = isPeriodic,
                schoolMask = spellSchool or school or 1,
                spellId    = spellId,
                spellName  = spellName or SpellNameForId(spellId),
                sourceName = srcName,
                absorbed   = absorbed,
            })
        end
        return
    end

    ----------------------------------------------------------------
    -- ENVIRONMENTAL_DAMAGE (incoming only)
    -- Payload: environmentalType, amount, overkill, school, resisted, blocked, absorbed, critical
    ----------------------------------------------------------------
    if subevent == "ENVIRONMENTAL_DAMAGE" then
        if not isIncoming then return end
        local envType, amount, overkill, school, resisted, blocked, absorbed, critical = ...
        local secret = IsSecret(amount)

        EmitIncoming({
            ts         = now,
            kind       = "damage",
            amount     = amount,
            isSecret   = secret,
            isCrit     = (critical == true) or (critical == 1),
            isPeriodic = false,
            schoolMask = school or 1,
            spellId    = nil,
            spellName  = envType,  -- "Falling", "Drowning", "Fire", "Lava", etc.
            sourceName = envType,
            absorbed   = absorbed,
        })
        return
    end

    ----------------------------------------------------------------
    -- SPELL_HEAL / SPELL_PERIODIC_HEAL
    -- Payload: spellId, spellName, spellSchool, amount, overhealing, absorbed, critical
    ----------------------------------------------------------------
    if SPELL_HEAL_EVENTS[subevent] then
        local spellId, spellName, spellSchool, amount, overhealing, absorbed, critical = ...
        local secret = IsSecret(amount)
        local isPeriodic = (subevent == "SPELL_PERIODIC_HEAL")

        if isOutgoing then
            EmitOutgoing({
                ts         = now,
                kind       = "heal",
                amount     = amount,
                isSecret   = secret,
                overheal   = overhealing,
                isAuto     = false,
                isCrit     = (critical == true) or (critical == 1),
                isPeriodic = isPeriodic,
                spellId    = spellId,
                spellName  = spellName or SpellNameForId(spellId),
                schoolMask = spellSchool or 1,
                destFlags  = destFlags,
                targetName = destName,
            })
        end
        if isIncoming then
            EmitIncoming({
                ts         = now,
                kind       = "heal",
                amount     = amount,
                isSecret   = secret,
                isCrit     = (critical == true) or (critical == 1),
                isPeriodic = isPeriodic,
                schoolMask = spellSchool or 1,
                spellId    = spellId,
                spellName  = spellName or SpellNameForId(spellId),
                sourceName = srcName,
                absorbed   = absorbed,
            })
        end
        return
    end
end

------------------------------------------------------------------------
-- Enable / Disable
------------------------------------------------------------------------
function CombatLog:Enable()
    if self._enabled then return end
    self._enabled = true

    Debug(1, "Parser.CombatLog:Enable()")

    -- Cache player GUID on enable
    _playerGUID = UnitGUID("player")

    if not self._frame then
        local f = CreateFrame("Frame")
        self._frame = f
    end

    self._frame:SetScript("OnEvent", function()
        HandleCLEU()
    end)

    self._frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
end

function CombatLog:Disable()
    if not self._enabled then return end
    self._enabled = false

    Debug(1, "Parser.CombatLog:Disable()")

    if self._frame then
        self._frame:UnregisterAllEvents()
        self._frame:SetScript("OnEvent", nil)
    end
end
```

- [ ] **Step 2: Verify file saved correctly**

Open the file and confirm it's syntactically complete — check that every `function` has an `end`, every `if` has an `end`, and the file ends cleanly.

- [ ] **Step 3: Commit**

```bash
git add Parser/CombatLog_Detect.lua
git commit -m "feat: implement unified CLEU parser for incoming and outgoing combat detection"
```

---

### Task 2: Update OutgoingProbe to use issecretvalue()

**Files:**
- Modify: `Core/Outgoing_Probe.lua:48-58` (replace `TryReadAmount`)

**Context:** The `TryReadAmount` function at line 51-58 uses a pcall hack to detect secret values. Replace it with `issecretvalue()`. The rest of the file's `isSecret` branching already works — it just needs to read from `evt.isSecret` instead of detecting locally.

- [ ] **Step 1: Replace TryReadAmount with issecretvalue-based helper**

In `Core/Outgoing_Probe.lua`, replace lines 48-58:

```lua
-- In restricted content (M+, raids) CLEU amounts are "secret numbers":
-- arithmetic on them throws, but tostring() works via metamethod.
-- Returns: plainValue (number), isSecret (bool)
local function TryReadAmount(raw)
    if raw == nil then return 0, false end
    local ok, val = pcall(function() return raw + 0 end)
    if ok and type(val) == "number" then
        return val, false
    end
    return raw, true  -- secret: caller must avoid arithmetic, use tostring()
end
```

With:

```lua
-- In restricted content (M+, raids) CLEU amounts are "secret numbers":
-- arithmetic on them throws, but tostring() works via Blizzard metamethod.
-- Returns: plainValue (number), isSecret (bool)
local function ReadAmount(raw)
    if raw == nil then return 0, false end
    if issecretvalue and issecretvalue(raw) then
        return raw, true  -- secret: caller must avoid arithmetic, use tostring()
    end
    local val = tonumber(raw)
    if val then return val, false end
    return 0, false
end
```

- [ ] **Step 2: Update ProcessOutgoingEvent to prefer evt.isSecret**

In `Core/Outgoing_Probe.lua`, in `ProcessOutgoingEvent` (line 306+), the damage branch calls `TryReadAmount(evt.amount)` at line 326. Update this call and the heal branch call (line 395) to use `ReadAmount` and also check `evt.isSecret`:

At line 326, change:
```lua
        local amt, isSecret = TryReadAmount(evt.amount)
```
To:
```lua
        local amt, isSecret = ReadAmount(evt.amount)
        if evt.isSecret then isSecret = true end
```

At line 395-396, change:
```lua
        local amt, isSecret   = TryReadAmount(evt.amount)
        local over, overSecret = TryReadAmount(evt.overheal)
```
To:
```lua
        local amt, isSecret   = ReadAmount(evt.amount)
        local over, overSecret = ReadAmount(evt.overheal)
        if evt.isSecret then isSecret = true; overSecret = true end
```

- [ ] **Step 3: Commit**

```bash
git add Core/Outgoing_Probe.lua
git commit -m "refactor: replace pcall secret detection with issecretvalue() in OutgoingProbe"
```

---

### Task 3: Update IncomingProbe for isSecret and crit support

**Files:**
- Modify: `Core/Incoming_Probe.lua:282-359` (`ProcessIncomingEvent`)
- Modify: `Core/Incoming_Probe.lua:42-48` (capability report)

**Context:** The incoming probe currently uses `tonumber(evt.amount)` which returns nil for secret values (silently dropping the event). It also has no crit detection. We need to:
1. Handle secret amounts (skip tonumber, skip thresholds, display via tostring)
2. Add crit color/formatting
3. Update the capability report to reflect CLEU source

- [ ] **Step 1: Update capability report source**

In `Core/Incoming_Probe.lua`, change the `cap` table at line 42-48:

```lua
Probe.cap = Probe.cap or {
    source = "UNIT_COMBAT",
    hasAmount = true, -- required
    hasFlagText = nil,
    hasSchool = nil,
    hasPeriodic = false -- UNIT_COMBAT does not provide reliable periodic classification
}
```

To:

```lua
Probe.cap = Probe.cap or {
    source = "CLEU",
    hasAmount = true,
    hasFlagText = true,
    hasSchool = true,
    hasPeriodic = true,
    hasCrit = true,
}
```

Also update the stale comment in `ResetCapture()` at line 99. Change:
```lua
    -- hasPeriodic remains false by design for UNIT_COMBAT.
```
To:
```lua
    -- hasPeriodic is always true with CLEU source.
```

- [ ] **Step 2: Update ProcessIncomingEvent for secret values and crits**

Replace `ProcessIncomingEvent` (lines 282-359) with:

```lua
function Probe:ProcessIncomingEvent(evt, isReplay)
    if not KSBT.db or not KSBT.db.profile or not KSBT.db.profile.incoming then
        return
    end

    local prof = KSBT.db.profile.incoming

    local kind = evt.kind
    if kind ~= "damage" and kind ~= "heal" then return end

    local conf = (kind == "damage") and prof.damage or prof.healing
    if not conf or not conf.enabled then return end

    -- Secret value handling: skip tonumber and thresholds
    local isSecret = evt.isSecret or (issecretvalue and issecretvalue(evt.amount) or false)
    local amt
    if isSecret then
        amt = evt.amount  -- pass through as-is; tostring() works via metamethod
    else
        amt = tonumber(evt.amount) or 0
        if amt <= 0 then return end

        local minT = tonumber(conf.minThreshold) or 0
        if amt < minT then return end
    end

    local area = conf.scrollArea or "Incoming"

    -- Format display text
    local text
    if isSecret then
        text = tostring(amt)
    else
        text = tostring(math.floor(amt + 0.5))
    end

    -- Optional flags (legacy support)
    if kind == "damage" and conf.showFlags and type(evt.flagText) ==
        "string" and evt.flagText ~= "" then
        text = text .. " " .. evt.flagText
    end

    -- Color: crit > school > custom > default
    local color = nil
    local isCrit = evt.isCrit == true

    if isCrit then
        if kind == "heal" then
            color = {r = 0.40, g = 1.00, b = 0.80}
        else
            color = {r = 1.00, g = 0.65, b = 0.00}
        end
        text = text .. "!"
    end

    if not color and prof.useSchoolColors and type(evt.schoolMask) == "number" then
        color = SchoolColorFromMask(evt.schoolMask)
    end

    local c = prof.customColor
    local hasCustom = (type(c) == "table") and (type(c.r) == "number") and
                          (type(c.g) == "number") and (type(c.b) == "number")
    local customIsWhite = hasCustom and (c.r == 1 and c.g == 1 and c.b == 1)

    if not color and hasCustom and not customIsWhite then
        color = {r = c.r, g = c.g, b = c.b}
    end

    if not color then
        if kind == "heal" then
            color = {r = 0.20, g = 1.00, b = 0.20}
        else
            color = {r = 1.00, g = 0.25, b = 0.25}
        end
    end

    local meta = {
        probe = true,
        replay = isReplay == true,
        kind = kind,
        school = evt.schoolMask,
        isCrit = isCrit,
        isPeriodic = evt.isPeriodic == true,
    }

    if KSBT.DisplayText then
        KSBT.DisplayText(area, text, color, meta)
    elseif KSBT.Core and KSBT.Core.Display and KSBT.Core.Display.Emit then
        KSBT.Core.Display:Emit(area, text, color, meta)
    end
end
```

- [ ] **Step 3: Commit**

```bash
git add Core/Incoming_Probe.lua
git commit -m "feat: add secret value handling and crit support to IncomingProbe"
```

---

## Chunk 2: Orchestration, Cleanup & UI

### Task 4: Remove OUTGOING_READY gate from Core.lua

**Files:**
- Modify: `Core/Core.lua:13-15` (delete OUTGOING_READY), `Core/Core.lua:118-120` (Enable), `Core/Core.lua:131-132` (Disable)

- [ ] **Step 1: Remove the OUTGOING_READY flag and its conditionals**

In `Core/Core.lua`:

Delete lines 13-15:
```lua
-- Outgoing combat text is under active development and not ready for release.
-- Set to true once the feature is confirmed working.
local OUTGOING_READY = false
```

Replace lines 118-120:
```lua
    if OUTGOING_READY and KSBT.Parser and KSBT.Parser.Outgoing and KSBT.Parser.Outgoing.Enable then
        KSBT.Parser.Outgoing:Enable()
    end
```
With nothing (delete these lines entirely).

Replace lines 131-132:
```lua
    if OUTGOING_READY and KSBT.Parser and KSBT.Parser.Outgoing and KSBT.Parser.Outgoing.Disable then
        KSBT.Parser.Outgoing:Disable()
    end
```
With nothing (delete these lines entirely).

- [ ] **Step 2: Commit**

```bash
git add Core/Core.lua
git commit -m "refactor: remove OUTGOING_READY gate — outgoing is now production-ready via CLEU"
```

---

### Task 5: Update Init.lua — simplify parser lifecycle

**Files:**
- Modify: `Core/Init.lua:72-134` (OnEnable, OnDisable)
- Modify: `Core/Init.lua:139-198` (HandleSlashCommand — remove probecombattext)

**Context:** The `OnEnable` currently enables `Parser.Incoming`, `Parser.CombatLog`, and `Parser.Cooldowns` separately. After this change, `Parser.CombatLog` handles both incoming and outgoing, so `Parser.Incoming` enable/disable calls are removed. Also remove the outgoing-not-ready comments and the `probecombattext` slash command.

- [ ] **Step 1: Update OnEnable (lines 72-111)**

Replace the parser enable block (lines 83-94):
```lua
        if KSBT.Parser then
            if KSBT.Parser.Incoming and KSBT.Parser.Incoming.Enable then
                KSBT.Parser.Incoming:Enable()
            end
            -- Outgoing is not ready for release; enabled only via Core.lua OUTGOING_READY flag
            if KSBT.Parser.CombatLog and KSBT.Parser.CombatLog.Enable then
                KSBT.Parser.CombatLog:Enable()
            end
            if KSBT.Parser.Cooldowns and KSBT.Parser.Cooldowns.Enable then
                KSBT.Parser.Cooldowns:Enable()
            end
        end
```

With:
```lua
        if KSBT.Parser then
            if KSBT.Parser.CombatLog and KSBT.Parser.CombatLog.Enable then
                KSBT.Parser.CombatLog:Enable()
            end
            if KSBT.Parser.Cooldowns and KSBT.Parser.Cooldowns.Enable then
                KSBT.Parser.Cooldowns:Enable()
            end
        end
```

Replace the parser disable block (lines 100-104):
```lua
            if KSBT.Parser.Incoming  and KSBT.Parser.Incoming.Disable  then KSBT.Parser.Incoming:Disable()  end
            -- Outgoing not active in this release
            if KSBT.Parser.Cooldowns and KSBT.Parser.Cooldowns.Disable then KSBT.Parser.Cooldowns:Disable() end
            if KSBT.Parser.CombatLog and KSBT.Parser.CombatLog.Disable then KSBT.Parser.CombatLog:Disable() end
```

With:
```lua
            if KSBT.Parser.CombatLog and KSBT.Parser.CombatLog.Disable then KSBT.Parser.CombatLog:Disable() end
            if KSBT.Parser.Cooldowns and KSBT.Parser.Cooldowns.Disable then KSBT.Parser.Cooldowns:Disable() end
```

- [ ] **Step 2: Update OnDisable (lines 116-134)**

Replace lines 117-128:
```lua
    if KSBT.Parser then
        if KSBT.Parser.Incoming and KSBT.Parser.Incoming.Disable then
            KSBT.Parser.Incoming:Disable()
        end
        -- Outgoing not active in this release
        if KSBT.Parser.Cooldowns and KSBT.Parser.Cooldowns.Disable then
            KSBT.Parser.Cooldowns:Disable()
        end
        if KSBT.Parser.CombatLog and KSBT.Parser.CombatLog.Disable then
            KSBT.Parser.CombatLog:Disable()
        end
    end
```

With:
```lua
    if KSBT.Parser then
        if KSBT.Parser.CombatLog and KSBT.Parser.CombatLog.Disable then
            KSBT.Parser.CombatLog:Disable()
        end
        if KSBT.Parser.Cooldowns and KSBT.Parser.Cooldowns.Disable then
            KSBT.Parser.Cooldowns:Disable()
        end
    end
```

- [ ] **Step 3: Remove probecombattext slash command**

In `HandleSlashCommand` (lines 139-198), delete the `probecombattext` handler block (lines 183-190):
```lua
    -- Diagnostic: test if COMBAT_TEXT_UPDATE fires in this build
    elseif cmd == "probecombattext" then
        if rest and rest:lower() == "stop" then
            self:StopCombatTextProbe(false)
        else
            self:StartCombatTextProbe(rest)
        end
        return
```

Update the `probeevents` comment at line 174 from:
```lua
    -- Diagnostic: dump raw UNIT_COMBAT + UNIT_SPELLCAST_SUCCEEDED to chat
```
To:
```lua
    -- Diagnostic: dump CLEU events to chat
```

Update the probeevents usage help at line 196 from:
```lua
    self:Print("  probeevents [sec|stop]   — dump UNIT_COMBAT events to chat")
```
To:
```lua
    self:Print("  probeevents [sec|stop]   — dump CLEU events to chat")
```

Also remove `probecombattext` from the usage help at line 197:
```lua
    self:Print("  probecombattext [sec|stop] — test if COMBAT_TEXT_UPDATE fires")
```

- [ ] **Step 4: Commit**

```bash
git add Core/Init.lua
git commit -m "refactor: simplify parser lifecycle — CombatLog parser handles both directions"
```

---

### Task 6: Update Diagnostics — CLEU probe, remove CTU probe

**Files:**
- Modify: `Core/Diagnostics.lua:101-208`

**Context:** The `probeevents` slash command currently dumps `UNIT_COMBAT` events. Update it to dump CLEU events instead. Delete the entire `probecombattext` probe (it tested a forbidden API).

- [ ] **Step 1: Replace the event probe with a CLEU-based probe**

Replace lines 101-152 (the UNIT_COMBAT event probe) with:

```lua
------------------------------------------------------------------------
-- CLEU Event Probe (#2)
-- Registers a standalone frame that dumps COMBAT_LOG_EVENT_UNFILTERED
-- events to chat for a set duration. Filters to player srcGUID/destGUID.
------------------------------------------------------------------------
local _eventProbeFrame = nil
local _eventProbeTimer = nil

function Addon:StartEventProbe(secondsStr)
    local seconds = tonumber(secondsStr) or 30
    if seconds < 5 then seconds = 5 end
    if seconds > 120 then seconds = 120 end

    if _eventProbeFrame then
        self:Print("Event probe already running. Use '/ksbt probeevents stop' to stop it.")
        return
    end

    local playerGUID = UnitGUID("player")

    _eventProbeFrame = CreateFrame("Frame")
    _eventProbeFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

    _eventProbeFrame:SetScript("OnEvent", function()
        local ts, sub, _, srcGUID, srcName, srcFlags, _,
              destGUID, destName, destFlags, _, ... = CombatLogGetCurrentEventInfo()

        local isPlayer = (srcGUID == playerGUID) or (destGUID == playerGUID)
        if not isPlayer then return end

        local dir = (srcGUID == playerGUID) and "OUT" or "IN"
        local args = {...}
        local argStr = ""
        for i = 1, math.min(#args, 8) do
            argStr = argStr .. " " .. tostring(args[i])
        end

        print("|cffff9900KSBT-Probe|r [" .. dir .. "] " .. tostring(sub)
            .. " src=" .. tostring(srcName)
            .. " dst=" .. tostring(destName)
            .. argStr)
    end)

    self:Print(("CLEU event probe STARTED for %ds. Attack something or take damage."):format(seconds))

    _eventProbeTimer = C_Timer.After(seconds, function()
        Addon:StopEventProbe(true)
    end)
end

function Addon:StopEventProbe(auto)
    if not _eventProbeFrame then
        self:Print("Event probe is not running.")
        return
    end
    _eventProbeFrame:UnregisterAllEvents()
    _eventProbeFrame:SetScript("OnEvent", nil)
    _eventProbeFrame = nil
    _eventProbeTimer = nil
    self:Print("Event probe " .. (auto and "ended (timeout)." or "stopped."))
end
```

- [ ] **Step 2: Delete the COMBAT_TEXT_UPDATE probe**

Delete lines 154-208 entirely (the `StartCombatTextProbe` and `StopCombatTextProbe` functions and their locals).

- [ ] **Step 3: Commit**

```bash
git add Core/Diagnostics.lua
git commit -m "refactor: update diagnostic probe to use CLEU, remove obsolete CTU probe"
```

---

### Task 7: Uncomment Outgoing config tab

**Files:**
- Modify: `UI/Config.lua:112-115`

- [ ] **Step 1: Uncomment the Outgoing tab**

In `UI/Config.lua`, change lines 112-115:

```lua
            ----------------------------------------------------------------
            -- Tab 4: Outgoing (hidden until feature is functional)
            -- outgoing = KSBT.BuildTab_Outgoing(),
            ----------------------------------------------------------------
```

To:

```lua
            ----------------------------------------------------------------
            -- Tab 4: Outgoing
            ----------------------------------------------------------------
            outgoing = KSBT.BuildTab_Outgoing(),

```

- [ ] **Step 2: Commit**

```bash
git add UI/Config.lua
git commit -m "feat: enable Outgoing config tab — no longer hidden"
```

---

### Task 8: Delete old parsers and update .toc

**Files:**
- Delete: `Parser/Outgoing_Detect.lua`
- Delete: `Parser/Incoming_Detect.lua`
- Modify: `KBST.toc:43-44`

- [ ] **Step 1: Delete the old parser files**

```bash
git rm Parser/Outgoing_Detect.lua
git rm Parser/Incoming_Detect.lua
```

- [ ] **Step 2: Update the .toc file**

In `KBST.toc`, remove lines 43-44:

```
Parser\Incoming_Detect.lua
Parser\Outgoing_Detect.lua
```

Also update the section comment at line 39 from:
```
# Parser (Detection) - Skeletons
```
To:
```
# Parser (Detection)
```

The Parser section should now read:

```
# Parser (Detection)
Parser\Normalize.lua
Parser\CombatLog_Detect.lua
Parser\Cooldowns_Detect.lua
```

- [ ] **Step 3: Commit**

```bash
git add KBST.toc
git commit -m "chore: remove old UNIT_COMBAT parsers, update .toc load order"
```

---

### Task 9: In-game validation

This task cannot be automated — it requires manual testing in WoW.

- [ ] **Step 1: Basic load test**

1. Copy the addon to your WoW AddOns folder
2. `/reload` in game
3. Verify no Lua errors on load
4. Type `/ksbt` — config should open with the Outgoing tab visible

- [ ] **Step 2: Outgoing damage test (solo)**

1. Enable KSBT, enable Outgoing Damage in the new tab
2. Attack a training dummy
3. Verify: auto-attack damage appears in the Outgoing scroll area
4. Cast a spell — verify spell damage appears with spell name (if showSpellNames enabled)
5. Verify crits show gold color with "!" suffix

- [ ] **Step 3: Outgoing healing test**

1. Enable Outgoing Healing
2. Cast a heal on yourself or a party member
3. Verify healing numbers appear in the Outgoing scroll area

- [ ] **Step 4: Incoming damage test**

1. Ensure Incoming Damage is enabled (was already working before)
2. Take damage from a mob
3. Verify incoming damage still appears correctly
4. Verify crit incoming damage now shows gold/orange color (new feature)

- [ ] **Step 5: CLEU probe diagnostic**

1. Run `/ksbt probeevents 30`
2. Attack a dummy and take some damage
3. Verify CLEU events print to chat with `[OUT]` and `[IN]` prefixes
4. Verify the probe stops after 30 seconds

- [ ] **Step 6: Restricted content test (if available)**

1. Enter a M+ dungeon or boss encounter
2. Verify combat text still displays (amounts may look different due to secret values)
3. Verify no Lua errors during the encounter
4. After leaving restricted content, verify normal numbers resume
