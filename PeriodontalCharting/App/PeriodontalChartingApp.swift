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
    var body: some Scene {
        WindowGroup {
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
