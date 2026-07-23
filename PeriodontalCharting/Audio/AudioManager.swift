import Foundation
import AVFoundation
import Combine

class AudioManager: NSObject, ObservableObject {
    static let shared = AudioManager()
    
    @Published var isRecording: Bool = false
    @Published var isPlaying: Bool = false
    @Published var hasRecording: Bool = false
    @Published var recordingURL: URL?
    
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    
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
            self.checkExistingRecording()
        }
    }
    
    func playRecording() {
        guard let url = recordingURL, hasRecording else { return }
        
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            
            DispatchQueue.main.async {
                self.isPlaying = true
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
        }
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
