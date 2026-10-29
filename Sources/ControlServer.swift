import Foundation
import Observation
import os

/// Lets your other apps drive Vaux: Vaux's Stream Deck plugin presses and
/// lets go of Vaux's keys here (Mute; with the camera on, Live, each effect
/// but the dictation one, and Clear All), and hears what's on, to light its
/// keys. A Unix socket in Vaux's Application Support folder, open to you
/// alone: the file is yours only, and each connection's user is checked.
///
/// One JSON message a line, each way. Vaux sends what there is, on
/// connecting and whenever it changes:
/// `{"version": 1, "items": [{"id", "title", "kind", "on", "image", "group"}, …]}`,
/// kind being mute, live, effect, group or clearAll; an effect's or group's
/// image is its key, `{"off", "on"}`, PNG data URLs; an effect in a group
/// names it, by its item ID. A client sends `{"press": id}` and
/// `{"release": id}` as its key goes down and up, so a hold works as it does
/// on a shortcut.
@MainActor
final class ControlServer {
    struct Item: Encodable, Equatable {
        let id: String
        let title: String
        let kind: String
        let on: Bool
        /// An effect's key, off and on, in its icon and color; a group's too.
        var image: KeyImages.Pair?
        /// An effect's group, by its item ID.
        var group: String?
    }

    private struct State: Encodable {
        let version = 1
        let items: [Item]
    }

    private struct Message: Decodable {
        let press: String?
        let release: String?
    }

    private final class Client {
        let source: DispatchSourceRead
        var buffer: [UInt8] = []
        /// Pressed and not yet let go, to let go of should it disconnect.
        var held: Set<String> = []
        /// Sent, and not yet taken by the socket (key images make messages
        /// bigger than it holds), written as it has room.
        var pending: [UInt8] = []
        var writer: DispatchSourceWrite?

        init(source: DispatchSourceRead) {
            self.source = source
        }
    }

    private let appState: AppState
    private let camera: VauxCamera
    private var listener: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private var items: [Item] = []
    /// Key images, drawn once each, by icon and color.
    private var keyImages: [String: KeyImages.Pair] = [:]
    private let log = Logger(subsystem: "dev.imathis.vaux", category: "control")

