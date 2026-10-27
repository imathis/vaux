import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Observation
import os

/// A color look over the whole picture: white balance, tone, saturation, a
/// three-way color grade, and texture, set together. One is on at a time;
/// switching fades from one to the next.
struct Look: Codable, Identifiable, Hashable, Sendable {
    /// One range's grade: tinted toward a hue, by how much, and brighter or
    /// darker.
    struct Grade: Codable, Hashable, Sendable {
        /// Degrees around the color wheel.
        var hue = 0.0
        /// How strongly the range is tinted toward the hue, 0 to 1.
        var saturation = 0.0
        /// Brighter (above 0) or darker, -1 to 1.
        var luminance = 0.0

        var isNeutral: Bool { saturation == 0 && luminance == 0 }
    }

    var id = UUID()
    var name: String
    /// The preset it started as, which Reset goes back to; none for a look
    /// made from scratch, which resets to plain.
    var preset: String?
    /// 0 is black and white, 1 as the camera sees it, 2 doubled.
    var saturation = 1.0
    var contrast = 1.0
    var brightness = 0.0
    /// White balance: toward amber (above 0) or blue (below).
    var warmth = 0.0
    /// White balance: toward magenta (above 0) or green (below).
    var tint = 0.0
    /// The bright and dark parts raised (above 0) or pulled down, each
    /// apart from the rest.
    var highlights = 0.0
    var shadows = 0.0
    /// The three-way color grade.
    var shadowGrade = Grade()
    var midtoneGrade = Grade()
    var highlightGrade = Grade()
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
    /// Tint, highlights, shadows, and a grade's luminance.
    static let signedRange = -1.0...1.0
    static let amountRange = 0.0...1.0
    static let hueRange = 0.0...360.0

    /// The looks a first run starts with, and Add Look offers again.
    static let presets = [
        // Silvery black and white: cool, with smoke in the shadows.
        Look(name: "Noir", preset: "noir", saturation: 0, contrast: 1.25, brightness: 0.02, warmth: -0.15, fade: 0.45, vignette: 0.45, grain: 0.3),
        Look(name: "Black & White", preset: "blackAndWhite", saturation: 0, contrast: 1.1),
        Look(name: "Warm", preset: "warm", saturation: 1.1, warmth: 0.5),
        Look(name: "Vivid", preset: "vivid", saturation: 1.45, contrast: 1.1),
        Look(name: "Faded", preset: "faded", saturation: 0.75, contrast: 0.85, fade: 0.4),
        // The film grade: teal in the shadows, warm in the highlights.
        Look(
            name: "Teal & Orange", preset: "tealAndOrange", contrast: 1.1,
            shadowGrade: Grade(hue: 195, saturation: 0.55, luminance: -0.05),
            highlightGrade: Grade(hue: 32, saturation: 0.45, luminance: 0.03)
        ),
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

extension Look {
    /// Settings a look was saved without (added since) take their defaults.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try values.decode(String.self, forKey: .name))
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? id
        preset = try values.decodeIfPresent(String.self, forKey: .preset)
        saturation = try values.decodeIfPresent(Double.self, forKey: .saturation) ?? saturation
        contrast = try values.decodeIfPresent(Double.self, forKey: .contrast) ?? contrast
        brightness = try values.decodeIfPresent(Double.self, forKey: .brightness) ?? brightness
        warmth = try values.decodeIfPresent(Double.self, forKey: .warmth) ?? warmth
        tint = try values.decodeIfPresent(Double.self, forKey: .tint) ?? tint
        highlights = try values.decodeIfPresent(Double.self, forKey: .highlights) ?? highlights
        shadows = try values.decodeIfPresent(Double.self, forKey: .shadows) ?? shadows
        shadowGrade = try values.decodeIfPresent(Grade.self, forKey: .shadowGrade) ?? shadowGrade
        midtoneGrade = try values.decodeIfPresent(Grade.self, forKey: .midtoneGrade) ?? midtoneGrade
        highlightGrade = try values.decodeIfPresent(Grade.self, forKey: .highlightGrade) ?? highlightGrade
        fade = try values.decodeIfPresent(Double.self, forKey: .fade) ?? fade
        vignette = try values.decodeIfPresent(Double.self, forKey: .vignette) ?? vignette
        grain = try values.decodeIfPresent(Double.self, forKey: .grain) ?? grain
    }
}

/// The user's looks, and which one is on: the default, unless another is
/// turned on over it (or it's turned off for now). Stored in UserDefaults.
@MainActor @Observable
final class LookLibrary {
    var looks: [Look] {
        didSet {
            save()
            if let defaultLook, look(defaultLook) == nil { self.defaultLook = nil }
            if case .look(let id) = override, look(id) == nil { override = nil }
            if let liveLook, look(liveLook) == nil { self.liveLook = nil }
        }
    }

