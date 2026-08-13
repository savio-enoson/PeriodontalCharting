//
//  ProtectedStorage.swift
//  PeriodontalCharting
//
//  ONE definition of "this file holds patient or biometric data".
//
//  The rules were written twice — once in `VoiceProfileStore` for voiceprints,
//  once in `ChartStore` for patient charts — which is how the app ended up with
//  the 632 MB re-downloadable Whisper model excluded from backup and the
//  irreplaceable voiceprints included. Protection policy stated in two places
//  is protection policy that will eventually disagree with itself.
//
//  WHY `.completeUnlessOpen` AND NOT `.complete`, for both stores:
//  `.complete` makes an already-open file handle fail the instant the screen
//  locks. Calibration is a multi-second AVAudioRecorder write the idle timer can
//  interrupt, and SwiftData holds its SQLite store open for the whole session —
//  so `.complete` breaks both. Closed-and-locked is equally unreadable under
//  either class, which is the property that actually matters.
//
//  TRAP: an atomic write REPLACES the inode, so protection must be re-applied
//  after every `Data.write(to:options:.atomic)` and after SwiftData creates its
//  -wal / -shm siblings. `secure(contentsOf:)` exists for that sweep.
//

import Foundation

enum ProtectedStorage {

    static let fileProtection: FileProtectionType = .completeUnlessOpen

    // Apply the protection class and keep the item out of iCloud/iTunes
    // backups. Idempotent — safe to call on every access.
    static func secure(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: fileProtection], ofItemAtPath: url.path)

        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // Secure a directory and everything one level inside it.
    //
    // Needed because setting the class on a DIRECTORY only governs files
    // created after that point — an install that predates this code keeps its
    // cleartext files forever without a sweep.
    static func secure(contentsOf directory: URL, recursive: Bool = false) {
        let fm = FileManager.default
        secure(directory)
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            secure(entry)
            guard recursive else { continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                secure(contentsOf: entry)
            }
        }
    }

    // Create a directory if needed and secure it in one step.
    @discardableResult
    static func makeSecureDirectory(at url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        secure(url)
        return url
    }
}
