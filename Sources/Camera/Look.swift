import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Observation

/// A color look over the whole picture: saturation, contrast and the like,
/// set together. One is on at a time; switching fades from one to the next.
struct Look: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// The preset it started as, which Reset goes back to; none for a look
    /// made from scratch, which resets to plain.
    var preset: String?
    /// 0 is black and white, 1 as the camera sees it, 2 doubled.
    var saturation = 1.0
    var contrast = 1.0
    var brightness = 0.0
    /// Toward amber (above 0) or blue (below).
    var warmth = 0.0
    /// Smoke: blacks lifted toward gray and a soft glow.
    var fade = 0.0
    /// Darkened edges.
    var vignette = 0.0
    /// Film grain, moving frame to frame.
    var grain = 0.0

    static let saturationRange = 0.0...2.0
    static let contrastRange = 0.6...1.6
    static let brightnessRange = -0.25...0.25
    static let warmthRange = -1.0...1.0
    static let amountRange = 0.0...1.0

    /// The looks a first run starts with, and Add Look offers again.
    static let presets = [
        // Silvery black and white: cool, with smoke in the shadows.
        Look(name: "Noir", preset: "noir", saturation: 0, contrast: 1.25, brightness: 0.02, warmth: -0.15, fade: 0.45, vignette: 0.45, grain: 0.3),
        Look(name: "Black & White", preset: "blackAndWhite", saturation: 0, contrast: 1.1),
        Look(name: "Warm", preset: "warm", saturation: 1.1, warmth: 0.5),
        Look(name: "Vivid", preset: "vivid", saturation: 1.45, contrast: 1.1),
        Look(name: "Faded", preset: "faded", saturation: 0.75, contrast: 0.85, fade: 0.4),
    ]

    /// What Reset goes back to: its preset's settings, or plain, keeping its
    /// own name and identity.
    var defaults: Look {
        var reset = Self.presets.first { $0.preset == preset } ?? Look(name: name)
        reset.id = id
        reset.name = name
        reset.preset = preset
        return reset
    }

    var isDefault: Bool { self == defaults }
}

/// The user's looks, and which one is on. Stored in UserDefaults.
@MainActor @Observable
final class LookLibrary {
    var looks: [Look] {
        didSet {
            save()
            if let active, look(active) == nil { self.active = nil }
            if let liveLook, look(liveLook) == nil { self.liveLook = nil }
        }
    }

    /// The look on, if any.
    private(set) var active: UUID?
    /// The Live effect's look, applied while Live is on.
    var liveLook: UUID? {
        didSet {
            UserDefaults.standard.set(liveLook?.uuidString, forKey: Self.liveKey)
            // Changed while Live is on: the camera follows.
            if liveApplied {
                active = liveLook
                liveApplied = liveLook != nil
            }
        }
    }
    /// Live put its look on, and it's still the one on.
    private(set) var liveApplied = false

    private static let key = "looks"
    private static let liveKey = "liveLook"

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Look].self, from: $0) }
        // Saved before looks knew their preset: matched by name.
        looks = stored?.map { look in
            guard look.preset == nil, let preset = Look.presets.first(where: { $0.name == look.name }) else { return look }
            var matched = look
            matched.preset = preset.preset
            return matched
        } ?? Look.presets
        liveLook = UserDefaults.standard.string(forKey: Self.liveKey).flatMap(UUID.init)
        if stored == nil { save() }
    }

    func look(_ id: UUID) -> Look? { looks.first { $0.id == id } }

    var activeLook: Look? { active.flatMap(look) }

    func toggle(_ id: UUID) {
        activate(active == id ? nil : id)
    }

    /// Turns a look on, the one that was on off; nil turns it off.
    func activate(_ id: UUID?) {
        if active != id { active = id }
        liveApplied = false
    }

    /// The Live effect on (its look, in place of any other) or off.
    func applyLive(_ on: Bool) {
        if on, let liveLook {
            activate(liveLook)
            liveApplied = true
        } else if !on, liveApplied {
            activate(nil)
        }
    }

    /// A new plain look, or a fresh copy of a preset (named apart from one
    /// already in the list).
    @discardableResult
    func add(_ preset: Look? = nil) -> Look {
        var look = preset ?? Look(name: "New Look")
        look.id = UUID()
        let names = Set(looks.map(\.name))
        if names.contains(look.name) {
            let base = look.name
            look.name = (2...).lazy.map { "\(base) \($0)" }.first { !names.contains($0) }!
        }
        looks.append(look)
        return look
    }

    func duplicate(_ id: UUID) {
        guard var copy = look(id) else { return }
        copy.id = UUID()
        copy.name += " Copy"
        looks.append(copy)
    }

    func remove(_ id: UUID) {
        looks.removeAll { $0.id == id }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(looks), forKey: Self.key)
    }
}

