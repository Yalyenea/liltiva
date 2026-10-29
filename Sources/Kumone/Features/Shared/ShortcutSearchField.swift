import AppKit
import SwiftUI

extension Notification.Name {
    static let focusLibrarySearch = Notification.Name("Liltiva.focusLibrarySearch")
}

extension NSView {
    func descendant<T: NSView>(of type: T.Type, matching predicate: (T) -> Bool = { _ in true }) -> T? {
        if let match = self as? T, predicate(match) { return match }
        for child in subviews {
            if let match = child.descendant(of: type, matching: predicate) { return match }
        }
        return nil
    }
}

/// Native field editing gives both hosting trees the same focus, selection and
/// Escape behavior, including the playlist header when it has scrolled away.
struct ShortcutSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var isPlaylistSearch = false
    var focusRequest = 0
    var onSubmit: () -> Void = {}
    var onExit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.font = .systemFont(ofSize: 12.5)
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.content = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.isPlaylistSearch = isPlaylistSearch
        field.isEnabled = context.environment.isEnabled
        field.setAccessibilityLabel(isPlaylistSearch ? String(localized: "搜索歌单内歌曲") : String(localized: "全局搜索"))
        field.setAccessibilityIdentifier(isPlaylistSearch ? "playlist-search" : "library-search")
        field.exit = { [weak field] in
            guard let field else { return }
            if isPlaylistSearch { text = "" }
            onExit()
            field.window?.makeFirstResponder(isPlaylistSearch
                ? field.enclosingTable : nil)
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak field] in field?.focusAndSelect() }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var content: ShortcutSearchField
        var lastFocusRequest = 0
        init(_ content: ShortcutSearchField) { self.content = content }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? Field else { return }
            content.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            let field = notification.object as? Field
            (field?.currentEditor() as? NSTextView)?.drawsBackground = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? Field else { return false }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                field.exit?()
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if content.isPlaylistSearch { _ = field.enclosingTable?.moveSelection?(true) }
                else { content.onSubmit() }
                return true
            }
            if selector == #selector(NSResponder.moveDown(_:)), content.isPlaylistSearch {
                _ = field.enclosingTable?.moveSelection?(true)
                return true
            }
            return false
        }
    }

    final class Field: NSTextField {
        var isPlaylistSearch = false
        var exit: (() -> Void)?

        var enclosingTable: TrackTable.SongTable? {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? TrackTable.SongTable { return table }
                ancestor = view.superview
            }
            return nil
        }

        func focusAndSelect() {
            guard let window else { return }
            window.makeFirstResponder(self)
            currentEditor()?.selectAll(nil)
        }
    }
}

/// The native table activates the row's existing playback action, keeping
/// double-click and Return consistent about permissions and offline tracks.
struct TrackActivationTarget: NSViewRepresentable {
    let activate: () -> Void
    func makeNSView(context: Context) -> Target { Target() }
    func updateNSView(_ target: Target, context: Context) {
        target.activate = context.environment.isEnabled ? activate : nil
    }
    final class Target: NSView {
        var activate: (() -> Void)?
    }
}
