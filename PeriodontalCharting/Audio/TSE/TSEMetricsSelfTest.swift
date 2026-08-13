//
//  TSEMetricsSelfTest.swift
//  PeriodontalCharting
//
//  PROOF, NOT PLAUSIBILITY.
//
//  Every metric in `TSEOverlapMetrics` returns a well-formed number whether or not
//  the code behind it is correct — a wrong FFT packing, a wrong moment
//  accumulation and a wrong lag range all produce output that looks like data. That
//  is the same hazard `TSEFeatures` warns about at the top of its own file: "re-run
//  the parity check rather than trusting the shape of the output."
//
//  Two of these metrics have EXACT analytic references and need no tolerance
//  argument at all:
//
//      pure sine       excess kurtosis = -1.5        crest factor = sqrt(2)
//      Gaussian noise  excess kurtosis =  0
//
//  Those two are the cheapest correctness proof available on the whole file, and
//  they exercise the shared machinery — frame extraction, mean removal, moment
//  accumulation — that every other metric is built on. The rest of the checks below
//  are behavioural rather than analytic: they assert the DESIGNED behaviour of the
//  competing-peak guards, which is the only part of family B that makes a claim
//  strong enough to be wrong in an interesting way.
//
//  WHY THIS IS NOT A TEST TARGET: there isn't one (FIXES, BP2), and `main.swift`
//  sits outside `PeriodontalCharting/` so it is in no target and cannot run. Call
//  `run()` from `SelectionDebugMenu` and read the console. When BP2 lands, the
//  assertions move over unchanged — they are already pure functions of synthetic
//  input with no device, no mic and no model.
//
//  RUN IT AFTER TOUCHING `analyze`. Schema 2 changed the analysis window from 512
//  to 1024 and schema 3 changed the activity threshold; both silently altered every
//  frame-derived number, and neither was verifiable from a session log.
//
//  A NOTE ON WHAT SCHEMA 3 UNBLOCKED: constant-amplitude synthetic signals were
//  UNANALYSABLE before it. A pure sine has an identical level in every frame, so the
//  20th and 90th percentiles coincide, and the old `noiseFloor * 3` threshold sat
//  three times above every frame — zero active frames, no output at all. The
//  `min(floor * 3, loud * 0.15)` form admits them. Had this file existed in schema
//  2, test 1 below would have failed loudly and the span inversion would have been
//  caught weeks earlier.
//

import Accelerate
import Foundation

enum TSEMetricsSelfTest {

    private static let sampleRate = Double(SpeakerGate.sampleRate)
    private static let seconds = 3.0

    // MARK: - Entry point

