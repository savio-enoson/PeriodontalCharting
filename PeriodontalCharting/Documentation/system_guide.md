# Periodontal Charting — System Guide

This document is the definitive high-level reference for the Periodontal Charting voice command system. It covers the full pipeline from raw speech to chart annotation: how speech is transcribed, how text becomes tokens, how tokens drive a stateful session parser, and how that parser produces structured commands that update the clinical record.

For the project brief, getting started, and roadmap, see [project_guide.md](project_guide.md). For the file-by-file Swift reference, see [frontend_guide.md](frontend_guide.md).

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Pipeline Architecture](#2-pipeline-architecture)
3. [Phase 1 — Tokenization](#3-phase-1--tokenization)
   - [TokenizerManager — Unified Entry Point](#30-tokenizermanager--unified-entry-point)
   - [Pre-tokenization Normalization](#31-pre-tokenization-normalization)
   - [Token Types](#32-token-types)
   - [Multi-word Alias Matching](#33-multi-word-alias-matching)
   - [Number Disambiguation](#34-number-disambiguation)
   - [Anatomy Lookahead Hint (`expectedValues`)](#35-anatomy-lookahead-hint-expectedvalues)
4. [Phase 2 — StatefulParser](#4-phase-2--statefulparser)
   - [Design: Truly Incremental (Design A)](#41-design-truly-incremental-design-a)
   - [API — `consume(tokens:isFinal:)`](#42-api--consumetokensfinal)
   - [Core State Variables](#43-core-state-variables)
   - [Token Processing Rules](#44-token-processing-rules)
   - [`dari` Keyword Semantics](#45-dari-keyword-semantics)
5. [The Two Targeting Modes](#5-the-two-targeting-modes)
   - [Pre-targeting (anatomy before numbers)](#51-pre-targeting-anatomy-before-numbers)
   - [Post-targeting (numbers before anatomy)](#52-post-targeting-numbers-before-anatomy)
6. [Anatomy Resolution](#6-anatomy-resolution)
   - [ChartAnatomyResolver](#61-chartanatomyresolver)
   - [Quadrant Mirroring](#62-quadrant-mirroring)
   - [Anatomy Aggregation](#63-anatomy-aggregation)
   - [Aspect-jump Safeguard](#64-aspect-jump-safeguard)
7. [Flushing & Emitting Commands](#7-flushing--emitting-commands)
   - [flushNumbers](#71-flushnumbers)
   - [emitBoolIfPending](#72-emitboolfpending)
   - [discardOrFlush](#73-discardorflush)
   - [Flush Triggers](#74-flush-triggers)
8. [Auto-advance & Sequence Restoration](#8-auto-advance--sequence-restoration)
9. [Lookahead Utilities](#9-lookahead-utilities)
10. [ChartingCursor — Traversal State](#10-chartingcursor--traversal-state)
11. [ChartingConfiguration — User Preferences](#11-chartingconfiguration--user-preferences)
12. [ChartProcessor — Applying Commands](#12-chartprocessor--applying-commands)
13. [Data Model Snapshot](#13-data-model-snapshot)
14. [Worked Examples](#14-worked-examples)
15. [Design Invariants & Edge-case Rules](#15-design-invariants--edge-case-rules)

---

## 1. System Overview

Periodontal charting is a clinical measurement procedure where a practitioner records 3–6 numeric values per tooth surface (probing depth, gingival margin, bleeding, plaque, furcation, mobility) while probing a patient's mouth with instruments. Traditionally, an assistant types these values as the clinician dictates them.

This system replaces the assistant with a real-time voice NLP engine. The clinician speaks Indonesian clinical shorthand into an iPad microphone. The engine converts that speech into structured `AnnotationCommand` mutations that update a full 32-tooth `mouthState` data structure.

The key constraints this creates for the NLP engine:

- **Hands-free**: The clinician cannot correct errors by typing. The parser must be tolerant of dictation patterns.
- **Contextual**: Tooth numbers and surfaces should not need to be repeated on every measurement. Context carries forward.
- **Deterministic**: Re-parsing the same text must always produce the same chart state, regardless of intermediate partial transcripts during streaming.
- **Incremental session state**: The `StatefulParser` instance **persists** across VAD chunk boundaries for the duration of one dictation session. Cursor position, active selection, and pending numbers carry forward between chunks. The `isFinal` flag on `consume(tokens:isFinal:)` marks the end of the **entire session**, not the end of a single chunk.

---

## 2. Pipeline Architecture

```
Live microphone audio
        │
        ▼
┌──────────────────────────────────────────┐
│  Phase 0a: Speaker Isolation             │
│  SpeakerGateService (ECAPA-TDNN)         │  Accepts / rejects segments by speaker ID
│  TSEEngine (BSRNN)                       │  Target source enhancement pre-filter
└──────────────────────────────────────────┘
        │  Filtered audio
        ▼
┌──────────────────────────────────────────┐
│  Phase 0b: Speech-to-Text                │
│  Wav2VecAudioCapture                     │  16 kHz mic capture, resampling, signal conditioning
│  Wav2VecViewModel                        │  Energy-based VAD, chunk commit logic
│  Wav2VecEngine (Wav2Vec2 FP16)           │  CoreML acoustic model inference
│  CTCDecoder (+ PrefixTrie)              │  Constrained beam search, acoustic cost rejection
└──────────────────────────────────────────┘
        │  Indonesian text (committed Wav2Vec chunks)
        ▼
┌──────────────────────────────────────────┐
│  Phase 1: Tokenization                   │
│  TokenizerManager                        │  Normalisation, dispatch
│    └── VoiceTokenizer                    │  Rule-based alias dictionary → [VoiceToken]
└──────────────────────────────────────────┘
        │  [VoiceToken]
        ▼
┌──────────────────────┐
│    StatefulParser    │  Phase 2: tokens → session state → [AnnotationCommand]
│  (+Flush, +Lookahead)│  Persistent across VAD chunk boundaries
└──────────────────────┘
        │  [AnnotationCommand]
        ▼
┌──────────────────┐
│  ChartProcessor  │  Phase 3: commands → mouthState mutations
└──────────────────┘
        │  [Int: ToothObject]
        ▼
    ChartDashboard  (SwiftUI view re-render)
```

**Phase 0a (Speaker Isolation):** `SpeakerGateService` runs ECAPA-TDNN speaker verification on each confirmed Wav2Vec segment. `TSEEngine` applies BSRNN target source enhancement as a pre-filter to suppress non-target speech before it reaches Wav2Vec. This layer is handled by a separate peer module; the components live in `Audio/` and `Audio/TSE/`. See [frontend_guide.md §3.9](frontend_guide.md) for the file reference.

**Phase 0b (Speech-to-Text):** `Wav2VecAudioCapture` records at 16 kHz mono, applies `HighPassFilter` (80 Hz cutoff) and `AutoGain` (target RMS 0.1, ~1.5 s time constant) before chunking into 512-sample aligned buffers. `Wav2VecViewModel` implements energy-based VAD using a 4-second rolling percentile window and dynamic range contrast check. Speech is accumulated into a growing `streamingBuffer`. A commit fires when silence frames exceed a threshold that tightens as the buffer grows (0–15 s: 15 frames, 15–30 s: 10 frames, 30–45 s: 5 frames, >45 s: 3 frames, >55 s: force-commit immediately). `Wav2VecEngine.predict()` pads audio to 1-second bucket boundaries with white noise (not zeros — zeros create a Z-score flatline at boundaries that drops phonemes), runs CoreML inference (`computeUnits = .cpuAndGPU`), and returns logits shape `[1, time_steps, vocab_size]`. `CTCDecoder` performs constrained beam search (width 40) guided by a `PrefixTrie` built from `lexicon.txt`. Characters forming an invalid trie prefix are culled to -∞ probability. `CTCDecoder` applies a Shallow Fusion LM boost to steer the beam toward critical anatomy terms. After beam search, `Acoustic Cost Rejection` filters words with `costPerFrame > 2.0`. Structural modifiers (`semua`, `sampai`, `hingga`, etc.) use a stricter threshold of 0.2 to prevent catastrophic chart mutations from hallucinated structural commands. `canonical_mapping.json` is applied in a 2-pass post-processing step. The `StatefulParser` applies Contextual Phonetic Recovery as a final safety net to map misheard numeric tokens (e.g. `lima`) back to anatomies (e.g. `lingual`) when clinically demanded.

**Phase 1 (Tokenization):** `TokenizerManager.shared.tokenize(text:isFinal:)` dispatches directly to the rule-based `VoiceTokenizer` (there is no ML path).

**Phase 2 (Parsing):** `AIVoiceViewModel` holds one `StatefulParser` instance alive for the duration of a dictation session. On each confirmed VAD chunk, the chunk's text is tokenized and `sessionParser.consume(tokens:isFinal:)` is called. The parser accumulates numbers, tracks the current tooth and surface selection, and emits `AnnotationCommand` objects. At session end, `consume(tokens: [], isFinal: true)` force-flushes all buffered state.

**Phase 3 (Application):** `ChartProcessor.apply(command:to:)` is a headless, UI-independent `static func` that takes an `AnnotationCommand` and updates `mouthState`. `ChartDashboard` rebuilds `mouthState` from scratch by replaying the entire `commandHistory` on every change, guaranteeing idempotency.

---

## 3. Phase 1 — Tokenization

### 3.0 TokenizerManager — Unified Entry Point

All tokenization calls go through `TokenizerManager.shared.tokenize(text:isFinal:)`. The manager reads a `useMLTokenizer` UserDefaults key for legacy compatibility, but since `MLVoiceTokenizer` is no longer present, it always routes to `VoiceTokenizer.tokenize(text:isFinal:)` directly.

`VoiceTokenizer` (`NLP/Tokenizer/`) performs a **single left-to-right pass** over the input text. It first applies string-level normalization, then walks word by word, attempting multi-word alias matches before falling back to single-word matches.

### 3.1 Pre-tokenization Normalization

Before splitting into words, the tokenizer applies regex/string substitutions to handle common transcription artefacts and clinical shorthand:

| Input pattern | Normalized to | Reason |
|---|---|---|
| `(?<=\d)\.(?=\d)` (regex) | `" "` (space) | Decimal point between digits — `"1.5"` → `"1 5"` (two values). Applied before the sentence-period rule so `"2.3.4"` does not scatter across sentence boundaries. |
| `.` / `\n` | `" _sep_ "` | Hard sentence boundary — prevents lookahead from accidentally bridging across separate dictation sentences |
| `,` | `" "` (space) | Commas in dictation are non-breaking; they separate list items but do not end a sentence |
| `\r` | `" "` | Carriage returns stripped to a space |
| `{` / `}` / `-` | `" "` | Strips curly-brace correction markers and hyphenated tooth numbers (e.g. `Gigi 1-6` → `Gigi 16`) |
| ` -` (space+hyphen) | `" minus "` | Inline negative sign — preserves recession dictation before the bare-hyphen rule strips remaining hyphens |
| `mesiobukal` / `distobukal` | `"mesio bukal"` / `"disto bukal"` | No-space compound anatomy — normalizes before multi-word matching |
| `mesiolingual` / `distolingual` | `"mesio lingual"` / `"disto lingual"` | Same |
| `mesiopalatal` / `distopalatal` | `"mesio palatal"` / `"disto palatal"` | Same |
| `mesiolabial` / `distolabial` | `"mesio labial"` / `"disto labial"` | Same |
| `"mid-"` / `"mid "` | `"mid"` | Normalizes hyphenated/spaced mid-prefix for multi-word alias matching |
| `"bleeding or probing"` | `"bop"` | Common STT transcription error for "bleeding on probing" |
| `"b o p"` / `"b.o.p"` / `"bleeding on probing"` | `"bop"` | Standard aliases |
| `"probing depth"` | `"poket"` | English-language probing depth phrase → Indonesian metric keyword |

After normalization, the text is split on whitespace into a word array.

**Word-level spell correction** is then applied before token matching:

| Misspelling(s) | Corrected to |
|---|---|
| `misio`, `mesyio`, `mesyu`, `meso`, `mezzo` | `mesio` |
| `misial`, `mesyal` | `mesial` |
| `diso`, `distio`, `dista`, `disco` | `disto` |
| `disal` | `distal` |
| `sampe` | `sampai` |
| `bocal`, `vocal`, `buka`, `buckal`, `buk` | `bukal` |
| `palato`, `palat` | `palatal` |
| `linguo` | `lingual` |
| `plat`, `plug`, `flak`, `plek`, `flek`, `black`, `flag` | `plak` |
| `pocket`, `poke`, `poked` | `poket` |
| `beope`, `biopi`, `tiopi`, `bleeding` | `bop` |
| `enggak`, `nda`, `ndak` | `gak` |
| `mobiliti` | `mobility` |
| `purkasi`, `furkasion`, `forkasi` | `furkasi` |

### 3.2 Token Types

| Token case | Example input | Produced token |
|---|---|---|
| `.number(Int)` | `"3"` / `"tiga"` | `.number(3)` |
| `.anatomy(AnatomyType)` | `"mesio bukal"` / `"palatal"` / `"rahang bawah"` | `.anatomy(.mesioBuccal)` |
| `.metric(AnnotationOperation, multiplier: Int)` | `"resesi"` / `"BOP"` / `"plak"` | `.metric(.gingivalMargin, multiplier: -1)` |
| `.action(ActionType)` | `"lanjut"` / `"gak ada"` / `"sampai"` | `.action(.next)` |
| `.toothIdentifier(Int)` | `"gigi 16"` or bare two-digit `"16"` | `.toothIdentifier(16)` |
| `.word(String)` | Unrecognised | `.word("mili")` |

> **Note on `multiplier`:** The `.metric` case carries an associated `multiplier: Int` value. For recession metrics (`"resesi"`, `"kemunduran"`), the multiplier is **-1**, automatically negating dictated values so the gingival margin is stored as a negative number (recession). All other metrics use `multiplier: 1`.

**Full metric keyword vocabulary:**

| Metric | Keywords |
|---|---|
| `.gingivalMargin` (multiplier **-1**) | `"resesi"`, `"kemunduran"` |
| `.gingivalMargin` (multiplier 1) | `"margin"`, `"gingival"`, `"enlargement"`, `"pembengkakan"`, `"pembesaran"` |
| `.probingDepth` | `"poket"`, `"probing"`, `"kedalaman"` |
| `.bleeding` | `"bop"`, `"berdarah"` |
| `.plaque` | `"plak"`, `"plaque"` |
| `.mobility` | `"kegoyangan"`, `"mobilitas"`, `"mobility"` |
| `.furcation` | `"furkasi"`, `"furcation"` |
| `.implant` | `"implan"`, `"implant"` |

**Indonesian number words:** nol(0), satu(1), dua(2), tiga(3), empat(4), lima(5), enam(6), tujuh(7), delapan(8), sembilan(9), sepuluh(10).

**`"minus"` handling:** The `.word("minus")` token sets `isNextNumberNegative = true`. The following `.number(n)` token is then negated to `-n`. This enables dictation of recession values (negative gingival margin).

**Full `ActionType` vocabulary:**

| Case | Indonesian keyword | Meaning |
|---|---|---|
| `.next` | `"lanjut"`, `"kemudian"`, `"selanjutnya"`, `"berikutnya"` | Advance cursor / flush current selection |
| `.commit` | `"selesai"` | Advance cursor / flush current selection (synonym for `.next`) |
| `.missing` | `"gak ada"`, `"missing"` | Tooth is missing / edentulous (note: `"gak"` alone is ignored) |
| `.missing2` | `"tidak ada"` | Alternative missing form (note: `"tidak"` alone is ignored) |
| `.from` | `"dari"` | Start of a range or possessive target specifier |
| `.until` | `"sampai"` | End of a range |
| `.until2` | `"hingga"` | End of a range (synonym) |
| `.at` | `"pada"` | "at / on" — triggers post-targeting mode |
| `.at2` | `"di"` | Shorter "at / on" form |
| `.all` | `"semua"`, `"semuanya"`, `"seluruh"`, `"seluruhnya"` | "all" — instantly assigns to all 64 surfaces |

> **Note on `.next` and `.commit`:** Both cases exist as distinct enum values (`case next = "lanjut"`, `case commit = "selesai"`). They produce identical behavior in the parser — both call `discardOrFlush()` then `restoreToMainSequence()`. All other commit-style synonyms (`kemudian`, `selanjutnya`, `berikutnya`) are mapped to `.next` by the tokenizer.

### 3.3 Multi-word Alias Matching

Multi-word tokens are checked *before* single-word tokens. The tokenizer peeks at the word after the current index. If both match a multi-word alias, both words are consumed (`i += 2`) and a single token is produced. Key multi-word aliases:

- `"mesio bukal"` → `.anatomy(.mesioBuccal)`, `"disto bukal"` → `.anatomy(.distoBuccal)`
- `"mesio palatal"` → `.anatomy(.mesioPalatal)`, `"mesio lingual"` → `.anatomy(.mesioLingual)`
- `"tengah bukal"` / `"mid bukal"` → `.anatomy(.midBuccal)`, `"tengah lingual"` / `"mid lingual"` → `.anatomy(.midLingual)`
- `"tengah palatal"` / `"mid palatal"` → `.anatomy(.midPalatal)`, `"tengah labial"` / `"mid labial"` → `.anatomy(.midLabial)`
- `"rahang atas"` → `.anatomy(.upperJaw)`, `"rahang bawah"` → `.anatomy(.lowerJaw)`
- `"gigi <N>"` → `.toothIdentifier(N)` (consumes two words)
- `"gak ada"` → `.action(.missing)`, `"tidak ada"` → `.action(.missing2)`

> **Mid-anatomy note:** The `AnatomyType` raw values use the Indonesian prefix `"tengah"` (e.g. `midBuccal = "tengah bukal"`). The English `"mid"` prefix is normalised then matched as a two-word alias with the following aspect word. Both forms (`"tengah bukal"` and `"mid bukal"`) produce the same token. Single-word compact forms (`"midbukal"`, `"tengahbukal"`) are also matched directly.

### 3.4 Number Disambiguation

Two-digit integers in the range **11–98** without a preceding `"gigi"` keyword are ambiguous: they could be a tooth number (e.g., `"16"`) or a pair of probing depth values (`"1"` then `"6"`).

**Block-Start Tooth Protection:** When the parser encounters a sequence of single digits that matches a valid two-digit tooth (e.g., `1` and `7` following `Disto Bukal`), it evaluates whether the number is followed by *exactly* the expected number of values for the current block. If it is (e.g., `Disto Bukal 1 7 2`, where `2` is exactly 1 value expected by `Disto Bukal`), the token `17` is flagged with `isSequenceOfTeeth = true`. This protects it from being aggressively broken apart and coerced into values by the `probingDepth` metric check.

The tokenizer disambiguates using the **current active metric's expected block size**:
- If the active metric expects blocks of **≥ 3** values (like `.probingDepth`) or **0** values (like boolean metrics), adjacent single digits are merged into a `.toothIdentifier`.
- If the active metric expects **1 value** (like `.gingivalMargin`), sequential single digits are *not* merged, preventing `"Resesi 1"` followed by `"6"` from being collapsed into tooth `16`.

### 3.5 Anatomy Lookahead Hint (`expectedValues`)

Each anatomy context carries an `expectedValues` count that tells the tokenizer how many numbers follow before a block boundary:

| Anatomy | `expectedValues` | Meaning |
|---|---|---|
| `mesioBuccal`, `distoBuccal`, `mesioLingual`, `distoLingual`, `mesioPalatal`, `distoPalatal`, `mesial`, `distal`, `midBuccal`, `midLingual`, `midPalatal`, `midLabial` | **1** | Single-site — exactly 1 value expected |
| `buccal`, `lingual`, `palatal`, `labial`, `upperJaw`, `lowerJaw` | **3** | Full-face — 3 values (one per site) |

`isStartOfBlock` is true when `currentValues == 0` (first value of a new block) or `currentValues % expectedValues == 0 && expectedValues >= 3` (a 3-value block just completed). This prevents a mid-block single digit from being misread as a standalone tooth number.

---

## 4. Phase 2 — StatefulParser

`StatefulParser` is a Swift `struct` conforming to `Equatable` and `Sendable`. It is split across three files:

| File | Responsibility |
|---|---|
| `StatefulParser.swift` | Struct declaration, all state variables, `consume(token:)` switch, `consume(tokens:isFinal:)` |
| `StatefulParser+Flush.swift` | `flushNumbers`, `emitBoolIfPending`, `discardOrFlush`, `restoreToMainSequence` |
| `StatefulParser+Lookahead.swift` | `tryResolveRangeDigits` — fragmented Wav2Vec digit accumulator |

### 4.1 Design: Truly Incremental (Design A)

The `StatefulParser` instance **persists across VAD chunk boundaries** for the duration of one dictation session. This is a key architectural difference from earlier parser designs:

| Aspect | Old behaviour | Current behaviour |
|---|---|---|
| Parser lifecycle | Re-instantiated on every parse call | One `StatefulParser` held alive for the entire session |
| Session state | Accumulated text re-parsed from scratch | State variables (cursor, numbers, selection) carry forward between chunks |
| `isFinal` flag | Marked end of a single parse call | Marks end of the **entire dictation session** |
| Ghosting | Preview vs. committed command sets | `committedCommandCount` marks the boundary in `AIVoiceViewModel` |

**Rationale:** Since Wav2Vec's commit boundaries are silence-delimited (energy VAD), holding parser state across commit boundaries means the cursor position, `activeSelection`, `pendingNumbers`, and `missingTeeth` all carry forward naturally.

**Batch processing (regression tests):** A fresh `StatefulParser` is constructed, `consume(tokens: allTokens, isFinal: true)` is called with the complete tokenized transcript, and `parser.commands` is read. The "incremental" aspect is transparent to callers who want batch behaviour.

**Simulation & Instant Fill:** `AIVoiceViewModel.parseOffline` and `parseInstant` construct a fresh `StatefulParser`, feed all tokens, and read the result. These paths model batch processing, not a live session.

### 4.2 API — `consume(tokens:isFinal:)`

```swift
mutating func consume(tokens: [VoiceToken], isFinal: Bool = false)
```

- Iterates the token array, calling `consume(token:)` for each.
- If `isFinal == true`: force-flushes any remaining `pendingNumbers`, calls `emitBoolIfPending()`, clears `pendingRangeDigits`, and resets `isWaitingForRangeEnd`. This commits all buffered state at session end.

`AIVoiceViewModel` session lifecycle:

```
startLiveDictation()
    → sessionParser = StatefulParser(configuration: getConfiguration())
    → committedCommandCount = 0

onConfirmedTranscript(chunk: String)
    → tokens = TokenizerManager.shared.tokenize(text: chunk, isFinal: false)
    → sessionParser!.consume(tokens: tokens, isFinal: false)
    → committedCommandCount = sessionParser!.commands.count

stopLiveDictation()
    → sessionParser!.consume(tokens: [], isFinal: true)
    → committedCommandCount = sessionParser!.commands.count
    → sessionParser = nil
```

### 4.3 Core State Variables

| Variable | Type | Role |
|---|---|---|
| `cursor` | `ChartingCursor` | Tracks the sequential traversal position (current tooth, aspect, metric). The authoritative position in the configured annotation sequence. |
| `activeSelection` | `TeethSelection?` | The explicitly targeted range or site that overrides the cursor. `nil` means use the cursor's position. |
| `pendingNumbers` | `[Int]` | Integer accumulator for values spoken but not yet committed to a command. |
| `pendingValues` | `[String]` *(computed)* | Stringified view of `pendingNumbers`, published to the UI for display. |
| `missingTeeth` | `Set<Int>` | Teeth marked edentulous during this session. The cursor auto-skips these when advancing. |
| `isNextNumberNegative` | `Bool` | Set by `.word("minus")`; negates the immediately following `.number(n)`. |
| `pendingAnatomies` | `[AnatomyType]` | Anatomy tokens accumulated before their target tooth has been identified, or anatomy carried across list iterations. |
| `pendingTeeth` | `[Int]` | Tooth numbers accumulated in a list (e.g., `"gigi 18 28 38 48 gak ada"`). |
| `isWaitingForRangeEnd` | `Bool` | Set by `.action(.until/.until2)`. Tells the parser the next tooth identifier completes a range. |
| `pendingRangeDigits` | `[Int]` | Digit accumulator for fragmented Wav2Vec range-end tooth numbers (e.g., `"1"` then `"5"` → tooth 15). |
| `isRangeStartPending` | `Bool` | Set by `.action(.from)` (no pending numbers). Tells the next tooth identifier to become the range start rather than a fresh standalone selection. |
| `isPostTargeting` | `Bool` | True when numbers were spoken before the anatomy/tooth — values are held until the target arrives. |
| `postTargetTemplate` | `AnnotationCommand?` | Stores the partial command template during post-targeting. |
| `postTargetAnatomy` | `AnatomyType?` | The anatomy token captured when entering post-targeting mode. |
| `isListAggregationActive` | `Bool` | True when a conjunction (`"dan"`, `","`) or consecutive tooth identifiers are being accumulated into a list. |
| `isSelectionUsed` | `Bool` | Prevents the same boolean `activeSelection` from being emitted twice. |
| `didSpecifyExplicitFullAspect` | `Bool` | True when a full-aspect anatomy (e.g. `"bukal"`) was explicitly specified; used to prevent spurious mid-site narrowing. |
| `metricHadSpecificTargets` | `Bool` | Tracks whether the active metric received any explicit tooth/anatomy targets. |
| `isFreshMetric` | `Bool` | True immediately after a metric token is consumed; prevents premature sequence restore on the first number. |
| `lastAutoAdvancedFromTooth` | `Int?` | Guards against double-advancing the cursor when the same tooth appears again immediately after auto-advance. |
| `currentMetricMultiplier` | `Int` | Multiplier from `.metric(_, multiplier:)` — applied to values on flush (e.g. `-1` for recession). |
| `commands` | `[AnnotationCommand]` | All emitted commands accumulating across the session. |

### 4.4 Token Processing Rules

#### `.number(n)`

1. If `isNextNumberNegative`, negate `n` and clear the flag.
2. If the current metric is boolean (bleeding/plaque/implant), call `emitBoolIfPending()` then `restoreToMainSequence()` before treating `n` as a probing depth value.
3. Clear `lastAutoAdvancedFromTooth` and `isRangeStartPending`.
4. **Range digit accumulation:** If `isWaitingForRangeEnd == true`, append `n` to `pendingRangeDigits` and call `tryResolveRangeDigits()`. Return early — do not append to `pendingNumbers`.
5. **Deferred anatomy resolution:** If `activeSelection == nil` and `pendingAnatomies` is non-empty, build an `activeSelection` from the pending anatomies against `cursor.currentTooth` right now (pre-targeting: anatomy arrived before tooth was explicitly named). If prior numbers were pending before anatomy was resolved, flush them first.
6. **Non-PD metric auto-selection:** If `pendingNumbers` is empty and `activeSelection == nil` and the metric is not `.probingDepth`, build a cursor-tooth selection so the value lands on the right tooth.
7. **Sequence restore guard (`isFreshMetric`):** If `pendingNumbers` is empty and `activeSelection` already exists, clear `isFreshMetric` or (if already clear) call `restoreToMainSequence()` to reset to the default sequence.
8. Append `n` to `pendingNumbers`.
9. **Auto-override metric:** If `pendingNumbers.count >= 3` and current metric is not `.probingDepth`, override to `.probingDepth` (user dictated a 3-value block, implying probing depth).
10. Call `flushNumbers(force: false)`.

#### `.toothIdentifier(tooth)`

1. Clear `lastAutoAdvancedFromTooth` and `pendingRangeDigits`.
2. Set `metricHadSpecificTargets = true`.
3. **Range end:** If `isWaitingForRangeEnd == true`, update `activeSelection.endTooth`, resolve any `pendingAnatomies` into `endAspect`/`endSite`, clear `isWaitingForRangeEnd`, jump cursor to `tooth`.
4. **Non-range path:**
   - If `activeSelection != nil` and `pendingNumbers` is empty:
     - `isRangeStartPending == true` → update `activeSelection.endTooth` to form a range.
     - `isListAggregationActive == true` → append to `pendingTeeth`.
     - Otherwise → emit bool if pending, clear selection, create a fresh single-tooth selection for `tooth`.
   - If `pendingNumbers` is non-empty:
     - `isListAggregationActive || isPostTargeting` → add `tooth` to `pendingTeeth`.
     - `!metricHadSpecificTargets` (first explicit target after a fresh metric) → reassign `activeSelection` start/end to `tooth` without flushing.
     - `pendingAnatomies` non-empty → build a new selection from the pending anatomies for `tooth`, then call `flushNumbers(force: false)`.
     - Otherwise → force-flush pending numbers, emit bool, create fresh selection for `tooth`.
5. Emit bool if pending (unless `isRangeStartPending` or `isFreshMetric`).
6. If `activeSelection` is still nil after the above, build a fresh tooth selection incorporating any `pendingAnatomies`.
7. Jump cursor to `tooth`.

> **`_sep_` barrier:** The `_sep_` sentinel (produced by sentence boundaries in normalization) reaches the parser as `.word("_sep_")`, which triggers `discardOrFlush()`. This prevents state from bleeding across unrelated dictation sentences.

#### `.metric(m, multiplier:)`

1. **Auto-advance correction:** If `lastAutoAdvancedFromTooth` is set, snap the cursor back to that tooth before switching metrics (prevents the modifier landing on the wrong tooth after auto-advance).
2. Clear `isListAggregationActive`, `isNextNumberNegative`, `isRangeStartPending`.
3. Force-flush any `pendingNumbers`.
4. **Boolean emit:** If the *previous* metric was a boolean (bleeding/plaque/implant) and `activeSelection` is non-nil, emit and restore before switching.
5. Set `cursor.currentMetric = m`, `currentMetricMultiplier = mult`.
6. Reset `metricHadSpecificTargets = false`, `isPostTargeting = false`, `isFreshMetric = true`, clear `pendingRangeDigits`.

> **Key invariant:** `.metric` tokens do *not* clear `activeSelection`. This allows chaining like `"Mesio Bukal Poket 2"` without losing the site selection.

#### `.action`

- **`.next` / `.commit` (`"lanjut"` / `"selesai"`):** Call `discardOrFlush()` then `restoreToMainSequence()`.
- **`.missing` / `.missing2` (`"gak ada"` / `"tidak ada"`):** Check if `activeSelection` was explicitly targeted (i.e. `!isSelectionUsed` or `!pendingNumbers.isEmpty`). If so, add it to the targets. Then call `discardOrFlush()`. Emit `.missing` commands for all accumulated targets, add to `missingTeeth`, advance cursor past them, and finally call `restoreToMainSequence()`. If no targets are found (e.g., noise), safely ignore the command.
- **`.until` / `.until2` (`"sampai"` / `"hingga"`):** Set `isWaitingForRangeEnd = true`.
- **`.from` (`"dari"`):** See §4.5 for the full disambiguation logic.
- **`.at` / `.at2` (`"pada"` / `"di"`):** If `pendingNumbers` is non-empty, set `isPostTargeting = true` and clear `activeSelection` (discard any eagerly-built cursor selection — the pending numbers will be bound to the explicit tooth list that follows). If no numbers are pending, no-op.
- **`.all` (`"semua"` / `"seluruh"`):** Set `metricHadSpecificTargets = true`. Build two `TeethSelection` objects (upper 18→28, lower 48→38). For boolean metrics: emit `[True]` per slot for both jaws. For numeric metrics with pending numbers: emit the pending values broadcast across both jaws. Clear `pendingNumbers`, `activeSelection`, `isPostTargeting`.

#### `.anatomy(a)`

1. **Auto-advance correction** (same as `.metric`): if `lastAutoAdvancedFromTooth` is set, snap cursor back.
2. Clear `isListAggregationActive`, `isNextNumberNegative`, `pendingRangeDigits`.
3. **Jaw tokens** (`.upperJaw`, `.lowerJaw`): Call `discardOrFlush()`, clear `activeSelection`, jump cursor to the start of the respective jaw via `cursor.jumpTo(jaw:)`, reset metric to `.probingDepth`. Return.
4. **Waiting for range end:** Append `a` to `pendingAnatomies`. Return. (The anatomy will be resolved when the next tooth identifier arrives as `endTooth`.)
5. **No active selection:** Resolve anatomy via `ChartAnatomyResolver`. If the resolved anatomy aspect differs from the current global cursor aspect, *unconditionally* update the global aspect via `cursor.jumpTo(aspect:)` (e.g., `"Lanjut palatal"` updates the global sequence, even if the anatomy returns a specific site index). If it's a full-face anatomy (site = `nil`), append `a` to `pendingAnatomies` for later resolution.
6. **Active selection exists:** Resolve anatomy against the selection's `startTooth`. Update `startAspect`/`startSite`/`endSite` on the selection, expanding bounds if multiple anatomies aggregate on the same aspect. If the aspect changes, apply the aspect-jump safeguard (see §6.4). If numbers are already pending for a different site, call `discardOrFlush()` first.

#### `.word(w)`

| Value | Effect |
|---|---|
| `"minus"` | Set `isNextNumberNegative = true` |
| `"dan"`, `"serta"`, `","` | If `pendingTeeth` is non-empty or `activeSelection` exists with no pending numbers: set `isListAggregationActive = true`. Otherwise clear it. |
| `"_sep_"` | Call `discardOrFlush()`; clear `isListAggregationActive`. |
| All other words | Clear `isListAggregationActive`. |

### 4.5 `dari` Keyword Semantics

`"dari"` has two distinct clinical meanings:

**`dari` as Range Start** — the most common use, introducing the start of an anatomical range followed by `"sampai"` / `"hingga"`:

```
"resesi dari mesio bukal 17 sampai disto bukal 15 minus 1"
          └──── start ────┘ └─────────── end ──────────────┘
```

**`dari` as Possessive** — a standalone use introducing a specific target without a following `"sampai"`:

```
"resesi 2 dari 14 distobukal minus 1"
          └── target ──────────────┘
```

Here, `"dari"` is semantically equivalent to `"pada"` — it introduces a target tooth. The full phrase means: *recession at tooth 14 disto-buccal, value −1*.

**Disambiguation logic (`case .from`):**

```swift
case .from:
    lastAutoAdvancedFromTooth = nil
    isListAggregationActive = false

    if !pendingNumbers.isEmpty {
        // Possessive use: numbers are ready; 'dari' acts like 'pada'.
        isPostTargeting = true
    } else {
        // Range or valueless possessive:
        // flush any pending bool, clear selection, set isRangeStartPending.
        if !isFreshMetric { emitBoolIfPending() }
        activeSelection = nil
        isRangeStartPending = true
    }
```

The key insight: `dari` does **not** use a deferred `isFromPending` flag. Instead:
- If numbers are pending → enter post-targeting immediately (possessive mode).
- If no numbers → set `isRangeStartPending = true` and let the natural anatomy + tooth + `sampai` flow handle the range.

`sampai` arriving later sets `isWaitingForRangeEnd = true`, which the next tooth identifier uses to close the range.

---

## 5. The Two Targeting Modes

The most conceptually important aspect of the parser is how it decides which anatomy belongs to which set of numbers. There are two modes:

### 5.1 Pre-targeting (anatomy before numbers)

The anatomy is spoken *before* the numbers. This is the standard clinical pattern.

```
"Disto Bukal 17   2"
  └─anatomy─┘ └─┘  └─numbers─┘
```

1. `Disto Bukal` → pushed to `pendingAnatomies`.
2. `17` → `.toothIdentifier(17)`. Anatomy resolved against tooth 17 → `activeSelection` = (T17, outer, site 2).
3. `2` → appended to `pendingNumbers`. `flushNumbers(force: false)`: 1 value for 1-slot selection → flush. Emit GM `[2]` for site 2 of tooth 17.

**Anatomy aggregation** (multiple anatomies for the same tooth/aspect):

When multiple anatomy tokens are spoken sequentially for the same tooth and aspect, the parser aggregates them into a single expanded `activeSelection` by expanding `startSite` and `endSite` bounds using `min()` / `max()`.

*Example (pre-tooth aggregation):*
```
"Distopalatal   Mesiopalatal   16   2"
  └───A1───┘    └────A2────┘  └─┘  └─num─┘
```
1. `Distopalatal` → `pendingAnatomies = [.distoPalatal]`.
2. `Mesiopalatal` → `pendingAnatomies = [.distoPalatal, .mesioPalatal]`.
3. `16` → Both anatomies resolved against tooth 16. `distoPalatal` → site 0 (inner); `mesioPalatal` → site 2 (inner). `activeSelection` = (T16, inner, startSite=0, endSite=2). `expectedSlots = 3`.
4. `2` → value flushed to 3 slots (broadcast).

*Example (post-tooth aggregation):*
```
"Bukal   Mesio Bukal   16   1 1"
  └─A1─┘ └────A2────┘  └─┘  └──nums──┘
```
1. `Bukal` → `pendingAnatomies = [.buccal]`.
2. `Mesio Bukal` → `pendingAnatomies = [.buccal, .mesioBuccal]`.
3. `16` → Resolve: `.buccal` → site nil (full-face, outer); `.mesioBuccal` → site 2 (outer). Combined: `activeSelection` = (T16, outer, startSite=1, endSite=2). `expectedSlots = 2`.
4. `1 1` → two values map to the two slots.

### 5.2 Post-targeting (numbers before anatomy)

Numbers are spoken *before* the anatomy or target. The parser holds the values until the target arrives.

**Via `"pada"` / `"di"`:**

```
"Resesi 2 pada labial 31, 32, 41, 42"
```

1. `Resesi` → metric set to `.gingivalMargin`.
2. `2` → `pendingNumbers = [2]`.
3. `pada` → `.action(.at)`. `pendingNumbers` non-empty → `isPostTargeting = true`; `activeSelection = nil`.
4. `labial` → `.anatomy(.labial)`. Stored in `pendingAnatomies`.
5. `31` → `.toothIdentifier(31)`. `pendingAnatomies` non-empty, `pendingNumbers = [2]`. Build `activeSelection` for tooth 31 from `pendingAnatomies` (→ outer, site nil). `flushNumbers`: 1 value for 3-slot full-aspect → apply to mid-site (site 1) only. Emit GM `[2]` for (T31, outer, site 1).
6. `","` → `isListAggregationActive = true`. `32`, `41`, `42` → same as step 5 for each tooth.

**Via `"dari"` (possessive):**

```
"resesi 2 dari 14 distobukal minus 1"
```

1. `2` → `pendingNumbers = [2]`.
2. `dari` → `pendingNumbers` non-empty → `isPostTargeting = true`.
3. `14` → `.toothIdentifier(14)`. Build selection for tooth 14.
4. `distobukal` → anatomy resolved into selection → (T14, outer, site 0).
5. `minus 1` → `pendingNumbers = [-1]`.
6. Next separator / session end → flush GM `[-1]` (multiplied by `currentMetricMultiplier` = -1) = `[1]` → stored as 1 (recession).

---

## 6. Anatomy Resolution

### 6.1 ChartAnatomyResolver

`ChartAnatomyResolver` is a static utility that maps an `AnatomyType` token to a concrete `(ChartAspect?, siteIndex: Int?)` pair relative to a specific tooth number and the current aspect.

| Anatomy token(s) | Returned aspect | Returned site |
|---|---|---|
| `mesioBuccal`, `distoBuccal` | `.outer` | 0 or 2 (mirrored) |
| `mesioLingual`, `distoLingual`, `mesioPalatal`, `distoPalatal` | `.inner` | 0 or 2 (mirrored) |
| `mesial`, `distal` | `currentAspect` | 0 or 2 (mirrored) |
| `midBuccal`, `midLabial` | `.outer` | **1** (explicit mid-site) |
| `midLingual`, `midPalatal` | `.inner` | **1** (explicit mid-site) |
| `buccal`, `labial` | `.outer` | **nil** (full-face — all 3 sites) |
| `lingual`, `palatal` | `.inner` | **nil** (full-face — all 3 sites) |

A `nil` site means the command targets the entire aspect (all 3 sites), which `ChartProcessor` handles as a 3-slot broadcast.

**Terminology normalization:** Both `.lingual` and `.palatal` resolve to `.inner`. Both `.buccal` and `.labial` resolve to `.outer`. This lets clinicians use the anatomically correct term for any tooth type without the parser needing to know which jaw the tooth belongs to.

### 6.2 Quadrant Mirroring

Site indices vary depending on which quadrant the tooth is in. The mouth is divided into two halves by the midline:

- **Right side** (teeth 11–18 and 41–48): the *mesial* surface is oriented toward the anterior/midline, which appears on the *right* of the chart column. Mesial = site index **2** (the rightmost slot in the data grid).
- **Left side** (teeth 21–28 and 31–38): the *mesial* surface is oriented toward the midline on the *left* of the chart column. Mesial = site index **0**.

`ChartAnatomyResolver.resolve(anatomy:for:currentAspect:)` performs this quadrant check internally. Callers do not need to know which side they are on.

### 6.3 Anatomy Aggregation

When multiple anatomy tokens are spoken sequentially for the same tooth and aspect — a common dictation pattern — the parser aggregates them into a single expanded `activeSelection` rather than treating each as a separate annotation.

**Detection:** When a new anatomy arrives with an existing `activeSelection`:
- Same aspect, same tooth, `pendingNumbers` is empty → expand `startSite` and `endSite` bounds using `min()` and `max()`.
- A different aspect, or numbers already pending → call `discardOrFlush()` first, then start a new selection.

**Example:** `"Bukal dan Mesio Bukal 16 1 1"`
1. `Bukal 16` → `activeSelection` = (T16, outer, startSite=nil, endSite=nil).
2. `Mesio Bukal` → same tooth/aspect; site 2 added. `activeSelection` = (T16, outer, startSite=1, endSite=2). `expectedSlots = 2`.
3. `1 1` → two values fill the two slots.

### 6.4 Aspect-jump Safeguard

When an anatomy token forces a transition to a different aspect (e.g., switching from `.outer` to `.inner`) on a tooth that has an active selection but no specific site yet (`startSite == nil`), the parser does **not** emit a full-face command for the previous aspect.

Without this safeguard, dictating `"gigi 16 lingual"` would create an outer selection for tooth 16, then switching to `.inner` would trigger a flush emitting a spurious full-face outer command before the lingual numbers arrive.

The guard in `case .anatomy`: if the resolved aspect differs from `cursor.currentAspect` and `activeSelection.startSite != nil || activeSelection.endSite != nil`, call `emitBoolIfPending()` and `flushNumbers(force: true)` before switching. If `startSite == nil && endSite == nil`, simply update the aspect without flushing.

---

## 7. Flushing & Emitting Commands

### 7.1 `flushNumbers`

`flushNumbers(force:)` is the primary emission function for numeric metrics (PD, GM, mobility, furcation).

**Full algorithm:**

1. If `pendingNumbers` is empty, return immediately.
2. Determine `targetSlots = activeSelection?.expectedSlots ?? 3`. If no active selection, assume 3 slots (full tooth).
3. **Deferred 1-slot metrics:** For furcation and mobility, `force == false` → return early (wait for explicit commit). For PD/GM with a 1-slot selection, return early unless 3+ numbers are present (allows the user to provide either 1 or 3 values).
4. **Auto-expand to full tooth:** If `pendingNumbers.count >= 3` and the selection has a specific start site on a single tooth, expand the selection to full-tooth (3 slots).
5. If `pendingNumbers.count >= targetSlots` OR `force == true`, proceed:
   - **Broadcast:** If exactly 1 value and `targetSlots > 1`: for non-PD/GM metrics, repeat to fill all slots. For PD/GM, apply to the mid-site (site 1) only by narrowing `startSite`/`endSite` to 1 (avoids broadcasting a single reading across all 3 sites).
   - **Pattern Repetition:** If `targetSlots % pendingNumbers.count == 0` (e.g., 3 values for 9 target slots): repeat the entire array to fill all slots.
   - **Padding:** If fewer values than slots, repeat the last value.
   - **Truncation:** Take only the first `targetSlots` values.
   - **Direction reversal:** For 3-slot selections, query `cursor.configuration.direction(for:aspect:)`. If `.rightToLeft`, reverse the values array. This maps the clinician's natural left-to-right dictation to the correct anatomical slot order.
   - **PD absolute value:** For `.probingDepth`, values are stored as `max(1, abs(n))`.
   - For `.gingivalMargin` and other numeric metrics, apply `abs(n) * currentMetricMultiplier`.
   - **List emission:** If `pendingTeeth` is non-empty, emit one command per tooth in the list, resolving `pendingAnatomies` against each tooth's quadrant for correct anatomy mapping.
   - **Range emission:** If `activeSelection.startTooth != endTooth`, call `ChartAnatomyResolver.sequence(from:to:)` to get the ordered `(tooth, aspect, site)` list. If the sequence is empty, try the reversed direction. If still empty, fall through to single-tooth fallback.
   - Emit `AnnotationCommand`.
6. **Auto-advance:** If the current metric is `.probingDepth` and the selection is a "plain tooth" (no specific sub-aspect/site, single tooth), advance the cursor to the next tooth, skipping any `missingTeeth`. Record `lastAutoAdvancedFromTooth`.
7. Clear `activeSelection`, `pendingNumbers`, `pendingTeeth`, `pendingAnatomies`, `isListAggregationActive`. Set `isSelectionUsed = true`.

### 7.2 `emitBoolIfPending`

Used for boolean metrics: `.bleeding`, `.plaque`, `.implant`, `.missing`.

When triggered:
- If `activeSelection` is set and `isSelectionUsed == false`: emit `AnnotationCommand` with `values = Array(repeating: "True", count: targetSlots)`. Clear `activeSelection`. Set `isSelectionUsed = true`.
- As a secondary pass: if `activeSelection` is nil but `pendingAnatomies` or `pendingTeeth` is non-empty, emit a boolean command per tooth in `pendingTeeth` (or `cursor.currentTooth` if the list is empty), resolving `pendingAnatomies` for each.

This is called before any context switch (new tooth, new metric, new anatomy) to ensure any pending boolean annotation is committed before the context changes.

### 7.3 `discardOrFlush`

A convenience helper used before context-switching actions (`.next`, `.commit`, `_sep_`, jaw jumps):

```swift
mutating func discardOrFlush(clearSelection: Bool = true) {
    emitBoolIfPending()
    if !pendingNumbers.isEmpty {
        flushNumbers(force: true)
    }
    if clearSelection {
        activeSelection = nil
    }
    isPostTargeting = false
}
```

### 7.4 Flush Triggers

The parser never uses a timer. Commands are buffered until one of three events occurs:

| Trigger | Mechanism |
|---|---|
| **Explicit commit** | `"lanjut"` or `"selesai"` → `.action(.next/.commit)` → `discardOrFlush()` |
| **Context jump** | New tooth, new metric, jaw switch, `_sep_` → flush before updating context |
| **Session end** | `isFinal: true` passed to `consume(tokens:isFinal:)` → forced flush of all remaining state |

This deterministic buffering approach means per-chunk token streams produce clean incremental commands without any race condition risk.

---

## 8. Auto-advance & Sequence Restoration

### Auto-advance

After successfully flushing a probing depth block for a "plain tooth" (no specific sub-aspect, single tooth, full 3-slot), the cursor automatically advances to the next tooth in the configured sequence. This allows the clinician to stream probing depths continuously:

```
"3 2 3   2 2 2   3 3 2   ..."
  └─T17─┘ └─T16─┘ └─T15─┘
```

Each 3-value block is flushed and the cursor advances without requiring `"lanjut"` between each tooth.

**Missing tooth skip:** After each advance, the cursor loops forward past any teeth in `missingTeeth`.

**Guard against double-advance:** `lastAutoAdvancedFromTooth` records the tooth the cursor just left. If the next token is a metric or anatomy (not a new tooth identifier), the cursor snaps back to `lastAutoAdvancedFromTooth` before processing the modifier. This prevents the modifier from being applied to the wrong tooth when dictating something like `"3 2 3 Resesi 1"` (the recession belongs to tooth 17, not 16).

### Sequence Restoration (`restoreToMainSequence`)

`restoreToMainSequence()` is called after any out-of-band operation (explicit commit, missing tooth, jaw switch) to return to the default charting flow:

1. Sets `cursor.currentMetric = .probingDepth` (the default sequence metric).
2. Sets `currentMetricMultiplier = 1`.
3. Clears `activeSelection`, `isPostTargeting`, `isWaitingForRangeEnd`, `pendingAnatomies`, `pendingTeeth`, `isListAggregationActive`, `isRangeStartPending`.
4. Calls `cursor.resyncToothToSequence()` then `cursor.syncWithSequence()`.
5. Skips any `missingTeeth` by advancing until a non-missing tooth is found.

---

## 9. Lookahead Utilities

Lookahead functions are used to resolve ambiguity in the speech stream.

### `hasExactlyNValues()` (in `VoiceTokenizer+Helpers.swift`)

Used by the tokenizer to differentiate between two single-digit values (e.g., `3 3`) and a tooth identifier (e.g., `33`). If the tokenizer encounters a potential tooth identifier formed by adjacent digits, it checks if it is immediately followed by exactly `expectedValues` (usually 3). 
* **Crucial constraint**: This lookahead strictly breaks on structural separators (`_sep_` and `.`). This prevents it from "bleeding" into the next dictation chunk or sentence, which could lead to falsely identifying a sequence of values in the next sentence as the trailing values for a hallucinated tooth identifier in the current sentence.

### `tryResolveRangeDigits()` (in `StatefulParser+Lookahead.swift`)

Called when `isWaitingForRangeEnd == true` and a `.number(n)` token arrives. This handles the Wav2Vec-specific case where multi-digit tooth numbers are emitted as individual digit tokens (e.g., `"1"` then `"5"` for tooth 15):

```swift
mutating func tryResolveRangeDigits() {
    guard isWaitingForRangeEnd, !pendingRangeDigits.isEmpty else { return }

    let candidate: Int
    switch pendingRangeDigits.count {
    case 1:
        return  // Single digit — ambiguous, wait for more
    case 2:
        candidate = pendingRangeDigits[0] * 10 + pendingRangeDigits[1]
    default:
        // More than 2 digits — take last two
        let d = pendingRangeDigits.suffix(2)
        candidate = d[d.startIndex] * 10 + d[d.index(after: d.startIndex)]
    }

    guard (11...48).contains(candidate) else { return }  // Not a valid FDI tooth

    consume(token: .toothIdentifier(candidate))
    pendingRangeDigits = []
}
```

When `isWaitingForRangeEnd` is cleared (by a successful `.toothIdentifier` or a flush), any residual `pendingRangeDigits` are also cleared.

The tokenizer (`TokenizerManager`) also has a primary fix for this: it force-stitches digit pairs when the preceding meaningful token is `.action(.until)` or `.action(.from)`. `tryResolveRangeDigits` is the secondary, defensive fallback for edge cases the tokenizer misses.

---

## 10. ChartingCursor — Traversal State

`ChartingCursor` (in `Configuration/ChartingCursor.swift`) tracks the sequential position in the configured annotation order.

```swift
struct ChartingCursor: Equatable {
    var currentTooth: Int
    var currentAspect: ChartAspect        // .outer or .inner
    var currentMetric: AnnotationOperation // default: .probingDepth
    var configuration: ChartingConfiguration
    // private: primaryIndex, secondaryIndex, sequenceIndex, currentSequence
}
```

### Key Methods

| Method | Effect |
|---|---|
| `advanceToNextTooth() -> Bool` | Increment `sequenceIndex`; call `advanceToNextRow()` when the sequence is exhausted. Returns `false` at end-of-mouth. |
| `advanceToNextRow() -> Bool` | Increment `secondaryIndex`; wrap to next `primaryIndex` when secondary exhausted. Calls `setupSequence()` on success. |
| `setupSequence()` *(private)* | Rebuild `currentSequence` + `currentAspect` from `primaryIndex`/`secondaryIndex` + config. Reset `sequenceIndex = 0` and `currentTooth` to the first tooth. |
| `syncWithSequence()` | Re-reads `currentTooth`/`currentAspect` from the current sequence position. |
| `resyncToothToSequence()` | Snap `currentTooth = currentSequence[sequenceIndex]`. Used after `restoreToMainSequence()`. |
| `jumpTo(tooth:)` | Override `currentTooth` for immediate highlighting without touching the sequence. |
| `jumpTo(jaw:)` | In `jawFirst` mode: jump `primaryIndex` to the target jaw, reset `secondaryIndex = 0`, call `setupSequence()`. |
| `jumpTo(aspect:)` | Jump `secondaryIndex` to target aspect within the current jaw, maintaining tooth position if possible. |
| `jumpTo(tooth:aspect:updateSequenceIndex:)` | Full search across all `(primary, secondary)` row pairs. If `updateSequenceIndex = true`, permanently reposition. If `false`, update `currentTooth` in-place for highlighting without disrupting the sequence. |
| `setMetric(_:)` | Update `currentMetric`. |

---

## 11. ChartingConfiguration — User Preferences

`ChartingConfiguration` (in `Configuration/ChartingConfiguration.swift`) is a `Codable` struct serialized to `UserDefaults` under key `"ChartingConfiguration"`.

| Property | Default | Meaning |
|---|---|---|
| `primaryOrder` | `.jawFirst` | Complete one jaw at a time vs one aspect at a time |
| `jawOrder` | `[.upper, .lower]` | Which jaw is charted first |
| `upperAspectOrder` | `[.buccal, .palatal]` | Aspect order within the upper jaw |
| `lowerAspectOrder` | `[.buccal, .palatal]` | Aspect order within the lower jaw |
| `directionMapping` | Zig-zag (see below) | Per `(jaw, aspect)` direction, keyed as `"Upper-Buccal"` etc. |

**Default zig-zag direction** (matches continuous clinical charting around the arch):

| Key | Direction | Tooth sequence |
|---|---|---|
| `"Upper-Buccal"` | `.leftToRight` | 18 → 11 → 21 → 28 |
| `"Upper-Palatal"` | `.rightToLeft` | 28 → 21 → 11 → 18 |
| `"Lower-Buccal"` | `.rightToLeft` | 38 → 31 → 41 → 48 |
| `"Lower-Palatal"` | `.leftToRight` | 48 → 41 → 31 → 38 |

The direction setting has two effects:
1. **Traversal order:** `ChartingCursor.setupSequence()` uses it to build the ordered tooth list for each row.
2. **Value reversal:** `flushNumbers(force:)` reverses the `values` array for `.rightToLeft` sequences, so numbers dictated left-to-right are stored in the correct anatomical (distal–mid–mesial or mesial–mid–distal) slot order.

---

## 12. ChartProcessor — Applying Commands

`ChartProcessor.apply(command:to:)` is a **UI-independent `static func`** shared between the app (`ChartDashboard`) and the CLI test runner. It takes an `AnnotationCommand` and mutates `mouthState: inout [Int: ToothObject]`.

The function dispatches on the command's geometry:

| Shape | Condition | Behaviour |
|---|---|---|
| **Anatomy-site range** | `startAspect` and `endAspect` both non-nil | Calls `ChartAnatomyResolver.sequence(from:to:)` to get the ordered `(tooth, aspect, site)` list; applies values element-wise across the sequence. |
| **Same-tooth, site range** | Same start and end tooth, `startSite` is non-nil | `endSite` defaults to `startSite` when nil (single-site selections valid). Iterates each `(aspect, site)` pair consuming indexed values. |
| **Multiple complete teeth** | `ts.startTooth != ts.endTooth` | Identifies all teeth between start and end using the standard charting order list. Detects if values were dictated in reverse-charting order and reverses the iteration array so values map cleanly to the dictated sequence. Slices values into 3-slot (or 1-slot) chunks per tooth. |
| **Single-tooth / fallback** | Default | Directly sets the named property arrays on the tooth using `command.values`. |

`ChartDashboard` rebuilds `mouthState` from scratch by replaying the full `commandHistory` on every parser update. This guarantees the chart is always the deterministic result of the command log, regardless of partial parses during streaming.

---

## 13. Data Model Snapshot

The single source of truth is `mouth: [Int: ToothObject]` keyed by FDI tooth number.

### `ToothObject`

| Property | Type | Description |
|---|---|---|
| `toothNumber` | `Int` | FDI number (11-18, 21-28, 31-38, 41-48) |
| `probingDepth` | `AspectData<Int>` | Pocket depth in mm per site |
| `gingivalMargin` | `AspectData<Int>` | CEJ-to-gum distance. Negative = recession, positive = pseudopocket |
| `mobility` | `MobilityClass` | Grade 0–3 |
| `furcation` | `FurcationData?` | `nil` for single-rooted / anterior teeth |
| `bleeding` | `AspectData<Bool>` | Bleeding on probing per site |
| `plaque` | `AspectData<Bool>` | Plaque present per site |
| `missing` | `Bool` | Edentulous site |
| `implant` | `Bool` | Osseointegrated implant present |
| `attachmentLevel` | `AspectData<Int>` *(computed)* | CAL = PD − GM, element-wise |

### `AspectData<T>`

Generic container: `outer: [T]` (Buccal/Facial) and `inner: [T]` (Palatal/Lingual), each with 3 elements ordered `[mesial, mid, distal]`.

### `TeethSelection`

Represents a parsed target range with start and end boundaries (tooth, aspect, site). `expectedSlots` is the count of `(tooth, aspect, site)` tuples from start to end (computed by `ChartAnatomyResolver.sequence`), driving how many values the parser must collect before flushing.

### `AnnotationCommand`

```swift
struct AnnotationCommand: Equatable {
    var operation: AnnotationOperation  // probingDepth, gingivalMargin, bleeding, etc.
    var teethSelection: TeethSelection
    var aspect: ChartAspect?
    var values: [String]               // measurements as strings
}
```

---

## 14. Worked Examples

### Example A — Sequential probing depths (auto-advance)

**Transcript:** `"2 2 2  3 4 3  2 2 2"`

Configuration: Upper Buccal, left-to-right. Cursor starts at tooth 18.

| Step | Token(s) | Parser action |
|---|---|---|
| 1 | `2 2 2` | `pendingNumbers = [2,2,2]`. `targetSlots = 3`. Flush: emit PD `[2,2,2]` for tooth 18. Auto-advance cursor → tooth 17. `lastAutoAdvancedFromTooth = 18`. |
| 2 | `3 4 3` | `pendingNumbers = [3,4,3]`. Flush: emit PD `[3,4,3]` for tooth 17. Auto-advance → tooth 16. |
| 3 | `2 2 2` | `pendingNumbers = [2,2,2]`. Flush: emit PD `[2,2,2]` for tooth 16. Auto-advance → tooth 15. |

### Example B — Out-of-band recession correction

**Transcript:** `"2 2 2  Resesi mesial minus 1  2 2 2"`

Cursor is at tooth 17 (after first block for tooth 18).

| Step | Token | Parser action |
|---|---|---|
| 1 | `2 2 2` | Flush PD for tooth 18. Auto-advance → tooth 17. `lastAutoAdvancedFromTooth = 18`. |
| 2 | `Resesi` | `.metric(.gingivalMargin, -1)`. `lastAutoAdvancedFromTooth` is set → snap cursor back to tooth 18 (the correction target). Set metric to GM. `isFreshMetric = true`. |
| 3 | `mesial` | `.anatomy(.mesial)`. Resolved to (`.outer`, site 2) on tooth 18 (upper right). `pendingAnatomies = [.mesial]`. |
| 4 | `minus 1` | `.word("minus")` → `isNextNumberNegative = true`. `.number(1)` → `n = -1`. `pendingAnatomies` non-empty → build `activeSelection` = (T18, outer, site 2). Append to `pendingNumbers`. |
| 5 | `2 2 2` | New numbers arrive. `restoreToMainSequence()` → back on PD at tooth 18. `2 2 2` → flush PD for T18. Wait — PD block already emitted for T18; cursor advances to T17. |

### Example C — Range command with anatomy

**Transcript:** `"BOP dari bukal 16 hingga bukal 14"`

| Step | Token | Parser action |
|---|---|---|
| 1 | `BOP` | `.metric(.bleeding, 1)`. Metric set to `.bleeding`. `isFreshMetric = true`. |
| 2 | `dari` | `.action(.from)`. `pendingNumbers` empty → `isRangeStartPending = true`. |
| 3 | `bukal` | `.anatomy(.buccal)`. `isRangeStartPending == true` → anatomy stored in `pendingAnatomies`. |
| 4 | `16` | `.toothIdentifier(16)`. `isRangeStartPending == true` → sets `activeSelection.endTooth = 16`. Then anatomy resolved: `activeSelection` = (T16, outer, nil). Clear `isRangeStartPending`. |
| 5 | `hingga` | `.action(.until2)`. `isWaitingForRangeEnd = true`. |
| 6 | `bukal` | `.anatomy(.buccal)`. `isWaitingForRangeEnd` → append to `pendingAnatomies`. |
| 7 | `14` | `.toothIdentifier(14)`. `isWaitingForRangeEnd` → `activeSelection.endTooth = 14`, end anatomy resolved from `pendingAnatomies` → (outer, nil). `activeSelection` = (T16, outer, nil → T14, outer, nil). |
| 8 | (isFinal) | `emitBoolIfPending`: `expectedSlots` for T16-outer-nil → T14-outer-nil = 9. Emit `["True" × 9]` for the 9 buccal sites across teeth 16, 15, 14. |

### Example D — Missing tooth list

**Transcript:** `"Gigi 18 28 38 48 gak ada"`

| Step | Token(s) | Parser action |
|---|---|---|
| 1 | `.toothIdentifier(18)` | `activeSelection` = (T18). `pendingTeeth = [18]`. |
| 2 | `.toothIdentifier(28)` | `activeSelection` non-nil, `pendingNumbers` empty → auto-activate list aggregation. `pendingTeeth = [18, 28]`. |
| 3 | `.toothIdentifier(38)` | `isListAggregationActive` → `pendingTeeth = [18, 28, 38]`. |
| 4 | `.toothIdentifier(48)` | `pendingTeeth = [18, 28, 38, 48]`. |
| 5 | `.action(.missing)` | `discardOrFlush()`. Collect targets from `pendingTeeth` = [18, 28, 38, 48]. Emit `.missing` for all four. Add to `missingTeeth`. `restoreToMainSequence()`. |

### Example E — Plaque mass-assignment

**Transcript:** `"Plaque pada semua gigi"`

| Step | Token | Parser action |
|---|---|---|
| 1 | `Plaque` | Metric set to `.plaque`. |
| 2 | `pada` | `pendingNumbers` empty → no-op (`.at` only enters post-targeting when numbers are pending). |
| 3 | `semua` | `.action(.all)`. `metricHadSpecificTargets = true`. Emit `.plaque ["True"]` for upper (18→28) and lower (48→38). |

---

## 15. Design Invariants & Edge-case Rules

These are the non-obvious rules that prevent subtle bugs. They are worth knowing if maintaining or extending the parser.

| Rule | Rationale |
|---|---|
| **`_sep_` is an opaque wall.** `discardOrFlush()` is called on `_sep_`, flushing all pending state. Range lookahead does not cross it. | A `.` or `\n` in the transcript ends the current dictation sentence. Allowing context to leak across it would collapse unrelated sentences. |
| **`"dan"` and `","` are list continuators, not structural operators.** They set `isListAggregationActive` only if `pendingTeeth` is non-empty or an `activeSelection` exists with no pending numbers. | Prevents `"Bukal dan Resesi"` from being misread as a list instruction. |
| **The metric never clears `activeSelection`.** Only tooth identifiers, jaw jumps, explicit commits, and full flushes clear it. | Allows `"Mesio Bukal Resesi 1"` to work — the anatomy selects the site, the metric changes, then `1` is applied to the still-active selection. |
| **Boolean metrics bypass `flushNumbers`.** They are emitted only by `emitBoolIfPending()`. If a number arrives while a boolean metric is active, the boolean is emitted first, `restoreToMainSequence()` is called, and the number is treated as a probing depth value. | Prevents ghost number commands from being emitted under boolean metrics. |
| **Plaque is only mass-assigned via `"semua"`/`"seluruh"`.** A bare `"plak"` with no target waits for a tooth identifier; if the metric changes or the session ends without one, the plaque command is silently dropped. | `applyPlaqueFallback()` has been removed. Bare plaque dictation without a target is a data-entry error that should not pollute the chart. |
| **Auto-advance only on plain-tooth PD selections.** An `activeSelection` with a specific anatomy or site (`startSite != nil`) blocks auto-advance after flushing. | Ensures that a corrective single-site PD annotation (`"Mesio Bukal 16 2"`) does not advance the cursor to the next tooth. |
| **`lastAutoAdvancedFromTooth` is cleared on every new tooth identifier.** | Prevents the snap-back from triggering when a genuine new tooth was explicitly named. |
| **Consecutive tooth identifiers auto-activate list aggregation.** When a new `.toothIdentifier` arrives with an existing `activeSelection` and no pending numbers, the parser seeds `pendingTeeth` with the previous tooth and starts accumulating — no separator word required. | Handles `"Gigi 18 28 38 48 gak ada"` (no `"dan"` between teeth) without losing any of the intermediate teeth. |
| **`dari` does not use a deferred flag.** The form is resolved immediately: pending numbers → post-targeting; no pending numbers → `isRangeStartPending`. | The old `isFromPending` flag caused anatomy tokens that arrived between `dari` and `sampai` to be incorrectly resolved as possessive, breaking range commands. |
| **`ChartProcessor` rebuilds from full `commandHistory` on every change.** | Guarantees idempotency. Mid-stream partial parses cannot corrupt the chart state because the history is always replayed from scratch. |
| **The `StatefulParser` instance persists for the entire session.** The `isFinal` flag marks the end of the **session**, not a single chunk. | Ensures cursor position, `missingTeeth`, and pending state carry forward correctly between confirmed VAD chunks, enabling natural cross-sentence clinical patterns (e.g., jaw switch in one sentence, PD values in the next). |
| **`Lanjut` and continuation words are NOT tooth prefixes.** Words like `"lanjut"`, `"kemudian"`, `"selanjutnya"` are purely `.commit`/`.next` actions. | If treated as tooth prefixes, dictating `"Lanjut"` followed by values (e.g., `"2 2 2"`) causes the first digits to be incorrectly grabbed as a tooth identifier (e.g., tooth `22`), jumping the cursor entirely out of sequence. |
| **The `isFinal` fallback heuristic must expect probing depths.** The final fallback that converts trailing numbers into a tooth identifier (`!isDefinitelyTooth && isFinal && nextWord == "nil"`) is guarded by `expectedValues != 3`. | Prevents the last sequence of valid probing depth values in a dictation session from being mistakenly swallowed and converted into a spurious tooth jump just because the stream ended. |
