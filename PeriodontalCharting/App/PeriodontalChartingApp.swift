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
            // ONLY THE SMALL MODELS LOAD HERE. Anything heavy waits for setup to
            // finish and loads in ContentView, behind the splash — a big Core ML
            // compile at launch queues everything onboarding does (the keyboard,
            // the chart diagrams, the audio session) behind it.
            ContentView()
                // Persist patient charts with SwiftData. The container is created
                // once and injected into the environment for @Query / modelContext.
                .modelContainer(for: PatientChart.self)
                .task {
                    // ORDER MATTERS: templates are in memory only, so without
                    // restoreEnrollment() a cold start has no centroid — and with
                    // no centroid the gate reports itself off and every voice in
                    // the room is transcribed.
                    await TranscriptionEngine.shared.restoreEnrollment()
                    await TranscriptionEngine.shared.load()
                }
        }
    }
}
