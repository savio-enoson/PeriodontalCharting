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
            // The WhisperKit warm-up USED TO LIVE HERE and started at launch,
            // unconditionally. On a first run that put a ~180 s Core ML encoder
            // compile alongside onboarding, and everything the setup screen does
            // — presenting the keyboard, decoding the chart diagrams, activating
            // the audio session — queued behind it. It has moved into ContentView
            // and now waits for setup to finish, where the splash already exists
            // to cover it.
            ContentView()
                // Speaker identity stays at launch: it restores the centroid from
                // cached embeddings (no audio read, no ECAPA pass) and the gate is
                // inert without it.
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
