//
//  SpeakerGateService.swift
//  PeriodontalCharting
//
//  Created by Hans Joachim Wiryonoptutro on 27/07/26.
//
//  Orchestrates speaker gating over an audio buffer: reuses the existing
//  SileroVADEngine to find speech, merges spans into decision-sized windows, and
//  classifies each with SpeakerGate.
//
//  Deliberately knows nothing about WhisperKit or AVAudioEngine — it takes
//  [Float] at 16 kHz. That keeps it usable from the file-based debug harness (no
//  mic, no session ownership conflict) and from the live path once the audio
//  source is wired in.
//

import Foundation

/// A VAD span with a speaker verdict attached. Bounds are in SAMPLES at 16 kHz,
/// matching SpeechSegment.
struct GatedSpan {
    let start: Int
    let end: Int
    let verdict: Verdict
    let distance: Double?

    var startSeconds: Double { Double(start) / Double(SpeakerGate.sampleRate) }
    var endSeconds: Double { Double(end) / Double(SpeakerGate.sampleRate) }
    var durationSeconds: Double { endSeconds - startSeconds }

    /// Text overlapping a rejected span must not reach the parser.
    var passesGate: Bool { verdict == .accept || verdict == .confirm }
}

final class SpeakerGateService: @unchecked Sendable {

    private let gate: SpeakerGate
    private let vad: SileroVADEngine

    /// Most recent evaluation, used by `isTargetSpeaking(atSeconds:)` to gate
    /// Whisper segments by timestamp.
    private let lock = NSLock()
    private var timeline: [GatedSpan] = []

    init(gate: SpeakerGate, vad: SileroVADEngine) {
        self.gate = gate
        self.vad = vad
    }

    var isEnrolled: Bool { gate.isEnrolled }
    var templateCount: Int { gate.templateCount }

    // MARK: - Enrollment

    /// Enroll from a recording. Splits on VAD so a single calibration file yields
    /// several templates — but note they are all ONE acoustic condition. Real
    /// multi-condition enrollment needs audio captured across conditions
    /// (see `enroll(utterances:)`).
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
    /// Stricter than `enroll(fromFile:)`, which enrolls EVERY span, for two reasons:
    ///
    /// * **>= 3 s spans preferred.** `SpeakerGate.inputSamples` is 48_000 — the
    ///   Core ML embedder has a FIXED 3 s input, centre-cropping longer audio and
    ///   ZERO-PADDING shorter. A 1.5 s span is half padding.
    ///
    /// * **Capped per file.** SpeakerGate evicts FIFO past `maxTemplates`, so
    ///   enrolling every span of four takes would silently DELETE take 1 — losing
    ///   exactly the acoustic diversity multi-condition calibration buys.
    func enrollmentUtterances(fromFile url: URL,
                              minSeconds: Double = 3.0,
                              maxPerFile: Int = 4) throws -> [[Float]] {
        let audio = try SpeakerGate.loadSamples(from: url)
        guard !audio.isEmpty else { return [] }

        let spans = Self.mergeSpans(vad.speechTimestamps(audio), totalSamples: audio.count)
        guard !spans.isEmpty else { return [] }

        let minSamples = Int(minSeconds * Double(SpeakerGate.sampleRate))
        // Fall back rather than enrolling nothing — a short take beats a missing condition.
        var eligible = spans.filter { $0.end - $0.start >= minSamples }
        if eligible.isEmpty { eligible = spans }

        return eligible
            .sorted { ($0.end - $0.start) > ($1.end - $1.start) }
            .prefix(maxPerFile)
            .map { Array(audio[$0.start..<$0.end]) }
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
    /// Used to gate Whisper segments by timestamp: a confirmed segment whose time
    /// range falls in a rejected span is somebody else's speech and must not be
    /// parsed into the chart.
    ///
    /// Defaults to `true` when no span covers the time — absence of a gate decision
    /// should not silently discard the clinician's dictation. Failing open means an
    /// occasional imposter word gets through; failing closed would drop real
    /// measurements, which is worse given the clinician is watching the chart.
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

    // MARK: - Span merging

    /// Direct port of `merge_spans` in TSE/src/tse.py.
    ///
    /// Bounds are for the GATE, not for ASR: min 1.0 s because shorter embeddings
    /// are duration-noise dominated, max 6.0 s to bound decision latency. Batch
    /// transcription packs speech into ≤30 s chunks instead — do not share these.
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

        // A single VAD span can already exceed maxLen — continuous background
        // speech fills the silences and the detector returns one enormous span.
        // The merge loop above only prevents JOINING past the cap, it never
        // shortens an over-long input, so without this the gate would make one
        // decision over tens of seconds and segment-level gating would be defeated.
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
