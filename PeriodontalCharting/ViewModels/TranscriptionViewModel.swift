//
//  TranscriptionViewModel.swift
//  transcript
//
//  MVVM view-model: owns WhisperKit, all live-transcription state, and the
//  business logic for live mic dictation. The View only observes and sends
//  intents; it holds no logic or WhisperKit references.
//
//  THREE OUTPUT STREAMS, and the difference between them is the buffer:
//
//      onLiveTranscript       matched + pending    what the clinician READS
//      onVerifiedTranscript   matched only         what reaches the CHART
//      onConfirmedTranscript  matched + confirmed  what renders SOLID vs ghosted
//
//  Unjudged text shows immediately so the system never looks dead, but it cannot
//  put a number on a tooth until the gate has said whose voice it was. Held text
//  is RELEASED once a verdict arrives — `nearestSpan` is re-evaluated on every
//  callback — so nothing is lost, only delayed.
//
//  TWO LAYERS OF DEFENCE. `GatedAudioProcessor` silences the wrong speaker in the
//  AUDIO, before Whisper hears it; the three streams above filter the TEXT after.
//  The audio layer keeps Whisper's running context clean; the text layer catches
//  anything the audio layer had no verdict for.
//
//  GATE-ONLY MODE (-GateOnlyMode YES): WhisperKit is not loaded at all.
//  `GateOnlyCapture` owns the microphone; launch drops from ~187 s to ~2 s.
//
//  STOPPING FINISHES ITS WORK. See `stopLiveTranscription`.
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

    /// Cleaned, display-ready transcript. Includes segments the gate has not
    /// judged yet — those show but do not reach the chart.
    private(set) var transcript: String = ""
    /// Human-readable status line.
    private(set) var statusMessage: String = "Loading model…"
    private(set) var isModelReady: Bool = false
    /// True until the final decode and the final gate pass have both landed —
    /// stays true for a moment after `isRecording` goes false.
    private(set) var isTranscribing: Bool = false
    private(set) var isRecording: Bool = false

    // MARK: - Private

    // The model is shared app-wide and preloaded at launch — see TranscriptionEngine.
    private var whisperKit: WhisperKit? { TranscriptionEngine.shared.whisperKit }

    // Live mic: WhisperKit's native streaming transcriber + the task driving it.
    private var streamTranscriber: AudioStreamTranscriber?
    private var streamTask: Task<Void, Never>?

    /// Gain + speaker gating upstream of Whisper. When present it also fills the
    /// gate timeline itself, so `startGateMonitor` skips its polling loop.
    @ObservationIgnored private var gatedProcessor: GatedAudioProcessor?

    /// Set only in gate-only mode, where WhisperKit is not loaded and something
    /// still has to own the microphone for the gate to have audio to judge.
    @ObservationIgnored private var gateOnlyCapture: GateOnlyCapture?

    // RTF tracking for live mode (debug console only).
    private var lastLiveUpdateTime: Date?
    private var lastLiveConfirmedSeconds: Float = 0

    /// Display text confirmed BEFORE the current transcriber was (re)started. A
    /// route change rebuilds the transcriber, which resets its segment state to
    /// empty, so this is prepended to keep the note intact.
    private var liveCarryOver = ""
    /// VERIFIED text from before the restart. Kept separate from `liveCarryOver`,
    /// which includes unjudged segments — freezing those into the chart's feed
    /// would make them permanent, because nothing ever re-filters a carry-over.
    private var verifiedCarryOver = ""
    /// Last verified text sent to the chart. AI Mode flushes from THIS at stop,
    /// never from `transcript`.
    @ObservationIgnored private(set) var lastVerifiedText = ""

    // MARK: - Live event hooks (for AI Mode)

    /// Running display transcript: matched + pending, everything except the other
    /// speaker. AI Mode mirrors this into its panel for immediate feedback.
    var onLiveTranscript: ((String) -> Void)?

    /// Text the gate has CONFIRMED came from the enrolled clinician. THIS drives
    /// the chart. Unjudged text is deliberately absent.
    var onVerifiedTranscript: ((String) -> Void)?

    /// Fired when Whisper confirms a new chunk, with the cumulative verified-and-
    /// confirmed text. Drives the solid-vs-ghosted distinction on the chart.
    var onConfirmedTranscript: ((String) -> Void)?

    private var lastConfirmedSegmentCount = 0
    private var lastConfirmedCumulative = ""
    private var liveConfirmedCarryOver = ""
    /// Speaker gate. ENFORCING — see `speakerVerdict` in the stream callback.
    var speakerGate: SpeakerGateService?

    // MARK: - Speaker filter status

    struct GateStatus {
        var active = false
        var extractorReady = false
        var spans = 0
        var rejected = 0
        var routed = 0
        var rescued = 0
        /// Segments dropped as somebody else.
        var withheldSegments = 0
        /// Segments waiting on a verdict. Not withheld — just not on the chart
        /// yet. A count that climbs and never clears means the gate has stalled.
        var heldSegments = 0
        var lastDistance: Double?

        var summary: String {
            guard active else { return "Speaker filter off" }
            var parts = ["\(spans) span\(spans == 1 ? "" : "s")"]
            if rejected > 0 { parts.append("\(rejected) not you") }
            if withheldSegments > 0 {
                parts.append("\(withheldSegments) line\(withheldSegments == 1 ? "" : "s") withheld")
            }
            if heldSegments > 0 { parts.append("\(heldSegments) pending") }
            if routed > 0 { parts.append("\(rescued)/\(routed) rescued") }
            return parts.joined(separator: " · ")
        }
    }
    private(set) var gateStatus = GateStatus()

    @ObservationIgnored private var gateMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var liveStreamStart: Date?
    @ObservationIgnored private var lastGatedAbsoluteSeconds: Double = 0
    /// Every span judged this session, for the summary printed at stop. Keyed by
    /// start sample because overlapping windows re-judge the same span.
    @ObservationIgnored private var sessionSpans: [Int: RescuedSpan] = [:]

    /// WhisperKit decodes a fixed 30 s window; batch speech is packed into chunks
    /// no larger than this so each decode fills the window.
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

    func loadModel() async {
        let engine = TranscriptionEngine.shared
        statusMessage = engine.statusMessage
        await engine.load()
        isModelReady = engine.isReady
        statusMessage = engine.statusMessage
    }

    // MARK: - Clinical decoding options

    private func clinicalOptions(_ whisper: WhisperKit) -> DecodingOptions {
        ClinicalConfig.decodingOptions(for: whisper.tokenizer)
    }

    // MARK: - Live streaming (mic) — WhisperKit AudioStreamTranscriber

    func toggleRecording() {
        if isRecording { Task { await stopLiveTranscription() } }
        else { startLiveTranscription() }
    }

    /// State-agnostic start/stop used by callers that drive live mode externally
    /// (AI Mode), where a plain toggle would be ambiguous.
    func startLive() { if !isRecording { startLiveTranscription() } }

    /// Stop, and WAIT for the final decode and the final gate pass to land.
    ///
    /// AWAITABLE ON PURPOSE. AI Mode must not disconnect its callbacks or run its
    /// final parse until this returns. It used to call a fire-and-forget stop and
    /// then nil the callbacks immediately, so the last decode's result fired into
    /// nothing and the chart was committed from text one decode out of date.
    func stopLive() async { if isRecording { await stopLiveTranscription() } }

    private func startLiveTranscription() {
        // Gate-only mode has no WhisperKit and no tokenizer by design.
        let gateOnly = TranscriptionEngine.shared.isGateOnly
        guard gateOnly || (whisperKit != nil && whisperKit?.tokenizer != nil) else {
            statusMessage = "Model not ready."
            return
        }

        transcript = ""
        liveCarryOver = ""
        verifiedCarryOver = ""
        lastVerifiedText = ""
        liveConfirmedCarryOver = ""
        lastConfirmedCumulative = ""
        lastConfirmedSegmentCount = 0
        isRecording = true
        isTranscribing = true
        statusMessage = "Requesting microphone access…"
        lastLiveUpdateTime = nil
        lastLiveConfirmedSeconds = 0
        WhisperStageTimer.shared.reset()

        Task { [weak self] in
            guard let self else { return }

            // AudioStreamTranscriber.startStreamTranscription() swallows a denied
            // mic permission internally (logs and returns, never throws), so a
            // failed start would otherwise sit on "Listening…" forever.
            guard await AudioProcessor.requestRecordPermission() else {
                self.statusMessage = "Microphone access denied — enable it in Settings > Privacy > Microphone."
                self.isRecording = false
                self.isTranscribing = false
                return
            }

            // AudioManager owns the AVAudioSession and watches for route/interruption
            // changes, calling restartLiveStream() when the input format shifts.
            do {
                try AudioManager.shared.beginLiveCapture(driving: self)
            } catch {
                self.statusMessage = "Audio session error: \(error.localizedDescription)"
                self.isRecording = false
                self.isTranscribing = false
                return
            }

            // ORDER MATTERS: `launchStreamTranscriber` captures the gate into its
            // @Sendable callback, so assigning it afterwards would capture nil.
            self.speakerGate = TranscriptionEngine.shared.makeSpeakerGateIfNeeded()

            // Reset the timeline HERE, before anything can write to it. Stream time
            // restarts at 0 every session, so last session's spans sit on top of
            // this one's timestamps — and a stale span also BLOCKS the new verdict,
            // because overlapping ranges are not re-judged. Doing this inside
            // startGateMonitor would race the audio wrapper, which begins judging
            // the moment the transcriber starts.
            self.speakerGate?.resetTimeline()

            if gateOnly {
                do {
                    let capture = GateOnlyCapture()
                    try capture.start()
                    self.gateOnlyCapture = capture
                    self.statusMessage = "Listening (gate only — no transcription)…"
                } catch {
                    self.statusMessage = "Mic error: \(error.localizedDescription)"
                    self.isRecording = false
                    self.isTranscribing = false
                    return
                }
                self.startGateMonitor()
                return
            }

            self.statusMessage = "Listening…"
            // Creates `gatedProcessor`, so the monitor below can see whether the
            // audio path is already doing the judging.
            self.launchStreamTranscriber()
            self.startGateMonitor()
        }
    }

    /// Build a fresh AudioStreamTranscriber against the *current* audio route and
    /// start it. Split out so `restartLiveStream` can rebuild the capture graph —
    /// and WhisperKit's converter — without re-owning the session.
    private func launchStreamTranscriber() {
        guard let whisper = whisperKit, let tokenizer = whisper.tokenizer else { return }
        let options = clinicalOptions(whisper)

        // Captured once, here on the main actor. SpeakerGateService is @unchecked
        // Sendable and its timeline is lock-guarded.
        let gate = (speakerGate?.isEnrolled == true) ? speakerGate : nil

        // Gain-correct and speaker-gate the audio BEFORE Whisper hears it. Only
        // when the gate is actually enrolled — with no centroid there is nothing to
        // judge against and the wrapper would be pure overhead.
        let gated: GatedAudioProcessor? = gate.map { GatedAudioProcessor(gate: $0) }
        gatedProcessor = gated

        let transcriber = AudioStreamTranscriber(
            // Pass-through decorators that time the two FIXED per-window costs.
            // Every decode window is zero-padded to 30 s BEFORE the mel and the
            // encoder run, so neither shrinks when less new audio arrived.
            audioEncoder: TimedAudioEncoder(whisper.audioEncoder),
            featureExtractor: TimedFeatureExtractor(whisper.featureExtractor),
            segmentSeeker: whisper.segmentSeeker,
            textDecoder: whisper.textDecoder,
            tokenizer: tokenizer,
            // The wrapper when the gate is armed, the real processor otherwise.
            audioProcessor: gated ?? whisper.audioProcessor,
            decodingOptions: options,
            // Keep a revisable tail DURING speech: unclear audio commits with full
            // following context. `finalizeOnSilence` reclaims the de-ghost lag by
            // confirming the current utterance the instant VAD hits a pause.
            requiredSegmentsForConfirmation: 1,
            // [LATENCY Tier 1] Bound the live buffer. The streamer re-decodes the
            // retained buffer every ~100 ms tick, so 60 s = two full 30 s windows
            // per tick. 32 s keeps a full window plus margin and retains less
            // silence. Do NOT drop below ~30 s: that truncates the decode window.
            maxRetainedAudioSeconds: 32,
            // [LATENCY Tier 3b] Commit on silence, so a charting burst solidifies
            // the moment the clinician stops.
            finalizeOnSilence: true
        ) { [weak self] _, newState in
            // Callback is @Sendable / off the main actor — hop back to update UI.
            //
            // TranscriptionSegment.text is the RAW per-segment text, including
            // special tokens. Re-decode from each segment's own `tokens`, filtering
            // the same way finalizeTranscriptionResult does.
            let specialTokenBegin = tokenizer.specialTokens.specialTokenBegin
            func cleanText(_ segments: [TranscriptionSegment]) -> String {
                segments.map { tokenizer.decode(tokens: $0.tokens.filter { $0 < specialTokenBegin }) }
                    .joined(separator: " ")
            }

            /// THREE-WAY, not two. `pending` is the buffer: text the gate has not
            /// reached yet. It shows in the transcript so the clinician can see the
            /// system is listening, but it never reaches a tooth — and it is
            /// released the moment a verdict arrives, because this runs again on
            /// every callback.
            ///
            /// `nearestSpan`, not `coveringSpan`: energy segmentation leaves gaps
            /// and Whisper produces text inside them. Inheriting the nearest
            /// verdict within 1.5 s means a gap during the other speaker is
            /// withheld too, while a gap mid-dictation still passes.
            func speakerVerdict(_ segment: TranscriptionSegment) -> SpeakerVerdict {
                // No gate at all (not enrolled) = old ungated behaviour.
                guard let gate else { return .matched }
                let mid = Double((segment.start + segment.end) / 2)
                guard let span = gate.nearestSpan(toSeconds: mid) else { return .pending }
                return span.speakerVerdict
            }

            let confirmedJudged   = newState.confirmedSegments.map   { ($0, speakerVerdict($0)) }
            let unconfirmedJudged = newState.unconfirmedSegments.map { ($0, speakerVerdict($0)) }

            // What the clinician READS: everything except the other speaker.
            let displayConfirmed   = confirmedJudged.filter   { $0.1 != .notMatched }.map(\.0)
            let displayUnconfirmed = unconfirmedJudged.filter { $0.1 != .notMatched }.map(\.0)

            // What reaches the CHART: verified only. `pending` waits here — this is
            // the buffer, and it is the whole point of the three-state verdict.
            let verifiedConfirmed   = confirmedJudged.filter   { $0.1 == .matched }.map(\.0)
            let verifiedUnconfirmed = unconfirmedJudged.filter { $0.1 == .matched }.map(\.0)

            let confirmed   = cleanText(displayConfirmed)
            let unconfirmed = cleanText(displayUnconfirmed)
            let raw = (confirmed + " " + unconfirmed).trimmingCharacters(in: .whitespaces)
            let cleaned = ClinicalConfig.clean(raw)

            let verifiedCleaned = ClinicalConfig.clean(
                (cleanText(verifiedConfirmed) + " " + cleanText(verifiedUnconfirmed))
                    .trimmingCharacters(in: .whitespaces))
            let verifiedConfirmedOnly = ClinicalConfig.clean(cleanText(verifiedConfirmed))
            let heldCount     = confirmedJudged.filter { $0.1 == .pending    }.count
            let withheldCount = confirmedJudged.filter { $0.1 == .notMatched }.count

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.transcript = self.liveCarryOver.isEmpty
                    ? cleaned
                    : (self.liveCarryOver + " " + cleaned).trimmingCharacters(in: .whitespaces)
                self.onLiveTranscript?(self.transcript)

                // CHART FEED — the buffer taking effect. Verified only, with its
                // OWN carry-over so a route change cannot freeze unjudged text in.
                let verifiedFull = self.verifiedCarryOver.isEmpty
                    ? verifiedCleaned
                    : (self.verifiedCarryOver + " " + verifiedCleaned)
                        .trimmingCharacters(in: .whitespaces)
                self.lastVerifiedText = verifiedFull
                self.onVerifiedTranscript?(verifiedFull)
                self.gateStatus.heldSegments = heldCount

                // Fire onConfirmedTranscript only when Whisper has finalized a new
                // segment, passing the cumulative verified-and-confirmed text.
                if newState.confirmedSegments.count != self.lastConfirmedSegmentCount {
                    self.lastConfirmedSegmentCount = newState.confirmedSegments.count

                    // Three cases look identical from the transcript: no verdict
                    // nearby, one that passed, or one that withheld. Name which.
                    for segment in newState.confirmedSegments.suffix(3) {
                        let mid = Double((segment.start + segment.end) / 2)
                        if let span = gate?.nearestSpan(toSeconds: mid) {
                            print(String(format: "[Gate/seg] %.2fs -> %.2f–%.2f %@%@ (d %@) -> %@",
                                         mid, span.startSeconds, span.endSeconds,
                                         span.verdict.rawValue,
                                         span.fromFallback ? " (blind)" : "",
                                         span.distance.map { String(format: "%.3f", $0) } ?? "-",
                                         String(describing: span.speakerVerdict)))
                        } else {
                            print(String(format: "[Gate/seg] %.2fs NO VERDICT WITHIN 1.5s -> pending "
                                         + "(shows in transcript, held off the chart)", mid))
                        }
                    }
                    self.gateStatus.withheldSegments = withheldCount

                    let cleanedConfirmed = verifiedConfirmedOnly
                    // [STT diag] What Whisper heard vs what the parser sees.
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

                // `currentText` is the framework's live status signal. Suppressed
                // once stopping has begun, so it cannot overwrite "Finishing up…".
                if !newState.currentText.isEmpty, self.isRecording {
                    self.statusMessage = newState.currentText
                }

                // [RTF] how much *new* confirmed audio landed per wall-clock second.
                let now = Date()
                let confirmedSeconds = newState.lastConfirmedSegmentEndSeconds
                let audioDelta = confirmedSeconds - self.lastLiveConfirmedSeconds
                if let lastTime = self.lastLiveUpdateTime, audioDelta > 0 {
                    let wallDelta = now.timeIntervalSince(lastTime)
                    let rtf = wallDelta > 0 ? Double(audioDelta) / wallDelta : 0
                    print(String(format: "[RTF] live: +%.1fs audio confirmed in %.1fs wall -> %.2fx realtime",
                                 audioDelta, wallDelta, rtf))

                    // Stage split. `mel` and `enc` are per-WINDOW and FIXED. `fixed`
                    // is what one decode pays before the decoder emits a token.
                    // The decoder's own cost is the residual: wall - mel - enc.
                    let stages = WhisperStageTimer.shared.drain()
                    if stages.melRuns > 0, stages.encRuns > 0 {
                        let melEach = stages.melMs / Double(stages.melRuns)
                        let encEach = stages.encMs / Double(stages.encRuns)
                        print(String(format: "[RTF]   mel %.0fms x%d | enc %.0fms x%d | fixed %.0fms/window | wall %.0fms | fb %d",
                                     melEach, stages.melRuns,
                                     encEach, stages.encRuns,
                                     melEach + encEach,
                                     wallDelta * 1000,
                                     newState.currentFallbacks))
                    }
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
    /// on a route/interruption change.
    func restartLiveStream() async {
        guard isRecording else { return }

        // Gate-only mode has no transcriber to rebuild — just restart the tap so
        // the new hardware format is picked up.
        if gateOnlyCapture != nil {
            gateOnlyCapture?.stop()
            let capture = GateOnlyCapture()
            try? capture.start()
            gateOnlyCapture = capture
            statusMessage = "Audio route changed — resuming (gate only)…"
            return
        }

        // Keep what's been transcribed so far; the new transcriber starts empty.
        // TWO carry-overs, deliberately: the display one may contain unjudged
        // segments, and freezing those into the chart's feed would make them
        // permanent — nothing ever re-filters a carry-over.
        liveCarryOver = transcript
        verifiedCarryOver = lastVerifiedText
        liveConfirmedCarryOver = lastConfirmedCumulative
        lastConfirmedSegmentCount = 0
        lastLiveUpdateTime = nil
        lastLiveConfirmedSeconds = 0
        await streamTranscriber?.stopStreamTranscription()
        streamTask?.cancel()
        streamTranscriber = nil
        streamTask = nil
        gatedProcessor = nil        // rebuilt against the new route below
        statusMessage = "Audio route changed — resuming…"
        launchStreamTranscriber()
    }

    /// Stop capturing, but FINISH what is already in flight.
    ///
    /// The old version cancelled three things too early and each one lost work:
    /// `printGateSummary()` ran before the gate had seen the tail, the gate monitor
    /// was cancelled immediately, and `streamTask.cancel()` aborted the decode that
    /// was running. `TranscribeTask` calls `Task.checkCancellation()` before the
    /// mel, before the encoder and before the decode loop, so cancelling threw away
    /// exactly the sentence the clinician was part-way through.
    private func stopLiveTranscription() async {
        // Microphone off immediately so the button responds, but `isTranscribing`
        // stays true — there is still work to finish and the UI should say so.
        isRecording = false
        statusMessage = "Finishing up…"

        // 1. Stop taking NEW audio. This flips the streamer's own isRecording flag;
        //    its realtimeLoop() then exits after the decode it is currently running
        //    COMPLETES. NOT cancelled — see above.
        await streamTranscriber?.stopStreamTranscription()

        // 2. Wait for that last decode to land. Its state callback still fires, so
        //    the final words reach the transcript and the parser.
        await streamTask?.value

        // 3. NOW judge the tail. The gate runs behind the microphone, so the last
        //    spans of every session used to go unjudged — and under the buffer that
        //    would mean the last sentence never reaching the chart at all. Runs
        //    before the capture is torn down, so the buffer is still readable.
        await flushGateTail()

        gateMonitorTask?.cancel()
        gateMonitorTask = nil
        liveStreamStart = nil
        printGateSummary()

        streamTranscriber = nil
        streamTask = nil
        gatedProcessor = nil
        gateOnlyCapture?.stop()
        gateOnlyCapture = nil
        // Release session ownership last, after the capture graph is down.
        AudioManager.shared.endLiveCapture()

        isTranscribing = false
        statusMessage = transcript.isEmpty ? "No speech captured" : "Done"
    }

    /// One final gate pass over whatever has not been judged yet.
    ///
    /// With `GatedAudioProcessor` in the path its `stopRecording()` already forces
    /// a final sweep, so this usually finds nothing there. It still matters for the
    /// polling paths — gate-only mode, and any session where the gate was not armed
    /// when the wrapper would have been built.
    private func flushGateTail() async {
        guard let gate = speakerGate, gate.isEnrolled,
              let streamStart = liveStreamStart else { return }

        let sr = Double(SpeakerGate.sampleRate)
        let buffer: [Float]
        if let gated = gatedProcessor {
            buffer = gated.rawSamples
        } else if let capture = gateOnlyCapture {
            buffer = capture.samples
        } else if let whisper = whisperKit {
            buffer = Array(whisper.audioProcessor.audioSamples)
        } else {
            return
        }
        guard !buffer.isEmpty else { return }

        let absoluteEnd = Date().timeIntervalSince(streamStart)
        let origin = max(0, absoluteEnd - Double(buffer.count) / sr)
        let from = max(origin, lastGatedAbsoluteSeconds - 2.5)
        let startIndex = Int((from - origin) * sr)
        guard startIndex >= 0, startIndex < buffer.count else { return }

        let slice = Array(buffer[startIndex...])
        let extractor = TSEEngine.shared.extractor
        let results = await Task.detached(priority: .userInitiated) {
            (try? gate.appendEvaluation(audio: slice,
                                        absoluteOffsetSeconds: from,
                                        extractor: extractor)) ?? []
        }.value
        applyGateResults(results)
        lastGatedAbsoluteSeconds = absoluteEnd
        print("[Gate/live] final tail pass — \(results.count) span(s) judged")
    }

    // MARK: - Live speaker gate

    /// Poll the retained audio buffer and judge only the audio that is new.
    ///
    /// SKIPPED ENTIRELY when `GatedAudioProcessor` is in the path: it judges every
    /// chunk at its pause boundaries and fills the same timeline, so polling would
    /// double the ECAPA work and re-judge spans that already have verdicts. It is
    /// also faster — it decides at pauses rather than on a 2-second clock.
    ///
    /// TIME BASE for the polling path: absolute stream time is reconstructed from
    /// the wall clock — a live mic produces samples in real time, so
    /// `now - streamStart` is the stream time of the buffer's last sample.
    private func startGateMonitor() {
        gateStatus = GateStatus()
        guard let gate = speakerGate, gate.isEnrolled else {
            print("[Gate/live] not enrolled — nothing to compare against")
            return
        }
        let extractor = TSEEngine.shared.extractor
        gateStatus.active = true
        gateStatus.extractorReady = extractor?.isPrepared == true
        sessionSpans.removeAll()
        print(String(format: "[Gate/live] armed — %d template(s), accept d < %.3f, "
                     + "reject d >= %.3f, extractor %@%@",
                     gate.templateCount,
                     gate.gate.acceptThreshold,
                     gate.gate.rejectThreshold,
                     gateStatus.extractorReady ? "ready" : "unavailable",
                     TranscriptionEngine.shared.isGateOnly ? "  [GATE-ONLY]" : ""))

        if gatedProcessor != nil {
            print("[Gate/live] judging in the audio path — polling monitor disabled")
            return
        }

        // Anchored lazily on the first non-empty buffer: capture begins a few
        // hundred ms after this call, and anchoring here would bake that setup
        // delay in as a constant offset.
        liveStreamStart = nil
        lastGatedAbsoluteSeconds = 0
        gateMonitorTask?.cancel()
        gateMonitorTask = Task { [weak self] in
            let sr = Double(SpeakerGate.sampleRate)
            // Re-read this much already-judged audio each pass so an utterance
            // crossing a window boundary is still seen whole.
            let overlapSeconds = 2.5
            // Do not judge less than this at once — the embedder wants 3 s.
            let minWindowSeconds = 4.0

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                // `continue`, not `return`: a transient gap — restartLiveStream
                // rebuilding the capture graph — must not kill the monitor.
                guard self.isRecording else { continue }

                let buffer: [Float]
                if let capture = self.gateOnlyCapture {
                    buffer = capture.samples
                } else if let whisper = self.whisperKit {
                    buffer = Array(whisper.audioProcessor.audioSamples)
                } else {
                    continue
                }
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
        for r in results { sessionSpans[r.start] = r }   // overlaps overwrite, not duplicate
        // Windows overlap, so these describe the LAST pass rather than the session.
        gateStatus.spans = results.count
        gateStatus.rejected = results.filter { $0.verdictMixed == .reject }.count
        gateStatus.routed = results.filter(\.routed).count
        gateStatus.rescued = results.filter(\.rescued).count
        gateStatus.lastDistance = results.last?.distanceMixed
    }

    /// Printed once per session, AFTER the final tail pass. The distance
    /// distributions have to stay separable for enforcement to be safe: if the
    /// worst kept span and the best dropped span overlap, the threshold is wrong
    /// for this centroid and the fix is a better calibration recording, not code.
    ///
    /// Measured 2026-08-06 across two real speakers on two profiles, the gaps were
    /// +0.161 and +0.151 with 0.775 sitting almost exactly in the middle of both.
    private func printGateSummary() {
        let spans = sessionSpans.values.sorted { $0.start < $1.start }
        guard !spans.isEmpty else {
            print("[Gate/summary] no spans judged this session")
            return
        }
        func stats(_ xs: [Double]) -> String {
            guard !xs.isEmpty else { return "—" }
            let s = xs.sorted()
            return String(format: "min %.3f / med %.3f / max %.3f", s.first!, s[s.count / 2], s.last!)
        }
        let accepted = spans.filter { $0.verdictMixed == .accept }.compactMap(\.distanceMixed)
        let confirmed = spans.filter { $0.verdictMixed == .confirm }.compactMap(\.distanceMixed)
        let rejected = spans.filter { $0.verdictMixed == .reject }.compactMap(\.distanceMixed)
        let seconds = spans.reduce(0) { $0 + $1.durationSeconds }

        print(String(format: "[Gate/summary] %d spans, %.1fs judged", spans.count, seconds))
        print("[Gate/summary]   accept  \(accepted.count)  \(stats(accepted))")
        print("[Gate/summary]   confirm \(confirmed.count)  \(stats(confirmed))")
        print("[Gate/summary]   reject  \(rejected.count)  \(stats(rejected))")

        if let worstKept = (accepted + confirmed).max(), let bestDropped = rejected.min() {
            print(String(format: "[Gate/summary]   separation: worst kept %.3f vs best dropped %.3f -> %+.3f",
                         worstKept, bestDropped, bestDropped - worstKept))
        }
    }
}

// Small convenience used above.
private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
