import AppKit
import CoreGraphics
import Foundation

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
        screenCaptureGranted = CGRequestScreenCaptureAccess()
        guard !screenCaptureGranted else { return }

        if SystemSettingsService().openScreenCapture() {
            runState = .failed("已打开屏幕录制设置。请打开“聊析”开关，然后按系统提示重新打开应用。")
        } else {
            runState = .failed("无法自动打开系统设置。请手动进入“隐私与安全性 → 屏幕与系统音频录制”。")
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
                    Task { @MainActor in self?.runState = .working(status) }
                }
                let report = try await pipeline.run(in: outputDirectory)
                runState = .finished(report)
            } catch is CancellationError {
                runState = .failed("已停止提取，没有写入未完成的结果。")
            } catch {
                runState = .failed(error.localizedDescription)
            }
            extractionTask = nil
        }
    }

    func cancel() {
        extractionTask?.cancel()
    }

    func revealResult() {
        guard case let .finished(report) = runState else { return }
        NSWorkspace.shared.activateFileViewerSelecting([report.markdownURL])
    }
}
