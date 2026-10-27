import CoreMedia
import CoreVideo
import Foundation

/// Vaux Camera's identity and formats, shared by Vaux and the extension.
enum CameraSpec {
    // Development builds have their own camera, so it and the release's
    // never collide.
    #if DEBUG
    static let name = "Vaux Dev Camera"
    #else
    static let name = "Vaux Camera"
    #endif
    static let manufacturer = "Vaux"
    /// What Vaux Camera offers, like a camera does: 720p and 1080p in
    /// cameras' own 4:2:0 YUV, at up to 60 fps (as fast as the camera
    /// runs; 30 at the least). The watching app picks a size; Vaux reads
    /// its choice from the stream.
    static let sizes = [CMVideoDimensions(width: 1280, height: 720), CMVideoDimensions(width: 1920, height: 1080)]
    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    static let fps: Int32 = 60
    static let frameDuration = CMTime(value: 1, timescale: fps)
    /// The slowest rate it runs at, a camera that does no better than 30:
    /// frames later than this are filled in.
    static let slowestFrameDuration = CMTime(value: 1, timescale: 30)
    /// Fixed, not made per launch: call apps remember a camera by its ID. It's
    /// also the device's unique ID in AVFoundation and CoreMediaIO.
    #if DEBUG
    static let deviceID = UUID(uuidString: "D37C8F68-A095-4C61-B40E-3FA30770631B")!
    static let sourceStreamID = UUID(uuidString: "C46AC17B-861F-4F30-96C5-A946CB6295BE")!
    static let sinkStreamID = UUID(uuidString: "5594CFB4-1254-4F3F-8352-757177F23CF5")!
    #else
    static let deviceID = UUID(uuidString: "2A09AA1C-8186-410D-8A1C-03E2C28CCFFC")!
    static let sourceStreamID = UUID(uuidString: "FD88204E-BEA7-4D8D-8DA0-96A7D426D13F")!
    static let sinkStreamID = UUID(uuidString: "841E408B-81C2-4322-A251-F113A65FE6AF")!
    #endif
    /// A custom device property, "1" while any app is watching Vaux Camera,
    /// so Vaux runs the real camera only then. Custom extension properties
    /// are named 4cc_<selector>_<scope>_<element>.
    static let watchedProperty = "4cc_wtch_glob_0000"
    static let watchedSelector: UInt32 = 0x7774_6368 // 'wtch'

    /// Rec. 709, the color cameras tag their frames with.
    static var colorExtensions: [CFString: Any] {
        [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
        ]
    }
}
