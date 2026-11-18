import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import VoilaMenu

private func keyDown(
    _ characters: String, keyCode: Int, modifiers: NSEvent.ModifierFlags
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false,
        keyCode: UInt16(keyCode))!
}

@Suite struct ShortcutTests {
    @Test func defaultIsControlOptionF() {
        #expect(Shortcut.default.display == "⌃⌥F")
        #expect(Shortcut.default.carbonModifiers == UInt32(controlKey | optionKey))
        #expect(Shortcut.default.keyCode == UInt32(kVK_ANSI_F))
    }

    @Test func recordsKeyPress() throws {
        let shortcut = try #require(
            Shortcut(event: keyDown("k", keyCode: kVK_ANSI_K, modifiers: [.command, .shift])))
        #expect(shortcut.display == "⇧⌘K")
        #expect(shortcut.carbonModifiers == UInt32(cmdKey | shiftKey))
        #expect(shortcut.keyCode == UInt32(kVK_ANSI_K))
    }

    @Test func listsModifiersInMenuOrder() throws {
        let shortcut = try #require(Shortcut(event: keyDown(
            "a", keyCode: kVK_ANSI_A, modifiers: [.command, .shift, .option, .control])))
        #expect(shortcut.display == "⌃⌥⇧⌘A")
    }

    @Test func namesSpecialKeys() throws {
        let space = try #require(
            Shortcut(event: keyDown(" ", keyCode: kVK_Space, modifiers: [.option])))
        #expect(space.display == "⌥Space")
        let f5 = try #require(
            Shortcut(event: keyDown("\u{F708}", keyCode: kVK_F5, modifiers: [.control])))
        #expect(f5.display == "⌃F5")
    }

    @Test func rejectsKeysThatWouldFireWhileTyping() {
        #expect(Shortcut(event: keyDown("f", keyCode: kVK_ANSI_F, modifiers: [])) == nil)
        #expect(Shortcut(event: keyDown("F", keyCode: kVK_ANSI_F, modifiers: [.shift])) == nil)
    }

    @Test func ignoresIrrelevantModifierFlags() throws {
        let shortcut = try #require(Shortcut(event: keyDown(
            "f", keyCode: kVK_ANSI_F, modifiers: [.control, .capsLock, .numericPad])))
        #expect(shortcut.flags == [.control])
    }

    @Test func survivesSavingAndLoading() throws {
        let original = Shortcut(
            keyCode: UInt32(kVK_ANSI_J), modifiers: NSEvent.ModifierFlags.command.rawValue, key: "J")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Shortcut.self, from: data) == original)
    }
}
