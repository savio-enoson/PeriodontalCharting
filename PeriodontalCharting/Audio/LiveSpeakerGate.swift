//
//  LiveSpeakerGate.swift
//  PeriodontalCharting
//
//  Incremental gating for the LIVE path, with the TSE rescue path attached.
//
//  `evaluate(audio:)` replaces the timeline wholesale, which is right for a file
//  and wrong for a stream: WhisperKit retains 32 s and the gate would re-run
//  ECAPA over all of it every pass. This appends instead.
//
//  OVERLAPPING WINDOWS, not disjoint slices. `mergeSpans` drops anything under
//  1 s and the embedder wants 3 s, so chopping the stream into short adjacent
//  chunks destroys exactly the spans it is supposed to judge — an utterance
//  crossing a boundary becomes two discarded fragments, and the gate then fails
//  open over both. Each pass therefore re-reads a few seconds of already-gated
//  audio, and verdicts covering the re-read range are REPLACED rather than
//  appended, so a timestamp never has two conflicting spans.
//
//  TIME BASE: absolute seconds since the stream started. That is NOT negotiable —
//  `AudioStreamTranscriber.offsetSegments` adds `bufferOriginSeconds` before the
//  callback fires, so the segment timestamps `isTargetSpeaking(atSeconds:)` is
//  compared against are already absolute.
//

import Foundation

extension SpeakerGateService {

    /// Gate a window of live audio and merge the verdicts into the timeline,
    /// replacing any that overlap the same range.
    ///
    /// - Parameters:
    ///   - audio: the window's samples.
    ///   - absoluteOffsetSeconds: stream time of `audio[0]`.
    ///   - extractor: when prepared, spans the gate does not accept are extracted
    ///     and re-gated. In `.observe` this only produces a log line.
    ///   - retainSeconds: timeline history kept. 120 s covers WhisperKit's 32 s
    ///     retained buffer plus confirmation lag.
    @discardableResult
    func appendEvaluation(audio: [Float],
                          absoluteOffsetSeconds: Double,
                          extractor: TargetSpeakerExtractor? = nil,
                          retainSeconds: Double = 120) throws -> [RescuedSpan] {

        let sr = Double(SpeakerGate.sampleRate)
        let base = Int(absoluteOffsetSeconds * sr)
        let windowEnd = absoluteOffsetSeconds + Double(audio.count) / sr

        // Threshold 0.3, not Silero's 0.5 default: measured max probability on
        // this mic is 0.409, so the default finds nothing and the gate then fails
        // open across the whole window. Same reasoning as the enrollment path,
        // which already had to drop to 0.3 for exactly this hardware.
        //
        // maxGap 0.35 s / maxDuration 3.0 s, tighter than the file path's
        // 1.5 s / 6.0 s. This is the difference between gating a PERSON and
        // gating a CONVERSATION: the offline numbers came from spans cut out of
        // single-speaker recordings, but in a real room one speaker's turn and
        // the next are usually less than 1.5 s apart, so the default merge fuses
        // them into a single span whose embedding contains the target — and
        // therefore reads as the target, carrying the other voice through inside
        // an `accept`. 3.0 s also matches SpeakerGate.inputSamples exactly, so no
        // span gets centre-cropped before embedding.
        let spans = Self.mergeSpans(vad.speechTimestamps(audio, threshold: 0.3),
                                    totalSamples: audio.count,
                                    maxGapSeconds: 0.35,
                                    maxDurationSeconds: 3.0)
        guard !spans.isEmpty else { return [] }

        var results: [RescuedSpan] = []
        results.reserveCapacity(spans.count)

        for span in spans {
            let slice = Array(audio[span.start..<span.end])
            let mixed = (try? gate.classify(slice))
                ?? GateResult(verdict: .tooShort, distance: nil)

            let duration = Double(span.end - span.start) / sr
            let shouldRoute =
                TSEConfig.mode != .off
                && extractor?.isPrepared == true
                && mixed.verdict != .tooShort
                && (mixed.distance ?? 0) >= TSEConfig.routeThreshold
                && duration >= TSEConfig.minRouteSeconds

            guard shouldRoute, let extractor else {
                results.append(RescuedSpan(start: base + span.start, end: base + span.end,
                                           verdictMixed: mixed.verdict,
                                           distanceMixed: mixed.distance,
                                           verdictSeparated: nil, distanceSeparated: nil,
                                           routed: false, extractionSeconds: 0,
                                           extractedAudio: nil))
                continue
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

            results.append(RescuedSpan(start: base + span.start, end: base + span.end,
                                       verdictMixed: mixed.verdict,
                                       distanceMixed: mixed.distance,
                                       verdictSeparated: verdict,
                                       distanceSeparated: separated.distance,
                                       routed: true, extractionSeconds: elapsed,
                                       extractedAudio: nil))
        }

        // Only `.enforce` lets an extraction change a verdict. Observe records the
        // counterfactual and leaves the gate's own decision in the timeline.
        let enforcing = TSEConfig.mode == .enforce
        let appended = results.map { r in
            GatedSpan(start: r.start, end: r.end,
                      verdict: enforcing ? r.effectiveVerdict : r.verdictMixed,
                      distance: enforcing ? (r.distanceSeparated ?? r.distanceMixed)
                                          : r.distanceMixed)
        }

        var timeline = currentTimeline
        // Drop anything overlapping the window we just re-judged, so the overlap
        // refines a verdict instead of leaving a stale one in front of it.
        timeline.removeAll { $0.endSeconds > absoluteOffsetSeconds && $0.startSeconds < windowEnd }
        timeline.append(contentsOf: appended)
        timeline.sort { $0.start < $1.start }
        let cutoff = windowEnd - retainSeconds
        if cutoff > 0 { timeline.removeAll { $0.endSeconds < cutoff } }
        replaceTimeline(timeline)

        for r in results {
            let d = r.distanceMixed.map { String(format: "%.3f", $0) } ?? "  -  "
            if r.routed {
                let ds = r.distanceSeparated.map { String(format: "%.3f", $0) } ?? "  -  "
                print(String(format: "[TSE/live] %6.2f–%6.2fs  d %@ -> %@  %@ -> %@  (%.2fs)%@",
                             r.startSeconds, r.endSeconds, d, ds,
                             r.verdictMixed.rawValue, r.effectiveVerdict.rawValue,
                             r.extractionSeconds,
                             enforcing ? "" : "   [observe: text unchanged]"))
            } else {
                print(String(format: "[Gate/live] %6.2f–%6.2fs (%.1fs)  d %@  %@",
                             r.startSeconds, r.endSeconds, r.durationSeconds, d,
                             r.verdictMixed.rawValue))
            }
        }
        return results
    }

    /// The span covering a timestamp, or nil when the gate has not reached it.
    /// Exposed so the segment filter can log WHY a line passed — "no span covers
    /// this" and "a span accepted this" are different failures with different fixes.
    func coveringSpan(atSeconds t: Double) -> GatedSpan? {
        currentTimeline.first { t >= $0.startSeconds && t < $0.endSeconds }
    }
}
