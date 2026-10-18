import Foundation

enum ChatWindowSelector {
    static func isMergedRecordTitle(_ title: String) -> Bool {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = name.lowercased()
        if ["搜索聊天记录", "查找聊天记录", "聊天记录管理", "聊天记录备份", "聊天记录迁移"].contains(where: { name.hasPrefix($0) }) { return false }
        if lower.hasPrefix("search") || lower.hasPrefix("find") || lower.contains("backup") || lower.contains("migration") { return false }
        return name == "聊天记录" || name.hasSuffix("的聊天记录") || lower.hasSuffix("chat history")
    }
}
