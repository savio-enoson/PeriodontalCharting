import SwiftUI
import Combine

@MainActor
class AIVoiceViewModel: ObservableObject {
    @Published var liveTranscription: String = ""
    @Published var isListening: Bool = false
    
    // Stubs for future parsing architecture
    @Published var currentCommand: AnnotationCommand? = nil
    @Published var commandHistory: [AnnotationCommand] = []
    
    private var simulationTask: Task<Void, Never>?
    
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

BOP dari Mesio Bukal 26 sampai Disto bukal 24.
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

15 palatal. Resesi bukal dan disto lingual 1. 
16 Resesi Mesio bukal 2. Bukal 4. Distol bukal 2
17 resesi mesio bukal 1
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
    
    /// Simulates a live dictation feed from a given string, appending words at the specified WPM.
    func simulateTranscription(from text: String, wpm: Int = 100) {
        simulationTask?.cancel()
        liveTranscription = ""
        isListening = true
        
        // Use a basic regex to split by whitespace and newlines but keep some sentence structure if needed, 
        // for now just split by whitespace
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        
        // Calculate delay per word. 120 WPM = 2 words per sec = 0.5 sec per word.
        let wordsPerSecond = Double(wpm) / 60.0
        let secondsPerWord = 1.0 / wordsPerSecond
        let nanosecondsPerWord = UInt64(secondsPerWord * 1_000_000_000)
        
        simulationTask = Task {
            for word in words {
                if Task.isCancelled { break }
                
                if !liveTranscription.isEmpty {
                    liveTranscription += " "
                }
                liveTranscription += word
                
                let parser = VoiceCommandParser(configuration: ChartingConfiguration())
                let parsedCommands = parser.parse(text: liveTranscription)
                
                self.commandHistory = parsedCommands
                self.currentCommand = parsedCommands.last
                
                try? await Task.sleep(nanoseconds: nanosecondsPerWord)
            }
            isListening = false
        }
    }
    
    func stopSimulation() {
        simulationTask?.cancel()
        isListening = false
    }
}
