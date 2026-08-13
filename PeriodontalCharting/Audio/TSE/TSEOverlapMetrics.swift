//
//  TSEOverlapMetrics.swift
//  PeriodontalCharting
//
//  T1 — CANDIDATE OVERLAP METRICS. MEASURED ON EVERY SPAN, GATING NOTHING.
//
//  The current router fires on ONE ECAPA distance over the whole span, which
//  conflates "someone else is talking over you" with "you are quiet or masked"
//  (HANDOFF, "The current trigger cannot work"). Before that can be replaced, the
//  null distribution has to exist: what does each candidate metric look like when
//  there is definitively NO overlap? Every ordinary clinic session is
//  single-speaker, so it produces that distribution for free — including on the
//  quiet spans that are exactly where the present trigger misfires.
//
//  THIS FILE DELIBERATELY MAKES NO DECISION. Nothing here feeds `shouldRoute`, and
//  none of it is gated on `TSEConfig.mode` — the whole point is that it runs while
//  the extractor stays `.off`.
//
//  VALIDATION: `TSEMetricsSelfTest.run()`. Every metric here returns a plausible
//  number whether or not the code is correct, so plausibility is not evidence.
//  Kurtosis and crest factor have EXACT analytic references (-1.5 and sqrt(2) for
//  a pure sine, 0 for Gaussian noise) and the self-test asserts them. Run it after
//  touching anything in `analyze`.
//
//  ---------------------------------------------------------------------------
//  SCHEMA 4 — flatness in dB; limiter diagnostics added.
//
//  `flat_med` was logged as a raw geometric/arithmetic ratio, which for speech
//  lives at 1e-3: measured 0.000–0.006 across a whole session, i.e. barely three
//  distinct values after rounding. The same data spans roughly -30 to -22 dB.
//
//  `crest` and `clip` are new, and they exist to make kurtosis interpretable.
//  KURTOSIS IS SCALE-INVARIANT, so AutoGain's multiplier cannot move it — the
//  earlier worry about "gain 3.26x inflating kurtosis" was misplaced. What DOES
//  move it is the LIMITER, which is nonlinear: squashing peaks pulls kurtosis
//  down, clipping at the rail pushes it up, and neither is speaker-count
//  information. Crest factor collapses toward 2 when the limiter has been working;
//  `clip` catches hard clipping. A `kurt_span` excursion at crest 4 with clip 0 is
//  real; the same excursion at crest 2 is the limiter.
//
//  Redefined by schema 4 — do not pool with schema 3: `flat_med`. New: `crest`,
//  `clip`.
//  ---------------------------------------------------------------------------
//
//  SCHEMA 3 — the activity threshold inverted on speech-dense spans.
//
//  Schema 2 derived the speech threshold inside each span the way `rescueSpans`
//  derives it inside a WINDOW: 20th percentile as the noise floor, times three.
//  That recipe assumes the input contains silence. A SPAN does not — the segmenter
//  selected it precisely because it is mostly voice — so its 20th percentile is
//  already a speech frame and 3x that excludes almost everything.
//
//  Measured 2026-08-10, the active fraction tracking speech density BACKWARDS:
//
//      span            gate said        frames active
//      22.00–24.94     47% speech       85 / 180  = 47%   correct
//      0.54– 2.52      95% speech       13 / 120  = 11%
//      7.68– 9.06     100% speech        4 /  83  =  5%
//      34.51–37.06     88% speech        1 / 156          collapsed
//
//  Every active-frame-derived column on the cleanest spans was computed from one
//  to four frames. It also explains why `voiced` equalled `active` almost
//  everywhere: only the loudest vowels cleared the bar. The threshold is now the
//  SMALLER of "three times the floor" and a fixed fraction of the loud part.
//
//  CROSS-CHECK: `speech_s` should agree with the seconds of speech on the matching
//  `[Gate] keep` line. If they diverge again, this regressed.
//
//  SCHEMA 2 — retained for reading older rows.
//
//  1. KURTOSIS RAN NEGATIVE, NOT POSITIVE. Schema 1 measured it on speech-active
//     frames only and claimed a FALL was evidence of mixing. Speech is
//     super-Gaussian because it ALTERNATES between loud and near-silent; filtering
//     to active frames discards that sparsity and leaves sustained vowels, which
//     approach a sine's -1.5. Both are measured now.
//  2. THE HARMONIC WINDOW WAS TOO SHORT. 512 samples held 2.2 periods of a 70 Hz
//     voice, below Boersma's three-period floor. Now 1024 — 4.5 periods.
//  3. COMPETING PEAKS COUNTED FORMANTS. No guard against SUB-PERIOD structure.
//     Candidates are now floored at half the dominant lag and must show harmonic
//     support at 2t. Confirmed: `peaks_mean` reached 0.00, against a schema-1
//     floor of 0.60.
//
//  FOUR FAMILIES, chosen because they FAIL DIFFERENTLY — waveform-, embedding- and
//  model-domain errors are uncorrelated, which is the whole reason combining helps:
//
//    A  WAVEFORM / TF SPARSITY   kurtosis (span + active), Gini, Hoyer, flatness
//    B  HARMONIC MULTIPLICITY    CPP, HNR, competing autocorrelation peaks, F0 IQR
//    C  OFF-SUBSPACE RESIDUAL    `SpeakerGate.probe`, below
//    E  SUB-WINDOW SPREAD        `TSERescue.subwindowDistances`
//
//  A, B AND C ARE FREE; ONLY E COSTS CORE ML. A and B are pure Accelerate. C reuses
//  the embedding `classify` already computed, so it is arithmetic only. E is 2–3
//  ECAPA calls on the ANE that WhisperKit's encoder occupies for ~442 ms a window,
//  inside the serial pump that publishes audio to Whisper.
//
//  PRIVACY: numbers only. No audio, no text.
//

