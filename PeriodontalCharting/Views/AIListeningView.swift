import SwiftUI

struct AIListeningView: View {
    @ObservedObject var viewModel: AIVoiceViewModel
    @State private var isPulsing = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack {
                    Image(systemName: "apple.intelligence")
                        .font(.title)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.orange, Color(red: 0.9, green: 0.3, blue: 0.0)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .symbolEffect(.pulse)
                    
                    Spacer()
                    
                    // DEBUG: Start Simulation
                    Button(action: {
                        viewModel.toggleSimulation(from: AIVoiceViewModel.debugTranscript)
                    }) {
                        Image(systemName: viewModel.isListening ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(viewModel.isListening ? .red : .blue)
                    }
                }
                .padding(.bottom, 8)
                
                // Section 1: Live Transcription
                VStack(alignment: .leading, spacing: 8) {
                    Text("LIVE TRANSCRIPTION")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    
                    ScrollView {
                        Text(viewModel.liveTranscription.isEmpty ? "Waiting for dictation..." : viewModel.liveTranscription)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(viewModel.liveTranscription.isEmpty ? .tertiary : .primary)
                    }
                    .padding()
                    .frame(minHeight: 120) // Roughly 5 lines of monospace text
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                }
                
                // Section 2: Current Command
                VStack(alignment: .leading, spacing: 8) {
                    Text("CURRENT COMMAND")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    
                    VStack(spacing: 0) {
                        CommandRow(
                            label: "Operation",
                            value: viewModel.currentCursor.map { $0.currentMetric.displayName } ?? "-"
                        )
                        Divider()
                        CommandRow(
                            label: "Selection",
                            value: viewModel.currentCursor.map { "\($0.currentTooth)" } ?? "-"
                        )
                        Divider()
                        VStack(alignment: .trailing, spacing: 12) {
                            HStack {
                                Text(viewModel.pendingValues.isEmpty ? "Last Applied" : "Pending Values")
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            
                            let valuesToDisplay = !viewModel.pendingValues.isEmpty ? viewModel.pendingValues : (viewModel.currentCommand?.values ?? [])
                            if !valuesToDisplay.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        Spacer(minLength: 0)
                                        ForEach(Array(valuesToDisplay.enumerated()), id: \.offset) { _, val in
                                            Text(val)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .overlay(Capsule().stroke(Color.black, lineWidth: 1))
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                                }
                            } else {
                                Text("-")
                            }
                        }
                        .padding()
                    }
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                }
                
                // Section 3: History
                VStack(alignment: .leading, spacing: 8) {
                    Text("HISTORY")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    
                    VStack(spacing: 8) {
                        if viewModel.commandHistory.isEmpty {
                            Text("No history yet")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        } else {
                            ForEach(Array(viewModel.commandHistory.suffix(5).reversed().enumerated()), id: \.offset) { _, cmd in
                                HistoryCard(
                                    operation: cmd.operation.displayName,
                                    selection: "Tooth \(cmd.teethSelection.startTooth.toothNumber) (\(cmd.values.map { String($0) }.joined(separator: ", ")))"
                                )
                            }
                        }
                    }
                }
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.black)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .light) // Ensures the material and colors feel 'white' oriented
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(
                    LinearGradient(
                        colors: [.orange, Color(red: 0.9, green: 0.3, blue: 0.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 3
                )
                .opacity(isPulsing ? 1.0 : 0.2)
        )
        .shadow(color: .black.opacity(0.15), radius: 20, x: -10, y: 10)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

struct CommandRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
        }
        .padding()
    }
}

struct HistoryCard: View {
    let operation: String
    let selection: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(operation)
                .font(.headline)
            Text(selection)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    AIListeningView(viewModel: AIVoiceViewModel())
}
