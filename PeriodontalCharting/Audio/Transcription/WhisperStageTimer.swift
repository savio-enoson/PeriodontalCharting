//
//  WhisperStageTimer.swift
//  PeriodontalCharting
//
//  Measures the live path's per-window model cost WITHOUT patching WhisperKit.
//
//  `AudioStreamTranscriber` does not own its models — TranscriptionViewModel
//  hands them in — so wrapping them here is enough. Both protocols are three
//  members wide, so these decorators forward everything and add only a clock.
//
//  WHY MEL AND ENCODER SPECIFICALLY. `TranscribeTask` zero-pads every decode
//  window to 30 s (`padOrTrim(..., toLength: windowSamples)`) BEFORE the mel and
//  the encoder run. Both are therefore FIXED costs per window — they do not
//  shrink when only one second of new audio arrived. That is the entire basis
//  for changing the decode cadence, so it is the number worth having first.
//
//  `TextDecoding` is deliberately NOT wrapped: 16 members, including a mutable
//  `logitsFilters` that TranscriptionEngine writes to (the SequenceBiasFilter).
//  Wrapping it would put a forwarding layer in the middle of the clinical bias
//  path for a number recoverable as `wall - mel - encoder`.
//

import Foundation
import WhisperKit

/// Accumulates stage timings across threads. `@unchecked Sendable` for the same
/// reason as SpeakerGate: all mutable state is behind `lock`.
final class WhisperStageTimer: @unchecked Sendable {
    static let shared = WhisperStageTimer()

    private let lock = NSLock()
    private var melSeconds = 0.0
    private var encSeconds = 0.0
    private var melRuns = 0
    private var encRuns = 0

    private init() {}

    func recordMel(_ seconds: TimeInterval) {
        lock.lock(); melSeconds += seconds; melRuns += 1; lock.unlock()
    }

    func recordEncoder(_ seconds: TimeInterval) {
        lock.lock(); encSeconds += seconds; encRuns += 1; lock.unlock()
    }

    /// Everything accumulated since the last drain, then zeroed.
    ///
    /// Drained on a callback rather than per decode because the state callback
    /// fires more often than the decode does — `onProgressCallback` mutates
    /// `state.currentText` mid-decode. Reporting PER-RUN averages makes the
    /// numbers independent of how the two interleave.
    func drain() -> (melMs: Double, melRuns: Int, encMs: Double, encRuns: Int) {
        lock.lock(); defer { lock.unlock() }
        let result = (melSeconds * 1000, melRuns, encSeconds * 1000, encRuns)
        melSeconds = 0; encSeconds = 0; melRuns = 0; encRuns = 0
        return result
    }

    func reset() { _ = drain() }
}

/// Times `logMelSpectrogram` and forwards the rest.
///
/// `windowSamples` MUST be forwarded, not defaulted: `TranscribeTask` reads
/// `featureExtractor.windowSamples ?? Constants.defaultWindowSamples` to size
/// every decode window. Returning nil here would silently resize the window.
final class TimedFeatureExtractor: FeatureExtracting, @unchecked Sendable {
    private let wrapped: any FeatureExtracting

    init(_ wrapped: any FeatureExtracting) { self.wrapped = wrapped }

    var melCount: Int? { wrapped.melCount }
    var windowSamples: Int? { wrapped.windowSamples }

    func logMelSpectrogram(
        fromAudio inputAudio: any AudioProcessorOutputType
    ) async throws -> (any FeatureExtractorOutputType)? {
        let start = Date()
        let output = try await wrapped.logMelSpectrogram(fromAudio: inputAudio)
        WhisperStageTimer.shared.recordMel(Date().timeIntervalSince(start))
        return output
    }
}

/// Times `encodeFeatures` and forwards the rest.
final class TimedAudioEncoder: AudioEncoding, @unchecked Sendable {
    private let wrapped: any AudioEncoding

    init(_ wrapped: any AudioEncoding) { self.wrapped = wrapped }

    var embedSize: Int? { wrapped.embedSize }

    func encodeFeatures(
        _ features: any FeatureExtractorOutputType
    ) async throws -> (any AudioEncoderOutputType)? {
        let start = Date()
        let output = try await wrapped.encodeFeatures(features)
        WhisperStageTimer.shared.recordEncoder(Date().timeIntervalSince(start))
        return output
    }
}
