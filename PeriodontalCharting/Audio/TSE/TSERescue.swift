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

    enum RescueTuning {
        /// Frames below `noiseFloor * speechFloorMultiple` are silence. RELATIVE,
        /// because the microphone level swings widely between sessions (measured
        /// window peaks 0.015 to 0.597).
        static let speechFloorMultiple: Float = 3.0
        /// Absolute minimum, so a dead-quiet room cannot promote its own hiss.
        static let absoluteFloor: Float = 0.01
        /// 0.35 s, not 1.5 s — gating a PERSON, not a CONVERSATION. Offline numbers
        /// came from single-speaker recordings, but in a real room consecutive turns
        /// are well under 1.5 s apart, so the default merge fuses them into one span
        /// whose embedding contains the target — and so reads as the target.
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

    /// Speech spans to judge — segmented on ENERGY, not Silero.
    ///
    /// Silero is non-functional on this device: peak probability 0.005 on speech at
    /// amplitude 0.597, 0.003 at 0.279, and it finds nothing on the calibration file
    /// either — which `SpeakerGate.loadSamples` already peak-normalises, so input
    /// level is not the variable. It loads and predicts; the outputs are simply
    /// wrong. Its probability is still logged on the fallback path so that a future
    /// fix, or a regression, is visible.
    ///
    /// RMS separates speech from silence by ~20x on this hardware (0.053 speech vs
    /// 0.003 silence), so an adaptive energy threshold is strictly more reliable.
    private func rescueSpans(in audio: [Float]) -> (spans: [SpeechSegment], fromFallback: Bool) {
        let hop = SpeakerGate.sampleRate / 100 * 3        // 30 ms frames
        guard audio.count >= hop * 8 else { return ([], true) }

        var frameLevels: [Float] = []
        frameLevels.reserveCapacity(audio.count / hop)
        audio.withUnsafeBufferPointer { buffer in
            var i = 0
            while i + hop <= buffer.count {
                var r: Float = 0
                vDSP_rmsqv(buffer.baseAddress! + i, 1, &r, vDSP_Length(hop))
                frameLevels.append(r)
                i += hop
            }
        }
        guard !frameLevels.isEmpty else { return ([], true) }

        // 20th percentile as the noise floor: robust whether the window is mostly
        // speech or mostly silence.
        let ordered = frameLevels.sorted()
        let noiseFloor = ordered[min(ordered.count - 1, ordered.count / 5)]
        let threshold = max(noiseFloor * RescueTuning.speechFloorMultiple,
                            RescueTuning.absoluteFloor)

        var raw: [SpeechSegment] = []
        var runStart: Int?
        for k in 0...frameLevels.count {
            let isSpeech = k < frameLevels.count && frameLevels[k] > threshold
            if isSpeech, runStart == nil { runStart = k }
            if !isSpeech, let s = runStart {
                raw.append(SpeechSegment(start: s * hop, end: min(k * hop, audio.count)))
                runStart = nil
            }
        }

        let merged = Self.mergeSpans(raw,
                                     totalSamples: audio.count,
                                     maxGapSeconds: RescueTuning.maxGapSeconds,
                                     maxDurationSeconds: RescueTuning.maxSpanSeconds)
        if !merged.isEmpty {
            print(String(format: "[Gate] energy: floor %.4f, threshold %.4f -> %d span(s)",
                         noiseFloor, threshold, merged.count))
            return (merged, false)
        }

        // Nothing above the floor — genuinely quiet, or one steady level throughout.
        // Fall back to fixed windows so coverage never has a hole, and never let
        // that be silent: an empty span list used to return before any logging, and
        // the gate then failed open across an entire session with no trace.
        let seconds = Double(audio.count) / Double(SpeakerGate.sampleRate)
        let sileroPeak = vad.speechProbabilities(audio).max() ?? 0
        let window = SpeakerGate.inputSamples
        guard audio.count >= window else {
            print(String(format: "[Gate] no spans in %.1fs (floor %.4f, silero %.3f), window too short",
                         seconds, noiseFloor, sileroPeak))
            return ([], true)
        }
        var windows: [SpeechSegment] = []
        var start = 0
        while start + window <= audio.count {
            windows.append(SpeechSegment(start: start, end: start + window))
            start += window
        }
        print(String(format: "[Gate] no energy above %.4f in %.1fs (floor %.4f, silero %.3f) — %d blind window(s)",
                     threshold, seconds, noiseFloor, sileroPeak, windows.count))
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
    
    /// The span covering a timestamp, or the nearest one within `tolerance`.
    ///
    /// Energy segmentation leaves gaps — between merged spans, and where
    /// `mergeSpans` drops something under its 1 s floor — and Whisper happily
    /// produces text inside them. Failing open on every gap lets the other speaker
    /// through; failing closed on every gap drops the clinician's own words.
    /// Inheriting the nearest verdict resolves both: mid-utterance gaps take the
    /// verdict of the speech around them, and only the leading edge of a session —
    /// where there is no verdict within 1.5 s — genuinely falls open.
    func nearestSpan(toSeconds t: Double, within tolerance: Double = 1.5) -> GatedSpan? {
        let spans = currentTimeline
        if let hit = spans.first(where: { t >= $0.startSeconds && t < $0.endSeconds }) {
            return hit
        }
        return spans
            .map { span -> (GatedSpan, Double) in
                (span, t < span.startSeconds ? span.startSeconds - t : t - span.endSeconds)
            }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?.0
    }

    // MARK: - Logging

    /// One line per span. Reading order: does the LEVEL look like speech, is the
    /// SOURCE nrg (energy-segmented, trustworthy) or win (blind fallback), then the
    /// distance and its margin.
    private static func log(_ results: [RescuedSpan],
                            tag: String,
                            enforcing: Bool,
                            fromFallback: Bool) {
        let source = fromFallback ? "win" : "nrg"
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
