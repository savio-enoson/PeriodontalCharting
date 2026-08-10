//
//  ContentView.swift
//  STT_Wav2Vec
//
//  Created by Savio Enoson on 6/8/26.
//

import SwiftUI
import Accelerate

struct ContentView: View {
    @StateObject private var modelManager = ModelManager.shared
    @StateObject private var audioManager = AudioManager.shared
    
    @State private var transcribedText = "Ready to dictate..."
    @State private var isProcessing = false
    
    // For streaming
    @State private var streamingBuffer: [Float] = []
    @State private var committedHistory: [String] = []
    @State private var silenceFrames = 0
    @State private var hasStartedSpeaking = false
    
    @State private var lastProcessedBufferCount = 0
    @State private var baselineRMS: Float = 0.01
    
    var body: some View {
        VStack(spacing: 30) {
            Text("Periodontal STT Engine")
                .font(.largeTitle)
                .bold()
            
            if !modelManager.isModelLoaded {
                ProgressView("Loading CoreML Model...")
            } else {
                ScrollView {
                    ScrollViewReader { proxy in
                        // Continuous stream of text
                        Text("\(Text(committedHistory.joined(separator: " ")).foregroundColor(.primary))\(Text(committedHistory.isEmpty ? transcribedText : " " + transcribedText).foregroundColor(.gray))")
                        .font(.title2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("bottomText")
                        .onChange(of: transcribedText) { oldValue, newValue in
                            withAnimation {
                                proxy.scrollTo("bottomText", anchor: .bottom)
                            }
                        }
                        .onChange(of: committedHistory.count) { oldValue, newValue in
                            withAnimation {
                                proxy.scrollTo("bottomText", anchor: .bottom)
                            }
                        }
                    }
                }
                .padding()
                .frame(minHeight: 250, maxHeight: .infinity)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
                
                HStack(spacing: 20) {
                    // Offline Recording Button
                    Button(action: toggleOfflineRecording) {
                        VStack {
                            Image(systemName: audioManager.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                                .font(.system(size: 40))
                            Text(audioManager.isRecording ? "Stop Recording" : "Start Offline")
                        }
                        .foregroundColor(audioManager.isRecording ? .red : .blue)
                    }
                    
                    // Streaming Recording Button (Optional demo)
                    Button(action: toggleStreamingRecording) {
                        VStack {
                            Image(systemName: audioManager.isRecording ? "stop.circle.fill" : "waveform.circle.fill")
                                .font(.system(size: 40))
                            Text(audioManager.isRecording ? "Stop Stream" : "Start Streaming")
                        }
                        .foregroundColor(audioManager.isRecording ? .red : .green)
                    }
                }
                
                // Simple VU Meter
                GeometryReader { geo in
                    let width = max(0, min(1.0, CGFloat((audioManager.audioLevel + 60.0) / 60.0))) * geo.size.width
                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: width)
                }
                .frame(height: 10)
                .background(Color.gray.opacity(0.3))
                .cornerRadius(5)
                .padding(.horizontal)
            }
        }
        .padding()
        .overlay(alignment: .topTrailing) {
            if isProcessing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                    .padding()
            }
        }
        .task {
            // Load model on appear and request mic
            _ = await audioManager.requestMicrophoneAccess()
            await modelManager.loadModel()
        }
    }
    
    private func toggleOfflineRecording() {
        if audioManager.isRecording {
            let buffer = audioManager.stopOfflineRecording()
            isProcessing = true
            Task {
                if let result = await modelManager.predict(audioData: buffer, isLivePreview: false) {
                    await MainActor.run {
                        transcribedText = result
                        isProcessing = false
                    }
                } else {
                    await MainActor.run {
                        transcribedText = "Error parsing audio."
                        isProcessing = false
                    }
                }
            }
        } else {
            transcribedText = "Listening (Offline Mode)..."
            try? audioManager.startOfflineRecording()
        }
    }
    
