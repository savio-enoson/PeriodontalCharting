//
//  SeparatorBenchmarkService.swift
//
//  Measures TargetSeparator_BSRNN on real hardware with dummy tensors — no
//  audio, no VAD, no pipeline. Answers the one binding unknown for the target
//  speaker extraction layer: does the A16 keep up?
//
//  Service layer, mirroring SpeakerGateService: no UI, no observable state,
//  returns a value type. The ViewModel owns presentation.
//
//  REFUSES TO RUN off-device by default. The Simulator has no Apple Neural
//  Engine and falls back to CPU silently; "Designed for iPad" on a Mac measures
//  the Mac. A number from either is worse than no number — it invites a false
//  conclusion. STT_ISSUES item 2 already flags this trap for Whisper latency.
//
//  Mac (M5) reference, for comparison:
//      CPU_ONLY    5.44 / 9.05 / 5.53 ms per block   (three runs)
//      CPU_AND_NE  6.12 / 6.79 / 6.58 ms
//      ALL         6.14 / 6.64 / 10.99 ms
//      CPU_AND_GPU 10.50 / 19.17 / 19.88 ms   <- consistently worst
//  The ORDER FLIPS between runs, which is why this reports median and min over
//  several repeats rather than a single number.
//

import CoreML
import Foundation

// MARK: - Model types

/// Where the benchmark is actually executing. Only `.device` produces numbers
/// that answer the A16 question.
enum BenchmarkEnvironment: Equatable {
    case device(machine: String)
    case simulator
    case macCatalyst
    case iOSAppOnMac

    var isRealDevice: Bool {
        if case .device = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .device(let machine): return machine
        case .simulator:           return "iOS Simulator"
        case .macCatalyst:         return "Mac Catalyst"
        case .iOSAppOnMac:         return "iOS app on macOS (\"Designed for iPad\")"
        }
    }
}

/// One compute unit's result. `failure` non-nil means that backend could not
/// run — expected for CPU_AND_GPU wherever there is no real Metal Core ML path
/// (it throws "MpsGraph backend validation on incompatible OS").
struct BenchmarkRow: Identifiable, Equatable {
    let unit: String
    let medianMs: Double?
    let minMs: Double?
    let failure: String?

    var id: String { unit }

    var rtf: Double? {
        medianMs.map { $0 / SeparatorBenchmarkService.msAudioPerBlock }
    }
}

struct BenchmarkReport: Equatable {
    let environment: BenchmarkEnvironment
    let blocks: Int
    let repeats: Int
    let thermalAtStart: String
    let thermalAtEnd: String
    let rows: [BenchmarkRow]

    /// Seconds of audio represented by one repeat.
    var audioSecondsPerRepeat: Double {
        Double(blocks) * SeparatorBenchmarkService.msAudioPerBlock / 1000.0
    }

    /// True when the thermal state degraded during the run — numbers unreliable.
    var throttled: Bool {
        thermalAtEnd.hasPrefix("serious") || thermalAtEnd.hasPrefix("critical")
    }
}

enum SeparatorBenchmarkError: LocalizedError {
    case modelNotFound
    case unexpectedIO(String)
    case notOnDevice(BenchmarkEnvironment)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "TargetSeparator_BSRNN.mlmodelc not in the bundle. Add the "
                 + ".mlpackage to the app target (deployment target iOS 17+)."
        case .unexpectedIO(let detail):
            return "Unexpected model I/O.\n\(detail)"
        case .notOnDevice(let env):
            return """
            REFUSING TO RUN: this is \(env.label), not an iPad.

            The Simulator has no Apple Neural Engine and falls back to CPU \
            without saying so; "Designed for iPad" on a Mac measures the Mac. \
            Either produces numbers that look real and mean nothing.

            Build and run on the physical A16 iPad. To smoke-test the plumbing \
            anyway, enable "Allow Simulator / Mac".
            """
        }
    }
}

