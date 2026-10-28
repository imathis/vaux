import Foundation

/// Something to turn on over your video, by name: overlays, a push-in, a
/// look, a shake, and other effects it builds on, any of them. Effects on together
/// stack, each over the ones before it (see `EffectLibrary`).
struct Effect: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// Effects it builds on, in order, under its own parts.
    var includes: [UUID] = []
    /// Each in its spot.
    var overlays: [Overlay] = []
    /// How far it pushes in, on top of each camera's own zoom.
    var pushIn: Double?
    var look: Look?
    var shake: Shake?
    /// Turns itself off after this many seconds; nil stays until turned off.
    var duration: Double?

    static let pushInRange = 1.1...2.0

    /// Nothing in it yet.
    var isEmpty: Bool { includes.isEmpty && overlays.isEmpty && pushIn == nil && look == nil && shake == nil }

    /// The picture jolting and tilting around, within the camera's frame:
    /// it pushes in just far enough to have room.
    struct Shake: Codable, Hashable, Sendable {
        /// 0 gentle to 1 wild.
        var amount = 0.5
        /// Smeared the way it's moving, as a camera would.
        var blur = true
        /// Overlays shake with the picture, rather than holding still over it.
        var overlays = false

        /// The furthest the picture moves each way, as a share of it.
        var reach: Double { 0.01 + 0.06 * amount }
        /// The furthest it turns each way, in radians: 0.2° to 1.2°.
        var tilt: Double { (0.2 + amount) * .pi / 180 }
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
        amount = try values.decodeIfPresent(Double.self, forKey: .amount) ?? amount
        blur = try values.decodeIfPresent(Bool.self, forKey: .blur) ?? blur
        overlays = try values.decodeIfPresent(Bool.self, forKey: .overlays) ?? overlays
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
        look = try values.decodeIfPresent(Look.self, forKey: .look)
        shake = try values.decodeIfPresent(Shake.self, forKey: .shake)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration)
    }
}

extension Look {
    /// Settings looks can set, one apart from another.
    static var amounts: [WritableKeyPath<Look, Double>] {
        [\.saturation, \.contrast, \.brightness, \.warmth, \.tint, \.highlights, \.shadows, \.blur, \.fade, \.vignette, \.grain]
    }

    static var grades: [WritableKeyPath<Look, Grade>] { [\.shadowGrade, \.midtoneGrade, \.highlightGrade] }

    /// The settings this look changes from plain, by name.
    var changes: Set<String> {
        let plain = Look(name: "")
        return Set(
            Self.amounts.filter { self[keyPath: $0] != plain[keyPath: $0] }.map { "\($0)" }
                + Self.grades.filter { self[keyPath: $0] != plain[keyPath: $0] }.map { "\($0)" }
        )
    }

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
