//
//  HighPassFilter.swift
//  PeriodontalCharting
//
//  80 Hz high-pass, second order. Removes DC, room rumble, handling noise and
//  desk thumps — everything below the human voice.
//
//  WHY, given journal.md measured the high-pass as worth only +0.003 on speaker
//  DISTANCES (inside noise): that measurement predates the energy segmenter, and
//  distances are not what this is for.
//
//  `rescueSpans` sets its speech threshold at `noiseFloor * 3`, where the floor is
//  the 20th-percentile 30 ms RMS. Rumble contributes to that RMS in SILENCE and in
//  SPEECH alike, so it lifts the floor without lifting the contrast — and the floor
//  is what a quiet speaker has to clear. Measured floors run 0.0027–0.0058; any
//  part of that which is sub-80 Hz energy is inflating the bar for no reason.
//
//  THE SIGNAL THAT IT WORKED: `[Gate] energy:` should report a LOWER floor and a
//  HIGHER range on the same speech. If neither moves, this microphone has no
//  meaningful rumble and the filter can come back out.
//
//  80 Hz, NOT 120 Hz. journal.md §1 also measured 120 Hz mains hum, but a
//  high-pass steep enough to remove that would cut into male fundamental frequency
//  (85–180 Hz) and take voice with it. Killing hum specifically needs a narrow
//  notch, which is a separate and riskier change — do it only if the hum shows up
//  on THIS microphone rather than on the archived recording.
//
//  NOT denoising. `handoff.md` "do not repeat": denoising before diarization hurt
//  coverage 39% -> 31%. This removes a band that contains no speech; it does not
//  try to estimate and subtract noise.
//
//  IIR, so it carries state between buffers. One instance per stream — sharing one
//  across two audio sources would leak each other's history.
//

import Foundation

struct HighPassFilter {

    /// Corner frequency. Below the lowest male fundamental, above room rumble.
    static let cornerHz: Double = 80
    /// Butterworth (maximally flat) — no resonant peak at the corner, which a
    /// higher Q would add right where voice starts.
    static let q: Double = 0.707

    // RBJ cookbook biquad coefficients, normalised by a0.
    private let b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    // Direct Form II transposed state.
    private var z1: Float = 0
    private var z2: Float = 0

    init(sampleRate: Double = Double(SpeakerGate.sampleRate)) {
        let w0 = 2 * Double.pi * Self.cornerHz / sampleRate
        let cosW = cos(w0)
        let alpha = sin(w0) / (2 * Self.q)

        let a0 = 1 + alpha
        b0 = Float(((1 + cosW) / 2) / a0)
        b1 = Float((-(1 + cosW)) / a0)
        b2 = Float(((1 + cosW) / 2) / a0)
        a1 = Float((-2 * cosW) / a0)
        a2 = Float((1 - alpha) / a0)
    }

    /// Filter in place, carrying state into the next call.
    mutating func apply(to buffer: inout [Float]) {
        for i in buffer.indices {
            let x = buffer[i]
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            buffer[i] = y
        }
    }

    mutating func reset() { z1 = 0; z2 = 0 }

    /// One-shot for a whole recording. Runs the filter TWICE, forward then
    /// backward, so the phase shift cancels — a file has no realtime constraint,
    /// and a calibration template should not carry group delay the live path
    /// doesn't. Doubles the rolloff to 24 dB/octave as a side effect.
    static func filterFile(_ samples: inout [Float],
                           sampleRate: Double = Double(SpeakerGate.sampleRate)) {
        var forward = HighPassFilter(sampleRate: sampleRate)
        forward.apply(to: &samples)
        samples.reverse()
        var backward = HighPassFilter(sampleRate: sampleRate)
        backward.apply(to: &samples)
        samples.reverse()
    }
}
