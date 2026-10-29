import Foundation

/// Something to turn on over your video, by name: overlays, a push-in, a
/// look, a shake, and other effects it builds on, any of them. One is on at
/// a time, over the default effect (see `EffectLibrary`).
struct Effect: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// Effects it builds on, in order, under its own parts.
    var includes: [UUID] = []
    /// Each in its spot.
    var overlays: [Overlay] = []
    /// How far it pushes in, on top of each camera's own zoom.
    var pushIn: Double?
    /// How it pushes in, and back out when it goes.
    var pushInMove = Move()
    var look: Look?
    var shake: Shake?
    /// Turns itself off after this many seconds; nil stays until turned off.
    var duration: Double?
    /// Mutes the mic while it's on (see Effects.followMuting).
    var mutesMic = false
    /// On its keys and in lists: an SF Symbol or an emoji. None picks one
    /// from what's in it (see EffectIcon.swift).
    var icon: String?
    /// None takes one by its place in the list.
    var color: Tint?
    /// The group it's listed in, if any (see EffectLibrary.ordered).
    var group: UUID?

    static let pushInRange = 1.1...2.0

    /// A push in or out: at once, or eased over a time.
    struct Move: Codable, Hashable, Sendable {
        enum Curve: String, Codable, CaseIterable, Sendable {
            case snap, easeIn, easeOut, easeInOut
        }

        var curve = Curve.easeInOut
        var seconds = 0.3
    }

    /// Nothing in it yet.
    var isEmpty: Bool { includes.isEmpty && overlays.isEmpty && pushIn == nil && look == nil && shake == nil }

    /// The picture jolting and tilting around, within the camera's frame:
    /// it pushes in just far enough to have room.
    struct Shake: Codable, Hashable, Sendable {
        /// How it moves (see ShakeMotion.swift).
        enum Motion: String, Codable, CaseIterable, Sendable {
            case vibrate, rumble, wobble
        }

        var motion = Motion.vibrate
        /// 0 gentle to 1 wild.
        var amount = 0.5
        /// How fast it moves, 0 slow to 1 fast, in its motion's own steps
        /// (see ShakeMotion.swift).
        var pace = 0.5
        /// For an effect that turns itself off: grows from a quarter to full
        /// three quarters of the way through its time, rather than easing
        /// straight in (see EffectLibrary.shakeBuild).
        var builds = false
        /// Smeared the way it's moving, as a camera would.
        var blur = true
        /// Overlays shake with the picture, rather than holding still over it.
        var overlays = false

        /// The furthest the picture moves each way, as a share of it.
        var reach: Double { motion.reach(amount) }
        /// The furthest it turns each way, in radians.
        var tilt: Double { motion.tilt(amount) }
        /// The zoom that leaves room for both, all around, in a 16:9 frame
        /// (all Vaux Camera sends): turning swings its corners up and down
        /// most.
        var zoom: Double { 1 + 2 * reach + 16.0 / 9 * sin(tilt) }
    }
}

extension Effect.Shake {
    /// Settings added since a shake was saved take their defaults.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        // Saved before there was a choice: the wobble it was made with. One
        // since taken out: the default.
        if let motion = try values.decodeIfPresent(String.self, forKey: .motion) {
            self.motion = Motion(rawValue: motion) ?? self.motion
        } else {
            motion = .wobble
        }
        amount = try values.decodeIfPresent(Double.self, forKey: .amount) ?? amount
        pace = try values.decodeIfPresent(Double.self, forKey: .pace) ?? pace
        builds = try values.decodeIfPresent(Bool.self, forKey: .builds) ?? builds
        blur = try values.decodeIfPresent(Bool.self, forKey: .blur) ?? blur
        overlays = try values.decodeIfPresent(Bool.self, forKey: .overlays) ?? overlays
    }
}

extension Effect.Move {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        curve = try values.decodeIfPresent(Curve.self, forKey: .curve) ?? curve
        seconds = try values.decodeIfPresent(Double.self, forKey: .seconds) ?? seconds
    }
}

extension Effect.Move.Curve {
    var label: String {
        switch self {
        case .snap: "Snap"
        case .easeIn: "Ease In"
        case .easeOut: "Ease Out"
        case .easeInOut: "Ease In and Out"
        }
    }

    var summary: String {
        switch self {
        case .snap: "Jumps there at once."
        case .easeIn: "Starts slow and speeds up, landing hard."
        case .easeOut: "Starts fast and slows down to settle."
        case .easeInOut: "Starts slow, speeds up, and settles."
        }
    }

    /// How far along a move is at `t`, 0 to 1 of its time: cubic, so each
    /// curve reads apart from the others.
    func eased(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return switch self {
        case .snap: 1
        case .easeIn: t * t * t
        case .easeOut: 1 - pow(1 - t, 3)
        case .easeInOut: t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        }
    }
}

extension Effect {
    /// Parts added since an effect was saved take their defaults.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try values.decode(String.self, forKey: .name))
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? id
        includes = try values.decodeIfPresent([UUID].self, forKey: .includes) ?? []
        overlays = try values.decodeIfPresent([Overlay].self, forKey: .overlays) ?? []
        pushIn = try values.decodeIfPresent(Double.self, forKey: .pushIn)
        pushInMove = try values.decodeIfPresent(Move.self, forKey: .pushInMove) ?? pushInMove
        look = try values.decodeIfPresent(Look.self, forKey: .look)
        shake = try values.decodeIfPresent(Shake.self, forKey: .shake)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration)
        mutesMic = try values.decodeIfPresent(Bool.self, forKey: .mutesMic) ?? mutesMic
        icon = try values.decodeIfPresent(String.self, forKey: .icon)
        color = try values.decodeIfPresent(Tint.self, forKey: .color)
        group = try values.decodeIfPresent(UUID.self, forKey: .group)
    }
}

extension Look {
    /// Settings looks can set, one apart from another.
    static var amounts: [WritableKeyPath<Look, Double>] {
        [\.saturation, \.contrast, \.brightness, \.warmth, \.tint, \.highlights, \.shadows, \.blur, \.fade, \.vignette, \.grain]
    }

    static var grades: [WritableKeyPath<Look, Grade>] { [\.shadowGrade, \.midtoneGrade, \.highlightGrade] }

    /// Looks on together, as one: each setting from the last that changes
    /// it, so black and white from one and grain from another both show.
    static func merged(_ looks: [Look], id: UUID) -> Look? {
        guard !looks.isEmpty else { return nil }
        let plain = Look(name: "")
        var merged = plain
        for look in looks {
            for amount in amounts where look[keyPath: amount] != plain[keyPath: amount] { merged[keyPath: amount] = look[keyPath: amount] }
            for grade in grades where look[keyPath: grade] != plain[keyPath: grade] { merged[keyPath: grade] = look[keyPath: grade] }
        }
        merged.id = id
        return merged
    }
}

/// Effects kept together under a name: listed together, a section in the
/// Quick Menu and the menu, and a key on Stream Deck that opens them.
struct EffectGroup: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// An SF Symbol or emoji; none shows a folder.
    var icon: String?
    /// None takes one by its place among the groups.
    var color: Effect.Tint?

    var shownIcon: String { icon ?? "folder.fill" }
}