import Accelerate
import Foundation

// MARK: - Configuration

// Separate from `TSEConfig` ON PURPOSE. Everything in `TSEConfig` is bound to the
// exported Core ML graph and breaks it if edited; everything here is a measurement
// knob and is meant to be turned.
enum TSEMetricsConfig {

    // Master switch. Independent of `TSEConfig.mode` — measurement continues while
    // extraction stays `.off`, which is the entire T1 arrangement.
    static var enabled = true

    // One extra console line per span.
    static var logToConsole = true

    // Append to the CSV under Application Support. Writes are buffered and drained
    // on a background queue, so this no longer costs the audio pump anything.
    static var writeCSV = true

    // FAMILY E — the only part of this file that calls Core ML.
    //
    // Costs 2–3 ECAPA calls per span on the ANE that WhisperKit's encoder occupies
    // for ~442 ms a window, inside `judgePending` and therefore before
    // `notify?(cleaned)` hands audio to Whisper. ANE requests serialise, so the
    // real cost is well above the isolated latency. This is the switch to reach
    // for when bisecting live latency.
    //
    // REPLACED `aneFamilies`, which gated families C and E together. C stopped
    // doing inference once `probe` began taking `GateResult.embedding` instead of
    // re-embedding the same audio, so it is now pure arithmetic and always runs.
    // One switch, one cost.
    static var probeSubwindows = true

    // 1.2 / 0.5 rather than 1.5 / 0.75: at the old geometry a span needed 2.25 s to
    // yield two windows, so 13 of 22 measured spans got nothing — including the
    // 1.1 s overlapping span that family E should have caught. 1.2 s still clears
    // the embedder's 1.0 s hard floor, and covers spans from 1.7 s up.
    static let subwindowSeconds: Double = 1.2
    static let subwindowStrideSeconds: Double = 0.4

    // 1024 = 64 ms @ 16 kHz. MUST stay 1024: the FFT setup is built at log2n = 10
    // and the split-complex packing assumes n/2 = 512.
    static let frameSize = 1024
    static let frameHop = 256

    // F0 search bounds. 1024 samples is 4.5 periods at 70 Hz and 25 at 400 Hz.
    static let minF0: Double = 70
    static let maxF0: Double = 400

    // Normalised autocorrelation above which a frame counts as VOICED.
    static let voicedThreshold: Float = 0.35

    // A competing peak must reach this fraction of the dominant peak...
    static let competingPeakFraction: Float = 0.5
    // ...and this absolute floor, so a frame with no real periodicity cannot
    // manufacture competitors out of its own noise.
    static let competingPeakFloor: Float = 0.25
    // A candidate must also show its own harmonic support: the autocorrelation at
    // TWICE its lag must reach this fraction of the peak. A real period implies
    // peaks at 2t, 3t…; a formant resonance does not.
    static let harmonicSupportFraction: Float = 0.5
    // Relative tolerance for calling two lags harmonically related. Inside this, a
    // peak is the SAME voice's harmonic or subharmonic and is not counted — this is
    // the octave-error immunity.
    static let harmonicTolerance: Double = 0.06
    // Below `windowAutocorr[lag]` this small, the correction amplifies noise more
    // than signal and the lag is skipped entirely.
    static let windowCorrectionFloor: Float = 0.05

    // Speech activity, first term: a multiple of the in-span noise floor. Correct
    // on spans that contain silence.
    static let speechFloorMultiple: Float = 3.0
    // Speech activity, second term: a fraction of the loud part (90th percentile).
    // Correct on spans that do NOT contain silence, where the floor term inverts.
    // The threshold takes the SMALLER of the two — see the schema-3 note.
    static let loudFraction: Float = 0.35
    // Absolute minimum, so a dead-quiet span cannot promote its own hiss.
    static let absoluteFloor: Float = 0.003

    // Samples at or beyond this magnitude count as hard-clipped.
    static let clipThreshold: Float = 0.99

    // Bump when a column is added, removed or REDEFINED. Rows carry it so two
    // collection periods with different definitions can never be pooled.
    //   1 — first implementation
    //   2 — kurtosis split span/active, 1024-sample harmonic window,
    //       competing-peak lag floor + harmonic support, tangent-space subspace
    //   3 — activity threshold no longer derived from the in-span floor alone
    //       (it inverted on speech-dense spans); `loud` column added
    //   4 — flatness moved to dB; `crest` and `clip` added so the limiter's effect
    //       on kurtosis can be separated from speaker count
    static let schemaVersion = 5
}

// MARK: - The measurements

// Families A + B. Pure signal, no model, no embedding — so nothing here is touched
// by the zero-padding trap, and nothing here touches the ANE.
struct SignalMetrics {
    var durationSeconds: Double = 0
    var rms: Double = 0

