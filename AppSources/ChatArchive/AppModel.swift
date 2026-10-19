import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
final class AppModel: ObservableObject {
    enum RunState: Equatable {
        case idle
        case working(String)
        case finished(ExtractionReport)
        case failed(String)
    }

    @Published var accessibilityGranted = false
    @Published var screenCaptureGranted = false
    @Published var outputDirectory: URL?
    @Published var sourceFiles: [URL] = []
    @Published var draftText = ""
    @Published var draftSelection = NSRange(location: 0, length: 0)
    @Published var manualAttachments: [ManualAttachment] = []
    @Published var runState: RunState = .idle
    private var extractionTask: Task<Void, Never>?

    var isWorking: Bool {
        if case .working = runState { return true }
        return false
    }

    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        accessibilityGranted = AXIsProcessTrusted()
        guard !accessibilityGranted else { return }

        if SystemSettingsService().openAccessibility() {
            runState = .failed("已打开辅助功能设置。请打开“聊析”开关，然后返回这里。")
        } else {
            runState = .failed("无法自动打开系统设置。请手动进入“隐私与安全性 → 辅助功能”。")
        }
    }

    func requestScreenCapture() {
        runState = .working("正在向 macOS 请求屏幕录制权限…")
        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
            } catch {
                _ = CGRequestScreenCaptureAccess()
            }

            refreshPermissions()
            guard !screenCaptureGranted else {
                runState = .idle
                return
            }

            if SystemSettingsService().openScreenCapture() {
                runState = .failed("已注册屏幕录制请求。请打开“聊析”开关，然后按系统提示重新打开应用。")
            } else {
                runState = .failed("无法自动打开系统设置。请手动进入“隐私与安全性 → 录屏与系统录音”。")
            }
        }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择导出位置"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            outputDirectory = panel.url
        }
    }

    func startAutomaticExtraction() {
        refreshPermissions()
        guard accessibilityGranted else {
            runState = .failed("请先打开辅助功能设置中的“聊析”开关。")
            return
        }
        guard screenCaptureGranted else {
            runState = .failed("请先打开屏幕录制设置中的“聊析”开关。")
            return
        }
        guard let outputDirectory else {
            runState = .failed("请先选择导出位置。")
            return
        }

        runState = .working("正在定位微信聊天记录窗口…")
        extractionTask = Task {
            do {
                let pipeline = ExtractionPipeline { [weak self] status in
                    self?.runState = .working(status)
                }
                let report = try await pipeline.run(in: outputDirectory, sourceFiles: sourceFiles)
                runState = .finished(report)
            } catch is CancellationError {
                runState = .failed("已停止提取，已保存的附件保留在同名文件夹中，Markdown 会标明未完成。")
            } catch {
                runState = .failed(error.localizedDescription)
            }
            extractionTask = nil
        }
    }

    func cancel() {
        extractionTask?.cancel()
    }

    func chooseAttachments() {
        let insertion = draftSelection
        let panel = NSOpenPanel()
        panel.title = "补充从微信保存的照片、视频和文档"
        panel.prompt = "添加附件"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            insertAttachments(panel.urls, at: insertion)
        }
    }

    func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            runState = .failed("剪贴板中没有文字。照片、视频和文件请先保存，再用“补充附件”加入。")
            return
        }
        let edit = ManualDraft.inserting(text, into: draftText, selection: draftSelection)
        draftText = edit.text; draftSelection = edit.selection
    }

    func insertAttachments(_ urls: [URL], at selection: NSRange) {
        var entries: [ManualAttachment] = []
        for url in urls {
            if let existing = manualAttachments.first(where: { $0.source.standardizedFileURL == url.standardizedFileURL }) {
                entries.append(existing)
            } else {
                let entry = ManualAttachment(id: (manualAttachments.map(\.id).max() ?? 0) + 1, source: url)
                manualAttachments.append(entry); entries.append(entry)
            }
        }
        guard !entries.isEmpty else { return }
        // Adding files must not erase a selected message.
        let insertion = Range(selection, in: draftText) == nil ? draftText.utf16.count : NSMaxRange(selection)
        let edit = ManualDraft.inserting(entries.map(\.token).joined(separator: "\n\n"), into: draftText,
            selection: NSRange(location: insertion, length: 0), block: true)
        draftText = edit.text; draftSelection = edit.selection
        sourceFiles = manualAttachments.map(\.source)
    }

    func clearManualAttachments() {
        for entry in manualAttachments { draftText = draftText.replacingOccurrences(of: entry.token, with: "") }
        manualAttachments = []; sourceFiles = []
        draftSelection = NSRange(location: draftText.utf16.count, length: 0)
    }

    func start() {
        guard !isWorking else { return }
        guard let parent = outputDirectory else { runState = .failed("请先选择导出位置。"); return }
        let draft = draftText, attachments = manualAttachments
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else {
            runState = .failed(ManualArchiveError.empty.localizedDescription); return
        }
        runState = .working("正在保存 Markdown 与附件…")
        extractionTask = Task {
            do {
                let report = try await withThrowingTaskGroup(of: ExtractionReport.self) { group in
                    group.addTask { try ManualMarkdownExporter().export(draft: draft, attachments: attachments, to: parent) }
                    guard let result = try await group.next() else { throw CancellationError() }
                    return result
                }
                runState = .finished(report)
            } catch is CancellationError { runState = .failed("已停止保存；粘贴文字仍在编辑区，已写入的草稿和附件保留。") }
            catch { runState = .failed(error.localizedDescription) }
            extractionTask = nil
        }
    }

    func revealResult() {
        guard case let .finished(report) = runState else { return }
        NSWorkspace.shared.activateFileViewerSelecting([report.markdownURL])
    }
}
