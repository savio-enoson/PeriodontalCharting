//
//  ModelLoadingSplash.swift
//  PeriodontalCharting
//
//  Full-screen splash shown while the shared WhisperKit model loads — or, on a
//  first launch without the bundled model, downloads from the Hugging Face Hub.
//  Observes TranscriptionEngine.shared (an @Observable singleton) and reflects its
//  `statusMessage`; the caller (ContentView) removes it when `isReady` flips true.
//  On a load failure it surfaces the error and offers a Retry.
//

import SwiftUI

struct ModelLoadingSplash: View {
    /// @Observable singleton — reading its properties in `body` registers the
    /// view for updates, so the status line and failure state stay live.
    private let engine = TranscriptionEngine.shared
    private let darkBlue = Color(red: 0.05, green: 0.2, blue: 0.5)

    /// TranscriptionEngine sets this exact prefix on the failure path.
    private var didFail: Bool { engine.statusMessage.hasPrefix("Failed to load") }

    var body: some View {
        ZStack {
            darkBlue.ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.white)

                if didFail {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title)
                        .foregroundStyle(.yellow)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }

                VStack(spacing: 8) {
                    Text(didFail ? "Couldn’t load dictation model" : "Preparing dictation model")
                        .font(.headline)
                        .foregroundStyle(.white)

                    // Reflects the engine's live status: "Loading bundled model…",
                    // "Downloading model…\n(large one-time download…)", or the error.
                    Text(engine.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 40)

                if didFail {
                    Button {
                        Task { await engine.load() }
                    } label: {
                        Text("Retry")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 10)
                            .background(.white, in: Capsule())
                            .foregroundStyle(darkBlue)
                    }
                }
            }
        }
    }
}

#Preview {
    ModelLoadingSplash()
}