    // Peak divided by RMS over the whole span. sqrt(2) ~ 1.414 for a pure sine,
    // 3–5 for natural speech, and it collapses toward 2 when AutoGain's limiter has
    // been working hard.
    //
    // THIS IS THE KURTOSIS CONTROL COLUMN. Kurtosis is scale-invariant, so plain
    // gain cannot move it — but the limiter is NONLINEAR, and it moves kurtosis in
    // both directions: squashing peaks pulls it down, clipping at the rail pushes
    // it up. Neither is speaker-count information. A `kurt_span` excursion on a span
    // with a low crest factor or nonzero `clip` is suspect; the same excursion at
    // crest 4 with clip 0 is real.
    var crestFactor: Double = .nan

    // Fraction of samples at or beyond `clipThreshold`. Hard clipping, as distinct
    // from the soft limiting the crest factor catches.
    var clippedFraction: Double = .nan

    var noiseFloor: Double = 0
    // 90th-percentile frame level. Half of the activity threshold, and the column
    // that makes a repeat of the schema-2 inversion visible without re-deriving it.
    var loudLevel: Double = 0
    var speechSeconds: Double = 0
    var frames: Int = 0
    var activeFrames: Int = 0
    var voicedFrames: Int = 0

    // A — excess kurtosis over the WHOLE span, unfiltered (0 = Gaussian).
    //
    // THE CLASSICAL BSS MEASURE. Speech is strongly super-Gaussian because it
    // alternates between loud and near-silent, and summing two independent sources
    // drives the distribution toward Gaussian. Expect POSITIVE; a FALL is the
    // mixing evidence. Measured 1.16–12.76 on real dictation.
    var kurtosisSpan: Double = .nan

    // A — excess kurtosis pooled over speech-ACTIVE samples only.
    //
    // A DIFFERENT QUANTITY WITH THE OPPOSITE SIGN CONVENTION. Filtering removes the
    // loud/silent alternation and leaves sustained vowels, which are quasi-periodic
    // and trend toward a sine's -1.5. Here a RISE toward 0 is the cue, because two
    // overlaid vowels are less sinusoidal than one. Kept alongside `kurtosisSpan`
    // precisely because the two should move in OPPOSITE directions under overlap;
    // agreement between two contradictory conventions is worth more than either.
    var kurtosisActive: Double = .nan

    // Per-frame excess kurtosis over active frames — median, and the low tail. If
    // overlap is intermittent inside the span the median hides it; p10 does not.
    var kurtosisMedian: Double = .nan
    var kurtosisP10: Double = .nan

    // A — TF-plane sparsity. Gini is the best-validated sparsity measure and is
    // scale-invariant; Hoyer is the same idea without the sort. Both FALL when a
    // second source fills the gaps between the first one's harmonics.
    var tfGini: Double = .nan
    var tfHoyer: Double = .nan

    // A — spectral flatness (Wiener entropy) in dB, median over active frames.
    //
    // IN dB SINCE SCHEMA 4. The raw ratio of geometric to arithmetic mean sits at
    // 1e-3 for speech, so schema 3 logged 0.000–0.006 — after rounding, barely
    // three distinct values across a whole session. The same data spans roughly
    // -30 to -22 dB, which is a column you can fit a distribution to. 0 dB is white
    // noise; more negative is more tonal.
    var flatnessMedian: Double = .nan

    // B — cepstral peak prominence, median over voiced frames. Arbitrary but
    // CONSISTENT units (the cepstrum carries an FFT scale factor); compare within
    // this app only, never against a published CPPS figure.
    var cppMedian: Double = .nan
    // B — harmonics-to-noise ratio in dB, median over voiced frames.
    var hnrMedian: Double = .nan
    // B — median corrected autocorrelation peak. DIAGNOSTIC, not a candidate: it is
    // what `voicedThreshold` is applied to, so if `voiced` ever equals `active`
    // again this column says whether the correction is inflating it.
    var autocorrMedian: Double = .nan
    // B — THE headline metric of the family: mean number of periodicities per voiced
    // frame that are neither harmonically related to the dominant one nor
    // explicable as sub-period structure. Single speaker should sit near 0.
    var competingPeaksMean: Double = .nan
    var competingPeaksMax: Int = 0
    // B — F0 median and interquartile range over voiced frames. A wide IQR means
    // alternating dominance or octave errors; measured 122 Hz on a span where a
    // second speaker was present, against 2–11 Hz on single-speaker spans.
    var f0Median: Double = .nan
    var f0IQR: Double = .nan
}

// Family C. Needs the gate's templates, so it is produced by `SpeakerGate.probe`.
struct SubspaceMetrics {
    // Cosine distance to the centroid — the number the gate already acts on,
    // carried here so a CSV row is self-contained.
    var distance: Double = .nan
    // Fraction of the TANGENTIAL deviation lying off the within-speaker subspace.
    // See `probe` for why the radial part is removed first.
    var tangentialOffRatio: Double = .nan
    // What that ratio would be for a direction unrelated to the subspace:
    // sqrt(1 - k/(D-1)), in the tangent space so D-1 rather than D.
    var chanceRatio: Double = .nan
    // `tangentialOffRatio / chanceRatio`. ~1 means "as off-subspace as random";
    // below 1 means the span moved along the speaker's own variation.
    //
    // MEASURED 0.93–1.00 ACROSS TWELVE SPANS — i.e. pinned at chance. With 8
    // templates from 2 takes the within-speaker subspace explains almost none of
    // the tangential variation. Not redundant with `d` any more (schema 2 fixed
    // that), but not yet discriminating either; unjudgeable until enrollment
    // carries 16 templates across three conditions.
    var offSubspaceNormalised: Double = .nan
    // Distance to the CLOSEST template rather than to the centroid. A quiet span
    // should be near the quiet template even when far from the mean.
    var nearestTemplate: Double = .nan
    // Mean template-to-centroid distance — how spread the enrollment itself is.
    var templateSpread: Double = .nan
    // Rank of the tangential within-speaker subspace. With n templates this must be
    // at most n-1; if it equals n, the radial deflation has regressed.
    var subspaceRank: Int = 0
}

