import AppKit
import ApplicationServices
import Foundation

/// Saves originals through WeChat's visible Save/Copy commands without executing attached documents.
@MainActor
final class AttachmentCollector {
    private var attempted = Set<String>()
    private var seenFiles: [String: URL] = [:]
    private(set) var files: [URL] = []
    private(set) var warnings: [String] = []
    var attemptedCount: Int { attempted.count }
    let directory: URL
    private let capture = WindowCaptureService()
    private let ocr = OCRService()

    init(directory: URL) {
        self.directory = directory
    }

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
            try await Task.sleep(nanoseconds: 350_000_000)
            click(location, button: .right)
            try await Task.sleep(nanoseconds: 350_000_000)
            guard var action = try await menuAction(root: root, target: target, location: location) else {
                // Escape closes the merged-record window when no popup actually exists.
                click(CGPoint(x: target.window.frame.midX, y: target.window.frame.minY + 55), button: .left)
                CaptureDiagnostics.record("media-menu-not-found")
                warnings.append("有媒体附件未能打开保存菜单，未作为正文识别。")
                continue
            }
            if action.save {
                CaptureDiagnostics.record("media-action=save")
                do {
                    if perform(action), let file = try await saveDialog(root: root) {
                        CaptureDiagnostics.record("media-file-saved")
                        try acceptSavedFile(file)
                        continue
                    }
                } catch {
                    cancelSavePanel(root: root)
                    throw error
                }
                cancelSavePanel(root: root)
                click(location, button: .right)
                try await Task.sleep(nanoseconds: 350_000_000)
                guard let copy = try await menuAction(root: root, target: target, location: location, preferCopy: true), !copy.save else {
                    click(CGPoint(x: target.window.frame.midX, y: target.window.frame.minY + 55), button: .left)
                    warnings.append("微信的附件另存未完成。可手动另存后使用“补充附件”。")
                    continue
                }
                action = copy
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
            guard perform(action) else {
                click(CGPoint(x: target.window.frame.midX, y: target.window.frame.minY + 55), button: .left)
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
                    do { try FileManager.default.copyItem(at: url, to: destination); try acceptSavedFile(destination) }
                    catch { warnings.append("\(url.lastPathComponent)：微信复制的附件不可读，请另存后补充。") }
                }
            } else if let data = board.data(forType: .png) {
                let destination = ArchiveFiles.uniqueURL(in: directory, name: "wechat-image.png")
                try data.write(to: destination, options: .withoutOverwriting)
                try acceptSavedFile(destination)
            } else if let data = board.data(forType: .tiff), let rep = NSBitmapImageRep(data: data),
                      let png = rep.representation(using: .png, properties: [:]) {
                let destination = ArchiveFiles.uniqueURL(in: directory, name: "wechat-image.png")
                try png.write(to: destination, options: .withoutOverwriting)
                try acceptSavedFile(destination)
            }
        }
    }

    func acceptSavedFile(_ file: URL) throws {
        guard file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        let hash = try ArchiveFiles.digest(file)
        if let first = seenFiles[hash], first != file, try ArchiveFiles.digest(first) == hash {
            // This is the fresh duplicate just saved by this collector; retain the verified first copy.
            try FileManager.default.removeItem(at: file)
            return
        }
        seenFiles[hash] = file
        if !files.contains(file) { files.append(file) }
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
        guard let field, let filename = string(field, kAXValueAttribute), !filename.isEmpty else {
            CaptureDiagnostics.record("save-panel-name-field-not-found")
            cancelSavePanel(root: root)
            return nil
        }
        // NSSavePanel may hide the extension. A unique prefix avoids a hidden-extension overwrite prompt.
        let destination = ArchiveFiles.uniqueURL(in: directory, name: "media-\(UUID().uuidString.prefix(8))-" + filename)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        do {
            key(5, flags: [.maskCommand, .maskShift]) // Go to Folder in NSSavePanel.
            var pathField: AXUIElement?
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 100_000_000)
                pathField = flatten(root).first { string($0, kAXIdentifierAttribute) == "PathTextField" }
                if pathField != nil { break }
            }
            guard let pathField,
                  AXUIElementSetAttributeValue(pathField, kAXValueAttribute as CFString, directory.path as CFString) == .success else {
                cancelSavePanel(root: root)
                return nil
            }
            key(36)
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if !flatten(root).contains(where: { string($0, kAXIdentifierAttribute) == "PathTextField" }) { break }
            }
            let nameField = flatten(root).first { string($0, kAXIdentifierAttribute) == "saveAsNameTextField" } ?? field
            guard AXUIElementSetAttributeValue(nameField, kAXValueAttribute as CFString, destination.lastPathComponent as CFString) == .success else {
                cancelSavePanel(root: root)
                return nil
            }
            let buttons = flatten(root).filter { string($0, kAXRoleAttribute) == kAXButtonRole as String }
            guard let save = buttons.first(where: { ["存储", "保存", "Save"].contains(string($0, kAXTitleAttribute) ?? "") }) else {
                cancelSavePanel(root: root)
                return nil
            }
            guard AXUIElementPerformAction(save, kAXPressAction as CFString) == .success else { cancelSavePanel(root: root); return nil }
            var previousSize = -1
            var previousName = ""
            var stable = 0
            for _ in 0..<600 {
                try await Task.sleep(nanoseconds: 200_000_000)
                let newFiles = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
                let file = newFiles.first { !before.contains($0.lastPathComponent)
                    && !$0.lastPathComponent.hasPrefix(".") && !["part", "download", "tmp"].contains($0.pathExtension.lowercased()) }
                let size = (try? file?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                stable = size > 0 && size == previousSize && file?.lastPathComponent == previousName ? stable + 1 : 0
                previousSize = size
                previousName = file?.lastPathComponent ?? ""
                if stable >= 15 { return file }
            }
            cancelSavePanel(root: root)
            return nil
        } catch {
            cancelSavePanel(root: root)
            throw error
        }
    }

    private func cancelSavePanel(root: AXUIElement) {
        if let button = flatten(root).first(where: {
            string($0, kAXRoleAttribute) == kAXButtonRole as String && ["取消", "Cancel"].contains(string($0, kAXTitleAttribute) ?? "")
        }) { AXUIElementPerformAction(button, kAXPressAction as CFString) }
    }

    private struct MenuAction {
        let save: Bool
        let element: AXUIElement?
        let point: CGPoint?
    }

    private func normalizedMenuTitle(_ text: String) -> String {
        text.replacingOccurrences(of: #"[.…]|\([A-Za-z]\)|（[A-Za-z]）"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func menuAction(root: AXUIElement, target: CapturableWindow, location: CGPoint, preferCopy: Bool = false) async throws -> MenuAction? {
        let saveNames = ["另存为", "存储为", "保存图片", "保存视频", "保存到本地", "Save As", "Save Image As", "Save Video As"]
        let copyNames = ["复制", "複製", "Copy", "复制图片", "Copy Image"]
        let items = flatten(root).filter { isAvailableMenuItem($0) }
        if preferCopy, let item = items.first(where: { copyNames.contains(normalizedMenuTitle(string($0, kAXTitleAttribute) ?? "")) }) {
            return MenuAction(save: false, element: item, point: nil)
        }
        if let item = items.first(where: { saveNames.contains(normalizedMenuTitle(string($0, kAXTitleAttribute) ?? "")) }) {
            return MenuAction(save: true, element: item, point: nil)
        }
        if let item = items.first(where: { copyNames.contains(normalizedMenuTitle(string($0, kAXTitleAttribute) ?? "")) }) {
            return MenuAction(save: false, element: item, point: nil)
        }
        // Qt draws its context menu without AXMenuItem. Read only the visible menu and match known commands.
        var screenshot: (image: CGImage, frame: CGRect)?
        for _ in 0..<3 {
            try Task.checkCancellation()
            do {
                screenshot = try await capture.captureVisibleRegion(target: target,
                    rect: CGRect(x: location.x - 260, y: location.y - 30, width: 560, height: 460))
                break
            } catch {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        guard let sample = screenshot else {
            CaptureDiagnostics.record("menu-capture-failed-after-retries")
            return nil
        }
        let lines = try await ocr.recognize(sample.image)
        let menuNames = saveNames + copyNames + ["转发", "收藏", "多选", "删除", "引用", "Forward", "Favorite", "Delete"]
        let recognized = lines.filter { menuNames.contains(normalizedMenuTitle($0.text)) }
        CaptureDiagnostics.record("visual-menu-commands=\(recognized.count)")
        guard recognized.count >= 2 else { return nil }
        let saveLine = recognized.first(where: { saveNames.contains(normalizedMenuTitle($0.text)) })
        let copyLine = recognized.first(where: { copyNames.contains(normalizedMenuTitle($0.text)) })
        guard let line = preferCopy ? (copyLine ?? saveLine) : (saveLine ?? copyLine) else { return nil }
        return MenuAction(save: saveNames.contains(normalizedMenuTitle(line.text)), element: nil,
                          point: CGPoint(x: sample.frame.minX + line.bounds.midX * sample.frame.width,
                                         y: sample.frame.minY + (1 - line.bounds.midY) * sample.frame.height))
    }

    private func perform(_ action: MenuAction) -> Bool {
        if let element = action.element { return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success }
        if let point = action.point { click(point, button: .left); return true }
        return false
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
        let types: [CGEventType] = button == .right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
        for type in types {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            event?.post(tap: .cghidEventTap)
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
