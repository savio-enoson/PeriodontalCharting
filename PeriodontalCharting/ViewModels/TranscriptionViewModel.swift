//
//  TranscriptionViewModel.swift
//  transcript
//
//  MVVM view-model: owns WhisperKit, all transcription state, and the business
//  logic for the three input modes. The View (ContentView) only observes and
//  sends intents; it holds no logic or WhisperKit references.
//
//  Batch (file/upload): Silero VAD finds the speech, which is packed into ≤30 s
//  chunks and transcribed — the on-device-efficient shape of app.py's `transcribe()`.
//
//  Live (mic): WhisperKit's AudioStreamTranscriber, which captures the mic, runs
//  VAD + windowing with running context, and fires a state callback (confirmed +
//  unconfirmed segments) as speech arrives — so the transcript updates continuously.
//  (app.py hand-rolls a rolling window only because Gradio has no streaming decoder;
//  on WhisperKit the native streamer avoids the per-window 30 s-pad + overlap dupes.)
//

import Foundation
import Observation
import AVFoundation
import CoreML
import WhisperKit

@MainActor
@Observable
final class TranscriptionViewModel: LiveCaptureDriver {

    // MARK: - Input mode

    enum InputMode: String, CaseIterable, Identifiable {
        case sample = "Sample File"
        case upload = "Upload File"
        case live = "Live Mic"
        var id: String { rawValue }
    }

    // MARK: - Observable state (the View binds to these)

    var inputMode: InputMode = .sample
    var selectedFileURL: URL?

    /// Cleaned, display-ready transcript (updated live while streaming).
    private(set) var transcript: String = ""
    /// Human-readable status line.
    private(set) var statusMessage: String = "Loading model…"
    private(set) var isModelReady: Bool = false
    private(set) var isTranscribing: Bool = false
    private(set) var isRecording: Bool = false

    /// Benchmark readouts (file/upload modes).
    private(set) var benchmarkTime: TimeInterval = 0
    private(set) var rtfValue: Double = 0

    var canTranscribe: Bool {
        isModelReady && !isTranscribing &&
        (inputMode != .upload || selectedFileURL != nil)
    }

    // MARK: - Private

    // The model is shared app-wide and preloaded at launch — see TranscriptionEngine.
    // These just forward to it so all the transcription logic below is unchanged.
    private var whisperKit: WhisperKit? { TranscriptionEngine.shared.whisperKit }
    private var vad: SileroVADEngine? { TranscriptionEngine.shared.vad }

    // Live mic: WhisperKit's native streaming transcriber + the task driving it.
    private var streamTranscriber: AudioStreamTranscriber?
    private var streamTask: Task<Void, Never>?

    // RTF tracking for live mode (debug console only): wall-clock time and
    // confirmed-audio position at the last state update, so we can print how
    // much *new* audio got confirmed per how much wall time actually passed.
    private var lastLiveUpdateTime: Date?
    private var lastLiveConfirmedSeconds: Float = 0

    // Transcript confirmed *before* the current stream transcriber was (re)started.
    // A route/interruption change rebuilds the transcriber (see restartLiveStream),
    // which resets its internal segment state to empty — we stash the text so far
    // here and prepend it, so a Bluetooth blip mid-session doesn't wipe the note.
    private var liveCarryOver = ""

    // MARK: - Live event hooks (for AI Mode)

    /// Fired on every live update with the running display transcript (confirmed +
    /// unconfirmed). AI Mode mirrors this into its panel for immediate feedback.
    var onLiveTranscript: ((String) -> Void)?

    /// Fired ONLY when Whisper confirms a new chunk, with the cumulative confirmed
    /// transcript so far. AI Mode runs the annotation parser off this — so the chart
    /// only updates once a chunk is finalized, never on volatile partial hypotheses
    /// that Whisper may still revise.
    var onConfirmedTranscript: ((String) -> Void)?

    // Confirmed-chunk tracking backing `onConfirmedTranscript`. `count` gates the
    // fire; `cumulative`/`carryOver` mirror liveCarryOver so a mid-session restart
    // doesn't drop already-parsed commands.
    private var lastConfirmedSegmentCount = 0
    private var lastConfirmedCumulative = ""
    private var liveConfirmedCarryOver = ""

    /// WhisperKit decodes a fixed 30 s window; batch speech is packed into chunks
    /// no larger than this so each decode fills the window (not one pass per burst).
    private static let maxChunkSamples = 30 * SileroVADEngine.sampleRate

