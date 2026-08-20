#if REGRESSION_TEST
import Foundation
import Accelerate

@main
struct RegressionRunner {
        static func main() async throws {
        UserDefaults.standard.set(false, forKey: "useMLTokenizer")
        
        print("Starting DR LUCKY")
        var mouth1 = ToothObject.fullMouthEmpty()
        var parser1 = StatefulParser(configuration: ChartingConfiguration())
        try await runAudioTest(path: "/Users/vio/XCodeProjects/PeriodontalCharting/PeriodontalCharting/Testing/Raw/dr_lucky_audio.m4a", parser: &parser1, mouth: &mouth1)
        let diffs1 = ChartTestingUtilities.compareCharts(expected: try getExpected(path: "/Users/vio/XCodeProjects/PeriodontalCharting/PeriodontalCharting/Testing/Ground/ground_truth.json"), actual: mouth1)
        print("DR LUCKY DIFFS:", diffs1)
        
        print("Starting STUDENT")
        var mouth2 = ToothObject.fullMouthEmpty()
        var parser2 = StatefulParser(configuration: ChartingConfiguration())
        try await runAudioTest(path: "/Users/vio/XCodeProjects/PeriodontalCharting/PeriodontalCharting/Testing/Raw/student_audio.m4a", parser: &parser2, mouth: &mouth2)
        let diffs2 = ChartTestingUtilities.compareCharts(expected: try getExpected(path: "/Users/vio/XCodeProjects/PeriodontalCharting/PeriodontalCharting/Testing/Ground/student_ground.json"), actual: mouth2)
        print("STUDENT DIFFS:", diffs2)
        
        
        print("\n=== IDEAL TRANSCRIPT TESTS ===")
        
        print("Starting DR LUCKY IDEAL")
        var mouth3 = ToothObject.fullMouthEmpty()
        var parser3 = StatefulParser(configuration: ChartingConfiguration())
        try runTextTest(path: "/Users/vio/XCodeProjects/PeriodontalCharting/PeriodontalCharting/Testing/Raw/dr_lucky_ground.txt", parser: &parser3, mouth: &mouth3)
        let diffs3 = ChartTestingUtilities.compareCharts(expected: try getExpected(path: "/Users/vio/XCodeProjects/PeriodontalCharting/PeriodontalCharting/Testing/Ground/ground_truth.json"), actual: mouth3)
        print("DR LUCKY IDEAL DIFFS:", diffs3)
        
        print("Starting STUDENT IDEAL")
        var mouth4 = ToothObject.fullMouthEmpty()
        var parser4 = StatefulParser(configuration: ChartingConfiguration())
        try runTextTest(path: "/Users/vio/XCodeProjects/PeriodontalCharting/PeriodontalCharting/Testing/Raw/student_ground.txt", parser: &parser4, mouth: &mouth4)
        let diffs4 = ChartTestingUtilities.compareCharts(expected: try getExpected(path: "/Users/vio/XCodeProjects/PeriodontalCharting/PeriodontalCharting/Testing/Ground/student_ground.json"), actual: mouth4)
        print("STUDENT IDEAL DIFFS:", diffs4)

        print("DONE")
        exit(0)
    }

    static func getExpected(path: String) throws -> [Int: ToothObject] {
        let gtData = try Data(contentsOf: URL(fileURLWithPath: path))
        let gtArray = try JSONDecoder().decode([ToothObject].self, from: gtData)
        var expectedMouth: [Int: ToothObject] = [:]
        for t in gtArray { expectedMouth[t.toothNumber] = t }
        return expectedMouth
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
        
        let audioDuration = Double(audioData.count)/16000.0
        print("Loaded \(audioData.count) audio samples (\(audioDuration) seconds)")
        
        let startTime = CFAbsoluteTimeGetCurrent()
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
            var chunk = Array(audioData[chunkIndex..<endIndex])
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
