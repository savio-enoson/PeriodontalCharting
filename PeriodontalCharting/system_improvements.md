# NLP System — Improvements Analysis

Findings are grouped by category. Each item is grounded in specific source lines.

---

## Category 1 — Definite Bugs

These are code paths where the current logic is provably wrong or will crash under a realistic input.

---

### Bug 1 — Force-unwrap crash in `resolveAnatomyWithLookahead`

**File:** `VoiceCommandParser+Lookahead.swift`, line 41

```swift
return (resolved.aspect!, resolved.site)
```

`ChartAnatomyResolver.resolve` returns `(aspect: ChartAspect?, site: Int?)?`. The outer optional is handled by `guard`, but the inner `aspect` is force-unwrapped. Looking at `ChartAnatomyResolver.resolve` in `Models.swift` lines 100–101:

```swift
default:
    return nil  // jaw anatomy tokens fall here
```

The caller (`+Parse.swift` line 485) filters jaw tokens separately, so the path is currently safe. But if a new `AnatomyType` case is added without updating the caller's filter, the force-unwrap crashes the app.

**Fix:** Replace with `guard let aspect = resolved.aspect else { return nil }`.

---

### Bug 2 — `_sep_` skipped in `.toothIdentifier` range lookahead

**File:** `VoiceCommandParser+Parse.swift`, lines 162–165

```swift
while peek < tokens.count {
    if case .word(_) = tokens[peek] { peek += 1; continue }
    break
}
```

This word-skip loop (looking for `sampai`/`hingga` after a tooth identifier) skips **all** `.word` tokens, including `_sep_`. Compare to the `.until` action handler (lines 360–363), which correctly excludes `_sep_`:

```swift
if case .word(let w) = tokens[peek], w != "_sep_" { peek += 1; continue }
```

**Impact:** A period or newline between a tooth number and `sampai` on the next dictation line could accidentally produce a cross-sentence range.

**Fix:** Apply the same `w != "_sep_"` guard to the `.toothIdentifier` lookahead.

---

### Bug 3 — `lastAutoAdvancedFromTooth` not cleared in `restoreToMainSequence`

**File:** `VoiceCommandParser+Flush.swift`, lines 4–13

`restoreToMainSequence()` never resets `lastAutoAdvancedFromTooth`. This variable is only cleared by `.action`, `.toothIdentifier`, and `.number` tokens.

**Failing case:**
```
"Resesi 2 pada 31  BOP"
```
After the post-target flush calls `restoreToMainSequence()`, `lastAutoAdvancedFromTooth` may still hold a stale value from a previous PD auto-advance. The `BOP` `.metric` handler then incorrectly snaps the cursor backward.

**Fix:** Add `lastAutoAdvancedFromTooth = nil` inside `restoreToMainSequence()`.

---

### Bug 4 — `startPostTargeting` pops the last command by operation type only

**File:** `VoiceCommandParser+Flush.swift`, lines 168–171

```swift
} else if let last = commands.last, last.operation == cursor.currentMetric {
    postTargetTemplate = commands.popLast()
    didCreateTemplate = true
}
```

When `startPostTargeting()` is called with empty `currentNumbers`, it pops the last emitted command as the template — checking only `operation == currentMetric`. If a modifier command (e.g., `.missing`) was emitted between two PD commands, the guard fails and the post-target is **silently ignored**.

**Failing case:** `"gigi 18 gak ada  3 2 3  pada mesio bukal"` — the last command is `.missing`, so the guard fails and `didCreateTemplate = false`.

**Fix:** Walk backward through `commands` to find the most recent matching operation, or explicitly emit a no-op when the post-target can't be resolved.

---

## Category 2 — Robustness / Resilience Issues

These produce wrong chart state under realistic dictation patterns.

---

### Issue 5 — `TeethSelection.expectedSlots` uses hardcoded canonical tooth order

**File:** `Models.swift`, lines 71–82

The multi-tooth `expectedSlots` fallback uses a hardcoded canonical array:

```swift
let allTeeth = [
    18,17,16,15,14,13,12,11, 21,22,23,24,25,26,27,28,
    48,47,46,45,44,43,42,41, 31,32,33,34,35,36,37,38
]
```

This is fine for intra-jaw ranges. But a range from T28 (canonical index 15) to T48 (canonical index 16) spans only 2 canonical steps, but T28 and T48 are anatomically far apart (upper-left last molar to lower-right last molar). The `min/max` slicing expands to include unintended teeth.

**Fix:** Validate that start and end teeth share the same traversal sequence before computing slot counts. Cross-jaw/cross-aspect ranges should either be rejected or decomposed into two separate commands.

---

### Issue 6 — `"lanjut"` filter hardcodes a 4-word aspect list