// Family E.
struct SubwindowMetrics {
    var count: Int = 0
    var minDistance: Double = .nan
    var maxDistance: Double = .nan
    // max - min. The direct reading of "present somewhere, not dominant across".
    var spread: Double = .nan
    var meanDistance: Double = .nan
}

// The three families as one value, carried on `RescuedSpan.metrics`.
//
// NO RENDERING HERE. Row formatting lives in `TSEMetricsLog.columns`, which
// declares the title, width and value extractor for every column in one array, so
// the header and the rows are generated from the same source and cannot drift.
// This struct used to carry its own `consoleLine`, which meant two renderers for
// the same data — and after the CSV came out they both printed, giving two lines
// per span.
struct OverlapMetrics {
    var signal = SignalMetrics()
    var subspace: SubspaceMetrics?
    var subwindows: SubwindowMetrics?
}

// MARK: - Analyzer

// One shared instance: it owns an `FFTSetup`, which is expensive to build and is
// NOT documented as safe for concurrent use, so `analyze` takes a lock. The gate
// path is serial anyway.
final class TSEOverlapAnalyzer: @unchecked Sendable {

    static let shared = TSEOverlapAnalyzer()

    private let lock = NSLock()
    private let setup: FFTSetup
    private let log2n: vDSP_Length = 10             // 2^10 = 1024
    private let n = TSEMetricsConfig.frameSize      // 1024
    private let hop = TSEMetricsConfig.frameHop     // 256
    private let bins: Int                           // 513
    private let window: [Float]
    // Boersma's correction: the autocorrelation of a WINDOWED frame is the signal's
    // autocorrelation multiplied by the window's own. Dividing it back out is what
    // stops HNR drifting with lag. It amplifies noise as the lag approaches the
    // window length, which is why the window is 4.5 periods long at the F0 floor
    // rather than the 2.2 it was in schema 1.
    private let windowAutocorr: [Float]
    private let lagMin: Int
    private let lagMax: Int
    private let quefrencyMin: Int
    private let quefrencyMax: Int

    private init() {
        bins = n / 2 + 1
        var w = [Float](repeating: 0, count: n)
        for i in 0..<n { w[i] = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(n)) }
        window = w

        let sr = Double(SpeakerGate.sampleRate)
        lagMin = max(1, Int(sr / TSEMetricsConfig.maxF0))       // 40
        lagMax = min(n - 1, Int(sr / TSEMetricsConfig.minF0))   // 228
        quefrencyMin = lagMin
        quefrencyMax = min(n / 2 - 1, Int(sr / 60.0))           // 266

