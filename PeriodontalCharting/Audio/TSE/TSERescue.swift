//
//  TSERescue.swift
//  PeriodontalCharting
//
//  THE SPEAKER GATE AND THE EXTRACTOR, AS ONE PASS OVER ONE CHUNK.
//
//      energy spans -> ECAPA -> verdict -> extract? -> splice -> silence rejects
//
//  Two decisions live here and they are deliberately separate:
//
//    WHOSE VOICE IS THIS      the verdict, from the gate's SpeechBrain ECAPA
//    WHAT DOES THE ASR HEAR   the audio, which extraction may improve
//
//  Conflating them is the bug this file is shaped to avoid. Under
//  `TSEConfig.coverage == .everySpan` a clean accepted span still goes through
//  the extractor for the ASR's benefit, but its VERDICT is frozen at `accept` —
//  extraction is never allowed to talk the gate out of a speaker it had already
//  identified. See `route(slice:...)`.
//
//  ONE ENTRY POINT: `gatedAudio(for:extractor:)`. Routing, extraction and the
//  splice happen in a single pass, so the extracted waveform cannot be computed
//  and then lost on its way to Wav2Vec — which is exactly what happened when
//  routing and rebuilding were separate calls and the live path passed
//  `keepAudio: false`.
//

import Accelerate
import Foundation

// One span's journey. `distanceSeparated` is nil when the span was never
// extracted — under `.rescueOnly` that is the normal case, not a failure.
struct RescuedSpan {
    let start: Int
    let end: Int
    let verdictMixed: Verdict
    let distanceMixed: Double?
    let verdictSeparated: Verdict?
    let distanceSeparated: Double?
    let routed: Bool
    let extractionSeconds: Double
    // RMS of the span. Distinguishes real speech from a window that tiled
    // silence — a distance measured on near-silence is meaningless.
    let level: Float
    // The separated waveform, kept only when the caller will splice it.
    var extractedAudio: [Float]?

    var startSeconds: Double { Double(start) / Double(SpeakerGate.sampleRate) }
    var endSeconds: Double { Double(end) / Double(SpeakerGate.sampleRate) }
    var durationSeconds: Double { endSeconds - startSeconds }

    // The verdict to act on. Falls back to the mixed verdict when extraction did
    // not produce one — including the frozen-accept case, where it never does.
    var effectiveVerdict: Verdict { verdictSeparated ?? verdictMixed }

    // Cosine SIMILARITY to the centroid — the complement of the distance the
    // thresholds use. 1.0 is identical, 0.0 is orthogonal.
    var similarity: Double? { distanceMixed.map { 1.0 - $0 } }
}

// What the ASR should transcribe, and the spans that decided it.
struct GatedAudio {
    let audio: [Float]
    let spans: [RescuedSpan]
    // False when the segmenter found nothing judgeable. `audio` is then the
    // untouched original — do NOT report that as "everything accepted".
    let judged: Bool
}

extension SpeakerGateService {

    // MARK: - Tuning

    enum RescueTuning {
        // Frames below `noiseFloor * speechFloorMultiple` are silence. RELATIVE,
        // because mic level swings between sessions AND between PEOPLE — a
        // softly-spoken clinician sits far below whatever the first tester
        // happened to measure.
        static let speechFloorMultiple: Float = 3.0

        // Absolute minimum, so a dead-quiet room cannot promote its own hiss.
        // WAS 0.01, which sat ABOVE `noiseFloor * 3` on every real recording
        // (floors measure 0.003–0.006), so the adaptive threshold never adapted
        // downward — the only direction a quiet voice needs.
        static let absoluteFloor: Float = 0.003

        // Loud frames must be this many times the noise floor before we believe
        // there is speech at all. The "don't promote hiss" guard done by
        // CONTRAST, so it cannot exclude someone merely for being quiet. Healthy
        // sessions measure 14–50x; a soft calibration take measured 5.4x.
        static let minDynamicRange: Float = 3.0

        // Gap that still counts as one span. 0.35 s was shorter than the pause
        // inside ordinary dictation ("dua … dua … dua"), so every number became
        // its own sub-second span.
        static let maxGapSeconds = 0.6

        // Matches `SpeakerGate.inputSamples` (3.0 s). Longer input is
        // CENTRE-CROPPED by the embedder, so joining past this loses the edges.
        static let maxSpanSeconds = 3.0

