# STT — Bug & Improvement Checklist

Running tracker for speech-to-text issues (Layer 1 STT + Layer 2 rule-based parser).
Tick the box when resolved. See `TUNING.md` for where each knob lives.

_Last updated: 2026-08-03_

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
  - [x] **"disto bukal" → "di bop"** (site compressed by STT; `di`=at-action, `bop`=BLEEDING metric, so the site would mark bleeding). Fixed via `phraseFixes` regex `\bdi\s*bop\b → "disto bukal"` — verified vs tokenizer (`"di bop 17"` → bleeding+at; after fix → `anat(disto bukal) tooth(17)`) and no false positives on `bop di bukal` / `di bukal`.
    - [x] **Parser-level backstop for the acoustic variants** (`di bob`/`the bop`/… that the exact `\bdi\s*bop\b` regex misses). Added an **adjacency** rule in `VoiceTokenizer+Parsing.swift` (top of the token loop, before the `di`→at / `bop`→bleeding rules): a `di`-family fragment (`di/the/de/dee/dih`) immediately followed by a `bop`-family fragment (`bop/bob/pop/bup`) → `.anatomy(.distoBuccal)`, consuming both. Safe because a legit `di` is always followed by a *site* word (never `bop`) and a real BOP command has the other word order (`bop di bukal`) — grammar the ClinicalConfig regex can't see. Fuzzy sets so new variants are one-line adds. _This handles the case where the SITE word itself got absorbed into "bop"; the general recovery below handles the case where the site word survives._
  - [x] **Generalized directional-stem recovery (stops the whack-a-mole for BOTH disto AND mesio)** — replaces the ever-growing `disto`/`mesio` variant regexes in `ClinicalConfig.phraseFixes` with one **position-based** rule. **Insight:** the SITE word (`bukal`/`lingual`/`palatal`) is reliably transcribed; only the STEM gets mangled (`di situ`/`justru`/`stok`/`di slow`/`misi`/`mili`/…). So any word sitting immediately before a site word that the tokenizer does **not** recognize is a mis-heard stem — resolve direction by leading sound (**`m` → mesio, else `disto`**) and swallow a leading `di`/`the` fragment so `di situ bukal` leaves no stray `di` (which would tokenize as the `at` action and spuriously start post-targeting). A `words`-array preprocessing pass in `VoiceTokenizer+Parsing.swift` (runs **before** the main loop, i.e. before `di` becomes an action). Guarded by an allowlist of words that legitimately precede a site (real directionals, `di`/`pada` at-actions, metrics, region words like `bagian`) + a number check, so `di bukal`/`pada bukal`/`3 bukal`/`bagian bukal`/`poket bukal` are untouched. **Verified** on 15 cases (`di situ/slow bukal`, `justru`, `stok`, `misi`, `mili`, `situl palatal`, `gigi 16 di situ bukal 3`, and all the must-not-change ones). New variants now need **zero** code — they fall out of the positional rule.
  - [x] **Fused directional compounds** (`mesiyobukal`, `distobuqal` — stem+site glued into ONE token with the site half fuzzed). The positional recovery above only fires on a SEPARATE site token, so these slipped through. Added a **compound splitter** just before it (`VoiceTokenizer+Parsing.swift`): peel a fuzzy trailing site suffix (`bukal/buccal/bucal/buqal/…`, `lingual/lingval/…`, `palatal/…`) off any **m/d-initial** token with a ≥2-char prefix, restore the canonical site, and hand the stem prefix to the positional pass. So `mesiyobukal`→`mesio bukal`, `distobuqal`→`disto bukal`, while `bukal`/`distal`/`mesial` are never split. **Verified** on 11 cases incl. mixed sentences (`mesiyobukal 3 distobuqal 2` → `mesio bukal 3 disto bukal 2`). _Resolves the compound half of #3._
  - [ ] `"di setob dan" → "disto bukal"` — mostly obsoleted by the generalized recovery above (`setob` before a site → `disto`); revisit only if a variant with **no** trailing site word shows up.
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
  - [x] **Tier 3b — commit on silence — BUILT (pending device feel-test):** `[RTFx] decode:` measured **10–50× realtime** on device (only the cold first tick was 1.46×), so the model is NOT the wall — confirmation cadence is (the jittery `[RTF] live:` 0.2–3.7×). That green-lit committing more aggressively. Added `finalizeOnSilence` to the local WhisperKit fork (`AudioStreamTranscriber.swift`): in the VAD no-voice branch, `finalizeUnconfirmedOnSilence()` promotes the pending unconfirmed tail to confirmed (advances `lastConfirmedSegmentEndSeconds` so the next decode clips past it — no dup/re-decode). Enabled from the app (`TranscriptionViewModel.launchStreamTranscriber`, `finalizeOnSilence: true`) with `requiredSegmentsForConfirmation` kept at **2**. Net: full 2-segment buffer (accuracy) DURING speech, instant solidify at each pause. Builds clean (app + package). **Needs a device run to confirm the feel.**

  ### Misfire guards to preserve regardless
  - Commit off **confirmed** text (Tier 3's lock step).
  - Don't bypass the tokenizer `expectedValues`/deferral (stops half-spoken phrases committing early).
  - Keep STT-side `SequenceBiasFilter.maxImmediateRepeats` + `suppressTokens`.

- [~] **3. Spelling variants slip through — "mesyobukal" not normalized** 🟡 · STT/PARSE _(largely covered by #5's generalized directional-stem recovery — the un-recognized stem before a site word now resolves positionally; keep open only for compounds with NO separable site word)_
  - **Symptom:** "mesyobukal" (and similar compound mis-hears) reach the parser un-normalized, so the site is missed.
  - **Root cause:** normalization only covers specific forms — `VoiceTokenizer+Parsing.swift` maps standalone `misio/mesyio/mesyu/meso/mezzo` → `mesio` (L34) and `mesiobukal` → `mesio bukal` (L16), but **not the compound mis-hear `mesyobukal`**. `ClinicalConfig.clean`'s Levenshtein snap is per-token and won't reach it (too many edits, and `mesiobukal` isn't in the lexicon).
  - **Fix ideas:**
    - [ ] Add compound variants to the tokenizer normalization (`mesyobukal`/`mesyubukal`/… → `mesio bukal`, and disto equivalents).
    - [ ] Better: normalize the stem **before** the compound split — map `mesyo`/`mesyu`/`misio` → `mesio` as a substring so any `<variant>bukal|lingual|palatal` compound is caught in one rule.
    - [ ] Consider a `phraseFix` regex in `ClinicalConfig.clean` so both the displayed transcript and the parser see the correction.
    - [ ] Collect the recurring mis-spellings from real sessions and batch-add them.

---

## Resolved

- [x] **9. Bool metric + full-face site over a range charted only the mid site** 🔴 · PARSE · _2026-08-05_
  - **Symptom:** `"bop dari bukal 16 hingga bukal 15"` (BOP on the whole buccal of teeth 16→15) charted only the middle sites and spilled across the 16/15 boundary (`16=[F,T,T]`, `15=[T,T,F]`) instead of both full buccal faces. **Not the decimal** — `1.6`/`1.5` tokenizes identically to `16`/`15` (`1.6`→`1 6`→`tooth 16`); verified the token stream and chart output are byte-identical with and without the decimal.
  - **Root cause:** `VoiceCommandParser+Lookahead.swift` `resolveAnatomyWithLookahead` collapses a full-aspect word (`bukal`/`lingual`/…) to the single mid site (`resolved.site = 1`) whenever fewer than 3 numbers follow it. That heuristic is for NUMERIC commands (`"bukal 3"` = one value on the mid site), but bool metrics (BOP/plaque/implant) carry **zero** numbers, so `numCount` is always `0 < 3` and the full face was always wrongly shrunk.
  - **Fix:** skip the collapse when `cursor.currentMetric` is a bool metric (`bleeding`/`plaque`/`implant`) — a full-aspect word then keeps `site == nil` (whole face). Verified end-to-end through the real `VoiceCommandParser` + `ChartProcessor`: bop/plaque full-face single-tooth and range now mark all 3 sites; numeric `"poket bukal 3"` still collapses to the mid site and `"poket bukal 3 4 5"` still fills the full face.

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
