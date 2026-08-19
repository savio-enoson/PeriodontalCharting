//
//  AutoGain.swift
//  PeriodontalCharting
//
//  Automatic gain, so a soft speaker and a loud one arrive at the same level.
//
//  WHAT THIS FIXES, AND WHAT IT DOES NOT.
//
//  It does NOT fix speaker verdicts. ECAPA normalises mean and variance per
//  utterance, so scaling moves speech and background together and the ratio
//  between them — which is what degrades the fingerprint — does not change.
//  journal.md measured `d` shifting 0.0000 across a 64x gain range. Enrolling the
//  quiet voice is what fixed that (see CalibrationTake).
//
//  It DOES fix two other things:
//    * Wav2Vec2 sees a consistent level. Its input is Z-score normalised per
//      chunk, so a chunk that is uniformly quiet normalises up its own noise.
//    * The energy thresholds stop varying by person. Measured across takes from
//      the same speaker, `[Gate] energy:` reported floors from 0.0027 to 0.0444
//      and thresholds from 0.0080 to 0.1332 — a 16x spread, purely from level.
//
//  DESIGN. A slow-moving multiplier, not per-buffer normalisation: normalising
//  each 100 ms chunk independently would pump the noise floor up during pauses
//  and squash the dynamics that `rescueSpans` relies on to find speech at all.
//

import Accelerate
import Foundation

struct AutoGain {

    /// Target RMS for speech. journal.md: healthy speech after normalisation sits
    /// at 0.05–0.2, and a good calibration recording measured 0.128.
    static let targetRMS: Float = 0.1

    /// Never amplify beyond this. A hard ceiling matters more than it looks:
    /// without one, a silent room drives the gain up until the noise floor hits
    /// the target and every hiss frame reads as speech.
    static let maxGain: Float = 12.0
    static let minGain: Float = 0.4

    /// Below this the buffer is treated as silence and the gain is HELD, not
    /// adapted. This is the anti-pumping rule, and it is only HALF of it — see
    /// `looksLikeSpeech`.
    ///
    /// ON ITS OWN THIS GUARD WAS TOO LOW TO DO ITS JOB. The measured post-gain
    /// floor on this device is 0.0466; a raw room floor above 0.004 therefore read
    /// as speech, and the gain adapted toward `targetRMS / rms` — up to 12x —
    /// pushing a quiet noisy room toward 0.1, which IS speech level. That fed the
    /// `Wav2VecViewModel` latch it was sitting next to.
    static let silenceRMS: Float = 0.004

    /// Rolling window for the contrast test, in seconds. Matches
    /// `Wav2VecViewModel.ActivityTuning.windowSeconds` on purpose: the two are
    /// answering the same question about the same buffers.
    static let contrastWindowSeconds: Double = 4.0
    static let floorPercentile: Double = 0.20
    static let loudPercentile: Double = 0.90

    /// Per-buffer smoothing (buffers are ~100 ms). 0.08 gives a ~1.5 s time
    /// constant — slow enough that a single loud word does not duck the next one,
    /// fast enough to follow a clinician leaning in and out over a patient.
    static let smoothing: Float = 0.08

    /// Above this, scale back rather than clip. Clipping is destroyed information
    /// (journal.md: recording.wav has 1,660 clipped samples, permanently lost).
    static let limitPeak: Float = 0.95

    private(set) var gain: Float = 1.0

    /// Pre-gain RMS history for the contrast test, trimmed to
    /// `contrastWindowSeconds`.
    private var rmsHistory: [(rms: Float, samples: Int)] = []
    private var rmsHistorySamples = 0

