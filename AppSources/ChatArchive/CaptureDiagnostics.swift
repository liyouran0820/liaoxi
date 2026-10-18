import Foundation

enum CaptureDiagnostics {
    static func record(_ event: String) {
        // Operational metadata only: never log chat text, media bytes, filenames or clipboard contents.
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/聊析")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("capture.log")
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\(Date().timeIntervalSince1970) \(event)\n".utf8))
        } catch { /* Diagnostics must not interrupt an export. */ }
    }
}
