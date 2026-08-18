# Pending fixes — speaker gate, TSE, and session control

Opened 2026-08-14. Everything here is either measured on a real session
(`DebugSessions/session-raw.wav`, 19.9 s, two speakers, replayable offline) or
confirmed by reading the code. Nothing here is a hunch.

The offline harness reproduces the device to three decimal places — same models,
same enrollment recipe, same segmenter — so every item below can be settled by
measurement rather than argument.

---

## RESOLVED 2026-08-18

- **P1 — Extractor conditioning is built from silence.** Already fixed before this
  pass: `TSEEngine.enrollmentAudio` selects with `SpeakerGateService
  .concatenatedSpeech` (the energy segmenter), not Silero. The entry below is kept
  for the reasoning; the **P3 tfmap-cost inflation it caused needs re-measuring**,
  since the recorded 0.37–0.41 RTF was taken while conditioning still spanned
  whole files.
- **P1 — Inactivity detector latches open on noise.** Fixed in
  `Wav2VecViewModel.detectSpeech`: rolling 4 s window, floor = 20th percentile,
  loud = 90th, speech iff `rms > floor * 3` **and** `loud / floor >= 3`. A
  percentile always tracks, so the latch is gone, and the contrast test now
  matches `rescueSpans` instead of disagreeing with it at `2.0x`.
- **P2 — AutoGain may amplify room noise into the speech band.** Fixed in
  `AutoGain.looksLikeSpeech`: adaptation now requires the `silenceRMS` level test
  **and** the same contrast test, so steady room noise — loud but flat — no longer
  drives the gain up.
- **P2 — Post-extraction accept uses a global constant.** Fixed in
  `TSERescue.route`: both bands now read `gate.acceptThreshold` /
  `gate.rejectThreshold`. `TSEConfig.postAcceptThreshold` is deleted; the log
  margin takes the profile's line as a parameter.

**None of the four are verified on device yet** — all are code-reviewed and the
project builds clean. The percentile detector and the AutoGain contrast test in
particular change live segmentation behaviour and want a real session before they
are trusted.

---

## MEASURED 2026-08-14 — full pipeline, offline, on `session-raw.wav`

Gate + extractor + Wav2Vec run end to end on the real capture
(`scratchpad/full`). Transcripts, not span tables:

```
UNGATED       ke resesi dari mesio bukal 1 5 hingga distal 1 1 minus 1 6 1 minus 2
              berikutnya bukal 1 5 hingga distobukal 1 1 8 dari bukal 1 5 hingga
              bukal 6 ke mobiliti

everySpan     selesai dari mesio gak 1 5 5 disto dengan 1 1 mid 1 bop dari missing
              mesial 1 5 gak distobukal 1 1                      <-- GARBLED

rescueOnly    ke resesi dari mesio bukal 1 5 hingga distobukal 1 1 minus 1 dari
              mesio bukal 1 5 hingga distobukal 1 1               <-- CLEAN

no extractor  ke resesi dari mesio bukal 1 5 hingga distobukal 1 1 minus 1 dari
              mesio bukal 1 5 hingga distobukal 1 1               <-- IDENTICAL
```

Three conclusions, all first-time measurements at the transcript level:

1. **`everySpan` is destructive, confirmed in text.** "ke resesi" becomes
   "selesai"; `gak`, `dengan`, `mid 1`, `bop`, `missing` are hallucinated. This is
   the "autotune" heard by ear, now visible as word errors. Do not ship it.
2. **`rescueOnly` and no-extractor-at-all produce the IDENTICAL transcript.** The
   3 spans extracted under `rescueOnly` were rejects that stayed rejects and were
   silenced anyway — so on this session **the extractor changed nothing** and cost
   0.77 s. It has yet to alter a single word of output in either direction.
