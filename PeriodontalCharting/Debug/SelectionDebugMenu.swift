import SwiftUI

struct SelectionDebugMenu: View {
    @Binding var mouth: [Int: ToothObject]
    @EnvironmentObject var selectionModel: ChartSelectionModel
    @EnvironmentObject var aiViewModel: AIVoiceViewModel
    @Environment(\.dismiss) var dismiss
    
    @State private var showAlert = false
    @State private var alertMessage = ""
    @AppStorage("useMLTokenizer") var useMLTokenizer: Bool = true

    // Refreshed on appear rather than read in `body`, which would enumerate the
    // directory on every render pass.
    @State private var metricFiles: [URL] = []
    
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

                Section("Speaker Gate (TSE)") {
                    NavigationLink("Open gate test harness") {
                        SpeakerGateDebugView()
                    }
                }

                // T1 — the overlap-metric collection layer. Nothing here changes a
                // verdict; it measures and records, and the switches exist so a
                // latency problem can be bisected WITHOUT a rebuild. That matters
                // more than it looks: a rebuild costs a ~190 s ANE recompile of the
                // Whisper encoder before a session can start, so a four-way bisect
                // by editing constants is most of an hour.
                Section("TSE Metrics (T1)") {
                    Toggle("Measure spans", isOn: Binding(
                        get: { TSEMetricsConfig.enabled },
                        set: { TSEMetricsConfig.enabled = $0 }
                    ))

                    // FAMILY E — the only part that calls Core ML. 2–3 ECAPA calls
                    // per span on the ANE that WhisperKit's encoder already occupies
                    // for ~442 ms a window, and it runs inside `judgePending` before
                    // cleaned audio is handed to Whisper. FIRST SWITCH TO TRY when
                    // the live path stalls.
                    Toggle("Family E (sub-window probe)", isOn: Binding(
                        get: { TSEMetricsConfig.probeSubwindows },
                        set: { TSEMetricsConfig.probeSubwindows = $0 }
                    ))

                    // Writes are buffered and drained on a background queue, so this
                    // should no longer cost the audio pump anything. It is still a
                    // switch because the first version fsynced per span on that pump,
                    // and being able to rule it out by hand is worth one row.
                    Toggle("Write CSV", isOn: Binding(
                        get: { TSEMetricsConfig.writeCSV },
                        set: { TSEMetricsConfig.writeCSV = $0 }
                    ))

                    Toggle("Console line per span", isOn: Binding(
                        get: { TSEMetricsConfig.logToConsole },
                        set: { TSEMetricsConfig.logToConsole = $0 }
                    ))

                    // PROOF, NOT PLAUSIBILITY. Every metric returns a well-formed
                    // number whether or not the code behind it is right; kurtosis and
                    // crest factor are the only ones with exact analytic references
                    // (-1.5 and sqrt(2) for a sine, 0 for Gaussian noise), and they
                    // exercise the frame extraction every other metric sits on.
                    // RUN THIS AFTER ANY CHANGE TO `analyze`.
                    NavigationLink("Run metric self-test") {
                        TSEMetricsReportView(title: "Self-test",
                                             generate: { TSEMetricsSelfTest.run() })
                    }

                    // Percentiles per column, split by schema and then by the gate's
                    // own verdict. Reading `accept` against `confirm`/`reject`
                    // separately is the point: the second group is mostly quiet-you,
                    // which is the population the current trigger misclassifies.
                    NavigationLink("Null distribution summary") {
                        TSEMetricsReportView(title: "Summary",
                                             generate: { TSEMetricsLog.summarise() })
                    }

                    if metricFiles.isEmpty {
                        Text("No metric CSVs collected yet")
                            .foregroundStyle(.secondary)
                    } else {
                        // Filter on the `schema` column before pooling anything, and
                        // remember which sessions had a second speaker in the room —
                        // those must never enter the null distribution.
                        ShareLink(item: metricFiles.last!) {
                            Text("Export latest CSV (\(metricFiles.count) file(s))")
                        }
                    }
                }
                
                Section("NLP Phase 1 Tokenizer") {
                    Toggle("Use ML Tokenizer (IndoBERT)", isOn: $useMLTokenizer)
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
            .onAppear { metricFiles = TSEMetricsLog.files }
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

// Scrollable, SELECTABLE, monospaced report.
//
// Selectable is the point: both reports exist to be copied out and read
// elsewhere, and the console is not reachable from a home-screen launch — which
// is exactly the configuration the per-launch ANE recompile needs to be tested
// in. Monospaced because both reports are column-aligned and unreadable
// proportionally.
//
// Horizontal scrolling as well as vertical: `summarise()` emits lines around 90
// characters, and wrapping them destroys the column alignment that makes the
// percentile table readable at a glance.
struct TSEMetricsReportView: View {
    let title: String
    // @Sendable so the work can leave the main actor. Both callers pass a static
    // function with no captured state: `TSEMetricsSelfTest.run` touches only the
    // lock-guarded shared analyzer, `TSEMetricsLog.summarise` only reads files.
    let generate: @Sendable () -> String

    @State private var report = "Running…"

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(report)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // OFF THE MAIN ACTOR. The self-test synthesises several 3-second signals
            // and runs the full analyzer over each — a few hundred milliseconds of
            // Accelerate — and `summarise` reads and parses every collected CSV.
            // Either would visibly hitch the push animation on the main actor.
            let work = generate
            report = await Task.detached(priority: .userInitiated) { work() }.value
        }
    }
}
