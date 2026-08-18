//
//  SpeakerGateService.swift
//  PeriodontalCharting
//
//  Created by Hans Joachim Wiryonoptutro on 27/07/26.
//
//  Orchestrates speaker gating over an audio buffer: finds speech, merges spans
//  into decision-sized windows, and classifies each with SpeakerGate.
//
//  Deliberately knows nothing about the ASR or AVAudioEngine — it takes [Float]
//  at 16 kHz. That keeps it usable from the file-based debug harness (no mic, no
//  session ownership conflict) and from the live path.
//
//  STATELESS. It held a `timeline` of judged spans back when the ASR emitted
//  timestamped segments that had to be looked up after the fact. Wav2Vec emits no
//  timestamps: `gatedAudio` (TSERescue.swift) judges a chunk and returns the audio
//  in the same call, so there is nothing to remember between calls — and nothing
//  to leak from one session into the next, which the timeline did.
//

import Foundation

// Half-open speech span in SAMPLE indices. Lived in SileroVADEngine.swift until
// that engine was removed; it has nothing to do with Silero and everything to do
// with `mergeSpans` and the energy segmenter, which are here.
struct SpeechSegment: Equatable {
    var start: Int
    var end: Int
}

// A speech span with a speaker verdict attached. Bounds are in SAMPLES at
// 16 kHz, matching SpeechSegment.
struct GatedSpan {
    let start: Int
    let end: Int
    let verdict: Verdict
    let distance: Double?

    var startSeconds: Double { Double(start) / Double(SpeakerGate.sampleRate) }
    var endSeconds: Double { Double(end) / Double(SpeakerGate.sampleRate) }
    var durationSeconds: Double { endSeconds - startSeconds }

    // Audio overlapping a rejected span must not reach the ASR.
    var passesGate: Bool { verdict == .accept || verdict == .confirm }
}

// Sendable outright now that the timeline is gone: both stored properties are
// immutable, and each guards its own mutable state internally.
final class SpeakerGateService: Sendable {

    // The embedder, and nothing else. Silero was removed 2026-08-17: it measured
    // 0.001–0.09 on this device (journal.md §10) and the live path never consumed
    // it. While it was a required init parameter, deleting its .mlpackage made
    // `makeSpeakerGateIfNeeded` return nil, enrollment return early in silence,
    // and the ENTIRE speaker filter report itself "off" with no error in the log.
    let gate: SpeakerGate

    init(gate: SpeakerGate) {
        self.gate = gate
    }

    var isEnrolled: Bool { gate.isEnrolled }
    var templateCount: Int { gate.templateCount }

    // MARK: - Enrollment

    @discardableResult
    func enroll(utterances: [[Float]]) throws -> Int {
        try gate.enroll(utterances)
    }

    // Select enrollment templates from one take, budgeted per file.
    //
    // USES THE LIVE SEGMENTER. `rescueSpans` is the same code that cuts live
    // audio — same energy threshold, same joining, same speech-content filter —
    // so a template and a live span are built to the same recipe and their
    // embeddings are comparable.
    //
    // This replaced Silero-plus-fixed-windows, which on this device always fell
    // through to 3.0 s blocks of continuous reading (~2.8 s of speech each) while
    // live dictation produced 1.7–2.4 s. Measured 2026-08-06, one speaker
    // throughout, distance tracked speech seconds monotonically:
    //
    //     2.4 s speech -> d 0.388        1.8 s speech -> d 0.659, 0.678
    //     1.9 s speech -> d 0.516        1.7 s speech -> d 0.717, 0.726
    //
    // The centroid sat in a region no live span could reach, and the shortfall in
    // speech content read as distance rather than as identity.
    //
    // Capped per file because SpeakerGate evicts FIFO past `maxTemplates`, so
    // enrolling every span of three takes would silently DELETE take 1 — losing
    // exactly the acoustic diversity multi-condition calibration buys.
    func enrollmentSelection(fromFile url: URL,
                             maxPerFile: Int = 4) throws -> (utterances: [[Float]],
                                                             audioSeconds: Double,
                                                             totalSpans: Int) {

        let audio = try SpeakerGate.loadSamples(from: url)
        let seconds = Double(audio.count) / Double(SpeakerGate.sampleRate)
        guard !audio.isEmpty else { return ([], 0, 0) }

        let (spans, fromFallback) = rescueSpans(in: audio, allowBlindWindows: true)
        guard !spans.isEmpty else {
            print(String(format: "[Enroll] %@: no usable spans in %.1fs",
                         url.lastPathComponent, seconds))
            return ([], seconds, 0)
        }
        if fromFallback {
            print("[Enroll] \(url.lastPathComponent): energy segmentation found nothing — "
                  + "blind windows. Templates built from these are as untrustworthy as "
                  + "the verdicts journal.md §12 warns about. Re-record this take.")
        }

        // Longest first is a proxy for most speech, and `rescueSpans` has already
        // guaranteed every survivor clears `minSpeechSeconds`.
        let picked = spans
            .sorted { ($0.end - $0.start) > ($1.end - $1.start) }
            .prefix(maxPerFile)
            .map { Array(audio[$0.start..<$0.end]) }

        let pickedSeconds = picked.reduce(0.0) {
            $0 + Double($1.count) / Double(SpeakerGate.sampleRate)
        }
        return (picked, pickedSeconds, spans.count)
    }

