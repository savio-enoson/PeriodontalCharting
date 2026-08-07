//
//  TSEEngine.swift
//  PeriodontalCharting
//
//  App-wide owner of the extractor, mirroring why `TranscriptionEngine` owns the
//  speaker gate: a locally-constructed extractor deallocates and takes 16 MB of
//  enroll_kv with it, and rebuilding that costs a full ECAPA pass over the
//  calibration recordings.
//
//  Deliberately separate from `TranscriptionEngine` so nothing here is gated
//  behind the ~600 MB WhisperKit load — the same mistake that made onboarding
//  find `vad` still nil and skip calibration.
//
//  STATUS OF THE EXTRACTOR ITSELF: it has never rescued a span in a real room.
//  Measured across every session since 2026-08-05 it moves routed spans AWAY from
//  the enrolled speaker, and on 2026-08-06 it pulled a WRONG-speaker span from
//  0.851 to 0.763 — into the band that would have put another person's words on a
//  chart. `TSEConfig.mode` stays `.observe` and
//  `GatedAudioProcessor.useExtractor` stays false. Every good number it has comes
//  from synthetic mixes with no shared room acoustics (journal.md §1).
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

    /// Non-isolated mirror of `extractor`, for the audio pump in
    /// `GatedAudioProcessor`, which runs off the main actor and cannot await.
    /// `TargetSpeakerExtractor` is `@unchecked Sendable` with lock-guarded
    /// enrollment state, so reading it from another thread is safe.
    ///
    /// Only ever read when `GatedAudioProcessor.useExtractor` is true — which it
    /// is not, see the header.
    nonisolated(unsafe) private(set) static var extractorUnsafe: TargetSpeakerExtractor?

    @ObservationIgnored private var prepareTask: Task<Void, Never>?

    /// 1024 keys at a 10 ms fbank hop. Enrollment shorter than this cannot fill
    /// the exported conditioning graph.
    nonisolated static var requiredEnrollmentSeconds: Double {
        Double(TSEConfig.enrollKeys) * 0.01
    }

    private init() {}

    /// Load the six Core ML models and build the conditioning tensors from the
    /// ACTIVE profile's calibration recordings. Idempotent and coalesced, like
    /// `TranscriptionEngine.load()`.
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
        let urls = VoiceProfileStore.shared.activeTakeURLs
        guard !urls.isEmpty else {
            extractor = nil
            Self.extractorUnsafe = nil
            isReady = false
            // Distinct from a failure: this profile simply has no recordings yet.
            // The generic "0.0 s of speech" message reads like something broke.
            status = "No calibration recorded for this profile yet"
            print("[TSE] \(status)")
            return
        }
        do {
            let built = try await Task.detached(priority: .userInitiated) {
                let extractor = try TargetSpeakerExtractor()
                let audio = try Self.enrollmentAudio(from: urls)
                try extractor.prepareEnrollment(audio)
                return extractor
            }.value
            extractor = built
            Self.extractorUnsafe = built
            isReady = true
            status = String(format: "Extractor ready — %.1f s enrolled from %d take(s)",
                            built.enrollmentSeconds, urls.count)
        } catch {
            extractor = nil
            Self.extractorUnsafe = nil
            isReady = false
            status = "Extractor unavailable: \(error.localizedDescription)"
            print("[TSE] \(status)")
        }
    }

    /// Re-run after the clinician re-records a take, or after switching profile.
    ///
    /// MANDATORY on a profile switch. `enroll_kv` comes from WeSpeaker ECAPA —
    /// same architecture and dimension as the gate's SpeechBrain ECAPA, different
    /// weights, unrelated embedding space — so it CANNOT be restored from the
    /// gate's cached templates. Skipping this leaves the extractor conditioned on
    /// the previous clinician: still "working", on the wrong person.
    func reprepare() async {
        extractor = nil
        Self.extractorUnsafe = nil
        isReady = false
        prepareTask = nil
        await prepare()
    }

    /// Concatenated SPEECH from every calibration take of the active profile —
    /// the extractor's enrollment, not the gate's templates.
    ///
    /// MULTI-TAKE HELPS THE EXTRACTOR TOO, for a different reason than the gate.
    /// The gate wants acoustic DIVERSITY across takes so its centroid covers every
    /// condition. The extractor just wants MORE frames: it needs >= 10.24 s of
    /// speech to fill its 1024 conditioning keys, and below that
    /// `prepareEnrollment` refuses outright. Concatenating takes clears that
    /// easily — measured 26.3 s from two, 34.4 s from a longer pair.
    ///
    /// Concatenated rather than "best 4 spans" on purpose: the gate wants a
    /// centroid over a few clean spans, the extractor wants as many frame-level
    /// keys as it can get. Different mechanisms; the "enroll generously" finding
    /// belongs to the GATE's centroid and does not transfer.
    ///
    /// Silero at 0.3, not its 0.5 default: measured max probability on a healthy
    /// calibration recording through this mic was 0.409, so the default found
    /// nothing. On this device it usually finds nothing regardless (journal.md
    /// §10), hence the whole-file fallback.
    nonisolated static func enrollmentAudio(from urls: [URL]) throws -> [Float] {
        guard !urls.isEmpty else { return [] }
        let vad = try? SileroVADEngine()

        var speech: [Float] = []
        var rawFallback: [Float] = []

        for url in urls {
            guard let audio = try? SpeakerGate.loadSamples(from: url), !audio.isEmpty else {
                continue
            }
            rawFallback.append(contentsOf: audio)

            guard let vad, case let spans = vad.speechTimestamps(audio, threshold: 0.3),
                  !spans.isEmpty else {
                // A dead VAD must not block enrollment — take the whole file.
                speech.append(contentsOf: audio)
                continue
            }
            for span in spans {
                let lo = max(0, span.start), hi = min(audio.count, span.end)
                if hi > lo { speech.append(contentsOf: audio[lo..<hi]) }
            }
        }

        let seconds = Double(speech.count) / Double(SpeakerGate.sampleRate)
        if seconds < requiredEnrollmentSeconds {
            print(String(format: "[TSE] only %.1f s of speech across %d take(s) "
                         + "(need %.1f s) — falling back to the whole recordings",
                         seconds, urls.count, requiredEnrollmentSeconds))
            return rawFallback
        }
        return speech
    }
}
