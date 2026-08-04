import SwiftUI

struct SelectionDebugMenu: View {
    @Binding var mouth: [Int: ToothObject]
    @EnvironmentObject var selectionModel: ChartSelectionModel
    @EnvironmentObject var aiViewModel: AIVoiceViewModel
    @Environment(\.dismiss) var dismiss
    @ObservedObject var tokenizerManager = TokenizerManager.shared
    
    @State private var showAlert = false
    @State private var alertMessage = ""
    
    var body: some View {
        NavigationStack {
            List {
                Section("Chart Overrides") {
                    Toggle("All Implants", isOn: Binding(
                        get: { mouth.values.allSatisfy { $0.implant } },
                        set: { isOn in
                            for key in mouth.keys {
                                mouth[key]?.implant = isOn
                            }
                        }
                    ))
                }
                
                Section("Tokenizer System") {
                    Toggle("Use ML Tokenizer (Phase 1)", isOn: $tokenizerManager.useMLTokenizer)
                    
                    Button("Compare ML vs Legacy on Selected") {
                        let targetName = aiViewModel.selectedTestTranscriptName
                        var foundText: String? = nil
                        for tup in TestTranscripts.all {
                            if tup.0 == targetName {
                                foundText = tup.1
                                break
                            }
                        }
                        if let text = foundText {
                            alertMessage = "Comparing... (This may take a few seconds)"
                            showAlert = true
                            
                            Task.detached {
                                let legacyTokens = await MainActor.run { tokenizerManager.tokenize(text: text, isFinal: true) }
                                
                                // Since MLVoiceTokenizer uses MLModel synchronously, doing it in detached task keeps MainThread free
                                // However, TokenizerManager is a class. We'll just instantiate the tokenizer or use it if it's thread-safe.
                                // Actually tokenizerManager.tokenize is synchronous but doesn't mutate state except useMLTokenizer, which is @Published.
                                // It's safer to just let the tokenizer do its job in the background if possible.
                                var state = await MainActor.run { MLTokenizerState() }
                                let mlTokens = await tokenizerManager.mlTokenizer?.tokenize(text: text, isFinal: true, sessionState: &state) ?? []
                                
                                await MainActor.run {
                                    if legacyTokens == mlTokens {
                                        alertMessage = "✅ Tokens match perfectly! Both systems produced \(mlTokens.count) tokens."
                                    } else {
                                        alertMessage = "❌ Tokens differ!\nLegacy: \(legacyTokens.count) tokens\nML: \(mlTokens.count) tokens"
                                    }
                                }
                            }
                        }
                    }
                }
                
                Section("AI Simulation") {
                    VStack(alignment: .leading) {
                        Text("WPM: \(Int(aiViewModel.wpm))")
                        Slider(value: $aiViewModel.wpm, in: 20...300, step: 10)
                    }
                }
                
                Section("Instant Fill (Testing)") {
                    Picker("Test Transcript", selection: $aiViewModel.selectedTestTranscriptName) {
                        ForEach(TestTranscripts.all, id: \.0) { transcript in
                            Text(transcript.0).tag(transcript.0)
                        }
                    }
                    
                    Button("Fill Chart") {
                        if let text = TestTranscripts.all.first(where: { $0.0 == aiViewModel.selectedTestTranscriptName })?.1 {
                            aiViewModel.parseInstant(text: text)
                        }
                        dismiss()
                    }
                    
                    Button("Test Debug Transcript") {
                        aiViewModel.parseInstant(text: AIVoiceViewModel.debugTranscript)
                        dismiss()
                    }
                    
                    Button("Clear Chart", role: .destructive) {
                        aiViewModel.parseInstant(text: "")
                        selectionModel.selectedCells.removeAll()
                        dismiss()
                    }
                }
                
                Section("Regression Testing") {
                    Button("Save as Ground Truth") {
                        let targetName = aiViewModel.selectedTestTranscriptName
                        var foundTranscript: (String, String)? = nil
                        for tup in TestTranscripts.all {
                            if tup.0 == targetName {
                                foundTranscript = tup
                                break
                            }
                        }
                        if let transcript = foundTranscript {
                            let text = transcript.1
                            let name = transcript.0
                            Task { @MainActor in
                                let config = (try? JSONDecoder().decode(ChartingConfiguration.self, from: UserDefaults.standard.data(forKey: "ChartingConfiguration") ?? Data())) ?? ChartingConfiguration()
                                let mouth = ChartTestingUtilities.parseTranscript(text: text, config: config)
                                let success = ChartTestingUtilities.saveChart(mouth: mouth, transcriptName: name)
                                alertMessage = success ? "Successfully saved ground truth to project folder." : "Failed to save ground truth."
                                showAlert = true
                            }
                        }
                    }
                    
                    Button("Test vs Ground Truth") {
                        let targetName = aiViewModel.selectedTestTranscriptName
                        var foundTranscript: (String, String)? = nil
                        for tup in TestTranscripts.all {
                            if tup.0 == targetName {
                                foundTranscript = tup
                                break
                            }
                        }
                        if let transcript = foundTranscript {
                            let text = transcript.1
                            let name = transcript.0
                            
                            Task { @MainActor in
                                let expected = ChartTestingUtilities.loadChart(transcriptName: name)
                                if let expected = expected {
                                    let config = (try? JSONDecoder().decode(ChartingConfiguration.self, from: UserDefaults.standard.data(forKey: "ChartingConfiguration") ?? Data())) ?? ChartingConfiguration()
                                    let actual = ChartTestingUtilities.parseTranscript(text: text, config: config)
                                    let diffs = ChartTestingUtilities.compareCharts(expected: expected, actual: actual)
                                    
                                    if diffs.isEmpty {
                                        alertMessage = "✅ Regression Test PASSED: No differences found."
                                    } else {
                                        alertMessage = "❌ Regression Test FAILED: \(diffs.count) differences found.\nCheck Xcode console for details."
                                    }
                                    showAlert = true
                                } else {
                                    alertMessage = "❌ No ground truth file found to compare against."
                                    showAlert = true
                                }
                            }
                        }
                    }
                }
                
                Section("Single Cell Highlights") {
                    Button("Tooth 16 Probing Depth (Outer)") {
                        var newSelection = Set<ChartCellCoordinate>()
                        newSelection.insert(ChartCellCoordinate(toothNumber: 16, operation: .probingDepth, aspect: .outer, siteIndex: 0))
                        newSelection.insert(ChartCellCoordinate(toothNumber: 16, operation: .probingDepth, aspect: .outer, siteIndex: 1))
                        newSelection.insert(ChartCellCoordinate(toothNumber: 16, operation: .probingDepth, aspect: .outer, siteIndex: 2))
                        selectionModel.selectedCells = newSelection
                        dismiss()
                    }
                    Button("Tooth 21 Bleeding (Inner, Mid)") {
                        selectionModel.selectedCells = [ChartCellCoordinate(toothNumber: 21, operation: .bleeding, aspect: .inner, siteIndex: 1)]
                        dismiss()
                    }
                }

                Section("Row / Region Highlights") {
                    Button("Q1 Gingival Margin (Outer)") {
                        var newSelection = Set<ChartCellCoordinate>()
                        let q1Teeth = [18, 17, 16, 15, 14, 13, 12, 11]
                        for tooth in q1Teeth {
                            for site in 0..<3 {
                                newSelection.insert(ChartCellCoordinate(toothNumber: tooth, operation: .gingivalMargin, aspect: .outer, siteIndex: site))
                            }
                        }
                        selectionModel.selectedCells = newSelection
                        dismiss()
                    }
                    Button("All Implants (Shared Grid)") {
                        var newSelection = Set<ChartCellCoordinate>()
                        let allTeeth = [
                            18,17,16,15,14,13,12,11,
                            21,22,23,24,25,26,27,28,
                            48,47,46,45,44,43,42,41,
                            31,32,33,34,35,36,37,38
                        ]
                        for tooth in allTeeth {
                            newSelection.insert(ChartCellCoordinate(toothNumber: tooth, operation: .implant, aspect: nil, siteIndex: nil))
                        }
                        selectionModel.selectedCells = newSelection
                        dismiss()
                    }
                }

                Section("Clear") {
                    Button("Clear All Selections", role: .destructive) {
                        selectionModel.selectedCells.removeAll()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Debug Selection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Regression Test", isPresented: $showAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
        }
    }
}