    /// Concatenate the VAD speech spans (dropping the silence between them) into
    /// chunks of at most `maxLen` samples; bursts longer than `maxLen` are split.
    nonisolated private static func packSpeech(
        _ audio: [Float], _ segments: [SpeechSegment], maxLen: Int
    ) -> [[Float]] {
        var chunks: [[Float]] = []
        var current: [Float] = []
        current.reserveCapacity(maxLen)
        for seg in segments {
            var s = max(0, seg.start)
            let end = min(audio.count, seg.end)
            while s < end {
                let take = min(end - s, maxLen - current.count)
                current.append(contentsOf: audio[s..<s + take])
                s += take
                if current.count >= maxLen {
                    chunks.append(current)
                    current = []
                    current.reserveCapacity(maxLen)
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [audio] : chunks
    }

    // MARK: - Model loading

    /// Reflect the shared, launch-preloaded model into this view-model's observable
    /// state. The heavy lifting lives in `TranscriptionEngine` (loaded once at app
    /// start); this awaits it — returning immediately when it's already warm — and
    /// mirrors its readiness/status so the existing UI bindings keep working.
    func loadModel() async {
        let engine = TranscriptionEngine.shared
        statusMessage = engine.statusMessage
        await engine.load()
        isModelReady = engine.isReady
        statusMessage = engine.statusMessage
    }

    // MARK: - Clinical decoding options

    /// See `ClinicalConfig.decodingOptions(for:)` — centralized there so the
    /// eval harness builds the exact same options this app uses.
    private func clinicalOptions(_ whisper: WhisperKit) -> DecodingOptions {
        ClinicalConfig.decodingOptions(for: whisper.tokenizer)
    }

    // MARK: - Intents

    /// Transcribe the current file/upload selection (batch; one result at the end).
    func transcribeSelection() {
        guard let whisper = whisperKit, inputMode != .live else { return }

        var audioURL: URL?
        var scoped = false
        switch inputMode {
        case .sample:
            audioURL = Bundle.main.url(forResource: "sample", withExtension: "mp3")
            if audioURL == nil {
                statusMessage = "Bundled 'sample.mp3' not found."
                return
            }
        case .upload:
            guard let url = selectedFileURL else {
                statusMessage = "Please select a file first."
                return
            }
            scoped = url.startAccessingSecurityScopedResource()
            guard scoped else {
                statusMessage = "Cannot access the selected file."
                return
            }
            audioURL = url
        case .live:
            return
        }

        guard let url = audioURL else { return }

        isTranscribing = true
        statusMessage = "Transcribing…"
        transcript = ""
        benchmarkTime = 0
        rtfValue = 0

        let vad = self.vad
        Task {
            let start = Date()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let options = clinicalOptions(whisper)

                // Load as a 16 kHz mono float array.
                let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
                let audioDuration = Double(audio.count) / Double(SileroVADEngine.sampleRate)

                // Silero VAD finds the speech, but WhisperKit's encoder ALWAYS runs on
                // a fixed 30 s (480k-sample) window — a 2 s burst still costs a full 30 s
                // pass. So instead of one decode per burst (app.py's shape, which explodes
                // the pass count on-device), we pack the speech back-to-back into ≤30 s
                // chunks: silence is dropped, each chunk fills the window, and a clip
                // needs ~ceil(speech / 30 s) passes instead of one-per-burst.
                let chunks: [[Float]] = await Task.detached {
                    guard let vad else { return [audio] }
                    let ts = vad.speechTimestamps(
                        audio, minSpeechDurationMs: 250, minSilenceDurationMs: 500)
                    guard !ts.isEmpty else { return [audio] }
                    return Self.packSpeech(audio, ts, maxLen: Self.maxChunkSamples)
                }.value

                statusMessage = "Transcribing \(chunks.count) chunk\(chunks.count == 1 ? "" : "s")…"

                let perChunk = await whisper.transcribe(audioArrays: chunks, decodeOptions: options)
                let raw = perChunk
                    .compactMap { $0?.map(\.text).joined(separator: " ") }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")

                let elapsed = Date().timeIntervalSince(start)
                transcript = ClinicalConfig.clean(raw).ifEmpty("No result")
                benchmarkTime = elapsed
                rtfValue = (audioDuration > 0 && elapsed > 0) ? audioDuration / elapsed : 0
                statusMessage = "Done (\(chunks.count) chunk\(chunks.count == 1 ? "" : "s"))"
                isTranscribing = false
                print(String(format: "[RTF] batch: %.1fs audio in %.1fs -> %.2fx realtime (%d chunks)",
                             audioDuration, elapsed, rtfValue, chunks.count))
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
                isTranscribing = false
            }
        }
    }

    // MARK: - Live streaming (mic) — WhisperKit AudioStreamTranscriber

    func toggleRecording() {
        if isRecording { stopLiveTranscription() }
        else { startLiveTranscription() }
    }

    /// State-agnostic start/stop used by callers that drive live mode externally
    /// (AI Mode), where a plain toggle would be ambiguous.
    func startLive() { if !isRecording { startLiveTranscription() } }
    func stopLive()  { if isRecording { stopLiveTranscription() } }

    private func startLiveTranscription() {
        guard let whisper = whisperKit, whisper.tokenizer != nil else {
            statusMessage = "Model not ready."
            return
        }

        transcript = ""
        liveCarryOver = ""
        liveConfirmedCarryOver = ""
        lastConfirmedCumulative = ""
        lastConfirmedSegmentCount = 0
        benchmarkTime = 0
        rtfValue = 0
        isRecording = true
        isTranscribing = true
        statusMessage = "Requesting microphone access…"
        lastLiveUpdateTime = nil
        lastLiveConfirmedSeconds = 0

        // This @MainActor class means a plain `Task {}` here already runs on the
        // main actor — no `MainActor.run` hops needed for state updates below.
        Task { [weak self] in
            guard let self else { return }

            // AudioStreamTranscriber.startStreamTranscription() swallows a denied
            // mic permission internally (logs and returns, never throws), so a
            // failed start would otherwise sit on "Listening…" forever with no
            // explanation. Check explicitly first.
            guard await AudioProcessor.requestRecordPermission() else {
                self.statusMessage = "Microphone access denied — enable it in Settings > Privacy > Microphone."
                self.isRecording = false
                self.isTranscribing = false
                return
            }

            // AudioManager owns the AVAudioSession: it configures/activates it and
            // watches for route/interruption changes, calling restartLiveStream()
            // when the input format shifts (Bluetooth (dis)connect, call/Siri) so
            // WhisperKit's AVAudioConverter never desyncs from the mic buffers and
            // crashes with audioProcessingFailed("Error converting audio: …").
            do {
                try AudioManager.shared.beginLiveCapture(driving: self)
            } catch {
                self.statusMessage = "Audio session error: \(error.localizedDescription)"
                self.isRecording = false
                self.isTranscribing = false
                return
            }

            self.statusMessage = "Listening…"
            self.launchStreamTranscriber()
        }
    }

    /// Build a fresh AudioStreamTranscriber against the *current* audio route and
    /// start it. Split out from `startLiveTranscription` so `restartLiveStream`
    /// (driven by AudioManager on a route/interruption change) can rebuild the
    /// capture graph — and WhisperKit's converter — without re-owning the session.
    private func launchStreamTranscriber() {
        guard let whisper = whisperKit, let tokenizer = whisper.tokenizer else { return }
        let options = clinicalOptions(whisper)

        // AudioStreamTranscriber captures the mic, runs VAD + windowing with running
        // context, and calls back with confirmed + unconfirmed segments as speech
        // arrives. We clean the running transcript on every update so the UI shows
        // live clinical text — no manual buffering, overlap dupes, or per-window pad.
        let transcriber = AudioStreamTranscriber(
            audioEncoder: whisper.audioEncoder,
            featureExtractor: whisper.featureExtractor,
            segmentSeeker: whisper.segmentSeeker,
            textDecoder: whisper.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisper.audioProcessor,
            decodingOptions: options,
            // Bound the live buffer to the most recent 60 s. Without this the
            // streamer keeps every sample of the session and re-processes the
            // whole thing each 100 ms tick — ~46 MB and climbing on a 12-minute
            // charting session, and a long internal silence gets re-fed to the
            // decoder every pass (which is what let the biased-vocabulary runaway
            // reappear repeatedly on the live path). 60 s keeps ample decode
            // context beyond Whisper's 30 s window while capping retained audio.
            maxRetainedAudioSeconds: 60
        ) { [weak self] _, newState in
            // Callback is @Sendable / off the main actor — hop back to update UI state.
            //
            // TranscriptionSegment.text is the RAW per-segment text, including special
            // tokens like <|startoftranscript|> and <|0.00|> — unlike batch mode, which
            // reads TranscriptionResult.text (already filtered by
            // WhisperKit.finalizeTranscriptionResult). Live mode never got that
            // filtering, so those tokens leaked straight into the displayed transcript.
            // Re-decode from each segment's own `tokens`, filtering the same way
            // finalizeTranscriptionResult does, to get clean text here too.
            let specialTokenBegin = tokenizer.specialTokens.specialTokenBegin
            func cleanText(_ segments: [TranscriptionSegment]) -> String {
                segments.map { tokenizer.decode(tokens: $0.tokens.filter { $0 < specialTokenBegin }) }
                    .joined(separator: " ")
            }
            let confirmed = cleanText(newState.confirmedSegments)
            let unconfirmed = cleanText(newState.unconfirmedSegments)
            let raw = (confirmed + " " + unconfirmed).trimmingCharacters(in: .whitespaces)
            let cleaned = ClinicalConfig.clean(raw)
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Prepend anything confirmed before the current transcriber was
                // (re)started so a route change mid-session doesn't drop the note.
                self.transcript = self.liveCarryOver.isEmpty
                    ? cleaned
                    : (self.liveCarryOver + " " + cleaned).trimmingCharacters(in: .whitespaces)
                self.onLiveTranscript?(self.transcript)

                // Confirmed-chunk gate: fire onConfirmedTranscript only when Whisper
                // has finalized a new segment (its confirmed count advanced), passing
                // the cumulative *confirmed* text. Downstream (AI Mode) parses off this
                // so annotations never react to unconfirmed hypotheses.
                if newState.confirmedSegments.count != self.lastConfirmedSegmentCount {
                    self.lastConfirmedSegmentCount = newState.confirmedSegments.count
                    let cleanedConfirmed = ClinicalConfig.clean(confirmed)
                    let confirmedCumulative = self.liveConfirmedCarryOver.isEmpty
                        ? cleanedConfirmed
                        : (self.liveConfirmedCarryOver + " " + cleanedConfirmed).trimmingCharacters(in: .whitespaces)
                    if !confirmedCumulative.isEmpty {
                        self.lastConfirmedCumulative = confirmedCumulative
                        self.onConfirmedTranscript?(confirmedCumulative)
                    }
                }

                // `currentText` is the framework's live status signal ("Waiting for
                // speech...", or interim decode progress) — without this the UI gives
                // zero feedback between "Listening…" and the first *confirmed* segment
                // (2 segments by default), which reads as "not capturing audio" even
                // when the mic and VAD are working correctly.
                if !newState.currentText.isEmpty {
                    self.statusMessage = newState.currentText
                }

                // [RTF] debug logging: how much *new* confirmed audio landed per how
                // much wall-clock time actually passed since the last update. Answers
                // "do I have to wait 30s per chunk" with real numbers instead of a guess.
                let now = Date()
                let confirmedSeconds = newState.lastConfirmedSegmentEndSeconds
                let audioDelta = confirmedSeconds - self.lastLiveConfirmedSeconds
                if let lastTime = self.lastLiveUpdateTime, audioDelta > 0 {
                    let wallDelta = now.timeIntervalSince(lastTime)
                    let rtf = wallDelta > 0 ? Double(audioDelta) / wallDelta : 0
                    print(String(format: "[RTF] live: +%.1fs audio confirmed in %.1fs wall -> %.2fx realtime",
                                 audioDelta, wallDelta, rtf))
                }
                if audioDelta > 0 {
                    self.lastLiveUpdateTime = now
                    self.lastLiveConfirmedSeconds = confirmedSeconds
                }
            }
        }
        streamTranscriber = transcriber

        streamTask = Task { [weak self] in
            do {
                try await transcriber.startStreamTranscription()
            } catch {
                // Don't tear down recording state here: a restart may already be in
                // flight (route/interruption change cancels this task on purpose).
                if !Task.isCancelled {
                    self?.statusMessage = "Live error: \(error.localizedDescription)"
                }
            }
        }
    }

    /// LiveCaptureDriver — AudioManager calls this after it reactivates the session
    /// on a route/interruption change. Rebuild the capture stream so WhisperKit's
    /// AVAudioConverter is recreated against the new hardware format.
    func restartLiveStream() async {
        guard isRecording else { return }
        // Keep what's been transcribed so far; the new transcriber starts empty.
        liveCarryOver = transcript
        // Same for the confirmed-only stream feeding the annotation parser, so a
        // restart mid-dictation doesn't re-emit a shorter transcript and drop
        // already-applied commands.
        liveConfirmedCarryOver = lastConfirmedCumulative
        lastConfirmedSegmentCount = 0
        lastLiveUpdateTime = nil
        lastLiveConfirmedSeconds = 0
        await streamTranscriber?.stopStreamTranscription()
        streamTask?.cancel()
        streamTranscriber = nil
        streamTask = nil
        statusMessage = "Audio route changed — resuming…"
        launchStreamTranscriber()
    }

    private func stopLiveTranscription() {
        Task { [weak self] in
            guard let self else { return }
            await self.streamTranscriber?.stopStreamTranscription()
            self.streamTask?.cancel()
            self.streamTranscriber = nil
            self.streamTask = nil
            // Release session ownership last, after the capture graph is torn down.
            AudioManager.shared.endLiveCapture()
            self.isRecording = false
            self.isTranscribing = false
            self.statusMessage = self.transcript.isEmpty ? "No speech captured" : "Done"
        }
    }
}

// Small convenience used above.
private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
