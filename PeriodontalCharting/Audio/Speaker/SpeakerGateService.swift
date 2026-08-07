//
//  SpeakerGateService.swift
//  PeriodontalCharting
//
//  Created by Hans Joachim Wiryonoptutro on 27/07/26.
//
//  Orchestrates speaker gating over an audio buffer: finds speech, merges spans
//  into decision-sized windows, and classifies each with SpeakerGate.
//
//  Deliberately knows nothing about WhisperKit or AVAudioEngine — it takes
//  [Float] at 16 kHz. That keeps it usable from the file-based debug harness (no
//  mic, no session ownership conflict) and from the live path.
//

import Foundation

/// A speech span with a speaker verdict attached. Bounds are in SAMPLES at
/// 16 kHz, matching SpeechSegment.
struct GatedSpan {
    let start: Int
    let end: Int
    let verdict: Verdict
    let distance: Double?
    /// True when this span came from the blind fixed-window fallback instead of
    /// energy segmentation. journal.md §12: those distances are NOT measurements
    /// — the window may be pure silence — so `SpeakerVerdict` maps them to
    /// `pending` rather than letting them release text to the chart.
    ///
    /// Defaulted so existing call sites compile unchanged.
    var fromFallback: Bool = false

    var startSeconds: Double { Double(start) / Double(SpeakerGate.sampleRate) }
    var endSeconds: Double { Double(end) / Double(SpeakerGate.sampleRate) }
    var durationSeconds: Double { endSeconds - startSeconds }

    /// Text overlapping a rejected span must not reach the parser.
    var passesGate: Bool { verdict == .accept || verdict == .confirm }
}

final class SpeakerGateService: @unchecked Sendable {

    let gate: SpeakerGate
    let vad: SileroVADEngine

    /// Most recent evaluation, used by `nearestSpan(toSeconds:)` to gate Whisper
    /// segments by timestamp.
    private let lock = NSLock()
    private var timeline: [GatedSpan] = []

    init(gate: SpeakerGate, vad: SileroVADEngine) {
        self.gate = gate
        self.vad = vad
    }

    var isEnrolled: Bool { gate.isEnrolled }
    var templateCount: Int { gate.templateCount }

    // MARK: - Enrollment

    /// Enroll from a recording, one template per merged VAD span.
    ///
    /// LEGACY PATH, kept for the file-based debug harness. Prefer
    /// `enrollmentSelection(fromFile:)`, which uses the same segmenter as the live
    /// gate — templates and the spans measured against them must be built to the
    /// same recipe or the embedder's duration artefact shows up as distance.
    @discardableResult
    func enroll(fromFile url: URL) throws -> Int {
        let audio = try SpeakerGate.loadSamples(from: url)
        guard !audio.isEmpty else { return 0 }
        let spans = Self.mergeSpans(vad.speechTimestamps(audio), totalSamples: audio.count)
        let utterances = spans.map { Array(audio[$0.start..<$0.end]) }
        return try gate.enroll(utterances.isEmpty ? [audio] : utterances)
    }

    @discardableResult
    func enroll(utterances: [[Float]]) throws -> Int {
        try gate.enroll(utterances)
    }

