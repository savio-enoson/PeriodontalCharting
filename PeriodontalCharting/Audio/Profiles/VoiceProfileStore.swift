//
//  VoiceProfileStore.swift
//  PeriodontalCharting
//
//  Named, switchable voice profiles on disk.
//
//      Documents/VoiceProfiles/
//        profiles.json                  index + which one is active
//        <uuid>/voice_sample.wav        take 1, normal voice
//        <uuid>/voice_sample_soft.wav   take 2, quiet voice
//        <uuid>/voice_sample_mask.wav   take 3, optional
//
//  MIGRATION IS AUTOMATIC AND SILENT. An install that predates profiles has its
//  takes at the Documents root; those are MOVED into a first profile on launch.
//  Nobody re-calibrates.
//
//  EVERYTHING UNDER `VoiceProfiles/` IS BIOMETRIC DATA — GDPR special category,
//  HIPAA identifier — so it carries an explicit protection class and is kept out
//  of iCloud. See "Data protection" below for which class goes where and why.
//

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class VoiceProfileStore {
    @ObservationIgnored static let shared = VoiceProfileStore()

    private(set) var profiles: [VoiceProfile] = []
    private(set) var activeID: String?

    /// Set when the last enrollment produced a spread wide enough that the
    /// clinician's own dictation is likely to be withheld. Cleared on re-enroll.
    private(set) var spreadWarning: String?

    /// Set when `profiles.json` EXISTS but could not be read — corrupt, or
    /// protected and the device was locked when we tried.
    ///
    /// While this is set the store REFUSES TO WRITE. The only thing it could
    /// write is an empty index over the top of a real one, which is exactly how
    /// every calibration in a clinic used to disappear without a message.
    private(set) var loadError: String?

    private static let indexFilename = "profiles.json"

    private static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceProfiles", isDirectory: true)
    }

    private static var indexURL: URL { root.appendingPathComponent(indexFilename) }

    private init() { load() }

    // MARK: - Access

    var active: VoiceProfile? { profiles.first { $0.id == activeID } }

    /// Directory for a profile, created on demand.
    ///
    /// Secured on every call, not only on creation: a directory that predates
    /// this code, or one restored from a backup taken before it, would otherwise
    /// keep the Documents default forever.
    func directory(for id: String) -> URL {
        let url = Self.root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        Self.secure(url)
        return url
    }

    var activeDirectory: URL? { activeID.map { directory(for: $0) } }

    /// Path relative to Documents, for `AudioManager.startRecording(filename:)`.
    /// AudioManager appends whatever it is given to the Documents root, so a
    /// relative path with slashes works and no change is needed there.
    func relativePath(_ take: CalibrationTake, for id: String) -> String {
        "VoiceProfiles/\(id)/\(take.rawValue)"
    }

    var activeTakeURLs: [URL] {
        guard let dir = activeDirectory else { return [] }
        return CalibrationTake.allCases
            .map { $0.url(in: dir) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Mutation

    @discardableResult
    func createProfile(named name: String) -> VoiceProfile {
        let profile = VoiceProfile(name: name)
        profiles.append(profile)
        _ = directory(for: profile.id)
        if activeID == nil { activeID = profile.id }
        save()
        AppLog.profiles.info("created '\(name, privacy: .private)'")
        return profile
    }

    func rename(_ id: String, to name: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].name = name
        save()
    }

    /// Delete a profile and its recordings.
    ///
    /// Refuses to delete the last one — an app with no profile has nowhere to put
    /// a calibration and would silently stop gating.
    @discardableResult
    func delete(_ id: String) -> Bool {
        guard profiles.count > 1, let i = profiles.firstIndex(where: { $0.id == id }) else {
            return false
        }
        try? FileManager.default.removeItem(at: directory(for: id))
        profiles.remove(at: i)
        if activeID == id { activeID = profiles.first?.id }
        save()
        return true
    }

    func setActive(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeID = id
        save()
        // Logger interpolations are AUTOCLOSURES — every capture of a property
        // has to name `self` explicitly, here and below.
        AppLog.profiles.info("active -> '\(self.active?.name ?? id, privacy: .private)'")
    }

    /// Store the embeddings and the measured spread after an enrollment.
    func updateAfterEnrollment(id: String,
                               templates: [[Double]],
                               selfDistances: [Double]) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].templates = templates

        if selfDistances.isEmpty {
            profiles[i].selfDistanceMedian = nil
            profiles[i].selfDistanceMax = nil
            spreadWarning = nil
        } else {
            let sorted = selfDistances.sorted()
            let median = sorted[sorted.count / 2]
            let worst = sorted.last!
            profiles[i].selfDistanceMedian = median
            profiles[i].selfDistanceMax = worst

            let accept = profiles[i].acceptThreshold ?? SpeakerGate.defaultAcceptThreshold
            AppLog.profiles.info("'\(self.profiles[i].name, privacy: .private)' self-spread: median \(median, format: .fixed(precision: 3)), max \(worst, format: .fixed(precision: 3)) (accept line \(accept, format: .fixed(precision: 3)))")

            // WARN, never auto-raise. handoff.md: a false accept is unrecoverable,
            // a false reject costs one repeat — so the threshold moves DOWN if it
            // moves. A wide spread means re-record, not relax the gate.
            spreadWarning = profiles[i].spreadIsRisky
                ? String(format: "This voice varies a lot between takes (worst %.2f against "
                         + "an accept line of %.2f). Your own dictation may be withheld. "
                         + "Re-record the takes in a quieter spot, closer to the mic.",
                         worst, accept)
                : nil
        }
        save()
    }

    // MARK: - Data protection
    //
    // V1/V2. Voiceprints are biometric identifiers. Until this, `VoiceProfiles/`
    // sat at the Documents default — `completeUntilFirstUserAuthentication`,
    // decryptable at any point after one unlock since boot, so a clinic iPad
    // that stays awake between patients held them in the clear all day — and
    // nothing excluded them from iCloud, while the 632 MB RE-DOWNLOADABLE
    // Whisper model WAS excluded. Exactly backwards.
    //
    // `.completeUnlessOpen` rather than `.complete`, and the difference is
    // operational, not a weakening: `.complete` kills an already-open file
    // handle the instant the screen locks, and calibration is a multi-second
    // AVAudioRecorder write that the idle timer can interrupt. Closed-and-locked
    // is equally unreadable under both, which is the property V1 asks for.
    //
    // NOTE the interaction with `load()`: adding a protection class creates a
    // NEW way for the index to be unreadable (locked device), and the old
    // load-failure path destroyed the file. Do not ship this without the
    // `load()`/`save()` guards below.

    private static let protection: FileProtectionType = .completeUnlessOpen

    /// Apply the protection class and keep the item out of iCloud/iTunes
    /// backups. Both are idempotent — safe to call on every access.
    private static func secure(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: protection], ofItemAtPath: url.path)

        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Retrofit every profile directory, every recording and the index.
    ///
    /// Setting the class on a DIRECTORY only governs files created after that
    /// point, so without this sweep an already-calibrated iPad keeps its
    /// cleartext voiceprints for the life of the install.
    private static func secureExisting() {
        let fm = FileManager.default
        secure(root)
        if fm.fileExists(atPath: indexURL.path) { secure(indexURL) }

        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            secure(entry)
            guard let files = try? fm.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: nil) else { continue }
            for file in files { secure(file) }
        }
    }

    // MARK: - Persistence

    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.root, withIntermediateDirectories: true)
        Self.secure(Self.root)

        loadError = nil

        // ABSENT and UNREADABLE are not the same thing. Conflating them is what
        // destroyed calibrations: a decode failure fell into the fresh-install
        // branch, created "Dentist 1", and `save()` then wrote an empty index
        // over the damaged one — no message, original gone. An index that
        // exists but will not read now STOPS the store instead.
        if fm.fileExists(atPath: Self.indexURL.path) {
            do {
                let data = try Data(contentsOf: Self.indexURL)
                let index = try JSONDecoder().decode(VoiceProfileIndex.self, from: data)
                profiles = index.profiles
                activeID = index.activeID ?? index.profiles.first?.id
            } catch {
                profiles = []
                activeID = nil
                loadError = "The voice profile index could not be read, so no profile is "
                          + "loaded and the speaker filter is OFF. The file has been left "
                          + "untouched — do not re-record over it."
                AppLog.profiles.fault(
                    "REFUSING TO OVERWRITE unreadable index: \(error.localizedDescription, privacy: .public)")
                return
            }
        } else {
            profiles = []
            activeID = nil
        }

        migrateLegacyIfNeeded()

        // An app with no profile has nowhere to put a calibration.
        if profiles.isEmpty {
            createProfile(named: "Dentist 1")
        } else if activeID == nil || !profiles.contains(where: { $0.id == activeID }) {
            activeID = profiles.first?.id
            save()
        }

        Self.secureExisting()
    }

    private func save() {
        // Never write over an index we could not read. See `load()`.
        guard loadError == nil else {
            AppLog.profiles.error("save suppressed — the on-disk index is unreadable")
            return
        }

        let index = VoiceProfileIndex(profiles: profiles, activeID: activeID)
        guard let data = try? JSONEncoder().encode(index) else {
            AppLog.profiles.error("FAILED to encode index — changes not saved")
            return
        }
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        Self.secure(Self.root)

        // V5: `try?` here meant a full disk lost profile changes silently while
        // the app carried on as though they had persisted.
        do {
            try data.write(to: Self.indexURL, options: .atomic)
            // An atomic write REPLACES the file, so the class must be reapplied
            // to the new inode every time. Dropping this line is a silent
            // regression of V1 that nothing would catch.
            Self.secure(Self.indexURL)
        } catch {
            AppLog.profiles.error(
                "FAILED to save index: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Adopt calibration takes from before profiles existed.
    ///
    /// They sit at the Documents root (`voice_sample.wav`, `voice_sample_soft.wav`)
    /// because that is where `AudioManager` wrote them. MOVED rather than copied:
    /// nothing reads the old location any more, and leaving duplicates would mean
    /// a future bug could silently enroll from the stale pair.
    private func migrateLegacyIfNeeded() {
        guard profiles.isEmpty else { return }
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]

        let legacy = CalibrationTake.allCases
            .map { (take: $0, url: documents.appendingPathComponent($0.rawValue)) }
            .filter { fm.fileExists(atPath: $0.url.path) }
        guard !legacy.isEmpty else { return }

        let profile = VoiceProfile(name: "Dentist 1")
        profiles = [profile]
        activeID = profile.id
        let dir = directory(for: profile.id)

        for item in legacy {
            let destination = item.take.url(in: dir)
            try? fm.removeItem(at: destination)
            do {
                try fm.moveItem(at: item.url, to: destination)
            } catch {
                // A failed move must not lose the recording — fall back to a copy
                // and leave the original where it is.
                try? fm.copyItem(at: item.url, to: destination)
            }
            // The legacy file carried the Documents default; a move preserves
            // the old class, so the new location has to be secured explicitly.
            Self.secure(destination)
        }
        save()
        AppLog.profiles.info("migrated \(legacy.count) legacy take(s) into 'Dentist 1'")
    }
}
