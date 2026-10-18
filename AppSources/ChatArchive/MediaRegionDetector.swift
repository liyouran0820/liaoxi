import CoreGraphics
import Foundation

/// Detects dense media blocks by pixels before text OCR; normalized coordinates use Vision's bottom-left origin.
struct MediaRegionDetector {
    func regions(in image: CGImage) -> [CGRect] {
        let width = min(360, image.width)
        let height = max(1, image.height * width / image.width)
        guard width > 3, height > 3 else { return [] }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext's data rows are in image order. Sample the blank right side for light/dark themes.
        var samples: [[Int]] = [[], [], []]
        for y in stride(from: height / 6, to: height * 9 / 10, by: 3) {
            let index = (y * width + width * 95 / 100) * 4
            for channel in 0..<3 { samples[channel].append(Int(pixels[index + channel])) }
        }
        let background = samples.map { values -> Int in
            let sorted = values.sorted()
            return sorted.isEmpty ? 250 : sorted[sorted.count / 2]
        }
        var ink = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                ink[y * width + x] = (0..<3).contains { abs(Int(pixels[i + $0]) - background[$0]) > 35 }
            }
        }
        // Join image pixels across small white gaps while leaving separated message rows apart.
        var joined = [Bool](repeating: false, count: ink.count)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) where ink[y * width + x] {
                for dy in -1...1 { for dx in -1...1 { joined[(y + dy) * width + x + dx] = true } }
            }
        }
        var visited = [Bool](repeating: false, count: ink.count)
        var found: [CGRect] = []
        for start in joined.indices where joined[start] && !visited[start] {
            var queue = [start]
            visited[start] = true
            var head = 0
            var left = width, top = height, right = 0, bottom = 0, count = 0
            while head < queue.count {
                let i = queue[head]; head += 1
                let x = i % width, y = i / width
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
                if ink[i] { count += 1 }
                for neighbor in [i - width, i + width, x > 0 ? i - 1 : -1, x + 1 < width ? i + 1 : -1] {
                    if neighbor >= 0 && neighbor < joined.count && joined[neighbor] && !visited[neighbor] {
                        visited[neighbor] = true
                        queue.append(neighbor)
                    }
                }
            }
            let w = right - left + 1, h = bottom - top + 1
            let area = Double(w * h) / Double(width * height)
            let density = Double(count) / Double(w * h)
            guard Double(w) / Double(width) >= 0.12, Double(h) / Double(height) >= 0.045,
                  left >= width * 7 / 100, right < width * 95 / 100,
                  top > height * 9 / 100, area >= 0.007, area < 0.65, density > 0.16 else { continue }
            found.append(CGRect(x: CGFloat(max(0, left - 2)) / CGFloat(width),
                                y: 1 - CGFloat(min(height, bottom + 3)) / CGFloat(height),
                                width: CGFloat(min(width, right + 3) - max(0, left - 2)) / CGFloat(width),
                                height: CGFloat(min(height, bottom + 3) - max(0, top - 2)) / CGFloat(height)))
        }
        return found.sorted { $0.maxY > $1.maxY }
    }

    func masking(_ image: CGImage, regions: [CGRect]) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: image.width * image.height * 4)
        guard !regions.isEmpty,
              let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for rect in regions {
            let left = max(0, Int(rect.minX * CGFloat(image.width)))
            let right = min(image.width, Int(ceil(rect.maxX * CGFloat(image.width))))
            let top = max(0, Int((1 - rect.maxY) * CGFloat(image.height)))
            let bottom = min(image.height, Int(ceil((1 - rect.minY) * CGFloat(image.height))))
            guard left < right, top < bottom else { continue }
            for y in top..<bottom { for x in left..<right {
                let index = (y * image.width + x) * 4
                for channel in 0..<4 { pixels[index + channel] = 255 }
            } }
        }
        return context.makeImage() ?? image
    }
}