        // SECONDS OF ACTUAL VOICE a span must hold to be worth judging.
        //
        // Measuring VOICE rather than span-seconds is what makes it safe: three
        // earlier rules (1.0 s of span, 1.5 s, a 30% speech-fraction floor) could
        // all be satisfied by padding a short utterance with silence, which is
        // what growing does for free.
        //
        // 1.2 -> 0.9 -> 0.75, each step measured rather than guessed.
        //
        // At 1.2, "dua … dua … dua" — three ~0.3 s bursts, ~1.0–1.2 s of voice —
        // landed just under the bar, and every dictated number in that session
        // was lost.
        //
        // 0.75 SWEPT ON A REAL SESSION (2026-08-14, 19.9 s, two speakers, replayed
        // offline through the shipping models and segmenter):
        //
        //     bar    spans  reach   verdicts
        //     0.90     5     57%    acc×3 rej×2
        //     0.80     6     66%    acc×3 con×1 rej×2
        //     0.75     7     72%    acc×3 con×1 rej×3
        //     0.70     7     72%    unchanged
        //     0.50     7     72%    unchanged
        //
        // Three findings decided it. The span recovered between 0.90 and 0.80 was
        // the CLINICIAN'S OWN (`confirm`), and under strict silencing it was being
        // muted as unattributed — the bar was deleting his speech, not somebody
        // else's. No new `accept` appears at any bar, so lowering it does not
        // start admitting misattributed audio as him. And it SATURATES at 0.75:
        // 0.70, 0.60 and 0.50 are identical, so this is a floor rather than a
        // point on a slope.
        //
        // `var` so the harness can keep sweeping it as more sessions are captured.
        // Ships at 0.75; one session is one session.
        static var minSpeechSeconds = 0.75

        // The EMBEDDER's own floor — `classify` returns `.tooShort` below it.
        // Deliberately NOT the qualification: its only job is to stop a span that
        // already has enough voice from being rejected on a technicality.
        static let embedderMinSeconds = SpeakerGate.minDurationSeconds
    }

    // MARK: - The routing decision (the one that must exist once)

    // Does this span go through the extractor?
    //
    // PURE AND STATIC so the decision table can be tested directly — it is the
    // behaviour the whole layer is configured by, and it reads as four booleans
    // that are easy to get subtly wrong.
    //
    //                     .rescueOnly   .everySpan
    //     accept              no           yes      (audio only — verdict frozen)
    //     confirm             no           yes      (audio only — verdict frozen)
    //     reject              yes          yes
    //     tooShort            no           no
    //
    // `.rescueOnly` routes EXACTLY what the freeze rule lets extraction re-judge,
    // and nothing else. It used to route `confirm` too, on the reading that
    // "anything not accepted might need saving" — but a confirm already passes
    // `passesGate`, so once its verdict is frozen there is no outcome extraction
    // can improve. All it can do is spend ~1 s and hand the decoder the audible
    // masking artefact (measured 5 of 6 spans in one session, ~4.9 s of extraction
    // for zero possible verdict change).
    //
    // `tooShort` never routes under either coverage: it carries no distance, so
    // there is no `d_sep` to check the result against and a rescue would be
    // trusted on nothing. Under the duration floor it is also nearly unreachable,
    // since `minRouteSeconds` equals the embedder's own minimum.
    static func shouldExtract(verdict: Verdict, durationSeconds: Double) -> Bool {
        guard TSEConfig.mode.runsExtractor else { return false }
        guard verdict != .tooShort else { return false }
        guard durationSeconds >= TSEConfig.minRouteSeconds else { return false }
        return TSEConfig.coverage == .everySpan || verdict == .reject
    }

    // Classify one span, and extract it when the coverage policy says to.
    //
    // Re-embedding uses the GATE's encoder (SpeechBrain ECAPA). The extractor's
    // own WeSpeaker ECAPA lives in a different embedding space and its distances
    // are not comparable to these thresholds.
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

        let shouldRoute = Self.shouldExtract(verdict: mixed.verdict, durationSeconds: duration)
            && extractor?.isPrepared == true

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

