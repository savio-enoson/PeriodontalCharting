# Tuning Guide — STT & Rule-Based Charting

This app has **two independent tunable layers**. Know which one you're changing:

```
  🎙️ audio ──▶ [ 1. Whisper STT ] ──▶ text ──▶ [ 1e. ClinicalConfig.clean ] ──▶ cleaned text
                                                                                      │
                                                                                      ▼
                                          chart cells ◀── [ 2. Rule-based parser ] ◀──┘
```

- **Layer 1 (STT)** turns audio into Indonesian text. Tune it when words are *mis-heard* (wrong/garbled text).
- **Layer 2 (rule-based parser)** turns text into chart commands. Tune it when the text is *correct* but the chart does the wrong thing (wrong tooth/site/metric/value).
- The **cleanup step** (`ClinicalConfig.clean`) sits between them and is the natural place to repair systematic mis-hearings before parsing.

> Line numbers below are anchors and will drift as you edit — trust the symbol names / snippets over the exact line.
> All paths are relative to `PeriodontalCharting/`.

---

## 1. Speech-to-Text (Whisper)

### 1a. Which model & how it loads — `Services/TranscriptionEngine.swift`
Single shared model, preloaded at launch (see `App/PeriodontalChartingApp.swift`).

| Knob | Where | Notes |
|------|-------|-------|
| Bundled model name | `bundledModelName` (L33) | Loaded from the app bundle root — the `.mlmodelc` folders shipped in the target. To swap models, replace those bundled CoreML files **and** this string. |
| Download model name | `networkModelName` (L34) | Used only when no bundled model is found. A HF `argmaxinc/whisperkit-coreml` folder name (underscore before `turbo`). |
| Compute units | `melCompute` / `audioEncoderCompute` / `textDecoderCompute` (L63–65) | Encoder on GPU = faster/consistent loads; decoder on ANE = fast inference. Changing these trades load time vs runtime speed. |

**To change the STT model entirely:** drop the new `*.mlmodelc` bundles into the target (same flattened-to-root layout), update `bundledModelName`, and confirm it loads (`statusMessage` becomes "Model ready …").

### 1b. Decoding behavior — `Domain/ClinicalConfig.swift` → `decodingOptions(for:)`
The `DecodingOptions` returned at L192–203 is shared by **both** batch and live modes (and any eval harness), so tune here once.

| Knob | Line | Current | Effect / when to change |
|------|------|---------|-------------------------|
| `language` | L193 | `"id"` | Force Indonesian. Change if dictation language changes. |
| `temperature` / `temperatureIncrementOnFallback` | L194–195 | `0.0` / `0.2` | Greedy decode; fallback bumps on failure. |
| `temperatureFallbackCount` | L196 | `2` | More = more retries on hard segments (slower). |
| `compressionRatioThreshold` | L200 | `8.0` | **Loosened** for legit repetitive charting ("bukal 2 bukal 2 …"). Lower → more aggressive repeat-loop guard (risks re-decoding correct repeats); higher/`nil` → lets true runaways through. |
| `logProbThreshold` | L201 | `-1.5` | Lower (more negative) keeps more low-confidence number segments; raise to drop shaky output. |
| `noSpeechThreshold` | L202 | `0.9` | High so quiet bare numbers aren't dropped as silence. Lower if hallucinations appear in true silence. |
| `suppressTokens` | via `suppressWords` | — | See 1c. |

> ⚠️ `promptTokens`/`initialPrompt` are intentionally **not** set — WhisperKit re-injects a static prompt into every 30 s window and it wrecked multi-minute recordings. Vocabulary biasing is done via `SequenceBiasFilter` instead (1c). Read the long NOTE at L175–190 before reconsidering.

### 1c. Vocabulary bias & suppression — `Domain/ClinicalConfig.swift` + `Domain/SequenceBiasFilter.swift`
This is the highest-leverage STT-accuracy tuning. Words are stored as **strings** and encoded against the loaded tokenizer at runtime — never hardcode token IDs.

**Boost (make clinical words more likely):**
| List | Line | Bias tier | Use for |
|------|------|-----------|---------|
| `directionalBoostWords` | L40 | `directionalBoostBias = 20.0` (L60) | Strongest push — acoustically confusable stems (mesio/disto…). |
| `generalBoostWords` | L46 | `generalBoostBias = 10.0` (L61) | Core clinical words (gigi, bukal, BOP, resesi…). |
| `lessCommonBoostWords` | L51 | `lessCommonBoostBias = 6.0` (L62) | Rarer terms (furkasi, margin, mobility…). |

- **Add a term:** put the word in the right tier list. That's it — it's encoded + biased automatically.
- **Tune strength:** adjust the three bias floats. Higher = stronger nudge but more risk of runaway repeats (guarded — see below).