    private func toggleStreamingRecording() {
        if audioManager.isRecording {
            audioManager.stopRecording()
            isProcessing = true
            let finalBuffer = streamingBuffer 
            Task {
                if finalBuffer.count >= 16000 {
                    let normalizedChunk = audioManager.normalizeAudio(data: finalBuffer)
                    if let result = await modelManager.predict(audioData: normalizedChunk, isLivePreview: false) {
                        if !result.trimmingCharacters(in: .whitespaces).isEmpty {
                            await MainActor.run {
                                committedHistory.append(result)
                            }
                        }
                    }
                }
                await MainActor.run {
                    transcribedText = "Stream Stopped."
                    isProcessing = false
                    streamingBuffer.removeAll()
                    hasStartedSpeaking = false
                }
            }
        } else {
            transcribedText = "Listening (Streaming Mode)..."
            streamingBuffer.removeAll()
            silenceFrames = 0
            hasStartedSpeaking = false
            lastProcessedBufferCount = 0
            baselineRMS = 0.01
            
            try? audioManager.startStreamingRecording { buffer in
                DispatchQueue.main.async {
                    // Calculate RMS energy for the 512-sample buffer
                    var rms: Float = 0.0
                    vDSP_rmsqv(buffer, 1, &rms, vDSP_Length(buffer.count))
                    
                    // Adaptive VAD threshold based on running background noise
                    // Removed the 0.015 hard cap so it can adapt to very loud baseline noise!
                    let threshold = max(0.01, self.baselineRMS * 2.0)
                    let isSpeech = rms > threshold
                    
                    if !isSpeech {
                        // Slowly adapt baseline downwards or upwards towards current noise floor
                        self.baselineRMS = self.baselineRMS * 0.99 + rms * 0.01
                    }
                    
                    // Let's print RMS instead of probabilities so we can tune the threshold
                    if !isSpeech && self.silenceFrames % 10 != 0 {
                        // Only print silence occasionally to avoid spam
                    } else {
                        print("RMS Energy: \(String(format: "%.5f", rms)), threshold: \(String(format: "%.5f", threshold)), isSpeech: \(isSpeech)")
                    }
                    
                    if isSpeech {
                        self.silenceFrames = 0
                        self.hasStartedSpeaking = true
                    } else {
                        self.silenceFrames += 1
                    }
                    
                    self.streamingBuffer.append(contentsOf: buffer)
                    
                    // Pre-roll logic: If we haven't started speaking, keep only a 1.0s pre-roll (16000 samples)
                    if !self.hasStartedSpeaking {
                        let preRollSamples = 16000
                        if self.streamingBuffer.count > preRollSamples {
                            self.streamingBuffer.removeFirst(self.streamingBuffer.count - preRollSamples)
                        }
                    }
                    
                    print("Buffer count: \(self.streamingBuffer.count), silenceFrames: \(self.silenceFrames), hasStarted: \(self.hasStartedSpeaking)")
                    
                    var requiredSilence = 5 // 0.16s base silence for ultra-snappy short commands
                    if self.streamingBuffer.count > 16000 * 5 {
                        requiredSilence = 12 // 0.38s pause if buffer > 5s (longer commands tolerance)
                    }
                    if self.streamingBuffer.count > 16000 * 30 {
                        requiredSilence = 6 // 0.2s pause if buffer > 30s
                    }
                    if self.streamingBuffer.count > 16000 * 45 {
                        requiredSilence = 3 // 0.1s pause if buffer > 45s
                    }
                    if self.streamingBuffer.count > 16000 * 55 {
                        requiredSilence = 0 // Instant flush if buffer > 55s to prevent crash
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
                            let normalizedChunk = audioManager.normalizeAudio(data: chunkToProcess)
                            if let result = await modelManager.predict(audioData: normalizedChunk, isLivePreview: false) {
                                if !result.trimmingCharacters(in: .whitespaces).isEmpty {
                                    await MainActor.run {
                                        self.committedHistory.append(result)
                                        self.transcribedText = "..."
                                    }
                                } else {
                                    await MainActor.run { self.transcribedText = "..." }
                                }
                            }
                            await MainActor.run { self.isProcessing = false }
                        }
                    } 
                    else if self.streamingBuffer.count >= 16000 && !self.isProcessing && self.silenceFrames <= requiredSilence {
                        // INTERMEDIATE INFERENCE
                        // Throttle to run every 0.5 seconds (8000 samples)
                        if self.streamingBuffer.count - self.lastProcessedBufferCount >= 8000 {
                            self.lastProcessedBufferCount = self.streamingBuffer.count
                            let chunk = self.streamingBuffer
                            
                            self.isProcessing = true
                            Task {
                                let normalizedChunk = audioManager.normalizeAudio(data: chunk)
                                
                                if let result = await modelManager.predict(audioData: normalizedChunk, isLivePreview: true) {
                                    await MainActor.run {
                                        self.transcribedText = result
                                    }
                                }
                                await MainActor.run { self.isProcessing = false }
                            }
                        }
                    }
                }
            }
        }
    }
}
