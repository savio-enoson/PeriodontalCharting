//
//  SileroVADEngine.swift
//  transcript
//
//  Core ML wrapper around the streaming Silero VAD v5 model (SileroVAD.mlmodelc,
//  converted in silevro_VAD_coreml.ipynb). Ports the two pieces app.py uses from
//  the Python `silero-vad` package:
//
//    • get_speech_timestamps(...)  -> speechTimestamps(...)   (batch burst chunking)
//    • the streaming prob loop      -> speechProbabilities(...) (used by both paths)
//
//  The model is a per-chunk streaming graph:
//      input    [1, 512]  f32  (16 kHz mono, one 32 ms hop)
//      hc_state [2, 1, 128]     (LSTM h,c; zeros at stream start)
//    → prob     [1, 1]
//    → hc_stateN[2, 1, 128]     (thread back in as hc_state for the next hop)
//
//  We load the compiled model by name from the bundle root — Xcode's synchronized
//  file group flattens Models/ so SileroVAD.mlmodelc lands alongside the WhisperKit
//  *.mlmodelc bundles (same mechanism ContentView/VM rely on for AudioEncoder).
//
//  RUNS ON CPU ONLY — see the note in init(). Prediction failures are swallowed as
//  prob 0 in speechProbabilities, so anything that breaks inference surfaces as
//  "no speech detected" rather than as an error.
//

import Foundation
import CoreML

/// Half-open speech span in *sample* indices (matches Python's {"start","end"}).
struct SpeechSegment: Equatable {
    var start: Int
    var end: Int
}

/// Streaming Silero VAD, wrapped for Core ML. Not an actor: predictions are
/// synchronous CPU/ANE calls; callers hop it onto a background task as needed.
/// `@unchecked Sendable`: after init the config fields are read-only and MLModel
/// prediction is thread-safe, so it can be handed to a detached VAD task.
final class SileroVADEngine: @unchecked Sendable {

    enum VADError: Error { case modelNotFound }

    static let sampleRate = 16_000
    /// Samples per VAD hop @16 kHz (32 ms) — must match the converted model.
    static let windowSamples = 512
    private static let stateShape: [NSNumber] = [2, 1, 128]

    private let model: MLModel
    private let inputName = "input"
    private let stateName = "hc_state"
    // Output names from the converted graph; resolved defensively at runtime
    // (Core ML can rename outputs), falling back to shape-based detection.
    private var probOut = "prob"
    private var stateOut = "hc_stateN"

    /// Loads SileroVAD.mlmodelc from the app bundle root.
    init() throws {
        guard let url = Self.locateModel() else { throw VADError.modelNotFound }
        let cfg = MLModelConfiguration()
        // CPU ONLY, deliberately. This graph takes 512 samples per call — the ANE
        // buys nothing at that size, and asking for it puts this model in
        // contention with WhisperKit's encoder compile, which runs for MINUTES on
        // first launch (see [ModelLoad] in TranscriptionEngine). During onboarding
        // a second SileroVADEngine is built while that compile is still in flight;
        // when its predictions fail, speechProbabilities appends 0 for every hop
        // and returns all zeros, which reads downstream as "no speech detected"
        // with no error anywhere. CPU is fast enough: ~31 hops per second of audio.
        cfg.computeUnits = .cpuOnly
        self.model = try MLModel(contentsOf: url, configuration: cfg)
        resolveOutputNames()
    }

    private static func locateModel() -> URL? {
        // Primary: flattened to the bundle root by the synchronized group build.
        if let root = Bundle.main.resourceURL {
            let flat = root.appendingPathComponent("SileroVAD.mlmodelc")
            if FileManager.default.fileExists(atPath: flat.path) { return flat }
        }
        // Fallback: normal resource lookup (e.g. non-flattened builds).
        return Bundle.main.url(forResource: "SileroVAD", withExtension: "mlmodelc")
    }

    /// Match the graph's real output names to prob (scalar) and state ([2,1,128]).
    private func resolveOutputNames() {
        let outputs = model.modelDescription.outputDescriptionsByName
        let stateCount = Self.stateShape.map(\.intValue).reduce(1, *)
        for (name, desc) in outputs {
            guard let c = desc.multiArrayConstraint else { continue }
            let count = c.shape.map(\.intValue).reduce(1, *)
            if count == 1 { probOut = name }
            else if count == stateCount { stateOut = name }
        }
    }

    // MARK: - Streaming inference

    /// Speech probability for every 512-sample hop across `audio`, threading the
    /// LSTM state exactly as the Python model does (state reset to zeros up front).
    ///
    /// NOTE: a failed prediction contributes 0, not an error. That keeps the loop
    /// robust to a single bad hop, but means a wholly broken model returns all
    /// zeros and looks like silence. Callers that get no spans should check
    /// `max()` of this before concluding the audio was silent.
    func speechProbabilities(_ audio: [Float]) -> [Float] {
        let n = audio.count
        guard n > 0, let state = try? MLMultiArray(shape: Self.stateShape, dataType: .float32),
              let input = try? MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32)
        else { return [] }

        // zero the initial (h, c) state
        let stateBuf = state.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<state.count { stateBuf[i] = 0 }