        var rw = [Float](repeating: 0, count: n)
        var energy: Float = 0
        for i in 0..<n { energy += w[i] * w[i] }
        for lag in 0..<n {
            var acc: Float = 0
            for i in 0..<(n - lag) { acc += w[i] * w[i + lag] }
            rw[lag] = energy > 0 ? acc / energy : 0
        }
        windowAutocorr = rw

        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    // Measure one span. Returns nil only when the span is shorter than a single
    // analysis frame (64 ms), which the segmenter should already have prevented.
    func analyze(_ span: [Float]) -> SignalMetrics? {
        guard span.count >= n else { return nil }
        lock.lock()
        defer { lock.unlock() }

        let sr = Double(SpeakerGate.sampleRate)
        var m = SignalMetrics()
        m.durationSeconds = Double(span.count) / sr

        var overallRMS: Float = 0
        vDSP_rmsqv(span, 1, &overallRMS, vDSP_Length(span.count))
        m.rms = Double(overallRMS)

        // Limiter diagnostics, one pass, no plumbing. See `crestFactor` for why
        // these have to exist before any kurtosis reading can be trusted.
        var peak: Float = 0
        vDSP_maxmgv(span, 1, &peak, vDSP_Length(span.count))
        m.crestFactor = overallRMS > 1e-9 ? Double(peak / overallRMS) : .nan
        var clipped = 0
        for v in span where abs(v) >= TSEMetricsConfig.clipThreshold { clipped += 1 }
        m.clippedFraction = Double(clipped) / Double(span.count)

        // A: the CLASSICAL kurtosis, over every sample of the span with no activity
        // filter. This is the one the BSS argument is about; the active-only figure
        // below is a different quantity with an inverted sign convention.
        m.kurtosisSpan = Self.excessKurtosis(span)

        let frameCount = 1 + (span.count - n) / hop
        m.frames = frameCount

        var levels = [Float](repeating: 0, count: frameCount)
        span.withUnsafeBufferPointer { src in
            for t in 0..<frameCount {
                var r: Float = 0
                vDSP_rmsqv(src.baseAddress! + t * hop, 1, &r, vDSP_Length(n))
                levels[t] = r
            }
        }
        let ordered = levels.sorted()
        let noiseFloor = ordered[min(ordered.count - 1, ordered.count / 5)]
        let loudLevel  = ordered[min(ordered.count - 1, ordered.count * 9 / 10)]
        m.noiseFloor = Double(noiseFloor)
        m.loudLevel = Double(loudLevel)

        // THE SPEECH THRESHOLD, and why it is a min() of two terms.
        //
        // `rescueSpans` computes this over a WINDOW, which contains silence, so its
        // 20th percentile really is a noise floor. Over a SPAN the same arithmetic
        // inverts: the segmenter chose this region because it is mostly voice, so
        // the 20th percentile is a speech frame and 3x it locks out nearly
        // everything. Measured: a span the gate scored 100% speech admitted 4 frames
        // of 83; one scored 88% admitted 1 of 156.
        //
        // Taking the SMALLER of the floor-relative and loud-relative terms means
        // whichever assumption holds for this span is the one that governs. A span
        // with real silence behaves exactly as before; a span without it can no
        // longer exclude its own content. It is also what makes the constant-
        // amplitude synthetic signals in `TSEMetricsSelfTest` analysable at all —
        // under schema 2 a pure sine had ZERO active frames.
        let floorRelative = noiseFloor * TSEMetricsConfig.speechFloorMultiple
        let loudRelative  = loudLevel * TSEMetricsConfig.loudFraction
        let threshold = max(TSEMetricsConfig.absoluteFloor, min(floorRelative, loudRelative))

        var frame = [Float](repeating: 0, count: n)
        var windowed = [Float](repeating: 0, count: n)
        var power = [Float](repeating: 0, count: bins)
        var logMagnitude = [Float](repeating: 0, count: bins)
        var cepstrum = [Float](repeating: 0, count: n)
        var autocorr = [Float](repeating: 0, count: n)

        // Pooled moments for the active-frame kurtosis. Accumulated over the first
        // `hop` samples of each active frame, so 75%-overlapped frames cannot
        // double-count.
        var count = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0

        var magnitudes: [Float] = []
        magnitudes.reserveCapacity(frameCount * bins)

        var frameKurtosis: [Double] = []
        var flatness: [Double] = []
        var cppValues: [Double] = []
        var hnrValues: [Double] = []
        var acValues: [Double] = []
        var peakCounts: [Double] = []
        var f0Values: [Double] = []

        for t in 0..<frameCount {
            guard levels[t] > threshold else { continue }
            m.activeFrames += 1

            let offset = t * hop
            for i in 0..<n { frame[i] = span[offset + i] }
            var mean: Float = 0
            vDSP_meanv(frame, 1, &mean, vDSP_Length(n))
            var negativeMean = -mean
            frame.withUnsafeMutableBufferPointer { p in
                vDSP_vsadd(p.baseAddress!, 1, &negativeMean, p.baseAddress!, 1, vDSP_Length(n))
            }

            for i in 0..<hop {
                let v = Double(frame[i])
                count += 1; s1 += v; s2 += v * v; s3 += v * v * v; s4 += v * v * v * v
            }
            frameKurtosis.append(Self.excessKurtosis(frame))

            vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(n))
            powerSpectrum(of: windowed, into: &power)

            var sumPower: Float = 0
            var sumLog: Float = 0
            for k in 0..<bins {
                let p = max(power[k], 1e-20)
                sumPower += p
                sumLog += log(p)
                logMagnitude[k] = 0.5 * log(p)
                magnitudes.append(p.squareRoot())
            }
            let binCount = Float(bins)
            let geometric = exp(sumLog / binCount)
            let arithmetic = sumPower / binCount
            let ratio = arithmetic > 0 ? geometric / arithmetic : 0
            flatness.append(ratio > 1e-12 ? 10 * Double(log10(ratio)) : .nan)

            // B: cepstral peak prominence
            evenInverse(logMagnitude, into: &cepstrum)
            cppValues.append(cepstralPeakProminence(cepstrum))

            // B: periodicity. Autocorrelation via Wiener-Khinchin, which is one
            // inverse FFT rather than a lag loop.
            evenInverse(power, into: &autocorr)
            let zero = autocorr[0]
            guard zero > 1e-20 else { continue }
            var best: Float = 0
            var bestLag = 0
            for lag in lagMin...lagMax {
                guard let r = corrected(autocorr, lag, zero) else { continue }
                if r > best { best = r; bestLag = lag }
            }
            guard bestLag > 0 else { continue }
            acValues.append(Double(best))
            guard best > TSEMetricsConfig.voicedThreshold else { continue }
            m.voicedFrames += 1

            let clamped = min(Double(best), 0.9999)
            hnrValues.append(10 * log10(clamped / (1 - clamped)))
            f0Values.append(sr / interpolatedLag(autocorr, around: bestLag, zero: zero))
            peakCounts.append(Double(competingPeaks(autocorr,
                                                    zero: zero,
                                                    dominantLag: bestLag,
                                                    dominant: best)))
        }

        m.speechSeconds = Double(m.activeFrames) * Double(hop) / sr

        if count > 3 {
            let mu = s1 / count
            let m2 = s2 / count - mu * mu
            let m4 = s4 / count - 4 * mu * (s3 / count)
                   + 6 * mu * mu * (s2 / count) - 3 * mu * mu * mu * mu
            m.kurtosisActive = m2 > 1e-20 ? m4 / (m2 * m2) - 3 : .nan
        }
        m.kurtosisMedian = Self.percentile(frameKurtosis, 0.5)
        m.kurtosisP10 = Self.percentile(frameKurtosis, 0.10)
        m.flatnessMedian = Self.percentile(flatness, 0.5)
        m.cppMedian = Self.percentile(cppValues, 0.5)
        m.hnrMedian = Self.percentile(hnrValues, 0.5)
        m.autocorrMedian = Self.percentile(acValues, 0.5)
        m.competingPeaksMean = peakCounts.isEmpty
            ? .nan : peakCounts.reduce(0, +) / Double(peakCounts.count)
        m.competingPeaksMax = Int(peakCounts.max() ?? 0)
        m.f0Median = Self.percentile(f0Values, 0.5)
        let q1 = Self.percentile(f0Values, 0.25), q3 = Self.percentile(f0Values, 0.75)
        m.f0IQR = (q1.isNaN || q3.isNaN) ? .nan : q3 - q1

