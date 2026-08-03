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
//  measured on the bench: `clean controls routed: 0`. Do not "simplify" this into
//  always-on; that is a different, worse system that has been measured.
//
//  Rescue-path bench result: 13 routed, mean SDRi +9.6 dB, 13/13 recovered,
//  0 unsafe promotions, 0 clean controls routed.
//
//  ONE ROUTING ROUTINE, TWO ENTRY POINTS. The file path and the live path used to
//  be separate files with the same per-span logic copy-pasted, and they drifted
//  the first time the span parameters were tuned — the live path got the fix, the
//  file path silently kept the old defaults. `route(slice:)` is now the only place
//  a routing decision is made.
//

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
    /// Only populated when `keepAudio` was requested.
    var extractedAudio: [Float]?

    var startSeconds: Double { Double(start) / Double(SpeakerGate.sampleRate) }
    var endSeconds: Double { Double(end) / Double(SpeakerGate.sampleRate) }
    var durationSeconds: Double { endSeconds - startSeconds }

    /// The verdict the chart should act on once the mode is `.enforce`.
    var effectiveVerdict: Verdict { verdictSeparated ?? verdictMixed }

    /// A span the extractor pulled back over the line.
    var rescued: Bool { routed && effectiveVerdict != .reject }
}

extension SpeakerGateService {

    // MARK: - Tuning

    /// Span parameters for the RESCUE paths. Deliberately tighter than
    /// `mergeSpans`' defaults, which `evaluate(audio:)` keeps so its distances
    /// stay comparable with the Python harness.
    enum RescueTuning {
        /// Silero's 0.5 default finds nothing on this microphone — measured max
        /// probability on clean, deliberate, close-mic speech was 0.409. At the
        /// default the gate produces no spans and then fails open over everything.
        static let vadThreshold: Float = 0.3

        /// 0.35 s, not 1.5 s. This is the difference between gating a PERSON and
        /// gating a CONVERSATION: every offline number came from spans cut out of
        /// single-speaker recordings, but in a real room one speaker's turn and
        /// the next are usually well under 1.5 s apart, so the default merge fuses
        /// them into a single span whose embedding contains the target — and so
        /// reads as the target, carrying the other voice through inside an accept.
        static let maxGapSeconds = 0.35

