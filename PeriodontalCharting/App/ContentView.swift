import SwiftUI

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @State private var records: [String] = ["2026-07-20 - Initial Exam"]
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
                List {
                    if records.isEmpty {
                        ContentUnavailableView {
                            Label("No Records in Database", systemImage: "tray")
                                .foregroundStyle(.white)
                        }
                    } else {
                        ForEach(records, id: \.self) { record in
                            NavigationLink(value: record) {
                                VStack(alignment: .leading) {
                                    Text("Patient Chart")
                                        .font(.headline)
                                        .foregroundStyle(.black)
                                    Text(record)
                                        .font(.subheadline)
                                        .foregroundStyle(.black.opacity(0.8))
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                        }
                    }
                }
                .navigationTitle("Periodontal Charting")
                .toolbarBackground(darkBlue, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .scrollContentBackground(.hidden)
                .background(darkBlue)
            } detail: {
                ChartDashboard(columnVisibility: $columnVisibility)
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
    }
}

#Preview {
    ContentView()
}