    /// Scale one buffer in place and update the running gain.
    ///
    /// The gain is applied BEFORE it is updated, so a sudden loud burst is not
    /// retroactively squashed — the next buffer absorbs it instead.
    mutating func apply(to buffer: inout [Float]) {
        guard !buffer.isEmpty else { return }

        var rms: Float = 0
        vDSP_rmsqv(buffer, 1, &rms, vDSP_Length(buffer.count))

        // Apply the CURRENT gain first.
        var g = gain
        vDSP_vsmul(buffer, 1, &g, &buffer, 1, vDSP_Length(buffer.count))

        // Soft ceiling. Only engages on a transient; the smoothing below then
        // pulls the steady-state gain down so it stops engaging.
        var peak: Float = 0
        vDSP_maxmgv(buffer, 1, &peak, vDSP_Length(buffer.count))
        if peak > Self.limitPeak {
            var trim = Self.limitPeak / peak
            vDSP_vsmul(buffer, 1, &trim, &buffer, 1, vDSP_Length(buffer.count))
        }

        // Adapt only on audio that looks like speech. Adapting during pauses is
        // what turns a quiet room into a loud one and defeats `rescueSpans`.
        //
        // TWO TESTS, NOT ONE. `silenceRMS` alone is a LEVEL test, and steady room
        // noise passes a level test — it is loud, it is simply flat. The contrast
        // test is what distinguishes them.
        guard rms > Self.silenceRMS, looksLikeSpeech(rms: rms, samples: buffer.count) else {
            return
        }

        let wanted = min(Self.maxGain, max(Self.minGain, Self.targetRMS / rms))
        gain += (wanted - gain) * Self.smoothing
    }

    /// Does the recent window look like speech rather than steady noise?
    ///
    /// Same rule as `Wav2VecViewModel.detectSpeech` and `rescueSpans`: a floor
    /// from the 20th percentile, a loud level from the 90th, and speech only when
    /// this buffer clears the floor AND the window has real dynamic range.
    /// Measured 14–50x on healthy speech, 2.3–3.4x on the noisy chunks.
    ///
    /// Before the window has filled it returns true, so a genuinely quiet speaker
    /// is not held at unity gain for the first seconds of a session — the
    /// `silenceRMS` guard above still applies throughout.
    private mutating func looksLikeSpeech(rms: Float, samples: Int) -> Bool {
        rmsHistory.append((rms, samples))
        rmsHistorySamples += samples

        let windowSamples = Int(Self.contrastWindowSeconds * Double(SpeakerGate.sampleRate))
        while rmsHistorySamples > windowSamples, let oldest = rmsHistory.first {
            rmsHistory.removeFirst()
            rmsHistorySamples -= oldest.samples
        }

        guard rmsHistorySamples >= windowSamples / 2 else { return true }

        let sorted = rmsHistory.map(\.rms).sorted()
        let floor = max(Self.percentile(sorted, Self.floorPercentile), Self.silenceRMS)
        let loud = Self.percentile(sorted, Self.loudPercentile)

        return rms > floor * SpeakerGateService.RescueTuning.speechFloorMultiple
            && loud / floor >= SpeakerGateService.RescueTuning.minDynamicRange
    }

    /// Nearest-rank percentile over an already-sorted array.
    private static func percentile(_ sorted: [Float], _ p: Double) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(sorted.count - 1, max(0, index))]
    }

    mutating func reset() {
        gain = 1.0
        rmsHistory = []
        rmsHistorySamples = 0
    }

    /// One-shot normalisation for a whole recording, for the calibration files.
    ///
    /// RMS-to-target rather than peak-to-1.0. Peak normalisation is hostage to a
    /// single transient — one cough, chair scrape or button tap scales everything
    /// else down around it — and it is why two takes from the same speaker
    /// produced noise floors of 0.0087 and 0.0444, a 5x difference that the energy
    /// segmenter then had to cope with.
    ///
    /// Measured on the RMS of the loudest half of the frames, so long silences at
    /// the start and end of a take do not drag the target down.
    static func normalise(_ samples: inout [Float]) {
        guard !samples.isEmpty else { return }

        let frame = SpeakerGate.sampleRate / 100 * 3      // 30 ms
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / max(1, frame))
        samples.withUnsafeBufferPointer { buffer in
            var i = 0
            while i + frame <= buffer.count {
                var r: Float = 0
                vDSP_rmsqv(buffer.baseAddress! + i, 1, &r, vDSP_Length(frame))
                levels.append(r)
                i += frame
            }
        }
        guard !levels.isEmpty else { return }

        let sorted = levels.sorted()
        let loudHalf = sorted[(sorted.count / 2)...]
        let speechRMS = loudHalf.reduce(0, +) / Float(loudHalf.count)
        guard speechRMS > 1e-6 else { return }

        var gain = min(maxGain, max(minGain, targetRMS / speechRMS))

        // Never push a transient into clipping while chasing the target.
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        if peak * gain > limitPeak { gain = limitPeak / max(peak, 1e-6) }

        vDSP_vsmul(samples, 1, &gain, &samples, 1, vDSP_Length(samples.count))
    }
}
