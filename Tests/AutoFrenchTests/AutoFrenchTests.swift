import Testing
@testable import AutoFrench

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
}
