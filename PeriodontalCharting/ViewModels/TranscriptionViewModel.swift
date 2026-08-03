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
    /// Speaker gate. When set and enrolled, confirmed Whisper segments whose time
    /// range falls in a REJECTED span are withheld from the parser.
    var speakerGate: SpeakerGateService?

    // MARK: - Speaker filter status
    //
    // Surfaced in AI Mode and the Transcribe sheet rather than a debug view. A
    // filter that runs invisibly is indistinguishable from Whisper simply missing
    // words — the clinician has to be able to see that numbers were withheld, or
    // they will read a silent gate as a broken microphone.
    struct GateStatus {
        var active = false
        var extractorReady = false
        var spans = 0
        var rejected = 0
        var routed = 0
        var rescued = 0
        var withheldSegments = 0
        var lastDistance: Double?

        var summary: String {
            guard active else { return "Speaker filter off" }
            var parts = ["\(spans) span\(spans == 1 ? "" : "s")"]
            if rejected > 0 { parts.append("\(rejected) not you") }
            if withheldSegments > 0 {
                parts.append("\(withheldSegments) line\(withheldSegments == 1 ? "" : "s") withheld")
            }
            if routed > 0 { parts.append("\(rescued)/\(routed) rescued") }
            return parts.joined(separator: " · ")
        }
    }
    private(set) var gateStatus = GateStatus()

    @ObservationIgnored private var gateMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var liveStreamStart: Date?
    @ObservationIgnored private var lastGatedAbsoluteSeconds: Double = 0

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

            // The gate was dead code: `speakerGate` was read by the segment filter
            // and assigned nowhere, so `gate.isEnrolled` failed and everything
            // passed. This is the assignment that turns it on — for AI Mode and the
            // Transcribe sheet alike, since both drive this same view model.
            //
            // ORDER MATTERS: `launchStreamTranscriber` captures the gate into its
            // @Sendable callback, so assigning it afterwards would capture nil and
            // filter nothing.
            self.speakerGate = TranscriptionEngine.shared.makeSpeakerGateIfNeeded()
            self.startGateMonitor()

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

        // Captured once, here on the main actor. SpeakerGateService is @unchecked
        // Sendable and isTargetSpeaking is lock-guarded, so the streaming callback
        // can consult it directly without hopping.
        let gate = (speakerGate?.isEnrolled == true) ? speakerGate : nil

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

            // Gate BOTH streams, not just the confirmed one. The displayed
            // transcript and AI Mode's chart PREVIEW are both built from
            // confirmed + unconfirmed (`onLiveTranscript` -> `ingestPreview` ->
            // `commandHistory`), so filtering only the confirmed path let another
            // speaker's numbers land on the chart as ghosted values and stay there.
            //
            // Segment timestamps are ABSOLUTE stream time — AudioStreamTranscriber's
            // `offsetSegments` adds its buffer origin before this callback fires —
            // which is the same base the gate timeline uses.
            func passesGate(_ segment: TranscriptionSegment) -> Bool {
                guard let gate else { return true }
                return gate.isTargetSpeaking(atSeconds: Double((segment.start + segment.end) / 2))
            }
            let gatedConfirmed = newState.confirmedSegments.filter(passesGate)
            let gatedUnconfirmed = newState.unconfirmedSegments.filter(passesGate)

            let confirmed = cleanText(gatedConfirmed)
            let unconfirmed = cleanText(gatedUnconfirmed)
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
                    if gate != nil {
                        // confirmedSegments is CUMULATIVE, so this difference is
                        // already a running total — assigning, not adding, is what
                        // keeps it from counting the same withheld line every tick.
                        self.gateStatus.withheldSegments =
                            newState.confirmedSegments.count - gatedConfirmed.count
                    }

                    // Three failure modes look identical from the transcript:
                    // no span covers the time (fail open), a span covered it and
                    // said accept (centroid too weak), or it was withheld and
                    // something else is re-adding the text. Name which one.
                    for segment in newState.confirmedSegments.suffix(3) {
                        let mid = Double((segment.start + segment.end) / 2)
                        if let span = gate?.coveringSpan(atSeconds: mid) {
                            print(String(format: "[Gate/seg] %.2fs covered by %.2f–%.2f %@ (d %@) -> %@",
                                         mid, span.startSeconds, span.endSeconds,
                                         span.verdict.rawValue,
                                         span.distance.map { String(format: "%.3f", $0) } ?? "-",
                                         span.passesGate ? "PASS" : "WITHHELD"))
                        } else {
                            print(String(format: "[Gate/seg] %.2fs NO SPAN COVERS -> PASS (fail open)", mid))
                        }
                    }

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
        gateMonitorTask?.cancel()
        gateMonitorTask = nil
        liveStreamStart = nil

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

    // MARK: - Live speaker gate

    /// Poll WhisperKit's retained buffer and gate only the audio that is new.
    ///
    /// POLLING, not a tap: `AudioStreamTranscriber` claims
    /// `audioProcessor.audioBufferCallback` for itself, so setting it here breaks
    /// the streamer.
    ///
    /// TIME BASE: `audioSamples` is trimmed from the FRONT at 32 s and its origin
    /// (`bufferOriginSeconds`) is private, while the segment timestamps reaching
    /// the callback are already ABSOLUTE — `offsetSegments` adds that origin
    /// before we see them. Absolute stream time is therefore reconstructed from
    /// the wall clock: a live mic produces samples in real time, so
    /// `now - streamStart` is the stream time of the buffer's last sample. Error
    /// is scheduling jitter — tens of ms against spans of 1–6 s.
    ///
    /// FAILS OPEN: `isTargetSpeaking(atSeconds:)` returns true when no span covers
    /// a timestamp, and the gate always lags by up to one cadence interval.
    /// Failing closed there would drop text systematically, not occasionally.
    private func startGateMonitor() {
        gateStatus = GateStatus()
        guard let gate = speakerGate, gate.isEnrolled else {
            print("[Gate/live] not enrolled — every segment passes")
            return
        }
        let extractor = TSEEngine.shared.extractor
        gateStatus.active = true
        gateStatus.extractorReady = extractor?.isPrepared == true
        if TSEConfig.mode != .off && !gateStatus.extractorReady {
            print("[TSE/live] extractor unavailable — gate runs alone")
        }

        // Anchored lazily on the first non-empty buffer, NOT here: WhisperKit's
        // startRecordingLive clears audioSamples and begins capture a few hundred
        // ms after this call, and its segment timestamps are relative to buffer[0].
        // Anchoring here would bake that setup delay in as a constant offset.
        liveStreamStart = nil
        lastGatedAbsoluteSeconds = 0
        gateMonitorTask?.cancel()
        gateMonitorTask = Task { [weak self] in
            let sr = Double(SpeakerGate.sampleRate)
            // Re-read this much already-gated audio each pass so an utterance
            // crossing a window boundary is still seen whole.
            let overlapSeconds = 2.5
            // Do not judge less than this at once — mergeSpans drops sub-1 s spans
            // and the embedder wants 3 s, so short windows produce weak or absent
            // verdicts, which fail open.
            let minWindowSeconds = 4.0

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                // `continue`, not `return`: a transient gap — restartLiveStream
                // rebuilding the capture graph on a route change — must not kill
                // gating for the rest of the session. stopLiveTranscription
                // cancels this task explicitly, so exiting here is never needed.
                guard self.isRecording, let whisper = self.whisperKit else { continue }

                let buffer = Array(whisper.audioProcessor.audioSamples)
                guard !buffer.isEmpty else { continue }

                if self.liveStreamStart == nil {
                    self.liveStreamStart = Date().addingTimeInterval(-Double(buffer.count) / sr)
                }
                guard let streamStart = self.liveStreamStart else { continue }

                let absoluteEnd = Date().timeIntervalSince(streamStart)
                let origin = max(0, absoluteEnd - Double(buffer.count) / sr)
                let from = max(origin, self.lastGatedAbsoluteSeconds - overlapSeconds)
                guard absoluteEnd - from >= minWindowSeconds else { continue }

                let startIndex = Int((from - origin) * sr)
                guard startIndex >= 0, startIndex < buffer.count else { continue }
                let slice = Array(buffer[startIndex...])

                let results = await Task.detached(priority: .utility) {
                    (try? gate.appendEvaluation(audio: slice,
                                                absoluteOffsetSeconds: from,
                                                extractor: extractor)) ?? []
                }.value
                self.applyGateResults(results)
                self.lastGatedAbsoluteSeconds = absoluteEnd
            }
        }
    }

    private func applyGateResults(_ results: [RescuedSpan]) {
        guard !results.isEmpty else { return }
        // Windows overlap, so these describe the LAST pass rather than the session.
        gateStatus.spans = results.count
        gateStatus.rejected = results.filter { $0.verdictMixed == .reject }.count
        gateStatus.routed = results.filter(\.routed).count
        gateStatus.rescued = results.filter(\.rescued).count
        gateStatus.lastDistance = results.last?.distanceMixed
    }
}
