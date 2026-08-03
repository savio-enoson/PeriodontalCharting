//
//  TargetSpeakerExtractor.swift
//  PeriodontalCharting
//
//  Target speaker extraction (Phase 2), assembled end to end: waveform in,
//  waveform out. BSRNN `tfmap_context_causal_100` at n_keys=1024 — the one
//  extractor of seven that passed the bench (SDRi +9.6 dB on routed items,
//  13/13 recovered, 0 unsafe promotions).
//
//  SPAN-BASED, NOT FRAME-STREAMING. `SpeakerGateService` already cuts audio into
//  merged VAD spans of <= 6 s, so extraction is a batch operation on a completed
//  span. That removes the ring buffer, the overlap-add tail across call
//  boundaries and the center=True alignment problem from the critical path. The
//  streaming work is still what makes it possible: Core ML wants fixed shapes, so
//  a span is processed as N fixed 8-frame blocks with (h, c) carried across —
//  exactly the loop that was proven bit-identical.
//
//  SIX Core ML models, in call order:
//      1. EnrollmentEncoder_WeSpeaker   fbank      -> frame features   (once)
//      2. EnrollmentProjection_BSRNN    frames     -> enroll_kv        (once)
//      3. TSEFrontend_BSRNN             spec_ri    -> band features    (per block)
//      4. SpeakerConditioning_BSRNN     + enroll_kv-> conditioned      (per block)
//      5. TargetSeparator_BSRNN         + (h, c)   -> separated        (per block)
//      6. TSEMasker_BSRNN               separated  -> complex mask     (per block)
//  STFT, iSTFT, the Kaldi fbank and the tfmap are Swift (Accelerate).
//
//  TWO ENCODERS ON DEVICE, and they are NOT interchangeable. This file uses
//  WeSpeaker ECAPA to condition the extractor; `SpeakerGate` uses SpeechBrain
//  ECAPA to decide identity. Same architecture, same 192 dims, different weights,
//  different embedding spaces. Feeding one's output to the other is silent
//  nonsense.
//
//  PARITY: the decomposition below (frontend / conditioning / separator in
//  8-frame blocks / masker / Swift complex-mask + iSTFT) reproduces
//  `model.forward` at 313.6 dB in float32 — i.e. exactly — measured before this
//  was ported. On device it runs in fp16; check VERDICTS, not just signal
//  metrics, because 0.9996 cosine did not guarantee identical verdicts near a
//  threshold and parity varies by compute unit.
//

import Accelerate
import CoreML
import Foundation

final class TargetSpeakerExtractor: @unchecked Sendable {

    enum ExtractorError: LocalizedError {
        case modelNotFound(String)
        case unexpectedIO(String)
        case notPrepared
        case enrollmentTooShort(seconds: Double)

        var errorDescription: String? {
            switch self {
            case .modelNotFound(let name):
                return "\(name).mlmodelc not in the bundle. Add the .mlpackage to the app target."
            case .unexpectedIO(let detail):
                return "Unexpected Core ML I/O: \(detail)"
            case .notPrepared:
                return "prepareEnrollment(_:) has not run — there is no enroll_kv to condition on."
            case .enrollmentTooShort(let s):
                return String(format: "Enrollment is %.1f s of speech; the exported "
                              + "conditioning graph needs >= 10.3 s to fill 1024 keys.", s)
            }
        }
    }

    // MARK: Models

    private let frontend: MLModel
    private let conditioning: MLModel
    private let separator: MLModel
    private let masker: MLModel
    private let enrollEncoder: MLModel
    private let enrollProjection: MLModel

    private let stft = TSESpectrogram()
    private let fbank = TSEKaldiFbank()

    // MARK: Enrollment state (guarded by `lock`)