        // ANYTHING THAT ALREADY PASSES THE GATE IS FROZEN — accept AND confirm.
        //
        // Extraction may improve the audio; it never gets a vote on a verdict
        // that was already going the clinician's way. It only re-judges a span
        // that would otherwise be REJECTED, where the span is lost as things
        // stand and `d_sep` can only be an improvement.
        //
        // THIS ORIGINALLY FROZE ONLY `accept`, on the reasoning that a
        // non-accepted span "has nothing to lose". That was wrong: `passesGate`
        // is `accept || confirm`, so a confirm span already reaches the chart, and
        // re-judging it can only take something away. Measured 2026-08-14, two of
        // the clinician's own quiet spans:
        //
        //     d 0.729 -> 1.039   confirm -> reject
        //     d 0.708 -> 0.882   confirm -> reject
        //
        // Both moved AWAY from his centroid — 1.039 is past orthogonal — and under
        // `.enforce` both would have been silenced. `confirm` is exactly where his
        // softer dictation sits (journal.md §9 measures it at 0.730), so the old
        // rule deleted the quiet half of his own speech.
        guard mixed.verdict == .reject else {
            return RescuedSpan(start: start, end: end,
                               verdictMixed: mixed.verdict,
                               distanceMixed: mixed.distance,
                               verdictSeparated: nil, distanceSeparated: nil,
                               routed: true, extractionSeconds: elapsed,
                               level: level,
                               extractedAudio: keepAudio ? extracted : nil)
        }

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

    // MARK: - Entry point: a chunk, in and out

    // Judge a chunk and hand back the audio Wav2Vec should transcribe.
    //
    // THIS IS THE HANDOFF THE EXTRACTOR EXISTS FOR. Routing, extraction and the
    // splice are one pass over one array, so the separated waveform reaches the
    // returned buffer or the extraction never happened — there is no in-between
    // state where a span was extracted and the result quietly discarded.
    //
    // Runs ECAPA and, on routed spans, the six-model extractor. Call it OFF the
    // main actor.
    //
    // Indices are chunk-relative, which is what the splice needs; the ASR gets a
    // buffer of exactly the input length, so nothing downstream re-times.
    func gatedAudio(for audio: [Float],
                    extractor: TargetSpeakerExtractor?) throws -> GatedAudio {

        let chunkSeconds = Double(audio.count) / Double(SpeakerGate.sampleRate)
        let (spans, fromFallback) = rescueSpans(in: audio)
        guard !spans.isEmpty else {
            // THE WHOLE CHUNK IS UNJUDGED AND PASSES THROUGH INTACT. Say so in
            // seconds, because "no verdict" reads like a small omission and this
            // is the single largest hole in the filter: any voice in here reaches
            // the decoder untouched, whoever it belonged to.
            print(String(format: "[Gate/audio] %.1fs chunk — 0.0s judged, %.1fs UNJUDGED and passed through",
                         chunkSeconds, chunkSeconds))
            return GatedAudio(audio: audio, spans: [], judged: false)
        }

        // `keepAudio` follows the mode: under `.observe` the extractor still runs
        // and still logs, but there is nothing to splice, so the per-span buffer
        // is not retained.
        let mode = TSEConfig.mode
        var results: [RescuedSpan] = []
        results.reserveCapacity(spans.count)
        for span in spans {
            results.append(try route(slice: Array(audio[span.start..<span.end]),
                                     start: span.start, end: span.end,
                                     extractor: extractor,
                                     keepAudio: mode.splicesAudio))
        }

        Self.log(results, mode: mode, fromFallback: fromFallback)
        Self.logAudioLedger(results, chunkSeconds: chunkSeconds, mode: mode)
        guard mode.splicesAudio else {
            return GatedAudio(audio: audio, spans: results, judged: true)
        }
        return GatedAudio(audio: Self.rebuild(audio, applying: results,
                                              silencingRejects: mode.silencesRejects,
                                              silencingUnattributed: TSEConfig.silenceUnattributed),
                          spans: results, judged: true)
    }

