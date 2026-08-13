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
//  TWO EVALUATION PATHS, and the difference matters. `service.evaluate` is the
//  original span route and produces NO metrics. `service.evaluateWithRescue` is
//  the batch entry point that goes through `route()`, so it computes the full T1
//  overlap battery per span and prints the `[TSE/m]` table. Use the second one
//  against a recording whose overlap regions are known — that is the labelled
//  positive set every metric conclusion so far has lacked.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SpeakerGateDebugView: View {

    @State private var service: SpeakerGateService?
    @State private var status = "Not initialized"
    @State private var templateCount = 0
    @State private var spans: [GatedSpan] = []
    @State private var isWorking = false
    @State private var adaptive = false
    @State private var showImporter = false
    @State private var localFiles: [URL] = []

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

            Section("T1 Metrics — labelled ground truth") {
                // FILES FROM THE APP'S OWN Documents FOLDER. On Simulator this is
                // the only friction-free route: dragging onto the window makes iOS
                // try to OPEN the file, nothing declares .wav, and it fails with
                // "simulator device failed to open". The Files picker cannot see
                // Documents either without UIFileSharingEnabled — which should not
                // be on in a shipping build whose Documents may hold voiceprints.
                // Reading our own container needs neither.
                //
                //   xcrun simctl get_app_container booted \
                //       SavioEnoson.PeriodontalCharting data
                //   cp take.wav "<that path>/Documents/"
                ForEach(localFiles, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        measure(url, label: url.lastPathComponent)
                    }
                    .disabled(isWorking || !(service?.isEnrolled ?? false))
                }
                if localFiles.isEmpty {
                    Text("No audio in Documents/ — copy one in with simctl")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("Refresh") { refreshLocalFiles() }

                Button("Or pick from Files…") { showImporter = true }
                    .disabled(isWorking || !(service?.isEnrolled ?? false))

                Text("Runs `evaluateWithRescue`, so every span gets the full T1 "
                     + "battery and the `[TSE/m]` table prints to the console. "
                     + "Compare each row's time range against the overlap regions "
                     + "you already know for that file.")
                    .font(.caption2).foregroundStyle(.secondary)
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
        .task {
            initializeIfNeeded()
            refreshLocalFiles()
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio, .wav, .mpeg4Audio],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let picked = urls.first else { return }
                importAndMeasure(picked)
            case .failure(let error):
                status = "Pick failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Setup

    // Uses the APP-WIDE gate from TranscriptionEngine, so this view reflects the
    // enrollment onboarding actually made. Building a private SpeakerGateService
    // here would show an empty one and hide whether calibration worked.
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

    // Audio sitting in the app's own Documents directory. No entitlement, no
    // picker, no Files-app involvement — the sandbox always grants this.
    private func refreshLocalFiles() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audio: Set<String> = ["wav", "m4a", "mp3", "caf", "aiff"]
        let found = (try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: nil)) ?? []
        localFiles = found
            .filter { audio.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
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

    // COPY FIRST, THEN MEASURE. A picked URL is security-scoped and its access is
    // only valid between start/stopAccessingSecurityScopedResource on THIS actor —
    // handing it to a detached task is how you get an intermittent read failure
    // that looks like a corrupt file. Copying into tmp while the scope is open
    // removes the lifetime question entirely.
    private func importAndMeasure(_ picked: URL) {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(picked.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: picked, to: destination)
        } catch {
            status = "Could not read picked file: \(error.localizedDescription)"
            return
        }
        measure(destination, label: picked.lastPathComponent)
    }

    // THE METRICS PATH. `evaluateWithRescue` routes every span through `route()`,
    // which calls `measure()` — so the console gets one `[TSE/m]` row per span,
    // under the same code path the live session uses.
    //
    // `extractor: nil` because TSEConfig.mode is `.off`; this is measurement only
    // and no audio is modified.
    private func measure(_ url: URL, label: String) {
        guard let service else { return }
        isWorking = true
        status = "Measuring \(label)…"
        Task.detached {
            do {
                let audio = try SpeakerGate.loadSamples(from: url)
                TSEMetricsLog.shared.startSession(profile: label)
                let results = try service.evaluateWithRescue(audio: audio, extractor: nil)
                TSEMetricsLog.shared.endSession()
                let display = results.map {
                    GatedSpan(start: $0.start, end: $0.end,
                              verdict: $0.verdictMixed, distance: $0.distanceMixed)
                }
                await MainActor.run {
                    spans = display
                    templateCount = service.templateCount
                    let secs = Double(audio.count) / Double(SpeakerGate.sampleRate)
                    status = String(format: "%@ — %.1fs, %d spans (table in console)",
                                    label, secs, results.count)
                    isWorking = false
                }
            } catch {
                await MainActor.run {
                    status = "Measure failed: \(error)"
                    isWorking = false
                }
            }
        }
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
