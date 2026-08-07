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
                // Warm the shared WhisperKit model at launch so live/AI-Mode
                // transcription is ready the moment the user reaches for it,
                // instead of paying the ~1 GB load on first use.
                .task { await TranscriptionEngine.shared.load() }
                
                // Speaker identity, in its own task so it does NOT queue behind
                // the ~600 MB model. Both stages read voice_sample.wav and need
                // only the small Core ML packages.
                //
                // ORDER MATTERS: templates are in memory only, so without
                // restoreEnrollment() a cold start has no centroid — and with no
                // centroid the rescue path can never route, because the routing
                // decision IS a distance from that centroid.
                .task {
                    await TranscriptionEngine.shared.restoreEnrollment()
                    // Returns immediately while TSEConfig.mode is .off.
                    await TSEEngine.shared.prepare()
                }
        }
    }
}
