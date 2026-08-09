import SwiftUI
import Combine

@MainActor
class AIVoiceViewModel: ObservableObject {
    @Published var committedTranscription: String = ""
    @Published var uncommittedTranscription: String = ""
    @Published var isListening: Bool = false
    /// True while real Whisper dictation is feeding the parser (vs. the debug
    /// simulation, which sets `isListening`). Kept separate so both controls can
    /// show independent state; the two are mutually exclusive at runtime.
    @Published var isDictating: Bool = false
    
    var currentStatusMessage: String {
        if UserDefaults.standard.bool(forKey: "useOfflineWav2Vec") {
            return wav2VecTranscriber.statusMessage
        } else {
            return transcriber.statusMessage
        }
    }

    /// Real on-device transcription. AI Mode drives it and consumes its confirmed
    /// chunks; the standalone LiveTranscriptionView uses its own instance.
    private let transcriber = TranscriptionViewModel()
    private let wav2VecTranscriber = Wav2VecViewModel()
    
    /// Speaker-filter state for the AI Mode header. The transcriber is private, so
    /// this is the only way the view can see it. Reading it inside a SwiftUI body
    /// tracks the @Observable transcriber directly — no @Published mirror needed,
    /// and it cannot go stale.
    var gateStatus: TranscriptionViewModel.GateStatus { 
        if UserDefaults.standard.bool(forKey: "useOfflineWav2Vec") {
            let s = wav2VecTranscriber.gateStatus
            return TranscriptionViewModel.GateStatus(active: s.active, extractorReady: s.extractorReady, spans: s.spans, rejected: s.rejected, routed: s.routed, rescued: s.rescued, withheldSegments: s.withheldSegments, lastDistance: s.lastDistance)
        } else {
            return transcriber.gateStatus 
        }
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
    
    @Published var selectedTestTranscriptName: String = TestTranscripts.all.first?.0 ?? ""
    var selectedTestTranscript: String {
        return TestTranscripts.all.first(where: { $0.0 == selectedTestTranscriptName })?.1 ?? ""
    }
    private var simulationTask: Task<Void, Never>?
    /// Last text handed to `ingestPreview`, to skip redundant re-parses at ~10 Hz.
    private var lastPreviewText: String = ""
    private var words: [String] = []
    private var currentWordIndex: Int = 0
    
    static let debugTranscript = """
resesi 18, 17, 16, -1 -1
"""
    
    /// Initializes the starting cursor position if it hasn't been set yet.
    func initializeCursorIfNeeded() {
        if self.currentCursor == nil {
            self.currentCursor = VoiceCommandParser(configuration: self.getConfiguration()).cursor
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
        committedTranscription = text
        uncommittedTranscription = ""
        let parser = VoiceCommandParser(configuration: self.getConfiguration())
        let parsedFinal = parser.parse(text: text, isFinal: true)
        
        self.commandHistory = parsedFinal
        if let last = parsedFinal.last, last.operation == parser.cursor.currentMetric {
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

    // MARK: - Live dictation (real Whisper transcription → annotation parser)

    func toggleLiveDictation() {
        if isDictating { stopLiveDictation() } else { startLiveDictation() }
    }

    /// Begin real on-device dictation. Tier 3 "optimistic preview + confirmed
    /// commit": the chart is driven by the FULL running transcript (preview) so it
    /// tracks the voice as accurately as the Transcribe sheet, while a separate
    /// confirmed-only pass (`committedCommands`) marks which cells are finalized —
    /// the rest render ghosted. The parser re-derives the whole chart from the full
    /// text each call, so a revised hypothesis self-corrects; nothing sticks wrong.
    func startLiveDictation() {
        stopSimulation()          // the two feeds are mutually exclusive
        isDictating = true
        committedTranscription = ""
        uncommittedTranscription = ""
        commandHistory = []
        committedCommands = []
        lastPreviewText = ""
        currentCommand = nil
        initializeCursorIfNeeded()

        let useWav2Vec = UserDefaults.standard.bool(forKey: "useOfflineWav2Vec")
        
        if useWav2Vec {
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
                self.committedTranscription = confirmed
                self.uncommittedTranscription = ""
                self.ingestPreview(confirmed)
                self.ingestCommitted(confirmed)
            }
        } else {
            transcriber.onLiveTranscript = { [weak self] fullText in
                guard let self = self else { return }
                let committed = self.committedTranscription
                if fullText.hasPrefix(committed) {
                    let uncommitted = String(fullText.dropFirst(committed.count)).trimmingCharacters(in: .whitespaces)
                    self.uncommittedTranscription = uncommitted.isEmpty ? "" : " " + uncommitted
                } else {
                    self.uncommittedTranscription = fullText
                }
            }
            transcriber.onConfirmedTranscript = { [weak self] confirmed in
                guard let self = self else { return }
                self.committedTranscription = confirmed
                self.uncommittedTranscription = ""
                self.ingestPreview(confirmed)
                self.ingestCommitted(confirmed)
            }
        }

        Task { [weak self] in
            guard let self else { return }
            if useWav2Vec {
                await self.wav2VecTranscriber.loadModel()
            } else {
                await self.transcriber.loadModel()
            }
            TokenizerManager.shared.loadModel()
            guard self.isDictating else { return }  // stopped during model load
            if useWav2Vec {
                self.wav2VecTranscriber.startLive()
            } else {
                self.transcriber.startLive()
            }
        }
    }

    func stopLiveDictation() {
        guard isDictating else { return }
        isDictating = false
        
        if UserDefaults.standard.bool(forKey: "useOfflineWav2Vec") {
            wav2VecTranscriber.stopLive()
            wav2VecTranscriber.onLiveTranscript = nil
            wav2VecTranscriber.onConfirmedTranscript = nil
        } else {
            transcriber.stopLive()
            transcriber.onLiveTranscript = nil
            transcriber.onConfirmedTranscript = nil
        }
        // Final flush over everything captured, then mark it all committed so no
        // cells remain ghosted once dictation ends.
        lastPreviewText = ""
        let finalOutput = committedTranscription + uncommittedTranscription
        committedTranscription = finalOutput
        uncommittedTranscription = ""
        ingestPreview(finalOutput, isFinal: true)
        committedCommands = commandHistory
    }

    /// Parse the FULL live transcript and publish the chart-driving state (values,
    /// cursor, selection). Skipped when the text hasn't changed since the last pass.
    private func ingestPreview(_ text: String, isFinal: Bool = false) {
        if !isFinal && text == lastPreviewText { return }
        lastPreviewText = text
        guard !text.isEmpty else {
            commandHistory = []
            currentCommand = nil
            return
        }
        let parser = VoiceCommandParser(configuration: getConfiguration())
        let parsed = parser.parse(text: text, isFinal: isFinal)

        self.commandHistory = parsed
        if let last = parsed.last, last.operation == parser.cursor.currentMetric {
            self.currentCommand = last
        } else {
            self.currentCommand = nil
        }
        self.currentCursor = parser.cursor
        self.activeSelection = parser.activeSelection
        self.pendingValues = parser.pendingValues
    }

    /// Parse the confirmed-only text into the committed command set. The chart
    /// ghosts any preview cell not backed by these.
    private func ingestCommitted(_ text: String) {
        guard !text.isEmpty else { committedCommands = []; return }
        let parser = VoiceCommandParser(configuration: getConfiguration())
        committedCommands = parser.parse(text: text, isFinal: false)
    }

    private func startSimulation(from text: String?) {
        stopLiveDictation()   // the two feeds are mutually exclusive
        committedCommands = nil   // simulation: no ghosting, everything solid
        if let newText = text {
            let spaced = newText
                .replacingOccurrences(of: "\n", with: " \n ")
                .replacingOccurrences(of: ".", with: " . ")
                .replacingOccurrences(of: ",", with: " , ")
            self.words = spaced.components(separatedBy: " ").filter { !$0.isEmpty }
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
                
                let word = words[currentWordIndex]
                if !committedTranscription.isEmpty && word != "\n" && word != "." && word != "," {
                    committedTranscription += " "
                }
                committedTranscription += word
                
                let currentText = self.committedTranscription
                
                // Offload parsing to a background thread to prevent UI lag
                let parsedResult = await Task.detached {
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
                
                let wordsPerSecond = wpm / 60.0
                let secondsPerWord = 1.0 / wordsPerSecond
                try? await Task.sleep(for: .seconds(secondsPerWord))
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
        let parser = VoiceCommandParser(configuration: config)
        let commands = parser.parse(text: text, isFinal: isFinal)
        return (commands, parser.cursor, parser.activeSelection, parser.pendingValues)
    }
}

// Silence strict concurrency warnings for struct models crossed through Task.detached
extension ChartingConfiguration: @unchecked Sendable {}

extension AnnotationCommand: @unchecked Sendable {}
extension ChartingCursor: @unchecked Sendable {}
extension TeethSelection: @unchecked Sendable {}

