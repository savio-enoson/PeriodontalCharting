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
//  clean audio never reaches the extractor, so Gate 1 is moot BY CONSTRUCTION.
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
    /// tiled silence — a distance measured on near-silence is meaningless.
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
        /// because the microphone level swings widely between sessions AND between
        /// PEOPLE — a softly-spoken clinician sits far below whatever the first
        /// tester happened to measure.
        static let speechFloorMultiple: Float = 3.0

        /// Absolute minimum, so a dead-quiet room cannot promote its own hiss.
        /// WAS 0.01, which sat ABOVE `noiseFloor * 3` on every real recording
        /// (floors measure 0.003–0.006), so the adaptive threshold never actually
        /// adapted downward — the only direction a quiet voice needs.
        static let absoluteFloor: Float = 0.003

        /// Loud frames must be at least this many times the noise floor before we
        /// believe there is speech at all. Room hiss has almost no contrast; speech
        /// has a lot. This is the "don't promote hiss" guard done by CONTRAST, so
        /// it cannot exclude someone merely for being quiet. Healthy sessions
        /// measure 14–50x; a soft calibration take measured 5.4x.
        static let minDynamicRange: Float = 3.0

        /// Gap that still counts as one span. 0.35 s was shorter than the pause
        /// inside ordinary dictation ("dua … dua … dua"), so every number became
        /// its own sub-second span.
        ///
        /// HOW TO SPOT IT GOING WRONG: a long `accept` span in `[Gate/live]`
        /// sitting exactly where you know two people were talking.
        static let maxGapSeconds = 0.6

        /// Matches `SpeakerGate.inputSamples` (3.0 s). Longer input is
        /// CENTRE-CROPPED by the embedder, so joining past this loses the edges —
        /// and `speechSeconds` would then be measuring audio the embedder never
        /// sees.
        static let maxSpanSeconds = 3.0

        /// SECONDS OF ACTUAL VOICE a span must contain to be worth judging.
        ///
        /// THIS IS THE QUALIFICATION, and measuring it in VOICE rather than in
        /// span-seconds is what makes it safe. Three earlier rules — 1.0 s of span,
        /// then 1.5 s, then a 30% speech-fraction floor — could all be satisfied by
        /// padding a short utterance out with silence, which is exactly what
        /// growing does for free.
        ///
        /// 0.9 s, DOWN from 1.2. The higher value was set while distance still
        /// tracked speech content steeply (1.7 s -> 0.72, 2.4 s -> 0.39), so short
        /// spans genuinely could not be trusted. Matching enrollment segmentation
        /// to this segmenter flattened that curve: measured 2026-08-06 after the
        /// change, 1.2 s -> 0.579 and 2.8 s -> 0.430, with everything between
        /// sitting inside 0.32–0.58. The bias 1.2 was protecting against is gone.
        ///
        /// What 1.2 WAS costing: dictated numbers. "dua … dua … dua" is three
        /// ~0.3 s bursts separated by pauses — about 1.0–1.2 s of voice in total,
        /// landing just under the bar. Every number run in that session went thin,
        /// fell through to a blind window, and was held off the chart permanently
        /// while the surrounding sentences went through. The app lost exactly the
        /// values it exists to record.
        static let minSpeechSeconds = 0.9

        /// The EMBEDDER's own floor — `SpeakerGate.classify` returns `.tooShort`
        /// below this, so a span must reach it just to be evaluated at all.
        ///
        /// Deliberately NOT the qualification. Its only job is to stop a span that
        /// already has enough voice from being rejected on a technicality: 1.0 s of
        /// dense dictation is fine, 1.0 s of padding is not, and only
        /// `minSpeechSeconds` can tell those apart.
        static let embedderMinSeconds = SpeakerGate.minDurationSeconds
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
    /// Silero is non-functional on this device (`journal.md` §10: peak probability
    /// 0.005 on speech at amplitude 0.597). Its probability is still logged on the
    /// no-verdict path so a future fix, or a regression, is visible.
    ///
    /// INTERNAL, not private: `enrollmentSelection` calls this too. Templates and
    /// the spans measured against them MUST come out of the same segmenter, or the
    /// embedder's duration artefact turns the difference into apparent distance.
    ///
    /// THE PIPELINE, and what each stage is for:
    ///
    ///     frames above threshold      raw candidate spans
    ///       -> mergeSpans             bridge normal dictation pauses
    ///       -> coalesceThinSpeech     JOIN until each holds enough VOICE
    ///       -> growToEmbedderFloor    reach the embedder's 1.0 s hard minimum
    ///       -> speech-content filter  DROP anything still short on voice
    ///
    /// EVERY STAGE MEASURES VOICE, NOT DURATION. That distinction is the whole
    /// lesson of this file: growing can manufacture length out of silence for
    /// free, so any rule phrased in seconds-of-span can be satisfied by padding.
    ///
    /// - Parameter allowBlindWindows: fall back to fixed 3 s blocks when energy
    ///   segmentation finds nothing. ENROLLMENT ONLY — on the live path they are
    ///   actively harmful, see the fallback block below.
    func rescueSpans(in audio: [Float],
                     allowBlindWindows: Bool = false) -> (spans: [SpeechSegment], fromFallback: Bool) {
        let sr = SpeakerGate.sampleRate
        let hop = sr / 100 * 3                        // 30 ms frames
        let seconds = Double(audio.count) / Double(sr)
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

        // 20th percentile as the noise floor, 90th as "the loud part". Both are
        // robust whether the window is mostly speech or mostly silence.
        let ordered = frameLevels.sorted()
        let noiseFloor = ordered[min(ordered.count - 1, ordered.count / 5)]
        let loudLevel  = ordered[min(ordered.count - 1, ordered.count * 9 / 10)]

        // CONTRAST, not level — behaves identically for a loud voice and a quiet one.
        let dynamicRange: Float = noiseFloor > 1e-6 ? loudLevel / noiseFloor : 0
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

        // Merge with NO minimum-duration filter — nothing is dropped for length
        // until the very end, where we can say why.
        let merged = Self.mergeSpans(raw,
                                     totalSamples: audio.count,
                                     maxGapSeconds: RescueTuning.maxGapSeconds,
                                     minDurationSeconds: 0,
                                     maxDurationSeconds: RescueTuning.maxSpanSeconds)

        // JOIN until each span holds enough VOICE. Two short neighbours are almost
        // always one utterance broken by a dictation pause; joining them yields
        // real speech, while growing each separately yields padding.
        let joined = Self.coalesceThinSpeech(merged,
                                             frameLevels: frameLevels,
                                             frameSamples: hop,
                                             threshold: threshold,
                                             minSpeechSeconds: RescueTuning.minSpeechSeconds,
                                             maxSpanSeconds: RescueTuning.maxSpanSeconds)

        // Reach the embedder's hard 1.0 s floor. A technicality, NOT a
        // qualification — a span that already has enough voice must not be thrown
        // away for being compact.
        let grown = Self.growToEmbedderFloor(joined,
                                             totalSamples: audio.count,
                                             minSeconds: RescueTuning.embedderMinSeconds)

        // The one test that matters: is there enough VOICE here to identify
        // someone? A span padded out with silence gives the embedder a fingerprint
        // of silence, which sits ~0.9 from any centroid — an authoritative-looking
        // reject built on nothing.
        let embedderFloor = Int(RescueTuning.embedderMinSeconds * Double(sr))
        var usable: [SpeechSegment] = []
        var thin = 0
        for span in grown {
            let spanSeconds = Double(span.end - span.start) / Double(sr)
            let speech = Self.speechSeconds(of: span,
                                            frameLevels: frameLevels,
                                            frameSamples: hop,
                                            threshold: threshold)
            let fraction = spanSeconds > 0 ? speech / spanSeconds : 0

            guard span.end - span.start >= embedderFloor,
                  speech >= RescueTuning.minSpeechSeconds else {
                thin += 1
                print(String(format: "[Gate]   thin  %5.2f–%5.2fs — %.1fs span, %.1fs speech (%.0f%%) "
                             + "— not enough voice to identify",
                             Double(span.start) / Double(sr), Double(span.end) / Double(sr),
                             spanSeconds, speech, fraction * 100))
                continue
            }

            usable.append(span)
            print(String(format: "[Gate]   keep  %5.2f–%5.2fs — %.1fs span, %.1fs speech (%.0f%%)",
                         Double(span.start) / Double(sr), Double(span.end) / Double(sr),
                         spanSeconds, speech, fraction * 100))
        }

        if !usable.isEmpty {
            print(String(format: "[Gate] energy: floor %.4f thr %.4f range %.1fx | "
                         + "raw %d -> merge %d -> join %d -> keep %d (thin %d)",
                         noiseFloor, threshold, dynamicRange,
                         raw.count, merged.count, joined.count, usable.count, thin))
            return (usable, false)
        }

        // Nothing usable. Name WHICH cause — they need different fixes.
        if raw.isEmpty {
            if dynamicRange < RescueTuning.minDynamicRange {
                print(String(format: "[Gate] SILENT %.1fs — no contrast (floor %.4f, loud %.4f, "
                             + "range %.1fx < %.1fx). Genuinely nothing said.",
                             seconds, noiseFloor, loudLevel,
                             dynamicRange, RescueTuning.minDynamicRange))
            } else {
                print(String(format: "[Gate] TOO QUIET %.1fs — contrast %.1fx but no frame above "
                             + "thr %.4f (floor %.4f, loud %.4f). This speaker needs gain.",
                             seconds, dynamicRange, threshold, noiseFloor, loudLevel))
            }
        } else {
            print(String(format: "[Gate] THIN %.1fs — %d raw span(s) found but none reached %.1fs of "
                         + "VOICE even after joining (floor %.4f, thr %.4f, range %.1fx). "
                         + "Brief blips, not dictation.",
                         seconds, raw.count, RescueTuning.minSpeechSeconds,
                         noiseFloor, threshold, dynamicRange))
        }

        let sileroPeak = vad.speechProbabilities(audio).max() ?? 0

        // NO BLIND WINDOWS ON THE LIVE PATH.
        //
        // They were meant to keep coverage from having holes. Under the buffer that
        // reasoning INVERTS: a blind window COVERS the timestamp, so `nearestSpan`
        // returns it and stops looking — text that could have inherited a real
        // neighbour's verdict inherits an untrustworthy one instead, and
        // `SpeakerVerdict` correctly maps it to `pending`, holding it forever
        // because nothing ever re-judges a span.
        //
        // Measured 2026-08-06, a 19-span dictation session: ALL 5 rejects and the
        // only confirm were blind windows, rms 0.004–0.053 — near-silence. ZERO
        // real spans failed. And the text at 5.89 s was held by a blind span while
        // a real `accept` ended at 5.94 s, 0.05 s away, which would have covered it.
        // Every dictated number in that session was lost this way.
        //
        // Returning nothing leaves a genuine gap, which is exactly what
        // `nearestSpan`'s 1.5 s tolerance exists for. A gap inherits from real
        // speech; a blind window blocks that.
        guard allowBlindWindows else {
            print(String(format: "[Gate]   no verdict for this window (silero %.3f) — "
                         + "nearby text will inherit from a real neighbour", sileroPeak))
            return ([], true)
        }

        // ENROLLMENT ONLY. A calibration file that segments badly must still yield
        // templates, or the clinician cannot set the app up at all — and unlike the
        // live path there is a human present who can be told to re-record. The
        // warning in `enrollmentSelection` fires when this happens.
        let window = SpeakerGate.inputSamples
        guard audio.count >= window else {
            print(String(format: "[Gate]   window too short for a blind pass (silero %.3f)",
                         sileroPeak))
            return ([], true)
        }
        var windows: [SpeechSegment] = []
        var start = 0
        while start + window <= audio.count {
            windows.append(SpeechSegment(start: start, end: start + window))
            start += window
        }
        print(String(format: "[Gate]   -> %d blind window(s), silero %.3f — DISTRUST these distances",
                     windows.count, sileroPeak))
        return (windows, true)
    }

    /// Seconds of ABOVE-THRESHOLD audio inside a span.
    ///
    /// The only honest answer to "is there enough here to identify someone?".
    /// Span LENGTH cannot answer it — growing manufactures length out of silence
    /// for free, which is how three successive duration-based rules (1.0 s, then
    /// 1.5 s, then a 30% fraction floor) all let padding through.
    private static func speechSeconds(of span: SpeechSegment,
                                      frameLevels: [Float],
                                      frameSamples: Int,
                                      threshold: Float) -> Double {
        let first = max(0, span.start / frameSamples)
        let last  = min(frameLevels.count, (span.end + frameSamples - 1) / frameSamples)
        guard last > first else { return 0 }
        var above = 0
        for k in first..<last where frameLevels[k] > threshold { above += 1 }
        return Double(above) * Double(frameSamples) / Double(SpeakerGate.sampleRate)
    }

    /// Join neighbouring spans until each holds `minSpeechSeconds` of VOICE, as
    /// long as the result still fits the embedder's 3 s window.
    ///
    /// The test is speech content, not duration — joining a thin span to its
    /// neighbour adds real voice, whereas growing it adds only the silence in
    /// between. Repeats until nothing more can be joined, so a run of dictated
    /// numbers collapses into one judgeable span rather than several thin ones.
    ///
    /// Capped at `maxSpanSeconds` because `SpeakerGate` centre-crops longer input:
    /// past 3 s the embedder would see less than `speechSeconds` measured.
    private static func coalesceThinSpeech(_ spans: [SpeechSegment],
                                           frameLevels: [Float],
                                           frameSamples: Int,
                                           threshold: Float,
                                           minSpeechSeconds: Double,
                                           maxSpanSeconds: Double) -> [SpeechSegment] {
        guard spans.count > 1 else { return spans }
        let maxLen = Int(maxSpanSeconds * Double(SpeakerGate.sampleRate))

        var out = spans.sorted { $0.start < $1.start }
        var didJoin = true
        while didJoin, out.count > 1 {
            didJoin = false
            var i = 0
            while i < out.count - 1 {
                let a = out[i], b = out[i + 1]
                let aSpeech = speechSeconds(of: a, frameLevels: frameLevels,
                                            frameSamples: frameSamples, threshold: threshold)
                let bSpeech = speechSeconds(of: b, frameLevels: frameLevels,
                                            frameSamples: frameSamples, threshold: threshold)
                let eitherThin = aSpeech < minSpeechSeconds || bSpeech < minSpeechSeconds
                let combined = b.end - a.start
                if eitherThin, combined <= maxLen {
                    out[i] = SpeechSegment(start: a.start, end: b.end)
                    out.remove(at: i + 1)
                    didJoin = true
                } else {
                    i += 1
                }
            }
        }
        return out
    }

    /// Stretch a span to the embedder's hard 1.0 s minimum, below which
    /// `SpeakerGate.classify` returns `.tooShort` and refuses to answer.
    ///
    /// PURELY A TECHNICALITY. This does not make a span worth judging — the
    /// speech-content filter decides that, afterwards. Its only job is to stop
    /// 0.9 s of dense dictation being discarded for being compact.
    ///
    /// Growth is symmetric where there is room and stops at the audio bounds and
    /// at the neighbouring span, so two separate spans can never be grown into
    /// each other.
    private static func growToEmbedderFloor(_ spans: [SpeechSegment],
                                            totalSamples: Int,
                                            minSeconds: Double) -> [SpeechSegment] {
        guard !spans.isEmpty else { return [] }
        let minLen = Int(minSeconds * Double(SpeakerGate.sampleRate))
        var out = spans.sorted { $0.start < $1.start }

        for i in out.indices {
            let length = out[i].end - out[i].start
            guard length < minLen else { continue }
            let needed = minLen - length

            let lowerBound = (i == 0) ? 0 : out[i - 1].end
            let upperBound = (i == out.count - 1) ? totalSamples : out[i + 1].start
            let roomLeft  = max(0, out[i].start - lowerBound)
            let roomRight = max(0, upperBound - out[i].end)

            // Split the need evenly, then spend whatever one side cannot take on
            // the other — a span at the very start grows entirely rightward.
            var growLeft  = needed / 2
            var growRight = needed - growLeft
            if growLeft > roomLeft {
                growRight = min(roomRight, growRight + (growLeft - roomLeft))
                growLeft = roomLeft
            }
            if growRight > roomRight {
                growLeft = min(roomLeft, growLeft + (growRight - roomRight))
                growRight = roomRight
            }

            out[i].start -= growLeft
            out[i].end   += growRight
        }
        return out
    }

    /// Verdict to install in the timeline. Only `.enforce` lets an extraction
    /// change it; observe records the counterfactual and leaves the gate's own
    /// decision in place.
    ///
    /// `fromFallback` rides along so `SpeakerVerdict` can map blind-window spans to
    /// `pending`. On the live path there are no longer any such spans, but the
    /// batch and enrollment paths can still produce them.
    private static func timelineSpan(_ r: RescuedSpan,
                                     enforcing: Bool,
                                     fromFallback: Bool) -> GatedSpan {
        GatedSpan(start: r.start, end: r.end,
                  verdict: enforcing ? r.effectiveVerdict : r.verdictMixed,
                  distance: enforcing ? (r.distanceSeparated ?? r.distanceMixed)
                                      : r.distanceMixed,
                  fromFallback: fromFallback)
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
            replaceTimeline(results.map {
                Self.timelineSpan($0, enforcing: true, fromFallback: fromFallback)
            })
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
    /// OVERLAPPING WINDOWS, not disjoint slices: short adjacent chunks destroy
    /// exactly the spans they are meant to judge.
    ///
    /// Windows with no judgeable speech contribute NOTHING to the timeline — no
    /// blind windows — so the gap stays open for `nearestSpan` to bridge.
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
        let fresh = results
            .map { Self.timelineSpan($0, enforcing: enforcing, fromFallback: fromFallback) }
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
    /// Energy segmentation leaves gaps — between spans, and where one was dropped
    /// for being thin on voice — and Whisper happily produces text inside them.
    /// Inheriting the nearest verdict means mid-utterance gaps take the verdict of
    /// the speech around them; only text with no real span within `tolerance` is
    /// left `pending`, and under the buffer that holds it off the chart rather
    /// than failing open.
    ///
    /// THIS TOLERANCE IS NOW LOad-BEARING. With blind windows gone, it is the only
    /// thing bridging a dictated number burst to the sentence either side of it.
    /// Raise it if numbers are still being held; lower it if a verdict is carrying
    /// across a speaker change.
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
    /// SOURCE nrg (energy-segmented, trustworthy) or win (blind fallback — only
    /// possible on the enrollment path now), then the distance and its margin.
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
