//
//  SeparatorBenchmarkView.swift
//  PeriodontalCharting
//
//  Pure view: observes SeparatorBenchmarkViewModel and sends intents. No Core ML,
//  no timing, no formatting logic.
//

import SwiftUI
import UIKit

struct SeparatorBenchmarkView: View {

    @State private var viewModel = SeparatorBenchmarkViewModel()

    var body: some View {
        List {
            Section("Why this exists") {
                Text("Every latency number for the extractor so far comes from a "
                   + "Mac. This measures TargetSeparator_BSRNN on the actual "
                   + "device with dummy tensors — no audio, no pipeline.")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("Running on", value: viewModel.environmentLabel)
                if let warning = viewModel.environmentWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Parameters") {
                Stepper("Blocks: \(viewModel.blocks)",
                        value: $viewModel.blocks, in: 10...500, step: 10)
                Stepper("Repeats: \(viewModel.repeats)",
                        value: $viewModel.repeats, in: 1...20)
                Text(String(format: "%.1f s of audio per repeat",
                            viewModel.audioSecondsPerRepeat))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Allow Simulator / Mac (plumbing check only)",
                       isOn: $viewModel.allowNonDevice)
            }

            Section {
                Button(viewModel.isRunning ? "Running…" : "Run benchmark") {
                    viewModel.runBenchmark()
                }
                .disabled(!viewModel.canRun)

                if viewModel.report != nil || viewModel.errorMessage != nil {
                    Button("Copy result") {
                        UIPasteboard.general.string = viewModel.reportText
                    }
                    Button("Clear", role: .destructive) { viewModel.reset() }
                }
            }

            if let message = viewModel.errorMessage {
                Section("Result") {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            if let report = viewModel.report {
                Section("Results") {
                    ForEach(report.rows) { row in
                        HStack {
                            Text(row.unit).bold()
                            Spacer()
                            if let failure = row.failure {
                                Text(failure.prefix(40) + "…")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            } else {
                                Text(String(format: "%.2f ms", row.medianMs ?? .nan))
                                    .monospacedDigit()
                                Text(String(format: "RTF %.3f", row.rtf ?? .nan))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Run info") {
                    LabeledContent("Thermal",
                                   value: "\(report.thermalAtStart) → \(report.thermalAtEnd)")
                    if report.throttled {
                        Label("Device throttled — numbers unreliable",
                              systemImage: "thermometer.high")
                            .font(.caption).foregroundStyle(.red)
                    }
                }

                if let interpretation = viewModel.interpretation {
                    Section("Verdict") {
                        Text(interpretation).font(.footnote)
                    }
                }

                Section("Notes") {
                    Text("Mac (M5) reference: 5.5–11 ms/block, RTF 0.086–0.311. "
                       + "Run several times — sustained load throttles, and on the "
                       + "Mac the ordering of compute units was not reproducible.\n\n"
                       + "CPU_AND_GPU failing with an Espresso/MPSGraph error is "
                       + "expected wherever there is no real Metal Core ML path.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Separator benchmark")
    }
}
