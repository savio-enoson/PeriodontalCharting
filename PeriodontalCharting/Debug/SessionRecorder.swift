//
//  SessionRecorder.swift
//  PeriodontalCharting
//
//  DEBUG INSTRUMENT. Captures one dictation session as TWO sample-aligned WAVs:
//  what the microphone heard, and what Wav2Vec was actually handed after the gate
//  and the extractor had their turn.
//
//  WHY BOTH, AND WHY ALIGNED. The open question in this layer is whether
//  extraction helps or hurts word error rate (TSEConfig.coverage), and half of
//  that question is qualitative — if the extractor is punching holes in the
//  clinician's own speech you HEAR it immediately, warbling and dropped
//  consonants, in a way no distance metric reports. Playing the two tracks back
//  to back only works if sample N means the same instant in both, so both files
//  are written from the SAME committed chunks: raw in, gated out, one append
//  each, in lockstep. A withheld chunk writes SILENCE to the gated track rather
//  than nothing, because skipping it would slide every later sample and destroy
//  the alignment the whole instrument depends on.
//
//  WHY THE FILE MATTERS MORE THAN THE PLAYBACK. `SpeakerGateDebugView` already
//  runs the entire gate on a FILE. Before this existed, the gated buffer was
//  discarded the instant `predict()` returned, so every bad verdict and every
//  mangled transcription was unreproducible — diagnosing one meant persuading a
//  real room to misbehave the same way twice. A session dump turns any live
//  failure into a fixture you can re-run offline, deterministically, against
//  different thresholds, modes and coverages, with no microphone in the loop.
//
//  LAST SESSION ONLY. `begin()` truncates. Bounded disk, bounded exposure, and
//  still whatever just went wrong.
//
//  OFF BY DEFAULT, AND NOT A SHIPPING FEATURE. Calibration audio is a clinician
//  reading a script; a SESSION is whatever was said in the operatory, which can
//  include the patient. The files carry the same `.completeUnlessOpen` protection
//  and backup exclusion `VoiceProfileStore` applies to voiceprints, but that
//  makes them defensible for debugging, not fit to ship. Turning this into a
//  clinician-facing control is a retention and compliance decision, not a code
//  one.
//

import AVFoundation
import Foundation

final class SessionRecorder: @unchecked Sendable {

    static let shared = SessionRecorder()

    // Persisted so a rebuild does not silently switch capture off midway through
    // an investigation — a reinstall is expensive enough without losing the one
    // setting that was recording the evidence.
    private static let enabledKey = "DebugSessionCaptureEnabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    enum Track: String, CaseIterable {
        case raw   = "session-raw.wav"
        case gated = "session-gated.wav"

        var title: String {
            switch self {
            case .raw:   return "Raw (what the mic heard)"
            case .gated: return "Gated (what Wav2Vec heard)"
            }
        }

