//
//  TranscriptionEngine.swift
//  PeriodontalCharting
//
//  Single, app-wide WhisperKit model + Silero VAD, loaded once at launch and
//  shared by every TranscriptionViewModel. The model is ~600 MB; loading a copy
//  per view-model would blow memory (the full turbo build already got the app
//  SIGKILL'd), so all live/batch transcription draws from this one instance.
//
//  MODEL SOURCING, in order: bundled at the app root -> previously downloaded and
//  remembered in UserDefaults -> downloaded from HuggingFace with progress and
//  retry. The model folders are gitignored, so a fresh clone has no bundled copy
//  and the download path is the normal one.
//
//  Also owns the app-wide SpeakerGateService. That is DELIBERATELY independent of
//  the WhisperKit load: enrollment needs only the small ECAPA embedder and Silero
//  VAD, and gating it behind a ~600 MB model meant onboarding always found `vad`
//  still nil and silently skipped calibration.
//
//  ENROLLMENT READS THE ACTIVE VoiceProfile. Switching dentist restores cached
//  embeddings rather than re-running ECAPA over every take.
//
//  TWO DEV FLAGS, both set in the scheme (Run -> Arguments Passed On Launch), so
//  switching costs a tick-box rather than a rebuild — which matters because a
//  rebuild is a reinstall and a reinstall re-pays the ~180 s encoder compile:
//
//      -GateOnlyMode  YES   skip WhisperKit entirely (~2 s launch, no transcription)
//      -FastModelLoad YES   encoder on the GPU (seconds to load, more memory,
//                           and it competes with the chart for the GPU)
//

import Foundation
import CoreML
import Observation
import os
import WhisperKit

@MainActor
@Observable
final class TranscriptionEngine {
    @ObservationIgnored static let shared = TranscriptionEngine()

    @ObservationIgnored private(set) var whisperKit: WhisperKit?
    @ObservationIgnored private(set) var vad: SileroVADEngine?
    /// Observable so the UI can show a model-ready indicator (see ChartDashboard).
    private(set) var isReady = false
    private(set) var statusMessage = "Loading model…"
    /// 0…1 while downloading, 0 otherwise. Bind this for a determinate bar.
    private(set) var downloadProgress: Double = 0

    /// True when this launch skipped WhisperKit. Callers that need transcription
    /// should check this rather than testing `whisperKit == nil` themselves.
    private(set) var isGateOnly = false

    /// App-wide speaker gate. Enrollment lives HERE, not in whatever view happened
    /// to trigger it — a locally-constructed service deallocates and takes the
    /// centroid with it.
    private(set) var speakerGate: SpeakerGateService?

    /// The in-flight (or completed) load, so concurrent callers coalesce onto one
    /// load instead of racing to build multiple WhisperKit instances.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var enrollmentTask: Task<Void, Never>?

    // Model naming: folders in argmaxinc/whisperkit-coreml use an underscore before
    // "turbo" (openai_whisper-large-v3_turbo), NOT a hyphen.
    private static let bundledModelName = "openai_whisper-large-v3-v20240930_turbo_632MB"
    /// Exact repo folder name. `WhisperKit.download` globs `*<variant>/*`.
    private static let networkModelVariant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    /// Remembers where a completed download landed.
    private static let cachedModelPathKey = "WhisperKitCachedModelPath"

    /// [Dev] Skip the WhisperKit load entirely. The speaker gate, the extractor and
    /// enrollment are all independent of it, so gate work does not need the ~187 s
    /// encoder compile. Launch drops to ~2 s; transcription is disabled.
    private static let gateOnlyKey = "GateOnlyMode"

    /// [Dev] Runtime A/B switch for the encoder compute unit — see `performLoad`.
    private static let fastModelLoadKey = "FastModelLoad"

    /// Take 1 of the ACTIVE profile. Kept as a single URL because some callers
    /// still want "the primary recording"; use `VoiceProfileStore.activeTakeURLs`
    /// for anything that should see every take.
    static var calibrationURL: URL {
        let store = VoiceProfileStore.shared
        let dir = store.activeDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return CalibrationTake.normal.url(in: dir)
    }

    /// Megabytes this process may still allocate before jetsam kills it.
    ///
    /// This is the number that actually matters — not "memory used". The app holds
    /// WhisperKit (~600 MB), eight Core ML packages for the gate and TSE, and
    /// TSE's 16 MB enroll_kv, and it has been SIGKILL'd before. Print it after each
    /// subsystem loads so a regression shows up as a shrinking number rather than
    /// as a crash with no stack trace.
    ///
    /// Returns 0 if the OS declines to report, so treat 0 as "unknown", not "none".
    nonisolated static func availableMemoryMB() -> Int {
        Int(os_proc_available_memory()) / 1_048_576
    }

