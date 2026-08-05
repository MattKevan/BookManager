import AppKit
import SwiftUI

/// A system-styled search field (`NSSearchField`) used as a regular toolbar
/// item. `.searchable` is not usable here: on macOS the system search item is
/// pinned to the toolbar's trailing edge with nothing allowed after it (the
/// Inspector toggle must sit to its RIGHT), and on macOS 26 the `.searchable`
/// field expands to fill the available toolbar width, crowding out the other
/// items. A fixed-width `NSSearchField` item gets the exact system styling —
/// glass capsule, focus ring, clear button — while staying positionable in the
/// toolbar's declaration order.
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String
    /// Published by the toolbar via `.focusedValue` so the Find command
    /// (Cmd-F) can focus the field programmatically.
    var isFocused: FocusState<Bool>.Binding

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        // Every keystroke updates the binding immediately; the session
        // debounces the actual refresh (200 ms in `searchText.didSet`).
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        // Fixed width keeps the field stable and prevents it from absorbing
        // all available toolbar space (the macOS 26 `.searchable` bug).
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        // Cmd-F bridge: the toolbar's focused value flips this binding true;
        // focus the field, but never steal focus from a field already editing.
        if isFocused.wrappedValue, nsView.window?.firstResponder !== nsView.currentEditor() {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ToolbarSearchField

        init(_ parent: ToolbarSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.isFocused.wrappedValue = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.isFocused.wrappedValue = false
        }
    }
}
