//
//  ChartingConfiguration+Defaults.swift
//  PeriodontalCharting
//
//  One owner for the persisted annotation order.
//
//  The literal key "ChartingConfiguration" and its decode-or-default dance were
//  open-coded in five places (AIVoiceViewModel, OnboardingView twice,
//  SelectionDebugMenu twice) — and the two debug-menu copies used a different
//  fallback shape (`?? Data()` inside a `try?`) from the other three, so they
//  could not be reasoned about together.
//

import Foundation
import OSLog

extension ChartingConfiguration {
    private static let defaultsKey = "ChartingConfiguration"

    /// The saved annotation order, or the built-in default when nothing has been
    /// saved or the stored blob no longer decodes.
    static func loadSaved() -> ChartingConfiguration {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(ChartingConfiguration.self, from: data)
        else { return ChartingConfiguration() }
        return saved
    }

    /// Persist as the app-wide annotation order.
    ///
    /// A failure here used to vanish inside `if let encoded = try?` and the
    /// setup screen still dismissed as though it had saved.
    func saveAsDefault() {
        guard let encoded = try? JSONEncoder().encode(self) else {
            AppLog.audio.error("FAILED to encode ChartingConfiguration — annotation order not saved")
            return
        }
        UserDefaults.standard.set(encoded, forKey: Self.defaultsKey)
    }
}