    // WHERE DID THE CHUNK'S SECONDS GO — the answer to "why is the other person
    // still audible in the gated track?".
    //
    // Silencing only ever touches a span the gate positively REJECTED. Audio the
    // segmenter never covered — the gaps between spans, spans dropped as `thin`,
    // and whole chunks that produced no verdict — is passed through verbatim by
    // construction. That is deliberate (a filter that muted everything it had not
    // identified would delete the clinician's own quiet dictation), but it means
    // the filter's reach is exactly `judged`, and this line reports it in seconds
    // rather than leaving it to be inferred from span timestamps.
    private static func logAudioLedger(_ results: [RescuedSpan],
                                       chunkSeconds: Double,
                                       mode: TSEConfig.Mode) {
        let judged: Double = results.reduce(0) { $0 + $1.durationSeconds }
        let rejected: Double = results
            .filter { $0.effectiveVerdict == .reject }
            .reduce(0) { $0 + $1.durationSeconds }
        let unjudged: Double = max(0, chunkSeconds - judged)
        let passing: Double = results
            .filter { $0.effectiveVerdict == .accept || $0.effectiveVerdict == .confirm }
            .reduce(0) { $0 + $1.durationSeconds }
        let strict = TSEConfig.silenceUnattributed && mode.silencesRejects
        // Under strict silencing the only audio that survives is what a passing
        // span covers; otherwise everything except an outright reject does.
        let silenced: Double = mode.silencesRejects
            ? (strict ? chunkSeconds - passing : rejected)
            : 0
        let audible: Double = chunkSeconds - silenced
        let reach: Double = chunkSeconds > 0 ? judged / chunkSeconds * 100 : 0

        print(String(format: "[Gate/audio] %.1fs chunk — %.1fs judged (%.0f%% reach), "
                     + "%.1fs silenced%@, %.1fs to the decoder, %.1fs unjudged",
                     chunkSeconds, judged, reach, silenced,
                     strict ? " (strict)" : "", audible, unjudged))
    }

    // Write the extracted waveform over each span, and — only when the mode says
    // so — silence the rejects.
    //
    // PURE AND STATIC so it can be tested without Core ML — this is the step that
    // decides what the ASR actually hears, and it is the one that would fail
    // silently if an index were wrong.
    //
    // `silencingRejects` false is `.extractOnly`: separation is the only thing
    // standing between another voice and the chart. That is a real position to
    // hold, but note what it means here — the reject is still MEASURED, it is
    // just not acted on, so the audio handed back still contains the attenuated
    // interferer that `normalizeAudio` will shortly rescale.
    //
    // Order matters when silencing: a span whose effective verdict is `reject`
    // has its extracted audio written in and THEN zeroed, which is what makes the
    // buffer agree with the log line for that span.
    //
    // Regions BETWEEN spans are left alone. They are the silence the segmenter
    // skipped; zeroing them would manufacture the flatline cliff Wav2VecEngine
    // already pads white noise to avoid. Output length always equals input length,
    // so `Wav2VecEngine`'s `seqLength / 320` frame count stays correct.
    static func rebuild(_ audio: [Float],
                        applying results: [RescuedSpan],
                        silencingRejects: Bool,
                        silencingUnattributed: Bool = false) -> [Float] {
        // Measured on the ORIGINAL chunk, before any span is spliced or silenced,
        // so the fill level describes this room rather than what we did to it.
        let tone = roomTone(audio)

        var out = audio
        for r in results {
            let lo = max(0, r.start), hi = min(r.end, out.count)
            guard hi > lo else { continue }
            if let extracted = r.extractedAudio {
                let n = min(extracted.count, hi - lo)
                for i in 0..<n { out[lo + i] = extracted[i] }
            }
            if silencingRejects, r.effectiveVerdict == .reject {
                for i in lo..<hi { out[i] = tone() }
            }
        }

        // Everything the gate did not attribute to the clinician. Built as a KEEP
        // mask over passing spans rather than by zeroing the complement span by
        // span, because spans can overlap after growing and a subtractive pass
        // would punch holes in audio a neighbour had already claimed.
        guard silencingUnattributed, silencingRejects else { return out }
        var keep = [Bool](repeating: false, count: out.count)
        for r in results where r.effectiveVerdict == .accept || r.effectiveVerdict == .confirm {
            let lo = max(0, r.start), hi = min(r.end, out.count)
            guard hi > lo else { continue }
            for i in lo..<hi { keep[i] = true }
        }
        for i in out.indices where !keep[i] { out[i] = tone() }
        return out
    }

