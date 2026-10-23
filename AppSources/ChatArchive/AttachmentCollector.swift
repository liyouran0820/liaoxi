import AppKit
import ApplicationServices
import Foundation

/// Uses WeChat's visible Copy command. It never opens/executes an attached document.
@MainActor
final class AttachmentCollector {
    private var attempted = Set<String>()
    private(set) var files: [URL] = []
    private(set) var warnings: [String] = []
    var attemptedCount: Int { attempted.count }
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChatArchive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    func collect(target: CapturableWindow, lines: [RecognizedLine], regions: [CGRect]) async throws {
        try Task.checkCancellation()
        let processor = ContentProcessor()
        var candidates: [(CGRect, String)] = []
        for (index, line) in lines.enumerated() {
            if !processor.likelyFileNames(in: [line.text]).isEmpty {
                let context = lines[max(0, index - 2)...index].map(\.text).joined(separator: "|")
                candidates.append((line.bounds, context))
            }
        }
        candidates += regions.map { region in
            let context = lines.filter { $0.bounds.minY >= region.maxY && $0.bounds.minY - region.maxY < 0.12 }
                .map(\.text).joined(separator: "|")
            return (region, "media|" + context + String(format: "|%.2f|%.2f", region.width, region.height))
        }
        for (rect, identity) in candidates.prefix(20) {
            try Task.checkCancellation()
            guard rect.midY > 0.04, rect.midY < 0.92, attempted.insert(identity).inserted else { continue }
            let location = CGPoint(x: target.window.frame.minX + rect.midX * target.window.frame.width,
                                   y: target.window.frame.minY + (1 - rect.midY) * target.window.frame.height)
            guard let app = NSRunningApplication(processIdentifier: target.application.processID) else { continue }
            app.activate(options: [.activateAllWindows])
            let root = AXUIElementCreateApplication(target.application.processID)
            var windowValue: CFTypeRef?
            AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowValue)
            if let windows = windowValue as? [AXUIElement],
               let selected = windows.first(where: { string($0, kAXTitleAttribute) == target.window.title }) {
                AXUIElementPerformAction(selected, kAXRaiseAction as CFString)
            } else {
                warnings.append("聊天记录窗口已改变，已跳过附件操作。")
                return
            }
            click(location, button: .right)
            try await Task.sleep(nanoseconds: 250_000_000)
            let items = flatten(root).filter { isAvailableMenuItem($0) }
            if let save = items.first(where: {
                let title = (string($0, kAXTitleAttribute) ?? "").replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
                return ["另存为", "存储为", "保存图片", "保存视频", "Save As", "Save Image As", "Save Video As"].contains(title)
            }) {
                do {
                    if AXUIElementPerformAction(save, kAXPressAction as CFString) == .success,
                       let file = try await saveDialog(root: root) {
                        files.append(file)
                        continue
                    }
                } catch {
                    key(53)
                    throw error
                }
                warnings.append("微信的附件另存未完成。可手动另存后使用“补充附件”。")
                continue
            }
            guard let copy = items.first(where: {
                let title = string($0, kAXTitleAttribute) ?? ""
                return ["复制", "複製", "Copy", "复制图片", "Copy Image"].contains(title)
            }) else {
                // Qt may expose no popup at all. Escape then closes the record itself and breaks scrolling.
                // A single click on the title's blank centre dismisses a popup without closing the record.
                click(CGPoint(x: target.window.frame.midX, y: target.window.frame.minY + 52), button: .left)
                ScrollDiagnostics.record("attachment-menu-unavailable dismissed-without-escape")
                continue
            }
            let board = NSPasteboard.general
            let snapshot = snapshotPasteboard(board)
            let originalCount = board.changeCount
            var ownCount = originalCount
            defer {
                if board.changeCount == ownCount && ownCount != originalCount {
                    board.clearContents()
                    if !snapshot.isEmpty { board.writeObjects(snapshot) }
                }
            }
            guard AXUIElementPerformAction(copy, kAXPressAction as CFString) == .success else {
                key(53)
                continue
            }
            ownCount = board.changeCount
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                ownCount = board.changeCount
                try Task.checkCancellation()
                if board.changeCount != originalCount { break }
            }
            ownCount = board.changeCount
            guard ownCount != originalCount else { continue }
            if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                for url in urls {
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                    let destination = ArchiveFiles.uniqueURL(in: directory, name: url.lastPathComponent)
                    do { try FileManager.default.copyItem(at: url, to: destination); files.append(destination) }
                    catch { warnings.append("\(url.lastPathComponent)：微信复制的附件不可读，请另存后补充。") }
                }
            } else if let data = board.data(forType: .png) {
                let destination = ArchiveFiles.uniqueURL(in: directory, name: "wechat-image.png")
                try data.write(to: destination, options: .withoutOverwriting)
                files.append(destination)
            } else if let data = board.data(forType: .tiff), let rep = NSBitmapImageRep(data: data),
                      let png = rep.representation(using: .png, properties: [:]) {
                let destination = ArchiveFiles.uniqueURL(in: directory, name: "wechat-image.png")
                try png.write(to: destination, options: .withoutOverwriting)
                files.append(destination)
            }
        }
    }

    private func saveDialog(root: AXUIElement) async throws -> URL? {
        var field: AXUIElement?
        for _ in 0..<25 {
            try await Task.sleep(nanoseconds: 100_000_000)
            field = flatten(root).first {
                string($0, kAXRoleAttribute) == kAXTextFieldRole as String
                    && (string($0, kAXIdentifierAttribute) == "saveAsNameTextField"
                        || ["存储为：", "存储为:", "Save As:", "保存为："].contains(string($0, kAXTitleAttribute) ?? ""))
            }
            if field != nil { break }
        }
        guard let field, let filename = string(field, kAXValueAttribute),
              !(filename as NSString).pathExtension.isEmpty else {
            key(53)
            return nil
        }
        let destination = ArchiveFiles.uniqueURL(in: directory, name: filename)
        let board = NSPasteboard.general
        let snapshot = snapshotPasteboard(board)
        board.clearContents()
        board.setString(directory.path, forType: .string)
        let ownCount = board.changeCount
        defer {
            if board.changeCount == ownCount {
                board.clearContents()
                if !snapshot.isEmpty { board.writeObjects(snapshot) }
            }
        }
        do {
            key(5, flags: [.maskCommand, .maskShift]) // Go to Folder in NSSavePanel.
            try await Task.sleep(nanoseconds: 200_000_000)
            key(9, flags: .maskCommand)
            key(36)
            try await Task.sleep(nanoseconds: 250_000_000)
            guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, destination.lastPathComponent as CFString) == .success else {
                key(53)
                return nil
            }
            let buttons = flatten(root).filter { string($0, kAXRoleAttribute) == kAXButtonRole as String }
            guard let save = buttons.first(where: { ["存储", "保存", "Save"].contains(string($0, kAXTitleAttribute) ?? "") }) else {
                key(53)
                return nil
            }
            guard AXUIElementPerformAction(save, kAXPressAction as CFString) == .success else { key(53); return nil }
            var previousSize = -1
            var stable = 0
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 200_000_000)
                let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                stable = size > 0 && size == previousSize ? stable + 1 : 0
                previousSize = size
                if stable >= 5 { return destination }
            }
            key(53)
            return nil
        } catch {
            key(53)
            throw error
        }
    }

    private func snapshotPasteboard(_ board: NSPasteboard) -> [NSPasteboardItem] {
        (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
    }

    private func flatten(_ root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        while let (element, depth) = pending.popLast(), result.count < 4000 {
            result.append(element)
            if depth >= 16 { continue }
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            if let children = value as? [AXUIElement] { pending += children.map { ($0, depth + 1) } }
        }
        return result
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? String
    }

    private func isAvailableMenuItem(_ element: AXUIElement) -> Bool {
        guard string(element, kAXRoleAttribute) == kAXMenuItemRole as String else { return false }
        var enabled: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
        guard (enabled as? Bool) == true else { return false }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        var size = CGSize.zero
        AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size)
        return size.width > 0 && size.height > 0
    }

    private func click(_ point: CGPoint, button: CGMouseButton) {
        for type in [CGEventType.rightMouseDown, .rightMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
        }
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
