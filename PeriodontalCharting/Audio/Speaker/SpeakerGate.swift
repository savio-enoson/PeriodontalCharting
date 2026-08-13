//
//  SpeakerGate.swift
//  PeriodontalCharting
//
//  Created by Hans Joachim Wiryonoptutro on 27/07/26.
//
//  Core ML wrapper around SpeakerEmbedding_ECAPA.mlmodelc (exported from
//  TSE/src/tse.py `export_coreml`). Decides whether a speech segment came from the
//  calibrated clinician, so an assistant's voice or a passing remark never reaches
//  the chart.
//
//  MEASURED OFFLINE (TSE/notebooks/ecapa-tdnn.ipynb — 1 target speaker,
//  2 held-out imposters, 44 held-out target turns):
//
//      single-template calibration ..... EER 8.6%
//      multi-template centroid ......... EER 1.0%
//      multi-template min-distance ..... EER 5.1%
//
//  Enrollment strategy — not model choice — was the lever: ECAPA-TDNN and
//  WeSpeaker ResNet34 picked the same speaker with no measurable difference, while
//  moving from one enrollment clip to a centroid of several improved EER ~8x.
//  min() over templates is WORSE than the centroid because it lowers imposter
//  distances just as much as target ones.
//
//  OPERATING POINT (centroid enrollment, ECAPA embeddings):
//      d <  0.675  ACCEPT   FAR 0.0%,  captures 86.4% of target speech
//      d <  0.775  CONFIRM  FAR 1.0%,  captures a further 9.1%
//      d >= 0.775  REJECT   4.5% of target speech lost (clinician repeats)
//
//  THRESHOLDS ARE PER-INSTANCE AND MUTABLE, because a VoiceProfile may carry its
//  own. They are still PER-MODEL: cosine distances are not comparable across
//  embedders, so re-derive with tse.py `evaluate()` before swapping the .mlpackage.
//
//  The model is a fixed-shape graph:
//      waveform  [1, 48000] f32  (16 kHz mono, exactly 3.0 s)
//    → embedding [1, 192]
//  Shorter input is zero-padded, longer is centre-cropped.
//

import Foundation
import CoreML
import AVFoundation

enum Verdict: String {
    case accept, confirm, reject, tooShort
}

struct GateResult {
    let verdict: Verdict
    let distance: Double?
}

/// `@unchecked Sendable`: after init the model is read-only, MLModel prediction is
/// thread-safe, and all mutable state — enrollment AND thresholds — is behind
/// `lock`, so this can be handed to a background classification task.
final class SpeakerGate: @unchecked Sendable {

    enum GateError: Error {
        case modelNotFound
        case noEmbeddingOutput
        case notEnrolled
    }

    static let sampleRate = 16_000
    /// Must match `input_seconds` used at export time (tse.py `export_coreml`).
    static let inputSamples = 48_000

    /// Re-validated by re-measurement rather than assumed. A profile override that
    /// is nil falls back to these.
    static let defaultAcceptThreshold = 0.675
    static let defaultRejectThreshold = 0.775

    // Operating point — see the header block for the measured FAR/FRR sweep.
    // Guarded by `lock`: `classify` runs on the gate queue while a profile switch
    // comes from the main actor.
    private(set) var acceptThreshold: Double
    private(set) var rejectThreshold: Double
    private var adaptThreshold: Double
    private let adaptMargin: Double

    /// Below this, embeddings are dominated by duration artefact rather than
    /// speaker identity (measured: a 1 s window sits ~0.46 from the 6 s embedding
    /// of the *same* audio). `classify` refuses below it.
    static let minDurationSeconds = 1.0
    /// Enrollment capacity. Past this, `recomputeCentroidLocked` evicts FIFO.
    /// Exposed so multi-condition calibration can budget templates per take and
    /// never trigger eviction — which would drop the EARLIEST condition.
    static let maxTemplates = 16

    private let model: MLModel
    private var inputName = "waveform"
    private var outputName = "embedding"

    // Guarded by `lock`: adaptive enrollment mutates these from the classification
    // queue while the UI may enroll or switch profile from the main actor.
    private let lock = NSLock()
    private var templates: [[Double]] = []
    private var centroid: [Double]?

    var isEnrolled: Bool {
        lock.lock(); defer { lock.unlock() }
        return centroid != nil
    }

    var templateCount: Int {
        lock.lock(); defer { lock.unlock() }
        return templates.count
    }

    init(acceptThreshold: Double = SpeakerGate.defaultAcceptThreshold,
         rejectThreshold: Double = SpeakerGate.defaultRejectThreshold,
         adaptMargin: Double = 0.9) throws {
        guard let url = Self.locateModel() else { throw GateError.modelNotFound }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine
        self.model = try MLModel(contentsOf: url, configuration: cfg)
        self.acceptThreshold = acceptThreshold
        self.rejectThreshold = rejectThreshold
        self.adaptMargin = adaptMargin
        self.adaptThreshold = acceptThreshold * adaptMargin
        resolveIONames()
    }

