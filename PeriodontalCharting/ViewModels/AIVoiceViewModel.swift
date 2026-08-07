import SwiftUI
import Combine

@MainActor
class AIVoiceViewModel: ObservableObject {
    /// What the clinician READS. May contain segments the gate has not judged yet.
    @Published var liveTranscription: String = ""
    @Published var isListening: Bool = false
    /// True while real Whisper dictation is feeding the parser (vs. the debug
    /// simulation, which sets `isListening`). Kept separate so both controls can
    /// show independent state; the two are mutually exclusive at runtime.
    @Published var isDictating: Bool = false
    /// True between the clinician tapping stop and the last decode + final gate
    /// pass actually landing. The microphone is already off; the chart is not
    /// final yet. Drives the busy state on the mic button.
    @Published private(set) var isFinishing: Bool = false

    /// Real on-device transcription. AI Mode drives it and consumes its verified
    /// chunks; the standalone LiveTranscriptionView (debug only) uses its own.
    private let transcriber = TranscriptionViewModel()

    /// The in-flight stop, held so nothing else stamps the chart underneath it.
    private var finishTask: Task<Void, Never>?

    /// Last VERIFIED transcript. The final flush parses this, never
    /// `liveTranscription` — which may contain segments the gate never reached,
    /// and nothing ever re-filters a committed command.
    private var lastVerifiedText: String = ""

    /// Keep the finishing indicator on screen for at least this long.
    ///
    /// A stop during a pause completes in ~100 ms — the decode loop is sitting in
    /// its 100 ms sleep and the gate tail pass returns immediately — which is
    /// faster than SwiftUI renders a frame. Worse, `TranscriptionViewModel.stopLive()`
    /// is itself @MainActor, so when none of its awaits genuinely suspend the whole
    /// finish runs in ONE main-actor turn and `isFinishing` goes true and false
    /// inside a single render pass. The indicator then never appears at all.
    ///
    /// The cost is a short delay before the mic is tappable again. That is the
    /// right trade: the chart is already committed by then — the wait happens
    /// AFTER the commit — and feedback that only shows up on slow stops is worse
    /// than none, because the clinician cannot tell "finished instantly" from
    /// "the button didn't register".
    private static let minFinishDisplaySeconds = 0.45
    
    /// Speaker-filter state for the AI Mode header. The transcriber is private, so
    /// this is the only way the view can see it. Reading it inside a SwiftUI body
    /// tracks the @Observable transcriber directly — no @Published mirror needed.
    var gateStatus: TranscriptionViewModel.GateStatus { transcriber.gateStatus }
    
    @Published var currentCommand: AnnotationCommand? = nil
    /// The commands driving the chart, parsed from VERIFIED text only. Text the
    /// gate has not judged yet shows in `liveTranscription` but cannot reach a
    /// tooth — that gap is the buffer.
    @Published var commandHistory: [AnnotationCommand] = []
    /// Commands parsed from verified-AND-confirmed text. The chart ghosts cells
    /// present in `commandHistory` but not yet here. `nil` outside live dictation
    /// → nothing ghosted (simulation/instant show all solid).
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

    /// Begin real on-device dictation.
    ///
    /// THREE STREAMS, and the difference between them is the buffer. The clinician
    /// reads everything the gate has not actively rejected, so the panel never
    /// looks dead. The CHART is driven only by text the gate has confirmed came
    /// from him — unjudged text waits. The parser re-derives the whole chart from
    /// the full verified text each call, so a revised hypothesis self-corrects.
    func startLiveDictation() {
        stopSimulation()          // the two feeds are mutually exclusive
        isDictating = true
        liveTranscription = ""
        lastVerifiedText = ""
        commandHistory = []
        committedCommands = []
        lastPreviewText = ""
        currentCommand = nil
        initializeCursorIfNeeded()

        transcriber.onLiveTranscript = { [weak self] text in
            // DISPLAY ONLY. May contain text the gate has not judged yet.
            self?.liveTranscription = text
        }
        transcriber.onVerifiedTranscript = { [weak self] verified in
            // CHART. Verified text only — this is the buffer.
            self?.lastVerifiedText = verified
            self?.ingestPreview(verified)
        }
        transcriber.onConfirmedTranscript = { [weak self] confirmed in
            self?.ingestCommitted(confirmed)  // verified + confirmed → ghosting
        }

        Task { [weak self] in
            guard let self else { return }
            await self.transcriber.loadModel()
            guard self.isDictating else { return }  // stopped during model load
            self.transcriber.startLive()
        }
    }

    /// Stop the microphone, then WAIT for the work already in flight before
    /// finalizing the chart.
    ///
    /// This used to call `transcriber.stopLive()` and immediately nil the
    /// callbacks. `stopLive()` starts asynchronous work — the last decode and the
    /// final speaker-gate pass — so the callbacks were gone before that work
    /// landed, its result fired into nothing, and the final parse ran on text one
    /// decode out of date. The clinician's last sentence was captured,
    /// transcribed, and then discarded.
    ///
    /// That final gate pass matters even more under the buffer: without it the
    /// last spans stay `pending` forever and never reach the chart at all.
    func stopLiveDictation() {
        guard isDictating else { return }
        isDictating = false
        isFinishing = true

        finishTask = Task { [weak self] in
            guard let self else { return }
            let began = Date()

            // Awaits the final decode AND the final gate pass. The callbacks are
            // still connected throughout, so the last words are judged and reach
            // the chart before anything is torn down.
            await self.transcriber.stopLive()

            self.transcriber.onLiveTranscript = nil
            self.transcriber.onVerifiedTranscript = nil
            self.transcriber.onConfirmedTranscript = nil

            // A simulation or a fresh dictation may have taken over while we were
            // finishing. Either owns the chart now; do not stamp over it.
            if !self.isListening && !self.isDictating {
                self.lastPreviewText = ""
                // From the VERIFIED text. Flushing `liveTranscription` here would
                // make every unjudged segment permanent.
                self.ingestPreview(self.lastVerifiedText, isFinal: true)
                self.committedCommands = self.commandHistory
            }

            // Chart is final at this point — only the indicator lingers. Grep
            // `[AI] finish` for how long the real work took: a stop during a pause
            // is ~100 ms, mid-sentence is 1–2 s.
            let elapsed = Date().timeIntervalSince(began)
            print(String(format: "[AI] finish took %.0f ms", elapsed * 1000))
            if elapsed < Self.minFinishDisplaySeconds {
                try? await Task.sleep(
                    nanoseconds: UInt64((Self.minFinishDisplaySeconds - elapsed) * 1_000_000_000))
            }

            self.isFinishing = false
        }
    }

    /// Parse the VERIFIED transcript and publish the chart-driving state (values,
    /// cursor, selection). Skipped when the text hasn't changed since the last pass.
    private func ingestPreview(_ text: String, isFinal: Bool = false) {
        if !isFinal && text == lastPreviewText { return }
        lastPreviewText = text
        guard !text.isEmpty else {
            commandHistory = []
            currentCommand = nil
            // Reset these too. Leaving them meant a withheld speaker could move the
            // cursor and leave it moved — the one piece of chart state that did NOT
            // recompute from scratch.
            currentCursor = VoiceCommandParser(configuration: getConfiguration()).cursor
            activeSelection = nil
            pendingValues = []
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

    /// Parse the verified-and-confirmed text into the committed command set. The
    /// chart ghosts any preview cell not backed by these.
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
        
        // Set BEFORE any suspension point, so a still-finishing stopLiveDictation
        // sees it and skips its final commit rather than racing us for the chart.
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
