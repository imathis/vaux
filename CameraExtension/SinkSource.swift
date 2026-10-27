import CoreMediaIO
import Foundation
import os

/// The stream Vaux feeds camera frames into.
final class SinkSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private(set) var stream: CMIOExtensionStream!
    let formats: [CMIOExtensionStreamFormat]
    /// Follows the video stream's: Vaux feeds the size the watching app chose.
    var activeFormatIndex = 0
    private weak var owner: DeviceSource?
    /// Who asked to feed; the stream starts right after.
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, formats: [CMIOExtensionStreamFormat], owner: DeviceSource) {
        self.formats = formats
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .sink,
            clockType: .hostTime,
            source: self
        )
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [
            .streamActiveFormatIndex, .streamFrameDuration,
            .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
            .streamSinkBufferUnderrunCount, .streamSinkEndOfData,
        ]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CameraSpec.frameDuration
        }
        // A short queue: a late frame is better dropped than shown late.
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 2
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        if properties.contains(.streamSinkBufferUnderrunCount) {
            streamProperties.sinkBufferUnderrunCount = 0
        }
        if properties.contains(.streamSinkEndOfData) {
            streamProperties.sinkEndOfData = 0
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        guard let client else { return }
        owner?.startFeeding(from: client)
    }

    func stopStream() throws {
        client = nil
        owner?.stopFeeding()
    }
}