    // ROOM TONE, NOT DIGITAL SILENCE.
    //
    // `Wav2VecEngine` already pads its buffer with white noise rather than zeros,
    // because "padding with pure 0.0 creates a mathematically impossible flatline
    // cliff that corrupts the CNN's forward receptive field, causing the final
    // phoneme of a word to be dropped or destroyed". Strict silencing removes far
    // MORE than the padding does — measured 12.2 s of a 19.9 s chunk — and puts a
    // cliff on both sides of every surviving span rather than one at the end.
    //
    // Filling at the chunk's own noise floor keeps the removal inaudible as a
    // discontinuity while still deleting the words: the decoder sees a room that
    // went quiet, which it has heard in training, instead of a signal that cannot
    // physically exist.
    //
    // The 20th-percentile 30 ms frame RMS — the same floor `rescueSpans` derives
    // its threshold from, so the fill can never rise near the speech bar.
    // Ceiling for the fill. Comfortably under the quietest measured speech (0.05)
    // and above digital silence, so it reads as a room rather than as a cliff.
    static let maxRoomToneRMS: Float = 0.02

    private static func roomTone(_ audio: [Float]) -> () -> Float {
        let hop = SpeakerGate.sampleRate / 100 * 3
        var levels: [Float] = []
        levels.reserveCapacity(max(1, audio.count / hop))
        audio.withUnsafeBufferPointer { buffer in
            var i = 0
            while i + hop <= buffer.count {
                var r: Float = 0
                vDSP_rmsqv(buffer.baseAddress! + i, 1, &r, vDSP_Length(hop))
                levels.append(r)
                i += hop
            }
        }
        let measured = levels.isEmpty
            ? RescueTuning.absoluteFloor
            : levels.sorted()[min(levels.count - 1, levels.count / 5)]

        // CAPPED, because the 20th percentile stops describing the room once the
        // chunk is mostly speech — in a dense one it lands ON speech, and the
        // "silenced" region would come back as full-level noise. Real floors
        // measure 0.009–0.047, real speech 0.05–0.24, so a ceiling here can only
        // ever make the fill quieter than the room, never louder.
        let floor = min(max(measured, 1e-5), Self.maxRoomToneRMS)
        // Uniform noise of RMS `floor`: half-width = floor * sqrt(3).
        let halfWidth = floor * 1.732
        return { Float.random(in: -halfWidth...halfWidth) }
    }

    // MARK: - Segmentation

    // Speech spans to judge — segmented on ENERGY, not Silero.
    //
    // Silero is non-functional on this device (journal.md §10: peak probability
    // 0.005 on speech at amplitude 0.597). Its probability is still logged on the
    // no-verdict path so a future fix, or a regression, is visible.
    //
    // INTERNAL, not private: `enrollmentSelection` calls this too. Templates and
    // the spans measured against them MUST come out of the same segmenter, or the
    // embedder's duration artefact turns the difference into apparent distance.
    //
    //     frames above threshold      raw candidate spans
    //       -> mergeSpans             bridge normal dictation pauses
    //       -> coalesceThinSpeech     JOIN until each holds enough VOICE
    //       -> growToEmbedderFloor    reach the embedder's 1.0 s hard minimum
    //       -> speech-content filter  DROP anything still short on voice
    //
    // EVERY STAGE MEASURES VOICE, NOT DURATION. Growing can manufacture length
    // out of silence for free, so any rule phrased in seconds-of-span can be
    // satisfied by padding.
    //
    // - Parameter allowBlindWindows: fall back to fixed 3 s blocks when energy
    //   segmentation finds nothing. ENROLLMENT ONLY — see the fallback block.
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

        // CONTRAST, not level — identical for a loud voice and a quiet one.
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
        // qualification.
        let grown = Self.growToEmbedderFloor(joined,
                                             totalSamples: audio.count,
                                             minSeconds: RescueTuning.embedderMinSeconds)