**File:** `VoiceTokenizer+Parsing.swift`, lines 189–206

```swift
let aspectWords = ["palatal", "lingual", "bukal", "labial"]
if aspectWords.contains(nextW) {
    let thirdW = (i + 2 < words.count) ? words[i+2] : ""
    var skipNext = true
    if let tNum = Int(thirdW), tNum > 10 && tNum < 99 {
        skipNext = false
    }
    ...
}
```

The guard `Int(thirdW) > 10 && < 99` only handles bare integer tooth numbers. It misses:
- `"gigi 16"` (two-word tooth identifier)
- Indonesian verbal tooth numbers (`"gigi enambelas"`)

So `"lanjut bukal gigi 16"` would discard `"bukal"` and leave `"gigi 16"` un-consumed, producing a spurious tooth jump.

**Fix:** Expand the tooth guard to also check `thirdW == "gigi"`.

---

### Issue 7 — `"nol"` (zero) injects an invalid probing depth

**File:** `VoiceTokenizer+Parsing.swift`, lines 150–185

`parseIntOrWord("nol")` returns `0`, producing `.number(0)`. A probing depth of 0 mm is clinically impossible on a present tooth. More importantly, STT drift could produce an unintended `"nol"` that silently injects a 0 into the next PD block via the broadcast/padding path: `"3 2 3  nol  2 2 2"` → the `0` gets broadcast to `[0, 0, 0]` for the next tooth.

**Fix:** In `flushNumbers`, clamp `.probingDepth` values to a minimum of 1: `String(max(1, abs(n)))`. Alternatively, in the `.number` handler, discard a `0` when the current metric is `.probingDepth`.

---

### Issue 8 — `"margin minus 2"` loses the minus sign

**File:** `VoiceCommandParser+Flush.swift`, lines 59–64

```swift
} else {
    valuesToEmit.append(String(abs(n) * currentMetricMultiplier))
}
```

When the metric is `"resesi"` (`multiplier = -1`) and the clinician dictates a plain positive number, `abs(n) * -1` correctly produces a negative value. But when the metric is `"margin"` / `"gingival"` (`multiplier = 1`) and the clinician says `"margin minus 2"` (a pseudopocket going below CEJ), `currentNumbers = [-2]` and `abs(-2) * 1 = 2`. The explicit minus sign is lost.

**Fix:** Remove `abs()` for non-PD metrics:

```swift
if m == .probingDepth {
    valuesToEmit.append(String(abs(n)))
} else {
    valuesToEmit.append(String(n * currentMetricMultiplier))
}
```

---

### Issue 9 — `.from` / `"dari"` falls through silently with no handler

**File:** `VoiceCommandParser+Parse.swift` — the `.action` switch has no `else if a == .from` branch

`"dari"` is silently ignored (falls through to `tokenIndex += 1`). The current behavior works by coincidence: the tooth identifier following `"dari"` sets `activeSelection`, and `sampai` then extends it. But the design intent is invisible — a reader or future contributor has no way to know this is intentional.

**Fix:** Add an explicit `else if a == .from { /* intentional no-op: start tooth set by following toothIdentifier */ }` comment case.

---

## Category 3 — Performance

---

### Issue 10 — O(n²) full re-tokenization on every word

**File:** `AIVoiceViewModel.swift`

The viewmodel calls `VoiceCommandParser.parse(text: liveTranscription, isFinal: false)` after appending each word. `liveTranscription` grows by one word per iteration, so the entire text is re-tokenized from scratch every time. For a 300-word transcript the total tokenization work is ~1+2+…+300 = ~45,000 word-processing steps.

This is fine on modern iPads today, but becomes a bottleneck on older devices or very long sessions.

**Fix (simple memoization):** Since `liveTranscription` only ever grows (never shrinks during streaming), memoize the last input/output pair:

```swift
private var lastTokenizedText = ""
private var cachedTokens: [VoiceToken] = []

// Before tokenizing, if new text starts with lastTokenizedText,
// only tokenize the suffix (minus the last ~5 words as a lookahead window)
// and prepend cachedTokens.
```

This reduces total work from O(n²) to O(n).

---

### Issue 11 — `ChartAnatomyResolver.sequence` allocates a 192-element flat array per call

**File:** `Models.swift`, lines 131–140

Every `sequence(from:to:)` call builds a full 192-tuple flat array (32 teeth × 3 sites × 2 aspects) on the heap just to find two indices and slice. This function is called on every `TeethSelection.expectedSlots` access, which happens frequently during parsing.

**Fix:** Hoist the full canonical flat array into a `static let`:

