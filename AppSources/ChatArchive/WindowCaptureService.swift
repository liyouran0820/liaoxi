import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct CapturableWindow {
    let window: SCWindow
    let application: SCRunningApplication
}

struct WindowCaptureService {
    func locateWeChatWindow() async throws -> CapturableWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let apps = content.applications.filter { app in
            let name = app.applicationName.lowercased()
            let bundle = app.bundleIdentifier.lowercased()
            return name == "微信" || name.contains("wechat") || bundle.contains("xinwechat")
        }
        guard !apps.isEmpty else { throw ExtractionError.weChatNotRunning }

        let pids = Set(apps.map(\.processID))
        let candidates = content.windows.filter { window in
            guard let app = window.owningApplication, pids.contains(app.processID) else { return false }
            return window.isOnScreen && window.frame.width >= 420 && window.frame.height >= 360
        }

        let ranked = candidates.sorted { lhs, rhs in
            score(lhs) > score(rhs)
        }
        guard let window = ranked.first, let application = window.owningApplication else {
            throw ExtractionError.noSuitableWindow
        }
        return CapturableWindow(window: window, application: application)
    }

    func capture(_ target: CapturableWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: target.window)
        let configuration = SCStreamConfiguration()
        let scale = bestScaleFactor(for: target.window.frame)
        configuration.width = max(1, Int(target.window.frame.width * scale))
        configuration.height = max(1, Int(target.window.frame.height * scale))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.colorSpaceName = CGColorSpace.sRGB

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw ExtractionError.captureFailed
        }
    }

    func activateAndScroll(target: CapturableWindow, delta: Int32) async {
        if let app = NSRunningApplication(processIdentifier: target.application.processID) {
            app.activate(options: [.activateAllWindows])
        }
        let location = CGPoint(x: target.window.frame.midX, y: target.window.frame.midY)
        let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)
        event?.location = location
        event?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 450_000_000)
    }

    private func score(_ window: SCWindow) -> Double {
        var result = Double(window.frame.width * window.frame.height)
        let title = (window.title ?? "").lowercased()
        if title.contains("聊天记录") || title.contains("chat history") { result += 10_000_000 }
        if title.contains("微信") || title.contains("wechat") { result += 1_000_000 }
        return result
    }

    private func bestScaleFactor(for frame: CGRect) -> CGFloat {
        NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.backingScaleFactor ?? 2
    }
}
