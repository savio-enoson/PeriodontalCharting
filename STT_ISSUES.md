# STT — Bug & Improvement Checklist

Running tracker for speech-to-text issues (Layer 1 STT + Layer 2 rule-based parser).
Tick the box when resolved. See `TUNING.md` for where each knob lives.

_Last updated: 2026-07-27_

**Legend:** severity 🔴 high · 🟡 medium · 🟢 low · layer **STT** (audio→text) / **PARSE** (text→chart) / **PERF**
Status: `[ ]` open · `[~]` in progress · `[x]` done

---

## Open

- [ ] **4. "furkasi" (furcation) mishandled** 🟡 · STT/PARSE _(needs repro)_
  - **Symptom:** furcation dictation doesn't chart correctly.
  - **Confirmed NOT the tokenizer:** `"furkasi 2"`, `"furkasi dua"`, `"gigi 46 furkasi 2"` all tokenize correctly → `metric(furcation,×1) num(2)`. So the fault is upstream (STT misheard it into a non-corpus word) or downstream (how the parser applies the furcation value).
  - **Existing coverage:** tokenizer word-map `purkasi/furkasion/forkasi → furkasi`; `ClinicalConfig.phraseFixes` `4 cation/furukasih/forcation/furukashi → furcation`; both `furkasi`+`furcation` in lexicon.
  - **⏳ Need from user:** one real transcript where it fails + expected vs actual, so we can tell if it's a new mishear variant (→ add to phraseFixes) or a parser-application bug.

