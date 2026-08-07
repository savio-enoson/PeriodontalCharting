# Periodontal Charting — ML Tokenizer Guide

This guide covers the Swift-native ML tokenizer: `TokenizerManager`, `MLVoiceTokenizer`, `MLTokenizerState`, and `BertTokenizer`. These components form the default Phase 1 path in the voice pipeline, replacing the rule-based `VoiceTokenizer` when the CoreML model (`VoiceTokenizerModel.mlmodelc`) is available.

For the project brief and roadmap, see [project_guide.md](project_guide.md).
For the full pipeline architecture and rule-based fallback path, see [system_guide.md](system_guide.md).
For the Swift file-by-file reference, see [frontend_guide.md](frontend_guide.md).

---

## Table of Contents

1. [Overview](#1-overview)
2. [TokenizerManager](#2-tokenizermanager)
   - [Normalization](#21-normalization)
   - [Sentence Splitting](#22-sentence-splitting)
   - [ML Inference Loop](#23-ml-inference-loop)
   - [Post-processing Pass](#24-post-processing-pass)
   - [Fallback Behavior](#25-fallback-behavior)
3. [MLVoiceTokenizer](#3-mlvoicetokenizer)
   - [Model Loading](#31-model-loading)
   - [Pre-allocated Buffers](#32-pre-allocated-buffers)
   - [predict() Inference Loop](#33-predict-inference-loop)
   - [Label → VoiceToken Mapping](#34-label--voicetoken-mapping)
4. [MLTokenizerState](#4-mltokenizerstate)
5. [BertTokenizer](#5-berttokenizer)
6. [Label Schema](#6-label-schema)
7. [State Conditioning](#7-state-conditioning)
   - [Active Metric Encoding](#71-active-metric-encoding)
   - [Prior Label History Encoding](#72-prior-label-history-encoding)
8. [CoreML Input Specification](#8-coreml-input-specification)
9. [Post-processing Heuristics](#9-post-processing-heuristics)
10. [Integration Status](#10-integration-status)

---

## 1. Overview

The ML tokenizer replaces the rule-based `VoiceTokenizer` as the primary Phase 1 component. Its job is identical: convert a normalized text string into a `[VoiceToken]` array that `VoiceCommandParser` can consume. The difference is how it works internally — instead of a hand-written alias dictionary and regex rules, it runs a CoreML word classifier that has learned clinical vocabulary from labeled training examples.

The critical constraint is that clinical tokenization is a **small, closed-vocabulary** word classification problem. The vocabulary of clinically meaningful token types is fixed (40 labels). A CoreML word classifier operating at per-word granularity is fast enough for live dictation and accurate enough to handle the spelling variants, STT transcription errors, and context-dependent disambiguations that the rule-based tokenizer struggles with.

> [!IMPORTANT]
> The ML tokenizer replaces only **Phase 1** (word classification). Phase 2 (`VoiceCommandParser`) is unchanged — it receives the same `[VoiceToken]` array regardless of which Phase 1 path produced it. The two phases are architecturally independent.

The ML path is gated by `UserDefaults.standard.bool(forKey: "useMLTokenizer")`, which defaults to `true`. Setting it to `false` (e.g., via the **Debug → NLP Phase 1 Tokenizer** toggle in the app) falls back to `VoiceTokenizer` directly.

> [!NOTE]
> **Rule-based fallback robustness heuristics.** The rule-based `VoiceTokenizer` (fallback path) contains several additional STT-robustness heuristics that are *not* replicated in the ML path:
> - **Fused directional-compound splitter** — peels a fuzzy trailing site suffix (`bukal`, `lingual`, `palatal` and variants) off any `m`/`d`-initial fused token (e.g. `"mesiyobukal"` → `"mesio bukal"`).
> - **Positional stem recovery** — any unrecognised word sitting immediately before a site word is resolved directionally (`m`-initial → `mesio`, otherwise → `disto`), catching novel Whisper mis-transcriptions of the directional stem without code changes.
> - **Adjacency rule for `di`+`bop`** — a `di`-family fragment immediately followed by a `bop`-family fragment is remapped to `.anatomy(.distoBuccal)` before either resolves to its normal token, preventing STT compression of `"disto bukal"` from triggering a spurious BOP command.
>
> These heuristics exist because the ML model is trained to handle most variant spellings natively. If a new spelling variant is observed that the model misclassifies, the fix is typically a training-data addition, not a code change. The rule-based path's heuristics serve as a safety net when the model is unavailable.

---

## 2. TokenizerManager

**File:** `NLP/Tokenizer/TokenizerManager.swift`

`TokenizerManager` is a singleton (`TokenizerManager.shared`) and the **only entry point** for tokenization in the app. `AIVoiceViewModel` always calls `TokenizerManager.shared.tokenize(text:isFinal:)` — it never calls `VoiceTokenizer` or `MLVoiceTokenizer` directly.

```swift
final class TokenizerManager {
    static let shared = TokenizerManager()
    var mlTokenizer: MLVoiceTokenizer?

    func loadModel()  // Call once at app launch (or when AI Mode starts)
    func tokenize(text: String, isFinal: Bool = false) -> [VoiceToken]
}
```

`loadModel()` is called by `AIVoiceViewModel.startLiveDictation()` after `TranscriptionEngine` is ready. It is idempotent — if `mlTokenizer` is already non-nil, it returns immediately.

### 2.1 Normalization

Before tokenization, `TokenizerManager.normalize(text:)` applies the following transformations in order:

**String-level replacements:**

| Pattern | Normalized to | Reason |
|---|---|---|
| `(?\<=\d)\.(?=\d)` (regex) | `" "` | Preserves decimal separators between digits as spaces, preventing `"1.6"` from becoming `"1 _sep_ 6"` |
| `.` | `" _sep_ "` | Hard sentence boundary |
| `,` | `" "` | Commas separate list items but do not end a sentence |
| `\n` / `\r` | `" _sep_ "` / `" "` | Newlines end the current dictation sentence |
| `{` / `}` | `" "` | Strip correction markers |
| `mesiolingual` | `"mesio lingual"` | No-space compound → multi-word alias compatible |
| `distolingual` | `"disto lingual"` | Same |
| `mesiopalatal` | `"mesio palatal"` | Same |
| `distopalatal` | `"disto palatal"` | Same |
| `mesiolabial` | `"mesio labial"` | Same |
| `distolabial` | `"disto labial"` | Same |
| `mid-` / `mid ` | `"mid"` | Normalize hyphenated/spaced mid-prefix |
| ` -` | `" minus "` | Inline negative sign → word |
| `-` | `" "` | Remaining hyphens (e.g., hyphenated tooth numbers) |
| `b o p` / `b.o.p` / `bleeding on probing` / `bleeding or probing` | `"bop"` | BOP aliases |
| `probing depth` | `"poket"` | English-language phrase → Indonesian metric keyword |

**Word-level spell correction** (applied after splitting on whitespace):

| Misspelling(s) | Corrected to |
|---|---|
| `misio`, `mesyio`, `mesyu`, `meso`, `mezzo` | `mesio` |
| `misial`, `mesyal` | `mesial` |
| `disco` | `disto` |
| `diso`, `distio`, `dista` | `disto` |
| `disal` | `distal` |
| `sampe` | `sampai` |
| `bocal`, `vocal`, `buka`, `buckal`, `buk`, `pukal` | `bukal` |
| `plat`, `plug`, `flak`, `plek`, `flek`, `black`, `flag` | `plak` |
| `pocket`, `poke`, `poked` | `poket` |
| `beope`, `biopi`, `tiopi`, `bleeding` | `bop` |
| `palato`, `palat` | `palatal` |
| `linguo` | `lingual` |
| `enggak`, `nda`, `ndak` | `gak` |
| `mobiliti` | `mobility` |
| `purkasi`, `furkasion`, `forkasi` | `furkasi` |

**Three-digit-or-longer number splitting:** Any token that `Int(word) >= 100` is split into individual digit characters before continuing. E.g., `"162"` → `["1", "6", "2"]`. This prevents multi-digit transcriptions from being treated as single tokens.

The normalization output is a space-joined word array.

### 2.2 Sentence Splitting

After normalization, `tokenize()` splits the word array on `"_sep_"` boundaries into sentences. Each sentence is processed by the ML inference loop with a **fresh `MLTokenizerState`** — state (active metric, prior label history) does not carry across sentence boundaries, matching the semantic reset that `_sep_` represents.

`_sep_` tokens are re-inserted between sentence segments in the final output so `VoiceCommandParser` can see the boundaries.

### 2.3 ML Inference Loop

For each word in a sentence:

1. **Build context window:** Collect words from `max(0, i - 10)` to `min(count - 1, i + 5)` — up to 10 preceding words and 5 following words. Compute `wordIndex = i - contextStart` (0-based index of the target word within this window).
2. **Call `mlTokenizer.predict(wordIndex:context:state:originalWord:)`** with the context window and a mutable `MLTokenizerState`. The state is updated in-place by the call (active metric and prior label history are updated after each prediction).
3. **Deduplicate:** If the predicted token is the same anatomy or action type as the immediately preceding token in the output, skip it. This suppresses the model re-predicting the same anatomy token for consecutive words that both map to the same label (e.g., `"mesio bukal"` after compound expansion might produce two `ANAT_MESIOBUCCAL` predictions — only the first is kept).
4. Append the returned `VoiceToken` (if non-nil) to the sentence output.

### 2.4 Post-processing Pass

After the ML inference loop produces a raw token array for all sentences, `tokenize()` runs a second pass over the combined token array to apply heuristics that the model alone cannot reliably handle:

**Multi-word action token assembly:**

Certain two-word sequences that `mapLabelToVoiceTokens` emits as `.word(w)` fall-through tokens are reassembled into proper action tokens:

| Word sequence | Produced token |
|---|---|
| `"gak"` + `"ada"` (next word) | `.action(.missing)` |
| `"tidak"` + `"ada"` (next word) | `.action(.missing)` |
| `"missing"` | `.action(.missing)` |
| `"semua"` / `"semuanya"` / `"seluruh"` / `"seluruhnya"` | `.action(.all)` |
| `"lanjut"` / `"selesai"` / `"kemudian"` / `"selanjutnya"` / `"berikutnya"` | `.action(.commit)` |
| `"dari"` / `"mulai"` | `.action(.from)` |
| `"sampai"` / `"hingga"` / `"ke"` | `.action(.until)` |

These cover cases where the ML model predicts `FILLER` or falls through to `.word(w)` for common action words.

**11-repeating number rule:**

If a `.number(n)` arrives where `n >= 11` and `n % 11 == 0` (e.g., `11`, `22`, `33`, `44`), and the previous processed token was also a number, the token is interpreted as two identical single digits: emit `.number(n / 11)` twice. This handles the case where Whisper transcribes two identical spoken digits (e.g., `"dua dua"`) as the integer `22`.

**Two-digit number → tooth identifier:**

Any `.number(n)` where `10 < n < 99` is unconditionally promoted to `.toothIdentifier(n)`. This handles cases where the model predicted `NUMBER` for a two-digit token that is unambiguously a tooth number in context.

**Single-digit pair merging:**

When two consecutive single digits (`d1` in 1–4, `d2` in 1–8) appear where:
- No third digit follows immediately (lookahead skips `_sep_`),
- No preceding digit exists in the current block (lookbehind stops at `_sep_` or anatomy tokens),

they are merged into `.toothIdentifier(d1 * 10 + d2)`. This reconstructs tooth numbers like `16` from separate `1` + `6` tokens when the model classified each word independently as `NUMBER`.

**Tooth identifier quadrant reassembly:**

Two consecutive `.toothIdentifier(d1)` tokens where both `d1` and `d2` are in 1–8 are merged into `.toothIdentifier(d1 * 10 + d2)` — this handles cases where a two-digit FDI tooth number was split into two single-digit identifiers by the model.

**Consecutive duplicate anatomy removal:**

Any `.anatomy(a)` token identical to the preceding processed token is dropped, preventing double-anatomy sequences from reaching the parser.

### 2.5 Fallback Behavior

If `useMLTokenizer` is `false`, or `mlTokenizer` is `nil` (model file not found or failed to load), `tokenize()` calls `VoiceTokenizer.tokenize(text:isFinal:)` directly and returns its output unchanged. The rest of the pipeline is unaffected — the same `[VoiceToken]` interface is used in both cases.

---

## 3. MLVoiceTokenizer

**File:** `NLP/Tokenizer/MLVoiceTokenizer.swift`

`MLVoiceTokenizer` wraps the CoreML model and runs per-word inference. It is a `final class` declared `@unchecked Sendable` so it can be safely shared across isolation boundaries in Swift 6 strict concurrency.

### 3.1 Model Loading

`init()` loads the model in two steps:

1. **`vocab.txt`** — `Bundle.main.url(forResource: "vocab", withExtension: "txt")`. In `#if DEBUG`, if the bundle resource is absent, falls back to the hardcoded absolute path `…/AI/vocab.txt` in the project directory.
2. **`VoiceTokenizerModel.mlmodelc`** — `Bundle.main.url(forResource: "VoiceTokenizerModel", withExtension: "mlmodelc")`. In `#if DEBUG`, falls back to a hardcoded absolute path at the project root.

If either resource fails to load, `self.model = nil` and all subsequent `predict()` calls return `nil` (the post-processing pass in `TokenizerManager` handles nil returns gracefully).

### 3.2 Pre-allocated Buffers

All five CoreML input tensors are allocated once in `setupBuffers()` and reused on every `predict()` call, eliminating per-inference allocation overhead:

```swift
inputIdsBuffer      = MLMultiArray(shape: [1, 32], dataType: .int32)
attentionMaskBuffer = MLMultiArray(shape: [1, 32], dataType: .int32)
targetTokenIdxBuffer = MLMultiArray(shape: [1],   dataType: .int32)
activeMetricIdBuffer = MLMultiArray(shape: [1],   dataType: .int32)
priorLabelIdsBuffer  = MLMultiArray(shape: [1, 3], dataType: .int32)
```

The maximum sequence length is `maxLen = 32` subword tokens (WordPiece BPE pieces, not words).

### 3.3 `predict()` Inference Loop

```swift
func predict(wordIndex: Int, context: [String], state: inout MLTokenizerState, originalWord: String) -> VoiceToken?
```

**Steps:**

1. **Thread safety:** Acquires `inferenceLock` (an `NSLock`) before writing to the shared pre-allocated buffers. This protects against concurrent calls from live dictation and the UI thread.

2. **Encode context:** Prepend `[CLS]` (token ID 2). For each word in `context`, call `bertTokenizer.encode(word)` and append the resulting subword IDs. Append `[SEP]` (token ID 3). Record `targetIdx` = the position of the first subword token of the target word (at `wordIndex`) within this sequence.

3. **Truncation:** If the sequence exceeds `maxLen`, keep the last `maxLen - 2` interior tokens (drop from the beginning, preserving `[CLS]` and `[SEP]`). Recompute `targetIdx` accordingly; if the target word was truncated away, point to position 1 (first real token).

4. **Padding:** Extend with `padTokenId = 0` and `attentionMask = 0` until length equals `maxLen`.

5. **Fill buffers:** Write `inputIds` and `attentionMask` arrays into pre-allocated `MLMultiArray`s. Set `targetTokenIdxBuffer[0]` = `targetIdx`, `activeMetricIdBuffer[0]` = `state.activeMetric`, and `priorLabelIdsBuffer[0,0..2]` = `state.priorLabels`.

6. **Inference:** Call `model.prediction(from: MLDictionaryFeatureProvider)`. The model has a single output (logits, shape `[1, 42]`). Take the argmax over the label dimension.

7. **State update:**
   - If the predicted label is a metric label (`METRIC_PD` through `METRIC_IMPLANT`), update `state.activeMetric` to the corresponding metric ID (0–7).
   - If the predicted label is not `FILLER`, `PAD`, or `SEPARATOR`, shift `state.priorLabels` left and append the predicted label index. This keeps a rolling 3-label history.

8. **Return:** Call `mapLabelToVoiceTokens(label:word:)` and return the result (may be `nil` for dropped labels).

### 3.4 Label → VoiceToken Mapping

`mapLabelToVoiceTokens(label:word:)` converts a predicted string label into a `VoiceToken?`:

| Label | VoiceToken produced | Notes |
|---|---|---|
| `NUMBER` | `.number(Int)` | Parses from `originalWord` via `Int(word)` then `VoiceTokenizer.parseIntOrWord(word)` |
| `SIGNED_NUMBER` | `.number(-Int)` | Negates the parsed integer |
| `TOOTH_ID` | `.toothIdentifier(Int)` | Parses from `originalWord` |
| `METRIC_PD` | `.metric(.probingDepth, multiplier: 1)` | |
| `METRIC_GM_NEG` | `.metric(.gingivalMargin, multiplier: -1)` | Recession — negative multiplier |
| `METRIC_GM_POS` | `.metric(.gingivalMargin, multiplier: 1)` | Pseudopocket — positive multiplier |
| `METRIC_BOP` | `.metric(.bleeding, multiplier: 1)` | |
| `METRIC_PLAQUE` | `.metric(.plaque, multiplier: 1)` | |
| `METRIC_MOBILITY` | `.metric(.mobility, multiplier: 1)` | |
| `METRIC_FURCATION` | `.metric(.furcation, multiplier: 1)` | |
| `METRIC_IMPLANT` | `.metric(.implant, multiplier: 1)` | |
| `ANAT_MESIOBUCCAL` | `.anatomy(.mesioBuccal)` | |
| `ANAT_DISTOBUCCAL` | `.anatomy(.distoBuccal)` | |
| `ANAT_MIDBUCCAL` | `.anatomy(.midBuccal)` | |
| `ANAT_MESIOPALATAL` | `.anatomy(.mesioPalatal)` | |
| `ANAT_DISTOPALATAL` | `.anatomy(.distoPalatal)` | |
| `ANAT_MIDPALATAL` | `.anatomy(.midPalatal)` | |
| `ANAT_MESIOLINGUAL` | `.anatomy(.mesioLingual)` | |
| `ANAT_DISTOLINGUAL` | `.anatomy(.distoLingual)` | |
| `ANAT_MIDLINGUAL` | `.anatomy(.midLingual)` | |
| `ANAT_MESIOLABIAL` | `.anatomy(.mesioBuccal)` | Labial = buccal (outer face); both refer to the outer aspect |
| `ANAT_DISTOLABIAL` | `.anatomy(.distoBuccal)` | Same — labial and buccal are the outer side |
| `ANAT_MIDLABIAL` | `.anatomy(.midLabial)` | |
| `ANAT_MESIAL` | `.anatomy(.mesial)` | |
| `ANAT_DISTAL` | `.anatomy(.distal)` | |
| `ANAT_BUCCAL` | `.anatomy(.buccal)` | |
| `ANAT_LINGUAL` | `.anatomy(.lingual)` | |
| `ANAT_PALATAL` | `.anatomy(.palatal)` | |
| `ANAT_LABIAL` | `.anatomy(.labial)` | |
| `ACTION_COMMIT` | `.action(.commit)` | |
| `ACTION_MISSING` | `.action(.missing)` | |
| `ACTION_FROM` | `.action(.from)` | |
| `ACTION_UNTIL` | `.action(.until)` | |
| `ACTION_AT` | `.action(.at)` | |
| `ACTION_ALL` | `.action(.all)` | |
| `JAW_UPPER` | `.anatomy(.upperJaw)` | |
| `JAW_LOWER` | `.anatomy(.lowerJaw)` | |
| `SIGN_MINUS` | `nil` | Dropped — the `" -"` → `" minus "` normalization in `TokenizerManager` handles this structurally |
| `TOOTH_MARKER` | `nil` | Dropped — `"gigi"` is a structural marker consumed by context |
| `SEPARATOR` | `nil` | Dropped — `_sep_` is re-inserted by `TokenizerManager` at sentence boundaries |
| `FILLER` | `.number(n)` if parseable, else `.word(w)` | Attempts numeric parse so digit filler words are not silently lost |
| `PAD` | `.number(n)` if parseable, else `.word(w)` | Same |

> [!NOTE]
> `ANAT_MESIOLABIAL` maps to `.anatomy(.mesioBuccal)` and `ANAT_DISTOLABIAL` maps to `.anatomy(.distoBuccal)`. This is intentional: in periodontal anatomy, "labial" and "buccal" both refer to the outer (facial) surface. The parser uses `.outer` as the unified aspect for both, so the mapping is semantically correct.

---

## 4. MLTokenizerState

**File:** `NLP/Tokenizer/MLTokenizerState.swift`

```swift
struct MLTokenizerState {
    var activeMetric: Int         // 0–7, see §7.1
    var priorLabels: [Int]        // rolling window of last 3 predicted label indices
    var contextWindow: [String]   // reserved field (not used in current inference loop)

    init(activeMetric: Int, priorLabels: [Int] = [41, 41, 41], contextWindow: [String] = [])
}
```

**Lifetime:** One `MLTokenizerState` is created per sentence (per split at `_sep_`). It is passed as `inout` to `MLVoiceTokenizer.predict()` and mutated word-by-word within that sentence. It is never shared across sentences — each sentence starts with `activeMetric = 0` (Probing Depth) and `priorLabels = [41, 41, 41]` (three `PAD` labels; index 41 is the `PAD` entry in `validLabels`).

**Fields:**

| Field | Initial value | Updated when |
|---|---|---|
| `activeMetric` | `0` (Probing Depth) | Model predicts any `METRIC_*` label → updates to the corresponding metric ID (0–7) |
| `priorLabels` | `[41, 41, 41]` (`PAD` × 3) | Model predicts any non-`FILLER`/`PAD`/`SEPARATOR` label → shift left, append new label index |
| `contextWindow` | `[]` | Unused in the current inference path (context is computed inline in `TokenizerManager`) |

---

## 5. BertTokenizer

**File:** `NLP/Tokenizer/BertTokenizer.swift`

A minimal Swift implementation of the WordPiece tokenizer used by IndoBERT. Loaded from `AI/vocab.txt` (or the `#if DEBUG` fallback path).

**Special token IDs:**

| Token | ID |
|---|---|
| `[PAD]` | `0` |
| `[UNK]` | `1` |
| `[CLS]` | `2` |
| `[SEP]` | `3` |

**`encode(_ word: String) -> [Int]`:**

Applies greedy longest-match WordPiece tokenization:
1. Lowercase the input.
2. Starting at position 0, find the longest prefix present in `vocab`. For positions > 0, search for `"##" + suffix`.
3. If no match exists for a character, return `[unkTokenId]` (the entire word becomes a single unknown token).
4. Return the list of vocabulary IDs.

**Usage in `MLVoiceTokenizer`:** The tokenizer encodes each word in the context window to produce the `input_ids` sequence fed to the model. Because the model operates on subword tokens and `targetIdx` must point to the first subword of the target word, `encode()` is called once per word during buffer filling to track the correct index.

---

## 6. Label Schema

The model predicts one of **42 labels** per word (40 clinical labels + `SEPARATOR` + `PAD`). The full ordered label list is defined in `MLVoiceTokenizer.validLabels`:

```swift
static let validLabels = [
    "NUMBER", "SIGNED_NUMBER", "TOOTH_MARKER", "TOOTH_ID",
    "METRIC_PD", "METRIC_GM_NEG", "METRIC_GM_POS", "METRIC_BOP",
    "METRIC_PLAQUE", "METRIC_MOBILITY", "METRIC_FURCATION", "METRIC_IMPLANT",
    "ANAT_MESIOBUCCAL", "ANAT_DISTOBUCCAL", "ANAT_MIDBUCCAL",
    "ANAT_MESIOPALATAL", "ANAT_DISTOPALATAL", "ANAT_MIDPALATAL",
    "ANAT_MESIOLINGUAL", "ANAT_DISTOLINGUAL", "ANAT_MIDLINGUAL",
    "ANAT_MESIOLABIAL", "ANAT_DISTOLABIAL", "ANAT_MIDLABIAL",
    "ANAT_MESIAL", "ANAT_DISTAL",
    "ANAT_BUCCAL", "ANAT_LINGUAL", "ANAT_PALATAL", "ANAT_LABIAL",
    "ACTION_COMMIT", "ACTION_MISSING", "ACTION_FROM", "ACTION_UNTIL",
    "ACTION_AT", "ACTION_ALL",
    "JAW_UPPER", "JAW_LOWER",
    "SIGN_MINUS", "SEPARATOR", "FILLER", "PAD"
]
```

The argmax index into this array is the predicted label. The index is also used directly as the label ID in `state.priorLabels` (e.g., `FILLER` = index 40, `PAD` = index 41).

**Label groupings:**

| Group | Labels | Description |
|---|---|---|
| Numbers | `NUMBER`, `SIGNED_NUMBER` | Integer measurements (unsigned and pre-negated) |
| Tooth targeting | `TOOTH_MARKER`, `TOOTH_ID` | `"gigi"` keyword and FDI tooth numbers |
| Metrics | `METRIC_PD` … `METRIC_IMPLANT` | 8 clinical measurement types |
| Specific anatomy | `ANAT_MESIOBUCCAL` … `ANAT_MIDLABIAL` | 12 sub-site anatomical positions |
| Surface anatomy | `ANAT_MESIAL`, `ANAT_DISTAL`, `ANAT_BUCCAL`, `ANAT_LINGUAL`, `ANAT_PALATAL`, `ANAT_LABIAL` | 6 general surface descriptors |
| Actions | `ACTION_COMMIT` … `ACTION_ALL` | 6 navigation / structural commands |
| Jaw | `JAW_UPPER`, `JAW_LOWER` | Full-jaw context switches |
| Structure | `SIGN_MINUS`, `SEPARATOR` | Sign modifier and sentence boundary |
| Non-clinical | `FILLER`, `PAD` | Hesitations, fillers, padding |

---

## 7. State Conditioning

The model is conditioned on two pieces of per-sentence state that evolve word-by-word. These allow the model to resolve context-dependent ambiguity — particularly the NUMBER vs. TOOTH_ID disambiguation — without a separate look-back pass.

### 7.1 Active Metric Encoding

`state.activeMetric` encodes which metric is currently active (i.e., the most recently predicted metric label within this sentence). It is an integer ID 0–8, where 8 means "no active metric" (initial state):

| ID | Metric |
|---|---|
| `0` | Probing Depth (`METRIC_PD`) |
| `1` | Gingival Margin — recession (`METRIC_GM_NEG`) |
| `2` | Gingival Margin — enlargement (`METRIC_GM_POS`) |
| `3` | Bleeding on Probing (`METRIC_BOP`) |
| `4` | Plaque (`METRIC_PLAQUE`) |
| `5` | Mobility (`METRIC_MOBILITY`) |
| `6` | Furcation (`METRIC_FURCATION`) |
| `7` | Implant (`METRIC_IMPLANT`) |

This is passed to the model as `active_metric_id` (a `[1]` Int32 tensor). The model's learned embedding for this ID provides context that helps disambiguate, e.g., whether `"1"` following `"resesi"` is a recession value or the start of a tooth number.

### 7.2 Prior Label History Encoding

`state.priorLabels` is a rolling window of the label indices of the last 3 non-structural predicted tokens. It is initialized to `[41, 41, 41]` (three `PAD` indices) at the start of each sentence.

After each prediction, if the label is not `FILLER`, `PAD`, or `SEPARATOR`:
```swift
state.priorLabels.removeFirst()
state.priorLabels.append(maxIndex)  // index of the predicted label in validLabels
```

This 3-label history is passed to the model as `prior_label_ids` (a `[1, 3]` Int32 tensor). It gives the model short-range sequential memory — e.g., after `TOOTH_MARKER`, the next token is almost certainly `TOOTH_ID`; after three `NUMBER` predictions, a new number is likely continuing a probing depth triple rather than starting a tooth number.

---

## 8. CoreML Input Specification

The model (`VoiceTokenizerModel_int8.mlmodelc`) expects five named inputs:

| Input name | Shape | Type | Description |
|---|---|---|---|
| `input_ids` | `[1, 32]` | `Int32` | WordPiece subword token IDs for the context window, padded/truncated to 32 |
| `attention_mask` | `[1, 32]` | `Int32` | `1` for real tokens, `0` for padding |
| `target_token_idx` | `[1]` | `Int32` | Index (0-based within the 32-slot sequence) of the target word's first subword token |
| `active_metric_id` | `[1]` | `Int32` | Active metric ID from `MLTokenizerState.activeMetric` |
| `prior_label_ids` | `[1, 3]` | `Int32` | Last 3 predicted label indices from `MLTokenizerState.priorLabels` |

**Output:** A single output tensor containing `logits` of shape `[1, 42]`. Argmax over the last dimension gives the predicted label index into `validLabels`.

---

## 9. Post-processing Heuristics

The post-processing pass in `TokenizerManager.tokenize()` runs over the raw ML output and corrects known failure modes. The heuristics are applied in the order listed:

**1. Action word fall-through rescue** — Catches multi-word actions and common single-word actions that the ML model may predict as `FILLER` or produce as `.word(w)` tokens. Inspects `w` directly and promotes to the correct `.action(_)` token.

**2. 11-repeating number rule** — Catches paired repeated digits (e.g., `"dua dua"` → `22`) that Whisper may produce as a two-digit integer. Only triggers when the previous processed token was also a number. Decomposes `n` into `n/11` emitted twice.

**3. Two-digit unconditional tooth promotion** — Any `.number(n)` with `10 < n < 99` is promoted to `.toothIdentifier(n)`. At this granularity, two-digit integers in dictation are overwhelmingly FDI tooth numbers, not measurements (which are 0–10 mm).

**4. Single-digit pair merging with lookahead/lookbehind** — Merges two consecutive single-digit tokens into a tooth identifier when:
   - `d1` is 1–4 (valid FDI quadrant prefix)
   - `d2` is 1–8 (valid FDI tooth position)
   - No third digit follows (lookahead, skipping `_sep_`)
   - No preceding digit exists in the current block (lookbehind, stopping at `_sep_` or anatomy tokens)

   This reconstructs tooth numbers from ML predictions that classified each digit of `"gigi 16"` as a separate `NUMBER`.

**5. Single-digit pair toothID reassembly** — Merges two consecutive `.toothIdentifier(d)` tokens where both `d` values are single digits (1–8) into `.toothIdentifier(d1 * 10 + d2)`.

**6. Consecutive duplicate anatomy removal** — Drops any `.anatomy(a)` that is identical to the immediately preceding processed token.

> [!NOTE]
> The ordering of these heuristics matters. The two-digit unconditional promotion (step 3) runs before the single-digit merging (step 4). This means a pre-existing two-digit number token from the ML output is promoted first; only individual single-digit tokens reaching step 4 are candidates for merging.

---

## 10. Integration Status

| Component | Status |
|---|---|
| `TokenizerManager.shared` singleton | ✅ Complete — loaded by `AIVoiceViewModel.startLiveDictation()` |
| `MLVoiceTokenizer` CoreML inference | ✅ Complete — `VoiceTokenizerModel.mlmodelc` |
| `BertTokenizer` WordPiece encoding | ✅ Complete — backed by `AI/vocab.txt` |
| `MLTokenizerState` per-sentence state | ✅ Complete |
| Post-processing pass | ✅ Complete |
| `useMLTokenizer` UserDefaults toggle | ✅ Complete — `true` by default; toggled via **Debug → NLP Phase 1 Tokenizer** at runtime |
| Rule-based `VoiceTokenizer` fallback | ✅ Complete — activated when model is absent or toggle is off; includes additional STT robustness heuristics (see §1 Overview) |
| Wiring to live dictation pipeline | ✅ Complete — `AIVoiceViewModel` calls `TokenizerManager.shared.tokenize()` via `VoiceCommandParser.parse()` |
