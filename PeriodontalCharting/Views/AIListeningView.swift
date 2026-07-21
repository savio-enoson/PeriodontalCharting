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
                        if viewModel.isListening {
                            viewModel.stopSimulation()
                        } else {
                            viewModel.simulateTranscription(from: AIVoiceViewModel.debugTranscript, wpm: 100)
                        }
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
                            .font(.system(.body, design: .monospaced))
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
                        CommandRow(label: "Operation", value: "Update Mobility")
                        Divider()
                        CommandRow(label: "Selection", value: "Tooth 18, 17, 16")
                        Divider()
                        CommandRow(label: "Values", value: "2")
                    }
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                }
                
                // Section 3: History
                VStack(alignment: .leading, spacing: 8) {
                    Text("HISTORY")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    
                    VStack(spacing: 8) {
                        HistoryCard(operation: "Probing Depth", selection: "Tooth 41-43")
                        HistoryCard(operation: "Bleeding on Probing", selection: "Tooth 38 (Distal)")
                        HistoryCard(operation: "Furcation", selection: "Tooth 26")
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
                .bold()
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
