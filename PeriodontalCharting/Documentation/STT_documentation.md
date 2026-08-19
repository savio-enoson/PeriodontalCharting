# Periodontal Charting — Speech-to-Text (STT) Engine

This document is the technical reference for the **Speech-to-Text (STT)** pipeline in the Periodontal Charting app. 

For the Target Speaker Extraction layer that sits before this pipeline, see [TSE_documentation.md](TSE_documentation.md).

---

## Table of Contents
1. [Overview](#1-overview)
2. [Files](#2-files)
3. [Audio Capture & Signal Conditioning](#3-audio-capture--signal-conditioning)
4. [Energy-Based VAD & Commit Logic](#4-energy-based-vad--commit-logic)
5. [Acoustic Model (Wav2Vec2)](#5-acoustic-model-wav2vec2)
6. [Constrained CTC Decoding](#6-constrained-ctc-decoding)
7. [Prefix Trie](#7-prefix-trie)
8. [Canonical Mapping & Acoustic Variants](#8-canonical-mapping--acoustic-variants)
9. [Acoustic Cost Rejection](#9-acoustic-cost-rejection)
10. [Live Pipeline Flow](#10-live-pipeline-flow)
11. [Offline / File Simulation](#11-offline--file-simulation)
12. [Asset Reference](#12-asset-reference)
13. [Known Limitations & Design Notes](#13-known-limitations--design-notes)

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

## 3. Audio Capture & Signal Conditioning

### Capture
- **AVAudioEngine** is used with `AVAudioConverter` resampling to 16 kHz mono Float32.
- Output is chunked to exact multiples of 512 samples via an alignment buffer.
- Audio level (dB RMS) is tracked via `vDSP_rmsqv` for the UI level meter.

### Signal Conditioning
Conditioning is applied in order:
1. **`HighPassFilter`** — 80 Hz IIR biquad. Removes sub-bass rumble from suction tubes, HVAC, and footsteps. Carries IIR state across buffers; `reset()` is called at session start.
2. **`AutoGain`** — Adaptive multiplier. 
   - `targetRMS = 0.1`
   - `maxGain = 12.0x`, `minGain = 0.4x`
   - Adapts only on frames above `silenceRMS = 0.004` (anti-pumping).
   - Smoothing constant is 0.08 per buffer (~1.5 s time constant).
   - Soft peak limiter at 0.95 to prevent clipping. 
   - *Note:* DOES NOT affect ECAPA speaker distances (ECAPA normalizes mean/variance per utterance).

> [!NOTE]
> **Why conditioning matters:** Measured on synthetic dictation, conditioning increases signal-to-noise contrast 2.5x (6.1x → 15.4x at RMS 0.03). Without conditioning, the energy segmenter's `noiseFloor * 3` threshold is elevated by low-frequency rumble, causing quiet clinicians to fail to trigger speech detection.

**Offline Files:**
Conditioning is also applied to offline files. `conditionAudio(buffer:inout)` exposes the same pipeline for offline regression tests, ensuring test conditions match live conditions.

---

## 4. Energy-Based VAD & Commit Logic

### Baseline Tracking
A running `baselineRMS` adapts at 1% per silent frame. 
- Speech threshold: `max(0.001, baselineRMS * 2.0)`
- `hasStartedSpeaking` gates accumulation — 1 second of pre-roll is kept before speech is detected (ensures the first word is captured).

### Dynamic Silence Timeout
The timeout tightens as the buffer grows to prevent CoreML OOM:

| Buffer length | Required silence frames | Silence duration |
|---|---|---|
| 0–15 s | 15 frames (× 512/16000) | ~0.48 s |
| 15–30 s | 10 frames | ~0.32 s |
| 30–45 s | 5 frames | ~0.16 s |
| 45–55 s | 3 frames | ~0.096 s |
| > 55 s | 0 (force commit immediately) | — |

### Commit Chaining
Commits are queued as a chained `Task` — each awaits its predecessor. This guarantees `StatefulParser` receives chunks in capture order. This is crucial because the parser is stateful; an out-of-order chunk misplaces not just one word but every value after it.

### Intermediate Preview
While speech is ongoing, a preview decode runs every ~0.5 s (every 8,000 new samples) over the growing `streamingBuffer`. Preview decodes are NOT gated (too expensive during active speech) and do NOT feed the parser — they only trigger `onLiveTranscript` for display.

---

## 5. Acoustic Model (Wav2Vec2)

**Model:** `Wav2Vec2_Indonesian_FP16.mlpackage` — Fine-tuned Wav2Vec2 model in FP16 precision.
- **Input:** 1D Float32 array, 16 kHz mono, Z-score normalized (zero mean, unit variance).
- **Output:** `[1, time_steps, vocab_size]` — raw logit probabilities per character at every 20 ms timestep (stride 320 samples).
- `computeUnits = .cpuAndGPU` — leverages GPU for FP16 matrix ops.

### Input Bucketing
Audio is zero-padded to 1-second bucket boundaries (16,000-sample multiples) before inference. This keeps CoreML from allocating a new Metal buffer for every slightly different length, reducing GPU memory fragmentation.

### Padding with White Noise
Trailing pad samples use `Float.random(in: -1.732...1.732)` (uniform distribution, variance = 1.0, matching Z-score normalization). Padding with zeros creates a "flatline cliff" — a region with exactly zero variance — that corrupts the CNN's causal receptive field and drops phonemes at boundaries.

### Z-score Normalization
Applied by `Wav2VecAudioCapture.normalizeAudio(data:)` using `vDSP_normalize` (hardware-accelerated). Normalization happens AFTER extraction (TSE), not before: the extractor needs the pre-normalization energy distribution to identify speaker segments.

---

## 6. Constrained CTC Decoding

**Algorithm:** Prefix Trie-constrained CTC beam search. At each timestep, only characters that form a valid prefix in the `PrefixTrie` are kept; all others have their probability forced to -∞. Beam width = 40.

- **Log-softmax:** Applied to logits before beam search using numerically stable formulation (subtract max before exponentiating).
- **Blank token:** `[PAD]` index (usually 27). Space token: `|` (mapped to space character).
- **Character Pruning:** Phonetic character branches with log-probs below `-15.0` are pruned. This relaxed threshold allows weaker phonetic branches (like `lingual`) to survive long enough to complete and receive their word-level bonuses.

### Implicit Space Injection
When a new character would violate the trie but the last completed word is valid, the decoder tries injecting a space first. Injected spaces carry a 2.0 log-probability penalty to discourage over-eager word splitting.

### Shallow Fusion LM Boost
When a valid word is completed, the decoder checks if it is a clinical anatomy term (e.g., `lingual`, `mesio`, `bukal`). If so, a massive log-probability bonus (`-3.0`) is subtracted from its cost, actively steering the acoustic beam search toward these crucial structural anchors during ambiguous audio segments.

### Partial Word Handling
At decoding end, if the final word is not a complete dictionary entry, it is dropped (hard commit). This prevents partial words from reaching the parser and triggering spurious annotations.

> [!NOTE]
> **Beam width rationale:** The beam width was increased to 40 to allow numeric and anatomy paths to survive pruning and receive their respective bonuses. With the acoustic cost filter properly normalized by frames spanned, wider beams no longer result in runaway hallucinations.

---

## 7. Prefix Trie

- Built at launch from `lexicon.txt` (clinical vocabulary). All canonical-mapping variants are also added to the trie so they are decodable.
- Supports `isValidPrefix(sequence:)` — used during CTC decoding to prune characters.
- Supports `isWord(_:)` — used to validate completed words at beam end.
- `lexicon.txt` format: one word per line, tab-separated phoneme string (e.g., `mesio\tm e s i o`). Only the word (before the tab) is used.

---

## 8. Canonical Mapping & Acoustic Variants

- `canonical_mapping.json` maps acoustic mispronunciations to canonical terms. Example: `{"misiobocal": "mesiobukal", "nggak": "gak"}`.
- Applied as a regex word-boundary replacement after decoding, longest match first.
- **Two-Pass Loop:** The mapping routine runs in a 2-pass loop to resolve cascaded phonetic combinations (e.g., `diso lima` → `disto lima` → `distolingual`).
- Variants are also added to `lexicon.txt` so the prefix trie can construct them.

> [!IMPORTANT]
> **Maintenance rule:** Do NOT write dynamic code to strip/patch words. Instead, observe the raw transcript, identify the specific acoustic variant the model heard, and add it explicitly to both `canonical_mapping.json` and `lexicon.txt`.

---

## 9. Acoustic Cost Rejection

After decoding, each word is scored by its average acoustic cost over the audio frames it spanned: `costPerFrame = wordCost / framesSpanned`.
- **Default threshold:** `maxCostPerFrame = 2.0`. Words exceeding this are silently discarded. This is relaxed enough to allow muffled prefixes and low-confidence numbers to pass.
- **Strict threshold:** `0.2` for destructive structural modifiers: `semua`, `semuanya`, `seluruh`, `seluruhnya`, `sampai`, `hingga`, `tika`, `tike`. These words, if hallucinated, can apply a value to all 192 measurement sites or open a massive range. They must be clearly spoken and pass a highly stringent acoustic bar.
- Applied to both committed decodes and live preview decodes (so the UI never shows hallucinated words).

---

## 10. Live Pipeline Flow

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

## 11. Offline / File Simulation

- `startSimulation(audio:speedMultiplier:)` feeds a recorded `.m4a` clip through the live pipeline at a configurable pace.
- `speedMultiplier >= 100` runs flat-out (no `Task.sleep`), useful for batch testing.
- Speaker gate is disabled for file simulation (gate is `nil`; `gatedChunk` passes chunks through untouched).
- `Wav2VecAudioCapture.readAudioFile(url:)` reads `.m4a` files via `AVAssetReader`, decoding to 16 kHz Float32.
- `conditionAudio(buffer:inout)` and `resetConditioning()` allow offline test runners to apply the same signal conditioning as the live path.

---

## 12. Asset Reference

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

## 13. Known Limitations & Design Notes

1. **Contextual Phonetic Recovery.** The acoustic model exhibits a massive bias toward numeric tokens (e.g., `lima`, `dua`) over phonetically similar clinical anatomies (e.g., `lingual`, `bukal`). Even with character pruning thresholds relaxed (`-15.0`) and LM boosts applied, a direct substitution often prevails acoustically. To defend against this, `StatefulParser` uses a contextual recovery step: if a number (`5` or `2`) is received *exactly* when the parsing state strictly expects an anatomy token, it safely recovers them to `lingual` and `bukal`.

2. **Beam width without language model.** Without a dedicated N-gram LM (e.g. KenLM), increasing beam width beyond 40 degrades accuracy by allowing the acoustic model to hallucinate longer confident-sounding garbage sequences. A future integration of KenLM or a lightweight bigram model would enable wider beams.

3. **No cross-chunk context.** Wav2Vec2 is a bidirectional transformer. Each committed chunk is decoded independently — there is no mechanism to pass acoustic context across commit boundaries. The energy VAD is tuned to avoid splitting words (by waiting for genuine silence), but rapid speech near a commit boundary can cause dropped phonemes at chunk edges.

4. **Z-score normalization is per-chunk.** A chunk that is uniformly quiet normalizes up its own noise floor. The `AutoGain` pre-stage mitigates this by ensuring consistent speaking levels before VAD fires, reducing the probability of a quiet chunk being Z-scored into noise amplification.

5. **Hallucination on non-speech audio.** Metal tools clinking, suction tubes, and ambient noise can trigger the energy VAD and produce a committed chunk. The trie forces the model to output something from the clinical vocabulary; `Acoustic Cost Rejection` is the primary defense against these hallucinations being parsed as real commands. The acoustic cost threshold (3.0) was tuned empirically on captured sessions.