        let win = Self.windowSamples
        var probs: [Float] = []
        probs.reserveCapacity((n + win - 1) / win)
        let inBuf = input.dataPointer.assumingMemoryBound(to: Float.self)

        var start = 0
        while start < n {
            let count = min(win, n - start)
            audio.withUnsafeBufferPointer { src in
                inBuf.update(from: src.baseAddress! + start, count: count)
            }
            if count < win {  // pad the final short hop with zeros
                for i in count..<win { inBuf[i] = 0 }
            }

            let provider = try? MLDictionaryFeatureProvider(dictionary: [
                inputName: input, stateName: state,
            ])
            guard let provider,
                  let out = try? model.prediction(from: provider),
                  let prob = out.featureValue(for: probOut)?.multiArrayValue,
                  let newState = out.featureValue(for: stateOut)?.multiArrayValue
            else { probs.append(0); start += win; continue }

            probs.append(prob[0].floatValue)
            // thread the new state back into `state` for the next hop
            let nsBuf = newState.dataPointer.assumingMemoryBound(to: Float.self)
            stateBuf.update(from: nsBuf, count: min(state.count, newState.count))
            start += win
        }
        return probs
    }

    // MARK: - get_speech_timestamps port

    /// Faithful Swift port of silero-vad's `get_speech_timestamps`. Returns speech
    /// spans (in samples) with the same defaults app.py relies on. `maxSpeechDurationS`
    /// defaults to ∞ (app.py never splits long bursts).
    func speechTimestamps(
        _ audio: [Float],
        threshold: Float = 0.5,
        minSpeechDurationMs: Int = 250,
        maxSpeechDurationS: Double = .infinity,
        minSilenceDurationMs: Int = 100,
        speechPadMs: Int = 30
    ) -> [SpeechSegment] {
        let sr = Double(Self.sampleRate)
        let win = Self.windowSamples
        let probs = speechProbabilities(audio)
        let audioLen = audio.count

        let minSpeechSamples = Int(sr * Double(minSpeechDurationMs) / 1000)
        let speechPadSamples = Int(sr * Double(speechPadMs) / 1000)
        let minSilenceSamples = Int(sr * Double(minSilenceDurationMs) / 1000)
        let minSilenceAtMaxSpeech = Int(sr * 98 / 1000)
        let maxSpeechSamples = maxSpeechDurationS.isFinite
            ? Int(sr * maxSpeechDurationS) - win - 2 * speechPadSamples
            : Int.max

        let negThreshold = threshold - 0.15
        var triggered = false
        var speeches: [SpeechSegment] = []
        var curStart = 0
        var curEnd = 0
        var hasCurrent = false
        var tempEnd = 0
        var prevEnd = 0
        var nextStart = 0

        for (i, prob) in probs.enumerated() {
            let pos = win * i

            if prob >= threshold && tempEnd != 0 {
                tempEnd = 0
                if nextStart < prevEnd { nextStart = pos }
            }

            if prob >= threshold && !triggered {
                triggered = true
                curStart = pos
                hasCurrent = true
                continue
            }

            if triggered && (pos - curStart) > maxSpeechSamples {
                if prevEnd != 0 {
                    curEnd = prevEnd
                    speeches.append(SpeechSegment(start: curStart, end: curEnd))
                    hasCurrent = false
                    if nextStart < prevEnd {
                        triggered = false
                    } else {
                        curStart = nextStart
                        hasCurrent = true
                    }
                    prevEnd = 0; nextStart = 0; tempEnd = 0
                } else {
                    curEnd = pos
                    speeches.append(SpeechSegment(start: curStart, end: curEnd))
                    hasCurrent = false
                    prevEnd = 0; nextStart = 0; tempEnd = 0
                    triggered = false
                    continue
                }
            }

            if prob < negThreshold && triggered {
                if tempEnd == 0 { tempEnd = pos }
                if (pos - tempEnd) > minSilenceAtMaxSpeech { prevEnd = tempEnd }
                if (pos - tempEnd) < minSilenceSamples {
                    continue
                } else {
                    curEnd = tempEnd
                    if (curEnd - curStart) > minSpeechSamples {
                        speeches.append(SpeechSegment(start: curStart, end: curEnd))
                    }
                    hasCurrent = false
                    prevEnd = 0; nextStart = 0; tempEnd = 0
                    triggered = false
                    continue
                }
            }
        }

        if hasCurrent && (audioLen - curStart) > minSpeechSamples {
            speeches.append(SpeechSegment(start: curStart, end: audioLen))
        }

        // pad + merge, exactly as the Python post-loop does
        for i in speeches.indices {
            if i == 0 {
                speeches[i].start = max(0, speeches[i].start - speechPadSamples)
            }
            if i != speeches.count - 1 {
                let silence = speeches[i + 1].start - speeches[i].end
                if silence < 2 * speechPadSamples {
                    speeches[i].end += silence / 2
                    speeches[i + 1].start = max(0, speeches[i + 1].start - silence / 2)
                } else {
                    speeches[i].end = min(audioLen, speeches[i].end + speechPadSamples)
                    speeches[i + 1].start = max(0, speeches[i + 1].start - speechPadSamples)
                }
            } else {
                speeches[i].end = min(audioLen, speeches[i].end + speechPadSamples)
            }
        }
        return speeches
    }
}