    // Runs every check and returns a printable report. Never throws and never
    // asserts — a failing metric must not be able to take the app down from a debug
    // menu.
    static func run() -> String {
        var out = "[TSE/selftest] schema \(TSEMetricsConfig.schemaVersion), "
        out += "frame \(TSEMetricsConfig.frameSize) hop \(TSEMetricsConfig.frameHop)\n"
        var failures = 0

        func check(_ name: String,
                   _ value: Double,
                   expected: String,
                   pass: Bool) {
            let mark = pass ? "PASS" : "FAIL"
            if !pass { failures += 1 }
            out += String(format: "  %@  %-34@ %10.4f   expected %@\n",
                          mark as NSString, name as NSString, value, expected as NSString)
        }

        // ---- 1. Pure sine. THE ANCHOR CHECK.
        //
        // Excess kurtosis of a sinusoid is exactly -1.5 and its crest factor is
        // exactly sqrt(2), independent of frequency, amplitude and phase. If either
        // is wrong, the fault is in frame extraction or moment accumulation and
        // every other number in the file is suspect.
        if let m = analyze(sine(frequency: 200, amplitude: 0.5)) {
            check("sine kurt_span", m.kurtosisSpan,
                  expected: "-1.500 +/- 0.02", pass: abs(m.kurtosisSpan + 1.5) < 0.02)
            check("sine crest", m.crestFactor,
                  expected: "1.414 +/- 0.01", pass: abs(m.crestFactor - 2.0.squareRoot()) < 0.01)
            check("sine clip", m.clippedFraction,
                  expected: "0", pass: m.clippedFraction == 0)
            // A sine is one bin: maximally tonal, maximally sparse.
            check("sine flat_med (dB)", m.flatnessMedian,
                  expected: "< -25", pass: m.flatnessMedian < -25)
            check("sine gini", m.tfGini,
                  expected: "> 0.90", pass: m.tfGini > 0.90)
            // Schema 3 regression guard: a constant-amplitude signal must not have
            // its own content thresholded away.
            check("sine active fraction", Double(m.activeFrames) / Double(max(m.frames, 1)),
                  expected: "> 0.95", pass: Double(m.activeFrames) > 0.95 * Double(m.frames))
        } else {
            out += "  FAIL  sine — analyze returned nil\n"; failures += 1
        }

        // ---- 2. Gaussian white noise. THE OTHER ANCHOR.
        //
        // Excess kurtosis 0 by definition. With 48000 samples the standard error is
        // sqrt(24/n) ~ 0.022, so 0.15 is roughly seven sigma — a failure here is a
        // bug, not a sampling accident.
        if let m = analyze(gaussian(amplitude: 0.2, seed: 0x5EED)) {
            check("noise kurt_span", m.kurtosisSpan,
                  expected: "0.000 +/- 0.15", pass: abs(m.kurtosisSpan) < 0.15)
            // Flat spectrum: flatness approaches 0 dB, sparsity is low.
            check("noise flat_med (dB)", m.flatnessMedian,
                  expected: "> -8", pass: m.flatnessMedian > -8)
            check("noise gini", m.tfGini,
                  expected: "< 0.65", pass: m.tfGini < 0.65)
        } else {
            out += "  FAIL  noise — analyze returned nil\n"; failures += 1
        }

        // ---- 3. Single voice. One pulse train through a 300 Hz resonator.
        //
        // F0 must come back at 200 Hz, and `peaks_mean` must be ~0. THE RESONATOR IS
        // THE POINT: it puts an autocorrelation peak at lag 53 (16000/300), which is
        // above the sub-period floor of dominantLag/2 = 40 and is NOT harmonically
        // related to the 200 Hz period at lag 80 — ratio 1.51. Schema 1 counted
        // exactly this as a second speaker. It survives now only because guard 3
        // demands harmonic support at lag 106, and a 200 Hz train has no peak there.
        if let m = analyze(voice(f0: 200, resonance: 300, amplitude: 0.4, seed: 0xB0B)) {
            check("voice f0_med", m.f0Median,
                  expected: "200 +/- 3", pass: abs(m.f0Median - 200) < 3)
            check("voice peaks_mean", m.competingPeaksMean,
                  expected: "< 0.20", pass: m.competingPeaksMean < 0.20)
            check("voice hnr_med (dB)", m.hnrMedian,
                  expected: "> 5", pass: m.hnrMedian > 5)
        } else {
            out += "  FAIL  voice — analyze returned nil\n"; failures += 1
        }

        // ---- 4. Octave immunity. 100 Hz train with a heavily boosted 2nd harmonic.
        //
        // Alternate pulses are doubled, so the strongest autocorrelation peak may
        // land on either 160 (100 Hz) or 80 (200 Hz). Either way the two are related
        // by exactly 2:1 and guard 1 must exclude the other. THIS IS THE CHECK THAT
        // JUSTIFIES HAVING NO F0 TRACKER: an octave error is invisible to the metric
        // by construction, so tracking pitch correctly is not a prerequisite.
        if let m = analyze(voice(f0: 100, resonance: 300, amplitude: 0.4,
                                 seed: 0xC0C, alternatePulseGain: 2.0)) {
            check("octave peaks_mean", m.competingPeaksMean,
                  expected: "< 0.20", pass: m.competingPeaksMean < 0.20)
        } else {
            out += "  FAIL  octave — analyze returned nil\n"; failures += 1
        }

        // ---- 5. TWO VOICES. The check the whole family exists for.
        //
        // 150 Hz (lag 106.7) and 233 Hz (lag 68.7). The ratio is 1.553 — deliberately
        // far from any integer, so neither can be explained as the other's harmonic,
        // and both sit above the sub-period floor whichever one dominates. Both are
        // real periods, so both carry support at twice their lag.
        //
        // If this reads ~0 while test 3 also reads ~0, the metric is not detecting
        // overlap — it is detecting nothing, and a null result on real audio would
        // mean nothing either.
        var mixture = voice(f0: 150, resonance: 300, amplitude: 0.3, seed: 0xD0D)
        let second = voice(f0: 233, resonance: 700, amplitude: 0.3, seed: 0xE0E)
        for i in 0..<min(mixture.count, second.count) { mixture[i] += second[i] }
        if let m = analyze(mixture) {
            check("two-voice peaks_mean", m.competingPeaksMean,
                  expected: "> 0.50", pass: m.competingPeaksMean > 0.50)
            check("two-voice peaks_max", Double(m.competingPeaksMax),
                  expected: ">= 1", pass: m.competingPeaksMax >= 1)
        } else {
            out += "  FAIL  two-voice — analyze returned nil\n"; failures += 1
        }

        // ---- 6. The limiter confound, demonstrated rather than asserted away.
        //
        // A sine driven past full scale and clipped becomes squarer, and a square
        // wave has excess kurtosis -2. So clipping moves kurtosis by 0.3 with no
        // change whatsoever in speaker count — which is exactly why `crest` and
        // `clip` exist as control columns. This test documents the effect and proves
        // both columns register it.
        if let m = analyze(clippedSine(frequency: 200, amplitude: 1.4)) {
            check("clipped sine clip", m.clippedFraction,
                  expected: "> 0.05", pass: m.clippedFraction > 0.05)
            check("clipped sine crest", m.crestFactor,
                  expected: "< 1.40", pass: m.crestFactor < 1.40)
            check("clipped sine kurt_span", m.kurtosisSpan,
                  expected: "< -1.50 (toward -2)", pass: m.kurtosisSpan < -1.50)
        } else {
            out += "  FAIL  clipped sine — analyze returned nil\n"; failures += 1
        }

        out += failures == 0
            ? "[TSE/selftest] ALL PASS\n"
            : "[TSE/selftest] \(failures) FAILURE(S) — do not trust collected rows\n"
        return out
    }

