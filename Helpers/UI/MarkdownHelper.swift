// Features/Shared/MarkdownHelper.swift
import Foundation

enum MarkdownHelper {
    static func insertAtLineStart(_ prefix: String, in text: inout String) {
        // Füge vor die aktuelle Zeile das Präfix (z. B. "# " oder "- ") ein.
        // Minimalistisch: am Ende anhängen, wenn keine Cursor-Position verfügbar
        if text.isEmpty {
            text = prefix
        } else if text.hasSuffix("\n") {
            text.append(prefix)
        } else {
            text.append("\n\(prefix)")
        }
    }

    static func wrapSelectionBold(_ s: inout String) {
        s = "**" + s + "**"
    }

    static func wrapSelectionItalic(_ s: inout String) {
        s = "*" + s + "*"
    }
}
