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
//  behind a large model load — the mistake that made onboarding find `vad` still
//  nil and skip calibration.
//
//  WHO CONSUMES IT: `Wav2VecViewModel` reads `extractor` on the main actor at
//  session start and hands it to the detached gate pass. There is no nonisolated
//  mirror any more — the audio pump that needed one went away with the old STT
//  front-end.
//
//  STANDING CAVEAT ON THE EXTRACTOR ITSELF: measured across every session since
//  2026-08-05 it moved routed spans AWAY from the enrolled speaker, and on
//  2026-08-06 it pulled a WRONG-speaker span from 0.851 to 0.763 — into the band
//  that would put another person's words on a chart. Every good number it has
//  comes from synthetic mixes with no shared room acoustics (journal.md §1).
//
//  That caveat is about DISTANCES, which is why `TSERescue.route` no longer lets
//  extraction revise an `accept`. Whether extraction helps or hurts WORD ERROR
//  RATE is a different question and an open one — see `TSEConfig.coverage`.
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

    // 1024 keys at a 10 ms fbank hop. Enrollment shorter than this cannot fill
    // the exported conditioning graph.
    nonisolated static var requiredEnrollmentSeconds: Double {
        Double(TSEConfig.enrollKeys) * 0.01
    }

    private init() {}

    // Load the six Core ML models and build the conditioning tensors from the
    // ACTIVE profile's calibration recordings. Idempotent and coalesced.
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
            isReady = true
            status = String(format: "Extractor ready — %.1f s enrolled from %d take(s)",
                            built.enrollmentSeconds, urls.count)
            print("[TSE] \(status)")
        } catch {
            extractor = nil
            isReady = false
            status = "Extractor unavailable: \(error.localizedDescription)"
            print("[TSE] \(status)")
        }
    }

    // Re-run after the clinician re-records a take, or after switching profile.
    //
    // MANDATORY on a profile switch. `enroll_kv` comes from WeSpeaker ECAPA —
    // same architecture and dimension as the gate's SpeechBrain ECAPA, different
    // weights, unrelated embedding space — so it CANNOT be restored from the
    // gate's cached templates. Skipping this leaves the extractor conditioned on
    // the previous clinician: still "working", on the wrong person.
    func reprepare() async {
        extractor = nil
        isReady = false
        prepareTask = nil
        await prepare()
    }

    // Concatenated SPEECH from every calibration take of the active profile —
    // the extractor's enrollment, not the gate's templates.
    //
    // MULTI-TAKE HELPS THE EXTRACTOR TOO, for a different reason than the gate.
    // The gate wants acoustic DIVERSITY so its centroid covers every condition.
    // The extractor just wants MORE frames: it needs >= 10.24 s of speech to fill
    // its 1024 conditioning keys, and below that `prepareEnrollment` refuses
    // outright. Concatenating takes clears that easily — measured 26.3 s from
    // two, 34.4 s from a longer pair.
    //
    // Concatenated rather than "best 4 spans" on purpose: the "enroll generously"
    // finding belongs to the GATE's centroid and does not transfer.
    //
    // SEGMENTED ON ENERGY, NOT SILERO. This used `vad.speechTimestamps` at 0.3,
    // and Silero reads 0.001–0.003 on this device (journal.md §10) — so it found
    // nothing on every take and fell through to "use the whole file" every single
    // time. Confirmed by arithmetic: the takes are 12.06 + 10.48 = 22.55 s, and
    // the log read `[TSE] enrolled 22.5 s`. The whole recordings, pauses included.
    //
    // The cost of that was paid twice. The 1024 conditioning keys were spread over
    // audio that is roughly half silence, and `computeTFMap` softmaxes every
    // mixture frame over EVERY enrollment frame — so the attention mass was
    // diluted by frames carrying no speaker information, and the tfmap cost, which
    // scales linearly with enrollment length, was inflated in the same proportion.
    //
    // `concatenatedSpeech` uses the same energy threshold the live gate uses, with
    // none of its qualification — see the note there for why the extractor must
    // NOT be fed `rescueSpans` output.
    nonisolated static func enrollmentAudio(from urls: [URL]) throws -> [Float] {
        guard !urls.isEmpty else { return [] }

        var speech: [Float] = []
        var rawFallback: [Float] = []

        for url in urls {
            guard let audio = try? SpeakerGate.loadSamples(from: url), !audio.isEmpty else {
                continue
            }
            rawFallback.append(contentsOf: audio)
            speech.append(contentsOf: SpeakerGateService.concatenatedSpeech(in: audio))
        }

        let seconds = Double(speech.count) / Double(SpeakerGate.sampleRate)
        let rawSeconds = Double(rawFallback.count) / Double(SpeakerGate.sampleRate)

        // THE FALLBACK IS NOT COSMETIC. `prepareEnrollment` refuses below 1024
        // fbank frames — 10.24 s — so when the takes are short or mostly silence
        // there is a real choice between diluted conditioning and no extractor at
        // all. Whole files win that trade, but say so loudly: it means the
        // clinician needs to record more, and the numbers below say how much.
        if seconds < requiredEnrollmentSeconds {
            print(String(format: "[TSE] energy segmentation found %.1f s of speech in %.1f s "
                         + "across %d take(s) (%.0f%%), under the %.1f s needed to fill "
                         + "%d keys — falling back to the whole recordings. RECORD LONGER "
                         + "CALIBRATION to get speech-only conditioning.",
                         seconds, rawSeconds, urls.count,
                         rawSeconds > 0 ? seconds / rawSeconds * 100 : 0,
                         requiredEnrollmentSeconds, TSEConfig.enrollKeys))
            return rawFallback
        }

        print(String(format: "[TSE] enrollment: %.1f s of speech from %.1f s across %d take(s) "
                     + "(%.0f%%) — %.1f s of silence dropped",
                     seconds, rawSeconds, urls.count,
                     rawSeconds > 0 ? seconds / rawSeconds * 100 : 0, rawSeconds - seconds))
        return speech
    }
}
