//
//  SpeakerGateDebugView.swift
//  PeriodontalCharting
//
//  Created by Hans Joachim Wiryonoptutro on 27/07/26.
//
//  Validates the speaker gate on FILES, with no microphone and no STT. That is
//  deliberate — it isolates the gate from Wav2Vec, so a failure here is
//  unambiguously the embedder's.
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

    @State private var captureEnabled = SessionRecorder.isEnabled
    @State private var sessionSeconds: Double?
    @State private var mode = TSEConfig.mode
    @State private var coverage = TSEConfig.coverage
    @ObservedObject private var audio = AudioManager.shared

    var body: some View {
        List {
            sessionCaptureSection

            extractionSection
            
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
                // THE CACHE OUTLIVES A REBUILD, and that is not obvious.
                // `restoreEnrollment` returns early whenever a profile already has
                // cached templates, so changing anything the segmenter does —
                // `minSpeechSeconds`, the live high-pass, the auto-gain — leaves
                // the OLD templates in place until someone re-records calibration.
                // This rebuilds them from the takes already on disk, no recording.
                Button("Re-enroll from existing takes") { reenroll() }
                    .disabled(isWorking)

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
        .task {
            initializeIfNeeded()
            sessionSeconds = SessionRecorder.recordedSeconds()
        }
    }

    // MARK: - Extraction

    // Live switches, persisted. These take effect on the NEXT dictation session —
    // an in-flight one has already captured the mode it started with.
    @ViewBuilder
    private var extractionSection: some View {
        Section("Extraction") {
            Picker("Mode", selection: $mode) {
                ForEach(TSEConfig.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: mode) { _, new in TSEConfig.mode = new }

            Picker("Coverage", selection: $coverage) {
                ForEach(TSEConfig.Coverage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: coverage) { _, new in TSEConfig.coverage = new }

            Text(modeExplanation)
                .font(.caption2).foregroundStyle(.secondary)

            Text("Per-span decisions go to the console as [Gate], [TSE] and "
                 + "[TSE/cover]. Live dictation gates through Wav2VecViewModel; "
                 + "this view is the file harness.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var modeExplanation: String {
        switch mode {
        case .off:
            return "Extractor never runs. Every voice in the room is transcribed."
        case .observe:
            return "Extractor runs and logs, but Wav2Vec receives the ORIGINAL audio. "
                 + "The counterfactual, at full cost, with no risk."
        case .extractOnly:
            return "Wav2Vec receives extracted audio, and NOTHING is silenced. Separation "
                 + "is the only mechanism. Rejects are still measured and named in the "
                 + "console — check the transcript for their words."
        case .enforce:
            return "Wav2Vec receives extracted audio, rejected spans are silenced, and an "
                 + "all-rejected chunk is withheld."
        }
    }

    // MARK: - Session capture

    // The A/B that answers the coverage question by ear. Play raw, then gated: if
    // extraction is hurting Wav2Vec you hear it as warbling and dropped
    // consonants long before WER would show it.
    @ViewBuilder
    private var sessionCaptureSection: some View {
        Section("Session capture") {
            Toggle("Record dictation sessions", isOn: $captureEnabled)
                .onChange(of: captureEnabled) { _, on in SessionRecorder.isEnabled = on }

            Text("DEBUG ONLY. Writes the last session as two sample-aligned WAVs — "
                 + "what the mic heard and what Wav2Vec was given. A session records "
                 + "whatever was said in the room, so leave this off around patients. "
                 + "Each session overwrites the previous one.")
                .font(.caption2).foregroundStyle(.secondary)

            if let seconds = sessionSeconds {
                LabeledContent("Last session", value: String(format: "%.1f s", seconds))

                ForEach(SessionRecorder.Track.allCases, id: \.self) { track in
                    Button {
                        playbackToggle(track)
                    } label: {
                        Label(track.title,
                              systemImage: isPlaying(track) ? "stop.fill" : "play.fill")
                    }
                }

                // The point of keeping the file: re-judge the exact audio that
                // misbehaved, as many times as needed, against whatever the config
                // says today. No microphone, no second clinician, no luck.
                Button("Re-run live gate on this session") { rerunOnSession() }
                    .disabled(isWorking || !(service?.isEnrolled ?? false))

                Button("Delete session recording", role: .destructive) {
                    audio.stopPlaying()
                    SessionRecorder.shared.deleteLastSession()
                    sessionSeconds = nil
                }
            } else {
                Text("No session recorded yet.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func isPlaying(_ track: SessionRecorder.Track) -> Bool {
        audio.isPlaying && audio.playingFilename == track.rawValue
    }

    private func playbackToggle(_ track: SessionRecorder.Track) {
        if isPlaying(track) {
            audio.stopPlaying()
        } else {
            audio.stopPlaying()          // switching tracks mid-play
            audio.playRecording(filename: track.relativePath)
        }
    }

    // Replays the session through `gatedAudio` — the SAME call the live path
    // makes, extractor included — so the console fills with the identical
    // [Gate]/[TSE]/[TSE/cover] lines the session produced, at current settings.
    private func rerunOnSession() {
        guard let service else { return }
        isWorking = true
        status = "Re-running the gate on the last session…"
        let url = SessionRecorder.url(for: .raw)
        let extractor = TSEEngine.shared.extractor

        Task.detached {
            do {
                // Raw, NOT loadSamples — see SessionRecorder.loadRaw. Replaying
                // through the calibration loader would add a high-pass and auto-gain
                // the live session never had, and the re-run would stop reproducing
                // the log it exists to reproduce.
                let audio = try SessionRecorder.loadRaw(url)
                let result = try service.gatedAudio(for: audio, extractor: extractor)
                let mapped = result.spans.map {
                    GatedSpan(start: $0.start, end: $0.end,
                              verdict: $0.effectiveVerdict,
                              distance: $0.distanceSeparated ?? $0.distanceMixed)
                }
                await MainActor.run {
                    spans = mapped
                    let secs = Double(audio.count) / Double(SpeakerGate.sampleRate)
                    status = result.judged
                        ? String(format: "Session re-run — %.1fs, %d span(s), coverage %@",
                                 secs, mapped.count, TSEConfig.coverage.rawValue)
                        : String(format: "Session re-run — %.1fs, nothing judgeable", secs)
                    isWorking = false
                }
            } catch {
                await MainActor.run {
                    status = "Re-run failed: \(error)"
                    isWorking = false
                }
            }
        }
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
                        maxPerFile: SpeakerGate.maxTemplates))
                .flatMap { try? service.enroll(utterances: $0) } ?? 0
            await MainActor.run {
                templateCount = service.templateCount
                status = n > 0 ? "Enrolled \(n) template(s)" : "No usable speech in calibration"
                isWorking = false
            }
        }
    }

    // Rebuild the centroid from the calibration takes already recorded, and
    // re-cache it. Also re-conditions the extractor, whose enroll_kv comes from
    // the same takes and is just as stale.
    private func reenroll() {
        isWorking = true
        status = "Re-enrolling from the takes on disk…"
        Task {
            let result = await TranscriptionEngine.shared.enrollFromCalibration(
                reset: true, waitForFile: false)
            await TSEEngine.shared.reprepare()
            templateCount = service?.templateCount ?? 0
            status = result.templates > 0
                ? String(format: "Re-enrolled %d template(s) from %d take(s), %.1fs",
                         result.templates, result.takes, result.seconds)
                : "Re-enrollment produced no templates — check the takes"
            isWorking = false
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
