import AppKit
import ApplicationServices
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
        guard !apps.isEmpty else {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.xinWeChat")
            throw running.isEmpty ? ExtractionError.weChatNotRunning : ExtractionError.noSuitableWindow
        }

        let pids = Set(apps.map(\.processID))
        let candidates = content.windows.filter { window in
            guard let app = window.owningApplication, pids.contains(app.processID) else { return false }
            return window.isOnScreen && window.frame.width >= 420 && window.frame.height >= 360
                && ChatWindowSelector.isMergedRecordTitle(window.title ?? "")
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
        // AppKit and ScreenCaptureKit use different screen coordinate origins. Use the filter's scale.
        let scale = max(2, CGFloat(filter.pointPixelScale))
        configuration.width = max(1, Int(target.window.frame.width * scale))
        configuration.height = max(1, Int(target.window.frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        configuration.colorSpaceName = CGColorSpace.sRGB

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            if CaptureQuality.hasVisibleContent(image) { return image }
            CaptureDiagnostics.record("capture-window-empty retry=display-filter")
        } catch {
            CaptureDiagnostics.record("capture-window-error retry=display-filter")
        }
        // Window-only capture can return a blank / transparent frame even while the window is visible.
        // Retry on its display, still including only this exact WeChat window, never the whole desktop.
        for attempt in 0..<2 {
            try Task.checkCancellation()
            try await activateWindow(target: target)
            try await Task.sleep(nanoseconds: 350_000_000)
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == target.window.windowID }),
                      let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) }),
                      display.frame.contains(window.frame) else { throw ExtractionError.noSuitableWindow }
                let displayFilter = SCContentFilter(display: display, including: [window])
                let config = SCStreamConfiguration()
                config.sourceRect = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                config.width = Int(window.frame.width * max(2, CGFloat(displayFilter.pointPixelScale)))
                config.height = Int(window.frame.height * max(2, CGFloat(displayFilter.pointPixelScale)))
                config.showsCursor = false
                config.ignoreShadowsDisplay = true
                config.colorSpaceName = CGColorSpace.sRGB
                let image = try await SCScreenshotManager.captureImage(contentFilter: displayFilter, configuration: config)
                if CaptureQuality.hasVisibleContent(image) {
                    CaptureDiagnostics.record("capture-display-recovered attempt=\(attempt)")
                    return image
                }
            } catch is CancellationError { throw CancellationError() }
            catch { CaptureDiagnostics.record("capture-display-error attempt=\(attempt)") }
        }
        throw ExtractionError.blankCapture
    }

    func captureVisibleRegion(target: CapturableWindow, rect: CGRect) async throws -> (image: CGImage, frame: CGRect) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) })
            ?? content.displays.first(where: { $0.frame.intersects(rect) }) else { throw ExtractionError.captureFailed }
        let clipped = rect.intersection(display.frame)
        let filter = SCContentFilter(display: display, including: [target.application], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = clipped.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = max(1, Int(clipped.width * 2))
        config.height = max(1, Int(clipped.height * 2))
        config.showsCursor = false
        config.ignoreShadowsDisplay = true
        return (try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config), clipped)
    }

    @MainActor
    func activateWindow(target: CapturableWindow) async throws {
        if let app = NSRunningApplication(processIdentifier: target.application.processID) {
            app.activate(options: [])
        }
        let root = AXUIElementCreateApplication(target.application.processID)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value)
        guard let windows = value as? [AXUIElement], let selected = windows.first(where: { window in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            return (title as? String) == target.window.title
        }) else {
            CaptureDiagnostics.record("raise-failed AX-window-not-found pid=\(target.application.processID)")
            throw ExtractionError.noSuitableWindow
        }
        AXUIElementPerformAction(selected, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(root, kAXFocusedWindowAttribute as CFString, selected)
        try await Task.sleep(nanoseconds: 200_000_000)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.application.processID else {
            CaptureDiagnostics.record("raise-failed front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) target=\(target.application.processID)")
            throw ExtractionError.noSuitableWindow
        }
    }

    @MainActor
    func activateAndScroll(target: CapturableWindow, delta: Int32) async throws {
        try await activateWindow(target: target)
        let location = CGPoint(x: target.window.frame.midX, y: target.window.frame.midY)
        let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)
        event?.location = location
        event?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 650_000_000)
    }

    private func score(_ window: SCWindow) -> Double {
        var result = Double(window.frame.width * window.frame.height)
        let title = (window.title ?? "").lowercased()
        if title.contains("聊天记录") || title.contains("chat history") { result += 10_000_000 }
        if title.contains("微信") || title.contains("wechat") { result += 1_000_000 }
        return result
    }

}
