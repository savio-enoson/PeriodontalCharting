//
//  GatedAudioProcessor.swift
//  PeriodontalCharting
//
//  Feeds WhisperKit GAIN-CORRECTED, SPEAKER-GATED audio instead of raw microphone
//  audio.
//
//  `AudioStreamTranscriber` does not own the microphone — TranscriptionViewModel
//  hands it an `AudioProcessing`. Swapping in this wrapper puts automatic gain and
//  the speaker gate UPSTREAM of Whisper without touching a line of the windowing
//  code (confirmed/unconfirmed tracking, clipTimestamps, finalizeOnSilence,
//  maxRetainedAudioSeconds). That code is where the biased-vocabulary runaway
//  lives; this deliberately stays out of it.
//
//  WHAT IT DOES:
//    1. AUTOMATIC GAIN, so Whisper gets consistent levels from any speaker.
//    2. Judges each chunk with the speaker gate, at pause boundaries.
//    3. SILENCES audio the gate says is somebody else, before Whisper hears it.
//    4. Fills the gate timeline, so the text-side buffer keeps working unchanged
//       — and the polling monitor becomes unnecessary.
//
//  WHAT IT DELIBERATELY DOES NOT DO: separate overlapping speech. `useExtractor`
//  is false. Measured across four sessions the extractor moved almost every
//  routed span AWAY from the enrolled speaker, and on 2026-08-06 it pulled a
//  wrong-speaker span from 0.851 to 0.763 — into the band that would have put
//  another person's words on a chart. Passing `nil` for the extractor also skips
//  ~1 s of work per routed span. Flip it only with evidence from a real
//  two-speaker OVERLAP recording, which does not exist yet.
//
//  THREE RULES, and breaking any of them desyncs every timestamp silently:
//
//  1. NEVER CHANGE THE LENGTH. `processed` mirrors `raw` sample for sample.
//     Rejected speech becomes silence IN PLACE.
//
//  2. ONLY PUBLISH JUDGED AUDIO. `judgedCount` is a watermark into `raw`. Whisper
//     therefore lags the microphone by the gate's latency — that is intended:
//     judge first, then transcribe. `AudioStreamTranscriber` handles a slow buffer
//     natively; it just sleeps.
//
//  3. CUT AT PAUSES. The chunk boundary is pulled back to the last quiet frame so
//     a word is never split across two judgements. If nothing is quiet for
//     `maxHoldSeconds`, cut anyway rather than stall.
//
//  Only regions with a CONFIRMED `notMatched` verdict are silenced. Gaps, thin
//  spans and unjudged regions pass through untouched — they are mostly silence,
//  and the text-side buffer is the second line of defence for anything that is not.
//

import Accelerate
import AVFoundation
import CoreML
import Foundation
import WhisperKit

final class GatedAudioProcessor: AudioProcessing, @unchecked Sendable {

    // MARK: Tuning

    /// Don't judge the newest audio — a span there may still be growing.
    private static let tailGuardSeconds = 1.0
    /// Smallest region worth a pass.
    private static let minChunkSeconds = 2.0
    /// Cut even without a pause after this much pending audio, so continuous
    /// speech cannot stall the transcriber indefinitely.
    private static let maxHoldSeconds = 6.0
    /// A 30 ms frame quieter than this counts as a pause.
    private static let quietRMS: Float = 0.01
    /// How often to look for work.
    private static let pumpIntervalNanos: UInt64 = 400_000_000

    /// Run the target-speaker extractor on routed spans. SEE THE HEADER — false on
    /// purpose, and it should stay false without new evidence.
    static var useExtractor = false

    // MARK: Collaborators

    private let inner = AudioProcessor()
    private let gate: SpeakerGateService

    // MARK: State (all behind `lock`)

    private let lock = NSLock()
    /// Everything the microphone produced, AFTER gain, from the current origin.
    private var raw: [Float] = []
    /// Judged audio: `raw[0..<judgedCount]` with rejected regions silenced.
    private var processed: ContiguousArray<Float> = []
    /// Per-100 ms energy over `processed`, kept in lockstep so `isVoiceDetected`
    /// indexes the same audio Whisper is about to see.
    private var energy: [Float] = []
    /// How much of `raw` has been decided.
    private var judgedCount = 0
    /// Samples dropped off the front by `purgeAudioSamples`, so absolute stream
    /// time survives trimming.
    private var droppedSamples = 0
    private var downstream: (([Float]) -> Void)?
    private var autoGain = AutoGain()
    
    /// One instance per stream; IIR state must not be shared.
    private var highPass = HighPassFilter()

