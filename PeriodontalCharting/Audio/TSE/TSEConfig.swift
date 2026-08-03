//
//  TSEConfig.swift
//  PeriodontalCharting
//
//  Constants for the target speaker extraction (TSE) layer, taken from the
//  exported graph of `tfmap_context_causal_100` at n_keys=1024. Every number
//  here is load-bearing: change one and the Core ML packages stop binding.
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
    static let featDim = 128
    static let nLayers = 6
    static let hidden = 256          // featDim * 2
    static let blockFrames = 8       // 64 ms per Core ML call
    static let enrollKeys = 1024     // n_keys — ADOPTED, re-scored through the harness
    static let enrollEmbedDim = 512  // WeSpeaker ECAPA layer-4 frame features
    static let attenDim = 128

    /// BSRNN sub-bands: 15 x 3 + 10 x 6 + 5 x 16 + 64 + 8 = 257.
    static let bandWidths: [Int] =
        Array(repeating: 3, count: 15)
        + Array(repeating: 6, count: 10)
        + Array(repeating: 16, count: 5)
        + [64, 8]

    /// Offset of each band's first frequency bin.
    static let bandOffsets: [Int] = {
        var offsets: [Int] = []
        var idx = 0
        for bw in bandWidths { offsets.append(idx); idx += bw }
        return offsets
    }()

    // MARK: Operating point

    /// ONE number became TWO decisions over TWO distributions (handoff: "SPLIT
    /// THE CONSTANT"). Both start at the re-validated 0.675, but they now move
    /// independently.
    ///
    /// `route` is applied to `d_mixed` — bypass or send to the extractor.
    static let routeThreshold = 0.675
    /// `postAccept` is applied to `d_sep` — trust the rescued stream or not.
    /// The zero-error band after extraction was re-derived as (0.486, 0.779).
    /// Margin is asymmetric in the WRONG direction for the cost model, so any
    /// future adjustment goes DOWN, never up.
    static let postAcceptThreshold = 0.675

    /// Extraction is not worth its ~0.3 RTF on a fragment the gate cannot judge.
    static let minRouteSeconds = 1.0

    // MARK: Behaviour

    /// Ship in `.observe` first. The extractor runs and everything is logged,
    /// but the verdict that reaches the chart is unchanged — same rationale as
    /// the gate's observe mode: Silero peaked at 0.41 on this mic, and there is
    /// no data on how often the rescue path fires in a real clinic.
    enum Mode: String { case off, observe, enforce }
    static var mode: Mode = .observe

    /// CPU_ONLY beat CPU_AND_NE by 20% on the A16 (12.40 vs 14.95 ms/block) with
    /// a clean gap. The ANE does not help this architecture — `band_comm`
    /// reshapes to B*T and runs 32 per-band LSTM calls.
    static var computeUnits: MLComputeUnits = .cpuOnly
}
