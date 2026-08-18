import SwiftUI
import Combine
import AVFoundation

@MainActor
class AIVoiceViewModel: ObservableObject {
    @Published var committedTranscription: String = ""
    @Published var uncommittedTranscription: String = ""
    @Published var isListening: Bool = false
    // True while real Wav2Vec dictation is feeding the parser (vs. the debug
    // simulation, which sets `isListening`). Kept separate so both controls can
    // show independent state; the two are mutually exclusive at runtime.
    @Published var isDictating: Bool = false
    // True after the mic is turned off but while the tail chunk's gate pass and
    // decode are still landing. The chart is not final yet, so the mic button
    // shows a "still working" state and stays disabled until this flips back.
    @Published var isFinishing: Bool = false

    var currentStatusMessage: String {
        wav2VecTranscriber.statusMessage
    }

    // Real on-device transcription (Wav2Vec2), already speaker-gated. AI Mode
    // drives it and consumes its confirmed chunks.
    private let wav2VecTranscriber = Wav2VecViewModel()

    /// Speaker-filter state for the AI Mode header. Reading it inside a SwiftUI
    /// body tracks the transcriber directly — no @Published mirror needed.
    var gateStatus: Wav2VecViewModel.GateStatus {
        wav2VecTranscriber.gateStatus
    }
    
    // Stubs for future parsing architecture
    @Published var currentCommand: AnnotationCommand? = nil
    /// The commands driving the chart. In live dictation this is the *preview*
    /// (parsed from the full confirmed+unconfirmed transcript) so the chart is as
    /// accurate as the Transcribe sheet.
    @Published var commandHistory: [AnnotationCommand] = []
    /// Commands parsed from *confirmed-only* text during live dictation. The chart
    /// ghosts cells present in `commandHistory` (preview) but not yet here. `nil`
    /// outside live dictation → nothing ghosted (simulation/instant show all solid).
    @Published var committedCommands: [AnnotationCommand]? = nil
    @Published var currentCursor: ChartingCursor? = nil
    @Published var activeSelection: TeethSelection? = nil
    @Published var pendingValues: [String] = []
    @Published var wpm: Double = 120.0
    
    /// The live session parser. Created when dictation begins, held alive for
    /// the entire session, consumed chunk-by-chunk. nil outside a session.
    private var sessionParser: StatefulParser? = nil
    
    /// Number of commands in sessionParser at the last confirmed-chunk boundary.
    /// Commands at indices < this value are "committed" (solid); at >= are "preview" (ghosted).
    private var committedCommandCount: Int = 0
    
    @Published var selectedTestTranscriptName: String = TestTranscripts.all.first?.0 ?? ""
    var selectedTestTranscript: String {
        return TestTranscripts.all.first(where: { $0.0 == selectedTestTranscriptName })?.1 ?? ""
    }
    private var simulationTask: Task<Void, Never>?
    private var words: [String] = []
    private var currentWordIndex: Int = 0
    
    static let debugTranscript = """
resesi 18, 17, 16, -1 -1
"""
    
    /// Initializes the starting cursor position if it hasn't been set yet.
    func initializeCursorIfNeeded() {
        if self.currentCursor == nil {
            self.currentCursor = StatefulParser(configuration: self.getConfiguration()).cursor
        }
    }
    
    /// Toggles the live dictation feed simulation. If paused, it resumes.
    func toggleSimulation(from text: String? = nil) {
        if isListening {
            internalStopSimulation()
        } else {
            startSimulation(from: text)
        }
    }
    
    func stopSimulation() {
        simulationTask?.cancel()
        isListening = false
    }
    
