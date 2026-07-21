import SwiftUI

struct SelectionDebugMenu: View {
    @EnvironmentObject var selectionModel: ChartSelectionModel
    @EnvironmentObject var aiViewModel: AIVoiceViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("AI Simulation") {
                    VStack(alignment: .leading) {
                        Text("WPM: \(Int(aiViewModel.wpm))")
                        Slider(value: $aiViewModel.wpm, in: 20...300, step: 10)
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
        }
    }
}
