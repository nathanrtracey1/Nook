//
//  EditPinnedURLDialog.swift
//  Nook
//
//  Custom UI: Native macOS dialog to edit a pinned tab's URL. Uses NSAlert + NSTextField.
//

import AppKit

enum EditPinnedURLDialog {
    /// Show modal "Edit Pinned URL…" dialog. On OK, validates URL (http/https) and calls `onSave(newURL)`.
    static func run(currentURL: URL, onSave: @escaping (URL) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Edit Pinned URL"
        alert.informativeText = "Enter the new URL for this pinned tab."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(string: currentURL.absoluteString)
        textField.placeholderString = "https://example.com"
        textField.frame = NSRect(x: 0, y: 0, width: 360, height: 22)
        textField.cell?.lineBreakMode = .byTruncatingTail
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let raw = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https") else {
            let err = NSAlert()
            err.messageText = "Invalid URL"
            err.informativeText = "Please enter a valid http or https URL."
            err.alertStyle = .warning
            err.addButton(withTitle: "OK")
            err.runModal()
            return
        }
        onSave(url)
    }
}
