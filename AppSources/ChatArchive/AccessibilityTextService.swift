import ApplicationServices
import CoreGraphics
import Foundation

struct AccessibilityTextService {
    func visibleText(processID: pid_t, matching windowFrame: CGRect) -> [String] {
        let app = AXUIElementCreateApplication(processID)
        guard let windows = values(of: kAXWindowsAttribute, from: app) as? [AXUIElement] else { return [] }
        let window = windows.min { lhs, rhs in
            frameDistance(frame(of: lhs), windowFrame) < frameDistance(frame(of: rhs), windowFrame)
        }
        guard let window else { return [] }

        var results: [(String, CGPoint)] = []
        walk(window, depth: 0, results: &results)
        return results
            .sorted {
                if abs($0.1.y - $1.1.y) < 5 { return $0.1.x < $1.1.x }
                return $0.1.y < $1.1.y
            }
            .map(\.0)
    }

    private func walk(_ element: AXUIElement, depth: Int, results: inout [(String, CGPoint)]) {
        guard depth < 18 else { return }
        let role = stringValue(kAXRoleAttribute, from: element) ?? ""
        if [kAXStaticTextRole as String, kAXTextAreaRole as String, kAXButtonRole as String].contains(role) {
            let text = stringValue(kAXValueAttribute, from: element)
                ?? stringValue(kAXTitleAttribute, from: element)
                ?? stringValue(kAXDescriptionAttribute, from: element)
            if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                results.append((text, frame(of: element).origin))
            }
        }
        guard let children = values(of: kAXChildrenAttribute, from: element) as? [AXUIElement] else { return }
        for child in children { walk(child, depth: depth + 1, results: &results) }
    }

    private func values(of attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func stringValue(_ attribute: String, from element: AXUIElement) -> String? {
        values(of: attribute, from: element) as? String
    }

    private func frame(of element: AXUIElement) -> CGRect {
        var point = CGPoint.zero
        var size = CGSize.zero
        if let position = axValue(of: kAXPositionAttribute, from: element) {
            AXValueGetValue(position, .cgPoint, &point)
        }
        if let dimensions = axValue(of: kAXSizeAttribute, from: element) {
            AXValueGetValue(dimensions, .cgSize, &size)
        }
        return CGRect(origin: point, size: size)
    }

    private func axValue(of attribute: String, from element: AXUIElement) -> AXValue? {
        guard let value = values(of: attribute, from: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.midX - rhs.midX) + abs(lhs.midY - rhs.midY) + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }
}