```swift
static let canonicalFlat: [(Int, ChartAspect, Int)] = {
    let allTeeth = [18,17,...,38]
    var flat: [(Int, ChartAspect, Int)] = []
    for aspect in [ChartAspect.outer, ChartAspect.inner] {
        for t in allTeeth { for s in 0..<3 { flat.append((t, aspect, s)) } }
    }
    return flat
}()
```

Computed once at first access, shared for all calls.

---

## Category 4 — New Logic / Quality-of-Life Improvements

---

### Improvement A — Mobility post-targeting

`"kegoyangan 2 pada 16"` works, but `"16 kegoyangan 2"` or `"2 kegoyangan"` (number-before-metric) does not — the pending `2` is treated as the start of a PD block when the metric token arrives.

**Fix:** In the `.metric` handler, if the incoming metric is `.mobility` and `currentNumbers.count == 1`, flush those numbers as mobility for the current tooth before switching the metric.

---

### Improvement B — Expanded STT spell correction

Common STT transcription errors not yet covered:

| Likely STT output | Correct | Notes |
|---|---|---|
| `"sampe"` | `"sampai"` | Casual Indonesian for "until" |
| `"disco"` | `"disto"` | STT misread |
| `"mezzo"` | `"mesio"` | Italian-influenced STT model |
| `"implan"` | already handled | ✓ |
| `"probing depth"` | `"poket"` | English clinical term |

**Fix:** Add these to the word-level spell correction map in `VoiceTokenizer+Parsing.swift`.

---

### Improvement C — `isFinal` force-pad UI feedback

When `isFinal: true` fires with only 1 or 2 numbers pending, `flushNumbers(force: true)` silently pads with the last value. A clinician who stopped mid-block gets `[3, 2, 2]` instead of `[3, 2, ?]` with no indication that padding occurred.

**Fix:** Add a `wasPadded: Bool` flag to `AnnotationCommand`. When `force == true` and padding is applied, set `wasPadded = true`. The `HistoryCard` in `AIListeningView` can then render a subtle warning indicator on padded commands.

---

### Improvement D — Explicit `"dari"` range start anchor

Currently `"dari bukal 17 sampai bukal 15"` works only because the cursor happens to already be at a tooth before T17. If the cursor is anywhere else (e.g., mid-palatal), the `"dari"` is ignored and `sampai` anchors from `cursor.currentTooth`, producing a wrong range.

**Fix:** In the `.from` action handler, peek ahead for an optional anatomy and tooth, and explicitly set `activeSelection.startTooth` to the identified tooth. This mirrors the `sampai` lookahead pattern and makes the range fully cursor-independent.

---

### Improvement E — `"mesio"` / `"disto"` as standalone anatomy when followed by anatomy preposition

Currently `"mesio"` alone (without `"bukal"`, `"lingual"`, or `"palatal"` following) resolves to `.anatomy(.mesial)`. This is correct, but `"disto"` resolves to `.anatomy(.distal)` only if the next word is not a valid compound. This is already handled correctly — noting this as a confirmation that the existing fallback is solid.

---

## Summary Table

| # | Category | Severity | Effort |
|---|---|---|---|
| Bug 1 | Force-unwrap crash in lookahead | 🔴 High (crash risk) | Low |
| Bug 2 | `_sep_` not excluded from toothIdentifier range lookahead | 🟠 Medium | Low |
| Bug 3 | `lastAutoAdvancedFromTooth` not cleared in `restoreToMainSequence` | 🟠 Medium | Low |
| Bug 4 | `startPostTargeting` pops command by operation only | 🟡 Low–Med | Medium |
| Issue 5 | `expectedSlots` hardcoded canonical order on cross-jaw ranges | 🟡 Low | Medium |
| Issue 6 | `"lanjut"` filter misses `"gigi N"` tooth form | 🟡 Low | Low |
| Issue 7 | `"nol"` injects invalid 0 into PD blocks | 🟠 Medium | Low |
| Issue 8 | `"margin minus 2"` loses sign | 🟠 Medium | Low |
| Issue 9 | `.from` silently falls through with no intent comment | 🟡 Low | Trivial |
| Issue 10 | O(n²) re-tokenization during streaming | 🟡 Low (perf) | Medium |
| Issue 11 | 192-tuple flat array allocated on every `sequence()` call | 🟡 Low (perf) | Low |
| Imp. A | Mobility post-targeting (`"2 kegoyangan"`) | 🟢 Enhancement | Low |
| Imp. B | Expanded STT spell correction | 🟢 Enhancement | Trivial |
| Imp. C | Force-pad warning in `AnnotationCommand` + UI | 🟢 Enhancement | Low |
| Imp. D | Explicit `"dari"` range start anchor | 🟢 Enhancement | Low |
