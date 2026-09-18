import CoreGraphics
import Foundation

/** The attack range indicator around the own champion, fitted as the perspective image of a ground circle of known radius: it gives px per unit and the champion's feet. */
struct RangeRing: Equatable {
    var centre: CGPoint
    var a: Double
    var b: Double
    var inliers: Int
    var candidates: Int
    var kx: Double
    var feet: CGPoint
    var atMs = 0.0
}

enum RangeRingDetector {
    static let rays = 72

    /** Ring pixels are a saturated cyan-to-white band 2–16 px wide with darker ground right behind it; up to four band crossings per ray from `origin`. */
    static func candidates(frame: Frame, origin: CGPoint, expectedA: Double) -> [CGPoint] {
        var points: [CGPoint] = []
        let tMin = max(20, Int(0.35 * expectedA)), tMax = max(tMin + 10, Int(1.7 * expectedA))
        for i in 0..<rays {
            let angle = 2 * Double.pi * Double(i) / Double(rays)
            let dx = cos(angle), dy = sin(angle)
            var inBand = false
            var bandStart = 0
            var found = 0
            for t in tMin...tMax {
                let x = Int((origin.x + dx * Double(t)).rounded()), y = Int((origin.y + dy * Double(t)).rounded())
                guard x >= 0, y >= 0, x < frame.width, y < frame.height else { break }
                let p = frame.base.load(fromByteOffset: y * frame.bytesPerRow + x * 4, as: UInt32.self)
                let white = ((p >> 8) & 0xFF) >= 225 && (p & 0xFF) >= 225
                if white && !inBand { bandStart = t }
                if !white && inBand {
                    let length = t - bandStart
                    let bx = Int((origin.x + dx * Double(t + 3)).rounded()), by = Int((origin.y + dy * Double(t + 3)).rounded())
                    if length >= 2, length <= 16, bx >= 0, by >= 0, bx < frame.width, by < frame.height {
                        let q = frame.base.load(fromByteOffset: by * frame.bytesPerRow + bx * 4, as: UInt32.self)
                        let luma = (Int((q >> 16) & 0xFF) * 299 + Int((q >> 8) & 0xFF) * 587 + Int(q & 0xFF) * 114) / 1000
                        if luma < 170 {
                            let mid = Double(bandStart + t) / 2
                            points.append(CGPoint(x: origin.x + dx * mid, y: origin.y + dy * mid))
                            found += 1
                            if found >= 4 { break }
                        }
                    }
                }
                inBand = white
            }
        }
        return points
    }

    /** Axis-aligned ellipse through the points by least squares on centred coordinates; nil when degenerate. */
    static func fitEllipse(_ points: [CGPoint]) -> (centre: CGPoint, a: Double, b: Double)? {
        guard points.count >= 4 else { return nil }
        let mx = points.reduce(0) { $0 + $1.x } / Double(points.count)
        let my = points.reduce(0) { $0 + $1.y } / Double(points.count)
        var m = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        var v = [Double](repeating: 0, count: 4)
        for p in points {
            let x = p.x - mx, y = p.y - my
            let row = [x * x, y * y, x, y]
            for i in 0..<4 {
                v[i] += row[i]
                for j in 0..<4 { m[i][j] += row[i] * row[j] }
            }
        }
        guard let s = solve(m, v), s[0] > 0, s[1] > 0 else { return nil }
        let ex = -s[2] / (2 * s[0]), ey = -s[3] / (2 * s[1])
        let k = 1 + s[0] * ex * ex + s[1] * ey * ey
        guard k > 0 else { return nil }
        return (CGPoint(x: ex + mx, y: ey + my), (k / s[0]).squareRoot(), (k / s[1]).squareRoot())
    }

