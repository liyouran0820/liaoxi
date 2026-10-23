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
            let title = (window.title ?? "").lowercased()
            return window.isOnScreen && window.frame.width >= 420 && window.frame.height >= 360
                && (title.contains("聊天记录") || title.contains("chat history"))
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

    @MainActor
    func activateAndScroll(target: CapturableWindow, delta: Int32, mode: RecordScrollMode = .precise) async throws -> CapturableWindow {
        try Task.checkCancellation()
        let current = try await refreshed(target)
        guard let app = NSRunningApplication(processIdentifier: current.application.processID) else { throw RecordScrollError.windowGone }
        let root = AXUIElementCreateApplication(current.application.processID)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value)
        let windows = (value as? [AXUIElement] ?? []).filter { element in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            return (title as? String) == current.window.title
        }
        guard windows.count == 1, let selected = windows.first else { throw RecordScrollError.windowGone }
        // Activating all WeChat windows can put the ordinary chat window above the merged record.
        app.activate(options: [])
        try await Task.sleep(nanoseconds: 180_000_000)
        guard AXUIElementPerformAction(selected, kAXRaiseAction as CFString) == .success else { throw RecordScrollError.cannotFocus }
        _ = AXUIElementSetAttributeValue(root, kAXFocusedWindowAttribute as CFString, selected)
        try await Task.sleep(nanoseconds: 180_000_000)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == current.application.processID else { throw RecordScrollError.cannotFocus }
        // Re-read the actual window's frame after activation / Space changes, not the launch-time coordinates.
        let ready = try await refreshed(current)
        let location = RecordScrollPlan.location(in: ready.window.frame, mode: mode)
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left) else { throw RecordScrollError.eventUnavailable }
        move.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 100_000_000)
        let chunks = RecordScrollPlan.chunks(for: delta, mode: mode)
        var gestureOpen = false
        func send(_ amount: Int32, phase: CGScrollPhase) throws {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: mode == .precise ? .pixel : .line,
                wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0) else { throw RecordScrollError.eventUnavailable }
            event.location = location
            if mode == .precise {
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            }
            event.post(tap: .cghidEventTap)
        }
        defer { if gestureOpen { try? send(0, phase: .ended) } }
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ready.application.processID else { throw RecordScrollError.cannotFocus }
            try send(chunk, phase: index == 0 ? .began : .changed)
            gestureOpen = mode == .precise
            try await Task.sleep(nanoseconds: 12_000_000)
        }
        if gestureOpen { try send(0, phase: .ended); gestureOpen = false }
        try await Task.sleep(nanoseconds: 550_000_000)
        let after = try await refreshed(ready)
        ScrollDiagnostics.record("scroll mode=\(mode.rawValue) delta=\(delta) window=\(after.window.windowID) events=\(chunks.count)")
        return after
    }

    private func refreshed(_ target: CapturableWindow) async throws -> CapturableWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            RecordScrollPlan.matchesWindow(id: $0.windowID, owner: $0.owningApplication?.processID ?? 0,
                visible: $0.isOnScreen, frame: $0.frame, expectedID: target.window.windowID,
                expectedOwner: target.application.processID)
        }), let app = window.owningApplication else { throw RecordScrollError.windowGone }
        return CapturableWindow(window: window, application: app)
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
