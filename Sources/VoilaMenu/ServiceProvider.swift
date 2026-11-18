import AppKit
import Voila

/// Backs the "Restore French Accents" entry that macOS shows in the
/// right-click Services menu for selected text. The method name must match
/// NSMessage in Info.plist.
@MainActor
final class ServiceProvider: NSObject {
    private let store: VariantStore

    init(store: VariantStore) {
        self.store = store
    }

    @objc(restoreAccents:userData:error:)
    func restoreAccents(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = pasteboard.string(forType: .string) else {
            error.pointee = "Voilà: the selection contains no text." as NSString
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(store.completer.restore(text), forType: .string)
    }
}