**Suppress (make mis-hears impossible):** `suppressWords` (L66). Add known hallucinations / mis-transcriptions here (they're hard-masked to −∞, i.e. never selectable — see the NOTE at L96–107 about this being stricter than the Python PoC's finite −20).

**Anti-runaway guard:** `SequenceBiasFilter` init `maxImmediateRepeats` (default `2`, L62 of that file). If a boosted word detonates into "plaque plaque plaque…", lower it; if the speaker legitimately repeats a word more times and it's getting under-boosted, raise it. `maxLogitMagnitude` (L62) is a Float16 overflow clamp — leave it.

### 1d. Post-STT text cleanup — `Domain/ClinicalConfig.swift` → `clean(_:)`
Runs on the transcript **before** the parser. Repair systematic STT errors here rather than teaching the parser every mis-spelling.

| Table | Line | What it does |
|-------|------|--------------|
| `phraseFixes` | L210 | Regex repairs for multi-word corruptions ("di situ" → "disto", compound-site spacing…). Ordered; applied first. |
| `disfluency` | L252 | Words dropped entirely (uh/eh + subtitle-credit hallucinations). |
| `textToNum` | L265 | Indonesian number-words → digits, incl. dozens of "dua"→"2" mishears. |
| `lexiconList` | L284 | Correct terms that must never be flagged; also the target set for the fuzzy Levenshtein snap (unknown alpha token within 2 edits → nearest lexicon word). The snap itself is in `clean(_:)` at L298. |

> This is also the cleanest single place to add a spoken-form correction that both the STT display **and** the parser will see.
>
> **Important:** per-token Levenshtein can only snap ONE unknown token to ONE lexicon word — it **cannot** fix multi-word corruptions (e.g. `"di setob dan" → "disto bukal"`, or `"minus satu"` merged into one word `"minosato"`). Those need a **`phraseFixes` regex**. Example already in place: `\bmin[ou]sat[ou]o?\b → "minus satu"`.