    private var pump: Task<Void, Never>?

    init(gate: SpeakerGateService) {
        self.gate = gate
    }

    /// Gain-corrected microphone audio, before gating. What the gate itself judges.
    var rawSamples: [Float] {
        lock.lock(); defer { lock.unlock() }
        return raw
    }

    /// Current auto-gain multiplier, for the logs.
    var currentGain: Float {
        lock.lock(); defer { lock.unlock() }
        return autoGain.gain
    }

    // MARK: - AudioProcessing: the three that carry real logic

    var audioSamples: ContiguousArray<Float> {
        lock.lock(); defer { lock.unlock() }
        return processed
    }

    var relativeEnergy: [Float] {
        lock.lock(); defer { lock.unlock() }
        return energy
    }

    func purgeAudioSamples(keepingLast keep: Int) {
        lock.lock(); defer { lock.unlock() }
        guard processed.count > keep else { return }
        let drop = processed.count - keep
        processed.removeFirst(drop)
        // `raw` and `judgedCount` MUST move by the same amount or every subsequent
        // span offset is wrong.
        raw.removeFirst(min(drop, raw.count))
        judgedCount = max(0, judgedCount - drop)
        droppedSamples += drop
        let energyDrop = min(energy.count, drop / inner.minBufferLength)
        if energyDrop > 0 { energy.removeFirst(energyDrop) }
    }

    // MARK: - AudioProcessing: lifecycle

    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        lock.lock()
        raw = []; processed = []; energy = []
        judgedCount = 0; droppedSamples = 0
        autoGain.reset()
        highPass.reset()
        downstream = callback
        lock.unlock()

