# Periodontal Charting — Speech-to-Text (STT) Engine

This document is the technical reference for the **Speech-to-Text (STT)** pipeline in the Periodontal Charting app. 

For the Target Speaker Extraction layer that sits before this pipeline, see [TSE_documentation.md](TSE_documentation.md).

---

## Table of Contents
1. [Overview](#1-overview)
2. [Files](#2-files)
3. [Audio Pipeline & Dynamic VAD](#3-audio-pipeline--dynamic-vad)
4. [Acoustic Model (Wav2Vec2)](#4-acoustic-model-wav2vec2)
5. [Constrained CTC Decoding](#5-constrained-ctc-decoding)
6. [Prefix Trie](#6-prefix-trie)
7. [Canonical Mapping & Acoustic Variants](#7-canonical-mapping--acoustic-variants)
8. [Acoustic Cost Rejection](#8-acoustic-cost-rejection)
9. [Contextual Phonetic Recovery](#9-contextual-phonetic-recovery)
10. [Pre-processing Pipeline](#10-pre-processing-pipeline-new-tokenizer-passes)
11. [Live Pipeline Flow](#11-live-pipeline-flow)
12. [Offline / File Simulation](#12-offline--file-simulation)
13. [Asset Reference](#13-asset-reference)
14. [Known Limitations & Design Notes](#14-known-limitations--design-notes)

---

## 1. Overview

The STT engine is fully offline and runs on-device via CoreML. It is optimized for Indonesian clinical dental terminology. 

The architecture is built on three pillars:
- **Wav2Vec2** (Acoustic Model)
- **Constrained CTC Decoding** (via PrefixTrie)
- **Energy-based VAD**

**Pipeline Flow:**
`mic` → `HighPassFilter` → `AutoGain` → `512-sample chunks` → `energy VAD` → `commit` → `Z-score normalize` → `Wav2Vec2 inference` → `CTC decode` → `canonical mapping` → `text`

**Integration in the App:**
`Wav2VecViewModel` hands confirmed transcripts to `AIVoiceViewModel` via `onConfirmedTranscript`. The gate and extractor (`SpeakerGateService` + `TSEEngine`) run between raw audio and the decoder.

---

## 2. Files

| File | Responsibility |
|---|---|
| `Wav2VecEngine.swift` | CoreML wrapper, `loadModel()`, `predict(audioData:isLivePreview:)` |
| `Wav2VecViewModel.swift` | Live pipeline orchestrator (VAD, commit logic, gate integration, parser callbacks) |
| `Wav2VecAudioCapture.swift` | AVFoundation mic + 16 kHz resampler + signal conditioning + Z-score normalization |
| `CTCDecoder.swift` | Constrained beam search + acoustic cost rejection + canonical mapping |
| `PrefixTrie.swift` | Clinical vocabulary prefix trie for decoding constraint |
| `Audio/Signal/AutoGain.swift` | Adaptive gain stage |
| `Audio/Signal/HighPassFilter.swift` | 80 Hz IIR biquad high-pass filter |

---

## 3. Audio Pipeline & Dynamic VAD

The application records raw 16 kHz PCM audio via `AVAudioEngine`. Buffers are captured in **512-sample chunks** (~32 ms at 16 kHz), passed through `HighPassFilter` (80 Hz IIR biquad) and `AutoGain` (target RMS 0.1, ~1.5 s time constant), and accumulated in `Wav2VecViewModel.streamingBuffer`.

### Why Arbitrary Chunking Failed
In previous iterations, the code forced a "Soft Commit" every 3 to 8 seconds to prevent buffer bloat. This failed because Wav2Vec2 is a bidirectional transformer — severing audio at arbitrary timeframes destroyed the acoustic left-context the network needed to predict the first phoneme of the next word.

### The Solution: Rolling Percentile VAD
Instead of arbitrary fixed thresholds, the engine uses a **rolling percentile speech detector** over a 4-second history window. Speech detection requires **both** conditions to hold simultaneously:

1. **Level check:** `rms > noiseFloor × 3.0` (buffer is louder than the floor by the required multiple)
2. **Contrast check:** `loud / noiseFloor ≥ minDynamicRange` (the window has sufficient dynamic range — flat noise fails this)

The 20th-percentile of the rolling window is the noise floor; the 90th-percentile is the loud level. During the first 1.5 s (warm-up), a simpler absolute floor is used instead of percentiles.

**Why percentiles over a decaying baseline:** The old system used a one-way baseline that only updated while the detector believed the room was quiet. Once any noise exceeded the baseline, it froze at its old low value — a latch that could not recover within a session. A percentile window always tracks: the floor follows the room both up and down.

### Commit Trigger — Dynamic Silence Threshold
When the VAD detects silence, it waits for a required number of consecutive silence frames before committing the buffer. This threshold tightens as the buffer grows to prevent the decoder from exceeding CoreML's 60-second limit:

| Buffer length | Required silence frames | Approx. silence duration |
|---|---|---|
| 0–15 s | 15 frames | ~480 ms |
| 15–30 s | 10 frames | ~320 ms |
| 30–45 s | 5 frames | ~160 ms |
| 45–55 s | 3 frames | ~96 ms |
| > 55 s | 0 frames | Force-commit immediately |

The buffer is only split between words (VAD fires on silence), so the transformer context is never severed mid-phoneme. The force-commit at 55 s guarantees the buffer never approaches the 60-second CoreML limit.

---

## 4. Acoustic Model (Wav2Vec2)

The engine utilizes `Wav2Vec2_Indonesian_FP16.mlpackage` (compiled to `.mlmodelc` at first launch). 
- **Input:** A 1D Float32 MultiArray representing the raw audio waveform at 16,000 Hz, padded to 1-second bucket boundaries with white noise (not zeros — zeros create a Z-score flatline at boundaries that drops phonemes).
- **Output:** A 3D Float32 MultiArray (`[1, sequence_length, vocab_size]`) containing raw logit probabilities for each token in the Indonesian alphabet at every 20 ms timestep.
- **Compute units:** `.cpuAndGPU` — measured to be faster than ANE for this model on Apple Silicon.

Because it operates at FP16, it is highly optimized for GPU inference, providing real-time inference speeds well below 0.1x RTF on modern iPads.

### Input Bucketing
Audio is zero-padded to 1-second bucket boundaries (16,000-sample multiples) before inference. This keeps CoreML from allocating a new Metal buffer for every slightly different length, reducing GPU memory fragmentation.

### Padding with White Noise
Trailing pad samples use `Float.random(in: -1.732...1.732)` (uniform distribution, variance = 1.0, matching Z-score normalization). Padding with zeros creates a "flatline cliff" — a region with exactly zero variance — that corrupts the CNN's causal receptive field and drops phonemes at boundaries.

### Z-score Normalization
Applied by `Wav2VecAudioCapture.normalizeAudio(data:)` using `vDSP_normalize` (hardware-accelerated). Normalization happens AFTER extraction (TSE), not before: the extractor needs the pre-normalization energy distribution to identify speaker segments.

---

## 5. Constrained CTC Decoding

**Algorithm:** Prefix Trie-constrained CTC beam search. At each timestep, only characters that form a valid prefix in the `PrefixTrie` are kept; all others have their probability forced to -∞. 

### Beam Search Parameters

- **Beam width:** 40 — wider than standard to allow weak anatomy candidates to survive long enough to receive the LM boost.
- **Character prune threshold:** `-15.0` (relaxed from `-10.0`) — prevents the decoder from culling correct anatomy branches before they can build sufficient probability.
- **Log-softmax:** Applied to logits before beam search using numerically stable formulation (subtract max before exponentiating).
- **Blank token:** `[PAD]` index (usually 27). Space token: `|` (mapped to space character).

### Shallow Fusion Language Model Boost

The Indonesian acoustic model is heavily biased toward numeric tokens over clinical anatomies — `lima` is acoustically similar to `lingual`, `dua` to `bukal`. To correct this without retraining:

- When a beam path **completes a recognised anatomy word** (e.g., `lingual`, `bukal`, `palatal`), a **`−3.0` log-probability bonus** is injected directly into that beam's score.
- This steers the search toward clinical terms using a lightweight word-level signal rather than a full language model.
- The relaxed prune threshold (`-15.0`) ensures anatomy candidates survive long enough to receive this bonus.

Without these two settings together, the beam search pruned the `l-i-n-g-u-a-l` character sequence before it could accumulate enough probability to compete with numerics.

### Implicit Space Injection
When a new character would violate the trie but the last completed word is valid, the decoder tries injecting a space first. Injected spaces carry a 2.0 log-probability penalty to discourage over-eager word splitting.

### Partial Word Handling
At decoding end, if the final word is not a complete dictionary entry, it is dropped (hard commit). This prevents partial words from reaching the parser and triggering spurious annotations.

> [!NOTE]
> **Beam width rationale:** The beam width was increased to 40 to allow numeric and anatomy paths to survive pruning and receive their respective bonuses. With the acoustic cost filter properly normalized by frames spanned, wider beams no longer result in runaway hallucinations.

---

## 6. Prefix Trie

- Built at launch from `lexicon.txt` (clinical vocabulary). All canonical-mapping variants are also added to the trie so they are decodable.
- Supports `isValidPrefix(sequence:)` — used during CTC decoding to prune characters.
- Supports `isWord(_:)` — used to validate completed words at beam end.
- `lexicon.txt` format: one word per line, tab-separated phoneme string (e.g., `mesio\tm e s i o`). Only the word (before the tab) is used.

---

## 7. Canonical Mapping & Acoustic Variants

- `canonical_mapping.json` maps acoustic mispronunciations to canonical terms. Example: `{"misiobocal": "mesiobukal", "nggak": "gak"}`.
- Applied as a regex word-boundary replacement after decoding, longest match first.
- **Two-Pass Loop:** The mapping routine runs in a 2-pass loop to resolve cascaded phonetic combinations (e.g., `diso lima` → `disto lima` → `distolingual`).
- Variants are also added to `lexicon.txt` so the prefix trie can construct them.

> [!IMPORTANT]
> **Maintenance rule:** Do NOT write dynamic code to strip/patch words. Instead, observe the raw transcript, identify the specific acoustic variant the model heard, and add it explicitly to both `canonical_mapping.json` and `lexicon.txt`.

---

## 8. Acoustic Cost Rejection

The engine enforces a strict cutoff: if `costPerFrame > 2.0`, the word is classified as "Non-Speech Noise" and is silently discarded. Structural modifiers (`semua`, `sampai`, `hingga`, etc.) that could trigger catastrophic chart mutations (e.g., mass-assigning all teeth) use a much stricter threshold of **0.2** to prevent hallucinated structural commands from reaching the parser.

---

## 9. Contextual Phonetic Recovery

For cases where acoustic ambiguity is irresolvable at the decoder level, `StatefulParser` includes a safety net. When the parser is in a state that expects an anatomy token — for example, after `.action(.from)` with `isWaitingForRangeEnd == true`, or immediately after a directional keyword — and receives a numeric token that would be clinically invalid at that position, it maps specific numbers to their acoustically similar anatomy counterparts:

| Mis-heard numeric | Recovered anatomy | Why |
|---|---|---|
| `5` / `lima` | `lingual` | `l-i-` onset sounds similar |
| `2` / `dua` | `bukal` | `b-u-` onset sounds similar |

**Context-gated:** Recovery only fires when numbers are clinically invalid in that parser state. Valid numeric input (probing depths, gingival margins) is never silently converted. The check is conservative: the parser must be expecting anatomy (not values) for recovery to trigger.

---

## 10. Pre-processing Pipeline (New Tokenizer Passes)

Before the main token-matching loop, `VoiceTokenizer+Parsing.swift` applies several pre-processing passes to handle STT transcription artefacts. These run in order:

### 10.1 String-level normalization (before word splitting)

| Rule | Example | Result |
|---|---|---|
| Spaced-digit fix (regex) | `gigi 1 8` | `gigi 18` — joins digits after `gigi`, `sampai`, `ke` |
| Decimal between digits | `1.5` | `1 5` — treats as two separate values |
| `.` or `\n` | `.` | `_sep_` — hard sentence boundary |
| `,` | `,` | ` , ` — soft list separator |
| `{...}` | `{correction}` | ` ` — strips correction markers |
| `mesiobukal` | `mesiobukal` | `mesio bukal` — splits fused compound anatomy |
| `b.o.p` / `b o p` | `b.o.p` | `bop` — BOP aliases |

### 10.2 Word-level spell correction

Applied after splitting into words. Maps known STT mispronunciations to canonical forms (e.g. `misio` → `mesio`, `bocal` → `bukal`, `pocket` → `poket`). See §3 of the original vocabulary for the full list.

### 10.3 Fused directional-compound splitter

Handles cases where the STT engine glues a directional stem and site into one token with a fuzzy site suffix (e.g., `mesiyobukal`, `distobuqal`). For any token starting with `m` or `d` that ends with a recognisable site suffix (`bukal`, `lingual`, `palatal` and variants), the suffix is peeled off and the remaining prefix is left for the directional stem recovery pass.

### 10.4 Directional stem recovery (position-based)

Whisper/Wav2Vec mangles the directional stem (`disto`/`mesio`) into an open-ended set of mis-hears (`di situ`, `justru`, `stok`, `misi`, `mili`, etc.) while the site word after it stays reliable. Rather than enumerate every variant, the pass uses **position**: any word immediately before a site word (`bukal`, `lingual`, `palatal`) that the tokenizer does not otherwise recognise is assumed to be a mis-heard stem. Direction is recovered by leading sound — `m`-initial → `mesio`, otherwise → `disto`.

A leading fragment (`di`, `the`, `de`) immediately before the junk stem is also consumed so it does not emit a spurious `at`-action token.

### 10.5 `di bop` → `disto bukal` collapse

The `disto bukal` phrase is sometimes acoustically compressed into a `<di-fragment> <bop-fragment>` pair (`di bop`, `di bob`, `the bop`, etc.). This is collapsed to `.anatomy(.distoBuccal)` before the generic `di` → at-action and `bop` → bleeding rules can fire and misroute it.

### 10.6 3+-digit value split

If the acoustic model concatenates a spoken run of single-digit values into one number (`333` for `3 3 3`), any integer ≥ 100 is split digit-by-digit into individual `.number` tokens.

### 10.7 Doubled-digit artifact guard

A "doubled digit" (11, 22, 33, …, 99) arriving immediately after a value token is almost always the STT repeating the value stream (e.g., `2 2 2` → `222 22`), not a real tooth jump. It is treated as two repeated values rather than a tooth identifier.

---

## 11. Live Pipeline Flow

```text
Mic audio (hardware sample rate)
    │
    ▼ AVAudioConverter → 16 kHz mono Float32
    │
    ▼ HighPassFilter (IIR biquad, 80 Hz)
    ▼ AutoGain (adaptive, 1.5 s time constant)
    │
    ▼ 512-sample aligned chunks → processAudioChunk()
    │
    ├── [ongoing speech] Intermediate preview every 8,000 new samples
    │       → Z-score normalize → Wav2VecEngine.predict(isLivePreview: true)
    │       → onLiveTranscript (display only, not parsed)
    │
    └── [silence detected] commit(chunk) → chained Task
            │
            ▼ SpeakerGateService.gatedAudio() [detached]
            │   ECAPA-TDNN per span + BSRNN extraction if routed
            │   Returns nil (withhold) or gated [Float]
            │
            ▼ SessionRecorder.append(raw:gated:)
            │
            ▼ Z-score normalize
            ▼ Wav2VecEngine.predict(isLivePreview: false)
            │
            ▼ onConfirmedTranscript → AIVoiceViewModel
                → TokenizerManager → StatefulParser → ChartProcessor
```

---

## 12. Offline / File Simulation

- `startSimulation(audio:speedMultiplier:)` feeds a recorded `.m4a` clip through the live pipeline at a configurable pace.
- `speedMultiplier >= 100` runs flat-out (no `Task.sleep`), useful for batch testing.
- Speaker gate is disabled for file simulation (gate is `nil`; `gatedChunk` passes chunks through untouched).
- `Wav2VecAudioCapture.readAudioFile(url:)` reads `.m4a` files via `AVAssetReader`, decoding to 16 kHz Float32.
- `conditionAudio(buffer:inout)` and `resetConditioning()` allow offline test runners to apply the same signal conditioning as the live path.

---

## 13. Asset Reference

| File | Location | Used by |
|---|---|---|
| `Wav2Vec2_Indonesian_FP16.mlpackage` | `AI/Wav2Vec_STT/` | `Wav2VecEngine.loadModel()` |
| `vocab.json` | `AI/Wav2Vec_STT/` | `CTCDecoder` — character index mapping |
| `lexicon.txt` | `AI/Wav2Vec_STT/` | `PrefixTrie` — clinical vocabulary |
| `canonical_mapping.json` | `AI/Wav2Vec_STT/` | `CTCDecoder` — acoustic variant mapping |
| `canonical_mapping.json.patch` | `AI/Wav2Vec_STT/` | Development artifact — diff for mapping updates |

> [!NOTE]
> All assets in `AI/` are gitignored. On a fresh clone, place these files manually before first run.

---

## 14. Known Limitations & Design Notes

1. **Contextual Phonetic Recovery.** The acoustic model exhibits a massive bias toward numeric tokens (e.g., `lima`, `dua`) over phonetically similar clinical anatomies (e.g., `lingual`, `bukal`). Even with character pruning thresholds relaxed (`-15.0`) and LM boosts applied, a direct substitution often prevails acoustically. To defend against this, `StatefulParser` uses a contextual recovery step: if a number (`5` or `2`) is received *exactly* when the parsing state strictly expects an anatomy token, it safely recovers them to `lingual` and `bukal`.

2. **Beam width without language model.** Without a dedicated N-gram LM (e.g. KenLM), increasing beam width beyond 40 degrades accuracy by allowing the acoustic model to hallucinate longer confident-sounding garbage sequences. A future integration of KenLM or a lightweight bigram model would enable wider beams.

3. **No cross-chunk context.** Wav2Vec2 is a bidirectional transformer. Each committed chunk is decoded independently — there is no mechanism to pass acoustic context across commit boundaries. The energy VAD is tuned to avoid splitting words (by waiting for genuine silence), but rapid speech near a commit boundary can cause dropped phonemes at chunk edges.

4. **Z-score normalization is per-chunk.** A chunk that is uniformly quiet normalizes up its own noise floor. The `AutoGain` pre-stage mitigates this by ensuring consistent speaking levels before VAD fires, reducing the probability of a quiet chunk being Z-scored into noise amplification.

5. **Hallucination on non-speech audio.** Metal tools clinking, suction tubes, and ambient noise can trigger the energy VAD and produce a committed chunk. The trie forces the model to output something from the clinical vocabulary; `Acoustic Cost Rejection` is the primary defense against these hallucinations being parsed as real commands. The default acoustic cost threshold is `maxCostPerFrame = 2.0` (see `CTCDecoder.swift`); destructive structural modifiers are held to the stricter threshold of 0.2.

**Document Last Updated**: 2026-08-20.
