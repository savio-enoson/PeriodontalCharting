# STT — Bug & Improvement Checklist

Running tracker for speech-to-text issues (Layer 1 STT + Layer 2 rule-based parser).
Tick the box when resolved. See `TUNING.md` for where each knob lives.

_Last updated: 2026-07-27_

**Legend:** severity 🔴 high · 🟡 medium · 🟢 low · layer **STT** (audio→text) / **PARSE** (text→chart) / **PERF**

---

## Open

- [ ] **2. Latency — live transcription still feels slow** 🔴 · PERF
  - **Symptom:** noticeable lag between speaking and text/chart updating.
  - **Where to look / try:**
    - [ ] Confirm the model is actually **preloaded at launch** (should be, via `TranscriptionEngine` — check "Model ready" appears before first use, not on first tap).
    - [ ] Read the `[RTF] live:` console logs (`TranscriptionViewModel` callback) — is decode real-time (>1.0×) or falling behind?
    - [ ] `maxRetainedAudioSeconds: 60` (`TranscriptionViewModel.swift` L~334) — the streamer re-processes the retained buffer each tick; try a smaller window (e.g. 30 s) and measure.
    - [ ] Compute units (`TranscriptionEngine.swift` L63–65) — try `textDecoderCompute: .cpuAndNeuralEngine` vs `.cpuAndGPU`; measure load vs runtime tradeoff on the actual device.
    - [ ] Model size — the ~1 GB `large-v3_turbo_954MB` build. A smaller/more-quantized build would cut decode latency at some accuracy cost. **Decision needed: is the accuracy headroom there?**
    - [ ] Confirmation lag: chart only updates on **confirmed** chunks (by design, per the last change). If perceived lag is chart-side, revisit how many segments Whisper needs before confirming.
    - [ ] Running as "Designed for iPad" on Mac uses the macOS HAL — verify latency on the **target iPad hardware**, not just the Mac, before optimizing.
  - **Fix ideas:**
    - [ ] Measure first (RTF logs), then pick the biggest lever — don't tune blind.

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
