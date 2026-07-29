import SwiftUI
import Combine

@MainActor
class AIVoiceViewModel: ObservableObject {
    @Published var liveTranscription: String = ""
    @Published var isListening: Bool = false
    /// True while real Whisper dictation is feeding the parser (vs. the debug
    /// simulation, which sets `isListening`). Kept separate so both controls can
    /// show independent state; the two are mutually exclusive at runtime.
    @Published var isDictating: Bool = false

    /// Real on-device transcription. AI Mode drives it and consumes its confirmed
    /// chunks; the standalone LiveTranscriptionView uses its own instance.
    private let transcriber = TranscriptionViewModel()
    
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
gigi 18 gak ada
2 2 2
3 4 5
5 3 3
2 2 2

resesi dari mesio bukal 17 sampai disto bukal 15 minus 1
BOP dari bukal 16 hingga bukal 15

Lanjut
2 2 2 
2 2 2
2 2 2

2 2 2
2 2 2 
2 2 2
3 4 5
5 5 5
6 6 4
3 2 2

BOP dari mesio bukal 24 sampai mesio bukal 27
28 gak ada

Lanjut palatal
2 2 2
2 2 4
4 4 4
4 2 2

BOP dari Mesio palatal 26 sampai Disto palatal 24.
Lanjut, 23.
2 2 2
2 2 2
2 2 2

2 2 2
2 2 2
2 2 2
2 2 2
2 2 2
4 3 3
3 3 2

15 palatal. Resesi palatal dan disto palatal 1.
16 Resesi Mesio palatal 2. palatal 4. Disto palatal 2
17 resesi mesio palatal 1
BOP dimulai dari disto lingual 15 hingga palatal 16
plaque pada semua gigi

rahang bawah
38 gak ada
2 2 2 
2 2 2
2 2 2
2 2 2
2 2 2
2 2 2
2 2 2

2 2 2
2 2 2
Resesi 2 mili pada labial 31, 32, 41, 42

Lanjut 43, 
2 2 2 
2 2 2 
2 2 2 

Resesi 1 mili, distal 45
46 tidak ada

3, 2, 2 

Resesi 1 mili Mesial 47

48 gak ada

Lingual
2 2 3
Resesi 1 mili Mesial
2 2 2
Resesi satu mili distal

2 2 2 
2 2 2
2 2 2
2 2 2

2 2 2
2 2 2
2 2 2

Sampai 37 2
Plaque pada semua gigi
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
        liveTranscription = text
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
        liveTranscription = ""
        commandHistory = []
        committedCommands = []
        lastPreviewText = ""
        currentCommand = nil
        initializeCursorIfNeeded()

        transcriber.inputMode = .live
        transcriber.onLiveTranscript = { [weak self] text in
            self?.liveTranscription = text
            self?.ingestPreview(text)         // full text → chart values + cursor
        }
        transcriber.onConfirmedTranscript = { [weak self] confirmed in
            self?.ingestCommitted(confirmed)  // confirmed text → committed set (ghosting)
        }

        Task { [weak self] in
            guard let self else { return }
            await self.transcriber.loadModel()
            guard self.isDictating else { return }  // stopped during model load
            self.transcriber.startLive()
        }
    }

    func stopLiveDictation() {
        guard isDictating else { return }
        isDictating = false
        transcriber.stopLive()
        transcriber.onLiveTranscript = nil
        transcriber.onConfirmedTranscript = nil
        // Final flush over everything captured, then mark it all committed so no
        // cells remain ghosted once dictation ends.
        lastPreviewText = ""
        ingestPreview(liveTranscription, isFinal: true)
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
            self.liveTranscription = ""
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
                if !liveTranscription.isEmpty && word != "\n" && word != "." && word != "," {
                    liveTranscription += " "
                }
                liveTranscription += word
                
                let currentText = self.liveTranscription
                
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
            let finalText = self.liveTranscription
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