    private let lock = NSLock()
    /// (nBands, enrollKeys, attenDim) fp32 = 16 MB. Allocated ONCE at
    /// calibration and handed to every predict() — re-marshalling this per block
    /// is the single most expensive mistake available in this file.
    private var enrollKV: MLMultiArray?
    /// L2-normalised enrollment magnitude, frequency-major (bins x frames).
    /// Pre-normalised because the tfmap needs it that way on every block.
    private var enrollMagNorm: [Float] = []
    private var enrollMagFrames = 0
    private var enrollSeconds: Double = 0

    var isPrepared: Bool {
        lock.lock(); defer { lock.unlock() }
        return enrollKV != nil
    }

    var enrollmentSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return enrollSeconds
    }

    // MARK: Init

    init(computeUnits: MLComputeUnits = TSEConfig.computeUnits) throws {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits
        func load(_ name: String) throws -> MLModel {
            guard let url = Self.locateModel(name) else { throw ExtractorError.modelNotFound(name) }
            return try MLModel(contentsOf: url, configuration: cfg)
        }
        frontend         = try load("TSEFrontend_BSRNN")
        conditioning     = try load("SpeakerConditioning_BSRNN")
        separator        = try load("TargetSeparator_BSRNN")
        masker           = try load("TSEMasker_BSRNN")
        enrollEncoder    = try load("EnrollmentEncoder_WeSpeaker")
        enrollProjection = try load("EnrollmentProjection_BSRNN")
    }

    /// Same lookup as SpeakerGate / SileroVADEngine: Xcode's synchronized file
    /// group flattens AI/, so compiled models land at the bundle ROOT.
    private static func locateModel(_ name: String) -> URL? {
        if let root = Bundle.main.resourceURL {
            let flat = root.appendingPathComponent("\(name).mlmodelc")
            if FileManager.default.fileExists(atPath: flat.path) { return flat }
        }
        return Bundle.main.url(forResource: name, withExtension: "mlmodelc")
    }

    // MARK: - Enrollment

    /// Build the conditioning tensors from calibration audio. Run once, off the
    /// main actor; it is ~1 s of work and its result is reused for every span.
    ///
    /// Feed CONCATENATED SPEECH, not a raw file: the Python context concatenates
    /// VAD spans from calibration.wav plus early spans of the session, giving
    /// 38.8 s. Silence between spans would spend keys on nothing.
    ///
    /// Gain does not matter — the fbank's CMVN and the tfmap's per-frame L2
    /// normalisation both remove it.
    func prepareEnrollment(_ audio: [Float]) throws {
        let seconds = Double(audio.count) / Double(TSEConfig.sampleRate)
        let (features, frames) = fbank.compute(audio)
        guard frames > 0 else { throw ExtractorError.enrollmentTooShort(seconds: seconds) }

        // 1024 keys need 1024 fbank frames at a 10 ms hop = 10.24 s. Below that
        // the linspace below starts DUPLICATING frames, which is a regime the
        // bench never scored. Refuse rather than silently degrade.
        guard frames >= TSEConfig.enrollKeys else {
            throw ExtractorError.enrollmentTooShort(seconds: seconds)
        }

        let fbankArray = try Self.makeArray([1, frames, TSEKaldiFbank.numMel])
        Self.write(features, into: fbankArray)
        let encoded = try enrollEncoder.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["fbank": fbankArray]))
        guard let frameFeatures = encoded.featureValue(for: "frames")?.multiArrayValue else {
            throw ExtractorError.unexpectedIO("EnrollmentEncoder produced no `frames`")
        }

        // Subsample to n_keys with torch.linspace(...).long() semantics —
        // TRUNCATION, not rounding. 3.8x less conditioning data cost nothing
        // measurable (SDRi 8.84 -> 8.82, unsafe 0 -> 0).
        var flat = [Float](repeating: 0, count: frameFeatures.count)
        Self.read(frameFeatures, into: &flat)
        let subsampled = try Self.makeArray([1, TSEConfig.enrollEmbedDim, TSEConfig.enrollKeys])
        let dst = subsampled.dataPointer.assumingMemoryBound(to: Float.self)
        let step = Double(frames - 1) / Double(TSEConfig.enrollKeys - 1)
        for key in 0..<TSEConfig.enrollKeys {
            let src = min(frames - 1, Int(Double(key) * step))
            for d in 0..<TSEConfig.enrollEmbedDim {
                dst[d * TSEConfig.enrollKeys + key] = flat[d * frames + src]
            }
        }

        let projected = try enrollProjection.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["enroll_frames": subsampled]))
        guard let kv = projected.featureValue(for: "enroll_kv")?.multiArrayValue else {
            throw ExtractorError.unexpectedIO("EnrollmentProjection produced no `enroll_kv`")
        }

        // tfmap side: enrollment magnitude, L2-normalised per frame once.
        let spec = stft.forward(audio)
        var mag = TSESpectrogram.magnitude(spec)
        Self.normaliseColumns(&mag, rows: TSEConfig.bins, columns: spec.frames)

        lock.lock()
        enrollKV = kv
        enrollMagNorm = mag
        enrollMagFrames = spec.frames
        enrollSeconds = seconds
        lock.unlock()

        print(String(format: "[TSE] enrolled %.1f s — %d fbank frames -> %d keys, "
                     + "%d stft frames for tfmap",
                     seconds, frames, TSEConfig.enrollKeys, spec.frames))
    }

    func resetEnrollment() {
        lock.lock()
        enrollKV = nil
        enrollMagNorm = []
        enrollMagFrames = 0
        enrollSeconds = 0
        lock.unlock()
    }

    // MARK: - Extraction

    /// Extract the enrolled speaker from one span. Returns the same number of
    /// samples as the input (the final partial hop is zero-filled).
    ///
    /// Cost on an A16 is roughly RTF 0.3 — a 6 s span costs ~1.8 s, added
    /// SERIALLY before transcription. That is why only routed spans come here.
    func extract(_ span: [Float]) throws -> [Float] {
        lock.lock()
        let kv = enrollKV
        let enrollMag = enrollMagNorm
        let enrollFrames = enrollMagFrames
        lock.unlock()
        guard let kv, enrollFrames > 0 else { throw ExtractorError.notPrepared }
        guard span.count > TSEConfig.nFFT else { return span }

        let spec = stft.forward(span)
        let frames = spec.frames
        let mixMag = TSESpectrogram.magnitude(spec)

        var estReal = [Float](repeating: 0, count: TSEConfig.bins * frames)
        var estImag = [Float](repeating: 0, count: TSEConfig.bins * frames)

        let block = TSEConfig.blockFrames
        let specRI = try Self.makeArray([1, 3, TSEConfig.bins, block])
        var h = try Self.makeArray([TSEConfig.nLayers, 1, TSEConfig.nBands, TSEConfig.hidden])
        var c = try Self.makeArray([TSEConfig.nLayers, 1, TSEConfig.nBands, TSEConfig.hidden])
        Self.zero(h); Self.zero(c)

        var maskReal = [Float](repeating: 0, count: TSEConfig.bins * block)
        var maskImag = [Float](repeating: 0, count: TSEConfig.bins * block)
        var tfmap = [Float](repeating: 0, count: TSEConfig.bins * block)
        var blockMag = [Float](repeating: 0, count: TSEConfig.bins * block)

        var start = 0
        while start < frames {
            let count = min(block, frames - start)

            // ---- tfmap: attend this block's magnitudes over the enrollment.
            // Frame-local by construction (each mix frame attends enrollment
            // frames only), so computing it per block is identical to computing
            // it over the whole span.
            for k in 0..<TSEConfig.bins {
                for t in 0..<block {
                    blockMag[k * block + t] = t < count ? mixMag[k * frames + start + t] : 0
                }
            }
            Self.computeTFMap(mixMagnitude: blockMag,
                              enrollNormalised: enrollMag,
                              enrollFrames: enrollFrames,
                              blockFrames: block,
                              into: &tfmap)

            // ---- spec_ri: (1, 3, bins, block) = [real, imag, tfmap]
            let ri = specRI.dataPointer.assumingMemoryBound(to: Float.self)
            for k in 0..<TSEConfig.bins {
                let rowOut = k * block
                for t in 0..<block {
                    let inside = t < count
                    let src = k * frames + start + t
                    ri[0 * TSEConfig.bins * block + rowOut + t] = inside ? spec.real[src] : 0
                    ri[1 * TSEConfig.bins * block + rowOut + t] = inside ? spec.imag[src] : 0
                    ri[2 * TSEConfig.bins * block + rowOut + t] = tfmap[rowOut + t]
                }
            }

            // ---- the four per-block models. Outputs are handed straight to the
            // next model, so nothing large is copied through Swift arrays.
            let features = try predict(frontend, ["spec_ri": specRI], output: "features")
            let conditioned = try predict(conditioning,
                                          ["features": features, "enroll_kv": kv],
                                          output: "conditioned")
            let separatorOut = try separator.prediction(
                from: MLDictionaryFeatureProvider(dictionary: [
                    "features": conditioned, "h_in": h, "c_in": c
                ]))
            guard let separated = separatorOut.featureValue(for: "separated")?.multiArrayValue,
                  let hOut = separatorOut.featureValue(for: "h_out")?.multiArrayValue,
                  let cOut = separatorOut.featureValue(for: "c_out")?.multiArrayValue else {
                throw ExtractorError.unexpectedIO("TargetSeparator outputs missing")
            }
            h = hOut; c = cOut       // carry (h, c) — the ONLY state in this model

            let maskOut = try masker.prediction(
                from: MLDictionaryFeatureProvider(dictionary: ["separated": separated]))
            guard let mr = maskOut.featureValue(for: "mask_real")?.multiArrayValue,
                  let mi = maskOut.featureValue(for: "mask_imag")?.multiArrayValue else {
                throw ExtractorError.unexpectedIO("TSEMasker outputs missing")
            }
            Self.read(mr, into: &maskReal)
            Self.read(mi, into: &maskImag)

            // ---- complex ratio mask: adjusts magnitude AND phase. A
            // magnitude-only mask cannot fix timing, which is why this is not
            // just a multiply of the magnitudes.
            for k in 0..<TSEConfig.bins {
                for t in 0..<count {
                    let src = k * frames + start + t
                    let m = k * block + t
                    let re = spec.real[src], im = spec.imag[src]
                    estReal[src] = re * maskReal[m] - im * maskImag[m]
                    estImag[src] = re * maskImag[m] + im * maskReal[m]
                }
            }
            start += block
        }

        let wave = stft.inverse(TSEComplexSpectrogram(real: estReal, imag: estImag, frames: frames))
        if wave.count == span.count { return wave }
        var out = [Float](repeating: 0, count: span.count)
        let n = min(wave.count, span.count)
        out.withUnsafeMutableBufferPointer { dst in
            wave.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress!, count: n)
            }
        }
        return out
    }

    private func predict(_ model: MLModel,
                         _ inputs: [String: MLMultiArray],
                         output: String) throws -> MLMultiArray {
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        guard let value = result.featureValue(for: output)?.multiArrayValue else {
            throw ExtractorError.unexpectedIO("missing output `\(output)`")
        }
        return value
    }

    // MARK: - tfmap

    /// Port of `TFMapFeature.compute`. Attention over enrollment frames in the
    /// magnitude domain, renormalised and rescaled to the mixture's per-frame
    /// energy. VERIFIED to match wesep exactly on this Mac.
    private static func computeTFMap(mixMagnitude: [Float],
                                     enrollNormalised: [Float],
                                     enrollFrames: Int,
                                     blockFrames: Int,
                                     into out: inout [Float]) {
        let bins = TSEConfig.bins
        var mixNorm = mixMagnitude
        normaliseColumns(&mixNorm, rows: bins, columns: blockFrames)

        // scores (blockFrames x enrollFrames) = mixNorm^T . enrollNorm
        var scores = [Float](repeating: 0, count: blockFrames * enrollFrames)
        cblas_sgemm(CblasRowMajor, CblasTrans, CblasNoTrans,
                    Int32(blockFrames), Int32(enrollFrames), Int32(bins),
                    1, mixNorm, Int32(blockFrames),
                    enrollNormalised, Int32(enrollFrames),
                    0, &scores, Int32(enrollFrames))

        for t in 0..<blockFrames {
            let row = t * enrollFrames
            var maximum = -Float.greatestFiniteMagnitude
            for e in 0..<enrollFrames { maximum = max(maximum, scores[row + e]) }
            var sum: Float = 0
            for e in 0..<enrollFrames {
                let v = exp(scores[row + e] - maximum)
                scores[row + e] = v
                sum += v
            }
            let inv = 1 / sum
            for e in 0..<enrollFrames { scores[row + e] *= inv }
        }

        // (blockFrames x bins) = scores . enrollNorm^T
        var transposed = [Float](repeating: 0, count: blockFrames * bins)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                    Int32(blockFrames), Int32(bins), Int32(enrollFrames),
                    1, scores, Int32(enrollFrames),
                    enrollNormalised, Int32(enrollFrames),
                    0, &transposed, Int32(bins))

        for t in 0..<blockFrames {
            for k in 0..<bins { out[k * blockFrames + t] = transposed[t * bins + k] }
        }
        // Renormalise, then recover the mixture's energy per frame.
        for t in 0..<blockFrames {
            var square: Float = 0
            for k in 0..<bins { let v = out[k * blockFrames + t]; square += v * v }
            let norm = square.squareRoot()
            guard norm > 0 else { continue }
            var gain: Float = 0
            for k in 0..<bins {
                out[k * blockFrames + t] /= norm
                gain += mixMagnitude[k * blockFrames + t] * out[k * blockFrames + t]
            }
            for k in 0..<bins { out[k * blockFrames + t] *= gain }
        }
    }

    /// F.normalize(x, p=2, dim=1) over a frequency-major matrix: each COLUMN is
    /// one frame. eps 1e-12 matches torch, and keeps all-zero pad frames at zero.
    private static func normaliseColumns(_ x: inout [Float], rows: Int, columns: Int) {
        for t in 0..<columns {
            var square: Float = 0
            for k in 0..<rows { let v = x[k * columns + t]; square += v * v }
            let norm = max(square.squareRoot(), 1e-12)
            for k in 0..<rows { x[k * columns + t] /= norm }
        }
    }

    // MARK: - MLMultiArray helpers

    private static func makeArray(_ shape: [Int]) throws -> MLMultiArray {
        try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: .float32)
    }

    private static func zero(_ a: MLMultiArray) {
        memset(a.dataPointer, 0, a.count * MemoryLayout<Float>.size)
    }

    private static func write(_ values: [Float], into a: MLMultiArray) {
        let p = a.dataPointer.assumingMemoryBound(to: Float.self)
        values.withUnsafeBufferPointer { src in
            p.update(from: src.baseAddress!, count: min(values.count, a.count))
        }
    }

    /// Core ML hands back fp16 buffers for models converted at FLOAT16
    /// precision, so never assume Float32 on an OUTPUT array.
    private static func read(_ a: MLMultiArray, into out: inout [Float]) {
        let n = min(a.count, out.count)
        guard a.strides.last?.intValue == 1 else {
            for i in 0..<n { out[i] = a[i].floatValue }
            return
        }
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.assumingMemoryBound(to: Float.self)
            out.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: p, count: n) }
        case .float16:
            var source = vImage_Buffer(data: a.dataPointer,
                                       height: 1, width: vImagePixelCount(n), rowBytes: n * 2)
            out.withUnsafeMutableBufferPointer { buffer in
                var destination = vImage_Buffer(data: buffer.baseAddress!,
                                                height: 1, width: vImagePixelCount(n),
                                                rowBytes: n * 4)
                _ = vImageConvert_Planar16FtoPlanarF(&source, &destination, 0)
            }
        default:
            for i in 0..<n { out[i] = a[i].floatValue }
        }
    }
}