        // The real recorder feeds US; we feed Whisper.
        try inner.startRecordingLive(inputDeviceID: inputDeviceID) { [weak self] buffer in
            self?.ingestRaw(buffer)
        }
        startPump()
        print("[GatedAudio] started — gain on, gate on, extractor \(Self.useExtractor ? "ON" : "off")")
    }

    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        lock.lock(); downstream = callback; lock.unlock()
        try inner.resumeRecordingLive(inputDeviceID: inputDeviceID) { [weak self] buffer in
            self?.ingestRaw(buffer)
        }
        startPump()
    }

    func pauseRecording() {
        pump?.cancel(); pump = nil
        inner.pauseRecording()
    }

    func stopRecording() {
        pump?.cancel(); pump = nil
        inner.stopRecording()
        // Final sweep so the tail is judged and published rather than discarded.
        judgePending(force: true)
        print(String(format: "[GatedAudio] stopped — final gain %.2fx", currentGain))
    }

    // MARK: - The pump

    private func ingestRaw(_ buffer: [Float]) {
        var scaled = buffer
        lock.lock()
        // Rumble first: AutoGain measures RMS to decide how much to amplify, and
        // sub-80 Hz energy in that measurement makes it under-amplify the voice.
        highPass.apply(to: &scaled)
        autoGain.apply(to: &scaled)
        raw.append(contentsOf: scaled)
        lock.unlock()
    }

    private func startPump() {
        pump?.cancel()
        pump = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pumpIntervalNanos)
                guard let self else { return }
                self.judgePending(force: false)
            }
        }
    }

    /// Judge as much pending audio as is safe, and publish the result.
    private func judgePending(force: Bool) {
        let sr = SpeakerGate.sampleRate

        lock.lock()
        let pendingStart = judgedCount
        let available = raw.count - pendingStart
        let guardSamples = force ? 0 : Int(Self.tailGuardSeconds * Double(sr))
        let usable = available - guardSamples
        guard usable >= (force ? sr : Int(Self.minChunkSeconds * Double(sr))) else {
            lock.unlock(); return
        }
        let region = Array(raw[pendingStart ..< pendingStart + usable])
        let absoluteOffset = Double(droppedSamples + pendingStart) / Double(sr)
        let base = droppedSamples + pendingStart
        lock.unlock()

        // Pull the boundary back to a pause so a word is never split. Past
        // maxHoldSeconds, cut regardless — a stalled buffer is worse.
        var cut = region.count
        if !force, Double(region.count) / Double(sr) < Self.maxHoldSeconds,
           let quiet = Self.lastQuietBoundary(in: region) {
            cut = quiet
        }
        guard cut >= sr else { return }          // never publish under 1 s
        let chunk = Array(region[0..<cut])

        // Judge it. This ALSO fills the gate timeline, so the text-side buffer in
        // TranscriptionViewModel keeps working unchanged — and the 2-second
        // polling monitor becomes redundant, which is why the view model skips it
        // when this wrapper is in use.
        //
        // `extractor: nil` unless useExtractor. See the header.
        let extractor = Self.useExtractor ? TSEEngine.extractorUnsafe : nil
        let results = (try? gate.appendEvaluation(audio: chunk,
                                                  absoluteOffsetSeconds: absoluteOffset,
                                                  extractor: extractor)) ?? []

        let cleaned = Self.silenceRejected(in: chunk, results: results, baseSample: base)

        lock.lock()
        processed.append(contentsOf: cleaned)
        appendEnergyLocked(for: cleaned)
        judgedCount += cut
        let notify = downstream
        lock.unlock()
        notify?(cleaned)
    }

    /// Index of the start of the last run of quiet frames, or nil if none.
    private static func lastQuietBoundary(in audio: [Float]) -> Int? {
        let frame = SpeakerGate.sampleRate / 100 * 3        // 30 ms
        guard audio.count >= frame * 4 else { return nil }
        var index = audio.count - frame
        while index >= frame {
            var rms: Float = 0
            audio.withUnsafeBufferPointer {
                vDSP_rmsqv($0.baseAddress! + index, 1, &rms, vDSP_Length(frame))
            }
            if rms < quietRMS { return index + frame }
            index -= frame
        }
        return nil
    }

    /// Silence the regions the gate confirmed belong to somebody else.
    /// SAME LENGTH, SAME POSITIONS — always.
    ///
    /// Only `.reject` is silenced. Gaps, thin spans and anything the gate had no
    /// opinion on pass through untouched: they are mostly silence, and silencing
    /// them on a guess would delete the clinician's own words. Whatever slips
    /// through is caught downstream by the text buffer, which holds anything
    /// without a verdict off the chart.
    private static func silenceRejected(in chunk: [Float],
                                        results: [RescuedSpan],
                                        baseSample: Int) -> [Float] {
        var out = chunk
        for r in results where r.effectiveVerdict == .reject {
            let lo = max(0, r.start - baseSample)
            let hi = min(chunk.count, r.end - baseSample)
            guard hi > lo else { continue }
            for i in lo..<hi { out[i] = 0 }
            print(String(format: "[GatedAudio] silenced %.2f–%.2fs before Whisper (d %@)",
                         r.startSeconds, r.endSeconds,
                         r.distanceMixed.map { String(format: "%.3f", $0) } ?? "-"))
        }
        return out
    }

    /// Keep `relativeEnergy` aligned with `processed`, using the same formula the
    /// real processor uses, so `AudioProcessor.isVoiceDetected` behaves normally.
    private func appendEnergyLocked(for buffer: [Float]) {
        let step = inner.minBufferLength                 // 100 ms
        var i = 0
        while i + step <= buffer.count {
            let slice = Array(buffer[i..<i+step])
            let minAvg = energy.suffix(relativeEnergyWindow).min() ?? Float.infinity
            energy.append(AudioProcessor.calculateRelativeEnergy(of: slice,
                                                                 relativeTo: minAvg))
            i += step
        }
    }

    // MARK: - AudioProcessing: plain pass-through

    var relativeEnergyWindow: Int {
        get { inner.relativeEnergyWindow }
        set { inner.relativeEnergyWindow = newValue }
    }

    func startStreamingRecordingLive(
        inputDeviceID: DeviceID?
    ) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        inner.startStreamingRecordingLive(inputDeviceID: inputDeviceID)
    }

    func padOrTrim(fromArray audioArray: [Float],
                   startAt startIndex: Int,
                   toLength frameLength: Int) -> (any AudioProcessorOutputType)? {
        inner.padOrTrim(fromArray: audioArray, startAt: startIndex, toLength: frameLength)
    }

    static func loadAudio(fromPath audioFilePath: String,
                          channelMode: ChannelMode,
                          startTime: Double?,
                          endTime: Double?,
                          maxReadFrameSize: AVAudioFrameCount?) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(fromPath: audioFilePath, channelMode: channelMode,
                                     startTime: startTime, endTime: endTime,
                                     maxReadFrameSize: maxReadFrameSize)
    }

    static func loadAudio(at audioPaths: [String],
                          channelMode: ChannelMode) async -> [Result<[Float], Swift.Error>] {
        await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
    }

    static func padOrTrimAudio(fromArray audioArray: [Float],
                               startAt startIndex: Int,
                               toLength frameLength: Int,
                               saveSegment: Bool) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex,
                                      toLength: frameLength, saveSegment: saveSegment)
    }
}
