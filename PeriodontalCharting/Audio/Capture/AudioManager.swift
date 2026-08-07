import Foundation
import AVFoundation
import Combine
import OSLog

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

    /// Bumped by every start AND every stop, so an in-flight asynchronous start
    /// can tell that it has been superseded.
    ///
    /// WITHOUT THIS: a Stop arriving before the (asynchronous) setup finishes
    /// finds `audioRecorder == nil`, stops nothing, and then the late setup
    /// starts recording anyway and republishes `isRecording = true` — a recorder
    /// nobody can stop and every Record button disabled. Guarded by `ioLock`
    /// along with the recorder/player themselves.
    private var recordGeneration = 0
    private var playGeneration = 0

    /// Guards `audioRecorder`, `audioPlayer` and the generation counters, which
    /// are written on `sessionQueue` but read and stopped from the main thread.
    /// Stop has to stay synchronous: `enrollCalibration()` starts reading the
    /// file the instant `stopRecording()` returns.
    private let ioLock = NSLock()

    /// Session setup runs here, never on main. `AVAudioSession.setActive(true)` is
    /// a blocking IPC to mediaserverd that renegotiates the whole audio route, and
    /// `.allowBluetoothHFP` makes it enumerate Bluetooth routes as well — 100–500 ms
    /// typical, worse while Core ML is compiling. Called from a button action on
    /// the main thread, that IS the "lag when I tap Record".
    private let sessionQueue = DispatchQueue(label: "PeriodontalCharting.audio.session",
                                             qos: .userInitiated)

    /// Set once the category has been applied. Guarded by `sessionQueue`.
    private var isSessionConfigured = false

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

    // MARK: - Session
    //
    // ONE CATEGORY FOR BOTH DIRECTIONS, applied ONCE.
    //
    // The old code set `.playAndRecord` in `startRecording`, `.playback` in
    // `playRecording`, and `setActive(false)` in `stopRecording` — so every
    // Record and every Play tap paid a full route renegotiation, not just the
    // first. Playback works fine under `.playAndRecord` because `.defaultToSpeaker`
    // is set, which is the same routing `.playback` was being chosen for.
    //
    // The trap that motivated the old split still holds and is why the category
    // stays `.playAndRecord` everywhere: `.defaultToSpeaker` is ONLY valid with
    // `.playAndRecord`. Passing it with `.playback` makes setCategory throw
    // OSStatus -50 and playback never starts.

    /// Configure and activate the shared session, at most once. MUST be called on
    /// `sessionQueue`.
    private func configureSessionIfNeeded() throws {
        let session = AVAudioSession.sharedInstance()
        if !isSessionConfigured {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP])
            isSessionConfigured = true
        }
        // Cheap when already active; the expensive renegotiation only happens on
        // the transition.
        try session.setActive(true)
    }

    /// Release the session. Call when leaving calibration entirely — NOT between
    /// takes, which is what made every tap slow.
    func deactivateSession() {
        sessionQueue.async {
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Warm the session ahead of the first tap. Optional: everything still works
    /// without it, the first Record just pays the setup (off the main thread).
    /// Onboarding calls this from `.onAppear`.
    func prepareForCalibration() {
        sessionQueue.async { [weak self] in
            do {
                try self?.configureSessionIfNeeded()
            } catch {
                AppLog.audio.error(
                    "session prepare failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Recording

    func startRecording(filename: String = "voice_sample.wav") {
        let documentPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioFilename = documentPath.appendingPathComponent(filename)

        // Published state and the target file are set on main immediately, so the
        // UI and the subsequent `stopRecording()` see a consistent target even
        // though the hardware setup below is asynchronous.
        self.recordingURL = audioFilename
        self.currentFilename = filename

        ioLock.lock()
        recordGeneration += 1
        let generation = recordGeneration
        ioLock.unlock()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureSessionIfNeeded()

                // 16kHz WAV configuration
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: 16000.0,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false
                ]

                let recorder = try AVAudioRecorder(url: audioFilename, settings: settings)
                recorder.delegate = self

                // Superseded while we were setting up (a Stop, or another take's
                // Record). Do not start, and do not republish `isRecording`.
                self.ioLock.lock()
                guard generation == self.recordGeneration else {
                    self.ioLock.unlock()
                    return
                }
                self.audioRecorder = recorder
                self.ioLock.unlock()

                recorder.record()

                DispatchQueue.main.async {
                    self.isRecording = true
                }
            } catch {
                AppLog.audio.error(
                    "Failed to setup audio recording: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async {
                    self.isRecording = false
                }
            }
        }
    }

    /// Stops SYNCHRONOUSLY on the calling thread.
    ///
    /// Deliberately not moved to `sessionQueue`: `enrollCalibration()` runs the
    /// moment this returns, and `AVAudioRecorder` already finalises its file
    /// asynchronously after `stop()` (which is why enrollment reads with
    /// `waitForFile: true`). Deferring the `stop()` itself would widen that
    /// window instead of narrowing it.
    ///
    /// The session is left ACTIVE — deactivating here is what made the next
    /// Record tap pay the full renegotiation again.
    func stopRecording() {
        ioLock.lock()
        // Invalidate any start still setting itself up on `sessionQueue`.
        recordGeneration += 1
        let recorder = audioRecorder
        audioRecorder = nil
        ioLock.unlock()

        recorder?.stop()

        DispatchQueue.main.async {
            self.isRecording = false
            self.checkExistingRecording(filename: self.currentFilename)
        }
    }

    // MARK: - Playback

    /// Pass a filename to play a specific take; omit it to replay whatever
    /// `recordingURL` currently points at (the pre-existing behaviour).
    func playRecording(filename: String? = nil) {
        if let filename { checkExistingRecording(filename: filename) }
        guard let url = recordingURL, hasRecording else { return }

        ioLock.lock()
        playGeneration += 1
        let generation = playGeneration
        ioLock.unlock()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                // No category switch. See the "Session" note above: `.playAndRecord`
                // plus `.defaultToSpeaker` already routes to the speaker, and
                // switching to `.playback` per tap was a full renegotiation.
                try self.configureSessionIfNeeded()

                let player = try AVAudioPlayer(contentsOf: url)
                player.delegate = self

                self.ioLock.lock()
                guard generation == self.playGeneration else {
                    self.ioLock.unlock()
                    return
                }
                self.audioPlayer = player
                self.ioLock.unlock()

                player.play()

                DispatchQueue.main.async {
                    self.isPlaying = true
                    // From the URL, not the parameter, so the legacy nil-filename
                    // path (replay whatever recordingURL points at) is covered too.
                    self.playingFilename = url.lastPathComponent
                }
            } catch {
                AppLog.audio.error(
                    "Failed to play audio: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stopPlaying() {
        ioLock.lock()
        playGeneration += 1
        let player = audioPlayer
        audioPlayer = nil
        ioLock.unlock()

        player?.stop()

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
    ///
    /// Stays SYNCHRONOUS and on the caller's thread: this one throws, and the
    /// caller aborts the whole start on failure. It is once per session, not per
    /// tap, so it was never the latency problem.
    @MainActor
    func beginLiveCapture(driving driver: any LiveCaptureDriver) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        sessionQueue.async { self.isSessionConfigured = true }

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
