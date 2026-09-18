import CoreGraphics
import Foundation

/** Perspective image of the ground at the game's fixed camera pitch (56.25° below the horizon): px per unit shrinks up the screen, so distances, dash points and the own feet are computed in game units through this model. */
struct GroundProjection: Equatable {
    static let pitchSin = sin(56.25 * Double.pi / 180)
    static let pitchCos = cos(56.25 * Double.pi / 180)
    static let pitchTan = tan(56.25 * Double.pi / 180)
    /** Screen px per unit of model height relative to kx: measured on Lucian, Sion, the dummy and minions (the pitch alone would give 0.556). */
    static let verticalPerScale = 0.72
    /** Points from a unit's bar fill top down to the top of its model: HUD layout, measured on three units. */
    static let barAboveHeadPt = 61.0
    static let gameplayRadius = 65.0
    /** c·frameHeight/kx: the camera distance is fixed, so the perspective per unit follows the scale (measured 2.95e-4 at 1.461 px/unit, 2338 px high). */
    static let perspectivePerScale = 0.472

    var frameWidth: Int
    var frameHeight: Int
    /** Frame px per game unit at the screen centre, horizontally. */
    var kx: Double
    /** Perspective per unit of depth: the scale at depth z (units up the screen from the centre) is kx / (1 + c·z). */
    var c: Double
    /** Own champion's feet in frame px. */
    var feet: CGPoint
    var feetFresh = false
    var feetFromCentre: CGPoint?
    /** Frame px from the own bar top to the feet. */
    var barToFeet: Double
    /** Frame px from a unit's bar fill top down to the top of its mesh (HUD layout, the same for every unit). */
    var barFrameOffset = 0.0
    var source = ""

    /** Centre-to-centre reach of a basic attack: edge range plus both gameplay radii. */
    static func reach(attackRange: Double) -> Double { attackRange + 2 * gameplayRadius }

    var centre: CGPoint { CGPoint(x: Double(frameWidth) / 2, y: Double(frameHeight) / 2) }

    /** Ground coordinates in units (x right, z up the screen) relative to the screen centre. */
    func ground(_ p: CGPoint) -> CGPoint {
        let w = centre.y - p.y
        let z = w / max(0.05 * kx * Self.pitchSin, kx * Self.pitchSin - c * w)
        return CGPoint(x: (p.x - centre.x) * (1 + c * z) / kx, y: z)
    }

    /** Frame point of ground coordinates relative to the screen centre. */
    func screen(_ g: CGPoint) -> CGPoint {
        let q = max(0.05, 1 + c * g.y)
        return CGPoint(x: centre.x + kx * g.x / q, y: centre.y - kx * Self.pitchSin * g.y / q)
    }

    func units(_ a: CGPoint, _ b: CGPoint) -> Double {
        let ga = ground(a), gb = ground(b)
        return hypot(ga.x - gb.x, ga.y - gb.y)
    }

    /** Frame point `unitX` units to the right and `unitZ` units up the screen from `p`. */
    func offset(_ p: CGPoint, unitX: Double, unitZ: Double) -> CGPoint {
        let g = ground(p)
        return screen(CGPoint(x: g.x + unitX, y: g.y + unitZ))
    }

    /** Local scale relative to the screen centre: 1 there, smaller up the screen, larger down. */
    func scale(at p: CGPoint) -> Double { 1 / max(0.05, 1 + c * ground(p).y) }

    /** Frame px a rise of `h` units above the ground point `p` spans on screen; the top is nearer the camera than the base. */
    func rise(_ h: Double, at p: CGPoint) -> Double {
        let z = ground(p).y
        return h * kx * Self.verticalPerScale / max(0.05, 1 + c * (z - h * Self.pitchTan / 2))
    }

    /** Feet of a unit from its bar top and its mesh height, iterated twice on the perspective at the feet. */
    func feet(barTop: CGPoint, meshHeight: Double) -> CGPoint {
        var result = CGPoint(x: barTop.x, y: barTop.y + barToFeet)
        for _ in 0..<2 { result.y = barTop.y + barFrameOffset + rise(meshHeight, at: result) }
        return result
    }
}
