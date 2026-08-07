//
//  VoiceProfile.swift
//  PeriodontalCharting
//
//  One dentist's voice: their calibration takes, the embeddings built from them,
//  and how tightly their own clips cluster.
//
//  WHY EMBEDDINGS ARE STORED, not just the audio: switching profiles between
//  patients must be instant. Rebuilding a centroid means an ECAPA pass over every
//  take (~1 s), and a clinic with a rotation would pay that at every handover.
//  192 doubles x up to 16 templates is a few kilobytes.
//
//  WHY THE AUDIO IS KEPT ANYWAY: the extractor's `enroll_kv` comes from WeSpeaker
//  ECAPA — different weights, different embedding space — and cannot be rebuilt
//  from the gate's SpeechBrain embeddings. Both have to survive.
//

import Foundation

struct VoiceProfile: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var createdAt: Date

    /// Cached gate embeddings, already unit-normalised. Restored straight into
    /// `SpeakerGate` on a profile switch — no audio is read.
    var templates: [[Double]]

    /// How far this speaker's own calibration clips sit from each other, measured
    /// leave-one-out at enrollment.
    ///
    /// THIS IS THE ONLY THRESHOLD EVIDENCE CALIBRATION CAN PRODUCE. A reject
    /// threshold separates this person from SOMEBODY ELSE, and calibration has no
    /// somebody else in it. What it does show is whether the global 0.675 has room
    /// for this particular voice: a speaker whose own clips sit at 0.30–0.45 is
    /// comfortable, one whose clips reach 0.60+ will be rejected while speaking
    /// normally and should re-record before that happens mid-patient.
    var selfDistanceMedian: Double?
    var selfDistanceMax: Double?

    /// Per-profile overrides. `nil` means use the measured global defaults.
    ///
    /// Deliberately allowed to move DOWN only in practice — handoff.md: a false
    /// accept puts a wrong number on a chart and nobody notices, a false reject
    /// costs one repeat. `VoiceProfileStore.suggestedAcceptThreshold` never
    /// proposes raising it; a wide spread produces a warning to re-record instead.
    var acceptThreshold: Double?
    var rejectThreshold: Double?

    init(id: String = UUID().uuidString,
         name: String,
         createdAt: Date = Date(),
         templates: [[Double]] = [],
         selfDistanceMedian: Double? = nil,
         selfDistanceMax: Double? = nil,
         acceptThreshold: Double? = nil,
         rejectThreshold: Double? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.templates = templates
        self.selfDistanceMedian = selfDistanceMedian
        self.selfDistanceMax = selfDistanceMax
        self.acceptThreshold = acceptThreshold
        self.rejectThreshold = rejectThreshold
    }

    /// True when this speaker's own clips scatter far enough that the accept line
    /// is inside their normal range. Their own dictation will be withheld.
    var spreadIsRisky: Bool {
        guard let max = selfDistanceMax else { return false }
        return max >= (acceptThreshold ?? SpeakerGate.defaultAcceptThreshold) * 0.85
    }
}

/// What the index file holds. Separate from the array so the active selection
/// survives a relaunch.
struct VoiceProfileIndex: Codable {
    var profiles: [VoiceProfile]
    var activeID: String?
}