    /// Same lookup strategy as SileroVADEngine: Xcode's synchronized file group
    /// flattens AI/ so the compiled model lands at the bundle ROOT.
    private static func locateModel() -> URL? {
        if let root = Bundle.main.resourceURL {
            let flat = root.appendingPathComponent("SpeakerEmbedding_ECAPA.mlmodelc")
            if FileManager.default.fileExists(atPath: flat.path) { return flat }
        }
        return Bundle.main.url(forResource: "SpeakerEmbedding_ECAPA", withExtension: "mlmodelc")
    }

    /// Core ML can rename graph I/O during conversion, so bind by shape rather
    /// than trusting the names we asked for at export time.
    private func resolveIONames() {
        let inputs = model.modelDescription.inputDescriptionsByName
        if inputs[inputName] == nil,
           let match = inputs.first(where: { $0.value.multiArrayConstraint != nil }) {
            inputName = match.key
        }
        let outputs = model.modelDescription.outputDescriptionsByName
        if outputs[outputName] == nil,
           let match = outputs.first(where: { $0.value.multiArrayConstraint != nil }) {
            outputName = match.key
        }
    }

    // MARK: - Operating point

    /// Apply a profile's operating point. `nil` restores the measured defaults.
    ///
    /// handoff.md: the margin is asymmetric in the WRONG direction for the cost
    /// model — a false accept puts a wrong number on a chart and nobody notices,
    /// a false reject costs one repeat — so any adjustment goes DOWN. Nothing in
    /// the app raises these automatically; a speaker whose own clips scatter
    /// widely gets told to re-record instead (VoiceProfileStore.spreadWarning).
    func applyThresholds(accept: Double?, reject: Double?) {
        lock.lock()
        acceptThreshold = accept ?? Self.defaultAcceptThreshold
        rejectThreshold = reject ?? Self.defaultRejectThreshold
        adaptThreshold = acceptThreshold * adaptMargin
        lock.unlock()
    }

    // MARK: - Embedding

    private func embed(_ samples: [Float]) throws -> [Double] {
        let n = Self.inputSamples
        guard let input = try? MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .float32) else {
            throw GateError.noEmbeddingOutput
        }
        let buf = input.dataPointer.assumingMemoryBound(to: Float.self)

