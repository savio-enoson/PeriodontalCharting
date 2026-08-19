# Analysis of Remaining Mismatches

After implementing the strict Acoustic Cost threshold (which successfully blocked the `[-5]` static hallucination cascade) and the `expectedSlots > 48` cross-arch range limit, we ran the evaluation again and observed **91 mismatches**. 

I performed a deep-dive trace into the STT pipeline to understand exactly why these mismatches occurred, and the results are conclusive: **The STT engine itself was functioning fine, but the regression testing script was bypassing crucial front-end audio conditioning.**

## The Root Cause of Dropped Words
Many teeth suddenly had a Gingival Margin of `[-1, -1, -1]` and `Plaque` was totally missing. Here is the exact sequence of events that caused it, proven by the STT logs:

1. **The Ground Truth Audio:**
   The dentist says:
   > "resesi mesio palatal 1"
   > "BOP dimulai dari disto lingual 15 hingga palatal 16"
   > "plak pada semua gigi"

2. **The Unconditioned Audio Evaluation:**
   The model completely dropped the softly spoken loanwords `BOP` and `plak`, and transcribed the audio as:
   > "resesi mesio bukal 1 ... di mulai dari distobukal 1 ... hingga ke palatal 1 6 ke pada semua gigi"

3. **The Parser Cascade:**
   - `resesi mesio bukal 1` set the active metric to `gingivalMargin`.
   - Because `BOP` and `plak` were dropped, the metric **remained** `gingivalMargin`.
   - The phrase `semua gigi` (all teeth) was *genuinely* spoken by the dentist loudly enough to be heard. 
   - The parser saw `semua gigi`, looked at the active metric (`gingivalMargin`), and logically applied `-1` to the Gingival Margin of **all teeth**.
   - **This resulted in 60+ cascade errors from a single dropped word.**

## The Fix: Applying Audio Conditioning
Recently, a `HighPassFilter` and an `AutoGain` module were added to the `startStreamingRecording` pipeline for the live app. These were explicitly added to lift the contrast of softly spoken clinicians by up to 2.5x.

However, the offline regression testing script (`run_regression_tests.swift`) was reading the raw floats from the `.m4a` file and skipping the conditioning step entirely. 

When we updated the testing script to apply the same `HighPassFilter` and `AutoGain` as the live app:
- The model successfully heard `"plak"` at the end of the audio clip.
- Because `plak` was correctly transcribed, the parser activated the `Plaque` metric before hitting `semua gigi`.
- Mismatches instantly plummeted from **91 down to 49**, and the WER improved to **33.66%**.

## Attempted Beam Width Optimizations
We experimented with increasing the CTC Beam Search width from `10` to `50` to see if the decoder would search wider for dropped words. This actually **degraded** the accuracy (pushing errors back up to 75). Without a dedicated N-gram language model like KenLM, a wider beam simply allows the raw acoustic model to hallucinate longer, confident-sounding garbage strings (e.g. `puluh distal 2 2 2 2`) that overwrite the true transcription at the end of audio files. The beam width has been reverted to `10`.

## Conclusion
At 49 mismatches, we have squeezed every drop of performance out of the current codebase. The remaining errors are pure Wav2Vec2 phonetic substitutions (e.g., mishearing "enam" as "dua") and isolated dropped words that no parser logic can safely recover.

There are no more software-side mitigations or parameters to tweak without resorting to finetuning the model or supplying a dedicated language model.

### Full Pipeline Evaluation (Audio to Charting)
| Test Case | Reference Words | Audio WER | Charting Mismatches (Full Pipeline) |
| :--- | :---: | :---: | :---: |
| `dr_lucky` | 309 | 33.66% | **49** (Down from 91) |
| `student` | 801 | 39.58% | **73** (Down from 104) |

### NLP Pipeline Evaluation (Text to Charting)
We ran the parser directly against the human-corrected, perfectly transcribed ground-truth text:
| Test Case | Charting Mismatches (NLP Pipeline) |
| :--- | :---: |
| `dr_lucky` | **0** (Down from 20) |
| `student` | **0** (Down from 69) |
