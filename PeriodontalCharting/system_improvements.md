# NLP System — Corrected Improvements Plan

The previous analysis contained **two critically wrong fix proposals** that break the existing transcripts. This document retracts those, explains exactly why, and provides a corrected list of what is genuinely safe to implement.

---

## ❌ RETRACTED — Fixes that break existing functionality

### ~~Issue 8/9 — Sign change in `flushNumbers`~~

**Original proposal:** Replace `abs(n) * currentMetricMultiplier` with `n * currentMetricMultiplier`.

**Why it's wrong — transcript proof:**

`dr_lucky_ground.txt` line 7:
```
resesi dari mesio bukal 17 sampai disto bukal 15 minus 1
```

The `"minus 1"` handler appends `-1` to `currentNumbers`. Then `flushNumbers` runs:
- **Current code:** `abs(-1) * -1 = -1` ✓ recession correctly stored
- **Proposed fix:** `-1 * -1 = +1` ✗ — stored as positive (pseudopocket), completely wrong

The `abs()` is **intentional**. It strips the sign before applying the metric-direction multiplier. The `"minus"` keyword and the `"resesi"` multiplier are two independent sign-control mechanisms that should NOT interact. The `"margin minus 2"` edge case I identified is a real but **acceptable limitation** — in clinical practice, recording a negative gingival margin with the `"margin"` keyword is non-standard. This fix must **not** be implemented.

---

### ~~Bug 3 — `lastAutoAdvancedFromTooth` in `restoreToMainSequence`~~

**Original proposal:** Add `lastAutoAdvancedFromTooth = nil` to `restoreToMainSequence()`.

**Why it's wrong — call-site analysis:**

Every call site of `restoreToMainSequence()` that is followed by more tokens **already** clears `lastAutoAdvancedFromTooth` before calling it:

| Call site | Clear happens before? |
|---|---|
| `.action(.next/.commit)` | Yes — `lastAutoAdvancedFromTooth = nil` at the top of the `.action` case |
| `.action(.missing)` | Yes — same |
| `.action(.anatomy jaw)` | Yes — the snap-back check fires and clears, or there are no more tokens |
| `.number` case → `flushPostTargetIfPending()` | **No** — but `lastAutoAdvancedFromTooth = nil` is set on line 48 *after* the call. Any subsequent token processes with `nil`. |
| `isFinal` block | No more tokens follow, so stale value is harmless |

