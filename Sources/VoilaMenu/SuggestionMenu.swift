import AppKit
import Voila

/// A popup menu offering replacements for one unknown word.
@MainActor
final class SuggestionMenu: NSObject {
    private var chosen: String?

    /// Shows the menu at `location` (screen coordinates) and blocks until
    /// the user picks a word or dismisses it; nil means keep the word.
    static func choose(for misspelling: Completer.Misspelling, at location: NSPoint) -> String? {
        let handler = SuggestionMenu()
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "Did you mean…", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for suggestion in misspelling.suggestions {
            let item = NSMenuItem(
                title: suggestion, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = handler
            item.representedObject = suggestion
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let keep = NSMenuItem(
            title: "Keep “\(misspelling.word)”", action: #selector(pick(_:)), keyEquivalent: "")
        keep.target = handler
        menu.addItem(keep)

        menu.popUp(positioning: menu.items[1], at: location, in: nil)
        return handler.chosen
    }

    @objc private func pick(_ sender: NSMenuItem) {
        chosen = sender.representedObject as? String
    }
}