- [~] **5. STT word corruptions (whack-a-mole) — repair layer** 🟡 · STT _(pattern established)_
  - **Insight:** per-token Levenshtein (in `ClinicalConfig.clean`) can only snap ONE unknown token to ONE lexicon word. It **cannot** fix multi-word corruptions like `"di setob dan" → "disto bukal"` (3→2 words, >2 edits). Those need a **phrase-level regex** in `ClinicalConfig.phraseFixes`.
  - [x] **"minus satu" → "minosato"/"minusatu"** (recession value −1 lost as one non-corpus word). Fixed via `phraseFixes` regex `\bmin[ou]sat[ou]o?\b → "minus satu"` — verified to catch the merged forms and leave correct `minus`/`minus satu`/`minus dua` untouched. Sign still comes from the metric (`resesi`), which is intended (the `minus` word is inert by design: `Flush.swift` uses `abs(n) * multiplier`).
  - [ ] `"di setob dan" → "disto bukal"` — add a `phraseFixes` regex (per-token Levenshtein won't do it). Need the observed variants.
  - [ ] Extend `minus` repair to sibling numbers (`minus dua/tiga/...`) as their corruptions are observed.

- [~] **2. Latency — live transcription still feels slow** 🔴 · PERF _(Tier 1+2 applied; measuring / Tier 3 pending)_
  - **Symptom:** noticeable lag between speaking and text/chart updating.

  ### Analysis / reasoning (why it's slow)
  The `VoiceCommandParser` is **not** the bottleneck (µs-scale regex + linear token walk). Perceived latency is **Whisper confirmation lag + raw decode cost**. Two `AudioStreamTranscriber` knobs (local WhisperKit package) dominate:
  | Knob | Was | Effect |
  |------|-----|--------|
  | `requiredSegmentsForConfirmation` | 2 | A segment confirms only after **2 more** segments exist after it. Chart commits on confirmed text → lags ~2 spoken phrases. |
  | `maxRetainedAudioSeconds` | 60 | Streamer re-decodes the **entire** retained buffer every ~100 ms tick. 60 s = two 30 s Whisper windows per tick. |

  **Key safety net:** the parser is **idempotent** — it re-derives the whole `commandHistory` from the full transcript every call, so a briefly-wrong value **self-corrects** and never sticks. This is what makes "faster commit" safe. The fundamental trade: commit earlier = faster but riskier; commit later = safer but laggier.

  ### Applied
  - [x] **Tier 1 — buffer window 60 → 32 s** (`TranscriptionViewModel.swift`, live init). Keeps a full 30 s decode window (+margin) but ~halves per-tick decode; retains less silence → also *reduces* runaway risk. Do NOT go below ~30 s (truncates Whisper's window). _Pure latency win, no misfire impact._
  - [x] **Tier 2 — `requiredSegmentsForConfirmation` 2 → 1** (live init). Removes a whole phrase of confirmation lag. Low, reversible risk (short charting utterances rarely revised; idempotent re-parse absorbs corrections). **Revert to 2 if segments freeze on wrong values.**

  ### Still to do
  - [x] **Instrumentation added** — true per-decode `[RTFx] decode: N.NNx realtime (…s audio in …s wall)` printed in `AudioStreamTranscriber` (local WhisperKit pkg) right around the decode call. This is the raw decode-speed signal (audio-seconds / wall-seconds), distinct from the app's throughput `[RTF] live:` log.
  - [ ] **Measure, don't guess.** Run and read `[RTFx] decode:` — >1.0× = model keeps up (lag is confirmation/UI side → Tier 2/3); <1.0× = model is the wall (→ smaller model / compute units / Tier 3b silence-commit).
  - [ ] Verify model is preloaded at launch ("Model ready" before first use, via `TranscriptionEngine`).
  - [ ] Measure on **target iPad hardware**, not the Mac — "Designed for iPad" uses the macOS HAL and can mislead.
  - [ ] Compute units (`TranscriptionEngine.swift` L63–65): try encoder/decoder ANE vs GPU on device.
  - [ ] Model size (~1 GB turbo): a smaller/more-quantized live model cuts decode at an accuracy cost. **Decision needed: accuracy headroom?**

  ### Tier 3 — "instant but safe" (design sketch, not yet built)
  The proper fix for responsiveness *without* misfires, leveraging parser idempotency:
  - **Optimistic preview + confirmed commit:** parse **confirmed + unconfirmed** text for a live *preview* (cursor + pending values shown but visually "unlocked"); only **lock/commit** a cell when its segment confirms **or** a boundary passes (`lanjut`/`selesai`, or a pause). Preview tracks the voice instantly; because the chart re-derives from full text, any misfire is transient and self-erasing — committed data stays clean.
  - **Tier 3b — commit on silence:** charting is dictated in bursts. WhisperKit already has VAD (`useVAD`/`silenceThreshold`); finalizing the current utterance at a detected pause gives near-instant commit at natural boundaries with no misfire.
  - **Where:** split AI Mode state into `previewCommands` (from full text) vs `committedCommands` (from confirmed/boundary) in `AIVoiceViewModel`; `ChartDashboard` renders committed as solid, preview as ghosted. Requires touching the confirmed-chunk gate in `TranscriptionViewModel` to also expose the unconfirmed tail.

  ### Misfire guards to preserve regardless
  - Commit off **confirmed** text (Tier 3's lock step).
  - Don't bypass the tokenizer `expectedValues`/deferral (stops half-spoken phrases committing early).
  - Keep STT-side `SequenceBiasFilter.maxImmediateRepeats` + `suppressTokens`.

- [ ] **3. Spelling variants slip through — "mesyobukal" not normalized** 🟡 · STT/PARSE
  - **Symptom:** "mesyobukal" (and similar compound mis-hears) reach the parser un-normalized, so the site is missed.
  - **Root cause:** normalization only covers specific forms — `VoiceTokenizer+Parsing.swift` maps standalone `misio/mesyio/mesyu/meso/mezzo` → `mesio` (L34) and `mesiobukal` → `mesio bukal` (L16), but **not the compound mis-hear `mesyobukal`**. `ClinicalConfig.clean`'s Levenshtein snap is per-token and won't reach it (too many edits, and `mesiobukal` isn't in the lexicon).
  - **Fix ideas:**
    - [ ] Add compound variants to the tokenizer normalization (`mesyobukal`/`mesyubukal`/… → `mesio bukal`, and disto equivalents).
    - [ ] Better: normalize the stem **before** the compound split — map `mesyo`/`mesyu`/`misio` → `mesio` as a substring so any `<variant>bukal|lingual|palatal` compound is caught in one rule.
    - [ ] Consider a `phraseFix` regex in `ClinicalConfig.clean` so both the displayed transcript and the parser see the correction.
    - [ ] Collect the recurring mis-spellings from real sessions and batch-add them.

---

## Resolved

- [x] **1. Multi-digit runs not split — "333" fed as one value** 🔴 · PARSE
  - **Fix:** `NLP/Tokenizer/VoiceTokenizer+Parsing.swift` — in the number branch, any number `≥ 100` is split into individual single-digit `.number` tokens. No valid tooth id (11–48) or per-site value is ≥ 100, so this is unambiguous and leaves 2-digit tooth ids untouched.
  - **Verified:** real tokenizer, `isFinal: true` — `"poket 333"` → `metric(probingDepth) num(3) num(3) num(3)` (identical to `"poket 3 3 3"`); `"225"` → `2,2,5`; `"gigi 18"` → `tooth(18)` (unchanged); `"3231"` → `3,2,3,1`.
  - **Not done (follow-ups, low priority):**
    - [ ] 2-digit ambiguity: "3 3" heard as "33" still becomes tooth 33 (11–98 always parsed as a tooth). Out of scope for this fix.
    - [ ] Per-metric upper-bound sanity check (e.g. drop/flag a probing depth > 12) — separate validation concern.

_(move items here with the box ticked and a one-line note on the fix + commit)_

---

## Template for new items

```
- [ ] **N. Short title** 🔴/🟡/🟢 · STT/PARSE/PERF
  - **Symptom:**
  - **Repro:**
  - **Root cause:** (file + symbol)
  - **Fix ideas:**
    - [ ]
```
