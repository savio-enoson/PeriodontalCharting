# STT Engine Documentation: Periodontal Charting Voice Architecture

This document serves as the permanent architectural record and maintenance guide for the custom offline Voice-to-Text (STT) engine built for the iOS Periodontal Charting Application.

---

## 1. System Overview

The STT engine is completely offline, highly specialized, and optimized exclusively for Indonesian clinical dental terminology. The architecture relies on four primary pillars:

1. **Acoustic Model**: An optimized CoreML `Wav2Vec2` model running in FP16 precision.
2. **CTC Beam Search Decoder**: A custom Swift decoder that converts model logit probabilities into text.
3. **Prefix Trie Constrained Decoding**: A strict dictionary-based filtering system that mathematically forces the AI to output *only* valid clinical terms, eliminating hallucinations.
4. **Dynamic RMS VAD (Voice Activity Detection)**: A lightweight, computationally free heuristic VAD that optimally chunks audio streams to prevent transformer context starvation while respecting CoreML tensor limits.

### The Core Principle: Strict Purity over Fuzzy Leniency
The engine's fundamental philosophy is that **strict dictionary mapping** is vastly superior to **fuzzy omission recovery** for clinical charting. Historically, attempts to inject dynamic 1-letter omission variants (e.g. `igi`, `ukal`) into the memory buffer caused the engine to become a "hallucination magnet," wildly snapping valid acoustic noise into fragmented words. The engine now runs strictly on a pristine, curated `lexicon.txt`, with only specific, manually defined phonetic variants placed in the `canonical_mapping.json`.

---

## 2. Audio Pipeline & Dynamic VAD

The application records raw 16kHz PCM audio buffers. To feed this infinite stream into a CoreML model (which has a strict maximum sequence length of 60 seconds / 960,000 samples), the audio must be chunked. 

### Why Arbitrary Chunking Failed
In previous iterations, the code forced a "Soft Commit" (flushing the buffer) every 3 to 8 seconds to prevent buffer bloat. It then instructed the Decoder to ignore the first `N` samples of the next buffer to stitch the text together. 

**This failed catastrophically.** Wav2Vec2 is a bidirectional transformer. Severing the audio at arbitrary timeframes completely destroyed the acoustic left-context the neural network needed to predict the first phoneme of the next word. The model would physically mishear `gigi` as `igi` simply because the `g` sound was mathematically deleted from the start of its buffer.

### The Solution: Dynamic VAD Threshold
Instead of arbitrarily chopping the audio, the engine now uses `vDSP_rmsqv` (Apple Accelerate) to continuously track the Room Mean Square (RMS) energy of the environment, automatically adapting to the loud baseline noise floor of suction tubes and dental drills. 

When the user speaks, the buffer grows infinitely. The VAD logic continuously monitors for "silence frames". To guarantee the audio is only ever split between sentences (and never mid-word), while also guaranteeing the buffer never exceeds CoreML limits, the engine utilizes a **Dynamic Silence Threshold**:

- **0–5 seconds**: Waits for **0.16s** of continuous silence (ultra-snappy for short commands).
- **5–30 seconds**: Waits for **0.38s** of continuous silence (tolerates breathing during long lists).
- **> 30 seconds**: Waits for **0.2s** of continuous silence.
- **> 45 seconds**: Waits for **0.1s** of continuous silence.

This mathematically guarantees the audio is never severed mid-phoneme, while elegantly preventing CoreML 60-second crashes. 

---

## 3. The Acoustic Model (Wav2Vec2)

The engine utilizes `Wav2Vec2_Indonesian_FP16.mlmodelc`. 
- **Input:** A 1D Float32 MultiArray representing the raw audio waveform at 16,000 Hz.
- **Output:** A 3D Float32 MultiArray (`[1, sequence_length, vocab_size]`) containing the raw logit probabilities for each token in the Indonesian alphabet at every 20ms timestep.

Because it operates at FP16, it is highly optimized for the Apple Neural Engine (ANE) and GPU, providing real-time inference speeds well below 0.1x RTF (Real-Time Factor) on modern iPads.

---

## 4. Constrained CTC Decoding (Prefix Trie)

Unlike standard STT engines that output whatever the acoustic model thinks it heard, this clinical engine uses **Strict Constrained Decoding**.

### The `lexicon.txt`
This file contains the absolute ground-truth vocabulary. It houses exactly 338 clinical terms (e.g. `mesio`, `distal`, `furkasi`, `plak`). 

### The Prefix Trie
When the application launches, `ModelManager.swift` builds an in-memory Prefix Trie from the lexicon. During inference, the `CTCDecoder` steps through the model's logits. For every character the model wants to predict, the Decoder asks the Prefix Trie: *"Does appending this character form a valid prefix of a clinical word?"*
- If **Yes**, the beam search continues.
- If **No**, the probability of that character is instantly forced to `-infinity`, permanently culling that hallucination path.

This guarantees the engine will *never* transcribe a non-clinical word. 

---

## 5. Canonical Mapping & Acoustic Variants

Because the clinical environment is noisy and Indonesian dentists often pronounce Latin/English clinical terms rapidly or phonetically, the engine requires a mechanism to map "what the model heard" to "what the software needs".

### The `canonical_mapping.json`
This JSON file serves as the phonetic bridge. It maps acoustic mispronunciations directly to canonical terms.
- **Example:** `{"misiobocal": "mesiobukal", "gret": "grade", "nggak": "gak"}`

### Maintenance Rules for Mapping
If the engine consistently mishears a specific word in testing:
1. Do **NOT** implement dynamic code to programmatically strip letters. 
2. Instead, look at the raw transcript to see what the engine *acoustically heard* (e.g., it heard `pukal` instead of `bukal`).
3. Add the explicit phonetic variant to `canonical_mapping.json` (`"pukal": "bukal"`).
4. Add the variant to the `lexicon.txt` so the Prefix Trie is allowed to construct it (`pukal \t p u k a l`).

This manual, curated approach maintains the mathematical purity of the Trie and entirely prevents the cascading hallucination issues that arise when dynamically bloating the dictionary.

---

## 6. Acoustic Cost Rejection

In a dental clinic, metal tools frequently clink against metal trays. These sounds create massive spikes in RMS energy, causing the VAD to trigger a false-positive and wake up the STT engine to process the sound of the metal clinking. 

Because the Prefix Trie mathematically forces the model to output *something* from the dictionary, the model will desperately try to match the static noise of a clinking tool to a clinical word. 

To solve this, `CTCDecoder.swift` calculates a `costPerLetter` for every final word it produces. The cost is derived from the negative log-probability of the acoustic logits. 
- If the model is confident (the sound was clearly a human saying "mesio"), the `costPerLetter` is extremely low (e.g., `0.5`).
- If the model is wildly guessing (trying to map a metal clink to a word), the `costPerLetter` skyrockets.

The engine enforces a strict cutoff: `if costPerLetter > 4.5`, the word is classified as "Non-Speech Noise" and is silently discarded. This guarantees that metal tools and suction noise do not inject random clinical words into the periodontal chart. This logic is strictly enforced on both the final commit and intermediate Live Previews, ensuring the UI remains perfectly stable and immune to jittery hallucinations.

---
**Document Last Updated**: August 2026.
