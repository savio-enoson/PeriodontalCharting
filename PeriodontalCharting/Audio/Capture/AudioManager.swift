import Foundation
import AVFoundation
import Combine

/// Something AudioManager drives while it owns the live-capture session — today,
/// TranscriptionViewModel. AudioManager owns the `AVAudioSession` and reacts to
/// route/interruption changes; the driver owns the actual capture graph and knows
/// how to rebuild it. `@MainActor` because the driver is UI-facing state.
@MainActor
protocol LiveCaptureDriver: AnyObject {
    /// Tear down and re-create the live capture stream against the *current* audio
    /// route/format. Called after AudioManager reactivates the session, so the
    /// driver's converter/tap are rebuilt to match the new hardware format.
    func restartLiveStream() async
}

class AudioManager: NSObject, ObservableObject {
    static let shared = AudioManager()
    
    @Published var isRecording: Bool = false
    @Published var isPlaying: Bool = false
    @Published var hasRecording: Bool = false
    /// Which file is currently playing, by filename. `isPlaying` alone is a single
    /// global flag, so multi-take calibration showed EVERY row as "Stop" the
    /// moment any one of them started.
    @Published private(set) var playingFilename: String?
    @Published var recordingURL: URL?
    
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?

    /// The file the last `startRecording` targeted. `stopRecording` must re-check
    /// THIS file rather than the default, or multi-take calibration silently
    /// repoints `recordingURL` at take 1 and Play plays the wrong recording.
    private var currentFilename: String = "voice_sample.wav"
    
    private override init() {
        super.init()
        checkExistingRecording()
    }
    
    func checkExistingRecording(filename: String = "voice_sample.wav") {
        let documentPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioFilename = documentPath.appendingPathComponent(filename)
        self.recordingURL = audioFilename
        self.hasRecording = FileManager.default.fileExists(atPath: audioFilename.path)
    }
    
    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }
    
    func startRecording(filename: String = "voice_sample.wav") {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            
            let documentPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let audioFilename = documentPath.appendingPathComponent(filename)
            self.recordingURL = audioFilename
            self.currentFilename = filename
            
            // 16kHz WAV configuration
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
            
            DispatchQueue.main.async {
                self.isRecording = true
            }
        } catch {
            print("Failed to setup audio recording: \(error.localizedDescription)")
        }
    }
    
    func stopRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false)
        
        DispatchQueue.main.async {
            self.isRecording = false
            self.checkExistingRecording(filename: self.currentFilename)
        }
    }
    
    /// Pass a filename to play a specific take; omit it to replay whatever
    /// `recordingURL` currently points at (the pre-existing behaviour).
    func playRecording(filename: String? = nil) {
        if let filename { checkExistingRecording(filename: filename) }
        guard let url = recordingURL, hasRecording else { return }
        
        let session = AVAudioSession.sharedInstance()
        do {
            // NO .defaultToSpeaker here — it is only valid with .playAndRecord,
            // and passing it with .playback makes setCategory throw OSStatus -50
            // so playback never starts. .playback already routes to the speaker.
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            
            DispatchQueue.main.async {
                self.isPlaying = true
                // From the URL, not the parameter, so the legacy nil-filename path
                // (replay whatever recordingURL points at) is covered too.
                self.playingFilename = url.lastPathComponent
            }
        } catch {
            print("Failed to play audio: \(error.localizedDescription)")
        }
    }
    
    func stopPlaying() {
        audioPlayer?.stop()
        audioPlayer = nil

        DispatchQueue.main.async {
            self.isPlaying = false
            self.playingFilename = nil
        }
    }

    // MARK: - Live transcription session ownership
    //
    // AudioManager is the single owner of the shared AVAudioSession for live
    // mic capture. WhisperKit's AudioStreamTranscriber builds an AVAudioConverter
    // from the input format when it starts; if the route or sample rate changes
    // afterward (Bluetooth headset (dis)connects, a call/Siri interrupts), that
    // converter no longer matches the tap buffers and WhisperKit throws
    //   audioProcessingFailed("Error converting audio: …")
    // (the AVAudioConverter FillComplexProc format-mismatch assertion). By owning
    // the session here we can catch those events and have the driver rebuild the
    // stream against the new format instead of crashing.

    /// The capture graph AudioManager is currently driving (the view-model).
    private weak var liveDriver: (any LiveCaptureDriver)?
    /// True between `beginLiveCapture` and `endLiveCapture` — gates the observers.
    private(set) var isLiveCaptureActive = false

    /// Configure + activate the session for live mic capture, start observing
    /// route/interruption changes, and remember the driver to rebuild on change.
    /// Call once when live transcription starts. Throws if the session rejects the
    /// configuration (caller should surface it and abort the start).
    @MainActor
    func beginLiveCapture(driving driver: any LiveCaptureDriver) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        liveDriver = driver
        isLiveCaptureActive = true
        registerSessionObservers()
    }

    /// Stop observing, drop the driver, and deactivate the session. Call once when
    /// live transcription stops (after the driver has torn down its capture graph).
    @MainActor
    func endLiveCapture() {
        guard isLiveCaptureActive else { return }
        isLiveCaptureActive = false
        liveDriver = nil
        unregisterSessionObservers()
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func registerSessionObservers() {
        unregisterSessionObservers()  // idempotent — never double-register
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
    }

    private func unregisterSessionObservers() {
        let nc = NotificationCenter.default
        nc.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        nc.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
    }

    // NotificationCenter posts on an arbitrary thread, so these stay non-isolated
    // and hop to the main actor before touching state or the driver.

    @objc private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
        switch AVAudioSession.RouteChangeReason(rawValue: raw) {
        case .newDeviceAvailable, .oldDeviceUnavailable:
            // The mic itself changed (e.g. Bluetooth headset (dis)connected) — the
            // capture graph must be rebuilt against the new device. Mere sample-rate
            // / config changes (.routeConfigurationChange, .override) are handled
            // seamlessly inside WhisperKit's adaptive converter, so we deliberately
            // don't restart on those — that would just churn the stream needlessly.
            Task { @MainActor [weak self] in await self?.performLiveRestart() }
        default:
            break
        }
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // The system tore down the engine; nothing to do until it ends. The
            // driver's stream task will stall and resume on the .ended restart.
            break
        case .ended:
            let shouldResume = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            if shouldResume {
                Task { @MainActor [weak self] in await self?.performLiveRestart() }
            }
        @unknown default:
            break
        }
    }

    /// Reactivate the session (route changes can deactivate it) and ask the driver
    /// to rebuild its capture stream against the now-current format.
    @MainActor
    private func performLiveRestart() async {
        guard isLiveCaptureActive else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        await liveDriver?.restartLiveStream()
    }
}

extension AudioManager: AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            stopRecording()
        }
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopPlaying()
    }
}
