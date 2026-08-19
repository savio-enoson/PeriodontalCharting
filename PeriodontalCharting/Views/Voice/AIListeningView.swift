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

                    // Real live dictation: mic -> speaker gate -> Wav2Vec2 ->
                    // annotation parser, per committed chunk. A spinner shows
                    // until the STT model is ready, then the mic becomes tappable.
                    let modelReady = Wav2VecEngine.shared.isModelLoaded
                    if viewModel.isDictating {
                        HStack(spacing: 12) {
                            Button(action: { viewModel.togglePauseLiveDictation() }) {
                                Image(systemName: viewModel.isPaused ? "mic.fill" : "pause.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(viewModel.isPaused ? Color.blue : Color.orange, in: Circle())
                            }

                            Button(action: { viewModel.toggleLiveDictation() }) {
                                Image(systemName: "square.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.red, in: Circle())
                            }
                        }
                    } else {
                        Button(action: { viewModel.toggleLiveDictation() }) {
                            if viewModel.isFinishing {
                                Image(systemName: "waveform")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.orange, in: Circle())
                                    .symbolEffect(.variableColor.iterative, isActive: true)
                            } else if modelReady {
                                Image(systemName: "mic.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.blue, in: Circle())
                            } else {
                                ProgressView().controlSize(.small)
                                    .frame(width: 44, height: 44)
                                    .background(Color.gray.opacity(0.3), in: Circle())
                            }
                        }
                        .disabled(viewModel.isFinishing || !modelReady)
                    }

                    // DEBUG: Start Simulation
//                    Button(action: {
//                        viewModel.toggleSimulation(from: viewModel.selectedTestTranscript)
//                    }) {
//                        Image(systemName: viewModel.isListening ? "stop.circle.fill" : "play.circle.fill")
//                            .font(.title2)
//                            .foregroundStyle(viewModel.isListening ? .red : .blue)
//                    }
                    // The two feeds are mutually exclusive, and starting a
                    // simulation mid-finish would race the final commit for the
                    // chart. AIVoiceViewModel guards against it, but greying the
                    // control is clearer than silently discarding one of them.
                    .disabled(viewModel.isFinishing)
                }
                .padding(.bottom, 8)
                
                // Speaker filter — visible whenever real dictation is running, and
                // through the finish, so a withheld line is never mistaken for the
                // decoder missing words. The tail chunk can still change these
                // counts after the mic goes off.
                if viewModel.isDictating || viewModel.isFinishing {
                    let status = viewModel.gateStatus
                    HStack(spacing: 6) {
                        Image(systemName: status.active ? "person.wave.2.fill" : "person.slash")
                            .foregroundStyle(status.active ? Color.blue : Color.orange)
                        Text(status.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let d = status.lastDistance {
                            Text(String(format: "d %.2f", d))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.bottom, 4)
                }
                
                // Section 1: Live Transcription
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("LIVE TRANSCRIPTION")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(viewModel.currentStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    ScrollViewReader { proxy in
                        ScrollView {
                            if viewModel.committedTranscription.isEmpty && viewModel.uncommittedTranscription.isEmpty {
                                Text("Waiting for dictation...")
                                    .font(.system(.footnote, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundStyle(.tertiary)
                                    .id("transcriptText")
                            } else {
                                (Text(viewModel.committedTranscription)
                                    .foregroundStyle(.primary) +
                                 Text(viewModel.uncommittedTranscription)
                                    .foregroundStyle(.gray))
                                    .font(.system(.footnote, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id("transcriptText")
                            }
                        }
                        .onChange(of: viewModel.committedTranscription) { _, _ in
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("transcriptText", anchor: .bottom)
                            }
                        }
                        .onChange(of: viewModel.uncommittedTranscription) { _, _ in
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("transcriptText", anchor: .bottom)
                            }
                        }
                        .padding()
                        .frame(height: 120) // Fixed height for ~5 lines
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    }
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
                                    selection: "\(String(localized: "Tooth")) \(cmd.teethSelection.startTooth.toothNumber) (\(cmd.values.map { String($0) }.joined(separator: ", ")))"
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
    let label: LocalizedStringKey
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
    var wasPadded: Bool = false
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(operation)
                    .font(.headline)
                Text(selection)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if wasPadded {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    AIListeningView(viewModel: AIVoiceViewModel())
}