    /// Vaux Dev has its own.
    static var socketURL: URL {
        URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "dev.imathis.vaux", directoryHint: .isDirectory)
            .appending(path: "control.sock")
    }

    init(appState: AppState, camera: VauxCamera) {
        self.appState = appState
        self.camera = camera
        listen()
        follow()
    }

    // MARK: Connections

    private func listen() {
        let url = Self.socketURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.path
        // Left by a Vaux that didn't get to clean up.
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log.error("Couldn't make the control socket: \(errno)")
            return
        }
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            log.error("The control socket's path is too long")
            close(fd)
            return
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // Yours alone; a connection's user is checked too.
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 8) == 0 else {
            log.error("Couldn't open the control socket: \(errno)")
            close(fd)
            return
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.accept(from: fd) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
    }

    private func accept(from listener: Int32) {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        var user = uid_t()
        var group = gid_t()
        guard getpeereid(fd, &user, &group) == 0, user == getuid() else {
            log.notice("Refused a control connection from another user")
            close(fd)
            return
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.read(from: fd) }
        }
        source.setCancelHandler { close(fd) }
        clients[fd] = Client(source: source)
        source.resume()
        send(items, to: fd)
    }

    private func read(from fd: Int32) {
        guard let client = clients[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &chunk, chunk.count)
        guard count > 0 else {
            if count == 0 || errno != EAGAIN { drop(fd) }
            return
        }
        client.buffer += chunk[..<count]
        while let newline = client.buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(client.buffer[..<newline])
            client.buffer.removeSubrange(...newline)
            handle(line, from: client)
        }
        // Nothing sends this much without a line break.
        if client.buffer.count > 65_536 { drop(fd) }
    }

    /// Gone: whatever it held is let go.
    private func drop(_ fd: Int32) {
        guard let client = clients.removeValue(forKey: fd) else { return }
        client.writer?.cancel()
        client.source.cancel()
        for id in client.held { release(id) }
    }

    // MARK: Keys

    private func handle(_ line: Data, from client: Client) {
        guard let message = try? JSONDecoder().decode(Message.self, from: line) else { return }
        if let id = message.press, client.held.insert(id).inserted {
            press(id)
        }
        if let id = message.release, client.held.remove(id) != nil {
            release(id)
        }
    }

    private func press(_ id: String) {
        if let triggers = camera.effects?.triggers {
            if let item = triggers.items.first(where: { $0.id == id }) { triggers.press(item.action) }
        } else if id == Triggers.id(of: .mute) {
            // The camera's off: Mute is all there is.
            appState.toggle()
        }
    }

    private func release(_ id: String) {
        guard let triggers = camera.effects?.triggers, let item = triggers.items.first(where: { $0.id == id }) else { return }
        triggers.release(item.action)
    }

    // MARK: What's on

    /// Sends what there is whenever it changes.
    private func follow() {
        let items = withObservationTracking { current } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        guard items != self.items else { return }
        self.items = items
        for fd in clients.keys { send(items, to: fd) }
    }

    private var current: [Item] {
        guard let triggers = camera.effects?.triggers else {
            return [Item(id: Triggers.id(of: .mute), title: "Mute", kind: "mute", on: appState.muted)]
        }
        let library = camera.effects?.library
        // The dictation effect follows your dictation app, not a key.
        let dictation = library?.dictationEffect.map { Triggers.id(of: .effect($0)) }
        let items = triggers.items.filter { $0.id != dictation }.map { item in
            let kind = switch item.action {
            case .mute: "mute"
            case .live: "live"
            case .effect: "effect"
            case .clearAll: "clearAll"
            }
            var image: KeyImages.Pair?
            if case .effect(let id) = item.action, let library, let effect = library.effect(id) {
                image = keyImage(icon: effect.shownIcon, tint: library.tint(of: effect))
            }
            return Item(id: item.id, title: item.title, kind: kind, on: item.isOn, image: image, group: item.group.map(Self.id(of:)))
        }
        guard let library else { return items }
        // As listed: each group just ahead of its effects, lit while any of
        // them is on.
        let effects = Dictionary(uniqueKeysWithValues: items.filter { $0.kind == "effect" }.map { ($0.id, $0) })
        func item(_ effect: Effect) -> Item? { effects[Triggers.id(of: .effect(effect.id))] }
        var listed = items.filter { $0.kind == "mute" || $0.kind == "live" }
        for entry in library.listing {
            switch entry {
            case .effect(let effect):
                if let item = item(effect) { listed.append(item) }
            case .group(let group, let members):
                let members = members.compactMap(item)
                listed.append(Item(
                    id: Self.id(of: group), title: group.name, kind: "group",
                    on: members.contains(where: \.on),
                    image: keyImage(icon: group.shownIcon, tint: library.tint(of: group))
                ))
                listed += members
            }
        }
        return listed + items.filter { $0.kind == "clearAll" }
    }

    private static func id(of group: EffectGroup) -> String { "group-\(group.id)" }

    private func keyImage(icon: String, tint: Effect.Tint) -> KeyImages.Pair {
        let key = "\(icon) \(tint.rawValue)"
        if let pair = keyImages[key] { return pair }
        let pair = KeyImages.pair(icon: icon, tint: tint)
        keyImages[key] = pair
        return pair
    }

    private func send(_ items: [Item], to fd: Int32) {
        guard let client = clients[fd], var data = try? JSONEncoder().encode(State(items: items)) else { return }
        data.append(UInt8(ascii: "\n"))
        client.pending += data
        // Far behind, it's stopped reading: dropped, it reconnects.
        if client.pending.count > 16 << 20 {
            drop(fd)
            return
        }
        flush(fd)
    }

    /// Writes what the socket takes now, and the rest as it has room.
    private func flush(_ fd: Int32) {
        guard let client = clients[fd] else { return }
        while !client.pending.isEmpty {
            let written = client.pending.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                client.pending.removeFirst(written)
            } else if written < 0, errno == EAGAIN {
                break
            } else {
                drop(fd)
                return
            }
        }
        if client.pending.isEmpty {
            client.writer?.cancel()
            client.writer = nil
        } else if client.writer == nil {
            let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
            writer.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.flush(fd) }
            }
            client.writer = writer
            writer.resume()
        }
    }
}