extension Look {
    /// The look over `image`, a whole frame. `frame` moves the grain, so it
    /// shimmers like film rather than sitting on the picture. Values pass
    /// through as the camera encoded them (no color management; see
    /// Compositor), as a video grade would treat them.
    func apply(to image: CIImage, frame: Int) -> CIImage {
        let extent = image.extent
        var out = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: saturation,
            kCIInputContrastKey: contrast,
            kCIInputBrightnessKey: brightness,
        ])
        if warmth != 0 {
            out = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 + 0.12 * warmth, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 + 0.02 * warmth, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - 0.12 * warmth, w: 0),
            ])
        }
        if fade > 0 {
            // Blacks lifted toward gray and whites eased down, so nothing
            // crushes or clips, then a glow off the highlights.
            let lift = 0.2 * fade
            let gain = 1 - 1.6 * lift
            out = out
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                    "inputBiasVector": CIVector(x: lift, y: lift, z: lift, w: 0),
                ])
                .applyingFilter("CIBloom", parameters: [
                    kCIInputRadiusKey: extent.height / 72,
                    kCIInputIntensityKey: 0.5 * fade,
                ])
                .cropped(to: extent)
        }
        if vignette > 0 {
            out = out.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputRadiusKey: max(extent.width, extent.height) * 0.55,
                kCIInputIntensityKey: vignette,
                "inputFalloff": 0.6,
            ])
        }
        if grain > 0 {
            // Gray noise around middle gray, overlaid on the picture: no
            // change at middle gray, grain either side. Coarser as it gets
            // stronger, as film's does, sized to the frame, and moved each
            // frame.
            let strength = 0.6 * grain
            let scale = extent.height / 720 * (1 + grain)
            let tile = CIFilter.affineTile()
            tile.inputImage = Self.noise
            tile.transform = CGAffineTransform(scaleX: scale, y: scale)
            let side = CGFloat(Self.noiseSize) * scale
            let grainImage = (tile.outputImage ?? Self.noise)
                .transformed(by: CGAffineTransform(
                    translationX: (CGFloat(frame * 97) * scale).truncatingRemainder(dividingBy: side),
                    y: (CGFloat(frame * 61) * scale).truncatingRemainder(dividingBy: side)
                ))
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: strength, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: strength, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0.5 - strength / 2, y: 0.5 - strength / 2, z: 0.5 - strength / 2, w: 1),
                ])
                .cropped(to: extent)
            out = grainImage.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: out])
        }
        return out.cropped(to: extent)
    }

    private static let noiseSize = 256

    /// Gray noise, made once and tiled: generating it each frame took
    /// several milliseconds.
    private static let noise: CIImage = {
        var bytes = [UInt8](repeating: 0, count: noiseSize * noiseSize)
        for index in bytes.indices { bytes[index] = .random(in: 0...255) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: noiseSize, height: noiseSize, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: noiseSize,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { return CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)) }
        return CIImage(cgImage: image)
    }()
}
