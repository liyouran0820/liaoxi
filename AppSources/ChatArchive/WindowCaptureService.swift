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
        guard !apps.isEmpty else { throw ExtractionError.weChatNotRunning }

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
        let scale = bestScaleFactor(for: target.window.frame)
        configuration.width = max(1, Int(target.window.frame.width * scale))
        configuration.height = max(1, Int(target.window.frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
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
    func activateAndScroll(target: CapturableWindow, delta: Int32) async throws {
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

    private func bestScaleFactor(for frame: CGRect) -> CGFloat {
        NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.backingScaleFactor ?? 2
    }
}
