//
//  TranscriptionViewModel.swift
//  transcript
//
//  MVVM view-model: owns WhisperKit, all live-transcription state, and the
//  business logic for live mic dictation. The View only observes and sends
//  intents; it holds no logic or WhisperKit references.
//
//  Live (mic): WhisperKit's AudioStreamTranscriber, which captures the mic, runs
//  VAD + windowing with running context, and fires a state callback (confirmed +
//  unconfirmed segments) as speech arrives — so the transcript updates continuously.
//

import Foundation
import Observation
import AVFoundation
import CoreML
import WhisperKit

@MainActor
@Observable
final class TranscriptionViewModel: LiveCaptureDriver {

    // MARK: - Observable state (the View binds to these)

    /// Cleaned, display-ready transcript (updated live while streaming).
    private(set) var transcript: String = ""
    /// Human-readable status line.
    private(set) var statusMessage: String = "Loading model…"
    private(set) var isModelReady: Bool = false
    private(set) var isTranscribing: Bool = false
    private(set) var isRecording: Bool = false

    // MARK: - Private

    // The model is shared app-wide and preloaded at launch — see TranscriptionEngine.
    // These just forward to it so all the transcription logic below is unchanged.
    private var whisperKit: WhisperKit? { TranscriptionEngine.shared.whisperKit }

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
            // Keep a 2-segment UNCONFIRMED (revisable) tail DURING speech: unclear
            // audio commits with full following context, so it's accurate — Whisper
            // keeps refining the last segments, and freezing early (tried 1/0) fed
            // rougher text on unclear audio. The de-ghost lag this normally costs is
            // reclaimed by Tier 3b below: `finalizeOnSilence` confirms the current
            // utterance the instant VAD hits a pause, so each tooth's values solidify
            // at the gap before the next one — accurate mid-phrase, snappy at pauses.
            // Measured decode headroom is 10–50× realtime, so this costs nothing.
            // See STT_ISSUES.md #2/#6 for the full latency-vs-accuracy history.
            requiredSegmentsForConfirmation: 1,
            // [LATENCY Tier 1] Bound the live buffer. The streamer re-decodes the
            // ENTIRE retained buffer every ~100 ms tick, so 60 s = two full 30 s
            // Whisper windows decoded per tick. 32 s keeps a full 30 s window (+
            // margin) while ~halving per-tick decode cost, and retains less silence
            // (which is what fed the biased-vocabulary runaway) — strictly safer.
            // Do NOT drop below ~30 s: that truncates Whisper's own decode window.
            maxRetainedAudioSeconds: 32,
            // [LATENCY Tier 3b] Commit on silence. VAD is already on (default); this
            // finalizes the pending tail at each detected pause so a charting burst
            // solidifies the moment the clinician stops, without lowering the mid-
            // speech confirmation buffer. Reclaims the de-ghost lag that keeping    
            // requiredSegmentsForConfirmation at 2 would otherwise cost.
            finalizeOnSilence: true
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
                    // [STT diag] The exact confirmed text that feeds the chart, before
                    // and after ClinicalConfig.clean. `raw` is what Whisper actually
                    // heard (pre-phraseFix); `clean` is what the parser sees. Diff the
                    // two to catch mishears clean MISSED (e.g. a "di bop" variant that
                    // slips the repair regex) vs. ones it fixed. Grep `[STT]`.
                    print("[STT] raw:   \(confirmed)")
                    print("[STT] clean: \(cleanedConfirmed)")
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
