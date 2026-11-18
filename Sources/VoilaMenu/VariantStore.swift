import Foundation
import Voila

/// One of the user's own rules: when they type `typed`, write `replacement`.
struct Variant: Codable, Equatable, Identifiable {
    var id = UUID()
    var typed: String
    var replacement: String
}

/// The user's variants, persisted, and the completer they apply to. Every
/// part of the app reads `completer` from here, so a new rule takes effect
/// on the next hotkey press without reloading the dictionary.
@MainActor
final class VariantStore: ObservableObject {
    @Published private(set) var variants: [Variant] = []
    private(set) var completer: Completer

    private static let defaultsKey = "variants"
    private let defaults: UserDefaults

    init(completer: Completer, defaults: UserDefaults = .standard) {
        self.completer = completer
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
            let saved = try? JSONDecoder().decode([Variant].self, from: data) {
            variants = saved
        }
        apply()
    }

    /// Whether `typed` can be a rule: a single word, since text is matched
    /// word by word.
    static func isValid(typed: String, replacement: String) -> Bool {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        let replacement = replacement.trimmingCharacters(in: .whitespaces)
        return !typed.isEmpty && !replacement.isEmpty
            && typed.allSatisfy { $0.isLetter || $0 == "'" || $0 == "\u{2019}" || $0 == "-" }
    }

    /// Adds a rule, replacing any existing rule for the same typed word
    /// (ignoring case and accents). Returns false when the rule is invalid.
    @discardableResult
    func add(typed: String, replacement: String) -> Bool {
        guard Self.isValid(typed: typed, replacement: replacement) else { return false }
        let typed = typed.trimmingCharacters(in: .whitespaces)
        let replacement = replacement.trimmingCharacters(in: .whitespaces)
        let key = Completer.fold(typed)
        variants.removeAll { Completer.fold($0.typed) == key }
        variants.append(Variant(typed: typed, replacement: replacement))
        variants.sort { $0.typed.localizedStandardCompare($1.typed) == .orderedAscending }
        save()
        return true
    }

    func remove(_ variant: Variant) {
        variants.removeAll { $0.id == variant.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(variants) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        apply()
    }

    private func apply() {
        completer.setVariants(variants.map { ($0.typed, $0.replacement) })
    }
}