3. **Silencing removes real content.** The ungated pass carries
   "minus 1 6 1 minus 2 berikutnya" and "8 dari bukal 1 5 hingga bukal 6 ke
   mobiliti", both absent once gated — 10.4 s silenced of 19.9 s. How much of that
   is the clinician (unjudged regions) versus the other speaker (rejected spans)
   is the next thing to separate.

---

## P3 — Acoustic-cost rejections are a PREVIEW artifact, not lost dictation

**CORRECTED 2026-08-14.** This was written up as P0 on the strength of the
rejected word list. The offline run does not support that severity:

```
35 words judged, 0 rejected, max cost/letter 3.03 against a 4.50 bar
sweep 4.0 / 4.5 / 5.0 / 5.5 / 6.0 / 100.0 -> drops nothing at any setting
```

Re-reading the device log ordering, all six rejections appear **before** any
`[Gate]` line — they come from the intermediate preview passes, which decode a
growing buffer every ~0.5 s and therefore truncate the final word. High cost on a
half-word is the filter working correctly. Preview text never reaches the parser,
so no chart value was lost to this.

The length bias is real but nowhere near the bar on complete words: short words
(<=3 letters) mean 1.09 cost/letter, long words (>=5) mean 0.74 — a 0.35 gap
against a 4.50 threshold.

**Remaining, minor:** the filter runs on preview inferences and logs each drop
with a ⚠️, which reads as data loss during debugging when it is not. Either skip
the filter when `isLivePreview` is true, or downgrade the log line there.

Original write-up follows, kept because the normalisation critique still stands
if the bar is ever lowered:

### Original (severity overstated)

`CTCDecoder.decode`:

```swift
let costPerLetter = cost / Float(max(1, word.count))
if costPerLetter <= 4.5 { filteredWords.append(word) }
else { print("⚠️ WORD REJECTED via Acoustic Cost: ...") }
```

A hard-coded `4.5`, no configuration, applied to **every** inference including
live preview. Every word it has rejected across every captured session:

| word  | letters | cost/letter | meaning     |
|-------|---------|-------------|-------------|
| ke    | 2       | 4.54        | to          |
| dan   | 3       | 5.13–5.60   | and         |
| dua   | 3       | 4.60        | **2**       |
| ada   | 3       | 5.57        | there is    |
| pada  | 4       | 4.59        | at          |
| enam  | 4       | 4.70        | **6**       |
| mulai | 5       | 4.54        | start       |

All are ≤5 letters, all are among the highest-frequency words in Indonesian, and
two of them are **digits** — `dua` and `enam` are probing depths. `ke`, `pada`
and `dan` are tokens the parser builds structure from.

**The defect is the normalisation, not the threshold value.** A CTC beam cost
carries a component that does not scale with word length — the trie's fight at
word boundaries — so dividing by LETTER count makes short words structurally
expensive regardless of how clearly they were spoken. Normalising by the number
of CTC frames the word spans, or by phoneme count, would not have this bias.

**And 4.5 bisects the distribution**: `dan` appears both accepted and rejected
within one session. That is the worst possible placement — maximum sensitivity to
noise.

This sits *after* the decoder got the word right, so it is a larger accuracy loss
than anything the gate is arguing about upstream.

**Fix:** normalise by frames spanned rather than letters; make the bar
configurable; derive it from a measured distribution rather than a literal. The
offline harness (`scratchpad/full`) dumps cost by word length across real
sessions for exactly this.

---

## P1 — Extractor conditioning is built from silence

`TSEEngine.enrollmentAudio` selects enrollment speech with Silero at threshold
0.3. Silero measures **0.001–0.003 on this device** — it finds nothing — so this
always falls through to the "dead VAD" branch and uses the **whole calibration
files**, pauses included.

Confirmed by arithmetic: the takes are 12.063 + 10.484 = **22.55 s**, and the log
reports `[TSE] enrolled 22.5 s`.

Two consequences, both bad:

