import Foundation

extension Effect {
    /// Effects Vaux comes with in no group, and offers ready-made in Add
    /// Effect: handy on a call, and a taste of what effects can do. New IDs
    /// each time.
    static var starters: [Effect] {
        let frosted = Look.presets.first { $0.preset == "frosted" }
        return [
            // Past recognizing, for when someone walks in behind you.
            Effect(name: "Privacy", look: frosted?.copy, mutesMic: true, icon: "eye.slash.fill", color: .indigo),
            // Seen in a small tile, where a call's own hand can be missed.
            Effect(
                name: "Hand Raised",
                overlays: [Overlay(lines: [Overlay.Line(text: "Hand raised", icon: "hand.raised.fill")], spot: .top)],
                icon: "hand.raised.fill",
                color: .yellow
            ),
            // The reaction shot: in close, captioned.
            Effect(name: "Suspicious", overlays: [Overlay(lines: [Overlay.Line(text: "Suspicious...")], spot: .bottom)], pushIn: 1.3, icon: "eyes", color: .purple),
            Effect(
                name: "Intensify",
                overlays: [Overlay(lines: [Overlay.Line(text: "[intensifies]")], style: .plain, size: .large, spot: .bottom)],
                pushIn: 1.5,
                pushInMove: Move(curve: .easeInOut, seconds: 0.2),
                shake: Shake(motion: .vibrate, amount: 0.75, pace: 1, builds: true),
                duration: 2.2,
                icon: "burst.fill",
                color: .red
            ),
            Effect(name: "Noir", look: Look.presets.first { $0.preset == "noir" }?.copy, icon: "moon.fill", color: .gray),
            Effect(name: "Teal & Orange", look: Look.presets.first { $0.preset == "tealAndOrange" }?.copy, icon: "camera.filters", color: .teal),
            Effect(name: "Dictating", overlays: [Overlay(lines: [Overlay.Line(text: "Dictating", icon: "waveform")], size: .large, spot: .bottom)], icon: "waveform", color: .green),
        ]
    }
}

extension EffectGroup {
    /// The group Vaux comes with, and offers ready-made: ways to step away,
    /// most muting the mic (not Paused, or On a call: you may be talking).
    /// BRB, frosted with a sign; the rest full-frame cards, which come with
    /// the app (see StarterGraphics). New IDs each time.
    static var away: (group: EffectGroup, effects: [Effect]) {
        let group = EffectGroup(name: "AWAY", icon: "clock.fill")
        // Frosted, but less: there behind the sign, not gone.
        var behind = Look.presets.first { $0.preset == "frosted" }?.copy
        behind?.blur = 0.54
        func card(_ name: String, _ file: String, mutes: Bool = true, icon: String? = nil, color: Effect.Tint? = nil) -> Effect {
            Effect(
                name: name,
                overlays: [Overlay(kind: .graphic, images: [StarterGraphics.name(of: file)], spot: .fullFrame)],
                mutesMic: mutes, icon: icon, color: color, group: group.id
            )
        }
        return (group, [
            Effect(
                name: "BRB",
                overlays: [Overlay(lines: [Overlay.Line(text: "Be right back", icon: "clock.fill")], size: .large, spot: .center)],
                look: behind,
                mutesMic: true,
                icon: "cup.and.saucer.fill",
                color: .orange,
                group: group.id
            ),
            card("Lunch", "away-lunch.jpg", icon: "🍽️"),
            card("Coffee", "away-coffee.jpg", icon: "cup.and.saucer.fill", color: .purple),
            card("Intermission", "away-intermission.jpg"),
            card("Paused", "away-paused.jpg", mutes: false),
            card("Poopin", "away-poopin.jpg", icon: "poop"),
            card("On a call", "away-on-a-call.jpg", mutes: false, icon: "phone.fill"),
        ])
    }
}

/// Graphics the starters show, in the app (StarterGraphics), copied into
/// the graphics folder as they're needed, as "starter-" and their name.
enum StarterGraphics {
    static let files = ["away-lunch.jpg", "away-coffee.jpg", "away-intermission.jpg", "away-paused.jpg", "away-poopin.jpg", "away-on-a-call.jpg"]

    static func name(of file: String) -> String { "starter-\(file)" }

    /// Into the graphics folder, any not there already.
    @MainActor
    static func install() {
        try? FileManager.default.createDirectory(at: EffectLibrary.graphicsFolder, withIntermediateDirectories: true)
        for file in files {
            let destination = EffectLibrary.graphicsFolder.appending(path: name(of: file))
            let name = (file as NSString).deletingPathExtension
            guard !FileManager.default.fileExists(atPath: destination.path),
                  let source = Bundle.main.url(forResource: name, withExtension: "jpg")
            else { continue }
            try? FileManager.default.copyItem(at: source, to: destination)
        }
    }
}
