//
//  TSERescue.swift
//  PeriodontalCharting
//
//  EXTRACTION IS A RESCUE PATH, NOT A FRONT-END.
//
//      VAD -> mergeSpans -> ECAPA -> d
//        d <  ROUTE_THRESHOLD  -> PASS THROUGH untouched     41/54 bench items
//        d >= ROUTE_THRESHOLD  -> EXTRACTOR -> re-embed      13/54
//                                 -> POST_ACCEPT_THRESHOLD
//
//  Gate 1 ("do no harm") killed every always-on candidate. Under the rescue path
//  clean audio never reaches the extractor, so Gate 1 is moot BY CONSTRUCTION —
//  measured on the bench: `clean controls routed: 0`.
//
//  ONE ROUTING ROUTINE, TWO ENTRY POINTS. `route(slice:)` is the only place a
//  routing decision is made, so the file and live paths cannot drift apart.
//

import Accelerate
import Foundation

/// One span's journey through the rescue path. `distanceSeparated` is nil when
/// the span was bypassed — that is the normal case, not a failure.
struct RescuedSpan {
    let start: Int
    let end: Int
    let verdictMixed: Verdict
    let distanceMixed: Double?
    let verdictSeparated: Verdict?
    let distanceSeparated: Double?
    let routed: Bool
    let extractionSeconds: Double
    /// RMS of the span. Distinguishes real speech from a fallback window that
    /// tiled silence — a distance measured on near-silence is meaningless, and
    /// without this the log gives no way to tell the two apart.
    let level: Float
    /// Only populated when `keepAudio` was requested.
    var extractedAudio: [Float]?

    var startSeconds: Double { Double(start) / Double(SpeakerGate.sampleRate) }
    var endSeconds: Double { Double(end) / Double(SpeakerGate.sampleRate) }
    var durationSeconds: Double { endSeconds - startSeconds }

    /// The verdict the chart should act on once the mode is `.enforce`.
    var effectiveVerdict: Verdict { verdictSeparated ?? verdictMixed }

    /// A span the extractor pulled back over the line.
    var rescued: Bool { routed && effectiveVerdict != .reject }

    /// Cosine SIMILARITY to the centroid — the complement of the distance the
    /// thresholds use. 1.0 is identical, 0.0 is orthogonal.
    var similarity: Double? { distanceMixed.map { 1.0 - $0 } }
}

extension SpeakerGateService {

    // MARK: - Tuning

    /// Span parameters for the RESCUE paths. Deliberately tighter than
    /// `mergeSpans`' defaults, which `evaluate(audio:)` keeps so its distances
    /// stay comparable with the Python harness.
    enum RescueTuning {
        /// Silero's 0.5 default finds nothing on this microphone — measured max
        /// probability on clean, deliberate, close-mic speech was 0.409.
        static let vadThreshold: Float = 0.3

        /// 0.35 s, not 1.5 s. The difference between gating a PERSON and gating a
        /// CONVERSATION: offline numbers came from single-speaker recordings, but
        /// in a real room consecutive turns are well under 1.5 s apart, so the
        /// default merge fuses them into one span whose embedding contains the
        /// target — and therefore reads as the target.
        static let maxGapSeconds = 0.35

        /// Matches `SpeakerGate.inputSamples` (3.0 s), so no span is centre-cropped.
        static let maxSpanSeconds = 3.0
    }

    // MARK: - The routing decision (the one that must exist once)

    /// Classify one span, and extract + re-gate it when the gate does not accept.
    ///
    /// Re-embedding uses the GATE's encoder (SpeechBrain ECAPA). The extractor's
    /// own WeSpeaker ECAPA lives in a different embedding space and its distances
    /// are not comparable to these thresholds.
    private func route(slice: [Float],
                       start: Int,
                       end: Int,
                       extractor: TargetSpeakerExtractor?,
                       keepAudio: Bool) throws -> RescuedSpan {

        var level: Float = 0
        vDSP_rmsqv(slice, 1, &level, vDSP_Length(slice.count))

        let mixed = (try? gate.classify(slice))
            ?? GateResult(verdict: .tooShort, distance: nil)
        let duration = Double(slice.count) / Double(SpeakerGate.sampleRate)

        let shouldRoute =
            TSEConfig.mode != .off
            && extractor?.isPrepared == true
            && mixed.verdict != .tooShort
            && (mixed.distance ?? 0) >= TSEConfig.routeThreshold
            && duration >= TSEConfig.minRouteSeconds

        guard shouldRoute, let extractor else {
            return RescuedSpan(start: start, end: end,
                               verdictMixed: mixed.verdict,
                               distanceMixed: mixed.distance,
                               verdictSeparated: nil, distanceSeparated: nil,
                               routed: false, extractionSeconds: 0,
                               level: level, extractedAudio: nil)
        }

        let began = CFAbsoluteTimeGetCurrent()
        let extracted = try extractor.extract(slice)
        let elapsed = CFAbsoluteTimeGetCurrent() - began
        let separated = (try? gate.classify(extracted))
            ?? GateResult(verdict: .reject, distance: nil)

        let verdict: Verdict
        if let d = separated.distance {
            verdict = d < TSEConfig.postAcceptThreshold ? .accept
                    : (d < gate.rejectThreshold ? .confirm : .reject)
        } else {
            verdict = .reject
        }

        return RescuedSpan(start: start, end: end,
                           verdictMixed: mixed.verdict,
                           distanceMixed: mixed.distance,
                           verdictSeparated: verdict,
                           distanceSeparated: separated.distance,
                           routed: true, extractionSeconds: elapsed,
                           level: level,
                           extractedAudio: keepAudio ? extracted : nil)
    }

