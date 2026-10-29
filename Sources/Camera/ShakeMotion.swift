import Foundation

/// How a shake moves the picture, frame by frame. It moves on the frames
/// call apps take, 30 a second: cameras send more and apps drop the rest, so
/// a move between two of those would be lost, or undone before it showed.
/// Each picks where the picture is from the frame alone (counted from when
/// it started), so nothing's kept between frames.
extension Effect.Shake.Motion {
    /// The frames a second it's laid out in: what call apps take.
    static let framesPerSecond = 30.0

    var label: String {
        switch self {
        case .vibrate: "Vibrate"
        case .rumble: "Rumble"
        case .wobble: "Wobble"
        }
    }

    /// What it does at `pace`, moves a second and all.
    func summary(pace: Double) -> String {
        switch self {
        case .vibrate: "Jumps to a new spot \(Self.rate(frames(pace: pace))) times a second."
        case .rumble: "Jitters on to a new spot \(Self.rate(frames(pace: pace))) times a second."
        case .wobble: "Sways and wanders, smoothly."
        }
    }

    /// The furthest it moves the picture each way at `amount` (0 gentle to
    /// 1 wild), as a share of it. A wobble's 1% to 7%; a rumble's a little
    /// under. Vibrate's 0.3% to 6% on a curve: fine steps while it's a
    /// buzz, a lot further at the wild end.
    func reach(_ amount: Double) -> Double {
        switch self {
        case .vibrate: 0.003 + 0.057 * amount * amount
        case .rumble: 0.6 * (0.01 + 0.06 * amount)
        case .wobble: 0.01 + 0.06 * amount
        }
    }

    /// The furthest it turns the picture each way, in radians, the same way:
    /// a wobble's 0.2° to 1.2°, vibrate's 0.06° to 1.3°.
    func tilt(_ amount: Double) -> Double {
        let degrees = switch self {
        case .vibrate: 0.06 + 1.24 * amount * amount
        case .rumble: 0.6 * (0.2 + amount)
        case .wobble: 0.2 + amount
        }
        return degrees * .pi / 180
    }

    /// Where it has the picture at `frame`, each -1 to 1: across, up and
    /// down, and turned. `pace` runs 0 (slow) to 1 (fast).
    func position(atFrame frame: Int, pace: Double) -> (x: Double, y: Double, turn: Double) {
        switch self {
        case .vibrate:
            // A new spot every few frames, held, each roughly opposite the
            // last, the way round drifting so it jumps every way.
            let step = Self.floor(frame, frames(pace: pace))
            let angle = Double(step) * (.pi + 0.9) + noise(step, 1) * 0.5
            let distance = 0.6 + 0.4 * abs(noise(step, 2))
            return (distance * cos(angle), distance * sin(angle), noise(step, 3) * 0.6)
        case .rumble:
            // Spots picked every few frames, straight lines between.
            let frames = frames(pace: pace)
            let step = Self.floor(frame, frames)
            let along = Double(frame - step * frames) / Double(frames)
            func between(_ channel: UInt64) -> Double { noise(step, channel) * (1 - along) + noise(step + 1, channel) * along }
            return (between(1), between(2), between(3))
        case .wobble:
            // A few jolts a second, wandering rather than repeating: three
            // waves each, at rates that never line up. At its fastest, the
            // quickest wave still takes a few frames each way.
            let seconds = Double(frame) / Self.framesPerSecond * (0.35 + 0.65 * pace)
            func wave(_ a: Double, _ b: Double, _ c: Double, _ phase: Double) -> Double {
                0.5 * sin(2 * .pi * a * seconds + phase) + 0.3 * sin(2 * .pi * b * seconds + phase + 1.3) + 0.2 * sin(2 * .pi * c * seconds + phase + 2.9)
            }
            return (wave(3.1, 5.9, 9.7, 0), wave(2.7, 6.7, 11.3, 0), wave(1.9, 4.3, 8.1, 0.7))
        }
    }

    /// Frames between new spots, at `pace`: Vibrate 6 down to every frame,
    /// Rumble 12 down to 2.
    private func frames(pace: Double) -> Int {
        let pace = min(max(pace, 0), 1)
        return switch self {
        case .vibrate: Int((6 - 5 * pace).rounded())
        case .rumble: Int((12 - 10 * pace).rounded())
        case .wobble: 1
        }
    }

    private static func rate(_ frames: Int) -> String {
        (framesPerSecond / Double(frames)).formatted(.number.precision(.fractionLength(0...1)))
    }

    /// Whole steps of `frames`, rounding down below zero too.
    private static func floor(_ frame: Int, _ frames: Int) -> Int {
        frame >= 0 ? frame / frames : -((-frame + frames - 1) / frames)
    }

    /// The same -1 to 1 for the same step and channel, scattered (SplitMix64).
    private func noise(_ step: Int, _ channel: UInt64) -> Double {
        var value = UInt64(bitPattern: Int64(step)) &* 0x9E37_79B9_7F4A_7C15 ^ channel &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) / Double(1 << 53) * 2 - 1
    }
}
