//
//  Wav2VecViewModel.swift
//  PeriodontalCharting
//
//  THE JOIN BETWEEN THE THREE SUBSYSTEMS. The whole live path is:
//
//      mic -> Wav2VecAudioCapture -> [this] -> SpeakerGateService.gatedAudio
//          -> TargetSpeakerExtractor -> Wav2VecEngine.predict
//          -> onConfirmedTranscript -> AIVoiceViewModel -> TokenizerManager
//          -> StatefulParser -> the chart
//
//  Two things this file exists to guarantee:
//
//  1. GATE BEFORE DECODE, NOT AFTER. The extracted waveform is what
//     `Wav2VecEngine` receives, so by the time text exists it has already been
//     attributed to a speaker. The previous design judged audio and text on
//     separate clocks and had to reconcile them by timestamp.
//
//  2. CHUNKS REACH THE PARSER IN CAPTURE ORDER. `StatefulParser` is stateful —
//     the cursor, the pending values and the active selection all carry forward —
//     so a chunk arriving out of order does not merely misplace a word, it
//     misplaces every value after it. Commits are chained for that reason.
//

import Foundation
import Observation
import Accelerate

@MainActor
@Observable
final class Wav2VecViewModel {

    // MARK: - Observable state (the View binds to these)
    private(set) var transcript: String = ""
    private(set) var statusMessage: String = "Loading model…"
    private(set) var isModelReady: Bool = false
    private(set) var isTranscribing: Bool = false
    private(set) var isRecording: Bool = false

    // MARK: - Live event hooks (for AI Mode)
    // `onConfirmedTranscript` is the ONLY path to the parser. `onLiveTranscript`
    // updates the on-screen text and nothing else.
    var onLiveTranscript: ((String) -> Void)?
    var onConfirmedTranscript: ((String) -> Void)?

    private var streamingBuffer: [Float] = []
    private var committedHistory: [String] = []
    private var silenceFrames = 0
    private var hasStartedSpeaking = false
    private var lastProcessedBufferCount = 0
    private var baselineRMS: Float = 0.01
    private var isProcessing = false

    // Commits, chained. Each waits for its predecessor, so `committedHistory`
    // grows in capture order and `stopLive` has a single thing to await.
    @ObservationIgnored private var commitChain: Task<Void, Never>?
    // Bumped by every commit, so `stopLive` can tell whether a new one appeared
    // while it was awaiting the previous one.
    @ObservationIgnored private var commitGeneration = 0
    // True from the first line of `stopLive` until the drain finishes. Mic
    // buffers already queued on the main actor must not start a new commit.
    @ObservationIgnored private var isStopping = false

    // MARK: - Speaker gate

    // The app-wide gate and extractor, resolved once per session.
    //
    // Held rather than looked up per chunk: both live on the main actor while the
    // gate pass runs detached, so resolving them here keeps the commit path free
    // of a hop back to the main actor mid-decode.
    @ObservationIgnored private var gateService: SpeakerGateService?
    @ObservationIgnored private var extractor: TargetSpeakerExtractor?

    // Speaker-filter state for the AI Mode header. `active` false means every
    // voice in the room is being transcribed — say so plainly, because a silent
    // no-op gate is indistinguishable from a working one.
    struct GateStatus: Sendable {
        var active = false
        var extractorReady = false
        // False under `.extractOnly`, where rejects are measured but not acted
        // on. The count then reads "would drop", because saying "dropped" while
        // the words are still in the transcript is the one thing this header
        // must never do.
        var silencing = true
        var spans = 0
        var rejected = 0
        var extracted = 0
        var rescued = 0
        var lastDistance: Double?

        var summary: String {
            guard active else { return "Speaker filter off — all voices transcribed" }
            guard spans > 0 else { return "Speaker filter on — nothing judged yet" }
            var text = "\(spans) span(s), \(rejected) \(silencing ? "dropped" : "would drop")"
            if extracted > 0 { text += ", \(extracted) extracted" }
            if rescued > 0 { text += " (\(rescued) recovered)" }
            return text
        }
    }
    private(set) var gateStatus = GateStatus()

