//
//  TranscriptionEngine.swift
//  PeriodontalCharting
//
//  Owns the small shared audio infrastructure: Silero VAD and the app-wide
//  SpeakerGateService. It transcribes nothing — the STT model is Wav2Vec2, it is
//  bundled, and it loads through `Wav2VecEngine`. The name is a leftover; renaming
//  it touches five call sites and is worth doing separately.
//
//  The gate is deliberately independent of any STT load: enrollment needs only the
//  small ECAPA embedder and Silero VAD, and gating it behind a large model meant
//  onboarding always found `vad` still nil and silently skipped calibration.
//
//  ENROLLMENT READS THE ACTIVE VoiceProfile. Switching dentist restores cached
//  embeddings rather than re-running ECAPA over every take.
//

import Foundation
import CoreML
import Observation
import os

@MainActor
@Observable
final class TranscriptionEngine {
    @ObservationIgnored static let shared = TranscriptionEngine()

    @ObservationIgnored private(set) var vad: SileroVADEngine?
    // Observable so the UI can show a gate-ready indicator.
    private(set) var isReady = false

    /// App-wide speaker gate. Enrollment lives HERE, not in whatever view happened
    /// to trigger it — a locally-constructed service deallocates and takes the
    /// centroid with it.
    private(set) var speakerGate: SpeakerGateService?

    /// The in-flight (or completed) load, so concurrent callers coalesce onto one
    /// load instead of racing to build the gate infrastructure twice.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var enrollmentTask: Task<Void, Never>?

    /// Take 1 of the ACTIVE profile. Kept as a single URL because some callers
    /// still want "the primary recording"; use `VoiceProfileStore.activeTakeURLs`
    /// for anything that should see every take.
    static var calibrationURL: URL {
        let store = VoiceProfileStore.shared
        let dir = store.activeDirectory 
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return CalibrationTake.normal.url(in: dir)
    }

    // Megabytes this process may still allocate before jetsam kills it.
    //
    // This is the number that actually matters — not "memory used". The app holds
    // Wav2Vec2, eight Core ML packages for the gate and TSE, and TSE's 16 MB
    // enroll_kv, and it has been SIGKILL'd before. Print it after each subsystem
    // loads so a regression shows up as a shrinking number rather than as a crash
    // with no stack trace.
    //
    // Returns 0 if the OS declines to report, so treat 0 as "unknown", not "none".
    nonisolated static func availableMemoryMB() -> Int {
        Int(os_proc_available_memory()) / 1_048_576
    }

    // What one enrollment pass produced. A struct rather than a wide tuple
    // because it crosses a `Task.detached` boundary and the fields matter.
    private struct EnrollmentOutcome: Sendable {
        var templates = 0
        var seconds = 0.0
        var totalSpans = 0
        var takes = 0
        var cachedTemplates: [[Double]] = []
        var selfDistances: [Double] = []
    }

    private init() {}

    // Load the shared VAD. Idempotent and coalesced.
    func load() async {
        if isReady { return }
        if loadTask == nil {
            loadTask = Task { await self.performLoad() }
        }
        await loadTask?.value
        if !isReady { loadTask = nil }  // allow a retry after a failed load
    }

    private func performLoad() async {
        if isReady { return }
        // Only the small Silero VAD the gate depends on. The gate, the extractor
        // and enrollment all build on demand (makeSpeakerGateIfNeeded / TSEEngine),
        // so this is a fast, memory-cheap load.
        vad = try? SileroVADEngine()
        isReady = true
        print("[Mem] gate infra ready: \(Self.availableMemoryMB()) MB available")
    }

    // MARK: - Speaker gate

    /// True once a centroid exists. Read this rather than tracking a separate flag.
    var isSpeakerEnrolled: Bool { speakerGate?.isEnrolled ?? false }

    // Build the app-wide gate on first use, independent of any STT load.
    //
    // Falls back to its own SileroVADEngine when `vad` is not set yet — during
    // onboarding it often is not, because `load()` may not have run.
    //
    // Synchronous: it loads two small Core ML models on the main actor (~100 ms).
    // Acceptable for a one-time setup call; do not put it in a render path.
    @discardableResult
    func makeSpeakerGateIfNeeded() -> SpeakerGateService? {
        if let speakerGate { return speakerGate }
        guard let vadEngine = vad ?? (try? SileroVADEngine()),
              let gate = try? SpeakerGate() else { return nil }
        let service = SpeakerGateService(gate: gate, vad: vadEngine)
        speakerGate = service
        return service
    }