    /// What one enrollment pass produced. A struct rather than a wide tuple
    /// because it crosses a `Task.detached` boundary and the fields matter.
    private struct EnrollmentOutcome: Sendable {
        var templates = 0
        var seconds = 0.0
        var totalSpans = 0
        var eligibleSpans = 0
        var takes = 0
        var cachedTemplates: [[Double]] = []
        var selfDistances: [Double] = []
    }

    private init() {}

    /// Load the shared model. Idempotent and coalesced.
    func load() async {
        if isReady { return }
        if loadTask == nil {
            loadTask = Task { await self.performLoad() }
        }
        await loadTask?.value
        if !isReady { loadTask = nil }  // allow a retry after a failed load
    }

    private func performLoad() async {
        guard whisperKit == nil else { return }
        do {
            // GATE-ONLY: bail out before anything expensive. Everything the gate
            // path needs is loaded elsewhere — `makeSpeakerGateIfNeeded()` builds
            // the ECAPA embedder on demand and TSEEngine.prepare() runs on its own
            // task — so the gate, enrollment and the extractor all still work.
            if UserDefaults.standard.bool(forKey: Self.gateOnlyKey) {
                isGateOnly = true
                vad = try? SileroVADEngine()
                isReady = true
                downloadProgress = 0
                statusMessage = "Gate-only mode — transcription disabled"
                print("[ModelLoad] GATE-ONLY: WhisperKit not loaded (saves ~187s).")
                print("[Mem] gate-only: \(Self.availableMemoryMB()) MB available")
                return
            }

            // Compute-unit choice trades LOAD time against RUNTIME, and the two
            // wants are opposite. Measured on the A16:
            //   .cpuAndNeuralEngine   encoder compile ~180 s per install, then
            //                         ~440 ms per decode window
            //   .cpuAndGPU            loads in seconds, but holds far more resident
            //                         (attention over a 1500-frame window) and then
            //                         competes with SwiftUI for the GPU — the mel
            //                         spikes in [RTF] (19 ms typical, 1127 ms worst)
            //                         are that contention on a TINY model.
            //
            // The encoder runs once per DECODE TICK, not once per recording, so
            // .cpuAndGPU is a debugging convenience, not a shipping choice.
            //
            // DO NOT try to have both by compiling the ANE bundle in the background
            // while a GPU encoder is live. `WhisperMLModel.loadModel(prewarmMode:)`
            // FULLY LOADS the model before discarding it, so the memory PEAK is
            // identical to a real load — two ~600 MB encoders at once. Tried on
            // 2026-08-05: jetsammed the app after 58 s.
            //
            // Deferring the encoder and loading mel + decoder first does not work
            // either: `loadTokenizerIfNeeded()` reads `audioEncoder.embedSize`, so
            // no encoder means no tokenizer, and no tokenizer means no clinical
            // bias filter.
            let fastLoad = UserDefaults.standard.bool(forKey: Self.fastModelLoadKey)
            let compute = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: fastLoad ? .cpuAndGPU : .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )

            // Xcode's synchronized-group build flattens the model folder, so the four
            // *.mlmodelc bundles land at the bundle ROOT. Detect via AudioEncoder.mlmodelc.
            let resourceURL = Bundle.main.resourceURL
            let hasBundledModel = resourceURL.map {
                FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent("AudioEncoder.mlmodelc").path)
            } ?? false

            let modelFolder: URL
            if hasBundledModel, let folder = resourceURL {
                statusMessage = "Loading bundled model…"
                modelFolder = folder
            } else {
                modelFolder = try await resolveDownloadedModel()
            }

            // Always load from an explicit folder — never let WhisperKit re-resolve
            // and re-download behind our back.
            let config = WhisperKitConfig(modelFolder: modelFolder.path,
                                          computeOptions: compute,
                                          download: false)

            statusMessage = "Preparing model…"
            print("[Mem] before WhisperKit load: \(Self.availableMemoryMB()) MB available")
            let loadStart = Date()
            let kit = try await WhisperKit(config)
            let loadWall = Date().timeIntervalSince(loadStart)

            // [ModelLoad] Where the load time goes. Pure on-device work: CoreML
            // compiling the .mlmodelc for the chosen compute units plus tokenizer
            // load.
            //
            // The cache is SUPPOSED to be per-install, not per-launch. ~180 s on a
            // second launch with no rebuild in between means it is being
            // invalidated, and that is a real bug — the clinic would pay three
            // minutes on every launch, not just after an update.
            let t = kit.currentTimings
            print(String(format: "[ModelLoad] %.2fs wall | modelLoading %.2fs — prewarm %.2f, encoder %.2f, decoder %.2f, tokenizer %.2f  [encoder on %@]",
                         loadWall, t.modelLoading, t.prewarmLoadTime, t.encoderLoadTime, t.decoderLoadTime, t.tokenizerLoadTime,
                         fastLoad ? "GPU" : "ANE"))

