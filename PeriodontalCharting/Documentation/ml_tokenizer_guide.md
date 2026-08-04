# Periodontal Charting — ML Tokenizer & Speech Pipeline Guide

This guide covers the machine-learning components of the voice pipeline: the **Phase 1 ML Tokenizer** (IndoBERT CoreML word classifier), the **WhisperKit + Silero VAD** speech-to-text layer, and the **Phase 2 TinyTransducer** evaluation — including the decision to retain the rule-based Swift parser as the deterministic Phase 2 component.

For the project brief and roadmap, see [project_guide.md](project_guide.md).
For the Swift file-by-file reference (including `MLVoiceTokenizer`, `TokenizerManager`, `TranscriptionEngine`, etc.), see [frontend_guide.md](frontend_guide.md).
For the full NLP parsing logic (Phase 2), see [system_guide.md](system_guide.md).

---

## Table of Contents

1. [Motivation — Why an ML Tokenizer?](#1-motivation--why-an-ml-tokenizer)
2. [Architecture Overview](#2-architecture-overview)
3. [Phase 0 — Speech-to-Text (WhisperKit + Silero VAD)](#3-phase-0--speech-to-text-whisperkit--silero-vad)
4. [Phase 1 — ML Tokenizer (Word Classifier)](#4-phase-1--ml-tokenizer-word-classifier)
   - [Label Schema](#41-label-schema)
   - [State Conditioning](#42-state-conditioning)
   - [Model Architecture](#43-model-architecture)
   - [Swift Integration](#44-swift-integration)
5. [Training Pipeline](#5-training-pipeline)
   - [Data Categories](#51-data-categories)
   - [Training Script](#52-training-script)
   - [CoreML Export](#53-coreml-export)
6. [Evaluation Results](#6-evaluation-results)
7. [Phase 2 — TinyTransducer (Evaluated & Abandoned)](#7-phase-2--tinytransducer-evaluated--abandoned)
   - [Architecture](#71-architecture)
   - [Performance](#72-performance)
   - [Failure Analysis](#73-failure-analysis)
   - [Decision: Retain Swift Parser](#74-decision-retain-swift-parser)
8. [Live STT Integration Status](#8-live-stt-integration-status)

---

## 1. Motivation — Why an ML Tokenizer?

The rule-based `VoiceTokenizer` maps words to typed tokens via a hand-written alias dictionary and regex rules. It fails in four predictable ways:

| Failure mode | Example | Root cause |
|---|---|---|
| Novel spelling variants | `"tigaa"`, `"empaat"`, `"siiga"` | Not in the alias dictionary |
| Unrecognized synonyms | `"darah"` for BOP, regional dialectal variants | Not in the alias dictionary |
| STT-introduced errors | Whisper transcribes `"mesio"` as `"misio"`, `"meso"` | Pattern mismatch |
| Context-dependent disambiguation | `"1 7"` could be values `[1, 7]` or tooth `17` | Rule-based context is fragile |

An ML classifier generalizes from labeled examples, handling all of these via learned representations rather than hand-coded rules. The critical insight is that the clinical vocabulary is **small and closed** — approximately 40 token type classes — so a classifier can be trained to near-perfect accuracy with a modest labeled dataset.

> [!IMPORTANT]
> The ML tokenizer replaces only **Phase 1** (word classification). Phase 2 (parsing typed tokens into `AnnotationCommand` mutations) remains the rule-based `VoiceCommandParser`. The two phases are architecturally independent — improving one does not require changing the other.

---

## 2. Architecture Overview

```
Live microphone audio
        │
        ▼
┌─────────────────────────────────┐
│  Phase 0: Speech-to-Text        │
│  SileroVADEngine                │  Detects speech segments (32 ms hops)
│  TranscriptionEngine (WhisperKit)│  Whisper large-v3-turbo, 632 MB
│  SequenceBiasFilter             │  Per-step clinical vocab logit biasing
└─────────────────────────────────┘
        │  Indonesian text
        ▼
┌─────────────────────────────────┐
│  Phase 1: ML Tokenizer          │
│  TokenizerManager               │  Shared normalization + dispatch
│    └── MLVoiceTokenizer         │  IndoBERT + CoreML (124 MB int8)
│        └── BertTokenizer        │  WordPiece subword tokenizer
└─────────────────────────────────┘
        │  [VoiceToken]
        ▼
┌─────────────────────────────────┐
│  Phase 2: Swift Parser          │
│  VoiceCommandParser             │  Deterministic rule-based state machine
└─────────────────────────────────┘
        │  [AnnotationCommand]
        ▼
    ChartProcessor → mouthState → ChartDashboard
```

The three-phase separation means each layer can be improved independently:
- **Phase 0:** swap to a different STT model without touching NLP.
- **Phase 1:** retrain the word classifier on new data without touching the parser.
- **Phase 2:** extend the parser's state machine without touching tokenization.

---

## 3. Phase 0 — Speech-to-Text (WhisperKit + Silero VAD)

### WhisperKit

The app bundles **OpenAI Whisper large-v3-turbo** via the [WhisperKit](https://github.com/argmaxinc/WhisperKit) framework (~632 MB quantized). Key design decisions:

**Compute units:** The mel spectrogram and audio encoder run on CPU + Neural Engine; the text decoder also uses the ANE. The encoder is not given ANE-only execution because the ANE compile cache for the encoder graph is fragile — a clean install or update re-triggers ANE specialization, adding ~199 s to the first launch. GPU-assisted encoder loading avoids this at negligible runtime cost (the encoder runs once per 30 s window; the decoder runs thousands of times per window).

**`SequenceBiasFilter`:** On each decoder step, the filter boosts log-probabilities for token sequences matching the clinical vocabulary. This prevents Whisper from substituting acoustically similar but clinically wrong words (e.g. `"mesio"` → `"misi"` or `"situ"`). Bias values are ported from the Python PoC:

| Word tier | Bias value | Examples |
|---|---|---|
| Directional stems | +20.0 | `mesio`, `disto`, `mesial`, `distal` |
| Core clinical terms | +10.0 | `gigi`, `bukal`, `BOP`, `resesi`, `poket` |
| Less-common terms | ~+5.0 | `furkasi`, `kegoyangan`, `implan` |

**`initialPrompt` is not used.** WhisperKit re-injects `promptTokens` into every 30 s window for the entire session. Measured on multi-minute recordings, this caused >50% of audio to be silently dropped. `SequenceBiasFilter` achieves the same vocabulary steering without the session-length degradation.

### Silero VAD

`SileroVADEngine` wraps Silero VAD v5 (`SileroVAD.mlpackage`, ~2 MB). The model is a **streaming LSTM** that processes 32 ms audio chunks at 16 kHz and outputs a speech probability. Two usage modes:

- **Batch mode (`speechTimestamps`)** — runs the full audio array and returns `[SpeechSegment]` (half-open sample index ranges). Used by `TranscriptionViewModel` to identify speech spans before Whisper transcription.
- **Streaming mode (`speechProbabilities`)** — returns per-chunk probability array for gating live Whisper windows.

VAD failure degrades gracefully: if `SileroVADEngine` fails to initialize, batch transcription falls back to whole-clip mode and live mode decodes every window.

---

## 4. Phase 1 — ML Tokenizer (Word Classifier)

### 4.1 Label Schema

The ML tokenizer assigns each word one of **40 typed labels**. The label set is a superset of `VoiceToken`'s cases, with gingival margin polarity split out for cleaner downstream handling:

| Label | Description | Example inputs |
|---|---|---|
| `NUMBER` | Integer measurement value | `tiga`, `3`, `tigaa` |
| `SIGNED_NUMBER` | Signed value (handled via `SIGN_MINUS` + `NUMBER` sequence) | `minus satu` |
| `TOOTH_MARKER` | The word `gigi` (signals upcoming tooth ID) | `gigi`, `g` |
| `TOOTH_ID` | Valid FDI tooth number (11–48) | `16`, `26`, `47` |
| `METRIC_PD` | Probing depth | `poket`, `probing`, `kedalaman` |
| `METRIC_GM_NEG` | Gingival margin — recession (negative) | `resesi`, `kemunduran` |
| `METRIC_GM_POS` | Gingival margin — enlargement (positive) | `enlargement`, `pembengkakan` |
| `METRIC_BOP` | Bleeding on probing | `bop`, `berdarah` |
| `METRIC_PLAQUE` | Plaque score | `plak`, `plaque` |
| `METRIC_MOBILITY` | Tooth mobility | `kegoyangan`, `mobilitas`, `mobility` |
| `METRIC_FURCATION` | Furcation class | `furkasi`, `furcation` |
| `METRIC_IMPLANT` | Implant marker | `implan`, `implant` |
| `ANAT_MESIOBUCCAL` | Mesio-buccal site | `mesiobukal`, `mesio bukal` |
| `ANAT_DISTOBUCCAL` | Disto-buccal site | `distobukal`, `disto bukal` |
| `ANAT_MIDBUCCAL` | Mid-buccal site | `mid bukal`, `tengah bukal` |
| `ANAT_MESIOPALATAL` | Mesio-palatal site | `mesiopalatal` |
| `ANAT_DISTOPALATAL` | Disto-palatal site | `distopalatal` |
| `ANAT_MIDPALATAL` | Mid-palatal site | `mid palatal` |
| `ANAT_MESIOLINGUAL` | Mesio-lingual site | `mesiolingual` |
| `ANAT_DISTOLINGUAL` | Disto-lingual site | `distolingual` |
| `ANAT_MIDLINGUAL` | Mid-lingual site | `mid lingual` |
| `ANAT_MESIOLABIAL` | Mesio-labial site | `mesiolabial` |
| `ANAT_DISTOLABIAL` | Disto-labial site | `distolabial` |
| `ANAT_MIDLABIAL` | Mid-labial site | `mid labial` |
| `ANAT_MESIAL` | Mesial surface (aspect-relative) | `mesial` |
| `ANAT_DISTAL` | Distal surface (aspect-relative) | `distal` |
| `ANAT_BUCCAL` | Full buccal aspect | `bukal`, `bocal` |
| `ANAT_LINGUAL` | Full lingual aspect | `lingual`, `linguo` |
| `ANAT_PALATAL` | Full palatal aspect | `palatal`, `palato` |
| `ANAT_LABIAL` | Full labial aspect | `labial` |
| `ACTION_COMMIT` | Advance cursor / flush | `lanjut`, `selesai`, `berikutnya` |
| `ACTION_MISSING` | Mark tooth as missing | `gak ada`, `tidak ada`, `missing` |
| `ACTION_FROM` | Range start | `dari` |
| `ACTION_UNTIL` | Range end | `sampai`, `hingga` |
| `ACTION_AT` | Post-targeting preposition | `pada`, `di` |
| `ACTION_ALL` | "All teeth" broadcast | `semua`, `seluruh` |
| `JAW_UPPER` | Upper jaw switch | `rahang atas` |
| `JAW_LOWER` | Lower jaw switch | `rahang bawah` |
| `SIGN_MINUS` | Negative sign for recession values | `minus` |
| `SEPARATOR` | Hard sentence boundary (from `.` / `\n`) | `_sep_` |
| `FILLER` | Non-clinical filler / hesitation | `eh`, `uh`, `hmm`, `em` |

**ML label → `VoiceToken` mapping** is performed in `MLVoiceTokenizer.mapLabelToVoiceTokens(label:word:lastToken:)`. Key conversions:
- `NUMBER` → `.number(Int)` — parsed from the raw word using `VoiceTokenizer.parseIntOrWord`.
- `METRIC_GM_NEG` → `.metric(.gingivalMargin, multiplier: -1)` (recession).
- `METRIC_GM_POS` → `.metric(.gingivalMargin, multiplier: 1)` (enlargement).
- `TOOTH_ID` → `.toothIdentifier(Int)` — only if the integer is a valid FDI number (11–48); otherwise `.number`.
- `SEPARATOR` → `.word("_sep_")`.
- `FILLER` → token dropped (not appended to output).

### 4.2 State Conditioning

To resolve context-dependent ambiguity — particularly whether a number is a **measurement value** or a **tooth identifier** — the model is conditioned on two pieces of session state beyond the current word:

**Active Metric Embedding:** The current metric class (`METRIC_PD`, `METRIC_GM_NEG`, etc., or `PAD` if none) is encoded as a learned embedding and concatenated with the word embedding. Example disambiguation:
- Under `METRIC_GM_NEG` (recession): `"1 7"` → `NUMBER(1)` + `TOOTH_ID(17)` (recession is a single value; 7 follows as the next tooth)
- Under `METRIC_PD` (probing): `"1 7"` → `NUMBER(1)` + `NUMBER(7)` (two probing depth values in a triple)

**Prior Label History Embedding:** The last 3 predicted labels (`priorLabels`, initialized to `["PAD", "PAD", "PAD"]`) are each encoded as a learned embedding. This gives the model short-range memory: e.g., after `TOOTH_MARKER`, the next token is almost certainly `TOOTH_ID`.

Both embeddings are concatenated with the BERT per-word hidden state before the linear classification head.

> [!IMPORTANT]
> The `activeMetric` and `priorLabels` state are managed inside an `MLTokenizerState` struct that is created **fresh on every `tokenize()` call** by `TokenizerManager`. This means there is zero state leakage between parse calls — the tokenizer is stateless from the caller's perspective. Within a single call, the state evolves word-by-word as above. If a `_sep_` token is encountered mid-call, all three state fields are reset to their initial values (`PAD`, `[PAD, PAD, PAD]`, and an empty context window), matching the sentence-boundary semantics of the legacy tokenizer.

### 4.3 Model Architecture

```
Input word: "17" (in context "Resesi 1 17")
    │
    ▼ BertTokenizer (WordPiece, vocab.txt)
[CLS, "1", "##7", SEP, pad...] → padded to 32 subword tokens
    │
    ▼ IndoBERT Encoder (indobenchmark/indobert-base-p1, 12-layer, 768-dim)
    Per-token hidden states [h_CLS, h_17, ...]
    │
    ├── h_{target word}  ← selected by targetIndex input (768-dim)
    ├── Active metric embedding  (9 classes → 16-dim)
    └── Prior label history  (3 × 40 classes → 3 × 16-dim = 48-dim)
    │
    ▼ Concatenate → 832-dim vector
    │
    ▼ Linear classification head (832 → 40 classes)
    │
    ▼ Predicted label: TOOTH_ID(17)  ✓
```

**CoreML input tensors:**

| Name | Shape | Type | Description |
|---|---|---|---|
| `input_ids` | `[1, 32]` | `Int32` | WordPiece token IDs, padded/truncated to 32 |
| `attention_mask` | `[1, 32]` | `Int32` | 1 for real tokens, 0 for padding |
| `target_idx` | `[1]` | `Int32` | Index of the target word's first subword token |
| `active_metric_id` | `[1]` | `Int32` | ID of the current active metric |
| `prior_label_ids` | `[1, 3]` | `Int32` | IDs of the last 3 predicted labels |

**Output:** `logits` — `[1, 40]` float tensor. Argmax → label index → `validLabels[index]`.

**Quantization:** Int8 post-training quantization via CoreML Tools reduces the model from ~499 MB (FP32 PyTorch) to ~124 MB with zero accuracy degradation (confirmed by parity check against PyTorch on the full test set).

### 4.4 Swift Integration

`MLVoiceTokenizer` is loaded by `TokenizerManager` at app launch from `Bundle.main.url(forResource: "VoiceTokenizerModel", withExtension: "mlmodelc")`.

**`MLTokenizerState` — fresh per call:** `TokenizerManager.tokenize(text:isFinal:)` creates a new `MLTokenizerState()` struct on every call and passes it as `inout` to `MLVoiceTokenizer.tokenize(text:isFinal:sessionState:)`. This means all per-word state (`activeMetric`, `priorLabels`, `contextWindow`) is isolated to the lifetime of a single tokenize call. The tokenizer itself holds no per-session mutable state, making it safe to share as a singleton.

**Thread safety:** An `NSLock` (`inferenceLock`) wraps each `predict()` call inside `MLVoiceTokenizer`. This protects the pre-allocated `MLMultiArray` input buffers from concurrent writes if `tokenize()` is called from multiple threads (e.g., during live dictation where a background transcription thread and the UI thread may both trigger tokenization).

**Pre-allocated `MLMultiArray` buffers:** All five input tensors are allocated once in `init()` and reused on every call. Raw `UnsafeMutablePointer<Int32>` pointers are bound to each array's data buffer for O(1) writes, eliminating per-word allocation overhead that previously dominated inference cost.

**Per-word inference loop:**
```
for each word in text:
    1. Append to sessionState.contextWindow (last 10 words)
    2. WordPiece-tokenize the context window → input_ids, attention_mask
    3. Fill pre-allocated MLMultiArray buffers via UnsafeMutablePointer
    4. [inferenceLock.lock()] model.prediction(from:) → logits → argmax → label [inferenceLock.unlock()]
    5. mapLabelToVoiceTokens(label:word:lastToken:) → [VoiceToken]
    6. Update sessionState.activeMetric, sessionState.priorLabels
```

**Context window:** The last 10 raw words are maintained and fed as the full BERT input sequence, giving the model bidirectional context for each classification step.

---

## 5. Training Pipeline

All training infrastructure lives in `/ml/scripts/` and `/ml/data/`. Environments: `/ml/.venv` (PyTorch + HuggingFace Transformers) and `/ml/venv_coreml` (CoreML Tools).

### 5.1 Data Categories

Phase 1 training data is organized into 20 subdirectories under `/ml/data/phase1/`:

| Directory | Content |
|---|---|
| `p1_a_canonical` | Canonical forms of every known clinical word and phrase |
| `p1_b_spelling_variants` | Systematic spelling variants (substitutions, duplications, omissions) |
| `p1_c_contextual_disambiguation` | Contrastive examples for ambiguous words in different contexts |
| `p1_d_novel_synonyms` | Regional and colloquial synonyms from clinical staff |
| `p1_e_stt_errors` | STT-introduced substitutions observed from real Whisper transcriptions |
| `p1_f_sentence_context` | Full clinical sentences for broader context training |
| `p1_g_filler_words` | Hesitation words and non-clinical fillers |
| `p1_h_action_commands` | Manually labeled action command data |
| `p1_h_generated_actions` | Synthetically generated action command examples |
| `p1_i_anatomical_modifiers` | Manually labeled anatomical modifier data |
| `p1_i_generated_anatomical` | Synthetically generated anatomical modifier examples |
| `p1_j_clinical_metrics` | Manually labeled metric keyword data |
| `p1_j_generated_metrics` | Synthetically generated metric examples |
| `p1_k_misc_missing` | Edge cases and coverage gaps identified during evaluation |
| `p1_l_low_perf` | Examples targeting low-performing label classes |
| `p1_m_urgent` | High-priority error cases from in-clinic testing |
| `p1_misc` | Miscellaneous examples not fitting other categories |
| `p1_n_actions` | Additional action command coverage |
| `p1_o_anatomy` | Additional anatomical modifier coverage |
| `p1_p_metrics` | Additional metric keyword coverage |

Processed JSONL splits in `/ml/data/processed/phase1/`:

| File | Size | Split |
|---|---|---|
| `train.jsonl` | ~29 MB | ~70% |
| `val.jsonl` | ~3.6 MB | ~15% |
| `test.jsonl` | ~3.6 MB | ~15% |

Each JSONL line is a word-level classification example:
```json
{
  "words": ["gigi", "16", "tiga", "empat", "tiga"],
  "target_idx": 2,
  "label": "NUMBER",
  "active_metric": "METRIC_PD",
  "prior_labels": ["TOOTH_MARKER", "TOOTH_ID", "PAD"]
}
```

### 5.2 Training Script

**`ml/scripts/train_phase1.py`:**
1. Loads train/val JSONL splits.
2. Builds label and metric ID mappings.
3. Loads `indobenchmark/indobert-base-p1` from HuggingFace (cached after first download).
4. Constructs the classification head (linear layer on top of BERT hidden states + metric + prior label embeddings).
5. Fine-tunes with `AdamW`, cross-entropy loss, and early stopping on validation F1.
6. Saves the best checkpoint as `ml/models/phase1_indobert.pt`.

**Supporting scripts:**

| Script | Purpose |
|---|---|
| `data_prep/generate_actions.py` | Synthetic action command examples |
| `data_prep/generate_anatomical.py` | Synthetic anatomical modifier examples |
| `data_prep/generate_metrics.py` | Synthetic metric keyword examples |
| `data_prep/generate_p1f.py` | Sentence-context examples |
| `consolidate_and_split.py` | Merge all categories → train/val/test JSONL |
| `validate_dataset.py` | Label distribution, class balance, duplicate detection |
| `inject_state_conditioning.py` | Retroactively add `active_metric` / `prior_labels` to older examples |
| `evaluate_models.py` | Evaluate PyTorch model; print per-class report |
| `stt_normalizer.py` | Standalone normalization for offline data preprocessing |

### 5.3 CoreML Export

**`ml/scripts/coreml_export.py`:**
1. Reconstruct model architecture; load weights from `phase1_indobert.pt`.
2. Trace with `torch.jit.trace` using representative sample inputs.
3. Convert with `coremltools.convert(...)` targeting iOS 16+.
4. Apply int8 weight quantization via `coremltools.optimize`.
5. Save as `ml/models/Phase1Tokenizer.mlmodel`.
6. Deploy to `PeriodontalCharting/AI/VoiceTokenizerModel.mlmodel`.

**`ml/scripts/evaluate_coreml.py`** / **`evaluate_coreml_accuracy.py`** — Evaluate the CoreML model on the test set to verify parity with the PyTorch checkpoint.

---

## 6. Evaluation Results

Held-out test set: **9,192 word-level examples**. Results are identical between the PyTorch checkpoint and the exported CoreML model.

### Overall Metrics

| Metric | Score |
|---|---|
| **Accuracy** | **99.43%** |
| **Precision (weighted avg)** | 99.44% |
| **Recall (weighted avg)** | 99.43% |
| **F1 Score (weighted avg)** | **99.43%** |

### Per-Class Breakdown

| Label | Precision | Recall | F1 | Support |
|---|---|---|---|---|
| `NUMBER` | 1.00 | 1.00 | 1.00 | 1,424 |
| `TOOTH_MARKER` | 0.99 | 1.00 | 1.00 | 538 |
| `TOOTH_ID` | 1.00 | 1.00 | 1.00 | 1,814 |
| `METRIC_PD` | 1.00 | 1.00 | 1.00 | 222 |
| `METRIC_GM_NEG` | 1.00 | 1.00 | 1.00 | 251 |
| `METRIC_GM_POS` | 0.98 | 1.00 | 0.99 | 54 |
| `METRIC_BOP` | 0.99 | 0.99 | 0.99 | 166 |
| `METRIC_PLAQUE` | 1.00 | 1.00 | 1.00 | 41 |
| `METRIC_MOBILITY` | 1.00 | 1.00 | 1.00 | 191 |
| `METRIC_FURCATION` | 1.00 | 0.99 | 1.00 | 105 |
| `METRIC_IMPLANT` | 1.00 | 1.00 | 1.00 | 24 |
| `ANAT_MESIOBUCCAL` | 0.97 | 1.00 | 0.99 | 36 |
| `ANAT_DISTOBUCCAL` | 1.00 | 1.00 | 1.00 | 74 |
| `ANAT_MIDBUCCAL` | 1.00 | 1.00 | 1.00 | 100 |
| `ANAT_MESIOPALATAL` | 1.00 | 1.00 | 1.00 | 90 |
| `ANAT_DISTOPALATAL` | 1.00 | 1.00 | 1.00 | 84 |
| `ANAT_MIDPALATAL` | 1.00 | 0.96 | 0.98 | 55 |
| `ANAT_MESIOLINGUAL` | 1.00 | 1.00 | 1.00 | 37 |
| `ANAT_DISTOLINGUAL` | 1.00 | 1.00 | 1.00 | 208 |
| `ANAT_MIDLINGUAL` | 1.00 | 0.99 | 1.00 | 105 |
| `ANAT_MESIOLABIAL` | 1.00 | 1.00 | 1.00 | 224 |
| `ANAT_DISTOLABIAL` | 0.97 | 1.00 | 0.99 | 36 |
| `ANAT_MIDLABIAL` | 0.98 | 0.99 | 0.99 | 149 |
| `ANAT_MESIAL` | 1.00 | 0.98 | 0.99 | 63 |
| `ANAT_DISTAL` | 1.00 | 1.00 | 1.00 | 95 |
| `ANAT_BUCCAL` | 0.98 | 0.95 | 0.97 | 64 |
| `ANAT_LINGUAL` | 0.97 | 0.97 | 0.97 | 35 |
| `ANAT_PALATAL` | 1.00 | 0.99 | 0.99 | 71 |
| `ANAT_LABIAL` | 1.00 | 1.00 | 1.00 | 213 |
| `ACTION_COMMIT` | 0.99 | 0.99 | 0.99 | 198 |
| `ACTION_MISSING` | 0.99 | 0.98 | 0.99 | 252 |
| `ACTION_FROM` | 0.99 | 1.00 | 1.00 | 163 |
| `ACTION_UNTIL` | 0.99 | 1.00 | 0.99 | 293 |
| `ACTION_AT` | 0.99 | 0.98 | 0.98 | 222 |
| `ACTION_ALL` | 1.00 | 0.98 | 0.99 | 110 |
| `JAW_UPPER` | 0.97 | 1.00 | 0.99 | 70 |
| `JAW_LOWER` | 0.91 | 1.00 | 0.95 | 31 |
| `SIGN_MINUS` | 1.00 | 0.99 | 0.99 | 68 |
| `SEPARATOR` | 1.00 | 0.98 | 0.99 | 46 |
| `FILLER` | 0.98 | 0.98 | 0.98 | 1,170 |

> [!NOTE]
> `JAW_LOWER` (F1 0.95) has the lowest score due to only 31 test examples — a small, rarely-spoken class. `ANAT_BUCCAL` (F1 0.97) has slightly lower recall because bare `"bukal"` is genuinely ambiguous without context in some dictation styles. Both are acceptable for clinical use.

### Diagnostic Tools

| Script | Purpose |
|---|---|
| `ml/scripts/dump_preds.py` | Run the model on a raw transcript; print per-word predictions vs. ground truth |
| `ml/scripts/simulate_streaming_phase1.py` | Simulate live word-by-word tokenization showing state evolution |
| `ml/scripts/parity_check.py` | Compare PyTorch vs. CoreML predictions word-by-word |
| `ml/scripts/check_final_accuracy.py` | Final accuracy check on the full test split |

---

## 7. Phase 2 — TinyTransducer (Evaluated & Abandoned)

### 7.1 Architecture

A custom small seq2seq Transformer (`TinyTransducer`) was trained as an ML-based Phase 2 replacement for `VoiceCommandParser`. The model takes typed Phase 1 token segments and produces a linear output token sequence encoding `AnnotationCommand` mutations.

**Input:** Cursor prefix tokens (current tooth, aspect, metric, traversal direction) concatenated with the Phase 1 typed token stream for the current commit segment, padded to 64 tokens.

**Output:** Flat token sequence representing commands:
```
OP_PD | OUT_T16 | OUT_OUTER | OUT_3 , OUT_4 , OUT_3 EOS
```

**Architecture:** 4-layer Transformer encoder-decoder, 64-dim embeddings, 4 attention heads, ~800K–1.5M parameters. Saved models: `ml/models/phase2_transducer.pt` (~6.6 MB PyTorch), `ml/models/Phase2Parser.mlmodel` (~4.1 MB CoreML).

**Training:** Commit-level segment pairs from existing test transcripts, augmented with synthetic examples from the rule-based VoiceCommandParser oracle. 20 epochs, `CrossEntropyLoss`, `AdamW`. Scripts: `ml/scripts/train_phase2.py`, `ml/scripts/evaluate_models.py`.

### 7.2 Performance

Evaluated against **284 held-out commit segments**:

| Metric | Score |
|---|---|
| **Exact Match Accuracy** | **~54–60%** |
| **Token Error Rate (TER)** | **~25–29%** |

The gap between exact match and TER indicates partial correctness — wrong tooth numbers or off-by-one values rather than structurally malformed output.

### 7.3 Failure Analysis

Three root causes were identified:

**1. Output syntax hallucinations.** The model occasionally generates outputs with unclosed brackets, missing separators, or spurious tokens. The output grammar is simple, but seq2seq models have no native concept of balance constraints. An FSA logit mask could prevent structurally malformed outputs but cannot eliminate semantically wrong ones (wrong tooth, wrong value).

**2. Medical determinism required.** A 54% exact-match rate means 46% of commands are wrong. In a clinical charting context this is unacceptable — a single wrong tooth-pocket depth entered into a patient record has direct clinical consequences. Probabilistic inference at the command level cannot be tolerated.

**3. Complex multi-tooth and long-range sequences.** TER climbs sharply on compound segments (multiple teeth, ranges, post-targeting lists). The model cannot replicate the explicit cursor tracking, `activeSelection`, and `flushNumbers` logic of the rule-based parser. These are inherently stateful operations that a sequence model struggles to generalize.

### 7.4 Decision: Retain Swift Parser

**Phase 2 ML is abandoned. The rule-based `VoiceCommandParser` is the permanent Phase 2 component.**

The key insight is that Phase 1's 99.43% F1 makes the typed token stream arriving at Phase 2 nearly perfect. Residual errors in command generation are deterministic edge cases that can be fixed with additional parser rules — not a modeling problem that benefits from probabilistic inference.

> [!IMPORTANT]
> `Phase2Parser.mlmodel` and `phase2_transducer.pt` in `ml/models/` are retained for reference but are **not integrated into the app**. Do not add a Swift integration for Phase 2 ML.

---

## 8. Live STT Integration Status

| Layer | Status |
|---|---|
| **Silero VAD** (`SileroVADEngine`) | ✅ Complete — integrated in `TranscriptionEngine` |
| **WhisperKit STT** (`TranscriptionEngine`) | ✅ Complete — loads and transcribes via `TranscriptionViewModel` |
| **Clinical vocabulary biasing** (`ClinicalConfig` + `SequenceBiasFilter`) | ✅ Complete — applied at load time in `TranscriptionEngine` |
| **ML Tokenizer** (`MLVoiceTokenizer` + `TokenizerManager`) | ✅ Complete — primary tokenizer path in the app |
| **Swift Parser** (`VoiceCommandParser`) | ✅ Complete — deterministic Phase 2 |
| **Live transcript → chart annotation wiring** | ⏳ Pending — connect `TranscriptionViewModel` output to `AIVoiceViewModel` |

The pending step is to route confirmed segment text from `TranscriptionViewModel`'s live stream callback into `AIVoiceViewModel.liveTranscription`, replacing the simulation loop with real dictation. `TokenizerManager` and `VoiceCommandParser` are already in place; only the data flow between the two view-models needs to be established.
