//
//  TSEDebugView.swift
//  PeriodontalCharting
//
//  File-based harness for the rescue path — no mic, no session ownership
//  conflict, same role `SpeakerGateDebugView` plays for the gate.
//
//  The number to read here is not SI-SDR (there is no clean reference on real
//  clinic audio). It is: how many spans ROUTE, and does `d` move DOWN when they
//  do. Open item 7 is on-device VERDICT parity — 0.9996 embedding cosine did not
//  guarantee identical verdicts near a threshold.
//

import SwiftUI

struct TSEDebugView: View {
    let audioURL: URL

    @State private var results: [RescuedSpan] = []
    @State private var running = false
    @State private var message = ""

    private var engine = TSEEngine.shared

    init(audioURL: URL) { self.audioURL = audioURL }

    var body: some View {
        List {
            Section("Extractor") {
                Text(engine.status).font(.footnote.monospaced())
                Button("Load + enroll") { Task { await engine.prepare() } }
                Button(running ? "Running…" : "Run rescue path on this file") { run() }
                    .disabled(running || !engine.isReady)
                if !message.isEmpty {
                    Text(message).font(.footnote.monospaced()).foregroundStyle(.secondary)
                }
            }
            if !results.isEmpty {
                Section("Spans — \(results.filter(\.routed).count) routed of \(results.count)") {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                        HStack {
                            Text(String(format: "%6.2f–%6.2f", r.startSeconds, r.endSeconds))
                                .font(.caption.monospaced())
                            Spacer()
                            Text(String(format: "%.3f", r.distanceMixed ?? -1))
                                .font(.caption.monospaced())
                            if let d = r.distanceSeparated {
                                Text("→ \(String(format: "%.3f", d))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(r.rescued ? .green : .orange)
                            }
                            Text(r.effectiveVerdict.rawValue).font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle("TSE rescue path")
    }

    private func run() {
        running = true
        let url = audioURL
        let extractor = engine.extractor
        let gate = TranscriptionEngine.shared.speakerGate
        Task.detached(priority: .userInitiated) {
            do {
                guard let gate else { throw TargetSpeakerExtractor.ExtractorError.notPrepared }
                let audio = try SpeakerGate.loadSamples(from: url)
                let began = CFAbsoluteTimeGetCurrent()
                let spans = try gate.evaluateWithRescue(audio: audio, extractor: extractor)
                let wall = CFAbsoluteTimeGetCurrent() - began
                let seconds = Double(audio.count) / Double(SpeakerGate.sampleRate)
                await MainActor.run {
                    results = spans
                    message = String(format: "%.1fs audio in %.1fs wall (RTF %.2f), mode %@",
                                     seconds, wall, wall / max(seconds, 0.001),
                                     TSEConfig.mode.rawValue)
                    running = false
                }
            } catch {
                await MainActor.run {
                    message = error.localizedDescription
                    running = false
                }
            }
        }
    }
}