    // Convenience wrapper — for callers that only want the audio.
    func enrollmentUtterances(fromFile url: URL, maxPerFile: Int = 4) throws -> [[Float]] {
        try enrollmentSelection(fromFile: url, maxPerFile: maxPerFile).utterances
    }

    func resetEnrollment() {
        gate.resetEnrollment()
    }

    // MARK: - Evaluation

    // Classify every merged VAD span in a buffer. Runs inference — call off the
    // main actor.
    //
    // The DEBUG HARNESS path (SpeakerGateDebugView): same segmenter as the live
    // path but no extractor, so a failure here is unambiguously the embedder's
    // rather than the rescue path's.
    func evaluate(audio: [Float], adapt: Bool = false) throws -> [GatedSpan] {
        let spans = rescueSpans(in: audio).spans
        var results: [GatedSpan] = []
        results.reserveCapacity(spans.count)

        for span in spans {
            let slice = Array(audio[span.start..<span.end])
            let r = (try? gate.classify(slice, adapt: adapt))
                ?? GateResult(verdict: .tooShort, distance: nil)
            results.append(GatedSpan(start: span.start, end: span.end,
                                     verdict: r.verdict, distance: r.distance))
        }
        return results
    }

    // MARK: - Span merging

    // Direct port of `merge_spans` in TSE/src/tse.py.
    //
    // Bounds are for the GATE, not for ASR — do not share these with the decoder.
    //
    // `minDurationSeconds` defaults to the embedder's floor but `rescueSpans`
    // passes 0: nothing is dropped for LENGTH there, because length can be
    // manufactured out of silence. Only speech content qualifies a span.
    static func mergeSpans(
        _ spans: [SpeechSegment],
        totalSamples: Int,
        maxGapSeconds: Double = 1.5,
        minDurationSeconds: Double = SpeakerGate.minDurationSeconds,
        maxDurationSeconds: Double = 6.0
    ) -> [SpeechSegment] {
        guard !spans.isEmpty else { return [] }
        let sr = Double(SpeakerGate.sampleRate)
        let maxGap = Int(maxGapSeconds * sr)
        let minLen = Int(minDurationSeconds * sr)
        let maxLen = Int(maxDurationSeconds * sr)

        let ordered = spans.sorted { $0.start < $1.start }
        var merged: [SpeechSegment] = []
        var cur = ordered[0]

        for span in ordered.dropFirst() {
            let wouldSpan = span.end - cur.start
            if span.start - cur.end <= maxGap && wouldSpan <= maxLen {
                cur.end = max(cur.end, span.end)
            } else {
                merged.append(cur)
                cur = span
            }
        }
        merged.append(cur)

        // A single span can already exceed maxLen — continuous background speech
        // fills the silences and the detector returns one enormous span. The merge
        // loop only prevents JOINING past the cap, it never shortens an over-long
        // input, so without this the gate would make one decision over tens of
        // seconds and span-level gating would be defeated.
        var split: [SpeechSegment] = []
        for seg in merged {
            let length = seg.end - seg.start
            if length <= maxLen {
                split.append(seg)
            } else {
                let parts = Int(ceil(Double(length) / Double(maxLen)))
                let step = length / parts
                for i in 0..<parts {
                    let start = seg.start + i * step
                    let end = (i == parts - 1) ? seg.end : seg.start + (i + 1) * step
                    split.append(SpeechSegment(start: start, end: end))
                }
            }
        }

        return split.compactMap { span in
            var s = span
            s.start = max(0, s.start)
            s.end = min(totalSamples, s.end)
            return (s.end - s.start) >= minLen ? s : nil
        }
    }
}
