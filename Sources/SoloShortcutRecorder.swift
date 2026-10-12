import AppKit
import KeyboardShortcuts
import SwiftUI

/// Recorder for the solo shortcut: the stock KeyboardShortcuts recorder, which
/// also takes a lone tap of a right-side modifier (e.g. FluidVoice's right ⌥).
/// A key combo and a tap key are exclusive — recording one clears the other.
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
            // Binding mode: Hush stores the shortcut, so the field's text never
            // gets reset behind our back while it shows a tap key.
            let recorder = KeyboardShortcuts.RecorderCocoa(shortcut: KeyboardShortcuts.getShortcut(for: .toggleSolo)) { shortcut in
                // A combo was recorded or the field cleared: no tap key either way.
                KeyboardShortcuts.setShortcut(shortcut, for: .toggleSolo)
                ModifierTapMonitor.Key.current = .off
            }
            let key = ModifierTapMonitor.Key.current
            if key != .off {
                recorder.stringValue = key.symbol
                (recorder.cell as? NSSearchFieldCell)?.resetCancelButtonCell()
            }

            // Taps arrive from ModifierTapMonitor's event tap, which sees them
            // even when a dictation app swallows the key.
            let coordinator = context.coordinator
            coordinator.recorder = recorder
            coordinator.observers = [
                NotificationCenter.default.addObserver(
                    forName: ModifierTapMonitor.recordedTap, object: nil, queue: .main
                ) { note in
                    guard let key = note.object as? ModifierTapMonitor.Key else { return }
                    MainActor.assumeIsolated {
                        guard let recorder = coordinator.recorder, let editor = recorder.currentEditor(), recorder.window?.firstResponder === editor else { return }
                        Self.record(key, in: recorder)
                    }
                },
                // Taps can't be seen without Accessibility: ask when recording starts.
                NotificationCenter.default.addObserver(
                    forName: ModifierTapMonitor.recorderStatus, object: nil, queue: .main
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

        static func dismantleNSView(_ nsView: KeyboardShortcuts.RecorderCocoa, coordinator: Coordinator) {
            coordinator.observers.forEach(NotificationCenter.default.removeObserver)
        }

        private static func record(_ key: ModifierTapMonitor.Key, in recorder: KeyboardShortcuts.RecorderCocoa) {
            recorder.shortcut = nil
            KeyboardShortcuts.setShortcut(nil, for: .toggleSolo)
            ModifierTapMonitor.Key.current = key
            recorder.stringValue = key.symbol
            recorder.window?.makeFirstResponder(nil) // ends recording
        }
    }
}
