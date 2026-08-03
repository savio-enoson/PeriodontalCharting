//
//  TSEFeatures.swift
//  PeriodontalCharting
//
//  The two signal-processing primitives the extraction layer needs. Both are pure
//  Accelerate with no app dependencies, and both were verified against their
//  Python reference on this Mac before being ported:
//
//    TSESpectrogram  STFT / iSTFT matching torch.stft(512, 128, hann, center=True).
//                    Bin values agree to ~1e-6 including the imaginary sign;
//                    round-trip 139.8 dB against torch's own 139.4 dB — float32's
//                    limit.
//
//    TSEKaldiFbank   80-bin log-mel matching torchaudio.compliance.kaldi.fbank
//                    with wesep's exact arguments. Agrees to ~1e-5.
//
//  The handoff plans a conv-based STFT because Core ML has no complex dtype.
//  Swift does not have that problem — Accelerate does the transform natively, so
//  the conv-STFT port and its `env` division trap (which quietly capped a first
//  attempt at 9.5 dB) are sidestepped entirely.
//
//  THREE TRAPS, all silent if you get them wrong:
//    * vDSP's real FFT packs DC in realp[0] and NYQUIST in imagp[0], and scales
//      everything by 2.
//    * the fbank waveform is scaled by 32768 BEFORE framing — Kaldi works in
//      16-bit units and its epsilon and energy floor are absolute.
//    * fbank frames run at a 10 ms hop, the STFT at 8 ms. Mixing the two rates is
//      the easy mistake: 38.8 s is 3,876 fbank frames, not 4,848.
//
//  If you rewrite either of these, re-run the parity check rather than trusting
//  the shape of the output.
//

import Accelerate
import Foundation

// MARK: - Spectrogram

/// A complex spectrogram stored as two frequency-major planes: element (k, t)
/// lives at `k * frames + t`. That layout is what the BLAS calls in the tfmap
/// want, so it is used everywhere in this layer.
struct TSEComplexSpectrogram {
    var real: [Float]
    var imag: [Float]
    let frames: Int
}

final class TSESpectrogram {

    private let window: [Float]
    private let setup: FFTSetup
    private let log2n: vDSP_Length = 9   // 2^9 = 512

    init() {
        let n = TSEConfig.nFFT
        var w = [Float](repeating: 0, count: n)
        // Periodic Hann — torch's default. NOT the symmetric one.
        for i in 0..<n {
            w[i] = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(n))
        }
        window = w
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    static func frameCount(samples: Int) -> Int { 1 + samples / TSEConfig.hop }

    /// Reflect padding by nFFT/2 at both ends — torch's `center=True` with the
    /// default `pad_mode='reflect'`.
    private func centerPad(_ x: [Float]) -> [Float] {
        let p = TSEConfig.nFFT / 2
        var out = [Float](repeating: 0, count: x.count + 2 * p)
        for i in 0..<p { out[i] = x[p - i] }
        for i in 0..<x.count { out[p + i] = x[i] }
        for j in 0..<p { out[p + x.count + j] = x[x.count - 2 - j] }
        return out
    }

    func forward(_ x: [Float]) -> TSEComplexSpectrogram {
        let n = TSEConfig.nFFT
        let half = n / 2
        let padded = centerPad(x)
        let frames = Self.frameCount(samples: x.count)

        var real = [Float](repeating: 0, count: TSEConfig.bins * frames)
        var imag = [Float](repeating: 0, count: TSEConfig.bins * frames)
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: n)