The only potentially dangerous path (`.number` → `flushPostTargetIfPending()` → `restoreToMainSequence()` with stale `lastAutoAdvancedFromTooth`) is safe because:
1. The `.number` handler sets `lastAutoAdvancedFromTooth = nil` on line 48, right after `flushPostTargetIfPending()` returns
2. No snap-back can fire between the `restoreToMainSequence()` call and that line 48 assignment (it's synchronous)

Furthermore, the parser is **re-instantiated on every word** (`AIVoiceViewModel` creates a fresh `VoiceCommandParser` each call), so `lastAutoAdvancedFromTooth` can never accumulate across words anyway. Adding this to `restoreToMainSequence()` is **not needed and creates unnecessary cognitive complexity**.

---

## ✅ CONFIRMED SAFE — Fixes with no behavior impact on existing transcripts

---

### Fix 1 — Force-unwrap crash protection (Bug 1)
**File:** `VoiceCommandParser+Lookahead.swift`, line 41

```swift
// BEFORE
return (resolved.aspect!, resolved.site)

// AFTER
guard let aspect = resolved.aspect else { return nil }
return (aspect, resolved.site)
```

**Transcript impact:** Zero. The `resolved.aspect` is only nil for jaw-type anatomy tokens, and the call sites filter those out. This is purely a defensive change for future extensibility. Does not alter any token's output.

---

### Fix 2 — `_sep_` barrier in `.toothIdentifier` range lookahead (Bug 2)
**File:** `VoiceCommandParser+Parse.swift`, lines 162–165

```swift
// BEFORE
while peek < tokens.count {
    if case .word(_) = tokens[peek] { peek += 1; continue }
    break
}

// AFTER
while peek < tokens.count {
    if case .word(let w) = tokens[peek], w != "_sep_" { peek += 1; continue }
    break
}
```

**Transcript impact check for `dr_lucky_ground`:**

- Line 32: `"BOP dari Mesio palatal 26 sampai Disto palatal 24."` — The period becomes `_sep_` AFTER `24`, not between `26` and `sampai`. The `sampai` range lookahead starts from `26` and looks rightward — it finds `sampai` before hitting any `_sep_`. ✓ Safe.
- Line 33: `"Lanjut, 23."` — No range, no impact. ✓
- Line 46: `"15 palatal. Resesi palatal dan disto palatal 1."` — The `15` is followed by `palatal`, then `_sep_`. No `sampai`/`hingga` after `15`, so the range lookahead terminates immediately at `_sep_`. ✓ Safe.
- Line 47: `"16 Resesi Mesio palatal 2. palatal 4. Disto palatal 2"` — `16` is followed by `Resesi`, not `sampai`. ✓ Not a range, no impact.

**Transcript impact check for `student_ground`:** None of the range patterns in `student_ground` have a `_sep_` between a tooth number and `sampai`/`hingga`. ✓ Safe.

---

### Fix 3 — Explicit `.from` no-op (Issue 9 / code clarity)
**File:** `VoiceCommandParser+Parse.swift` — the `.action` switch

```swift
// Add this branch explicitly (currently falls through silently):
} else if a == .from {
    // Intentional no-op. "dari" (from) anchors the start of a range but
    // the actual start tooth is set by the following .toothIdentifier token.
    // The .until / .until2 handler then closes the range from cursor.currentTooth.
}
```

**Transcript impact:** Zero. No behavior change, purely documents existing intent.

---

### Fix 4 — `"nol"` (zero) PD clamp — PD-ONLY, precisely scoped (Issue 7)
**File:** `VoiceCommandParser+Flush.swift`, line 61

```swift
// BEFORE
if m == .probingDepth {
    valuesToEmit.append(String(abs(n)))

// AFTER
if m == .probingDepth {
    valuesToEmit.append(String(max(1, abs(n))))
```

**Why this scope is safe:** The `max(1, ...)` clamp is ONLY applied inside the `m == .probingDepth` branch. The `else` branch (lines 62–64) for all other metrics (`gingivalMargin`, `mobility`, etc.) is unchanged. Gingival margin values of 0 (CEJ-level, no recession) are completely unaffected.

**Transcript impact:** Neither `dr_lucky_ground` nor `student_ground` intentionally record PD = 0. The only risk is accidental STT `"nol"` which would previously corrupt the tooth. This is purely defensive. ✓ Safe.

> ⚠️ **Important:** Do NOT apply `max(1, ...)` outside the `m == .probingDepth` branch. Gingival margin of 0 is clinically valid.

---

### Fix 5 — `static let` canonical flat array (Issue 11 / performance)
**File:** `Models.swift` — inside `ChartAnatomyResolver`

```swift
// BEFORE: rebuilt on every sequence(from:to:) call
var flat: [(Int, ChartAspect, Int)] = []
for aspect in aspects {
    for t in allTeeth {
        for s in 0..<3 {
            flat.append((t, aspect, s))
        }
    }
}

// AFTER: add a static constant above sequence(from:to:)
private static let _fullCanonicalFlat: [(Int, ChartAspect, Int)] = {
    let allTeeth = [
        18,17,16,15,14,13,12,11, 21,22,23,24,25,26,27,28,
        48,47,46,45,44,43,42,41, 31,32,33,34,35,36,37,38
    ]
    var flat: [(Int, ChartAspect, Int)] = []
    for aspect in [ChartAspect.outer, ChartAspect.inner] {
        for t in allTeeth { for s in 0..<3 { flat.append((t, aspect, s)) } }
    }
    return flat
}()

// Inside sequence(from:to:): use _fullCanonicalFlat directly
// when aspects == [.outer, .inner] (both aspects needed).
// Keep the per-aspect filter for same-aspect ranges.
```

> ⚠️ **Note:** The `aspects` variable in the existing code is `[start.1]` for same-aspect ranges and `[.outer, .inner]` for cross-aspect ranges. The static array covers the cross-aspect case. For same-aspect ranges, filter from the static array rather than rebuilding. The existing logic produces correct results; this change only affects allocation count.

**Transcript impact:** Zero. Pure performance — no behavior change.

---

### Fix 6 — Expanded STT spell correction (Improvement C)
**File:** `VoiceTokenizer+Parsing.swift`, in the `words.map { word in switch word { ... } }` block

```swift
// Add these cases:
case "sampe": return "sampai"           // Casual Indonesian "until"
case "disco": return "disto"            // STT misread of "disto"
case "mezzo": return "mesio"            // Italian-influenced STT
case "probing depth": return "poket"   // English clinical term (handle pre-split)
```

**Transcript impact:** Neither transcript uses these words. Purely additive. ✓ Safe.

> Note: `"probing depth"` as a two-word phrase won't be catchable in the per-word `map`. It needs pre-split normalization (like `"bleeding on probing"`) in the string-level section. The single-word ones (`"sampe"`, `"disco"`, `"mezzo"`) are safe in the `map`.

---

## 🔍 ITEMS NEEDING FURTHER INVESTIGATION — Do not implement without tracing

---

### Bug 4 — `startPostTargeting` fallback walks backward through commands

The proposed fix (walk backward to find the most recent matching command) is conceptually right but needs careful implementation. The current behavior — silently no-op when the last command doesn't match — is **preferable to a wrong command** being used as a template.

**Transcript check:** Neither `dr_lucky_ground` nor `student_ground` trigger this exact failure path (`.missing` interleaved with PD, then `pada`). This is a real edge case but not a regression risk for the current transcripts.

**Recommendation:** Before implementing, add a test transcript specifically for this pattern:
```
gigi 18 gak ada  3 2 3  pada mesio bukal
```

---

### Issue 5 — Cross-jaw `expectedSlots`

The cross-jaw range issue (T28→T48) is theoretically present but both transcripts stay within jaw boundaries. The fix (validate same-sequence before computing slots) requires integrating `ChartingConfiguration` into `TeethSelection`, which is a larger architectural change.

**Recommendation:** Defer until a test case is found in clinical use.

---

### Issue 6 — `"lanjut"` filter missing `"gigi N"` form

`dr_lucky_ground` line 66: `"Lanjut 43,"` — this is `lanjut` followed directly by a tooth number (no aspect word). The filter only fires when `nextW` is in `aspectWords`. Since `43` is not an aspect word, the filter is bypassed correctly. ✓ No issue with current transcripts.

`student_ground` line 142: `"Lanjut ke rahang atas"` — `lanjut` is followed by `"ke"` (not an aspect word), so the filter doesn't fire. ✓

The `"gigi"` fix is only needed if a clinician says `"lanjut bukal gigi 16"` where `"gigi"` follows the aspect. This is an uncommon phrasing. **Low priority.**

---

## Summary — What to implement now vs. later

| Fix | Status | Implemented |
|---|---|---|
| ~~Sign change in `flushNumbers`~~ | ❌ Retracted — breaks `"resesi minus N"` | No |
| ~~`lastAutoAdvancedFromTooth` in `restoreToMainSequence`~~ | ❌ Retracted — already handled at call sites | No |
| Fix 1 — Force-unwrap guard | ✅ Completed | Yes |
| Fix 2 — `_sep_` in range lookahead | ✅ Completed | Yes |
| Fix 3 — `.from` no-op comment | ✅ Completed | Yes |
| Fix 4 — PD-only `max(1, abs(n))` clamp | ✅ Completed | Yes |
| Fix 5 — `static let` canonical flat | ✅ Completed | Yes |
| Fix 6 — STT spell corrections | ✅ Completed | Yes |
| Fix 7 — `hasUpcomingToothIdentifier` sentence boundary `_sep_` stop | ✅ Completed | Yes |
| Bug 4 — `startPostTargeting` fallback | 🔍 Needs targeted test transcript first | Not yet |
| Issue 5 — Cross-jaw `expectedSlots` | 🔍 Architectural change | Not yet |
| Issue 6 — `"lanjut"` + `"gigi N"` form | 🔍 Low priority, uncommon pattern | Not yet |
