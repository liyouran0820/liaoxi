import AppKit
import Foundation

struct SystemSettingsService {
    static let accessibilityURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
    )!

    static let legacyAccessibilityURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    @MainActor
    func openAccessibility() -> Bool {
        if NSWorkspace.shared.open(Self.accessibilityURL) {
            return true
        }
        if NSWorkspace.shared.open(Self.legacyAccessibilityURL) {
            return true
        }
        return NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
