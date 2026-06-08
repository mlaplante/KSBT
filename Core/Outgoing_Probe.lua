------------------------------------------------------------------------
-- Kroth's Scrolling Battle Text - Outgoing Probe / Replay Harness (UI/UX Validation)
--
-- Purpose:
--   - Capture *real* outgoing events (from Parser.CombatLog) into a ring buffer
--   - Replay captured events through display routing to validate the Outgoing UI
--
-- Scope rules for this probe:
--   - Outgoing = player-only. Pet/guardian damage must NOT appear here.
--   - This is NOT the engine. No attribution beyond player-only flag filtering.
--   - Throttling and dummy suppression are applied here. No merging or learning.
------------------------------------------------------------------------
local ADDON_NAME, KSBT = ...

KSBT.Core = KSBT.Core or {}
KSBT.Core.OutgoingProbe = KSBT.Core.OutgoingProbe or {}
local Probe = KSBT.Core.OutgoingProbe
local Addon = KSBT.Addon

-- Internal state
Probe._initialized = Probe._initialized or false
Probe._capturing = Probe._capturing or false
Probe._replaying = Probe._replaying or false
Probe._captureEnds = Probe._captureEnds or 0
Probe._ticker = Probe._ticker or nil

Probe._maxBuffer = Probe._maxBuffer or 300
Probe._buffer = Probe._buffer or {}
Probe._bufHead = Probe._bufHead or 0
Probe._bufCount = Probe._bufCount or 0

-- Spam control: merge pending events
-- Key: kind .. "_" .. spellId .. "_" .. area  →  entry table
local _mergeState = {}

local band = bit.band

-- Training dummy detection (for suppressDummyDamage)
local _DUMMY_TYPE_NPC         = COMBATLOG_OBJECT_TYPE_NPC        or 0x00000800
local _DUMMY_REACTION_NEUTRAL = COMBATLOG_OBJECT_REACTION_NEUTRAL or 0x00000020

local function IsDummyTarget(destFlags)
    if not destFlags then return false end
    -- destFlags can be a secret number in boss encounters; pcall protects band()
    local ok, result = pcall(function()
        return band(destFlags, _DUMMY_TYPE_NPC) ~= 0
           and band(destFlags, _DUMMY_REACTION_NEUTRAL) ~= 0
    end)
    return ok and result or false
end

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

-- Spell filter: per-character whitelist/blacklist with auto-discovery.
-- Returns: "auto" (use thresholds), "show" (whitelist), "hide" (blacklist), or nil (no spellId)

-- Cap on auto-discovered entries to prevent saved-variable bloat over long play sessions.
-- User-configured entries (show/hide) are never pruned.
local SPELL_FILTER_MAX = 500
local SPELL_FILTER_PRUNE_TARGET = 400  -- prune down to this count when cap is exceeded