// MARK: - Protocol

/// Injectable so the ViewModel can be driven by a stub in previews and tests.
protocol SeparatorBenchmarking: Sendable {
    func run(blocks: Int, repeats: Int, allowNonDevice: Bool) throws -> BenchmarkReport
    var environment: BenchmarkEnvironment { get }
}

// MARK: - Service

final class SeparatorBenchmarkService: SeparatorBenchmarking, @unchecked Sendable {

    // Architecture constants, from the exported graph.
    static let nBands      = 32
    static let featDim     = 128
    static let nLayers     = 6
    static let hidden      = 256      // feature_dim * 2
    static let blockFrames = 8
    /// 8 frames x 8 ms hop = 64 ms of audio produced per predict() call.
    static let msAudioPerBlock = 64.0

    init() {}

    // MARK: Environment

    var environment: BenchmarkEnvironment {
        #if targetEnvironment(simulator)
        return .simulator
        #elseif targetEnvironment(macCatalyst)
        return .macCatalyst
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac { return .iOSAppOnMac }
        var sysinfo = utsname(); uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return .device(machine: machine)
        #endif
    }

    private var thermalDescription: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious (throttling — results unreliable)"
        case .critical: return "critical (throttling — results unreliable)"
        @unknown default: return "unknown"
        }
    }

    // MARK: Model location

    /// Same lookup strategy as SpeakerGate / SileroVADEngine: Xcode's
    /// synchronized file group flattens AI/, so the compiled model lands at the
    /// bundle ROOT.
    private func locateModel() -> URL? {
        if let root = Bundle.main.resourceURL {
            let flat = root.appendingPathComponent("TargetSeparator_BSRNN.mlmodelc")
            if FileManager.default.fileExists(atPath: flat.path) { return flat }
        }
        return Bundle.main.url(forResource: "TargetSeparator_BSRNN", withExtension: "mlmodelc")
    }

    // MARK: I/O binding

    private struct IONames {
        let features: String, hIn: String, cIn: String, hOut: String, cOut: String
    }

    /// Core ML can rename graph I/O during conversion (same reason
    /// SpeakerGate.resolveIONames exists), so prefer the exported names and fall
    /// back to binding by shape.
    ///
    /// NOTE: h_in and c_in have IDENTICAL shapes, so shape alone cannot tell
    /// them apart. For TIMING that is harmless — swapping them changes nothing.
    /// Before using this model for CORRECTNESS, verify the names are right.
    private func resolveIO(_ model: MLModel) throws -> IONames {
        let ins  = model.modelDescription.inputDescriptionsByName
        let outs = model.modelDescription.outputDescriptionsByName

        if ins["features"] != nil, ins["h_in"] != nil, ins["c_in"] != nil,
           outs["h_out"] != nil, outs["c_out"] != nil {
            return IONames(features: "features", hIn: "h_in", cIn: "c_in",
                           hOut: "h_out", cOut: "c_out")
        }

        let stateShape = [Self.nLayers, 1, Self.nBands, Self.hidden].map(NSNumber.init(value:))
        func isState(_ d: MLFeatureDescription) -> Bool {
            d.multiArrayConstraint?.shape == stateShape
        }
        let stateIns  = ins.filter  { isState($0.value) }.keys.sorted()
        let stateOuts = outs.filter { isState($0.value) }.keys.sorted()
        let featureIn = ins.first { $0.value.multiArrayConstraint != nil && !isState($0.value) }?.key

        guard stateIns.count == 2, stateOuts.count == 2, let feat = featureIn else {
            throw SeparatorBenchmarkError.unexpectedIO(
                "inputs: \(ins.keys.sorted())\noutputs: \(outs.keys.sorted())")
        }
        return IONames(features: feat, hIn: stateIns[0], cIn: stateIns[1],
                       hOut: stateOuts[0], cOut: stateOuts[1])
    }

    // MARK: Tensors

    private func makeArray(_ shape: [Int], random: Bool) throws -> MLMultiArray {
        let a = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: .float32)
        if random {
            let p = a.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<a.count { p[i] = Float.random(in: -0.5...0.5) }
        } else {
            memset(a.dataPointer, 0, a.count * MemoryLayout<Float>.size)
        }
        return a
    }

    // MARK: Run

    /// - Parameters:
    ///   - blocks: predict() calls per repeat. 50 blocks = 3.2 s of audio.
    ///   - repeats: whole-loop repeats. Median and min are reported because
    ///     single runs are not rankable — on the Mac the ordering of compute
    ///     units flipped between runs.
    ///   - allowNonDevice: run on Simulator/Mac anyway. Plumbing check only.
    func run(blocks: Int = 50,
             repeats: Int = 5,
             allowNonDevice: Bool = false) throws -> BenchmarkReport {

        let env = environment
        if !env.isRealDevice && !allowNonDevice {
            throw SeparatorBenchmarkError.notOnDevice(env)
        }
        guard let url = locateModel() else { throw SeparatorBenchmarkError.modelNotFound }

        let thermalStart = thermalDescription

        // GPU last: consistently worst on the Mac, and it is the backend that
        // throws "MpsGraph backend validation on incompatible OS" where no real
        // Metal Core ML path exists. Its failure must not abort the others.
        let units: [(String, MLComputeUnits)] = [
            ("ALL",         .all),
            ("CPU_AND_NE",  .cpuAndNeuralEngine),
            ("CPU_ONLY",    .cpuOnly),
            ("CPU_AND_GPU", .cpuAndGPU),
        ]

        var rows: [BenchmarkRow] = []
        for (name, unit) in units {
            do {
                let timings = try measure(url: url, unit: unit,
                                          blocks: blocks, repeats: repeats)
                let sorted = timings.sorted()
                rows.append(BenchmarkRow(unit: name,
                                         medianMs: sorted[sorted.count / 2],
                                         minMs: sorted.first,
                                         failure: nil))
            } catch {
                rows.append(BenchmarkRow(unit: name, medianMs: nil, minMs: nil,
                                         failure: (error as NSError).localizedDescription))
            }
        }

        return BenchmarkReport(environment: env,
                               blocks: blocks,
                               repeats: repeats,
                               thermalAtStart: thermalStart,
                               thermalAtEnd: thermalDescription,
                               rows: rows)
    }

    /// Returns ms-per-block for each repeat (warm-up discarded).
    private func measure(url: URL, unit: MLComputeUnits,
                         blocks: Int, repeats: Int) throws -> [Double] {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = unit
        let model = try MLModel(contentsOf: url, configuration: cfg)
        let io = try resolveIO(model)

        let features = try makeArray([1, Self.nBands, Self.featDim, Self.blockFrames],
                                     random: true)
        var timings: [Double] = []

        for repeatIndex in 0..<(repeats + 1) {              // index 0 = warm-up
            var h = try makeArray([Self.nLayers, 1, Self.nBands, Self.hidden], random: false)
            var c = try makeArray([Self.nLayers, 1, Self.nBands, Self.hidden], random: false)

            let t0 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<blocks {
                let provider = try MLDictionaryFeatureProvider(dictionary: [
                    io.features: features, io.hIn: h, io.cIn: c
                ])
                let out = try model.prediction(from: provider)
                // Feed state straight back — no copy. A real implementation does
                // the same, which is why this is the honest loop to time.
                guard let hn = out.featureValue(for: io.hOut)?.multiArrayValue,
                      let cn = out.featureValue(for: io.cOut)?.multiArrayValue else {
                    throw SeparatorBenchmarkError.unexpectedIO("missing \(io.hOut) / \(io.cOut)")
                }
                h = hn; c = cn
            }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0 / Double(blocks)
            if repeatIndex > 0 { timings.append(ms) }
        }
        return timings
    }
}