    /// Speech spans to judge, plus whether they came from the fallback.
    ///
    /// Two defences live here, both learned the hard way:
    ///
    /// 1. PEAK-NORMALISE before the VAD. The only measurement where Silero gave a
    ///    usable probability on this hardware (0.409) was on file audio, which
    ///    `SpeakerGate.loadSamples` peak-normalises. Live buffer audio arrives raw
    ///    and Silero collapsed to 0.003–0.046 on speech Whisper transcribed
    ///    cleanly at rms 0.08 — so present it the same shape of signal the
    ///    enrollment path does. Indices map 1:1, and spans are sliced from the
    ///    ORIGINAL audio afterwards (ECAPA is gain-invariant either way).
    ///
    /// 2. FIXED-WINDOW FALLBACK when the VAD still finds nothing. The enrollment
    ///    path already needed this. Without it the live gate produces zero spans,
    ///    the timeline stays empty, every timestamp is uncovered — silently,
    ///    because the empty-span return happens before any logging. The log lines
    ///    below exist so that can never be silent again.
    private func rescueSpans(in audio: [Float]) -> (spans: [SpeechSegment], fromFallback: Bool) {
        var probe = audio
        var peakAmplitude: Float = 0
        vDSP_maxmgv(probe, 1, &peakAmplitude, vDSP_Length(probe.count))
        if peakAmplitude > 1e-6 {
            var scale = 1.0 / peakAmplitude
            vDSP_vsmul(probe, 1, &scale, &probe, 1, vDSP_Length(probe.count))
        }

        let merged = Self.mergeSpans(
            vad.speechTimestamps(probe, threshold: RescueTuning.vadThreshold),
            totalSamples: audio.count,
            maxGapSeconds: RescueTuning.maxGapSeconds,
            maxDurationSeconds: RescueTuning.maxSpanSeconds)
        if !merged.isEmpty { return (merged, false) }

        // `speechProbabilities` swallows failed predictions as 0, so a DEAD VAD
        // and genuine silence produce the same empty list. Print the peak next to
        // the input amplitude: a low probability at amp 1.000 means the model is
        // not predicting usefully, and the fallback is masking that rather than
        // compensating for a quiet microphone.
        let seconds = Double(audio.count) / Double(SpeakerGate.sampleRate)
        let peakProb = vad.speechProbabilities(probe).max() ?? 0

        let window = SpeakerGate.inputSamples          // 3.0 s — the embedder's input
        guard audio.count >= window else {
            print(String(format: "[Gate] no spans in %.1fs (VAD peak %.3f, amp %.3f), window too short",
                         seconds, peakProb, peakAmplitude))
            return ([], true)
        }
        var windows: [SpeechSegment] = []
        var start = 0
        while start + window <= audio.count {
            windows.append(SpeechSegment(start: start, end: start + window))
            start += window
        }
        print(String(format: "[Gate] VAD found nothing at %.2f in %.1fs (peak %.3f, amp %.3f) — "
                     + "%d blind window(s); distances below are NOT trustworthy",
                     RescueTuning.vadThreshold, seconds, peakProb, peakAmplitude, windows.count))
        return (windows, true)
    }

    /// Verdict to install in the timeline. Only `.enforce` lets an extraction
    /// change it; observe records the counterfactual and leaves the gate's own
    /// decision in place.
    private static func timelineSpan(_ r: RescuedSpan, enforcing: Bool) -> GatedSpan {
        GatedSpan(start: r.start, end: r.end,
                  verdict: enforcing ? r.effectiveVerdict : r.verdictMixed,
                  distance: enforcing ? (r.distanceSeparated ?? r.distanceMixed)
                                      : r.distanceMixed)
    }

    // MARK: - Entry point 1: a whole file (batch transcription)

    @discardableResult
    func evaluateWithRescue(audio: [Float],
                            extractor: TargetSpeakerExtractor?,
                            keepAudio: Bool = false) throws -> [RescuedSpan] {

        let (spans, fromFallback) = rescueSpans(in: audio)
        var results: [RescuedSpan] = []
        results.reserveCapacity(spans.count)

        for span in spans {
            results.append(try route(slice: Array(audio[span.start..<span.end]),
                                     start: span.start, end: span.end,
                                     extractor: extractor, keepAudio: keepAudio))
        }

        let enforcing = TSEConfig.mode == .enforce
        Self.log(results, tag: "file", enforcing: enforcing, fromFallback: fromFallback)
        if enforcing {
            replaceTimeline(results.map { Self.timelineSpan($0, enforcing: true) })
        }
        return results
    }