local function PruneSpellFilters(filters)
    -- Count total entries and collect auto-mode keys for eviction candidates.
    local total = 0
    local autoCandidates = {}
    for k, v in pairs(filters) do
        total = total + 1
        if v.mode == "auto" or v.mode == nil then
            autoCandidates[#autoCandidates + 1] = k
        end
    end
    if total <= SPELL_FILTER_MAX then return end

    -- Remove auto entries until we reach the prune target.
    local toRemove = total - SPELL_FILTER_PRUNE_TARGET
    for i = 1, math.min(toRemove, #autoCandidates) do
        filters[autoCandidates[i]] = nil
    end
end

function KSBT.GetSpellFilterMode(spellId, spellName, kind)
    if not spellId or spellId == 0 then return nil end
    local charDb = KSBT.db and KSBT.db.char
    if not charDb or not charDb.spellFilters then return nil end

    local key = tostring(spellId)
    local entry = charDb.spellFilters[key]
    if not entry then
        -- First time seeing this spell — auto-discover.
        -- Prune excess auto entries before adding to keep saved-variable size bounded.
        PruneSpellFilters(charDb.spellFilters)
        local name = spellName
        if (not name or name == "") and C_Spell and C_Spell.GetSpellInfo then
            local info = C_Spell.GetSpellInfo(spellId)
            name = info and info.name
        end
        charDb.spellFilters[key] = {
            mode = "auto",
            name = name or ("Unknown (" .. key .. ")"),
            kind = kind or "damage",
        }
        return "auto"
    end

    -- Update name/kind if they were missing
    if spellName and spellName ~= "" and (not entry.name or entry.name:match("^Unknown")) then
        entry.name = spellName
    end
    if kind and not entry.kind then
        entry.kind = kind
    end

    return entry.mode or "auto"
end

------------------------------------------------------------------------
-- Percentile-based font scaling (session-only, not persisted)
------------------------------------------------------------------------
local _spellHistory = {}     -- Key: spellId (number), Value: sorted array of amounts
local MAX_HISTORY = 200      -- max samples per spell
local MIN_SAMPLES = 20       -- minimum before scaling activates

-- Insert a value into a sorted array, maintaining sort order.
-- If array exceeds MAX_HISTORY, evict the median to preserve tail shape.
local function RecordSpellAmount(spellId, amount)
    if not spellId or spellId == 0 or not amount or amount <= 0 then return end

    local hist = _spellHistory[spellId]
    if not hist then
        hist = {}
        _spellHistory[spellId] = hist
    end

    -- Binary search for insert position
    local lo, hi = 1, #hist
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if hist[mid] < amount then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    table.insert(hist, lo, amount)

    -- Evict median if over capacity (preserves both tails)
    if #hist > MAX_HISTORY then
        local median = math.floor(#hist / 2)
        table.remove(hist, median)
    end
end

-- Returns a font scale factor (1.0 to maxScale) based on percentile position.
-- Returns 1.0 if not enough samples or amount is below threshold.
local function GetPercentileScale(spellId, amount)
    if not spellId or spellId == 0 or not amount or amount <= 0 then return 1.0 end

    local charDb = KSBT.db and KSBT.db.char
    local conf = charDb and charDb.spamControl and charDb.spamControl.percentileScaling
    if not conf or not conf.enabled then return 1.0 end

    local hist = _spellHistory[spellId]
    if not hist or #hist < MIN_SAMPLES then return 1.0 end

    local pct = (tonumber(conf.percentile) or 95) / 100
    local maxScale = tonumber(conf.maxScale) or 1.5
    if maxScale <= 1.0 then return 1.0 end

    local thresholdIdx = math.floor(#hist * pct)
    if thresholdIdx < 1 then thresholdIdx = 1 end
    local threshold = hist[thresholdIdx]
    local maxVal = hist[#hist]

    if amount < threshold then return 1.0 end
    if maxVal <= threshold then return maxScale end

    -- Lerp between 1.0 and maxScale based on position between threshold and max
    local t = (amount - threshold) / (maxVal - threshold)
    if t > 1.0 then t = 1.0 end
    return 1.0 + t * (maxScale - 1.0)
end

local function MergeKey(kind, spellId, area)
    return tostring(kind) .. "_" .. tostring(spellId or "0") .. "_" .. tostring(area)
end

local function FlushMerge(key)
    local entry = _mergeState[key]
    if not entry then return end
    _mergeState[key] = nil

    if entry.timer then entry.timer:Cancel() end

    local db = KSBT.db and KSBT.db.profile
    local charDb = KSBT.db and KSBT.db.char

    -- Post-merge threshold check (skip for secret values and whitelisted spells)
    local isWhitelisted = entry.meta and entry.meta.whitelisted
    if not entry.isSecret and not isWhitelisted then
        local throttle = charDb and charDb.spamControl and charDb.spamControl.throttling
        if throttle then
            local postMin
            if entry.kind == "damage" then
                postMin = tonumber(throttle.postMergeDamage) or 0
            else
                postMin = tonumber(throttle.postMergeHealing) or 0
            end
            if postMin > 0 and entry.count > 1 and entry.totalAmount < postMin then
                return  -- merged total below post-merge threshold; discard
            end
        end
    end

    -- Compose display text from accumulated data
    local text
    if entry.isSecret then
        text = entry.secretText or "?"
    else
        text = KSBT.FormatNumber and KSBT.FormatNumber(entry.totalAmount) or tostring(math.floor(entry.totalAmount + 0.5))
    end

    -- Spell name (from first tick's meta)
    local prof = db and db.outgoing
    if prof and prof.showSpellNames and entry.meta and entry.meta.spellName
    and entry.meta.spellName ~= "" and not entry.meta.isAuto then
        text = text .. " " .. entry.meta.spellName
    end

    -- Target name (damage only)
    if entry.kind == "damage" and prof and prof.damage and prof.damage.showTargets
    and entry.meta and entry.meta.targetName and entry.meta.targetName ~= "" then
        text = text .. " -> " .. entry.meta.targetName
    end

    -- Overheal display (healing only)
    if entry.kind == "heal" and not entry.isSecret then
        local healConf = prof and prof.healing
        if healConf and healConf.showOverheal and (entry.totalOverheal or 0) > 0 then
            text = text .. " (OH " .. tostring(math.floor(entry.totalOverheal + 0.5)) .. ")"
        end
    end

    -- Crit marker: if any tick in the group was a crit, promote the merged display
    local color = entry.color
    -- Shallow-copy meta to avoid mutating the original reference
    local meta = {}
    for k, v in pairs(entry.meta or {}) do meta[k] = v end
    if entry.hasCrit then
        text = text .. "!"
        meta.isCrit = true
        if entry.kind == "damage" then
            color = {r = 1.00, g = 0.65, b = 0.00}
        else
            color = {r = 0.40, g = 1.00, b = 0.80}
        end
    end

    -- Merge count suffix
    local showCount = charDb and charDb.spamControl and charDb.spamControl.merging
                      and charDb.spamControl.merging.showCount
    if entry.count > 1 and showCount then
        text = text .. " x" .. entry.count
    end

    -- Percentile-based font scaling
    if not entry.isSecret and entry.spellId then
        local scale = GetPercentileScale(entry.spellId, entry.totalAmount)
        if scale > 1.0 then
            meta.fontScale = scale
        end
        -- Record merged total for future percentile checks
        RecordSpellAmount(entry.spellId, entry.totalAmount)
    end

    if KSBT.DisplayText then
        KSBT.DisplayText(entry.area, text, color, meta)
    elseif KSBT.Core and KSBT.Core.Display and KSBT.Core.Display.Emit then
        KSBT.Core.Display:Emit(entry.area, text, color, meta)
    end
end

-- Emit an event, merging with previous if spam control is active.
-- amount: numeric value for accumulation (nil/0 for secret values)
-- baseText: the raw number string (used for non-merged direct emit)
-- text: the fully composed display string (used for non-merged direct emit)
-- isSecret: true if amount is a WoW secret number (skip arithmetic)
local function EmitOrMerge(kind, spellId, area, amount, baseText, text, color, meta, isReplay, isSecret)
    local db = KSBT.db and KSBT.db.profile
    local charDb = KSBT.db and KSBT.db.char
    local mergeEnabled = charDb and charDb.spamControl and charDb.spamControl.merging
                         and charDb.spamControl.merging.enabled
    local mergeWindow  = (charDb and charDb.spamControl and charDb.spamControl.merging
                         and charDb.spamControl.merging.window) or 1.5

    if mergeEnabled and not isReplay and not (meta and meta.noMerge) then
        local mkey = MergeKey(kind, spellId, area)
        local existing = _mergeState[mkey]

        if existing then
            -- Same spell in same area — accumulate
            existing.count = existing.count + 1
            if not isSecret and not existing.isSecret then
                existing.totalAmount = existing.totalAmount + (amount or 0)
                existing.totalOverheal = (existing.totalOverheal or 0) + (meta.overhealAmount or 0)
            else
                existing.isSecret = true
            end
            if meta.isCrit then existing.hasCrit = true end
            if meta.whitelisted then
                existing.meta = existing.meta or {}
                existing.meta.whitelisted = true
            end
            if existing.timer then existing.timer:Cancel() end
            existing.timer = C_Timer.NewTimer(mergeWindow, function()
                FlushMerge(mkey)
            end)
        else
            -- First occurrence — start new entry
            _mergeState[mkey] = {
                kind         = kind,
                spellId      = spellId,
                area         = area,
                totalAmount  = amount or 0,
                totalOverheal = meta.overhealAmount or 0,
                count        = 1,
                color        = color,
                meta         = meta,
                isSecret     = isSecret == true,
                hasCrit      = meta.isCrit == true,
                secretText   = isSecret and baseText or nil,
                timer        = C_Timer.NewTimer(mergeWindow, function()
                    FlushMerge(mkey)
                end),
            }
        end
    else
        -- No merging — emit directly
        if KSBT.DisplayText then
            KSBT.DisplayText(area, text, color, meta)
        elseif KSBT.Core and KSBT.Core.Display and KSBT.Core.Display.Emit then
            KSBT.Core.Display:Emit(area, text, color, meta)
        end
    end
end

local function Now() return (GetTime and GetTime()) or 0 end

local function Debug(level, ...)
    if Addon and Addon.DebugPrint then Addon:DebugPrint(level, ...) end
end

local function PushEvent(evt)
    Probe._bufHead = (Probe._bufHead % Probe._maxBuffer) + 1
    Probe._buffer[Probe._bufHead] = evt
    Probe._bufCount = math.min(Probe._bufCount + 1, Probe._maxBuffer)
end

local function SnapshotBuffer()
    local out = {}
    if Probe._bufCount == 0 then return out end

    local start = Probe._bufHead - Probe._bufCount + 1
    for i = 0, Probe._bufCount - 1 do
        local idx = start + i
        while idx <= 0 do idx = idx + Probe._maxBuffer end
        while idx > Probe._maxBuffer do idx = idx - Probe._maxBuffer end
        out[#out + 1] = Probe._buffer[idx]
    end
    return out
end

function Probe:Init()
    if self._initialized then return end
    self._initialized = true
    Debug(1, "Core.OutgoingProbe:Init()")
end

function Probe:IsCapturing() return self._capturing == true end
function Probe:IsReplaying() return self._replaying == true end

function Probe:ResetCapture()
    self._buffer = {}
    self._bufHead = 0
    self._bufCount = 0
end

function Probe:StartCapture(seconds)
    self:Init()

    if self._capturing then return end
    self:StopReplay(false)

    seconds = tonumber(seconds) or 30
    if seconds < 1 then seconds = 1 end
    if seconds > 120 then seconds = 120 end

    self:ResetCapture()

    self._capturing = true
    self._captureEnds = Now() + seconds

    Debug(1, ("Core.OutgoingProbe:StartCapture(%ss)"):format(seconds))
    if Addon and Addon.Print then
        Addon:Print(
            ("Outgoing probe capture started (%ss). Auto-attack and cast a few spells; do at least one heal if possible.")
                :format(seconds))
    end

    C_Timer.After(seconds, function()
        if Probe and Probe._capturing then Probe:StopCapture(true) end
    end)
end

function Probe:StopCapture(auto)
    if not self._capturing then return end
    self._capturing = false
    self._captureEnds = 0

    Debug(1, "Core.OutgoingProbe:StopCapture()")
    if Addon and Addon.Print then
        Addon:Print(("Outgoing probe capture %s. Captured %d events.")
                        :format(auto and "ended" or "stopped", self._bufCount))
    end
end

function Probe:Replay(speed)
    self:Init()
    if self._replaying then return end
    self:StopCapture(false)

    local events = SnapshotBuffer()
    if #events == 0 then
        if Addon and Addon.Print then
            Addon:Print("Outgoing probe has no captured events to replay. Capture first.")
        end
        return
    end

    speed = tonumber(speed) or 1.0
    if speed < 0.25 then speed = 0.25 end
    if speed > 4.0 then speed = 4.0 end

    self._replaying = true
    local i = 1

    Debug(1, ("Core.OutgoingProbe:Replay(speed=%s) events=%d"):format(speed, #events))
    if Addon and Addon.Print then
        Addon:Print(("Outgoing probe replay started (%d events, speed x%.2f).")
                        :format(#events, speed))
    end

    local interval = 0.20 / speed
    self._ticker = C_Timer.NewTicker(interval, function()
        if not Probe or not Probe._replaying then return end
        local evt = events[i]
        if evt then
            Probe:ProcessOutgoingEvent(evt, true)
            i = i + 1
        end
        if i > #events then Probe:StopReplay(true) end
    end)
end

function Probe:StopReplay(auto)
    if not self._replaying then return end
    self._replaying = false

    if self._ticker then
        self._ticker:Cancel()
        self._ticker = nil
    end

    Debug(1, "Core.OutgoingProbe:StopReplay()")
    if Addon and Addon.Print then
        Addon:Print(("Outgoing probe replay %s."):format(auto and "completed" or "stopped"))
    end
end

function Probe:GetStatusLine()
    local cap = {}
    cap.bufferCount = self._bufCount or 0
    cap.bufferMax = self._maxBuffer or 0
    cap.capturing = self._capturing == true
    cap.replaying = self._replaying == true
    return cap
end

-- evt contract from Parser.CombatLog:
-- {
--   ts=number,
--   kind="damage"|"heal",
--   amount=number,
--   overheal=number|nil,
--   isAuto=true|false,
--   isCrit=true|false,
--   spellID=number|nil,
--   spellName=string|nil,
--   targetName=string|nil,
--   schoolMask=number|nil,
-- }
function Probe:OnOutgoingDetected(evt)
    if not evt or type(evt) ~= "table" then return end

    -- Record into ring buffer only during an active capture session.
    if self._capturing then
        PushEvent(evt)
    end

    -- Always emit live so combat text displays during normal gameplay.
    self:ProcessOutgoingEvent(evt, false)
end

function Probe:ProcessOutgoingEvent(evt, isReplay)
    if not KSBT.db or not KSBT.db.profile or not KSBT.db.profile.outgoing then
        return
    end

    local prof = KSBT.db.profile.outgoing
    local kind = evt.kind
    if kind ~= "damage" and kind ~= "heal" then return end

    if kind == "damage" then
        local conf = prof.damage
        if not conf or not conf.enabled then return end

        -- Auto-attack filtering (no amount needed).
        if evt.isAuto == true then
            local mode = tostring(conf.autoAttackMode or "Show All")
            if mode == "Hide" then return end
            if mode == "Show Only Crits" and evt.isCrit ~= true then return end
        end

        -- Spell filter check (per-character overrides)
        local spellFilterMode = KSBT.GetSpellFilterMode(evt.spellId, evt.spellName, "damage")
        if spellFilterMode == "hide" then return end

        local amt, isSecret = ReadAmount(evt.amount)
        if evt.isSecret then isSecret = true end

        -- Record for percentile tracking (before filtering, all hits count)
        if not isSecret and evt.spellId then
            RecordSpellAmount(evt.spellId, amt)
        end

        -- When readable: apply min-threshold and spam controls.
        if not isSecret and spellFilterMode ~= "show" and spellFilterMode ~= "show_nomerge" then
            if amt <= 0 then return end

            local minT = tonumber(conf.minThreshold) or 0
            if amt < minT then return end

            local spamConf = KSBT.db.char.spamControl
            local throttle = spamConf and spamConf.throttling
            if throttle then
                local globalMin = tonumber(throttle.minDamage) or 0
                if globalMin > 0 and amt < globalMin then return end

                local hideAutoBelow = tonumber(throttle.hideAutoBelow) or 0
                if evt.isAuto and hideAutoBelow > 0 and amt < hideAutoBelow then return end
            end

            if spamConf and spamConf.suppressDummyDamage then
                if IsDummyTarget(evt.destFlags) then return end
            end
        elseif not isSecret then
            -- Whitelisted: still need amt > 0 check
            if amt <= 0 then return end
        end

        -- Build display text.
        -- Secret amounts: tostring() works via Blizzard metamethod; skip spell/target append.
        local baseText = isSecret and tostring(evt.amount) or (KSBT.FormatNumber and KSBT.FormatNumber(amt) or tostring(math.floor(amt + 0.5)))
        local text = baseText

        if not isSecret and prof.showSpellNames and evt.isAuto ~= true
        and type(evt.spellName) == "string" and evt.spellName ~= "" then
            text = text .. " " .. evt.spellName
        end

        if not isSecret and conf.showTargets
        and type(evt.targetName) == "string" and evt.targetName ~= "" then
            text = text .. " -> " .. evt.targetName
        end

        local meta = {
            probe = true,
            replay = isReplay == true,
            kind = kind,
            isAuto = evt.isAuto == true,
            isCrit = evt.isCrit == true,
            school = evt.schoolMask,
            spellId = evt.spellId,
            spellName = evt.spellName,
            targetName = evt.targetName,
            whitelisted = (spellFilterMode == "show" or spellFilterMode == "show_nomerge"),
        }

        -- Per-spell merge control
        if spellFilterMode == "auto_nomerge" or spellFilterMode == "show_nomerge" then
            meta.noMerge = true
        end

        local color
        if meta.isCrit then
            color = {r = 1.00, g = 0.65, b = 0.00}
            text = text .. "!"
        else
            color = {r = 1.00, g = 0.25, b = 0.25}
        end

        if not meta.isCrit and not isSecret then
            local prof2 = KSBT.db.profile
            if prof2.incoming and prof2.incoming.useSchoolColors then
                local sc = KSBT.SchoolColorFromMask and KSBT.SchoolColorFromMask(evt.schoolMask)
                if sc then color = sc end
            end
        end

        -- Percentile font scaling for direct (non-merged) emit
        if not isSecret and evt.spellId then
            local scale = GetPercentileScale(evt.spellId, amt)
            if scale > 1.0 then
                meta.fontScale = scale
            end
        end

        EmitOrMerge(kind, evt.spellId, conf.scrollArea or "Outgoing", amt, baseText, text, color, meta, isReplay, isSecret)

    else  -- heal
        local conf = prof.healing
        if not conf or not conf.enabled then return end

        -- Spell filter check (per-character overrides)
        local spellFilterMode = KSBT.GetSpellFilterMode(evt.spellId, evt.spellName, "heal")
        if spellFilterMode == "hide" then return end

        local amt, isSecret   = ReadAmount(evt.amount)
        local over, overSecret = ReadAmount(evt.overheal)
        if evt.isSecret then isSecret = true; overSecret = true end

        -- Record for percentile tracking BEFORE filtering (all hits count)
        if not isSecret and not overSecret and evt.spellId then
            local rawOver = over
            if rawOver < 0 then rawOver = 0 end
            local recordAmt = amt - rawOver
            if recordAmt > 0 then
                RecordSpellAmount(evt.spellId, recordAmt)
            end
        end

        -- When amounts are readable: apply overheal subtraction, thresholds, throttling.
        local displayAmt
        if not isSecret and not overSecret and spellFilterMode ~= "show" and spellFilterMode ~= "show_nomerge" then
            if over < 0 then over = 0 end
            displayAmt = conf.showOverheal and amt or (amt - over)
            if displayAmt <= 0 then return end

            local minT = tonumber(conf.minThreshold) or 0
            if displayAmt < minT then return end

            local spamConf2 = KSBT.db.char.spamControl
            local throttle2 = spamConf2 and spamConf2.throttling
            if throttle2 then
                local globalMin = tonumber(throttle2.minHealing) or 0
                if globalMin > 0 and displayAmt < globalMin then return end
            end
        elseif not isSecret and not overSecret then
            -- Whitelisted: still compute displayAmt
            if over < 0 then over = 0 end
            displayAmt = conf.showOverheal and amt or (amt - over)
            if displayAmt <= 0 then return end
        end
        -- Secret: skip all arithmetic checks; trust CLEU that an event occurred.

        local baseText
        if isSecret or overSecret then
            -- Secret value: tostring() works; overheal arithmetic skipped.
            baseText = tostring(evt.amount)
        else
            baseText = KSBT.FormatNumber and KSBT.FormatNumber(displayAmt) or tostring(math.floor(displayAmt + 0.5))
        end
        local text = baseText

        if prof.showSpellNames and type(evt.spellName) == "string" and evt.spellName ~= "" then
            text = text .. " " .. evt.spellName
        end

        if not isSecret and not overSecret and conf.showOverheal and over > 0 then
            text = text .. " (OH " .. tostring(math.floor(over + 0.5)) .. ")"
        end

        local meta = {
            probe = true,
            replay = isReplay == true,
            kind = kind,
            isCrit = evt.isCrit == true,
            school = evt.schoolMask,
            spellId = evt.spellId,
            spellName = evt.spellName,
            overhealAmount = (not isSecret and not overSecret) and over or 0,
            whitelisted = (spellFilterMode == "show" or spellFilterMode == "show_nomerge"),
        }

        -- Per-spell merge control
        if spellFilterMode == "auto_nomerge" or spellFilterMode == "show_nomerge" then
            meta.noMerge = true
        end

        local color
        if meta.isCrit then
            color = {r = 0.40, g = 1.00, b = 0.80}
            text = text .. "!"
        else
            color = {r = 0.20, g = 1.00, b = 0.20}
        end

        -- Percentile font scaling for direct (non-merged) emit
        if not isSecret and not overSecret and evt.spellId and displayAmt then
            local scale = GetPercentileScale(evt.spellId, displayAmt)
            if scale > 1.0 then
                meta.fontScale = scale
            end
        end

        local emitAmt = (not isSecret and not overSecret) and displayAmt or 0
        EmitOrMerge(kind, evt.spellId, conf.scrollArea or "Outgoing", emitAmt, baseText, text, color, meta, isReplay, isSecret or overSecret)
    end
end
