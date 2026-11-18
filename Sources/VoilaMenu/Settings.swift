import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The user's hotkey: persisted, and re-registered whenever it changes.
@MainActor
final class ShortcutStore: ObservableObject {
    @Published private(set) var shortcut: Shortcut
    /// True when macOS refused the shortcut (another app owns it).
    @Published private(set) var isUnavailable = false

    private static let defaultsKey = "shortcut"
    private let hotKey: HotKey

    init(action: @escaping () -> Void) {
        hotKey = HotKey(action: action)
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
            let saved = try? JSONDecoder().decode(Shortcut.self, from: data) {
            shortcut = saved
        } else {
            shortcut = .default
        }
        apply()
    }

    func set(_ newShortcut: Shortcut) {
        shortcut = newShortcut
        if let data = try? JSONEncoder().encode(newShortcut) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        apply()
    }

    /// Recording must not trigger the current hotkey, so it is released
    /// while the recorder listens.
    func pause() { hotKey.unregister() }
    func resume() { apply() }

    private func apply() {
        isUnavailable = !hotKey.register(shortcut)
    }
}

struct SettingsView: View {
    @ObservedObject var store: ShortcutStore
    @ObservedObject var variants: VariantStore
    @State private var newTyped = ""
    @State private var newReplacement = ""
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var isTrusted = SelectionFixer.isTrusted
    @State private var recordingHint: String?

    private let trustTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            LabeledContent("Fix selected text:") {
                HStack {
                    Button(isRecording ? "Type a shortcut…" : store.shortcut.display) {
                        isRecording ? stopRecording() : startRecording()
                    }
                    .frame(minWidth: 130)
                    Button("Reset") { store.set(.default) }
                        .disabled(store.shortcut == .default || isRecording)
                }
            }
            if let recordingHint {
                Text(recordingHint).font(.callout).foregroundStyle(.secondary)
            } else if store.isUnavailable {
                Text("\(store.shortcut.display) is taken by another app. Choose another.")
                    .font(.callout).foregroundStyle(.red)
            }

            LabeledContent("Accessibility:") {
                if isTrusted {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Allow…") { SelectionFixer.requestTrust() }
                }
            }
            Text("""
                Select text in any app and press the shortcut: \
                "ca va etre genial" becomes "ça va être génial". \
                The shortcut copies and pastes for you, which needs Accessibility.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 6)
            variantsSection
        }
        .padding(20)
        .frame(width: 480)
        .onReceive(trustTimer) { _ in isTrusted = SelectionFixer.isTrusted }
        .onDisappear(perform: stopRecording)
    }

    private var variantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("My variants").font(.headline)
            HStack {
                TextField("I type", text: $newTyped)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("Voilà writes", text: $newReplacement)
                    .onSubmit(addVariant)
                Button("Add", action: addVariant)
                    .disabled(!VariantStore.isValid(typed: newTyped, replacement: newReplacement))
            }
            if variants.variants.isEmpty {
                Text("No variants yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                List(variants.variants) { variant in
                    HStack {
                        Text(variant.typed)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(variant.replacement)
                        Spacer()
                        Button {
                            variants.remove(variant)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this variant")
                    }
                }
                .frame(height: 140)
            }
            Text("""
                Matched ignoring case and accents, and applied before the dictionary. \
                Write the same word on both sides to teach Voilà a word, like a name. \
                The suggestion menu's “Always…” items add variants too.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addVariant() {
        if variants.add(typed: newTyped, replacement: newReplacement) {
            newTyped = ""
            newReplacement = ""
        }
    }

    private func startRecording() {
        isRecording = true
        recordingHint = "Press keys with ⌃, ⌥ or ⌘. Esc cancels."
        store.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
            } else if let shortcut = Shortcut(event: event) {
                stopRecording()
                store.set(shortcut)
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if isRecording {
            isRecording = false
            recordingHint = nil
            store.resume()
        }
    }
}