        let (gini, hoyer) = Self.sparsity(of: &magnitudes)
        m.tfGini = gini
        m.tfHoyer = hoyer

        return m
    }

    // MARK: FFT

    private func powerSpectrum(of frame: [Float], into power: inout [Float]) {
        let half = n / 2
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        // vDSP packs DC in realp[0] and NYQUIST in imagp[0], and scales by 2 — the
        // same trap TSEFeatures documents. Get this wrong and every metric above
        // still produces plausible-looking numbers.
        power[0] = (re[0] * 0.5) * (re[0] * 0.5)
        power[half] = (im[0] * 0.5) * (im[0] * 0.5)
        for k in 1..<half {
            let r = re[k] * 0.5, i = im[k] * 0.5
            power[k] = r * r + i * i
        }
    }

    // Inverse transform of a REAL, EVEN spectrum — which both the log-magnitude
    // (cepstrum) and the power spectrum (autocorrelation) are. Output scale is an
    // arbitrary constant, and both consumers are scale-insensitive: the
    // autocorrelation is normalised by its own zero lag, and CPP is a DIFFERENCE
    // from a regression line in the same units.
    private func evenInverse(_ spectrum: [Float], into out: inout [Float]) {
        let half = n / 2
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        re[0] = spectrum[0]
        im[0] = spectrum[half]
        for k in 1..<half { re[k] = spectrum[k]; im[k] = 0 }

        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                out.withUnsafeMutableBufferPointer { op in
                    op.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ztoc(&split, 1, cp, 2, vDSP_Length(half))
                    }
                }
            }
        }
        var scale = Float(1.0) / Float(n)
        out.withUnsafeMutableBufferPointer { p in
            vDSP_vsmul(p.baseAddress!, 1, &scale, p.baseAddress!, 1, vDSP_Length(n))
        }
    }

    // MARK: Metric kernels

    // Normalised autocorrelation at one lag, with the window's own autocorrelation
    // divided back out. Nil where the correction would amplify noise more than
    // signal.
    private func corrected(_ autocorr: [Float], _ lag: Int, _ zero: Float) -> Float? {
        guard lag > 0, lag < n else { return nil }
        let correction = windowAutocorr[lag]
        guard correction > TSEMetricsConfig.windowCorrectionFloor else { return nil }
        return (autocorr[lag] / zero) / correction
    }

    // Peak of the cepstrum in the F0 quefrency band, measured against the linear
    // trend of the cepstrum in that same band. The regression is what makes it a
    // PROMINENCE rather than a level, and is why the arbitrary FFT scale factor does
    // not matter.
    private func cepstralPeakProminence(_ cepstrum: [Float]) -> Double {
        guard quefrencyMax > quefrencyMin + 4 else { return .nan }
        var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0
        var peak = -Double.greatestFiniteMagnitude
        var peakQ = quefrencyMin
        for q in quefrencyMin...quefrencyMax {
            let x = Double(q), y = Double(cepstrum[q])
            sumX += x; sumY += y; sumXY += x * y; sumXX += x * x
            if y > peak { peak = y; peakQ = q }
        }
        let pointCount = Double(quefrencyMax - quefrencyMin + 1)
        let denominator = pointCount * sumXX - sumX * sumX
        guard abs(denominator) > 1e-12 else { return .nan }
        let slope = (pointCount * sumXY - sumX * sumY) / denominator
        let intercept = (sumY - slope * sumX) / pointCount
        return peak - (intercept + slope * Double(peakQ))
    }

    // Count periodicities the frame supports that cannot be explained by the
    // dominant voice.
    //
    // THREE GUARDS, and schema 1 only had the first:
    //
    // 1. HARMONIC RELATION (octave-error immunity). Any peak whose lag ratio to the
    //    dominant lag is near an integer — in either direction — is the same voice's
    //    harmonic or subharmonic and is excluded. This is why no F0 tracker is
    //    needed: an octave error contributes zero by construction.
    //
    // 2. SUB-PERIOD FLOOR. Candidates below HALF the dominant lag are rejected. With
    //    F0 ~110 Hz (lag 145) a 300 Hz formant resonance peaks at lag 53, a ratio of
    //    2.7 — not near an integer, so schema 1 counted it as a second speaker, and
    //    `peaks_mean` never fell below 0.60 on single-speaker audio. It reaches 0.00
    //    now.
    //    KNOWN BLIND SPOT: an interferer more than an octave above the target is
    //    excluded by this floor. Such a voice sits near a 2:1 ratio and guard 1 was
    //    already removing it, so the floor costs little that was not already lost.
    //
    // 3. HARMONIC SUPPORT. A real period t implies further peaks at 2t, 3t…; a
    //    resonance does not. A candidate must show a peak at 2t reaching
    //    `harmonicSupportFraction` of its own. Skipped when 2t falls outside the
    //    search range, which makes long-lag candidates slightly easier to admit —
    //    acceptable, since guard 2 has already screened them.
    private func competingPeaks(_ autocorr: [Float],
                                zero: Float,
                                dominantLag: Int,
                                dominant: Float) -> Int {
        let bar = max(dominant * TSEMetricsConfig.competingPeakFraction,
                      TSEMetricsConfig.competingPeakFloor)
        let floorLag = max(lagMin, dominantLag / 2)
        guard floorLag + 2 < lagMax else { return 0 }

        var found = 0
        var lag = floorLag + 1
        while lag < lagMax {
            guard let r = corrected(autocorr, lag, zero),
                  let previous = corrected(autocorr, lag - 1, zero),
                  let next = corrected(autocorr, lag + 1, zero),
                  r >= previous, r > next, r >= bar else { lag += 1; continue }

            let ratio = lag > dominantLag
                ? Double(lag) / Double(dominantLag)
                : Double(dominantLag) / Double(lag)
            let nearest = max(1.0, ratio.rounded())
            guard abs(ratio - nearest) / nearest > TSEMetricsConfig.harmonicTolerance else {
                lag += 2; continue
            }

            let doubled = lag * 2
            if doubled <= lagMax {
                guard let support = corrected(autocorr, doubled, zero),
                      support >= r * TSEMetricsConfig.harmonicSupportFraction else {
                    lag += 2; continue
                }
            }

            found += 1
            lag += 2      // step past the peak's own shoulder
        }
        return found
    }

    // Parabolic interpolation around the autocorrelation peak. Without it F0
    // quantises to sr/lag, and the quantisation alone would inflate `f0IQR`.
    private func interpolatedLag(_ autocorr: [Float], around lag: Int, zero: Float) -> Double {
        guard lag > 0, lag < n - 1 else { return Double(lag) }
        let a = Double(autocorr[lag - 1] / zero)
        let b = Double(autocorr[lag] / zero)
        let c = Double(autocorr[lag + 1] / zero)
        let denominator = a - 2 * b + c
        guard abs(denominator) > 1e-12 else { return Double(lag) }
        let shift = 0.5 * (a - c) / denominator
        return Double(lag) + max(-1, min(1, shift))
    }

    // Gini and Hoyer sparsity of the pooled magnitude values.
    //
    // Gini needs a sort (sub-millisecond with vDSP); Hoyer does not. Both are here
    // because they disagree in informative ways — Hoyer is driven by the overall
    // L1/L2 ratio, Gini by the shape of the whole distribution, and a second speaker
    // moves them by different amounts.
    private static func sparsity(of values: inout [Float]) -> (gini: Double, hoyer: Double) {
        let count = values.count
        guard count > 1 else { return (.nan, .nan) }

        var l1: Float = 0, l2: Float = 0
        vDSP_sve(values, 1, &l1, vDSP_Length(count))
        vDSP_svesq(values, 1, &l2, vDSP_Length(count))
        l2 = l2.squareRoot()
        guard l1 > 1e-20, l2 > 1e-20 else { return (.nan, .nan) }

        let root = Double(count).squareRoot()
        let hoyer = (root - Double(l1) / Double(l2)) / (root - 1)

        values.withUnsafeMutableBufferPointer { p in
            vDSP_vsort(p.baseAddress!, vDSP_Length(count), 1)   // ascending
        }
        var accumulated = 0.0
        let denominator = Double(l1)
        let total = Double(count)
        for (index, v) in values.enumerated() {
            let k = Double(index + 1)
            accumulated += (Double(v) / denominator) * ((total - k + 0.5) / total)
        }
        return (1 - 2 * accumulated, hoyer)
    }

    // Excess kurtosis about the sample mean. 0 = Gaussian, -1.5 = pure sine,
    // -2 = square wave, strongly positive = sparse/impulsive. The first two are
    // exact and are what `TSEMetricsSelfTest` asserts.
    private static func excessKurtosis(_ x: [Float]) -> Double {
        guard x.count > 3 else { return .nan }
        var mean = 0.0
        for v in x { mean += Double(v) }
        mean /= Double(x.count)

        var m2 = 0.0, m4 = 0.0
        for v in x {
            let d = Double(v) - mean
            let sq = d * d
            m2 += sq
            m4 += sq * sq
        }
        let count = Double(x.count)
        m2 /= count; m4 /= count
        guard m2 > 1e-20 else { return .nan }
        return m4 / (m2 * m2) - 3
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let clean = values.filter { $0.isFinite }.sorted()
        guard !clean.isEmpty else { return .nan }
        if clean.count == 1 { return clean[0] }
        let position = p * Double(clean.count - 1)
        let low = Int(position.rounded(.down))
        let high = min(clean.count - 1, low + 1)
        let fraction = position - Double(low)
        return clean[low] * (1 - fraction) + clean[high] * fraction
    }
}

