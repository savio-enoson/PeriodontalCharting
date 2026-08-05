# Periodontal Charting — System Guide

This document is the definitive high-level reference for anyone who wants to understand the inner logic of the Periodontal Charting voice command system. It covers the full pipeline from raw speech to chart annotation: how speech is transcribed, how text becomes tokens, how tokens drive a state machine, and how that state machine produces structured commands that update the clinical record.

For the project brief, getting started, and roadmap, see [project_guide.md](project_guide.md). For the file-by-file Swift reference, see [frontend_guide.md](frontend_guide.md). For the ML tokenizer internals (label schema, state conditioning, inference loop, post-processing heuristics), see [ml_tokenizer_guide.md](ml_tokenizer_guide.md).

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
4. [Phase 2 — Parsing & State Machine](#4-phase-2--parsing--state-machine)
   - [Core State Variables](#41-core-state-variables)
   - [Token Processing Rules](#42-token-processing-rules)
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
   - [Flush Triggers](#73-flush-triggers)
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
- **Stateless per call**: The parser is re-instantiated and re-run from scratch on every new word during streaming. The accumulated text, not the parser instance, is the session state.

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
│  TranscriptionEngine (WhisperKit)        │  Whisper large-v3-turbo, on-device
│  SileroVADEngine                         │  Speech segment detection (32 ms hops)
│  SequenceBiasFilter (ClinicalConfig)     │  Per-step clinical vocabulary logit biasing
└──────────────────────────────────────────┘
        │  Indonesian text
        ▼
┌──────────────────────────────────────────┐
│  Phase 1: Tokenization                   │
│  TokenizerManager                        │  Normalisation, ML/rule-based dispatch
│    ├── MLVoiceTokenizer  (default)       │  CoreML word classifier → [VoiceToken]
│    └── VoiceTokenizer    (fallback)      │  Rule-based alias dictionary → [VoiceToken]
└──────────────────────────────────────────┘
        │  [VoiceToken]
        ▼
┌──────────────────────────────┐
│      VoiceCommandParser      │  Phase 2: tokens → state changes → [AnnotationCommand]
│  (+Parse, +Flush, +Lookahead)│
└──────────────────────────────┘
        │  [AnnotationCommand]
        ▼
┌──────────────────┐
│  ChartProcessor  │  Phase 3: commands → mouthState mutations
└──────────────────┘
        │  [Int: ToothObject]
        ▼
    ChartDashboard  (SwiftUI view re-render)
```

**Phase 0a (Speaker Isolation):** `SpeakerGateService` runs ECAPA-TDNN speaker verification on each confirmed Whisper segment. `TSEEngine` applies BSRNN target source enhancement as a pre-filter to suppress non-target speech before it reaches Whisper. This layer is handled by a separate peer module; the components live in `Audio/` and `Audio/TSE/`. See [frontend_guide.md §3.9](frontend_guide.md) for the file reference.

**Phase 0b (Speech-to-Text):** `TranscriptionEngine` is an app-wide singleton that owns one `WhisperKit` instance (Whisper large-v3-turbo, ~632 MB, loaded once at launch). `SileroVADEngine` detects speech segments on 32 ms hops before Whisper transcription. `SequenceBiasFilter` (configured by `ClinicalConfig`) biases Whisper's decoder log-probabilities toward the clinical vocabulary at each decoding step. `TranscriptionViewModel` drives the live stream and fires `onLiveTranscript` / `onConfirmedTranscript` callbacks into `AIVoiceViewModel`.

**Phase 1 (Tokenization):** `TokenizerManager.shared.tokenize(text:isFinal:)` is the unified entry point. It applies string normalisation, then dispatches to either `MLVoiceTokenizer` (the CoreML word classifier, default when the model is loaded) or the rule-based `VoiceTokenizer` (fallback). The output in both cases is a flat `[VoiceToken]` array. For full ML tokenizer internals, see [ml_tokenizer_guide.md](ml_tokenizer_guide.md).

**Phase 2 (Parsing):** `VoiceCommandParser` iterates the token array with a stateful cursor. It accumulates numbers, tracks the current tooth and surface selection, and emits `AnnotationCommand` objects at the right moments. The parser is a *class* (reference semantics) but its mutable state is reset on every `parse(text:isFinal:)` call — the parser instance itself is recreated fresh for every call from `AIVoiceViewModel`.

**Phase 3 (Application):** `ChartProcessor.apply(command:to:)` is a headless, UI-independent `static func` that takes an `AnnotationCommand` and updates `mouthState`. `ChartDashboard` rebuilds `mouthState` from scratch by replaying the entire `commandHistory` on every change, guaranteeing idempotency.

---

## 3. Phase 1 — Tokenization

### 3.0 TokenizerManager — Unified Entry Point

All tokenization calls go through `TokenizerManager.shared.tokenize(text:isFinal:)`. The manager:

1. Reads the `useMLTokenizer` `UserDefaults` key (defaults to `true`).
2. If `true` and `MLVoiceTokenizer` is loaded, routes through the ML path — applying `normalize(text:)`, splitting on `_sep_` boundaries to reset ML state between sentences, running word-by-word inference, then applying a post-processing pass for tooth-ID disambiguation and multi-word token assembly.
3. If `false` or the model is unavailable (e.g. `.mlmodelc` missing from the bundle), falls back to `VoiceTokenizer.tokenize(text:isFinal:)` directly.

The ML path's full specification — label schema, state conditioning, inference loop, post-processing heuristics, and fallback behavior — is covered in [ml_tokenizer_guide.md](ml_tokenizer_guide.md). The rule-based fallback path is documented in the sections below.

`VoiceTokenizer` (`NLP/Tokenizer/`) performs a **single left-to-right pass** over the input text. It first applies string-level normalization, then walks word by word, attempting multi-word alias matches before falling back to single-word matches.

### 3.1 Pre-tokenization Normalization

Before splitting into words, the tokenizer applies regex/string substitutions to handle common transcription artefacts and clinical shorthand:

| Input pattern | Normalized to | Reason |
|---|---|---|
| `.` / `\n` | `" _sep_ "` | Hard sentence boundary — prevents lookahead from accidentally bridging across separate dictation sentences |
| `,` | `" "` (space) | Commas in dictation are non-breaking; they separate list items but do not end a sentence |
| `{` / `}` / `-` | `" "` | Strips curly-brace correction markers and hyphenated tooth numbers (e.g. `Gigi 1-6` → `Gigi 16`) |
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
| `.action(ActionType)` | `"lanjut"` / `"gak ada"` / `"sampai"` | `.action(.commit)` |
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

**`"minus"` handling:** `"minus"` followed by `.number(n)` appends `-n` to the number buffer. This enables dictation of recession values (negative gingival margin).

**Full `ActionType` vocabulary:**

| Case | Indonesian keyword | Meaning |
|---|---|---|
| `.commit` | `"lanjut"`, `"selesai"`, `"kemudian"`, `"selanjutnya"`, `"berikutnya"` | Advance cursor / flush current selection |
| `.missing` | `"gak"` (+ `"ada"`), `"missing"` | Tooth is missing / edentulous |
| `.missing2` | `"tidak"` (+ `"ada"`) | Alternative missing form |
| `.from` | `"dari"` | Start of a range |
| `.until` | `"sampai"` | End of a range |
| `.until2` | `"hingga"` | End of a range (synonym) |
| `.at` | `"pada"` | "at / on" — triggers post-targeting mode |
| `.at2` | `"di"` | Shorter "at / on" form |
| `.all` | `"semua"`, `"semuanya"`, `"seluruh"`, `"seluruhnya"` | "all" — instantly assigns to all 64 surfaces |

> **Note:** The `.next` enum case has been removed. All advance/flush actions now use the unified `.commit` case. The tokenizer maps `lanjut` and four synonyms to `.commit`.

### 3.3 Multi-word Alias Matching

Multi-word tokens are checked *before* single-word tokens. The tokenizer peeks at the word after the current index. If both match a multi-word alias, both words are consumed (`i += 2`) and a single token is produced. Key multi-word aliases:

- `"mesio bukal"` → `.anatomy(.mesioBuccal)`, `"disto bukal"` → `.anatomy(.distoBuccal)`
- `"mesio palatal"` → `.anatomy(.mesioPalatal)`, `"mesio lingual"` → `.anatomy(.mesioLingual)`
- `"tengah bukal"` / `"mid bukal"` → `.anatomy(.midBuccal)`, `"tengah lingual"` / `"mid lingual"` → `.anatomy(.midLingual)`
- `"tengah palatal"` / `"mid palatal"` → `.anatomy(.midPalatal)`, `"tengah labial"` / `"mid labial"` → `.anatomy(.midLabial)`
- `"rahang atas"` → `.anatomy(.upperJaw)`, `"rahang bawah"` → `.anatomy(.lowerJaw)`
- `"gigi <N>"` → `.toothIdentifier(N)` (consumes two words)
- `"gak ada"` → `.action(.missing)`, `"tidak ada"` → `.action(.missing2)`

> **Mid-anatomy note:** The `AnatomyType` raw values use the Indonesian prefix `"tengah"` (e.g. `midBuccal = "tengah bukal"`). The English `"mid"` prefix is normalised to `"mid"` then matched as a two-word alias with the following aspect word. Both forms (`"tengah bukal"` and `"mid bukal"`) produce the same token. Single-word compact forms (`"midbukal"`, `"tengahbukal"`) are also matched directly.

### 3.4 Number Disambiguation

Two-digit integers in the range **11–98** without a preceding `"gigi"` keyword are ambiguous: they could be a tooth number (e.g., `"16"`) or a pair of probing depth values (`"1"` then `"6"`).

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

## 4. Phase 2 — Parsing & State Machine

`VoiceCommandParser` iterates the token array produced by `VoiceTokenizer` with a stateful cursor. The parser is split across four Swift files for clarity:

| File | Responsibility |
|---|---|
| `VoiceCommandParser.swift` | Property declarations and init |
| `VoiceCommandParser+Parse.swift` | Main `parse(text:isFinal:)` loop |
| `VoiceCommandParser+Flush.swift` | `flushNumbers`, `emitBoolIfPending`, `startPostTargeting`, `flushPostTargetIfPending`, `restoreToMainSequence` |
| `VoiceCommandParser+Lookahead.swift` | `resolveAnatomyWithLookahead`, `isContinuingList`, `hasUpcomingToothIdentifier` |

### 4.1 Core State Variables

| Variable | Type | Role |
|---|---|---|
| `cursor` | `ChartingCursor` | Tracks the sequential traversal position (current tooth, aspect, metric). The authoritative position in the configured annotation sequence. |
| `activeSelection` | `TeethSelection?` | The explicitly targeted range or site that overrides the cursor. `nil` means the cursor's position is used. |
| `currentNumbers` | `[Int]` | Integer accumulator for values spoken but not yet committed to a command. |
| `pendingValues` | `[String]` | Stringified view of `currentNumbers`, published to the UI for display. |
| `missingTeeth` | `Set<Int>` | Teeth marked edentulous during this session. The cursor auto-skips these when advancing. |
| `isPostTargeting` | `Bool` | True when the parser is in post-targeting mode (numbers were spoken before the anatomy). |
| `postTargetTemplate` | `AnnotationCommand?` | Stores the partial command template (operation + collected values) during post-targeting. |
| `postTargetAnatomy` | `AnatomyType?` | The anatomy token captured when entering post-targeting mode. |
| `metricHadSpecificTargets` | `Bool` | Tracks whether the active metric received any explicit tooth/anatomy targets. Used for plaque mass-assignment fallback. |
| `lastAutoAdvancedFromTooth` | `Int?` | Guards against double-advancing the cursor when the same tooth appears again immediately after auto-advance. |
| `currentMetricMultiplier` | `Int` | Multiplier from `.metric(_, multiplier:)` — reserved for future unit scaling. |
| `commands` | `[AnnotationCommand]` | All emitted commands accumulating during this parse call. |
| `tokens` | `[VoiceToken]` | The full tokenized array for the current parse call. |
| `tokenIndex` | `Int` | Current position in the `tokens` array. |

### 4.2 Token Processing Rules

#### `.number(n)`

1. If a pending post-target template exists, flush it first (`flushPostTargetIfPending`) and exit post-targeting mode.
2. **Array-Lookahead Fallback:** If `currentNumbers` is empty, look ahead in the token stream. If 3 or more contiguous numbers (ignoring `_sep_`) follow, and the current metric expects fewer than 3 values (e.g. `furcation` or `mobility`), the metric is automatically overridden to `.probingDepth`. This self-corrects cases where a user dictates 3 numbers sequentially for a 1-value metric without explicitly declaring the switch back to Probing Depth.
3. **Single-site escape hatch:** If `activeSelection.expectedSlots == 1` and the current metric is `.probingDepth`, peek ahead — if 3 or more numbers are coming, clear `activeSelection` (the clinician is dictating a full-tooth sequence, not a single-site correction).
4. If the current metric is boolean (bleeding/plaque/implant), emit any pending bool command and restore to main sequence before treating the number as a probing depth value.
5. Append `n` to `currentNumbers`, then attempt `flushNumbers(force: false)`.

#### `.toothIdentifier(tooth)`

1. Flush any pending bool commands and force-flush any pending numbers.
2. Jump the cursor to the specified tooth.
3. **Range lookahead:** Skip whitespace words and check whether the next meaningful token is `.action(.until)` or `.action(.until2)`. If so, look further for an optional end anatomy and end tooth.
4. **Start anatomy lookback:** If `tokens[tokenIndex-1]` is an anatomy token, treat it as the start-anatomy of the range.
5. Set `activeSelection` based on whether a full range, a partial range (no end tooth yet), or a single point was detected.
6. **List aggregation:** If the previous token was also a `.toothIdentifier` and `currentNumbers` is empty, expand the `activeSelection.endTooth` to aggregate sequential teeth into a contiguous range (e.g. `"18 17 16"`).
7. **List continuation:** After a post-target tooth is applied, `isContinuingList` peeks ahead for conjunctions or additional tooth identifiers. If a list continues, `isPostTargeting` is maintained so subsequent teeth in the list receive the same template values.

> **`_sep_` barrier:** The range lookahead skips `.word` filler tokens but stops at `_sep_` boundaries. This prevents a sentence-ending `.` or `\n` from accidentally forming a range bridge between two unrelated dictation sentences.

#### `.metric(m, multiplier:)`

1. **Auto-advance correction:** If `lastAutoAdvancedFromTooth` is set and no upcoming tooth identifier is in the stream, snap the cursor back to that tooth before switching metrics (prevents the cursor jumping past the tooth the clinician is currently annotating with a modifier metric).
2. Clear post-targeting state.
3. Emit any pending bool and force-flush any pending numbers.
4. **Plaque fallback:** If the *previous* metric was `.plaque` and no specific targets were set (`!metricHadSpecificTargets`), emit a whole-sequence plaque command before switching.
5. If `currentNumbers` is empty and `activeSelection` is set, snap the cursor highlight to that tooth without disrupting the sequence index.
6. Set `cursor.currentMetric = m` and reset `metricHadSpecificTargets = false`.
7. **Boolean Auto-Flushing:** If the new metric is boolean (`.bleeding`, `.plaque`, `.implant`) and `activeSelection` is non-nil (meaning targets were set before the metric), instantly emit the boolean command and restore the parser back to `.probingDepth`. This prevents boolean metrics from sticking to subsequent commands (e.g. isolating `"21 22 23 BOP"` from an incoming `"24 25 26 plak"`).

> **Key invariant:** `.metric` tokens do *not* clear `activeSelection`. This allows chaining like `"Mesio Bukal Poket 2"` without losing the site selection.

#### `.action`

- **`.next` / `.commit` (`"lanjut"` / `"selesai"`):** Flush all pending state (post-target, bool, numbers), apply plaque fallback if needed, then call `restoreToMainSequence()`.
- **`.missing` / `.missing2` (`"gak ada"` / `"tidak ada"`):** Walk backwards from the current token index collecting any adjacent `.toothIdentifier` tokens (the teeth the clinician just named). Emit `.missing` commands for all of them, add them to `missingTeeth`, and advance the cursor past them.
- **`.until` / `.until2` (`"sampai"` / `"hingga"`):** Flush pending state. Look ahead for an optional end anatomy and end tooth. If found, set `activeSelection` from the cursor's current position to the end. If not yet in the stream, set `activeSelection = nil` (safe suspension) to prevent stale highlights.
- **`.at` / `.at2` (`"pada"` / `"di"`):** For non-boolean metrics, enter post-targeting mode via `startPostTargeting()`. Has no effect for boolean metrics (they don't need post-targeting; their targets are set by direct anatomy/tooth selection).
- **`.all` (`"semua"` / `"seluruh"`):** Immediately emit two whole-jaw commands (upper 18→28, lower 48→38) with `aspect = nil` for the current metric. Sets `metricHadSpecificTargets = true` to suppress the plaque fallback.

#### `.anatomy(a)`

1. **Auto-advance correction** (same as `.metric`): if `lastAutoAdvancedFromTooth` is set and no upcoming tooth identifier follows, snap cursor back.
2. **Post-targeting shortcut:** If `isPostTargeting` is true, store `a` as `postTargetAnatomy` and continue — the anatomy will be resolved when the next tooth identifier or flush is encountered.
3. **Jaw tokens** (`.upperJaw`, `.lowerJaw`): Flush all pending state, clear `activeSelection`, and jump the cursor to the start of the respective jaw via `cursor.jumpTo(jaw:)`.
4. **Deferred anatomy** (next token is `.toothIdentifier`): Do nothing — the tooth identifier handler will look back and pick up this anatomy as `startAnatomy`.
5. **Immediate anatomy resolution**: Call `resolveAnatomyWithLookahead` to determine aspect and site. Then:
   - If the aspect changes, apply the aspect-jump safeguard (see §6.4).
   - If the resolved site is `nil` (full-face), clear `activeSelection` so the default 3-slot full-face behaviour applies.
   - If the resolved site is non-nil, either create a new `activeSelection` or expand the bounds of the existing one via anatomy aggregation (see §6.3).

#### `.word(w)`

The only meaningful case is `w == "minus"` immediately followed by `.number(n)` — appends `-n` to `currentNumbers`. All other `.word` tokens are silently skipped.

---

## 5. The Two Targeting Modes

The most conceptually important aspect of the parser is how it decides which anatomy belongs to which set of numbers. There are two modes:

### 5.1 Pre-targeting (anatomy before numbers)

The anatomy is spoken *before* the numbers. This is the standard clinical pattern.

```
"Disto Bukal 17   2"
  └─anatomy─┘ └─┘  └─numbers─┘
```

1. `Disto Bukal 17` → sets `activeSelection` = (Tooth 17, outer, site 2).
2. `2` → appended to `currentNumbers`.
3. Next token triggers `flushNumbers`, which applies `2` to site 2 of tooth 17 outer.

**Anatomy aggregation** (multiple anatomies for the same tooth/aspect):

When multiple anatomies are spoken sequentially, the parser aggregates them into a single selection, either by expanding bounds immediately or by deferring them until the target tooth is identified.

*Example A (Post-tooth aggregation):*
```
"Bukal   dan   Mesio Bukal   16   1 1"
  └─A1─┘       └────A2────┘  └─┘  └──nums──┘
```
1. `Bukal 16` → `activeSelection` = (Tooth 16, outer, site 1).
2. `Mesio Bukal` → same tooth/aspect detected; site bounds expand: `activeSelection` = (Tooth 16, outer, site 1 to 2).
3. `1 1` → two values mapped to the two slots.

*Example B (Pre-tooth aggregation / Lookahead deferral):*
```
"Distopalatal   Mesiopalatal   16   2"
  └───A1───┘    └────A2────┘  └─┘  └─num─┘
```
1. `Distopalatal` → parser uses lookahead and detects an upcoming tooth identifier (`16`), so it defers processing.
2. `Mesiopalatal` → parser detects an upcoming tooth identifier, so it defers.
3. `16` → parser walks backward, collects all contiguous deferred anatomies (`Distopalatal`, `Mesiopalatal`), sets the baseline to the first anatomy, and aggregates the rest (expanding bounds from site 0 to 2).
4. `2` → value is flushed to the aggregated sites.

*Example C (Tooth Sequence Aggregation):*
```
"18   17   16   resesi   -2"
└────A1─────┘   └──M──┘  └N┘
```
1. `18` → sets `activeSelection` = 18.
2. `17` → list aggregation detects a sequential tooth; expands `activeSelection` to `18...17`.
3. `16` → expands `activeSelection` to `18...16`.
4. `resesi -2` → broadcasts the metric/number across the entire 3-tooth block.

### 5.2 Post-targeting (numbers before anatomy)

Numbers are spoken *before* the anatomy or target. The parser must hold the values until the anatomy/tooth arrives.

```
"2 2 2   Bukal"
 └─nums─┘ └──anatomy──┘
```

1. `2 2 2` → appended to `currentNumbers`.
2. `Bukal` → parser detects `currentNumbers` is non-empty AND `activeSelection` has no anatomy yet.
3. Calls `startPostTargeting()`: packages `[2,2,2]` into `postTargetTemplate`, sets `postTargetAnatomy = .buccal`.
4. On the next tooth identifier (or `isFinal`), `flushPostTargetIfPending` resolves the anatomy against the tooth and emits the command.

Post-targeting is also used for the `"pada"` / `"di"` pattern:

```
"Resesi 2 pada 31, 32, 41, 42"
```

1. `Resesi` → sets metric to `.gingivalMargin`.
2. `2` → pushed to `currentNumbers`.
3. `pada` → calls `startPostTargeting()`, packaging `2` into the template.
4. `31`, `32`, `41`, `42` → each tooth identifier receives the template, emitting a `.gingivalMargin` command with value `2` for the mid-site of each tooth. `isContinuingList` keeps `isPostTargeting` alive across the comma-separated list.

**Metric switching during post-targeting:**

```
"Mesio Bukal Poket 2"
```

1. `Mesio Bukal` → `activeSelection` = (current tooth, outer, site 2).
2. `Poket` → metric changes to `.probingDepth` but `activeSelection` is **not cleared**.
3. `2` → flushed to the still-active mesio-buccal selection.

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

**Detection:** Before creating a new `activeSelection`, the parser checks whether:
- The existing `activeSelection` has the **same tooth** and **same aspect** as the incoming anatomy.
- `currentNumbers` is **empty** (no numbers have started for the first anatomy yet).

If both conditions hold, the `startSite` and `endSite` bounds are expanded using `min()` and `max()` to produce a contiguous sub-range.

**Example:** `"Bukal dan Mesio Bukal 16 1 1"`
1. `Bukal 16` → `activeSelection` = (Tooth 16, outer, startSite=1, endSite=1). `expectedSlots = 1`.
2. `Mesio Bukal` → same tooth/aspect; site 2 added. `activeSelection` = (Tooth 16, outer, startSite=1, endSite=2). `expectedSlots = 2`.
3. `1 1` → two values fill the two slots.

### 6.4 Aspect-jump Safeguard

When an anatomy token forces a transition to a different aspect (e.g., switching from `.outer` to `.inner`) on a tooth that was just targeted but has no specific site yet (`startSite == nil`), the parser does **not** immediately emit a full-face command for the previous aspect.

Without this safeguard, dictating `"gigi 16 lingual"` would first create an outer selection for tooth 16 (since tooth 16 was just targeted), then switching to `.inner` would trigger a flush that emits a spurious full-face outer command before the lingual numbers arrive.

The safeguard checks: if `activeSelection.startSite == nil && activeSelection.endSite == nil`, skip the flush and simply update the aspect.

---

## 7. Flushing & Emitting Commands

### 7.1 `flushNumbers`

`flushNumbers(force:)` is the primary emission function for numeric metrics (PD, GM, mobility, furcation).

**Full algorithm:**

1. If `currentNumbers` is empty, return immediately.
2. Determine `targetSlots = activeSelection?.expectedSlots ?? 3`. If no active selection, assume 3 slots (full tooth).
3. If `currentNumbers.count >= targetSlots` OR `force == true`, proceed:
   - **Broadcast:** If exactly 1 value and `targetSlots > 1`, repeat it to fill all slots (e.g., `"Bukal 2"` → `[2, 2, 2]`).
   - **Pattern Repetition:** If `targetSlots % currentNumbers.count == 0` (e.g., 3 values given for 9 target slots), seamlessly repeat the entire array to fill the slots (e.g., `"18 17 16 3 2 3"` expands to `[3, 2, 3, 3, 2, 3, 3, 2, 3]`).
   - **Padding:** If fewer values than slots (and it's not a clean multiple), repeat the last value to fill the remainder.
   - **Truncation:** Take only the first `targetSlots` values.
   - **Direction reversal:** Query `cursor.configuration.direction(for:aspect:)`. If `.rightToLeft`, reverse the values array. This maps the clinician's natural left-to-right dictation order to the correct anatomical site indices without requiring them to reverse.
   - **PD absolute value:** For `.probingDepth`, values are stored as `abs(n)` to prevent negative probing depths.
   - Emit `AnnotationCommand`.
4. **Auto-advance:** If the current metric is `.probingDepth` and the selection is a "plain tooth" (no specific sub-aspect or site), advance the cursor to the next tooth, skipping any `missingTeeth`.
5. Clear `activeSelection` and `currentNumbers`.

### 7.2 `emitBoolIfPending`

Used for boolean metrics: `.bleeding`, `.plaque`, `.implant`.

When triggered, if there is an `activeSelection`:
- Compute `targetSlots = sel.expectedSlots`.
- Emit `AnnotationCommand` with `values = Array(repeating: "True", count: targetSlots)`.
- Clear `activeSelection`.

This is called before any context switch (new tooth, new metric, new anatomy) to ensure any pending boolean annotation is committed before the context changes.

### 7.3 Flush Triggers

The parser never uses a timer. Commands are buffered until one of three events occurs:

| Trigger | Mechanism |
|---|---|
| **Explicit commit** | `"lanjut"` or `"selesai"` → `.action(.next/.commit)` → `flushNumbers(force: true)` |
| **Context jump** | New tooth, new metric, or jaw switch → flush before updating context |
| **Final transcript** | `isFinal: true` passed to `parse(text:isFinal:)` → forced flush of all remaining state |

This deterministic buffering approach means mid-stream partial transcripts produce clean incremental commands without any race condition risk.

---

## 8. Auto-advance & Sequence Restoration

### Auto-advance

After successfully flushing a probing depth block for a "plain tooth" (no specific sub-aspect), the cursor automatically advances to the next tooth in the configured sequence. This allows the clinician to stream probing depths continuously:

```
"3 2 3   2 2 2   3 3 2   ..."
  └─T17─┘ └─T16─┘ └─T15─┘
```

Each 3-value block is flushed and the cursor advances without requiring `"lanjut"` between each tooth.

**Missing tooth skip:** After each advance, the cursor loops forward past any teeth in `missingTeeth`.

**Guard against double-advance:** `lastAutoAdvancedFromTooth` records the tooth the cursor just left. If the next token is a metric or anatomy (not a new tooth identifier), the cursor snaps back to `lastAutoAdvancedFromTooth` before processing the modifier. This prevents the modifier from being applied to the wrong tooth when dictating something like `"3 2 3 Resesi 1"` (the recession belongs to tooth 17, not 16).

### Sequence Restoration (`restoreToMainSequence`)

`restoreToMainSequence()` is called after any out-of-band operation (explicit commit, missing tooth, post-target flush, jaw switch) to return to the default charting flow:

1. Sets `cursor.currentMetric = .probingDepth` (the default sequence metric).
2. Clears `activeSelection`.
3. Calls `cursor.resyncToothToSequence()` then `cursor.syncWithSequence()` to ensure the cursor tooth matches its sequence position.
4. Skips any `missingTeeth` by advancing until a non-missing tooth is found.

---

## 9. Lookahead Utilities

Three lookahead functions live in `VoiceCommandParser+Lookahead.swift`:

### `resolveAnatomyWithLookahead(anatomy:for:toothIndex:tokens:)`

Wraps `ChartAnatomyResolver.resolve` with a peek-ahead that decides whether a full-face anatomy (`.buccal`, `.lingual`, etc.) should be treated as full-face (site = `nil`, 3 slots) or mid-site (site = 1, 1 slot):

- Counts the number of `.number` tokens that follow the anatomy token before hitting any other meaningful token (anatomy, metric, tooth identifier, action).
- If **≥ 3 numbers** follow → full-face (`site = nil`).
- If **< 3 numbers** follow → mid-site (`resolved.site = 1`).

This means `"Bukal 2 2 2"` targets all 3 buccal sites, while `"Bukal 2"` targets only the mid-buccal site (index 1) by default, preventing the accidental broadcasting of a single value across all 3 sites.

### `isContinuingList(after:in:)`

Peeks ahead from the given index. Returns `true` if a `.toothIdentifier` is found before hitting a non-list token. Conjunctions (`"dan"`, `"serta"`, `"juga"`), anatomy tokens, `_sep_`, and unknown words are skipped during the peek. Used to keep post-targeting mode alive across comma/`"dan"`-separated tooth lists.

### `hasUpcomingToothIdentifier(from:in:)`

Peeks ahead for any upcoming `.toothIdentifier`. Returns `false` immediately on encountering a `.metric`, `.action`, or `.number`. Used to decide whether a pending `lastAutoAdvancedFromTooth` snap-back is appropriate before processing a metric or anatomy token.

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
| **Same-tooth, site range** | Same start and end tooth, `startSite` is non-nil | `endSite` defaults to `startSite` when nil (making single-site selections valid). Iterates each `(aspect, site)` pair consuming indexed values. |
| **Multiple complete teeth** | `ts.startTooth != ts.endTooth` | Identifies all teeth between start and end using the standard charting order list. **Crucially**, it detects if the user dictated them in reverse-charting order (e.g. `startTooth: 41`, `endTooth: 43`). If so, it reverses the iteration array so that values map cleanly left-to-right to the dictated sequence order. Slices the values array into 3-slot (or 1-slot) chunks and applies them to each tooth sequentially. |
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
| 1 | `2 2 2` | `currentNumbers = [2,2,2]`. `targetSlots = 3`. Flush: emit PD `[2,2,2]` for tooth 18. Advance cursor → tooth 17. |
| 2 | `3 4 3` | `currentNumbers = [3,4,3]`. Flush: emit PD `[3,4,3]` for tooth 17. Advance → tooth 16. |
| 3 | `2 2 2` | `currentNumbers = [2,2,2]`. Flush: emit PD `[2,2,2]` for tooth 16. Advance → tooth 15. |

### Example B — Out-of-band recession correction

**Transcript:** `"2 2 2  Resesi mesial minus 1  2 2 2"`

Cursor is at tooth 17 (after first block for tooth 18).

| Step | Token | Parser action |
|---|---|---|
| 1 | `2 2 2` | Flush PD for tooth 18. Auto-advance → tooth 17. |
| 2 | `Resesi` | `.metric(.gingivalMargin)`. `lastAutoAdvancedFromTooth = 17` — snap back → cursor still at 17. Set metric. |
| 3 | `mesial` | `.anatomy(.mesial)`. Resolved to (`.outer`, site 2) on tooth 17 (upper right). `activeSelection` = (T17, outer, site 2). |
| 4 | `minus 1` | `.word("minus")` + `.number(1)` → append `-1`. `currentNumbers = [-1]`. |
| 5 | `2 2 2` | Parser detects boolean? No. Current metric is `.gingivalMargin`. Flush numbers (force=false, 1 value vs targetSlots=1 → flush): emit GM `[1]` for (T17, outer, site 2). Then: new numbers are incoming, `restoreToMainSequence()` is called. Back on PD at tooth 17. `2 2 2` → flush PD for T17. Advance → tooth 16. |

### Example C — Range with anatomy

**Transcript:** `"BOP dari bukal 16 hingga bukal 15"`

| Step | Token | Parser action |
|---|---|---|
| 1 | `BOP` | `.metric(.bleeding)`. Metric set to bleeding. |
| 2 | `dari` | `.action(.from)` — (silently skipped; range is initiated by the tooth identifier) |
| 3 | `bukal` | `.anatomy(.buccal)` — next token is `.toothIdentifier(16)`, so defer. |
| 4 | `16` | `.toothIdentifier(16)`. Look back: `tokens[i-1]` = `.anatomy(.buccal)` → `startAnatomy = .buccal`. Look ahead: `.action(.until2)` + `.anatomy(.buccal)` + `.toothIdentifier(15)` found. Build `activeSelection` = (T16, outer, site nil → T15, outer, site nil). |
| 5 | `hingga bukal 15` | (consumed during step 4 lookahead) |
| 6 | (isFinal) | `emitBoolIfPending`: `expectedSlots` for T16-outer-nil → T15-outer-nil = 6. Emit `["True", "True", "True", "True", "True", "True"]` for the 6 buccal sites across teeth 16 and 15. |

### Example D — Post-targeting list

**Transcript:** `"Resesi 2 pada labial 31, 32, 41, 42"`

| Step | Token | Parser action |
|---|---|---|
| 1 | `Resesi` | Metric → `.gingivalMargin`. |
| 2 | `2` | `currentNumbers = [2]`. |
| 3 | `pada` | `.action(.at)`. Calls `startPostTargeting()`. Packages `[2]` into `postTargetTemplate`. `isPostTargeting = true`. |
| 4 | `labial` | `.anatomy(.labial)`. `isPostTargeting` is true → `postTargetAnatomy = .labial`. |
| 5 | `31` | `.toothIdentifier(31)`. Resolve `postTargetAnatomy (.labial)` for tooth 31 → (`.outer`, site 1). Emit GM `[2]` for (T31, outer, site 1). `isContinuingList` = true → keep `isPostTargeting`. |
| 6 | `32`, `41`, `42` | Same as step 5 for each tooth. |
| 7 | (isFinal) | `flushPostTargetIfPending` finds no pending template (all flushed). Done. |

---

## 15. Design Invariants & Edge-case Rules

These are the non-obvious rules that prevent subtle bugs. They are worth knowing if maintaining or extending the parser.

| Rule | Rationale |
|---|---|
| **`_sep_` is an opaque wall.** Range lookahead stops at `_sep_`. List continuation stops at `_sep_`. | A `.` or `\n` in the transcript ends the current dictation sentence. Allowing lookahead to cross it would collapse unrelated sentences into false ranges. |
| **`"dan"` is not a structural operator.** The conjunction is simply a `.word` token that is skipped, not an action that triggers aggregation. Aggregation happens implicitly when consecutive anatomy tokens share the same tooth/aspect. | This prevents `"Bukal dan Resesi"` from being misread as a range instruction. |
| **The metric never clears `activeSelection`.** Only tooth identifiers, jawbone jumps, explicit commits, and full flushes clear it. | Allows `"Mesio Bukal Resesi 1"` to work — the anatomy selects the site, then the metric changes, then `1` is applied to the still-active selection. |
| **Boolean metrics bypass `flushNumbers`.** They are emitted only by `emitBoolIfPending()`. If a number arrives while a boolean metric is active, the parser emits the boolean first, restores to main sequence, then treats the number as a probing depth value. | Prevents ghost number commands from being emitted under boolean metrics. |
| **The `plaque` fallback is last-resort only.** If `metricHadSpecificTargets` is false when switching away from `.plaque`, a whole-sequence command is emitted. | Handles `"Plaque pada semua gigi"` naturally but does not emit duplicate commands if individual targets were already specified. |
| **Auto-advance only on plain-tooth PD selections.** An `activeSelection` with a specific anatomy or site (`startAspect != nil`) blocks auto-advance after flushing. | Ensures that a corrective single-site PD annotation (`"Mesio Bukal 16 2"`) does not advance the cursor to the next tooth. |
| **`lastAutoAdvancedFromTooth` is cleared on every new tooth identifier.** | Prevents the snap-back from triggering when a genuine new tooth was explicitly named. |
| **`restoreToMainSequence` short-circuits for boolean metrics.** It returns early before entering the numeric flush path when the current metric is `.bleeding`, `.plaque`, or `.implant`. | Prevents a spurious number-flush command from being emitted when restoring context after a boolean range (e.g., `"BOP dari bukal 16 hingga bukal 15"`). |
| **`ChartProcessor` rebuilds from full `commandHistory` on every change.** | Guarantees idempotency. Mid-stream partial parses cannot corrupt the chart state because the history is always replayed from scratch. |
| **`VoiceCommandParser` is re-instantiated on every word.** | Guarantees that no parser instance state leaks between words. The full accumulated text, not the parser, is the session state. |
