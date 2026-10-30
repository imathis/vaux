import AppKit
import AVFoundation
import Observation
import SwiftUI

/// Effects tried out where the call can't see them. While Preview is open,
/// the effects you turn on (in Settings, the menu, the Quick Menu, keys,
/// Stream Deck) show in it instead, over your camera as the call would see
/// it (not mirrored); the call keeps what it had, edits and all, until it
/// closes. A window of Vaux's own, like Settings (see AppWindows).
@MainActor @Observable
final class EffectsPreview: NSObject, NSWindowDelegate {
    /// The camera's, once it's running (see CameraSide).
    var feeder: Feeder? {
        didSet { feeder?.screen = screen }
    }

    @ObservationIgnored private let library: EffectLibrary
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var screen: PreviewScreen?

    private static let frameName = "Preview"

    init(library: EffectLibrary) {
        self.library = library
        super.init()
    }

    func show() {
        if window == nil {
            library.openPreview()
            let screen = PreviewScreen()
            self.screen = screen
            feeder?.screen = screen
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: true
            )
            window.title = "Preview"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PreviewView(preview: self, library: library, screen: screen))
            window.setContentSize(NSSize(width: 640, height: 360 + PreviewView.footerHeight))
            window.contentMinSize = NSSize(width: 320, height: 180 + PreviewView.footerHeight)
            window.delegate = self
            // Where it was last; the first time, the top right of the screen
            // you're on, beside Settings.
            if !window.setFrameUsingName(Self.frameName) {
                let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
                if let area = screen?.visibleFrame {
                    window.setFrameTopLeftPoint(NSPoint(x: area.maxX - window.frame.width - 20, y: area.maxY - 20))
                }
            }
            window.setFrameAutosaveName(Self.frameName)
            self.window = window
        }
        guard let window else { return }
        AppWindows.opened(window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens it with this effect on.
    func show(_ id: UUID) {
        show()
        if !library.isOn(id), let token = library.turnOn(id) { library.settle(token) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        feeder?.screen = nil
        screen = nil
        self.window = nil
        library.closePreview()
        AppWindows.closed(window)
    }
}

/// The camera with the preview's effects, or why it isn't showing; under
/// it, a reminder of where effects go, and Clear.
struct PreviewView: View {
    let preview: EffectsPreview
    let library: EffectLibrary
    let screen: PreviewScreen

    static let footerHeight: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                ScreenView(screen: screen)
                if let problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding()
                }
            }
            HStack(spacing: 8) {
                Text("Effects you turn on show here, not on your camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button("Clear All") { library.clearAll() }
                    .controlSize(.small)
                    .disabled(!library.anythingOn)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.footerHeight)
        }
    }

    /// Why there's no picture, if there isn't.
    private var problem: String? {
        guard let feeder = preview.feeder else { return "Vaux Camera is still setting up." }
        if feeder.previewing != nil { return nil }
        return switch feeder.status {
        case .noCamera: "No camera connected."
        case .notReady: "Vaux needs camera access. Allow it in Settings → Camera."
        default: "Starting…"
        }
    }
}

/// The screen's layer, filling the view.
private struct ScreenView: NSViewRepresentable {
    let screen: PreviewScreen

    func makeNSView(context: Context) -> NSView { Host(layer: screen.layer) }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class Host: NSView {
        private let shown: CALayer

        init(layer: CALayer) {
            shown = layer
            super.init(frame: .zero)
            wantsLayer = true
            self.layer?.addSublayer(layer)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shown.frame = bounds
            CATransaction.commit()
        }
    }
}

/// Where the preview's frames go (see CameraFeed): shown as they come,
/// in their own color, fitted to the window.
final class PreviewScreen: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    private let renderer: AVSampleBufferVideoRenderer

    @MainActor
    init() {
        layer.videoGravity = .resizeAspect
        renderer = layer.sampleBufferRenderer
    }

    /// On the camera's queue.
    func show(_ frame: CVPixelBuffer, at time: CMTime) {
        do {
            let sample = try CMSampleBuffer(
                imageBuffer: frame,
                formatDescription: CMVideoFormatDescription(imageBuffer: frame),
                sampleTiming: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
            )
            // No clock to wait for: on screen now.
            sample.sampleAttachments[0][.displayImmediately] = true
            if renderer.requiresFlushToResumeDecoding { renderer.flush() }
            renderer.enqueue(sample)
        } catch {}
    }
}
