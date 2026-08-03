//
//  TSEEngine.swift
//  PeriodontalCharting
//
//  App-wide owner of the extractor, mirroring why `TranscriptionEngine` owns the
//  speaker gate: a locally-constructed extractor deallocates and takes 16 MB of
//  enroll_kv with it, and rebuilding that costs a full ECAPA pass over the
//  calibration recording.
//
//  Deliberately separate from `TranscriptionEngine` so nothing here is gated
//  behind the ~600 MB WhisperKit load — the same mistake that made onboarding
//  find `vad` still nil and skip calibration.
//

import Foundation
import Observation

@MainActor
@Observable
final class TSEEngine {
    @ObservationIgnored static let shared = TSEEngine()

    @ObservationIgnored private(set) var extractor: TargetSpeakerExtractor?
    private(set) var status = "Extractor not loaded"
    private(set) var isReady = false

    @ObservationIgnored private var prepareTask: Task<Void, Never>?

    /// 1024 keys at a 10 ms fbank hop. Enrollment shorter than this cannot fill
    /// the exported conditioning graph.
    nonisolated static var requiredEnrollmentSeconds: Double {
        Double(TSEConfig.enrollKeys) * 0.01
    }

    private init() {}

    /// Load the six Core ML models and build the conditioning tensors from the
    /// calibration recording. Idempotent and coalesced, like `TranscriptionEngine.load()`.
    func prepare() async {
        if isReady { return }
        if prepareTask == nil { prepareTask = Task { await self.performPrepare() } }
        await prepareTask?.value
        if !isReady { prepareTask = nil }        // allow a retry
    }

    private func performPrepare() async {
        guard TSEConfig.mode != .off else {
            status = "Extraction disabled (TSEConfig.mode == .off)"
            return
        }
        let url = TranscriptionEngine.calibrationURL
        do {
            let built = try await Task.detached(priority: .userInitiated) {
                let extractor = try TargetSpeakerExtractor()
                let audio = try Self.enrollmentAudio(from: url)
                try extractor.prepareEnrollment(audio)
                return extractor
            }.value
            extractor = built
            isReady = true
            status = String(format: "Extractor ready — %.1f s enrolled",
                            built.enrollmentSeconds)
        } catch {
            extractor = nil
            isReady = false
            status = "Extractor unavailable: \(error.localizedDescription)"
            print("[TSE] \(status)")
        }
    }

    /// Re-run after the clinician re-records calibration.
    func reprepare() async {
        extractor = nil
        isReady = false
        prepareTask = nil
        await prepare()
    }

    /// Concatenated SPEECH from the calibration recording — the extractor's
    /// enrollment, not the gate's templates.
    ///
    /// Concatenated rather than "best 4 spans" on purpose: the gate wants a
    /// centroid over a few clean 3 s windows, the extractor wants as many
    /// frame-level keys as it can get. Different mechanisms; the "enroll
    /// generously" finding belongs to the GATE's centroid and does not transfer.
    ///
    /// Silero at 0.3, not its 0.5 default: measured max probability on a healthy
    /// calibration recording through this mic was 0.409, so the default found
    /// nothing at all.
    nonisolated static func enrollmentAudio(from url: URL) throws -> [Float] {
        let audio = try SpeakerGate.loadSamples(from: url)
        guard !audio.isEmpty else { return [] }
        guard let vad = try? SileroVADEngine() else { return audio }

        let spans = vad.speechTimestamps(audio, threshold: 0.3)
        guard !spans.isEmpty else { return audio }   // a dead VAD must not block enrollment

        var speech: [Float] = []
        speech.reserveCapacity(spans.reduce(0) { $0 + ($1.end - $1.start) })
        for span in spans {
            let lo = max(0, span.start), hi = min(audio.count, span.end)
            if hi > lo { speech.append(contentsOf: audio[lo..<hi]) }
        }
        let seconds = Double(speech.count) / Double(SpeakerGate.sampleRate)
        if seconds < requiredEnrollmentSeconds {
            print(String(format: "[TSE] only %.1f s of speech in calibration "
                         + "(need %.1f s) — falling back to the whole recording",
                         seconds, requiredEnrollmentSeconds))
            return audio
        }
        return speech
    }
}