    func parseInstant(text: String) {
        stopSimulation()
        committedCommands = nil   // debug/instant: no ghosting, everything solid
        
        // Simulate Wav2Vec2 STT engine by forcing spaces between consecutive digits
        let sttSimulated = text.replacingOccurrences(of: #"(?<=\d)(?=\d)"#, with: " ", options: .regularExpression)
        let chunks = sttSimulated.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        
        committedTranscription = ""
        uncommittedTranscription = ""
        
        var parser = StatefulParser(configuration: self.getConfiguration())
        
        for (idx, chunk) in chunks.enumerated() {
            let isFinal = idx == chunks.count - 1
            if !committedTranscription.isEmpty {
                committedTranscription += " \n "
            }
            committedTranscription += chunk
            
            let parserCurrentValues = parser.pendingNumbers.count
            let parserExpectedValues = parser.activeSelection?.expectedSlots ?? 3
            let tokens = TokenizerManager.shared.tokenize(text: chunk, isFinal: isFinal, currentMetric: parser.cursor.currentMetric, parserCurrentValues: parserCurrentValues, parserExpectedValues: parserExpectedValues)
            parser.consume(tokens: tokens, isFinal: isFinal)
        }
        
        self.commandHistory = parser.commands
        if let last = parser.commands.last, last.operation == parser.cursor.currentMetric {
            self.currentCommand = last
        } else {
            self.currentCommand = nil
        }
        self.currentCursor = parser.cursor
        self.activeSelection = parser.activeSelection
        self.pendingValues = parser.pendingValues
    }
    
    private func internalStopSimulation() {
        stopSimulation()
    }

    // MARK: - Audio File Simulation

    /// Feeds a recorded audio file through the real Wav2Vec pipeline (decode + gate)
    /// as if it were live mic input, so a fixed clip can drive the same
    /// preview/confirmed charting path as dictation. `speedMultiplier` throttles
    /// playback to emulate real-time pacing.
    func audioFileSimulation(fileURL: URL, speedMultiplier: Double) {
        stopSimulation()
        stopLiveDictation()

        guard let file = try? AVAudioFile(forReading: fileURL),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            print("Failed to setup audio file reading")
            return
        }

        let ratio = 16000.0 / file.processingFormat.sampleRate
        let targetFrameCapacity = AVAudioFrameCount(Double(file.length) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: targetFrameCapacity) else { return }

        var error: NSError?
        var isDone = false
        converter.convert(to: outputBuffer, error: &error) { packetCount, outStatus in
            if isDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            let readCapacity = AVAudioFrameCount(8192)
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: readCapacity) else {
                outStatus.pointee = .noDataNow
                return nil
            }
            do {
                try file.read(into: inputBuffer, frameCount: readCapacity)
                if inputBuffer.frameLength == 0 {
                    isDone = true
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return inputBuffer
            } catch {
                isDone = true
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        guard let channelData = outputBuffer.floatChannelData else { return }
        let audioArray = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))

        isDictating = true
        committedTranscription = ""
        uncommittedTranscription = ""
        commandHistory = []
        committedCommands = []
        currentCommand = nil
        initializeCursorIfNeeded()

        sessionParser = StatefulParser(configuration: getConfiguration())
        committedCommandCount = 0

        wav2VecTranscriber.onLiveTranscript = { [weak self] fullText in
            guard let self = self else { return }
            let committed = self.committedTranscription
            if fullText.hasPrefix(committed) {
                let uncommitted = String(fullText.dropFirst(committed.count)).trimmingCharacters(in: .whitespaces)
                self.uncommittedTranscription = uncommitted.isEmpty ? "" : " " + uncommitted
            } else {
                self.uncommittedTranscription = fullText
            }
        }
        wav2VecTranscriber.onConfirmedTranscript = { [weak self] confirmed in
            guard let self = self else { return }
            self.processConfirmedChunk(confirmed)
        }

        Task { [weak self] in
            guard let self = self else { return }
            await self.wav2VecTranscriber.loadModel()
            TokenizerManager.shared.loadModel()
            guard self.isDictating else { return }
            self.wav2VecTranscriber.startSimulation(audio: audioArray, speedMultiplier: speedMultiplier)
        }
    }

    // MARK: - Live dictation (gated Wav2Vec transcription → annotation parser)

    func toggleLiveDictation() {
        if isDictating { stopLiveDictation() } else { startLiveDictation() }
    }

