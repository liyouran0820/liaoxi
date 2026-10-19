import CoreGraphics

enum CaptureQuality {
    /// Reject transparent / solid content areas, not merely empty OCR output (an image-only page is valid).
    static func hasVisibleContent(_ image: CGImage) -> Bool {
        let width = 128, height = 160
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var low = [255, 255, 255], high = [0, 0, 0], opaque = 0
        // Ignore window chrome; a title bar alone must not make a blank chat look readable.
        for y in 20..<152 { for x in 10..<120 {
            let index = (y * width + x) * 4
            guard pixels[index + 3] >= 128 else { continue }
            opaque += 1
            for channel in 0..<3 {
                low[channel] = min(low[channel], Int(pixels[index + channel]))
                high[channel] = max(high[channel], Int(pixels[index + channel]))
            }
        } }
        return opaque > 100 && (0..<3).contains { high[$0] - low[$0] >= 12 }
    }
}
