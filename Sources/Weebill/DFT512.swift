// DFT512.swift — 512-point DFT wrapper with the exact scaling conventions
// required by algorithm.md.
//
// algorithm.md "Conventions": forward DFT of size N is
//     X[k] = Σ_{n=0}^{N−1} x[n]·e^(−j2πnk/N)      (no scaling)
// and the decoder's inverse real DFT convention is pinned down exactly in
// algorithm.md §7.5 step 3. vDSP's own scaling conventions differ from a
// plain mathematical DFT, so everything here is expressed in terms of the
// spec's formulas and verified by `DFTIdentityTests`.

import Accelerate

/// A reusable 512-point complex FFT, used for
///   * the LPC envelope / weighting responses (algorithm.md §7.2 step 1),
///   * the synthesis-filter phase samples (algorithm.md §7.3),
///   * the inverse real DFT of the harmonic spectrum (algorithm.md §7.5).
public final class DFT512 {
    /// Transform size, algorithm.md §7.2 / §7.5 (N_dft = 512).
    public static let n = 512
    private static let log2n = vDSP_Length(9)

    private let setup: FFTSetup

    /// Creates the transform, allocating a vDSP FFT setup that lives for the
    /// object's lifetime. Reuse one instance rather than creating per frame.
    public init() {
        guard let s = vDSP_create_fftsetup(DFT512.log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup(512) failed")
        }
        setup = s
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Forward DFT, algorithm.md conventions section:
    /// `X[k] = Σ x[n]·e^(−j2πnk/N)`, unscaled.
    ///
    /// `real`/`imag` are padded/truncated to 512 samples.
    public func forward(real: [Float], imag: [Float]? = nil) -> (re: [Float], im: [Float]) {
        var re = [Float](repeating: 0, count: DFT512.n)
        var im = [Float](repeating: 0, count: DFT512.n)
        for i in 0..<min(real.count, DFT512.n) { re[i] = real[i] }
        if let imag { for i in 0..<min(imag.count, DFT512.n) { im[i] = imag[i] } }

        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                // vDSP's "forward" complex FFT computes the e^(−j2πnk/N) sum
                // with no scaling — exactly the spec's convention.
                vDSP_fft_zip(setup, &split, 1, DFT512.log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        return (re, im)
    }

    /// Inverse **real** DFT, algorithm.md §7.5 step 3, computing exactly
    ///
    ///     s'[n] = Re( S[0] + S[256]·(−1)^n + 2·Σ_{k=1}^{255} S[k]·e^(j2πkn/512) )
    ///
    /// from a half spectrum `S[0...256]`. Implemented by completing the
    /// conjugate-symmetric full spectrum (`S[512−k] = conj(S[k])`) and taking
    /// an unscaled inverse complex FFT, which reproduces the formula term for
    /// term; `DFTIdentityTests` pins this down against the closed form.
    public func inverseReal(halfRe: [Float], halfIm: [Float]) -> [Float] {
        precondition(halfRe.count >= 257 && halfIm.count >= 257,
                     "half spectrum must cover S[0...256]")
        var re = [Float](repeating: 0, count: DFT512.n)
        var im = [Float](repeating: 0, count: DFT512.n)

        re[0] = halfRe[0]; im[0] = 0                 // S[0] contributes once
        re[256] = halfRe[256]; im[256] = 0           // S[256]·(−1)^n, once
        for k in 1...255 {
            re[k] = halfRe[k];  im[k] = halfIm[k]
            re[512 - k] = halfRe[k]; im[512 - k] = -halfIm[k]   // conjugate twin
        }

        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                // vDSP's "inverse" complex FFT computes Σ X[k]·e^(+j2πnk/N)
                // with no scaling.
                vDSP_fft_zip(setup, &split, 1, DFT512.log2n, FFTDirection(kFFTDirection_Inverse))
            }
        }
        return re
    }
}
