import CoreMediaIO
import Foundation

/// The stream apps read Vaux Camera's video from.
final class StreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private(set) var stream: CMIOExtensionStream!
    let formats: [CMIOExtensionStreamFormat]
    private var activeFormatIndex = 0
    private weak var owner: DeviceSource?

    init(localizedName: String, streamID: UUID, formats: [CMIOExtensionStreamFormat], owner: DeviceSource) {
        self.formats = formats
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CameraSpec.frameDuration
        }
        return streamProperties
    }

    /// The watching app picks a size; one frame rate.
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        guard let index = streamProperties.activeFormatIndex, formats.indices.contains(index), index != activeFormatIndex else { return }
        activeFormatIndex = index
        owner?.formatChanged(to: index)
        stream.notifyPropertiesChanged([.streamActiveFormatIndex: CMIOExtensionPropertyState<AnyObject>(value: NSNumber(value: index))])
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { owner?.watchersChanged() }

    func stopStream() throws { owner?.watchersChanged() }
}
