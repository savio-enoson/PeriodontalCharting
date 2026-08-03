//
//  TSERescuePath.swift
//  PeriodontalCharting
//
//  EXTRACTION IS A RESCUE PATH, NOT A FRONT-END.
//
//      mic -> VAD -> mergeSpans -> ECAPA -> d
//        d <  ROUTE_THRESHOLD  -> PASS THROUGH untouched     41/54 bench items
//        d >= ROUTE_THRESHOLD  -> EXTRACTOR -> re-embed      13/54
//                                 -> POST_ACCEPT_THRESHOLD
//
//  Gate 1 ("do no harm") killed every always-on candidate. Under the rescue path
//  clean audio never reaches the extractor, so Gate 1 is moot BY CONSTRUCTION —
//  measured on the bench: `clean controls routed: 0`. Do not "simplify" this
//  into always-on; that is a different, worse system that has been measured.
//
//  Rescue-path bench result: 13 routed, mean SDRi +9.6 dB, 13/13 recovered,
//  0 unsafe promotions, 0 clean controls routed.
//
//  SHIP IN .observe FIRST. Same reasoning as the gate: Silero peaked at 0.41 on
//  this mic and there is no data on how often the rescue path fires in a real
//  clinic. Run one session, read the log, then flip the mode.
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

    var gated: GatedSpan {
        GatedSpan(start: start, end: end,
                  verdict: effectiveVerdict,
                  distance: distanceSeparated ?? distanceMixed)
    }
}

extension SpeakerGateService {

    /// Gate every merged span, sending only the ones the gate does NOT accept to
    /// the extractor, then re-gating the extracted stream.
    ///
    /// Runs inference — call off the main actor. In `.observe` the timeline is
    /// left untouched, so nothing about what reaches the chart changes.
    ///
    /// - Parameter keepAudio: retain the extracted waveform per span. Needed by
    ///   `rebuild(audio:with:)`; costs memory, so off by default.
    @discardableResult
    func evaluateWithRescue(audio: [Float],
                            extractor: TargetSpeakerExtractor?,
                            keepAudio: Bool = false) throws -> [RescuedSpan] {

        let spans = Self.mergeSpans(vad.speechTimestamps(audio), totalSamples: audio.count)
        var results: [RescuedSpan] = []
        results.reserveCapacity(spans.count)

        for span in spans {
            let slice = Array(audio[span.start..<span.end])
            let mixed = (try? gate.classify(slice))
                ?? GateResult(verdict: .tooShort, distance: nil)

            let duration = Double(span.end - span.start) / Double(SpeakerGate.sampleRate)
            let shouldRoute =
                TSEConfig.mode != .off
                && extractor != nil
                && extractor!.isPrepared
                && mixed.verdict != .tooShort
                && (mixed.distance ?? 0) >= TSEConfig.routeThreshold
                && duration >= TSEConfig.minRouteSeconds

            guard shouldRoute, let extractor else {
                results.append(RescuedSpan(start: span.start, end: span.end,
                                           verdictMixed: mixed.verdict,
                                           distanceMixed: mixed.distance,
                                           verdictSeparated: nil,
                                           distanceSeparated: nil,
                                           routed: false,
                                           extractionSeconds: 0,
                                           extractedAudio: nil))
                continue
            }

            let began = CFAbsoluteTimeGetCurrent()
            let extracted = try extractor.extract(slice)
            let elapsed = CFAbsoluteTimeGetCurrent() - began

            // Re-embed with the GATE's encoder (SpeechBrain ECAPA). The
            // extractor's own WeSpeaker encoder lives in a different embedding
            // space and its distances are not comparable to these thresholds.
            let separated = (try? gate.classify(extracted))
                ?? GateResult(verdict: .reject, distance: nil)

            let verdict: Verdict
            if let d = separated.distance {
                verdict = d < TSEConfig.postAcceptThreshold ? .accept
                        : (d < gate.rejectThreshold ? .confirm : .reject)
            } else {
                verdict = .reject
            }

            results.append(RescuedSpan(start: span.start, end: span.end,
                                       verdictMixed: mixed.verdict,
                                       distanceMixed: mixed.distance,
                                       verdictSeparated: verdict,
                                       distanceSeparated: separated.distance,
                                       routed: true,
                                       extractionSeconds: elapsed,
                                       extractedAudio: keepAudio ? extracted : nil))
        }

        Self.log(results, mode: TSEConfig.mode)
        if TSEConfig.mode == .enforce {
            replaceTimeline(results.map(\.gated))
        }
        return results
    }

    /// Splice extracted audio back over the routed spans. This is what a BATCH
    /// transcription path feeds to Whisper.
    ///
    /// The LIVE path cannot use it: WhisperKit's `AudioStreamTranscriber`
    /// captures, VADs, windows and decodes as one unit, and
    /// `audioProcessor.audioSamples` is a READ-ONLY tap. Changing the audio
    /// before Whisper sees it means owning the mic and dropping the native
    /// streamer — whose own comments warn that hand-rolled windowing is what let
    /// the biased-vocabulary runaway reappear.
    static func rebuild(audio: [Float], with results: [RescuedSpan]) -> [Float] {
        var out = audio
        for r in results where r.routed {
            guard let extracted = r.extractedAudio else { continue }
            let n = min(extracted.count, r.end - r.start)
            for i in 0..<n { out[r.start + i] = extracted[i] }
        }
        return out
    }

    private static func log(_ results: [RescuedSpan], mode: TSEConfig.Mode) {
        let routed = results.filter(\.routed)
        let rescued = routed.filter(\.rescued)
        let cost = routed.reduce(0) { $0 + $1.extractionSeconds }
        print(String(format: "[TSE/%@] %d spans | routed %d (%.0f%%) | rescued %d | %.2fs extracting",
                     mode.rawValue, results.count, routed.count,
                     results.isEmpty ? 0 : Double(routed.count) / Double(results.count) * 100,
                     rescued.count, cost))
        for r in results {
            let dMixed = r.distanceMixed.map { String(format: "%.3f", $0) } ?? "  -  "
            if r.routed {
                let dSep = r.distanceSeparated.map { String(format: "%.3f", $0) } ?? "  -  "
                print(String(format: "[TSE]   %6.2f–%6.2fs  d %@ -> %@  %@ -> %@  (%.2fs)%@",
                             r.startSeconds, r.endSeconds, dMixed, dSep,
                             r.verdictMixed.rawValue,
                             r.effectiveVerdict.rawValue, r.extractionSeconds,
                             mode == .observe ? "  [observe: chart unchanged]" : ""))
            } else if r.verdictMixed == .reject && mode == .observe {
                print(String(format: "[TSE]   %6.2f–%6.2fs  d %@  reject, NOT routed "
                             + "(too short or extraction unavailable)",
                             r.startSeconds, r.endSeconds, dMixed))
            }
        }
    }
}
