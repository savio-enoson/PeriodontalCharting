import SwiftUI

struct SelectionDebugMenu: View {
    @Binding var mouth: [Int: ToothObject]
    @EnvironmentObject var selectionModel: ChartSelectionModel
    @EnvironmentObject var aiViewModel: AIVoiceViewModel
    @Environment(\.dismiss) var dismiss
    
    @State private var showAlert = false
    @State private var alertMessage = ""

    @AppStorage("useOfflineWav2Vec") var useOfflineWav2Vec: Bool = true
    @AppStorage("useStatefulParser") var useStatefulParser: Bool = true
    
    @State private var selectedAudioFile: String = "dr_lucky_audio"
    @State private var speedMultiplier: Double = 2.0
    @State private var tseEnabled: Bool = TSEConfig.mode != .off
    
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
                    
                    Button("Fill Random Data") {
                        mouth = ToothObject.fullMouthMock()
                        dismiss()
                    }
                }

                Section("Speaker Gate (TSE)") {
                    Toggle("Enable TSE (Extraction & Gate)", isOn: Binding(
                        get: { TSEConfig.mode != .off },
                        set: { isOn in
                            TSEConfig.mode = isOn ? .enforce : .off
                            tseEnabled = isOn // Force UI update
                        }
                    ))
                    
                    NavigationLink("Open gate test harness") {
                        SpeakerGateDebugView()
                    }
                }
                


                Section("Audio File Streaming") {
                    Picker("Audio File", selection: $selectedAudioFile) {
                        Text("Dr. Lucky").tag("dr_lucky_audio")
                        Text("Student").tag("student_audio")
                        Text("Dr. Gaby").tag("dr_gaby_audio")
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Speed: \(String(format: "%.1fx", speedMultiplier))")
                        Slider(value: $speedMultiplier, in: 0.5...5.0, step: 0.5)
                    }
                    
                    Button("Start File Simulation") {
                        if let url = Bundle.main.url(forResource: selectedAudioFile, withExtension: "m4a") {
                            aiViewModel.audioFileSimulation(fileURL: url, speedMultiplier: speedMultiplier)
                            dismiss()
                        } else {
                            alertMessage = "Audio file \\(selectedAudioFile).m4a not found in bundle."
                            showAlert = true
                        }
                    }
                }
                
                Section("AI Simulation") {
                    VStack(alignment: .leading) {
                        Text("WPM: \(Int(aiViewModel.wpm))")
                        Slider(value: $aiViewModel.wpm, in: 20...300, step: 10)
                    }
                    Button(aiViewModel.isListening ? "Stop Simulation" : "Start Simulation (Streaming)") {
                        if aiViewModel.isListening {
                            aiViewModel.stopSimulation()
                        } else {
                            if let text = TestTranscripts.all.first(where: { $0.0 == aiViewModel.selectedTestTranscriptName })?.1 {
                                aiViewModel.toggleSimulation(from: text)
                                dismiss()
                            }
                        }
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