    // What one detached gate pass produced. Scalars plus the buffer, so it
    // crosses the actor boundary without carrying RescuedSpan.
    private struct GateOutcome: Sendable {
        var audio: [Float]
        var spans = 0
        var rejected = 0
        var extracted = 0
        var rescued = 0
        var lastDistance: Double?
    }

    func loadModel() async {
        statusMessage = "Loading Wav2Vec2 model…"
        await Wav2VecEngine.shared.loadModel()
        isModelReady = Wav2VecEngine.shared.isModelLoaded
        statusMessage = isModelReady ? "Model ready (Wav2Vec2)"
                                     : "Error: Model/Vocab failed to load."
    }

    func toggleRecording() {
        if isRecording { Task { await stopLive() } } else { startLive() }
    }

    func startLive() {
        guard !isRecording else { return }
        guard isModelReady else {
            statusMessage = "Model not ready. (Check logs)"
            return
        }

        transcript = ""
        committedHistory = []
        streamingBuffer = []
        silenceFrames = 0
        hasStartedSpeaking = false
        lastProcessedBufferCount = 0
        baselineRMS = 0.01
        commitChain = nil

        // The gate is only real if a centroid exists. An unenrolled gate reports
        // itself OFF rather than quietly passing everything — a filter that claims
        // to be on while accepting every voice is the exact failure this layer
        // exists to prevent.
        gateService = TranscriptionEngine.shared.makeSpeakerGateIfNeeded()
        extractor = TSEEngine.shared.extractor
        gateStatus = GateStatus(active: TSEConfig.mode.runsExtractor
                                        && (gateService?.isEnrolled ?? false),
                                extractorReady: extractor?.isPrepared == true,
                                silencing: TSEConfig.mode.silencesRejects)

        // The extractor is built lazily: onboarding prepares it after calibration
        // and a profile switch re-prepares it, but a cold start with a CACHED
        // profile restores gate templates without ever touching it. Asking here
        // races the first chunks — those route to nothing and fall back to the
        // gate's own verdict, which is the correct degradation.
        Task { [weak self] in
            await TSEEngine.shared.prepare()
            guard let self, self.isRecording else { return }
            self.extractor = TSEEngine.shared.extractor
            self.gateStatus.extractorReady = self.extractor?.isPrepared == true
        }

        // Debug capture, off unless switched on in the gate debug menu. Truncates
        // the previous session.
        SessionRecorder.shared.begin()

        isRecording = true
        isTranscribing = true
        statusMessage = "Listening…"

        do {
            try Wav2VecAudioCapture.shared.startStreamingRecording { [weak self] buffer in
                DispatchQueue.main.async {
                    self?.processAudioChunk(buffer)
                }
            }
        } catch {
            statusMessage = "Live error: \(error.localizedDescription)"
            isRecording = false
            isTranscribing = false
        }
    }

    // Stop the mic and finish every commit still in flight.
    //
    // ASYNC ON PURPOSE. The tail chunk still has a gate pass and a decode ahead of
    // it, and `AIVoiceViewModel` finalises the parser the moment this returns.
    // When this was synchronous the tail's text landed AFTER `sessionParser` had
    // been consumed and set to nil, so the last thing said in a session was
    // silently dropped — and gating widened that window, because extraction runs
    // serially before the decode.
    func stopLive() async {
        guard isRecording else { return }
        // BEFORE stopRecording(). Removing the tap does not cancel mic buffers
        // already dispatched to the main actor, and each `await` below lets them
        // run — one of them starting a fresh commit is how a whole chunk got
        // gated, extracted and decoded a SECOND time after the session had been
        // saved, at ~4 s of wasted extraction and a duplicate parser feed.
        isStopping = true
        Wav2VecAudioCapture.shared.stopRecording()
        isRecording = false
        isTranscribing = false

        let tail = streamingBuffer
        streamingBuffer = []
        if tail.count >= 16000 { commit(tail) }

        // Drain until a full await adds nothing new. The `isStopping` guard should
        // make one pass enough; this is the backstop that makes it true rather
        // than assumed, since `commitChain = nil` on its own would just DROP a
        // task that had been queued during the await, not stop it running.
        var seen = -1
        while seen != commitGeneration {
            seen = commitGeneration
            await commitChain?.value
        }
        commitChain = nil
        isStopping = false

        // After the drain, so the tail chunk is in the dump before it closes.
        SessionRecorder.shared.finish()
        statusMessage = transcript.isEmpty ? "No speech captured" : "Done"
    }