### 1e. Segmentation (VAD) — `Services/SileroVADEngine.swift`
Silero VAD finds speech spans (batch mode packs them into ≤30 s chunks; live mode uses WhisperKit's own VAD).

| Knob | Where | Effect |
|------|-------|--------|
| `speechTimestamps(...)` defaults | `SileroVADEngine.swift` L138–142 (`threshold 0.5`, `minSpeechDurationMs 250`, `minSilenceDurationMs 100`, `speechPadMs 30`) | Lower `threshold` catches quieter speech (more false positives); `minSilence`/`minSpeech` control how eagerly it splits. |
| Batch call overrides | `ViewModels/TranscriptionViewModel.swift` L211–212 (`minSpeechDurationMs: 250, minSilenceDurationMs: 500`) | The actual values used for file/upload transcription. |

### 1f. Live-streaming behavior — `ViewModels/TranscriptionViewModel.swift` (live init in `launchStreamTranscriber`)
| Knob | Current | Effect |
|------|---------|--------|
| `maxRetainedAudioSeconds` | **32** | Rolling live buffer cap. The streamer re-decodes the *whole* retained buffer each ~100 ms tick, so this ~= per-tick decode cost. Keep ≥30 (Whisper's own window); higher = more context + memory + latency. |
| `requiredSegmentsForConfirmation` | **2** | A segment confirms only after N following segments. Lower = faster confirmation but rougher (less-stabilized) confirmed text; higher = more accurate but laggier. Drives what the AI Mode chart *commits*. |
| Live event hooks | `onLiveTranscript` (full text) / `onConfirmedTranscript` (confirmed-only, fires when `confirmedSegments.count` advances) | AI Mode (Tier 3) parses the **full** text for the live chart *preview* and the confirmed-only text to mark which cells are finalized — see Layer 2 / AI Mode below. |

**Latency:** the true per-decode speed prints as `[RTFx] decode: N.NNx realtime …` (added in `AudioStreamTranscriber`, local WhisperKit pkg). >1.0× = model keeps up; <1.0× = it's the bottleneck. See `STT_ISSUES.md` #2 for the full latency-vs-accuracy analysis (Tier 1/2/3).

---

## 2. Rule-Based Charting System (text → chart commands)

Text that's already correct is turned into chart annotations here. Tune this when the **words are right but the chart is wrong**.

### 2a. Word → meaning mapping — `NLP/Tokenizer/VoiceTokenizer+Parsing.swift` ⭐ (the big one)
`tokenize(text:isFinal:)` is the heart of the rule system. Everything spoken becomes a `VoiceToken` here.

| What | Line | To tune |
|------|------|---------|
| Compound-phrase normalization | L14–28 (`replacingOccurrences`) | Map spoken phrases to canonical forms ("bleeding on probing" → "bop", compound sites…). Add new phrasings here. |
| Mis-spelling normalization | L32–52 (`words = words.map { switch … }`) | Snap common STT variants to canonical words ("bocal"/"buka" → "bukal"). **Add a mis-heard word variant here.** |
| Values-per-site logic | `updateExpectedValues(...)` L57–78 | How many numbers a site/metric expects (single-site anatomy = 1, whole-side = 3, BOP/plaque = 0…). Change if a metric's expected value count changes. |
| Missing / next / all keywords | L94–101 (`gak ada`, `missing`, `semua`, `lanjut`/`selesai`…) | Synonyms for control actions. |
| Metric keywords | L212–219 | **Which spoken words map to which metric** — `resesi`/`kemunduran` → gingival margin (×−1), `poket`/`probing`/`kedalaman` → probing depth, `bop`/`berdarah` → bleeding, `plaque`/`plak`, `kegoyangan`/`mobilitas`/`mobility`, `furkasi`/`furcation`, `implan`/`implant`. Add a synonym by extending the `w == "…" || …` list. |
| Number words | `VoiceTokenizer.swift` L6 (`numberWords`) | Indonesian digit words 0–10. |
| Multi-digit split | number branch, `num >= 100` | A concatenated STT number (`"333"` for a spoken "3 3 3") is split back into single-digit `.number` values — no valid tooth id (11–48) or per-site value is ≥100. |

### 2b. Controlled vocabulary (enums) — `NLP/Models/VoiceToken.swift`
`ActionType` and `AnatomyType` raw values are the canonical spoken forms. Add a genuinely new *action* or *anatomy site* here first, then handle it in `tokenize`.

### 2c. Charting order & direction — `Configuration/ChartingConfiguration.swift`
Not word-level — this controls **cursor traversal**: jaw/aspect order, per-quadrant left↔right direction, and the tooth-number sequences (`getSequence(for:aspect:)`). Tune when auto-advance walks teeth in the wrong order/direction. (This config is user-editable via the Settings/Onboarding screen and persisted in `UserDefaults` under `"ChartingConfiguration"`.)

### 2d. Parser state machine — `NLP/Parser/VoiceCommandParser*.swift` (advanced)
The flow logic that consumes tokens into `AnnotationCommand`s: `+Parse` (main loop), `+Lookahead` (deferring/merging decisions), `+Flush` (committing pending values). Change here only for *behavioral* logic (e.g. how ranges "dari … sampai …" resolve, when a block auto-commits) — not for vocabulary.
- **Sign of values:** `+Flush` uses `abs(n) * currentMetricMultiplier`, so a value's sign comes from the **metric** (`resesi` → ×−1, `margin`/`gingival` → ×+1), *not* the spoken word "minus" (which is inert). Recession is negative because of `resesi`.
- Note a debug `print` in `activeSelection.didSet` (VoiceCommandParser.swift L5) worth silencing for production.

### 2e. AI Mode live rendering — preview vs committed (Tier 3)
AI Mode drives the chart from the **full** live transcript (preview) so it's as accurate as the Transcribe sheet, and marks not-yet-confirmed cells as **ghosted** (0.4 opacity).
- `AIVoiceViewModel`: `commandHistory` = preview (from `onLiveTranscript`), `committedCommands` = confirmed-only (from `onConfirmedTranscript`). `committedCommands == nil` ⇒ no ghosting (simulation / `parseInstant`).
- `ChartProcessor.differingCells(preview:committed:)` → `ChartSelectionModel.ghostedCells` → per-site dimming in `ToothColumnView`/`ToothRowViews`.
- To change the ghost look, edit the `.opacity(… ? 0.4 : 1)` in `ToothRowViews.swift`.

---

## How to test your tuning

| Path | Good for |
|------|----------|
| **AI Mode → mic button** (`AIListeningView`) | End-to-end: real audio → STT → parser → chart. Chart tracks the live (preview) transcript; unconfirmed cells render **ghosted** until confirmed. Tests Layer 1 + 2 together. |
| **AI Mode → ▶ debug simulation** | Feeds a canned transcript (`TestTranscripts.swift`) word-by-word into the parser at a fake WPM — tests **Layer 2 only**, no audio, no ghosting. |
| **Debug menu → `parseInstant`** (`Debug/SelectionDebugMenu.swift`) | Parse a full transcript instantly — fastest Layer-2 iteration. |
| **Transcribe sheet / TestView** (`TestView.swift`) | Live mic (Transcribe) or batch file/upload (TestView) — shows raw transcript, tests **Layer 1** (STT + cleanup) without the parser. |

**Rule of thumb:** if the *transcript text* is wrong → tune Layer 1 (§1c/§1d most often). If the *text is right but the chart is wrong* → tune Layer 2 (§2a most often).