        for t in 0..<frames {
            let off = t * TSEConfig.hop
            padded.withUnsafeBufferPointer { src in
                vDSP_vmul(src.baseAddress! + off, 1, window, 1, &frame, 1, vDSP_Length(n))
            }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
            real[0 * frames + t] = re[0] * 0.5           // DC
            real[half * frames + t] = im[0] * 0.5        // Nyquist, packed in imagp[0]
            for k in 1..<half {
                real[k * frames + t] = re[k] * 0.5
                imag[k * frames + t] = im[k] * 0.5
            }
        }
        return TSEComplexSpectrogram(real: real, imag: imag, frames: frames)
    }

    /// Overlap-add inverse, dividing by the summed squared window. Returns
    /// `hop * (frames - 1)` samples, which is exactly what torch.istft returns
    /// for a centred transform with `length=None`.
    func inverse(_ spec: TSEComplexSpectrogram) -> [Float] {
        let n = TSEConfig.nFFT
        let half = n / 2
        let frames = spec.frames
        let padLen = TSEConfig.hop * (frames - 1) + n

        var acc = [Float](repeating: 0, count: padLen)
        var env = [Float](repeating: 0, count: padLen)
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: n)
        var scale = Float(1.0 / Double(n))

        for t in 0..<frames {
            re[0] = spec.real[0 * frames + t]
            im[0] = spec.real[half * frames + t]
            for k in 1..<half {
                re[k] = spec.real[k * frames + t]
                im[k] = spec.imag[k * frames + t]
            }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                    frame.withUnsafeMutableBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ztoc(&split, 1, cp, 2, vDSP_Length(half))
                        }
                    }
                }
            }
            vDSP_vsmul(frame, 1, &scale, &frame, 1, vDSP_Length(n))
            let off = t * TSEConfig.hop
            for i in 0..<n {
                acc[off + i] += frame[i] * window[i]
                env[off + i] += window[i] * window[i]
            }
        }

        let p = n / 2
        let outLen = TSEConfig.hop * (frames - 1)
        var out = [Float](repeating: 0, count: outLen)
        for i in 0..<outLen {
            let e = env[p + i]
            out[i] = e > 1e-11 ? acc[p + i] / e : 0
        }
        return out
    }

    /// Per-frame magnitude, same frequency-major layout. Used for the tfmap.
    static func magnitude(_ spec: TSEComplexSpectrogram) -> [Float] {
        var mag = [Float](repeating: 0, count: spec.real.count)
        for i in 0..<mag.count {
            mag[i] = (spec.real[i] * spec.real[i] + spec.imag[i] * spec.imag[i]).squareRoot()
        }
        return mag
    }
}

// MARK: - Kaldi filterbank

/// 80-bin Kaldi filterbank for the WeSpeaker ECAPA frame encoder that conditions
/// the extractor. Mirrors `torchaudio.compliance.kaldi.fbank` with the exact
/// arguments wesep uses (`Fbank_kaldi` in wesep/modules/speaker/encoder.py):
///
///     num_mel_bins 80 | frame_length 25 ms | frame_shift 10 ms
///     dither 0.0      | window "hamming"   | use_energy False
///     then CMVN: subtract the per-coefficient mean over time (norm_var False)
final class TSEKaldiFbank {

    static let numMel = 80
    static let windowSize = 400        // 25 ms @ 16 kHz
    static let windowShift = 160       // 10 ms
    static let paddedSize = 512        // round_to_power_of_two
    /// torch.finfo(torch.float32).eps — the floor Kaldi's log uses.
    static let epsilon: Float = 1.1920928955078125e-07

    private let window: [Float]
    private let melBanks: [Float]      // numMel x (paddedSize/2 + 1), row-major
    private let setup: FFTSetup
    private let log2n: vDSP_Length = 9