- **Conditioning quality.** 1024 conditioning keys are spread across ~22.5 s of
  which maybe 40% is speech. The function's own comment says "Silence between
  spans would spend keys on nothing" — that is exactly what is happening.
- **The tfmap attends over silence.** `computeTFMap` softmaxes every mixture
  frame over *all* enrollment frames, so the attention mass is diluted by frames
  that carry no speaker information.

A weakly-conditioned extractor is the most likely explanation for separation
failing on overlapping speech.

**Fix:** select enrollment speech with the energy segmenter (`rescueSpans`), not
Silero — the same correction the gate already received. The codebase's own lesson
applies: templates and the audio measured against them must come from the same
segmenter.

**Also fixes P3.** Do this one first; it is free, adds no stage, and targets the
overlap complaint directly.

---

## P1 — Inactivity detector latches open on noise

`Wav2VecViewModel.processAudioChunk`:

```swift
let threshold = max(0.001, baselineRMS * 2.0)
let isSpeech = rms > threshold
if !isSpeech { baselineRMS = baselineRMS * 0.99 + rms * 0.01 }   // only when quiet
```

The baseline updates **only while the detector believes the room is quiet**. Once
noise pushes `rms` above `baselineRMS * 2`, the baseline freezes at its old low
value, the threshold stays low, and every subsequent buffer reads as speech. It
cannot recover on its own — a one-way door, not a sensitivity problem.

This is why the listening session keeps running when there is "even a bit of
noise". Denoising would mask it (lower the noise below the frozen threshold and
the baseline resumes) but the latch would remain, and would fire again at the
next sound above it.

Two further defects in the same six lines:

- **It measures level, not contrast.** `rescueSpans` already discriminates speech
  from steady noise using `minDynamicRange = 3.0` — measured 14–50× on healthy
  speech, 2.3–3.4× on the noisy chunks. Steady noise is loud but flat.
- **It disagrees with the segmenter.** `2.0×` here vs `speechFloorMultiple = 3.0`
  next door: two thresholds answering the same question differently.

**Fix:** replace with the segmenter's rule over a rolling ~4 s window — floor =
20th percentile, loud = 90th percentile, speech iff `rms > floor * 3` **and**
`loud / floor >= 3`. Kills the latch (a percentile always tracks), adds the
contrast test, reuses constants already proven on real recordings. ~30 lines, no
new stage, no model, no RTF.

---

## P2 — AutoGain may amplify room noise into the speech band

Added to the live path 2026-08-14. Its anti-pumping guard holds the gain only
below `silenceRMS = 0.004`, but the measured post-gain floor on this device is
**0.0466**. If the raw room floor sits above 0.004, AutoGain treats room noise as
speech and adapts toward `targetRMS / rms` — up to **12×** — pushing a quiet noisy
room toward 0.1, which is speech level.

That would jam the inactivity latch above harder, and is a **live regression
introduced this session**. Suspect it first if sessions now run on longer than
they did before.

**Fix:** raise `silenceRMS` toward the measured floor, or gate adaptation on the
same contrast test as above rather than on level.

---

## P2 — Post-extraction accept uses a global constant, pre-extraction uses the profile's

`TSERescue.route`, in a single expression:

```swift
verdict = d < TSEConfig.postAcceptThreshold      // global 0.675
        ? .accept
        : (d < gate.rejectThreshold ? .confirm : .reject)   // per profile
```

`routeThreshold` was removed for exactly this drift — a profile that lowers its
accept line kept routing at a stale global. The same bug survives one line later:
a span is judged *before* extraction at the profile's own operating point and
*after* extraction at a global constant, and the two can disagree.

**Fix:** use `gate.acceptThreshold` for the post-extraction accept band. Keep
`postAcceptThreshold` only if there is evidence the post-extraction distribution
genuinely needs a different line from the pre-extraction one — and if so, make it
an offset from the profile's line, not an independent absolute.

---

## P3 — tfmap dominates extraction cost, and the cost is inflated by P1