    // Begin real on-device dictation. "Optimistic preview + confirmed commit":
    // the chart is driven by the full running transcript (preview) so it tracks
    // the voice closely, while a separate confirmed-only pass
    // (`committedCommands`) marks which cells are finalized — the rest render
    // ghosted.
    //
    // ONLY THE CONFIRMED STREAM IS SPEAKER-GATED. `onLiveTranscript` is preview
    // text from an ungated buffer and never reaches the parser;
    // `onConfirmedTranscript` carries chunks that have already been through the
    // gate and the extractor. Do not wire the parser to the live hook.
    func startLiveDictation() {
        stopSimulation()          // the two feeds are mutually exclusive
        isDictating = true
        committedTranscription = ""
        uncommittedTranscription = ""
        commandHistory = []
        committedCommands = []
        currentCommand = nil
        initializeCursorIfNeeded()

        sessionParser = StatefulParser(configuration: getConfiguration())
        committedCommandCount = 0

        wav2VecTranscriber.onLiveTranscript = { [weak self] fullText in
            guard let self = self else { return }
            let committed = self.committedTranscription
            if fullText.hasPrefix(committed) {
                let uncommitted = String(fullText.dropFirst(committed.count)).trimmingCharacters(in: .whitespaces)
                self.uncommittedTranscription = uncommitted.isEmpty ? "" : " " + uncommitted
            } else {
                self.uncommittedTranscription = fullText
            }
        }
        wav2VecTranscriber.onConfirmedTranscript = { [weak self] confirmed in
            guard let self = self else { return }
            self.processConfirmedChunk(confirmed)
        }

        Task { [weak self] in
            guard let self else { return }
            await self.wav2VecTranscriber.loadModel()
            guard self.isDictating else { return }  // stopped during model load
            self.wav2VecTranscriber.startLive()
        }
    }

    func stopLiveDictation() {
        guard isDictating else { return }
        isDictating = false
        // Mic is off, but the tail chunk still has a gate pass and a decode ahead
        // of it. `isFinishing` holds the mic button until both land. The class is
        // @MainActor, so every mutation below stays on the main actor; callers
        // stay synchronous and untouched.
        isFinishing = true
        Task {
            defer { isFinishing = false }

            // AWAITED. `stopLive` returns only once the final chunk has reached
            // `onConfirmedTranscript`, so the leftover text below is genuinely
            // leftover. Firing and forgetting dropped whatever was said last,
            // because the parser was consumed and nil'd before the tail arrived.
            await wav2VecTranscriber.stopLive()
            wav2VecTranscriber.onLiveTranscript = nil
            wav2VecTranscriber.onConfirmedTranscript = nil

            let finalOutput = committedTranscription + uncommittedTranscription
            if finalOutput.hasPrefix(committedTranscription) {
                let leftover = String(finalOutput.dropFirst(committedTranscription.count)).trimmingCharacters(in: .whitespaces)
                if !leftover.isEmpty {
                    let parserCurrentValues = sessionParser?.pendingNumbers.count ?? 0
                    let parserExpectedValues = sessionParser?.activeSelection?.expectedSlots ?? 3
                    let tokens = TokenizerManager.shared.tokenize(text: leftover, isFinal: true, currentMetric: sessionParser?.cursor.currentMetric, parserCurrentValues: parserCurrentValues, parserExpectedValues: parserExpectedValues)
                    sessionParser?.consume(tokens: tokens, isFinal: true)
                } else {
                    sessionParser?.consume(tokens: [], isFinal: true)
                }
            } else {
                sessionParser?.consume(tokens: [], isFinal: true)
            }

            committedTranscription = finalOutput
            uncommittedTranscription = ""

            if let parser = sessionParser {
                committedCommandCount = parser.commands.count
                self.commandHistory = parser.commands
                self.committedCommands = parser.commands
                if let last = parser.commands.last, last.operation == parser.cursor.currentMetric {
                    self.currentCommand = last
                } else {
                    self.currentCommand = nil
                }
                self.currentCursor = parser.cursor
                self.activeSelection = parser.activeSelection
                self.pendingValues = parser.pendingValues
            }

            sessionParser = nil
        }
    }

    private func processConfirmedChunk(_ confirmed: String) {
        let newChunk: String
        if confirmed.hasPrefix(self.committedTranscription) {
            newChunk = String(confirmed.dropFirst(self.committedTranscription.count)).trimmingCharacters(in: .whitespaces)
        } else {
            newChunk = confirmed // fallback
        }
        
        self.committedTranscription = confirmed
        self.uncommittedTranscription = ""
        
        if !newChunk.isEmpty {
            let parserCurrentValues = sessionParser?.pendingNumbers.count ?? 0
            let parserExpectedValues = sessionParser?.activeSelection?.expectedSlots ?? 3
            let tokens = TokenizerManager.shared.tokenize(text: newChunk, isFinal: false, currentMetric: sessionParser?.cursor.currentMetric, parserCurrentValues: parserCurrentValues, parserExpectedValues: parserExpectedValues)
            sessionParser?.consume(tokens: tokens, isFinal: false)
            
            if let parser = sessionParser {
                committedCommandCount = parser.commands.count
                self.commandHistory = parser.commands
                self.committedCommands = Array(parser.commands.prefix(committedCommandCount))
                if let last = parser.commands.last, last.operation == parser.cursor.currentMetric {
                    self.currentCommand = last
                } else {
                    self.currentCommand = nil
                }
                self.currentCursor = parser.cursor
                self.activeSelection = parser.activeSelection
                self.pendingValues = parser.pendingValues
            }
        }
    }

