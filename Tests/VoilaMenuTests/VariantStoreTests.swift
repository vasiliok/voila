import Foundation
import Testing
import Voila
@testable import VoilaMenu

private let dictionary = try! Completer.french()

@MainActor
@Suite struct VariantStoreTests {
    private let defaults: UserDefaults

    init() {
        let suite = "voila-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func addedVariantAppliesImmediately() {
        let store = VariantStore(completer: dictionary, defaults: defaults)
        #expect(store.add(typed: "bjr", replacement: "bonjour"))
        #expect(store.completer.restore("bjr") == "bonjour")
    }

    @Test func survivesRelaunch() {
        VariantStore(completer: dictionary, defaults: defaults)
            .add(typed: "ajurdui", replacement: "aujourd'hui")
        let reopened = VariantStore(completer: dictionary, defaults: defaults)
        #expect(reopened.variants.map(\.typed) == ["ajurdui"])
        #expect(reopened.completer.restore("ajurdui") == "aujourd'hui")
    }

    @Test func sameTypedWordReplacesOldRule() {
        let store = VariantStore(completer: dictionary, defaults: defaults)
        store.add(typed: "bjr", replacement: "bonjour")
        store.add(typed: "BJR", replacement: "bonsoir")
        #expect(store.variants.map(\.replacement) == ["bonsoir"])
    }

    @Test func removeUndoesTheRule() throws {
        let store = VariantStore(completer: dictionary, defaults: defaults)
        store.add(typed: "bjr", replacement: "bonjour")
        store.remove(try #require(store.variants.first))
        #expect(store.variants.isEmpty)
        #expect(store.completer.restore("bjr") == "bjr")
    }

    @Test func keepsListSorted() {
        let store = VariantStore(completer: dictionary, defaults: defaults)
        for typed in ["tkt", "bjr", "mdr"] {
            store.add(typed: typed, replacement: typed.uppercased())
        }
        #expect(store.variants.map(\.typed) == ["bjr", "mdr", "tkt"])
    }

    @Test(arguments: [("", "x"), ("bjr", ""), ("deux mots", "x"), ("a1", "x")])
    func rejectsInvalidRules(typed: String, replacement: String) {
        let store = VariantStore(completer: dictionary, defaults: defaults)
        #expect(!store.add(typed: typed, replacement: replacement))
        #expect(store.variants.isEmpty)
    }

    @Test func acceptsApostrophesAndHyphens() {
        #expect(VariantStore.isValid(typed: "aujourd'hui", replacement: "x"))
        #expect(VariantStore.isValid(typed: "peut-etre", replacement: "x"))
    }
}