Measured RTF is **0.37–0.41**. The Core ML models alone should be ~0.19 by the
recorded A16 benchmark (12.40 ms/block, 47 blocks per 3 s span), so roughly half
the time is the Swift tfmap and marshalling.

`computeTFMap` runs two `cblas_sgemm` calls per block against **every** enrollment
frame:

```
span 3.0s -> 375 stft frames -> 47 blocks
tfmap = 11.6M MAC/block, 0.54 GMAC per span
speech-only enrollment (~40%) -> 0.22 GMAC   (2.5x less)
```

It also heap-allocates `scores` (8 × 2819 floats ≈ 90 KB) and `transposed` inside
the per-block loop — about 4 MB of allocation churn per span.

**Fix:** P1 gives 2.5× for free by shortening the enrollment. Then hoist the two
scratch buffers out of the block loop.

---

## P3 — Denoising, in the flow: Audio → Denoise → Gate → Extract → Denoise → Wav2Vec

Wanted for stopping the session on inactivity. Note the P1 inactivity item first:
the latch is the actual cause there, and denoising does not fix it.

Recommended order, cheapest and safest first:

1. **TSE enrollment via the energy segmenter** (P1 above). Free, no new stage,
   targets overlap directly.
2. **Denoise before Wav2Vec** (stage 2). Lower risk — no interaction with the
   segmenter. Measure it against the fixture.
3. **Denoise before the gate** (stage 1). Highest risk, and it has a recorded
   prior: `handoff.md` "do not repeat" — *denoising before diarization hurt
   coverage 39% → 31%*.

The mechanism behind that prior is visible in the code:

```swift
let threshold = max(noiseFloor * speechFloorMultiple, absoluteFloor)
```

The segmenter derives its speech threshold **from the noise floor**. Denoise
first, the floor collapses, `threshold` pins to the 0.003 absolute floor,
everything above it reads as speech, spans merge into one block, and the gate
makes a single verdict over the whole chunk.

**Condition on stage 1:** the calibration takes must be denoised identically.
Templates and live spans must come from the same front end — denoising live but
not enrollment rebuilds the exact asymmetry fixed on 2026-08-14 (missing
high-pass and auto-gain on the live path, 75% abstention).

**Implementation:** no new model. `TSEFeatures.swift` already has
`TSESpectrogram.forward` / `.inverse` / `.magnitude`, and `rescueSpans` already
computes a per-chunk noise floor. Spectral subtraction on top of those is ~60
lines. Given RTF is already 0.39 and this app has been jetsam-killed, a Core ML
denoiser is the wrong trade.

Both stages should ship behind independent switches, defaulted off, and be
measured on the fixture before either is committed to.

---

## Standing record — extractor efficacy

Not a defect; the honest tally so far, across every extraction with both distances
logged:

```
6 of 8 moved AWAY from the enrolled centroid; mean +0.114
worst degradation +0.310   best improvement -0.039
restricted to its actual job (rescuing rejects): 1 rescue in 2 attempts
```

Four of those six degradations were `confirm` spans that should never have been
re-judged — fixed 2026-08-14 by freezing any verdict that already passes the gate.
The remaining sample is too small to conclude from. Re-tally after P1.

---

## Cosmetic

- `TSEExtractor`'s enroll_kv comment cites `(nBands, enrollKeys, attenDim)`, but
  `attenDim` was pruned from `TSEConfig` as unreferenced. Restore the constant or
  reword the comment.

---

## Verified sound (checked 2026-08-14, no action)

- LSTM `(h, c)` state is freshly zeroed per `extract()` call, so it cannot leak
  between spans.
- Enrollment subsampling matches `torch.linspace(...).long()` truncation.
- fbank frame count is consistent with the documented 10 ms hop
  (22.55 s → 2253 frames).
- `read(_:into:)` correctly handles fp16, fp32 and non-contiguous strides.