        // The one test that matters: is there enough VOICE here to identify
        // someone? A span padded with silence gives the embedder a fingerprint of
        // silence, which sits ~0.9 from any centroid — an authoritative-looking
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
        // Measured 2026-08-06, a 19-span dictation session: ALL 5 rejects and the
        // only confirm were blind windows, rms 0.004–0.053 — near-silence. ZERO
        // real spans failed. Under the current design a blind window would be
        // spliced or SILENCED on the strength of a distance measured on nothing,
        // which is strictly worse than leaving the audio alone.
        guard allowBlindWindows else {
            print(String(format: "[Gate]   no verdict for this chunk (silero %.3f) — "
                         + "audio passes through untouched", sileroPeak))
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

    // Contiguous speech regions for the EXTRACTOR's enrollment, concatenated.
    //
    // NOT `rescueSpans`, and the difference is the point. That segmenter answers
    // "is there enough voice here to IDENTIFY someone?" — it grows spans to the
    // embedder's 1.0 s floor and discards anything under `minSpeechSeconds`,
    // because a span padded with silence gives ECAPA a fingerprint of silence.
    // The extractor asks a different question. It wants FRAMES: 1024 conditioning
    // keys to fill, and `prepareEnrollment` refuses below 10.24 s of them. Feeding
    // it qualified spans would discard most of the material it needs — measured on
    // the real takes, `rescueSpans` keeps 7.2 s out of 22.5 s.
    //
    // So this uses the same energy THRESHOLD and none of the qualification: every
    // above-threshold run, gaps under 0.2 s bridged so a word is not cut at a
    // stop consonant, concatenated in order.
    //
    // PURE AND STATIC — no models, so `TSEEngine` can call it without depending on
    // a constructed gate, and the harness can measure it directly.
    static func concatenatedSpeech(in audio: [Float]) -> [Float] {
        let sr = SpeakerGate.sampleRate
        let hop = sr / 100 * 3                       // 30 ms, as everywhere else
        guard audio.count >= hop * 8 else { return [] }

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
        guard !frameLevels.isEmpty else { return [] }

        let ordered = frameLevels.sorted()
        let noiseFloor = ordered[min(ordered.count - 1, ordered.count / 5)]
        let threshold = max(noiseFloor * RescueTuning.speechFloorMultiple,
                            RescueTuning.absoluteFloor)

        var runs: [SpeechSegment] = []
        var runStart: Int?
        for k in 0...frameLevels.count {
            let isSpeech = k < frameLevels.count && frameLevels[k] > threshold
            if isSpeech, runStart == nil { runStart = k }
            if !isSpeech, let s = runStart {
                runs.append(SpeechSegment(start: s * hop, end: min(k * hop, audio.count)))
                runStart = nil
            }
        }
        guard !runs.isEmpty else { return [] }

        // Bridge only the gaps INSIDE words. The cap is the whole file rather than
        // an unbounded value on purpose: `mergeSpans` computes
        // `Int(maxDurationSeconds * sampleRate)`, and passing
        // `.greatestFiniteMagnitude` there overflows the Int conversion and traps
        // — which would crash the app during enrollment, not in a test.
        //
        // A cap of "longer than the input" means no span is ever split, which is
        // what the extractor wants: an unbroken stretch of reading is the best
        // conditioning material there is.
        let wholeFileSeconds = Double(audio.count) / Double(sr) + 1
        let merged = Self.mergeSpans(runs,
                                     totalSamples: audio.count,
                                     maxGapSeconds: 0.2,
                                     minDurationSeconds: 0,
                                     maxDurationSeconds: wholeFileSeconds)

        var speech: [Float] = []
        speech.reserveCapacity(merged.reduce(0) { $0 + ($1.end - $1.start) })
        for span in merged {
            let lo = max(0, span.start), hi = min(audio.count, span.end)
            if hi > lo { speech.append(contentsOf: audio[lo..<hi]) }
        }
        return speech
    }

    // Seconds of ABOVE-THRESHOLD audio inside a span. The only honest answer to
    // "is there enough here to identify someone?" — span LENGTH cannot answer it,
    // because growing manufactures length out of silence for free.
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

    // Join neighbouring spans until each holds `minSpeechSeconds` of VOICE, as
    // long as the result still fits the embedder's 3 s window.
    //
    // Joining a thin span to its neighbour adds real voice; growing it adds only
    // the silence in between. Repeats until nothing more can be joined, so a run
    // of dictated numbers collapses into one judgeable span.
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

    // Stretch a span to the embedder's hard 1.0 s minimum, below which `classify`
    // returns `.tooShort` and refuses to answer.
    //
    // PURELY A TECHNICALITY — the speech-content filter decides whether a span is
    // worth judging, afterwards. Growth stops at the audio bounds and at the
    // neighbouring span, so two spans can never be grown into each other.
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

    // MARK: - Logging

    // One line per span, then one summary line for the coverage A/B.
    //
    // Reading order: does the LEVEL look like speech, is the SOURCE nrg
    // (energy-segmented, trustworthy) or win (blind fallback — enrollment only),
    // then the distance and its margin.
    private static func log(_ results: [RescuedSpan],
                            mode: TSEConfig.Mode,
                            fromFallback: Bool) {
        let source = fromFallback ? "win" : "nrg"
        for r in results {
            let d = r.distanceMixed
            let dText = d.map { String(format: "%.3f", $0) } ?? " --- "
            let cosText = r.similarity.map { String(format: "%.3f", $0) } ?? " --- "
            // Positive margin = inside the accept region. Negative = how far over.
            let marginText = d.map { String(format: "%+.3f", TSEConfig.postAcceptThreshold - $0) } ?? "  --- "

            if r.routed {
                // A frozen accept has no `d_sep` on purpose — "kept" says the
                // audio was extracted and the verdict was not up for revision.
                let ds = r.distanceSeparated.map { String(format: "%.3f", $0) } ?? "kept "
                print(String(format: "[TSE] %6.2f–%6.2fs (%.1fs) %@ rms %.3f  d %@ -> %@  %@ -> %@  (%.2fs)%@",
                             r.startSeconds, r.endSeconds, r.durationSeconds,
                             source, r.level, dText, ds,
                             r.verdictMixed.rawValue, r.effectiveVerdict.rawValue,
                             r.extractionSeconds,
                             mode == .enforce ? "" : "   [\(mode.rawValue)]"))
            } else {
                print(String(format: "[Gate] %6.2f–%6.2fs (%.1fs) %@ rms %.3f  d %@  cos %@  margin %@  %@",
                             r.startSeconds, r.endSeconds, r.durationSeconds,
                             source, r.level, dText, cosText, marginText,
                             r.verdictMixed.rawValue))
            }
        }

        // The line to compare across an A/B: how much audio Wav2Vec received
        // extracted, and what it cost.
        // EVERY TYPE IS SPELLED OUT. Left to inference, the trailing ternary was
        // boxed as an Int by iOS 26.5's `String(format:)` overlay, which then
        // rejected the whole call at RUNTIME — so the one line the A/B is read
        // from was replaced by a page of NSCocoaErrorDomain 2048 whenever no span
        // was extracted, i.e. exactly on the `rescueOnly` runs it exists to
        // measure. It did not reproduce on macOS; do not "simplify" this back.
        let extracted = results.filter(\.routed)
        let extractedSeconds: Double = extracted.reduce(0) { $0 + $1.durationSeconds }
        let totalSeconds: Double = results.reduce(0) { $0 + $1.durationSeconds }
        let cost: Double = extracted.reduce(0) { $0 + $1.extractionSeconds }
        let rtf: Double = extractedSeconds > 0 ? cost / extractedSeconds : 0
        let extractedCount: Int = extracted.count
        let totalCount: Int = results.count
        print(String(format: "[TSE/cover] %@/%@ — %d/%d span(s), %.1fs of %.1fs extracted, %.2fs spent (rtf %.2f)",
                     mode.rawValue, TSEConfig.coverage.rawValue,
                     extractedCount, totalCount,
                     extractedSeconds, totalSeconds, cost, rtf))

        // THE LINE THE EXPERIMENT TURNS ON. Under `.extractOnly` the gate still
        // judges every span, it just does not act — so this names the spans whose
        // words should NOT appear in the transcript if separation alone is doing
        // the job. Any of them you can read back afterwards is a false negative
        // for the "TSE is enough" hypothesis.
        let rejects = results.filter { $0.effectiveVerdict == .reject }
        if !rejects.isEmpty, !mode.silencesRejects {
            let where_ = rejects
                .map { String(format: "%.2f–%.2fs", $0.startSeconds, $0.endSeconds) }
                .joined(separator: ", ")
            print("[TSE/cover] NOT SILENCED (\(mode.rawValue)): \(rejects.count) rejected span(s) "
                  + "still in the audio at \(where_) — check the transcript for their words")
        }
    }
}