    /// Splice extracted audio back over the routed spans — for a BATCH path only.
    static func rebuild(audio: [Float], with results: [RescuedSpan]) -> [Float] {
        var out = audio
        for r in results where r.routed {
            guard let extracted = r.extractedAudio else { continue }
            let n = min(extracted.count, r.end - r.start)
            for i in 0..<n { out[r.start + i] = extracted[i] }
        }
        return out
    }

    // MARK: - Entry point 2: a live window (streaming)

    /// Judge a window of live audio and merge the verdicts into the timeline.
    ///
    /// OVERLAPPING WINDOWS, not disjoint slices: `mergeSpans` drops anything under
    /// 1 s and the embedder wants 3 s, so short adjacent chunks destroy exactly the
    /// spans they are meant to judge.
    ///
    /// TIME BASE: absolute seconds since the stream started —
    /// `AudioStreamTranscriber.offsetSegments` adds its buffer origin before the
    /// callback fires, so the timestamps compared against are already absolute.
    @discardableResult
    func appendEvaluation(audio: [Float],
                          absoluteOffsetSeconds: Double,
                          extractor: TargetSpeakerExtractor? = nil,
                          retainSeconds: Double = 120) throws -> [RescuedSpan] {

        let sr = Double(SpeakerGate.sampleRate)
        let base = Int(absoluteOffsetSeconds * sr)
        let windowEnd = absoluteOffsetSeconds + Double(audio.count) / sr

        let (spans, fromFallback) = rescueSpans(in: audio)
        guard !spans.isEmpty else { return [] }

        var results: [RescuedSpan] = []
        results.reserveCapacity(spans.count)
        for span in spans {
            results.append(try route(slice: Array(audio[span.start..<span.end]),
                                     start: base + span.start, end: base + span.end,
                                     extractor: extractor, keepAudio: false))
        }

        let enforcing = TSEConfig.mode == .enforce
        var timeline = currentTimeline
        // NEVER delete an existing verdict. The overlap exists so an utterance
        // crossing a window boundary is seen whole by SOME pass; whichever pass saw
        // it whole already recorded it, and a later pass sees only its tail.
        // Deleting overlapped spans silently erased verdicts and left uncovered
        // holes, which the segment filter then read as "no opinion".
        let fresh = results
            .map { Self.timelineSpan($0, enforcing: enforcing) }
            .filter { candidate in
                !timeline.contains { $0.endSeconds > candidate.startSeconds
                                  && $0.startSeconds < candidate.endSeconds }
            }
        timeline.append(contentsOf: fresh)
        timeline.sort { $0.start < $1.start }
        let cutoff = windowEnd - retainSeconds
        if cutoff > 0 { timeline.removeAll { $0.endSeconds < cutoff } }
        replaceTimeline(timeline)

        Self.log(results, tag: "live", enforcing: enforcing, fromFallback: fromFallback)
        return results
    }

    /// The span covering a timestamp, or nil when the gate has not reached it.
    func coveringSpan(atSeconds t: Double) -> GatedSpan? {
        currentTimeline.first { t >= $0.startSeconds && t < $0.endSeconds }
    }

    // MARK: - Logging

    /// One line per span. Reading order: does the LEVEL look like speech, is the
    /// SOURCE vad (trustworthy) or win (blind), then the distance and its margin.
    private static func log(_ results: [RescuedSpan],
                            tag: String,
                            enforcing: Bool,
                            fromFallback: Bool) {
        let source = fromFallback ? "win" : "vad"
        for r in results {
            let d = r.distanceMixed
            let dText = d.map { String(format: "%.3f", $0) } ?? " --- "
            let cosText = r.similarity.map { String(format: "%.3f", $0) } ?? " --- "
            // Positive margin = inside the accept region. Negative = how far over.
            let marginText = d.map { String(format: "%+.3f", TSEConfig.postAcceptThreshold - $0) } ?? "  --- "

            if r.routed {
                let ds = r.distanceSeparated.map { String(format: "%.3f", $0) } ?? " --- "
                print(String(format: "[TSE/%@] %6.2f–%6.2fs (%.1fs) %@ rms %.3f  d %@ -> %@  %@ -> %@  (%.2fs)%@",
                             tag, r.startSeconds, r.endSeconds, r.durationSeconds,
                             source, r.level, dText, ds,
                             r.verdictMixed.rawValue, r.effectiveVerdict.rawValue,
                             r.extractionSeconds,
                             enforcing ? "" : "   [observe]"))
            } else {
                print(String(format: "[Gate/%@] %6.2f–%6.2fs (%.1fs) %@ rms %.3f  d %@  cos %@  margin %@  %@",
                             tag, r.startSeconds, r.endSeconds, r.durationSeconds,
                             source, r.level, dText, cosText, marginText,
                             r.verdictMixed.rawValue))
            }
        }
    }
}
