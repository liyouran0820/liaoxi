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

    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var screenCaptureGranted = CGPreflightScreenCaptureAccess()
    @Published var outputDirectory: URL?
    @Published var sourceFiles: [URL] = []
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

    func start() {
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
        let panel = NSOpenPanel()
        panel.title = "补充从微信保存的照片、视频和文档"
        panel.prompt = "添加附件"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !sourceFiles.contains(url) { sourceFiles.append(url) }
        }
    }

    func revealResult() {
        guard case let .finished(report) = runState else { return }
        NSWorkspace.shared.activateFileViewerSelecting([report.markdownURL])
    }
}
