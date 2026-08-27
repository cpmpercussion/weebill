// LPC.swift — order-10 linear prediction analysis and LPC→LSP conversion.
// algorithm.md §6.

import Foundation

/// Order-10 linear prediction analysis and LPC→LSP conversion
/// (algorithm.md §6). A namespace of stateless operations.
public enum LPC {

    /// Autocorrelation `R[j] = Σ_i x[i]·x[i+j]`, j = 0…order.
    /// algorithm.md §6 step 1, over the windowed buffer.
    public static func autocorrelation(_ x: [Double], order: Int) -> [Double] {
        var r = [Double](repeating: 0, count: order + 1)
        for j in 0...order {
            var acc = 0.0
            for i in 0..<(x.count - j) { acc += x[i] * x[i + j] }
            r[j] = acc
        }
        return r
    }

    /// Levinson–Durbin recursion (Makhoul eqs. 38a–d), algorithm.md §6 step 2.
    /// Returns `a[0...order]` with a₀ = 1.
    ///
    /// Carries a running prediction-error energy `e`, initialised to R[0]. At
    /// stage i = 1…order, with a^(i) the order-i coefficient set:
    ///
    ///     k_i     = −( R[i] + Σ_{j=1}^{i−1} a^(i−1)_j · R[i−j] ) / e
    ///     a^(i)_i = k_i
    ///     a^(i)_j = a^(i−1)_j + k_i · a^(i−1)_{i−j},   j = 1…i−1
    ///     e       ← e · (1 − k_i²)
    ///
    /// **Reflection-coefficient clamp**: if |k_i| > 1, substitute k_i = 0 for
    /// that stage, which makes the stage a no-op — coefficients and `e` pass
    /// through unchanged and a_i ends up exactly 0.
    ///
    /// Per §6 step 2 this clamp is *not* a rare guard: on rank-deficient input
    /// it is the normal outcome for the top stages and effectively lowers the
    /// model order. A steady sinusoid is a rank-2 process, so `e` collapses
    /// towards the single-precision epsilon of R[0] and the upper stages clamp.
    /// From that point the recursion is decided by rounding rather than by the
    /// signal, and such frames are outside the reproducible envelope of the
    /// specification (algorithm.md §9, qa-log.md Q7) — this is expected, not an
    /// error path, and must not be "fixed" by conditioning R.
    public static func levinsonDurbin(_ r: [Double], order: Int) -> [Double] {
        var a = [Double](repeating: 0, count: order + 1)
        a[0] = 1.0

        var e = r[0]
        for i in 1...order {
            var acc = r[i]
            for j in 1..<i { acc += a[j] * r[i - j] }
            var k = -acc / e
            // The clamp is written as a range test rather than `|k| > 1` so
            // that a degenerate stage (e collapsed to 0, giving ±inf or NaN)
            // also becomes the specified no-op instead of propagating.
            if !(abs(k) <= 1.0) { k = 0.0 }

            var next = a
            next[i] = k
            if i > 1 {
                for j in 1..<i { next[j] = a[j] + k * a[i - j] }
            }
            a = next
            e *= (1.0 - k * k)
        }
        return a
    }

    /// Bandwidth expansion `a_i ← a_i · 0.994^i` (≈15 Hz).
    /// algorithm.md §6 step 4 — applied *after* the energy of step 3.
    public static func bandwidthExpand(_ a: [Double], factor: Double = 0.994) -> [Double] {
        var out = a
        var g = 1.0
        for i in 0..<out.count {
            out[i] *= g
            g *= factor
        }
        return out
    }

    /// Residual energy `E = Σ_{i=0}^{10} a_i·R[i]`, algorithm.md §6 step 3,
    /// computed *before* bandwidth expansion.
    public static func residualEnergy(a: [Double], r: [Double]) -> Double {
        var acc = 0.0
        for i in 0..<a.count { acc += a[i] * r[i] }
        return acc
    }

    // MARK: - LPC -> LSP (algorithm.md §6 step 5)

    /// Fallback LSPs used when LPC analysis is skipped or the root finder
    /// fails: `lsp[i] = i·π/10` (algorithm.md §6 steps 1 and 5).
    public static let fallbackLSP: [Double] =
        (0..<Codec2Constants.lpcOrder).map { Double($0) * Double.pi / 10.0 }

