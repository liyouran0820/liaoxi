import Foundation

struct ArchiveWorkspace {
    let directory: URL
    var markdownURL: URL { directory.appendingPathComponent(directory.lastPathComponent + ".md") }

    init(parent: URL) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        directory = ArchiveFiles.uniqueURL(in: parent, name: "微信聊天记录-\(formatter.string(from: Date()))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        writeIncomplete("正在提取，附件会直接保存在本文件所在目录。")
    }

    func writeIncomplete(_ reason: String) {
        var text = "# 微信合并聊天记录\n\n状态：\(reason)\n\n## 已保存的附件\n\n"
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for file in files where file != markdownURL && (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            text += "- [\(ArchiveFiles.kind(file))：\(file.lastPathComponent)](\(ArchiveFiles.relativeLink(file.lastPathComponent)))\n"
        }
        try? text.write(to: markdownURL, atomically: true, encoding: .utf8)
    }
}
