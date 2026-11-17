import AppKit
import AutoFrench
import Carbon.HIToolbox

/// Fixes the selected text of the frontmost app: copies it with a synthetic
/// ⌘C, restores the accents, pastes the result with ⌘V, then puts the
/// user's clipboard back. Posting keys needs Accessibility permission.
@MainActor
final class SelectionFixer {
    private let completer: Completer
    private var isBusy = false

    init(completer: Completer) {
        self.completer = completer
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS for Accessibility permission, which adds AutoFrench to
    /// the list in System Settings, and opens that panel.
    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options),
            let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func fixSelection() {
        guard !isBusy else { return }
        guard Self.isTrusted else {
            Self.requestTrust()
            return
        }
        isBusy = true
        Task {
            await fix()
            isBusy = false
        }
    }

    private func fix() async {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount
        let targetApp = NSWorkspace.shared.frontmostApplication
        let menuLocation = Self.selectionLocation() ?? NSEvent.mouseLocation

        postCommand(kVK_ANSI_C)
        for _ in 0..<25 where pasteboard.changeCount == before {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard pasteboard.changeCount != before,
            let text = pasteboard.string(forType: .string) else {
            NSSound.beep()  // nothing selected, or the app has no Copy
            return
        }

        var fixed = completer.restore(text)
        let misspellings = completer.misspellings(in: fixed).prefix(Self.maxQuestions)
        if !misspellings.isEmpty {
            // The menus need keyboard focus; the paste needs it back.
            NSApp.activate(ignoringOtherApps: true)
            var corrections: [(misspelling: Completer.Misspelling, replacement: String)] = []
            for misspelling in misspellings {
                if let choice = SuggestionMenu.choose(for: misspelling, at: menuLocation) {
                    corrections.append((misspelling, choice))
                }
            }
            fixed = Completer.applying(corrections, to: fixed)
            targetApp?.activate()
            try? await Task.sleep(for: .milliseconds(200))
        }

        if fixed != text {
            pasteboard.clearContents()
            pasteboard.setString(fixed, forType: .string)
            postCommand(kVK_ANSI_V)
            // The target app reads the clipboard asynchronously after ⌘V.
            try? await Task.sleep(for: .milliseconds(300))
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(saved)
    }

    /// At most this many suggestion menus per hotkey press, so a pasted
    /// paragraph full of names doesn't become a quiz.
    private static let maxQuestions = 5

    /// Bottom-left corner of the focused app's selection in AppKit screen
    /// coordinates, or nil when the app doesn't expose it.
    private static func selectionLocation() -> NSPoint? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement

        var range: CFTypeRef?
        var bounds: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
            let range,
            AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds)
                == .success,
            let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0
        else { return nil }
        // Accessibility measures from the top of the primary screen, AppKit from its bottom.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSPoint(x: rect.minX, y: primaryHeight - rect.maxY)
    }

    private func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    /// Posts ⌘+key. The private event source keeps the modifiers the user
    /// is still holding from the hotkey out of the synthetic event.
    private func postCommand(_ keyCode: Int) {
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            let event = CGEvent(
                keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
