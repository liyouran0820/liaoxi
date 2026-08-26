import AppKit
import Foundation

struct SystemSettingsService {
    static let accessibilityURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
    )!

    static let legacyAccessibilityURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    static let screenCaptureURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
    )!

    static let legacyScreenCaptureURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!

    @MainActor
    func openAccessibility() -> Bool {
        open(primary: Self.accessibilityURL, legacy: Self.legacyAccessibilityURL)
    }

    @MainActor
    func openScreenCapture() -> Bool {
        open(primary: Self.screenCaptureURL, legacy: Self.legacyScreenCaptureURL)
    }

    @MainActor
    private func open(primary: URL, legacy: URL) -> Bool {
        if NSWorkspace.shared.open(primary) { return true }
        if NSWorkspace.shared.open(legacy) { return true }
        return NSWorkspace.shared.open(
            URL(fileURLWithPath: "/System/Applications/System Settings.app")
        )
    }
}
