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

import Foundation
import Observation

@MainActor
@Observable
final class VoiceProfileStore {
    @ObservationIgnored static let shared = VoiceProfileStore()

    private(set) var profiles: [VoiceProfile] = []
    private(set) var activeID: String?

    /// Set when the last enrollment produced a spread wide enough that the
    /// clinician's own dictation is likely to be withheld. Cleared on re-enroll.
    private(set) var spreadWarning: String?

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
    func directory(for id: String) -> URL {
        let url = Self.root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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
        print("[Profiles] created '\(name)' (\(profile.id))")
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
        print("[Profiles] active -> '\(active?.name ?? id)'")
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
            print(String(format: "[Profiles] '%@' self-spread: median %.3f, max %.3f "
                         + "(accept line %.3f)",
                         profiles[i].name, median, worst, accept))

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

    // MARK: - Persistence

    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.root, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: Self.indexURL),
           let index = try? JSONDecoder().decode(VoiceProfileIndex.self, from: data) {
            profiles = index.profiles
            activeID = index.activeID ?? index.profiles.first?.id
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
    }

    private func save() {
        let index = VoiceProfileIndex(profiles: profiles, activeID: activeID)
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        try? data.write(to: Self.indexURL, options: .atomic)
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
        }
        save()
        print("[Profiles] migrated \(legacy.count) legacy take(s) into 'Dentist 1'")
    }
}
