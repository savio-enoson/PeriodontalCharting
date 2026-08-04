//
//  LiveTranscriptionView.swift
//  PeriodontalCharting
//
//  Live-mic-only slice of TestView, for embedding in the chart toolbar.
//

import SwiftUI

struct LiveTranscriptionView: View {
    @State private var viewModel = TranscriptionViewModel()

    var body: some View {
        VStack(spacing: 20) {
            Text("Live Transcription")
                .font(.largeTitle)
                .padding(.top)

            statusView

            gateView

            transcriptView

            controls
        }
        .padding(.bottom)
        .task {
            await viewModel.loadModel()
        }
    }

    // MARK: - Subviews

    private var statusView: some View {
        HStack(spacing: 8) {
            if viewModel.isRecording {
                Circle().fill(.red).frame(width: 10, height: 10)
                    .opacity(0.9)
                    .symbolEffectPulse()
            } else if viewModel.isTranscribing {
                ProgressView().controlSize(.small)
            }
            Text(viewModel.statusMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    /// Speaker filter state. Orange "off" is the case that used to be invisible:
    /// no enrollment means every voice in the room reaches the chart.
    @ViewBuilder
    private var gateView: some View {
        if viewModel.isRecording {
            let status = viewModel.gateStatus
            HStack(spacing: 6) {
                Image(systemName: status.active ? "person.wave.2.fill" : "person.slash")
                Text(status.summary)
                if let d = status.lastDistance {
                    Text(String(format: "· d %.2f", d)).monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(status.active ? Color.secondary : Color.orange)
        }
    }

    private var transcriptView: some View {
        ScrollView {
            Text(viewModel.transcript.isEmpty ? "Transcription will appear here" : viewModel.transcript)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(viewModel.transcript.isEmpty ? .secondary : .primary)
                .animation(.default, value: viewModel.transcript)
        }
        .frame(maxHeight: 300)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.4)))
        .padding(.horizontal)
    }

    private var controls: some View {
        Button(action: viewModel.toggleRecording) {
            Text(viewModel.isRecording ? "Stop" : "Start Recording")
                .padding()
                .frame(maxWidth: .infinity)
                .background(viewModel.isRecording ? Color.red : Color.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(!viewModel.isModelReady)
        .padding(.horizontal)
    }
}

// Gentle pulse for the live "recording" dot.
private extension View {
    @ViewBuilder
    func symbolEffectPulse() -> some View {
        self.modifier(PulseModifier())
    }
}

private struct PulseModifier: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? 1.2 : 0.85)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

#Preview {
    LiveTranscriptionView()
}
