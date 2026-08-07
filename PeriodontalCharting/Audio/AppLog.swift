//
//  AppLog.swift
//  PeriodontalCharting
//
//  `print` reaches Console.app for anyone who plugs the iPad into a Mac, in
//  RELEASE builds included, with no levels, no categories and no redaction.
//  Of the 84 sites in this app, two carried dictated patient measurements and
//  five carried clinician names.
//
//  `Logger` fixes that properly rather than by conditional compilation: string
//  interpolation is redacted by DEFAULT for non-numeric values, so clinical text
//  has to be opted IN to appear, which is the right way round for a medical app.
//  Numbers (distances, counts, timings) interpolate visibly, which is exactly
//  the material this project debugs with.
//
//  Read a clinic session with:
//      log stream --predicate 'subsystem CONTAINS "PeriodontalCharting"' --level debug
//

import OSLog

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "PeriodontalCharting"

    static let gate     = Logger(subsystem: subsystem, category: "gate")
    static let profiles = Logger(subsystem: subsystem, category: "profiles")
    static let stt      = Logger(subsystem: subsystem, category: "stt")
    static let audio    = Logger(subsystem: subsystem, category: "audio")
    static let tse      = Logger(subsystem: subsystem, category: "tse")
    static let model    = Logger(subsystem: subsystem, category: "model")
}
