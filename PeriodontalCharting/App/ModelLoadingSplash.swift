//
//  ModelLoadingSplash.swift
//  PeriodontalCharting
//
//  Full-screen splash for the two things that must be ready before the UI they
//  serve is usable:
//
//    1. CHART IMAGES  — four ~6800 px diagrams, decoded once and downscaled in
//       memory. Fast (a second or two) and reports REAL progress. Gates
//       onboarding, because they are rendered in the same `body` as its text
//       field and decoding them on first render is what made typing lag.
//    2. DICTATION MODEL — WhisperKit, or a ~632 MB download on a first launch
//       without the bundled model. Gates the chart, not onboarding: the
//       clinician completes setup while it warms.
//
//  Images come first, so on a first run the sequence is
//      "Preparing chart images" -> onboarding -> "Preparing dictation model" -> chart.
//
//  Model states, in priority order: failed -> downloading (determinate, real
//  byte progress) -> preparing (indeterminate — Core ML compilation reports no
//  progress).
//

import SwiftUI

struct ModelLoadingSplash: View {
    /// @Observable singletons — reading their properties in `body` registers the
    /// view for updates, so the status line and failure state stay live.
    private let engine = TranscriptionEngine.shared
    private let assets = ChartAssetStore.shared
    private let darkBlue = Color(red: 0.05, green: 0.2, blue: 0.5)

    /// Images gate onboarding, so they are reported first whenever outstanding.
    private var isPreparingAssets: Bool { !assets.isReady }

    /// TranscriptionEngine sets this exact prefix on the failure path.
    private var didFail: Bool { engine.statusMessage.hasPrefix("Failed to load") }

    /// Strictly between 0 and 1 — the engine resets it to 0 once the bytes are in
    /// and Core ML compilation starts, which has no progress to report.
    private var isDownloading: Bool {
        engine.downloadProgress > 0 && engine.downloadProgress < 1
    }

    private var headline: String {
        if isPreparingAssets { return "Preparing chart images" }
        if didFail { return "Couldn’t load dictation model" }
        return isDownloading ? "Downloading dictation model" : "Preparing dictation model"
    }

    private var detail: String {
        isPreparingAssets ? assets.statusMessage : engine.statusMessage
    }

    private var icon: String {
        isPreparingAssets ? "square.stack.3d.up" : "waveform.badge.mic"
    }

    var body: some View {
        ZStack {
            darkBlue.ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: icon)
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.white)

                if isPreparingAssets {
                    // Determinate: four discrete images, so the progress is real.
                    ProgressView(value: assets.progress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(maxWidth: 280)
                } else if didFail {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title)
                        .foregroundStyle(.yellow)
                } else if isDownloading {
                    // Determinate: this is a ~600 MB one-time transfer and a bare
                    // spinner for several minutes reads as a hang.
                    ProgressView(value: engine.downloadProgress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(maxWidth: 280)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }

                VStack(spacing: 8) {
                    Text(headline)
                        .font(.headline)
                        .foregroundStyle(.white)

                    // Reflects the live status: "Preparing chart images… 2 of 4",
                    // "Loading bundled model…", "Downloading model… 42%", a retry
                    // notice, or the error.
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 40)

                if didFail && !isPreparingAssets {
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