// MARK: - Family C: off-subspace residual

extension SpeakerGate {

    // The gate's verdict PLUS the shape information the centroid throws away.
    //
    // TAKES THE EMBEDDING, DOES NOT COMPUTE IT. `classify` has already run ECAPA
    // over this exact audio by the time anything calls this, so embedding again was
    // one wasted ANE inference per span — on the serial pump that publishes audio to
    // Whisper, against an ANE the encoder already occupies. Family C now costs
    // nothing but arithmetic: a Gram-Schmidt over 8 templates in 192 dimensions,
    // ~12k multiply-adds.
    //
    // `classify` reduces the templates to one point and asks how far the span is
    // from it. That single number cannot distinguish "you, quieter than usual" from
    // "someone else" — both are simply far. But the templates span a SUBSPACE of
    // within-speaker variation (loud/soft/masked, which is what multi-condition
    // calibration is for), and those two cases differ in DIRECTION.
    //
    // WHY THE RADIAL COMPONENT IS REMOVED FIRST (schema 2).
    //
    // Schema 1 measured the residual of `r = e - c` against a basis built from
    // `t_i - c`, and the result was a near-perfect INVERSE of the distance: ten
    // spans, one inversion. It carried no information the gate did not have.
    //
    // The mechanism is geometric. Every embedding is L2 normalised, so `e` and `c`
    // both lie on the unit sphere and
    //
    //     r · c = e · c - 1 = (1 - d) - 1 = -d          |r| = sqrt(2d)
    //
    // The radial component of the deviation IS the distance, exactly. And because
    // `c` was the NORMALISED mean rather than the raw mean, the centred templates
    // did not sum to zero — their leftover radial component became a spurious extra
    // basis vector pointing along `c` itself. (Visible in schema-1 logs as
    // `off_chance` 0.979 = sqrt(1 - 8/192) with only 8 templates, i.e. rank 8 where
    // 7 was the maximum.) That vector let the "within-speaker subspace" absorb the
    // radial part, so the residual fell as sqrt(1 - d/2 - …).
    //
    // The fix is to ask the question in the TANGENT SPACE. Radial displacement is
    // distance and is already reported; what is informative is the DIRECTION of the
    // tangential displacement, which an interferer changes and a gain or
    // vocal-effort change does not. Confirmed: rank reads 7, `off_chance` 0.982, and
    // the monotone relationship with `d` is gone.
    //
    // READ THE RATIO AGAINST `chanceRatio`, NEVER RAW. A tangent space of 191
    // dimensions with a rank-7 subspace leaves an unrelated direction ~98% off it.
    // Measured range so far is 0.93–1.00 — pinned at chance, i.e. 8 templates from
    // 2 takes do not describe enough within-speaker variation for this to
    // discriminate. Revisit at 16 templates across three conditions.
    //
    // - Parameter embedding: a UNIT vector from `SpeakerGate.embed`, normally
    //   carried on `GateResult.embedding`. Passing an unnormalised vector silently
    //   produces meaningless ratios — nothing here re-normalises it.
    func probe(embedding: [Double]) -> SubspaceMetrics? {
        let snapshot = currentTemplates
        guard snapshot.count >= 3,
              let dimension = snapshot.first?.count,
              embedding.count == dimension else { return nil }

        func dot(_ a: [Double], _ b: [Double]) -> Double {
            var sum = 0.0
            for i in 0..<dimension { sum += a[i] * b[i] }
            return sum
        }
        func norm(_ a: [Double]) -> Double { dot(a, a).squareRoot() }

        var mean = [Double](repeating: 0, count: dimension)
        for t in snapshot {
            for i in 0..<dimension { mean[i] += t[i] }
        }
        for i in 0..<dimension { mean[i] /= Double(snapshot.count) }
        let centre = Self.unit(mean)

        var metrics = SubspaceMetrics()
        metrics.distance = 1.0 - dot(centre, embedding)
        metrics.nearestTemplate = snapshot.map { 1.0 - dot($0, embedding) }.min() ?? .nan
        metrics.templateSpread = snapshot
            .map { 1.0 - dot(centre, $0) }
            .reduce(0, +) / Double(snapshot.count)

        // Strip the component along the centroid. Whatever survives is movement
        // ACROSS the sphere rather than toward or away from the enrolled point.
        func tangential(_ v: [Double]) -> [Double] {
            let radial = dot(v, centre)
            var out = v
            for i in 0..<dimension { out[i] -= radial * centre[i] }
            return out
        }

        // Orthonormal basis of the templates' TANGENTIAL deviations (modified
        // Gram-Schmidt). Those deviations sum to zero by construction — the raw sum
        // is purely radial and `tangential` removes it — so the rank is at most
        // count - 1. If `subspaceRank` ever equals the template count, this
        // deflation has regressed.
        var basis: [[Double]] = []
        for t in snapshot {
            var v = [Double](repeating: 0, count: dimension)
            for i in 0..<dimension { v[i] = t[i] - centre[i] }
            v = tangential(v)
            for u in basis {
                let projection = dot(u, v)
                for i in 0..<dimension { v[i] -= projection * u[i] }
            }
            let length = norm(v)
            if length > 1e-6 { basis.append(v.map { $0 / length }) }
        }
        metrics.subspaceRank = basis.count
        guard !basis.isEmpty, dimension > 1 else { return metrics }

        var residual = [Double](repeating: 0, count: dimension)
        for i in 0..<dimension { residual[i] = embedding[i] - centre[i] }
        residual = tangential(residual)
        let total = norm(residual)
        guard total > 1e-9 else { return metrics }

        for u in basis {
            let projection = dot(u, residual)
            for i in 0..<dimension { residual[i] -= projection * u[i] }
        }

        metrics.tangentialOffRatio = norm(residual) / total
        metrics.chanceRatio = (1.0 - Double(basis.count) / Double(dimension - 1)).squareRoot()
        metrics.offSubspaceNormalised = metrics.chanceRatio > 1e-9
            ? metrics.tangentialOffRatio / metrics.chanceRatio : .nan
        return metrics
    }
}