        // Relative to Documents, which is the form `AudioManager.playRecording`
        // expects — it appends whatever it is given to the Documents root, and a
        // path with slashes routes correctly.
        var relativePath: String { "\(SessionRecorder.directoryName)/\(rawValue)" }
    }

    static let directoryName = "DebugSessions"

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func url(for track: Track) -> URL {
        directory.appendingPathComponent(track.rawValue)
    }

    // AVAudioFile is not thread-safe and commits arrive from the main actor while
    // `finish()` may land from a teardown task. One lock covers both writers.
    private let lock = NSLock()
    private var rawFile: AVAudioFile?
    private var gatedFile: AVAudioFile?
    private var samplesWritten = 0

    private init() {}

    var isCapturing: Bool {
        lock.lock(); defer { lock.unlock() }
        return rawFile != nil
    }

    // Seconds captured in the session on disk, or nil when there is none.
    //
    // The fileExists check is not redundant with `try?`. AVAudioFile logs
    // `ExtAudioFileOpenURL ... error 2003334207` to the console before throwing,
    // so probing a missing file prints three lines of alarming-looking noise every
    // time the debug view appears — which is exactly when someone is reading the
    // console for real gate output.
    static func recordedSeconds() -> Double? {
        let url = url(for: .raw)
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url), file.length > 0 else {
            return nil
        }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    // MARK: - Capture

    // Truncate both tracks and open them for writing. Cheap enough to call on
    // every session start; does nothing at all when capture is off.
    func begin() {
        guard Self.isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }

        do {
            try FileManager.default.createDirectory(at: Self.directory,
                                                    withIntermediateDirectories: true)
            Self.secure(Self.directory)

            // 16-bit PCM, not float32. Halves the file for no audible loss at
            // these levels, and AVAudioPlayer opens it without conversion.
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: Double(SpeakerGate.sampleRate),
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            // `forWriting` truncates an existing file, which is the whole
            // last-session-only retention policy.
            rawFile = try AVAudioFile(forWriting: Self.url(for: .raw), settings: settings)
            gatedFile = try AVAudioFile(forWriting: Self.url(for: .gated), settings: settings)
            samplesWritten = 0
            for track in Track.allCases { Self.secure(Self.url(for: track)) }
            print("[Capture] recording session to \(Self.directoryName)/")
        } catch {
            rawFile = nil
            gatedFile = nil
            print("[Capture] could not start: \(error.localizedDescription)")
        }
    }

    // Append one committed chunk to both tracks.
    //
    // `gated` nil means the chunk was withheld — every span was somebody else.
    // That writes SILENCE of the same length, so the two files stay aligned and
    // the withheld stretch is audible for what it is.
    func append(raw: [Float], gated: [Float]?) {
        guard Self.isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let rawFile, let gatedFile else { return }

        let gatedOrSilence = gated ?? [Float](repeating: 0, count: raw.count)
        do {
            try Self.write(raw, to: rawFile)
            try Self.write(gatedOrSilence, to: gatedFile)
            samplesWritten += raw.count
        } catch {
            print("[Capture] write failed: \(error.localizedDescription)")
        }
    }

    // Close both tracks and report what landed.
    func finish() {
        guard Self.isEnabled else { return }
        lock.lock()
        let seconds = Double(samplesWritten) / Double(SpeakerGate.sampleRate)
        let had = rawFile != nil
        rawFile = nil                       // AVAudioFile flushes on deinit
        gatedFile = nil
        samplesWritten = 0
        lock.unlock()

        guard had else { return }
        for track in Track.allCases { Self.secure(Self.url(for: track)) }
        print(String(format: "[Capture] session saved — %.1fs raw + gated in %@/",
                     seconds, Self.directoryName))
    }

    func deleteLastSession() {
        lock.lock()
        rawFile = nil
        gatedFile = nil
        samplesWritten = 0
        lock.unlock()
        for track in Track.allCases {
            try? FileManager.default.removeItem(at: Self.url(for: track))
        }
        print("[Capture] session deleted")
    }

    // MARK: - Replay

    // Read a captured track back EXACTLY as the microphone delivered it.
    //
    // NOT `SpeakerGate.loadSamples`, and the difference is the whole point of the
    // re-run. `loadSamples` peak-normalises, high-passes at 80 Hz and auto-gains,
    // because it was written for CALIBRATION files. The live path does none of
    // that — `Wav2VecAudioCapture` hands raw converted floats straight to the
    // gate. Replaying a session through `loadSamples` would judge it under
    // preprocessing the live session never had, so a re-run could disagree with
    // the log lines it is supposed to reproduce.
    //
    // (That asymmetry is not this function's doing and does not stop at replay:
    // enrollment templates are built from high-passed, auto-gained audio while
    // live spans are not, so the two are measured through different front ends.
    // Worth settling on its own.)
    static func loadRaw(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            return []
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    // MARK: - Helpers

    private static func write(_ samples: [Float], to file: AVAudioFile) throws {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            channel[0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    // Same treatment `VoiceProfileStore` gives voiceprints: encrypted at rest
    // unless already open, and never synced to iCloud. Session audio is more
    // sensitive than a calibration take, not less.
    private static func secure(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
