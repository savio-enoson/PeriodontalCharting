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
//    2. DICTATION MODEL — the Wav2Vec2 STT model. Bundled (no download), loads in
//       a few seconds. Gates the chart, not onboarding: the clinician completes
//       setup while it warms.
//
//  Images come first, so on a first run the sequence is
//      "Preparing chart images" -> onboarding -> "Preparing dictation model" -> chart.
//

import SwiftUI

struct ModelLoadingSplash: View {
    /// @Observable singleton — reading its properties in `body` registers the view
    /// for updates so the asset-progress line stays live.
    private let assets = ChartAssetStore.shared
    private let darkBlue = Color(red: 0.05, green: 0.2, blue: 0.5)

    /// Images gate onboarding, so they are reported first whenever outstanding.
    private var isPreparingAssets: Bool { !assets.isReady }

    private var headline: String {
        isPreparingAssets ? "Preparing chart images" : "Preparing dictation model"
    }

    private var detail: String {
        isPreparingAssets ? assets.statusMessage : "Loading Wav2Vec2 model…"
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
                } else {
                    // Core ML compilation of the bundled model reports no progress.
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }

                VStack(spacing: 8) {
                    Text(headline)
                        .font(.headline)
                        .foregroundStyle(.white)

                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 40)
            }
        }
    }
}

#Preview {
    ModelLoadingSplash()
}
