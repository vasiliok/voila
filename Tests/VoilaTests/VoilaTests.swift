import Testing
@testable import Voila

private let completer = try! Completer.french()

@Suite struct AccentuateTests {
    @Test func restoresCedilla() {
        #expect(completer.accentuate("francais") == "français")
    }

    @Test func restoresLigature() {
        #expect(completer.accentuate("coeur") == "cœur")
    }

    @Test func restoresCircumflex() {
        #expect(completer.accentuate("etre") == "être")
    }

    @Test func transfersCapitalization() {
        #expect(completer.accentuate("Ecole") == "École")
        #expect(completer.accentuate("ECOLE") == "ÉCOLE")
    }

    @Test func keepsKnownWordAsTyped() {
        // "a" (avoir) is in the dictionary, so it must not become "à".
        #expect(completer.accentuate("a") == "a")
        #expect(completer.accentuate("été") == "été")
    }

    @Test func leavesUnknownWordAlone() {
        #expect(completer.accentuate("xyzzyq") == "xyzzyq")
    }
}

@Suite struct CompleteTests {
    @Test func findsAccentedWordsFromAsciiPrefix() {
        let words = completer.complete("ecol").map(\.word)
        #expect(words.first == "école")
    }

    @Test func ranksByFrequency() {
        let frequencies = completer.complete("ch", limit: 20).map(\.frequency)
        #expect(frequencies == frequencies.sorted(by: >))
    }

    @Test func respectsLimit() {
        #expect(completer.complete("a", limit: 3).count == 3)
    }

    @Test func emptyPrefixYieldsNothing() {
        #expect(completer.complete("").isEmpty)
    }

    @Test func transfersPrefixCase() {
        #expect(completer.complete("Ecol").first?.word == "École")
    }
}

@Suite struct RestoreTests {
    @Test func restoresSentence() {
        #expect(completer.restore("ca va etre genial") == "ça va être génial")
    }

    @Test func convertsQuotesToGuillemets() {
        #expect(completer.restore("il a dit \"bonjour\"")
            == "il a dit «\u{00A0}bonjour\u{00A0}»")
    }

    @Test func keepsPunctuationAndApostrophes() {
        #expect(completer.restore("l'ecole, deja!") == "l'école, déjà!")
    }

    @Test func keepsCorrectContractionsIntact() {
        #expect(completer.restore("qu'il jusqu'ici aujourd'hui") == "qu'il jusqu'ici aujourd'hui")
    }
}

@Suite struct ApostropheAndHyphenTests {
    @Test(arguments: [
        ("aujourdhui", "aujourd'hui"),
        ("Aujourdhui", "Aujourd'hui"),
        ("peutetre", "peut-être"),
    ])
    func restoresMissingJoiner(typed: String, expected: String) {
        #expect(completer.accentuate(typed) == expected)
    }

    @Test(arguments: [
        ("cest", "c'est"),
        ("jai", "j'ai"),
        ("quil", "qu'il"),
        ("daccord", "d'accord"),
        ("dabord", "d'abord"),
        ("jaime", "j'aime"),
        ("cetait", "c'était"),
        ("Cetait", "C'était"),
        ("jusquici", "jusqu'ici"),
    ])
    func restoresElision(typed: String, expected: String) {
        #expect(completer.accentuate(typed) == expected)
    }

    @Test(arguments: ["lune", "quelle", "son", "lame", "lait", "la", "ma", "tes", "mais", "dans"])
    func keepsRealWordsThatLookLikeContractions(word: String) {
        #expect(completer.accentuate(word) == word)
    }

    @Test func prefersAccentedWordOverContraction() {
        #expect(completer.accentuate("tete") == "tête")  // not "t'été"
    }

    @Test func restoresContractionsInText() {
        #expect(completer.restore("cest genial, jai dit quil viendra aujourdhui")
            == "c'est génial, j'ai dit qu'il viendra aujourd'hui")
    }
}

@Suite struct SuggestionTests {
    @Test(arguments: [
        ("ajurdui", "aujourd'hui"),
        ("bonjur", "bonjour"),
        ("mersi", "merci"),
        ("francias", "français"),
        ("chapeu", "chapeau"),
        ("tro", "trop"),
        ("anglai", "anglais"),
    ])
    func suggestsCorrectionFirst(typed: String, expected: String) {
        #expect(completer.suggestions(for: typed).first == expected)
    }

    @Test(arguments: [("bocoup", "beaucoup"), ("bokou", "beaucoup")])
    func suggestsPhoneticMatches(typed: String, expected: String) {
        #expect(completer.suggestions(for: typed).first == expected)
    }

    @Test func transfersCase() {
        #expect(completer.suggestions(for: "Bonjur").first == "Bonjour")
    }

    @Test func knownWordsGetNoSuggestions() {
        #expect(completer.suggestions(for: "bonjour").isEmpty)
        #expect(completer.suggestions(for: "aujourd'hui").isEmpty)
        #expect(completer.suggestions(for: "qu'il").isEmpty)
    }

    @Test func gibberishAndShortWordsGetNoSuggestions() {
        #expect(completer.suggestions(for: "xyzzyq").isEmpty)
        #expect(completer.suggestions(for: "qz").isEmpty)
    }

    @Test func offersOneSpellingPerWord() {
        let keys = completer.suggestions(for: "bocoup", limit: 10).map(Completer.fold)
        #expect(keys.count == Set(keys).count)
    }

    @Test func respectsLimit() {
        #expect(completer.suggestions(for: "bonjur", limit: 2).count == 2)
    }
}

@Suite struct MisspellingTests {
    @Test func findsUnknownWordsWithRanges() {
        let text = "je dis bonjur a mon ami"
        let found = completer.misspellings(in: text)
        #expect(found.map(\.word) == ["bonjur"])
        #expect(found.first.map { String(text[$0.range]) } == "bonjur")
        #expect(found.first?.suggestions.first == "bonjour")
    }

    @Test func treatsContractionsAsOneKnownWord() {
        #expect(completer.misspellings(in: "qu'il vienne aujourd'hui, peut-être").isEmpty)
    }

    @Test func appliesChosenCorrections() {
        let text = "mersi bocoup et bonjur"
        let found = completer.misspellings(in: text)
        #expect(found.count == 3)
        // Pick the top suggestion for the first and last, keep the middle.
        let corrections = [found[0], found[2]].map { ($0, $0.suggestions[0]) }
        #expect(Completer.applying(corrections, to: text) == "merci bocoup et bonjour")
    }
}

@Suite struct EditDistanceTests {
    private func distance(_ a: String, _ b: String, limit: Int = 5) -> Int? {
        Completer.editDistance(Array(a.unicodeScalars), Array(b.unicodeScalars), limit: limit)
    }

    @Test func countsEdits() {
        #expect(distance("chat", "chat") == 0)
        #expect(distance("chat", "chats") == 1)   // insertion
        #expect(distance("chat", "cat") == 1)     // deletion
        #expect(distance("chat", "chut") == 1)    // substitution
        #expect(distance("chat", "caht") == 1)    // adjacent swap
        #expect(distance("", "abc") == 3)
    }

    @Test func givesUpPastLimit() {
        #expect(distance("chat", "chien", limit: 1) == nil)
        #expect(distance("a", "abcd", limit: 2) == nil)
    }

    @Test func phoneticKeysMatchSoundAlikes() {
        #expect(Completer.phonetic("beaucoup") == Completer.phonetic("bocoup"))
        #expect(Completer.phonetic("photo") == Completer.phonetic("foto"))
    }
}
