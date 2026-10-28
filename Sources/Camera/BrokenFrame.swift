import CoreVideo

/// Spots a frame that arrived from the camera broken: some of its bytes were
/// lost on the way (through a dock or hub, say), so the rest slipped into the
/// wrong places. The color data, landing where brightness goes, shows as a
/// band of flat gray with fine vertical stripes (its two color channels
/// alternate pixel by pixel), with the picture above it shifted. That band
/// gives it away: a picture changes smoothly from one pixel to the next,
/// where color data alternates. A row in every few is enough to find it, in a
/// fraction of a millisecond.
///
/// Tested on the 397 photos and textures macOS ships, whole and at 1:1: no
/// row of any of them looked like color data; of frames broken from them,
/// 97% from photos were caught (85% counting flat one-color textures, whose
/// color data is too even to tell from a plain gray wall).
enum BrokenFrame {
    /// Rows checked: one in this many.
    private static let rowStep = 4
    /// Rows in a row that look like color data, about a dozen pixels: a
    /// band thinner than that is barely seen.
    private static let shortestBand = 3

    static func isBroken(_ pixels: CVPixelBuffer) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(pixels)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return false }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return false }
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        var run = 0
        for row in stride(from: 0, to: CVPixelBufferGetHeightOfPlane(pixels, 0), by: rowStep) {
            if looksLikeColor(luma + row * bytesPerRow, width: width) {
                run += 1
                if run >= shortestBand { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    /// A row of color data where brightness should be: neighbors differ far
    /// more than pixels two apart, and it sits around the middle gray, as
    /// color values do.
    private static func looksLikeColor(_ row: UnsafePointer<UInt8>, width: Int) -> Bool {
        var neighbors = 0
        var twoApart = 0
        var sum = 0
        var samples = 0
        var x = 0
        while x + 2 < width {
            let a = Int(row[x]), b = Int(row[x + 1]), c = Int(row[x + 2])
            neighbors += abs(a - b) + abs(b - c)
            twoApart += abs(a - c)
            sum += a
            samples += 1
            x += 2
        }
        guard samples > 0 else { return false }
        let alternating = Double(neighbors) / 2 / Double(samples)
        let changing = Double(twoApart) / Double(samples)
        let mean = Double(sum) / Double(samples)
        return alternating >= 2 && alternating >= 4 * changing && abs(mean - 128) < 72
    }
}