            // Real per-step logit bias for the clinical vocabulary. Unlike the
            // initial-prompt priming this stays active for the whole session.
            if let tokenizer = kit.tokenizer {
                kit.textDecoder.logitsFilters = [
                    SequenceBiasFilter(sequences: ClinicalConfig.boostSequences(for: tokenizer)),
                ]
            }
            whisperKit = kit
            // Silero VAD is optional: if it fails to load, batch falls back to
            // whole-clip transcription and live decodes every window ungated.
            vad = try? SileroVADEngine()
            isReady = true
            downloadProgress = 0
            statusMessage = "Model ready (\(Self.bundledModelName))"
            print("[Mem] after WhisperKit load:  \(Self.availableMemoryMB()) MB available")
        } catch {
            downloadProgress = 0
            statusMessage = "Failed to load: \(error.localizedDescription)"
        }
    }

    // MARK: - Model download

    /// Where downloads land. Application Support rather than Caches: the system can
    /// purge Caches under disk pressure, and re-downloading 600 MB mid-clinic is not
    /// a risk worth taking. Excluded from iCloud backup — it is re-downloadable.
    private static func downloadBase() throws -> URL {
        var url = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("WhisperKitModels", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    /// Reuse a previous download if we have one; otherwise fetch with progress.
    private func resolveDownloadedModel() async throws -> URL {
        let fm = FileManager.default

        // Downloaded on an earlier launch? Validate by the file WhisperKit needs,
        // not just by the directory existing — a half-finished download leaves the
        // folder behind.
        if let cached = UserDefaults.standard.string(forKey: Self.cachedModelPathKey) {
            let url = URL(fileURLWithPath: cached)
            if fm.fileExists(atPath: url.appendingPathComponent("AudioEncoder.mlmodelc").path) {
                statusMessage = "Loading downloaded model…"
                return url
            }
            UserDefaults.standard.removeObject(forKey: Self.cachedModelPathKey)
        }

        // Retry: -1001 (request timed out) is transient, and the Hub API skips files
        // it already has, so each attempt resumes rather than restarting.
        var lastError: Error?
        for attempt in 1...3 {
            do {
                statusMessage = attempt == 1
                    ? "Downloading model…\n(one-time, ~600 MB — keep the app open)"
                    : "Download interrupted — retrying (\(attempt) of 3)…"
                downloadProgress = 0

                let url = try await WhisperKit.download(
                    variant: Self.networkModelVariant,
                    downloadBase: try Self.downloadBase(),
                    useBackgroundSession: false,
                    progressCallback: { [weak self] progress in
                        Task { @MainActor in
                            guard let self else { return }
                            let pct = progress.fractionCompleted
                            self.downloadProgress = pct
                            self.statusMessage = String(
                                format: "Downloading model… %.0f%%\n(one-time — keep the app open)",
                                pct * 100)
                        }
                    }
                )

                UserDefaults.standard.set(url.path, forKey: Self.cachedModelPathKey)
                downloadProgress = 1
                return url
            } catch {
                lastError = error
                print("[ModelDownload] attempt \(attempt) failed: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw lastError ?? URLError(.timedOut)
    }

    // MARK: - Speaker gate

    /// True once a centroid exists. Read this rather than tracking a separate flag.
    var isSpeakerEnrolled: Bool { speakerGate?.isEnrolled ?? false }

    /// Build the app-wide gate on first use, independent of the WhisperKit load.
    ///
    /// Falls back to its own SileroVADEngine when `vad` is not set yet — during
    /// onboarding it usually is not, because `performLoad` assigns it only AFTER
    /// the WhisperKit load completes.
    ///
    /// Synchronous: it loads two small Core ML models on the main actor (~100 ms).
    /// Acceptable for a one-time setup call; do not put it in a render path.
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
    ) async -> (templates: Int, seconds: Double, totalSpans: Int,
                eligibleSpans: Int, takes: Int) {

        guard let service = makeSpeakerGateIfNeeded() else { return (0, 0, 0, 0, 0) }
        let store = VoiceProfileStore.shared
        guard let profileID = store.activeID else { return (0, 0, 0, 0, 0) }
        let urls = store.activeTakeURLs
        guard !urls.isEmpty else { return (0, 0, 0, 0, 0) }

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
                        fromFile: url, minSeconds: 3.0, maxPerFile: perTake) else {
                    print("[Enroll] \(url.lastPathComponent): no usable spans")
                    continue
                }

                let takeAdded = (try? service.enroll(utterances: selection.utterances)) ?? 0
                print(String(format: "[Enroll] %@: %.1fs, %d span(s), %d eligible -> %d template(s)",
                             url.lastPathComponent, selection.audioSeconds,
                             selection.totalSpans, selection.eligibleSpans, takeAdded))

                result.templates     += takeAdded
                result.seconds       += selection.audioSeconds
                result.totalSpans    += selection.totalSpans
                result.eligibleSpans += selection.eligibleSpans
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

        return (outcome.templates, outcome.seconds,
                outcome.totalSpans, outcome.eligibleSpans, outcome.takes)
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