    /** Gaussian elimination with partial pivoting. */
    private static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        var a = matrix, b = rhs
        let n = b.count
        for i in 0..<n {
            var pivot = i
            for r in i..<n where abs(a[r][i]) > abs(a[pivot][i]) { pivot = r }
            guard abs(a[pivot][i]) > 1e-12 else { return nil }
            a.swapAt(i, pivot)
            b.swapAt(i, pivot)
            for r in 0..<n where r != i {
                let f = a[r][i] / a[i][i]
                for col in i..<n { a[r][col] -= f * a[i][col] }
                b[r] -= f * b[i]
            }
        }
        return (0..<n).map { b[$0] / a[$0][$0] }
    }

    private static func normalizedRadius(_ p: CGPoint, _ fit: (centre: CGPoint, a: Double, b: Double)) -> Double {
        hypot((p.x - fit.centre.x) / fit.a, (p.y - fit.centre.y) / fit.b)
    }

    /** RANSAC over the candidates: the axis-aligned ellipse with the most points within 1.2 % of its radius, preferring the size expected for the attack ring over other indicators; the fit must cover most rays and have the axis ratio the camera pitch produces. */
    static func detect(frame: Frame, origin: CGPoint, expectedA: Double, ringUnits: Double, screenCentre: CGPoint, now: Double) -> RangeRing? {
        let points = candidates(frame: frame, origin: origin, expectedA: expectedA)
        guard points.count >= 16 else { return nil }
        var generator = SystemRandomNumberGenerator()
        var best: (inliers: [CGPoint], score: Double)?
        for _ in 0..<300 {
            var sample: [CGPoint] = []
            var used = Set<Int>()
            while sample.count < 6 {
                let index = Int.random(in: 0..<points.count, using: &generator)
                if used.insert(index).inserted { sample.append(points[index]) }
            }
            guard let fit = fitEllipse(sample), fit.a > 0.3 * expectedA, fit.a < 2.5 * expectedA, fit.b / fit.a > 0.6, fit.b / fit.a < 1.0 else { continue }
            let inliers = points.filter { abs(normalizedRadius($0, fit) - 1) < 0.012 }
            let score = Double(inliers.count) - 10 * abs(fit.a - expectedA) / expectedA
            if let current = best, score <= current.score { continue }
            best = (inliers, score)
        }
        guard let candidate = best, candidate.inliers.count >= 20, let fit = fitEllipse(candidate.inliers) else { return nil }
        let inliers = points.filter { abs(normalizedRadius($0, fit) - 1) < 0.012 }
        guard inliers.count * 5 >= rays * 3, fit.b / fit.a > 0.79, fit.b / fit.a < 0.85 else { return nil }
        return solve(centre: fit.centre, a: fit.a, b: fit.b, inliers: inliers.count, candidates: points.count, ringUnits: ringUnits, frameHeight: Double(frame.height), screenCentre: screenCentre, now: now)
    }

    /** From the horizontal semi-axis and the known radius: kx = a·√(q0² − γ²)/r with γ = c·r from the camera constant, and ζ (feet depth) from how far the ellipse centre sits below the projected circle centre. */
    static func solve(centre: CGPoint, a: Double, b: Double, inliers: Int, candidates: Int, ringUnits r: Double, frameHeight: Double, screenCentre: CGPoint, now: Double) -> RangeRing? {
        let s = GroundProjection.pitchSin
        let offset = centre.y - screenCentre.y
        var kx = a / r
        var gamma = 0.0
        var zeta = 0.0
        for _ in 0..<3 {
            gamma = kx * GroundProjection.perspectivePerScale / frameHeight * r
            for _ in 0..<6 {
                let q0 = 1 + gamma * zeta
                zeta = (-offset * (q0 * q0 - gamma * gamma) / (kx * r * s) + gamma) / q0
            }
            let q0 = 1 + gamma * zeta
            kx = a * (q0 * q0 - gamma * gamma).squareRoot() / r
        }
        guard kx > 0, abs(zeta) < 0.8 else { return nil }
        let feet = CGPoint(x: centre.x, y: screenCentre.y - kx * r * s * zeta / (1 + gamma * zeta))
        return RangeRing(centre: centre, a: a, b: b, inliers: inliers, candidates: candidates, kx: kx, feet: feet, atMs: now)
    }
}
