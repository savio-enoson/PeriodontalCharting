//
//  CalibrationTake.swift
//  PeriodontalCharting
//
//  The calibration recording is SEVERAL takes, not one, and they now live inside
//  a profile directory rather than at the Documents root.
//
//  WHY MULTIPLE TAKES. The centroid built from one take at one volume only knows
//  what the clinician sounds like when he projects. Measured 2026-08-06, same
//  speaker both sessions:
//
//      normal voice   rms 0.076–0.144   0 rejects / 11 spans
//      soft   voice   rms 0.025–0.044   3 rejects /  5 spans
//
//  Two of those three rejects were full-length 2.7 s and 2.0 s spans of real
//  speech scoring 0.806 and 0.808 against a 0.775 line. The gate was withholding
//  his own dictation purely because he had lowered his voice mid-procedure —
//  which is what a dentist does when leaning over a patient.
//
//  Gain does not fix it: ECAPA normalises mean and variance per utterance
//  (journal.md measured distance shifting 0.0000 across a 64x gain range), so
//  scaling moves speech and background together. Enrolling the quiet voice does.
//
//  FILENAMES ARE UNCHANGED so `VoiceProfileStore` can migrate a pre-profiles
//  install by moving the files rather than rewriting anything.
//

import Foundation

enum CalibrationTake: String, CaseIterable, Identifiable {
    /// The original file. A pre-profiles install already has this one.
    case normal = "voice_sample.wav"
    /// The one that matters. This is the condition the gate used to fail on.
    case soft   = "voice_sample_soft.wav"
    /// Optional third condition — mask on, or standing further from the mic.
    case mask   = "voice_sample_mask.wav"

    var id: String { rawValue }
    var filename: String { rawValue }

    func url(in directory: URL) -> URL {
        directory.appendingPathComponent(rawValue)
    }

    func exists(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(in: directory).path)
    }

    var title: String {
        switch self {
        case .normal: return "Normal voice"
        case .soft:   return "Quiet voice"
        case .mask:   return "Mask on (optional)"
        }
    }

    var instruction: String {
        switch self {
        case .normal:
            return "Read the passage at the volume you'd use talking across the room."
        case .soft:
            return "Read it again, quietly — the way you speak leaning over a patient. "
                 + "Without this the app will silence you whenever you lower your voice."
        case .mask:
            return "Read it once more with your mask on, if you wear one while charting."
        }
    }

    /// Only the first is strictly required; without it there is no centroid.
    var isRequired: Bool { self == .normal }

    /// Takes that exist for a given profile directory, in order.
    static func recorded(in directory: URL) -> [CalibrationTake] {
        allCases.filter { $0.exists(in: directory) }
    }
}
