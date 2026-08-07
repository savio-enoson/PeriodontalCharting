//
//  GateOnlyCapture.swift
//  PeriodontalCharting
//
//  Microphone feed for gate-only mode.
//
//  Normally WhisperKit's AudioStreamTranscriber owns the microphone and the gate
//  monitor polls `whisper.audioProcessor.audioSamples`. With WhisperKit unloaded
//  there is nothing to poll, so we run the same `AudioProcessor` directly. Same
//  class, same 16 kHz mono output — the gate cannot tell the difference, so span
//  detection and distances are identical to a real session.
//
//  DEBUG ONLY. Owning the microphone is the thing `handoff.md` warns against for
//  the real path, because owning the mic means owning the windowing and
//  hand-rolled windowing is what let the biased-vocabulary runaway reappear. Here
//  nothing is transcribed at all, so there is no windowing to get wrong.
//
//  AudioManager still owns the AVAudioSession — this only installs the tap.
//

import Foundation
import WhisperKit

final class GateOnlyCapture: @unchecked Sendable {

    /// Keep at most this much audio. The gate monitor reconstructs stream time
    /// from the buffer length, so an unbounded buffer still works — it just wastes
    /// memory at ~64 KB per second.
    private static let maxRetainedSeconds = 120.0

    private let processor = AudioProcessor()

    func start() throws {
        try processor.startRecordingLive(inputDeviceID: nil, callback: nil)
        print("[GateOnly] microphone started — no transcription this session")
    }

    func stop() {
        processor.stopRecording()
        print("[GateOnly] microphone stopped")
    }

    /// Current buffer, trimmed to the retention window.
    var samples: [Float] {
        let cap = Int(Self.maxRetainedSeconds * Double(SpeakerGate.sampleRate))
        if processor.audioSamples.count > cap {
            processor.purgeAudioSamples(keepingLast: cap)
        }
        return Array(processor.audioSamples)
    }
}
