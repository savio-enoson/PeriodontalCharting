//
//  SeparatorBenchmarkViewModel.swift
//  PeriodontalCharting
//
//  MVVM view-model: owns benchmark parameters, run state, and all formatting.
//  The View only observes and sends intents; it holds no Core ML references and
//  no logic. Matches TranscriptionViewModel's contract.
//

import Foundation
import Observation

@MainActor
@Observable
final class SeparatorBenchmarkViewModel {

    // MARK: - Intent-bound parameters (the View writes these)

    var blocks: Int = 50
    var repeats: Int = 5
    /// Run on Simulator / Mac anyway. Plumbing check only — the resulting
    /// numbers cannot answer the A16 question.
    var allowNonDevice: Bool = false

    // MARK: - Observable state (the View reads these)

    private(set) var isRunning = false
    private(set) var report: BenchmarkReport?
    private(set) var errorMessage: String?

    // MARK: - Dependencies

    private let service: SeparatorBenchmarking

    init(service: SeparatorBenchmarking = SeparatorBenchmarkService()) {
        self.service = service
    }

    // MARK: - Derived presentation

    var isRealDevice: Bool { service.environment.isRealDevice }
    var environmentLabel: String { service.environment.label }

    /// Shown before any run, so the trap is visible without pressing anything.
    var environmentWarning: String? {
        guard !isRealDevice else { return nil }
        return "Running on \(environmentLabel). No Apple Neural Engine here — "
             + "Core ML falls back silently. Build to the physical iPad for a "
             + "number that means anything."
    }

    var audioSecondsPerRepeat: Double {
        Double(blocks) * SeparatorBenchmarkService.msAudioPerBlock / 1000.0
    }

    var canRun: Bool { !isRunning }

    /// Plain-text rendering, for the clipboard. The View performs the paste.
    var reportText: String {
        guard let report else { return errorMessage ?? "" }
        var out = "TargetSeparator_BSRNN\n"
        out += "\(report.blocks) blocks x \(report.repeats) repeats · "
        out += "1 block = \(Int(SeparatorBenchmarkService.msAudioPerBlock)) ms audio\n"
        out += "device: \(report.environment.label)\n"
        if !report.environment.isRealDevice {
            out += "*** NOT THE A16 — these numbers do not answer the question ***\n"
        }
        out += "thermal: \(report.thermalAtStart) -> \(report.thermalAtEnd)\n\n"
        out += String(format: "%-14@%11@%11@%9@\n", "unit" as NSString,
                      "median ms" as NSString, "min ms" as NSString, "RTF" as NSString)
        for row in report.rows {
            if let failure = row.failure {
                out += String(format: "%-14@%@\n", row.unit as NSString,
                              "FAILED — \(failure.prefix(80))" as NSString)
            } else {
                out += String(format: "%-14@%11.2f%11.2f%9.3f\n", row.unit as NSString,
                              row.medianMs ?? .nan, row.minMs ?? .nan, row.rtf ?? .nan)
            }
        }
        out += "\nMac (M5) reference: 5.5-11 ms/block, RTF 0.086-0.311."
        return out
    }

    /// Verdict on the best available compute unit, in the project's own terms.
    var interpretation: String? {
        guard let report,
              let best = report.rows.compactMap(\.rtf).min() else { return nil }
        if report.throttled {
            return "Device throttled mid-run — rerun when cool before trusting this."
        }
        switch best {
        case ..<0.5:
            return String(format: "RTF %.2f — comfortable headroom. Proceed to the "
                        + "span-extraction implementation.", best)
        case 0.5..<1.0:
            return String(format: "RTF %.2f — works, but the extractor shares this "
                        + "budget with a ~1 GB Whisper model that STT_ISSUES already "
                        + "flags as slow. Measure Whisper on this device too.", best)
        default:
            return String(format: "RTF %.2f — a 6 s span takes longer than 6 s to "
                        + "extract. Needs fewer enrollment keys or a lighter model "
                        + "before integration is worth starting.", best)
        }
    }

    // MARK: - Intents

    func runBenchmark() {
        guard !isRunning else { return }
        isRunning = true
        report = nil
        errorMessage = nil

        let service = self.service
        let blocks = self.blocks
        let repeats = self.repeats
        let allowNonDevice = self.allowNonDevice

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try service.run(blocks: blocks,
                                         repeats: repeats,
                                         allowNonDevice: allowNonDevice) }
            }.value

            switch outcome {
            case .success(let value): report = value
            case .failure(let error): errorMessage = error.localizedDescription
            }
            isRunning = false
        }
    }

    func reset() {
        report = nil
        errorMessage = nil
    }
}