    private func processAudioChunk(_ buffer: [Float]) {
        // A buffer queued before the tap was removed. Dropping it is correct:
        // `stopLive` has already taken the tail, so anything arriving now is
        // either a duplicate of it or audio from after the mic went off.
        guard !isStopping else { return }

        var rms: Float = 0.0
        vDSP_rmsqv(buffer, 1, &rms, vDSP_Length(buffer.count))

        let threshold = max(0.001, baselineRMS * 2.0)
        let isSpeech = rms > threshold

        if !isSpeech { baselineRMS = baselineRMS * 0.99 + rms * 0.01 }

        if isSpeech {
            silenceFrames = 0
            hasStartedSpeaking = true
        } else {
            silenceFrames += 1
        }

        streamingBuffer.append(contentsOf: buffer)

        if !hasStartedSpeaking {
            let preRollSamples = 16000
            if streamingBuffer.count > preRollSamples {
                streamingBuffer.removeFirst(streamingBuffer.count - preRollSamples)
            }
        }

        // Commit sooner as the buffer grows, so an unbroken stretch of speech
        // cannot outrun the decoder.
        var requiredSilence = 15                            // 0.48 s
        if streamingBuffer.count > 16000 * 15 { requiredSilence = 10 }
        if streamingBuffer.count > 16000 * 30 { requiredSilence = 5 }
        if streamingBuffer.count > 16000 * 45 { requiredSilence = 3 }
        if streamingBuffer.count > 16000 * 55 { requiredSilence = 0 }

        if hasStartedSpeaking && silenceFrames >= requiredSilence && streamingBuffer.count > 16000 {
            let chunk = streamingBuffer
            streamingBuffer.removeAll()
            silenceFrames = 0
            hasStartedSpeaking = false
            lastProcessedBufferCount = 0
            commit(chunk)
        }
        else if streamingBuffer.count >= 16000 && !isProcessing && silenceFrames <= requiredSilence {
            // INTERMEDIATE PREVIEW — UNGATED, deliberately.
            //
            // This re-runs every ~0.5 s over a growing buffer, and extraction costs
            // ~0.3 RTF; gating it would cost more than the decode itself. Nothing
            // it produces reaches the chart — only `onConfirmedTranscript` feeds
            // the parser, and that fires only from `commit`.
            //
            // The visible consequence: preview text can show a second voice for a
            // moment and then lose it when the chunk commits. That is the gate
            // working, not the decoder stuttering.
            if streamingBuffer.count - lastProcessedBufferCount >= 8000 {
                lastProcessedBufferCount = streamingBuffer.count
                let chunk = streamingBuffer
                isProcessing = true
                Task { [weak self] in
                    guard let self else { return }
                    defer { self.isProcessing = false }
                    let normalized = Wav2VecAudioCapture.shared.normalizeAudio(data: chunk)
                    guard let result = await Wav2VecEngine.shared.predict(audioData: normalized,
                                                                          isLivePreview: true) else { return }
                    let live = (self.committedHistory + [result]).joined(separator: " ")
                    self.transcript = live
                    self.onLiveTranscript?(live)
                }
            }
        }
    }

    // Queue a committed chunk behind whatever is already running.
    private func commit(_ chunk: [Float]) {
        commitGeneration += 1
        let previous = commitChain
        commitChain = Task { [weak self] in
            await previous?.value
            await self?.performCommit(chunk)
        }
    }

