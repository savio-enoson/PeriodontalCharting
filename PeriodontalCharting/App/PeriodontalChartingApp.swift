//
//  PeriodontalChartingApp.swift
//  PeriodontalCharting
//
//  Created by Savio Enoson on 20/7/26.
//

import SwiftUI
import SwiftData

@main
struct PeriodontalChartingApp: App {
    init() {
        UserDefaults.standard.register(defaults: [
            "useOfflineWav2Vec": true
        ])
    }
    
    var body: some Scene {
        WindowGroup {
            // The STT model warm-up USED TO LIVE HERE and started at launch,
            // unconditionally, which put its compile alongside onboarding and made
            // everything the setup screen does — presenting the keyboard, decoding
            // the chart diagrams, activating the audio session — queue behind it.
            // It has moved into ContentView and now waits for setup to finish,
            // where the splash already exists to cover it.
            ContentView()
                // Persist patient charts with SwiftData. The container is created
                // once and injected into the environment for @Query / modelContext.
                .modelContainer(for: PatientChart.self)
                // Warm the speaker-gate / VAD infrastructure at launch. The
                // Wav2Vec2 STT model loads separately, gated by the splash in
                // ContentView (it warms only after onboarding completes).
                .task {
                    // Load the small speaker isolation / VAD models. ORDER MATTERS:
                    // templates are in memory only, so without restoreEnrollment()
                    // a cold start has no centroid.
                    await TranscriptionEngine.shared.restoreEnrollment()
                    await TranscriptionEngine.shared.load()
                }
        }
    }
}
