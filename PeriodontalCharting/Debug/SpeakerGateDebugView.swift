//
//  SpeakerGateDebugView.swift
//  PeriodontalCharting
//
//  Created by Hans Joachim Wiryonoptutro on 27/07/26.
//
//  Milestone-1 harness: validates the speaker gate on FILES, with no microphone
//  and no WhisperKit dependency. This is deliberate — it isolates the TSE layer
//  from STT so a failure here is unambiguously the gate's.
//

import SwiftUI
import UIKit

struct SpeakerGateDebugView: View {

    @State private var service: SpeakerGateService?
    @State private var status = "Not initialized"
    @State private var templateCount = 0
    @State private var spans: [GatedSpan] = []
    @State private var isWorking = false
    @State private var adaptive = false

    var body: some View {
        List {
            Section("Extraction") {
                Text("Mode: \(TSEConfig.mode.rawValue). Routing decisions and "
                     + "per-span distances go to the console as [Gate/live] and "
                     + "[TSE/live]. The A16 benchmark and the TSE harness were "
                     + "removed once their numbers were recorded in handoff.md.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            
            Section("Status") {
                Text(status).font(.callout)
                LabeledContent("Templates", value: "\(templateCount)")
                LabeledContent("Enrolled", value: (service?.isEnrolled ?? false) ? "yes" : "no")
            }

            Section("Enrollment") {
                Button("Enroll from voice_sample.wav") { enroll() }
                    .disabled(isWorking)
                Text("Onboarding now enrolls automatically when calibration is "
                     + "recorded, and TranscriptionEngine restores it at launch. "
                     + "This button re-runs it by hand.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Reset enrollment", role: .destructive) {
                    service?.resetEnrollment()
                    templateCount = 0
                    spans = []
                    status = "Enrollment cleared"
                }
            }

            Section("Evaluate") {
                Toggle("Adaptive enrollment", isOn: $adaptive)
                Button("Run gate on sample.mp3") { evaluateBundledSample() }
                    .disabled(isWorking || !(service?.isEnrolled ?? false))
                Button("Run gate on voice_sample.wav (sanity: expect ACCEPT)") {
                    evaluateCalibration()
                }
                .disabled(isWorking || !(service?.isEnrolled ?? false))
            }

            if !spans.isEmpty {
                Section("Summary") {
                    ForEach(summary, id: \.0) { LabeledContent($0.0, value: $0.1) }
                    Button("Copy distances for Python parity check") { copyDistances() }
                }

                Section("Spans") {
                    ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                        HStack {
                            Circle().fill(color(span.verdict)).frame(width: 10, height: 10)
                            Text(span.verdict.rawValue).bold()
                            Spacer()
                            Text(String(format: "%.1f–%.1fs", span.startSeconds, span.endSeconds))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(span.distance.map { String(format: "d=%.3f", $0) } ?? "—")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Speaker Gate (TSE)")
        .task { initializeIfNeeded() }
    }

    // MARK: - Setup

    /// Uses the APP-WIDE gate from TranscriptionEngine, so this view reflects the
    /// enrollment onboarding actually made. Building a private SpeakerGateService
    /// here would show an empty one and hide whether calibration worked.
    private func initializeIfNeeded() {
        guard service == nil else { return }
        guard let shared = TranscriptionEngine.shared.makeSpeakerGateIfNeeded() else {
            status = "Speaker gate unavailable — ECAPA or Silero VAD failed to load"
            return
        }
        service = shared
        templateCount = shared.templateCount
        status = shared.isEnrolled
            ? "Ready — \(shared.templateCount) template(s) enrolled"
            : "Ready — enroll to begin"
    }

    // MARK: - Actions

    private var calibrationURL: URL { TranscriptionEngine.calibrationURL }

    private func enroll() {
        initializeIfNeeded()
        guard let service else { return }
        guard FileManager.default.fileExists(atPath: calibrationURL.path) else {
            status = "voice_sample.wav not found — run onboarding calibration first"
            return
        }
        isWorking = true
        status = "Enrolling…"
        let url = calibrationURL
        Task.detached {
            service.resetEnrollment()
            let n = (try? service.enrollmentUtterances(
                        fromFile: url,
                        minSeconds: 3.0,
                        maxPerFile: SpeakerGate.maxTemplates))
                .flatMap { try? service.enroll(utterances: $0) } ?? 0
            await MainActor.run {
                templateCount = service.templateCount
                status = n > 0 ? "Enrolled \(n) template(s)" : "No usable speech in calibration"
                isWorking = false
            }
        }
    }

    private func evaluateBundledSample() {
        guard let url = Bundle.main.url(forResource: "sample", withExtension: "mp3") else {
            status = "sample.mp3 not in bundle"
            return
        }
        run(url, label: "sample.mp3")
    }

    private func evaluateCalibration() {
        run(calibrationURL, label: "voice_sample.wav")
    }

    private func run(_ url: URL, label: String) {
        guard let service else { return }
        isWorking = true
        status = "Evaluating \(label)…"
        let useAdapt = adaptive
        Task.detached {
            do {
                let audio = try SpeakerGate.loadSamples(from: url)
                let result = try service.evaluate(audio: audio, adapt: useAdapt)
                await MainActor.run {
                    spans = result
                    templateCount = service.templateCount
                    let secs = Double(audio.count) / Double(SpeakerGate.sampleRate)
                    status = String(format: "%@ — %.1fs, %d spans", label, secs, result.count)
                    isWorking = false
                }
            } catch {
                await MainActor.run {
                    status = "Evaluate failed: \(error)"
                    isWorking = false
                }
            }
        }
    }

    // MARK: - Presentation

    private func color(_ v: Verdict) -> Color {
        switch v {
        case .accept: return .green
        case .confirm: return .orange
        case .reject: return .red
        case .tooShort: return .gray
        }
    }

    private var summary: [(String, String)] {
        var rows: [(String, String)] = []
        for verdict in [Verdict.accept, .confirm, .reject, .tooShort] {
            let matching = spans.filter { $0.verdict == verdict }
            guard !matching.isEmpty else { continue }
            let ds = matching.compactMap(\.distance)
            let mean = ds.isEmpty ? 0 : ds.reduce(0, +) / Double(ds.count)
            let secs = matching.reduce(0) { $0 + $1.durationSeconds }
            rows.append((verdict.rawValue,
                         String(format: "%d spans, %.1fs, mean d=%.3f", matching.count, secs, mean)))
        }
        let passing = spans.filter(\.passesGate).reduce(0) { $0 + $1.durationSeconds }
        let total = spans.reduce(0) { $0 + $1.durationSeconds }
        rows.append(("passing gate", String(format: "%.1fs of %.1fs (%.0f%%)",
                                            passing, total, total > 0 ? passing / total * 100 : 0)))
        return rows
    }

    private func copyDistances() {
        let lines = spans.compactMap { span -> String? in
            guard let d = span.distance else { return nil }
            return String(format: "%.6f\t%@\t%.2f\t%.2f",
                          d, span.verdict.rawValue, span.startSeconds, span.endSeconds)
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        status = "Copied \(lines.count) distances"
    }
}
