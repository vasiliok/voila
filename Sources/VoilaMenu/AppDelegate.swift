import AppKit
import Voila
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var completer: Completer?
    private var serviceProvider: ServiceProvider?
    private var fixer: SelectionFixer?
    private var shortcuts: ShortcutStore?
    private var settingsWindow: NSWindow?
    private let fixItem = NSMenuItem(
        title: "Fix Selected Text", action: #selector(fixSelection), keyEquivalent: "")
    private let loginItem = NSMenuItem(
        title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let completer = try Self.loadCompleter()
            self.completer = completer
            let provider = ServiceProvider(completer: completer)
            serviceProvider = provider
            NSApp.servicesProvider = provider
            NSUpdateDynamicServices()
            let fixer = SelectionFixer(completer: completer)
            self.fixer = fixer
            shortcuts = ShortcutStore { fixer.fixSelection() }
        } catch {
            showAlert(
                "Voilà cannot load its dictionary",
                error.localizedDescription)
            NSApp.terminate(nil)
            return
        }
        setUpStatusItem()
    }

    /// Inside the .app the dictionary lives in Contents/Resources; under
    /// `swift run` it comes from the SwiftPM resource bundle.
    private static func loadCompleter() throws -> Completer {
        if let url = Bundle.main.url(forResource: "fr_50k", withExtension: "txt") {
            return try Completer.load(from: url)
        }
        return try Completer.french()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "é"
        item.button?.toolTip = "Voilà"

        let menu = NSMenu()
        menu.addItem(fixItem)
        menu.addItem(withTitle: "Restore Accents in Clipboard",
                     action: #selector(restoreClipboard), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(loginItem)
        menu.addItem(withTitle: "How to Use…", action: #selector(showHelp), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Voilà",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for menuItem in menu.items where menuItem.action != #selector(NSApplication.terminate(_:)) {
            menuItem.target = self
        }
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    @objc private func fixSelection() {
        fixer?.fixSelection()
    }

    @objc private func showSettings() {
        guard let shortcuts else { return }
        if settingsWindow == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: SettingsView(store: shortcuts)))
            window.title = "Voilà Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func restoreClipboard() {
        let pasteboard = NSPasteboard.general
        guard let completer, let text = pasteboard.string(forType: .string) else {
            NSSound.beep()
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(completer.restore(text), forType: .string)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            showAlert("Cannot change Launch at Login", error.localizedDescription)
        }
    }

    @objc private func showHelp() {
        showAlert(
            "Fix French text anywhere",
            """
            Select text in any app and press \(shortcuts?.shortcut.display ?? "the shortcut") \
            (change it in Settings), or right-click it and choose \
            Services → Restore French Accents. The selection is replaced: \
            "ca va etre genial" becomes "ça va être génial".

            If the Services item is missing, enable it in System Settings → \
            Keyboard → Keyboard Shortcuts → Services → Text.

            "Restore Accents in Clipboard" fixes text you have copied, \
            ready to paste.
            """)
    }

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if let shortcut = shortcuts?.shortcut {
            fixItem.title = "Fix Selected Text  \(shortcut.display)"
        }
    }
}
