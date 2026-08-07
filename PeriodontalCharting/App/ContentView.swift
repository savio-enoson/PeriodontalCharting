import SwiftUI
import SwiftData

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PatientChart.updatedAt, order: .reverse) private var charts: [PatientChart]
    @State private var selectedChart: PatientChart?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        content
            // Blocking splash while the shared WhisperKit model loads/downloads.
            // Only after onboarding, so first-time users complete setup while the
            // model warms in the background. Auto-dismisses when the model is ready.
            // Reading `isReady` here (an @Observable) drives the transition.
            .overlay {
                if hasCompletedOnboarding && !TranscriptionEngine.shared.isReady {
                    ModelLoadingSplash()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.35),
                       value: TranscriptionEngine.shared.isReady)
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
