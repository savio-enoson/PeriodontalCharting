import SwiftUI

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @State private var records: [String] = ["2026-07-20 - Initial Exam"]
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// @Observable singletons — read in `body` so the splash transitions itself.
    private let assets = ChartAssetStore.shared
    private let engine = TranscriptionEngine.shared

    /// Chart images gate ONBOARDING as well as the chart: they are rendered in
    /// the same `body` as the onboarding name field. A second or two behind a
    /// determinate bar buys a responsive setup screen.
    ///
    /// The model gates only the CHART — and now only STARTS once setup is done.
    private var needsSplash: Bool {
        !assets.isReady || (hasCompletedOnboarding && !engine.isReady)
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
            // WhisperKit, deferred until setup is finished.
            //
            // It used to start at launch, which meant a ~180 s Core ML compile
            // ran underneath onboarding — the first keyboard presentation, the
            // audio-session activation and the image decode all queued behind it.
            // Nothing in onboarding needs the model; the gate uses its own small
            // packages. `task(id:)` fires again when the flag flips, so the load
            // begins the moment "Complete Setup" is tapped and the splash covers
            // it exactly as it does on every later launch.
            .task(id: hasCompletedOnboarding) {
                guard hasCompletedOnboarding else { return }
                await engine.load()
            }
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
