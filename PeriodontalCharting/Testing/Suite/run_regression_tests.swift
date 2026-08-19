#if REGRESSION_TEST
import Foundation
import Accelerate

@main
struct RegressionRunner {
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count < 3 {
            print("Usage: run_regression_tests <transcript.txt or audio.m4a> <ground_truth.json> [--save]")
            return
        }
        
        let transcriptPath = args[1] 
        let groundTruthPath = args[2]
        let saveMode = args.count > 3 && args[3] == "--save"
        
        UserDefaults.standard.set(false, forKey: "useMLTokenizer")
        
        var mouth = ToothObject.fullMouthEmpty()
        var parser = StatefulParser(configuration: ChartingConfiguration())
        
        if transcriptPath.hasSuffix(".m4a") || transcriptPath.hasSuffix(".wav") {
            try await runAudioTest(path: transcriptPath, parser: &parser, mouth: &mouth)
        } else {
            try runTextTest(path: transcriptPath, parser: &parser, mouth: &mouth)
        }
        
        if saveMode {
            // Save the actual output as the new ground truth
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let array = Array(mouth.values).sorted(by: { $0.toothNumber < $1.toothNumber })
            let data = try encoder.encode(array)
            try data.write(to: URL(fileURLWithPath: groundTruthPath))
            print("✅ SAVED: New ground truth written to \(groundTruthPath)")
        } else {
            // Read the ground truth JSON
            let gtData = try Data(contentsOf: URL(fileURLWithPath: groundTruthPath))
            let decoder = JSONDecoder()
            let gtArray = try decoder.decode([ToothObject].self, from: gtData)
            var expectedMouth: [Int: ToothObject] = [:]
            for t in gtArray { expectedMouth[t.toothNumber] = t }
            
            // Compare
            let diffs = ChartTestingUtilities.compareCharts(expected: expectedMouth, actual: mouth)
            if diffs.isEmpty {
                print("✅ PASSED: No differences found!")
            } else {
                print("❌ FAILED: Differences found:")
                for d in diffs {
                    print("  - \(d)")
                }
            }
        }
        print("--------------------------------------------------\n")
    }

    static func runTextTest(path: String, parser: inout StatefulParser, mouth: inout [Int: ToothObject]) throws {
        let rawContent = try String(contentsOfFile: path, encoding: .utf8)
        let transcriptRaw = rawContent.replacingOccurrences(of: #"(?<=\d)(?=\d)"#, with: " ", options: .regularExpression)
        
        print("--- Testing Transcript: \(path.components(separatedBy: "/").last ?? "") ---")
        
        let tokens = TokenizerManager.shared.tokenize(text: transcriptRaw, isFinal: true, currentMetric: parser.cursor.currentMetric)
        print("DEBUG TOKENS: \(tokens)")
        parser.consume(tokens: tokens, isFinal: true)
        
        let commands = parser.commands
        for command in commands {
            ChartProcessor.apply(command: command, to: &mouth)
        }
    }

    @MainActor
    static func runAudioTest(path: String, parser: inout StatefulParser, mouth: inout [Int: ToothObject]) async throws {
        print("--- Testing Audio File: \(path.components(separatedBy: "/").last ?? "") ---")
        
        // 1. Initialize engine
        await Wav2VecEngine.shared.loadModel()
        
        // 2. Load audio
        let url = URL(fileURLWithPath: path)
        guard var audioData = Wav2VecAudioCapture.shared.readAudioFile(url: url) else {
            print("Failed to read audio file")
            return
        }
        
        Wav2VecAudioCapture.shared.resetConditioning()
        Wav2VecAudioCapture.shared.conditionAudio(buffer: &audioData)
        
        print("Loaded \(audioData.count) audio samples (\(Double(audioData.count)/16000.0) seconds)")
        
        // 3. Emulate the ViewModel chunking
        var streamingBuffer: [Float] = []
        var committedHistory: [String] = []
        var hasStartedSpeaking = false
        var silenceFrames = 0
        var chunkIndex = 0
        let chunkSize = 512
        
        var currentCommandsProcessed = 0
        
        // Local function to feed parser and process commands
        func processTranscript(_ text: String, isFinal: Bool) {
            let tokens = TokenizerManager.shared.tokenize(text: text, isFinal: isFinal, currentMetric: parser.cursor.currentMetric, parserCurrentValues: parser.pendingNumbers.count, parserExpectedValues: parser.activeSelection?.expectedSlots ?? 3)
            parser.consume(tokens: tokens, isFinal: isFinal)
            
            let commands = parser.commands
            while currentCommandsProcessed < commands.count {
                ChartProcessor.apply(command: commands[currentCommandsProcessed], to: &mouth)
                currentCommandsProcessed += 1
            }
        }
        
        var baselineRMS: Float = 0.0
        
        while chunkIndex < audioData.count {
            let endIndex = min(chunkIndex + chunkSize, audioData.count)
            let chunk = Array(audioData[chunkIndex..<endIndex])
            chunkIndex += chunkSize
            
            // Simple RMS energy calculation to emulate VAD speech detection
            var rms: Float = 0
            vDSP_rmsqv(chunk, 1, &rms, vDSP_Length(chunk.count))
            
            let threshold = max(0.001, baselineRMS * 2.0)
            let isSpeech = rms > threshold
            
            if !isSpeech {
                baselineRMS = baselineRMS * 0.99 + rms * 0.01
            }
            
            if isSpeech {
                hasStartedSpeaking = true
                silenceFrames = 0
            } else if hasStartedSpeaking {
                silenceFrames += 1
            }
            
            streamingBuffer.append(contentsOf: chunk)
            
            let preRollSamples = 16000 * 1
            if !hasStartedSpeaking && silenceFrames > 5 {
                if streamingBuffer.count > preRollSamples {
                    streamingBuffer.removeFirst(streamingBuffer.count - preRollSamples)
                }
            }
            
            var requiredSilence = 15
            if streamingBuffer.count > 16000 * 15 { requiredSilence = 10 }
            if streamingBuffer.count > 16000 * 30 { requiredSilence = 5 }
            if streamingBuffer.count > 16000 * 45 { requiredSilence = 3 }
            if streamingBuffer.count > 16000 * 55 { requiredSilence = 0 }
            
            if hasStartedSpeaking && silenceFrames >= requiredSilence && streamingBuffer.count > 16000 {
                let chunkToProcess = streamingBuffer
                streamingBuffer.removeAll()
                silenceFrames = 0
                hasStartedSpeaking = false
                
                let zeroPadding = Array(repeating: Float(0.0), count: 8000) // 0.5s padding
                let paddedChunk = chunkToProcess + zeroPadding
                let normalizedChunk = Wav2VecAudioCapture.shared.normalizeAudio(data: paddedChunk)
                
                if let result = await Wav2VecEngine.shared.predict(audioData: normalizedChunk, isLivePreview: false) {
                    if !result.trimmingCharacters(in: .whitespaces).isEmpty {
                        committedHistory.append(result)
                        processTranscript(result, isFinal: false)
                        print("COMMIT: \(result)")
                    }
                }
            }
        }
        
        // Final flush
        if !streamingBuffer.isEmpty {
            let normalizedChunk = Wav2VecAudioCapture.shared.normalizeAudio(data: streamingBuffer)
            if let result = await Wav2VecEngine.shared.predict(audioData: normalizedChunk, isLivePreview: false) {
                if !result.trimmingCharacters(in: .whitespaces).isEmpty {
                    committedHistory.append(result)
                    processTranscript(result, isFinal: false)
                    print("FINAL COMMIT: \(result)")
                }
            }
        }
        
        // Finalize parser
        processTranscript("", isFinal: true)
    }
}
#endif
