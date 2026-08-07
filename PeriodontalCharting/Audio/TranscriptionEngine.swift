//
//  TranscriptionEngine.swift
//  PeriodontalCharting
//
//  Single, app-wide WhisperKit model + Silero VAD, loaded once at launch and
//  shared by every TranscriptionViewModel (AI Mode, the live sheet, the test
//  view). The model is ~600 MB; loading a copy per view-model would blow memory
//  (the full turbo build already got the app SIGKILL'd), so all live/batch
//  transcription draws from this one instance.
//
//  MODEL SOURCING, in order: bundled at the app root -> previously downloaded and
//  remembered in UserDefaults -> downloaded from HuggingFace with progress and
//  retry. The model folders are gitignored, so a fresh clone has no bundled copy
//  and the download path is the normal one — it needs to be robust, not a
//  fallback nobody tested.
//
//  Also owns the app-wide SpeakerGateService. That is DELIBERATELY independent of
//  the WhisperKit load: enrollment needs only the small ECAPA embedder and Silero
//  VAD, and gating it behind a ~600 MB model meant onboarding always found `vad`
//  still nil and silently skipped calibration.
//

import Foundation
import CoreML
import Observation
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
    /// Exact repo folder name. `WhisperKit.download` globs `*<variant>/*`, so an
    /// imprecise name matches several folders and forces its disambiguation path.
    private static let networkModelVariant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    /// Remembers where a completed download landed, so relaunching does not
    /// re-download 600 MB.
    private static let cachedModelPathKey = "WhisperKitCachedModelPath"

    /// Where onboarding writes the calibration recording. Single source of truth
    /// for both enrollment and restore.
    static var calibrationURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voice_sample.wav")
    }

    private init() {}

    /// Load the shared model. Idempotent and coalesced: a completed load returns
    /// immediately, concurrent callers await the same in-flight load, and a failed
    /// load can be retried on the next call.
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
            // Compute-unit choice drives LOAD time. Measured (see [ModelLoad] log):
            // encoder ANE compile = ~199s, the entire load. `.all` still lets CoreML
            // put encoder layers on the ANE, so it keeps paying that. `.cpuAndGPU`
            // EXPLICITLY excludes the ANE for the encoder → no ANE compile, load drops
            // to seconds, with negligible runtime cost (the encoder runs once per
            // window). Decoder stays on ANE (7s compile) for the fast autoregressive
            // per-token loop — that's where the inference win is.
            let compute = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndGPU, // .cpuAndGPU for fast loads
                textDecoderCompute: .cpuAndNeuralEngine
            )

            // Xcode's synchronized-group build flattens the model folder, so the four
            // *.mlmodelc bundles land at the bundle ROOT. Detect that via AudioEncoder.mlmodelc.
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
            let loadStart = Date()
            let kit = try await WhisperKit(config)
            let loadWall = Date().timeIntervalSince(loadStart)

            // [ModelLoad] Where the load time goes. No download here — this is pure
            // on-device work: CoreML re-compiling the .mlmodelc for the chosen compute
            // units (the ANE compile + weight re-tiling dominates) plus tokenizer load.
            // NOTE: this cache is per-install — the first launch after a (re)install
            // pays the full ANE compile; launch 2+ on a stable install is far cheaper.
            let t = kit.currentTimings
            print(String(format: "[ModelLoad] %.2fs wall | modelLoading %.2fs — prewarm %.2f, encoder %.2f, decoder %.2f, tokenizer %.2f",
                         loadWall, t.modelLoading, t.prewarmLoadTime, t.encoderLoadTime, t.decoderLoadTime, t.tokenizerLoadTime))

            // Real per-step logit bias for the clinical vocabulary (see
            // SequenceBiasFilter): unlike the initial-prompt priming in
            // ClinicalConfig.decodingOptions, this stays active for the whole
            // session, not just the first few tokens of context.
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
        // it already has, so each attempt resumes rather than restarting. A single
        // stalled connection previously failed the entire load.
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

    /// Enroll from the calibration recording. ONE implementation for both
    /// launch-time restore and onboarding.
    ///
    /// - Parameters:
    ///   - reset: clear existing templates first. True when the clinician has just
    ///     re-recorded; false when restoring at launch.
    ///   - waitForFile: poll until the WAV is readable. AVAudioRecorder finalises
    ///     ASYNCHRONOUSLY after stop(), so reading immediately can get a truncated
    ///     file that looks exactly like "no speech".
    @discardableResult
    func enrollFromCalibration(
        reset: Bool,
        waitForFile: Bool
    ) async -> (templates: Int, seconds: Double, totalSpans: Int, eligibleSpans: Int) {

        guard let service = makeSpeakerGateIfNeeded() else { return (0, 0, 0, 0) }
        let url = Self.calibrationURL

        return await Task.detached(priority: .userInitiated) {
            var seconds = 0.0
            let attempts = waitForFile ? 12 : 1
            for _ in 0..<attempts {
                seconds = ((try? SpeakerGate.loadSamples(from: url))?.count).map {
                    Double($0) / Double(SpeakerGate.sampleRate)
                } ?? 0
                if seconds >= 1.0 { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard seconds >= 1.0 else { return (0, seconds, 0, 0) }

            if reset { service.resetEnrollment() }
            guard let selection = try? service.enrollmentSelection(
                    fromFile: url,
                    minSeconds: 3.0,
                    maxPerFile: SpeakerGate.maxTemplates) else {
                return (0, seconds, 0, 0)
            }
            let added = (try? service.enroll(utterances: selection.utterances)) ?? 0
            return (added, selection.audioSeconds,
                    selection.totalSpans, selection.eligibleSpans)
        }.value
    }

    /// Rebuild the centroid at launch from the stored calibration recording.
    /// Templates are in memory only, so without this the clinician re-calibrates
    /// on every cold start. Idempotent and coalesced, like `load()`.
    func restoreEnrollment() async {
        if isSpeakerEnrolled { return }
        if enrollmentTask == nil {
            enrollmentTask = Task {
                _ = await self.enrollFromCalibration(reset: false, waitForFile: false)
            }
        }
        await enrollmentTask?.value
        if !isSpeakerEnrolled { enrollmentTask = nil }   // allow a retry
    }
}
