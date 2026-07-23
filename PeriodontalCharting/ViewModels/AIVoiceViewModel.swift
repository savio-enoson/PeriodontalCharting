import SwiftUI
import Combine

@MainActor
class AIVoiceViewModel: ObservableObject {
    @Published var liveTranscription: String = ""
    @Published var isListening: Bool = false
    
    // Stubs for future parsing architecture
    @Published var currentCommand: AnnotationCommand? = nil
    @Published var commandHistory: [AnnotationCommand] = []
    @Published var currentCursor: ChartingCursor? = nil
    @Published var activeSelection: TeethSelection? = nil
    @Published var pendingValues: [String] = []
    @Published var wpm: Double = 100.0
    
    @Published var selectedTestTranscriptName: String = TestTranscripts.all.first?.0 ?? ""
    var selectedTestTranscript: String {
        return TestTranscripts.all.first(where: { $0.0 == selectedTestTranscriptName })?.1 ?? ""
    }
    private var simulationTask: Task<Void, Never>?
    private var flushTimer: Timer?
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
        flushTimer?.invalidate()
        isListening = false
    }
    
    func parseInstant(text: String) {
        stopSimulation()
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

    private func startSimulation(from text: String?) {
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
        
        simulationTask = Task {
            while currentWordIndex < words.count {
                if Task.isCancelled { break }
                
                let word = words[currentWordIndex]
                if !liveTranscription.isEmpty && word != "\n" && word != "." && word != "," {
                    liveTranscription += " "
                }
                liveTranscription += word
                
                let parser = VoiceCommandParser(configuration: self.getConfiguration())
                let parsedCommands = parser.parse(text: self.liveTranscription, isFinal: false)
                
                self.commandHistory = parsedCommands
                
                if let last = parsedCommands.last, last.operation == parser.cursor.currentMetric {
                    self.currentCommand = last
                } else {
                    self.currentCommand = nil
                }
                
                self.currentCursor = parser.cursor
                self.activeSelection = parser.activeSelection
                self.pendingValues = parser.pendingValues
                
                self.flushTimer?.invalidate()
                self.flushTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        let parserFinal = VoiceCommandParser(configuration: self.getConfiguration())
                        let parsedFinal = parserFinal.parse(text: self.liveTranscription, isFinal: true)
                        self.commandHistory = parsedFinal
                        if let last = parsedFinal.last, last.operation == parserFinal.cursor.currentMetric {
                            self.currentCommand = last
                        } else {
                            self.currentCommand = nil
                        }
                        self.currentCursor = parserFinal.cursor
                        self.activeSelection = parserFinal.activeSelection
                        self.pendingValues = parserFinal.pendingValues
                    }
                }
                
                currentWordIndex += 1
                
                let wordsPerSecond = wpm / 60.0
                let secondsPerWord = 1.0 / wordsPerSecond
                try? await Task.sleep(for: .seconds(secondsPerWord))
            }
            
            // Final flush when completely done
            self.flushTimer?.invalidate()
            let parserFinal = VoiceCommandParser(configuration: self.getConfiguration())
            let parsedFinal = parserFinal.parse(text: self.liveTranscription, isFinal: true)
            self.commandHistory = parsedFinal
            if let last = parsedFinal.last, last.operation == parserFinal.cursor.currentMetric {
                self.currentCommand = last
            } else {
                self.currentCommand = nil
            }
            self.currentCursor = parserFinal.cursor
            self.activeSelection = parserFinal.activeSelection
            self.pendingValues = parserFinal.pendingValues
            
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
}
