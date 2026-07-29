//
//  TestView.swift
//  PeriodontalCharting
//
//  Created by Hendrik Nicolas Carlo on 24/07/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct TestView: View {
    @State private var viewModel = TranscriptionViewModel()
    @State private var showFileImporter = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Periodontal Transcription")
                .font(.largeTitle)
                .padding(.top)

            Picker("Input Mode", selection: $viewModel.inputMode) {
                ForEach(TranscriptionViewModel.InputMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .disabled(viewModel.isTranscribing)

            statusView

            if viewModel.benchmarkTime > 0 {
                benchmarkView
            }

            transcriptView

            controls
        }
        .padding(.bottom)
        .task {
            await viewModel.loadModel()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result {
                viewModel.selectedFileURL = url
            }
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

    private var benchmarkView: some View {
        VStack(spacing: 5) {
            Text("Transcription Time:  \(viewModel.benchmarkTime, format: .number.precision(.fractionLength(2)))s")
                .foregroundStyle(.green).bold()
            Text("RTFx: \(viewModel.rtfValue, format: .number.precision(.fractionLength(2)))x")
                .foregroundStyle(.blue).font(.headline)
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

    @ViewBuilder
    private var controls: some View {
//        if viewModel.inputMode == .upload {
//            Button("Select Audio File") { showFileImporter = true }
//                .padding(.top, 4)
//            if let url = viewModel.selectedFileURL {
//                Text("Selected: \(url.lastPathComponent)").font(.caption)
//            }
//        }

        if viewModel.inputMode == .live {
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
        } else {
            Button(action: viewModel.transcribeSelection) {
                Text(viewModel.isTranscribing ? "Transcribing…" : "Transcribe")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(viewModel.canTranscribe ? Color.blue : Color.gray)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(!viewModel.canTranscribe)
            .padding(.horizontal)
        }
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
    ContentView()
}