        /// Matches `SpeakerGate.inputSamples` (3.0 s) exactly, so no span is
        /// centre-cropped before embedding.
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
                               extractedAudio: nil)
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
                           extractedAudio: keepAudio ? extracted : nil)
    }

    private func rescueSpans(in audio: [Float]) -> [SpeechSegment] {
        Self.mergeSpans(vad.speechTimestamps(audio, threshold: RescueTuning.vadThreshold),
                        totalSamples: audio.count,
                        maxGapSeconds: RescueTuning.maxGapSeconds,
                        maxDurationSeconds: RescueTuning.maxSpanSeconds)
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

    /// Gate every span in a completed recording, routing the ones the gate does
    /// not accept. Runs inference — call off the main actor.
    ///
    /// - Parameter keepAudio: retain the extracted waveform per span. Needed by
    ///   `rebuild(audio:with:)`; costs memory, so off by default.
    @discardableResult
    func evaluateWithRescue(audio: [Float],
                            extractor: TargetSpeakerExtractor?,
                            keepAudio: Bool = false) throws -> [RescuedSpan] {

        let spans = rescueSpans(in: audio)
        var results: [RescuedSpan] = []
        results.reserveCapacity(spans.count)

        for span in spans {
            results.append(try route(slice: Array(audio[span.start..<span.end]),
                                     start: span.start, end: span.end,
                                     extractor: extractor, keepAudio: keepAudio))
        }

        let enforcing = TSEConfig.mode == .enforce
        Self.log(results, tag: "file", enforcing: enforcing)
        if enforcing {
            replaceTimeline(results.map { Self.timelineSpan($0, enforcing: true) })
        }
        return results
    }

    /// Splice extracted audio back over the routed spans. This is what a BATCH
    /// transcription path feeds to Whisper.
    ///
    /// The LIVE path cannot use it: WhisperKit's `AudioStreamTranscriber`
    /// captures, VADs, windows and decodes as one unit, and
    /// `audioProcessor.audioSamples` is a READ-ONLY tap.
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

    /// Gate a window of live audio and merge the verdicts into the timeline,
    /// replacing any that overlap the same range.
    ///
    /// OVERLAPPING WINDOWS, not disjoint slices: `mergeSpans` drops anything
    /// under 1 s and the embedder wants 3 s, so chopping the stream into short
    /// adjacent chunks destroys exactly the spans it is supposed to judge — an
    /// utterance crossing a boundary becomes two discarded fragments and the gate
    /// fails open over both. Each pass re-reads a few seconds of already-gated
    /// audio, and verdicts covering the re-read range are REPLACED rather than
    /// appended, so a timestamp never has two conflicting spans.
    ///
    /// TIME BASE: absolute seconds since the stream started, because
    /// `AudioStreamTranscriber.offsetSegments` adds its buffer origin before the
    /// callback fires — the timestamps `isTargetSpeaking(atSeconds:)` compares
    /// against are already absolute.
    @discardableResult
    func appendEvaluation(audio: [Float],
                          absoluteOffsetSeconds: Double,
                          extractor: TargetSpeakerExtractor? = nil,
                          retainSeconds: Double = 120) throws -> [RescuedSpan] {

        let sr = Double(SpeakerGate.sampleRate)
        let base = Int(absoluteOffsetSeconds * sr)
        let windowEnd = absoluteOffsetSeconds + Double(audio.count) / sr

        let spans = rescueSpans(in: audio)
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
        // Drop anything overlapping the window we just re-judged, so the overlap
        // refines a verdict instead of leaving a stale one in front of it.
        timeline.removeAll { $0.endSeconds > absoluteOffsetSeconds && $0.startSeconds < windowEnd }
        timeline.append(contentsOf: results.map { Self.timelineSpan($0, enforcing: enforcing) })
        timeline.sort { $0.start < $1.start }
        let cutoff = windowEnd - retainSeconds
        if cutoff > 0 { timeline.removeAll { $0.endSeconds < cutoff } }
        replaceTimeline(timeline)

        Self.log(results, tag: "live", enforcing: enforcing)
        return results
    }

    /// The span covering a timestamp, or nil when the gate has not reached it.
    /// Exposed so the segment filter can log WHY a line passed — "no span covers
    /// this" and "a span accepted this" are different failures with different fixes.
    func coveringSpan(atSeconds t: Double) -> GatedSpan? {
        currentTimeline.first { t >= $0.startSeconds && t < $0.endSeconds }
    }

    // MARK: - Logging

    private static func log(_ results: [RescuedSpan], tag: String, enforcing: Bool) {
        for r in results {
            let d = r.distanceMixed.map { String(format: "%.3f", $0) } ?? "  -  "
            if r.routed {
                let ds = r.distanceSeparated.map { String(format: "%.3f", $0) } ?? "  -  "
                print(String(format: "[TSE/%@] %6.2f–%6.2fs  d %@ -> %@  %@ -> %@  (%.2fs)%@",
                             tag, r.startSeconds, r.endSeconds, d, ds,
                             r.verdictMixed.rawValue, r.effectiveVerdict.rawValue,
                             r.extractionSeconds,
                             enforcing ? "" : "   [observe: text unchanged]"))
            } else {
                print(String(format: "[Gate/%@] %6.2f–%6.2fs (%.1fs)  d %@  %@",
                             tag, r.startSeconds, r.endSeconds, r.durationSeconds, d,
                             r.verdictMixed.rawValue))
            }
        }
    }
}