        if samples.count >= n {
            let start = (samples.count - n) / 2      // centre-crop
            samples.withUnsafeBufferPointer { src in
                buf.update(from: src.baseAddress! + start, count: n)
            }
        } else {
            samples.withUnsafeBufferPointer { src in
                buf.update(from: src.baseAddress!, count: samples.count)
            }
            for i in samples.count..<n { buf[i] = 0 }   // zero-pad
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: input])
        let out = try model.prediction(from: provider)
        guard let emb = out.featureValue(for: outputName)?.multiArrayValue else {
            throw GateError.noEmbeddingOutput
        }

        var vec = [Double](repeating: 0, count: emb.count)
        for i in 0..<emb.count { vec[i] = emb[i].doubleValue }
        return Self.unit(vec)
    }

    /// Internal rather than private: `leaveOneOutDistances` needs it from a static
    /// context outside any instance.
    static func unit(_ v: [Double]) -> [Double] {
        let norm = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard norm > 1e-12 else { return v }
        return v.map { $0 / norm }
    }

    // MARK: - Enrollment

    /// Add enrollment utterances. Pass SEVERAL spanning different conditions
    /// (mask on/off, near/far, normal/quiet) — that difference was worth ~8x EER.
    /// One clip is the weak case, and one VOLUME is the case that measured as
    /// withholding the clinician's own soft dictation.
    @discardableResult
    func enroll(_ utterances: [[Float]]) throws -> Int {
        let minSamples = Int(Self.minDurationSeconds * Double(Self.sampleRate))
        var embedded: [[Double]] = []
        for u in utterances where u.count >= minSamples {
            embedded.append(try embed(u))          // inference outside the lock
        }
        guard !embedded.isEmpty else { return 0 }

        lock.lock()
        templates.append(contentsOf: embedded)
        recomputeCentroidLocked()
        lock.unlock()
        return embedded.count
    }

    func resetEnrollment() {
        lock.lock()
        templates.removeAll()
        centroid = nil
        lock.unlock()
    }

    /// The current templates, for caching on a profile.
    var currentTemplates: [[Double]] {
        lock.lock(); defer { lock.unlock() }
        return templates
    }

    /// Load cached embeddings instead of recomputing them from audio.
    ///
    /// This is what makes switching dentist instant. Rebuilding a centroid means
    /// an ECAPA pass over every take of the profile; a clinic with a rotation
    /// would pay that at every handover.
    func restore(templates newTemplates: [[Double]]) {
        lock.lock()
        templates = newTemplates
        recomputeCentroidLocked()
        lock.unlock()
    }

    /// Leave-one-out distances: each template against the centroid of the others.
    ///
    /// THE ONLY THRESHOLD EVIDENCE CALIBRATION CAN PRODUCE. A reject threshold
    /// separates this person from SOMEBODY ELSE, and calibration contains no
    /// somebody else. What this does show is whether the accept line has room for
    /// a particular voice: clips clustering at 0.30–0.45 are comfortable against
    /// 0.675, clips reaching 0.60+ mean the speaker will be withheld while talking
    /// normally — and it is far better to learn that at setup than mid-patient.
    ///
    /// Returns empty below three templates, where leaving one out leaves too
    /// little to average meaningfully.
    static func leaveOneOutDistances(_ templates: [[Double]]) -> [Double] {
        guard templates.count >= 3, let dim = templates.first?.count else { return [] }
        var out: [Double] = []
        out.reserveCapacity(templates.count)

        for i in templates.indices {
            var mean = [Double](repeating: 0, count: dim)
            for (j, t) in templates.enumerated() where j != i {
                for d in 0..<dim { mean[d] += t[d] }
            }
            let n = Double(templates.count - 1)
            for d in 0..<dim { mean[d] /= n }
            let centre = unit(mean)
            let dot = zip(centre, templates[i]).reduce(0) { $0 + $1.0 * $1.1 }
            out.append(1.0 - dot)
        }
        return out
    }

    /// Caller must hold `lock`.
    private func recomputeCentroidLocked() {
        if templates.count > Self.maxTemplates {
            templates.removeFirst(templates.count - Self.maxTemplates)
        }
        guard let dim = templates.first?.count, !templates.isEmpty else {
            centroid = nil
            return
        }
        var mean = [Double](repeating: 0, count: dim)
        for t in templates {
            for i in 0..<dim { mean[i] += t[i] }
        }
        for i in 0..<dim { mean[i] /= Double(templates.count) }
        centroid = Self.unit(mean)
    }

    // MARK: - Classification

    func classify(_ samples: [Float], adapt: Bool = false) throws -> GateResult {
        // Thresholds are read under the lock alongside the centroid: a profile
        // switch can change them from the main actor while this runs on the gate
        // queue, and reading a half-applied pair would judge against a mixture of
        // two operating points.
        lock.lock()
        let snapshot = centroid
        let accept = acceptThreshold
        let reject = rejectThreshold
        let adaptLine = adaptThreshold
        lock.unlock()
        guard let snapshot else { throw GateError.notEnrolled }

        let minSamples = Int(Self.minDurationSeconds * Double(Self.sampleRate))
        guard samples.count >= minSamples else {
            return GateResult(verdict: .tooShort, distance: nil)
        }

        let emb = try embed(samples)
        let dot = zip(snapshot, emb).reduce(0) { $0 + $1.0 * $1.1 }
        let distance = 1.0 - dot

        let verdict: Verdict
        if distance < accept {
            verdict = .accept
        } else if distance < reject {
            verdict = .confirm
        } else {
            verdict = .reject
        }

        // Only fold in comfortably-accepted segments, so the centroid cannot drift
        // toward whatever it has been mistakenly accepting.
        if adapt && distance < adaptLine {
            lock.lock()
            templates.append(emb)
            recomputeCentroidLocked()
            lock.unlock()
        }

        return GateResult(verdict: verdict, distance: distance)
    }
}

// MARK: - Audio loading

extension SpeakerGate {

    /// Read any CoreAudio-decodable file as 16 kHz mono Float32, peak-normalized.
    ///
    /// PARITY NOTE: the offline pipeline also applies an 80 Hz high-pass and
    /// peak-normalizes the WHOLE FILE before cutting segments. Measured effect of
    /// the high-pass was +0.003 on distances (inside noise) so it is omitted, but
    /// verify measured distances against Python before trusting on-device verdicts.
    static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: source,
                                          frameCapacity: AVAudioFrameCount(file.length)) else {
            return []
        }
        try file.read(into: inBuf)

        var mono: [Float]
        if source.sampleRate == Double(sampleRate) && source.channelCount == 1 {
            guard let ch = inBuf.floatChannelData else { return [] }
            mono = Array(UnsafeBufferPointer(start: ch[0], count: Int(inBuf.frameLength)))
        } else {
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: Double(sampleRate),
                                             channels: 1,
                                             interleaved: false),
                  let converter = AVAudioConverter(from: source, to: target)
            else { return [] }

            let ratio = target.sampleRate / source.sampleRate
            let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                return []
            }

            var error: NSError?
            var supplied = false
            converter.convert(to: outBuf, error: &error) { _, status in
                if supplied { status.pointee = .endOfStream; return nil }
                supplied = true
                status.pointee = .haveData
                return inBuf
            }
            guard error == nil, let ch = outBuf.floatChannelData else { return [] }
            mono = Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
        }

        var peak: Float = 0
        for s in mono { peak = max(peak, abs(s)) }
        if peak > 1e-8 { for i in mono.indices { mono[i] /= peak } }
        
        // Matches the offline pipeline, which applies an 80 Hz high-pass before
        // cutting segments. Previously omitted because its effect on DISTANCES
        // measured at +0.003 — but the energy segmenter, which did not exist then,
        // cares about the noise floor rather than the distance.
        HighPassFilter.filterFile(&mono)
        AutoGain.normalise(&mono)
        return mono
    }
}
