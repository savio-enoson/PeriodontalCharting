import Foundation
import SwiftData

/// A persisted periodontal charting session for a single patient exam.
///
/// The full-mouth chart is stored as JSON-encoded `Data` rather than as a
/// SwiftData relationship. `ToothObject` is already `Codable`, and encoding the
/// whole mouth as one blob keeps the SwiftData schema flat and stable — there is
/// no per-tooth query surface we need, we always load/save the mouth as a unit.
@Model
final class PatientChart {
    var patientName: String
    var createdAt: Date
    var updatedAt: Date

    /// JSON-encoded `[ToothObject]`. Access through `mouth` rather than directly.
    private var teethData: Data

    init(patientName: String, mouth: [Int: ToothObject] = ToothObject.fullMouthEmpty()) {
        self.patientName = patientName
        self.createdAt = .now
        self.updatedAt = .now
        self.teethData = Self.encode(mouth)
    }

    /// The full-mouth chart keyed by tooth number. Setting it bumps `updatedAt`.
    var mouth: [Int: ToothObject] {
        get {
            guard let teeth = try? JSONDecoder().decode([ToothObject].self, from: teethData),
                  !teeth.isEmpty else {
                return ToothObject.fullMouthEmpty()
            }
            var dict: [Int: ToothObject] = [:]
            for tooth in teeth { dict[tooth.toothNumber] = tooth }
            return dict
        }
        set {
            teethData = Self.encode(newValue)
            updatedAt = .now
        }
    }

    private static func encode(_ mouth: [Int: ToothObject]) -> Data {
        // Sort by tooth number so the stored blob is deterministic.
        let teeth = mouth.values.sorted { $0.toothNumber < $1.toothNumber }
        return (try? JSONEncoder().encode(teeth)) ?? Data()
    }
}
