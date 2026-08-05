//
//  PeriodontalChartingApp.swift
//  PeriodontalCharting
//
//  Created by Savio Enoson on 20/7/26.
//

import SwiftUI

@main
struct PeriodontalChartingApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
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
                // decision IS a distance from that centroid. This call had no
                // call site before; that is why the gate looked inert at launch.
                .task {
                    // Restore enrollment centroid here if needed
                }
        }
    }
}