    /// On whenever no other look is: under everything else, kept between
    /// launches. Choosing one puts it on now, over whatever was turned on.
    var defaultLook: UUID? {
        didSet {
            UserDefaults.standard.set(defaultLook?.uuidString, forKey: Self.defaultKey)
            if defaultLook != oldValue, override != nil { set(nil) }
        }
    }

    /// What's been turned on or off over the default, for now.
    enum Override: Equatable {
        case look(UUID)
        /// The default, turned off.
        case off
    }

    private(set) var override: Override?

    /// The look on.
    var active: UUID? {
        switch override {
        case .look(let id): id
        case .off: nil
        case nil: defaultLook
        }
    }

    /// The Live effect's look, applied while Live is on.
    var liveLook: UUID? {
        didSet {
            UserDefaults.standard.set(liveLook?.uuidString, forKey: Self.liveKey)
            // Changed while Live is on: the camera follows.
            if liveApplied {
                if let liveLook { set(.look(liveLook)) } else { set(beforeLive) }
                liveApplied = liveLook != nil
            }
        }
    }
    /// Live put its look on, and it's still the one on.
    private(set) var liveApplied = false
    /// What was on before Live's look, to go back to.
    @ObservationIgnored private var beforeLive: Override?

    private static let key = "looks"
    private static let defaultKey = "defaultLook"
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
        defaultLook = UserDefaults.standard.string(forKey: Self.defaultKey).flatMap(UUID.init)
        liveLook = UserDefaults.standard.string(forKey: Self.liveKey).flatMap(UUID.init)
        if stored == nil { save() }
    }

    func look(_ id: UUID) -> Look? { looks.first { $0.id == id } }

    var activeLook: Look? { active.flatMap(look) }

    func toggle(_ id: UUID) {
        if active == id { turnOff() } else { turnOn(id) }
    }

    /// Turns a look on over the default (or the default back on).
    func turnOn(_ id: UUID) {
        set(id == defaultLook ? nil : .look(id))
    }

    /// Turns off the look that's on: back to the default, or, if the
    /// default was on, no look for now.
    func turnOff() {
        switch override {
        case .look: set(nil)
        case nil where defaultLook != nil: set(.off)
        default: break
        }
    }

    /// What's on over the default, to put back after a held key.
    var state: Override? { override }

    func restore(_ state: Override?) {
        set(state)
    }

    private func set(_ override: Override?) {
        if self.override != override { self.override = override }
        liveApplied = false
    }

