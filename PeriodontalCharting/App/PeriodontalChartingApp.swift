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
            "useWav2Vec": true,
            "useOfflineWav2Vec": true
        ])
    }
    
    var body: some Scene {
        WindowGroup {
            // The WhisperKit warm-up USED TO LIVE HERE and started at launch,
            // unconditionally. On a first run that put a ~180 s Core ML encoder
            // compile alongside onboarding, and everything the setup screen does
            // — presenting the keyboard, decoding the chart diagrams, activating
            // the audio session — queued behind it. It has moved into ContentView
            // and now waits for setup to finish, where the splash already exists
            // to cover it.
            ContentView()
                // Persist patient charts with SwiftData. The container is created
                // once and injected into the environment for @Query / modelContext.
                .modelContainer(for: PatientChart.self)
                // Warm the shared models at launch so live/AI-Mode
                // transcription is ready the moment the user reaches for it.
                // We serialize the loading here to prevent CoreML from spiking
                // memory by compiling multiple models concurrently.
                .task {
                    // 1. Load the small speaker isolation / VAD models first.
                    // ORDER MATTERS: templates are in memory only, so without
                    // restoreEnrollment() a cold start has no centroid.
                    await TranscriptionEngine.shared.restoreEnrollment()
                    
                    // 2. Load the ~600 MB WhisperKit model. This compile is heavy,
                    // so it waits until the smaller models are done.
                    await TranscriptionEngine.shared.load()
                }
        }
    }
}
