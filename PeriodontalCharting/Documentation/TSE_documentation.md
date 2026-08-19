# Periodontal Charting — Target Speaker Extraction (TSE)

This document is the complete technical reference for the **Target Speaker Extraction (TSE)** pipeline in the Periodontal Charting app. TSE prevents ambient speech, assistant voices, and background noise from reaching the ASR model and polluting the periodontal chart.

For the STT layer that calls into this pipeline, see [STT_documentation.md](STT_documentation.md). For the file-by-file reference, see [frontend_guide.md](frontend_guide.md).

---

## Table of Contents

1. [Overview](#1-overview)
2. [Files](#2-files)
3. [Operating Modes](#3-operating-modes)
4. [Speaker Gate](#4-speaker-gate--ecapa-tdnn-identity-verification)
5. [Energy Span Segmentation](#5-energy-span-segmentation)
6. [Extractor Architecture](#6-extractor-architecture--bsrnn)
7. [Routing Decision](#7-routing-decision)
8. [Audio Rebuild](#8-audio-rebuild)
9. [Early Commit Integration](#9-early-commit-integration)
10. [Enrollment Pipeline](#10-enrollment-pipeline)
11. [GateStatus and Debug](#11-gatestatus-and-debug)
12. [Performance](#12-performance)
13. [Asset Reference](#13-asset-reference)
14. [Known Limitations](#14-known-limitations-and-caveats)

---

## 1. Overview

TSE solves a **two-decision problem**:

1. **Whose voice is this?** — the **Speaker Gate** (ECAPA-TDNN identity verification) answers per span.
2. **What does the ASR hear?** — the **BSRNN extractor** reshapes the audio so only the target speaker's signal remains.

The two decisions are deliberately separated. The gate runs on the raw (unmodified) audio so its verdict is not influenced by extraction. The extractor then runs on spans the gate marked as needing help (rejected spans, or all spans under `.everySpan` coverage).

**Where TSE sits in the live pipeline:**

```
Wav2VecViewModel.commit(chunk, isEarlyCommit:)
        |
        v
SpeakerGateService.gatedAudio(for: chunk, extractor: extractor)
  [implemented in TSERescue.swift]
        |
        +-- rescueSpans()             energy-based VAD -> speech span list
        |
        +-- for each span:
        |    SpeakerGate.classify()   ECAPA-TDNN identity check
        |    shouldExtract()?
        |    TargetSpeakerExtractor.extract()   BSRNN 6-model pipeline
        |
        +-- rebuild()                 splice extracted audio, silence rejects
        |
        v
Wav2VecEngine.predict()    transcribes gated audio only
```

**Gate fails open:** if the gate service is nil, not enrolled, or throws — the chunk passes through untouched. A broken gate must never silently stop transcription.

---

## 2. Files

### `Audio/TSE/`

| File | Responsibility |
|---|---|
| `TSEConfig.swift` | Architecture constants, `Mode` and `Coverage` enums, runtime settings, compute unit selection |
| `TSEEngine.swift` | `@MainActor @Observable` singleton — owns `TargetSpeakerExtractor?`, `prepare()`, `reprepare()`, `enrollmentAudio(from:)` |
| `TSEExtractor.swift` | `TargetSpeakerExtractor` — loads 6 Core ML models, `prepareEnrollment(_:)`, `extract(_:)` |
| `TSEFeatures.swift` | `TSESpectrogram` (STFT/iSTFT), `TSEKaldiFbank` (80-bin log-mel), both in Accelerate |
| `TSERescue.swift` | Extension on `SpeakerGateService`: `gatedAudio`, `rescueSpans`, `route`, `rebuild`, `roomTone`, `coalesceThinSpeech`, `growToEmbedderFloor`, `concatenatedSpeech` |

### `Audio/Speaker/`

| File | Responsibility |
|---|---|
| `SpeakerGate.swift` | CoreML ECAPA-TDNN wrapper, `enroll(utterances:)`, `classify(_:)` |
| `SpeakerGateService.swift` | Stateless gate orchestrator, `enrollmentSelection(fromFile:)`, `concatenatedSpeech(in:)` |
| `SpeakerVerdict.swift` | **Deprecated** — entire file commented out (DEPRECATED 2026-08-13). No longer used. |

---

## 3. Operating Modes

### `TSEConfig.Mode`

Persisted in `UserDefaults("TSEMode")`. Settable at runtime without restarting the session.

| Mode | Extractor runs? | Audio spliced? | Rejects silenced? | Use case |
|---|---|---|---|---|
| `.off` | No | No | No | Disable TSE entirely; audio passes bit-exact |
| `.observe` | Yes | No | No | Measure extraction cost and log `d_sep` without affecting audio |
| `.extractOnly` | Yes | Yes | No | Splices extracted audio; nothing withheld. Separation is the only filter. |
| `.enforce` *(default)* | Yes | Yes | Yes | Full pipeline: extracted audio + reject silencing + chunk withholding |

### `TSEConfig.Coverage`

Persisted in `UserDefaults("TSECoverage")`.

| Coverage | Which spans are extracted? | Verdict changes? |
|---|---|---|
| `.rescueOnly` *(default)* | `.reject` spans only | Only rejects can be re-judged after extraction |
| `.everySpan` | All judged spans | `.accept` and `.confirm` verdicts are **frozen** |

### Verdict Freeze Rule

A span the gate initially classified as `.accept` or `.confirm` has its verdict **frozen**. The extractor cannot demote a passing speaker. Only `.reject` spans can have their verdict revised:

- `d_sep < 0.675` → rescued to `.accept`
- `d_sep < 0.775` → rescued to `.confirm`
- `d_sep >= 0.775` → remains `.reject`

**Motivation (measured 2026-08-14):** Two of the clinician's own `confirm` spans had their extracted-audio ECAPA distances pushed *away* from the centroid (0.74 → 1.039 and 0.74 → 0.882). Freezing `.confirm` prevents the extractor from accidentally silencing the target speaker's own confirmed speech.

### `TSEConfig.silenceUnattributed`

When `true` (default) under `.enforce`: audio inside a judged chunk that is NOT covered by any passing (`.accept` or `.confirm`) span is also silenced to room tone. This closes the inter-span gaps — the keep-mask covers passing spans only; everything else is zeroed.

### Compute Units

`TSEConfig.computeUnits = .cpuOnly`. Measured on A16 Bionic: CPU-only averaged **12.40 ms/block** vs 14.95 ms/block for CPU+ANE — 20% faster. The ANE does not accelerate the `band_comm`-style reshape operations that dominate the BSRNN forward pass.

---

## 4. Speaker Gate — ECAPA-TDNN Identity Verification

### Model

**`SpeakerEmbedding_ECAPA.mlpackage`** — SpeechBrain ECAPA-TDNN. Fixed-shape input `[1, 48000]` Float32 (exactly 3.0 s at 16 kHz). Output: `[1, 192]` Float32 embedding.

- Shorter clips: zero-padded to 48,000 samples.
- Longer clips: centre-cropped to 48,000 samples.

### Operating Point (Multi-template Centroid Enrollment)

| Threshold | Verdict | FAR | Target speech captured |
|---|---|---|---|
| `d < 0.675` | `.accept` | 0.0% | 86.4% |
| `d < 0.775` | `.confirm` | 1.0% | +9.1% (cumulative 95.5%) |
| `d >= 0.775` | `.reject` | — | 4.5% lost |

EER with single template: **8.6%**. EER with multi-template centroid: **1.0%** (8.6x improvement). EER with min-distance strategy: 5.1% — worse than centroid.

### Enrollment

`SpeakerGate.enroll(utterances: [[Float]])` embeds each 3.0 s clip; stores the **centroid** (mean over all embeddings). FIFO eviction past `maxTemplates`.

`SpeakerGateService.enrollmentSelection(fromFile:maxPerFile:4)`:
- Energy-segments calibration audio using `rescueSpans` (same segmenter as live path).
- Picks up to 4 longest spans >= 1.0 s.
- Returns clips for `SpeakerGate.enroll(utterances:)`.

### Two ECAPA Models — NOT Interchangeable

> **Important:** There are two ECAPA-TDNN models on device with the same architecture (192-dim) but completely different weights and embedding spaces.

| Model | Weights | Used by | Purpose |
|---|---|---|---|
| `SpeakerEmbedding_ECAPA.mlpackage` | SpeechBrain | `SpeakerGate` | Identity verification — centroid distances |
| `EnrollmentEncoder_WeSpeaker.mlpackage` | WeSpeaker | `TSEExtractor` | Conditioning keys — `enroll_kv` for BSRNN |

Feeding one model's embeddings to the other's downstream consumer produces numerically valid but semantically meaningless output.

---

## 5. Energy Span Segmentation

The live gate uses **energy-based segmentation** (`rescueSpans`). Silero VAD was removed from this path on 2026-08-17: it measured 0.001–0.09 speech probability on this device — effectively non-functional.

### `rescueSpans(in:allowBlindWindows:) -> ([SpeechSegment], Bool)`

All constants live in `RescueTuning`.

1. **Frame energy:** 30 ms frames (480 samples at 16 kHz). RMS per frame.
2. **Noise floor:** 20th-percentile frame RMS.
3. **Loud level:** 90th-percentile frame RMS.
4. **Threshold:** `max(noiseFloor * 3.0, 0.003)`. Requires meaningful dynamic range (loud > 3.5x noise) — a flat signal produces no spans.
5. **Raw candidates:** contiguous above-threshold frame runs.
6. **`mergeSpans`:** bridge gaps <= 0.6 s (preserves words split by stop consonants), split spans > 3.0 s.
7. **`coalesceThinSpeech`:** iteratively join adjacent thin spans until each holds >= 0.75 s of actual speech. Joining adds voice; growing adds only silence.
8. **`growToEmbedderFloor`:** stretch any span < 1.0 s to the ECAPA minimum, using available room on either side without overlapping neighbours.
9. **Speech-content filter:** drop spans with < `minSpeechSeconds = 0.75` s of above-threshold audio (after all merging and growing).

**`allowBlindWindows`:**
- `false` (live path): if no spans found, return `([], false)` — chunk passes untouched. A blind window verdict on near-silence is worse than doing nothing.
- `true` (enrollment only): fall back to 3.0 s fixed windows so clinicians can enroll even with poorly-segmenting calibration audio.

### `coalesceThinSpeech` Detail

Iterates until stable. For each adjacent pair `(a, b)`: if either has < `minSpeechSeconds` of voice AND the combined span fits within 3.0 s — join. Repeat until no more joins.

### `growToEmbedderFloor` Detail

For each span < 1.0 s: split needed growth evenly left/right, constrained by audio bounds and neighbouring span boundaries. Hard bounds: cannot overlap adjacent spans.

---

## 6. Extractor Architecture — BSRNN

### Six Core ML Models (in call order)

| # | Model | Input | Output | Frequency |
|---|---|---|---|---|
| 1 | `EnrollmentEncoder_WeSpeaker` | fbank `[1, frames, 80]` | frame features `[1, 512, frames]` | Once at enrollment |
| 2 | `EnrollmentProjection_BSRNN` | `[1, 512, enrollKeys]` | `enroll_kv [nBands, enrollKeys, attenDim]` | Once at enrollment |
| 3 | `TSEFrontend_BSRNN` | `spec_ri [1, 3, bins, blockFrames]` | `features` | Per 8-frame block |
| 4 | `SpeakerConditioning_BSRNN` | `features + enroll_kv` | `conditioned` | Per 8-frame block |
| 5 | `TargetSeparator_BSRNN` | `conditioned + (h_in, c_in)` | `separated, (h_out, c_out)` | Per block; LSTM state carried |
| 6 | `TSEMasker_BSRNN` | `separated` | `(mask_real, mask_imag)` | Per 8-frame block |

STFT, iSTFT, Kaldi fbank, and tfmap are pure Swift/Accelerate — no CoreML.

### Architecture Constants

| Constant | Value | Meaning |
|---|---|---|
| `sampleRate` | 16,000 | Hz |
| `nFFT` | 512 | 32 ms analysis window |
| `hop` | 128 | 8 ms hop — one STFT frame |
| `bins` | 257 | `nFFT/2 + 1` |
| `nBands` | 32 | BSRNN sub-bands |
| `nLayers` | 6 | Separator LSTM layers |
| `hidden` | 256 | LSTM hidden size |
| `blockFrames` | 8 | One CoreML call = 8 STFT frames = 64 ms of audio |
| `enrollKeys` | 1024 | Conditioning key-value pairs = 10.24 s fbank |
| `enrollEmbedDim` | 512 | WeSpeaker ECAPA layer-4 frame feature dimension |

### Enrollment (`prepareEnrollment(_ audio: [Float])`)

1. Compute Kaldi fbank (80-bin, 25 ms window, 10 ms hop, hamming, CMVN, input scaled x32768). Result: `frames` fbank vectors.
2. Guard `frames >= enrollKeys (1024)` — i.e. >= **10.24 s** of speech-only audio. Fails with loud warning if below floor.
3. `EnrollmentEncoder_WeSpeaker`: fbank `[1, frames, 80]` -> frame features `[1, 512, frames]`.
4. Subsample to exactly 1,024 keys using `torch.linspace` index semantics.
5. `EnrollmentProjection_BSRNN`: `[1, 512, 1024]` -> `enroll_kv [nBands, enrollKeys, attenDim]` — **16 MB**, allocated once per session.
6. STFT of enrollment audio -> magnitude -> L2-normalise per frame -> `enrollMagNorm` (used in tfmap attention).
7. Store `enrollKV` and `enrollMagNorm` in a lock-guarded pair.

### Extraction (`extract(_ span: [Float]) throws -> [Float]`)

For each 8-frame STFT block (64 ms):

1. **tfmap** — attention over enrollment in magnitude domain:
   - Query = STFT block magnitude (8 frames x 257 bins).
   - `score[t, k] = dot(query[t], enrollMagNorm[k])` via BLAS `sgemm`.
   - Softmax over enrollment keys `k`.
   - `tfmap[t] = weighted sum of enrollKV`.
2. Assemble `spec_ri = [real, imag, tfmap]`, shape `[1, 3, bins, 8]`.
3. **TSEFrontend_BSRNN**: `spec_ri` -> `features`.
4. **SpeakerConditioning_BSRNN**: `(features, enroll_kv)` -> `conditioned`.
5. **TargetSeparator_BSRNN**: `(conditioned, h_in, c_in)` -> `(separated, h_out, c_out)`. LSTM state carried across blocks.
6. **TSEMasker_BSRNN**: `separated` -> `(mask_real, mask_imag)`.
7. Complex ratio mask: `est_real = re*mr - im*mi`, `est_imag = re*mi + im*mr`.

After all blocks: **iSTFT** (overlap-add, squared Hann envelope, center=True) -> output waveform, same length as input.

### Signal Processing (`TSEFeatures.swift`)

**`TSESpectrogram`** — matches `torch.stft(512, 128, hann, center=True)`:
- Reflect-padded by `nFFT/2 = 256` samples on both ends.
- Periodic Hann window (not symmetric).
- vDSP real FFT; DC/Nyquist halved to undo vDSP 2x convention.
- Verified at **139.8 dB** round-trip (torch's own: 139.4 dB — float32 limit).

**`TSEKaldiFbank`** — matches `torchaudio.compliance.kaldi.fbank(num_mel_bins=80, frame_length=25, frame_shift=10)`:
- 25 ms window (400 samples), 10 ms hop (160 samples), zero-padded to 512, Hamming window.
- DC offset removal, preemphasis 0.97 with replicate first-sample padding.
- Input scaled by **32,768** before framing (Kaldi 16-bit integer convention).
- CMVN: subtract per-coefficient mean. No variance normalization.
- Verified against Python reference to ~1e-5 absolute error.

---

## 7. Routing Decision

### `shouldExtract(verdict:durationSeconds:) -> Bool`

Static, pure. Returns `true` only when ALL of:

1. `TSEConfig.mode.runsExtractor` (`mode != .off`)
2. `durationSeconds >= TSEConfig.minRouteSeconds (1.0 s)` — spans < 1 s are never routed
3. `extractor.isPrepared` — WeSpeaker enrollment has been computed
4. Verdict-coverage agreement:

| Verdict | `.rescueOnly` | `.everySpan` |
|---|---|---|
| `.accept` | no (pass bit-exact) | yes (verdict frozen) |
| `.confirm` | no (pass bit-exact) | yes (verdict frozen) |
| `.reject` | yes | yes |
| `.tooShort` | no | no |

### Verdict Revision in `route()`

For **`.reject` spans only** — after extraction, re-classify extracted audio to get `d_sep`:

- `d_sep < postAcceptThreshold (0.675)` -> rescued to `.accept`
- `d_sep < rejectThreshold (0.775)` -> rescued to `.confirm`
- `d_sep >= 0.775` -> stays `.reject`

For `.accept` and `.confirm` spans: verdict is **frozen** regardless of `d_sep`.

### `RescuedSpan`

| Field | Meaning |
|---|---|
| `start, end` | Chunk-relative sample indices |
| `verdictMixed` | ECAPA verdict on original audio |
| `distanceMixed` | Cosine distance, original audio |
| `verdictSeparated` | ECAPA verdict on extracted audio (`nil` if not extracted) |
| `distanceSeparated` | Cosine distance, extracted audio |
| `effectiveVerdict` | `verdictSeparated ?? verdictMixed` |
| `routed` | Went through extractor? |
| `extractionSeconds` | Wall-clock cost of extraction |
| `level` | RMS of span in original chunk |
| `extractedAudio` | Populated when `mode.splicesAudio`; nil otherwise |

---

## 8. Audio Rebuild

### `rebuild(_:applying:silencingRejects:silencingUnattributed:)`

1. Copy input chunk into output buffer.
2. For each routed span with `extractedAudio`: splice extracted audio into output at `[r.start..<r.end]`.
3. If `silencingRejects`: fill all `.reject` spans with room tone.
4. If `silencingUnattributed` (and `silencingRejects`): build keep-mask over all `.accept`/`.confirm` spans. Fill every sample NOT covered by the mask with room tone. This silences inter-span gaps in addition to explicit rejects.

### Room Tone Fill — Not Digital Silence

> **Important:** Rejected and unattributed spans are filled with **uniform noise at the 20th-percentile RMS of the original chunk** — NOT zeros.

**Why not zeros:** `Wav2VecEngine` pads inference inputs with white noise. A zero-padded region creates a "flatline cliff" at the boundary — a Z-score-normalized signal at exactly zero variance — which corrupts the CNN's causal receptive field and drops phonemes immediately before/after the silence.

**Formula:**
```
noiseFloor = 20th-percentile of 30ms frame RMS (computed over original chunk, before modification)
roomToneRMS = min(noiseFloor, maxRoomToneRMS = 0.02)
fill[i] = Uniform(-roomToneRMS * sqrt(3), +roomToneRMS * sqrt(3))
```

Uniform distribution with this range has RMS = `roomToneRMS`, approximating white noise at the measured noise floor.

---

## 9. Early Commit Integration

When `Wav2VecViewModel` detects a command boundary during intermediate preview (via the `isCommandBoundary` hook), it slices the buffer and calls `commit(chunkToCommit, isEarlyCommit: true)`.

### Early-Commit Gate Path (`isEarlyCommit: true`)

- Calls `gatedAudio(for: gateAccumulator, extractor: nil, skipExtraction: true)`.
- Uses `gateAccumulator` (full running audio since last commit), **not** the short sliced chunk. The sliced chunk is typically < 2 s — too short for a meaningful ECAPA embedding; the accumulator gives a better identity read.
- `skipExtraction: true` — BSRNN models are NOT run.
- Decision: any span `.accept`, `.confirm`, or `.tooShort` -> pass sliced chunk bit-exact. All spans `.reject` -> return nil (withhold).

### Why No Extraction on Early Commits

- Extraction costs ~RTF 0.3 per extracted span (see §12).
- An early-commit slice is typically 0.5–2 s. Extraction would cost 0.15–0.6 s wall-clock.
- The purpose of early commit is to **reduce latency**. Spending 0.6 s on extraction negates the gain.
- For a sub-second slice, gate identity is sufficient.

---

## 10. Enrollment Pipeline

Enrollment is split into two separate processes because the gate and extractor use different models with different input requirements.

### Gate Enrollment (SpeechBrain ECAPA -> identity centroid)

1. User records calibration audio in `OnboardingView` via `AudioManager`.
2. Recording saved as a `CalibrationTake` in `VoiceProfileStore`.
3. `SpeakerGateService.enrollmentSelection(fromFile:maxPerFile:4)`:
   - Segments calibration audio with `rescueSpans` (same energy segmenter as live path — template distribution matches live conditions).
   - Picks up to 4 longest spans >= 1.0 s.
   - Returns 3.0 s clips (zero-padded or cropped to ECAPA input shape).
4. `SpeakerGate.enroll(utterances:)` embeds each clip and stores the centroid.

### Extractor Enrollment (WeSpeaker -> `enroll_kv`)

`TSEEngine.enrollmentAudio(from: urls)` uses `SpeakerGateService.concatenatedSpeech`:

**`concatenatedSpeech(in:) -> [Float]`** — static, pure:
- Same 20th-percentile energy threshold; 0.2 s gap bridging.
- **No** speech-content filter (`minSpeechSeconds` not applied).
- **No** `growToEmbedderFloor`.
- Concatenates ALL above-threshold runs in order.

**Why different from `rescueSpans`:**

`rescueSpans` asks: *"Is there enough voice here to identify someone?"* — keeps only spans long enough and voice-dense enough for ECAPA. Measured on real takes: kept **7.2 s out of 22.5 s**.

`concatenatedSpeech` asks: *"Give me as many fbank frames as possible."* — discarding any frame reduces `enroll_kv` quality. Measured: kept **18.1 s out of 22.5 s**.

**Enrollment floor:** >= `enrollKeys = 1024` fbank frames = **>= 10.24 s of speech-only audio**.

**Fallback:** if `concatenatedSpeech` returns < 10.24 s, `enrollmentAudio(from:)` falls back to the whole file (all samples concatenated without silence stripping). A loud warning is printed. Conditioning quality is degraded.

**Multi-take:** `TSEEngine.prepare()` concatenates speech from all active `CalibrationTake` URLs. Measured: 2 short takes = 26.3 s enrolled; 2 longer takes = 34.4 s enrolled. More enrollment speech generally improves conditioning.

### Live Session Pickup

`Wav2VecViewModel.startLive()` reads `TSEEngine.shared.extractor`. If `extractor?.isPrepared == false`, fires `Task { await TSEEngine.shared.prepare() }` in the background. First few commits may run gate-only. `GateStatus.extractorReady` reflects this.

**After profile switch:** call `TSEEngine.shared.reprepare()`. The old `enroll_kv` is keyed to the previous user's voice and must be recomputed with WeSpeaker for the new profile.

---

## 11. GateStatus and Debug

### `GateStatus` (on `Wav2VecViewModel`)

Updated after every commit. Observed by `AIListeningView`.

| Field | Type | Meaning |
|---|---|---|
| `active` | `Bool` | Gate service present and enrolled |
| `extractorReady` | `Bool` | `TSEEngine.shared.extractor?.isPrepared` |
| `silencing` | `Bool` | `TSEConfig.mode.silencesRejects` — false under `.extractOnly` |
| `spans` | `Int` | Total judged spans in last commit |
| `rejected` | `Int` | Spans with `effectiveVerdict == .reject` |
| `extracted` | `Int` | Spans that went through the extractor |
| `rescued` | `Int` | Spans that were `.reject` but extracted to `.accept`/`.confirm` |
| `lastDistance` | `Double?` | Most recent ECAPA cosine distance |
| `summary` | `String` | Human-readable status for `AIListeningView` |

### Console Log Format

**Per gate span (`[Gate]` — not routed):**
```
[Gate]   0.00–  2.34s (2.3s) nrg rms 0.043  d 0.621  cos 0.379  margin +0.054  accept
```

**Per extracted span (`[TSE]` — routed through extractor):**
```
[TSE]   2.34–  5.10s (2.8s) nrg rms 0.052  d 0.811 -> 0.643  reject -> accept  (1.23s)
```

**Per-commit summary (`[TSE/cover]`):**
```
[TSE/cover] enforce/rescueOnly — 2/5 span(s), 2.8s of 7.4s extracted, 1.23s spent (rtf 0.44)
```

`nrg` = energy-segmented (trustworthy); `win` = blind window (enrollment fallback only — DISTRUST these distances). Suffix `[mode]` shown when mode != `.enforce`.

### Runtime Controls

| Setting | Persisted in | Default |
|---|---|---|
| `TSEConfig.mode` | `UserDefaults("TSEMode")` | `.enforce` |
| `TSEConfig.coverage` | `UserDefaults("TSECoverage")` | `.rescueOnly` |
| `TSEConfig.silenceUnattributed` | code constant | `true` |

### `SpeakerGateDebugView`

Accessible via **Debug -> Speaker Gate (TSE)**. Provides enrollment testing, per-file verification, live `GateStatus` readout, and manual `reprepare()` trigger.

### `SessionRecorder`

Called at every `startLive()` (begin), after each `performCommit` (append raw + gated), and at `stopLive()` (finish). When a debug flag is set, raw and gated audio streams are written to disk for offline analysis.

---

## 12. Performance

| Metric | Value | Notes |
|---|---|---|
| RTF per extracted span | ~0.3 | 6 s span -> ~1.8 s wall-clock |
| Block processing time | ~12.4 ms / 8-frame block | A16 Bionic, CPU-only |
| `enroll_kv` allocation | 16 MB | Allocated once at `prepareEnrollment`; reused for session lifetime |
| Compute units | `.cpuOnly` | 20% faster than `.cpuAndNeuralEngine` on A16 |

Extraction is **serialised before transcription** in `performCommit`: gate -> extract -> normalize -> `Wav2VecEngine.predict`. Commits are chained (each awaits its predecessor), so audio arrives at the ASR in capture order regardless of extraction timing.

---

## 13. Asset Reference

All models are in `AI/Target_Speech_Extraction/` (gitignored). Must be placed manually before first run.

| Model | File | Role |
|---|---|---|
| ECAPA-TDNN (SpeechBrain) | `SpeakerEmbedding_ECAPA.mlpackage` | Gate identity verification |
| WeSpeaker enrollment encoder | `EnrollmentEncoder_WeSpeaker.mlpackage` | fbank -> frame features |
| BSRNN enrollment projection | `EnrollmentProjection_BSRNN.mlpackage` | Frame features -> `enroll_kv` |
| BSRNN frontend | `TSEFrontend_BSRNN.mlpackage` | `spec_ri` -> band features per block |
| BSRNN speaker conditioning | `SpeakerConditioning_BSRNN.mlpackage` | Band features + enrollment -> conditioned |
| BSRNN target separator | `TargetSeparator_BSRNN.mlpackage` | Streaming LSTM separation |
| BSRNN masker | `TSEMasker_BSRNN.mlpackage` | Separated -> complex ratio mask |

All models use `computeUnits = .cpuOnly` (set in `TSEConfig`).

---

## 14. Known Limitations and Caveats

> **Warning:** All positive WER measurements for TSE were conducted on **synthetic mixes** assembled in a recording studio without shared room acoustics. No controlled measurement of WER improvement on real clinical dictation sessions has been completed.

**Extraction sometimes moves spans away from the target centroid.**

On real sessions (2026-08-05 to 2026-08-06), ECAPA distances on extracted audio were sometimes *higher* than on the original:
- One clinician `confirm` span: 0.74 (original) -> 1.039 (extracted) — made it look like a stranger.
- Another: 0.74 -> 0.882 — pushed into the reject zone.

This directly motivated the **verdict freeze rule** (§3, §7) and the **`.rescueOnly` default coverage** (§3).

**`.everySpan` coverage introduces transcription errors.**

Measured transcript comparison (2026-08-14): `.everySpan` caused `"selesai"` instead of `"ke resesi"`, and produced hallucinated tokens not present in the original dictation. `.rescueOnly` avoids these by passing accepted/confirmed spans bit-exact.

**Extraction cost is non-trivial.**

At RTF 0.3, a session with many long rejected spans can add several seconds of latency before the final transcript is confirmed.

**Extractor requires >= 10.24 s of speech for enrollment.**

Clinicians with short calibration recordings fall back to whole-file conditioning, which degrades quality. The onboarding UI should clearly communicate this requirement.

**`SpeakerVerdict.swift` is a dead file.**

Entire file is commented out (DEPRECATED 2026-08-13). Previously defined a text-span verdict type for the Whisper post-transcription gate. Nothing in the live path references it.
