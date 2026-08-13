# Periodontal Charting — STT Documentation

This document describes the **Speech-to-Text (STT) layer** of the Periodontal Charting app: how microphone audio is captured, how it becomes a text transcript, and how that transcript is fed to the downstream NLP pipeline. The app contains two independent STT engines — **Wav2Vec2 (default)** and **Whisper** — switchable at runtime. This document covers both, with emphasis on Wav2Vec2 as the production default.

For the NLP pipeline that consumes the transcript, see [system_guide.md](system_guide.md). For the file-by-file Swift reference, see [frontend_guide.md](frontend_guide.md).

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Engine Selection](#2-engine-selection)
3. [Wav2Vec2 Pipeline (Default)](#3-wav2vec2-pipeline-default)
   - [Audio Capture — Wav2VecAudioCapture](#31-audio-capture--wav2vecaudiocapture)
   - [Model — Wav2VecEngine](#32-model--wav2vecengine)
   - [Streaming VAD & Commit Logic — Wav2VecViewModel](#33-streaming-vad--commit-logic--wav2vecviewmodel)
   - [CTC Decoding — CTCDecoder](#34-ctc-decoding--ctcdecoder)
   - [Lexicon Constraint — PrefixTrie](#35-lexicon-constraint--prefixtrie)
   - [Acoustic Cost Hallucination Filter](#36-acoustic-cost-hallucination-filter)
   - [Canonical Mapping](#37-canonical-mapping)
4. [Whisper Pipeline (Alternative)](#4-whisper-pipeline-alternative)
   - [TranscriptionEngine](#41-transcriptionengine)
   - [Silero VAD](#42-silero-vad)
   - [Clinical Vocabulary Biasing](#43-clinical-vocabulary-biasing)
   - [Speaker Gate (TSE)](#44-speaker-gate-tse)
5. [AIVoiceViewModel Integration](#5-aivoiceviewmodel-integration)
   - [Live Preview vs. Committed Transcripts](#51-live-preview-vs-committed-transcripts)
   - [Session Parser Lifecycle](#52-session-parser-lifecycle)
6. [Asset Reference](#6-asset-reference)

---

## 1. Architecture Overview

The STT layer sits between the microphone hardware and the `StatefulParser`. Its job is to convert raw PCM audio into confirmed Indonesian text chunks, then fire callbacks into `AIVoiceViewModel` which drives the parser.

```
Microphone (AVAudioEngine)
        │  Raw PCM (hardware sample rate, e.g. 48kHz)
        ▼
┌─────────────────────────────────────────┐
│  Audio Capture / Resampling             │
│  Wav2VecAudioCapture  (Wav2Vec2 path)   │  Resamples to 16kHz mono Float32
│  TranscriptionViewModel (Whisper path)  │  Resamples via WhisperKit
└─────────────────────────────────────────┘
        │  16kHz Float32 chunks (aligned to 512-sample multiples)
        ▼
┌─────────────────────────────────────────┐
│  VAD / Commit Gating                    │
│  Wav2VecViewModel     (Wav2Vec2 path)   │  RMS-threshold energy VAD
│  SileroVADEngine      (Whisper path)    │  Neural speech probability VAD
└─────────────────────────────────────────┘
        │  Speech segments ready for inference
        ▼
┌─────────────────────────────────────────┐
│  ASR Inference                          │
│  Wav2VecEngine (CoreML CTC model)       │  → raw logit grid [T × vocab]
│  WhisperKit (encoder-decoder)           │  → token IDs → detokenized text
└─────────────────────────────────────────┘
        │  Raw text
        ▼
┌─────────────────────────────────────────┐
│  Post-processing                        │
│  CTCDecoder (Wav2Vec2 path)             │  Beam search + trie + acoustic filter + mapping
│  SequenceBiasFilter (Whisper path)      │  Per-step clinical vocab logit biasing
└─────────────────────────────────────────┘
        │  onLiveTranscript(fullText: String)    ← intermediate (preview)
        │  onConfirmedTranscript(chunk: String)  ← silence-committed (final for this chunk)
        ▼
AIVoiceViewModel  →  StatefulParser  →  [AnnotationCommand]  →  ChartDashboard
```

---

## 2. Engine Selection

Two engines are compiled into the app. The active one is selected by a single `UserDefaults` key:

| Key | Default | Effect |
|---|---|---|
| `"useOfflineWav2Vec"` | `true` | `true` → Wav2Vec2; `false` → Whisper |

The default (`true`) is registered in `PeriodontalChartingApp.init()`:

```swift
UserDefaults.standard.register(defaults: [
    "useMLTokenizer": false,
    "useOfflineWav2Vec": true
])
```

The toggle is exposed in **Debug → Speech-to-Text Engine** (a segmented picker: `"Wav2Vec2 STT"` / `"Whisper STT"`). Changes take effect on the **next** AI Mode session start — the running session is not hot-swapped.

> [!NOTE]
> Even when `useOfflineWav2Vec == true`, `TranscriptionEngine` is still loaded at app launch. This is because `TranscriptionEngine` owns the speaker gate (ECAPA-TDNN + Silero VAD) which is shared infrastructure used regardless of which STT path is active. The WhisperKit model itself is not needed by the Wav2Vec2 path, but the load sequence is serialized and both start at launch.

---

## 3. Wav2Vec2 Pipeline (Default)

The Wav2Vec2 path is implemented across four files in `Audio/Wav2Vec/`:

| File | Role |
|---|---|
| `Wav2VecAudioCapture.swift` | AVAudioEngine tap, hardware resampling to 16kHz, Z-score normalization |
| `Wav2VecEngine.swift` | CoreML model singleton, padding + inference, canonical mapping application |
| `Wav2VecViewModel.swift` | RMS VAD, streaming buffer management, live/committed transcript callbacks |
| `CTCDecoder.swift` | Beam search CTC decoder with PrefixTrie lexicon constraint and acoustic-cost filter |
| `PrefixTrie.swift` | Prefix trie data structure loaded from `lexicon.txt` |

### 3.1 Audio Capture — `Wav2VecAudioCapture`

`Wav2VecAudioCapture` is an `@MainActor ObservableObject` singleton (`shared`). It owns the `AVAudioEngine` tap and handles:

**Session setup:**
- Configures `AVAudioSession` as `.playAndRecord` with `.defaultToSpeaker` and `.allowBluetooth` options.
- Installs an `inputNode` tap with a 4096-frame buffer.
- Creates an `AVAudioConverter` from the hardware input format (e.g. 44100 or 48000 Hz, stereo) to 16kHz mono Float32.

**Streaming mode (`startStreamingRecording(onBuffer:)`):**
- Maintains an `alignmentBuffer` that accumulates converted audio until it has a multiple of **512 samples** — matching Silero VAD's expected chunk size.
- Fires `onBuffer([Float])` with the aligned chunk, passing **raw (unnormalized)** audio so the downstream RMS VAD can gauge absolute energy levels.

**Audio level metering:**
- Uses `vDSP_rmsqv` on the original (pre-conversion) buffer to compute RMS, converts to dBFS, and publishes `audioLevel` for the UI mic level indicator.

**Z-score normalization (`normalizeAudio(data:)`):**
- Uses `vDSP_normalize` to compute mean and standard deviation, then applies zero-mean unit-variance scaling.
- Returns `[Float](repeating: 0.0, count: data.count)` if `stdDev == 0` (pure silence), preventing NaN propagation.
- Called by `Wav2VecViewModel` just before handing audio to `Wav2VecEngine`, **not** inside the tap callback — normalization runs on the full committed segment, not on individual 512-sample chunks.

**Offline mode (`startOfflineRecording` / `stopOfflineRecording`):**
- Accumulates raw audio into `offlineAudioBuffer`.
- `stopOfflineRecording()` stops the engine and returns the Z-score normalized result.
- Used by `AudioManager` for voice calibration recording (not used in the AI Mode path).

### 3.2 Model — `Wav2VecEngine`

`Wav2VecEngine` is an `@MainActor ObservableObject` singleton (`shared`) that owns the CoreML model and decoder.

**Model loading (`loadModel()`):**

Idempotent — returns immediately if already loaded. Runs on a `Task.detached(priority: .userInitiated)` background thread to avoid blocking the main actor during the large model load.

Resource discovery (tries bundle root first, then the `AI/Wav2Vec_STT` subdirectory):
- `Wav2Vec2_Indonesian_FP16.mlmodelc` — the compiled CoreML model
- `vocab.json` — character vocabulary (JSON dict: `{char: index}`)
- `lexicon.txt` — tab-delimited word list (word in column 0)
- `canonical_mapping.json` — post-decode word normalization map

The model is configured with `.cpuAndGPU` compute units. After loading, `PrefixTrie` is built from the lexicon words plus any keys in `canonical_mapping` that are not already in the lexicon, then `CTCDecoder` is initialized with the vocab and trie.

**Inference (`predict(audioData:isLivePreview:)`):**

Runs on `Task.detached(priority: .userInitiated)`.

1. **Bucket padding:** The audio is padded to the nearest 16000-sample (1-second) boundary. This ensures the Metal backend only allocates a few fixed-size buffers rather than allocating a new one for every unique length, preventing GPU memory fragmentation.

2. **White noise padding:** The padding region is filled with uniform random noise in `[-√3, +√3]` (variance ≈ 1.0), **not** zeros. This is a critical correctness fix: because audio is Z-score normalized (mean 0, variance 1), zero-padding creates a mathematically impossible flatline cliff that corrupts the CNN's forward receptive field and causes the final phoneme of a word to be dropped. White noise with the same variance as the speech signal provides a natural acoustic boundary.

3. **MLMultiArray construction:** Input is `[1, paddedLength]` Float32, fed as `"input_values"`.

4. **Inference:** Calls `MLModel.prediction(from:)`. Reads the `"logits"` output MultiArray, shape `[1, paddedTimeSteps, vocabSize]`.

5. **Actual-length extraction:** Only logit frames corresponding to real audio are decoded. The conversion factor is **1 frame = 320 samples** (standard Wav2Vec2 striding): `actualTimeSteps = seqLength / 320`. Padded frames are discarded.

6. **Decode:** Calls `CTCDecoder.decode(logits:beamWidth:isLivePreview:)` with `beamWidth = 10`.

7. **Canonical word mapping:** The decoded word sequence is split on spaces; each word is looked up in `decoder.dynamicMapping`. If found, the canonical form replaces the raw form. This applies single-word substitutions. Multi-word phrase substitutions are applied inside `CTCDecoder.decode` itself.

8. **Number Formatting & NLP Reconstruction:** The Wav2Vec2 model outputs multi-digit numbers as space-separated single digits (e.g., `18 222` is emitted as `1 8 2 2 2`). The downstream `VoiceTokenizer` (NLP pipeline) is explicitly designed to handle this by applying `isStartOfBlock` heuristics to reconstruct structural `toothIdentifier` tokens from these single-digit streams. The `VoiceTokenizer` specifically uses chunking separated by newlines (converted to `_sep_`) to maintain these block boundaries cleanly. All local regression testing scripts (e.g. `dr_lucky_ground.txt`) must manually insert spaces between digits and separate clinical thoughts with newlines to correctly simulate this native output and chunk-streaming behavior.

### 3.3 Streaming VAD & Commit Logic — `Wav2VecViewModel`

`Wav2VecViewModel` is the live-session orchestrator. It is `@MainActor @Observable` and is instantiated once inside `AIVoiceViewModel` (not shared).

**State:**
- `streamingBuffer: [Float]` — accumulated raw audio since the last commit.
- `committedHistory: [String]` — list of confirmed transcription segments for this session.
- `silenceFrames: Int` — count of consecutive silence frames seen since last speech.
- `hasStartedSpeaking: Bool` — true after the first speech frame.
- `baselineRMS: Float` — exponentially smoothed RMS estimate of background noise. Starts at `0.01`, decays toward the noise floor at rate `0.01` per silent frame.
- `isProcessing: Bool` — prevents concurrent inference calls on the same buffer.
- `lastProcessedBufferCount: Int` — tracks when the buffer has grown enough to justify a fresh intermediate inference.

**Per-chunk VAD (`processAudioChunk(_:)`):**

Called on `DispatchQueue.main` for each 512-sample chunk from `Wav2VecAudioCapture`.

```
RMS = vDSP_rmsqv(buffer)
threshold = max(0.001, baselineRMS × 2.0)
isSpeech = (RMS > threshold)
if !isSpeech: baselineRMS ← baselineRMS × 0.99 + RMS × 0.01  (slow exponential decay)
```

- **Pre-roll buffer:** Before speech starts, the buffer is capped at 16000 samples (1 second of pre-roll). This prevents a large silence accumulation before the first word.
- **Adaptive silence timeout:** `requiredSilence` (in frames, each ~32ms) decreases as the buffer grows, preventing indefinitely long sessions from blocking:

| Buffer size | Required silence |
|---|---|
| < 15 s | 15 frames (~0.48 s) |
| 15–30 s | 10 frames (~0.32 s) |
| 30–45 s | 5 frames (~0.16 s) |
| 45–55 s | 3 frames (~0.10 s) |
| > 55 s | 0 frames (commit immediately) |

**Commit (silence detected):**

When `hasStartedSpeaking && silenceFrames >= requiredSilence && streamingBuffer.count > 16000`:
1. Snapshot `streamingBuffer`, clear it.
2. Reset `silenceFrames`, `hasStartedSpeaking`, `lastProcessedBufferCount`.
3. Spawn a `Task`:
   - Z-score normalize the chunk.
   - Call `Wav2VecEngine.shared.predict(audioData:isLivePreview: false)`.
   - If result is non-empty: append to `committedHistory`, join with spaces, fire `onConfirmedTranscript(joined)` and `onLiveTranscript(joined)`.

**Intermediate inference (live preview, no commit):**

When `streamingBuffer.count >= 16000 && !isProcessing && silenceFrames <= requiredSilence && buffer grew by >= 8000 samples since last preview`:
1. Snapshot current `streamingBuffer` (not cleared — speech is ongoing).
2. Spawn a `Task`:
   - Z-score normalize.
   - Call `Wav2VecEngine.shared.predict(audioData:isLivePreview: true)`.
   - Prepend `committedHistory` to form the full running transcript.
   - Fire `onLiveTranscript(liveOutput)`.

**On `stopLive()`:**

Stops audio capture. If the remaining buffer is ≥ 16000 samples (1 second), performs one final committed inference and fires both `onConfirmedTranscript` and `onLiveTranscript`.

**Speaker gate note:** `Wav2VecViewModel` maintains a stub `GateStatus` struct so that `AIVoiceViewModel.gateStatus` can be read without a type branch. The `summary` property always returns `"Speaker filter offline (Wav2Vec2)"` — the full speaker gate (ECAPA-TDNN + BSRNN TSE) is only active in the Whisper path.

### 3.4 CTC Decoding — `CTCDecoder`

`CTCDecoder` implements a **prefix beam search** decoder over the CTC logit grid. It is initialized with a vocabulary and a `PrefixTrie` lexicon.

**Vocabulary loading (`loadVocab`):**

Reads `vocab.json` (a `{char: Int}` dictionary). Sorts characters by index into `labels: [String]`. Locates:
- `blankIndex` — the CTC blank token, identified by the `"[PAD]"` or `"</s>"` key.
- `spaceIndex` — the word boundary token, identified by the `"|"` key; its label is replaced with `" "`.

Special tokens (labels beginning with `"["` or `"<"`) are cleared to `""` so they are never emitted.

**Beam state:**

Each `Beam` tracks:
- `text: String` — the hypothesis text built so far.
- `lastCharIndex: Int` — the most recently emitted character index (for repeat detection).
- `probBlank: Float` — log-probability of this hypothesis ending in a blank frame.
- `probNonBlank: Float` — log-probability of this hypothesis ending in a non-blank character.
- `totalProb: Float` — `max(probBlank, probNonBlank)` (log-sum-exp approximation).
- `lastSpaceFrame: Int` — frame index of the last space insertion.
- `wordCosts: [Float]` — acoustic cost per completed word.
- `currentWordCost: Float` — accumulating acoustic cost for the word in progress.

**Decoding loop (`decode`):**

1. Apply log-softmax to the raw logit grid.
2. For each time step `t`, for each beam:
   - **Blank extension:** Extend with the blank token. Merged back into the same `BeamState` (blank does not change the text). Pruned if blank log-prob `< -20.0`.
   - **Character extensions:** For each non-blank, non-empty label with log-prob `> -10.0`:
     - **Repeat suppression:** If the same character index was the last emitted, the character is not appended (CTC repeated-frame collapsing).
     - **Trie constraint:** `trie.isValidPrefix(sequence: newText)` is checked. If the new text is not a valid prefix of any lexicon word, the beam is pruned. Exception: if the last completed word is a valid lexicon word (`trie.isWord(lastWord)`), an **implicit space** is injected before the new character and the alternate text is checked. If valid, the beam continues with a `beamProbPenalty = 2.0` (discourages unnecessary word fracturing).
     - Acoustic cost for the character is tracked as `currentWordCost += (maxLogit - pChar)`.
3. Prune `nextBeams` to the top `beamWidth` entries by `totalProb`. Default `beamWidth = 10`.
4. After all frames: select the beam with the highest `totalProb`.

**Post-beam word-boundary finalization:**

1. Split the best hypothesis into words.
2. If the hypothesis does not end with a space (i.e., the last word is incomplete), the trailing word is dropped if it is not a valid lexicon word (`!trie.isWord(lastWord)`). This prevents partial phoneme sequences from appearing in output when the audio is cut mid-word.

**Multi-word canonical mapping:**

After the word-list is finalized, the `dynamicMapping` dictionary is iterated in descending key-length order. Each key is searched in the final string and replaced if found. This applies multi-word normalization (e.g., `"bleeding or probing"` → `"bop"`) that cannot be expressed as single-word substitutions.

### 3.5 Lexicon Constraint — `PrefixTrie`

`PrefixTrie` is a character-level prefix trie loaded from `lexicon.txt`. The lexicon is a tab-delimited file; the first column of each line is the word.

**Key operations:**

| Method | Description |
|---|---|
| `insert(word:)` | Insert a word into the trie character by character. Marks the terminal node `isWord = true`. |
| `load(from:)` | Batch load from a file path. |
| `isValidPrefix(sequence:)` | True if the sequence is a valid prefix of any lexicon entry. Space-aware: splits by `" "` and only validates the current word being formed. If the sequence ends with a space, validates that the just-completed word is a lexicon word. |
| `isWord(_:)` | True if the word is fully in the trie with `isWord == true` at the terminal node. |

The trie is built from the union of:
- Words in `lexicon.txt` (the clinical + Indonesian vocabulary).
- Any keys present in `canonical_mapping.json` that are not already in the lexicon (so variant spellings that map to canonical forms are themselves valid beam paths).

### 3.6 Acoustic Cost Hallucination Filter

The acoustic cost filter is applied inside `CTCDecoder.decode` after beam finalization. It detects words that the lexicon trie was forced to "fight" for — words that cost the model a high per-character log-probability penalty to maintain:

```
costPerLetter = word.wordCosts[i] / max(1, word.count)
```

Where `wordCosts[i]` accumulates `(maxLogit - pChar)` for each character of word `i`. If the best character at time `t` was `"a"` but the beam needed `"s"` to stay on a trie path, the cost for `"s"` is `maxLogit - pChar("s")`, which is high.

**Threshold:** `costPerLetter > 4.5` → word is **rejected**.

This replaces any Levenshtein-based approach. The filter catches phonetic hallucinations (e.g., `"sampai"` forced from static noise) without requiring a second-pass edit-distance pass. It is applied on **all** inferences — both live preview and committed — so the UI does not jitter with hallucinated clinical terms.

### 3.7 Canonical Mapping

Two layers of canonical mapping are applied:

**1. Post-inference single-word mapping (`Wav2VecEngine.predict`):**

After `CTCDecoder.decode` returns, the result string is split by spaces. Each word is looked up in `decoder.dynamicMapping`. If a mapping entry exists, the canonical form replaces the decoded word. Applied to all words independently.

**2. Multi-word phrase mapping (`CTCDecoder.decode`):**

After word-boundary finalization, mapping keys are sorted by descending length and checked via `String.contains`. Longer phrases match first, preventing a shorter key from partially matching inside a longer phrase. This handles multi-word clinical contractions. Note that for missing teeth targeting, the token must exactly be `"gak ada"` (or `"tidak ada"`). Standalone words like `"gak"` or `"tidak"` do not trigger the `.missing` operation. This enforces **strict targeting**, ensuring missing status is only applied when explicitly intended rather than cascading automatically.

> [!NOTE]
> The `canonical_mapping.json` file is also used to expand the trie during model loading. Any key in the mapping that is not already in the lexicon is inserted into the trie as a valid word, ensuring the beam decoder can produce the variant spelling that the mapping then normalizes.

---

## 4. Whisper Pipeline (Alternative)

The Whisper path is active when `useOfflineWav2Vec == false`. It uses `TranscriptionEngine` (the app-wide WhisperKit singleton) via `TranscriptionViewModel`.

### 4.1 TranscriptionEngine

`TranscriptionEngine` is an `@MainActor @Observable` singleton that owns:
- `whisperKit: WhisperKit?` — Whisper large-v3-turbo (~632 MB). Loaded once at app launch.
- `vad: SileroVADEngine?` — Silero VAD v5.
- `speakerGate: SpeakerGateService?` — ECAPA-TDNN speaker verification + BSRNN TSE.

**Model sourcing (in order):**
1. Bundled at app root — detected by checking `AudioEncoder.mlmodelc` at `Bundle.main.resourceURL`.
2. Previously downloaded and cached at `Application Support/WhisperKitModels/` — validated by the existence of `AudioEncoder.mlmodelc` inside the cached folder.
3. Downloaded from HuggingFace (argmaxinc/whisperkit-coreml) with progress reporting and up to 3 retry attempts. Model variant: `openai_whisper-large-v3-v20240930_turbo_632MB`.

**Compute unit configuration:**

| Component | Compute units | Rationale |
|---|---|---|
| Mel spectrogram | `.cpuAndGPU` | Small, runs fast anywhere |
| Audio encoder | `.cpuOnly` | `.all` triggers ANE compile (~199 s on first launch); `.cpuOnly` cuts load to seconds with negligible runtime cost (encoder runs once per window) |
| Text decoder | `.cpuAndNeuralEngine` | ANE compile (~7 s) pays off — the decoder runs once per generated token in the autoregressive loop |

**Clinical vocabulary biasing:**

After loading, if a tokenizer is available, `SequenceBiasFilter` is installed as a `logitsFilter` on the text decoder:

```swift
kit.textDecoder.logitsFilters = [
    SequenceBiasFilter(sequences: ClinicalConfig.boostSequences(for: tokenizer)),
]
```

This stays active for the **entire session** — unlike `initialPrompt`, which was found to silently drop more than 50% of audio in multi-minute sessions and was removed.

### 4.2 Silero VAD

`SileroVADEngine` wraps **Silero VAD v5** (`SileroVAD.mlpackage`, ~2 MB). It processes 16kHz audio at **32 ms per chunk** (512 samples) and outputs a speech probability per chunk via a streaming LSTM.

**Usage modes:**
- **Batch mode (`speechTimestamps`):** Processes a full audio array and returns `[SpeechSegment]` (half-open sample index ranges). Used by `TranscriptionViewModel` to identify speech spans before Whisper transcription.
- **Streaming mode (`speechProbabilities`):** Returns per-chunk probability arrays for gating live Whisper windows.

VAD failure degrades gracefully: if `SileroVADEngine` fails to initialize, batch transcription falls back to whole-clip mode and live mode decodes every window.

### 4.3 Clinical Vocabulary Biasing

`ClinicalConfig` (in `Audio/Domain/ClinicalConfig.swift`) defines the clinical vocabulary and decoding configuration. It provides:
- `boostSequences(for:)` — returns token sequences representing clinical terms, used by `SequenceBiasFilter` to build per-step logit boost tables.
- `decodingOptions` — `DecodingOptions` struct for WhisperKit, including initial prompt, language, and temperature settings.

`SequenceBiasFilter` (in `Audio/Domain/SequenceBiasFilter.swift`) implements `LogitsFilter` from WhisperKit. At each decoder step, it adds a positive bias to token IDs that are part of a boosted clinical sequence, steering Whisper output toward the clinical vocabulary without forcing it.

### 4.4 Speaker Gate (TSE)

The speaker isolation layer is active in the Whisper path only. It consists of:

- **`SpeakerGate`** — CoreML wrapper around `SpeakerEmbedding_ECAPA.mlpackage`. Computes a 192-dim speaker embedding from 3.0 s of 16kHz mono audio. Shorter clips are zero-padded; longer are centre-cropped. Returns a `GateResult` with verdict (`.accept`/`.confirm`/`.reject`/`.tooShort`) and cosine distance to the enrolled centroid.
  - Accept threshold: `d < 0.675`
  - Confirm threshold: `d < 0.775`
  - Reject: `d ≥ 0.775`

- **`SpeakerGateService`** — Orchestrates enrollment from `voice_sample.wav` (the onboarding calibration recording) and per-segment verification. Maintains a multi-template centroid (average embedding over all enrollment clips) for improved speaker separation vs. single-template enrollment.

- **TSE pipeline** (`Audio/TSE/`) — BSRNN target source enhancement: `TSEEngine` → `TSEExtractor` → `TSEFeatures` → `TSEConfig`. Uses speaker conditioning derived from the enrolled centroid to perform beamforming-free single-channel speech enhancement before the audio reaches Whisper. This sub-system is handled by a separate peer module.

> [!NOTE]
> The speaker gate and TSE pipeline are **not** active in the Wav2Vec2 path. `Wav2VecViewModel.gateStatus` returns a stub `GateStatus` with `summary = "Speaker filter offline (Wav2Vec2)"`. The gate is present in the code and its status is surfaced to the UI, but it has no effect on the Wav2Vec2 transcription path.

---

## 5. AIVoiceViewModel Integration

`AIVoiceViewModel` owns both transcriber instances:

```swift
private let transcriber = TranscriptionViewModel()          // Whisper path
private let wav2VecTranscriber = Wav2VecViewModel()        // Wav2Vec2 path
```

`startLiveDictation()` reads `useOfflineWav2Vec` once at session start, wires callbacks on the appropriate transcriber, then starts it:

```swift
let useWav2Vec = UserDefaults.standard.bool(forKey: "useOfflineWav2Vec")

if useWav2Vec {
    wav2VecTranscriber.onLiveTranscript = { ... }
    wav2VecTranscriber.onConfirmedTranscript = { ... }
} else {
    transcriber.onLiveTranscript = { ... }
    transcriber.onConfirmedTranscript = { ... }
}

Task {
    if useWav2Vec { await wav2VecTranscriber.loadModel() }
    else          { await transcriber.loadModel() }
    TokenizerManager.shared.loadModel()
    // start the active transcriber
}
```

`stopLiveDictation()` stops the active transcriber, clears its callbacks, performs a final `isFinal: true` parse over any leftover text, then sets `committedCommands = commandHistory` (all cells become solid, no cells ghosted).

### 5.1 Live Preview vs. Committed Transcripts

Both STT paths fire two callbacks:

| Callback | Timing | Usage |
|---|---|---|
| `onLiveTranscript(fullText: String)` | Every intermediate inference (≥ 8000 new samples) | Updates `uncommittedTranscription`; triggers chart preview re-render. Not fed to `sessionParser`. |
| `onConfirmedTranscript(chunk: String)` | Every silence-committed segment | Calls `processConfirmedChunk(chunk)` — tokenizes the chunk and feeds it to `sessionParser`. Advances `committedCommandCount`. |

**In `Wav2VecViewModel`:**

- `onLiveTranscript` fires with `committedHistory.joined() + " " + liveResult` — the full running transcript including the in-progress segment.
- `onConfirmedTranscript` fires with `committedHistory.joined()` — only the silence-committed history.

**In `AIVoiceViewModel`:**

- `uncommittedTranscription` is derived by trimming `committedTranscription` from `fullText` in `onLiveTranscript`.
- `processConfirmedChunk(confirmed)` tokenizes `confirmed`, feeds tokens to `sessionParser?.consume(tokens:isFinal:false)`, then advances `committedCommandCount` to `sessionParser!.commands.count`.

### 5.2 Session Parser Lifecycle

```
startLiveDictation()
    → sessionParser = StatefulParser(configuration: getConfiguration())
    → committedCommandCount = 0

onConfirmedTranscript(chunk)
    → tokens = TokenizerManager.shared.tokenize(text: chunk, isFinal: false, currentMetric: sessionParser?.cursor.currentMetric)
    → sessionParser!.consume(tokens: tokens, isFinal: false)
    → committedCommandCount = sessionParser!.commands.count

stopLiveDictation()
    → leftover = uncommittedTranscription.trimmingCharacters(in: .whitespaces)
    → if !leftover.isEmpty:
        tokens = TokenizerManager.shared.tokenize(text: leftover, isFinal: true, currentMetric: sessionParser?.cursor.currentMetric)
        sessionParser!.consume(tokens: tokens, isFinal: true)
    → else:
        sessionParser!.consume(tokens: [], isFinal: true)
    → committedCommandCount = sessionParser!.commands.count
    → committedCommands = commandHistory   // remove all ghosting
    → sessionParser = nil
```

For the full `StatefulParser` specification, see [system_guide.md](system_guide.md).

---

## 6. Asset Reference

All STT model assets are stored in the `AI/` directory (gitignored) or downloaded at runtime.

### Wav2Vec2 assets

| File | Location | Used by |
|---|---|---|
| `Wav2Vec2_Indonesian_FP16.mlmodelc` | Bundle root or `AI/Wav2Vec_STT/` | `Wav2VecEngine` — FP16 Wav2Vec2 CTC model for Indonesian |
| `vocab.json` | Bundle root or `AI/Wav2Vec_STT/` | `CTCDecoder` — character-to-index mapping |
| `lexicon.txt` | Bundle root or `AI/Wav2Vec_STT/` | `PrefixTrie` — tab-delimited word list |
| `canonical_mapping.json` | Bundle root or `AI/Wav2Vec_STT/` | `CTCDecoder` — variant → canonical word substitutions |

`Wav2VecEngine` tries the bundle root first; if not found, falls back to the `AI/Wav2Vec_STT` subdirectory.

### Whisper / shared assets

| File | Location | Used by |
|---|---|---|
| `openai_whisper-large-v3-v20240930_turbo_632MB/` | `Application Support/WhisperKitModels/` (downloaded on first launch) or bundle root | `TranscriptionEngine` — WhisperKit STT model |
| `SileroVAD.mlpackage` | Bundle — `AI/` | `SileroVADEngine` — Silero VAD v5 (~2 MB) |
| `SpeakerEmbedding_ECAPA.mlpackage` | Bundle — `AI/` | `SpeakerGate` — 192-dim ECAPA-TDNN speaker embedder (~6 MB) |
| `EnrollmentEncoder_WeSpeaker.mlpackage` | Bundle — `AI/` | `SpeakerGateService` — enrollment encoding |
| `EnrollmentProjection_BSRNN.mlpackage` | Bundle — `AI/` | TSE pipeline |
| `SpeakerConditioning_BSRNN.mlpackage` | Bundle — `AI/` | TSE pipeline |
| `TSEFrontend_BSRNN.mlpackage` | Bundle — `AI/` | TSE pipeline |
| `TSEMasker_BSRNN.mlpackage` | Bundle — `AI/` | TSE pipeline |
| `TargetSeparator_BSRNN.mlpackage` | Bundle — `AI/` | TSE pipeline |
| `voice_sample.wav` | `Documents/voice_sample.wav` | `SpeakerGateService` enrollment (written by onboarding calibration) |
