import AppKit
import Voila

/// What the user picked in the suggestion menu.
enum SuggestionChoice: Equatable {
    case replace(String)
    /// Replace now, and add a variant so it happens automatically next time.
    case alwaysReplace(String)
    case keep
    /// Keep, and add the word as a variant of itself so it is never asked again.
    case alwaysKeep
}

/// A popup menu offering replacements for one unknown word.
@MainActor
final class SuggestionMenu: NSObject {
    private var chosen: SuggestionChoice?
    private var choices: [SuggestionChoice] = []

    /// Shows the menu at `location` (screen coordinates) and blocks until
    /// the user picks an item or dismisses it; nil means dismissed.
    static func choose(
        for misspelling: Completer.Misspelling, at location: NSPoint
    ) -> SuggestionChoice? {
        let handler = SuggestionMenu()
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "Did you mean…", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for suggestion in misspelling.suggestions {
            menu.addItem(handler.item(suggestion, .replace(suggestion)))
        }
        menu.addItem(.separator())

        // A rule matches one typed word, so pieces like "aujour dhui" can't
        // become one.
        let canRemember = VariantStore.isValid(
            typed: misspelling.word, replacement: misspelling.word)
        if canRemember {
            let always = NSMenuItem(title: "Always Replace With", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for suggestion in misspelling.suggestions {
                submenu.addItem(handler.item(suggestion, .alwaysReplace(suggestion)))
            }
            always.submenu = submenu
            menu.addItem(always)
        }
        menu.addItem(handler.item("Keep “\(misspelling.word)”", .keep))
        if canRemember {
            menu.addItem(handler.item("Always Keep “\(misspelling.word)”", .alwaysKeep))
        }

        menu.popUp(positioning: menu.items[1], at: location, in: nil)
        return handler.chosen
    }

    private func item(_ title: String, _ choice: SuggestionChoice) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
        item.target = self
        item.tag = choices.count
        choices.append(choice)
        return item
    }

    @objc private func pick(_ sender: NSMenuItem) {
        chosen = choices[sender.tag]
    }
}
