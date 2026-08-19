//
//  TSEConfig.swift
//  PeriodontalCharting
//
//  Constants for the target speaker extraction (TSE) layer, taken from the
//  exported graph of `tfmap_context_causal_100` at n_keys=1024. Every number in
//  the architecture block is load-bearing: change one and the Core ML packages
//  stop binding.
//

import CoreML
import Foundation

enum TSEConfig {

    // MARK: Architecture (from the checkpoint — do not edit to "tune")

    static let sampleRate = 16_000
    static let nFFT = 512            // 32 ms window
    static let hop = 128             // 8 ms — the model's frame rate
    static let bins = nFFT / 2 + 1   // 257

    static let nBands = 32
    static let nLayers = 6
    static let hidden = 256
    static let blockFrames = 8       // 64 ms per Core ML call
    static let enrollKeys = 1024     // n_keys
    static let enrollEmbedDim = 512  // WeSpeaker ECAPA layer-4 frame features

    // MARK: Operating point

    // ROUTING IS BY VERDICT, NOT BY DISTANCE.
    //
    // Anything the gate does not outright accept — `confirm` or `reject` — goes
    // to the extractor. That reuses the gate's OWN accept threshold, which is per
    // profile, so a clinician with a custom operating point routes at their own
    // line. The old `routeThreshold` was a second global 0.675 sitting beside
    // `SpeakerGate.acceptThreshold` with nothing keeping the two in step: a
    // profile that lowered its accept line kept routing at the stale one.
    //
    // THE SAME NOW APPLIES AFTER EXTRACTION. `postAcceptThreshold`, a second
    // global 0.675, used to decide the accept band for `d_sep` while the reject
    // band beside it came from the profile — so a span was judged before
    // extraction at the clinician's own line and after it at a stale global. It
    // was the identical drift, one line further down, and it is gone:
    // `TSERescue.route` now reads `gate.acceptThreshold` for both.
    //
    // Re-introduce a separate post-extraction line ONLY with evidence that the
    // post-extraction distance distribution genuinely differs — the zero-error
    // band after extraction was re-derived as (0.486, 0.779) — and make it an
    // OFFSET from the profile's line rather than an independent absolute. Margin
    // is asymmetric in the WRONG direction for the cost model, so any adjustment
    // goes DOWN.

    // Extraction is not worth its ~0.3 RTF on a fragment the gate cannot judge.
    // Matches `SpeakerGate.minDurationSeconds`, below which `classify` refuses.
    static let minRouteSeconds = 1.0

    // SILENCE AUDIO THE GATE DID NOT ATTRIBUTE TO ANYONE — but only inside a
    // chunk it actually judged.
    //
    // Without this, `.enforce` silences ONLY spans positively scored `reject`,
    // and everything else survives: the gaps between spans, spans dropped as
    // `thin`, and every chunk that produced no verdict at all. A second speaker
    // is audible in the gated audio wherever the segmenter did not happen to cut
    // a span around him — which is what "my friend's voice is still there" was.
    //
    // SCOPED TO JUDGED CHUNKS ON PURPOSE. Applying it to a chunk with no spans
    // would mute the chunk entirely, and abstention measured at 75% on quiet
    // audio — that would delete most of a session. The honest reading is that
    // this closes the leak the gate can see, and abstention is a separate bug
    // fixed upstream by conditioning the live signal (Wav2VecAudioCapture).
    //
    // THE COST, stated plainly: a `thin` span holding 0.3–0.8 s of the
    // clinician's own quiet speech is now silenced rather than passed. That is
    // the codebase's stated cost model applied consistently — a false accept puts
    // a wrong number on a chart and nobody notices, a false reject costs one
    // repeat. Set false to go back to reject-only muting.
    static var silenceUnattributed = true

    // MARK: Behaviour

    // What each mode does to the audio Wav2Vec receives:
    //
    //   off          nothing runs; the chunk arrives untouched
    //   observe      the extractor runs and logs, Wav2Vec still gets the ORIGINAL
    //                — the counterfactual, at full cost, with no risk
    //   extractOnly  Wav2Vec gets the extracted audio, but NOTHING is ever
    //                silenced or withheld. Separation is the only mechanism.
    //   enforce      as extractOnly, plus rejected spans are silenced and an
    //                all-rejected chunk is withheld entirely
    //
    // `.observe` is the back-out. It keeps every log line identical, so a
    // regression can be diagnosed from the same console output.
    //
    // `.extractOnly` IS THE "WHY NOT JUST TSE?" EXPERIMENT, and it is here to be
    // measured rather than argued about. The claim it tests: if the extractor is
    // conditioned on the clinician, a second voice comes out suppressed, so the
    // decoder should produce nothing for it and an explicit reject is redundant.
    //
    // The reason to doubt that — and the thing to watch for in the transcript —
    // is that suppression is not rejection. A ratio mask attenuates, it does not
    // null, and `Wav2VecAudioCapture.normalizeAudio` then Z-scores the chunk by
    // its OWN standard deviation, which rescales whatever residual is left back
    // to unit variance. Attenuation does not survive that step; a zeroed span or
    // a withheld chunk does. Under `.extractOnly` the gate still measures and
    // logs every reject, it simply does not act on one, so the console tells you
    // exactly which spans WOULD have been dropped and you can check the
    // transcript for their words.
    enum Mode: String, CaseIterable {
        case off, observe, extractOnly, enforce

