import AppKit
import KeyboardShortcuts
import SwiftUI

/// Recorder for the solo shortcut: the stock KeyboardShortcuts recorder, which
/// also takes a key shared with dictation: the 🎤 Dictation key, or a lone tap
/// of a right-side modifier (e.g. FluidVoice's right ⌥). A key combo and a
/// shared key are exclusive — recording one clears the other.
struct SoloShortcutRecorder: View {
    let title: String

    var body: some View {
        LabeledContent {
            Field()
        } label: {
            Text(title)
        }
    }

    private struct Field: NSViewRepresentable {
        @MainActor
        final class Coordinator {
            weak var recorder: KeyboardShortcuts.RecorderCocoa?
            var observers: [NSObjectProtocol] = []
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> KeyboardShortcuts.RecorderCocoa {
            // Binding mode: Vaux stores the shortcut, so the field's text never
            // gets reset behind our back while it shows a shared key.
            let recorder = KeyboardShortcuts.RecorderCocoa(shortcut: KeyboardShortcuts.getShortcut(for: .toggleSolo)) { shortcut in
                // A combo was recorded or the field cleared: no shared key either way.
                KeyboardShortcuts.setShortcut(shortcut, for: .toggleSolo)
                SoloKeyMonitor.Key.current = .off
            }
            let key = SoloKeyMonitor.Key.current
            if key != .off {
                recorder.stringValue = key.symbol
                (recorder.cell as? NSSearchFieldCell)?.resetCancelButtonCell()
            }

            // Shared keys arrive from SoloKeyMonitor's event tap, which sees
            // them even when a dictation app swallows the key.
            let coordinator = context.coordinator
            coordinator.recorder = recorder
            coordinator.observers = [
                NotificationCenter.default.addObserver(
                    forName: SoloKeyMonitor.recordedTap, object: nil, queue: .main
                ) { note in
                    guard let key = note.object as? SoloKeyMonitor.Key else { return }
                    MainActor.assumeIsolated {
                        guard let recorder = coordinator.recorder, let editor = recorder.currentEditor(), recorder.window?.firstResponder === editor else { return }
                        Self.record(key, in: recorder)
                    }
                },
                // Shared keys can't be seen without Accessibility: ask when recording starts.
                NotificationCenter.default.addObserver(
                    forName: SoloKeyMonitor.recorderStatus, object: nil, queue: .main
                ) { note in
                    guard note.userInfo?["isActive"] as? Bool == true else { return }
                    MainActor.assumeIsolated {
                        if coordinator.recorder?.currentEditor() != nil, !CallMuter.isTrusted { CallMuter.requestTrust() }
                    }
                },
            ]
            return recorder
        }

        func updateNSView(_ nsView: KeyboardShortcuts.RecorderCocoa, context: Context) {}

        /// A touch wider than the stock 130pt: the text area mirrors the cancel
        /// button's inset on both sides, leaving 74pt, and "Dictation Key" needs 80.
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: KeyboardShortcuts.RecorderCocoa, context: Context) -> CGSize? {
            CGSize(width: 150, height: nsView.intrinsicContentSize.height)
        }

        static func dismantleNSView(_ nsView: KeyboardShortcuts.RecorderCocoa, coordinator: Coordinator) {
            coordinator.observers.forEach(NotificationCenter.default.removeObserver)
        }

        private static func record(_ key: SoloKeyMonitor.Key, in recorder: KeyboardShortcuts.RecorderCocoa) {
            recorder.shortcut = nil
            KeyboardShortcuts.setShortcut(nil, for: .toggleSolo)
            SoloKeyMonitor.Key.current = key
            recorder.stringValue = key.symbol
            recorder.window?.makeFirstResponder(nil) // ends recording
        }
    }
}