    private static func analyze(_ signal: [Float]) -> SignalMetrics? {
        TSEOverlapAnalyzer.shared.analyze(signal)
    }

    // MARK: - Signal generators
    //
    // All deterministic: the same build produces the same numbers on every run, so a
    // change in output means a change in code rather than a change in luck.

    private static func sine(frequency: Double, amplitude: Float) -> [Float] {
        let count = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: count)
        let step = 2 * Double.pi * frequency / sampleRate
        for i in 0..<count { out[i] = amplitude * Float(sin(step * Double(i))) }
        return out
    }

    private static func clippedSine(frequency: Double, amplitude: Float) -> [Float] {
        sine(frequency: frequency, amplitude: amplitude).map { max(-1.0, min(1.0, $0)) }
    }

    private static func gaussian(amplitude: Float, seed: UInt64) -> [Float] {
        let count = Int(seconds * sampleRate)
        var rng = Random(seed: seed)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count { out[i] = amplitude * rng.gaussian() }
        return out
    }

    // A pulse train at `f0` through a two-pole resonator at `resonance`, plus a
    // little noise so the spectrum is not perfectly deterministic.
    //
    // The resonator is what makes this a fair test rather than a friendly one: it
    // creates sub-period autocorrelation structure of exactly the kind that made
    // schema 1 report competing speakers on single-speaker audio.
    //
    // `alternatePulseGain` boosts every second pulse, which strengthens the 2nd
    // harmonic and is how the octave-immunity case is built.
    private static func voice(f0: Double,
                              resonance: Double,
                              amplitude: Float,
                              seed: UInt64,
                              alternatePulseGain: Float = 1.0) -> [Float] {
        let count = Int(seconds * sampleRate)
        var rng = Random(seed: seed)
        var excitation = [Float](repeating: 0, count: count)

        var phase = 0.0
        let increment = f0 / sampleRate
        var pulseIndex = 0
        for i in 0..<count {
            phase += increment
            if phase >= 1.0 {
                phase -= 1.0
                excitation[i] = pulseIndex % 2 == 0 ? 1.0 : alternatePulseGain
                pulseIndex += 1
            }
        }

        // y[n] = x[n] + 2r cos(w) y[n-1] - r^2 y[n-2]
        let omega = 2 * Double.pi * resonance / sampleRate
        let r = 0.96
        let a1 = Float(2 * r * cos(omega))
        let a2 = Float(r * r)
        var out = [Float](repeating: 0, count: count)
        var y1: Float = 0, y2: Float = 0
        for i in 0..<count {
            let y = excitation[i] + a1 * y1 - a2 * y2
            out[i] = y
            y2 = y1; y1 = y
        }

        var peak: Float = 0
        vDSP_maxmgv(out, 1, &peak, vDSP_Length(count))
        guard peak > 1e-9 else { return out }
        let scale = amplitude / peak
        for i in 0..<count { out[i] = out[i] * scale + 0.002 * rng.gaussian() }
        return out
    }

    // Deterministic PRNG — an LCG plus Box-Muller. Not cryptographic and not meant
    // to be; it exists so a failing assertion is reproducible.
    private struct Random {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func nextUnit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) * (1.0 / 9007199254740992.0)
        }

        mutating func gaussian() -> Float {
            let u1 = max(nextUnit(), 1e-12)
            let u2 = nextUnit()
            return Float((-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2))
        }
    }
}
