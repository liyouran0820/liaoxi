import AppKit
import SwiftUI

struct ManualTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var editable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let view = NSTextView()
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.setAccessibilityLabel("聊天内容")
        view.delegate = context.coordinator
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        view.isEditable = editable
        if view.string != text { view.string = text }
        let safe = Range(selection, in: text) != nil ? selection : NSRange(location: text.utf16.count, length: 0)
        if view.selectedRange() != safe { view.setSelectedRange(safe) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ManualTextEditor
        var updating = false
        init(_ parent: ManualTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            parent.selection = view.selectedRange()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.selection = view.selectedRange()
        }
    }
}