    /// Select enrollment templates from one take, budgeted per file.
    ///
    /// USES THE LIVE SEGMENTER. `rescueSpans` is the same code that cuts live
    /// audio — same energy threshold, same joining, same speech-content filter —
    /// so a template and a live span are built to the same recipe and their
    /// embeddings are comparable.
    ///
    /// This replaced Silero-plus-fixed-windows, which on this device always fell
    /// through to 3.0 s blocks of continuous reading (~2.8 s of speech each) while
    /// live dictation produced 1.7–2.4 s. Measured 2026-08-06, one speaker
    /// throughout, distance tracked speech seconds monotonically:
    ///
    ///     2.4 s speech -> d 0.388        1.8 s speech -> d 0.659, 0.678
    ///     1.9 s speech -> d 0.516        1.7 s speech -> d 0.717, 0.726
    ///
    /// The centroid sat in a region no live span could reach, and the shortfall in
    /// speech content read as distance rather than as identity.
    ///
    /// Capped per file because SpeakerGate evicts FIFO past `maxTemplates`, so
    /// enrolling every span of three takes would silently DELETE take 1 — losing
    /// exactly the acoustic diversity multi-condition calibration buys.
    func enrollmentSelection(
        fromFile url: URL,
        minSeconds: Double = 3.0,          // retained for call-site compatibility
        maxPerFile: Int = 4
    ) throws -> (utterances: [[Float]], audioSeconds: Double,
                 totalSpans: Int, eligibleSpans: Int) {

        let audio = try SpeakerGate.loadSamples(from: url)
        let seconds = Double(audio.count) / Double(SpeakerGate.sampleRate)
        guard !audio.isEmpty else { return ([], 0, 0, 0) }

        let (spans, fromFallback) = rescueSpans(in: audio, allowBlindWindows: true)
        guard !spans.isEmpty else {
            print(String(format: "[Enroll] %@: no usable spans in %.1fs",
                         url.lastPathComponent, seconds))
            return ([], seconds, 0, 0)
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
        return (picked, pickedSeconds, spans.count, spans.count)
    }

    /// Convenience wrapper — kept so any caller that only wants the audio is
    /// unaffected.
    func enrollmentUtterances(fromFile url: URL,
                              minSeconds: Double = 3.0,
                              maxPerFile: Int = 4) throws -> [[Float]] {
        try enrollmentSelection(fromFile: url,
                                minSeconds: minSeconds,
                                maxPerFile: maxPerFile).utterances
    }

    func resetEnrollment() {
        gate.resetEnrollment()
        lock.lock(); timeline.removeAll(); lock.unlock()
    }

    // MARK: - Evaluation

    /// Find speech, classify each merged span, and store the result as the current
    /// timeline. Runs inference — call off the main actor.
    @discardableResult
    func evaluate(audio: [Float], adapt: Bool = false) throws -> [GatedSpan] {
        let spans = Self.mergeSpans(vad.speechTimestamps(audio), totalSamples: audio.count)
        var results: [GatedSpan] = []
        results.reserveCapacity(spans.count)

        for span in spans {
            let slice = Array(audio[span.start..<span.end])
            let r = (try? gate.classify(slice, adapt: adapt))
                ?? GateResult(verdict: .tooShort, distance: nil)
            results.append(GatedSpan(start: span.start, end: span.end,
                                     verdict: r.verdict, distance: r.distance))
        }

        lock.lock(); timeline = results; lock.unlock()
        return results
    }

    /// Was the calibrated clinician speaking at this point in the evaluated audio?
    ///
    /// Defaults to `true` when no span covers the time. The LIVE path no longer
    /// uses this — see `SpeakerVerdict`, where absence of a verdict means `pending`
    /// and the chart waits rather than failing open.
    func isTargetSpeaking(atSeconds t: Double) -> Bool {
        lock.lock(); let spans = timeline; lock.unlock()
        guard let hit = spans.first(where: { t >= $0.startSeconds && t < $0.endSeconds }) else {
            return true
        }
        return hit.passesGate
    }

    var currentTimeline: [GatedSpan] {
        lock.lock(); defer { lock.unlock() }
        return timeline
    }
    
    /// Replace the timeline from the rescue path (TSERescue.swift). Separate from
    /// `evaluate` so post-extraction verdicts can be installed without re-running
    /// segmentation and ECAPA over the same audio.
    func replaceTimeline(_ spans: [GatedSpan]) {
        lock.lock(); timeline = spans; lock.unlock()
    }
    
    /// Clear the timeline at the start of a live session.
    ///
    /// Stream time restarts at 0 every session, so the previous session's spans
    /// sit directly on top of this one's timestamps — and because `appendEvaluation`
    /// does not re-judge an overlapping range, a stale verdict also BLOCKS the new
    /// one from ever being recorded. Both effects were observed: a friend-only
    /// session read `covered by 2.55–5.10 accept (d 0.418)`, a span from an earlier
    /// recording of the enrolled speaker.
    func resetTimeline() {
        lock.lock(); timeline = []; lock.unlock()
    }

    // MARK: - Span merging

    /// Direct port of `merge_spans` in TSE/src/tse.py.
    ///
    /// Bounds are for the GATE, not for ASR. Batch transcription packs speech into
    /// <=30 s chunks instead — do not share these.
    ///
    /// `minDurationSeconds` defaults to the embedder's floor but `rescueSpans`
    /// passes 0: nothing is dropped for LENGTH there, because length can be
    /// manufactured out of silence. Only speech content qualifies a span.
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
        // loop above only prevents JOINING past the cap, it never shortens an
        // over-long input, so without this the gate would make one decision over
        // tens of seconds and segment-level gating would be defeated.
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
