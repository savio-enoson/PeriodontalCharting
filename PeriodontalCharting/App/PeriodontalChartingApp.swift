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
        }
    }
}