    // Gate, decode, publish.
    private func performCommit(_ chunk: [Float]) async {
        isProcessing = true
        defer { isProcessing = false }

        let gatedOrNil = await gatedChunk(chunk)

        // Capture BEFORE the early return, so a withheld chunk still lands in the
        // dump. A chunk the gate threw away is the single most interesting thing
        // to listen back to — it is either the filter working or the clinician
        // being cut off, and only the audio distinguishes those.
        SessionRecorder.shared.append(raw: chunk, gated: gatedOrNil)

        guard let gated = gatedOrNil else { return }

        // NORMALISE AFTER EXTRACTION. `gated` is the separated waveform wherever a
        // span was extracted; Z-scoring first would hand the extractor a signal it
        // was never conditioned on, and would rescale the buffer the energy
        // segmenter measures its noise floor against.
        let normalized = Wav2VecAudioCapture.shared.normalizeAudio(data: gated)
        guard let result = await Wav2VecEngine.shared.predict(audioData: normalized,
                                                             isLivePreview: false),
              !result.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        committedHistory.append(result)
        let joined = committedHistory.joined(separator: " ")
        transcript = joined
        onConfirmedTranscript?(joined)
        onLiveTranscript?(joined)
    }

    // Run the gate + extractor over one committed chunk.
    //
    // Returns the audio Wav2Vec should transcribe, or nil to withhold the chunk
    // entirely — the case where every judged span was somebody else. Feeding that
    // through anyway would decode near-silence into whatever the white-noise
    // padding suggests, which is worse than no text.
    //
    // FAILS OPEN. No gate, no enrolment, or a thrown pass returns the chunk
    // untouched: a broken gate must not silently stop transcription, because the
    // clinician sees a running mic and no words with nothing to explain it.
    private func gatedChunk(_ chunk: [Float]) async -> [Float]? {
        guard TSEConfig.mode.runsExtractor,
              let service = gateService, service.isEnrolled else { return chunk }
        let extractor = self.extractor

        // Detached: this runs ECAPA on every span and the six-model extractor on
        // routed ones. On the main actor it would stall the chart mid-dictation.
        let outcome = await Task.detached(priority: .userInitiated) { () -> GateOutcome? in
            guard let gated = try? service.gatedAudio(for: chunk, extractor: extractor) else {
                return nil
            }
            var result = GateOutcome(audio: gated.audio)
            result.spans = gated.spans.count
            for span in gated.spans {
                if span.effectiveVerdict == .reject { result.rejected += 1 }
                if span.routed {
                    result.extracted += 1
                    // "Rescued" is only meaningful where extraction was allowed to
                    // change the verdict — a frozen accept or confirm was never in
                    // danger, so counting it here would inflate the number that
                    // decides whether the extractor earns its place.
                    if span.verdictMixed == .reject, span.effectiveVerdict != .reject {
                        result.rescued += 1
                    }
                }
            }
            result.lastDistance = gated.spans.last
                .map { $0.distanceSeparated ?? $0.distanceMixed } ?? nil
            return result
        }.value

        guard let outcome else {
            print("[Gate] pass failed — chunk transcribed ungated")
            return chunk
        }

        gateStatus.spans += outcome.spans
        gateStatus.rejected += outcome.rejected
        gateStatus.extracted += outcome.extracted
        gateStatus.rescued += outcome.rescued
        if let d = outcome.lastDistance { gateStatus.lastDistance = d }

        // Every span rejected: withhold. Zero spans means the segmenter found
        // nothing judgeable, which is NOT a reject — that audio passes through.
        //
        // ONLY UNDER `.enforce`. Withholding is a rejection, and `.extractOnly`
        // exists precisely to test what happens when nothing is rejected — so it
        // hands the chunk on and lets the transcript answer the question.
        if TSEConfig.mode.silencesRejects, outcome.spans > 0, outcome.rejected == outcome.spans {
            print("[Gate] chunk withheld — all \(outcome.spans) span(s) rejected")
            return nil
        }
        return outcome.audio
    }
}
