import SwiftUI

struct SelectionDebugMenu: View {
    @EnvironmentObject var selectionModel: ChartSelectionModel
    @EnvironmentObject var aiViewModel: AIVoiceViewModel
    @Environment(\.dismiss) var dismiss
    
    @State private var showAlert = false
    @State private var alertMessage = ""
    
    var body: some View {
        NavigationStack {
            List {
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
                    
                    Button("Clear Chart", role: .destructive) {
                        aiViewModel.parseInstant(text: "")
                        selectionModel.selectedCells.removeAll()
                        dismiss()
                    }
                }
                
                Section("Regression Testing") {
                    Button("Save as Ground Truth") {
                        if let text = TestTranscripts.all.first(where: { $0.0 == aiViewModel.selectedTestTranscriptName })?.1 {
                            // Fetch active config or default
                            let config = (try? JSONDecoder().decode(ChartingConfiguration.self, from: UserDefaults.standard.data(forKey: "ChartingConfiguration") ?? Data())) ?? ChartingConfiguration()
                            let mouth = ChartTestingUtilities.parseTranscript(text: text, config: config)
                            let success = ChartTestingUtilities.saveChart(mouth: mouth)
                            alertMessage = success ? "Successfully saved ground truth to project folder." : "Failed to save ground truth."
                            showAlert = true
                        }
                    }
                    
                    Button("Test vs Ground Truth") {
                        if let text = TestTranscripts.all.first(where: { $0.0 == aiViewModel.selectedTestTranscriptName })?.1 {
                            let expected = ChartTestingUtilities.loadChart()
                            if let expected = expected {
                                let config = (try? JSONDecoder().decode(ChartingConfiguration.self, from: UserDefaults.standard.data(forKey: "ChartingConfiguration") ?? Data())) ?? ChartingConfiguration()
                                let actual = ChartTestingUtilities.parseTranscript(text: text, config: config)
                                let diffs = ChartTestingUtilities.compareCharts(expected: expected, actual: actual)
                                if diffs.isEmpty {
                                    alertMessage = "✅ Regression Test PASSED: No differences found."
                                } else {
                                    alertMessage = "❌ Regression Test FAILED:\n" + diffs.joined(separator: "\n")
                                }
                            } else {
                                alertMessage = "⚠️ No ground truth found. Please save it first."
                            }
                            showAlert = true
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