    /// Enroll from EVERY calibration take of the ACTIVE profile, then cache the
    /// resulting embeddings and the measured spread on it.
    ///
    /// MULTI-CONDITION. Each take is a different acoustic condition — normal
    /// voice, quiet voice, mask on — and all of them go into one centroid, so the
    /// gate recognises the clinician however he happens to be speaking. One take
    /// at one volume is what made a softly-spoken session score 0.806–0.808 and
    /// get withheld; see CalibrationTake for the measurements.
    ///
    /// TEMPLATE BUDGET. `SpeakerGate` evicts FIFO past `maxTemplates` (16), so
    /// letting take 1 fill all 16 would silently DELETE it again when take 2
    /// arrives — losing exactly the acoustic diversity this is for. The budget is
    /// split evenly across the takes that exist.
    ///
    /// - Parameters:
    ///   - reset: clear existing templates first. True whenever re-enrolling, so a
    ///     re-recorded take does not stack on top of its own older version.
    ///   - waitForFile: poll until the WAV is readable. AVAudioRecorder finalises
    ///     ASYNCHRONOUSLY after stop(), so reading immediately can get a truncated
    ///     file that looks exactly like "no speech".
    @discardableResult
    func enrollFromCalibration(
        reset: Bool,
        waitForFile: Bool
    ) async -> (templates: Int, seconds: Double, totalSpans: Int, takes: Int) {

        guard let service = makeSpeakerGateIfNeeded() else { return (0, 0, 0, 0) }
        let store = VoiceProfileStore.shared
        guard let profileID = store.activeID else { return (0, 0, 0, 0) }
        let urls = store.activeTakeURLs
        guard !urls.isEmpty else { return (0, 0, 0, 0) }

        // The profile's own operating point, before anything is judged against it.
        service.gate.applyThresholds(accept: store.active?.acceptThreshold,
                                     reject: store.active?.rejectThreshold)

        let outcome = await Task.detached(priority: .userInitiated) { () -> EnrollmentOutcome in
            // Split the 16-template budget across the takes, so no single take can
            // evict the others. Floor of 2 so three takes still give a spread.
            let perTake = max(2, SpeakerGate.maxTemplates / urls.count)

            if reset { service.resetEnrollment() }

            var result = EnrollmentOutcome()

            for url in urls {
                // Wait for THIS file specifically — only the take just recorded is
                // still being finalised, but restore-at-launch passes waitForFile
                // false and reads all of them immediately.
                var takeSeconds = 0.0
                let attempts = waitForFile ? 12 : 1
                for _ in 0..<attempts {
                    takeSeconds = ((try? SpeakerGate.loadSamples(from: url))?.count).map {
                        Double($0) / Double(SpeakerGate.sampleRate)
                    } ?? 0
                    if takeSeconds >= 1.0 { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                guard takeSeconds >= 1.0 else {
                    print("[Enroll] \(url.lastPathComponent): unreadable or too short, skipped")
                    continue
                }

                guard let selection = try? service.enrollmentSelection(
                        fromFile: url, maxPerFile: perTake) else {
                    print("[Enroll] \(url.lastPathComponent): no usable spans")
                    continue
                }

                let takeAdded = (try? service.enroll(utterances: selection.utterances)) ?? 0
                print(String(format: "[Enroll] %@: %.1fs, %d span(s) -> %d template(s)",
                             url.lastPathComponent, selection.audioSeconds,
                             selection.totalSpans, takeAdded))

                result.templates  += takeAdded
                result.seconds    += selection.audioSeconds
                result.totalSpans += selection.totalSpans
                if takeAdded > 0 { result.takes += 1 }
            }

            result.cachedTemplates = service.gate.currentTemplates
            result.selfDistances = SpeakerGate.leaveOneOutDistances(result.cachedTemplates)
            print(String(format: "[Enroll] centroid from %d take(s), %d template(s), %.1fs total",
                         result.takes, result.templates, result.seconds))
            return result
        }.value

        // Cache the embeddings so switching back to this profile costs nothing, and
        // record the spread so setup can warn before a patient is in the chair.
        store.updateAfterEnrollment(id: profileID,
                                    templates: outcome.cachedTemplates,
                                    selfDistances: outcome.selfDistances)

        return (outcome.templates, outcome.seconds, outcome.totalSpans, outcome.takes)
    }

    /// Switch dentist.
    ///
    /// Restores cached embeddings — no audio is read, no ECAPA pass runs — then
    /// re-conditions the extractor, which CANNOT be restored from the gate's
    /// embeddings because it uses WeSpeaker ECAPA: same architecture and dimension
    /// as the gate's SpeechBrain ECAPA, different weights, unrelated embedding
    /// space. Skipping that step would leave the extractor conditioned on the
    /// previous clinician — still "working", on the wrong person.
    func activateProfile(_ id: String) async {
        let store = VoiceProfileStore.shared
        store.setActive(id)
        guard let service = makeSpeakerGateIfNeeded(), let profile = store.active else { return }

        service.gate.applyThresholds(accept: profile.acceptThreshold,
                                     reject: profile.rejectThreshold)

        if profile.templates.isEmpty {
            // Never enrolled, or cached by a build from before templates were stored.
            _ = await enrollFromCalibration(reset: true, waitForFile: false)
        } else {
            service.gate.restore(templates: profile.templates)
            print("[Profiles] restored \(profile.templates.count) template(s) for '\(profile.name)'")
        }
        await TSEEngine.shared.reprepare()
    }

    /// Rebuild the centroid at launch. Templates are in memory only, so without
    /// this the clinician re-calibrates on every cold start. Idempotent and
    /// coalesced, like `load()`.
    func restoreEnrollment() async {
        if isSpeakerEnrolled { return }
        if enrollmentTask == nil {
            enrollmentTask = Task {
                let store = VoiceProfileStore.shared
                // Cached embeddings make a cold start instant. Falling through to a
                // full enrollment only happens for a profile that has never been
                // enrolled, or one saved before caching existed.
                if let profile = store.active, !profile.templates.isEmpty,
                   let service = self.makeSpeakerGateIfNeeded() {
                    service.gate.applyThresholds(accept: profile.acceptThreshold,
                                                 reject: profile.rejectThreshold)
                    service.gate.restore(templates: profile.templates)
                    print("[Profiles] restored \(profile.templates.count) template(s) "
                          + "for '\(profile.name)' from cache")
                    return
                }
                _ = await self.enrollFromCalibration(reset: false, waitForFile: false)
            }
        }
        await enrollmentTask?.value
        if !isSpeakerEnrolled { enrollmentTask = nil }   // allow a retry
        print("[Mem] after gate enrollment:   \(Self.availableMemoryMB()) MB available")
    }
}
