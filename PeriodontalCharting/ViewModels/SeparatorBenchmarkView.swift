//
//  SeparatorBenchmarkView.swift
//  PeriodontalCharting
//
//  Created by Hans Joachim Wiryonoptutro on 31/07/26.
//
//  Standalone so nothing existing needs editing. Present it however you reach
//  SpeakerGateDebugView.
//

import SwiftUI
import UIKit

struct SeparatorBenchmarkView: View {

    @State private var report = ""
    @State private var isRunning = false
    @State private var blocks = 50
    @State private var repeats = 5

    var body: some View {
        List {
            Section("Why this exists") {
                Text("Every latency number for the extractor so far is from a Mac. "
                   + "This measures TargetSeparator_BSRNN on the actual device, "
                   + "with dummy tensors — no audio, no pipeline.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Parameters") {
                Stepper("blocks: \(blocks)", value: $blocks, in: 10...500, step: 10)
                Stepper("repeats: \(repeats)", value: $repeats, in: 1...20)
                Text("\(Int(Double(blocks) * SeparatorBenchmark.msAudioPerBlock / 1000.0)) s "
                   + "of audio per repeat")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button(isRunning ? "Running…" : "Run benchmark") { runBenchmark() }
                    .disabled(isRunning)
                if !report.isEmpty {
                    Button("Copy result") { UIPasteboard.general.string = report }
                }
            }

            if !report.isEmpty {
                Section("Result") {
                    Text(report)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section("How to read it") {
                    Text("RTF 0.2–0.4 → comfortable headroom, proceed.\n"
                       + "RTF ≈ 1.0 → a 6 s span takes 6 s to extract. Needs a "
                       + "lighter model or fewer enrollment keys.\n"
                       + "RTF > 1 → revisit the architecture before integrating.\n\n"
                       + "Also capture the [RTF] live: Whisper logs on this same "
                       + "device — the extractor shares the budget with a ~1 GB "
                       + "transcription model that STT_ISSUES already flags as slow.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Separator benchmark")
    }

    private func runBenchmark() {
        isRunning = true
        report = ""
        let b = blocks, r = repeats
        DispatchQueue.global(qos: .userInitiated).async {
            let text: String
            do { text = try SeparatorBenchmark.run(blocks: b, repeats: r) }
            catch { text = "FAILED\n\(error.localizedDescription)" }
            DispatchQueue.main.async {
                report = text
                isRunning = false
            }
        }
    }
}