    private func startSimulation(from text: String?) {
        stopLiveDictation()   // the two feeds are mutually exclusive
        committedCommands = nil   // simulation: no ghosting, everything solid
        if let newText = text {
            // Simulate Wav2Vec2 STT engine by forcing spaces between consecutive digits
            let sttSimulated = newText.replacingOccurrences(of: #"(?<=\d)(?=\d)"#, with: " ", options: .regularExpression)
            self.words = sttSimulated.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            self.currentWordIndex = 0
            self.committedTranscription = ""
            self.uncommittedTranscription = ""
            self.commandHistory = []
            self.currentCommand = nil
        }
        
        isListening = true
        simulationTask?.cancel()
        
        simulationTask = Task { @MainActor in
            let config = self.getConfiguration()
            while currentWordIndex < words.count {
                if Task.isCancelled { break }
                
                let chunk = words[currentWordIndex]
                if !committedTranscription.isEmpty {
                    committedTranscription += " \n "
                }
                committedTranscription += chunk
                
                let currentText = self.committedTranscription
                
                // Offload parsing to a background thread to prevent UI lag
                let parsedResult = await Task.detached {
                    // For simulation, we parse from scratch with the accumulated chunks,
                    // but we do NOT pass isFinal: true until the very end, to preserve chunk state behaviors.
                    return self.parseOffline(text: currentText, config: config, isFinal: false)
                }.value
                
                self.commandHistory = parsedResult.0
                
                if let last = parsedResult.0.last, last.operation == parsedResult.1.currentMetric {
                    self.currentCommand = last
                } else {
                    self.currentCommand = nil
                }
                
                self.currentCursor = parsedResult.1
                self.activeSelection = parsedResult.2
                self.pendingValues = parsedResult.3
                
                currentWordIndex += 1
                
                try? await Task.sleep(for: .seconds(0.8)) // Emulate time between chunks
            }
            
            // Final flush when completely done
            let finalText = self.committedTranscription
            let finalResult = await Task.detached {
                return self.parseOffline(text: finalText, config: config, isFinal: true)
            }.value
            
            self.commandHistory = finalResult.0
            if let last = finalResult.0.last, last.operation == finalResult.1.currentMetric {
                self.currentCommand = last
            } else {
                self.currentCommand = nil
            }
            self.currentCursor = finalResult.1
            self.activeSelection = finalResult.2
            self.pendingValues = finalResult.3
            
            isListening = false
        }
    }
    
    private func getConfiguration() -> ChartingConfiguration {
        if let data = UserDefaults.standard.data(forKey: "ChartingConfiguration"),
           let config = try? JSONDecoder().decode(ChartingConfiguration.self, from: data) {
            return config
        }
        return ChartingConfiguration()
    }
    nonisolated private func parseOffline(text: String, config: ChartingConfiguration, isFinal: Bool) -> ([AnnotationCommand], ChartingCursor, TeethSelection?, [String]) {
        var parser = StatefulParser(configuration: config)
        let parserCurrentValues = parser.pendingNumbers.count
        let parserExpectedValues = parser.activeSelection?.expectedSlots ?? 3
        let tokens = TokenizerManager.shared.tokenize(text: text, isFinal: isFinal, currentMetric: parser.cursor.currentMetric, parserCurrentValues: parserCurrentValues, parserExpectedValues: parserExpectedValues)
        parser.consume(tokens: tokens, isFinal: isFinal)
        return (parser.commands, parser.cursor, parser.activeSelection, parser.pendingValues)
    }
}

// Silence strict concurrency warnings for struct models crossed through Task.detached
extension ChartingConfiguration: @unchecked Sendable {}

extension AnnotationCommand: @unchecked Sendable {}
extension ChartingCursor: @unchecked Sendable {}
extension TeethSelection: @unchecked Sendable {}
