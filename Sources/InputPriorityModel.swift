import CoreAudio
import Foundation
import Observation

/// Backs the Settings "Preferred Inputs" list. Keeps the stored order merged
/// with currently-connected devices and updates connection state live via a
/// device-list HAL listener (so unplugging a device greys it immediately).
@MainActor
@Observable
final class InputPriorityModel {
    private(set) var entries: [InputEntry] = []
    private(set) var presentUIDs: Set<String> = []

    @ObservationIgnored private var deviceListener: AudioPropertyListener?

    init() {
        reload()
        deviceListener = AudioPropertyListener(
            objectID: AudioController.system,
            selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal
        ) { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        var stored = PreferredInput.order
        let present = AudioController.inputDevices().filter { !$0.uid.isEmpty }
        for device in present {
            if let index = stored.firstIndex(where: { $0.uid == device.uid }) {
                stored[index].name = device.name
            } else {
                stored.append(InputEntry(uid: device.uid, name: device.name))
            }
        }
        entries = stored
        presentUIDs = Set(present.map(\.uid))
        PreferredInput.order = stored
    }

    func move(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        PreferredInput.order = entries
    }

    func isConnected(_ entry: InputEntry) -> Bool {
        presentUIDs.contains(entry.uid)
    }
}
