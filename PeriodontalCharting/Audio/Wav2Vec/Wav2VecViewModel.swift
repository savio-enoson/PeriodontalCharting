import Foundation
import Observation
import Accelerate

@MainActor
@Observable
final class Wav2VecViewModel {
    
    // MARK: - Observable state (the View binds to these)
    private(set) var transcript: String = ""
    private(set) var statusMessage: String = String(localized: "Loading the speech model…")
    private(set) var isModelReady: Bool = false
    private(set) var isTranscribing: Bool = false
    private(set) var isRecording: Bool = false

    // MARK: - Live event hooks (for AI Mode)
    var onLiveTranscript: ((String) -> Void)?
    var onConfirmedTranscript: ((String) -> Void)?

    private var streamingBuffer: [Float] = []
    private var committedHistory: [String] = []
    private var silenceFrames = 0
    private var hasStartedSpeaking = false
    private var lastProcessedBufferCount = 0
    private var baselineRMS: Float = 0.01
    private var isProcessing = false

    // Provides the same gate status struct as TranscriptionViewModel to satisfy UI bindings
    struct GateStatus {
        var active = false
        var extractorReady = false
        var spans = 0
        var rejected = 0
        var routed = 0
        var rescued = 0
        var withheldSegments = 0
        var lastDistance: Double?
        var summary: String { return "Speaker filter offline (Wav2Vec2)" }
    }
    private(set) var gateStatus = GateStatus()

    func loadModel() async {
        statusMessage = String(localized: "Loading the speech model…")
        await Wav2VecEngine.shared.loadModel()
        isModelReady = Wav2VecEngine.shared.isModelLoaded
        if isModelReady {
            statusMessage = String(localized: "Voice dictation ready")
        } else {
            statusMessage = String(localized: "Couldn’t load the speech model")
        }
    }

    func toggleRecording() {
        if isRecording { stopLive() }
        else { startLive() }
    }

    func startLive() {
        guard !isRecording else { return }
        guard isModelReady else {
            statusMessage = String(localized: "Voice dictation isn’t ready yet")
            return
        }

        transcript = ""
        committedHistory = []
        streamingBuffer = []
        silenceFrames = 0
        hasStartedSpeaking = false
        lastProcessedBufferCount = 0
        baselineRMS = 0.01
        
        isRecording = true
        isTranscribing = true
        statusMessage = String(localized: "Listening…")
        
        do {
            try Wav2VecAudioCapture.shared.startStreamingRecording { [weak self] buffer in
                DispatchQueue.main.async {
                    self?.processAudioChunk(buffer)
                }
            }
        } catch {
            statusMessage = "Live error: \(error.localizedDescription)"
            isRecording = false
            isTranscribing = false
        }
    }

    func stopLive() {
        guard isRecording else { return }
        Wav2VecAudioCapture.shared.stopRecording()
        isRecording = false
        isTranscribing = false
        statusMessage = transcript.isEmpty ? String(localized: "No speech captured") : String(localized: "Done")
        
        // Final flush
        let chunkToProcess = streamingBuffer
        streamingBuffer = []
        if chunkToProcess.count >= 16000 {
            isProcessing = true
            Task {
                let normalizedChunk = Wav2VecAudioCapture.shared.normalizeAudio(data: chunkToProcess)
                if let result = await Wav2VecEngine.shared.predict(audioData: normalizedChunk, isLivePreview: false) {
                    if !result.trimmingCharacters(in: .whitespaces).isEmpty {
                        await MainActor.run {
                            self.committedHistory.append(result)
                            let joined = self.committedHistory.joined(separator: " ")
                            self.transcript = joined
                            self.onConfirmedTranscript?(joined)
                            self.onLiveTranscript?(joined)
                        }
                    }
                }
                await MainActor.run { self.isProcessing = false }
            }
        }
    }

    private func processAudioChunk(_ buffer: [Float]) {
        var rms: Float = 0.0
        vDSP_rmsqv(buffer, 1, &rms, vDSP_Length(buffer.count))
        
        let threshold = max(0.001, self.baselineRMS * 2.0)
        let isSpeech = rms > threshold
        
        if !isSpeech {
            self.baselineRMS = self.baselineRMS * 0.99 + rms * 0.01
        }
        
        if isSpeech {
            self.silenceFrames = 0
            self.hasStartedSpeaking = true
        } else {
            self.silenceFrames += 1
        }
        
        self.streamingBuffer.append(contentsOf: buffer)
        
        if !self.hasStartedSpeaking {
            let preRollSamples = 16000
            if self.streamingBuffer.count > preRollSamples {
                self.streamingBuffer.removeFirst(self.streamingBuffer.count - preRollSamples)
            }
        }
        
        var requiredSilence = 15 // 0.48s base silence requirement for snappy commits
        if self.streamingBuffer.count > 16000 * 15 {
            requiredSilence = 10
        }
        if self.streamingBuffer.count > 16000 * 30 {
            requiredSilence = 5
        }
        if self.streamingBuffer.count > 16000 * 45 {
            requiredSilence = 3
        }
        if self.streamingBuffer.count > 16000 * 55 {
            requiredSilence = 0
        }
        
        if self.hasStartedSpeaking && self.silenceFrames >= requiredSilence && self.streamingBuffer.count > 16000 {
            // COMMIT
            let chunkToProcess = self.streamingBuffer
            self.streamingBuffer.removeAll()
            self.silenceFrames = 0
            self.hasStartedSpeaking = false
            self.isProcessing = true
            self.lastProcessedBufferCount = 0
            
            Task {
                let normalizedChunk = Wav2VecAudioCapture.shared.normalizeAudio(data: chunkToProcess)
                if let result = await Wav2VecEngine.shared.predict(audioData: normalizedChunk, isLivePreview: false) {
                    if !result.trimmingCharacters(in: .whitespaces).isEmpty {
                        await MainActor.run {
                            self.committedHistory.append(result)
                            let joined = self.committedHistory.joined(separator: " ")
                            self.transcript = joined
                            self.onConfirmedTranscript?(joined)
                            self.onLiveTranscript?(joined)
                        }
                    }
                }
                await MainActor.run { self.isProcessing = false }
            }
        } 
        else if self.streamingBuffer.count >= 16000 && !self.isProcessing && self.silenceFrames <= requiredSilence {
            // INTERMEDIATE INFERENCE
            if self.streamingBuffer.count - self.lastProcessedBufferCount >= 8000 {
                self.lastProcessedBufferCount = self.streamingBuffer.count
                let chunk = self.streamingBuffer
                
                self.isProcessing = true
                Task {
                    let normalizedChunk = Wav2VecAudioCapture.shared.normalizeAudio(data: chunk)
                    
                    if let result = await Wav2VecEngine.shared.predict(audioData: normalizedChunk, isLivePreview: true) {
                        await MainActor.run {
                            let liveOutput = (self.committedHistory + [result]).joined(separator: " ")
                            self.transcript = liveOutput
                            self.onLiveTranscript?(liveOutput)
                        }
                    }
                    await MainActor.run { self.isProcessing = false }
                }
            }
        }
    }
}