    init() {
        var w = [Float](repeating: 0, count: Self.windowSize)
        // torch.hamming_window(N, periodic=False, alpha=0.54, beta=0.46)
        for i in 0..<Self.windowSize {
            w[i] = 0.54 - 0.46 * cos(2 * Float.pi * Float(i) / Float(Self.windowSize - 1))
        }
        window = w
        melBanks = Self.makeMelBanks()
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    static func frameCount(samples: Int) -> Int {
        samples < windowSize ? 0 : 1 + (samples - windowSize) / windowShift
    }

    private static func melScale(_ f: Float) -> Float { 1127.0 * log(1.0 + f / 700.0) }

    /// Kaldi's triangular mel banks over the first `paddedSize/2` FFT bins; the
    /// Nyquist bin is left at zero, exactly as `get_mel_banks` + its right-pad.
    private static func makeMelBanks() -> [Float] {
        let numFFTBins = paddedSize / 2                      // 256
        let sampleRate = Float(TSEConfig.sampleRate)
        let lowFreq: Float = 20.0                            // kaldi default
        let highFreq: Float = 0.5 * sampleRate               // high_freq <= 0 -> += nyquist
        let binWidth = sampleRate / Float(paddedSize)
        let melLow = melScale(lowFreq)
        let melHigh = melScale(highFreq)
        let melDelta = (melHigh - melLow) / Float(numMel + 1)

        var banks = [Float](repeating: 0, count: numMel * (numFFTBins + 1))
        for m in 0..<numMel {
            let left = melLow + Float(m) * melDelta
            let center = melLow + Float(m + 1) * melDelta
            let right = melLow + Float(m + 2) * melDelta
            for k in 0..<numFFTBins {
                let mel = melScale(binWidth * Float(k))
                let up = (mel - left) / (center - left)
                let down = (right - mel) / (right - center)
                banks[m * (numFFTBins + 1) + k] = max(0, min(up, down))
            }
        }
        return banks
    }

    /// - Parameter waveform: mono 16 kHz in [-1, 1].
    /// - Returns: `(frames * 80)` row-major log-mel with CMVN applied, and the
    ///   frame count. Empty when the input is shorter than one window.
    func compute(_ waveform: [Float]) -> (features: [Float], frames: Int) {
        let frames = Self.frameCount(samples: waveform.count)
        guard frames > 0 else { return ([], 0) }

        var x = waveform
        var gain: Float = 32768.0
        vDSP_vsmul(x, 1, &gain, &x, 1, vDSP_Length(x.count))

        let half = Self.paddedSize / 2
        var out = [Float](repeating: 0, count: frames * Self.numMel)
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: Self.paddedSize)
        var power = [Float](repeating: 0, count: half + 1)

        for t in 0..<frames {
            let off = t * Self.windowShift
            for i in 0..<Self.windowSize { frame[i] = x[off + i] }
            for i in Self.windowSize..<Self.paddedSize { frame[i] = 0 }

            // remove_dc_offset, over the 400 real samples only
            var mean: Float = 0
            vDSP_meanv(frame, 1, &mean, vDSP_Length(Self.windowSize))
            for i in 0..<Self.windowSize { frame[i] -= mean }

            // preemphasis 0.97 with replicate padding: x[-1] == x[0]
            var previous = frame[0]
            for i in 0..<Self.windowSize {
                let current = frame[i]
                frame[i] = current - 0.97 * previous
                previous = current
            }
            for i in 0..<Self.windowSize { frame[i] *= window[i] }

            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
            power[0] = (re[0] * 0.5) * (re[0] * 0.5)
            power[half] = (im[0] * 0.5) * (im[0] * 0.5)
            for k in 1..<half {
                let r = re[k] * 0.5, i = im[k] * 0.5
                power[k] = r * r + i * i
            }

            melBanks.withUnsafeBufferPointer { banks in
                for m in 0..<Self.numMel {
                    var acc: Float = 0
                    vDSP_dotpr(banks.baseAddress! + m * (half + 1), 1,
                               power, 1, &acc, vDSP_Length(half + 1))
                    out[t * Self.numMel + m] = log(max(acc, Self.epsilon))
                }
            }
        }

        // CMVN — norm_mean only, per utterance. This is where the encoder's
        // gain invariance comes from, so do not "optimise" it away.
        for m in 0..<Self.numMel {
            var sum: Float = 0
            for t in 0..<frames { sum += out[t * Self.numMel + m] }
            let mu = sum / Float(frames)
            for t in 0..<frames { out[t * Self.numMel + m] -= mu }
        }
        return (out, frames)
    }
}
