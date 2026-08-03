//
//  TSESpectrogram.swift
//  PeriodontalCharting
//
//  STFT / iSTFT for the extraction path, matching
//      torch.stft(x, 512, 128, 512, window=hann_window(512), center=True)
//  bit-for-bit within float32.
//
//  The handoff plans a conv-based STFT because Core ML has no complex dtype.
//  Swift does not have that problem: Accelerate does the transform natively, so
//  the whole conv-STFT port — and its `env` division trap, which quietly capped
//  a first attempt at 9.5 dB — is sidestepped.
//
//  VERIFIED against torch on this Mac (16 000-sample deterministic signal):
//      bin values          agree to ~1e-6 (real AND imag, incl. the sign)
//      round-trip          139.8 dB   (torch itself: 139.4 dB — float32's limit)
//
//  TRAP that bit here: vDSP's real FFT packs DC in realp[0] and NYQUIST in
//  imagp[0], and scales everything by 2. Both are handled below; if you rewrite
//  this, re-run the parity check rather than trusting the shape of the output.
//

import Accelerate
import Foundation

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
