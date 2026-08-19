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

## Breakthrough: Shallow Fusion & Constrained Pruning
Previously, we concluded that without finetuning the model, 49 mismatches was the ceiling. When we tried increasing the CTC Beam Search width from `10` to `50`, the model hallucinated and errors spiked.

However, a deeper analysis into the acoustic outputs revealed that the model was heavily biased toward numeric tokens (e.g. `lima`, `dua`) over clinical anatomies (e.g. `lingual`, `bukal`).

We broke through this plateau by implementing three fixes:
1. **Shallow Fusion LM Boost:** We injected a massive `-3.0` log-probability bonus directly into the CTC beam search whenever it completed an anatomy word, steering the acoustic math toward clinical terms.
2. **Relaxed Character Pruning:** The Wav2Vec model was so confident in numbers that it was pruning the `l-i-n-g-u-a-l` character branches before they could even finish. Relaxing the prune threshold from `-10.0` to `-15.0` allowed these weaker branches to survive long enough to receive the LM boost.
3. **Contextual Phonetic Recovery:** For the remaining cases where `lima` purely overpowered `lingual` acoustically, the `StatefulParser` was updated to safely catch `5` and `2` and recover them to `lingual` and `bukal` *only* if the parser was actively expecting an anatomy (making numbers clinically invalid anyway).

## Conclusion
By fixing the acoustic cost filter to normalize over frames, widening the beam to `40`, and injecting a word-level anatomy LM boost with a context-safe parser safety net, we successfully broke the previous 49-mismatch ceiling and dropped the student charting mismatches by over 70% without retraining the model.

### Full Pipeline Evaluation (Audio to Charting)
| Test Case | Diagnostic Words | Audio WER (Diagnostic) | Charting Mismatches (Full Pipeline) |
| :--- | :---: | :---: | :---: |
| `dr_lucky` | 287 | **12.54%** | **34** |
| `student` | 607 | **15.32%** | **26** |

### NLP Pipeline Evaluation (Text to Charting)
We ran the parser directly against the human-corrected, perfectly transcribed ground-truth text:
| Test Case | Charting Mismatches (NLP Pipeline) |
| :--- | :---: |
| `dr_lucky` | **0** (Down from 20) |
| `student` | **0** (Down from 69) |
