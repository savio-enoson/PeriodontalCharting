import SwiftUI
import SwiftData

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PatientChart.updatedAt, order: .reverse) private var charts: [PatientChart]
    @State private var selectedChart: PatientChart?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// @Observable singleton — read in `body` so the splash transitions itself.
    private let assets = ChartAssetStore.shared
    /// The Wav2Vec2 STT model. Loaded during the splash so live/AI-Mode dictation
    /// is ready the moment the chart appears. ObservableObject, so observe it.
    @StateObject private var wav2vec = Wav2VecEngine.shared

    /// Chart images gate ONBOARDING as well as the chart: they are rendered in
    /// the same `body` as the onboarding name field. A second or two behind a
    /// determinate bar buys a responsive setup screen.
    ///
    /// The STT model gates only the CHART — and now only STARTS once setup is done.
    private var needsSplash: Bool {
        !assets.isReady || (hasCompletedOnboarding && !wav2vec.isModelLoaded)
    }

    var body: some View {
        content
            .overlay {
                if needsSplash {
                    ModelLoadingSplash()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: needsSplash)
            // Decode the chart diagrams once, downscaled, and hold them.
            .task { await assets.warm() }
            // The two heavy subsystems, deferred until setup is finished. Nothing
            // in onboarding needs either — the gate uses its own small packages.
            // `task(id:)` fires again when the flag flips, so loading begins the
            // moment "Complete Setup" is tapped, behind the same splash that
            // covers every later launch.
            //
            // STT FIRST, EXTRACTOR SECOND. The mic button unlocks on
            // `isModelLoaded`, so making the clinician wait for six extra Core ML
            // packages before they can dictate would be the wrong trade — the
            // extractor catching up late costs at most the first chunk, which
            // falls back to the gate's own verdict.
            .task(id: hasCompletedOnboarding) {
                guard hasCompletedOnboarding else { return }
                await Wav2VecEngine.shared.loadModel()
                await TSEEngine.shared.prepare()
            }
    }

    @ViewBuilder
    private var content: some View {
        if !hasCompletedOnboarding {
            OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
        } else {
            let darkBlue = Color(red: 0.05, green: 0.2, blue: 0.5)

            NavigationSplitView(columnVisibility: $columnVisibility) {
                List(selection: $selectedChart) {
                    if charts.isEmpty {
                        ContentUnavailableView {
                            Label("No Records in Database", systemImage: "tray")
                                .foregroundStyle(.white)
                        }
                    } else {
                        ForEach(charts) { chart in
                            NavigationLink(value: chart) {
                                VStack(alignment: .leading) {
                                    Text(chart.patientName)
                                        .font(.headline)
                                        .foregroundStyle(.black)
                                    Text(chart.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.subheadline)
                                        .foregroundStyle(.black.opacity(0.8))
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                            .listRowSeparator(.hidden)
                        }
                        .onDelete(perform: deleteCharts)
                    }
                }
                .listRowSpacing(12)
                .navigationTitle("Periodontal Charting")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            addChart()
                        } label: {
                            Label("New Chart", systemImage: "plus")
                        }
                    }
                }
                .toolbarBackground(darkBlue, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .scrollContentBackground(.hidden)
                .background(darkBlue)
            } detail: {
                ChartDashboard(chart: selectedChart, columnVisibility: $columnVisibility)
                    // Rebuild the dashboard's local state when the selected chart
                    // changes, so switching records reloads the right mouth.
                    .id(selectedChart?.persistentModelID)
                    .toolbar(.hidden, for: .navigationBar)
            }
            .onAppear {
                if selectedChart == nil { selectedChart = charts.first }
            }
        }
    }

    private func addChart() {
        let count = charts.count + 1
        let chart = PatientChart(patientName: "Patient Chart \(count)")
        modelContext.insert(chart)
        selectedChart = chart
    }

    private func deleteCharts(at offsets: IndexSet) {
        for index in offsets {
            let chart = charts[index]
            if chart == selectedChart { selectedChart = nil }
            modelContext.delete(chart)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: PatientChart.self, inMemory: true)
}
