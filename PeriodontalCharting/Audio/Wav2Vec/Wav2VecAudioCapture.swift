import Foundation
import AVFoundation
import Combine
import Accelerate

@MainActor
class Wav2VecAudioCapture: ObservableObject {
    static let shared = Wav2VecAudioCapture()
    
    private let audioEngine = AVAudioEngine()
    
    @Published var isRecording = false
    @Published var audioLevel: Float = -60.0
    
    
    private init() {
    }
    
    /// Prompts the user for microphone access.
    func requestMicrophoneAccess() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    
    private var alignmentBuffer: [Float] = []

    // THE LIVE PATH'S FRONT END, and until now it did not have one.
    //
    // `SpeakerGate.loadSamples` high-passes and auto-gains every CALIBRATION
    // file, so enrollment templates were built from conditioned audio while live
    // spans were judged raw. The energy segmenter sets its speech threshold at
    // `noiseFloor * 3`, and sub-80 Hz rumble lifts that floor in silence and in
    // speech alike — so a quiet clinician had to clear a bar his own templates
    // never faced. Measured on synthetic dictation, adding these two lifts
    // contrast 2.5x (6.1x -> 15.4x at rms 0.03, 18.0x -> 47.1x at 0.11).
    //
    // The STREAMING variants, which were written for exactly this and had no
    // caller. Both carry state across buffers: `HighPassFilter` is an IIR biquad,
    // and `AutoGain` smooths its multiplier over ~1.5 s and HOLDS it during
    // silence so a quiet room cannot drive the noise floor up to the target.
    private var highPass = HighPassFilter()
    private var autoGain = AutoGain()

    /// Starts continuous streaming. The callback receives chunks that are exact multiples of 512 samples (for VAD compatibility).
    func startStreamingRecording(onBuffer: @escaping ([Float]) -> Void) throws {
        alignmentBuffer.removeAll()
        // Per session. The filter's IIR state and the gain's multiplier are both
        // history, and last session's history belongs to a different room.
        highPass.reset()
        autoGain.reset()
        try startRecording { [weak self] buffer in
            guard let self = self else { return }
            // Condition BEFORE anything downstream sees it, so the gate, the
            // decoder and the debug capture all work from the same signal.
            var conditioned = buffer
            self.highPass.apply(to: &conditioned)
            self.autoGain.apply(to: &conditioned)
            self.alignmentBuffer.append(contentsOf: conditioned)
            
            var alignedChunks: [Float] = []
            while self.alignmentBuffer.count >= 512 {
                let chunk = Array(self.alignmentBuffer.prefix(512))
                alignedChunks.append(contentsOf: chunk)
                self.alignmentBuffer.removeFirst(512)
            }
            
            if !alignedChunks.isEmpty {
                // Pass raw (unnormalized) audio so VAD can gauge absolute energy
                onBuffer(alignedChunks)
            }
        }
    }
    
    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false
    }
    
    private func startRecording(onBuffer: @escaping ([Float]) -> Void) throws {
        guard !isRecording else { return }
        
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        // Use .playAndRecord with .defaultToSpeaker. This is universally supported on all iOS/iPadOS devices and prevents category errors.
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "Wav2VecAudioCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid hardware audio format. Microphone may not be ready."])
        }
        
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000.0, channels: 1, interleaved: false) else {
            throw NSError(domain: "Wav2VecAudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create target 16kHz audio format."])
        }
        
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "Wav2VecAudioCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter."])
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            
            // Calculate audio level for UI (RMS) using Accelerate on original buffer
            self.updateAudioLevel(buffer: buffer)
            
            let capacity = AVAudioFrameCount(targetFormat.sampleRate / inputFormat.sampleRate * Double(buffer.frameLength)) + 1024
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            
            var error: NSError?
            var allDone = false
            let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                if allDone {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                allDone = true
                outStatus.pointee = .haveData
                return buffer
            }
            
            if status != .error, let channelData = convertedBuffer.floatChannelData {
                let frameLength = Int(convertedBuffer.frameLength)
                let floatArray = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
                onBuffer(floatArray)
            }
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        isRecording = true
    }
    
    private func updateAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let channelDataValue = channelData.pointee
        let frameLength = UInt(buffer.frameLength)
        
        // Use vDSP for hardware-accelerated RMS calculation
        var rms: Float = 0.0
        vDSP_rmsqv(channelDataValue, Int(buffer.stride), &rms, vDSP_Length(frameLength))
        
        let db = 20 * log10(rms)
        
        DispatchQueue.main.async {
            self.audioLevel = db.isFinite ? max(-60.0, db) : -60.0
        }
    }
    
    /// Hardware-accelerated zero-mean, unit-variance normalization (Z-score).
    func normalizeAudio(data: [Float]) -> [Float] {
        guard !data.isEmpty else { return data }
        let length = vDSP_Length(data.count)
        
        var output = [Float](repeating: 0.0, count: data.count)
        var mean: Float = 0.0
        var stdDev: Float = 0.0
        
        // vDSP_normalize calculates mean and stddev, then applies standard score scaling
        vDSP_normalize(data, 1, &output, 1, &mean, &stdDev, length)
        
        // If the buffer is pure silence (stdDev = 0), vDSP might output NaNs. 
        if stdDev == 0 {
            return [Float](repeating: 0.0, count: data.count)
        }
        
        return output
    }
}
