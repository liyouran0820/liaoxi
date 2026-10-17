import CryptoKit
import Foundation

enum ArchiveFiles {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "3gp"]

    static func safeName(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var name = raw.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if name.isEmpty { name = "attachment" }
        let stem = (name as NSString).deletingPathExtension.uppercased()
        let reserved = ["CON", "PRN", "AUX", "NUL"] + (1...9).map { "COM\($0)" } + (1...9).map { "LPT\($0)" }
        if reserved.contains(stem) { name = "_" + name }
        return name
    }

    static func uniqueURL(in directory: URL, name: String) -> URL {
        let name = safeName(name)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem)-\(suffix)" + (ext.isEmpty ? "" : ".\(ext)"))
            suffix += 1
        }
        return candidate
    }

    static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func relativeLink(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }

    static func kind(_ file: URL) -> String {
        let ext = file.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return "照片" }
        if videoExtensions.contains(ext) { return "视频" }
        return "文档 / 文件"
    }
}
