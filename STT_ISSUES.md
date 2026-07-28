# STT — Bug & Improvement Checklist

Running tracker for speech-to-text issues (Layer 1 STT + Layer 2 rule-based parser).
Tick the box when resolved. See `TUNING.md` for where each knob lives.

_Last updated: 2026-07-28_

**Legend:** severity 🔴 high · 🟡 medium · 🟢 low · layer **STT** (audio→text) / **PARSE** (text→chart) / **PERF**
Status: `[ ]` open · `[~]` in progress · `[x]` done

---

## Open

- [~] **7. Tier 3 fires more duplicate commands** 🔴 · PARSE _(acute jump fixed; residual overflow open)_
  - **Cause:** Tier 3 parses the **full** transcript (confirmed + *unconfirmed* tail) every ~10 Hz. On repetitive charting audio Whisper repeats the value stream ("2 2 2" → "222 22"). The digit-split makes `222`→2,2,2, then the trailing **`22` was read as tooth 22** → cursor jumped.
  - [x] **Acute fix (cursor jump):** `VoiceTokenizer+Parsing.swift` — a doubled-digit number (`num % 11 == 0`, i.e. 11/22/…/88) arriving **immediately after a value `.number`** is treated as two repeated values, not a tooth jump. Verified: `"bukal 222 22"` / `"bukal 2 2 2 22"` → all values (no jump); `"gigi 22"`, `"22 gak ada"`, `"lanjut 22"`, `"…2 2 2 18"` still teeth.
  - [ ] **Residual:** the repeated digits still overflow the metric's 3 slots (e.g. 5 twos), so 1–2 extra values can spill onto the next tooth. Deeper fix = attack the root (volatile tail): (a) preview a bounded unconfirmed window, (b) commit-driven cursor (Tier 3b), or (c) cap values at `expectedValues` in the parser/flush. Pending: does the spill still show in practice after the jump fix?

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

- [~] **6. AI Mode chart less accurate than the Transcribe sheet** 🟡 · PARSE _(Tier 3 built — pending device verify)_
  - **Symptom:** the same speech gives a more accurate result in the Transcribe sheet than in the AI Mode chart, at ~the same latency.
  - **Root cause (verified in code):** STT is **identical** for both (shared model, same options, same streaming path). The difference is the *result each shows*:
    - Transcribe sheet renders `viewModel.transcript` = `clean(confirmed + unconfirmed)` — Whisper's **latest, most-refined** hypothesis.
    - AI Mode's **chart** is parsed from `onConfirmedTranscript` = `clean(confirmed)` **only**, then run through `VoiceCommandParser`. The AI Mode *panel text* (`liveTranscription`) is the same full string as Transcribe — only the chart uses the narrower confirmed input.
    - So the chart sees (a) an earlier, confirmed-only hypothesis (no unconfirmed-tail refinements) and (b) a second lossy layer (`clean` + parser).
  - [x] **Mitigation applied:** reverted `requiredSegmentsForConfirmation` to 2 so confirmed text is more stabilized before the chart commits.
  - [x] **Real fix — Tier 3 BUILT:** the AI Mode chart is now driven by the **full** live transcript (preview), so its input matches the Transcribe sheet exactly; a confirmed-only pass marks which cells are finalized and the rest render **ghosted** (0.4 opacity). Files: `AIVoiceViewModel` (preview→`commandHistory`, confirmed→`committedCommands`), `ChartProcessor.differingCells`, `ChartSelectionModel.ghostedCells`, `ChartDashboard.recomputeChart`, `ToothColumnView`/`ToothRowViews` (per-site ghosting). **Compiles clean; needs a device run to verify the ghosting visually.** Remaining gap vs Transcribe is now only parser/clean fidelity (#1–5), never STT.

- [~] **2. Latency — live transcription still feels slow** 🔴 · PERF _(Tier 1 applied; Tier 2 reverted; Tier 3 built; measuring pending)_
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
  - [x] ~~**Tier 2 — `requiredSegmentsForConfirmation` 2 → 1**~~ **REVERTED to 2** — this fed the AI Mode chart a rougher (earlier-frozen) hypothesis than the Transcribe sheet shows; see #6. Accuracy chosen over ~1 phrase of latency (which felt the same anyway). Tier 3 is the way to get both.

  ### Still to do
  - [x] **Instrumentation added** — true per-decode `[RTFx] decode: N.NNx realtime (…s audio in …s wall)` printed in `AudioStreamTranscriber` (local WhisperKit pkg) right around the decode call. This is the raw decode-speed signal (audio-seconds / wall-seconds), distinct from the app's throughput `[RTF] live:` log.
  - [ ] **Measure, don't guess.** Run and read `[RTFx] decode:` — >1.0× = model keeps up (lag is confirmation/UI side → Tier 2/3); <1.0× = model is the wall (→ smaller model / compute units / Tier 3b silence-commit).
  - [ ] Verify model is preloaded at launch ("Model ready" before first use, via `TranscriptionEngine`).
  - [ ] Measure on **target iPad hardware**, not the Mac — "Designed for iPad" uses the macOS HAL and can mislead.
  - [ ] Compute units (`TranscriptionEngine.swift` L63–65): try encoder/decoder ANE vs GPU on device.
  - [ ] Model size (~1 GB turbo): a smaller/more-quantized live model cuts decode at an accuracy cost. **Decision needed: accuracy headroom?**

  ### Tier 3 — "instant but safe" — ✅ BUILT (see #6)
  Optimistic preview + confirmed commit, leveraging parser idempotency. The chart is driven by the **full** live transcript (preview) so it's as responsive/accurate as the Transcribe sheet; not-yet-confirmed cells render **ghosted** (0.4 opacity) and solidify as Whisper confirms. Implemented via `AIVoiceViewModel` (`commandHistory`=preview / `committedCommands`=confirmed), `ChartProcessor.differingCells`, `ChartSelectionModel.ghostedCells`, `ToothColumnView`/`ToothRowViews`. Compiles clean; **pending device verify** of the ghost visuals + flicker feel.
  - [ ] **Tier 3b — commit on silence (not built):** charting is dictated in bursts; WhisperKit already has VAD (`useVAD`/`silenceThreshold`). Finalizing the current utterance at a detected pause would tighten the confirm timing further. Only worth it if `[RTFx]` shows the model keeps up and confirmation lag is still the felt bottleneck.

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

- [x] **8. "gak ada" wrongly corrected to "pada"** 🔴 · STT · _2026-07-28_
  - **Cause:** when STT merges "gak ada" (tooth missing) into one token (`gada`/`gaada`/`gakda`/`gadda`…), `ClinicalConfig.clean`'s Levenshtein snap sends it to **"pada"** — verified: `pada` precedes `ada` in `lexiconList` and is 1 edit from `gada`, so the first-closest tie-break picks it. `pada` = the "at" action, so the tooth never gets marked missing.
  - **Fix:** `phraseFixes` regex `\bgak?\s?a?d+a+\b → "gak ada"` (runs before the snap). Verified to catch `gada/gaada/gakada/gakda/gadda/gadaa/ga da` and leave `pada/ada/tidak ada/dada` untouched.

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
