// DFTIdentityTests.swift — algorithm.md §7.5 step 3.
//
// The brief's suggested first step for M2: "Verify your inverse-FFT wrapper
// against the identity in algorithm.md §7.5 step 3 before debugging anything
// downstream of it. vDSP scaling conventions differ from the spec's."

import XCTest
import Foundation
@testable import Weebill

final class DFTIdentityTests: XCTestCase {

    /// The closed form of algorithm.md §7.5 step 3, evaluated directly.
    private func referenceInverse(halfRe: [Float], halfIm: [Float]) -> [Double] {
        let n = 512
        var out = [Double](repeating: 0, count: n)
        for sample in 0..<n {
            var acc = Double(halfRe[0])
            acc += Double(halfRe[256]) * ((sample % 2 == 0) ? 1.0 : -1.0)
            var sum = 0.0
            for k in 1...255 {
                let theta = 2.0 * Double.pi * Double(k) * Double(sample) / Double(n)
                // Re(S[k]·e^(jθ)) = re·cos θ − im·sin θ
                sum += Double(halfRe[k]) * cos(theta) - Double(halfIm[k]) * sin(theta)
            }
            out[sample] = acc + 2.0 * sum
        }
        return out
    }

    /// Single test bin, exactly as algorithm.md §7.5 step 3 recommends:
    /// "each interior bin contributes 2·A_m·cos(2πbn/512 + φ_m)".
    func testSingleBinContributesTwoACosine() {
        let dft = DFT512()
        for (bin, amp, phase) in [(1, 1.0, 0.0),
                                  (7, 250.0, 0.7),
                                  (64, 3.5, -2.0),
                                  (128, 1000.0, Double.pi / 2),
                                  (255, 12.0, 3.0)] as [(Int, Double, Double)] {
            var re = [Float](repeating: 0, count: 257)
            var im = [Float](repeating: 0, count: 257)
            re[bin] = Float(amp * cos(phase))
            im[bin] = Float(amp * sin(phase))

            let got = dft.inverseReal(halfRe: re, halfIm: im)
            for sample in 0..<512 {
                let want = 2.0 * amp
                    * cos(2.0 * Double.pi * Double(bin) * Double(sample) / 512.0 + phase)
                XCTAssertEqual(Double(got[sample]), want,
                               accuracy: max(1e-3, abs(want) * 1e-4),
                               "bin \(bin), n = \(sample)")
            }
        }
    }

    /// DC (S[0]) and Nyquist (S[256]) contribute once, not twice
    /// (algorithm.md §7.5 step 3).
    func testDCAndNyquistContributeOnce() {
        let dft = DFT512()
        var re = [Float](repeating: 0, count: 257)
        let im = [Float](repeating: 0, count: 257)
        re[0] = 3.0
        re[256] = 5.0
        let got = dft.inverseReal(halfRe: re, halfIm: im)
        for sample in 0..<512 {
            let want = 3.0 + 5.0 * ((sample % 2 == 0) ? 1.0 : -1.0)
            XCTAssertEqual(Double(got[sample]), want, accuracy: 1e-4, "n = \(sample)")
        }
    }

    /// Full random half-spectrum against the closed form — catches any
    /// residual scaling factor, sign, or conjugation error.
    func testInverseMatchesClosedFormForRandomSpectrum() {
        let dft = DFT512()
        var rng = SystemRandomNumberGenerator()
        var re = [Float](repeating: 0, count: 257)
        var im = [Float](repeating: 0, count: 257)
        for k in 0...256 {
            re[k] = Float.random(in: -10...10, using: &rng)
            im[k] = (k == 0 || k == 256) ? 0 : Float.random(in: -10...10, using: &rng)
        }
        let got = dft.inverseReal(halfRe: re, halfIm: im)
        let want = referenceInverse(halfRe: re, halfIm: im)
        for sample in 0..<512 {
            XCTAssertEqual(Double(got[sample]), want[sample], accuracy: 1e-2, "n = \(sample)")
        }
    }

    /// Forward DFT convention (algorithm.md conventions section):
    /// `X[k] = Σ x[n]·e^(−j2πnk/N)`, unscaled.
    func testForwardIsUnscaledNegativeExponentDFT() {
        let dft = DFT512()
        // A pure real cosine at bin 10 must give X[10] = X[502] = N/2 · amp.
        var x = [Float](repeating: 0, count: 512)
        let amp: Double = 4.0
        for n in 0..<512 {
            x[n] = Float(amp * cos(2.0 * Double.pi * 10.0 * Double(n) / 512.0))
        }
        let (re, im) = dft.forward(real: x)
        XCTAssertEqual(Double(re[10]), amp * 256.0, accuracy: 0.05)
        XCTAssertEqual(Double(im[10]), 0.0, accuracy: 0.05)
        XCTAssertEqual(Double(re[502]), amp * 256.0, accuracy: 0.05)

        // An impulse must give a flat unit spectrum.
        var d = [Float](repeating: 0, count: 512)
        d[0] = 1
        let (dre, dim) = dft.forward(real: d)
        for k in 0..<512 {
            XCTAssertEqual(Double(dre[k]), 1.0, accuracy: 1e-5)
            XCTAssertEqual(Double(dim[k]), 0.0, accuracy: 1e-5)
        }

        // A shifted impulse gives e^(−j2πk/N): checks the exponent sign.
        var d1 = [Float](repeating: 0, count: 512)
        d1[1] = 1
        let (r1, i1) = dft.forward(real: d1)
        for k in [1, 5, 100, 300] {
            let theta = -2.0 * Double.pi * Double(k) / 512.0
            XCTAssertEqual(Double(r1[k]), cos(theta), accuracy: 1e-5)
            XCTAssertEqual(Double(i1[k]), sin(theta), accuracy: 1e-5, "sign of exponent, k=\(k)")
        }
    }
}