    /// The Live effect on (its look, in place of any other) or off: back
    /// to what was on before.
    func applyLive(_ on: Bool) {
        if on, let liveLook {
            let before = override
            set(.look(liveLook))
            beforeLive = before
            liveApplied = true
        } else if !on, liveApplied {
            set(beforeLive)
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

    /// A copy beside it, to make another version of it.
    @discardableResult
    func duplicate(_ id: UUID) -> Look? {
        guard let index = looks.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = looks[index]
        copy.id = UUID()
        copy.name += " Copy"
        looks.insert(copy, at: index + 1)
        return copy
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
        // Tint, highlights and shadows, and the grade: one lookup, made
        // when they change, not per frame.
        let grading = Grading(look: self)
        if !grading.isNeutral {
            out = out.applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": Grading.size,
                "inputCubeData": grading.cube,
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

/// The part of a look done by lookup: tint, highlights and shadows, and the
/// three-way grade. Its cube is made once per setting and kept, since
/// sliders change it far less often than frames come.
private struct Grading: Hashable {
    let tint: Double
    let highlights: Double
    let shadows: Double
    let grades: [Look.Grade]

    init(look: Look) {
        tint = look.tint
        highlights = look.highlights
        shadows = look.shadows
        grades = [look.shadowGrade, look.midtoneGrade, look.highlightGrade]
    }

    var isNeutral: Bool { tint == 0 && highlights == 0 && shadows == 0 && grades.allSatisfy(\.isNeutral) }

    static let size = 33
    private static let made = OSAllocatedUnfairLock<[Grading: Data]>(initialState: [:])

    var cube: Data {
        if let cube = Self.made.withLock({ $0[self] }) { return cube }
        let cube = make()
        Self.made.withLock { made in
            // A slider's drag makes many; only the latest few matter.
            if made.count > 8 { made.removeAll() }
            made[self] = cube
        }
        return cube
    }

    /// Red fastest, then green, then blue, as CIColorCube reads it.
    private func make() -> Data {
        let size = Self.size
        var values = [Float](repeating: 0, count: size * size * size * 4)
        let tints = grades.map { grade in Self.direction(hue: grade.hue) }
        var index = 0
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    var rgb = SIMD3(Double(red), Double(green), Double(blue)) / Double(size - 1)
                    let luma = Self.luma(rgb)
                    // White balance's tint: green down for magenta.
                    rgb *= SIMD3(1 + 0.04 * tint, 1 - 0.1 * tint, 1 + 0.04 * tint)
                    // Highlights and shadows, each on its own part.
                    let lift = 0.15 * (shadows * Self.bell(luma, at: 0.22) + highlights * Self.bell(luma, at: 0.78))
                    rgb += SIMD3(repeating: lift)
                    // The grade: shadows, midtones and highlights, blending
                    // into each other.
                    let shadow = 1 - Self.smoothstep(0, 0.6, luma)
                    let highlight = Self.smoothstep(0.4, 1, luma)
                    let weights = [shadow, max(0, 1 - shadow - highlight), highlight]
                    for (range, grade) in grades.enumerated() where !grade.isNeutral {
                        rgb += weights[range] * (0.3 * grade.saturation * tints[range] + SIMD3(repeating: 0.2 * grade.luminance))
                    }
                    let clamped = rgb.clamped(lowerBound: .zero, upperBound: .one)
                    values[index] = Float(clamped.x)
                    values[index + 1] = Float(clamped.y)
                    values[index + 2] = Float(clamped.z)
                    values[index + 3] = 1
                    index += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func luma(_ rgb: SIMD3<Double>) -> Double {
        0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
    }

    /// A hue's push away from gray: its full color less its own brightness,
    /// so tinting shifts color, not light.
    private static func direction(hue: Double) -> SIMD3<Double> {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        let color: SIMD3<Double> = switch Int(h) {
        case 0: SIMD3(1, x, 0)
        case 1: SIMD3(x, 1, 0)
        case 2: SIMD3(0, 1, x)
        case 3: SIMD3(0, x, 1)
        case 4: SIMD3(x, 0, 1)
        default: SIMD3(1, 0, x)
        }
        return color - SIMD3(repeating: luma(color))
    }

    private static func bell(_ value: Double, at center: Double) -> Double {
        exp(-pow((value - center) / 0.2, 2))
    }

    private static func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let t = min(max((value - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