        // The extractor runs at all.
        var runsExtractor: Bool { self != .off }
        // The extracted waveform actually reaches the decoder.
        var splicesAudio: Bool { self == .extractOnly || self == .enforce }
        // A rejected span is silenced, and an all-rejected chunk is withheld.
        var silencesRejects: Bool { self == .enforce }
    }

    // PERSISTED AND RUNTIME-SETTABLE, from the gate debug harness.
    //
    // Not for the clinician's benefit — for the A/B. Comparing two modes meant
    // editing this file, rebuilding and reinstalling between takes, and on this
    // project a reinstall re-pays the Core ML compile. That turned a ten-minute
    // experiment into an afternoon, which is the reason it kept not getting done.
    //
    // A stored static with a lazy initialiser, NOT a computed property: `mode` is
    // read once per span inside `shouldExtract`, and routing a chunk should not
    // mean a UserDefaults lookup per span. The write persists; the read is a
    // plain static access.
    private static let modeKey = "TSEMode"
    private static let coverageKey = "TSECoverage"

    static var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "")
        ?? .enforce {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: modeKey) }
    }

    // WHICH SPANS GO THROUGH THE EXTRACTOR. This is the open question, and the
    // two answers are one word apart on purpose.
    //
    //   rescueOnly  extract the spans the gate did NOT accept — `confirm` and
    //               `reject`. Accepted speech reaches Wav2Vec bit-exact, so
    //               extraction artefacts can never cost a word that was already
    //               going to be transcribed right.
    //   everySpan   extract every judged span, so Wav2Vec always sees a signal
    //               with the other voice suppressed.
    //
    // `.rescueOnly` routes its two bands for different reasons — `reject` to win
    // the span back, `confirm` for the ASR only, since a confirm's verdict is
    // frozen. The decision table in `TSERescue.shouldExtract` is the detail.
    //
    // WHAT THE EXISTING BENCH DOES AND DOES NOT SETTLE. "Gate 1 (do no harm)
    // killed every always-on candidate" was measured on SPEAKER DISTANCE — does
    // extraction move a span away from the enrolled centroid. It says nothing
    // about WORD ERROR RATE, which is the number that matters for this choice and
    // which nobody has measured on device. Do not quote Gate 1 as if it had.
    //
    // The real risk of `.everySpan` is not noise, it is ARTEFACTS: a complex
    // ratio mask punches spectral holes, and a CTC acoustic model that never saw
    // enhanced audio in training can lose phonemes to them — the same failure
    // Wav2VecEngine already pads white noise to avoid at the buffer edge. The
    // risk `.rescueOnly` used to carry was the friend's point — a `confirm`-band
    // span that IS the clinician, transcribed through the other voice. Routing
    // `confirm` closes that, and buys the artefact risk on those spans instead;
    // only `accept` is bit-exact now.
    //
    // Both are measurable with the same recording. `[TSE/cover]` logs the split
    // per chunk so an A/B is a rebuild, not a re-instrument.
    enum Coverage: String, CaseIterable { case rescueOnly, everySpan }

    // SHIPS AS `.rescueOnly`, and this default is measured rather than assumed.
    //
    // It was `.everySpan` while that was the open question. It is not open any
    // more — replayed through the real decoder on a captured session:
    //
    //   ungated     ke resesi dari mesio bukal 1 5 hingga distal 1 1 minus 1 6 ...
    //   everySpan   selesai dari mesio gak 1 5 5 disto dengan 1 1 mid 1 bop ...
    //   rescueOnly  ke resesi dari mesio bukal 1 5 hingga distobukal 1 1 minus 1 ...
    //
    // `.everySpan` turned "ke resesi" into "selesai" and hallucinated `gak`,
    // `dengan`, `mid 1`, `bop` — the masking artefact, audible as an autotuned
    // quality on the clinician's own voice. `.rescueOnly` leaves accepted and
    // confirmed speech bit-exact and produced a transcript identical to running
    // with no extractor at all.
    static var coverage: Coverage =
        Coverage(rawValue: UserDefaults.standard.string(forKey: coverageKey) ?? "") ?? .rescueOnly {
        didSet { UserDefaults.standard.set(coverage.rawValue, forKey: coverageKey) }
    }

    // CPU_ONLY beat CPU_AND_NE by 20% on the A16 (12.40 vs 14.95 ms/block). The
    // ANE does not help this architecture — `band_comm` reshapes to B*T and runs
    // 32 per-band LSTM calls.
    static var computeUnits: MLComputeUnits = .cpuOnly
}
