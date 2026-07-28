//
//  TranscriptionEngine.swift
//  PeriodontalCharting
//
//  Single, app-wide WhisperKit model + Silero VAD, loaded once at launch and
//  shared by every TranscriptionViewModel (AI Mode, the live sheet, the test
//  view). The model is ~1 GB; loading a copy per view-model would blow memory
//  (the full turbo build already got the app SIGKILL'd), so all live/batch
//  transcription draws from this one instance.
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

    /// The in-flight (or completed) load, so concurrent callers coalesce onto one
    /// load instead of racing to build multiple WhisperKit instances.
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    // Model naming: folders in argmaxinc/whisperkit-coreml use an underscore before
    // "turbo" (openai_whisper-large-v3_turbo), NOT a hyphen. The full turbo build is
    // ~3.2 GB and was getting the app SIGKILL'd mid-download; we ship the ~1 GB
    // quantized build in the bundle and load it from disk (no first-launch download).
//    private static let bundledModelName = "openai_whisper-large-v3_turbo_954MB"
    private static let bundledModelName = "openai_whisper-large-v3_turbo_632MB"
    private static let networkModelName = "openai_whisper-large-v3_turbo"

    private init() {}

    /// Load the shared model. Idempotent and coalesced: a completed load returns
    /// immediately, concurrent callers await the same in-flight load, and a failed
    /// load can be retried on the next call. Called once at launch (see the App)
    /// and again from each view-model's `loadModel()` — which then just reflects
    /// the already-warm state.
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
            // Compute-unit choice drives LOAD time. The AudioEncoder defaults to the
            // Neural Engine, but the ANE graph specialization is the slowest part of
            // loading and, in practice, is re-done on nearly every launch (the ANE
            // compile cache is fragile). Running the encoder on the GPU skips that ANE
            // specialization -> much faster, consistent loads, with negligible runtime
            // cost on the encoder. The TextDecoder — which benefits most from the ANE —
            // stays there for fast inference.
            // Measured (see [ModelLoad] log): encoder ANE compile = ~199s, the entire
            // load. `.all` still lets CoreML put encoder layers on the ANE, so it keeps
            // paying that. `.cpuAndGPU` EXPLICITLY excludes the ANE for the encoder →
            // no ANE compile, load drops to seconds, with negligible runtime cost (the
            // encoder runs once per window). Decoder stays on ANE (7s compile) for the
            // fast autoregressive per-token loop — that's where the inference win is.
            let compute = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .all,
                textDecoderCompute: .cpuAndNeuralEngine
            )

            // Xcode's synchronized-group build flattens the model folder, so the four
            // *.mlmodelc bundles land at the bundle ROOT. Detect that via AudioEncoder.mlmodelc.
            let resourceURL = Bundle.main.resourceURL
            let hasBundledModel = resourceURL.map {
                FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent("AudioEncoder.mlmodelc").path)
            } ?? false

            let config: WhisperKitConfig
            if hasBundledModel, let folder = resourceURL {
                statusMessage = "Loading bundled model…"
                config = WhisperKitConfig(modelFolder: folder.path, computeOptions: compute)
            } else {
                statusMessage = "Downloading model…\n(large one-time download; keep app foregrounded)"
                config = WhisperKitConfig(model: Self.networkModelName, computeOptions: compute)
            }
            let loadStart = Date()
            let kit = try await WhisperKit(config)
            let loadWall = Date().timeIntervalSince(loadStart)

            // [ModelLoad] Where the load time goes. There's no download here — this is
            // pure on-device work: CoreML re-compiling the .mlmodelc for the chosen
            // compute units (the ANE compile + weight re-tiling dominates when the
            // encoder/decoder are on .cpuAndNeuralEngine) plus tokenizer load.
            // WhisperKit's own per-stage timings break it down (encoder vs decoder).
            // NOTE: this cache is per-install — the first launch after a (re)install
            // pays the full ANE compile; launch 2+ on a stable install is far cheaper.
            let t = kit.currentTimings
            print(String(format: "[ModelLoad] %.2fs wall | modelLoading %.2fs — prewarm %.2f, encoder %.2f, decoder %.2f, tokenizer %.2f",
                         loadWall, t.modelLoading, t.prewarmLoadTime, t.encoderLoadTime, t.decoderLoadTime, t.tokenizerLoadTime))

            // Real per-step logit bias for the clinical vocabulary (see
            // SequenceBiasFilter): unlike the initial-prompt priming in
            // ClinicalConfig.decodingOptions, this stays active for the whole
            // session, not just the first few tokens of context. Set once here since
            // WhisperKit.textDecoder is shared across batch and live modes.
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
            statusMessage = "Model ready (\(Self.bundledModelName))"
        } catch {
            statusMessage = "Failed to load: \(error.localizedDescription)"
        }
    }
}
