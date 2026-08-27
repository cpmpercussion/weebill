// LSP.swift — line spectral pairs to LPC coefficients.
// algorithm.md §7.1.

import Foundation

/// Line spectral pair to LPC coefficient conversion, the decoder-side
/// inverse of `LPC.toLSP` (algorithm.md §7.1).
public enum LSP {

    /// Reconstructs `a[0...10]` (with a₀ = 1) from 10 LSP angles in radians,
    /// ascending. algorithm.md §7.1:
    ///
    ///   "Reconstruct a₀..a₁₀ from the LSPs by cascading the second-order
    ///    sections (1 − 2·cos(ω_k)z^−1 + z^−2) to rebuild P(z) and Q(z) and
    ///    averaging: A(z) = [P(z)·(1+z^−1) + Q(z)·(1−z^−1)]/2."
    ///
    /// The split between P and Q follows the interlacing established by the
    /// analysis grid search (algorithm.md §6 step 5), which alternates P'/Q'
    /// starting from x = 1.0 downward — so ascending LSPs alternate
    /// P, Q, P, Q, …, i.e. even indices belong to P and odd indices to Q.
    public static func toLPC(_ lsp: [Double]) -> [Double] {
        precondition(lsp.count == Codec2Constants.lpcOrder,
                     "expected \(Codec2Constants.lpcOrder) LSPs")

        // P(z) and Q(z): five second-order sections each -> degree 10.
        var p: [Double] = [1.0]
        var q: [Double] = [1.0]
        for k in stride(from: 0, to: 10, by: 2) {
            p = convolve(p, [1.0, -2.0 * cos(lsp[k]), 1.0])
        }
        for k in stride(from: 1, to: 10, by: 2) {
            q = convolve(q, [1.0, -2.0 * cos(lsp[k]), 1.0])
        }

        // A(z) = [P(z)(1 + z^-1) + Q(z)(1 - z^-1)] / 2.
        // The z^-11 terms cancel exactly, leaving a degree-10 A(z).
        var a = [Double](repeating: 0, count: 12)
        for i in 0..<p.count {
            a[i] += p[i]
            a[i + 1] += p[i]
            a[i] += q[i]
            a[i + 1] -= q[i]
        }
        for i in 0..<12 { a[i] *= 0.5 }
        return Array(a[0...10])
    }

    /// Polynomial multiplication (z^-1 coefficient convention).
    static func convolve(_ x: [Double], _ y: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: x.count + y.count - 1)
        for i in 0..<x.count {
            for j in 0..<y.count {
                out[i + j] += x[i] * y[j]
            }
        }
        return out
    }
}