    /// Converts `a[0...10]` to 10 LSP angles (radians, ascending).
    ///
    /// algorithm.md §6 step 5. P'(z) = P(z)/(1+z^−1) and Q'(z) = Q(z)/(1−z^−1)
    /// are degree-10 and symmetric, so six coefficients each suffice; on the
    /// unit circle both reduce to Chebyshev sums in x = cos ω whose ten roots
    /// in (−1, 1) are the LSPs, strictly interlacing between p and q.
    ///
    /// The search is **not** a single monotone descending lattice. Each
    /// polynomial gets its own scan, re-anchored at the previously found
    /// root, with `x_lower` persisting across the whole search. That is what
    /// makes a 0.01 step sufficient: adjacent LSPs are roots of *different*
    /// polynomials, so two of them may lie arbitrarily close together — even
    /// inside one 0.01 cell — without either being missed. The step size only
    /// has to beat the spacing of successive roots *within* p or within q,
    /// i.e. the gap between LSP i and LSP i+2.
    ///
    /// "If the search yields fewer than 10 roots, discard them all and
    /// substitute lsp[i] = i·π/10."
    public static func toLSP(_ a: [Double]) -> [Double] {
        let order = Codec2Constants.lpcOrder      // 10
        precondition(a.count == order + 1)

        // algorithm.md §6 step 5:
        //   p₀ = q₀ = 1
        //   p_k = (a_k + a_{11−k}) − p_{k−1},  k = 1..5
        //   q_k = (a_k − a_{11−k}) + q_{k−1},  k = 1..5
        var p = [Double](repeating: 0, count: 6)
        var q = [Double](repeating: 0, count: 6)
        p[0] = 1.0
        q[0] = 1.0
        for k in 1...5 {
            let sum = a[k] + a[order + 1 - k]
            let difference = a[k] - a[order + 1 - k]
            p[k] = sum - p[k - 1]
            q[k] = difference + q[k - 1]
        }

        // algorithm.md §6 step 5:
        //   p(x) = p₅ + 2·Σ_{k=1}^{5} p_{5−k}·T_k(x)
        // Note the asymmetry: every coefficient is doubled *except* the one
        // multiplying T₀.
        func chebyshev(_ c: [Double], _ x: Double) -> Double {
            var tPrev = 1.0          // T₀
            var t = x                // T₁
            var sum = c[5] + 2.0 * c[4] * t
            for k in 2...5 {
                let next = 2.0 * x * t - tPrev
                tPrev = t
                t = next
                sum += 2.0 * c[5 - k] * t
            }
            return sum
        }

        var roots = [Double]()
        // x_upper is the scan position, x_lower the probe position. Both
        // persist across the whole search; x_lower is never reset between
        // polynomials.
        var xUpper = 1.0
        var xLower = 0.0

        for j in 0..<order {
            let c = (j % 2 == 0) ? p : q          // p for even j, q for odd j
            var fUpper = chebyshev(c, xUpper)
            var found = false

            // The guard tests the probe position left over from the previous
            // pass (or the previous j), so the last interval examined can
            // reach as low as x = −1.01.
            while xLower >= -1.0 {
                xLower = xUpper - 0.01
                var fLower = chebyshev(c, xLower)

                if fUpper * fLower < 0 || fLower == 0 {
                    // Exactly 6 bisection steps over [x_lower, x_upper].
                    var xMid = 0.0
                    for _ in 0...5 {
                        xMid = 0.5 * (xUpper + xLower)
                        let fMid = chebyshev(c, xMid)
                        // Strictly greater: an exact zero takes the other branch.
                        if fMid * fUpper > 0 {
                            xUpper = xMid
                            fUpper = fMid
                        } else {
                            xLower = xMid
                            fLower = fMid
                        }
                    }
                    // The root is the last x_mid evaluated, not the midpoint
                    // of the surviving bracket.
                    roots.append(xMid)
                    // Re-anchor: the next polynomial's scan starts from the
                    // root just found; x_lower is left unchanged.
                    xUpper = xMid
                    found = true
                    break
                } else {
                    xUpper = xLower
                    fUpper = fLower
                }
            }

            // Once a scan has run off the bottom of the range, this j and
            // every later j find nothing.
            if !found { break }
        }

        guard roots.count == order else { return fallbackLSP }

        // The x_i were found descending, so the angles come out ascending.
        return roots.map { acos(max(-1.0, min(1.0, $0))) }
    }
}
